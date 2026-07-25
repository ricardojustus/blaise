import Foundation

/// ULID string identifying a meeting.
public typealias MeetingID = String
/// ULID string identifying a handoff queue item.
public typealias HandoffID = String

// MARK: - Meeting

public enum MeetingSource: String, Codable, Sendable, CaseIterable {
    case meet, zoom, teams, inPerson, imported
}

/// `status` describes the last full processing run. `failed` = it did not
/// complete (existing artifacts remain valid and discoverable). `ready` =
/// transcript AND notes complete; minted exclusively by
/// `BlaiseDatabase.finalizeMeetingProcessing` in one transaction with the
/// handoff enqueue. A failed regeneration of a `ready` meeting keeps
/// `status == ready` (no-regress rule, enforced by C7). No CHECK constraint
/// in SQL — this vocabulary is the one most likely to evolve; the enum is
/// the validity boundary.
///
/// G9: `paused` is a durable held-open state — the current capture part is
/// finalized but the meeting is neither recording nor processing. The
/// dispatch arc gains `recording → paused → recording | processing`. No path
/// may process a `paused` meeting: the orphan sweep encodes its CAFs
/// (floor 2) but withholds the kick, and `dispatchProcessing` refuses it
/// outright. The DB startup sweep enumerates only `recording`/`processing`,
/// so a `paused` row survives a crash/relaunch intact (the End path is the
/// only arc out of `paused` into processing).
public enum MeetingStatus: String, Codable, Sendable, CaseIterable {
    // G10: `cancelled` is the durable end state of a user-cancelled FIRST
    // processing run (the G9 `paused` precedent — TEXT, no CHECK constraint).
    // The auto-kick paths refuse it; only the user's Process / explicit
    // regenerate are the sanctioned exits (no deadlock).
    case recording, processing, ready, failed, paused, cancelled
}

public enum AttendeeSource: String, Codable, Sendable, CaseIterable {
    case meetExtension, calendar, manual
}

public struct Attendee: Codable, Sendable, Equatable {
    public var name: String
    public var email: String?
    public var source: AttendeeSource

    public init(name: String, email: String? = nil, source: AttendeeSource) {
        self.name = name
        self.email = email
        self.source = source
    }
}

/// Engine identity = model + runtime (decision D5). Set whenever the
/// transcript is (re)written.
///
/// `vocabularyHintsApplied`/`languageHint` (C2): same engine ± hints
/// produces different transcripts; provenance must say which ran. Decode
/// defaults (`false`/`nil`) cover previously-persisted JSON — additive, no
/// migration.
public struct ASRProvenance: Codable, Sendable, Equatable {
    public var engine: String
    public var model: String
    public var runtime: String
    public var engineVersion: String
    public var transcribedAt: Date
    public var vocabularyHintsApplied: Bool
    public var languageHint: String?

    public init(
        engine: String,
        model: String,
        runtime: String,
        engineVersion: String,
        transcribedAt: Date,
        vocabularyHintsApplied: Bool = false,
        languageHint: String? = nil
    ) {
        self.engine = engine
        self.model = model
        self.runtime = runtime
        self.engineVersion = engineVersion
        self.transcribedAt = transcribedAt
        self.vocabularyHintsApplied = vocabularyHintsApplied
        self.languageHint = languageHint
    }

    enum CodingKeys: String, CodingKey {
        case engine, model, runtime
        case engineVersion = "engine_version"
        case transcribedAt = "transcribed_at"
        case vocabularyHintsApplied = "vocabulary_hints_applied"
        case languageHint = "language_hint"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.engine = try container.decode(String.self, forKey: .engine)
        self.model = try container.decode(String.self, forKey: .model)
        self.runtime = try container.decode(String.self, forKey: .runtime)
        self.engineVersion = try container.decode(String.self, forKey: .engineVersion)
        self.transcribedAt = try container.decode(Date.self, forKey: .transcribedAt)
        self.vocabularyHintsApplied = try container.decodeIfPresent(Bool.self, forKey: .vocabularyHintsApplied) ?? false
        self.languageHint = try container.decodeIfPresent(String.self, forKey: .languageHint)
    }
}

