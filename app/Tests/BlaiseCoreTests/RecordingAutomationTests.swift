import Foundation
import Synchronization
import Testing

@testable import BlaiseCore

// C14 AC1: the MeetCallTracker state machine — notification gating, the
// per-call suppression record, end-debounce, watchdog (staleSince + 90 s
// uptime confirmation incl. sleep-gap immunity), grace resume/expiry, the
// configured Resume window incl. Off, and the 15-min zero-signal nudge.
// Clock-injected; controller and notifier mocked (no audio, no UN*).

// MARK: - Mocks

private final class MockBox<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ value: T) { self.value = value }
    func with<R>(_ body: (inout T) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

private final class MockAutomationController: RecordingAutomating, @unchecked Sendable {
    struct State {
        var session: RecordingSessionInfo?
        var meetings: [MeetingID: Meeting] = [:]
        var startCalls: [(title: String?, code: String?, attendees: [Attendee])] = []
        /// G11: the calendar anchor passed to each start (AC2 — anchor written
        /// when suggestion-matched, nil for ad-hoc).
        var startAnchors: [CalendarAnchor?] = []
        var stopCalls = 0
        var autoStopCalls: [Bool] = []  // finalizeImmediately values
        var resumeCalls: [MeetingID] = []
        var kicks: [MeetingID] = []
        var autoStopRecoverable = true
        var resumeError: Error?
        /// false simulates a stop whose off-actor encode never releases the
        /// session (the startCorrelated poll-exhaustion corner).
        var stopReleasesSession = true
        // G9
        var pauseCalls = 0
        var resumePausedCalls: [MeetingID] = []
        var endPausedCalls: [MeetingID] = []
        var pauseGraceCalls: [MeetingID] = []
        var pausedMeetingIDs: [MeetingID] = []
    }

    let state = MockBox(State())

    func currentSession() async -> RecordingSessionInfo? {
        state.with { $0.session }
    }

    @discardableResult
    func start(
        source: MeetingSource, title: String?, meetingCode: String?, attendees: [Attendee],
        anchor: CalendarAnchor?
    ) async throws -> Meeting {
        let meeting = makeMeeting(title: title ?? "Auto", source: source, status: .recording)
        return state.with { s in
            var stored = meeting
            stored.meetingCode = meetingCode
            stored.calendarEventID = anchor?.eventIdentifier
            stored.scheduledEndMs = anchor?.scheduledEndMs
            s.startCalls.append((title, meetingCode, attendees))
            s.startAnchors.append(anchor)
            s.session = RecordingSessionInfo(meetingID: stored.id, meetingCode: meetingCode)
            s.meetings[stored.id] = stored
            return stored
        }
    }

    @discardableResult
    func stop(alarm: String?) async throws -> Meeting {
        try state.with { s in
            guard let session = s.session, let meeting = s.meetings[session.meetingID] else {
                throw RecordingControllerError.notRecording
            }
            s.stopCalls += 1
            if s.stopReleasesSession { s.session = nil }
            return meeting
        }
    }

    func autoStop(finalizeImmediately: Bool) async throws -> AutoStopOutcome {
        try state.with { s in
            guard let session = s.session, let meeting = s.meetings[session.meetingID] else {
                throw RecordingControllerError.notRecording
            }
            s.autoStopCalls.append(finalizeImmediately)
            s.session = nil
            return AutoStopOutcome(
                meeting: meeting, recoverableAudio: s.autoStopRecoverable,
                scheduledEndMs: meeting.scheduledEndMs)
        }
    }

    @discardableResult
    func resume(meetingID: MeetingID) async throws -> Meeting {
        try state.with { s in
            if let error = s.resumeError { throw error }
            guard let meeting = s.meetings[meetingID] else {
                throw BlaiseDatabaseError.meetingNotFound(meetingID)
            }
            s.resumeCalls.append(meetingID)
            s.session = RecordingSessionInfo(meetingID: meetingID, meetingCode: meeting.meetingCode)
            return meeting
        }
    }

    func kickProcessing(meetingID: MeetingID) async {
        state.with { $0.kicks.append(meetingID) }
    }

    // MARK: - G9

    @discardableResult
    func pause() async throws -> Meeting {
        try state.with { s in
            guard let session = s.session, var meeting = s.meetings[session.meetingID] else {
                throw RecordingControllerError.notRecording
            }
            s.pauseCalls += 1
            meeting.status = .paused
            s.meetings[meeting.id] = meeting
            s.pausedMeetingIDs.append(meeting.id)
            s.session = nil
            return meeting
        }
    }

    @discardableResult
    func resumePaused(meetingID: MeetingID) async throws -> Meeting {
        try state.with { s in
            guard var meeting = s.meetings[meetingID] else {
                throw BlaiseDatabaseError.meetingNotFound(meetingID)
            }
            s.resumePausedCalls.append(meetingID)
            meeting.status = .recording
            s.meetings[meetingID] = meeting
            s.pausedMeetingIDs.removeAll { $0 == meetingID }
            s.session = RecordingSessionInfo(meetingID: meetingID, meetingCode: meeting.meetingCode)
            return meeting
        }
    }

    @discardableResult
    func endPaused(meetingID: MeetingID) async throws -> Meeting {
        try state.with { s in
            guard var meeting = s.meetings[meetingID] else {
                throw BlaiseDatabaseError.meetingNotFound(meetingID)
            }
            s.endPausedCalls.append(meetingID)
            meeting.status = .processing
            s.meetings[meetingID] = meeting
            s.pausedMeetingIDs.removeAll { $0 == meetingID }
            return meeting
        }
    }

    func pauseGraceMeeting(meetingID: MeetingID) async {
        state.with { s in
            s.pauseGraceCalls.append(meetingID)
            if var meeting = s.meetings[meetingID] {
                meeting.status = .paused
                s.meetings[meetingID] = meeting
            }
            s.pausedMeetingIDs.append(meetingID)
        }
    }

    func pausedMeetingID(excluding: MeetingID?) async -> MeetingID? {
        state.with { s in s.pausedMeetingIDs.first { $0 != excluding } }
    }
}

private final class MockNotifier: AutomationNotifying, @unchecked Sendable {
    struct State {
        var meetStarts: [(code: String, title: String?)] = []
        var meetStartWithdrawals: [String] = []
        var watchdogStops: [(meetingID: MeetingID, canResume: Bool)] = []
        var watchdogWithdrawals: [MeetingID] = []
        var nudges: [MeetingID] = []
        var calendarPosts: [(eventKey: String, title: String, code: String)] = []
        var calendarWithdrawals: [String] = []
    }

    let state = MockBox(State())

    func postMeetStart(code: String, title: String?) async {
        state.with { $0.meetStarts.append((code, title)) }
    }
    func withdrawMeetStart(code: String) async {
        state.with { $0.meetStartWithdrawals.append(code) }
    }
    func postWatchdogStop(meetingID: MeetingID, title: String, canResume: Bool) async {
        state.with { $0.watchdogStops.append((meetingID, canResume)) }
    }
    func withdrawWatchdogStop(meetingID: MeetingID) async {
        state.with { $0.watchdogWithdrawals.append(meetingID) }
    }
    func postNudge(meetingID: MeetingID, title: String) async {
        state.with { $0.nudges.append(meetingID) }
    }
    func postCalendarUpcoming(
        eventKey: String, title: String, start: Date, code: String, urlString: String?
    ) async {
        state.with { $0.calendarPosts.append((eventKey, title, code)) }
    }
    func withdrawCalendarUpcoming(eventKey: String) async {
        state.with { $0.calendarWithdrawals.append(eventKey) }
    }
}

// MARK: - Harness

private struct TrackerHarness {
    let tracker: MeetCallTracker
    let controller: MockAutomationController
    let notifier: MockNotifier
    let clock: MockBox<Date>
    let uptime: MockBox<TimeInterval>
    let window: MockBox<Int>
    /// G11 §3: the persist-grace seam record — each (meetingID, until?) the
    /// tracker wrote. A non-nil `until` = grace entry, nil = a grace exit clear.
    let graceWrites: MockBox<[(meetingID: MeetingID, until: Int64?)]>

    static let code = "abc-defg-hij"
    static let epoch = Date(timeIntervalSince1970: 1_781_136_000)

    /// The last persisted grace deadline for `meetingID` (nil if it was cleared
    /// or never written).
    func lastGraceWrite(_ meetingID: MeetingID) -> Int64?? {
        graceWrites.with { $0.last { $0.meetingID == meetingID }?.until }
    }

    /// Advances wall clock AND uptime together (the normal awake case).
    func advance(_ seconds: TimeInterval) {
        clock.with { $0 = $0.addingTimeInterval(seconds) }
        uptime.with { $0 += seconds }
    }

    /// A sleep gap: wall clock advances, uptime does not.
    func sleep(_ seconds: TimeInterval) {
        clock.with { $0 = $0.addingTimeInterval(seconds) }
    }

    func nowMs() -> Int64 {
        clock.with { Int64($0.timeIntervalSince1970 * 1000) }
    }

    func signal(
        code: String = TrackerHarness.code, kind: MeetWireLifecycle.Kind? = nil,
        atMs: Int64? = nil, capturedAtMs: Int64? = nil, reason: String? = nil
    ) async {
        let ts = atMs ?? nowMs()
        await tracker.receive(
            MeetCallSignal(
                meetingCode: code,
                capturedAtMs: capturedAtMs ?? ts,
                lifecycle: kind.map { MeetWireLifecycle(kind: $0, atMs: ts, reason: reason) }))
    }

    func meetStartCount() -> Int { notifier.state.with { $0.meetStarts.count } }
}

private func makeTrackerHarness(
    resumeWindow: Int = 300, enabled: Bool = true,
    suggestions: [MeetingSuggestion] = [],
    startPollNap: @escaping @Sendable () async -> Void = {
        try? await Task.sleep(for: .milliseconds(10))
    }
) -> TrackerHarness {
    let controller = MockAutomationController()
    let notifier = MockNotifier()
    let clock = MockBox(TrackerHarness.epoch)
    let uptime = MockBox<TimeInterval>(10_000)
    let window = MockBox(resumeWindow)
    let graceWrites = MockBox<[(meetingID: MeetingID, until: Int64?)]>([])
    let tracker = MeetCallTracker(
        controller: controller,
        notifier: notifier,
        resumeWindowSeconds: { window.with { $0 } },
        automationEnabled: { enabled },
        suggestions: { suggestions },
        persistGrace: { meetingID, until in
            graceWrites.with { $0.append((meetingID, until)) }
        },
        now: { clock.with { $0 } },
        uptime: { uptime.with { $0 } },
        schedule: { _, _ in },  // tests drive evaluate() with the fake clock
        startPollNap: startPollNap
    )
    return TrackerHarness(
        tracker: tracker, controller: controller, notifier: notifier,
        clock: clock, uptime: uptime, window: window, graceWrites: graceWrites)
}

/// Puts the harness in the "recording an ANCHORED call" state: starts a
/// recording carrying a calendar anchor (scheduled end) and feeds the tracker
/// the lifecycle fact. The mock stores `scheduledEndMs` so the §2 classifier
/// sees it at auto-stop.
private func startAnchoredRecording(
    _ h: TrackerHarness, code: String = TrackerHarness.code, title: String = "Weekly sync",
    scheduledEnd: Date
) async throws -> Meeting {
    let meeting = try await h.controller.start(
        source: .meet, title: title, meetingCode: code, attendees: [],
        anchor: CalendarAnchor(eventIdentifier: "evt-fiction", scheduledEnd: scheduledEnd))
    await h.tracker.recordingStarted(
        meetingID: meeting.id, meetingCode: code, title: title, partIndex: 1)
    return meeting
}

/// Puts the harness in the "recording the call" state: starts a correlated
/// recording through the controller and feeds the tracker the lifecycle
/// fact (what the controller's observer does in production).
private func startRecording(
    _ h: TrackerHarness, code: String? = TrackerHarness.code, title: String = "Weekly sync"
) async throws -> Meeting {
    let meeting = try await h.controller.start(
        source: .meet, title: title, meetingCode: code, attendees: [], anchor: nil)
    await h.tracker.recordingStarted(
        meetingID: meeting.id, meetingCode: code, title: title, partIndex: 1)
    return meeting
}

// MARK: - Tests

@Suite("C14 tracker: meet-start notification + suppression")
struct TrackerNotificationTests {
    @Test("fresh call-started posts the notification once; heartbeats never re-nag")
    func freshCallStartedPosts() async {
        let h = makeTrackerHarness()
        await h.signal(kind: .callStarted)
        #expect(h.meetStartCount() == 1)
        // Heartbeats every 60 s for the whole call refresh the record
        // WITHOUT re-posting.
        for _ in 0..<5 {
            h.advance(60)
            await h.signal(kind: .heartbeat)
        }
        #expect(h.meetStartCount() == 1)
    }

    @Test("stale buffered call-started (> 120 s old) only updates bookkeeping")
    func staleCallStartedDoesNotPost() async {
        let h = makeTrackerHarness()
        let staleTs = h.nowMs() - 300_000  // 5 min old
        await h.signal(kind: .callStarted, atMs: staleTs, capturedAtMs: staleTs)
        #expect(h.meetStartCount() == 0)
    }

    @Test("late-start rule: fresh plain liveness with no recording/grace/suppression posts")
    func lateStartLiveness() async {
        let h = makeTrackerHarness()
        await h.signal()  // no lifecycle at all (roster/speech batch)
        #expect(h.meetStartCount() == 1)
    }

    @Test("gate (a): a recording with the same code is active — no notification")
    func activeSameCodeGates() async throws {
        let h = makeTrackerHarness()
        _ = try await startRecording(h)
        await h.signal(kind: .callStarted)
        #expect(h.meetStartCount() == 0)
    }

    @Test("a DIFFERENT active code does NOT gate the notification")
    func differentActiveCodeStillPosts() async throws {
        let h = makeTrackerHarness()
        _ = try await startRecording(h, code: "zzz-zzzz-zzz")
        await h.signal(kind: .callStarted)
        #expect(h.meetStartCount() == 1)
    }

    @Test("monotonic guard: a replayed signal re-fires nothing and regresses no lastSignalAt")
    func replayGuard() async {
        let h = makeTrackerHarness()
        let ts = h.nowMs()
        await h.signal(kind: .callStarted, atMs: ts, capturedAtMs: ts)
        #expect(h.meetStartCount() == 1)
        // Expire the suppression record by 10 min of silence, then REPLAY
        // the original ciphertext's signal: old timestamp → dropped, no
        // re-post even though no suppression record stands anymore.
        h.advance(700)
        await h.tracker.evaluate()
        await h.signal(kind: .callStarted, atMs: ts, capturedAtMs: ts)
        #expect(h.meetStartCount() == 1)
    }

    @Test("suppression: posted-and-ignored suppresses for the call's lifetime, not 10 rolling minutes")
    func suppressionLifetime() async {
        let h = makeTrackerHarness()
        await h.signal(kind: .callStarted)
        #expect(h.meetStartCount() == 1)
        // 30 minutes of heartbeats: the record's lastSignalAt keeps
        // refreshing; the late-start rule must never re-offer.
        for _ in 0..<30 {
            h.advance(60)
            await h.signal(kind: .heartbeat)
        }
        #expect(h.meetStartCount() == 1)
    }

    @Test("suppression expires after 10 min of signal silence; a new call on the code re-offers")
    func suppressionSilenceExpiry() async {
        let h = makeTrackerHarness()
        await h.signal(kind: .callStarted)
        #expect(h.meetStartCount() == 1)
        h.advance(601)  // ten missed heartbeats
        await h.tracker.evaluate()
        await h.signal(kind: .callStarted)
        #expect(h.meetStartCount() == 2)
    }

    @Test("call-ended does NOT clear the suppression record (tab-reload re-nag protection)")
    func callEndedKeepsSuppression() async {
        let h = makeTrackerHarness()
        await h.signal(kind: .callStarted)
        h.advance(30)
        await h.signal(kind: .callEnded, reason: "pagehide")
        // The reload's rejoin re-fires call-started 2 minutes later — still
        // inside the record's silence window: no re-nag.
        h.advance(120)
        await h.signal(kind: .callStarted)
        #expect(h.meetStartCount() == 1)
    }

    @Test("manual stop while staying in the call: stopped record suppresses the late-start rule")
    func manualStopSuppresses() async throws {
        let h = makeTrackerHarness()
        let meeting = try await startRecording(h)
        await h.signal(kind: .heartbeat)
        // The user stops manually (B-6) while the call continues.
        _ = try await h.controller.stop(alarm: nil)
        await h.tracker.recordingStopped(
            meetingID: meeting.id, meetingCode: TrackerHarness.code, manual: true)
        // Heartbeats keep arriving; neither they nor a reload's re-fired
        // call-started may re-offer Record.
        h.advance(60)
        await h.signal(kind: .heartbeat)
        h.advance(60)
        await h.signal(kind: .callStarted)
        #expect(h.meetStartCount() == 0)
    }

    @Test("a recording starting by ANY path clears the record and withdraws the notification")
    func startClearsRecord() async throws {
        let h = makeTrackerHarness()
        await h.signal(kind: .callStarted)
        #expect(h.meetStartCount() == 1)
        _ = try await startRecording(h)
        #expect(h.notifier.state.with { $0.meetStartWithdrawals }.contains(TrackerHarness.code))
    }

    @Test("notification body carries the matching calendar suggestion's title")
    func suggestionTitle() async {
        let suggestion = MeetingSuggestion(
            title: "Reunião Vexatron", start: TrackerHarness.epoch, source: .meet,
            meetingCode: TrackerHarness.code, attendees: [])
        let h = makeTrackerHarness(suggestions: [suggestion])
        await h.signal(kind: .callStarted)
        #expect(h.notifier.state.with { $0.meetStarts.first?.title } == "Reunião Vexatron")
    }

    @Test("automation toggle off: no notifications, no state")
    func disabledTracker() async {
        let h = makeTrackerHarness(enabled: false)
        await h.signal(kind: .callStarted)
        #expect(h.meetStartCount() == 0)
    }
}

// Discriminating coverage for the per-code monotonic guard in ISOLATION
// (audit M-1): each test replays a signal that every OTHER gate would let
// through — delete `passGuard` and all three fail. The 120 s freshness
// check, the suppression record, and the per-call gates cannot absorb any
// of them.
@Suite("C14 tracker: monotonic guard (discriminating, in isolation)")
struct TrackerMonotonicGuardTests {
    @Test("a replayed signal must NOT cancel a live end-debounce")
    func replayCannotCancelDebounce() async throws {
        let h = makeTrackerHarness()
        _ = try await startRecording(h)
        let heartbeatTs = h.nowMs()
        await h.signal(kind: .heartbeat, atMs: heartbeatTs, capturedAtMs: heartbeatTs)
        h.advance(10)
        await h.signal(kind: .callEnded, reason: "pagehide")  // long reload-safe debounce
        h.advance(5)
        // Replay the earlier heartbeat: 15 s old — INSIDE the 120 s fresh
        // window, for the active code, mid-debounce. Only the monotonic
        // guard stands between it and a debounce cancel.
        await h.signal(kind: .heartbeat, atMs: heartbeatTs, capturedAtMs: heartbeatTs)
        h.advance(21)  // 26 s past call-ended
        await h.tracker.evaluate()
        #expect(
            h.controller.state.with { $0.autoStopCalls } == [false],
            "the debounce survived the replay and auto-stopped on time")
    }

    @Test("a replayed signal must NOT clear watchdog staleness or advance lastSignalAt")
    func replayCannotFeedWatchdog() async throws {
        let h = makeTrackerHarness(resumeWindow: 300)
        _ = try await startRecording(h)
        let ts = h.nowMs()
        await h.signal(kind: .heartbeat, atMs: ts, capturedAtMs: ts)  // arms the watchdog
        h.advance(310)
        await h.tracker.evaluate()  // FIRST stale evaluation: staleSince recorded
        // Replay the arming signal (old timestamp): it must neither clear
        // staleSince nor advance lastSignalAt — a dead meeting's watchdog
        // is not fed by replays.
        await h.signal(atMs: ts, capturedAtMs: ts)
        h.advance(91)
        await h.tracker.evaluate()
        #expect(
            h.controller.state.with { $0.autoStopCalls } == [false],
            "the watchdog fired on schedule — the replay fed nothing")
    }

    @Test("a fresh-window replay re-fires NO notification once no suppression record stands")
    func freshWindowReplayDoesNotRepost() async throws {
        let h = makeTrackerHarness(resumeWindow: 0)
        let ts = h.nowMs()
        await h.signal(kind: .callStarted, atMs: ts, capturedAtMs: ts)
        #expect(h.meetStartCount() == 1)
        // The user records the call (clears the suppression record), then the
        // call ends and the Off-window auto-stop finalizes (no grace).
        _ = try await startRecording(h)
        h.advance(5)
        await h.signal(kind: .heartbeat)
        h.advance(10)
        await h.signal(kind: .callEnded, reason: "left")
        h.advance(26)
        await h.tracker.evaluate()
        #expect(await h.tracker.graceState == nil)
        // 41 s after the original call-started: INSIDE the 120 s fresh
        // window, no active session, no grace, no suppression record —
        // only the monotonic guard prevents a duplicate post.
        await h.signal(kind: .callStarted, atMs: ts, capturedAtMs: ts)
        #expect(h.meetStartCount() == 1)
    }
}

