import Foundation
import GRDB

// MARK: - MeetingRepository

public struct MeetingRepository: Sendable {
    let database: BlaiseDatabase

    public init(database: BlaiseDatabase) {
        self.database = database
    }

    public func create(_ meeting: Meeting) async throws {
        try await database.pool.write { db in
            try meeting.insert(db)
        }
    }

    public func update(_ meeting: Meeting) async throws {
        var meeting = meeting
        meeting.updatedAt = Date()
        try await database.pool.write { [meeting] db in
            try meeting.update(db)
        }
    }

    public func fetch(_ id: MeetingID) async throws -> Meeting? {
        try await database.pool.read { db in
            try Meeting.fetchOne(db, key: id)
        }
    }

    /// List by recency: `ORDER BY started_at DESC, id DESC`. No delete in V1.
    public func listByRecency() async throws -> [Meeting] {
        try await database.pool.read { db in
            try Meeting
                .order(Column("started_at").desc, Column("id").desc)
                .fetchAll(db)
        }
    }

    /// Meeting-code edit (C10 detail inspector). The CALLER follows up with
    /// the pending-events sweep + status-dependent dispatch.
    ///
    /// Deliberately NO `updatedAt` bump (C1 semantics, amended v6.7):
    /// `updatedAt` tracks CONTENT mutations only and is bumped by content
    /// runs; `meetingCode` is correlation metadata, and it is embedded in no
    /// payload — bumping here would silently invalidate a `ready` meeting's
    /// minted payload (C8 re-materialization must hash-equal version_hash).
    public func setMeetingCode(_ id: MeetingID, to code: String?) async throws {
        try await database.pool.write { db in
            guard var meeting = try Meeting.fetchOne(db, key: id) else {
                throw BlaiseDatabaseError.meetingNotFound(id)
            }
            let normalized = code?.trimmingCharacters(in: .whitespacesAndNewlines)
            meeting.meetingCode = (normalized?.isEmpty ?? true) ? nil : normalized
            try meeting.update(db)
        }
    }
}

// MARK: - TranscriptRepository

public struct TranscriptRepository: Sendable {
    let database: BlaiseDatabase

    public init(database: BlaiseDatabase) {
        self.database = database
    }

    /// Replaces all segments of a meeting in one transaction; FTS stays in
    /// sync via the external-content synchronization triggers.
    @discardableResult
    public func replaceAllSegments(meetingID: MeetingID, with segments: [TranscriptSegment]) async throws -> [TranscriptSegment] {
        try await database.pool.write { db in
            try db.execute(sql: "DELETE FROM transcript_segment WHERE meeting_id = ?", arguments: [meetingID])
            var inserted: [TranscriptSegment] = []
            for var segment in segments {
                segment.meetingID = meetingID
                segment.id = nil
                try segment.insert(db)
                inserted.append(segment)
            }
            return inserted
        }
    }

    /// All segments of a meeting, in `ord` order.
    public func segments(meetingID: MeetingID) async throws -> [TranscriptSegment] {
        try await database.pool.read { db in
            try TranscriptSegment
                .filter(Column("meeting_id") == meetingID)
                .order(Column("ord").asc)
                .fetchAll(db)
        }
    }

    /// Removes the transcript (segments + FTS) only — notes, meeting row and
    /// audio are untouched.
    public func deleteTranscript(meetingID: MeetingID) async throws {
        try await database.pool.write { db in
            try db.execute(sql: "DELETE FROM transcript_segment WHERE meeting_id = ?", arguments: [meetingID])
        }
    }

