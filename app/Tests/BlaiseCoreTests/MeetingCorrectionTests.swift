import Foundation
import GRDB
import Testing

@testable import BlaiseCore

// G17 AC7: store CRUD + status transitions, and the pure anchoring
// discipline (fold-contains matching, occurrence resolution, re-anchor pass).

private func makeRow(
    meetingID: MeetingID,
    kind: MeetingCorrection.Kind = .understanding,
    section: MeetingCorrection.Section = .detailedNotes,
    quote: String = "committed to migrating",
    occurrence: Int = 0,
    text: String = "Only an evaluation was agreed."
) -> MeetingCorrection {
    MeetingCorrection(
        meetingID: meetingID, kind: kind, section: section,
        quotedText: quote, occurrence: occurrence, userText: text, createdAt: msDate())
}

@Suite struct MeetingCorrectionStoreTests {
    @Test func crudAndOrdering() async throws {
        let db = try makeDatabase()
        let meeting = makeMeeting()
        try await MeetingRepository(database: db).create(meeting)
        let first = makeRow(meetingID: meeting.id)
        let second = makeRow(meetingID: meeting.id, kind: .annotation, text: "Check with Ricardo.")
        try await db.pool.write { conn in
            try MeetingCorrectionStore.insert(conn, first)
            try MeetingCorrectionStore.insert(conn, second)
            let rows = try MeetingCorrectionStore.all(conn, meetingID: meeting.id)
            #expect(rows.map(\.id) == [first.id, second.id])
            #expect(rows[0].status == .pending)

            try MeetingCorrectionStore.update(
                conn, id: first.id, quotedText: "migrating", occurrence: 1,
                userText: "Evaluation only.", status: .pending)
            let updated = try MeetingCorrectionStore.all(conn, meetingID: meeting.id)[0]
            #expect(updated.quotedText == "migrating")
            #expect(updated.occurrence == 1)
            #expect(updated.userText == "Evaluation only.")

            try MeetingCorrectionStore.delete(conn, id: second.id)
            #expect(try MeetingCorrectionStore.all(conn, meetingID: meeting.id).count == 1)
        }
    }

    @Test func markAppliedFlipsOnlyNamedRows() async throws {
        let db = try makeDatabase()
        let meeting = makeMeeting()
        try await MeetingRepository(database: db).create(meeting)
        let consumed = makeRow(meetingID: meeting.id)
        let untouched = makeRow(meetingID: meeting.id, quote: "other span")
        try await db.pool.write { conn in
            try MeetingCorrectionStore.insert(conn, consumed)
            try MeetingCorrectionStore.insert(conn, untouched)
            try MeetingCorrectionStore.markApplied(conn, ids: [consumed.id], at: msDate())
            let rows = try MeetingCorrectionStore.all(conn, meetingID: meeting.id)
            #expect(rows.first { $0.id == consumed.id }?.status == .applied)
            #expect(rows.first { $0.id == consumed.id }?.appliedAt != nil)
            #expect(rows.first { $0.id == untouched.id }?.status == .pending)
        }
    }

    @Test func meetingDeleteCascades() async throws {
        let db = try makeDatabase()
        let meeting = makeMeeting()
        let repo = MeetingRepository(database: db)
        try await repo.create(meeting)
        let row = makeRow(meetingID: meeting.id)
        try await db.pool.write { conn in
            try MeetingCorrectionStore.insert(conn, row)
        }
        try await db.pool.write { conn in
            _ = try Meeting.filter(Column("id") == meeting.id).deleteAll(conn)
            #expect(try MeetingCorrectionStore.all(conn, meetingID: meeting.id).isEmpty)
        }
    }
}

