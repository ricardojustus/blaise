import BlaiseCore
import Foundation

// C7 crash-harness child process (scripts/c7_crash_harness.sh) + the C8
// handoff integration harness (scripts/c8_integration.sh).
//
// Modes:
//   import  <dataRoot> <wav>                      → prints the new meeting ULID
//   process <dataRoot> <meetingID> [--real-asr --venv <p> --hf <p>]
//                                                  → runs the pipeline (BLAISE_CRASH_AT honored)
//   status  <dataRoot> <meetingID>                 → opens the DB (startup sweeps RUN) and
//                                                    prints one JSON line of observable state
//   handoff-seed  <dataRoot> <count> [--payload-kb N]
//                                                  → seeds N synthetic ready meetings with
//                                                    queued payloads (real builder + finalize
//                                                    codepaths; re-materializable rows)
//   handoff-drain <dataRoot> [--remote-root R] [--hosts a,b] [--user U] [--identity F]
//                                                  → applies handoff.* settings, runs the REAL
//                                                    HandoffWorker until settled (one external
//                                                    wake; BLAISE_CRASH_AT honored), prints
//                                                    DELIVERED lines + final snapshot JSON
//   handoff-queue <dataRoot>                       → prints queue rows as JSON lines (DB open
//                                                    runs the C1 delivering→pending sweep)
//
// Stub engines are byte-deterministic (fixed dates, fixed clock) — the only
// honest way to assert byte-level no-ops at the deterministic kill points.
// `--real-asr` swaps in the real MLXWhisperEngine for the timing-kill test.

let fixedDate = Date(timeIntervalSince1970: 1_770_000_000)

/// Repo-relative fixture URL (the `#filePath` convention the test target uses):
/// this file lives at `app/Sources/CrashRunner/main.swift`, so the repo root is
/// four parents up.
func repoFixture(_ name: String) -> URL {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0 ..< 4 { url.deleteLastPathComponent() }
    return url.appendingPathComponent("fixtures").appendingPathComponent(name)
}

// MARK: - Deterministic stub engines

struct StubASREngine: ASREngine {
    let id = "stub-asr"
    let displayName = "Stub ASR"
    let kind: EngineKind = .local
    let costDescriptor: EngineCostDescriptor? = nil
    let configDescriptors: [EngineConfigDescriptor] = []

    func availability() async -> EngineAvailability { .available }

    func transcribe(_ request: ASRRequest) async throws -> ASRResult {
        let segments = [
            ASRSegment(
                startSeconds: 0.0, endSeconds: 4.0, text: "Olá, vamos começar a reunião.",
                words: [
                    ASRWord(word: "Olá,", startSeconds: 0.0, endSeconds: 0.8),
                    ASRWord(word: "vamos", startSeconds: 0.9, endSeconds: 1.5),
                    ASRWord(word: "começar", startSeconds: 1.6, endSeconds: 2.4),
                    ASRWord(word: "a", startSeconds: 2.5, endSeconds: 2.6),
                    ASRWord(word: "reunião.", startSeconds: 2.7, endSeconds: 4.0),
                ]),
            ASRSegment(
                startSeconds: 4.5, endSeconds: 8.0, text: "Não temos muito tempo hoje.",
                words: [
                    ASRWord(word: "Não", startSeconds: 4.5, endSeconds: 4.9),
                    ASRWord(word: "temos", startSeconds: 5.0, endSeconds: 5.6),
                    ASRWord(word: "muito", startSeconds: 5.7, endSeconds: 6.3),
                    ASRWord(word: "tempo", startSeconds: 6.4, endSeconds: 7.0),
                    ASRWord(word: "hoje.", startSeconds: 7.1, endSeconds: 8.0),
                ]),
        ]
        return ASRResult(
            segments: segments,
            detectedLanguage: "pt",
            rawPayload: Data(#"{"stub":true,"segments":2}"#.utf8),
            usage: nil,
            provenance: ASRProvenance(
                engine: id, model: "stub-model", runtime: "stub-runtime",
                engineVersion: "1", transcribedAt: fixedDate))
    }
}

struct StubDiarizer: Diarizing {
    func prepare() async throws {}
    func availability() async -> EngineAvailability { .available }
    func diarize(audioURL: URL, attendeeCount: Int?) async throws -> DiarizationOutput {
        DiarizationOutput(
            segments: [
                DiarizedSegment(speakerLabel: "S0", startSeconds: 0.0, endSeconds: 4.2),
                DiarizedSegment(speakerLabel: "S1", startSeconds: 4.4, endSeconds: 8.0),
            ],
            speakerCount: 2)
    }
}

struct StubNotesEngine: SummarizationEngine {
    let id = "stub-notes"
    let displayName = "Stub Notes"
    let kind: EngineKind = .local
    let loadProfile: EngineLoadProfile = .lightweight
    let costDescriptor: EngineCostDescriptor? = nil
    let configDescriptors: [EngineConfigDescriptor] = []

