import Foundation
import Testing
@testable import BlaiseCore

private func interval(_ start: Double, _ end: Double) -> SpeechInterval {
    SpeechInterval(startSeconds: start, endSeconds: end)
}

private let usableProfile = VoiceProfileSnapshot(
    version: 3, modelID: "vexatron-voice-v1",
    references: [
        VoiceProfileReference(
            meetingID: "01J00000000000000000000001",
            embedding: [1, 0], speechSeconds: 90, language: "en")
    ])

@Suite("Room treatment pure evaluation")
struct RoomTreatmentTests {
    @Test("masked seconds use interval unions before subtracting system speech")
    func maskedSecondsUsesUnions() {
        let seconds = RoomTreatment.maskedSeconds(
            candidate: [interval(0, 8), interval(4, 12)],
            system: [interval(2, 4), interval(6, 10)])
        #expect(seconds == 6)
    }

    @Test("verified system silence is vacuous and can pass the audio gate")
    func verifiedSilenceVacuousPass() {
        let result = RoomTreatment.evaluate(
            source: .meet,
            captureFacts: CaptureFacts(
                sourceProvenance: .classified, linkClass: .assumed),
            micClusters: [
                RoomSpeechCluster(
                    label: "M0", intervals: [interval(0, 120)], centroid: [0, 1])
            ],
            systemCentroids: [:],
            systemSpeechIntervals: [],
            profile: usableProfile,
            persistedRenameClusters: [])

        #expect(result.ladderRow == .audioGate)
        #expect(result.artifact.gateVerdict == .room)
        #expect(result.artifact.gateEvidence[0].sysDistance == nil)
        #expect(result.artifact.ownerStamps["M0"]?.decision == .user)
        #expect(result.counters.roomGateInertNoSystemCentroids == 0)
    }

    @Test("system speech without centroids makes a gate row inert")
    func missingSystemCentroidsMakesGateInert() {
        let result = RoomTreatment.evaluate(
            source: .meet,
            captureFacts: CaptureFacts(
                sourceProvenance: .classified, linkClass: .recognized),
            micClusters: [
                RoomSpeechCluster(
                    label: "M0", intervals: [interval(0, 120)], centroid: [0, 1])
            ],
            systemCentroids: [:],
            systemSpeechIntervals: [interval(0, 4)],
            profile: usableProfile,
            persistedRenameClusters: [])

        #expect(result.artifact.gateVerdict == .solo)
        #expect(result.counters.roomGateInertNoSystemCentroids == 1)
        #expect(result.counters.stampsDisabledNoSystemCentroids == 0)
    }

    @Test("binding room row stays room but disables stamps without system centroids")
    func roomRowMissingCentroidsDisablesStamps() {
        let result = RoomTreatment.evaluate(
            source: .inPerson,
            captureFacts: CaptureFacts(
                sourceProvenance: .explicit, linkClass: .none),
            micClusters: [
                RoomSpeechCluster(
                    label: "M0", intervals: [interval(0, 20)], centroid: [1, 0])
            ],
            systemCentroids: [:],
            systemSpeechIntervals: [interval(0, 3)],
            profile: usableProfile,
            persistedRenameClusters: [])

        #expect(result.artifact.gateVerdict == .room)
        #expect(result.artifact.ownerStamps["M0"]?.decision == .anonymous)
        #expect(result.counters.stampsDisabledNoSystemCentroids == 1)
        #expect(result.counters.roomGateInertNoSystemCentroids == 0)
    }

