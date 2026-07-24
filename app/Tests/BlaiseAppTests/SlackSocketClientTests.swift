import BlaiseCore
import Foundation
import Synchronization
import Testing

@testable import BlaiseApp

// C15: the Socket Mode client's protocol handling with a stubbed transport +
// channel — connections.open non-ok, ack-before-process ordering, disconnect →
// reconnect, and the backoff cap.

func http200(_ json: String) -> (Data, HTTPURLResponse) {
    let response = HTTPURLResponse(
        url: URL(string: "https://slack.com/api/x")!, statusCode: 200, httpVersion: nil,
        headerFields: nil)!
    return (Data(json.utf8), response)
}

/// A scripted text-frame channel. Yields queued frames in order; once drained,
/// `receiveText` parks until the task is cancelled. Every send is logged so a
/// test can assert ack-before-process ordering.
private final class StubChannel: SlackWebSocketChannel, @unchecked Sendable {
    let log = Mutex<[String]>([])
    private let frames: Mutex<[String]>

    init(frames: [String]) {
        self.frames = Mutex(frames)
    }

    func receiveText() async throws -> String {
        if let next = frames.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) {
            return next
        }
        // Drained: park until cancelled (a healthy idle socket).
        try await Task.sleep(for: .seconds(3600))
        throw CancellationError()
    }

    func sendText(_ text: String) async throws {
        log.withLock { $0.append("send:\(text)") }
    }

    func sendPing() async throws {
        log.withLock { $0.append("ping") }
    }

    func cancel() {}
}

/// A channel whose `receiveText` parks on a continuation that DELIBERATELY
/// ignores Swift task cancellation and resumes only when `cancel()` is called —
/// reproducing `URLSessionWebSocketTask.receive()`. A cooperative Task.sleep
/// stub would mask the teardown bug this exercises.
private final class NonCooperativeChannel: SlackWebSocketChannel, @unchecked Sendable {
    private struct State {
        var cancelled = false
        var parked: CheckedContinuation<String, any Error>?
        var isParked = false
    }
    private let state = Mutex(State())
    private let frames: Mutex<[String]>

    init(frames: [String]) {
        self.frames = Mutex(frames)
    }

    var wasCancelled: Bool { state.withLock { $0.cancelled } }
    var isParked: Bool { state.withLock { $0.isParked } }

    func receiveText() async throws -> String {
        if let next = frames.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) { return next }
        return try await withCheckedThrowingContinuation { continuation in
            let alreadyCancelled = state.withLock { s -> Bool in
                if s.cancelled { return true }
                s.parked = continuation
                s.isParked = true
                return false
            }
            if alreadyCancelled { continuation.resume(throwing: CancellationError()) }
        }
    }

    func sendText(_ text: String) async throws {}
    func sendPing() async throws {}

    func cancel() {
        let continuation = state.withLock { s -> CheckedContinuation<String, any Error>? in
            s.cancelled = true
            s.isParked = false
            let parked = s.parked
            s.parked = nil
            return parked
        }
        continuation?.resume(throwing: CancellationError())
    }
}

private let helloFrame = #"{"type":"hello"}"#
private let disconnectFrame = #"{"type":"disconnect","reason":"link_disabled"}"#
private let eventFrame = """
    {"envelope_id":"env-1","type":"events_api","payload":{"event":{
      "type":"user_huddle_changed",
      "user":{"id":"U012AB3CD","profile":{"huddle_state":"in_a_huddle","huddle_state_call_id":"R1"}},
      "event_ts":"1.1"}}}
    """

