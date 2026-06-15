import Foundation
import GRDB
import os

// G10 §2: tombstone-disciplined meeting deletion.
//
// Floor 2 as refined by D23: the SYSTEM never deletes autonomously. File
// deletion happens ONLY under a durable owner-intent record — the tombstone.
// Row-absence proves nothing (a recreated blaise.sqlite makes every dir
// row-less; that scenario must preserve EVERYTHING). The tombstone is written
// in the SAME transaction that erases the meeting's rows; the launch sweep
// (CaptureRecovery's launch recovery, beside the orphan-CAF sweep) removes
// EXACTLY the tombstoned dirs and then their tombstones.
//
// Order, crash-safe at every point:
//   1. ONE DB transaction: delete children-first (ON DELETE RESTRICT on
//      handoff_queue forces queue rows first), then the meeting row; INSERT
//      the tombstone.
//   2. Remove the audio directory.
//   3. Delete the tombstone row.
// Kill before (1) commits → nothing happened. Kill between (1) and (2) →
// the sweep removes exactly the tombstoned dir. Kill between (2) and (3) →
// stale tombstone with no dir → swept harmlessly. DB loss/recreation → no
// tombstones → no file is ever deleted (floor 2 holds by construction).

/// The durable owner-intent record (migration v11). `audioDirPath` is stored
/// RELATIVE to the data root so the root can move (consistent with
/// handoff payload paths); the sweep resolves it against the live root.
public struct MeetingTombstone: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "meeting_tombstone"

    public var id: MeetingID
    public var audioDirPath: String
    public var deletedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case audioDirPath = "audio_dir_path"
        case deletedAt = "deleted_at"
    }

    public init(id: MeetingID, audioDirPath: String, deletedAt: Date) {
        self.id = id
        self.audioDirPath = audioDirPath
        self.deletedAt = deletedAt
    }
}

public enum MeetingDeletion {
    private static let logger = Logger(subsystem: BlaiseBundle.identifier, category: "deletion")

    /// Step 1 — the one-transaction erasure. Deletes every local row for the
    /// meeting CHILDREN-FIRST (handoff_queue is ON DELETE RESTRICT, so its
    /// rows — ALL states including delivered — go before the meeting row, or
    /// the meeting delete fails on the restrict), then INSERTS the tombstone
    /// recording the dir still owed removal. FTS, transcript segments, parts,
    /// speaker events/renames, notes, and action-item state ride their own
    /// ON DELETE CASCADE off the meeting row; name-correction source links and
    /// receipts are ON DELETE SET NULL by design (the correction/bill outlives
    /// the meeting). The remote inbox (delivered copies) is untouched immutable
    /// history; local payload files live inside the meeting dir and go in
    /// step 2 with it. `midTransactionHook` is the crash-test seam.
    ///
    /// Returns the tombstone written (its `audioDirPath` is the relative dir
    /// path the sweep / step 2 resolve against the live root).
    @discardableResult
    public static func eraseAndTombstone(
        database: BlaiseDatabase,
        meetingID: MeetingID,
        now: Date = Date(),
        midTransactionHook: (@Sendable () throws -> Void)? = nil
    ) async throws -> MeetingTombstone {
        let relativeDir = "meetings/\(meetingID)"
        let tombstone = MeetingTombstone(
            id: meetingID, audioDirPath: relativeDir, deletedAt: now)
        try await database.pool.write { db in
            // Children of handoff_queue's RESTRICT first — ALL states.
            try db.execute(
                sql: "DELETE FROM handoff_queue WHERE meeting_id = ?", arguments: [meetingID])
            // The meeting row drops the CASCADE children (transcript_segment +
            // its FTS sync triggers, meeting_notes, meeting_speaker_event,
            // meet_roster_pending, action_item_state, meeting_capture_part,
            // speaker_rename) and SET-NULLs the by-design survivors
            // (cloud_spend_receipt.meeting_id, name_correction.source_meeting_id).
            try db.execute(sql: "DELETE FROM meeting WHERE id = ?", arguments: [meetingID])
            // The tombstone, in the SAME transaction: no crash window can erase
            // the rows without recording the dir still owed removal.
            try tombstone.insert(db)
            try midTransactionHook?()
        }
        logger.notice(
            "erased meeting \(meetingID, privacy: .public); tombstone written for \(relativeDir, privacy: .public)")
        return tombstone
    }

