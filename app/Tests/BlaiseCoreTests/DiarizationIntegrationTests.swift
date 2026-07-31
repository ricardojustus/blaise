import Foundation
import Testing
@testable import BlaiseCore

// C4 AC2: REAL-audio integration. Must RUN on this machine; when a stack is
// genuinely missing the C3 skip protocol applies (separate skip entries per
// stack — diarizer vs whisper). The diarization models may download on the
// first run (allowed); the override points at the machine's FluidAudio cache
// so the download persists across runs.

private let repoRoot = VocabFixtures.repoRoot
private let icsiClip = VocabFixtures.fixture("icsi_sample/Bmr001_excerpt_5min.wav")
private let researchVenv = RegressionPin.asrVenv
private let realHFHome = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".cache/huggingface", isDirectory: true)
private let fluidAudioModelsParent = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/FluidAudio/Models", isDirectory: true)

private func makeRealDiarizer() async throws -> FluidAudioDiarizer {
    let dataRoot = try makeTempRoot()
    let database = try BlaiseDatabase(rootURL: dataRoot)
    let settings = SettingsStore(database: database)
    // Machine-level cache (same seam as the C3 Parakeet integration test):
    // first run may download the offline diarization models there.
    try await settings.set(
        "engine.\(FluidAudioDiarizer.diarizerID).\(FluidAudioDiarizer.modelsPathKey)",
        to: fluidAudioModelsParent.path)
    return FluidAudioDiarizer(
        configuration: EngineConfiguration(
            engineID: FluidAudioDiarizer.diarizerID,
            descriptors: FluidAudioDiarizer.descriptors,
            settings: settings,
            secrets: InMemorySecretStore()),
        dataRoot: dataRoot)
}

@Suite(.serialized) struct DiarizationIntegrationTests {
    @Test("silence is a valid result: silent track → 0 segments, 0 speakers, no error", .timeLimit(.minutes(20)))
    func silentTrackYieldsEmptyDiarizationNotFailure() async throws {
        // An in-person recording has a legitimately SILENT system track
        // (everyone is on the mic track). FluidAudio throws
        // noSpeechDetected on it; the diarizer must map that to an empty
        // output, not a stage failure.
        let silent = FileManager.default.temporaryDirectory
            .appendingPathComponent("silent-\(UUID().uuidString).wav")
        let sampleRate = 16_000
        let frames = sampleRate * 12
        var data = Data()
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let dataBytes = UInt32(frames * 2)
        data.append(contentsOf: Array("RIFF".utf8)); le32(36 + dataBytes)
        data.append(contentsOf: Array("WAVE".utf8)); data.append(contentsOf: Array("fmt ".utf8))
        le32(16); le16(1); le16(1); le32(UInt32(sampleRate)); le32(UInt32(sampleRate * 2)); le16(2); le16(16)
        data.append(contentsOf: Array("data".utf8)); le32(dataBytes)
        data.append(Data(count: frames * 2))
        try data.write(to: silent)
        defer { try? FileManager.default.removeItem(at: silent) }

        let diarizer = try await makeRealDiarizer()
        try await diarizer.prepare()
        let output = try await diarizer.diarize(audioURL: silent, expectedSpeakerCount: nil)
        #expect(output.segments.isEmpty)
        #expect(output.speakerCount == 0)
    }

    @Test(.timeLimit(.minutes(20)))
    func diarizerFindsSpeakersOnRealSegB() async throws {
        guard FluidAudioDiarizer.modelsPresent(
            at: fluidAudioModelsParent.appendingPathComponent(
                FluidAudioDiarizer.repoFolderName, isDirectory: true))
        else {
            recordTestSkip(
                "diarizerFindsSpeakersOnRealSegB",
                reason: "FluidAudio diarization models not present on this machine")
            return
        }

        let diarizer = try await makeRealDiarizer()
        let started = Date()
        try await diarizer.prepare()
        let prepared = Date()
        #expect(await diarizer.availability() == .available)
        // The structural-integrity predicate must agree with where FluidAudio
        // ACTUALLY cached the models (guards the repo-folder-name constant).
        #expect(
            FluidAudioDiarizer.modelsPresent(
                at: fluidAudioModelsParent.appendingPathComponent(
                    FluidAudioDiarizer.repoFolderName, isDirectory: true)))
        let output = try await diarizer.diarize(audioURL: icsiClip, expectedSpeakerCount: nil)
        let elapsed = Date().timeIntervalSince(prepared)
        print(
            "[integration] diarizer icsi: \(output.segments.count) segments, \(output.speakerCount) speakers; prepare \(String(format: "%.1f", prepared.timeIntervalSince(started))) s, diarize \(String(format: "%.1f", elapsed)) s"
        )

        #expect(output.speakerCount >= 2)
        #expect(output.segments.count >= 15)

