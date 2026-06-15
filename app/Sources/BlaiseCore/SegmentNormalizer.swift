import Foundation

/// What normalization did to an engine's raw segments. Engines log this;
/// the raw output stays verbatim in `ASRResult.rawPayload`, so the
/// pathology remains observable (C7's regression artifact can compare raw
/// vs normalized).
public struct NormalizationReport: Codable, Sendable, Equatable {
    /// Rule 0a: letter content majority (>50 %) in non-Latin script.
    public var droppedNonLatinScript: Int
    /// Rule 0b: members of 3+-long identical-text runs after the first.
    public var droppedRepetitionRun: Int
    /// Rule 1: empty/whitespace-only text.
    public var droppedEmpty: Int
    /// Rule 2: `end <= start`.
    public var droppedZeroLength: Int
    /// Rule 3: `start >= audioDuration` (the hallucination-tail class).
    public var droppedOutOfBounds: Int
    /// Rule 4: boundary-straddlers clamped to `audioDuration` and kept.
    public var clampedRetained: Int
    /// Rule 4: straddlers whose retained portion was < 50 % or < 0.2 s.
    public var clampedDropped: Int
    /// Rule 5: floating-point overlaps resolved (`next.start = prev.end`).
    public var overlapsResolved: Int

    public init(
        droppedNonLatinScript: Int = 0,
        droppedRepetitionRun: Int = 0,
        droppedEmpty: Int = 0,
        droppedZeroLength: Int = 0,
        droppedOutOfBounds: Int = 0,
        clampedRetained: Int = 0,
        clampedDropped: Int = 0,
        overlapsResolved: Int = 0
    ) {
        self.droppedNonLatinScript = droppedNonLatinScript
        self.droppedRepetitionRun = droppedRepetitionRun
        self.droppedEmpty = droppedEmpty
        self.droppedZeroLength = droppedZeroLength
        self.droppedOutOfBounds = droppedOutOfBounds
        self.clampedRetained = clampedRetained
        self.clampedDropped = clampedDropped
        self.overlapsResolved = overlapsResolved
    }

    enum CodingKeys: String, CodingKey {
        case droppedNonLatinScript = "dropped_non_latin_script"
        case droppedRepetitionRun = "dropped_repetition_run"
        case droppedEmpty = "dropped_empty"
        case droppedZeroLength = "dropped_zero_length"
        case droppedOutOfBounds = "dropped_out_of_bounds"
        case clampedRetained = "clamped_retained"
        case clampedDropped = "clamped_dropped"
        case overlapsResolved = "overlaps_resolved"
    }
}

