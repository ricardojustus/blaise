import Foundation
import Testing
@testable import BlaiseCore

@Suite struct RepositoryTests {
    @Test func meetingCreateFetchRoundTrip() async throws {
        let database = try makeDatabase()
        let repo = MeetingRepository(database: database)
        var meeting = makeMeeting(
            title: "Pitch GameMaker",
            attendees: [
                Attendee(name: "Sam Rivera", email: "sam.rivera@vexatron.test", source: .calendar),
                Attendee(name: "Convidado", source: .meetExtension),
            ]
        )
        meeting.endedAt = msDate(1_770_000_500.25)
        meeting.dominantLanguage = "pt-BR"
        meeting.asrProvenance = ASRProvenance(
            engine: "test", model: "m", runtime: "rt", engineVersion: "1.0", transcribedAt: msDate()
        )
        try await repo.create(meeting)
        let fetched = try #require(try await repo.fetch(meeting.id))
        #expect(fetched == meeting)
        #expect(try await repo.fetch(ULID.generate()) == nil)
    }

    @Test func meetingUpdatePersistsAndBumpsUpdatedAt() async throws {
        let database = try makeDatabase()
        let repo = MeetingRepository(database: database)
        let original = makeMeeting(title: "Before")
        try await repo.create(original)

        var changed = original
        changed.title = "After"
        changed.status = .failed
        changed.lastProcessingError = "asr crashed"
        try await repo.update(changed)

        let fetched = try #require(try await repo.fetch(original.id))
        #expect(fetched.title == "After")
        #expect(fetched.status == .failed)
        #expect(fetched.lastProcessingError == "asr crashed")
        #expect(fetched.updatedAt > original.updatedAt)
    }

    @Test func listByRecencyOrdersByStartedAtThenID() async throws {
        let database = try makeDatabase()
        let repo = MeetingRepository(database: database)
        let oldest = makeMeeting(title: "oldest", startedAt: msDate(1_700_000_000))
        let tieEarlierID = makeMeeting(title: "tie a", startedAt: msDate(1_700_000_100))
        let tieLaterID = makeMeeting(title: "tie b", startedAt: msDate(1_700_000_100))
        #expect(tieLaterID.id > tieEarlierID.id, "ULIDs are time-ordered, so creation order gives the tiebreak")
        for m in [tieLaterID, oldest, tieEarlierID] {
            try await repo.create(m)
        }
        let listed = try await repo.listByRecency()
        #expect(listed.map(\.id) == [tieLaterID.id, tieEarlierID.id, oldest.id])
    }

    @Test func notesUpsertAndFetch() async throws {
        let database = try makeDatabase()
        let meeting = makeMeeting()
        try await MeetingRepository(database: database).create(meeting)
        let repo = NotesRepository(database: database)

        let v1 = makeNotes(meetingID: meeting.id, markdown: "# v1")
        try await repo.upsert(v1)
        #expect(try await repo.fetch(meetingID: meeting.id) == v1)

        var v2 = v1
        v2.markdown = "# v2 — regenerated"
        v2.generatedAt = msDate(1_780_000_000.5)
        try await repo.upsert(v2)
        #expect(try await repo.fetch(meetingID: meeting.id) == v2)
        #expect(try database.count("meeting_notes") == 1)
        #expect(try await repo.fetch(meetingID: ULID.generate()) == nil)
    }

    @Test func settingsRoundTrip() async throws {
        let database = try makeDatabase()
        let store = SettingsStore(database: database)

        try await store.set("asr.engine", to: "whisper-local")
        #expect(try await store.get("asr.engine") == "whisper-local")

        try await store.set("retention.days", to: 30)
        #expect(try await store.get("retention.days") == 30)

        // Overwrite is an upsert.
        try await store.set("asr.engine", to: "parakeet")
        #expect(try await store.get("asr.engine") == "parakeet")

        struct EngineConfig: Codable, Sendable, Equatable {
            var name: String
            var temperature: Double
        }
        let config = EngineConfig(name: "synth", temperature: 0.2)
        try await store.set("notes.engine", to: config)
        #expect(try await store.get("notes.engine") == config)

        let missing: String? = try await store.get("does.not.exist")
        #expect(missing == nil)
    }

    @Test func audioConstantsRetainedFormatMatchesD7() {
        let format = AudioConstants.retainedFormat
        #expect(format.codec == "AAC-LC")
        #expect(format.bitRate == 32_000)
        #expect(format.channelCount == 1)
        #expect(format.fileExtension == "m4a")
    }

    @Test func codableRoundTrips() throws {
        var meeting = makeMeeting(
            attendees: [Attendee(name: "Sam", email: "sam.rivera@vexatron.test", source: .manual)]
        )
        meeting.asrProvenance = ASRProvenance(engine: "e", model: "m", runtime: "r", engineVersion: "v", transcribedAt: msDate())
        meeting.dominantLanguage = "pt-BR"
        let decodedMeeting = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(meeting))
        #expect(decodedMeeting == meeting)

        let item = HandoffItem(
            id: ULID.generate(),
            meetingID: meeting.id,
            payloadPath: "meetings/x/handoff/h.json",
            versionHash: "h",
            state: .failed,
            attempts: 3,
            createdSeq: 7,
            createdAt: msDate(),
            lastAttemptAt: msDate(),
            lastError: "queue jammed"
        )
        let decodedItem = try JSONDecoder().decode(HandoffItem.self, from: JSONEncoder().encode(item))
        #expect(decodedItem == item)

        let notes = makeNotes(meetingID: meeting.id)
        let decodedNotes = try JSONDecoder().decode(MeetingNotes.self, from: JSONEncoder().encode(notes))
        #expect(decodedNotes == notes)

        let segment = TranscriptSegment(id: 9, meetingID: meeting.id, ord: 0, startSeconds: 1.5, endSeconds: 2.5, text: "olá")
        #expect(segment.speakerLabel == TranscriptSegment.unattributed)
        let decodedSegment = try JSONDecoder().decode(TranscriptSegment.self, from: JSONEncoder().encode(segment))
        #expect(decodedSegment == segment)
    }
}
