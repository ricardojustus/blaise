import Foundation
import GRDB
import Synchronization
import Testing
@testable import BlaiseCore

final class EditorManualClock: @unchecked Sendable {
    private struct Sleeper {
        var deadline: Date
        var continuation: CheckedContinuation<Void, Never>?
        var done = false
    }
    private struct State {
        var instant: Date
        var sleepers: [Int: Sleeper] = [:]
        var nextID = 0
    }
    private let state: Mutex<State>

    init(start: Date = msDate()) {
        state = Mutex(State(instant: start))
    }

    var now: @Sendable () -> Date {
        { [self] in state.withLock { $0.instant } }
    }

    var sleep: @Sendable (Duration) async throws -> Void {
        { [weak self] duration in
            guard let self else { return }
            let id = self.state.withLock { state -> Int in
                let id = state.nextID
                state.nextID += 1
                state.sleepers[id] = Sleeper(
                    deadline: state.instant.addingTimeInterval(duration.editorSeconds))
                return id
            }
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let resumeNow = self.state.withLock { state -> Bool in
                        guard var sleeper = state.sleepers[id] else { return true }
                        if sleeper.done { return true }
                        sleeper.continuation = continuation
                        state.sleepers[id] = sleeper
                        return false
                    }
                    if resumeNow { continuation.resume() }
                }
            } onCancel: {
                self.wake(id)
            }
            if Task.isCancelled { throw CancellationError() }
        }
    }

    var activeSleeperCount: Int {
        state.withLock { $0.sleepers.values.filter { !$0.done }.count }
    }

    func advance(by duration: Duration) {
        let due = state.withLock { state -> [Int] in
            state.instant = state.instant.addingTimeInterval(duration.editorSeconds)
            return state.sleepers.compactMap { id, sleeper in
                !sleeper.done && sleeper.deadline <= state.instant ? id : nil
            }
        }
        due.forEach(wake)
    }

    private func wake(_ id: Int) {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard var sleeper = state.sleepers[id], !sleeper.done else { return nil }
            sleeper.done = true
            let continuation = sleeper.continuation
            sleeper.continuation = nil
            state.sleepers[id] = sleeper
            return continuation
        }
        continuation?.resume()
    }
}

private extension Duration {
    var editorSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

final class EditorGate: @unchecked Sendable {
    private struct State {
        var entered = false
        var released = false
        var enteredWaiters: [CheckedContinuation<Void, Never>] = []
        var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())

    func enterAndWait() async {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.entered = true
            defer { state.enteredWaiters = [] }
            return state.enteredWaiters
        }
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { state -> Bool in
                if state.released { return true }
                state.releaseWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { state -> Bool in
                if state.entered { return true }
                state.enteredWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func release() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.released = true
            defer { state.releaseWaiters = [] }
            return state.releaseWaiters
        }
        waiters.forEach { $0.resume() }
    }
}

private final class ScriptedNotesEditorEngine:
    SummarizationEngine, NotesEditingEngine, @unchecked Sendable
{
    enum Outcome: Sendable {
        case result([NotesEditOperation])
        case error(EngineError)
    }

    struct State {
        var outcomes: [Outcome] = []
        var requests: [NotesEditorRequest] = []
        var purposes: [CloudSpendPurpose] = []
        var prepareCalls = 0
        var fullNotesCalls = 0
        var digestCalls = 0
        var activeCalls = 0
        var maximumActiveCalls = 0
        var callOrder: [MeetingID] = []
        var gate: EditorGate?
        var availability: EngineAvailability = .available
    }

    let id: String
    let displayName = "Scripted notes editor"
    let kind: EngineKind = .cloud
    let loadProfile: EngineLoadProfile = .lightweight
    let costDescriptor: EngineCostDescriptor? = nil
    let configDescriptors: [EngineConfigDescriptor] = []
    let state = Mutex(State())

    init(id: String = "scripted-notes-editor") {
        self.id = id
    }

    func availability() async -> EngineAvailability {
        state.withLock { $0.availability }
    }

    func prepare() async throws {
        state.withLock { $0.prepareCalls += 1 }
    }

    func generateNotes(
        _ request: NotesRequest, purpose: CloudSpendPurpose
    ) async throws -> NotesResult {
        state.withLock { $0.fullNotesCalls += 1 }
        throw EngineError.permanent("unexpected full notes call")
    }

    func generateDigest(
        _ request: DigestRequest, purpose: CloudSpendPurpose
    ) async throws -> DigestResult {
        state.withLock { $0.digestCalls += 1 }
        throw EngineError.permanent("unexpected digest call")
    }

    func editNotes(
        _ request: NotesEditorRequest, purpose: CloudSpendPurpose
    ) async throws -> NotesEditorResult {
        let gate = state.withLock { state -> EditorGate? in
            state.requests.append(request)
            state.purposes.append(purpose)
            state.callOrder.append(request.meetingID)
            state.activeCalls += 1
            state.maximumActiveCalls = max(state.maximumActiveCalls, state.activeCalls)
            return state.gate
        }
        defer { state.withLock { $0.activeCalls -= 1 } }
        if let gate { await gate.enterAndWait() }
        let outcome = state.withLock { state -> Outcome in
            guard !state.outcomes.isEmpty else { return .result([]) }
            return state.outcomes.removeFirst()
        }
        switch outcome {
        case .result(let operations):
            return NotesEditorResult(operations: operations, usage: nil)
        case .error(let error):
            throw error
        }
    }

    var callCount: Int { state.withLock { $0.requests.count } }
    var requests: [NotesEditorRequest] { state.withLock { $0.requests } }
    var purposes: [CloudSpendPurpose] { state.withLock { $0.purposes } }
    var maximumActiveCalls: Int { state.withLock { $0.maximumActiveCalls } }
    var fullNotesCallCount: Int { state.withLock { $0.fullNotesCalls } }
    var digestCallCount: Int { state.withLock { $0.digestCalls } }

    func setOutcomes(_ outcomes: [Outcome]) {
        state.withLock { $0.outcomes = outcomes }
    }

    func setGate(_ gate: EditorGate?) {
        state.withLock { $0.gate = gate }
    }
}

private final class BlockingFirstKicker: HandoffKicking, @unchecked Sendable {
    private let gate = EditorGate()
    private let calls = Mutex(0)

    func kick() async {
        let shouldBlock = calls.withLock { calls -> Bool in
            calls += 1
            return calls == 1
        }
        if shouldBlock { await gate.enterAndWait() }
    }

    func waitUntilEntered() async { await gate.waitUntilEntered() }
    func release() { gate.release() }
}

private struct EditorHarness {
    let root: URL
    let database: BlaiseDatabase
    let pipeline: ProcessingPipeline
    let engine: ScriptedNotesEditorEngine
    let clock: EditorManualClock
}

private func makeEditorHarness(
    root: URL? = nil,
    database: BlaiseDatabase? = nil,
    engine: ScriptedNotesEditorEngine = ScriptedNotesEditorEngine(),
    clock: EditorManualClock = EditorManualClock(),
    handoffKicker: any HandoffKicking = NoopHandoffKicker(),
    afterSchedulerDatabaseOperation: (@Sendable (MeetingID) async -> Void)? = nil,
    /// The N2 scenarios pin the EDITOR's own window; the settle window never
    /// fires here (a real ten-minute sleep must never reach a test, and a settle
    /// sleeper on the shared manual clock would perturb every sleeper count).
    settleSleep: @escaping @Sendable (Duration) async throws -> Void = { _ in
        throw CancellationError()
    }
) async throws -> EditorHarness {
    let root = try root ?? makeTempRoot()
    let database = try database ?? BlaiseDatabase(rootURL: root)
    let registry = try EngineRegistry(asr: [], summarization: [engine])
    let settings = SettingsStore(database: database)
    try await settings.set(EngineResolver.summarizationSettingsKey, to: engine.id)
    try await settings.set(UserIdentity.settingsKey, to: UserIdentity.onboardedUser)
    let pipeline = ProcessingPipeline(
        database: database, registry: registry, diarizer: PipelineMockDiarizer(),
        vocabulary: try VocabFixtures.pipelineVocabulary(), handoffKicker: handoffKicker,
        now: clock.now,
        notesEditorSleep: clock.sleep,
        settleSleep: settleSleep,
        afterNotesEditorSchedulerDatabaseOperation: afterSchedulerDatabaseOperation)
    return EditorHarness(
        root: root, database: database, pipeline: pipeline, engine: engine, clock: clock)
}

@discardableResult
private func seedEditorMeeting(
    _ harness: EditorHarness,
    title: String = "Meeting",
    titleSource: TitleSource = .user,
    structured: NotesStructured = NotesStructured(
        title: "Notes", summary: "One Two Three Four",
        detailedNotes: "Details", decisions: ["Decision"],
        actionItems: [ActionItem(owner: "Sam", text: "Action")],
        userActionItems: []),
    lastProcessingError: String? = nil,
    segments: [TranscriptSegment]? = nil
) async throws -> (Meeting, MeetingNotes) {
    let id = ULID.generate()
    let timestamp = harness.clock.now()
    let meeting = Meeting(
        id: id, title: title, titleSource: titleSource,
        startedAt: timestamp.addingTimeInterval(-300), endedAt: timestamp,
        source: .meet, status: .ready, attendees: [], dominantLanguage: "en",
        asrProvenance: ASRProvenance(
            engine: "test", model: "test", runtime: "test", engineVersion: "1",
            transcribedAt: timestamp),
        lastProcessingError: lastProcessingError,
        createdAt: timestamp.addingTimeInterval(-300), updatedAt: timestamp)
    try harness.database.paths.createMeetingDirectory(id)
    try await MeetingRepository(database: harness.database).create(meeting)
    let transcript = segments ?? [
        TranscriptSegment(
            meetingID: id, ord: 0, startSeconds: 0, endSeconds: 1,
            speakerLabel: "S0", speakerName: "Sam", text: "Unchanged transcript")
    ]
    _ = try await TranscriptRepository(database: harness.database)
        .replaceAllSegments(meetingID: id, with: transcript)
    let markdown = try NotesRenderer.render(
        structured, language: "en", meetingTitle: title,
        userName: UserIdentity.onboardedUser.name, annotations: [])
    let notes = MeetingNotes(
        meetingID: id, markdown: markdown, structured: structured, language: "en",
        generatedAt: timestamp.addingTimeInterval(-100),
        provenance: NotesProvenance(
            engine: "seed", model: "seed", pipelineVersion: "seed",
            runtime: "seed", rendererVersion: NotesRenderer.version,
            promptVersion: "seed"),
        memoryDigest: "durable digest",
        scopedAliasBindings: [AliasPair(alias: "Q", canonical: "Quoll")])
    try await NotesRepository(database: harness.database).upsert(notes)
    try Data(markdown.utf8).write(
        to: harness.database.paths.notesURL(id), options: .atomic)
    // The editor scenarios all describe a person working IN the meeting, which
    // is the only place corrections can be entered. Registering the view is what
    // makes the settle chain wait out its idle window here rather than treat the
    // meeting as an abandoned session and settle at once.
    await harness.pipeline.settleViewAttached(id)
    return (meeting, notes)
}

@discardableResult
private func insertCorrection(
    _ database: BlaiseDatabase,
    meetingID: MeetingID,
    id: String = ULID.generate(),
    status: MeetingCorrection.Status = .pending,
    kind: MeetingCorrection.Kind = .understanding,
    section: MeetingCorrection.Section = .summary,
    quotedText: String = "One",
    userText: String = "Change it",
    createdAt: Date,
    appliedAt: Date? = nil,
    occurrence: Int = 0
) async throws -> MeetingCorrection {
    let row = MeetingCorrection(
        id: id, meetingID: meetingID, kind: kind, section: section,
        quotedText: quotedText, occurrence: occurrence, userText: userText,
        status: status, createdAt: createdAt, appliedAt: appliedAt)
    try await database.pool.write { db in
        try MeetingCorrectionStore.insert(db, row)
    }
    return row
}

private func correctionRows(
    _ database: BlaiseDatabase, meetingID: MeetingID
) async throws -> [MeetingCorrection] {
    try await database.pool.read { db in
        try MeetingCorrectionStore.all(db, meetingID: meetingID)
    }
}

private func exactStructuredJSON(_ notes: NotesStructured) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(notes), as: UTF8.self)
}

