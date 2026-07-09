import Foundation
import GRDB
import Testing

@testable import BlaiseCore

/// F1 Inc2 — Reprocess-all cost/cap (AC5), the pure plan math.
@Suite struct ReprocessAllPlanTests {
    private func plan(eligible: Int, per: Double, spent: Double, ceiling: Double) -> ReprocessAllPlan {
        ReprocessAllPlan(
            eligibleMeetingIDs: (0..<eligible).map { _ in ULID.generate() },
            perMeetingUSD: per, spentThisMonthUSD: spent, ceilingUSD: ceiling, monthKey: "2026-06")
    }

    @Test func capsToRemainingMonthlyBudget() {
        // headroom 0.50 / 0.074 = 6.75 → 6 affordable.
        let p = plan(eligible: 100, per: 0.074, spent: 19.5, ceiling: 20.0)
        #expect(p.affordableCount == 6)
        #expect(p.cappedCount == 6)
        #expect(p.wasCapped)
        #expect(p.meetingsToEnqueue.count == 6)
        #expect(abs(p.estimatedUSD - 6 * 0.074) < 1e-9)
    }

    @Test func enqueuesAllWhenBudgetIsAmple() {
        let p = plan(eligible: 5, per: 0.074, spent: 0, ceiling: 20)
        #expect(p.cappedCount == 5)
        #expect(!p.wasCapped)
        #expect(p.meetingsToEnqueue.count == 5)
    }

    @Test func capsToZeroAtTheCeiling() {
        let p = plan(eligible: 10, per: 0.074, spent: 20, ceiling: 20)
        #expect(p.affordableCount == 0)
        #expect(p.cappedCount == 0)
        #expect(p.meetingsToEnqueue.isEmpty)
        #expect(p.wasCapped)
    }

    @Test func freeCostEnqueuesEverything() {
        let p = plan(eligible: 3, per: 0, spent: 5, ceiling: 20)
        #expect(p.cappedCount == 3)
        #expect(!p.wasCapped)
    }
}

/// F1 Inc2 — repository retry (AC4) + CAS-guarded pending cancel (AC3/C2).
@Suite struct ProcessingQueueRepositoryInc2Tests {
    private func seed() async throws -> (BlaiseDatabase, ProcessingQueueRepository, Meeting) {
        let db = try makeDatabase()
        let meeting = makeMeeting()
        try await MeetingRepository(database: db).create(meeting)
        return (db, ProcessingQueueRepository(database: db), meeting)
    }

    @Test func retryFlipsFailedBackToPendingAndClearsError() async throws {
        let (db, repo, meeting) = try await seed()
        let job = try await repo.enqueue(meetingID: meeting.id, origin: .user)
        _ = try await repo.claimNext()
        try await repo.fail(job.id, error: "boom")
        try await repo.retry(job.id)
        let next = try #require(try await repo.nextPending())
        #expect(next.id == job.id)
        #expect(next.state == .pending)
        #expect(next.lastError == nil)
        #expect(next.attempts == 1, "attempts preserved as history")
        _ = db
    }

    @Test func userAdmissionPromotesAnExistingAutoPendingJob() async throws {
        // H-promote: a user's Process/Regenerate collapsing into a live AUTO job
        // promotes its origin, so the run uses refuseCancelled=false (else a
        // cancelled meeting's user Process would be silently refused).
        let (_, repo, meeting) = try await seed()
        let auto = try await repo.enqueue(meetingID: meeting.id, origin: .auto)
        #expect(auto.origin == .auto)
        let promoted = try await repo.enqueue(meetingID: meeting.id, origin: .user)
        #expect(promoted.id == auto.id)  // collapsed into the same job
        #expect(promoted.origin == .user)  // ...but promoted
    }

    @Test func cancelPendingCASCancelsOnlyPendingNotRunning() async throws {
        let (db, repo, meeting) = try await seed()
        let job = try await repo.enqueue(meetingID: meeting.id, origin: .user)
        // pending → CAS cancel succeeds.
        #expect(try await repo.cancelPending(job.id) == true)
        let after = try await db.pool.read { try ProcessingJob.fetchOne($0, key: job.id) }
        #expect(after?.state == .cancelled)

        // A running job: cancelPending must NOT stomp it (returns false).
        let m2 = makeMeeting()
        try await MeetingRepository(database: db).create(m2)
        let job2 = try await repo.enqueue(meetingID: m2.id, origin: .user)
        _ = try await repo.claimNext()  // job2 → running
        #expect(try await repo.cancelPending(job2.id) == false)
        let after2 = try await db.pool.read { try ProcessingJob.fetchOne($0, key: job2.id) }
        #expect(after2?.state == .running, "a running job is left for pipeline.cancel, not stomped")
    }
}

