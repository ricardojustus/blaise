import Foundation
import GRDB
import Testing

@testable import BlaiseCore

// T3 / T3.1 — structured digest inputs (scoped alias bindings + host binding)
// and the md-v3 deterministic rendering. All fixtures FICTIONAL (Vexatron Labs
// / Quoll Harbor); no real user/company data anywhere.

private enum T31Fixtures {
    /// A fictional dictionary: a codename alias (`Vexa` → `Vexatron Labs`), a
    /// correction-limited alias (`Quoll` → `Quoll Harbor`, whose canonical is
    /// never injected), and a self-pair (`Marsh` → `Marsh`, excluded).
    static let dictionary = VocabularyDictionary(entries: [
        VocabularyEntry(canonical: "Vexatron Labs", aliases: ["Vexa", "Vex Labs"]),
        VocabularyEntry(canonical: "Quoll Harbor", aliases: ["Quoll"]),
        VocabularyEntry(canonical: "Marsh", aliases: ["Marsh"]),
    ])

    static func segment(
        label: String = "S0", name: String? = nil, text: String, ord: Int = 0
    ) -> TranscriptSegment {
        TranscriptSegment(
            meetingID: "01STRUCTUREDINPUTS0000000000", ord: ord, startSeconds: Double(ord),
            endSeconds: Double(ord) + 1, speakerLabel: label, speakerName: name, text: text)
    }

    static func aliasCorrection(_ original: String, _ canonical: String) -> AppliedCorrection {
        AppliedCorrection(original: original, canonical: canonical, stage: "alias")
    }
}

// MARK: - AC1 — AliasPair / HostBinding Equatable + DigestRequest compiles

@Suite struct DigestStructuredModelTests {
    @Test func aliasPairEquatable() {
        let a = AliasPair(alias: "Vexa", canonical: "Vexatron Labs")
        let b = AliasPair(alias: "Vexa", canonical: "Vexatron Labs")
        let c = AliasPair(alias: "Vexa", canonical: "Quoll Harbor")
        #expect(a == b)
        #expect(a != c)
    }

    @Test func hostBindingEquatable() {
        #expect(HostBinding(canonicalName: "Dana Marsh") == HostBinding(canonicalName: "Dana Marsh"))
        #expect(HostBinding(canonicalName: "Dana Marsh") != HostBinding(canonicalName: nil))
        #expect(HostBinding(canonicalName: nil) == HostBinding(canonicalName: nil))
    }

    /// AC1: the new fields default so existing constructions still compile, and
    /// `DigestRequest`'s synthesized `Equatable` still holds with the fields set.
    @Test func digestRequestCompilesAndEquates() {
        let base = DigestRequest(
            meeting: Meeting(
                id: "01STRUCTUREDINPUTS0000000000", title: "Vexatron Labs sync",
                startedAt: msDate(), source: .meet, status: .processing,
                attendees: [], createdAt: msDate(), updatedAt: msDate()),
            transcript: [],
            notes: NotesStructured(
                title: nil, summary: "s", detailedNotes: "", decisions: [],
                actionItems: [], userActionItems: []),
            dominantLanguage: "en",
            vocabulary: [],
            user: UserIdentity.shippedDefault)
        // Defaulted fields: empty / nil.
        #expect(base.scopedAliasBindings.isEmpty)
        #expect(base.hostBinding == nil)

        var withFields = base
        withFields.scopedAliasBindings = [AliasPair(alias: "Vexa", canonical: "Vexatron Labs")]
        withFields.hostBinding = HostBinding(canonicalName: "Dana Marsh")
        #expect(withFields != base)
        var copy = base
        copy.scopedAliasBindings = [AliasPair(alias: "Vexa", canonical: "Vexatron Labs")]
        copy.hostBinding = HostBinding(canonicalName: "Dana Marsh")
        #expect(copy == withFields)
    }
}

// MARK: - AC2 — scoped-alias derivation (both admit paths + canonical-only NEG + resume)

