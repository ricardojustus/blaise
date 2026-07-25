import BlaiseCore
import SwiftUI

// Settings scene: Engines / Automation / Glossary / Identity & Handoff / Usage.

struct SettingsRootView: View {
    // Screenshot scaffolding: BLAISE_DEMO_SCENE=cloud-spend opens the Usage
    // tab directly (the G7 receipts panel evidence); settings-handoff opens the
    // Identity & Handoff tab (the G5 destination-picker evidence). Normal
    // launches default to Engines.
    @State private var selection: Int = {
        switch ProcessInfo.processInfo.environment["BLAISE_DEMO_SCENE"] {
        case "cloud-spend": return 4
        case "settings-handoff": return 3
        default: return 0
        }
    }()

    var body: some View {
        TabView(selection: $selection) {
            EnginesSettingsTab()
                .tabItem { Label("Engines", systemImage: "cpu") }
                .tag(0)
            AutomationTab()
                .tabItem { Label("Automation", systemImage: "bell.badge") }
                .tag(1)
            GlossaryTab()
                .tabItem { Label("Glossary", systemImage: "character.book.closed") }
                .tag(2)
            IdentityHandoffTab()
                .tabItem { Label("Identity & Handoff", systemImage: "person.crop.circle.badge.checkmark") }
                .tag(3)
            UsageTab()
                .tabItem { Label("Usage", systemImage: "chart.bar") }
                .tag(4)
        }
        .frame(width: 620, height: 600)
    }
}

// MARK: - Automation tab (C14)

struct AutomationTab: View {
    @Environment(AppEnvironment.self) private var appEnv
    @State private var enabled = true
    @State private var confirmParticipants = false
    @State private var resumeWindowMinutes = AutomationSettings.defaultResumeWindowSeconds / 60
    @State private var silenceAutoPauseEnabled = SilenceAutoPauseSettings.defaultEnabled
    @State private var silenceThresholdMinutes = Int(SilenceAutoPauseSettings.defaultThresholdSeconds / 60)
    @State private var deniedBannerDismissed = false
    @State private var notificationTestSent = false
    @State private var loaded = false

    private static let deniedBannerKey = "automation.deniedBannerDismissed"

