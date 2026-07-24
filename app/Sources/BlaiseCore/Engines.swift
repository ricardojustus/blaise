import Foundation

// The two engine seams mandated by the product requirements (ASR and
// summarization) as plain async request/response protocols. Pure types +
// protocols; concrete engines arrive in C3/C6 and register at the
// composition root. Engine identity = model + runtime (decision D5);
// provenance must reconstruct "what produced this".

// MARK: - ASR types

public struct ASRSegment: Codable, Sendable, Equatable {
    public var startSeconds: Double
    public var endSeconds: Double
    public var text: String
    /// Word-level timings (C2 amendment, additive; decode-default nil).
    /// C4 dependency: speaker-change splitting inside segments.
    public var words: [ASRWord]?

    public init(startSeconds: Double, endSeconds: Double, text: String, words: [ASRWord]? = nil) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
        self.words = words
    }

    enum CodingKeys: String, CodingKey {
        case text, words
        case startSeconds = "start_seconds"
        case endSeconds = "end_seconds"
    }
}

public struct ASRWord: Codable, Sendable, Equatable {
    public var word: String
    public var startSeconds: Double
    public var endSeconds: Double

    public init(word: String, startSeconds: Double, endSeconds: Double) {
        self.word = word
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }

    enum CodingKeys: String, CodingKey {
        case word
        case startSeconds = "start_seconds"
        case endSeconds = "end_seconds"
    }
}

/// Hints contract: `vocabularyHints` are engine-level *biasing* only (Apple
/// `contextualStrings` etc.); engines that can't use them ignore them. The
/// C5 correction layer remains the authoritative post-pass; double-correction
/// is safe because C5 matches against canonical forms and is idempotent on
/// already-correct text. `ASRProvenance` records what was passed.
public struct ASRRequest: Codable, Sendable, Equatable {
    /// 16 kHz mono WAV; C7 owns transcoding.
    public var audioURL: URL
    public var vocabularyHints: [String]
    /// BCP-47; nil = auto-detect.
    public var languageHint: String?

    public init(audioURL: URL, vocabularyHints: [String] = [], languageHint: String? = nil) {
        self.audioURL = audioURL
        self.vocabularyHints = vocabularyHints
        self.languageHint = languageHint
    }

    enum CodingKeys: String, CodingKey {
        case audioURL = "audio_url"
        case vocabularyHints = "vocabulary_hints"
        case languageHint = "language_hint"
    }
}

public struct ASRResult: Codable, Sendable, Equatable {
    public var segments: [ASRSegment]
    /// BCP-47, whole-file judgment.
    public var detectedLanguage: String?
    /// Engine-native JSON — word-level timing/confidence stay reachable here
    /// for future chunks without a protocol change.
    public var rawPayload: Data
    public var usage: EngineUsage?
    public var provenance: ASRProvenance

    public init(
        segments: [ASRSegment],
        detectedLanguage: String? = nil,
        rawPayload: Data,
        usage: EngineUsage? = nil,
        provenance: ASRProvenance
    ) {
        self.segments = segments
        self.detectedLanguage = detectedLanguage
        self.rawPayload = rawPayload
        self.usage = usage
        self.provenance = provenance
    }

    enum CodingKeys: String, CodingKey {
        case segments, usage, provenance
        case detectedLanguage = "detected_language"
        case rawPayload = "raw_payload"
    }
}

// MARK: - Notes types

/// Who "the user" is, so every summarization engine can produce
/// `userActionItems` without out-of-band knowledge. Persisted in
/// `SettingsStore` under `UserIdentity.settingsKey`. Design-for-one, door
/// open for many.
public struct UserIdentity: Codable, Sendable, Equatable {
    public static let settingsKey = "user.identity"

