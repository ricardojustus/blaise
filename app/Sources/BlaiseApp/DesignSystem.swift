import BlaiseCore
import SwiftUI

// PROPOSALS_V2/V3 design exploration: four fully-realized visual directions
// over the unchanged D16 information architecture (NavigationSplitView,
// day-grouped list, reading pane). The direction is switchable at runtime
// (View ▸ Design) and persists across launches; the capture harness keeps
// its deterministic launch override:
//
//   BLAISE_DESIGN_DIRECTION = caderno | estudio | aquarela | fluido
//
// The `DesignDirection` enum and its precedence resolution live in
// BlaiseCore (pure, unit-tested). Views read color/type tokens from
// `Design`; structural variants (notes section chrome, the user-action box, the
// audio transport) switch on `Design.direction`. Dark-first throughout.

/// The live design choice. Initial value via `DesignDirection.resolved`:
/// the `BLAISE_DESIGN_DIRECTION` launch override (capture harness
/// determinism) wins, else the saved menu choice, else Estúdio (the user's pick
/// after the v3 review). Picking from View ▸ Design saves the choice; the
/// window re-roots on change (rare action — a full rebuild is the simple,
/// correct mechanism).
@MainActor @Observable
final class DesignSelection {
    static let shared = DesignSelection()
    private static let defaultsKey = "BlaiseDesignDirection"

    var direction: DesignDirection {
        didSet {
            UserDefaults.standard.set(direction.rawValue, forKey: Self.defaultsKey)
        }
    }

    private init() {
        direction = DesignDirection.resolved(
            env: ProcessInfo.processInfo.environment["BLAISE_DESIGN_DIRECTION"],
            saved: UserDefaults.standard.string(forKey: Self.defaultsKey))
    }
}

@MainActor
enum Design {
    static var direction: DesignDirection { DesignSelection.shared.direction }

    // MARK: - Palette

    /// Primary accent: selection, user emphasis, search matches, play.
    static var accent: Color {
        switch direction {
        case .caderno: return Color(red: 0.92, green: 0.68, blue: 0.38)  // honey amber #EBAE61
        case .estudio, .fluido: return Color(red: 0.36, green: 0.85, blue: 0.92)  // electric cyan #5CD9EB
        case .aquarela: return Color(red: 0.86, green: 0.55, blue: 0.61)  // rosa #DB8C9C
        }
    }

    /// Supporting hue: decisions, counts, secondary emphasis.
    static var support: Color {
        switch direction {
        case .caderno: return Color(red: 0.62, green: 0.72, blue: 0.60)  // sage #9EB899
        case .estudio, .fluido: return Color(red: 0.57, green: 0.51, blue: 0.97)  // violet #9182F7
        case .aquarela: return Color(red: 0.42, green: 0.68, blue: 0.65)  // teal #6BADA6
        }
    }

    /// Recording / destructive state.
    static var recording: Color {
        switch direction {
        case .caderno: return Color(red: 0.89, green: 0.36, blue: 0.29)  // vermilion #E35C4A
        case .estudio, .fluido: return Color(red: 1.00, green: 0.36, blue: 0.38)  // hot coral #FF5C61
        case .aquarela: return Color(red: 0.85, green: 0.42, blue: 0.42)  // soft red #D96B6B
        }
    }

    /// Backdrop for the center (meeting-list) column.
    static var listColumn: Color {
        switch direction {
        case .caderno: return Color(red: 0.105, green: 0.090, blue: 0.074)  // warm umber #1B1713
        case .estudio, .fluido: return Color(red: 0.050, green: 0.065, blue: 0.094)  // ink blue #0D1118
        case .aquarela: return Color(red: 0.082, green: 0.086, blue: 0.098)  // graphite #151619
        }
    }

    /// Shared quiet card surface for lists, search, and compact status fields.
    /// Each direction keeps its palette, while spacing and hierarchy stay
    /// consistent across the product.
    static var surface: Color {
        switch direction {
        case .caderno: return Color(red: 0.145, green: 0.122, blue: 0.098)
        case .estudio: return Color.white.opacity(0.034)
        case .aquarela: return Color.white.opacity(0.03)
        case .fluido: return Color.white.opacity(0.04)
        }
    }

    static var surfaceBorder: Color {
        switch direction {
        case .caderno: return accent.opacity(0.13)
        case .estudio, .fluido: return Color.white.opacity(0.065)
        case .aquarela: return Color.white.opacity(0.06)
        }
    }

    static var selectionFill: Color {
        switch direction {
        case .caderno: return accent.opacity(0.12)
        case .estudio, .fluido: return accent.opacity(0.105)
        case .aquarela: return accent.opacity(0.10)
        }
    }

    static var selectionBorder: Color { accent.opacity(0.34) }

    // MARK: - Reading-pane backdrop (the direction's "field")

