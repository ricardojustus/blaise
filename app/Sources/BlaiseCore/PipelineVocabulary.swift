import Foundation
import os

/// The C5 vocabulary stack as the pipeline consumes it: dictionary,
/// corrector, effective suppression set, BR common names, and the canonical
/// term list for engine prompts/hints.
///
/// G1: the runtime stack is built per pipeline run from the per-user glossary
/// (`PipelineVocabulary.user(dataRoot:)`), or — for regression/pin/test paths —
/// from `fixtures/synthetic_vocab.txt` via `fixture()` (raw parse, byte-preserving
/// every pinned behavior). The shared stoplist lexicons stay bundled.
public struct PipelineVocabulary: Sendable {
    public let dictionary: VocabularyDictionary
    public let corrector: VocabularyCorrector
    public let suppression: Set<String>
    public let commonNames: Set<String>

    /// Canonical spellings, in dictionary order (NotesRequest.vocabulary).
    public var canonicalTerms: [String] { dictionary.entries.map(\.canonical) }

    public init(
        dictionary: VocabularyDictionary,
        suppression: Set<String>,
        commonNames: Set<String>
    ) throws {
        self.dictionary = dictionary
        self.corrector = try VocabularyCorrector(dictionary: dictionary, suppression: suppression)
        self.suppression = suppression
        self.commonNames = commonNames
    }

    /// Direct-corrector initializer (used by the isolated loader, which builds
    /// the corrector through its injectable seam).
    init(
        dictionary: VocabularyDictionary,
        corrector: VocabularyCorrector,
        suppression: Set<String>,
        commonNames: Set<String>
    ) {
        self.dictionary = dictionary
        self.corrector = corrector
        self.suppression = suppression
        self.commonNames = commonNames
    }

    public enum LoadError: Error {
        case missingResource(String)
    }

    /// Bundled resource URL, by fixture name.
    public static func bundledResource(_ name: String) throws -> URL {
        let parts = (name as NSString).lastPathComponent.split(separator: ".")
        guard
            parts.count == 2,
            let url = BlaiseResources.bundle.url(forResource: String(parts[0]), withExtension: String(parts[1]))
        else {
            throw LoadError.missingResource(name)
        }
        return url
    }

    /// The bundled glossary template (`Resources/glossary_template.md`, G1 §2).
    public static func glossaryTemplateURL() throws -> URL {
        try bundledResource("glossary_template.md")
    }

    // MARK: - Shared lexicons (bundled; loaded once per process)

    /// The C5 lexicons gates 1–3 consume, loaded once per process (§5a perf).
    struct Lexicons: Sendable {
        let pt: FrequencyList
        let en: FrequencyList
        let project: Set<String>
        let exclusions: Set<String>
        let commonNames: Set<String>

        var suppressionBase: Set<String> {
            SuppressionSet.effective(pt: pt, en: en, project: project, exclusions: exclusions)
        }
    }

    private static let lexiconCache = OSAllocatedUnfairLock<Lexicons?>(initialState: nil)

    static func sharedLexicons() throws -> Lexicons {
        try lexiconCache.withLock { cached in
            if let cached { return cached }
            let lexicons = Lexicons(
                pt: try FrequencyList(contentsOf: bundledResource("stoplist_pt.txt")),
                en: try FrequencyList(contentsOf: bundledResource("stoplist_en.txt")),
                project: try VocabWordList.parse(contentsOf: bundledResource("stoplist_user.txt")),
                exclusions: try VocabWordList.parse(contentsOf: bundledResource("stoplist_exclusions.txt")),
                commonNames: try VocabWordList.parse(contentsOf: bundledResource("br_common_names.txt")))
            cached = lexicons
            return lexicons
        }
    }

    // MARK: - fixture() — regression/pin/test path (byte-preserving)

