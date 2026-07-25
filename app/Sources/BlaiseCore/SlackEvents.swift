import Foundation

// C15: the wire layer of docs/slack_huddles_contract.md — the Socket Mode
// frame envelope, the `user_huddle_changed` event payload, and the Web API
// responses the connect flow validates against (`apps.connections.open`,
// `auth.test`, `users.info`). Pure Codable types + small helpers; the socket
// transport lives in BlaiseApp/SlackHuddlesIntegration.swift and the state
// machine in SlackHuddleTracker.swift.

// MARK: - Correlation code

/// The `meetingCode` namespace for huddles: a huddle's Slack call id
/// (`R0123ABC456`) becomes `slack:R0123ABC456`, the string the ingestor
/// correlates on and `MeetingSource(forMeetingCode:)` reads. Kept string-
/// generic (the `meet_*` tables never learn the word "slack").
public enum SlackHuddle {
    public static let meetingCodePrefix = "slack:"

    public static func meetingCode(callID: String) -> String {
        meetingCodePrefix + callID
    }

    /// The call id embedded in a `slack:` code, or nil for a non-Slack code.
    public static func callID(fromMeetingCode code: String) -> String? {
        guard code.hasPrefix(meetingCodePrefix) else { return nil }
        return String(code.dropFirst(meetingCodePrefix.count))
    }
}

// MARK: - Self member id

/// The user's own Slack member id (`U…`/`W…`), pasted at setup. Not a secret
/// (it appears in every event), so it lives in the settings JSON. Shape is
/// validated at connect: `^[UW][A-Z0-9]{5,}$`.
public enum SlackMemberID {
    public static func isValid(_ raw: String) -> Bool {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = id.first, first == "U" || first == "W" else { return false }
        let rest = id.dropFirst()
        guard rest.count >= 5 else { return false }
        return rest.allSatisfy { $0.isASCII && ($0.isNumber || ($0.isLetter && $0.isUppercase)) }
    }
}

// MARK: - Dev-instance gating

/// Mirrors `MeetEventsListenerPolicy` (MeetEvents.swift): an instance pointed
/// at an overridden data root (dev/demo throwaway roots in /tmp) never opens
/// the long-lived Socket Mode connection — two instances sharing a workspace's
/// event stream and both auto-recording would be the huddle equivalent of the
/// port-squatting field failure. Opt in with `BLAISE_SLACK_SOCKET=1` for
/// deliberate integration testing against a scratch root.
public enum SlackSocketPolicy {
    public static func connectAllowed(environment: [String: String]) -> Bool {
        environment["BLAISE_DATA_ROOT"] == nil || environment["BLAISE_SLACK_SOCKET"] == "1"
    }

    public static func connectAllowed() -> Bool {
        connectAllowed(environment: ProcessInfo.processInfo.environment)
    }
}

// MARK: - Socket Mode frames (server → client)

/// One Socket Mode frame. Only the fields Blaise consumes are decoded:
/// `type` (`hello` / `events_api` / `disconnect` / ...), the `envelope_id`
/// that an `events_api` frame must be acked with, `payload` for events, and
/// `reason` on a `disconnect`.
public struct SlackSocketFrame: Decodable, Sendable, Equatable {
    public var type: String
    public var envelopeID: String?
    public var payload: SlackEventsAPIPayload?
    public var reason: String?

    enum CodingKeys: String, CodingKey {
        case type
        case envelopeID = "envelope_id"
        case payload
        case reason
    }
}

public struct SlackEventsAPIPayload: Decodable, Sendable, Equatable {
    public var event: SlackHuddleEvent?
}

/// Lenient envelope-id extraction, decoded independently of the full frame so
/// an enveloped frame is ACKed even when the strict `SlackSocketFrame` (or its
/// nested event) fails to decode — otherwise Slack redelivers it forever.
public struct SlackEnvelopeID: Decodable, Sendable, Equatable {
    public var envelopeID: String?

    enum CodingKeys: String, CodingKey {
        case envelopeID = "envelope_id"
    }
}

/// The client's ack for an `events_api` envelope — `{"envelope_id": "<id>"}`,
/// sent BEFORE processing (Slack redelivers unacked envelopes; the tracker's
/// `user.id + ":" + event_ts` dedupe absorbs any redelivery).
public struct SlackSocketAck: Encodable, Sendable, Equatable {
    public var envelopeID: String

