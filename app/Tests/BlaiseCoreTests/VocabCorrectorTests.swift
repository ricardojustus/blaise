import Foundation
import Testing
@testable import BlaiseCore

/// C5 AC1/AC2/AC3 — corrector behavior on the real derived dictionary + stoplists.
@Suite struct VocabCorrectorTests {
    private var corrector: VocabularyCorrector { VocabFixtures.corrector }

    private func assertUntouched(_ text: String, _ note: Comment? = nil) {
        let result = corrector.correct(text)
        #expect(result.correctedText == text, note)
        #expect(result.corrections.isEmpty, note)
    }

    // MARK: FP regression table (AC1 — self-contained, complete)

    @Test func falsePositiveRegressionTable() {
        // 29 spec-pinned words/phrases, each in a PT sentence: ZERO corrections,
        // byte-identical output.
        let sentences: [(String, String)] = [
            ("acha", "Ela acha que vai dar certo."),
            ("achar", "Vou achar um horário amanhã."),
            ("teve", "O time teve uma semana difícil."),
            ("hora", "Já passou da hora de decidir."),
            ("banco", "O banco aprovou o contrato."),
            ("branco", "O documento ficou em branco."),
            ("mesa", "Deixei o contrato na mesa."),
            ("metade", "Só usamos metade do orçamento."),
            ("terça", "A reunião ficou para terça."),
            ("desde", "Estamos nisso desde janeiro."),
            ("liga", "Ele liga todo dia cedo."),
            ("fábrica", "A fábrica fecha em dezembro."),
            ("França", "Ela viajou para a França ontem."),
            ("cloud", "Subimos tudo para o cloud ontem."),
            ("exception", "O código lançou uma exception nova."),
            ("projeto", "O projeto muda na semana que vem."),
            ("Renato", "O Renato revisou o documento."),
            ("Patrícia", "A Patrícia chega amanhã cedo."),
            ("Fábio", "O Fábio respondeu o e-mail."),
            ("Mateus", "O Mateus ficou de avisar depois."),
            ("teto", "O valor bateu no teto previsto."),
            ("Roberta", "A Roberta assume na segunda."),
            ("Tomás", "O Tomás prefere outro formato."),
            ("Tomas", "O Tomas confirmou presença."),
            ("vela", "Acendemos uma vela no jantar."),
            ("barco", "O barco saiu do porto cedo."),
            ("maré", "A maré subiu mais que o previsto."),
            ("ponte", "Atravessamos a ponte velha ontem."),
            ("leme", "Ele assumiu o leme do projeto."),
        ]
        #expect(sentences.count == 29)
        for (word, sentence) in sentences {
            #expect(sentence.localizedCaseInsensitiveContains(word), "sentence must embed '\(word)'")
            assertUntouched(sentence, "FP regression: \(word)")
        }
    }

    // MARK: Exact stage

    @Test func exactRestoresDistinctiveNames() {
        let petball = corrector.correct("vou jogar petball hoje")
        #expect(petball.correctedText == "vou jogar Petball hoje")
        #expect(petball.corrections.map(\.stage) == [.exact])
        let cerebros = corrector.correct("a cerebros assume o contrato")
        #expect(cerebros.correctedText == "a Cerebros assume o contrato")
        #expect(cerebros.corrections.first?.original == "cerebros")
        #expect(cerebros.corrections.first?.canonical == "Cerebros")
    }

    @Test func suppressionLeavesStopListedCasingAlone() {
        // The project codenames are everyday PT words (suppressed): an ordinary
        // occurrence is never rewritten, whatever its casing.
        assertUntouched("a maré estava forte demais")
        assertUntouched("acendemos uma vela no altar")
        assertUntouched("o barco encostou no cais")
        assertUntouched("a ponte velha caiu na enchente")
        // Suppressed even when the surface is capitalized at the sentence start.
        assertUntouched("Pedra rolou morro abaixo")
    }

    @Test func multiTokenAllStopWindowsUntouched() throws {
        // M-6: a fully-suppressible multi-token entry — every core in the
        // suppression set — never fires, whatever the diff. The shipped synthetic
        // dictionary has no all-stop entry (every curated name carries a
        // distinctive core), so this builds one directly from two nautical
        // project codewords that ARE both suppressed.
        let dict = VocabularyDictionary(entries: [VocabularyEntry(canonical: "Vela Barco")])
        let suppressed = try VocabularyCorrector(
            dictionary: dict, suppression: ["vela", "barco"])
        let lower = suppressed.correct("soltamos a vela barco no porto")
        #expect(lower.correctedText == "soltamos a vela barco no porto")
        #expect(lower.corrections.isEmpty)
        // Even a case-only diff stays suppressed (no title-casing injected).
        let cased = suppressed.correct("soltamos a Vela barco no porto")
        #expect(cased.correctedText == "soltamos a Vela barco no porto")
        #expect(cased.corrections.isEmpty)
    }

