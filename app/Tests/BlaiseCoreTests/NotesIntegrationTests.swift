import Foundation
import Testing
@testable import BlaiseCore

// C6 AC2: REAL integration tests (skip-protocol like C3).

private let repoRoot = VocabFixtures.repoRoot
/// Persistent C6 dataRoot (venv provisioned once by the gated smoke step;
/// gitignored). The engine points AT it directly so the sentinel machinery
/// is exercised on the production path.
private let c6DataRoot = RegressionPin.notesDataRoot
private let realHFHome = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".cache/huggingface", isDirectory: true)

/// True iff the C6 stack (provisioned shared venv + Gemma snapshot) exists.
private func notesStackPresent() -> Bool {
    guard let requirements = MLXWhisperEngine.bundledRequirementsFile(),
        let requirementsData = try? Data(contentsOf: requirements)
    else { return false }
    let venvDir = VenvLayout(dataRoot: c6DataRoot).venvDir
    guard VenvLayout.isProvisioned(venvDir: venvDir, requirementsData: requirementsData) else {
        return false
    }
    return WhisperModelCache(
        hfHome: realHFHome, repo: MLXSummarizationEngine.modelRepo,
        markerName: MLXSummarizationEngine.suspectMarkerName
    ).integrity()
}

func makeRealNotesEngine() async throws -> MLXSummarizationEngine {
    // Settings DB lives in a temp root; the python/model dataRoot is the
    // persistent one (settings only carry the hfHome override).
    let database = try BlaiseDatabase(rootURL: try makeTempRoot())
    let settings = SettingsStore(database: database)
    try await settings.set(
        "engine.\(MLXSummarizationEngine.engineID).\(MLXSummarizationEngine.hfHomePathKey)",
        to: realHFHome.path)
    return MLXSummarizationEngine(
        configuration: EngineConfiguration(
            engineID: MLXSummarizationEngine.engineID,
            descriptors: MLXSummarizationEngine.descriptors,
            settings: settings,
            secrets: InMemorySecretStore()),
        dataRoot: c6DataRoot,
        uvBinary: repoRoot.appendingPathComponent("vendor/uv/uv"),
        driverScript: try #require(MLXSummarizationEngine.bundledDriverScript()),
        requirementsFile: try #require(MLXWhisperEngine.bundledRequirementsFile()),
        sweepOrphansOnInit: false)
}

