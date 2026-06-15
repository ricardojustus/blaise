import Foundation
import Testing
@testable import BlaiseCore

// C4 SpeakerMerger unit tests (no models): split trigger, word assignment,
// gap rules, boundary repair, healing, reconstruction, degeneracy,
// zero-overlap paths, consolidation, post-conditions, determinism.

private func word(_ text: String, _ start: Double, _ end: Double) -> ASRWord {
    ASRWord(word: text, startSeconds: start, endSeconds: end)
}

private func asr(_ start: Double, _ end: Double, _ text: String, words: [ASRWord]? = nil) -> ASRSegment {
    ASRSegment(startSeconds: start, endSeconds: end, text: text, words: words)
}

private func diar(_ label: String, _ start: Double, _ end: Double) -> DiarizedSegment {
    DiarizedSegment(speakerLabel: label, startSeconds: start, endSeconds: end)
}

private let meeting: MeetingID = "01TESTMEETING0000000000000"

@Suite struct SpeakerMergerTests {
    // MARK: - Primary whole-segment path

    @Test func singleSpeakerWholeSegmentKeepsOriginalTextAndTiming() {
        let result = SpeakerMerger.merge(
            asr: [asr(0, 10, " olá, mundo ", words: [word(" olá,", 0, 5), word(" mundo", 5, 10)])],
            diarization: [diar("S0", 0, 10)],
            meetingID: meeting)
        #expect(result.segments.count == 1)
        #expect(result.segments[0].speakerLabel == "S0")
        #expect(result.segments[0].text == " olá, mundo ")  // original, verbatim
        #expect(result.segments[0].startSeconds == 0)
        #expect(result.segments[0].endSeconds == 10)
        #expect(result.report == MergeReport(splits: 0, degenerateSegments: 0, gapAssignedWords: 0, healedFragments: 0))
    }

    @Test func majorityOverlapWinsWholeSegment() {
        // S1 covers 0.4 s = 4% — below BOTH split thresholds; no split, S0 majority.
        let result = SpeakerMerger.merge(
            asr: [asr(0, 10, "fala", words: (0..<10).map { word("w\($0)", Double($0), Double($0 + 1)) })],
            diarization: [diar("S0", 0, 9.6), diar("S1", 9.6, 10)],
            meetingID: meeting)
        #expect(result.segments.count == 1)
        #expect(result.segments[0].speakerLabel == "S0")
        #expect(result.report.splits == 0)
    }

    // MARK: - Split trigger (OR semantics)

    @Test func orTriggerFiresAtNineteenPointSevenPercentWhenAboveHalfSecond() {
        // The 19.7% / 5.9 s case: S1 covers 5.9 s of 30 s = 19.67% (< 20%)
        // but ≥ 0.5 s — the OR trigger fires.
        let words = (0..<15).map { word("w\($0)", Double($0 * 2), Double($0 * 2 + 2)) }
        let result = SpeakerMerger.merge(
            asr: [asr(0, 30, "long turn", words: words)],
            diarization: [diar("S0", 0, 24.1), diar("S1", 24.1, 30)],
            meetingID: meeting)
        #expect(result.report.splits == 1)
        #expect(result.segments.count == 2)
        #expect(result.segments[0].speakerLabel == "S0")
        #expect(result.segments[1].speakerLabel == "S1")
        // Words w0…w11 (midpoints 1…23) → S0; w12…w14 (25, 27, 29) → S1.
        #expect(result.segments[0].text == (0..<12).map { "w\($0)" }.joined(separator: " "))
        #expect(result.segments[1].text == "w12 w13 w14")
        // Reconstruction timing: first/last word bounds per piece.
        #expect(result.segments[0].startSeconds == 0)
        #expect(result.segments[0].endSeconds == 24)
        #expect(result.segments[1].startSeconds == 24)
        #expect(result.segments[1].endSeconds == 30)
    }

