import Foundation

/// T3.1 (md-v3): the deterministic derivation of the digest's structured inputs
/// — the scoped alias bindings and the host binding — from the CORRECTED
/// transcript, the vocabulary dictionary, and the applied corrections. Pure and
/// app-owned (the model never hand-authors these). Shared by the first-run and
/// digest-resume call sites in `ProcessingPipeline` so both scope identically.
public enum DigestStructuredInputs {
    /// Derive `scopedAliasBindings` from the dictionary entries (alias→canonical),
    /// excluding self-pairs, admitting a pair ONLY on ACTUAL alias evidence:
    ///   (i)  the alias surface OCCURS in the corrected transcript under the
    ///        corrector's alias-hit authority (`VocabTokenizer` + the
    ///        `VocabNormalization.aliasMode` core fold — diacritic-EXACT, the SAME
    ///        mode the alias corrector keys on; NOT `canonicalMode`), OR
    ///   (ii) there is an `AppliedCorrection` whose `stage == "alias"`, whose
    ///        `original` folds (alias-mode) to the alias, and whose `canonical`
    ///        equals the entry's canonical (so a correction-LIMITED alias — one
    ///        whose canonical is never injected into the transcript — still
    ///        resolves).
    /// A pair is NEVER admitted merely because its canonical appears (the
    /// canonical may have been spoken normally — not alias evidence). Pairs carry
    /// ORIGINAL-CASE surfaces, in deterministic dictionary order (entries, then
    /// aliases within an entry); duplicates collapse (first occurrence wins).
    ///
    /// RESUME ROBUSTNESS: on the bare digest-resume path `corrections` is `[]`
    /// (the records are not reconstructed), so path (ii) is unreachable there;
    /// path (i) still fires because the corrected transcript is reloaded. A
    /// correction-limited alias is therefore omitted only on bare resume — and
    /// that is recoverable (its canonical is already in the corrected transcript,
    /// so the entity stays nameable). See the T3.1 spec note.
    public static func scopedAliasBindings(
        dictionary: VocabularyDictionary,
        correctedSegments: [TranscriptSegment],
        corrections: [AppliedCorrection]
    ) -> [AliasPair] {
        // Alias surfaces present in the corrected transcript, as alias-mode
        // single-/multi-token core joins (the corrector's actual alias match key).
        let transcriptKeys = aliasModeCoreSet(correctedSegments.map(\.text))
        // Applied `.alias` corrections: the alias-mode fold of each original →
        // the set of canonicals it was corrected to (path (ii)).
        var appliedAlias: [String: Set<String>] = [:]
        for correction in corrections where correction.stage == Correction.Stage.alias.rawValue {
            let key = aliasModeKey(correction.original)
            guard !key.isEmpty else { continue }
            appliedAlias[key, default: []].insert(correction.canonical)
        }

        var pairs: [AliasPair] = []
        var seen: Set<String> = [] // alias-mode-key|canonical, dedup across entries
        for entry in dictionary.entries {
            let canonical = entry.canonical
            for alias in entry.aliases {
                let aliasKey = aliasModeKey(alias)
                guard !aliasKey.isEmpty else { continue }
                // Self-pair exclusion: an alias whose folded surface equals the
                // canonical's carries no resolution (and is not alias evidence).
                if aliasKey == aliasModeKey(canonical) { continue }
                // Path (i): the alias surface occurs in the corrected transcript.
                let pathI = transcriptKeys.contains(aliasKey)
                // Path (ii): an applied `.alias` correction maps this alias to
                // this canonical.
                let pathII = appliedAlias[aliasKey]?.contains(canonical) ?? false
                guard pathI || pathII else { continue }
                let dedup = aliasKey + "\u{0}" + canonical
                if seen.insert(dedup).inserted {
                    pairs.append(AliasPair(alias: alias, canonical: canonical))
                }
            }
        }
        return pairs
    }

    /// The host binding from the `user`-track owner (`UserIdentity`): the owner's
    /// FULLEST name (most name tokens, then longest) across the identity's name +
    /// aliases — a "First Last" form when the user has one — or `nil` when no name
    /// is set (pre-onboarding), where the renderer uses a neutral descriptor,
    /// never the raw `user` label. The full name anchors the host distinctly so
    /// the model cannot canonicalize the host's bare first name to a DIFFERENT
    /// vocabulary/roster person who shares it (a bare first name can otherwise be
    /// canonicalized to a same-first-name colleague listed in the glossary).
    public static func hostBinding(user: UserIdentity) -> HostBinding {
        let candidates = ([user.name] + user.aliases)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let fullest = candidates.max {
            ($0.split(separator: " ").count, $0.count)
                < ($1.split(separator: " ").count, $1.count)
        }
        return HostBinding(canonicalName: fullest)
    }

    // MARK: - Body-grounding (provenance rendering)

    /// True when `name` (all tokens, contiguously, at token boundaries, under the
    /// canonical fold) occurs verbatim somewhere in the transcript BODY — the
    /// same authority `SpeakerResolver`'s transcript-verbatim rule uses. Drives
    /// the per-turn `transcript-grounded` vs `roster-resolved` provenance marker:
    /// a resolved speaker name present in the body is transcript-grounded;
    /// otherwise it is roster-resolved (allowed from attendees/events/userName
    /// without body evidence) and is NOT tier-(c) evidence.
    public static func nameIsBodyGrounded(_ name: String, in segments: [TranscriptSegment]) -> Bool {
        let needle = foldedCores(name)
        guard !needle.isEmpty else { return false }
        for segment in segments {
            if containsContiguous(foldedCores(segment.text), needle) { return true }
        }
        return false
    }

    // MARK: - Folding helpers (mirror the corrector's alias-hit authority)

    /// Alias-mode (diacritic-exact) core join of a single surface — the
    /// corrector's alias match key for that surface.
    private static func aliasModeKey(_ surface: String) -> String {
        VocabTokenizer.tokenize(surface)
            .map { VocabNormalization.aliasMode($0.core) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The set of ALL contiguous alias-mode core windows (length 1…N) present
    /// across the given texts — so a multi-token alias surface matches the same
    /// way the corrector's longest-window scan would admit it.
    private static func aliasModeCoreSet(_ texts: [String]) -> Set<String> {
        var keys: Set<String> = []
        for text in texts {
            let cores = VocabTokenizer.tokenize(text)
                .map { VocabNormalization.aliasMode($0.core) }
                .filter { !$0.isEmpty }
            guard !cores.isEmpty else { continue }
            for start in cores.indices {
                var window = ""
                for end in start..<cores.count {
                    window += window.isEmpty ? cores[end] : " " + cores[end]
                    keys.insert(window)
                }
            }
        }
        return keys
    }

    private static func foldedCores(_ text: String) -> [String] {
        VocabTokenizer.tokenize(text)
            .map { VocabNormalization.canonicalMode($0.core) }
            .filter { !$0.isEmpty }
    }

    private static func containsContiguous(_ haystack: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start ..< start + needle.count]) == needle { return true }
        }
        return false
    }
}
