import Foundation
import Testing
@testable import BlaiseCore

// C4 SpeakerResolver unit tests: dominance, drift sweep, identity keys,
// ambiguity, bounds, sentinel exclusion + the ActiveSpeakerEvent Codable
// golden (C12 contract pin).

private func diar(_ label: String, _ start: Double, _ end: Double) -> DiarizedSegment {
    DiarizedSegment(speakerLabel: label, startSeconds: start, endSeconds: end)
}

/// Recording starts at this wall-clock epoch; event times are given in
/// recording-relative SECONDS for readability.
private let recordingStart: Int64 = 1_765_000_000_000

private func event(
    _ name: String, _ start: Double, _ end: Double, pid: String? = nil
) -> ActiveSpeakerEvent {
    ActiveSpeakerEvent(
        displayName: name,
        participantID: pid,
        startEpochMillis: recordingStart + Int64(start * 1000),
        endEpochMillis: recordingStart + Int64(end * 1000))
}

private func hints(_ events: [ActiveSpeakerEvent]?, start: Int64? = recordingStart) -> SpeakerHints {
    SpeakerHints(activeSpeakerEvents: events, recordingStartEpochMillis: start)
}

@Suite struct SpeakerResolverTests {
    // MARK: - Dominance

    @Test func exactTwiceRunnerUpIsUnresolved() {
        // Alice 10 s vs Bob 5 s: 10 is NOT strictly > 2×5 → unresolved.
        let resolution = SpeakerResolver.resolve(
            diarization: [diar("S0", 0, 30)],
            hints: hints([event("Alice", 0, 10), event("Bob", 10, 15)]),
            audioDuration: 60)
        #expect(resolution.assignments.isEmpty)
        #expect(resolution.unresolved == ["S0"])
    }

    @Test func strictDominanceResolves() {
        // Alice 10.5 s > 2×5 s and ≥ 5 s → resolved; many-to-one allowed.
        let resolution = SpeakerResolver.resolve(
            diarization: [diar("S0", 0, 30), diar("S1", 30, 45)],
            hints: hints([
                event("Alice", 0, 10.5), event("Bob", 10.5, 15.5),
                event("Alice", 30, 41),
            ]),
            audioDuration: 60)
        #expect(resolution.assignments == ["S0": "Alice", "S1": "Alice"])
        #expect(resolution.unresolved.isEmpty)
    }

    @Test func fiveSecondFloorBlocksShortDominance() {
        // Alice 4 s with no runner-up: dominant but below the 5 s floor.
        let resolution = SpeakerResolver.resolve(
            diarization: [diar("S0", 0, 30)],
            hints: hints([event("Alice", 0, 4)]),
            audioDuration: 60)
        #expect(resolution.assignments.isEmpty)
        #expect(resolution.unresolved == ["S0"])  // had ≥ 1 vote, failed
    }

    @Test func zeroVoteClustersAreNeitherAssignedNorUnresolved() {
        let resolution = SpeakerResolver.resolve(
            diarization: [diar("S0", 0, 10), diar("S1", 40, 50)],
            hints: hints([event("Alice", 0, 8)]),
            audioDuration: 60)
        #expect(resolution.assignments == ["S0": "Alice"])
        #expect(resolution.unresolved.isEmpty)  // S1 had no votes
    }

    // MARK: - Drift sweep

    @Test func driftSweepRecoversSyntheticOffset() {
        // Events written by a clock running 1 s AHEAD of the recording clock:
        // true activity [10,14] and [16,20] (bracketing the cluster's edges)
        // shows up as [11,15] and [17,21]. The objective is uniquely maximal
        // at offset −1.0 (8.0; every other sweep point is < 8).
        let clusters = [diar("S0", 10, 20)]
        let events = [event("Alice", 11, 15), event("Alice", 17, 21)]
        let relative = events.map {
            (
                $0.displayName, $0.participantID,
                Double($0.startEpochMillis - recordingStart) / 1000.0,
                Double($0.endEpochMillis - recordingStart) / 1000.0
            )
        }
        let offset = SpeakerResolver.chooseOffset(
            clusters: clusters, events: relative, audioDuration: 60)
        #expect(offset == -1.0)

        let resolution = SpeakerResolver.resolve(
            diarization: clusters, hints: hints(events), audioDuration: 60)
        #expect(resolution.assignments == ["S0": "Alice"])
    }

