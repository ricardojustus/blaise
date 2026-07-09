import Foundation
import os

/// C6 engine 1: Gemma 4 26B-A4B-it, 4-bit MLX, via a Python helper
/// (`notes_driver.py`) in the SAME venv infrastructure as C3's whisper
/// engine (shared `python_requirements.txt`, shared sentinel, shared lock
/// scheme). Structured output is enforced by Outlines constrained decoding
/// inside the helper.
///
/// Serialization: public `prepare()`/`generateNotes()` are FIFO chain links
/// (`EngineTaskChain`); bodies are un-chained and `generateNotesBody()`
/// calls `prepareBody()` DIRECTLY (the C3-normative pattern — two
/// concurrent 15.6 GB loads on a 32 GB machine is the failure the chain
/// prevents).
public actor MLXSummarizationEngine: SummarizationEngine {
    public static let engineID = "mlx-gemma4-26b"
    public static let modelRepo = "mlx-community/gemma-4-26b-a4b-it-4bit"
    public static let venvPathKey = "venvPath"
    public static let hfHomePathKey = "hfHomePath"
    /// KV-probe-calibrated input budget (C6 smoke gate):
    /// 24k-token prefill + 100 generated peaked 17.85 GB on the 32 GB
    /// machine (probe 2026-06-10, prompt_tps 454) — 24_000 holds with
    /// headroom, no halving needed. The helper's exact tokenizer count is
    /// the refusal authority; there is deliberately NO Swift-side pre-screen
    /// (every cheap heuristic under-counts PT, the unsafe direction).
    public static let maxInputTokens = 24_000
    public static let maxOutputTokens = 8_192
    /// Fixed driver timeout (same as C3's floor; generation length does not
    /// scale with audio duration here).
    static let driverTimeout: TimeInterval = 900
    /// Disk precheck for the 15.6 GB model fetch.
    static let requiredFetchBytes: Int64 = 20 * 1_073_741_824
    /// Per-engine suspect marker (shares `hfHome` with whisper's cache).
    static let suspectMarkerName = ".blaise-suspect-notes"
    /// Declared peak for the D17 weight class: the C6 KV probe
    /// (2026-06-10) measured a 17.85 GB peak for a
    /// 24k-token prefill + 100 generated tokens on the 32 GB machine —
    /// declared as 18 GB.
    public static let estimatedPeakBytes: Int64 = 18 * 1_073_741_824
    /// Safety margin the memory gate requires ON TOP of the declared peak.
    static let memoryGateMargin: Int64 = 2 * 1_073_741_824

    public nonisolated let id: String = MLXSummarizationEngine.engineID
    public nonisolated let displayName = "Gemma 4 26B (MLX, local)"
    public nonisolated let kind: EngineKind = .local
    /// Heavyweight (D17): never auto-loaded by the runtime fallback; even a
    /// deliberate run is refused by the memory gate without real headroom.
    public nonisolated let loadProfile: EngineLoadProfile =
        .heavyweight(estimatedPeakBytes: MLXSummarizationEngine.estimatedPeakBytes)
    public nonisolated let costDescriptor: EngineCostDescriptor? = nil
    public static let descriptors: [EngineConfigDescriptor] = [
        EngineConfigDescriptor(
            key: MLXSummarizationEngine.venvPathKey, label: "Python venv path", kind: .path,
            required: false),
        EngineConfigDescriptor(
            key: MLXSummarizationEngine.hfHomePathKey, label: "Model cache (HF_HOME) path",
            kind: .path, required: false),
    ]
    public nonisolated let configDescriptors: [EngineConfigDescriptor] =
        MLXSummarizationEngine.descriptors

    private let configuration: EngineConfiguration
    private let dataRoot: URL
    private let uvBinary: URL
    private let driverScript: URL
    private let requirementsFile: URL
    private let chain = EngineTaskChain()
    private let logger = Logger(subsystem: BlaiseBundle.identifier, category: "notes.mlx")

    // Test seams (internal): replace the network model fetch; shrink
    // timeouts; replace the memory probe (the gate must be unit-testable
    // without depending on the build machine's live memory pressure).
    let modelFetchOverride: (@Sendable (_ hfHome: URL) async throws -> Void)?
    let driverTimeoutOverride: TimeInterval?
    let availableMemoryProbe: @Sendable () -> Int64

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
        driverTimeoutOverride: TimeInterval? = nil,
        availableMemoryProbe: @escaping @Sendable () -> Int64 = SystemMemory.availableBytes
    ) {
        self.configuration = configuration
        self.dataRoot = dataRoot
        self.uvBinary = uvBinary
        self.driverScript = driverScript
        self.requirementsFile = requirementsFile
        self.modelFetchOverride = modelFetchOverride
        self.driverTimeoutOverride = driverTimeoutOverride
        self.availableMemoryProbe = availableMemoryProbe
        if sweepOrphansOnInit {
            let path = driverScript.path
            let log = logger
            Task.detached { await OrphanSweeper.sweep(driverPath: path, logger: log) }
        }
    }

    public static func bundledDriverScript() -> URL? {
        BlaiseResources.bundle.url(forResource: "notes_driver", withExtension: "py")
    }

    // MARK: - Resolved environment (live read-through, per call)

    struct ResolvedEnvironment: Sendable {
        var venvDir: URL
        var venvIsExternallyManaged: Bool
        var hfHome: URL

        var pythonBinary: URL { venvDir.appendingPathComponent("bin/python") }
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

    private func modelCache(_ environment: ResolvedEnvironment) -> WhisperModelCache {
        WhisperModelCache(
            hfHome: environment.hfHome, repo: Self.modelRepo, markerName: Self.suspectMarkerName)
    }

    // MARK: - Availability (mirrors C3 semantics)

    public func availability() async -> EngineAvailability {
        let environment: ResolvedEnvironment
        do {
            environment = try await resolveEnvironment()
        } catch {
            return .unavailable(reason: "configuration unreadable: \(error)")
        }
        if environment.venvIsExternallyManaged {
            if let failure = await pythonImportCheckFailure(
                python: environment.pythonBinary, modules: ["mlx_lm", "outlines"])
            {
                return .unavailable(reason: "external venv import check failed: \(failure)")
            }
        } else {
            guard let requirementsData = try? Data(contentsOf: requirementsFile) else {
                return .unavailable(reason: "bundled python_requirements.txt missing")
            }
            guard
                VenvLayout.isProvisioned(
                    venvDir: environment.venvDir, requirementsData: requirementsData)
            else {
                return .unavailable(reason: "not yet provisioned")
            }
        }
        guard modelCache(environment).integrity() else {
            return .unavailable(reason: "model cache missing or incomplete (prepare will fetch)")
        }
        return .available
    }

    // MARK: - Chained entry points

    public func prepare() async throws {
        try await chain.run { try await self.prepareBody() }
    }

    public func generateNotes(_ request: NotesRequest, purpose: CloudSpendPurpose) async throws -> NotesResult {
        // Local engine — no cloud spend, so `purpose` is irrelevant here.
        try await chain.run { try await self.generateNotesBody(request) }
    }

    public func generateDigest(_ request: DigestRequest, purpose: CloudSpendPurpose) async throws -> DigestResult {
        // Local engine — no cloud spend, so `purpose` is irrelevant here.
        try await chain.run { try await self.generateDigestBody(request) }
    }

    // MARK: - Bodies (un-chained)

    private func prepareBody() async throws {
        let environment = try await resolveEnvironment()
        if !environment.venvIsExternallyManaged {
            let provisioner = PythonVenvProvisioner(
                dataRoot: dataRoot,
                uvBinary: uvBinary,
                requirementsFile: requirementsFile,
                importCheckModules: ["mlx_lm", "outlines"],
                logger: logger
            )
            try await provisioner.provisionIfNeeded(venvDir: environment.venvDir)
        }
        try await ensureModelCache(environment)
    }

    private func generateNotesBody(_ request: NotesRequest) async throws -> NotesResult {
        if Task.isCancelled { throw EngineError.cancelled }
        // Memory gate (D17): refuse BEFORE any weight load when actual
        // reclaimable headroom cannot cover the declared peak + margin.
        // Protects even deliberate user-selected runs (the 2026-06-10
        // lockups were ~18 GB peaks on a machine without 16 GB free).
        // prepare() is deliberately NOT gated: it provisions the venv and
        // fetches the model to DISK — no weights are loaded there, and the
        // launch-time eager prepare must keep working on a busy machine.
        let available = availableMemoryProbe()
        let required = Self.estimatedPeakBytes + Self.memoryGateMargin
        guard available >= required else {
            logger.warning(
                "memory gate refused weight load: \(available / 1_048_576) MB available < \(required / 1_048_576) MB required (peak + margin)"
            )
            throw EngineError.notAvailable(reason: EngineFallbackReason.insufficientMemory)
        }
        try await prepareBody()

        let environment = try await resolveEnvironment()
        let cache = modelCache(environment)

        var processEnvironment = minimalPythonProcessEnvironment()
        processEnvironment["HF_HOME"] = environment.hfHome.path
        processEnvironment["HF_HUB_DISABLE_TELEMETRY"] = "1"
        if cache.integrity(), cache.suspectState() == nil {
            processEnvironment["HF_HUB_OFFLINE"] = "1"
        }

        // Prompt version: live read-through of the global setting
        // (`notes.promptVersion`); unset/invalid → the shipped default.
        let promptVersion = NotesPromptBuilder.resolve(
            try? await configuration.globalValue(key: NotesPromptBuilder.versionSettingsKey))
        let stdinPayload = try driverRequestPayload(request, promptVersion: promptVersion)
        let timeout = driverTimeoutOverride ?? Self.driverTimeout
        let outcome: SubprocessRunner.Outcome
        do {
            // Driver runs against the app-managed venv hold the SHARED
            // environment lock for the subprocess lifetime (C6 lock scheme).
            outcome = try await withSharedPythonLock(
                dataRoot: dataRoot, bypass: environment.venvIsExternallyManaged
            ) {
                try await SubprocessRunner.run(
                    executable: environment.pythonBinary,
                    arguments: [driverScript.path, "--blaise-engine"],
                    environment: processEnvironment,
                    stdin: stdinPayload,
                    timeout: timeout
                )
            }
        } catch let error as EngineError {
            throw error
        } catch {
            // Spawn failure: broken interpreter → sentinel invalidation
            // (self-heal), default venv only.
            if !environment.venvIsExternallyManaged {
                invalidateSentinel(environment)
            }
            throw EngineError.notAvailable(reason: "python interpreter failed to launch: \(error)")
        }

        if outcome.cancelled { throw EngineError.cancelled }
        if outcome.timedOut { throw EngineError.transient("timeout") }
        guard let status = outcome.exitStatus else {
            throw EngineError.transient("driver terminated without status: \(stderrExcerpt(outcome.stderrTail))")
        }
        if outcome.terminationReason == .uncaughtSignal {
            throw EngineError.transient("driver killed by signal: \(stderrExcerpt(outcome.stderrTail))")
        }
        switch status {
        case 0:
            break
        case 2 where outcome.stderrTail.contains("BLAISE_INPUT_TOO_LONG"):
            // Exact-tokenizer refusal → the one-hop runtime fallback.
            throw EngineError.permanent(EngineFallbackReason.inputTooLong)
        case 2:
            throw EngineError.permanent("bad input: \(stderrExcerpt(outcome.stderrTail))")
        case 3:
            throw mapModelLoadFailure(cache: cache, stderr: outcome.stderrTail)
        case 4 where Self.stderrSignalsOOM(outcome.stderrTail):
            // OOM is a fallback trigger, NOT `.transient` (retrying the
            // same oversized generation cannot help).
            throw EngineError.permanent(EngineFallbackReason.outOfMemory)
        case 4:
            throw EngineError.transient("generation failure: \(stderrExcerpt(outcome.stderrTail))")
        default:
            throw EngineError.transient("driver exit \(status): \(stderrExcerpt(outcome.stderrTail))")
        }

        let parsed: NotesDriverOutput
        do {
            parsed = try JSONDecoder().decode(NotesDriverOutput.self, from: outcome.stdout)
        } catch {
            throw EngineError.transient("driver stdout was not the expected JSON: \(error)")
        }

        cache.clearSuspect()

        let (structured, mapping) = parsed.notes.toNotes()
        logger.info(
            "notes generated: \(parsed.usage.inputTokens) in / \(parsed.usage.outputTokens) out tokens, peak \(String(format: "%.1f", parsed.stats?.peakMemoryGB ?? 0)) GB"
        )
        return NotesResult(
            structured: structured,
            usage: EngineUsage(
                inputUnits: parsed.usage.inputTokens,
                outputUnits: parsed.usage.outputTokens,
                estimatedCostUSD: nil
            ),
            provenance: NotesProvenance(
                engine: id,
                model: Self.modelRepo,
                pipelineVersion: "",
                runtime: "mlx-lm+outlines/subprocess",
                promptVersion: promptVersion.rawValue
            ),
            speakerNameMapping: mapping
        )
    }

    /// Backoff before the ONE bounded transient re-issue of the digest
    /// generation (H1) — parallels the Claude engine's bounded re-issue. A hard
    /// failure (OOM, bad input, model-load) is NOT retried and falls through to
    /// the digest-pending path identically.
    static let digestRetryBackoff: Duration = .milliseconds(750)

    private func generateDigestBody(_ request: DigestRequest) async throws -> DigestResult {
        do {
            return try await runDigestDriver(request)
        } catch let error as EngineError where MLXSummarizationEngine.isDigestRetryable(error) {
            if Task.isCancelled { throw EngineError.cancelled }
            try? await Task.sleep(for: Self.digestRetryBackoff)
            if Task.isCancelled { throw EngineError.cancelled }
            return try await runDigestDriver(request)
        }
    }

    /// True for the MLX digest errors the one-shot bounded retry re-issues: a
    /// `.transient` generation/driver blip. A `.permanent`/`.notAvailable`
    /// (OOM, bad input, model-load) is NOT retried — re-running cannot help.
    static func isDigestRetryable(_ error: EngineError) -> Bool {
        if case .transient = error { return true }
        return false
    }

    private func runDigestDriver(_ request: DigestRequest) async throws -> DigestResult {
        if Task.isCancelled { throw EngineError.cancelled }
        let available = availableMemoryProbe()
        let required = Self.estimatedPeakBytes + Self.memoryGateMargin
        guard available >= required else {
            logger.warning(
                "memory gate refused digest weight load: \(available / 1_048_576) MB available < \(required / 1_048_576) MB required (peak + margin)"
            )
            throw EngineError.notAvailable(reason: EngineFallbackReason.insufficientMemory)
        }
        try await prepareBody()

        let environment = try await resolveEnvironment()
        let cache = modelCache(environment)
        var processEnvironment = minimalPythonProcessEnvironment()
        processEnvironment["HF_HOME"] = environment.hfHome.path
        processEnvironment["HF_HUB_DISABLE_TELEMETRY"] = "1"
        if cache.integrity(), cache.suspectState() == nil {
            processEnvironment["HF_HUB_OFFLINE"] = "1"
        }

        let version = DigestPromptBuilder.shippedVersion
        let stdinPayload = try digestDriverRequestPayload(request, promptVersion: version)
        let timeout = driverTimeoutOverride ?? Self.driverTimeout
        let outcome: SubprocessRunner.Outcome
        do {
            outcome = try await withSharedPythonLock(
                dataRoot: dataRoot, bypass: environment.venvIsExternallyManaged
            ) {
                try await SubprocessRunner.run(
                    executable: environment.pythonBinary,
                    arguments: [driverScript.path, "--blaise-engine", "--digest"],
                    environment: processEnvironment,
                    stdin: stdinPayload,
                    timeout: timeout
                )
            }
        } catch let error as EngineError {
            throw error
        } catch {
            if !environment.venvIsExternallyManaged {
                invalidateSentinel(environment)
            }
            throw EngineError.notAvailable(reason: "python interpreter failed to launch: \(error)")
        }

        if outcome.cancelled { throw EngineError.cancelled }
        if outcome.timedOut { throw EngineError.transient("timeout") }
        guard let status = outcome.exitStatus else {
            throw EngineError.transient("driver terminated without status: \(stderrExcerpt(outcome.stderrTail))")
        }
        if outcome.terminationReason == .uncaughtSignal {
            throw EngineError.transient("driver killed by signal: \(stderrExcerpt(outcome.stderrTail))")
        }
        switch status {
        case 0:
            break
        case 2 where outcome.stderrTail.contains("BLAISE_INPUT_TOO_LONG"):
            throw EngineError.permanent(EngineFallbackReason.inputTooLong)
        case 2:
            throw EngineError.permanent("bad input: \(stderrExcerpt(outcome.stderrTail))")
        case 3:
            throw mapModelLoadFailure(cache: cache, stderr: outcome.stderrTail)
        case 4 where Self.stderrSignalsOOM(outcome.stderrTail):
            throw EngineError.permanent(EngineFallbackReason.outOfMemory)
        case 4:
            throw EngineError.transient("generation failure: \(stderrExcerpt(outcome.stderrTail))")
        default:
            throw EngineError.transient("driver exit \(status): \(stderrExcerpt(outcome.stderrTail))")
        }

        let parsed: DigestDriverOutput
        do {
            parsed = try JSONDecoder().decode(DigestDriverOutput.self, from: outcome.stdout)
        } catch {
            throw EngineError.transient("digest driver stdout was not the expected JSON: \(error)")
        }
        cache.clearSuspect()
        return DigestResult(
            digest: parsed.digest,
            usage: EngineUsage(
                inputUnits: parsed.usage.inputTokens,
                outputUnits: parsed.usage.outputTokens,
                estimatedCostUSD: nil),
            promptVersion: version.rawValue)
    }

    /// The stdin JSON request for the driver's `--digest` mode: free-text
    /// generation (NO `schema` field — the digest is Markdown, not a
    /// schema-shaped document). Same prompt authority (`DigestPromptBuilder`).
    nonisolated func digestDriverRequestPayload(
        _ request: DigestRequest,
        promptVersion: DigestPromptVersion = DigestPromptBuilder.shippedVersion
    ) throws -> Data {
        let payload: [String: Any] = [
            "system": DigestPromptBuilder.systemPrompt(for: promptVersion),
            "user": DigestPromptBuilder.userMessage(for: request),
            "max_input_tokens": Self.maxInputTokens,
            "max_output_tokens": Self.maxOutputTokens,
            "temperature": NotesDecodingParameters.temperature,
            "top_p": NotesDecodingParameters.mlxTopP,
        ]
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    /// The stdin JSON request for `notes_driver.py` (prompts assembled in
    /// Swift by the shared `NotesPromptBuilder` — one prompt authority for
    /// both engines).
    ///
    /// The schema is spliced in as its RAW authored JSON (same device as the
    /// Claude engine's request body): a `JSONSerialization` round-trip with
    /// `.sortedKeys` alphabetizes the schema properties, and Outlines'
    /// constrained decoding follows schema property order exactly like the
    /// cloud structured-output mechanism — authored order is what makes
    /// `meeting_type` generate BEFORE `detailed_notes` (classify-then-write)
    /// and the analysis fields before the item arrays. Python's `json.load`
    /// preserves the wire-byte key order into the driver's dict.
    nonisolated func driverRequestPayload(
        _ request: NotesRequest,
        promptVersion: NotesPromptVersion = NotesPromptBuilder.shippedVersion
    ) throws -> Data {
        let placeholder = "BLAISE-NOTES-SCHEMA-SPLICE-7F2A"
        let payload: [String: Any] = [
            "system": NotesPromptBuilder.systemPrompt(for: promptVersion),
            "user": NotesPromptBuilder.userMessage(for: request),
            "schema": placeholder,
            "max_input_tokens": Self.maxInputTokens,
            "max_output_tokens": Self.maxOutputTokens,
            "temperature": NotesDecodingParameters.temperature,
            "top_p": NotesDecodingParameters.mlxTopP,
        ]
        let serialized = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let template = String(data: serialized, encoding: .utf8),
            template.contains("\"\(placeholder)\"")
        else {
            throw EngineError.permanent("driver request serialization failed")
        }
        let spliced = template.replacingOccurrences(
            of: "\"\(placeholder)\"", with: NotesResponseSchema.json)
        return Data(spliced.utf8)
    }

    /// OOM signatures observed from mlx/Metal allocation failures.
    static func stderrSignalsOOM(_ stderr: String) -> Bool {
        let signatures = [
            "metal::malloc", "exceeds the memory limit", "Out of memory", "MemoryError",
            "kIOGPUCommandBufferCallbackErrorOutOfMemory",
        ]
        return signatures.contains { stderr.contains($0) }
    }

    // MARK: - Model cache step (same integrity/suspect/wipe-repair predicates as C3)

    private func ensureModelCache(_ environment: ResolvedEnvironment) async throws {
        let cache = modelCache(environment)
        let integrity = cache.integrity()
        let suspect = cache.suspectState()
        if integrity, suspect == nil { return }
        if let suspect, suspect.permanentFailure {
            throw EngineError.permanent(
                "model cache failed twice after wipe-repair; reset the cache to retry (delete \(cache.suspectMarkerURL.path))")
        }

        if let available = DiskSpace.availableBytes(at: environment.hfHome),
            available < Self.requiredFetchBytes
        {
            let gigabytes = Double(available) / 1_073_741_824
            throw EngineError.transient(
                "insufficient disk space: need ≥ 20 GB free for the model cache, have \(String(format: "%.1f", gigabytes)) GB")
        }

        if integrity, suspect != nil {
            logger.warning("model cache suspect with intact integrity — wiping \(cache.repoCacheDir.path)")
            try? FileManager.default.removeItem(at: cache.repoCacheDir)
            try await fetchModel(environment)
            cache.recordRepairCompleted()
        } else {
            try await fetchModel(environment)
        }
    }

    private func fetchModel(_ environment: ResolvedEnvironment) async throws {
        if let modelFetchOverride {
            try await modelFetchOverride(environment.hfHome)
            return
        }
        var processEnvironment = minimalPythonProcessEnvironment()
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
                timeout: 7200
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
            throw EngineError.transient("model download failed: \(stderrExcerpt(outcome.stderrTail))")
        }
    }

    // MARK: - Error-mapping helpers

    private func mapModelLoadFailure(cache: WhisperModelCache, stderr: String) -> EngineError {
        if let state = cache.suspectState(), state.repairedSinceLastFailure {
            cache.recordPermanentFailure()
            return .permanent(
                "model load failed again after cache wipe-repair (\(Self.modelRepo)): \(stderrExcerpt(stderr))")
        }
        cache.recordLoadFailure()
        return .notAvailable(
            reason: "model load failure for \(Self.modelRepo) (cache marked suspect): \(stderrExcerpt(stderr))")
    }

    private func invalidateSentinel(_ environment: ResolvedEnvironment) {
        guard let requirementsData = try? Data(contentsOf: requirementsFile) else { return }
        let sentinel = VenvLayout.sentinelURL(
            venvDir: environment.venvDir, requirementsData: requirementsData)
        try? FileManager.default.removeItem(at: sentinel)
        logger.warning("spawn failure: invalidated venv sentinel (next prepare rebuilds)")
    }
}

