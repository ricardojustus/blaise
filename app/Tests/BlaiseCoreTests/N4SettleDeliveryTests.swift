import Foundation
import GRDB
import Synchronization
import Testing

@testable import BlaiseCore

// N4 — digest editing, the session settle, and the one pooled delivery.
// Every fixture is FICTIONAL (Vexatron Labs / Quoll Harbor).

// MARK: - A scripted engine that can edit notes AND digests

/// Synthesis is scripted too, so ONE engine can serve a whole arc lifecycle
/// (full synthesis → notes editing → digest editing) with four independent
/// counters. Both synthesis methods still throw while unscripted, which is what
/// keeps every "no full synthesis happened" oracle in this file non-vacuous.
final class SettleScriptedEngine:
    SummarizationEngine, NotesEditingEngine, DigestEditingEngine, @unchecked Sendable
{
    struct State {
        var notesOutcomes: [[NotesEditOperation]] = []
        var notesErrors: [EngineError?] = []
        var notesRequests: [NotesEditorRequest] = []
        var digestOutcomes: [[DigestEditOperation]] = []
        var digestErrors: [EngineError?] = []
        var digestRequests: [DigestEditorRequest] = []
        var digestPurposes: [CloudSpendPurpose] = []
        var digestGate: EditorGate?
        var notesGate: EditorGate?
        var prepareCalls = 0
        var notesSyntheses: [NotesStructured] = []
        var notesSynthesisRequests: [NotesRequest] = []
        var notesSynthesisGate: EditorGate?
        var digestSyntheses: [String] = []
        var digestSynthesisRequests: [DigestRequest] = []
    }

    let id: String
    let displayName = "Settle scripted engine"
    let kind: EngineKind = .cloud
    let loadProfile: EngineLoadProfile = .lightweight
    let costDescriptor: EngineCostDescriptor? = nil
    let configDescriptors: [EngineConfigDescriptor] = []
    let state = Mutex(State())

    init(id: String = "settle-scripted-engine") { self.id = id }

    func availability() async -> EngineAvailability { .available }
    func prepare() async throws { state.withLock { $0.prepareCalls += 1 } }

    func generateNotes(
        _ request: NotesRequest, purpose: CloudSpendPurpose
    ) async throws -> NotesResult {
        let gate = state.withLock { state -> EditorGate? in
            state.notesSynthesisRequests.append(request)
            return state.notesSynthesisGate
        }
        if let gate { await gate.enterAndWait() }
        guard
            let structured = state.withLock({ state -> NotesStructured? in
                state.notesSyntheses.isEmpty ? nil : state.notesSyntheses.removeFirst()
            })
        else { throw EngineError.permanent("unexpected full notes call") }
        return NotesResult(
            structured: structured,
            usage: EngineUsage(inputUnits: 100, outputUnits: 50),
            provenance: NotesProvenance(
                engine: id, model: "scripted", pipelineVersion: "", runtime: "scripted",
                rendererVersion: "", promptVersion: "scripted"),
            speakerNameMapping: [])
    }

    func generateDigest(
        _ request: DigestRequest, purpose: CloudSpendPurpose
    ) async throws -> DigestResult {
        guard
            let digest = state.withLock({ state -> String? in
                state.digestSynthesisRequests.append(request)
                return state.digestSyntheses.isEmpty ? nil : state.digestSyntheses.removeFirst()
            })
        else { throw EngineError.permanent("unexpected digest synthesis call") }
        return DigestResult(
            digest: digest,
            usage: EngineUsage(inputUnits: 80, outputUnits: 40, estimatedCostUSD: nil),
            promptVersion: DigestPromptBuilder.shippedVersion.rawValue)
    }

    func editNotes(
        _ request: NotesEditorRequest, purpose: CloudSpendPurpose
    ) async throws -> NotesEditorResult {
        let gate = state.withLock { state -> EditorGate? in
            state.notesRequests.append(request)
            return state.notesGate
        }
        if let gate { await gate.enterAndWait() }
        let outcome = state.withLock { state -> (EngineError?, [NotesEditOperation]) in
            let error = state.notesErrors.isEmpty ? nil : state.notesErrors.removeFirst()
            let ops = state.notesOutcomes.isEmpty ? [] : state.notesOutcomes.removeFirst()
            return (error, ops)
        }
        if let error = outcome.0 { throw error }
        return NotesEditorResult(operations: outcome.1, usage: nil)
    }

    func editDigest(
        _ request: DigestEditorRequest, purpose: CloudSpendPurpose
    ) async throws -> DigestEditorResult {
        let gate = state.withLock { state -> EditorGate? in
            state.digestRequests.append(request)
            state.digestPurposes.append(purpose)
            return state.digestGate
        }
        if let gate { await gate.enterAndWait() }
        let outcome = state.withLock { state -> (EngineError?, [DigestEditOperation]) in
            let error = state.digestErrors.isEmpty ? nil : state.digestErrors.removeFirst()
            let ops = state.digestOutcomes.isEmpty ? [] : state.digestOutcomes.removeFirst()
            return (error, ops)
        }
        if let error = outcome.0 { throw error }
        return DigestEditorResult(
            operations: outcome.1,
            usage: EngineUsage(inputUnits: 40, outputUnits: 10, estimatedCostUSD: nil))
    }

    var notesCallCount: Int { state.withLock { $0.notesRequests.count } }
    var digestCallCount: Int { state.withLock { $0.digestRequests.count } }
    var notesSynthesisCallCount: Int { state.withLock { $0.notesSynthesisRequests.count } }
    var digestSynthesisCallCount: Int { state.withLock { $0.digestSynthesisRequests.count } }
    /// Every model call this engine served, whatever its kind.
    var totalModelCallCount: Int {
        state.withLock {
            $0.notesRequests.count + $0.digestRequests.count
                + $0.notesSynthesisRequests.count + $0.digestSynthesisRequests.count
        }
    }
    var digestRequests: [DigestEditorRequest] { state.withLock { $0.digestRequests } }
    var digestPurposes: [CloudSpendPurpose] { state.withLock { $0.digestPurposes } }

    func scriptNotes(_ ops: [[NotesEditOperation]], errors: [EngineError?] = []) {
        state.withLock {
            $0.notesOutcomes = ops
            $0.notesErrors = errors
        }
    }

    func scriptDigest(_ ops: [[DigestEditOperation]], errors: [EngineError?] = []) {
        state.withLock {
            $0.digestOutcomes = ops
            $0.digestErrors = errors
        }
    }
}

/// A local engine stand-in: it can synthesize but conforms to NEITHER editing
/// protocol, which is what makes the chain's skip arms representable.
final class SettleNonEditingEngine: SummarizationEngine, @unchecked Sendable {
    let id = "settle-non-editing-engine"
    let displayName = "Settle non-editing engine"
    let kind: EngineKind = .local
    let loadProfile: EngineLoadProfile = .lightweight
    let costDescriptor: EngineCostDescriptor? = nil
    let configDescriptors: [EngineConfigDescriptor] = []

    func availability() async -> EngineAvailability { .available }
    func prepare() async throws {}
    func generateNotes(
        _ request: NotesRequest, purpose: CloudSpendPurpose
    ) async throws -> NotesResult {
        throw EngineError.permanent("unexpected notes call")
    }
    func generateDigest(
        _ request: DigestRequest, purpose: CloudSpendPurpose
    ) async throws -> DigestResult {
        throw EngineError.permanent("unexpected digest call")
    }
}

// MARK: - Harness

struct SettleHarness {
    let root: URL
    let database: BlaiseDatabase
    let pipeline: ProcessingPipeline
    let engine: SettleScriptedEngine
    let clock: EditorManualClock
    let settleClock: EditorManualClock

    func queueRows(_ id: MeetingID) async throws -> Int {
        try await database.pool.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM handoff_queue WHERE meeting_id = ?",
                arguments: [id]) ?? -1
        }
    }

    func notes(_ id: MeetingID) async throws -> MeetingNotes {
        try #require(try await NotesRepository(database: database).fetch(meetingID: id))
    }

    func latestPayload(_ id: MeetingID) async throws -> [String: Any] {
        let item = try #require(try await database.pool.read { db in
            try HandoffItem
                .filter(Column("meeting_id") == id)
                .order(Column("created_seq").desc)
                .fetchOne(db)
        })
        let data = try Data(contentsOf: root.appendingPathComponent(item.payloadPath))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

let settleDigestFixture = """
    ## HEADER
    meeting: Vexatron Labs field-kit review
    date: 2026-03-14
    speaker: Dana Marsh

    ## DECISIONS
    Dana Marsh decided on 2026-03-14 to ship the Quoll Harbor field kit in May 2026.

    ## STATUS
    The Quoll Harbor field kit reached 70% coverage as of 2026-03-14.
    """

func makeSettleHarness(
    root: URL? = nil,
    database: BlaiseDatabase? = nil,
    engine: SettleScriptedEngine = SettleScriptedEngine(),
    extraEngines: [any SummarizationEngine] = [],
    selectedEngineID: String? = nil,
    clock: EditorManualClock = EditorManualClock(),
    settleClock: EditorManualClock = EditorManualClock(),
    handoffKicker: any HandoffKicking = NoopHandoffKicker(),
    afterSettleTerminalStep: (@Sendable (MeetingID) async -> Void)? = nil
) async throws -> SettleHarness {
    let root = try root ?? makeTempRoot()
    let database = try database ?? BlaiseDatabase(rootURL: root)
    let registry = try EngineRegistry(asr: [], summarization: [engine] + extraEngines)
    let settings = SettingsStore(database: database)
    try await settings.set(
        EngineResolver.summarizationSettingsKey, to: selectedEngineID ?? engine.id)
    try await settings.set(UserIdentity.settingsKey, to: UserIdentity.onboardedUser)
    let pipeline = ProcessingPipeline(
        database: database, registry: registry, diarizer: PipelineMockDiarizer(),
        vocabulary: try VocabFixtures.pipelineVocabulary(), handoffKicker: handoffKicker,
        now: clock.now, notesEditorSleep: clock.sleep, settleSleep: settleClock.sleep,
        afterSettleTerminalStep: afterSettleTerminalStep)
    return SettleHarness(
        root: root, database: database, pipeline: pipeline, engine: engine, clock: clock,
        settleClock: settleClock)
}

@discardableResult
func seedSettleMeeting(
    _ harness: SettleHarness,
    digest: String? = settleDigestFixture,
    digestPromptVersion: String? = DigestPromptBuilder.shippedVersion.rawValue,
    title: String = "Vexatron Labs field-kit review",
    titleSource: TitleSource = .user,
    lastProcessingError: String? = nil
) async throws -> Meeting {
    let id = ULID.generate()
    let timestamp = harness.clock.now()
    let meeting = Meeting(
        id: id, title: title, titleSource: titleSource,
        startedAt: timestamp.addingTimeInterval(-600), endedAt: timestamp,
        source: .meet, status: .ready, attendees: [], dominantLanguage: "en",
        asrProvenance: ASRProvenance(
            engine: "test", model: "test", runtime: "test", engineVersion: "1",
            transcribedAt: timestamp),
        lastProcessingError: lastProcessingError,
        createdAt: timestamp.addingTimeInterval(-600), updatedAt: timestamp)
    try harness.database.paths.createMeetingDirectory(id)
    try await MeetingRepository(database: harness.database).create(meeting)
    _ = try await TranscriptRepository(database: harness.database).replaceAllSegments(
        meetingID: id,
        with: [
            TranscriptSegment(
                meetingID: id, ord: 0, startSeconds: 0, endSeconds: 1,
                speakerLabel: "S0", speakerName: "Dana Marsh",
                text: "The field kit ships in May.")
        ])
    let structured = NotesStructured(
        title: "Field-kit review", summary: "Ships in May.",
        detailedNotes: "The Quoll Harbor field kit ships in May.",
        decisions: ["Ship the field kit in May"],
        actionItems: [ActionItem(owner: "Dana Marsh", text: "Confirm the ship date")],
        userActionItems: [])
    let markdown = try NotesRenderer.render(
        structured, language: "en", meetingTitle: title,
        userName: UserIdentity.onboardedUser.name, annotations: [])
    let notes = MeetingNotes(
        meetingID: id, markdown: markdown, structured: structured, language: "en",
        generatedAt: timestamp.addingTimeInterval(-60),
        provenance: NotesProvenance(
            engine: "seed", model: "seed", pipelineVersion: "seed", runtime: "seed",
            rendererVersion: NotesRenderer.version, promptVersion: "seed"),
        memoryDigest: digest,
        digestPromptVersion: digest == nil ? nil : digestPromptVersion)
    try await NotesRepository(database: harness.database).upsert(notes)
    try Data(markdown.utf8).write(
        to: harness.database.paths.notesURL(id), options: .atomic)
    return meeting
}

