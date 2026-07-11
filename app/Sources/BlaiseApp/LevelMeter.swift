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

/// Two compact horizontal meters — microphone and call audio — driven by the
/// holder's smoothed RMS through a perceptual dB scale. A channel silent ≥ 10 s
/// renders hollow with a warning tint (the "is it hearing me/others?" glance;
/// visual, never modal). The raw RMS remains untouched for silence detection.
/// The holder read is confined to THIS leaf.
struct LevelMeterView: View {
    var holder: LevelMeterHolder
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            MeterChannelBar(
                label: "Microphone", systemImage: "mic.fill",
                channel: holder.levels.you, reduceMotion: reduceMotion)
            MeterChannelBar(
                label: "Call audio", systemImage: "speaker.wave.2.fill",
                channel: holder.levels.others, reduceMotion: reduceMotion)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let you = holder.levels.you.silent ? "silent" : "active"
        let others = holder.levels.others.silent ? "silent" : "active"
        return "Audio levels — you \(you), others \(others)"
    }
}

/// Stateful leaf for one channel. Rising audio uses a fast attack so speech is
/// visible immediately; falling audio decays more slowly so the level remains
/// readable instead of flickering between capture buffers.
private struct MeterChannelBar: View {
    let label: String
    let systemImage: String
    let channel: ChannelLevel
    let reduceMotion: Bool
    @State private var displayedFraction = 0.0

    var body: some View {
        let tint: Color = channel.silent ? .orange : Design.recording
        HStack(spacing: 4) {
            Image(systemName: channel.silent ? "exclamationmark" : systemImage)
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(channel.silent ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                .frame(width: 11)
                .accessibilityHidden(true)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(tint.opacity(channel.silent ? 0.12 : 0.18))
                    if !channel.silent {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [tint.opacity(0.72), tint],
                                    startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(2, geometry.size.width * displayedFraction))
                    }
                }
                .overlay {
                    Capsule().stroke(tint.opacity(channel.silent ? 0.72 : 0.2), lineWidth: 0.75)
                }
            }
            .frame(width: 32, height: 5)
        }
        .accessibilityLabel("\(label) level")
        .accessibilityValue(channel.silent ? "silent" : "\(Int(displayedFraction * 100)) percent")
        .onChange(of: channel.level, initial: true) { _, newLevel in
            let mapped = LevelMeterPresentation.fraction(rms: newLevel)
            let target = reduceMotion ? (mapped * 5).rounded() / 5 : mapped
            guard !reduceMotion else {
                displayedFraction = target
                return
            }
            withAnimation(.linear(duration: target >= displayedFraction ? 0.08 : 0.34)) {
                displayedFraction = target
            }
        }
    }
}
