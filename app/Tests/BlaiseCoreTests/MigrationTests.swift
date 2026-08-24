import Foundation
import GRDB
import Testing
@testable import BlaiseCore

private struct MigrationColumnShape: Equatable {
    var name: String
    var type: String
    var notNull: Int
    var defaultValue: String?
    var primaryKeyPosition: Int

    init(_ row: Row) {
        name = row["name"]
        type = (row["type"] as String).uppercased()
        notNull = row["notnull"]
        defaultValue = row["dflt_value"]
        primaryKeyPosition = row["pk"]
    }
}

private struct MigrationSchemaSQL: Equatable {
    var name: String
    var sql: String?

    init(_ row: Row) {
        name = row["name"]
        sql = row["sql"]
    }
}

@Suite struct MigrationTests {
    @Test func freshDatabaseEndsAtV10WithStructuredColumnAndCloudSpend() throws {
        let database = try makeDatabase()
        try database.pool.read { db in
            let applied = try BlaiseDatabase.migrator.appliedMigrations(db)
            #expect(applied == ["v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9", "v10", "v11", "v12", "v13", "v14", "v15", "v16", "v17", "v18", "v19", "v20", "v21", "v22"])

            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(meeting_notes)")
            let structured = columns.first { $0["name"] == "structured" }
            #expect(structured != nil, "meeting_notes.structured column missing")
            #expect(structured?["notnull"] == 1, "structured must be NOT NULL")

            // C6 migration v3: cloud_spend table + meeting.processing_note.
            let cloudSpend = try Row.fetchAll(db, sql: "PRAGMA table_info(cloud_spend)")
                .map { $0["name"] as String }
            #expect(cloudSpend.contains("month_key"))
            #expect(cloudSpend.contains("accumulated_usd"))
            let meetingColumns = try Row.fetchAll(db, sql: "PRAGMA table_info(meeting)")
                .map { $0["name"] as String }
            #expect(meetingColumns.contains("processing_note"))
            // C11 migration v6: durable captured-meeting marker.
            #expect(meetingColumns.contains("captured"))

            // V1.1 migration v7: local-only action-item done state.
            let actionState = try Row.fetchAll(db, sql: "PRAGMA table_info(action_item_state)")
            let names = actionState.map { $0["name"] as String }
            #expect(names == ["meeting_id", "item_key", "done_at"])
            let pkColumns = actionState.filter { ($0["pk"] as Int) > 0 }.map { $0["name"] as String }
            #expect(Set(pkColumns) == ["meeting_id", "item_key"], "PK(meeting_id, item_key)")

            // C14 migration v8: per-part capture metadata.
            let partColumns = try Row.fetchAll(db, sql: "PRAGMA table_info(meeting_capture_part)")
            let partNames = partColumns.map { $0["name"] as String }
            #expect(partNames == ["meeting_id", "part_index", "started_at_ms", "ended_at_ms"])
            let endedNullable = partColumns.first { $0["name"] == "ended_at_ms" }
            #expect(endedNullable?["notnull"] == 0, "ended_at_ms is NULL while a part records")
            let partPK = partColumns.filter { ($0["pk"] as Int) > 0 }.map { $0["name"] as String }
            #expect(Set(partPK) == ["meeting_id", "part_index"], "PK(meeting_id, part_index)")

            // G7 migration v9: per-call cloud-spend receipts.
            let receiptColumns = try Row.fetchAll(db, sql: "PRAGMA table_info(cloud_spend_receipt)")
            let receiptNames = receiptColumns.map { $0["name"] as String }
            #expect(
                receiptNames == [
                    "id", "timestamp", "month_key", "engine_id", "model", "purpose",
                    "meeting_id", "input_tokens", "output_tokens", "cost_usd", "note",
                ])
            let receiptPK = receiptColumns.filter { ($0["pk"] as Int) > 0 }.map { $0["name"] as String }
            #expect(receiptPK == ["id"], "PK(id)")
            // purpose is CHECK-constrained; meeting_id is nullable; cost_usd REAL.
            let meetingIDCol = receiptColumns.first { $0["name"] == "meeting_id" }
            #expect(meetingIDCol?["notnull"] == 0, "meeting_id is nullable (ON DELETE SET NULL)")
            let costCol = receiptColumns.first { $0["name"] == "cost_usd" }
            // GRDB's `.double` declares DOUBLE (SQLite REAL affinity).
            let costType = (costCol?["type"] as String?)?.uppercased() ?? ""
            #expect(costType == "DOUBLE")

            // G2 migration v10: the name-correction store + speaker-rename table.
            let ncColumns = try Row.fetchAll(db, sql: "PRAGMA table_info(name_correction)")
            let ncNames = ncColumns.map { $0["name"] as String }
            #expect(
                ncNames == [
                    "id", "misheard_folded", "replacement", "everyday",
                    "source_meeting_id", "created_at",
                ])
            let ncPK = ncColumns.filter { ($0["pk"] as Int) > 0 }.map { $0["name"] as String }
            #expect(ncPK == ["id"], "PK(id)")
            // misheard_folded is UNIQUE.
            let ncIndexes = try Row.fetchAll(db, sql: "PRAGMA index_list(name_correction)")
            #expect(ncIndexes.contains { ($0["unique"] as Int) == 1 }, "misheard_folded UNIQUE")
            // source_meeting_id is nullable (ON DELETE SET NULL).
            let ncSource = ncColumns.first { $0["name"] == "source_meeting_id" }
            #expect(ncSource?["notnull"] == 0)