    /// Raw parse of `fixtures/synthetic_vocab.txt` with the suppression set wired
    /// exactly as the former `bundled()` did — NO region extraction, NO
    /// admission. Every pinned behavior is byte-preserved (AC7). `vocabURL`
    /// resolves via the test target's `#filePath` fixtures convention (and
    /// CrashRunner's repo-relative path); suppression/common-names come from the
    /// still-bundled stoplist lexicons.
    ///
    /// `additionalSuppression` is unioned on top of the bundled suppression base
    /// — the production default is empty (the bundled `stoplist_user.txt` ships
    /// empty), but the regression harness passes the pinned project-stoplist
    /// terms so the byte-pinned suppression set is reproduced after the split.
    public static func fixture(
        vocabURL: URL, additionalSuppression: Set<String> = []
    ) throws -> PipelineVocabulary {
        let lexicons = try sharedLexicons()
        let dictionary = try VocabularyDictionary.parse(contentsOf: vocabURL)
        return try PipelineVocabulary(
            dictionary: dictionary,
            suppression: lexicons.suppressionBase.union(additionalSuppression),
            commonNames: lexicons.commonNames)
    }

    // MARK: - user() — per-run load of the user glossary (§3)

    /// Result of a user-glossary load: the runtime stack plus its diagnostics
    /// and source. THE GLOSSARY NEVER FAILS A PIPELINE RUN (§3) — `user`
    /// always returns a usable `vocabulary`, empty in the worst case.
    public struct UserLoad: Sendable {
        public let vocabulary: PipelineVocabulary
        public let diagnostics: GlossaryDiagnostics
        public let loadedAt: Date
    }

