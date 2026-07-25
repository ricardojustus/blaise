import Foundation
import os

// C14: the recording-automation brain. A single actor consuming three
// inputs — signals forwarded by the ingestor (lifecycle + per-batch
// liveness), recording-controller lifecycle facts, and a 30 s evaluation
// timer — and owning four behaviors: the meet-start notification (with the
// per-call suppression memory), auto-stop with end-debounce, the watchdog
// for unobservable ends, and the resume grace window. Clock-injected and
// notification-seamed: fully unit-testable, no UNUserNotificationCenter and
// no audio anywhere near it.

// MARK: - Settings (C14)

public enum AutomationSettings {
    /// "Meeting automation (notifications, auto-stop)" toggle, default ON.
    public static let enabledKey = "automation.enabled"
    /// Resume window in seconds: 0 = Off (finalize immediately on
    /// auto-stop); otherwise clamped to 60–600. Default 5 minutes.
    public static let resumeWindowKey = "automation.resumeWindowSeconds"
    public static let defaultResumeWindowSeconds = 300

    /// G15: "Ask me to confirm participants before notes are written" — opt-in,
    /// default OFF. When ON, a meeting whose attendees Blaise could not learn
    /// (empty attendees, no calendar/roster match) holds the notes stage until
    /// the user confirms the participant names; transcription and audio
    /// retention are never blocked. OFF is byte-identical to the pre-G15 flow.
    public static let confirmParticipantsKey = "automation.confirmParticipants"

    /// G15: the auto-skip sub-toggle of the gate above — opt-in, default OFF.
    /// When ON, a meeting still unanswered `confirmParticipantsAutoSkipSeconds`
    /// after its recording stopped proceeds without attendees instead of parking
    /// (or re-parking) on the gate. OFF keeps the park-until-answered semantics.
    public static let confirmParticipantsAutoSkipKey = "automation.confirmParticipantsAutoSkip"

    /// Operator-pinned window (25/07/2026): five minutes, measured from the
    /// recording stop — which IS the ask time, because the confirmation is
    /// raised at stop. Read only when the sub-toggle above is ON.
    public static let confirmParticipantsAutoSkipSeconds: TimeInterval = 300

    public static func clampResumeWindow(_ value: Int) -> Int {
        value <= 0 ? 0 : min(600, max(60, value))
    }

    public static func confirmParticipants(from settings: SettingsStore) async -> Bool {
        (try? await settings.get(confirmParticipantsKey, as: Bool.self)) ?? nil ?? false
    }

    public static func confirmParticipantsAutoSkip(from settings: SettingsStore) async -> Bool {
        (try? await settings.get(confirmParticipantsAutoSkipKey, as: Bool.self)) ?? nil ?? false
    }

    public static func resumeWindowSeconds(from settings: SettingsStore) async -> Int {
        let stored =
            (try? await settings.get(resumeWindowKey, as: Int.self))
            ?? nil ?? defaultResumeWindowSeconds
        return clampResumeWindow(stored)
    }

    public static func enabled(from settings: SettingsStore) async -> Bool {
        (try? await settings.get(enabledKey, as: Bool.self)) ?? nil ?? true
    }
}

// MARK: - Notification seam (UNUserNotificationCenter adapter in BlaiseApp)

public protocol AutomationNotifying: Sendable {
    /// "Meeting in progress" — default action AND the Record button start
    /// the correlated recording; swipe-to-clear = decline.
    func postMeetStart(code: String, title: String?) async
    func withdrawMeetStart(code: String) async
    /// Watchdog stop. `canResume` true → "Recording stopped — meeting
    /// appears to have ended" with a Resume action; false → the
    /// informational variant "Recording ended — uncertain signal", NO
    /// Resume action (Off means Off; a dead button would be worse than
    /// honesty).
    func postWatchdogStop(meetingID: MeetingID, title: String, canResume: Bool) async
    /// Withdrawn when the meeting's grace ends by any path (resume, expiry,
    /// Finalize now, manual stop): a stale "click to resume" hours later
    /// would be a dead surface.
    func withdrawWatchdogStop(meetingID: MeetingID) async
    /// 15-minute zero-signal backstop for notification-initiated recordings.
    func postNudge(meetingID: MeetingID, title: String) async
    /// Calendar pre-meeting "Launch & Record".
    func postCalendarUpcoming(eventKey: String, title: String, start: Date, code: String, urlString: String?) async
    func withdrawCalendarUpcoming(eventKey: String) async
}

public struct NoopAutomationNotifier: AutomationNotifying {
    public init() {}
    public func postMeetStart(code: String, title: String?) async {}
    public func withdrawMeetStart(code: String) async {}
    public func postWatchdogStop(meetingID: MeetingID, title: String, canResume: Bool) async {}
    public func withdrawWatchdogStop(meetingID: MeetingID) async {}
    public func postNudge(meetingID: MeetingID, title: String) async {}
    public func postCalendarUpcoming(eventKey: String, title: String, start: Date, code: String, urlString: String?) async {}
    public func withdrawCalendarUpcoming(eventKey: String) async {}
}

// MARK: - UI mirror events (menu-bar surfaces + indicator inputs)

/// How a grace window left, so the indicator handler applies the right display.
public enum GraceEndReason: Sendable, Equatable {
    /// The user Resumed within the window — back to recording.
    case resumed
    /// The window expired (or Finalize now) — finalize kicked, processing.
    case expired
    /// The user Paused the grace meeting — converted to a durable `paused`
    /// hold. NOT processing: the paused display is driven by the controller's
    /// `.paused` recording event; this only clears the menu's grace line.
    case paused
}

