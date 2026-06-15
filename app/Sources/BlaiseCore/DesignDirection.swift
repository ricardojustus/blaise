import Foundation

// The four switchable visual directions (design wave, PROPOSALS_V2/V3).
// The enum and its launch-time precedence resolution live in CORE (not the
// BlaiseApp executable) so the precedence chain — env override > saved menu
// choice > Estúdio default — is a pure function under unit test; the app's
// `DesignSelection` and the `Design` token table consume it.

public enum DesignDirection: String, CaseIterable, Sendable {
    /// "Caderno" — editorial warmth: paper-dark surfaces, New York serif
    /// reading, honey amber + sage. Notes read like a well-bound notebook.
    case caderno
    /// "Estúdio" — studio glass: deep blue-black glass layers, electric
    /// cyan + violet, monospaced telemetry. A precision instrument.
    case estudio
    /// "Aquarela" — quiet color: every meeting carries its own muted hue
    /// (adaptive tinting from content); notes sections sit in calm semantic
    /// color fields. Color does the wayfinding.
    case aquarela
    /// "Estúdio Fluido" (v3) — Estúdio's palette set in motion: a living
    /// mesh backdrop, a settling header, cards with real hover/press
    /// physics, and earned micro-delight (Pow) on the rare moments.
    /// Continuity + physics, not quantity of animation.
    case fluido

    /// Menu label (View ▸ Design).
    public var displayName: String {
        switch self {
        case .caderno: return "Caderno"
        case .estudio: return "Estúdio"
        case .aquarela: return "Aquarela"
        case .fluido: return "Estúdio Fluido"
        }
    }

    /// Launch-time precedence: the `BLAISE_DESIGN_DIRECTION` env override
    /// (capture-harness determinism) wins, else the saved menu choice, else
    /// Estúdio (the user's pick after the v3 review). An unrecognized value at
    /// either level falls through — never crashes, never half-applies.
    public static func resolved(env: String?, saved: String?) -> DesignDirection {
        env.flatMap(DesignDirection.init(rawValue:))
            ?? saved.flatMap(DesignDirection.init(rawValue:))
            ?? .estudio
    }
}
