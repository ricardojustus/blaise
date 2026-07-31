import Foundation
import Testing
@testable import BlaiseCore

@Suite("Room attribution authority")
struct RoomAttributionTests {
    private let user = UserIdentity(
        name: "Sam Rivera",
        aliases: ["Samuel Rivera"],
        email: "sam.rivera@vexatron.test")
    private let attendees = [
        Attendee(
            name: "S. Rivera", email: "sam.rivera@vexatron.test",
            source: .calendar),
        Attendee(
            name: "Dana Okonkwo", email: "dana@quoll-harbor.test",
            source: .calendar),
    ]

    private func segment(label: String, text: String, name: String? = nil) -> TranscriptSegment {
        TranscriptSegment(
            meetingID: "01TESTMEETING0000000000000", ord: 0,
            startSeconds: 0, endSeconds: 10, speakerLabel: label,
            speakerName: name, text: text)
    }

    @Test("owner set mirrors payload user forms and excludes empty identity")
    func ownerIdentitySetAndPayloadStayAligned() {
        let ownerSet = OwnerIdentitySet(user: user, attendees: attendees)
        for name in ["Sam Rivera", "samuel rivera", "S. RIVERA"] {
            #expect(ownerSet.contains(name))
            let meeting = Meeting(
                id: "01ARZ3NDEKTSV4RRFFQ69G5FAV", title: "Quoll Harbor",
                startedAt: Date(timeIntervalSince1970: 1_770_000_000),
                source: .meet, status: .ready, attendees: attendees,
                createdAt: Date(timeIntervalSince1970: 1_770_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_770_000_000))
            #expect(
                EvidencePayloadBuilder.speakerSource(
                    of: segment(label: "S0", text: "hello", name: name),
                    meeting: meeting, user: user) == "microphone")
        }
        #expect(
            !OwnerIdentitySet(user: .shippedDefault, attendees: attendees)
                .contains(""))
    }

    @Test("rule 2b drops every owner form in both allowed-name branches")
    func ruleTwoBClosesBothBranches() {
        let ownerSet = OwnerIdentitySet(user: user, attendees: attendees)
        for name in ["Sam Rivera", "Samuel Rivera", "S. Rivera"] {
            let base = segment(label: "M1", text: "\(name) discussed the launch")
            let allowed = SpeakerResolution(
                assignments: ["M1": name], unresolved: []
            ).apply(
                to: [base], attendeeNames: [name], eventNames: [],
                userName: user.name, suppression: [], commonNames: [],
                ownerIdentitySet: ownerSet)
            #expect(allowed[0].speakerName == nil)

            let verbatim = SpeakerResolution(
                assignments: ["M1": name], unresolved: []
            ).apply(
                to: [base], attendeeNames: [], eventNames: [],
                userName: "", suppression: [], commonNames: [],
                ownerIdentitySet: ownerSet)
            #expect(verbatim[0].speakerName == nil)
        }
    }

    @Test("non-owner name remains allowed and empty onboarding contributes nothing")
    func nonOwnerAndEmptyIdentity() {
        let segment = segment(label: "M1", text: "Dana Okonkwo discussed the launch")
        let named = SpeakerResolution(
            assignments: ["M1": "Dana Okonkwo"], unresolved: []
        ).apply(
            to: [segment], attendeeNames: [], eventNames: [], userName: "",
            suppression: [], commonNames: [],
            ownerIdentitySet: OwnerIdentitySet(
                user: .shippedDefault, attendees: []))
        #expect(named[0].speakerName == "Dana Okonkwo")
    }

    @Test("timeline refinement ignores M-origin and stamped-user segments")
    func refinementSkipsMicNamespace() {
        let segments = [
            segment(label: "M0", text: "mic"),
            segment(label: TranscriptSegment.userLabel, text: "owner", name: "Sam Rivera"),
        ]
        let events = [
            ActiveSpeakerEvent(
                displayName: "Dana Okonkwo", participantID: "dana",
                startEpochMillis: 1_000, endEpochMillis: 11_000)
        ]
        let refined = SpeakerResolver.refineWithPerSegmentTimeline(
            segments: segments, diarization: [],
            hints: SpeakerHints(
                activeSpeakerEvents: events, recordingStartEpochMillis: 1_000),
            audioDuration: 10, eventNames: ["Dana Okonkwo"])
        #expect(refined == segments)
    }

    @Test("M-origin payload source is stamp-only")
    func payloadMicSourceRequiresStamp() {
        let meeting = Meeting(
            id: "01ARZ3NDEKTSV4RRFFQ69G5FAV", title: "Quoll Harbor",
            startedAt: Date(timeIntervalSince1970: 1_770_000_000),
            source: .meet, status: .ready, attendees: attendees,
            createdAt: Date(timeIntervalSince1970: 1_770_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_770_000_000))
        #expect(
            EvidencePayloadBuilder.speakerSource(
                of: segment(label: "M0", text: "mic", name: "Sam Rivera"),
                meeting: meeting, user: user) == "speaker")
        #expect(
            EvidencePayloadBuilder.speakerSource(
                of: segment(
                    label: TranscriptSegment.userLabel, text: "mic",
                    name: "Sam Rivera"),
                meeting: meeting, user: user) == "microphone")
    }

    @Test("artifact presence follows the label namespace")
    func artifactPresenceIsNamespaceSpecific() {
        let presence = DiarizationArtifactPresence(system: true, mic: false)
        #expect(presence.containsArtifact(for: "S2"))
        #expect(!presence.containsArtifact(for: "M2"))
        #expect(presence.containsArtifact(for: TranscriptSegment.unattributed))
    }
}
