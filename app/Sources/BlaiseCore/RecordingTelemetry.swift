import Foundation

// G12 §1/§2 — the pure, headless-testable MODELS behind the menu-bar live
// timer and the two-channel in-app level meter. Owned by BlaiseCore so the
// formatting, the state mapping, the RMS smoothing, the ≤10 Hz publish cap and
// the silence-detection thresholds are unit-pinned without a SwiftUI host. The
// views (menu-bar label, toolbar meter) are thin renderers over these values;
// their visual check is deferred to the deploy ask (§5).

// MARK: - Menu-bar live timer (§1)

/// The menu-bar recording readout: a red-tinted accent glyph plus a live
/// `MM:SS` (or `H:MM:SS` past an hour) timer while recording, and a paused
/// variant carrying the accumulated time with no tick. Fixed-width digits
/// (`.monospacedDigit()` on the rendering `Text`) keep the menu-bar item from
/// jittering as the timer rolls; the digit roll is the only motion (delight
/// budget — no other menu-bar animation).
public enum RecordingTimerModel {
    /// What the menu-bar item should show, derived from the indicator state.
    public enum Display: Equatable, Sendable {
        /// Idle/processing/grace/alarm: the existing glyph, no timer.
        case glyph
        /// Live recording: red accent glyph + elapsed `formatted` timer.
        case recording(formatted: String)
        /// Paused: amber-class accent glyph + accumulated `formatted` time, no tick.
        case paused(formatted: String)
    }

    /// Maps the indicator state to the menu-bar display. `now` drives the live
    /// elapsed; for `.paused` the accumulated time rides the state itself (no
    /// clock read — a paused timer never ticks).
    public static func display(for state: IndicatorState, now: Date) -> Display {
        switch state {
        case .recording(let startedAt), .warning(let startedAt, _):
            return .recording(formatted: format(seconds: now.timeIntervalSince(startedAt)))
        case .paused(_, let accumulatedSeconds):
            return .paused(formatted: format(seconds: accumulatedSeconds))
        case .idle, .processing, .alarm, .grace:
            return .glyph
        }
    }

    /// The quiet states (no live timer): the handoff-warning badge may take
    /// the menu-bar glyph here. Recording/paused are NOT quiet — the live
    /// timer owns the item.
    public static func isQuietState(_ state: IndicatorState) -> Bool {
        switch state {
        case .idle, .processing, .grace, .alarm: return true
        case .recording, .warning, .paused: return false
        }
    }

    /// `MM:SS`, rolling to `H:MM:SS` once a session passes one hour. Negative
    /// inputs (a clock skew between the start stamp and `now`) clamp to zero so
    /// the readout never shows a negative timer. The minute/second fields are
    /// always two digits; the hour field is unpadded (`1:02:03`, not
    /// `01:02:03`) so the common < 1 h case stays the compact `MM:SS`.
    public static func format(seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}

/// Pure RMS of one capture buffer window, normalized to [0, 1]. Handles the
/// two interleaved sample formats the capture path produces — Float32 (the
/// CoreAudio process tap's native delivery) and Int16 (the canonical CAF
/// format) — keyed off `bytesPerSample`. Empty/odd-length data → 0. No audio
/// taps of its own: the IOProc already has the bytes; this just measures them.
public enum AudioRMS {
    /// `bytesPerSample`: 4 → Float32, 2 → Int16. Any other value → 0 (the
    /// caller has no usable format, so the meter shows quiet rather than noise).
    public static func rms(of data: Data, bytesPerSample: Int) -> Double {
        switch bytesPerSample {
        case 4: return float32RMS(data)
        case 2: return int16RMS(data)
        default: return 0
        }
    }

    private static func float32RMS(_ data: Data) -> Double {
        let count = data.count / 4
        guard count > 0 else { return 0 }
        var sumSquares = 0.0
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Float32.self)
            for i in 0..<count {
                let v = Double(samples[i])
                sumSquares += v * v
            }
        }
        return min(1, (sumSquares / Double(count)).squareRoot())
    }

    private static func int16RMS(_ data: Data) -> Double {
        let count = data.count / 2
        guard count > 0 else { return 0 }
        var sumSquares = 0.0
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<count {
                let v = Double(samples[i]) / 32768.0
                sumSquares += v * v
            }
        }
        return min(1, (sumSquares / Double(count)).squareRoot())
    }
}

// MARK: - Two-channel level meter (§2)

/// One channel's published meter level: a smoothed 0…1 magnitude plus the
/// silence flag (the channel has been below the silence floor for ≥
/// `LevelMeter.silenceThreshold` while recording — the bar renders hollow with
/// a warning tint, the "something's wrong" glance, never a modal).
public struct ChannelLevel: Equatable, Sendable {
    /// Smoothed RMS magnitude in [0, 1].
    public var level: Double
    /// The channel has been silent ≥ the threshold (render hollow + warn).
    public var silent: Bool

