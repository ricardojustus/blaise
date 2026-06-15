import FluidAudio
import Foundation
import os

// C4: diarization seam. `Diarizing` is NOT an `ASREngine` — it has no registry
// slot; C7 wires it into the pipeline directly. Production impl: FluidAudio
// 0.15.2 `OfflineDiarizerManager` (pyannote community-1 CoreML port, 17 ms
// frame resolution). SpeakerKit (argmax-oss-swift v1.0.0, MIT) is the recorded
// fallback — swap = one conformance (D10).

// MARK: - Protocol + output types

public protocol Diarizing: Sendable {
    func prepare() async throws
    func availability() async -> EngineAvailability
    func diarize(audioURL: URL, attendeeCount: Int?) async throws -> DiarizationOutput
}

public struct DiarizationOutput: Codable, Sendable, Equatable {
    public let segments: [DiarizedSegment]
    /// Distinct labels AFTER clamping/drops.
    public let speakerCount: Int

    public init(segments: [DiarizedSegment], speakerCount: Int) {
        self.segments = segments
        self.speakerCount = speakerCount
    }

    enum CodingKeys: String, CodingKey {
        case segments
        case speakerCount = "speaker_count"
    }
}

public struct DiarizedSegment: Codable, Sendable, Equatable {
    /// Normalized to `"S<n>"` (n = 0-based cluster index in first-appearance
    /// order) by the `Diarizing` implementation, whatever the library's
    /// native labels.
    public let speakerLabel: String
    public let startSeconds: Double
    public let endSeconds: Double

    public init(speakerLabel: String, startSeconds: Double, endSeconds: Double) {
        self.speakerLabel = speakerLabel
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }

    enum CodingKeys: String, CodingKey {
        case speakerLabel = "speaker_label"
        case startSeconds = "start_seconds"
        case endSeconds = "end_seconds"
    }
}

// MARK: - FluidAudio offline diarizer

