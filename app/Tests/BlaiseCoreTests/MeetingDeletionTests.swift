import Foundation
import GRDB
import Testing
@testable import BlaiseCore

// G10 §2/§2b/AC2/AC3: tombstone-disciplined deletion. Full local erasure in
// ONE transaction (incl. delivered queue rows + FTS); the RESTRICT discipline
// (children-first); the tombstone written in-transaction; the launch sweep
// removing EXACTLY the tombstoned dirs; the C-1 floor-2 pin (a row-less dir
// WITHOUT a tombstone is NEVER touched); the delete-vs-delivery no-op race.

@Suite struct MeetingDeletionTests {

    /// Drives a meeting to `ready` (1 queue row), marks it delivered, enqueues
    /// a SECOND superseding pending row, and writes some FTS-indexed segments —
    /// the full local footprint a delete must erase.
    private func readyHarnessWithQueueAndFTS() async throws -> (PipelineHarness, Meeting) {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        // Mark the one queued row delivered (a delivered row must STILL be
        // deleted — children-first under RESTRICT).
        let items = try await HandoffRepository(database: harness.database).allItems()
        for item in items where item.meetingID == meeting.id {
            _ = try await HandoffRepository(database: harness.database)
                .transition(item.id, to: .delivering)
            _ = try await HandoffRepository(database: harness.database).markDelivered(item.id)
        }
        return (harness, meeting)
    }

    @Test func deleteErasesAllLocalRowsAndWritesTombstoneInOneTransaction() async throws {
        let (harness, meeting) = try await readyHarnessWithQueueAndFTS()
        let db = harness.database
        let dir = db.paths.meetingDirectory(meeting.id)
        #expect(FileManager.default.fileExists(atPath: dir.path))
        // Pre: FTS has rows for this meeting's segments.
        let ftsBefore = try await db.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_fts") ?? 0
        }
        #expect(ftsBefore > 0)

        try await harness.pipeline.deleteMeeting(meetingID: meeting.id)

