import AppKit
import BlaiseCore
import CryptoKit
import Foundation
import Network
import Observation
import Security

private struct GoogleCalendarSettings: Codable, Equatable, Sendable {
    var enabled: Bool
    var clientID: String

    static let empty = GoogleCalendarSettings(enabled: false, clientID: "")
}

private enum GoogleCalendarError: LocalizedError, Sendable {
    case missingClientID
    case missingRefreshToken
    case browserOpenFailed
    case oauthCallbackTimedOut
    case oauthCallbackFailed(String)
    case oauthStateMismatch
    case http(status: Int, message: String)
    case malformedResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            return "Enter a Google OAuth desktop client ID first."
        case .missingRefreshToken:
            return "Google Calendar is not connected."
        case .browserOpenFailed:
            return "Could not open the Google sign-in page."
        case .oauthCallbackTimedOut:
            return "Google sign-in timed out."
        case .oauthCallbackFailed(let message):
            return message
        case .oauthStateMismatch:
            return "Google sign-in returned an invalid state."
        case .http(let status, let message):
            return "Google Calendar request failed (\(status)): \(message)"
        case .malformedResponse(let message):
            return "Google Calendar returned an unexpected response: \(message)"
        }
    }
}

@MainActor @Observable
final class GoogleCalendarModel {
    static let settingsKey = "calendar.google.settings"
    static let refreshTokenKey = "calendar.google.refreshToken"
    static let hiddenKey = "calendar.google.hiddenCalendarIDs"

    var enabled = false
    var clientID = ""
    private(set) var connected = false
    private(set) var authorizing = false
    private(set) var refreshing = false
    private(set) var lastError: String?
    private(set) var lastRefresh: Date?
    /// Google calendar IDs the user has hidden (empty = all shown).
    private(set) var hiddenCalendarIDs: Set<String> = []
    /// Available Google calendars (id + name) for the Settings picker.
    private(set) var googleCalendars: [CalendarChoice] = []

    private let settings: SettingsStore
    private let secrets: any SecretStore
    private let client: GoogleCalendarClient

    init(
        settings: SettingsStore,
        secrets: any SecretStore,
        client: GoogleCalendarClient = GoogleCalendarClient()
    ) {
        self.settings = settings
        self.secrets = secrets
        self.client = client
    }

    func load() async {
        let stored =
            (try? await settings.get(Self.settingsKey, as: GoogleCalendarSettings.self))
            ?? nil ?? .empty
        enabled = stored.enabled
        clientID = stored.clientID
        hiddenCalendarIDs = Set(
            (try? await settings.get(Self.hiddenKey, as: [String].self)) ?? nil ?? [])
        connected = ((try? secrets.get(key: Self.refreshTokenKey)) ?? nil) != nil
    }

    private var hiddenPersistTask: Task<Void, Never>?
    /// Show/hide a specific Google calendar across every surface.
    func setGoogleCalendar(_ id: String, shown: Bool) {
        if shown { hiddenCalendarIDs.remove(id) } else { hiddenCalendarIDs.insert(id) }
        let snapshot = Array(hiddenCalendarIDs)
        // Chain writes so a rapid burst of toggles persists in order.
        let previous = hiddenPersistTask
        hiddenPersistTask = Task { [settings] in
            _ = await previous?.value
            try? await settings.set(Self.hiddenKey, to: snapshot)
        }
    }

    /// Fetch the user's Google calendar list (id + name) for the Settings
    /// picker. No-op (keeps the last list) when not connected or on error.
    func listCalendars() async {
        let normalized = normalizedClientID
        guard connected, !normalized.isEmpty,
            let refreshToken = (try? secrets.get(key: Self.refreshTokenKey)) ?? nil
        else {
            googleCalendars = []
            return
        }
        if let fetched = try? await client.listCalendars(
            clientID: normalized, refreshToken: refreshToken) {
            googleCalendars = fetched
        }
    }

    func saveSettings() async {
        let normalized = normalizedClientID
        clientID = normalized
        try? await settings.set(
            Self.settingsKey,
            to: GoogleCalendarSettings(enabled: enabled, clientID: normalized))
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        Task { await saveSettings() }
    }

