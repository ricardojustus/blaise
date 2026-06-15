import Foundation
import os

// C6 (extends C3's venv infrastructure): the app-managed python venv is
// SHARED between the whisper and notes drivers — one requirements file
// (python_requirements.txt), one venv, one sentinel. Cross-engine safety is
// the lock scheme below (C6 spec, "Cross-engine venv locking"):
//
// - ENGINE DRIVER runs take a SHARED `flock` on `<dataRoot>/python/.lock`
//   for the subprocess lifetime.
// - Provisioning destroy/rebuild takes the EXCLUSIVE lock; its OWN child
//   spawns (`uv venv`, `uv pip`, import check) take NO lock — they run under
//   the exclusive lock's protection. (A generic in-SubprocessRunner
//   acquisition would self-deadlock: flock conflicts across fds within one
//   process.)
// - Exclusive acquisition is try-then-wait ≤ 30 s →
//   `.transient("python environment busy")` — a rebuild never silently
//   stalls minutes behind a transcription; C10's eager prepare retries
//   later.
// - One acquisition per logical operation, one fd, children inherit nothing
//   (FD_CLOEXEC).

/// `flock(2)` on `<dataRoot>/python/.lock` with shared and exclusive modes.
/// Acquisition is non-blocking + async polling so cooperative threads are
/// never parked inside a blocking flock.
final class PythonEnvironmentLock {
    static let exclusiveTimeout: TimeInterval = 30
    static let pollInterval: TimeInterval = 0.2

    private let fileDescriptor: Int32

    init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fileDescriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard fileDescriptor >= 0 else {
            throw EngineError.transient("cannot open python environment lock file: errno \(errno)")
        }
    }

    /// SHARED lock for a driver-subprocess lifetime. Waits (polling) for an
    /// in-flight rebuild to finish; observes task cancellation promptly.
    func acquireShared() async throws {
        while flock(fileDescriptor, LOCK_SH | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK else {
                throw EngineError.transient("flock(LOCK_SH) failed: errno \(errno)")
            }
            if Task.isCancelled { throw EngineError.cancelled }
            try? await Task.sleep(for: .seconds(Self.pollInterval))
        }
    }

    /// EXCLUSIVE lock for provisioning destroy/rebuild: try, then wait at
    /// most `exclusiveTimeout` seconds, then `.transient("python environment
    /// busy")`.
    func acquireExclusive(timeout: TimeInterval = PythonEnvironmentLock.exclusiveTimeout) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while flock(fileDescriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK else {
                throw EngineError.transient("flock(LOCK_EX) failed: errno \(errno)")
            }
            if Task.isCancelled { throw EngineError.cancelled }
            guard Date() < deadline else {
                throw EngineError.transient("python environment busy")
            }
            try? await Task.sleep(for: .seconds(Self.pollInterval))
        }
    }

    func unlock() {
        flock(fileDescriptor, LOCK_UN)
    }

    deinit {
        close(fileDescriptor)
    }
}

/// Runs `body` while holding the SHARED environment lock (driver runs).
/// `bypass: true` (externally managed venv — never rebuilt, lock pointless,
/// and the default-layout `python/` dir must not be created) runs `body`
/// directly.
func withSharedPythonLock<T: Sendable>(
    dataRoot: URL, bypass: Bool = false, isolation: isolated (any Actor)? = #isolation,
    _ body: () async throws -> T
) async throws -> T {
    if bypass { return try await body() }
    let lock = try PythonEnvironmentLock(url: VenvLayout(dataRoot: dataRoot).lockFileURL)
    try await lock.acquireShared()
    defer { lock.unlock() }
    return try await body()
}

/// Shared venv provisioning (C3's flow, extracted for C6's second consumer):
/// sentinel `.blaise-provisioned-<sha256(python_requirements.txt)>` present
/// ⇔ the venv satisfies exactly that pin set. Missing/mismatched → destroy +
/// rebuild under the EXCLUSIVE lock: `uv venv --python 3.12` (interpreter
/// inside the data root) + `uv pip install --no-deps --require-hashes` +
/// per-engine import check → write sentinel.
struct PythonVenvProvisioner: Sendable {
    let dataRoot: URL
    let uvBinary: URL
    let requirementsFile: URL
    /// Modules the consuming engine needs importable after install.
    let importCheckModules: [String]
    let logger: Logger

