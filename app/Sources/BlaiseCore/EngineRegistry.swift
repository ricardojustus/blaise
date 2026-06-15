import Foundation

/// Engine registry, immutable by construction (⇒ trivially Sendable; no
/// freeze rules, no locking). Registration order is preserved (stable for
/// UI). Adding an engine later = implement protocol + construct + register
/// at the composition root; nothing else changes (B-8).
public struct EngineRegistry: Sendable {
    public let asrEngines: [any ASREngine]
    public let summarizationEngines: [any SummarizationEngine]

    /// - Throws: `EngineError.duplicateEngineID` if ids collide within a slot.
    public init(asr: [any ASREngine], summarization: [any SummarizationEngine]) throws {
        var seen = Set<String>()
        for engine in asr {
            guard seen.insert(engine.id).inserted else {
                throw EngineError.duplicateEngineID(engine.id)
            }
        }
        seen.removeAll()
        for engine in summarization {
            guard seen.insert(engine.id).inserted else {
                throw EngineError.duplicateEngineID(engine.id)
            }
        }
        self.asrEngines = asr
        self.summarizationEngines = summarization
    }

    public func asrEngine(id: String) -> (any ASREngine)? {
        asrEngines.first { $0.id == id }
    }

    public func summarizationEngine(id: String) -> (any SummarizationEngine)? {
        summarizationEngines.first { $0.id == id }
    }
}

/// Shipped default engine ids — used when `SettingsStore` has no selection.
public enum EngineDefaults {
    public static let asrEngineID = "mlx-whisper-large-v3-turbo"
    /// Cloud-as-default per the bake-off verdict (audits/c6/bakeoff_judgment.md):
    /// the local engine FAILED the faithfulness hard floor (fabricated
    /// owner/action item in all three blind generations). Pre-sanctioned
    /// outcome under B-2/B-3; local stays registered and user-selectable.
    public static let summarizationEngineID = ClaudeSummarizationEngine.engineID
}

public struct ResolvedEngine<Engine: Sendable>: Sendable {
    public let engine: Engine
    /// true when the selected/default id was not registered and another
    /// engine of the slot was substituted (C10 displays it; C7 logs
    /// provenance truthfully).
    public let usedFallback: Bool

    public init(engine: Engine, usedFallback: Bool) {
        self.engine = engine
        self.usedFallback = usedFallback
    }
}

/// Resolves the persisted engine selection against the registry. C7 resolves
/// at run start, then checks `availability()` itself — if unavailable, the
/// run fails with the engine's reason (no silent engine swap; availability
/// is not resolution's job).
///
/// Precedence (deterministic, registration-order-independent for the normal
/// path): effective id = settings value if present, else the
/// `EngineDefaults` constant. Then:
/// 1. id in registry → `{engine, usedFallback: false}`;
/// 2. id not in registry → substituted engine, `usedFallback: true` — for
///    the summarization slot the first `.lightweight` engine when one is
///    registered (substitution is never a deliberate selection, so it must
///    not resolve a heavyweight engine — D17), else the first registered;
/// 3. empty slot → `EngineError.noEnginesRegistered`.
public struct EngineResolver: Sendable {
    public static let asrSettingsKey = "asrEngineID"
    public static let summarizationSettingsKey = "summarizationEngineID"

    private let registry: EngineRegistry
    private let settings: SettingsStore

    public init(registry: EngineRegistry, settings: SettingsStore) {
        self.registry = registry
        self.settings = settings
    }

    public func resolveASR() async throws -> ResolvedEngine<any ASREngine> {
        let effectiveID = try await settings.get(Self.asrSettingsKey, as: String.self)
            ?? EngineDefaults.asrEngineID
        if let engine = registry.asrEngine(id: effectiveID) {
            return ResolvedEngine(engine: engine, usedFallback: false)
        }
        if let first = registry.asrEngines.first {
            return ResolvedEngine(engine: first, usedFallback: true)
        }
        throw EngineError.noEnginesRegistered(slot: "asr")
    }

    public func resolveSummarization() async throws -> ResolvedEngine<any SummarizationEngine> {
        let effectiveID = try await settings.get(Self.summarizationSettingsKey, as: String.self)
            ?? EngineDefaults.summarizationEngineID
        if let engine = registry.summarizationEngine(id: effectiveID) {
            return ResolvedEngine(engine: engine, usedFallback: false)
        }
        // Rule 2 substitution is NOT a deliberate selection, so it must
        // never resolve a heavyweight engine (D17: no code path loads the
        // 18 GB-peak model without deliberate selection): prefer the first
        // `.lightweight` engine; only a slot with no lightweight engine
        // substitutes the first registered one.
        if let substitute = registry.summarizationEngines.first(where: {
            $0.loadProfile == .lightweight
        }) ?? registry.summarizationEngines.first {
            return ResolvedEngine(engine: substitute, usedFallback: true)
        }
        throw EngineError.noEnginesRegistered(slot: "summarization")
    }
}
