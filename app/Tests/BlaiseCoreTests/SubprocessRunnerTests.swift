import Foundation
import Testing
@testable import BlaiseCore

@Suite struct SubprocessRunnerTests {
    private let shell = URL(fileURLWithPath: "/bin/sh")
    private let environment = ["PATH": "/usr/bin:/bin"]

    /// The load-bearing drain contract: > 1 MB on BOTH streams, interleaved,
    /// far past the 64 KB pipe buffer. Read-after-wait would deadlock here.
    @Test(.timeLimit(.minutes(1)))
    func drainsLargeDualStreamOutputWithoutDeadlock() async throws {
        // 1100 KB to stdout and 1100 KB to stderr, interleaved 1 KB at a time.
        let script = """
            i=0
            chunk=$(printf 'a%.0s' $(/usr/bin/seq 1 1024))
            while [ $i -lt 1100 ]; do
                printf '%s' "$chunk"
                printf '%s' "$chunk" >&2
                i=$((i+1))
            done
            """
        let outcome = try await SubprocessRunner.run(
            executable: shell, arguments: ["-c", script], environment: environment, timeout: 50)
        #expect(outcome.exitStatus == 0)
        #expect(outcome.stdout.count == 1100 * 1024)
        #expect(!outcome.timedOut && !outcome.cancelled)
        // stderr keeps only the 4 KB ring tail.
        #expect(outcome.stderrTail.utf8.count <= SubprocessRunner.stderrRingCapacity)
        #expect(outcome.stderrTail.allSatisfy { $0 == "a" })
    }

    /// A child that exits WITHOUT reading its stdin must not kill the
    /// process feeding it. Pre-fix this raised SIGPIPE on the stdin write
    /// (payload > the 64 KB pipe buffer, reader already gone) and took down
    /// the whole app — the 11/06/2026 field crash loop: every launch retried
    /// a stuck handoff delivery whose ssh died before consuming the payload.
    /// Failure mode of a regression here is the TEST RUNNER dying, which is
    /// exactly the point.
    @Test(.timeLimit(.minutes(1)))
    func childExitingWithoutReadingStdinDoesNotRaiseSIGPIPE() async throws {
        let payload = Data(repeating: 0x42, count: 1_000_000)
        let outcome = try await SubprocessRunner.run(
            executable: shell, arguments: ["-c", "exit 3"],
            environment: environment, stdin: payload, timeout: 20)
        #expect(outcome.exitStatus == 3)
        #expect(!outcome.timedOut && !outcome.cancelled)
    }

    @Test func capturesExitStatusAndStderrTail() async throws {
        let outcome = try await SubprocessRunner.run(
            executable: shell, arguments: ["-c", "echo detail >&2; exit 7"],
            environment: environment, timeout: 20)
        #expect(outcome.exitStatus == 7)
        #expect(outcome.stderrTail.contains("detail"))
    }

    @Test(.timeLimit(.minutes(1)))
    func timeoutSendsSIGTERMAndReportsTimedOut() async throws {
        let started = Date()
        let outcome = try await SubprocessRunner.run(
            executable: shell, arguments: ["-c", "sleep 60"], environment: environment, timeout: 1)
        #expect(outcome.timedOut)
        #expect(outcome.exitStatus == nil)
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test(.timeLimit(.minutes(1)))
    func timeoutEscalatesToSIGKILLWhenSIGTERMIsTrapped() async throws {
        let started = Date()
        // Child ignores SIGTERM; only the 5 s SIGKILL escalation can end it.
        let outcome = try await SubprocessRunner.run(
            executable: shell, arguments: ["-c", "trap '' TERM; sleep 60"],
            environment: environment, timeout: 1)
        let elapsed = Date().timeIntervalSince(started)
        #expect(outcome.timedOut)
        #expect(elapsed >= SubprocessRunner.sigkillGraceSeconds - 0.5)
        #expect(elapsed < 30)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationKillsTheProcess() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("runner-cancel-\(UUID().uuidString).pid")
        let script = "echo $$ > '\(pidFile.path)'; sleep 60"
        let task = Task {
            try await SubprocessRunner.run(
                executable: shell, arguments: ["-c", script],
                environment: environment, timeout: 120)
        }
        // Let the child start and write its pid.
        while !FileManager.default.fileExists(atPath: pidFile.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        task.cancel()
        let outcome = try await task.value
        #expect(outcome.cancelled)
        #expect(outcome.exitStatus == nil)
        // The child is really gone (sh defers SIGTERM while waiting on its
        // `sleep` job; the 5 s SIGKILL escalation ends it).
        let pid = Int32(
            try String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        try await Task.sleep(for: .milliseconds(200))
        #expect(kill(pid, 0) == -1)
        try? FileManager.default.removeItem(at: pidFile)
    }

    @Test func spawnFailureThrows() async {
        await #expect(throws: SubprocessRunner.SpawnError.self) {
            _ = try await SubprocessRunner.run(
                executable: URL(fileURLWithPath: "/nonexistent/binary"),
                arguments: [], environment: environment, timeout: 5)
        }
    }
}
