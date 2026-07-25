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

    // C14 automation surfaces. These are always visible in the menu: macOS can
    // accept a notification request without presenting a banner (Focus,
    // disabled alerts, or Notification Center settings), so permission alone
    // must never decide whether Blaise exposes an automation action.
    /// Standing grace windows, soonest expiry first (back-to-back meetings
    /// can hold several at once; the menu shows the soonest plus a count).
    var graceWindows: [(meetingID: MeetingID, code: String, title: String, until: Date)] = []
    var notificationHealth: AutomationNotificationHealth = .checking
    var lastNotificationReceipt: AutomationNotificationReceipt?
    /// Live Meet call with no recording ("Meeting detected — Record").
    var detectedMeeting: (code: String, title: String?)?
    /// 15-minute zero-signal nudge line.
    var nudgeMessage: String?
    /// Calendar pre-meeting reminder mirror (denied-mode menu line).
    var calendarReminder: (eventKey: String, title: String, code: String, urlString: String)?
    /// High-confidence Meet leave received; capture remains live only for the
    /// short reconnect cushion ending at this deadline.
    var meetingEndPendingUntil: Date?

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

    func notificationRequestCompleted(
        title: String, submittedAt: Date, acceptedBySystem: Bool
    ) {
        lastNotificationReceipt = AutomationNotificationReceipt(
            title: title, submittedAt: submittedAt, acceptedBySystem: acceptedBySystem)
    }
}

// MARK: - Calendar suggestions (EventKit adapter; graceful absence)

/// A selectable calendar (id + display name) for the Settings picker — shared by
/// the Apple and Google calendar lists.
struct CalendarChoice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

/// Persisted Apple Calendar source settings (mirrors `GoogleCalendarSettings`).
private struct AppleCalendarSettings: Codable, Equatable, Sendable {
    var enabled: Bool
    var hiddenCalendarIDs: [String]
    static let `default` = AppleCalendarSettings(enabled: true, hiddenCalendarIDs: [])
}

/// EventKit full access (macOS has no read-only level —
/// NSCalendarsFullAccessUsageDescription; its own TCC prompt, fired ONLY
/// when the user opens calendar suggestions). Denied/absent → plain manual.
@MainActor @Observable
final class CalendarSuggestionProvider {
    enum Access {
        case notDetermined, granted, denied
    }

    static let settingsKey = "calendar.apple.settings"

    private let google: GoogleCalendarModel
    private let settings: SettingsStore
    private var store: EKEventStore?
    private(set) var suggestions: [MeetingSuggestion] = []
    private(set) var upcomingRows: [UpcomingMeetingRow] = []

    /// Apple Calendar source on/off — user-level, independent of the OS grant.
    var appleEnabled = true
    /// EventKit `calendarIdentifier`s the user has hidden (empty = all shown).
    private(set) var appleHiddenCalendarIDs: Set<String> = []
    /// Available EventKit calendars (id + title) for the Settings picker.
    private(set) var appleCalendars: [CalendarChoice] = []

    init(google: GoogleCalendarModel, settings: SettingsStore) {
        self.google = google
        self.settings = settings
    }

    /// Load the persisted Apple-source settings (enabled + hidden calendars) and
    /// refresh the picker list. Called at startup and when Settings opens.
    func load() async {
        let stored = (try? await settings.get(Self.settingsKey, as: AppleCalendarSettings.self))
            ?? nil ?? .default
        appleEnabled = stored.enabled
        appleHiddenCalendarIDs = Set(stored.hiddenCalendarIDs)
        refreshAppleCalendars()
    }