@Suite("C14 tracker: Record action")
struct TrackerRecordActionTests {
    @Test("Record with the SAME code active: no-op + withdraw")
    func sameCodeNoop() async throws {
        let h = makeTrackerHarness()
        _ = try await startRecording(h)
        await h.tracker.recordActionClicked(code: TrackerHarness.code)
        #expect(h.controller.state.with { $0.stopCalls } == 0)
        #expect(h.controller.state.with { $0.startCalls.count } == 1)  // the harness's own start
        #expect(h.notifier.state.with { $0.meetStartWithdrawals }.contains(TrackerHarness.code))
    }

    @Test("Record while a DIFFERENT recording is active: stop-then-start, never a swallowed throw")
    func differentActiveStopsThenStarts() async throws {
        let h = makeTrackerHarness()
        _ = try await startRecording(h, code: "zzz-zzzz-zzz")
        await h.tracker.recordActionClicked(code: TrackerHarness.code)
        #expect(h.controller.state.with { $0.stopCalls } == 1)
        let starts = h.controller.state.with { $0.startCalls }
        #expect(starts.count == 2)
        #expect(starts.last?.code == TrackerHarness.code)
    }

    @Test("Record with a code-less manual recording active: stop-then-start too")
    func codelessActiveStopsThenStarts() async throws {
        let h = makeTrackerHarness()
        _ = try await startRecording(h, code: nil)
        await h.tracker.recordActionClicked(code: TrackerHarness.code)
        #expect(h.controller.state.with { $0.stopCalls } == 1)
        #expect(h.controller.state.with { $0.startCalls.last?.code } == TrackerHarness.code)
    }

