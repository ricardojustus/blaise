import Foundation
import Testing
@testable import BlaiseCore

// G2 AC1: per-rule pins for the pure NameSubstitution.apply function.
// G2 AC5: idempotence + §2 write-rule refusals (NameCorrectionStore).

private func fold(_ s: String) -> String { VocabNormalization.canonicalMode(s) }

private func storeRow(_ key: String, _ replacement: String, everyday: Bool = false)
    -> NameSubstitution.StoreRow
{
    NameSubstitution.StoreRow(
        mishearedFolded: fold(key), replacement: replacement, everyday: everyday)
}

private func ctx(
    store: [NameSubstitution.StoreRow] = [],
    owners: [String] = [],
    polish: [String] = [],
    commonNames: Set<String> = []
) -> NameSubstitution.Context {
    NameSubstitution.Context(
        store: store, ownerCandidates: owners, commonNames: commonNames,
        polishCanonicals: polish)
}

private func notes(
    title: String? = nil, summary: String = "", detailed: String = "",
    decisions: [String] = [], actions: [ActionItem] = [], userItems: [ActionItem] = []
) -> NotesStructured {
    NotesStructured(
        title: title, summary: summary, detailedNotes: detailed,
        decisions: decisions, actionItems: actions, userActionItems: userItems)
}

// MARK: - Folded Damerau-Levenshtein (the metric the spec names)

@Suite struct NameSubstitutionMetricTests {
    @Test func pinnedDistances() {
        // §1 verified facts (folded Damerau-Levenshtein).
        #expect(NameSubstitution.damerauLevenshtein(fold("Vidal"), fold("Vido"), cap: 4) == 2)
        #expect(NameSubstitution.damerauLevenshtein(fold("Kobi"), fold("Koco"), cap: 4) == 2)
        #expect(NameSubstitution.damerauLevenshtein(fold("Sabel"), fold("Sable"), cap: 4) == 1)
    }

    @Test func transpositionIsOne() {
        #expect(NameSubstitution.damerauLevenshtein("ab", "ba", cap: 4) == 1)
    }

    @Test func capReturnsCapPlusOne() {
        #expect(NameSubstitution.damerauLevenshtein("abcdef", "uvwxyz", cap: 2) == 3)
    }
}

// MARK: - Rule 1: store hit + everyday scoping

@Suite struct NameSubstitutionRule1Tests {
    @Test func nonEverydayKeyAppliesEverywhere() {
        let context = ctx(store: [storeRow("semi", "Sable")])
        let result = NameSubstitution.apply(
            notes: notes(summary: "SEMI joined the call", actions: [ActionItem(owner: "SEMI", text: "send the deck")]),
            context: context)
        #expect(result.notes.summary == "Sable joined the call")
        #expect(result.notes.actionItems[0].owner == "Sable")
        #expect(result.report.contains { $0.rule == 1 && $0.replacement == "Sable" })
    }

    @Test func everydayKeyProseStaysUntouched_NC1() {
        // "riso" is everyday (pt 1929) → prose stays laughter; owner is fixed.
        let context = ctx(store: [storeRow("riso", "Marco Vidal", everyday: true)])
        let result = NameSubstitution.apply(
            notes: notes(
                summary: "houve muito riso na sala",
                actions: [ActionItem(owner: "riso", text: "revisar contrato")]),
            context: context)
        #expect(result.notes.summary == "houve muito riso na sala") // prose: untouched
        #expect(result.notes.actionItems[0].owner == "Marco Vidal") // owner: fixed
    }

    @Test func hyphenGuard_semiAbertoIntact() {
        // "semi-aberto" must not match even with a semi store row, in an OWNER
        // field (so everyday scoping isn't what protects it — the guard is).
        let context = ctx(store: [storeRow("semi", "Sable", everyday: true)])
        let result = NameSubstitution.apply(
            notes: notes(actions: [ActionItem(owner: "semi-aberto", text: "x")]),
            context: context)
        #expect(result.notes.actionItems[0].owner == "semi-aberto")
        #expect(result.report.isEmpty)
    }