@discardableResult
func seedSettleCorrection(
    _ harness: SettleHarness,
    meetingID: MeetingID,
    kind: MeetingCorrection.Kind = .understanding,
    status: MeetingCorrection.Status = .pending,
    section: MeetingCorrection.Section = .summary,
    quotedText: String = "Ships in May.",
    userText: String = "It ships in June.",
    createdAt: Date
) async throws -> MeetingCorrection {
    let row = MeetingCorrection(
        id: ULID.generate(), meetingID: meetingID, kind: kind, section: section,
        quotedText: quotedText, occurrence: 0, userText: userText, status: status,
        createdAt: createdAt, appliedAt: nil)
    try await harness.database.pool.write { db in
        try MeetingCorrectionStore.insert(db, row)
    }
    return row
}

// MARK: - SC-15 / SC-17: the pure applier and its structural assertion

@Suite struct N4DigestApplierTests {
    @Test("SC-15: replace-all, empty find, unmatched find, and the literal NFC/NFD no-op")
    func applierSemantics() throws {
        let digest = "## HEADER\nmeeting: Quoll Harbor sync\n\n## FACTS\nAda ships. Ada ships.\n"
        let replaced = try #require(
            DigestEditApplier.apply(
                [DigestEditOperation(find: "Ada ships.", replace: "Bo ships.", instruction: 1)],
                to: digest))
        #expect(!replaced.contains("Ada"))
        #expect(replaced.components(separatedBy: "Bo ships.").count == 3)

        // An empty find is a no-op (the schema cannot forbid empty strings).
        #expect(
            DigestEditApplier.apply(
                [DigestEditOperation(find: "", replace: "X", instruction: 1)], to: digest)
                == digest)
        // An unmatched find is a no-op.
        #expect(
            DigestEditApplier.apply(
                [DigestEditOperation(find: "absent", replace: "X", instruction: 1)], to: digest)
                == digest)

        // `.literal` is codepoint-exact: an NFD-stored digest with an NFC find
        // deterministically matches nothing.
        let nfd = "## HEADER\nmeeting: Ac\u{0327}a\u{0301}o review\n"
        #expect(
            DigestEditApplier.apply(
                [DigestEditOperation(find: "Açáo", replace: "Ação", instruction: 1)], to: nfd)
                == nfd)
    }

    @Test("SC-17: the structural assertion discards renamed, reordered, duplicated, invented, non-md-v1 and HEADER-erasing results")
    func structuralAssertion() {
        let digest = """
            ## HEADER
            meeting: Quoll Harbor sync

            ## DECISIONS
            Ada ships in May.

            ## STATUS
            Coverage is 70% as of 2026-03-14.
            """
        // Erasing HEADER.
        #expect(
            DigestEditApplier.apply(
                [DigestEditOperation(find: "## HEADER", replace: "", instruction: 1)], to: digest)
                == nil)
        // Renaming a surviving header.
        #expect(
            DigestEditApplier.apply(
                [DigestEditOperation(find: "## DECISIONS", replace: "## CHOICES", instruction: 1)],
                to: digest) == nil)
        // Inventing a section.
        #expect(
            DigestEditApplier.apply(
                [DigestEditOperation(
                    find: "Ada ships in May.", replace: "Ada ships in May.\n\n## NOTES\nExtra.",
                    instruction: 1)],
                to: digest) == nil)
        // Duplicating a header.
        #expect(
            DigestEditApplier.apply(
                [DigestEditOperation(
                    find: "## DECISIONS", replace: "## DECISIONS\n\n## DECISIONS", instruction: 1)],
                to: digest) == nil)
        // Reordering (STATUS lifted above DECISIONS).
        let reordered = """
            ## HEADER
            meeting: Quoll Harbor sync

            ## STATUS
            Coverage is 70% as of 2026-03-14.

            ## DECISIONS
            Ada ships in May.
            """
        #expect(!DigestEditApplier.isStructurallySound(reordered, against: digest))
        // A heading outside the eight md-v1 headings never ships, even inherited.
        #expect(
            !DigestEditApplier.isStructurallySound(
                "## HEADER\nx\n\n## APPENDIX\ny", against: "## HEADER\nx\n\n## APPENDIX\ny"))
        // A legitimate emptied-section removal passes the subsequence check.
        let emptied = """
            ## HEADER
            meeting: Quoll Harbor sync

            ## DECISIONS
            Ada ships in May.
            """
        #expect(DigestEditApplier.isStructurallySound(emptied, against: digest))
        #expect(DigestEditApplier.headings(of: digest) == ["HEADER", "DECISIONS", "STATUS"])
    }

    @Test("SC-17: a heading-like line at any level other than an exact allowed `## ` heading is discarded")
    func headingLevelSmuggling() throws {
        let digest = """
            ## HEADER
            meeting: Quoll Harbor sync

            ## FACTS
            The field kit exists.
            """
        // A heading demoted or promoted out of the `## ` parser's sight.
        for replace in ["### INVENTED", "# FACTS", "#### FACTS", "###### HEADER"] {
            #expect(
                DigestEditApplier.apply(
                    [DigestEditOperation(find: "## FACTS", replace: replace, instruction: 1)],
                    to: digest) == nil,
                "\(replace) never ships")
        }
        // Newline-smuggling: a heading-like line injected into body text.
        #expect(
            DigestEditApplier.apply(
                [DigestEditOperation(
                    find: "The field kit exists.",
                    replace: "The field kit exists.\n#### FACTS\nInvented.", instruction: 1)],
                to: digest) == nil)
        // The rule is heading-like lines only: a `#` inside prose is untouched.
        let hashInProse = try #require(
            DigestEditApplier.apply(
                [DigestEditOperation(
                    find: "The field kit exists.", replace: "Issue #14 is open.",
                    instruction: 1)],
                to: digest))
        #expect(hashInProse.contains("Issue #14 is open."))
        // CommonMark §4.2: up to three leading spaces still open an ATX
        // heading, and a bare hash run is a valid empty heading — both render
        // as sections the `md-v1` envelope does not have.
        for replace in ["   ### INVENTED", "###"] {
            #expect(
                DigestEditApplier.apply(
                    [DigestEditOperation(find: "## FACTS", replace: replace, instruction: 1)],
                    to: digest) == nil,
                "\(replace) never ships")
        }
        #expect(
            DigestEditApplier.apply(
                [DigestEditOperation(
                    find: "The field kit exists.",
                    replace: "The field kit exists.\n  #### FACTS\nInvented.", instruction: 1)],
                to: digest) == nil)
        #expect(DigestEditApplier.isHeadingLike("## FACTS"[...]))
        #expect(DigestEditApplier.isHeadingLike("   ### INVENTED"[...]))
        #expect(DigestEditApplier.isHeadingLike("###"[...]))
        #expect(!DigestEditApplier.isHeadingLike("#14 open"[...]))
        // Four spaces is indented code, not a heading opening.
        #expect(!DigestEditApplier.isHeadingLike("    #### FACTS"[...]))
    }

    @Test("SC-17: the digest response decodes wholly or not at all")
    func strictDecoding() throws {
        let valid = #"{"ops":[{"find":"a","replace":"b","instruction":1}]}"#
        #expect(
            try DigestEditorWireContract.decodeOperations(from: Data(valid.utf8))
                == [DigestEditOperation(find: "a", replace: "b", instruction: 1)])
        for invalid in [
            #"{"ops":[{"find":"a","replace":"b","instruction":1,"extra":true}]}"#,
            #"{"ops":[{"find":"a","replace":"b"}]}"#,
            #"{"ops":[{"field":"summary","find":"a","replace":"b","instruction":1}]}"#,
            #"{"ops":[],"prose":"accepted"}"#,
            #"{"operations":[]}"#,
        ] {
            #expect(throws: DecodingError.self) {
                _ = try DigestEditorWireContract.decodeOperations(from: Data(invalid.utf8))
            }
        }
    }

    @Test("SC-17: the local engine does not conform to the digest-editing seam")
    func localEngineDoesNotConform() {
        #expect(!(SettleNonEditingEngine() is any DigestEditingEngine))
        #expect(!(SettleNonEditingEngine() is any NotesEditingEngine))
    }
}

// MARK: - SC-18: the digest-editor request

@Suite struct N4DigestEditorRequestTests {
    @Test("SC-18: the request carries the digest verbatim and one hardened line per understanding row")
    func requestShape() async throws {
        let harness = try await makeSettleHarness()
        let meeting = try await seedSettleMeeting(harness)
        let base = harness.clock.now()
        // Every status, plus annotations that must NOT appear.
        let pending = try await seedSettleCorrection(
            harness, meetingID: meeting.id, status: .pending,
            quotedText: "Ships in May.", userText: "It ships in June.",
            createdAt: base)
        let applied = try await seedSettleCorrection(
            harness, meetingID: meeting.id, status: .applied,
            quotedText: "Dana \"Danny\" Marsh", userText: "Marlow Quoll owns it",
            createdAt: base.addingTimeInterval(1))
        let resolved = try await seedSettleCorrection(
            harness, meetingID: meeting.id, status: .resolved,
            quotedText: "70% coverage", userText: "80% coverage",
            createdAt: base.addingTimeInterval(2))
        _ = try await seedSettleCorrection(
            harness, meetingID: meeting.id, kind: .annotation, status: .applied,
            quotedText: "Ships in May.", userText: "A margin note",
            createdAt: base.addingTimeInterval(3))

        try await harness.database.pool.write { db in
            try db.execute(
                sql: "UPDATE meeting_notes SET digest_edit_owed = 1 WHERE meeting_id = ?",
                arguments: [meeting.id])
        }
        harness.engine.scriptDigest([[]])
        _ = try await harness.pipeline.reconcileDigest(meetingID: meeting.id)

        let request = try #require(harness.engine.digestRequests.first)
        #expect(Array(request.currentDigest.utf8) == Array(settleDigestFixture.utf8))
        #expect(request.instructions.map(\.rowID) == [pending.id, applied.id, resolved.id])

        let message = DigestEditorWireContract.userMessage(for: request)
        #expect(message.hasPrefix("CURRENT DIGEST:\n" + settleDigestFixture + "\nCORRECTIONS:\n"))
        #expect(message.contains("1. The user corrected the meeting record."))
        #expect(message.contains("3. The user corrected the meeting record."))
        #expect(
            !message.contains("\n4. "),
            "exactly three understanding rows are numbered")
        #expect(!message.contains("A margin note"), "annotations never enter the prompt")
        // The delimiter hardening: a user quote's ASCII double quote cannot end
        // its own data position.
        #expect(message.contains("Dana \u{201D}Danny\u{201D} Marsh"))
        #expect(!message.contains("notes_structured"))
        #expect(!message.contains("The field kit ships in May."), "no transcript")
        // No section clause and no occurrence clause on the digest surface.
        #expect(!message.contains("In the summary"))
        #expect(!message.contains("occurrence"))
        #expect(harness.engine.digestPurposes == [.digestEditor])
    }
}

// MARK: - SC-1 / SC-2 / SC-11 / SC-13: the pooled session

@Suite struct N4PooledSettleTests {
    /// Drives one settle to completion through the view-detach trigger.
    private func settleByDetaching(_ harness: SettleHarness, _ meetingID: MeetingID) async {
        await harness.pipeline.settleViewDetached(meetingID)
    }

    @Test("SC-1: K corrections and M annotations settle as one editor call, one digest call, one delivery")
    func pooledSession() async throws {
        let harness = try await makeSettleHarness()
        let meeting = try await seedSettleMeeting(harness)
        await harness.pipeline.settleViewAttached(meeting.id)
        harness.engine.scriptNotes([[
            .replace(field: .summary, find: "Ships in May.", replace: "Ships in June.",
                instruction: 1)
        ]])
        harness.engine.scriptDigest([[
            DigestEditOperation(
                find: "ship the Quoll Harbor field kit in May 2026",
                replace: "ship the Quoll Harbor field kit in June 2026", instruction: 1)
        ]])

        for index in 0 ..< 3 {
            _ = try await harness.pipeline.addCorrection(
                meetingID: meeting.id, kind: .understanding, section: .summary,
                quotedText: "Ships in May.", occurrence: 0, userText: "It ships in June \(index)")
        }
        for index in 0 ..< 2 {
            _ = try await harness.pipeline.addCorrection(
                meetingID: meeting.id, kind: .annotation, section: .decision,
                quotedText: "Ship the field kit in May", occurrence: 0,
                userText: "Margin note \(index)")
        }

        // Nothing shipped at apply time or at annotation-mutation time.
        #expect(try await harness.queueRows(meeting.id) == 0)
        #expect(harness.engine.notesCallCount == 0)
        #expect(harness.engine.digestCallCount == 0)

        let transcriptBefore = try await TranscriptRepository(database: harness.database)
            .segments(meetingID: meeting.id)

        await settleByDetaching(harness, meeting.id)

        #expect(harness.engine.notesCallCount == 1)
        #expect(harness.engine.digestCallCount == 1)
        #expect(try await harness.queueRows(meeting.id) == 1)

        let notes = try await harness.notes(meeting.id)
        #expect(!notes.deliveryOwed)
        #expect(!notes.digestEditOwed)
        #expect(notes.structured.summary == "Ships in June.")
        #expect(try #require(notes.memoryDigest).contains("June 2026"))

        let payload = try await harness.latestPayload(meeting.id)
        #expect(payload["memory_digest"] as? String == notes.memoryDigest)
        let markdown = try #require(payload["summary_markdown"] as? String)
        #expect(markdown.contains("Margin note 0"))
        #expect(markdown.contains("Margin note 1"))
        #expect(markdown.contains("Ships in June."))

        // SC-13: the transcript is byte-identical across drain, digest and delivery.
        let transcriptAfter = try await TranscriptRepository(database: harness.database)
            .segments(meetingID: meeting.id)
        #expect(transcriptAfter == transcriptBefore)
    }