    func availability() async -> EngineAvailability { .available }

    func generateNotes(_ request: NotesRequest, purpose: CloudSpendPurpose) async throws -> NotesResult {
        NotesResult(
            structured: NotesStructured(
                title: "Reunião de teste",
                summary: "Resumo determinístico para o harness de crash.",
                detailedNotes: "Notas detalhadas fixas.",
                decisions: ["Decisão fixa"],
                actionItems: [ActionItem(owner: "Demo User", text: "tarefa fixa")],
                userActionItems: [ActionItem(owner: "Demo User", text: "tarefa fixa")]),
            usage: nil,
            provenance: NotesProvenance(
                engine: id, model: "stub-model", pipelineVersion: "",
                runtime: "stub-runtime", rendererVersion: "", promptVersion: "stub-v1"),
            speakerNameMapping: [])
    }

    func generateDigest(_ request: DigestRequest, purpose: CloudSpendPurpose) async throws -> DigestResult {
        DigestResult(
            digest: "## HEADER\nmeeting: reunião de teste\nspeaker: (none resolved)\n",
            usage: nil,
            promptVersion: DigestPromptBuilder.shippedVersion.rawValue)
    }
}

// MARK: - C8 handoff-harness fixtures (deterministic synthetic content)

func makeSyntheticMeeting(id: String, ordinal: Int) -> BlaiseCore.Meeting {
    Meeting(
        id: id,
        title: "C8 handoff harness meeting \(ordinal)",
        startedAt: fixedDate,
        endedAt: fixedDate.addingTimeInterval(60),
        source: .imported,
        status: .processing,
        attendees: [Attendee(name: "Demo User", email: "demo@example.com", source: .manual)],
        dominantLanguage: "pt",
        asrProvenance: ASRProvenance(
            engine: "stub-asr", model: "stub-model", runtime: "stub-runtime",
            engineVersion: "1", transcribedAt: fixedDate),
        createdAt: fixedDate,
        updatedAt: fixedDate
    )
}

func makeSyntheticNotes(meetingID: String, ordinal: Int) -> MeetingNotes {
    MeetingNotes(
        meetingID: meetingID,
        markdown: "# Harness \(ordinal)\n\nResumo sintético.\n",
        structured: NotesStructured(
            title: "Harness \(ordinal)",
            summary: "Resumo sintético.",
            detailedNotes: "Notas do harness C8.",
            decisions: [],
            actionItems: [],
            userActionItems: []),
        language: "pt",
        generatedAt: fixedDate,
        provenance: NotesProvenance(
            engine: "stub-notes", model: "stub-model", pipelineVersion: "1.0",
            runtime: "stub-runtime", rendererVersion: "1", promptVersion: "stub-v1")
    )
}

// MARK: - Helpers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(2)
}

