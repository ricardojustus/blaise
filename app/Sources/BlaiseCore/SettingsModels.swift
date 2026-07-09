import Foundation
import Observation
import os

// C10 Settings view-models (UI-free; SwiftUI tabs in BlaiseApp read them).

// MARK: - Engines tab

public enum EngineSlot: String, Sendable, CaseIterable {
    case asr, summarization
}

/// Engine pickers + the pinned prepare UX state machine:
/// - switching writes the `EngineSelection` key IMMEDIATELY (the selection
///   is the user's choice regardless of preparation state);
/// - `prepare()` fires eagerly; while running → `.preparing` (the
///   indeterminate progress row); failure → `.failed(reason)` with the
///   selection KEPT and a Retry; success → row clears;
/// - `prepareSelectedEnginesAtLaunch()` re-fires prepare for the selected
///   engines on every launch (idempotent, cheap when satisfied — covers the
///   selected-but-unprepared case).
@MainActor @Observable
public final class EngineSettingsModel {
    public struct EngineRow: Identifiable, Equatable, Sendable {
        public var id: String
        public var displayName: String
        public var kind: EngineKind
        public var costSummary: String?
        public var configDescriptors: [EngineConfigDescriptor]
        /// nil = available.
        public var availabilityReason: String?
    }

    public enum PrepareState: Equatable, Sendable {
        case idle
        case preparing(engineID: String)
        case failed(engineID: String, reason: String)
    }

    public private(set) var asrRows: [EngineRow] = []
    public private(set) var summarizationRows: [EngineRow] = []
    public private(set) var selectedASRID: String = EngineDefaults.asrEngineID
    public private(set) var selectedSummarizationID: String = EngineDefaults.summarizationEngineID
    public private(set) var asrPrepare: PrepareState = .idle
    public private(set) var summarizationPrepare: PrepareState = .idle

    private let registry: EngineRegistry
    private let settings: SettingsStore
    private var prepareGeneration: [EngineSlot: Int] = [:]
    private let logger = Logger(subsystem: BlaiseBundle.identifier, category: "settings.engines")

    public init(registry: EngineRegistry, settings: SettingsStore) {
        self.registry = registry
        self.settings = settings
    }

    public func load() async {
        selectedASRID =
            (try? await settings.get(EngineResolver.asrSettingsKey, as: String.self))
            ?? nil ?? EngineDefaults.asrEngineID
        selectedSummarizationID =
            (try? await settings.get(EngineResolver.summarizationSettingsKey, as: String.self))
            ?? nil ?? EngineDefaults.summarizationEngineID
        await refreshRows()
    }

    public func refreshRows() async {
        var asr: [EngineRow] = []
        for engine in registry.asrEngines {
            asr.append(await row(
                id: engine.id, name: engine.displayName, kind: engine.kind,
                cost: engine.costDescriptor, descriptors: engine.configDescriptors,
                availability: engine.availability()))
        }
        var summarization: [EngineRow] = []
        for engine in registry.summarizationEngines {
            summarization.append(await row(
                id: engine.id, name: engine.displayName, kind: engine.kind,
                cost: engine.costDescriptor, descriptors: engine.configDescriptors,
                availability: engine.availability()))
        }
        asrRows = asr
        summarizationRows = summarization
    }

    private func row(
        id: String, name: String, kind: EngineKind, cost: EngineCostDescriptor?,
        descriptors: [EngineConfigDescriptor], availability: EngineAvailability
    ) -> EngineRow {
        var reason: String?
        if case .unavailable(let value) = availability { reason = value }
        return EngineRow(
            id: id, displayName: name, kind: kind, costSummary: cost?.pricingSummary,
            configDescriptors: descriptors, availabilityReason: reason)
    }

    public func selectedID(_ slot: EngineSlot) -> String {
        slot == .asr ? selectedASRID : selectedSummarizationID
    }

    public func prepareState(_ slot: EngineSlot) -> PrepareState {
        slot == .asr ? asrPrepare : summarizationPrepare
    }

    /// Select + eager prepare. The settings write happens FIRST and is never
    /// rolled back on prepare failure.
    public func select(_ id: String, slot: EngineSlot) async {
        switch slot {
        case .asr:
            selectedASRID = id
            try? await settings.set(EngineResolver.asrSettingsKey, to: id)
        case .summarization:
            selectedSummarizationID = id
            try? await settings.set(EngineResolver.summarizationSettingsKey, to: id)
        }
        await prepare(slot: slot, engineID: id)
    }

