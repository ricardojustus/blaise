import Foundation
import Testing
@testable import BlaiseCore

@Suite struct ParakeetEngineTests {
    private func makeEngine() async throws -> (FluidAudioParakeetEngine, SettingsStore, URL) {
        let dataRoot = try makeTempRoot()
        let database = try BlaiseDatabase(rootURL: dataRoot)
        let settings = SettingsStore(database: database)
        let engine = FluidAudioParakeetEngine(
            configuration: EngineConfiguration(
                engineID: FluidAudioParakeetEngine.engineID,
                descriptors: FluidAudioParakeetEngine.descriptors,
                settings: settings,
                secrets: InMemorySecretStore()),
            dataRoot: dataRoot)
        return (engine, settings, dataRoot)
    }

    @Test func availabilityBeforeDownloadNamesTheMissingModels() async throws {
        let (engine, _, _) = try await makeEngine()
        let availability = await engine.availability()
        guard case .unavailable(let reason) = availability else {
            Issue.record("expected unavailable, got \(availability)")
            return
        }
        #expect(reason.contains("not yet downloaded"))
    }

    @Test func modelsPathOverrideIsReadFromOwnNamespace() async throws {
        let (engine, settings, _) = try await makeEngine()
        // Point at an empty override dir: availability still names the
        // missing models (and does not fall back to another engine's keys).
        let override = try makeTempRoot()
        try await settings.set(
            "engine.\(FluidAudioParakeetEngine.engineID).\(FluidAudioParakeetEngine.modelsPathKey)",
            to: override.path)
        let availability = await engine.availability()
        guard case .unavailable(let reason) = availability else {
            Issue.record("expected unavailable, got \(availability)")
            return
        }
        #expect(reason.contains("not yet downloaded"))
    }

    @Test func engineIdentityAndDescriptors() {
        let (id, name) = (FluidAudioParakeetEngine.engineID, FluidAudioParakeetEngine.modelName)
        #expect(id == "fluidaudio-parakeet-v3")
        #expect(name == "parakeet-tdt-0.6b-v3")
        #expect(FluidAudioParakeetEngine.descriptors.map(\.key) == ["modelsPath"])
    }

    /// Both C3 engines register side by side (the composition-root shape).
    @Test func bothEnginesRegisterInOneRegistry() async throws {
        let (parakeet, settings, dataRoot) = try await makeEngine()
        let whisper = MLXWhisperEngine(
            configuration: EngineConfiguration(
                engineID: MLXWhisperEngine.engineID,
                descriptors: MLXWhisperEngine.descriptors,
                settings: settings,
                secrets: InMemorySecretStore()),
            dataRoot: dataRoot,
            uvBinary: dataRoot.appendingPathComponent("uv"),
            driverScript: try #require(MLXWhisperEngine.bundledDriverScript()),
            requirementsFile: try #require(MLXWhisperEngine.bundledRequirementsFile()),
            sweepOrphansOnInit: false)
        let registry = try EngineRegistry(asr: [whisper, parakeet], summarization: [])
        #expect(registry.asrEngines.map(\.id) == [
            "mlx-whisper-large-v3-turbo", "fluidaudio-parakeet-v3",
        ])
        // The shipped default resolves to the whisper engine.
        #expect(registry.asrEngine(id: EngineDefaults.asrEngineID)?.id == MLXWhisperEngine.engineID)
    }
}