        try await db.pool.read { db in
            // Meeting + every child table empty for this id.
            try #expect(Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meeting WHERE id = ?", arguments: [meeting.id]) == 0)
            try #expect(Int.fetchOne(db, sql: "SELECT COUNT(*) FROM handoff_queue WHERE meeting_id = ?", arguments: [meeting.id]) == 0)
            try #expect(Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_segment WHERE meeting_id = ?", arguments: [meeting.id]) == 0)
            try #expect(Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meeting_notes WHERE meeting_id = ?", arguments: [meeting.id]) == 0)
            // FTS cascaded with the segments (external-content sync triggers).
            try #expect(Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_fts") == 0)
            // The tombstone was written and then CLEARED by step 3 (dir gone).
            try #expect(Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meeting_tombstone") == 0)
        }
        // Dir removed (step 2).
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    /// AC2: a mutant that deletes the meeting row BEFORE the queue rows must
    /// FAIL on ON DELETE RESTRICT. This pins the children-first discipline.
    @Test func deletingMeetingBeforeQueueRowsFailsOnRestrict() async throws {
        let (harness, meeting) = try await readyHarnessWithQueueAndFTS()
        await #expect(throws: (any Error).self) {
            try await harness.database.pool.write { db in
                // WRONG ORDER: meeting before its restricting children.
                try db.execute(sql: "DELETE FROM meeting WHERE id = ?", arguments: [meeting.id])
            }
        }
        // The meeting is still intact (the failed transaction rolled back).
        try #expect(await harness.meeting(meeting.id) != nil)
    }

    /// AC3: kill MID-transaction (the erase commit throws) → fully intact, no
    /// tombstone, dir present.
    @Test func killMidTransactionLeavesEverythingIntact() async throws {
        let (harness, meeting) = try await readyHarnessWithQueueAndFTS()
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await harness.pipeline.deleteMeeting(meetingID: meeting.id) { throw Boom() }
        }
        try #expect(await harness.meeting(meeting.id) != nil, "the meeting survives a mid-txn kill")
        try await harness.database.pool.read { db in
            try #expect(Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meeting_tombstone") == 0)
            try #expect(Int.fetchOne(db, sql: "SELECT COUNT(*) FROM handoff_queue WHERE meeting_id = ?", arguments: [meeting.id]) == 1)
        }
        #expect(FileManager.default.fileExists(atPath: harness.database.paths.meetingDirectory(meeting.id).path))
    }

    /// AC3: kill between (1) commit and (2) dir removal → relaunch sweeps ONLY
    /// the tombstoned dir, then clears the tombstone.
    @Test func killBetweenTxnAndRemoveLeavesTombstoneSweptAtLaunch() async throws {
        let (harness, meeting) = try await readyHarnessWithQueueAndFTS()
        let db = harness.database
        let dir = db.paths.meetingDirectory(meeting.id)
        // Simulate step 1 only (erase + tombstone), NO dir removal — the
        // crash-between window.
        _ = try await MeetingDeletion.eraseAndTombstone(database: db, meetingID: meeting.id)
        try #expect(await harness.meeting(meeting.id) == nil)
        #expect(FileManager.default.fileExists(atPath: dir.path), "dir still present (kill before step 2)")
        let tombstonesBefore = try await db.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meeting_tombstone") ?? 0
        }
        #expect(tombstonesBefore == 1)

        // Relaunch sweep.
        let swept = await MeetingDeletion.sweepTombstones(database: db)
        #expect(swept == [meeting.id])
        #expect(!FileManager.default.fileExists(atPath: dir.path), "the tombstoned dir was removed")
        try await db.pool.read { db in
            try #expect(Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meeting_tombstone") == 0)
        }
    }

    /// AC3, the C-1 floor-2 pin: a row-less dir WITHOUT a tombstone (a
    /// recreated blaise.sqlite, a mid-import crash) is NEVER touched by the
    /// sweep — the sweep keys ONLY on tombstone rows.
    @Test func rowlessDirWithoutTombstoneIsNeverTouched() async throws {
        let harness = try await makePipelineHarness()
        let db = harness.database
        // A meeting dir with audio but NO row and NO tombstone (the fresh-DB /
        // import-crash scenario).
        let orphanID = ULID.generate()
        try db.paths.createMeetingDirectory(orphanID)
        let audio = db.paths.audioURL(orphanID)
        try Data("retained audio bytes".utf8).write(to: audio)
        try #expect(await harness.meeting(orphanID) == nil, "no row")

        let swept = await MeetingDeletion.sweepTombstones(database: db)
        #expect(swept.isEmpty, "no tombstone ⇒ nothing swept")
        #expect(
            FileManager.default.fileExists(atPath: audio.path),
            "floor 2: a row-less dir without a tombstone is NEVER deleted")
    }

    /// AC3: kill between (2) dir removal and (3) tombstone clear → a stale
    /// tombstone with no dir → swept harmlessly (the tombstone clears).
    @Test func staleTombstoneWithNoDirSweepsHarmlessly() async throws {
        let harness = try await makePipelineHarness()
        let db = harness.database
        // A tombstone whose dir was already removed (kill before step 3).
        let id = ULID.generate()
        let tombstone = MeetingTombstone(
            id: id, audioDirPath: "meetings/\(id)", deletedAt: Date())
        try await db.pool.write { db in try tombstone.insert(db) }
        let swept = await MeetingDeletion.sweepTombstones(database: db)
        #expect(swept == [id])
        try await db.pool.read { db in
            try #expect(Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meeting_tombstone") == 0)
        }
    }

    /// G10 §2 (H-4): floor-2 path-traversal containment. A tombstone whose
    /// `audio_dir_path` resolves OUTSIDE `<root>/meetings/` (only reachable via
    /// a corrupted/tampered `blaise.sqlite`) is QUARANTINED — the named
    /// directory is NEVER deleted, and the tombstone is KEPT (loud log), not
    /// cleared. The sweep is the only autonomous file-deletion authority for
    /// meeting data; it must never delete-as-pointed.
    @Test func tombstoneTraversalCannotDeleteOutsideMeetingsDir() async throws {
        let harness = try await makePipelineHarness()
        let db = harness.database

        // (a) `meetings/../victim` → escapes meetings/ into the data root.
        let victimInRoot = db.rootURL.appendingPathComponent("victim")
        try FileManager.default.createDirectory(at: victimInRoot, withIntermediateDirectories: true)
        try Data("precious".utf8).write(to: victimInRoot.appendingPathComponent("keep.txt"))
        let traversalID = ULID.generate()
        let traversalTombstone = MeetingTombstone(
            id: traversalID, audioDirPath: "meetings/../victim", deletedAt: Date())

        // (b) `../<sibling>` → escapes the data root entirely.
        let outside = db.rootURL.deletingLastPathComponent()
            .appendingPathComponent("g10-h4-outside-victim", isDirectory: true)
        try? FileManager.default.removeItem(at: outside)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outside.appendingPathComponent("keep.txt"))
        let escapeID = ULID.generate()
        let escapeTombstone = MeetingTombstone(
            id: escapeID, audioDirPath: "../g10-h4-outside-victim", deletedAt: Date())

        try await db.pool.write { db in
            try traversalTombstone.insert(db)
            try escapeTombstone.insert(db)
        }

        _ = await MeetingDeletion.sweepTombstones(database: db)

        // Both victims survive untouched.
        #expect(
            FileManager.default.fileExists(atPath: victimInRoot.appendingPathComponent("keep.txt").path),
            "a tombstone escaping meetings/ must NOT delete the data-root sibling")
        #expect(
            FileManager.default.fileExists(atPath: outside.appendingPathComponent("keep.txt").path),
            "a tombstone escaping the data root must NOT delete the outside dir")
        // Both tombstones are QUARANTINED (kept for inspection), not cleared.
        let remaining = try await db.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meeting_tombstone") ?? -1
        }
        #expect(remaining == 2, "quarantined tombstones are kept, never silently cleared")

        // A WELL-FORMED tombstone in the SAME sweep is still acted on — the
        // guard did not over-reject legitimate `meetings/<ULID>` paths.
        let goodID = ULID.generate()
        try db.paths.createMeetingDirectory(goodID)
        let goodDir = db.paths.meetingDirectory(goodID)
        let goodTombstone = MeetingTombstone(
            id: goodID, audioDirPath: "meetings/\(goodID)", deletedAt: Date())
        try await db.pool.write { db in try goodTombstone.insert(db) }
        _ = await MeetingDeletion.sweepTombstones(database: db)
        #expect(!FileManager.default.fileExists(atPath: goodDir.path), "a contained tombstone IS swept")

        try? FileManager.default.removeItem(at: outside)
    }

    /// AC2/§2b: a `paused` meeting deletes DIRECTLY (it has no in-flight run).
    @Test func pausedMeetingDeletesDirectly() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        try await harness.database.pool.write { db in
            try db.execute(sql: "UPDATE meeting SET status = 'paused' WHERE id = ?", arguments: [meeting.id])
        }
        try await harness.pipeline.deleteMeeting(meetingID: meeting.id)
        try #expect(await harness.meeting(meeting.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: harness.database.paths.meetingDirectory(meeting.id).path))
    }

    /// AC2: delete refuses a `recording` meeting (the live writer holds the dir).
    @Test func deleteRefusesRecordingMeeting() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        try await harness.database.pool.write { db in
            try db.execute(sql: "UPDATE meeting SET status = 'recording' WHERE id = ?", arguments: [meeting.id])
        }
        await #expect(throws: PipelineDeleteError.self) {
            try await harness.pipeline.deleteMeeting(meetingID: meeting.id)
        }
        try #expect(await harness.meeting(meeting.id) != nil)
    }

    /// AC2: "Cancel & Delete" composition — the in-flight run is cancelled
    /// (token first) and the delete runs after it winds down. End state: gone.
    @Test func cancelAndDeleteWindsDownThenErases() async throws {
        let harness = try await makePipelineHarness()
        harness.asr.state.withLock { $0.transcribeDelaySeconds = 5 }
        let meeting = try await harness.importTestMeeting()
        let pipeline = harness.pipeline
        let runTask = Task { try? await pipeline.process(meetingID: meeting.id) }
        #expect(await waitUntil { await pipeline.hasRunInFlight(meeting.id) })
        // Cancel & Delete: token first, then the chained delete.
        _ = await pipeline.cancel(meetingID: meeting.id)
        try await pipeline.deleteMeeting(meetingID: meeting.id)
        _ = await runTask.value
        try #expect(await harness.meeting(meeting.id) == nil, "Cancel & Delete erases the meeting")
        #expect(!FileManager.default.fileExists(atPath: harness.database.paths.meetingDirectory(meeting.id).path))
    }

    /// §2 in-flight delivery race: a queue row deleted mid-delivery makes
    /// markDelivered a logged no-op (the row is gone; `transition` throws
    /// `handoffItemNotFound`, which the worker swallows).
    @Test func deleteVsDeliveryRaceMakesMarkDeliveredNoOp() async throws {
        let (harness, meeting) = try await readyHarnessWithQueueAndFTS()
        // Re-enqueue a fresh pending row to act as the "claimed" item.
        let items = try await HandoffRepository(database: harness.database).allItems()
        let claimed = try #require(items.first { $0.meetingID == meeting.id })
        // Delete the meeting (erases the queue row) THEN the worker tries to
        // mark its claimed item delivered.
        try await harness.pipeline.deleteMeeting(meetingID: meeting.id)
        await #expect(throws: BlaiseDatabaseError.self) {
            _ = try await HandoffRepository(database: harness.database).markDelivered(claimed.id)
        }
    }
}