    /// Full-text search across all transcripts. Snippets delimit matches
    /// with `SearchHit.matchStartDelimiter`/`matchEndDelimiter`.
    public func search(_ query: String) async throws -> [SearchHit] {
        guard let pattern = FTS5Pattern(matchingAllTokensIn: query) else {
            return []
        }
        return try await database.pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT
                        s.meeting_id AS meeting_id,
                        s.id AS segment_id,
                        s.ord AS ord,
                        s.start_seconds AS start_seconds,
                        snippet(transcript_fts, 0, ?, ?, '…', 12) AS snippet
                    FROM transcript_fts
                    JOIN transcript_segment s ON s.id = transcript_fts.rowid
                    WHERE transcript_fts MATCH ?
                    ORDER BY bm25(transcript_fts)
                    """,
                arguments: [SearchHit.matchStartDelimiter, SearchHit.matchEndDelimiter, pattern.rawPattern]
            )
            return rows.map { row in
                SearchHit(
                    meetingID: row["meeting_id"],
                    segmentID: row["segment_id"],
                    ord: row["ord"],
                    startSeconds: row["start_seconds"],
                    snippet: row["snippet"]
                )
            }
        }
    }
}

// MARK: - NotesRepository

public struct NotesRepository: Sendable {
    let database: BlaiseDatabase

    public init(database: BlaiseDatabase) {
        self.database = database
    }

    public func upsert(_ notes: MeetingNotes) async throws {
        try await database.pool.write { db in
            try notes.upsert(db)
        }
    }

    public func fetch(meetingID: MeetingID) async throws -> MeetingNotes? {
        try await database.pool.read { db in
            try MeetingNotes.fetchOne(db, key: meetingID)
        }
    }

    /// Full-text search across all meeting NOTES (F2). Notes are one row per
    /// meeting, so a hit is a meeting (no segment). Uses the same all-tokens
    /// prefix matcher and snippet delimiters as transcript search, so query
    /// semantics and snippet rendering are identical across surfaces.
    /// `meeting_id` is stored as `notes_fts` column 0 (UNINDEXED) and read
    /// directly — no rowid join. Capped to bound a pathological query.
    public func searchNotes(_ query: String) async throws -> [NotesSearchHit] {
        guard let pattern = FTS5Pattern(matchingAllTokensIn: query) else {
            return []
        }
        return try await database.pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT
                        meeting_id AS meeting_id,
                        snippet(notes_fts, 1, ?, ?, '…', 12) AS snippet
                    FROM notes_fts
                    WHERE notes_fts MATCH ?
                    ORDER BY bm25(notes_fts), meeting_id
                    LIMIT 50
                    """,
                arguments: [SearchHit.matchStartDelimiter, SearchHit.matchEndDelimiter, pattern.rawPattern]
            )
            return rows.map { row in
                NotesSearchHit(meetingID: row["meeting_id"], snippet: row["snippet"])
            }
        }
    }
}

// MARK: - HandoffRepository

public struct HandoffRepository: Sendable {
    let database: BlaiseDatabase

    public init(database: BlaiseDatabase) {
        self.database = database
    }

    /// Enqueues a handoff for delivery. The payload file must already exist
    /// at `payloadPath` (relative to the data root) — the immutable writer
    /// writes it before enqueue. On `UNIQUE(meeting_id, version_hash)`
    /// conflict this is a no-op returning the existing item (idempotent
    /// enqueue, consistent with D4).
    @discardableResult
    public func enqueue(meetingID: MeetingID, versionHash: String, payloadPath: String) async throws -> HandoffItem {
        try database.requirePayloadFile(at: payloadPath)
        let rootURL = database.rootURL
        return try await database.pool.write { db in
            try Self.enqueue(db, rootURL: rootURL, meetingID: meetingID, versionHash: versionHash, payloadPath: payloadPath)
        }
    }

