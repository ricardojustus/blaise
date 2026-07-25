import Foundation
import Synchronization
@testable import BlaiseCore

// C7 unit-test support: configurable mock engines/diarizer for stage
// sequencing + failure-path tests, a tiny WAV generator (so ingest/transcode
// run real AVFoundation work fast), and the pipeline harness builder.

// MARK: - Tiny WAV generator (16 kHz mono Int16, sine)

func writeTestWAV(to url: URL, seconds: Double = 2.0, sampleRate: Int = 16_000) throws {
    let frames = Int(seconds * Double(sampleRate))
    var samples = [Int16]()
    samples.reserveCapacity(frames)
    for n in 0 ..< frames {
        let t = Double(n) / Double(sampleRate)
        samples.append(Int16(8_000 * sin(2 * .pi * 440 * t)))
    }
    var data = Data()
    func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    let dataBytes = UInt32(frames * 2)
    data.append(contentsOf: Array("RIFF".utf8))
    le32(36 + dataBytes)
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8))
    le32(16)
    le16(1)  // PCM
    le16(1)  // mono
    le32(UInt32(sampleRate))
    le32(UInt32(sampleRate * 2))  // byte rate
    le16(2)  // block align
    le16(16)  // bits
    data.append(contentsOf: Array("data".utf8))
    le32(dataBytes)
    samples.withUnsafeBytes { data.append(contentsOf: $0) }
    try data.write(to: url)
}

// MARK: - Configurable mocks

/// Default mock transcript: PT text with word timings, a verbatim "Fábio"
/// mention (passes apply()'s transcript-verbatim rule: outside the
/// suppression top-3000, in br_common_names), spanning two diarization turns.
enum PipelineMockData {
    static let segments: [ASRSegment] = [
        ASRSegment(
            startSeconds: 0.0, endSeconds: 0.9, text: "Olá, vamos começar.",
            words: [
                ASRWord(word: "Olá,", startSeconds: 0.0, endSeconds: 0.3),
                ASRWord(word: "vamos", startSeconds: 0.35, endSeconds: 0.6),
                ASRWord(word: "começar.", startSeconds: 0.65, endSeconds: 0.9),
            ]),
        ASRSegment(
            startSeconds: 1.0, endSeconds: 1.9, text: "O Fábio vai mandar o contrato.",
            words: [
                ASRWord(word: "O", startSeconds: 1.0, endSeconds: 1.05),
                ASRWord(word: "Fábio", startSeconds: 1.1, endSeconds: 1.3),
                ASRWord(word: "vai", startSeconds: 1.35, endSeconds: 1.45),
                ASRWord(word: "mandar", startSeconds: 1.5, endSeconds: 1.65),
                ASRWord(word: "o", startSeconds: 1.7, endSeconds: 1.72),
                ASRWord(word: "contrato.", startSeconds: 1.75, endSeconds: 1.9),
            ]),
    ]

    /// Default mic-track transcript for two-track captured runs: the user's
    /// GENUINE words, deliberately different from the system text — two
    /// tracks never carry identical ASR in reality, and the cross-track echo
    /// suppressor (C7 v3.7) must have nothing to drop in the default
    /// harness. Overlaps the system span (talking over) to exercise the
    /// keep-on-different-text path on every two-track run.
    static let micSegments: [ASRSegment] = [
        ASRSegment(
            startSeconds: 1.2, endSeconds: 2.4,
            text: "Perfeito, eu reviso isso ainda hoje à tarde.")
    ]

    static let diarization = DiarizationOutput(
        segments: [
            DiarizedSegment(speakerLabel: "S0", startSeconds: 0.0, endSeconds: 0.95),
            DiarizedSegment(speakerLabel: "S1", startSeconds: 0.98, endSeconds: 1.9),
        ],
        speakerCount: 2)

    static func notesResult(
        engine: String,
        summary: String = "Resumo da reunião de teste.",
        actionOwner: String = "Fábio",
        mapping: [SpeakerNameProposal] = [],
        notesTitle: String? = "Notas"
    ) -> NotesResult {
        NotesResult(
            structured: NotesStructured(
                title: notesTitle,
                summary: summary,
                detailedNotes: "Discussão sobre o contrato.",
                decisions: ["Fábio manda o contrato"],
                actionItems: [ActionItem(owner: actionOwner, text: "mandar o contrato")],
                userActionItems: []),
            usage: EngineUsage(inputUnits: 10, outputUnits: 5),
            provenance: NotesProvenance(
                engine: engine, model: "mock-model", pipelineVersion: "",
                runtime: "mock-runtime", rendererVersion: "", promptVersion: "test-v1"),
            speakerNameMapping: mapping)
    }
}

