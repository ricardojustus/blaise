import BlaiseCore
import Foundation
import Observation
import os

// C15: the app side of docs/slack_huddles_contract.md — the settings/connect
// model (mirrors GoogleCalendarModel) and the Socket Mode client. The pure
// state machine (SlackHuddleTracker) and wire types (SlackEvents) live in
// BlaiseCore; this file owns the network + Keychain + @Observable surface.
//
// Privacy: bot scope is `users:read` only. Nothing but presence metadata is
// read (who is in a huddle, and when); no message, no audio path. The two
// tokens live in the Keychain and never leave the machine except as Blaise's
// own calls to slack.com.

private struct SlackHuddlesSettings: Codable, Equatable, Sendable {
    var enabled: Bool
    var memberID: String
    /// Workspace name from `auth.test`, cached for the status line.
    var workspaceName: String?

    static let empty = SlackHuddlesSettings(enabled: false, memberID: "", workspaceName: nil)
}

enum SlackClientError: LocalizedError, Sendable, Equatable {
    /// Slack replied `{ok:false, error:"…"}`.
    case api(String)
    case http(status: Int)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .api(let code):
            return "Slack rejected the request (\(code)). Check the token and its scopes."
        case .http(let status):
            return "Slack request failed (HTTP \(status))."
        case .malformed(let detail):
            return "Slack returned an unexpected response: \(detail)"
        }
    }
}

// MARK: - Settings/connect model

@MainActor @Observable
final class SlackHuddlesModel {
    static let settingsKey = "slack.huddles.settings"
    static let appTokenKey = "slack.appToken"
    static let botTokenKey = "slack.botToken"

    var enabled = false
    var memberID = ""
    /// Bound to the two SecureFields; consumed by `connect()` and never
    /// persisted to the settings DB (tokens are Keychain-only).
    var appToken = ""
    var botToken = ""
    private(set) var workspaceName: String?
    private(set) var connected = false
    private(set) var connecting = false
    private(set) var lastError: String?
    /// Settings/Keychain persistence failures, kept separate from `lastError`
    /// so a later success can't silently wipe them (Google-model precedent).
    private(set) var settingsError: String?
    /// Receipt time of the last `user_huddle_changed` event (status line age).
    private(set) var lastEventAt: Date?
    /// True once the running socket has seen a `hello`; false while it is
    /// (re)connecting. Drives the "Connecting…"/"Reconnecting…" status.
    private(set) var socketLive = false

    /// Consecutive reconnect sessions that never reached `hello` — a revoked
    /// token or removed app loops here forever, so after `maxFailedSessions`
    /// the failure is surfaced into `lastError` (mirrors the extension's 3×401
    /// badge rule).
    private var noHelloStreak = 0
    static let maxFailedSessions = 3
    static let reconnectFailureMessage =
        "Slack keeps disconnecting without connecting — the app may have been removed or its tokens revoked. Reconnect with fresh tokens."

    private let settings: SettingsStore
    private let secrets: any SecretStore
    private let client: SlackSocketClient
    private let tracker: SlackHuddleTracker
    private let logger = Logger(subsystem: BlaiseBundle.identifier, category: "slack.huddles")

    /// True while a Keychain read failed at load — an empty token field then
    /// must not be read as "the user cleared the token".
    private var secretLoadFailed = false
    private var connectTask: Task<String?, any Error>?
    private var socketTask: Task<Void, Never>?
    /// Bumped by `cancelConnect()` so a `connect()` that already resolved when a
    /// disconnect landed cannot resurrect the connection (Google epoch-guard
    /// lesson).
    private var connectEpoch = 0

    init(
        settings: SettingsStore,
        secrets: any SecretStore,
        tracker: SlackHuddleTracker,
        client: SlackSocketClient = SlackSocketClient()
    ) {
        self.settings = settings
        self.secrets = secrets
        self.tracker = tracker
        self.client = client
    }