func makePipeline(dataRoot: URL, realASR: Bool, venv: String?, hfHome: String?) async throws
    -> (BlaiseDatabase, ProcessingPipeline)
{
    let database = try BlaiseDatabase(rootURL: dataRoot)
    let asrEngine: any ASREngine
    if realASR {
        guard let venv, let hfHome else { fail("--real-asr requires --venv and --hf") }
        let settings = SettingsStore(database: database)
        try await settings.set(
            "engine.\(MLXWhisperEngine.engineID).\(MLXWhisperEngine.venvPathKey)", to: venv)
        try await settings.set(
            "engine.\(MLXWhisperEngine.engineID).\(MLXWhisperEngine.hfHomePathKey)", to: hfHome)
        guard
            let driver = MLXWhisperEngine.bundledDriverScript(),
            let requirements = MLXWhisperEngine.bundledRequirementsFile()
        else { fail("bundled whisper driver/requirements missing") }
        asrEngine = MLXWhisperEngine(
            configuration: EngineConfiguration(
                engineID: MLXWhisperEngine.engineID,
                descriptors: MLXWhisperEngine.descriptors,
                settings: settings,
                secrets: InMemorySecretStore()),
            dataRoot: dataRoot,
            uvBinary: dataRoot.appendingPathComponent("uv-unused"),
            driverScript: driver,
            requirementsFile: requirements)
    } else {
        asrEngine = StubASREngine()
    }
    let registry = try EngineRegistry(asr: [asrEngine], summarization: [StubNotesEngine()])
    let pipeline = ProcessingPipeline(
        database: database,
        registry: registry,
        diarizer: StubDiarizer(),
        // G1: the crash harness pins the same byte-deterministic outputs as the
        // regression suite, so it loads the `fixture()` stack (raw parse of the
        // repo synthetic_vocab.txt), resolved repo-relative from this file.
        vocabulary: try PipelineVocabulary.fixture(vocabURL: repoFixture("synthetic_vocab.txt")),
        now: { realASR ? Date() : fixedDate })
    return (database, pipeline)
}

// MARK: - Entry

let args = CommandLine.arguments
guard args.count >= 2 else {
    fail("usage: CrashRunner import|process|status|handoff-seed|handoff-drain|handoff-queue|capture <dataRoot> … | ulid")
}
let mode = args[1]
// Standalone helper for the C8 integration harness (run-ULID minting).
if mode == "ulid" {
    print(ULID.generate())
    exit(0)
}
guard args.count >= 3 else {
    fail("usage: CrashRunner \(mode) <dataRoot> …")
}
let dataRoot = URL(fileURLWithPath: args[2], isDirectory: true)