    func connect() async {
        clientID = normalizedClientID
        guard !clientID.isEmpty else {
            lastError = GoogleCalendarError.missingClientID.localizedDescription
            return
        }
        authorizing = true
        defer { authorizing = false }
        do {
            let refreshToken = try await client.authorize(clientID: clientID)
            try secrets.set(key: Self.refreshTokenKey, value: refreshToken)
            connected = true
            enabled = true
            lastError = nil
            await saveSettings()
        } catch {
            lastError = Self.describe(error)
        }
    }

    func disconnect() async {
        // Best-effort revoke at Google BEFORE forgetting the token locally, so a
        // disconnect tears down the grant itself — not just our copy of it.
        if let refreshToken = (try? secrets.get(key: Self.refreshTokenKey)) ?? nil {
            await client.revoke(refreshToken: refreshToken)
        }
        try? secrets.delete(key: Self.refreshTokenKey)
        await client.clearAccessToken()
        connected = false
        enabled = false
        lastError = nil
        await saveSettings()
    }

    func snapshots(from start: Date, to end: Date) async -> [CalendarEventSnapshot] {
        guard enabled else { return [] }
        let normalized = normalizedClientID
        guard !normalized.isEmpty else {
            lastError = GoogleCalendarError.missingClientID.localizedDescription
            return []
        }
        guard let refreshToken = (try? secrets.get(key: Self.refreshTokenKey)) ?? nil else {
            connected = false
            lastError = GoogleCalendarError.missingRefreshToken.localizedDescription
            return []
        }
        refreshing = true
        defer { refreshing = false }
        do {
            let events = try await client.snapshots(
                clientID: normalized, refreshToken: refreshToken,
                hiddenCalendarIDs: hiddenCalendarIDs, from: start, to: end)
            connected = true
            lastError = nil
            lastRefresh = Date()
            return events
        } catch {
            lastError = Self.describe(error)
            return []
        }
    }

