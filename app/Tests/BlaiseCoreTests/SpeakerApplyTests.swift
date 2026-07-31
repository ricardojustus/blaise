import Foundation
import Testing
@testable import BlaiseCore

// C4 SpeakerResolution.apply() unit tests — all three validation rules,
// against the REAL C5 fixtures (the same channel C7 loads):
// suppression = SuppressionSet.effective, commonNames = br_common_names.txt.
// Fixture facts the cases lean on (verified against the committed lists):
// "vamos" pt rank ~46 (suppressed, not a name); "maria" pt rank ~1510
// (suppressed BUT a known given name); "fabio"/"souza" pt ranks ~17k/~28k
// (outside suppression); "clara" pt rank ~2.1k (suppressed, NOT in the
// names list); "z" outside both top-3000 cuts.

private let suppression = VocabFixtures.suppression
private let commonNames = VocabFixtures.brCommonNames

private func transcript(_ rows: [(label: String, text: String)]) -> [TranscriptSegment] {
    rows.enumerated().map { index, row in
        TranscriptSegment(
            meetingID: "01TESTMEETING0000000000000",
            ord: index,
            startSeconds: Double(index * 10),
            endSeconds: Double(index * 10 + 5),
            speakerLabel: row.label,
            speakerName: nil,
            text: row.text)
    }
}

private func apply(
    _ assignments: [String: String],
    to segments: [TranscriptSegment],
    attendees: Set<String> = [],
    events: Set<String> = [],
    user: String = "Sam"
) -> [TranscriptSegment] {
    SpeakerResolution(assignments: assignments, unresolved: []).apply(
        to: segments,
        attendeeNames: attendees,
        eventNames: events,
        userName: user,
        suppression: suppression,
        commonNames: commonNames,
        ownerIdentitySet: .empty)
}

@Suite struct SpeakerApplyTests {
    // MARK: - Rule 1: label must exist; never `unattributed`

    @Test func mappingToMissingLabelIsDropped() {
        let segments = transcript([("S0", "bom dia")])
        let applied = apply(["S9": "Alice"], to: segments, attendees: ["Alice"])
        #expect(applied == segments)
    }

    @Test func mappingToUnattributedSentinelIsDropped() {
        let segments = transcript([(TranscriptSegment.unattributed, "bom dia"), ("S0", "oi")])
        let applied = apply(
            [TranscriptSegment.unattributed: "Alice", "S0": "Alice"],
            to: segments, attendees: ["Alice"])
        #expect(applied[0].speakerName == nil)  // sentinel never named
        #expect(applied[1].speakerName == "Alice")
    }

    @Test func entryGranularityOneBadEntryDoesNotPoisonOthers() {
        let segments = transcript([("S0", "bom dia"), ("S1", "oi")])
        let applied = apply(
            ["S0": "Alice", "S1": "Nome Inventado"], to: segments, attendees: ["Alice"])
        #expect(applied[0].speakerName == "Alice")
        #expect(applied[1].speakerName == nil)
    }

    // MARK: - Rule 2: allowed names (sets, folded)

    @Test func attendeeNameMatchesCaseInsensitiveDiacriticFolded() {
        let segments = transcript([("S0", "bom dia")])
        // Attendee has the accent, proposal does not — folded compare matches.
        let applied = apply(["S0": "fabio SILVA"], to: segments, attendees: ["Fábio Silva"])
        #expect(applied[0].speakerName == "fabio SILVA")  // proposed string, verbatim
    }

    @Test func eventNamesAndUserNameAreAllowed() {
        let segments = transcript([("S0", "bom dia"), ("S1", "oi")])
        let applied = apply(
            ["S0": "Caio Souza", "S1": "Sam"], to: segments, events: ["Caio Souza"], user: "Sam")
        #expect(applied[0].speakerName == "Caio Souza")
        #expect(applied[1].speakerName == "Sam")
    }

    // MARK: - Rule 2: transcript-verbatim allowance

    @Test func fullNameVerbatimInTranscriptIsAllowedFolded() {
        // "Fábio Souza" ← transcript has unaccented "fabio souza" contiguously;
        // both tokens are outside the suppression cut → not blocked.
        let segments = transcript([("S0", "e o fabio souza vai mandar a proposta")])
        let applied = apply(["S0": "Fábio Souza"], to: segments)
        #expect(applied[0].speakerName == "Fábio Souza")
    }