    @Test func hyphenGuard_enDashCompoundIntact_L1() {
        // L-1: an en-dash (U+2013) compound is an intra-word dash context too.
        let context = ctx(store: [storeRow("semi", "Sable", everyday: true)])
        let result = NameSubstitution.apply(
            notes: notes(actions: [ActionItem(owner: "semi\u{2013}aberto", text: "x")]),
            context: context)
        #expect(result.notes.actionItems[0].owner == "semi\u{2013}aberto")
        #expect(result.report.isEmpty)
    }

    @Test func contextFixedPoint_NC2() {
        // Vidal → Marco Vidal: "Marco Vidal" stays; bare "Vidal" expands.
        let context = ctx(store: [storeRow("Vidal", "Marco Vidal")])
        let stable = NameSubstitution.apply(
            notes: notes(summary: "Marco Vidal aprovou"), context: context)
        #expect(stable.notes.summary == "Marco Vidal aprovou")
        #expect(stable.report.isEmpty)

        let expand = NameSubstitution.apply(
            notes: notes(summary: "Vidal aprovou"), context: context)
        #expect(expand.notes.summary == "Marco Vidal aprovou")
        #expect(expand.report.count == 1)
    }

    @Test func quotedSpanImmunity() {
        let context = ctx(store: [storeRow("semi", "Sable")])
        let result = NameSubstitution.apply(
            notes: notes(summary: "ele disse \"SEMI\" em voz alta"), context: context)
        #expect(result.notes.summary == "ele disse \"SEMI\" em voz alta")
    }

    @Test func unbalancedQuoteHasNoImmunity() {
        let context = ctx(store: [storeRow("semi", "Sable")])
        let result = NameSubstitution.apply(
            notes: notes(summary: "\"SEMI no fim"), context: context)
        #expect(result.notes.summary == "\"Sable no fim")
    }

    // C-2 / H-9 (spec v5.2): a possessive apostrophe ("Sam's") is never a quote
    // delimiter — but under v5.2 NEITHER is a STRAIGHT single quote. So the
    // 'keep hizo as is' span is NOT immune (straight quotes don't pair), and
    // "hizo" being prose, the non-everyday `hizo → Vidal` row fires there. The
    // load-bearing guarantee that survives is STABILITY: the possessive does not
    // flip any pairing parity, so apply∘apply == apply (no run-away rewrite).
    @Test func possessiveDoesNotBreakQuoteImmunity_C2() {
        let context = ctx(store: [storeRow("hizo", "Vidal")])
        let once = NameSubstitution.apply(
            notes: notes(summary: "Sam's plan: 'keep hizo as is' for now"), context: context).notes
        #expect(once.summary == "Sam's plan: 'keep Vidal as is' for now")
        let twice = NameSubstitution.apply(notes: once, context: context)
        #expect(once == twice.notes, "stable: no apostrophe parity flip on re-apply")
        #expect(twice.report.isEmpty)
    }

    // C-2 idempotence form: an apostrophe-bearing REPLACEMENT ("O'Neil") must
    // not re-pair downstream quotes on a second pass and rewrite a quoted span.
    // Under v5.2 straight single quotes are never delimiters, so "hizo" is prose
    // and corrects on pass 1; "xq" → "O'Neil" likewise; the apostrophe in the
    // replacement does not flip parity, so the second pass is a no-op.
    @Test func apostropheReplacementIdempotentAcrossQuote_C2() {
        let context = ctx(store: [storeRow("xq", "O'Neil"), storeRow("hizo", "Vidal")])
        let once = NameSubstitution.apply(
            notes: notes(summary: "xq said 'hizo stays' today"), context: context).notes
        let twice = NameSubstitution.apply(notes: once, context: context)
        #expect(once == twice.notes, "apply∘apply must equal apply with an apostrophe replacement")
        #expect(once.summary == "O'Neil said 'Vidal stays' today")
        #expect(twice.report.isEmpty)
    }

