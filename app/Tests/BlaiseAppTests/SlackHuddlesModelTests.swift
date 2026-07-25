import BlaiseCore
import Foundation
import Synchronization
import Testing

@testable import BlaiseApp

// C15: the settings/connect model — validation failure paths, disconnect
// clears the Keychain, and the epoch guard (a connect that resolves after
// Disconnect cannot resurrect the connection — the Google-model lesson).

/// Records every batch the tracker emits, so the model's lifecycle wiring is
/// observable behaviorally (does the tracker still listen?) rather than by
/// reaching into private state.
private final class LifecycleRecorder: MeetBatchIngesting, @unchecked Sendable {
    private let store = Mutex<[MeetWireBatch]>([])
    func ingest(batch: MeetWireBatch) async { store.withLock { $0.append(batch) } }
    var count: Int { store.withLock { $0.count } }
}

/// Structural mirror of the model's private settings record. Decoding this from
/// the settings store lets a test observe that a lifecycle Task ran to
/// COMPLETION: persisting settings is the Task's last action, so every step
/// before it — the tracker identity push/clear, the socket start/stop — has
/// already happened.
///
/// Two traps this shape exists to avoid. (1) Polling `model.enabled` does not
/// work at all: it is assigned SYNCHRONOUSLY before the Task starts, so the
/// condition is true immediately and the wait is a no-op. (2) Polling persisted
/// `enabled` for a value it ALREADY holds is the same no-op one level down —
/// the poll evaluates its condition before its first sleep, so a settle that
/// merely re-observes existing state returns without waiting. Waits that need
/// to observe a TRANSITION key on `memberID` instead, which only the surviving
/// lifecycle task can write.
private struct PersistedSlackSettings: Codable {
    var enabled: Bool
    var memberID: String
}

@MainActor
struct SlackHuddlesModelTests {
    private func makeModel(
        client: SlackSocketClient
    ) throws -> (SlackHuddlesModel, InMemorySecretStore, SettingsStore) {
        let (model, secrets, settings, _) = try makeModelWithTracker(client: client)
        return (model, secrets, settings)
    }

