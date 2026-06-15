import BlaiseCore
import EventKit
import SwiftUI

/// A STABLE 1 Hz tick anchor for the dropdown's live timers (elapsed while
/// recording, grace countdown). `from: .now` is re-evaluated on every render,
/// so a TimelineView anchored on it sees a NEW schedule input every pass — the
/// same perpetual-dirty failure that spun the status-item label into an
/// infinite update loop at launch (14/06). A fixed anchor ticks normally; the
/// phase is irrelevant because each readout is computed from the session start
/// / grace deadline against `context.date`, not the anchor.
private let menuTickAnchor = Date(timeIntervalSinceReferenceDate: 0)

// C11: the discreet menu-bar indicator (MenuBarExtra, research §6) + the
// recording menu (start/stop with source picker, calendar suggestions,
// Open Blaise, last meeting). Four states: idle (template glyph), recording
// (subtle red-tinted glyph; elapsed in the MENU, not the bar — calm),
// warning, processing. No dock bounce, no notifications.

// MARK: - Status holder

@MainActor @Observable
final class CaptureStatusHolder {
    private(set) var state: IndicatorState = .idle
    /// The captured meeting currently recording/processing (menu labels).
    var activeMeetingTitle: String?
    /// Set at stop; the pipeline event for this meeting flips processing→idle.
    var processingMeetingID: MeetingID?
    /// G9: the meeting currently held in `paused` (the Resume / End & process
    /// actions target it). Cleared on resume/end.
    var pausedMeetingID: MeetingID?
    /// G9 (M-8): the detached launch orphan-CAF sweep has finished. Resume is
    /// GATED on this — a live new-part CAF can never race the sweep's
    /// zero-frame unlink of a paused meeting's orphan CAF. The sweep finishes
    /// in seconds; the Resume control is disabled until it reports done. End &
    /// process and Stop are NOT gated (they never open a new live part).
    var launchSweepComplete = false
    var lastMeeting: (id: MeetingID, title: String)?
    /// Transient start/stop failure surfaced in the menu (no notifications).
    var lastActionError: String?

    // C14 automation surfaces (the menu is the load-bearing equivalent of
    // every notification when notifications are denied).
    /// Standing grace windows, soonest expiry first (back-to-back meetings
    /// can hold several at once; the menu shows the soonest plus a count).
    var graceWindows: [(meetingID: MeetingID, code: String, title: String, until: Date)] = []
    var notificationsDenied = false
    /// Live Meet call with no recording ("Meeting detected — Record").
    var detectedMeeting: (code: String, title: String?)?
    /// 15-minute zero-signal nudge line.
    var nudgeMessage: String?
    /// Calendar pre-meeting reminder mirror (denied-mode menu line).
    var calendarReminder: (eventKey: String, title: String, code: String, urlString: String)?

    private var machine = IndicatorStateMachine()

    func apply(_ input: IndicatorStateMachine.Input) {
        state = machine.apply(input)
    }

    var isRecording: Bool {
        switch state {
        case .recording, .warning: return true
        case .idle, .processing, .alarm, .grace, .paused: return false
        }
    }

    /// G9: the indicator is showing a held-open paused meeting (the menu +
    /// main-window controls show Resume / End & process).
    var isPaused: Bool {
        if case .paused = state { return true }
        return false
    }
}

extension CaptureStatusHolder: AutomationNotificationMirroring {
    func calendarReminderPosted(eventKey: String, title: String, code: String, urlString: String) {
        calendarReminder = (eventKey, title, code, urlString)
    }

    func calendarReminderWithdrawn(eventKey: String) {
        if calendarReminder?.eventKey == eventKey {
            calendarReminder = nil
        }
    }
}

// MARK: - Calendar suggestions (EventKit adapter; graceful absence)

/// EventKit full access (macOS has no read-only level —
/// NSCalendarsFullAccessUsageDescription; its own TCC prompt, fired ONLY
/// when the user opens calendar suggestions). Denied/absent → plain manual.
@MainActor @Observable
final class CalendarSuggestionProvider {
    enum Access {
        case notDetermined, granted, denied
    }

    private var store: EKEventStore?
    private(set) var suggestions: [MeetingSuggestion] = []

    var access: Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    /// User-initiated (the menu's "Show Calendar Suggestions" action): the
    /// one place the EventKit prompt can fire.
    func requestAccessAndLoad(userEmail: String) async {
        let store = store ?? EKEventStore()
        self.store = store
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        if granted { load(userEmail: userEmail) }
    }

    /// Loads events ±15 min from now (no prompt; call only when granted).
    func load(userEmail: String, now: Date = Date()) {
        guard access == .granted else {
            suggestions = []
            return
        }
        let window = CalendarSuggestionBuilder.windowSeconds
        let snapshots = eventSnapshots(
            from: now.addingTimeInterval(-window), to: now.addingTimeInterval(window))
        suggestions = CalendarSuggestionBuilder.suggestions(
            from: snapshots, now: now, userEmail: userEmail)
    }