    func load() async {
        let stored =
            (try? await settings.get(Self.settingsKey, as: SlackHuddlesSettings.self))
            ?? nil ?? .empty
        enabled = stored.enabled
        memberID = stored.memberID
        workspaceName = stored.workspaceName
        do {
            appToken = try secrets.get(key: Self.appTokenKey) ?? ""
            botToken = try secrets.get(key: Self.botTokenKey) ?? ""
            secretLoadFailed = false
            settingsError = nil
        } catch {
            // A Keychain read error is not "no tokens": surface it (the fields
            // render blank, which would otherwise be inexplicable) and remember
            // it so a Save can't turn the glitch into token deletion.
            secretLoadFailed = true
            settingsError = "Could not read the saved Slack tokens from the Keychain."
        }
        connected = !appToken.isEmpty && !botToken.isEmpty
        await tracker.setSelfUserID(memberID)
    }

    /// Start the long-lived Socket Mode connection if enabled + connected. Dev
    /// instances on a `BLAISE_DATA_ROOT` override do not connect (unless
    /// `BLAISE_SLACK_SOCKET=1`), the same hygiene as the Meet listener.
    func startIfEnabled() {
        guard enabled, connected else { return }
        startSocket()
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        Task {
            if value {
                startSocket()
            } else {
                await stopSocket()
            }
            await saveSettings()
        }
    }

    func connect() async {
        // Re-entry guard (mirrors GoogleCalendarModel): the UI disables Connect
        // while connecting, but an overlapping call would clobber connectTask.
        guard !connecting else { return }
        appToken = normalizedAppToken
        botToken = normalizedBotToken
        memberID = normalizedMemberID
        guard !appToken.isEmpty, !botToken.isEmpty else {
            lastError = "Paste both the app-level token (xapp-…) and the bot token (xoxb-…) first."
            return
        }
        guard SlackMemberID.isValid(memberID) else {
            lastError = "Enter your Slack member ID (Profile → ⋯ → Copy member ID). It looks like U0123ABCD."
            return
        }
        connecting = true
        defer {
            connecting = false
            connectTask = nil
        }
        let app = appToken
        let bot = botToken
        let epoch = connectEpoch
        let client = self.client
        let task = Task { () -> String? in
            // Validate the bot token (also yields the workspace name) AND the
            // app token (a fresh Socket Mode URL is allocated and discarded —
            // the real socket opens later).
            let auth = try await client.authTest(botToken: bot)
            _ = try await client.openConnection(appToken: app)
            return auth.team
        }
        connectTask = task
        do {
            let team = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard epoch == connectEpoch else {
                // A disconnect landed after validation already succeeded, so
                // cancelling the task was a no-op — the result no longer
                // applies. Do NOT store tokens or reconnect.
                return
            }
            try secrets.set(key: Self.appTokenKey, value: app)
            try secrets.set(key: Self.botTokenKey, value: bot)
            secretLoadFailed = false
            workspaceName = team
            connected = true
            enabled = true
            lastError = nil
            await tracker.setSelfUserID(memberID)
            await saveSettings()
            // Reconnect with rotated tokens: tear the old socket down (awaited)
            // before starting fresh, or it would keep streaming the old
            // workspace forever (startSocket no-ops while a task exists).
            await stopSocket()
            startSocket()
        } catch is CancellationError {
            lastError = nil
        } catch {
            lastError = Self.describe(error)
        }
    }

    /// Abort an in-flight `connect()` and bump the epoch so a late success
    /// cannot resurrect the connection.
    func cancelConnect() {
        connectEpoch += 1
        connectTask?.cancel()
    }

    func disconnect() async {
        // Abort any in-flight connect first — a late validation success must
        // not write fresh tokens and silently undo the disconnect.
        cancelConnect()
        await stopSocket()
        try? secrets.delete(key: Self.appTokenKey)
        try? secrets.delete(key: Self.botTokenKey)
        appToken = ""
        botToken = ""
        workspaceName = nil
        connected = false
        enabled = false
        lastError = nil
        lastEventAt = nil
        await saveSettings()
    }

