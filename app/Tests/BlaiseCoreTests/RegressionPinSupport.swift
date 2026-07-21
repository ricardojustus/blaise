import CryptoKit
import Foundation
import Testing
@testable import BlaiseCore

// Shared support for the C7 regression pin: Tier-1 deterministic chain,
// pinned-artifact serialization, word similarity, the real-engine pipeline
// builder, and the vocab near-miss scanner.

enum RegressionPin {
    static let repoRoot = VocabFixtures.repoRoot
    static var directory: URL { repoRoot.appendingPathComponent("fixtures/icsi_sample", isDirectory: true) }
    /// A maintainer-local path the public suite never touches: the gated
    /// real-engine tests skip-guard when the dir is absent, so a clean clone
    /// never reaches it. Overridable per-path via an env var (set in
    /// scripts/blaise.env for a private real-engine run); the default is a
    /// local, gitignored scratch dir under the repo root.
    private static func localEnvPath(_ envVar: String, default def: String) -> URL {
        let rel = ProcessInfo.processInfo.environment[envVar].flatMap { $0.isEmpty ? nil : $0 } ?? def
        return repoRoot.appendingPathComponent(rel, isDirectory: true)
    }
    /// Output dir for the maintainer's Tier-2 real-engine run records.
    static var auditsDir: URL { localEnvPath("BLAISE_TIER2_OUTPUT_DIR", default: ".tier2-runs") }
    /// The maintainer's real ASR Python virtualenv (real-engine integration tests).
    static var asrVenv: URL { localEnvPath("BLAISE_ASR_VENV", default: ".asr-venv") }
    /// The maintainer's real ASR engine-output / oracle directory.
    static var asrOutDir: URL { localEnvPath("BLAISE_ASR_OUT", default: ".asr-out") }
    /// The maintainer's persistent C6 notes-engine data root (provisioned venv).
    static var notesDataRoot: URL { localEnvPath("BLAISE_C6_DATAROOT", default: ".c6-notes-dataroot") }

    static var rawASRURL: URL { directory.appendingPathComponent("raw_asr.json") }
    static var diarizationURL: URL { directory.appendingPathComponent("diarization.json") }
    static var intermediateURL: URL { directory.appendingPathComponent("transcript_intermediate_pinned.json") }
    static var finalURL: URL { directory.appendingPathComponent("transcript_pinned.json") }
    static var manifestURL: URL { directory.appendingPathComponent("pin_manifest.json") }

    static func pinsExist() -> Bool {
        [rawASRURL, diarizationURL, intermediateURL, finalURL, manifestURL]
            .allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The fabricated attendee list for the full-sample run (the ICSI
    /// Bmr001 excerpt is an English meeting): an English fictional cast.
    /// Sam Rivera is the user identity; the other participants exist so the
    /// diarizer gets a sane speaker-count ceiling (file-first mixed track:
    /// attendees + 1, C4 v5.5).
    static let fabricatedAttendees: [Attendee] = [
        Attendee(name: "Sam Rivera", email: "sam.rivera@vexatron.test", source: .manual),
        Attendee(name: "Marco Vidal", email: nil, source: .manual),
        Attendee(name: "Leo Marston", email: nil, source: .manual),
        Attendee(name: "Anna Reyes", email: nil, source: .manual),
    ]

    static let sampleTitle = "ICSI Bmr001 excerpt (regression sample)"
}

// MARK: - Pinned artifact shapes

/// Pin-stable segment shape (no DB ids, no meeting ULIDs — runs mint fresh
/// ULIDs; byte-comparison must not depend on them).
struct PinnedSegment: Codable, Equatable {
    let ord: Int
    let startSeconds: Double
    let endSeconds: Double
    let speakerLabel: String
    let speakerName: String?
    let text: String

    enum CodingKeys: String, CodingKey {
        case ord, text
        case startSeconds = "start_seconds"
        case endSeconds = "end_seconds"
        case speakerLabel = "speaker_label"
        case speakerName = "speaker_name"
    }

    init(_ segment: TranscriptSegment) {
        self.ord = segment.ord
        self.startSeconds = segment.startSeconds
        self.endSeconds = segment.endSeconds
        self.speakerLabel = segment.speakerLabel
        self.speakerName = segment.speakerName
        self.text = segment.text
    }
}

func pinBytes<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    var data = try encoder.encode(value)
    data.append(0x0A)
    return data
}

/// `{provenance, payload}` — the committed raw_asr_full.json envelope.
struct RawASREnvelope: Decodable {
    let provenance: ASRProvenance
    let payload: WhisperDriverOutput