    /// Raw snapshots over an arbitrary window (C14 `PreMeetingScheduler`
    /// input: a rolling 24 h fetch). No prompt; empty when not granted.
    func eventSnapshots(from start: Date, to end: Date) -> [CalendarEventSnapshot] {
        guard access == .granted else { return [] }
        let store = store ?? EKEventStore()
        self.store = store
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).map { event in
            CalendarEventSnapshot(
                eventIdentifier: event.eventIdentifier ?? "",
                title: event.title ?? "Meeting",
                start: event.startDate,
                end: event.endDate,
                location: event.location,
                notes: event.notes,
                urlString: event.url?.absoluteString,
                attendees: (event.attendees ?? []).map { participant in
                    CalendarEventSnapshot.AttendeeSnapshot(
                        name: participant.name ?? Self.email(of: participant) ?? "Unknown",
                        email: Self.email(of: participant))
                })
        }
    }

    private static func email(of participant: EKParticipant) -> String? {
        let url = participant.url.absoluteString
        return url.hasPrefix("mailto:") ? String(url.dropFirst("mailto:".count)) : nil
    }
}

// MARK: - Menu bar label + always-alive window routing

/// The MenuBarExtra label, plus the notification-click → open-main-window
/// routing observer (round-2 M-2). The MenuBarExtra label view tree is alive
/// for the whole app lifetime — including when the main window is CLOSED,
/// the state where the WindowGroup's own observer no longer exists — so this
/// is the seam that can recreate a closed window in response to a click. The
/// observer reacts to `AppUIState.openMainWindowRequest`, the counter the
/// notification action increments (`AppEnvironment` `onAction.openMainWindow`).
struct MenuBarLabelWithWindowRouting: View {
    /// The live capture status + handoff status holders, read HERE (inside this
    /// leaf's body) rather than in `App.body`. Field bug 12/06: reading
    /// `captureStatus.state` / `handoffStatus.snapshot` in the scene builder
    /// made every recording tick (and every capture lifecycle event) invalidate
    /// the WHOLE `App.body` — re-creating the sibling `Settings { }` content and
    /// its `TabView`, which drops the macOS Settings tab-item SF Symbol icons
    /// (the FB15540812 re-render class). Confining the ticking reads to this
    /// always-alive label means a tick can only re-render the menu-bar glyph.
    /// Holders are optional: nil only during the brief composition-root failure
    /// window (no env), where the label renders the idle glyph.
    var captureStatus: CaptureStatusHolder?
    var handoffStatus: HandoffStatusHolder?
    /// nil only during the brief composition-root failure window (no env).
    var uiState: AppUIState?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let state = captureStatus?.state ?? .idle
        let handoffWarning = handoffStatus?.snapshot.warning != nil
        Group {
            // G12 §1: while recording/paused the label expands to the live
            // timer (`● MM:SS`, tabular digits). The handoff warning badge keeps
            // priority only in the quiet states (as before); a live recording
            // owns the menu-bar item.
            if handoffWarning, RecordingTimerModel.isQuietState(state) {
                RecordingMenuBarLabel(state: state, handoffWarning: true)
            } else {
                RecordingTimerLabel(state: state)
            }
        }
        .onChange(of: uiState?.openMainWindowRequest) { _, _ in
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

/// The ⌥⌘R Start/Stop menu command. Its `captureStatus.isRecording` read is
/// confined to this child view so it does NOT register `App.body` (the scene
/// builder) as a dependency of the ticking `captureStatus.state` — which would
/// re-create the sibling `Settings` scene's TabView on every recording tick
/// (field bug 12/06). Only this menu item re-renders when the state flips.
struct RecordingMenuCommandButton: View {
    @Environment(AppEnvironment.self) private var appEnv

    var body: some View {
        Button(
            appEnv.captureStatus.isRecording ? "Stop Recording" : "Start Recording"
        ) {
            Task { await appEnv.toggleRecording() }
        }
        .keyboardShortcut("r", modifiers: [.option, .command])
    }
}

struct RecordingMenuBarLabel: View {
    let state: IndicatorState
    /// Handoff persistent-failure warning (HandoffSnapshot.warning != nil):
    /// the quiet states swap to a badged glyph while it is active. Recording
    /// and alarm displays keep priority — the badge returns when they end,
    /// and the banner/notification surfaces carry the warning meanwhile.
    var handoffWarning = false

    var body: some View {
        if handoffWarning, isQuietState {
            Image(systemName: "waveform.badge.exclamationmark")
                .foregroundStyle(.orange)
        } else {
            switch state {
            case .idle:
                Image(systemName: "waveform.circle")
            case .recording:
                Image(systemName: "record.circle")
                    .foregroundStyle(Color(red: 0.92, green: 0.32, blue: 0.32))
            case .warning:
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.orange)
            case .alarm:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case .processing:
                Image(systemName: "arrow.triangle.2.circlepath.circle")
            case .grace:
                // Post-recording template glyph variant: pause-adjacent, calm.
                Image(systemName: "pause.circle")
            case .paused:
                // G9: held-open meeting — static accent pause-fill glyph
                // (calm, not the loud recording red).
                Image(systemName: "pause.circle.fill")
                    .foregroundStyle(Theme.accent)
            }
        }
    }

    private var isQuietState: Bool {
        switch state {
        case .idle, .processing, .grace, .paused: return true
        case .recording, .warning, .alarm: return false
        }
    }
}

// MARK: - Menu content

struct RecordingMenuView: View {
    @Environment(AppEnvironment.self) private var appEnv
    // Hosted in an AppKit NSPopover (not a SwiftUI scene), so `\.openWindow` is
    // unavailable. Window-opening is routed through `uiState.openMainWindowRequest`,
    // which StatusBarController observes and fulfills via AppKit.