final class PipelineMockASR: ASREngine, @unchecked Sendable {
    let id: String
    let displayName = "Pipeline Mock ASR"
    let kind: EngineKind = .local
    let costDescriptor: EngineCostDescriptor? = nil
    let configDescriptors: [EngineConfigDescriptor] = []

    struct State {
        var segments = PipelineMockData.segments
        /// Returned for mic-track requests (temp WAV with the "-mic-" infix,
        /// the same convention the captured-variant tests already key on).
        var micSegments = PipelineMockData.micSegments
        var detectedLanguage: String? = "pt"
        var availability: EngineAvailability = .available
        var transcribeError: EngineError?
        var prepareError: EngineError?
        var transcribeDelaySeconds: Double = 0
        var requests: [ASRRequest] = []
        var onTranscribe: (@Sendable () async -> Void)?
    }

    let state: Mutex<State>

    init(id: String = "pipeline-mock-asr") {
        self.id = id
        self.state = Mutex(State())
    }

    func availability() async -> EngineAvailability {
        state.withLock { $0.availability }
    }

    func prepare() async throws {
        if let error = state.withLock({ $0.prepareError }) { throw error }
    }

    func transcribe(_ request: ASRRequest) async throws -> ASRResult {
        if let hook = state.withLock({ $0.onTranscribe }) { await hook() }
        let delay = state.withLock { $0.transcribeDelaySeconds }
        if delay > 0 {
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                throw EngineError.cancelled
            }
        }
        if Task.isCancelled { throw EngineError.cancelled }
        if let error = state.withLock({ $0.transcribeError }) { throw error }
        let isMicTrack = request.audioURL.lastPathComponent.contains("-mic-")
        let (segments, detected) = state.withLock { state in
            state.requests.append(request)
            return (isMicTrack ? state.micSegments : state.segments, state.detectedLanguage)
        }
        return ASRResult(
            segments: segments,
            detectedLanguage: detected,
            rawPayload: Data(#"{"mock":true}"#.utf8),
            provenance: ASRProvenance(
                engine: id, model: "mock-model", runtime: "mock-runtime",
                engineVersion: "1", transcribedAt: msDate()))
    }
}

final class PipelineMockDiarizer: Diarizing, @unchecked Sendable {
    struct State {
        var output = PipelineMockData.diarization
        var error: EngineError?
        var attendeeCounts: [Int?] = []
    }

    let state = Mutex(State())

    func prepare() async throws {}
    func availability() async -> EngineAvailability { .available }

    func diarize(audioURL: URL, attendeeCount: Int?) async throws -> DiarizationOutput {
        try state.withLock { state in
            state.attendeeCounts.append(attendeeCount)
            if let error = state.error { throw error }
            return state.output
        }
    }
}

final class PipelineMockNotes: SummarizationEngine, @unchecked Sendable {
    let id: String
    let displayName = "Pipeline Mock Notes"
    let kind: EngineKind
    let loadProfile: EngineLoadProfile
    let costDescriptor: EngineCostDescriptor? = nil
    let configDescriptors: [EngineConfigDescriptor] = []

    /// Decision B: read-through of the scriptable State flag (defaults to the
    /// protocol's `false`; a test flips it to model the subscription engine).
    var suppressesAutoFallback: Bool { state.withLock { $0.suppressesAutoFallback } }