    /// Transaction-scoped enqueue, shared with `finalizeMeetingProcessing`.
    /// FIFO order is `created_seq`, assigned monotonically inside this
    /// transaction (durable, VACUUM-stable, clock-independent).
    static func enqueue(
        _ db: Database,
        rootURL: URL,
        meetingID: MeetingID,
        versionHash: String,
        payloadPath: String
    ) throws -> HandoffItem {
        guard FileManager.default.fileExists(atPath: rootURL.appendingPathComponent(payloadPath).path) else {
            throw BlaiseDatabaseError.missingPayloadFile(relativePath: payloadPath)
        }
        if let existing = try HandoffItem
            .filter(Column("meeting_id") == meetingID && Column("version_hash") == versionHash)
            .fetchOne(db)
        {
            return existing
        }
        let nextSeq = try Int64.fetchOne(db, sql: "SELECT IFNULL(MAX(created_seq), 0) + 1 FROM handoff_queue") ?? 1
        let item = HandoffItem(
            id: ULID.generate(),
            meetingID: meetingID,
            payloadPath: payloadPath,
            versionHash: versionHash,
            state: .pending,
            attempts: 0,
            createdSeq: nextSeq,
            createdAt: Date()
        )
        try item.insert(db)
        // Return the stored row, not the in-memory value: dates round-trip
        // through SQLite at millisecond precision, and callers must see the
        // same item a later fetch would return.
        guard let stored = try HandoffItem.fetchOne(db, key: item.id) else {
            throw BlaiseDatabaseError.handoffItemNotFound(item.id)
        }
        return stored
    }

    /// Oldest pending item by `created_seq` (FIFO), or nil.
    public func nextPending() async throws -> HandoffItem? {
        try await database.pool.read { db in
            try HandoffItem
                .filter(Column("state") == HandoffState.pending.rawValue)
                .order(Column("created_seq").asc)
                .fetchOne(db)
        }
    }

    /// SQL fragment selecting rows the C8 worker may deliver: `pending`,
    /// plus `failed` rows that are plain retriable bookkeeping (NOT under a
    /// reserved `last_error` prefix — `damaged:` quarantine and
    /// `superseded:` terminal closures are excluded).
    static let deliverableSQL = """
        (state = 'pending' OR (state = 'failed' AND (last_error IS NULL \
        OR (last_error NOT LIKE ? AND last_error NOT LIKE ?))))
        """
    static var reservedPrefixArguments: [String] {
        [HandoffErrorClass.damagedPrefix + "%", HandoffErrorClass.supersededPrefix + "%"]
    }

    /// Oldest deliverable item by `created_seq` (FIFO with damaged-skip).
    public func nextDeliverable() async throws -> HandoffItem? {
        try await database.pool.read { db in
            try HandoffItem
                .filter(sql: Self.deliverableSQL, arguments: StatementArguments(Self.reservedPrefixArguments))
                .order(Column("created_seq").asc)
                .fetchOne(db)
        }
    }

    /// Deliverable rows + the in-flight one — the snapshot's pendingCount.
    public func undeliveredCount() async throws -> Int {
        try await database.pool.read { db in
            try HandoffItem
                .filter(sql: "state = 'delivering' OR " + Self.deliverableSQL,
                        arguments: StatementArguments(Self.reservedPrefixArguments))
                .fetchCount(db)
        }
    }

    /// Every undelivered, non-`superseded:` row in `created_seq` order — the
    /// warning-threshold input. Damaged quarantine INCLUDED: a quarantined
    /// meeting is still waiting on the user, unlike `undeliveredCount`'s
    /// drain-progress view which reports damaged rows separately.
    public func undeliveredItems() async throws -> [HandoffItem] {
        try await database.pool.read { db in
            try HandoffItem
                .filter(sql: "state <> 'delivered' AND (last_error IS NULL OR last_error NOT LIKE ?)",
                        arguments: [HandoffErrorClass.supersededPrefix + "%"])
                .order(Column("created_seq").asc)
                .fetchAll(db)
        }
    }

    /// Every queue row in `created_seq` order (status surfaces, harnesses).
    public func allItems() async throws -> [HandoffItem] {
        try await database.pool.read { db in
            try HandoffItem.order(Column("created_seq").asc).fetchAll(db)
        }
    }