    @Test func twentyPercentCoverageTriggersEvenBelowHalfSecond() {
        // Short segment: S1 covers 0.4375 s = 21.9% of 2 s — below the 0.5 s
        // arm but the percentage arm fires (binary-exact boundary values).
        let words = [word("a", 0, 0.75), word("b", 0.75, 1.5625), word("c", 1.5625, 2.0)]
        let result = SpeakerMerger.merge(
            asr: [asr(0, 2, "a b c", words: words)],
            diarization: [diar("S0", 0, 1.5625), diar("S1", 1.5625, 2.0)],
            meetingID: meeting)
        // c (midpoint 1.8) → S1; sub-second 1-word piece → fragment → healed
        // into the left S0 piece, so no split survives — but the TRIGGER fired
        // (observable: healedFragments).
        #expect(result.report.healedFragments == 1)
        #expect(result.segments.count == 1)
        #expect(result.segments[0].speakerLabel == "S0")
    }

    // MARK: - Word-midpoint assignment conventions

    @Test func overlappingDiarizationMidpointGoesToGreaterTotalOverlap() {
        // Both cover midpoints in [3.9, 6]; S1's total overlap with the ASR
        // segment (6.1 s) beats S0's (6 s) → contested words go S1.
        let words = (0..<10).map { word("w\($0)", Double($0), Double($0 + 1)) }
        let result = SpeakerMerger.merge(
            asr: [asr(0, 10, "x", words: words)],
            diarization: [diar("S0", 0, 6), diar("S1", 3.9, 10)],
            meetingID: meeting)
        #expect(result.segments.count == 2)
        #expect(result.segments[0].speakerLabel == "S0")
        #expect(result.segments[0].text == "w0 w1 w2 w3")  // midpoints 0.5–3.5
        #expect(result.segments[1].speakerLabel == "S1")
        #expect(result.segments[1].text == (4..<10).map { "w\($0)" }.joined(separator: " "))
    }

    @Test func overlapTieGoesToEarlierStartingSegment() {
        // Equal total overlap (6 s each) → contested midpoints go to the
        // earlier-starting diarization segment (S0).
        let words = (0..<10).map { word("w\($0)", Double($0), Double($0 + 1)) }
        let result = SpeakerMerger.merge(
            asr: [asr(0, 10, "x", words: words)],
            diarization: [diar("S0", 0, 6), diar("S1", 4, 10)],
            meetingID: meeting)
        #expect(result.segments.count == 2)
        // Midpoints 4.5, 5.5 covered by both → S0.
        #expect(result.segments[0].text == (0..<6).map { "w\($0)" }.joined(separator: " "))
        #expect(result.segments[0].speakerLabel == "S0")
        #expect(result.segments[1].speakerLabel == "S1")
    }

    // MARK: - Gap-word rules

    @Test func gapWordWithinTwoSecondsTakesNearestSegment() {
        // w("mid") midpoint 4.0 in the 3–6 gap: distance 1.0 to S0, 2.0 to S1 → S0.
        let words = [
            word("a", 0, 1.5), word("b", 1.5, 3), word("mid", 3.5, 4.5),
            word("c", 6, 8), word("d", 8, 10),
        ]
        let result = SpeakerMerger.merge(
            asr: [asr(0, 10, "x", words: words)],
            diarization: [diar("S0", 0, 3), diar("S1", 6, 10)],
            meetingID: meeting)
        #expect(result.segments.count == 2)
        #expect(result.segments[0].text == "a b mid")
        #expect(result.segments[0].speakerLabel == "S0")
        #expect(result.report.gapAssignedWords == 1)
    }

    @Test func gapWordBeyondTwoSecondsTakesPreviousWordsSpeaker() {
        // w("far") midpoint 5.0: distance 3.0 to both → previous word's speaker (S0).
        let words = [word("a", 0, 2), word("far", 4.5, 5.5), word("b", 8, 10)]
        let result = SpeakerMerger.merge(
            asr: [asr(0, 10, "x", words: words)],
            diarization: [diar("S0", 0, 2), diar("S1", 8, 10)],
            meetingID: meeting)
        #expect(result.segments.count == 2)
        #expect(result.segments[0].text == "a far")
        #expect(result.segments[0].speakerLabel == "S0")
        #expect(result.segments[1].speakerLabel == "S1")
        #expect(result.report.gapAssignedWords == 1)
    }