            let renameColumns = try Row.fetchAll(db, sql: "PRAGMA table_info(speaker_rename)")
            let renameNames = renameColumns.map { $0["name"] as String }
            #expect(
                renameNames == [
                    "meeting_id", "speaker_label", "anchor_ms", "stale", "name", "created_at",
                ])
            let renamePK = renameColumns.filter { ($0["pk"] as Int) > 0 }.map { $0["name"] as String }
            #expect(Set(renamePK) == ["meeting_id", "speaker_label"], "PK(meeting_id, speaker_label)")
            let staleCol = renameColumns.first { $0["name"] == "stale" }
            #expect(staleCol?["notnull"] == 1, "stale NOT NULL (default 0)")

            // G10 migration v11: the deletion tombstone (no FK — outlives the row).
            let tombColumns = try Row.fetchAll(db, sql: "PRAGMA table_info(meeting_tombstone)")
            let tombNames = tombColumns.map { $0["name"] as String }
            #expect(tombNames == ["id", "audio_dir_path", "deleted_at"])
            let tombPK = tombColumns.filter { ($0["pk"] as Int) > 0 }.map { $0["name"] as String }
            #expect(tombPK == ["id"], "PK(id)")
            let tombFKs = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(meeting_tombstone)")
            #expect(tombFKs.isEmpty, "the tombstone has NO FK — it outlives the meeting row")

            // G11 migration v12: the calendar anchor + durable resume-grace
            // columns, all additive + nullable.
            let g11Columns = try Row.fetchAll(db, sql: "PRAGMA table_info(meeting)")
            let g11Names = g11Columns.map { $0["name"] as String }
            #expect(g11Names.contains("calendar_event_id"))
            #expect(g11Names.contains("scheduled_end_ms"))
            #expect(g11Names.contains("grace_until_ms"))
            for name in ["calendar_event_id", "scheduled_end_ms", "grace_until_ms"] {
                let col = g11Columns.first { $0["name"] == name }
                #expect(col?["notnull"] == 0, "\(name) is nullable (additive)")
            }

            // G12 migration v13: the title-precedence provenance, additive,
            // NOT NULL with a backfilled 'default'.
            let g12Columns = try Row.fetchAll(db, sql: "PRAGMA table_info(meeting)")
            let titleSource = g12Columns.first { $0["name"] == "title_source" }
            #expect(titleSource != nil, "meeting.title_source column missing")
            #expect(titleSource?["notnull"] == 1, "title_source NOT NULL")
            #expect((titleSource?["dflt_value"] as String?) == "'default'", "backfilled 'default'")
        }
    }

    @Test func laterMigrationsApplyOnTopOfEmptyV1() throws {
        let url = try makeTempRoot().appendingPathComponent("v1-empty.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try BlaiseDatabase.migrator.migrate(queue, upTo: "v1")
        try queue.read { db in
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(meeting_notes)").map { $0["name"] as String }
            #expect(!columns.contains("structured"))
        }

        try BlaiseDatabase.migrator.migrate(queue)

        try queue.read { db in
            #expect(try BlaiseDatabase.migrator.appliedMigrations(db) == ["v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9", "v10", "v11", "v12", "v13", "v14", "v15", "v16", "v17", "v18", "v19", "v20", "v21", "v22"])
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(meeting_notes)").map { $0["name"] as String }
            #expect(columns.contains("structured"))
            #expect(columns.contains("memory_digest"), "v14 adds the nullable memory_digest column")
            #expect(
                columns.contains("scoped_alias_bindings"),
                "v17 adds the nullable scoped_alias_bindings column (T3.1 AC2 resume parity)")
            let meetingColumns = try Row.fetchAll(db, sql: "PRAGMA table_info(meeting)").map { $0["name"] as String }
            #expect(meetingColumns.contains("processing_note"))
            #expect(meetingColumns.contains("title_source"))
            // G5 v1.5 / migration v19: delivery provenance. Nullable by design —
            // a row delivered by an earlier binary has no proof of WHERE, so it
            // is never a deletion candidate.
            let queueColumns = try Row.fetchAll(db, sql: "PRAGMA table_info(handoff_queue)")
            let endpoint = try #require(queueColumns.first { $0["name"] == "delivered_endpoint" })
            #expect(endpoint["notnull"] == 0, "delivered_endpoint must be nullable")
        }
    }

    /// v3–v9 are additive (nullable/defaulted columns + new tables) — they apply
    /// on a POPULATED v2 database without touching existing rows.
    @Test func v3ThroughV9ApplyOnPopulatedV2() throws {
        let url = try makeTempRoot().appendingPathComponent("v2-populated.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try BlaiseDatabase.migrator.migrate(queue, upTo: "v2")
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO meeting (id, title, started_at, source, status, attendees, created_at, updated_at)
                    VALUES (?, 'v2 meeting', ?, 'meet', 'ready', '[]', ?, ?)
                    """,
                arguments: [ULID.generate(), msDate(), msDate(), msDate()]
            )
        }

        try BlaiseDatabase.migrator.migrate(queue)

        try queue.read { db in
            #expect(try BlaiseDatabase.migrator.appliedMigrations(db) == ["v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9", "v10", "v11", "v12", "v13", "v14", "v15", "v16", "v17", "v18", "v19", "v20", "v21", "v22"])
            let note = try Row.fetchOne(db, sql: "SELECT processing_note, title, captured, title_source FROM meeting")
            #expect(note?["processing_note"] == nil)
            #expect(note?["title"] == "v2 meeting")
            #expect(note?["captured"] == 0, "v6 backfills captured = false")
            // G12 v13: the pre-existing row backfills to the default tier (its
            // title is the one minted at create, never an llm/calendar promotion).
            #expect(note?["title_source"] == "default", "v13 backfills title_source = 'default'")
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM action_item_state") == 0)
            // v8: pre-v8 meetings simply have NO part rows (single-part is
            // derived at stitch time, never migrated).
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meeting_capture_part") == 0)
            // v9: the receipt table exists and is empty (pre-G7 history has no
            // receipts — the permanent reconciliation delta the panel labels).
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cloud_spend_receipt") == 0)
            // v10 (G2): the name-correction store + speaker-rename table exist
            // and are empty on an upgraded old DB (AC7: additive, old DBs open).
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM name_correction") == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM speaker_rename") == 0)
        }
    }

    /// A populated v1 cannot exist outside tests (the first notes-writer,
    /// C7, ships after v2) — the NOT-NULL-without-DEFAULT column makes the
    /// migration fail LOUDLY rather than silently fabricate data. This test
    /// pins that defined behavior so the invariant is never silently broken.
    @Test func populatedV1MakesV2FailLoudly() throws {
        let url = try makeTempRoot().appendingPathComponent("v1-populated.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try BlaiseDatabase.migrator.migrate(queue, upTo: "v1")
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO meeting (id, title, started_at, source, status, attendees, created_at, updated_at)
                    VALUES (?, 'v1 meeting', ?, 'meet', 'ready', '[]', ?, ?)
                    """,
                arguments: [ULID.generate(), msDate(), msDate(), msDate()]
            )
            try db.execute(
                sql: """
                    INSERT INTO meeting_notes (meeting_id, markdown, language, generated_at, provenance)
                    VALUES ((SELECT id FROM meeting), '# v1 notes', 'pt-BR', ?, '{}')
                    """,
                arguments: [msDate()]
            )
        }

        #expect(throws: DatabaseError.self) {
            try BlaiseDatabase.migrator.migrate(queue)
        }

        try queue.read { db in
            let applied = try BlaiseDatabase.migrator.appliedMigrations(db)
            #expect(applied == ["v1"], "failed v2 must not be recorded as applied")
            // The failed ALTER rolled back: no structured column, row intact.
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(meeting_notes)").map { $0["name"] as String }
            #expect(!columns.contains("structured"))
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meeting_notes") == 1)
        }
    }

    /// C15 migration v18: the `meeting` rebuild that widens `source` for
    /// `slack` (real users' old-binary DBs carry a `slack`-rejecting v1 CHECK;
    /// the current binary's v1 already includes it, so this pins the rebuild's
    /// MECHANICS — data preserved, indexes recreated, `slack` insertable —
    /// which is what must never corrupt an upgraded database).
    ///
    /// The child rows are the load-bearing half: `meeting` is the FK parent of
    /// the whole content model (transcript_segment, meeting_notes,
    /// processing_queue, … all `ON DELETE CASCADE`). The rebuild drops the old
    /// `meeting` table, which — were foreign keys enforced during migration —
    /// would cascade-delete every child row in the database. GRDB's `.deferred`
    /// mode disables FK enforcement (`PRAGMA foreign_keys = OFF`) around the
    /// migration, which is what makes the drop safe. This test pins that with
    /// populated children: a regression (a GRDB behavior change, or someone
    /// switching the migration to `.immediate`) silently destroys every user's
    /// transcripts, and ONLY a populated-children test catches it.
    @Test func v18RebuildPreservesDataAndWidensSource() throws {
        let url = try makeTempRoot().appendingPathComponent("v17-populated.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try BlaiseDatabase.migrator.migrate(queue, upTo: "v17")
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO meeting (id, title, started_at, source, status, attendees, created_at, updated_at, meeting_code)
                    VALUES ('M1', 'kept', ?, 'meet', 'ready', '[]', ?, ?, 'abc-defg-hij')
                    """,
                arguments: [msDate(), msDate(), msDate()])
            // CASCADE children of M1 — the rows the rebuild must not destroy.
            try db.execute(
                sql: """
                    INSERT INTO transcript_segment (meeting_id, ord, start_seconds, end_seconds, speaker_label, text)
                    VALUES ('M1', 0, 0.0, 2.5, 'S1', 'kept segment one'),
                           ('M1', 1, 2.5, 4.0, 'S2', 'kept segment two')
                    """)
            try db.execute(
                sql: """
                    INSERT INTO meeting_notes (meeting_id, markdown, language, generated_at, provenance, structured)
                    VALUES ('M1', '# kept notes', 'en', ?, '{}', '{}')
                    """,
                arguments: [msDate()])
            try db.execute(
                sql: """
                    INSERT INTO processing_queue (id, meeting_id, state, origin, enqueued_at, created_seq)
                    VALUES ('J1', 'M1', 'pending', 'auto', ?, 1)
                    """,
                arguments: [msDate()])
        }

        try BlaiseDatabase.migrator.migrate(queue, upTo: "v18")

        try queue.write { db in
            // Existing row (and its non-default columns) preserved across the
            // create-copy-drop-rename rebuild.
            let kept = try Row.fetchOne(db, sql: "SELECT * FROM meeting WHERE id = 'M1'")
            #expect(kept?["title"] == "kept")
            #expect(kept?["meeting_code"] == "abc-defg-hij")
            #expect(kept?["title_source"] == "default")
            // Children survived the parent-table drop (FKs off during the
            // migration; the drop must NOT have cascaded).
            #expect(
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM transcript_segment WHERE meeting_id = 'M1'") == 2)
            #expect(
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM meeting_notes WHERE meeting_id = 'M1'") == 1)
            #expect(
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM processing_queue WHERE meeting_id = 'M1'") == 1)
            // And the FK relationship still holds after the rename: cascades
            // work post-migration exactly as before.
            #expect(try Bool.fetchOne(db, sql: "PRAGMA foreign_keys") == true)
            // slack inserts.
            try db.execute(
                sql: """
                    INSERT INTO meeting (id, title, started_at, source, status, attendees, created_at, updated_at)
                    VALUES ('M2', 'slack meeting', ?, 'slack', 'ready', '[]', ?, ?)
                    """,
                arguments: [msDate(), msDate(), msDate()])
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meeting WHERE source = 'slack'") == 1)
            // Indexes recreated under their canonical names.
            let indexes = try Set(
                String.fetchAll(
                    db,
                    sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'meeting'"))
            #expect(indexes.contains("index_meeting_on_started_at"))
            #expect(indexes.contains("index_meeting_on_status"))
        }
    }

    // v20 over a POPULATED v19 database. The migration adds a table and an
    // index to a live schema; a populated upgrade is the only shape that
    // proves the pre-existing meeting_notes row survives it and reads back
    // through the CURRENT decoder.
    @Test func v20MigratesAPopulatedV19Database() throws {
        let url = try makeTempRoot().appendingPathComponent("v19-populated.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try BlaiseDatabase.migrator.migrate(queue, upTo: "v19")
        let meetingID = ULID.generate()
        let structuredJSON =
            #"{"summary":"Resumo","detailed_notes":"","decisions":[],"action_items":[],"user_action_items":[]}"#
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO meeting (id, title, started_at, source, status, attendees, created_at, updated_at)
                    VALUES (?, 'Reunião antiga', ?, 'meet', 'ready', '[]', ?, ?)
                    """,
                arguments: [meetingID, msDate(), msDate(), msDate()])
            try db.execute(
                sql: """
                    INSERT INTO meeting_notes (meeting_id, markdown, language, generated_at, provenance, structured)
                    VALUES (?, '# Notas antigas', 'pt-BR', ?, ?, ?)
                    """,
                arguments: [
                    meetingID, msDate(),
                    #"{"engine":"legacy","model":"m","pipeline_version":"1"}"#,
                    structuredJSON,
                ])
        }

        try BlaiseDatabase.migrator.migrate(queue, upTo: "v20")

        try queue.read { db in
            #expect(try BlaiseDatabase.migrator.appliedMigrations(db).last == "v20")
            // The exact ten columns, by name AND declared type.
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(meeting_correction)")
                .map { ($0["name"] as String, ($0["type"] as String).uppercased()) }
            #expect(
                columns.map(\.0) == [
                    "id", "meeting_id", "kind", "section", "quoted_text", "occurrence",
                    "user_text", "status", "created_at", "applied_at",
                ])
            #expect(
                columns.map(\.1) == [
                    "TEXT", "TEXT", "TEXT", "TEXT", "TEXT", "INTEGER",
                    "TEXT", "TEXT", "DATETIME", "DATETIME",
                ])
            // The FK to `meeting`, cascading — a deleted meeting takes its
            // correction rows with it.
            let foreignKeys = try Row.fetchAll(
                db, sql: "PRAGMA foreign_key_list(meeting_correction)")
            #expect(foreignKeys.count == 1)
            #expect(foreignKeys.first?["table"] == "meeting")
            #expect(foreignKeys.first?["from"] == "meeting_id")
            #expect(foreignKeys.first?["on_delete"] == "CASCADE")
            // The lookup index the store's only query shape needs, in its
            // exact three-column order.
            let indexes = try Row.fetchAll(db, sql: "PRAGMA index_list(meeting_correction)")
                .map { $0["name"] as String }
            #expect(indexes.contains("idx_meeting_correction_meeting"))
            let indexed = try Row.fetchAll(
                db, sql: "PRAGMA index_info(idx_meeting_correction_meeting)"
            ).map { $0["name"] as String }
            #expect(indexed == ["meeting_id", "created_at", "id"])
            // The payload trim: the notes row gains NO correction column.
            let notesColumns = try Row.fetchAll(db, sql: "PRAGMA table_info(meeting_notes)")
                .map { $0["name"] as String }
            #expect(!notesColumns.contains("user_corrections"))
            // The pre-existing row survives and decodes unchanged.
            let notes = try #require(try MeetingNotes.fetchOne(db, key: meetingID))
            #expect(notes.markdown == "# Notas antigas")
            #expect(notes.language == "pt-BR")
            #expect(notes.structured.summary == "Resumo")
            #expect(notes.structured.decisions.isEmpty)
            #expect(try MeetingCorrectionStore.all(db, meetingID: meetingID).isEmpty)
        }

        // And a correction written AFTER the upgrade round-trips.
        let row = MeetingCorrection(
            meetingID: meetingID, kind: .annotation, section: .summary,
            quotedText: "Resumo", userText: "Conferir.", createdAt: msDate())
        try queue.write { db in
            try MeetingCorrectionStore.insert(db, row)
        }
        try queue.read { db in
            let rows = try MeetingCorrectionStore.all(db, meetingID: meetingID)
            #expect(rows == [row])
        }
    }

    @Test("AC-14: populated v20 receipts survive v21 and gain only the canonical index")
    func v21RebuildsAPopulatedV20ReceiptTable() throws {
        let url = try makeTempRoot().appendingPathComponent("v20-populated.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try BlaiseDatabase.migrator.migrate(queue, upTo: "v20")
        let meetingID = "01V21LIVEMEETING00000000000"
        let oldPurposes = ["generation", "regeneration", "validation", "smoke", "digest"]

        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO meeting
                      (id, title, started_at, source, status, attendees, created_at, updated_at)
                    VALUES (?, 'Populated v20 meeting', ?, 'meet', 'ready', '[]', ?, ?)
                    """,
                arguments: [meetingID, msDate(), msDate(), msDate()])
            for (index, purpose) in oldPurposes.enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO cloud_spend_receipt
                          (id, timestamp, month_key, engine_id, model, purpose, meeting_id,
                           input_tokens, output_tokens, cost_usd, note)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        "receipt-\(index)", msDate(1_770_000_000.5 + Double(index)),
                        index.isMultiple(of: 2) ? "2026-08" : "2026-07",
                        "engine-\(index)", "model-\(index)-ç", purpose,
                        index == 0 ? meetingID : nil,
                        100 + index, 10 + index, Double(index) + 0.125,
                        index == 4 ? nil : "note-\(index)-á",
                    ])
            }

            // `allCases` is evaluated by migration source at runtime, so a
            // newly-created test DB would otherwise get the widened CHECK even
            // when stopped at v20. Recreate the exact shipped-v20 frozen CHECK
            // and its retained v14 temporary-name index before exercising v21.
            try db.create(table: "cloud_spend_receipt_v20_fixture") { t in
                t.primaryKey("id", .text)
                t.column("timestamp", .datetime).notNull()
                t.column("month_key", .text).notNull()
                t.column("engine_id", .text).notNull()
                t.column("model", .text).notNull()
                t.column("purpose", .text).notNull()
                    .check { oldPurposes.contains($0) }
                t.column("meeting_id", .text)
                    .references("meeting", onDelete: .setNull)
                t.column("input_tokens", .integer).notNull()
                t.column("output_tokens", .integer).notNull()
                t.column("cost_usd", .double).notNull()
                t.column("note", .text)
            }
            try db.execute(sql: """
                INSERT INTO cloud_spend_receipt_v20_fixture
                  (id, timestamp, month_key, engine_id, model, purpose, meeting_id,
                   input_tokens, output_tokens, cost_usd, note)
                SELECT
                  id, timestamp, month_key, engine_id, model, purpose, meeting_id,
                  input_tokens, output_tokens, cost_usd, note
                FROM cloud_spend_receipt
                """)
            try db.drop(table: "cloud_spend_receipt")
            try db.rename(
                table: "cloud_spend_receipt_v20_fixture", to: "cloud_spend_receipt")
            try db.execute(sql: """
                CREATE INDEX "index_cloud_spend_receipt_new_on_month_key"
                ON "cloud_spend_receipt"("month_key")
                """)
        }

        #expect(throws: DatabaseError.self) {
            try queue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO cloud_spend_receipt
                          (id, timestamp, month_key, engine_id, model, purpose,
                           input_tokens, output_tokens, cost_usd)
                        VALUES ('rejected-before-v21', ?, '2026-08', 'e', 'm',
                                'notes-editor', 1, 1, 0.0)
                        """,
                    arguments: [msDate()])
            }
        }

        let before = try queue.read { db in
            let receipts = try CloudSpendReceipt.fetchAll(
                db, sql: "SELECT * FROM cloud_spend_receipt ORDER BY id")
            let columns = try Row.fetchAll(
                db, sql: "PRAGMA table_info(cloud_spend_receipt)").map(MigrationColumnShape.init)
            let correctionColumns = try Row.fetchAll(
                db, sql: "PRAGMA table_info(meeting_correction)").map(MigrationColumnShape.init)
            let otherTables = try Row.fetchAll(
                db,
                sql: """
                    SELECT name, sql FROM sqlite_master
                    WHERE type = 'table' AND name <> 'cloud_spend_receipt'
                    ORDER BY name
                    """).map(MigrationSchemaSQL.init)
            return (receipts, columns, correctionColumns, otherTables)
        }

        try BlaiseDatabase.migrator.migrate(queue)

        try queue.read { db in
            let afterReceipts = try CloudSpendReceipt.fetchAll(
                db, sql: "SELECT * FROM cloud_spend_receipt ORDER BY id")
            #expect(afterReceipts == before.0, "every receipt value must survive row by row")

            let columns = try Row.fetchAll(
                db, sql: "PRAGMA table_info(cloud_spend_receipt)").map(MigrationColumnShape.init)
            #expect(columns == before.1)
            #expect(columns.map(\.name) == [
                "id", "timestamp", "month_key", "engine_id", "model", "purpose",
                "meeting_id", "input_tokens", "output_tokens", "cost_usd", "note",
            ])
            #expect(columns.map(\.type) == [
                "TEXT", "DATETIME", "TEXT", "TEXT", "TEXT", "TEXT",
                "TEXT", "INTEGER", "INTEGER", "DOUBLE", "TEXT",
            ])
            #expect(columns.map(\.notNull) == [1, 1, 1, 1, 1, 1, 0, 1, 1, 1, 0])
            #expect(columns.map(\.primaryKeyPosition) == [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])

            let foreignKeys = try Row.fetchAll(
                db, sql: "PRAGMA foreign_key_list(cloud_spend_receipt)")
            #expect(foreignKeys.count == 1)
            #expect(foreignKeys.first?["table"] == "meeting")
            #expect(foreignKeys.first?["from"] == "meeting_id")
            #expect(foreignKeys.first?["to"] == "id")
            #expect(foreignKeys.first?["on_delete"] == "SET NULL")

            let indexes = try Row.fetchAll(
                db, sql: "PRAGMA index_list(cloud_spend_receipt)")
            let indexNames = Set(indexes.map { $0["name"] as String })
            #expect(indexNames == [
                "sqlite_autoindex_cloud_spend_receipt_1",
                "index_cloud_spend_receipt_on_month_key",
            ])
            let explicitIndexes = indexes.filter { ($0["origin"] as String) == "c" }
            #expect(explicitIndexes.count == 1)
            #expect(explicitIndexes.first?["name"] == "index_cloud_spend_receipt_on_month_key")
            let monthColumns = try Row.fetchAll(
                db, sql: "PRAGMA index_info(index_cloud_spend_receipt_on_month_key)"
            ).map { $0["name"] as String }
            #expect(monthColumns == ["month_key"])
            #expect(!indexNames.contains { $0.contains("_new_") || $0.contains("v21") })
            #expect(try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM sqlite_master
                    WHERE name = 'cloud_spend_receipt_v21'
                       OR name = 'cloud_spend_receipt_v20_fixture'
                    """) == 0)

            let correctionColumns = try Row.fetchAll(
                db, sql: "PRAGMA table_info(meeting_correction)").map(MigrationColumnShape.init)
            #expect(correctionColumns == before.2)
            // `meeting_notes` is excluded: v22 adds the two owed-work columns
            // and the digest stamp to it. Every OTHER table shape must still be
            // untouched by the receipt rebuilds.
            let otherTables = try Row.fetchAll(
                db,
                sql: """
                    SELECT name, sql FROM sqlite_master
                    WHERE type = 'table' AND name NOT IN ('cloud_spend_receipt', 'meeting_notes')
                    ORDER BY name
                    """).map(MigrationSchemaSQL.init)
            #expect(
                otherTables == before.3.filter { $0.name != "meeting_notes" },
                "the receipt rebuilds must not change another table shape")
            #expect(try BlaiseDatabase.migrator.appliedMigrations(db).last == "v22")
        }

        try queue.write { db in
            for purpose in CloudSpendPurpose.allCases {
                try db.execute(
                    sql: """
                        INSERT INTO cloud_spend_receipt
                          (id, timestamp, month_key, engine_id, model, purpose,
                           input_tokens, output_tokens, cost_usd)
                        VALUES (?, ?, '2026-08', 'engine', 'model', ?, 1, 2, 0.0)
                        """,
                    arguments: ["valid-\(purpose.rawValue)", msDate(), purpose.rawValue])
            }
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

        // The live FK survived the rebuild and still nulls rather than deleting
        // the receipt when its meeting disappears.
        try queue.write { db in
            try db.execute(sql: "DELETE FROM meeting WHERE id = ?", arguments: [meetingID])
        }
        try queue.read { db in
            let survivingMeetingID = try String.fetchOne(
                db,
                sql: "SELECT meeting_id FROM cloud_spend_receipt WHERE id = 'receipt-0'")
            #expect(survivingMeetingID == nil)
        }
    }
}