    // The C-2 fix narrows QUOTE detection only; it does not change word
    // segmentation. A possessive "hizo's" is one `.byWords` run that folds to
    // "hizo's" (not "hizo"), so it does not match a "hizo" key — a documented
    // miss (the possessive carries the apostrophe-s), never a corruption. The
    // bare name still corrects.
    @Test func bareMisheardNameCorrected_possessiveLeftAlone_C2() {
        let context = ctx(store: [storeRow("hizo", "Vidal")])
        let result = NameSubstitution.apply(
            notes: notes(actions: [ActionItem(owner: "hizo deck", text: "x")]), context: context)
        #expect(result.notes.actionItems[0].owner == "Vidal deck")
        let poss = NameSubstitution.apply(
            notes: notes(actions: [ActionItem(owner: "hizo's deck", text: "x")]), context: context)
        #expect(poss.notes.actionItems[0].owner == "hizo's deck") // unmatched, unchanged
    }

    // H-9 (spec v5.2): a STRAIGHT apostrophe is NEVER a quote delimiter. The
    // round-2 audit's exact probes: an s-ending possessive ("Atlas'") and a
    // leading elision ("'em", "'90s") used to flip the single-quote pairing
    // parity and pull the genuinely 'quoted' span out of immunity, rewriting the
    // verbatim quoted text in a single pass. With straight apostrophes ignored,
    // the 'keep hizo as is' span has NO balanced curly/double delimiter around
    // it, so it is NOT immune — but "hizo" there is prose and "hizo→Vidal" is a
    // non-everyday key that fires in prose, so it DOES correct. The point the pin
    // guards is that the apostrophes neither create nor destroy immunity and the
    // result is STABLE (idempotent), with no parity flip rewriting unrelated text.
    @Test func sEndingPossessiveNotQuoteDelimiter_H9() {
        let context = ctx(store: [storeRow("hizo", "Vidal")])
        // The auditor's verbatim probe string.
        let once = NameSubstitution.apply(
            notes: notes(summary: "Atlas' plan: 'keep hizo as is'"), context: context).notes
        #expect(once.summary == "Atlas' plan: 'keep Vidal as is'")
        let twice = NameSubstitution.apply(notes: once, context: context)
        #expect(once == twice.notes, "stable: no apostrophe parity flip on re-apply")
        #expect(twice.report.isEmpty)
        // Sharper: two s-possessives spanning a name. If a straight ' were a
        // delimiter, "Atlas' deck and hizo'" would pair into an immune span and
        // SHIELD "hizo" from correction. Under v5.2 straight quotes give NO
        // immunity, so "hizo" corrects — distinguishing the fix from the neuter.
        let pair = NameSubstitution.apply(
            notes: notes(summary: "Atlas' deck and hizo' notes"), context: context).notes
        #expect(pair.summary == "Atlas' deck and Vidal' notes")
    }

    // H-9 elision form: a leading elision apostrophe ("'em", "'90s") is also
    // never a delimiter. The auditor's probe: "keep 'em honest, said 'hizo stays'
    // loudly" — the straight quotes do not pair, so nothing is immune; "hizo" is
    // a prose store hit and corrects, and the result is stable.
    @Test func leadingElisionNotQuoteDelimiter_H9() {
        let context = ctx(store: [storeRow("hizo", "Vidal")])
        let once = NameSubstitution.apply(
            notes: notes(summary: "keep 'em honest, said 'hizo stays' loudly"), context: context)
            .notes
        #expect(once.summary == "keep 'em honest, said 'Vidal stays' loudly")
        let twice = NameSubstitution.apply(notes: once, context: context)
        #expect(once == twice.notes)
        #expect(twice.report.isEmpty)
        // "'90s" carries no store hit and must pass through untouched + stable.
        let decade = NameSubstitution.apply(
            notes: notes(summary: "back in the '90s, said 'hizo'"), context: context).notes
        #expect(decade.summary == "back in the '90s, said 'Vidal'")
    }

