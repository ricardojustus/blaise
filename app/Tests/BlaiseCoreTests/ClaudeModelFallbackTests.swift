import Foundation
import Synchronization
import Testing
@testable import BlaiseCore

enum ClaudeFallbackTrigger: CaseIterable, Sendable, Equatable {
    case missingKey
    case ceilingReached
}

@Suite struct ClaudeModelFallbackTests {
    @Test(arguments: ClaudeNotesModel.allCases, ClaudeFallbackTrigger.allCases)
    func apiFamilyDoesNotFallbackAcrossModels(
        selectedModel: ClaudeNotesModel, trigger: ClaudeFallbackTrigger
    ) async throws {
        let harness = try await makePipelineHarness(registerFallbackEngine: false)
        let settings = SettingsStore(database: harness.database)
        let secrets = InMemorySecretStore()
        if trigger == .ceilingReached {
            try secrets.set(
                key: "engine.\(ClaudeSummarizationEngine.engineID).\(ClaudeSummarizationEngine.apiKeyConfigKey)",
                value: "sk-test-not-a-real-key")
            try await settings.set(CloudSpendLedger.ceilingSettingsKey, to: 0.0)
        }
        let configuration = EngineConfiguration(
            engineID: ClaudeSummarizationEngine.engineID,
            descriptors: ClaudeSummarizationEngine.descriptors,
            settings: settings,
            secrets: secrets)
        let ledger = CloudSpendLedger(database: harness.database)
        let requests = Mutex<[URLRequest]>([])
        let transport: ClaudeSummarizationEngine.Transport = { request in
            requests.withLock { $0.append(request) }
            throw EngineError.permanent("API transport must not run after preflight failure")
        }
        let apiEngines = ClaudeNotesModel.allCases.map { model in
            ClaudeSummarizationEngine(
                configuration: configuration, ledger: ledger, model: model,
                transport: transport)
        }
        let heavyweight = PipelineMockNotes(
            id: "pipeline-heavy-notes",
            loadProfile: .heavyweight(estimatedPeakBytes: 18 * 1_073_741_824))
        var notesEngines: [any SummarizationEngine] = apiEngines
        notesEngines.append(heavyweight)
        let registry = try EngineRegistry(asr: [harness.asr], summarization: notesEngines)
        try await settings.set(EngineResolver.asrSettingsKey, to: harness.asr.id)
        try await settings.set(
            EngineResolver.summarizationSettingsKey, to: selectedModel.apiEngineID)

        let pipeline = ProcessingPipeline(
            database: harness.database,
            registry: registry,
            diarizer: harness.diarizer,
            vocabulary: try VocabFixtures.pipelineVocabulary(),
            voiceProfileStore: harness.voiceProfileStore,
            tempDirectory: harness.tempDir,
            notesEditorSleep: { _ in throw CancellationError() })
        let meeting = try await harness.importTestMeeting()
        let record = try await pipeline.process(meetingID: meeting.id)

        switch trigger {
        case .missingKey:
            #expect(record.notesPending
                == ProcessingPipeline.humanReason(.configurationMissing(key: "apiKey")))
        case .ceilingReached:
            #expect(record.notesPending == EngineFallbackReason.monthlyCeiling)
        }
        #expect(record.fallback == nil)
        #expect(record.notesEngineID == nil)
        #expect(requests.withLock { $0.isEmpty })
        #expect(heavyweight.state.withLock { $0.prepareCalls } == 0)
        #expect(heavyweight.state.withLock { $0.requests.isEmpty })
        #expect(!(try await harness.segments(meeting.id)).isEmpty)
        #expect(try await harness.queueRows(meeting.id) == 0)
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.status == .failed)
        #expect(NotesPendingClass.isPending(stored.lastProcessingError))
        let notes = try await NotesRepository(database: harness.database)
            .fetch(meetingID: meeting.id)
        #expect(notes == nil)
    }
}
