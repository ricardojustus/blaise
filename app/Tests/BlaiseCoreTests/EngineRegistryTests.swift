import Foundation
import Testing
@testable import BlaiseCore

@Suite struct EngineRegistryTests {
    @Test func preservesRegistrationOrderAndLooksUpByID() throws {
        let a = MockASREngine(id: "asr-a")
        let b = MockASREngine(id: "asr-b")
        let s = MockSummarizationEngine(id: "sum-s")
        let registry = try EngineRegistry(asr: [a, b], summarization: [s])

        #expect(registry.asrEngines.map(\.id) == ["asr-a", "asr-b"])
        #expect(registry.summarizationEngines.map(\.id) == ["sum-s"])
        #expect(registry.asrEngine(id: "asr-b")?.id == "asr-b")
        #expect(registry.summarizationEngine(id: "sum-s")?.id == "sum-s")
        #expect(registry.asrEngine(id: "missing") == nil)
        #expect(registry.summarizationEngine(id: "missing") == nil)
    }

    @Test func duplicateASRIDThrows() {
        #expect(throws: EngineError.duplicateEngineID("dup")) {
            try EngineRegistry(
                asr: [MockASREngine(id: "dup"), MockASREngine(id: "dup")],
                summarization: []
            )
        }
    }

    @Test func duplicateSummarizationIDThrows() {
        #expect(throws: EngineError.duplicateEngineID("dup")) {
            try EngineRegistry(
                asr: [],
                summarization: [MockSummarizationEngine(id: "dup"), MockSummarizationEngine(id: "dup")]
            )
        }
    }

    @Test func sameIDAcrossSlotsIsAllowed() throws {
        // Uniqueness is per slot — an ASR engine and a summarization engine
        // may share an id without colliding.
        let registry = try EngineRegistry(
            asr: [MockASREngine(id: "shared")],
            summarization: [MockSummarizationEngine(id: "shared")]
        )
        #expect(registry.asrEngine(id: "shared") != nil)
        #expect(registry.summarizationEngine(id: "shared") != nil)
    }

    @Test func emptyRegistryInitializes() throws {
        let registry = try EngineRegistry(asr: [], summarization: [])
        #expect(registry.asrEngines.isEmpty)
        #expect(registry.summarizationEngines.isEmpty)
    }
}

@Suite struct EngineResolverTests {
    private func makeResolver(
        asr: [any ASREngine] = [],
        summarization: [any SummarizationEngine] = []
    ) throws -> (EngineResolver, SettingsStore) {
        let database = try makeDatabase()
        let settings = SettingsStore(database: database)
        let registry = try EngineRegistry(asr: asr, summarization: summarization)
        return (EngineResolver(registry: registry, settings: settings), settings)
    }

    @Test func selectedIDInRegistryResolvesWithoutFallback() async throws {
        let (resolver, settings) = try makeResolver(
            asr: [MockASREngine(id: "asr-a"), MockASREngine(id: "asr-b")],
            summarization: [MockSummarizationEngine(id: "sum-a"), MockSummarizationEngine(id: "sum-b")]
        )
        try await settings.set(EngineResolver.asrSettingsKey, to: "asr-b")
        try await settings.set(EngineResolver.summarizationSettingsKey, to: "sum-b")

        let asr = try await resolver.resolveASR()
        #expect(asr.engine.id == "asr-b")
        #expect(asr.usedFallback == false)

        let sum = try await resolver.resolveSummarization()
        #expect(sum.engine.id == "sum-b")
        #expect(sum.usedFallback == false)
    }

    @Test func missingSettingUsesShippedDefaultWhenRegistered() async throws {
        // Registration-order-independent: the default wins even when it is
        // not the first registered engine.
        let (resolver, _) = try makeResolver(
            asr: [MockASREngine(id: "asr-other"), MockASREngine(id: EngineDefaults.asrEngineID)],
            summarization: [
                MockSummarizationEngine(id: "sum-other"),
                MockSummarizationEngine(id: EngineDefaults.summarizationEngineID),
            ]
        )

        let asr = try await resolver.resolveASR()
        #expect(asr.engine.id == EngineDefaults.asrEngineID)
        #expect(asr.usedFallback == false)

        let sum = try await resolver.resolveSummarization()
        #expect(sum.engine.id == EngineDefaults.summarizationEngineID)
        #expect(sum.usedFallback == false)
    }

    @Test func unregisteredSelectionFallsBackToFirstRegistered() async throws {
        let (resolver, settings) = try makeResolver(
            asr: [MockASREngine(id: "asr-first"), MockASREngine(id: "asr-second")],
            summarization: [MockSummarizationEngine(id: "sum-first")]
        )
        try await settings.set(EngineResolver.asrSettingsKey, to: "gone-engine")
        try await settings.set(EngineResolver.summarizationSettingsKey, to: "gone-engine")

        let asr = try await resolver.resolveASR()
        #expect(asr.engine.id == "asr-first")
        #expect(asr.usedFallback == true)

        let sum = try await resolver.resolveSummarization()
        #expect(sum.engine.id == "sum-first")
        #expect(sum.usedFallback == true)
    }

    @Test func unregisteredSummarizationIDSubstitutesLightweightEngineRegardlessOfOrder() async throws {
        // D17 audit M-1: rule-2 substitution is not a deliberate selection,
        // so it must never resolve a heavyweight engine — even when the
        // heavyweight one is registered first.
        let (resolver, settings) = try makeResolver(
            summarization: [
                MockSummarizationEngine(
                    id: "sum-heavy",
                    loadProfile: .heavyweight(estimatedPeakBytes: 18 * 1_073_741_824)),
                MockSummarizationEngine(id: "sum-light", loadProfile: .lightweight),
            ]
        )
        try await settings.set(EngineResolver.summarizationSettingsKey, to: "gone-engine")

        let sum = try await resolver.resolveSummarization()
        #expect(sum.engine.id == "sum-light")
        #expect(sum.usedFallback == true)
    }

    @Test func unregisteredSummarizationIDWithOnlyHeavyweightEnginesSubstitutesFirst() async throws {
        // No lightweight engine registered: rule 2 degrades to the first
        // registered engine (an empty substitution would strand the run).
        let (resolver, settings) = try makeResolver(
            summarization: [
                MockSummarizationEngine(
                    id: "sum-heavy",
                    loadProfile: .heavyweight(estimatedPeakBytes: 18 * 1_073_741_824))
            ]
        )
        try await settings.set(EngineResolver.summarizationSettingsKey, to: "gone-engine")

        let sum = try await resolver.resolveSummarization()
        #expect(sum.engine.id == "sum-heavy")
        #expect(sum.usedFallback == true)
    }

    @Test func missingSettingAndUnregisteredDefaultFallsBack() async throws {
        let (resolver, _) = try makeResolver(asr: [MockASREngine(id: "asr-only")])
        let asr = try await resolver.resolveASR()
        #expect(asr.engine.id == "asr-only")
        #expect(asr.usedFallback == true)
    }

    @Test func emptySlotThrowsNoEnginesRegistered() async throws {
        let (resolver, _) = try makeResolver()
        await #expect(throws: EngineError.noEnginesRegistered(slot: "asr")) {
            _ = try await resolver.resolveASR()
        }
        await #expect(throws: EngineError.noEnginesRegistered(slot: "summarization")) {
            _ = try await resolver.resolveSummarization()
        }
    }
}