    struct State {
        var error: EngineError?
        var prepareError: EngineError?
        /// Decision B: when true, this engine reports `suppressesAutoFallback` and
        /// the pipeline must leave a fallback-trigger failure notes-PENDING rather
        /// than hop to the registered fallback (the subscription-engine policy).
        var suppressesAutoFallback = false
        var summary = "Resumo da reunião de teste."
        var actionOwner = "Fábio"
        var mapping: [SpeakerNameProposal] = []
        /// G12: the `NotesStructured.title` the mock returns — the field the
        /// LLM-title promotion reuses. `nil`/empty exercises the non-null gate.
        var notesTitle: String? = "Notas"
        var requests: [NotesRequest] = []
        /// G7 AC3: the purpose the pipeline threaded into each call, in order.
        var purposes: [CloudSpendPurpose] = []
        var prepareCalls = 0
        /// Interleaving seam (mirrors PipelineMockASR.onTranscribe): awaited
        /// at the top of every generateNotes call.
        var onGenerate: (@Sendable () async -> Void)?
        /// Interleaving seam awaited at the top of every prepare() call — the
        /// run parks here, just before the pipeline's cancel-token boundary
        /// check (M-1 order pin).
        var onPrepare: (@Sendable () async -> Void)?

        // G14 digest seam.
        /// The digest string the engine returns (when no error/transient
        /// script is set). A `{digest}` token in this string is replaced with a
        /// label seeded from the request, used to prove neutralization.
        var digestString = "## HEADER\nmeeting: reunião de teste\nspeaker: (none resolved)\n"
        /// A `@Sendable` digest builder; when set it OVERRIDES `digestString`
        /// (lets a test honor the drop rule from the input).
        var digestBuilder: (@Sendable (DigestRequest) -> String)?
        /// Throw this error on every digest call (AC5c persistent failure).
        var digestError: EngineError?
        /// Throw a transient error the first N digest calls, then succeed (the
        /// bounded-retry / transient-then-success path).
        var digestTransientFailCount = 0
        /// The digest requests this engine saw, in order (count + content).
        var digestRequests: [DigestRequest] = []
        /// The purpose the pipeline threaded into each digest call, in order.
        var digestPurposes: [CloudSpendPurpose] = []
        private(set) var digestAttempts = 0

        mutating func nextDigestAttempt() -> Int { digestAttempts += 1; return digestAttempts }
    }

    let state: Mutex<State>

    init(id: String, kind: EngineKind = .local, loadProfile: EngineLoadProfile = .lightweight) {
        self.id = id
        self.kind = kind
        self.loadProfile = loadProfile
        self.state = Mutex(State())
    }

    func availability() async -> EngineAvailability { .available }

    func prepare() async throws {
        if let hook = state.withLock({ $0.onPrepare }) { await hook() }
        let error = state.withLock { state -> EngineError? in
            state.prepareCalls += 1
            return state.prepareError
        }
        if let error { throw error }
    }

    func generateNotes(_ request: NotesRequest, purpose: CloudSpendPurpose) async throws -> NotesResult {
        if let hook = state.withLock({ $0.onGenerate }) { await hook() }
        let (error, summary, owner, mapping, notesTitle) = state.withLock {
            state -> (EngineError?, String, String, [SpeakerNameProposal], String?) in
            state.requests.append(request)
            state.purposes.append(purpose)
            return (state.error, state.summary, state.actionOwner, state.mapping, state.notesTitle)
        }
        if let error { throw error }
        return PipelineMockData.notesResult(
            engine: id, summary: summary, actionOwner: owner, mapping: mapping,
            notesTitle: notesTitle)
    }

    func generateDigest(_ request: DigestRequest, purpose: CloudSpendPurpose) async throws -> DigestResult {
        if let hook = state.withLock({ $0.onGenerate }) { await hook() }
        enum Outcome { case fail(EngineError); case ok(String) }
        let outcome = state.withLock { state -> Outcome in
            state.digestRequests.append(request)
            state.digestPurposes.append(purpose)
            let attempt = state.nextDigestAttempt()
            if let error = state.digestError { return .fail(error) }
            if attempt <= state.digestTransientFailCount {
                return .fail(.transient("mock transient digest failure attempt \(attempt)"))
            }
            let value = state.digestBuilder.map { $0(request) } ?? state.digestString
            return .ok(value)
        }
        switch outcome {
        case .fail(let error): throw error
        case .ok(let digest):
            return DigestResult(
                digest: digest,
                usage: EngineUsage(inputUnits: 80, outputUnits: 40, estimatedCostUSD: nil),
                promptVersion: DigestPromptBuilder.shippedVersion.rawValue)
        }
    }
}

// MARK: - Harness