    static func load(from url: URL) throws -> RawASREnvelope {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RawASREnvelope.self, from: Data(contentsOf: url))
    }
}

// MARK: - Pin manifest

/// A clear, descriptive failure when the committed `pin_manifest.json` is
/// missing or malformed — surfaced instead of an opaque `DecodingError` so the
/// always-on Tier-1 test (which decodes this) reports *why* it failed.
struct PinManifestError: Error, CustomStringConvertible {
    let description: String
}

struct PinManifest: Codable {
    struct AudioInfo: Codable {
        let sampleRate: Int
        let channels: Int
        let bitsPerSample: Int
        let dataByteCount: Int
        let sha256: String

        enum CodingKeys: String, CodingKey {
            case sampleRate = "sample_rate"
            case channels
            case bitsPerSample = "bits_per_sample"
            case dataByteCount = "data_byte_count"
            case sha256
        }

        /// Exactly WAVHeader.Info's duration computation.
        var duration: Double {
            WAVHeader.Info(
                sampleRate: sampleRate, channels: channels,
                bitsPerSample: bitsPerSample, dataByteCount: dataByteCount
            ).duration
        }
    }

    // Required fields (decoded as non-optional; the manifest must carry them).
    var schemaVersion: Int
    var meetingID: String
    var pipelineVersion: String
    var dominantLanguage: String
    var audio: AudioInfo
    var asrProvenance: ASRProvenance
    var diarizationSpeakerCount: Int
    var intermediateSegmentCount: Int
    var finalSegmentCount: Int

    // Vestigial fields (OPTIONAL — omitted from the committed ICSI manifest;
    // kept decodable so an older manifest that still carries them round-trips).
    var tier2: PinManifestTier2?
    var attendeesNote: String?
    var privacyResolution: String?
    var namedSegmentCount: Int?
    var correctionCount: Int?

    enum CodingKeys: String, CodingKey {
        case audio, tier2
        case schemaVersion = "schema_version"
        case meetingID = "meeting_id"
        case pipelineVersion = "pipeline_version"
        case dominantLanguage = "dominant_language"
        case asrProvenance = "asr_provenance"
        case diarizationSpeakerCount = "diarization_speaker_count"
        case intermediateSegmentCount = "intermediate_segment_count"
        case finalSegmentCount = "final_segment_count"
        case namedSegmentCount = "named_segment_count"
        case correctionCount = "correction_count"
        case attendeesNote = "attendees_note"
        case privacyResolution = "privacy_resolution"
    }

    /// Decode + validate, translating a missing required field/file into a
    /// clear `PinManifestError` (which names the field/key) rather than an
    /// opaque decode crash.
    static func load() throws -> PinManifest {
        let data: Data
        do {
            data = try Data(contentsOf: RegressionPin.manifestURL)
        } catch {
            throw PinManifestError(
                description: "pin_manifest.json not found at \(RegressionPin.manifestURL.path): \(error)")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(PinManifest.self, from: data)
        } catch let DecodingError.keyNotFound(key, _) {
            throw PinManifestError(
                description: "pin_manifest.json is missing required field '\(key.stringValue)'")
        } catch let DecodingError.typeMismatch(_, context) {
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            throw PinManifestError(
                description: "pin_manifest.json field '\(path)' has the wrong type: \(context.debugDescription)")
        } catch let DecodingError.valueNotFound(_, context) {
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            throw PinManifestError(
                description: "pin_manifest.json field '\(path)' is null but required")
        } catch {
            throw PinManifestError(description: "pin_manifest.json failed to decode: \(error)")
        }
    }
}

/// Vestigial Tier-2 block (no longer written; kept decodable only).
struct PinManifestTier2: Codable {
    var mintedThreshold: Double?
    var anchorsPT: [String]?
    var anchorsEN: [String]?

