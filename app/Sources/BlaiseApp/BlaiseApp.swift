import BlaiseCore
import SwiftUI
import UniformTypeIdentifiers

// C10 app shell: the real app surface (D16 Direction A), replacing the C1
// placeholder window. Dark-first, one quiet accent, restrained Liquid Glass.

/// C11: quit-during-recording intercept — quitting mid-capture runs the
/// SAME stop+encode path as a manual stop (the CAFs are crash-safe either
/// way; this just finishes the job now instead of at next launch's sweep).
///
/// G9: a `paused` meeting counts as open — quitting offers a dialog
/// ("End & process, or quit and keep it paused?"). Quitting keeps the state
/// (the paused row is durable); relaunch surfaces the paused meeting with
/// Resume / End & process.
final class BlaiseAppDelegate: NSObject, NSApplicationDelegate {
    weak var environment: AppEnvironment?
    /// The AppKit menu-bar indicator + recording menu (NSStatusItem + NSPopover),
    /// replacing SwiftUI's MenuBarExtra. Retained for the app's lifetime; created
    /// once after launch.
    private var statusBar: StatusBarController?

    @MainActor func installStatusBar(_ environment: AppEnvironment) {
        guard statusBar == nil else { return }
        statusBar = StatusBarController(environment: environment)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let environment else { return .terminateNow }
        let controller = environment.recordingController
        Task {
            // Ask the CONTROLLER, not the UI mirror: a quit inside the
            // start window would read a stale mirror and terminate without
            // stopping the brand-new session.
            if await controller.isRecording {
                _ = try? await controller.stop()
            } else if let pausedID = await controller.pausedMeetingID() {
                // G9: a paused meeting is open. Ask whether to End & process
                // it now or quit and keep it paused. Quitting preserves the
                // durable `paused` row either way.
                let endNow = await MainActor.run {
                    Self.askEndOrKeepPaused()
                }
                if endNow {
                    _ = try? await controller.endPaused(meetingID: pausedID)
                }
            }
            // A MANUAL stop may already be encoding (state .processing, not
            // recording): termination waits for any in-flight finalization,
            // not just its own stop — quitting mid-encode would orphan the
            // CAFs until the next launch's sweep.
            await controller.awaitQuiescence()
            await MainActor.run {
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    /// The paused-quit dialog. Returns true if the user chose End & process.
    @MainActor
    private static func askEndOrKeepPaused() -> Bool {
        let alert = NSAlert()
        alert.messageText = "A meeting is paused"
        alert.informativeText = "End & process it, or quit and keep it paused?"
        alert.addButton(withTitle: "End & Process")
        alert.addButton(withTitle: "Quit & Keep Paused")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

@main
struct BlaiseApplication: App {
    /// Composition root — built once; a failure to open the database is
    /// unrecoverable and surfaced in a minimal window.
    @State private var environment: AppEnvironment?
    @State private var startupError: String?
    @State private var started = false
    @NSApplicationDelegateAdaptor(BlaiseAppDelegate.self) private var appDelegate

    init() {
        do {
            let environment = try AppEnvironment()
            _environment = State(initialValue: environment)
        } catch {
            _startupError = State(initialValue: "\(error)")
        }
    }

    var body: some Scene {
        WindowGroup("Blaise", id: "main") {
            if let environment {
                MainWindow()
                    .environment(environment)
                    .environment(environment.uiState)
                    .environment(environment.library)
                    .environment(environment.activity)
                    .environment(environment.handoffStatus)
                    .environment(environment.listenerStatus)
                    .preferredColorScheme(.dark)
                    .tint(Theme.accent)
                    // Design is runtime-switchable (View ▸ Design): re-root
                    // the window on change so every token and structural
                    // switch re-resolves. Rare action; the models live in
                    // AppEnvironment and survive (the `started` guard keeps
                    // start() one-shot).
                    .id(DesignSelection.shared.direction)
                    .task {
                        guard !started else { return }
                        started = true
                        appDelegate.environment = environment
                        // The menu-bar indicator is AppKit-hosted (NSStatusItem
                        // + NSPopover), installed after launch — SwiftUI's
                        // MenuBarExtra was unfit for the live ticker/meter.
                        appDelegate.installStatusBar(environment)
                        await environment.start()
                    }
            } else {
                VStack(spacing: 10) {
                    Text("Blaise could not start")
                        .font(.title2.bold())
                    Text(startupError ?? "unknown error")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(40)
                .frame(minWidth: 420, minHeight: 200)
            }
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(after: .newItem) {
                if let environment {
                    Button("Import Meeting Audio…") {
                        environment.uiState.importSourceURL = nil
                        ImportPanel.present(uiState: environment.uiState)
                    }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                }
            }
            CommandGroup(after: .textEditing) {
                if let environment {
                    Button("Search Meetings") {
                        environment.uiState.searchFocusRequest += 1
                    }
                    .keyboardShortcut("f", modifiers: .command)
                }
            }
            // View ▸ Design: the four visual directions, switchable live and
            // persisted (BLAISE_DESIGN_DIRECTION still overrides at launch
            // for the capture harness).
            CommandGroup(after: .sidebar) {
                Picker(
                    "Design",
                    selection: Binding(
                        get: { DesignSelection.shared.direction },
                        set: { DesignSelection.shared.direction = $0 })
                ) {
                    ForEach(DesignDirection.allCases, id: \.self) { direction in
                        Text(direction.displayName).tag(direction)
                    }
                }
            }
            // C11: in-app/menu-scoped ⌥⌘R (a GLOBAL hotkey needs another
            // TCC class — BACKLOG).
            CommandGroup(after: .toolbar) {
                if let environment {
                    // The `isRecording` read lives in this child view, NOT the
                    // scene builder: reading it here would register `App.body`
                    // as a dependency of `captureStatus.state`, so every
                    // recording tick would re-create the sibling `Settings`
                    // TabView (field bug 12/06). The child re-renders alone.
                    RecordingMenuCommandButton()
                        .environment(environment)
                }
            }
        }

        // C11/G12: the menu-bar indicator + recording menu are AppKit-hosted in
        // StatusBarController (NSStatusItem + NSPopover), installed by the app
        // delegate after launch. SwiftUI's MenuBarExtra spun an infinite render
        // loop with the live ticker and stack-overflowed when the dropdown was
        // opened during recording; see notes/menubar-live-content.md.

        Settings {
            if let environment {
                SettingsRootView()
                    .environment(environment)
                    .preferredColorScheme(.dark)
                    .tint(Theme.accent)
                    .id(DesignSelection.shared.direction)  // live design switch
            }
        }
    }
}

/// The library window plus the import sheet + drag-drop entry.
struct MainWindow: View {
    @Environment(AppEnvironment.self) private var appEnv
    @Environment(AppUIState.self) private var uiState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var uiState = uiState
        LibraryView()
            .frame(minWidth: 1100, minHeight: 640)
            // Capture this window so the AppKit StatusBarController can raise the
            // EXACT main window for "Open Blaise" / notification routing (the
            // popover can't use SwiftUI's openWindow). Fully-closed-window reopen
            // remains the accepted v1 limitation.
            .background(WindowAccessor { appEnv.mainWindow = $0 })
            .task {
                // Screenshot scaffolding (active only under --seed-demo).
                if CommandLine.arguments.contains("--seed-demo") {
                    // Pin the window to the evidence size (saved state may
                    // restore a different frame).
                    try? await Task.sleep(for: .milliseconds(400))
                    if let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }) {
                        window.setContentSize(NSSize(width: 1440, height: 900))
                        window.center()
                        // The motion capture records the SCREEN rect (not a
                        // composited window): the window must be frontmost.
                        NSApp.activate(ignoringOtherApps: true)
                        window.makeKeyAndOrderFront(nil)
                    }
                    if ["settings", "cloud-spend", "settings-handoff"].contains(
                        ProcessInfo.processInfo.environment["BLAISE_DEMO_SCENE"] ?? "")
                    {
                        try? await Task.sleep(for: .seconds(1))
                        openSettings()
                    }
                }
                // G3 onboarding auto-offer: once per launch, only when no
                // identity is stored yet. Never under --seed-demo (which seeds
                // an explicit identity). BLAISE_DEMO_SCENE=onboarding forces it
                // for screenshot evidence.
                await offerOnboardingIfNeeded()
            }
            .sheet(isPresented: $uiState.showOnboarding) {
                OnboardingSheet(
                    settings: appEnv.settings, secrets: appEnv.secrets,
                    onFinish: { name in
                        uiState.showOnboarding = false
                        // Reflect the just-entered identity into the live
                        // self-exclusion email used by calendar suggestions.
                        appEnv.applyOnboardedIdentity()
                        _ = name
                    },
                    onSkip: { uiState.showOnboarding = false })
            }
            .sheet(
                isPresented: Binding(
                    get: { uiState.importSourceURL != nil },
                    set: { if !$0 { uiState.importSourceURL = nil } })
            ) {
                if let url = uiState.importSourceURL {
                    ImportSheet(sourceURL: url) {
                        uiState.importSourceURL = nil
                    }
                }
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                guard let provider = providers.first else { return false }
                let state = uiState
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard
                        let url,
                        ["wav", "m4a"].contains(url.pathExtension.lowercased())
                    else { return }
                    Task { @MainActor in
                        state.importSourceURL = url
                    }
                }
                return true
            }
    }

    /// Raise the onboarding sheet at most once per launch, only when the
    /// stored identity is empty. `--seed-demo` seeds an explicit identity, so
    /// the empty check naturally suppresses it there; the
    /// `BLAISE_DEMO_SCENE=onboarding` override forces it for screenshots.
    private func offerOnboardingIfNeeded() async {
        guard !uiState.onboardingOffered else { return }
        uiState.onboardingOffered = true
        let forced = ProcessInfo.processInfo.environment["BLAISE_DEMO_SCENE"] == "onboarding"
        if forced {
            uiState.showOnboarding = true
            return
        }
        let identity =
            (try? await appEnv.settings.get(UserIdentity.settingsKey, as: UserIdentity.self))
            ?? nil ?? .shippedDefault
        if identity.isEmpty {
            uiState.showOnboarding = true
        }
    }
}

/// G3 first-launch onboarding: writes the user's identity so they become
/// "the user" the way the user is today. Skippable (the app works unnamed — mic
/// track labels "You", the action-items section renders "My action items");
/// the same fields live in Settings → Identity, so completing here is exactly
/// equivalent to a Settings edit. Re-offerable from Settings, never nagging.
struct OnboardingSheet: View {
    @State private var model: IdentityModel
    let onFinish: (String) -> Void
    let onSkip: () -> Void

    init(
        settings: SettingsStore, secrets: any SecretStore,
        onFinish: @escaping (String) -> Void, onSkip: @escaping () -> Void
    ) {
        _model = State(initialValue: IdentityModel(settings: settings, secrets: secrets))
        self.onFinish = onFinish
        self.onSkip = onSkip
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to Blaise")
                    .font(.title2.weight(.semibold))
                Text("Tell Blaise who you are so it can mark your speech and pull out the action items that are yours.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                TextField("Your name", text: $model.name)
                    .textFieldStyle(.roundedBorder)
                TextField("Nicknames (optional, comma-separated)", text: $model.aliasesText)
                    .textFieldStyle(.roundedBorder)
                TextField("Email (optional)", text: $model.email)
                    .textFieldStyle(.roundedBorder)
                Text("Email matches you in calendar invites.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Later") { onSkip() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Get Started") {
                    let name = model.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task {
                        await model.save()
                        await MainActor.run { onFinish(name) }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(28)
        .frame(width: 440)
        .accessibilityLabel("Identity onboarding")
    }
}

/// NSOpenPanel wrapper for the File-menu command (WAV/M4A only).
@MainActor
enum ImportPanel {
    static func present(uiState: AppUIState) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = UTType.blaiseImportable
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a WAV or M4A recording to import"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                uiState.importSourceURL = url
            }
        }
    }
}
