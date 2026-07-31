import Foundation

/// G2 §3: the deterministic, single-pass, idempotent name-substitution pass.
///
/// Runs over NOTES fields and speaker LABELS — never transcript prose (hard
/// floors 1, 5). Zero LLM judgment: every decision is a fold + a folded
/// Damerau-Levenshtein distance + the three rules below, first-match-wins per
/// word-run. The pass is pure: `apply` takes its whole world as value inputs
/// and returns the substituted fields plus a provenance report.
public enum NameSubstitution {
    // MARK: - Inputs

    /// One store row, reduced to what the pass needs (§2 already normalized it:
    /// cycle-free, one-hop, word-compose-free).
    public struct StoreRow: Sendable, Equatable {
        /// The folded misheard key (`VocabNormalization.canonicalMode`).
        public let mishearedFolded: String
        /// The replacement surface.
        public let replacement: String
        /// Everyday keys apply to OWNER fields and speaker labels only (§3 r1).
        public let everyday: Bool

        public init(mishearedFolded: String, replacement: String, everyday: Bool) {
            self.mishearedFolded = mishearedFolded
            self.replacement = replacement
            self.everyday = everyday
        }
    }

    /// The pass's world. `commonNames` is the folded `br_common_names` set (the
    /// rule-2 variant guard, NH-2). `polishCanonicals` are glossary canonicals
    /// eligible for rule-3 label polish (non-limited, non-lexicon).
    public struct Context: Sendable {
        public let store: [StoreRow]
        /// Candidate full names for rule 2: resolved speaker names ∪ attendees.
        public let ownerCandidates: [String]
        /// Folded br_common_names membership.
        public let commonNames: Set<String>
        /// Glossary canonicals eligible for rule-3 polish.
        public let polishCanonicals: [String]

        public init(
            store: [StoreRow],
            ownerCandidates: [String],
            commonNames: Set<String>,
            polishCanonicals: [String]
        ) {
            self.store = store
            self.ownerCandidates = ownerCandidates
            self.commonNames = commonNames
            self.polishCanonicals = polishCanonicals
        }
    }

    /// One provenance line: which field, what changed, by which rule.
    public struct ReportEntry: Codable, Sendable, Equatable {
        public let field: String
        public let original: String
        public let replacement: String
        public let rule: Int

        public init(field: String, original: String, replacement: String, rule: Int) {
            self.field = field
            self.original = original
            self.replacement = replacement
            self.rule = rule
        }
    }

    /// Which field a span belongs to, governing rule applicability:
    /// - `.owner` (owner fields + speaker labels): everyday store keys and
    ///   rule-2/rule-3 may fire here.
    /// - `.prose` (title, summary, detailed_notes, decisions, action-item texts):
    ///   only NON-everyday store keys fire (rules 2 and 3 are owner-only).
    public enum FieldKind: Sendable, Equatable {
        case owner
        case prose
    }

    /// The reason a position-scoped correction can or cannot change the
    /// selected occurrence. This is deliberately separate from the pipeline's
    /// replacement count: a guard-covered occurrence is present, but already
    /// agrees with the requested replacement.
    public enum OccurrenceClassification: Sendable, Equatable {
        case replaceable
        case alreadyCorrect
        case absent
    }

    // MARK: - Notes entry point

    /// Applies the pass to a `NotesStructured` value, returning the substituted
    /// notes and the report. `apply∘apply == apply` (idempotent): replacement
    /// text is never re-scanned within a pass, and the context fixed point
    /// (NC-2) makes a second pass a no-op.
    public static func apply(
        notes: NotesStructured,
        context: Context
    ) -> (notes: NotesStructured, report: [ReportEntry]) {
        var report: [ReportEntry] = []
        var out = notes

        func proseField(_ value: String, _ name: String) -> String {
            let r = applyToText(value, kind: .prose, context: context)
            for entry in r.entries {
                report.append(ReportEntry(
                    field: name, original: entry.original, replacement: entry.replacement,
                    rule: entry.rule))
            }
            return r.text
        }
        func ownerField(_ value: String, _ name: String) -> String {
            let r = applyToText(value, kind: .owner, context: context)
            for entry in r.entries {
                report.append(ReportEntry(
                    field: name, original: entry.original, replacement: entry.replacement,
                    rule: entry.rule))
            }
            return r.text
        }

        if let title = out.title {
            out.title = proseField(title, "title")
        }
        out.summary = proseField(out.summary, "summary")
        out.detailedNotes = proseField(out.detailedNotes, "detailed_notes")
        out.decisions = out.decisions.map { proseField($0, "decisions") }
        out.actionItems = out.actionItems.map { item in
            ActionItem(
                owner: ownerField(item.owner, "action_items.owner"),
                text: proseField(item.text, "action_items.text"))
        }
        out.userActionItems = out.userActionItems.map { item in
            ActionItem(
                owner: ownerField(item.owner, "user_action_items.owner"),
                text: proseField(item.text, "user_action_items.text"))
        }
        return (out, report)
    }

    // MARK: - Single-field pass

