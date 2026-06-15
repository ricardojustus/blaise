import BlaiseCore
import SwiftUI

// G12 §2 — the two-channel (you / others) in-app level meter that REPLACES the
// static recording indicator, plus its lock-free holder. The capture IOProc
// already touches every buffer; it feeds raw RMS into `LevelMeter` (BlaiseCore,
// pure + unit-pinned) which smooths, caps the publish rate at ≤ 10 Hz, and
// flags ≥ 10 s silence. The holder below carries the published `MeterLevels`
// for SwiftUI; following the Settings-fix / G9 leaf-observation pattern, ONLY
// the meter view reads it, so a level publish can never invalidate the scene
// root (the FB15540812 re-render class the recording timer triggered).

// MARK: - Holder (leaf-observed)

/// The published meter levels. `@Observable`, but read ONLY inside
/// `LevelMeterView.body` — a level publish must invalidate the meter view and
/// nothing higher (never `App.body`, never the Settings scene). This is the
/// audio analog of `CaptureStatusHolder.state` after the recording-tick fix.
@MainActor @Observable
final class LevelMeterHolder {
    /// The latest ≤ 10 Hz published pair; the meter view's sole dependency.
    var levels = MeterLevels()
    /// Cleared to a fresh (silent) pair when recording ends so the toolbar
    /// meter settles to its idle state instead of freezing on the last frame.
    func reset() { levels = MeterLevels() }
}

// MARK: - Meter view

/// Two slim bars — "you" (mic) and "others" (system) — driven by the holder's
/// smoothed RMS. A channel silent ≥ 10 s renders hollow with a warning tint
/// (the "is it hearing me/others?" glance the user asked for; visual, never modal).
/// Reduce Motion swaps the continuous fill for discrete level steps with no
/// pulse animation. The holder read is confined to THIS leaf.
struct LevelMeterView: View {
    var holder: LevelMeterHolder
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            channelBar(label: "You", channel: holder.levels.you)
            channelBar(label: "Others", channel: holder.levels.others)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private func channelBar(label: String, channel: ChannelLevel) -> some View {
        // Hollow + warning tint when the channel has gone silent (the glance);
        // otherwise the accent fill scaled by the smoothed magnitude.
        let tint: Color = channel.silent ? .orange : Design.recording
        VStack(spacing: 2) {
            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    Capsule()
                        .fill(tint.opacity(channel.silent ? 0.18 : 0.22))
                    if !channel.silent {
                        Capsule()
                            .fill(tint)
                            .frame(height: max(2, geo.size.height * fillFraction(channel.level)))
                            // Reduce Motion: snap between discrete steps, no
                            // continuous pulse animation.
                            .animation(reduceMotion ? nil : .linear(duration: 0.1), value: channel.level)
                    }
                }
                .overlay {
                    if channel.silent {
                        // Hollow outline — the "something's wrong" glance.
                        Capsule().stroke(tint.opacity(0.7), lineWidth: 1)
                    }
                }
            }
            .frame(width: 5, height: 18)
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
        }
    }

    /// Reduce Motion quantizes the bar into 4 discrete steps (no smooth pulse);
    /// otherwise the bar fills continuously to the smoothed magnitude.
    private func fillFraction(_ level: Double) -> Double {
        let clamped = min(1, max(0, level))
        guard reduceMotion else { return clamped }
        return (clamped * 4).rounded() / 4
    }

    private var accessibilityLabel: String {
        let you = holder.levels.you.silent ? "silent" : "active"
        let others = holder.levels.others.silent ? "silent" : "active"
        return "Audio levels — you \(you), others \(others)"
    }
}

// MARK: - Menu-bar timer label (§1)

/// The menu-bar recording readout: red-tinted accent glyph + live `MM:SS`
/// timer while recording, the G9 paused accent + accumulated time when paused,
/// the plain glyph otherwise. Tabular digits (`.monospacedDigit()`) keep the
/// menu-bar item fixed-width as the timer rolls; `.contentTransition` rolls the
/// digits and is the only motion (delight budget). The state read is confined
/// to THIS leaf (the recording-tick isolation pattern).
struct RecordingTimerLabel: View {
    let state: IndicatorState

    // Leaf-local 1 Hz clock. The live seconds readout is driven by ticking THIS
    // @State once a second from a lifecycle-managed `.task` — deliberately NOT a
    // TimelineView. A TimelineView inside the MenuBarExtra label snapshots into
    // the NSStatusItem on a SYNCHRONOUS update path with no run-loop coalescing;
    // with `from: .now` (re-evaluated on every render) its schedule input
    // changed on every pass, leaving the status item perpetually dirty and
    // spinning updateButton → layout → requestUpdate in an infinite loop at
    // launch (the hang-on-open crash, 14/06). `@State` here is leaf-local and
    // observed ONLY by this always-alive label, so a tick re-renders just this
    // glyph — never App.body (preserving the field-bug-12/06 invariant). The
    // task runs ONLY while the readout actually advances (recording/warning);
    // idle/processing/grace/alarm are static glyphs and paused shows a fixed
    // accumulated time, so none of them mount a ticking clock.
    @State private var now = Date()

    private var isTicking: Bool {
        switch state {
        case .recording, .warning: return true
        default: return false
        }
    }

    var body: some View {
        content
            .task(id: isTicking) {
                guard isTicking else { return }
                while !Task.isCancelled {
                    now = Date()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch RecordingTimerModel.display(for: state, now: now) {
        case .glyph:
            RecordingMenuBarLabel(state: state)
        case .recording(let formatted):
            Label {
                Text(formatted)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            } icon: {
                Image(systemName: "record.circle")
                    .foregroundStyle(Color(red: 0.92, green: 0.32, blue: 0.32))
            }
        case .paused(let formatted):
            Label {
                Text(formatted).monospacedDigit()
            } icon: {
                Image(systemName: "pause.circle.fill")
                    .foregroundStyle(Theme.accent)
            }
        }
    }
}