public enum MeetAutomationEvent: Sendable, Equatable {
    case graceEntered(meetingID: MeetingID, code: String, title: String, until: Date)
    /// Grace left — the `reason` distinguishes how (see `GraceEndReason`). All
    /// three clear the menu's grace line; only `.expired` applies the indicator
    /// `.graceExpired`/processing display, and only `.paused` is the grace→Pause
    /// conversion (the paused display is driven by the controller's `.paused`
    /// recording event, not here).
    case graceEnded(meetingID: MeetingID, reason: GraceEndReason)
    /// A live Meet call with no recording (denied-notifications menu
    /// surface: "Meeting detected — Record").
    case meetingDetected(code: String, title: String?)
    case meetingDetectionCleared(code: String)
    /// Meet explicitly reported that the active call ended. Capture continues
    /// only through the short reconnect cushion represented by `until`.
    case meetingEndPending(code: String, until: Date)
    /// A reconnect cancelled the pending end, or capture began stopping.
    case meetingEndPendingCleared(code: String)
    /// The 15-minute zero-signal nudge (menu line under denied
    /// notifications).
    case nudge(meetingID: MeetingID, title: String)
    /// A notification/menu action could not be honored (e.g. the correlated
    /// start dropped because the previous recording never released its
    /// session) — surfaced via the menu's lastActionError line, never a
    /// silent swallow.
    case actionFailed(message: String)
}

// MARK: - Tracker