    @Test func mixedWindowFires() {
        // "Lance Quoll": "lance" is a stop core (pt top-3000) but "quoll" is
        // distinctive, so the canonical window is NOT fully-suppressible — it
        // fires via the exact stage.
        let result = corrector.correct("trouxe o lance quoll para testar")
        #expect(result.correctedText == "trouxe o Lance Quoll para testar")
        #expect(result.corrections.count == 1)
        #expect(result.corrections.first?.original == "lance quoll")
        #expect(result.corrections.first?.stage == .exact)
    }

    @Test func interiorPunctuationExceptionFires() {
        let result = corrector.correct("o a.j. stone confirmou a fala")
        #expect(result.correctedText == "o A.J. Stone confirmou a fala")
        #expect(result.corrections.first?.original == "a.j. stone")
    }

    @Test func curlyApostropheMatchesStraightCanonical() {
        let result = corrector.correct("o frank d\u{2019}avlin aprovou a arte")
        #expect(result.correctedText == "o Frank D'avlin aprovou a arte")
    }

    @Test func levelBFlipCodenamesSuppressed() {
        // Level-B flip put the nautical codewords proa/leme/ponte in
        // stoplist_project: a project name that collides with these everyday PT
        // words is suppressed, delegated to C6 — ordinary speech is untouched.
        assertUntouched("a proa do barco quebrou na tempestade")
        assertUntouched("ele perdeu o leme no meio do caminho")
        assertUntouched("atravessamos a ponte de pedra ao amanhecer")
        // The correctly-spelled title self-matches (emits nothing); the colon and
        // subtitle that follow the 2-token canonical stay untouched.
        assertUntouched("Aurora Tales: The Last Confession estreia em breve")
    }

    @Test func subtitleAliasResolvesWithoutInjectingTitleColon() {
        // M-1 regression: the colon-bearing subtitle is a curated ALIAS of the
        // base title "Aurora Tales". When the colon is absent in speech, the
        // alias fires to the colon-free canonical — it must NEVER inject the
        // title colon into ordinary speech.
        let result = corrector.correct("a gente jogou aurora tales the last confession ontem")
        #expect(result.correctedText == "a gente jogou Aurora Tales ontem")
        #expect(!result.correctedText.contains(":"))
        #expect(result.corrections.map(\.stage) == [.alias])
    }

    @Test func selfMatchesEmitNothing() {
        // Correctly-spelled canonicals self-match: the window is consumed but no
        // correction is emitted.
        assertUntouched("a Petball segue firme")
        assertUntouched("o Marco Vidal respondeu")
    }

    // MARK: Alias stage

    @Test func teloAliasFiresInRealClause() {
        // A curated mishearing alias fires in a clause: "Tobes" → "Toban Vane".
        let result = corrector.correct("Eu acho que os recados estão dados. Eu concordo com o Tobes")
        #expect(result.correctedText == "Eu acho que os recados estão dados. Eu concordo com o Toban Vane")
        #expect(result.corrections.map(\.stage) == [.alias])
        #expect(result.corrections.first?.original == "Tobes")
    }

    @Test func accentedTeloDoesNotMatchDiacriticExactAlias() {
        // Alias mode is diacritic-EXACT: "Tóbes" (accented surname shape) stays.
        assertUntouched("o show do Tóbes lotou")
    }

    @Test func spacedCompoundAliasesFire() {
        // The planted spaced mishearing of the studio location.
        let harbour = corrector.correct("a equipe foi pra Quol Harbour, antes do offsite")
        #expect(harbour.correctedText == "a equipe foi pra Quoll Harbour, antes do offsite")
        #expect(harbour.corrections.map(\.stage) == [.alias])
        // A curated brand compound resolves to its base canonical.
        let nexus = corrector.correct("a versão de Nexus Quest vem depois")
        #expect(nexus.correctedText == "a versão de Nexus vem depois")
        #expect(nexus.corrections.map(\.stage) == [.alias])
    }

