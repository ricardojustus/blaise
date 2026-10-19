import Foundation
import GRDB
import Synchronization
import Testing
@testable import BlaiseCore

// Timecode links through the pipeline: the trigger and its isolation (T-4)
// and the rows across every notes write (T-6). A scripted engine writes the
// notes, answers the editor and the anchoring call. Fictional data only.

final class AnchoringStubEngine:
    SummarizationEngine, NotesEditingEngine, TimecodeAnchoringEngine, @unchecked Sendable
{
    enum AnchorScript: Sendable {
        /// Every item anchored to the first segment at `seconds`… placed by
        /// the rule (no quote → the segment's start).
        case answerAll
        case answer(@Sendable (TimecodeAnchoring.Prompt) -> String)
        case error(EngineError)
    }

    struct Call: Sendable {
        let meetingID: MeetingID
        let purpose: CloudSpendPurpose
        let structured: NotesStructured
    }

    struct State {
        var notes: NotesStructured
        var anchorScripts: [AnchorScript] = []
        var anchorGates: [EditorGate] = []
        var anchorCalls: [Call] = []
        var editScripts: [[NotesEditOperation]] = []
        var editorGate: EditorGate?
        var notesGate: EditorGate?
    }

    let id = "anchoring-stub"
    let displayName = "Anchoring stub"
    let kind: EngineKind = .cloud
    let loadProfile: EngineLoadProfile = .lightweight
    let costDescriptor: EngineCostDescriptor? = nil
    let configDescriptors: [EngineConfigDescriptor] = []
    let state: Mutex<State>
    private let chain = EngineTaskChain()

    init(notes: NotesStructured) {
        state = Mutex(State(notes: notes))
    }

    func availability() async -> EngineAvailability { .available }
    func prepare() async throws {}

    func generateNotes(_ request: NotesRequest, purpose: CloudSpendPurpose) async throws -> NotesResult {
        let gate = state.withLock { state -> EditorGate? in
            defer { state.notesGate = nil }
            return state.notesGate
        }
        if let gate { await gate.enterAndWait() }
        let notes = state.withLock { $0.notes }
        return NotesResult(
            structured: notes, usage: EngineUsage(inputUnits: 1, outputUnits: 1),
            provenance: NotesProvenance(
                engine: id, model: "stub", pipelineVersion: "", runtime: "stub",
                rendererVersion: "", promptVersion: "stub"),
            speakerNameMapping: [])
    }

    func generateDigest(_ request: DigestRequest, purpose: CloudSpendPurpose) async throws -> DigestResult {
        DigestResult(
            digest: "## HEADER\nmeeting: Quoll Harbor sync\nspeaker: (none resolved)\n",
            usage: EngineUsage(inputUnits: 1, outputUnits: 1, estimatedCostUSD: nil),
            promptVersion: DigestPromptBuilder.shippedVersion.rawValue,
            model: "stub")
    }

    func editNotes(_ request: NotesEditorRequest, purpose: CloudSpendPurpose) async throws -> NotesEditorResult {
        let gate = state.withLock { $0.editorGate }
        if let gate { await gate.enterAndWait() }
        let operations = state.withLock { state -> [NotesEditOperation] in
            state.editScripts.isEmpty ? [] : state.editScripts.removeFirst()
        }
        return NotesEditorResult(operations: operations, usage: nil)
    }

    func anchorTimecodes(
        meetingID: MeetingID, purpose: CloudSpendPurpose,
        prepare: @escaping @Sendable () async throws -> TimecodeAnchoring.Prompt?
    ) async throws -> TimecodeAnchoring.Answer? {
        try await chain.run {
            guard let prompt = try await prepare() else { return nil }
            let (gate, script) = self.state.withLock { state -> (EditorGate?, AnchorScript) in
                state.anchorCalls.append(Call(
                    meetingID: meetingID, purpose: purpose, structured: prompt.structured))
                let gate = state.anchorGates.isEmpty ? nil : state.anchorGates.removeFirst()
                let script = state.anchorScripts.isEmpty ? .answerAll : state.anchorScripts.removeFirst()
                return (gate, script)
            }
            if let gate { await gate.enterAndWait() }
            switch script {
            case .answerAll:
                return TimecodeAnchoring.Answer(prompt: prompt, response: Self.answerAll(prompt))
            case .answer(let build):
                return TimecodeAnchoring.Answer(prompt: prompt, response: build(prompt))
            case .error(let error):
                throw error
            }
        }
    }

    static func answerAll(_ prompt: TimecodeAnchoring.Prompt, ord: Int? = nil) -> String {
        let segment = ord ?? prompt.segments[0].ord
        let entries = prompt.items.map { #"{"item":\#($0.number),"segment":\#(segment),"quote":null}"# }
        return #"{"anchors":[\#(entries.joined(separator: ","))]}"#
    }

    var calls: [Call] { state.withLock { $0.anchorCalls } }

    func holdNextNotes() -> EditorGate {
        let gate = EditorGate()
        state.withLock { $0.notesGate = gate }
        return gate
    }

    func holdNextAnchoring() -> EditorGate {
        let gate = EditorGate()
        state.withLock { $0.anchorGates.append(gate) }
        return gate
    }

    func script(_ script: AnchorScript) { state.withLock { $0.anchorScripts.append(script) } }
    func setNotes(_ notes: NotesStructured) { state.withLock { $0.notes = notes } }
    func scriptEdit(_ operations: [NotesEditOperation]) {
        state.withLock { $0.editScripts.append(operations) }
    }
}

struct TimecodeHarness {
    let root: URL
    let database: BlaiseDatabase
    let pipeline: ProcessingPipeline
    let engine: AnchoringStubEngine

    var settings: SettingsStore { SettingsStore(database: database) }

    func importAndProcess() async throws -> Meeting {
        let wav = root.appendingPathComponent("source-\(UUID().uuidString).wav")
        try writeTestWAV(to: wav)
        let meeting = try await pipeline.importMeeting(
            sourceURL: wav, title: "Quoll Harbor sync", startedAt: msDate())
        _ = try await pipeline.process(meetingID: meeting.id)
        return meeting
    }

    func rows(_ id: MeetingID) async throws -> [NotesTimecode] {
        try await database.pool.read { db in try NotesTimecodeStore.all(db, meetingID: id) }
    }

    func notes(_ id: MeetingID) async throws -> MeetingNotes {
        try #require(try await NotesRepository(database: database).fetch(meetingID: id))
    }

    /// The marks the pane would draw: rendered block text → placed seconds.
    func marks(_ id: MeetingID) async throws -> [String: Double] {
        let structured = try await notes(id).structured
        let rows = try await self.rows(id)
        var marks: [String: Double] = [:]
        for block in TimecodeAnchoring.markableBlocks(of: structured) {
            if let row = rows.first(where: {
                $0.section == block.id.section && $0.itemHash == block.hash
            }) {
                marks[block.text] = row.startSeconds
            }
        }
        return marks
    }

    func setSwitch(_ on: Bool) async throws {
        try await NotesEditingSettings.setTimecodeLinks(on, in: settings)
    }

    /// A ready meeting with these notes and transcript, and rows seeded for
    /// the given (section, rendered text, seconds).
    func seed(
        notes: NotesStructured,
        segments: [(label: String, name: String?, text: String)] = [
            ("S0", "Dana Marsh", "We keep crane four down and book the inspector."),
        ],
        rows: [(MeetingCorrection.Section, String, Double)] = []
    ) async throws -> MeetingID {
        let id = ULID.generate()
        let timestamp = msDate()
        let meeting = Meeting(
            id: id, title: "Quoll Harbor sync", titleSource: .user,
            startedAt: timestamp.addingTimeInterval(-300), endedAt: timestamp,
            source: .meet, status: .ready, attendees: [], dominantLanguage: "en",
            asrProvenance: ASRProvenance(
                engine: "test", model: "test", runtime: "test", engineVersion: "1",
                transcribedAt: timestamp),
            createdAt: timestamp.addingTimeInterval(-300), updatedAt: timestamp)
        try database.paths.createMeetingDirectory(id)
        try await MeetingRepository(database: database).create(meeting)
        _ = try await TranscriptRepository(database: database).replaceAllSegments(
            meetingID: id,
            with: segments.enumerated().map { index, segment in
                TranscriptSegment(
                    meetingID: id, ord: index, startSeconds: Double(index * 10),
                    endSeconds: Double(index * 10 + 8), speakerLabel: segment.label,
                    speakerName: segment.name, text: segment.text)
            })
        let diarization = DiarizationOutput(
            segments: segments.enumerated().map { index, segment in
                DiarizedSegment(
                    speakerLabel: segment.label, startSeconds: Double(index * 10),
                    endSeconds: Double(index * 10 + 8))
            },
            speakerCount: Set(segments.map(\.label)).count)
        try JSONEncoder().encode(diarization).write(to: database.paths.diarizationURL(id))
        let markdown = try NotesRenderer.render(
            notes, language: "en", meetingTitle: meeting.title,
            userName: UserIdentity.onboardedUser.name, annotations: [])
        try await NotesRepository(database: database).upsert(MeetingNotes(
            meetingID: id, markdown: markdown, structured: notes, language: "en",
            generatedAt: timestamp,
            provenance: NotesProvenance(
                engine: "seed", model: "seed", pipelineVersion: "seed", runtime: "seed",
                rendererVersion: NotesRenderer.version, promptVersion: "seed")))
        try Data(markdown.utf8).write(to: database.paths.notesURL(id), options: .atomic)
        try await database.pool.write { db in
            try NotesTimecodeStore.replace(db, meetingID: id, with: rows.map { section, text, seconds in
                NotesTimecode(
                    meetingID: id, section: section, itemHash: TimecodeAnchoring.itemHash(text),
                    startSeconds: seconds, segmentOrd: 0, track: .system)
            })
        }
        return id
    }

    /// One AI Correct pass with these operations.
    func aiCorrect(_ id: MeetingID, _ operations: [NotesEditOperation]) async throws {
        engine.scriptEdit(operations)
        try await database.pool.write { db in
            try MeetingCorrectionStore.insert(db, MeetingCorrection(
                meetingID: id, kind: .understanding, section: .summary,
                quotedText: "Harbor", userText: "Fix it", createdAt: msDate()))
        }
        try await pipeline.editPendingNotes(meetingID: id)
    }
}

func makeTimecodeHarness(
    notes: NotesStructured = TimecodeFixtures.notes, otherEngines: [any SummarizationEngine] = []
) async throws -> TimecodeHarness {
    let root = try makeTempRoot()
    let tempDir = root.appendingPathComponent("pipeline-tmp", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    let database = try BlaiseDatabase(rootURL: root)
    let asr = PipelineMockASR()
    let engine = AnchoringStubEngine(notes: notes)
    let registry = try EngineRegistry(asr: [asr], summarization: [engine] + otherEngines)
    let settings = SettingsStore(database: database)
    try await settings.set(EngineResolver.asrSettingsKey, to: asr.id)
    try await settings.set(EngineResolver.summarizationSettingsKey, to: engine.id)
    try await settings.set(UserIdentity.settingsKey, to: UserIdentity.onboardedUser)
    let pipeline = ProcessingPipeline(
        database: database, registry: registry, diarizer: PipelineMockDiarizer(),
        vocabulary: try VocabFixtures.pipelineVocabulary(),
        voiceProfileStore: VoiceProfileStore(paths: database.paths),
        tempDirectory: tempDir,
        notesEditorSleep: { _ in throw CancellationError() },
        settleSleep: { _ in throw CancellationError() })
    return TimecodeHarness(root: root, database: database, pipeline: pipeline, engine: engine)
}

private func paragraphs(_ blocks: String...) -> NotesStructured {
    NotesStructured(
        title: "Quoll Harbor sync", summary: "Harbor review.",
        detailedNotes: blocks.joined(separator: "\n\n"), decisions: [], actionItems: [],
        userActionItems: [])
}

private func decisions(_ items: String...) -> NotesStructured {
    NotesStructured(
        title: "Quoll Harbor sync", summary: "Harbor review.", detailedNotes: "",
        decisions: items, actionItems: [], userActionItems: [])
}

private func replace(_ find: String, _ with: String) -> NotesEditOperation {
    .replace(field: .detailedNotes, find: find, replace: with, instruction: 1)
}

// MARK: - T-4

@Suite struct TimecodeTriggerTests {
    @Test func fullRunAndNotesOnlyRunEachMakeOneCallAfterTheCommit() async throws {
        let harness = try await makeTimecodeHarness()
        let meeting = try await harness.importAndProcess()
        _ = await harness.pipeline.awaitTimecodeAnchoring(meetingID: meeting.id)
        #expect(harness.engine.calls.count == 1)
        #expect(harness.engine.calls.first?.purpose == .generation)
        // The call read the committed notes row.
        #expect(harness.engine.calls.first?.structured == (try await harness.notes(meeting.id)).structured)
        #expect(try await harness.rows(meeting.id).count == 10)

        _ = try await harness.pipeline.rewriteNotes(meetingID: meeting.id)
        _ = await harness.pipeline.awaitTimecodeAnchoring(meetingID: meeting.id)
        #expect(harness.engine.calls.count == 2)
        #expect(harness.engine.calls.last?.purpose == .regeneration)
    }

    @Test func switchOffMakesNoCall() async throws {
        let harness = try await makeTimecodeHarness()
        try await harness.setSwitch(false)
        let meeting = try await harness.importAndProcess()
        _ = await harness.pipeline.awaitTimecodeAnchoring(meetingID: meeting.id)
        await harness.pipeline.generateTimestamps(meetingID: meeting.id)
        _ = await harness.pipeline.awaitTimecodeAnchoring(meetingID: meeting.id)
        #expect(harness.engine.calls.isEmpty)
        #expect(try await harness.rows(meeting.id).isEmpty)
    }

    @Test func aNonConformingEngineMakesNoCall() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        #expect(await harness.pipeline.awaitTimecodeAnchoring(meetingID: meeting.id).isEmpty)
        #expect(await harness.pipeline.anchorTimecodes(meetingID: meeting.id) == .noCall)
    }

    /// The call goes to the engine that wrote the notes, not to whatever
    /// Settings names by the time the run ends.
    @Test func aSettingsChangeDuringSynthesisKeepsTheNotesEngine() async throws {
        let other = PipelineMockNotes(id: "pipeline-mock-notes-other")
        let harness = try await makeTimecodeHarness(otherEngines: [other])
        let gate = harness.engine.holdNextNotes()
        let run = Task { try await harness.importAndProcess() }
        await gate.waitUntilEntered()
        try await harness.settings.set(EngineResolver.summarizationSettingsKey, to: other.id)
        gate.release()
        let meeting = try await run.value
        _ = await harness.pipeline.awaitTimecodeAnchoring(meetingID: meeting.id)
        #expect(harness.engine.calls.map(\.meetingID) == [meeting.id])
    }

    @Test func notesWrittenByANonConformingEngineMakeNoCallAfterASettingsChange() async throws {
        let other = PipelineMockNotes(id: "pipeline-mock-notes-other")
        let harness = try await makeTimecodeHarness(otherEngines: [other])
        try await harness.settings.set(EngineResolver.summarizationSettingsKey, to: other.id)
        let gate = EditorGate()
        other.state.withLock { $0.onGenerate = { await gate.enterAndWait() } }
        let run = Task { try await harness.importAndProcess() }
        await gate.waitUntilEntered()
        try await harness.settings.set(EngineResolver.summarizationSettingsKey, to: harness.engine.id)
        gate.release()
        let meeting = try await run.value
        _ = await harness.pipeline.awaitTimecodeAnchoring(meetingID: meeting.id)
        #expect(harness.engine.calls.isEmpty)
    }

    @Test func notesWrittenByTheFallbackEngineAnchorOnIt() async throws {
        let primary = PipelineMockNotes(id: "pipeline-mock-notes-primary")
        primary.state.withLock { $0.error = .configurationMissing(key: "fictional-key") }
        let harness = try await makeTimecodeHarness(otherEngines: [primary])
        try await harness.settings.set(EngineResolver.summarizationSettingsKey, to: primary.id)
        let meeting = try await harness.importAndProcess()
        _ = await harness.pipeline.awaitTimecodeAnchoring(meetingID: meeting.id)
        #expect(harness.engine.calls.map(\.meetingID) == [meeting.id])
    }

    @Test func zeroItemsOrZeroSegmentsMakeNoCall() async throws {
        let harness = try await makeTimecodeHarness(notes: NotesStructured(
            title: "Quoll Harbor sync", summary: "Only a summary.", detailedNotes: "## Heading",
            decisions: [], actionItems: [], userActionItems: []))
        let meeting = try await harness.importAndProcess()
        _ = await harness.pipeline.awaitTimecodeAnchoring(meetingID: meeting.id)
        let noSegments = try await harness.seed(notes: decisions("Row C only."), segments: [])
        #expect(await harness.pipeline.anchorTimecodes(meetingID: noSegments) == .noCall)
        #expect(harness.engine.calls.isEmpty)
    }

    @Test func theRunCompletesWhileTheCallIsHeld() async throws {
        let harness = try await makeTimecodeHarness()
        let gate = harness.engine.holdNextAnchoring()
        let events = await harness.pipeline.events()
        let completed = Task { () -> Bool in
            for await event in events { if case .runCompleted = event { return true } }
            return false
        }
        let meeting = try await harness.importAndProcess()
        await gate.waitUntilEntered()
        #expect(await completed.value)
        #expect(try await harness.rows(meeting.id).isEmpty)
        gate.release()
        _ = await harness.pipeline.awaitTimecodeAnchoring(meetingID: meeting.id)
        #expect(try await harness.rows(meeting.id).count == 10)
    }

    @Test func twoGenerateTimestampsClicksMakeTwoCalls() async throws {
        let harness = try await makeTimecodeHarness()
        let id = try await harness.seed(notes: decisions("Row C only.", "Night shift stays."))
        await harness.pipeline.generateTimestamps(meetingID: id)
        await harness.pipeline.generateTimestamps(meetingID: id)
        _ = await harness.pipeline.awaitTimecodeAnchoring(meetingID: id)
        #expect(harness.engine.calls.map(\.purpose) == [.regeneration, .regeneration])
    }

    /// A failed call leaves everything exactly as the notes commit left it.
    @Test(arguments: [
        AnchoringStubEngine.AnchorScript.error(.permanent("boom")),
        .error(.transient("claude -p timed out")),
        .answer { _ in "not json at all" },
        .answer { _ in #"{"links":[]}"# },
    ])
    func aFailingCallChangesNothing(_ script: AnchoringStubEngine.AnchorScript) async throws {
        let harness = try await makeTimecodeHarness()
        harness.engine.script(script)
        let gate = harness.engine.holdNextAnchoring()
        let meeting = try await harness.importAndProcess()
        await gate.waitUntilEntered()
        let before = try await snapshot(harness, meeting.id)
        gate.release()
        _ = await harness.pipeline.awaitTimecodeAnchoring(meetingID: meeting.id)
        #expect(harness.engine.calls.count == 1)
        #expect(try await snapshot(harness, meeting.id) == before)
        #expect(try await harness.rows(meeting.id).isEmpty)

        harness.engine.script(script)
        let outcome = await harness.pipeline.anchorTimecodes(meetingID: meeting.id)
        #expect(outcome == .failed || outcome == .unparseable)
        #expect(try await harness.rows(meeting.id).isEmpty)
    }

    private func snapshot(_ harness: TimecodeHarness, _ id: MeetingID) async throws -> [String] {
        let notes = try await harness.notes(id)
        let meeting = try #require(try await MeetingRepository(database: harness.database).fetch(id))
        let file = try String(contentsOf: harness.database.paths.notesURL(id), encoding: .utf8)
        let queue = try await harness.database.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM handoff_queue WHERE meeting_id = ? ORDER BY rowid", arguments: [id])
                .map { $0.description }
        }
        let notesRow = try await harness.database.pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM meeting_notes WHERE meeting_id = ?", arguments: [id])?
                .description ?? ""
        }
        return [
            notesRow, notes.markdown, file, meeting.status.rawValue,
            meeting.lastProcessingError ?? "nil",
        ] + queue
    }

    @Test func aMeetingDeletedWhileItsCallWaitsMakesNoCall() async throws {
        let harness = try await makeTimecodeHarness()
        let first = try await harness.seed(notes: decisions("Row C only."))
        let second = try await harness.seed(notes: decisions("Night shift stays."))
        let gate = harness.engine.holdNextAnchoring()
        await harness.pipeline.generateTimestamps(meetingID: first)
        await gate.waitUntilEntered()
        await harness.pipeline.generateTimestamps(meetingID: second)
        try await harness.pipeline.deleteMeeting(meetingID: second)
        gate.release()
        _ = await harness.pipeline.awaitTimecodeAnchoring(meetingID: first)
        _ = await harness.pipeline.awaitTimecodeAnchoring(meetingID: second)
        #expect(harness.engine.calls.map(\.meetingID) == [first])
    }
}

