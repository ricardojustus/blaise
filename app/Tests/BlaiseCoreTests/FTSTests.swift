import Foundation
import Testing
@testable import BlaiseCore

@Suite struct FTSTests {
    private func seededDatabase() async throws -> (BlaiseDatabase, Meeting, [TranscriptSegment]) {
        let database = try makeDatabase()
        let meeting = makeMeeting(title: "Reunião de produto")
        try await MeetingRepository(database: database).create(meeting)
        let segments = try await TranscriptRepository(database: database).replaceAllSegments(
            meetingID: meeting.id,
            with: [
                TranscriptSegment(meetingID: meeting.id, ord: 0, startSeconds: 0.0, endSeconds: 6.5, speakerLabel: "S1", speakerName: "Sam", text: "Na reunião de hoje revisamos o orçamento do trimestre"),
                TranscriptSegment(meetingID: meeting.id, ord: 1, startSeconds: 6.5, endSeconds: 12.0, text: "Ficaram definidas as ações para a próxima sprint"),
                TranscriptSegment(meetingID: meeting.id, ord: 2, startSeconds: 12.0, endSeconds: 18.0, text: "And then we switched to English mid-sentence"),
            ]
        )
        return (database, meeting, segments)
    }

    @Test func ptAccentSearchMatchesWithAndWithoutDiacritics() async throws {
        let (database, meeting, segments) = try await seededDatabase()
        let repo = TranscriptRepository(database: database)

        // With diacritics and without — remove_diacritics 2 must fold both.
        for query in ["reunião", "reuniao"] {
            let hits = try await repo.search(query)
            #expect(hits.count == 1, "query \(query)")
            let hit = try #require(hits.first)
            #expect(hit.meetingID == meeting.id)
            #expect(hit.ord == 0)
            #expect(hit.startSeconds == 0.0)
            #expect(hit.segmentID == segments[0].id)
            #expect(hit.snippet.contains("\(SearchHit.matchStartDelimiter)reunião\(SearchHit.matchEndDelimiter)"))
        }
        for query in ["ações", "acoes"] {
            let hits = try await repo.search(query)
            #expect(hits.count == 1, "query \(query)")
            #expect(hits.first?.ord == 1)
        }
        let english = try await repo.search("English")
        #expect(english.count == 1)
        let none = try await repo.search("blockchain")
        #expect(none.isEmpty)
        let empty = try await repo.search("   ")
        #expect(empty.isEmpty)
    }

    @Test func replaceAllSegmentsSwapsFTSContent() async throws {
        let (database, meeting, _) = try await seededDatabase()
        let repo = TranscriptRepository(database: database)

        try await repo.replaceAllSegments(
            meetingID: meeting.id,
            with: [TranscriptSegment(meetingID: meeting.id, ord: 0, startSeconds: 0, endSeconds: 4, text: "Decisão final aprovada")]
        )
        // Old text no longer matches; new text does.
        #expect(try await repo.search("reunião").isEmpty)
        #expect(try await repo.search("orçamento").isEmpty)
        for query in ["decisão", "decisao"] {
            #expect(try await repo.search(query).count == 1, "query \(query)")
        }
        #expect(try database.count("transcript_segment") == 1)
        try database.checkFTSIntegrity()
    }

    @Test func deleteTranscriptRemovesSegmentsAndFTSOnly() async throws {
        let (database, meeting, _) = try await seededDatabase()
        try await NotesRepository(database: database).upsert(makeNotes(meetingID: meeting.id))

        try await TranscriptRepository(database: database).deleteTranscript(meetingID: meeting.id)

        #expect(try database.count("transcript_segment") == 0)
        #expect(try database.rawFTSMatchCount("reuniao") == 0)
        try database.checkFTSIntegrity()
        // Notes and meeting row are untouched.
        #expect(try database.count("meeting_notes") == 1)
        #expect(try await MeetingRepository(database: database).fetch(meeting.id) != nil)
    }

    @Test func searchHitConstructedFromRealQueryRoundTripsCodable() async throws {
        let (database, _, _) = try await seededDatabase()
        let hits = try await TranscriptRepository(database: database).search("orçamento")
        let hit = try #require(hits.first)
        let decoded = try JSONDecoder().decode(SearchHit.self, from: JSONEncoder().encode(hit))
        #expect(decoded == hit)
    }
}
