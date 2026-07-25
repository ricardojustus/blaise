import Foundation
import GRDB
import Synchronization
import os

// C11: recording lifecycle orchestration — UI-free and CoreAudio-free (the
// engine is injected behind `AudioCapturing`, so the lifecycle is fully
// unit-testable). Implements `RecordingSessionProviding` (C10's seam): the
// meet-events listener's live-correlation case activates while a session is
// registered here.

// MARK: - Capture engine seam

public enum CaptureEngineEvent: Sendable, Equatable {
    /// Mic all-zero ≥ 60 s while system audio is active (true), or the mic
    /// signal returned (false).
    case micSilence(active: Bool)
    /// B4 (audit): the capture graph has been DOWN through a route-change
    /// rebuild for longer than `CaptureSession.captureDownAlarmSeconds`
    /// (true), or a rebuild succeeded and capture resumed (false). Unlike
    /// `writeFailure` this does NOT stop the recording — the retry ladder is
    /// still working. See `CaptureSession.captureDownAlarmSeconds` for why
    /// this must be visible.
    case captureDown(active: Bool)
    /// A CAF writer error — the one sanctioned automatic stop: continuing to
    /// record into a failing writer loses MORE. The controller stops,
    /// encodes whatever exists, and raises the loud indicator alarm.
    case writeFailure(String)
    /// G12 §2: a raw RMS pair (mic, system) for the live level meter, already
    /// throttled to ≤ 10 Hz at the source (the IOProc's processing queue).
    /// Smoothing + silence detection happen in the holder's `LevelMeter` model.
    case level(you: Double, others: Double)
}

/// What the engine learned at graph build, returned from `start` so the
/// controller can act on it AFTER the `.started` event (an `onEvent` fired
/// during start races the started emission and gets erased by the state
/// machine's start reset).
public struct CaptureStartInfo: Sendable, Equatable {
    /// Input-device stream count; 0 = the mic track will stay empty and
    /// the silence detector can never fire (no data) — warn at start.
    public var micStreams: Int
    public init(micStreams: Int) { self.micStreams = micStreams }
}

/// The capture engine (real: `CaptureSession`, CoreAudio process tap +
/// aggregate; tests: a mock that plants CAF bytes).
public protocol AudioCapturing: Sendable {
    @discardableResult
    func start(
        systemCAF: URL, micCAF: URL,
        onEvent: @escaping @Sendable (CaptureEngineEvent) -> Void
    ) async throws -> CaptureStartInfo
    func stop() async
}

// MARK: - Controller

public enum RecordingControllerError: Error, CustomStringConvertible, Equatable {
    case alreadyRecording
    case notRecording
    case insufficientDiskSpace(freeBytes: Int64)
    /// G9 (H-2/M-9): a start or resume was refused because a meeting is
    /// durably `paused` — the user must End & process it or Resume it first.
    /// `title` drives the start-surface prompt. Distinct from
    /// `alreadyRecording` (a LIVE session), which is existing behavior.
    case meetingPaused(meetingID: MeetingID, title: String)

    public var description: String {
        switch self {
        case .alreadyRecording: return "a recording is already in progress"
        case .notRecording: return "no recording is in progress"
        case .insufficientDiskSpace(let free):
            return "not enough free disk space to record (\(free / 1_000_000) MB free; \(CaptureLimits.minimumFreeDiskBytes / 1_000_000_000) GB required)"
        case .meetingPaused(_, let title):
            return "'\(title)' is paused — End & process it, or Resume it instead?"
        }
    }
}

// MARK: - C14 automation seams

/// What an auto-stop left behind — the tracker's grace-entry condition
/// (Resume window configured AND ≥ 1 recoverable part; otherwise the stop
/// finalized immediately / took the no-audio failed path).
public struct AutoStopOutcome: Sendable {
    public let meeting: Meeting
    /// ≥ 1 part of the meeting holds verified retained audio after this stop.
    public let recoverableAudio: Bool
    /// G11 §2: the meeting's calendar anchor end (`scheduled_end_ms`), nil for
    /// an ad-hoc meeting — the §2 classifier's input. Surfaced from the stop so
    /// the tracker can decide grace-vs-process without a separate DB read.
    public var scheduledEndMs: Int64?

    public init(meeting: Meeting, recoverableAudio: Bool, scheduledEndMs: Int64? = nil) {
        self.meeting = meeting
        self.recoverableAudio = recoverableAudio
        self.scheduledEndMs = scheduledEndMs
    }
}

/// The controller surface `MeetCallTracker` drives (mocked in tests — the
/// tracker is clock-injected and capture-free).
public protocol RecordingAutomating: Sendable {
    func currentSession() async -> RecordingSessionInfo?
    @discardableResult
    func start(
        source: MeetingSource, title: String?, meetingCode: String?, attendees: [Attendee],
        anchor: CalendarAnchor?
    ) async throws -> Meeting
    @discardableResult
    func stop(alarm: String?) async throws -> Meeting
    func autoStop(finalizeImmediately: Bool) async throws -> AutoStopOutcome
    @discardableResult
    func resume(meetingID: MeetingID) async throws -> Meeting
    func kickProcessing(meetingID: MeetingID) async
    // G9: manual pause of the live session — finalizes the current part and
    // writes `paused` in one transaction; manual resume of a paused meeting;
    // End-from-pause (flip + finalize→processing).
    @discardableResult
    func pause() async throws -> Meeting
    @discardableResult
    func resumePaused(meetingID: MeetingID) async throws -> Meeting
    @discardableResult
    func endPaused(meetingID: MeetingID) async throws -> Meeting
    /// G9 grace→paused conversion: write a grace meeting (no live session,
    /// parts already finalized at auto-stop) durably to `paused`.
    func pauseGraceMeeting(meetingID: MeetingID) async
    /// G9 (M-9): the id of any meeting durably `paused` (excluding the given
    /// id) — the single-open-meeting predicate consulted by every grace/resume
    /// entry, including grace→paused conversion.
    func pausedMeetingID(excluding: MeetingID?) async -> MeetingID?
}

