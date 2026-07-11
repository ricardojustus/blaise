import Foundation
import Synchronization
import Testing

@testable import BlaiseCore

// C10 app-shell tests: block-level markdown (the .full html-off pin),
// search-snippet delimiter mapping, settings view-models (immediate write +
// prepare state machine, validation + kick-on-fix, Retry-All prefix
// semantics), observation smoke, the widened import seam, status-dependent
// dispatch, and the demo seeder.

// MARK: - Pinned date rendering (M-1: DD/MM/YYYY never locale-field-order)

@Suite struct BlaiseDateFormatTests {
    /// 8 June 2026 14:30 local — unambiguous day/month, so a field-order
    /// swap is detectable.
    private var sample: Date {
        Calendar.current.date(
            from: DateComponents(year: 2026, month: 6, day: 8, hour: 14, minute: 30))!
    }

    @Test func dayMonthYearIsFixedOrderEvenWhereEnUSWouldSwapIt() {
        #expect(BlaiseDateFormat.dayMonthYear(sample) == "08/06/2026")
        // The pre-fix style under a FORCED en_US locale renders month-first —
        // the exact failure mode the fixed formatter excludes.
        let enUS = sample.formatted(
            Date.FormatStyle(locale: Locale(identifier: "en_US"))
                .day(.twoDigits).month(.twoDigits).year())
        #expect(enUS == "06/08/2026")
        #expect(BlaiseDateFormat.dayMonthYear(sample) != enUS)
    }

    @Test func dayMonthYearTimeIs24Hour() {
        #expect(BlaiseDateFormat.dayMonthYearTime(sample) == "08/06/2026 14:30")
    }
}

// MARK: - Markdown blocks (native NotesStructured rendering support)

@Suite struct MarkdownBlocksTests {
    /// The pinned N8 guarantee: under `interpretedSyntax: .full`, raw HTML
    /// stays LITERAL text — never interpreted, never stripped.
    @Test func htmlOffUnderFullSyntaxOption() throws {
        let markdown = "Antes <script>alert('x')</script> depois <b>bold?</b>"
        let blocks = MarkdownBlocks.parse(markdown)
        let flattened = blocks.map { String($0.text.characters) }.joined(separator: "\n")
        #expect(flattened.contains("<script>alert('x')</script>"))
        #expect(flattened.contains("<b>bold?</b>"))
        // And the option itself preserves it (the exact pinned API form).
        let attributed = try AttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full))
        #expect(String(attributed.characters).contains("<script>alert('x')</script>"))
    }

    @Test func paragraphsAndListsSplitIntoBlocks() {
        let markdown = """
            First paragraph with **bold**.

            Second paragraph.

            - item one
            - item two

            1. ordered one
            2. ordered two
            """
        let blocks = MarkdownBlocks.parse(markdown)
        let paragraphs = blocks.filter { $0.kind == .paragraph }
        #expect(paragraphs.count == 2)
        let unordered = blocks.filter { $0.kind == .listItem(ordinal: nil, depth: 1) }
        #expect(unordered.map { String($0.text.characters) } == ["item one", "item two"])
        let ordered = blocks.filter {
            if case .listItem(let ordinal, _) = $0.kind { return ordinal != nil }
            return false
        }
        #expect(ordered.count == 2)
        // Inline emphasis survives inside a block.
        let first = paragraphs[0].text
        #expect(first.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
    }

    @Test func emptyAndPlainInputs() {
        #expect(MarkdownBlocks.parse("").isEmpty)
        let plain = MarkdownBlocks.parse("só um parágrafo")
        #expect(plain.count == 1)
        #expect(plain[0].kind == .paragraph)
    }
}

// MARK: - Search snippet delimiter mapping