    // H-9 + real quotation: a genuinely quoted span using CURLY single quotes
    // (what LLM-generated notes actually emit) IS still immune; the surrounding
    // straight apostrophes do not interfere with the curly pairing.
    @Test func curlyQuotedSpanStillImmune_H9() {
        let context = ctx(store: [storeRow("hizo", "Vidal")])
        let result = NameSubstitution.apply(
            notes: notes(summary: "Atlas' nota: \u{2018}keep hizo as is\u{2019} hoje"),
            context: context)
        #expect(result.notes.summary == "Atlas' nota: \u{2018}keep hizo as is\u{2019} hoje")
        #expect(result.report.isEmpty)
    }

    @Test func markdownIntact() {
        let context = ctx(store: [storeRow("semi", "Sable")])
        let md = "## Notas\n\n- **SEMI** falou sobre o *projeto*\n"
        let result = NameSubstitution.apply(notes: notes(detailed: md), context: context)
        #expect(result.notes.detailedNotes == "## Notas\n\n- **Sable** falou sobre o *projeto*\n")
    }
}

// MARK: - Rule 2: owner fuzzy fix (honest misses + a firing case)

@Suite struct NameSubstitutionRule2Tests {
    @Test func honestMisses_risoCaco_doNotFire() {
        // riso→Vidal (d=2, len(Vidal)=5 → tol 1) and caco→Kobi (d=2, len 4 → tol
        // 1) NEVER fire by rule 2 (documented). No store rows here.
        let risoCtx = ctx(owners: ["Vidal"])
        let r1 = NameSubstitution.apply(
            notes: notes(actions: [ActionItem(owner: "riso", text: "x")]), context: risoCtx)
        #expect(r1.notes.actionItems[0].owner == "riso")

        let cacoCtx = ctx(owners: ["Kobi"])
        let r2 = NameSubstitution.apply(
            notes: notes(actions: [ActionItem(owner: "caco", text: "x")]), context: cacoCtx)
        #expect(r2.notes.actionItems[0].owner == "caco")
    }

    @Test func len6Distance2CaseFires() {
        // A len-6 candidate token, d=2 (tol 2): owner "Marina" vs candidate
        // "Zoran" — wait, choose a clean fire: candidate "Adrian" (len 6),
        // owner "Adryen" d=2.
        let context = ctx(owners: ["Adrian Sorrel"])
        let result = NameSubstitution.apply(
            notes: notes(actions: [ActionItem(owner: "Adryen", text: "x")]), context: context)
        #expect(result.notes.actionItems[0].owner == "Adrian Sorrel")
        #expect(result.report.contains { $0.rule == 2 })
    }

    @Test func commonNameVariantGuard_NH2() {
        // Paulo (common name) vs candidate "Paula" at d=1 → never fire.
        let context = ctx(owners: ["Paula"], commonNames: ["paulo", "paula"])
        let result = NameSubstitution.apply(
            notes: notes(actions: [ActionItem(owner: "Paulo", text: "x")]), context: context)
        #expect(result.notes.actionItems[0].owner == "Paulo")
    }

    @Test func alreadyEntityNoOp() {
        let context = ctx(owners: ["Adrian Sorrel"])
        let result = NameSubstitution.apply(
            notes: notes(actions: [ActionItem(owner: "Adrian Sorrel", text: "x")]), context: context)
        #expect(result.notes.actionItems[0].owner == "Adrian Sorrel")
        #expect(result.report.isEmpty)
    }

    @Test func ambiguityNoOp() {
        // Two candidate tokens within tolerance of the owner → tie → no-op.
        let context = ctx(owners: ["Marcos", "Markus"])
        let result = NameSubstitution.apply(
            notes: notes(actions: [ActionItem(owner: "Marcus", text: "x")]), context: context)
        #expect(result.notes.actionItems[0].owner == "Marcus")
    }

    @Test func rule2DoesNotFireInProse() {
        let context = ctx(owners: ["Adrian Sorrel"])
        let result = NameSubstitution.apply(
            notes: notes(summary: "Adryen aprovou"), context: context)
        #expect(result.notes.summary == "Adryen aprovou")
    }