    @Test func suppressedCommonWordIsBlockedAsName() {
        // "Vamos" occurs verbatim, but it is a suppression member and not a
        // known given name → blocked.
        let segments = transcript([("S0", "Vamos começar a reunião")])
        let applied = apply(["S0": "Vamos"], to: segments)
        #expect(applied[0].speakerName == nil)
    }

    @Test func suppressedKnownGivenNamePasses() {
        // "Maria" is inside the top-3000 suppression cut BUT a known given
        // name (br_common_names) → not blocked.
        let segments = transcript([("S0", "a maria fica responsável por isso")])
        let applied = apply(["S0": "Maria"], to: segments)
        #expect(applied[0].speakerName == "Maria")
    }

    @Test func anyBlockedTokenBlocksTheWholeName() {
        // "clara" is suppressed and NOT in the names list → "Clara Mendes"
        // is blocked even though "mendes" would pass.
        let segments = transcript([("S0", "a clara mendes apresentou os números")])
        let applied = apply(["S0": "Clara Mendes"], to: segments)
        #expect(applied[0].speakerName == nil)
    }

    @Test func nameShorterThanTwoCharactersIsDropped() {
        // "Z" is outside both top-3000 cuts (unblocked) and occurs verbatim —
        // only the ≥ 2 characters rule rejects it.
        let segments = transcript([("S0", "o Z confirmou presença")])
        let applied = apply(["S0": "Z"], to: segments)
        #expect(applied[0].speakerName == nil)
    }

    @Test func nameMustOccurContiguouslyAtTokenBoundaries() {
        let inside = transcript([("S0", "a banana clara estava na mesa")])
        // "ana" appears only inside "banana" — not at a token boundary.
        #expect(apply(["S0": "Ana"], to: inside)[0].speakerName == nil)
        // Tokens present but not contiguous.
        let split = transcript([("S0", "o fabio falou com a souza ontem")])
        #expect(apply(["S0": "Fabio Souza"], to: split)[0].speakerName == nil)
        // Positive control: contiguous, boundary-respecting occurrence.
        let good = transcript([("S0", "falei com ana hoje cedo")])
        #expect(apply(["S0": "Ana"], to: good)[0].speakerName == "Ana")
    }

    @Test func nameDoesNotMatchAcrossSegmentBoundaries() {
        // The full name must occur within ONE segment's text.
        let segments = transcript([("S0", "quem resolve é o fabio"), ("S0", "souza talvez ajude")])
        #expect(apply(["S0": "Fabio Souza"], to: segments).allSatisfy { $0.speakerName == nil })
    }

    @Test func punctuationAroundTheNameDoesNotBlockMatching() {
        // Edge punctuation is peeled by the tokenizer ("Fabio," → fabio).
        let segments = transcript([("S0", "obrigado, Fabio, pela ajuda")])
        #expect(apply(["S0": "Fabio"], to: segments)[0].speakerName == "Fabio")
    }

    @Test func nameAbsentFromSetsAndTranscriptIsDropped() {
        let segments = transcript([("S0", "discussão sobre o roadmap")])
        #expect(apply(["S0": "Carlos Eduardo"], to: segments)[0].speakerName == nil)
    }

    // MARK: - Rule 3: no-overwrite precedence

    @Test func alreadyNamedSegmentsAreNeverChanged() {
        var segments = transcript([("S0", "bom dia"), ("S0", "boa tarde")])
        segments[0].speakerName = "Alice"  // mechanical pass already named it
        let applied = apply(["S0": "Bob"], to: segments, attendees: ["Alice", "Bob"])
        #expect(applied[0].speakerName == "Alice")  // first application wins
        #expect(applied[1].speakerName == "Bob")  // unnamed segments still fill
    }

    @Test func sequentialApplicationsFirstWins() {
        let segments = transcript([("S0", "bom dia")])
        let mechanical = apply(["S0": "Alice"], to: segments, attendees: ["Alice", "Bob"])
        let llmAfter = apply(["S0": "Bob"], to: mechanical, attendees: ["Alice", "Bob"])
        #expect(llmAfter[0].speakerName == "Alice")
    }

    @Test func applyOnlyTouchesSpeakerName() {
        let segments = transcript([("S0", "bom dia"), ("S1", "oi")])
        let applied = apply(["S0": "Alice"], to: segments, attendees: ["Alice"])
        for (before, after) in zip(segments, applied) {
            var named = before
            named.speakerName = after.speakerName
            #expect(named == after)
        }
    }
}