// MARK: - T-6 lists (AI Correct)

@Suite struct TimecodeListCarryTests {
    private let rows: [(MeetingCorrection.Section, String, Double)] = [
        (.decision, "Row C approved.", 100), (.decision, "Couch co-op stays in beta.", 200),
    ]

    private func seeded() async throws -> (TimecodeHarness, MeetingID) {
        let harness = try await makeTimecodeHarness()
        let id = try await harness.seed(
            notes: decisions("Row C approved.", "Couch co-op stays in beta.", "Night shift stays."),
            rows: rows)
        return (harness, id)
    }

    private func set(_ index: Int, _ text: String) -> NotesEditOperation {
        .set(field: .decisions, index: index, patch: NotesItemPatch(owner: nil, text: text), instruction: 1)
    }

    private func insert(_ index: Int?, _ text: String) -> NotesEditOperation {
        .insert(field: .decisions, index: index, patch: NotesItemPatch(owner: nil, text: text), instruction: 1)
    }

    private func remove(_ index: Int) -> NotesEditOperation {
        .remove(field: .decisions, index: index, instruction: 1)
    }

    @Test func setKeepsTheMarkUnderTheNewText() async throws {
        let (harness, id) = try await seeded()
        try await harness.aiCorrect(id, [set(0, "Row C approved for reefers.")])
        #expect(try await harness.marks(id) == [
            "Row C approved for reefers.": 100, "Couch co-op stays in beta.": 200,
        ])
    }

    @Test func removeDropsInsertGetsNone() async throws {
        let (harness, id) = try await seeded()
        try await harness.aiCorrect(id, [remove(0), insert(nil, "Crane 4 stays down.")])
        #expect(try await harness.marks(id) == ["Couch co-op stays in beta.": 200])
        #expect(try await harness.rows(id).count == 1)
    }

    @Test func aVerbatimReinsertGetsNone() async throws {
        let (harness, id) = try await seeded()
        try await harness.aiCorrect(id, [remove(0), insert(0, "Row C approved.")])
        #expect(try await harness.marks(id) == ["Couch co-op stays in beta.": 200])
    }

    @Test func removeOneAndInsertAnotherGetsNone() async throws {
        let (harness, id) = try await seeded()
        try await harness.aiCorrect(id, [remove(0), insert(0, "Row D approved.")])
        #expect(try await harness.marks(id) == ["Couch co-op stays in beta.": 200])
    }

    @Test func deleteAnchoredAThenSetUnanchoredB() async throws {
        let (harness, id) = try await seeded()
        try await harness.aiCorrect(id, [remove(0), set(1, "Night shift stays on.")])
        #expect(try await harness.marks(id) == ["Couch co-op stays in beta.": 200])
    }

    @Test func anOutOfRangeOperationChangesNothing() async throws {
        let (harness, id) = try await seeded()
        try await harness.aiCorrect(id, [remove(9), set(7, "Nowhere."), set(1, "Couch co-op stays in the beta.")])
        #expect(try await harness.marks(id) == [
            "Row C approved.": 100, "Couch co-op stays in the beta.": 200,
        ])
    }

    @Test func aSetWithARawLabelKeepsItsMarkUnderTheNeutralizedText() async throws {
        let (harness, id) = try await seeded()
        try await harness.aiCorrect(id, [set(0, "S0 approved row C.")])
        let text = try await harness.notes(id).structured.decisions[0]
        #expect(text == "Dana Marsh approved row C.")
        #expect(try await harness.marks(id)[text] == 100)
    }
}