@Suite(.serialized) struct NotesIntegrationTests {
    /// MLX engine end-to-end on a short REAL transcript excerpt (the C5
    /// golden clauses as a degenerate transcript — spec-sanctioned input).
    /// Gated behind BLAISE_TEST_FULL_SAMPLE_NOTES=1 since D17: this loads
    /// the real 15.6 GB model (~18 GB peak) — quiet-machine window only,
    /// never as part of the plain suite on a working machine.
    @Test(.timeLimit(.minutes(15)))
    func mlxEngineGeneratesSchemaValidNotesOnRealExcerpt() async throws {
        guard ProcessInfo.processInfo.environment["BLAISE_TEST_FULL_SAMPLE_NOTES"] == "1" else {
            recordTestSkip(
                "mlxEngineGeneratesSchemaValidNotesOnRealExcerpt",
                reason: "heavyweight local engine (~18 GB peak) — run under BLAISE_TEST_FULL_SAMPLE_NOTES=1 in a quiet-machine window (D17)")
            return
        }
        guard notesStackPresent() else {
            recordTestSkip(
                "mlxEngineGeneratesSchemaValidNotesOnRealExcerpt",
                reason: "C6 notes stack missing (provisioned venv at the maintainer-local notes data root or Gemma HF snapshot)")
            return
        }

        let engine = try await makeRealNotesEngine()
        #expect(await engine.availability() == .available)

        let meetingID = "01C6INTEGRATIONEXCERPT0000"
        let segments = VocabFixtures.goldenClauses.prefix(10).enumerated().map { index, clause in
            TranscriptSegment(
                meetingID: meetingID, ord: index, startSeconds: Double(index * 6),
                endSeconds: Double(index * 6 + 5), speakerLabel: "S\(index % 2)",
                text: clause.expected)
        }
        let request = NotesRequest(
            meeting: Meeting(
                id: meetingID, title: "Trecho de reunião (integração C6)",
                startedAt: msDate(), source: .meet, status: .processing,
                attendees: [Attendee(name: "Sam", source: .manual)],
                createdAt: msDate(), updatedAt: msDate()),
            transcript: Array(segments),
            dominantLanguage: "pt",
            vocabulary: VocabFixtures.dictionary.entries.map(\.canonical),
            user: UserIdentity.shippedDefault
        )

        let started = Date()
        let result = try await engine.generateNotes(request)
        let elapsed = Date().timeIntervalSince(started)
        print("[integration] mlx notes: \(String(format: "%.1f", elapsed)) s, usage \(String(describing: result.usage))")

        // Schema-valid by construction (decoded); sane content.
        #expect(!result.structured.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(try #require(result.usage?.inputUnits) > 100)
        #expect(try #require(result.usage?.outputUnits) > 0)
        #expect(result.usage?.estimatedCostUSD == nil)
        #expect(result.provenance.engine == "mlx-gemma4-26b")
        #expect(result.provenance.promptVersion == NotesPromptBuilder.promptVersion)
        // Mapping proposals are free-form LLM output; labels not present in
        // the transcript are dropped downstream by C7 → apply() (rule 1).
        // Here we only log them — schema validity is already proven by the
        // decode above.
        print("[integration] mlx notes mapping: \(result.speakerNameMapping)")
    }

    /// Claude engine end-to-end ONLY IF an API key is present (it cannot be
    /// invented; if skipped, the bake-off runs local-only and cloud E2E is a
    /// C13 human touchpoint with a 2-minute instruction).
    @Test(.timeLimit(.minutes(5)))
    func claudeEngineEndToEndWithRealKey() async throws {
        guard let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty
        else {
            recordTestSkip(
                "claudeEngineEndToEndWithRealKey",
                reason: "no ANTHROPIC_API_KEY in environment/Keychain — cloud E2E is a C13 human touchpoint (paste key, re-run)")
            return
        }

        let database = try BlaiseDatabase(rootURL: try makeTempRoot())
        let secrets = InMemorySecretStore()
        try secrets.set(
            key: "engine.\(ClaudeSummarizationEngine.engineID).\(ClaudeSummarizationEngine.apiKeyConfigKey)",
            value: key)
        let ledger = CloudSpendLedger(database: database)
        let engine = ClaudeSummarizationEngine(
            configuration: EngineConfiguration(
                engineID: ClaudeSummarizationEngine.engineID,
                descriptors: ClaudeSummarizationEngine.descriptors,
                settings: SettingsStore(database: database),
                secrets: secrets),
            ledger: ledger
        )
        // M-3: this is a harness/acceptance cloud call → `.validation` (spec
        // §1), threaded through the REAL engine accounting path so the purpose
        // is reachable by actual code, not just by the enum. The request's
        // meeting has no row in this throwaway DB; the ledger's FK-salvage
        // (M-3) keeps the receipt with meeting_id NULL rather than dropping it.
        let result = try await engine.generateNotes(makeNotesRequest(), purpose: .validation)
        #expect(!result.structured.summary.isEmpty)
        #expect(try #require(result.usage?.estimatedCostUSD) > 0)

        // The validation receipt actually landed (purpose threaded end to end).
        let month = try await ledger.monthReceipts()
        let validation = try #require(
            month.receipts.first { $0.purpose == .validation },
            "the validation purpose threaded down to a persisted receipt")
        #expect(validation.meetingID == nil, "no meeting row → kept with meeting_id NULL (M-3)")
        #expect(validation.costUSD > 0)
    }
}