    /// Quarantined rows (`failed` + `damaged:` prefix), oldest first.
    public func damagedItems() async throws -> [HandoffItem] {
        try await database.pool.read { db in
            try HandoffItem
                .filter(sql: "state = 'failed' AND last_error LIKE ?",
                        arguments: [HandoffErrorClass.damagedPrefix + "%"])
                .order(Column("created_seq").asc)
                .fetchAll(db)
        }
    }

    /// C10 queue-panel "Retry All": re-enters `failed` rows as `pending`,
    /// INCLUDING one re-check of `damaged:` quarantined rows (the worker's
    /// pre-stream self-check re-quarantines any still bad) — but NEVER
    /// `superseded:` rows (terminal per D12, the C1/C8 prefix contract).
    /// Returns the re-entered count; the caller kicks the worker.
    @discardableResult
    public func retryAllFailed() async throws -> Int {
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    UPDATE handoff_queue SET state = 'pending'
                    WHERE state = 'failed' AND (last_error IS NULL OR last_error NOT LIKE ?)
                    """,
                arguments: [HandoffErrorClass.supersededPrefix + "%"])
            return db.changesCount
        }
    }

    /// C10 queue-panel per-item retry: same prefix semantics as
    /// `retryAllFailed`, scoped to one row. Returns false when the row is
    /// not retriable (not failed, or terminally `superseded:`).
    @discardableResult
    public func retryItem(_ id: HandoffID) async throws -> Bool {
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    UPDATE handoff_queue SET state = 'pending'
                    WHERE id = ? AND state = 'failed'
                      AND (last_error IS NULL OR last_error NOT LIKE ?)
                    """,
                arguments: [id, HandoffErrorClass.supersededPrefix + "%"])
            return db.changesCount > 0
        }
    }

    /// Relaunch re-check (C8 quarantine semantics): damaged rows go back to
    /// `pending` ONCE per launch; the pre-stream self-check re-quarantines
    /// any that are still bad. `last_error` is kept for traceability.
    @discardableResult
    public func requeueDamaged() async throws -> Int {
        try await database.pool.write { db in
            try db.execute(
                sql: "UPDATE handoff_queue SET state = 'pending' WHERE state = 'failed' AND last_error LIKE ?",
                arguments: [HandoffErrorClass.damagedPrefix + "%"])
            return db.changesCount
        }
    }

    /// D12 supersession sweep, run when a delivery succeeds: older
    /// undelivered rows for the same meeting are terminally closed as
    /// `failed` / `superseded:<newer hash>` — content-superseded, never
    /// silently lost (the meeting's CURRENT content was delivered).
    /// Returns the closed ids.
    public func supersedeOlder(meetingID: MeetingID, newerSeq: Int64, newerHash: String) async throws -> [HandoffID] {
        try await database.pool.write { db in
            try Self.supersedeOlder(db, meetingID: meetingID, newerSeq: newerSeq, newerHash: newerHash)
        }
    }

    /// Transaction-scoped sweep body, shared with `markDelivered`.
    static func supersedeOlder(
        _ db: Database, meetingID: MeetingID, newerSeq: Int64, newerHash: String
    ) throws -> [HandoffID] {
        let ids = try String.fetchAll(
            db,
            sql: """
                SELECT id FROM handoff_queue
                WHERE meeting_id = ? AND created_seq < ? AND state <> 'delivered'
                ORDER BY created_seq
                """,
            arguments: [meetingID, newerSeq])
        guard !ids.isEmpty else { return [] }
        try db.execute(
            sql: """
                UPDATE handoff_queue SET state = 'failed', last_error = ?
                WHERE meeting_id = ? AND created_seq < ? AND state <> 'delivered'
                """,
            arguments: [HandoffErrorClass.superseded(byNewerHash: newerHash), meetingID, newerSeq])
        return ids
    }

    /// `.delivered` transition + D12 supersession sweep in ONE write
    /// transaction (impl-audit M-1): no crash or cancellation window can
    /// leave an older undelivered row open behind a delivered newer one.
    public func markDelivered(_ id: HandoffID) async throws -> (item: HandoffItem, superseded: [HandoffID]) {
        try await database.pool.write { db in
            let item = try Self.transition(db, id: id, to: .delivered)
            let superseded = try Self.supersedeOlder(
                db, meetingID: item.meetingID, newerSeq: item.createdSeq, newerHash: item.versionHash)
            return (item, superseded)
        }
    }

    /// Launch catch-up for the D12 sweep (impl-audit M-1): terminally close
    /// any undelivered row whose meeting already has a DELIVERED row with a
    /// greater `created_seq` — state a historical crash window (pre-fix
    /// binary) could have left behind. Idempotent; returns the closed count.
    public func sweepSupersededAtLaunch() async throws -> Int {
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    UPDATE handoff_queue SET state = 'failed', last_error = ? || (
                        SELECT d.version_hash FROM handoff_queue d
                        WHERE d.meeting_id = handoff_queue.meeting_id AND d.state = 'delivered'
                          AND d.created_seq > handoff_queue.created_seq
                        ORDER BY d.created_seq DESC LIMIT 1)
                    WHERE state <> 'delivered'
                      AND (last_error IS NULL OR last_error NOT LIKE ?)
                      AND EXISTS (
                        SELECT 1 FROM handoff_queue d
                        WHERE d.meeting_id = handoff_queue.meeting_id AND d.state = 'delivered'
                          AND d.created_seq > handoff_queue.created_seq)
                    """,
                arguments: [
                    HandoffErrorClass.supersededPrefix,
                    HandoffErrorClass.supersededPrefix + "%",
                ])
            return db.changesCount
        }
    }

    /// State transition with attempt bookkeeping:
    /// - `.delivering`: increments `attempts`, stamps `lastAttemptAt`;
    /// - `.delivered`: stamps `deliveredAt` (the only terminal state — no transition leaves it);
    /// - `.failed`: records `lastError` (retriable bookkeeping — nothing is ever dropped).
    ///
    /// Returns the re-fetched stored row (same date precision as the DB, like `enqueue`).
    @discardableResult
    public func transition(_ id: HandoffID, to state: HandoffState, error: String? = nil) async throws -> HandoffItem {
        try await database.pool.write { db in
            try Self.transition(db, id: id, to: state, error: error)
        }
    }

    /// Transaction-scoped transition body, shared with `markDelivered`.
    static func transition(
        _ db: Database, id: HandoffID, to state: HandoffState, error: String? = nil
    ) throws -> HandoffItem {
        guard var item = try HandoffItem.fetchOne(db, key: id) else {
            throw BlaiseDatabaseError.handoffItemNotFound(id)
        }
        guard item.state != .delivered else {
            throw BlaiseDatabaseError.illegalHandoffTransition(from: .delivered, to: state)
        }
        item.state = state
        switch state {
        case .delivering:
            item.attempts += 1
            item.lastAttemptAt = Date()
        case .delivered:
            item.deliveredAt = Date()
        case .failed:
            item.lastError = error
        case .pending:
            break
        }
        try item.update(db)
        guard let stored = try HandoffItem.fetchOne(db, key: id) else {
            throw BlaiseDatabaseError.handoffItemNotFound(id)
        }
        return stored
    }
}

// MARK: - ActionItemStateRepository (V1.1, migration v7)

/// Stable key for an LLM-produced action item: SHA-256 hex of the
/// case/diacritic-folded, whitespace-collapsed item text. Items have no
/// durable ids (notes regeneration may rewrite them), so the key is derived
/// from content: an unchanged item keeps its done mark across regeneration;
/// a changed item loses it (documented limitation — the alternative,
/// fuzzy matching, risks marking the WRONG item done).
///
/// Chosen consequence (test-pinned): two DISTINCT items in ONE meeting
/// whose texts fold equal (case/diacritic/whitespace-only variants) share
/// the key and therefore share done state — they toggle together in the
/// detail box and the sidebar. Accepted: such near-duplicates are the same
/// item in practice, and any disambiguator (ordinal in the key) would make
/// done marks brittle against reordering regenerations.
public enum ActionItemKey {
    public static func key(for itemText: String) -> String {
        let folded = VocabNormalization.canonicalMode(itemText)
        let collapsed = folded
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return EvidencePayloadBuilder.sha256Hex(Data(collapsed.utf8))
    }
}

/// Done/archive state for user action items (`action_item_state`). LOCAL
/// ONLY: never read by the payload builder — a `ready` meeting's minted
/// payload stays re-materializable byte-equal.
public struct ActionItemStateRepository: Sendable {
    let database: BlaiseDatabase

    public init(database: BlaiseDatabase) {
        self.database = database
    }

    /// Marks the item done (idempotent; `done_at` keeps the FIRST mark).
    public func markDone(meetingID: MeetingID, itemText: String) async throws {
        let key = ActionItemKey.key(for: itemText)
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO action_item_state (meeting_id, item_key, done_at)
                    VALUES (?, ?, ?)
                    """,
                arguments: [meetingID, key, Date()])
        }
    }

    /// Un-marks the item (no-op when not marked).
    public func clearDone(meetingID: MeetingID, itemText: String) async throws {
        let key = ActionItemKey.key(for: itemText)
        try await database.pool.write { db in
            try db.execute(
                sql: "DELETE FROM action_item_state WHERE meeting_id = ? AND item_key = ?",
                arguments: [meetingID, key])
        }
    }

    public func doneKeys(meetingID: MeetingID) async throws -> Set<String> {
        try await database.pool.read { db in
            try Set(String.fetchAll(
                db, sql: "SELECT item_key FROM action_item_state WHERE meeting_id = ?",
                arguments: [meetingID]))
        }
    }
}