    public init(envelopeID: String) {
        self.envelopeID = envelopeID
    }

    enum CodingKeys: String, CodingKey {
        case envelopeID = "envelope_id"
    }
}

// MARK: - user_huddle_changed

public struct SlackHuddleEvent: Decodable, Sendable, Equatable {
    public var type: String
    public var user: SlackUser
    public var eventTS: String

    enum CodingKeys: String, CodingKey {
        case type
        case user
        case eventTS = "event_ts"
    }

    public init(type: String, user: SlackUser, eventTS: String) {
        self.type = type
        self.user = user
        self.eventTS = eventTS
    }

    public static let huddleChangedType = "user_huddle_changed"
    public static let inHuddleState = "in_a_huddle"

    /// The huddle this event describes (`profile.huddle_state_call_id`).
    public var callID: String? { user.profile?.huddleStateCallID?.nonEmpty }

    /// Whether the user is currently in a huddle (`huddle_state`).
    public var isInHuddle: Bool { user.profile?.huddleState == Self.inHuddleState }

    /// Wire-shape fidelity only: parsed from `profile.huddle_state_expiration_ts`
    /// (epoch seconds), never consulted by production code (C15 spec, "Lingering state").
    public var expirationTs: Int64? { user.profile?.huddleStateExpirationTs }

    /// Display-name preference (contract): `display_name`, else `real_name`,
    /// else `user.name`, else nil (nil name beats a wrong name — the roster
    /// still carries the stable member id, and a `users.info` fetch is the
    /// caller's last resort).
    public var preferredDisplayName: String? {
        user.profile?.displayName?.nonEmpty
            ?? user.profile?.realName?.nonEmpty
            ?? user.name?.nonEmpty
    }
}

public struct SlackUser: Decodable, Sendable, Equatable {
    public var id: String
    public var name: String?
    public var profile: SlackUserProfile?

    public init(id: String, name: String? = nil, profile: SlackUserProfile? = nil) {
        self.id = id
        self.name = name
        self.profile = profile
    }
}

public struct SlackUserProfile: Decodable, Sendable, Equatable {
    public var displayName: String?
    public var realName: String?
    public var huddleState: String?
    public var huddleStateExpirationTs: Int64?
    public var huddleStateCallID: String?

    public init(
        displayName: String? = nil, realName: String? = nil, huddleState: String? = nil,
        huddleStateExpirationTs: Int64? = nil, huddleStateCallID: String? = nil
    ) {
        self.displayName = displayName
        self.realName = realName
        self.huddleState = huddleState
        self.huddleStateExpirationTs = huddleStateExpirationTs
        self.huddleStateCallID = huddleStateCallID
    }

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case realName = "real_name"
        case huddleState = "huddle_state"
        case huddleStateExpirationTs = "huddle_state_expiration_ts"
        case huddleStateCallID = "huddle_state_call_id"
    }
}

// MARK: - Web API responses (connect validation)

/// `apps.connections.open` → `{ok, url}` (the `wss://…` to open) or
/// `{ok:false, error}`.
public struct SlackConnectionOpenResponse: Decodable, Sendable, Equatable {
    public var ok: Bool
    public var url: String?
    public var error: String?
}

/// `auth.test` → identity + workspace (`team`) for the Settings status line,
/// or `{ok:false, error}`.
public struct SlackAuthTestResponse: Decodable, Sendable, Equatable {
    public var ok: Bool
    public var url: String?
    public var team: String?
    public var teamID: String?
    public var user: String?
    public var userID: String?
    public var error: String?

    enum CodingKeys: String, CodingKey {
        case ok, url, team, user, error
        case teamID = "team_id"
        case userID = "user_id"
    }
}

/// `users.info` → the user object (display-name fallback when an event's
/// profile carried no name), or `{ok:false, error}`.
public struct SlackUsersInfoResponse: Decodable, Sendable, Equatable {
    public var ok: Bool
    public var user: SlackUser?
    public var error: String?
}

// MARK: -

extension String {
    /// The trimmed string, or nil when it is empty/whitespace — the "nil name
    /// beats a wrong name" gate the display-name preference leans on.
    fileprivate var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
