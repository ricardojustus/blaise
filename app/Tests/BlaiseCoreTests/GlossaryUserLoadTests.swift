import Foundation
import Testing
@testable import BlaiseCore

/// G1 AC2 (admission), AC3 (lifecycle), AC4 (provisioning) — the per-run
/// `PipelineVocabulary.user(dataRoot:)` load over a temp data root.
@Suite struct GlossaryUserLoadTests {
    // MARK: Temp-root scaffolding

    private func tempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("blaise-glossary-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeGlossary(_ body: String, at root: URL) {
        let url = MeetingPaths(rootURL: root).glossaryURL
        try! Data(body.utf8).write(to: url)
    }

    /// A glossary file with the standard header + an `## Entries` region holding
    /// the given lines.
    private func glossary(_ entries: String) -> String {
        "# Blaise Glossary\n\n## Entries\n\(entries)\n"
    }

    private func reasons(_ load: PipelineVocabulary.UserLoad) -> [GlossaryDiagnosticReason] {
        load.diagnostics.items.map(\.reason)
    }

    private func writeUserStoplist(_ body: String, at root: URL) {
        let url = MeetingPaths(rootURL: root).userStoplistURL
        try! Data(body.utf8).write(to: url)
    }

    // MARK: data-root stoplist_user.txt union (G6 stoplist split)

    /// The PRODUCTION `user(dataRoot:)` path unions the data-root
    /// `stoplist_user.txt` onto the bundled (now-empty) project suppression, so
    /// a deployed install's project terms still suppress. Exercises the union
    /// path itself (not the `fixture()` path), so a regression dropping the
    /// data-root union is caught.
    @Test func dataRootUserStoplistUnionedIntoSuppression() {
        let root = tempRoot()
        writeGlossary(glossary("# none"), at: root)

        // Without the file: the bundled project stoplist is empty, so a
        // distinctive non-everyday term is NOT in the suppression set.
        let bare = PipelineVocabulary.user(dataRoot: root)
        #expect(!bare.vocabulary.suppression.contains("vexatron"))

        // With the file: its folded terms are unioned into the suppression set.
        writeUserStoplist("# project terms\nvexatron\nquoll\n", at: root)
        let withStops = PipelineVocabulary.user(dataRoot: root)
        #expect(withStops.vocabulary.suppression.contains("vexatron"))
        #expect(withStops.vocabulary.suppression.contains("quoll"))
        // The bundled frequency base is still present (a top-3000 PT word).
        #expect(withStops.vocabulary.suppression.contains("lance"))
    }

    // MARK: AC2(a) — stoplist/common-name single-token alias rejected, NOT corrected