    @Test("calendar action path (startCorrelated): same code active → no-op, no split recording")
    func calendarSameCodeNoop() async throws {
        let h = makeTrackerHarness()
        _ = try await startRecording(h)
        await h.tracker.startCorrelated(code: TrackerHarness.code, title: "Event", attendees: [])
        #expect(h.controller.state.with { $0.stopCalls } == 0)
        #expect(h.controller.state.with { $0.startCalls.count } == 1)
    }

    // L-5: poll exhaustion (the previous stop's encode never releases the
    // session) must surface, not swallow, the click.
    @Test("startCorrelated poll exhaustion emits actionFailed — never a silently dropped click")
    func pollExhaustionSurfaces() async throws {
        // Shortened nap: the 500-attempt budget exhausts in ~tens of ms
        // (a real suspension each nap so the child stop task still runs).
        let h = makeTrackerHarness(startPollNap: {
            try? await Task.sleep(for: .microseconds(50))
        })
        _ = try await startRecording(h, code: "zzz-zzzz-zzz")
        h.controller.state.with { $0.stopReleasesSession = false }  // stalled encode
        let events = await h.tracker.events()
        let collected = MockBox<[MeetAutomationEvent]>([])
        let consumer = Task {
            for await event in events { collected.with { $0.append(event) } }
        }
        await h.tracker.startCorrelated(code: TrackerHarness.code, title: nil, attendees: [])
        // The stop was attempted (fired in a child task — poll for it), the
        // start was NOT (it would have thrown alreadyRecording into a log),
        // and the failure surfaced.
        #expect(await waitUntil { h.controller.state.with { $0.stopCalls } == 1 })
        #expect(h.controller.state.with { $0.startCalls.count } == 1)  // only the harness's own
        let surfaced = await waitUntil {
            collected.with {
                $0.contains { event in
                    if case .actionFailed(let message) = event {
                        return message.contains(TrackerHarness.code)
                    }
                    return false
                }
            }
        }
        #expect(surfaced, "the dropped click surfaced via actionFailed (menu lastActionError)")
        consumer.cancel()
    }

    @Test("Record start carries the matching suggestion's title and attendees")
    func startCarriesSuggestion() async {
        let suggestion = MeetingSuggestion(
            title: "Planning", start: TrackerHarness.epoch, source: .meet,
            meetingCode: TrackerHarness.code,
            attendees: [Attendee(name: "Maria Silva", source: .calendar)])
        let h = makeTrackerHarness(suggestions: [suggestion])
        await h.tracker.recordActionClicked(code: TrackerHarness.code)
        let start = h.controller.state.with { $0.startCalls.last }
        #expect(start?.title == "Planning")
        #expect(start?.attendees.map(\.name) == ["Maria Silva"])
    }
}

@Suite("C14 tracker: end-debounce + auto-stop")
struct TrackerEndDebounceTests {
    @Test("explicit Leave uses a 5 s reconnect cushion, then auto-stops")
    func debounceExpiryStops() async throws {
        let h = makeTrackerHarness()
        _ = try await startRecording(h)
        await h.signal(kind: .heartbeat)
        h.advance(10)
        await h.signal(kind: .callEnded, reason: "left")
        #expect(h.controller.state.with { $0.autoStopCalls }.isEmpty)  // not yet
        h.advance(4)
        await h.tracker.evaluate()
        #expect(h.controller.state.with { $0.autoStopCalls }.isEmpty)  // 4 s < 5 s
        h.advance(2)
        await h.tracker.evaluate()
        #expect(h.controller.state.with { $0.autoStopCalls } == [false])  // grace window on
        // Clean signal-confirmed end: NO watchdog notification.
        #expect(h.notifier.state.with { $0.watchdogStops }.isEmpty)
    }