// MARK: - SettingsStore

/// Typed key/value settings backed by `app_setting` (JSON values).
public struct SettingsStore: Sendable {
    let database: BlaiseDatabase

    public init(database: BlaiseDatabase) {
        self.database = database
    }

    public func get<T: Codable & Sendable>(_ key: String, as type: T.Type = T.self) async throws -> T? {
        try await database.pool.read { db in
            guard let json = try String.fetchOne(db, sql: "SELECT value FROM app_setting WHERE key = ?", arguments: [key]) else {
                return nil
            }
            return try JSONDecoder().decode(T.self, from: Data(json.utf8))
        }
    }

    public func set<T: Codable & Sendable>(_ key: String, to value: T) async throws {
        let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        try await database.pool.write { db in
            try db.execute(
                sql: "INSERT INTO app_setting (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: [key, json]
            )
        }
    }
}

// MARK: - F1 processing queue repository

/// Durable processing-queue (F1). Mirrors `HandoffRepository`. The worker drains
/// it by calling the unchanged `ProcessingPipeline.dispatchProcessing`; this
/// repository owns enqueue/claim/complete + the startup sweep. `complete`/`fail`
/// are UPDATE…WHERE-id, so a row deleted mid-run (meeting deletion) is a safe
/// no-op (H-2).
public struct ProcessingQueueRepository: Sendable {
    let database: BlaiseDatabase