    @Test func leadingGapWordTakesFollowingAssignedWordsSpeaker() {
        // w0 midpoint 0.5: > 2 s from everything, no previous → the first
        // FOLLOWING assigned word's speaker (w1 → S0).
        let words = [
            word("lead", 0, 1), word("a", 4, 5), word("b", 7.2, 8), word("c", 8, 9.5),
        ]
        let result = SpeakerMerger.merge(
            asr: [asr(0, 10, "x", words: words)],
            diarization: [diar("S0", 4, 7), diar("S1", 7, 10)],
            meetingID: meeting)
        #expect(result.segments.count == 2)
        #expect(result.segments[0].text == "lead a")
        #expect(result.segments[0].speakerLabel == "S0")
        #expect(result.segments[1].text == "b c")
        #expect(result.segments[1].speakerLabel == "S1")
    }

    @Test func noDirectAssignmentFallsBackToWholeSegmentPath() {
        // Edge-only coverage: both speakers qualify (0.6 s ≥ 0.5 s) but every
        // word midpoint is > 2 s from any diarization segment → whole-segment
        // primary path (coverage tie 0.6/0.6 → earliest overlapping start: S0).
        let words = [word("a", 4, 5), word("b", 5, 6)]
        let result = SpeakerMerger.merge(
            asr: [asr(0, 10, "a b", words: words)],
            diarization: [diar("S0", 0, 0.6), diar("S1", 9.4, 10)],
            meetingID: meeting)
        #expect(result.segments.count == 1)
        #expect(result.segments[0].speakerLabel == "S0")
        #expect(result.segments[0].text == "a b")  // original text kept
        #expect(result.segments[0].startSeconds == 0)
        #expect(result.segments[0].endSeconds == 10)
        #expect(result.report.splits == 0)
    }

    // MARK: - Piece boundary repair

    @Test func boundaryRepairClampsOverlappingPieceStarts() {
        // w2 starts (2.5) before the S0 piece ends (2.9) → repaired to 2.9.
        let words = [
            word("a", 0, 1.5), word("b", 1.4, 2.9), word("c", 2.5, 6), word("d", 6, 9),
        ]
        let result = SpeakerMerger.merge(
            asr: [asr(0, 9, "x", words: words)],
            diarization: [diar("S0", 0, 3), diar("S1", 3, 9)],
            meetingID: meeting)
        #expect(result.segments.count == 2)
        #expect(result.segments[0].endSeconds == 2.9)
        #expect(result.segments[1].startSeconds == 2.9)
        #expect(result.segments[1].text == "c d")
    }

    @Test func pieceEmptiedByRepairMergesIntoLeftNeighbor() {
        // "c" (midpoint 2.675) sits where S0 and S1 overlap; S1's greater
        // total overlap with the segment wins it, but the resulting S1 piece
        // [2.5, 2.85] is emptied by the clamp to the S0 piece's end (2.9) →
        // it merges into the left neighbor (S0 wins). Repair, not healing.
        let words = [
            word("a", 0, 1.5), word("b", 1.4, 2.9), word("c", 2.5, 2.85),
        ]
        let result = SpeakerMerger.merge(
            asr: [asr(0, 7, "x", words: words)],
            diarization: [diar("S0", 0, 2.92), diar("S1", 2.6, 7)],
            meetingID: meeting)
        #expect(result.segments.count == 1)
        #expect(result.segments[0].speakerLabel == "S0")
        #expect(result.segments[0].text == "a b c")
        #expect(result.segments[0].endSeconds == 2.9)
        #expect(result.report.healedFragments == 0)  // repair, not healing
        #expect(result.report.splits == 0)
    }

    // MARK: - Fragment healing (AND guardrail, one left-to-right pass)

    @Test func subSecondOneWordFragmentHealsIntoLeftNeighborAndWalkConsolidates() {
        // S1 piece = one word, 0.5 s → fragment (< 2 words AND < 1 s) →
        // absorbed by the left S0 piece; the following S0 piece then
        // consolidates during the walk → ONE segment.
        let words = [
            word("a", 0, 3), word("b", 3, 6), word("frag", 6.1, 6.6),
            word("c", 6.8, 8), word("d", 8, 10),
        ]
        let result = SpeakerMerger.merge(
            asr: [asr(0, 10, "x", words: words)],
            diarization: [diar("S0", 0, 6), diar("S1", 6, 6.7), diar("S0", 6.7, 10)],
            meetingID: meeting)
        #expect(result.segments.count == 1)
        #expect(result.segments[0].speakerLabel == "S0")
        #expect(result.segments[0].text == "a b frag c d")
        #expect(result.report.healedFragments == 1)
        #expect(result.report.splits == 0)  // healing collapsed the split
    }

