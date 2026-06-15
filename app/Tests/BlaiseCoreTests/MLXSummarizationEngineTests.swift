import Foundation
import Testing
@testable import BlaiseCore

// C6: MLX notes engine request/response contract + error mapping via the
// driver test seam (fake venv python under a temp dataRoot — the C3
// pattern).

/// A driver-shaped success document (what notes_driver.py emits).
let fakeNotesDriverJSON = """
    {"notes": \(sampleEngineResponseJSON),
     "usage": {"input_tokens": 1234, "output_tokens": 256},
     "stats": {"prompt_tps": 100.0, "generation_tps": 40.0, "peak_memory_gb": 17.2}}
    """

struct NotesHarness {
    let dataRoot: URL
    let database: BlaiseDatabase
    let settings: SettingsStore
    let engine: MLXSummarizationEngine
    let requirementsData: Data

    var venvDir: URL { dataRoot.appendingPathComponent("python/venv", isDirectory: true) }
    var hfHome: URL { dataRoot.appendingPathComponent("models/hf", isDirectory: true) }
    var stdinCaptureURL: URL { dataRoot.appendingPathComponent("stdin-capture.json") }
    var sentinelURL: URL {
        VenvLayout.sentinelURL(venvDir: venvDir, requirementsData: requirementsData)
    }
    var cache: WhisperModelCache {
        WhisperModelCache(
            hfHome: hfHome, repo: MLXSummarizationEngine.modelRepo,
            markerName: MLXSummarizationEngine.suspectMarkerName)
    }

    func installPython(_ script: String) throws {
        let bin = venvDir.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let python = bin.appendingPathComponent("python")
        try Data(script.utf8).write(to: python)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
    }

    func writeSentinel() throws {
        try FileManager.default.createDirectory(at: venvDir, withIntermediateDirectories: true)
        try Data().write(to: sentinelURL)
    }

    func plantCompleteCache() throws {
        let snapshot = cache.repoCacheDir.appendingPathComponent("snapshots/main", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: snapshot.appendingPathComponent("weights.safetensors"))
    }
}

/// Fake driver script: captures stdin to a file, then behaves per `body`.
private func notesScript(captureTo url: URL, body: String) -> String {
    "#!/bin/sh\n" + FakePython.versionProbe + "\ncat > '\(url.path)'\n" + body + "\n"
}

func makeNotesHarness(
    body: String? = "cat <<'JSON'\n\(fakeNotesDriverJSON)\nJSON\nexit 0",
    completeCache: Bool = true,
    driverTimeout: TimeInterval = 20,
    // Generous default: the fake driver needs no memory, and the gate must
    // not flake these contract tests on a loaded build machine. The gate
    // test injects a small value explicitly.
    availableMemory: Int64 = 64 * 1_073_741_824
) async throws -> NotesHarness {
    let dataRoot = try makeTempRoot()
    precondition(
        dataRoot.path.hasPrefix(FileManager.default.temporaryDirectory.path),
        "C6 tests must use temp dataRoots")
    let database = try BlaiseDatabase(rootURL: dataRoot)
    let settings = SettingsStore(database: database)
    let configuration = EngineConfiguration(
        engineID: MLXSummarizationEngine.engineID,
        descriptors: MLXSummarizationEngine.descriptors,
        settings: settings,
        secrets: InMemorySecretStore()
    )
    let driver = try #require(MLXSummarizationEngine.bundledDriverScript())
    let requirements = try #require(MLXWhisperEngine.bundledRequirementsFile())
    let engine = MLXSummarizationEngine(
        configuration: configuration,
        dataRoot: dataRoot,
        uvBinary: dataRoot.appendingPathComponent("uv-not-present"),
        driverScript: driver,
        requirementsFile: requirements,
        sweepOrphansOnInit: false,
        modelFetchOverride: nil,
        driverTimeoutOverride: driverTimeout,
        availableMemoryProbe: { availableMemory }
    )
    let harness = NotesHarness(
        dataRoot: dataRoot,
        database: database,
        settings: settings,
        engine: engine,
        requirementsData: try Data(contentsOf: requirements)
    )
    if let body {
        try harness.installPython(
            notesScript(captureTo: harness.stdinCaptureURL, body: body))
        try harness.writeSentinel()
    }
    if completeCache {
        try harness.plantCompleteCache()
    }
    return harness
}

