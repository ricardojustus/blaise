import Foundation

/// F1 Inc2 — durable settings keys for the processing queue.
public enum ProcessingQueueSettings {
    /// Bool — when true the worker parks (the in-flight job finishes; D6).
    public static let pausedKey = "processing.paused"
}

/// F1 Inc2 — the durable processing queue's observable state (twin of
/// `HandoffSnapshot`). A lightweight value the worker publishes after every
/// state change; the Settings panel reads it for live status and refreshes the
/// full job list on demand.
public struct ProcessingSnapshot: Sendable, Equatable {
    public enum State: String, Sendable, Equatable {
        case idle          // no live or failed jobs
        case processing    // a job is running
        case pending       // jobs queued, none running yet
        case waitingRetry  // failed jobs awaiting a manual retry
        case paused        // the worker is parked (user pause)
    }

    public var state: State
    public var pendingCount: Int
    public var runningMeetingID: MeetingID?
    public var failedCount: Int
    public var paused: Bool

    public init(
        state: State = .idle, pendingCount: Int = 0, runningMeetingID: MeetingID? = nil,
        failedCount: Int = 0, paused: Bool = false
    ) {
        self.state = state
        self.pendingCount = pendingCount
        self.runningMeetingID = runningMeetingID
        self.failedCount = failedCount
        self.paused = paused
    }

    public static let initial = ProcessingSnapshot()

    /// Derive the headline state from the raw counts (paused dominates).
    public init(pendingCount: Int, runningMeetingID: MeetingID?, failedCount: Int, paused: Bool) {
        let state: State
        if paused {
            state = .paused
        } else if runningMeetingID != nil {
            state = .processing
        } else if pendingCount > 0 {
            state = .pending
        } else if failedCount > 0 {
            state = .waitingRetry
        } else {
            state = .idle
        }
        self.init(
            state: state, pendingCount: pendingCount, runningMeetingID: runningMeetingID,
            failedCount: failedCount, paused: paused)
    }
}

/// `@MainActor @Observable` holder the worker publishes into and the UI observes
/// (twin of `HandoffStatusHolder`, minus the warning-episode machinery).
@MainActor @Observable
public final class ProcessingStatusHolder {
    public private(set) var snapshot: ProcessingSnapshot = .initial
    public init() {}
    public func publish(_ snapshot: ProcessingSnapshot) { self.snapshot = snapshot }
}
