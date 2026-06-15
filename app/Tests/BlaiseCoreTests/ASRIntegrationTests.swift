import Foundation
import Testing
@testable import BlaiseCore

// AC2: REAL-audio integration tests. These must RUN on this machine (the
// research venv + HF cache + FluidAudio models exist); when a precondition
// is genuinely missing they follow the skip protocol — write
// `<repo>/.test-skips/<test>.txt` and return — never silently green.

private let repoRoot = VocabFixtures.repoRoot
private let researchVenv = repoRoot.appendingPathComponent("research/asr/.venv", isDirectory: true)
private let realHFHome = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".cache/huggingface", isDirectory: true)
private let fluidAudioModelsParent = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/FluidAudio/Models", isDirectory: true)

private func tokenize(_ text: String) -> [String] {
    text.lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
}

@Suite(.serialized) struct ASRIntegrationTests {
    @Test(.timeLimit(.minutes(10)))
    func whisperTranscribesRealSegA() async throws {
        let wav = VocabFixtures.fixture("icsi_sample/Bmr001_excerpt_5min.wav")
        guard FileManager.default.isExecutableFile(atPath: researchVenv.appendingPathComponent("bin/python").path),
            WhisperModelCache(hfHome: realHFHome).integrity()
        else {
            recordTestSkip(
                "whisperTranscribesRealSegA",
                reason: "research venv or HF whisper cache missing on this machine")
            return
        }

        let dataRoot = try makeTempRoot()
        let database = try BlaiseDatabase(rootURL: dataRoot)
        let settings = SettingsStore(database: database)
        // Seams per the C3 kickoff: externally-managed research venv + the
        // real HF cache (1.5 GB whisper-large-v3-turbo already present).
        try await settings.set(
            "engine.\(MLXWhisperEngine.engineID).\(MLXWhisperEngine.venvPathKey)",
            to: researchVenv.path)
        try await settings.set(
            "engine.\(MLXWhisperEngine.engineID).\(MLXWhisperEngine.hfHomePathKey)",
            to: realHFHome.path)
        let engine = MLXWhisperEngine(
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

        // External venv: availability = import check only — available now.
        #expect(await engine.availability() == .available)

        let started = Date()
        let result = try await engine.transcribe(ASRRequest(audioURL: wav, languageHint: "en"))
        let elapsed = Date().timeIntervalSince(started)
        print("[integration] whisper icsi: \(result.segments.count) segments in \(String(format: "%.1f", elapsed)) s")

        let duration = try WAVHeader.read(at: wav).duration  // 300.0

        // Normalized-output contract.
        #expect(result.segments.count >= 10)
        for (index, segment) in result.segments.enumerated() {
            #expect(!segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(segment.startSeconds >= 0)
            #expect(segment.endSeconds <= 300.04)
            #expect(segment.endSeconds > segment.startSeconds)
            if index > 0 {
                #expect(segment.startSeconds >= result.segments[index - 1].endSeconds)
                #expect(segment.startSeconds > result.segments[index - 1].startSeconds)
            }
        }
        // Word timings present (C4 dependency).
        #expect(result.segments.allSatisfy { $0.words != nil })
        #expect(result.segments.contains { !($0.words ?? []).isEmpty })

        // English content sanity: common EN function words.
        let tokens = Set(tokenize(result.segments.map(\.text).joined(separator: " ")))
        let functionWords = ["the", "and", "to", "of", "that", "a"].filter { tokens.contains($0) }
        #expect(functionWords.count >= 3, "expected EN function words, found \(functionWords)")
        #expect(result.detectedLanguage == "en")

        // The raw payload preserves everything; re-normalizing it reproduces
        // the engine's output and exposes the report. The drop classes stay
        // covered by SegmentNormalizerTests' synthetic pathological inputs.
        let raw = try JSONDecoder().decode(WhisperDriverOutput.self, from: result.rawPayload)
        let (renormalized, report) = SegmentNormalizer.normalize(raw.asrSegments, audioDuration: duration)
        #expect(renormalized == result.segments)
        #expect(raw.segments.count >= renormalized.count)
        #expect(report.droppedEmpty + report.droppedOutOfBounds + report.clampedDropped + report.droppedZeroLength
                == raw.segments.count - renormalized.count)

        // Provenance honest.
        #expect(result.provenance.engine == "mlx-whisper-large-v3-turbo")
        #expect(result.provenance.model == "mlx-community/whisper-large-v3-turbo")
        #expect(result.provenance.runtime == "mlx-whisper/subprocess")
        #expect(result.provenance.engineVersion == "0.4.3")
        #expect(result.provenance.languageHint == "en")
        #expect(!result.provenance.vocabularyHintsApplied)
    }