@Suite(.serialized) struct MLXSummarizationEngineTests {
    @Test func successMapsDriverOutputIntoNotesResult() async throws {
        let harness = try await makeNotesHarness()
        let result = try await harness.engine.generateNotes(makeNotesRequest())

        #expect(result.structured.summary == "Resumo da reunião.")
        #expect(result.structured.decisions == ["Aprovar orçamento"])
        // Post-parse normalization ran (user item unioned into actionItems).
        #expect(result.structured.actionItems.count == 2)
        #expect(result.speakerNameMapping.count == 2)
        #expect(result.speakerNameMapping[0].name == "Sam")
        #expect(result.usage == EngineUsage(inputUnits: 1234, outputUnits: 256, estimatedCostUSD: nil))
        #expect(result.provenance.engine == "mlx-gemma4-26b")
        #expect(result.provenance.model == "mlx-community/gemma-4-26b-a4b-it-4bit")
        #expect(result.provenance.runtime == "mlx-lm+outlines/subprocess")
        #expect(result.provenance.promptVersion == NotesPromptBuilder.promptVersion)
        #expect(result.provenance.pipelineVersion == "")
    }

    // MARK: - D17: load profile + memory gate

    @Test func loadProfilesAreDeclaredPerD17() async throws {
        // The pipeline's lightweight-only auto-fallback keys on these.
        let harness = try await makeNotesHarness()
        #expect(
            harness.engine.loadProfile
                == .heavyweight(estimatedPeakBytes: MLXSummarizationEngine.estimatedPeakBytes))
        #expect(MLXSummarizationEngine.estimatedPeakBytes == 18 * 1_073_741_824)
        let claude = ClaudeSummarizationEngine(
            configuration: EngineConfiguration(
                engineID: ClaudeSummarizationEngine.engineID,
                descriptors: ClaudeSummarizationEngine.descriptors,
                settings: harness.settings,
                secrets: InMemorySecretStore()),
            ledger: CloudSpendLedger(database: harness.database))
        #expect(claude.loadProfile == .lightweight)
    }

    @Test func memoryGateRefusesBeforeAnyLoadWhenHeadroomIsInsufficient() async throws {
        // 16 GB available < 18 GB peak + 2 GB margin → pinned reason, and
        // the driver is NEVER spawned (no stdin capture file).
        let harness = try await makeNotesHarness(availableMemory: 16 * 1_073_741_824)
        let error = await engineError { try await harness.engine.generateNotes(makeNotesRequest()) }
        #expect(error == .notAvailable(reason: EngineFallbackReason.insufficientMemory))
        #expect(EngineFallbackReason.isFallbackTrigger(try #require(error)))
        #expect(
            !FileManager.default.fileExists(atPath: harness.stdinCaptureURL.path),
            "the memory gate must refuse BEFORE the weight-loading subprocess spawns")
        // prepare() is deliberately NOT gated (venv + disk fetch only).
        try await harness.engine.prepare()
    }

    @Test func memoryGateAdmitsWithHeadroom() async throws {
        // Exactly at the boundary: peak + margin available → runs.
        let harness = try await makeNotesHarness(availableMemory: 20 * 1_073_741_824)
        let result = try await harness.engine.generateNotes(makeNotesRequest())
        #expect(!result.structured.summary.isEmpty)
    }

    @Test func memoryProbeFormulaIsConservativeAndExcludesPurgeable() {
        // The probe sums free + inactive ONLY: purgeable-volatile pages sit
        // on the regular paging queues, so counting `purgeable_count` would
        // double-count inactive pages — over-counting in the unsafe
        // direction (the gate would admit a load the machine cannot take).
        var stats = vm_statistics64()
        stats.free_count = 100
        stats.inactive_count = 50
        stats.purgeable_count = 1_000_000
        let pageSize: vm_size_t = 16_384
        #expect(
            SystemMemory.reclaimableBytes(stats: stats, pageSize: pageSize)
                == Int64(150) * Int64(pageSize))
    }

    @Test func driverReceivesTheAssembledRequestOnStdin() async throws {
        let harness = try await makeNotesHarness()
        _ = try await harness.engine.generateNotes(makeNotesRequest())

        let captured = try Data(contentsOf: harness.stdinCaptureURL)
        let object = try #require(try JSONSerialization.jsonObject(with: captured) as? [String: Any])
        #expect(object["system"] as? String == NotesPromptBuilder.systemPrompt)
        let user = try #require(object["user"] as? String)
        #expect(user.contains("[S0] Bom dia, vamos começar."))
        #expect(object["max_input_tokens"] as? Int == MLXSummarizationEngine.maxInputTokens)
    }

    // MARK: - G14 digest mode

    /// The digest driver request is FREE-TEXT: it carries the md-v1 system
    /// prompt and the budgets, but NO `schema` field (unconstrained generation).
    @Test func digestDriverRequestPayloadHasNoSchema() async throws {
        let harness = try await makeNotesHarness()
        let request = DigestRequest(
            meeting: Meeting(
                id: "01DIGESTMLX0000000000000000", title: "Vexatron Labs sync",
                startedAt: msDate(), source: .meet, status: .processing, attendees: [],
                createdAt: msDate(), updatedAt: msDate()),
            transcript: [TranscriptSegment(
                meetingID: "01DIGESTMLX0000000000000000", ord: 0, startSeconds: 0, endSeconds: 5,
                speakerLabel: "S0", text: "Vexatron Labs vai enviar o cronograma.")],
            notes: NotesStructured(
                title: "X", summary: "Resumo.", detailedNotes: "D.", decisions: [],
                actionItems: [], userActionItems: []),
            dominantLanguage: "pt", vocabulary: ["Vexatron Labs"],
            user: UserIdentity(name: "Dana Marsh", aliases: [], email: "dana@vexatronlabs.example"))
        let data = try harness.engine.digestDriverRequestPayload(request)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["schema"] == nil, "the digest call is free-text — no schema")
        #expect(object["system"] as? String == DigestPromptBuilder.systemPrompt)
        #expect((object["user"] as? String)?.contains("Vexatron Labs") == true)
        #expect(object["max_input_tokens"] as? Int == MLXSummarizationEngine.maxInputTokens)
    }

    /// The digest driver's stdout {digest, usage, stats} parses into a
    /// DigestResult (the local path spends nothing — no cost).
    @Test func digestDriverSuccessParses() async throws {
        let driverJSON = "{\"digest\": \"## HEADER\\nmeeting: Vexatron Labs sync\\n\", \"usage\": {\"input_tokens\": 600, \"output_tokens\": 90}, \"stats\": {\"prompt_tps\": 100.0, \"generation_tps\": 40.0, \"peak_memory_gb\": 17.0}}"
        let harness = try await makeNotesHarness(body: "cat <<'EOF'\n\(driverJSON)\nEOF")
        let request = DigestRequest(
            meeting: Meeting(
                id: "01DIGESTMLX0000000000000001", title: "Vexatron Labs sync",
                startedAt: msDate(), source: .meet, status: .processing, attendees: [],
                createdAt: msDate(), updatedAt: msDate()),
            transcript: [TranscriptSegment(
                meetingID: "01DIGESTMLX0000000000000001", ord: 0, startSeconds: 0, endSeconds: 5,
                speakerLabel: "S0", text: "ok")],
            notes: NotesStructured(
                title: "X", summary: "S.", detailedNotes: "D.", decisions: [],
                actionItems: [], userActionItems: []),
            dominantLanguage: "en", vocabulary: [],
            user: UserIdentity(name: "Dana Marsh", aliases: [], email: "dana@vexatronlabs.example"))
        let result = try await harness.engine.generateDigest(request)
        #expect(result.digest == "## HEADER\nmeeting: Vexatron Labs sync\n")
        #expect(result.promptVersion == "md-v1")
        #expect(result.usage?.estimatedCostUSD == nil, "the local path spends nothing")
    }

    @Test func inputTooLongSentinelMapsToFallbackReason() async throws {
        let harness = try await makeNotesHarness(
            body: "echo 'BLAISE_INPUT_TOO_LONG: 30000 tokens > 24000 budget' >&2; exit 2")
        let error = await engineError { try await harness.engine.generateNotes(makeNotesRequest()) }
        #expect(error == .permanent(EngineFallbackReason.inputTooLong))
        #expect(EngineFallbackReason.isFallbackTrigger(try #require(error)))
    }

    @Test func plainExit2MapsToPermanentBadInput() async throws {
        let harness = try await makeNotesHarness(body: "echo 'malformed stdin request' >&2; exit 2")
        let error = await engineError { try await harness.engine.generateNotes(makeNotesRequest()) }
        guard case .permanent(let reason) = error else {
            Issue.record("expected .permanent, got \(String(describing: error))")
            return
        }
        #expect(reason.contains("bad input"))
        #expect(!EngineFallbackReason.isFallbackTrigger(try #require(error)))
    }

    @Test func exit3MarksNotesCacheSuspectWithoutTouchingWhispersMarker() async throws {
        let harness = try await makeNotesHarness(body: "echo 'weights corrupted' >&2; exit 3")
        let error = await engineError { try await harness.engine.generateNotes(makeNotesRequest()) }
        guard case .notAvailable(let reason) = error else {
            Issue.record("expected .notAvailable, got \(String(describing: error))")
            return
        }
        #expect(reason.contains(MLXSummarizationEngine.modelRepo))
        let state = try #require(harness.cache.suspectState())
        #expect(state.attempts == 1)
        // Per-engine suspect isolation: whisper's marker must not exist.
        #expect(WhisperModelCache(hfHome: harness.hfHome).suspectState() == nil)
    }

    @Test func exit4WithOOMSignatureMapsToOutOfMemoryFallback() async throws {
        let harness = try await makeNotesHarness(
            body: "echo '[metal::malloc] Attempting to allocate 32000000000 bytes which exceeds the memory limit' >&2; exit 4")
        let error = await engineError { try await harness.engine.generateNotes(makeNotesRequest()) }
        #expect(error == .permanent(EngineFallbackReason.outOfMemory))
        #expect(EngineFallbackReason.isFallbackTrigger(try #require(error)))
    }

    @Test func plainExit4MapsToTransient() async throws {
        let harness = try await makeNotesHarness(body: "echo 'mlx assertion' >&2; exit 4")
        let error = await engineError { try await harness.engine.generateNotes(makeNotesRequest()) }
        guard case .transient(let reason) = error else {
            Issue.record("expected .transient, got \(String(describing: error))")
            return
        }
        #expect(reason.contains("mlx assertion"))
    }

    @Test func garbageStdoutMapsToTransient() async throws {
        let harness = try await makeNotesHarness(body: "echo 'this is not json'; exit 0")
        let error = await engineError { try await harness.engine.generateNotes(makeNotesRequest()) }
        guard case .transient(let reason) = error else {
            Issue.record("expected .transient, got \(String(describing: error))")
            return
        }
        #expect(reason.contains("expected JSON"))
    }

    @Test func availabilityBeforeProvisioningReportsNotProvisioned() async throws {
        let harness = try await makeNotesHarness(body: nil, completeCache: false)
        let availability = await harness.engine.availability()
        #expect(availability == .unavailable(reason: "not yet provisioned"))
    }

    @Test func availabilityWithVenvButNoCacheMentionsPrepare() async throws {
        let harness = try await makeNotesHarness(completeCache: false)
        let availability = await harness.engine.availability()
        #expect(availability == .unavailable(reason: "model cache missing or incomplete (prepare will fetch)"))
    }

    @Test func wipeRepairRunsAndSuccessClearsSuspect() async throws {
        let harness = try await makeNotesHarness()
        // The repair path's production guard requires ≥ 20 GB free on the cache
        // volume before it will wipe + re-fetch; below that floor generateNotes
        // returns .transient("insufficient disk space") and this success path
        // cannot be exercised. Treat low disk as a resource gate — like the
        // engine's other availability preconditions — and skip cleanly rather
        // than fail, so machines/CI runners under 20 GB free don't flake.
        let freeForImportantUsage = (try? harness.cache.repoCacheDir.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? .max
        let twentyGiB: Int64 = 20 * 1024 * 1024 * 1024
        guard freeForImportantUsage >= twentyGiB else {
            recordTestSkip(
                "wipeRepairRunsAndSuccessClearsSuspect",
                reason: "model-cache repair needs ≥ 20 GB free on the cache volume; this machine has less")
            return
        }
        harness.cache.recordLoadFailure()
        #expect(harness.cache.suspectState() != nil)
        // Suspect + intact integrity → prepare wipes the repo cache dir and
        // re-fetches (the fake python's `-c` branch plays the fetch), then a
        // successful generation clears suspicion entirely.
        _ = try await harness.engine.generateNotes(makeNotesRequest())
        #expect(harness.cache.suspectState() == nil)
        #expect(!FileManager.default.fileExists(
            atPath: harness.cache.repoCacheDir.appendingPathComponent("snapshots/main/weights.safetensors").path))
    }
}