    struct FieldResult {
        var text: String
        var entries: [(original: String, replacement: String, rule: Int)]
    }

    /// Single pass over the ORIGINAL spans of one text field: collect candidate
    /// matches first, resolve overlaps (longest-run-first, then leftmost),
    /// apply together. Replacement text is never re-scanned.
    static func applyToText(_ text: String, kind: FieldKind, context: Context) -> FieldResult {
        guard !text.isEmpty else { return FieldResult(text: text, entries: []) }

        let words = wordRuns(in: text)
        guard !words.isEmpty else { return FieldResult(text: text, entries: []) }
        let quoted = quotedRanges(in: text)

        // Candidate matches over word-runs (single words and the multi-word
        // runs a rule could match are handled per rule via neighborhoods; the
        // run we replace is always a single word unless a rule says otherwise).
        struct Candidate {
            let range: Range<String.Index>
            let wordCount: Int
            let firstWordIndex: Int
            let original: String
            let replacement: String
            let rule: Int
        }
        var candidates: [Candidate] = []

        for (i, word) in words.enumerated() {
            // Hyphen guard: a word-run whose enclosing characters abut `-`
            // never matches (intra-word hyphen context, "semi-aberto").
            if abutsHyphen(text, word.range) { continue }
            // Quoted-span immunity: a word inside a balanced quoted span is
            // immune.
            if quoted.contains(where: { $0.contains(word.range.lowerBound) }) { continue }

            if let (replacement, rule) = matchRules(
                word: word.text, index: i, words: words, kind: kind, context: context)
            {
                candidates.append(Candidate(
                    range: word.range, wordCount: 1, firstWordIndex: i,
                    original: word.text, replacement: replacement, rule: rule))
            }
        }

        // Rule 2 — owner fuzzy fix — is FIELD-LEVEL (H-2): O is the WHOLE owner
        // field, and a fire replaces the ENTIRE field with the candidate's full
        // name (never splices a third name into a multi-word owner). It is a
        // fallback below the per-word rule-1/3 hits: if any word already matched
        // (a store/polish hit on this field), those take the span and rule 2 is
        // not considered for the field. The field must not be inside a quoted
        // span and must not abut a hyphen for the field-level fire.
        if kind == .owner, candidates.isEmpty,
            !quoted.contains(where: { $0.contains(text.startIndex) }),
            let full = ownerFuzzyFix(
                word: text, folded: VocabNormalization.canonicalMode(text), context: context)
        {
            let range = text.startIndex ..< text.endIndex
            candidates.append(Candidate(
                range: range, wordCount: words.count, firstWordIndex: 0,
                original: text, replacement: full, rule: 2))
        }

        guard !candidates.isEmpty else { return FieldResult(text: text, entries: []) }

        // Overlap resolution: longest-run-first, then leftmost. Single-word
        // candidates never overlap, but the ordering is defined regardless.
        candidates.sort { a, b in
            if a.wordCount != b.wordCount { return a.wordCount > b.wordCount }
            return a.range.lowerBound < b.range.lowerBound
        }
        var accepted: [Candidate] = []
        for candidate in candidates {
            if accepted.contains(where: { rangesOverlap($0.range, candidate.range) }) { continue }
            accepted.append(candidate)
        }
        // Apply right-to-left so earlier ranges stay valid.
        accepted.sort { $0.range.lowerBound > $1.range.lowerBound }
        var result = text
        var entries: [(original: String, replacement: String, rule: Int)] = []
        for candidate in accepted {
            result.replaceSubrange(candidate.range, with: candidate.replacement)
            entries.append((candidate.original, candidate.replacement, candidate.rule))
        }
        // Report in field reading order.
        entries.reverse()
        return FieldResult(text: result, entries: entries)
    }

    // MARK: - The three rules (first-match-wins per span)

    /// Returns the replacement + rule number for a single word-run, or nil.
    static func matchRules(
        word: String, index: Int, words: [WordRun], kind: FieldKind, context: Context
    ) -> (replacement: String, rule: Int)? {
        let folded = VocabNormalization.canonicalMode(word)

        // Rule 1 — store hit.
        for row in context.store where row.mishearedFolded == folded {
            // Everyday keys: OWNER fields and speaker labels ONLY.
            if row.everyday && kind != .owner { break }
            // Context fixed point (NC-2): skip when the run is already part of
            // the replacement in place. The replacement's WORDS are taken with
            // the SHARED segmentation (`foldedWords`) so the check sees exactly
            // the words the engine would re-match — a single-word replacement
            // whose only rendered word fold-equals the run ("(Sammy)" → ["sammy"]
            // matching run "Sammy") is a fixed point, closing the decorated /
            // self-containing replacement idempotence hole the §2 gate alone
            // cannot (apply∘apply == apply).
            let replWords = foldedWords(in: row.replacement)
            if replWords == [folded] { break }
            if neighborhoodContainsReplacement(
                replacementWords: replWords, index: index, words: words)
            {
                break
            }
            // NC-2 extended (v5.2, C-3): a store key never fires inside a person's
            // already-correct full name. When the run at `index` is a sub-run of a
            // neighborhood that fold-equals ANY attendee/resolved-speaker full
            // name, skip — this kills the rule-2→rule-1 surname-expansion
            // composition (rule 2 writes "Theo Marsh"; on the next pass a
            // `marsh → Dana Marsh` row must NOT then expand the "Marsh" inside
            // it to "Theo Dana Marsh"). Same harm in one pass on the
            // speaker-label path where a second bearer of a corrected surname
            // appears.
            if runIsInsideKnownEntity(
                index: index, words: words, candidateFolds: context.ownerCandidates.map {
                    VocabNormalization.canonicalMode($0)
                })
            {
                break
            }
            return (row.replacement, 1)
        }

        // Rule 2 — owner fuzzy fix — is applied FIELD-LEVEL in `applyToText`
        // (O = the whole owner field), not per word-run; see H-2.

        // Rule 3 — label polish (labels + owner fields).
        if kind == .owner, let r = labelPolish(word: word, folded: folded, context: context) {
            return (r, 3)
        }

        return nil
    }

