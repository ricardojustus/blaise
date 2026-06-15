import Foundation

// C11/C7 v3.2: interleave the mic and system transcript tracks of a captured
// meeting. Pinned tie-break: start time, then track (mic first), then the
// segment's original in-track ord; `ord` is re-sequenced globally afterward.
// The per-track monotonic/non-overlap invariants hold PER TRACK — cross-track
// overlap is legal (people talk over each other; C4 v5.3 post-condition
// scope note).

// C7 v3.7/v3.8: cross-track echo dedup. In two-track captures WITHOUT
// headphones the system track's audio (other participants) bleeds
// acoustically into the mic, so the mic track grows near-duplicate segments
// of OTHER speakers' words under the user's label (validation gap 5).
//
// v3.8 granularity: suppression runs on the RAW ASR segments of both tracks,
// BEFORE SpeakerMerger consolidates the mic track. Field evidence: merge
// consolidation produces user turns up to ~400 s, so a MIXED turn (genuine
// user speech with an embedded echo of the other speaker) never crosses the
// whole-segment similarity gate — only pure-echo turns got caught post-merge.
// Raw whisper segments (median ~1.8 s) discriminate cleanly; the merge then
// consolidates only the survivors. A MIC segment is dropped as echo iff
//   (a) its time span overlaps system segments within ±1.5 s (codec/
//       transcription jitter), AND
//   (b) it carries ≥ 5 normalized tokens (short utterances — "sim", "ok",
//       "tá bom" — are NEVER dropped: they coincide across tracks by
//       chance), AND
//   (c) its folded token sequence (case/diacritic-folded, punctuation-
//       stripped) matches the concatenated overlapping-system token window
//       at ≥ 0.85 similarity — order-respecting token-level edit distance
//       with free leading/trailing system tokens (approximate-substring
//       alignment), normalized by the mic token count. Order sensitivity
//       kills the bag-of-common-words false positive; the window
//       concatenation catches mic bleed that consolidated across system
//       speaker turns. At 5 tokens the threshold demands an EXACT match;
//       longer segments tolerate proportional ASR jitter (1 edit per ~7
//       tokens).
// Only the MIC copy is ever dropped: its `user` attribution is assigned by
// construction (every mic-track segment), so a near-duplicate is evidence
// the label is wrong, while the system copy's attribution is diarization-
// grounded. The symmetric direction (the user's words echoing into the
// SYSTEM track via a remote participant's speakers) is deliberately NOT
// suppressed: dropping a system segment risks deleting another
// participant's genuine words, the user's mic is the source (remote echo
// requires the far end's echo cancellation to fail — rare), and when it
// does happen the damage is a redundant duplicate under an S-label, not
// content loss. False-dropping the user's real words is the failure this
// pass must never commit; every gate errs toward keeping.

public enum EchoSuppressor {
    static let overlapToleranceSeconds = 1.5
    static let minimumTokenCount = 5
    static let similarityThreshold = 0.85
    /// Causality jitter: an acoustic echo on the mic cannot START before its
    /// system-track source does (sound is effectively instantaneous at room
    /// scale; this allowance covers ASR timestamp jitter only). A mic
    /// segment that PRECEDES every matching system candidate is the
    /// ORIGINAL — the user spoke first and the other participant repeated it
    /// (read-backs of figures/commitments have exactly this shape) — and is
    /// always kept (v1.1-wave audit H-1).
    static let causalityJitterSeconds = 0.5