private func expectTranscriptColumnsByteEqual(
    _ actual: [TranscriptSegment], _ expected: [TranscriptSegment]
) {
    #expect(actual.count == expected.count)
    for (actual, expected) in zip(actual, expected) {
        #expect(actual.id == expected.id)
        #expect(Array(actual.meetingID.utf8) == Array(expected.meetingID.utf8))
        #expect(actual.ord == expected.ord)
        #expect(actual.startSeconds.bitPattern == expected.startSeconds.bitPattern)
        #expect(actual.endSeconds.bitPattern == expected.endSeconds.bitPattern)
        #expect(Array(actual.speakerLabel.utf8) == Array(expected.speakerLabel.utf8))
        #expect(
            actual.speakerName.map { Array($0.utf8) }
                == expected.speakerName.map { Array($0.utf8) })
        #expect(Array(actual.text.utf8) == Array(expected.text.utf8))
    }
}

func eventually(
    _ condition: @escaping @Sendable () async -> Bool,
    iterations: Int = 10_000
) async -> Bool {
    for _ in 0 ..< iterations {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}

private enum EditorTestTimeout: Error { case elapsed }

private final class TimeoutResolution: @unchecked Sendable {
    private let resolved = Mutex(false)

    func win() -> Bool {
        resolved.withLock { value in
            guard !value else { return false }
            value = true
            return true
        }
    }
}

/// Unstructured timeout on purpose: a re-entrant pipeline link never exits its
/// task group, so a structured timeout would itself deadlock waiting for it.
private func requireCompletesWithin(
    _ duration: Duration,
    operation: @escaping @Sendable () async throws -> Void
) async throws {
    let resolution = TimeoutResolution()
    try await withCheckedThrowingContinuation { continuation in
        Task {
            do {
                try await operation()
                if resolution.win() { continuation.resume() }
            } catch {
                if resolution.win() { continuation.resume(throwing: error) }
            }
        }
        Task {
            try? await Task.sleep(for: duration)
            if resolution.win() {
                continuation.resume(throwing: EditorTestTimeout.elapsed)
            }
        }
    }
}

@Suite("N2 stage 2 notes-editor pipeline", .serialized)
struct NotesEditorPipelineTests {
    @Test("M-A: Resolve/Reopen cannot assign editor-only statuses to understandings")
    func resolveSeamRestrictsUnderstandingLifecycle() async throws {
        let harness = try await makeEditorHarness()
        let (meeting, notes) = try await seedEditorMeeting(harness)
        let anchored = try await insertCorrection(
            harness.database, meetingID: meeting.id, quotedText: "One",
            createdAt: harness.clock.now())
        let unanchored = try await insertCorrection(
            harness.database, meetingID: meeting.id, quotedText: "Absent",
            createdAt: harness.clock.now())

        for row in [anchored, unanchored] {
            try await harness.pipeline.setCorrectionResolved(
                meetingID: meeting.id, id: row.id, resolved: true,
                structuredNotes: notes.structured)
        }
        var rows = try await correctionRows(harness.database, meetingID: meeting.id)
        #expect(rows.filter { [anchored.id, unanchored.id].contains($0.id) }.allSatisfy {
            $0.status == .resolved
        })

        // These snapshots would derive `.applied` and `.stale`, respectively,
        // for annotations. The fetched understanding kind must override both.
        try await harness.pipeline.setCorrectionResolved(
            meetingID: meeting.id, id: anchored.id, resolved: false,
            structuredNotes: notes.structured)
        try await harness.pipeline.setCorrectionResolved(
            meetingID: meeting.id, id: unanchored.id, resolved: false,
            structuredNotes: notes.structured)

        rows = try await correctionRows(harness.database, meetingID: meeting.id)
            .filter { [anchored.id, unanchored.id].contains($0.id) }
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.status == .pending })
        #expect(rows.allSatisfy { $0.status != .applied && $0.status != .stale })
        #expect(rows.allSatisfy { $0.appliedAt == nil })
    }

    @Test("AC-15: every pipeline editor attempt uses the notes-editor receipt purpose")
    func editorPurposeIsThreaded() async throws {
        let engine = ScriptedNotesEditorEngine()
        engine.setOutcomes([.result([])])
        let harness = try await makeEditorHarness(engine: engine)
        let (meeting, _) = try await seedEditorMeeting(harness)
        _ = try await insertCorrection(
            harness.database, meetingID: meeting.id, createdAt: harness.clock.now())

        try await harness.pipeline.sendPendingNotesToEditor(meetingID: meeting.id)

        #expect(engine.callCount == 1)
        #expect(engine.purposes == [.notesEditor])
    }

    @Test("AC-1: the pipeline builds the exact precedence-closed editor request")
    func exactPrecedenceClosedRequest() async throws {
        let structured = NotesStructured(
            title: "Quoll Harbor", summary: "repeat / repeat / repeat",
            meetingType: .projectReview, detailedNotes: "Detailed repeat.",
            decisions: ["Keep decision"],
            actionItems: [ActionItem(owner: "Harlan Voss", text: "Keep action")],
            userActionItems: [ActionItem(owner: "Sam", text: "Keep personal")])
        let engine = ScriptedNotesEditorEngine()
        engine.setOutcomes([.result([])])
        let harness = try await makeEditorHarness(engine: engine)
        let (meeting, _) = try await seedEditorMeeting(harness, structured: structured)
        let t = harness.clock.now()
        let a = try await insertCorrection(
            harness.database, meetingID: meeting.id, id: "row-a", status: .applied,
            quotedText: "closed A", userText: "closed A", createdAt: t.addingTimeInterval(-4),
            appliedAt: t)
        let b = try await insertCorrection(
            harness.database, meetingID: meeting.id, id: "row-b", status: .applied,
            quotedText: "closed B", userText: "closed B", createdAt: t.addingTimeInterval(-3),
            appliedAt: t)
        let c = try await insertCorrection(
            harness.database, meetingID: meeting.id, id: "row-c",
            section: .summary, quotedText: "repeat", userText: "Use the final repeat.",
            createdAt: t, occurrence: 2)
        let resolved = try await insertCorrection(
            harness.database, meetingID: meeting.id, id: "row-resolved", status: .resolved,
            section: .decision, quotedText: "Keep decision", userText: "Retain it",
            createdAt: t.addingTimeInterval(1))
        let annotation = try await insertCorrection(
            harness.database, meetingID: meeting.id, id: "row-annotation", status: .applied,
            kind: .annotation, section: .summary, quotedText: "repeat",
            userText: "ANNOTATION BODY MUST STAY OUT", createdAt: t.addingTimeInterval(1.5),
            appliedAt: t)
        let d = try await insertCorrection(
            harness.database, meetingID: meeting.id, id: "row-d", status: .applied,
            section: .actionItem, quotedText: "Keep action", userText: "Retain owner",
            createdAt: t.addingTimeInterval(2), appliedAt: t)
        let e = try await insertCorrection(
            harness.database, meetingID: meeting.id, id: "row-e",
            section: .detailedNotes, quotedText: "Detailed\n\"repeat\"",
            userText: "Use\n\"new wording\"", createdAt: t.addingTimeInterval(3))

        try await harness.pipeline.editPendingNotes(meetingID: meeting.id)

        let request = try #require(engine.requests.first)
        #expect(request.currentNotes == structured)
        #expect(request.instructions.map(\.rowID) == [c.id, resolved.id, d.id, e.id])
        #expect(!request.instructions.map(\.rowID).contains(a.id))
        #expect(!request.instructions.map(\.rowID).contains(b.id))
        #expect(!request.instructions.map(\.rowID).contains(annotation.id))
        let wire = try NotesEditorWireContract.userMessage(for: request)
        let expected = #"""
CURRENT NOTES:
{"action_items":[{"owner":"Harlan Voss","text":"Keep action"}],"decisions":["Keep decision"],"detailed_notes":"Detailed repeat.","meeting_type":"project_review","summary":"repeat / repeat / repeat","title":"Quoll Harbor","user_action_items":[{"owner":"Sam","text":"Keep personal"}]}
INSTRUCTIONS:
1. In the summary, the current notes say: "repeat". The user corrects: Use the final repeat.
2. In the decisions, the current notes say: "Keep decision". The user corrects: Retain it
3. In the action items, the current notes say: "Keep action". The user corrects: Retain owner
4. In the detailed notes, the current notes say: "Detailed ”repeat”". The user corrects: Use ”new wording”
"""#
        #expect(Array(wire.utf8) == Array(expected.utf8))
        #expect(!wire.contains("occurrence"))
        #expect(!wire.contains("ANNOTATION BODY MUST STAY OUT"))
        #expect(!wire.contains("durable digest"))
        #expect(!wire.contains("Unchanged transcript"))
        #expect(!wire.contains("row-"))
    }

    @Test("AC-4: Harlan/Devin correction changes all three fields and nothing else")
    func harlanDevinMultiFieldFixture() async throws {
        let before = NotesStructured(
            title: "Quoll Harbor Staffing Review",
            summary: "Harlan Voss missed the rendering requirement for Quoll Harbor. The staffing plan says only developers are needed.",
            meetingType: .externalCall,
            detailedNotes: "The shader audit remains Thursday.\n\nQuoll Harbor launch logistics are otherwise unchanged.",
            decisions: [
                "Only developers are needed for the Quoll Harbor rendering requirement.",
                "Keep the shader audit on Thursday.",
            ],
            actionItems: [
                ActionItem(owner: "Harlan Voss", text: "Close the Quoll Harbor rendering requirement."),
                ActionItem(owner: "Mara Fenwick", text: "Keep the launch brief byte-identical."),
            ],
            userActionItems: [
                ActionItem(owner: "Sam", text: "Review the fictional staffing plan."),
            ])
        let expected = NotesStructured(
            title: "Quoll Harbor Staffing Review",
            summary: "Manager Devin Quoll missed the rendering requirement for Quoll Harbor. The staffing plan requires artists as well as developers.",
            meetingType: .externalCall,
            detailedNotes: "The shader audit remains Thursday.\n\nQuoll Harbor launch logistics are otherwise unchanged.",
            decisions: [
                "Artists as well as developers are needed for the Quoll Harbor rendering requirement.",
                "Keep the shader audit on Thursday.",
            ],
            actionItems: [
                ActionItem(owner: "Devin Quoll", text: "Close the Quoll Harbor rendering requirement."),
                ActionItem(owner: "Mara Fenwick", text: "Keep the launch brief byte-identical."),
            ],
            userActionItems: [
                ActionItem(owner: "Sam", text: "Review the fictional staffing plan."),
            ])
        let engine = ScriptedNotesEditorEngine()
        engine.setOutcomes([.result([
            .replace(
                field: .summary,
                find: "Harlan Voss missed the rendering requirement for Quoll Harbor. The staffing plan says only developers are needed.",
                replace: "Manager Devin Quoll missed the rendering requirement for Quoll Harbor. The staffing plan requires artists as well as developers.",
                instruction: 1),
            .set(
                field: .actionItems, index: 0,
                patch: NotesItemPatch(owner: "Devin Quoll", text: nil), instruction: 1),
            .set(
                field: .decisions, index: 0,
                patch: NotesItemPatch(
                    owner: nil,
                    text: "Artists as well as developers are needed for the Quoll Harbor rendering requirement."),
                instruction: 1),
        ])])
        let harness = try await makeEditorHarness(engine: engine)
        let (meeting, _) = try await seedEditorMeeting(
            harness, title: "Quoll Harbor Staffing Review", structured: before)
        let row = try await insertCorrection(
            harness.database, meetingID: meeting.id, section: .summary,
            quotedText: "Harlan Voss missed the rendering requirement for Quoll Harbor.",
            userText: "It was manager Devin Quoll, and artists as well as developers are needed.",
            createdAt: harness.clock.now())

        #expect(try exactStructuredJSON(before) == #"{"action_items":[{"owner":"Harlan Voss","text":"Close the Quoll Harbor rendering requirement."},{"owner":"Mara Fenwick","text":"Keep the launch brief byte-identical."}],"decisions":["Only developers are needed for the Quoll Harbor rendering requirement.","Keep the shader audit on Thursday."],"detailed_notes":"The shader audit remains Thursday.\n\nQuoll Harbor launch logistics are otherwise unchanged.","meeting_type":"external_call","summary":"Harlan Voss missed the rendering requirement for Quoll Harbor. The staffing plan says only developers are needed.","title":"Quoll Harbor Staffing Review","user_action_items":[{"owner":"Sam","text":"Review the fictional staffing plan."}]}"#)

        try await harness.pipeline.editPendingNotes(meetingID: meeting.id)

        let stored = try #require(
            try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id))
        #expect(stored.structured == expected)
        #expect(try exactStructuredJSON(stored.structured) == #"{"action_items":[{"owner":"Devin Quoll","text":"Close the Quoll Harbor rendering requirement."},{"owner":"Mara Fenwick","text":"Keep the launch brief byte-identical."}],"decisions":["Artists as well as developers are needed for the Quoll Harbor rendering requirement.","Keep the shader audit on Thursday."],"detailed_notes":"The shader audit remains Thursday.\n\nQuoll Harbor launch logistics are otherwise unchanged.","meeting_type":"external_call","summary":"Manager Devin Quoll missed the rendering requirement for Quoll Harbor. The staffing plan requires artists as well as developers.","title":"Quoll Harbor Staffing Review","user_action_items":[{"owner":"Sam","text":"Review the fictional staffing plan."}]}"#)
        let expectedMarkdown = """
            # Quoll Harbor Staffing Review

            ## Summary

            Manager Devin Quoll missed the rendering requirement for Quoll Harbor. The staffing plan requires artists as well as developers.

            ## Detailed notes

            The shader audit remains Thursday.

            Quoll Harbor launch logistics are otherwise unchanged.

            ## Decisions

            - Artists as well as developers are needed for the Quoll Harbor rendering requirement.
            - Keep the shader audit on Thursday.

            ## Action items

            - **Devin Quoll:** Close the Quoll Harbor rendering requirement.
            - **Mara Fenwick:** Keep the launch brief byte-identical.

            ## Sam's action items

            - **Sam:** Review the fictional staffing plan.

            """
        #expect(Array(stored.markdown.utf8) == Array(expectedMarkdown.utf8))
        let finalRow = try #require(
            try await correctionRows(harness.database, meetingID: meeting.id).first {
                $0.id == row.id
            })
        #expect(finalRow.status == .applied)
        #expect(finalRow.appliedAt != nil)
    }

    @Test("AC-5: ordinary corrections delete prose and a list item byte-exactly")
    func ordinaryDeletionCorrectionsComplete() async throws {
        let before = NotesStructured(
            title: "Quoll Harbor Cleanup",
            summary: "Keep alpha. Remove obsolete claim. Keep omega.",
            meetingType: .decisionMeeting,
            detailedNotes: "Untouched detailed notes.",
            decisions: ["Keep first", "Remove obsolete item", "Keep last"],
            actionItems: [ActionItem(owner: "Devin Quoll", text: "Keep action")],
            userActionItems: [])
        let engine = ScriptedNotesEditorEngine()
        engine.setOutcomes([.result([
            .replace(
                field: .summary, find: "Remove obsolete claim. ", replace: "",
                instruction: 1),
            .remove(field: .decisions, index: 1, instruction: 2),
        ])])
        let harness = try await makeEditorHarness(engine: engine)
        let (meeting, _) = try await seedEditorMeeting(harness, structured: before)
        let prose = try await insertCorrection(
            harness.database, meetingID: meeting.id, section: .summary,
            quotedText: "Remove obsolete claim.", userText: "Remove this part",
            createdAt: harness.clock.now())
        let list = try await insertCorrection(
            harness.database, meetingID: meeting.id, section: .decision,
            quotedText: "Remove obsolete item", userText: "Remove this item",
            createdAt: harness.clock.now().addingTimeInterval(1))

        try await harness.pipeline.editPendingNotes(meetingID: meeting.id)

        let stored = try #require(
            try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id))
        var expected = before
        expected.summary = "Keep alpha. Keep omega."
        expected.decisions = ["Keep first", "Keep last"]
        #expect(stored.structured == expected)
        #expect(Array(stored.structured.summary.utf8) == Array("Keep alpha. Keep omega.".utf8))
        #expect(stored.structured.decisions.map { Array($0.utf8) } == [
            Array("Keep first".utf8), Array("Keep last".utf8),
        ])
        let rows = try await correctionRows(harness.database, meetingID: meeting.id)
        #expect(rows.first { $0.id == prose.id }?.status == .applied)
        #expect(rows.first { $0.id == list.id }?.status == .applied)
    }

    @Test("AC-6: completion follows effective attribution only")
    func evidenceBasedCompletion() async throws {
        let engine = ScriptedNotesEditorEngine()
        engine.setOutcomes([.result([
            .replace(field: .summary, find: "One", replace: "Uno", instruction: 1),
            .replace(field: .summary, find: "Two", replace: "Two", instruction: 2),
            .replace(field: .summary, find: "Missing", replace: "X", instruction: 3),
            .replace(field: .summary, find: "Three", replace: "Tres", instruction: 0),
            .replace(field: .summary, find: "Four", replace: "Quatro", instruction: 4),
            .replace(field: .summary, find: "Uno", replace: "Uno!", instruction: 1),
        ])])
        let harness = try await makeEditorHarness(engine: engine)
        let (meeting, _) = try await seedEditorMeeting(harness)
        let t = harness.clock.now()
        let rows = try await [
            insertCorrection(
                harness.database, meetingID: meeting.id, quotedText: "One",
                userText: "Uno", createdAt: t),
            insertCorrection(
                harness.database, meetingID: meeting.id, quotedText: "Two",
                userText: "Dos", createdAt: t.addingTimeInterval(1)),
            insertCorrection(
                harness.database, meetingID: meeting.id, quotedText: "Three",
                userText: "Tres", createdAt: t.addingTimeInterval(2)),
        ]

        try await harness.pipeline.editPendingNotes(meetingID: meeting.id)

        let finalRows = try await correctionRows(harness.database, meetingID: meeting.id)
        #expect(finalRows.first { $0.id == rows[0].id }?.status == .applied)
        #expect(finalRows.first { $0.id == rows[0].id }?.appliedAt != nil)
        #expect(finalRows.first { $0.id == rows[1].id }?.status == .pending)
        #expect(finalRows.first { $0.id == rows[1].id }?.appliedAt == nil)
        #expect(finalRows.first { $0.id == rows[2].id }?.status == .pending)
        #expect(
            try await NotesRepository(database: harness.database)
                .fetch(meetingID: meeting.id)?.structured.summary
                == "Uno! Two Tres Quatro")
    }

    enum RaceMutation: String, CaseIterable, Sendable {
        case edit, resolve, delete, resolveThenReopen
    }

    @Test(
        "AC-6: a mutation during the model await defeats the final four-value match",
        arguments: RaceMutation.allCases)
    func mutationRace(_ mutation: RaceMutation) async throws {
        let gate = EditorGate()
        let engine = ScriptedNotesEditorEngine()
        engine.setGate(gate)
        engine.setOutcomes([.result([
            .replace(field: .summary, find: "One", replace: "Uno", instruction: 1)
        ])])
        let harness = try await makeEditorHarness(engine: engine)
        let (meeting, _) = try await seedEditorMeeting(harness)
        let row = try await insertCorrection(
            harness.database, meetingID: meeting.id, createdAt: harness.clock.now())
        let task = Task { try await harness.pipeline.editPendingNotes(meetingID: meeting.id) }
        await gate.waitUntilEntered()

        switch mutation {
        case .edit:
            _ = try await harness.pipeline.updateCorrection(
                meetingID: meeting.id, id: row.id, quotedText: row.quotedText,
                occurrence: row.occurrence, userText: "Newer wording")
        case .resolve:
            try await harness.pipeline.setCorrectionResolved(
                meetingID: meeting.id, id: row.id, resolved: true,
                structuredNotes: nil)
        case .delete:
            _ = try await harness.pipeline.deleteCorrection(meetingID: meeting.id, id: row.id)
        case .resolveThenReopen:
            try await harness.pipeline.setCorrectionResolved(
                meetingID: meeting.id, id: row.id, resolved: true,
                structuredNotes: nil)
            try await harness.pipeline.setCorrectionResolved(
                meetingID: meeting.id, id: row.id, resolved: false,
                structuredNotes: nil)
        }
        gate.release()
        try await task.value

        let stored = try await correctionRows(harness.database, meetingID: meeting.id)
            .first { $0.id == row.id }
        switch mutation {
        case .edit:
            #expect(stored?.status == .pending)
            #expect(stored?.userText == "Newer wording")
            #expect(stored?.createdAt != row.createdAt)
        case .resolve:
            #expect(stored?.status == .resolved)
        case .delete:
            #expect(stored == nil)
        case .resolveThenReopen:
            #expect(stored?.status == .pending)
            #expect(stored?.quotedText == row.quotedText)
            #expect(stored?.userText == row.userText)
            #expect(stored?.createdAt != row.createdAt)
        }
        #expect(stored?.appliedAt == nil)
        #expect(
            try await NotesRepository(database: harness.database)
                .fetch(meetingID: meeting.id)?.structured.summary
                == "Uno Two Three Four")
    }

    @Test("AC-6/7: closed rows are citable context but never completion candidates")
    func appliedAndResolvedRowsRideWithoutCompleting() async throws {
        let appliedAt = msDate(1_760_000_000)
        let engine = ScriptedNotesEditorEngine()
        engine.setOutcomes([.result([
            .replace(field: .summary, find: "Two", replace: "Dos", instruction: 2)
        ])])
        let harness = try await makeEditorHarness(engine: engine)
        let (meeting, _) = try await seedEditorMeeting(harness)
        let t = harness.clock.now()
        let pending = try await insertCorrection(
            harness.database, meetingID: meeting.id, quotedText: "One",
            userText: "Uno", createdAt: t)
        let applied = try await insertCorrection(
            harness.database, meetingID: meeting.id, status: .applied,
            quotedText: "Two", userText: "Dos", createdAt: t.addingTimeInterval(1),
            appliedAt: appliedAt)
        let resolved = try await insertCorrection(
            harness.database, meetingID: meeting.id, status: .resolved,
            quotedText: "Three", userText: "Tres", createdAt: t.addingTimeInterval(2))

        try await harness.pipeline.editPendingNotes(meetingID: meeting.id)

        #expect(
            engine.requests.first?.instructions.map(\.rowID)
                == [pending.id, applied.id, resolved.id])
        let final = try await correctionRows(harness.database, meetingID: meeting.id)
        #expect(final.first { $0.id == pending.id }?.status == .pending)
        #expect(final.first { $0.id == applied.id }?.status == .applied)
        #expect(final.first { $0.id == applied.id }?.appliedAt == appliedAt)
    }

    @Test("AC-7/8: the newer winner rides every later activation with its pending loser")
    func newestWinnerRemainsInTheSliceWithoutSelfLooping() async throws {
        let structured = NotesStructured(
            title: "Quoll Harbor Ownership",
            summary: "The owner is Devin Quoll.", meetingType: .decisionMeeting,
            detailedNotes: "Ownership review.", decisions: [], actionItems: [],
            userActionItems: [])
        let engine = ScriptedNotesEditorEngine()
        engine.setOutcomes([
            .result([.replace(
                field: .summary, find: "Devin Quoll", replace: "Priya Okonjo",
                instruction: 2)]),
            .result([]),
        ])
        let harness = try await makeEditorHarness(engine: engine)
        let (meeting, _) = try await seedEditorMeeting(harness, structured: structured)
        let t = harness.clock.now()
        let a = try await insertCorrection(
            harness.database, meetingID: meeting.id, id: "01A-OLDER-HARLAN",
            section: .summary, quotedText: "Devin Quoll", userText: "The owner is Harlan Voss.",
            createdAt: t.addingTimeInterval(-2))
        let b = try await insertCorrection(
            harness.database, meetingID: meeting.id, id: "01B-NEWER-PRIYA",
            section: .summary, quotedText: "Devin Quoll", userText: "The owner is Priya Okonjo.",
            createdAt: t.addingTimeInterval(-1))

        try await harness.pipeline.editPendingNotes(meetingID: meeting.id)

        #expect(engine.requests[0].instructions.map(\.rowID) == [a.id, b.id])
        #expect(
            try await NotesRepository(database: harness.database)
                .fetch(meetingID: meeting.id)?.structured.summary == "The owner is Priya Okonjo.")
        var rows = try await correctionRows(harness.database, meetingID: meeting.id)
        #expect(rows.first { $0.id == a.id }?.status == .pending)
        #expect(rows.first { $0.id == b.id }?.status == .applied)

        harness.clock.advance(by: .seconds(2))
        let c = try await harness.pipeline.addCorrection(
            meetingID: meeting.id, kind: .understanding, section: .detailedNotes,
            quotedText: "Ownership review.", occurrence: 0,
            userText: "The review happened at Quoll Harbor.")
        try await harness.pipeline.sendPendingNotesToEditor(meetingID: meeting.id)

        #expect(engine.requests[1].instructions.map(\.rowID) == [a.id, b.id, c.row.id])
        rows = try await correctionRows(harness.database, meetingID: meeting.id)
        #expect(rows.first { $0.id == a.id }?.status == .pending)
        #expect(rows.first { $0.id == b.id }?.status == .applied)
        #expect(rows.first { $0.id == c.row.id }?.status == .pending)
        harness.clock.advance(by: .seconds(3_600))
        await Task.yield()
        #expect(engine.callCount == 2, "a decoded result with pending losers must not self-loop")
    }

    @Test("AC-7: precedence closure, resolved inclusion, deletion, and pinned-clock restamp")
    func precedenceSliceAndStrictOrdering() async throws {
        let engine = ScriptedNotesEditorEngine()
        engine.setOutcomes([.result([]), .result([]), .result([])])
        let harness = try await makeEditorHarness(engine: engine)
        let (meeting, _) = try await seedEditorMeeting(harness)
        let pinned = harness.clock.now()
        let olderClosed = try await insertCorrection(
            harness.database, meetingID: meeting.id, status: .applied,
            quotedText: "old", userText: "closed", createdAt: pinned.addingTimeInterval(-2))
        let a = try await insertCorrection(
            harness.database, meetingID: meeting.id, id: "01J00000000000000000000001",
            quotedText: "name", userText: "Harlan", createdAt: pinned.addingTimeInterval(-1))
        let b = try await insertCorrection(
            harness.database, meetingID: meeting.id, id: "01J00000000000000000000002",
            status: .applied, quotedText: "name", userText: "Priya", createdAt: pinned,
            appliedAt: pinned)
        let resolved = try await insertCorrection(
            harness.database, meetingID: meeting.id, status: .resolved,
            quotedText: "date", userText: "Monday", createdAt: pinned)
        let c = try await insertCorrection(
            harness.database, meetingID: meeting.id, quotedText: "other",
            userText: "Other", createdAt: pinned)

        try await harness.pipeline.editPendingNotes(meetingID: meeting.id)
        #expect(engine.requests[0].instructions.map(\.rowID) == [a.id, b.id, resolved.id, c.id])
        #expect(!engine.requests[0].instructions.map(\.rowID).contains(olderClosed.id))

        _ = try await harness.pipeline.deleteCorrection(meetingID: meeting.id, id: b.id)
        try await harness.pipeline.sendPendingNotesToEditor(meetingID: meeting.id)
        #expect(engine.requests[1].instructions.map(\.rowID) == [a.id, resolved.id, c.id])

        _ = try await harness.pipeline.updateCorrection(
            meetingID: meeting.id, id: a.id, quotedText: "name", occurrence: 0,
            userText: "Harlan revised")
        try await harness.pipeline.sendPendingNotesToEditor(meetingID: meeting.id)
        #expect(engine.requests[2].instructions.map(\.rowID) == [c.id, a.id])
        let edited = try #require(
            try await correctionRows(harness.database, meetingID: meeting.id).first {
                $0.id == a.id
            })
        let priorMaximum = max(b.createdAt, resolved.createdAt, c.createdAt)
        #expect(edited.createdAt > priorMaximum)
    }

    @Test("H-D: a backward clock cannot put a newer add before an older instruction")
    func backwardClockAddStillSortsLast() async throws {
        let engine = ScriptedNotesEditorEngine()
        engine.setOutcomes([.result([])])
        let harness = try await makeEditorHarness(engine: engine)
        let (meeting, _) = try await seedEditorMeeting(harness)
        let first = try await harness.pipeline.addCorrection(
            meetingID: meeting.id, kind: .understanding, section: .summary,
            quotedText: "One", occurrence: 0, userText: "First request")

        harness.clock.advance(by: .seconds(-120))
        let second = try await harness.pipeline.addCorrection(
            meetingID: meeting.id, kind: .understanding, section: .summary,
            quotedText: "Two", occurrence: 0, userText: "Second request")
        try await harness.pipeline.sendPendingNotesToEditor(meetingID: meeting.id)

        #expect(second.row.createdAt > first.row.createdAt)
        #expect(engine.requests.first?.instructions.map(\.rowID) == [first.row.id, second.row.id])
    }

    @Test("AC-8: burst pooling and immediate send use one sleeping slot")
    func burstAndImmediateSend() async throws {
        let engine = ScriptedNotesEditorEngine()
        engine.setOutcomes([.result([]), .result([])])
        let harness = try await makeEditorHarness(engine: engine)
        let (meeting, _) = try await seedEditorMeeting(harness)

        _ = try await harness.pipeline.addCorrection(
            meetingID: meeting.id, kind: .understanding, section: .summary,
            quotedText: "One", occurrence: 0, userText: "First")
        #expect(await eventually { harness.clock.activeSleeperCount == 1 })
        harness.clock.advance(by: .seconds(20))
        _ = try await harness.pipeline.addCorrection(
            meetingID: meeting.id, kind: .understanding, section: .summary,
            quotedText: "Two", occurrence: 0, userText: "Second")
        #expect(await eventually { harness.clock.activeSleeperCount == 1 })
        harness.clock.advance(by: .seconds(39))
        _ = try await harness.pipeline.addCorrection(
            meetingID: meeting.id, kind: .understanding, section: .summary,
            quotedText: "Three", occurrence: 0, userText: "Third")
        #expect(await eventually { harness.clock.activeSleeperCount == 1 })
        harness.clock.advance(by: .seconds(299))
        // One second short of the window: the slot is still sleeping.
        #expect(await eventually { harness.clock.activeSleeperCount == 1 })
        #expect(engine.callCount == 0)
        harness.clock.advance(by: .seconds(1))
        #expect(await eventually { engine.callCount == 1 })
        #expect(engine.requests.first?.instructions.count == 3)

        _ = try await harness.pipeline.addCorrection(
            meetingID: meeting.id, kind: .understanding, section: .summary,
            quotedText: "Four", occurrence: 0, userText: "Fourth")
        #expect(await eventually { harness.clock.activeSleeperCount == 1 })
        harness.clock.advance(by: .seconds(30))
        try await harness.pipeline.sendPendingNotesToEditor(meetingID: meeting.id)
        #expect(engine.callCount == 2)
        harness.clock.advance(by: .seconds(3_600))
        await Task.yield()
        #expect(engine.callCount == 2, "the cancelled debounce must not duplicate Send")
    }

    @Test("AC-8: launch re-arm waits a fresh five minutes")
    func durableRelaunchRearm() async throws {
        let engine = ScriptedNotesEditorEngine()
        engine.setOutcomes([.result([])])
        let harness = try await makeEditorHarness(engine: engine)
        let (meeting, _) = try await seedEditorMeeting(harness)
        _ = try await insertCorrection(
            harness.database, meetingID: meeting.id, createdAt: harness.clock.now())

        try await harness.pipeline.rearmPendingNotesEditorActivations()
        #expect(await eventually { harness.clock.activeSleeperCount == 1 })
        harness.clock.advance(by: .seconds(299))
        // One second short of the fresh window: still sleeping, still silent.
        #expect(await eventually { harness.clock.activeSleeperCount == 1 })
        #expect(engine.callCount == 0)
        harness.clock.advance(by: .seconds(1))
        #expect(await eventually { engine.callCount == 1 })
        harness.clock.advance(by: .seconds(600))
        await Task.yield()
        #expect(engine.callCount == 1, "a decoded empty result must not self-arm")
    }

    @Test("§9: the injected sleep seam's documentation names the window the timers arm")
    func sleepSeamDocumentationNamesTheActivationWindow() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources", isDirectory: true)
        let source = try String(
            contentsOf: sources.appendingPathComponent("BlaiseCore/ProcessingPipeline.swift"),
            encoding: .utf8)
        let seam = try #require(source.range(of: "private let notesEditorSleep"))
        let documentation = source[..<seam.lowerBound].suffix(400)
        #expect(documentation.contains("5-minute activation timers"))
        #expect(!documentation.contains("60-second"))
        // The window every activation kind actually sleeps.
        #expect(source.contains("try await sleep(.seconds(300))"))
    }

    @Test("AC-8/§2: an engine that can edit, selected again, makes pending corrections live")
    func selectingAnEditingEngineMakesPendingCorrectionsLiveAgain() async throws {
        let root = try makeTempRoot()
        let database = try BlaiseDatabase(rootURL: root)
        let clock = EditorManualClock()
        let editor = ScriptedNotesEditorEngine(id: "cloud-editor")
        editor.setOutcomes([
            .result([.replace(field: .summary, find: "One", replace: "Uno", instruction: 1)])
        ])
        let local = PipelineMockNotes(id: "local-without-editor", kind: .local)
        let registry = try EngineRegistry(asr: [], summarization: [editor, local])
        let settings = SettingsStore(database: database)
        try await settings.set(EngineResolver.summarizationSettingsKey, to: editor.id)
        try await settings.set(UserIdentity.settingsKey, to: UserIdentity.onboardedUser)
        let pipeline = ProcessingPipeline(
            database: database, registry: registry, diarizer: PipelineMockDiarizer(),
            vocabulary: try VocabFixtures.pipelineVocabulary(), now: clock.now,
            notesEditorSleep: clock.sleep,
            settleSleep: { _ in throw CancellationError() })
        let harness = EditorHarness(
            root: root, database: database, pipeline: pipeline, engine: editor, clock: clock)
        let (meeting, _) = try await seedEditorMeeting(harness)

        // Stated under an engine that can edit: one activation sleeps.
        _ = try await pipeline.addCorrection(
            meetingID: meeting.id, kind: .understanding, section: .summary,
            quotedText: "One", occurrence: 0, userText: "Uno")
        #expect(await eventually { clock.activeSleeperCount == 1 })

        // The engine that cannot edit is selected. The window lapses, the pass
        // refuses without a model call, and nothing is scheduled in its place.
        try await settings.set(EngineResolver.summarizationSettingsKey, to: local.id)
        await pipeline.rearmPendingNotesEditorActivationsIfEngineCanEdit()
        clock.advance(by: .seconds(300))
        #expect(await eventually { clock.activeSleeperCount == 0 })
        clock.advance(by: .seconds(3_600))
        await Task.yield()
        #expect(editor.callCount == 0)
        #expect(local.state.withLock { $0.requests.isEmpty })
        #expect(clock.activeSleeperCount == 0, "a refusal schedules nothing")
        #expect(
            try await correctionRows(database, meetingID: meeting.id).first?.status == .pending)

        // Selecting inside the same incapable class arms nothing: there is
        // still no engine that could serve the row.
        await pipeline.rearmPendingNotesEditorActivationsIfEngineCanEdit()
        await Task.yield()
        #expect(clock.activeSleeperCount == 0)

        // The engine that can edit is selected again: exactly one activation,
        // and it carries the waiting correction through.
        try await settings.set(EngineResolver.summarizationSettingsKey, to: editor.id)
        await pipeline.rearmPendingNotesEditorActivationsIfEngineCanEdit()
        #expect(await eventually { clock.activeSleeperCount == 1 })
        clock.advance(by: .seconds(300))
        #expect(await eventually { editor.callCount == 1 })
        #expect(
            await eventually {
                (try? await correctionRows(database, meetingID: meeting.id).first?.status)
                    == .applied
            })
        clock.advance(by: .seconds(3_600))
        await Task.yield()
        #expect(editor.callCount == 1, "exactly one activation, never two")
    }

    @Test("AC-8: only three transport failures re-arm, repeatedly, until decoded")
    func transportRetryChain() async throws {
        let engine = ScriptedNotesEditorEngine()
        engine.setOutcomes([
            .error(.transient("offline 1")), .error(.transient("offline 2")),
            .error(.transient("offline 3")), .error(.transient("offline 4")),
            .error(.transient("offline 5")), .error(.transient("offline 6")),
            .result([]),
        ])
        let harness = try await makeEditorHarness(engine: engine)
        let (meeting, _) = try await seedEditorMeeting(harness)
        _ = try await insertCorrection(
            harness.database, meetingID: meeting.id, createdAt: harness.clock.now())

        let first = Task {
            try await harness.pipeline.sendPendingNotesToEditor(meetingID: meeting.id)
        }
        #expect(await eventually { engine.callCount == 1 })
        #expect(await eventually { harness.clock.activeSleeperCount == 1 })
        harness.clock.advance(by: .seconds(1))
        #expect(await eventually { engine.callCount == 2 })
        #expect(await eventually { harness.clock.activeSleeperCount == 1 })
        harness.clock.advance(by: .seconds(2))
        #expect(await eventually { engine.callCount == 3 })
        do {
            try await first.value
            Issue.record("transport exhaustion should escape the immediate caller")
        } catch let error as EngineError {
            guard case .transient = error else {
                Issue.record("expected transient exhaustion, got \(error)")
                return
            }
        }
        #expect(await eventually { harness.clock.activeSleeperCount == 1 })

        harness.clock.advance(by: .seconds(300))
        #expect(await eventually { engine.callCount == 4 })
        #expect(await eventually { harness.clock.activeSleeperCount == 1 })
        harness.clock.advance(by: .seconds(1))
        #expect(await eventually { engine.callCount == 5 })
        #expect(await eventually { harness.clock.activeSleeperCount == 1 })
        harness.clock.advance(by: .seconds(2))
        #expect(await eventually { engine.callCount == 6 })
        #expect(await eventually { harness.clock.activeSleeperCount == 1 })

        harness.clock.advance(by: .seconds(300))
        #expect(await eventually { engine.callCount == 7 })
        harness.clock.advance(by: .seconds(3_600))
        await Task.yield()
        #expect(engine.callCount == 7)
    }

    @Test("AC-8: permanent failure terminates at its attempt and schedules nothing")
    func permanentFailureStops() async throws {
        let engine = ScriptedNotesEditorEngine()
        engine.setOutcomes([
            .error(.transient("429")), .error(.permanent("malformed body")),
            .result([]),
        ])
        let harness = try await makeEditorHarness(engine: engine)
        let (meeting, _) = try await seedEditorMeeting(harness)
        _ = try await insertCorrection(
            harness.database, meetingID: meeting.id, createdAt: harness.clock.now())

        let task = Task {
            try await harness.pipeline.sendPendingNotesToEditor(meetingID: meeting.id)
        }
        #expect(await eventually { engine.callCount == 1 })
        #expect(await eventually { harness.clock.activeSleeperCount == 1 })
        harness.clock.advance(by: .seconds(1))
        do {
            try await task.value
            Issue.record("permanent failure should escape")
        } catch let error as EngineError {
            #expect(error == .permanent("malformed body"))
        }
        #expect(engine.callCount == 2)
        harness.clock.advance(by: .seconds(3_600))
        await Task.yield()
        #expect(engine.callCount == 2)
    }

    @Test("AC-8: a live mutation cannot cancel the in-flight editor and arms exactly one successor")
    func mutationCrossesLiveCall() async throws {
        let gate = EditorGate()
        let engine = ScriptedNotesEditorEngine()
        engine.setGate(gate)
        engine.setOutcomes([
            .result([.replace(field: .summary, find: "One", replace: "Uno", instruction: 1)]),
            .result([]),
        ])
        let harness = try await makeEditorHarness(engine: engine)
        let (meeting, _) = try await seedEditorMeeting(harness)
        _ = try await insertCorrection(
            harness.database, meetingID: meeting.id, createdAt: harness.clock.now())

        let active = Task {
            try await harness.pipeline.sendPendingNotesToEditor(meetingID: meeting.id)
        }
        await gate.waitUntilEntered()
        _ = try await harness.pipeline.addCorrection(
            meetingID: meeting.id, kind: .understanding, section: .summary,
            quotedText: "Two", occurrence: 0, userText: "Dos")
        gate.release()
        try await active.value
        #expect(engine.callCount == 1)
        #expect(await eventually { harness.clock.activeSleeperCount == 1 })
        harness.clock.advance(by: .seconds(300))
        #expect(await eventually { engine.callCount == 2 })
        harness.clock.advance(by: .seconds(600))
        await Task.yield()
        #expect(engine.callCount == 2)
    }

    @Test("AC-8: a mutation replaces a sleeping transport retry")
    func mutationReplacesRetryTimer() async throws {
        let engine = ScriptedNotesEditorEngine()
        engine.setOutcomes([
            .error(.transient("one")), .error(.transient("two")),
            .error(.transient("three")), .result([]),
        ])
        let harness = try await makeEditorHarness(engine: engine)
        let (meeting, _) = try await seedEditorMeeting(harness)
        _ = try await insertCorrection(
            harness.database, meetingID: meeting.id, createdAt: harness.clock.now())
        let first = Task {
            try await harness.pipeline.sendPendingNotesToEditor(meetingID: meeting.id)
        }
        #expect(await eventually { engine.callCount == 1 })
        #expect(await eventually { harness.clock.activeSleeperCount == 1 })
        harness.clock.advance(by: .seconds(1))
        #expect(await eventually { engine.callCount == 2 })
        #expect(await eventually { harness.clock.activeSleeperCount == 1 })
        harness.clock.advance(by: .seconds(2))
        #expect(await eventually { engine.callCount == 3 })
        _ = try? await first.value
        harness.clock.advance(by: .seconds(150))
        _ = try await harness.pipeline.addCorrection(
            meetingID: meeting.id, kind: .understanding, section: .summary,
            quotedText: "Two", occurrence: 0, userText: "new activation")
        #expect(await eventually { harness.clock.activeSleeperCount == 1 })
        harness.clock.advance(by: .seconds(155))
        await Task.yield()
        #expect(engine.callCount == 3, "the replaced retry timer must stay cancelled")
        harness.clock.advance(by: .seconds(145))
        #expect(await eventually { engine.callCount == 4 })
        harness.clock.advance(by: .seconds(600))
        await Task.yield()
        #expect(engine.callCount == 4)
    }

    @Test("AC-8: an exhausted activation arms unconditionally")
    func exhaustedActivationArmsUnconditionally() async throws {
        let gate = EditorGate()
        let engine = ScriptedNotesEditorEngine()
        engine.setGate(gate)
        engine.setOutcomes([
            .error(.transient("offline 1")), .error(.transient("offline 2")),
            .error(.transient("offline 3")), .result([]), .result([]),
        ])
        let harness = try await makeEditorHarness(engine: engine)
        let (meeting, _) = try await seedEditorMeeting(harness)
        _ = try await insertCorrection(
            harness.database, meetingID: meeting.id, createdAt: harness.clock.now())

        // A timer stands in the slot when this activation starts, and it fires
        // and clears its own slot while the failing call is still out — the
        // window a slot comparison cannot tell from an untouched empty slot.
        try await harness.pipeline.rearmPendingNotesEditorActivations()
        #expect(await eventually { harness.clock.activeSleeperCount == 1 })
        let activation = Task {
            try await harness.pipeline.editPendingNotes(meetingID: meeting.id)
        }
        #expect(await eventually { engine.callCount == 1 })
        harness.clock.advance(by: .seconds(300))
        #expect(await eventually { harness.clock.activeSleeperCount == 0 })
        gate.release()

        #expect(await eventually { harness.clock.activeSleeperCount == 1 })
        harness.clock.advance(by: .seconds(1))
        #expect(await eventually { engine.callCount == 2 })
        #expect(await eventually { harness.clock.activeSleeperCount == 1 })
        harness.clock.advance(by: .seconds(2))
        #expect(await eventually { engine.callCount == 3 })
        do {
            try await activation.value
            Issue.record("transport exhaustion should escape the caller")
        } catch let error as EngineError {
            guard case .transient = error else {
                Issue.record("expected transient exhaustion, got \(error)")
                return
            }
        }

        // The pass the fired timer queued behind this one decodes and schedules
        // nothing, so the retry activation is the only thing left sleeping.
        #expect(await eventually { engine.callCount == 4 })
        #expect(await eventually { harness.clock.activeSleeperCount == 1 })
        #expect(harness.clock.activeSleeperCount == 1, "one successor, never two")
        harness.clock.advance(by: .seconds(300))
        #expect(await eventually { engine.callCount == 5 })
        harness.clock.advance(by: .seconds(3_600))
        await Task.yield()
        #expect(engine.callCount == 5)
    }

    @Test("H-C: an add after the completion commit preserves its newer activation")
    func addInPostCommitWindowPreservesNewerSlot() async throws {
        let postDatabaseGate = EditorGate()
        let engine = ScriptedNotesEditorEngine()
        engine.setOutcomes([
            .result([.replace(
                field: .summary, find: "One", replace: "Uno", instruction: 1)]),
            .result([]),
        ])
        let harness = try await makeEditorHarness(
            engine: engine,
            afterSchedulerDatabaseOperation: { _ in
                await postDatabaseGate.enterAndWait()
            })
        let (meeting, _) = try await seedEditorMeeting(harness)
        _ = try await insertCorrection(
            harness.database, meetingID: meeting.id, createdAt: harness.clock.now())

        let edit = Task {
            try await harness.pipeline.editPendingNotes(meetingID: meeting.id)
        }
        await postDatabaseGate.waitUntilEntered()
        let later = try await harness.pipeline.addCorrection(
            meetingID: meeting.id, kind: .understanding, section: .summary,
            quotedText: "Two", occurrence: 0, userText: "Dos")
        postDatabaseGate.release()
        try await edit.value

        #expect(
            try await correctionRows(harness.database, meetingID: meeting.id)
                .first { $0.id == later.row.id }?.status == .pending)
        #expect(await eventually { harness.clock.activeSleeperCount == 1 })
        harness.clock.advance(by: .seconds(300))
        #expect(await eventually { engine.callCount == 2 })
    }

    @Test("H-C: a resolve during the exhaustion read cancels that retry UUID")
    func resolveInExhaustionWindowPreventsStaleArm() async throws {
        let postDatabaseGate = EditorGate()
        let engine = ScriptedNotesEditorEngine()
        engine.setOutcomes([
            .error(.transient("offline 1")),
            .error(.transient("offline 2")),
            .error(.transient("offline 3")),
        ])
        let harness = try await makeEditorHarness(
            engine: engine,
            afterSchedulerDatabaseOperation: { _ in
                await postDatabaseGate.enterAndWait()
            })
        let (meeting, _) = try await seedEditorMeeting(harness)
        let row = try await insertCorrection(
            harness.database, meetingID: meeting.id, createdAt: harness.clock.now())

        let edit = Task {
            try await harness.pipeline.sendPendingNotesToEditor(meetingID: meeting.id)
        }
        #expect(await eventually { engine.callCount == 1 })
        #expect(await eventually { harness.clock.activeSleeperCount == 1 })
        harness.clock.advance(by: .seconds(1))
        #expect(await eventually { engine.callCount == 2 })
        #expect(await eventually { harness.clock.activeSleeperCount == 1 })
        harness.clock.advance(by: .seconds(2))
        #expect(await eventually { engine.callCount == 3 })
        await postDatabaseGate.waitUntilEntered()
        try await harness.pipeline.setCorrectionResolved(
            meetingID: meeting.id, id: row.id, resolved: true,
            structuredNotes: nil)
        postDatabaseGate.release()
        await #expect(throws: EngineError.self) { try await edit.value }

        #expect(
            try await correctionRows(harness.database, meetingID: meeting.id)
                .first { $0.id == row.id }?.status == .resolved)
        #expect(await eventually { harness.clock.activeSleeperCount == 0 })
        harness.clock.advance(by: .seconds(3_600))
        await Task.yield()
        #expect(engine.callCount == 3)
    }

    @Test("AC-8: every correction mutation follows its arm-or-cancel rule")
    func mutationSchedulerMatrix() async throws {
        let engine = ScriptedNotesEditorEngine()
        engine.setOutcomes([
            .result([]), .result([]),
            .result([.replace(
                field: .summary, find: "One", replace: "Uno", instruction: 1)]),
        ])
        let harness = try await makeEditorHarness(engine: engine)

        let (deletedMeeting, _) = try await seedEditorMeeting(harness)
        let deleted = try await harness.pipeline.addCorrection(
            meetingID: deletedMeeting.id, kind: .understanding, section: .summary,
            quotedText: "One", occurrence: 0, userText: "delete")
        #expect(await eventually { harness.clock.activeSleeperCount == 1 })
        _ = try await harness.pipeline.deleteCorrection(
            meetingID: deletedMeeting.id, id: deleted.row.id)
        #expect(await eventually { harness.clock.activeSleeperCount == 0 })

        let (resolvedMeeting, _) = try await seedEditorMeeting(harness)
        let resolved = try await harness.pipeline.addCorrection(
            meetingID: resolvedMeeting.id, kind: .understanding, section: .summary,
            quotedText: "One", occurrence: 0, userText: "resolve")
        #expect(await eventually { harness.clock.activeSleeperCount == 1 })
        try await harness.pipeline.setCorrectionResolved(
            meetingID: resolvedMeeting.id, id: resolved.row.id, resolved: true,
            structuredNotes: nil)
        #expect(await eventually { harness.clock.activeSleeperCount == 0 })
        harness.clock.advance(by: .seconds(600))
        await Task.yield()
        #expect(engine.callCount == 0, "delete and resolve cancel; neither arms")

        let (editedMeeting, _) = try await seedEditorMeeting(harness)
        let edited = try await insertCorrection(
            harness.database, meetingID: editedMeeting.id, createdAt: harness.clock.now())
        _ = try await harness.pipeline.updateCorrection(
            meetingID: editedMeeting.id, id: edited.id, quotedText: "One",
            occurrence: 0, userText: "edited")
        #expect(await eventually { harness.clock.activeSleeperCount == 1 })
        harness.clock.advance(by: .seconds(300))
        #expect(await eventually { engine.callCount == 1 })

        let (reopenedMeeting, _) = try await seedEditorMeeting(harness)
        let reopened = try await insertCorrection(
            harness.database, meetingID: reopenedMeeting.id, status: .resolved,
            createdAt: harness.clock.now())
        try await harness.pipeline.setCorrectionResolved(
            meetingID: reopenedMeeting.id, id: reopened.id, resolved: false,
            structuredNotes: nil)
        #expect(await eventually { harness.clock.activeSleeperCount == 1 })
        harness.clock.advance(by: .seconds(300))
        #expect(await eventually { engine.callCount == 2 })

        let (appliedMeeting, _) = try await seedEditorMeeting(harness)
        _ = try await harness.pipeline.addCorrection(
            meetingID: appliedMeeting.id, kind: .understanding, section: .summary,
            quotedText: "One", occurrence: 0, userText: "Uno")
        #expect(await eventually { harness.clock.activeSleeperCount == 1 })
        try await harness.pipeline.sendPendingNotesToEditor(meetingID: appliedMeeting.id)
        #expect(engine.callCount == 3)
        #expect(await eventually { harness.clock.activeSleeperCount == 0 })
        #expect(
            try await correctionRows(harness.database, meetingID: appliedMeeting.id)
                .first?.status == .applied)

        let (annotationMeeting, _) = try await seedEditorMeeting(harness)
        _ = try await harness.pipeline.addCorrection(
            meetingID: annotationMeeting.id, kind: .annotation, section: .summary,
            quotedText: "One", occurrence: 0, userText: "Margin note")
        #expect(await eventually { harness.clock.activeSleeperCount == 0 })
        harness.clock.advance(by: .seconds(600))
        await Task.yield()
        #expect(engine.callCount == 3, "annotation writes never arm the editor")
    }

    @Test("AC-8: an unsupported selected engine refuses silently and preserves durable work")
    func unsupportedEngineRefusal() async throws {
        let harness = try await makeEditorHarness()
        let (meeting, _) = try await seedEditorMeeting(
            harness, lastProcessingError: "keep this non-editor marker")
        let row = try await insertCorrection(
            harness.database, meetingID: meeting.id, createdAt: harness.clock.now())
        let local = PipelineMockNotes(id: "local-without-editor", kind: .local)
        let registry = try EngineRegistry(asr: [], summarization: [local])
        try await SettingsStore(database: harness.database).set(
            EngineResolver.summarizationSettingsKey, to: local.id)
        let localPipeline = ProcessingPipeline(
            database: harness.database, registry: registry,
            diarizer: PipelineMockDiarizer(),
            vocabulary: try VocabFixtures.pipelineVocabulary(), now: harness.clock.now,
            notesEditorSleep: harness.clock.sleep,
            settleSleep: { _ in throw CancellationError() })

        try await localPipeline.editPendingNotes(meetingID: meeting.id)

        #expect(local.state.withLock { $0.requests.isEmpty })
        let storedRow = try #require(
            try await correctionRows(harness.database, meetingID: meeting.id).first)
        #expect(storedRow.id == row.id)
        #expect(storedRow.status == .pending)
        #expect(
            try await MeetingRepository(database: harness.database).fetch(meeting.id)?
                .lastProcessingError == "keep this non-editor marker")
    }

    @Test("AC-2/8: fallback skips a local non-editor and configuration failure never re-arms")
    func unsupportedFallbackIsNeverSentEditorWork() async throws {
        let root = try makeTempRoot()
        let database = try BlaiseDatabase(rootURL: root)
        let clock = EditorManualClock()
        let primary = ScriptedNotesEditorEngine(id: "primary-editor")
        primary.setOutcomes([.error(.configurationMissing(key: "fictional-editor-key"))])
        let local = PipelineMockNotes(id: "local-without-editor", kind: .local)
        let registry = try EngineRegistry(asr: [], summarization: [primary, local])
        let settings = SettingsStore(database: database)
        try await settings.set(EngineResolver.summarizationSettingsKey, to: primary.id)
        try await settings.set(UserIdentity.settingsKey, to: UserIdentity.onboardedUser)
        let pipeline = ProcessingPipeline(
            database: database, registry: registry, diarizer: PipelineMockDiarizer(),
            vocabulary: try VocabFixtures.pipelineVocabulary(), now: clock.now,
            notesEditorSleep: clock.sleep,
            settleSleep: { _ in throw CancellationError() })
        let harness = EditorHarness(
            root: root, database: database, pipeline: pipeline, engine: primary, clock: clock)
        let (meeting, _) = try await seedEditorMeeting(harness)
        _ = try await insertCorrection(
            database, meetingID: meeting.id, createdAt: clock.now())

        await #expect(throws: EngineError.self) {
            try await pipeline.sendPendingNotesToEditor(meetingID: meeting.id)
        }

        #expect(primary.callCount == 1)
        #expect(local.state.withLock { $0.requests.isEmpty })
        #expect(try await correctionRows(database, meetingID: meeting.id).first?.status == .pending)
        clock.advance(by: .seconds(3_600))
        await Task.yield()
        #expect(primary.callCount == 1)
        #expect(clock.activeSleeperCount == 0)
    }

    enum ReadFault: String, CaseIterable, Sendable {
        case correctionStore, notesStore
    }

    @Test(
        "AC-8: correction-store and notes read faults send nothing and schedule nothing",
        arguments: ReadFault.allCases)
    func readFaultsStopWithoutScheduling(_ fault: ReadFault) async throws {
        let engine = ScriptedNotesEditorEngine()
        engine.setOutcomes([.result([])])
        let harness = try await makeEditorHarness(engine: engine)
        let (meeting, _) = try await seedEditorMeeting(harness)
        _ = try await insertCorrection(
            harness.database, meetingID: meeting.id, createdAt: harness.clock.now())
        try await harness.database.pool.write { db in
            switch fault {
            case .correctionStore:
                try db.drop(table: "meeting_correction")
            case .notesStore:
                try db.drop(table: "meeting_notes")
            }
        }

        await #expect(throws: (any Error).self) {
            try await harness.pipeline.sendPendingNotesToEditor(meetingID: meeting.id)
        }

        #expect(engine.callCount == 0)
        harness.clock.advance(by: .seconds(3_600))
        await Task.yield()
        #expect(engine.callCount == 0)
        #expect(harness.clock.activeSleeperCount == 0)
    }

    @Test("AC-8: a queued duplicate finding no pending rows makes no model call")
    func noPendingDuplicateIsNoOp() async throws {
        let engine = ScriptedNotesEditorEngine()
        engine.setOutcomes([.result([.replace(
            field: .summary, find: "One", replace: "Uno", instruction: 1)])])
        let harness = try await makeEditorHarness(engine: engine)
        let (meeting, _) = try await seedEditorMeeting(harness)
        _ = try await insertCorrection(
            harness.database, meetingID: meeting.id, createdAt: harness.clock.now())
        try await harness.pipeline.editPendingNotes(meetingID: meeting.id)
        try await harness.pipeline.editPendingNotes(meetingID: meeting.id)
        #expect(engine.callCount == 1)
    }

    @Test("AC-9: app-wide chain serializes editor calls")
    func editorJobsSerializeGlobally() async throws {
        let gate = EditorGate()
        let engine = ScriptedNotesEditorEngine()
        engine.setGate(gate)
        engine.setOutcomes([.result([]), .result([])])
        let harness = try await makeEditorHarness(engine: engine)
        let (firstMeeting, _) = try await seedEditorMeeting(harness)
        let (secondMeeting, _) = try await seedEditorMeeting(harness)
        _ = try await insertCorrection(
            harness.database, meetingID: firstMeeting.id, createdAt: harness.clock.now())
        _ = try await insertCorrection(
            harness.database, meetingID: secondMeeting.id, createdAt: harness.clock.now())

        let first = Task { try await harness.pipeline.editPendingNotes(meetingID: firstMeeting.id) }
        await gate.waitUntilEntered()
        let second = Task { try await harness.pipeline.editPendingNotes(meetingID: secondMeeting.id) }
        await Task.yield()
        #expect(engine.callCount == 1)
        #expect(engine.maximumActiveCalls == 1)
        gate.release()
        try await requireCompletesWithin(.seconds(2)) {
            try await first.value
            try await second.value
        }
        #expect(engine.callCount == 2)
        #expect(engine.maximumActiveCalls == 1)
    }

    @Test("AC-9: editor queues behind an existing writer and never re-enters the pipeline chain")
    func existingWriterAndNonReentrancy() async throws {
        let kicker = BlockingFirstKicker()
        let engine = ScriptedNotesEditorEngine()
        engine.setOutcomes([.result([.replace(
            field: .summary, find: "One", replace: "Uno", instruction: 1)])])
        let harness = try await makeEditorHarness(engine: engine, handoffKicker: kicker)
        let (meeting, _) = try await seedEditorMeeting(harness)
        _ = try await insertCorrection(
            harness.database, meetingID: meeting.id, createdAt: harness.clock.now())

        // The settle DELIVERY is the chain-holding writer here: N4 moved the
        // handoff kick off the re-mint and onto the one pooled delivery, so the
        // delivery is what can be held inside its own chain link.
        try await harness.database.pool.write { db in
            try db.execute(
                sql: "UPDATE meeting_notes SET delivery_owed = 1 WHERE meeting_id = ?",
                arguments: [meeting.id])
        }
        let writer = Task {
            _ = try await harness.pipeline.deliverSettled(meetingID: meeting.id)
        }
        await kicker.waitUntilEntered()
        let editor = Task {
            try await harness.pipeline.editPendingNotes(meetingID: meeting.id)
        }
        await Task.yield()
        #expect(engine.callCount == 0, "the existing notes writer owns the global chain")
        kicker.release()

        try await requireCompletesWithin(.seconds(2)) {
            try await writer.value
            try await editor.value
        }
        #expect(engine.callCount == 1)
        #expect(
            try await NotesRepository(database: harness.database)
                .fetch(meetingID: meeting.id)?.structured.summary
                == "Uno Two Three Four")
    }

    @Test("AC-10: cancel signals the editor token and clears activity")
    func cancellationAndActivity() async throws {
        let gate = EditorGate()
        let engine = ScriptedNotesEditorEngine()
        engine.setGate(gate)
        engine.setOutcomes([.result([
            .replace(field: .summary, find: "One", replace: "Uno", instruction: 1)
        ])])
        let harness = try await makeEditorHarness(engine: engine)
        let (meeting, beforeNotes) = try await seedEditorMeeting(harness)
        let row = try await insertCorrection(
            harness.database, meetingID: meeting.id, createdAt: harness.clock.now())
        let events = await harness.pipeline.events()
        let eventTask = Task { () -> [PipelineEvent] in
            var collected: [PipelineEvent] = []
            for await event in events {
                collected.append(event)
                if case .runCompleted = event { break }
                if case .runFailed = event { break }
            }
            return collected
        }
        let editTask = Task { try await harness.pipeline.editPendingNotes(meetingID: meeting.id) }
        await gate.waitUntilEntered()
        #expect(await harness.pipeline.hasRunInFlight(meeting.id))
        #expect(await harness.pipeline.cancel(meetingID: meeting.id))
        gate.release()
        do {
            try await editTask.value
            Issue.record("cancelled editor should fail")
        } catch let error as EngineError {
            #expect(error == .cancelled)
        }
        let collected = await eventTask.value
        #expect(collected.contains(.runStarted(meeting.id, regeneration: true)))
        #expect(collected.contains(.stageBegan(meeting.id, .notes)))
        #expect(collected.contains { event in
            if case .runFailed(let id, .notes, _) = event { return id == meeting.id }
            return false
        })
        let holder = await MainActor.run { PipelineActivityHolder() }
        for event in collected { await MainActor.run { _ = holder.apply(event) } }
        #expect(await MainActor.run { holder.activeRuns[meeting.id] == nil })
        #expect(!(await harness.pipeline.hasRunInFlight(meeting.id)))
        #expect(try await MeetingRepository(database: harness.database).fetch(meeting.id)?.status == .ready)
        #expect(try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id) == beforeNotes)
        #expect(try await correctionRows(harness.database, meetingID: meeting.id).first?.id == row.id)
        #expect(try await correctionRows(harness.database, meetingID: meeting.id).first?.status == .pending)
        harness.clock.advance(by: .seconds(600))
        await Task.yield()
        #expect(engine.callCount == 1)
    }

    @Test("AC-10: clean editor activity emits the exact notes-stage sequence")
    func successfulEventSequence() async throws {
        let engine = ScriptedNotesEditorEngine()
        engine.setOutcomes([.result([])])
        let harness = try await makeEditorHarness(engine: engine)
        let (meeting, _) = try await seedEditorMeeting(harness)
        _ = try await insertCorrection(
            harness.database, meetingID: meeting.id, createdAt: harness.clock.now())
        let stream = await harness.pipeline.events()
        let collector = Task { () -> [PipelineEvent] in
            var events: [PipelineEvent] = []
            for await event in stream {
                events.append(event)
                if case .runCompleted = event { break }
                if case .runFailed = event { break }
            }
            return events
        }

        try await harness.pipeline.editPendingNotes(meetingID: meeting.id)

        #expect(await collector.value == [
            .runStarted(meeting.id, regeneration: true),
            .stageBegan(meeting.id, .notes),
            .stageFinished(meeting.id, .notes),
            .runCompleted(meeting.id),
        ])
    }

    @Test("AC-10: cancellation at the primary boundary prevents the fallback send")
    func cancellationPreventsFallback() async throws {
        let root = try makeTempRoot()
        let database = try BlaiseDatabase(rootURL: root)
        let clock = EditorManualClock()
        let gate = EditorGate()
        let primary = ScriptedNotesEditorEngine(id: "primary-editor")
        primary.setGate(gate)
        primary.setOutcomes([.error(.configurationMissing(key: "primary"))])
        let fallback = ScriptedNotesEditorEngine(id: "fallback-editor")
        fallback.setOutcomes([.result([])])
        let registry = try EngineRegistry(asr: [], summarization: [primary, fallback])
        let settings = SettingsStore(database: database)
        try await settings.set(EngineResolver.summarizationSettingsKey, to: primary.id)
        try await settings.set(UserIdentity.settingsKey, to: UserIdentity.onboardedUser)
        let pipeline = ProcessingPipeline(
            database: database, registry: registry, diarizer: PipelineMockDiarizer(),
            vocabulary: try VocabFixtures.pipelineVocabulary(), now: clock.now,
            notesEditorSleep: clock.sleep,
            settleSleep: { _ in throw CancellationError() })
        let harness = EditorHarness(
            root: root, database: database, pipeline: pipeline, engine: primary, clock: clock)
        let (meeting, beforeNotes) = try await seedEditorMeeting(harness)
        _ = try await insertCorrection(
            database, meetingID: meeting.id, createdAt: clock.now())

        let task = Task { try await pipeline.editPendingNotes(meetingID: meeting.id) }
        await gate.waitUntilEntered()
        #expect(await pipeline.cancel(meetingID: meeting.id))
        gate.release()
        do {
            try await task.value
            Issue.record("cancelled primary must not fall back")
        } catch let error as EngineError {
            #expect(error == .cancelled)
        }
        #expect(primary.callCount == 1)
        #expect(fallback.callCount == 0)
        #expect(try await NotesRepository(database: database).fetch(meetingID: meeting.id) == beforeNotes)
    }

    @Test("AC-11: successful persistence changes only editor-owned artifacts")
    func successfulArtifactPersistence() async throws {
        let rawTitle = String(repeating: "Long title ", count: 12)
        let initialStructured = NotesStructured(
            title: "Old title", summary: "Old S1 claim.",
            meetingType: .oneOnOne,
            detailedNotes: "Untouched details.", decisions: ["Untouched decision"],
            actionItems: [ActionItem(owner: "Sam", text: "Untouched action")],
            userActionItems: [ActionItem(owner: "Sam", text: "Untouched personal action")])
        let engine = ScriptedNotesEditorEngine()
        engine.setOutcomes([.result([
            .replace(field: .title, find: "Old title", replace: rawTitle, instruction: 1),
            .replace(
                field: .summary, find: "Old S1 claim.", replace: "New S1 claim.",
                instruction: 1),
        ])])
        let harness = try await makeEditorHarness(engine: engine)
        let segment = TranscriptSegment(
            meetingID: "01J00000000000000000000000", ord: 0,
            startSeconds: 0, endSeconds: 1, speakerLabel: "S1",
            speakerName: "Alice",
            text: "Transcric\u{0327}a\u{0303}o stays byte-exact")
        let (meeting, beforeNotes) = try await seedEditorMeeting(
            harness, title: "Date title", titleSource: .default,
            structured: initialStructured, segments: [segment])
        let transcriptArtifactBefore = Data(
            #"{"meeting":"Quoll Harbor","segments":[{"speaker":"S1","text":"Transcript stays exact"}]}"#.utf8)
        try transcriptArtifactBefore.write(
            to: harness.database.paths.transcriptURL(meeting.id), options: .atomic)
        let transcriptBefore = try await TranscriptRepository(database: harness.database)
            .segments(meetingID: meeting.id)
        let understanding = try await insertCorrection(
            harness.database, meetingID: meeting.id, quotedText: "Old S1 claim.",
            userText: "Make it new", createdAt: harness.clock.now())
        let annotation = try await insertCorrection(
            harness.database, meetingID: meeting.id, status: .applied,
            kind: .annotation, quotedText: "Old S1 claim.", userText: "Pinned note",
            createdAt: harness.clock.now().addingTimeInterval(1))
        let decisionAnnotation = try await insertCorrection(
            harness.database, meetingID: meeting.id, status: .applied,
            kind: .annotation, section: .decision,
            quotedText: "Untouched decision", userText: "Decision margin note",
            createdAt: harness.clock.now().addingTimeInterval(2))

        try await harness.pipeline.editPendingNotes(meetingID: meeting.id)

        let storedMeeting = try #require(
            try await MeetingRepository(database: harness.database).fetch(meeting.id))
        let storedNotes = try #require(
            try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id))
        let promoted = try #require(ProcessingPipeline.promotedLLMTitle(from: rawTitle))
        #expect(storedMeeting.title == promoted)
        #expect(storedMeeting.titleSource == TitleSource.llm)
        #expect(storedMeeting.updatedAt > meeting.updatedAt)
        #expect(storedNotes.structured.title == rawTitle)
        #expect(storedNotes.structured.summary == "New Alice claim.")
        #expect(storedNotes.structured.detailedNotes == beforeNotes.structured.detailedNotes)
        #expect(storedNotes.structured.decisions == beforeNotes.structured.decisions)
        #expect(storedNotes.structured.actionItems == beforeNotes.structured.actionItems)
        #expect(storedNotes.structured.userActionItems == beforeNotes.structured.userActionItems)
        #expect(storedNotes.structured.meetingType == beforeNotes.structured.meetingType)
        #expect(storedNotes.language == beforeNotes.language)
        #expect(storedNotes.provenance == beforeNotes.provenance)
        #expect(storedNotes.generatedAt == beforeNotes.generatedAt)
        #expect(storedNotes.memoryDigest == beforeNotes.memoryDigest)
        #expect(storedNotes.scopedAliasBindings == beforeNotes.scopedAliasBindings)
        var expectedStoredStructured = initialStructured
        expectedStoredStructured.title = rawTitle
        expectedStoredStructured.summary = "New Alice claim."
        var expectedRenderStructured = expectedStoredStructured
        expectedRenderStructured.title = promoted
        let expectedMarkdown = try NotesRenderer.render(
            expectedRenderStructured, language: beforeNotes.language,
            meetingTitle: promoted, userName: UserIdentity.onboardedUser.name,
            annotations: [annotation, decisionAnnotation])
        #expect(Array(storedNotes.markdown.utf8) == Array(expectedMarkdown.utf8))
        #expect(storedNotes.markdown.contains("Pinned note"))
        #expect(storedNotes.markdown.contains("Decision margin note"))
        let notesFile = try Data(contentsOf: harness.database.paths.notesURL(meeting.id))
        #expect(notesFile == Data(expectedMarkdown.utf8))
        let transcriptAfter = try await TranscriptRepository(database: harness.database)
            .segments(meetingID: meeting.id)
        expectTranscriptColumnsByteEqual(transcriptAfter, transcriptBefore)
        #expect(
            try Data(contentsOf: harness.database.paths.transcriptURL(meeting.id))
                == transcriptArtifactBefore)
        #expect(engine.fullNotesCallCount == 0)
        #expect(engine.digestCallCount == 0)

        let rows = try await correctionRows(harness.database, meetingID: meeting.id)
        let finalUnderstanding = rows.first { $0.id == understanding.id }
        let finalAnnotation = rows.first { $0.id == annotation.id }
        let finalDecisionAnnotation = rows.first { $0.id == decisionAnnotation.id }
        #expect(finalUnderstanding?.status == MeetingCorrection.Status.applied)
        #expect(finalAnnotation?.status == MeetingCorrection.Status.stale)
        #expect(finalDecisionAnnotation?.status == MeetingCorrection.Status.applied)
        // N4: the apply-time delivery is dead. What the persist leaves behind is
        // the settle chain's durable intent — nothing is queued here, and the
        // pooled settle delivery is what ships this markdown.
        #expect(try await harness.database.pool.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM handoff_queue WHERE meeting_id = ?",
                arguments: [meeting.id]) ?? -1
        } == 0)
        #expect(storedNotes.deliveryOwed)
        #expect(storedNotes.digestEditOwed)
    }

    @Test("AC-11: zero-effective response mutates no artifacts")
    func zeroEffectiveIsWriteFree() async throws {
        let engine = ScriptedNotesEditorEngine()
        engine.setOutcomes([.result([
            .replace(field: .summary, find: "missing", replace: "new", instruction: 1)
        ])])
        let harness = try await makeEditorHarness(engine: engine)
        let (meeting, notesBefore) = try await seedEditorMeeting(harness)
        let row = try await insertCorrection(
            harness.database, meetingID: meeting.id, createdAt: harness.clock.now())
        let meetingBefore = try await MeetingRepository(database: harness.database).fetch(meeting.id)
        let transcriptBefore = try await TranscriptRepository(database: harness.database)
            .segments(meetingID: meeting.id)
        let fileBefore = try Data(contentsOf: harness.database.paths.notesURL(meeting.id))

        try await harness.pipeline.editPendingNotes(meetingID: meeting.id)

        #expect(try await MeetingRepository(database: harness.database).fetch(meeting.id) == meetingBefore)
        #expect(try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id) == notesBefore)
        #expect(try Data(contentsOf: harness.database.paths.notesURL(meeting.id)) == fileBefore)
        #expect(
            try await TranscriptRepository(database: harness.database)
                .segments(meetingID: meeting.id) == transcriptBefore)
        #expect(try await correctionRows(harness.database, meetingID: meeting.id).first?.id == row.id)
        #expect(try await correctionRows(harness.database, meetingID: meeting.id).first?.status == .pending)
        #expect(try await harness.database.pool.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM handoff_queue WHERE meeting_id = ?",
                arguments: [meeting.id]) ?? -1
        } == 0)
        #expect(engine.fullNotesCallCount == 0)
        #expect(engine.digestCallCount == 0)
    }

    @Test("AC-11: user and calendar meeting titles remain authoritative")
    func authoritativeTitleSourcesStayByteExact() async throws {
        for source in [TitleSource.user, .calendar] {
            let engine = ScriptedNotesEditorEngine(id: "editor-\(source.rawValue)")
            engine.setOutcomes([.result([.replace(
                field: .title, find: "Notes", replace: "Model-authored title",
                instruction: 1)])])
            let harness = try await makeEditorHarness(engine: engine)
            let (meeting, _) = try await seedEditorMeeting(
                harness, title: "Authoritative title", titleSource: source)
            _ = try await insertCorrection(
                harness.database, meetingID: meeting.id, quotedText: "Notes",
                userText: "Change the title", createdAt: harness.clock.now())

            try await harness.pipeline.editPendingNotes(meetingID: meeting.id)

            let storedMeeting = try #require(
                try await MeetingRepository(database: harness.database).fetch(meeting.id))
            let storedNotes = try #require(
                try await NotesRepository(database: harness.database).fetch(
                    meetingID: meeting.id))
            #expect(storedMeeting.title == "Authoritative title")
            #expect(storedMeeting.titleSource == source)
            #expect(storedNotes.structured.title == "Model-authored title")
        }
    }

    @Test("AC-11: final-transaction failure rolls back notes, anchors, handoff, and completion")
    func finalTransactionRollback() async throws {
        let engine = ScriptedNotesEditorEngine()
        engine.setOutcomes([.result([
            .replace(field: .summary, find: "One", replace: "Uno", instruction: 1)
        ])])
        let harness = try await makeEditorHarness(engine: engine)
        let (meeting, notesBefore) = try await seedEditorMeeting(harness)
        let understanding = try await insertCorrection(
            harness.database, meetingID: meeting.id, quotedText: "One",
            userText: "Uno", createdAt: harness.clock.now())
        let annotation = try await insertCorrection(
            harness.database, meetingID: meeting.id, status: .applied,
            kind: .annotation, quotedText: "One", userText: "Pinned",
            createdAt: harness.clock.now().addingTimeInterval(1))
        // The apply-time enqueue is gone, so the forced failure lands on the
        // re-anchor write the same transaction performs after the notes upsert.
        try await harness.database.pool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_editor_reanchor BEFORE UPDATE ON meeting_correction
                BEGIN SELECT RAISE(FAIL, 'forced editor re-anchor failure'); END
                """)
        }

        do {
            try await harness.pipeline.sendPendingNotesToEditor(meetingID: meeting.id)
            Issue.record("forced transaction failure should escape")
        } catch {
            // Expected GRDB persistence error.
        }

        #expect(try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id) == notesBefore)
        let rows = try await correctionRows(harness.database, meetingID: meeting.id)
        #expect(rows.first { $0.id == understanding.id }?.status == .pending)
        #expect(rows.first { $0.id == annotation.id }?.status == .applied)
        #expect(try await harness.database.pool.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM handoff_queue WHERE meeting_id = ?",
                arguments: [meeting.id]) ?? -1
        } == 0)
        let fileAfter = try String(
            contentsOf: harness.database.paths.notesURL(meeting.id), encoding: .utf8)
        #expect(fileAfter.contains("Uno"), "the contract intentionally leaves the file-ahead write")
        let meetingAfter = try #require(
            try await MeetingRepository(database: harness.database).fetch(meeting.id))
        #expect(meetingAfter.updatedAt > meeting.updatedAt)
        harness.clock.advance(by: .seconds(3_600))
        await Task.yield()
        #expect(engine.callCount == 1, "persistence failure must not timer-retry")
    }
}
