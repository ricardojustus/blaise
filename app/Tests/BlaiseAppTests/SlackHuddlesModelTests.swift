import BlaiseCore
import Foundation
import Synchronization
import Testing

@testable import BlaiseApp

// C15: the settings/connect model — validation failure paths, disconnect
// clears the Keychain, and the epoch guard (a connect that resolves after
// Disconnect cannot resurrect the connection — the Google-model lesson).

@MainActor
struct SlackHuddlesModelTests {
    private func makeModel(
        client: SlackSocketClient
    ) throws -> (SlackHuddlesModel, InMemorySecretStore, SettingsStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("blaise-slack-tests-\(UUID().uuidString)")
        let database = try BlaiseDatabase(rootURL: root)
        let settings = SettingsStore(database: database)
        let secrets = InMemorySecretStore()
        let tracker = SlackHuddleTracker(selfUserID: "", emitter: NoopMeetBatchIngestor())
        let model = SlackHuddlesModel(
            settings: settings, secrets: secrets, tracker: tracker, client: client)
        return (model, secrets, settings)
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
        model.handleSocketStatus(.sessionEnded(healthy: false))
        #expect(model.lastError == nil)
        model.handleSocketStatus(.sessionEnded(healthy: false))
        model.handleSocketStatus(.sessionEnded(healthy: false))
        #expect(model.lastError == SlackHuddlesModel.reconnectFailureMessage)
        // A healthy session clears it.
        model.handleSocketStatus(.connected)
        #expect(model.lastError == nil)
        #expect(model.socketLive)
        await model.disconnect()
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
