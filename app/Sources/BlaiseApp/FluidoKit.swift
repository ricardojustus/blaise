import AppKit
import BlaiseCore
import Combine
import SwiftUI

// Estúdio Fluido (design v3): the motion layer. Everything here follows one
// law — fluidity is continuity + physics, not quantity of animation:
//   • elements persist between states; a surviving component never
//     re-animates;
//   • springs everywhere, interruptible, < 300–400 ms, transform+opacity only;
//   • delight budget inversely proportional to frequency — selection and
//     scrolling stay instant, the particles fire only on rare moments;
//   • Reduce Motion substitutes fades for movement throughout.
// (The v3 floating Liquid Glass recording pill was removed after the user's
// review — recording state lives in the toolbar chip, like the other
// directions; see git history for the pill.)

// MARK: - Living mesh background

/// A slow-drifting dark 3×3 MeshGradient behind the reading pane: the center
/// control point orbits on two incommensurate periods so the field never
/// visibly loops. While recording the field warms — the same geometry leaning
/// toward coral — so the app's most important state is ambient, not loud.
/// Very low contrast by design: it lives BEHIND `.ultraThinMaterial` cards.
struct FluidoMeshBackground: View {
    @Environment(AppEnvironment.self) private var appEnv
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Eased warmth (0 cool … 1 recording), hand-animated inside the
    /// TimelineView so the hue shift glides over ~2 s without re-render
    /// machinery beyond the frames the mesh already draws.
    @State private var warmAnchor: (start: Date, from: Double, to: Double) = (.distantPast, 0, 0)
    /// Nobody is looking: every window occluded or the app hidden
    /// (NSApplication occlusion state). The 20 Hz drift pauses — the mesh
    /// holds its last frame and resumes when the app becomes visible again.
    @State private var occluded = false

    var body: some View {
        let recording = appEnv.captureStatus.isRecording
        TimelineView(
            .animation(minimumInterval: 1.0 / 20.0, paused: reduceMotion || occluded)
        ) { timeline in
            mesh(date: timeline.date)
        }
        .onChange(of: recording, initial: true) { _, nowRecording in
            let now = Date()
            let current = warmth(at: now)
            warmAnchor = (now, current, nowRecording ? 1 : 0)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didChangeOcclusionStateNotification)
        ) { _ in
            occluded = !NSApp.occlusionState.contains(.visible)
        }
        .onAppear {
            occluded = !NSApp.occlusionState.contains(.visible)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private func warmth(at date: Date) -> Double {
        let progress = min(max(date.timeIntervalSince(warmAnchor.start) / 2.0, 0), 1)
        let eased = progress * progress * (3 - 2 * progress)  // smoothstep
        return warmAnchor.from + (warmAnchor.to - warmAnchor.from) * eased
    }

    private func mesh(date: Date) -> some View {
        let t = reduceMotion ? 0.0 : date.timeIntervalSinceReferenceDate
        let w = warmth(at: date)
        // Center orbit + gentle edge drift (positions only — cheap).
        let cx = Float(0.50 + 0.20 * sin(t * 0.110))
        let cy = Float(0.48 + 0.18 * cos(t * 0.073))
        let points: [SIMD2<Float>] = [
            [0, 0], [Float(0.5 + 0.06 * sin(t * 0.050)), 0], [1, 0],
            [0, Float(0.5 + 0.07 * cos(t * 0.061))], [cx, cy],
            [1, Float(0.5 + 0.05 * sin(t * 0.083))],
            [0, 1], [Float(0.5 - 0.06 * sin(t * 0.047)), 1], [1, 1],
        ]
        return MeshGradient(width: 3, height: 3, points: points, colors: meshColors(warmth: w))
    }

    /// Estúdio's depth field as mesh control colors — ink blues with a cyan
    /// bloom up top and violet rising from below — lerped toward a warm
    /// coral-leaning variant while recording.
    private func meshColors(warmth: Double) -> [Color] {
        // (cool, warm) RGB pairs per control point, row-major.
        let pairs: [(SIMD3<Double>, SIMD3<Double>)] = [
            (.init(0.062, 0.082, 0.118), .init(0.105, 0.072, 0.092)),  // top-leading cyan hint
            (.init(0.052, 0.068, 0.102), .init(0.092, 0.062, 0.080)),
            (.init(0.045, 0.058, 0.090), .init(0.085, 0.056, 0.072)),
            (.init(0.048, 0.060, 0.095), .init(0.090, 0.058, 0.078)),
            (.init(0.075, 0.082, 0.140), .init(0.130, 0.072, 0.105)),  // center: deepest bloom
            (.init(0.058, 0.056, 0.112), .init(0.105, 0.060, 0.090)),  // violet rise
            (.init(0.040, 0.050, 0.076), .init(0.078, 0.050, 0.064)),
            (.init(0.052, 0.052, 0.098), .init(0.095, 0.055, 0.080)),  // bottom violet
            (.init(0.045, 0.052, 0.085), .init(0.082, 0.052, 0.070)),
        ]
        return pairs.map { cool, warm in
            let c = cool + (warm - cool) * warmth
            return Color(red: c.x, green: c.y, blue: c.z)
        }
    }
}

// MARK: - Card physics (hover lift + tilt, pressed scale)

/// Craft-style card life: a slight lift and a few degrees of tilt toward the
/// cursor corner on hover, shadow deepening underneath. The tilt follows the
/// pointer directly (no animation lag); enter/exit settle on a spring.
/// Disabled wholesale under Reduce Motion (the shadow change stays).
struct FluidoCardPhysics: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    /// Pointer position in unit space (0…1), for the tilt direction.
    @State private var unitPoint = UnitPoint.center
    @State private var size = CGSize(width: 1, height: 1)

