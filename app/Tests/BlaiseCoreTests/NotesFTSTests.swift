import Foundation
import GRDB
import Testing

@testable import BlaiseCore

/// F2 — full-text search over NOTES (the standalone `notes_fts` index + the
/// meeting_id-keyed triggers + `NotesRepository.searchNotes` + the model merge).
/// Fictional PT/EN business vocabulary only.
@Suite struct NotesFTSTests {

    // 1. Diacritics fold both ways (parity with transcript_fts: remove_diacritics 2).
    @Test func notesDiacriticsFoldBothWays() async throws {
        let database = try makeDatabase()
        let meeting = makeMeeting(title: "Planejamento")
        try await MeetingRepository(database: database).create(meeting)
        try await NotesRepository(database: database).upsert(
            makeNotes(meetingID: meeting.id, markdown: "## Resumo\nDecisões e ações do trimestre aprovadas"))

        let repo = NotesRepository(database: database)
        for query in ["decisões", "decisoes", "ações", "acoes"] {
            let hits = try await repo.searchNotes(query)
            #expect(hits.count == 1, "query \(query)")
            #expect(hits.first?.meetingID == meeting.id, "query \(query)")
        }
        #expect(try await repo.searchNotes("blockchain").isEmpty)
        #expect(try await repo.searchNotes("   ").isEmpty)
    }

    // 2. Regeneration re-index (load-bearing) — drives the REAL upsert so it
    // exercises GRDB's ON CONFLICT DO UPDATE → SQLite UPDATE → notes_fts_au.
    @Test func regeneratingNotesReindexesViaUpdateTrigger() async throws {
        let database = try makeDatabase()
        let meeting = makeMeeting()
        try await MeetingRepository(database: database).create(meeting)
        let repo = NotesRepository(database: database)

        try await repo.upsert(makeNotes(meetingID: meeting.id, markdown: "Discutimos o orçamento inicial"))
        #expect(try await repo.searchNotes("orçamento").count == 1)

        // Regenerate: a real upsert OVERWRITE of the single row.
        try await repo.upsert(makeNotes(meetingID: meeting.id, markdown: "Aprovamos o cronograma final"))
        #expect(try await repo.searchNotes("orçamento").isEmpty, "old text no longer indexed")
        #expect(try await repo.searchNotes("cronograma").count == 1, "new text indexed")
        #expect(try database.count("notes_fts") == 1, "exactly one row — no orphan, no duplicate")
        try database.checkNotesFTSIntegrity()
    }

    // 3. Cascade-delete cleanup + index independence.
    @Test func deletingMeetingClearsNotesFTSAndIndexesAreIndependent() async throws {
        let database = try makeDatabase()
        let meeting = makeMeeting(title: "Reunião")
        try await MeetingRepository(database: database).create(meeting)
        try await NotesRepository(database: database).upsert(
            makeNotes(meetingID: meeting.id, markdown: "Notas com a palavra cronograma"))
        try await TranscriptRepository(database: database).replaceAllSegments(
            meetingID: meeting.id,
            with: [TranscriptSegment(meetingID: meeting.id, ord: 0, startSeconds: 0, endSeconds: 4, text: "transcript orçamento")])
        #expect(try database.rawNotesFTSMatchCount("cronograma") == 1)
        // Independence, both directions: a notes term is absent from the
        // transcript index, and a transcript term is absent from the notes index.
        #expect(try database.rawFTSMatchCount("cronograma") == 0, "notes term absent from transcript_fts")
        #expect(try database.rawNotesFTSMatchCount("orçamento") == 0, "transcript term absent from notes_fts")

        // Deleting the TRANSCRIPT must not touch notes_fts.
        try await TranscriptRepository(database: database).deleteTranscript(meetingID: meeting.id)
        #expect(try database.rawNotesFTSMatchCount("cronograma") == 1, "notes index untouched by transcript delete")
        #expect(try database.rawFTSMatchCount("orçamento") == 0, "transcript index cleared")

        // Deleting the MEETING cascades → meeting_notes row → notes_fts_ad.
        try await database.pool.write { db in
            try db.execute(sql: "DELETE FROM meeting WHERE id = ?", arguments: [meeting.id])
        }
        #expect(try database.rawNotesFTSMatchCount("cronograma") == 0, "cascade cleared the notes index")
        #expect(try database.count("notes_fts") == 0)
        try database.checkNotesFTSIntegrity()
    }

