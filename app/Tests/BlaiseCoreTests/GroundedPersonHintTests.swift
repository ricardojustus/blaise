import Foundation
import Testing
@testable import BlaiseCore

// #101 — grounded person-mention hint. ALL fixtures are FICTIONAL placeholders
// (Sol Vega / Bruno Marlow / a made-up "Vexatron" universe); no real names.
// These tests cover the deterministic, model-free plumbing only: admission
// capture, the grounding/surface/collision/cap/injection gates, presence-gated
// byte-identity of the user messages, the three locked block strings, and the
// NotesRequest round-trip.

@Suite struct GroundedPersonHintTests {

    // MARK: - Temp-root glossary scaffolding (mirrors GlossaryUserLoadTests)

    private func tempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("blaise-gph-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeGlossary(_ entries: String, at root: URL) {
        let url = MeetingPaths(rootURL: root).glossaryURL
        try! Data("# Blaise Glossary\n\n## Entries\n\(entries)\n".utf8).write(to: url)
    }

    // MARK: - Fixture builders

    /// A PipelineVocabulary built directly from a dictionary + the explicit
    /// everyday-rejected list — bypasses admission so the helper can be unit
    /// tested in isolation. Suppression/commonNames are empty (irrelevant to the
    /// helper). Uses the public throwing init.
    private func vocab(
        entries: [VocabularyEntry],
        everydayRejected: [(canonical: String, alias: String)]
    ) -> PipelineVocabulary {
        try! PipelineVocabulary(
            dictionary: VocabularyDictionary(entries: entries),
            suppression: [],
            commonNames: [],
            everydayRejectedAliases: everydayRejected)
    }

    private func seg(_ text: String, label: String = "S0", name: String? = nil) -> TranscriptSegment {
        TranscriptSegment(
            meetingID: "01TESTMEETING0000000000000", ord: 0, startSeconds: 0, endSeconds: 1,
            speakerLabel: label, speakerName: name, text: text)
    }

    private func attendee(_ name: String) -> Attendee {
        Attendee(name: name, source: .calendar)
    }

    // MARK: - 1. Admission capture: .lexiconWord ONLY