    enum CodingKeys: String, CodingKey {
        case mintedThreshold = "minted_threshold"
        case anchorsPT = "anchors_pt"
        case anchorsEN = "anchors_en"
    }
}

// MARK: - Tier-1 deterministic chain

enum Tier1Chain {
    /// Committed inputs → normalizer → merge → correct, in-process — the
    /// deterministic stage chain the byte-pin guards (post-correct,
    /// pre-naming). `meetingID` only flows into TranscriptSegment rows and is
    /// erased by PinnedSegment.
    static func run(
        envelope: RawASREnvelope,
        diarization: DiarizationOutput,
        audioDuration: Double,
        vocabulary: PipelineVocabulary
    ) -> (segments: [TranscriptSegment], dominantLanguage: String) {
        let (normalized, _) = SegmentNormalizer.normalize(
            envelope.payload.asrSegments, audioDuration: audioDuration)
        let merged = SpeakerMerger.merge(
            asr: normalized, diarization: diarization.segments, meetingID: "01TIER1CHAINFIXEDMEETING00")
        var segments = merged.segments
        for index in segments.indices {
            segments[index].text = vocabulary.corrector.correct(segments[index].text).correctedText
        }
        return (segments, DominantLanguage.classify(segments: segments))
    }
}

// MARK: - Word similarity (Myers O(ND) over word tokens)

enum WordSimilarity {
    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// 2·LCS/(n+m) via Myers edit distance; bails once the distance bound
    /// proves the ratio below `floor` (returns that upper bound, which is
    /// below any acceptable threshold by construction).
    static func ratio(_ a: [String], _ b: [String], floor: Double = 0.9) -> Double {
        let n = a.count
        let m = b.count
        if n == 0 && m == 0 { return 1 }
        let total = n + m
        let maxD = min(total, Int((1.0 - floor) * Double(total)) + 1)
        var v = [Int](repeating: 0, count: 2 * maxD + 3)
        let offset = maxD + 1
        for d in 0 ... maxD {
            var k = -d
            while k <= d {
                var x: Int
                if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) {
                    x = v[offset + k + 1]
                } else {
                    x = v[offset + k - 1] + 1
                }
                var y = x - k
                while x < n && y < m && a[x] == b[y] {
                    x += 1
                    y += 1
                }
                v[offset + k] = x
                if x >= n && y >= m {
                    let lcs = (total - d) / 2
                    return 2.0 * Double(lcs) / Double(total)
                }
                k += 2
            }
        }
        // Bailed: distance > maxD ⇒ ratio < this bound < any threshold.
        return Double(total - maxD) / Double(total)
    }
}

// MARK: - Folded containment + Levenshtein (near-miss scan)

enum VocabScan {
    static func fold(_ text: String) -> String {
        VocabNormalization.canonicalMode(text)
    }

    static func foldedTokens(_ text: String) -> [String] {
        WordSimilarity.tokens(fold(text))
    }

    /// Occurrence count of `term` (folded, token-contiguous) in `tokens`.
    static func occurrences(of term: String, in tokens: [String]) -> Int {
        let needle = foldedTokens(term)
        guard !needle.isEmpty, tokens.count >= needle.count else { return 0 }
        var count = 0
        for start in 0 ... (tokens.count - needle.count) {
            if Array(tokens[start ..< start + needle.count]) == needle { count += 1 }
        }
        return count
    }