    var body: some View {
        @Bindable var google = appEnv.googleCalendar
        Form {
            Section("Meeting automation") {
                Toggle("Meeting automation (notifications, auto-stop)", isOn: $enabled)
                    .onChange(of: enabled) { _, newValue in
                        guard loaded else { return }
                        Task {
                            try? await appEnv.settings.set(
                                AutomationSettings.enabledKey, to: newValue)
                        }
                    }
                Text(
                    "A notification offers Record when a Meet call starts; the recording stops by itself when the meeting ends. Manual start/stop always works."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                // G15: opt-in participant-confirmation gate.
                Toggle(
                    "Ask me to confirm participants before notes are written",
                    isOn: $confirmParticipants
                )
                .onChange(of: confirmParticipants) { _, newValue in
                    guard loaded else { return }
                    Task {
                        try? await appEnv.settings.set(
                            AutomationSettings.confirmParticipantsKey, to: newValue)
                    }
                }
                Text(
                    "When a meeting's participants couldn't be learned from your calendar or the Meet roster, Blaise still transcribes and keeps the audio, but holds the notes until you confirm the names (or skip). Off by default."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Section("Notifications & connection") {
                LabeledContent("Notifications") {
                    Label(notificationStatusTitle, systemImage: notificationStatusIcon)
                        .foregroundStyle(notificationStatusTint)
                }
                LabeledContent("Meet extension") {
                    Label(listenerStatusTitle, systemImage: listenerStatusIcon)
                        .foregroundStyle(listenerStatusTint)
                }
                HStack {
                    Button("Send Test Notification") {
                        notificationTestSent = true
                        Task { await appEnv.sendNotificationTest() }
                    }
                    Spacer()
                    if notificationTestSent {
                        Text("Test sent to macOS")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(
                    "The test only checks banners and the Open Blaise action. It never creates a meeting, recording, evidence payload, or handoff."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Section("Resume window") {
                Stepper(value: $resumeWindowMinutes, in: 0 ... 10) {
                    Text(resumeWindowMinutes == 0
                        ? "Resume window: Off"
                        : "Resume window: \(resumeWindowMinutes) min")
                }
                .onChange(of: resumeWindowMinutes) { _, newValue in
                    guard loaded else { return }
                    Task {
                        try? await appEnv.settings.set(
                            AutomationSettings.resumeWindowKey, to: newValue * 60)
                    }
                }
                Text(
                    "After an automatic stop, rejoining the same meeting within this window resumes the recording instead of starting a new one. Off finalizes immediately; manual stops are never held."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Section("Silence auto-pause") {
                Toggle("Auto-pause after sustained silence", isOn: $silenceAutoPauseEnabled)
                    .onChange(of: silenceAutoPauseEnabled) { _, newValue in
                        guard loaded else { return }
                        Task {
                            try? await appEnv.settings.set(
                                SilenceAutoPauseSettings.enabledKey, to: newValue)
                        }
                    }
                Stepper(value: $silenceThresholdMinutes, in: 1 ... 60) {
                    Text("Silence threshold: \(silenceThresholdMinutes) min")
                }
                .onChange(of: silenceThresholdMinutes) { _, newValue in
                    guard loaded else { return }
                    Task {
                        try? await appEnv.settings.set(
                            SilenceAutoPauseSettings.thresholdSecondsKey, to: Double(newValue * 60))
                    }
                }
                .disabled(!silenceAutoPauseEnabled)
                Text(
                    "If both your microphone and the meeting audio stay silent for this long, the recording pauses by itself (resumable). It never fires while either side has sound."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Section("Calendars") {
                // Apple Calendar — on/off + per-calendar picker.
                switch appEnv.calendarSuggestions.access {
                case .granted:
                    Toggle(
                        "Apple Calendar",
                        isOn: Binding(
                            get: { appEnv.calendarSuggestions.appleEnabled },
                            set: { value in
                                appEnv.calendarSuggestions.setAppleEnabled(value)
                                Task { await appEnv.calendarSourcesChanged() }
                            }))
                    if appEnv.calendarSuggestions.appleEnabled {
                        calendarPicker(
                            calendars: appEnv.calendarSuggestions.appleCalendars,
                            hidden: appEnv.calendarSuggestions.appleHiddenCalendarIDs
                        ) { id, shown in
                            appEnv.calendarSuggestions.setAppleCalendar(id, shown: shown)
                            Task { await appEnv.calendarSourcesChanged() }
                        }
                    }
                case .notDetermined:
                    LabeledContent("Apple Calendar") {
                        Button("Enable") {
                            Task {
                                await appEnv.calendarSuggestions.requestAccessAndLoad(
                                    userEmail: appEnv.userEmail)
                                await appEnv.calendarSourcesChanged()
                            }
                        }
                    }
                case .denied:
                    LabeledContent("Apple Calendar") {
                        Text("Off (System Settings)").foregroundStyle(.orange)
                    }
                }

                // Google Calendar — connect + per-calendar picker.
                Toggle(
                    "Google Calendar",
                    isOn: Binding(
                        get: { google.enabled },
                        set: { value in
                            google.setEnabled(value)
                            Task { await appEnv.calendarSourcesChanged() }
                        }))
                // Credential edits are frozen while a sign-in is in flight: the
                // refresh token must be persisted with the pair it was minted
                // under, not values edited mid-flow.
                TextField("OAuth desktop client ID", text: $google.clientID)
                    .textFieldStyle(.roundedBorder)
                    .disabled(google.authorizing)
                    .onSubmit {
                        Task {
                            await google.saveSettings()
                            await appEnv.calendarSourcesChanged()
                        }
                    }
                // Google's token endpoint rejects Desktop-app grants without the
                // client secret ("client_secret is missing"), so it's required
                // alongside the client ID for most setups.
                SecureField("OAuth client secret", text: $google.clientSecret)
                    .textFieldStyle(.roundedBorder)
                    .disabled(google.authorizing)
                    .onSubmit {
                        Task {
                            await google.saveSettings()
                            await appEnv.calendarSourcesChanged()
                        }
                    }
                HStack {
                    Button("Save") {
                        Task {
                            await google.saveSettings()
                            await appEnv.calendarSourcesChanged()
                        }
                    }
                    .disabled(google.authorizing)
                    Button(google.connected ? "Reconnect" : "Connect") {
                        Task {
                            await google.connect()
                            await google.listCalendars()
                            await appEnv.calendarSourcesChanged()
                        }
                    }
                    .disabled(google.authorizing)
                    if google.authorizing {
                        Button("Cancel") {
                            google.cancelConnect()
                        }
                    }
                    if google.connected {
                        Button("Disconnect") {
                            Task {
                                await google.disconnect()
                                await appEnv.calendarSourcesChanged()
                            }
                        }
                    }
                    if google.refreshing || google.authorizing {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                if google.authorizing {
                    Text("Waiting for Google sign-in in your browser…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if google.connected {
                    Label("Connected", systemImage: "checkmark.circle")
                        .foregroundStyle(Theme.accent)
                }
                if let error = google.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                if let error = google.settingsError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                if google.connected && google.enabled {
                    calendarPicker(
                        calendars: google.googleCalendars,
                        hidden: google.hiddenCalendarIDs
                    ) { id, shown in
                        google.setGoogleCalendar(id, shown: shown)
                        Task { await appEnv.calendarSourcesChanged() }
                    }
                }
            }
            if appEnv.captureStatus.notificationHealth.needsAttention && !deniedBannerDismissed {
                Section {
                    QuietBanner(
                        text: notificationBannerText,
                        systemImage: "bell.slash", tint: .orange,
                        accessibilityPrefix: "Notification presentation")
                    Button("Dismiss") {
                        deniedBannerDismissed = true
                        Task {
                            try? await appEnv.settings.set(Self.deniedBannerKey, to: true)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            await appEnv.refreshAutomationSurfaceStatus()
            await appEnv.googleCalendar.load()
            await appEnv.googleCalendar.listCalendars()
            await appEnv.calendarSuggestions.load()
            enabled = await AutomationSettings.enabled(from: appEnv.settings)
            confirmParticipants = await AutomationSettings.confirmParticipants(from: appEnv.settings)
            resumeWindowMinutes =
                await AutomationSettings.resumeWindowSeconds(from: appEnv.settings) / 60
            silenceAutoPauseEnabled = await SilenceAutoPauseSettings.enabled(from: appEnv.settings)
            silenceThresholdMinutes =
                Int((await SilenceAutoPauseSettings.thresholdSeconds(from: appEnv.settings) / 60).rounded())
            deniedBannerDismissed =
                (try? await appEnv.settings.get(Self.deniedBannerKey, as: Bool.self))
                ?? nil ?? false
            loaded = true
        }
    }

    private var notificationBannerText: String {
        switch appEnv.captureStatus.notificationHealth {
        case .alertsDisabled:
            return "macOS has authorized Blaise, but banners or Notification Center presentation are off. Meeting actions still stay visible in the menu-bar menu. Re-enable alerts in System Settings → Notifications → Blaise if you want banners too."
        case .denied:
            return "Notifications are denied, so meeting-start, resume, and calendar banners cannot appear. Auto-stop and the rejoin window still work, and the menu-bar menu carries every action. Re-enable Blaise in System Settings → Notifications."
        case .notDetermined:
            return "macOS has not recorded a notification choice for Blaise yet. Meeting actions remain available in the menu-bar menu."
        case .unavailable:
            return "Blaise could not read macOS notification settings. Meeting actions remain available in the menu-bar menu."
        case .checking, .available:
            return "Meeting actions remain available in the menu-bar menu."
        }
    }

    private var notificationStatusTitle: String {
        switch appEnv.captureStatus.notificationHealth {
        case .checking: return "Checking"
        case .available: return "Banners allowed"
        case .alertsDisabled: return "Banners off"
        case .denied: return "Denied"
        case .notDetermined: return "Not authorized"
        case .unavailable: return "Unavailable"
        }
    }

    private var notificationStatusIcon: String {
        appEnv.captureStatus.notificationHealth == .available
            ? "bell.badge.fill" : "bell.slash.fill"
    }

    private var notificationStatusTint: AnyShapeStyle {
        appEnv.captureStatus.notificationHealth == .available
            ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.orange)
    }

    private var listenerStatusTitle: String {
        switch appEnv.listenerStatus.state {
        case .starting: return "Starting"
        case .listening:
            return appEnv.listenerStatus.lastResponse?.status == 200 ? "Connected" : "Listening"
        case .disabledForIsolatedData: return "Off in isolated build"
        case .unavailable: return "Unavailable"
        }
    }

    private var listenerStatusIcon: String {
        switch appEnv.listenerStatus.state {
        case .listening: return "antenna.radiowaves.left.and.right"
        case .disabledForIsolatedData: return "checkmark.shield"
        case .starting: return "ellipsis.circle"
        case .unavailable: return "exclamationmark.triangle.fill"
        }
    }

    private var listenerStatusTint: AnyShapeStyle {
        switch appEnv.listenerStatus.state {
        case .unavailable: return AnyShapeStyle(Color.orange)
        case .listening: return AnyShapeStyle(Theme.accent)
        case .starting, .disabledForIsolatedData: return AnyShapeStyle(.secondary)
        }
    }

    /// A collapsible "show calendars" checklist for a source — each calendar a
    /// checkbox (checked = shown). Hidden when the source has no calendars.
    @ViewBuilder
    private func calendarPicker(
        calendars: [CalendarChoice], hidden: Set<String>,
        toggle: @escaping (String, Bool) -> Void
    ) -> some View {
        if !calendars.isEmpty {
            DisclosureGroup("Show calendars") {
                ForEach(calendars) { calendar in
                    Toggle(
                        calendar.name,
                        isOn: Binding(
                            get: { !hidden.contains(calendar.id) },
                            set: { toggle(calendar.id, $0) }))
                        .toggleStyle(.checkbox)
                }
            }
            .font(.callout)
        }
    }
}

// MARK: - Engines tab

struct EnginesSettingsTab: View {
    @Environment(AppEnvironment.self) private var appEnv

    var body: some View {
        let model = appEnv.engineSettings
        Form {
            EngineSlotSection(
                model: model, slot: .asr, title: "Transcription (ASR)",
                rows: model.asrRows,
                consequence:
                    "A selected engine that cannot run FAILS processing with its own reason until remedied — Blaise never silently swaps your transcription engine.")
            EngineSlotSection(
                model: model, slot: .summarization, title: "Notes (Summarization)",
                rows: model.summarizationRows,
                consequence:
                    "If the selected engine cannot run, that run falls back once to the other registered engine (noted on the meeting).")
        }
        .formStyle(.grouped)
        .task { await model.load() }
    }
}

private struct EngineSlotSection: View {
    @Bindable var model: EngineSettingsModel
    let slot: EngineSlot
    let title: String
    let rows: [EngineSettingsModel.EngineRow]
    let consequence: String

    var body: some View {
        Section(title) {
            Picker(
                "Engine",
                selection: Binding(
                    get: { model.selectedID(slot) },
                    set: { newValue in
                        Task { await model.select(newValue, slot: slot) }
                    })
            ) {
                ForEach(rows) { row in
                    HStack(spacing: 6) {
                        Text(row.displayName)
                        Text(row.kind == .cloud ? "CLOUD" : "LOCAL")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .tag(row.id)
                }
            }
            .accessibilityLabel("\(title) engine")

            if let selected = rows.first(where: { $0.id == model.selectedID(slot) }) {
                if let cost = selected.costSummary {
                    LabeledContent("Cost") { Text(cost).foregroundStyle(.secondary) }
                }
                if let reason = selected.availabilityReason {
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Engine unavailable: \(reason)")
                }
            }

            prepareRow

            Text(consequence)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let selected = rows.first(where: { $0.id == model.selectedID(slot) }),
                !selected.configDescriptors.isEmpty
            {
                ForEach(selected.configDescriptors, id: \.key) { descriptor in
                    EngineConfigField(engineID: selected.id, descriptor: descriptor)
                }
            }
        }
    }

    /// The pinned prepare UX: indeterminate row while preparing; failure →
    /// reason inline, selection kept, Retry offered; success → row clears.
    @ViewBuilder
    private var prepareRow: some View {
        switch model.prepareState(slot) {
        case .idle:
            EmptyView()
        case .preparing(let engineID):
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Preparing \(displayName(engineID))… first use may download models")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Preparing \(displayName(engineID))")
        case .failed(let engineID, let reason):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Could not prepare \(displayName(engineID))")
                        .font(.callout)
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Retry") {
                    Task { await model.retryPrepare(slot: slot) }
                }
            }
            .accessibilityLabel("Prepare failed for \(displayName(engineID)): \(reason)")
        }
    }

    private func displayName(_ id: String) -> String {
        rows.first { $0.id == id }?.displayName ?? id
    }
}

/// Generic per-engine config field from `configDescriptors`: secrets render
/// masked and land in the Keychain; everything else in SettingsStore — all
/// under `engine.<id>.<key>` (the Claude `apiKey` lands here — Q5).
private struct EngineConfigField: View {
    @Environment(AppEnvironment.self) private var appEnv
    let engineID: String
    let descriptor: EngineConfigDescriptor
    @State private var value = ""
    @State private var saved = false
    @State private var hasStoredValue = false

    private var storageKey: String { "engine.\(engineID).\(descriptor.key)" }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            if descriptor.kind == .secret {
                SecureField(label, text: $value, prompt: Text(hasStoredValue ? "•••••• (saved)" : "Required"))
            } else {
                TextField(label, text: $value)
            }
            Button("Save") { save() }
                .disabled(value.isEmpty)
            if saved {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(Theme.accent)
                    .accessibilityLabel("Saved")
            }
        }
        .task(id: engineID + descriptor.key) { await loadCurrent() }
    }

    private var label: String {
        descriptor.label + (descriptor.required ? "" : " (optional)")
    }

    private func loadCurrent() async {
        saved = false
        value = ""
        if descriptor.kind == .secret {
            hasStoredValue = ((try? appEnv.secrets.get(key: storageKey)) ?? nil) != nil
        } else {
            value = (try? await appEnv.settings.get(storageKey, as: String.self)) ?? nil ?? ""
        }
    }

    private func save() {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            if descriptor.kind == .secret {
                try? appEnv.secrets.set(key: storageKey, value: trimmed)
                hasStoredValue = true
                value = ""
            } else {
                try? await appEnv.settings.set(storageKey, to: trimmed)
            }
            saved = true
            // Config may unblock the selected engine: refresh availability.
            await appEnv.engineSettings.refreshRows()
            // D17 self-heal trigger: a saved summarization-engine config
            // (the Anthropic API key lands here) re-dispatches notes-pending
            // meetings through the notes-only resume.
            if appEnv.registry.summarizationEngine(id: engineID) != nil {
                await appEnv.pipeline.resumePendingNotes()
                // G14 H1: the same key-save also self-heals digest-pending
                // meetings (re-fires generateDigest, never generateNotes).
                await appEnv.pipeline.resumePendingDigests()
            }
        }
    }
}

// MARK: - Identity & Handoff tab

struct IdentityHandoffTab: View {
    @Environment(AppEnvironment.self) private var appEnv
    @State private var identity: IdentityModel?
    @State private var handoff: HandoffSettingsModel?
    @State private var queue: QueuePanelModel?
    @State private var processing: ProcessingQueueModel?
    @State private var revealedSecret: String?

    var body: some View {
        Form {
            if let banner = appEnv.listenerStatus.banner {
                Section {
                    QuietBanner(
                        text: banner, systemImage: "exclamationmark.triangle", tint: .orange,
                        accessibilityPrefix: "Meet listener")
                }
            }
            if let identity {
                // G3-L1: a Settings identity edit must refresh the LIVE
                // userName/userEmail (detail-view section title, calendar
                // self-exclusion) the same way onboarding's onFinish does —
                // not wait for a relaunch.
                IdentitySection(model: identity, onSaved: { appEnv.applyOnboardedIdentity() })
            }
            extensionSecretSection
            if let handoff {
                HandoffSection(model: handoff)
            }
            if let queue {
                QueuePanelSection(model: queue, snapshot: appEnv.handoffStatus.snapshot)
            }
            if let processing {
                ProcessingQueueSection(model: processing, snapshot: appEnv.processingStatus.snapshot)
            }
        }
        .formStyle(.grouped)
        .task {
            if identity == nil {
                let identityModel = IdentityModel(settings: appEnv.settings, secrets: appEnv.secrets)
                await identityModel.load()
                identity = identityModel
                let handoffModel = HandoffSettingsModel(settings: appEnv.settings, kicker: appEnv.worker)
                await handoffModel.load()
                handoff = handoffModel
                let queueModel = QueuePanelModel(database: appEnv.database, kicker: appEnv.worker)
                await queueModel.refresh()
                queue = queueModel
                let pipeline = appEnv.pipeline
                let processingModel = ProcessingQueueModel(
                    database: appEnv.database, worker: appEnv.processingQueue,
                    settings: appEnv.settings,
                    cancelRunning: { meetingID in _ = await pipeline.cancel(meetingID: meetingID) })
                await processingModel.refresh()
                processing = processingModel
            }
        }
    }

    private var extensionSecretSection: some View {
        Section("Meet Extension") {
            if let secret = revealedSecret {
                Text(secret)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                Button("Hide") { revealedSecret = nil }
            } else {
                LabeledContent("Shared secret") {
                    Text("Hidden").foregroundStyle(.secondary)
                }
                HStack {
                    Button("Reveal") { revealedSecret = identityOrNew()?.revealMeetSecret() }
                    Button("Regenerate") {
                        revealedSecret = identityOrNew()?.regenerateMeetSecret()
                    }
                    .help("Invalidates the old secret; paste the new value into the extension options page")
                }
            }
            Text("Paste this secret once into the Blaise Meet extension's options page.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func identityOrNew() -> IdentityModel? { identity }
}

private struct IdentitySection: View {
    @Bindable var model: IdentityModel
    /// G3-L1: invoked after the store write so the caller can refresh the live
    /// identity (section title, calendar self-exclusion) without a relaunch.
    var onSaved: () -> Void

    var body: some View {
        Section("Identity") {
            TextField("Name", text: $model.name)
            TextField("Aliases (comma-separated)", text: $model.aliasesText)
            TextField("Email", text: $model.email)
            HStack {
                Spacer()
                Button("Save Identity") {
                    Task {
                        await model.save()
                        onSaved()
                    }
                }
            }
            Text("Used to mark your speech and extract the dedicated action-items section.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct HandoffSection: View {
    @Bindable var model: HandoffSettingsModel

    var body: some View {
        Section("Evidence Store") {
            Text("Where finished meetings are delivered.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Destination", selection: $model.destinationKind) {
                Text("Evidence Store (SSH)").tag(HandoffDestination.Kind.ssh)
                Text("Local Folder").tag(HandoffDestination.Kind.localFolder)
            }
            .accessibilityLabel("Evidence Store destination")

            switch model.destinationKind {
            case .ssh:
                TextField("User", text: $model.user)
                TextField("Identity file", text: $model.identityFile)
                // A TextEditor, not a vertical TextField: on macOS, Return in a
                // `TextField(axis: .vertical)` SUBMITS the field instead of
                // inserting a newline, so "one per line" was impossible to type.
                // (The parser also accepts commas — HandoffSettingsModel.hosts.)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Hosts (one per line, or comma-separated)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $model.hostsText)
                        .font(.callout.monospaced())
                        .frame(minHeight: 52, maxHeight: 96)
                        .padding(4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.secondary.opacity(0.3)))
                        .accessibilityLabel("Evidence Store hosts, one per line")
                }
                TextField("Remote root", text: $model.remoteRoot)
            case .localFolder:
                LabeledContent("Folder") {
                    Text(model.localFolderPath.isEmpty ? "None chosen" : model.localFolderPath)
                        .foregroundStyle(model.localFolderPath.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button("Choose Folder…") { chooseFolder() }
                    .accessibilityLabel("Choose local destination folder")
            }

            // G6: the Markdown-sidecar toggle is destination-independent — SSH
            // uploads the .md alongside the JSON; Local Folder writes it next to
            // the JSON. (Mirrors the memory-digest toggle's placement.)
            Toggle("Write Markdown sidecar (Obsidian-ready)", isOn: $model.markdownSidecar)
                .accessibilityLabel("Write Markdown sidecar alongside the evidence payload")

            // G5 v1.3: superseded-payload REMOVAL. Default OFF ⇒ delivered
            // payloads accumulate, preserving the published immutable-history
            // contract. Named for the ACTION it performs: "Keep …" defaulting
            // to off is a double negative the reader must resolve before
            // learning that files get deleted.
            Toggle(
                "Remove superseded payloads at the destination",
                isOn: $model.removeSupersededPayloads
            )
            .accessibilityLabel("Remove superseded payloads at the destination")
            Text("Off (default): every delivered version is kept, so anything referencing an older payload can still find it. On: a correction or regeneration deletes the previous payload at the destination, leaving one current file per meeting.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // G5 v1.3: audio delivery. Default OFF (the privacy default) — the
            // headline is stated plainly here and in the README/contract doc.
            Toggle("Include audio recordings", isOn: $model.deliverAudio)
                .accessibilityLabel("Include audio recordings in the destination")
            Text("Off by default. On copies each meeting's recordings to the destination; a destination that syncs (iCloud/network) means audio leaves this machine. Applies to each meeting's NEXT delivery — there is no retroactive sweep.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // G14: the memory-digest toggle is destination-independent — it
            // gates the second machine-facing render on the knowledge graph payload.
            Toggle("Include memory digest", isOn: $model.includeMemoryDigest)
                .accessibilityLabel("Include memory digest in the evidence payload")
            Text("A second machine-facing render for the knowledge graph. On by default.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // The verify/repair pass — a third synthesis call that audits the
            // digest against the transcript and corrects grounding errors before
            // it ships. Only meaningful when the digest is included, so it is
            // disabled when "Include memory digest" is OFF.
            Toggle("Verify & repair memory digest", isOn: $model.verifyMemoryDigest)
                .disabled(!model.includeMemoryDigest)
                .accessibilityLabel("Verify and repair the memory digest before sending")
            Text("Runs a second pass that audits the digest against the transcript and corrects attribution/fact errors before sending. Higher accuracy; roughly doubles the digest's cloud cost.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let error = model.validationError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Handoff settings invalid: \(error)")
            }
            HStack {
                Spacer()
                Button("Save Handoff Settings") {
                    Task { await model.save() }  // valid → automatic worker kick
                }
            }
        }
    }

    /// NSOpenPanel folder picker → security-scoped bookmark (G5). The scope is
    /// opened to read the bookmark; the worker re-opens it at delivery time.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder finished meetings are delivered to."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        Task {
            await model.chooseLocalFolder(url)
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
    }
}

private struct QueuePanelSection: View {
    @Bindable var model: QueuePanelModel
    let snapshot: HandoffSnapshot

    var body: some View {
        Section("Delivery Queue") {
            LabeledContent("State") {
                Text(stateLabel)
                    .foregroundStyle(stateIsAlert ? .orange : .secondary)
            }
            if let endpoint = snapshot.activeEndpoint {
                LabeledContent("Endpoint") { Text(endpoint).monospaced() }
            }
            LabeledContent("Pending") { Text("\(snapshot.pendingCount)").monospacedDigit() }
            if let detail = snapshot.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            let retriable = model.queueItems.filter {
                $0.state == .failed && !HandoffErrorClass.isSuperseded($0.lastError)
            }
            if !retriable.isEmpty {
                ForEach(retriable, id: \.id) { item in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(item.meetingID) · \(item.attempts) attempts")
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)
                            if let error = item.lastError {
                                Text(error)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer()
                        Button("Retry") {
                            Task { await model.retry(item.id) }
                        }
                        .accessibilityLabel("Retry delivery for meeting \(item.meetingID)")
                    }
                }
            }
            HStack {
                Button("Refresh") { Task { await model.refresh() } }
                Spacer()
                // "Retry now": also enabled for merely-PENDING items sitting
                // on a backoff floor — the kick clears all floors and benches
                // so the queue is attempted immediately (the fix for the
                // relaunch-to-retry gap).
                Button("Retry Now") { Task { await model.retryAll() } }
                    .disabled(
                        retriable.isEmpty && snapshot.damagedItems.isEmpty
                            && snapshot.pendingCount == 0
                    )
                    .help("Re-enters failed deliveries (re-checks damaged ones once; superseded items stay closed), clears all backoff, and retries immediately")
            }
        }
    }

    private var stateLabel: String {
        switch snapshot.state {
        case .idle: "Idle — queue empty"
        case .delivering: "Delivering…"
        case .waitingRetry: "Waiting to retry"
        // M-3: the destination-naming states derive their machine name from the
        // active warning's reason, which the worker already classified by
        // destination kind. A local-folder install must never read the SSH
        // remote-destination wording.
        case .allEndpointsDown:
            isLocalDestinationWarning ? "Destination folder unavailable — will retry"
                : "Remote destination unreachable — will retry"
        case .configurationInvalid: "Paused — settings invalid"
        case .authFailure: "SSH key rejected — needs attention"
        case .hostKeyMismatch: "Host key changed — needs attention"
        case .remoteDiskFull:
            isLocalDestinationWarning ? "Destination disk full — needs attention"
                : "Remote destination disk full — needs attention"
        }
    }

    /// True when the active warning's reason is the local-destination shape
    /// (`HandoffWarning.shortReason` derives it from the transport's signature),
    /// so the panel names the folder rather than the remote destination (M-3).
    private var isLocalDestinationWarning: Bool {
        guard let reason = snapshot.warning?.shortReason else { return false }
        return reason == "destination disk full" || reason == "destination folder unavailable"
    }

    private var stateIsAlert: Bool {
        switch snapshot.state {
        case .authFailure, .hostKeyMismatch, .remoteDiskFull, .configurationInvalid: true
        default: false
        }
    }
}

// MARK: - Processing queue panel (F1 Inc2)

private struct ProcessingQueueSection: View {
    @Bindable var model: ProcessingQueueModel
    let snapshot: ProcessingSnapshot

    var body: some View {
        Section("Processing Queue") {
            LabeledContent("State") {
                Text(stateLabel)
                    .foregroundStyle(snapshot.state == .waitingRetry ? .orange : .secondary)
            }
            if snapshot.pendingCount > 0 {
                LabeledContent("Pending") { Text("\(snapshot.pendingCount)").monospacedDigit() }
            }
            Toggle("Pause processing", isOn: Binding(
                get: { model.paused },
                set: { value in Task { await model.setPaused(value) } }))
                .help("Finish the in-flight meeting, then stop processing new ones until resumed.")

            // Failed jobs: retriable, one row each.
            ForEach(model.failedJobs, id: \.id) { job in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(job.meetingID) · \(job.attempts) attempt\(job.attempts == 1 ? "" : "s")")
                            .font(.system(size: 11, design: .monospaced))
                        if let error = job.lastError, !error.isEmpty {
                            Text(error).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer()
                    Button("Retry") { Task { await model.retry(job) } }
                }
            }
            // Live (pending/running) jobs: cancellable.
            ForEach(model.liveJobs, id: \.id) { job in
                HStack {
                    Text("\(job.meetingID) · \(job.state.rawValue)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel", role: .destructive) { Task { await model.cancel(job) } }
                }
            }
            HStack {
                Button("Refresh") { Task { await model.refresh() } }
                Spacer()
                Button("Retry All") { Task { await model.retryAllFailed() } }
                    .disabled(model.failedJobs.isEmpty)
            }
        }
    }

    private var stateLabel: String {
        switch snapshot.state {
        case .idle: return "Idle"
        case .processing: return "Processing…"
        case .pending: return "Queued (\(snapshot.pendingCount))"
        case .waitingRetry: return "\(snapshot.failedCount) failed"
        case .paused: return "Paused"
        }
    }
}

// MARK: - Usage tab

struct UsageTab: View {
    @Environment(AppEnvironment.self) private var appEnv
    @State private var model: UsageModel?
    @State private var ceilingText = ""

    var body: some View {
        Form {
            if let model {
                Section("Cloud Spend") {
                    LabeledContent("Month") { Text(model.monthKey).monospaced() }
                    LabeledContent("Spent") {
                        Text(Self.usd(model.spentUSD))
                            .monospacedDigit()
                    }
                    LabeledContent("Ceiling") {
                        Text(Self.usd(model.ceilingUSD))
                            .monospacedDigit()
                    }
                    if model.warningReached {
                        Label(
                            "Cloud spend has reached 80% of this month's ceiling.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Warning: cloud spend at 80 percent of ceiling")
                    }
                    HStack {
                        TextField("New ceiling (US$)", text: $ceilingText)
                        Button("Set Ceiling") {
                            if let value = Double(ceilingText.replacingOccurrences(of: ",", with: ".")) {
                                Task {
                                    await model.setCeiling(value)
                                    ceilingText = ""
                                }
                            }
                        }
                        .disabled(Double(ceilingText.replacingOccurrences(of: ",", with: ".")) == nil)
                    }
                }

                // G7: line-by-line explanation of the bill.
                Section("This Month's Receipts") {
                    subtotalStrip(model.receipts)
                    reconciliationLine(model.receipts)
                    if model.receipts.receipts.isEmpty {
                        Text("No cloud calls recorded this month.")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    } else {
                        ForEach(model.receipts.receipts, id: \.id) { receipt in
                            receiptRow(receipt, in: model.receipts)
                        }
                    }
                }

                // Manual on-demand refresh (sibling parity with the delivery /
                // processing queues). Spend does not auto-tick live; this is
                // the correctness guarantee regardless of `.task` re-fire.
                HStack {
                    Button("Refresh") { Task { await model.refresh() } }
                        .accessibilityIdentifier("usage-refresh")
                    Spacer()
                }
            }
            Section("Storage") {
                LabeledContent("Data root") {
                    Text(appEnv.database.rootURL.path)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            if model == nil {
                let usage = UsageModel(ledger: appEnv.ledger, settings: appEnv.settings)
                await usage.load()  // load BEFORE publish -> no empty-section flash on first open
                model = usage
            } else {
                await model?.load()  // re-fire (view node recreated) -> refresh
            }
        }
    }

    // MARK: - G7 receipts

    private static func usd(_ value: Double) -> String {
        String(format: "US$ %.2f", value)
    }

    /// "Meetings $0.33 · Regenerations $0.25 · Validation $0.00".
    @ViewBuilder
    private func subtotalStrip(_ month: CloudSpendMonthReceipts) -> some View {
        let parts = month.subtotalsByPurpose.map {
            "\($0.purpose.displayPlural) \(Self.usd($0.totalUSD))"
        }
        Text(parts.joined(separator: " · "))
            .font(.callout)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("cloud-spend-subtotals")
    }

    /// Receipts-sum vs accumulator. A permanent positive delta from
    /// pre-receipts history is labeled honestly.
    @ViewBuilder
    private func reconciliationLine(_ month: CloudSpendMonthReceipts) -> some View {
        if month.reconciles {
            Label(
                "Receipts reconcile with the recorded total (\(Self.usd(month.accumulatorUSD))).",
                systemImage: "checkmark.circle"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        } else {
            let delta = month.reconciliationDeltaUSD
            // A positive delta = accumulator exceeds receipts. Two honest
            // causes (L-2): spend recorded before G7's receipts existed, OR a
            // receipt that could not be written (the isolation path keeps the
            // money on the accumulator but loses the line item).
            let explanation =
                delta > 0
                ? "\(Self.usd(delta)) was spent before receipts existed or where a receipt could not be recorded."
                : "Receipts exceed the recorded total by \(Self.usd(-delta))."
            Label(
                "Receipts \(Self.usd(month.receiptsSumUSD)) vs recorded \(Self.usd(month.accumulatorUSD)) — \(explanation)",
                systemImage: "info.circle"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("cloud-spend-reconciliation")
        }
    }

    @ViewBuilder
    private func receiptRow(_ receipt: CloudSpendReceipt, in month: CloudSpendMonthReceipts) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(month.label(for: receipt))
                    .font(.callout)
                    .lineLimit(1)
                Text("\(receipt.timestamp, format: .dateTime.day().month().hour().minute()) · \(receipt.inputTokens)/\(receipt.outputTokens) tok")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(Self.usd(receipt.costUSD))
                .monospacedDigit()
                .font(.callout)
        }
    }
}