/// G12 (migration v13): the provenance of `meeting.title`, the precedence
/// ladder's single source of authority. Higher tiers are never overwritten by
/// lower ones (the writers gate on this), and `Comparable` orders them so the
/// gate reads as `incoming >= current`:
/// `default < llm < calendar < user`.
/// - `user`: any explicit rename (G2 `renameMeeting`), whenever it happened.
/// - `calendar`: the suggestion-matched event title, written once at start.
/// - `llm`: an ad-hoc meeting's title promoted from `NotesStructured.title`
///   on the primary finalize run (refreshable by a later generation).
/// - `default`: the date-derived placeholder minted at recording start.
public enum TitleSource: String, Codable, Sendable, Equatable, CaseIterable, Comparable {
    case `default`
    case llm
    case calendar
    case user

    private var rank: Int {
        switch self {
        case .default: return 0
        case .llm: return 1
        case .calendar: return 2
        case .user: return 3
        }
    }

    public static func < (lhs: TitleSource, rhs: TitleSource) -> Bool {
        lhs.rank < rhs.rank
    }
}

public struct Meeting: Codable, Sendable, Equatable {
    public var id: MeetingID
    public var title: String
    /// G12 (migration v13): which tier set `title` (`default` until a higher
    /// writer claims it). The precedence gate reads this so a lower tier never
    /// clobbers a higher one. Tolerant default `default` for rows predating v13.
    public var titleSource: TitleSource
    /// Non-optional — a meeting always has a start.
    public var startedAt: Date
    /// nil while recording.
    public var endedAt: Date?
    public var source: MeetingSource
    public var status: MeetingStatus
    public var attendees: [Attendee]
    /// Google Meet meeting code (e.g. "abc-defg-hij") — the C12 batch→meeting
    /// correlation key (C10, migration v4; C1 amendment recorded). Set by the
    /// import sheet's optional field in V1, by C11 capture sessions later;
    /// editable in the detail inspector (edits sweep `meet_events_pending`).
    public var meetingCode: String?
    /// BCP-47.
    public var dominantLanguage: String?
    public var asrProvenance: ASRProvenance?
    public var lastProcessingError: String?
    /// C6 (migration v3): non-failure note from the last processing run —
    /// e.g. "fallback: input too long" when the one-hop summarization
    /// runtime fallback ran. Distinct from `lastProcessingError`, which
    /// keeps failures-only semantics. Lifecycle: cleared at the start of
    /// every processing/regeneration run, set only by that run (C7).
    public var processingNote: String?
    /// C11 (migration v6): durable captured-meeting marker, set at capture
    /// start. The processing dispatch keys on it (OR on mic-track presence)
    /// so a captured meeting whose mic track was lost still runs the
    /// two-track variant (isSelf voting exclusion, honest capturedTracks) —
    /// never on file presence alone. Always false for file-first imports.
    public var captured: Bool
    /// G11 (migration v12): the calendar anchor — the matched event's
    /// identifier. Written ONCE at start when the start was suggestion-matched;
    /// nil = ad-hoc. Internal only (never a payload-builder input).
    public var calendarEventID: String?
    /// G11 (migration v12): the matched event's scheduled end (epoch ms). The
    /// §2 classifier reads it to decide whether a debounce-fired end skips
    /// grace. nil = ad-hoc.
    public var scheduledEndMs: Int64?
    /// G11 (migration v12): the durable resume-grace deadline (epoch ms).
    /// Non-nil while a grace window stands (written before the in-memory timer
    /// is armed, cleared at every grace exit). A non-nil value on a `recording`
    /// row at launch means "app died during grace" — the interrupted-flip
    /// exemption keeps it from being flipped and launch recovery re-enters
    /// grace or processes by its deadline.
    public var graceUntilMs: Int64?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: MeetingID,
        title: String,
        titleSource: TitleSource = .default,
        startedAt: Date,
        endedAt: Date? = nil,
        source: MeetingSource,
        status: MeetingStatus,
        attendees: [Attendee] = [],
        meetingCode: String? = nil,
        dominantLanguage: String? = nil,
        asrProvenance: ASRProvenance? = nil,
        lastProcessingError: String? = nil,
        processingNote: String? = nil,
        captured: Bool = false,
        calendarEventID: String? = nil,
        scheduledEndMs: Int64? = nil,
        graceUntilMs: Int64? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.titleSource = titleSource
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.source = source
        self.status = status
        self.attendees = attendees
        self.meetingCode = meetingCode
        self.dominantLanguage = dominantLanguage
        self.asrProvenance = asrProvenance
        self.lastProcessingError = lastProcessingError
        self.processingNote = processingNote
        self.captured = captured
        self.calendarEventID = calendarEventID
        self.scheduledEndMs = scheduledEndMs
        self.graceUntilMs = graceUntilMs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, title, source, status, attendees, captured
        case titleSource = "title_source"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case meetingCode = "meeting_code"
        case dominantLanguage = "dominant_language"
        case asrProvenance = "asr_provenance"
        case lastProcessingError = "last_processing_error"
        case processingNote = "processing_note"
        case calendarEventID = "calendar_event_id"
        case scheduledEndMs = "scheduled_end_ms"
        case graceUntilMs = "grace_until_ms"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(MeetingID.self, forKey: .id)
        self.title = try container.decode(String.self, forKey: .title)
        // Tolerant default: rows/fixtures predating migration v13.
        self.titleSource = try container.decodeIfPresent(TitleSource.self, forKey: .titleSource) ?? .default
        self.startedAt = try container.decode(Date.self, forKey: .startedAt)
        self.endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        self.source = try container.decode(MeetingSource.self, forKey: .source)
        self.status = try container.decode(MeetingStatus.self, forKey: .status)
        self.attendees = try container.decode([Attendee].self, forKey: .attendees)
        self.meetingCode = try container.decodeIfPresent(String.self, forKey: .meetingCode)
        self.dominantLanguage = try container.decodeIfPresent(String.self, forKey: .dominantLanguage)
        self.asrProvenance = try container.decodeIfPresent(ASRProvenance.self, forKey: .asrProvenance)
        self.lastProcessingError = try container.decodeIfPresent(String.self, forKey: .lastProcessingError)
        self.processingNote = try container.decodeIfPresent(String.self, forKey: .processingNote)
        // Tolerant default: rows/fixtures predating migration v6.
        self.captured = try container.decodeIfPresent(Bool.self, forKey: .captured) ?? false
        // Tolerant defaults: rows/fixtures predating migration v12.
        self.calendarEventID = try container.decodeIfPresent(String.self, forKey: .calendarEventID)
        self.scheduledEndMs = try container.decodeIfPresent(Int64.self, forKey: .scheduledEndMs)
        self.graceUntilMs = try container.decodeIfPresent(Int64.self, forKey: .graceUntilMs)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

// MARK: - Transcript

public struct TranscriptSegment: Codable, Sendable, Equatable {
    /// Diarization label sentinel before diarization runs (single convention for C3/C4).
    public static let unattributed = "unattributed"
    /// Reserved label for the user's own microphone track under two-track
    /// capture (C11; C1/C4 convention amended: reserved classes are `S<n>`,
    /// `unattributed`, `user`). Segments carrying it are named at creation
    /// (`UserIdentity.name`) and IMMUNE to any mapping (apply() rule 0).
    public static let userLabel = "user"

