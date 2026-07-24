import Foundation
import GRDB
import Testing
@testable import BlaiseCore

@Suite struct MigrationTests {
    @Test func freshDatabaseEndsAtV10WithStructuredColumnAndCloudSpend() throws {
        let database = try makeDatabase()
        try database.pool.read { db in
            let applied = try BlaiseDatabase.migrator.appliedMigrations(db)
            #expect(applied == ["v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9", "v10", "v11", "v12", "v13", "v14", "v15", "v16", "v17", "v18"])

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
            #expect(try BlaiseDatabase.migrator.appliedMigrations(db) == ["v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9", "v10", "v11", "v12", "v13", "v14", "v15", "v16", "v17", "v18"])
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(meeting_notes)").map { $0["name"] as String }
            #expect(columns.contains("structured"))
            #expect(columns.contains("memory_digest"), "v14 adds the nullable memory_digest column")
            #expect(
                columns.contains("scoped_alias_bindings"),
                "v17 adds the nullable scoped_alias_bindings column (T3.1 AC2 resume parity)")
            let meetingColumns = try Row.fetchAll(db, sql: "PRAGMA table_info(meeting)").map { $0["name"] as String }
            #expect(meetingColumns.contains("processing_note"))
            #expect(meetingColumns.contains("title_source"))
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
            #expect(try BlaiseDatabase.migrator.appliedMigrations(db) == ["v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9", "v10", "v11", "v12", "v13", "v14", "v15", "v16", "v17", "v18"])
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
}
