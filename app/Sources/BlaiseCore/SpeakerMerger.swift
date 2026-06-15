import Foundation
import os

// C4: merge diarization speaker turns with ASR segments. Pure, deterministic,
// O(segments × diarization). Input ASR segments are SegmentNormalizer output
// (strictly monotonic, non-overlapping, words clamped to segment bounds —
// C3 guarantees, trusted). Diarization segments may overlap (legal input).

public struct MergeResult: Sendable, Equatable {
    public let segments: [TranscriptSegment]
    public let report: MergeReport
}

public struct MergeReport: Sendable, Equatable {
    /// ASR segments whose split path produced ≥ 2 final pieces.
    public let splits: Int
    /// Segments with nil/empty `words` routed to the whole-segment path.
    public let degenerateSegments: Int
    /// Words whose midpoint lay in a diarization gap (assigned via the
    /// nearest-within-2 s, previous-word-continuity, or following-word rules).
    public let gapAssignedWords: Int
    /// Fragments absorbed by the healing pass.
    public let healedFragments: Int

    public init(splits: Int, degenerateSegments: Int, gapAssignedWords: Int, healedFragments: Int) {
        self.splits = splits
        self.degenerateSegments = degenerateSegments
        self.gapAssignedWords = gapAssignedWords
        self.healedFragments = healedFragments
    }
}

public enum SpeakerMerger {
    /// Split-trigger thresholds (research §4, OR semantics).
    static let splitCoverageSeconds = 0.5
    static let splitCoverageFraction = 0.2
    /// Nearest-diarization-segment reach for gap words / zero-overlap segments,
    /// and the same-speaker consolidation gap (validated rule).
    static let nearestReachSeconds = 2.0
    static let consolidationGapSeconds = 2.0
    /// Fragment guardrail (AND semantics): a piece is a fragment iff
    /// `< 2 words AND < 1.0 s`.
    static let fragmentMinSeconds = 1.0

    private static let logger = Logger(subsystem: BlaiseBundle.identifier, category: "speaker.merger")

    public static func merge(
        asr: [ASRSegment], diarization: [DiarizedSegment], meetingID: MeetingID
    ) -> MergeResult {
        var splits = 0
        var degenerate = 0
        var gapWords = 0
        var healed = 0

        // Stage 1: per ASR segment, produce (speakerLabel, start, end, text) pieces.
        var pieces: [(label: String, start: Double, end: Double, text: String)] = []
        for segment in asr {
            let coverage = speakerCoverage(of: segment, in: diarization)
            let qualifying = coverage.values.filter {
                $0 >= splitCoverageSeconds
                    || $0 >= splitCoverageFraction * (segment.endSeconds - segment.startSeconds)
            }
            let triggerFires = qualifying.count >= 2

            if triggerFires {
                guard let words = segment.words, !words.isEmpty else {
                    // Per-segment degeneracy: whole-segment path, counted.
                    degenerate += 1
                    pieces.append(wholeSegmentPiece(segment, diarization: diarization, coverage: coverage))
                    continue
                }
                if let (split, gapAssigned, healedCount) = splitPieces(
                    segment: segment, words: words, diarization: diarization)
                {
                    gapWords += gapAssigned
                    healed += healedCount
                    if split.count >= 2 { splits += 1 }
                    pieces.append(contentsOf: split)
                } else {
                    // No word got a direct assignment (edge-only coverage) or
                    // no non-empty piece survived: whole-segment fallback.
                    pieces.append(wholeSegmentPiece(segment, diarization: diarization, coverage: coverage))
                }
            } else {
                if segment.words?.isEmpty ?? true { degenerate += 1 }
                pieces.append(wholeSegmentPiece(segment, diarization: diarization, coverage: coverage))
            }
        }

        // Stage 2: consolidation — adjacent same-speaker segments with
        // gap ≤ 2.0 s merge (single-space join).
        var consolidated: [(label: String, start: Double, end: Double, text: String)] = []
        for piece in pieces {
            if let last = consolidated.last, last.label == piece.label,
                piece.start - last.end <= consolidationGapSeconds
            {
                consolidated[consolidated.count - 1] = (
                    last.label, last.start, max(last.end, piece.end), last.text + " " + piece.text
                )
            } else {
                consolidated.append(piece)
            }
        }

        // Stage 3: TranscriptSegments with re-sequenced ord; post-conditions
        // (established by the piece boundary repair) asserted.
        let segments = consolidated.enumerated().map { index, piece in
            TranscriptSegment(
                meetingID: meetingID,
                ord: index,
                startSeconds: piece.start,
                endSeconds: piece.end,
                speakerLabel: piece.label,
                speakerName: nil,
                text: piece.text)
        }
        for (index, segment) in segments.enumerated() {
            assert(segment.endSeconds > segment.startSeconds, "empty merged segment")
            if index > 0 {
                assert(segment.startSeconds > segments[index - 1].startSeconds, "non-monotonic starts")
                assert(segment.startSeconds >= segments[index - 1].endSeconds, "overlapping segments")
            }
            assert(segment.speakerName == nil, "speakerName must be nil after merge")
        }

        return MergeResult(
            segments: segments,
            report: MergeReport(
                splits: splits, degenerateSegments: degenerate,
                gapAssignedWords: gapWords, healedFragments: healed))
    }