    @Test func oneWordTurnOfAtLeastOneSecondIsNeverHealed() {
        // "approved" — one word but 1.1 s ≥ 1.0 s → NOT a fragment; kept.
        let words = [
            word("a", 0, 3), word("b", 3, 6), word("approved", 6.0, 7.1),
            word("c", 7.2, 8.5), word("d", 8.5, 10),
        ]
        let result = SpeakerMerger.merge(
            asr: [asr(0, 10, "x", words: words)],
            diarization: [diar("S0", 0, 6), diar("S1", 6, 7.15), diar("S0", 7.15, 10)],
            meetingID: meeting)
        #expect(result.segments.count == 3)
        #expect(result.segments.map(\.speakerLabel) == ["S0", "S1", "S0"])
        #expect(result.segments[1].text == "approved")
        #expect(result.report.healedFragments == 0)
        #expect(result.report.splits == 1)
    }

    @Test func leftmostFragmentMergesRightAndAbsorberSpeakerWins() {
        // The leftmost piece (one word, 0.5 s, S1) is a fragment → merges
        // RIGHT; the absorbing S0 piece's speaker wins.
        let words = [
            word("hm", 0, 0.5), word("a", 0.6, 3), word("b", 3, 6), word("c", 6, 9),
        ]
        let result = SpeakerMerger.merge(
            asr: [asr(0, 9, "x", words: words)],
            diarization: [diar("S1", 0, 0.55), diar("S0", 0.55, 9)],
            meetingID: meeting)
        #expect(result.segments.count == 1)
        #expect(result.segments[0].speakerLabel == "S0")
        #expect(result.segments[0].text == "hm a b c")
        #expect(result.segments[0].startSeconds == 0)
        #expect(result.report.healedFragments == 1)
    }

    @Test func loneFragmentPieceStaysWithoutNeighbors() {
        // A trigger-firing segment whose words collapse to one sub-second
        // piece: no neighbor exists; the piece stays (no healing possible).
        let words = [word("oi", 1.0, 1.5)]
        let result = SpeakerMerger.merge(
            asr: [asr(0.9, 1.6, " oi ", words: words)],
            diarization: [diar("S0", 0, 1.2), diar("S1", 1.2, 2)],
            meetingID: meeting)
        #expect(result.segments.count == 1)
        #expect(result.report.healedFragments == 0)
    }

    // MARK: - Reconstruction

    @Test func reconstructionTrimsWhitespaceEdgesAndPreservesPunctuation() {
        // Whisper-style words with leading spaces; punctuation is part of the
        // token and preserved.
        let words = [
            word(" Olá,", 0, 1), word(" tudo", 1, 2), word(" bem?", 2, 3),
            word(" Sim!", 5.5, 7), word(" claro.", 7, 9),
        ]
        let result = SpeakerMerger.merge(
            asr: [asr(0, 9, " Olá, tudo bem? Sim! claro.", words: words)],
            diarization: [diar("S0", 0, 4), diar("S1", 4, 9)],
            meetingID: meeting)
        #expect(result.segments.count == 2)
        #expect(result.segments[0].text == "Olá, tudo bem?")
        #expect(result.segments[1].text == "Sim! claro.")
        #expect(result.segments[0].startSeconds == 0)
        #expect(result.segments[0].endSeconds == 3)
        #expect(result.segments[1].startSeconds == 5.5)
        #expect(result.segments[1].endSeconds == 9)
    }

    // MARK: - Degeneracy

    @Test func nilOrEmptyWordsRouteToWholeSegmentPathAndAreCounted() {
        // Trigger would fire for both segments, but words are nil/empty →
        // whole-segment path, counted.
        let result = SpeakerMerger.merge(
            asr: [
                asr(0, 10, "no words at all", words: nil),
                asr(13, 23, "empty words", words: []),
            ],
            diarization: [diar("S0", 0, 5), diar("S1", 5, 18), diar("S0", 18, 23)],
            meetingID: meeting)
        #expect(result.report.degenerateSegments == 2)
        #expect(result.report.splits == 0)
        // Majority per segment: segment 1 ties S0/S1 at 5 s each → earliest
        // overlapping start wins (S0 at 0); segment 2 ties at 5 s → S1's
        // overlapping segment starts at 5 < S0's 18 → S1.
        #expect(result.segments[0].speakerLabel == "S0")
        #expect(result.segments[1].speakerLabel == "S1")
    }

