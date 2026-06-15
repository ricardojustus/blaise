import Foundation

/// One applied correction. `range` is in ORIGINAL string coordinates and spans
/// from the first window token's core start to the last window token's core end
/// (outer edge punctuation excluded — it is preserved around the replacement).
public struct Correction: Sendable, Equatable {
    public enum Stage: String, Sendable {
        case exact
        case alias
    }

    public let range: Range<String.Index>
    public let original: String
    public let canonical: String
    public let stage: Stage
}

public struct CorrectionResult: Sendable, Equatable {
    public let correctedText: String
    public let corrections: [Correction]
}

public enum VocabularyCorrectorError: Error, Equatable {
    /// Two different canonicals claim the same folded surface form (derivation
    /// collision assertion violated; defense-in-depth at load time).
    case surfaceCollision(surface: String, canonicalA: String, canonicalB: String)
}

/// Deterministic post-ASR vocabulary correction (C5 spec v5.1):
/// exact canonical restoration (case/diacritics) + curated alias substitution,
/// single left-to-right pass, windows tried longest→shortest; entries whose
/// cores are all stop-listed never fire (wholly delegated to C6). No fuzzy
/// matching (D9 as amended). Touches nothing else. One documented edge: a
/// firing (mixed) window with non-canonical inter-token whitespace is
/// normalized to the canonical spelling, single spaces included.
public struct VocabularyCorrector: Sendable {
    private struct EntryToken: Sendable {
        let core: String // normalized per the entry's mode
        let prefix: String // raw edge punctuation carried by the entry token
        let suffix: String
    }

    private enum Kind: Sendable {
        case canonical
        case alias
    }

    private struct TableEntry: Sendable {
        let kind: Kind
        let canonical: String
        let tokens: [EntryToken]
        /// Folded cores for suppression membership (canonical kind only).
        let foldedCores: [String]
    }

    /// Window length → key → entry. Canonical keys are canonical-mode core joins;
    /// alias keys are alias-mode core joins. Cross-kind key conflicts are
    /// impossible under the folded-surface collision assertion.
    private let tables: [Int: [String: TableEntry]]
    private let maxWindow: Int
    private let suppression: Set<String>

    public init(dictionary: VocabularyDictionary, suppression: Set<String>) throws {
        var tables: [Int: [String: TableEntry]] = [:]
        var maxWindow = 1
        // Folded surface → canonical, for the collision assertion.
        var foldedSurfaces: [String: String] = [:]

        func register(surface: String, canonical: String, kind: Kind) throws {
            let surfaceTokens = VocabTokenizer.tokenize(surface)
            guard !surfaceTokens.isEmpty else { return }
            // Defense in depth (G1 §5a gate 0b is primary): a surface whose
            // tokens all peel to empty cores (pure edge punctuation, e.g. `---`)
            // would register under the empty window key `""` and fire on
            // standalone punctuation transcript tokens. Never register it.
            guard surfaceTokens.contains(where: { !$0.core.isEmpty }) else { return }
            let normalize: (String) -> String
            switch kind {
            case .canonical: normalize = { VocabNormalization.canonicalMode($0) }
            case .alias: normalize = { VocabNormalization.aliasMode($0) }
            }
            let entryTokens = surfaceTokens.map {
                EntryToken(core: normalize($0.core), prefix: $0.prefix, suffix: $0.suffix)
            }
            let key = entryTokens.map(\.core).joined(separator: " ")
            let foldedKey = VocabNormalization.canonicalMode(surfaceTokens.map(\.core).joined(separator: " "))
            if let existing = foldedSurfaces[foldedKey], existing != canonical {
                throw VocabularyCorrectorError.surfaceCollision(
                    surface: foldedKey, canonicalA: existing, canonicalB: canonical
                )
            }
            foldedSurfaces[foldedKey] = canonical
            let foldedCores = surfaceTokens.map { VocabNormalization.canonicalMode($0.core) }
            let entry = TableEntry(kind: kind, canonical: canonical, tokens: entryTokens, foldedCores: foldedCores)
            // Duplicate surfaces mapping to the same canonical merge (first wins).
            if tables[surfaceTokens.count]?[key] == nil {
                tables[surfaceTokens.count, default: [:]][key] = entry
                maxWindow = max(maxWindow, surfaceTokens.count)
            }
        }

        for entry in dictionary.entries {
            try register(surface: entry.canonical, canonical: entry.canonical, kind: .canonical)
            for alias in entry.aliases {
                try register(surface: alias, canonical: entry.canonical, kind: .alias)
            }
        }
        self.tables = tables
        self.maxWindow = maxWindow
        self.suppression = suppression
    }

