import Foundation
import GRDB
import Testing

@testable import BlaiseCore

/// F1 Increment 1 — durable processing-queue data layer (migration v15 +
/// ProcessingQueueRepository). The worker + recovery integration are separate
/// stages; these pin the repository contract (AC1/AC2 + the resume sweep).
struct ProcessingQueueRepositoryTests {

    private func setup() async throws -> (BlaiseDatabase, ProcessingQueueRepository, Meeting) {
        let db = try makeDatabase()
        let meeting = makeMeeting()
        try await MeetingRepository(database: db).create(meeting)
        return (db, ProcessingQueueRepository(database: db), meeting)
    }

    @Test("enqueue inserts a pending job; created_seq is monotonic FIFO (AC2)")
    func enqueueInserts() async throws {
        let (db, repo, meeting) = try await setup()
        let m2 = makeMeeting()
        try await MeetingRepository(database: db).create(m2)
        let j1 = try await repo.enqueue(meetingID: meeting.id, origin: .auto)
        let j2 = try await repo.enqueue(meetingID: m2.id, origin: .user)
        #expect(j1.state == .pending)
        #expect(j1.createdSeq == 1)
        #expect(j2.createdSeq == 2)
        #expect(j2.origin == .user)
    }

    @Test("enqueue while a live job exists COLLAPSES — idempotent dedup (AC2)")
    func enqueueDedup() async throws {
        let (_, repo, meeting) = try await setup()
        // Same origin → pure collapse, no promotion. (The .user-over-.auto
        // origin promotion is covered by userAdmissionPromotesAnExistingAutoPendingJob.)
        let j1 = try await repo.enqueue(meetingID: meeting.id, origin: .auto)
        let j2 = try await repo.enqueue(meetingID: meeting.id, origin: .auto)
        #expect(j1.id == j2.id)  // same row, no duplicate
        #expect(j2.origin == .auto)  // collapsed, unchanged
        let live = try await repo.liveCount()
        #expect(live == 1)
    }

    @Test("partial unique index rejects two LIVE rows for one meeting — the backstop (AC1)")
    func partialUniqueIndexBackstop() async throws {
        let (db, _, meeting) = try await setup()
        try await db.pool.write { db in
            let a = ProcessingJob(
                id: ULID.generate(), meetingID: meeting.id, state: .pending,
                origin: .auto, attempts: 0, createdSeq: 1, enqueuedAt: Date())
            try a.insert(db)
        }
        await #expect(throws: (any Error).self) {
            try await db.pool.write { db in
                let b = ProcessingJob(
                    id: ULID.generate(), meetingID: meeting.id, state: .running,
                    origin: .user, attempts: 0, createdSeq: 2, enqueuedAt: Date())
                try b.insert(db)
            }
        }
        // A non-live (done) row for the same meeting is allowed.
        try await db.pool.write { db in
            let c = ProcessingJob(
                id: ULID.generate(), meetingID: meeting.id, state: .done,
                origin: .auto, attempts: 0, createdSeq: 3, enqueuedAt: Date())
            try c.insert(db)
        }
    }

    @Test("claimNext returns the oldest by created_seq, marks running; complete → done (AC2)")
    func claimAndComplete() async throws {
        let (db, repo, meeting) = try await setup()
        let m2 = makeMeeting()
        try await MeetingRepository(database: db).create(m2)
        _ = try await repo.enqueue(meetingID: meeting.id, origin: .auto)  // seq 1
        _ = try await repo.enqueue(meetingID: m2.id, origin: .auto)  // seq 2
        let claimed = try #require(try await repo.claimNext())
        #expect(claimed.meetingID == meeting.id)  // oldest first
        #expect(claimed.state == .running)
        try await repo.complete(claimed.id)
        let next = try #require(try await repo.claimNext())
        #expect(next.meetingID == m2.id)  // the second job
    }

    @Test("fail bumps attempts; complete on a deleted/absent row is a safe no-op (H-2)")
    func failAndDeleteTolerance() async throws {
        let (_, repo, meeting) = try await setup()
        let job = try await repo.enqueue(meetingID: meeting.id, origin: .auto)
        _ = try await repo.claimNext()
        try await repo.fail(job.id, error: "boom")
        let failed = try #require(try await fetchJob(repo, id: job.id))
        #expect(failed.state == .failed)
        #expect(failed.attempts == 1)
        #expect(failed.lastError == "boom")
        // complete on an id with no row must not throw (delete-mid-run tolerance)
        try await repo.complete("nonexistent-id")
    }

    @Test("resetStaleRunning: a stale running row → pending (resume sweep, AC4)")
    func resetStaleRunning() async throws {
        let (_, repo, meeting) = try await setup()
        _ = try await repo.enqueue(meetingID: meeting.id, origin: .auto)
        let claimed = try #require(try await repo.claimNext())
        #expect(claimed.state == .running)
        try await repo.resetStaleRunning()
        let next = try #require(try await repo.nextPending())
        #expect(next.id == claimed.id)
        #expect(next.state == .pending)
    }

    @Test("DB-open (runStartupSweeps) resets a stale running job → pending — the unconditional sweep (M-A)")
    func startupSweepResetsRunning() async throws {
        let root = try makeTempRoot()
        let meeting = makeMeeting()
        do {
            let db1 = try BlaiseDatabase(rootURL: root)
            try await MeetingRepository(database: db1).create(meeting)
            let repo1 = ProcessingQueueRepository(database: db1)
            _ = try await repo1.enqueue(meetingID: meeting.id, origin: .auto)
            _ = try await repo1.claimNext()  // → running (simulate a pre-crash claim)
            #expect(try await repo1.nextPending() == nil)  // running, not pending
        }
        // Re-open at the same root → runStartupSweeps resets running → pending,
        // regardless of how the worker is launched (kick() vs start()).
        let db2 = try BlaiseDatabase(rootURL: root)
        let repo2 = ProcessingQueueRepository(database: db2)
        let pending = try #require(try await repo2.nextPending())
        #expect(pending.meetingID == meeting.id)
        #expect(pending.state == .pending)
    }

    private func fetchJob(_ repo: ProcessingQueueRepository, id: String) async throws -> ProcessingJob? {
        try await repo.database.pool.read { db in
            try ProcessingJob.fetchOne(db, key: id)
        }
    }
}