    /// Enumerate the available EventKit calendars for the picker (no prompt;
    /// empty when access is not granted).
    func refreshAppleCalendars() {
        guard access == .granted else { appleCalendars = []; return }
        let store = store ?? EKEventStore()
        self.store = store
        appleCalendars = store.calendars(for: .event)
            .map { CalendarChoice(id: $0.calendarIdentifier, name: $0.title) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func setAppleEnabled(_ value: Bool) {
        appleEnabled = value
        persistApple()
    }

    /// Show/hide a specific Apple calendar across every surface.
    func setAppleCalendar(_ id: String, shown: Bool) {
        if shown { appleHiddenCalendarIDs.remove(id) } else { appleHiddenCalendarIDs.insert(id) }
        persistApple()
    }

    private var persistTask: Task<Void, Never>?
    private func persistApple() {
        let snapshot = AppleCalendarSettings(
            enabled: appleEnabled, hiddenCalendarIDs: Array(appleHiddenCalendarIDs))
        // Chain writes so a rapid burst of toggles persists in order (the last
        // toggle wins on disk) rather than racing as detached Tasks.
        let previous = persistTask
        persistTask = Task { [settings] in
            _ = await previous?.value
            try? await settings.set(Self.settingsKey, to: snapshot)
        }
    }

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
        if granted {
            // A user-initiated grant also turns the source ON, so a persisted
            // appleEnabled=false can't leave the just-granted source silent.
            if !appleEnabled { appleEnabled = true; persistApple() }
            refreshAppleCalendars()
            await refresh(userEmail: userEmail)
        }
    }

    /// Refreshes the menu suggestions plus the main-window/menu upcoming rows.
    /// EventKit is read only when already granted; Google Calendar is read only
    /// when the user has connected and enabled it in Settings.
    func refresh(
        userEmail: String, recordedCodes: Set<String> = [], now: Date = Date()
    ) async {
        let suggestionSnapshots = await eventSnapshots(
            from: now.addingTimeInterval(-CalendarSuggestionBuilder.lookbackSeconds),
            to: now.addingTimeInterval(CalendarSuggestionBuilder.lookaheadSeconds))
        suggestions = CalendarSuggestionBuilder.suggestions(
            from: suggestionSnapshots, now: now, userEmail: userEmail)

        let calendar = UpcomingMeetings.localCalendar
        let startOfDay = calendar.startOfDay(for: now)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)
            ?? now.addingTimeInterval(24 * 3600)
        let upcomingSnapshots = await eventSnapshots(from: startOfDay, to: endOfDay)
        upcomingRows = UpcomingMeetings.rows(
            from: upcomingSnapshots, now: now, recordedCodes: recordedCodes,
            userEmail: userEmail, calendar: calendar)
    }

    /// Raw snapshots over an arbitrary window (C14 `PreMeetingScheduler`
    /// input: a rolling 24 h fetch). No prompt; empty when no source is enabled.
    func eventSnapshots(from start: Date, to end: Date) async -> [CalendarEventSnapshot] {
        var snapshots: [CalendarEventSnapshot] = []
        snapshots.append(contentsOf: eventKitSnapshots(from: start, to: end))
        snapshots.append(contentsOf: await google.snapshots(from: start, to: end))
        return CalendarEventMerger.merged(snapshots)
    }