@Suite struct SearchSnippetTests {
    @Test func mapsPinnedDelimitersToMatchSegments() {
        let snippet = "…falando de \u{FFF9}prototipar\u{FFFA} para decidir e \u{FFF9}core loop\u{FFFA}…"
        let segments = SearchSnippetFormatter.segments(snippet)
        #expect(segments == [
            .init(text: "…falando de ", isMatch: false),
            .init(text: "prototipar", isMatch: true),
            .init(text: " para decidir e ", isMatch: false),
            .init(text: "core loop", isMatch: true),
            .init(text: "…", isMatch: false),
        ])
    }

    @Test func plainSnippetIsOneSegment() {
        #expect(SearchSnippetFormatter.segments("sem matches")
            == [.init(text: "sem matches", isMatch: false)])
    }

    @Test func extractsUniqueStoredMatchSpellings() {
        let segments: [SearchSnippetFormatter.Segment] = [
            .init(text: "…", isMatch: false),
            .init(text: "OrbitVR", isMatch: true),
            .init(text: " and ", isMatch: false),
            .init(text: "orbitvr", isMatch: true),
            .init(text: " decisões", isMatch: true),
        ]
        #expect(SearchSnippetFormatter.matchTerms(segments) == ["OrbitVR", "decisões"])
    }

    @Test func destinationMatcherHighlightsEveryCaseAndDiacriticInsensitiveOccurrence() {
        let segments = SearchTextMatcher.segments(
            "OrbitVR reviewed ORBITVR decisões", matching: ["orbitvr", "decisoes"])
        #expect(segments == [
            .init(text: "OrbitVR", isMatch: true),
            .init(text: " reviewed ", isMatch: false),
            .init(text: "ORBITVR", isMatch: true),
            .init(text: " ", isMatch: false),
            .init(text: "decisões", isMatch: true),
        ])
    }
}

// MARK: - Engine settings model (immediate write + prepare state machine)

final class PrepareControlledASR: ASREngine, @unchecked Sendable {
    let id: String
    let displayName: String
    let kind: EngineKind = .local
    let costDescriptor: EngineCostDescriptor? = nil
    let configDescriptors: [EngineConfigDescriptor] = []
    struct State {
        var prepareError: EngineError?
        var availability: EngineAvailability = .available
        var prepareCalls = 0
    }
    let state = Mutex(State())

    init(id: String, displayName: String = "Controlled ASR") {
        self.id = id
        self.displayName = displayName
    }

    func availability() async -> EngineAvailability { state.withLock { $0.availability } }
    func prepare() async throws {
        let error = state.withLock { state -> EngineError? in
            state.prepareCalls += 1
            return state.prepareError
        }
        if let error { throw error }
    }
    func transcribe(_ request: ASRRequest) async throws -> ASRResult { throw EngineError.cancelled }
}

@MainActor
@Suite struct EngineSettingsModelTests {
    func makeModel() async throws -> (EngineSettingsModel, PrepareControlledASR, PrepareControlledASR, SettingsStore) {
        let database = try makeDatabase()
        let good = PrepareControlledASR(id: "good-asr")
        let bad = PrepareControlledASR(id: "bad-asr")
        let registry = try EngineRegistry(
            asr: [good, bad], summarization: [MockSummarizationEngine(id: "mock-sum")])
        let settings = SettingsStore(database: database)
        try await settings.set(EngineResolver.asrSettingsKey, to: good.id)
        try await settings.set(EngineResolver.summarizationSettingsKey, to: "mock-sum")
        let model = EngineSettingsModel(registry: registry, settings: settings)
        await model.load()
        return (model, good, bad, settings)
    }

    @Test func selectionWritesImmediatelyEvenWhenPrepareFails() async throws {
        let (model, _, bad, settings) = try await makeModel()
        bad.state.withLock {
            $0.prepareError = .notAvailable(reason: "model download failed")
            $0.availability = .unavailable(reason: "model download failed")
        }
        await model.select("bad-asr", slot: .asr)
        // The settings key was written IMMEDIATELY — the selection is the
        // user's choice regardless of preparation state.
        #expect(try await settings.get(EngineResolver.asrSettingsKey, as: String.self) == "bad-asr")
        // Failure → reason inline, selection KEPT.
        #expect(model.selectedASRID == "bad-asr")
        #expect(model.asrPrepare == .failed(engineID: "bad-asr", reason: "model download failed"))
    }

    @Test func retryClearsFailureOnSuccess() async throws {
        let (model, _, bad, _) = try await makeModel()
        bad.state.withLock {
            $0.prepareError = .transient("network down")
        }
        await model.select("bad-asr", slot: .asr)
        guard case .failed = model.asrPrepare else {
            Issue.record("expected failed prepare, got \(model.asrPrepare)")
            return
        }
        bad.state.withLock { $0.prepareError = nil }
        await model.retryPrepare(slot: .asr)
        #expect(model.asrPrepare == .idle)
        #expect(model.selectedASRID == "bad-asr")
        #expect(bad.state.withLock { $0.prepareCalls } == 2)
    }

