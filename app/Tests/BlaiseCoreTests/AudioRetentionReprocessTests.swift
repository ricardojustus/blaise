import Foundation
import GRDB
import Testing
@testable import BlaiseCore

// G16 §3 (specs/g16_audio_retention.md): once a meeting's audio is deleted,
// every full reprocess is refused — never downgraded to a notes rewrite. A
// user dispatch gets `PipelineDispatchError.audioDeleted`; an automatic origin
// also leaves a `processingNote` and never touches `status` /
// `lastProcessingError`; the queue drops marked meetings at admission and
// completes (not fails) a job whose meeting was marked after admission;
// Reprocess All excludes and counts marked meetings.

private func rawColumn(_ database: BlaiseDatabase, _ column: String, _ id: MeetingID) async throws -> String? {
    try await database.pool.read { db in
        try String.fetchOne(db, sql: "SELECT \(column) FROM meeting WHERE id = ?", arguments: [id])
    }
}

private func insertMeeting(_ database: BlaiseDatabase, status: MeetingStatus = .ready) async throws -> MeetingID {
    let meeting = makeMeeting(status: status)
    try database.paths.createMeetingDirectory(meeting.id)
    try await MeetingRepository(database: database).create(meeting)
    return meeting.id
}

private func jobs(_ database: BlaiseDatabase, _ meetingID: MeetingID) async throws -> [ProcessingJob] {
    try await database.pool.read { db in
        try ProcessingJob.filter(Column("meeting_id") == meetingID).fetchAll(db)
    }
}

@Suite struct AudioRetentionReprocessTests {