    public init(database: BlaiseDatabase) {
        self.database = database
    }

    /// Enqueue a process job for a meeting. Idempotent (F1 §5): if a live
    /// (pending/running) job already exists for the meeting, return it —
    /// SELECT-then-INSERT under the write lock; the partial unique index is the
    /// belt-and-suspenders backstop against logic bugs.
    @discardableResult
    public func enqueue(meetingID: MeetingID, origin: ProcessingJobOrigin) async throws -> ProcessingJob {
        try await database.pool.write { db in
            try Self.enqueue(db, meetingID: meetingID, origin: origin)
        }
    }

    /// Transaction-scoped enqueue (FIFO `created_seq` assigned monotonically).
    static func enqueue(_ db: Database, meetingID: MeetingID, origin: ProcessingJobOrigin) throws -> ProcessingJob {
        if let existing = try ProcessingJob
            .filter(Column("meeting_id") == meetingID)
            .filter(sql: "state IN ('pending','running')")
            .fetchOne(db)
        {
            // H-promote: a USER admission collapsing into an existing AUTO/
            // reprocess_all PENDING job promotes the job's origin, so the worker
            // runs it with refuseCancelled=false — otherwise the user's
            // Process/Regenerate of a CANCELLED meeting would silently collapse
            // into an auto job and be refused. (A running job already captured
            // its origin, so only pending is promotable.)
            if origin == .user, existing.origin != .user, existing.state == .pending {
                try db.execute(
                    sql: "UPDATE processing_queue SET origin = ? WHERE id = ?",
                    arguments: [ProcessingJobOrigin.user.rawValue, existing.id])
                return try ProcessingJob.fetchOne(db, key: existing.id) ?? existing
            }
            return existing
        }
        let nextSeq = try Int64.fetchOne(
            db, sql: "SELECT IFNULL(MAX(created_seq), 0) + 1 FROM processing_queue") ?? 1
        let job = ProcessingJob(
            id: ULID.generate(),
            meetingID: meetingID,
            state: .pending,
            origin: origin,
            attempts: 0,
            createdSeq: nextSeq,
            enqueuedAt: Date())
        try job.insert(db)
        guard let stored = try ProcessingJob.fetchOne(db, key: job.id) else {
            throw BlaiseDatabaseError.processingJobNotFound(job.id)
        }
        return stored
    }

