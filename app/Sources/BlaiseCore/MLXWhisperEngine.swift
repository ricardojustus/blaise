import Foundation
import os

/// Engine 1 (default): Whisper large-v3-turbo via an mlx-whisper 0.4.3
/// subprocess (decision D5). WAV in → normalized segments out; the raw
/// driver JSON stays verbatim in `rawPayload`.
///
/// Serialization: public `prepare()`/`transcribe()` are FIFO chain links
/// (`EngineTaskChain`); their bodies are un-chained, and `transcribeBody()`
/// calls `prepareBody()` DIRECTLY — never the public chained `prepare()`,
/// which would enqueue behind itself and deadlock.
public actor MLXWhisperEngine: ASREngine {
    public static let engineID = "mlx-whisper-large-v3-turbo"
    public static let modelRepo = "mlx-community/whisper-large-v3-turbo"
    public static let venvPathKey = "venvPath"
    public static let hfHomePathKey = "hfHomePath"

    public nonisolated let id: String = MLXWhisperEngine.engineID
    public nonisolated let displayName = "Whisper large-v3-turbo (MLX)"
    public nonisolated let kind: EngineKind = .local
    public nonisolated let costDescriptor: EngineCostDescriptor? = nil
    /// Shared with the composition root (the `EngineConfiguration` handle is
    /// built from the same descriptors the engine declares).
    public static let descriptors: [EngineConfigDescriptor] = [
        EngineConfigDescriptor(
            key: MLXWhisperEngine.venvPathKey, label: "Python venv path", kind: .path, required: false),
        EngineConfigDescriptor(
            key: MLXWhisperEngine.hfHomePathKey, label: "Model cache (HF_HOME) path", kind: .path, required: false),
    ]
    public nonisolated let configDescriptors: [EngineConfigDescriptor] = MLXWhisperEngine.descriptors

    private let configuration: EngineConfiguration
    private let dataRoot: URL
    private let uvBinary: URL
    private let driverScript: URL
    private let requirementsFile: URL
    private let chain = EngineTaskChain()
    private let logger = Logger(subsystem: BlaiseBundle.identifier, category: "asr.whisper")
    /// engineVersion cache, per venv path, per launch (override-honest).
    private var cachedEngineVersions: [String: String] = [:]

    // Test seams (internal): replace the network model fetch; shrink timeouts.
    let modelFetchOverride: (@Sendable (_ hfHome: URL) async throws -> Void)?
    let driverTimeoutOverride: TimeInterval?

    public init(
        configuration: EngineConfiguration,
        dataRoot: URL,
        uvBinary: URL,
        driverScript: URL,
        requirementsFile: URL
    ) {
        self.init(
            configuration: configuration, dataRoot: dataRoot, uvBinary: uvBinary,
            driverScript: driverScript, requirementsFile: requirementsFile,
            sweepOrphansOnInit: true, modelFetchOverride: nil, driverTimeoutOverride: nil)
    }

    init(
        configuration: EngineConfiguration,
        dataRoot: URL,
        uvBinary: URL,
        driverScript: URL,
        requirementsFile: URL,
        sweepOrphansOnInit: Bool,
        modelFetchOverride: (@Sendable (_ hfHome: URL) async throws -> Void)? = nil,
        driverTimeoutOverride: TimeInterval? = nil
    ) {
        self.configuration = configuration
        self.dataRoot = dataRoot
        self.uvBinary = uvBinary
        self.driverScript = driverScript
        self.requirementsFile = requirementsFile
        self.modelFetchOverride = modelFetchOverride
        self.driverTimeoutOverride = driverTimeoutOverride
        if sweepOrphansOnInit {
            let path = driverScript.path
            let log = logger
            Task.detached { await OrphanSweeper.sweep(driverPath: path, logger: log) }
        }
    }

    /// Bundled resources (SwiftPM resource bundle; present in the .app via
    /// scripts/build_app.sh).
    public static func bundledDriverScript() -> URL? {
        BlaiseResources.bundle.url(forResource: "whisper_driver", withExtension: "py")
    }

    /// The SHARED pin set (whisper + notes stacks, one venv): renamed
    /// `python_requirements.txt` by C6.
    public static func bundledRequirementsFile() -> URL? {
        BlaiseResources.bundle.url(forResource: "python_requirements", withExtension: "txt")
    }

    // MARK: - Resolved environment (live read-through, per call)

    struct ResolvedEnvironment: Sendable {
        var venvDir: URL
        /// True when `venvPath` config overrides the default: the venv is
        /// externally managed — provisioning and ALL sentinel logic are
        /// disabled for it (no destroy/rebuild/invalidation ever).
        var venvIsExternallyManaged: Bool
        var hfHome: URL

        var pythonBinary: URL {
            venvDir.appendingPathComponent("bin/python")
        }
    }

    private func resolveEnvironment() async throws -> ResolvedEnvironment {
        let venvOverride: String?
        let hfHomeOverride: String?
        do {
            venvOverride = try await configuration.value(for: Self.venvPathKey)
            hfHomeOverride = try await configuration.value(for: Self.hfHomePathKey)
        } catch {
            throw EngineError.transient("cannot read engine configuration: \(error)")
        }
        let layout = VenvLayout(dataRoot: dataRoot)
        let venvDir = venvOverride.map { URL(fileURLWithPath: expandTilde($0), isDirectory: true) }
        let hfHome = hfHomeOverride.map { URL(fileURLWithPath: expandTilde($0), isDirectory: true) }
            ?? dataRoot.appendingPathComponent("models/hf", isDirectory: true)
        return ResolvedEnvironment(
            venvDir: venvDir ?? layout.venvDir,
            venvIsExternallyManaged: venvDir != nil,
            hfHome: hfHome
        )
    }

    private nonisolated func expandTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    // MARK: - Availability

    public func availability() async -> EngineAvailability {
        let environment: ResolvedEnvironment
        do {
            environment = try await resolveEnvironment()
        } catch {
            return .unavailable(reason: "configuration unreadable: \(error)")
        }
        if environment.venvIsExternallyManaged {
            // Externally managed venv: availability = import check only.
            if let failure = await importCheckFailure(python: environment.pythonBinary) {
                return .unavailable(reason: "external venv import check failed: \(failure)")
            }
        } else {
            guard let requirementsData = try? Data(contentsOf: requirementsFile) else {
                return .unavailable(reason: "bundled python_requirements.txt missing")
            }
            guard VenvLayout.isProvisioned(venvDir: environment.venvDir, requirementsData: requirementsData)
            else {
                return .unavailable(reason: "not yet provisioned")
            }
        }
        let cache = WhisperModelCache(hfHome: environment.hfHome)
        guard cache.integrity() else {
            return .unavailable(reason: "model cache missing or incomplete (prepare will fetch)")
        }
        return .available
    }

    /// nil = import succeeded; otherwise a reason string.
    private func importCheckFailure(python: URL) async -> String? {
        await pythonImportCheckFailure(python: python, modules: ["mlx_whisper"])
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
        let environment = try await resolveEnvironment()
        if !environment.venvIsExternallyManaged {
            try await provisionVenvIfNeeded(environment)
        }
        // Model-cache step runs in BOTH modes: the cache is engine-owned, not
        // venv-owned; suspect/repair applies normally under a venv override.
        try await ensureModelCache(environment)
    }

    private func transcribeBody(_ request: ASRRequest) async throws -> ASRResult {
        if Task.isCancelled { throw EngineError.cancelled }
        try await prepareBody()

        let environment = try await resolveEnvironment()
        let wavInfo: WAVHeader.Info
        do {
            wavInfo = try WAVHeader.read(at: request.audioURL)
        } catch {
            throw EngineError.permanent("bad input: cannot read WAV header: \(error)")
        }
        let audioDuration = wavInfo.duration

        let cache = WhisperModelCache(hfHome: environment.hfHome)
        var processEnvironment = minimalEnvironment()
        processEnvironment["HF_HOME"] = environment.hfHome.path
        processEnvironment["HF_HUB_DISABLE_TELEMETRY"] = "1"
        // Offline only when the cache is whole AND unsuspected; otherwise the
        // driver may legitimately need the network to (re)fetch.
        if cache.integrity(), cache.suspectState() == nil {
            processEnvironment["HF_HUB_OFFLINE"] = "1"
        }

        var arguments = [driverScript.path, "--blaise-engine", "--audio", request.audioURL.path]
        if let hint = request.languageHint {
            // Whisper takes bare ISO 639-1 codes; BCP-47 regioned hints like
            // "pt-BR" (valid per the C2 contract, natural for this user) would
            // exit 2 → .permanent. Primary subtag only; provenance keeps the
            // original hint verbatim (impl audit M4; Parakeet already strips).
            let primary = hint.split(separator: "-").first.map(String.init) ?? hint
            arguments += ["--language", primary.lowercased()]
        }

        let timeout = driverTimeoutOverride ?? max(600, 3 * audioDuration)
        let outcome: SubprocessRunner.Outcome
        do {
            // Driver runs against the APP-MANAGED venv hold the SHARED
            // environment lock for the subprocess lifetime (C6 lock scheme):
            // a rebuild can never destroy the interpreter under an in-flight
            // transcription. An externally managed venv is never rebuilt, so
            // its runs take no lock (and leave no `<dataRoot>/python` trace).
            outcome = try await withSharedPythonLock(
                dataRoot: dataRoot, bypass: environment.venvIsExternallyManaged
            ) {
                try await SubprocessRunner.run(
                    executable: environment.pythonBinary,
                    arguments: arguments,
                    environment: processEnvironment,
                    timeout: timeout
                )
            }
        } catch let error as EngineError {
            throw error
        } catch {
            // Spawn failure: broken interpreter. Invalidate the sentinel so the
            // next prepare rebuilds (self-heal) — UNLESS the venv is externally
            // managed (no sentinel side effects ever).
            if !environment.venvIsExternallyManaged {
                invalidateSentinel(environment)
            }
            throw EngineError.notAvailable(reason: "python interpreter failed to launch: \(error)")
        }

        if outcome.cancelled { throw EngineError.cancelled }
        if outcome.timedOut { throw EngineError.transient("timeout") }
        guard let status = outcome.exitStatus else {
            throw EngineError.transient("driver terminated without status: \(excerpt(outcome.stderrTail))")
        }
        if outcome.terminationReason == .uncaughtSignal {
            throw EngineError.transient("driver killed by signal: \(excerpt(outcome.stderrTail))")
        }
        switch status {
        case 0:
            break
        case 2:
            throw EngineError.permanent("bad input: \(excerpt(outcome.stderrTail))")
        case 3:
            throw mapModelLoadFailure(cache: cache, stderr: outcome.stderrTail)
        case 4:
            throw EngineError.transient("transcribe failure: \(excerpt(outcome.stderrTail))")
        default:
            throw EngineError.transient("driver exit \(status): \(excerpt(outcome.stderrTail))")
        }

        let parsed: WhisperDriverOutput
        do {
            parsed = try JSONDecoder().decode(WhisperDriverOutput.self, from: outcome.stdout)
        } catch {
            throw EngineError.transient("driver stdout was not the expected JSON: \(error)")
        }

        // Successful transcribe: cache exonerated.
        cache.clearSuspect()

        let (segments, report) = SegmentNormalizer.normalize(parsed.asrSegments, audioDuration: audioDuration)
        logger.info(
            "whisper normalization: kept \(segments.count)/\(parsed.segments.count) — droppedNonLatinScript \(report.droppedNonLatinScript), droppedRepetitionRun \(report.droppedRepetitionRun), droppedEmpty \(report.droppedEmpty), droppedZeroLength \(report.droppedZeroLength), droppedOutOfBounds \(report.droppedOutOfBounds), clampedRetained \(report.clampedRetained), clampedDropped \(report.clampedDropped), overlapsResolved \(report.overlapsResolved)"
        )

        let version = await engineVersion(environment)
        return ASRResult(
            segments: segments,
            detectedLanguage: parsed.language,
            rawPayload: outcome.stdout,
            usage: nil,
            provenance: ASRProvenance(
                engine: id,
                model: Self.modelRepo,
                runtime: "mlx-whisper/subprocess",
                engineVersion: version,
                transcribedAt: Date(),
                vocabularyHintsApplied: false,
                languageHint: request.languageHint
            )
        )
    }

    // MARK: - Provisioning (default venv only)

    private func provisionVenvIfNeeded(_ environment: ResolvedEnvironment) async throws {
        // Shared infrastructure (PythonRuntime.swift): exclusive-lock
        // try-then-wait ≤ 30 s, destroy+rebuild, hashed install, sentinel.
        let provisioner = PythonVenvProvisioner(
            dataRoot: dataRoot,
            uvBinary: uvBinary,
            requirementsFile: requirementsFile,
            importCheckModules: ["mlx_whisper"],
            logger: logger
        )
        try await provisioner.provisionIfNeeded(venvDir: environment.venvDir)
    }

    // MARK: - Model cache step

    private func ensureModelCache(_ environment: ResolvedEnvironment) async throws {
        let cache = WhisperModelCache(hfHome: environment.hfHome)
        let integrity = cache.integrity()
        let suspect = cache.suspectState()
        if integrity, suspect == nil { return }
        if let suspect, suspect.permanentFailure {
            // Verdict already final: do NOT wipe/re-download again (M3).
            throw EngineError.permanent(
                "model cache failed twice after wipe-repair; reset the cache to retry (delete \(cache.suspectMarkerURL.path))")
        }

        // A fetch (or wipe + full re-fetch) is about to run.
        if let available = DiskSpace.availableBytes(at: environment.hfHome),
            available < 4 * 1_073_741_824
        {
            let gigabytes = Double(available) / 1_073_741_824
            throw EngineError.transient(
                "insufficient disk space: need ≥ 4 GB free for the model cache, have \(String(format: "%.1f", gigabytes)) GB")
        }

        if integrity, suspect != nil {
            // Integrity holds yet loads fail → in-place corruption, the class
            // a resumed download cannot fix: wipe the pinned repo's cache dir,
            // then full re-fetch (the Parakeet engine's own pattern).
            logger.warning("model cache suspect with intact integrity — wiping \(cache.repoCacheDir.path)")
            try? FileManager.default.removeItem(at: cache.repoCacheDir)
            try await fetchModel(environment)
            cache.recordRepairCompleted()
        } else {
            // Integrity false: hub fetch with network allowed (resumes
            // incomplete downloads).
            try await fetchModel(environment)
        }
    }

    private func fetchModel(_ environment: ResolvedEnvironment) async throws {
        if let modelFetchOverride {
            try await modelFetchOverride(environment.hfHome)
            return
        }
        var processEnvironment = minimalEnvironment()
        processEnvironment["HF_HOME"] = environment.hfHome.path
        processEnvironment["HF_HUB_DISABLE_TELEMETRY"] = "1"
        let outcome: SubprocessRunner.Outcome
        do {
            outcome = try await SubprocessRunner.run(
                executable: environment.pythonBinary,
                arguments: [
                    "-c",
                    "import sys, huggingface_hub; huggingface_hub.snapshot_download(repo_id=sys.argv[1])",
                    Self.modelRepo,
                ],
                environment: processEnvironment,
                timeout: 3600
            )
        } catch {
            if !environment.venvIsExternallyManaged {
                invalidateSentinel(environment)
            }
            throw EngineError.notAvailable(reason: "python interpreter failed to launch: \(error)")
        }
        if outcome.cancelled { throw EngineError.cancelled }
        if outcome.timedOut { throw EngineError.transient("model download timed out") }
        guard outcome.exitStatus == 0 else {
            throw EngineError.transient("model download failed: \(excerpt(outcome.stderrTail))")
        }
    }

    // MARK: - Error-mapping helpers

    private func mapModelLoadFailure(cache: WhisperModelCache, stderr: String) -> EngineError {
        if let state = cache.suspectState(), state.repairedSinceLastFailure {
            // Second exit-3 after a COMPLETED wipe-repair, no successful
            // transcribe between → permanent; finalize so repair stops (M3).
            cache.recordPermanentFailure()
            return .permanent(
                "model load failed again after cache wipe-repair (\(Self.modelRepo)): \(excerpt(stderr))")
        }
        cache.recordLoadFailure()
        return .notAvailable(
            reason: "model load failure for \(Self.modelRepo) (cache marked suspect): \(excerpt(stderr))")
    }

    private func invalidateSentinel(_ environment: ResolvedEnvironment) {
        guard let requirementsData = try? Data(contentsOf: requirementsFile) else { return }
        let sentinel = VenvLayout.sentinelURL(
            venvDir: environment.venvDir, requirementsData: requirementsData)
        try? FileManager.default.removeItem(at: sentinel)
        logger.warning("spawn failure: invalidated venv sentinel (next prepare rebuilds)")
    }

    // MARK: - Provenance

    private func engineVersion(_ environment: ResolvedEnvironment) async -> String {
        if let cached = cachedEngineVersions[environment.venvDir.path] { return cached }
        guard
            let outcome = try? await SubprocessRunner.run(
                executable: environment.pythonBinary,
                arguments: ["-c", "import importlib.metadata as m; print(m.version('mlx-whisper'), end='')"],
                environment: minimalEnvironment(),
                timeout: 120
            ),
            outcome.exitStatus == 0,
            case let version = String(decoding: outcome.stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !version.isEmpty
        else { return "unknown" }
        cachedEngineVersions[environment.venvDir.path] = version
        return version
    }

    // MARK: - Process environment hygiene

    /// Explicit minimal environment — never the GUI login env. No ffmpeg
    /// needed (the driver decodes WAV itself).
    private nonisolated func minimalEnvironment() -> [String: String] {
        [
            "PATH": "/usr/bin:/bin",
            "HOME": NSHomeDirectory(),
        ]
    }

    private nonisolated func excerpt(_ stderr: String) -> String {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 600 ? "…" + trimmed.suffix(600) : trimmed
    }
}