    @Test("pagehide keeps the 25 s reload-safe debounce")
    func pagehideKeepsLongDebounce() async throws {
        let h = makeTrackerHarness()
        _ = try await startRecording(h)
        await h.signal(kind: .callEnded, reason: "pagehide")
        h.advance(6)
        await h.tracker.evaluate()
        #expect(h.controller.state.with { $0.autoStopCalls }.isEmpty)
        h.advance(20)
        await h.tracker.evaluate()
        #expect(h.controller.state.with { $0.autoStopCalls } == [false])
    }

    @Test("a fresh heartbeat within the debounce cancels it")
    func heartbeatCancelsDebounce() async throws {
        let h = makeTrackerHarness()
        _ = try await startRecording(h)
        await h.signal(kind: .callEnded, reason: "left")
        h.advance(2)
        await h.signal(kind: .heartbeat)  // Meet's automatic reconnect
        h.advance(60)
        await h.tracker.evaluate()
        #expect(h.controller.state.with { $0.autoStopCalls }.isEmpty)
        #expect(h.controller.state.with { $0.session } != nil)
    }

    // L-3: the start-instant race — the controller session exists but the
    // detached recordingStarted fact has not been delivered yet.
    @Test("explicit Leave before the recordingStarted fact is buffered, not dropped (5 s stop)")
    func callEndedBeforeStartFactBuffered() async throws {
        let h = makeTrackerHarness()
        _ = try await h.controller.start(
            source: .meet, title: "Weekly sync", meetingCode: TrackerHarness.code, attendees: [], anchor: nil)
        // The fact is still in flight when call-ended lands.
        await h.signal(kind: .callEnded, reason: "left")
        let session = try #require(h.controller.state.with { $0.session })
        await h.tracker.recordingStarted(
            meetingID: session.meetingID, meetingCode: TrackerHarness.code, title: "Weekly sync",
            partIndex: 1)
        h.advance(6)
        await h.tracker.evaluate()
        #expect(
            h.controller.state.with { $0.autoStopCalls } == [false],
            "the buffered end anchored the explicit-leave debounce — stopped in ~5 s")
    }

    @Test("a fresh signal cancels a buffered pre-start-fact end (flicker absorbed)")
    func bufferedEndCancelledByFreshSignal() async throws {
        let h = makeTrackerHarness()
        _ = try await h.controller.start(
            source: .meet, title: "Weekly sync", meetingCode: TrackerHarness.code, attendees: [], anchor: nil)
        await h.signal(kind: .callEnded, reason: "left")
        h.advance(2)
        await h.signal(kind: .heartbeat)  // the reconnect flicker
        let session = try #require(h.controller.state.with { $0.session })
        await h.tracker.recordingStarted(
            meetingID: session.meetingID, meetingCode: TrackerHarness.code, title: "Weekly sync",
            partIndex: 1)
        h.advance(60)
        await h.tracker.evaluate()
        #expect(h.controller.state.with { $0.autoStopCalls }.isEmpty)
        #expect(h.controller.state.with { $0.session } != nil)
    }

    @Test("a stale buffered end is pruned — it never insta-stops a later recording on the code")
    func staleBufferedEndPruned() async throws {
        let h = makeTrackerHarness()
        _ = try await h.controller.start(
            source: .meet, title: "Weekly sync", meetingCode: TrackerHarness.code, attendees: [], anchor: nil)
        await h.signal(kind: .callEnded, reason: "left")
        // The fact never arrives inside the debounce span (or arrives for a
        // much later recording on the same code).
        h.advance(120)
        await h.tracker.evaluate()
        let session = try #require(h.controller.state.with { $0.session })
        await h.tracker.recordingStarted(
            meetingID: session.meetingID, meetingCode: TrackerHarness.code, title: "Weekly sync",
            partIndex: 1)
        h.advance(60)
        await h.tracker.evaluate()
        #expect(h.controller.state.with { $0.autoStopCalls }.isEmpty)
    }

    @Test("call-ended for a NON-active code never stops the recording")
    func otherCodeEndIgnored() async throws {
        let h = makeTrackerHarness()
        _ = try await startRecording(h)
        await h.signal(code: "zzz-zzzz-zzz", kind: .callEnded, reason: "left")
        h.advance(60)
        await h.tracker.evaluate()
        #expect(h.controller.state.with { $0.autoStopCalls }.isEmpty)
    }
}

@Suite("C14 tracker: grace window")
struct TrackerGraceTests {
    private func autoStopIntoGrace(_ h: TrackerHarness) async throws -> Meeting {
        let meeting = try await startRecording(h)
        await h.signal(kind: .heartbeat)
        h.advance(5)
        await h.signal(kind: .callEnded, reason: "left")
        h.advance(26)
        await h.tracker.evaluate()
        return meeting
    }

    @Test("auto-stop with ≥1 recoverable part enters grace for the configured window")
    func graceEntered() async throws {
        let h = makeTrackerHarness(resumeWindow: 300)
        let meeting = try await autoStopIntoGrace(h)
        let grace = await h.tracker.graceState
        #expect(grace?.meetingID == meeting.id)
        #expect(grace?.code == TrackerHarness.code)
        // No processing kick yet — it moves to grace expiry.
        #expect(h.controller.state.with { $0.kicks }.isEmpty)
    }

    @Test("fresh call-started during grace resumes (part n+1), silent and automatic")
    func graceResumeOnCallStarted() async throws {
        let h = makeTrackerHarness()
        let meeting = try await autoStopIntoGrace(h)
        h.advance(60)
        await h.signal(kind: .callStarted)
        #expect(h.controller.state.with { $0.resumeCalls } == [meeting.id])
        // Production: the controller's observer reports the resume start.
        await h.tracker.recordingStarted(
            meetingID: meeting.id, meetingCode: TrackerHarness.code, title: meeting.title,
            partIndex: 2)
        #expect(await h.tracker.graceState == nil)
        #expect(h.controller.state.with { $0.kicks }.isEmpty)  // resumed, not finalized
        #expect(h.meetStartCount() == 0)  // never a notification for a rejoin
    }

    @Test("fresh heartbeat during grace resumes too; plain liveness does NOT")
    func graceResumeSignals() async throws {
        let h = makeTrackerHarness()
        let meeting = try await autoStopIntoGrace(h)
        h.advance(30)
        await h.signal()  // plain liveness (e.g. a delayed post-leave flush)
        #expect(h.controller.state.with { $0.resumeCalls }.isEmpty)
        h.advance(30)
        await h.signal(kind: .heartbeat)
        #expect(h.controller.state.with { $0.resumeCalls } == [meeting.id])
    }

    @Test("grace expiry finalizes: kicks processing once")
    func graceExpiry() async throws {
        let h = makeTrackerHarness(resumeWindow: 300)
        let meeting = try await autoStopIntoGrace(h)
        h.advance(301)
        await h.tracker.evaluate()
        #expect(h.controller.state.with { $0.kicks } == [meeting.id])
        #expect(await h.tracker.graceState == nil)
        // A later call-started is a NEW meeting → notification again.
        h.advance(700)  // suppression silence expiry first
        await h.tracker.evaluate()
        await h.signal(kind: .callStarted)
        #expect(h.meetStartCount() == 1)
        #expect(h.controller.state.with { $0.resumeCalls }.isEmpty)
    }

    @Test("Resume window Off: auto-stop finalizes immediately, no grace state ever")
    func offMeansOff() async throws {
        let h = makeTrackerHarness(resumeWindow: 0)
        _ = try await autoStopIntoGrace(h)
        #expect(h.controller.state.with { $0.autoStopCalls } == [true])  // finalize immediately
        #expect(await h.tracker.graceState == nil)
    }

    @Test("no grace after a no-recoverable-audio auto-stop")
    func noGraceWithoutAudio() async throws {
        let h = makeTrackerHarness(resumeWindow: 300)
        h.controller.state.with { $0.autoStopRecoverable = false }
        _ = try await autoStopIntoGrace(h)
        #expect(await h.tracker.graceState == nil)
        #expect(h.controller.state.with { $0.kicks }.isEmpty)  // nothing to process
    }

    @Test("resume signal while a DIFFERENT recording is active is ignored")
    func resumeIgnoredWhileOtherActive() async throws {
        let h = makeTrackerHarness()
        _ = try await autoStopIntoGrace(h)
        // A different recording starts during the grace window.
        let other = try await h.controller.start(
            source: .zoom, title: "Other", meetingCode: nil, attendees: [], anchor: nil)
        await h.tracker.recordingStarted(
            meetingID: other.id, meetingCode: nil, title: "Other", partIndex: 1)
        h.advance(30)
        await h.signal(kind: .callStarted)
        #expect(h.controller.state.with { $0.resumeCalls }.isEmpty)
        #expect(await h.tracker.graceState != nil)  // finalizes at expiry
    }

