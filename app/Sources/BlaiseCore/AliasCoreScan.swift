import Foundation

/// The alias-core scan, relocated from VocabTool into BlaiseCore beside
/// `AliasAdmission` (G1 §5a.2). Identical code, identical lexicons (all
/// BlaiseCore-reachable: `FrequencyList`, `VocabTokenizer`, `VocabNormalization`).
///
/// Why it exists (recorded decision, carried verbatim from the derivation tool):
/// single-token alias surfaces are covered by the alias-admission rule, and
/// multi-token CANONICALS by runtime suppression — but alias hits have no
/// runtime suppression branch and always fire, so a multi-token alias is only
/// safe if at least one core is distinctive (not a plausible ordinary word).
/// Cut at rank ≤ 40,000 of either full ~50k list: deeper entries are corpus
/// noise, not words a speaker plausibly says. An alias whose cores are ALL
/// lexicon-common ("silver fox", "open door") would rewrite ordinary speech
/// and is rejected.
public enum AliasCoreScan {
    /// Rank cut: a core at rank ≤ this in either full list is "lexicon-common".
    public static let commonRankCut = 40_000

    /// A folded core is lexicon-common iff it sits at rank ≤ `commonRankCut` in
    /// either the PT or EN full list.
    public static func isLexiconCommon(_ foldedCore: String, pt: FrequencyList, en: FrequencyList) -> Bool {
        if let rank = pt.rank[foldedCore], rank <= commonRankCut { return true }
        if let rank = en.rank[foldedCore], rank <= commonRankCut { return true }
        return false
    }

    /// True when `alias` is a multi-token surface whose cores are ALL
    /// lexicon-common — it must never ship (it would rewrite ordinary speech).
    /// Single-token aliases are out of scope here (the alias-admission rule and
    /// the Level-A machinery cover them).
    public static func hasNoDistinctiveCore(_ alias: String, pt: FrequencyList, en: FrequencyList) -> Bool {
        let cores = VocabTokenizer.tokenize(alias).map { VocabNormalization.canonicalMode($0.core) }
        guard cores.count > 1 else { return false }
        return cores.allSatisfy { isLexiconCommon($0, pt: pt, en: en) }
    }

    /// The tokenizer-peeled core set of a surface: each whitespace-delimited
    /// token's core (edge punctuation peeled), folded. Empty cores (a token that
    /// is ALL edge punctuation) are dropped — they carry no matchable text.
    /// This is exactly what `VocabularyCorrector` keys on (G1 §5a gates 0a/0b).
    public static func peeledCores(_ surface: String) -> [String] {
        VocabTokenizer.tokenize(surface)
            .map { VocabNormalization.canonicalMode($0.core) }
            .filter { !$0.isEmpty }
    }

    /// Gate 0a (G1 §5a) — punctuation safety, the TOTAL no-punctuation rule.
    ///
    /// This is the load-time relocation, verbatim, of C5's curation assertion
    /// (`VocabTool.swift`, the "alias carries punctuation other than apostrophes"
    /// fail) — generalized to its full intent: an alias must be plain matchable
    /// text. After the canonical fold, a surface is REJECTED if it contains ANY
    /// character that is not a letter, a digit, or a single internal space.
    ///
    /// No edge-vs-interior distinction, no peel-reconstruction cleverness:
    /// trailing periods, markdown bold, parentheses, commas, apostrophes (straight
    /// AND curly), quotes, em-dashes, interpuncts, fullwidth forms, zero-width
    /// characters, interior hyphens (`segunda-feira`) — everything
    /// non-alphanumeric-non-space rejects. The corrector keys on tokenizer-PEELED
    /// cores, so any of these would otherwise let a bare everyday word slip a
    /// lexicon gate that inspected a different string. Consequence (owned, like
    /// C5's): legitimately hyphenated names lose alias rights and must be written
    /// unhyphenated.
    public static func carriesDisallowedPunctuation(_ surface: String) -> Bool {
        // Fold first (curly apostrophes straighten, diacritics fold) so the rule
        // sees exactly the characters the corrector's key space would.
        let folded = VocabNormalization.canonicalMode(surface)
        // Letterless aliases (`360`, `2026`, `100`) are invisible to every
        // lexicon gate — numbers are not lexicon members — yet rewrite every
        // numeral occurrence in a transcript (impl-audit round-4 M-1). An
        // alias must contain at least one letter to be a plausible mishearing
        // of a name.
        if !folded.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) {
            return true
        }
        var sawSpace = false
        for scalar in folded.unicodeScalars {
            // A single internal space is the only permitted separator. The folded
            // surface is already trimmed of leading/trailing whitespace by the
            // parser's field trim, so any run of spaces (double space) or a space
            // among otherwise-empty content is a disallowed shape.
            if scalar == " " {
                if sawSpace { return true } // double space — not single internal
                sawSpace = true
                continue
            }
            sawSpace = false
            if CharacterSet.letters.contains(scalar) { continue }
            if CharacterSet.decimalDigits.contains(scalar) { continue }
            return true // anything else (punctuation, symbol, zero-width, …)
        }
        return false
    }

    /// Gate 0b (G1 §5a) — empty-core safety. A surface whose peeled core set is
    /// EMPTY (every token is pure edge punctuation, e.g. `---`, `...`) carries no
    /// matchable text; the corrector would otherwise register it under the empty
    /// window key and fire on standalone punctuation tokens in the transcript.
    public static func hasEmptyPeeledCores(_ surface: String) -> Bool {
        peeledCores(surface).isEmpty
    }

    /// True when ANY whitespace-delimited token of `surface` peels to an empty
    /// core (the token is pure edge punctuation, e.g. the `-` in `Marsa -`). Such
    /// a token registers under the empty key fragment and matches a standalone
    /// punctuation transcript token, so a canonical carrying one must not register
    /// for correction (G1 §5a — the canonical correction-limitation gate). This
    /// is stricter than `hasEmptyPeeledCores`, which requires ALL cores empty.
    public static func hasAnyEmptyPeeledCore(_ surface: String) -> Bool {
        VocabTokenizer.tokenize(surface).contains { VocabNormalization.canonicalMode($0.core).isEmpty }
    }
}