    private var normalizedClientID: String {
        clientID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func describe(_ error: any Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}

actor GoogleCalendarClient {
    private static let calendarReadonlyScope = "https://www.googleapis.com/auth/calendar.readonly"
    private static let authEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    private static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    private static let revokeEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!
    private static let calendarListEndpoint = URL(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList")!
    private static let eventsBase = "https://www.googleapis.com/calendar/v3/calendars"

    private let session: URLSession
    private var cachedAccessToken: String?
    private var accessTokenExpiresAt: Date?

    init(session: URLSession = .shared) {
        self.session = session
    }

    func clearAccessToken() {
        cachedAccessToken = nil
        accessTokenExpiresAt = nil
    }

    /// Best-effort grant revocation at Google (RFC 7009). Any failure is
    /// swallowed — the caller drops the local token regardless, so a transient
    /// network error never blocks disconnect.
    func revoke(refreshToken: String) async {
        var request = URLRequest(url: Self.revokeEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "token", value: refreshToken)]
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
        _ = try? await session.data(for: request)
        clearAccessToken()
    }

    func authorize(clientID: String) async throws -> String {
        let state = try Self.randomURLSafe(byteCount: 24)
        let codeVerifier = try Self.randomURLSafe(byteCount: 48)
        let codeChallenge = Self.codeChallenge(for: codeVerifier)
        let receiver = try GoogleOAuthLoopbackReceiver(state: state)
        let redirectURI = try await receiver.start()

        var components = URLComponents(url: Self.authEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.calendarReadonlyScope),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let authURL = components.url else {
            throw GoogleCalendarError.malformedResponse("could not build authorization URL")
        }
        let opened = await MainActor.run {
            NSWorkspace.shared.open(authURL)
        }
        guard opened else { throw GoogleCalendarError.browserOpenFailed }

        let code = try await receiver.waitForCode(timeoutSeconds: 180)
        let token = try await tokenRequest([
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "code_verifier", value: codeVerifier),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
        ])
        guard let refreshToken = token.refreshToken, !refreshToken.isEmpty else {
            throw GoogleCalendarError.malformedResponse("missing refresh token")
        }
        cachedAccessToken = token.accessToken
        accessTokenExpiresAt = Date().addingTimeInterval(TimeInterval(max(0, token.expiresIn - 60)))
        return refreshToken
    }

    func snapshots(
        clientID: String, refreshToken: String, hiddenCalendarIDs: Set<String>,
        from start: Date, to end: Date
    ) async throws -> [CalendarEventSnapshot] {
        let accessToken = try await accessToken(clientID: clientID, refreshToken: refreshToken)
        let calendars = try await calendarList(accessToken: accessToken)
        // F3: fetch only non-hidden calendars; the "primary" fallback fires only
        // when the list is empty AND nothing is hidden (see CalendarVisibility).
        let calendarIDs = CalendarVisibility.visibleCalendarIDs(
            available: calendars.map(\.id), hidden: hiddenCalendarIDs)
        var snapshots: [CalendarEventSnapshot] = []
        for calendarID in calendarIDs {
            snapshots.append(contentsOf: try await events(
                calendarID: calendarID, accessToken: accessToken, from: start, to: end))
        }
        return snapshots
    }

    /// The user's Google calendars (id + name) for the Settings picker.
    func listCalendars(clientID: String, refreshToken: String) async throws -> [CalendarChoice] {
        let accessToken = try await accessToken(clientID: clientID, refreshToken: refreshToken)
        return try await calendarList(accessToken: accessToken).map {
            CalendarChoice(id: $0.id, name: $0.summary?.nilIfEmpty ?? $0.id)
        }
    }

    private func accessToken(clientID: String, refreshToken: String) async throws -> String {
        if let cachedAccessToken, let accessTokenExpiresAt, accessTokenExpiresAt > Date() {
            return cachedAccessToken
        }
        let token = try await tokenRequest([
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
        ])
        cachedAccessToken = token.accessToken
        accessTokenExpiresAt = Date().addingTimeInterval(TimeInterval(max(0, token.expiresIn - 60)))
        return token.accessToken
    }

    private func calendarList(accessToken: String) async throws -> [GoogleCalendarListEntry] {
        var calendars: [GoogleCalendarListEntry] = []
        var pageToken: String?
        repeat {
            var components = URLComponents(url: Self.calendarListEndpoint, resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "minAccessRole", value: "reader"),
                URLQueryItem(name: "showHidden", value: "false"),
                URLQueryItem(name: "maxResults", value: "250"),
            ]
            if let pageToken {
                components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            let response: GoogleCalendarListResponse = try await getJSON(
                components.url!, accessToken: accessToken)
            calendars.append(contentsOf: response.items ?? [])
            pageToken = response.nextPageToken
        } while pageToken != nil
        return calendars.filter { entry in
            guard let hidden = entry.hidden, hidden else { return true }
            return false
        }
    }

    private func events(
        calendarID: String, accessToken: String, from start: Date, to end: Date
    ) async throws -> [CalendarEventSnapshot] {
        var result: [CalendarEventSnapshot] = []
        var pageToken: String?
        repeat {
            var components = URLComponents(
                string: "\(Self.eventsBase)/\(Self.pathSegment(calendarID))/events")!
            components.queryItems = [
                URLQueryItem(name: "singleEvents", value: "true"),
                URLQueryItem(name: "orderBy", value: "startTime"),
                URLQueryItem(name: "showDeleted", value: "false"),
                URLQueryItem(name: "maxResults", value: "2500"),
                URLQueryItem(name: "maxAttendees", value: "50"),
                URLQueryItem(name: "timeMin", value: Self.rfc3339(start)),
                URLQueryItem(name: "timeMax", value: Self.rfc3339(end)),
                URLQueryItem(name: "timeZone", value: TimeZone.current.identifier),
            ]
            if let pageToken {
                components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            let response: GoogleEventsResponse = try await getJSON(
                components.url!, accessToken: accessToken)
            result.append(contentsOf: (response.items ?? []).compactMap {
                Self.snapshot(event: $0, calendarID: calendarID)
            })
            pageToken = response.nextPageToken
        } while pageToken != nil
        return result
    }

    private func tokenRequest(_ items: [URLQueryItem]) async throws -> GoogleTokenResponse {
        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = items
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        return try JSONDecoder().decode(GoogleTokenResponse.self, from: data)
    }

    private func getJSON<T: Decodable>(_ url: URL, accessToken: String) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard 200 ..< 300 ~= http.statusCode else {
            let message =
                (try? JSONDecoder().decode(GoogleErrorEnvelope.self, from: data).error.message)
                ?? String(decoding: data, as: UTF8.self)
            throw GoogleCalendarError.http(status: http.statusCode, message: message)
        }
    }

    private static func snapshot(
        event: GoogleCalendarEvent, calendarID: String
    ) -> CalendarEventSnapshot? {
        guard event.status != "cancelled" else { return nil }
        guard
            let start = event.start.dateTime.flatMap(parseDate),
            let end = event.end.dateTime.flatMap(parseDate)
        else {
            return nil
        }
        let videoURL = event.hangoutLink
            ?? event.conferenceData?.entryPoints?.first(where: { $0.entryPointType == "video" })?.uri
        return CalendarEventSnapshot(
            eventIdentifier: "google:\(calendarID):\(event.id)",
            title: event.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Meeting",
            start: start,
            end: end,
            location: event.location,
            notes: event.description,
            urlString: videoURL,
            attendees: (event.attendees ?? [])
                .filter { $0.resource != true && $0.responseStatus != "declined" }
                .map { attendee in
                    CalendarEventSnapshot.AttendeeSnapshot(
                        name: attendee.displayName?.nilIfEmpty ?? attendee.email ?? "Unknown",
                        email: attendee.email)
                })
    }

    private static func rfc3339(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }

    private static func pathSegment(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func randomURLSafe(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        // A failed CSPRNG draw would leave the buffer all-zeros, yielding a
        // PREDICTABLE PKCE verifier AND CSRF state — abort the flow rather than
        // proceed with a degraded grant.
        guard status == errSecSuccess else {
            throw GoogleCalendarError.malformedResponse("secure random generation failed (\(status))")
        }
        return Data(bytes).base64URLEncodedString()
    }

    static func codeChallenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }
}

private final class GoogleOAuthLoopbackReceiver: @unchecked Sendable {
    private static let callbackPath = "/oauth/google-calendar"