    /// Per-run load (§3): read → region-extract → parse → admission (§5a) →
    /// dictionary + suppression set. Called at EACH pipeline run start.
    ///
    /// `build` is the injectable dictionary-construction seam (§3, AC3): it
    /// constructs the corrector from a candidate dictionary + suppression set,
    /// throwing on an entry whose insertion is unsafe. The loader isolates
    /// per-entry faults by building incrementally; a fault that survives even
    /// an empty dictionary degrades to an empty vocabulary + `glossaryRejected`.
    public static func user(
        dataRoot: URL,
        now: @Sendable () -> Date = { Date() },
        build: (VocabularyDictionary, Set<String>) throws -> VocabularyCorrector = {
            try VocabularyCorrector(dictionary: $0, suppression: $1)
        }
    ) -> UserLoad {
        let lexicons: Lexicons
        do {
            lexicons = try sharedLexicons()
        } catch {
            // The bundled lexicons are a build invariant; if they cannot load,
            // run with an empty vocabulary rather than failing the run.
            return emptyLoad(diagnostics: rejectedDiagnostics(error), now: now)
        }
        // The bundled `stoplist_user.txt` ships EMPTY; an install may add its own
        // project/team terms at `<dataRoot>/stoplist_user.txt`, unioned on top of
        // the bundled frequency-based suppression base (absent on a fresh install,
        // where the per-glossary augmentation below is the only supplement).
        let userStoplistURL = MeetingPaths(rootURL: dataRoot).userStoplistURL
        let dataRootStops = (try? VocabWordList.parse(contentsOf: userStoplistURL)) ?? []
        let suppressionBase = lexicons.suppressionBase.union(dataRootStops)

        let glossaryURL = MeetingPaths(rootURL: dataRoot).glossaryURL
        let raw: String
        do {
            raw = try String(contentsOf: glossaryURL, encoding: .utf8)
        } catch {
            var diagnostics = GlossaryDiagnostics()
            if !FileManager.default.fileExists(atPath: glossaryURL.path) {
                diagnostics.addFile(.fileMissing)
            } else {
                diagnostics.addFile(.fileUnreadable)
            }
            return emptyLoad(suppression: suppressionBase, commonNames: lexicons.commonNames,
                             diagnostics: diagnostics, now: now, build: build)
        }

        let (entries, entryLines, parsedDiagnostics) = GlossaryParser.parseRegion(GlossaryParser.extractRegion(raw))
        var diagnostics = parsedDiagnostics

        // §5a admission: gates 0a/0b (punctuation / empty-core safety), 1–2
        // (alias) field-wise, gate 3 (canonical) sets the suppression
        // augmentation. Surfaces map is the running collision input (admitted
        // surfaces only). Diagnostics carry the entry's absolute source line
        // (M-1, §5b) via the index-aligned `entryLines`.
        var admitted: [(entry: VocabularyEntry, line: Int)] = []
        var surfaces: [String: String] = [:]
        var suppressionAugment: Set<String> = []
        var aliasesAdmitted = 0
        var canonicalsLimited = 0

        for (entry, line) in zip(entries, entryLines) {
            let folded = VocabNormalization.canonicalMode(entry.canonical)

            // Gate 0b (canonical): a canonical whose peeled core set is EMPTY
            // (e.g. `---`, `...`) carries no matchable text — it would register
            // under the empty window key and fire on standalone punctuation
            // tokens. The whole entry is rejected (its aliases have no canonical
            // to map to). C-2.
            if AliasCoreScan.hasEmptyPeeledCores(entry.canonical) {
                diagnostics.add(GlossaryDiagnosticItem(
                    line: line, prefix: entry.canonical,
                    reason: .emptyCanonical))
                continue
            }

            // Gate 1+2 (+0a/0b for aliases): each alias through the punctuation
            // and empty-core gates, then AliasAdmission, then the alias-core
            // scan; rejected → field-wise drop with aliasRejectedUnsafe.
            var keptAliases: [String] = []
            for alias in entry.aliases {
                // Gate 0b (alias): empty peeled cores — no matchable text. C-2.
                if AliasCoreScan.hasEmptyPeeledCores(alias) {
                    diagnostics.add(GlossaryDiagnosticItem(
                        line: line, prefix: alias,
                        reason: .aliasRejectedUnsafe(reason: "no matchable text — alias is punctuation only")))
                    continue
                }
                // Gate 0a (alias): the TOTAL no-punctuation rule — C5's curation
                // assertion relocated verbatim. An alias must be plain matchable
                // text; after the fold, ANY character that is not a letter, digit,
                // or single internal space rejects (trailing periods, markdown,
                // apostrophes/quotes straight or curly, interior hyphens like
                // `segunda-feira`, fullwidth/zero-width forms). The corrector keys
                // on PEELED cores, so any of these could slip a bare everyday word
                // past a lexicon gate that inspected a different string. C-1 /
                // R2-C-1 / R2-H-1.
                if AliasCoreScan.carriesDisallowedPunctuation(alias) {
                    diagnostics.add(GlossaryDiagnosticItem(
                        line: line, prefix: alias,
                        reason: .aliasRejectedUnsafe(reason: "alias carries punctuation — only plain letters, digits, and single spaces are allowed (hyphenate-free)")))
                    continue
                }
                let verdict = AliasAdmission.evaluate(
                    alias: alias,
                    canonical: entry.canonical,
                    ptLexicon: lexicons.pt,
                    enLexicon: lexicons.en,
                    brCommonNames: lexicons.commonNames,
                    existingSurfaces: surfaces)
                if case .rejected(let rejection) = verdict {
                    diagnostics.add(GlossaryDiagnosticItem(
                        line: line, prefix: alias, reason: .aliasRejectedUnsafe(reason: rejectionText(rejection))))
                    continue
                }
                if AliasCoreScan.hasNoDistinctiveCore(alias, pt: lexicons.pt, en: lexicons.en) {
                    diagnostics.add(GlossaryDiagnosticItem(
                        line: line, prefix: alias,
                        reason: .aliasRejectedUnsafe(reason: "multi-token alias has no distinctive core — would rewrite ordinary speech")))
                    continue
                }
                // Belt-and-braces (§5a): gates 1–2 also run against the PEELED
                // representation, so no representation mismatch can recur. The
                // peeled cores are the corrector's actual match key; gate-0a
                // already rejects punctuation, so this normally equals the raw
                // alias — but it closes any residual peel that gate 0a misses.
                let peeled = AliasCoreScan.peeledCores(alias).joined(separator: " ")
                if peeled != VocabNormalization.canonicalMode(alias) {
                    let peeledVerdict = AliasAdmission.evaluate(
                        alias: peeled,
                        canonical: entry.canonical,
                        ptLexicon: lexicons.pt,
                        enLexicon: lexicons.en,
                        brCommonNames: lexicons.commonNames,
                        existingSurfaces: surfaces)
                    if case .rejected = peeledVerdict {
                        diagnostics.add(GlossaryDiagnosticItem(
                            line: line, prefix: alias,
                            reason: .aliasRejectedUnsafe(reason: "alias reduces to an everyday word after punctuation is stripped")))
                        continue
                    }
                    if AliasCoreScan.hasNoDistinctiveCore(peeled, pt: lexicons.pt, en: lexicons.en) {
                        diagnostics.add(GlossaryDiagnosticItem(
                            line: line, prefix: alias,
                            reason: .aliasRejectedUnsafe(reason: "alias has no distinctive core after punctuation is stripped")))
                        continue
                    }
                }
                let aliasFold = VocabNormalization.canonicalMode(alias)
                surfaces[aliasFold] = entry.canonical
                keptAliases.append(alias)
                aliasesAdmitted += 1
            }

            // Gate 3: canonical correction-limitation scan. A canonical is
            // correction-LIMITED — kept in `canonicalTerms` for note spelling but
            // excluded from corrector registration (its non-empty cores join the
            // suppression set; admitted aliases still fire) — when EITHER:
            //   (a) every NON-EMPTY core is everyday (the original §5a.3 rule); OR
            //   (b) its folded surface carries disallowed punctuation
            //       (`**Vexatron**`), or any token peels to an empty core
            //       (`Maria Silva -`, `Marsa. -`, `Está -`). Without (b) the raw
            //       canonical string is replaced into every transcript hit,
            //       injecting markdown/punctuation/diacritics into ordinary speech
            //       and (via the empty-core token) firing on a standalone dash.
            //       R2-H-2 / R2-M-1.
            // Empty cores are dropped before the everyday test (an empty core is
            // never "everyday", so a stray punctuation token must not defeat the
            // limitation — the structural hole behind R2-H-2).
            let cores = AliasCoreScan.peeledCores(entry.canonical)
            let punctuationLimited =
                AliasCoreScan.carriesDisallowedPunctuation(entry.canonical)
                || AliasCoreScan.hasAnyEmptyPeeledCore(entry.canonical)
            let everydayLimited = !cores.isEmpty && cores.allSatisfy { isEveryday($0, lexicons: lexicons) }
            if punctuationLimited || everydayLimited {
                suppressionAugment.formUnion(cores)
                canonicalsLimited += 1
                diagnostics.add(GlossaryDiagnosticItem(
                    line: line, prefix: entry.canonical, reason: .canonicalCorrectionLimited))
            }

            surfaces[folded] = entry.canonical
            admitted.append((VocabularyEntry(canonical: entry.canonical, aliases: keptAliases), line))
        }

        let suppression = suppressionBase.union(suppressionAugment)

        // Isolated dictionary construction (§3): build incrementally so a single
        // unsafe entry is dropped (entryRejected) and the rest survive.
        var accepted: [VocabularyEntry] = []
        for (entry, line) in admitted {
            let candidate = VocabularyDictionary(entries: accepted + [entry])
            do {
                _ = try build(candidate, suppression)
                accepted.append(entry)
            } catch {
                diagnostics.add(GlossaryDiagnosticItem(
                    line: line, prefix: entry.canonical,
                    reason: .entryRejected(reason: faultText(error))))
            }
        }

        let finalDictionary = VocabularyDictionary(entries: accepted)
        let corrector: VocabularyCorrector
        do {
            corrector = try build(finalDictionary, suppression)
        } catch {
            // Construction failed outright despite per-entry isolation: run with
            // an empty vocabulary + glossaryRejected (the never-fails invariant).
            diagnostics.addFile(.glossaryRejected(reason: faultText(error)))
            return emptyLoad(suppression: suppressionBase, commonNames: lexicons.commonNames,
                             diagnostics: diagnostics, now: now, build: build)
        }

        diagnostics.parsedEntries = entries.count
        diagnostics.effectiveEntries = accepted.count
        diagnostics.aliasesAdmitted = aliasesAdmitted
        diagnostics.canonicalsLimited = canonicalsLimited

        let vocabulary = PipelineVocabulary(
            dictionary: finalDictionary, corrector: corrector,
            suppression: suppression, commonNames: lexicons.commonNames)
        return UserLoad(vocabulary: vocabulary, diagnostics: diagnostics, loadedAt: now())
    }

