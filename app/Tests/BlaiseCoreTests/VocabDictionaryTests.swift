import Foundation
import Testing
@testable import BlaiseCore

/// C5 AC1 — parser ↔ manifest, grammar, suppression set, alias admission.
@Suite struct VocabDictionaryTests {
    // MARK: Parser grammar

    @Test func parserMatchesManifest() {
        let dictionary = VocabFixtures.dictionary
        let manifest = VocabFixtures.manifest
        #expect(dictionary.warnings.isEmpty)
        #expect(dictionary.entries.count == manifest.entryCount)
        #expect(dictionary.entries.reduce(0) { $0 + $1.aliases.count } == manifest.aliasCount)
        let multiToken = dictionary.entries.filter { VocabTokenizer.tokenize($0.canonical).count > 1 }
        #expect(multiToken.count == manifest.multiTokenEntryCount)
    }

    @Test func extendedFormParsesCanonicalAndAliases() {
        let parsed = VocabularyDictionary.parse("Toban|Tobes|Tello\n")
        #expect(parsed.entries == [VocabularyEntry(canonical: "Toban", aliases: ["Tobes", "Tello"])])
        #expect(parsed.warnings.isEmpty)
    }

    @Test func fieldsAreWhitespaceTrimmed() {
        let parsed = VocabularyDictionary.parse("  PLN1  |  PLN 1  \n")
        #expect(parsed.entries == [VocabularyEntry(canonical: "PLN1", aliases: ["PLN 1"])])
    }

    @Test func emptyCanonicalSkippedWithSurfacedWarning() {
        let parsed = VocabularyDictionary.parse("""
        |orphan alias
        Valid Entry
        """)
        #expect(parsed.entries == [VocabularyEntry(canonical: "Valid Entry", aliases: [])])
        #expect(parsed.warnings.count == 1)
        #expect(parsed.warnings[0].contains("line 1"))
    }

