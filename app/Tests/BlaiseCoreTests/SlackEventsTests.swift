import Foundation
import Testing

@testable import BlaiseCore

// C15: the wire layer — Socket Mode frame + `user_huddle_changed` decoding,
// the display-name preference, member-id shape, code namespace, and the
// connect-flow Web API responses.

@Suite("C15 Slack wire types")
struct SlackEventsTests {
    private func decodeFrame(_ json: String) throws -> SlackSocketFrame {
        try JSONDecoder().decode(SlackSocketFrame.self, from: Data(json.utf8))
    }

    @Test("hello frame")
    func hello() throws {
        let frame = try decodeFrame(#"{"type":"hello","num_connections":1}"#)
        #expect(frame.type == "hello")
        #expect(frame.envelopeID == nil)
        #expect(frame.payload == nil)
    }

    @Test("disconnect frame carries its reason")
    func disconnect() throws {
        let frame = try decodeFrame(#"{"type":"disconnect","reason":"link_disabled"}"#)
        #expect(frame.type == "disconnect")
        #expect(frame.reason == "link_disabled")
    }

    @Test("events_api envelope decodes a full self-join user_huddle_changed")
    func selfJoinEnvelope() throws {
        let json = """
            { "envelope_id": "env-1", "type": "events_api",
              "payload": { "event": {
                "type": "user_huddle_changed",
                "user": { "id": "U012AB3CD", "name": "sam",
                  "profile": { "display_name": "Sam", "real_name": "Sam Rivera",
                    "huddle_state": "in_a_huddle",
                    "huddle_state_expiration_ts": 1781136000,
                    "huddle_state_call_id": "R0123ABC456" } },
                "event_ts": "1781135000.001300" } },
              "event_ts": "1781135000.001300" }
            """
        let frame = try decodeFrame(json)
        #expect(frame.type == "events_api")
        #expect(frame.envelopeID == "env-1")
        let event = try #require(frame.payload?.event)
        #expect(event.type == SlackHuddleEvent.huddleChangedType)
        #expect(event.user.id == "U012AB3CD")
        #expect(event.isInHuddle)
        #expect(event.callID == "R0123ABC456")
        #expect(event.expirationTs == 1_781_136_000)
        #expect(event.preferredDisplayName == "Sam")
    }

    @Test("leave event: state cleared, no call id")
    func leaveEvent() throws {
        let json = """
            { "type": "user_huddle_changed",
              "user": { "id": "U012AB3CD",
                "profile": { "huddle_state": "default_unset" } },
              "event_ts": "1781135100.000200" }
            """
        let event = try JSONDecoder().decode(SlackHuddleEvent.self, from: Data(json.utf8))
        #expect(!event.isInHuddle)
        #expect(event.callID == nil)
        #expect(event.expirationTs == nil)
    }

    @Test("display-name preference: display_name → real_name → user.name → nil")
    func displayNamePreference() {
        func event(display: String?, real: String?, name: String?) -> SlackHuddleEvent {
            SlackHuddleEvent(
                type: SlackHuddleEvent.huddleChangedType,
                user: SlackUser(
                    id: "U1", name: name,
                    profile: SlackUserProfile(displayName: display, realName: real)),
                eventTS: "1.1")
        }
        #expect(event(display: "Disp", real: "Real", name: "n").preferredDisplayName == "Disp")
        #expect(event(display: "  ", real: "Real", name: "n").preferredDisplayName == "Real")
        #expect(event(display: nil, real: "", name: "n").preferredDisplayName == "n")
        #expect(event(display: nil, real: nil, name: nil).preferredDisplayName == nil)
    }

    @Test("missing huddle_state_call_id decodes to a nil call id")
    func missingCallID() throws {
        let json = """
            { "type": "user_huddle_changed",
              "user": { "id": "U1", "profile": { "huddle_state": "in_a_huddle" } },
              "event_ts": "1.1" }
            """
        let event = try JSONDecoder().decode(SlackHuddleEvent.self, from: Data(json.utf8))
        #expect(event.isInHuddle)
        #expect(event.callID == nil)
    }

    @Test("member-id shape gate")
    func memberID() {
        #expect(SlackMemberID.isValid("U012AB3CD"))
        #expect(SlackMemberID.isValid("W07ABCDE9"))
        #expect(SlackMemberID.isValid("  U012AB3CD  "))  // trimmed
        #expect(!SlackMemberID.isValid("u012ab"))  // lowercase prefix
        #expect(!SlackMemberID.isValid("U123"))  // too short
        #expect(!SlackMemberID.isValid("X012AB3CD"))  // wrong prefix
        #expect(!SlackMemberID.isValid("U012ab3cd"))  // lowercase body
        #expect(!SlackMemberID.isValid(""))
    }

    @Test("code namespace round-trips")
    func codeNamespace() {
        #expect(SlackHuddle.meetingCode(callID: "R1") == "slack:R1")
        #expect(SlackHuddle.callID(fromMeetingCode: "slack:R1") == "R1")
        #expect(SlackHuddle.callID(fromMeetingCode: "abc-defg-hij") == nil)
        #expect(MeetingSource(forMeetingCode: "slack:R1") == .slack)
        #expect(MeetingSource(forMeetingCode: "abc-defg-hij") == .meet)
    }

    @Test("Web API responses: connections.open, auth.test")
    func webAPI() throws {
        let open = try JSONDecoder().decode(
            SlackConnectionOpenResponse.self,
            from: Data(#"{"ok":true,"url":"wss://wss-primary.slack.com/link/x"}"#.utf8))
        #expect(open.ok)
        #expect(open.url == "wss://wss-primary.slack.com/link/x")

        let bad = try JSONDecoder().decode(
            SlackConnectionOpenResponse.self, from: Data(#"{"ok":false,"error":"invalid_auth"}"#.utf8))
        #expect(!bad.ok)
        #expect(bad.error == "invalid_auth")

        let auth = try JSONDecoder().decode(
            SlackAuthTestResponse.self,
            from: Data(#"{"ok":true,"team":"Acme","team_id":"T1","user_id":"U1"}"#.utf8))
        #expect(auth.ok)
        #expect(auth.team == "Acme")
        #expect(auth.userID == "U1")
    }

    @Test("dev-instance socket gating mirrors the listener bind policy")
    func socketPolicy() {
        #expect(SlackSocketPolicy.connectAllowed(environment: [:]))
        #expect(!SlackSocketPolicy.connectAllowed(environment: ["BLAISE_DATA_ROOT": "/tmp/x"]))
        #expect(
            SlackSocketPolicy.connectAllowed(
                environment: ["BLAISE_DATA_ROOT": "/tmp/x", "BLAISE_SLACK_SOCKET": "1"]))
    }
}
