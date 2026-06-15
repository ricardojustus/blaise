import FluidAudio
import Foundation
import Testing
@testable import BlaiseCore

@Suite struct TokenSegmenterTests {
    private func timing(
        _ token: String, _ start: Double, _ end: Double, id: Int = 0, confidence: Float = 0.9
    ) -> TokenTiming {
        TokenTiming(token: token, tokenId: id, startTime: start, endTime: end, confidence: confidence)
    }

    // MARK: Word merge (port fidelity, synthetic rules)

    @Test func mergesWhitespacePrefixedTokensIntoWords() {
        // " Es" "tava," " né" "?" → "Estava," + "né?" (the CLI rule: a
        // whitespace-prefixed token starts a new word).
        let words = TokenSegmenter.mergeTokensIntoWords([
            timing(" Es", 0.16, 0.24),
            timing("tava,", 0.24, 0.40),
            timing(" né", 0.48, 0.56),
            timing("?", 0.56, 0.60),
        ])
        #expect(words.map(\.word) == ["Estava,", "né?"])
        #expect(words[0].startSeconds == 0.16)
        #expect(words[0].endSeconds == 0.40)
        #expect(words[1].startSeconds == 0.48)
        #expect(words[1].endSeconds == 0.60)
    }

    @Test func firstTokenWithoutWhitespacePrefixStartsAWord() {
        let words = TokenSegmenter.mergeTokensIntoWords([
            timing("Oi", 0.0, 0.2),
            timing(" tudo", 0.3, 0.5),
        ])
        #expect(words.map(\.word) == ["Oi", "tudo"])
    }

    @Test func emptyTimingsYieldNoWords() {
        #expect(TokenSegmenter.mergeTokensIntoWords([]).isEmpty)
    }

    // MARK: Sentence grouping

    @Test func splitsOnSentenceFinalPunctuation() {
        let segments = TokenSegmenter.segments(
            tokenTimings: [
                timing(" Acabou.", 0.0, 0.5),
                timing(" Agora", 0.6, 0.9),
                timing(" sim", 0.95, 1.2),
            ],
            fullText: "Acabou. Agora sim",
            audioDuration: 10
        )
        #expect(segments.map(\.text) == ["Acabou.", "Agora sim"])
        #expect(segments[0].endSeconds == 0.5)
        #expect(segments[1].startSeconds == 0.6)
        // Words populated, word merge precedes sentence grouping.
        #expect(segments[0].words?.map(\.word) == ["Acabou."])
        #expect(segments[1].words?.map(\.word) == ["Agora", "sim"])
    }

    @Test func splitsOnLongPause() {
        let segments = TokenSegmenter.segments(
            tokenTimings: [
                timing(" antes", 0.0, 0.5),
                timing(" depois", 2.0, 2.4),  // 1.5 s gap ≥ 1.0 s threshold
            ],
            fullText: "antes depois",
            audioDuration: 10
        )
        #expect(segments.map(\.text) == ["antes", "depois"])
    }

    @Test func shortPauseAndNoPunctuationStaysOneSegment() {
        let segments = TokenSegmenter.segments(
            tokenTimings: [
                timing(" uma", 0.0, 0.3),
                timing(" frase", 0.8, 1.1),  // 0.5 s gap < threshold
            ],
            fullText: "uma frase",
            audioDuration: 10
        )
        #expect(segments.map(\.text) == ["uma frase"])
        #expect(segments[0].startSeconds == 0.0)
        #expect(segments[0].endSeconds == 1.1)
        #expect(segments[0].words?.count == 2)
    }

    @Test func emptyTimingsFallBackToSingleFullDurationSegment() {
        let segments = TokenSegmenter.segments(
            tokenTimings: [], fullText: "  texto inteiro da reunião  ", audioDuration: 42.5)
        #expect(segments.count == 1)
        #expect(segments[0].startSeconds == 0)
        #expect(segments[0].endSeconds == 42.5)
        #expect(segments[0].text == "texto inteiro da reunião")
        #expect(segments[0].words == nil)  // no word detail available — honest nil
    }

    @Test func emptyTimingsAndEmptyTextYieldNothing() {
        #expect(TokenSegmenter.segments(tokenTimings: [], fullText: "  ", audioDuration: 10).isEmpty)
    }
}