    // MARK: - Conventions (pinned by the spec)

    /// Summed overlap seconds per speaker over `[start, end]` (overlapping
    /// diarization segments double-count harmlessly).
    private static func speakerCoverage(
        of segment: ASRSegment, in diarization: [DiarizedSegment]
    ) -> [String: Double] {
        var coverage: [String: Double] = [:]
        for d in diarization {
            let overlap = min(segment.endSeconds, d.endSeconds) - max(segment.startSeconds, d.startSeconds)
            if overlap > 0 { coverage[d.speakerLabel, default: 0] += overlap }
        }
        return coverage
    }

    /// Midpoint distance = distance from the midpoint to the diarization
    /// segment's INTERVAL (0 if inside, else distance to the nearest edge).
    private static func distance(_ midpoint: Double, to d: DiarizedSegment) -> Double {
        if midpoint < d.startSeconds { return d.startSeconds - midpoint }
        if midpoint > d.endSeconds { return midpoint - d.endSeconds }
        return 0
    }

    /// Selects the best diarization segment for a midpoint among candidates at
    /// equal footing: greater total overlap with the enclosing ASR segment;
    /// tie → the earlier-starting segment (then earlier end, then label, for
    /// full determinism on degenerate ties).
    private static func bestCandidate(
        _ candidates: [DiarizedSegment], enclosing segment: ASRSegment
    ) -> DiarizedSegment? {
        candidates.min { a, b in
            let overlapA = min(segment.endSeconds, a.endSeconds) - max(segment.startSeconds, a.startSeconds)
            let overlapB = min(segment.endSeconds, b.endSeconds) - max(segment.startSeconds, b.startSeconds)
            if overlapA != overlapB { return overlapA > overlapB }
            if a.startSeconds != b.startSeconds { return a.startSeconds < b.startSeconds }
            if a.endSeconds != b.endSeconds { return a.endSeconds < b.endSeconds }
            return a.speakerLabel < b.speakerLabel
        }
    }

    /// Speaker for a midpoint: covering segment per the conventions; in a gap,
    /// the nearest segment within `nearestReachSeconds` (distance ties broken
    /// by the same conventions). nil when nothing is within reach.
    private static func speaker(
        atMidpoint midpoint: Double, enclosing segment: ASRSegment, diarization: [DiarizedSegment]
    ) -> (label: String, wasGap: Bool)? {
        let covering = diarization.filter { $0.startSeconds <= midpoint && midpoint <= $0.endSeconds }
        if !covering.isEmpty {
            return (bestCandidate(covering, enclosing: segment)!.speakerLabel, false)
        }
        let reachable = diarization.filter { distance(midpoint, to: $0) <= nearestReachSeconds }
        guard !reachable.isEmpty else { return nil }
        let nearestDistance = reachable.map { distance(midpoint, to: $0) }.min()!
        let nearest = reachable.filter { distance(midpoint, to: $0) == nearestDistance }
        return (bestCandidate(nearest, enclosing: segment)!.speakerLabel, true)
    }

    // MARK: - Whole-segment path

    /// Primary path: greatest summed overlap; ties broken by the earliest
    /// start among the speaker's overlapping segments, then label. Zero
    /// overlap → nearest within 2.0 s of the segment midpoint, else the
    /// `unattributed` sentinel. Keeps original text/timing.
    private static func wholeSegmentPiece(
        _ segment: ASRSegment, diarization: [DiarizedSegment], coverage: [String: Double]
    ) -> (label: String, start: Double, end: Double, text: String) {
        let label: String
        if !coverage.isEmpty {
            func earliestOverlappingStart(of speaker: String) -> Double {
                diarization
                    .filter {
                        $0.speakerLabel == speaker
                            && min(segment.endSeconds, $0.endSeconds)
                                - max(segment.startSeconds, $0.startSeconds) > 0
                    }
                    .map(\.startSeconds).min()!
            }
            label = coverage.keys.min { a, b in
                if coverage[a]! != coverage[b]! { return coverage[a]! > coverage[b]! }
                let startA = earliestOverlappingStart(of: a)
                let startB = earliestOverlappingStart(of: b)
                if startA != startB { return startA < startB }
                return a < b
            }!
        } else {
            let midpoint = (segment.startSeconds + segment.endSeconds) / 2
            if let assigned = speaker(atMidpoint: midpoint, enclosing: segment, diarization: diarization) {
                label = assigned.label
            } else {
                label = TranscriptSegment.unattributed
            }
        }
        return (label, segment.startSeconds, segment.endSeconds, segment.text)
    }

    // MARK: - Split path

    private struct Piece {
        var label: String
        var words: [ASRWord]
        var start: Double
        var end: Double