        // Clamped within [0, 300.05]; positive-duration; sorted.
        for (index, segment) in output.segments.enumerated() {
            #expect(segment.startSeconds >= 0)
            #expect(segment.endSeconds <= 300.05)
            #expect(segment.endSeconds > segment.startSeconds)
            if index > 0 { #expect(segment.startSeconds >= output.segments[index - 1].startSeconds) }
        }

        // Label normalization: S<n>, 0-based, first appearance.
        #expect(output.segments.first?.speakerLabel == "S0")
        let labels = Set(output.segments.map(\.speakerLabel))
        #expect(labels.count == output.speakerCount)
        for n in 0..<output.speakerCount { #expect(labels.contains("S\(n)")) }

        // Boundary anti-snap: ≥ 3 distinct fractional parts among boundary
        // times (the 10 s streaming-mode snapping artifact would yield few).
        let boundaries = output.segments.flatMap { [$0.startSeconds, $0.endSeconds] }
        let fractions = Set(boundaries.map { (($0 - $0.rounded(.down)) * 100).rounded() / 100 })
        print("[integration] diarizer icsi distinct boundary fractions: \(fractions.count)")
        #expect(fractions.count >= 3)
    }

    @Test(.timeLimit(.minutes(30)))
    func liveWhisperMergeAttributesRealSegB() async throws {
        // Skip separability: one entry per missing stack.
        var stackMissing = false
        if !(FileManager.default.isExecutableFile(atPath: researchVenv.appendingPathComponent("bin/python").path)
            && WhisperModelCache(hfHome: realHFHome).integrity())
        {
            recordTestSkip(
                "liveWhisperMergeAttributesRealSegB.whisper",
                reason: "whisper stack missing (research venv or HF whisper cache)")
            stackMissing = true
        }
        if !FluidAudioDiarizer.modelsPresent(
            at: fluidAudioModelsParent.appendingPathComponent(
                FluidAudioDiarizer.repoFolderName, isDirectory: true))
        {
            recordTestSkip(
                "liveWhisperMergeAttributesRealSegB.diarizer",
                reason: "diarizer stack missing (FluidAudio diarization models)")
            stackMissing = true
        }
        if stackMissing { return }

        // LIVE whisper run on the committed clip (word timestamps are required
        // for the merge). Same seams and cost ownership as C3's AC2.
        let dataRoot = try makeTempRoot()
        let database = try BlaiseDatabase(rootURL: dataRoot)
        let settings = SettingsStore(database: database)
        try await settings.set(
            "engine.\(MLXWhisperEngine.engineID).\(MLXWhisperEngine.venvPathKey)",
            to: researchVenv.path)
        try await settings.set(
            "engine.\(MLXWhisperEngine.engineID).\(MLXWhisperEngine.hfHomePathKey)",
            to: realHFHome.path)
        let whisper = MLXWhisperEngine(
            configuration: EngineConfiguration(
                engineID: MLXWhisperEngine.engineID,
                descriptors: MLXWhisperEngine.descriptors,
                settings: settings,
                secrets: InMemorySecretStore()),
            dataRoot: dataRoot,
            uvBinary: repoRoot.appendingPathComponent("vendor/uv/uv"),
            driverScript: try #require(MLXWhisperEngine.bundledDriverScript()),
            requirementsFile: try #require(MLXWhisperEngine.bundledRequirementsFile()),
            sweepOrphansOnInit: false)

        let whisperStart = Date()
        let asrResult = try await whisper.transcribe(ASRRequest(audioURL: icsiClip, languageHint: "en"))
        let whisperElapsed = Date().timeIntervalSince(whisperStart)
        #expect(asrResult.segments.count >= 10)
        #expect(asrResult.segments.allSatisfy { $0.words != nil })

        let diarizer = try await makeRealDiarizer()
        let diarStart = Date()
        let diarization = try await diarizer.diarize(audioURL: icsiClip, expectedSpeakerCount: nil)
        let diarElapsed = Date().timeIntervalSince(diarStart)

        let merged = SpeakerMerger.merge(
            asr: asrResult.segments, diarization: diarization.segments,
            meetingID: "01C4INTEGRATIONICSI0000000")
        print(
            "[integration] merge icsi: whisper \(String(format: "%.1f", whisperElapsed)) s (\(asrResult.segments.count) segments), diarizer \(String(format: "%.1f", diarElapsed)) s (\(diarization.speakerCount) speakers), merged \(merged.segments.count) segments, report \(merged.report)"
        )

        // Attribution quality floor.
        let unattributed = merged.segments.filter {
            $0.speakerLabel == TranscriptSegment.unattributed
        }
        #expect(merged.segments.count - unattributed.count >= 1)
        #expect(Double(unattributed.count) <= 0.2 * Double(merged.segments.count))

        // ≥ 1 split (if 0: investigate, do not relax — the chunk cannot close).
        #expect(merged.report.splits >= 1, "no split observed on real audio: \(merged.report)")

        // Post-conditions hold on real output.
        for (index, segment) in merged.segments.enumerated() {
            #expect(segment.ord == index)
            #expect(segment.speakerName == nil)
            #expect(segment.endSeconds > segment.startSeconds)
            #expect(!segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if index > 0 {
                #expect(segment.startSeconds > merged.segments[index - 1].startSeconds)
                #expect(segment.startSeconds >= merged.segments[index - 1].endSeconds)
            }
            let label = segment.speakerLabel
            #expect(label == TranscriptSegment.unattributed || label.hasPrefix("S"))
        }
    }
}
