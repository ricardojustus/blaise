import Foundation
import Testing
@testable import BlaiseCore

/// G1 §5a.2 / AC2(b) / AC6 — the alias-core scan relocated into BlaiseCore,
/// pinned by the scan's recorded decisions (VocabTool's `compoundAliases` table
/// and the manifest). VocabTool has no test target (Package.swift), so the
/// equivalence is pinned here where the code now lives.
@Suite struct AliasCoreScanTests {
    private var pt: FrequencyList { VocabFixtures.ptList }
    private var en: FrequencyList { VocabFixtures.enList }

    private func noDistinctiveCore(_ alias: String) -> Bool {
        AliasCoreScan.hasNoDistinctiveCore(alias, pt: pt, en: en)
    }

    // MARK: Recorded-decision pins (the "Dozen Labs" rejection among them).

    @Test func rejectsAllCommonCoreCompounds() {
        // Recorded REJECTED in VocabTool.compoundAliases: both cores common EN.
        #expect(noDistinctiveCore("Dozen Labs"))
        #expect(noDistinctiveCore("Pet ball"))
    }

    @Test func admitsCompoundsWithADistinctiveCore() {
        // Recorded ADDED: 'pln'/'nvr' are not lexicon words → distinctive anchor.
        #expect(!noDistinctiveCore("PLN 1"))
        #expect(!noDistinctiveCore("NVR 2"))
    }

    @Test func singleTokenAliasesAreOutOfScope() {
        // The scan only judges multi-token surfaces (single tokens go through
        // the alias-admission rule / Level-A machinery).
        #expect(!noDistinctiveCore("Tobes"))
        #expect(!noDistinctiveCore("computer"))
    }

    @Test func rankCutMatchesTheRecordedThreshold() {
        #expect(AliasCoreScan.commonRankCut == 40_000)
    }

    @Test func lexiconCommonHonorsTheCutInBothLists() {
        // A common EN word is lexicon-common; a deep-corpus/absent token is not.
        #expect(AliasCoreScan.isLexiconCommon("labs", pt: pt, en: en))
        #expect(AliasCoreScan.isLexiconCommon("eleven", pt: pt, en: en))
        #expect(!AliasCoreScan.isLexiconCommon("nvr", pt: pt, en: en))
        #expect(!AliasCoreScan.isLexiconCommon("pln1", pt: pt, en: en))
    }

    // MARK: Equivalence with the shipped manifest's compound-alias scan.

    @Test func matchesShippedManifestVerdicts() {
        // `hasNoDistinctiveCore` is a PURE all-cores-lexicon-common check: it
        // rejects iff every core is lexicon-common, with no brand exemption. The
        // manifest's verdicts split that raw rejection into two curation outcomes:
        //   • rejected_all_cores_lexicon_common — dropped (a phonetic mishearing
        //     whose spaced surface occurs in ordinary speech), and
        //   • added_curated_brand_compound — the scanner ALSO rejects (all cores
        //     common), but the distinctive product/title surface is curated in
        //     anyway, EXEMPT from the rejection.
        // Both therefore correspond to scanner-rejected==true. Only `added`
        // (a distinctive core, absent from both lexicons or ranked >40000) is
        // admitted by the raw scan. So the scanner's raw verdict is the oracle for
        // the lexicon-common-ness the manifest records, and the curated exemption
        // is the only divergence between scan output and shipping decision.
        for record in VocabFixtures.manifest.compoundAliasScan {
            let rejected = noDistinctiveCore(record.alias)
            switch record.verdict {
            case "rejected_all_cores_lexicon_common", "added_curated_brand_compound":
                #expect(rejected, "scan should find no distinctive core in \(record.alias)")
            case "added":
                #expect(!rejected, "scan should find a distinctive core in \(record.alias)")
            default:
                Issue.record("unexpected compoundAliasScan verdict '\(record.verdict)' for \(record.alias)")
            }
        }
    }

    // MARK: Gate 0a — the TOTAL no-punctuation rule, pinned INDEPENDENTLY
    //
    // These pin `carriesDisallowedPunctuation` directly (not through the loader),
    // so neutering the function alone fails a named test — the round-2 finding
    // that the belt-and-braces peeled re-run masked the gate (R2-L-1).

    @Test func gate0aRejectsEveryNonAlphanumericNonSpaceCharacter() {
        // Edge punctuation, interior punctuation, apostrophes (straight + curly),
        // quotes, em-dash, interpunct, fullwidth, zero-width — all rejected.
        for surface in [
            "caco.", "**caco**", "(caco)", "caco,", "ca.co", "c-a-c-o",
            "segunda-feira", "fim-de-semana", "follow-up",
            "cat's", "maria's", "caco'", "caco\u{2019}",
            "\u{201C}caco\u{201D}", "caco\u{2014}", "caco\u{2026}",
            "caco\u{00B7}", "caco\u{FF0E}", "ca\u{200B}co", "caco\u{200B}",
        ] {
            #expect(AliasCoreScan.carriesDisallowedPunctuation(surface), "should reject \(surface)")
        }
    }

    @Test func gate0aAdmitsPlainLettersDigitsAndSingleSpaces() {
        for surface in ["caco", "Vexatron", "vexatron labs", "pln 1", "nvr 2", "Caçó"] {
            #expect(!AliasCoreScan.carriesDisallowedPunctuation(surface), "should admit \(surface)")
        }
    }

    @Test func gate0aRejectsDoubleInternalSpace() {
        #expect(AliasCoreScan.carriesDisallowedPunctuation("vexatron  labs"))
    }

    /// Impl-audit round-4 M-1: letterless aliases (`360`, `2026`, `100`) are
    /// invisible to every lexicon gate yet rewrite every numeral occurrence
    /// in a transcript. An alias must contain at least one letter.
    @Test func gate0aRejectsLetterlessAliases() {
        for surface in ["360", "2026", "100", "360 360", "2 0 2 6"] {
            #expect(AliasCoreScan.carriesDisallowedPunctuation(surface), "should reject \(surface)")
        }
        // Mixed digit+letter aliases stay admissible (the pln/nvr-2 class).
        for surface in ["pln 1", "nvr 2", "rio2"] {
            #expect(!AliasCoreScan.carriesDisallowedPunctuation(surface), "should admit \(surface)")
        }
    }

    // MARK: Empty-core detection — both helpers pinned directly.

    @Test func hasEmptyPeeledCoresDetectsAllPunctuationSurfaces() {
        #expect(AliasCoreScan.hasEmptyPeeledCores("---"))
        #expect(AliasCoreScan.hasEmptyPeeledCores("..."))
        #expect(!AliasCoreScan.hasEmptyPeeledCores("caco"))
        #expect(!AliasCoreScan.hasEmptyPeeledCores("maria silva -"))
    }

    @Test func hasAnyEmptyPeeledCoreDetectsAStandalonePunctuationToken() {
        // The R2-H-2 hole: a SOME-empty-core surface (a punctuation-only token
        // among real ones) that `hasEmptyPeeledCores` (all-empty) misses.
        #expect(AliasCoreScan.hasAnyEmptyPeeledCore("maria silva -"))
        #expect(AliasCoreScan.hasAnyEmptyPeeledCore("caco -"))
        #expect(AliasCoreScan.hasAnyEmptyPeeledCore("---"))
        #expect(!AliasCoreScan.hasAnyEmptyPeeledCore("maria silva"))
        #expect(!AliasCoreScan.hasAnyEmptyPeeledCore("caco"))
    }
}