    /// Neutral shipped default (G3/D19): the app ships with NO personal data.
    /// An empty identity means "not yet onboarded" — first launch offers the
    /// onboarding sheet, and every `?? .shippedDefault` consumer degrades
    /// gracefully (attendee self-exclusion no-ops without an email; the
    /// action-items section renders "My action items"; the mic track labels
    /// "You"). Each user becomes "the user" the way the user is today by writing
    /// their identity into the settings store at onboarding.
    public static let shippedDefault = UserIdentity(name: "", aliases: [], email: "")

    /// True when no identity has been entered yet (onboarding trigger).
    public var isEmpty: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var name: String
    public var aliases: [String]
    public var email: String

    public init(name: String, aliases: [String], email: String) {
        self.name = name
        self.aliases = aliases
        self.email = email
    }
}

public struct NotesRequest: Codable, Sendable, Equatable {
    public var meeting: Meeting
    /// Speaker-attributed, corrected transcript.
    public var transcript: [TranscriptSegment]
    /// Producer: C7's deterministic language-stats step over the transcript —
    /// recomputable for regeneration; never fabricated.
    public var dominantLanguage: String
    public var vocabulary: [String]
    public var user: UserIdentity
    /// #101: presence-gated grounded person-mention hints derived by app code
    /// (`GroundedPersonHints.groundedPersonHints`) — never hand-authored. Empty
    /// by default; an empty set renders NO hint block (byte-identical to no
    /// block). Decoded via `decodeIfPresent ?? []` so payloads predating the
    /// field round-trip unchanged.
    public var groundedPersonHints: [GroundedPersonHint]
    /// G17: the meeting's durable user corrections/notes, injected into every
    /// synthesis run (partial or full — a later Regenerate can never erase
    /// user truth). Empty renders NO block (byte-identical user message);
    /// `decodeIfPresent ?? []` keeps pre-G17 requests round-tripping.
    public var corrections: [NotesCorrection]

    public init(
        meeting: Meeting,
        transcript: [TranscriptSegment],
        dominantLanguage: String,
        vocabulary: [String],
        user: UserIdentity,
        groundedPersonHints: [GroundedPersonHint] = [],
        corrections: [NotesCorrection] = []
    ) {
        self.meeting = meeting
        self.transcript = transcript
        self.dominantLanguage = dominantLanguage
        self.vocabulary = vocabulary
        self.user = user
        self.groundedPersonHints = groundedPersonHints
        self.corrections = corrections
    }

    enum CodingKeys: String, CodingKey {
        case meeting, transcript, vocabulary, user, corrections
        case dominantLanguage = "dominant_language"
        case groundedPersonHints = "grounded_person_hints"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.meeting = try container.decode(Meeting.self, forKey: .meeting)
        self.transcript = try container.decode([TranscriptSegment].self, forKey: .transcript)
        self.dominantLanguage = try container.decode(String.self, forKey: .dominantLanguage)
        self.vocabulary = try container.decode([String].self, forKey: .vocabulary)
        self.user = try container.decode(UserIdentity.self, forKey: .user)
        // Presence-preserving: payloads predating #101 carry no key → [].
        self.groundedPersonHints =
            try container.decodeIfPresent([GroundedPersonHint].self, forKey: .groundedPersonHints) ?? []
        self.corrections =
            try container.decodeIfPresent([NotesCorrection].self, forKey: .corrections) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(meeting, forKey: .meeting)
        try container.encode(transcript, forKey: .transcript)
        try container.encode(dominantLanguage, forKey: .dominantLanguage)
        try container.encode(vocabulary, forKey: .vocabulary)
        try container.encode(user, forKey: .user)
        try container.encode(groundedPersonHints, forKey: .groundedPersonHints)
        try container.encode(corrections, forKey: .corrections)
    }
}

public struct ActionItem: Codable, Sendable, Equatable {
    public var owner: String
    public var text: String

    public init(owner: String, text: String) {
        self.owner = owner
        self.text = text
    }
}

