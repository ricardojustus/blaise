import Foundation
import GRDB
import Testing

@testable import BlaiseCore

/// F1 Increment 1 — the processing-queue worker drain (Stage B). The executor is
/// injected, so the drain is pinned without the live pipeline.
struct ProcessingQueueWorkerTests {

    private actor JobRecorder {
        var ran: [MeetingID] = []
        func record(_ m: MeetingID) { ran.append(m) }
    }

    private struct JobError: Error {}

    private actor OriginRecorder {
        var byMeeting: [MeetingID: ProcessingJobOrigin] = [:]
        func record(_ m: MeetingID, _ o: ProcessingJobOrigin) { byMeeting[m] = o }
        func origin(for m: MeetingID) -> ProcessingJobOrigin? { byMeeting[m] }
    }

    private func seed(_ count: Int) async throws -> (BlaiseDatabase, ProcessingQueueRepository, [Meeting]) {
        let db = try makeDatabase()
        let repo = ProcessingQueueRepository(database: db)
        let meetingRepo = MeetingRepository(database: db)
        var meetings: [Meeting] = []
        for _ in 0..<count {
            let m = makeMeeting()
            try await meetingRepo.create(m)
            _ = try await repo.enqueue(meetingID: m.id, origin: .auto)
            meetings.append(m)
        }
        return (db, repo, meetings)
    }

    @Test("worker drains pending jobs FIFO and marks each done (AC3)")
    func drainsFIFO() async throws {
        let (db, repo, meetings) = try await seed(3)
        let recorder = JobRecorder()
        let worker = ProcessingQueueWorker(database: db, runJob: { id, _ in await recorder.record(id) })
        await worker.kick()
        await worker.waitUntilSettled()
        let ran = await recorder.ran
        #expect(ran == meetings.map(\.id))  // FIFO by created_seq
        #expect(try await repo.liveCount() == 0)  // all done
    }

    @Test("a throwing job is marked failed (+attempts), never left pending/lost (AC3)")
    func failedJobMarkedNotLost() async throws {
        let (db, repo, meetings) = try await seed(1)
        let worker = ProcessingQueueWorker(database: db, runJob: { _, _ in throw JobError() })
        await worker.kick()
        await worker.waitUntilSettled()
        #expect(try await repo.nextPending() == nil)  // not left pending
        let job = try await db.pool.read { db in
            try ProcessingJob.filter(Column("meeting_id") == meetings[0].id).fetchOne(db)
        }
        #expect(job?.state == .failed)
        #expect(job?.attempts == 1)
    }

    @Test("a run that throws EngineError.cancelled marks the job cancelled, not failed (AC3/C1)")
    func cancelledRunMarkedCancelled() async throws {
        let (db, repo, meetings) = try await seed(1)
        let worker = ProcessingQueueWorker(database: db, runJob: { _, _ in throw EngineError.cancelled })
        await worker.kick()
        await worker.waitUntilSettled()
        let job = try await db.pool.read { db in
            try ProcessingJob.filter(Column("meeting_id") == meetings[0].id).fetchOne(db)
        }
        #expect(job?.state == .cancelled)  // terminal cancel — NOT a failure, no misleading Retry
        #expect(try await repo.nextPending() == nil)
    }

    @Test("runJob receives the job's origin so the executor can vary refuseCancelled (AC2/D1)")
    func runJobReceivesOrigin() async throws {
        let db = try makeDatabase()
        let repo = ProcessingQueueRepository(database: db)
        let meetingRepo = MeetingRepository(database: db)
        let mUser = makeMeeting()
        let mAuto = makeMeeting()
        try await meetingRepo.create(mUser)
        try await meetingRepo.create(mAuto)
        _ = try await repo.enqueue(meetingID: mUser.id, origin: .user)
        _ = try await repo.enqueue(meetingID: mAuto.id, origin: .auto)
        let seen = OriginRecorder()
        let worker = ProcessingQueueWorker(database: db, runJob: { id, origin in
            await seen.record(id, origin)
        })
        await worker.kick()
        await worker.waitUntilSettled()
        #expect(await seen.origin(for: mUser.id) == .user)
        #expect(await seen.origin(for: mAuto.id) == .auto)
    }

    @Test("start() resets a stale running row (interrupted claim) then drains it (AC4)")
    func startResumesStale() async throws {
        let (db, repo, meetings) = try await seed(1)
        // Simulate a pre-crash claim: leave the row `running`.
        _ = try await repo.claimNext()
        #expect(try await repo.nextPending() == nil)  // running, not pending
        let recorder = JobRecorder()
        let worker = ProcessingQueueWorker(database: db, runJob: { id, _ in await recorder.record(id) })
        await worker.start()  // resetStaleRunning → pending → drain → done
        await worker.waitUntilSettled()
        #expect(await recorder.ran == [meetings[0].id])
        #expect(try await repo.liveCount() == 0)
    }

    /// A two-signal gate so the test can deterministically observe a job RUNNING,
    /// stop() it, then release it — pinning that stop() does not fail the in-flight job.
    private actor Gate {
        private var startedCont: CheckedContinuation<Void, Never>?
        private var started = false
        private var releaseCont: CheckedContinuation<Void, Never>?
        private var released = false
        func signalStarted() {
            started = true
            startedCont?.resume()
            startedCont = nil
        }
        func awaitStarted() async {
            if started { return }
            await withCheckedContinuation { startedCont = $0 }
        }
        func release() {
            released = true
            releaseCont?.resume()
            releaseCont = nil
        }
        func awaitRelease() async {
            if released { return }
            await withCheckedContinuation { releaseCont = $0 }
        }
    }

    @Test("stop() lets the IN-FLIGHT job finish (marked done, not failed) — Floor 1")
    func stopLetsInflightFinish() async throws {
        let (db, _, meetings) = try await seed(1)
        let gate = Gate()
        let worker = ProcessingQueueWorker(database: db, runJob: { _, _ in
            await gate.signalStarted()
            await gate.awaitRelease()
        })
        await worker.kick()  // drain claims the job; runJob blocks
        await gate.awaitStarted()  // the job IS running
        await worker.stop()  // stopping = true; the in-flight job continues
        await gate.release()  // runJob completes
        await worker.waitUntilSettled()
        let job = try await db.pool.read { db in
            try ProcessingJob.filter(Column("meeting_id") == meetings[0].id).fetchOne(db)
        }
        #expect(job?.state == .done)  // finished gracefully, NOT failed
    }
}