    @Test("profile match counts before rename suppression and blocks dominant default")
    func renameSuppressedProfileMatchKeepsOtherClusterAnonymous() {
        let clusters = [
            RoomSpeechCluster(
                label: "M0", intervals: [interval(0, 10)], centroid: [1, 0]),
            RoomSpeechCluster(
                label: "M1", intervals: [interval(10, 40)], centroid: [0, 1]),
        ]
        let unsuppressed = RoomTreatment.evaluate(
            source: .inPerson,
            captureFacts: CaptureFacts(
                sourceProvenance: .explicit, linkClass: .none),
            micClusters: clusters,
            systemCentroids: [:],
            systemSpeechIntervals: [],
            profile: usableProfile,
            persistedRenameClusters: [])
        #expect(unsuppressed.artifact.ownerStamps["M0"]?.decision == .user)
        #expect(unsuppressed.artifact.ownerStamps["M1"]?.decision == .anonymous)

        let result = RoomTreatment.evaluate(
            source: .inPerson,
            captureFacts: CaptureFacts(
                sourceProvenance: .explicit, linkClass: .none),
            micClusters: clusters,
            systemCentroids: [:],
            systemSpeechIntervals: [],
            profile: usableProfile,
            persistedRenameClusters: ["M0"])

        #expect(result.artifact.ownerStamps["M0"]?.decision == .anonymous)
        #expect(result.artifact.ownerStamps["M0"]?.suppressedByRename == true)
        #expect(result.artifact.ownerStamps["M1"]?.decision == .anonymous)
        #expect(result.counters.stampsSuppressedByRename == 1)
        #expect(result.counters.ownerStampedClusters == 0)
    }

    @Test("system match veto outranks profile match")
    func systemMatchVeto() {
        let result = RoomTreatment.evaluate(
            source: .inPerson,
            captureFacts: CaptureFacts(
                sourceProvenance: .explicit, linkClass: .none),
            micClusters: [
                RoomSpeechCluster(
                    label: "M0", intervals: [interval(0, 15)], centroid: [1, 0])
            ],
            systemCentroids: ["S0": [1, 0]],
            systemSpeechIntervals: [interval(0, 2)],
            profile: usableProfile,
            persistedRenameClusters: [])

        #expect(result.artifact.ownerStamps["M0"]?.decision == .anonymous)
        #expect(result.counters.ownerStampedClusters == 0)
    }

    @Test("pre-profile explicit in-person stays room with anonymous clusters")
    func preProfileRoomIsAnonymous() {
        let result = RoomTreatment.evaluate(
            source: .inPerson,
            captureFacts: CaptureFacts(
                sourceProvenance: .explicit, linkClass: .none),
            micClusters: [
                RoomSpeechCluster(
                    label: "M0", intervals: [interval(0, 20)], centroid: [1, 0])
            ],
            systemCentroids: [:],
            systemSpeechIntervals: [interval(0, 3)],
            profile: nil,
            persistedRenameClusters: [])

        #expect(result.ladderRow == .explicitInPersonRoom)
        #expect(result.artifact.gateVerdict == .room)
        #expect(result.artifact.ownerStamps["M0"]?.decision == .anonymous)
        #expect(result.counters.stampsDisabledNoSystemCentroids == 0)
    }

    @Test("classified in-person with a generic link uses the profile room row")
    func classifiedInPersonGenericLinkUsesProfileRoom() {
        let result = RoomTreatment.evaluate(
            source: .inPerson,
            captureFacts: CaptureFacts(
                sourceProvenance: .classified, linkClass: .generic),
            micClusters: [],
            systemCentroids: [:],
            systemSpeechIntervals: [],
            profile: usableProfile,
            persistedRenameClusters: [])

        #expect(result.ladderRow == .profileRoom)
        #expect(result.artifact.gateVerdict == .room)
    }

    /// The classifier does not mint `.inPerson` for a link-bearing event, so a
    /// classified link-bearing calendar meeting takes the audio-gate row on
    /// whichever label it carries — recognized host or generic.
    @Test("a classified online calendar meeting takes the gate row, never profile room")
    func classifiedOnlineLinkTakesTheGateRow() {
        for linkClass in [CaptureFacts.LinkClass.recognized, .generic] {
            let result = RoomTreatment.evaluate(
                source: .online,
                captureFacts: CaptureFacts(
                    sourceProvenance: .classified, linkClass: linkClass),
                micClusters: [],
                systemCentroids: [:],
                systemSpeechIntervals: [],
                profile: usableProfile,
                persistedRenameClusters: [])

            #expect(result.ladderRow == .audioGate)
        }
    }

