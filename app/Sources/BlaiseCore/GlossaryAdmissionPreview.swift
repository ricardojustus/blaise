import Foundation

/// G2 §5 (M-5): the silent pre-check that gates the "also add to glossary"
/// link. The link appears ONLY when the surface would pass G1 admission as an
/// alias — and that means the FULL gate stack, not `AliasAdmission.evaluate`
/// alone: gates 0a/0b (punctuation / empty-core safety) run FIRST, then
/// `AliasAdmission`, then the distinctive-core scan. Decorated input
/// ("**Sammy**", "Sammy.") must be previewed against its peeled form, exactly
/// as the loader does, so the link never shows for a surface a real load would
/// reject.
public enum GlossaryAdmissionPreview {
    /// True iff `surface` would be admitted as an alias of `canonical` under the
    /// G1 §5a gate stack (gates 0a/0b + AliasAdmission + distinctive-core).
    /// `existingSurfaces` is the current folded-surface→canonical collision
    /// input; pass an empty map when previewing against a clean slate.
    public static func wouldAdmit(
        surface: String,
        canonical: String,
        pt: FrequencyList,
        en: FrequencyList,
        brCommonNames: Set<String>,
        existingSurfaces: [String: String] = [:]
    ) -> Bool {
        // Gate 0b: empty peeled cores — no matchable text.
        if AliasCoreScan.hasEmptyPeeledCores(surface) { return false }
        // Gate 0a: the TOTAL no-punctuation rule.
        if AliasCoreScan.carriesDisallowedPunctuation(surface) { return false }
        // Gates 1+2: AliasAdmission (lexicon / common-name / collision).
        if case .rejected = AliasAdmission.evaluate(
            alias: surface, canonical: canonical, ptLexicon: pt, enLexicon: en,
            brCommonNames: brCommonNames, existingSurfaces: existingSurfaces)
        {
            return false
        }
        // Distinctive-core scan (a multi-token alias must carry a distinctive
        // core, else it would rewrite ordinary speech).
        if AliasCoreScan.hasNoDistinctiveCore(surface, pt: pt, en: en) { return false }
        return true
    }
}