    @Test("SC-2: the reconciled digest ships, and a toggle-OFF mint omits BOTH digest keys")
    func digestReconcileAndToggleConformance() async throws {
        let harness = try await makeSettleHarness()
        let meeting = try await seedSettleMeeting(harness)
        await harness.pipeline.settleViewAttached(meeting.id)
        harness.engine.scriptNotes([[
            .replace(field: .summary, find: "Ships in May.", replace: "Ships in June.",
                instruction: 1)
        ]])
        harness.engine.scriptDigest([[
            DigestEditOperation(
                find: "Dana Marsh decided on 2026-03-14 to ship the Quoll Harbor field kit in May 2026.\n",
                replace: "", instruction: 1)
        ]])
        _ = try await harness.pipeline.addCorrection(
            meetingID: meeting.id, kind: .understanding, section: .summary,
            quotedText: "Ships in May.", occurrence: 0,
            userText: "We never decided a May ship date")
        await harness.pipeline.settleViewDetached(meeting.id)

        let notes = try await harness.notes(meeting.id)
        let stored = try #require(notes.memoryDigest)
        #expect(!stored.contains("May 2026"), "the withdrawn claim is gone from the digest")
        let payload = try await harness.latestPayload(meeting.id)
        #expect(payload["memory_digest"] as? String == stored)
    }

    @Test("SC-2/SC-9: with the digest toggle OFF no reconcile fires and every forward mint omits both digest keys")
    func toggleOffConformance() async throws {
        let harness = try await makeSettleHarness()
        let settings = SettingsStore(database: harness.database)
        try await settings.set(MemoryDigestSettings.enabledKey, to: false)
        let meeting = try await seedSettleMeeting(harness)
        await harness.pipeline.settleViewAttached(meeting.id)
        harness.engine.scriptNotes([[
            .replace(field: .summary, find: "Ships in May.", replace: "Ships in June.",
                instruction: 1)
        ]])
        _ = try await harness.pipeline.addCorrection(
            meetingID: meeting.id, kind: .understanding, section: .summary,
            quotedText: "Ships in May.", occurrence: 0, userText: "It ships in June")
        await harness.pipeline.settleViewDetached(meeting.id)

        #expect(harness.engine.digestCallCount == 0, "toggle OFF spends no digest call")
        let notes = try await harness.notes(meeting.id)
        #expect(notes.memoryDigest != nil, "the stored digest is RETAINED, never deleted")
        #expect(notes.digestEditOwed, "the debt survives for a future toggle-on settle")

        let payload = try await harness.latestPayload(meeting.id)
        #expect(payload["memory_digest"] == nil)
        let provenance = try #require(payload["provenance"] as? [String: Any])
        #expect(provenance["memory_digest"] == nil)

        // The same conformance at an INSTANT name-fix mint (the shared seam).
        _ = try await harness.pipeline.renameMeeting(
            meetingID: meeting.id, to: "Quoll Harbor field-kit review")
        let renamePayload = try await harness.latestPayload(meeting.id)
        #expect(renamePayload["memory_digest"] == nil)
        let renameProvenance = try #require(renamePayload["provenance"] as? [String: Any])
        #expect(renameProvenance["memory_digest"] == nil)

        // SC-2's last clause: the surviving debt's future toggle-ON settle
        // reconciles and re-delivers WITH the field.
        let rowsBefore = try await harness.queueRows(meeting.id)
        try await settings.set(MemoryDigestSettings.enabledKey, to: true)
        harness.engine.scriptDigest([[
            DigestEditOperation(find: "in May 2026", replace: "in June 2026", instruction: 1)
        ]])
        await harness.pipeline.resumeOwedSettles()

        #expect(harness.engine.digestCallCount == 1)
        let reconciled = try await harness.notes(meeting.id)
        #expect(!reconciled.digestEditOwed)
        #expect(try #require(reconciled.memoryDigest).contains("in June 2026"))
        #expect(try await harness.queueRows(meeting.id) == rowsBefore + 1, "one new payload")
        let onPayload = try await harness.latestPayload(meeting.id)
        #expect(onPayload["memory_digest"] as? String == reconciled.memoryDigest)
        let onProvenance = try #require(onPayload["provenance"] as? [String: Any])
        let digestProvenance = try #require(onProvenance["memory_digest"] as? [String: Any])
        #expect(
            digestProvenance["prompt_version"] as? String
                == DigestPromptBuilder.shippedVersion.rawValue)
    }

    @Test("SC-9: a rename still delivers instantly, on its own")
    func renameKeepsItsInstantCadence() async throws {
        let harness = try await makeSettleHarness()
        let meeting = try await seedSettleMeeting(harness)
        #expect(try await harness.queueRows(meeting.id) == 0)
        _ = try await harness.pipeline.renameMeeting(
            meetingID: meeting.id, to: "Quoll Harbor field-kit review")
        #expect(try await harness.queueRows(meeting.id) == 1)
        #expect(harness.engine.digestCallCount == 0)
    }

    @Test("SC-11: each digest skip arm preserves the debt, and the zero-instruction arm clears it")
    func digestSkipArms() async throws {
        // Toggle OFF.
        do {
            let harness = try await makeSettleHarness()
            try await SettingsStore(database: harness.database)
                .set(MemoryDigestSettings.enabledKey, to: false)
            let meeting = try await seedSettleMeeting(harness)
            _ = try await seedSettleCorrection(
                harness, meetingID: meeting.id, createdAt: harness.clock.now())
            try await setDigestOwed(harness, meeting.id)
            #expect(try await harness.pipeline.reconcileDigest(meetingID: meeting.id) == .skipped)
            #expect(harness.engine.digestCallCount == 0)
            #expect(try await harness.notes(meeting.id).digestEditOwed)
        }
        // A non-conforming engine.
        do {
            let local = SettleNonEditingEngine()
            let harness = try await makeSettleHarness(
                extraEngines: [local], selectedEngineID: local.id)
            let meeting = try await seedSettleMeeting(harness)
            _ = try await seedSettleCorrection(
                harness, meetingID: meeting.id, createdAt: harness.clock.now())
            try await setDigestOwed(harness, meeting.id)
            #expect(try await harness.pipeline.reconcileDigest(meetingID: meeting.id) == .skipped)
            #expect(harness.engine.digestCallCount == 0)
            #expect(try await harness.notes(meeting.id).digestEditOwed)
        }
        // A live digest-pending marker.
        do {
            let harness = try await makeSettleHarness()
            let meeting = try await seedSettleMeeting(
                harness, lastProcessingError: DigestPendingClass.marker("network"))
            _ = try await seedSettleCorrection(
                harness, meetingID: meeting.id, createdAt: harness.clock.now())
            try await setDigestOwed(harness, meeting.id)
            #expect(try await harness.pipeline.reconcileDigest(meetingID: meeting.id) == .skipped)
            #expect(harness.engine.digestCallCount == 0)
            #expect(try await harness.notes(meeting.id).digestEditOwed)
        }
        // Zero instructions: no call, and the debt CLEARS (no phantom debt).
        do {
            let harness = try await makeSettleHarness()
            let meeting = try await seedSettleMeeting(harness)
            try await setDigestOwed(harness, meeting.id)
            #expect(
                try await harness.pipeline.reconcileDigest(meetingID: meeting.id) == .reconciled)
            #expect(harness.engine.digestCallCount == 0)
            #expect(!(try await harness.notes(meeting.id).digestEditOwed))
        }
    }

    @Test("SC-11: delivery refuses while a runnable digest debt stands, then ships coherently")
    func deliveryGuardRefusesAheadOfTheDigest() async throws {
        let harness = try await makeSettleHarness()
        let meeting = try await seedSettleMeeting(harness)
        _ = try await seedSettleCorrection(
            harness, meetingID: meeting.id, createdAt: harness.clock.now())
        try await setDigestOwed(harness, meeting.id)
        try await setDeliveryOwed(harness, meeting.id)

        #expect(
            try await harness.pipeline.deliverSettled(meetingID: meeting.id)
                == .refusedDigestOwed)
        #expect(try await harness.queueRows(meeting.id) == 0)

        harness.engine.scriptDigest([[]])
        #expect(try await harness.pipeline.reconcileDigest(meetingID: meeting.id) == .reconciled)
        #expect(try await harness.pipeline.deliverSettled(meetingID: meeting.id) == .delivered)
        #expect(try await harness.queueRows(meeting.id) == 1)
    }

    @Test("SC-6/SC-11: a permanent digest failure still delivers, goes quiescent, and re-fires no call")
    func permanentDigestFailureStillDelivers() async throws {
        let harness = try await makeSettleHarness()
        let meeting = try await seedSettleMeeting(harness)
        await harness.pipeline.settleViewAttached(meeting.id)
        harness.engine.scriptNotes([[
            .replace(field: .summary, find: "Ships in May.", replace: "Ships in June.",
                instruction: 1)
        ]])
        harness.engine.scriptDigest([], errors: [.permanent("malformed body")])
        _ = try await harness.pipeline.addCorrection(
            meetingID: meeting.id, kind: .understanding, section: .summary,
            quotedText: "Ships in May.", occurrence: 0, userText: "It ships in June")
        await harness.pipeline.settleViewDetached(meeting.id)

        #expect(harness.engine.digestCallCount == 1, "a permanent failure is not retried")
        #expect(try await harness.queueRows(meeting.id) == 1, "the corrected notes still ship")
        let notes = try await harness.notes(meeting.id)
        #expect(notes.digestEditOwed, "the digest debt survives")
        #expect(!notes.deliveryOwed)

        // Quiescent: repeated visits and detaches fire no further model call.
        for _ in 0 ..< 3 {
            await harness.pipeline.settleViewAttached(meeting.id)
            await harness.pipeline.settleViewDetached(meeting.id)
        }
        #expect(harness.engine.digestCallCount == 1)
        #expect(try await harness.queueRows(meeting.id) == 1)
    }

    @Test("SC-6: transport exhaustion takes exactly three attempts and leaves the bits intact")
    func transportExhaustion() async throws {
        let harness = try await makeSettleHarness()
        let meeting = try await seedSettleMeeting(harness)
        _ = try await seedSettleCorrection(
            harness, meetingID: meeting.id, createdAt: harness.clock.now())
        try await setDigestOwed(harness, meeting.id)
        harness.engine.scriptDigest(
            [], errors: [.transient("a"), .transient("b"), .transient("c")])

        let outcome = Task { try await harness.pipeline.reconcileDigest(meetingID: meeting.id) }
        // Two bounded backoffs on the injected clock.
        for _ in 0 ..< 2 {
            _ = await eventually { harness.clock.activeSleeperCount == 1 }
            harness.clock.advance(by: .seconds(2))
        }
        #expect(try await outcome.value == .transportExhausted)
        #expect(harness.engine.digestCallCount == 3)
        #expect(try await harness.notes(meeting.id).digestEditOwed)
    }

    @Test("SC-2: delivery takes ONE toggle snapshot, so an OFF→ON flip mid-mint ships no unreconciled digest")
    func deliveryTakesOneToggleSnapshot() async throws {
        // The flip is raced across a spread of interleavings; whichever side of
        // the mint it lands on, the guard's decision and the payload agree.
        for iteration in 0 ..< 12 {
            let harness = try await makeSettleHarness()
            let settings = SettingsStore(database: harness.database)
            try await settings.set(MemoryDigestSettings.enabledKey, to: false)
            let meeting = try await seedSettleMeeting(harness)
            _ = try await seedSettleCorrection(
                harness, meetingID: meeting.id, status: .applied,
                createdAt: harness.clock.now())
            try await setDigestOwed(harness, meeting.id)
            try await setDeliveryOwed(harness, meeting.id)

            let delivery = Task {
                try await harness.pipeline.deliverSettled(meetingID: meeting.id)
            }
            for _ in 0 ..< iteration { await Task.yield() }
            try await settings.set(MemoryDigestSettings.enabledKey, to: true)
            let outcome = try await delivery.value

            if outcome == .delivered {
                let payload = try await harness.latestPayload(meeting.id)
                #expect(
                    payload["memory_digest"] == nil,
                    "an OFF snapshot at the guard is the OFF snapshot at the mint")
                let provenance = try #require(payload["provenance"] as? [String: Any])
                #expect(provenance["memory_digest"] == nil)
            } else {
                #expect(outcome == .refusedDigestOwed)
                #expect(try await harness.queueRows(meeting.id) == 0)
            }
            #expect(
                try await harness.notes(meeting.id).digestEditOwed,
                "the unreconciled debt stands either way")
            #expect(harness.engine.digestCallCount == 0)
        }
    }

    /// The behavioural race above can only observe the interleaving it happens
    /// to get. This pins the property that makes every interleaving safe: one
    /// snapshot, taken once, governing both the refusal and the payload.
    @Test("SC-2: the delivery PATH reads the digest toggle exactly once")
    func deliveryReadsTheToggleOnce() throws {
        var repositoryRoot = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { repositoryRoot.deleteLastPathComponent() }
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "app/Sources/BlaiseCore/ProcessingPipeline.swift"), encoding: .utf8)
        // Both reads the defect spanned live here: one in the delivery body,
        // one in the runnable guard the body calls. Scanning the body alone
        // counts one either way.
        let deliveryBody = try Self.functionText("private func deliverSettledBody(", in: source)
        let runnableGuard = try Self.functionText(
            "private func digestStepIsRunnable(", in: source)
        // A guard read below the snapshot branch runs only for a caller that
        // supplied none; delivery always supplies its own.
        let guardHead = runnableGuard.components(separatedBy: "if let digestEnabled {")[0]
        let deliveryPathReads =
            deliveryBody.components(separatedBy: "MemoryDigestSettings.isEnabled").count - 1
            + guardHead.components(separatedBy: "MemoryDigestSettings.isEnabled").count - 1
        #expect(deliveryPathReads == 1)
        #expect(deliveryBody.contains("digestEnabled: digestEnabled"))
    }

    /// The ordering the harness cannot schedule: a delivery queued behind the
    /// editor link enters the moment that link's gate opens, so the terminal's
    /// invalidation has to happen INSIDE the link, not in the caller that runs
    /// after it.
    @Test("SC-11: the editor link invalidates the digest generation before releasing its successor")
    func editorLinkInvalidatesTheDigestGenerationBeforeReleasing() throws {
        var repositoryRoot = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { repositoryRoot.deleteLastPathComponent() }
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "app/Sources/BlaiseCore/ProcessingPipeline.swift"), encoding: .utf8)
        let activation = try Self.functionText(
            "private func editPendingNotesActivation(", in: source)
        let linkStart = try #require(activation.range(of: "chain.run"))
        let linkEnd = try #require(activation.range(of: "\n        }\n"))
        let link = activation[linkStart.lowerBound ..< linkEnd.upperBound]
        #expect(link.contains("clearQuiescentDigestDebt(meetingID: meetingID)"))
        // And the post-chain hook must not repeat it: a digest call that
        // started after this link began would lose a generation to a trigger
        // that has already been applied.
        let hook = try Self.functionText("private func settlePostEditorHook(", in: source)
        #expect(!hook.contains("clearQuiescentDigestDebt"))
    }

    /// A declaration's text, from its signature to its closing brace at method
    /// indentation.
    private static func functionText(_ signature: String, in source: String) throws -> String {
        let start = try #require(source.range(of: signature))
        let tail = source[start.lowerBound...]
        let end = try #require(tail.range(of: "\n    }\n"))
        return String(tail[..<end.upperBound])
    }

    @Test("SC-7: a settle whose mint equals a queued row enqueues nothing new")
    func idempotentDelivery() async throws {
        let harness = try await makeSettleHarness()
        let meeting = try await seedSettleMeeting(harness)
        _ = try await harness.pipeline.renameMeeting(
            meetingID: meeting.id, to: "Quoll Harbor field-kit review")
        #expect(try await harness.queueRows(meeting.id) == 1)
        try await setDeliveryOwed(harness, meeting.id)
        #expect(try await harness.pipeline.deliverSettled(meetingID: meeting.id) == .delivered)
        #expect(try await harness.queueRows(meeting.id) == 1, "identical bytes enqueue nothing")
        #expect(!(try await harness.notes(meeting.id).deliveryOwed))
    }
}