/// Same actor + FIFO-chain serialization, integrity/wipe-repair, and
/// availability patterns as C3's `FluidAudioParakeetEngine`. Models are the
/// heavy shared state; an `OfflineDiarizerManager` is constructed per call so
/// `withSpeakers(min:max:)` can carry the per-call attendee-count constraint.
///
/// Embeddings exposed by the FluidAudio API are NOT persisted (V1.1 voice
/// fingerprint material, noted only).
public actor FluidAudioDiarizer: Diarizing {
    public static let diarizerID = "fluidaudio-diarizer-offline"
    public static let modelsPathKey = "modelsPath"
    /// Local cache folder FluidAudio downloads into. NOT the HF repo name:
    /// `Repo.folderName` strips the `-coreml` suffix ("speaker-diarization");
    /// referenced from the library so it can never drift.
    static let repoFolderName = Repo.diarizer.folderName

    /// Shared with the composition root / C7.
    public static let descriptors: [EngineConfigDescriptor] = [
        EngineConfigDescriptor(
            key: FluidAudioDiarizer.modelsPathKey, label: "Diarization models directory",
            kind: .path, required: false)
    ]

    private let configuration: EngineConfiguration
    private let dataRoot: URL
    private let chain = EngineTaskChain()
    private let logger = Logger(subsystem: BlaiseBundle.identifier, category: "diarizer.fluidaudio")

    /// Loaded models double as the cached last-successful-load result for
    /// this launch. `.stub` exists only for the test seam below.
    private enum LoadedModels { case real(OfflineDiarizerModels), stub }
    private var models: LoadedModels?
    private var lastLoadFailureReason: String?
    private var consecutiveLoadFailures = 0
    /// Test seam (C3 `modelFetchOverride` pattern): replaces the
    /// download+load step so repair decision logic is testable offline.
    private let modelLoadOverride: (@Sendable (URL) async throws -> Void)?

    public init(
        configuration: EngineConfiguration,
        dataRoot: URL,
        modelLoadOverride: (@Sendable (URL) async throws -> Void)? = nil
    ) {
        self.configuration = configuration
        self.dataRoot = dataRoot
        self.modelLoadOverride = modelLoadOverride
    }

    // MARK: - Paths

    /// The configured value (or default `<dataRoot>/models/fluidaudio-diar`)
    /// is the PARENT directory; FluidAudio's repo folder lives inside it.
    private func resolveModelsParent() async throws -> URL {
        let override: String?
        do {
            override = try await configuration.value(for: Self.modelsPathKey)
        } catch {
            throw EngineError.transient("cannot read diarizer configuration: \(error)")
        }
        return override.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? dataRoot.appendingPathComponent("models/fluidaudio-diar", isDirectory: true)
    }

    /// Structural integrity: all offline-variant model files present in the
    /// repo folder (Segmentation/FBank/Embedding/PldaRho `.mlmodelc` +
    /// `plda-parameters.json`).
    nonisolated static func modelsPresent(at repoDir: URL) -> Bool {
        ModelNames.OfflineDiarizer.requiredModels.allSatisfy {
            FileManager.default.fileExists(atPath: repoDir.appendingPathComponent($0).path)
        }
    }

    // MARK: - Availability

    public func availability() async -> EngineAvailability {
        if models != nil { return .available }
        let parent: URL
        do {
            parent = try await resolveModelsParent()
        } catch {
            return .unavailable(reason: "configuration unreadable: \(error)")
        }
        if let lastLoadFailureReason {
            return .unavailable(reason: "model load failed this launch: \(lastLoadFailureReason)")
        }
        guard Self.modelsPresent(at: parent.appendingPathComponent(Self.repoFolderName, isDirectory: true)) else {
            return .unavailable(reason: "models not yet downloaded (prepare fetches the diarization models)")
        }
        return .available
    }

    // MARK: - Chained entry points

    public func prepare() async throws {
        try await chain.run { try await self.prepareBody() }
    }

    public func diarize(audioURL: URL, attendeeCount: Int?) async throws -> DiarizationOutput {
        try await chain.run { try await self.diarizeBody(audioURL: audioURL, attendeeCount: attendeeCount) }
    }

    // MARK: - Bodies (un-chained; diarizeBody calls prepareBody directly,
    // never the chained public prepare — see the C3 serialization rule)

    private func prepareBody() async throws {
        if models != nil { return }  // idempotent; loaded for this launch
        if Task.isCancelled { throw EngineError.cancelled }
        let parent = try await resolveModelsParent()
        let repoDir = parent.appendingPathComponent(Self.repoFolderName, isDirectory: true)

        if !Self.modelsPresent(at: repoDir) {
            if let available = DiskSpace.availableBytes(at: parent), available < 1_073_741_824 {
                let gigabytes = Double(available) / 1_073_741_824
                throw EngineError.transient(
                    "insufficient disk space: need ≥ 1 GB free for diarization models, have \(String(format: "%.1f", gigabytes)) GB")
            }
        }

        do {
            // Downloads when missing, then loads + compiles. We call the
            // models loader directly (not manager.prepareModels) so the
            // wipe-repair pattern below owns failure handling.
            if let modelLoadOverride {
                try await modelLoadOverride(parent)
                models = .stub
            } else {
                models = .real(try await OfflineDiarizerModels.load(from: parent))
            }
            consecutiveLoadFailures = 0
            lastLoadFailureReason = nil
        } catch is CancellationError {
            throw EngineError.cancelled
        } catch {
            consecutiveLoadFailures += 1
            lastLoadFailureReason = "\(error)"
            // Repair: load failure wipes the repo dir; the next prepare()
            // re-downloads. Two consecutive failures → permanent.
            try? FileManager.default.removeItem(at: repoDir)
            logger.error(
                "diarizer model load failed (attempt \(self.consecutiveLoadFailures)): \(String(describing: error))")
            if consecutiveLoadFailures >= 2 {
                throw EngineError.permanent("diarizer model load failed twice consecutively: \(error)")
            }
            throw EngineError.transient(
                "diarizer model load failed (models dir wiped; next prepare re-downloads): \(error)")
        }
    }

    private func diarizeBody(audioURL: URL, attendeeCount: Int?) async throws -> DiarizationOutput {
        if Task.isCancelled { throw EngineError.cancelled }
        try await prepareBody()
        guard case .real(let models) = models else {
            throw EngineError.notAvailable(reason: "diarization models not loaded")
        }

        let wavInfo: WAVHeader.Info
        do {
            wavInfo = try WAVHeader.read(at: audioURL)
        } catch {
            throw EngineError.permanent("bad input: cannot read WAV header: \(error)")
        }
        let audioDuration = wavInfo.duration

        // Speaker-count constraint when the attendee count is known: pyannote
        // semantics, never `exactly` (the count is a hint, not ground truth).
        var config = OfflineDiarizerConfig.default
        if let attendeeCount {
            config = config.withSpeakers(min: 1, max: attendeeCount + 1)
        }

        if Task.isCancelled { throw EngineError.cancelled }
        let raw: [(speakerLabel: String, startSeconds: Double, endSeconds: Double)]
        do {
            let manager = OfflineDiarizerManager(config: config)
            manager.initialize(models: models)
            let result = try await manager.process(audioURL)
            raw = result.segments.map {
                ($0.speakerId, Double($0.startTimeSeconds), Double($0.endTimeSeconds))
            }
        } catch is CancellationError {
            throw EngineError.cancelled
        } catch OfflineDiarizationError.noSpeechDetected {
            // Silence is a VALID diarization result, not a failure: an
            // in-person recording (or any meeting where no other audio
            // plays) has a legitimately silent system track — everyone is
            // on the mic track. Zero segments / zero speakers lets the
            // captured-meeting merge proceed honestly. (Found by the user's
            // an early touchpoint recording.)
            logger.info("diarization: no speech in track — 0 segments, 0 speakers (valid silence)")
            return DiarizationOutput(segments: [], speakerCount: 0)
        } catch {
            if Task.isCancelled { throw EngineError.cancelled }
            throw EngineError.transient("diarization failed: \(error)")
        }
        if Task.isCancelled { throw EngineError.cancelled }

        let output = Self.normalizedOutput(raw, audioDuration: audioDuration)
        logger.info(
            "diarization: \(output.segments.count)/\(raw.count) segments, \(output.speakerCount) speakers")
        return output
    }

    // MARK: - Output post-processing (C4-owned)

    /// Clamps segments to the audio duration (the probed real output overruns
    /// it — frame-quantization overshoot, e.g. max end 300.0849 on a 300.032 s
    /// file); segments entirely past EOF are dropped; native labels are
    /// normalized to `"S<n>"` in first-appearance order over the time-sorted,
    /// post-drop list.
    static func normalizedOutput(
        _ raw: [(speakerLabel: String, startSeconds: Double, endSeconds: Double)],
        audioDuration: Double
    ) -> DiarizationOutput {
        let sorted = raw.sorted {
            ($0.startSeconds, $0.endSeconds, $0.speakerLabel)
                < ($1.startSeconds, $1.endSeconds, $1.speakerLabel)
        }
        var clamped: [(label: String, start: Double, end: Double)] = []
        for segment in sorted {
            if segment.startSeconds >= audioDuration { continue }  // entirely past EOF
            let end = min(segment.endSeconds, audioDuration)
            if end <= segment.startSeconds { continue }
            clamped.append((segment.speakerLabel, segment.startSeconds, end))
        }
        var labelMap: [String: String] = [:]
        var segments: [DiarizedSegment] = []
        for segment in clamped {
            let normalized: String
            if let existing = labelMap[segment.label] {
                normalized = existing
            } else {
                normalized = "S\(labelMap.count)"
                labelMap[segment.label] = normalized
            }
            segments.append(
                DiarizedSegment(
                    speakerLabel: normalized, startSeconds: segment.start, endSeconds: segment.end))
        }
        return DiarizationOutput(segments: segments, speakerCount: labelMap.count)
    }
}
