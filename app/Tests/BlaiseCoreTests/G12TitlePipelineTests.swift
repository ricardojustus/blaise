import AVFoundation
import CryptoKit
import Foundation
import Synchronization
import Testing

@testable import BlaiseCore

// G12 — the title precedence ladder (user > calendar > llm > default) and the
// capture-code fix for the rename-during-recording revert.
//
// All fixtures are FICTIONAL and unrelated to any real person (Vexatron Labs / Quoll
// Harbor — the established test universe), per the standing no-real-data rule.

// MARK: - Shared controller harness (mirrors RecordingControllerTests)

/// Mock engine that plants 1 s of real LPCM CAF on start so the REAL verified
/// encode + stop path runs. Identical in spirit to RecordingControllerTests'
/// MockCaptureEngine; duplicated here to keep this suite self-contained.
private final class G12MockEngine: AudioCapturing, @unchecked Sendable {
    let state = Mutex<(@Sendable (CaptureEngineEvent) -> Void)?>(nil)

    @discardableResult
    func start(
        systemCAF: URL, micCAF: URL,
        onEvent: @escaping @Sendable (CaptureEngineEvent) -> Void
    ) async throws -> CaptureStartInfo {
        state.withLock { $0 = onEvent }
        for url in [systemCAF, micCAF] {
            let writer = try CaptureCAFWriter(url: url)
            let buffer = AVAudioPCMBuffer(pcmFormat: CaptureCAFWriter.format, frameCapacity: 16_000)!
            buffer.frameLength = 16_000
            try writer.write(buffer)
            writer.close()
        }
        return CaptureStartInfo(micStreams: 1)
    }

    func stop() async {}
}

private func makeG12Controller(_ database: BlaiseDatabase) -> RecordingController {
    RecordingController(
        database: database, engine: G12MockEngine(),
        processKicker: { _ in }, now: { msDate() })
}

@Suite("G12 title pipeline")
struct G12TitlePipelineTests {

    // MARK: - AC1: the rename-during-recording revert is FIXED