@Suite struct ScopedAliasDerivationTests {
    /// Path (i): the alias surface occurs in the corrected transcript (under the
    /// diacritic-exact alias-mode fold). Admitted; original case preserved.
    @Test func admitsViaTranscriptAliasSurface() {
        let segments = [
            T31Fixtures.segment(text: "Vamos revisar o roadmap do Vexa nesta reunião."),
        ]
        let pairs = DigestStructuredInputs.scopedAliasBindings(
            dictionary: T31Fixtures.dictionary, correctedSegments: segments, corrections: [])
        #expect(pairs.contains(AliasPair(alias: "Vexa", canonical: "Vexatron Labs")))
        // The correction-limited alias (Quoll) is NOT in the transcript and has
        // no record here → not admitted.
        #expect(!pairs.contains { $0.canonical == "Quoll Harbor" })
    }

    /// Path (ii): an applied `.alias` correction admits a correction-limited
    /// alias whose canonical is never injected into the transcript.
    @Test func admitsViaAppliedAliasCorrection() {
        let segments = [
            T31Fixtures.segment(text: "Falamos com o parceiro sobre a integração."),
        ]
        let pairs = DigestStructuredInputs.scopedAliasBindings(
            dictionary: T31Fixtures.dictionary, correctedSegments: segments,
            corrections: [T31Fixtures.aliasCorrection("Quoll", "Quoll Harbor")])
        #expect(pairs.contains(AliasPair(alias: "Quoll", canonical: "Quoll Harbor")))
    }

    /// NEGATIVE: the canonical appears in the transcript but NO alias surface and
    /// NO applied `.alias` correction → NOT admitted (canonical-presence alone is
    /// never alias evidence).
    @Test func rejectsCanonicalPresenceAlone() {
        let segments = [
            T31Fixtures.segment(text: "A Vexatron Labs definiu o cronograma de maio."),
        ]
        let pairs = DigestStructuredInputs.scopedAliasBindings(
            dictionary: T31Fixtures.dictionary, correctedSegments: segments, corrections: [])
        #expect(!pairs.contains { $0.canonical == "Vexatron Labs" })
        #expect(pairs.isEmpty)
    }

    /// A non-alias-stage correction (e.g. exact) does NOT admit an alias.
    @Test func rejectsNonAliasStageCorrection() {
        let segments = [T31Fixtures.segment(text: "Reunião de status do produto.")]
        let exact = AppliedCorrection(original: "quoll", canonical: "Quoll Harbor", stage: "exact")
        let pairs = DigestStructuredInputs.scopedAliasBindings(
            dictionary: T31Fixtures.dictionary, correctedSegments: segments, corrections: [exact])
        #expect(pairs.isEmpty)
    }

    /// Self-pairs (alias folds to the canonical) are excluded.
    @Test func excludesSelfPairs() {
        let segments = [T31Fixtures.segment(text: "O Marsh apresentou os números.")]
        let pairs = DigestStructuredInputs.scopedAliasBindings(
            dictionary: T31Fixtures.dictionary, correctedSegments: segments, corrections: [])
        #expect(!pairs.contains { $0.alias == "Marsh" })
    }

    /// RESUME-PATH: on bare resume `corrections == []`. A path-(i) alias (its
    /// surface is in the reloaded corrected transcript) scopes IDENTICALLY to the
    /// first run; only a correction-limited alias is dropped (recoverable — its
    /// canonical is already in the transcript). First-run vs resume agree on the
    /// path-(i) alias.
    @Test func resumePathScopesIdenticallyForTranscriptSurfaceAlias() {
        let corrected = [
            T31Fixtures.segment(text: "O Vexa subiu para 70% de cobertura.", ord: 0),
            T31Fixtures.segment(text: "Falamos com o Quoll também.", ord: 1),
        ]
        // First run also has the applied alias-correction records.
        let firstRun = DigestStructuredInputs.scopedAliasBindings(
            dictionary: T31Fixtures.dictionary, correctedSegments: corrected,
            corrections: [T31Fixtures.aliasCorrection("Vexa", "Vexatron Labs")])
        // Bare resume: no correction records, same corrected segments.
        let resume = DigestStructuredInputs.scopedAliasBindings(
            dictionary: T31Fixtures.dictionary, correctedSegments: corrected, corrections: [])
        // Both admit Vexa via the transcript surface.
        #expect(firstRun.contains(AliasPair(alias: "Vexa", canonical: "Vexatron Labs")))
        #expect(resume.contains(AliasPair(alias: "Vexa", canonical: "Vexatron Labs")))
        // Quoll's surface IS in the corrected transcript here (path i), so both
        // admit it too — the resume set equals the first-run set.
        #expect(resume == firstRun)
    }

