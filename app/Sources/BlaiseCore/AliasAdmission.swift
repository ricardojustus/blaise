import Foundation

/// The C5 alias admission rule (spec §Dictionary derivation, operationalizing the
/// D9 amendment): a curated mishearing alias is admissible iff its folded surface is
/// (a) absent from the full ~50k lexicons as a common word — a lexicon hit rejects
///     unless the surface was explicitly reviewed as name-shaped (disposition ii),
/// (b) absent from br_common_names (folded membership also covers the accent-drop
///     direction for listed names, e.g. "tomas" ← "Tomás"),
/// (c) non-colliding: its folded form must not already map to a different canonical.
/// Rule (d) — "could the alias be the accent-stripped form of a plausible real name
/// beyond the lists?" — is reviewer judgment; residual risks are recorded in the
/// manifest (e.g. Vexa / Vexá), not decided here.
public enum AliasAdmission {
    public enum Verdict: Equatable, Sendable {
        case admitted
        case rejected(Rejection)
    }

    public enum Rejection: Equatable, Sendable {
        /// Folded surface is a lexicon word (pt and/or en rank), not reviewed as name-shaped.
        case lexiconWord(ptRank: Int?, enRank: Int?)
        case brCommonName
        /// Folded surface already maps to a different canonical.
        case collision(existingCanonical: String)
    }

    /// - Parameters:
    ///   - existingSurfaces: folded surface form → canonical, across ALL entries
    ///     (canonicals and aliases), per the derivation collision assertion.
    ///   - reviewedNameShaped: folded surfaces whose lexicon hits were reviewed as
    ///     name-shaped (disposition rule ii) and therefore do not block admission.
    public static func evaluate(
        alias: String,
        canonical: String,
        ptLexicon: FrequencyList,
        enLexicon: FrequencyList,
        brCommonNames: Set<String>,
        existingSurfaces: [String: String],
        reviewedNameShaped: Set<String> = []
    ) -> Verdict {
        let folded = VocabNormalization.canonicalMode(alias)
        if brCommonNames.contains(folded) {
            return .rejected(.brCommonName)
        }
        if let existing = existingSurfaces[folded], existing != canonical {
            return .rejected(.collision(existingCanonical: existing))
        }
        let ptRank = ptLexicon.rank(of: alias)
        let enRank = enLexicon.rank(of: alias)
        if (ptRank != nil || enRank != nil), !reviewedNameShaped.contains(folded) {
            return .rejected(.lexiconWord(ptRank: ptRank, enRank: enRank))
        }
        return .admitted
    }
}