    @Test("finalizeGraceNow (menu Finalize now) ends grace and kicks immediately")
    func finalizeNow() async throws {
        let h = makeTrackerHarness()
        let meeting = try await autoStopIntoGrace(h)
        await h.tracker.finalizeGraceNow()
        #expect(h.controller.state.with { $0.kicks } == [meeting.id])
        #expect(await h.tracker.graceState == nil)
    }

    // H-1: a back-to-back auto-stop during a standing grace must not
    // overwrite it (the audit's stranded-meeting probe, inverted).
    @Test("back-to-back: B's auto-stop inside A's grace strands nothing — both finalize at their own expiries, A first")
    func backToBackGraceOverlap() async throws {
        let h = makeTrackerHarness(resumeWindow: 300)
        let codeB = "bbb-bbbb-bbb"
        // Meeting A auto-stops into grace.
        let a = try await autoStopIntoGrace(h)
        #expect(await h.tracker.graceState?.meetingID == a.id)
        // The user records meeting B while A's window is open; B's short call
        // ends and ITS auto-stop lands inside A's remaining window.
        h.advance(30)
        let b = try await startRecording(h, code: codeB, title: "Standup")
        await h.signal(code: codeB, kind: .heartbeat)
        h.advance(60)
        await h.signal(code: codeB, kind: .callEnded, reason: "left")
        h.advance(26)
        await h.tracker.evaluate()
        // BOTH windows stand — A's was not overwritten.
        #expect(await h.tracker.graceStates.map(\.meetingID) == [a.id, b.id], "soonest (A) first")
        // A finalizes at A'S expiry; B's window is still open.
        h.advance(190)
        await h.tracker.evaluate()
        #expect(h.controller.state.with { $0.kicks } == [a.id])
        #expect(await h.tracker.graceStates.map(\.meetingID) == [b.id])
        // B finalizes at ITS expiry: kicks land in order, nothing stranded.
        h.advance(120)
        await h.tracker.evaluate()
        #expect(h.controller.state.with { $0.kicks } == [a.id, b.id])
        #expect(await h.tracker.graceState == nil)
    }

    @Test("back-to-back: a rejoin signal resumes ITS meeting among several standing windows")
    func rejoinTargetsItsWindow() async throws {
        let h = makeTrackerHarness(resumeWindow: 300)
        let codeB = "bbb-bbbb-bbb"
        let a = try await autoStopIntoGrace(h)
        h.advance(30)
        let b = try await startRecording(h, code: codeB, title: "Standup")
        await h.signal(code: codeB, kind: .heartbeat)
        h.advance(40)
        await h.signal(code: codeB, kind: .callEnded, reason: "left")
        h.advance(26)
        await h.tracker.evaluate()
        #expect(await h.tracker.graceStates.count == 2)
        // The user rejoins meeting A's call: A resumes, B's window stands.
        h.advance(10)
        await h.signal(kind: .callStarted)
        #expect(h.controller.state.with { $0.resumeCalls } == [a.id])
        await h.tracker.recordingStarted(
            meetingID: a.id, meetingCode: TrackerHarness.code, title: a.title, partIndex: 2)
        #expect(await h.tracker.graceStates.map(\.meetingID) == [b.id])
    }

    @Test("same-code back-to-back: the standing window finalizes before the new one is installed (one resume target per code)")
    func sameCodeGraceCollision() async throws {
        let h = makeTrackerHarness(resumeWindow: 300)
        let a = try await autoStopIntoGrace(h)
        // A NEW recording on the SAME code (manual B-6 start): A can never
        // resume again once it ends.
        h.advance(30)
        let b = try await startRecording(h, title: "Round two")
        h.advance(20)
        await h.signal(kind: .heartbeat)
        h.advance(30)
        await h.signal(kind: .callEnded, reason: "left")
        h.advance(26)
        await h.tracker.evaluate()
        // A finalized (kicked) when B's grace took the code over.
        #expect(h.controller.state.with { $0.kicks } == [a.id])
        #expect(await h.tracker.graceStates.map(\.meetingID) == [b.id])
    }

    @Test("failed resume keeps grace standing until expiry")
    func failedResumeKeepsGrace() async throws {
        let h = makeTrackerHarness()
        let meeting = try await autoStopIntoGrace(h)
        h.controller.state.with {
            $0.resumeError = RecordingControllerError.insufficientDiskSpace(freeBytes: 0)
        }
        h.advance(30)
        await h.signal(kind: .callStarted)
        #expect(await h.tracker.graceState != nil)
        h.advance(280)
        await h.tracker.evaluate()
        #expect(h.controller.state.with { $0.kicks } == [meeting.id])
    }
}

@Suite("C14 tracker: watchdog")
struct TrackerWatchdogTests {
    @Test("never armed without a correlated signal: no auto-stop however long the silence")
    func unarmedNeverFires() async throws {
        let h = makeTrackerHarness()
        _ = try await startRecording(h)
        // A Meet recording without the extension running: zero signals.
        for _ in 0..<30 {
            h.advance(60)
            await h.tracker.evaluate()
        }
        #expect(h.controller.state.with { $0.autoStopCalls }.isEmpty)
    }

    @Test("staleSince + 90 s confirmation: fires after >5 min stale across two evaluations")
    func firesAfterConfirmation() async throws {
        let h = makeTrackerHarness(resumeWindow: 300)
        let meeting = try await startRecording(h)
        await h.signal(kind: .heartbeat)  // arms the watchdog
        h.advance(310)  // > 5 min with no signal
        await h.tracker.evaluate()  // FIRST stale evaluation: records staleSince
        #expect(h.controller.state.with { $0.autoStopCalls }.isEmpty)
        h.advance(30)
        await h.tracker.evaluate()  // 30 s < 90 s confirmation
        #expect(h.controller.state.with { $0.autoStopCalls }.isEmpty)
        h.advance(61)
        await h.tracker.evaluate()  // ≥ staleSince + 90 s → FIRE
        #expect(h.controller.state.with { $0.autoStopCalls } == [false])
        // Grace on → Resume-bearing notification.
        let stops = h.notifier.state.with { $0.watchdogStops }
        #expect(stops.count == 1)
        #expect(stops.first?.canResume == true)
        #expect(await h.tracker.graceState?.meetingID == meeting.id)
    }

    @Test("sleep-gap immunity: wall-stale but uptime-frozen evaluations cannot confirm")
    func sleepGapImmunity() async throws {
        let h = makeTrackerHarness()
        _ = try await startRecording(h)
        await h.signal(kind: .heartbeat)
        // The Mac sleeps 20 minutes: wall clock advances, uptime does not.
        h.sleep(1200)
        await h.tracker.evaluate()  // stale → staleSince recorded (at frozen uptime)
        h.sleep(300)
        await h.tracker.evaluate()  // uptime unchanged: cannot satisfy +90 s
        #expect(h.controller.state.with { $0.autoStopCalls }.isEmpty)
        // Post-wake heartbeat resumes the call before the awake window
        // reaches 90 s.
        h.advance(30)
        await h.signal(kind: .heartbeat)
        h.advance(60)
        await h.tracker.evaluate()
        #expect(h.controller.state.with { $0.autoStopCalls }.isEmpty)
    }

    @Test("fresh signal between stale evaluations clears staleSince")
    func freshSignalClearsStale() async throws {
        let h = makeTrackerHarness()
        _ = try await startRecording(h)
        await h.signal(kind: .heartbeat)
        h.advance(310)
        await h.tracker.evaluate()  // staleSince recorded
        await h.signal(kind: .heartbeat)  // network recovered
        h.advance(95)
        await h.tracker.evaluate()
        #expect(h.controller.state.with { $0.autoStopCalls }.isEmpty)
    }

    // L-6: the Resume-bearing watchdog notification must not outlive its
    // grace window (a stale "click to resume" hours later is a dead surface).
    @Test("watchdog Resume notification is withdrawn at grace expiry")
    func watchdogNotificationWithdrawnOnExpiry() async throws {
        let h = makeTrackerHarness(resumeWindow: 300)
        let meeting = try await startRecording(h)
        await h.signal(kind: .heartbeat)
        h.advance(310)
        await h.tracker.evaluate()
        h.advance(91)
        await h.tracker.evaluate()  // watchdog fires → grace + Resume notification
        #expect(h.notifier.state.with { $0.watchdogStops.count } == 1)
        #expect(h.notifier.state.with { $0.watchdogWithdrawals }.isEmpty)
        h.advance(301)
        await h.tracker.evaluate()  // grace expires → finalize
        #expect(h.notifier.state.with { $0.watchdogWithdrawals } == [meeting.id])
        #expect(h.controller.state.with { $0.kicks } == [meeting.id])
    }