    /// DB autoincrement; nil before insert.
    public var id: Int64?
    public var meetingID: MeetingID
    public var ord: Int
    public var startSeconds: Double
    public var endSeconds: Double
    /// Diarization label; `TranscriptSegment.unattributed` before diarization.
    public var speakerLabel: String
    /// Resolved human name.
    public var speakerName: String?
    public var text: String

    public init(
        id: Int64? = nil,
        meetingID: MeetingID,
        ord: Int,
        startSeconds: Double,
        endSeconds: Double,
        speakerLabel: String = TranscriptSegment.unattributed,
        speakerName: String? = nil,
        text: String
    ) {
        self.id = id
        self.meetingID = meetingID
        self.ord = ord
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.speakerLabel = speakerLabel
        self.speakerName = speakerName
        self.text = text
    }

    enum CodingKeys: String, CodingKey {
        case id, ord, text
        case meetingID = "meeting_id"
        case startSeconds = "start_seconds"
        case endSeconds = "end_seconds"
        case speakerLabel = "speaker_label"
        case speakerName = "speaker_name"
    }
}

// MARK: - Notes

/// `runtime`/`rendererVersion` (C2): parity with D5's engine-identity rule
/// on the notes side; the renderer version travels because the markdown
/// artifact depends on it. Decode default `""` covers previously-persisted
/// JSON — additive, no migration.
public struct NotesProvenance: Codable, Sendable, Equatable {
    public var engine: String
    public var model: String
    public var pipelineVersion: String
    public var runtime: String
    public var rendererVersion: String
    /// C6 amendment: the system-prompt version that produced these notes
    /// (versioned constant; the artifacts depend on it). Decode-default ""
    /// — additive, no migration. `pipelineVersion` stays C7's.
    public var promptVersion: String
    /// G2 §3: the deterministic name-substitution report for THIS generation
    /// (field, original, replacement, rule). Decode-default [] — additive, no
    /// migration; an empty store / no substitutions leaves it empty, which
    /// keeps the regression-pin payload byte-identical (AC6). Shown in the
    /// notes info popover.
    public var nameSubstitutions: [NameSubstitution.ReportEntry]
    /// G3: the identity name that drove the user action-items section title
    /// for THIS generation (empty pre-onboarding → the neutral "My
    /// action items"/"Minhas ações" rendering). The markdown depends on it the
    /// same way it depends on `rendererVersion`, so it travels in provenance.
    /// Decode-default "" — additive, no migration.
    public var userName: String