// MARK: - Python environment lock (C6 scheme)

@Suite struct PythonEnvironmentLockTests {
    @Test func exclusiveAcquisitionTimesOutAgainstHeldSharedLock() async throws {
        let dataRoot = try makeTempRoot()
        let lockURL = VenvLayout(dataRoot: dataRoot).lockFileURL
        let holder = try PythonEnvironmentLock(url: lockURL)
        try await holder.acquireShared()
        defer { holder.unlock() }

        let contender = try PythonEnvironmentLock(url: lockURL)
        do {
            try await contender.acquireExclusive(timeout: 0.6)
            Issue.record("exclusive acquisition should have timed out")
        } catch let error as EngineError {
            #expect(error == .transient("python environment busy"))
        }
    }

    @Test func sharedAcquisitionWaitsForExclusiveRelease() async throws {
        let dataRoot = try makeTempRoot()
        let lockURL = VenvLayout(dataRoot: dataRoot).lockFileURL
        let holder = try PythonEnvironmentLock(url: lockURL)
        try await holder.acquireExclusive(timeout: 1)

        let acquired = Recorder<Date>()
        let waiter = Task {
            let lock = try PythonEnvironmentLock(url: lockURL)
            try await lock.acquireShared()
            acquired.append(Date())
            lock.unlock()
        }
        try await Task.sleep(for: .milliseconds(500))
        #expect(acquired.values.isEmpty, "shared lock must wait behind exclusive")
        let released = Date()
        holder.unlock()
        try await waiter.value
        #expect(acquired.values.count == 1)
        #expect(try #require(acquired.values.first) >= released)
    }

    @Test func twoSharedLocksCoexist() async throws {
        let dataRoot = try makeTempRoot()
        let lockURL = VenvLayout(dataRoot: dataRoot).lockFileURL
        let first = try PythonEnvironmentLock(url: lockURL)
        try await first.acquireShared()
        defer { first.unlock() }
        let second = try PythonEnvironmentLock(url: lockURL)
        // Must acquire immediately (no exclusive holder).
        try await second.acquireShared()
        second.unlock()
    }
}