    var body: some View {
        let status = appEnv.captureStatus
        let calendar = appEnv.calendarSuggestions

        Group {
            switch status.state {
            case .recording(let startedAt):
                recordingSection(startedAt: startedAt, warning: nil)
            case .warning(let startedAt, let message):
                recordingSection(startedAt: startedAt, warning: message)
            case .alarm(let message):
                // Loud post-stop failure: visible until dismissed or the
                // next successful start — and recording stays STARTABLE.
                Text("⚠ \(message)")
                Button("Dismiss Warning") {
                    status.apply(.alarmAcknowledged)
                }
                Divider()
                startSection(calendar: calendar)
            case .processing:
                Text("Processing\(status.activeMeetingTitle.map { " — \($0)" } ?? "")…")
                // Back-to-back meetings: the next recording can start while
                // the previous one is still processing.
                Divider()
                startSection(calendar: calendar)
            case .grace(let title, let until):
                graceSection(
                    title: title, until: until,
                    moreWaiting: max(0, status.graceWindows.count - 1))
                Divider()
                startSection(calendar: calendar)
            case .paused(let title, let accumulatedSeconds):
                // G9 three-state model: a held-open meeting offers Resume and
                // End & process. A new start is REFUSED while paused (the
                // controller's predicate), so no start section here — the
                // user must decide about the paused meeting first.
                pausedSection(title: title, accumulatedSeconds: accumulatedSeconds)
            case .idle:
                startSection(calendar: calendar)
            }

            // C14 denied-notifications surfaces: the menu is the
            // load-bearing equivalent of every notification.
            if status.notificationsDenied {
                if let detected = status.detectedMeeting, !status.isRecording {
                    Divider()
                    Text("Meeting detected — \(detected.title ?? detected.code)")
                    Button("Record \(detected.code)") {
                        Task { await appEnv.recordDetectedMeeting(code: detected.code) }
                    }
                }
                if let reminder = status.calendarReminder {
                    Divider()
                    Button("Launch & Record: \(reminder.title)") {
                        Task {
                            await appEnv.launchAndRecord(
                                eventKey: reminder.eventKey, code: reminder.code,
                                title: reminder.title, urlString: reminder.urlString)
                        }
                    }
                }
                if let nudge = status.nudgeMessage {
                    Divider()
                    Text(nudge)
                }
            }

            if let error = status.lastActionError {
                Divider()
                Text(error)
            }

            // Handoff persistent-failure warning: the badge's explanation
            // (the badge alone would be mysterious) + the retry affordance.
            if let warning = appEnv.handoffStatus.snapshot.warning {
                Divider()
                Text(warning.message())
                Button("Retry Delivery Now") {
                    Task { await appEnv.retryHandoffNow() }
                }
            }

            Divider()

            Button("Open Blaise") {
                appEnv.uiState.openMainWindowRequest += 1
            }
            if let last = status.lastMeeting {
                Button("Last Meeting: \(last.title)") {
                    appEnv.uiState.selectedMeetingID = last.id
                    appEnv.uiState.openMainWindowRequest += 1
                }
            }
        }
        .onAppear {
            // Refresh suggestions when the menu opens (granted = no prompt).
            if calendar.access == .granted {
                calendar.load(userEmail: appEnv.userEmail)
            }
        }
    }

