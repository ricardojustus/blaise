import CryptoKit
import Foundation
import Testing
@testable import BlaiseCore

// C7's minimal EvidencePayloadBuilder + CanonicalJSONWriter, per the C8 spec
// §payload-assembly (fully pinned there). C8's chunk owns worker/transport.

@Suite struct CanonicalJSONWriterTests {
    private func text(_ value: CanonicalJSONValue) -> String {
        String(decoding: CanonicalJSONWriter.write(value), as: UTF8.self)
    }

    @Test func sortsKeysByteWiseWithTrailingNewline() {
        let value = CanonicalJSONValue.object([
            ("zeta", .integer(1)),
            ("alpha", .integer(2)),
            ("Zeta", .integer(3)),  // 'Z' (0x5A) sorts before 'a' (0x61) byte-wise
            ("alpha2", .integer(4)),
        ])
        #expect(text(value) == "{\"Zeta\":3,\"alpha\":2,\"alpha2\":4,\"zeta\":1}\n")
    }

    @Test func nonASCIIKeysSortByUTF8Bytes() {
        // "é" = 0xC3 0xA9 sorts after every ASCII key.
        let value = CanonicalJSONValue.object([
            ("é", .integer(1)),
            ("z", .integer(2)),
        ])
        #expect(text(value) == "{\"z\":2,\"\u{e9}\":1}\n")
    }

    @Test func escapingTable() {
        // Quotes and backslash escaped; control chars as \u00XX; emoji and
        // accents verbatim UTF-8.
        let value = CanonicalJSONValue.string("a\"b\\c\nd\te\u{01}f é 🎙")
        #expect(text(value) == "\"a\\\"b\\\\c\\u000ad\\u0009e\\u0001f é 🎙\"\n")
    }

    @Test func integersBoolsNullArrays() {
        let value = CanonicalJSONValue.array([
            .integer(0), .integer(-42), .integer(1_770_000_000_000),
            .bool(true), .bool(false), .null,
            .array([]), .object([]),
        ])
        #expect(text(value) == "[0,-42,1770000000000,true,false,null,[],{}]\n")
    }

    @Test func noInsignificantWhitespaceAndByteStability() {
        let value = CanonicalJSONValue.object([
            ("b", .array([.string("x"), .integer(1)])),
            ("a", .object([("nested", .null)])),
        ])
        let first = CanonicalJSONWriter.write(value)
        let second = CanonicalJSONWriter.write(value)
        #expect(first == second)
        #expect(String(decoding: first, as: UTF8.self) == "{\"a\":{\"nested\":null},\"b\":[\"x\",1]}\n")
    }

    @Test func documentParsesAsJSON() throws {
        let value = CanonicalJSONValue.object([
            ("text", .string("linha 1\nlinha 2 \"citação\" — ç")),
            ("n", .integer(7)),
        ])
        let parsed = try JSONSerialization.jsonObject(with: CanonicalJSONWriter.write(value)) as? [String: Any]
        #expect(parsed?["text"] as? String == "linha 1\nlinha 2 \"citação\" — ç")
        #expect(parsed?["n"] as? Int == 7)
    }
}

@Suite struct EvidencePayloadBuilderTests {
    // Explicit identity for the payload golden (G3: the shipped default is now
    // neutral/empty, so the owner must be supplied — an onboarded user).
    private let user = UserIdentity(
        name: "Sam", aliases: ["Sam", "Sam Rivera"], email: "sam.rivera@vexatron.test")

    private func makeFixedMeeting() -> Meeting {
        Meeting(
            id: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
            title: "Reunião fixa",
            startedAt: Date(timeIntervalSince1970: 1_770_000_000),
            endedAt: Date(timeIntervalSince1970: 1_770_000_300),
            source: .imported,
            status: .ready,
            attendees: [
                Attendee(name: "Sam", email: "sam.rivera@vexatron.test", source: .manual),
                Attendee(name: "Mariana Costa", email: nil, source: .manual),
            ],
            dominantLanguage: "pt",
            asrProvenance: ASRProvenance(
                engine: "mlx-whisper-large-v3-turbo",
                model: "mlx-community/whisper-large-v3-turbo",
                runtime: "mlx-whisper/subprocess",
                engineVersion: "0.4.3",
                transcribedAt: Date(timeIntervalSince1970: 1_770_000_100),
                vocabularyHintsApplied: false,
                languageHint: nil),
            createdAt: Date(timeIntervalSince1970: 1_770_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_770_000_200)
        )
    }

