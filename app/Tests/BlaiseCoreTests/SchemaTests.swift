import Foundation
import GRDB
import Testing
@testable import BlaiseCore

@Suite struct SchemaTests {
    @Test func migrationCreatesAllTables() throws {
        let database = try makeDatabase()
        let tables = try database.tableNames()
        for expected in ["meeting", "transcript_segment", "meeting_notes", "transcript_fts", "handoff_queue", "app_setting", "action_item_state", "name_correction", "speaker_rename", "processing_queue", "notes_fts"] {
            #expect(tables.contains(expected), "missing table \(expected)")
        }
    }

    @Test func walModeActive() throws {
        let database = try makeDatabase()
        let mode = try database.pool.read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode")
        }
        #expect(mode?.lowercased() == "wal")
    }

    @Test func meetingSourceCheckRejectsUnknownValue() throws {
        let database = try makeDatabase()
        #expect(throws: DatabaseError.self) {
            try database.pool.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO meeting (id, title, started_at, source, status, attendees, created_at, updated_at)
                        VALUES (?, 'bad', ?, 'skype', 'ready', '[]', ?, ?)
                        """,
                    arguments: [ULID.generate(), msDate(), msDate(), msDate()]
                )
            }
        }
    }

    @Test func meetingStatusHasNoCheckConstraint() throws {
        // Deliberate: status vocabulary evolves; the Swift enum is the boundary.
        let database = try makeDatabase()
        try database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO meeting (id, title, started_at, source, status, attendees, created_at, updated_at)
                    VALUES (?, 'future status', ?, 'meet', 'someFutureStatus', '[]', ?, ?)
                    """,
                arguments: [ULID.generate(), msDate(), msDate(), msDate()]
            )
        }
        #expect(try database.count("meeting") == 1)
    }

    @Test func handoffStateCheckRejectsUnknownValue() async throws {
        let database = try makeDatabase()
        let meeting = makeMeeting()
        try await MeetingRepository(database: database).create(meeting)
        #expect(throws: DatabaseError.self) {
            try database.pool.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO handoff_queue (id, meeting_id, payload_path, version_hash, state, attempts, created_at, created_seq)
                        VALUES (?, ?, 'p.json', 'h1', 'bogus', 0, ?, 1)
                        """,
                    arguments: [ULID.generate(), meeting.id, msDate()]
                )
            }
        }
    }

    @Test func sqlLevelCascadeDeletesSegmentsAndNotes() async throws {
        let database = try makeDatabase()
        let meeting = makeMeeting()
        try await MeetingRepository(database: database).create(meeting)
        try await TranscriptRepository(database: database).replaceAllSegments(
            meetingID: meeting.id,
            with: [
                TranscriptSegment(meetingID: meeting.id, ord: 0, startSeconds: 0, endSeconds: 5, text: "decisão importante da reunião"),
                TranscriptSegment(meetingID: meeting.id, ord: 1, startSeconds: 5, endSeconds: 9, text: "próximos passos"),
            ]
        )
        try await NotesRepository(database: database).upsert(makeNotes(meetingID: meeting.id))
        #expect(try database.count("transcript_segment") == 2)
        #expect(try database.count("meeting_notes") == 1)

        // No deletion API exists in V1 — this is a raw SQL probe of the schema's FK behavior.
        try await database.pool.write { db in
            try db.execute(sql: "DELETE FROM meeting WHERE id = ?", arguments: [meeting.id])
        }
        #expect(try database.count("transcript_segment") == 0)
        #expect(try database.count("meeting_notes") == 0)
        #expect(try database.rawFTSMatchCount("reunião") == 0)
        try database.checkFTSIntegrity()
    }

    @Test func restrictBlocksMeetingDeleteWithUndeliveredHandoff() async throws {
        let database = try makeDatabase()
        let (meeting, hash, path) = try await makeEnqueueableMeeting(database)
        try await HandoffRepository(database: database).enqueue(meetingID: meeting.id, versionHash: hash, payloadPath: path)
        #expect(throws: DatabaseError.self) {
            try database.pool.write { db in
                try db.execute(sql: "DELETE FROM meeting WHERE id = ?", arguments: [meeting.id])
            }
        }
        #expect(try database.count("meeting") == 1)
    }

    @Test func startupSweepsResetStaleStates() async throws {
        let root = try makeTempRoot()
        let database = try BlaiseDatabase(rootURL: root)
        let meetings = MeetingRepository(database: database)

        let recording = makeMeeting(title: "stale recording", status: .recording)
        let processing = makeMeeting(title: "stale processing", status: .processing)
        let ready = makeMeeting(title: "untouched ready", status: .ready)
        let failed = makeMeeting(title: "untouched failed", status: .failed)
        for m in [recording, processing, ready, failed] {
            try await meetings.create(m)
        }

        let handoffs = HandoffRepository(database: database)
        let path = try plantPayload(database, meetingID: ready.id, versionHash: "h-sweep")
        let item = try await handoffs.enqueue(meetingID: ready.id, versionHash: "h-sweep", payloadPath: path)
        try await handoffs.transition(item.id, to: .delivering)
        let path2 = try plantPayload(database, meetingID: ready.id, versionHash: "h-delivered")
        let delivered = try await handoffs.enqueue(meetingID: ready.id, versionHash: "h-delivered", payloadPath: path2)
        try await handoffs.transition(delivered.id, to: .delivered)

        // Reopen at the same root: the startup sweeps run again.
        let reopened = try BlaiseDatabase(rootURL: root)
        let repo = MeetingRepository(database: reopened)

        let sweptRecording = try #require(try await repo.fetch(recording.id))
        #expect(sweptRecording.status == .failed)
        #expect(sweptRecording.lastProcessingError == "interrupted")

        let sweptProcessing = try #require(try await repo.fetch(processing.id))
        #expect(sweptProcessing.status == .failed)
        #expect(sweptProcessing.lastProcessingError == "interrupted")

        // The sweep never promotes to ready, and never touches terminal states.
        let untouchedReady = try #require(try await repo.fetch(ready.id))
        #expect(untouchedReady.status == .ready)
        #expect(untouchedReady.lastProcessingError == nil)
        let untouchedFailed = try #require(try await repo.fetch(failed.id))
        #expect(untouchedFailed.status == .failed)

        let sweptItem = try #require(try await reopened.pool.read { db in
            try HandoffItem.fetchOne(db, key: item.id)
        })
        #expect(sweptItem.state == .pending, "stale delivering claim must reset to pending")
        let stillDelivered = try #require(try await reopened.pool.read { db in
            try HandoffItem.fetchOne(db, key: delivered.id)
        })
        #expect(stillDelivered.state == .delivered, "delivered is terminal — sweep must not touch it")
    }

    @Test func healthCheckReportsSchemaAndJournal() async throws {
        let database = try makeDatabase()
        let health = try await HealthCheck.run(database)
        // schemaVersion = COUNT of applied migrations: v1 + v2 (C2) + v3 (C6) +
        // v4/v5 (C10) + v6 (C11) + v7 (V1.1) + v8 (C14) + v9 (G7) + v10 (G2) +
        // v11 (G10) + v12 (G11) + v13 (G12: meeting.title_source) + v14 (G14:
        // memory_digest column + the cloud_spend_receipt CHECK-rebuild) + v15
        // (F1: processing_queue substrate) + v16 (F2: notes_fts) + v17 (T3.1:
        // scoped_alias_bindings column) = 17.
        #expect(health.schemaVersion == 17)
        #expect(health.journalMode == "wal")
    }
}

// Impl-audit round-1 M4: pin the persisted structured JSON format so a
// CodingKeys/GRDB encoding drift cannot silently orphan stored rows.
@Suite struct PersistedStructuredFormatTests {
    @Test func structuredColumnJSONFormatIsPinned() async throws {
        let database = try makeDatabase()
        let meeting = makeMeeting()
        try await MeetingRepository(database: database).create(meeting)
        var notes = makeNotes(meetingID: meeting.id)
        notes.structured = NotesStructured(
            title: "T", summary: "S", detailedNotes: "D",
            decisions: ["d1"],
            actionItems: [ActionItem(owner: "Ana", text: "fazer x")],
            userActionItems: [ActionItem(owner: "Sam", text: "rever y")]
        )
        try await NotesRepository(database: database).upsert(notes)
        let raw = try await database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT structured FROM meeting_notes WHERE meeting_id = ?", arguments: [meeting.id])
        }
        let json = try #require(raw)
        for key in ["\"title\"", "\"summary\"", "\"detailed_notes\"", "\"decisions\"", "\"action_items\"", "\"user_action_items\"", "\"owner\"", "\"text\""] {
            #expect(json.contains(key), "persisted JSON must contain pinned key \(key); got: \(json)")
        }
    }
}
