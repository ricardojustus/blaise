import Foundation
import GRDB
import Testing

@testable import BlaiseCore

// N6 §3 — the single-shot migration proof: one populated, production-SHAPED
// database upgraded through the ENTIRE arc chain in one run, in both the state
// a clean pre-arc install is in (v19) and the state the real production
// database is in (v19 with v20 already applied). Fixtures only; no real
// database is ever opened. Every value is FICTIONAL (Vexatron Labs / Quoll
// Harbor).

// MARK: - The frozen v19 baseline

/// The receipt purposes a REAL v19 database's frozen CHECK admits. Migrations
/// derive their CHECK from `CloudSpendPurpose.allCases` at RUN time, so a
/// freshly built baseline would otherwise get today's widened constraint and
/// the upgrade would be proven against a schema no user is on.
private let frozenV19Purposes = ["generation", "regeneration", "validation", "smoke", "digest"]

private let digestBearingMeeting = "01N6MGRATNCHA0000000000001"
private let digestLessMeeting = "01N6MGRATNCHA0000000000002"

private let fixtureDigest = """
    ## HEADER
    meeting: Vexatron Labs field-kit review
    date: 2026-03-14

    ## STATUS
    The Quoll Harbor field kit reached 70% coverage.
    """

private let fixtureVersionHash = "b3f1c0a29d4e5f60718293a4b5c6d7e8f90112233445566778899aabbccddeeff"

