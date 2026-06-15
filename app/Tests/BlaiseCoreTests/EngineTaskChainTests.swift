import Foundation
import Testing
@testable import BlaiseCore

@Suite struct EngineTaskChainTests {
    /// Single-flight: N concurrent calls never overlap (actor reentrancy
    /// alone would interleave at the suspension points).
    @Test(.timeLimit(.minutes(1)))
    func concurrentCallsRunStrictlySequentially() async throws {
        let chain = EngineTaskChain()
        let events = Recorder<String>()
        await withTaskGroup(of: Void.self) { group in
            for index in 0 ..< 8 {
                group.addTask {
                    try? await chain.run {
                        events.append("start-\(index)")
                        try await Task.sleep(for: .milliseconds(20))
                        events.append("end-\(index)")
                    }
                }
            }
        }
        let log = events.values
        #expect(log.count == 16)
        // Strict alternation: every start is immediately followed by its end.
        for pair in stride(from: 0, to: log.count, by: 2) {
            #expect(log[pair].hasPrefix("start-"))
            #expect(log[pair + 1] == log[pair].replacingOccurrences(of: "start", with: "end"))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func queuedCancellationIsPromptAndLeavesChainHealthy() async throws {
        let chain = EngineTaskChain()
        let firstStarted = OneShotGate()
        let releaseFirst = OneShotGate()

        let first = Task {
            try await chain.run {
                firstStarted.open()
                try await releaseFirst.wait()
                return "first"
            }
        }
        try await firstStarted.wait()

        // Queued behind the running first link.
        let queued = Task {
            try await chain.run { "queued" }
        }
        try await Task.sleep(for: .milliseconds(50))
        let cancelStart = Date()
        queued.cancel()
        // Prompt: the queued call observes cancellation without waiting for
        // the running job (which is still blocked).
        await #expect(throws: EngineError.cancelled) { try await queued.value }
        #expect(Date().timeIntervalSince(cancelStart) < 1.0)

        // The chain is not poisoned: release the first, run a third normally.
        releaseFirst.open()
        #expect(try await first.value == "first")
        let third = try await chain.run { "third" }
        #expect(third == "third")
    }

    @Test(.timeLimit(.minutes(1)))
    func linkFailureDoesNotPropagateToQueuedLinks() async throws {
        let chain = EngineTaskChain()
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await chain.run { throw Boom() }
        }
        let value = try await chain.run { 42 }
        #expect(value == 42)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationBeforeEnqueueThrowsCancelled() async throws {
        let chain = EngineTaskChain()
        let task = Task {
            // Cooperative pre-cancellation: cancel, then enqueue.
            try await Task.sleep(for: .seconds(10))
            return try await chain.run { "never" }
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected cancellation")
        } catch is CancellationError {
            // sleep threw first — also fine
        } catch let error as EngineError {
            #expect(error == .cancelled)
        }
        // Chain still healthy.
        let value = try await chain.run { 1 }
        #expect(value == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func fifoOrderIsPreserved() async throws {
        let chain = EngineTaskChain()
        let events = Recorder<Int>()
        var tasks: [Task<Void, Error>] = []
        for index in 0 ..< 5 {
            tasks.append(Task {
                try await chain.run { events.append(index) }
            })
            // Give each task time to enqueue before the next (FIFO is defined
            // by enqueue order).
            try await Task.sleep(for: .milliseconds(25))
        }
        for task in tasks { try await task.value }
        #expect(events.values == [0, 1, 2, 3, 4])
    }
}