@Suite struct CorrectionPromptTests {
    @Test("presence gate: no corrections -> no block, byte-identical user message")
    func presenceGate() throws {
        #expect(NotesPromptBuilder.correctionsBlock([]) == nil)
        let request = NotesRequest(
            meeting: makeMeeting(), transcript: [], dominantLanguage: "en",
            vocabulary: [], user: UserIdentity(name: "Sam", aliases: [], email: "s@x.co"))
        var withEmpty = request
        withEmpty.corrections = []
        #expect(
            NotesPromptBuilder.userMessage(for: request)
                == NotesPromptBuilder.userMessage(for: withEmpty))
    }

    @Test("understanding corrections render authoritative numbered entries; notes render as margin context")
    func blockShape() throws {
        let block = try #require(NotesPromptBuilder.correctionsBlock([
            NotesCorrection(
                kind: .understanding, section: .detailedNotes,
                quotedText: "committed to migrating", userText: "Evaluation only, no date."),
            NotesCorrection(
                kind: .annotation, section: .summary,
                quotedText: "under evaluation", userText: "Ask Ricardo about Yeti gain."),
        ]))
        #expect(block.contains("USER CORRECTIONS (authoritative"))
        #expect(block.contains("1. In the detailed notes, an earlier draft said: \"committed to migrating\". The user corrects: Evaluation only, no date."))
        #expect(block.contains("USER NOTES"))
        #expect(block.contains("- (on \"under evaluation\") Ask Ricardo about Yeti gain."))
        // The block lands in the user message between metadata and transcript.
        var request = NotesRequest(
            meeting: makeMeeting(), transcript: [], dominantLanguage: "en",
            vocabulary: [], user: UserIdentity(name: "Sam", aliases: [], email: "s@x.co"))
        request.corrections = [
            NotesCorrection(
                kind: .understanding, section: .summary, quotedText: "q", userText: "t")
        ]
        let message = NotesPromptBuilder.userMessage(for: request)
        let metadataRange = try #require(message.range(of: "MEETING:"))
        let blockRange = try #require(message.range(of: "USER CORRECTIONS"))
        let transcriptRange = try #require(message.range(of: "TRANSCRIPT:"))
        #expect(metadataRange.lowerBound < blockRange.lowerBound)
        #expect(blockRange.lowerBound < transcriptRange.lowerBound)
    }
}

@Suite struct AnnotationRenderingTests {
    private let structured = NotesStructured(
        title: "Sync",
        summary: "FluidAudio v2 is under evaluation.",
        detailedNotes: "First paragraph here.\n\nSecond paragraph about the ceiling.",
        decisions: ["Room mode ships behind a setting"],
        actionItems: [ActionItem(owner: "Ricardo", text: "Evaluate FluidAudio v2")],
        userActionItems: [])

    private func annotation(
        section: MeetingCorrection.Section, quote: String, text: String
    ) -> MeetingCorrection {
        MeetingCorrection(
            meetingID: "01TESTMEETING0000000000000", kind: .annotation, section: section,
            quotedText: quote, userText: text, createdAt: msDate())
    }

    @Test("no annotations -> byte-identical to the pre-G17 render")
    func byteIdentityGate() throws {
        let before = try NotesRenderer.render(
            structured, language: "en", meetingTitle: "Sync", userName: "Sam")
        let after = try NotesRenderer.render(
            structured, language: "en", meetingTitle: "Sync", userName: "Sam", annotations: [])
        #expect(before == after)
        // An understanding row alone weaves nothing either (asides are
        // annotation-only; corrections act through re-synthesis).
        let understanding = MeetingCorrection(
            meetingID: "01TESTMEETING0000000000000", kind: .understanding, section: .summary,
            quotedText: "under evaluation", userText: "fix", createdAt: msDate())
        let withUnderstanding = try NotesRenderer.render(
            structured, language: "en", meetingTitle: "Sync", userName: "Sam",
            annotations: [understanding])
        #expect(before == withUnderstanding)
    }