    public init(level: Double = 0, silent: Bool = false) {
        self.level = level
        self.silent = silent
    }
}

/// Both channels' published levels — the lock-free value the meter view (and
/// nothing else) observes. A new pair is published at most `LevelMeter.maxHz`
/// times a second; see `LevelMeter`.
public struct MeterLevels: Equatable, Sendable {
    public var you: ChannelLevel
    public var others: ChannelLevel

    public init(you: ChannelLevel = ChannelLevel(), others: ChannelLevel = ChannelLevel()) {
        self.you = you
        self.others = others
    }
}

/// Pure RMS smoothing + silence-detection + publish-rate math for ONE channel,
/// fed the raw RMS of each capture buffer by the IOProc. No audio taps of its
/// own (the IOProc already touches every buffer); no SwiftUI, no clock of its
/// own — the caller passes a monotonic timestamp so the thresholds are
/// deterministic under test.
public struct LevelMeterChannel: Equatable, Sendable {
    /// Exponential-moving-average smoothing factor (per ingested sample). A
    /// new RMS contributes `smoothing`; the running value keeps `1 −
    /// smoothing`. 0.3 settles a step in a few buffers without the bar
    /// twitching per sample.
    public static let smoothing = 0.3
    /// Below this smoothed magnitude the channel counts as silent.
    public static let silenceFloor = 0.01
    /// Silent for at least this long (s) while recording → the warning glance.
    public static let silenceThreshold: TimeInterval = 10

    public private(set) var smoothed = 0.0
    /// The last timestamp the smoothed level was ABOVE the silence floor — the
    /// silence clock's origin. nil until the first above-floor sample.
    public private(set) var lastAboveFloorAt: Date?

    public init() {}

    /// Ingest one buffer's raw RMS (already in [0, 1]) observed at `at`. EMA
    /// smoothing; the silence clock advances from the last above-floor sample.
    public mutating func ingest(rms: Double, at: Date) {
        let clamped = min(1, max(0, rms))
        smoothed = Self.smoothing * clamped + (1 - Self.smoothing) * smoothed
        if smoothed >= Self.silenceFloor {
            lastAboveFloorAt = at
        }
    }

    /// Whether this channel is silent as of `now`: the smoothed level has sat
    /// below the floor for ≥ `silenceThreshold`. Before any above-floor sample
    /// the channel is treated as silent from the recording's start `since`.
    public func isSilent(now: Date, since recordingStart: Date) -> Bool {
        guard smoothed < Self.silenceFloor else { return false }
        let lastHeard = lastAboveFloorAt ?? recordingStart
        return now.timeIntervalSince(lastHeard) >= Self.silenceThreshold
    }

    /// The channel's published level snapshot as of `now`.
    public func channelLevel(now: Date, since recordingStart: Date) -> ChannelLevel {
        ChannelLevel(level: smoothed, silent: isSilent(now: now, since: recordingStart))
    }
}

/// The two-channel meter model: a `you`/`others` pair of `LevelMeterChannel`,
/// the ≤ `maxHz` publish gate, and the silence thresholds. The IOProc feeds raw
/// RMS into `ingestYou`/`ingestOthers` at the buffer rate; the model publishes
/// a new `MeterLevels` only when `minPublishInterval` has elapsed (no
/// per-sample UI churn). Pure and clock-injected — fully unit-testable.
public struct LevelMeter: Equatable, Sendable {
    /// The UI publish-rate cap (Hz). Buffers arrive far faster than this; the
    /// gate drops intermediate frames so the meter updates ≤ 10×/s.
    public static let maxHz = 10.0
    public static var minPublishInterval: TimeInterval { 1.0 / maxHz }

    public private(set) var you = LevelMeterChannel()
    public private(set) var others = LevelMeterChannel()
    /// The recording start — the origin of each channel's pre-first-sample
    /// silence clock.
    public let recordingStart: Date
    /// The last time a frame was PUBLISHED (the ≤ 10 Hz gate's clock). nil
    /// until the first publish.
    public private(set) var lastPublishedAt: Date?

    public init(recordingStart: Date) {
        self.recordingStart = recordingStart
    }

    public mutating func ingestYou(rms: Double, at: Date) {
        you.ingest(rms: rms, at: at)
    }

    public mutating func ingestOthers(rms: Double, at: Date) {
        others.ingest(rms: rms, at: at)
    }

    /// Whether a publish is due at `now`: the first frame always publishes;
    /// thereafter only once `minPublishInterval` has elapsed since the last
    /// publish (the ≤ `maxHz` cap).
    public func shouldPublish(now: Date) -> Bool {
        guard let last = lastPublishedAt else { return true }
        return now.timeIntervalSince(last) >= Self.minPublishInterval
    }