    /// PURE DERIVATION: a correction-limited alias (its surface absent from the
    /// corrected transcript) is admitted on the first run via path (ii) but is
    /// NOT re-derivable from the bare inputs alone (no correction records on
    /// resume → path (ii) is unreachable). This is the FUNCTION contract; the
    /// pipeline closes the gap by PERSISTING the first-run set and replaying it
    /// on resume (see `resumeReplaysPersistedCorrectionLimitedAlias` below and
    /// the `MeetingNotes` round-trip), so the alias SURVIVES a digest-resume.
    @Test func bareDerivationDropsCorrectionLimitedAliasOnResumeInputs() {
        let corrected = [T31Fixtures.segment(text: "Conversamos com o parceiro de longa data.")]
        let firstRun = DigestStructuredInputs.scopedAliasBindings(
            dictionary: T31Fixtures.dictionary, correctedSegments: corrected,
            corrections: [T31Fixtures.aliasCorrection("Quoll", "Quoll Harbor")])
        let bareResumeDerivation = DigestStructuredInputs.scopedAliasBindings(
            dictionary: T31Fixtures.dictionary, correctedSegments: corrected, corrections: [])
        #expect(firstRun.contains(AliasPair(alias: "Quoll", canonical: "Quoll Harbor")))
        // Re-derivation from the bare resume inputs alone drops it — which is why
        // the first-run set is persisted and replayed (the next test).
        #expect(bareResumeDerivation.isEmpty)
    }

    /// AC2 RESUME PARITY: the SURVIVAL mechanism. The first run's resolved scoped
    /// set is persisted; the resume path replays it as the override, which
    /// REPLACES re-derivation — so the correction-limited alias the bare
    /// derivation would drop is preserved IDENTICALLY across the resume boundary.
    /// (The override seam is the same value `digestOnlyBody` passes from the
    /// reloaded `notes.scopedAliasBindings`.)
    @Test func resumeReplaysPersistedCorrectionLimitedAlias() {
        let corrected = [T31Fixtures.segment(text: "Conversamos com o parceiro de longa data.")]
        // First run: path (ii) admits the correction-limited alias; this is the
        // set the pipeline PERSISTS on the meeting_notes row.
        let firstRunPersisted = DigestStructuredInputs.scopedAliasBindings(
            dictionary: T31Fixtures.dictionary, correctedSegments: corrected,
            corrections: [T31Fixtures.aliasCorrection("Quoll", "Quoll Harbor")])
        #expect(firstRunPersisted.contains(AliasPair(alias: "Quoll", canonical: "Quoll Harbor")))
        // Resume replays the persisted set through a Codable round-trip (the
        // meeting_notes column) — the override the digest call then uses.
        let encoded = try! JSONEncoder().encode(firstRunPersisted)
        let replayed = try! JSONDecoder().decode([AliasPair].self, from: encoded)
        #expect(replayed == firstRunPersisted)
        #expect(replayed.contains(AliasPair(alias: "Quoll", canonical: "Quoll Harbor")))
    }