    @Test("anchored notes render as asides by their block; section lists get quoted asides")
    func anchoredAsides() throws {
        let markdown = try NotesRenderer.render(
            structured, language: "en", meetingTitle: "Sync", userName: "Sam",
            annotations: [
                annotation(section: .detailedNotes, quote: "second paragraph", text: "Check threshold too."),
                annotation(section: .actionItem, quote: "Evaluate FluidAudio", text: "By next sprint?"),
            ])
        // The detailed-notes aside sits directly under its paragraph.
        #expect(markdown.contains(
            "Second paragraph about the ceiling.\n\n> **Your note:** Check threshold too."))
        // The list aside names its anchor.
        #expect(markdown.contains(
            "> **Your note** (on \u{201C}Evaluate FluidAudio v2\u{201D}): By next sprint?"))
        // No tail section: everything anchored.
        #expect(!markdown.contains("## Your notes"))
    }

    @Test("unanchored notes land under the tail heading with their original quote — never dropped")
    func unanchoredTail() throws {
        let markdown = try NotesRenderer.render(
            structured, language: "en", meetingTitle: "Sync", userName: "Sam",
            annotations: [
                annotation(
                    section: .detailedNotes, quote: "a paragraph the re-write removed",
                    text: "Important reminder.")
            ])
        #expect(markdown.contains("## Your notes"))
        #expect(markdown.contains(
            "- Important reminder. *(on \u{201C}a paragraph the re-write removed\u{201D})*"))
    }

    @Test("Portuguese localization for asides and tail")
    func portuguese() throws {
        let markdown = try NotesRenderer.render(
            structured, language: "pt-BR", meetingTitle: "Sync", userName: "Sam",
            annotations: [
                annotation(section: .summary, quote: "under evaluation", text: "Confirmar com Ricardo."),
                annotation(section: .summary, quote: "gone from notes", text: "Nota solta."),
            ])
        #expect(markdown.contains("> **Sua nota:** Confirmar com Ricardo."))
        #expect(markdown.contains("## Suas notas"))
        #expect(markdown.contains("*(sobre \u{201C}gone from notes\u{201D})*"))
    }
}

@Suite struct CorrectionPayloadTests {
    @Test("payload presence gate: empty snapshot -> byte-identical pre-G17 payload; snapshot emits user_corrections")
    func presenceGatedPayload() throws {
        let meeting = makeMeeting(status: .ready)
        let user = UserIdentity(name: "Sam", aliases: [], email: "s@x.co")
        let bare = makeNotes(meetingID: meeting.id)
        let before = EvidencePayloadBuilder.build(
            meeting: meeting, segments: [], notes: bare, user: user)

        var withEmpty = bare
        withEmpty.userCorrections = []
        let gated = EvidencePayloadBuilder.build(
            meeting: meeting, segments: [], notes: withEmpty, user: user)
        #expect(gated.versionHash == before.versionHash)

        var withSnapshot = bare
        let row = MeetingCorrection(
            meetingID: meeting.id, kind: .understanding, section: .summary,
            quotedText: "old claim", userText: "the truth", createdAt: msDate())
        withSnapshot.userCorrections = [NotesCorrectionSnapshot(row: row)]
        let minted = EvidencePayloadBuilder.build(
            meeting: meeting, segments: [], notes: withSnapshot, user: user)
        #expect(minted.versionHash != before.versionHash)
        let json = String(decoding: minted.bytes, as: UTF8.self)
        #expect(json.contains("\"user_corrections\""))
        #expect(json.contains("\"quoted_text\":\"old claim\""))
        #expect(json.contains("\"kind\":\"understanding\""))
    }

    @Test("meeting_notes round-trips the snapshot; empty stores NULL (legacy rows decode empty)")
    func snapshotColumnRoundTrip() async throws {
        let db = try makeDatabase()
        let meeting = makeMeeting()
        try await MeetingRepository(database: db).create(meeting)
        var notes = makeNotes(meetingID: meeting.id)
        let row = MeetingCorrection(
            meetingID: meeting.id, kind: .annotation, section: .decision,
            quotedText: "ships behind a setting", userText: "Default ON for me.",
            createdAt: msDate())
        notes.userCorrections = [NotesCorrectionSnapshot(row: row)]
        try await NotesRepository(database: db).upsert(notes)
        let fetched = try await NotesRepository(database: db).fetch(meetingID: meeting.id)
        #expect(fetched?.userCorrections.count == 1)
        #expect(fetched?.userCorrections.first?.quotedText == "ships behind a setting")

        notes.userCorrections = []
        try await NotesRepository(database: db).upsert(notes)
        let cleared = try await db.pool.read { conn in
            try String.fetchOne(
                conn, sql: "SELECT user_corrections FROM meeting_notes WHERE meeting_id = ?",
                arguments: [meeting.id])
        }
        #expect(cleared == nil)
    }
}

