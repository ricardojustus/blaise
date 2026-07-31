import Foundation
import Testing
@testable import BlaiseCore

@Suite("Room treatment capture facts")
struct CaptureFactsTests {
    @Test("nil-code Slack is assumed and generic calendar URLs stay generic")
    func linkClassification() {
        let slack = CaptureFacts.derive(
            source: .slack, meetingCode: nil, sourceProvenance: .explicit)
        #expect(slack.linkClass == .assumed)

        let generic = CaptureFacts.derive(
            source: .inPerson, meetingCode: nil, sourceProvenance: .classified,
            joinedLinkText: "Join at https://calls.vexatron.example/quoll")
        #expect(generic.linkClass == .generic)

        let noLink = CaptureFacts.derive(
            source: .inPerson, meetingCode: nil, sourceProvenance: .classified,
            joinedLinkText: "Quoll Harbor planning room")
        #expect(noLink.linkClass == .none)
    }

    @Test("recognized platform wins over unrelated generic links")
    func recognizedLinkPrecedence() {
        let facts = CaptureFacts.derive(
            source: .meet, meetingCode: nil, sourceProvenance: .classified,
            joinedLinkText:
                "https://docs.vexatron.example/brief https://meet.google.com/abc-defg-hij")
        #expect(facts.linkClass == .recognized)
    }

    @Test("an online-source meeting with no observable link is assumed, fresh and legacy")
    func onlineSourceRoutesToAssumed() {
        let fresh = CaptureFacts.derive(
            source: .online, meetingCode: nil, sourceProvenance: .classified)
        #expect(fresh.linkClass == .assumed)

        let legacy = CaptureFacts.legacy(source: .online, meetingCode: nil)
        #expect(legacy.linkClass == .assumed)
        #expect(legacy.sourceProvenance == .classified)

        let withLink = CaptureFacts.derive(
            source: .online, meetingCode: nil, sourceProvenance: .classified,
            joinedLinkText: "https://calls.vexatron.example/quoll")
        #expect(withLink.linkClass == .generic)
    }

    @Test("absent and corrupt files synthesize legacy classified facts")
    func legacySynthesis() {
        let absent = CaptureFacts.resolve(
            encoded: nil, legacySource: .zoom, legacyMeetingCode: nil)
        #expect(absent.facts.sourceProvenance == .classified)
        #expect(absent.facts.linkClass == .recognized)
        #expect(absent.disposition == .synthesizedAbsent)

        let corrupt = CaptureFacts.resolve(
            encoded: Data("{".utf8), legacySource: .inPerson, legacyMeetingCode: nil)
        #expect(corrupt.facts.linkClass == .none)
        #expect(corrupt.disposition == .synthesizedCorrupt)
    }
}