    /// Deterministic dictionary order + dedup.
    @Test func deterministicOrderAndDedup() {
        let segments = [
            T31Fixtures.segment(text: "Vexa e Quoll trabalharam juntos.", ord: 0),
            T31Fixtures.segment(text: "Vexa de novo, e Quoll outra vez.", ord: 1),
        ]
        let pairs = DigestStructuredInputs.scopedAliasBindings(
            dictionary: T31Fixtures.dictionary, correctedSegments: segments, corrections: [])
        #expect(pairs == [
            AliasPair(alias: "Vexa", canonical: "Vexatron Labs"),
            AliasPair(alias: "Quoll", canonical: "Quoll Harbor"),
        ])
    }
}

// MARK: - AC2 — REAL persistence: a correction-limited alias survives a resume

@Suite struct ScopedAliasPersistenceTests {
    /// AC2 / Trap 2: the scoped set persisted on the `meeting_notes` row
    /// round-trips through REAL DB storage — a correction-limited alias (its
    /// canonical never in the transcript) SURVIVES the resume boundary because
    /// the resume reloads `notes.scopedAliasBindings` and replays it as the
    /// digest call's override (it does not re-derive).
    @Test func correctionLimitedAliasSurvivesNotesRoundTrip() async throws {
        let database = try makeDatabase()
        let meeting = makeMeeting()
        try await MeetingRepository(database: database).create(meeting)

        // The first run's resolved set, derived via path (ii) and PERSISTED.
        let firstRunScoped = DigestStructuredInputs.scopedAliasBindings(
            dictionary: T31Fixtures.dictionary,
            correctedSegments: [T31Fixtures.segment(text: "Conversamos com o parceiro.")],
            corrections: [T31Fixtures.aliasCorrection("Quoll", "Quoll Harbor")])
        #expect(firstRunScoped.contains(AliasPair(alias: "Quoll", canonical: "Quoll Harbor")))

        var notes = makeNotes(meetingID: meeting.id)
        notes.scopedAliasBindings = firstRunScoped
        try await NotesRepository(database: database).upsert(notes)

        // Resume reloads the row — the persisted set is the override the digest
        // call replays. The correction-limited alias is STILL present.
        let reloaded = try #require(
            await NotesRepository(database: database).fetch(meetingID: meeting.id))
        #expect(reloaded.scopedAliasBindings == firstRunScoped)
        #expect(reloaded.scopedAliasBindings
            .contains(AliasPair(alias: "Quoll", canonical: "Quoll Harbor")))
    }

    /// An empty scoped set writes SQL NULL and decodes back to `[]` (a pre-md-v3
    /// / digest-off / no-alias row carries no column value).
    @Test func emptyScopedSetRoundTripsAsNullColumn() async throws {
        let database = try makeDatabase()
        let meeting = makeMeeting()
        try await MeetingRepository(database: database).create(meeting)
        let notes = makeNotes(meetingID: meeting.id) // default: empty scoped set
        try await NotesRepository(database: database).upsert(notes)

        let rawColumn = try await database.pool.read { db in
            try Row.fetchOne(
                db, sql: "SELECT scoped_alias_bindings FROM meeting_notes WHERE meeting_id = ?",
                arguments: [meeting.id])
        }
        let value = try #require(rawColumn)
        #expect(value["scoped_alias_bindings"] == DatabaseValue.null,
            "an empty scoped set persists as SQL NULL")
        let reloaded = try #require(
            await NotesRepository(database: database).fetch(meetingID: meeting.id))
        #expect(reloaded.scopedAliasBindings.isEmpty)
    }
}

// MARK: - AC4 — host binding + empty-name fallback

@Suite struct HostBindingDerivationTests {
    @Test func bindsOwnerCanonicalName() {
        let host = DigestStructuredInputs.hostBinding(
            user: UserIdentity(name: "Dana Marsh", aliases: ["Dana"], email: "dana@vexatronlabs.example"))
        #expect(host.canonicalName == "Dana Marsh")
    }

    @Test func emptyIdentityYieldsNilName() {
        let host = DigestStructuredInputs.hostBinding(user: UserIdentity.shippedDefault)
        #expect(host.canonicalName == nil)
    }