@Suite struct CorrectionAnchoringTests {
    private let structured = NotesStructured(
        title: "Sync",
        summary: "FluidAudio v2 is under evaluation for the speaker ceiling.",
        detailedNotes: """
            Arthur walked through the over-counting fix.

            Ricardo agreed to evaluate FluidAudio v2. The room-mode work does not depend on it.

            Room mode reuses the tone-probe protocol.
            """,
        decisions: ["Room mode ships behind a setting", "Keep the threshold at 0.62"],
        actionItems: [
            ActionItem(owner: "Arthur", text: "Verify Yeti gain"),
            ActionItem(owner: "Ricardo", text: "Evaluate FluidAudio v2"),
        ],
        userActionItems: [])

    @Test func foldIsCaseAndWhitespaceInsensitive() {
        #expect(CorrectionAnchoring.fold("  FluidAudio\n V2 ") == "fluidaudio v2")
        #expect(CorrectionAnchoring.fold("") == "")
    }

    @Test func blocksPerSection() {
        #expect(CorrectionAnchoring.blocks(of: structured, section: .summary).count == 1)
        #expect(CorrectionAnchoring.blocks(of: structured, section: .detailedNotes).count == 3)
        #expect(CorrectionAnchoring.blocks(of: structured, section: .decision).count == 2)
        #expect(
            CorrectionAnchoring.blocks(of: structured, section: .actionItem)
                == ["Verify Yeti gain", "Evaluate FluidAudio v2"])
    }

    @Test func resolveFindsNthMatchAndClamps() {
        let blocks = ["alpha beta", "gamma beta", "delta"]
        #expect(CorrectionAnchoring.matches(quote: "BETA", in: blocks) == [0, 1])
        #expect(CorrectionAnchoring.resolve(quote: "beta", occurrence: 1, in: blocks)?.blockIndex == 1)
        // Out-of-range occurrence clamps to the first match (a re-write that
        // collapsed duplicates keeps the note attached).
        #expect(CorrectionAnchoring.resolve(quote: "beta", occurrence: 7, in: blocks)?.blockIndex == 2 - 1)
        #expect(CorrectionAnchoring.resolve(quote: "absent", occurrence: 0, in: blocks) == nil)
        #expect(CorrectionAnchoring.resolve(quote: "", occurrence: 0, in: blocks) == nil)
    }

    @Test func reanchorAppliesMatchedAndStalesOrphans() {
        let meetingID: MeetingID = "01TESTMEETING0000000000000"
        let anchored = MeetingCorrection(
            meetingID: meetingID, kind: .annotation, section: .detailedNotes,
            quotedText: "evaluate fluidaudio v2", occurrence: 0,
            userText: "Ask about Yeti gain too.", status: .pending, createdAt: msDate())
        let orphan = MeetingCorrection(
            meetingID: meetingID, kind: .annotation, section: .detailedNotes,
            quotedText: "a paragraph that was rewritten away", occurrence: 0,
            userText: "Note on removed text.", status: .applied, createdAt: msDate())
        let understanding = MeetingCorrection(
            meetingID: meetingID, kind: .understanding, section: .summary,
            quotedText: "anything", occurrence: 0, userText: "fix", createdAt: msDate())

        let updates = CorrectionAnchoring.reanchor(
            annotations: [anchored, orphan, understanding], against: structured)
        // Understanding rows are excluded (their lifecycle is markApplied's).
        #expect(updates.count == 2)
        #expect(updates.first { $0.id == anchored.id }?.status == .applied)
        #expect(updates.first { $0.id == orphan.id }?.status == .stale)
        // The orphan keeps its stored occurrence for the eventual re-pin.
        #expect(updates.first { $0.id == orphan.id }?.occurrence == 0)
    }
}
