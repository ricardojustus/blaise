import AVFoundation
import BlaiseCore
import EventKit
import Foundation
import GRDB
import Network
import Observation
import SwiftUI
import Synchronization
import os

// C10 composition root: every long-lived object is constructed here —
// engines (B-8), pipeline, handoff worker, meet-events listener, observable
// models — and shared with the view tree through SwiftUI's environment.

/// Window-level UI state shared across the split view (search focus command,
/// selection, cross-view navigation requests).
@MainActor @Observable
final class AppUIState {
    var selectedGroup: LibraryModel.SmartGroup = .all
    var selectedMeetingID: MeetingID?
    var searchText = ""
    /// Incremented by the ⌘F command; the library view focuses the field.
    var searchFocusRequest = 0
    /// Incremented when a handoff-warning notification is clicked (L-3): the
    /// main window opens and the app activates, surfacing the queue banner.
    var openMainWindowRequest = 0
    /// Set when a search hit / user-action entry asks the detail to open a
    /// specific tab (and scroll to a segment).
    var detailRequest: DetailRequest?
    var importSourceURL: URL?
    /// G15 §2/§3: the meeting whose participant-confirmation sheet the main
    /// window should present — set when a recording stops while Blaise is
    /// frontmost, and when the confirm notification is clicked (which can land
    /// before the meeting has parked, so it cannot rely on the detail banner).
    var participantConfirmMeeting: Meeting?
    /// F1 Inc2: set by the "Reprocess All Meetings…" menu item; presents the
    /// cost-cap confirmation sheet.
    var reprocessAllRequested = false
    /// G3 onboarding: presented at most ONCE per launch when the stored
    /// identity is empty (first run / not yet onboarded). Skippable — the app
    /// works unnamed — and re-offerable from Settings, but never nagging: the
    /// auto-offer fires a single time, gated by `onboardingOffered`.
    var showOnboarding = false
    /// Set true the first time the auto-offer fires (or is skipped) this
    /// launch, so it is never raised twice automatically.
    var onboardingOffered = false
    /// Transient failure from a library/detail action (rename, done toggle)
    /// — the window-level analog of `CaptureStatusHolder.lastActionError`:
    /// set on failure, cleared on the next success, shown as a dismissible
    /// banner over the split view.
    var lastActionError: String?

    struct DetailRequest: Equatable {
        enum Target: Equatable {
            case notes
            case userActions
            case transcript(segmentID: Int64?)
        }

        var meetingID: MeetingID
        var target: Target
        /// Actual stored spellings wrapped by the FTS snippet. Destination
        /// views use these only for scrolling/highlighting; persistence,
        /// notes content, digest generation, and handoff are untouched.
        var searchTerms: [String] = []
    }
}

enum MeetListenerState: Equatable {
    case starting
    case listening
    /// Expected for isolated/demo data roots so they can never steal the live
    /// app's fixed loopback port.
    case disabledForIsolatedData
    case unavailable(String)
}

struct MeetListenerReceipt: Equatable {
    var status: Int
    var receivedAt: Date
}

/// Observable health of the Chrome-extension ingress. This deliberately stops
/// at the app-side acceptance boundary; it does not alter or reinterpret the
/// Meet batch, recording correlation, evidence payload, or handoff path.
@MainActor @Observable
final class ListenerStatusHolder {
    var state: MeetListenerState = .starting
    var lastRequestAt: Date?
    var lastResponse: MeetListenerReceipt?

    var banner: String? {
        guard case .unavailable(let detail) = state else { return nil }
        return detail
    }

    var isUnavailable: Bool {
        if case .unavailable = state { return true }
        return false
    }

    func noteRequest(at date: Date = Date()) {
        lastRequestAt = date
    }

    func noteResponse(status: Int, at date: Date = Date()) {
        lastResponse = MeetListenerReceipt(status: status, receivedAt: date)
    }
}

@MainActor @Observable
final class AppEnvironment {
    let database: BlaiseDatabase
    /// The main window's `NSWindow`, captured by `WindowAccessor` when it
    /// appears, so the AppKit `StatusBarController` can raise the EXACT window
    /// for "Open Blaise" / notification routing (not a heuristic match). Weak
    /// (the window may close) and observation-ignored (read imperatively).
    @ObservationIgnored weak var mainWindow: NSWindow?
    /// Captured from the main WindowGroup's SwiftUI environment while a window
    /// exists. Unlike the weak NSWindow reference, this can create a fresh main
    /// window after the user fully closes the previous one.
    @ObservationIgnored var reopenMainWindow: (@MainActor () -> Void)?
    let registry: EngineRegistry
    let settings: SettingsStore
    let secrets: KeychainSecretStore
    let ledger: CloudSpendLedger
    let pipeline: ProcessingPipeline
    let worker: HandoffWorker
    let handoffStatus: HandoffStatusHolder
    /// F1 Inc2: the durable processing-queue worker — the single admission path
    /// for full-pipeline work (the user's Process/Regenerate, import, recovery,
    /// the listener re-mint, and Reprocess-all all enqueue here).
    let processingQueue: ProcessingQueueWorker
    /// F1 Inc2: the observable processing-queue state for the Settings panel +
    /// StatusBar (the worker publishes into it).
    let processingStatus: ProcessingStatusHolder
    let ingestor: MeetEventsIngestor
    let listener: MeetEventsListener
    let listenerStatus: ListenerStatusHolder
    let library: LibraryModel
    let activity: PipelineActivityHolder
    let engineSettings: EngineSettingsModel
    let uiState = AppUIState()
    // C11: live capture.
    let recordingController: RecordingController
    let captureStatus = CaptureStatusHolder()
    // G12 §2: the two-channel live level meter's lock-free holder. Read ONLY
    // by the meter view (leaf observation) so a ≤ 10 Hz level publish never
    // invalidates the scene root.
    let levelMeter = LevelMeterHolder()
    let googleCalendar: GoogleCalendarModel
    let calendarSuggestions: CalendarSuggestionProvider
    // C15: native Slack Huddles roster/lifecycle (Socket Mode → ingestor).
    let slackHuddles: SlackHuddlesModel
    let slackHuddleTracker: SlackHuddleTracker
    // C14: recording automation.
    let tracker: MeetCallTracker
    let scheduler: PreMeetingScheduler
    let notificationAdapter = AutomationNotificationAdapter()
    /// For calendar attendee self-exclusion (loaded identity at start).
    private(set) var userEmail = UserIdentity.shippedDefault.email
    /// The user's display name, loaded at start and refreshed after
    /// onboarding — drives the detail view's user action-items section title
    /// (empty → neutral "My action items" / "Minhas ações", G3).
    private(set) var userName = UserIdentity.shippedDefault.name

    private var eventTask: Task<Void, Never>?
    private var purgeTask: Task<Void, Never>?
    private var recordingEventTask: Task<Void, Never>?
    /// G12 §2: the live `LevelMeter` model (RMS smoothing + silence detection +
    /// ≤ 10 Hz publish gate). Re-armed at each recording start; fed by the
    /// controller's `.level` events; publishes into `levelMeter` (the
    /// leaf-observed holder). nil when not recording.
    private var levelMeterModel: LevelMeter?
    /// Silence auto-pause watchdog (orthogonal to the `MeetCallTracker` end-
    /// detector): armed at each recording start/resume, fed the same `.level`
    /// events as the meter, and fires ONCE to `pauseRecording()` after BOTH
    /// tracks sit below the silence floor for the configured threshold. Disarmed
    /// on pause/stop and after firing.
    private var silenceWatchdog = SilenceWatchdog()
    private var automationEventTask: Task<Void, Never>?
    private var schedulerTask: Task<Void, Never>?
    private var tickerTask: Task<Void, Never>?
    /// D17 self-heal: network-path restoration re-dispatches notes-pending
    /// meetings (same NWPathMonitor pattern as the handoff worker's).
    private var notesPathMonitor: NWPathMonitor?
    private let logger = Logger(subsystem: BlaiseBundle.identifier, category: "app")