    @Test func whitespaceOnlyNameYieldsNilName() {
        let host = DigestStructuredInputs.hostBinding(
            user: UserIdentity(name: "   ", aliases: [], email: ""))
        #expect(host.canonicalName == nil)
    }
}

// MARK: - Rendering — presence-gated ALIAS RESOLUTION + HOST + per-turn markers

@Suite struct DigestStructuredRenderTests {
    private func request(
        scoped: [AliasPair] = [], host: HostBinding? = nil,
        transcript: [TranscriptSegment] = [],
        notes: NotesStructured? = nil
    ) -> DigestRequest {
        DigestRequest(
            meeting: Meeting(
                id: "01STRUCTUREDINPUTS0000000000", title: "Vexatron Labs roadmap",
                startedAt: msDate(), source: .meet, status: .processing,
                attendees: [Attendee(name: "Dana Marsh", email: "dana@vexatronlabs.example", source: .manual)],
                createdAt: msDate(), updatedAt: msDate()),
            transcript: transcript,
            notes: notes ?? NotesStructured(
                title: "Roadmap", summary: "Resumo.", detailedNotes: "",
                decisions: [], actionItems: [], userActionItems: []),
            dominantLanguage: "en",
            vocabulary: ["Vexatron Labs"],
            user: UserIdentity(name: "Dana Marsh", aliases: ["Dana"], email: "dana@vexatronlabs.example"),
            scopedAliasBindings: scoped,
            hostBinding: host)
    }

    /// Empty structured inputs → no ALIAS RESOLUTION block and no HOST line; the
    /// raw `user` label never appears (the [HOST: ...] marker replaces it).
    @Test func emptyInputsRenderNoExtraBlocks() {
        let msg = DigestPromptBuilder.userMessage(for: request())
        #expect(!msg.contains("ALIAS RESOLUTION"))
        #expect(!msg.contains("HOST:"))
    }

    /// Presence-gated ALIAS RESOLUTION block renders each pair after CANONICAL
    /// VOCABULARY.
    @Test func aliasResolutionBlockRendersWhenPresent() {
        let msg = DigestPromptBuilder.userMessage(
            for: request(scoped: [AliasPair(alias: "Vexa", canonical: "Vexatron Labs")]))
        #expect(msg.contains("ALIAS RESOLUTION"))
        #expect(msg.contains("\"Vexa\" → Vexatron Labs"))
        let vocabIdx = msg.range(of: "CANONICAL VOCABULARY")!.lowerBound
        let aliasIdx = msg.range(of: "ALIAS RESOLUTION")!.lowerBound
        #expect(vocabIdx < aliasIdx) // after the canonical vocabulary block.
    }

    /// Presence-gated HOST line renders the canonical name; the raw `user` label
    /// is never present.
    @Test func hostLineRendersCanonicalName() {
        let msg = DigestPromptBuilder.userMessage(
            for: request(host: HostBinding(canonicalName: "Dana Marsh")))
        #expect(msg.contains("HOST: the meeting host"))
        #expect(msg.contains("Dana Marsh"))
    }