    // MARK: - G2 §5 public facades (UI-facing, no internal types leaked)

    /// G2: an everyday-membership test over the bundled lexicons, as a value
    /// the app layer can hold (the `Lexicons` type stays internal). Returns a
    /// closure that answers the G1 everyday test for a FOLDED key; falls back
    /// to "never everyday" if the bundled lexicons cannot load.
    public static func everydayTest() -> @Sendable (String) -> Bool {
        guard let lexicons = try? sharedLexicons() else { return { _ in false } }
        return { isEveryday($0, lexicons: lexicons) }
    }

    /// G2 §5 (M-5): the glossary-link admission pre-check over the bundled
    /// lexicons — gates 0a/0b + AliasAdmission + distinctive-core. True iff
    /// `surface` would be admitted as an alias of `canonical`.
    public static func wouldAdmitToGlossary(surface: String, canonical: String) -> Bool {
        guard let lexicons = try? sharedLexicons() else { return false }
        return GlossaryAdmissionPreview.wouldAdmit(
            surface: surface, canonical: canonical,
            pt: lexicons.pt, en: lexicons.en, brCommonNames: lexicons.commonNames)
    }

    /// Gate-3 everyday-core test (§5a.3): a core is everyday iff it is a member
    /// of either frequency lexicon (any rank) OR of `br_common_names`. (The
    /// top-3,000 band is a subset of any-rank lexicon membership — the spec's
    /// own nit — so the disjunction reduces to these two checks.)
    static func isEveryday(_ foldedCore: String, lexicons: Lexicons) -> Bool {
        if lexicons.pt.rank[foldedCore] != nil { return true }
        if lexicons.en.rank[foldedCore] != nil { return true }
        if lexicons.commonNames.contains(foldedCore) { return true }
        return false
    }