@Suite("C15 SlackSocketClient")
struct SlackSocketClientTests {
    @Test("apps.connections.open non-ok surfaces the Slack error")
    func connectionsOpenNonOk() async {
        let client = SlackSocketClient(
            transport: { _ in http200(#"{"ok":false,"error":"invalid_auth"}"#) },
            opener: { _ in StubChannel(frames: []) })
        await #expect(throws: SlackClientError.self) {
            _ = try await client.openConnection(appToken: "xapp-bad")
        }
    }

    @Test("auth.test non-ok throws; ok returns the workspace")
    func authTest() async throws {
        let okClient = SlackSocketClient(
            transport: { _ in http200(#"{"ok":true,"team":"Acme","user_id":"U1"}"#) },
            opener: { _ in StubChannel(frames: []) })
        let auth = try await okClient.authTest(botToken: "xoxb-good")
        #expect(auth.team == "Acme")

        let badClient = SlackSocketClient(
            transport: { _ in http200(#"{"ok":false,"error":"not_authed"}"#) },
            opener: { _ in StubChannel(frames: []) })
        await #expect(throws: SlackClientError.self) {
            _ = try await badClient.authTest(botToken: "xoxb-bad")
        }
    }

    @Test("events_api envelope is acked BEFORE the event is processed")
    func ackBeforeProcess() async {
        let channel = StubChannel(frames: [helloFrame, eventFrame, disconnectFrame])
        let openCount = Mutex(0)
        let second = StubChannel(frames: [])
        let client = SlackSocketClient(
            transport: { _ in http200(#"{"ok":true,"url":"wss://example"}"#) },
            opener: { _ in
                let n = openCount.withLock { $0 += 1; return $0 }
                return n == 1 ? channel : second
            },
            backoffSleep: { _ in },  // immediate
            pingSleep: { _ in try await Task.sleep(for: .seconds(3600)) })  // no pings
        let processed = Mutex<[String]>([])
        let runTask = Task {
            await client.run(appToken: "xapp", botToken: "xoxb") { event in
                channel.log.withLock { $0.append("process:\(event.user.id)") }
                processed.withLock { $0.append(event.user.id) }
            }
        }
        // The disconnect frame triggers a reconnect → the opener is called twice.
        _ = await waitUntilApp { openCount.withLock { $0 } >= 2 }
        runTask.cancel()

        #expect(processed.withLock { $0 } == ["U012AB3CD"])
        let log = channel.log.withLock { $0 }
        let ackIndex = log.firstIndex { $0.contains("env-1") }
        let processIndex = log.firstIndex { $0.hasPrefix("process:") }
        #expect(ackIndex != nil)
        #expect(processIndex != nil)
        if let ackIndex, let processIndex {
            #expect(ackIndex < processIndex)  // ACK FIRST
        }
    }

    @Test("a task-cancel promptly cancels the channel and stops delivery")
    func promptTeardown() async {
        // The channel ignores task cancellation (like URLSession); only an
        // explicit channel.cancel() unblocks its receive.
        let channel = NonCooperativeChannel(frames: [helloFrame])
        let client = SlackSocketClient(
            transport: { _ in http200(#"{"ok":true,"url":"wss://example"}"#) },
            opener: { _ in channel },
            backoffSleep: { _ in },
            pingSleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        let processed = Mutex<[String]>([])
        let runTask = Task {
            await client.run(appToken: "xapp", botToken: "xoxb") { event in
                processed.withLock { $0.append(event.user.id) }
            }
        }
        // Wait until it has consumed hello and is blocked on the next receive.
        _ = await waitUntilApp { channel.isParked }
        runTask.cancel()
        await runTask.value  // must return promptly — if teardown hangs, this never completes
        #expect(channel.wasCancelled)
        #expect(processed.withLock { $0 }.isEmpty)  // nothing delivered after teardown
    }

    @Test("run reports hello as connected and a healthy session end")
    func statusReporting() async {
        let channel = StubChannel(frames: [helloFrame, disconnectFrame])
        let openCount = Mutex(0)
        let second = StubChannel(frames: [])
        let client = SlackSocketClient(
            transport: { _ in http200(#"{"ok":true,"url":"wss://example"}"#) },
            opener: { _ in
                let n = openCount.withLock { $0 += 1; return $0 }
                return n == 1 ? channel : second
            },
            backoffSleep: { _ in },
            pingSleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        let statuses = Mutex<[SlackSocketStatus]>([])
        let runTask = Task {
            await client.run(appToken: "xapp", botToken: "xoxb", onEvent: { _ in }) { status in
                statuses.withLock { $0.append(status) }
            }
        }
        _ = await waitUntilApp { statuses.withLock { $0.contains(.sessionEnded(healthy: true, networkDown: false)) } }
        runTask.cancel()
        let seen = statuses.withLock { $0 }
        #expect(seen.first == .connected)
        #expect(seen.contains(.sessionEnded(healthy: true, networkDown: false)))
    }

    @Test("a frame that fails strict decode is still ACKed (no infinite redelivery)")
    func undecodableEnvelopeIsAcked() async {
        // Valid envelope_id, but the nested event is unusable (user has no id),
        // so the strict SlackSocketFrame decode fails.
        let badEnvelope = #"{"envelope_id":"env-9","type":"events_api","payload":{"event":{"type":"user_huddle_changed","user":{}}}}"#
        let channel = StubChannel(frames: [badEnvelope, disconnectFrame])
        let openCount = Mutex(0)
        let second = StubChannel(frames: [])
        let client = SlackSocketClient(
            transport: { _ in http200(#"{"ok":true,"url":"wss://example"}"#) },
            opener: { _ in
                let n = openCount.withLock { $0 += 1; return $0 }
                return n == 1 ? channel : second
            },
            backoffSleep: { _ in },
            pingSleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        let processed = Mutex<[String]>([])
        let runTask = Task {
            await client.run(appToken: "xapp", botToken: "xoxb") { event in
                processed.withLock { $0.append(event.user.id) }
            }
        }
        _ = await waitUntilApp { channel.log.withLock { $0.contains { $0.contains("env-9") } } }
        runTask.cancel()
        #expect(channel.log.withLock { $0.contains { $0.contains("env-9") } })  // ACKed
        #expect(processed.withLock { $0 }.isEmpty)  // undecodable → not delivered
    }

    @Test("backoff doubles and caps at 60 s")
    func backoffCap() {
        #expect(SlackSocketClient.nextBackoff(1) == 2)
        #expect(SlackSocketClient.nextBackoff(8) == 16)
        #expect(SlackSocketClient.nextBackoff(32) == 60)  // min(60, 64)
        #expect(SlackSocketClient.nextBackoff(60) == 60)
    }
}

/// Local poll helper (the BlaiseCore `waitUntil` lives in the other target).
func waitUntilApp(
    timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