/// The meeting-type taxonomy (notes v2):
/// a strict 8-value enum the LLM commits to BEFORE writing the notes
/// (classify-then-write via schema property order). `general` is the
/// explicit "no strong cue / cues conflict" escape — never force a type.
public enum MeetingType: String, Codable, Sendable, Equatable, CaseIterable {
    case oneOnOne = "one_on_one"
    case budgetFinance = "budget_finance"
    case projectReview = "project_review"
    case decisionMeeting = "decision_meeting"
    case brainstormWorkshop = "brainstorm_workshop"
    case externalCall = "external_call"
    case interview
    case general
}

/// The single source of truth for notes content. The human markdown document
/// is rendered deterministically from this by `NotesRenderer` — engines do
/// not return markdown.
public struct NotesStructured: Codable, Sendable, Equatable {
    public var title: String?
    public var summary: String
    /// The LLM's meeting-type classification (notes v2). `nil` means the
    /// notes predate the field (pre-v2 persisted rows) — treated as
    /// `general` wherever a value is needed. Presence-preserving Codable
    /// (synthesized `decodeIfPresent`/`encodeIfPresent`): old persisted
    /// notes round-trip WITHOUT the key, which keeps the C8 payload
    /// re-materialization byte-exact for pre-v2 payloads (the builder emits
    /// `meeting_type` only when the notes row actually has it).
    public var meetingType: MeetingType?
    /// Long-form markdown body.
    public var detailedNotes: String
    public var decisions: [String]
    public var actionItems: [ActionItem]
    public var userActionItems: [ActionItem]

    public init(
        title: String? = nil,
        summary: String,
        meetingType: MeetingType? = nil,
        detailedNotes: String,
        decisions: [String],
        actionItems: [ActionItem],
        userActionItems: [ActionItem]
    ) {
        self.title = title
        self.summary = summary
        self.meetingType = meetingType
        self.detailedNotes = detailedNotes
        self.decisions = decisions
        self.actionItems = actionItems
        self.userActionItems = userActionItems
    }

    enum CodingKeys: String, CodingKey {
        case title, summary, decisions
        case meetingType = "meeting_type"
        case detailedNotes = "detailed_notes"
        case actionItems = "action_items"
        case userActionItems = "user_action_items"
        /// G4: persisted notes rows predating the rename carry
        /// `ric_action_items`. The decoder accepts both keys forever (spec
        /// §2, AC2); encoding emits only the new key (new rows new-key-only).
        case ricActionItemsLegacy = "ric_action_items"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.summary = try container.decode(String.self, forKey: .summary)
        // Lenient: `meeting_type` is an OPTIONAL classification. The API/MLX engines
        // get schema-enforced enum values, but the `claude -p` (Account) engine has
        // NO server-side json_schema enforcement and can emit a free-text phrase here
        // — an UNRECOGNIZED value decodes to nil (treated as `general` downstream)
        // rather than failing the ENTIRE notes. A valid raw value still maps to its
        // case, so this is a no-op for the schema-enforced engines.
        self.meetingType = (try container.decodeIfPresent(String.self, forKey: .meetingType))
            .flatMap(MeetingType.init(rawValue:))
        self.detailedNotes = try container.decode(String.self, forKey: .detailedNotes)
        self.decisions = try container.decode([String].self, forKey: .decisions)
        self.actionItems = try container.decode([ActionItem].self, forKey: .actionItems)
        // Prefer the new key; fall back to legacy `ric_action_items` for
        // pre-G4 persisted rows (spec §2, AC2).
        self.userActionItems =
            try container.decodeIfPresent([ActionItem].self, forKey: .userActionItems)
            ?? container.decode([ActionItem].self, forKey: .ricActionItemsLegacy)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Presence-preserving for `meeting_type` (kept from the synthesized
        // behavior): pre-v2 rows round-trip WITHOUT the key, keeping C8
        // payload re-materialization byte-exact.
        try container.encodeIfPresent(title, forKey: .title)
        try container.encode(summary, forKey: .summary)
        try container.encodeIfPresent(meetingType, forKey: .meetingType)
        try container.encode(detailedNotes, forKey: .detailedNotes)
        try container.encode(decisions, forKey: .decisions)
        try container.encode(actionItems, forKey: .actionItems)
        try container.encode(userActionItems, forKey: .userActionItems)
    }
}

/// LLM-proposed speaker-name mapping confidence (C6 amendment to C2).
public enum ProposalConfidence: String, Codable, Sendable, Equatable, CaseIterable {
    case high, medium, low
}

/// One proposed mapping from a diarization label (e.g. "S0") to a human
/// name. `name == nil` means the engine saw the speaker but found no
/// grounded name. `evidence` quotes the supporting transcript span. C7
/// drops `low`-confidence proposals before `SpeakerResolution.apply()`,
/// which validates every name against attendees ∪ events ∪ user ∪
/// transcript-verbatim — names are never invented into the transcript.
public struct SpeakerNameProposal: Codable, Sendable, Equatable {
    public var label: String
    public var name: String?
    public var confidence: ProposalConfidence
    public var evidence: String