public actor MeetCallTracker: MeetCallSignalReceiving, RecordingLifecycleObserving {
    // Constants (constants, not settings — resolved decision).
    public static let freshSignalSeconds: TimeInterval = 120
    /// An explicit in-page leave is a high-confidence end. Keep only a short
    /// reconnect cushion so the recording visibly settles within a few seconds.
    public static let explicitLeaveDebounceSeconds: TimeInterval = 5
    /// A pagehide/tab-close can also be a reload, so retain the longer cushion
    /// for that lower-confidence signal.
    public static let endDebounceSeconds: TimeInterval = 25
    public static let watchdogStaleSeconds: TimeInterval = 300
    public static let watchdogConfirmSeconds: TimeInterval = 90
    public static let suppressionExpirySeconds: TimeInterval = 600
    public static let nudgeAfterSeconds: TimeInterval = 900
    public static let evaluationIntervalSeconds: TimeInterval = 30

    public static func debounceSeconds(forEndReason reason: String?) -> TimeInterval {
        reason == "left" ? explicitLeaveDebounceSeconds : endDebounceSeconds
    }

    // Injected.
    private let controller: any RecordingAutomating
    private let notifier: any AutomationNotifying
    private let resumeWindowSeconds: @Sendable () async -> Int
    private let automationEnabled: @Sendable () async -> Bool
    /// Current calendar suggestions (title/attendees for a correlated start;
    /// the meet-start notification body's event title).
    private let suggestions: @Sendable () async -> [MeetingSuggestion]
    /// Calendar-notification withdrawal hook (the scheduler's
    /// call-ended/recording-started obligations).
    private let calendarHook: @Sendable (String) async -> Void
    /// G11 §3: persists the durable resume-grace deadline. Called with a
    /// non-nil epoch-ms at grace ENTRY (before the in-memory timer is armed,
    /// so a crash between write and arm recovers at launch) and with nil at
    /// every grace EXIT (clear-before-action). The tracker holds no DB handle;
    /// the environment (which holds the database) does the write in its own
    /// transaction — the same seam shape as the notification callbacks.
    private let persistGrace: @Sendable (MeetingID, Int64?) async -> Void
    private let now: @Sendable () -> Date
    /// Process-monotonic clock that does NOT advance across sleep
    /// (watchdog confirmation; a sleep/wake gap cannot satisfy the 90 s).
    private let uptime: @Sendable () -> TimeInterval
    /// Precise one-shot timer seam (debounce, grace expiry). Production
    /// sleeps; tests inject a recorder and drive `evaluate()` directly.
    private let schedule: @Sendable (TimeInterval, @escaping @Sendable () async -> Void) -> Void
    /// One nap of the bounded session-release poll in `startCorrelated`
    /// (production sleeps 10 ms; tests inject a no-op to spin it instantly).
    private let startPollNap: @Sendable () async -> Void
    private let logger = Logger(subsystem: BlaiseBundle.identifier, category: "automation.tracker")

    // MARK: State

    /// ONE per-meetingCode monotonic guard covering BOTH signal kinds
    /// (lifecycle `atMs` and liveness `capturedAtMs`): any signal whose
    /// timestamp is ≤ the stored value advances nothing and fires nothing.
    private var lastSignalAtMs: [String: Int64] = [:]

    /// Per-call do-not-nag memory.
    struct Suppression {
        enum Kind { case notified, stopped, paused }
        var kind: Kind
        /// Receipt time of the last fresh signal; 10 min of silence expires
        /// the record (ten missed heartbeats: the call's signal source is
        /// gone, not throttled). G9: the `paused` kind is keyed to the
        /// durable status, NOT the 10-min silence rule — it NEVER expires by
        /// silence (a paused call's own signals can never re-post "Meeting in
        /// progress"); it is cleared explicitly on Resume/End.
        var lastSignalAt: Date
    }
    private var suppressions: [String: Suppression] = [:]

    /// G9: meetings under MANUAL pause control. Lifecycle end events for a
    /// meeting in this set are INGESTED (speaker windows) but produce NO
    /// state transitions; cleared on Resume and on End.
    private var manualControl: Set<MeetingID> = []

    struct ActiveCall {
        var meetingID: MeetingID
        var code: String?
        var title: String
        var startedAt: Date
        var viaNotification: Bool
        /// EVENT time (`atMs`/`capturedAtMs`) of the last correlated signal
        /// during THIS recording; nil = watchdog not armed.
        var lastSignalAt: Date?
        /// Process uptime at the FIRST stale evaluation (watchdog).
        var staleSinceUptime: TimeInterval?
        /// End-debounce deadline (receipt clock + reason-aware cushion).
        var endPendingUntil: Date?
        var nudgeSent = false
    }
    private var activeCall: ActiveCall?

    public struct GraceState: Sendable, Equatable {
        public var meetingID: MeetingID
        public var code: String
        public var title: String
        public var until: Date
    }
    /// Standing grace windows, keyed by meeting. MULTIPLE meetings can hold
    /// grace concurrently (back-to-back meetings: B auto-stops while A's
    /// window is still open); each finalizes at ITS OWN expiry. At most one
    /// window per meeting CODE (the resume target must be unambiguous): a
    /// same-code auto-stop finalizes the standing window first.
    private var graces: [MeetingID: GraceState] = [:]

    /// A `call-ended` that landed before the controller's detached
    /// `recordingStarted` fact (start-instant race): buffered per code,
    /// consumed when the fact arrives, pruned after its reason-aware deadline.
    private var pendingEnds: [String: Date] = [:]

    /// Consumed by the next `recordingStarted` (nudge backstop arming).
    private var nextStartViaNotification = false

    private var eventContinuations: [UUID: AsyncStream<MeetAutomationEvent>.Continuation] = [:]
    private var evaluationTask: Task<Void, Never>?

    public init(
        controller: any RecordingAutomating,
        notifier: any AutomationNotifying,
        resumeWindowSeconds: @escaping @Sendable () async -> Int,
        automationEnabled: @escaping @Sendable () async -> Bool = { true },
        suggestions: @escaping @Sendable () async -> [MeetingSuggestion] = { [] },
        calendarHook: @escaping @Sendable (String) async -> Void = { _ in },
        persistGrace: @escaping @Sendable (MeetingID, Int64?) async -> Void = { _, _ in },
        now: @escaping @Sendable () -> Date = { Date() },
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        schedule: @escaping @Sendable (TimeInterval, @escaping @Sendable () async -> Void) -> Void = {
            delay, operation in
            Task {
                try? await Task.sleep(for: .seconds(delay))
                await operation()
            }
        },
        startPollNap: @escaping @Sendable () async -> Void = {
            try? await Task.sleep(for: .milliseconds(10))
        }
    ) {
        self.controller = controller
        self.notifier = notifier
        self.resumeWindowSeconds = resumeWindowSeconds
        self.automationEnabled = automationEnabled
        self.suggestions = suggestions
        self.calendarHook = calendarHook
        self.persistGrace = persistGrace
        self.now = now
        self.uptime = uptime
        self.schedule = schedule
        self.startPollNap = startPollNap
    }

    /// Production 30 s evaluation timer. Tests never call it — they drive
    /// `evaluate()` with an injected clock.
    public func startEvaluationTimer() {
        guard evaluationTask == nil else { return }
        evaluationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.evaluationIntervalSeconds))
                await self?.evaluate()
            }
        }
    }

    // MARK: Events (UI mirror)

    public func events() -> AsyncStream<MeetAutomationEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            eventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        eventContinuations[id] = nil
    }

    private func emit(_ event: MeetAutomationEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    /// The soonest-expiring grace window (what the menu displays and the
    /// no-argument Resume / Finalize-now actions target).
    public var graceState: GraceState? {
        graces.values.min { $0.until < $1.until }
    }

    /// All standing grace windows, soonest expiry first.
    public var graceStates: [GraceState] {
        graces.values.sorted { $0.until < $1.until }
    }

    public func isInGrace(code: String) -> Bool {
        graces.values.contains { $0.code == code }
    }

    // MARK: - Input 1: ingestor signals

    public func receive(_ signal: MeetCallSignal) async {
        guard await automationEnabled() else { return }
        let code = signal.meetingCode
        let lifecycle = signal.lifecycle
        // The monotonic guard, fed by BOTH timestamp kinds: a replayed
        // ciphertext or out-of-order ring flush carries an old timestamp
        // and can neither re-fire a notification nor keep feeding a dead
        // meeting's watchdog.
        let lifecycleFresh = lifecycle.map { passGuard(code: code, ts: $0.atMs) } ?? false
        let livenessFresh = passGuard(code: code, ts: signal.capturedAtMs)
        guard lifecycleFresh || livenessFresh else { return }

        let receivedAt = now()
        // Every fresh signal refreshes the suppression record WITHOUT
        // re-posting (expired-by-silence records die first).
        expireSuppressions(at: receivedAt)
        if suppressions[code] != nil {
            suppressions[code]?.lastSignalAt = receivedAt
        }
        // Correlated-signal bookkeeping: watchdog arming + staleness clear.
        let eventMs = max(lifecycle?.atMs ?? 0, signal.capturedAtMs)
        if activeCall?.code == code {
            let eventDate = Date(timeIntervalSince1970: Double(eventMs) / 1000.0)
            if activeCall?.lastSignalAt.map({ eventDate > $0 }) ?? true {
                activeCall?.lastSignalAt = eventDate
            }
            activeCall?.staleSinceUptime = nil
        }

        if lifecycleFresh, let lifecycle, lifecycle.kind == .callEnded {
            await handleCallEnded(code: code, reason: lifecycle.reason)
            return
        }

        // call-started / heartbeat / plain liveness from here on: any of
        // them cancels a pending end-debounce for the code (the fast
        // flicker the debounce exists to absorb) — and a buffered
        // pre-start-fact end (the same flicker, caught even earlier).
        if activeCall?.code == code, activeCall?.endPendingUntil != nil {
            activeCall?.endPendingUntil = nil
            emit(.meetingEndPendingCleared(code: code))
            logger.info("end-debounce cancelled by fresh signal for \(code, privacy: .private)")
        }
        pendingEnds[code] = nil

        let kind = lifecycle?.kind
        let signalEventMs = (lifecycleFresh && lifecycle != nil) ? lifecycle!.atMs : signal.capturedAtMs
        let fresh =
            receivedAt.timeIntervalSince1970 - Double(signalEventMs) / 1000.0
            <= Self.freshSignalSeconds

        // Grace rejoin: a fresh call-started OR heartbeat for a grace
        // code resumes ITS meeting — silent, automatic. (Plain liveness
        // does NOT: a delayed post-leave flush must not resurrect the
        // recording.)
        if let grace = graces.values.first(where: { $0.code == code }) {
            if fresh, kind == .callStarted || kind == .heartbeat {
                await resumeFromGrace(meetingID: grace.meetingID)
            }
            return
        }

        // Buffered-stale signals only update bookkeeping (above).
        guard fresh else { return }

        // Notification decision. Late start: a fresh liveness signal of ANY
        // kind for a code with no active recording, no grace, no live
        // suppression record is treated as call-started for notification
        // purposes.
        if let session = await controller.currentSession(), session.meetingCode == code {
            return  // gate (a): already recording this call
        }
        if suppressions[code] != nil {
            return  // gate (c): the user said no once (or already notified) — do not nag
        }
        await postMeetStart(code: code)
    }

    private func passGuard(code: String, ts: Int64) -> Bool {
        if let last = lastSignalAtMs[code], ts <= last { return false }
        lastSignalAtMs[code] = ts
        return true
    }

    private func expireSuppressions(at reference: Date) {
        suppressions = suppressions.filter { _, record in
            // G9: the paused-class record is keyed to the durable status and
            // never expires by silence — it is cleared explicitly on
            // Resume/End so a paused call's own signals can never re-post.
            if record.kind == .paused { return true }
            return reference.timeIntervalSince(record.lastSignalAt) <= Self.suppressionExpirySeconds
        }
    }

    private func postMeetStart(code: String) async {
        let title = (await suggestions()).first { $0.meetingCode == code }?.title
        suppressions[code] = Suppression(kind: .notified, lastSignalAt: now())
        await notifier.postMeetStart(code: code, title: title)
        emit(.meetingDetected(code: code, title: title))
        logger.notice("meet-start notification posted for \(code, privacy: .private)")
    }

    private func handleCallEnded(code: String, reason: String?) async {
        // The meet-start offer is moot; calendar reminders for the code are
        // withdrawn too. The suppression record is NOT cleared (a tab
        // reload's pagehide emits call-ended and the rejoin re-fires
        // call-started minutes later — clearing here would re-nag exactly
        // that case); signal silence expires it ≤ 10 min behind.
        await notifier.withdrawMeetStart(code: code)
        emit(.meetingDetectionCleared(code: code))
        await calendarHook(code)
        guard let session = await controller.currentSession(), session.meetingCode == code else {
            return
        }
        let delay = Self.debounceSeconds(forEndReason: reason)
        let deadline = now().addingTimeInterval(delay)
        if activeCall?.code == code {
            guard activeCall?.endPendingUntil == nil else { return }
            activeCall?.endPendingUntil = deadline
            emit(.meetingEndPending(code: code, until: deadline))
            logger.notice(
                "call-ended for active recording — \(delay, privacy: .public)s end-debounce started (\(reason ?? "unknown", privacy: .public))")
            schedule(delay + 0.1) { [weak self] in
                await self?.fireEndDebounceIfDue()
            }
        } else {
            // The controller session exists but the detached
            // `recordingStarted` fact has not landed yet (start-instant
            // race): buffer the end; the fact's arrival anchors the
            // debounce at THIS receipt time. Without the buffer the stop
            // would wait on the ~6.5 min watchdog instead of 25 s.
            pendingEnds[code] = deadline
            logger.notice("call-ended buffered: start fact not yet delivered")
        }
    }

    // MARK: - Input 2: recording-controller lifecycle facts

    public func recordingStarted(
        meetingID: MeetingID, meetingCode: String?, title: String, partIndex: Int
    ) async {
        // A recording for the code starting by ANY path clears the
        // suppression record and withdraws the offer surfaces.
        if let meetingCode {
            suppressions[meetingCode] = nil
            await notifier.withdrawMeetStart(code: meetingCode)
            emit(.meetingDetectionCleared(code: meetingCode))
            await calendarHook(meetingCode)
        }
        if graces.removeValue(forKey: meetingID) != nil {
            // G11 §3 exit (mechanical: the column clears wherever a grace entry
            // leaves the in-memory map). The rejoin path already cleared it in
            // `resumeFromGrace` before `controller.resume` (r3-M2 ordering);
            // this is the idempotent backstop for any other door that resumes a
            // grace meeting via a fresh `recordingStarted` fact.
            await persistGrace(meetingID, nil)
            emit(.graceEnded(meetingID: meetingID, reason: .resumed))
            await notifier.withdrawWatchdogStop(meetingID: meetingID)
        }
        let via = nextStartViaNotification
        nextStartViaNotification = false
        // A new part re-arms the watchdog from scratch (armed only once a
        // correlated signal arrives during THIS recording).
        activeCall = ActiveCall(
            meetingID: meetingID, code: meetingCode, title: title,
            startedAt: now(), viaNotification: via)
        // A call-ended buffered ahead of this fact (start-instant race):
        // start the debounce now, anchored at the buffered receipt.
        if let meetingCode, let pendingUntil = pendingEnds.removeValue(forKey: meetingCode),
            now() <= pendingUntil
        {
            activeCall?.endPendingUntil = pendingUntil
            emit(.meetingEndPending(code: meetingCode, until: pendingUntil))
            logger.notice("buffered call-ended consumed — end-debounce started")
            schedule(max(0, pendingUntil.timeIntervalSince(now())) + 0.1) { [weak self] in
                await self?.fireEndDebounceIfDue()
            }
        }
    }

    /// G9: a meeting was manually PAUSED. Set `manualControl`; clear the
    /// active-call linkage (the watchdog keys on `activeCall`, so a paused
    /// meeting has nothing to orphan — AC1); withdraw any standing
    /// grace/watchdog notification and emit the `graceEnded` mirror (the
    /// menu's grace line must not go stale); install a non-expiring
    /// paused-class suppression so the meeting's own call can never re-post
    /// "Meeting in progress".
    public func recordingPaused(meetingID: MeetingID, meetingCode: String?) async {
        manualControl.insert(meetingID)
        if activeCall?.meetingID == meetingID {
            if let code = activeCall?.code, activeCall?.endPendingUntil != nil {
                emit(.meetingEndPendingCleared(code: code))
            }
            activeCall = nil
        }
        // Grace→paused conversion: if this meeting held a grace entry, remove
        // it (real cancellation — the scheduled expiry closure no-ops on a
        // missing entry), withdraw the notification, and clear the UI mirror.
        // `.paused`, not `.expired`: the live-pause `.paused` recording event
        // already drives the paused display — applying `.graceExpired` here
        // would clobber it into a false "processing".
        if graces.removeValue(forKey: meetingID) != nil {
            // G11 §3 exit (the race-reachable removal: a detached `recordingPaused`
            // fact landed while a grace entry still stood — resume-then-pause).
            // Clear the durable column so no exempted row outlives the grace
            // entry. The live pause already wrote the meeting durably elsewhere.
            await persistGrace(meetingID, nil)
            emit(.graceEnded(meetingID: meetingID, reason: .paused))
            await notifier.withdrawWatchdogStop(meetingID: meetingID)
        }
        if let meetingCode {
            suppressions[meetingCode] = Suppression(kind: .paused, lastSignalAt: now())
        }
    }

    /// G9: a paused meeting was Resumed (`resumed` true) or Ended (false).
    /// Clear `manualControl` and the paused-class suppression; drain any
    /// `pendingEnds` buffered for the code WITHOUT effect (the meeting was
    /// paused, so no transition is owed). On Resume the subsequent
    /// `recordingStarted` fact re-arms the watchdog and clears suppression
    /// again (idempotent); on End the meeting is leaving for processing.
    public func recordingUnpaused(meetingID: MeetingID, meetingCode: String?, resumed: Bool) async {
        manualControl.remove(meetingID)
        if let meetingCode {
            if suppressions[meetingCode]?.kind == .paused {
                suppressions[meetingCode] = nil
            }
            pendingEnds[meetingCode] = nil
        }
    }

    /// G9: the tracker-level grace→paused conversion (the Pause control on a
    /// meeting currently in grace, no live session). Removes the grace entry,
    /// withdraws its notification, clears the UI mirror, and writes the
    /// meeting durably to `paused` via the controller's End-less pause-of-
    /// grace path. Returns whether a grace entry was converted.
    @discardableResult
    public func pauseFromGrace(meetingID: MeetingID) async -> Bool {
        guard let grace = graces[meetingID] else { return false }
        // M-9: the universal single-open-meeting predicate guards THIS entry
        // too. Refuse a second open meeting — a live session anywhere, OR any
        // OTHER meeting already durably `paused` — so converting grace→paused
        // can never produce two paused meetings (which would break every
        // single-paused assumption: the start prompt, `pausedMeetingID() LIMIT
        // 1`, the quit dialog, the relaunch surface).
        guard await controller.currentSession() == nil else {
            logger.notice("pause-from-grace ignored: a recording is active")
            return false
        }
        guard await controller.pausedMeetingID(excluding: meetingID) == nil else {
            logger.notice("pause-from-grace ignored: another meeting is already paused")
            return false
        }
        graces.removeValue(forKey: meetingID)
        // G11 §3 exit (grace→paused): clear the durable column BEFORE the
        // controller flips `recording → paused`. A kill between the clear and
        // the flip leaves a plain `recording` row (today's launch flip), never
        // a `paused` row carrying a stale grace column.
        await persistGrace(meetingID, nil)
        emit(.graceEnded(meetingID: meetingID, reason: .paused))
        await notifier.withdrawWatchdogStop(meetingID: meetingID)
        manualControl.insert(meetingID)
        suppressions[grace.code] = Suppression(kind: .paused, lastSignalAt: now())
        await controller.pauseGraceMeeting(meetingID: meetingID)
        logger.notice("grace converted to paused for \(meetingID)")
        return true
    }

    public func recordingStopped(meetingID: MeetingID, meetingCode: String?, manual: Bool) async {
        if activeCall?.meetingID == meetingID {
            if let code = activeCall?.code, activeCall?.endPendingUntil != nil {
                emit(.meetingEndPendingCleared(code: code))
            }
            activeCall = nil
        }
        guard manual else { return }
        // B-6: the user deliberately stopped, possibly while staying in the call —
        // neither the late-start rule nor a reload's re-fired call-started
        // may re-offer Record for that call.
        if let meetingCode {
            suppressions[meetingCode] = Suppression(kind: .stopped, lastSignalAt: now())
        }
        if graces.removeValue(forKey: meetingID) != nil {
            // G11 §3 exit (manual stop of a grace meeting): clear the durable
            // column. The manual stop already finalized the meeting through the
            // controller, so processing is owed elsewhere; here we only ensure
            // a kill leaves no exempted-but-stopped row.
            await persistGrace(meetingID, nil)
            emit(.graceEnded(meetingID: meetingID, reason: .expired))
            await notifier.withdrawWatchdogStop(meetingID: meetingID)
        }
    }

    // MARK: - Input 3: the 30 s evaluation

    public func evaluate() async {
        guard await automationEnabled() else { return }
        expireSuppressions(at: now())
        // A buffered pre-start-fact end whose recording never materialized
        // is dropped after its deadline (consuming it later would
        // insta-stop an unrelated fresh recording on the code).
        pendingEnds = pendingEnds.filter { now() <= $0.value }
        await fireEndDebounceIfDue()
        await finalizeGraceIfExpired()
        await checkNudge()
        await checkWatchdog()
    }

    private func fireEndDebounceIfDue() async {
        guard let call = activeCall, let until = call.endPendingUntil,
            now() >= until
        else { return }
        activeCall?.endPendingUntil = nil
        if let code = call.code {
            emit(.meetingEndPendingCleared(code: code))
        }
        logger.notice("end-debounce expired — auto-stopping")
        await performAutoStop(watchdog: false)
    }

    private func checkWatchdog() async {
        guard let call = activeCall, let last = call.lastSignalAt else { return }
        guard call.endPendingUntil == nil else { return }  // the debounce owns the end
        let stale = now().timeIntervalSince(last) > Self.watchdogStaleSeconds
        guard stale else {
            activeCall?.staleSinceUptime = nil
            return
        }
        if let since = call.staleSinceUptime {
            // Confirmation on the process-monotonic clock: a sleep/wake gap
            // cannot satisfy the 90 s, and post-wake heartbeats get a full
            // window to resume.
            if uptime() >= since + Self.watchdogConfirmSeconds {
                logger.notice("watchdog fired — no signal for > 5 min, confirmed over 90 s uptime")
                await performAutoStop(watchdog: true)
            }
        } else {
            activeCall?.staleSinceUptime = uptime()
        }
    }

    private func checkNudge() async {
        guard var call = activeCall, call.viaNotification, !call.nudgeSent,
            call.lastSignalAt == nil,
            now().timeIntervalSince(call.startedAt) >= Self.nudgeAfterSeconds
        else { return }
        call.nudgeSent = true
        activeCall = call
        await notifier.postNudge(meetingID: call.meetingID, title: call.title)
        emit(.nudge(meetingID: call.meetingID, title: call.title))
        logger.notice("zero-signal nudge posted for \(call.meetingID)")
    }

    // MARK: - Auto-stop → grace

    private func performAutoStop(watchdog: Bool) async {
        guard let call = activeCall else { return }
        // G11 §2: the end-signal's debounce-FIRE wall clock (the moment this is
        // invoked — app clock, no extension-timestamp skew). Captured before
        // the stop so it is the FIRE instant, not the post-encode instant.
        let endSignalAt = now()
        let window = await resumeWindowSeconds()
        let outcome: AutoStopOutcome
        do {
            // Off (window 0) finalizes immediately exactly like a manual
            // stop (processing kicks at the stop); otherwise the kick moves
            // to grace expiry.
            outcome = try await controller.autoStop(finalizeImmediately: window == 0)
        } catch {
            // A manual stop won the race — nothing to do.
            logger.info("auto-stop skipped: \(error)")
            return
        }
        activeCall = nil
        let meeting = outcome.meeting
        // G11 §2: classification applies to DEBOUNCE-fired ends only (the
        // watchdog keeps C14's grace + canResume notification). A calendar-
        // anchored meeting whose end-signal landed inside the 10-min band
        // before its scheduled end (or after it) SKIPS grace — the meeting is
        // genuinely over, so the resume window is just latency. Off (window 0)
        // is already an immediate finalize; only window > 0 can reach grace.
        let classifierProcessesNow =
            !watchdog
            && EndDetectionClassifier.classify(
                endSignalAt: endSignalAt, scheduledEndMs: outcome.scheduledEndMs) == .endAndProcess
        if window > 0, outcome.recoverableAudio, let code = call.code, classifierProcessesNow {
            // In-band end on an anchored meeting: process immediately, NO grace
            // entry (no suppression record — non-manual stops never write one,
            // §2's owned aftermath). A same-code standing grace finalizes too
            // (it can never resume past this end). The audio to here is fully
            // retained.
            if let standing = graces.values.first(where: { $0.code == code }) {
                await finalizeGraceNow(meetingID: standing.meetingID)
            }
            await controller.kickProcessing(meetingID: meeting.id)
            logger.notice("in-band end for \(meeting.id) — processed immediately, no grace")
            return
        }
        if window > 0, outcome.recoverableAudio, let code = call.code {
            // A standing grace window for ANOTHER meeting is untouched (it
            // finalizes at its own expiry — back-to-back meetings). One
            // resume target per CODE: a standing same-code window can never
            // resume again, so it finalizes now, before the new entry.
            if let standing = graces.values.first(where: { $0.code == code }) {
                logger.notice("same-code auto-stop — finalizing the standing grace first")
                await finalizeGraceNow(meetingID: standing.meetingID)
            }
            let until = now().addingTimeInterval(TimeInterval(window))
            graces[meeting.id] = GraceState(
                meetingID: meeting.id, code: code, title: meeting.title, until: until)
            // G11 §3: persist the durable grace deadline BEFORE arming the
            // in-memory timer. A crash between this write and the timer arm
            // recovers at launch (the row stays `recording` with a non-nil
            // column → the interrupted-flip exemption + launch recovery).
            await persistGrace(meeting.id, Int64(until.timeIntervalSince1970 * 1000))
            emit(.graceEntered(meetingID: meeting.id, code: code, title: meeting.title, until: until))
            logger.notice("grace entered for \(meeting.id) until \(until)")
            schedule(TimeInterval(window) + 0.1) { [weak self] in
                await self?.finalizeGraceIfExpired()
            }
            if watchdog {
                // The low-confidence path: one click from recovery.
                await notifier.postWatchdogStop(
                    meetingID: meeting.id, title: meeting.title, canResume: true)
            }
        } else {
            // No grace: window Off, no recoverable audio (the controller
            // already took the loud failed path), or a code-less recording.
            if window > 0, outcome.recoverableAudio {
                // Code-less active call cannot re-correlate: finalize now.
                await controller.kickProcessing(meetingID: meeting.id)
            }
            if watchdog {
                await notifier.postWatchdogStop(
                    meetingID: meeting.id, title: meeting.title, canResume: false)
            }
        }
    }

    /// G11 §3 launch recovery: re-enter the in-memory grace window for a
    /// meeting whose durable `grace_until_ms` was still in the future at launch
    /// (the app died mid-grace). Re-arms the grace map entry, the suppression-
    /// equivalent state (a fresh `call-started`/heartbeat resumes it; a stray
    /// notification must not fire for the code meanwhile), and the expiry timer.
    /// Does NOT re-write the durable column — it already stands; the re-armed
    /// grace's own exit clears it. Idempotent: a meeting already in grace is
    /// left as-is.
    public func reenterGrace(
        meetingID: MeetingID, code: String?, title: String, until: Date
    ) async {
        guard graces[meetingID] == nil else { return }
        // A code-less grace can never be rejoined by signal — the recovery
        // routes those to the process-now path and never calls this. Defensive
        // guard only (no in-memory entry to re-arm without a correlation key).
        guard let code else { return }
        graces[meetingID] = GraceState(
            meetingID: meetingID, code: code, title: title, until: until)
        emit(.graceEntered(meetingID: meetingID, code: code, title: title, until: until))
        // Suppression-equivalent state: a notified-class record keyed to the
        // code keeps a stray late-start liveness from re-posting "Meeting in
        // progress" while the re-armed grace stands; a fresh call-started /
        // heartbeat still resumes the grace (the grace check precedes the
        // suppression gate in `receive`).
        suppressions[code] = Suppression(kind: .notified, lastSignalAt: now())
        let remaining = max(0, until.timeIntervalSince(now()))
        schedule(remaining + 0.1) { [weak self] in
            await self?.finalizeGraceIfExpired()
        }
        logger.notice("grace re-entered at launch for \(meetingID) until \(until)")
    }

    private func finalizeGraceIfExpired() async {
        let due = graces.values.filter { now() >= $0.until }.sorted { $0.until < $1.until }
        for grace in due {
            await finalizeGraceNow(meetingID: grace.meetingID)
        }
    }

    /// The menu's "Finalize now" (acts on the displayed, soonest-expiring
    /// window).
    public func finalizeGraceNow() async {
        guard let soonest = graceState else { return }
        await finalizeGraceNow(meetingID: soonest.meetingID)
    }

    /// Grace expiry AND Finalize now (and the same-code preempt): kick
    /// `processCaptured` via the existing track-inventory-aware dispatch.
    public func finalizeGraceNow(meetingID: MeetingID) async {
        guard graces.removeValue(forKey: meetingID) != nil else { return }
        // G11 §3 exit (clear-before-action): clear the durable column BEFORE
        // the processing kick. A kill mid-exit then recovers as a plain
        // crashed `recording` under today's flip+sweep, never as an
        // exempted-but-live-crashed row.
        await persistGrace(meetingID, nil)
        emit(.graceEnded(meetingID: meetingID, reason: .expired))
        await notifier.withdrawWatchdogStop(meetingID: meetingID)
        logger.notice("grace ended for \(meetingID) — finalizing")
        await controller.kickProcessing(meetingID: meetingID)
    }

    /// The menu's Resume item (acts on the displayed, soonest-expiring
    /// window).
    public func resumeFromGrace() async {
        guard let soonest = graceState else { return }
        await resumeFromGrace(meetingID: soonest.meetingID)
    }

    /// M-1: the menu's Pause item on a meeting currently in grace (acts on the
    /// displayed, soonest-expiring window) — converts grace→paused.
    @discardableResult
    public func pauseGrace() async -> Bool {
        guard let soonest = graceState else { return false }
        return await pauseFromGrace(meetingID: soonest.meetingID)
    }

    /// The grace rejoin (signal-driven), the `meetStart`/watchdog
    /// notification actions, and the menu's Resume item — all resume the
    /// same way.
    public func resumeFromGrace(meetingID: MeetingID) async {
        guard graces[meetingID] != nil else { return }
        guard await controller.currentSession() == nil else {
            // One session at a time; the grace meeting finalizes at expiry.
            logger.notice("resume signal ignored: a different recording is active")
            return
        }
        // G11 §3 exit ordering (r3-M2): the rejoin-resume exit clears the
        // durable grace column BEFORE `controller.resume` opens the live
        // new-part session. A kill after-clear-before-resume degrades to
        // today's flip + redispatch (safe — the row goes `failed`/interrupted
        // and re-processes); a kill after the live session opened but before
        // the clear would otherwise leave a LIVE-crashed exempted row whose
        // crashed part the recovery would silently omit. The in-memory map
        // entry is removed by the subsequent `recordingStarted` fact.
        await persistGrace(meetingID, nil)
        do {
            _ = try await controller.resume(meetingID: meetingID)
            // recordingStarted clears the grace entry and emits the event.
        } catch {
            // The resume failed and no live session opened: re-arm the durable
            // column so the still-standing grace entry stays recoverable
            // across a crash before its expiry.
            if let grace = graces[meetingID] {
                await persistGrace(
                    meetingID, Int64(grace.until.timeIntervalSince1970 * 1000))
            }
            logger.error("grace resume failed: \(error) — grace continues until expiry")
        }
    }

    // MARK: - Notification / menu actions

    /// The meet-start notification's default + Record action (and the
    /// denied-mode menu's Record button).
    public func recordActionClicked(code: String) async {
        await notifier.withdrawMeetStart(code: code)
        emit(.meetingDetectionCleared(code: code))
        if let session = await controller.currentSession(), session.meetingCode == code {
            // The gating should have suppressed it; this closes the race.
            return
        }
        if let grace = graces.values.first(where: { $0.code == code }),
            await controller.currentSession() == nil
        {
            await resumeFromGrace(meetingID: grace.meetingID)
            return
        }
        let suggestion = (await suggestions()).first { $0.meetingCode == code }
        await startCorrelated(
            code: code, title: suggestion?.title, attendees: suggestion?.attendees ?? [],
            anchor: suggestion.flatMap(CalendarAnchor.init(suggestion:)))
    }

    /// Shared by the meet-start Record action and the calendar Launch &
    /// Record action: an active DIFFERENT recording is stopped first
    /// (immediate finalize, no grace — the explicit back-to-back signal);
    /// the start rides the existing start-while-finalizing support. Never a
    /// silently swallowed `alreadyRecording` throw. `anchor` (§1) is persisted
    /// at start when the start was suggestion-matched.
    public func startCorrelated(
        code: String, title: String?, attendees: [Attendee], anchor: CalendarAnchor? = nil
    ) async {
        if let session = await controller.currentSession() {
            if session.meetingCode == code { return }  // same code: no-op
            // Stop in a child task: stop() returns only after the encode,
            // but the session is released first — poll for the release so
            // the new recording starts while the previous one finalizes.
            let controller = self.controller
            Task { _ = try? await controller.stop(alarm: nil) }
            var attempts = 0
            while await controller.currentSession() != nil, attempts < 500 {
                attempts += 1
                await startPollNap()
            }
            if await controller.currentSession() != nil {
                // The previous stop is still holding the session after the
                // 5 s poll budget: surface the dropped click (the
                // notification was already withdrawn) instead of swallowing
                // an `alreadyRecording` throw.
                emit(.actionFailed(message:
                    "Could not start recording for \(code): the previous recording is still finalizing — try again from the menu"))
                logger.error("correlated start dropped: session still active after stop poll")
                return
            }
        }
        nextStartViaNotification = true
        do {
            // C15: the correlated recording inherits its source from the code
            // (`slack:…` → `.slack`, else `.meet`) — no longer hardcoded, so a
            // Slack-huddle Record action files under the right source.
            _ = try await controller.start(
                source: MeetingSource(forMeetingCode: code), title: title, meetingCode: code,
                attendees: attendees, anchor: anchor)
        } catch {
            nextStartViaNotification = false
            emit(.actionFailed(message: "Could not start recording for \(code): \(error)"))
            logger.error("correlated start failed: \(error)")
        }
    }
}