    @Test("audio gate duration floor removes a five-second candidate")
    func audioGateDurationFloorCounter() {
        let result = RoomTreatment.evaluate(
            source: .meet,
            captureFacts: CaptureFacts(
                sourceProvenance: .classified, linkClass: .recognized),
            micClusters: [
                RoomSpeechCluster(
                    label: "M0", intervals: [interval(0, 5)], centroid: [0, 1])
            ],
            systemCentroids: [:],
            systemSpeechIntervals: [],
            profile: usableProfile,
            persistedRenameClusters: [])

        #expect(result.ladderRow == .audioGate)
        #expect(result.artifact.gateVerdict == .solo)
        #expect(result.counters.gateCandidatesSurvivingPerCondition.duration == 0)
    }

    @Test("audio gate profile match veto removes its sole candidate")
    func audioGateProfileVetoCounter() {
        let result = RoomTreatment.evaluate(
            source: .meet,
            captureFacts: CaptureFacts(
                sourceProvenance: .classified, linkClass: .recognized),
            micClusters: [
                RoomSpeechCluster(
                    label: "M0", intervals: [interval(0, 120)], centroid: [1, 0])
            ],
            systemCentroids: [:],
            systemSpeechIntervals: [],
            profile: usableProfile,
            persistedRenameClusters: [])

        #expect(result.ladderRow == .audioGate)
        #expect(result.artifact.gateVerdict == .solo)
        #expect(result.counters.gateCandidatesSurvivingPerCondition.duration == 1)
        #expect(result.counters.gateCandidatesSurvivingPerCondition.profileVeto == 0)
    }

    @Test("recognized Meet capture without a profile stays solo")
    func recognizedMeetWithoutProfileIsSolo() {
        let result = RoomTreatment.evaluate(
            source: .meet,
            captureFacts: CaptureFacts(
                sourceProvenance: .classified, linkClass: .recognized),
            micClusters: [],
            systemCentroids: [:],
            systemSpeechIntervals: [],
            profile: nil,
            persistedRenameClusters: [])

        #expect(result.ladderRow == .profileAbsentSolo)
        #expect(result.artifact.gateVerdict == .solo)
    }