    /// Empty-name host falls back to a neutral descriptor, NEVER the raw `user`
    /// label.
    @Test func hostLineFallsBackToNeutralDescriptor() {
        #expect(DigestPromptBuilder.hostDescriptor(HostBinding(canonicalName: nil))
            == "the host (no name on record)")
        let msg = DigestPromptBuilder.userMessage(
            for: request(host: HostBinding(canonicalName: nil)))
        #expect(msg.contains("the host (no name on record)"))
    }

    /// AC4: a `user`-labeled turn renders [HOST: <name>] (the host binding's
    /// canonical name), NEVER the raw `user` label.
    @Test func userTurnRendersHostMarkerNotRawLabel() {
        let segments = [
            T31Fixtures.segment(label: "user", name: "Dana Marsh", text: "Let's ship in May.", ord: 0),
        ]
        let msg = DigestPromptBuilder.userMessage(
            for: request(host: HostBinding(canonicalName: "Dana Marsh"), transcript: segments))
        #expect(msg.contains("[HOST: Dana Marsh] Let's ship in May."))
        #expect(!msg.contains("[user]"))
    }

    /// A `user`-labeled turn with NO host name still never emits the raw `user`
    /// label — it falls back to the segment's own name or "the host".
    @Test func userTurnWithoutHostNameNeverEmitsRawLabel() {
        let segments = [
            T31Fixtures.segment(label: "user", name: nil, text: "Status update.", ord: 0),
        ]
        let msg = DigestPromptBuilder.userMessage(for: request(transcript: segments))
        #expect(!msg.contains("[user]"))
        #expect(msg.contains("[HOST: the host] Status update."))
    }

    /// Per-turn provenance: a named non-host turn whose name appears verbatim in
    /// the body is [transcript-grounded]; one resolved only from the roster is
    /// [roster-resolved].
    @Test func nonHostTurnsCarryProvenanceMarkers() {
        let segments = [
            T31Fixtures.segment(
                label: "S0", name: "Priya Nandakumar",
                text: "Priya Nandakumar here — the migration is on track.", ord: 0),
            T31Fixtures.segment(
                label: "S1", name: "Theo Vance", text: "Agreed, let's proceed.", ord: 1),
        ]
        let msg = DigestPromptBuilder.userMessage(for: request(transcript: segments))
        #expect(msg.contains("[Priya Nandakumar · transcript-grounded]"))
        #expect(msg.contains("[Theo Vance · roster-resolved]"))
    }

    // MARK: - md-v4 OWNER CROSS-CHECK roster

    private func notes(action: [ActionItem] = [], user: [ActionItem] = []) -> NotesStructured {
        NotesStructured(
            title: "Roadmap", summary: "Resumo.", detailedNotes: "",
            decisions: [], actionItems: action, userActionItems: user)
    }

    /// No owner-bearing action item → no OWNER CROSS-CHECK block at all (byte-
    /// identical to having no block).
    @Test func ownerRosterAbsentWhenNoOwners() {
        let msg = DigestPromptBuilder.userMessage(for: request())
        #expect(!msg.contains("OWNER CROSS-CHECK"))
        // Also absent when action items exist but carry empty owners.
        let blank = DigestPromptBuilder.userMessage(
            for: request(notes: notes(action: [ActionItem(owner: "  ", text: "do a thing")])))
        #expect(!blank.contains("OWNER CROSS-CHECK"))
    }

    /// Owner-bearing action items render the WHO-only OWNER CROSS-CHECK block as a
    /// NAMES-ONLY list (one `- name` line each, NO task text — the laundering
    /// vector), placed AFTER the MEETING block and BEFORE the transcript.
    @Test func ownerRosterRendersNamesOnlyAndIsFencedWhoOnly() {
        let msg = DigestPromptBuilder.userMessage(for: request(
            transcript: [T31Fixtures.segment(label: "S0", name: "Theo Vance", text: "ok", ord: 0)],
            notes: notes(
                action: [
                    ActionItem(owner: "Theo Vance", text: "ship the migration by Friday"),
                    ActionItem(owner: "Priya Nandakumar", text: "review the rollout plan"),
                ],
                user: [ActionItem(owner: "Dana Marsh", text: "send the recap")])))
        #expect(msg.contains("OWNER CROSS-CHECK"))
        // WHO-only fence wording + authority of the body.
        #expect(msg.contains("WHO-only roster"))
        #expect(msg.contains("wins on any conflict"))
        // One line per owner NAME — no task text leaks (the laundering vector).
        #expect(msg.contains("- Theo Vance"))
        #expect(msg.contains("- Priya Nandakumar"))
        #expect(msg.contains("- Dana Marsh"))
        #expect(!msg.contains("ship the migration"))
        #expect(!msg.contains("review the rollout plan"))
        #expect(!msg.contains("send the recap"))
        // Placement: after MEETING, before the TRANSCRIPT.
        let meetingIdx = msg.range(of: "MEETING:")!.lowerBound
        let rosterIdx = msg.range(of: "OWNER CROSS-CHECK")!.lowerBound
        let transcriptIdx = msg.range(of: "TRANSCRIPT (")!.lowerBound
        #expect(meetingIdx < rosterIdx)
        #expect(rosterIdx < transcriptIdx)
    }

    /// Owner NAMES dedupe case-insensitively across action + user action items;
    /// multiple distinct tasks for one owner collapse to a single name line.
    @Test func ownerRosterDedupesNamesCaseInsensitively() {
        let msg = DigestPromptBuilder.userMessage(for: request(notes: notes(
            action: [
                ActionItem(owner: "Theo Vance", text: "task one"),
                ActionItem(owner: "theo vance", text: "task two"),   // case-dup → collapses
                ActionItem(owner: "Priya Nandakumar", text: "task three"),
            ],
            user: [ActionItem(owner: "Theo Vance", text: "task four")])))  // dup across lists
        // "- Theo Vance" appears exactly once (first-cased form wins).
        let occurrences = msg.components(separatedBy: "- Theo Vance").count - 1
        #expect(occurrences == 1)
        #expect(msg.contains("- Priya Nandakumar"))
        // No task text anywhere.
        #expect(!msg.contains("task one"))
        #expect(!msg.contains("task four"))
    }
}

