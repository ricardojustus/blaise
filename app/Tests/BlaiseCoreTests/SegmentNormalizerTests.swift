import Foundation
import Testing
@testable import BlaiseCore

@Suite struct SegmentNormalizerTests {
    private func segment(
        _ start: Double, _ end: Double, _ text: String = "fala", words: [ASRWord]? = nil
    ) -> ASRSegment {
        ASRSegment(startSeconds: start, endSeconds: end, text: text, words: words)
    }

    // MARK: Rule 0a (out-of-scope-script guard)

    @Test func rule0aDropsCyrillicMajoritySegments() {
        let (kept, report) = SegmentNormalizer.normalize(
            [
                segment(0, 1, "Хорошо, спасибо большое"),
                segment(1, 2, "tudo bem"),
                segment(2, 3, "Я не знаю что это"),
            ],
            audioDuration: 10)
        #expect(kept.map(\.text) == ["tudo bem"])
        #expect(report.droppedNonLatinScript == 2)
    }

    @Test func rule0aDropsCJKAndGreekAndArabicMajoritySegments() {
        let (kept, report) = SegmentNormalizer.normalize(
            [
                segment(0, 1, "今日は会議です"),
                segment(1, 2, "καλημέρα σας"),
                segment(2, 3, "مرحبا بالجميع"),
                segment(3, 4, "ok then"),
            ],
            audioDuration: 10)
        #expect(kept.map(\.text) == ["ok then"])
        #expect(report.droppedNonLatinScript == 3)
    }

    @Test func rule0aKeepsPortugueseDiacritics() {
        let (kept, report) = SegmentNormalizer.normalize(
            [
                segment(0, 1, "ações"),
                segment(1, 2, "café"),
                segment(2, 3, "não é uma decisão fácil"),
                segment(3, 4, "atenção à promoção"),
            ],
            audioDuration: 10)
        #expect(kept.count == 4)
        #expect(report.droppedNonLatinScript == 0)
    }

    @Test func rule0aHalfNonLatinIsKeptThresholdIsStrictlyOverHalf() {
        // "да ok": 2 Cyrillic letters vs 2 Latin letters = exactly 50 % —
        // the rule is > 50 %, so the segment survives.
        let (kept, report) = SegmentNormalizer.normalize(
            [segment(0, 1, "да ok")], audioDuration: 10)
        #expect(kept.count == 1)
        #expect(report.droppedNonLatinScript == 0)
    }

    @Test func rule0aIgnoresDigitsAndPunctuation() {
        // Letters decide: 3 Cyrillic letters vs 2 Latin among digits and
        // punctuation → majority non-Latin → dropped.
        let (kept, report) = SegmentNormalizer.normalize(
            [segment(0, 1, "что 12.000,00 — ok!!!"), segment(1, 2, "R$ 1.000,00!")],
            audioDuration: 10)
        #expect(kept.map(\.text) == ["R$ 1.000,00!"])
        #expect(report.droppedNonLatinScript == 1)
    }

    // MARK: Rule 0b (repetition-run collapse)

    @Test func rule0bCollapsesRunOfThreeToFirstSegment() {
        // Identity is the NORMALIZED text: case, punctuation, and outer
        // whitespace differences still form one run; the FIRST survives
        // with its original text.
        let (kept, report) = SegmentNormalizer.normalize(
            [
                segment(0, 1, "Tchau, tchau!"),
                segment(1, 2, " tchau tchau "),
                segment(2, 3, "TCHAU TCHAU."),
                segment(3, 4, "até amanhã"),
            ],
            audioDuration: 10)
        #expect(kept.map(\.text) == ["Tchau, tchau!", "até amanhã"])
        #expect(report.droppedRepetitionRun == 2)
    }

    @Test func rule0bKeepsRunOfTwo() {
        let (kept, report) = SegmentNormalizer.normalize(
            [segment(0, 1, "sim"), segment(1, 2, "sim"), segment(2, 3, "ok")],
            audioDuration: 10)
        #expect(kept.map(\.text) == ["sim", "sim", "ok"])
        #expect(report.droppedRepetitionRun == 0)
    }

    @Test func rule0bCollapsesLongRunAndCountsAllDropped() {
        let run = (0 ..< 7).map { segment(Double($0), Double($0) + 1, "é") }
        let (kept, report) = SegmentNormalizer.normalize(run, audioDuration: 10)
        #expect(kept.count == 1)
        #expect(kept[0].startSeconds == 0)
        #expect(report.droppedRepetitionRun == 6)
    }