    func saveSettings() async {
        let snapshot = SlackHuddlesSettings(
            enabled: enabled, memberID: normalizedMemberID, workspaceName: workspaceName)
        memberID = normalizedMemberID
        do {
            try await settings.set(Self.settingsKey, to: snapshot)
            settingsError = nil
        } catch {
            settingsError = Self.describe(error)
        }
    }

    // MARK: - Socket lifecycle

    private func startSocket() {
        guard SlackSocketPolicy.connectAllowed() else {
            logger.notice(
                "slack socket disabled: BLAISE_DATA_ROOT override active (set BLAISE_SLACK_SOCKET=1 to opt in)")
            return
        }
        guard socketTask == nil else { return }
        guard
            let app = (try? secrets.get(key: Self.appTokenKey)) ?? nil,
            let bot = (try? secrets.get(key: Self.botTokenKey)) ?? nil
        else { return }
        let client = self.client
        let tracker = self.tracker
        let onEvent: @Sendable (SlackHuddleEvent) async -> Void = { [weak self] event in
            await tracker.handle(event, at: Date())
            await MainActor.run { self?.lastEventAt = Date() }
        }
        let onStatus: @Sendable (SlackSocketStatus) async -> Void = { [weak self] status in
            await MainActor.run { self?.handleSocketStatus(status) }
        }
        socketTask = Task {
            await client.run(appToken: app, botToken: bot, onEvent: onEvent, onStatus: onStatus)
        }
    }

    /// Cancel + AWAIT the running socket so a rotated-token reconnect or a
    /// disconnect fully tears the old session down before the next one starts.
    private func stopSocket() async {
        guard let task = socketTask else { return }
        socketTask = nil
        socketLive = false
        noHelloStreak = 0
        task.cancel()
        await task.value
    }

    /// The socket's connection-health sink (`run`'s `onStatus`). Internal so the
    /// streak → persistent-failure logic is unit-testable without a live socket.
    func handleSocketStatus(_ status: SlackSocketStatus) {
        switch status {
        case .connected:
            socketLive = true
            noHelloStreak = 0
            if lastError == Self.reconnectFailureMessage { lastError = nil }
        case .sessionEnded(let healthy):
            socketLive = false
            if healthy {
                noHelloStreak = 0
            } else {
                noHelloStreak += 1
                if noHelloStreak >= Self.maxFailedSessions {
                    lastError = Self.reconnectFailureMessage
                }
            }
        }
    }

    // MARK: - Derived UI state

    /// disconnected / connecting / reconnecting / connected — mirrors the
    /// extension badge.
    var statusTitle: String {
        if connecting { return "Connecting" }
        guard connected else { return "Disconnected" }
        guard socketLive else {
            // Tokens exist but the socket has not reached `hello`: first attempt
            // vs a drop after we had traffic.
            return lastEventAt == nil ? "Connecting…" : "Reconnecting…"
        }
        if let last = lastEventAt {
            return "Connected · last event \(Self.age(since: last)) ago"
        }
        return "Connected"
    }