func setDigestOwed(_ harness: SettleHarness, _ meetingID: MeetingID) async throws {
    try await harness.database.pool.write { db in
        try db.execute(
            sql: "UPDATE meeting_notes SET digest_edit_owed = 1 WHERE meeting_id = ?",
            arguments: [meetingID])
    }
}

func setDeliveryOwed(_ harness: SettleHarness, _ meetingID: MeetingID) async throws {
    try await harness.database.pool.write { db in
        try db.execute(
            sql: "UPDATE meeting_notes SET delivery_owed = 1 WHERE meeting_id = ?",
            arguments: [meetingID])
    }
}

// MARK: - SC-3 / SC-4 / SC-5 / SC-16: the scheduler

@Suite struct N4SettleSchedulerTests {
    @Test("SC-5: activity resets a running slot, ten minutes of quiet fires, activity alone arms nothing")
    func idleSemantics() async throws {
        let harness = try await makeSettleHarness()
        let meeting = try await seedSettleMeeting(harness)
        await harness.pipeline.settleViewAttached(meeting.id)

        // Activity without owed work arms nothing.
        await harness.pipeline.noteMeetingActivity(meeting.id)
        #expect(harness.settleClock.activeSleeperCount == 0)

        // A mutation arms exactly one slot.
        harness.engine.scriptNotes([[]])
        _ = try await harness.pipeline.addCorrection(
            meetingID: meeting.id, kind: .annotation, section: .decision,
            quotedText: "Ship the field kit in May", occurrence: 0, userText: "A note")
        #expect(await eventually { harness.settleClock.activeSleeperCount == 1 })

        // Each activity signal RESETS the running slot rather than adding one.
        for _ in 0 ..< 3 {
            harness.settleClock.advance(by: .seconds(120))
            await harness.pipeline.noteMeetingActivity(meeting.id)
            #expect(await eventually { harness.settleClock.activeSleeperCount == 1 })
        }
        #expect(try await harness.queueRows(meeting.id) == 0, "quiet never elapsed")

        // Ten minutes of quiet fires the settle.
        harness.settleClock.advance(by: .seconds(600))
        #expect(await eventually { (try? await harness.queueRows(meeting.id)) == 1 })
    }

    @Test("SC-3: leaving the meeting view drains, reconciles and delivers in order")
    func leaveViewFires() async throws {
        let harness = try await makeSettleHarness()
        let meeting = try await seedSettleMeeting(harness)
        await harness.pipeline.settleViewAttached(meeting.id)
        harness.engine.scriptNotes([[
            .replace(field: .summary, find: "Ships in May.", replace: "Ships in June.",
                instruction: 1)
        ]])
        harness.engine.scriptDigest([[]])
        _ = try await harness.pipeline.addCorrection(
            meetingID: meeting.id, kind: .understanding, section: .summary,
            quotedText: "Ships in May.", occurrence: 0, userText: "It ships in June")
        #expect(harness.engine.notesCallCount == 0, "the burst window has not elapsed")

        await harness.pipeline.settleViewDetached(meeting.id)

        #expect(harness.engine.notesCallCount == 1)
        #expect(harness.engine.digestCallCount == 1)
        #expect(try await harness.queueRows(meeting.id) == 1)
    }

    @Test("SC-4: a detach after the terminating flag starts no executor")
    func quitOutranksDetach() async throws {
        let harness = try await makeSettleHarness()
        let meeting = try await seedSettleMeeting(harness)
        await harness.pipeline.settleViewAttached(meeting.id)
        try await setDeliveryOwed(harness, meeting.id)

        harness.pipeline.markTerminating()
        await harness.pipeline.settleViewDetached(meeting.id)

        #expect(try await harness.queueRows(meeting.id) == 0)
        #expect(try await harness.notes(meeting.id).deliveryOwed, "the bit is durable")
    }

    @Test("SC-4: the launch sweep converges owed work without the meeting being opened")
    func launchResume() async throws {
        let root = try makeTempRoot()
        let database = try BlaiseDatabase(rootURL: root)
        let first = try await makeSettleHarness(root: root, database: database)
        let meeting = try await seedSettleMeeting(first)
        await first.pipeline.settleViewAttached(meeting.id)
        first.engine.scriptNotes([[
            .replace(field: .summary, find: "Ships in May.", replace: "Ships in June.",
                instruction: 1)
        ]])
        first.engine.scriptDigest([[]])
        _ = try await first.pipeline.addCorrection(
            meetingID: meeting.id, kind: .understanding, section: .summary,
            quotedText: "Ships in May.", occurrence: 0, userText: "It ships in June")
        // The session dies here: the slot is in memory only, the bits are not.
        #expect(try await first.queueRows(meeting.id) == 0)

        // A fresh pipeline over the SAME database, with no drainable batch: the
        // correction row is still pending, so drain it first the way N2's own
        // launch re-arm would, then let the sweep finish the chain.
        let second = try await makeSettleHarness(root: root, database: database)
        second.engine.scriptNotes([[
            .replace(field: .summary, find: "Ships in May.", replace: "Ships in June.",
                instruction: 1)
        ]])
        second.engine.scriptDigest([[]])
        try await second.pipeline.sendPendingNotesToEditor(meetingID: meeting.id)

        #expect(await eventually { (try? await second.queueRows(meeting.id)) == 1 })
        let notes = try await second.notes(meeting.id)
        #expect(!notes.deliveryOwed)
        #expect(!notes.digestEditOwed)
    }

    @Test("SC-4: an annotation committed but never re-minted still delivers with a fresh timestamp")
    func annotationCrashFreshness() async throws {
        let harness = try await makeSettleHarness()
        let meeting = try await seedSettleMeeting(harness)
        let before = try #require(
            try await MeetingRepository(database: harness.database).fetch(meeting.id))
        // The mutation transaction alone — the follow-on re-mint never happened.
        let row = MeetingCorrection(
            id: ULID.generate(), meetingID: meeting.id, kind: .annotation, section: .decision,
            quotedText: "Ship the field kit in May", occurrence: 0,
            userText: "A margin note that survived the crash", status: .applied,
            createdAt: harness.clock.now(), appliedAt: nil)
        try await harness.database.pool.write { db in
            try MeetingCorrectionStore.insert(db, row)
            try MeetingCorrectionStore.recordAnnotationMutation(
                db, meetingID: meeting.id, proposedTimestamp: before.updatedAt)
        }

        await harness.pipeline.resumeOwedSettles()