// MARK: - System memory probe (D17 memory gate)

/// Actual reclaimable memory headroom: free + inactive pages via
/// `host_statistics64(HOST_VM_INFO64)` (Mach; verified by compile-probe
/// against the macOS SDK 2026-06-10 — on this 32 GB machine the original
/// free+inactive+purgeable sum read 18.5 GB with Chrome running; the
/// conservative formula below reads lower). `os_proc_available_memory` was
/// rejected: it is jetsam-limit-scoped and returns 0 for ordinary Mac apps.
enum SystemMemory {
    /// Conservative formula: free + inactive ONLY. `purgeable_count` is
    /// deliberately excluded — in XNU, purgeable-volatile pages sit on the
    /// regular paging queues, so adding them double-counts pages already in
    /// `inactive_count` (and the gate must never over-count in the unsafe
    /// direction). Remaining KNOWN optimism: `inactive_count` includes dirty
    /// anonymous/file-backed pages whose reclamation goes through the
    /// compressor/swap/writeback — the very thrash the gate exists to
    /// prevent; the gate's 2 GiB margin is what absorbs that bias.
    static func reclaimableBytes(stats: vm_statistics64, pageSize: vm_size_t) -> Int64 {
        (Int64(stats.free_count) + Int64(stats.inactive_count)) * Int64(pageSize)
    }

