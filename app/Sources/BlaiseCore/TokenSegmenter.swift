import FluidAudio
import Foundation

/// FluidAudio's library `ASRResult` carries token-level timings only; the
/// CLI's timestamped output comes from a CLI-target helper. This ports that
/// helper and groups the words into sentence-ish segments for `ASRSegment`.
enum TokenSegmenter {
    /// Pause length that splits two words into separate segments. The CLI has
    /// no sentence grouping to port (its merge stops at words), so this
    /// threshold is ours: 1.0 s of silence is a safe clause boundary for
    /// meeting speech and well above Parakeet's intra-word token gaps.
    static let pauseSplitThreshold: TimeInterval = 1.0

    /// Sentence-final punctuation that closes a segment.
    static let sentenceTerminators: Set<Character> = [".", "!", "?", "…"]

    /// Faithful port of `WordTimingMerger.mergeTokensIntoWords` from
    /// FluidAudioCLI (Sources/FluidAudioCLI/Commands/ASR/Parakeet/
    /// SlidingWindow/TranscribeCommand.swift:133-186 at 0.15.2): a token
    /// prefixed with whitespace (" ", "\n", "\t" — TranscribeCommand.swift:146)
    /// starts a new word; any other token appends to the current word.
    /// Confidence is dropped (`ASRWord` carries word/start/end only).
    static func mergeTokensIntoWords(_ tokenTimings: [TokenTiming]) -> [ASRWord] {
        guard !tokenTimings.isEmpty else { return [] }

        var words: [ASRWord] = []
        var currentWord = ""
        var currentStartTime: TimeInterval?
        var currentEndTime: TimeInterval = 0

        for timing in tokenTimings {
            let token = timing.token
            if token.hasPrefix(" ") || token.hasPrefix("\n") || token.hasPrefix("\t") {
                if !currentWord.isEmpty, let startTime = currentStartTime {
                    words.append(ASRWord(word: currentWord, startSeconds: startTime, endSeconds: currentEndTime))
                }
                currentWord = token.trimmingCharacters(in: .whitespacesAndNewlines)
                currentStartTime = timing.startTime
                currentEndTime = timing.endTime
            } else {
                if currentStartTime == nil {
                    currentStartTime = timing.startTime
                }
                currentWord += token
                currentEndTime = timing.endTime
            }
        }
        if !currentWord.isEmpty, let startTime = currentStartTime {
            words.append(ASRWord(word: currentWord, startSeconds: startTime, endSeconds: currentEndTime))
        }
        return words
    }

    /// Token timings → `ASRSegment`s with `words` populated (word merge
    /// precedes sentence grouping). Empty timings → a single full-duration
    /// segment carrying the whole text (no word detail available — honest nil).
    static func segments(
        tokenTimings: [TokenTiming],
        fullText: String,
        audioDuration: Double
    ) -> [ASRSegment] {
        let words = mergeTokensIntoWords(tokenTimings)
        guard !words.isEmpty else {
            let trimmed = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            return [ASRSegment(startSeconds: 0, endSeconds: audioDuration, text: trimmed, words: nil)]
        }

        var segments: [ASRSegment] = []
        var bucket: [ASRWord] = []

        func flush() {
            guard let first = bucket.first, let last = bucket.last else { return }
            segments.append(
                ASRSegment(
                    startSeconds: first.startSeconds,
                    endSeconds: last.endSeconds,
                    text: bucket.map(\.word).joined(separator: " "),
                    words: bucket
                ))
            bucket.removeAll(keepingCapacity: true)
        }

        for (index, word) in words.enumerated() {
            bucket.append(word)
            let endsSentence = word.word.last.map(sentenceTerminators.contains) ?? false
            let longPause =
                index + 1 < words.count
                && words[index + 1].startSeconds - word.endSeconds >= pauseSplitThreshold
            if endsSentence || longPause {
                flush()
            }
        }
        flush()
        return segments
    }
}