    /// Rule 2 (§3): fire iff O fold-matches no attendee/speaker/canonical;
    /// exactly one candidate token T with d(O,T) ≤ (1 if len(T) ≤ 5 else 2),
    /// len ≥ 4; common-name variant guard (NH-2); replacement = candidate's
    /// full name; no-op when O already fold-equals it; ties no-op.
    static func ownerFuzzyFix(word: String, folded: String, context: Context) -> String? {
        guard folded.count >= 4 else { return nil }

        // O must fold-match no candidate (attendee/speaker/canonical) exactly —
        // an already-grounded owner is left alone.
        let candidateFolds = context.ownerCandidates.map { VocabNormalization.canonicalMode($0) }
        let polishFolds = context.polishCanonicals.map { VocabNormalization.canonicalMode($0) }
        if candidateFolds.contains(folded) || polishFolds.contains(folded) { return nil }
        // Also: O fold-matches no candidate TOKEN (the name appears verbatim).
        for fullFold in candidateFolds {
            for token in tokens(fullFold) where token == folded { return nil }
        }

        // Common-name variant guard (NH-2): if O is itself a br_common_names
        // member, never fire at d = 1 (Paulo/Paula class). We forbid the
        // whole d=1 firing for a common-name O.
        let oIsCommonName = context.commonNames.contains(folded)

        // Exactly one candidate within tolerance. The tie is over distinct
        // FULL-NAME folds (H-1): two different humans whose names share the
        // matched token ("Sammy Lee", "Sammy Reyes" both within d of "samy")
        // are AMBIGUOUS → no-op, deterministically — not last-candidate-wins.
        var matchedFull: String?
        var matchedFullFold: String?
        var ambiguous = false
        for (fullFold, fullSurface) in zip(candidateFolds, context.ownerCandidates) {
            for token in tokens(fullFold) {
                guard token.count >= 4 else { continue }
                let tolerance = token.count <= 5 ? 1 : 2
                let d = damerauLevenshtein(folded, token, cap: tolerance)
                guard d >= 1, d <= tolerance else { continue }
                if oIsCommonName && d == 1 { continue }
                if let existing = matchedFullFold, existing != fullFold {
                    ambiguous = true
                } else if matchedFullFold == nil {
                    matchedFullFold = fullFold
                    matchedFull = fullSurface
                }
            }
        }
        guard !ambiguous, let full = matchedFull else { return nil }
        // No-op when O already fold-equals the candidate's full name.
        if folded == VocabNormalization.canonicalMode(full) { return nil }
        return full
    }

    /// Rule 3 (§3): fold-equal to a NON-limited, non-lexicon glossary canonical
    /// differing only in surface → canonical surface. `word` is the original
    /// surface (to gate "differs only in surface").
    static func labelPolish(word: String, folded: String, context: Context) -> String? {
        for canonical in context.polishCanonicals {
            guard VocabNormalization.canonicalMode(canonical) == folded else { continue }
            // Fire only when the surface genuinely differs (idempotence).
            if canonical != word { return canonical }
        }
        return nil
    }

    // MARK: - Neighborhood / context fixed point (NC-2)

    /// True when the run at `index` is a sub-run of a neighborhood that
    /// fold-contains the full replacement — check the surrounding words up to
    /// the replacement's word count on each side. `replWords` are the
    /// replacement's folded words via the SHARED `foldedWords` segmentation.
    static func neighborhoodContainsReplacement(
        replacementWords replWords: [String], index: Int, words: [WordRun]
    ) -> Bool {
        guard replWords.count >= 1 else { return false }
        let n = replWords.count
        let lower = max(0, index - (n - 1))
        let upper = min(words.count - 1, index + (n - 1))
        guard upper >= lower else { return false }
        let windowFolds = (lower ... upper).map { VocabNormalization.canonicalMode(words[$0].text) }
        // Slide a window of length n; if any contiguous slice fold-equals the
        // replacement words AND covers `index`, the run is already in place.
        guard windowFolds.count >= n else { return false }
        for start in 0 ... (windowFolds.count - n) {
            let slice = Array(windowFolds[start ..< start + n])
            if slice == replWords {
                let absoluteStart = lower + start
                let absoluteEnd = absoluteStart + n - 1
                if index >= absoluteStart && index <= absoluteEnd { return true }
            }
        }
        return false
    }

