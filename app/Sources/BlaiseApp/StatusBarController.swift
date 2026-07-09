import AppKit
import BlaiseCore
import Observation
import SwiftUI

/// The menu-bar indicator + menu, hosted in AppKit rather than SwiftUI's
/// `MenuBarExtra`. `MenuBarExtra` proved unfit for LIVE content: a
/// `TimelineView(.now)` in the status-item label spun an infinite
/// updateButton/requestUpdate render loop at launch, and opening the dropdown
/// during recording recursed `MenuBehavior.menuHostDidChangeMenuItems` ~46k
/// levels into a stack-overflow crash. This drives the status item
/// IMPERATIVELY — a plain template `NSImage` glyph + an `NSStatusItem.button`
/// title updated by a `RunLoop` timer — and hosts the existing SwiftUI
/// `RecordingMenuView` in an `NSPopover` via `NSHostingController`. There is no
/// `MenuBarExtra` and no `NSMenu`, so none of those render-loop code paths
/// exist.
@MainActor
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private unowned let environment: AppEnvironment
    /// The 1 Hz elapsed-text tick. Runs ONLY while the readout advances
    /// (recording/warning); idle/processing/grace/alarm/paused are static.
    private var tick: Timer?

    init(environment: AppEnvironment) {
        self.environment = environment
        // `.variableLength` so the item grows for the elapsed text. MUST be
        // retained (this stored property) or the system drops the item.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        popover.behavior = .transient          // click-away dismiss, menu-like
        popover.animates = false
        // The dropdown is our existing SwiftUI view. The SwiftUI environment
        // does NOT cross the AppKit hosting boundary, so AppEnvironment is
        // injected explicitly; window-opening is routed through AppEnvironment
        // (the `\.openWindow` action is unavailable here).
        popover.contentViewController = NSHostingController(
            rootView: RecordingMenuView().environment(environment))

        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .regular)
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        render()
        observe()
        observeWindowRequests()
    }

    // No deinit: the controller is retained for the app's lifetime, the
    // repeating tick weakly captures self (no retain cycle), and the OS reclaims
    // the status item at process exit. (A nonisolated deinit also cannot touch
    // the main-actor-isolated `tick` under Swift 6 strict concurrency.)

    // MARK: - Imperative label

    /// Set the glyph + elapsed text from the current state. No SwiftUI lives in
    /// the label, so there is no diffing pass to stall (the frozen-ticker bug)
    /// and nothing that can drive an updateButton loop (the launch-hang bug).
    private func render() {
        guard let button = statusItem.button else { return }
        let state = environment.captureStatus.state
        let warning = environment.handoffStatus.snapshot.warning != nil
        button.image = Self.glyph(for: state, handoffWarning: warning)

        switch RecordingTimerModel.display(for: state, now: Date()) {
        case .glyph:
            if case .idle = state, !warning,
                let upcoming = Self.upcomingTitle(environment.calendarSuggestions.upcomingRows)
            {
                button.title = " \(upcoming)"
            } else {
                button.title = ""
            }
        case .recording(let formatted), .paused(let formatted):
            button.title = " \(formatted)"
        }
        button.toolTip = Self.upcomingTooltip(environment.calendarSuggestions.upcomingRows)

        // Tick only while the elapsed readout actually advances.
        switch state {
        case .recording, .warning: startTick()
        default: stopTick()
        }
    }

    private func startTick() {
        guard tick == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
        timer.tolerance = 0.1
        // `.common` so it keeps firing while the popover/menu tracking runloop
        // is active — otherwise the elapsed text would freeze while open.
        RunLoop.main.add(timer, forMode: .common)
        tick = timer
    }

    private func stopTick() {
        tick?.invalidate()
        tick = nil
    }

    // MARK: - State observation (immediate glyph on transitions)

    /// Re-render immediately when the indicator state or the handoff warning
    /// changes (so the glyph flips the instant recording starts/stops, not up
    /// to a second later). `withObservationTracking` is one-shot, so it re-arms
    /// itself after each change.
    private func observe() {
        withObservationTracking {
            _ = environment.captureStatus.state
            _ = environment.handoffStatus.snapshot.warning
            _ = environment.calendarSuggestions.upcomingRows
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.render()
                self.observe()
            }
        }
    }

    /// The popover's "Open Blaise" / a clicked notification bump
    /// `uiState.openMainWindowRequest`; bring the main window forward via AppKit
    /// (the popover can't use SwiftUI's `\.openWindow`). One-shot tracking,
    /// re-armed after each request.
    private func observeWindowRequests() {
        withObservationTracking {
            _ = environment.uiState.openMainWindowRequest
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.showMainWindow()
                self.observeWindowRequests()
            }
        }
    }

    private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        // Raise the EXACT main window captured by WindowAccessor — never a
        // heuristic NSApp.windows match (which could front Settings or another
        // window), and never the popover's own window (touching its view here
        // would also force the popover's SwiftUI tree to load offscreen). If the
        // main window was fully closed (WindowGroup torn down) the weak ref is
        // nil and we no-op — the accepted v1 limitation.
        environment.mainWindow?.makeKeyAndOrderFront(nil)
        closeMenu()
    }

    // MARK: - Popover

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// Dismiss the popover (called after a menu action that navigates away).
    func closeMenu() { popover.performClose(nil) }

    // MARK: - Glyph mapping (ported from the former RecordingMenuBarLabel)

    /// The SF Symbol name for the menu-bar glyph. Pure + unit-testable.
    ///
    /// The handoff-warning badge overrides the glyph ONLY in the genuinely-quiet
    /// states; it must NEVER mask `.recording`, `.warning`, or `.alarm`. In
    /// particular an `.alarm` glyph is a post-stop capture failure ("recording
    /// may be lost") and is load-bearing — burying it behind a handoff badge
    /// would hide a lost-recording state. This matches the pre-AppKit label's
    /// precedence and deliberately does NOT use `RecordingTimerModel.isQuietState`,
    /// which classifies `.alarm`/`.paused` differently than this glyph needs.
    static func symbolName(for state: IndicatorState, handoffWarning: Bool) -> String {
        let handoffBadgeAllowed: Bool
        switch state {
        case .idle, .processing, .grace, .paused: handoffBadgeAllowed = true
        case .recording, .warning, .alarm: handoffBadgeAllowed = false
        }
        if handoffWarning, handoffBadgeAllowed { return "exclamationmark.triangle" }
        switch state {
        case .idle: return "waveform.circle"
        case .recording: return "record.circle"
        case .warning: return "exclamationmark.circle"
        case .alarm: return "exclamationmark.triangle.fill"
        case .processing: return "arrow.triangle.2.circlepath.circle"
        case .grace: return "pause.circle"
        case .paused: return "pause.circle.fill"
        }
    }

    static func glyph(for state: IndicatorState, handoffWarning: Bool = false) -> NSImage? {
        let name = symbolName(for: state, handoffWarning: handoffWarning)
        // Tint the load-bearing states so "am I recording / did it fail?" reads
        // at a glance; everything else is a template glyph (adapts to light/dark).
        let color: NSColor?
        switch name {
        case "record.circle": color = .systemRed
        case "exclamationmark.circle", "exclamationmark.triangle", "exclamationmark.triangle.fill":
            color = .systemOrange
        case "pause.circle.fill": color = .controlAccentColor
        default: color = nil
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Blaise status")
        if let color {
            return image?.withSymbolConfiguration(.init(paletteColors: [color]))
        }
        image?.isTemplate = true
        return image
    }

    static func upcomingTitle(_ rows: [UpcomingMeetingRow], now: Date = Date()) -> String? {
        guard let row = rows.first(where: { $0.end > now }) else { return nil }
        let title = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = title.isEmpty ? "Meeting" : title
        let compactTitle = displayTitle.count > 18 ? String(displayTitle.prefix(17)) + "…" : displayTitle
        return "\(time(row.start)) \(compactTitle)"
    }

    static func upcomingTooltip(_ rows: [UpcomingMeetingRow], now: Date = Date()) -> String? {
        guard let row = rows.first(where: { $0.end > now }) else { return "Blaise" }
        let title = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Next meeting: \(title.isEmpty ? "Meeting" : title) at \(time(row.start))"
    }

    private static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

/// Captures the hosting `NSWindow` of a SwiftUI view once it's attached, so the
/// AppKit status-bar controller can raise the EXACT main window rather than a
/// heuristic `NSApp.windows` match. Attach via `.background(WindowAccessor { … })`
/// on the main window's root content.
struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window { onResolve(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            if let window = nsView?.window { onResolve(window) }
        }
    }
}
