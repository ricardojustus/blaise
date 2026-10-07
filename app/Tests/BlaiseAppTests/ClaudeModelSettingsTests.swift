import BlaiseCore
import Foundation
import Testing

@testable import BlaiseApp

@MainActor
struct ClaudeModelSettingsTests {
    @Test func modelChoicesReuseCredentialsAndPersistIndependently() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try BlaiseDatabase(rootURL: root)
        let settings = SettingsStore(database: database)
        let secrets = InMemorySecretStore()
        let ledger = CloudSpendLedger(database: database)
        let registry = AppEnvironment.buildRegistry(
            database: database, dataRoot: root, settings: settings, secrets: secrets, ledger: ledger)
        let model = EngineSettingsModel(registry: registry, settings: settings)

        // These are the existing key locations, not newly generated namespaces.
        try secrets.set(key: "engine.claude-sonnet.apiKey", value: "fictional-test-key")
        try secrets.set(key: "engine.claude-cli.oauthToken", value: "fictional-test-token")
        let cli = root.appendingPathComponent("claude")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        try await settings.set("engine.claude-cli.binaryPath", to: cli.path)

        try await settings.set(EngineResolver.summarizationSettingsKey, to: "claude-cli")
        await model.load()
        #expect(model.selectedSummarizationID == "claude-cli")
        let apiIDs = ["claude-sonnet", "claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-4-5"]
        let cliIDs = ["claude-cli", "claude-opus-5-5-cli"]
        #expect(registry.summarizationEngines.map(\.id) == apiIDs + [MLXSummarizationEngine.engineID] + cliIDs)
        for id in apiIDs + cliIDs {
            let row = try #require(model.summarizationRows.first { $0.id == id })
            #expect(row.availabilityReason == nil)
            #expect(row.configurationID == (apiIDs.contains(id) ? "claude-sonnet" : "claude-cli"))
        }

        await model.select("claude-opus-5-5", slot: .summarization)
        #expect(model.selectedSummarizationID == "claude-opus-5-5")
        #expect(model.summarizationPrepare == .idle)
        let reloaded = EngineSettingsModel(registry: registry, settings: settings)
        await reloaded.load()
        let resolved = try await EngineResolver(registry: registry, settings: settings).resolveSummarization()
        #expect(reloaded.selectedSummarizationID == "claude-opus-5-5")
        #expect(resolved.engine.id == reloaded.selectedSummarizationID)
        #expect(!resolved.usedFallback)
        #expect(resolved.engine.costDescriptor?.estimatedPerMeetingUSD == ClaudeNotesModel.opus55.estimatedPerMeetingUSD)
    }
}
