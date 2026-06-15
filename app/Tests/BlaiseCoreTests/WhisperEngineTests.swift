import Foundation
import Testing
@testable import BlaiseCore

// MARK: - Driver JSON parsing

@Suite struct WhisperDriverParsingTests {
    @Test func parsesDriverShapedJSONWithWords() throws {
        // A driver run WITH word timestamps: each speech segment carries a
        // non-empty `words` array whose entries tile the segment text. Synthetic
        // (Vexatron Labs universe), English, three segments.
        let json = #"""
        {
          "text": " the quoll harbour survey is ready",
          "language": "en",
          "segments": [
            {
              "start": 0.0, "end": 0.66, "text": " the quoll",
              "no_speech_prob": 0.012, "avg_logprob": -0.21,
              "words": [
                {"word": " the", "start": 0.0, "end": 0.30},
                {"word": " quoll", "start": 0.30, "end": 0.66}
              ]
            },
            {
              "start": 0.66, "end": 1.50, "text": " harbour survey",
              "no_speech_prob": 0.008, "avg_logprob": -0.18,
              "words": [
                {"word": " harbour", "start": 0.66, "end": 1.10},
                {"word": " survey", "start": 1.10, "end": 1.50}
              ]
            },
            {
              "start": 1.50, "end": 2.20, "text": " is ready",
              "no_speech_prob": 0.005, "avg_logprob": -0.15,
              "words": [
                {"word": " is", "start": 1.50, "end": 1.80},
                {"word": " ready", "start": 1.80, "end": 2.20}
              ]
            }
          ]
        }
        """#
        let output = try JSONDecoder().decode(WhisperDriverOutput.self, from: Data(json.utf8))
        #expect(output.language == "en")
        #expect(output.segments.count == 3)
        let first = output.segments[0]
        #expect(first.start == 0.0)
        #expect(abs(try #require(first.end) - 0.66) < 1e-9)
        #expect(first.noSpeechProb != nil)
        #expect(first.avgLogprob != nil)
        let words = try #require(first.words)
        #expect(words.count == 2)
        #expect(words[0].word == " the")
        #expect(words[0].start == 0.0)
        #expect(abs(try #require(words[1].end) - 0.66) < 1e-9)

        let segments = output.asrSegments
        #expect(segments.count == 3)
        #expect(segments[0].words?.count == 2)
        #expect(segments[0].text == first.text)
        #expect(segments[2].words?.map(\.word) == [" is", " ready"])
    }

    @Test func parsesSegmentsWithoutWordsAsNil() throws {
        // A run WITHOUT word timestamps: the `words` key is absent on every
        // speech segment (decode-default nil), yet mlx-whisper still emits
        // EMPTY `words` arrays on the empty-text tail rows. The decode must
        // keep these two states distinct — key-absent → nil with real text,
        // key-present-but-empty → empty array with empty text. Synthetic:
        // 10 normal speech segments (no words key) + 3 empty tail rows.
        let speech = (0 ..< 10).map { i in
            let start = Double(i)
            return """
            {"start": \(start), "end": \(start + 0.8), "text": " segment \(i)", \
            "no_speech_prob": 0.01, "avg_logprob": -0.2}
            """
        }
        let emptyTail = (0 ..< 3).map { i in
            let start = 10.0 + Double(i) * 0.5
            return """
            {"start": \(start), "end": \(start + 0.1), "text": "", \
            "no_speech_prob": 0.97, "avg_logprob": -1.4, "words": []}
            """
        }
        let json = """
        {"text": " synthetic", "language": "en", "segments": [
        \((speech + emptyTail).joined(separator: ",\n"))
        ]}
        """
        let output = try JSONDecoder().decode(WhisperDriverOutput.self, from: Data(json.utf8))
        let keyAbsent = output.segments.filter { $0.words == nil }
        #expect(keyAbsent.count == 10)
        #expect(keyAbsent.allSatisfy { !$0.text.isEmpty })
        let keyPresent = output.segments.filter { $0.words != nil }
        #expect(keyPresent.count == 3)
        #expect(keyPresent.allSatisfy { $0.words!.isEmpty && $0.text.isEmpty })
    }

    @Test func rejectsNonJSONStdout() {
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(WhisperDriverOutput.self, from: Data("not json".utf8))
        }
    }
}

// MARK: - Driver language clamp (the REAL bundled driver script, pure logic
// only — system python3, no mlx/model: clamp_language and ALLOWED_LANGUAGES
// are stdlib-importable at module level)

@Suite struct WhisperDriverLanguageClampTests {
    /// Imports the bundled driver as a module and prints
    /// `clamp_language(<probs JSON>)`.
    private func clamp(probs: String) throws -> String {
        let driver = try #require(MLXWhisperEngine.bundledDriverScript())
        let script = """
            import importlib.util, json, sys
            spec = importlib.util.spec_from_file_location("whisper_driver", sys.argv[1])
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            print(mod.clamp_language(json.loads(sys.argv[2])))
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script, driver.path, probs]
        let stdout = Pipe()
        process.standardOutput = stdout
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func clampPicksPTWhenGlobalArgmaxIsOutOfScope() throws {
        // The field failure: Russian wins the unrestricted argmax; within
        // {pt, en} Portuguese wins.
        let choice = try clamp(probs: #"{"ru": 0.62, "it": 0.20, "pt": 0.11, "en": 0.07}"#)
        #expect(choice == "pt")
    }

    @Test func clampPicksENWhenENBeatsPTWithinScope() throws {
        let choice = try clamp(probs: #"{"it": 0.50, "en": 0.30, "pt": 0.20}"#)
        #expect(choice == "en")
    }

    @Test func allowedLanguagesAreExactlyPTAndEN() throws {
        let driver = try #require(MLXWhisperEngine.bundledDriverScript())
        let script = """
            import importlib.util, json, sys
            spec = importlib.util.spec_from_file_location("whisper_driver", sys.argv[1])
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            print(json.dumps(list(mod.ALLOWED_LANGUAGES)))
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script, driver.path]
        let stdout = Pipe()
        process.standardOutput = stdout
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(output == #"["pt", "en"]"#)
    }
}

// MARK: - Error mapping table

@Suite(.serialized) struct WhisperErrorMappingTests {
    @Test func exit2MapsToPermanentBadInput() async throws {
        let harness = try await makeWhisperHarness(python: FakePython.exit2)
        let wav = try harness.makeWAV()
        let error = await engineError {
            try await harness.engine.transcribe(ASRRequest(audioURL: wav))
        }
        guard case .permanent(let reason) = error else {
            Issue.record("expected .permanent, got \(String(describing: error))")
            return
        }
        #expect(reason.contains("bad input"))
        #expect(reason.contains("unreadable audio"))
    }

    @Test func exit3MapsToNotAvailableAndMarksCacheSuspect() async throws {
        let harness = try await makeWhisperHarness(python: FakePython.exit3)
        let wav = try harness.makeWAV()
        let error = await engineError {
            try await harness.engine.transcribe(ASRRequest(audioURL: wav))
        }
        guard case .notAvailable(let reason) = error else {
            Issue.record("expected .notAvailable, got \(String(describing: error))")
            return
        }
        #expect(reason.contains(MLXWhisperEngine.modelRepo))
        let state = try #require(harness.cache.suspectState())
        #expect(state.attempts == 1)
        #expect(!state.repairedSinceLastFailure)
    }

    @Test func secondExit3AfterCompletedWipeRepairMapsToPermanent() async throws {
        let fetchCalls = Recorder<URL>()
        let harness = try await makeWhisperHarness(
            python: FakePython.exit3,
            modelFetch: { hfHome in
                fetchCalls.append(hfHome)
                // Re-fetch recreates a structurally complete cache.
                try WhisperHarness.plantCompleteCache(hfHome: hfHome)
            })
        let wav = try harness.makeWAV()

        // First exit-3: suspect, .notAvailable.
        let first = await engineError {
            try await harness.engine.transcribe(ASRRequest(audioURL: wav))
        }
        guard case .notAvailable = first else {
            Issue.record("expected .notAvailable, got \(String(describing: first))")
            return
        }

        // Second call: prepare sees integrity TRUE + suspect → wipe-repair
        // (fetch override runs), then the driver fails with exit-3 again →
        // two consecutive with a completed repair between → .permanent.
        let second = await engineError {
            try await harness.engine.transcribe(ASRRequest(audioURL: wav))
        }
        guard case .permanent(let reason) = second else {
            Issue.record("expected .permanent, got \(String(describing: second))")
            return
        }
        #expect(reason.contains("after cache wipe-repair"))
        #expect(fetchCalls.values.count == 1)
        let state = try #require(harness.cache.suspectState())
        #expect(state.repairedSinceLastFailure)
    }

    @Test func exit4MapsToTransientWithStderrExcerpt() async throws {
        let harness = try await makeWhisperHarness(python: FakePython.exit4)
        let wav = try harness.makeWAV()
        let error = await engineError {
            try await harness.engine.transcribe(ASRRequest(audioURL: wav))
        }
        guard case .transient(let reason) = error else {
            Issue.record("expected .transient, got \(String(describing: error))")
            return
        }
        #expect(reason.contains("metal assertion"))
    }

    @Test func garbageStdoutMapsToTransient() async throws {
        let harness = try await makeWhisperHarness(python: FakePython.garbageStdout)
        let wav = try harness.makeWAV()
        let error = await engineError {
            try await harness.engine.transcribe(ASRRequest(audioURL: wav))
        }
        guard case .transient(let reason) = error else {
            Issue.record("expected .transient, got \(String(describing: error))")
            return
        }
        #expect(reason.contains("JSON"))
    }

    @Test func timeoutMapsToTransientTimeout() async throws {
        let harness = try await makeWhisperHarness(python: FakePython.sleeper, driverTimeout: 1)
        let wav = try harness.makeWAV()
        let error = await engineError {
            try await harness.engine.transcribe(ASRRequest(audioURL: wav))
        }
        #expect(error == .transient("timeout"))
    }

    @Test func spawnFailureMapsToNotAvailableAndInvalidatesSentinel() async throws {
        let harness = try await makeWhisperHarness(python: FakePython.success)
        // Break the interpreter AFTER provisioning checks pass.
        try FileManager.default.removeItem(at: harness.pythonBinary)
        #expect(FileManager.default.fileExists(atPath: harness.sentinelURL.path))

        let wav = try harness.makeWAV()
        let error = await engineError {
            try await harness.engine.transcribe(ASRRequest(audioURL: wav))
        }
        guard case .notAvailable(let reason) = error else {
            Issue.record("expected .notAvailable, got \(String(describing: error))")
            return
        }
        #expect(reason.contains("failed to launch"))
        // Self-heal: the sentinel is gone, the next prepare rebuilds.
        #expect(!FileManager.default.fileExists(atPath: harness.sentinelURL.path))
    }

    @Test func uncaughtSignalMapsToTransient() async throws {
        let harness = try await makeWhisperHarness(
            python: FakePython.script("kill -SEGV $$"))
        let wav = try harness.makeWAV()
        let error = await engineError {
            try await harness.engine.transcribe(ASRRequest(audioURL: wav))
        }
        guard case .transient = error else {
            Issue.record("expected .transient, got \(String(describing: error))")
            return
        }
    }

    @Test func cancellationWhileRunningKillsProcessAndNextCallSucceeds() async throws {
        let harness = try await makeWhisperHarness(python: FakePython.sleeper, driverTimeout: 120)
        let wav = try harness.makeWAV()
        let task = Task {
            try await harness.engine.transcribe(ASRRequest(audioURL: wav))
        }
        try await Task.sleep(for: .milliseconds(400))
        task.cancel()
        let started = Date()
        await #expect(throws: EngineError.cancelled) { _ = try await task.value }
        #expect(Date().timeIntervalSince(started) < 10)

        // The chain is healthy and the engine still works.
        try harness.installPython(FakePython.success)
        let result = try await harness.engine.transcribe(ASRRequest(audioURL: wav))
        #expect(result.segments.map(\.text) == [" ola", " mundo"])
    }

    @Test func successPathNormalizesAndReportsHonestProvenance() async throws {
        let harness = try await makeWhisperHarness(python: FakePython.success)
        // Plant a suspect marker: a successful transcribe must clear it.
        harness.cache.recordLoadFailure()
        let wav = try harness.makeWAV(seconds: 2.0)
        let result = try await harness.engine.transcribe(
            ASRRequest(audioURL: wav, languageHint: "pt"))
        #expect(result.segments.count == 2)
        #expect(result.segments.allSatisfy { $0.words != nil })
        #expect(result.detectedLanguage == "pt")
        #expect(result.provenance.engine == MLXWhisperEngine.engineID)
        #expect(result.provenance.model == MLXWhisperEngine.modelRepo)
        #expect(result.provenance.runtime == "mlx-whisper/subprocess")
        #expect(result.provenance.engineVersion == "0.4.3-fake")
        #expect(result.provenance.languageHint == "pt")
        #expect(!result.provenance.vocabularyHintsApplied)
        // Raw payload is the verbatim driver stdout.
        let raw = try JSONDecoder().decode(WhisperDriverOutput.self, from: result.rawPayload)
        #expect(raw.segments.count == 2)
        // Suspicion cleared by success.
        #expect(harness.cache.suspectState() == nil)
    }

    /// AC1: N concurrent transcribe() → sequential spawn count.
    @Test(.timeLimit(.minutes(1)))
    func concurrentTranscribesSpawnSequentially() async throws {
        let harness = try await makeWhisperHarness(python: nil)
        let log = harness.dataRoot.appendingPathComponent("spawn.log")
        try harness.installPython(
            FakePython.script("""
                echo S >> '\(log.path)'
                sleep 0.2
                echo E >> '\(log.path)'
                cat <<'JSON'
                \(fakeDriverJSON)
                JSON
                exit 0
                """))
        try harness.writeSentinel()
        let wav = try harness.makeWAV()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 4 {
                group.addTask {
                    _ = try await harness.engine.transcribe(ASRRequest(audioURL: wav))
                }
            }
            try await group.waitForAll()
        }
        let events = try String(contentsOf: log, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(events.count == 8)
        // Sequential: strict S/E alternation, never two spawns in flight.
        for (index, event) in events.enumerated() {
            #expect(event == (index.isMultiple(of: 2) ? "S" : "E"))
        }
    }
}

// MARK: - Integrity / suspect / repair decision logic

@Suite struct WhisperModelCacheTests {
    private func makeHFHome() throws -> URL {
        try makeTempRoot().appendingPathComponent("hf", isDirectory: true)
    }

    @Test func integrityTrueForCompleteCache() throws {
        let hfHome = try makeHFHome()
        try WhisperHarness.plantCompleteCache(hfHome: hfHome)
        #expect(WhisperModelCache(hfHome: hfHome).integrity())
    }

    @Test func integrityFalseWhenSnapshotsMissingOrEmpty() throws {
        let hfHome = try makeHFHome()
        let cache = WhisperModelCache(hfHome: hfHome)
        #expect(!cache.integrity())  // nothing exists
        let emptySnapshot = cache.repoCacheDir.appendingPathComponent("snapshots/main", isDirectory: true)
        try FileManager.default.createDirectory(at: emptySnapshot, withIntermediateDirectories: true)
        #expect(!cache.integrity())  // snapshot dir exists but is empty
    }

    @Test func integrityFalseWithIncompleteBlob() throws {
        let hfHome = try makeHFHome()
        try WhisperHarness.plantCompleteCache(hfHome: hfHome)
        let cache = WhisperModelCache(hfHome: hfHome)
        let blobs = cache.repoCacheDir.appendingPathComponent("blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: blobs.appendingPathComponent("abc123.incomplete"))
        #expect(!cache.integrity())
    }

    @Test func suspectStateRoundTripsAndPersists() throws {
        let hfHome = try makeHFHome()
        let cache = WhisperModelCache(hfHome: hfHome)
        #expect(cache.suspectState() == nil)
        cache.recordLoadFailure()
        #expect(cache.suspectState() == .init(attempts: 1, repairedSinceLastFailure: false))
        cache.recordLoadFailure()
        #expect(cache.suspectState()?.attempts == 2)
        cache.recordRepairCompleted()
        #expect(cache.suspectState() == .init(attempts: 2, repairedSinceLastFailure: true))
        // Persisted (survives "relaunch" — a fresh instance reads the marker).
        let rebornCache = WhisperModelCache(hfHome: hfHome)
        #expect(rebornCache.suspectState()?.attempts == 2)
        rebornCache.clearSuspect()
        #expect(cache.suspectState() == nil)
    }

    @Test func prepareRepairsIntactButSuspectCacheByWipeAndRefetch() async throws {
        let fetchCalls = Recorder<URL>()
        let harness = try await makeWhisperHarness(
            python: FakePython.success,
            modelFetch: { hfHome in
                fetchCalls.append(hfHome)
                try WhisperHarness.plantCompleteCache(hfHome: hfHome)
            })
        // Distinctive pre-wipe content that must vanish.
        let stale = harness.cache.repoCacheDir.appendingPathComponent("snapshots/main/stale-file")
        try Data("stale".utf8).write(to: stale)
        harness.cache.recordLoadFailure()

        try await harness.engine.prepare()
        #expect(fetchCalls.values.count == 1)
        #expect(!FileManager.default.fileExists(atPath: stale.path))  // wiped
        #expect(harness.cache.suspectState()?.repairedSinceLastFailure == true)
        #expect(harness.cache.integrity())
    }

    @Test func prepareFetchesWhenIntegrityFalseWithoutWiping() async throws {
        let fetchCalls = Recorder<URL>()
        let harness = try await makeWhisperHarness(
            python: FakePython.success,
            completeCache: false,
            modelFetch: { hfHome in
                fetchCalls.append(hfHome)
                try WhisperHarness.plantCompleteCache(hfHome: hfHome)
            })
        try await harness.engine.prepare()
        #expect(fetchCalls.values.count == 1)
        #expect(harness.cache.integrity())
        // No suspicion involved: marker untouched (absent).
        #expect(harness.cache.suspectState() == nil)
    }

    @Test func prepareDoesNothingWhenCacheHealthy() async throws {
        let fetchCalls = Recorder<URL>()
        let harness = try await makeWhisperHarness(
            python: FakePython.success,
            modelFetch: { fetchCalls.append($0) })
        try await harness.engine.prepare()
        #expect(fetchCalls.values.isEmpty)
    }
}

// MARK: - Provisioning predicates + override semantics + availability

@Suite struct WhisperProvisioningTests {
    @Test func sentinelNameBindsToRequirementsHash() {
        let dataA = Data("mlx-whisper==0.4.3".utf8)
        let dataB = Data("mlx-whisper==0.9.9".utf8)
        let nameA = VenvLayout.sentinelName(requirementsData: dataA)
        let nameB = VenvLayout.sentinelName(requirementsData: dataB)
        #expect(nameA.hasPrefix(".blaise-provisioned-"))
        #expect(nameA.count == ".blaise-provisioned-".count + 64)
        #expect(nameA != nameB)
        #expect(nameA == VenvLayout.sentinelName(requirementsData: dataA))  // deterministic
    }

    @Test func isProvisionedRequiresMatchingSentinel() throws {
        let venv = try makeTempRoot()
        let current = Data("pins-v2".utf8)
        let stale = Data("pins-v1".utf8)
        #expect(!VenvLayout.isProvisioned(venvDir: venv, requirementsData: current))
        // A sentinel for a DIFFERENT pin set does not satisfy (mismatch → rebuild).
        try Data().write(to: VenvLayout.sentinelURL(venvDir: venv, requirementsData: stale))
        #expect(!VenvLayout.isProvisioned(venvDir: venv, requirementsData: current))
        try Data().write(to: VenvLayout.sentinelURL(venvDir: venv, requirementsData: current))
        #expect(VenvLayout.isProvisioned(venvDir: venv, requirementsData: current))
    }

    @Test func availabilityBeforeFirstPrepareIsNotYetProvisioned() async throws {
        let harness = try await makeWhisperHarness(python: nil, completeCache: false)
        let availability = await harness.engine.availability()
        #expect(availability == .unavailable(reason: "not yet provisioned"))
    }

    @Test func availabilityWithVenvButNoModelCacheNamesTheCache() async throws {
        let harness = try await makeWhisperHarness(python: FakePython.success, completeCache: false)
        let availability = await harness.engine.availability()
        guard case .unavailable(let reason) = availability else {
            Issue.record("expected unavailable, got \(availability)")
            return
        }
        #expect(reason.contains("model cache"))
    }

    @Test func availabilityAvailableWhenProvisionedAndCacheIntact() async throws {
        let harness = try await makeWhisperHarness(python: FakePython.success)
        #expect(await harness.engine.availability() == .available)
    }

    @Test func overrideDisablesProvisioningAndSentinelLogic() async throws {
        // Externally managed venv: a fake one with a working "python", no
        // sentinel anywhere, no uv binary in existence.
        let harness = try await makeWhisperHarness(python: nil, completeCache: true)
        let externalVenv = try makeTempRoot().appendingPathComponent("ext-venv", isDirectory: true)
        try harness.installPython(FakePython.success, at: externalVenv)
        try await harness.settings.set(
            "engine.\(MLXWhisperEngine.engineID).\(MLXWhisperEngine.venvPathKey)",
            to: externalVenv.path)

        // prepare() must NOT provision: no default venv dir, no sentinel.
        try await harness.engine.prepare()
        #expect(!FileManager.default.fileExists(atPath: harness.venvDir.path))

        // transcribe works against the external venv.
        let wav = try harness.makeWAV()
        let result = try await harness.engine.transcribe(ASRRequest(audioURL: wav))
        #expect(result.segments.count == 2)

        // availability = import check only ("python" runs, exits 0 for -c).
        #expect(await harness.engine.availability() == .available)

        // Spawn failure under override: .notAvailable, NO sentinel side
        // effects (nothing created or deleted under the default layout).
        try FileManager.default.removeItem(
            at: externalVenv.appendingPathComponent("bin/python"))
        let error = await engineError {
            try await harness.engine.transcribe(ASRRequest(audioURL: wav))
        }
        guard case .notAvailable = error else {
            Issue.record("expected .notAvailable, got \(String(describing: error))")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: harness.dataRoot.appendingPathComponent("python").path))
    }

    @Test func perEngineConfigKeysAreNamespaced() async throws {
        let database = try makeDatabase()
        let settings = SettingsStore(database: database)
        let secrets = InMemorySecretStore()
        let whisperConfig = EngineConfiguration(
            engineID: MLXWhisperEngine.engineID, descriptors: MLXWhisperEngine.descriptors,
            settings: settings, secrets: secrets)
        let parakeetConfig = EngineConfiguration(
            engineID: FluidAudioParakeetEngine.engineID,
            descriptors: FluidAudioParakeetEngine.descriptors,
            settings: settings, secrets: secrets)

        try await settings.set("engine.\(MLXWhisperEngine.engineID).venvPath", to: "/whisper/venv")
        try await settings.set(
            "engine.\(FluidAudioParakeetEngine.engineID).modelsPath", to: "/parakeet/models")

        #expect(try await whisperConfig.value(for: "venvPath") == "/whisper/venv")
        #expect(try await parakeetConfig.value(for: "modelsPath") == "/parakeet/models")
        // No cross-talk: each engine sees only its own namespace.
        #expect(try await parakeetConfig.value(for: "venvPath") == nil)
        #expect(try await whisperConfig.value(for: "modelsPath") == nil)
    }
}

// MARK: - Orphan sweep matcher

@Suite struct OrphanSweeperTests {
    private let driverPath = "/Applications/Blaise.app/Contents/Resources/whisper_driver.py"

    @Test func parsesPSOutputLines() {
        let record = OrphanSweeper.parsePSLine(
            "  123     1 /venv/bin/python \(driverPath) --blaise-engine --audio /tmp/a.wav")
        #expect(record == .init(
            pid: 123, ppid: 1,
            command: "/venv/bin/python \(driverPath) --blaise-engine --audio /tmp/a.wav"))
        #expect(OrphanSweeper.parsePSLine("") == nil)
        #expect(OrphanSweeper.parsePSLine("garbage") == nil)
        #expect(OrphanSweeper.parsePSLine("abc def ghi") == nil)
    }

    @Test func matchesOnlyReparentedDriversWithMarker() {
        func record(_ ppid: Int32, _ command: String) -> OrphanSweeper.ProcessRecord {
            .init(pid: 999, ppid: ppid, command: command)
        }
        let orphan = record(1, "/venv/bin/python \(driverPath) --blaise-engine --audio /tmp/a.wav")
        #expect(OrphanSweeper.isOrphanedDriver(orphan, driverPath: driverPath))

        // Live parent → never touched (ppid-1 is the load-bearing rule).
        let owned = record(4242, "/venv/bin/python \(driverPath) --blaise-engine --audio /tmp/a.wav")
        #expect(!OrphanSweeper.isOrphanedDriver(owned, driverPath: driverPath))

        // Reparented but not ours (no marker / different script).
        #expect(!OrphanSweeper.isOrphanedDriver(
            record(1, "/venv/bin/python \(driverPath) --audio /tmp/a.wav"), driverPath: driverPath))
        #expect(!OrphanSweeper.isOrphanedDriver(
            record(1, "/venv/bin/python /other/script.py --blaise-engine"), driverPath: driverPath))
    }
}

// Orchestrator regression: NaN handling end-to-end (caught live — mlx-whisper
// emitted NaN in a probability field; Python json wrote it; Foundation refused
// the document).
@Suite struct WhisperNaNRegressionTests {
    @Test func nullProbabilitiesAndTimingsDecodeAndDrop() throws {
        let json = """
        {"text":"x","language":"pt","segments":[
          {"start":0.0,"end":1.0,"text":"ok","no_speech_prob":null,"avg_logprob":null,
           "words":[{"word":"ok","start":0.0,"end":1.0},{"word":"bad","start":null,"end":null}]},
          {"start":null,"end":null,"text":"garbage","words":[]}
        ]}
        """
        let decoded = try JSONDecoder().decode(WhisperDriverOutput.self, from: Data(json.utf8))
        let segments = decoded.asrSegments
        #expect(segments.count == 1, "null-timed segment must be dropped")
        #expect(segments[0].words?.count == 1, "null-timed word must be dropped")
    }
}
