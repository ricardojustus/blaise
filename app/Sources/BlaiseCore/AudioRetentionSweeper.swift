import Foundation
import os

// G16 §4 (specs/g16_audio_retention.md): the size-cap sweep. Triggers (launch
// after recovery, a meeting reaching `ready`, the daily purge loop, a setting
// change) call `requestSweep`. Sweeps are serialized: one in flight plus at
// most one coalesced re-run. Each deletion goes through
// `ProcessingPipeline.deleteAudio(origin: .cap)`, which re-checks eligibility
// inside its chain slot — a refusal there just skips that meeting.

public actor AudioRetentionSweeper {
    private let database: BlaiseDatabase
    private let pipeline: ProcessingPipeline
    private let settings: SettingsStore
    private let logger: Logger
    /// Test seam: awaited at the start of every sweep pass.
    private let beforePass: (@Sendable () async -> Void)?
    /// Test seam: a raw byte cap replacing the setting (the smallest real cap
    /// is 1 GB, too big to plant in a test).
    private let capBytesOverride: Int64?

    private var inFlight: Task<AudioCapPlan, Never>?
    private var rerunPending = false
    /// Completed sweep passes (diagnostics / tests).
    public private(set) var passCount = 0

    public init(
        database: BlaiseDatabase,
        pipeline: ProcessingPipeline,
        settings: SettingsStore? = nil,
        logger: Logger = Logger(subsystem: BlaiseBundle.identifier, category: "audio.retention")
    ) {
        self.init(
            database: database, pipeline: pipeline, settings: settings, logger: logger,
            beforePass: nil, capBytesOverride: nil)
    }

    init(
        database: BlaiseDatabase,
        pipeline: ProcessingPipeline,
        settings: SettingsStore? = nil,
        logger: Logger = Logger(subsystem: BlaiseBundle.identifier, category: "audio.retention"),
        beforePass: (@Sendable () async -> Void)?,
        capBytesOverride: Int64?
    ) {
        self.capBytesOverride = capBytesOverride
        self.database = database
        self.pipeline = pipeline
        self.settings = settings ?? SettingsStore(database: database)
        self.logger = logger
        self.beforePass = beforePass
    }

    /// Fire-and-forget trigger. While a sweep runs, marks one re-run instead
    /// (any number of requests during a sweep collapse into one re-run).
    public func requestSweep() {
        _ = startOrCoalesce()
    }

    /// Requests a sweep and awaits it (including a coalesced re-run when one
    /// was already in flight). Returns the last pass's plan.
    @discardableResult
    public func sweepNow() async -> AudioCapPlan {
        await startOrCoalesce().value
    }

    private func startOrCoalesce() -> Task<AudioCapPlan, Never> {
        if let inFlight {
            rerunPending = true
            return inFlight
        }
        let task = Task { await self.drive() }
        inFlight = task
        return task
    }

    /// Runs passes until no re-run is pending. The pending check and the
    /// `inFlight` reset happen without a suspension in between, so a request
    /// either lands in this loop or starts a fresh task.
    private func drive() async -> AudioCapPlan {
        while true {
            let plan = await pass()
            passCount += 1
            if rerunPending {
                rerunPending = false
                continue
            }
            inFlight = nil
            return plan
        }
    }

    private func pass() async -> AudioCapPlan {
        await beforePass?()
        let cap = await AudioRetentionSettings.cap(from: settings)
        let capBytes = capBytesOverride ?? cap.bytes
        guard capBytes != nil else { return .empty }
        let usage: AudioUsage
        do {
            usage = try await AudioRetention.usage(database: database)
        } catch {
            logger.error("audio cap sweep: usage read failed: \(error)")
            return .empty
        }
        let plan = AudioRetention.capPlan(usage: usage, capBytes: capBytes)
        if !plan.isEmpty {
            logger.notice(
                "audio cap sweep (\(capBytes ?? 0) bytes): deleting audio of \(plan.meetingIDs.count) meeting(s), \(plan.bytesFreed) bytes")
        }
        for meetingID in plan.meetingIDs {
            do {
                _ = try await pipeline.deleteAudio(meetingID: meetingID, origin: .cap)
            } catch let PipelineAudioDeleteError.refused(reason) {
                logger.notice(
                    "audio cap sweep skipped \(meetingID, privacy: .public): \(reason.rawValue, privacy: .public)")
            } catch {
                logger.error("audio cap sweep failed for \(meetingID, privacy: .public): \(error)")
            }
        }
        if plan.remainingOverCap > 0 {
            logger.warning(
                "audio cap sweep (\(capBytes ?? 0) bytes): \(plan.remainingOverCap) bytes over the cap remain in audio not eligible for automatic deletion — not forced")
        }
        return plan
    }
}
