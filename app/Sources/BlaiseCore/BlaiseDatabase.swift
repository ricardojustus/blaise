import Foundation
import GRDB

public enum BlaiseDatabaseError: Error, Equatable {
    case meetingNotFound(MeetingID)
    case handoffItemNotFound(HandoffID)
    case processingJobNotFound(String)
    /// `enqueue` requires the payload file already on disk (relative path under the data root).
    case missingPayloadFile(relativePath: String)
    /// `delivered` is terminal: no transition may leave it (impl audit F3).
    case illegalHandoffTransition(from: HandoffState, to: HandoffState)
}

/// Wraps a GRDB `DatabasePool` (WAL) at `<root>/blaise.sqlite`.
///
/// Durability bar: WAL with `synchronous=NORMAL` (GRDB default) —
/// crash-consistent (app crash/kill -9 loses nothing committed); on full
/// power loss the most recent commits may roll back but the DB never
/// corrupts. Retained audio + deterministic reprocessing regenerate any lost
/// derived state.
public final class BlaiseDatabase: Sendable {
    public static let databaseFileName = "blaise.sqlite"

    /// The Blaise data root (database file, per-meeting directories).
    public let rootURL: URL
    public let pool: DatabasePool
    public let paths: MeetingPaths

    /// `<appSupport>/Blaise` — the production data root.
    public static func defaultRootURL() throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Blaise", isDirectory: true)
    }

    /// Opens (creating/migrating as needed) the database under `rootURL`,
    /// then runs the startup sweeps.
    public init(rootURL: URL) throws {
        self.rootURL = rootURL
        self.paths = MeetingPaths(rootURL: rootURL)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        self.pool = try DatabasePool(path: rootURL.appendingPathComponent(Self.databaseFileName).path)
        try Self.migrator.migrate(pool)
        try runStartupSweeps()
    }

    // MARK: - Schema

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "meeting") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("started_at", .datetime).notNull().indexed()
                t.column("ended_at", .datetime)
                t.column("source", .text).notNull()
                    .check { MeetingSource.allCases.map(\.rawValue).contains($0) }
                // Deliberately NO CHECK on status: that vocabulary is the one
                // most likely to evolve (SQLite CHECK changes force a table
                // rebuild); the Swift enum enforces validity at the boundary.
                t.column("status", .text).notNull().indexed()
                t.column("attendees", .text).notNull() // JSON
                t.column("dominant_language", .text)
                t.column("asr_provenance", .text) // JSON
                t.column("last_processing_error", .text)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }

            try db.create(table: "transcript_segment") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("meeting_id", .text).notNull()
                    .references("meeting", onDelete: .cascade)
                t.column("ord", .integer).notNull()
                t.column("start_seconds", .double).notNull()
                t.column("end_seconds", .double).notNull()
                t.column("speaker_label", .text).notNull()
                t.column("speaker_name", .text)
                t.column("text", .text).notNull()
                t.uniqueKey(["meeting_id", "ord"])
            }

            // External-content FTS5 on transcript_segment(text), kept in sync
            // by GRDB's synchronization triggers (decision D8).
            try db.create(virtualTable: "transcript_fts", using: FTS5()) { t in
                t.synchronize(withTable: "transcript_segment")
                t.tokenizer = .unicode61(diacritics: .remove) // remove_diacritics 2
                t.column("text")
            }

            try db.create(table: "meeting_notes") { t in
                t.primaryKey("meeting_id", .text)
                    .references("meeting", onDelete: .cascade)
                t.column("markdown", .text).notNull()
                t.column("language", .text).notNull()
                t.column("generated_at", .datetime).notNull()
                t.column("provenance", .text).notNull() // JSON
            }

            try db.create(table: "handoff_queue") { t in
                t.primaryKey("id", .text)
                // RESTRICT, not CASCADE: V1 has no meeting deletion at all;
                // if it ever arrives, undelivered rows must block it.
                t.column("meeting_id", .text).notNull()
                    .references("meeting", onDelete: .restrict)
                t.column("payload_path", .text).notNull()
                t.column("version_hash", .text).notNull()
                // CHECK here is deliberate asymmetry with meeting.status:
                // this 4-value set is stable and hard-floor-bearing.
                t.column("state", .text).notNull()
                    .check { HandoffState.allCases.map(\.rawValue).contains($0) }
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("created_at", .datetime).notNull()
                t.column("last_attempt_at", .datetime)
                t.column("delivered_at", .datetime)
                t.column("last_error", .text)
                t.column("created_seq", .integer).notNull().unique()
                t.uniqueKey(["meeting_id", "version_hash"])
            }
            try db.create(indexOn: "handoff_queue", columns: ["state", "created_seq"])

            try db.create(table: "app_setting") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull() // JSON
            }
        }
        // C2: persisted structured notes (the single source of truth for
        // notes content; markdown is rendered from it). NOT NULL without
        // DEFAULT is valid because the table is provably empty at migration
        // time in every deployment that can exist (the first notes-writer,
        // C7, ships after v2) — SQLite allows ADD COLUMN NOT NULL sans
        // DEFAULT only on empty tables (verified on system SQLite 3.51); a
        // populated v1 fails this migration loudly, by design.
        migrator.registerMigration("v2") { db in
            try db.alter(table: "meeting_notes") { t in
                t.add(column: "structured", .text).notNull() // JSON NotesStructured
            }
        }
        // C6 (additive): B-2 cloud-spend ledger + the runtime-fallback note.
        // `processing_note` is distinct from `last_processing_error`
        // (failures-only); it carries non-failure notes such as
        // "fallback: input too long", cleared at the start of every run (C7).
        migrator.registerMigration("v3") { db in
            try db.create(table: "cloud_spend") { t in
                t.primaryKey("month_key", .text) // "YYYY-MM" in the system time zone
                t.column("accumulated_usd", .double).notNull()
            }
            try db.alter(table: "meeting") { t in
                t.add(column: "processing_note", .text)
            }
        }
        // C10 (additive; C1 changelog amended): the meet-events listener's
        // durable state. `meeting.meeting_code` is the C12 batch→meeting
        // correlation key; `meet_events_pending` holds unmatched batches
        // (purged > 7 d; pre-match replay dedupe = UNIQUE(batch_digest));
        // `meet_seen_event_id` is the authoritative POST-match replay guard
        // (event_id = the contract dedupe id, computed from PRE-substitution
        // wire fields); `meeting_speaker_event` is THE durable home C7's
        // stage 8 reads (SpeakerHints.activeSpeakerEvents).
        migrator.registerMigration("v4") { db in
            try db.alter(table: "meeting") { t in
                t.add(column: "meeting_code", .text)
            }
            try db.create(table: "meet_events_pending") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("meeting_code", .text).notNull().indexed()
                t.column("batch_json", .text).notNull()
                // SHA-256 hex of the decrypted batch plaintext: a replayed
                // unmatched batch stores once (the spec's pre-match dedupe).
                t.column("batch_digest", .text).notNull().unique()
                t.column("captured_at_ms", .integer).notNull()
                t.column("received_at", .datetime).notNull()
            }
            try db.create(table: "meet_seen_event_id") { t in
                t.column("meeting_id", .text).notNull()
                t.column("event_id", .text).notNull()
                t.primaryKey(["meeting_id", "event_id"])
            }
            try db.create(table: "meeting_speaker_event") { t in
                t.column("meeting_id", .text).notNull()
                    .references("meeting", onDelete: .cascade)
                // Contract formula over PRE-substitution wire fields —
                // identity renames can never break replay protection.
                t.column("dedupe_id", .text).notNull()
                // Post-substitution (isSelf → UserIdentity.name).
                t.column("display_name", .text).notNull()
                t.column("participant_id", .text)
                t.column("is_self", .boolean).notNull()
                t.column("start_epoch_ms", .integer).notNull()
                t.column("end_epoch_ms", .integer).notNull()
                t.uniqueKey(["meeting_id", "dedupe_id"])
            }
        }
        // C10 impl-audit H-1 (additive; C1 changelog amended v6.7): ingestion
        // NEVER mutates the meeting row (attendees and updated_at are payload-
        // builder inputs; a post-mint mutation would break C8's
        // re-materialization recovery). Roster names from matched batches
        // queue here; the NEXT content run absorbs them into
        // `Meeting.attendees` inside its entry transaction — the sanctioned
        // content-mutation point — and clears the rows.
        migrator.registerMigration("v5") { db in
            try db.create(table: "meet_roster_pending") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("meeting_id", .text).notNull()
                    .references("meeting", onDelete: .cascade)
                t.column("display_name", .text).notNull()
                // Folded (VocabNormalization.canonicalMode) for the dedupe key.
                t.column("display_name_folded", .text).notNull()
                t.column("participant_id", .text)
                // Always false today (normalize() drops self identities before
                // storage); the absorption filter is belt-and-braces.
                t.column("is_self", .boolean).notNull()
                t.uniqueKey(["meeting_id", "display_name_folded"])
            }
        }
        // C11: durable captured-meeting marker (set at capture start) — the
        // two-track processing dispatch must not depend on file presence
        // alone (a mic-failed captured meeting still runs the captured
        // variant with the isSelf voting exclusion).
        migrator.registerMigration("v6") { db in
            try db.alter(table: "meeting") { t in
                t.add(column: "captured", .boolean).notNull().defaults(to: false)
            }
        }
        // V1.1: per-item done/archive state for user action items — LOCAL
        // ONLY (never a payload-builder input: re-materialization byte-
        // equality must hold, so the evidence payload gains no fields).
        // `item_key` = SHA-256 hex of the normalized item text
        // (ActionItemKey): items are LLM output without stable ids, so the
        // key survives regeneration when the text is unchanged; a
        // regenerated item whose text CHANGED simply loses its done mark
        // (documented, honest).
        migrator.registerMigration("v7") { db in
            try db.create(table: "action_item_state") { t in
                t.column("meeting_id", .text).notNull()
                    .references("meeting", onDelete: .cascade)
                t.column("item_key", .text).notNull()
                t.column("done_at", .datetime).notNull()
                t.primaryKey(["meeting_id", "item_key"])
            }
        }
        // C14 (additive; C1 changelog amended): per-part capture metadata for
        // the resume grace window. The controller inserts a row at each part
        // start and closes it at stop; rows are the stitcher's gap source.
        // A row left open by a crash is closed at stitch time as
        // `started + decoded part duration`; meetings with NO rows (every
        // pre-v8 meeting) are single-part — derived, not migrated. The
        // empty-part rule deletes a row ONLY when every file of its part is
        // provably gone (zero-frame CAFs removed, no part m4a on disk).
        migrator.registerMigration("v8") { db in
            try db.create(table: "meeting_capture_part") { t in
                t.column("meeting_id", .text).notNull()
                    .references("meeting", onDelete: .cascade)
                t.column("part_index", .integer).notNull()
                t.column("started_at_ms", .integer).notNull()
                t.column("ended_at_ms", .integer)
                t.primaryKey(["meeting_id", "part_index"])
            }
        }
        // G7 (additive): per-call cloud-spend receipts — the line-by-line
        // explanation of the `cloud_spend` month accumulator (BACKLOG 11/06:
        // "$2.07 with 6 meetings" needed manual reconstruction). The
        // accumulator STAYS the ceiling-enforcement source of truth; receipts
        // never gate a call. `purpose` is CHECK-constrained (a stable 4-value
        // set). `meeting_id` is NULLABLE with ON DELETE SET NULL: a receipt
        // outlives its meeting (the bill is real even after the meeting is
        // gone). Receipts are local bookkeeping — never a payload-builder
        // input, so the C8 re-materialization byte-equality is untouched.
        migrator.registerMigration("v9") { db in
            try db.create(table: "cloud_spend_receipt") { t in
                t.primaryKey("id", .text) // ULID
                t.column("timestamp", .datetime).notNull()
                t.column("month_key", .text).notNull().indexed() // "YYYY-MM" (SP)
                t.column("engine_id", .text).notNull()
                t.column("model", .text).notNull()
                t.column("purpose", .text).notNull()
                    .check { CloudSpendPurpose.allCases.map(\.rawValue).contains($0) }
                t.column("meeting_id", .text)
                    .references("meeting", onDelete: .setNull)
                t.column("input_tokens", .integer).notNull()
                t.column("output_tokens", .integer).notNull()
                t.column("cost_usd", .double).notNull()
                t.column("note", .text)
            }
        }
        // G2 (additive): the durable name-correction store (§2) and the
        // durable speaker-rename table (§4).
        //
        // `name_correction` — one folded misheard key → one replacement, with
        // the everyday flag computed AT WRITE TIME (G1 everyday membership of
        // the folded key) governing WHERE the row applies (§3 rule 1). No
        // scope column: the everyday flag IS the scope. `misheard_folded` is
        // UNIQUE — one row per folded key; re-teaching an existing key updates
        // it. `source_meeting_id` is NULLABLE with ON DELETE SET NULL (the
        // correction outlives the meeting that seeded it).
        //
        // `speaker_rename` — one user rename per (meeting_id, speaker_label).
        // `anchor_ms` is the MIDPOINT of the cluster's longest segment at
        // write time (an interior instant, robust to boundary jitter — §4).
        // `stale` (the R4-H1 lifecycle column) marks a row the fresh-diarize
        // fallback could not safely re-map; a stale row is NOT applied and
        // renders the label unnamed with a re-confirmation prompt until the
        // user re-confirms.
        migrator.registerMigration("v10") { db in
            try db.create(table: "name_correction") { t in
                t.primaryKey("id", .text) // ULID
                t.column("misheard_folded", .text).notNull().unique()
                t.column("replacement", .text).notNull()
                t.column("everyday", .boolean).notNull()
                t.column("source_meeting_id", .text)
                    .references("meeting", onDelete: .setNull)
                t.column("created_at", .datetime).notNull()
            }
            try db.create(table: "speaker_rename") { t in
                t.column("meeting_id", .text).notNull()
                    .references("meeting", onDelete: .cascade)
                t.column("speaker_label", .text).notNull()
                t.column("anchor_ms", .integer).notNull()
                t.column("stale", .boolean).notNull().defaults(to: false)
                t.column("name", .text).notNull()
                t.column("created_at", .datetime).notNull()
                t.primaryKey(["meeting_id", "speaker_label"])
            }
        }
        // G10 (additive): the deletion tombstone — the DURABLE owner-intent
        // record that authorizes file removal (floor 2 as refined by D23: the
        // SYSTEM never deletes autonomously; row-absence proves nothing — a
        // recreated blaise.sqlite makes every dir row-less, and that scenario
        // must preserve everything). A delete writes the tombstone in the SAME
        // transaction that erases the meeting's rows; the launch tombstone
        // sweep removes EXACTLY the tombstoned dirs (path-specific, durable)
        // and then their tombstones. No FK to `meeting` — the tombstone
        // OUTLIVES the row it records (the whole point is that the row is gone
        // while the dir removal is still owed).
        migrator.registerMigration("v11") { db in
            try db.create(table: "meeting_tombstone") { t in
                t.primaryKey("id", .text) // the deleted meeting's id (ULID)
                t.column("audio_dir_path", .text).notNull()
                t.column("deleted_at", .datetime).notNull()
            }
        }
        // G11 (additive): the calendar anchor + durable resume-grace window.
        // `calendar_event_id`/`scheduled_end_ms` are written ONCE at meeting
        // start when the start was suggestion-matched (§1; both NULL = ad-hoc).
        // The classifier (§2) reads `scheduled_end_ms` to decide whether a
        // debounce-fired end skips grace. `grace_until_ms` is the durable
        // grace deadline (§3): written before the in-memory timer is armed,
        // cleared at every grace exit, and read at launch by the interrupted-
        // flip exemption so a relaunch mid-grace re-enters grace rather than
        // stranding the meeting. All three are payload-irrelevant (internal;
        // the V1 evidence payload omits calendar_event), so C8's
        // re-materialization byte-equality is untouched.
        migrator.registerMigration("v12") { db in
            try db.alter(table: "meeting") { t in
                t.add(column: "calendar_event_id", .text)
                t.add(column: "scheduled_end_ms", .integer)
                t.add(column: "grace_until_ms", .integer)
            }
        }
        // G12 (additive): the title-precedence provenance. Existing rows carry
        // the date-default title minted at start, so the backfilled default
        // value `'default'` is correct — the LLM/calendar promotions only ever
        // claim a row whose source is still `default`.
        migrator.registerMigration("v13") { db in
            try db.alter(table: "meeting") { t in
                t.add(column: "title_source", .text).notNull().defaults(to: "default")
            }
        }

        // G14 (additive): two statements at one ordered slot.
        //
        // (1) `meeting_notes.memory_digest` — the persisted machine-facing
        //     digest string (the single source of truth for re-materialization,
        //     §3 store-once / re-materialize-stored invariant). Nullable: a
        //     toggle-off, a legacy (pre-G14), or a digest-pending meeting has no
        //     digest, so the payload omits `memory_digest` (absent ⇒ skip to
        //     the knowledge graph). HandoffWorker re-materialization reproduces the STORED
        //     bytes; a null column re-materializes byte-identically with no
        //     `memory_digest` field (Floor 8).
        //
        // (2) `cloud_spend_receipt` CHECK rebuild — migration v9 baked
        //     `CHECK(purpose IN (…))` with the rawValues present WHEN v9 RAN
        //     (generation/regeneration/validation/smoke). SQLite never updates a
        //     column CHECK when a new enum case is added later, and `digest` was
        //     NOT pre-provisioned the way `smoke` was, so a `digest`-purpose
        //     INSERT would fail the frozen v9 CHECK on any migrated DB. SQLite
        //     cannot ALTER…DROP/ADD CONSTRAINT, so this is the standard table
        //     rebuild: create the table anew with the widened CHECK derived from
        //     `CloudSpendPurpose.allCases` (which now includes `digest`), copy
        //     rows, drop the old table, rename. A fresh DB at v9 already gets the
        //     wide CHECK from `allCases`; this rebuild fixes the MIGRATED path.
        migrator.registerMigration("v14") { db in
            try db.alter(table: "meeting_notes") { t in
                t.add(column: "memory_digest", .text) // nullable; Markdown string
            }

            try db.create(table: "cloud_spend_receipt_new") { t in
                t.primaryKey("id", .text)
                t.column("timestamp", .datetime).notNull()
                t.column("month_key", .text).notNull().indexed()
                t.column("engine_id", .text).notNull()
                t.column("model", .text).notNull()
                t.column("purpose", .text).notNull()
                    .check { CloudSpendPurpose.allCases.map(\.rawValue).contains($0) }
                t.column("meeting_id", .text)
                    .references("meeting", onDelete: .setNull)
                t.column("input_tokens", .integer).notNull()
                t.column("output_tokens", .integer).notNull()
                t.column("cost_usd", .double).notNull()
                t.column("note", .text)
            }
            try db.execute(sql: """
                INSERT INTO cloud_spend_receipt_new
                  (id, timestamp, month_key, engine_id, model, purpose, meeting_id,
                   input_tokens, output_tokens, cost_usd, note)
                SELECT
                  id, timestamp, month_key, engine_id, model, purpose, meeting_id,
                  input_tokens, output_tokens, cost_usd, note
                FROM cloud_spend_receipt
                """)
            try db.drop(table: "cloud_spend_receipt")
            try db.rename(table: "cloud_spend_receipt_new", to: "cloud_spend_receipt")
        }

        // F1: the durable processing-queue substrate (additive; the pipeline
        // body is unchanged). Mirrors handoff_queue. `created_seq` is the
        // VACUUM-stable, clock-independent FIFO key; the partial unique index
        // (raw SQL — no GRDB `create(indexOn:)` precedent for a WHERE clause) is
        // the dedup constraint: at most one live job per meeting.
        migrator.registerMigration("v15") { db in
            try db.create(table: "processing_queue") { t in
                t.primaryKey("id", .text)
                t.column("meeting_id", .text).notNull()
                    .references("meeting", onDelete: .cascade)
                t.column("state", .text).notNull()
                    .check { ProcessingJobState.allCases.map(\.rawValue).contains($0) }
                t.column("origin", .text).notNull()
                    .check { ProcessingJobOrigin.allCases.map(\.rawValue).contains($0) }
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("enqueued_at", .datetime).notNull()
                t.column("started_at", .datetime)
                t.column("finished_at", .datetime)
                t.column("last_error", .text)
                t.column("created_seq", .integer).notNull().unique()
            }
            try db.create(indexOn: "processing_queue", columns: ["state", "created_seq"])
            try db.execute(
                sql: "CREATE UNIQUE INDEX uniq_processing_live ON processing_queue(meeting_id) "
                    + "WHERE state IN ('pending','running')")
        }

        // F2: full-text search over NOTES. A STANDALONE FTS5 table — NOT
        // external-content. `transcript_fts` can be external-content because
        // `transcript_segment` has an INTEGER-PK rowid alias (VACUUM-stable);
        // `meeting_notes` has a TEXT primary key, so its hidden rowid is not
        // VACUUM-stable, and the codebase prefers VACUUM-stable keys. So
        // `notes_fts` stores `meeting_id` as a real column and is kept in sync
        // by meeting_id-keyed triggers — search returns the meeting id directly,
        // no rowid join. The triggers live in the schema, so the sacred finalize
        // path (`MeetingNotes.upsert`) is untouched. The AFTER UPDATE trigger is
        // the HOT path: note regeneration is a GRDB upsert
        // (INSERT…ON CONFLICT DO UPDATE = a SQLite UPDATE), so without it a
        // regenerated note would keep stale indexed text. It is unqualified (not
        // `OF markdown`) and delete-then-insert (idempotent, self-healing). Raw
        // SQL because GRDB's `t.synchronize` IS the external-content mechanism we
        // are deliberately avoiding. Indexes the rendered `markdown` (NOT NULL).
        migrator.registerMigration("v16") { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE notes_fts USING fts5(
                    meeting_id UNINDEXED,
                    content,
                    tokenize = "unicode61 remove_diacritics 2"
                )
                """)
            try db.execute(sql: """
                CREATE TRIGGER notes_fts_ai AFTER INSERT ON meeting_notes BEGIN
                    INSERT INTO notes_fts(meeting_id, content) VALUES (new.meeting_id, new.markdown);
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER notes_fts_ad AFTER DELETE ON meeting_notes BEGIN
                    DELETE FROM notes_fts WHERE meeting_id = old.meeting_id;
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER notes_fts_au AFTER UPDATE ON meeting_notes BEGIN
                    DELETE FROM notes_fts WHERE meeting_id = old.meeting_id;
                    INSERT INTO notes_fts(meeting_id, content) VALUES (new.meeting_id, new.markdown);
                END
                """)
            // Backfill notes that already exist at migration time. This INSERTs
            // into notes_fts (not meeting_notes), so it does NOT fire the
            // triggers above — no double-indexing.
            try db.execute(
                sql: "INSERT INTO notes_fts(meeting_id, content) SELECT meeting_id, markdown FROM meeting_notes")
        }

        // T3.1 (md-v3) AC2: the FIRST-run scoped alias bindings persisted with
        // the meeting so the bare digest-resume path (`digestOnlyBody`) — which
        // reloads only the corrected transcript and CANNOT reconstruct the
        // `AppliedCorrection` records — scopes IDENTICALLY to the first run.
        // Additive, nullable JSON column (the `memory_digest`/v14 precedent): a
        // pre-md-v3 row's NULL decodes to an empty set and re-materializes the
        // payload byte-identically (the column is NOT a payload input). No FTS
        // impact — the AFTER UPDATE trigger re-indexes `markdown` only.
        migrator.registerMigration("v17") { db in
            try db.alter(table: "meeting_notes") { t in
                t.add(column: "scoped_alias_bindings", .text) // nullable; JSON [AliasPair]
            }
        }

        // G17 (additive): span-anchored user corrections and margin notes on
        // a finished meeting. Durable rows survive every re-run (synthesis
        // re-reads them); anchoring is quote + section + occurrence. Payload
        // impact is presence-gated (a meeting with no rows emits no new keys),
        // so C8 re-materialization byte-equality is untouched.
        migrator.registerMigration("v18") { db in
            try db.create(table: "meeting_correction") { t in
                t.primaryKey("id", .text) // ULID
                t.column("meeting_id", .text).notNull()
                    .references("meeting", onDelete: .cascade)
                t.column("kind", .text).notNull() // 'understanding' | 'annotation'
                t.column("section", .text).notNull()
                t.column("quoted_text", .text).notNull()
                t.column("occurrence", .integer).notNull().defaults(to: 0)
                t.column("user_text", .text).notNull()
                t.column("status", .text).notNull().defaults(to: "pending")
                t.column("created_at", .datetime).notNull()
                t.column("applied_at", .datetime)
            }
            // The mint-time snapshot of the rows that shaped a notes artifact
            // (the payload's hash-stable re-materialization source; live rows
            // are user-mutable). Nullable JSON, the v17 precedent. No FTS
            // impact — the triggers re-index `markdown` only.
            try db.alter(table: "meeting_notes") { t in
                t.add(column: "user_corrections", .text) // nullable; JSON [NotesCorrectionSnapshot]
            }
        }
        return migrator
    }

    // MARK: - Startup sweeps

    /// At DB open (single process — no live run can exist at startup):
    /// - stale `delivering` handoff rows are by definition an interrupted
    ///   claim → reset to `pending`;
    /// - stale `recording`/`processing` meetings → `failed` with
    ///   `lastProcessingError = "interrupted"`. The sweep NEVER promotes to
    ///   `ready` — `ready` is minted exclusively by `finalizeMeetingProcessing`.
    private func runStartupSweeps() throws {
        try pool.write { db in
            try db.execute(
                sql: "UPDATE handoff_queue SET state = ? WHERE state = ?",
                arguments: [HandoffState.pending.rawValue, HandoffState.delivering.rawValue]
            )
            // F1: the twin sweep — a stale `running` processing job is an
            // interrupted claim at DB open; reset it to `pending` so recovery +
            // any kick drains it. This UNCONDITIONAL DB-open reset is the
            // load-bearing one (the worker also re-checks in start()); without
            // it, a launch via kick()-not-start() would strand the meeting (its
            // uniq_processing_live slot stays occupied; claimNext sees only
            // `pending`).
            try db.execute(
                sql: "UPDATE processing_queue SET state = 'pending', started_at = NULL WHERE state = 'running'")
            // G11 §3: a `recording` row with a non-nil `grace_until_ms` is
            // EXEMPTED from the flip — it was cleanly stopped-and-encoded by
            // construction (performAutoStop completed before grace was
            // written), so it is not a crashed live session. Launch recovery
            // (CaptureRecovery.recoverDurableGrace) handles it instead:
            // past-deadline → process, future → re-enter grace. A `processing`
            // row is ALWAYS flipped (no exemption): every grace exit clears the
            // durable column BEFORE the processing kick (clear-before-kick —
            // MeetCallTracker.finalizeGraceNow / CaptureRecovery), so no
            // `processing` row ever carries a non-nil grace column. No guard.
            try db.execute(
                sql: """
                    UPDATE meeting
                    SET status = ?, last_processing_error = 'interrupted', updated_at = ?
                    WHERE status = ?
                    """,
                arguments: [
                    MeetingStatus.failed.rawValue,
                    Date(),
                    MeetingStatus.processing.rawValue,
                ]
            )
            try db.execute(
                sql: """
                    UPDATE meeting
                    SET status = ?, last_processing_error = 'interrupted', updated_at = ?
                    WHERE status = ? AND grace_until_ms IS NULL
                    """,
                arguments: [
                    MeetingStatus.failed.rawValue,
                    Date(),
                    MeetingStatus.recording.rawValue,
                ]
            )
        }
    }

    // MARK: - Finalize (ready ⇒ queued invariant)

    /// Marks the meeting `ready`, upserts its notes, and enqueues its handoff
    /// in ONE database transaction — no crash point can produce a `ready`
    /// meeting without a queued/delivered handoff row. The payload file must
    /// already exist at `payloadPath` (relative to the data root).
    @discardableResult
    public func finalizeMeetingProcessing(
        meetingID: MeetingID,
        versionHash: String,
        payloadPath: String,
        notes: MeetingNotes
    ) async throws -> HandoffItem {
        try await finalizeMeetingProcessing(
            meetingID: meetingID,
            versionHash: versionHash,
            payloadPath: payloadPath,
            notes: notes,
            midTransactionHook: nil
        )
    }

    /// Internal variant with a test seam between the status flip and the
    /// enqueue, proving transaction atomicity.
    func finalizeMeetingProcessing(
        meetingID: MeetingID,
        versionHash: String,
        payloadPath: String,
        notes: MeetingNotes,
        midTransactionHook: (@Sendable () throws -> Void)?
    ) async throws -> HandoffItem {
        try requirePayloadFile(at: payloadPath)
        let rootURL = self.rootURL
        return try await pool.write { db in
            guard var meeting = try Meeting.fetchOne(db, key: meetingID) else {
                throw BlaiseDatabaseError.meetingNotFound(meetingID)
            }
            meeting.status = .ready
            meeting.lastProcessingError = nil
            // Deliberately NO updatedAt bump: the payload was built from the
            // pre-finalize row and embeds its `updated_at_ms`; mutating a
            // builder input AFTER the payload is minted would make C8's
            // re-materialization recovery (rebuild from durable state, must
            // hash-equal the stored version_hash) structurally impossible.
            // Content-changing writes (persistTranscript, regeneration) still
            // bump updatedAt before the builder runs.
            try meeting.update(db)

            try notes.upsert(db)

            try midTransactionHook?()

            return try HandoffRepository.enqueue(
                db,
                rootURL: rootURL,
                meetingID: meetingID,
                versionHash: versionHash,
                payloadPath: payloadPath
            )
        }
    }

    // MARK: - Transcript persistence (C7 stage 11)

    /// The single transcript persistence point (C7): replace-all segments
    /// (FTS synced by the external-content triggers) + `asrProvenance` +
    /// `dominantLanguage` meeting updates in the SAME transaction — C1's
    /// rule that provenance is set when the transcript is (re)written; a
    /// failed regeneration must never re-label the old transcript.
    /// `midTransactionHook` is the crash-test seam (C1 pattern).
    @discardableResult
    public func persistTranscript(
        meetingID: MeetingID,
        segments: [TranscriptSegment],
        asrProvenance: ASRProvenance,
        dominantLanguage: String,
        updatedAt: Date = Date(),
        midTransactionHook: (@Sendable () throws -> Void)? = nil
    ) async throws -> [TranscriptSegment] {
        try await pool.write { db in
            guard var meeting = try Meeting.fetchOne(db, key: meetingID) else {
                throw BlaiseDatabaseError.meetingNotFound(meetingID)
            }
            try db.execute(sql: "DELETE FROM transcript_segment WHERE meeting_id = ?", arguments: [meetingID])
            var inserted: [TranscriptSegment] = []
            for var segment in segments {
                segment.meetingID = meetingID
                segment.id = nil
                try segment.insert(db)
                inserted.append(segment)
            }
            meeting.asrProvenance = asrProvenance
            meeting.dominantLanguage = dominantLanguage
            meeting.updatedAt = updatedAt
            try meeting.update(db)
            try midTransactionHook?()
            return inserted
        }
    }

    func requirePayloadFile(at relativePath: String) throws {
        let url = rootURL.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BlaiseDatabaseError.missingPayloadFile(relativePath: relativePath)
        }
    }
}

// MARK: - Health check

public struct HealthCheck: Sendable, Equatable {
    public let schemaVersion: Int
    public let journalMode: String

    public static func run(_ database: BlaiseDatabase) async throws -> HealthCheck {
        try await database.pool.read { db in
            let journalMode = try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "unknown"
            let schemaVersion = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations") ?? 0
            return HealthCheck(schemaVersion: schemaVersion, journalMode: journalMode)
        }
    }
}