    // 4. v16 backfills notes that already existed at migration time.
    @Test func v16BackfillsExistingNotes() throws {
        let url = try makeTempRoot().appendingPathComponent("v15-populated.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try BlaiseDatabase.migrator.migrate(queue, upTo: "v15")
        let meetingID = ULID.generate()
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO meeting (id, title, started_at, source, status, attendees, created_at, updated_at)
                    VALUES (?, 'Backfill meeting', ?, 'meet', 'ready', '[]', ?, ?)
                    """,
                arguments: [meetingID, msDate(), msDate(), msDate()])
            try db.execute(
                sql: """
                    INSERT INTO meeting_notes (meeting_id, markdown, language, generated_at, provenance, structured)
                    VALUES (?, 'Notas antigas: revisar o orçamento do trimestre', 'pt-BR', ?, '{}', '{}')
                    """,
                arguments: [meetingID, msDate()])
        }

        // notes_fts does not exist before v16; migrating creates it AND backfills.
        try BlaiseDatabase.migrator.migrate(queue)

        try queue.read { db in
            let count = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM notes_fts WHERE notes_fts MATCH 'orçamento'")
            #expect(count == 1, "the pre-existing note was backfilled into notes_fts")
        }
    }

    // 5. Snippet wraps the STORED token (not the query spelling) + Codable round-trip.
    @Test func notesSnippetWrapsStoredTokenAndHitRoundTrips() async throws {
        let database = try makeDatabase()
        let meeting = makeMeeting()
        try await MeetingRepository(database: database).create(meeting)
        try await NotesRepository(database: database).upsert(
            makeNotes(meetingID: meeting.id, markdown: "As decisões foram registradas"))

        // Query WITHOUT diacritics; the snippet wraps the stored spelling "decisões".
        let hits = try await NotesRepository(database: database).searchNotes("decisoes")
        let hit = try #require(hits.first)
        #expect(hit.snippet.contains("\(SearchHit.matchStartDelimiter)decisões\(SearchHit.matchEndDelimiter)"))

        let decoded = try JSONDecoder().decode(NotesSearchHit.self, from: JSONEncoder().encode(hit))
        #expect(decoded == hit)
    }

    // 6a. Equal-bm25 notes hits order deterministically by the meeting_id tiebreak.
    @Test func equalScoreNotesHitsOrderByMeetingID() async throws {
        let database = try makeDatabase()
        let meetingRepo = MeetingRepository(database: database)
        let notesRepo = NotesRepository(database: database)
        let m1 = makeMeeting()
        let m2 = makeMeeting()
        try await meetingRepo.create(m1)
        try await meetingRepo.create(m2)
        // Identical notes text → identical bm25 → only the meeting_id tiebreak decides.
        let markdown = "Pauta: revisar o cronograma e o orçamento do trimestre"
        try await notesRepo.upsert(makeNotes(meetingID: m1.id, markdown: markdown))
        try await notesRepo.upsert(makeNotes(meetingID: m2.id, markdown: markdown))

        let hits = try await notesRepo.searchNotes("cronograma")
        #expect(hits.count == 2)
        #expect(hits.map(\.meetingID) == [m1.id, m2.id].sorted(), "ascending meeting_id tiebreak")
    }

    // 6b. The model merges both surfaces into separate groups (Notes + Transcript).
    @MainActor @Test func modelSearchReturnsBothNotesAndTranscriptGroups() async throws {
        let database = try makeDatabase()
        let meeting = makeMeeting(title: "Sync")
        try await MeetingRepository(database: database).create(meeting)
        try await NotesRepository(database: database).upsert(
            makeNotes(meetingID: meeting.id, markdown: "Notas: decidimos o cronograma"))
        try await TranscriptRepository(database: database).replaceAllSegments(
            meetingID: meeting.id,
            with: [TranscriptSegment(meetingID: meeting.id, ord: 0, startSeconds: 0, endSeconds: 4, text: "falamos sobre o cronograma de entregas")])

        let model = LibraryModel(database: database)
        let results = await model.search("cronograma")
        #expect(results.notes.count == 1, "notes group populated")
        #expect(results.transcripts.count == 1, "transcript group populated")
        #expect(results.notes.first?.hit.meetingID == meeting.id)
        #expect(results.notes.first?.meetingTitle == "Sync")
        #expect(!results.isEmpty)

        // An empty query yields an empty result on both surfaces.
        let empty = await model.search("   ")
        #expect(empty.isEmpty)
    }

    // 7. Integrity probe stays green across a sequence of upserts and deletes.
    @Test func notesFTSIntegrityHoldsAcrossUpsertsAndDeletes() async throws {
        let database = try makeDatabase()
        let meetingRepo = MeetingRepository(database: database)
        let notesRepo = NotesRepository(database: database)
        for index in 0..<3 {
            let meeting = makeMeeting()
            try await meetingRepo.create(meeting)
            try await notesRepo.upsert(makeNotes(meetingID: meeting.id, markdown: "Item \(index): cronograma"))
            try await notesRepo.upsert(makeNotes(meetingID: meeting.id, markdown: "Item \(index): orçamento revisado"))
            try await database.pool.write { db in
                try db.execute(sql: "DELETE FROM meeting WHERE id = ?", arguments: [meeting.id])
            }
        }
        #expect(try database.count("notes_fts") == 0)
        try database.checkNotesFTSIntegrity()
    }
}