    func provisionIfNeeded(venvDir: URL) async throws {
        let requirementsData: Data
        do {
            requirementsData = try Data(contentsOf: requirementsFile)
        } catch {
            throw EngineError.permanent("bundled python_requirements.txt unreadable: \(error)")
        }
        if VenvLayout.isProvisioned(venvDir: venvDir, requirementsData: requirementsData) {
            return
        }

        let layout = VenvLayout(dataRoot: dataRoot)
        let lock = try PythonEnvironmentLock(url: layout.lockFileURL)
        try await lock.acquireExclusive()
        defer { lock.unlock() }

        // Re-check under the lock: another process may have provisioned.
        if VenvLayout.isProvisioned(venvDir: venvDir, requirementsData: requirementsData) {
            return
        }

        guard FileManager.default.isExecutableFile(atPath: uvBinary.path) else {
            throw EngineError.notAvailable(reason: "bundled uv binary missing at \(uvBinary.path)")
        }

        logger.info("provisioning venv at \(venvDir.path) (sentinel missing/mismatched)")
        // Missing/mismatched sentinel → destroy + rebuild.
        try? FileManager.default.removeItem(at: venvDir)

        var uvEnvironment = minimalPythonProcessEnvironment()
        uvEnvironment["UV_PYTHON_INSTALL_DIR"] = layout.cpythonInstallDir.path
        uvEnvironment["UV_CACHE_DIR"] = layout.uvCacheDir.path

        let pythonBinary = venvDir.appendingPathComponent("bin/python")
        try await runUV(
            ["venv", "--python", "3.12", venvDir.path],
            environment: uvEnvironment, timeout: 600, step: "uv venv")
        try await runUV(
            [
                "pip", "install",
                "--python", pythonBinary.path,
                "--no-deps", "--require-hashes",
                "-r", requirementsFile.path,
            ],
            environment: uvEnvironment, timeout: 3600, step: "uv pip install")

        if let failure = await pythonImportCheckFailure(
            python: pythonBinary, modules: importCheckModules)
        {
            throw EngineError.transient("venv import check failed after install: \(failure)")
        }

        let sentinel = VenvLayout.sentinelURL(venvDir: venvDir, requirementsData: requirementsData)
        do {
            try Data().write(to: sentinel)
        } catch {
            throw EngineError.transient("cannot write provisioning sentinel: \(error)")
        }
        logger.info("venv provisioned; sentinel \(sentinel.lastPathComponent)")
    }

    private func runUV(
        _ arguments: [String], environment: [String: String], timeout: TimeInterval, step: String
    ) async throws {
        let outcome: SubprocessRunner.Outcome
        do {
            outcome = try await SubprocessRunner.run(
                executable: uvBinary, arguments: arguments, environment: environment, timeout: timeout)
        } catch {
            throw EngineError.notAvailable(reason: "\(step) failed to launch: \(error)")
        }
        if outcome.cancelled { throw EngineError.cancelled }
        if outcome.timedOut { throw EngineError.transient("\(step) timed out") }
        guard outcome.exitStatus == 0 else {
            throw EngineError.transient("\(step) failed: \(stderrExcerpt(outcome.stderrTail))")
        }
    }
}

/// nil = all modules import; otherwise a reason string.
func pythonImportCheckFailure(python: URL, modules: [String]) async -> String? {
    do {
        let outcome = try await SubprocessRunner.run(
            executable: python,
            arguments: ["-c", "import " + modules.joined(separator: ", ")],
            environment: minimalPythonProcessEnvironment(),
            timeout: 120
        )
        return outcome.exitStatus == 0 ? nil : stderrExcerpt(outcome.stderrTail)
    } catch {
        return "interpreter failed to launch: \(error)"
    }
}

/// Explicit minimal environment for python/uv subprocesses — never the GUI
/// login env.
func minimalPythonProcessEnvironment() -> [String: String] {
    [
        "PATH": "/usr/bin:/bin",
        "HOME": NSHomeDirectory(),
    ]
}

func stderrExcerpt(_ stderr: String) -> String {
    let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.count > 600 ? "…" + trimmed.suffix(600) : trimmed
}
