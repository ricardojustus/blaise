import Foundation

// G11 §2: calendar-aware end-detection classifier — PURE, no clock, no DB,
// no audio. Decides whether a debounce-fired end-signal stops-and-processes
// immediately (the meeting is at/near its scheduled end) or enters the
// existing resume grace window (today's behavior). Everything stateful lives
// in `MeetCallTracker`; this is the single decision point it consults.

/// What to do when an end-signal fires for a recording.
public enum EndAction: Sendable, Equatable {
    /// Stop and process NOW — no grace window. Used when a calendar-anchored
    /// meeting's end-signal lands inside the band before the scheduled end,
    /// or after it: the meeting is genuinely over, so the resume window is
    /// just latency before processing.
    case endAndProcess
    /// Enter the existing resume grace window (today's behavior): an early or
    /// ad-hoc (unanchored) end keeps the chance to rejoin as a new part.
    case graceThenProcess
}

public enum EndDetectionClassifier {
    /// The band before the scheduled end inside which an end-signal SKIPS
    /// grace (fixed at 10 minutes — §2; not user-tunable, §6).
    public static let bandSeconds: TimeInterval = 10 * 60

    /// G11 §2 / AC1. `endSignalAt` is the tracker's debounce-FIRE wall clock
    /// (the moment `performAutoStop` is invoked — app clock, no extension
    /// timestamp skew). `scheduledEndMs` is the meeting's calendar anchor
    /// (`scheduled_end_ms`); nil for an ad-hoc / unmatched meeting.
    ///
    /// - anchored AND `endSignalAt >= scheduledEnd − 10 min` → `.endAndProcess`
    /// - otherwise (early signal, or no anchor) → `.graceThenProcess`.
    public static func classify(
        endSignalAt: Date, scheduledEndMs: Int64?
    ) -> EndAction {
        guard let scheduledEndMs else { return .graceThenProcess }
        let scheduledEnd = Date(timeIntervalSince1970: Double(scheduledEndMs) / 1000.0)
        let bandOpens = scheduledEnd.addingTimeInterval(-bandSeconds)
        return endSignalAt >= bandOpens ? .endAndProcess : .graceThenProcess
    }
}