/// Builds the populated, frozen-shape v19 database `M-1` and `M-2` both start
/// from, at `<root>/blaise.sqlite` so the normal app open can be exercised on
/// the very same file afterwards.
private func buildPopulatedFrozenV19(root: URL) throws {
    let queue = try DatabaseQueue(path: root.appendingPathComponent("blaise.sqlite").path)
    try BlaiseDatabase.migrator.migrate(queue, upTo: "v19")
    try queue.write { db in
        // Two meetings: one that will carry a digest through the md-v6
        // backfill, one that must stay NULL — the backfill both ways.
        try db.execute(
            sql: """
                INSERT INTO meeting
                  (id, title, started_at, ended_at, source, status, attendees,
                   dominant_language, asr_provenance, last_processing_error,
                   created_at, updated_at)
                VALUES (?, ?, ?, ?, 'meet', 'ready', ?, 'pt-BR', NULL, NULL, ?, ?)
                """,
            arguments: [
                digestBearingMeeting, "Vexatron Labs — revisão do field kit",
                msDate(1_770_000_000), msDate(1_770_003_600),
                #"[{"name":"Dana Marsh","source":"manual"}]"#,
                msDate(1_770_000_000), msDate(1_770_003_600),
            ])
        try db.execute(
            sql: """
                INSERT INTO meeting
                  (id, title, started_at, ended_at, source, status, attendees,
                   dominant_language, asr_provenance, last_processing_error,
                   created_at, updated_at)
                VALUES (?, ?, ?, NULL, 'meet', 'ready', '[]', NULL, NULL, NULL, ?, ?)
                """,
            arguments: [
                digestLessMeeting, "Quoll Harbor onboarding sync",
                msDate(1_770_100_000), msDate(1_770_100_000), msDate(1_770_100_000),
            ])

        // Notes: Unicode and a nullable digest on one row, NULL on the other.
        try db.execute(
            sql: """
                INSERT INTO meeting_notes
                  (meeting_id, markdown, language, generated_at, provenance, structured,
                   memory_digest)
                VALUES (?, ?, 'pt-BR', ?, ?, ?, ?)
                """,
            arguments: [
                digestBearingMeeting, "# Revisão do field kit\n\nAção — enviar o contrato.",
                msDate(1_770_003_600),
                #"{"engine":"legacy","model":"m","pipeline_version":"1"}"#,
                #"{"summary":"Ação concluída.","detailed_notes":"Café às 14:30.","decisions":[],"action_items":[],"user_action_items":[]}"#,
                fixtureDigest,
            ])
        try db.execute(
            sql: """
                INSERT INTO meeting_notes
                  (meeting_id, markdown, language, generated_at, provenance, structured,
                   memory_digest)
                VALUES (?, '# Onboarding sync', 'en', ?, ?, ?, NULL)
                """,
            arguments: [
                digestLessMeeting, msDate(1_770_100_000),
                #"{"engine":"legacy","model":"m","pipeline_version":"1"}"#,
                #"{"summary":"Kickoff.","detailed_notes":"","decisions":[],"action_items":[],"user_action_items":[]}"#,
            ])

        try db.execute(
            sql: """
                INSERT INTO transcript_segment
                  (meeting_id, ord, start_seconds, end_seconds, speaker_label, speaker_name, text)
                VALUES (?, 0, 0.0, 2.5, 'S0', 'Dana Marsh', 'O field kit sai em maio.'),
                       (?, 1, 2.5, 4.25, 'S1', NULL, 'Ação — confirmar a data.')
                """,
            arguments: [digestBearingMeeting, digestBearingMeeting])

        // Receipts covering EVERY legacy purpose, with a NULL meeting id and a
        // live foreign-key meeting id among them, plus Unicode and NULL notes.
        for (index, purpose) in frozenV19Purposes.enumerated() {
            try db.execute(
                sql: """
                    INSERT INTO cloud_spend_receipt
                      (id, timestamp, month_key, engine_id, model, purpose, meeting_id,
                       input_tokens, output_tokens, cost_usd, note)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    "n6-receipt-\(index)", msDate(1_770_000_000.5 + Double(index)),
                    index.isMultiple(of: 2) ? "2026-08" : "2026-07",
                    "engine-\(index)", "modelo-\(index)-ç", purpose,
                    index == 0 ? digestBearingMeeting : nil,
                    100 + index, 10 + index, Double(index) + 0.125,
                    index == 4 ? nil : "observação-\(index)-á",
                ])
        }

        // A queued handoff row, in the state the startup sweep intentionally
        // rewrites — which is exactly why the preservation snapshot is taken
        // BEFORE the normal-path open below.
        try db.execute(
            sql: """
                INSERT INTO handoff_queue
                  (id, meeting_id, payload_path, version_hash, state, attempts, created_at,
                   created_seq)
                VALUES ('n6-handoff-1', ?, ?, ?, 'delivering', 1, ?, 1)
                """,
            arguments: [
                digestBearingMeeting,
                MeetingPaths(rootURL: root).relativeHandoffPayloadPath(
                    meetingID: digestBearingMeeting, versionHash: fixtureVersionHash),
                fixtureVersionHash, msDate(1_770_003_600),
            ])

        // The frozen-shape reconstruction. `migrate(upTo:)` alone builds
        // TODAY's widened receipts CHECK, so without this the upgrade would be
        // proven against a schema no user is on — synthetic exactly where the
        // v21/v22 rebuilds do their work. Rebuild the receipt table under the
        // historical CHECK and restore v14's retained temporary-name index.
        try db.create(table: "cloud_spend_receipt_v19_fixture") { t in
            t.primaryKey("id", .text)
            t.column("timestamp", .datetime).notNull()
            t.column("month_key", .text).notNull()
            t.column("engine_id", .text).notNull()
            t.column("model", .text).notNull()
            t.column("purpose", .text).notNull()
                .check { frozenV19Purposes.contains($0) }
            t.column("meeting_id", .text)
                .references("meeting", onDelete: .setNull)
            t.column("input_tokens", .integer).notNull()
            t.column("output_tokens", .integer).notNull()
            t.column("cost_usd", .double).notNull()
            t.column("note", .text)
        }
        try db.execute(sql: """
            INSERT INTO cloud_spend_receipt_v19_fixture
              (id, timestamp, month_key, engine_id, model, purpose, meeting_id,
               input_tokens, output_tokens, cost_usd, note)
            SELECT
              id, timestamp, month_key, engine_id, model, purpose, meeting_id,
              input_tokens, output_tokens, cost_usd, note
            FROM cloud_spend_receipt
            """)
        try db.drop(table: "cloud_spend_receipt")
        try db.rename(table: "cloud_spend_receipt_v19_fixture", to: "cloud_spend_receipt")
        try db.execute(sql: """
            CREATE INDEX "index_cloud_spend_receipt_new_on_month_key"
            ON "cloud_spend_receipt"("month_key")
            """)
        // The baseline really does carry the stale index, and the pattern the
        // end-state battery screens with really does match it. Without this
        // control, that battery's "no temporary index survives" assertion could
        // pass because the pattern matches nothing, anywhere.
        let staleIndexes = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) FROM sqlite_master
                WHERE name LIKE '%\\_new\\_%' ESCAPE '\\'
                """)
        #expect(staleIndexes == 1, "v14's retained temporary-name index is part of a real v19")
    }

    // The payload file the queued row points at.
    let payloadURL = MeetingPaths(rootURL: root).handoffPayloadURL(
        meetingID: digestBearingMeeting, versionHash: fixtureVersionHash)
    try FileManager.default.createDirectory(
        at: payloadURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"schema":"fixture"}"#.utf8).write(to: payloadURL, options: .atomic)

    // The baseline is verified frozen, not assumed: a purpose this arc adds is
    // REJECTED before the upgrade. A baseline that accepts it was never a v19.
    #expect(throws: DatabaseError.self) {
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO cloud_spend_receipt
                      (id, timestamp, month_key, engine_id, model, purpose,
                       input_tokens, output_tokens, cost_usd)
                    VALUES ('rejected-before-the-arc', ?, '2026-08', 'e', 'm',
                            'notes-editor', 1, 1, 0.0)
                    """,
                arguments: [msDate()])
        }
    }
}

// MARK: - Snapshots

/// The pre-existing rows, in the v19 column shape, for the row-by-row
/// preservation comparison. `meeting_notes` is column-listed because v22 adds
/// three columns to it; every other table's shape is untouched by the chain.
private struct PreservationSnapshot: Equatable {
    var meetings: [Row]
    var segments: [Row]
    var notes: [Row]
    var receipts: [CloudSpendReceipt]
    var handoff: [Row]

    static let notesColumns =
        "meeting_id, markdown, language, generated_at, provenance, structured, memory_digest, scoped_alias_bindings"

    init(_ db: Database) throws {
        meetings = try Row.fetchAll(db, sql: "SELECT * FROM meeting ORDER BY id")
        segments = try Row.fetchAll(
            db, sql: "SELECT * FROM transcript_segment ORDER BY meeting_id, ord")
        notes = try Row.fetchAll(
            db, sql: "SELECT \(Self.notesColumns) FROM meeting_notes ORDER BY meeting_id")
        receipts = try CloudSpendReceipt.fetchAll(
            db, sql: "SELECT * FROM cloud_spend_receipt ORDER BY id")
        handoff = try Row.fetchAll(db, sql: "SELECT * FROM handoff_queue ORDER BY id")
    }
}

private func snapshot(at url: URL) throws -> PreservationSnapshot {
    let queue = try DatabaseQueue(path: url.path)
    return try queue.read(PreservationSnapshot.init)
}

/// The whole schema, ordering normalized — the equivalence oracle's subject.
private func schemaDump(at url: URL) throws -> [String] {
    let queue = try DatabaseQueue(path: url.path)
    return try queue.read { db in
        try String.fetchAll(
            db,
            sql: """
                SELECT type || '|' || name || '|' || COALESCE(sql, '')
                FROM sqlite_master ORDER BY type, name
                """)
    }
}

private func migrateThroughTheWholeChain(at url: URL) throws {
    let queue = try DatabaseQueue(path: url.path)
    try BlaiseDatabase.migrator.migrate(queue)
}

/// Reproduces the recorded production entry point — a v19 app with migration
/// v20 already applied and its `meeting_correction` table present and EMPTY —
/// and verifies it before the arc chain runs on top of it.
private func applyTheRecordedProductionResidue(at url: URL) throws {
    let queue = try DatabaseQueue(path: url.path)
    try BlaiseDatabase.migrator.migrate(queue, upTo: "v20")
    try queue.read { db in
        let applied = try BlaiseDatabase.migrator.appliedMigrations(db)
        let corrections = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meeting_correction")
        #expect(applied.last == "v20")
        #expect(corrections == 0, "the incident left the table present and empty")
    }
}

private let fullMigrationSequence = [
    "v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9", "v10", "v11", "v12", "v13", "v14",
    "v15", "v16", "v17", "v18", "v19", "v20", "v21", "v22",
]

// MARK: - The shared end-state battery

/// Every assertion §3 makes about the upgraded database, run identically on
/// both variants: the chain's two entry points must converge on one end state.
private func assertUpgradedEndState(at url: URL, before: PreservationSnapshot) throws {
    let queue = try DatabaseQueue(path: url.path)
    try queue.read { db in
        // The exact applied sequence, not only its last element.
        #expect(try BlaiseDatabase.migrator.appliedMigrations(db) == fullMigrationSequence)

        // Row-by-row preservation, in the v19 column shape. The counts are
        // asserted first: an empty snapshot would make every comparison below
        // pass without comparing anything.
        let after = try PreservationSnapshot(db)
        #expect(after.meetings.count == 2)
        #expect(after.notes.count == 2)
        #expect(after.segments.count == 2)
        #expect(after.receipts.count == frozenV19Purposes.count)
        #expect(after.handoff.count == 1)
        #expect(after.meetings == before.meetings)
        #expect(after.notes == before.notes)
        #expect(after.receipts == before.receipts, "every receipt value survives row by row")
        #expect(after.handoff == before.handoff)
        // The transcript is the hard floor: byte-equal, column by column.
        #expect(after.segments == before.segments)
        for (old, new) in zip(before.segments, after.segments) {
            #expect(Array((old["text"] as String).utf8) == Array((new["text"] as String).utf8))
        }

        // `meeting_correction` in its v20 shape.
        let correctionColumns = try Row.fetchAll(
            db, sql: "PRAGMA table_info(meeting_correction)")
        #expect(
            correctionColumns.map { $0["name"] as String } == [
                "id", "meeting_id", "kind", "section", "quoted_text", "occurrence",
                "user_text", "status", "created_at", "applied_at",
            ])
        let correctionFK = try Row.fetchAll(
            db, sql: "PRAGMA foreign_key_list(meeting_correction)")
        #expect(correctionFK.count == 1)
        #expect(correctionFK.first?["table"] == "meeting")
        #expect(correctionFK.first?["on_delete"] == "CASCADE")
        let correctionIndexed = try Row.fetchAll(
            db, sql: "PRAGMA index_info(idx_meeting_correction_meeting)"
        ).map { $0["name"] as String }
        #expect(correctionIndexed == ["meeting_id", "created_at", "id"])

        // The owed columns and the digest stamp, backfilled both ways.
        let notesColumns = try Row.fetchAll(db, sql: "PRAGMA table_info(meeting_notes)")
        for name in ["digest_edit_owed", "delivery_owed"] {
            let column = try #require(notesColumns.first { $0["name"] as String == name })
            #expect(column["notnull"] == 1)
            #expect((column["dflt_value"] as String?) == "0")
        }
        #expect(
            try String.fetchOne(
                db, sql: "SELECT digest_prompt_version FROM meeting_notes WHERE meeting_id = ?",
                arguments: [digestBearingMeeting]) == "md-v6")
        #expect(
            try Row.fetchOne(
                db, sql: "SELECT digest_prompt_version FROM meeting_notes WHERE meeting_id = ?",
                arguments: [digestLessMeeting])?["digest_prompt_version"] == nil,
            "a digest-less row stays NULL")
        #expect(
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM meeting_notes WHERE digest_edit_owed = 0 AND delivery_owed = 0")
                == 2)

        // Exactly the canonical explicit index survives, beside the primary
        // key's autoindex; no temporary index or table outlives the rebuilds.
        let receiptIndexes = try Row.fetchAll(db, sql: "PRAGMA index_list(cloud_spend_receipt)")
        #expect(
            Set(receiptIndexes.map { $0["name"] as String }) == [
                "sqlite_autoindex_cloud_spend_receipt_1",
                "index_cloud_spend_receipt_on_month_key",
            ])
        let explicit = receiptIndexes.filter { ($0["origin"] as String) == "c" }
        #expect(explicit.count == 1)
        #expect(explicit.first?["name"] == "index_cloud_spend_receipt_on_month_key")
        #expect(
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM sqlite_master
                    WHERE name LIKE '%\\_new\\_%' ESCAPE '\\'
                       OR name LIKE '%_v19_fixture'
                       OR name LIKE '%_v21'
                       OR name LIKE '%_v22'
                    """) == 0)

        // Structural integrity.
        #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        #expect(try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok")
    }

    // The widened CHECK accepts every legacy purpose plus both arc purposes,
    // and still rejects an unknown one.
    try queue.write { db in
        for purpose in frozenV19Purposes + ["notes-editor", "digest-editor"] {
            try db.execute(
                sql: """
                    INSERT INTO cloud_spend_receipt
                      (id, timestamp, month_key, engine_id, model, purpose,
                       input_tokens, output_tokens, cost_usd)
                    VALUES (?, ?, '2026-08', 'engine', 'model', ?, 1, 2, 0.0)
                    """,
                arguments: ["accepted-\(purpose)", msDate(), purpose])
        }
    }
    #expect(throws: DatabaseError.self) {
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO cloud_spend_receipt
                      (id, timestamp, month_key, engine_id, model, purpose,
                       input_tokens, output_tokens, cost_usd)
                    VALUES ('rejected-after-the-arc', ?, '2026-08', 'e', 'm',
                            'not-a-purpose', 1, 1, 0.0)
                    """,
                arguments: [msDate()])
        }
    }

    // A correction written after the upgrade round-trips through the store.
    let row = MeetingCorrection(
        meetingID: digestBearingMeeting, kind: .understanding, section: .summary,
        quotedText: "Ação concluída.", userText: "Ainda em aberto.", createdAt: msDate())
    try queue.write { db in try MeetingCorrectionStore.insert(db, row) }
    try queue.read { db in
        let roundTripped = try MeetingCorrectionStore.all(db, meetingID: digestBearingMeeting)
        #expect(roundTripped == [row])
    }
}

/// The normal app open of the migrated file — decoder and startup
/// compatibility evidence only. Run AFTER the preservation snapshot, because
/// the open runs the startup sweeps and an intentional startup transition must
/// never read as migration corruption.
private func assertTheAppOpensTheMigratedFile(root: URL) async throws {
    let database = try BlaiseDatabase(rootURL: root)
    #expect(try await HealthCheck.run(database).schemaVersion == 22)
    let notes = try #require(
        try await NotesRepository(database: database).fetch(meetingID: digestBearingMeeting))
    #expect(notes.memoryDigest == fixtureDigest)
    #expect(notes.structured.summary == "Ação concluída.")
    #expect(notes.digestPromptVersion == "md-v6")
    let meeting = try #require(
        try await MeetingRepository(database: database).fetch(digestBearingMeeting))
    #expect(meeting.title == "Vexatron Labs — revisão do field kit")
    // The sweep's intentional transition, named so it is never mistaken for
    // migration damage: the interrupted delivery claim is reset to pending.
    #expect(
        try await database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT state FROM handoff_queue WHERE id = 'n6-handoff-1'")
        } == "pending")
}

// MARK: - M-1 / M-2

@Suite struct N6MigrationChainTests {
    @Test("M-1: a populated, frozen-shape v19 database upgrades through the whole arc chain")
    func cleanChainFromV19() async throws {
        let root = try makeTempRoot()
        let url = root.appendingPathComponent("blaise.sqlite")
        try buildPopulatedFrozenV19(root: root)

        // Taken BEFORE the chain — a post-upgrade snapshot would compare the
        // migrated database against itself — and before the normal-path open
        // below, whose startup sweeps make an intentional transition that must
        // not read as migration corruption.
        let before = try snapshot(at: url)

        try migrateThroughTheWholeChain(at: url)

        try assertUpgradedEndState(at: url, before: before)
        try await assertTheAppOpensTheMigratedFile(root: root)
    }

    @Test("M-2: the production-residue chain converges on the identical schema")
    func productionResidueChain() async throws {
        let residueRoot = try makeTempRoot()
        let residueURL = residueRoot.appendingPathComponent("blaise.sqlite")
        try buildPopulatedFrozenV19(root: residueRoot)
        try applyTheRecordedProductionResidue(at: residueURL)
        let residueBefore = try snapshot(at: residueURL)

        // ONE full migrate — v21 and v22 only, from that exact state.
        try migrateThroughTheWholeChain(at: residueURL)

        try assertUpgradedEndState(at: residueURL, before: residueBefore)
        try await assertTheAppOpensTheMigratedFile(root: residueRoot)

        // The equivalence oracle: the clean chain and the residue chain end on
        // the SAME schema. Production is not on a variant of the arc's schema.
        let cleanRoot = try makeTempRoot()
        let cleanURL = cleanRoot.appendingPathComponent("blaise.sqlite")
        try buildPopulatedFrozenV19(root: cleanRoot)
        try migrateThroughTheWholeChain(at: cleanURL)
        let cleanSchema = try schemaDump(at: cleanURL)
        #expect(cleanSchema.count > 20, "an empty dump would make the equivalence vacuous")
        #expect(cleanSchema == (try schemaDump(at: residueURL)))
    }
}