    @Test("watchdog Resume notification is withdrawn when the grace resumes")
    func watchdogNotificationWithdrawnOnResume() async throws {
        let h = makeTrackerHarness(resumeWindow: 300)
        let meeting = try await startRecording(h)
        await h.signal(kind: .heartbeat)
        h.advance(310)
        await h.tracker.evaluate()
        h.advance(91)
        await h.tracker.evaluate()  // watchdog fires → grace
        h.advance(30)
        await h.signal(kind: .heartbeat)  // signals return → auto-resume
        #expect(h.controller.state.with { $0.resumeCalls } == [meeting.id])
        await h.tracker.recordingStarted(
            meetingID: meeting.id, meetingCode: TrackerHarness.code, title: meeting.title,
            partIndex: 2)
        #expect(h.notifier.state.with { $0.watchdogWithdrawals } == [meeting.id])
    }

    @Test("Resume window Off: watchdog stop posts the informational variant, no Resume")
    func offWatchdogInformational() async throws {
        let h = makeTrackerHarness(resumeWindow: 0)
        _ = try await startRecording(h)
        await h.signal(kind: .heartbeat)
        h.advance(310)
        await h.tracker.evaluate()
        h.advance(91)
        await h.tracker.evaluate()
        #expect(h.controller.state.with { $0.autoStopCalls } == [true])
        let stops = h.notifier.state.with { $0.watchdogStops }
        #expect(stops.count == 1)
        #expect(stops.first?.canResume == false)
        #expect(await h.tracker.graceState == nil)
    }

    @Test("watchdog stop with NO recoverable audio: informational variant, never grace")
    func watchdogNoAudioInformational() async throws {
        let h = makeTrackerHarness(resumeWindow: 300)
        h.controller.state.with { $0.autoStopRecoverable = false }
        _ = try await startRecording(h)
        await h.signal(kind: .heartbeat)
        h.advance(310)
        await h.tracker.evaluate()
        h.advance(91)
        await h.tracker.evaluate()
        let stops = h.notifier.state.with { $0.watchdogStops }
        #expect(stops.first?.canResume == false)
        #expect(await h.tracker.graceState == nil)
    }
}

@Suite("C14 tracker: zero-signal nudge")
struct TrackerNudgeTests {
    @Test("notification-initiated recording with ZERO correlated signals nudges ONCE at 15 min")
    func nudgeFires() async throws {
        let h = makeTrackerHarness()
        // The click-and-abandon case: started via the notification action.
        await h.tracker.recordActionClicked(code: TrackerHarness.code)
        let session = h.controller.state.with { $0.session }
        let meeting = h.controller.state.with { s in s.session.flatMap { s.meetings[$0.meetingID] } }
        #expect(session != nil)
        await h.tracker.recordingStarted(
            meetingID: meeting!.id, meetingCode: TrackerHarness.code, title: meeting!.title,
            partIndex: 1)
        h.advance(880)
        await h.tracker.evaluate()
        #expect(h.notifier.state.with { $0.nudges }.isEmpty)  // < 15 min
        h.advance(25)
        await h.tracker.evaluate()
        #expect(h.notifier.state.with { $0.nudges } == [meeting!.id])
        h.advance(120)
        await h.tracker.evaluate()
        #expect(h.notifier.state.with { $0.nudges }.count == 1)  // ONE nudge, never repeated
        // Never an auto-stop: a live meeting recorded without a working
        // extension must never be cut.
        #expect(h.controller.state.with { $0.autoStopCalls }.isEmpty)
    }

    @Test("a correlated signal before 15 min suppresses the nudge")
    func signalSuppressesNudge() async throws {
        let h = makeTrackerHarness()
        await h.tracker.recordActionClicked(code: TrackerHarness.code)
        let meeting = h.controller.state.with { s in s.session.flatMap { s.meetings[$0.meetingID] } }
        await h.tracker.recordingStarted(
            meetingID: meeting!.id, meetingCode: TrackerHarness.code, title: meeting!.title,
            partIndex: 1)
        h.advance(60)
        await h.signal(kind: .heartbeat)  // the join completed
        h.advance(900)
        await h.tracker.evaluate()
        #expect(h.notifier.state.with { $0.nudges }.isEmpty)
    }

    @Test("manual (B-6) recordings are untouched by the nudge")
    func manualStartNoNudge() async throws {
        let h = makeTrackerHarness()
        _ = try await startRecording(h)  // not via a notification
        h.advance(1000)
        await h.tracker.evaluate()
        #expect(h.notifier.state.with { $0.nudges }.isEmpty)
    }
}

// MARK: - Indicator grace transitions (C14)

@Suite("C14 indicator: grace state machine")
struct IndicatorGraceTests {
    private let until = msDate(1_770_000_900)

    @Test("graceEntered while processing stands: processing wins (spec §4: processing > grace)")
    func graceAfterStop() {
        var machine = IndicatorStateMachine()
        machine.apply(.captureStarted(at: msDate()))
        machine.apply(.captureStopping)
        machine.apply(.captureStopped(alarm: nil))
        #expect(machine.state == .processing)
        // Spec v4 priority: alarm > recording > processing > grace > paused.
        // A grace window entered while the just-stopped meeting still
        // processes does NOT take the icon — processing outranks grace; the
        // grace resurfaces once processing finishes.
        let state = machine.apply(.graceEntered(meetingTitle: "Weekly", until: until))
        #expect(state == .processing)
        #expect(machine.apply(.processingFinished) == .grace(meetingTitle: "Weekly", until: until))
    }

    @Test("graceResumed hands to idle; the rejoin's captureStarted takes over")
    func graceResumed() {
        var machine = IndicatorStateMachine()
        machine.apply(.graceEntered(meetingTitle: "Weekly", until: until))
        #expect(machine.apply(.graceResumed) == .idle)
        #expect(machine.apply(.captureStarted(at: msDate())) == .recording(startedAt: msDate()))
    }

    @Test("graceExpired hands to processing (the finalize kick)")
    func graceExpired() {
        var machine = IndicatorStateMachine()
        machine.apply(.graceEntered(meetingTitle: "Weekly", until: until))
        #expect(machine.apply(.graceExpired) == .processing)
        #expect(machine.apply(.processingFinished) == .idle)
    }

    @Test("recording wins over grace; the standing grace resurfaces once processing finishes")
    func recordingWinsOverGrace() {
        var machine = IndicatorStateMachine()
        machine.apply(.graceEntered(meetingTitle: "A", until: until))
        // Back-to-back: a NEW meeting starts while A is in grace.
        machine.apply(.captureStarted(at: msDate()))
        #expect(machine.state == .recording(startedAt: msDate()))
        machine.apply(.captureStopping)
        // Spec v4: processing > grace. The new meeting's encode is running, so
        // processing holds the icon; A's grace resurfaces once it finishes.
        #expect(machine.state == .processing)
        machine.apply(.captureStopped(alarm: nil))
        #expect(machine.state == .processing)
        #expect(machine.apply(.processingFinished) == .grace(meetingTitle: "A", until: until))
    }

    @Test("alarm > grace (spec §4): a loud failure wins over a standing grace window")
    func alarmWinsOverGrace() {
        var machine = IndicatorStateMachine()
        machine.apply(.graceEntered(meetingTitle: "A", until: until))
        machine.apply(.captureStarted(at: msDate()))
        machine.apply(.captureStopping)
        machine.apply(.captureStopped(alarm: "part 2 produced no recoverable audio"))
        // alarm > recording > processing > grace: the loud failure takes the icon.
        #expect(machine.state == .alarm(message: "part 2 produced no recoverable audio"))
        // Acknowledging the alarm reveals the still-standing grace beneath it.
        #expect(machine.apply(.alarmAcknowledged) == .grace(meetingTitle: "A", until: until))
    }

    @Test("alarm behavior unchanged when no grace is standing")
    func alarmWithoutGrace() {
        var machine = IndicatorStateMachine()
        machine.apply(.captureStarted(at: msDate()))
        machine.apply(.captureStopping)
        #expect(machine.apply(.captureStopped(alarm: "boom")) == .alarm(message: "boom"))
    }
}

// MARK: - G9 tracker contract

@Suite("G9 tracker: pause / resume automation contract")
struct G9TrackerContractTests {
    /// Recording the call, then pause it (the controller's observer fact).
    private func startThenPause(_ h: TrackerHarness) async throws -> Meeting {
        let meeting = try await startRecording(h)
        await h.signal(kind: .heartbeat)  // arm the watchdog (lastSignalAt set)
        // Production order: pause() releases the controller session FIRST,
        // then fires the recordingPaused observer fact. Mirror that here.
        h.controller.state.with { $0.session = nil }
        await h.tracker.recordingPaused(
            meetingID: meeting.id, meetingCode: TrackerHarness.code)
        return meeting
    }