    public init(
        engine: String, model: String, pipelineVersion: String, runtime: String = "",
        rendererVersion: String = "", promptVersion: String = "",
        nameSubstitutions: [NameSubstitution.ReportEntry] = [],
        userName: String = ""
    ) {
        self.engine = engine
        self.model = model
        self.pipelineVersion = pipelineVersion
        self.runtime = runtime
        self.rendererVersion = rendererVersion
        self.promptVersion = promptVersion
        self.nameSubstitutions = nameSubstitutions
        self.userName = userName
    }

    enum CodingKeys: String, CodingKey {
        case engine, model, runtime
        case pipelineVersion = "pipeline_version"
        case rendererVersion = "renderer_version"
        case promptVersion = "prompt_version"
        case nameSubstitutions = "name_substitutions"
        case userName = "user_name"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.engine = try container.decode(String.self, forKey: .engine)
        self.model = try container.decode(String.self, forKey: .model)
        self.pipelineVersion = try container.decode(String.self, forKey: .pipelineVersion)
        self.runtime = try container.decodeIfPresent(String.self, forKey: .runtime) ?? ""
        self.rendererVersion = try container.decodeIfPresent(String.self, forKey: .rendererVersion) ?? ""
        self.promptVersion = try container.decodeIfPresent(String.self, forKey: .promptVersion) ?? ""
        self.nameSubstitutions =
            try container.decodeIfPresent([NameSubstitution.ReportEntry].self, forKey: .nameSubstitutions)
            ?? []
        self.userName = try container.decodeIfPresent(String.self, forKey: .userName) ?? ""
    }
}

public struct MeetingNotes: Codable, Sendable, Equatable {
    public var meetingID: MeetingID
    /// Human artifact, rendered deterministically from `structured` by
    /// `NotesRenderer` (C7 stores both).
    public var markdown: String
    /// The single source of truth for notes content (C2, schema v2).
    public var structured: NotesStructured
    public var language: String
    public var generatedAt: Date
    public var provenance: NotesProvenance
    /// G14: the persisted machine-facing memory digest (the knowledge graph
    /// graph-extractor surface). `nil` means no digest for this meeting — a
    /// toggle-off, a legacy (pre-G14) row, or a digest-pending meeting whose
    /// digest call has not yet landed. Presence-preserving Codable (the
    /// `meeting_type` precedent): a null/absent column round-trips WITHOUT the
    /// key, so the payload re-materializes byte-identically (no `memory_digest`
    /// field) for any meeting that has no stored digest. The single source of
    /// truth for re-materialization (§3 store-once invariant): the digest bytes
    /// change ONLY when the pipeline genuinely re-runs the digest call or a
    /// deterministic name-edit rewrites them in place.
    public var memoryDigest: String?
    /// T3.1 (md-v3) AC2: the FIRST-run scoped alias bindings (alias→canonical,
    /// admitted on actual alias evidence) persisted with the meeting so the bare
    /// digest-resume path (`digestOnlyBody`) — which reloads only the corrected
    /// transcript and CANNOT reconstruct the `AppliedCorrection` records — scopes
    /// IDENTICALLY to the first run. Without this, a correction-LIMITED alias
    /// (admitted via path (ii): an applied `.alias` correction whose canonical is
    /// never injected into the transcript) would silently vanish on resume.
    /// Stored in its OWN nullable JSON column (`scoped_alias_bindings`);
    /// presence-preserving like `memoryDigest` (a null/absent column → `[]`, so a
    /// pre-md-v3 row round-trips WITHOUT the key and the payload re-materializes
    /// byte-identically). NOT in the payload (the builder reads explicit fields
    /// only — `EvidencePayloadBuilder`), so `versionHash` is unaffected (AC7).
    public var scopedAliasBindings: [AliasPair]