    /// The Retry control on a failed prepare row.
    public func retryPrepare(slot: EngineSlot) async {
        await prepare(slot: slot, engineID: selectedID(slot))
    }

    /// Launch retry: fires prepare for both selected engines.
    public func prepareSelectedEnginesAtLaunch() async {
        await load()
        async let asr: Void = prepare(slot: .asr, engineID: selectedASRID)
        async let summarization: Void = prepare(slot: .summarization, engineID: selectedSummarizationID)
        _ = await (asr, summarization)
    }

    private func prepare(slot: EngineSlot, engineID: String) async {
        let generation = (prepareGeneration[slot] ?? 0) + 1
        prepareGeneration[slot] = generation
        setPrepareState(.preparing(engineID: engineID), slot: slot)
        do {
            switch slot {
            case .asr:
                guard let engine = registry.asrEngine(id: engineID) else {
                    throw EngineError.notAvailable(reason: "engine '\(engineID)' is not registered")
                }
                try await engine.prepare()
            case .summarization:
                guard let engine = registry.summarizationEngine(id: engineID) else {
                    throw EngineError.notAvailable(reason: "engine '\(engineID)' is not registered")
                }
                try await engine.prepare()
            }
            guard prepareGeneration[slot] == generation else { return }
            setPrepareState(.idle, slot: slot)
        } catch {
            guard prepareGeneration[slot] == generation else { return }
            let reason = await failureReason(slot: slot, engineID: engineID, error: error)
            logger.warning("prepare failed for \(engineID, privacy: .public): \(reason, privacy: .public)")
            setPrepareState(.failed(engineID: engineID, reason: reason), slot: slot)
        }
        await refreshRows()
    }

    /// Prefer the engine's own availability reason (the inline message the
    /// spec pins); fall back to the thrown error.
    private func failureReason(slot: EngineSlot, engineID: String, error: any Error) async -> String {
        let availability: EngineAvailability? =
            switch slot {
            case .asr: await registry.asrEngine(id: engineID)?.availability()
            case .summarization: await registry.summarizationEngine(id: engineID)?.availability()
            }
        if case .unavailable(let reason) = availability { return reason }
        return ProcessingPipeline.describe(error)
    }

    private func setPrepareState(_ state: PrepareState, slot: EngineSlot) {
        switch slot {
        case .asr: asrPrepare = state
        case .summarization: summarizationPrepare = state
        }
    }
}

// MARK: - Identity & handoff tab

/// UserIdentity + handoff endpoint settings. Saving persists what was typed
/// (the worker is the enforcement point: invalid settings pause it as
/// `configurationInvalid`), surfaces the inline validation error, and on a
/// PASS fires `worker.kick()` — C8's fix-resumes-immediately guarantee.
@MainActor @Observable
public final class HandoffSettingsModel {
    /// The active destination kind (G5): SSH (the remote host) or a local folder. ONE
    /// active at a time.
    public var destinationKind: HandoffDestination.Kind = .ssh
    public var user = ""
    public var identityFile = ""
    /// One host per line (or comma-separated) in the UI.
    public var hostsText = ""
    public var remoteRoot = ""
    /// Display path of the chosen local folder ("" = none chosen yet).
    public private(set) var localFolderPath = ""
    /// Markdown sidecar toggle for the local folder (default ON).
    public var markdownSidecar = true
    /// G14: "Include memory digest" — the second machine-facing render that
    /// the knowledge graph's graph extractor reads. Default ON. OFF ⇒ no second synthesis
    /// call and no `memory_digest` on the payload (absent ⇒ skip to the knowledge graph).
    public var includeMemoryDigest = MemoryDigestSettings.defaultEnabled
    /// "Verify & repair memory digest" — the second auditor pass that audits the
    /// digest against the transcript and repairs grounding errors before sending.
    /// Default ON (the validated precision config). Only meaningful when
    /// `includeMemoryDigest` is ON; the UI disables it when the digest is OFF.
    public var verifyMemoryDigest = MemoryDigestSettings.defaultVerifyEnabled
    public private(set) var validationError: String?

    private let settings: SettingsStore
    private let kicker: any HandoffKicking