    private var normalizedAppToken: String { appToken.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var normalizedBotToken: String { botToken.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var normalizedMemberID: String { memberID.trimmingCharacters(in: .whitespacesAndNewlines) }

    private static func age(since date: Date) -> String {
        let seconds = Int(max(0, Date().timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }

    private static func describe(_ error: any Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}

// MARK: - Socket Mode client

/// Connection health reported by `run()` so the model's status line can tell
/// "connected" from "reconnecting" and surface a persistent failure (a revoked
/// token or a removed app loops forever without a `hello`).
enum SlackSocketStatus: Sendable, Equatable {
    /// A `hello` arrived — the session is healthy.
    case connected
    /// A session ended and a reconnect will follow. `healthy` = it had a hello.
    case sessionEnded(healthy: Bool)
}

/// A minimal text-frame WebSocket, injectable so the client's ack/reconnect
/// logic is testable without a live socket.
protocol SlackWebSocketChannel: Sendable {
    func receiveText() async throws -> String
    func sendText(_ text: String) async throws
    func sendPing() async throws
    func cancel()
}

actor SlackSocketClient {
    typealias HTTPTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    typealias SocketOpener = @Sendable (URL) async throws -> any SlackWebSocketChannel

    static let apiBase = "https://slack.com/api"
    static let initialBackoffSeconds: Double = 1
    static let maxBackoffSeconds: Double = 60
    static let pingIntervalSeconds: Double = 30

    private let transport: HTTPTransport
    private let opener: SocketOpener
    private let backoffSleep: @Sendable (Double) async throws -> Void
    private let pingSleep: @Sendable (Double) async throws -> Void
    private let logger = Logger(subsystem: BlaiseBundle.identifier, category: "slack.socket")

    /// Set when the current session received `hello` — reset the backoff only
    /// after a genuinely healthy connection (survives a mid-session error too).
    private var sessionSawHello = false

    init(
        transport: @escaping HTTPTransport = SlackSocketClient.urlSessionTransport,
        opener: @escaping SocketOpener = SlackSocketClient.urlSessionOpener,
        backoffSleep: @escaping @Sendable (Double) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        },
        pingSleep: @escaping @Sendable (Double) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }
    ) {
        self.transport = transport
        self.opener = opener
        self.backoffSleep = backoffSleep
        self.pingSleep = pingSleep
    }

    /// Exponential backoff, capped (jitter added at the call site).
    static func nextBackoff(_ current: Double) -> Double {
        min(maxBackoffSeconds, current * 2)
    }

    // MARK: Web API

    /// `apps.connections.open` → the `wss://…` URL to open. Non-ok surfaces the
    /// Slack error code.
    func openConnection(appToken: String) async throws -> URL {
        let response: SlackConnectionOpenResponse = try await postForm(
            "apps.connections.open", token: appToken)
        guard response.ok else { throw SlackClientError.api(response.error ?? "unknown") }
        guard let urlString = response.url, let url = URL(string: urlString) else {
            throw SlackClientError.malformed("apps.connections.open returned no url")
        }
        return url
    }

    /// `auth.test` → identity + workspace. Non-ok surfaces the error code.
    func authTest(botToken: String) async throws -> SlackAuthTestResponse {
        let response: SlackAuthTestResponse = try await postForm("auth.test", token: botToken)
        guard response.ok else { throw SlackClientError.api(response.error ?? "unknown") }
        return response
    }

    /// `users.info` fallback for an event whose profile carried no usable name.
    /// A failure returns nil (nil name beats wrong name — the caller keeps the
    /// stable member id).
    func usersInfo(userID: String, botToken: String) async -> SlackUser? {
        var components = URLComponents(string: "\(Self.apiBase)/users.info")!
        components.queryItems = [URLQueryItem(name: "user", value: userID)]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(botToken)", forHTTPHeaderField: "Authorization")
        guard
            let (data, http) = try? await transport(request), 200 ..< 300 ~= http.statusCode,
            let response = try? JSONDecoder().decode(SlackUsersInfoResponse.self, from: data),
            response.ok
        else { return nil }
        return response.user
    }

    // MARK: Socket run loop

    /// Runs the Socket Mode connection until the task is cancelled: open →
    /// pump frames → on disconnect/error reconnect with capped, jittered
    /// backoff (reset after a healthy `hello`).
    func run(
        appToken: String, botToken: String,
        onEvent: @escaping @Sendable (SlackHuddleEvent) async -> Void,
        onStatus: @escaping @Sendable (SlackSocketStatus) async -> Void = { _ in }
    ) async {
        var backoff = Self.initialBackoffSeconds
        while !Task.isCancelled {
            sessionSawHello = false
            do {
                let url = try await openConnection(appToken: appToken)
                let channel = try await opener(url)
                defer { channel.cancel() }
                try await pump(channel: channel, onEvent: onEvent, onStatus: onStatus)
            } catch is CancellationError {
                return
            } catch {
                logger.notice("slack socket session ended: \(error.localizedDescription, privacy: .public)")
            }
            if Task.isCancelled { return }
            // Report the ended session (healthy = it saw a hello) so the model
            // can distinguish a routine link refresh from a failing loop.
            await onStatus(.sessionEnded(healthy: sessionSawHello))
            if sessionSawHello { backoff = Self.initialBackoffSeconds }
            let jitter = Double.random(in: 0 ... 0.3) * backoff
            try? await backoffSleep(backoff + jitter)
            backoff = Self.nextBackoff(backoff)
        }
    }

    /// One connection's frame loop. Returns on a `disconnect` frame; throws on
    /// a socket read error (caller reconnects).
    private func pump(
        channel: any SlackWebSocketChannel,
        onEvent: @escaping @Sendable (SlackHuddleEvent) async -> Void,
        onStatus: @escaping @Sendable (SlackSocketStatus) async -> Void
    ) async throws {
        let pingSleep = self.pingSleep
        let pinger = Task {
            while !Task.isCancelled {
                do { try await pingSleep(Self.pingIntervalSeconds) } catch { return }
                do { try await channel.sendPing() } catch { return }
            }
        }
        defer { pinger.cancel() }

        while true {
            try Task.checkCancellation()
            // `URLSessionWebSocketTask.receive()` does NOT observe Swift task
            // cancellation, so cancel the channel explicitly on cancellation —
            // otherwise a disconnect leaves the pump blocked until the next
            // inbound frame, which would still be ACKed and delivered to the
            // tracker AFTER the user disconnected.
            let text = try await withTaskCancellationHandler {
                try await channel.receiveText()
            } onCancel: {
                channel.cancel()
            }
            let data = Data(text.utf8)
            // ACK FIRST, before any processing — and independently of the full
            // decode, so a frame whose strict decode fails is still ACKed
            // (Slack redelivers unacked envelopes forever). Only enveloped
            // frames (events_api) carry an envelope_id.
            if let id = (try? JSONDecoder().decode(SlackEnvelopeID.self, from: data))?.envelopeID,
                let ack = try? String(
                    decoding: JSONEncoder().encode(SlackSocketAck(envelopeID: id)), as: UTF8.self)
            {
                try? await channel.sendText(ack)
            }
            guard let frame = try? JSONDecoder().decode(SlackSocketFrame.self, from: data)
            else { continue }  // unknown frame shape — already ACKed, ignore
            switch frame.type {
            case "hello":
                sessionSawHello = true
                await onStatus(.connected)
            case "disconnect":
                logger.info("slack socket disconnect frame (\(frame.reason ?? "-", privacy: .public))")
                return
            case "events_api":
                if let event = frame.payload?.event,
                    event.type == SlackHuddleEvent.huddleChangedType
                {
                    await onEvent(event)
                }
            default:
                break
            }
        }
    }

    // MARK: Helpers

    private func postForm<T: Decodable>(_ method: String, token: String) async throws -> T {
        var request = URLRequest(url: URL(string: "\(Self.apiBase)/\(method)")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(
            "application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data()
        let (data, http) = try await transport(request)
        guard 200 ..< 300 ~= http.statusCode else {
            throw SlackClientError.http(status: http.statusCode)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw SlackClientError.malformed("\(method): \(error)")
        }
    }

    // MARK: Production transports

    static let urlSessionTransport: HTTPTransport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SlackClientError.malformed("non-HTTP response from slack.com")
        }
        return (data, http)
    }

    static let urlSessionOpener: SocketOpener = { url in
        URLSessionSlackChannel(task: URLSession.shared.webSocketTask(with: url))
    }
}

/// Production channel over `URLSessionWebSocketTask`.
private final class URLSessionSlackChannel: SlackWebSocketChannel, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
        task.resume()
    }

    func receiveText() async throws -> String {
        switch try await task.receive() {
        case .string(let text): return text
        case .data(let data): return String(decoding: data, as: UTF8.self)
        @unknown default: return ""
        }
    }

    func sendText(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func sendPing() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            task.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func cancel() {
        task.cancel(with: .goingAway, reason: nil)
    }
}
