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
