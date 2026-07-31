import CryptoKit
import Foundation

/// D4 payload assembly per the C8 spec §payload-assembly (shape fully pinned
/// there). C8's chunk owns the worker/transport; C7 calls this builder at
/// stage 13 from the now-final DB state. a self-described JSON shape, not mirroring any external format:
/// `*_ms` integer milliseconds everywhere, `native_id` instead of `id`;
/// `calendar_event` omitted in V1.
public enum EvidencePayloadBuilder {
    public struct Payload: Sendable {
        /// Canonical JSON document bytes (CanonicalJSONWriter convention).
        public let bytes: Data
        /// SHA-256 hex of `bytes` — Blaise's idempotency key.
        public let versionHash: String
    }

    /// The notes user-action-items key form on the wire. New payloads always
    /// carry `.current` (`user_action_items`, the G4 rename). `.legacy`
    /// (`ric_action_items`) exists ONLY so re-materialization of a payload
    /// minted before G4 can reproduce its stored `version_hash` byte-for-byte —
    /// the same presence-gating discipline that protects pre-v2 `meeting_type`
    /// and pre-G2 `name_substitutions` rows.
    public enum UserActionItemsKey {
        case current
        case legacy

        var wireKey: String {
            switch self {
            case .current: return "user_action_items"
            case .legacy: return "ric_action_items"
            }
        }
    }

    /// Every field's persisted source (C8 §builder-inputs): `meeting` row,
    /// `transcript_segment` rows, `meeting_notes` row, `UserIdentity` from
    /// SettingsStore. Re-materialization at delivery time therefore works
    /// from durable state alone.
    public static func build(
        meeting: Meeting,
        segments: [TranscriptSegment],
        notes: MeetingNotes,
        user: UserIdentity,
        userActionItemsKey: UserActionItemsKey = .current,
        digestPromptVersion: DigestPromptVersion = DigestPromptBuilder.shippedVersion
    ) -> Payload {
        let value = payloadValue(
            meeting: meeting, segments: segments, notes: notes, user: user,
            userActionItemsKey: userActionItemsKey, digestPromptVersion: digestPromptVersion)
        let bytes = CanonicalJSONWriter.write(value)
        return Payload(bytes: bytes, versionHash: sha256Hex(bytes))
    }

