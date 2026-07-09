import Foundation
import os

/// F1 — the durable processing-queue worker. Drains `processing_queue` strictly
/// SEQUENTIALLY (one job in flight): notes/digest synthesis is a cost-bounded
/// CLOUD call, and the local MLX engine has an 18 GB peak-memory gate, so
/// concurrency is unsafe (Hard Floors). It does NOT touch the pipeline body — it
/// claims a job and calls the unchanged executor (`dispatchProcessing`).
///
/// Mirrors `HandoffWorker`'s wake model: `kick()` on enqueue, `start()` on launch,
/// a generation counter so a drain about to park re-loops if a wake landed
/// mid-decision, and an `os_activity` background token so App Nap can't stall it.
/// The job executor is INJECTED (production = `ProcessingPipeline.dispatchProcessing`)
/// so the drain is unit-testable without the live pipeline.
public actor ProcessingQueueWorker {
    private let repository: ProcessingQueueRepository
    /// The injected executor (production = `ProcessingPipeline.dispatchProcessing`).
    /// Takes the job's `origin` so it can set `refuseCancelled` (auto/recovery
    /// paths must not resurrect a user-cancelled meeting; the user's own run may
    /// — D1). MUST propagate the throw: the drain classifies the terminal state
    /// from it (`done` on return, `cancelled` on `EngineError.cancelled`, else
    /// `failed`).
    private let runJob: @Sendable (MeetingID, ProcessingJobOrigin) async throws -> Void
    private let logger = Logger(subsystem: BlaiseBundle.identifier, category: "processing-queue")

    private var drainTask: Task<Void, Never>?
    /// Bumped by external wakes; a drain that decided to park re-loops if a wake
    /// landed while it was deciding.
    private var wakeGeneration = 0
    /// Set by `stop()`; the drain finishes the IN-FLIGHT job + its `complete`,
    /// then exits before claiming the next (never interrupt a half-written
    /// output — Floor 1). Cleared by `kick()`/`start()` (a wake means resume).
    private var stopping = false
    /// Held while a drain is running so App Nap cannot stall the queue.
    private var activityToken: (any NSObjectProtocol)?
    /// Observability sink (F1 Inc2): the worker publishes a snapshot after every
    /// state change. nil in tests that don't assert the UI.
    private let holder: ProcessingStatusHolder?
    /// Durable pause predicate (D6): checked at the top of the drain loop; when
    /// true the worker parks (the in-flight job finishes first). Resume = the
    /// setting clears + `kick()`.
    private let isPaused: @Sendable () async -> Bool

    public init(
        database: BlaiseDatabase,
        holder: ProcessingStatusHolder? = nil,
        isPaused: @escaping @Sendable () async -> Bool = { false },
        runJob: @escaping @Sendable (MeetingID, ProcessingJobOrigin) async throws -> Void
    ) {
        self.repository = ProcessingQueueRepository(database: database)
        self.holder = holder
        self.isPaused = isPaused
        self.runJob = runJob
    }

    /// The single durable admission point for full-pipeline work (C7): persist a
    /// job (idempotent — a live job for the meeting collapses) then wake the
    /// drain. Producers call this instead of `dispatchProcessing` directly.
    @discardableResult
    public func enqueue(_ meetingID: MeetingID, origin: ProcessingJobOrigin) async -> ProcessingJob? {
        let job = try? await repository.enqueue(meetingID: meetingID, origin: origin)
        await kick()
        return job
    }

    /// Launch wake: a stale `running` row is an interrupted claim → reset to
    /// `pending` (the resume sweep), then drain.
    public func start() async {
        stopping = false
        do {
            try await repository.resetStaleRunning()
        } catch {
            // Floor 2: a failed reset leaves stale `running` rows unclaimable
            // (claim only selects `pending`) — surface it loudly rather than
            // silently strand jobs. The next launch retries the sweep.
            logger.error(
                "processing-queue resetStaleRunning failed at launch — stale running jobs may be stranded: \(String(describing: error), privacy: .public)")
        }
        await kick()
    }

    /// External wake (enqueue / launch): (re-)drain.
    public func kick() async {
        stopping = false
        wakeGeneration += 1
        ensureDraining()
    }

    /// Graceful stop: stop claiming NEW jobs. The IN-FLIGHT job (and its
    /// `complete`) finishes — never interrupt a half-written output (Floor 1);
    /// a force-kill mid-job is recovered by the running→pending sweep on next
    /// launch. (Cooperative mid-job cancellation is Increment 2.)
    public func stop() {
        stopping = true
    }

    /// Test/evidence support: waits until no drain is running.
    public func waitUntilSettled() async {
        while let task = drainTask { await task.value }
    }

    private func ensureDraining() {
        guard drainTask == nil else { return }
        beginActivityIfNeeded()
        drainTask = Task { await self.drain() }
    }

    private func drain() async {
        defer {
            drainTask = nil
            endActivityIfHeld()
        }
        // `stopping` is checked before each claim, so the in-flight job + its
        // `complete` always finish before the worker exits (Floor 1).
        while !stopping {
            // D6: park on pause — the in-flight job (if any) already finished
            // below; resume is the setting clearing + a kick().
            if await isPaused() {
                await publishSnapshot()
                return
            }
            let generation = wakeGeneration
            let claimed: ProcessingJob?
            do {
                claimed = try await repository.claimNext()
            } catch {
                logger.error("processing-queue claim failed: \(String(describing: error), privacy: .public)")
                await publishSnapshot()  // settle the indicator even on a claim failure
                return
            }
            guard let job = claimed else {
                // No pending work. Re-loop only if a wake landed while we decided;
                // otherwise stop — the next enqueue/launch kick re-drains.
                if generation != wakeGeneration { continue }
                await publishSnapshot()  // settle to idle now the queue is drained
                return
            }
            await publishSnapshot()  // running
            do {
                try await runJob(job.meetingID, job.origin)
                try await repository.complete(job.id)
            } catch is CancellationError {
                // The worker's own Task was cancelled (shutdown) — leave the row
                // `running`; the launch resume sweep reclaims it. Not a job failure.
                try? await repository.resetStaleRunning()
            } catch let error as EngineError where Self.isCancelled(error) {
                // C1/D2: the user cancelled this running job (pipeline.cancel →
                // typed EngineError.cancelled). Terminal `cancelled`, NOT `failed`
                // (a cancelled job must not offer a misleading Retry).
                logger.notice("processing job \(job.id, privacy: .public) cancelled by user")
                try? await repository.markCancelled(job.id)
            } catch {
                logger.error(
                    "processing job \(job.id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                // Mark failed (best-effort; a row deleted mid-run no-ops — H-2).
                try? await repository.fail(job.id, error: String(describing: error))
            }
            await publishSnapshot()  // after the terminal transition
        }
        await publishSnapshot()  // final settle on stop (loop exited via `stopping`)
    }

    /// Publish the current queue state to the holder (F1 Inc2). Cheap counts read.
    private func publishSnapshot() async {
        guard let holder else { return }
        let paused = await isPaused()
        let counts = (try? await repository.counts()) ?? (pending: 0, failed: 0, runningMeetingID: nil)
        let snapshot = ProcessingSnapshot(
            pendingCount: counts.pending, runningMeetingID: counts.runningMeetingID,
            failedCount: counts.failed, paused: paused)
        await holder.publish(snapshot)
    }

    private func beginActivityIfNeeded() {
        guard activityToken == nil else { return }
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: .background, reason: "Blaise processing queue")
    }

    private func endActivityIfHeld() {
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
    }

    private static func isCancelled(_ error: EngineError) -> Bool {
        if case .cancelled = error { return true }
        return false
    }
}

/// Routes the Meet-listener post-ready re-mint (the `ProcessingDispatching`
/// seam) through the durable queue instead of dispatching directly — F1 Inc2
/// C3 (origin `.auto`, so a user-cancelled meeting is not resurrected).
public struct QueueProcessingDispatcher: ProcessingDispatching {
    private let queue: ProcessingQueueWorker
    public init(queue: ProcessingQueueWorker) { self.queue = queue }
    public func dispatch(meetingID: MeetingID) async {
        await queue.enqueue(meetingID, origin: .auto)
    }
}