    // MARK: - Helpers

    private static func emptyLoad(
        suppression: Set<String> = [],
        commonNames: Set<String> = [],
        diagnostics: GlossaryDiagnostics,
        now: @Sendable () -> Date,
        build: (VocabularyDictionary, Set<String>) throws -> VocabularyCorrector = {
            try VocabularyCorrector(dictionary: $0, suppression: $1)
        }
    ) -> UserLoad {
        let empty = VocabularyDictionary(entries: [])
        // The empty corrector cannot collide; force-build is safe. Should the
        // injected build throw even here, fall back to the real constructor.
        let corrector = (try? build(empty, suppression))
            ?? (try? VocabularyCorrector(dictionary: empty, suppression: suppression))
            ?? (try! VocabularyCorrector(dictionary: empty, suppression: []))
        let vocabulary = PipelineVocabulary(
            dictionary: empty, corrector: corrector,
            suppression: suppression, commonNames: commonNames)
        return UserLoad(vocabulary: vocabulary, diagnostics: diagnostics, loadedAt: now())
    }

    private static func rejectedDiagnostics(_ error: Error) -> GlossaryDiagnostics {
        var d = GlossaryDiagnostics()
        d.addFile(.glossaryRejected(reason: faultText(error)))
        return d
    }

    private static func rejectionText(_ rejection: AliasAdmission.Rejection) -> String {
        switch rejection {
        case .lexiconWord(let ptRank, let enRank):
            return "everyday word (pt \(ptRank.map(String.init) ?? "—"), en \(enRank.map(String.init) ?? "—"))"
        case .brCommonName:
            return "common given name"
        case .collision(let existing):
            return "already maps to \(existing)"
        }
    }

    private static func faultText(_ error: Error) -> String {
        if let collision = error as? VocabularyCorrectorError {
            switch collision {
            case .surfaceCollision(let surface, let a, let b):
                return "surface collision on '\(surface)' (\(a) vs \(b))"
            }
        }
        return String(describing: error)
    }
}
