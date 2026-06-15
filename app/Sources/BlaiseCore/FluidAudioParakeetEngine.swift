import FluidAudio
import Foundation
import os

/// Engine 2: Parakeet TDT 0.6b v3 via FluidAudio 0.15.2 (exact; CoreML).
/// Same FIFO-chain serialization as the whisper engine; `AsrManager` is
/// created once per engine, with a fresh `TdtDecoderState` per call.
///
/// Runtime-identity note (C3 spec): 0.15.2 = rev 7f963cd, not verified to
/// contain the research commit f3760dc — the real-audio integration test is
/// the runtime validation; if its output regresses against the research
/// transcript shape, D5 is revisited before the chunk closes.
public actor FluidAudioParakeetEngine: ASREngine {
    public static let engineID = "fluidaudio-parakeet-v3"
    public static let modelName = "parakeet-tdt-0.6b-v3"
    public static let runtimeVersion = "0.15.2"
    public static let modelsPathKey = "modelsPath"
    /// HF repo folder FluidAudio downloads into (Repo.parakeetV3.folderName).
    static let repoFolderName = "parakeet-tdt-0.6b-v3-coreml"

    public nonisolated let id: String = FluidAudioParakeetEngine.engineID
    public nonisolated let displayName = "Parakeet v3 (FluidAudio)"
    public nonisolated let kind: EngineKind = .local
    public nonisolated let costDescriptor: EngineCostDescriptor? = nil
    /// Shared with the composition root.
    public static let descriptors: [EngineConfigDescriptor] = [
        EngineConfigDescriptor(
            key: FluidAudioParakeetEngine.modelsPathKey, label: "Models directory", kind: .path,
            required: false)
    ]
    public nonisolated let configDescriptors: [EngineConfigDescriptor] = FluidAudioParakeetEngine.descriptors

    private let configuration: EngineConfiguration
    private let dataRoot: URL
    private let chain = EngineTaskChain()
    private let logger = Logger(subsystem: BlaiseBundle.identifier, category: "asr.parakeet")

    /// Created once per engine on first successful prepare; doubles as the
    /// cached last-successful-load result for this launch.
    private var manager: AsrManager?
    private var lastLoadFailureReason: String?
    private var consecutiveLoadFailures = 0

    public init(configuration: EngineConfiguration, dataRoot: URL) {
        self.configuration = configuration
        self.dataRoot = dataRoot
    }

    // MARK: - Paths

    /// The configured value (or default `<dataRoot>/models/fluidaudio`) is
    /// the PARENT directory; FluidAudio's repo folder lives inside it.
    private func resolveModelsDir() async throws -> URL {
        let override: String?
        do {
            override = try await configuration.value(for: Self.modelsPathKey)
        } catch {
            throw EngineError.transient("cannot read engine configuration: \(error)")
        }
        let base =
            override.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? dataRoot.appendingPathComponent("models/fluidaudio", isDirectory: true)
        return base.appendingPathComponent(Self.repoFolderName, isDirectory: true)
    }

    // MARK: - Availability

    public func availability() async -> EngineAvailability {
        if manager != nil { return .available }
        let modelsDir: URL
        do {
            modelsDir = try await resolveModelsDir()
        } catch {
            return .unavailable(reason: "configuration unreadable: \(error)")
        }
        if let lastLoadFailureReason {
            return .unavailable(reason: "model load failed this launch: \(lastLoadFailureReason)")
        }
        guard AsrModels.modelsExist(at: modelsDir) else {
            return .unavailable(reason: "models not yet downloaded (prepare fetches ~461 MB)")
        }
        return .available
    }

    // MARK: - Chained entry points

    public func prepare() async throws {
        try await chain.run { try await self.prepareBody() }
    }

    public func transcribe(_ request: ASRRequest) async throws -> ASRResult {
        try await chain.run { try await self.transcribeBody(request) }
    }

    // MARK: - Bodies (un-chained)

    private func prepareBody() async throws {
        if manager != nil { return }  // idempotent; loaded for this launch
        if Task.isCancelled { throw EngineError.cancelled }
        let modelsDir = try await resolveModelsDir()

        if !AsrModels.modelsExist(at: modelsDir) {
            if let available = DiskSpace.availableBytes(at: modelsDir.deletingLastPathComponent()),
                available < 1_073_741_824
            {
                let gigabytes = Double(available) / 1_073_741_824
                throw EngineError.transient(
                    "insufficient disk space: need ≥ 1 GB free for Parakeet models, have \(String(format: "%.1f", gigabytes)) GB")
            }
        }

        do {
            let models = try await AsrModels.downloadAndLoad(to: modelsDir, version: .v3)
            let loaded = AsrManager(config: .default)
            try await loaded.loadModels(models)
            manager = loaded
            consecutiveLoadFailures = 0
            lastLoadFailureReason = nil
        } catch is CancellationError {
            throw EngineError.cancelled
        } catch {
            consecutiveLoadFailures += 1
            lastLoadFailureReason = "\(error)"
            // Repair: load failure wipes the models dir; the next prepare()
            // re-downloads. Two consecutive failures → permanent.
            try? FileManager.default.removeItem(at: modelsDir)
            logger.error("Parakeet model load failed (attempt \(self.consecutiveLoadFailures)): \(String(describing: error))")
            if consecutiveLoadFailures >= 2 {
                throw EngineError.permanent("Parakeet model load failed twice consecutively: \(error)")
            }
            throw EngineError.transient(
                "Parakeet model load failed (models dir wiped; next prepare re-downloads): \(error)")
        }
    }

    private func transcribeBody(_ request: ASRRequest) async throws -> ASRResult {
        if Task.isCancelled { throw EngineError.cancelled }
        try await prepareBody()
        guard let manager else {
            throw EngineError.notAvailable(reason: "Parakeet models not loaded")
        }

        let wavInfo: WAVHeader.Info
        do {
            wavInfo = try WAVHeader.read(at: request.audioURL)
        } catch {
            throw EngineError.permanent("bad input: cannot read WAV header: \(error)")
        }
        let audioDuration = wavInfo.duration

        // Unknown/invalid hint → auto-LID (nil), recorded verbatim in provenance.
        // (`Language` resolves to FluidAudio's — BlaiseCore declares none.)
        let language = request.languageHint.flatMap { hint in
            Language(rawValue: String(hint.prefix(while: { $0 != "-" })).lowercased())
        }

        if Task.isCancelled { throw EngineError.cancelled }
        var decoderState: TdtDecoderState
        do {
            decoderState = try TdtDecoderState()  // fresh per call
        } catch {
            throw EngineError.transient("cannot create decoder state: \(error)")
        }

        // The transcription result is used inside the `do` scope because its
        // type cannot be named from here: the module ships a type literally
        // named `FluidAudio` (qualification resolves to it, not the module)
        // and BlaiseCore's own ASRResult shadows the unqualified name.
        let segments: [ASRSegment]
        let rawPayload: Data
        do {
            let raw = try await manager.transcribe(
                request.audioURL, decoderState: &decoderState, language: language)
            segments = TokenSegmenter.segments(
                tokenTimings: raw.tokenTimings ?? [],
                fullText: raw.text,
                audioDuration: audioDuration
            )
            rawPayload = (try? JSONEncoder().encode(raw)) ?? Data()
        } catch is CancellationError {
            throw EngineError.cancelled
        } catch {
            if Task.isCancelled { throw EngineError.cancelled }
            throw EngineError.transient("Parakeet transcription failed: \(error)")
        }
        if Task.isCancelled { throw EngineError.cancelled }

        let (normalized, report) = SegmentNormalizer.normalize(segments, audioDuration: audioDuration)
        logger.info(
            "parakeet normalization: kept \(normalized.count)/\(segments.count) — droppedNonLatinScript \(report.droppedNonLatinScript), droppedRepetitionRun \(report.droppedRepetitionRun), droppedEmpty \(report.droppedEmpty), droppedZeroLength \(report.droppedZeroLength), droppedOutOfBounds \(report.droppedOutOfBounds), clampedRetained \(report.clampedRetained), clampedDropped \(report.clampedDropped), overlapsResolved \(report.overlapsResolved)"
        )

        return ASRResult(
            segments: normalized,
            detectedLanguage: nil,  // FluidAudio reports no whole-file language judgment
            rawPayload: rawPayload,
            usage: nil,
            provenance: ASRProvenance(
                engine: id,
                model: Self.modelName,
                runtime: "FluidAudio \(Self.runtimeVersion)/CoreML",
                engineVersion: Self.runtimeVersion,
                transcribedAt: Date(),
                vocabularyHintsApplied: false,
                languageHint: request.languageHint
            )
        )
    }
}
