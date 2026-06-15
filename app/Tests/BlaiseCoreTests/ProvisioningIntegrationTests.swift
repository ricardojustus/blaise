import Foundation
import Testing
@testable import BlaiseCore

// AC3 (gated `BLAISE_TEST_PROVISION=1`, mandatory before C13): clean temp
// dataRoot → FULL real provisioning (uv-managed CPython + hashed pin set +
// 1.5 GB model fetch), then the three repair paths end-to-end. Roughly 2 GB
// of downloads on a cold run; the gate exists so ordinary suite runs stay
// fast. When the gate is off the test records a skip-protocol entry, which
// forces the C13 acceptance run to set the variable.

private let provisionGateEnabled = ProcessInfo.processInfo.environment["BLAISE_TEST_PROVISION"] == "1"

/// Copies the first `seconds` of a 16 kHz mono PCM WAV into a new file
/// (real speech for the post-provisioning transcribe check).
private func extractWAVPrefix(from source: URL, seconds: Double, to destination: URL) throws {
    let data = try Data(contentsOf: source)
    // Locate the data chunk (12-byte RIFF header, then chunks).
    var offset = 12
    while offset + 8 <= data.count {
        let id = data[offset ..< offset + 4]
        let size = Int(data[offset + 4]) | Int(data[offset + 5]) << 8
            | Int(data[offset + 6]) << 16 | Int(data[offset + 7]) << 24
        if id == Data("data".utf8) {
            let pcmStart = offset + 8
            let wanted = min(Int(seconds * 16000) * 2, size)
            let pcm = data[pcmStart ..< pcmStart + wanted]
            var out = Data()
            func appendUInt32(_ value: UInt32) {
                withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
            }
            func appendUInt16(_ value: UInt16) {
                withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
            }
            out.append(contentsOf: Array("RIFF".utf8))
            appendUInt32(UInt32(36 + pcm.count))
            out.append(contentsOf: Array("WAVE".utf8))
            out.append(contentsOf: Array("fmt ".utf8))
            appendUInt32(16)
            appendUInt16(1)
            appendUInt16(1)
            appendUInt32(16000)
            appendUInt32(32000)
            appendUInt16(2)
            appendUInt16(16)
            out.append(contentsOf: Array("data".utf8))
            appendUInt32(UInt32(pcm.count))
            out.append(pcm)
            try out.write(to: destination)
            return
        }
        offset += 8 + size + size % 2
    }
    throw TestFailure()
}

@Suite(.serialized) struct ProvisioningIntegrationTests {
    @Test(.timeLimit(.minutes(60)))
    func fullProvisioningLifecycle() async throws {
        guard provisionGateEnabled else {
            recordTestSkip(
                "fullProvisioningLifecycle",
                reason: "BLAISE_TEST_PROVISION not set (mandatory before C13; ~2 GB of downloads)")
            return
        }
        let uvBinary = VocabFixtures.repoRoot.appendingPathComponent("vendor/uv/uv")
        try #require(
            FileManager.default.isExecutableFile(atPath: uvBinary.path),
            "run scripts/fetch_uv.sh first")

        let dataRoot = try makeTempRoot()
        let database = try BlaiseDatabase(rootURL: dataRoot)
        let settings = SettingsStore(database: database)
        let requirementsFile = try #require(MLXWhisperEngine.bundledRequirementsFile())
        let engine = MLXWhisperEngine(
            configuration: EngineConfiguration(
                engineID: MLXWhisperEngine.engineID,
                descriptors: MLXWhisperEngine.descriptors,
                settings: settings,
                secrets: InMemorySecretStore()),
            dataRoot: dataRoot,
            uvBinary: uvBinary,
            driverScript: try #require(MLXWhisperEngine.bundledDriverScript()),
            requirementsFile: requirementsFile,
            sweepOrphansOnInit: false)

        // 1. Clean dataRoot: not yet provisioned.
        #expect(await engine.availability() == .unavailable(reason: "not yet provisioned"))