    @Test func launchRetryFiresPrepareForSelectedEngines() async throws {
        let (model, good, _, _) = try await makeModel()
        await model.prepareSelectedEnginesAtLaunch()
        #expect(good.state.withLock { $0.prepareCalls } >= 1)
        #expect(model.asrPrepare == .idle)
        #expect(model.summarizationPrepare == .idle)
    }

    @Test func rowsCarryAvailabilityAndKind() async throws {
        let (model, _, bad, _) = try await makeModel()
        bad.state.withLock { $0.availability = .unavailable(reason: "needs provisioning") }
        await model.refreshRows()
        let badRow = try #require(model.asrRows.first { $0.id == "bad-asr" })
        #expect(badRow.availabilityReason == "needs provisioning")
        #expect(badRow.kind == .local)
        let goodRow = try #require(model.asrRows.first { $0.id == "good-asr" })
        #expect(goodRow.availabilityReason == nil)
    }
}

// MARK: - Handoff settings model (validation + kick-on-fix)

final class CountingKicker: HandoffKicking, @unchecked Sendable {
    let kicks = Mutex(0)
    func kick() async { kicks.withLock { $0 += 1 } }
    var count: Int { kicks.withLock { $0 } }
}

@MainActor
@Suite struct HandoffSettingsModelTests {
    @Test func invalidSettingsShowInlineErrorAndNeverKick() async throws {
        let database = try makeDatabase()
        let kicker = CountingKicker()
        let model = HandoffSettingsModel(settings: SettingsStore(database: database), kicker: kicker)
        await model.load()
        // The shipped default is now empty (G6 publish-scrub), so establish a fully
        // valid baseline first — this test exercises a SINGLE invalid field
        // (remoteRoot), not the empty-default case.
        model.user = "deploy"
        model.hostsText = "store.example"
        model.remoteRoot = "relative/path'; rm -rf /"  // fails the C8 regex
        let passed = await model.save()
        #expect(!passed)
        #expect(model.validationError?.contains("remoteRoot") == true)
        #expect(kicker.count == 0)

        // Fix → save passes validation → automatic worker.kick().
        model.remoteRoot = "/srv/store/evidence-inbox/blaise"
        let fixed = await model.save()
        #expect(fixed)
        #expect(model.validationError == nil)
        #expect(kicker.count == 1)

        // The persisted values round-trip through HandoffSettings.load.
        let loaded = await HandoffSettings.load(from: SettingsStore(database: database))
        #expect(loaded.remoteRoot == "/srv/store/evidence-inbox/blaise")
    }

    @Test func hostsParseFromLinesAndCommas() async throws {
        let database = try makeDatabase()
        let model = HandoffSettingsModel(
            settings: SettingsStore(database: database), kicker: CountingKicker())
        model.hostsText = "198.51.100.10\n203.0.113.20, host.example"
        #expect(model.hosts == ["198.51.100.10", "203.0.113.20", "host.example"])
    }
}

// MARK: - Queue retry semantics (damaged once, superseded never)

@Suite struct QueueRetrySemanticsTests {
    @Test func retryAllReentersFailedAndDamagedButNeverSuperseded() async throws {
        let database = try makeDatabase()
        let repository = HandoffRepository(database: database)
        let (m1, h1, p1) = try await makeEnqueueableMeeting(database, versionHash: "hash-plain")
        let plain = try await repository.enqueue(meetingID: m1.id, versionHash: h1, payloadPath: p1)
        _ = try await repository.transition(plain.id, to: .failed, error: "transient: exit=255")
        let (m2, h2, p2) = try await makeEnqueueableMeeting(database, versionHash: "hash-damaged")
        let damaged = try await repository.enqueue(meetingID: m2.id, versionHash: h2, payloadPath: p2)
        _ = try await repository.transition(
            damaged.id, to: .failed, error: HandoffErrorClass.damaged("bytes do not match"))
        let (m3, h3, p3) = try await makeEnqueueableMeeting(database, versionHash: "hash-superseded")
        let superseded = try await repository.enqueue(meetingID: m3.id, versionHash: h3, payloadPath: p3)
        _ = try await repository.transition(
            superseded.id, to: .failed, error: HandoffErrorClass.superseded(byNewerHash: "deadbeef"))

        let reentered = try await repository.retryAllFailed()
        #expect(reentered == 2)
        let items = try await repository.allItems()
        func state(_ id: HandoffID) -> HandoffState? { items.first { $0.id == id }?.state }
        #expect(state(plain.id) == .pending)
        #expect(state(damaged.id) == .pending)  // the ONE re-check
        #expect(state(superseded.id) == .failed)  // terminal, never re-entered
    }

