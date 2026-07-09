import Foundation
import Testing

@testable import BlaiseCore

// C10 AC3: the DoD app-surface flows exercised end to end against mock
// engines — import → process → ready event + detail content surface; search
// THROUGH THE VIEW-MODEL PATH over (a) the seeded pinned sample transcript
// and (b) two PLANTED synthetic fixture transcripts (provenance: invented
// here, in this test, for the DoD's "planted test transcripts" item);
// Settings engine switch + regenerate end to end (real-engine equivalent =
// C7 AC4, cited in the evidence).

@MainActor
@Suite struct AppShellIntegrationTests {
    @Test func importProcessSurfacesReadyEventAndDetailContent() async throws {
        let harness = try await makePipelineHarness()
        let library = LibraryModel(database: harness.database)
        library.start()
        defer { library.stop() }
        let activity = PipelineActivityHolder()

        let events = await harness.pipeline.events()
        let meeting = try await harness.importTestMeeting()

        let consumer = Task { @MainActor in
            var finalized: MeetingID?
            for await event in events {
                if let id = activity.apply(event) {
                    finalized = id
                    library.markReady(id)
                }
                if case .runCompleted = event { break }
            }
            return finalized
        }
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        let finalized = await consumer.value

        // stageFinished(.finalize) fired for this meeting → ready pulse +
        // textual badge state.
        #expect(finalized == meeting.id)
        #expect(library.recentlyReady.contains(meeting.id))

        // Detail model surfaces the fresh notes + transcript immediately.
        let detail = MeetingDetailModel(database: harness.database, meetingID: meeting.id)
        detail.start()
        defer { detail.stop() }
        for _ in 0 ..< 100 {
            if detail.notes != nil, !detail.segments.isEmpty, detail.meeting?.status == .ready { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(detail.meeting?.status == .ready)
        let notes = try #require(detail.notes)
        #expect(notes.structured.summary == "Resumo da reunião de teste.")
        #expect(!detail.segments.isEmpty)
        // Run overlay state cleared after completion.
        #expect(activity.activeRuns[meeting.id] == nil)
    }

    @Test func searchThroughViewModelPathOverSeededAndPlantedTranscripts() async throws {
        let database = try makeDatabase()

        // (a) The seeded mock transcripts, planted by the debug seeder.
        let seeded = try await DemoSeeder.seed(database: database)

        // (b) Two PLANTED synthetic transcripts (invented for this test).
        let transcripts = TranscriptRepository(database: database)
        let plantedA = makeMeeting(title: "Planted A — orçamento", status: .ready)
        try await MeetingRepository(database: database).create(plantedA)
        try await transcripts.replaceAllSegments(
            meetingID: plantedA.id,
            with: [
                TranscriptSegment(
                    meetingID: plantedA.id, ord: 0, startSeconds: 0, endSeconds: 4,
                    speakerName: "Sam", text: "o orçamento do protótipo fica em quarenta mil"),
                TranscriptSegment(
                    meetingID: plantedA.id, ord: 1, startSeconds: 5, endSeconds: 9,
                    speakerName: "Nira", text: "fechado, atualizo a planilha do orçamento hoje"),
            ])
        let plantedB = makeMeeting(title: "Planted B — roadmap", status: .ready)
        try await MeetingRepository(database: database).create(plantedB)
        try await transcripts.replaceAllSegments(
            meetingID: plantedB.id,
            with: [
                TranscriptSegment(
                    meetingID: plantedB.id, ord: 0, startSeconds: 0, endSeconds: 4,
                    speakerName: "Kuvira", text: "the roadmap review moves to Thursday")
            ])

        let library = LibraryModel(database: database)
        library.start()
        defer { library.stop() }
        for _ in 0 ..< 100 {
            if library.items.count == seeded.meetingCount + 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        // (a) Known seeded-mock strings, via the view-model path: snippet
        // segments carry the mapped match runs and the meeting title joins.
        for term in ["patch", "crash-free"] {
            let results = await library.search(term).transcripts
            #expect(!results.isEmpty, "no results for \(term)")
            let first = try #require(results.first)
            #expect(first.segments.contains { $0.isMatch })
            #expect(!first.meetingTitle.isEmpty)
        }

        // (b) Planted transcripts: both meetings reachable; diacritic-folded
        // FTS (unicode61 remove_diacritics) matches "orcamento" too.
        let planted = await library.search("orçamento").transcripts
        #expect(planted.contains { $0.hit.meetingID == plantedA.id })
        let folded = await library.search("orcamento").transcripts
        #expect(folded.contains { $0.hit.meetingID == plantedA.id })
        let english = await library.search("roadmap").transcripts
        #expect(english.contains { $0.hit.meetingID == plantedB.id })
        #expect(english.first { $0.hit.meetingID == plantedB.id }?.meetingTitle == "Planted B — roadmap")
    }

    @Test func engineSwitchThenRegenerateEndToEnd() async throws {
        // Settings switch + regenerate with mock engines: the regenerated
        // notes carry the NEWLY selected engine's provenance (real-engine
        // evidence = C7 AC4).
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        let firstNotes = try #require(
            try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id))
        #expect(firstNotes.provenance.engine == "pipeline-mock-notes-primary")

        // Switch the summarization engine through the Settings model
        // (immediate write), then regenerate via the dispatch rule.
        let registry = try EngineRegistry(
            asr: [harness.asr], summarization: [harness.notesPrimary, harness.notesFallback])
        let settings = SettingsStore(database: harness.database)
        let model = EngineSettingsModel(registry: registry, settings: settings)
        await model.load()
        await model.select("pipeline-mock-notes-fallback", slot: .summarization)
        #expect(try await settings.get(EngineResolver.summarizationSettingsKey, as: String.self)
            == "pipeline-mock-notes-fallback")

        _ = try await harness.pipeline.dispatchProcessing(meetingID: meeting.id)
        let regenerated = try #require(
            try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id))
        #expect(regenerated.provenance.engine == "pipeline-mock-notes-fallback")
        let after = try #require(try await harness.meeting(meeting.id))
        #expect(after.status == .ready)
    }
}