// MARK: - T-6 detailed notes (AI Correct)

@Suite struct TimecodeDetailedCarryTests {
    private let blocks = [
        "Crane 4 stays out of service.", "Nia will book the inspector.",
        "The reefer upgrade is approved for row C.", "Quoll Harbor keeps the night shift.",
    ]

    private func seeded(
        _ notes: NotesStructured? = nil, rows: [(MeetingCorrection.Section, String, Double)]? = nil
    ) async throws -> (TimecodeHarness, MeetingID) {
        let harness = try await makeTimecodeHarness()
        let seededRows = rows ?? blocks.enumerated().map {
            (.detailedNotes, $0.element, Double($0.offset + 1) * 100)
        }
        let id = try await harness.seed(
            notes: notes ?? NotesStructured(
                title: "Quoll Harbor sync", summary: "Harbor review.",
                detailedNotes: blocks.joined(separator: "\n\n"), decisions: [],
                actionItems: [], userActionItems: []),
            rows: seededRows)
        return (harness, id)
    }

    @Test func unchangedTextKeepsItsMarkWhenMoved() async throws {
        let (harness, id) = try await seeded()
        try await harness.aiCorrect(id, [replace(
            "Crane 4 stays out of service.\n\nNia will book the inspector.",
            "Nia will book the inspector.\n\nCrane 4 stays out of service.")])
        #expect(try await harness.marks(id) == [
            "Crane 4 stays out of service.": 100, "Nia will book the inspector.": 200,
            "The reefer upgrade is approved for row C.": 300,
            "Quoll Harbor keeps the night shift.": 400,
        ])
    }

    @Test func aRewrittenBlockLosesItsMark() async throws {
        let (harness, id) = try await seeded()
        try await harness.aiCorrect(id, [replace("row C", "row D")])
        #expect(try await harness.marks(id) == [
            "Crane 4 stays out of service.": 100, "Nia will book the inspector.": 200,
            "Quoll Harbor keeps the night shift.": 400,
        ])
    }

    @Test func oneFindInBlocksOneAndThreeLeavesBlockTwo() async throws {
        let text = ["Vexatron Labs keeps crane 4 down.", "Nia will book the inspector.", "Vexatron Labs approved row C."]
        let (harness, id) = try await seeded(
            paragraphs(text[0], text[1], text[2]),
            rows: text.enumerated().map { (.detailedNotes, $0.element, Double($0.offset + 1) * 100) })
        try await harness.aiCorrect(id, [replace("Vexatron Labs", "Vexatron")])
        #expect(try await harness.marks(id) == ["Nia will book the inspector.": 200])
    }

    @Test func emphasisOnlyKeepsTheMark() async throws {
        let (harness, id) = try await seeded(
            paragraphs("The reefer upgrade is approved for **row C**."),
            rows: [(.detailedNotes, "The reefer upgrade is approved for row C.", 300)])
        try await harness.aiCorrect(id, [replace("**row C**", "row C")])
        #expect(try await harness.marks(id) == ["The reefer upgrade is approved for row C.": 300])
    }

    @Test func caseOnlyLosesTheMark() async throws {
        let (harness, id) = try await seeded()
        try await harness.aiCorrect(id, [replace("Quoll Harbor keeps", "quoll harbor keeps")])
        #expect(try await harness.marks(id)["quoll harbor keeps the night shift."] == nil)
        #expect(try await harness.marks(id).count == 3)
    }

    /// The folds are equal, the texts are not.
    @Test func aFoldEqualRewriteIntoADeletedBlocksTextGetsNone() async throws {
        let (harness, id) = try await seeded(
            paragraphs("Vexatron Labs selected C#.", "Another paragraph stays."),
            rows: [(.detailedNotes, "Vexatron Labs selected C#.", 100),
                   (.detailedNotes, "Another paragraph stays.", 200)])
        try await harness.aiCorrect(id, [
            replace("Vexatron Labs selected C#.\n\n", ""),
            replace("Another paragraph stays.", "Vexatron Labs selected C."),
        ])
        #expect(try await harness.notes(id).structured.detailedNotes == "Vexatron Labs selected C.")
        #expect(try await harness.marks(id).isEmpty)
        #expect(try await harness.rows(id).isEmpty)
    }

    @Test func theTBDCleanupKeepsOnlyTheUntouchedBullet() async throws {
        let bullets = ["Crane 4 date TBD", "Inspector visit TBD", "Night shift stays"]
        let (harness, id) = try await seeded(
            paragraphs(bullets.map { "- " + $0 }.joined(separator: "\n")),
            rows: bullets.enumerated().map { (.detailedNotes, $0.element, Double($0.offset + 1) * 100) })
        try await harness.aiCorrect(id, [replace(" TBD", "")])
        #expect(try await harness.marks(id) == ["Night shift stays": 300])
    }

    @Test func deleteARewriteBIntoAsTextGivesBAsMark() async throws {
        let (harness, id) = try await seeded()
        try await harness.aiCorrect(id, [
            replace("Crane 4 stays out of service.\n\n", ""),
            replace("Nia will book the inspector.", "Crane 4 stays out of service."),
        ])
        #expect(try await harness.marks(id) == [
            "Crane 4 stays out of service.": 100,
            "The reefer upgrade is approved for row C.": 300,
            "Quoll Harbor keeps the night shift.": 400,
        ])
    }

    @Test func aParagraphTurnedIntoAHeadingGetsNone() async throws {
        let (harness, id) = try await seeded()
        try await harness.aiCorrect(id, [replace(
            "Quoll Harbor keeps the night shift.", "## Quoll Harbor keeps the night shift.")])
        #expect(try await harness.marks(id)["Quoll Harbor keeps the night shift."] == nil)
        #expect(try await harness.rows(id).count == 3)
    }

    @Test func aHardBreakTurnedIntoOneSpaceKeepsTheMark() async throws {
        let (harness, id) = try await seeded(
            paragraphs("Nia will book\\\nthe inspector."),
            rows: [(.detailedNotes, "Nia will book the inspector.", 200)])
        #expect(try await harness.marks(id).values.first == 200)
        try await harness.aiCorrect(id, [replace("book\\\nthe", "book the")])
        #expect(try await harness.marks(id) == ["Nia will book the inspector.": 200])
    }

    @Test func aDoubledSpaceTurnedIntoOneKeepsTheMark() async throws {
        let (harness, id) = try await seeded(
            paragraphs("Nia will book  the inspector."),
            rows: [(.detailedNotes, "Nia will book the inspector.", 200)])
        try await harness.aiCorrect(id, [replace("book  the", "book the")])
        #expect(try await harness.marks(id) == ["Nia will book the inspector.": 200])
    }

    @Test func anEditThatMakesTwinsLeavesNeitherARow() async throws {
        let (harness, id) = try await seeded(
            paragraphs("Couch co-op stays in the closed beta.", "Couch co-op stays in closed beta.", "Night shift stays."),
            rows: [(.detailedNotes, "Couch co-op stays in the closed beta.", 100),
                   (.detailedNotes, "Couch co-op stays in closed beta.", 200),
                   (.detailedNotes, "Night shift stays.", 300)])
        try await harness.aiCorrect(id, [replace("stays in closed beta", "stays in the closed beta")])
        #expect(try await harness.marks(id) == ["Night shift stays.": 300])
        #expect(try await harness.rows(id).count == 1)
    }

    /// An answer that landed while the editor ran is carried, not wiped.
    @Test func anAnswerThatLandsDuringTheEditorIsCarried() async throws {
        let harness = try await makeTimecodeHarness()
        let id = try await harness.seed(notes: paragraphs(
            "Crane 4 stays out of service.", "Nia will book the inspector."))
        let anchoringGate = harness.engine.holdNextAnchoring()
        let anchoring = Task { await harness.pipeline.anchorTimecodes(meetingID: id) }
        await anchoringGate.waitUntilEntered()
        let editorGate = EditorGate()
        harness.engine.state.withLock { $0.editorGate = editorGate }
        let editor = Task { try await harness.aiCorrect(id, [replace("Nia will", "Nia shall")]) }
        await editorGate.waitUntilEntered()
        anchoringGate.release()
        #expect(await anchoring.value == .written(2))
        editorGate.release()
        try await editor.value
        #expect(try await harness.marks(id) == ["Crane 4 stays out of service.": 0])
    }
}

