import Foundation

/// Per-engine configuration handle. Engines are CONSTRUCTED at the
/// composition root with one of these; C3/C6 build against it.
///
/// Routing is by the engine's declared descriptor kind: `.secret` →
/// `SecretStore`, everything else → `SettingsStore`, all under
/// `engine.<id>.<key>`.
///
/// Normative (C2 spec): configuration VALUES are read from the stores at
/// call time (live read-through); only descriptors are static. A key entered
/// in Settings after launch reaches already-constructed engines on their
/// next call — no restart, no registry rebuild.
public struct EngineConfiguration: Sendable {
    public let engineID: String
    private let descriptors: [EngineConfigDescriptor]
    private let settings: SettingsStore
    private let secrets: any SecretStore

    public init(
        engineID: String,
        descriptors: [EngineConfigDescriptor],
        settings: SettingsStore,
        secrets: any SecretStore
    ) {
        self.engineID = engineID
        self.descriptors = descriptors
        self.settings = settings
        self.secrets = secrets
    }

    public func value(for key: String) async throws -> String? {
        let storageKey = "engine.\(engineID).\(key)"
        if descriptors.first(where: { $0.key == key })?.kind == .secret {
            return try secrets.get(key: storageKey)
        }
        return try await settings.get(storageKey, as: String.self)
    }

    /// Reads a GLOBAL (non-engine-scoped) settings key, live read-through —
    /// for the rare setting that one engine SLOT shares across its engines
    /// (today only `notes.promptVersion`, shared by both summarization
    /// engines because the prompt builder is one authority). Never routes to
    /// secrets.
    public func globalValue(key: String) async throws -> String? {
        try await settings.get(key, as: String.self)
    }
}