    @Test func perItemRetryRespectsSupersededPrefix() async throws {
        let database = try makeDatabase()
        let repository = HandoffRepository(database: database)
        let (m1, h1, p1) = try await makeEnqueueableMeeting(database, versionHash: "hash-a")
        let item = try await repository.enqueue(meetingID: m1.id, versionHash: h1, payloadPath: p1)
        _ = try await repository.transition(item.id, to: .failed, error: "transient: x")
        #expect(try await repository.retryItem(item.id))
        _ = try await repository.transition(item.id, to: .failed, error: HandoffErrorClass.superseded(byNewerHash: "ff"))
        #expect(!(try await repository.retryItem(item.id)))
    }

    @MainActor
    @Test func queuePanelModelKicksAfterRetryAll() async throws {
        let database = try makeDatabase()
        let repository = HandoffRepository(database: database)
        let (m1, h1, p1) = try await makeEnqueueableMeeting(database, versionHash: "hash-kick")
        let item = try await repository.enqueue(meetingID: m1.id, versionHash: h1, payloadPath: p1)
        _ = try await repository.transition(item.id, to: .failed, error: "transient: x")
        let kicker = CountingKicker()
        let model = QueuePanelModel(database: database, kicker: kicker)
        await model.retryAll()
        #expect(kicker.count == 1)
        #expect(model.queueItems.first?.state == .pending)
    }
}

// MARK: - Observation smoke + library grouping

@MainActor
@Suite struct LibraryModelTests {
    @Test func valueObservationSeesInsertsAndNotesMetadata() async throws {
        let database = try makeDatabase()
        let model = LibraryModel(database: database)
        model.start()
        defer { model.stop() }

        let meeting = makeMeeting(title: "Observed meeting", status: .ready)
        try await MeetingRepository(database: database).create(meeting)
        try await NotesRepository(database: database).upsert(makeNotes(meetingID: meeting.id))

        // ValueObservation delivers asynchronously; poll briefly.
        for _ in 0 ..< 100 {
            if model.items.first?.userActionItemCount == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let item = try #require(model.items.first)
        #expect(item.meeting.title == "Observed meeting")
        #expect(item.userActionItemCount == 1)
        #expect(item.actionItemCount == 1)
        #expect(item.summary == "Resumo da reunião.")
        // My Action Items entries flatten with meeting context.
        #expect(model.userEntries.first?.meetingTitle == "Observed meeting")
    }

    @Test func smartGroupsFilter() async throws {
        let database = try makeDatabase()
        let model = LibraryModel(database: database)
        let now = msDate()
        let recent = MeetingListItem(
            meeting: makeMeeting(title: "recent", startedAt: now.addingTimeInterval(-3600)),
            summary: nil, actionItemCount: 0, userActionItemCount: 2)
        let old = MeetingListItem(
            meeting: makeMeeting(title: "old", startedAt: now.addingTimeInterval(-10 * 24 * 3600)),
            summary: nil, actionItemCount: 1, userActionItemCount: 0)
        model.setItemsForTesting([recent, old])
        #expect(model.items(in: .all, now: now).count == 2)
        #expect(model.items(in: .thisWeek, now: now).map(\.meeting.title) == ["recent"])
        #expect(model.items(in: .myActionItems, now: now).map(\.meeting.title) == ["recent"])
    }

    @Test func dayGroupsAreNewestFirstWithDDMMYYYYLabels() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        let now = Date(timeIntervalSince1970: 1_781_136_000)
        let today = MeetingListItem(
            meeting: makeMeeting(title: "today", startedAt: now.addingTimeInterval(-60)),
            summary: nil, actionItemCount: 0, userActionItemCount: 0)
        let lastWeek = MeetingListItem(
            meeting: makeMeeting(title: "past", startedAt: now.addingTimeInterval(-6 * 24 * 3600)),
            summary: nil, actionItemCount: 0, userActionItemCount: 0)
        let groups = LibraryModel.dayGroups([today, lastWeek], calendar: calendar, now: now)
        #expect(groups.count == 2)
        #expect(groups[0].label == "Today")
        #expect(groups[0].items.map(\.meeting.title) == ["today"])
        // Older day: weekday + the DD/MM/YYYY convention.
        #expect(groups[1].label.contains("/2026"))
        let dayPart = groups[1].label.split(separator: " ").last!
        #expect(dayPart.split(separator: "/").count == 3)
    }
}

