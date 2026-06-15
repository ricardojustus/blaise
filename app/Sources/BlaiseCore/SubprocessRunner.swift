import Foundation

/// Runs a subprocess with the C3 process contract:
/// - stdout and stderr drained CONCURRENTLY from launch (readability
///   handlers; a 78-min transcript far exceeds the 64 KB pipe buffer, and
///   read-after-wait deadlocks). stdout is accumulated whole; stderr keeps
///   only the last 4 KB (ring) for error excerpts.
/// - timeout → SIGTERM, 5 s grace, SIGKILL; reported as `.timedOut`.
/// - task cancellation → same kill sequence; reported as `.cancelled`.
/// - explicit environment only (env hygiene; never the GUI login env).
enum SubprocessRunner {
    struct Outcome: Sendable {
        /// nil when the process was killed by the runner (timeout/cancel).
        var exitStatus: Int32?
        var terminationReason: Process.TerminationReason
        var stdout: Data
        /// Last 4 KB of stderr, lossy UTF-8.
        var stderrTail: String
        var timedOut: Bool
        var cancelled: Bool
    }

    enum SpawnError: Error {
        case launchFailed(String)
    }

    static let stderrRingCapacity = 4096
    static let sigkillGraceSeconds: Double = 5

    /// Spawn failure (binary missing/not executable) throws `SpawnError`;
    /// everything else is reported in `Outcome`.
    ///
    /// `stdin` (C3 v4.1 amendment): caller-supplied Data written to the
    /// child's stdin from a detached task, fd closed at EOF; the nullDevice
    /// default is unchanged.
    static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL? = nil,
        stdin: Data? = nil,
        timeout: TimeInterval
    ) async throws -> Outcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdinPipe: Pipe?
        if stdin != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinPipe = pipe
        } else {
            process.standardInput = FileHandle.nullDevice
            stdinPipe = nil
        }

        let collector = StreamCollector()

        // Drain from launch, off the awaiting task, so the child never blocks
        // on a full pipe regardless of which stream it floods.
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                collector.finishStdout()
            } else {
                collector.appendStdout(chunk)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                collector.finishStderr()
            } else {
                collector.appendStderr(chunk)
            }
        }

        // Set BEFORE run(): a handler installed after exit never fires.
        let exitGate = OneShotGate()
        process.terminationHandler = { _ in exitGate.open() }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw SpawnError.launchFailed("\(error)")
        }

        // Feed stdin off the awaiting task (a large payload would deadlock
        // against an unread stdout pipe if written inline); close at EOF.
        // F_SETNOSIGPIPE: if the child exits before consuming stdin (e.g.
        // ssh dying on auth/host-key failure mid-delivery), a plain write
        // raises SIGPIPE and KILLS THE WHOLE APP — `try?` never sees it.
        // With the flag set the write fails as a catchable EPIPE instead and
        // the child's exit status carries the real error. Field crash
        // 11/06/2026: launch crash-loop on a stuck `delivering` row.
        if let stdinPipe, let stdin {
            let handle = stdinPipe.fileHandleForWriting
            _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
            Task.detached {
                try? handle.write(contentsOf: stdin)
                try? handle.close()
            }
        }

        let killer = ProcessKiller(process: process, exited: { exitGate.opened() })
        let timeoutTask = Task.detached {
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            killer.kill(reason: .timeout)
        }
        defer { timeoutTask.cancel() }

        await withTaskCancellationHandler {
            // Uncancellable wait for real exit: on cancellation the child is
            // killed and we still collect its termination.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                exitGate.whenOpen { continuation.resume() }
            }
        } onCancel: {
            killer.kill(reason: .cancellation)
        }

        // EOF on both pipes before reading the collected output (the handlers
        // signal completion when availableData turns empty). The wait is
        // CAPPED: a killed sh-style child can leave a grandchild holding the
        // pipe write ends (observed: sh's `sleep` survives the parent's
        // SIGKILL and keeps the pipe open for its full duration) — 2 s grace
        // after a kill, 30 s after a natural exit (EOF is immediate there;
        // the cap only guards against pathological fd inheritance).
        let eofGrace: TimeInterval = killer.firedReason() == nil ? 30 : 2
        let sawEOF = await collector.waitForEOF(timeout: eofGrace)
        if !sawEOF {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
        }

        let (stdout, stderrTail) = collector.snapshot()
        let killReason = killer.firedReason()
        return Outcome(
            exitStatus: killReason == nil ? process.terminationStatus : nil,
            terminationReason: process.terminationReason,
            stdout: stdout,
            stderrTail: stderrTail,
            timedOut: killReason == .timeout,
            cancelled: killReason == .cancellation
        )
    }

}

