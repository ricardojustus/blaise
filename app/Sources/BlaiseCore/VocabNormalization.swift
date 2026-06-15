import Foundation

/// Text normalization modes for the C5 vocabulary correction layer.
///
/// - Canonical mode: lowercase + diacritic fold + curly-apostrophe straightening.
///   Used for canonical-entry keys and suppression/stoplist membership.
/// - Alias mode: lowercase + curly-apostrophe straightening, diacritic-EXACT.
///   Used for alias keys (protects the accent-drop direction: "vexá" never
///   matches the alias "vexa").
public enum VocabNormalization {
    /// Lowercase + NFD diacritic fold + `’` → `'`.
    public static func canonicalMode(_ s: String) -> String {
        straightenApostrophes(s)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Lowercase + `’` → `'` only (diacritic-exact).
    public static func aliasMode(_ s: String) -> String {
        straightenApostrophes(s)
            .folding(options: [.caseInsensitive], locale: nil)
    }

    private static func straightenApostrophes(_ s: String) -> String {
        s.contains("\u{2019}") ? s.replacingOccurrences(of: "\u{2019}", with: "'") : s
    }
}

/// One whitespace-delimited token decomposed as (prefix, core, suffix):
/// edge punctuation is peeled into prefix/suffix; apostrophes and interior
/// periods stay in the core. Ranges index the source string.
///
/// Known, deliberate false negative: because apostrophes stay in the core
/// (so `O'Brien` matches), quoted and possessive surfaces ('Vexa', ‘Vexa’,
/// "vexa's") never match an entry — a miss, never a corruption.
public struct VocabToken: Sendable {
    public let prefix: String
    public let core: String
    public let suffix: String
    /// Range of the core within the source string.
    public let coreRange: Range<String.Index>
    /// True when a line break separates this token from the previous one.
    /// Multi-token windows never span a line break (newline = window boundary).
    public let followsNewline: Bool

    public init(prefix: String, core: String, suffix: String, coreRange: Range<String.Index>, followsNewline: Bool = false) {
        self.prefix = prefix
        self.core = core
        self.suffix = suffix
        self.coreRange = coreRange
        self.followsNewline = followsNewline
    }
}

public enum VocabTokenizer {
    private static let edgePunctuation: CharacterSet = {
        var set = CharacterSet.punctuationCharacters.union(.symbols)
        set.remove(charactersIn: "'\u{2019}")
        return set
    }()

    private static func isEdgePunctuation(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { edgePunctuation.contains($0) }
    }

    /// Whitespace-split tokenization; symmetric for input text and entry surfaces.
    public static func tokenize(_ text: String) -> [VocabToken] {
        var tokens: [VocabToken] = []
        var index = text.startIndex
        while index < text.endIndex {
            // Skip whitespace, noting any line break in the gap.
            var sawNewline = false
            while index < text.endIndex, text[index].isWhitespace {
                if text[index].isNewline { sawNewline = true }
                index = text.index(after: index)
            }
            guard index < text.endIndex else { break }
            let start = index
            while index < text.endIndex, !text[index].isWhitespace {
                index = text.index(after: index)
            }
            tokens.append(decompose(text, start ..< index, followsNewline: sawNewline))
        }
        return tokens
    }

    private static func decompose(_ text: String, _ range: Range<String.Index>, followsNewline: Bool) -> VocabToken {
        var coreStart = range.lowerBound
        var coreEnd = range.upperBound
        while coreStart < coreEnd, isEdgePunctuation(text[coreStart]) {
            coreStart = text.index(after: coreStart)
        }
        while coreEnd > coreStart, isEdgePunctuation(text[text.index(before: coreEnd)]) {
            coreEnd = text.index(before: coreEnd)
        }
        return VocabToken(
            prefix: String(text[range.lowerBound ..< coreStart]),
            core: String(text[coreStart ..< coreEnd]),
            suffix: String(text[coreEnd ..< range.upperBound]),
            coreRange: coreStart ..< coreEnd,
            followsNewline: followsNewline
        )
    }
}
