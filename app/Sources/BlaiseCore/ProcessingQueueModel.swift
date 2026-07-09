import Foundation

/// F1 Inc2 — the Reprocess-all cost/cap plan (Stage 2c). Pure value: all the
/// numbers the confirmation dialog shows, plus the capped enqueue set. The cap
/// honors the remaining monthly headroom (the ledger's per-call gate is the true
/// ceiling — C6; this is a courtesy pre-filter so a near-ceiling reprocess can't
/// queue work that will only stall).
public struct ReprocessAllPlan: Sendable, Equatable {
    /// All `ready` meetings (reprocess regenerates their notes from retained audio).
    public var eligibleMeetingIDs: [MeetingID]
    public var perMeetingUSD: Double
    public var spentThisMonthUSD: Double
    public var ceilingUSD: Double
    public var monthKey: String

    public init(
        eligibleMeetingIDs: [MeetingID], perMeetingUSD: Double, spentThisMonthUSD: Double,
        ceilingUSD: Double, monthKey: String
    ) {
        self.eligibleMeetingIDs = eligibleMeetingIDs
        self.perMeetingUSD = perMeetingUSD
        self.spentThisMonthUSD = spentThisMonthUSD
        self.ceilingUSD = ceilingUSD
        self.monthKey = monthKey
    }

    public var eligibleCount: Int { eligibleMeetingIDs.count }
    public var headroomUSD: Double { max(0, ceilingUSD - spentThisMonthUSD) }
    /// How many meetings the remaining budget affords (all of them if cost is 0).
    public var affordableCount: Int {
        guard perMeetingUSD > 0 else { return eligibleCount }
        return Int((headroomUSD / perMeetingUSD).rounded(.down))
    }
    /// The set that will actually enqueue (capped to the affordable count).
    public var cappedCount: Int { min(eligibleCount, max(0, affordableCount)) }
    public var wasCapped: Bool { cappedCount < eligibleCount }
    public var estimatedUSD: Double { Double(cappedCount) * perMeetingUSD }
    public var meetingsToEnqueue: [MeetingID] { Array(eligibleMeetingIDs.prefix(cappedCount)) }
}

public enum ReprocessAllPlanner {
    /// Per-meeting cost estimate for the dialog (mirrors
    /// `ClaudeSummarizationEngine.costDescriptor.estimatedPerMeetingUSD`).
    public static let defaultPerMeetingUSD = 0.074

    /// Build the plan from the catalog (`ready` meetings) + the ledger.
    public static func plan(
        database: BlaiseDatabase, ledger: CloudSpendLedger, perMeetingUSD: Double
    ) async -> ReprocessAllPlan {
        let meetings = (try? await MeetingRepository(database: database).listByRecency()) ?? []
        let eligible = meetings.filter { $0.status == .ready }.map(\.id)
        let spent = (try? await ledger.accumulatedThisMonth()) ?? 0
        let ceiling = await ledger.ceilingUSD()
        let monthKey = await ledger.currentMonthKey()
        return ReprocessAllPlan(
            eligibleMeetingIDs: eligible, perMeetingUSD: perMeetingUSD,
            spentThisMonthUSD: spent, ceilingUSD: ceiling, monthKey: monthKey)
    }
}

/// F1 Inc2 — the Settings "Processing Queue" panel model (Stage 2b/2d). Reads
/// the durable jobs + the pause setting; drives manual retry, per-job cancel,
/// and pause. Live status comes from `ProcessingStatusHolder.snapshot` (the
/// worker publishes it); this model owns the full job list + the actions.
@MainActor @Observable
public final class ProcessingQueueModel {
    public private(set) var jobs: [ProcessingJob] = []
    public private(set) var paused = false

    private let repository: ProcessingQueueRepository
    private let worker: ProcessingQueueWorker
    private let settings: SettingsStore
    /// Cancels a RUNNING job's in-flight pipeline run (prod = `pipeline.cancel`).
    private let cancelRunning: @Sendable (MeetingID) async -> Void

    public init(
        database: BlaiseDatabase,
        worker: ProcessingQueueWorker,
        settings: SettingsStore,
        cancelRunning: @escaping @Sendable (MeetingID) async -> Void
    ) {
        self.repository = ProcessingQueueRepository(database: database)
        self.worker = worker
        self.settings = settings
        self.cancelRunning = cancelRunning
    }

    public var failedJobs: [ProcessingJob] { jobs.filter { $0.state == .failed } }
    public var liveJobs: [ProcessingJob] { jobs.filter { $0.state == .pending || $0.state == .running } }

    public func refresh() async {
        jobs = (try? await repository.allJobs()) ?? []
        paused = ((try? await settings.get(ProcessingQueueSettings.pausedKey, as: Bool.self)) ?? nil) ?? false
    }

    public func retry(_ job: ProcessingJob) async {
        try? await repository.retry(job.id)
        await worker.kick()
        await refresh()
    }

    public func retryAllFailed() async {
        try? await repository.retryAllFailed()
        await worker.kick()
        await refresh()
    }

    /// C2: a PENDING job is CAS-cancelled directly. If the CAS no-ops, RELOAD
    /// the job by id — only cancel the in-flight pipeline run if *this same job*
    /// is still `running` (a CAS no-op also means done/failed/cancelled/deleted,
    /// where cancelling the meeting's run could hit a newer run — H-cancel-routing).
    public func cancel(_ job: ProcessingJob) async {
        if (try? await repository.cancelPending(job.id)) == true {
            await refresh()
            return
        }
        if let current = try? await repository.job(job.id), current.state == .running {
            await cancelRunning(job.meetingID)
        }
        await refresh()
    }

    public func setPaused(_ value: Bool) async {
        try? await settings.set(ProcessingQueueSettings.pausedKey, to: value)
        paused = value
        if !value { await worker.kick() }  // resume → re-drain
        await refresh()
    }
}