    @Test func offsetTiesPreferSmallestAbsoluteThenEarlier() {
        // Event [4,5] between clusters [0,4] and [5,9]: every |offset| ≥ 1
        // yields the same maximal overlap (1.0 s) → smallest |offset| wins the
        // argmax tie (1.0 vs 2.0…), then the earlier offset (−1.0 over +1.0).
        let clusters = [diar("S0", 0, 4), diar("S1", 5, 9)]
        let offset = SpeakerResolver.chooseOffset(
            clusters: clusters,
            events: [("Alice", nil, 4.0, 5.0)],
            audioDuration: 20)
        #expect(offset == -1.0)

        // Constant objective across the whole sweep → 0.0 (smallest |offset|).
        let flat = SpeakerResolver.chooseOffset(
            clusters: [diar("S0", 0, 100)],
            events: [("Alice", nil, 50.0, 55.0)],
            audioDuration: 100)
        #expect(flat == 0.0)
    }

    // MARK: - Identity keys + ambiguity

    @Test func timeDisjointSameNameIDsAreARejoinOneKey() {
        // Two participantIDs, same display name, time-disjoint (Meet
        // reassigns ids on rejoin) → one person; votes combine.
        let resolution = SpeakerResolver.resolve(
            diarization: [diar("S0", 0, 20)],
            hints: hints([
                event("Caio Souza", 0, 3, pid: "id-a"),
                event("Caio Souza", 10, 13, pid: "id-b"),
            ]),
            audioDuration: 60)
        #expect(resolution.assignments == ["S0": "Caio Souza"])
    }

    @Test func overlappingSameNameIDsMakeTheNameAmbiguous() {
        // Two distinct non-nil ids share a name AND overlap in time → the
        // name is ambiguous; the cluster whose top it is stays unresolved.
        let resolution = SpeakerResolver.resolve(
            diarization: [diar("S0", 0, 20)],
            hints: hints([
                event("Caio Souza", 0, 10, pid: "id-a"),
                event("Caio Souza", 5, 15, pid: "id-b"),
            ]),
            audioDuration: 60)
        #expect(resolution.assignments.isEmpty)
        #expect(resolution.unresolved == ["S0"])
    }

    @Test func ambiguousNamesStillContributeRunnerUpMass() {
        // S1: Alice 11 s top, ambiguous Caio 6 s runner-up. 11 ≤ 2×6 → the
        // ambiguous name's mass suppresses dominance (conservative).
        let resolution = SpeakerResolver.resolve(
            diarization: [diar("S0", 0, 20), diar("S1", 30, 60)],
            hints: hints([
                event("Caio", 0, 10, pid: "id-a"),
                event("Caio", 5, 15, pid: "id-b"),  // → "Caio" ambiguous
                event("Caio", 30, 36, pid: "id-a"),
                event("Alice", 36, 47),
            ]),
            audioDuration: 60)
        #expect(resolution.assignments.isEmpty)
        #expect(resolution.unresolved == ["S0", "S1"])
    }

    @Test func nilAndNonNilParticipantIDsAreOneKey() {
        // nil/non-nil mixtures of one display name are one key, not ambiguous.
        let resolution = SpeakerResolver.resolve(
            diarization: [diar("S0", 0, 20)],
            hints: hints([
                event("Dana", 0, 4, pid: nil),
                event("Dana", 2, 6, pid: "id-x"),  // overlaps the nil event
            ]),
            audioDuration: 60)
        #expect(resolution.assignments == ["S0": "Dana"])
    }