    @Test func ac2a_commonWordAliasRejectedAndNotCorrected() {
        let root = tempRoot()
        // "Lighthouse" is distinctive; "lance" is a PT top-3000 word → rejected.
        writeGlossary(glossary("Lighthouse | lance"), at: root)
        let load = PipelineVocabulary.user(dataRoot: root)
        #expect(reasons(load).contains {
            if case .aliasRejectedUnsafe = $0 { return true }; return false
        })
        // The rejected alias does not rewrite ordinary speech.
        let result = load.vocabulary.corrector.correct("ele deu um lance alto")
        #expect(result.correctedText == "ele deu um lance alto")
    }

    // MARK: AC2(b) — no-distinctive-core multi-token alias rejected by the scan

    @Test func ac2b_noDistinctiveCoreMultiTokenAliasRejected() {
        let root = tempRoot()
        // "Lighthouse | dozen labs" — both alias cores are common EN words.
        writeGlossary(glossary("Lighthouse | dozen labs"), at: root)
        let load = PipelineVocabulary.user(dataRoot: root)
        #expect(reasons(load).contains {
            if case .aliasRejectedUnsafe = $0 { return true }; return false
        })
        let result = load.vocabulary.corrector.correct("we met at dozen labs today")
        #expect(result.correctedText == "we met at dozen labs today")
    }

    // MARK: AC2(c) — safe multi-token alias admitted and corrects

    @Test func ac2c_safeMultiTokenAliasAdmittedAndCorrects() {
        let root = tempRoot()
        // "Vexatron Labs | vexatron labz" — 'vexatron' is distinctive.
        writeGlossary(glossary("Vexatron Labs | vexatron labz"), at: root)
        let load = PipelineVocabulary.user(dataRoot: root)
        #expect(load.diagnostics.aliasesAdmitted >= 1)
        let result = load.vocabulary.corrector.correct("we use vexatron labz daily")
        #expect(result.correctedText == "we use Vexatron Labs daily")
    }

    // MARK: AC2(d) — bare lexicon-member canonical limited (not rewritten, in notes)

    @Test func ac2d_limitedCanonicalNotRewrittenButInNotesVocabulary() {
        let root = tempRoot()
        // "Caco" — its only core "caco" is a PT lexicon member AND br_common_name
        // → everyday → correction-limited.
        writeGlossary(glossary("Caco"), at: root)
        let load = PipelineVocabulary.user(dataRoot: root)
        #expect(reasons(load).contains(.canonicalCorrectionLimited))
        // "caco" in lowercase prose is NOT rewritten to "Caco".
        let result = load.vocabulary.corrector.correct("ele quebrou um caco de vidro")
        #expect(result.correctedText == "ele quebrou um caco de vidro")
        // …but Caco is present in the notes-prompt canonical vocabulary block.
        #expect(load.vocabulary.canonicalTerms.contains("Caco"))
    }

    // MARK: AC2(e) — distinctive canonical corrects its diacritic variant

    @Test func ac2e_distinctiveCanonicalCorrectsDiacriticVariant() {
        let root = tempRoot()
        // "Zandi" — a name-shaped surface; to avoid any lexicon-rank ambiguity,
        // use a fully distinctive canonical with a clear diacritic variant.
        writeGlossary(glossary("Vexatrón"), at: root)
        let load = PipelineVocabulary.user(dataRoot: root)
        #expect(!reasons(load).contains(.canonicalCorrectionLimited))
        let result = load.vocabulary.corrector.correct("falamos com vexatron ontem")
        #expect(result.correctedText == "falamos com Vexatrón ontem")
    }

    // MARK: AC2(f) — a limited canonical's admitted alias still fires

    @Test func ac2f_limitedCanonicalAdmittedAliasStillFires() {
        let root = tempRoot()
        // "Caco" is limited (everyday core); "Kribble" is a distinctive alias
        // (absent from lexicons + br_common_names) that still fires.
        writeGlossary(glossary("Caco | Kribble"), at: root)
        let load = PipelineVocabulary.user(dataRoot: root)
        #expect(reasons(load).contains(.canonicalCorrectionLimited))
        #expect(load.diagnostics.aliasesAdmitted >= 1)
        // bare "caco" stays; the alias "kribble" rewrites to the canonical.
        let bare = load.vocabulary.corrector.correct("um caco de vidro")
        #expect(bare.correctedText == "um caco de vidro")
        let viaAlias = load.vocabulary.corrector.correct("o kribble chegou")
        #expect(viaAlias.correctedText == "o Caco chegou")
    }

    // MARK: §5a gate 0a — punctuation-decorated aliases (round-1 C-1)
    //
    // The admission gates fold the RAW alias surface, but the corrector keys on
    // tokenizer-PEELED cores. An alias like `caco.` / `**caco**` / `(caco)` /
    // `caco,` is not a whole-string lexicon hit, has one token, and was admitted
    // by round-1 — then the corrector stripped the punctuation and rewrote the
    // bare everyday word. Gate 0a rejects any alias whose raw surface carries
    // edge punctuation the tokenizer would peel.

    private func rejectsPunctAlias(_ alias: String, probe: String, file: StaticString = #filePath, line: UInt = #line) {
        let root = tempRoot()
        writeGlossary(glossary("Vexatron | \(alias)"), at: root)
        let load = PipelineVocabulary.user(dataRoot: root)
        // The alias is rejected with a diagnostic (never silently applied).
        #expect(reasons(load).contains {
            if case .aliasRejectedUnsafe = $0 { return true }; return false
        }, "expected aliasRejectedUnsafe for \(alias)", sourceLocation: SourceLocation(fileID: "\(file)", filePath: "\(file)", line: Int(line), column: 1))
        // The transcript is untouched — the bare word is not rewritten.
        let result = load.vocabulary.corrector.correct(probe)
        #expect(result.correctedText == probe, sourceLocation: SourceLocation(fileID: "\(file)", filePath: "\(file)", line: Int(line), column: 1))
    }

    @Test func gate0a_trailingPeriodAliasRejected() {
        rejectsPunctAlias("caco.", probe: "ele quebrou um caco de vidro")
    }

    @Test func gate0a_markdownBoldAliasRejected() {
        rejectsPunctAlias("**caco**", probe: "ele quebrou um caco de vidro")
    }

    @Test func gate0a_parenthesizedAliasRejected() {
        rejectsPunctAlias("(caco)", probe: "ele quebrou um caco de vidro")
    }

    @Test func gate0a_trailingCommaAliasRejected() {
        rejectsPunctAlias("caco,", probe: "ele quebrou um caco de vidro")
    }

    @Test func gate0a_commonNameWithPeriodAliasRejected() {
        // `maria.` — a top-band common given name behind a period; the exact
        // catastrophe class (a person's name rewritten in ordinary speech).
        rejectsPunctAlias("maria.", probe: "a maria chegou cedo")
    }

    // MARK: §5a gate 0b — punctuation-only / empty-core entries (round-1 C-2)
    //
    // A canonical or alias whose peeled core set is EMPTY (`---`, `...`) carries
    // no matchable text; round-1 registered it under the empty window key `""`
    // and fired on standalone punctuation transcript tokens ("5 - 3" → "5 ---- 3").

    @Test func gate0b_punctuationOnlyCanonicalRejected() {
        let root = tempRoot()
        writeGlossary(glossary("---"), at: root)
        let load = PipelineVocabulary.user(dataRoot: root)
        #expect(reasons(load).contains(.emptyCanonical))
        // A standalone dash transcript token is NOT a match target.
        let result = load.vocabulary.corrector.correct("o placar foi 5 - 3 ontem")
        #expect(result.correctedText == "o placar foi 5 - 3 ontem")
    }

    @Test func gate0b_punctuationOnlyAliasRejected() {
        let root = tempRoot()
        writeGlossary(glossary("Vexatron | ---"), at: root)
        let load = PipelineVocabulary.user(dataRoot: root)
        #expect(reasons(load).contains {
            if case .aliasRejectedUnsafe = $0 { return true }; return false
        })
        let result = load.vocabulary.corrector.correct("o placar foi 5 - 3 ontem")
        #expect(result.correctedText == "o placar foi 5 - 3 ontem")
    }

    // MARK: §5b — admission diagnostics carry absolute line numbers (round-1 M-1)

    @Test func admissionDiagnosticsCarryAbsoluteLineNumbers() {
        let root = tempRoot()
        // `glossary()` is `# Blaise Glossary\n\n## Entries\n<body>\n`: header
        // occupies lines 1-3, so entries begin at line 4. A rejected alias on
        // line 5, a limited canonical on line 6.
        writeGlossary(glossary("Vexatron Labs\nVexatron | lance\nCaco"), at: root)
        let load = PipelineVocabulary.user(dataRoot: root)
        let aliasItem = load.diagnostics.items.first {
            if case .aliasRejectedUnsafe = $0.reason { return true }; return false
        }
        #expect(aliasItem?.line == 5)
        let limitedItem = load.diagnostics.items.first { $0.reason == .canonicalCorrectionLimited }
        #expect(limitedItem?.line == 6)
    }

    // MARK: AC3 — lifecycle

    @Test func ac3_hotReloadBetweenLoadsWithoutRestart() {
        let root = tempRoot()
        writeGlossary(glossary("Vexatron Labs"), at: root)
        let first = PipelineVocabulary.user(dataRoot: root)
        #expect(first.vocabulary.canonicalTerms.contains("Vexatron Labs"))
        // Edit the file, reload — the new content is visible without restart.
        writeGlossary(glossary("Quoll Harbor"), at: root)
        let second = PipelineVocabulary.user(dataRoot: root)
        #expect(second.vocabulary.canonicalTerms.contains("Quoll Harbor"))
        #expect(!second.vocabulary.canonicalTerms.contains("Vexatron Labs"))
    }

    @Test func ac3_missingFileSucceedsWithFileMissing() {
        let root = tempRoot()  // no Glossary.md written
        let load = PipelineVocabulary.user(dataRoot: root)
        #expect(reasons(load).contains(.fileMissing))
        #expect(load.vocabulary.dictionary.entries.isEmpty)
        // The corrector is usable (a no-op over arbitrary text).
        #expect(load.vocabulary.corrector.correct("hello").correctedText == "hello")
    }

    @Test func ac3_injectedEntryFaultIsolatedWithEntryRejected() {
        let root = tempRoot()
        writeGlossary(glossary("Alpha\nBravo\nCharlie"), at: root)
        // Inject a build that throws ONLY when the candidate dictionary's last
        // entry is "Bravo" — isolating that single entry.
        let load = PipelineVocabulary.user(dataRoot: root, build: { dict, suppression in
            if dict.entries.last?.canonical == "Bravo" {
                throw VocabularyCorrectorError.surfaceCollision(
                    surface: "bravo", canonicalA: "Bravo", canonicalB: "X")
            }
            return try VocabularyCorrector(dictionary: dict, suppression: suppression)
        })
        #expect(reasons(load).contains {
            if case .entryRejected = $0 { return true }; return false
        })
        // Bravo dropped; Alpha + Charlie survive.
        #expect(load.vocabulary.canonicalTerms == ["Alpha", "Charlie"])
    }

    @Test func ac3_fullConstructionFaultYieldsEmptyGlossaryRejected() {
        let root = tempRoot()
        writeGlossary(glossary("Alpha\nBravo"), at: root)
        // Inject a build that throws for ANY non-empty dictionary AND even the
        // empty one — a full-construction fault.
        let load = PipelineVocabulary.user(dataRoot: root, build: { _, _ in
            throw VocabularyCorrectorError.surfaceCollision(
                surface: "x", canonicalA: "A", canonicalB: "B")
        })
        #expect(reasons(load).contains {
            if case .glossaryRejected = $0 { return true }; return false
        })
        #expect(load.vocabulary.dictionary.entries.isEmpty)
        // The run still gets a usable corrector (never-fails invariant).
        #expect(load.vocabulary.corrector.correct("anything").correctedText == "anything")
    }

    // MARK: AC4 — provisioning

    @Test func ac4_freshRootGetsTemplateByteIdentical() throws {
        let root = tempRoot()
        let wrote = GlossaryProvisioning.ensure(dataRoot: root)
        #expect(wrote)
        let written = try String(
            contentsOf: MeetingPaths(rootURL: root).glossaryURL, encoding: .utf8)
        #expect(written == GlossaryTemplate.text)
    }

    @Test func ac4_existingFileNeverOverwritten() throws {
        let root = tempRoot()
        let custom = "# my own file\n\n## Entries\nMyName\n"
        writeGlossary(custom, at: root)
        let wrote = GlossaryProvisioning.ensure(dataRoot: root)
        #expect(!wrote)
        let after = try String(
            contentsOf: MeetingPaths(rootURL: root).glossaryURL, encoding: .utf8)
        #expect(after == custom)
    }

    @Test func ac4_templateProvisionsToZeroEffectiveEntries() {
        let root = tempRoot()
        GlossaryProvisioning.ensure(dataRoot: root)
        let load = PipelineVocabulary.user(dataRoot: root)
        #expect(load.vocabulary.dictionary.entries.isEmpty)
        #expect(!reasons(load).contains(.noEntriesHeading))
    }

    @Test func templateResourceMatchesConstant() throws {
        let url = try PipelineVocabulary.glossaryTemplateURL()
        let resource = try String(contentsOf: url, encoding: .utf8)
        #expect(resource == GlossaryTemplate.text)
    }

    // MARK: §5a gate 0a — the TOTAL no-punctuation rule (round-2 C-1 / H-1)
    //
    // Gate 0a is C5's curation assertion relocated: an alias must be plain
    // matchable text — after the fold, ANY character that is not a letter, digit,
    // or single internal space rejects. This subsumes the round-1 edge-peel check
    // and additionally kills internal punctuation (interior hyphens — everyday PT
    // compounds the PT lexicon does not list) and the apostrophe carve-out
    // (possessives/quotes that rewrote ordinary speech and even deleted a quote).

    @Test func gate0a_internalHyphenEverydayCompoundRejected() {
        // `segunda-feira` — top-frequency PT compound, absent from the PT lexicon
        // as a hyphenated entry; round-2 R2-C-1 silently rewrote it.
        rejectsPunctAlias("segunda-feira", probe: "nos vemos segunda-feira de manhã")
    }

    @Test func gate0a_internalHyphenWeekendRejected() {
        rejectsPunctAlias("fim-de-semana", probe: "no fim-de-semana a gente conversa")
    }

    @Test func gate0a_followUpEnglishHyphenRejected() {
        rejectsPunctAlias("follow-up", probe: "let's schedule a follow-up next week")
    }

    @Test func gate0a_apostrophePossessiveRejected() {
        // `cat's` / `maria's` — the apostrophe carve-out admitted these in round-2
        // (R2-H-1) and they rewrote ordinary speech; now rejected.
        rejectsPunctAlias("cat's", probe: "the cat's bowl is full")
        rejectsPunctAlias("maria's", probe: "we went to maria's house")
    }

    @Test func gate0a_trailingApostropheRejected() {
        // `caco'` — the closing curly quote was consumed (text DELETION) in
        // round-2; the apostrophe-bearing alias now rejects outright.
        rejectsPunctAlias("caco'", probe: "ele disse \u{2018}caco\u{2019} ontem")
    }

    @Test func gate0a_curlyQuotePairRejected() {
        rejectsPunctAlias("\u{201C}caco\u{201D}", probe: "ele quebrou um caco de vidro")
    }

    // MARK: §5a gate 3 — canonical punctuation / empty-core → correction-limited
    //
    // A canonical whose folded surface carries disallowed punctuation, or any of
    // whose tokens peels to an empty core, is excluded from corrector
    // registration (it stays in canonicalTerms for notes) — otherwise the raw
    // canonical string was replaced into every transcript hit, injecting
    // markdown/punctuation/diacritics, and an empty-core token fired on a
    // standalone dash (round-2 R2-H-2 / R2-M-1).

    /// A correction-limited canonical leaves the probe transcript untouched and
    /// carries the `canonicalCorrectionLimited` diagnostic, while still appearing
    /// in the notes canonical vocabulary.
    private func limitsCanonical(_ canonical: String, probe: String, notesTerm: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let root = tempRoot()
        writeGlossary(glossary(canonical), at: root)
        let load = PipelineVocabulary.user(dataRoot: root)
        let loc = SourceLocation(fileID: "\(file)", filePath: "\(file)", line: Int(line), column: 1)
        #expect(reasons(load).contains(.canonicalCorrectionLimited), sourceLocation: loc)
        let result = load.vocabulary.corrector.correct(probe)
        #expect(result.correctedText == probe, sourceLocation: loc)
        #expect(load.vocabulary.canonicalTerms.contains(notesTerm), sourceLocation: loc)
    }

    @Test func gate3_markdownBoldCanonicalLimited() {
        // `**Vexatron**` — distinctive core, but markdown decoration would inject
        // `**Vexatron**` into every hit. Limited, not rewritten.
        limitsCanonical("**Vexatron**", probe: "o vexatron chegou cedo", notesTerm: "**Vexatron**")
    }

    @Test func gate3_specExampleNamePlusPunctTokenLimited() {
        // §5a.3's own "Maria Silva" example, defeated in round-2 by a trailing
        // `-` token whose empty core slipped the gate-3 allSatisfy.
        limitsCanonical("Maria Silva -", probe: "a maria silva - disse ela", notesTerm: "Maria Silva -")
    }

    @Test func gate3_diacriticInjectionViaPunctTokenLimited() {
        // `Está -` — the `-` empty-core token let `esta`→`está` (a meaning change)
        // through. Now limited.
        limitsCanonical("Está -", probe: "esta - coisa funciona", notesTerm: "Está -")
    }

    @Test func gate3_decoratedEverydayCanonicalPlusPunctTokenLimited() {
        // `Caco. -` — period injection mid-sentence in round-2.
        limitsCanonical("Caco. -", probe: "ele disse caco - depois saiu", notesTerm: "Caco. -")
    }

    @Test func gate3_plainDecoratedEverydayCanonicalStillLimited() {
        // Control: plain `Caco.` (no extra token) — gate 3 already limited it via
        // the everyday core; the punctuation rule keeps it limited too.
        limitsCanonical("Caco.", probe: "ele quebrou um caco de vidro", notesTerm: "Caco.")
    }

    // MARK: §6 — rejected-alias attribution across n≥3 shared-alias entries
    // (round-2 R2-L-3). Distinctive canonicals so correction-limitation adds no
    // annotation noise; the editor supplies row source lines for exact mapping.

    @Test func rejectedAliasAttributesToOwningRowAcrossThreeEntries() {
        let root = tempRoot()
        let body = "Vexatron | zorblax\nQuoll | zorblax\nKribblon | zorblax"
        writeGlossary(glossary(body), at: root)
        let load = PipelineVocabulary.user(dataRoot: root)
        let text = (try? String(contentsOf: MeetingPaths(rootURL: root).glossaryURL, encoding: .utf8)) ?? ""
        let editor = GlossaryEditor(fileText: text)
        let ann = GlossaryEditor.annotations(
            from: load.diagnostics, rows: editor.rows, rowSourceLines: editor.rowSourceLines)
        // Vexatron's zorblax is admitted (first); Quoll's and Kribblon's collide
        // and each rejection annotates ITS OWN row — not all on the last owner.
        #expect(ann["vexatron"] == nil)
        #expect(ann["quoll"]?.contains("zorblax") == true)
        #expect(ann["kribblon"]?.contains("zorblax") == true)
    }
}