// MARK: - Import seam (WAV + M4A + meetingCode) and dispatch rule

@Suite struct ImportSeamTests {
    @Test func m4aImportSkipsEncodeAndPersistsCodeAndStart() async throws {
        let harness = try await makePipelineHarness()
        // Build a real m4a from a generated WAV via the C7 transcoder.
        let wav = harness.dataRoot.appendingPathComponent("src.wav")
        try writeTestWAV(to: wav, seconds: 2.0)
        let m4a = harness.dataRoot.appendingPathComponent("src.m4a")
        try AudioTranscoder.encodeToM4A(wav: wav, destination: m4a) { _ in }

        let started = msDate()
        let meeting = try await harness.pipeline.importMeeting(
            sourceURL: m4a, title: "M4A import", startedAt: started,
            attendees: [Attendee(name: "Sam", source: .manual)], meetingCode: "abc-defg-hij")

        // The m4a IS the retained audio (copied in verified); no import.wav.
        let audioURL = harness.database.paths.audioURL(meeting.id)
        #expect(FileManager.default.fileExists(atPath: audioURL.path))
        #expect(!FileManager.default.fileExists(atPath: harness.database.paths.importCopyURL(meeting.id).path))

        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.meetingCode == "abc-defg-hij")
        #expect(stored.startedAt == started)
        #expect(stored.endedAt != nil)
        #expect(stored.source == .imported)

        // A full process() run works from the imported m4a (ingest skips the
        // encode by construction: audio.m4a already exists).
        let record = try await harness.pipeline.process(meetingID: meeting.id)
        #expect(record.versionHash != nil)
        let processed = try #require(try await harness.meeting(meeting.id))
        #expect(processed.status == .ready)
    }

    @Test func wavImportStillEncodesViaIngest() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        #expect(FileManager.default.fileExists(
            atPath: harness.database.paths.importCopyURL(meeting.id).path))
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        #expect(FileManager.default.fileExists(
            atPath: harness.database.paths.audioURL(meeting.id).path))
    }

    @Test func dispatchIsStatusDependent() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        // Non-ready → process() (full run incl. ingest; import copy consumed).
        _ = try await harness.pipeline.dispatchProcessing(meetingID: meeting.id)
        let afterFirst = try #require(try await harness.meeting(meeting.id))
        #expect(afterFirst.status == .ready)

        // Ready → regenerate(): never-regress. Make the run FAIL mid-ASR —
        // a process() dispatch would flip status to .failed; regenerate keeps
        // .ready (the C1 no-regress rule), proving the regenerate path ran.
        harness.asr.state.withLock { $0.transcribeError = .transient("induced") }
        await #expect(throws: PipelineError.self) {
            try await harness.pipeline.dispatchProcessing(meetingID: meeting.id)
        }
        let afterSecond = try #require(try await harness.meeting(meeting.id))
        #expect(afterSecond.status == .ready)
        #expect(afterSecond.lastProcessingError?.contains("induced") == true)
    }
}

// MARK: - Demo seeder

@Suite struct DemoSeederTests {
    @Test func seedsTwelveMocks() async throws {
        let database = try makeDatabase()
        let summary = try await DemoSeeder.seed(database: database)
        #expect(summary.meetingCount == 12)  // 12 mocks
        #expect(try database.count("meeting") == 12)
        #expect(summary.segmentCount > 0)

        // A known READY mock carries real transcript + notes outputs.
        let meetings = try await MeetingRepository(database: database).listByRecency()
        let aurora = try #require(
            meetings.first { $0.title == "Aurora Drift — post-launch sync" },
            "expected the Aurora Drift mock to be seeded")
        let segments = try await TranscriptRepository(database: database)
            .segments(meetingID: aurora.id)
        #expect(!segments.isEmpty)
        let notes = try #require(
            try await NotesRepository(database: database).fetch(meetingID: aurora.id))
        #expect(!notes.structured.userActionItems.isEmpty)

        // Search works against a seeded mock transcript (known mock string).
        let hits = try await TranscriptRepository(database: database).search("patch")
        #expect(hits.contains { $0.meetingID == aurora.id })
    }
}