    /// Returns the RAW mic ASR segments that survive echo suppression
    /// (relative order preserved) plus the dropped count. System segments
    /// are never modified or dropped. Runs pre-merge (v3.8): inputs are
    /// each track's raw ASR segments, not consolidated transcript turns.
    public static func suppress(
        mic: [ASRSegment], system: [ASRSegment]
    ) -> (kept: [ASRSegment], droppedCount: Int) {
        guard !mic.isEmpty, !system.isEmpty else { return (mic, 0) }
        let orderedSystem = system.enumerated()
            .sorted {
                $0.element.startSeconds != $1.element.startSeconds
                    ? $0.element.startSeconds < $1.element.startSeconds
                    : $0.offset < $1.offset
            }
            .map(\.element)
        let systemTokens = orderedSystem.map { tokens($0.text) }

        var kept: [ASRSegment] = []
        var dropped = 0
        for segment in mic {
            let micTokens = tokens(segment.text)
            guard micTokens.count >= minimumTokenCount else {
                kept.append(segment)
                continue
            }
            // Concatenated token window of system segments overlapping the
            // mic span (tolerance-expanded), in start order. CAUSALITY: a
            // candidate qualifies only if it STARTED before the mic segment
            // ENDED (minus jitter) — a source that begins after the mic
            // segment finished cannot have echoed into it. This keeps the
            // user's ORIGINAL when the other participant repeats it
            // afterwards (read-backs), while a long mic segment can still
            // match sources that started mid-segment.
            var window: [String] = []
            for (index, candidate) in orderedSystem.enumerated() {
                let overlaps =
                    min(segment.endSeconds, candidate.endSeconds + overlapToleranceSeconds)
                    > max(segment.startSeconds, candidate.startSeconds - overlapToleranceSeconds)
                let causal =
                    candidate.startSeconds - causalityJitterSeconds < segment.endSeconds
                if overlaps && causal { window += systemTokens[index] }
            }
            guard !window.isEmpty else {
                kept.append(segment)
                continue
            }
            if similarity(of: micTokens, in: window) >= similarityThreshold {
                dropped += 1
            } else {
                kept.append(segment)
            }
        }
        return (kept, dropped)
    }

    /// Normalized comparison tokens: case/diacritic fold (C5's canonical
    /// mode), whitespace split, punctuation stripped per token.
    static func tokens(_ text: String) -> [String] {
        VocabNormalization.canonicalMode(text)
            .split(whereSeparator: { $0.isWhitespace })
            .map { token in
                String(String.UnicodeScalarView(
                    token.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
            }
            .filter { !$0.isEmpty }
    }

    /// Approximate-substring similarity: token-level Levenshtein distance of
    /// `needle` against the best-matching contiguous span of `haystack`
    /// (leading and trailing haystack tokens are free), normalized by the
    /// needle length. 1.0 = `needle` occurs verbatim somewhere in `haystack`.
    static func similarity(of needle: [String], in haystack: [String]) -> Double {
        guard !needle.isEmpty else { return 0 }
        guard !haystack.isEmpty else { return 0 }
        let n = haystack.count
        // dp over needle rows; row 0 = 0 everywhere (free start position).
        var previous = [Int](repeating: 0, count: n + 1)
        var current = [Int](repeating: 0, count: n + 1)
        for i in 1 ... needle.count {
            current[0] = i
            for j in 1 ... n {
                let cost = needle[i - 1] == haystack[j - 1] ? 0 : 1
                current[j] = min(previous[j - 1] + cost, previous[j] + 1, current[j - 1] + 1)
            }
            swap(&previous, &current)
        }
        let distance = previous.min()!  // free end position
        return 1 - Double(distance) / Double(needle.count)
    }
}

public enum TwoTrackInterleaver {
    public static func interleave(
        mic: [TranscriptSegment], system: [TranscriptSegment]
    ) -> [TranscriptSegment] {
        struct Keyed {
            let segment: TranscriptSegment
            let trackRank: Int  // mic = 0, system = 1 (mic first on ties)
            let originalOrd: Int
        }
        let keyed =
            mic.map { Keyed(segment: $0, trackRank: 0, originalOrd: $0.ord) }
            + system.map { Keyed(segment: $0, trackRank: 1, originalOrd: $0.ord) }
        let sorted = keyed.sorted {
            if $0.segment.startSeconds != $1.segment.startSeconds {
                return $0.segment.startSeconds < $1.segment.startSeconds
            }
            if $0.trackRank != $1.trackRank { return $0.trackRank < $1.trackRank }
            return $0.originalOrd < $1.originalOrd
        }
        return sorted.enumerated().map { index, keyed in
            var segment = keyed.segment
            segment.ord = index
            return segment
        }
    }
}
