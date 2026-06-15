import Foundation
import GRDB
import Testing
@testable import BlaiseCore

// Opportunistic-local PT/EN fidelity guard. A local meeting corpus, when
// present, carries genuine Portuguese/English code-switching the synthetic and
// ICSI fixtures cannot. When such a corpus is present, structurally
// sanity-check the most recent ready meeting; otherwise skip. This is a
// build-time guard only — never CI, never a default local run.
//
// SAFETY (the production DB may be in use / actively recording):
//  - EXPLICIT OPT-IN: real work happens ONLY when BLAISE_TEST_LOCAL_CORPUS=="1".
//  - The production database is NEVER opened in place for queries and NEVER
//    written or migrated. It is opened READ-ONLY purely to drive SQLite's
//    backup into a TEMP snapshot; all queries run against that snapshot,
//    re-opened READ-ONLY. The snapshot is deleted at the end.
//  - PRIVACY: this reads a local meeting corpus. The test asserts ONLY
//    counts and booleans — never transcript text, titles, or speaker names,
//    and prints none of them.

@Suite struct OpportunisticLocalMeetingTests {
    private static var optedIn: Bool {
        ProcessInfo.processInfo.environment["BLAISE_TEST_LOCAL_CORPUS"] == "1"
    }

    /// Same resolution order as the app's composition root: a
    /// `BLAISE_DATA_ROOT` override, else the production default data root.
    private static func resolveDataRoot() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["BLAISE_DATA_ROOT"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return try BlaiseDatabase.defaultRootURL()
    }

    @Test func newestReadyMeetingIsStructurallySane() throws {
        // Default (CI, normal local runs): do nothing at all. No data root is
        // resolved, no file is touched.
        guard Self.optedIn else { return }

        let dataRoot = try Self.resolveDataRoot()
        let dbURL = dataRoot.appendingPathComponent(BlaiseDatabase.databaseFileName)
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            recordTestSkip(
                "newestReadyMeetingIsStructurallySane",
                reason: "local Blaise data root / database not found")
            return
        }

        // Backup the live DB to a TEMP snapshot, then query the snapshot only.
        // The source is opened READ-ONLY (no migration, no writes — safe even
        // while recording); the backup is a consistent SQLite-level copy.
        let snapshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("blaise-corpus-snapshot-\(UUID().uuidString).sqlite")
        defer {
            // Remove the snapshot and any WAL/SHM siblings.
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(
                    atPath: snapshotURL.path + suffix)
            }
        }

        var readOnly = Configuration()
        readOnly.readonly = true
        let source = try DatabaseQueue(path: dbURL.path, configuration: readOnly)
        let snapshot = try DatabaseQueue(path: snapshotURL.path)
        try source.backup(to: snapshot)
        // Release every handle on the production file immediately after the
        // copy; nothing else touches it.
        try source.close()
        try snapshot.close()

        // Re-open the snapshot READ-ONLY for the structural queries.
        let reader = try DatabaseQueue(path: snapshotURL.path, configuration: readOnly)

        // Newest ready meeting (recency order = the app's list order).
        let meetingID: String? = try reader.read { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT id FROM meeting
                    WHERE status = ?
                    ORDER BY started_at DESC, id DESC
                    LIMIT 1
                    """,
                arguments: [MeetingStatus.ready.rawValue])
        }
        guard let meetingID else {
            recordTestSkip(
                "newestReadyMeetingIsStructurallySane",
                reason: "no ready meetings in the local corpus")
            return
        }

        // Persisted transcript segments — COUNTS/BOOLEANS only, never text.
        let timings: [(start: Double, end: Double)] = try reader.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT start_seconds, end_seconds FROM transcript_segment
                    WHERE meeting_id = ?
                    ORDER BY ord
                    """,
                arguments: [meetingID]
            ).map { row in (row["start_seconds"], row["end_seconds"]) }
        }
        try reader.close()

        // Structural sanity: at least one segment; each interval well-formed;
        // starts monotonic non-decreasing. No content is read or asserted.
        #expect(timings.count > 0, "ready meeting has no persisted transcript segments")
        var previousStart = -Double.infinity
        for (index, timing) in timings.enumerated() {
            #expect(
                timing.end > timing.start,
                "segment \(index): end is not after start")
            #expect(
                timing.start >= previousStart,
                "segment \(index): start is not monotonic non-decreasing")
            previousStart = timing.start
        }

        // The retained audio must exist (the regeneration source). Same
        // two-track presence rule the pipeline/recovery use.
        let paths = MeetingPaths(rootURL: dataRoot)
        let hasAudio =
            FileManager.default.fileExists(atPath: paths.audioURL(meetingID).path)
            || FileManager.default.fileExists(atPath: paths.audioMicURL(meetingID).path)
        guard hasAudio else {
            recordTestSkip(
                "newestReadyMeetingIsStructurallySane",
                reason: "audio absent for the discovered meeting")
            return
        }
    }
}