    private func makeFixedNotes(meetingID: MeetingID) -> MeetingNotes {
        MeetingNotes(
            meetingID: meetingID,
            markdown: "# Reunião fixa\n\n## Resumo\n\nResumo.\n",
            structured: NotesStructured(
                title: "Reunião fixa",
                summary: "Resumo.",
                detailedNotes: "Detalhes.",
                decisions: ["Decisão 1"],
                actionItems: [ActionItem(owner: "Sam", text: "enviar proposta")],
                userActionItems: [ActionItem(owner: "Sam", text: "enviar proposta")]),
            language: "pt",
            generatedAt: Date(timeIntervalSince1970: 1_770_000_250),
            provenance: NotesProvenance(
                engine: "mlx-gemma4-26b", model: "mlx-community/gemma-4-26b-a4b-it-4bit",
                pipelineVersion: "1.0", runtime: "mlx-lm/subprocess",
                rendererVersion: "1", promptVersion: "c6-v1"))
    }

    @Test func fullPayloadGolden() throws {
        let meeting = makeFixedMeeting()
        let segments = [
            TranscriptSegment(
                meetingID: meeting.id, ord: 0, startSeconds: 0.0, endSeconds: 2.5,
                speakerLabel: "S0", speakerName: "Sam Rivera", text: "Olá, vamos começar."),
            TranscriptSegment(
                meetingID: meeting.id, ord: 1, startSeconds: 2.75, endSeconds: 5.0,
                speakerLabel: "S1", speakerName: nil, text: "Perfeito."),
        ]
        let payload = EvidencePayloadBuilder.build(
            meeting: meeting, segments: segments, notes: makeFixedNotes(meetingID: meeting.id),
            user: user)

        let expected =
            #"{"attendees":[{"email":"sam.rivera@vexatron.test","name":"Sam"},{"name":"Mariana Costa"}],"#
            + #""created_at_ms":1770000000000,"dominant_language":"pt","ended_at_ms":1770000300000,"#
            + #""native_id":"01ARZ3NDEKTSV4RRFFQ69G5FAV","#
            + #""notes_structured":{"action_items":[{"owner":"Sam","text":"enviar proposta"}],"decisions":["Decisão 1"],"detailed_notes":"Detalhes.","summary":"Resumo.","title":"Reunião fixa","user_action_items":[{"owner":"Sam","text":"enviar proposta"}]},"#
            + #""owner":{"email":"sam.rivera@vexatron.test","name":"Sam"},"#
            + #""provenance":{"asr":{"engine":"mlx-whisper-large-v3-turbo","engine_version":"0.4.3","language_hint":null,"model":"mlx-community/whisper-large-v3-turbo","runtime":"mlx-whisper/subprocess","transcribed_at_ms":1770000100000,"vocabulary_hints_applied":false},"notes":{"engine":"mlx-gemma4-26b","model":"mlx-community/gemma-4-26b-a4b-it-4bit","prompt_version":"c6-v1","renderer_version":"1","runtime":"mlx-lm/subprocess"},"pipeline_version":"1.0"},"#
            + #""source":"blaise","started_at_ms":1770000000000,"#
            // Newlines in string values travel as \u000a (control-char escaping).
            + ##""summary_markdown":"# Reunião fixa\u000a\u000a## Resumo\u000a\u000aResumo.\u000a","summary_text":"Resumo.","title":"Reunião fixa","##
            + #""transcript":[{"end_time_ms":2500,"speaker":{"diarization_label":"S0","name":"Sam Rivera","source":"microphone"},"start_time_ms":0,"text":"Olá, vamos começar."},{"end_time_ms":5000,"speaker":{"diarization_label":"S1","name":null,"source":"speaker"},"start_time_ms":2750,"text":"Perfeito."}],"#
            + #""updated_at_ms":1770000200000}"#
            + "\n"
        #expect(String(decoding: payload.bytes, as: UTF8.self) == expected)

        // versionHash = SHA-256 of exactly those bytes.
        let digest = SHA256.hash(data: Data(expected.utf8))
        #expect(payload.versionHash == digest.map { String(format: "%02x", $0) }.joined())
        #expect(MeetingPaths.isValidVersionHash(payload.versionHash))

        // G4 AC3: the rename is the SOLE diff from the pre-rename payload.
        // Build the OLD (pre-rename) payload from the SAME inputs via the
        // legacy-key encoder path, then compare byte streams. This is NOT
        // vacuous: it independently SERIALIZES the legacy form (it does not
        // copy-and-rename the new bytes), so ANY non-rename divergence between
        // the two encoders — a moved field, a changed value, a different
        // canonicalization — makes the token-substituted comparison FAIL.
        let oldPayload = EvidencePayloadBuilder.build(
            meeting: meeting, segments: segments, notes: makeFixedNotes(meetingID: meeting.id),
            user: user, userActionItemsKey: .legacy)
        let newText = String(decoding: payload.bytes, as: UTF8.self)
        let oldText = String(decoding: oldPayload.bytes, as: UTF8.self)
        // The two streams differ (the key changed AND canonical sort reacts to
        // the new key name, the sanctioned reordering) — so they are NOT equal
        // outright, and the byte-pin above already proves the new bytes.
        #expect(newText != oldText)
        // Independently parse BOTH payloads and confirm: the only key-set diff
        // anywhere in the document is `user_action_items` ⇄ `ric_action_items`
        // inside notes_structured, and that key's VALUE is byte-identical.
        let newParsed = try #require(
            try JSONSerialization.jsonObject(with: payload.bytes) as? [String: Any])
        let oldParsed = try #require(
            try JSONSerialization.jsonObject(with: oldPayload.bytes) as? [String: Any])
        let newStructured = try #require(newParsed["notes_structured"] as? [String: Any])
        let oldStructured = try #require(oldParsed["notes_structured"] as? [String: Any])
        // The renamed key's value is byte-identical across the rename.
        #expect(
            (newStructured["user_action_items"] as? [[String: String]])
                == (oldStructured["ric_action_items"] as? [[String: String]]))
        // The ONLY key-set difference anywhere is the renamed action-items key
        // inside notes_structured; top-level key sets are identical.
        #expect(Set(newStructured.keys).symmetricDifference(Set(oldStructured.keys))
            == ["user_action_items", "ric_action_items"])
        #expect(Set(newParsed.keys) == Set(oldParsed.keys))
        // Whole-document byte-diff modulo the key token (AC3 / AC4): rename
        // BOTH streams' action-items key to a common placeholder, re-emit each
        // through the canonical writer (which re-sorts so the placeholder lands
        // in the SAME slot in both), and confirm the resulting bytes are
        // identical. Any other byte that differs between the two encoders
        // survives the substitution and fails this — it is not vacuous.
        #expect(
            canonicalReemit(payload.bytes, replacingKey: "user_action_items", with: "z_action_items")
                == canonicalReemit(oldPayload.bytes, replacingKey: "ric_action_items", with: "z_action_items"))
    }

    /// Parse canonical JSON bytes, rename one object key wherever it appears,
    /// and re-serialize through the canonical writer. Used to byte-diff the
    /// pre/post-rename payloads modulo the renamed key (G4 AC3/AC4).
    private func canonicalReemit(_ bytes: Data, replacingKey old: String, with new: String) -> Data {
        let json = try! JSONSerialization.jsonObject(with: bytes)
        func convert(_ any: Any) -> CanonicalJSONValue {
            if let dict = any as? [String: Any] {
                return .object(dict.map { (k, v) in (k == old ? new : k, convert(v)) })
            }
            if let arr = any as? [Any] { return .array(arr.map(convert)) }
            if let n = any as? NSNumber {
                if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
                if CFNumberIsFloatType(n) { return .string(String(describing: n)) }
                return .integer(n.int64Value)
            }
            if any is NSNull { return .null }
            return .string(any as! String)
        }
        return CanonicalJSONWriter.write(convert(json))
    }

    @Test func meetingTypeIsAdditiveAndGatedOnPresence() throws {
        // Notes v2 contract discipline: `notes_structured.meeting_type` is
        // ADDITIVE — present only when the notes row HAS a classification.
        // The nil case is `fullPayloadGolden` above (its expected bytes
        // carry NO meeting_type — pre-v2 payloads re-materialize
        // byte-identically). Here: a v2 notes row emits it, and ONLY the
        // notes_structured block changes.
        let meeting = makeFixedMeeting()
        let before = EvidencePayloadBuilder.build(
            meeting: meeting, segments: [], notes: makeFixedNotes(meetingID: meeting.id),
            user: user)
        var notes = makeFixedNotes(meetingID: meeting.id)
        notes.structured.meetingType = .externalCall
        let after = EvidencePayloadBuilder.build(
            meeting: meeting, segments: [], notes: notes, user: user)

        let beforeText = String(decoding: before.bytes, as: UTF8.self)
        let afterText = String(decoding: after.bytes, as: UTF8.self)
        #expect(!beforeText.contains("meeting_type"))
        #expect(afterText.contains(#""meeting_type":"external_call""#))
        // Canonical key sort inside notes_structured holds with the new key:
        // `meeting_type` sorts between `detailed_notes` and `summary`, and
        // the renamed `user_action_items` sorts last (after `title`).
        #expect(afterText.contains(#""detailed_notes":"Detalhes.","meeting_type":"external_call","summary""#))
        #expect(afterText.contains(#""title":"Reunião fixa","user_action_items""#))
        #expect(
            afterText.replacingOccurrences(
                of: #""meeting_type":"external_call","#, with: "") == beforeText)
        #expect(before.versionHash != after.versionHash)
    }

    @Test func speakerSourcePredicate() {
        let meeting = makeFixedMeeting()
        func source(_ name: String?) -> String {
            EvidencePayloadBuilder.speakerSource(
                of: TranscriptSegment(
                    meetingID: meeting.id, ord: 0, startSeconds: 0, endSeconds: 1,
                    speakerLabel: "S0", speakerName: name, text: "x"),
                meeting: meeting, user: user)
        }
        // Identity name + aliases, case-insensitive + diacritic-folded.
        #expect(source("Sam") == "microphone")
        #expect(source("Sam") == "microphone")
        #expect(source("Sam Rivera") == "microphone")  // C8 AC1 alias-form case
        #expect(source("Sam Rivera") == "microphone")
        // Attendee-email match: attendee "Sam" carries the user's email; an
        // attendee WITHOUT the email stays "speaker".
        #expect(source("Mariana Costa") == "speaker")
        #expect(source("Outra Pessoa") == "speaker")
        #expect(source(nil) == "speaker")
    }

    @Test("G3 AC2: empty (pre-onboarding) identity → payload owner carries empty fields honestly")
    func payloadOwnerCarriesEmptyIdentityHonestly() throws {
        // The evidence contract §2 owner note allows empty owner fields
        // pre-onboarding. The builder must emit them as empty STRINGS (not
        // omitted, not a fabricated default) so the inbox sees "no identity
        // yet" rather than a stale owner.
        let meeting = makeFixedMeeting()
        let payload = EvidencePayloadBuilder.build(
            meeting: meeting, segments: [], notes: makeFixedNotes(meetingID: meeting.id),
            user: UserIdentity.shippedDefault)  // empty
        let parsed = try #require(
            try JSONSerialization.jsonObject(with: payload.bytes) as? [String: Any])
        let owner = try #require(parsed["owner"] as? [String: Any])
        #expect(owner["name"] as? String == "")
        #expect(owner["email"] as? String == "")
    }

    @Test("G3 AC2: empty identity → speakerSource name/alias/email match no-ops; mic label still tags")
    func speakerSourceNoOpsWithEmptyIdentity() {
        let meeting = makeFixedMeeting()
        let empty = UserIdentity.shippedDefault  // name/aliases/email all empty
        func source(label: String, name: String?) -> String {
            EvidencePayloadBuilder.speakerSource(
                of: TranscriptSegment(
                    meetingID: meeting.id, ord: 0, startSeconds: 0, endSeconds: 1,
                    speakerLabel: label, speakerName: name, text: "x"),
                meeting: meeting, user: empty)
        }
        // No identity forms to match against: a resolved name never resolves to
        // "microphone" via the name/alias/email predicate.
        #expect(source(label: "S0", name: "Sam") == "speaker")
        #expect(source(label: "S0", name: "Sam Rivera") == "speaker")
        #expect(source(label: "S0", name: nil) == "speaker")
        // But the durable mic label still tags live capture as microphone
        // (the re-materialization-exact path, independent of identity).
        #expect(source(label: "user", name: nil) == "microphone")
    }

    @Test func attendeeEmailMatchYieldsMicrophone() {
        // A resolved name that is NOT an identity alias but maps to an
        // attendee whose email equals the user's.
        var meeting = makeFixedMeeting()
        meeting.attendees = [
            Attendee(name: "R. Rivera", email: "sam.rivera@vexatron.test", source: .calendar)
        ]
        let segment = TranscriptSegment(
            meetingID: meeting.id, ord: 0, startSeconds: 0, endSeconds: 1,
            speakerLabel: "S0", speakerName: "R. Rivera", text: "x")
        #expect(
            EvidencePayloadBuilder.speakerSource(of: segment, meeting: meeting, user: user)
                == "microphone")
    }

    @Test func distinctMeetingsNeverCollide() {
        // native_id embedding: same content, different ULIDs → different bytes.
        var meetingA = makeFixedMeeting()
        var meetingB = makeFixedMeeting()
        meetingA.id = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
        meetingB.id = "01ARZ3NDEKTSV4RRFFQ69G5FB0"
        let notesA = makeFixedNotes(meetingID: meetingA.id)
        let a = EvidencePayloadBuilder.build(meeting: meetingA, segments: [], notes: notesA, user: user)
        let b = EvidencePayloadBuilder.build(meeting: meetingB, segments: [], notes: notesA, user: user)
        #expect(a.versionHash != b.versionHash)
    }

    @Test func millisecondsAreRoundedIntegers() {
        #expect(EvidencePayloadBuilder.milliseconds(2.5) == 2500)
        #expect(EvidencePayloadBuilder.milliseconds(0.0004) == 0)
        #expect(EvidencePayloadBuilder.milliseconds(0.0006) == 1)
        #expect(EvidencePayloadBuilder.milliseconds(date: Date(timeIntervalSince1970: 1.0015)) == 1002)
    }
}