    @Test func rule0bCollapsesEachRunIndependently() {
        let (kept, report) = SegmentNormalizer.normalize(
            [
                segment(0, 1, "é"), segment(1, 2, "é"), segment(2, 3, "é"),
                segment(3, 4, "quebra"),
                segment(4, 5, "tá"), segment(5, 6, "tá"), segment(6, 7, "tá"), segment(7, 8, "tá"),
            ],
            audioDuration: 10)
        #expect(kept.map(\.text) == ["é", "quebra", "tá"])
        #expect(report.droppedRepetitionRun == 5)
    }

    @Test func rule0bNonAdjacentRepeatsAreNotARun() {
        let (kept, report) = SegmentNormalizer.normalize(
            [segment(0, 1, "ok"), segment(1, 2, "sim"), segment(2, 3, "ok"), segment(3, 4, "sim")],
            audioDuration: 10)
        #expect(kept.count == 4)
        #expect(report.droppedRepetitionRun == 0)
    }

    @Test func rule0bPunctuationOnlySegmentsNeverFormRuns() {
        // Their normalized key is empty — "identical nothing" is not a run;
        // they pass through to the later rules untouched.
        let (kept, report) = SegmentNormalizer.normalize(
            [segment(0, 1, "..."), segment(1, 2, "..."), segment(2, 3, "...")],
            audioDuration: 10)
        #expect(kept.count == 3)
        #expect(report.droppedRepetitionRun == 0)
    }

    @Test func rule0aAndRule0bMixedInterleaveComesOutClean() {
        // The field shape in miniature: real PT/EN interleaved with Cyrillic
        // garbage and a repetition run. Garbage is removed FIRST (rule 0a),
        // so it cannot break the run it interrupts.
        let (kept, report) = SegmentNormalizer.normalize(
            [
                segment(0, 1, "vamos começar"),
                segment(1, 2, "Я не знаю"),
                segment(2, 3, "tchau tchau"),
                segment(3, 4, "Хорошо спасибо"),
                segment(4, 5, "tchau tchau"),
                segment(5, 6, "tchau tchau"),
                segment(6, 7, "see you tomorrow"),
            ],
            audioDuration: 10)
        #expect(kept.map(\.text) == ["vamos começar", "tchau tchau", "see you tomorrow"])
        #expect(report.droppedNonLatinScript == 2)
        #expect(report.droppedRepetitionRun == 2)
    }

    // MARK: Rule 1

    @Test func rule1DropsEmptyAndWhitespaceOnlyText() {
        let (kept, report) = SegmentNormalizer.normalize(
            [segment(0, 1, ""), segment(1, 2, "  \n\t "), segment(2, 3, "ok")],
            audioDuration: 10)
        #expect(kept.map(\.text) == ["ok"])
        #expect(report.droppedEmpty == 2)
    }

    // MARK: Rule 2

    @Test func rule2DropsZeroAndNegativeLength() {
        let (kept, report) = SegmentNormalizer.normalize(
            [segment(1, 1), segment(2, 1.5), segment(3, 4, "ok")],
            audioDuration: 10)
        #expect(kept.map(\.text) == ["ok"])
        #expect(report.droppedZeroLength == 2)
    }

    // MARK: Rule 3

    @Test func rule3DropsEntirelyOutOfBounds() {
        // The hallucination-tail class: non-empty, positive duration, fully
        // past EOF — dropped, never clamped into zero-width visibility masks.
        let (kept, report) = SegmentNormalizer.normalize(
            [segment(0, 5, "ok"), segment(10, 11, "loop"), segment(12, 13, "loop")],
            audioDuration: 10)
        #expect(kept.map(\.text) == ["ok"])
        #expect(report.droppedOutOfBounds == 2)
    }

    @Test func rule3BoundaryStartExactlyAtDurationIsDropped() {
        let (kept, report) = SegmentNormalizer.normalize(
            [segment(10, 11, "loop")], audioDuration: 10)
        #expect(kept.isEmpty)
        #expect(report.droppedOutOfBounds == 1)
    }

    // MARK: Rule 4 (straddlers)

    @Test func rule4ClampsAndKeepsStraddlerRetainingMajority() {
        // 9.4→10.5 on a 10.0 file: retains 0.6/1.1 ≈ 55 % and ≥ 0.2 s → kept.
        let (kept, report) = SegmentNormalizer.normalize(
            [segment(9.4, 10.5, "final word")], audioDuration: 10)
        #expect(kept.count == 1)
        #expect(kept[0].endSeconds == 10)
        #expect(report.clampedRetained == 1)
        #expect(report.clampedDropped == 0)
    }