/// Normative, shared, quality-bearing (C3 spec): applied by BOTH engines
/// before returning `ASRResult`. Rules run in order against `audioDuration`
/// read from the WAV header.
///
/// Rule order: the content rules 0a (script guard) and 0b (repetition-run
/// collapse) run FIRST, over the raw decoder sequence — 0a before 0b so
/// out-of-scope-script garbage can neither anchor nor break a repetition
/// run, and both before the timing rules 1–6 so runs are judged on decoder
/// adjacency, not on whatever adjacency survives the timing drops. Field
/// basis (an early field recording): Whisper rendered acoustic bleed
/// as ~340 pure-Cyrillic segments plus contiguous 3+-long identical-text
/// repetition runs; Blaise meetings are PT/EN only by product definition.
public enum SegmentNormalizer {
    public static func normalize(
        _ segments: [ASRSegment],
        audioDuration: Double
    ) -> (segments: [ASRSegment], report: NormalizationReport) {
        var report = NormalizationReport()

        // Rule 0a: drop segments whose letter content is majority (>50 %)
        // non-Latin script. Letters only — digits, punctuation, and symbols
        // do not count either way; Latin-with-diacritics (PT) is Latin.
        var scriptClean: [ASRSegment] = []
        scriptClean.reserveCapacity(segments.count)
        for segment in segments {
            if isMajorityNonLatin(segment.text) {
                report.droppedNonLatinScript += 1
                continue
            }
            scriptClean.append(segment)
        }

        // Rule 0b: collapse runs of 3+ consecutive segments with identical
        // normalized text (trimmed, lowercased, punctuation/symbol-stripped)
        // to the run's FIRST segment. Runs of 2 are kept (legitimate
        // back-to-back repeats exist; the pathology is 3+). Segments whose
        // normalized text is empty never participate in runs.
        var collapsed: [ASRSegment] = []
        collapsed.reserveCapacity(scriptClean.count)
        let keys = scriptClean.map { repetitionKey($0.text) }
        var index = 0
        while index < scriptClean.count {
            var runEnd = index + 1
            if !keys[index].isEmpty {
                while runEnd < scriptClean.count, keys[runEnd] == keys[index] {
                    runEnd += 1
                }
            }
            if runEnd - index >= 3 {
                collapsed.append(scriptClean[index])
                report.droppedRepetitionRun += runEnd - index - 1
            } else {
                collapsed.append(contentsOf: scriptClean[index ..< runEnd])
            }
            index = runEnd
        }

        var kept: [ASRSegment] = []
        kept.reserveCapacity(collapsed.count)

        for raw in collapsed {
            var segment = raw
            // Rule 1: drop empty/whitespace-only text.
            if segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                report.droppedEmpty += 1
                continue
            }
            // Rule 2: drop end <= start.
            if segment.endSeconds <= segment.startSeconds {
                report.droppedZeroLength += 1
                continue
            }
            // Rule 3: drop entirely out of bounds (start >= duration). Out-of-bounds
            // content is dropped, never clamped into zero-width segments.
            if segment.startSeconds >= audioDuration {
                report.droppedOutOfBounds += 1
                continue
            }
            // Rule 4: boundary-straddlers (start < duration < end): clamp end, then
            // drop if the retained portion is < 50 % of the original or < 0.2 s.
            if segment.endSeconds > audioDuration {
                let original = segment.endSeconds - segment.startSeconds
                let retained = audioDuration - segment.startSeconds
                if retained < original * 0.5 || retained < 0.2 {
                    report.clampedDropped += 1
                    continue
                }
                segment.endSeconds = audioDuration
                report.clampedRetained += 1
            }
            // Rule 5: resolve floating-point overlaps against the previous survivor.
            if let previous = kept.last, segment.startSeconds < previous.endSeconds {
                report.overlapsResolved += 1
                segment.startSeconds = previous.endSeconds
                if segment.startSeconds >= segment.endSeconds {
                    continue  // resolution emptied the segment
                }
            }
            // Rule 5b: clamp word timings to the segment's final bounds; drop
            // words falling entirely outside.
            if let words = segment.words {
                segment.words = words.compactMap { word in
                    var word = word
                    if word.endSeconds <= segment.startSeconds || word.startSeconds >= segment.endSeconds {
                        return nil
                    }
                    word.startSeconds = max(word.startSeconds, segment.startSeconds)
                    word.endSeconds = min(word.endSeconds, segment.endSeconds)
                    return word
                }
            }
            kept.append(segment)
        }

        // Rule 6: post-conditions.
        assertPostconditions(kept, audioDuration: audioDuration)
        return (kept, report)
    }

    /// Rule 0a classifier: true when >50 % of the text's alphabetic scalars
    /// fall outside the Latin script blocks. Texts with no letters at all
    /// (digits/punctuation-only) are never majority non-Latin.
    private static func isMajorityNonLatin(_ text: String) -> Bool {
        var latin = 0
        var nonLatin = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            if isLatinScript(scalar) { latin += 1 } else { nonLatin += 1 }
        }
        let letters = latin + nonLatin
        return letters > 0 && nonLatin * 2 > letters
    }

    /// Latin-script blocks (Swift exposes no Unicode script property, so the
    /// block ranges are explicit): ASCII letters, Latin-1 Supplement,
    /// Latin Extended-A/B, combining diacritics (NFD-decomposed PT accents),
    /// and Latin Extended Additional. Cyrillic (0x400+), Greek (0x370+),
    /// Arabic, CJK, etc. all fall outside.
    private static func isLatinScript(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x41 ... 0x5A, 0x61 ... 0x7A,  // ASCII A–Z, a–z
            0xC0 ... 0xFF,  // Latin-1 Supplement letters (ç, õ, é, …)
            0x100 ... 0x24F,  // Latin Extended-A/B
            0x300 ... 0x36F,  // combining diacritical marks (NFD PT)
            0x1E00 ... 0x1EFF:  // Latin Extended Additional
            return true
        default:
            return false
        }
    }

    /// Rule 0b identity key: trimmed, lowercased, punctuation- and
    /// symbol-stripped text.
    private static func repetitionKey(_ text: String) -> String {
        let stripped = CharacterSet.punctuationCharacters.union(.symbols)
        var scalars = String.UnicodeScalarView()
        for scalar in text.lowercased().unicodeScalars where !stripped.contains(scalar) {
            scalars.append(scalar)
        }
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func assertPostconditions(_ segments: [ASRSegment], audioDuration: Double) {
        for (index, segment) in segments.enumerated() {
            assert(!segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "empty text survived")
            assert(segment.startSeconds >= 0 && segment.endSeconds <= audioDuration, "segment out of bounds")
            assert(segment.endSeconds > segment.startSeconds, "non-positive segment")
            if index > 0 {
                assert(segment.startSeconds >= segments[index - 1].endSeconds, "overlap survived")
                assert(segment.startSeconds > segments[index - 1].startSeconds, "starts not strictly monotonic")
            }
        }
    }
}