    public init(
        meetingID: MeetingID,
        markdown: String,
        structured: NotesStructured,
        language: String,
        generatedAt: Date,
        provenance: NotesProvenance,
        memoryDigest: String? = nil,
        scopedAliasBindings: [AliasPair] = []
    ) {
        self.meetingID = meetingID
        self.markdown = markdown
        self.structured = structured
        self.language = language
        self.generatedAt = generatedAt
        self.provenance = provenance
        self.memoryDigest = memoryDigest
        self.scopedAliasBindings = scopedAliasBindings
    }

    enum CodingKeys: String, CodingKey {
        case markdown, structured, language, provenance
        case meetingID = "meeting_id"
        case generatedAt = "generated_at"
        case memoryDigest = "memory_digest"
        case scopedAliasBindings = "scoped_alias_bindings"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.meetingID = try container.decode(MeetingID.self, forKey: .meetingID)
        self.markdown = try container.decode(String.self, forKey: .markdown)
        self.structured = try container.decode(NotesStructured.self, forKey: .structured)
        self.language = try container.decode(String.self, forKey: .language)
        self.generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        self.provenance = try container.decode(NotesProvenance.self, forKey: .provenance)
        self.memoryDigest = try container.decodeIfPresent(String.self, forKey: .memoryDigest)
        // A null/absent column (legacy / pre-md-v3 / digest-off row) → empty set.
        self.scopedAliasBindings =
            try container.decodeIfPresent([AliasPair].self, forKey: .scopedAliasBindings) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(meetingID, forKey: .meetingID)
        try container.encode(markdown, forKey: .markdown)
        try container.encode(structured, forKey: .structured)
        try container.encode(language, forKey: .language)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(provenance, forKey: .provenance)
        // `memory_digest` is its OWN nullable DB column (not embedded JSON), so
        // it is always encoded — a nil writes the column as SQL NULL. This is
        // load-bearing for upsert: a path that re-persists notes WITHOUT a
        // digest (digest-pending, or a toggle flipped off on regenerate) must
        // actively CLEAR a previously-stored digest, which `encodeIfPresent`
        // would silently skip. Byte-identical payload re-materialization is
        // protected at the PAYLOAD builder (the `memory_digest` field is
        // presence-gated on a non-null column), not here.
        try container.encode(memoryDigest, forKey: .memoryDigest)
        // `scoped_alias_bindings`: an EMPTY set writes SQL NULL (so a digest-off
        // / no-alias row carries no column value and a pre-md-v3 row stays
        // null), a non-empty set writes a JSON array. Always encoded (like
        // `memory_digest`) so a re-persist that scopes to no aliases actively
        // CLEARS a previously-stored set rather than silently retaining it.
        try container.encode(
            scopedAliasBindings.isEmpty ? nil : scopedAliasBindings,
            forKey: .scopedAliasBindings)
    }
}

// MARK: - Search

public struct SearchHit: Codable, Sendable, Equatable {
    /// FTS5 `snippet()` match-start delimiter (U+FFF9) — unambiguous, never occurs in speech text.
    public static let matchStartDelimiter = "\u{FFF9}"
    /// FTS5 `snippet()` match-end delimiter (U+FFFA).
    public static let matchEndDelimiter = "\u{FFFA}"

    public var meetingID: MeetingID
    public var segmentID: Int64
    public var ord: Int
    public var startSeconds: Double
    public var snippet: String

    public init(meetingID: MeetingID, segmentID: Int64, ord: Int, startSeconds: Double, snippet: String) {
        self.meetingID = meetingID
        self.segmentID = segmentID
        self.ord = ord
        self.startSeconds = startSeconds
        self.snippet = snippet
    }
}

/// A full-text hit in a meeting's NOTES (F2). Notes are one row per meeting,
/// so a hit IS a meeting; it carries no segment/offset. The snippet uses the
/// same `SearchHit.match{Start,End}Delimiter` convention as transcript hits,
/// so the snippet-bolding formatter is shared.
public struct NotesSearchHit: Codable, Sendable, Equatable {
    public var meetingID: MeetingID
    public var snippet: String

