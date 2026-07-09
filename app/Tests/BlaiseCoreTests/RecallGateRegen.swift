import Foundation
import GRDB
import Testing

@testable import BlaiseCore

// DEV-ONLY recall-gate regen runner. It is a Swift Testing `@Test` so it can
// reach `@testable` internals, but it is really a headless tool, GATED OFF by
// default (skips unless BLAISE_RECALL_GATE=1) so the normal suite is untouched.
//
// What it does: for a set of EXISTING, already-`ready` meetings in a SEEDED
// THROWAWAY data root (a copy of prod), it re-fires ONLY the digest cloud call
// over the stored transcript + stored notes (`processDigestOnly`) and collects,
// per meeting:
//   - the regenerated md-v3 digest (`<id>.digest.md`), and
//   - the BYTE-EXACT rendered digest user-message the model saw, captured by
//     the pre-existing `BLAISE_DUMP_DIGEST_INPUT=1` seam in
//     `generateMemoryDigest` (now written into the meeting's OWN directory at
//     `<meetingDir>/.digest_input.txt`, so the PII-bearing dump is reaped with
//     the meeting; this runner copies it out as `<id>.digest_input.txt`).
// Plus the run's `Glossary.md` and a `manifest.json` for the recall-gate judge.
//
// It NEVER seeds, creates, or mutates meeting/transcript/notes content — it
// operates only on existing rows. The only DB write is the bookkeeping
// `digest-pending:` marker that `processDigestOnly` requires as its entry gate;
// a successful re-fire clears it again (same self-heal path the app uses).

/// A no-op diarizer: digest-only re-fire never touches audio or diarization,
/// so these methods are unreachable here (mirrors `PipelineMockDiarizer`).
private final class RecallGateNoopDiarizer: Diarizing, @unchecked Sendable {
    func prepare() async throws {}
    func availability() async -> EngineAvailability { .available }
    func diarize(audioURL: URL, attendeeCount: Int?) async throws -> DiarizationOutput {
        DiarizationOutput(segments: [], speakerCount: 0)
    }
}

/// Per-meeting outcome (a data condition, never a test failure).
private enum RegenResult {
    case ok(MeetingID)
    case skipped(MeetingID, reason: String)
    case failed(MeetingID, reason: String)
}