        #expect(try await harness.queueRows(meeting.id) == 1)
        let payload = try await harness.latestPayload(meeting.id)
        let updatedAt = try #require(payload["updated_at_ms"] as? Int64)
        #expect(updatedAt > EvidencePayloadBuilder.milliseconds(date: before.updatedAt))
        let markdown = try #require(payload["summary_markdown"] as? String)
        #expect(markdown.contains("A margin note that survived the crash"))
    }

    @Test("SC-16: the sweep ARMS an attached-view owed meeting rather than delivering at once")
    func sweepArmsAnAttachedView() async throws {
        let harness = try await makeSettleHarness()
        let meeting = try await seedSettleMeeting(harness)
        await harness.pipeline.settleViewAttached(meeting.id)
        try await setDeliveryOwed(harness, meeting.id)

        await harness.pipeline.resumeOwedSettles()

        #expect(try await harness.queueRows(meeting.id) == 0, "the idle window governs")
        #expect(await eventually { harness.settleClock.activeSleeperCount == 1 })
        harness.settleClock.advance(by: .seconds(600))
        #expect(await eventually { (try? await harness.queueRows(meeting.id)) == 1 })
    }

    @Test("SC-16: a sweep or a re-attach never restarts a settle window already counting")
    func invisibleTriggersPreserveACountingSlot() async throws {
        let harness = try await makeSettleHarness()
        let meeting = try await seedSettleMeeting(harness)
        await harness.pipeline.settleViewAttached(meeting.id)
        try await setDeliveryOwed(harness, meeting.id)
        await harness.pipeline.resumeOwedSettles()
        #expect(await eventually { harness.settleClock.activeSleeperCount == 1 })

        // t=599, one second short of the operator-pinned window: invisible
        // triggers arrive while the user has been quiet the whole time.
        harness.settleClock.advance(by: .seconds(599))
        await harness.pipeline.resumeOwedSettles()
        await harness.pipeline.settleViewAttached(meeting.id)
        #expect(try await harness.queueRows(meeting.id) == 0)

        // The ORIGINAL deadline governs: a restarted window would not be due
        // until t=1199.
        harness.settleClock.advance(by: .seconds(1))
        #expect(await eventually { (try? await harness.queueRows(meeting.id)) == 1 })
    }

    @Test("SC-4: annotation add, edit and delete each deliver a strictly fresher payload on a frozen clock")
    func frozenClockAnnotationFreshness() async throws {
        let harness = try await makeSettleHarness()
        let meeting = try await seedSettleMeeting(harness)
        var lastUpdatedAt = EvidencePayloadBuilder.milliseconds(date: meeting.updatedAt)
        var lastRows = 0

        // The clock NEVER advances: only the monotonic clamps move the stamp.
        func settleAndAssertFreshness() async throws {
            await harness.pipeline.settleViewDetached(meeting.id)
            let rows = try await harness.queueRows(meeting.id)
            #expect(rows == lastRows + 1)
            lastRows = rows
            let payload = try await harness.latestPayload(meeting.id)
            let updatedAt = try #require(payload["updated_at_ms"] as? Int64)
            #expect(updatedAt > lastUpdatedAt)
            lastUpdatedAt = updatedAt
        }

        let added = try await harness.pipeline.addCorrection(
            meetingID: meeting.id, kind: .annotation, section: .decision,
            quotedText: "Ship the field kit in May", occurrence: 0, userText: "A margin note")
        try await settleAndAssertFreshness()

        _ = try await harness.pipeline.updateCorrection(
            meetingID: meeting.id, id: added.row.id,
            quotedText: "Ship the field kit in May", occurrence: 0,
            userText: "An edited margin note")
        try await settleAndAssertFreshness()

        _ = try await harness.pipeline.deleteCorrection(meetingID: meeting.id, id: added.row.id)
        try await settleAndAssertFreshness()
    }

    @Test("SC-16: the sweep skips digest-only debt while the toggle is OFF, and converges once it is ON")
    func sweepSkipsNonRunnableDigestDebt() async throws {
        let harness = try await makeSettleHarness()
        let settings = SettingsStore(database: harness.database)
        try await settings.set(MemoryDigestSettings.enabledKey, to: false)
        let meeting = try await seedSettleMeeting(harness)
        _ = try await seedSettleCorrection(
            harness, meetingID: meeting.id, status: .applied,
            createdAt: harness.clock.now())
        try await setDigestOwed(harness, meeting.id)

        await harness.pipeline.resumeOwedSettles()
        #expect(harness.engine.digestCallCount == 0)
        #expect(try await harness.queueRows(meeting.id) == 0)
        #expect(harness.settleClock.activeSleeperCount == 0, "non-runnable debt arms nothing")

        try await settings.set(MemoryDigestSettings.enabledKey, to: true)
        harness.engine.scriptDigest([[]])
        await harness.pipeline.resumeOwedSettles()
        #expect(harness.engine.digestCallCount == 1)
        #expect(!(try await harness.notes(meeting.id).digestEditOwed))
    }
}

// MARK: - SC-8: instruction-aware synthesis

@Suite struct N4InstructionAwareSynthesisTests {
    @Test("SC-8: an empty correction set renders a byte-identical digest prompt")
    func presenceGate() {
        let meeting = Meeting(
            id: ULID.generate(), title: "Vexatron Labs sync", startedAt: msDate(),
            source: .meet, status: .ready, attendees: [], createdAt: msDate(),
            updatedAt: msDate())
        let structured = NotesStructured(
            title: nil, summary: "s", detailedNotes: "d", decisions: [], actionItems: [],
            userActionItems: [])
        func request(_ instructions: [NotesEditorInstruction]) -> DigestRequest {
            DigestRequest(
                meeting: meeting, transcript: [], notes: structured, dominantLanguage: "en",
                vocabulary: [], user: UserIdentity.onboardedUser, instructions: instructions)
        }
        let empty = DigestPromptBuilder.userMessage(for: request([]))
        #expect(!empty.contains("AUTHORITATIVE USER CORRECTIONS"))
        #expect(
            DigestPromptBuilder.combinedAuditUserMessage(for: request([]), draftDigest: "d")
                .contains("AUTHORITATIVE USER CORRECTIONS") == false)

        let instruction = NotesEditorInstruction(
            rowID: "r1", section: .summary, quotedText: "Ada \"owns\" it",
            userText: "Bo owns it")
        let populated = DigestPromptBuilder.userMessage(for: request([instruction]))
        #expect(populated.contains("AUTHORITATIVE USER CORRECTIONS"))
        #expect(populated.contains("override the transcript where they conflict"))
        #expect(populated.contains("HIGHER-NUMBERED one is what the user believes now"))
        #expect(populated.contains("1. The notes said: \u{201C}") == false)
        #expect(populated.contains("Ada \u{201D}owns\u{201D} it"), "the quote is hardened")
        #expect(populated.contains("Bo owns it"))
        // The block precedes the transcript it outranks.
        #expect(populated.hasPrefix(empty.prefix(20)))

        // The auditor carries the same block AND its own authority rule.
        let audit = DigestPromptBuilder.combinedAuditUserMessage(
            for: request([instruction]), draftDigest: "draft")
        #expect(audit.contains("AUTHORITATIVE USER CORRECTIONS APPLY TO THIS AUDIT"))
        #expect(audit.contains("NEVER remove, weaken, or revert content a correction mandates"))
        #expect(audit.contains("Bo owns it"))
    }

    @Test("SC-8: the shipped version is md-v7 and it still uses the ONE combined audit")
    func shippedVersionUsesTheCombinedAudit() {
        #expect(DigestPromptBuilder.shippedVersion == .mdV7)
        #expect(DigestPromptBuilder.shippedVersion.usesCombinedAudit)
        #expect(DigestPromptVersion.mdV6.usesCombinedAudit)
        for version in [DigestPromptVersion.mdV1, .mdV2, .mdV3, .mdV4, .mdV5] {
            #expect(!version.usesCombinedAudit, "\(version) predates the combined audit")
        }
    }
}

// MARK: - SC-10: migration v22

@Suite struct N4MigrationTests {
    @Test("SC-10: the v22 upgrade adds the owed columns, backfills the stamp both ways, and widens the receipt CHECK")
    func populatedUpgradeFromV21() throws {
        let root = try makeTempRoot()
        let queue = try DatabaseQueue(
            path: root.appendingPathComponent("blaise.sqlite").path)

        // Migrate to the v21 baseline only.
        try BlaiseDatabase.migrator.migrate(queue, upTo: "v21")

        let withDigest = ULID.generate()
        let withoutDigest = ULID.generate()
        try queue.write { db in
            for (id, digest) in [(withDigest, "## HEADER\nmeeting: Quoll Harbor\n"), (withoutDigest, nil)] as [(String, String?)] {
                try db.execute(
                    sql: """
                        INSERT INTO meeting
                          (id, title, started_at, ended_at, source, status, attendees,
                           created_at, updated_at, title_source)
                        VALUES (?, 'Quoll Harbor sync', ?, ?, 'meet', 'ready', '[]', ?, ?, 'default')
                        """,
                    arguments: [id, msDate(), msDate(), msDate(), msDate()])
                try db.execute(
                    sql: """
                        INSERT INTO meeting_notes
                          (meeting_id, markdown, language, generated_at, provenance,
                           structured, memory_digest)
                        VALUES (?, '# Notes', 'en', ?, '{}', '{}', ?)
                        """,
                    arguments: [id, msDate(), digest])
            }
            try db.execute(
                sql: """
                    INSERT INTO cloud_spend_receipt
                      (id, timestamp, month_key, engine_id, model, purpose,
                       input_tokens, output_tokens, cost_usd)
                    VALUES ('v21-era-receipt', ?, '2026-08', 'e', 'm', 'notes-editor', 7, 3, 0.5)
                    """,
                arguments: [msDate()])
        }
        let receiptBefore = try queue.read { db in
            try CloudSpendReceipt.fetchOne(
                db, sql: "SELECT * FROM cloud_spend_receipt WHERE id = 'v21-era-receipt'")
        }
        // No pre-migration rejection is asserted here: a table BUILT by v21
        // derives its CHECK from the CURRENT enum, so only a database migrated
        // by an older binary carries the frozen list. What v22 must guarantee is
        // asserted after the migration below.

        try BlaiseDatabase.migrator.migrate(queue)

        try queue.read { db in
            #expect(try BlaiseDatabase.migrator.appliedMigrations(db).last == "v22")
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(meeting_notes)")
                .map { $0["name"] as String }
            #expect(columns.contains("digest_edit_owed"))
            #expect(columns.contains("delivery_owed"))
            #expect(columns.contains("digest_prompt_version"))
            // Both bits default 0 for every existing row.
            #expect(try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM meeting_notes WHERE digest_edit_owed = 0 AND delivery_owed = 0")
                == 2)
            // The backfill, pinned both ways.
            #expect(try String.fetchOne(
                db, sql: "SELECT digest_prompt_version FROM meeting_notes WHERE meeting_id = ?",
                arguments: [withDigest]) == "md-v6")
            #expect(try String.fetchOne(
                db, sql: "SELECT digest_prompt_version FROM meeting_notes WHERE meeting_id = ?",
                arguments: [withoutDigest]) == nil)
            // The v21-era receipt survives the rebuild byte for byte.
            let after = try CloudSpendReceipt.fetchOne(
                db, sql: "SELECT * FROM cloud_spend_receipt WHERE id = 'v21-era-receipt'")
            #expect(after == receiptBefore)
            // The canonical index exists and no rebuild leftover survives.
            let indexNames = Set(
                try Row.fetchAll(db, sql: "PRAGMA index_list(cloud_spend_receipt)")
                    .map { $0["name"] as String })
            #expect(indexNames.contains("index_cloud_spend_receipt_on_month_key"))
            #expect(!indexNames.contains { $0.contains("v22") || $0.contains("_new_") })
            #expect(try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE name = 'cloud_spend_receipt_v22'")
                == 0)
        }

        // The widened CHECK accepts digest-editor and still rejects nonsense.
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO cloud_spend_receipt
                      (id, timestamp, month_key, engine_id, model, purpose,
                       input_tokens, output_tokens, cost_usd)
                    VALUES ('accepted-after-v22', ?, '2026-08', 'e', 'm',
                            'digest-editor', 1, 1, 0.0)
                    """,
                arguments: [msDate()])
        }
        #expect(throws: DatabaseError.self) {
            try queue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO cloud_spend_receipt
                          (id, timestamp, month_key, engine_id, model, purpose,
                           input_tokens, output_tokens, cost_usd)
                        VALUES ('invalid-purpose', ?, '2026-08', 'e', 'm',
                                'not-a-purpose', 1, 1, 0.0)
                        """,
                    arguments: [msDate()])
            }
        }
    }

    @Test("SC-10: an explicit version argument still overrides the backfilled stamp column")
    func explicitVersionOverridesTheColumn() throws {
        let meeting = Meeting(
            id: ULID.generate(), title: "Quoll Harbor sync", startedAt: msDate(),
            source: .meet, status: .ready, attendees: [], createdAt: msDate(),
            updatedAt: msDate())
        let structured = NotesStructured(
            title: nil, summary: "s", detailedNotes: "d", decisions: [], actionItems: [],
            userActionItems: [])
        var notes = MeetingNotes(
            meetingID: meeting.id, markdown: "# n", structured: structured, language: "en",
            generatedAt: msDate(),
            provenance: NotesProvenance(
                engine: "e", model: "m", pipelineVersion: "p", runtime: "r",
                rendererVersion: NotesRenderer.version, promptVersion: "v"),
            memoryDigest: "## HEADER\nmeeting: Quoll Harbor\n",
            digestPromptVersion: "md-v6")

        func stamp(_ payload: EvidencePayloadBuilder.Payload) throws -> String {
            let object = try #require(
                JSONSerialization.jsonObject(with: payload.bytes) as? [String: Any])
            let provenance = try #require(object["provenance"] as? [String: Any])
            let digest = try #require(provenance["memory_digest"] as? [String: Any])
            return try #require(digest["prompt_version"] as? String)
        }

        // The column governs when the caller names nothing…
        #expect(
            try stamp(EvidencePayloadBuilder.build(
                meeting: meeting, segments: [], notes: notes,
                user: UserIdentity.onboardedUser, corrections: [])) == "md-v6")
        // …and the recovery axis still overrides it.
        #expect(
            try stamp(EvidencePayloadBuilder.build(
                meeting: meeting, segments: [], notes: notes,
                user: UserIdentity.onboardedUser,
                corrections: [], digestPromptVersion: .mdV2)) == "md-v2")
        // A row minted before the column existed falls back to the shipped version.
        notes.digestPromptVersion = nil
        #expect(
            try stamp(EvidencePayloadBuilder.build(
                meeting: meeting, segments: [], notes: notes,
                user: UserIdentity.onboardedUser, corrections: [])) == "md-v7")
    }
}

// MARK: - The settle window measures USER quiet

