import FluidAudio
import Foundation
import Testing
@testable import BlaiseCore

// C4 FluidAudioDiarizer decision-logic unit tests over filesystem fixtures
// (C3 pattern): availability reasons, integrity predicate, wipe-repair +
// two-consecutive-failures, config namespacing — all offline (the real model
// load runs in DiarizationIntegrationTests). Plus the C4-owned output
// post-processing (clamp/drop/label normalization).

private struct FakeLoadFailure: Error {}

private func makeDiarizer(
    modelLoadOverride: (@Sendable (URL) async throws -> Void)? = nil
) async throws -> (diarizer: FluidAudioDiarizer, settings: SettingsStore, dataRoot: URL) {
    let dataRoot = try makeTempRoot()
    let database = try BlaiseDatabase(rootURL: dataRoot)
    let settings = SettingsStore(database: database)
    let diarizer = FluidAudioDiarizer(
        configuration: EngineConfiguration(
            engineID: FluidAudioDiarizer.diarizerID,
            descriptors: FluidAudioDiarizer.descriptors,
            settings: settings,
            secrets: InMemorySecretStore()),
        dataRoot: dataRoot,
        modelLoadOverride: modelLoadOverride)
    return (diarizer, settings, dataRoot)
}

/// Plants the offline-variant repo fixture (all five required entries as
/// plain files — structural integrity only).
private func plantModelFixture(parent: URL) throws {
    let repo = parent.appendingPathComponent(FluidAudioDiarizer.repoFolderName, isDirectory: true)
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    for name in ModelNames.OfflineDiarizer.requiredModels {
        try Data("junk".utf8).write(to: repo.appendingPathComponent(name))
    }
}

@Suite struct DiarizerTests {
    @Test func availabilityBeforeDownloadNamesTheMissingModels() async throws {
        let (diarizer, _, _) = try await makeDiarizer()
        guard case .unavailable(let reason) = await diarizer.availability() else {
            Issue.record("expected unavailable")
            return
        }
        #expect(reason.contains("not yet downloaded"))
    }

    @Test func modelsPathOverrideIsReadFromOwnNamespace() async throws {
        let (diarizer, settings, _) = try await makeDiarizer()
        let override = try makeTempRoot()
        try await settings.set(
            "engine.\(FluidAudioDiarizer.diarizerID).\(FluidAudioDiarizer.modelsPathKey)",
            to: override.path)
        guard case .unavailable(let reason) = await diarizer.availability() else {
            Issue.record("expected unavailable")
            return
        }
        #expect(reason.contains("not yet downloaded"))

        // Planting the fixture in the OVERRIDE dir flips availability —
        // the override namespace, not the default, is being read.
        try plantModelFixture(parent: override)
        #expect(await diarizer.availability() == .available)
    }

    @Test func modelsPresentPredicateRequiresEveryFile() throws {
        let parent = try makeTempRoot()
        let repo = parent.appendingPathComponent(FluidAudioDiarizer.repoFolderName, isDirectory: true)
        #expect(!FluidAudioDiarizer.modelsPresent(at: repo))  // nothing planted
        try plantModelFixture(parent: parent)
        #expect(FluidAudioDiarizer.modelsPresent(at: repo))
        // Removing any single required entry breaks integrity.
        try FileManager.default.removeItem(
            at: repo.appendingPathComponent(ModelNames.OfflineDiarizer.pldaParameters))
        #expect(!FluidAudioDiarizer.modelsPresent(at: repo))
    }