    init() throws {
        let dataRoot: URL
        if let override = ProcessInfo.processInfo.environment["BLAISE_DATA_ROOT"] {
            dataRoot = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            dataRoot = try BlaiseDatabase.defaultRootURL()
        }
        let database = try BlaiseDatabase(rootURL: dataRoot)
        self.database = database
        let settings = SettingsStore(database: database)
        self.settings = settings
        let secrets = KeychainSecretStore()
        self.secrets = secrets
        self.ledger = CloudSpendLedger(database: database)
        self.registry = Self.buildRegistry(
            database: database, dataRoot: dataRoot, settings: settings, secrets: secrets,
            ledger: ledger)

        let handoffStatus = HandoffStatusHolder()
        self.handoffStatus = handoffStatus
        let worker = HandoffWorker(database: database, holder: handoffStatus)
        self.worker = worker
        // Late-bound: the pipeline needs the ingestor (sweeper) and the
        // ingestor needs the pipeline (post-ready dispatch) — the box closes
        // the cycle, set right after the pipeline exists.
        let dispatcherBox = ProcessingDispatcherBox()
        // C11: the live-session seam (C10's RecordingSessionProviding) —
        // boxed because the controller needs the pipeline, which needs the
        // ingestor; set right after the controller exists.
        let sessionBox = RecordingSessionBox()
        // C14: liveness/lifecycle signal seam (ingestor → tracker) and the
        // controller-lifecycle seam (controller → tracker) — boxed for the
        // same construction-order reason.
        let signalBox = MeetCallSignalBox()
        let observerBox = RecordingLifecycleObserverBox()
        let ingestor = MeetEventsIngestor(
            database: database, secrets: secrets, session: sessionBox, dispatcher: dispatcherBox,
            signals: signalBox)
        self.ingestor = ingestor
        let diarizer = FluidAudioDiarizer(
            configuration: EngineConfiguration(
                engineID: FluidAudioDiarizer.diarizerID,
                descriptors: FluidAudioDiarizer.descriptors,
                settings: settings, secrets: secrets),
            dataRoot: dataRoot)
        // G1 §4: provision the user glossary into the data root before the
        // first run can read it (idempotent; never overwrites an existing file).
        GlossaryProvisioning.ensure(dataRoot: dataRoot)
        self.pipeline = ProcessingPipeline(
            database: database,
            registry: registry,
            diarizer: diarizer,
            // G1 §3: rebuild the user-glossary stack at each run start; the full
            // UserLoad (diagnostics + timestamp) rides the activity observable (§5b).
            vocabularyProvider: { PipelineVocabulary.user(dataRoot: dataRoot) },
            handoffKicker: worker,
            meetEventsSweeper: ingestor)
        // F1 Inc2: the durable processing queue is the single admission path for
        // full-pipeline work. runJob = the unchanged executor; the job's origin
        // sets refuseCancelled (auto/recovery must not resurrect a user-cancelled
        // meeting — D1). Sequential worker + the single-flight chain = no new
        // concurrency.
        let pipeline = self.pipeline
        let processingStatus = ProcessingStatusHolder()
        self.processingStatus = processingStatus
        let pauseSettings = settings
        let processingQueue = ProcessingQueueWorker(
            database: database,
            holder: processingStatus,
            isPaused: {
                ((try? await pauseSettings.get(ProcessingQueueSettings.pausedKey, as: Bool.self)) ?? nil)
                    ?? false
            },
            runJob: { meetingID, origin in
                _ = try await pipeline.dispatchProcessing(
                    meetingID: meetingID, refuseCancelled: origin != .user)
            })
        self.processingQueue = processingQueue
        // C3: the Meet-listener post-ready re-mint routes through the queue too
        // (was a direct dispatchProcessing via the pipeline conformance).
        dispatcherBox.set(QueueProcessingDispatcher(queue: processingQueue))
        // C11: capture engine + lifecycle controller. The stop/End kick now
        // ENQUEUES (origin .auto → refuseCancelled) instead of dispatching.
        let recordingController = RecordingController(
            database: database,
            engine: CaptureSession(),
            processKicker: { meetingID in
                await processingQueue.enqueue(meetingID, origin: .auto)
            },
            observer: observerBox)
        self.recordingController = recordingController
        sessionBox.set(recordingController)
        let listenerStatus = ListenerStatusHolder()
        self.listenerStatus = listenerStatus
        self.listener = MeetEventsListener(ingestor: ingestor, status: listenerStatus)
        self.library = LibraryModel(database: database)
        self.activity = PipelineActivityHolder()
        self.engineSettings = EngineSettingsModel(registry: registry, settings: settings)

        // C14: the automation tracker + calendar pre-meeting scheduler.
        // Closures capture locals (not self — the boxes close the cycles).
        let googleCalendar = GoogleCalendarModel(settings: settings, secrets: secrets)
        self.googleCalendar = googleCalendar
        let calendar = CalendarSuggestionProvider(google: googleCalendar, settings: settings)
        self.calendarSuggestions = calendar
        // C15: the Slack huddle state machine emits MeetWireBatches into the
        // SAME ingestor as the Meet extension (roster/lifecycle persistence +
        // the automation signal forward come free). The member id is pushed in
        // by the model after settings load.
        let slackHuddleTracker = SlackHuddleTracker(selfUserID: "", emitter: ingestor)
        self.slackHuddleTracker = slackHuddleTracker
        self.slackHuddles = SlackHuddlesModel(
            settings: settings, secrets: secrets, tracker: slackHuddleTracker)
        let notifier = self.notificationAdapter
        let schedulerRef = Mutex<PreMeetingScheduler?>(nil)
        let tracker = MeetCallTracker(
            controller: recordingController,
            notifier: notifier,
            resumeWindowSeconds: { await AutomationSettings.resumeWindowSeconds(from: settings) },
            automationEnabled: { await AutomationSettings.enabled(from: settings) },
            suggestions: {
                let identity =
                    (try? await settings.get(UserIdentity.settingsKey, as: UserIdentity.self))
                    ?? nil ?? .shippedDefault
                await calendar.refresh(userEmail: identity.email)
                return await MainActor.run { calendar.suggestions }
            },
            calendarHook: { code in
                let scheduler = schedulerRef.withLock { $0 }
                await scheduler?.withdrawForCode(code)
            },
            // G11 §3: the durable grace deadline writer (the environment holds
            // the database; the tracker holds no DB handle).
            persistGrace: { meetingID, until in
                await recordingController.persistGraceDeadline(meetingID: meetingID, until: until)
            })
        self.tracker = tracker
        let scheduler = PreMeetingScheduler(
            notifier: notifier,
            recordingState: { code in
                if let session = await recordingController.currentSession(),
                    session.meetingCode == code
                {
                    return .recording
                }
                if await tracker.isInGrace(code: code) { return .grace }
                return .idle
            },
            alreadyDone: { code, windowStart, windowEnd in
                // A meeting row with this code whose endedAt falls inside
                // the event window: recorded and ended before a restart.
                (try? await database.pool.read { db in
                    try Int.fetchOne(
                        db,
                        sql: """
                            SELECT COUNT(*) FROM meeting
                            WHERE meeting_code = ? AND ended_at IS NOT NULL
                              AND ended_at >= ? AND ended_at <= ?
                            """,
                        arguments: [code, windowStart, windowEnd]) ?? 0
                } > 0) ?? false
            })
        self.scheduler = scheduler
        schedulerRef.withLock { $0 = scheduler }
        signalBox.set(tracker)
        observerBox.set(tracker)
    }