@Suite struct N4SettleWindowTests {
    /// An editor completion is an invisible background event, not user
    /// activity: the ten-minute window it lands inside keeps its deadline.
    @Test("SC-5: an editor completion mid-window does not move the settle deadline")
    func editorCompletionDoesNotMoveTheDeadline() async throws {
        let harness = try await makeSettleHarness()
        let meeting = try await seedSettleMeeting(harness)
        await harness.pipeline.settleViewAttached(meeting.id)
        harness.engine.scriptNotes([[
            .replace(
                field: .summary, find: "Ships in May.", replace: "Ships in June.", instruction: 1)
        ]])
        harness.engine.scriptDigest([[]])

        // t0: the correction arms N2's five-minute burst and the ten-minute settle.
        _ = try await harness.pipeline.addCorrection(
            meetingID: meeting.id, kind: .understanding, section: .summary,
            quotedText: "Ships in May.", occurrence: 0, userText: "It ships in June")
        #expect(await eventually { harness.settleClock.activeSleeperCount == 1 })
        #expect(await eventually { harness.clock.activeSleeperCount == 1 })

        // t0+300: the editor activation fires and completes.
        harness.settleClock.advance(by: .seconds(300))
        harness.clock.advance(by: .seconds(300))
        #expect(await eventually { harness.engine.notesCallCount == 1 })
        #expect(await eventually { (try? await harness.notes(meeting.id).deliveryOwed) == true })
        // Let the post-editor hook run to completion before the window is read.
        for _ in 0 ..< 500 { await Task.yield() }
        #expect(try await harness.queueRows(meeting.id) == 0)

        // t0+600 — the ORIGINAL deadline — fires. A window the editor
        // completion had restarted would not be due until t0+900.
        harness.settleClock.advance(by: .seconds(300))
        #expect(await eventually { (try? await harness.queueRows(meeting.id)) == 1 })
    }
}

// MARK: - SC-6: the two failure-class timers

@Suite struct N4SettleFailureTimerTests {
    @Test("SC-6: a digest transport exhaustion re-arms the settle slot at five minutes")
    func transportExhaustionRearmsAtFiveMinutes() async throws {
        let harness = try await makeSettleHarness()
        let meeting = try await seedSettleMeeting(harness)
        _ = try await seedSettleCorrection(
            harness, meetingID: meeting.id, status: .applied, createdAt: harness.clock.now())
        try await setDigestOwed(harness, meeting.id)
        try await setDeliveryOwed(harness, meeting.id)
        harness.engine.scriptDigest(
            [], errors: [.transient("a"), .transient("b"), .transient("c")])

        // No view is attached, so the detach signal runs the executor now.
        let executor = Task { await harness.pipeline.settleViewDetached(meeting.id) }
        for _ in 0 ..< 2 {
            _ = await eventually { harness.clock.activeSleeperCount == 1 }
            harness.clock.advance(by: .seconds(2))
        }
        await executor.value

        #expect(harness.engine.digestCallCount == 3)
        #expect(try await harness.queueRows(meeting.id) == 0, "the activation ended before delivery")
        #expect(harness.settleClock.activeSleeperCount == 1, "the settle slot re-armed")

        // Five minutes, not the ten-minute window.
        harness.settleClock.advance(by: .seconds(299))
        #expect(try await harness.queueRows(meeting.id) == 0)
        harness.engine.scriptDigest([[]])
        harness.settleClock.advance(by: .seconds(1))
        #expect(await eventually { (try? await harness.queueRows(meeting.id)) == 1 })
        #expect(!(try await harness.notes(meeting.id).digestEditOwed))
    }

    @Test("SC-6: a permanent digest failure arms no timer at all")
    func permanentFailureArmsNoTimer() async throws {
        let harness = try await makeSettleHarness()
        let meeting = try await seedSettleMeeting(harness)
        await harness.pipeline.settleViewAttached(meeting.id)
        harness.engine.scriptNotes([[
            .replace(
                field: .summary, find: "Ships in May.", replace: "Ships in June.", instruction: 1)
        ]])
        harness.engine.scriptDigest([], errors: [.permanent("malformed body")])
        _ = try await harness.pipeline.addCorrection(
            meetingID: meeting.id, kind: .understanding, section: .summary,
            quotedText: "Ships in May.", occurrence: 0, userText: "It ships in June")
        #expect(await eventually { harness.settleClock.activeSleeperCount == 1 })

        harness.clock.advance(by: .seconds(300))
        #expect(await eventually { harness.engine.notesCallCount == 1 })
        // The editor's persist is what leaves the settle work owed.
        #expect(await eventually { (try? await harness.notes(meeting.id).deliveryOwed) == true })
        for _ in 0 ..< 500 { await Task.yield() }
        harness.settleClock.advance(by: .seconds(600))
        #expect(await eventually { (try? await harness.queueRows(meeting.id)) == 1 })

        #expect(harness.engine.digestCallCount == 1)
        #expect(try await harness.notes(meeting.id).digestEditOwed, "the digest debt survives")
        #expect(
            harness.settleClock.activeSleeperCount == 0,
            "quiescent debt arms nothing — no timer re-runs the failed call")
    }
}

// MARK: - SC-11: the hostile interleaves