    static let availableBytes: @Sendable () -> Int64 = {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }  // unreadable → refuse (conservative)
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return 0 }
        return reclaimableBytes(stats: stats, pageSize: pageSize)
    }
}

// MARK: - Driver output

/// The single JSON document `notes_driver.py` writes to stdout.
struct NotesDriverOutput: Decodable {
    struct Usage: Decodable {
        var inputTokens: Int
        var outputTokens: Int

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }

    struct Stats: Decodable {
        var promptTPS: Double?
        var generationTPS: Double?
        var peakMemoryGB: Double?

        enum CodingKeys: String, CodingKey {
            case promptTPS = "prompt_tps"
            case generationTPS = "generation_tps"
            case peakMemoryGB = "peak_memory_gb"
        }
    }

    var notes: NotesEngineResponse
    var usage: Usage
    var stats: Stats?
}

/// The single JSON document `notes_driver.py --digest` writes to stdout: a
/// free-text Markdown digest string + usage + stats (no `notes` object).
struct DigestDriverOutput: Decodable {
    struct Usage: Decodable {
        var inputTokens: Int
        var outputTokens: Int

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }

    struct Stats: Decodable {
        var promptTPS: Double?
        var generationTPS: Double?
        var peakMemoryGB: Double?

        enum CodingKeys: String, CodingKey {
            case promptTPS = "prompt_tps"
            case generationTPS = "generation_tps"
            case peakMemoryGB = "peak_memory_gb"
        }
    }

    var digest: String
    var usage: Usage
    var stats: Stats?
}
