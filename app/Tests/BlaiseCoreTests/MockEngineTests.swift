import Foundation
import Testing
@testable import BlaiseCore

@Suite struct MockEngineTests {
    private func asrRequest(hints: [String] = [], languageHint: String? = nil) -> ASRRequest {
        ASRRequest(
            audioURL: URL(fileURLWithPath: "/tmp/meeting.wav"),
            vocabularyHints: hints,
            languageHint: languageHint
        )
    }

    @Test func hintsContractIsRecordedInRequestAndProvenance() async throws {
        let engine = MockASREngine()

        let hinted = try await engine.transcribe(asrRequest(hints: ["Vexatron", "Lattice"], languageHint: "pt-BR"))
        #expect(hinted.provenance.vocabularyHintsApplied == true)
        #expect(hinted.provenance.languageHint == "pt-BR")

        let unhinted = try await engine.transcribe(asrRequest())
        #expect(unhinted.provenance.vocabularyHintsApplied == false)
        #expect(unhinted.provenance.languageHint == nil)

        // The engine saw exactly what was passed.
        #expect(engine.recordedRequests.map(\.vocabularyHints) == [["Vexatron", "Lattice"], []])
        #expect(engine.recordedRequests.map(\.languageHint) == ["pt-BR", nil])
    }

    @Test func transcribeThrowsCancelledOnCancelledTask() async throws {
        let engine = MockASREngine()
        let task = Task { () throws -> ASRResult in
            // Deterministic: cancel the current task before the engine call.
            withUnsafeCurrentTask { $0?.cancel() }
            return try await engine.transcribe(asrRequest())
        }
        await #expect(throws: EngineError.cancelled) {
            _ = try await task.value
        }
        #expect(engine.recordedRequests.isEmpty)
    }

    @Test func generateNotesThrowsCancelledOnCancelledTask() async throws {
        let engine = MockSummarizationEngine()
        let request = NotesRequest(
            meeting: makeMeeting(),
            transcript: [],
            dominantLanguage: "pt-BR",
            vocabulary: [],
            user: .shippedDefault
        )
        let task = Task { () throws -> NotesResult in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await engine.generateNotes(request)
        }
        await #expect(throws: EngineError.cancelled) {
            _ = try await task.value
        }
    }

    /// Missing required secret → `availability()` reports unavailable and
    /// calls throw `.configurationMissing` — never a crash. Setting the
    /// secret afterwards reaches the already-constructed engine on its next
    /// call (live read-through; B-8's "5-second fix", no restart).
    @Test func missingRequiredSecretThrowsConfigurationMissingUntilProvided() async throws {
        let database = try makeDatabase()
        let secrets = InMemorySecretStore()
        let descriptors = [EngineConfigDescriptor(key: "apiKey", label: "API key", kind: .secret, required: true)]
        let configuration = EngineConfiguration(
            engineID: "mock-cloud-asr",
            descriptors: descriptors,
            settings: SettingsStore(database: database),
            secrets: secrets
        )
        let engine = MockASREngine(
            id: "mock-cloud-asr",
            configDescriptors: descriptors,
            configuration: configuration
        )

        #expect(await engine.availability() == .unavailable(reason: "missing required configuration: apiKey"))
        await #expect(throws: EngineError.configurationMissing(key: "apiKey")) {
            _ = try await engine.transcribe(asrRequest())
        }

        // Live read-through: same engine instance, secret entered "in Settings".
        try secrets.set(key: "engine.mock-cloud-asr.apiKey", value: "k")
        #expect(await engine.availability() == .available)
        _ = try await engine.transcribe(asrRequest())
        #expect(engine.recordedRequests.count == 1)
    }

    @Test func summarizationMissingRequiredSecretThrowsConfigurationMissing() async throws {
        let database = try makeDatabase()
        let descriptors = [EngineConfigDescriptor(key: "apiKey", label: "API key", kind: .secret, required: true)]
        let engine = MockSummarizationEngine(
            id: "mock-cloud-sum",
            kind: .cloud,
            costDescriptor: EngineCostDescriptor(pricingSummary: "US$ test", estimatedPerMeetingUSD: 0.1),
            configDescriptors: descriptors,
            configuration: EngineConfiguration(
                engineID: "mock-cloud-sum",
                descriptors: descriptors,
                settings: SettingsStore(database: database),
                secrets: InMemorySecretStore()
            )
        )
        let request = NotesRequest(
            meeting: makeMeeting(),
            transcript: [],
            dominantLanguage: "en",
            vocabulary: [],
            user: .shippedDefault
        )
        await #expect(throws: EngineError.configurationMissing(key: "apiKey")) {
            _ = try await engine.generateNotes(request)
        }
    }

    @Test func defaultPrepareIsANoOp() async throws {
        // Protocol extension default: prepare() must exist and not throw.
        try await MockASREngine().prepare()
        try await MockSummarizationEngine().prepare()
    }
}