@Suite struct VocabBundlingTests {
    /// AC5: the C5 fixtures are bundled into the app resources and must stay
    /// byte-identical to the repo fixtures (the derivation outputs).
    @Test func bundledFixturesAreByteIdenticalToRepoFixtures() throws {
        // G1: Vexatron_vocab.txt is no longer bundled (the user glossary replaces
        // it). G6: stoplist_project.txt is no longer bundled either — it is
        // replaced by an EMPTY stoplist_user.txt and the real terms move to the
        // data-root stoplist_user.txt (asserted separately below). The remaining
        // shared stoplist lexicons stay bundled and must match the repo.
        for name in [
            "stoplist_pt.txt", "stoplist_en.txt",
            "stoplist_exclusions.txt", "br_common_names.txt",
        ] {
            let bundled = try PipelineVocabulary.bundledResource(name)
            let repo = VocabFixtures.fixture(name)
            #expect(
                try Data(contentsOf: bundled) == (try Data(contentsOf: repo)),
                "bundled \(name) drifted from fixtures/\(name) — re-copy after derivation")
        }
    }

    /// G6 stoplist split: the public bundle ships an EMPTY stoplist_user.txt
    /// (header comment only, zero terms) in place of the real-term
    /// stoplist_project.txt, which is no longer bundled at all.
    @Test func bundledUserStoplistIsEmptyAndProjectStoplistIsGone() throws {
        #expect((try? PipelineVocabulary.bundledResource("stoplist_project.txt")) == nil)
        let userStoplist = try PipelineVocabulary.bundledResource("stoplist_user.txt")
        let terms = VocabWordList.parse(try String(contentsOf: userStoplist, encoding: .utf8))
        #expect(terms.isEmpty, "bundled stoplist_user.txt must ship empty (zero terms)")
    }

    @Test func syntheticVocabIsNotBundled() {
        // AC6: the bundled BlaiseCore resources carry no synthetic_vocab.txt.
        #expect((try? PipelineVocabulary.bundledResource("synthetic_vocab.txt")) == nil)
    }

    @Test func fixtureCorrectorWorks() throws {
        let vocabulary = try VocabFixtures.pipelineVocabulary()
        #expect(vocabulary.dictionary.entries.count == VocabFixtures.dictionary.entries.count)
        // Exact-stage restore of the distinctive single-token canonical "Petball"
        // plus the planted alias-stage mishearing "Quol Harbour" → "Quoll Harbour".
        let result = vocabulary.corrector.correct("a petball estreia e o time foi pra Quol Harbour")
        #expect(result.correctedText == "a Petball estreia e o time foi pra Quoll Harbour")
        #expect(!vocabulary.suppression.isEmpty)
        #expect(vocabulary.commonNames.contains("fabio"))
        #expect(vocabulary.canonicalTerms.contains("Vexatron Labs"))
    }
}