    @Test("AC1: a rename DURING recording survives stop (the stale-snapshot clobber is gone)")
    func renameDuringRecordingSurvivesStop() async throws {
        let database = try makeDatabase()
        let controller = makeG12Controller(database)

        // Start an ad-hoc meeting — its row carries the date-default title and
        // that start-time snapshot is captured into the live session.
        let started = try await controller.start(source: .inPerson)
        let dateDefault = started.title

        // Rename the DB row WHILE the session is live (the surgical title write
        // never touches the actor's in-memory session.meeting).
        let renamed = "Quoll Harbor field notes"
        try await database.pool.write { db in
            try db.execute(
                sql: "UPDATE meeting SET title = ?, title_source = ? WHERE id = ?",
                arguments: [renamed, TitleSource.user.rawValue, started.id])
        }

        // Stop drives the REAL performStop. PRE-FIX, performStop wrote the stale
        // full row (date-default title) back over the rename; the fix writes
        // only ended_at/updated_at, so the rename survives.
        _ = try await controller.stop()

        let stored = try #require(try await MeetingRepository(database: database).fetch(started.id))
        #expect(
            stored.title == renamed,
            "the rename must survive the stop — a stale-snapshot full-row clobber would revert it to \(dateDefault)")
        #expect(stored.titleSource == .user)
        #expect(stored.endedAt != nil, "the stop still records ended_at")
    }

    @Test("AC2: the resume write-back preserves a title changed mid-grace")
    func resumeWriteBackPreservesConcurrentRename() async throws {
        let database = try makeDatabase()
        let controller = makeG12Controller(database)

        // Start → auto-stop into the GRACE window (status stays `recording`, no
        // live session) — the state the grace-rejoin `resume(meetingID:)`
        // expects. The resume write-back must not clobber a title set while in
        // grace.
        let started = try await controller.start(source: .inPerson)
        _ = try await controller.autoStop(finalizeImmediately: false)
        // Rename while in grace; the resume fetches fresh, but a full-row write
        // of the fetched value would still risk a concurrent change.
        let renamed = "Vexatron Labs standup"
        try await database.pool.write { db in
            try db.execute(
                sql: "UPDATE meeting SET title = ?, title_source = ? WHERE id = ?",
                arguments: [renamed, TitleSource.user.rawValue, started.id])
        }
        _ = try await controller.resume(meetingID: started.id)
        let afterResume = try #require(try await MeetingRepository(database: database).fetch(started.id))
        #expect(afterResume.title == renamed, "resume's write-back preserved the rename")
        #expect(afterResume.titleSource == .user)
        #expect(afterResume.endedAt == nil, "resume cleared ended_at")

        // And a stop after resume still keeps it.
        _ = try await controller.stop()
        let afterStop = try #require(try await MeetingRepository(database: database).fetch(started.id))
        #expect(afterStop.title == renamed)
        #expect(afterStop.titleSource == .user)
    }

    // MARK: - AC2: the precedence ladder writers + gates

    @Test("AC2: a suggestion-matched start writes the CALENDAR tier")
    func calendarTierAtStart() async throws {
        let database = try makeDatabase()
        let controller = makeG12Controller(database)
        let anchor = CalendarAnchor(
            eventIdentifier: "vexatron-evt-1",
            scheduledEnd: msDate(3_600))
        let meeting = try await controller.start(
            source: .meet, title: "Vexatron board review", anchor: anchor)
        let stored = try #require(try await MeetingRepository(database: database).fetch(meeting.id))
        #expect(stored.title == "Vexatron board review")
        #expect(stored.titleSource == .calendar)
        _ = try await controller.stop()
    }

    @Test("AC2: an ad-hoc start (no anchor) is the DEFAULT tier")
    func adHocStartIsDefaultTier() async throws {
        let database = try makeDatabase()
        let controller = makeG12Controller(database)
        let meeting = try await controller.start(source: .inPerson)
        let stored = try #require(try await MeetingRepository(database: database).fetch(meeting.id))
        #expect(stored.titleSource == .default)
        _ = try await controller.stop()
    }

    @Test("AC2: renameMeeting sets the USER tier (top of the ladder)")
    func renameSetsUserTier() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        _ = try await harness.pipeline.process(meetingID: meeting.id)

        let changed = try await harness.pipeline.renameMeeting(
            meetingID: meeting.id, to: "Quoll Harbor retro")
        #expect(changed)
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.title == "Quoll Harbor retro")
        #expect(stored.titleSource == .user)
    }

    @Test("AC2: regeneration refreshes an llm title but NEVER a user/calendar title")
    func regenerationRefreshesLLMOnly() async throws {
        // user tier: a rename then a re-process must keep the user title.
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        _ = try await harness.pipeline.renameMeeting(meetingID: meeting.id, to: "Vexatron locked title")
        // A fresh generation returns a different notes title; it must NOT win.
        harness.notesPrimary.state.withLock { $0.notesTitle = "Regenerated notes title" }
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.title == "Vexatron locked title", "a user title is never overwritten by regeneration")
        #expect(stored.titleSource == .user)
    }

    // MARK: - AC3: the LLM promotion, truncation, gating, ordering

    @Test("AC3: an ad-hoc meeting promotes NotesStructured.title into BOTH markdown and payload")
    func llmPromotionLandsInMarkdownAndPayload() async throws {
        let harness = try await makePipelineHarness()
        // The notes engine yields a LONG fictional title so the promoted,
        // truncated `meeting.title` is a DIFFERENT string than the raw
        // `NotesStructured.title`. This split is what makes assertion (b)
        // non-vacuous: the markdown H1 can only equal the promoted (truncated)
        // value if the promotion's value reached the stage-12 render — were the
        // render fed the date-default `meetingTitle`, or the raw structured
        // title, the H1 would NOT equal `meeting.title` and (b) would FAIL.
        let rawNotesTitle = "Quoll Harbor Q3 launch sync " + String(repeating: "x", count: 90)
        let promotedTitle = try #require(ProcessingPipeline.promotedLLMTitle(from: rawNotesTitle))
        #expect(promotedTitle != rawNotesTitle, "the promoted title must be truncated (distinct from the raw notes title)")
        #expect(promotedTitle.count == ProcessingPipeline.maxTitleLength)
        harness.notesPrimary.state.withLock { $0.notesTitle = rawNotesTitle }
        let meeting = try await harness.importTestMeeting()
        // Pre-condition: the imported meeting is default-tier, with a
        // date-default title DISTINCT from both the raw and the promoted title.
        let before = try #require(try await harness.meeting(meeting.id))
        #expect(before.titleSource == .default)
        let dateDefault = before.title
        #expect(dateDefault != promotedTitle && dateDefault != rawNotesTitle)

        let record = try await harness.pipeline.process(meetingID: meeting.id)

        // (DB) the row carries the PROMOTED (truncated) title at the llm tier.
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.title == promotedTitle)
        #expect(stored.titleSource == .llm)

        // (a) the minted payload's top-level title is the promoted title —
        // proves the promotion committed BEFORE EvidencePayloadBuilder.build
        // (stage 13, which builds from the just-fetched finalMeeting.title).
        let payloadURL = harness.database.rootURL.appendingPathComponent(
            try #require(record.payloadPath))
        let payload = try JSONSerialization.jsonObject(
            with: Data(contentsOf: payloadURL)) as? [String: Any]
        #expect(payload?["title"] as? String == promotedTitle)

        // (b) the persisted markdown notes file's H1 is the PROMOTED title (it
        // equals stored.title and is NOT the raw notes title nor the
        // date-default). Because the renderer derives the H1 from the structured
        // title FIRST, the H1 can equal the promoted value ONLY if the promotion
        // reached the stage-12 persistNotes render — a promotion pinned only
        // before the stage-13 build (or fed the date-default `meetingTitle`)
        // would leave the H1 on the raw 200-char title and FAIL here. Floor 5:
        // the human notes surface and the payload now agree on one title.
        let markdown = try String(contentsOf: harness.database.paths.notesURL(meeting.id), encoding: .utf8)
        #expect(markdown.hasPrefix("# \(stored.title)\n"), "markdown H1 carries the promoted title")
        #expect(!markdown.hasPrefix("# \(rawNotesTitle)\n"), "the markdown H1 is NOT the raw (untruncated) notes title")
        #expect(!markdown.hasPrefix("# \(dateDefault)\n"), "the markdown H1 is NOT the date-default")
        // The payload's embedded markdown is the same rendered bytes.
        #expect((payload?["summary_markdown"] as? String)?.hasPrefix("# \(stored.title)\n") == true)
        // The AI surface (notes_structured.title) preserves the RAW model output
        // verbatim — the promotion normalizes only the human-facing surfaces
        // (Floor 5: notes are for humans, the structured block is for AI).
        let notesStructured = payload?["notes_structured"] as? [String: Any]
        #expect(notesStructured?["title"] as? String == rawNotesTitle)
    }

    @Test("AC3: a calendar-tier meeting is NOT promoted (the gate refuses non-default)")
    func calendarTierNotPromoted() async throws {
        let harness = try await makePipelineHarness()
        harness.notesPrimary.state.withLock { $0.notesTitle = "LLM would-be title" }
        // Import, then force the row to the calendar tier (a calendar-matched
        // start writes this; imports can't, so set it directly for the gate).
        let meeting = try await harness.importTestMeeting()
        try await harness.database.pool.write { db in
            try db.execute(
                sql: "UPDATE meeting SET title = ?, title_source = ? WHERE id = ?",
                arguments: ["Vexatron calendar title", TitleSource.calendar.rawValue, meeting.id])
        }
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.title == "Vexatron calendar title", "the calendar tier is not clobbered by the llm promotion")
        #expect(stored.titleSource == .calendar)
    }

    @Test("AC3: an empty/whitespace NotesStructured.title does NOT promote (non-null gate)")
    func emptyNotesTitleDoesNotPromote() async throws {
        let harness = try await makePipelineHarness()
        harness.notesPrimary.state.withLock { $0.notesTitle = "   " }
        let meeting = try await harness.importTestMeeting()
        let importTitle = try #require(try await harness.meeting(meeting.id)).title
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.title == importTitle, "a blank notes title leaves the default-tier title in place")
        #expect(stored.titleSource == .default)
    }

    @Test("AC3: a too-long NotesStructured.title is truncated to 80 chars with an ellipsis")
    func longTitleTruncated() async throws {
        // Pure-function pin of the gate/normalization (no pipeline needed).
        let long = String(repeating: "x", count: 200)
        let promoted = try #require(ProcessingPipeline.promotedLLMTitle(from: long))
        #expect(promoted.count == ProcessingPipeline.maxTitleLength)
        #expect(promoted.hasSuffix("…"))

        #expect(ProcessingPipeline.promotedLLMTitle(from: nil) == nil)
        #expect(ProcessingPipeline.promotedLLMTitle(from: "") == nil)
        #expect(ProcessingPipeline.promotedLLMTitle(from: "   \n ") == nil)
        #expect(ProcessingPipeline.promotedLLMTitle(from: "  Trimmed  ") == "Trimmed")
        let exactly80 = String(repeating: "y", count: 80)
        #expect(ProcessingPipeline.promotedLLMTitle(from: exactly80) == exactly80)
    }

    @Test("AC3: regeneration REFRESHES an llm title from a newer generation")
    func regenerationRefreshesLLMTitle() async throws {
        let harness = try await makePipelineHarness()
        harness.notesPrimary.state.withLock { $0.notesTitle = "First llm title" }
        let meeting = try await harness.importTestMeeting()
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        let first = try #require(try await harness.meeting(meeting.id))
        #expect(first.title == "First llm title")
        #expect(first.titleSource == .llm)

        // A second generation with a new title refreshes the llm tier.
        harness.notesPrimary.state.withLock { $0.notesTitle = "Refreshed llm title" }
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        let second = try #require(try await harness.meeting(meeting.id))
        #expect(second.title == "Refreshed llm title")
        #expect(second.titleSource == .llm)
    }

    // MARK: - AC6: migration is additive v13; no prompt constant changed

    @Test("AC6: the title_source migration is registered as v13 — the next name AFTER v12")
    func migrationRegisteredAsV13AfterV12() async throws {
        // Confirm the tree being built already contains v12 (the G11 calendar
        // columns) and that title_source's migration is the NEXT sequential
        // name, v13 — registering against a stale v11 base would name it v12
        // and collide with main, silently skipping the calendar migration.
        let database = try makeDatabase()
        let applied = try await database.pool.read { db in
            try Set(String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations"))
        }
        #expect(applied.contains("v12"), "the tree must already contain v12 (post-rebase main)")
        #expect(applied.contains("v13"), "title_source is registered as the additive v13")
        // (Pre-merge this also asserted v13 was the HIGHEST migration; post-merge
        //  G14 registers v14 immediately after it, so that branch-local guard no
        //  longer holds — AC6's rebase-correctness invariant is v12 AND v13 both
        //  present, asserted above.)

        // The column exists, NOT NULL, backfilled 'default' for prior rows.
        let columns = try await database.pool.read { db -> [String] in
            try db.columns(in: "meeting").map(\.name)
        }
        #expect(columns.contains("title_source"))
    }

    @Test("AC6: G12 changed NO notes prompt — v1/v11/v2 hashes stay byte-identical")
    func promptHashesUnchanged() {
        // The chunk reuses the existing NotesStructured.title and edits no
        // prompt constant (D27). Reaffirm the frozen hashes here so a stray
        // prompt edit in the G12 diff fails this gate.
        func hex(_ s: String) -> String {
            SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        #expect(hex(NotesPromptBuilder.systemPromptV1)
            == "49dc155e6223337c4d717a36f52f55ca82b0f36b0277672af60ffe82918cf314")
        // G6 re-pin (publish-scrub: the v11 suffix's misheard-vs-canonical
        // example real name → fictional "Marsa (Dana Marsh)"; v1/v2 untouched).
        #expect(hex(NotesPromptBuilder.systemPromptV11)
            == "c579b9f5c706508a491920d5555851211004ef09e86e6adae31daa7267705ae4")
        #expect(hex(NotesPromptBuilder.systemPromptV2)
            == "1900a407f905bff5a42805c3e2052b706143bb3639dd8d8cbb2cc871bc041298")
    }

    @Test("AC2: TitleSource orders default < llm < calendar < user")
    func titleSourceOrdering() {
        #expect(TitleSource.default < TitleSource.llm)
        #expect(TitleSource.llm < TitleSource.calendar)
        #expect(TitleSource.calendar < TitleSource.user)
        #expect(TitleSource.user > TitleSource.default)
    }
}