    private var maxTilt: Double { reduceMotion ? 0 : 2.4 }

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { newSize in
                size = newSize
            }
            .scaleEffect(hovering && !reduceMotion ? 1.012 : 1.0)
            .rotation3DEffect(
                .degrees(hovering ? -(unitPoint.y - 0.5) * maxTilt : 0), axis: (x: 1, y: 0, z: 0))
            .rotation3DEffect(
                .degrees(hovering ? (unitPoint.x - 0.5) * maxTilt : 0), axis: (x: 0, y: 1, z: 0))
            .shadow(
                color: .black.opacity(hovering ? 0.35 : 0.16),
                radius: hovering ? 14 : 5, y: hovering ? 7 : 2)
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    if !hovering {
                        withAnimation(.smooth(duration: 0.22)) { hovering = true }
                    }
                    unitPoint = UnitPoint(
                        x: min(max(location.x / max(size.width, 1), 0), 1),
                        y: min(max(location.y / max(size.height, 1), 0), 1))
                case .ended:
                    withAnimation(.smooth(duration: 0.3)) {
                        hovering = false
                        unitPoint = .center
                    }
                }
            }
    }
}

/// Pressed-state physics for the meeting cards: 0.98 scale on a snappy,
/// interruptible spring. Selection itself stays instant.
struct FluidoCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

// MARK: - Shimmer (loading / transcribing rows)

/// A hand-rolled mask shimmer: content sits at ~60 % alpha with a brighter
/// band sweeping across — the universal "working on it" idiom, one modifier,
/// no dependency. Static (full alpha) under Reduce Motion.
struct FluidoShimmer: ViewModifier {
    var active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        if active && !reduceMotion {
            content
                .mask {
                    GeometryReader { proxy in
                        let width = proxy.size.width
                        Rectangle()
                            .fill(.white.opacity(0.55))
                            .overlay {
                                LinearGradient(
                                    colors: [.clear, .white, .clear],
                                    startPoint: .leading, endPoint: .trailing
                                )
                                .frame(width: width * 0.6)
                                .offset(x: -width * 0.6 + phase * (width + width * 0.6))
                            }
                    }
                }
                .onAppear {
                    phase = 0
                    withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                        phase = 1
                    }
                }
        } else {
            content
        }
    }
}

// MARK: - Header settle (selection entrance)

/// The detail header settles into place on selection: a small rise (6 pt) +
/// fade + 0.985 scale on a smooth spring, ~300 ms. (A full card→header
/// `matchedGeometryEffect` morph was built first and toned down to this on
/// the user's review — the cross-column geometry flight read as weird.)
/// One-shot per selection — returning from the Transcript tab must NOT
/// replay it (a surviving component never re-animates). Under Reduce Motion
/// it reduces to a plain fade.
struct FluidoHeaderSettle: ViewModifier {
    /// One-shot arm owned by the enclosing detail view (reset per selection).
    @Binding var armed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settling = false

