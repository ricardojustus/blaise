import Foundation

// C11: capture-health primitives, pure and unit-testable. The session feeds
// per-callback observations; the controller/indicator consume the verdicts.

/// Mic-silence health check (the mic-health-tracking pattern,
/// extracted): all-zero mic for ≥ 60 s while the system track is active →
/// warning (AirPods handing off to the phone silently zero the Mac mic).
public struct MicSilenceDetector: Sendable {
    public static let warningThresholdSeconds = 60.0

    private var silentWhileActiveSeconds = 0.0
    public private(set) var warningActive = false

    public init() {}

    /// Feed one observation window; returns a state CHANGE when one occurs
    /// (`true` = warning began, `false` = mic signal restored), nil otherwise.
    public mutating func observe(
        micAllZero: Bool, systemActive: Bool, windowSeconds: Double
    ) -> Bool? {
        if micAllZero && systemActive {
            silentWhileActiveSeconds += windowSeconds
            if !warningActive && silentWhileActiveSeconds >= Self.warningThresholdSeconds {
                warningActive = true
                return true
            }
        } else if !micAllZero {
            silentWhileActiveSeconds = 0
            if warningActive {
                warningActive = false
                return false
            }
        }
        // mic silent but system also silent: hold the accumulator (a quiet
        // room is not evidence either way), no state change.
        return nil
    }
}

/// Long-session warning threshold (indicator state only; recording
/// continues — the write-failure stop is the ONLY automatic stop).
public enum CaptureLimits {
    public static let longSessionWarningSeconds: TimeInterval = 6 * 3600
    /// Disk precheck at start: refuse to start with less than this free.
    public static let minimumFreeDiskBytes: Int64 = 2_000_000_000
}

// MARK: - Indicator state machine (pure; the MenuBarExtra renders it)

/// The indicator states (C11 spec). `warning` carries its reason and only
/// exists while recording (recording continues underneath). `alarm` is the
/// loud post-stop failure state (write failure, no recoverable audio): no
/// capture is live, a new recording is STARTABLE from it, and it persists
/// until acknowledged or the next successful start.
public enum IndicatorState: Equatable, Sendable {
    case idle
    case recording(startedAt: Date)
    case warning(startedAt: Date, message: String)
    case alarm(message: String)
    case processing
    /// C14 resume grace window: post-recording template glyph variant
    /// (pause-adjacent, calm), shown only when not recording. Grace and
    /// processing can coexist (back-to-back meetings); under the M-3 §4 order
    /// processing wins the icon (live recording > alarm > processing > grace >
    /// paused > idle — see `resolveDisplay`).
    case grace(meetingTitle: String, until: Date)
    /// G9 manual pause: the meeting is held open, no capture live. Carries
    /// the accumulated recorded time (sum of part durations) for the timer
    /// display. Display priority (fully ordered, §4):
    /// live recording > alarm > processing > grace > paused > idle.
    case paused(meetingTitle: String, accumulatedSeconds: TimeInterval)
}

/// Deterministic transition function over capture/pipeline inputs. Owned by
/// BlaiseCore so it is unit-testable; the UI holder applies inputs and
/// renders the result.
public struct IndicatorStateMachine: Sendable, Equatable {
    public private(set) var state: IndicatorState = .idle
    private var micSilence = false
    /// B4 (audit): the capture graph has been DOWN longer than
    /// `CaptureSession.captureDownAlarmSeconds` while a rebuild retries.
    /// See that constant for why this must be visible.
    private var captureDown = false
    private var startedAt: Date?
    /// Standing grace window (C14): survives interleaved back-to-back
    /// capture events; grace wins the icon whenever nothing is recording.
    private struct GraceWindow: Equatable, Sendable {
        var title: String
        var until: Date
    }
    private var grace: GraceWindow?
    /// G9 standing pause (a held-open meeting). Like the grace window, it is
    /// stored and resurfaces whenever nothing higher-priority is showing;
    /// cleared on resume (a `.captureStarted` follows) or End.
    private struct PausedMeeting: Equatable, Sendable {
        var title: String
        var accumulatedSeconds: TimeInterval
    }
    private var paused: PausedMeeting?
    /// Standing processing flag: a stop/auto-stop/End handed the meeting to the
    /// pipeline and the run has not finished. Cleared by `.processingFinished`.
    /// Spec §4 priority places processing ABOVE grace and paused.
    private var processing = false
    /// Standing loud-failure message (write failure / no recoverable audio).
    /// Persists until acknowledged or the next successful start. Spec §4 places
    /// alarm above processing/grace/paused.
    private var alarmMessage: String?

    public init() {}

    public enum Input: Equatable, Sendable {
        case captureStarted(at: Date)
        /// Stop was pressed: the engine is down and the encode is running —
        /// the indicator reflects "processing" immediately, before the
        /// (possibly long) encode finishes.
        case captureStopping
        /// Stop+encode completed. `alarm` carries the loud failure message
        /// (write failure / no recoverable audio). Always preceded by
        /// `.captureStopping` (the controller's protocol): if a capture is
        /// live when this arrives, it is a STALE completion — the next
        /// recording started before the previous encode finished — and the
        /// live recording wins the indicator.
        case captureStopped(alarm: String?)
        case micSilence(active: Bool)
        /// The capture graph went down / came back during a route-change rebuild.
        case captureDown(active: Bool)
        /// Periodic clock tick (long-session check, > 6 h).
        case tick(now: Date)
        case processingFinished
        /// User dismissed the loud alarm from the menu.
        case alarmAcknowledged
        /// C14 grace window entered after an auto-stop.
        case graceEntered(meetingTitle: String, until: Date)
        /// Grace left by rejoin (a `.captureStarted` follows immediately).
        case graceResumed
        /// Grace left by expiry / Finalize now (processing kicks).
        case graceExpired
        /// G9 manual pause: the meeting is held open (no live capture).
        case meetingPaused(meetingTitle: String, accumulatedSeconds: TimeInterval)
        /// G9 paused meeting resumed (a `.captureStarted` follows immediately).
        case meetingResumed
        /// G9 paused meeting Ended → processing (the kick fires).
        case meetingEnded
    }