    @Test func aliasWindowsRequirePlainValidity() {
        // Interior punctuation breaks alias windows (no entry-punctuation exception):
        // the "." after "quol" splits the "Quol Harbour" window, so it cannot fire.
        assertUntouched("salvei o quol. harbour chegou depois")
    }

    // MARK: Window mechanics

    @Test func suppressedWindowAdvancesOneToken() {
        // M-2: a suppressed/pass-through first token does not consume its
        // successor — the second token still starts a new match.
        let result = corrector.correct("pedra cerebros")
        #expect(result.correctedText == "pedra Cerebros")
        #expect(result.corrections.count == 1)
        #expect(result.corrections.first?.original == "cerebros")
    }

    @Test func punctuatedWindowNotMerged() {
        // "Lance. Quoll" must not merge into "Lance Quoll" across the sentence break.
        assertUntouched("usamos a Lance. Quoll é outra conversa")
    }

    @Test func windowsNeverSpanLineBreaks() {
        // M-2 regression: ASR output breaks lines mid-sentence; a window across
        // "\n" must not match (firing would merge the lines). Both stages.
        assertUntouched("a lance\nquoll chegou")
        assertUntouched("alinhar o Quol\nHarbour amanhã")
    }

    @Test func droppedCommonWordCompoundAliasesStayUntouched() {
        // H-1 regression: "Dozen Labs" and "Apex Game" were rejected by the
        // alias-core scan (all cores lexicon-common) — the ordinary-speech bigrams
        // must stay untouched.
        assertUntouched("the university has dozen labs downtown")
        assertUntouched("they played an apex game last night")
    }

    @Test func correctionRangesSliceOriginal() {
        let text = "o petball e o Tobes, toparam"
        let result = corrector.correct(text)
        #expect(result.corrections.count == 2)
        for correction in result.corrections {
            #expect(String(text[correction.range]) == correction.original)
        }
        // Reconstructing from ranges in ORIGINAL coordinates reproduces the output.
        var rebuilt = ""
        var cursor = text.startIndex
        for correction in result.corrections {
            rebuilt += text[cursor ..< correction.range.lowerBound] + correction.canonical
            cursor = correction.range.upperBound
        }
        rebuilt += text[cursor...]
        #expect(rebuilt == result.correctedText)
        #expect(result.correctedText == "o Petball e o Toban Vane, toparam")
        #expect(result.corrections.map(\.stage) == [.exact, .alias])
    }