    public init(label: String, name: String?, confidence: ProposalConfidence, evidence: String) {
        self.label = label
        self.name = name
        self.confidence = confidence
        self.evidence = evidence
    }
}

public struct NotesResult: Codable, Sendable, Equatable {
    public var structured: NotesStructured
    public var usage: EngineUsage?
    public var provenance: NotesProvenance
    /// C6 amendment (additive; decode-default []). Engines without mapping
    /// ability return [].
    public var speakerNameMapping: [SpeakerNameProposal]

    public init(
        structured: NotesStructured,
        usage: EngineUsage? = nil,
        provenance: NotesProvenance,
        speakerNameMapping: [SpeakerNameProposal] = []
    ) {
        self.structured = structured
        self.usage = usage
        self.provenance = provenance
        self.speakerNameMapping = speakerNameMapping
    }

    enum CodingKeys: String, CodingKey {
        case structured, usage, provenance
        case speakerNameMapping = "speaker_name_mapping"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.structured = try container.decode(NotesStructured.self, forKey: .structured)
        self.usage = try container.decodeIfPresent(EngineUsage.self, forKey: .usage)
        self.provenance = try container.decode(NotesProvenance.self, forKey: .provenance)
        self.speakerNameMapping =
            try container.decodeIfPresent([SpeakerNameProposal].self, forKey: .speakerNameMapping) ?? []
    }
}

// MARK: - Engine load profile (D17)

/// Engine weight class for the summarization slot (D17). The pipeline's
/// one-hop runtime fallback only AUTO-fires to a `.lightweight` engine; a
/// `.heavyweight` engine runs only by deliberate user selection (as the
/// resolved primary), and is expected to gate its own weight load against
/// actual memory headroom. Born from the 2026-06-10 incident: the
/// auto-fallback cold-loading the 15.6 GB local model (~18 GB peak) locked
/// up the 32 GB machine twice during back-to-back meetings.
public enum EngineLoadProfile: Sendable, Equatable {
    /// No significant memory footprint (cloud calls, small models).
    case lightweight
    /// Loads model weights with a large peak footprint; never auto-loaded.
    case heavyweight(estimatedPeakBytes: Int64)
}

// MARK: - Runtime fallback reasons (C6)

/// Reason CONSTANTS for the one-hop summarization runtime fallback (C6
/// spec): C7 matches `EngineError.permanent/.notAvailable` payloads against
/// these exact strings, never on free-form text. The `.permanent` reasons
/// (`inputTooLong`, `outOfMemory`) and the `.notAvailable` reasons
/// (`monthlyCeiling`, `insufficientMemory`) are — together with
/// `.configurationMissing` — the ONLY fallback triggers.
public enum EngineFallbackReason {
    public static let inputTooLong = "input too long"
    public static let outOfMemory = "out of memory"
    public static let monthlyCeiling = "monthly cloud ceiling reached"
    /// Thrown by a heavyweight engine's memory gate BEFORE any weight load
    /// (D17): actual headroom cannot cover the declared peak + margin.
    /// Retry can help once memory frees — but never by waiting blindly:
    /// the trigger lets the pipeline hop to a lightweight engine or resolve
    /// the run to notes-pending.
    public static let insufficientMemory = "insufficient memory headroom"