    /// Steps 2+3 for ONE tombstone: remove the audio dir, then delete the
    /// tombstone row. Shared by the live delete and the launch sweep. Removing
    /// an absent dir is a no-op (the kill-between-(2)-and-(3) case); the
    /// tombstone is cleared regardless, so a stale tombstone with no dir is
    /// swept harmlessly.
    public static func removeDirAndClear(
        database: BlaiseDatabase, tombstone: MeetingTombstone
    ) async {
        let dir = database.rootURL.appendingPathComponent(tombstone.audioDirPath)
        // G10 §2 (H-4): floor-2 containment. This sweep is the ONLY autonomous
        // file-deletion authority for meeting data; it must never delete-as-
        // pointed a path that escapes the data root's `meetings/` directory.
        // The sole writer (`eraseAndTombstone`) only ever stores
        // `"meetings/<ULID>"`, so a traversal path (`../victim`, an absolute
        // path) is only reachable from a corrupted/tampered `blaise.sqlite` —
        // but floor 2 is a hard floor, so the tombstone is QUARANTINED (kept,
        // loudly logged, NEVER acted on) rather than blindly obeyed. Symlinks
        // are resolved before the containment check so a symlinked component
        // cannot smuggle the target outside the tree.
        let meetingsRoot = database.rootURL.appendingPathComponent("meetings")
        let resolvedDir = dir.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedRoot = meetingsRoot.standardizedFileURL.resolvingSymlinksInPath()
        let rootComponents = resolvedRoot.pathComponents
        let dirComponents = resolvedDir.pathComponents
        let containedAndDeeper =
            dirComponents.count > rootComponents.count
            && Array(dirComponents.prefix(rootComponents.count)) == rootComponents
        guard containedAndDeeper else {
            logger.error(
                "tombstone for \(tombstone.id, privacy: .public) resolves OUTSIDE the meetings directory (\(tombstone.audioDirPath, privacy: .public)) — QUARANTINED, not deleted; data root may be corrupted")
            return
        }
        do {
            if FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.removeItem(at: dir)
            }
        } catch {
            // Leave the tombstone in place so the next launch retries the
            // removal (fail-safe direction: residue, never loss).
            logger.error(
                "tombstone dir removal failed for \(tombstone.id, privacy: .public): \(error) — tombstone kept for next sweep")
            return
        }
        try? await database.pool.write { db in
            _ = try MeetingTombstone.deleteOne(db, key: tombstone.id)
        }
    }

    /// Launch tombstone sweep (CaptureRecovery's launch recovery, beside the
    /// orphan-CAF sweep): removes EXACTLY the tombstoned dirs (durable owner
    /// intent, path-specific) and then their tombstones. A row-less dir
    /// WITHOUT a tombstone (a recreated blaise.sqlite, a mid-import crash) is
    /// NEVER touched — this sweep keys ONLY on the tombstone rows, never on
    /// dir-vs-row reconciliation (the C-1 floor-2 pin).
    @discardableResult
    public static func sweepTombstones(database: BlaiseDatabase) async -> [MeetingID] {
        let tombstones =
            (try? await database.pool.read { db in
                try MeetingTombstone.order(Column("deleted_at").asc).fetchAll(db)
            }) ?? []
        var swept: [MeetingID] = []
        for tombstone in tombstones {
            await removeDirAndClear(database: database, tombstone: tombstone)
            swept.append(tombstone.id)
        }
        if !swept.isEmpty {
            logger.notice("tombstone sweep removed \(swept.count) directory/directories")
        }
        return swept
    }
}