    @ViewBuilder
    private func recordingSection(startedAt: Date, warning: String?) -> some View {
        if let warning {
            Text("⚠ \(warning)")
        }
        let title = appEnv.captureStatus.activeMeetingTitle ?? "Recording"
        // TimelineView so the elapsed time ticks while the menu is open.
        TimelineView(.periodic(from: menuTickAnchor, by: 1)) { context in
            Text("\(title) — \(Self.elapsed(since: startedAt, now: context.date))")
        }
        // G12 §2: the two-channel level meter in the dropdown too — the
        // "is it hearing me/others?" glance without opening the main window.
        LevelMeterView(holder: appEnv.levelMeter)
        if appEnv.captureStatus.processingMeetingID != nil {
            Text("Still processing the previous meeting…")
        }
        // G9 three-state model: Pause holds the meeting open (resume later or
        // end & process from pause); Stop finalizes and processes now.
        Button("Pause Recording") {
            Task { await appEnv.pauseRecording() }
        }
        Button("Stop Recording") {
            Task { await appEnv.stopRecording() }
        }
        .keyboardShortcut("r", modifiers: [.option, .command])
    }

    /// G9 paused section: the held-open meeting with its accumulated recorded
    /// time, offering Resume / End & process (the three-state model). A new
    /// start is refused while paused — the user decides about this meeting
    /// first.
    @ViewBuilder
    private func pausedSection(title: String, accumulatedSeconds: TimeInterval) -> some View {
        Text("Paused — \(title) (\(Self.duration(accumulatedSeconds)) recorded)")
        Button("Resume Recording") {
            Task { await appEnv.resumePausedRecording() }
        }
        // M-8: disabled until the launch orphan-CAF sweep reports done.
        .disabled(!appEnv.canResumePaused)
        Button("End & Process") {
            Task { await appEnv.endPausedRecording() }
        }
    }

    /// C14 grace section: "Waiting for rejoin (m:ss)" countdown + Resume +
    /// Finalize now. The load-bearing recovery surface when notifications
    /// are denied. Shows the SOONEST-expiring window (Resume/Finalize act on
    /// it) plus a count when more back-to-back windows are standing.
    @ViewBuilder
    private func graceSection(title: String, until: Date, moreWaiting: Int) -> some View {
        TimelineView(.periodic(from: menuTickAnchor, by: 1)) { context in
            let remaining = max(0, Int(until.timeIntervalSince(context.date)))
            Text("Waiting for rejoin (\(remaining / 60):\(String(format: "%02d", remaining % 60))) — \(title)")
        }
        if moreWaiting > 0 {
            Text("\(moreWaiting) more meeting\(moreWaiting == 1 ? "" : "s") waiting to finalize")
        }
        Button("Resume Recording") {
            Task { await appEnv.resumeFromGrace() }
        }
        // M-1: Pause the grace meeting (converts grace→paused). The control
        // during an active grace window — the real production caller of the
        // tracker's grace→paused conversion.
        Button("Pause") {
            Task { await appEnv.pauseGraceMeeting() }
        }
        Button("Finalize Now") {
            Task { await appEnv.finalizeGraceNow() }
        }
    }

    @ViewBuilder
    private func startSection(calendar: CalendarSuggestionProvider) -> some View {
        // Pasted-Meet-link affordance: a Meet link on the clipboard at
        // menu-open time pre-parses into the meeting code.
        let clipboardCode = NSPasteboard.general.string(forType: .string)
            .flatMap { MeetLinkParser.meetingCode(from: $0) }

        Menu("Start Recording") {
            Button(clipboardCode.map { "Google Meet (\($0) from clipboard)" } ?? "Google Meet") {
                Task { await appEnv.startRecording(source: .meet, meetingCode: clipboardCode) }
            }
            .keyboardShortcut("r", modifiers: [.option, .command])
            Button("Zoom") { Task { await appEnv.startRecording(source: .zoom) } }
            Button("Teams") { Task { await appEnv.startRecording(source: .teams) } }
            Button("In Person") { Task { await appEnv.startRecording(source: .inPerson) } }
        }

        switch calendar.access {
        case .granted:
            if calendar.suggestions.isEmpty {
                Text("No calendar events near now")
            } else {
                ForEach(Array(calendar.suggestions.enumerated()), id: \.offset) { _, suggestion in
                    Button("Start: \(suggestion.title) (\(Self.time(suggestion.start)))") {
                        Task { await appEnv.startRecording(suggestion: suggestion) }
                    }
                }
            }
        case .notDetermined:
            Button("Show Calendar Suggestions…") {
                Task { await calendar.requestAccessAndLoad(userEmail: appEnv.userEmail) }
            }
        case .denied:
            Text("Calendar access off (System Settings → Privacy)")
        }
    }

    private static func elapsed(since start: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    private static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// G9 accumulated recorded time (sum of part durations) for the paused
    /// display. Mirrors `elapsed`'s mm:ss / h:mm:ss formatting.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