    static func levenshtein(_ a: String, _ b: String, cap: Int) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        if abs(aChars.count - bChars.count) > cap { return cap + 1 }
        var previous = Array(0 ... bChars.count)
        for i in 1 ... max(aChars.count, 1) where !aChars.isEmpty {
            var current = [i] + [Int](repeating: 0, count: bChars.count)
            var rowMin = i
            for j in 1 ... max(bChars.count, 1) where !bChars.isEmpty {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                rowMin = min(rowMin, current[j])
            }
            if rowMin > cap { return cap + 1 }
            previous = current
        }
        return previous[bChars.count]
    }

    struct NearMiss: Codable {
        let term: String
        let surface: String
        let distance: Int
        let count: Int
        let termInCorrected: Bool
    }

    /// Folded fuzzy grep, distance ≤ 2, of every vocab term (canonicals AND
    /// aliases) against the raw ASR token stream; reports surfaces that are
    /// NOT the term itself. Independent check against transcript-mediated
    /// circularity (terms mangled beyond recognition stay invisible — stated).
    static func nearMissScan(
        vocabulary: PipelineVocabulary, rawTokens: [String], correctedTokens: [String]
    ) -> [NearMiss] {
        var terms: [String] = []
        for entry in vocabulary.dictionary.entries {
            terms.append(entry.canonical)
            terms.append(contentsOf: entry.aliases)
        }
        var results: [NearMiss] = []
        for term in terms {
            let needle = foldedTokens(term)
            guard !needle.isEmpty else { continue }
            let needleJoined = needle.joined(separator: " ")
            guard needleJoined.count >= 3 else { continue }  // 1–2 char terms: pure noise at d≤2
            let window = needle.count
            guard rawTokens.count >= window else { continue }
            var surfaces: [String: Int] = [:]
            for start in 0 ... (rawTokens.count - window) {
                let candidate = rawTokens[start ..< start + window].joined(separator: " ")
                guard candidate != needleJoined else { continue }
                if levenshtein(candidate, needleJoined, cap: 2) <= 2 {
                    surfaces[candidate, default: 0] += 1
                }
            }
            guard !surfaces.isEmpty else { continue }
            let termPresent = occurrences(of: term, in: correctedTokens) > 0
            for (surface, count) in surfaces.sorted(by: { $0.value > $1.value }) {
                results.append(
                    NearMiss(
                        term: term, surface: surface, distance:
                            levenshtein(surface, needleJoined, cap: 2),
                        count: count, termInCorrected: termPresent))
            }
        }
        return results
    }
}

// MARK: - Notes structural comparison (Tier-2 / mint)

enum NotesStructuralCheck {
    /// Violations list (empty = pass): all five sections render, language
    /// matches the classifier output, owners ⊆ attendees ∪ final-transcript
    /// speaker names ∪ user identity (C7 spec M-1 definition).
    static func findings(
        notes: MeetingNotes,
        dominantLanguage: String,
        attendees: [Attendee],
        segments: [TranscriptSegment],
        user: UserIdentity
    ) -> [String] {
        var findings: [String] = []
        // G3 name-driven rendering: NotesRenderer uses the FULL user name
        // verbatim — PT user section is "Ações de <name>", EN is the
        // possessive "<name>'s action items". The literals are derived from
        // the SAME `user` passed here so the check matches whatever the
        // renderer produced for that identity (no first-name guessing).
        let userName = user.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let headings = dominantLanguage.hasPrefix("pt")
            ? ["## Resumo", "## Notas detalhadas", "## Decisões", "## Itens de ação", "## Ações de \(userName)"]
            : ["## Summary", "## Detailed notes", "## Decisions", "## Action items", "## \(userName)'s action items"]
        for heading in headings where !notes.markdown.contains(heading) {
            findings.append("missing section heading: \(heading)")
        }
        if notes.language != dominantLanguage {
            findings.append("notes.language \(notes.language) != dominantLanguage \(dominantLanguage)")
        }
        let notesText = notes.structured.summary + " " + notes.structured.detailedNotes
        let notesLanguage = DominantLanguage.classify(text: notesText)
        if notesLanguage != dominantLanguage {
            findings.append("notes content classifies as \(notesLanguage), expected \(dominantLanguage)")
        }
        var allowed = Set(attendees.map { VocabScan.fold($0.name) })
        allowed.formUnion(segments.compactMap { $0.speakerName.map(VocabScan.fold) })
        allowed.insert(VocabScan.fold(user.name))
        allowed.formUnion(user.aliases.map(VocabScan.fold))
        for item in notes.structured.actionItems + notes.structured.userActionItems {
            if !allowed.contains(VocabScan.fold(item.owner)) {
                findings.append("owner not in attendees ∪ speaker names ∪ user identity: \(item.owner)")
            }
        }
        return findings
    }
}

// MARK: - Real-engine pipeline builder (Tier-2 / mint / regeneration ACs)