@Suite(.serialized) struct RecallGateRegen {
    /// Env this runner consumes (all read from the INVOKER's environment):
    ///   - BLAISE_RECALL_GATE      arm switch — "1" runs; anything else skips.
    ///   - BLAISE_DATA_ROOT        seeded throwaway data root (blaise.db + Glossary.md).
    ///   - ANTHROPIC_API_KEY       cloud key for the digest call.
    ///   - BLAISE_RECALL_MEETINGS  comma-separated meeting IDs (ULID strings).
    ///   - BLAISE_RECALL_OUT       output dir (optional; default <root>/_recall_gate/out).
    ///   - BLAISE_DUMP_DIGEST_INPUT must be "1" so the seam captures the rendered input.
    @Test
    func recallGateRegen() async throws {
        let env = ProcessInfo.processInfo.environment

        // 1. Gate: OFF by default so the normal suite is unaffected.
        guard env["BLAISE_RECALL_GATE"] == "1" else {
            recordTestSkip(
                "recallGateRegen",
                reason: "dev-only recall-gate regen runner — arm with BLAISE_RECALL_GATE=1 (plus BLAISE_DATA_ROOT, ANTHROPIC_API_KEY, BLAISE_RECALL_MEETINGS, BLAISE_DUMP_DIGEST_INPUT=1)")
            return
        }

        // 2. Required env (a missing one is a genuine test failure — the runner
        //    was armed but cannot do its job).
        func require(_ key: String) throws -> String {
            guard let value = env[key], !value.isEmpty else {
                Issue.record("recallGateRegen: required env \(key) is missing or empty")
                throw RegenAbort.missingEnv(key)
            }
            return value
        }

        let dataRootPath = try require("BLAISE_DATA_ROOT")
        let apiKey = try require("ANTHROPIC_API_KEY")
        let meetingsRaw = try require("BLAISE_RECALL_MEETINGS")

        // The seam must be armed by the INVOKER: ProcessInfo.environment is a
        // snapshot taken at process start, so setting it from inside this
        // process would NOT reach the seam's own read. Fail loudly instead.
        guard env["BLAISE_DUMP_DIGEST_INPUT"] == "1" else {
            Issue.record(
                "recallGateRegen: set BLAISE_DUMP_DIGEST_INPUT=1 so the seam captures the rendered input (must be set by the invoker, not from inside the process)")
            throw RegenAbort.seamNotArmed
        }

        let meetingIDs = meetingsRaw
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !meetingIDs.isEmpty else {
            Issue.record("recallGateRegen: BLAISE_RECALL_MEETINGS held no usable meeting IDs after trimming")
            throw RegenAbort.noMeetings
        }

        let root = URL(fileURLWithPath: dataRootPath, isDirectory: true)
        let outDir: URL = {
            if let custom = env["BLAISE_RECALL_OUT"], !custom.isEmpty {
                return URL(fileURLWithPath: custom, isDirectory: true)
            }
            return root.appendingPathComponent("_recall_gate", isDirectory: true)
                .appendingPathComponent("out", isDirectory: true)
        }()
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        // 3. Build a CLOUD-only pipeline over the EXISTING seeded DB.
        let database = try BlaiseDatabase(rootURL: root)
        let settings = SettingsStore(database: database)

        let secrets = InMemorySecretStore()
        try secrets.set(
            key: "engine.\(ClaudeSummarizationEngine.engineID).\(ClaudeSummarizationEngine.apiKeyConfigKey)",
            value: apiKey)

        // Force the summarization slot to the cloud engine (also the shipped
        // default, set explicitly for belt-and-suspenders) AND register ONLY
        // Claude, so no local 18 GB-peak engine can ever be resolved here.
        try await settings.set(
            EngineResolver.summarizationSettingsKey, to: ClaudeSummarizationEngine.engineID)

        let ledger = CloudSpendLedger(database: database)
        let claude = ClaudeSummarizationEngine(
            configuration: EngineConfiguration(
                engineID: ClaudeSummarizationEngine.engineID,
                descriptors: ClaudeSummarizationEngine.descriptors,
                settings: settings,
                secrets: secrets),
            ledger: ledger)
        // ASR slot empty: digest-only never resolves or runs ASR.
        let registry = try EngineRegistry(asr: [], summarization: [claude])

        let pipeline = ProcessingPipeline(
            database: database,
            registry: registry,
            diarizer: RecallGateNoopDiarizer(),
            vocabularyProvider: { PipelineVocabulary.user(dataRoot: root) })

        // 4. Per-meeting regen. Catch per meeting; never throw out of the loop.
        var results: [RegenResult] = []
        let meetings = MeetingRepository(database: database)
        let notesRepo = NotesRepository(database: database)

        for id in meetingIDs {
            do {
                guard let meeting = try await meetings.fetch(id) else {
                    results.append(.skipped(id, reason: "no meeting row"))
                    continue
                }
                guard meeting.status == .ready else {
                    results.append(.skipped(id, reason: "status \(meeting.status.rawValue) (not ready)"))
                    continue
                }

                // Set the digest-pending marker that `processDigestOnly` gates
                // on (bookkeeping only — no status change, no content change).
                try await database.pool.write { db in
                    guard var m = try Meeting.fetchOne(db, key: id) else { return }
                    m.lastProcessingError = DigestPendingClass.marker("recall-gate regen")
                    try m.update(db)
                }

                let ok = try await pipeline.processDigestOnly(meetingID: id)
                guard ok else {
                    results.append(.failed(id, reason: "processDigestOnly returned false (no digest produced — see log)"))
                    continue
                }

                guard let digest = try await notesRepo.fetch(meetingID: id)?.memoryDigest else {
                    results.append(.failed(id, reason: "no digest produced (memoryDigest nil after re-fire)"))
                    continue
                }

                // Write the regenerated digest.
                try Data(digest.utf8).write(
                    to: outDir.appendingPathComponent("\(id).digest.md"), options: .atomic)

                // Copy the seam's byte-exact rendered input next to it. The seam
                // now writes into the MEETING'S OWN directory (so the PII-bearing
                // dump is reaped with the meeting on delete), at
                // `<meetingDir>/.digest_input.txt`.
                let seamDump = database.paths.meetingDirectory(id)
                    .appendingPathComponent(".digest_input.txt")
                let inputCopy = outDir.appendingPathComponent("\(id).digest_input.txt")
                if FileManager.default.fileExists(atPath: seamDump.path) {
                    try? FileManager.default.removeItem(at: inputCopy)
                    try FileManager.default.copyItem(at: seamDump, to: inputCopy)
                } else {
                    print("[recall-gate] WARN \(id): seam dump missing — was BLAISE_DUMP_DIGEST_INPUT=1 set by the invoker?")
                }

                results.append(.ok(id))
            } catch {
                results.append(.failed(id, reason: "exception: \(error)"))
            }
        }

        // 5. Glossary + manifest.
        let glossarySrc = MeetingPaths(rootURL: root).glossaryURL
        let glossaryOut = outDir.appendingPathComponent("Glossary.md")
        if FileManager.default.fileExists(atPath: glossarySrc.path) {
            try? FileManager.default.removeItem(at: glossaryOut)
            try FileManager.default.copyItem(at: glossarySrc, to: glossaryOut)
        } else {
            print("[recall-gate] WARN: \(glossarySrc.path) missing — glossary_path will reference a non-existent file")
        }

        let manifestEntries: [[String: Any]] = results.compactMap { result in
            guard case .ok(let id) = result else { return nil }
            return [
                "meeting_id": id,
                "transcript_path": outDir.appendingPathComponent("\(id).digest_input.txt").path,
                "digest_path": outDir.appendingPathComponent("\(id).digest.md").path,
                "glossary_path": glossaryOut.path,
                "hard_case_tags": [String](),
            ]
        }
        let manifest: [String: Any] = ["meetings": manifestEntries]
        let manifestData = try JSONSerialization.data(
            withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try manifestData.write(to: outDir.appendingPathComponent("manifest.json"), options: .atomic)

        // 6. Final summary (counts are data conditions; do NOT #expect-fail on
        //    a per-meeting skip/failure).
        let okCount = results.filter { if case .ok = $0 { return true } else { return false } }.count
        let skippedCount = results.filter { if case .skipped = $0 { return true } else { return false } }.count
        let failedCount = results.filter { if case .failed = $0 { return true } else { return false } }.count
        print("""
            [recall-gate] regen complete:
              ok=\(okCount)  skipped=\(skippedCount)  failed=\(failedCount)
              out=\(outDir.path)
            """)
        for result in results {
            switch result {
            case .ok(let id): print("  ok      \(id)")
            case .skipped(let id, let reason): print("  skipped \(id) — \(reason)")
            case .failed(let id, let reason): print("  failed  \(id) — \(reason)")
            }
        }
    }
}

/// Thrown only for missing-required-env / construction preconditions (a genuine
/// armed-but-cannot-run failure), so the loop's per-meeting catch never absorbs
/// them. Each throw is paired with an `Issue.record` above for the visible message.
private enum RegenAbort: Error {
    case missingEnv(String)
    case seamNotArmed
    case noMeetings
}