@Suite struct N4HostileInterleaveTests {
    /// An editor pass slotted onto the chain BETWEEN the executor's digest step
    /// and its delivery step re-establishes the digest debt; the delivery guard
    /// refuses, the one-retry rule reconciles, and the pair ships coherent.
    @Test("SC-11: an editor pass between the digest step and delivery forces one retry")
    func editorInterleavedBetweenDigestAndDelivery() async throws {
        let gate = EditorGate()
        let harness = try await makeSettleHarness()
        harness.engine.state.withLock { $0.digestGate = gate }
        let meeting = try await seedSettleMeeting(harness)
        _ = try await seedSettleCorrection(
            harness, meetingID: meeting.id, status: .applied,
            quotedText: "Ships in May.", userText: "It ships in June.",
            createdAt: harness.clock.now())
        _ = try await seedSettleCorrection(
            harness, meetingID: meeting.id, status: .pending, section: .detailedNotes,
            quotedText: "70% coverage", userText: "Coverage is 80%",
            createdAt: harness.clock.now().addingTimeInterval(1))
        try await setDigestOwed(harness, meeting.id)
        try await setDeliveryOwed(harness, meeting.id)
        harness.engine.scriptNotes([[
            .replace(
                field: .detailedNotes, find: "ships in May", replace: "ships in June",
                instruction: 1)
        ]])
        harness.engine.scriptDigest([
            [DigestEditOperation(find: "in May 2026", replace: "in June 2026", instruction: 1)],
            [DigestEditOperation(find: "70% coverage", replace: "80% coverage", instruction: 2)],
        ])

        let executor = Task { await harness.pipeline.settleViewDetached(meeting.id) }
        await gate.waitUntilEntered()
        // Enqueued onto the chain BEHIND the gated digest pass, so it takes the
        // slot ahead of the delivery the executor enqueues next.
        let injected = Task {
            try await harness.pipeline.sendPendingNotesToEditor(meetingID: meeting.id)
        }
        for _ in 0 ..< 500 { await Task.yield() }
        gate.release()
        try await injected.value
        await executor.value

        #expect(harness.engine.notesCallCount == 1)
        #expect(
            harness.engine.digestCallCount == 2,
            "the guard refused once and the activation's single retry reconciled")
        #expect(try await harness.queueRows(meeting.id) == 1)
        let notes = try await harness.notes(meeting.id)
        #expect(!notes.digestEditOwed)
        #expect(!notes.deliveryOwed)
        let digest = try #require(notes.memoryDigest)
        #expect(digest.contains("80% coverage"), "the late correction reached the digest")
        #expect(notes.structured.detailedNotes.contains("ships in June"))
        let payload = try await harness.latestPayload(meeting.id)
        #expect(payload["memory_digest"] as? String == digest)
        #expect(
            try #require(payload["summary_markdown"] as? String).contains("ships in June"),
            "notes and digest ship as one coherent pair")
    }

    /// The permanent-failure variant: a late mutation CLEARS quiescence while
    /// the delivery is queued behind a chained editor pass, so the delivery
    /// guard refuses and retries instead of shipping over the failed reconcile.
    @Test("SC-11: a late clear of quiescence after a permanent failure refuses, never bypasses")
    func lateQuiescenceClearForcesRefusal() async throws {
        let digestGate = EditorGate()
        let notesGate = EditorGate()
        let harness = try await makeSettleHarness()
        harness.engine.state.withLock {
            $0.digestGate = digestGate
            $0.notesGate = notesGate
        }
        let meeting = try await seedSettleMeeting(harness)
        _ = try await seedSettleCorrection(
            harness, meetingID: meeting.id, status: .pending, section: .detailedNotes,
            quotedText: "70% coverage", userText: "Coverage is 80%",
            createdAt: harness.clock.now())
        try await setDigestOwed(harness, meeting.id)
        try await setDeliveryOwed(harness, meeting.id)
        harness.engine.scriptNotes([[
            .replace(
                field: .detailedNotes, find: "ships in May", replace: "ships in June",
                instruction: 1)
        ]])
        // One outcome and one error are consumed per call: the first call fails
        // permanently, the retry carries the operation.
        harness.engine.scriptDigest(
            [[], [DigestEditOperation(find: "70% coverage", replace: "80% coverage", instruction: 1)]],
            errors: [.permanent("malformed body")])

        let executor = Task { await harness.pipeline.settleViewDetached(meeting.id) }
        await digestGate.waitUntilEntered()
        let injected = Task {
            try await harness.pipeline.sendPendingNotesToEditor(meetingID: meeting.id)
        }
        for _ in 0 ..< 500 { await Task.yield() }
        // The digest step fails permanently: the debt goes quiescent and the
        // executor queues its delivery behind the (gated) editor pass.
        digestGate.release()
        await notesGate.waitUntilEntered()
        // A mutation is a fresh external trigger — it clears quiescence while
        // the delivery still waits for its chain slot.
        _ = try await harness.pipeline.addCorrection(
            meetingID: meeting.id, kind: .understanding, section: .summary,
            quotedText: "Ships in May.", occurrence: 0, userText: "It ships in June")
        notesGate.release()
        try await injected.value
        await executor.value

        #expect(
            harness.engine.digestCallCount == 2,
            "the cleared quiescence forced the refusal-and-retry path")
        #expect(try await harness.queueRows(meeting.id) == 1, "one coherent delivery, never two")
        let notes = try await harness.notes(meeting.id)
        #expect(!notes.digestEditOwed)
        #expect(!notes.deliveryOwed)
        #expect(try #require(notes.memoryDigest).contains("80% coverage"))
        let payload = try await harness.latestPayload(meeting.id)
        #expect(payload["memory_digest"] as? String == notes.memoryDigest)
    }

    /// annotation → detach → delivery → re-mint, with the re-mint's commit
    /// forced strictly AFTER the terminal step's predicate sample (the injected
    /// seam). The rerun latch must deliver the re-asserted debt in this same
    /// executor rather than waiting for an unrelated trigger.
    @Test("SC-11: a re-mint committing after the terminal sample is delivered by the latch")
    func remintAfterTerminalSampleIsLatched() async throws {
        let pipelineBox = Mutex<ProcessingPipeline?>(nil)
        let clockBox = Mutex<EditorManualClock?>(nil)
        let fired = Mutex(false)
        let harness = try await makeSettleHarness(afterSettleTerminalStep: { meetingID in
            guard !fired.withLock({ value -> Bool in
                defer { value = true }
                return value
            }) else { return }
            guard let pipeline = pipelineBox.withLock({ $0 }) else { return }
            // A fresh instant so the re-delivery's payload is genuinely new.
            clockBox.withLock { $0 }?.advance(by: .seconds(5))
            _ = try? await pipeline.remintNotesArtifacts(meetingID: meetingID)
        })
        pipelineBox.withLock { $0 = harness.pipeline }
        clockBox.withLock { $0 = harness.clock }
        let meeting = try await seedSettleMeeting(harness)

        // The annotation mutation transaction alone — its follow-on re-mint is
        // what the seam runs, at the hostile moment.
        let before = try #require(
            try await MeetingRepository(database: harness.database).fetch(meeting.id))
        let row = MeetingCorrection(
            id: ULID.generate(), meetingID: meeting.id, kind: .annotation, section: .decision,
            quotedText: "Ship the field kit in May", occurrence: 0,
            userText: "A margin note", status: .applied,
            createdAt: harness.clock.now(), appliedAt: nil)
        try await harness.database.pool.write { db in
            try MeetingCorrectionStore.insert(db, row)
            try MeetingCorrectionStore.recordAnnotationMutation(
                db, meetingID: meeting.id, proposedTimestamp: before.updatedAt)
        }

        await harness.pipeline.settleViewDetached(meeting.id)

        #expect(
            try await harness.queueRows(meeting.id) == 2,
            "the latched re-assert delivered in the same executor")
        #expect(
            !(try await harness.notes(meeting.id).deliveryOwed),
            "a swallowed latch would leave the re-asserted bit standing")
    }

    /// A sweep landing WHILE the digest call is suspended is a fresh external
    /// trigger. The permanent failure that returns afterwards belongs to the
    /// older generation, so it must not quiesce the debt the sweep just
    /// released — and must not license the delivery bypass either.
    @Test("SC-11: a sweep during the digest call survives a late permanent failure")
    func sweepDuringTheDigestCallSurvivesALateFailure() async throws {
        let gate = EditorGate()
        let harness = try await makeSettleHarness()
        harness.engine.state.withLock { $0.digestGate = gate }
        let meeting = try await seedSettleMeeting(harness)
        _ = try await seedSettleCorrection(
            harness, meetingID: meeting.id, status: .applied,
            quotedText: "70% coverage", userText: "Coverage is 80%",
            createdAt: harness.clock.now())
        try await setDigestOwed(harness, meeting.id)
        try await setDeliveryOwed(harness, meeting.id)
        // The first call fails permanently; the resample carries the operation.
        harness.engine.scriptDigest(
            [[], [DigestEditOperation(find: "70% coverage", replace: "80% coverage", instruction: 1)]],
            errors: [.permanent("malformed body")])

        let executor = Task { await harness.pipeline.settleViewDetached(meeting.id) }
        await gate.waitUntilEntered()
        await harness.pipeline.resumeOwedSettles()
        gate.release()
        await executor.value

        #expect(
            harness.engine.digestCallCount == 2,
            "the trigger that arrived mid-call got its resample")
        #expect(try await harness.queueRows(meeting.id) == 1, "one coherent delivery")
        let notes = try await harness.notes(meeting.id)
        #expect(!notes.digestEditOwed)
        #expect(try #require(notes.memoryDigest).contains("80% coverage"))
        let payload = try await harness.latestPayload(meeting.id)
        #expect(payload["memory_digest"] as? String == notes.memoryDigest)
    }

    /// The editor variant: a chained editor pass takes the chain the moment the
    /// failing digest call returns, so its terminal outcome — newer notes, fresh
    /// digest debt, quiescence cleared — lands around the executor's own
    /// continuation. Neither ordering may ship the newer notes over the old
    /// digest.
    @Test("SC-11: an editor pass completing around a failed reconcile never ships an incoherent pair")
    func editorCompletionAroundAFailedReconcile() async throws {
        let gate = EditorGate()
        let harness = try await makeSettleHarness()
        harness.engine.state.withLock { $0.digestGate = gate }
        let meeting = try await seedSettleMeeting(harness)
        _ = try await seedSettleCorrection(
            harness, meetingID: meeting.id, status: .pending, section: .detailedNotes,
            quotedText: "70% coverage", userText: "Coverage is 80%",
            createdAt: harness.clock.now())
        try await setDigestOwed(harness, meeting.id)
        try await setDeliveryOwed(harness, meeting.id)
        harness.engine.scriptNotes([[
            .replace(
                field: .detailedNotes, find: "ships in May", replace: "ships in June",
                instruction: 1)
        ]])
        harness.engine.scriptDigest(
            [[], [DigestEditOperation(find: "70% coverage", replace: "80% coverage", instruction: 1)]],
            errors: [.permanent("malformed body")])

        let executor = Task { await harness.pipeline.settleViewDetached(meeting.id) }
        await gate.waitUntilEntered()
        let injected = Task {
            try await harness.pipeline.sendPendingNotesToEditor(meetingID: meeting.id)
        }
        for _ in 0 ..< 500 { await Task.yield() }
        gate.release()
        try await injected.value
        await executor.value

        #expect(harness.engine.notesCallCount == 1)
        #expect(
            harness.engine.digestCallCount == 2,
            "the editor's terminal outcome forced a resample, never a bypass")
        #expect(try await harness.queueRows(meeting.id) == 1)
        let notes = try await harness.notes(meeting.id)
        #expect(!notes.digestEditOwed)
        #expect(notes.structured.detailedNotes.contains("ships in June"))
        #expect(try #require(notes.memoryDigest).contains("80% coverage"))
        let payload = try await harness.latestPayload(meeting.id)
        #expect(payload["memory_digest"] as? String == notes.memoryDigest)
    }

    /// Pins the outcome of a delivery that is ALREADY queued behind the editor
    /// link when that link commits its fresh notes and debt. It cannot force
    /// the losing side of the release race — the actor hop back into the
    /// editor's caller consistently precedes the queued delivery's own hop, so
    /// the schedule where the invalidation arrives too late is unreachable from
    /// the harness. The construction pin
    /// `editorLinkInvalidatesTheDigestGenerationBeforeReleasing` is the
    /// instrument for the ordering itself.
    @Test("SC-11: a delivery queued behind the editor link never bypasses on stale quiescence")
    func editorTerminalInvalidatesBeforeReleasingItsSuccessor() async throws {
        let digestGate = EditorGate()
        let notesGate = EditorGate()
        let harness = try await makeSettleHarness()
        harness.engine.state.withLock {
            $0.digestGate = digestGate
            $0.notesGate = notesGate
        }
        let meeting = try await seedSettleMeeting(harness)
        _ = try await seedSettleCorrection(
            harness, meetingID: meeting.id, status: .pending, section: .detailedNotes,
            quotedText: "70% coverage", userText: "Coverage is 80%",
            createdAt: harness.clock.now())
        try await setDigestOwed(harness, meeting.id)
        try await setDeliveryOwed(harness, meeting.id)
        harness.engine.scriptNotes([[
            .replace(
                field: .detailedNotes, find: "ships in May", replace: "ships in June",
                instruction: 1)
        ]])
        harness.engine.scriptDigest(
            [[], [DigestEditOperation(find: "70% coverage", replace: "80% coverage", instruction: 1)]],
            errors: [.permanent("malformed body")])

        // The executor's digest call holds its chain link.
        let executor = Task { await harness.pipeline.settleViewDetached(meeting.id) }
        await digestGate.waitUntilEntered()
        // The editor link queues behind it.
        let editor = Task {
            try await harness.pipeline.sendPendingNotesToEditor(meetingID: meeting.id)
        }
        for _ in 0 ..< 200 { await Task.yield() }
        // The digest call fails permanently and releases the editor, which
        // suspends inside its own link.
        digestGate.release()
        await notesGate.waitUntilEntered()
        // The failed call's continuation quiesces the debt and queues its
        // delivery behind the still-running editor link.
        for _ in 0 ..< 500 { await Task.yield() }
        notesGate.release()
        try await editor.value
        await executor.value

        #expect(harness.engine.notesCallCount == 1)
        #expect(
            harness.engine.digestCallCount == 2,
            "the queued delivery refused and the activation resampled the digest")
        #expect(
            try await harness.queueRows(meeting.id) == 1,
            "a bypassing mint would stand as a second, earlier queue row")
        // Every durable payload is coherent: edited notes never ship over the
        // digest their edit invalidated.
        let items = try await harness.database.pool.read { db in
            try HandoffItem
                .filter(Column("meeting_id") == meeting.id)
                .order(Column("created_seq"))
                .fetchAll(db)
        }
        for item in items {
            let data = try Data(contentsOf: harness.root.appendingPathComponent(item.payloadPath))
            let json = try #require(
                JSONSerialization.jsonObject(with: data) as? [String: Any])
            let markdown = try #require(json["summary_markdown"] as? String)
            guard markdown.contains("ships in June") else { continue }
            #expect(
                (json["memory_digest"] as? String)?.contains("80% coverage") == true,
                "the edited notes shipped over an unreconciled digest")
        }
        let notes = try await harness.notes(meeting.id)
        #expect(!notes.digestEditOwed)
        #expect(notes.structured.detailedNotes.contains("ships in June"))
        #expect(try #require(notes.memoryDigest).contains("80% coverage"))
    }

    /// Two waves, not one: the second signal lands after the drain's own
    /// terminal sample, in the window a single trailing check leaves open.
    @Test("SC-11: two latch waves are both drained before the executor leaves the in-flight set")
    func twoLatchWavesAreBothDrained() async throws {
        let pipelineBox = Mutex<ProcessingPipeline?>(nil)
        let clockBox = Mutex<EditorManualClock?>(nil)
        let waves = Mutex(0)
        let harness = try await makeSettleHarness(afterSettleTerminalStep: { meetingID in
            let wave = waves.withLock { value -> Int in
                value += 1
                return value
            }
            guard wave <= 2, let pipeline = pipelineBox.withLock({ $0 }) else { return }
            // A fresh instant per wave so each re-delivery is genuinely new.
            clockBox.withLock { $0 }?.advance(by: .seconds(5))
            _ = try? await pipeline.remintNotesArtifacts(meetingID: meetingID)
        })
        pipelineBox.withLock { $0 = harness.pipeline }
        clockBox.withLock { $0 = harness.clock }
        let meeting = try await seedSettleMeeting(harness)

        let before = try #require(
            try await MeetingRepository(database: harness.database).fetch(meeting.id))
        let row = MeetingCorrection(
            id: ULID.generate(), meetingID: meeting.id, kind: .annotation, section: .decision,
            quotedText: "Ship the field kit in May", occurrence: 0,
            userText: "A margin note", status: .applied,
            createdAt: harness.clock.now(), appliedAt: nil)
        try await harness.database.pool.write { db in
            try MeetingCorrectionStore.insert(db, row)
            try MeetingCorrectionStore.recordAnnotationMutation(
                db, meetingID: meeting.id, proposedTimestamp: before.updatedAt)
        }

        await harness.pipeline.settleViewDetached(meeting.id)

        #expect(
            try await harness.queueRows(meeting.id) == 3,
            "both latch waves drained inside the same executor")
        #expect(
            !(try await harness.notes(meeting.id).deliveryOwed),
            "a swallowed second wave would leave the re-asserted bit standing")
    }

    /// A transport-exhausted editor drain arms N2's five-minute slot, and the
    /// post-editor hook neither invokes nor latches: the next drain happens on
    /// that slot's own expiry, never immediately.
    @Test("SC-11: a detached transport exhaustion waits out N2's five-minute slot")
    func detachedTransportExhaustionWaitsForTheSlot() async throws {
        let harness = try await makeSettleHarness()
        let meeting = try await seedSettleMeeting(harness)
        harness.engine.scriptNotes(
            [], errors: [.transient("a"), .transient("b"), .transient("c")])

        // A mutation with no view attached ARMS both slots; nothing runs yet.
        _ = try await harness.pipeline.addCorrection(
            meetingID: meeting.id, kind: .understanding, section: .summary,
            quotedText: "Ships in May.", occurrence: 0, userText: "It ships in June")
        #expect(await eventually { harness.settleClock.activeSleeperCount == 1 })

        // The settle fires and its drain exhausts its transport attempts.
        harness.settleClock.advance(by: .seconds(600))
        for attempt in 1 ... 2 {
            // The drain cancels N2's own slot first, so once the attempt has
            // been made the only sleeper left is its backoff.
            _ = await eventually { harness.engine.notesCallCount == attempt }
            _ = await eventually { harness.clock.activeSleeperCount == 1 }
            harness.clock.advance(by: .seconds(2))
        }
        #expect(await eventually { harness.engine.notesCallCount == 3 })
        #expect(await eventually { harness.clock.activeSleeperCount == 1 }, "N2 re-armed")
        for _ in 0 ..< 500 { await Task.yield() }
        #expect(harness.engine.digestCallCount == 0, "the hook neither invoked nor latched")
        #expect(try await harness.queueRows(meeting.id) == 0)

        // The next drain happens on that slot's own expiry.
        harness.engine.scriptNotes([[
            .replace(
                field: .summary, find: "Ships in May.", replace: "Ships in June.", instruction: 1)
        ]])
        harness.engine.scriptDigest([[]])
        harness.clock.advance(by: .seconds(300))
        #expect(await eventually { (try? await harness.queueRows(meeting.id)) == 1 })
        #expect(harness.engine.digestCallCount == 1)
    }
}

// MARK: - SC-12: the digest entry's surface

@Suite struct N4DigestEntrySurfaceTests {
    @Test("SC-12: the digest pass emits no pipeline events and never closes correction entry")
    func digestPassIsSilentAndLeavesEntryOpen() async throws {
        let gate = EditorGate()
        let harness = try await makeSettleHarness()
        harness.engine.state.withLock { $0.digestGate = gate }
        let meeting = try await seedSettleMeeting(harness)
        _ = try await seedSettleCorrection(
            harness, meetingID: meeting.id, status: .applied, createdAt: harness.clock.now())
        try await setDigestOwed(harness, meeting.id)
        harness.engine.scriptDigest([[]])

        let collected = Recorder<PipelineEvent>()
        let stream = await harness.pipeline.events()
        let collector = Task { for await event in stream { collected.append(event) } }

        let pass = Task { try await harness.pipeline.reconcileDigest(meetingID: meeting.id) }
        await gate.waitUntilEntered()
        // Correction entry stays ENABLED during the pass: a row entered while
        // it runs lands durably.
        let written = try await harness.pipeline.addCorrection(
            meetingID: meeting.id, kind: .understanding, section: .summary,
            quotedText: "Ships in May.", occurrence: 0, userText: "Entered mid-pass")
        let stored = try await harness.database.pool.read { db in
            try MeetingCorrection.fetchOne(db, key: written.row.id)
        }
        #expect(stored != nil)
        gate.release()
        #expect(try await pass.value == .reconciled)

        for _ in 0 ..< 500 { await Task.yield() }
        #expect(collected.values.isEmpty, "the digest entry emits no run events")

        // Positive control for the collector: an editor pass on the same
        // pipeline DOES reach it.
        harness.engine.scriptNotes([[]])
        try await harness.pipeline.sendPendingNotesToEditor(meetingID: meeting.id)
        #expect(await eventually { !collected.values.isEmpty })
        #expect(
            collected.values.contains(.runStarted(meeting.id, regeneration: true)),
            "the instrument sees a run that does emit")
        collector.cancel()
    }
}