    public init(settings: SettingsStore, kicker: any HandoffKicking) {
        self.settings = settings
        self.kicker = kicker
    }

    public func load() async {
        destinationKind = (try? await settings.get(HandoffDestination.Key.kind, as: HandoffDestination.Kind.self))
            ?? nil ?? .ssh
        let current = await HandoffSettings.load(from: settings)
        user = current.user
        identityFile = current.identityFile
        hostsText = current.hosts.joined(separator: "\n")
        remoteRoot = current.remoteRoot
        localFolderPath = (try? await settings.get(HandoffDestination.Key.localPath, as: String.self))
            ?? nil ?? ""
        markdownSidecar = (try? await settings.get(HandoffDestination.Key.localMarkdownSidecar, as: Bool.self))
            ?? nil ?? true
        includeMemoryDigest = await MemoryDigestSettings.isEnabled(in: settings)
        verifyMemoryDigest = await MemoryDigestSettings.isVerifyEnabled(in: settings)
        validationError = validationMessage(of: current)
    }

    /// Persists a folder chosen via NSOpenPanel: stores a security-scoped
    /// bookmark (survives folder moves) plus the display path. The caller has
    /// already opened the security scope on `url`. Returns whether the bookmark
    /// was created (false → an inline error is set).
    @discardableResult
    public func chooseLocalFolder(_ url: URL) async -> Bool {
        do {
            let bookmark = try url.bookmarkData(
                options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            try? await settings.set(HandoffDestination.Key.localBookmark, to: bookmark.base64EncodedString())
            try? await settings.set(HandoffDestination.Key.localPath, to: url.path)
            localFolderPath = url.path
            validationError = nil
            return true
        } catch {
            validationError = "could not bookmark folder: \(error.localizedDescription)"
            return false
        }
    }

    var hosts: [String] {
        hostsText
            .split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Persists, validates, and kicks the worker iff validation passes.
    /// Returns whether validation passed.
    @discardableResult
    public func save() async -> Bool {
        // Persist the active destination kind (G5). SSH fields are always
        // persisted (so switching back keeps them); the sidecar toggle is
        // persisted for the local folder.
        try? await settings.set(HandoffDestination.Key.kind, to: destinationKind)
        try? await settings.set(HandoffDestination.Key.localMarkdownSidecar, to: markdownSidecar)
        // G14: persist the memory-digest toggle (forward renders only — it
        // never rewrites already-minted payloads).
        try? await settings.set(MemoryDigestSettings.enabledKey, to: includeMemoryDigest)
        // Persist the verify/repair toggle (forward renders only). The dev env
        // override BLAISE_DIGEST_VERIFY=1 forces the pass on regardless of this.
        try? await settings.set(MemoryDigestSettings.verifyEnabledKey, to: verifyMemoryDigest)
        let candidate = HandoffSettings(
            user: user.trimmingCharacters(in: .whitespaces),
            identityFile: identityFile.trimmingCharacters(in: .whitespaces),
            hosts: hosts,
            remoteRoot: remoteRoot.trimmingCharacters(in: .whitespaces))
        try? await settings.set(HandoffSettings.Key.user, to: candidate.user)
        try? await settings.set(HandoffSettings.Key.identityFile, to: candidate.identityFile)
        try? await settings.set(HandoffSettings.Key.hosts, to: candidate.hosts)
        try? await settings.set(HandoffSettings.Key.remoteRoot, to: candidate.remoteRoot)

        switch destinationKind {
        case .ssh:
            if let message = validationMessage(of: candidate) {
                validationError = message
                return false
            }
        case .localFolder:
            // The worker resolves the bookmark; a missing one pauses it. Guard
            // the obvious case here so the picker gives immediate feedback.
            if localFolderPath.isEmpty {
                validationError = "choose a folder for the local destination"
                return false
            }
        }
        validationError = nil
        await kicker.kick()
        return true
    }

    private func validationMessage(of candidate: HandoffSettings) -> String? {
        do {
            try candidate.validate()
            return nil
        } catch {
            return error.description
        }
    }
}

/// UserIdentity editor (name / aliases / email) + the extension shared
/// secret (reveal / regenerate per C12; Keychain via the C2 SecretStore).
@MainActor @Observable
public final class IdentityModel {
    public var name = ""
    public var aliasesText = ""
    public var email = ""

    private let settings: SettingsStore
    private let secrets: any SecretStore

    public init(settings: SettingsStore, secrets: any SecretStore) {
        self.settings = settings
        self.secrets = secrets
    }

    public func load() async {
        let identity =
            (try? await settings.get(UserIdentity.settingsKey, as: UserIdentity.self))
            ?? nil ?? .shippedDefault
        name = identity.name
        aliasesText = identity.aliases.joined(separator: ", ")
        email = identity.email
    }

    public func save() async {
        let aliases = aliasesText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let identity = UserIdentity(
            name: name.trimmingCharacters(in: .whitespaces),
            aliases: aliases,
            email: email.trimmingCharacters(in: .whitespaces))
        try? await settings.set(UserIdentity.settingsKey, to: identity)
    }

    /// Returns the shared secret, generating + storing one on first access.
    public func revealMeetSecret() -> String {
        if let existing = (try? secrets.get(key: MeetEventsSecret.secretStoreKey)) ?? nil {
            return existing
        }
        return regenerateMeetSecret()
    }

    @discardableResult
    public func regenerateMeetSecret() -> String {
        let secret = MeetEventsSecret.generate()
        try? secrets.set(key: MeetEventsSecret.secretStoreKey, value: secret)
        return secret
    }
}

/// Queue panel: HandoffSnapshot display (via `HandoffStatusHolder`) PLUS the
/// contracted controls — Retry All / per-item retry, both followed by a
/// worker kick.
@MainActor @Observable
public final class QueuePanelModel {
    public private(set) var queueItems: [HandoffItem] = []

    private let repository: HandoffRepository
    private let kicker: any HandoffKicking

    public init(database: BlaiseDatabase, kicker: any HandoffKicking) {
        self.repository = HandoffRepository(database: database)
        self.kicker = kicker
    }

    public func refresh() async {
        queueItems = (try? await repository.allItems()) ?? []
    }

    /// The queue panel's "Retry Now": re-enters `failed` rows incl. ONE
    /// re-check of `damaged:` rows (`superseded:` never — the C1/C8 prefix
    /// contract), and the kick clears every backoff floor and host bench, so
    /// pending items on a floor retry immediately too (same semantics as
    /// `HandoffWorker.retryNow`).
    public func retryAll() async {
        _ = try? await repository.retryAllFailed()
        await kicker.kick()
        await refresh()
    }

    public func retry(_ id: HandoffID) async {
        _ = try? await repository.retryItem(id)
        await kicker.kick()
        await refresh()
    }
}

// MARK: - Usage tab

/// Cloud spend month view + the `cloud.ceilingUSD` setting + the 80 %
/// warning surface.
@MainActor @Observable
public final class UsageModel {
    public private(set) var monthKey = ""
    public private(set) var spentUSD = 0.0
    public private(set) var ceilingUSD = CloudSpendLedger.defaultCeilingUSD
    public private(set) var warningReached = false
    /// G7: the line-by-line month view (receipts newest first, per-purpose
    /// subtotals, reconciliation against the authoritative accumulator).
    public private(set) var receipts = CloudSpendMonthReceipts(
        monthKey: "", receipts: [], accumulatorUSD: 0)

    private let ledger: CloudSpendLedger
    private let settings: SettingsStore

    public init(ledger: CloudSpendLedger, settings: SettingsStore) {
        self.ledger = ledger
        self.settings = settings
    }

    public func load() async {
        monthKey = await ledger.currentMonthKey()
        spentUSD = (try? await ledger.accumulatedThisMonth()) ?? 0
        ceilingUSD = await ledger.ceilingUSD()
        warningReached = (try? await ledger.warningReached()) ?? false
        receipts =
            (try? await ledger.monthReceipts())
            ?? CloudSpendMonthReceipts(monthKey: monthKey, receipts: [], accumulatorUSD: spentUSD)
    }

    /// Cosmetic alias of `load()` so the Usage tab's Refresh button mirrors the
    /// sibling panels (QueuePanelModel.refresh / ProcessingQueueModel.refresh):
    /// re-reads the ledger month view on demand. Spend does NOT auto-tick live;
    /// this + refresh-on-open is the correctness guarantee.
    public func refresh() async { await load() }

    public func setCeiling(_ value: Double) async {
        guard value > 0 else { return }
        try? await settings.set(CloudSpendLedger.ceilingSettingsKey, to: value)
        await load()
    }
}