struct PipelineHarness {
    let dataRoot: URL
    let tempDir: URL
    let database: BlaiseDatabase
    let pipeline: ProcessingPipeline
    let asr: PipelineMockASR
    let diarizer: PipelineMockDiarizer
    let notesPrimary: PipelineMockNotes
    let notesFallback: PipelineMockNotes

    /// Imports a freshly generated 2 s WAV and returns the meeting.
    func importTestMeeting(
        attendees: [Attendee] = [Attendee(name: "Sam", email: "sam.rivera@vexatron.test", source: .manual)]
    ) async throws -> Meeting {
        let wav = dataRoot.appendingPathComponent("source-\(UUID().uuidString).wav")
        try writeTestWAV(to: wav)
        return try await pipeline.importMeeting(
            sourceURL: wav, title: "Reunião de teste", startedAt: msDate(), attendees: attendees)
    }

    func meeting(_ id: MeetingID) async throws -> Meeting? {
        try await MeetingRepository(database: database).fetch(id)
    }

    func segments(_ id: MeetingID) async throws -> [TranscriptSegment] {
        try await TranscriptRepository(database: database).segments(meetingID: id)
    }

    func queueRows(_ id: MeetingID) async throws -> Int {
        try await database.pool.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM handoff_queue WHERE meeting_id = ?",
                arguments: [id]) ?? -1
        }
    }
}

func makePipelineHarness(
    registerFallbackEngine: Bool = true,
    primaryLoadProfile: EngineLoadProfile = .lightweight,
    fallbackLoadProfile: EngineLoadProfile = .lightweight,
    vocabularyProvider: (@Sendable () -> PipelineVocabulary.UserLoad)? = nil,
    handoffKicker: (any HandoffKicking)? = nil,
    now: @escaping @Sendable () -> Date = { msDate() },
    duringParticipantParkCommit: (@Sendable (MeetingID) async -> Void)? = nil
) async throws -> PipelineHarness {
    let dataRoot = try makeTempRoot()
    let tempDir = dataRoot.appendingPathComponent("pipeline-tmp", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    let database = try BlaiseDatabase(rootURL: dataRoot)
    let asr = PipelineMockASR()
    let diarizer = PipelineMockDiarizer()
    let primary = PipelineMockNotes(
        id: "pipeline-mock-notes-primary", loadProfile: primaryLoadProfile)
    let fallback = PipelineMockNotes(
        id: "pipeline-mock-notes-fallback", loadProfile: fallbackLoadProfile)
    let registry = try EngineRegistry(
        asr: [asr],
        summarization: registerFallbackEngine ? [primary, fallback] : [primary])
    let settings = SettingsStore(database: database)
    try await settings.set(EngineResolver.asrSettingsKey, to: asr.id)
    try await settings.set(EngineResolver.summarizationSettingsKey, to: primary.id)
    // G3: the shipped default identity is now empty; the pipeline tests assume
    // an onboarded "Sam" (mic-track naming, user action-items). Seed it.
    try await settings.set(
        UserIdentity.settingsKey,
        to: UserIdentity(
            name: "Sam", aliases: ["Sam", "Sam Rivera"], email: "sam.rivera@vexatron.test"))
    let kicker: any HandoffKicking = handoffKicker ?? NoopHandoffKicker()
    let pipeline: ProcessingPipeline
    if let vocabularyProvider {
        pipeline = ProcessingPipeline(
            database: database,
            registry: registry,
            diarizer: diarizer,
            vocabularyProvider: vocabularyProvider,
            handoffKicker: kicker,
            tempDirectory: tempDir,
            now: now,
            duringParticipantParkCommit: duringParticipantParkCommit)
    } else {
        pipeline = ProcessingPipeline(
            database: database,
            registry: registry,
            diarizer: diarizer,
            vocabulary: try VocabFixtures.pipelineVocabulary(),
            handoffKicker: kicker,
            tempDirectory: tempDir,
            now: now,
            duringParticipantParkCommit: duringParticipantParkCommit)
    }
    return PipelineHarness(
        dataRoot: dataRoot, tempDir: tempDir, database: database, pipeline: pipeline,
        asr: asr, diarizer: diarizer, notesPrimary: primary, notesFallback: fallback)
}

extension PipelineError {
    var taggedDescription: String { "\(stage.rawValue): \(message)" }
}