    // H-1: two DIFFERENT humans whose full names share the matched first-name
    // token ("Sable Marsh", "Sable Lee" both within d of owner "Sabel") are a
    // TIE → deterministic no-op, NOT last-candidate-wins. Pre-fix the tie was
    // declared only on distinct TOKENS, so the shared "sable" token was "not
    // ambiguous" and an arbitrary full name won.
    @Test func sharedFirstNameTieNoOps_H1() {
        let context = ctx(owners: ["Sable Marsh", "Sable Lee"])
        let result = NameSubstitution.apply(
            notes: notes(actions: [ActionItem(owner: "Sabel", text: "x")]), context: context)
        #expect(result.notes.actionItems[0].owner == "Sabel", "shared-token tie → no-op")
        #expect(result.report.isEmpty)
    }

    // H-1 boundary: a SINGLE candidate sharing the token still fires (the tie is
    // over distinct full names, not the mere presence of the token).
    @Test func singleSharedFirstNameCandidateFires_H1() {
        let context = ctx(owners: ["Sable Marsh"])
        let result = NameSubstitution.apply(
            notes: notes(actions: [ActionItem(owner: "Sabel", text: "x")]), context: context)
        #expect(result.notes.actionItems[0].owner == "Sable Marsh")
    }

    // H-2: rule 2 is FIELD-LEVEL — a fire replaces the WHOLE owner field with
    // the candidate's full name, never splices a third name into a multi-word
    // owner. Owner "Marina Silva" with attendee "Mariana Costa" must NOT become
    // "Mariana Costa Silva". The whole field does not fuzzy-match a single
    // candidate, so the correct outcome is a no-op (left as-is).
    @Test func multiWordOwnerNotSpliced_H2() {
        let context = ctx(owners: ["Mariana Costa"])
        let result = NameSubstitution.apply(
            notes: notes(actions: [ActionItem(owner: "Marina Silva", text: "x")]), context: context)
        #expect(result.notes.actionItems[0].owner == "Marina Silva", "no per-word splice")
        #expect(!result.notes.actionItems[0].owner.contains("Mariana Costa Silva"))
    }

    // H-2 firing form: a SINGLE-word owner still fixes to the full name (the
    // field-level replacement of the whole field equals the per-word case here).
    @Test func singleWordOwnerReplacedWhole_H2() {
        let context = ctx(owners: ["Adrian Sorrel"])
        let result = NameSubstitution.apply(
            notes: notes(actions: [ActionItem(owner: "Adryen", text: "x")]), context: context)
        #expect(result.notes.actionItems[0].owner == "Adrian Sorrel")
    }

    // C-3 (spec v5.2, NC-2 extended): the rule-2→rule-1 surname-expansion
    // composition is killed. Auditor's EXACT probe: store `Vidal → Marco
    // Vidal` + attendee/speaker "Halden Vidal". Owner "Vidau" (a fuzzy near-miss
    // of "Vidal") fires rule 2 to the candidate's full name "Halden Vidal" on
    // pass 1, and on pass 2 the `Vidal` store row must NOT then expand the "Vidal"
    // INSIDE that already-correct full name to "Halden Marco Vidal" — the
    // run is a sub-run of a neighborhood fold-equal to a known entity, so it is
    // skipped. apply∘apply == apply.
    @Test func rule2ToRule1SurnameRelaySuppressed_C3() {
        let context = ctx(
            store: [storeRow("Vidal", "Marco Vidal")],
            owners: ["Halden Vidal"])
        let once = NameSubstitution.apply(
            notes: notes(actions: [ActionItem(owner: "Vidau", text: "x")]), context: context).notes
        #expect(once.actionItems[0].owner == "Halden Vidal", "rule 2 grounds Vidau → Halden Vidal")
        let twice = NameSubstitution.apply(notes: once, context: context)
        #expect(
            twice.notes.actionItems[0].owner == "Halden Vidal",
            "the Vidal store row must NOT expand the surname inside the full name")
        #expect(once == twice.notes, "apply∘apply == apply (no surname relay)")
        #expect(twice.report.isEmpty)
    }

    // C-3 single-pass label form: the SAME interaction garbles a CORRECT
    // co-surname bearer in ONE pass on the speaker-label path that production
    // re-applies every regenerate. A speaker correctly labelled "Halden Vidal"
    // (also an attendee) must NOT become "Halden Marco Vidal" under a
    // `Vidal → Marco Vidal` store row in `applyToLabel`. This is the probe
    // that hits production directly (ProcessingPipeline applyStoreToSpeakerLabels).
    @Test func coSurnameBearerLabelNotGarbled_C3() {
        let context = ctx(
            store: [storeRow("Vidal", "Marco Vidal")],
            owners: ["Halden Vidal"])
        let label = NameSubstitution.applyToLabel("Halden Vidal", context: context)
        #expect(label == "Halden Vidal", "co-surname bearer label preserved (single pass)")
        // And bare "Vidal" (no known-entity neighbor) still expands — the skip is
        // scoped to the known-entity neighborhood, not a blanket suppression.
        let bare = NameSubstitution.applyToLabel("Vidal", context: context)
        #expect(bare == "Marco Vidal", "a lone misheard surname still expands")
    }
}