    /// NC-2 extended (v5.2, C-3): true when the run at `index` is a sub-run of a
    /// neighborhood that fold-EQUALS one of `candidateFolds` (an attendee /
    /// resolved-speaker full name). A multi-word candidate full name is matched
    /// as a contiguous run of words covering `index`; a single-word candidate is
    /// NOT used here (a bare first-name field that equals a candidate is handled
    /// by rule 2's grounding, not by suppressing a legitimate store hit). This is
    /// what stops a store key from firing inside a person's already-correct full
    /// name ("Marsh" inside attendee "Theo Marsh").
    static func runIsInsideKnownEntity(
        index: Int, words: [WordRun], candidateFolds: [String]
    ) -> Bool {
        let wordFolds = words.map { VocabNormalization.canonicalMode($0.text) }
        for fullFold in candidateFolds {
            let entityWords = tokens(fullFold)
            guard entityWords.count >= 2 else { continue }
            let n = entityWords.count
            // Windows of length n that cover `index`.
            let lower = max(0, index - (n - 1))
            let upper = min(words.count - n, index)
            guard upper >= lower else { continue }
            for start in lower ... upper {
                let slice = Array(wordFolds[start ..< start + n])
                if slice == entityWords { return true }
            }
        }
        return false
    }

    // MARK: - Word runs / segmentation (.byWords)

    struct WordRun {
        let text: String
        let range: Range<String.Index>
    }

    /// `enumerateSubstrings(.byWords)` segmentation, preserving source ranges.
    static func wordRuns(in text: String) -> [WordRun] {
        var runs: [WordRun] = []
        text.enumerateSubstrings(
            in: text.startIndex ..< text.endIndex, options: .byWords
        ) { substring, range, _, _ in
            if let substring, !substring.isEmpty {
                runs.append(WordRun(text: substring, range: range))
            }
        }
        return runs
    }

    /// True when either character immediately enclosing the run is a hyphen or
    /// dash (intra-word hyphen context). Covers ASCII `-`, the non-breaking
    /// hyphen, and the en/em dashes used as compound joiners (L-1: "semi–aberto"
    /// with U+2013 must be guarded the same as "semi-aberto").
    static func abutsHyphen(_ text: String, _ range: Range<String.Index>) -> Bool {
        func isDash(_ c: Character) -> Bool {
            c == "-" || c == "\u{2010}" || c == "\u{2011}" || c == "\u{2013}" || c == "\u{2014}"
        }
        if range.lowerBound > text.startIndex, isDash(text[text.index(before: range.lowerBound)]) {
            return true
        }
        if range.upperBound < text.endIndex, isDash(text[range.upperBound]) {
            return true
        }
        return false
    }

    // MARK: - Quoted-span immunity

    /// Balanced same-type pairs of straight `"`, curly “ ”, « », and curly ‘ ’.
    /// STRAIGHT apostrophes are NEVER delimiters (H-9). Unbalanced = no immunity.
    static func quotedRanges(in text: String) -> [Range<String.Index>] {
        let asymmetric: [(open: Character, close: Character)] = [
            ("\u{201C}", "\u{201D}"), // “ ”
            ("\u{00AB}", "\u{00BB}"), // « »
            ("\u{2018}", "\u{2019}"), // ‘ ’
        ]
        var ranges: [Range<String.Index>] = []

        // Straight double-quote: symmetric, paired sequentially (no word-internal
        // form exists for `"`).
        do {
            var openIndex: String.Index?
            var i = text.startIndex
            while i < text.endIndex {
                if text[i] == "\"" {
                    if let open = openIndex {
                        ranges.append(text.index(after: open) ..< i)
                        openIndex = nil
                    } else {
                        openIndex = i
                    }
                }
                i = text.index(after: i)
            }
            // An unbalanced trailing open → no immunity (dropped).
        }

        // Straight single-quote / apostrophe (H-9, spec v5.2): a straight `'` is
        // NEVER a quote delimiter. Possessives ("the user's", "Carlos'"), contractions
        // ("don't"), and elisions ("'em", "'90s") make open/close pairing
        // undecidable — a closing s-possessive ("Carlos'") looks identical to an
        // opener, and a leading elision ("'em") to a closer. LLM-generated notes
        // use CURLY single quotes (‘ ’) or double quotes for real quotation, which
        // ARE paired below. So straight apostrophes are simply ignored here: they
        // never consume a quote, never flip pairing parity, and never grant or
        // revoke immunity to a span.

        for pair in asymmetric {
            var openIndex: String.Index?
            var i = text.startIndex
            while i < text.endIndex {
                let c = text[i]
                if c == pair.open && openIndex == nil {
                    openIndex = i
                } else if c == pair.close, let open = openIndex {
                    ranges.append(text.index(after: open) ..< i)
                    openIndex = nil
                }
                i = text.index(after: i)
            }
        }
        return ranges
    }