private let researchVenv = RegressionPin.asrVenv
private let realHFHome = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".cache/huggingface", isDirectory: true)
private let fluidAudioModelsParent = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/FluidAudio/Models", isDirectory: true)
private let c6NotesDataRoot = RegressionPin.notesDataRoot

struct RealPipelineStack {
    let dataRoot: URL
    let database: BlaiseDatabase
    let pipeline: ProcessingPipeline
    let settings: SettingsStore
}

/// True iff every real stack the full pipeline needs is on this machine.
func realStacksPresent() -> Bool {
    guard FileManager.default.isExecutableFile(atPath: researchVenv.appendingPathComponent("bin/python").path),
        WhisperModelCache(hfHome: realHFHome).integrity(),
        FluidAudioDiarizer.modelsPresent(
            at: fluidAudioModelsParent.appendingPathComponent(FluidAudioDiarizer.repoFolderName, isDirectory: true)),
        let requirements = MLXWhisperEngine.bundledRequirementsFile(),
        let requirementsData = try? Data(contentsOf: requirements)
    else { return false }
    guard VenvLayout.isProvisioned(
        venvDir: VenvLayout(dataRoot: c6NotesDataRoot).venvDir, requirementsData: requirementsData)
    else { return false }
    return WhisperModelCache(
        hfHome: realHFHome, repo: MLXSummarizationEngine.modelRepo,
        markerName: MLXSummarizationEngine.suspectMarkerName
    ).integrity()
}

/// The app's composition-root shape with this machine's seams: research venv
/// + real HF cache for whisper/gemma, the machine FluidAudio model cache,
/// shipped engine DEFAULTS left in place (cloud notes default → no key →
/// configurationMissing → local fallback: exactly the production path today).
func makeRealPipelineStack(dataRoot: URL? = nil) async throws -> RealPipelineStack {
    let root = try dataRoot ?? makeTempRoot()
    let database = try BlaiseDatabase(rootURL: root)
    let settings = SettingsStore(database: database)
    let secrets = InMemorySecretStore()

    // Identity fix: an EXPLICIT fictional identity so the notes renderer emits
    // a named user action-items heading ("Sam Rivera's action items") that
    // NotesStructuralCheck can match — the shipped default is the empty
    // identity, which would render the neutral "My action items" and never
    // match the check's expected named heading.
    try await settings.set(
        UserIdentity.settingsKey,
        to: UserIdentity(name: "Sam Rivera", aliases: ["Sam"], email: "sam.rivera@vexatron.test"))

    func config(_ engineID: String, _ descriptors: [EngineConfigDescriptor]) -> EngineConfiguration {
        EngineConfiguration(engineID: engineID, descriptors: descriptors, settings: settings, secrets: secrets)
    }

    try await settings.set(
        "engine.\(MLXWhisperEngine.engineID).\(MLXWhisperEngine.venvPathKey)", to: researchVenv.path)
    try await settings.set(
        "engine.\(MLXWhisperEngine.engineID).\(MLXWhisperEngine.hfHomePathKey)", to: realHFHome.path)
    try await settings.set(
        "engine.\(FluidAudioParakeetEngine.engineID).\(FluidAudioParakeetEngine.modelsPathKey)",
        to: fluidAudioModelsParent.path)
    try await settings.set(
        "engine.\(FluidAudioDiarizer.diarizerID).\(FluidAudioDiarizer.modelsPathKey)",
        to: fluidAudioModelsParent.path)
    try await settings.set(
        "engine.\(MLXSummarizationEngine.engineID).\(MLXSummarizationEngine.hfHomePathKey)",
        to: realHFHome.path)

    let whisper = MLXWhisperEngine(
        configuration: config(MLXWhisperEngine.engineID, MLXWhisperEngine.descriptors),
        dataRoot: root,
        uvBinary: RegressionPin.repoRoot.appendingPathComponent("vendor/uv/uv"),
        driverScript: try #require(MLXWhisperEngine.bundledDriverScript()),
        requirementsFile: try #require(MLXWhisperEngine.bundledRequirementsFile()),
        sweepOrphansOnInit: false)
    let parakeet = FluidAudioParakeetEngine(
        configuration: config(FluidAudioParakeetEngine.engineID, FluidAudioParakeetEngine.descriptors),
        dataRoot: root)
    let diarizer = FluidAudioDiarizer(
        configuration: config(FluidAudioDiarizer.diarizerID, FluidAudioDiarizer.descriptors),
        dataRoot: root)
    // Gemma runs against the persistent provisioned C6 dataRoot (venv +
    // shared lock live there); its model cache is the hfHome override above.
    let gemma = MLXSummarizationEngine(
        configuration: config(MLXSummarizationEngine.engineID, MLXSummarizationEngine.descriptors),
        dataRoot: c6NotesDataRoot,
        uvBinary: RegressionPin.repoRoot.appendingPathComponent("vendor/uv/uv"),
        driverScript: try #require(MLXSummarizationEngine.bundledDriverScript()),
        requirementsFile: try #require(MLXWhisperEngine.bundledRequirementsFile()),
        sweepOrphansOnInit: false)
    let claude = ClaudeSummarizationEngine(
        configuration: config(ClaudeSummarizationEngine.engineID, ClaudeSummarizationEngine.descriptors),
        ledger: CloudSpendLedger(database: database))

    let registry = try EngineRegistry(asr: [whisper, parakeet], summarization: [gemma, claude])
    let pipeline = ProcessingPipeline(
        database: database,
        registry: registry,
        diarizer: diarizer,
        vocabulary: try VocabFixtures.pipelineVocabulary())
    return RealPipelineStack(dataRoot: root, database: database, pipeline: pipeline, settings: settings)
}