    @Test func rule4DropsStraddlerRetainingUnderHalf() {
        // The real hallucination-loop first member shape: retains 21 % —
        // clamping alone would smuggle it into the transcript.
        let (kept, report) = SegmentNormalizer.normalize(
            [segment(9.8, 10.8, "loop")], audioDuration: 10)
        #expect(kept.isEmpty)
        #expect(report.clampedDropped == 1)
        #expect(report.clampedRetained == 0)
    }

    @Test func rule4DropsStraddlerRetainingUnderMinimumDuration() {
        // Retains 0.15 s (> 50 % of 0.25 s) but under the 0.2 s floor → drop.
        let (kept, report) = SegmentNormalizer.normalize(
            [segment(9.85, 10.1, "blip")], audioDuration: 10)
        #expect(kept.isEmpty)
        #expect(report.clampedDropped == 1)
    }

    // MARK: Rule 5 (overlaps)

    @Test func rule5ResolvesFloatingPointOverlap() {
        let (kept, report) = SegmentNormalizer.normalize(
            [segment(0, 2.0000000000000004, "a"), segment(2.0, 3, "b")],
            audioDuration: 10)
        #expect(kept.count == 2)
        #expect(kept[1].startSeconds == 2.0000000000000004)
        #expect(report.overlapsResolved == 1)
    }

    @Test func rule5DropsSegmentEmptiedByOverlapResolution() {
        // Second segment is entirely inside the first → resolution empties it.
        let (kept, report) = SegmentNormalizer.normalize(
            [segment(0, 3, "a"), segment(1, 2, "b"), segment(3, 4, "c")],
            audioDuration: 10)
        #expect(kept.map(\.text) == ["a", "c"])
        #expect(report.overlapsResolved == 1)
    }

    // MARK: Rule 5b (word clamping)

    @Test func rule5bClampsWordsToFinalSegmentBoundsAndDropsOutliers() throws {
        let words = [
            ASRWord(word: "out-before", startSeconds: 0.0, endSeconds: 0.9),
            ASRWord(word: "straddle-in", startSeconds: 0.8, endSeconds: 1.5),
            ASRWord(word: "inside", startSeconds: 1.5, endSeconds: 2.0),
            ASRWord(word: "straddle-out", startSeconds: 9.5, endSeconds: 10.5),
            ASRWord(word: "out-after", startSeconds: 10.2, endSeconds: 10.8),
        ]
        // Segment straddles EOF (clamped to 10) and overlaps the previous
        // (start pushed to 1).
        let (kept, _) = SegmentNormalizer.normalize(
            [segment(0, 1, "a"), segment(0.5, 10.4, "b", words: words)],
            audioDuration: 10)
        #expect(kept.count == 2)
        let clamped = try #require(kept[1].words)
        #expect(clamped.map(\.word) == ["straddle-in", "inside", "straddle-out"])
        #expect(clamped[0].startSeconds == 1.0)  // clamped up to segment start
        #expect(clamped[2].endSeconds == 10.0)  // clamped down to segment end
        for word in clamped {
            #expect(word.startSeconds >= kept[1].startSeconds)
            #expect(word.endSeconds <= kept[1].endSeconds)
        }
    }

    @Test func rule5bLeavesNilWordsNil() {
        let (kept, _) = SegmentNormalizer.normalize([segment(0, 1, "a")], audioDuration: 10)
        #expect(kept[0].words == nil)
    }

    // MARK: Rule 6 (post-conditions on a survivor set)

    @Test func postconditionsHoldOnMixedInput() {
        let input = [
            segment(0, 1, "a"), segment(1, 1, ""), segment(0.9999999999999999, 2, "b"),
            segment(5, 4, "neg"), segment(9.9, 10.6, "tail"), segment(11, 12, "loop"),
        ]
        let (kept, _) = SegmentNormalizer.normalize(input, audioDuration: 10)
        for (index, seg) in kept.enumerated() {
            #expect(!seg.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(seg.startSeconds >= 0 && seg.endSeconds <= 10)
            #expect(seg.endSeconds > seg.startSeconds)
            if index > 0 {
                #expect(seg.startSeconds >= kept[index - 1].endSeconds)
                #expect(seg.startSeconds > kept[index - 1].startSeconds)
            }
        }
    }

    // MARK: Combined real-shape pathology (synthetic)