    // MARK: - Helpers

    static func tokens(_ folded: String) -> [String] {
        folded.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { !$0.isEmpty }
    }

    /// THE shared word-segmentation-and-fold of a surface (C-1): the folded
    /// `.byWords` runs of `text`, exactly as the substitution engine matches
    /// them. The §2 write gate folds replacement words through THIS function so
    /// the store and the engine agree on what a "word" is by construction — a
    /// markdown/parenthesis-decorated replacement word like `(Sammy)` or
    /// `**Sammy**` folds to the same `sammy` the engine's run inside it folds
    /// to, closing the gate-vs-engine word-identity gap.
    public static func foldedWords(in text: String) -> [String] {
        wordRuns(in: text).map { VocabNormalization.canonicalMode($0.text) }.filter { !$0.isEmpty }
    }

    // MARK: - Correction windows

    /// One identity-bearing occurrence from the §3.1 scan. The run indexes
    /// remain attached so the §3.2 guard can inspect the PRE-EDIT run array;
    /// the source range is the span consumed by the replacement.
    private struct CorrectionWindow {
        let firstRunIndex: Int
        let lastRunIndex: Int
        let range: Range<String.Index>
    }

    /// The only line-break graphemes accepted inside a multi-word correction
    /// window. `Character.isNewline` intentionally admits more than the
    /// structural grammar permits, so this is an allowlist rather than a
    /// blocklist.
    private static func isAllowedCorrectionLineBreak(_ character: Character) -> Bool {
        let scalars = Array(character.unicodeScalars)
        if scalars.count == 1 {
            return scalars[0].value == 0x0A || scalars[0].value == 0x0D
        }
        return scalars.count == 2
            && scalars[0].value == 0x0D
            && scalars[1].value == 0x0A
    }

    /// §3.1 separator grammar: whitespace-only gaps, with at most one
    /// allowlisted line-break grapheme. Empty gaps are accepted vacuously;
    /// `.byWords` normally prevents adjacent word runs from reaching this
    /// case.
    private static func correctionGapsAreValid(
        in text: String, runs: [WordRun], first: Int, last: Int
    ) -> Bool {
        guard first < last else { return true }
        for index in first ..< last {
            let gap = text[runs[index].range.upperBound ..< runs[index + 1].range.lowerBound]
            var lineBreakCount = 0
            for character in gap {
                guard character.isWhitespace else { return false }
                let hasExplicitDisallowedNewlineScalar = character.unicodeScalars.contains {
                    [0x000B, 0x000C, 0x0085, 0x2028, 0x2029].contains($0.value)
                }
                if character.isNewline || hasExplicitDisallowedNewlineScalar {
                    guard isAllowedCorrectionLineBreak(character) else { return false }
                    lineBreakCount += 1
                    guard lineBreakCount <= 1 else { return false }
                }
            }
        }
        return true
    }

    private static func correctionWindowFoldsEqual(
        _ runs: [WordRun], first: Int, last: Int, expected: [String]
    ) -> Bool {
        guard last - first + 1 == expected.count else { return false }
        for offset in 0 ..< expected.count {
            let fold = VocabNormalization.canonicalMode(runs[first + offset].text)
            guard fold == expected[offset] else { return false }
        }
        return true
    }

    /// §3.1 PHASE 1 — enumerate identity-bearing, non-overlapping windows
    /// without consulting the replacement or its containment guard.
    private static func enumerateCorrectionWindows(
        in text: String, original: String
    ) -> [CorrectionWindow] {
        let targetFolds = foldedWords(in: original)
        guard !targetFolds.isEmpty else { return [] }
        let runs = wordRuns(in: text)
        let wordCount = targetFolds.count
        guard runs.count >= wordCount else { return [] }

        var windows: [CorrectionWindow] = []
        var first = 0
        while first + wordCount <= runs.count {
            let last = first + wordCount - 1
            if correctionWindowFoldsEqual(
                runs, first: first, last: last, expected: targetFolds),
                correctionGapsAreValid(in: text, runs: runs, first: first, last: last)
            {
                windows.append(CorrectionWindow(
                    firstRunIndex: first, lastRunIndex: last,
                    range: runs[first].range.lowerBound ..< runs[last].range.upperBound))
                // The accepted occurrence consumes the complete candidate
                // window. This is the locked overlap/adjacency identity rule.
                first += wordCount
            } else {
                first += 1
            }
        }
        return windows
    }