// MARK: - SC-8: the correction slice, asserted at each digest call site

@Suite struct N4DigestSliceCallSiteTests {
    /// Every status, chronological, annotations excluded — the slice the
    /// synthesis seams read.
    private func seedSlice(
        _ harness: PipelineHarness, _ meetingID: MeetingID
    ) async throws -> [String] {
        let base = msDate()
        var ids: [String] = []
        for (offset, status) in [
            MeetingCorrection.Status.pending, .applied, .resolved,
        ].enumerated() {
            let row = MeetingCorrection(
                id: ULID.generate(), meetingID: meetingID, kind: .understanding,
                section: .summary, quotedText: "Ships in May.", occurrence: 0,
                userText: "It ships in June (\(status.rawValue))", status: status,
                createdAt: base.addingTimeInterval(Double(offset)), appliedAt: nil)
            try await harness.database.pool.write { db in
                try MeetingCorrectionStore.insert(db, row)
            }
            ids.append(row.id)
        }
        let annotation = MeetingCorrection(
            id: ULID.generate(), meetingID: meetingID, kind: .annotation, section: .decision,
            quotedText: "Ships in May.", occurrence: 0, userText: "A margin note",
            status: .applied, createdAt: base.addingTimeInterval(3), appliedAt: nil)
        try await harness.database.pool.write { db in
            try MeetingCorrectionStore.insert(db, annotation)
        }
        return ids
    }

    private func assertSlice(_ request: DigestRequest, _ expected: [String]) {
        #expect(request.instructions.map(\.rowID) == expected)
        #expect(
            request.instructions.allSatisfy { $0.userText.contains("It ships in June") },
            "the block carries the user's correction text")
        #expect(
            !request.instructions.contains { $0.userText == "A margin note" },
            "annotations never enter a digest prompt")
    }

    @Test("SC-8: the FULL-RUN call site carries the complete slice")
    func fullRunSite() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        let expected = try await seedSlice(harness, meeting.id)

        _ = try await harness.pipeline.process(meetingID: meeting.id)

        let request = try #require(
            harness.notesPrimary.state.withLock { $0.digestRequests.last })
        assertSlice(request, expected)
    }

    @Test("SC-8: the NOTES-ONLY RESUME call site carries the complete slice")
    func notesOnlyResumeSite() async throws {
        let harness = try await makePipelineHarness(
            fallbackLoadProfile: .heavyweight(estimatedPeakBytes: 18 * 1_073_741_824))
        let meeting = try await harness.importTestMeeting()
        harness.notesPrimary.state.withLock {
            $0.error = .configurationMissing(key: "apiKey")
        }
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        #expect(harness.notesPrimary.state.withLock { $0.digestRequests.isEmpty })

        let expected = try await seedSlice(harness, meeting.id)
        harness.notesPrimary.state.withLock { $0.error = nil }
        _ = try await harness.pipeline.processNotesOnly(meetingID: meeting.id)

        let request = try #require(
            harness.notesPrimary.state.withLock { $0.digestRequests.last })
        assertSlice(request, expected)
    }

    @Test("SC-8: an unreadable correction set fails the digest CLOSED instead of synthesizing blind")
    func unreadableSliceFailsClosed() async throws {
        let harness = try await makePipelineHarness()
        harness.notesPrimary.state.withLock { $0.digestError = .permanent("forced") }
        let meeting = try await harness.importTestMeeting()
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        let callsBefore = harness.notesPrimary.state.withLock { $0.digestRequests.count }

        // The injected read fault: the slice's own table is gone, so the read
        // throws rather than reporting an empty instruction set.
        harness.notesPrimary.state.withLock { $0.digestError = nil }
        try await harness.database.pool.write { db in
            try db.execute(sql: "DROP TABLE meeting_correction")
        }
        await harness.pipeline.resumePendingDigests()

        #expect(
            harness.notesPrimary.state.withLock { $0.digestRequests.count } == callsBefore,
            "no correction-blind digest call fires")
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(
            DigestPendingClass.isPending(stored.lastProcessingError),
            "the digest debt survives for the heal to retry")
        let notes = try #require(
            try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id))
        #expect(notes.memoryDigest == nil, "no digest is recorded as instruction-aware")
        #expect(notes.digestPromptVersion == nil)
    }

    @Test("SC-8: the DIGEST-ONLY HEAL call site carries the complete slice")
    func digestHealSite() async throws {
        let harness = try await makePipelineHarness()
        harness.notesPrimary.state.withLock { $0.digestError = .permanent("forced") }
        let meeting = try await harness.importTestMeeting()
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        let failedRequests = harness.notesPrimary.state.withLock { $0.digestRequests.count }

        let expected = try await seedSlice(harness, meeting.id)
        harness.notesPrimary.state.withLock { $0.digestError = nil }
        await harness.pipeline.resumePendingDigests()

        #expect(harness.notesPrimary.state.withLock { $0.digestRequests.count } > failedRequests)
        let request = try #require(
            harness.notesPrimary.state.withLock { $0.digestRequests.last })
        assertSlice(request, expected)
    }
}

// MARK: - SC-4: the four marker-transition crash states

@Suite struct N4MarkerCrashStateTests {
    /// The state a crash leaves, rebuilt on the durable surfaces the crash
    /// would have left behind, then handed to a fresh pipeline's own triggers.
    private func rewind(
        _ harness: PipelineHarness, _ meetingID: MeetingID, to marker: String?,
        staleNotesFile: Bool = false
    ) async throws {
        try await harness.database.pool.write { db in
            try db.execute(
                sql: "UPDATE meeting SET last_processing_error = ? WHERE id = ?",
                arguments: [marker, meetingID])
        }
        if staleNotesFile {
            try Data("# stale notes the promote never replaced".utf8).write(
                to: harness.database.paths.notesURL(meetingID), options: .atomic)
        }
    }

    private func notesFile(_ harness: PipelineHarness, _ meetingID: MeetingID) throws -> String {
        try String(
            contentsOf: harness.database.paths.notesURL(meetingID), encoding: .utf8)
    }

    /// A NON-deferred install commits the digest marker INSIDE the finalize
    /// transaction: the notes row, the queue row and the marker are one atom.
    @Test("SC-4: the non-deferred digest failure commits its marker atomically with finalize")
    func nonDeferredAtomicMarker() async throws {
        let harness = try await makePipelineHarness()
        harness.notesPrimary.state.withLock { $0.digestError = .permanent("forced") }
        let meeting = try await harness.importTestMeeting()
        _ = try await harness.pipeline.process(meetingID: meeting.id)

        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(DigestPendingClass.isPending(stored.lastProcessingError))
        #expect(!NotesPendingClass.isPending(stored.lastProcessingError))
        #expect(stored.status == .ready)
        let notes = try #require(
            try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id))
        #expect(notes.memoryDigest == nil)
        #expect(!notes.digestEditOwed && !notes.deliveryOwed, "finalize delivered everything")
        #expect(try await harness.queueRows(meeting.id) == 1)
        #expect(try notesFile(harness, meeting.id) == notes.markdown, "row and file agree")
    }

    /// A DEFERRED install whose digest also failed, crashed BEFORE the
    /// `notes.md` promotion: the notes-promote marker is what survives, and the
    /// full resume heals the file and the digest together.
    @Test("SC-4: a crash before the promotion heals both the notes file and the digest")
    func crashBeforePromotion() async throws {
        let harness = try await makePipelineHarness(
            fallbackLoadProfile: .heavyweight(estimatedPeakBytes: 18 * 1_073_741_824))
        let meeting = try await harness.importTestMeeting()
        harness.notesPrimary.state.withLock {
            $0.error = .configurationMissing(key: "apiKey")
        }
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        harness.notesPrimary.state.withLock {
            $0.error = nil
            $0.digestError = .permanent("forced")
        }
        _ = try await harness.pipeline.processNotesOnly(meetingID: meeting.id)

        // The crash state: the finalize transaction committed, the promote did
        // not, so the promote marker stands and `notes.md` is stale.
        try await rewind(
            harness, meeting.id,
            to: NotesPendingClass.marker(NotesPendingClass.notesFilePromoteIncomplete),
            staleNotesFile: true)

        // A fresh process: the notes self-heal enumerates the marker.
        harness.notesPrimary.state.withLock { $0.digestError = nil }
        await harness.pipeline.resumePendingNotes()

        let healed = try #require(try await harness.meeting(meeting.id))
        #expect(healed.lastProcessingError == nil, "both debts retired")
        let notes = try #require(
            try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id))
        #expect(try notesFile(harness, meeting.id) == notes.markdown, "the file was repaired")
        #expect(notes.memoryDigest != nil, "the digest recovered")
    }

    /// A crash AFTER the promotion but before the marker replacement: the
    /// promote marker is still present, so the replacement re-runs — the digest
    /// debt is never dropped on the way through.
    @Test("SC-4: a crash after the promotion re-runs the replacement, keeping the digest debt")
    func crashAfterPromotionBeforeReplacement() async throws {
        let harness = try await makePipelineHarness(
            fallbackLoadProfile: .heavyweight(estimatedPeakBytes: 18 * 1_073_741_824))
        let meeting = try await harness.importTestMeeting()
        harness.notesPrimary.state.withLock {
            $0.error = .configurationMissing(key: "apiKey")
        }
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        harness.notesPrimary.state.withLock {
            $0.error = nil
            $0.digestError = .permanent("forced")
        }
        _ = try await harness.pipeline.processNotesOnly(meetingID: meeting.id)
        let promoted = try #require(
            try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id))
        #expect(try notesFile(harness, meeting.id) == promoted.markdown)

        // The crash state: the file is already promoted, the marker is not yet
        // replaced.
        try await rewind(
            harness, meeting.id,
            to: NotesPendingClass.marker(NotesPendingClass.notesFilePromoteIncomplete))

        // The digest still fails, so the replacement must leave the digest
        // marker standing rather than clearing to nil.
        await harness.pipeline.resumePendingNotes()
        let afterReplacement = try #require(try await harness.meeting(meeting.id))
        #expect(
            DigestPendingClass.isPending(afterReplacement.lastProcessingError),
            "the digest debt survived the marker transition")

        // And once the digest engine recovers, its own trigger converges.
        harness.notesPrimary.state.withLock { $0.digestError = nil }
        await harness.pipeline.resumePendingDigests()
        let converged = try #require(try await harness.meeting(meeting.id))
        #expect(converged.lastProcessingError == nil)
        let notes = try #require(
            try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id))
        #expect(notes.memoryDigest != nil)
        #expect(try notesFile(harness, meeting.id) == notes.markdown)
    }

    /// A COMPLETED replacement: the digest marker is the live one, and the
    /// digest heal enumerates it.
    @Test("SC-4: a completed marker replacement is enumerated by the digest heal")
    func completedReplacementIsEnumerated() async throws {
        let harness = try await makePipelineHarness(
            fallbackLoadProfile: .heavyweight(estimatedPeakBytes: 18 * 1_073_741_824))
        let meeting = try await harness.importTestMeeting()
        harness.notesPrimary.state.withLock {
            $0.error = .configurationMissing(key: "apiKey")
        }
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        harness.notesPrimary.state.withLock {
            $0.error = nil
            $0.digestError = .permanent("forced")
        }
        _ = try await harness.pipeline.processNotesOnly(meetingID: meeting.id)

        // The deferred path's own end state: promoted file, digest marker.
        let afterResume = try #require(try await harness.meeting(meeting.id))
        #expect(DigestPendingClass.isPending(afterResume.lastProcessingError))
        let notes = try #require(
            try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id))
        #expect(try notesFile(harness, meeting.id) == notes.markdown)
        #expect(notes.memoryDigest == nil)

        let rowsBefore = try await harness.queueRows(meeting.id)
        harness.notesPrimary.state.withLock { $0.digestError = nil }
        await harness.pipeline.resumePendingDigests()

        let healed = try #require(try await harness.meeting(meeting.id))
        #expect(healed.lastProcessingError == nil)
        let healedNotes = try #require(
            try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id))
        #expect(healedNotes.memoryDigest != nil)
        #expect(!healedNotes.digestEditOwed && !healedNotes.deliveryOwed)
        #expect(try await harness.queueRows(meeting.id) == rowsBefore + 1)
    }
}
