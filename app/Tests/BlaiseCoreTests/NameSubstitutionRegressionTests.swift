import Foundation
import Testing
@testable import BlaiseCore

// G2 AC6 (empirical, not "by construction"): the substitution pass with an
// EMPTY store leaves the notes byte-identical. An explicit identity check on a
// hand-authored fictional NotesStructured (Vexatron Labs / Quoll Harbour) —
// the G2 identity guarantee, with no real-meeting pin involved.

@Suite struct NameSubstitutionRegressionTests {
    /// A small, wholly-fictional NotesStructured literal (the deleted
    /// real-meeting `notes_pinned.json` is gone; this stands in for the
    /// identity check). Non-empty userActionItems and a couple of decisions.
    private func syntheticStructured() -> NotesStructured {
        NotesStructured(
            title: "Vexatron Labs — Quoll Harbour build sync",
            summary: "The Quoll Harbour vertical slice is on track for the milestone review.",
            detailedNotes: """
                Sam Rivera walked the team through the diving traversal loop.
                The lighting pass on the second biome still needs an art review.
                """,
            decisions: [
                "Quoll Harbour ships the vertical slice with two biomes; the third is a stretch goal.",
                "Marco Vidal owns the milestone build cut.",
            ],
            actionItems: [
                ActionItem(owner: "Marco Vidal", text: "Cut the milestone build by Friday."),
                ActionItem(owner: "Anna Reyes", text: "Schedule the lighting art review."),
            ],
            userActionItems: [
                ActionItem(owner: "Sam Rivera", text: "Approve the vertical-slice scope."),
            ])
    }

    @Test func emptyStoreLeavesNotesByteIdentical() throws {
        let structured = syntheticStructured()
        // The fixture vocabulary (rule-3 polish set is derived from it); the
        // empty store means rules 1 and 2 cannot fire either.
        let vocabulary = try VocabFixtures.pipelineVocabulary()
        let context = NameSubstitution.Context(
            store: [],
            ownerCandidates: [],
            commonNames: vocabulary.commonNames,
            polishCanonicals: ProcessingPipeline.polishCanonicals(vocabulary))

        let result = NameSubstitution.apply(notes: structured, context: context)
        #expect(result.report.isEmpty, "empty store must produce no substitutions")
        #expect(result.notes == structured, "empty-store pass must be the identity on the notes")

        // Byte-level: encode both and compare exact bytes.
        let before = try pinBytes(structured)
        let after = try pinBytes(result.notes)
        #expect(before == after, "notes must be byte-identical after an empty-store pass")
    }
}