/// SIGTERM, 5 s grace, SIGKILL — used by both the timeout and cancellation
/// paths; records which one fired first.
private final class ProcessKiller: @unchecked Sendable {
    enum Reason: Equatable { case timeout, cancellation }

    private let lock = NSLock()
    private let process: Process
    private let exited: () -> Bool

    private var fired: Reason?

    /// `exited` reports whether the child's termination handler already ran —
    /// a kill firing after natural exit must not poison the outcome
    /// (timedOut=true over a clean exit-0) nor signal a stale/reused pid
    /// (impl audit M1). The exit gate is race-correct where Process.isRunning
    /// is not: it flips exactly when terminationHandler runs.
    init(process: Process, exited: @escaping @Sendable () -> Bool) {
        self.process = process
        self.exited = exited
    }

    func kill(reason: Reason) {
        lock.lock()
        guard fired == nil else {
            lock.unlock()
            return
        }
        guard !exited() else {
            lock.unlock()
            return
        }
        fired = reason
        lock.unlock()
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        Darwin.kill(pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + SubprocessRunner.sigkillGraceSeconds) { [process] in
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    func firedReason() -> Reason? {
        lock.lock()
        defer { lock.unlock() }
        return fired
    }
}

private final class StreamCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderrRing = Data()
    private var stdoutDone = false
    private var stderrDone = false
    private var eofGates: [OneShotGate] = []

    func appendStdout(_ chunk: Data) {
        lock.lock()
        stdout.append(chunk)
        lock.unlock()
    }

    func appendStderr(_ chunk: Data) {
        lock.lock()
        stderrRing.append(chunk)
        if stderrRing.count > SubprocessRunner.stderrRingCapacity {
            stderrRing.removeFirst(stderrRing.count - SubprocessRunner.stderrRingCapacity)
        }
        lock.unlock()
    }

    func finishStdout() { finish { self.stdoutDone = true } }
    func finishStderr() { finish { self.stderrDone = true } }

    private func finish(_ mark: () -> Void) {
        lock.lock()
        mark()
        let resumable = (stdoutDone && stderrDone) ? eofGates : []
        if !resumable.isEmpty { eofGates.removeAll() }
        lock.unlock()
        for gate in resumable { gate.open() }
    }

    /// Waits for EOF on both streams, up to `timeout`. Returns whether EOF
    /// was actually observed.
    func waitForEOF(timeout: TimeInterval) async -> Bool {
        let gate = OneShotGate()
        if !registerEOFGate(gate) { return true }

        let timer = Task.detached {
            try? await Task.sleep(for: .seconds(timeout))
            gate.open()  // idempotent; a real EOF beats it harmlessly
        }
        defer { timer.cancel() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            gate.whenOpen { continuation.resume() }
        }
        return eofObserved()
    }

    /// Returns false if EOF already happened (no registration needed).
    private func registerEOFGate(_ gate: OneShotGate) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if stdoutDone && stderrDone { return false }
        eofGates.append(gate)
        return true
    }

    private func eofObserved() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stdoutDone && stderrDone
    }

    func snapshot() -> (stdout: Data, stderrTail: String) {
        lock.lock()
        defer { lock.unlock() }
        return (stdout, String(decoding: stderrRing, as: UTF8.self))
    }
}