    /// A processed `ready` meeting whose audio was then deleted (manual).
    private func readyMeetingWithDeletedAudio() async throws -> (PipelineHarness, MeetingID) {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        try await harness.pipeline.deleteAudio(meetingID: meeting.id, origin: .manual)
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.status == .ready)
        #expect(stored.audioDeletedAt != nil)
        return (harness, meeting.id)
    }

    // MARK: dispatchProcessing

    @Test("user dispatch of a marked meeting throws audioDeleted; no note, status untouched")
    func userDispatchRefused() async throws {
        let (harness, id) = try await readyMeetingWithDeletedAudio()
        let updatedBefore = try await rawColumn(harness.database, "updated_at", id)

        await #expect(throws: PipelineDispatchError.audioDeleted(id)) {
            try await harness.pipeline.dispatchProcessing(meetingID: id)
        }

        let stored = try #require(try await harness.meeting(id))
        #expect(stored.status == .ready)
        #expect(stored.lastProcessingError == nil)
        #expect(stored.processingNote == nil)
        #expect(try await rawColumn(harness.database, "updated_at", id) == updatedBefore)
    }

    @Test("automatic dispatch of a marked meeting leaves the note; status/lastProcessingError/updated_at untouched")
    func automaticDispatchWritesNote() async throws {
        let (harness, id) = try await readyMeetingWithDeletedAudio()
        let updatedBefore = try await rawColumn(harness.database, "updated_at", id)

        await #expect(throws: PipelineDispatchError.audioDeleted(id)) {
            try await harness.pipeline.dispatchProcessing(
                meetingID: id, refuseCancelled: true, noteIfAudioDeleted: true)
        }

        let stored = try #require(try await harness.meeting(id))
        #expect(stored.status == .ready)
        #expect(stored.lastProcessingError == nil)
        #expect(stored.processingNote == AudioDeletedReprocessNote.text)
        #expect(try await rawColumn(harness.database, "updated_at", id) == updatedBefore)
    }

    @Test("the automatic note never replaces a capture-recovery note")
    func captureRecoveryNoteOutranks() async throws {
        let (harness, id) = try await readyMeetingWithDeletedAudio()
        let recovery = CaptureRecovery.notePrefix + " test"
        try await harness.database.pool.write { db in
            try db.execute(
                sql: "UPDATE meeting SET processing_note = ? WHERE id = ?", arguments: [recovery, id])
        }
        await #expect(throws: PipelineDispatchError.audioDeleted(id)) {
            try await harness.pipeline.dispatchProcessing(
                meetingID: id, refuseCancelled: true, noteIfAudioDeleted: true)
        }
        #expect(try await harness.meeting(id)?.processingNote == recovery)
    }

    // MARK: Processing queue

    @Test("enqueue drops a marked meeting; only an automatic origin leaves the note")
    func enqueueDropsMarkedMeeting() async throws {
        let database = try makeDatabase()
        let userID = try await insertMeeting(database)
        let autoID = try await insertMeeting(database)
        let reprocessID = try await insertMeeting(database)
        for id in [userID, autoID, reprocessID] {
            try await AudioRetention.markDeleted(database: database, meetingID: id, reason: .manual)
        }
        let updatedBefore = try await rawColumn(database, "updated_at", autoID)
        let worker = ProcessingQueueWorker(database: database, runJob: { _, _ in
            Issue.record("a marked meeting must never reach the executor")
        })

        #expect(await worker.enqueue(userID, origin: .user) == nil)
        #expect(await worker.enqueue(autoID, origin: .auto) == nil)
        #expect(await worker.enqueue(reprocessID, origin: .reprocessAll) == nil)
        await worker.waitUntilSettled()

        for id in [userID, autoID, reprocessID] {
            #expect(try await jobs(database, id).isEmpty)
        }
        let repo = MeetingRepository(database: database)
        #expect(try await repo.fetch(userID)?.processingNote == nil)
        #expect(try await repo.fetch(reprocessID)?.processingNote == nil)
        let auto = try #require(try await repo.fetch(autoID))
        #expect(auto.processingNote == AudioDeletedReprocessNote.text)
        #expect(auto.status == .ready)
        #expect(auto.lastProcessingError == nil)
        #expect(try await rawColumn(database, "updated_at", autoID) == updatedBefore)
    }

    @Test("a Meet-event re-mint (QueueProcessingDispatcher) on a marked meeting leaves the note, no job")
    func meetEventRemintWritesNote() async throws {
        let database = try makeDatabase()
        let id = try await insertMeeting(database)
        try await AudioRetention.markDeleted(database: database, meetingID: id, reason: .manual)
        let worker = ProcessingQueueWorker(database: database, runJob: { _, _ in
            Issue.record("a marked meeting must never reach the executor")
        })
        await QueueProcessingDispatcher(queue: worker).dispatch(meetingID: id)
        await worker.waitUntilSettled()
        #expect(try await jobs(database, id).isEmpty)
        #expect(try await MeetingRepository(database: database).fetch(id)?.processingNote
            == AudioDeletedReprocessNote.text)
    }

    @Test("a queued job whose meeting is marked after admission completes, not fails")
    func queuedJobCompletesOnAudioDeleted() async throws {
        let (harness, id) = try await {
            let harness = try await makePipelineHarness()
            let meeting = try await harness.importTestMeeting()
            _ = try await harness.pipeline.process(meetingID: meeting.id)
            return (harness, meeting.id)
        }()
        let database = harness.database
        let pipeline = harness.pipeline
        // Admitted BEFORE the mark (the pre-check lets it in). `deleteAudio`
        // refuses a queued meeting, so the mark is committed directly — the
        // race an enqueue landing after the eligibility check would produce.
        _ = try await ProcessingQueueRepository(database: database).enqueue(meetingID: id, origin: .user)
        try await AudioRetention.markDeleted(database: database, meetingID: id, reason: .manual)

        let worker = ProcessingQueueWorker(database: database, runJob: { meetingID, origin in
            _ = try await pipeline.dispatchProcessing(
                meetingID: meetingID, refuseCancelled: origin != .user,
                noteIfAudioDeleted: origin == .auto)
        })
        await worker.kick()
        await worker.waitUntilSettled()

        let job = try #require(try await jobs(database, id).first)
        #expect(job.state == .done)
        #expect(job.lastError == nil)
        let stored = try #require(try await harness.meeting(id))
        #expect(stored.status == .ready)
        #expect(stored.lastProcessingError == nil)
    }

    // MARK: Reprocess All

    @Test("Reprocess All excludes marked meetings and counts them")
    func reprocessAllExcludesMarked() async throws {
        let database = try makeDatabase()
        let kept = try await insertMeeting(database)
        let marked1 = try await insertMeeting(database)
        let marked2 = try await insertMeeting(database)
        _ = try await insertMeeting(database, status: .failed)
        try await AudioRetention.markDeleted(database: database, meetingID: marked1, reason: .manual)
        try await AudioRetention.markDeleted(database: database, meetingID: marked2, reason: .cap)

        let plan = await ReprocessAllPlanner.plan(
            database: database, ledger: CloudSpendLedger(database: database), perMeetingUSD: 0)

        #expect(plan.eligibleMeetingIDs == [kept])
        #expect(plan.skippedAudioDeletedCount == 2)
        #expect(plan.meetingsToEnqueue == [kept])
    }
}