    @Test("artifact schema contains only the persisted room-treatment fields")
    func artifactSchema() throws {
        let result = RoomTreatment.evaluate(
            source: .meet,
            captureFacts: CaptureFacts(
                sourceProvenance: .classified, linkClass: .recognized),
            micClusters: [],
            systemCentroids: [:],
            systemSpeechIntervals: [],
            profile: usableProfile,
            persistedRenameClusters: [])
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(result.artifact))
                as? [String: Any])
        #expect(Set(object.keys) == [
            "micDiarization", "clusterCentroids", "gateVerdict", "gateEvidence",
            "profileVersion", "ownerStamps",
        ])
    }

    @Test("a centroid-less mic cluster can never receive an owner stamp")
    func centroidlessClusterIsAnonymous() {
        let result = RoomTreatment.evaluate(
            source: .inPerson,
            captureFacts: CaptureFacts(
                sourceProvenance: .explicit, linkClass: .none),
            micClusters: [
                RoomSpeechCluster(
                    label: "M0", intervals: [interval(0, 30)], centroid: nil)
            ],
            systemCentroids: [:],
            systemSpeechIntervals: [],
            profile: usableProfile,
            persistedRenameClusters: [])
        #expect(result.artifact.ownerStamps["M0"]?.decision == .anonymous)
        #expect(result.counters.ownerStampedClusters == 0)
    }

    @Test("gate survivor counters are cumulative in condition order")
    func cumulativeSurvivorCounters() {
        let result = RoomTreatment.evaluate(
            source: .meet,
            captureFacts: CaptureFacts(
                sourceProvenance: .classified, linkClass: .recognized),
            micClusters: [
                RoomSpeechCluster(
                    label: "M0", intervals: [interval(20, 40)], centroid: [1, 0]),
                RoomSpeechCluster(
                    label: "M1", intervals: [interval(20, 25)], centroid: [0, 1]),
                RoomSpeechCluster(
                    label: "M2", intervals: [interval(20, 95)], centroid: [-1, 0]),
            ],
            systemCentroids: ["S0": [1, 0]],
            systemSpeechIntervals: [interval(0, 2)],
            profile: usableProfile,
            persistedRenameClusters: [])
        #expect(
            result.counters.gateCandidatesSurvivingPerCondition.systemExclusion == 2)
        #expect(result.counters.gateCandidatesSurvivingPerCondition.duration == 1)
        #expect(result.counters.gateCandidatesSurvivingPerCondition.profileVeto == 1)
        #expect(result.artifact.gateVerdict == .room)
    }

    /// The fired meeting whose ONLY profile match is the bleed-vetoed cluster:
    /// the match still counts, so rule 3 never defaults the remaining dominant
    /// cluster to the user and the meeting ends fully anonymous.
    @Test("a bleed-vetoed profile match suppresses the dominant cluster's default-you")
    func bleedVetoedMatchSuppressesDefaultYou() {
        let result = RoomTreatment.evaluate(
            source: .meet,
            captureFacts: CaptureFacts(
                sourceProvenance: .classified, linkClass: .recognized),
            micClusters: [
                RoomSpeechCluster(
                    label: "M0", intervals: [interval(0, 900)], centroid: [1, 0]),
                RoomSpeechCluster(
                    label: "M1", intervals: [interval(900, 2500)], centroid: [0, 1]),
            ],
            systemCentroids: ["S0": [1, 0]],
            systemSpeechIntervals: [interval(0, 600)],
            profile: usableProfile,
            persistedRenameClusters: [])

        #expect(result.artifact.gateVerdict == .room)
        #expect(result.counters.gateCandidatesSurvivingPerCondition.profileVeto == 1)
        #expect(result.artifact.ownerStamps["M0"]?.decision == .anonymous)
        #expect(result.artifact.ownerStamps["M1"]?.decision == .anonymous)
        #expect(result.counters.ownerStampedClusters == 0)
        #expect(result.counters.stampsSuppressedByRename == 0)
    }

    @Test("a profile-silent room meeting still defaults the dominant cluster to the user")
    func profileSilentMeetingDefaultsToDominantCluster() {
        let result = RoomTreatment.evaluate(
            source: .inPerson,
            captureFacts: CaptureFacts(
                sourceProvenance: .explicit, linkClass: .none),
            micClusters: [
                RoomSpeechCluster(
                    label: "M0", intervals: [interval(0, 30)], centroid: [0, 1]),
                RoomSpeechCluster(
                    label: "M1", intervals: [interval(100, 400)], centroid: [-1, 0]),
            ],
            systemCentroids: [:],
            systemSpeechIntervals: [],
            profile: usableProfile,
            persistedRenameClusters: [])

        #expect(result.artifact.gateVerdict == .room)
        #expect(result.artifact.ownerStamps["M1"]?.decision == .user)
        #expect(result.artifact.ownerStamps["M0"]?.decision == .anonymous)
        #expect(result.counters.ownerStampedClusters == 1)
    }

    /// The shipped tuple is the calibration's product (spec §7, v10); a changed
    /// value here re-opens that calibration.
    @Test("the shipped gate constants are the calibrated tuple")
    func calibratedConstantsAreShipped() {
        let constants = RoomGateConstants()
        #expect(constants.systemDistanceThreshold == 0.50)
        #expect(constants.maskedSecondsFloor == 60)
        #expect(constants.profileDistanceThreshold == 0.45)
        #expect(constants.modeRadius == 0.50)
        #expect(constants.dominanceRatio == 2)
    }
}