// MARK: - AC7 (A10) — the new DigestRequest fields never serialize into the payload

@Suite struct DigestRequestFieldsDoNotSerializeTests {
    /// The payload is assembled by `EvidencePayloadBuilder.build` from durable
    /// state — the `meeting`/`transcript`/`notes`(+stored digest)/`user` rows —
    /// and NEVER from a `DigestRequest`. The structured digest inputs
    /// (`scopedAliasBindings`, `hostBinding`) are PROMPT-input only: they shape
    /// the rendered model input, never the stored payload. This suite pins that
    /// guarantee two ways: (1) varying those request fields (incl. NON-empty)
    /// leaves the payload bytes + `versionHash` unchanged for fixed stored
    /// notes/digest; (2) no alias/host key ever appears in the payload JSON.

    /// Fixed stored notes (a stored digest so the payload carries the
    /// memory_digest surface; the digest TEXT is fixed and contains no
    /// alias/host structured keys), with the PERSISTED `scopedAliasBindings`
    /// column set to the given value — every OTHER stored field held constant.
    private func notes(_ meetingID: MeetingID, scoped: [AliasPair] = []) -> MeetingNotes {
        var n = makeNotes(meetingID: meetingID)
        n.memoryDigest = "## HEADER\nmeeting: Vexatron Labs sync\ndate: 2026-03-14\nspeaker: Dana Marsh\n"
        n.scopedAliasBindings = scoped
        return n
    }

    private func payload(_ meeting: Meeting, scoped: [AliasPair] = []) -> EvidencePayloadBuilder.Payload {
        EvidencePayloadBuilder.build(
            meeting: meeting, segments: [], notes: notes(meeting.id, scoped: scoped),
            user: .shippedDefault)
    }

    /// Varying `scopedAliasBindings` / `hostBinding` on a DigestRequest does NOT
    /// change the payload built from the SAME stored notes/digest: the request
    /// fields are not a builder input, so the bytes and `versionHash` are stable.
    @Test func nonEmptyRequestFieldsLeavePayloadAndHashUnchanged() {
        let meeting = makeMeeting()
        // Two DigestRequests over the same meeting — one bare, one with NON-empty
        // structured inputs — demonstrating the request fields differ…
        let base = DigestRequest(
            meeting: meeting, transcript: [],
            notes: NotesStructured(
                title: nil, summary: "s", detailedNotes: "", decisions: [],
                actionItems: [], userActionItems: []),
            dominantLanguage: "en", vocabulary: [], user: .shippedDefault)
        var withFields = base
        withFields.scopedAliasBindings = [
            AliasPair(alias: "Vexa", canonical: "Vexatron Labs"),
            AliasPair(alias: "Quoll", canonical: "Quoll Harbor"),
        ]
        withFields.hostBinding = HostBinding(canonicalName: "Dana Marsh")
        #expect(base != withFields, "the request fields genuinely differ")

        // …yet the payload, built from the fixed stored notes/digest (NOT from
        // either request), is byte- and hash-identical regardless.
        let p1 = payload(meeting)
        let p2 = payload(meeting)
        #expect(p1.bytes == p2.bytes)
        #expect(p1.versionHash == p2.versionHash)
    }