    @Test("pause clears the active-call linkage: a watchdog pass leaves paused untouched (AC1)")
    func watchdogLeavesPausedUntouched() async throws {
        let h = makeTrackerHarness()
        _ = try await startThenPause(h)
        // Any number of evaluations: no auto-stop is attempted (activeCall is
        // nil after pause — the watchdog has nothing to orphan).
        for _ in 0..<20 {
            h.advance(60)
            await h.tracker.evaluate()
        }
        #expect(h.controller.state.with { $0.autoStopCalls }.isEmpty)
        // And no spurious pause/end/resume calls.
        #expect(h.controller.state.with { $0.endPausedCalls }.isEmpty)
        #expect(h.controller.state.with { $0.resumePausedCalls }.isEmpty)
    }

    @Test("paused suppression does NOT expire on the 10-min silence rule (AC1)")
    func pausedSuppressionNonExpiry() async throws {
        let h = makeTrackerHarness()
        _ = try await startThenPause(h)
        // Far past the 10-minute suppression expiry, with no signals.
        h.advance(3_600)
        await h.tracker.evaluate()
        // A fresh call-started for the paused code must NOT re-post "Meeting
        // in progress" — the paused-class suppression is still standing.
        await h.signal(kind: .callStarted)
        #expect(h.meetStartCount() == 0)
    }

    @Test("grace→paused conversion withdraws the watchdog notification + clears the mirror (AC1)")
    func graceToPausedWithdrawsNotification() async throws {
        let h = makeTrackerHarness(resumeWindow: 300)
        // Auto-stop into grace with the watchdog notification posted.
        let meeting = try await startRecording(h)
        await h.signal(kind: .heartbeat)
        h.advance(310)
        await h.tracker.evaluate()  // staleSince set
        h.advance(91)
        await h.tracker.evaluate()  // watchdog fires → grace + postWatchdogStop
        #expect(await h.tracker.graceState?.meetingID == meeting.id)
        let mirror = Recorder<MeetAutomationEvent>()
        let events = await h.tracker.events()
        let collector = Task { for await e in events { mirror.append(e) } }

        // Pause the grace meeting → conversion.
        let converted = await h.tracker.pauseFromGrace(meetingID: meeting.id)
        #expect(converted)
        // The grace entry is gone (real cancellation).
        #expect(await h.tracker.graceState == nil)
        // The watchdog notification was withdrawn.
        #expect(h.notifier.state.with { $0.watchdogWithdrawals }.contains(meeting.id))
        // The controller wrote the meeting durably to paused.
        #expect(h.controller.state.with { $0.pauseGraceCalls } == [meeting.id])
        // The UI mirror got a graceEnded with the .paused reason (so the
        // menu's grace line clears AND the handler does NOT apply processing —
        // H-3: a conversion must not show a false "processing" display).
        #expect(await waitUntil {
            mirror.values.contains {
                if case .graceEnded(meeting.id, .paused) = $0 { return true }; return false
            }
        })
        collector.cancel()
    }

    @Test("M-1: pauseFromGrace REFUSES when ANOTHER meeting is already paused (no two paused)")
    func graceToPausedRefusedWhenOtherPaused() async throws {
        let h = makeTrackerHarness(resumeWindow: 300)
        // Drive a meeting into grace with the watchdog notification posted.
        let meeting = try await startRecording(h)
        await h.signal(kind: .heartbeat)
        h.advance(310)
        await h.tracker.evaluate()  // staleSince set
        h.advance(91)
        await h.tracker.evaluate()  // watchdog fires → grace
        #expect(await h.tracker.graceState?.meetingID == meeting.id)

        // ANOTHER meeting is already durably paused (the controller reports it
        // via the universal predicate). The grace→paused conversion must refuse
        // — two paused meetings would break every single-paused assumption.
        let other = makeMeeting(title: "Already paused", status: .paused)
        h.controller.state.with { $0.pausedMeetingIDs.append(other.id) }

        let converted = await h.tracker.pauseFromGrace(meetingID: meeting.id)
        #expect(!converted)
        // No durable write, the grace entry survives (still actionable).
        #expect(h.controller.state.with { $0.pauseGraceCalls }.isEmpty)
        #expect(await h.tracker.graceState?.meetingID == meeting.id)
    }

    @Test("manualControl cleared on Resume; paused suppression cleared (AC1)")
    func manualControlClearedOnResume() async throws {
        let h = makeTrackerHarness()
        let meeting = try await startThenPause(h)
        // Resume: the controller's recordingUnpaused(resumed: true) fact.
        await h.tracker.recordingUnpaused(
            meetingID: meeting.id, meetingCode: TrackerHarness.code, resumed: true)
        // After resume the paused suppression is gone: a fresh call-started
        // for the code now CAN notify (the gate is cleared). (In production
        // recordingStarted re-clears too; here we prove the explicit clear.)
        h.advance(5)  // a later timestamp passes the monotonic guard
        await h.signal(kind: .callStarted)
        #expect(h.meetStartCount() == 1)
    }

    @Test("manualControl cleared on End (AC1)")
    func manualControlClearedOnEnd() async throws {
        let h = makeTrackerHarness()
        let meeting = try await startThenPause(h)
        await h.tracker.recordingUnpaused(
            meetingID: meeting.id, meetingCode: TrackerHarness.code, resumed: false)
        h.advance(5)  // a later timestamp passes the monotonic guard
        await h.signal(kind: .callStarted)
        #expect(h.meetStartCount() == 1)
    }

    @Test("auto-stop end event DURING pause = ingest-no-transition (no auto-stop)")
    func endEventDuringPauseNoTransition() async throws {
        let h = makeTrackerHarness()
        _ = try await startThenPause(h)
        // A lifecycle call-ended arrives while paused (no live session): it is
        // ingested but produces NO state transition (no debounce, no
        // auto-stop). handleCallEnded returns early when no session exists.
        await h.signal(kind: .callEnded, reason: "left")
        h.advance(30)
        await h.tracker.evaluate()
        #expect(h.controller.state.with { $0.autoStopCalls }.isEmpty)
        #expect(h.controller.state.with { $0.endPausedCalls }.isEmpty)
    }
}

// MARK: - G9 indicator priority

@Suite("G9 indicator: paused state + priority order")
struct G9IndicatorTests {
    private let until = msDate(1_770_000_900)

    @Test("recording > paused: a live capture wins over a standing paused window")
    func recordingWinsOverPaused() {
        var m = IndicatorStateMachine()
        m.apply(.meetingPaused(meetingTitle: "Held", accumulatedSeconds: 120))
        #expect(m.state == .paused(meetingTitle: "Held", accumulatedSeconds: 120))
        // A resume re-enters recording (meetingResumed then captureStarted).
        m.apply(.meetingResumed)
        let now = msDate()
        m.apply(.captureStarted(at: now))
        #expect(m.state == .recording(startedAt: now))
    }

    @Test("grace > paused: a standing grace window wins the display over a paused meeting")
    func graceWinsOverPaused() {
        var m = IndicatorStateMachine()
        m.apply(.graceEntered(meetingTitle: "Graced", until: until))
        // A different meeting pauses while grace stands — grace wins.
        m.apply(.meetingPaused(meetingTitle: "Held", accumulatedSeconds: 60))
        #expect(m.state == .grace(meetingTitle: "Graced", until: until))
    }

    @Test("paused > idle: a paused window shows when nothing higher is live")
    func pausedOverIdle() {
        var m = IndicatorStateMachine()
        m.apply(.meetingPaused(meetingTitle: "Held", accumulatedSeconds: 90))
        #expect(m.state == .paused(meetingTitle: "Held", accumulatedSeconds: 90))
    }

    @Test("paused indicator carries the accumulated recorded time")
    func pausedCarriesAccumulated() {
        var m = IndicatorStateMachine()
        let result = m.apply(.meetingPaused(meetingTitle: "Held", accumulatedSeconds: 754))
        if case .paused(_, let seconds) = result {
            #expect(seconds == 754)
        } else {
            Issue.record("expected paused state")
        }
    }

    @Test("End from paused → processing")
    func endFromPausedToProcessing() {
        var m = IndicatorStateMachine()
        m.apply(.meetingPaused(meetingTitle: "Held", accumulatedSeconds: 30))
        m.apply(.meetingEnded)
        #expect(m.state == .processing)
    }

    @Test("C-1: the REAL pause sequence (captureStarted → meetingPaused) lands .paused")
    func realPauseSequenceLandsPaused() {
        // The exact production order: a live capture started, then THIS meeting
        // is paused. The machine must leave .recording and show .paused — the
        // toolbar/menu key on this state for the three-state controls.
        var m = IndicatorStateMachine()
        let now = msDate()
        m.apply(.captureStarted(at: now))
        #expect(m.state == .recording(startedAt: now))
        let state = m.apply(.meetingPaused(meetingTitle: "Held", accumulatedSeconds: 120))
        #expect(state == .paused(meetingTitle: "Held", accumulatedSeconds: 120))
    }