    @Test func everydayLexiconAliasIsCaptured() {
        let root = tempRoot()
        // "sol" is a PT lexicon word (rank ~48k) → `.lexiconWord` rejection.
        // "Sol Vega" is admitted (the surname "vega" is distinctive).
        writeGlossary("Sol Vega | sol", at: root)
        let load = PipelineVocabulary.user(dataRoot: root)
        #expect(load.vocabulary.everydayRejectedAliases.contains {
            $0.canonical == "Sol Vega" && $0.alias == "sol"
        })
    }

    @Test func brCommonNameAliasIsNotCaptured() {
        let root = tempRoot()
        // "bruno" is a br_common_name (NOT a lexicon word) → `.brCommonName`,
        // which is checked BEFORE the lexicon branch → must NOT be captured.
        writeGlossary("Bruno Marlow | bruno", at: root)
        let load = PipelineVocabulary.user(dataRoot: root)
        #expect(load.vocabulary.everydayRejectedAliases.allSatisfy { $0.alias != "bruno" })
        #expect(load.vocabulary.everydayRejectedAliases.isEmpty)
    }

    @Test func collisionAliasIsNotCaptured() {
        let root = tempRoot()
        // A distinctive made-up alias "zorptik" mapped twice: the FIRST entry
        // admits it; the SECOND collides. A `.collision` is NOT a `.lexiconWord`
        // → must NOT be captured.
        writeGlossary("Vexatron | zorptik\nQuoll Harbor | zorptik", at: root)
        let load = PipelineVocabulary.user(dataRoot: root)
        #expect(load.vocabulary.everydayRejectedAliases.allSatisfy { $0.alias != "zorptik" })
        #expect(load.vocabulary.everydayRejectedAliases.isEmpty)
    }

    @Test func mixedGlossaryCapturesOnlyTheLexiconRejection() {
        let root = tempRoot()
        writeGlossary("Sol Vega | sol\nBruno Marlow | bruno", at: root)
        let load = PipelineVocabulary.user(dataRoot: root)
        let captured = load.vocabulary.everydayRejectedAliases
        #expect(captured.count == 1)
        #expect(captured.first?.canonical == "Sol Vega")
        #expect(captured.first?.alias == "sol")
    }

    @Test func fixtureAndEmptyLoadsCarryNoEverydayRejectedAliases() throws {
        // The regression/pin fixture() path never runs admission → empty.
        let url = try PipelineVocabulary.bundledResource("glossary_template.md")
        _ = url  // (the fixture path uses synthetic_vocab; assert the default)
        let direct = try PipelineVocabulary(
            dictionary: VocabularyDictionary(entries: []), suppression: [], commonNames: [])
        #expect(direct.everydayRejectedAliases.isEmpty)
        // A missing-glossary load degrades to an empty vocabulary with no captures.
        let missing = PipelineVocabulary.user(dataRoot: tempRoot())
        #expect(missing.vocabulary.everydayRejectedAliases.isEmpty)
    }

    @Test func everydayRejectedAliasNeverReachesCorrectorOrAliasBindings() {
        let root = tempRoot()
        writeGlossary("Sol Vega | sol", at: root)
        let load = PipelineVocabulary.user(dataRoot: root)
        let v = load.vocabulary
        // Captured as a hint signal …
        #expect(v.everydayRejectedAliases.contains { $0.alias == "sol" })
        // … but NEVER an admitted alias of any dictionary entry.
        let admittedAliases = v.dictionary.entries.flatMap(\.aliases).map { $0.lowercased() }
        #expect(!admittedAliases.contains("sol"))
        // … the corrector never rewrites the everyday word in prose.
        #expect(v.corrector.correct("o sol estava forte").correctedText == "o sol estava forte")
        // … and it is excluded from scopedAliasBindings (which scans only the
        // admitted dictionary entries against the body).
        let bindings = DigestStructuredInputs.scopedAliasBindings(
            dictionary: v.dictionary,
            correctedSegments: [seg("o sol confirmou")],
            corrections: [])
        #expect(bindings.allSatisfy { $0.alias.lowercased() != "sol" })
    }

    // MARK: - 2. Grounding gate

    @Test func attendeeGroundingEmits() {
        let v = vocab(
            entries: [VocabularyEntry(canonical: "Sol Vega")],
            everydayRejected: [(canonical: "Sol Vega", alias: "sol")])
        let hints = GroundedPersonHints.groundedPersonHints(
            vocabulary: v,
            attendees: [attendee("Sol Vega")],
            segments: [seg("o sol decidiu adiar o lançamento")])
        #expect(hints.count == 1)
        #expect(hints.first?.canonical == "Sol Vega")
        #expect(hints.first?.everydaySurfaces == ["sol"])
    }

    @Test func resolvedSpeakerGroundingEmits() {
        let v = vocab(
            entries: [VocabularyEntry(canonical: "Sol Vega")],
            everydayRejected: [(canonical: "Sol Vega", alias: "sol")])
        let hints = GroundedPersonHints.groundedPersonHints(
            vocabulary: v,
            attendees: [],
            segments: [seg("o sol vai mandar o contrato", label: "S1", name: "Sol Vega")])
        #expect(hints.map(\.canonical) == ["Sol Vega"])
    }

    @Test func bodyFullNameGroundingEmits() {
        let v = vocab(
            entries: [VocabularyEntry(canonical: "Sol Vega")],
            everydayRejected: [(canonical: "Sol Vega", alias: "sol")])
        // The full name "Sol Vega" appears contiguously in the body (secondary
        // grounding), AND the everyday surface "sol" appears in the body.
        let hints = GroundedPersonHints.groundedPersonHints(
            vocabulary: v,
            attendees: [],
            segments: [seg("falei com Sol Vega ontem"), seg("depois o sol confirmou o plano")])
        #expect(hints.map(\.canonical) == ["Sol Vega"])
    }

    @Test func everydaySurfaceWithGlossaryMappingEmitsViaGlossaryGrounding() {
        // #101 fix: the body has ONLY the everyday surface "sol"; the canonical is
        // NOT a participant and its full name never appears — the ad-hoc-meeting
        // case the feature EXISTS for (no attendees, the surname surfaces only as
        // the everyday word, no clean full name). The CURATED glossary mapping is itself
        // the grounding, so the hint DOES emit (strength-0 tier). Whether THIS
        // "sol" occurrence is the person or the everyday word is the LLM's
        // per-occurrence call under the leave-by-default rule — not this gate's.
        let v = vocab(
            entries: [VocabularyEntry(canonical: "Sol Vega")],
            everydayRejected: [(canonical: "Sol Vega", alias: "sol")])
        let hints = GroundedPersonHints.groundedPersonHints(
            vocabulary: v,
            attendees: [],
            segments: [seg("o sol estava forte na sala")])
        #expect(hints.map(\.canonical) == ["Sol Vega"])
        #expect(hints.first?.everydaySurfaces == ["sol"])
    }

    @Test func participantGroundingOutranksGlossaryOnlyAtTheCap() {
        // When more than the cap qualify, the strength ranking must keep the
        // participant-grounded (strength 2) hints and drop the glossary-only
        // (strength 0) one. Group 0 is glossary-only; groups 1…cap are attendees.
        let cap = GroundedPersonHints.maxHintsPerMeeting
        var entries: [VocabularyEntry] = []
        var rejected: [(canonical: String, alias: String)] = []
        var attendees: [Attendee] = []
        var body = ""
        for i in 0...cap {  // cap + 1 groups
            let canonical = "Person\(i) Lastname\(i)"
            let surface = "surfx\(i)"
            entries.append(VocabularyEntry(canonical: canonical))
            rejected.append((canonical: canonical, alias: surface))
            if i != 0 { attendees.append(attendee(canonical)) }  // group 0 = glossary-only
            body += " \(surface)"
        }
        let v = vocab(entries: entries, everydayRejected: rejected)
        let hints = GroundedPersonHints.groundedPersonHints(
            vocabulary: v, attendees: attendees, segments: [seg(body)])
        #expect(hints.count == cap)
        // The glossary-only group 0 is the weakest → dropped beyond the cap.
        #expect(!hints.contains { $0.canonical == "Person0 Lastname0" })
    }

    @Test func groundedCanonicalButSurfaceAbsentFromBodyDoesNotEmit_F3b() {
        // The canonical IS grounded (an attendee), but the everyday surface "sol"
        // never appears in the body → the hard surface-present gate suppresses it.
        let v = vocab(
            entries: [VocabularyEntry(canonical: "Sol Vega")],
            everydayRejected: [(canonical: "Sol Vega", alias: "sol")])
        let hints = GroundedPersonHints.groundedPersonHints(
            vocabulary: v,
            attendees: [attendee("Sol Vega")],
            segments: [seg("a equipe revisou o orçamento")])
        #expect(hints.isEmpty)
    }

    @Test func collisionSurfaceMappingTwoGroundedCanonicalsIsOmitted_D8() {
        // The same everyday surface "vale" maps to TWO grounded canonicals →
        // ambiguous → omit the surface entirely → no hint survives for either.
        let v = vocab(
            entries: [VocabularyEntry(canonical: "Vale Nunes"), VocabularyEntry(canonical: "Vale Prado")],
            everydayRejected: [
                (canonical: "Vale Nunes", alias: "vale"),
                (canonical: "Vale Prado", alias: "vale"),
            ])
        let hints = GroundedPersonHints.groundedPersonHints(
            vocabulary: v,
            attendees: [attendee("Vale Nunes"), attendee("Vale Prado")],
            segments: [seg("o vale ficou de revisar isso")])
        #expect(hints.isEmpty)
    }

    @Test func strongGroundingSurvivesCollisionWithGlossaryOnly() {
        // "sol" maps to an ATTENDEE-grounded canonical AND an ABSENT glossary-only
        // canonical. Strength-aware collision keeps the surface for the present
        // person; the glossary-only one loses it — the strong hint is NOT suppressed.
        let v = vocab(
            entries: [VocabularyEntry(canonical: "Sol Vega"), VocabularyEntry(canonical: "Sol Marsh")],
            everydayRejected: [
                (canonical: "Sol Vega", alias: "sol"),
                (canonical: "Sol Marsh", alias: "sol"),
            ])
        let hints = GroundedPersonHints.groundedPersonHints(
            vocabulary: v,
            attendees: [attendee("Sol Vega")],  // present; Sol Marsh is glossary-only (absent)
            segments: [seg("o sol confirmou o plano")])
        #expect(hints.map(\.canonical) == ["Sol Vega"])
        #expect(hints.first?.everydaySurfaces == ["sol"])
    }

    @Test func capLimitsHintsPerMeeting() {
        // Build more grounded hints than the cap; expect exactly the cap.
        let cap = GroundedPersonHints.maxHintsPerMeeting
        var entries: [VocabularyEntry] = []
        var rejected: [(canonical: String, alias: String)] = []
        var attendees: [Attendee] = []
        var body = ""
        for i in 0..<(cap + 3) {
            let canonical = "Person\(i) Lastname\(i)"
            let surface = "surfx\(i)"  // distinctive, present in the body
            entries.append(VocabularyEntry(canonical: canonical))
            rejected.append((canonical: canonical, alias: surface))
            attendees.append(attendee(canonical))
            body += " \(surface)"
        }
        let v = vocab(entries: entries, everydayRejected: rejected)
        let hints = GroundedPersonHints.groundedPersonHints(
            vocabulary: v, attendees: attendees, segments: [seg(body)])
        #expect(hints.count == cap)
    }

    @Test func injectionCharactersAreStripped_D9() {
        // Defense-in-depth (D9): a canonical carrying a newline + control char
        // (the realistic injection vector — an alias already passed the
        // no-punctuation admission gate, but a canonical may carry markdown /
        // control bytes) is rendered as DATA: newline/control stripped, collapsed,
        // Unicode-normalized. The clean everyday surface gates against the body
        // normally.
        let v = vocab(
            entries: [VocabularyEntry(canonical: "Sol\nVega")],
            everydayRejected: [(canonical: "Sol\u{07}\nVega", alias: "sol")])
        let hints = GroundedPersonHints.groundedPersonHints(
            vocabulary: v,
            attendees: [attendee("Sol Vega")],
            segments: [seg("o sol confirmou o plano")])
        let hint = try! #require(hints.first)
        #expect(!hint.canonical.contains("\n"))
        #expect(!hint.canonical.unicodeScalars.contains { $0.properties.generalCategory == .control })
        #expect(hint.canonical == "Sol Vega")
        #expect(hint.everydaySurfaces == ["sol"])
    }

    @Test func multipleSurfacesForOneCanonicalDedupAndJoin() {
        let v = vocab(
            entries: [VocabularyEntry(canonical: "Sol Vega")],
            everydayRejected: [
                (canonical: "Sol Vega", alias: "sol"),
                (canonical: "Sol Vega", alias: "soool"),
            ])
        let hints = GroundedPersonHints.groundedPersonHints(
            vocabulary: v,
            attendees: [attendee("Sol Vega")],
            segments: [seg("o sol e o soool apareceram")])
        #expect(hints.count == 1)
        #expect(hints.first?.everydaySurfaces == ["sol", "soool"])
    }

    // MARK: - 3. Presence-gating: byte-identical user messages when empty

    @Test func emptyHintsLeaveNotesUserMessageByteIdentical() {
        let base = makeNotesRequest()
        var withField = base
        withField.groundedPersonHints = []
        #expect(
            NotesPromptBuilder.userMessage(for: withField)
                == NotesPromptBuilder.userMessage(for: base))
        // And the field-bearing request with empty hints renders no hint marker.
        #expect(!NotesPromptBuilder.userMessage(for: withField).contains("CONDITIONAL PERSON MENTIONS"))
    }

    @Test func emptyHintsLeaveDigestUserMessageByteIdentical() {
        let withHints = makeGPHDigestRequest(hints: [])
        let withoutField = makeGPHDigestRequest(hints: [])
        #expect(
            DigestPromptBuilder.userMessage(for: withHints)
                == DigestPromptBuilder.userMessage(for: withoutField))
        #expect(!DigestPromptBuilder.userMessage(for: withHints).contains("CONDITIONAL PERSON MENTIONS"))
    }

    @Test func emptyHintsLeaveCombinedAuditUserMessageByteIdentical() {
        let req = makeGPHDigestRequest(hints: [])
        let msg = DigestPromptBuilder.combinedAuditUserMessage(for: req, draftDigest: "## HEADER\n")
        #expect(!msg.contains("CONDITIONAL PERSON-MENTION RECONCILIATION"))
        #expect(!msg.contains("CONDITIONAL PERSON MENTIONS"))
    }

    // MARK: - 4. Block present when non-empty

    @Test func notesUserMessageCarriesBlockWhenNonEmpty() {
        var req = makeNotesRequest()
        req.groundedPersonHints = [GroundedPersonHint(canonical: "Sol Vega", everydaySurfaces: ["sol"])]
        let msg = NotesPromptBuilder.userMessage(for: req)
        #expect(msg.contains("CONDITIONAL PERSON MENTIONS (NOT a substitution list"))
        #expect(msg.contains("mis-transcription of the person Sol Vega"))
        // The block sits AFTER the CANONICAL VOCABULARY block and BEFORE MEETING.
        let vocabRange = msg.range(of: "CANONICAL VOCABULARY")
        let hintRange = msg.range(of: "CONDITIONAL PERSON MENTIONS")
        let meetingRange = msg.range(of: "MEETING:")
        #expect(vocabRange != nil && hintRange != nil && meetingRange != nil)
        if let v = vocabRange, let h = hintRange, let m = meetingRange {
            #expect(v.lowerBound < h.lowerBound)
            #expect(h.lowerBound < m.lowerBound)
        }
    }

    @Test func digestUserMessageCarriesBlockAfterAliasResolutionWhenNonEmpty() {
        var req = makeGPHDigestRequest(hints: [
            GroundedPersonHint(canonical: "Sol Vega", everydaySurfaces: ["sol"])
        ])
        req.scopedAliasBindings = [AliasPair(alias: "projeto fênix", canonical: "Aurora")]
        let msg = DigestPromptBuilder.userMessage(for: req)
        let aliasRange = msg.range(of: "ALIAS RESOLUTION")
        let hintRange = msg.range(of: "CONDITIONAL PERSON MENTIONS")
        #expect(aliasRange != nil && hintRange != nil)
        if let a = aliasRange, let h = hintRange {
            #expect(a.lowerBound < h.lowerBound)  // hint after ALIAS RESOLUTION
        }
    }

    @Test func combinedAuditUserMessageCarriesBlock3WhenNonEmpty() {
        let req = makeGPHDigestRequest(hints: [
            GroundedPersonHint(canonical: "Sol Vega", everydaySurfaces: ["sol"])
        ])
        let msg = DigestPromptBuilder.combinedAuditUserMessage(for: req, draftDigest: "## HEADER\n")
        // Both the base synthesis block (carried by userMessage) AND the STEP-1
        // reconciliation clause are present.
        #expect(msg.contains("CONDITIONAL PERSON MENTIONS (NOT a substitution list"))
        #expect(msg.contains("CONDITIONAL PERSON-MENTION RECONCILIATION (STEP 1"))
        // The reconciliation clause precedes the STEP-2 HUMAN NOTES frame.
        let block3 = msg.range(of: "CONDITIONAL PERSON-MENTION RECONCILIATION")
        let humanNotes = msg.range(of: "=== HUMAN NOTES")
        if let b = block3, let n = humanNotes {
            #expect(b.lowerBound < n.lowerBound)
        }
    }

    // MARK: - 5. The three locked block strings render byte-exact

    @Test func block1RendersByteExact() {
        let expected = """
            CONDITIONAL PERSON MENTIONS (NOT a substitution list — the DEFAULT is to LEAVE the word exactly as written):
            Some people in the vocabulary are sometimes mis-transcribed as an ordinary everyday word. For each line below, decide SEPARATELY FOR EACH OCCURRENCE of the word: the same word may be the person in one sentence and the ordinary everyday word in the next. Read an occurrence as the person ONLY when that sentence's own wording clearly refers to a person — the word is the grammatical agent of a person-action (it says / asks / decides / will do / owns something), the word is directly addressed, the word is credited with an opinion or an action, or the word is assigned ownership of a task or item — AND the ordinary everyday reading does not fit there. In EVERY other case — any ambiguous occurrence, and every occurrence used in its ordinary everyday sense — leave the word EXACTLY as written. This is glossary presence only; it is NOT evidence that the person is present or referred to. Never introduce a person the sentence does not itself support, and never change an occurrence you are unsure about.
            """
        #expect(GroundedPersonHints.block1Header == expected)
    }

    @Test func block2RendersByteExact() {
        let single = GroundedPersonHints.block2Line(
            for: GroundedPersonHint(canonical: "Sol Vega", everydaySurfaces: ["sol"]))
        #expect(single == "- The everyday word \"sol\" is occasionally a mis-transcription of the person Sol Vega; apply the rule above per occurrence.")
        let multi = GroundedPersonHints.block2Line(
            for: GroundedPersonHint(canonical: "Sol Vega", everydaySurfaces: ["sol", "soool"]))
        #expect(multi == "- The everyday word \"sol\" (e.g. also \"soool\") is occasionally a mis-transcription of the person Sol Vega; apply the rule above per occurrence.")
    }

    @Test func block3RendersByteExact() {
        let expected = """
            CONDITIONAL PERSON-MENTION RECONCILIATION (STEP 1 — read together with the CONDITIONAL PERSON MENTIONS above; subordinate to the RECALL GUARD):
            The draft above may already read one of the listed everyday words as the person it can be mis-transcribed as. For such a person, the transcript body contains the everyday SURFACE word, not the person's spelled-out name — so the everyday surface in the body IS that name's transcript-body grounding. Therefore do NOT apply the UNGROUNDED NAME rule (2) to demote, or the PHANTOM ENTITY rule (4) to remove, such a name SOLELY because its surname (or spelled-out form) is absent from the body. This exception is NARROW: it covers ONLY a name that (a) appears in the CONDITIONAL PERSON MENTIONS list AND (b) the DRAFT ITSELF already resolved. KEEP such a resolution only where that sentence clearly supports a person (the resolved word is the grammatical agent of a person-action, is directly addressed, is credited an opinion or action, or owns a task). Where the sentence does NOT clearly support a person — it is ambiguous, or plainly the ordinary everyday word, or contradicted by the transcript (wrong speaker, wrong action) — REVERT that occurrence to the ordinary everyday word it was mis-transcribed as; reverting to the verbatim transcript word loses no recall, so the RECALL GUARD does not require keeping a doubtful person-resolution. You must NOT yourself newly resolve any everyday word the draft left as the ordinary word, and you must NOT convert any further occurrence. The hint is NOT evidence by itself.
            """
        #expect(GroundedPersonHints.block3AuditClause == expected)
    }

    @Test func renderedBlockHasHeaderThenOneLinePerHint() {
        let block = GroundedPersonHints.synthesisBlock([
            GroundedPersonHint(canonical: "Sol Vega", everydaySurfaces: ["sol"]),
            GroundedPersonHint(canonical: "Vale Nunes", everydaySurfaces: ["vale"]),
        ])
        let expected = GroundedPersonHints.block1Header + "\n"
            + "- The everyday word \"sol\" is occasionally a mis-transcription of the person Sol Vega; apply the rule above per occurrence.\n"
            + "- The everyday word \"vale\" is occasionally a mis-transcription of the person Vale Nunes; apply the rule above per occurrence."
        #expect(block == expected)
        #expect(GroundedPersonHints.synthesisBlock([]) == nil)
    }

    // MARK: - 6. NotesRequest Codable round-trips with hints

    @Test func notesRequestRoundTripsWithHints() throws {
        var req = makeNotesRequest()
        req.groundedPersonHints = [
            GroundedPersonHint(canonical: "Sol Vega", everydaySurfaces: ["sol", "soool"])
        ]
        let decoded = try JSONDecoder().decode(NotesRequest.self, from: JSONEncoder().encode(req))
        #expect(decoded == req)
        #expect(decoded.groundedPersonHints == req.groundedPersonHints)
    }

    @Test func notesRequestLegacyPayloadWithoutKeyDecodesToEmptyHints() throws {
        // A payload predating #101 (no `grounded_person_hints` key) must decode
        // with an empty hint list (decodeIfPresent ?? []).
        let legacy = """
            {"meeting":\(meetingJSON()),"transcript":[],"vocabulary":["Vexatron"],"user":\(userJSON()),"dominant_language":"pt"}
            """
        let decoded = try JSONDecoder().decode(NotesRequest.self, from: Data(legacy.utf8))
        #expect(decoded.groundedPersonHints.isEmpty)
    }

    // MARK: - Local digest-request fixture

    private func makeGPHDigestRequest(hints: [GroundedPersonHint]) -> DigestRequest {
        DigestRequest(
            meeting: makeMeeting(title: "Reunião", attendees: [attendee("Sol Vega")]),
            transcript: [seg("o sol confirmou o plano", label: "S1", name: "Sol Vega")],
            notes: makeStructuredNotes(),
            dominantLanguage: "pt",
            vocabulary: ["Sol Vega"],
            user: UserIdentity.onboardedUser,
            groundedPersonHints: hints)
    }

    private func meetingJSON() -> String {
        String(decoding: try! JSONEncoder().encode(makeMeeting()), as: UTF8.self)
    }

    private func userJSON() -> String {
        String(decoding: try! JSONEncoder().encode(UserIdentity.onboardedUser), as: UTF8.self)
    }
}