    @Test func loadFailureWipesRepoAndSecondConsecutiveFailureIsPermanent() async throws {
        let (diarizer, _, dataRoot) = try await makeDiarizer(modelLoadOverride: { _ in
            throw FakeLoadFailure()
        })
        let parent = dataRoot.appendingPathComponent("models/fluidaudio-diar", isDirectory: true)
        let repo = parent.appendingPathComponent(FluidAudioDiarizer.repoFolderName, isDirectory: true)
        try plantModelFixture(parent: parent)

        // First failure: transient, repo dir wiped, availability names it.
        let first = await engineError { try await diarizer.prepare() }
        guard case .transient(let reason) = first else {
            Issue.record("expected transient, got \(String(describing: first))")
            return
        }
        #expect(reason.contains("wiped"))
        #expect(!FileManager.default.fileExists(atPath: repo.path))
        guard case .unavailable(let unavailableReason) = await diarizer.availability() else {
            Issue.record("expected unavailable after load failure")
            return
        }
        #expect(unavailableReason.contains("model load failed this launch"))

        // Second consecutive failure (fixture re-planted, no success between):
        // permanent.
        try plantModelFixture(parent: parent)
        let second = await engineError { try await diarizer.prepare() }
        guard case .permanent(let permanentReason) = second else {
            Issue.record("expected permanent, got \(String(describing: second))")
            return
        }
        #expect(permanentReason.contains("twice consecutively"))
    }

    @Test func successfulLoadResetsFailureCountAndFlipsAvailability() async throws {
        // Fails once, then succeeds — the counter resets and the diarizer
        // reports available for the rest of the launch.
        let shouldFail = Recorder<Bool>()
        shouldFail.append(true)
        let (diarizer, _, _) = try await makeDiarizer(modelLoadOverride: { _ in
            if shouldFail.values.count == 1 {
                shouldFail.append(false)
                throw FakeLoadFailure()
            }
        })
        let first = await engineError { try await diarizer.prepare() }
        guard case .transient = first else {
            Issue.record("expected transient first failure")
            return
        }
        try await diarizer.prepare()  // succeeds
        #expect(await diarizer.availability() == .available)
        try await diarizer.prepare()  // idempotent
        #expect(await diarizer.availability() == .available)
    }

    @Test func diarizerIdentityAndDescriptors() {
        #expect(FluidAudioDiarizer.diarizerID == "fluidaudio-diarizer-offline")
        #expect(FluidAudioDiarizer.descriptors.map(\.key) == ["modelsPath"])
        // FluidAudio's local cache folder strips the -coreml suffix; the
        // OFFLINE-variant model files live inside it (the machine cache holds
        // both pipelines' files side by side).
        #expect(FluidAudioDiarizer.repoFolderName == "speaker-diarization")
    }

    // MARK: - Output post-processing (clamp / drop / label normalization)

    @Test func normalizedOutputClampsOverrunsAndDropsPastEOF() {
        // The probed real-output pathology: frame-quantization overshoot
        // (end 300.0849 on a 300.032 s file) clamps; segments entirely past
        // EOF drop; a clamp that empties a segment drops it.
        let output = FluidAudioDiarizer.normalizedOutput(
            [
                ("S1", 0.0, 7.25),
                ("S2", 7.25, 300.0849),  // overrun → clamped to 300.032
                ("S1", 300.04, 301.0),  // start ≥ EOF → dropped
                ("S3", 300.032, 300.05),  // start == EOF → dropped
            ],
            audioDuration: 300.032)
        #expect(output.segments.count == 2)
        #expect(output.segments[1].endSeconds == 300.032)
        #expect(output.speakerCount == 2)  // S3's only segment dropped
        #expect(output.segments.allSatisfy { $0.endSeconds > $0.startSeconds })
    }

    @Test func normalizedOutputAssignsLabelsInFirstAppearanceOrder() {
        // Native labels (any spelling) → "S<n>" by first appearance over the
        // time-sorted, post-drop list.
        let output = FluidAudioDiarizer.normalizedOutput(
            [
                ("Speaker 7", 10.0, 20.0),
                ("Speaker 2", 0.0, 9.0),
                ("Speaker 7", 25.0, 30.0),
                ("Speaker 4", 21.0, 24.0),
            ],
            audioDuration: 60)
        #expect(output.segments.map(\.speakerLabel) == ["S0", "S1", "S2", "S1"])
        #expect(output.segments.map(\.startSeconds) == [0.0, 10.0, 21.0, 25.0])
        #expect(output.speakerCount == 3)
    }

    @Test func normalizedOutputSpeakerCountExcludesFullyDroppedSpeakers() {
        let output = FluidAudioDiarizer.normalizedOutput(
            [("A", 0, 5), ("B", 400, 410)], audioDuration: 100)
        #expect(output.segments.count == 1)
        #expect(output.speakerCount == 1)
    }
}