        var isFragment: Bool {
            words.count < 2 && (end - start) < SpeakerMerger.fragmentMinSeconds
        }
    }

    /// Word-level split. Returns nil when no word gets a direct assignment
    /// (whole-segment fallback applies) or no non-empty piece survives.
    private static func splitPieces(
        segment: ASRSegment, words: [ASRWord], diarization: [DiarizedSegment]
    ) -> (pieces: [(label: String, start: Double, end: Double, text: String)], gapAssigned: Int, healed: Int)? {
        // Word assignment: direct (covered midpoint, or gap-nearest within
        // 2.0 s); unassigned words take the previous word's speaker; a
        // leading run takes the first FOLLOWING assigned word's speaker.
        var assigned: [String?] = []
        var gapAssigned = 0
        for word in words {
            let midpoint = (word.startSeconds + word.endSeconds) / 2
            if let hit = speaker(atMidpoint: midpoint, enclosing: segment, diarization: diarization) {
                assigned.append(hit.label)
                if hit.wasGap { gapAssigned += 1 }
            } else {
                assigned.append(nil)
                gapAssigned += 1
            }
        }
        guard assigned.contains(where: { $0 != nil }) else { return nil }
        // Continuity fill (left-to-right), then leading run from the first
        // directly assigned word.
        for index in assigned.indices {
            if assigned[index] == nil, index > 0 { assigned[index] = assigned[index - 1] }
        }
        if assigned[0] == nil {
            let following = assigned.first(where: { $0 != nil })!!
            for index in assigned.indices {
                if assigned[index] == nil { assigned[index] = following } else { break }
            }
        }

        // Contiguous same-speaker words form pieces.
        var pieces: [Piece] = []
        for (word, label) in zip(words, assigned.map { $0! }) {
            if var last = pieces.last, last.label == label {
                last.words.append(word)
                last.end = word.endSeconds
                pieces[pieces.count - 1] = last
            } else {
                pieces.append(
                    Piece(label: label, words: [word], start: word.startSeconds, end: word.endSeconds))
            }
        }

        // Piece boundary repair (C3 rule-5 analogue — word timings within a
        // segment may overlap or tie): left-to-right,
        // `next.start = max(next.start, prev.end)`; a piece emptied by this
        // merges into its left neighbor (an empty leftmost piece — only
        // possible from degenerate word timings — merges right). Establishes
        // the post-conditions.
        var repaired: [Piece] = []
        var leadingEmpty: Piece?
        for piece in pieces {
            var current = piece
            if let lead = leadingEmpty {
                current.words = lead.words + current.words
                current.start = min(current.start, lead.start)
                leadingEmpty = nil
            }
            if let prev = repaired.last {
                current.start = max(current.start, prev.end)
            }
            if current.start >= current.end {
                if repaired.isEmpty {
                    leadingEmpty = current
                } else {
                    repaired[repaired.count - 1].words += current.words
                    repaired[repaired.count - 1].end = max(repaired[repaired.count - 1].end, current.end)
                }
            } else {
                repaired.append(current)
            }
        }
        guard !repaired.isEmpty else { return nil }

        // Fragment healing (AND guardrail): ONE deterministic left-to-right
        // pass — a fragment merges into its LEFT neighbor (the leftmost piece
        // merges right), the absorber's speaker wins, and adjacent
        // same-speaker pieces consolidate as the walk proceeds. Order IS the
        // rule.
        var healedPieces: [Piece] = []
        var pendingLeftmostFragment: Piece?
        var healedCount = 0
        for piece in repaired {
            var current = piece
            if let pending = pendingLeftmostFragment {
                // The leftmost fragment merges right: this piece absorbs it.
                current.words = pending.words + current.words
                current.start = pending.start
                pendingLeftmostFragment = nil
                healedCount += 1
            }
            if current.isFragment {
                if healedPieces.isEmpty {
                    pendingLeftmostFragment = current
                    continue
                }
                // Merge into the LEFT neighbor; the absorber's speaker wins.
                healedPieces[healedPieces.count - 1].words += current.words
                healedPieces[healedPieces.count - 1].end = max(
                    healedPieces[healedPieces.count - 1].end, current.end)
                healedCount += 1
                continue
            }
            if let last = healedPieces.last, last.label == current.label {
                // Walk consolidation of adjacent same-speaker pieces.
                healedPieces[healedPieces.count - 1].words += current.words
                healedPieces[healedPieces.count - 1].end = max(
                    healedPieces[healedPieces.count - 1].end, current.end)
            } else {
                healedPieces.append(current)
            }
        }
        if let pending = pendingLeftmostFragment {
            // A lone fragment has no absorber; it stays.
            healedPieces.append(pending)
        }

        // Reconstruction: text = words joined by single spaces, each word's
        // whitespace-only edges trimmed (punctuation is part of the word
        // token and is preserved); timing from the (repaired) piece bounds.
        let result = healedPieces.map { piece in
            let text = piece.words
                .map { $0.word.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return (piece.label, piece.start, piece.end, text)
        }
        return (result, gapAssigned, healedCount)
    }
}