/// F1 Inc2 — the worker parks when paused and drains on resume (AC6).
@Suite struct ProcessingQueuePauseTests {
    private actor Flag {
        private var value: Bool
        init(_ v: Bool) { value = v }
        func get() -> Bool { value }
        func set(_ v: Bool) { value = v }
    }
    private actor Recorder {
        var ran: [MeetingID] = []
        func record(_ m: MeetingID) { ran.append(m) }
    }

    @Test func pausedWorkerParksThenDrainsOnResume() async throws {
        let db = try makeDatabase()
        let repo = ProcessingQueueRepository(database: db)
        let meeting = makeMeeting()
        try await MeetingRepository(database: db).create(meeting)
        _ = try await repo.enqueue(meetingID: meeting.id, origin: .auto)

        let paused = Flag(true)
        let recorder = Recorder()
        let worker = ProcessingQueueWorker(
            database: db,
            isPaused: { await paused.get() },
            runJob: { id, _ in await recorder.record(id) })

        await worker.kick()
        await worker.waitUntilSettled()
        #expect(await recorder.ran.isEmpty, "paused → nothing drained")
        #expect(try await repo.nextPending() != nil, "the job is still pending")

        await paused.set(false)
        await worker.kick()
        await worker.waitUntilSettled()
        #expect(await recorder.ran == [meeting.id], "resume drains the parked job")
    }
}

/// F1 Inc2 — the panel model's cancel ROUTING (H-cancel-routing): a CAS no-op
/// must reload by id and only pipeline-cancel a STILL-RUNNING job (never a
/// stale done/failed row, which could hit a newer run for the same meeting).
@Suite struct ProcessingQueueModelCancelTests {
    private actor CancelRecorder {
        var meetings: [MeetingID] = []
        func record(_ m: MeetingID) { meetings.append(m) }
        var seen: [MeetingID] { meetings }
    }

    @MainActor private func makeModel(_ db: BlaiseDatabase, _ recorder: CancelRecorder) -> ProcessingQueueModel {
        ProcessingQueueModel(
            database: db, worker: ProcessingQueueWorker(database: db, runJob: { _, _ in }),
            settings: SettingsStore(database: db),
            cancelRunning: { mid in await recorder.record(mid) })
    }

    @MainActor @Test func cancelDoesNotPipelineCancelAStaleDoneJob() async throws {
        let db = try makeDatabase()
        let repo = ProcessingQueueRepository(database: db)
        let meeting = makeMeeting()
        try await MeetingRepository(database: db).create(meeting)
        let job = try await repo.enqueue(meetingID: meeting.id, origin: .user)
        _ = try await repo.claimNext()
        try await repo.complete(job.id)  // now DONE — a stale panel row

        let recorder = CancelRecorder()
        let model = makeModel(db, recorder)
        await model.refresh()
        await model.cancel(job)  // CAS no-op; reload shows done → NO pipeline cancel
        #expect(await recorder.seen.isEmpty)
    }

    @MainActor @Test func cancelPipelineCancelsAStillRunningJob() async throws {
        let db = try makeDatabase()
        let repo = ProcessingQueueRepository(database: db)
        let meeting = makeMeeting()
        try await MeetingRepository(database: db).create(meeting)
        let job = try await repo.enqueue(meetingID: meeting.id, origin: .user)
        _ = try await repo.claimNext()  // running

        let recorder = CancelRecorder()
        let model = makeModel(db, recorder)
        await model.refresh()
        await model.cancel(job)  // CAS no-op (running); reload shows running → pipeline cancel
        #expect(await recorder.seen == [meeting.id])
    }
}

/// F1 Inc2 regression — when the queue drains to empty, the snapshot settles to
/// `.idle` BEFORE `drain()` returns. The final publish was previously
/// fire-and-forget (`Task { await publishSnapshot() }` in a `defer`), so it
/// could lose the race and leave the live "Processing" indicator stuck on a
/// stale running job after everything had finished.
@Suite struct ProcessingQueueSnapshotSettleTests {
    @Test func drainingToEmptySettlesIndicatorToIdle() async throws {
        let db = try makeDatabase()
        let repo = ProcessingQueueRepository(database: db)
        let meeting = makeMeeting()
        try await MeetingRepository(database: db).create(meeting)
        _ = try await repo.enqueue(meetingID: meeting.id, origin: .auto)

        let holder = await MainActor.run { ProcessingStatusHolder() }
        let worker = ProcessingQueueWorker(
            database: db, holder: holder,
            runJob: { _, _ in })  // succeeds immediately

        await worker.kick()
        await worker.waitUntilSettled()

        // waitUntilSettled returns only after drain() has AWAITED its final
        // publish, so the holder must already read idle — not a stale running.
        let snapshot = await holder.snapshot
        #expect(snapshot.state == .idle, "indicator stuck at \(snapshot.state)")
        #expect(snapshot.runningMeetingID == nil)
        #expect(snapshot.pendingCount == 0)
    }
}