/// Recording lifecycle facts the tracker consumes (start by ANY path clears
/// suppression; a MANUAL stop writes the `stopped` suppression record).
public protocol RecordingLifecycleObserving: Sendable {
    func recordingStarted(meetingID: MeetingID, meetingCode: String?, title: String, partIndex: Int) async
    func recordingStopped(meetingID: MeetingID, meetingCode: String?, manual: Bool) async
    /// G9: a meeting was MANUALLY paused. The tracker sets its per-meeting
    /// `manualControl` flag, converts an active grace window to paused
    /// (withdrawing its notification), clears the active-call linkage, and
    /// installs a non-expiring paused-class suppression record.
    func recordingPaused(meetingID: MeetingID, meetingCode: String?) async
    /// G9: a paused meeting was Resumed or Ended — the tracker clears the
    /// `manualControl` flag and the paused-class suppression. `resumed` true =
    /// Resume (the subsequent `recordingStarted` re-arms the watchdog);
    /// false = End (the meeting is leaving for processing).
    func recordingUnpaused(meetingID: MeetingID, meetingCode: String?, resumed: Bool) async
}

public struct NoopRecordingLifecycleObserver: RecordingLifecycleObserving {
    public init() {}
    public func recordingStarted(meetingID: MeetingID, meetingCode: String?, title: String, partIndex: Int) async {}
    public func recordingStopped(meetingID: MeetingID, meetingCode: String?, manual: Bool) async {}
    public func recordingPaused(meetingID: MeetingID, meetingCode: String?) async {}
    public func recordingUnpaused(meetingID: MeetingID, meetingCode: String?, resumed: Bool) async {}
}

/// Late-binding box (composition-root cycle: the controller is built before
/// the tracker, which observes it).
public final class RecordingLifecycleObserverBox: RecordingLifecycleObserving, Sendable {
    private let target = Mutex<(any RecordingLifecycleObserving)?>(nil)

    public init() {}

    public func set(_ observer: any RecordingLifecycleObserving) {
        target.withLock { $0 = observer }
    }

    public func recordingStarted(meetingID: MeetingID, meetingCode: String?, title: String, partIndex: Int) async {
        let observer = target.withLock { $0 }
        await observer?.recordingStarted(
            meetingID: meetingID, meetingCode: meetingCode, title: title, partIndex: partIndex)
    }

    public func recordingStopped(meetingID: MeetingID, meetingCode: String?, manual: Bool) async {
        let observer = target.withLock { $0 }
        await observer?.recordingStopped(meetingID: meetingID, meetingCode: meetingCode, manual: manual)
    }

    public func recordingPaused(meetingID: MeetingID, meetingCode: String?) async {
        let observer = target.withLock { $0 }
        await observer?.recordingPaused(meetingID: meetingID, meetingCode: meetingCode)
    }

    public func recordingUnpaused(meetingID: MeetingID, meetingCode: String?, resumed: Bool) async {
        let observer = target.withLock { $0 }
        await observer?.recordingUnpaused(
            meetingID: meetingID, meetingCode: meetingCode, resumed: resumed)
    }
}

/// UI-facing lifecycle events (the indicator holder consumes them).
public enum RecordingEvent: Sendable, Equatable {
    case started(meetingID: MeetingID, at: Date)
    case micSilence(active: Bool)
    /// B4 (audit): capture graph down/up during a route-change rebuild.
    case captureDown(active: Bool)
    /// The engine is down and the encode is running — emitted immediately
    /// at stop so the indicator reflects it before the encode finishes.
    case stopping(meetingID: MeetingID)
    /// Stop+encode completed. `alarm` carries the loud failure message
    /// (write failure / no recoverable audio); `kickedProcessing` says a
    /// pipeline run was dispatched for this meeting.
    case stopped(meetingID: MeetingID, alarm: String?, kickedProcessing: Bool)
    /// G9: manual pause finalized the current part and committed `paused`.
    /// `accumulatedSeconds` is the sum of all closed part durations (the
    /// indicator's "paused" timer). DISTINCT from `.stopping/.stopped` — a
    /// pause never processes and never enters grace.
    case paused(meetingID: MeetingID, accumulatedSeconds: TimeInterval)
    /// G9: a paused meeting resumed — engine live again, new part open. The
    /// indicator returns to recording; carries the resumed-part start so the
    /// timer continues from the accumulated base. (`.started` re-emission
    /// also fires; `.resumed` lets the holder distinguish pause-resume from a
    /// fresh start for the accumulated-timer base.)
    case resumed(meetingID: MeetingID, at: Date, accumulatedSeconds: TimeInterval)
    /// G12 §2: a ≤ 10 Hz raw RMS pair (mic, system) for the live level meter.
    /// The UI holder feeds it into the `LevelMeter` model (smoothing + silence).
    case level(you: Double, others: Double)
}