    // MARK: - Zero-overlap segments

    @Test func zeroOverlapSegmentTakesNearestWithinTwoSeconds() {
        // Midpoint 21; S0 ends at 19 → distance exactly 2.0 → assigned.
        let result = SpeakerMerger.merge(
            asr: [asr(20, 22, "isolated")],
            diarization: [diar("S0", 10, 19)],
            meetingID: meeting)
        #expect(result.segments.count == 1)
        #expect(result.segments[0].speakerLabel == "S0")
    }

    @Test func zeroOverlapSegmentBeyondTwoSecondsIsUnattributed() {
        // Midpoint 21; S0 ends 18.9 → distance 2.1 → unattributed sentinel.
        let result = SpeakerMerger.merge(
            asr: [asr(20, 22, "isolated")],
            diarization: [diar("S0", 10, 18.9)],
            meetingID: meeting)
        #expect(result.segments[0].speakerLabel == TranscriptSegment.unattributed)
        #expect(result.segments[0].speakerName == nil)
    }

    // MARK: - Consolidation

    @Test func adjacentSameSpeakerSegmentsWithinTwoSecondGapMerge() {
        let result = SpeakerMerger.merge(
            asr: [asr(0, 5, "primeira parte."), asr(6.5, 10, "segunda parte.")],
            diarization: [diar("S0", 0, 10)],
            meetingID: meeting)
        #expect(result.segments.count == 1)
        #expect(result.segments[0].text == "primeira parte. segunda parte.")  // single-space join
        #expect(result.segments[0].startSeconds == 0)
        #expect(result.segments[0].endSeconds == 10)
    }

    @Test func consolidationRespectsGapAndSpeakerBoundaries() {
        let result = SpeakerMerger.merge(
            asr: [
                asr(0, 5, "a"), asr(7.5, 10, "b"),  // gap 2.5 s → NOT merged
                asr(10.5, 12, "c"),  // S1 → different speaker → NOT merged
            ],
            diarization: [diar("S0", 0, 10), diar("S1", 10.2, 12)],
            meetingID: meeting)
        #expect(result.segments.count == 3)
        #expect(result.segments.map(\.text) == ["a", "b", "c"])
        #expect(result.segments.map(\.speakerLabel) == ["S0", "S0", "S1"])
    }

    // MARK: - Post-conditions + determinism

    @Test func postConditionsHoldAndMergeIsDeterministic() {
        let words1 = (0..<10).map { word("w\($0)", Double($0), Double($0 + 1)) }
        let words2 = [word(" x.", 12, 13.5), word(" y,", 13.4, 15), word(" z", 15, 18)]
        let asrInput = [
            asr(0, 10, "first", words: words1),
            asr(12, 18, "second", words: words2),
            asr(19, 21, "third", words: nil),
            asr(40, 42, "orphan"),
        ]
        let diarInput = [
            diar("S0", 0, 4.3), diar("S1", 4.3, 11), diar("S1", 12, 16.2),
            diar("S0", 16.2, 22),
        ]
        let first = SpeakerMerger.merge(asr: asrInput, diarization: diarInput, meetingID: meeting)
        let second = SpeakerMerger.merge(asr: asrInput, diarization: diarInput, meetingID: meeting)
        #expect(first == second)  // determinism

        let segments = first.segments
        #expect(!segments.isEmpty)
        for (index, segment) in segments.enumerated() {
            #expect(segment.ord == index)  // ord re-sequenced 0…n−1
            #expect(segment.speakerName == nil)
            #expect(segment.endSeconds > segment.startSeconds)
            if index > 0 {
                #expect(segment.startSeconds > segments[index - 1].startSeconds)
                #expect(segment.startSeconds >= segments[index - 1].endSeconds)
            }
        }
        #expect(segments.last?.speakerLabel == TranscriptSegment.unattributed)
    }
}