    /// True iff `error` is a fallback trigger. `.configurationMissing` is a
    /// trigger (C6 impl-audit H-1): with the cloud default shipped and
    /// no API key yet entered, every notes run would otherwise fail with no
    /// interim path — today that trigger resolves to notes-pending when the
    /// only fallback is heavyweight (D17).
    public static func isFallbackTrigger(_ error: EngineError) -> Bool {
        switch error {
        case .permanent(let reason):
            return reason == inputTooLong || reason == outOfMemory
        case .notAvailable(let reason):
            return reason == monthlyCeiling || reason == insufficientMemory
        case .configurationMissing:
            return true
        default:
            return false
        }
    }
}

// MARK: - Cost / usage surface (B-2)

/// Per-call usage. nil fields for local engines; cloud engines fill what
/// they know. Enforcement/accounting of the B-2 ceiling is C6; display is
/// C10; C2 only carries the data.
public struct EngineUsage: Codable, Sendable, Equatable {
    public var inputUnits: Int?
    public var outputUnits: Int?
    public var estimatedCostUSD: Double?

    public init(inputUnits: Int? = nil, outputUnits: Int? = nil, estimatedCostUSD: Double? = nil) {
        self.inputUnits = inputUnits
        self.outputUnits = outputUnits
        self.estimatedCostUSD = estimatedCostUSD
    }

    enum CodingKeys: String, CodingKey {
        case inputUnits = "input_units"
        case outputUnits = "output_units"
        case estimatedCostUSD = "estimated_cost_usd"
    }
}

/// Static engine-level descriptor for Settings display.
public struct EngineCostDescriptor: Codable, Sendable, Equatable {
    public var pricingSummary: String
    public var estimatedPerMeetingUSD: Double?

    public init(pricingSummary: String, estimatedPerMeetingUSD: Double? = nil) {
        self.pricingSummary = pricingSummary
        self.estimatedPerMeetingUSD = estimatedPerMeetingUSD
    }

    enum CodingKeys: String, CodingKey {
        case pricingSummary = "pricing_summary"
        case estimatedPerMeetingUSD = "estimated_per_meeting_usd"
    }
}

// MARK: - Availability / errors

public enum EngineAvailability: Codable, Sendable, Equatable {
    case available
    case unavailable(reason: String)
}

/// Taxonomy all engines map their failures into.
public enum EngineError: Error, Codable, Sendable, Equatable {
    /// Retry may help.
    case transient(String)
    case permanent(String)
    case cancelled
    case configurationMissing(key: String)
    case notAvailable(reason: String)
    // Registry / resolution:
    case duplicateEngineID(String)
    case noEnginesRegistered(slot: String)
    // Renderer:
    case invalidStructuredNotes(String)
}

public enum EngineKind: String, Codable, Sendable, Equatable, CaseIterable {
    case local, cloud
}

// MARK: - Configuration descriptors

public enum ConfigKind: String, Codable, Sendable, Equatable, CaseIterable {
    case string, path, secret
}

/// Engines declare; C10 renders generically. Values live in `SettingsStore`
/// (non-secrets) or `SecretStore` (secrets) under `engine.<id>.<key>`.
public struct EngineConfigDescriptor: Codable, Sendable, Equatable {
    public var key: String
    public var label: String
    public var kind: ConfigKind
    public var required: Bool