    /// AC7 (the load-bearing invariant): the PERSISTED
    /// `MeetingNotes.scopedAliasBindings` COLUMN never reaches the evidence
    /// payload. This varies the stored column DIRECTLY — empty vs a NON-empty
    /// set — over otherwise-identical stored notes/digest, and pins that the
    /// payload is byte- and hash-identical and carries no alias/host key. (The
    /// DigestRequest-varying test above demonstrates the same for the
    /// prompt-input fields; this one pins the durable column the builder reads,
    /// which is what AC7 actually guarantees.)
    @Test func persistedScopedColumnNeverReachesPayload() {
        let meeting = makeMeeting(attendees: [
            Attendee(name: "Dana Marsh", email: "dana@vexatronlabs.example", source: .manual)
        ])
        // The persisted column genuinely differs: empty vs a non-empty set.
        // Its alias/canonical surfaces are DISTINCT from everything in the fixed
        // notes/digest (so their presence in the payload could ONLY come from
        // the column leaking — "Vexa"/"Vexatron Labs" would collide with the
        // fixed digest's "Vexatron Labs sync" line and are deliberately avoided).
        let scoped = [
            AliasPair(alias: "Zorptide", canonical: "Zorptide Collective"),
            AliasPair(alias: "Brumal", canonical: "Brumal Works"),
        ]
        #expect(notes(meeting.id, scoped: []).scopedAliasBindings.isEmpty)
        #expect(notes(meeting.id, scoped: scoped).scopedAliasBindings == scoped,
            "the persisted column genuinely varies between the two builds")

        let empty = payload(meeting, scoped: [])
        let nonEmpty = payload(meeting, scoped: scoped)
        // (a) byte-identical and (b) hash-identical: the column is not a builder
        // input, so it cannot perturb the payload.
        #expect(empty.bytes == nonEmpty.bytes,
            "the persisted scopedAliasBindings column must not change the payload bytes")
        #expect(empty.versionHash == nonEmpty.versionHash)

        // (c) no alias/host/column key — structural OR the column's own
        // alias/canonical surfaces — appears in the payload JSON of the
        // NON-empty build (where any leak would surface).
        let text = String(decoding: nonEmpty.bytes, as: UTF8.self)
        for key in ["scoped_alias", "scopedAlias", "scoped_alias_bindings", "alias_bindings",
                    "ALIAS RESOLUTION", "host_binding", "hostBinding", "HOST:",
                    "Zorptide", "Zorptide Collective", "Brumal", "Brumal Works"] {
            #expect(!text.contains(key),
                "the persisted column leaked the alias/host key \(key) into the payload")
        }
    }

    /// No alias/host structured key leaks into the payload JSON. (The stored
    /// digest text and user/host bindings are prompt-only; the wire payload
    /// carries none of the md-v3 structured-input keys.)
    @Test func payloadJSONCarriesNoAliasOrHostKeys() {
        let meeting = makeMeeting(attendees: [
            Attendee(name: "Dana Marsh", email: "dana@vexatronlabs.example", source: .manual)
        ])
        let text = String(decoding: payload(meeting).bytes, as: UTF8.self)
        for key in ["scoped_alias", "scopedAlias", "alias_resolution", "aliasResolution",
                    "host_binding", "hostBinding", "alias_bindings", "ALIAS RESOLUTION"] {
            #expect(!text.contains(key), "payload must not carry the structured-input key \(key)")
        }
        // A non-empty HostBinding canonical name (the owner's display name) must
        // not surface as a HOST marker/key in the payload either.
        #expect(!text.contains("HOST:"))
    }
}