    func body(content: Content) -> some View {
        content
            .opacity(settling ? 0 : 1)
            .scaleEffect(settling && !reduceMotion ? 0.985 : 1, anchor: .topLeading)
            .offset(y: settling && !reduceMotion ? 6 : 0)
            .onAppear {
                guard armed else { return }
                armed = false
                settling = true
                withAnimation(.smooth(duration: 0.3)) { settling = false }
            }
    }
}

// MARK: - user-action box celebration (the one big effect — earned, rare)

/// Completing the LAST open user action item of a meeting fires one sparkle
/// burst over the user-action box — Estúdio-palette particles, ~2 s, never on any
/// other path. Hand-rolled Canvas particles (Vortex 1.0.4 was dropped: its
/// asset catalog needs actool, blocked by this machine's unaccepted Xcode
/// license). The overlay exists only WHILE bursting — zero cost otherwise.
/// Suppressed under Reduce Motion.
struct FluidoUserActionCelebration<Content: View>: View {
    let openCount: Int
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var burstStart: Date?

    var body: some View {
        content
            .overlay {
                if let burstStart {
                    FluidoSparkleBurst(start: burstStart)
                        .padding(-46)  // let particles overflow the box edges
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .onChange(of: openCount) { previous, current in
                guard previous > 0, current == 0, !reduceMotion else { return }
                burstStart = Date()
                Task {
                    try? await Task.sleep(for: .seconds(FluidoSparkleBurst.duration + 0.2))
                    burstStart = nil  // tear the TimelineView down again
                }
            }
    }
}

/// One ballistic particle burst: ~70 cyan/violet/white sparks and squares
/// thrown from the box's upper middle, falling under gravity, fading out.
/// Pure Canvas + TimelineView; mounted only for `duration` seconds.
struct FluidoSparkleBurst: View {
    let start: Date
    static let duration: Double = 2.0

    private struct Particle {
        var origin: CGPoint  // unit space
        var velocity: CGVector  // points/s
        var color: Color
        var size: CGFloat
        var spin: Double  // rad/s
        var lifespan: Double
        var isSquare: Bool
    }

    private let particles: [Particle] = {
        var generator = SystemRandomNumberGenerator()
        let palette: [Color] = [
            Color(red: 0.36, green: 0.85, blue: 0.92),  // electric cyan
            Color(red: 0.57, green: 0.51, blue: 0.97),  // violet
            Color(white: 0.95),
        ]
        return (0..<70).map { index in
            let angle = Double.random(in: 0..<(2 * .pi), using: &generator)
            let speed = Double.random(in: 70...300, using: &generator)
            return Particle(
                origin: CGPoint(
                    x: 0.5 + .random(in: -0.04...0.04, using: &generator), y: 0.32),
                velocity: CGVector(
                    dx: cos(angle) * speed, dy: sin(angle) * speed - 60),
                color: palette[index % palette.count],
                size: .random(in: 4...8, using: &generator),
                spin: .random(in: -7...7, using: &generator),
                lifespan: .random(in: 1.1...duration, using: &generator),
                isSquare: index % 3 == 0)
        }
    }()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 40.0)) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSince(start)
                guard t >= 0, t < Self.duration else { return }
                let gravity = 320.0  // points/s²
                for particle in particles {
                    let life = t / particle.lifespan
                    guard life < 1 else { continue }
                    let x = particle.origin.x * size.width + particle.velocity.dx * t
                    let y =
                        particle.origin.y * size.height + particle.velocity.dy * t
                        + 0.5 * gravity * t * t
                    let fade = 1 - life * life  // ease-out fade
                    var layer = context
                    layer.opacity = fade
                    layer.translateBy(x: x, y: y)
                    layer.rotate(by: .radians(particle.spin * t))
                    let rect = CGRect(
                        x: -particle.size / 2, y: -particle.size / 2,
                        width: particle.size, height: particle.size)
                    if particle.isSquare {
                        layer.fill(
                            RoundedRectangle(cornerRadius: 1.5).path(in: rect),
                            with: .color(particle.color))
                    } else {
                        layer.fill(Circle().path(in: rect), with: .color(particle.color))
                    }
                }
            }
        }
    }
}