    public func correct(_ text: String) -> CorrectionResult {
        let tokens = VocabTokenizer.tokenize(text)
        var corrections: [Correction] = []
        var i = 0
        while i < tokens.count {
            var advanced = false
            let longest = min(maxWindow, tokens.count - i)
            lengths: for length in stride(from: longest, through: 1, by: -1) {
                guard let table = tables[length] else { continue }
                let window = Array(tokens[i ..< i + length])

                // 1. Alias hit (alias-mode; plain window validity).
                let aliasKey = window.map { VocabNormalization.aliasMode($0.core) }.joined(separator: " ")
                if let entry = table[aliasKey], entry.kind == .alias, isPlainValid(window) {
                    emit(entry, window: window, text: text, stage: .alias, into: &corrections)
                    i += length
                    advanced = true
                    break lengths
                }

                // 2. Canonical hit (canonical-mode; validity with the entry-punctuation exception).
                let canonKey = window.map { VocabNormalization.canonicalMode($0.core) }.joined(separator: " ")
                if let entry = table[canonKey], entry.kind == .canonical,
                   isValidWithException(window, entry: entry) {
                    let surface = windowSurface(window, in: text)
                    if surface == entry.canonical {
                        // Self-match: emit nothing, consume the window.
                        i += length
                    } else if entry.foldedCores.filter({ !$0.isEmpty }).allSatisfy(suppression.contains) {
                        // Suppress: a fully-suppressible entry never fires, whatever
                        // the diff (case-only or punctuation-bearing — it must not
                        // insert title punctuation into ordinary speech); restoration
                        // is wholly delegated to C6. Advance ONE token so shorter/
                        // alias windows at subsequent positions stay reachable (M-2).
                        i += 1
                    } else {
                        emit(entry, window: window, text: text, stage: .exact, into: &corrections)
                        i += length
                    }
                    advanced = true
                    break lengths
                }
            }
            if !advanced { i += 1 } // 3. No hit.
        }
        return CorrectionResult(
            correctedText: apply(corrections, to: text),
            corrections: corrections
        )
    }

    // MARK: - Window mechanics

    /// Plain validity: no non-final suffix, no non-initial prefix, single line.
    private func isPlainValid(_ window: [VocabToken]) -> Bool {
        for (offset, token) in window.enumerated() {
            if offset < window.count - 1, !token.suffix.isEmpty { return false }
            if offset > 0, !token.prefix.isEmpty { return false }
            if offset > 0, token.followsNewline { return false }
        }
        return true
    }

    /// Canonical-window validity: interior punctuation invalidates the window
    /// except where the entry's positionally corresponding token carries
    /// identical punctuation (canonical windows have equal token counts, so
    /// positional alignment is total). Windows never span a line break: real
    /// ASR output breaks lines mid-sentence, and firing across one would merge
    /// lines (newline = window boundary, like sentence punctuation).
    private func isValidWithException(_ window: [VocabToken], entry: TableEntry) -> Bool {
        for (offset, token) in window.enumerated() {
            let entryToken = entry.tokens[offset]
            if offset < window.count - 1, !token.suffix.isEmpty, token.suffix != entryToken.suffix {
                return false
            }
            if offset > 0, !token.prefix.isEmpty, token.prefix != entryToken.prefix {
                return false
            }
            if offset > 0, token.followsNewline { return false }
        }
        return true
    }

    private func windowRange(_ window: [VocabToken]) -> Range<String.Index> {
        window[0].coreRange.lowerBound ..< window[window.count - 1].coreRange.upperBound
    }

    private func windowSurface(_ window: [VocabToken], in text: String) -> String {
        String(text[windowRange(window)])
    }

    private func emit(
        _ entry: TableEntry,
        window: [VocabToken],
        text: String,
        stage: Correction.Stage,
        into corrections: inout [Correction]
    ) {
        let range = windowRange(window)
        corrections.append(Correction(
            range: range,
            original: String(text[range]),
            canonical: entry.canonical,
            stage: stage
        ))
    }

    /// Replacement re-attaches first-token prefix + last-token suffix implicitly:
    /// the correction range excludes them, so they survive untouched.
    private func apply(_ corrections: [Correction], to text: String) -> String {
        guard !corrections.isEmpty else { return text }
        var result = ""
        var cursor = text.startIndex
        for correction in corrections {
            result += text[cursor ..< correction.range.lowerBound]
            result += correction.canonical
            cursor = correction.range.upperBound
        }
        result += text[cursor...]
        return result
    }
}
