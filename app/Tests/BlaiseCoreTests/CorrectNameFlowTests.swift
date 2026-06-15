import Foundation
import Testing
@testable import BlaiseCore

// G2 §5 mechanism pins: position-scoped occurrence correction, rename-input
// normalization, and the M-5 glossary-link admission pre-check (gates 0a/0b).

@Suite struct CorrectNameOccurrenceTests {
    private func notes(summary: String) -> NotesStructured {
        NotesStructured(
            summary: summary, detailedNotes: summary, decisions: [],
            actionItems: [], userActionItems: [])
    }

    @Test func singleOccurrenceReplacesFirstOnly() {
        let n = NotesStructured(
            title: nil, summary: "Riso e Riso", detailedNotes: "Riso de novo",
            decisions: [], actionItems: [], userActionItems: [])
        let r = NameSubstitution.applyNoteCorrection(
            notes: n, original: "Riso", replacement: "Marco Vidal", allOccurrences: false)
        #expect(r.count == 1)
        #expect(r.notes.summary == "Marco Vidal e Riso") // first run only
        #expect(r.notes.detailedNotes == "Riso de novo") // untouched
    }

    @Test func allOccurrencesReplacesEveryRun() {
        let n = NotesStructured(
            title: nil, summary: "Riso e Riso", detailedNotes: "Riso de novo",
            decisions: [], actionItems: [], userActionItems: [])
        let r = NameSubstitution.applyNoteCorrection(
            notes: n, original: "Riso", replacement: "Marco Vidal", allOccurrences: true)
        #expect(r.count == 3)
        #expect(r.notes.summary == "Marco Vidal e Marco Vidal")
        #expect(r.notes.detailedNotes == "Marco Vidal de novo")
    }

    // H-8 (NH-C position scoping): the position-scoped confirm fixes the
    // occurrence the user POINTED AT (occurrenceIndex in global reading order),
    // never silently the first. Here there are three "Riso" runs (summary[0],
    // summary[1], detailedNotes[0]); occurrence 2 is the detailedNotes one.
    @Test func positionScopedFixesSelectedOccurrence_H8() {
        let n = NotesStructured(
            title: nil, summary: "Riso e Riso", detailedNotes: "Riso de novo",
            decisions: [], actionItems: [], userActionItems: [])
        // Occurrence index 1 → the SECOND run (summary's second "Riso").
        let r1 = NameSubstitution.applyNoteCorrection(
            notes: n, original: "Riso", replacement: "Marco Vidal",
            allOccurrences: false, occurrenceIndex: 1)
        #expect(r1.count == 1)
        #expect(r1.notes.summary == "Riso e Marco Vidal", "second run fixed, not the first")
        #expect(r1.notes.detailedNotes == "Riso de novo")

        // Occurrence index 2 → the detailedNotes run (a different field).
        let r2 = NameSubstitution.applyNoteCorrection(
            notes: n, original: "Riso", replacement: "Marco Vidal",
            allOccurrences: false, occurrenceIndex: 2)
        #expect(r2.count == 1)
        #expect(r2.notes.summary == "Riso e Riso")
        #expect(r2.notes.detailedNotes == "Marco Vidal de novo", "the pointed-at run fixed")
    }

    @Test func positionScopedDefaultsToFirstWhenIndexNil_H8() {
        let n = NotesStructured(
            title: nil, summary: "Riso e Riso", detailedNotes: "Riso de novo",
            decisions: [], actionItems: [], userActionItems: [])
        let r = NameSubstitution.applyNoteCorrection(
            notes: n, original: "Riso", replacement: "Marco Vidal", allOccurrences: false)
        #expect(r.count == 1)
        #expect(r.notes.summary == "Marco Vidal e Riso", "nil index → first occurrence")
    }
}

@Suite struct RenameNormalizationTests {
    @Test func stripsParentheticals() {
        #expect(NameSubstitution.normalizeRenameInput("Riso (Marco Vidal)") == "Marco Vidal")
        #expect(NameSubstitution.normalizeRenameInput("  Sammy   Marsh ") == "Sammy Marsh")
    }

    @Test func storeRule1NormalizesRenameInput() {
        let context = NameSubstitution.Context(
            store: [NameSubstitution.StoreRow(
                mishearedFolded: VocabNormalization.canonicalMode("semi"), replacement: "Sammy",
                everyday: true)],
            ownerCandidates: [], commonNames: [], polishCanonicals: [])
        #expect(NameSubstitution.normalizeRename("SEMI", context: context) == "Sammy")
    }

    @Test func rule3PolishesRenameInput() {
        let context = NameSubstitution.Context(
            store: [], ownerCandidates: [], commonNames: [], polishCanonicals: ["Márcio"])
        #expect(NameSubstitution.normalizeRename("Marcio", context: context) == "Márcio")
    }
}

@Suite struct GlossaryAdmissionPreviewTests {
    @Test func admitsADistinctiveName() {
        #expect(GlossaryAdmissionPreview.wouldAdmit(
            surface: "Vexatron", canonical: "Vexatron Labs",
            pt: VocabFixtures.ptList, en: VocabFixtures.enList,
            brCommonNames: VocabFixtures.brCommonNames))
    }

    @Test func rejectsEverydayWord() {
        // "semi" is an everyday PT word → not admissible as a glossary alias.
        #expect(!GlossaryAdmissionPreview.wouldAdmit(
            surface: "semi", canonical: "Sammy",
            pt: VocabFixtures.ptList, en: VocabFixtures.enList,
            brCommonNames: VocabFixtures.brCommonNames))
    }

    @Test func rejectsCommonGivenName() {
        // A br_common_names member is rejected by AliasAdmission.
        let aName = VocabFixtures.brCommonNames.first!
        #expect(!GlossaryAdmissionPreview.wouldAdmit(
            surface: aName, canonical: "Whoever",
            pt: VocabFixtures.ptList, en: VocabFixtures.enList,
            brCommonNames: VocabFixtures.brCommonNames))
    }

    @Test func gate0aRejectsPunctuationDecoratedSurface() {
        // M-5: AliasAdmission ALONE would miss gate 0a; the preview runs it.
        #expect(!GlossaryAdmissionPreview.wouldAdmit(
            surface: "**Vexatron**", canonical: "Vexatron Labs",
            pt: VocabFixtures.ptList, en: VocabFixtures.enList,
            brCommonNames: VocabFixtures.brCommonNames))
    }

    @Test func gate0bRejectsEmptyCoreSurface() {
        #expect(!GlossaryAdmissionPreview.wouldAdmit(
            surface: "---", canonical: "Vexatron Labs",
            pt: VocabFixtures.ptList, en: VocabFixtures.enList,
            brCommonNames: VocabFixtures.brCommonNames))
    }
}