    private func eventKitSnapshots(from start: Date, to end: Date) -> [CalendarEventSnapshot] {
        guard appleEnabled, access == .granted else { return [] }
        let store = store ?? EKEventStore()
        self.store = store
        // Only calendars the user has NOT hidden (empty hidden set = all shown);
        // all hidden → nothing.
        let shown = store.calendars(for: .event)
            .filter { !appleHiddenCalendarIDs.contains($0.calendarIdentifier) }
        guard !shown.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: shown)
        return store.events(matching: predicate)
            .filter { !$0.isAllDay }  // never surface all-day events (Birthdays, all-day blocks)
            .map { event in
            CalendarEventSnapshot(
                eventIdentifier: "eventkit:\(event.eventIdentifier ?? "")",
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

// MARK: - Menu content

struct RecordingMenuView: View {
    @Environment(AppEnvironment.self) private var appEnv
    @State private var menuContentHeight: CGFloat = 300
    // Hosted in an AppKit NSPopover (not a SwiftUI scene), so `\.openWindow` is
    // unavailable. Window-opening is routed through `uiState.openMainWindowRequest`,
    // which StatusBarController observes and fulfills via AppKit.

    var body: some View {
        let status = appEnv.captureStatus

        VStack(spacing: 0) {
            menuHeader(status: status)
            Divider().opacity(0.55)

            // Track the natural content height so ordinary states stay compact.
            // Dense combinations are capped and scroll instead of stretching
            // the popover beyond a comfortable menu height.
            ScrollView {
                menuContent(status: status)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: RecordingMenuContentHeightKey.self,
                                value: proxy.size.height)
                        }
                    }
            }
            .frame(height: min(ceil(menuContentHeight), 460))
            .onPreferenceChange(RecordingMenuContentHeightKey.self) { height in
                guard height > 0 else { return }
                menuContentHeight = height
            }

            Divider().opacity(0.55)
            menuFooter(status: status)
        }
        .frame(width: 370)
        .background(.regularMaterial)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .task {
            // Neither operation prompts. Re-read both calendar rows and macOS
            // notification presentation settings each time the menu opens.
            async let calendar: Void = appEnv.refreshCalendarSurfaces()
            async let automation: Void = appEnv.refreshAutomationSurfaceStatus()
            _ = await (calendar, automation)
        }
    }