// Task.detached, NOT Task: top-level code is MainActor-isolated, and the
// main thread parks in semaphore.wait() below — an inherited-MainActor task
// would never get to run (deadlock, observed).
let semaphore = DispatchSemaphore(value: 0)
let task = Task.detached {
    defer { semaphore.signal() }
    do {
        switch mode {
        case "import":
            guard args.count >= 4 else { fail("usage: CrashRunner import <dataRoot> <wav>") }
            let (_, pipeline) = try await makePipeline(
                dataRoot: dataRoot, realASR: false, venv: nil, hfHome: nil)
            let meeting = try await pipeline.importMeeting(
                sourceURL: URL(fileURLWithPath: args[3]),
                title: "Crash harness meeting",
                startedAt: fixedDate,
                attendees: [Attendee(name: "Demo User", email: "demo@example.com", source: .manual)])
            print(meeting.id)

        case "process":
            guard args.count >= 4 else { fail("usage: CrashRunner process <dataRoot> <meetingID>") }
            let meetingID = args[3]
            var realASR = false
            var venv: String?
            var hfHome: String?
            var index = 4
            while index < args.count {
                switch args[index] {
                case "--real-asr": realASR = true
                case "--venv":
                    index += 1
                    venv = args[index]
                case "--hf":
                    index += 1
                    hfHome = args[index]
                default: fail("unknown flag \(args[index])")
                }
                index += 1
            }
            let (_, pipeline) = try await makePipeline(
                dataRoot: dataRoot, realASR: realASR, venv: venv, hfHome: hfHome)
            let record = try await pipeline.process(meetingID: meetingID)
            print("processed \(meetingID): \(record.finalSegmentCount) segments, hash \(record.versionHash ?? "-")")

        case "status":
            guard args.count >= 4 else { fail("usage: CrashRunner status <dataRoot> <meetingID>") }
            let meetingID = args[3]
            // Opening the DB runs the C1 startup sweeps — that IS the
            // relaunch behavior under test.
            let database = try BlaiseDatabase(rootURL: dataRoot)
            guard let meeting = try await MeetingRepository(database: database).fetch(meetingID)
            else { fail("meeting not found: \(meetingID)") }
            let segments = try await TranscriptRepository(database: database)
                .segments(meetingID: meetingID)
            let queueRows = try await database.pool.read { db in
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM handoff_queue WHERE meeting_id = ?",
                    arguments: [meetingID]) ?? -1
            }
            var ftsOK = true
            do {
                try await database.pool.write { db in
                    try db.execute(
                        sql: "INSERT INTO transcript_fts(transcript_fts, rank) VALUES('integrity-check', 1)")
                }
            } catch {
                ftsOK = false
            }
            let payloadDir = database.paths.handoffDirectory(meetingID)
            let payloadFiles =
                (try? FileManager.default.contentsOfDirectory(atPath: payloadDir.path)
                    .filter { $0.hasSuffix(".json") }.sorted()) ?? []
            let state: [String: Any] = [
                "status": meeting.status.rawValue,
                "last_error": meeting.lastProcessingError ?? NSNull(),
                "processing_note": meeting.processingNote ?? NSNull(),
                "segment_count": segments.count,
                "named_segments": segments.filter { $0.speakerName != nil }.count,
                "queue_rows": queueRows,
                "fts_ok": ftsOK,
                "payload_files": payloadFiles,
                "audio_exists": FileManager.default.fileExists(
                    atPath: database.paths.audioURL(meetingID).path),
                "import_copy_exists": FileManager.default.fileExists(
                    atPath: database.paths.importCopyURL(meetingID).path),
            ]
            let data = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))

        case "handoff-seed":
            guard args.count >= 4, let count = Int(args[3]) else {
                fail("usage: CrashRunner handoff-seed <dataRoot> <count> [--payload-kb N]")
            }
            var payloadKB = 1
            if let flagIndex = args.firstIndex(of: "--payload-kb"), args.count > flagIndex + 1 {
                payloadKB = Int(args[flagIndex + 1]) ?? 1
            }
            let database = try BlaiseDatabase(rootURL: dataRoot)
            let meetings = MeetingRepository(database: database)
            let transcripts = TranscriptRepository(database: database)
            // ~90 bytes of canonical JSON per synthetic segment.
            let segmentCount = max(2, payloadKB * 1024 / 90)
            for index in 0 ..< count {
                let meetingID = ULID.generate()
                var meeting = makeSyntheticMeeting(id: meetingID, ordinal: index)
                meeting.status = .processing
                try await meetings.create(meeting)
                let segments = (0 ..< segmentCount).map { ord in
                    TranscriptSegment(
                        meetingID: meetingID, ord: ord,
                        startSeconds: Double(ord), endSeconds: Double(ord) + 0.9,
                        speakerLabel: "S\(ord % 2)", speakerName: ord % 2 == 0 ? "Demo User" : nil,
                        text: "segmento sintético \(ord) da reunião \(index) para o harness C8")
                }
                let stored = try await transcripts.replaceAllSegments(meetingID: meetingID, with: segments)
                let notes = makeSyntheticNotes(meetingID: meetingID, ordinal: index)
                meeting.status = .ready
                let payload = EvidencePayloadBuilder.build(
                    meeting: meeting, segments: stored, notes: notes,
                    user: UserIdentity.shippedDefault)
                let relativePath = database.paths.relativeHandoffPayloadPath(
                    meetingID: meetingID, versionHash: payload.versionHash)
                try ImmutablePayloadWriter.write(
                    payload.bytes, to: dataRoot.appendingPathComponent(relativePath))
                let item = try await database.finalizeMeetingProcessing(
                    meetingID: meetingID, versionHash: payload.versionHash,
                    payloadPath: relativePath, notes: notes)
                print("SEEDED seq=\(item.createdSeq) meeting=\(meetingID) hash=\(payload.versionHash) bytes=\(payload.bytes.count)")
            }

        case "handoff-drain":
            let database = try BlaiseDatabase(rootURL: dataRoot)
            let settings = SettingsStore(database: database)
            var index = 3
            while index < args.count {
                switch args[index] {
                case "--remote-root":
                    index += 1
                    try await settings.set(HandoffSettings.Key.remoteRoot, to: args[index])
                case "--hosts":
                    index += 1
                    try await settings.set(
                        HandoffSettings.Key.hosts, to: args[index].split(separator: ",").map(String.init))
                case "--user":
                    index += 1
                    try await settings.set(HandoffSettings.Key.user, to: args[index])
                case "--identity":
                    index += 1
                    try await settings.set(HandoffSettings.Key.identityFile, to: args[index])
                case "--local-root":
                    // G5: switch the active destination to a LOCAL folder.
                    // Persist a real security-scoped bookmark (works for a /tmp
                    // dir even though the app is not sandboxed) so the worker's
                    // HandoffDestination.load resolves it exactly as in prod.
                    index += 1
                    let folder = URL(fileURLWithPath: args[index], isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let bookmark = try folder.bookmarkData(
                        options: [.withSecurityScope], includingResourceValuesForKeys: nil,
                        relativeTo: nil)
                    try await settings.set(
                        HandoffDestination.Key.kind, to: HandoffDestination.Kind.localFolder)
                    try await settings.set(
                        HandoffDestination.Key.localBookmark, to: bookmark.base64EncodedString())
                    try await settings.set(HandoffDestination.Key.localPath, to: folder.path)
                default: fail("unknown flag \(args[index])")
                }
                index += 1
            }
            let worker = HandoffWorker(database: database)
            await worker.start()
            await worker.waitUntilSettled()
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            for record in await worker.deliveryHistory() {
                print("DELIVERED seq=\(record.createdSeq) meeting=\(record.meetingID) hash=\(record.versionHash) host=\(record.host) at=\(iso.string(from: record.deliveredAt))")
            }
            let snapshot = await worker.currentSnapshot()
            let summary: [String: Any] = [
                "state": snapshot.state.rawValue,
                "active_endpoint": snapshot.activeEndpoint ?? NSNull(),
                "pending_count": snapshot.pendingCount,
                "damaged_count": snapshot.damagedItems.count,
                "detail": snapshot.detail ?? NSNull(),
                "delivered_this_run": await worker.deliveryHistory().count,
            ]
            print(String(
                decoding: try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]),
                as: UTF8.self))

        case "handoff-queue":
            let database = try BlaiseDatabase(rootURL: dataRoot)
            let rows = try await HandoffRepository(database: database).allItems()
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            for row in rows {
                let json: [String: Any] = [
                    "seq": row.createdSeq,
                    "meeting": row.meetingID,
                    "hash": row.versionHash,
                    "state": row.state.rawValue,
                    "attempts": row.attempts,
                    "delivered_at": row.deliveredAt.map(iso.string(from:)) ?? NSNull(),
                    "last_error": row.lastError ?? NSNull(),
                ]
                print(String(
                    decoding: try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
                    as: UTF8.self))
            }

        case "capture":
            // C11 gated capture integration test (BLAISE_TEST_CAPTURE=1):
            // child process for the kill -9 variant. Creates the meeting
            // row, starts the REAL CaptureSession (requires the TCC grants
            // of the Touchpoint), prints the meeting id, then records until
            // killed — the parent SIGKILLs it mid-capture and asserts the
            // crash-safe CAFs + startup sweep rescue.
            let database = try BlaiseDatabase(rootURL: dataRoot)
            let controller = RecordingController(
                database: database, engine: CaptureSession(), processKicker: { _ in })
            let meeting = try await controller.start(source: .inPerson, title: "Capture kill test")
            // Unbuffered write(2), so the parent's pipe sees the line before
            // the kill window. NOT print(): stdio block-buffers under a
            // pipe, and `synchronizeFile()` on pipe-backed stdout throws an
            // uncatchable NSException ("Operation not supported").
            FileHandle.standardOutput.write(Data("CAPTURING \(meeting.id)\n".utf8))
            try await Task.sleep(for: .seconds(3600))

        default:
            fail("unknown mode \(mode)")
        }
    } catch {
        FileHandle.standardError.write(Data("run failed: \(error)\n".utf8))
        semaphore.signal()
        exit(1)
    }
}
semaphore.wait()
_ = task
exit(0)