// MARK: - ICSI regression-pin mint (gated, one-time)

/// One-time mint of the five committed ICSI regression pins
/// (`fixtures/icsi_sample/{raw_asr,diarization,transcript_intermediate_pinned,
/// transcript_pinned,pin_manifest}.json`). Runs ASR + diarization ONCE over the
/// committed CC-BY ICSI Bmr001 5-minute excerpt, freezes the two nondeterministic
/// inputs (raw ASR + diarization) and the final transcript export, byte-pins the
/// deterministic Tier-1 transform over the frozen inputs, and writes a manifest the
/// always-on Tier-1 byte-pin test decodes. HEAVY: provisions the shared Whisper
/// venv and runs a full Whisper pass — gated behind `BLAISE_MINT_ICSI=1`, never CI.
func mintICSIRegressionPins() async throws {
    // --- a. Provision the shared Whisper venv (no-op if already provisioned) ---
    // A throwaway database backs the SettingsStore the provisioning engine reads
    // its venv/hfHome overrides from — the SAME wiring makeRealPipelineStack uses,
    // pointed at the persistent C6 dataRoot so the shared venv/lock live there.
    let provisionRoot = try makeTempRoot()
    let provisionDB = try BlaiseDatabase(rootURL: provisionRoot)
    let provisionSettings = SettingsStore(database: provisionDB)
    try await provisionSettings.set(
        "engine.\(MLXWhisperEngine.engineID).\(MLXWhisperEngine.venvPathKey)", to: researchVenv.path)
    try await provisionSettings.set(
        "engine.\(MLXWhisperEngine.engineID).\(MLXWhisperEngine.hfHomePathKey)", to: realHFHome.path)
    let whisper = MLXWhisperEngine(
        configuration: EngineConfiguration(
            engineID: MLXWhisperEngine.engineID,
            descriptors: MLXWhisperEngine.descriptors,
            settings: provisionSettings,
            secrets: InMemorySecretStore()),
        dataRoot: c6NotesDataRoot,
        uvBinary: RegressionPin.repoRoot.appendingPathComponent("vendor/uv/uv"),
        driverScript: try #require(MLXWhisperEngine.bundledDriverScript()),
        requirementsFile: try #require(MLXWhisperEngine.bundledRequirementsFile()))
    try await whisper.prepare()

    // --- b. Run the full pipeline ON THE ICSI CLIP (Whisper default; English) ---
    let sampleURL = VocabFixtures.fixture("icsi_sample/Bmr001_excerpt_5min.wav")
    let stack = try await makeRealPipelineStack()
    let meeting = try await stack.pipeline.importMeeting(
        sourceURL: sampleURL,
        title: RegressionPin.sampleTitle,
        attendees: RegressionPin.fabricatedAttendees)
    let record = try await stack.pipeline.process(meetingID: meeting.id)
    let paths = stack.database.paths

    // --- c. Capture the frozen inputs + the final transcript export ---
    try FileManager.default.createDirectory(
        at: RegressionPin.directory, withIntermediateDirectories: true)
    func copyOverwriting(_ source: URL, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }
    try copyOverwriting(paths.rawASRURL(meeting.id), to: RegressionPin.rawASRURL)
    try copyOverwriting(paths.diarizationURL(meeting.id), to: RegressionPin.diarizationURL)
    try copyOverwriting(paths.transcriptURL(meeting.id), to: RegressionPin.finalURL)
    // X2: normalize the final transcript's meeting_id to the corpus id so all
    // pins agree (the per-mint runtime ULID is synthetic; the byte-pin ignores
    // meeting ids entirely — PinnedSegment strips them). pin_manifest already
    // uses "Bmr001"; this keeps transcript_pinned consistent across re-mints.
    let normalizedFinal = try String(contentsOf: RegressionPin.finalURL, encoding: .utf8)
        .replacingOccurrences(of: meeting.id, with: "Bmr001")
    try normalizedFinal.write(to: RegressionPin.finalURL, atomically: true, encoding: .utf8)

    // --- d. Byte-pin the deterministic Tier-1 transform over the FROZEN inputs ---
    let audioInfo = try WAVHeader.read(at: sampleURL)
    let envelope = try RawASREnvelope.load(from: RegressionPin.rawASRURL)
    let diarization = try JSONDecoder().decode(
        DiarizationOutput.self, from: Data(contentsOf: RegressionPin.diarizationURL))
    let (segments, dominantLanguage) = Tier1Chain.run(
        envelope: envelope,
        diarization: diarization,
        audioDuration: audioInfo.duration,
        vocabulary: try VocabFixtures.pipelineVocabulary())
    try pinBytes(segments.map(PinnedSegment.init)).write(to: RegressionPin.intermediateURL)

    // --- e. Write pin_manifest.json (all required fields; vestigial fields nil) ---
    let wavBytes = try Data(contentsOf: sampleURL)
    let sha256 = SHA256.hash(data: wavBytes).map { String(format: "%02x", $0) }.joined()
    let distinctSpeakers = Set(diarization.segments.map(\.speakerLabel)).count
    let manifest = PinManifest(
        schemaVersion: 1,
        meetingID: "Bmr001",
        pipelineVersion: PipelineVersion.current,
        dominantLanguage: dominantLanguage,
        audio: PinManifest.AudioInfo(
            sampleRate: audioInfo.sampleRate,
            channels: audioInfo.channels,
            bitsPerSample: audioInfo.bitsPerSample,
            dataByteCount: audioInfo.dataByteCount,
            sha256: sha256),
        asrProvenance: envelope.provenance,
        diarizationSpeakerCount: distinctSpeakers,
        intermediateSegmentCount: segments.count,
        finalSegmentCount: record.finalSegmentCount,
        tier2: nil,
        attendeesNote: nil,
        privacyResolution: nil,
        namedSegmentCount: nil,
        correctionCount: nil)
    let manifestEncoder = JSONEncoder()
    manifestEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    manifestEncoder.dateEncodingStrategy = .iso8601
    try manifestEncoder.encode(manifest).write(to: RegressionPin.manifestURL)

    // --- f. Summary ---
    print("""
        [mint-icsi] wrote 5 pins to \(RegressionPin.directory.path):
          raw_asr.json                          \(RegressionPin.rawASRURL.lastPathComponent)
          diarization.json                      (\(distinctSpeakers) speakers, \(diarization.segments.count) turns)
          transcript_intermediate_pinned.json   (\(segments.count) segments, dominant=\(dominantLanguage))
          transcript_pinned.json                (\(record.finalSegmentCount) final segments)
          pin_manifest.json                     (schemaVersion=1, pipeline=\(PipelineVersion.current))
        """)
}