    /// §3.2: every valid replacement-window START index, computed ONCE per
    /// (text, replacement) pass — a single O(runs × m) scan. Per-candidate
    /// coverage then costs a binary search, keeping the whole guard inside the
    /// spec's attested O(runs × max(n, m)) instead of O(runs × m²) when a
    /// pathological long replacement is pasted (impl-audit I-H3).
    private static func validReplacementWindowStarts(
        in text: String, runs: [WordRun], replacementFolds: [String]
    ) -> [Int] {
        let m = replacementFolds.count
        guard m > 0, runs.count >= m else { return [] }
        var starts: [Int] = []
        for first in 0 ... (runs.count - m) {
            if correctionWindowFoldsEqual(
                runs, first: first, last: first + m - 1, expected: replacementFolds),
                correctionGapsAreValid(in: text, runs: runs, first: first, last: first + m - 1)
            {
                starts.append(first)
            }
        }
        return starts
    }

    /// §3.2 containment guard evaluated against the PRE-EDIT run array: the
    /// candidate [i...j] is covered iff some valid replacement window of
    /// length m starts at a ∈ [j-m+1, i] (length m ⇒ that start covers the
    /// whole candidate interval). `starts` is ascending by construction.
    private static func correctionWindowIsCovered(
        _ candidate: CorrectionWindow, replacementWindowStarts starts: [Int],
        replacementCount: Int
    ) -> Bool {
        guard replacementCount > 0, !starts.isEmpty else { return false }
        let minStart = candidate.lastRunIndex - replacementCount + 1
        let maxStart = candidate.firstRunIndex
        guard minStart <= maxStart else { return false }
        var lo = 0
        var hi = starts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if starts[mid] < minStart { lo = mid + 1 } else { hi = mid }
        }
        return lo < starts.count && starts[lo] <= maxStart
    }

    private static func applyingCorrectionWindows(
        _ windows: [CorrectionWindow], in text: String, replacement: String
    ) -> (text: String, count: Int) {
        guard !windows.isEmpty else { return (text, 0) }
        var result = text
        for window in windows.reversed() {
            result.replaceSubrange(window.range, with: replacement)
        }
        return (result, windows.count)
    }

    /// Replacement-independent occurrence identity for one flat text field.
    public static func selectableOccurrenceCount(in text: String, original: String) -> Int {
        enumerateCorrectionWindows(in: text, original: original).count
    }

    /// Replacement-aware count of actual changes for one flat text field.
    public static func replaceableOccurrenceCount(
        in text: String, original: String, replacement: String
    ) -> Int {
        let windows = enumerateCorrectionWindows(in: text, original: original)
        guard !windows.isEmpty else { return 0 }
        let runs = wordRuns(in: text)
        let replacementFolds = foldedWords(in: replacement)
        let starts = validReplacementWindowStarts(
            in: text, runs: runs, replacementFolds: replacementFolds)
        return windows.filter {
            !correctionWindowIsCovered(
                $0, replacementWindowStarts: starts,
                replacementCount: replacementFolds.count)
        }.count
    }

    private static func noteCorrectionFieldValues(_ notes: NotesStructured) -> [String] {
        // MUST mirror applyNoteCorrection's traversal exactly — same fields,
        // same order (per action item: owner then text) — or the UI counts,
        // the picker's global occurrence index, and the apply pass diverge.
        var values: [String] = []
        if let title = notes.title { values.append(title) }
        values.append(notes.summary)
        values.append(notes.detailedNotes)
        values.append(contentsOf: notes.decisions)
        for item in notes.actionItems {
            values.append(item.owner)
            values.append(item.text)
        }
        for item in notes.userActionItems {
            values.append(item.owner)
            values.append(item.text)
        }
        return values
    }

    /// §3.3 replacement-independent occurrence count across notes fields in
    /// the existing reading order: title, summary, detailed notes, decisions,
    /// then each action item (owner, text), then each user action item
    /// (owner, text) — applyNoteCorrection's own traversal, mirrored.
    public static func selectableOccurrenceCount(
        in notes: NotesStructured, original: String
    ) -> Int {
        noteCorrectionFieldValues(notes).reduce(into: 0) { count, value in
            count += selectableOccurrenceCount(in: value, original: original)
        }
    }

    /// §3.3 guarded count of occurrences that an all-occurrences confirm will
    /// actually replace.
    public static func replaceableOccurrenceCount(
        in notes: NotesStructured, original: String, replacement: String
    ) -> Int {
        noteCorrectionFieldValues(notes).reduce(into: 0) { count, value in
            count += replaceableOccurrenceCount(
                in: value, original: original, replacement: replacement)
        }
    }

    /// §3.3 status preflight for the global notes occurrence index.
    public static func classifyNoteOccurrence(
        in notes: NotesStructured, original: String, replacement: String,
        occurrenceIndex: Int?
    ) -> OccurrenceClassification {
        let target = occurrenceIndex ?? 0
        guard target >= 0 else { return .absent }
        var seen = 0
        let replacementFolds = foldedWords(in: replacement)
        for value in noteCorrectionFieldValues(notes) {
            let windows = enumerateCorrectionWindows(in: value, original: original)
            if target < seen + windows.count {
                let window = windows[target - seen]
                let runs = wordRuns(in: value)
                let starts = validReplacementWindowStarts(
                    in: value, runs: runs, replacementFolds: replacementFolds)
                return correctionWindowIsCovered(
                    window, replacementWindowStarts: starts,
                    replacementCount: replacementFolds.count)
                    ? .alreadyCorrect
                    : .replaceable
            }
            seen += windows.count
        }
        return .absent
    }

    /// §5/§3 position-scoped notes correction (NH-C). Replaces the shared
    /// §3.1 windows in the structured notes.
    ///
    /// - `allOccurrences == true`: replace every identity window that is not
    ///   covered by the §3.2 containment guard across all fields (the guarded
    ///   count shown in the UI).
    /// - `allOccurrences == false`: POSITION-SCOPED — replace the single window
    ///   the user pointed at, identified by `occurrenceIndex` (its zero-based
    ///   index among all §3.1 windows in field reading order). A
    ///   guard-covered selection is an honest no-op. A nil `occurrenceIndex`
    ///   defaults to occurrence 0 (a provenance-line correction with no
    ///   specific selection fixes the first occurrence).
    ///
    /// Returns the edited notes and the number of windows replaced (0 or 1 in
    /// the position-scoped case; N when `allOccurrences`).
    public static func applyNoteCorrection(
        notes: NotesStructured, original: String, replacement: String,
        allOccurrences: Bool, occurrenceIndex: Int? = nil
    ) -> (notes: NotesStructured, count: Int) {
        var out = notes
        var replaced = 0
        let replacementFolds = foldedWords(in: replacement)
        // The position-scoped target occurrence (reading order across fields).
        let target = allOccurrences ? -1 : (occurrenceIndex ?? 0)
        // Running count of §3.1 identity occurrences seen so far across all
        // fields, so the occurrence index is GLOBAL.
        var seen = 0

        func fix(_ value: String) -> String {
            let windows = enumerateCorrectionWindows(in: value, original: original)
            let runs = wordRuns(in: value)
            let fieldStart = seen
            seen += windows.count

            let chosen: [CorrectionWindow]
            if windows.isEmpty {
                chosen = []
            } else {
                let starts = validReplacementWindowStarts(
                    in: value, runs: runs, replacementFolds: replacementFolds)
                if allOccurrences {
                    chosen = windows.filter {
                        !correctionWindowIsCovered(
                            $0, replacementWindowStarts: starts,
                            replacementCount: replacementFolds.count)
                    }
                } else if target >= fieldStart, target < fieldStart + windows.count {
                    let window = windows[target - fieldStart]
                    chosen = correctionWindowIsCovered(
                        window, replacementWindowStarts: starts,
                        replacementCount: replacementFolds.count)
                        ? [] : [window]
                } else {
                    chosen = []
                }
            }
            let result = applyingCorrectionWindows(chosen, in: value, replacement: replacement)
            replaced += result.count
            return result.text
        }

        if let title = out.title { out.title = fix(title) }
        out.summary = fix(out.summary)
        out.detailedNotes = fix(out.detailedNotes)
        out.decisions = out.decisions.map(fix)
        out.actionItems = out.actionItems.map {
            ActionItem(owner: fix($0.owner), text: fix($0.text))
        }
        out.userActionItems = out.userActionItems.map {
            ActionItem(owner: fix($0.owner), text: fix($0.text))
        }
        return (out, replaced)
    }

    /// G14 (M3): deterministic, guarded name rewrite over a FLAT Markdown
    /// string. The same §3.1 occurrence identity and §3.2 containment guard are
    /// used by the notes path, so digest and notes cannot diverge on a bare→full
    /// correction. NO LLM call.
    public static func applyTextCorrection(
        text: String, original: String, replacement: String
    ) -> (text: String, count: Int) {
        let windows = enumerateCorrectionWindows(in: text, original: original)
        guard !windows.isEmpty else { return (text, 0) }
        let runs = wordRuns(in: text)
        let replacementFolds = foldedWords(in: replacement)
        let starts = validReplacementWindowStarts(
            in: text, runs: runs, replacementFolds: replacementFolds)
        let chosen = windows.filter {
            !correctionWindowIsCovered(
                $0, replacementWindowStarts: starts,
                replacementCount: replacementFolds.count)
        }
        return applyingCorrectionWindows(chosen, in: text, replacement: replacement)
    }

    /// §3/§1: apply the substitution pass to a SPEAKER LABEL surface (label
    /// scope = owner kind: everyday store keys, rule-2 fuzzy, and rule-3 polish
    /// all eligible). A misheard mechanical/LLM `speaker_name` ("SEMI") is
    /// outranked by a `semi → Sammy` store row right here, so the correction
    /// reaches the transcript labels and the evidence payload — not just notes.
    /// Returns the substituted label (unchanged when nothing matched).
    public static func applyToLabel(_ label: String, context: Context) -> String {
        applyToText(label, kind: .owner, context: context).text
    }

    /// G13 layer 1 — diarization-label → name substitution over `notes.structured`.
    /// EXACT and case-sensitive (`S0`→`Dana`), not fuzzy: a resolved speaker
    /// mapping ∪ active `speaker_rename` rows produce `labelMap`, and every
    /// emphasis-aware label occurrence (`SLabelNeutralizer.labelRanges`) in every
    /// notes field — including owners — whose token is a key in `labelMap` is
    /// replaced by the mapped name. A label with no entry is left for layer 2.
    /// Sibling to `apply`/`applyNoteCorrection`; operates field-by-field,
    /// right-to-left within a field so earlier ranges stay valid.
    ///
    /// `groundedMLabels` is the detector's M-namespace grounding: an M label is
    /// only a label when the meeting's persisted segments carry that cluster, so
    /// this layer must be given the same set the caller filtered `labelMap` with
    /// — otherwise a named live M label is invisible here AND excluded from
    /// layer 2, and reaches the reader raw.
    public static func applyLabelSubstitution(
        notes: NotesStructured, labelMap: [String: String],
        groundedMLabels: Set<String> = []
    ) -> NotesStructured {
        guard !labelMap.isEmpty else { return notes }
        var out = notes

        func substitute(_ value: String) -> String {
            let ranges = SLabelNeutralizer.labelRanges(
                in: value, groundedMLabels: groundedMLabels)
            guard !ranges.isEmpty else { return value }
            var result = value
            for range in ranges.reversed() {
                let token = String(value[range])
                guard let name = labelMap[token] else { continue }
                result.replaceSubrange(range, with: name)
            }
            return result
        }

        if let title = out.title { out.title = substitute(title) }
        out.summary = substitute(out.summary)
        out.detailedNotes = substitute(out.detailedNotes)
        out.decisions = out.decisions.map(substitute)
        out.actionItems = out.actionItems.map {
            ActionItem(owner: substitute($0.owner), text: substitute($0.text))
        }
        out.userActionItems = out.userActionItems.map {
            ActionItem(owner: substitute($0.owner), text: substitute($0.text))
        }
        return out
    }

    /// §4 rename-input normalization: ONE surface, no parentheticals. For the
    /// documented "Misheard (Canonical)" artifact (`X (Y)`), keeps the
    /// parenthetical canonical `Y`; otherwise strips any parenthetical group.
    /// Collapses whitespace — the rename row stores a single clean name.
    public static func normalizeRenameInput(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // `X (Y)` → Y (the canonical the v1.1 prompt bans inline).
        if let open = trimmed.firstIndex(of: "("),
            let close = trimmed.lastIndex(of: ")"),
            open < close
        {
            let inner = trimmed[trimmed.index(after: open) ..< close]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !inner.isEmpty {
                return inner.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            }
        }
        return trimmed.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Applies store rule 1 and rule-3 polish to a rename input surface (the
    /// §4 "store rule-1/3 normalization applies to rename input too"): a store
    /// hit on the folded surface replaces it; otherwise a fold-equal polish
    /// canonical normalizes the surface. Then `normalizeRenameInput`.
    public static func normalizeRename(_ raw: String, context: Context) -> String {
        let cleaned = normalizeRenameInput(raw)
        let folded = VocabNormalization.canonicalMode(cleaned)
        for row in context.store where row.mishearedFolded == folded {
            return normalizeRenameInput(row.replacement)
        }
        if let polished = labelPolish(word: cleaned, folded: folded, context: context) {
            return normalizeRenameInput(polished)
        }
        return cleaned
    }

    static func rangesOverlap(_ a: Range<String.Index>, _ b: Range<String.Index>) -> Bool {
        a.lowerBound < b.upperBound && b.lowerBound < a.upperBound
    }

    // MARK: - Folded Damerau-Levenshtein

    /// Optimal-string-alignment Damerau-Levenshtein (adjacent transpositions),
    /// over the already-folded inputs, capped (returns cap+1 once exceeded).
    static func damerauLevenshtein(_ a: String, _ b: String, cap: Int) -> Int {
        let s = Array(a)
        let t = Array(b)
        let n = s.count
        let m = t.count
        if abs(n - m) > cap { return cap + 1 }
        if n == 0 { return m <= cap ? m : cap + 1 }
        if m == 0 { return n <= cap ? n : cap + 1 }

        var prev2 = [Int](repeating: 0, count: m + 1) // row i-2
        var prev = [Int](repeating: 0, count: m + 1)  // row i-1
        var curr = [Int](repeating: 0, count: m + 1)
        for j in 0 ... m { prev[j] = j }

        for i in 1 ... n {
            curr[0] = i
            var rowMin = i
            for j in 1 ... m {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                var value = min(
                    prev[j] + 1,        // deletion
                    curr[j - 1] + 1,    // insertion
                    prev[j - 1] + cost) // substitution
                if i > 1, j > 1, s[i - 1] == t[j - 2], s[i - 2] == t[j - 1] {
                    value = min(value, prev2[j - 2] + 1) // transposition
                }
                curr[j] = value
                rowMin = min(rowMin, value)
            }
            if rowMin > cap { return cap + 1 }
            prev2 = prev
            prev = curr
            curr = [Int](repeating: 0, count: m + 1)
        }
        return prev[m] <= cap ? prev[m] : cap + 1
    }
}