    // MARK: - Bounds, sentinel, missing hints

    @Test func eventsEntirelyOutsideAudioAreExcluded() {
        let resolution = SpeakerResolver.resolve(
            diarization: [diar("S0", 0, 20)],
            hints: hints([event("Alice", 30, 45)]),  // entirely past a 20 s file
            audioDuration: 20)
        #expect(resolution.assignments.isEmpty)
        #expect(resolution.unresolved.isEmpty)
    }

    @Test func unattributedSentinelNeverParticipates() {
        let resolution = SpeakerResolver.resolve(
            diarization: [
                diar(TranscriptSegment.unattributed, 0, 10), diar("S0", 12, 20),
            ],
            hints: hints([event("Alice", 0, 10), event("Alice", 12, 20)]),
            audioDuration: 60)
        #expect(resolution.assignments == ["S0": "Alice"])
        #expect(!resolution.unresolved.contains(TranscriptSegment.unattributed))
    }

    @Test func nilRecordingStartIgnoresEvents() {
        let resolution = SpeakerResolver.resolve(
            diarization: [diar("S0", 0, 20)],
            hints: hints([event("Alice", 0, 10)], start: nil),
            audioDuration: 60)
        #expect(resolution.assignments.isEmpty)
        #expect(resolution.unresolved.isEmpty)
    }

    @Test func nilOrEmptyEventsYieldEmptyResolution() {
        for events in [nil, [ActiveSpeakerEvent]()] {
            let resolution = SpeakerResolver.resolve(
                diarization: [diar("S0", 0, 20)], hints: hints(events), audioDuration: 60)
            #expect(resolution.assignments.isEmpty)
            #expect(resolution.unresolved.isEmpty)
        }
    }

    @Test func resolveIsDeterministic() {
        let clusters = [diar("S0", 0, 20), diar("S1", 20, 40), diar("S2", 40, 60)]
        let events = [
            event("Alice", 0, 11), event("Bob", 11, 15), event("Bob", 20, 33),
            event("Caio", 41, 47), event("Alice", 47, 52, pid: "p1"),
        ]
        let first = SpeakerResolver.resolve(
            diarization: clusters, hints: hints(events), audioDuration: 60)
        let second = SpeakerResolver.resolve(
            diarization: clusters, hints: hints(events), audioDuration: 60)
        #expect(first == second)
    }

    // MARK: - ActiveSpeakerEvent Codable golden (C12 contract pin)

    @Test func activeSpeakerEventCodableGolden() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let full = ActiveSpeakerEvent(
            displayName: "Caio Souza", participantID: "p42",
            startEpochMillis: 1_765_000_000_000, endEpochMillis: 1_765_000_004_500)
        let fullJSON = String(decoding: try encoder.encode(full), as: UTF8.self)
        #expect(fullJSON == #"{"display_name":"Caio Souza","end_epoch_millis":1765000004500,"participant_id":"p42","start_epoch_millis":1765000000000}"#)

        // nil participantID is omitted, and missing keys decode as nil
        // (C12 may not be able to scrape the id).
        let bare = ActiveSpeakerEvent(
            displayName: "Ana", participantID: nil,
            startEpochMillis: 1, endEpochMillis: 2)
        let bareJSON = String(decoding: try encoder.encode(bare), as: UTF8.self)
        #expect(bareJSON == #"{"display_name":"Ana","end_epoch_millis":2,"start_epoch_millis":1}"#)

        let decodedFull = try JSONDecoder().decode(ActiveSpeakerEvent.self, from: Data(fullJSON.utf8))
        #expect(decodedFull == full)
        let decodedBare = try JSONDecoder().decode(ActiveSpeakerEvent.self, from: Data(bareJSON.utf8))
        #expect(decodedBare == bare)
    }
}