    /// SHA-256 lowercase hex — the version-hash convention (shared with the
    /// C8 worker's pre-stream self-check).
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func payloadValue(
        meeting: Meeting,
        segments: [TranscriptSegment],
        notes: MeetingNotes,
        user: UserIdentity,
        userActionItemsKey: UserActionItemsKey = .current,
        digestPromptVersion: DigestPromptVersion = DigestPromptBuilder.shippedVersion
    ) -> CanonicalJSONValue {
        let attendees: [CanonicalJSONValue] = meeting.attendees.map { attendee in
            var fields: [(String, CanonicalJSONValue)] = [("name", .string(attendee.name))]
            if let email = attendee.email {
                fields.append(("email", .string(email)))
            }
            return .object(fields)
        }

        let transcript: [CanonicalJSONValue] = segments.map { segment in
            .object([
                ("speaker", .object([
                    ("source", .string(speakerSource(of: segment, meeting: meeting, user: user))),
                    ("diarization_label", .string(segment.speakerLabel)),
                    ("name", segment.speakerName.map(CanonicalJSONValue.string) ?? .null),
                ])),
                ("text", .string(segment.text)),
                ("start_time_ms", .integer(milliseconds(segment.startSeconds))),
                ("end_time_ms", .integer(milliseconds(segment.endSeconds))),
            ])
        }

        let structured = notes.structured
        var notesStructuredFields: [(String, CanonicalJSONValue)] = [
            ("title", structured.title.map(CanonicalJSONValue.string) ?? .null),
            ("summary", .string(structured.summary)),
            ("detailed_notes", .string(structured.detailedNotes)),
            ("decisions", .array(structured.decisions.map(CanonicalJSONValue.string))),
            ("action_items", .array(structured.actionItems.map(actionItemValue))),
            // G4 rename held the position `ric_action_items` occupied (between
            // action_items and meeting_type). `.legacy` re-emits the OLD key in
            // that same slot so a pre-G4 payload re-materializes byte-identically
            // to its stored version_hash; new payloads always use `.current`.
            (userActionItemsKey.wireKey, .array(structured.userActionItems.map(actionItemValue))),
        ]
        // ADDITIVE field (C8 contract discipline), gated on presence: only
        // notes rows that HAVE a meeting_type (notes v2 onward) emit it —
        // pre-v2 notes re-materialize byte-identically to their original
        // payloads (the worker's pre-stream self-check compares hashes).
        if let meetingType = structured.meetingType {
            notesStructuredFields.append(("meeting_type", .string(meetingType.rawValue)))
        }
        let notesStructured: CanonicalJSONValue = .object(notesStructuredFields)

        var provenanceASR: [(String, CanonicalJSONValue)] = []
        if let asr = meeting.asrProvenance {
            provenanceASR = [
                ("engine", .string(asr.engine)),
                ("model", .string(asr.model)),
                ("runtime", .string(asr.runtime)),
                ("engine_version", .string(asr.engineVersion)),
                ("transcribed_at_ms", .integer(milliseconds(date: asr.transcribedAt))),
                ("vocabulary_hints_applied", .bool(asr.vocabularyHintsApplied)),
                ("language_hint", asr.languageHint.map(CanonicalJSONValue.string) ?? .null),
            ]
        }
        // G2 §3: the deterministic name-substitution report rides the notes
        // provenance. ADDITIVE + presence-gated (C8 contract discipline): only
        // emitted when the pass actually substituted something, so an empty
        // store re-materializes pre-G2 payloads byte-identically (AC6).
        var notesProvenanceFields: [(String, CanonicalJSONValue)] = [
            ("engine", .string(notes.provenance.engine)),
            ("model", .string(notes.provenance.model)),
            ("runtime", .string(notes.provenance.runtime)),
            ("renderer_version", .string(notes.provenance.rendererVersion)),
            ("prompt_version", .string(notes.provenance.promptVersion)),
        ]
        if !notes.provenance.nameSubstitutions.isEmpty {
            notesProvenanceFields.append((
                "name_substitutions",
                .array(notes.provenance.nameSubstitutions.map { entry in
                    .object([
                        ("field", .string(entry.field)),
                        ("original", .string(entry.original)),
                        ("replacement", .string(entry.replacement)),
                        ("rule", .integer(Int64(entry.rule))),
                    ])
                })))
        }
        // G14: the digest provenance sub-object — ADDITIVE + presence-gated,
        // alongside `asr`/`notes`. Emitted ONLY when a digest is stored
        // (`notes.memoryDigest != nil`); a toggle-off / legacy / digest-failed
        // meeting omits it entirely, so the payload re-materializes
        // byte-identically to today's. Carries the `md-v1` prompt version (the
        // engine/model mirror the notes call's — the digest rides the same
        // engine the user selected for notes).
        var provenanceFields: [(String, CanonicalJSONValue)] = [
            ("asr", .object(provenanceASR)),
            ("notes", .object(notesProvenanceFields)),
            ("pipeline_version", .string(notes.provenance.pipelineVersion)),
        ]
        if notes.memoryDigest != nil {
            // #102 (F9): `memory_digest.model` denotes the SYNTHESIS engine — the
            // model that PRODUCED the digest draft (always Sonnet = the engine the
            // user selected for notes), NOT the per-call combined-audit model. The
            // audit model (which may be the cheaper Haiku when the toggle is ON)
            // lives in the cloud-spend RECEIPT, where the ledger truth is keyed.
            // This provenance field intentionally stays the synthesis model.
            provenanceFields.append((
                "memory_digest",
                .object([
                    ("prompt_version", .string(digestPromptVersion.rawValue)),
                    ("engine", .string(notes.provenance.engine)),
                    ("model", .string(notes.provenance.model)),
                ])))
        }
        let provenance: CanonicalJSONValue = .object(provenanceFields)

        var topLevel: [(String, CanonicalJSONValue)] = [
            // The meeting ULID MUST be embedded so payloads for distinct
            // meetings can never be byte-identical (C1).
            ("native_id", .string(meeting.id)),
            ("source", .string("blaise")),
            ("title", .string(meeting.title)),
            ("started_at_ms", .integer(milliseconds(date: meeting.startedAt))),
            ("ended_at_ms", meeting.endedAt.map { CanonicalJSONValue.integer(milliseconds(date: $0)) } ?? .null),
            ("created_at_ms", .integer(milliseconds(date: meeting.createdAt))),
            ("updated_at_ms", .integer(milliseconds(date: meeting.updatedAt))),
            ("owner", .object([
                ("name", .string(user.name)),
                ("email", .string(user.email)),
            ])),
            ("attendees", .array(attendees)),
            ("dominant_language", notes.language.isEmpty ? .null : .string(notes.language)),
            ("summary_text", .string(structured.summary)),
            ("summary_markdown", .string(notes.markdown)),
            ("notes_structured", notesStructured),
            ("transcript", .array(transcript)),
            ("provenance", provenance),
        ]
        // G14: the top-level machine-facing digest — ADDITIVE + presence-gated.
        // Emitted ONLY when a digest is stored; absent ⇒ "skip" to the knowledge graph
        // (amendment §10). A toggle-off / legacy / digest-failed meeting omits
        // it, byte-identical to today's payload. `CanonicalJSONWriter` byte-sorts
        // it into canonical position automatically.
        if let digest = notes.memoryDigest {
            topLevel.append(("memory_digest", .string(digest)))
        }
        return .object(topLevel)
    }

    /// `speaker.source` predicate, pinned (C8 round-4 H-2, v4.2 C11
    /// amendment): `"microphone"` iff `speakerLabel == "user"` (the durable
    /// label C11's live capture writes for mic-track segments —
    /// re-materialization-exact), OR the segment's resolved name matches —
    /// case-insensitive, diacritic-folded equality — `UserIdentity.name ∪
    /// aliases`, OR the resolved name maps to an attendee whose email equals
    /// `UserIdentity.email`; else `"speaker"`.
    static func speakerSource(of segment: TranscriptSegment, meeting: Meeting, user: UserIdentity) -> String {
        if segment.speakerLabel == "user" { return "microphone" }
        if DiarizationLabel.isMicCluster(segment.speakerLabel) { return "speaker" }
        guard let name = segment.speakerName else { return "speaker" }
        return OwnerIdentitySet(user: user, attendees: meeting.attendees).contains(name)
            ? "microphone" : "speaker"
    }

    private static func actionItemValue(_ item: ActionItem) -> CanonicalJSONValue {
        .object([("owner", .string(item.owner)), ("text", .string(item.text))])
    }

    static func milliseconds(_ seconds: Double) -> Int64 {
        Int64((seconds * 1000).rounded())
    }

    static func milliseconds(date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}