// MARK: - T-6 renames, corrections, re-mints, new notes

@Suite struct TimecodeRewriteTests {
    @Test func aSpeakerRenameMovesMarksByPosition() async throws {
        let harness = try await makeTimecodeHarness()
        let id = try await harness.seed(
            notes: NotesStructured(
                title: "Quoll Harbor sync", summary: "Harbor review.",
                detailedNotes: "S0 will call Nia about crane 4.", decisions: ["S0 agreed."],
                actionItems: [], userActionItems: []),
            segments: [("S0", nil, "I agree, I will call Nia.")],
            rows: [(.decision, "S0 agreed.", 100), (.detailedNotes, "S0 will call Nia about crane 4.", 150)])
        _ = try await harness.pipeline.renameSpeaker(meetingID: id, speakerLabel: "S0", to: "Dana Marsh")
        #expect(try await harness.marks(id) == [
            "Dana Marsh agreed.": 100, "Dana Marsh will call Nia about crane 4.": 150,
        ])
    }

    @Test func aNameCorrectionKeepsTheMark() async throws {
        let harness = try await makeTimecodeHarness()
        let id = try await harness.seed(
            notes: decisions("Nia booked the inspector.", "Row C only."),
            rows: [(.decision, "Nia booked the inspector.", 100), (.decision, "Row C only.", 200)])
        let count = try await harness.pipeline.correctNameInNotes(
            meetingID: id, original: "Nia", replacement: "Nya", allOccurrences: true)
        #expect(count == 1)
        #expect(try await harness.marks(id) == ["Nya booked the inspector.": 100, "Row C only.": 200])
    }

    @Test func aRenameThatMakesTwinsLeavesNeitherARow() async throws {
        let harness = try await makeTimecodeHarness()
        let id = try await harness.seed(
            notes: decisions(
                "S0 will send the reefer quote.", "S1 will send the reefer quote.",
                "Quoll Harbor keeps the night shift."),
            segments: [("S0", nil, "I will send it."), ("S1", "Ilse Brandt", "Me too.")],
            rows: [(.decision, "S0 will send the reefer quote.", 100),
                   (.decision, "S1 will send the reefer quote.", 200),
                   (.decision, "Quoll Harbor keeps the night shift.", 300)])
        _ = try await harness.pipeline.renameSpeaker(meetingID: id, speakerLabel: "S0", to: "Ilse Brandt")
        #expect(try await harness.marks(id) == ["Quoll Harbor keeps the night shift.": 300])
        #expect(try await harness.rows(id).count == 1)
    }

    @Test func aTitleRenameKeepsEveryMatch() async throws {
        let harness = try await makeTimecodeHarness()
        let id = try await harness.seed(
            notes: decisions("Row C only.", "Night shift stays."),
            rows: [(.decision, "Row C only.", 100), (.decision, "Night shift stays.", 200)])
        _ = try await harness.pipeline.renameMeeting(meetingID: id, to: "Vexatron Labs harbor review")
        #expect(try await harness.marks(id) == ["Row C only.": 100, "Night shift stays.": 200])
    }

    @Test func aRegenerationsCallReplacesAllRows() async throws {
        let harness = try await makeTimecodeHarness()
        let meeting = try await harness.importAndProcess()
        _ = await harness.pipeline.awaitTimecodeAnchoring(meetingID: meeting.id)
        harness.engine.setNotes(decisions("Row C only."))
        _ = try await harness.pipeline.rewriteNotes(meetingID: meeting.id)
        _ = await harness.pipeline.awaitTimecodeAnchoring(meetingID: meeting.id)
        let rows = try await harness.rows(meeting.id)
        #expect(rows.count == 1)
        #expect(rows.first?.itemHash == TimecodeAnchoring.itemHash("Row C only."))
    }

    private let anchoredCSharp = NotesStructured(
        title: "Quoll Harbor sync", summary: "Harbor review.",
        detailedNotes: "Vexatron Labs selected C#.\n\nAnother paragraph stays.", decisions: [],
        actionItems: [], userActionItems: [])
    private let regeneratedC = NotesStructured(
        title: "Quoll Harbor sync", summary: "Harbor review.",
        detailedNotes: "Vexatron Labs selected C.\n\nAnother paragraph stays.", decisions: [],
        actionItems: [], userActionItems: [])

    /// Every write that installs new notes clears the rows before the call,
    /// fold-equal text included.
    @Test(arguments: [false, true])
    func eachNewNotesInstallLeavesNoRowsBeforeItsCall(notesOnly: Bool) async throws {
        let harness = try await makeTimecodeHarness(notes: anchoredCSharp)
        let meeting = try await harness.importAndProcess()
        _ = await harness.pipeline.awaitTimecodeAnchoring(meetingID: meeting.id)
        #expect(try await harness.rows(meeting.id).count == 2)
        harness.engine.setNotes(regeneratedC)
        let gate = harness.engine.holdNextAnchoring()
        if notesOnly {
            _ = try await harness.pipeline.rewriteNotes(meetingID: meeting.id)
        } else {
            _ = try await harness.pipeline.regenerate(meetingID: meeting.id)
        }
        await gate.waitUntilEntered()
        #expect(try await harness.rows(meeting.id).isEmpty)
        #expect(try await harness.marks(meeting.id).isEmpty)
        gate.release()
        _ = await harness.pipeline.awaitTimecodeAnchoring(meetingID: meeting.id)
        #expect(try await harness.rows(meeting.id).count == 2)
    }

    /// Regenerate to fold-equal text, the call fails, then an AI Correct of
    /// another paragraph: the new text never carries the old mark.
    @Test func aFailedCallAfterRegenerationLeavesNoMarkThroughAnAICorrect() async throws {
        let harness = try await makeTimecodeHarness(notes: anchoredCSharp)
        let meeting = try await harness.importAndProcess()
        _ = await harness.pipeline.awaitTimecodeAnchoring(meetingID: meeting.id)
        harness.engine.setNotes(regeneratedC)
        harness.engine.script(.error(.permanent("boom")))
        _ = try await harness.pipeline.rewriteNotes(meetingID: meeting.id)
        _ = await harness.pipeline.awaitTimecodeAnchoring(meetingID: meeting.id)
        #expect(harness.engine.calls.count == 2)
        try await harness.aiCorrect(meeting.id, [replace("Another paragraph stays.", "Another paragraph moved.")])
        #expect(try await harness.marks(meeting.id)["Vexatron Labs selected C."] == nil)
        #expect(try await harness.rows(meeting.id).isEmpty)
    }

    @Test func aFullRunFailingBetweenItsInstallAndFinalizeLeavesNoRow() async throws {
        let harness = try await makeTimecodeHarness(notes: anchoredCSharp)
        let meeting = try await harness.importAndProcess()
        _ = await harness.pipeline.awaitTimecodeAnchoring(meetingID: meeting.id)
        harness.engine.setNotes(regeneratedC)
        let handoff = harness.database.paths.meetingDirectory(meeting.id)
            .appendingPathComponent("handoff", isDirectory: true)
        try FileManager.default.createDirectory(at: handoff, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: handoff.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: handoff.path)
        }
        await #expect(throws: (any Error).self) {
            _ = try await harness.pipeline.regenerate(meetingID: meeting.id)
        }
        #expect(try await harness.notes(meeting.id).structured == regeneratedC)
        #expect(harness.engine.calls.count == 1, "no call after a failed run")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: handoff.path)
        try await harness.aiCorrect(meeting.id, [replace("Another paragraph stays.", "Another paragraph moved.")])
        #expect(try await harness.rows(meeting.id).isEmpty)
    }

    @Test func aSwitchedOffRegenerationStillClearsTheRows() async throws {
        let harness = try await makeTimecodeHarness(notes: anchoredCSharp)
        let meeting = try await harness.importAndProcess()
        _ = await harness.pipeline.awaitTimecodeAnchoring(meetingID: meeting.id)
        try await harness.setSwitch(false)
        harness.engine.setNotes(regeneratedC)
        _ = try await harness.pipeline.rewriteNotes(meetingID: meeting.id)
        #expect(try await harness.rows(meeting.id).isEmpty)
        try await harness.setSwitch(true)
        try await harness.aiCorrect(meeting.id, [replace("Another paragraph stays.", "Another paragraph moved.")])
        #expect(try await harness.rows(meeting.id).isEmpty)
        #expect(harness.engine.calls.count == 1)
    }

    @Test func aRenameDuringTheCallMakesTheAnswerStale() async throws {
        let harness = try await makeTimecodeHarness()
        let id = try await harness.seed(
            notes: decisions("S0 agreed.", "Row C only."),
            segments: [("S0", nil, "Agreed.")],
            rows: [(.decision, "S0 agreed.", 100)])
        harness.engine.script(.answer { AnchoringStubEngine.answerAll($0) })
        let gate = harness.engine.holdNextAnchoring()
        let anchoring = Task { await harness.pipeline.anchorTimecodes(meetingID: id) }
        await gate.waitUntilEntered()
        _ = try await harness.pipeline.renameSpeaker(meetingID: id, speakerLabel: "S0", to: "Dana Marsh")
        gate.release()
        #expect(await anchoring.value == .stale)
        #expect(try await harness.marks(id) == ["Dana Marsh agreed.": 100])
    }
}