    @Test("processing > paused (spec §4): End-from-pause's kick wins over a different paused window")
    func processingWinsOverPaused() {
        // A meeting is paused; a SEPARATE stop's encode is running. Spec v4
        // priority places processing above paused, so the icon shows
        // processing until the run finishes, then the paused window resurfaces.
        var m = IndicatorStateMachine()
        m.apply(.captureStarted(at: msDate()))
        m.apply(.captureStopping)  // processing stands
        #expect(m.state == .processing)
        m.apply(.meetingPaused(meetingTitle: "Held", accumulatedSeconds: 10))
        #expect(m.state == .processing)  // processing > paused
        #expect(m.apply(.processingFinished) == .paused(meetingTitle: "Held", accumulatedSeconds: 10))
    }
}

// MARK: - G11: classifier wiring + durable-grace exits

@Suite("G11 AC3/AC4: end-detection wiring in the tracker")
struct G11TrackerWiringTests {
    /// Drives a correlated recording to a DEBOUNCE-fired auto-stop, with the
    /// meeting carrying the given `scheduledEnd` anchor.
    private func autoStopAnchored(_ h: TrackerHarness, scheduledEnd: Date) async throws -> Meeting {
        let meeting = try await startAnchoredRecording(h, scheduledEnd: scheduledEnd)
        await h.signal(kind: .heartbeat)
        h.advance(5)
        await h.signal(kind: .callEnded, reason: "left")
        h.advance(26)
        await h.tracker.evaluate()
        return meeting
    }

    @Test("AC3: an in-band end (within 10 min of the scheduled end) processes immediately, NO grace")
    func inBandEndProcessesNoGrace() async throws {
        let h = makeTrackerHarness(resumeWindow: 300)
        // Fire is ~epoch+31 s; an end 5 min before the scheduled end → in band.
        let scheduledEnd = TrackerHarness.epoch.addingTimeInterval(331)
        let meeting = try await autoStopAnchored(h, scheduledEnd: scheduledEnd)
        #expect(await h.tracker.graceState == nil, "no grace entered")
        #expect(h.controller.state.with { $0.kicks } == [meeting.id], "processed immediately")
        // No grace column was ever written (no entry → nothing to clear).
        #expect(h.graceWrites.with { $0.isEmpty }, "no durable grace write on the no-grace path")
    }

    @Test("AC3: an EARLY end on an anchored meeting still graces (today's behavior)")
    func earlyEndGraces() async throws {
        let h = makeTrackerHarness(resumeWindow: 300)
        // Scheduled end far in the future → the band has not opened → grace.
        let scheduledEnd = TrackerHarness.epoch.addingTimeInterval(5000)
        let meeting = try await autoStopAnchored(h, scheduledEnd: scheduledEnd)
        #expect(await h.tracker.graceState?.meetingID == meeting.id, "grace entered")
        #expect(h.controller.state.with { $0.kicks }.isEmpty, "kick moved to grace expiry")
        // The durable grace deadline was written (entry).
        #expect(h.lastGraceWrite(meeting.id) ?? nil != nil, "grace column written at entry")
    }

    @Test("AC3: an ad-hoc (unanchored) end graces — nil anchor never processes in-band")
    func adHocEndGraces() async throws {
        let h = makeTrackerHarness(resumeWindow: 300)
        let meeting = try await startRecording(h)  // no anchor
        await h.signal(kind: .heartbeat)
        h.advance(5)
        await h.signal(kind: .callEnded, reason: "left")
        h.advance(26)
        await h.tracker.evaluate()
        #expect(await h.tracker.graceState?.meetingID == meeting.id)
    }

    @Test("AC4: grace ENTRY persists the deadline; EXPIRY clears it (clear-before-kick)")
    func graceEntryAndExpiryColumn() async throws {
        let h = makeTrackerHarness(resumeWindow: 300)
        let scheduledEnd = TrackerHarness.epoch.addingTimeInterval(5000)
        let meeting = try await autoStopAnchored(h, scheduledEnd: scheduledEnd)
        #expect(h.lastGraceWrite(meeting.id) ?? nil != nil, "entry wrote the deadline")
        h.advance(301)
        await h.tracker.evaluate()  // grace expiry
        #expect(h.lastGraceWrite(meeting.id) == .some(nil), "expiry cleared the column")
        #expect(h.controller.state.with { $0.kicks } == [meeting.id])
    }

    @Test("AC4: a rejoin RESUME clears the column before controller.resume (r3-M2 ordering)")
    func rejoinClearsColumnBeforeResume() async throws {
        let h = makeTrackerHarness()
        let scheduledEnd = TrackerHarness.epoch.addingTimeInterval(5000)
        let meeting = try await autoStopAnchored(h, scheduledEnd: scheduledEnd)
        #expect(h.lastGraceWrite(meeting.id) ?? nil != nil)
        h.advance(60)
        await h.signal(kind: .callStarted)  // rejoin
        // The clear was written BEFORE the resume call (ordering pin).
        #expect(h.lastGraceWrite(meeting.id) == .some(nil), "column cleared on rejoin")
        #expect(h.controller.state.with { $0.resumeCalls } == [meeting.id])
    }

    @Test("AC4: a manual stop of a grace meeting clears the column")
    func manualStopClearsColumn() async throws {
        let h = makeTrackerHarness()
        let scheduledEnd = TrackerHarness.epoch.addingTimeInterval(5000)
        let meeting = try await autoStopAnchored(h, scheduledEnd: scheduledEnd)
        await h.tracker.recordingStopped(
            meetingID: meeting.id, meetingCode: TrackerHarness.code, manual: true)
        #expect(h.lastGraceWrite(meeting.id) == .some(nil))
        #expect(await h.tracker.graceState == nil)
    }

    @Test("AC4: pauseFromGrace clears the column before the controller flips to paused")
    func pauseFromGraceClearsColumn() async throws {
        let h = makeTrackerHarness()
        let scheduledEnd = TrackerHarness.epoch.addingTimeInterval(5000)
        let meeting = try await autoStopAnchored(h, scheduledEnd: scheduledEnd)
        let converted = await h.tracker.pauseFromGrace(meetingID: meeting.id)
        #expect(converted)
        #expect(h.lastGraceWrite(meeting.id) == .some(nil))
        #expect(h.controller.state.with { $0.pauseGraceCalls } == [meeting.id])
    }

    @Test("AC4: a recordingPaused landing while a grace entry stands clears the column (5th exit)")
    func recordingPausedFromGraceClearsColumn() async throws {
        // The race-reachable grace exit (MeetCallTracker `recordingPaused`,
        // `graces.removeValue` branch): a detached `recordingPaused` fact lands
        // for a meeting that is still holding a grace entry (resume-then-pause).
        // Distinct from `pauseFromGrace`, which the menu's Pause-during-grace
        // control drives — this is the observer fact arriving with grace alive.
        let h = makeTrackerHarness()
        let scheduledEnd = TrackerHarness.epoch.addingTimeInterval(5000)
        let meeting = try await autoStopAnchored(h, scheduledEnd: scheduledEnd)
        #expect(await h.tracker.graceState?.meetingID == meeting.id, "grace entered")
        #expect(h.lastGraceWrite(meeting.id) ?? nil != nil, "grace column written at entry")
        // The recordingPaused observer fact lands with the grace entry still up.
        await h.tracker.recordingPaused(
            meetingID: meeting.id, meetingCode: TrackerHarness.code)
        #expect(h.lastGraceWrite(meeting.id) == .some(nil), "durable grace column cleared on pause-from-grace")
        #expect(await h.tracker.graceState == nil, "grace entry removed")
    }

    @Test("AC4: the watchdog path still graces (classification is debounce-only)")
    func watchdogStillGraces() async throws {
        let h = makeTrackerHarness(resumeWindow: 300)
        // An in-band scheduled end, but the END arrives via the WATCHDOG, not
        // the debounce — classification must NOT apply, so it graces.
        let scheduledEnd = TrackerHarness.epoch.addingTimeInterval(331)
        let meeting = try await startAnchoredRecording(h, scheduledEnd: scheduledEnd)
        await h.signal(kind: .heartbeat)  // arms the watchdog
        // No call-ended: let the watchdog fire (> 5 min stale, 90 s confirm).
        h.advance(MeetCallTracker.watchdogStaleSeconds + 1)
        await h.tracker.evaluate()  // first stale eval: records staleSince
        h.advance(MeetCallTracker.watchdogConfirmSeconds + 1)
        await h.tracker.evaluate()  // confirmed → watchdog auto-stop
        #expect(await h.tracker.graceState?.meetingID == meeting.id, "watchdog graces, never in-band processes")
        #expect(h.controller.state.with { $0.kicks }.isEmpty)
    }
}