    /// Launch sequence. The debug seed command (`--seed-demo`) populates the
    /// data root from the repo fixtures BEFORE anything observes it.
    func start() async {
        // Recording lifecycle → indicator state machine. Subscribed FIRST:
        // the start affordances (menu bar, ⌥⌘R) work as soon as the scene
        // renders, so a launch-instant recording must not lose its
        // `.started` event to a later subscription.
        let recordingEvents = await recordingController.events()
        recordingEventTask = Task { [weak self] in
            for await event in recordingEvents {
                guard let self else { return }
                switch event {
                case .started(_, let at):
                    self.captureStatus.meetingEndPendingUntil = nil
                    self.captureStatus.apply(.captureStarted(at: at))
                    self.startLongSessionTicker()
                    // G12 §2: arm the level meter for this live session (each
                    // channel's silence clock starts from `at`).
                    self.levelMeterModel = LevelMeter(recordingStart: at)
                    self.levelMeter.reset()
                    // Silence auto-pause: arm for this live session (start AND
                    // resume re-emit `.started`); read the two settings at arm
                    // time so a change takes effect on the next session. The
                    // clock is monotonic process uptime (never wall-clock), so a
                    // sleep/wake gap cannot false-fire the watchdog.
                    self.silenceWatchdog.enabled =
                        await SilenceAutoPauseSettings.enabled(from: self.settings)
                    self.silenceWatchdog.thresholdSeconds =
                        await SilenceAutoPauseSettings.thresholdSeconds(from: self.settings)
                    self.silenceWatchdog.arm(nowUptime: ProcessInfo.processInfo.systemUptime)
                case .micSilence(let active):
                    self.captureStatus.apply(.micSilence(active: active))
                case .level(let you, let others):
                    // Feed raw RMS into the model (smoothing + silence); publish
                    // the ≤ 10 Hz result into the leaf-observed holder.
                    let stamp = Date()
                    self.levelMeterModel?.ingestYou(rms: you, at: stamp)
                    self.levelMeterModel?.ingestOthers(rms: others, at: stamp)
                    if self.levelMeterModel?.shouldPublish(now: stamp) == true,
                        let levels = self.levelMeterModel?.publish(now: stamp)
                    {
                        self.levelMeter.levels = levels
                    }
                    // Silence auto-pause: a sustained dual-track silence (both
                    // tracks below the floor for the threshold) pauses the
                    // recording ONCE. Disarm-then-pause so the queued `.paused`
                    // event can never re-trigger it; if the pause raced a stop
                    // (no-op), re-arm so a later genuine silence still fires.
                    let nowUptime = ProcessInfo.processInfo.systemUptime
                    if self.silenceWatchdog.note(you: you, others: others, nowUptime: nowUptime),
                        self.captureStatus.isRecording
                    {
                        let thresholdMinutes =
                            Int((self.silenceWatchdog.thresholdSeconds / 60).rounded())
                        self.silenceWatchdog.disarm()
                        self.logger.notice(
                            "silence auto-pause fired (both tracks below floor past threshold) — pausing recording")
                        if let paused = await self.pauseRecording() {
                            await self.notificationAdapter.postSilenceAutoPause(
                                meetingID: paused.id, title: paused.title, minutes: thresholdMinutes)
                        } else {
                            self.silenceWatchdog.arm(nowUptime: nowUptime)
                        }
                    }
                case .stopping:
                    // The encode may take a while — reflect "processing"
                    // immediately, before `.stopped` arrives.
                    self.tickerTask?.cancel()
                    self.captureStatus.meetingEndPendingUntil = nil
                    self.captureStatus.apply(.captureStopping)
                    // G12 §2: tear down the live meter so the toolbar settles.
                    self.levelMeterModel = nil
                    self.levelMeter.reset()
                    self.silenceWatchdog.disarm()
                case .stopped(let id, let alarm, let kicked):
                    if kicked {
                        self.captureStatus.processingMeetingID = id
                    }
                    self.captureStatus.apply(.captureStopped(alarm: alarm))
                    if let alarm {
                        // When a live capture won the indicator (a newer
                        // capture outranks the alarm under the M-3 §4 order:
                        // recording > processing > grace > paused), keep the
                        // alarm visible in the menu instead of the icon.
                        if case .alarm = self.captureStatus.state {
                        } else {
                            self.captureStatus.lastActionError = alarm
                        }
                    }
                case .paused(let id, let accumulatedSeconds):
                    // G9: the meeting is held open. The long-session ticker
                    // stops (no live capture); the indicator shows the
                    // accumulated recorded time with "paused".
                    self.tickerTask?.cancel()
                    self.captureStatus.meetingEndPendingUntil = nil
                    self.captureStatus.pausedMeetingID = id
                    let title = self.captureStatus.activeMeetingTitle ?? "Recording"
                    self.captureStatus.apply(
                        .meetingPaused(meetingTitle: title, accumulatedSeconds: accumulatedSeconds))
                    // G12 §2: no live capture while paused — settle the meter.
                    self.levelMeterModel = nil
                    self.levelMeter.reset()
                    self.silenceWatchdog.disarm()
                case .resumed(let id, _, _):
                    // G9: the held meeting resumed — back to recording (the
                    // `.started` re-emission applies `.captureStarted`).
                    if self.captureStatus.pausedMeetingID == id {
                        self.captureStatus.pausedMeetingID = nil
                    }
                    self.captureStatus.apply(.meetingResumed)
                }
            }
        }

        // C14: automation tracker events → indicator grace inputs + the
        // denied-mode menu surfaces.
        let automationEvents = await tracker.events()
        automationEventTask = Task { [weak self] in
            for await event in automationEvents {
                guard let self else { return }
                switch event {
                case .graceEntered(let id, let code, let title, let until):
                    // Multiple windows can stand (back-to-back meetings):
                    // the indicator/menu display the soonest-expiring one,
                    // with a count for the rest.
                    self.captureStatus.graceWindows.removeAll { $0.meetingID == id }
                    self.captureStatus.graceWindows.append((id, code, title, until))
                    self.captureStatus.graceWindows.sort { $0.until < $1.until }
                    if let soonest = self.captureStatus.graceWindows.first {
                        self.captureStatus.apply(
                            .graceEntered(meetingTitle: soonest.title, until: soonest.until))
                    }
                case .graceEnded(let id, let reason):
                    self.captureStatus.graceWindows.removeAll { $0.meetingID == id }
                    // Only true EXPIRY (window lapsed / Finalize now / manual
                    // stop) finalizes and processes. A grace→Pause conversion
                    // (.paused) is NOT processing — its paused display is driven
                    // by the controller's `.paused` recording event; applying
                    // `.graceExpired`/processing here would trap it in a false,
                    // unreachable "processing" forever (H-3).
                    if case .expired = reason {
                        self.captureStatus.processingMeetingID = id
                    }
                    if let next = self.captureStatus.graceWindows.first {
                        // Another back-to-back window still stands: it takes
                        // the grace display over.
                        self.captureStatus.apply(
                            .graceEntered(meetingTitle: next.title, until: next.until))
                    } else {
                        switch reason {
                        case .resumed: self.captureStatus.apply(.graceResumed)
                        case .expired: self.captureStatus.apply(.graceExpired)
                        case .paused:
                            // Clear the grace display without forcing expiry;
                            // the `.paused` recording event sets the paused
                            // display (which outranks grace under M-3).
                            self.captureStatus.apply(.graceResumed)
                        }
                    }
                case .actionFailed(let message):
                    self.captureStatus.lastActionError = message
                case .meetingDetected(let code, let title):
                    self.captureStatus.detectedMeeting = (code, title)
                case .meetingDetectionCleared(let code):
                    if self.captureStatus.detectedMeeting?.code == code {
                        self.captureStatus.detectedMeeting = nil
                    }
                case .meetingEndPending(_, let until):
                    self.captureStatus.meetingEndPendingUntil = until
                case .meetingEndPendingCleared:
                    self.captureStatus.meetingEndPendingUntil = nil
                case .nudge(_, let title):
                    self.captureStatus.nudgeMessage =
                        "Recording running — no Meet signals yet — \(title)"
                }
            }
        }
        // Notification plumbing: categories + action routing + the Human
        // Touchpoint authorization prompt (first launch with automation on).
        notificationAdapter.activate()
        notificationAdapter.mirror = captureStatus
        notificationAdapter.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .record(let code):
                await self.tracker.recordActionClicked(code: code)
            case .resume(let meetingID):
                await self.tracker.resumeFromGrace(meetingID: meetingID)
            case .launchRecord(let eventKey, let code, let title, let urlString):
                await self.launchAndRecord(
                    eventKey: eventKey, code: code, title: title, urlString: urlString)
            case .openMainWindow:
                // L-3: surface the queue — open the main window (banner +
                // Settings → handoff panel) and bring Blaise frontmost.
                await MainActor.run {
                    self.uiState.openMainWindowRequest += 1
                    NSApp.activate(ignoringOtherApps: true)
                }
            case .participantConfirm(let meetingID):
                // G15: open Blaise, select the meeting, and raise the confirm
                // sheet itself. The notification is posted at the run-entry ask
                // (§2a), when the meeting has no pending banner yet — routing to
                // the banner alone would be a dead end.
                let meeting = try? await MeetingRepository(database: self.database)
                    .fetch(meetingID)
                let outcome = await MainActor.run {
                    let outcome = Self.routeParticipantConfirmClick(
                        meetingID: meetingID, meeting: meeting, uiState: self.uiState)
                    NSApp.activate(ignoringOtherApps: true)
                    return outcome
                }
                // R4-F3: the standing sheet kept its meeting, so the clicked one
                // needs its surface back — the click consumed the notification.
                if outcome == .deferredToStandingSheet, let meeting {
                    await self.notificationAdapter.postParticipantConfirmation(
                        meetingID: meetingID, title: meeting.title)
                }
            }
        }
        Task { [notificationAdapter, settings, captureStatus] in
            // Screenshot/demo bundles must not create a real notification TCC
            // decision for their throwaway bundle identity.
            if !CommandLine.arguments.contains("--seed-demo"),
                await AutomationSettings.enabled(from: settings)
            {
                await notificationAdapter.requestAuthorization()
            }
            let health = await notificationAdapter.notificationHealth()
            await MainActor.run { captureStatus.notificationHealth = health }
        }
        await googleCalendar.load()
        await calendarSuggestions.load()
        // Handoff persistent-failure warning → Notification Center: the
        // holder fires once per failure episode (never per attempt); clearing
        // withdraws the standing notification silently — no success spam.
        // Wired BEFORE worker.start() so a launch-instant warning (stale
        // queue from a previous run) is not lost.
        handoffStatus.onWarningEpisode = { [notificationAdapter] warning in
            Task { await notificationAdapter.postHandoffWarning(warning) }
        }
        handoffStatus.onWarningCleared = { [notificationAdapter] in
            notificationAdapter.withdrawHandoffWarning()
        }
        // L-2: persist episode bookkeeping so a relaunch with the same ongoing
        // episode does not re-notify or resurrect a dismissed banner. Restore
        // before worker.start() publishes; a new episode after relaunch still
        // notifies (its key differs from the persisted one).
        if let restored = (try? await settings.get(
            HandoffStatusHolder.EpisodeState.settingsKey, as: HandoffStatusHolder.EpisodeState.self))
            ?? nil
        {
            handoffStatus.restore(restored)
        }
        handoffStatus.persistEpisodeState = { [settings] state in
            Task { try? await settings.set(HandoffStatusHolder.EpisodeState.settingsKey, to: state) }
        }
        await tracker.startEvaluationTimer()
        // C15: load Slack settings, arm the huddle evaluation tick, and open
        // the Socket Mode connection if the integration is enabled + connected
        // (the model gates on the BLAISE_SLACK_SOCKET dev-instance policy).
        await slackHuddles.load()
        await slackHuddleTracker.startTicking()
        slackHuddles.startIfEnabled()

        if CommandLine.arguments.contains("--seed-demo") {
            await runSeedCommand()
            applyDemoScene()
        }
        library.start()
        await worker.start()
        await processingQueue.start()  // F1 Inc2: resume sweep + drain any pending
        await listener.start()

        // C11 launch hygiene + recovery: destroy a crashed session's
        // lingering aggregate device (a LIVE session's device is guarded by
        // the engine's live-UID registry), sweep orphan capture CAFs
        // (encode + verify + attach + AUTO-KICK processing — no
        // babysitting; actively-recording meetings are skipped), then
        // re-dispatch interrupted meetings that kept their retained audio
        // (quit-during-recording leaves no CAF for the sweep to key on).
        CaptureSession.cleanupStaleAggregates()
        let startupIdentity = (try? await settings.get(UserIdentity.settingsKey, as: UserIdentity.self))
            ?? nil ?? .shippedDefault
        userEmail = startupIdentity.email
        userName = startupIdentity.name
        // Calendar surfaces refresh OFF the startup critical path: a slow or
        // unreachable Google fetch must not delay paused-meeting restoration,
        // pipeline-event subscription, or the scheduler timer below.
        Task { await refreshCalendarSurfaces() }
        Task { [database, processingQueue, captureStatus] in
            // F1 Inc2: launch recovery ENQUEUES (origin .auto → refuseCancelled),
            // funneling the orphan-CAF sweep + redispatchInterrupted + durable-
            // grace recovery onto one queued job per meeting (the partial unique
            // index dedups → no double-processing).
            let kick: @Sendable (MeetingID) async -> Void = { meetingID in
                await processingQueue.enqueue(meetingID, origin: .auto)
            }
            // G10 §2: the tombstone sweep — removes EXACTLY the tombstoned
            // dirs (durable owner intent, the only file-deletion authority for
            // meeting data besides verified-encode) and then their tombstones.
            // A kill between the delete's erase-commit and its dir removal
            // leaves a tombstone this sweep finishes; a row-less dir WITHOUT a
            // tombstone is NEVER touched (floor 2, the C-1 pin). Runs beside
            // the orphan-CAF sweep, before the kicks so a tombstoned dir is
            // never re-encoded.
            await MeetingDeletion.sweepTombstones(database: database)
            let swept = await CaptureRecovery.sweepOrphanCAFs(database: database, kick: kick)
            await CaptureRecovery.redispatchInterrupted(
                database: database, excluding: Set(swept.map(\.meetingID)), kick: kick)
            // G11 §3 durable-grace recovery: a `recording` row with a non-nil
            // grace_until_ms is a meeting that died mid-grace (the interrupted-
            // flip exemption kept it). Past deadline → process now; future →
            // re-enter grace on the tracker. Runs after the sweeps (which skip
            // `recording` rows), so it owns the exempted in-grace rows.
            let tracker = self.tracker
            await CaptureRecovery.recoverDurableGrace(
                database: database, now: Date(), kick: kick,
                reenterGrace: { row in
                    await tracker.reenterGrace(
                        meetingID: row.meetingID, code: row.code, title: row.title,
                        until: Date(timeIntervalSince1970: Double(row.graceUntilMs) / 1000.0))
                })
            // G9 (M-8): the orphan-CAF sweep has finished — Resume may now open
            // a new live part with no risk of the sweep finalizing its CAF
            // under the live writer. Set on the main actor (the holder is
            // @MainActor @Observable).
            await MainActor.run { captureStatus.launchSweepComplete = true }
        }
        refreshLastMeeting()

        // G9 (H-2): restore a paused meeting across relaunch. A clean
        // quit-and-keep-paused leaves a durable `paused` row; without this the
        // indicator stays idle and Resume / End & process are unreachable —
        // the app would trap the user in a refuse-everything state. Rehydrate
        // the holder so every paused surface (menu, main-window toolbar,
        // indicator) works exactly as in the live flow.
        await restorePausedMeetingIfAny()

        // D17 self-heal triggers: notes-pending meetings re-dispatch through
        // the pipeline's notes-only resume at launch and on network-path
        // restoration (the key-save trigger lives in Settings). A kick with
        // nothing pending — or with the blocking condition still standing —
        // is cheap: the engine refuses before any network call or load.
        Task { [pipeline] in await pipeline.resumePendingNotes() }
        // G14 H1: the digest-only resume self-heals digest-pending meetings from
        // the SAME launch trigger (re-fires generateDigest, never generateNotes).
        Task { [pipeline] in await pipeline.resumePendingDigests() }
        if notesPathMonitor == nil {
            let monitor = NWPathMonitor()
            let pipeline = self.pipeline
            // Fire only on RESTORATION (non-satisfied → satisfied):
            // NWPathMonitor delivers the current path on start (the launch
            // kick above already covers it) and re-fires on every path
            // CHANGE while satisfied (interface/VPN flips) — neither is a
            // restoration. The handler runs on the serial monitor queue.
            let previousStatus = Mutex<NWPath.Status?>(nil)
            monitor.pathUpdateHandler = { path in
                let wasUnsatisfied = previousStatus.withLock { previous in
                    defer { previous = path.status }
                    return previous != nil && previous != .satisfied
                }
                guard path.status == .satisfied, wasUnsatisfied else { return }
                Task { await pipeline.resumePendingNotes() }
                Task { await pipeline.resumePendingDigests() }
            }
            monitor.start(queue: DispatchQueue(label: BlaiseBundle.subsystem("notes.path")))
            notesPathMonitor = monitor
        }

        // Pipeline progress stream → activity holder + ready pulse +
        // indicator processing→idle hand-back.
        let events = await pipeline.events()
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                if let readyID = self.activity.apply(event) {
                    self.library.markReady(readyID)
                }
                switch event {
                case .runCompleted(let id), .runFailed(let id, _, _):
                    if self.captureStatus.processingMeetingID == id {
                        self.captureStatus.processingMeetingID = nil
                        self.captureStatus.apply(.processingFinished)
                        self.refreshLastMeeting()
                    }
                case .participantConfirmationNeeded(let id, let title):
                    // G15: the gate parked this meeting for the FIRST time — post
                    // the confirm notification once (the pipeline emits this event
                    // once per park, never per resume re-park).
                    let adapter = self.notificationAdapter
                    Task { await adapter.postParticipantConfirmation(meetingID: id, title: title) }
                case .participantAskRaised(let id, let title):
                    // G15 §2a: the run just started and nobody is named yet —
                    // raise the question now.
                    Task { await self.raiseParticipantAsk(meetingID: id, title: title) }
                default:
                    break
                }
            }
        }

        // Pending-batch purge: startup + a daily timer (contract).
        purgeTask = Task { [ingestor] in
            while !Task.isCancelled {
                _ = try? await ingestor.purgeStalePending()
                try? await Task.sleep(for: .seconds(24 * 3600))
            }
        }

        // Launch retry for a selected-but-unprepared engine (pinned UX).
        Task { [engineSettings] in
            await engineSettings.prepareSelectedEnginesAtLaunch()
        }

        // C14 calendar pre-meeting scheduler: rolling 24 h snapshot refresh
        // every 5 min + EKEventStoreChanged, evaluation every 30 s. Armed
        // ONLY when EventKit access is already granted (no new prompt path).
        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshSchedulerSnapshots()
            }
        }
        schedulerTask = Task { [weak self] in
            var beat = 0
            while !Task.isCancelled {
                if beat % 10 == 0 {  // every 5 min
                    await self?.refreshSchedulerSnapshots()
                } else {
                    guard let scheduler = self?.scheduler else { return }
                    await scheduler.evaluate()
                }
                beat += 1
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func refreshSchedulerSnapshots() async {
        let now = Date()
        let snapshots = await calendarSuggestions.eventSnapshots(
            from: now.addingTimeInterval(-PreMeetingScheduler.validitySeconds),
            to: now.addingTimeInterval(24 * 3600))
        await scheduler.update(snapshots: snapshots)
        await refreshCalendarSurfaces(now: now)
    }

    func refreshCalendarSurfaces(now: Date = Date()) async {
        await calendarSuggestions.refresh(
            userEmail: userEmail, recordedCodes: recordedMeetingCodes(), now: now)
    }

    /// A calendar source/visibility change (Apple or Google enable, or a
    /// per-calendar hide/show): re-fetch the FILTERED snapshots into the 24h
    /// scheduler too — so a now-hidden or disabled calendar's pending Launch &
    /// Record notifications are withdrawn — not just the suggestion / upcoming
    /// surfaces. Use this (not `refreshCalendarSurfaces`) from Settings actions.
    func calendarSourcesChanged() async {
        await refreshSchedulerSnapshots()
    }

    private func recordedMeetingCodes() -> Set<String> {
        (try? database.pool.read { db in
            try Set(String.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT meeting_code FROM meeting
                    WHERE meeting_code IS NOT NULL
                      AND status IN ('recording', 'processing', 'ready', 'failed', 'paused')
                    """))
        }) ?? []
    }

    // MARK: - Recording actions (menu bar + ⌥⌘R command)

    func startRecording(
        source: MeetingSource, title: String? = nil, meetingCode: String? = nil,
        attendees: [Attendee] = [], anchor: CalendarAnchor? = nil
    ) async {
        // G11 §4 (v3.2): a quick-start carrying no suggestion anchor still binds
        // to a covering calendar event when one is in progress — the late-join /
        // undetected-Zoom fix. Without this the anchor only ever reached a start
        // via a surfaced suggestion (±15 min of the event START), so a meeting
        // joined mid-way got no `scheduled_end_ms` and the §2 classifier could
        // never Rule-1 it. The supplied anchor (a surfaced suggestion) always
        // wins — §1 "written once at start when matched", no retroactive rebind.
        let resolvedAnchor: CalendarAnchor?
        if let anchor {
            resolvedAnchor = anchor
        } else {
            resolvedAnchor = await coveringCalendarAnchor(code: meetingCode)
        }
        do {
            let meeting = try await recordingController.start(
                source: source, title: title, meetingCode: meetingCode, attendees: attendees,
                anchor: resolvedAnchor)
            captureStatus.activeMeetingTitle = meeting.title
            captureStatus.lastActionError = nil
        } catch {
            logger.error("start recording failed: \(error)")
            captureStatus.lastActionError = "Could not start recording: \(error)"
        }
    }

    /// Manual "Slack" start from the menu bar. When the huddle tracker knows a
    /// live call (Slack connected + self in a huddle), the recording binds to
    /// its meeting code, so the roster stream and auto-stop attach exactly as
    /// on the notification path. Disconnected or no huddle → a plain
    /// slack-source recording (nil code; the ingestor never attaches batches
    /// to nil-code sessions, by design).
    func startSlackRecording() async {
        let code = await slackHuddleTracker.currentMeetingCode()
        await startRecording(source: .slack, meetingCode: code)
    }

    func startRecording(suggestion: MeetingSuggestion) async {
        // G11 §1: a suggestion-matched start persists the calendar anchor.
        await startRecording(
            source: suggestion.source, title: suggestion.title,
            meetingCode: suggestion.meetingCode, attendees: suggestion.attendees,
            anchor: CalendarAnchor(suggestion: suggestion))
    }

    func startRecording(upcoming row: UpcomingMeetingRow) async {
        await startRecording(
            source: row.source, title: row.title,
            meetingCode: row.meetingCode, attendees: row.attendees,
            anchor: row.anchor)
        await refreshCalendarSurfaces()
    }

    /// G11 §4 (v3.2): the calendar anchor for a quick-start with no surfaced
    /// suggestion — the late-join / undetected-Zoom anchor source. Reads the
    /// EventKit snapshots over the bind window [now − 15 min, now + buffer] and
    /// anchors to a covering event (`quickStartAnchor`). nil when access is
    /// not granted or no event covers now (the start stays ad-hoc → §1 columns
    /// NULL). EventKit reads only; never prompts (the prompt is its own opt-in).
    private func coveringCalendarAnchor(code: String?) async -> CalendarAnchor? {
        let now = Date()
        // The fetch must span any event that could COVER now: it can have
        // started up to its full duration ago, so reach back generously and
        // forward past the bind lead; quickStartAnchor enforces actual coverage.
        let snapshots = await calendarSuggestions.eventSnapshots(
            from: now.addingTimeInterval(-12 * 3600),
            to: now.addingTimeInterval(CalendarSuggestionBuilder.bindLeadSeconds))
        return CalendarSuggestionBuilder.quickStartAnchor(for: now, code: code, in: snapshots)
    }

    func stopRecording() async {
        do {
            _ = try await recordingController.stop()
            captureStatus.lastActionError = nil
        } catch {
            logger.error("stop recording failed: \(error)")
            captureStatus.lastActionError = "Could not stop recording: \(error)"
        }
    }

    // MARK: - G9 pause / resume / end (menu + main-window three-state model)

    /// G9 (H-2): rehydrate a paused meeting at launch. Reads the durable
    /// `paused` row (single-open-meeting invariant — at most one) and drives
    /// the holder into its paused rendering: the indicator shows the
    /// accumulated recorded time with "paused", and the menu + main-window
    /// expose Resume / End & process. Resume is still GATED on launch-sweep
    /// completion (M-8) — the control stays disabled until the detached sweep
    /// reports done. No-op when nothing is paused.
    func restorePausedMeetingIfAny() async {
        guard let restored = await recordingController.restorablePausedMeeting() else { return }
        captureStatus.pausedMeetingID = restored.meeting.id
        captureStatus.activeMeetingTitle = restored.meeting.title
        captureStatus.apply(
            .meetingPaused(
                meetingTitle: restored.meeting.title,
                accumulatedSeconds: restored.accumulatedSeconds))
    }

    /// Pause the live recording (finalize the current part, hold the meeting
    /// open). The `.paused` controller event drives the indicator. Returns the
    /// paused meeting on success, or nil if the pause threw / no-op'd (e.g. a
    /// stop already began) — the silence watchdog uses this to know whether to
    /// disarm or re-arm.
    @discardableResult
    func pauseRecording() async -> Meeting? {
        do {
            let meeting = try await recordingController.pause()
            captureStatus.lastActionError = nil
            return meeting
        } catch {
            logger.error("pause recording failed: \(error)")
            captureStatus.lastActionError = "Could not pause recording: \(error)"
            return nil
        }
    }

    /// Resume the held-open paused meeting (open a new part, back to
    /// recording). Refused if a live session exists or any OTHER meeting is
    /// paused (the controller's universal predicate). GATED on launch-sweep
    /// completion (M-8): the control is disabled until the detached orphan-CAF
    /// sweep reports done, so a live new-part CAF can never race the sweep's
    /// zero-frame unlink. The guard here is the backstop for the disabled
    /// control.
    func resumePausedRecording() async {
        guard let meetingID = captureStatus.pausedMeetingID else { return }
        guard captureStatus.launchSweepComplete else {
            captureStatus.lastActionError =
                "Resume is preparing (finishing crash-recovery checks) — try again in a moment"
            return
        }
        do {
            _ = try await recordingController.resumePaused(meetingID: meetingID)
            captureStatus.lastActionError = nil
        } catch {
            logger.error("resume paused recording failed: \(error)")
            captureStatus.lastActionError = "Could not resume recording: \(error)"
        }
    }

    /// G9 (M-8): whether the Resume control should be enabled (launch sweep
    /// done). The UI disables the Resume button until this is true.
    var canResumePaused: Bool { captureStatus.launchSweepComplete }

    /// End & process the held-open paused meeting (flip paused→processing,
    /// finalize over existing parts — no new part).
    func endPausedRecording() async {
        guard let meetingID = captureStatus.pausedMeetingID else { return }
        do {
            let result = try await recordingController.endPaused(meetingID: meetingID)
            captureStatus.pausedMeetingID = nil
            captureStatus.lastActionError = nil
            // L-j: endPaused no-ops if a resume won the race (the row is back
            // to `recording`, not `processing`). Only apply the processing
            // display when the End actually flipped the row — otherwise the
            // `.captureStarted` from the winning resume owns the display and a
            // transient false "processing" is avoided.
            if result.status == .processing {
                captureStatus.processingMeetingID = meetingID
                captureStatus.apply(.meetingEnded)
            }
        } catch {
            logger.error("end paused recording failed: \(error)")
            captureStatus.lastActionError = "Could not end paused recording: \(error)"
        }
    }

    /// "Retry now" (warning banner + menu): re-enters failed deliveries and
    /// external-wakes the worker — backoff floors and host benches clear, so
    /// the queue is attempted immediately (no more relaunch-to-retry).
    func retryHandoffNow() async {
        await worker.retryNow()
    }

    // MARK: - G10 cancel + delete (detail / library actions)

    /// G10 §1: cancel the in-flight run for `meetingID`. No-op if nothing is
    /// running for it (idleness-keyed). The pipeline does the class-aware
    /// status write; this wrapper just surfaces failures via the banner.
    func cancelProcessing(meetingID: MeetingID) async {
        _ = await pipeline.cancel(meetingID: meetingID)
    }

    /// G10 §2: delete a meeting (tombstone-disciplined, single-flight). A
    /// `paused` meeting deletes directly — its parts close unprocessed and
    /// G10 owns the cleanup: the shared paused teardown (tracker manualControl
    /// + paused-class suppression) PLUS the holder mirror (`pausedMeetingID`
    /// and the indicator window), or the G9 refuse-everything predicate
    /// outlives the deleted row and traps the user until relaunch (G9 M-9).
    /// Refuses a `recording` meeting (the pipeline throws). The detail pane
    /// dismisses if its meeting was the one deleted.
    func deleteMeeting(meetingID: MeetingID) async {
        // Capture the paused linkage BEFORE the row is erased (the teardown
        // and holder-clear need the meeting code; the row is gone after).
        let meeting = try? await MeetingRepository(database: database).fetch(meetingID)
        let wasPaused = meeting?.status == .paused
        do {
            try await pipeline.deleteMeeting(meetingID: meetingID)
        } catch {
            logger.error("delete meeting failed: \(error)")
            uiState.lastActionError = "Could not delete the meeting: \(error)"
            return
        }
        if wasPaused {
            await recordingController.clearPausedTeardownForDelete(
                meetingID: meetingID, meetingCode: meeting?.meetingCode)
            // Clear the holder mirror synchronously at the delete commit
            // (mirroring how the End / resumeLostRace teardown drives it).
            if captureStatus.pausedMeetingID == meetingID {
                captureStatus.pausedMeetingID = nil
                captureStatus.apply(.meetingEnded)
            }
        }
        // Detail-pane dismissal: the deleted meeting can no longer be selected.
        if uiState.selectedMeetingID == meetingID {
            uiState.selectedMeetingID = nil
        }
        uiState.lastActionError = nil
    }

    /// G10 §2: "Cancel & Delete" — set the cancel token FIRST (class-aware,
    /// exactly as §1), then run the delete on the chain after the cancelled run
    /// winds down at its next checkpoint/attempt boundary. The token-first
    /// order means the in-flight run never runs to completion before the
    /// delete; the delete's own chain slot serializes behind the run's exit.
    func cancelAndDelete(meetingID: MeetingID) async {
        _ = await pipeline.cancel(meetingID: meetingID)
        await deleteMeeting(meetingID: meetingID)
    }

    // MARK: - C14 automation actions (menu + notification routes)

    func resumeFromGrace() async {
        await tracker.resumeFromGrace()
    }

    /// M-1: Pause the meeting currently in its grace window (the menu's grace-
    /// section Pause control) — converts grace→paused. Refused (no-op) if a
    /// live session exists or another meeting is already paused (the universal
    /// single-open-meeting predicate, enforced in the tracker).
    func pauseGraceMeeting() async {
        await tracker.pauseGrace()
    }

    func finalizeGraceNow() async {
        await tracker.finalizeGraceNow()
    }

    func recordDetectedMeeting(code: String) async {
        await tracker.recordActionClicked(code: code)
    }

    /// Hide the standing in-app offer without changing the tracker's per-call
    /// suppression record. Later heartbeats from this same call therefore do
    /// not nag again; call-ended still clears the mirror idempotently.
    func dismissDetectedMeeting(code: String) async {
        await notificationAdapter.withdrawMeetStart(code: code)
        if captureStatus.detectedMeeting?.code == code {
            captureStatus.detectedMeeting = nil
        }
    }

    func dismissCalendarReminder(eventKey: String) async {
        await notificationAdapter.withdrawCalendarUpcoming(eventKey: eventKey)
    }

    /// Re-read System Settings whenever the menu opens. Notification settings
    /// can change while Blaise is running, and `add` success alone cannot tell
    /// us whether macOS is configured to present a banner.
    func refreshAutomationSurfaceStatus() async {
        let health = await notificationAdapter.notificationHealth()
        captureStatus.notificationHealth = health
    }

    func sendNotificationTest() async {
        await notificationAdapter.postDiagnosticsTest()
        await refreshAutomationSurfaceStatus()
    }

    // MARK: - G15 participant confirmation (sheet backing)

    /// G15 §2a: the pipeline raised the ask at its run entry (the earliest
    /// point where "Blaise has no attendees" is a true statement — the Meet /
    /// Slack roster absorbs there). Surface it: the sheet if Blaise is frontmost
    /// (the user just pressed Stop, they are right here), otherwise the
    /// `participantConfirm` notification. Processing continues either way;
    /// answering before the run reaches its notes stage means it never parks.
    /// The pipeline records the ask, so a later park does not notify twice.
    func raiseParticipantAsk(meetingID: MeetingID, title: String) async {
        switch Self.participantAskSurface(
            appIsActive: NSApp.isActive, sheetPresenting: uiState.participantConfirmMeeting?.id)
        {
        case .sheet:
            let meeting = try? await MeetingRepository(database: database).fetch(meetingID)
            guard let meeting else { return }
            uiState.participantConfirmMeeting = meeting
            uiState.openMainWindowRequest += 1
        case .notification:
            await notificationAdapter.postParticipantConfirmation(
                meetingID: meetingID, title: title)
        }
    }

    /// The two designed surfaces for a run-entry ask (G15 §2a).
    enum ParticipantAskSurface: Equatable {
        case sheet
        case notification
    }

    /// Which surface this ask may use. Blaise frontmost ⇒ the sheet, EXCEPT
    /// while a confirm sheet is already presented: a second ask must never
    /// overwrite the meeting the standing sheet is answering (R3-F4). The
    /// presented sheet captured its subject at init, so overwriting the state
    /// leaves the first sheet answering the first meeting and loses the second
    /// question entirely — through both of its surfaces, since the pipeline
    /// latch already counts it as asked. The notification is the designed
    /// surface for "the sheet cannot be shown now"; it survives, and the user
    /// reaches the second meeting from it.
    static func participantAskSurface(
        appIsActive: Bool, sheetPresenting: MeetingID?
    ) -> ParticipantAskSurface {
        appIsActive && sheetPresenting == nil ? .sheet : .notification
    }

    /// What a `participantConfirm` notification CLICK did with the shared sheet
    /// state (R4-F3).
    enum ParticipantClickOutcome: Equatable {
        /// The clicked meeting is now the sheet's subject.
        case presented
        /// A DIFFERENT meeting's sheet was standing: it kept it, and the caller
        /// owes the clicked meeting its notification back.
        case deferredToStandingSheet
    }

    /// Routes a `participantConfirm` notification click under the SAME
    /// presented-sheet rule as `participantAskSurface` (R4-F3). Installing the
    /// clicked meeting over a standing sheet is exactly the overwrite that rule
    /// exists to prevent: the presented sheet captured its own meeting at init,
    /// so the write retargets nothing the user can see, and answering the
    /// standing sheet then clears the clicked meeting's state — losing the
    /// question through both of its surfaces. Deferring keeps the meeting
    /// selected (its row and the parked banner are entry points) and tells the
    /// caller to re-post the notification the click just consumed.
    @MainActor
    static func routeParticipantConfirmClick(
        meetingID: MeetingID, meeting: Meeting?, uiState: AppUIState
    ) -> ParticipantClickOutcome {
        uiState.selectedMeetingID = meetingID
        uiState.openMainWindowRequest += 1
        let standing = uiState.participantConfirmMeeting
        if let standing, standing.id != meetingID { return .deferredToStandingSheet }
        uiState.participantConfirmMeeting = meeting
        return .presented
    }

    /// Confirm-sheet pre-fill names (§3), in the spec's order: calendar
    /// suggestions for the meeting's time window (attendees of the event the
    /// start binds to), then grounded person-hint canonicals. Folded-deduped,
    /// order-preserving. Empty when neither source has anything.
    func participantPrefillNames(for meeting: Meeting) async -> [String] {
        var names: [String] = []
        // Calendar suggestions for the meeting's own time window.
        let windowEnd = meeting.endedAt ?? meeting.startedAt
        let snapshots = await calendarSuggestions.eventSnapshots(
            from: meeting.startedAt.addingTimeInterval(-CalendarSuggestionBuilder.bindLeadSeconds),
            to: windowEnd.addingTimeInterval(CalendarSuggestionBuilder.bindLeadSeconds))
        if let event = CalendarSuggestionBuilder.bindingEvent(
            for: meeting.startedAt, code: meeting.meetingCode, in: snapshots)
        {
            let userEmailFolded = userEmail.lowercased()
            for attendee in event.attendees
            where userEmailFolded.isEmpty || (attendee.email ?? "").lowercased() != userEmailFolded {
                names.append(attendee.name)
            }
        }
        // Grounded person hints (curated glossary names heard in this meeting).
        names.append(contentsOf: await pipeline.groundedPersonNames(meetingID: meeting.id))
        // Fold-dedup, order-preserving (surface preserved), empties dropped.
        return ProcessingPipeline.foldedDedupedAttendees(names).map(\.name)
    }

    /// Whether this meeting's notes are already written — the state in which a
    /// confirm/skip answer is moot (G15 §3 refuses it, and the auto-skip that
    /// minted them already took the answer's place). The sheet reads it to tell
    /// a refusal that can never succeed from one worth retrying (R3-F3).
    func meetingHasNotes(_ meetingID: MeetingID) async -> Bool {
        ((try? await NotesRepository(database: database).fetch(meetingID: meetingID)) ?? nil) != nil
    }

    /// Confirm-sheet caption count (§3): "Blaise heard N distinct voices".
    func participantVoiceCount(for meetingID: MeetingID) async -> Int {
        await pipeline.diarizationClusterCount(meetingID: meetingID)
    }

    /// Confirm (§3): write the confirmed attendee names and dispatch the
    /// gate-bypassing notes-only resume. Returns whether it actually happened;
    /// the notification is withdrawn ONLY on success, so a failure leaves every
    /// recovery surface in place instead of looking like it worked.
    @discardableResult
    func confirmParticipants(meetingID: MeetingID, names: [String]) async -> Bool {
        let confirmed =
            (try? await pipeline.confirmParticipants(meetingID: meetingID, names: names)) ?? false
        if confirmed { notificationAdapter.withdrawParticipantConfirmation(meetingID: meetingID) }
        return confirmed
    }

    /// Skip (§3): proceed without attendees. "Don't ask again" flips the
    /// preference off first. Same success contract as `confirmParticipants`.
    @discardableResult
    func skipParticipantConfirmation(meetingID: MeetingID, dontAskAgain: Bool) async -> Bool {
        if dontAskAgain {
            try? await settings.set(AutomationSettings.confirmParticipantsKey, to: false)
        }
        let skipped =
            (try? await pipeline.skipParticipantConfirmation(meetingID: meetingID)) ?? false
        if skipped { notificationAdapter.withdrawParticipantConfirmation(meetingID: meetingID) }
        return skipped
    }

    /// The calendar Launch & Record action: open the Meet link in Google
    /// Chrome (NEVER the default browser — the extension lives in Chrome),
    /// then start a correlated recording with the event's title/attendees.
    /// Chrome missing or failing to launch → a "Couldn't open Google
    /// Chrome" notification and NO recording start.
    func launchAndRecord(eventKey: String, code: String, title: String, urlString: String) async {
        await notificationAdapter.withdrawCalendarUpcoming(eventKey: eventKey)
        if let session = await recordingController.currentSession(), session.meetingCode == code {
            // Same-code no-op: both notifications can legitimately coexist
            // for one meeting; the second click inside the withdrawal race
            // must not split the meeting.
            return
        }
        guard
            let chrome = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.google.Chrome"),
            let url = URL(string: urlString)
        else {
            await notificationAdapter.postChromeLaunchFailure(title: title)
            return
        }
        do {
            _ = try await NSWorkspace.shared.open(
                [url], withApplicationAt: chrome, configuration: NSWorkspace.OpenConfiguration())
        } catch {
            logger.error("Chrome launch failed: \(error)")
            await notificationAdapter.postChromeLaunchFailure(title: title)
            return
        }
        // Attendees from the matching current suggestion (user excluded as
        // today); the extension's first batch correlates live via the code.
        await refreshCalendarSurfaces()
        let row = calendarSuggestions.upcomingRows.first {
            $0.id == eventKey || $0.meetingCode == code
        }
        let suggestion = calendarSuggestions.suggestions.first { $0.meetingCode == code }
        await tracker.startCorrelated(
            code: code, title: title,
            attendees: row?.attendees ?? suggestion?.attendees ?? [],
            anchor: row?.anchor ?? suggestion.flatMap(CalendarAnchor.init(suggestion:)))
        await refreshCalendarSurfaces()
    }

    func launchAndRecord(upcoming row: UpcomingMeetingRow) async {
        guard let code = row.meetingCode, let urlString = row.urlString else {
            await startRecording(upcoming: row)
            return
        }
        await launchAndRecord(eventKey: row.id, code: code, title: row.title, urlString: urlString)
    }

    /// ⌥⌘R: toggle. Not recording → quick-start (Meet, clipboard code if
    /// present). Start is allowed while the previous meeting is still
    /// processing (back-to-back meetings) and from the alarm state — only a
    /// live session blocks it (the controller enforces that too).
    func toggleRecording() async {
        if captureStatus.isRecording {
            await stopRecording()
        } else {
            let clipboardCode = NSPasteboard.general.string(forType: .string)
                .flatMap { MeetLinkParser.meetingCode(from: $0) }
            await startRecording(source: .meet, meetingCode: clipboardCode)
        }
    }

    /// Long-session warning tick (> 6 h; indicator only — recording
    /// continues).
    private func startLongSessionTicker() {
        tickerTask?.cancel()
        tickerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, self.captureStatus.isRecording else { return }
                self.captureStatus.apply(.tick(now: Date()))
            }
        }
    }

    /// G3: after onboarding writes a fresh identity, re-read the email used
    /// for calendar attendee self-exclusion and reload suggestions so the new
    /// identity takes effect without a relaunch.
    func applyOnboardedIdentity() {
        Task {
            let identity =
                (try? await settings.get(UserIdentity.settingsKey, as: UserIdentity.self))
                ?? nil ?? .shippedDefault
            await MainActor.run {
                userEmail = identity.email
                userName = identity.name
            }
            await refreshCalendarSurfaces()
        }
    }

    private func refreshLastMeeting() {
        let last = try? database.pool.read { db -> (MeetingID, String)? in
            guard
                let id = try String.fetchOne(
                    db, sql: "SELECT id FROM meeting ORDER BY started_at DESC, id DESC LIMIT 1"),
                let title = try String.fetchOne(
                    db, sql: "SELECT title FROM meeting WHERE id = ?", arguments: [id])
            else { return nil }
            return (id, title)
        }
        if let last = last ?? nil {
            captureStatus.lastMeeting = (id: last.0, title: last.1)
        }
    }

    private func runSeedCommand() async {
        do {
            let hasMeetings = try await database.pool.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meeting") ?? 0
            }
            guard hasMeetings == 0 else {
                logger.notice("--seed-demo: data root already has meetings; skipping")
                return
            }
            // G3: the demo carries an EXPLICIT identity so screenshots never
            // surface the onboarding sheet (and the seeded notes render with
            // the demo user's name). A fictional demo user, matching the
            // DemoSeeder universe.
            try await settings.set(
                UserIdentity.settingsKey,
                to: UserIdentity(
                    name: "Demo User", aliases: ["Demo"], email: "demo@example.com"))
            let summary = try await DemoSeeder.seed(database: database)
            logger.notice(
                "--seed-demo: seeded \(summary.meetingCount) meetings (\(summary.segmentCount) segments)")
        } catch {
            logger.error("--seed-demo failed: \(error)")
        }
    }

    /// Screenshot-evidence scaffolding, active only under `--seed-demo`:
    /// `BLAISE_DEMO_SCENE=detail|search` preselects the seeded pinned
    /// meeting / pre-fills a known sample search term.
    private func applyDemoScene() {
        switch ProcessInfo.processInfo.environment["BLAISE_DEMO_SCENE"] {
        case "library":
            // Most recent meeting selected — the populated three-pane shot.
            uiState.selectedMeetingID = try? database.pool.read { db in
                try String.fetchOne(
                    db, sql: "SELECT id FROM meeting ORDER BY started_at DESC, id DESC LIMIT 1")
            }
            uiState.selectedMeetingID.map(seedDemoAudio)
        case "detail":
            uiState.selectedMeetingID = mostRecentMeetingID()
        case "notes":
            // PROPOSALS_V2 beauty shot: a seeded PT meeting with user-action
            // items, one pre-marked done (shows the completion states).
            let meetingID = try? database.pool.read { db in
                try String.fetchOne(
                    db, sql: "SELECT id FROM meeting WHERE title LIKE ? LIMIT 1",
                    arguments: ["Reunião de heads%"])
            }
            uiState.selectedMeetingID = meetingID
            if let meetingID {
                seedDemoAudio(for: meetingID)
                let database = database
                Task {
                    try? await ActionItemStateRepository(database: database).markDone(
                        meetingID: meetingID,
                        itemText: "Dar retorno à Julia Castro sobre a faixa salarial do tech lead MR.")
                }
            }
        case "search":
            uiState.selectedMeetingID = mostRecentMeetingID()
            uiState.searchText = "roadmap"
        case "recording":
            // PROPOSALS_V3 shot: most recent meeting open, the demo
            // recording live (indicator mirror only — no capture session):
            // toolbar chip in its recording state, fluido mesh warmed.
            uiState.selectedMeetingID = mostRecentMeetingID()
            uiState.selectedMeetingID.map(seedDemoAudio)
            captureStatus.activeMeetingTitle = "Demo recording"
            captureStatus.apply(.captureStarted(at: Date().addingTimeInterval(-127)))
            // Display-only fixture so the isolated screenshot scene exercises
            // the perceptual mapping without opening an audio capture device.
            levelMeter.levels = MeterLevels(
                you: ChannelLevel(level: 0.08),
                others: ChannelLevel(level: 0.025))
        case "paused":
            // G9 shot: the three-state model in its PAUSED rendering
            // (indicator mirror only — no capture session): toolbar shows
            // Resume + End & Process, the chip shows the accumulated recorded
            // time with "paused", the calm accent pause glyph.
            uiState.selectedMeetingID = mostRecentMeetingID()
            uiState.selectedMeetingID.map(seedDemoAudio)
            captureStatus.activeMeetingTitle = "Demo recording"
            captureStatus.pausedMeetingID = mostRecentMeetingID()
            captureStatus.launchSweepComplete = true  // sweep done → Resume enabled
            captureStatus.apply(
                .meetingPaused(meetingTitle: "Demo recording", accumulatedSeconds: 127))
        case "automationmenu":
            // Isolated visual-smoke scene for the menu's load-bearing
            // notification fallback. No tracker input, listener bind, capture,
            // or external delivery: UI mirror state only.
            captureStatus.detectedMeeting = (
                code: "abc-defg-hij", title: "Weekly product review")
            captureStatus.notificationHealth = .alertsDisabled
            captureStatus.lastNotificationReceipt = AutomationNotificationReceipt(
                title: "Meeting in progress",
                submittedAt: Date().addingTimeInterval(-45),
                acceptedBySystem: true)
        case "motion":
            // PROPOSALS_V3 screen recording: a timed self-driving tour —
            // select (settle), demo-record (mesh warm), stop, open the PT
            // meeting, complete both user items (spray, then the last-item
            // sparkle burst). Demo data root only.
            runMotionTour()
        case "handoffwarning":
            // Smoke/screenshot scaffolding for the persistent-failure
            // surfaces: a FAKE warning snapshot published straight to the UI
            // holder (mirror only — no queue rows, no transport; the demo
            // root's empty queue means the real worker idles). Delayed past
            // worker.start()'s initial idle publish.
            uiState.selectedMeetingID = mostRecentMeetingID()
            let holder = handoffStatus
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                holder.publish(
                    HandoffSnapshot(
                        state: .authFailure, activeEndpoint: nil, pendingCount: 2,
                        currentItem: nil, damagedItems: [],
                        detail: "auth: exit=255 Permission denied (publickey).",
                        warning: HandoffWarning(
                            since: Date().addingTimeInterval(-3 * 3600),
                            meetingsWaiting: 2,
                            shortReason: "SSH key rejected",
                            episodeKey: "auth|2")))
            }
        case "windowrouting":
            // Verification scaffolding for round-2 M-2: prove a
            // notification-click reopens a CLOSED main window. Self-driving:
            // (1) close the main window, (2) drive the SAME seam the
            // notification action drives (`openMainWindowRequest += 1`) — which
            // the always-alive MenuBarExtra observer must turn into a fresh
            // `openWindow(id:"main")`. A screenshot after step 2 shows the
            // window back. Demo data root only.
            uiState.selectedMeetingID = mostRecentMeetingID()
            uiState.selectedMeetingID.map(seedDemoAudio)
            let routedState = uiState
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                // Close every visible content window — the menu-bar-recorder
                // state where the WindowGroup's own observer is torn down.
                for window in NSApp.windows where window.isVisible && window.frame.width > 600 {
                    window.close()
                }
                try? await Task.sleep(for: .seconds(2))
                // The notification-action seam (AppEnvironment onAction
                // .openMainWindow does exactly this).
                routedState.openMainWindowRequest += 1
                NSApp.activate(ignoringOtherApps: true)
            }
        case "designswitch":
            // Verification scaffolding for the View ▸ Design live switch:
            // flips the selection through the SAME setter the menu uses, so
            // a before/after capture proves the re-root render path.
            uiState.selectedMeetingID = mostRecentMeetingID()
            uiState.selectedMeetingID.map(seedDemoAudio)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(6))
                DesignSelection.shared.direction = .caderno
            }
        default:
            break
        }
    }

    private func mostRecentMeetingID() -> MeetingID? {
        try? database.pool.read { db in
            try String.fetchOne(
                db, sql: "SELECT id FROM meeting ORDER BY started_at DESC, id DESC LIMIT 1")
        }
    }

    /// The v3 motion-capture tour (active only under --seed-demo).
    private func runMotionTour() {
        let recentID = mostRecentMeetingID()
        let ptMeetingID = try? database.pool.read { db in
            try String.fetchOne(
                db, sql: "SELECT id FROM meeting WHERE title LIKE ? LIMIT 1",
                arguments: ["Reunião de heads%"])
        }
        recentID.map(seedDemoAudio)
        ptMeetingID.map { seedDemoAudio(for: $0) }
        let status = captureStatus
        let uiState = uiState
        let database = database
        Task { @MainActor in
            // 1) Hero morph: list → most recent meeting.
            try? await Task.sleep(for: .seconds(4))
            uiState.selectedMeetingID = recentID
            // 2) Demo recording: chip flips to Recording, mesh warms.
            try? await Task.sleep(for: .seconds(3))
            status.activeMeetingTitle = "Demo recording"
            status.apply(.captureStarted(at: Date()))
            // 3) Stop: back to idle, mesh cools.
            try? await Task.sleep(for: .seconds(6))
            status.apply(.captureStopping)
            status.apply(.captureStopped(alarm: nil))
            status.apply(.processingFinished)
            // 4) Hero morph again: the PT meeting with user action items.
            try? await Task.sleep(for: .seconds(2.5))
            uiState.selectedMeetingID = ptMeetingID
            // 5) Complete the first user item (spray + spring settle).
            try? await Task.sleep(for: .seconds(3.5))
            guard let ptMeetingID else { return }
            let repo = ActionItemStateRepository(database: database)
            try? await repo.markDone(
                meetingID: ptMeetingID,
                itemText: "Revisar a proposta de headcount do Daniel Nunes antes de quinta.")
            // 6) Complete the LAST item — the earned sparkle burst.
            try? await Task.sleep(for: .seconds(3.5))
            try? await repo.markDone(
                meetingID: ptMeetingID,
                itemText: "Dar retorno à Julia Castro sobre a faixa salarial do tech lead MR.")
        }
    }

    /// Demo-scene scaffolding (throwaway data root only): a silent m4a at
    /// the meeting's audio path so the player transport renders in
    /// screenshots — the seeder writes no audio for mock meetings.
    private func seedDemoAudio(for meetingID: MeetingID) {
        let url = database.paths.audioURL(meetingID)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100.0,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32000,
            ]
            let file = try AVAudioFile(forWriting: url, settings: settings)
            guard
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat, frameCapacity: 44100)
            else { return }
            buffer.frameLength = 44100  // one second of silence per write
            for _ in 0..<63 { try file.write(from: buffer) }
        } catch {
            logger.error("--seed-demo: demo audio seed failed: \(error)")
        }
    }

    // MARK: - Engine registry (B-8: implement + construct + register)

    static func buildRegistry(
        database: BlaiseDatabase, dataRoot: URL, settings: SettingsStore,
        secrets: any SecretStore, ledger: CloudSpendLedger
    ) -> EngineRegistry {
        guard
            let driverScript = MLXWhisperEngine.bundledDriverScript(),
            let notesDriverScript = MLXSummarizationEngine.bundledDriverScript(),
            let requirementsFile = MLXWhisperEngine.bundledRequirementsFile()
        else {
            // Bundle resources missing — impossible in a built app; an empty
            // registry keeps the UI alive enough to show the problem.
            return try! EngineRegistry(asr: [], summarization: [])
        }

        func configuration(for engineID: String, descriptors: [EngineConfigDescriptor]) -> EngineConfiguration {
            EngineConfiguration(
                engineID: engineID, descriptors: descriptors, settings: settings, secrets: secrets)
        }

        let uvBinary = (Bundle.main.resourceURL ?? dataRoot).appendingPathComponent("uv")
        let whisper = MLXWhisperEngine(
            configuration: configuration(
                for: MLXWhisperEngine.engineID, descriptors: MLXWhisperEngine.descriptors),
            dataRoot: dataRoot,
            uvBinary: uvBinary,
            driverScript: driverScript,
            requirementsFile: requirementsFile)
        let parakeet = FluidAudioParakeetEngine(
            configuration: configuration(
                for: FluidAudioParakeetEngine.engineID, descriptors: FluidAudioParakeetEngine.descriptors),
            dataRoot: dataRoot)
        let gemma = MLXSummarizationEngine(
            configuration: configuration(
                for: MLXSummarizationEngine.engineID, descriptors: MLXSummarizationEngine.descriptors),
            dataRoot: dataRoot,
            uvBinary: uvBinary,
            driverScript: notesDriverScript,
            requirementsFile: requirementsFile)
        let claude = ClaudeSummarizationEngine(
            configuration: configuration(
                for: ClaudeSummarizationEngine.engineID, descriptors: ClaudeSummarizationEngine.descriptors),
            ledger: ledger)
        // The "Account engine" — the user's Claude subscription via the `claude -p`
        // CLI (~$0). Registered alongside the API engine so the existing engine
        // picker surfaces it; it is NEVER the default (`EngineDefaults.summarization`
        // stays the API engine) and runs only when the user selects it AND it is
        // available (the `claude` binary resolves AND the OAuth token is set).
        let claudeCode = ClaudeCodeSummarizationEngine(
            configuration: configuration(
                for: ClaudeCodeSummarizationEngine.engineID,
                descriptors: ClaudeCodeSummarizationEngine.descriptors),
            ledger: ledger)
        // `try!` is safe: the ids are distinct constants. Summarization
        // order is load-bearing (D17): the lightweight API engine is
        // registered FIRST so that any first-registered substitution path
        // can never land on the 18 GB-peak local engine (the resolver also
        // prefers a lightweight engine on its own — belt and suspenders).
        // The account (claude -p) engine is registered LAST so the runtime
        // lightweight-substitution / one-hop fallback never AUTO-routes a
        // meeting's transcript through the subscription path: the API engine
        // is preferred, then the local MLX engine, and the account engine runs
        // ONLY when the user explicitly selects it.
        return try! EngineRegistry(
            asr: [whisper, parakeet], summarization: [claude, gemma, claudeCode])
    }
}