    @Test func emptyAliasFieldDroppedFieldWiseEntrySurvives() {
        // G1 §2 amendment: an empty alias field is dropped field-wise; the entry
        // survives on its remaining fields, with a surfaced warning.
        let parsed = VocabularyDictionary.parse("""
        Valid Entry
        Broken||x
        """)
        #expect(parsed.entries == [
            VocabularyEntry(canonical: "Valid Entry", aliases: []),
            VocabularyEntry(canonical: "Broken", aliases: ["x"]),
        ])
        #expect(parsed.warnings.count == 1)
        #expect(parsed.warnings[0].contains("line 2"))
    }

    @Test func fieldTrimsHandleCarriageReturns() {
        // G1 §2 amendment: field trims include `\r` (CRLF-safe).
        let parsed = VocabularyDictionary.parse("Toban|Tobes\r\nNira\r\n")
        #expect(parsed.entries == [
            VocabularyEntry(canonical: "Toban", aliases: ["Tobes"]),
            VocabularyEntry(canonical: "Nira", aliases: []),
        ])
        #expect(parsed.warnings.isEmpty)
    }

    @Test func sectionHeadersAndBlanksIgnored() {
        let parsed = VocabularyDictionary.parse("# people\n\nNira\n# other terms\nPLN1\n")
        #expect(parsed.entries.map(\.canonical) == ["Nira", "PLN1"])
    }

    @Test func commaHasNoSyntacticMeaning() {
        let parsed = VocabularyDictionary.parse("A, B\n")
        #expect(parsed.entries == [VocabularyEntry(canonical: "A, B", aliases: [])])
    }

    // MARK: Effective suppression set

    @Test func foldedMembership() {
        let set = VocabFixtures.suppression
        // Diacritic-folded both sides: top-3000 PT words land folded.
        #expect(set.contains("voce")) // você, pt top-3000
        #expect(set.contains("nao")) // não
        #expect(set.contains("the"))
        #expect(set.contains("do"))
        #expect(set.contains("big"))
        #expect(set.contains("office"))
    }

    @Test func exclusionsHonored() {
        // "quest" must be non-stop whatever its vendored rank (defensive AC pin).
        #expect(!VocabFixtures.suppression.contains("quest"))
        // "renato" exclusion: name-shaped top-3000 presence must not suppress the entry.
        #expect(!VocabFixtures.suppression.contains("renato"))
    }

    @Test func collisionPolicyExampleWordsPresent() {
        let set = VocabFixtures.suppression
        // The synthetic project codenames are everyday PT (nautical) words that
        // collide with ordinary speech, so each is in the effective suppression
        // set (folded). A codename that collides with a common word must be
        // suppressed, never auto-corrected.
        for word in ["vela", "barco", "farol", "mare", "ancora", "bussola", "pedra", "ponte", "cais", "proa", "leme"] {
            #expect(set.contains(word), "expected suppression stop-word: \(word)")
        }
    }

    @Test func manifestRecordsScanDispositions() {
        let manifest = VocabFixtures.manifest
        // kuvira's lexicon hit is disposition-(ii) ACCEPTED — name-shaped, rank ≈ 44k (AC1).
        let kuvira = manifest.levelA.first { VocabNormalization.canonicalMode($0.surface) == "kuvira" }
        #expect(kuvira != nil)
        #expect(kuvira?.disposition.hasPrefix("accept_name_shaped") == true)
        #expect((30_000 ... 50_000).contains(kuvira?.enRank ?? 0))
        // proa/leme are Level-B flip dispositions with recorded justification (AC1).
        for word in ["proa", "leme"] {
            let record = manifest.stoplistProject.first { $0.word == word }
            #expect(record?.source == "level_b_flip", "expected level_b_flip for \(word)")
            #expect(record?.justification.isEmpty == false)
        }
        // The lexicon ranks backing the proa/leme disposition (≈ 13.5k / 9.9k):
        // real PT words outside the top-3000 cut, so case-restoring the spaced
        // codename surface would corrupt ordinary PT speech.
        #expect((10_000 ... 20_000).contains(VocabFixtures.ptList.rank(of: "proa") ?? 0))
        #expect((5_000 ... 15_000).contains(VocabFixtures.ptList.rank(of: "leme") ?? 0))
        // Every Level-A record carries exactly one disposition with a justification.
        for record in manifest.levelA {
            #expect(!record.disposition.isEmpty && !record.justification.isEmpty)
            #expect(record.ptRank != nil || record.enRank != nil, "Level-A record without a hit: \(record.surface)")
        }
        #expect(manifest.assertions.values.allSatisfy { $0 })
    }

    @Test func aliasCoreScanRejectsAllCommonCoreCompounds() {
        // H-1: a phonetic-mishearing multi-token alias is rejected iff ALL of its
        // cores are lexicon-common (rank ≤ 40000 in either full list) — the spaced
        // surface occurs in ordinary speech and alias hits have no suppression
        // branch. A curated BRAND/TITLE compound (a distinctive product or studio
        // name) is exempt: the spaced surface is itself the entity and never
        // appears in ordinary speech.
        let scan = VocabFixtures.manifest.compoundAliasScan
        let verdicts = Dictionary(uniqueKeysWithValues: scan.map { ($0.alias, $0.verdict) })
        // The planted mishearing "Quol Harbour" ships (distinctive core "quol").
        #expect(verdicts["Quol Harbour"] == "added")
        // Phonetic-mishearing candidates with only lexicon-common cores are rejected.
        #expect(verdicts["Dozen Labs"] == "rejected_all_cores_lexicon_common")
        #expect(verdicts["Apex Game"] == "rejected_all_cores_lexicon_common")
        // The rejected surfaces are gone from the shipped dictionary.
        #expect(VocabFixtures.surfaces["dozen labs"] == nil)
        #expect(VocabFixtures.surfaces["apex game"] == nil)
        // Curated brand/title compounds (all cores lexicon-common, but distinctive
        // spaced surfaces) are recorded as added curated compounds in the manifest.
        let curatedBrand = Set(
            scan.filter { $0.verdict == "added_curated_brand_compound" }.map(\.alias))
        // Every shipped multi-token alias is EITHER distinctive (has a core absent
        // from both lexicons or ranked > 40000) OR a recorded curated brand compound.
        for entry in VocabFixtures.dictionary.entries {
            for alias in entry.aliases {
                let cores = VocabTokenizer.tokenize(alias).map { VocabNormalization.canonicalMode($0.core) }
                guard cores.count > 1 else { continue }
                let allCommon = cores.allSatisfy { core in
                    (VocabFixtures.ptList.rank[core] ?? Int.max) <= 40_000
                        || (VocabFixtures.enList.rank[core] ?? Int.max) <= 40_000
                }
                #expect(
                    !allCommon || curatedBrand.contains(alias),
                    "alias '\(alias)' of '\(entry.canonical)' would rewrite ordinary speech")
            }
        }
    }

    // MARK: Alias admission rule

    private func evaluate(alias: String, canonical: String) -> AliasAdmission.Verdict {
        AliasAdmission.evaluate(
            alias: alias,
            canonical: canonical,
            ptLexicon: VocabFixtures.ptList,
            enLexicon: VocabFixtures.enList,
            brCommonNames: VocabFixtures.brCommonNames,
            existingSurfaces: VocabFixtures.surfaces
        )
    }

    @Test func admissionRejectsRealWordSink() {
        // "sink" is a real EN word — the D9-amendment class that must never ship.
        guard case .rejected(.lexiconWord(_, let enRank)) = evaluate(alias: "sink", canonical: "sync") else {
            Issue.record("expected lexiconWord rejection for 'sink'")
            return
        }
        #expect(enRank != nil)
    }

    @Test func admissionRejectsBrCommonNameMember() {
        // Folded membership also covers the accent-drop direction (Tomás → tomas).
        #expect(evaluate(alias: "Mateus", canonical: "Nira") == .rejected(.brCommonName))
        #expect(evaluate(alias: "Tomas", canonical: "Tomás") == .rejected(.brCommonName))
    }

    @Test func admissionRejectsLexiconWord() {
        guard case .rejected(.lexiconWord(let ptRank, _)) = evaluate(alias: "lance", canonical: "Lance Quoll") else {
            Issue.record("expected lexiconWord rejection for 'lance'")
            return
        }
        #expect(ptRank != nil)
    }

    @Test func admissionRejectsCrossEntryCollision() {
        // "Kobi" is its own canonical surface; admitting it as an alias of another
        // entry would make one folded surface map to two canonicals.
        #expect(evaluate(alias: "Kobi", canonical: "Elena Marquez")
            == .rejected(.collision(existingCanonical: "Kobi")))
    }

    @Test func admissionAdmitsTelo() {
        // The shipped alias "Tobes": a curated, evidenced mishearing of Toban Vane.
        // The manifest records the admission and its residual risk (M-2): "Tobes"
        // reads as a casual given-name nickname, admitted only as the evidenced
        // mishearing.
        let record = VocabFixtures.manifest.aliasAdmissions.first { $0.alias == "Tobes" }
        #expect(record?.verdict == "admitted")
        #expect(record?.canonical == "Toban Vane")
        #expect(record?.residualRisk.contains("nickname") == true)
    }

    @Test func admissionAdmitsKibura() {
        // Comparison analysis observed transcripts rendering the spoken surname
        // "Marsh" as "Marsa" — lexical garbage (absent from both lexicons and
        // br_common_names), so admissible as a curated mishearing.
        #expect(evaluate(alias: "Marsa", canonical: "Fernando Marsh") == .admitted)
        let record = VocabFixtures.manifest.aliasAdmissions.first { $0.alias == "Marsa" }
        #expect(record?.verdict == "admitted")
        #expect(record?.canonical == "Fernando Marsh")
    }

    @Test func admissionRejectsBart() {
        // Evaluated and REJECTED 2026-06-10 (spec v5.3): "Bart" is a real name with
        // lexicon presence in both lists, so a Bárbara|Bart alias must never ship
        // (the derivation also has no standalone Bárbara canonical to carry it —
        // bare Barbara is br_common_names-blocked).
        guard case .rejected(.lexiconWord(let ptRank, let enRank)) = evaluate(alias: "Bart", canonical: "Bárbara") else {
            Issue.record("expected lexiconWord rejection for 'Bart'")
            return
        }
        #expect(ptRank != nil && enRank != nil)
        // And the shipped dictionary carries no such surface.
        #expect(VocabFixtures.surfaces["bart"] == nil)
    }
}