    @Test func realFixtureReportMatchesProbedPathology() throws {
        // The full mlx-whisper tail-pathology shape in one synthetic input:
        // normal in-bounds speech, two floating-point overlaps, a run of
        // empty tail rows (rule 1), a boundary straddler retaining < 50 %
        // (clamp-dropped, rule 4), and a cluster of segments entirely past
        // EOF (rule 3). All counts are asserted exactly against a fixed
        // synthetic audioDuration; no audio file or committed fixture.
        let audioDuration = 100.0
        let input: [ASRSegment] = [
            // Five well-formed, in-bounds, non-overlapping speech segments.
            segment(0, 1, "alpha"),
            segment(1, 2, "bravo"),
            segment(2, 3, "charlie"),
            segment(3, 4, "delta"),
            segment(4, 5, "echo"),
            // Two floating-point overlaps: next.start just below prev.end.
            segment(5, 6, "foxtrot"),
            segment(5.999999999999999, 7, "golf"),
            segment(7, 8, "hotel"),
            segment(7.999999999999999, 9, "india"),
            // Empty tail rows (rule 1) — varied whitespace, in bounds.
            segment(10, 10.1, ""),
            segment(11, 11.1, "  "),
            segment(12, 12.1, "\n\t"),
            segment(13, 13.1, ""),
            segment(14, 14.1, ""),
            // Boundary straddler retaining 20 % of 1.0 s → clamp-dropped.
            segment(99.8, 100.8, "tail"),
            // Three segments entirely past EOF (the hallucination-loop class).
            segment(100, 101, "loop"),
            segment(105, 106, "echo-loop"),
            segment(110, 111, "ghost-loop"),
        ]

        let (kept, report) = SegmentNormalizer.normalize(input, audioDuration: audioDuration)

        #expect(report.droppedEmpty == 5)
        #expect(report.droppedZeroLength == 0)
        #expect(report.droppedOutOfBounds == 3)
        #expect(report.clampedRetained == 0)
        #expect(report.clampedDropped == 1)
        #expect(report.overlapsResolved == 2)
        #expect(kept.count == 9)

        // Post-conditions over the full survivor set.
        for (index, seg) in kept.enumerated() {
            #expect(!seg.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(seg.startSeconds >= 0 && seg.endSeconds <= audioDuration)
            #expect(seg.endSeconds > seg.startSeconds)
            if index > 0 { #expect(seg.startSeconds >= kept[index - 1].endSeconds) }
        }
    }

    @Test func realWordsFixtureKeepsWordsInsideBounds() throws {
        // The words-bearing variant: speech segments carrying word timings,
        // some words inside bounds and some straddling/outside the final
        // segment bounds (which themselves move under clamp/overlap), plus
        // empty tail rows. Asserts the empty-drop count and the word-inside-
        // bounds invariant. Synthetic; no committed fixture.
        let audioDuration = 100.0
        let input: [ASRSegment] = [
            // Plain in-bounds speech with all-inside words.
            segment(0, 2, "alpha bravo", words: [
                ASRWord(word: "alpha", startSeconds: 0.0, endSeconds: 1.0),
                ASRWord(word: "bravo", startSeconds: 1.0, endSeconds: 2.0),
            ]),
            // Overlap pushes this segment's start to 2.0; the first word
            // straddles the new start and must clamp up to it.
            segment(1.9999999999999998, 4, "charlie delta", words: [
                ASRWord(word: "charlie", startSeconds: 1.8, endSeconds: 3.0),
                ASRWord(word: "delta", startSeconds: 3.0, endSeconds: 4.0),
            ]),
            // Three empty tail rows (rule 1) carrying empty word arrays.
            segment(10, 10.1, "", words: []),
            segment(11, 11.1, "  ", words: []),
            segment(12, 12.1, "", words: []),
            // Boundary straddler clamped to EOF; its last word straddles EOF
            // and must clamp down, the one fully past EOF is dropped.
            segment(99.0, 100.6, "echo foxtrot", words: [
                ASRWord(word: "echo", startSeconds: 99.0, endSeconds: 99.8),
                ASRWord(word: "foxtrot", startSeconds: 99.8, endSeconds: 100.4),
                ASRWord(word: "ghost", startSeconds: 100.4, endSeconds: 100.6),
            ]),
        ]

        let (kept, report) = SegmentNormalizer.normalize(input, audioDuration: audioDuration)
        #expect(report.droppedEmpty == 3)
        #expect(!kept.isEmpty)
        for seg in kept {
            guard let words = seg.words else { continue }
            for word in words {
                #expect(word.startSeconds >= seg.startSeconds)
                #expect(word.endSeconds <= seg.endSeconds)
            }
        }
    }
}