    public init(key: String, label: String, kind: ConfigKind, required: Bool) {
        self.key = key
        self.label = label
        self.kind = kind
        self.required = required
    }
}

// MARK: - Engine protocols

/// Post-meeting batch only in V1 (hard floor 1); a streaming refinement
/// later is additive. Cancellation: engines check `Task.isCancelled` at
/// natural boundaries and throw `EngineError.cancelled`.
public protocol ASREngine: Sendable {
    /// Stable, persisted (e.g. "mlx-whisper-large-v3-turbo").
    var id: String { get }
    var displayName: String { get }
    var kind: EngineKind { get }
    /// nil for local engines.
    var costDescriptor: EngineCostDescriptor? { get }
    var configDescriptors: [EngineConfigDescriptor] { get }
    func availability() async -> EngineAvailability
    /// Idempotent; model download etc. Default no-op. OWNERS: C7 awaits
    /// prepare() at every run start (covers shipped-default first run); C10
    /// additionally calls it on switch for eager UX.
    func prepare() async throws
    func transcribe(_ request: ASRRequest) async throws -> ASRResult
}

extension ASREngine {
    public func prepare() async throws {}
}

public protocol SummarizationEngine: Sendable {
    var id: String { get }
    var displayName: String { get }
    var kind: EngineKind { get }
    /// Weight class (D17): `.heavyweight` engines are never auto-loaded by
    /// the runtime fallback; declared explicitly by every engine.
    var loadProfile: EngineLoadProfile { get }
    /// When the user has SELECTED this engine and it fails (after its own bounded
    /// retries) with a fallback-trigger error, the pipeline must NOT silently fall
    /// back to a metered/other engine — it leaves the meeting's notes PENDING with
    /// a user-visible warning so it can be retried on the chosen engine. Default
    /// `false` (the protocol extension below) → the cloud/local engines fall back
    /// as before; ONLY the subscription `claude -p` Account engine overrides it to
    /// `true` (staying free is a user choice that must not be silently spent past).
    var suppressesAutoFallback: Bool { get }
    var costDescriptor: EngineCostDescriptor? { get }
    var configDescriptors: [EngineConfigDescriptor] { get }
    func availability() async -> EngineAvailability
    func prepare() async throws
    /// `purpose` (G7) is threaded down to the cloud accounting write so every
    /// receipt is attributed (generation/regeneration/validation/smoke); it
    /// has NO effect on the produced notes. Local engines ignore it.
    func generateNotes(_ request: NotesRequest, purpose: CloudSpendPurpose) async throws -> NotesResult

    /// G14: the SECOND synthesis call, fired AFTER the notes — produces the
    /// machine-facing `memory_digest`, taking the degarbled transcript + the
    /// just-produced notes as a salience guide (`DigestRequest`). Same engine
    /// the user selected for notes (the swappable seam — the
    /// digest rides it). It carries a NEW bounded transient-retry built for it
    /// (one bounded re-issue on a 429/529/5xx/transient before the error
    /// escapes — a transient blip never becomes a memory gap on the first
    /// wobble). `purpose` is threaded to the cloud accounting write under the
    /// new `.digest` case; local engines ignore it and spend nothing.
    func generateDigest(_ request: DigestRequest, purpose: CloudSpendPurpose) async throws -> DigestResult
}

extension SummarizationEngine {
    public func prepare() async throws {}

    /// Default: engines DO participate in the runtime auto-fallback. Only the
    /// subscription `claude -p` Account engine overrides this to `true` (see its
    /// declaration) so a user who chose "stay free" is never silently switched to
    /// a metered engine — the run goes notes-pending with a warning instead.
    public var suppressesAutoFallback: Bool { false }

    /// Convenience for callers that don't attribute a purpose (bare engine
    /// tests, ad-hoc calls): defaults to `.generation` (spec §1).
    public func generateNotes(_ request: NotesRequest) async throws -> NotesResult {
        try await generateNotes(request, purpose: .generation)
    }

    /// Convenience for callers that don't attribute a purpose: defaults to the
    /// G14 `.digest` spend purpose.
    public func generateDigest(_ request: DigestRequest) async throws -> DigestResult {
        try await generateDigest(request, purpose: .digest)
    }
}
