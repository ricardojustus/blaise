import Foundation
import Testing
@testable import BlaiseCore

// Shared C3 test support: fake venvs/model caches under temp dataRoots
// (never the real ones — asserted in makeWhisperHarness), tiny WAV
// generation, the skip protocol, and a thread-safe recorder.

// MARK: - Skip protocol

/// C3 skip protocol: a skipping test writes `<repo>/.test-skips/<test>.txt`
/// with the reason; scripts/test.sh clears the dir at the start of each run.
func recordTestSkip(_ testName: String, reason: String) {
    let dir = VocabFixtures.repoRoot.appendingPathComponent(".test-skips", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? Data(reason.utf8).write(to: dir.appendingPathComponent("\(testName).txt"))
}

// MARK: - WAV synthesis

/// Writes a 16 kHz mono 16-bit PCM WAV of `seconds` of silence.
@discardableResult
func writeTestWAV(at url: URL, seconds: Double) throws -> URL {
    let sampleRate = 16000
    let frames = Int(seconds * Double(sampleRate))
    var data = Data()
    let dataBytes = frames * 2
    func appendUInt32(_ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    func appendUInt16(_ value: UInt16) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    data.append(contentsOf: Array("RIFF".utf8))
    appendUInt32(UInt32(36 + dataBytes))
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8))
    appendUInt32(16)
    appendUInt16(1)  // PCM
    appendUInt16(1)  // mono
    appendUInt32(UInt32(sampleRate))
    appendUInt32(UInt32(sampleRate * 2))  // byte rate
    appendUInt16(2)  // block align
    appendUInt16(16)  // bits/sample
    data.append(contentsOf: Array("data".utf8))
    appendUInt32(UInt32(dataBytes))
    data.append(Data(count: dataBytes))
    try data.write(to: url)
    return url
}

// MARK: - Thread-safe recorder

final class Recorder<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [T] = []

    func append(_ value: T) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [T] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

// MARK: - Whisper harness

/// A minimal, syntactically valid driver JSON for fake-driver success paths.
let fakeDriverJSON = """
    {"text": " ola mundo", "language": "pt", "segments": [
      {"start": 0.0, "end": 1.0, "text": " ola", "no_speech_prob": 0.01, "avg_logprob": -0.2,
       "words": [{"word": " ola", "start": 0.0, "end": 0.9}]},
      {"start": 1.0, "end": 2.0, "text": " mundo", "no_speech_prob": 0.01, "avg_logprob": -0.2,
       "words": [{"word": " mundo", "start": 1.0, "end": 1.8}]}
    ]}
    """

struct WhisperHarness {
    let dataRoot: URL
    let database: BlaiseDatabase
    let settings: SettingsStore
    let engine: MLXWhisperEngine
    let requirementsData: Data

    var venvDir: URL { dataRoot.appendingPathComponent("python/venv", isDirectory: true) }
    var pythonBinary: URL { venvDir.appendingPathComponent("bin/python") }
    var hfHome: URL { dataRoot.appendingPathComponent("models/hf", isDirectory: true) }
    var sentinelURL: URL {
        VenvLayout.sentinelURL(venvDir: venvDir, requirementsData: requirementsData)
    }
    var cache: WhisperModelCache { WhisperModelCache(hfHome: hfHome) }

    /// Replaces the fake python driver script.
    func installPython(_ script: String, at venv: URL? = nil) throws {
        let bin = (venv ?? venvDir).appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let python = bin.appendingPathComponent("python")
        try Data(script.utf8).write(to: python)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
    }

    func writeSentinel() throws {
        try FileManager.default.createDirectory(at: venvDir, withIntermediateDirectories: true)
        try Data().write(to: sentinelURL)
    }

    /// A structurally complete HF cache for the pinned repo.
    static func plantCompleteCache(hfHome: URL) throws {
        let snapshot = WhisperModelCache(hfHome: hfHome).repoCacheDir
            .appendingPathComponent("snapshots/main", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: snapshot.appendingPathComponent("weights.safetensors"))
    }

    func plantCompleteCache() throws {
        try Self.plantCompleteCache(hfHome: hfHome)
    }

    func makeWAV(seconds: Double = 2.0) throws -> URL {
        try writeTestWAV(at: dataRoot.appendingPathComponent("test-\(UUID().uuidString).wav"), seconds: seconds)
    }
}

/// Fake python scripts for the error-mapping table. The `-c` branch serves
/// the engineVersion / import-check probes.
enum FakePython {
    static let versionProbe = """
        if [ "$1" = "-c" ]; then printf '0.4.3-fake'; exit 0; fi
        """

    static func script(_ body: String) -> String {
        "#!/bin/sh\n" + versionProbe + "\n" + body + "\n"
    }

    static let success = script("cat <<'JSON'\n\(fakeDriverJSON)\nJSON\nexit 0")
    static let exit2 = script("echo 'unreadable audio' >&2; exit 2")
    static let exit3 = script("echo 'weights corrupted' >&2; exit 3")
    static let exit4 = script("echo 'metal assertion' >&2; exit 4")
    static let garbageStdout = script("echo 'this is not json'; exit 0")
    static let sleeper = script("sleep 60")
}

/// Builds a fully faked, provisioned-looking whisper engine under a TEMP
/// dataRoot (asserted: tests never touch real data roots).
func makeWhisperHarness(
    python: String? = FakePython.success,
    completeCache: Bool = true,
    modelFetch: (@Sendable (URL) async throws -> Void)? = nil,
    driverTimeout: TimeInterval = 20
) async throws -> WhisperHarness {
    let dataRoot = try makeTempRoot()
    precondition(
        dataRoot.path.hasPrefix(FileManager.default.temporaryDirectory.path),
        "C3 tests must use temp dataRoots")
    let database = try BlaiseDatabase(rootURL: dataRoot)
    let settings = SettingsStore(database: database)
    let configuration = EngineConfiguration(
        engineID: MLXWhisperEngine.engineID,
        descriptors: MLXWhisperEngine.descriptors,
        settings: settings,
        secrets: InMemorySecretStore()
    )
    let driver = try #require(MLXWhisperEngine.bundledDriverScript())
    let requirements = try #require(MLXWhisperEngine.bundledRequirementsFile())
    let engine = MLXWhisperEngine(
        configuration: configuration,
        dataRoot: dataRoot,
        uvBinary: dataRoot.appendingPathComponent("uv-not-present"),
        driverScript: driver,
        requirementsFile: requirements,
        sweepOrphansOnInit: false,
        modelFetchOverride: modelFetch,
        driverTimeoutOverride: driverTimeout
    )
    let harness = WhisperHarness(
        dataRoot: dataRoot,
        database: database,
        settings: settings,
        engine: engine,
        requirementsData: try Data(contentsOf: requirements)
    )
    if let python {
        try harness.installPython(python)
        try harness.writeSentinel()
    }
    if completeCache {
        try harness.plantCompleteCache()
    }
    return harness
}

/// Unwraps an `EngineError` from a thrown error or fails.
func engineError<T: Sendable>(from operation: () async throws -> T) async -> EngineError? {
    do {
        _ = try await operation()
        return nil
    } catch let error as EngineError {
        return error
    } catch {
        return nil
    }
}