    private let listener: NWListener
    private let queue = DispatchQueue(label: "app.blaise.google-calendar.oauth")
    private let state: String
    private let lock = NSLock()
    private var readyContinuation: CheckedContinuation<String, any Error>?
    private var codeContinuation: CheckedContinuation<String, any Error>?
    private var pendingResult: Result<String, any Error>?
    private var finished = false

    init(state: String) throws {
        self.state = state
        // Bind the OAuth callback listener to loopback (127.0.0.1) only, so the
        // ephemeral redirect port is unreachable from other hosts on the network
        // during the auth window; the CSRF `state` check is the second guard.
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        self.listener = try NWListener(using: parameters)
    }

    func start() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                readyContinuation = continuation
            }
            listener.stateUpdateHandler = { [weak self] newState in
                self?.handleListenerState(newState)
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
        }
    }

    func waitForCode(timeoutSeconds: UInt64) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await self.waitForCodeOnly() }
            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                let error = GoogleCalendarError.oauthCallbackTimedOut
                self.complete(.failure(error))
                throw error
            }
            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }

    private func waitForCodeOnly() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let pending: Result<String, any Error>? = lock.withLock {
                if let pendingResult {
                    self.pendingResult = nil
                    return pendingResult
                }
                codeContinuation = continuation
                return nil
            }
            if let pending {
                continuation.resume(with: pending)
            }
        }
    }

    private func handleListenerState(_ newState: NWListener.State) {
        switch newState {
        case .ready:
            guard let port = listener.port?.rawValue else { return }
            resumeReady("http://127.0.0.1:\(port)\(Self.callbackPath)")
        case .failed(let error):
            resumeReady(error)
            complete(.failure(error))
        case .cancelled:
            complete(.failure(GoogleCalendarError.oauthCallbackTimedOut))
        default:
            break
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let result = self.parse(data: data)
            switch result {
            case .success(let code):
                self.respond(connection, status: "200 OK", body: "Blaise is connected to Google Calendar. You can close this tab.")
                self.complete(.success(code))
            case .failure(let error):
                self.respond(connection, status: "400 Bad Request", body: error.localizedDescription)
                self.complete(.failure(error))
            }
        }
    }

    private func parse(data: Data?) -> Result<String, any Error> {
        guard
            let data,
            let request = String(data: data, encoding: .utf8),
            let requestLine = request.components(separatedBy: "\r\n").first
        else {
            return .failure(GoogleCalendarError.malformedResponse("empty OAuth callback"))
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            return .failure(GoogleCalendarError.malformedResponse("invalid OAuth callback"))
        }
        guard
            let components = URLComponents(string: "http://127.0.0.1\(parts[1])"),
            components.path == Self.callbackPath
        else {
            return .failure(GoogleCalendarError.malformedResponse("unexpected OAuth callback path"))
        }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        if let error = query["error"] {
            return .failure(GoogleCalendarError.oauthCallbackFailed(error))
        }
        guard query["state"] == state else {
            return .failure(GoogleCalendarError.oauthStateMismatch)
        }
        guard let code = query["code"], !code.isEmpty else {
            return .failure(GoogleCalendarError.malformedResponse("missing authorization code"))
        }
        return .success(code)
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let html = """
            <!doctype html><meta charset="utf-8"><title>Blaise</title><body style="font:14px -apple-system;margin:32px">\(body)</body>
            """
        let bodyData = Data(html.utf8)
        var response = Data(
            "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
                .utf8)
        response.append(bodyData)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func resumeReady(_ value: String) {
        let continuation = lock.withLock { () -> CheckedContinuation<String, any Error>? in
            defer { readyContinuation = nil }
            return readyContinuation
        }
        continuation?.resume(returning: value)
    }

    private func resumeReady(_ error: any Error) {
        let continuation = lock.withLock { () -> CheckedContinuation<String, any Error>? in
            defer { readyContinuation = nil }
            return readyContinuation
        }
        continuation?.resume(throwing: error)
    }

    private func complete(_ result: Result<String, any Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<String, any Error>? in
            guard !finished else { return nil }
            finished = true
            if let codeContinuation {
                self.codeContinuation = nil
                return codeContinuation
            }
            pendingResult = result
            return nil
        }
        continuation?.resume(with: result)
        listener.cancel()
    }
}

