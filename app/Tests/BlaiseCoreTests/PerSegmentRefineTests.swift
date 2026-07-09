import Foundation
import Testing

@testable import BlaiseCore

// C4 v6 — per-segment refinement (SpeakerResolver.refineWithPerSegmentTimeline).
// Corrects cluster BLEED and names multi-speaker BLOBS the cluster pass leaves
// unresolved, from the same active-speaker timeline. Recall-safe; policy (b):
// a contradicted name is cleared to unknown rather than kept wrong. One big
// diarization cluster pins the drift offset to 0 so cases test the policy, not
// alignment. FICTIONAL data only.

private let recStart: Int64 = 1_765_000_000_000

private func ev(_ name: String, _ start: Double, _ end: Double, pid: String? = nil) -> ActiveSpeakerEvent {
    ActiveSpeakerEvent(
        displayName: name, participantID: pid,
        startEpochMillis: recStart + Int64(start * 1000),
        endEpochMillis: recStart + Int64(end * 1000))
}

private func seg(
    _ ord: Int, _ start: Double, _ end: Double, label: String, name: String? = nil
) -> TranscriptSegment {
    TranscriptSegment(
        meetingID: "01TESTMEETING0000000000000", ord: ord,
        startSeconds: start, endSeconds: end, speakerLabel: label, speakerName: name, text: "line \(ord)")
}

private func refine(
    _ segments: [TranscriptSegment], events: [ActiveSpeakerEvent]?, cluster: (Double, Double) = (0, 100)
) -> [TranscriptSegment] {
    let names = Set((events ?? []).map(\.displayName))
    return SpeakerResolver.refineWithPerSegmentTimeline(
        segments: segments,
        diarization: [DiarizedSegment(speakerLabel: "S0", startSeconds: cluster.0, endSeconds: cluster.1)],
        hints: SpeakerHints(
            activeSpeakerEvents: events, recordingStartEpochMillis: events == nil ? recStart : recStart),
        audioDuration: 100, eventNames: names)
}

@Suite struct PerSegmentRefineTests {
    @Test func fillsUnnamedBlobBySegmentDominantSpeaker() {
        // One cluster, two segments, no cluster-level name → each filled by the
        // speaker the timeline shows in that window.
        let out = refine(
            [seg(0, 0, 10, label: "S0"), seg(1, 20, 30, label: "S0")],
            events: [ev("Alice", 0, 10), ev("Bob", 20, 30)])
        #expect(out[0].speakerName == "Alice")
        #expect(out[1].speakerName == "Bob")
    }

    @Test func replacesBledNameWhenAnotherSpeakerDominates() {
        // Segment cluster-named "Alice", but Alice is absent here and Bob owns
        // the window → corrected to Bob.
        let out = refine(
            [seg(0, 0, 10, label: "S0", name: "Alice")],
            events: [ev("Bob", 0, 10), ev("Alice", 50, 60)])
        #expect(out[0].speakerName == "Bob")
    }

    @Test func clearsContradictedNameWhenNoConfidentReplacement() {
        // Alice absent; Bob and Carol split the window evenly → no dominant →
        // policy (b): clear to unknown rather than keep wrong "Alice".
        let out = refine(
            [seg(0, 0, 10, label: "S0", name: "Alice")],
            events: [ev("Bob", 0, 5), ev("Carol", 5, 10), ev("Alice", 50, 60)])
        #expect(out[0].speakerName == nil)
    }

    @Test func keepsCurrentNameWhenTimelineStillSupportsIt() {
        // Alice speaks briefly (present ≥ floor) though Bob is louder → keep
        // Alice; a real interjection is not stolen by the louder neighbour.
        let out = refine(
            [seg(0, 0, 10, label: "S0", name: "Alice")],
            events: [ev("Alice", 0, 3), ev("Bob", 3, 10)])
        #expect(out[0].speakerName == "Alice")
    }

    @Test func ignoresScraperNoiseName() {
        // A Meet UI caption logged as a "speaker" (sentence) must NOT win, even
        // with more overlap than the real speaker.
        let out = refine(
            [seg(0, 0, 10, label: "S0")],
            events: [ev("People can still see your full video", 0, 10), ev("Alice", 0, 8)])
        #expect(out[0].speakerName == "Alice")
    }

    @Test func neverTouchesUserMicTrack() {
        let out = refine(
            [seg(0, 0, 10, label: TranscriptSegment.userLabel, name: "Sam")],
            events: [ev("Bob", 0, 10)])
        #expect(out[0].speakerLabel == TranscriptSegment.userLabel)
        #expect(out[0].speakerName == "Sam")
    }

    @Test func noEventsIsNoOp() {
        let input = [seg(0, 0, 10, label: "S0", name: "Alice"), seg(1, 20, 30, label: "S1")]
        let out = refine(input, events: nil)
        #expect(out == input)
    }

    @Test func isPlausibleSpeakerNameRejectsCaptionsAcceptsNames() {
        #expect(SpeakerResolver.isPlausibleSpeakerName("Dana Whitfield"))
        #expect(SpeakerResolver.isPlausibleSpeakerName("Sam Okonkwo Reyes"))
        #expect(!SpeakerResolver.isPlausibleSpeakerName("People can still see your full video"))
        #expect(!SpeakerResolver.isPlausibleSpeakerName("Sure, that makes sense."))
        #expect(!SpeakerResolver.isPlausibleSpeakerName("   "))
    }
}