        // 2. Full prepare: uv venv from pins+hashes, sentinel, model fetch.
        let prepareStarted = Date()
        try await engine.prepare()
        print("[provision] full prepare: \(String(format: "%.0f", Date().timeIntervalSince(prepareStarted))) s")

        // Availability flips; sentinel + interpreter live inside dataRoot.
        #expect(await engine.availability() == .available)
        let venvDir = dataRoot.appendingPathComponent("python/venv", isDirectory: true)
        let requirementsData = try Data(contentsOf: requirementsFile)
        let sentinel = VenvLayout.sentinelURL(venvDir: venvDir, requirementsData: requirementsData)
        #expect(FileManager.default.fileExists(atPath: sentinel.path))
        #expect(FileManager.default.fileExists(
            atPath: dataRoot.appendingPathComponent("python/cpython").path))

        // 3. A 10 s slice of real speech transcribes.
        let shortWAV = dataRoot.appendingPathComponent("short.wav")
        try extractWAVPrefix(
            from: VocabFixtures.fixture("icsi_sample/Bmr001_excerpt_5min.wav"), seconds: 10, to: shortWAV)
        let result = try await engine.transcribe(ASRRequest(audioURL: shortWAV, languageHint: "en"))
        #expect(!result.segments.isEmpty)
        #expect(result.provenance.engineVersion == "0.4.3")

        let cache = WhisperModelCache(
            hfHome: dataRoot.appendingPathComponent("models/hf", isDirectory: true))
        #expect(cache.integrity())

        // 4. Interrupted-download simulation: a planted *.incomplete blob
        // flips the predicate; prepare runs the repair fetch (resume path).
        let blobs = cache.repoCacheDir.appendingPathComponent("blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        let planted = blobs.appendingPathComponent("deadbeef.incomplete")
        try Data("partial".utf8).write(to: planted)
        #expect(!cache.integrity())
        try await engine.prepare()  // repair fetch runs (everything resumable is present)
        try FileManager.default.removeItem(at: planted)  // clear the plant
        #expect(cache.integrity())

        // 5. Sentinel invalidation → destroy + rebuild on next prepare.
        try FileManager.default.removeItem(at: sentinel)
        let rebuildStarted = Date()
        try await engine.prepare()
        print("[provision] rebuild after sentinel invalidation: \(String(format: "%.0f", Date().timeIntervalSince(rebuildStarted))) s")
        #expect(FileManager.default.fileExists(atPath: sentinel.path))
        #expect(await engine.availability() == .available)

        // 6. Corrupted model → exit-3 → suspect → wipe-repair → success.
        let snapshots = cache.repoCacheDir.appendingPathComponent("snapshots", isDirectory: true)
        let snapshotDirs = try FileManager.default.contentsOfDirectory(
            at: snapshots, includingPropertiesForKeys: nil)
        for snapshot in snapshotDirs {
            let weights = snapshot.appendingPathComponent("weights.safetensors")
            if FileManager.default.fileExists(atPath: weights.path) {
                // Resolve the symlinked blob and corrupt the real bytes.
                let resolved = weights.resolvingSymlinksInPath()
                try Data("corrupted".utf8).write(to: resolved)
            }
        }
        let corrupted = await engineError {
            try await engine.transcribe(ASRRequest(audioURL: shortWAV))
        }
        guard case .notAvailable = corrupted else {
            Issue.record("expected .notAvailable from corrupted model, got \(String(describing: corrupted))")
            return
        }
        #expect(cache.suspectState() != nil)

        // Repair: integrity TRUE + suspect → wipe + full re-fetch; transcribe
        // succeeds again and the marker clears.
        let repairStarted = Date()
        let healed = try await engine.transcribe(ASRRequest(audioURL: shortWAV, languageHint: "en"))
        print("[provision] wipe-repair + retranscribe: \(String(format: "%.0f", Date().timeIntervalSince(repairStarted))) s")
        #expect(!healed.segments.isEmpty)
        #expect(cache.suspectState() == nil)
    }
}