private struct GoogleTokenResponse: Decodable, Sendable {
    var accessToken: String
    var expiresIn: Int
    var refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
    }
}

private struct GoogleCalendarListResponse: Decodable, Sendable {
    var nextPageToken: String?
    var items: [GoogleCalendarListEntry]?
}

private struct GoogleCalendarListEntry: Decodable, Sendable {
    var id: String
    var summary: String?
    var hidden: Bool?
}

private struct GoogleEventsResponse: Decodable, Sendable {
    var nextPageToken: String?
    var items: [GoogleCalendarEvent]?
}

private struct GoogleCalendarEvent: Decodable, Sendable {
    var id: String
    var status: String?
    var summary: String?
    var description: String?
    var location: String?
    var hangoutLink: String?
    var start: GoogleEventDate
    var end: GoogleEventDate
    var attendees: [GoogleEventAttendee]?
    var conferenceData: GoogleConferenceData?
}

private struct GoogleEventDate: Decodable, Sendable {
    var dateTime: String?
    var date: String?
    var timeZone: String?
}

private struct GoogleEventAttendee: Decodable, Sendable {
    var email: String?
    var displayName: String?
    var responseStatus: String?
    var resource: Bool?
}

private struct GoogleConferenceData: Decodable, Sendable {
    var entryPoints: [GoogleConferenceEntryPoint]?
}

private struct GoogleConferenceEntryPoint: Decodable, Sendable {
    var entryPointType: String?
    var uri: String?
}

private struct GoogleErrorEnvelope: Decodable, Sendable {
    struct GoogleError: Decodable, Sendable {
        var message: String
    }

    var error: GoogleError
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