    /// The detail pane's background. `tint` is the per-meeting hue
    /// (aquarela's adaptive wash); ignored by the other directions.
    @ViewBuilder
    static func paneBackdrop(tint: Color?) -> some View {
        switch direction {
        case .caderno:
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.128, green: 0.110, blue: 0.090),
                        Color(red: 0.100, green: 0.086, blue: 0.070),
                    ], startPoint: .top, endPoint: .bottom)
                // Lamplight: a faint warm glow from the top-leading corner.
                RadialGradient(
                    colors: [Color(red: 0.95, green: 0.76, blue: 0.46).opacity(0.055), .clear],
                    center: .topLeading, startRadius: 0, endRadius: 760)
            }
        case .estudio:
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.058, green: 0.075, blue: 0.108),
                        Color(red: 0.040, green: 0.050, blue: 0.076),
                    ], startPoint: .top, endPoint: .bottom)
                // Depth: a cool cyan bloom up top, violet rising from below.
                RadialGradient(
                    colors: [accent.opacity(0.06), .clear],
                    center: .topLeading, startRadius: 0, endRadius: 700)
                RadialGradient(
                    colors: [support.opacity(0.08), .clear],
                    center: .bottomTrailing, startRadius: 0, endRadius: 900)
            }
        case .aquarela:
            ZStack {
                Color(red: 0.090, green: 0.094, blue: 0.106)
                if let tint {
                    // The meeting's own hue washes the top of its page —
                    // adaptive tinting from content, watercolor-quiet.
                    RadialGradient(
                        colors: [tint.opacity(0.17), .clear],
                        center: .top, startRadius: 0, endRadius: 820)
                }
            }
        case .fluido:
            // The living field: a slow-drifting mesh, warming while
            // recording (FluidoKit). Content floats on materials above it.
            FluidoMeshBackground()
        }
    }

    // MARK: - Typography

    /// Display: meeting titles, the largest text on screen.
    static func displayFont(_ size: CGFloat) -> Font {
        switch direction {
        case .caderno: return .system(size: size + 2, weight: .bold, design: .serif)
        case .estudio, .fluido: return .system(size: size, weight: .heavy)
        case .aquarela: return .system(size: size, weight: .bold, design: .rounded)
        }
    }

    /// Reading: notes body text. Caderno reads in New York serif.
    static func readingFont(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        switch direction {
        case .caderno: return .system(size: size + 1, weight: weight, design: .serif)
        case .estudio, .fluido: return .system(size: size, weight: weight)
        case .aquarela: return .system(size: size, weight: weight)
        }
    }

    static var readingLineSpacing: CGFloat {
        switch direction {
        case .caderno: return 6
        case .estudio, .fluido: return 4
        case .aquarela: return 5
        }
    }

    /// Row titles in the meeting list.
    static var rowTitleFont: Font {
        switch direction {
        case .caderno: return .system(size: 13.5, weight: .semibold, design: .serif)
        case .estudio, .fluido: return .system(size: 13, weight: .semibold)
        case .aquarela: return .system(size: 13, weight: .semibold)
        }
    }

    /// Metadata digits (times, durations, timestamps).
    static var metaFont: Font {
        switch direction {
        case .estudio, .fluido: return .system(size: 11, design: .monospaced)
        default: return .system(size: 11.5).monospacedDigit()
        }
    }

    // MARK: - Aquarela: per-meeting quiet hues (adaptive tint from content)

    /// Eight muted, dark-mode-tuned hues; a meeting's title hashes to one,
    /// stably. The hue follows the meeting everywhere: list dot, page wash,
    /// header icons, audio transport.
    static let quietHues: [Color] = [
        Color(red: 0.80, green: 0.49, blue: 0.42),  // terracotta #CC7D6B
        Color(red: 0.80, green: 0.66, blue: 0.42),  // ochre #CCA86B
        Color(red: 0.56, green: 0.69, blue: 0.55),  // sage #8FB08C
        Color(red: 0.42, green: 0.68, blue: 0.65),  // teal #6BADA6
        Color(red: 0.49, green: 0.60, blue: 0.80),  // slate #7D99CC
        Color(red: 0.62, green: 0.56, blue: 0.80),  // lavender #9E8FCC
        Color(red: 0.80, green: 0.49, blue: 0.62),  // rose #CC7D9E
        Color(red: 0.64, green: 0.69, blue: 0.43),  // moss #A3B06E
    ]

    static func meetingHue(_ title: String) -> Color {
        var hash: UInt64 = 5381
        for byte in title.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return quietHues[Int(hash % UInt64(quietHues.count))]
    }

    // MARK: - Aquarela: semantic notes-section fields

    enum NoteSectionKind {
        case summary, userActions, decisions, actions, detailed
    }

    static func sectionTint(_ kind: NoteSectionKind) -> Color {
        switch kind {
        case .summary: return Color(red: 0.49, green: 0.60, blue: 0.80)  // slate
        case .userActions: return accent  // rosa — the signature, unmissable
        case .decisions: return Color(red: 0.62, green: 0.56, blue: 0.80)  // lavender
        case .actions: return support  // teal
        case .detailed: return Color(red: 0.60, green: 0.62, blue: 0.66)  // neutral
        }
    }

    static func sectionIcon(_ kind: NoteSectionKind) -> String {
        switch kind {
        case .summary: return "text.alignleft"
        case .userActions: return "person.crop.circle.badge.checkmark"
        case .decisions: return "checkmark.seal.fill"
        case .actions: return "person.2.fill"
        case .detailed: return "doc.text"
        }
    }
}

// MARK: - Shared chrome helpers

extension View {
    /// Direction-tinted backdrop for the list columns (center column,
    /// search results, My Action Items).
    func designListBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(Design.listColumn.ignoresSafeArea())
    }
}

/// Direction-styled empty/error state for the detail pane: the direction's
/// typography over whatever backdrop the host supplies (the no-selection
/// state adds `Design.paneBackdrop` itself; the not-found state sits on the
/// backdrop MeetingDetailView already draws). Replaces the raw
/// ContentUnavailableView defaults that read as unstyled in every direction.
struct DirectionUnavailableView: View {
    let title: String
    let systemImage: String
    var description: String?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Design.accent.opacity(0.5))
                .accessibilityHidden(true)
            Text(title)
                .font(Design.displayFont(17))
                .foregroundStyle(.secondary)
            if let description {
                Text(description)
                    .font(Design.readingFont(12.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// Header metadata item: tinted icon + quiet text.
struct MetaItem: View {
    let icon: String
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(tint.opacity(0.9))
                .accessibilityHidden(true)
            Text(text)
                .font(Design.metaFont)
                .foregroundStyle(.secondary)
        }
    }
}