    public init(meetingID: MeetingID, snippet: String) {
        self.meetingID = meetingID
        self.snippet = snippet
    }
}

// MARK: - Handoff

/// `delivered` is the only terminal state; `failed` is retriable bookkeeping
/// (C8 re-enters it; nothing is ever dropped).
public enum HandoffState: String, Codable, Sendable, CaseIterable {
    case pending, delivering, delivered, failed
}

public struct HandoffItem: Codable, Sendable, Equatable {
    public var id: HandoffID
    public var meetingID: MeetingID
    /// RELATIVE to the Blaise data root.
    public var payloadPath: String
    /// SHA-256 of the canonical payload JSON (canonicalization per D4, implemented in C7).
    public var versionHash: String
    public var state: HandoffState
    public var attempts: Int
    /// Durable, VACUUM-stable, clock-independent FIFO enqueue order,
    /// assigned monotonically inside the enqueue transaction.
    public var createdSeq: Int64
    public var createdAt: Date
    public var lastAttemptAt: Date?
    public var deliveredAt: Date?
    public var lastError: String?
    /// G5 v1.5: the destination identity this row's payload was DELIVERED to
    /// (nil until delivered, and on rows delivered by a pre-v19 binary). The
    /// provenance destination cleanup keys its deletion candidates on.
    public var deliveredEndpoint: String?

    public init(
        id: HandoffID,
        meetingID: MeetingID,
        payloadPath: String,
        versionHash: String,
        state: HandoffState,
        attempts: Int,
        createdSeq: Int64,
        createdAt: Date,
        lastAttemptAt: Date? = nil,
        deliveredAt: Date? = nil,
        lastError: String? = nil,
        deliveredEndpoint: String? = nil
    ) {
        self.id = id
        self.meetingID = meetingID
        self.payloadPath = payloadPath
        self.versionHash = versionHash
        self.state = state
        self.attempts = attempts
        self.createdSeq = createdSeq
        self.createdAt = createdAt
        self.lastAttemptAt = lastAttemptAt
        self.deliveredAt = deliveredAt
        self.lastError = lastError
        self.deliveredEndpoint = deliveredEndpoint
    }

    enum CodingKeys: String, CodingKey {
        case id, state, attempts
        case meetingID = "meeting_id"
        case payloadPath = "payload_path"
        case versionHash = "version_hash"
        case createdSeq = "created_seq"
        case createdAt = "created_at"
        case lastAttemptAt = "last_attempt_at"
        case deliveredAt = "delivered_at"
        case lastError = "last_error"
        case deliveredEndpoint = "delivered_endpoint"
    }
}

// MARK: - F1 processing queue

public enum ProcessingJobState: String, Codable, Sendable, CaseIterable {
    case pending, running, done, failed, cancelled
}

public enum ProcessingJobOrigin: String, Codable, Sendable, CaseIterable {
    case user, auto
    case reprocessAll = "reprocess_all"
}

/// A durable processing-queue job (F1). The queue is the always-on substrate;
/// the worker drives the unchanged `ProcessingPipeline.dispatchProcessing`, which
/// self-selects process-vs-regenerate at run time — so there is no `kind` here.
public struct ProcessingJob: Codable, Sendable, Equatable {
    public var id: String
    public var meetingID: MeetingID
    public var state: ProcessingJobState
    public var origin: ProcessingJobOrigin
    public var attempts: Int
    /// Durable, VACUUM-stable, clock-independent FIFO order (the handoff pattern).
    public var createdSeq: Int64
    public var enqueuedAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var lastError: String?

    public init(
        id: String,
        meetingID: MeetingID,
        state: ProcessingJobState,
        origin: ProcessingJobOrigin,
        attempts: Int,
        createdSeq: Int64,
        enqueuedAt: Date,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.id = id
        self.meetingID = meetingID
        self.state = state
        self.origin = origin
        self.attempts = attempts
        self.createdSeq = createdSeq
        self.enqueuedAt = enqueuedAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.lastError = lastError
    }

    enum CodingKeys: String, CodingKey {
        case id, state, origin, attempts
        case meetingID = "meeting_id"
        case createdSeq = "created_seq"
        case enqueuedAt = "enqueued_at"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case lastError = "last_error"
    }
}