    @ViewBuilder
    private func menuContent(status: CaptureStatusHolder) -> some View {
        VStack(spacing: 10) {
            RecordingMenuCard(tint: captureTint(status.state)) {
                captureSection(status: status, calendar: appEnv.calendarSuggestions)
            }

            // Always mirror live automation actions in-app. A granted
            // notification permission does not prove that Focus or
            // presentation settings showed the banner.
            if let detected = status.detectedMeeting, !status.isRecording {
                detectedMeetingCard(detected, paused: status.isPaused)
            }
            if let reminder = status.calendarReminder {
                calendarReminderCard(reminder)
            }
            if let nudge = status.nudgeMessage {
                messageCard(
                    title: "Check Meet connection", message: nudge,
                    systemImage: "waveform.badge.exclamationmark", tint: .orange,
                    dismiss: { status.nudgeMessage = nil })
            }
            if let error = status.lastActionError {
                messageCard(
                    title: "Recording action failed", message: error,
                    systemImage: "exclamationmark.triangle.fill", tint: .orange,
                    dismiss: { status.lastActionError = nil })
            }
            if let warning = appEnv.handoffStatus.snapshot.warning {
                RecordingMenuCard(tint: .orange) {
                    Label("Delivery needs attention", systemImage: "externaldrive.badge.exclamationmark")
                        .font(.headline)
                    Text(warning.message())
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Retry Delivery Now") {
                        Task { await appEnv.retryHandoffNow() }
                    }
                    .buttonStyle(.bordered)
                }
            }

            automationStatusCard
        }
        .padding(12)
    }

    private func menuHeader(status: CaptureStatusHolder) -> some View {
        let visualState = BlaiseStatusIcon.visualState(
            for: status.state,
            handoffWarning: appEnv.handoffStatus.snapshot.warning != nil,
            meetingDetected: status.detectedMeeting != nil)
        return HStack(spacing: 9) {
            Image(nsImage: BlaiseStatusIcon.image(for: visualState))
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Blaise").font(.headline)
                Text(headerSubtitle(status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if status.isRecording {
                Text(status.meetingEndPendingUntil == nil ? "REC" : "ENDING")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Design.recording, in: Capsule())
            } else if status.detectedMeeting != nil {
                Text("MEETING FOUND")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.accent.opacity(0.12), in: Capsule())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private func captureSection(
        status: CaptureStatusHolder, calendar: CalendarSuggestionProvider
    ) -> some View {
        switch status.state {
        case .recording(let startedAt):
            recordingSection(startedAt: startedAt, warning: nil)
        case .warning(let startedAt, let message):
            recordingSection(startedAt: startedAt, warning: message)
        case .alarm(let message):
            Label("Recording may need attention", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(message).font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Dismiss") { status.apply(.alarmAcknowledged) }
                    .buttonStyle(.bordered)
                Spacer()
            }
            Divider().opacity(0.5)
            startSection(calendar: calendar)
        case .processing:
            Label("Processing meeting", systemImage: "arrow.triangle.2.circlepath")
                .font(.headline)
            if let title = status.activeMeetingTitle {
                Text(title).font(.callout).foregroundStyle(.secondary)
            }
            ProgressView().controlSize(.small)
            Divider().opacity(0.5)
            startSection(calendar: calendar)
        case .grace(let title, let until):
            graceSection(
                title: title, until: until,
                moreWaiting: max(0, status.graceWindows.count - 1))
            Divider().opacity(0.5)
            startSection(calendar: calendar)
        case .paused(let title, let accumulatedSeconds):
            pausedSection(title: title, accumulatedSeconds: accumulatedSeconds)
        case .idle:
            startSection(calendar: calendar)
        }
    }

    @ViewBuilder
    private func recordingSection(startedAt: Date, warning: String?) -> some View {
        if let warning {
            Label(warning, systemImage: "exclamationmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
        }
        if let until = appEnv.captureStatus.meetingEndPendingUntil {
            TimelineView(.periodic(from: menuTickAnchor, by: 1)) { context in
                let seconds = max(0, Int(ceil(until.timeIntervalSince(context.date))))
                Label(
                    seconds > 0
                        ? "Meet ended — stopping in \(seconds)s"
                        : "Meet ended — stopping…",
                    systemImage: "hourglass")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
        let title = appEnv.captureStatus.activeMeetingTitle ?? "Recording"
        // TimelineView so the elapsed time ticks while the menu is open.
        TimelineView(.periodic(from: menuTickAnchor, by: 1)) { context in
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).lineLimit(1)
                    Text("Recording in progress")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(Self.elapsed(since: startedAt, now: context.date))
                    .font(.system(.title3, design: .monospaced, weight: .semibold))
                    .foregroundStyle(Design.recording)
            }
        }
        // G12 §2: the two-channel level meter in the dropdown too — the
        // "is it hearing me/others?" glance without opening the main window.
        LevelMeterView(holder: appEnv.levelMeter)
        if appEnv.captureStatus.processingMeetingID != nil {
            Label("Still processing the previous meeting", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        // G9 three-state model: Pause holds the meeting open (resume later or
        // end & process from pause); Stop finalizes and processes now.
        HStack {
            Button("Pause") { Task { await appEnv.pauseRecording() } }
                .buttonStyle(.bordered)
            Spacer()
            Button("Stop & Process") { Task { await appEnv.stopRecording() } }
                .buttonStyle(.borderedProminent)
                .tint(Design.recording)
                .keyboardShortcut("r", modifiers: [.option, .command])
        }
    }

    /// G9 paused section: the held-open meeting with its accumulated recorded
    /// time, offering Resume / End & process (the three-state model). A new
    /// start is refused while paused — the user decides about this meeting
    /// first.
    @ViewBuilder
    private func pausedSection(title: String, accumulatedSeconds: TimeInterval) -> some View {
        Label("Recording paused", systemImage: "pause.circle.fill")
            .font(.headline)
            .foregroundStyle(Theme.accent)
        Text(title).font(.callout)
        Text("\(Self.duration(accumulatedSeconds)) recorded")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        HStack {
            Button("End & Process") { Task { await appEnv.endPausedRecording() } }
                .buttonStyle(.bordered)
            Spacer()
            Button("Resume") { Task { await appEnv.resumePausedRecording() } }
                .buttonStyle(.borderedProminent)
                // M-8: disabled until the launch orphan-CAF sweep reports done.
                .disabled(!appEnv.canResumePaused)
        }
    }

    /// C14 grace section: "Waiting for rejoin (m:ss)" countdown + Resume +
    /// Finalize now. Shows the SOONEST-expiring window (Resume/Finalize act on
    /// it) plus a count when more back-to-back windows are standing.
    @ViewBuilder
    private func graceSection(title: String, until: Date, moreWaiting: Int) -> some View {
        TimelineView(.periodic(from: menuTickAnchor, by: 1)) { context in
            let remaining = max(0, Int(until.timeIntervalSince(context.date)))
            VStack(alignment: .leading, spacing: 3) {
                Label("Waiting for Meet rejoin", systemImage: "arrow.clockwise.circle")
                    .font(.headline)
                Text(title).font(.callout)
                Text("Finalizes in \(remaining / 60):\(String(format: "%02d", remaining % 60))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        if moreWaiting > 0 {
            Text("\(moreWaiting) more meeting\(moreWaiting == 1 ? "" : "s") waiting to finalize")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        HStack {
            Menu("More") {
                // M-1: converts grace→paused.
                Button("Pause Meeting") { Task { await appEnv.pauseGraceMeeting() } }
                Button("Finalize Now") { Task { await appEnv.finalizeGraceNow() } }
            }
            .menuStyle(.button)
            Spacer()
            Button("Resume") { Task { await appEnv.resumeFromGrace() } }
                .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private func startSection(calendar: CalendarSuggestionProvider) -> some View {
        // Pasted-Meet-link affordance: a Meet link on the clipboard at
        // menu-open time pre-parses into the meeting code.
        let clipboardCode = NSPasteboard.general.string(forType: .string)
            .flatMap { MeetLinkParser.meetingCode(from: $0) }

        Menu {
            Button(clipboardCode.map { "Google Meet (\($0) from clipboard)" } ?? "Google Meet") {
                Task { await appEnv.startRecording(source: .meet, meetingCode: clipboardCode) }
            }
            .keyboardShortcut("r", modifiers: [.option, .command])
            Button("Zoom") { Task { await appEnv.startRecording(source: .zoom) } }
            Button("Teams") { Task { await appEnv.startRecording(source: .teams) } }
            Button("Slack") { Task { await appEnv.startSlackRecording() } }
            Button("In Person") { Task { await appEnv.startRecording(source: .inPerson) } }
        } label: {
            Label("Start Recording", systemImage: "record.circle")
                .frame(maxWidth: .infinity)
        }
        .menuStyle(.button)
        .buttonStyle(.borderedProminent)
        .controlSize(.large)

        if !calendar.upcomingRows.isEmpty {
            Text("UPCOMING")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
                .padding(.top, 3)
            ForEach(calendar.upcomingRows.prefix(3)) { row in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Self.menuTitle(row.title)).font(.callout).lineLimit(1)
                        Text(Self.time(row.start))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if row.offersLaunchAndRecord {
                        Button {
                            Task { await appEnv.launchAndRecord(upcoming: row) }
                        } label: {
                            Image(systemName: "video.fill")
                        }
                        .buttonStyle(.borderless)
                        .help("Launch in Chrome and record")
                    }
                    Button("Record") { Task { await appEnv.startRecording(upcoming: row) } }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }

        switch calendar.access {
        case .granted:
            EmptyView()
        case .notDetermined:
            Button("Connect Apple Calendar…") {
                Task { await calendar.requestAccessAndLoad(userEmail: appEnv.userEmail) }
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
        case .denied:
            Label("Apple Calendar is off", systemImage: "calendar.badge.exclamationmark")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func detectedMeetingCard(
        _ detected: (code: String, title: String?), paused: Bool
    ) -> some View {
        RecordingMenuCard(tint: Theme.accent) {
            HStack(spacing: 7) {
                Image(nsImage: BlaiseStatusIcon.image(for: .meetingDetected))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
                Text("Meeting detected")
                    .font(.headline)
                    .foregroundStyle(Theme.accent)
            }
            Text(detected.title ?? "Google Meet")
                .font(.callout.weight(.medium))
                .lineLimit(2)
            Text(detected.code)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            if paused {
                Text("Finish or resume the paused recording first.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Button("Not This Meeting") {
                    Task { await appEnv.dismissDetectedMeeting(code: detected.code) }
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("Record Now") {
                    Task { await appEnv.recordDetectedMeeting(code: detected.code) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(paused)
            }
        }
    }

    private func calendarReminderCard(
        _ reminder: (eventKey: String, title: String, code: String, urlString: String)
    ) -> some View {
        RecordingMenuCard(tint: Design.support) {
            Label("Calendar meeting ready", systemImage: "calendar.badge.clock")
                .font(.headline)
                .foregroundStyle(Design.support)
            Text(reminder.title).font(.callout.weight(.medium)).lineLimit(2)
            HStack {
                Button("Dismiss") {
                    Task { await appEnv.dismissCalendarReminder(eventKey: reminder.eventKey) }
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("Launch & Record") {
                    Task {
                        await appEnv.launchAndRecord(
                            eventKey: reminder.eventKey, code: reminder.code,
                            title: reminder.title, urlString: reminder.urlString)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func messageCard(
        title: String, message: String, systemImage: String, tint: Color,
        dismiss: @escaping @MainActor () -> Void
    ) -> some View {
        RecordingMenuCard(tint: tint) {
            HStack(alignment: .top) {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                    .foregroundStyle(tint)
                Spacer()
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Dismiss")
            }
            Text(message).font(.callout).foregroundStyle(.secondary)
        }
    }

    private var automationStatusCard: some View {
        let listener = listenerPresentation
        let notifications = notificationPresentation
        let degraded = listener.needsAttention || notifications.needsAttention

        return RecordingMenuCard(tint: degraded ? .orange : .green) {
            Text("AUTOMATION STATUS")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
            statusRow(
                systemImage: listener.systemImage, tint: listener.tint,
                title: listener.title, detail: listener.detail)
            Divider().opacity(0.35)
            statusRow(
                systemImage: notifications.systemImage, tint: notifications.tint,
                title: notifications.title, detail: notifications.detail)
        }
    }

    private func statusRow(
        systemImage: String, tint: Color, title: String, detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: systemImage)
                .frame(width: 16)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.semibold))
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private typealias StatusPresentation = (
        title: String, detail: String, systemImage: String, tint: Color, needsAttention: Bool
    )

    private var listenerPresentation: StatusPresentation {
        let holder = appEnv.listenerStatus
        switch holder.state {
        case .starting:
            return ("Meet listener starting", "Preparing the local Chrome connection.",
                    "ellipsis.circle", .secondary, false)
        case .disabledForIsolatedData:
            return ("Meet listener off in test build",
                    "This isolated copy cannot take over the live app’s connection.",
                    "checkmark.shield", .green, false)
        case .unavailable:
            return ("Meet listener unavailable",
                    "Chrome events are buffering; Blaise retries the connection every minute.",
                    "exclamationmark.triangle.fill", .orange, true)
        case .listening:
            guard let response = holder.lastResponse else {
                return ("Waiting for Chrome extension",
                        "Listener is ready; no Meet event has arrived since Blaise launched.",
                        "antenna.radiowaves.left.and.right", .secondary, false)
            }
            switch response.status {
            case 200:
                return ("Meet extension connected",
                        "Last batch accepted \(Self.relativeAge(response.receivedAt)).",
                        "checkmark.circle.fill", .green, false)
            case 401:
                return ("Meet extension secret rejected",
                        "Chrome reached Blaise, but the shared secret was missing or did not match.",
                        "key.slash.fill", .orange, true)
            case 400:
                return ("Meet batch rejected",
                        "Chrome reached Blaise, but the batch format was unusable.",
                        "exclamationmark.triangle.fill", .orange, true)
            default:
                return ("Meet event will retry",
                        "Chrome reached Blaise, but local acceptance failed.",
                        "arrow.clockwise.circle.fill", .orange, true)
            }
        }
    }

    private var notificationPresentation: StatusPresentation {
        let status = appEnv.captureStatus
        let latest = status.lastNotificationReceipt
        if let latest, !latest.acceptedBySystem {
            return ("Notification request failed",
                    "The action is still available here in the Blaise menu.",
                    "bell.badge.slash.fill", .orange, true)
        }
        switch status.notificationHealth {
        case .checking:
            return ("Checking notifications", "Reading macOS presentation settings.",
                    "ellipsis.circle", .secondary, false)
        case .available:
            let detail = latest.map {
                "Sent “\($0.title)” to macOS \(Self.relativeAge($0.submittedAt)); Focus can still keep it quiet."
            } ?? "Banners are allowed; Focus can still keep them quiet. Actions always appear here."
            return ("Notification banners allowed", detail, "bell.fill", .green, false)
        case .alertsDisabled:
            return ("Notification banners are off",
                    "macOS may keep alerts in the background; actions always appear here.",
                    "bell.slash.fill", .orange, true)
        case .denied:
            return ("Notifications denied",
                    "Enable Blaise in System Settings if you want banners; actions still appear here.",
                    "bell.slash.fill", .orange, true)
        case .notDetermined:
            return ("Notifications not authorized",
                    "Blaise has not received a macOS notification decision yet.",
                    "bell.badge.fill", .orange, true)
        case .unavailable:
            return ("Notification status unavailable",
                    "Blaise could not read macOS notification settings.",
                    "bell.badge.exclamationmark.fill", .orange, true)
        }
    }

    private func menuFooter(status: CaptureStatusHolder) -> some View {
        HStack(spacing: 8) {
            Button {
                appEnv.uiState.openMainWindowRequest += 1
            } label: {
                Label("Open Blaise", systemImage: "macwindow")
            }
            .buttonStyle(.plain)
            .font(.callout.weight(.medium))
            Spacer()
            if let last = status.lastMeeting {
                Button {
                    appEnv.uiState.selectedMeetingID = last.id
                    appEnv.uiState.openMainWindowRequest += 1
                } label: {
                    Label("Last Meeting", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(last.title)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func headerSubtitle(_ status: CaptureStatusHolder) -> String {
        if status.meetingEndPendingUntil != nil {
            return "Meet ended — finishing capture"
        }
        return switch status.state {
        case .recording, .warning: "Capturing this meeting"
        case .alarm: "Recording needs attention"
        case .processing: "Turning the last meeting into memory"
        case .grace: "Waiting for a quick rejoin"
        case .paused: "Meeting held open"
        case .idle: status.detectedMeeting == nil ? "Ready to remember" : "Ready to record this call"
        }
    }

    private func captureTint(_ state: IndicatorState) -> Color {
        switch state {
        case .recording, .warning: Design.recording
        case .alarm: .orange
        case .processing, .grace, .paused: Theme.accent
        case .idle: .white
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

    private static func menuTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 16 else { return trimmed.isEmpty ? "Meeting" : trimmed }
        return String(trimmed.prefix(15)) + "…"
    }

    private static func relativeAge(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 10 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        return "\(hours)h ago"
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

private struct RecordingMenuContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct RecordingMenuCard<Content: View>: View {
    let tint: Color
    @ViewBuilder let content: Content

    init(tint: Color, @ViewBuilder content: () -> Content) {
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.045))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(tint.opacity(0.22), lineWidth: 1)
        }
    }
}