    @Test func collisionAssertionDefendsAtLoad() {
        let colliding = VocabularyDictionary(entries: [
            VocabularyEntry(canonical: "Nira"),
            VocabularyEntry(canonical: "Elena Marquez", aliases: ["Nira"]),
        ])
        #expect(throws: VocabularyCorrectorError.self) {
            try VocabularyCorrector(dictionary: colliding, suppression: [])
        }
    }

    // MARK: AC2 — golden fixture

    @Test func goldenClauses() {
        for clause in VocabFixtures.goldenClauses {
            let result = corrector.correct(clause.input)
            #expect(result.correctedText == clause.expected, "golden: \(clause.source)")
            if clause.input == clause.expected {
                #expect(result.corrections.isEmpty, "byte-identical clause emitted corrections: \(clause.source)")
            } else {
                #expect(!result.corrections.isEmpty, "correcting clause emitted nothing: \(clause.source)")
            }
        }
    }

    @Test func idempotenceOverGoldenCorpus() {
        // Property: correct(correct(x)) == correct(x), per clause and concatenated.
        var corpus = VocabFixtures.goldenClauses.map(\.input)
        corpus.append(corpus.joined(separator: "\n"))
        for input in corpus {
            let once = corrector.correct(input)
            let twice = corrector.correct(once.correctedText)
            #expect(twice.correctedText == once.correctedText)
            #expect(twice.corrections.isEmpty)
        }
    }

    // MARK: Real-transcript corpus (the audit's strongest FP check, permanent)

    @Test(.disabled("mint-pending: reads the maintainer-local real ASR output with the pre-scrub allowed-set; re-derive against the synthetic corpus")) func realTranscriptCorpusYieldsOnlyKnownCorrections() throws {
        // The directory holds the meeting sample's engine outputs — local
        // research artifacts referenced by path; skip when absent.
        let outDir = RegressionPin.asrOutDir
        guard FileManager.default.fileExists(atPath: outDir.path) else {
            print("skip realTranscriptCorpusYieldsOnlyKnownCorrections: real ASR output dir absent (maintainer-local artifacts not in this checkout)")
            return
        }
        let files = try FileManager.default
            .contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil)
            .flatMap { dir in
                (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            }
            .filter { $0.lastPathComponent.hasPrefix("seg_") && $0.pathExtension == "txt" }
            .sorted { $0.path < $1.path }
        try #require(files.count >= 14, "expected the full engine-output corpus")
        // The complete known-correct set over the corpus: case restores of a partner acronym,
        // the evidenced Tobes→Toban alias, and qwen3's lowercase-output restores.
        let allowed: Set<[String]> = [
            ["cci", "CCI"],
            ["Tobes", "Toban"],
            ["anna reyes", "Anna Reyes"],
            ["leo", "Leo"],
        ]
        var sawCorrection = false
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let result = corrector.correct(text)
            var rebuilt = ""
            var cursor = text.startIndex
            for correction in result.corrections {
                sawCorrection = true
                let pair = [VocabNormalization.canonicalMode(correction.original), correction.canonical]
                #expect(allowed.contains(pair),
                        "unexpected correction in \(file.lastPathComponent): '\(correction.original)' → '\(correction.canonical)'")
                #expect(String(text[correction.range]) == correction.original)
                // Splice reconstruction: byte-identity outside correction ranges.
                rebuilt += text[cursor ..< correction.range.lowerBound] + correction.canonical
                cursor = correction.range.upperBound
            }
            rebuilt += text[cursor...]
            #expect(rebuilt == result.correctedText, "splice mismatch: \(file.lastPathComponent)")
            // Idempotence on real data.
            let twice = corrector.correct(result.correctedText)
            #expect(twice.correctedText == result.correctedText, "not idempotent: \(file.lastPathComponent)")
            #expect(twice.corrections.isEmpty, "second pass corrected: \(file.lastPathComponent)")
        }
        #expect(sawCorrection, "the corpus must exercise the known-correct set")
    }

    // MARK: §5a gate 0b defense-in-depth — the corrector's register guard
    //
    // R2-L-2: the loader gate 0b intercepts every empty-core surface, so the
    // corrector's `register` guard (which refuses a surface whose tokens all peel
    // to empty cores) was unverified. These build the corrector DIRECTLY from a
    // dictionary holding such a surface — the loader's gate is bypassed, so only
    // the register guard prevents the empty window key `""` from registering and
    // firing on a standalone punctuation transcript token. Neutering the guard
    // (removing the `guard surfaceTokens.contains(where:) else { return }` line)
    // fails these.

    @Test func registerGuardRefusesAnAllPunctuationCanonical() throws {
        // `---` direct into the dictionary, no loader admission.
        let dict = VocabularyDictionary(entries: [VocabularyEntry(canonical: "---")])
        let corrector = try VocabularyCorrector(dictionary: dict, suppression: [])
        // A standalone dash transcript token must NOT be a match target.
        let result = corrector.correct("o placar foi 5 - 3 ontem")
        #expect(result.correctedText == "o placar foi 5 - 3 ontem")
        #expect(result.corrections.isEmpty)
    }

    @Test func registerGuardRefusesAnAllPunctuationAlias() throws {
        // Distinctive canonical with an all-punctuation alias `...` direct into
        // the dictionary; the alias must not register under the empty key.
        let dict = VocabularyDictionary(entries: [
            VocabularyEntry(canonical: "Vexatron", aliases: ["..."]),
        ])
        let corrector = try VocabularyCorrector(dictionary: dict, suppression: [])
        let result = corrector.correct("o placar foi 5 ... 3 ontem")
        #expect(result.correctedText == "o placar foi 5 ... 3 ontem")
        #expect(result.corrections.isEmpty)
    }

    // MARK: AC3 — performance

    @Test func ninethousandTokenInputUnderFiveSeconds() {
        let base = VocabFixtures.goldenClauses.map(\.input).joined(separator: " ")
        var text = base
        while text.split(whereSeparator: \.isWhitespace).count < 9_000 {
            text += " " + base
        }
        let tokenCount = text.split(whereSeparator: \.isWhitespace).count
        #expect(tokenCount >= 9_000)
        let clock = ContinuousClock()
        var result: CorrectionResult?
        let duration = clock.measure { result = corrector.correct(text) }
        #expect(duration < .seconds(5), "took \(duration) for \(tokenCount) tokens")
        #expect((result?.corrections.count ?? 0) > 0)
    }
}