    @discardableResult
    public mutating func apply(_ input: Input) -> IndicatorState {
        switch input {
        case .captureStarted(let at):
            // A successful start clears a standing alarm and any processing/
            // paused state for THIS meeting; recording resumes the live
            // display. A standing grace for a DIFFERENT meeting stays stored
            // and resurfaces once this recording stops.
            startedAt = at
            micSilence = false
            captureDown = false
            paused = nil
            processing = false
            alarmMessage = nil
        case .captureStopping:
            // Stop pressed: the encode is running → processing is now standing.
            // The session is no longer live.
            startedAt = nil
            micSilence = false
            captureDown = false
            processing = true
        case .captureStopped(let alarm):
            // The stop's encode finished. A NEWER capture may already be live
            // (its start beat this stop's encode): the live recording wins and
            // a stale completion — even a loud one — is dropped (the new
            // capture owns the display). Otherwise a loud failure stands; a
            // clean completion leaves `processing` standing (the encode is
            // done, but the pipeline run continues until `.processingFinished`).
            guard startedAt == nil else { break }
            micSilence = false
            captureDown = false
            if let alarm {
                // The loud path: persists until acknowledged or the next
                // successful start. The encode finished, so it is no longer
                // "processing" — the alarm IS the terminal display.
                alarmMessage = alarm
                processing = false
            }
        case .micSilence(let active):
            micSilence = active
            resolveDisplay(now: nil)
            return state
        case .captureDown(let active):
            captureDown = active
            resolveDisplay(now: nil)
            return state
        case .tick(let now):
            resolveDisplay(now: now)
            return state
        case .processingFinished:
            // The pipeline run finished: clear the processing flag. A standing
            // alarm is untouched (loud by design — it outlives the salvage run).
            processing = false
        case .alarmAcknowledged:
            alarmMessage = nil
        case .graceEntered(let title, let until):
            grace = GraceWindow(title: title, until: until)
        case .graceResumed:
            // Grace left by rejoin; `.captureStarted` follows immediately.
            grace = nil
        case .graceExpired:
            // Grace left by expiry/Finalize now: the finalize kick is running.
            grace = nil
            processing = true
        case .meetingPaused(let title, let seconds):
            // C-1: pause ENDS the live capture for this meeting — clear
            // `startedAt` (and the long-session/mic-silence flags) so the
            // display leaves `.recording` and resolves to `.paused`. The pause
            // path emits only `.paused` (no `.captureStopping/.captureStopped`,
            // by spec §4), so this input is authoritative for the transition.
            startedAt = nil
            micSilence = false
            captureDown = false
            paused = PausedMeeting(title: title, accumulatedSeconds: seconds)
        case .meetingResumed:
            // `.captureStarted` follows immediately.
            paused = nil
        case .meetingEnded:
            // End-from-pause flips into processing.
            paused = nil
            processing = true
        }
        resolveDisplay(now: nil)
        return state
    }

    /// Resolves `state` from the standing inputs in priority order:
    /// live recording > alarm > processing > grace > paused > idle. A LIVE
    /// capture (`startedAt != nil`) outranks the alarm — the alarm belongs to
    /// a finished capture and only shows once nothing is recording (the
    /// stale-completion contract: a new capture owns the display, the alarm
    /// rides the menu). `now` (from `.tick`) upgrades a long session to its
    /// warning; otherwise the long-session warning, once shown, persists.
    private mutating func resolveDisplay(now: Date?) {
        if let startedAt {
            state = recordingDisplay(startedAt: startedAt, now: now)
            return
        }
        if let alarmMessage {
            state = .alarm(message: alarmMessage)
            return
        }
        if processing {
            state = .processing
            return
        }
        if let grace {
            state = .grace(meetingTitle: grace.title, until: grace.until)
            return
        }
        if let paused {
            state = .paused(meetingTitle: paused.title, accumulatedSeconds: paused.accumulatedSeconds)
            return
        }
        state = .idle
    }

    private func recordingDisplay(startedAt: Date, now: Date?) -> IndicatorState {
        let longSession =
            now.map { $0.timeIntervalSince(startedAt) > CaptureLimits.longSessionWarningSeconds }
            ?? isLongSessionShowing
        // Capture-down outranks every other warning. See
        // CaptureSession.captureDownAlarmSeconds for why this must be visible.
        if captureDown {
            return .warning(
                startedAt: startedAt, message: "Audio device changed — recording is paused, retrying")
        } else if micSilence {
            return .warning(startedAt: startedAt, message: "Mic appears silent — check input device")
        } else if longSession {
            return .warning(startedAt: startedAt, message: "Recording for over 6 hours")
        } else {
            return .recording(startedAt: startedAt)
        }
    }

    private var isLongSessionShowing: Bool {
        if case .warning(_, let message) = state { return message.contains("6 hours") }
        return false
    }
}