    /// Claim the oldest `pending` job (FIFO by `created_seq` ONLY — L-4), marking
    /// it `running`. Returns nil if none; the worker drains one at a time.
    public func claimNext() async throws -> ProcessingJob? {
        try await database.pool.write { db in
            guard let job = try ProcessingJob
                .filter(Column("state") == ProcessingJobState.pending.rawValue)
                .order(Column("created_seq").asc)
                .fetchOne(db)
            else { return nil }
            try db.execute(
                sql: "UPDATE processing_queue SET state = 'running', started_at = ? WHERE id = ?",
                arguments: [Date(), job.id])
            return try ProcessingJob.fetchOne(db, key: job.id)
        }
    }

    /// Mark a job `done`. No-op if the row was deleted mid-run (H-2).
    public func complete(_ id: String) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: "UPDATE processing_queue SET state = 'done', finished_at = ? WHERE id = ?",
                arguments: [Date(), id])
        }
    }

    /// Mark a job `failed` + bump `attempts`. No-op if the row was deleted (H-2).
    public func fail(_ id: String, error: String) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: "UPDATE processing_queue SET state = 'failed', last_error = ?, "
                    + "attempts = attempts + 1, finished_at = ? WHERE id = ?",
                arguments: [error, Date(), id])
        }
    }

    /// Oldest `pending` job (FIFO peek), or nil.
    public func nextPending() async throws -> ProcessingJob? {
        try await database.pool.read { db in
            try ProcessingJob
                .filter(Column("state") == ProcessingJobState.pending.rawValue)
                .order(Column("created_seq").asc)
                .fetchOne(db)
        }
    }

    /// Count of live (pending or running) jobs.
    public func liveCount() async throws -> Int {
        try await database.pool.read { db in
            try ProcessingJob.filter(sql: "state IN ('pending','running')").fetchCount(db)
        }
    }

    /// Startup sweep: a stale `running` row is an interrupted claim → reset to
    /// `pending` (twin of the handoff `delivering→pending` sweep).
    public func resetStaleRunning() async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: "UPDATE processing_queue SET state = 'pending', started_at = NULL WHERE state = 'running'")
        }
    }

    /// Mark a job `cancelled` (the worker's drain after the user cancelled the
    /// in-flight run — `pipeline.cancel` → typed `EngineError.cancelled`). A
    /// cancelled job is terminal and offers no Retry. No-op if the row is gone.
    public func markCancelled(_ id: String) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: "UPDATE processing_queue SET state = 'cancelled', finished_at = ? WHERE id = ?",
                arguments: [Date(), id])
        }
    }

    // MARK: - Increment 2 (UI / cancel / snapshot)

    /// CAS-cancel a PENDING job (C2): flips `pending → cancelled` only. Returns
    /// true iff a pending row was cancelled; false means the caller must reload
    /// (a job claimed `running` between the UI read and here must NOT be stomped
    /// — the caller routes a running job to `pipeline.cancel` instead).
    @discardableResult
    public func cancelPending(_ id: String) async throws -> Bool {
        try await database.pool.write { db in
            try db.execute(
                sql: "UPDATE processing_queue SET state = 'cancelled', finished_at = ? "
                    + "WHERE id = ? AND state = 'pending'",
                arguments: [Date(), id])
            return db.changesCount > 0
        }
    }

    /// Retry a `failed` job → `pending` (manual retry — D3). CAS-guarded to
    /// `failed` (clears the error; `attempts` is preserved as history).
    public func retry(_ id: String) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: "UPDATE processing_queue SET state = 'pending', last_error = NULL, "
                    + "started_at = NULL, finished_at = NULL WHERE id = ? AND state = 'failed'",
                arguments: [id])
        }
    }

    /// Retry ALL `failed` jobs → `pending`.
    public func retryAllFailed() async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: "UPDATE processing_queue SET state = 'pending', last_error = NULL, "
                    + "started_at = NULL, finished_at = NULL WHERE state = 'failed'")
        }
    }

    /// Fetch a job by id (the cancel-routing reload after a CAS no-op).
    public func job(_ id: String) async throws -> ProcessingJob? {
        try await database.pool.read { db in
            try ProcessingJob.fetchOne(db, key: id)
        }
    }

    /// The live (`pending`/`running`) job for a meeting, or nil — the detail view
    /// gates its busy/Cancel UI on this (AC1b).
    public func liveJob(meetingID: MeetingID) async throws -> ProcessingJob? {
        try await database.pool.read { db in
            try ProcessingJob
                .filter(Column("meeting_id") == meetingID)
                .filter(sql: "state IN ('pending','running')")
                .fetchOne(db)
        }
    }

    /// All jobs, newest first (the panel list).
    public func allJobs() async throws -> [ProcessingJob] {
        try await database.pool.read { db in
            try ProcessingJob.order(Column("created_seq").desc).fetchAll(db)
        }
    }

    /// Failed (retriable) jobs, oldest first.
    public func failedJobs() async throws -> [ProcessingJob] {
        try await database.pool.read { db in
            try ProcessingJob
                .filter(Column("state") == ProcessingJobState.failed.rawValue)
                .order(Column("created_seq").asc)
                .fetchAll(db)
        }
    }

    /// The currently-running job (≤1 — the worker is sequential), or nil.
    public func runningJob() async throws -> ProcessingJob? {
        try await database.pool.read { db in
            try ProcessingJob
                .filter(Column("state") == ProcessingJobState.running.rawValue)
                .fetchOne(db)
        }
    }

    /// Counts for the snapshot in one read.
    public func counts() async throws -> (pending: Int, failed: Int, runningMeetingID: MeetingID?) {
        try await database.pool.read { db in
            let pending = try ProcessingJob
                .filter(Column("state") == ProcessingJobState.pending.rawValue).fetchCount(db)
            let failed = try ProcessingJob
                .filter(Column("state") == ProcessingJobState.failed.rawValue).fetchCount(db)
            let running = try ProcessingJob
                .filter(Column("state") == ProcessingJobState.running.rawValue).fetchOne(db)
            return (pending, failed, running?.meetingID)
        }
    }
}