    /// The current published levels as of `now`, marking `lastPublishedAt`.
    /// The caller publishes the returned `MeterLevels` into the lock-free
    /// holder only when `shouldPublish(now:)` is true.
    public mutating func publish(now: Date) -> MeterLevels {
        lastPublishedAt = now
        return MeterLevels(
            you: you.channelLevel(now: now, since: recordingStart),
            others: others.channelLevel(now: now, since: recordingStart))
    }
}

// MARK: - Silence auto-pause watchdog (§3)

/// An orthogonal capture-path fallback to the `MeetCallTracker` end-detector:
/// when BOTH tracks — the mic ("you") and the system ("others") — sit below the
/// silence floor continuously for `thresholdSeconds`, fire ONCE to auto-pause
/// the recording (resumable, crash-safe; the caller routes through the normal
/// pause path, which never touches captured audio). Pure and clock-injected:
/// the caller passes a MONOTONIC uptime value, so the silence timer is
/// deterministic under test. It only SIGNALS — the caller performs the pause and
/// `disarm()`s on a true return, so it fires at most once per recording session.
///
/// The clock is process uptime (`ProcessInfo.processInfo.systemUptime` at the
/// call sites), NOT wall-clock `Date`: a sleep/wake or NTP step never advances
/// it across an unobserved gap, so a clock jump can never make the elapsed
/// silence reach the threshold instantly and false-fire. This matches the
/// in-repo `MeetCallTracker` watchdog, which confirms on the same monotonic
/// clock for exactly this reason.
///
/// Distinct from `LevelMeterChannel`'s per-channel UI silence glance: this is a
/// single dual-track timer over the RAW per-buffer RMS, defaulting to a much
/// longer threshold (10 min), and it pauses rather than tinting a bar. It reuses
/// the SAME silence floor as the meter (one floor, never a second constant).
public struct SilenceWatchdog: Equatable, Sendable {
    /// The silence floor, reused from the per-channel meter logic.
    public static let silenceFloor = LevelMeterChannel.silenceFloor

    /// Master enable (Settings, default on). A disabled watchdog never fires.
    public var enabled: Bool
    /// Sustained dual-silence this long (s) → fire. Default 600 (10 min).
    public var thresholdSeconds: TimeInterval
    /// Armed between a recording start/resume and the next pause/stop, and
    /// cleared after firing (the at-most-once-per-session guard).
    public private(set) var armed = false
    /// The last MONOTONIC uptime (s) EITHER track was above the floor — the
    /// silence clock's origin. Set to the arm uptime so a recording silent from
    /// the very start still waits the full threshold. Monotonic (process
    /// uptime), so an unobserved sleep/wake gap does not advance it.
    public private(set) var lastAboveFloorUptime: TimeInterval?

    public init(enabled: Bool = true, thresholdSeconds: TimeInterval = 600) {
        self.enabled = enabled
        self.thresholdSeconds = thresholdSeconds
    }

    /// Arm for a new live session (recording start / resume): the silence clock
    /// starts at `nowUptime` (a monotonic process-uptime value).
    public mutating func arm(nowUptime: TimeInterval) {
        armed = true
        lastAboveFloorUptime = nowUptime
    }

    /// Disarm (pause / stop, or after firing). A disarmed watchdog never fires.
    public mutating func disarm() {
        armed = false
    }

    /// Ingest one level sample (raw per-channel RMS) observed at `nowUptime` (a
    /// monotonic process-uptime value). Any above-floor sample on EITHER track
    /// resets the silence clock. Returns true exactly when the recording should
    /// auto-pause NOW: armed, enabled, and BOTH tracks below the floor
    /// continuously for `thresholdSeconds` of uptime. The caller pauses and
    /// `disarm()`s on a true return.
    public mutating func note(you: Double, others: Double, nowUptime: TimeInterval) -> Bool {
        guard enabled, armed else { return false }
        if you > Self.silenceFloor || others > Self.silenceFloor {
            lastAboveFloorUptime = nowUptime
        }
        let since = lastAboveFloorUptime ?? nowUptime
        return nowUptime - since >= thresholdSeconds
    }
}

/// The two settings gating the silence auto-pause watchdog, read at each arm
/// (recording start / resume) so a change takes effect on the next session
/// without a relaunch. Mirrors `AutomationSettings`.
public enum SilenceAutoPauseSettings {
    /// Master toggle, default ON.
    public static let enabledKey = "recording.silenceAutoPause.enabled"
    public static let defaultEnabled = true
    /// Sustained dual-silence threshold (s), default 600 (10 min).
    public static let thresholdSecondsKey = "recording.silenceAutoPause.thresholdSeconds"
    public static let defaultThresholdSeconds: TimeInterval = 600

    public static func enabled(from settings: SettingsStore) async -> Bool {
        (try? await settings.get(enabledKey, as: Bool.self)) ?? nil ?? defaultEnabled
    }

    public static func thresholdSeconds(from settings: SettingsStore) async -> TimeInterval {
        (try? await settings.get(thresholdSecondsKey, as: TimeInterval.self)) ?? nil
            ?? defaultThresholdSeconds
    }
}