    /// Same as `makeModel` but also returns the tracker, so tests can assert
    /// the model's lifecycle actually reaches it (enable/disable identity
    /// pushes). Without this seam the disable/re-enable wiring is unobservable:
    /// deleting it left the whole suite green.
    private func makeModelWithTracker(
        client: SlackSocketClient
    ) throws -> (SlackHuddlesModel, InMemorySecretStore, SettingsStore, SlackHuddleTracker) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("blaise-slack-tests-\(UUID().uuidString)")
        let database = try BlaiseDatabase(rootURL: root)
        let settings = SettingsStore(database: database)
        let secrets = InMemorySecretStore()
        let tracker = SlackHuddleTracker(selfUserID: "", emitter: lifecycleRecorder)
        let model = SlackHuddlesModel(
            settings: settings, secrets: secrets, tracker: tracker, client: client)
        return (model, secrets, settings, tracker)
    }

    /// Records batches emitted by the tracker, so a test can observe whether
    /// the tracker is actually listening (identity pushed) rather than
    /// inspecting private state.
    private let lifecycleRecorder = LifecycleRecorder()

    /// A huddle event for a self member id (defaults to the one the tests
    /// configure at connect).
    private func selfHuddleEvent(
        memberID: String = "U012AB3CD", callID: String?, inHuddle: Bool, ts: String
    ) -> SlackHuddleEvent {
        SlackHuddleEvent(
            type: SlackHuddleEvent.huddleChangedType,
            user: SlackUser(
                id: memberID, name: nil,
                profile: SlackUserProfile(
                    displayName: nil, realName: nil,
                    huddleState: inHuddle ? SlackHuddleEvent.inHuddleState : "default_unset",
                    huddleStateExpirationTs: nil, huddleStateCallID: callID)),
            eventTS: ts)
    }

    /// Routes auth.test / apps.connections.open to ok responses.
    private var okTransport: SlackSocketClient.HTTPTransport {
        { request in
            if request.url?.path.contains("auth.test") == true {
                return http200(#"{"ok":true,"team":"Acme","user_id":"U012AB3CD"}"#)
            }
            return http200(#"{"ok":true,"url":"wss://example"}"#)
        }
    }

    private func parkingClient(transport: @escaping SlackSocketClient.HTTPTransport) -> SlackSocketClient {
        SlackSocketClient(
            transport: transport,
            opener: { _ in ParkingChannel() },
            backoffSleep: { _ in try await Task.sleep(for: .seconds(3600)) },
            pingSleep: { _ in try await Task.sleep(for: .seconds(3600)) })
    }

    @Test("connect refuses when a token is missing")
    func missingTokens() async throws {
        let (model, secrets, _) = try makeModel(client: parkingClient(transport: okTransport))
        model.appToken = ""
        model.botToken = "xoxb-x"
        model.memberID = "U012AB3CD"
        await model.connect()
        #expect(model.lastError != nil)
        #expect(!model.connected)
        #expect(try secrets.get(key: SlackHuddlesModel.appTokenKey) == nil)
    }

    @Test("connect refuses a malformed member id")
    func badMemberID() async throws {
        let (model, _, _) = try makeModel(client: parkingClient(transport: okTransport))
        model.appToken = "xapp-x"
        model.botToken = "xoxb-x"
        model.memberID = "not-an-id"
        await model.connect()
        #expect(model.lastError != nil)
        #expect(!model.connected)
    }

    @Test("an auth.test rejection surfaces and stores nothing")
    func authRejected() async throws {
        let client = parkingClient(transport: { _ in http200(#"{"ok":false,"error":"not_authed"}"#) })
        let (model, secrets, _) = try makeModel(client: client)
        model.appToken = "xapp-x"
        model.botToken = "xoxb-x"
        model.memberID = "U012AB3CD"
        await model.connect()
        #expect(model.lastError != nil)
        #expect(!model.connected)
        #expect(try secrets.get(key: SlackHuddlesModel.appTokenKey) == nil)
        #expect(try secrets.get(key: SlackHuddlesModel.botTokenKey) == nil)
    }

    @Test("connect stores both tokens; disconnect clears them")
    func connectThenDisconnect() async throws {
        let (model, secrets, _) = try makeModel(client: parkingClient(transport: okTransport))
        model.appToken = "xapp-good"
        model.botToken = "xoxb-good"
        model.memberID = "U012AB3CD"
        await model.connect()
        #expect(model.connected)
        #expect(model.workspaceName == "Acme")
        #expect(try secrets.get(key: SlackHuddlesModel.appTokenKey) == "xapp-good")
        #expect(try secrets.get(key: SlackHuddlesModel.botTokenKey) == "xoxb-good")

        await model.disconnect()
        #expect(!model.connected)
        #expect(try secrets.get(key: SlackHuddlesModel.appTokenKey) == nil)
        #expect(try secrets.get(key: SlackHuddlesModel.botTokenKey) == nil)
    }

    @Test("reconnect with new tokens tears down the old socket and opens with the new app token")
    func tokenRotation() async throws {
        let rec = SocketRecorder()
        let client = SlackSocketClient(
            transport: rec.transport, opener: rec.opener,
            backoffSleep: { _ in try await Task.sleep(for: .seconds(3600)) },
            pingSleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        let (model, _, _) = try makeModel(client: client)
        model.appToken = "xapp-A"
        model.botToken = "xoxb-A"
        model.memberID = "U012AB3CD"
        await model.connect()
        #expect(model.connected)
        _ = await waitUntilApp { rec.channels.withLock { $0.count } >= 1 }

        // Reconnect with rotated tokens.
        model.appToken = "xapp-B"
        model.botToken = "xoxb-B"
        await model.connect()
        _ = await waitUntilApp { rec.channels.withLock { $0.count } >= 2 }

        #expect(rec.channels.withLock { $0[0] }.wasCancelled)  // old socket torn down
        #expect(rec.openAppTokens.withLock { $0.last } == "Bearer xapp-B")  // new socket uses B
        await model.disconnect()
    }

    @Test("status reflects connection health; a persistent no-hello loop surfaces an error")
    func connectionHealthStatus() async throws {
        let (model, _, _) = try makeModel(client: parkingClient(transport: okTransport))
        model.appToken = "xapp"
        model.botToken = "xoxb"
        model.memberID = "U012AB3CD"
        await model.connect()
        #expect(model.connected)
        #expect(model.statusTitle == "Connecting…")  // tokens set, no hello yet
        model.handleSocketStatus(.connected)
        #expect(model.socketLive)
        #expect(model.statusTitle == "Connected")
        // Three sessions that never reach hello → surface the persistent failure.
        model.handleSocketStatus(.sessionEnded(healthy: false, networkDown: false))
        #expect(model.lastError == nil)
        model.handleSocketStatus(.sessionEnded(healthy: false, networkDown: false))
        model.handleSocketStatus(.sessionEnded(healthy: false, networkDown: false))
        #expect(model.lastError == SlackHuddlesModel.reconnectFailureMessage)
        // A healthy session clears it.
        model.handleSocketStatus(.connected)
        #expect(model.lastError == nil)
        #expect(model.socketLive)
        await model.disconnect()
    }

    @Test("offline sessions are neutral: a Wi-Fi blip never surfaces the revoked-tokens banner")
    func offlineSessionsAreNeutral() async throws {
        let (model, _, _) = try makeModel(client: parkingClient(transport: okTransport))
        model.appToken = "xapp"
        model.botToken = "xoxb"
        model.memberID = "U012AB3CD"
        await model.connect()
        // Any number of connectivity-class failures must not accumulate toward
        // the banner (offline says nothing about the Slack app or its tokens)…
        for _ in 0 ..< 6 {
            model.handleSocketStatus(.sessionEnded(healthy: false, networkDown: true))
        }
        #expect(model.lastError == nil)
        // …and must not RESET a genuine no-hello streak either: two real
        // failures + an offline blip + a third real failure still surfaces it.
        model.handleSocketStatus(.sessionEnded(healthy: false, networkDown: false))
        model.handleSocketStatus(.sessionEnded(healthy: false, networkDown: false))
        model.handleSocketStatus(.sessionEnded(healthy: false, networkDown: true))
        #expect(model.lastError == nil)
        model.handleSocketStatus(.sessionEnded(healthy: false, networkDown: false))
        #expect(model.lastError == SlackHuddlesModel.reconnectFailureMessage)
        await model.disconnect()
    }

    @Test("disable stops the tracker listening; re-enable restores it")
    func disableAndReEnableWireTracker() async throws {
        let (model, _, settings, tracker) = try makeModelWithTracker(
            client: parkingClient(transport: okTransport))
        model.appToken = "xapp"
        model.botToken = "xoxb"
        model.memberID = "U012AB3CD"
        await model.connect()
        #expect(model.connected)

        // Baseline: the tracker has the identity and reacts to a self event.
        await tracker.handle(selfHuddleEvent(callID: "R1", inHuddle: true, ts: "1000.1"), at: Date())
        let afterConnect = lifecycleRecorder.count
        #expect(afterConnect > 0)

        // Disable → the tracker is cleared, so a fresh event is ignored.
        model.setEnabled(false)
        #expect(await settleLifecycle(settings, enabled: false), "lifecycle task never settled")
        await tracker.handle(selfHuddleEvent(callID: "R2", inHuddle: true, ts: "2000.1"), at: Date())
        #expect(lifecycleRecorder.count == afterConnect, "disabled ⇒ tracker deaf")

        // Re-enable → the member id is pushed back and events land again.
        model.setEnabled(true)
        #expect(await settleLifecycle(settings, enabled: true), "lifecycle task never settled")
        await tracker.handle(selfHuddleEvent(callID: "R3", inHuddle: true, ts: "3000.1"), at: Date())
        #expect(lifecycleRecorder.count > afterConnect, "re-enabled ⇒ tracker listening again")
        await model.disconnect()
    }

    @Test("a rapid disable→enable toggle cannot leave the tracker deaf (lifecycle epoch)")
    func rapidToggleKeepsTrackerListening() async throws {
        let (model, _, settings, tracker) = try makeModelWithTracker(
            client: parkingClient(transport: okTransport))
        model.appToken = "xapp"
        model.botToken = "xoxb"
        model.memberID = "U012AB3CD"
        await model.connect()
        let baseline = lifecycleRecorder.count

        // Change the member id so the settle observes a TRANSITION. Waiting on
        // `enabled: true` here would not wait at all — connect() already
        // persisted it — and the test would then assert against a tracker the
        // lifecycle tasks had not finished touching, passing vacuously with the
        // epoch guards reverted.
        model.memberID = "U987ZY6XW"

        // Both toggles issued before either unstructured Task completes: the
        // stale disable must not clear the identity the re-enable just pushed.
        model.setEnabled(false)
        model.setEnabled(true)
        #expect(
            await settleLifecycle(settings, memberID: "U987ZY6XW"),
            "the surviving lifecycle task never completed")

        await tracker.handle(
            selfHuddleEvent(memberID: "U987ZY6XW", callID: "R9", inHuddle: true, ts: "9000.1"),
            at: Date())
        #expect(
            lifecycleRecorder.count > baseline,
            "final state is enabled ⇒ the tracker must still be listening")
        #expect(model.enabled)
        await model.disconnect()
    }

    /// Waits for a lifecycle Task to run to COMPLETION by observing the
    /// persisted settings — the Task's final action, so every earlier step is
    /// guaranteed done. Never `_ =`-discard the result: a poll that times out
    /// returns false, and in a test whose assertion is "nothing happened" a
    /// silent timeout reads exactly like success.
    private func settleLifecycle(_ settings: SettingsStore, enabled expected: Bool) async -> Bool {
        await waitUntilApp {
            let persisted = try? await settings.get(
                SlackHuddlesModel.settingsKey, as: PersistedSlackSettings.self)
            return (persisted ?? nil)?.enabled == expected
        }
    }

    /// Waits for a TRANSITION rather than a state. Use when the value being
    /// waited on may already hold the expected result — `settleLifecycle` would
    /// then return without waiting at all, because the poll evaluates its
    /// condition before its first sleep. Only the surviving lifecycle task can
    /// persist the new member id, so seeing it proves that task completed.
    private func settleLifecycle(_ settings: SettingsStore, memberID expected: String) async -> Bool
    {
        await waitUntilApp {
            let persisted = try? await settings.get(
                SlackHuddlesModel.settingsKey, as: PersistedSlackSettings.self)
            return (persisted ?? nil)?.memberID == expected
        }
    }

    @Test("INVARIANT: no socket is opened while the integration is disabled")
    func disabledNeverOpensASocket() async throws {
        let rec = SocketRecorder()
        let client = SlackSocketClient(
            transport: rec.transport, opener: rec.opener,
            backoffSleep: { _ in try await Task.sleep(for: .seconds(3600)) },
            pingSleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        let (model, _, settings, _) = try makeModelWithTracker(client: client)
        model.appToken = "xapp"
        model.botToken = "xoxb"
        model.memberID = "U012AB3CD"
        await model.connect()
        _ = await waitUntilApp { rec.channels.withLock { $0.count } >= 1 }
        let afterConnect = rec.channels.withLock { $0.count }

        model.setEnabled(false)
        #expect(await settleLifecycle(settings, enabled: false), "lifecycle task never settled")

        // Drives the reachable disabled-state doors: the launch path, and a
        // toggle pair whose final state is OFF. This pins the INVARIANT, not
        // one specific guard — the pre-mutation epoch checks in `setEnabled`
        // already stop a stale enable before it reaches `startSocket`, so that
        // method's own `enabled` precondition is defense-in-depth. Both layers
        // are cheap; the invariant is what must hold.
        model.startIfEnabled()
        model.setEnabled(true)
        model.setEnabled(false)
        #expect(await settleLifecycle(settings, enabled: false), "lifecycle task never settled")
        // Give any stale task room to do the wrong thing before asserting.
        _ = await waitUntilApp(timeout: .milliseconds(300)) {
            rec.channels.withLock { $0.count } > afterConnect
        }
        #expect(
            rec.channels.withLock { $0.count } == afterConnect,
            "disabled ⇒ no new socket channel may be opened by any path")
        await model.disconnect()
    }

    @Test("disconnect supersedes an in-flight enable (lifecycle epoch)")
    func disconnectSupersedesInFlightEnable() async throws {
        let rec = SocketRecorder()
        let client = SlackSocketClient(
            transport: rec.transport, opener: rec.opener,
            backoffSleep: { _ in try await Task.sleep(for: .seconds(3600)) },
            pingSleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        let (model, secrets, _, tracker) = try makeModelWithTracker(client: client)
        model.appToken = "xapp"
        model.botToken = "xoxb"
        model.memberID = "U012AB3CD"
        await model.connect()
        _ = await waitUntilApp { rec.channels.withLock { $0.count } >= 1 }
        let afterConnect = rec.channels.withLock { $0.count }
        let baseline = lifecycleRecorder.count

        // Enable issued, then a disconnect lands before its task settles: the
        // disconnect's epoch bump must supersede the enable's post-await half.
        model.setEnabled(true)
        await model.disconnect()
        _ = await waitUntilApp(timeout: .milliseconds(300)) {
            rec.channels.withLock { $0.count } > afterConnect
        }

        #expect(!model.enabled)
        #expect(!model.connected)
        #expect(
            rec.channels.withLock { $0.count } == afterConnect,
            "a superseded enable must not open a socket after disconnect")
        #expect(try secrets.get(key: SlackHuddlesModel.appTokenKey) == nil)
        #expect(try secrets.get(key: SlackHuddlesModel.botTokenKey) == nil)
        // And the tracker is deaf: a self event after disconnect emits nothing.
        await tracker.handle(selfHuddleEvent(callID: "RX", inHuddle: true, ts: "7000.1"), at: Date())
        #expect(lifecycleRecorder.count == baseline)
    }

    @Test("URLError connectivity classification")
    func connectivityErrorClassification() {
        #expect(SlackSocketClient.isConnectivityError(URLError(.notConnectedToInternet)))
        #expect(SlackSocketClient.isConnectivityError(URLError(.networkConnectionLost)))
        #expect(SlackSocketClient.isConnectivityError(URLError(.dnsLookupFailed)))
        // Auth-shaped and protocol-shaped failures still count toward the streak.
        #expect(!SlackSocketClient.isConnectivityError(URLError(.userAuthenticationRequired)))
        #expect(!SlackSocketClient.isConnectivityError(URLError(.badServerResponse)))
        #expect(!SlackSocketClient.isConnectivityError(SlackClientError.api("invalid_auth")))
    }

    @Test("a Keychain read failure at load surfaces through settingsError")
    func keychainReadFailureSurfaces() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("blaise-slack-tests-\(UUID().uuidString)")
        let database = try BlaiseDatabase(rootURL: root)
        let tracker = SlackHuddleTracker(selfUserID: "", emitter: NoopMeetBatchIngestor())
        let model = SlackHuddlesModel(
            settings: SettingsStore(database: database), secrets: FailingReadStore(),
            tracker: tracker, client: parkingClient(transport: okTransport))
        await model.load()
        #expect(model.settingsError != nil)
    }

    @Test("a connect that resolves after Disconnect cannot resurrect (epoch guard)")
    func epochGuard() async throws {
        let gate = Gate()
        let entered = Mutex(false)
        let transport: SlackSocketClient.HTTPTransport = { request in
            entered.withLock { $0 = true }
            await gate.wait()
            if request.url?.path.contains("auth.test") == true {
                return http200(#"{"ok":true,"team":"Acme"}"#)
            }
            return http200(#"{"ok":true,"url":"wss://example"}"#)
        }
        let (model, secrets, _) = try makeModel(client: parkingClient(transport: transport))
        model.appToken = "xapp-good"
        model.botToken = "xoxb-good"
        model.memberID = "U012AB3CD"

        let connectTask = Task { await model.connect() }
        _ = await waitUntilApp { entered.withLock { $0 } }
        // Disconnect lands while validation is still in flight.
        await model.disconnect()
        // Now let the (already-superseded) validation succeed.
        await gate.open()
        await connectTask.value

        #expect(!model.connected)  // the late success did not resurrect
        #expect(try secrets.get(key: SlackHuddlesModel.appTokenKey) == nil)
        #expect(try secrets.get(key: SlackHuddlesModel.botTokenKey) == nil)
    }
}

/// A no-op channel: parks on receive until cancelled (for connect paths that
/// start the socket without a live network).
private final class ParkingChannel: SlackWebSocketChannel, @unchecked Sendable {
    func receiveText() async throws -> String {
        try await Task.sleep(for: .seconds(3600))
        throw CancellationError()
    }
    func sendText(_ text: String) async throws {}
    func sendPing() async throws {}
    func cancel() {}
}

/// Records the app tokens each `apps.connections.open` used and every channel
/// the opener handed out — for the token-rotation test.
private final class SocketRecorder: @unchecked Sendable {
    let openAppTokens = Mutex<[String]>([])
    let channels = Mutex<[RecordingChannel]>([])

    var transport: SlackSocketClient.HTTPTransport {
        { request in
            let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
            if request.url?.path.contains("apps.connections.open") == true {
                self.openAppTokens.withLock { $0.append(auth) }
                return http200(#"{"ok":true,"url":"wss://example"}"#)
            }
            return http200(#"{"ok":true,"team":"Acme"}"#)  // auth.test
        }
    }

    var opener: SlackSocketClient.SocketOpener {
        { _ in
            let channel = RecordingChannel()
            self.channels.withLock { $0.append(channel) }
            return channel
        }
    }
}

/// A parking channel that records whether it was cancelled (torn down).
private final class RecordingChannel: SlackWebSocketChannel, @unchecked Sendable {
    private let cancelledFlag = Mutex(false)
    var wasCancelled: Bool { cancelledFlag.withLock { $0 } }

    func receiveText() async throws -> String {
        try await Task.sleep(for: .seconds(3600))
        throw CancellationError()
    }
    func sendText(_ text: String) async throws {}
    func sendPing() async throws {}
    func cancel() { cancelledFlag.withLock { $0 = true } }
}

private struct SlackTestError: Error {}

/// A secret store whose reads always fail (the Keychain-glitch path).
private final class FailingReadStore: SecretStore, @unchecked Sendable {
    func get(key: String) throws -> String? { throw SlackTestError() }
    func set(key: String, value: String) throws {}
    func delete(key: String) throws {}
}

/// A one-shot gate the epoch test opens to release a stalled transport.
actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