public actor RecordingController: RecordingSessionProviding, RecordingAutomating {
    private let database: BlaiseDatabase
    private let engine: any AudioCapturing
    /// Track-inventory-aware processing dispatch (the pipeline's
    /// `dispatchProcessing`), fired after stop+encode. Fire-and-forget —
    /// the run records its own failures.
    private let processKicker: @Sendable (MeetingID) async -> Void
    private let now: @Sendable () -> Date
    /// C14: lifecycle facts for the automation tracker (Noop outside the app).
    private let observer: any RecordingLifecycleObserving
    private let logger = Logger(subsystem: BlaiseBundle.identifier, category: "capture.controller")

    private struct ActiveSession {
        var meeting: Meeting
        /// 1-based capture part this session writes (C14 multi-part).
        var partIndex: Int
        var stopping = false
    }

    private var active: ActiveSession?
    private var eventContinuations: [UUID: AsyncStream<RecordingEvent>.Continuation] = [:]
    /// Off-actor encodes still running (a stop past its session release).
    /// The quit intercept awaits these via `awaitQuiescence()` — terminating
    /// mid-encode would orphan the CAFs until the next launch's sweep.
    private var finalizing = 0
    private var quiescenceWaiters: [CheckedContinuation<Void, Never>] = []

    /// The stop-path encode, injectable so tests can HOLD it open and prove
    /// `awaitQuiescence` actually waits (the real encode is too fast to
    /// observe). Production always uses the default. C14: part-indexed.
    private let finalizer: @Sendable (MeetingPaths, MeetingID, Int) -> CaptureRecovery.FinalizeOutcome

    /// G9 AC3 crash-test seam (G7 pattern): a hook run BETWEEN the part-close
    /// write and the status write inside the pause/resume single
    /// transaction. Production passes nil; a test throws to prove BOTH writes
    /// roll back atomically. Default nil.
    private let transactionHook: (@Sendable () throws -> Void)?
    /// H-1 test seam (G7 pattern): runs inside `endPaused`, AFTER the meeting
    /// is fetched as `paused` but BEFORE the guarded flip — the window where a
    /// concurrent Resume can flip the row to `recording`, making the flip a
    /// no-op. Tests use it to drive that exact TOCTOU and prove the flip-result
    /// check refuses the kick. nil in production.
    private let endFlipHook: (@Sendable () async -> Void)?

    public init(
        database: BlaiseDatabase,
        engine: any AudioCapturing,
        processKicker: @escaping @Sendable (MeetingID) async -> Void,
        now: @escaping @Sendable () -> Date = { Date() },
        observer: any RecordingLifecycleObserving = NoopRecordingLifecycleObserver(),
        finalizer: @escaping @Sendable (MeetingPaths, MeetingID, Int) -> CaptureRecovery.FinalizeOutcome = {
            CaptureRecovery.finalizeTracks(paths: $0, meetingID: $1, part: $2)
        },
        transactionHook: (@Sendable () throws -> Void)? = nil,
        endFlipHook: (@Sendable () async -> Void)? = nil
    ) {
        self.database = database
        self.engine = engine
        self.processKicker = processKicker
        self.now = now
        self.observer = observer
        self.finalizer = finalizer
        self.transactionHook = transactionHook
        self.endFlipHook = endFlipHook
    }

    // MARK: - RecordingSessionProviding (C10 seam, live correlation)

    public func currentSession() async -> RecordingSessionInfo? {
        active.map { RecordingSessionInfo(meetingID: $0.meeting.id, meetingCode: $0.meeting.meetingCode) }
    }

    public var isRecording: Bool { active != nil }

    /// Returns once no stop+encode is in flight. The quit intercept calls
    /// this so termination waits for ANY in-flight finalization — its own
    /// stop and a manual stop already past `.stopping` alike.
    public func awaitQuiescence() async {
        while finalizing > 0 {
            await withCheckedContinuation { quiescenceWaiters.append($0) }
        }
    }

    // MARK: - Events

    public func events() -> AsyncStream<RecordingEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            eventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    /// Test-only: register the continuation SYNCHRONOUSLY (the public
    /// `events()` AsyncStream registers lazily on first iteration, so an
    /// immediate single emit can be lost before iteration begins). Same stream
    /// semantics; only the registration timing differs.
    func subscribeForTest() -> AsyncStream<RecordingEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<RecordingEvent>.makeStream()
        eventContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return stream
    }

    /// Test-only: finish all event continuations so an inline iterator drain
    /// terminates deterministically after the events under test were emitted.
    func finishEventStreamsForTest() {
        for continuation in eventContinuations.values { continuation.finish() }
        eventContinuations.removeAll()
    }

    private func removeContinuation(_ id: UUID) {
        eventContinuations[id] = nil
    }

    private func emit(_ event: RecordingEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    // MARK: - Start

    /// Creates the Meeting row (`status = recording`), starts the capture
    /// engine into the meeting directory's CAF tracks, and registers the
    /// live session. Status transitions (spec): start → `recording`; stop →
    /// encode → `processCaptured` entry sets `processing`.
    @discardableResult
    public func start(
        source: MeetingSource,
        title: String? = nil,
        meetingCode: String? = nil,
        attendees: [Attendee] = [],
        anchor: CalendarAnchor? = nil
    ) async throws -> Meeting {
        // The universal refusal predicate (H-2/M-9): (a) a LIVE session
        // exists, or (b) ANY meeting is durably `paused`. Grace-window and
        // finalize-in-flight meetings (status still `recording`, no live
        // session) deliberately do NOT refuse — the shipped back-to-back
        // stop-then-start path stays green.
        guard active == nil else { throw RecordingControllerError.alreadyRecording }
        try await refuseIfAnyMeetingPaused(excluding: nil)
        try checkDiskSpace()

        let startedAt = now()
        // G12 CALENDAR tier: a suggestion-matched start carries BOTH the
        // event title AND a calendar anchor (`PreMeetingScheduler` /
        // `startRecording(suggestion:)`), so the title is calendar-sourced and
        // outranks a later llm promotion (it never claims a non-`default`
        // row). An anchorless start — no title (date default) or, in principle,
        // a manual title with no calendar event — is `default`, leaving the
        // ad-hoc llm promotion free to claim it.
        let resolvedTitle = title ?? Self.defaultTitle(for: startedAt)
        let titleSource: TitleSource =
            (title != nil && anchor?.eventIdentifier != nil) ? .calendar : .default
        let meeting = Meeting(
            id: ULID.generate(),
            title: resolvedTitle,
            titleSource: titleSource,
            startedAt: startedAt,
            source: source,
            status: .recording,
            attendees: attendees,
            meetingCode: meetingCode,
            // Durable two-track marker: the dispatch must know this meeting
            // was captured even if a track's file is later lost.
            captured: true,
            // G11 §1: the calendar anchor, written ONCE here when the start was
            // suggestion-matched (nil = ad-hoc → both columns NULL). No
            // retroactive binding.
            calendarEventID: anchor?.eventIdentifier,
            scheduledEndMs: anchor?.scheduledEndMs,
            createdAt: startedAt,
            updatedAt: startedAt)
        try database.paths.createMeetingDirectory(meeting.id)
        try await MeetingRepository(database: database).create(meeting)
        // C14: part-1 row before the capture session (row-before-session —
        // a crash can leave a row without files, which the stitcher
        // tolerates, but never part files without a row).
        try await CaptureParts.insertPart(
            database, meetingID: meeting.id, partIndex: 1,
            startedAtMs: Int64(startedAt.timeIntervalSince1970 * 1000))

        let startInfo: CaptureStartInfo
        do {
            let meetingID = meeting.id
            startInfo = try await engine.start(
                systemCAF: database.paths.captureCAFURL(meetingID, track: .system),
                micCAF: database.paths.captureCAFURL(meetingID, track: .mic),
                onEvent: { [weak self] event in
                    Task { await self?.handleEngineEvent(event) }
                })
        } catch {
            // Honest failure: the row stays, marked failed (never deleted).
            try? await database.pool.write { db in
                try db.execute(
                    sql: "UPDATE meeting SET status = ?, last_processing_error = ? WHERE id = ?",
                    arguments: [
                        MeetingStatus.failed.rawValue, "capture start failed: \(error)", meeting.id,
                    ])
            }
            // The engine creates the CAF files before its graph build; a
            // start failure can leave header-only stubs that the next
            // launch's sweep would "recover" into empty retained audio.
            // Deleting them is NOT a retention event: removal happens only
            // when the file provably carries ZERO audio frames AND the row
            // was just marked failed-at-start. Anything unreadable or
            // non-empty stays on disk (hard floor 2).
            removeZeroFrameStubs(meetingID: meeting.id, part: 1)
            // Row-follows-files: the part row goes only when the part's
            // files are provably gone.
            await CaptureParts.deletePartRowIfFilesGone(database, meetingID: meeting.id, partIndex: 1)
            throw error
        }

        active = ActiveSession(meeting: meeting, partIndex: 1)
        emit(.started(meetingID: meeting.id, at: startedAt))
        if startInfo.micStreams == 0 {
            // Deterministically AFTER .started (the state machine's start
            // reset would erase an earlier emission): the mic track will
            // stay empty and the silence detector can never fire — this is
            // the only chance to warn.
            logger.error("input device exposes no streams; mic track will be EMPTY")
            emit(.micSilence(active: true))
        }
        logger.notice("recording started: \(meeting.id) source=\(source.rawValue)")
        let observer = self.observer
        let started = meeting
        Task { await observer.recordingStarted(
            meetingID: started.id, meetingCode: started.meetingCode, title: started.title, partIndex: 1) }
        return meeting
    }

    // MARK: - Resume (C14 grace window → part n+1)

    /// Resumes a meeting held in grace as its next capture part.
    /// Precondition: the meeting is in grace (tracker-owned; the controller
    /// trusts its caller) and no session is active. Disk precheck, `endedAt`
    /// CLEARED at part start (the correlation window falls back to its open
    /// `endedAt`-or-now form), part row inserted, THEN the capture session
    /// into the part's CAF paths; `.started` re-emitted (indicator back to
    /// recording); live session re-registered (live correlation resumes).
    @discardableResult
    public func resume(meetingID: MeetingID) async throws -> Meeting {
        // M-9: the SAME refusal predicate guards every resume entry. Resuming
        // meeting X refuses when a live session exists or any OTHER meeting is
        // durably `paused` — never two open meetings through any door
        // (including the C14 grace rejoin into this method).
        guard active == nil else { throw RecordingControllerError.alreadyRecording }
        try await refuseIfAnyMeetingPaused(excluding: meetingID)
        try checkDiskSpace()
        guard var meeting = try await MeetingRepository(database: database).fetch(meetingID) else {
            throw BlaiseDatabaseError.meetingNotFound(meetingID)
        }
        let resumedAt = now()
        let part = await CaptureParts.nextPartIndex(database, meetingID: meetingID)
        meeting.endedAt = nil
        meeting.updatedAt = resumedAt
        // G12: a surgical two-column write, not a full-row `update(meeting)`.
        // The fetch above is fresh, but a rename landing between fetch and
        // write would still be clobbered by a full-row write of the stale
        // value; writing only the columns this resume owns preserves any
        // concurrent `title`/`title_source` change.
        try await database.pool.write { db in
            try db.execute(
                sql: "UPDATE meeting SET ended_at = NULL, updated_at = ? WHERE id = ?",
                arguments: [resumedAt, meetingID])
        }
        // Row before session (crash leaves a row without files, never the
        // reverse).
        try await CaptureParts.insertPart(
            database, meetingID: meetingID, partIndex: part,
            startedAtMs: Int64(resumedAt.timeIntervalSince1970 * 1000))

        let startInfo: CaptureStartInfo
        do {
            startInfo = try await engine.start(
                systemCAF: database.paths.captureCAFURL(meetingID, track: .system, part: part),
                micCAF: database.paths.captureCAFURL(meetingID, track: .mic, part: part),
                onEvent: { [weak self] event in
                    Task { await self?.handleEngineEvent(event) }
                })
        } catch {
            // The meeting stays in grace (status `recording`, earlier parts
            // intact); grace expiry finalizes them. Zero-frame stubs are
            // removed (the C1 rule) and the fresh row follows its files.
            logger.error("resume part \(part) failed for \(meetingID): \(error)")
            removeZeroFrameStubs(meetingID: meetingID, part: part)
            await CaptureParts.deletePartRowIfFilesGone(database, meetingID: meetingID, partIndex: part)
            throw error
        }

        active = ActiveSession(meeting: meeting, partIndex: part)
        emit(.started(meetingID: meetingID, at: resumedAt))
        if startInfo.micStreams == 0 {
            logger.error("input device exposes no streams; mic track will be EMPTY")
            emit(.micSilence(active: true))
        }
        logger.notice("recording resumed: \(meetingID) part=\(part)")
        let observer = self.observer
        let resumed = meeting
        Task { await observer.recordingStarted(
            meetingID: resumed.id, meetingCode: resumed.meetingCode, title: resumed.title, partIndex: part) }
        return meeting
    }

    // MARK: - Pause / Resume-from-pause / End-from-pause (G9)

    /// Manual pause of the live session: finalize the current capture part
    /// (the C14 verified-encode path) and commit `status = paused` in ONE
    /// transaction with the part close (the C11 flag discipline). Floor 2:
    /// nothing recorded before the pause is lost — the part is encoded and
    /// retained exactly like a stop. Unlike stop: NO processing kick, NO
    /// grace, and the zero/no-recoverable-audio failed write NEVER fires
    /// (pausing a seconds-old meeting is legal and leaves a near-empty part —
    /// the End path is where zero-audio is evaluated).
    ///
    /// The control is disabled from controller state while a stop is in
    /// flight; the `!session.stopping` guard is the residual TOCTOU backstop —
    /// a late click after an auto-stop finalize began is a `notRecording`
    /// no-op (AC1).
    @discardableResult
    public func pause() async throws -> Meeting {
        guard var session = active, !session.stopping else {
            throw RecordingControllerError.notRecording
        }
        session.stopping = true
        active = session
        let partIndex = session.partIndex
        var meeting = session.meeting

        await engine.stop()

        let pausedAt = now()
        let pausedAtMs = Int64(pausedAt.timeIntervalSince1970 * 1000)

        // Encode the part off the actor (a long part's encode must not block
        // the live-correlation seam), exactly as the stop path does.
        finalizing += 1
        defer {
            finalizing -= 1
            if finalizing == 0 {
                quiescenceWaiters.forEach { $0.resume() }
                quiescenceWaiters.removeAll()
            }
        }
        let paths = database.paths
        let pausedID = meeting.id
        let finalizer = self.finalizer
        let outcome = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: finalizer(paths, pausedID, partIndex))
            }
        }
        if let note = outcome.recoveryNote {
            await CaptureRecovery.writeRecoveryNote(
                database: database, meetingID: meeting.id, note: note)
        }
        // Row-follows-files: a provably-empty pause part (zero-frame CAFs
        // removed by the finalize, no part m4a) drops its row — but the
        // meeting still becomes `paused` (legal; End evaluates zero-audio).
        if !outcome.anyTrack {
            await CaptureParts.deletePartRowIfFilesGone(
                database, meetingID: meeting.id, partIndex: partIndex)
        }

        // The single transaction: close the part AND write `paused` together.
        // A crash here either committed (durably `paused`) or did not (stays
        // `recording` — kill-mid-capture). The AC3 hook proves atomicity.
        try await CaptureParts.closePartAndSetStatus(
            database, meetingID: meeting.id, partIndex: partIndex,
            endedAtMs: pausedAtMs, status: .paused,
            midTransactionHook: transactionHook)
        meeting.status = .paused
        // Mirror the ms-truncated value persisted by closePartAndSetStatus so
        // the returned meeting matches the durable row exactly.
        let persistedEnd = Date(timeIntervalSince1970: Double(pausedAtMs) / 1000.0)
        meeting.endedAt = persistedEnd
        meeting.updatedAt = persistedEnd

        // The capture is over for this part: release the session.
        active = nil
        let accumulated = await CaptureParts.accumulatedRecordedSeconds(
            database, meetingID: meeting.id)
        emit(.paused(meetingID: meeting.id, accumulatedSeconds: accumulated))
        logger.notice("recording paused: \(meeting.id) part=\(partIndex)")
        let observer = self.observer
        let paused = meeting
        Task { await observer.recordingPaused(
            meetingID: paused.id, meetingCode: paused.meetingCode) }
        return meeting
    }

    /// Manual resume of a paused meeting (menu Resume on a paused row, the
    /// relaunch Resume surface). Mirrors `resume(meetingID:)` but the source
    /// status is `paused`, and the inverted M-7 order is load-bearing: the
    /// engine + new-part CAFs are opened FIRST, then the part row AND
    /// `status = recording` commit in ONE transaction. A crash at ANY point
    /// before that commit leaves the meeting durably `paused` (the §2 gate
    /// rescues the orphaned new-part CAF as residue — nothing processes).
    /// Engine-start failure OR commit failure → the engine is torn down and
    /// the meeting stays `paused`, error surfaced — no live-engine-against-
    /// paused-row state persists.
    ///
    /// THE CALLER (the universal refusal predicate) guarantees no live
    /// session exists and no OTHER meeting is paused before this runs (M-9);
    /// the `active == nil` guard is the controller-level backstop.
    @discardableResult
    public func resumePaused(meetingID: MeetingID) async throws -> Meeting {
        // M-9: refuse if a live session exists or any OTHER meeting is paused
        // (resuming THIS paused meeting is the point — exclude it).
        guard active == nil else { throw RecordingControllerError.alreadyRecording }
        try await refuseIfAnyMeetingPaused(excluding: meetingID)
        try checkDiskSpace()
        guard var meeting = try await MeetingRepository(database: database).fetch(meetingID) else {
            throw BlaiseDatabaseError.meetingNotFound(meetingID)
        }
        let resumedAt = now()
        let part = await CaptureParts.nextPartIndex(database, meetingID: meetingID)

        // Engine + new-part CAFs FIRST (M-7).
        let startInfo: CaptureStartInfo
        do {
            startInfo = try await engine.start(
                systemCAF: database.paths.captureCAFURL(meetingID, track: .system, part: part),
                micCAF: database.paths.captureCAFURL(meetingID, track: .mic, part: part),
                onEvent: { [weak self] event in
                    Task { await self?.handleEngineEvent(event) }
                })
        } catch {
            // Engine-start failure: stays `paused`, earlier parts intact. The
            // header-only stubs of the failed part are zero-frame-removed; no
            // part row was written, so there is nothing to delete.
            logger.error("resume-from-pause engine start failed for \(meetingID): \(error)")
            removeZeroFrameStubs(meetingID: meetingID, part: part)
            throw error
        }

        // The single transaction: open the part row AND flip `recording`.
        do {
            try await CaptureParts.openPartAndSetStatus(
                database, meetingID: meetingID, partIndex: part,
                startedAtMs: Int64(resumedAt.timeIntervalSince1970 * 1000),
                status: .recording, updatedAt: resumedAt,
                midTransactionHook: transactionHook)
        } catch {
            // Commit failure: tear the engine down — no live engine may
            // persist against a `paused` row. The new-part CAFs stay on disk
            // as orphan residue (floor 2; the §2 gate keeps them encode-only),
            // the meeting stays durably `paused`, the error surfaces.
            logger.error("resume-from-pause commit failed for \(meetingID): \(error) — engine torn down")
            await engine.stop()
            throw error
        }
        meeting.status = .recording
        meeting.endedAt = nil
        meeting.updatedAt = resumedAt

        active = ActiveSession(meeting: meeting, partIndex: part)
        let accumulated = await CaptureParts.accumulatedRecordedSeconds(
            database, meetingID: meetingID)
        emit(.resumed(meetingID: meetingID, at: resumedAt, accumulatedSeconds: accumulated))
        emit(.started(meetingID: meetingID, at: resumedAt))
        if startInfo.micStreams == 0 {
            logger.error("input device exposes no streams; mic track will be EMPTY")
            emit(.micSilence(active: true))
        }
        logger.notice("recording resumed from pause: \(meetingID) part=\(part)")
        let observer = self.observer
        let resumed = meeting
        Task {
            await observer.recordingUnpaused(
                meetingID: resumed.id, meetingCode: resumed.meetingCode, resumed: true)
            await observer.recordingStarted(
                meetingID: resumed.id, meetingCode: resumed.meetingCode, title: resumed.title,
                partIndex: part)
        }
        return meeting
    }

    /// End-from-pause: leave `paused` directly into the normal
    /// finalize→processing flow over the EXISTING parts (no new part). The
    /// `paused → processing` flip happens FIRST, in its own transaction,
    /// BEFORE any dispatch (AC1) — so §2's refusal set never blocks a
    /// deliberate End. `endedAt` is already the last part's end (set at
    /// pause). The zero/no-recoverable-audio evaluation lives in the kick's
    /// pipeline run, which fails honestly if no part has audio.
    @discardableResult
    public func endPaused(meetingID: MeetingID) async throws -> Meeting {
        guard var meeting = try await MeetingRepository(database: database).fetch(meetingID) else {
            throw BlaiseDatabaseError.meetingNotFound(meetingID)
        }
        guard meeting.status == .paused else {
            // Not actually paused (a racing resume/kick already moved it):
            // no-op, return current state.
            return meeting
        }
        // Flip paused → processing FIRST, in its own transaction, so the
        // subsequent kick (which refuses `paused`) is not blocked. The flip is
        // GUARDED `WHERE status = 'paused'` and reports whether it moved the
        // row: if a concurrent Resume already flipped the meeting back to
        // `recording` (the End/Resume race, H-1), the flip is a no-op and we
        // MUST NOT kick — a live recording would otherwise be processed and
        // handed off mid-capture. Re-fetch the current durable state and
        // return it without kicking.
        await endFlipHook?()  // H-1 test seam: drive the fetch→flip TOCTOU
        let flipped = try await CaptureParts.flipPausedToProcessing(database, meetingID: meetingID)
        guard flipped else {
            logger.notice(
                "endPaused no-op: \(meetingID) is no longer paused (a resume won the race) — no kick")
            return (try? await MeetingRepository(database: database).fetch(meetingID)) ?? meeting
        }
        meeting.status = .processing

        // Clear automation linkage (manualControl + suppression) — the
        // meeting is leaving for processing.
        let observer = self.observer
        let ended = meeting
        Task { await observer.recordingUnpaused(
            meetingID: ended.id, meetingCode: ended.meetingCode, resumed: false) }

        // Normal finalize→processing flow over existing parts — fire-and-
        // forget (the run records its own failures), exactly like the stop
        // path's kick. The flip already happened, so this dispatch is not
        // refused by §2's paused rule.
        let kicker = processKicker
        Task { await kicker(meetingID) }
        return meeting
    }

    /// G11 §3: the durable resume-grace deadline writer. Called by the
    /// tracker's `persistGrace` seam — non-nil epoch-ms at grace entry (before
    /// the in-memory timer is armed), nil at every grace exit (clear-before-
    /// action). Its own transaction; the tracker holds no DB handle. Guarded
    /// `WHERE id = ?` only — the write is intent-driven, not status-keyed (the
    /// row is `recording` throughout a standing grace by construction).
    public func persistGraceDeadline(meetingID: MeetingID, until: Int64?) async {
        try? await database.pool.write { db in
            try db.execute(
                sql: "UPDATE meeting SET grace_until_ms = ? WHERE id = ?",
                arguments: [until, meetingID])
        }
    }

    /// G9 grace→paused conversion: a meeting auto-stopped into grace has its
    /// parts already finalized (the auto-stop encoded them) and no live
    /// session — converting it to paused is purely the durable status write
    /// (no part-finalize). The grace meeting's `endedAt` already stands from
    /// the auto-stop. Idempotent: only flips a `recording` row (a racing
    /// finalize that already moved it is a no-op).
    public func pauseGraceMeeting(meetingID: MeetingID) async {
        try? await database.pool.write { db in
            try db.execute(
                sql: "UPDATE meeting SET status = ?, updated_at = ? WHERE id = ? AND status = ?",
                arguments: [
                    MeetingStatus.paused.rawValue, self.now(), meetingID,
                    MeetingStatus.recording.rawValue,
                ])
        }
        // Drive the SAME holder path a live pause does: the recording-events
        // handler sets `pausedMeetingID` + applies `.meetingPaused`. Without
        // this the converted meeting shows no paused display and its Resume /
        // End controls are unreachable. The auto-stop already finalized the
        // parts, so `accumulatedSeconds` is the sum of the closed durations.
        let accumulated = await CaptureParts.accumulatedRecordedSeconds(
            database, meetingID: meetingID)
        emit(.paused(meetingID: meetingID, accumulatedSeconds: accumulated))
        logger.notice("grace meeting written to paused: \(meetingID)")
    }

    /// G10 §2/2b: per-meeting paused teardown for a DELETE of a `paused`
    /// meeting. The same automation teardown the End path runs — clears the
    /// tracker `manualControl` flag and the paused-class suppression record so
    /// the deleted meeting's linkage does not outlive its row. `meetingCode`
    /// is the caller's (read BEFORE the row is erased). The app-layer delete
    /// additionally clears the `pausedMeetingID` holder mirror (the indicator
    /// window + the refuse-everything predicate); without that the user is
    /// trapped until relaunch (G9 M-9).
    public func clearPausedTeardownForDelete(meetingID: MeetingID, meetingCode: String?) async {
        await observer.recordingUnpaused(
            meetingID: meetingID, meetingCode: meetingCode, resumed: false)
    }

    /// G9 (H-2): the durable paused meeting to surface at launch. A clean quit-
    /// and-keep-paused leaves exactly one `paused` row (the single-open-meeting
    /// invariant); relaunch reads it back so the indicator/menu/main-window
    /// expose Resume / End & process — without this the app traps the user in a
    /// refuse-everything state with no exit. Returns the meeting plus its
    /// accumulated recorded time (the paused-timer base).
    public func restorablePausedMeeting() async -> (meeting: Meeting, accumulatedSeconds: TimeInterval)? {
        guard let pausedID = await pausedMeetingID(excluding: nil),
            let meeting = try? await MeetingRepository(database: database).fetch(pausedID)
        else { return nil }
        let accumulated = await CaptureParts.accumulatedRecordedSeconds(database, meetingID: pausedID)
        return (meeting, accumulated)
    }

    /// G9 (M-9 support): does ANY meeting hold durable status `paused`? The
    /// universal refusal predicate consults this on every start AND resume
    /// entry — `start()` refuses when a live session exists OR any meeting is
    /// paused; resume-from-grace refuses when a live session exists OR any
    /// OTHER meeting is paused. Never two open meetings through any door.
    public func pausedMeetingID(excluding: MeetingID? = nil) async -> MeetingID? {
        (try? await database.pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT id FROM meeting WHERE status = ? AND id IS NOT ? ORDER BY id LIMIT 1",
                arguments: [MeetingStatus.paused.rawValue, excluding])
        }) ?? nil
    }

    // MARK: - Stop (manual, quit-intercept, and write-failure share it)

    /// Stops the capture, sets `endedAt`, encodes the current part's CAFs
    /// through the verified-encode gate (CAF deleted only after the m4a
    /// verifies), and kicks processing. `alarm` is non-nil on the
    /// write-failure path. Returns only after the encode completes (the quit
    /// intercept relies on that), but the encode runs OFF the actor:
    /// `.stopping` is emitted first, the session is released, and a new
    /// recording can start while the previous one finalizes (back-to-back
    /// meetings). Manual semantics: stop means stop — never enters grace.
    @discardableResult
    public func stop(alarm: String? = nil) async throws -> Meeting {
        try await performStop(alarm: alarm, manual: true, kickProcessing: true).meeting
    }

    /// The tracker's auto-stop (debounced end / watchdog). Identical stop +
    /// verified per-part encode; with `finalizeImmediately` false the
    /// processing kick MOVES to grace expiry (the tracker calls
    /// `kickProcessing` there) — Resume window Off passes true and the stop
    /// finalizes exactly like a manual one.
    public func autoStop(finalizeImmediately: Bool) async throws -> AutoStopOutcome {
        try await performStop(alarm: nil, manual: false, kickProcessing: finalizeImmediately)
    }

    /// Grace-expiry / Finalize-now processing kick (the existing
    /// track-inventory-aware dispatch).
    public func kickProcessing(meetingID: MeetingID) async {
        await processKicker(meetingID)
    }

    private func performStop(
        alarm: String?, manual: Bool, kickProcessing: Bool
    ) async throws -> AutoStopOutcome {
        guard var session = active, !session.stopping else {
            throw RecordingControllerError.notRecording
        }
        session.stopping = true
        active = session
        let partIndex = session.partIndex

        await engine.stop()

        var meeting = session.meeting
        let stoppedAt = now()
        meeting.endedAt = stoppedAt  // every part stop sets it (latest wins)
        meeting.updatedAt = stoppedAt
        let stoppingID = meeting.id
        // G12 title-bug fix: `session.meeting` is the START-TIME snapshot — a
        // rename DURING recording rewrote the DB row's `title` but NOT this
        // value type, so a full-row `MeetingRepository.update(meeting)` here
        // would clobber the renamed title back to the date default. Write ONLY
        // the two columns this stop actually owns (mirroring the start-failure
        // surgical write below), leaving every concurrently-changed column —
        // `title`/`title_source` above all — untouched on the row.
        do {
            try await database.pool.write { db in
                try db.execute(
                    sql: "UPDATE meeting SET ended_at = ?, updated_at = ? WHERE id = ?",
                    arguments: [stoppedAt, stoppedAt, stoppingID])
            }
        } catch {
            logger.error("endedAt update failed for \(stoppingID): \(error)")
            try? await database.pool.write { db in
                try db.execute(
                    sql: "UPDATE meeting SET last_processing_error = ? WHERE id = ?",
                    arguments: ["endedAt update failed: \(error)", stoppingID])
            }
        }
        // Close the part row (the stitcher's gap source).
        try? await CaptureParts.closePart(
            database, meetingID: meeting.id, partIndex: partIndex,
            endedAtMs: Int64(stoppedAt.timeIntervalSince1970 * 1000))

        // The capture is over (files closed): release the session before
        // the encode so the controller stays responsive and startable.
        active = nil
        emit(.stopping(meetingID: meeting.id))
        finalizing += 1
        defer {
            finalizing -= 1
            if finalizing == 0 {
                quiescenceWaiters.forEach { $0.resume() }
                quiescenceWaiters.removeAll()
            }
        }

        // Encode whatever exists — also the write-failure path's salvage.
        // Off the cooperative pool: a long meeting's encode must not block
        // the actor (currentSession is the C12 live-correlation seam).
        let paths = database.paths
        let stoppedID = meeting.id
        let finalizer = self.finalizer
        let outcome = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: finalizer(paths, stoppedID, partIndex))
            }
        }
        if let note = outcome.recoveryNote {
            await CaptureRecovery.writeRecoveryNote(
                database: database, meetingID: meeting.id, note: note)
        }

        // Meeting-wide recoverability (C14): the failed-status write fires
        // only when NO part of the meeting has recoverable audio. An empty
        // part n ≥ 2 with surviving earlier parts alarms loudly but leaves
        // status `recording` (grace continues; the survivors process at
        // grace end or through the launch sweep).
        let partRecoverable = outcome.anyTrack
        let meetingRecoverable =
            partRecoverable || CaptureParts.anyRetainedAudio(paths: paths, meetingID: meeting.id)
        if !partRecoverable {
            // Row-follows-files: the empty part's row is deleted ONLY when
            // every file of the part is provably gone (zero-frame CAFs
            // removed by the finalize, no part m4a). An encode-FAILED part
            // whose CAF is retained keeps its row.
            await CaptureParts.deletePartRowIfFilesGone(
                database, meetingID: meeting.id, partIndex: partIndex)
        }

        // No recoverable audio is a loud failure even on a manual stop —
        // never a silent dead end.
        let effectiveAlarm: String?
        if let alarm {
            effectiveAlarm = alarm
        } else if !meetingRecoverable {
            effectiveAlarm = "Recording produced no recoverable audio"
        } else if !partRecoverable {
            effectiveAlarm = "Recording part \(partIndex) produced no recoverable audio"
        } else {
            effectiveAlarm = nil
        }
        let kicked = meetingRecoverable && kickProcessing
        emit(.stopped(meetingID: meeting.id, alarm: effectiveAlarm, kickedProcessing: kicked))
        logger.notice(
            "recording stopped: \(meeting.id) part=\(partIndex) tracks=\(outcome.encodedTracks.map(\.rawValue).joined(separator: ","))\(effectiveAlarm.map { " ALARM: \($0)" } ?? "")")

        if kicked {
            let kicker = processKicker
            let meetingID = meeting.id
            Task { await kicker(meetingID) }
        } else if !meetingRecoverable {
            // Nothing recoverable anywhere: today's no-audio failed path
            // (§4 entry condition — never enters grace).
            let meetingID = meeting.id
            try? await database.pool.write { db in
                try db.execute(
                    sql: "UPDATE meeting SET status = ?, last_processing_error = ? WHERE id = ?",
                    arguments: [
                        MeetingStatus.failed.rawValue, "capture produced no recoverable audio",
                        meetingID,
                    ])
            }
        }
        let observer = self.observer
        let stopped = meeting
        Task { await observer.recordingStopped(
            meetingID: stopped.id, meetingCode: stopped.meetingCode, manual: manual) }
        return AutoStopOutcome(
            meeting: meeting, recoverableAudio: meetingRecoverable,
            scheduledEndMs: meeting.scheduledEndMs)
    }

    private func handleEngineEvent(_ event: CaptureEngineEvent) async {
        switch event {
        case .micSilence(let activeNow):
            emit(.micSilence(active: activeNow))
        case .captureDown(let activeNow):
            emit(.captureDown(active: activeNow))
        case .level(let you, let others):
            emit(.level(you: you, others: others))
        case .writeFailure(let message):
            logger.error("capture write failure — stopping: \(message)")
            // The one sanctioned automatic stop pre-C14: immediate finalize
            // (not manual for suppression purposes — the call may continue
            // and a re-record offer is correct).
            _ = try? await performStop(
                alarm: "Recording stopped: \(message)", manual: false, kickProcessing: true)
        }
    }

    // MARK: - Helpers

    /// Start-failure cleanup: removes a capture CAF stub ONLY when a
    /// duration probe proves it carries zero audio frames (no audio ever
    /// existed, so this is not a retention event). An unreadable or
    /// non-empty CAF is left on disk for the recovery sweep.
    private func removeZeroFrameStubs(meetingID: MeetingID, part: Int) {
        let fm = FileManager.default
        for track in CaptureTrack.allCases {
            let caf = database.paths.captureCAFURL(meetingID, track: track, part: part)
            guard fm.fileExists(atPath: caf.path),
                let duration = try? AudioTranscoder.duration(of: caf),
                duration == 0
            else { continue }
            try? fm.removeItem(at: caf)
            logger.notice(
                "removed zero-frame capture stub after start failure: \(caf.lastPathComponent)")
        }
    }

    /// The (b) half of the universal refusal predicate: throws
    /// `meetingPaused` if any meeting (other than `excluding`) is durably
    /// `paused`. The title drives the start-surface prompt.
    private func refuseIfAnyMeetingPaused(excluding: MeetingID?) async throws {
        guard let pausedID = await pausedMeetingID(excluding: excluding) else { return }
        let title =
            (try? await MeetingRepository(database: database).fetch(pausedID))?.title
            ?? "the paused meeting"
        throw RecordingControllerError.meetingPaused(meetingID: pausedID, title: title)
    }

    private func checkDiskSpace() throws {
        let values = try? database.rootURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let free = values?.volumeAvailableCapacityForImportantUsage,
            free < CaptureLimits.minimumFreeDiskBytes
        {
            throw RecordingControllerError.insufficientDiskSpace(freeBytes: free)
        }
    }

    /// "Meeting 10/06/2026 14:30" — DD/MM/YYYY + 24 h per the notes
    /// conventions; fixed format, locale-independent.
    static func defaultTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "dd/MM/yyyy HH:mm"
        return "Meeting \(formatter.string(from: date))"
    }
}