    @Test(.timeLimit(.minutes(30)))
    func parakeetTranscribesRealSegB() async throws {
        let wav = VocabFixtures.fixture("icsi_sample/Bmr001_excerpt_5min.wav")
        let oracleURL = repoRoot.appendingPathComponent("research/asr/out/fluidaudio_parakeet/icsi_excerpt.txt")
        // The oracle is minted by a later model run; absent it, skip cleanly
        // rather than hard-fail (the stacks/model guard is implicit — prepare()
        // below is what exercises the FluidAudio models).
        guard FileManager.default.fileExists(atPath: oracleURL.path)
        else {
            recordTestSkip(
                "parakeetTranscribesRealSegB",
                reason: "committed Parakeet oracle (icsi_excerpt.txt) missing — minted at a model run")
            return
        }

        let dataRoot = try makeTempRoot()
        let database = try BlaiseDatabase(rootURL: dataRoot)
        let settings = SettingsStore(database: database)
        // Reuse the machine's FluidAudio model cache when present (avoids a
        // 461 MB download); otherwise FluidAudio downloads there — allowed on
        // the first integration run.
        try await settings.set(
            "engine.\(FluidAudioParakeetEngine.engineID).\(FluidAudioParakeetEngine.modelsPathKey)",
            to: fluidAudioModelsParent.path)
        let engine = FluidAudioParakeetEngine(
            configuration: EngineConfiguration(
                engineID: FluidAudioParakeetEngine.engineID,
                descriptors: FluidAudioParakeetEngine.descriptors,
                settings: settings,
                secrets: InMemorySecretStore()),
            dataRoot: dataRoot)

        let started = Date()
        try await engine.prepare()
        let prepared = Date()
        #expect(await engine.availability() == .available)
        let result = try await engine.transcribe(ASRRequest(audioURL: wav))
        let elapsed = Date().timeIntervalSince(prepared)
        print(
            "[integration] parakeet icsi: \(result.segments.count) segments; prepare \(String(format: "%.1f", prepared.timeIntervalSince(started))) s, transcribe \(String(format: "%.1f", elapsed)) s"
        )

        let duration = try WAVHeader.read(at: wav).duration

        // Generic engine assertions (same contract as engine 1).
        #expect(result.segments.count >= 10)
        for (index, segment) in result.segments.enumerated() {
            #expect(!segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(segment.startSeconds >= 0)
            #expect(segment.endSeconds <= duration)
            if index > 0 { #expect(segment.startSeconds >= result.segments[index - 1].endSeconds) }
        }
        // Engine 2 POPULATES words from token timings (C4 contract).
        #expect(result.segments.allSatisfy { $0.words != nil && !($0.words ?? []).isEmpty })

        // Segmenter shape comparison against the one committed oracle
        // (research/asr/out/fluidaudio_parakeet/icsi_excerpt.txt). Tolerant by
        // necessity: research artifacts hold post-merge TEXT only, and
        // 0.15.2 is a different rev than the research checkout.
        let oracleTokens = tokenize(try String(contentsOf: oracleURL, encoding: .utf8))
        let ourTokens = tokenize(result.segments.map(\.text).joined(separator: " "))
        let overlap = overlapRatio(ourTokens, oracleTokens)
        print("[integration] parakeet icsi token overlap vs oracle: \(String(format: "%.3f", overlap))")
        #expect(overlap >= 0.7, "token overlap vs research oracle too low: \(overlap)")
        let lengthRatio = Double(ourTokens.count) / Double(oracleTokens.count)
        #expect(lengthRatio > 0.75 && lengthRatio < 1.33, "length ratio off: \(lengthRatio)")

        // Boundary shape: speech spans essentially the whole file.
        #expect(try #require(result.segments.first).startSeconds < 10)
        #expect(try #require(result.segments.last).endSeconds > duration - 20)

        // Provenance honest.
        #expect(result.provenance.engine == "fluidaudio-parakeet-v3")
        #expect(result.provenance.model == "parakeet-tdt-0.6b-v3")
        #expect(result.provenance.runtime == "FluidAudio 0.15.2/CoreML")
        #expect(result.provenance.engineVersion == "0.15.2")
    }

    /// Multiset token overlap relative to the larger side.
    private func overlapRatio(_ a: [String], _ b: [String]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var counts: [String: Int] = [:]
        for token in a { counts[token, default: 0] += 1 }
        var shared = 0
        for token in b where (counts[token] ?? 0) > 0 {
            counts[token]! -= 1
            shared += 1
        }
        return Double(shared) / Double(max(a.count, b.count))
    }
}