// MARK: - Rule 3: label polish

@Suite struct NameSubstitutionRule3Tests {
    @Test func labelPolishToCanonicalSurface() {
        // owner "zoran" → canonical "Zóran" (fold-equal, surface differs).
        let context = ctx(owners: [], polish: ["Zóran"])
        let result = NameSubstitution.apply(
            notes: notes(actions: [ActionItem(owner: "Zoran", text: "x")]), context: context)
        #expect(result.notes.actionItems[0].owner == "Zóran")
        #expect(result.report.contains { $0.rule == 3 })
    }

    @Test func labelPolishIdempotent() {
        let context = ctx(owners: [], polish: ["Zóran"])
        let once = NameSubstitution.apply(
            notes: notes(actions: [ActionItem(owner: "Zoran", text: "x")]), context: context)
        let twice = NameSubstitution.apply(notes: once.notes, context: context)
        #expect(once.notes == twice.notes)
        #expect(twice.report.isEmpty)
    }
}

// MARK: - Overlap resolution

@Suite struct NameSubstitutionOverlapTests {
    @Test func multiOccurrenceAllReplaced() {
        let context = ctx(store: [storeRow("semi", "Sable")])
        let result = NameSubstitution.apply(
            notes: notes(summary: "SEMI e SEMI conversaram"), context: context)
        #expect(result.notes.summary == "Sable e Sable conversaram")
        #expect(result.report.count == 2)
    }
}

// MARK: - Idempotence property (AC5)

@Suite struct NameSubstitutionIdempotenceTests {
    @Test func applyApplyEqualsApply_acrossMultiWord() {
        let context = ctx(store: [
            storeRow("Vidal", "Marco Vidal"),
            storeRow("semi", "Sable"),
        ], polish: ["Zóran"])
        let inputs = [
            notes(summary: "Vidal e SEMI falaram com Zoran"),
            notes(detailed: "Marco Vidal aprovou; Vidal confirmou"),
            notes(summary: "\"Vidal\" entre aspas e Vidal solto"),
        ]
        for input in inputs {
            let once = NameSubstitution.apply(notes: input, context: context).notes
            let twice = NameSubstitution.apply(notes: once, context: context)
            #expect(once == twice.notes, "apply∘apply must equal apply")
            #expect(twice.report.isEmpty, "second pass must be a no-op")
        }
    }
}

// MARK: - Empty-store identity (AC6 building block)

@Suite struct NameSubstitutionIdentityTests {
    @Test func emptyStoreIsIdentity() {
        let context = ctx()
        let input = notes(
            title: "Reunião de orçamento",
            summary: "Discutimos o **plano** com R$ 1.000,00",
            detailed: "## Decisões\n- item",
            decisions: ["fechado: seguir"],
            actions: [ActionItem(owner: "Sam", text: "enviar proposta")],
            userItems: [ActionItem(owner: "Sam", text: "enviar proposta")])
        let result = NameSubstitution.apply(notes: input, context: context)
        #expect(result.notes == input)
        #expect(result.report.isEmpty)
    }
}
