import Foundation
import Testing
@testable import BlaiseCore

// Fix 0 §5 — T1–T4 and T6–T11. All correction fixtures use the locked
// fictional universe: Dana Del Rosso, Dana Quoll, Kip Rho, and Okora.

private func correctionNotes(
    title: String? = nil, summary: String, detailedNotes: String = "",
    decisions: [String] = [], actionItems: [ActionItem] = [],
    userActionItems: [ActionItem] = []
) -> NotesStructured {
    NotesStructured(
        title: title, summary: summary, detailedNotes: detailedNotes,
        decisions: decisions, actionItems: actionItems, userActionItems: userActionItems)
}

@Suite struct MultiWordNameCorrectionCoreTests {
    /// T1: the old single-run matcher cannot fire this repro because the
    /// target has three words. The three fold-equivalent surfaces must all
    /// move in one deterministic digest pass.
    @Test func T1_multiWordDigestCorrectionReplacesAllFoldVariants() {
        let digest = "dana del rosso reviewed the plan. Dana Del Rosso agreed. Dána Del Rosso followed up."
        let (rewritten, count) = NameSubstitution.applyTextCorrection(
            text: digest, original: "Dana Del Rosso", replacement: "Dana Quoll")
        #expect(count == 3)
        #expect(rewritten == "Dana Quoll reviewed the plan. Dana Quoll agreed. Dana Quoll followed up.")
    }

    /// T2: a bare name expands, but a pre-existing full replacement is not
    /// double-appended; applying the same correction again is a no-op.
    @Test func T2_containmentGuardMakesExpansionIdempotent() {
        let input = "Dana met Dana Quoll, then Dana."
        let (once, firstCount) = NameSubstitution.applyTextCorrection(
            text: input, original: "Dana", replacement: "Dana Quoll")
        #expect(firstCount == 2)
        #expect(once == "Dana Quoll met Dana Quoll, then Dana Quoll.")

        let (twice, secondCount) = NameSubstitution.applyTextCorrection(
            text: once, original: "Dana", replacement: "Dana Quoll")
        #expect(secondCount == 0)
        #expect(twice == once)
    }

    /// T3's existing Okora→Okoro byte pin remains in
    /// MemoryDigestSelfHealEditTests unchanged; this companion pins the
    /// whole-word boundary around that same fictional surface.
    @Test func T3_singleWordCorrectionDoesNotMatchAWordPrefix() {
        let (rewritten, count) = NameSubstitution.applyTextCorrection(
            text: "Okorama Okora", original: "Okora", replacement: "Okoro")
        #expect(count == 1)
        #expect(rewritten == "Okorama Okoro")
    }

    /// T4: matching a prefix of a multi-word target is not an occurrence.
    @Test func T4_multiWordArityIsHonest() {
        let input = "Dana Del reviewed the plan."
        let (rewritten, count) = NameSubstitution.applyTextCorrection(
            text: input, original: "Dana Del Rosso", replacement: "Dana Quoll")
        #expect(count == 0)
        #expect(rewritten == input)
    }

    /// T6: intra-name spacing is consumed and normalized by the verbatim
    /// replacement, including a single allowed line-wrap.
    @Test func T6_whitespaceVarianceIsAcceptedAndNormalized() {
        let input = "Dana  Del Vex; Dana\nDel Vex"
        let (rewritten, count) = NameSubstitution.applyTextCorrection(
            text: input, original: "Dana Del Vex", replacement: "Dana Quoll")
        #expect(count == 2)
        #expect(rewritten == "Dana Quoll; Dana Quoll")
    }

    /// T7: punctuation, markdown/list structure, blank lines, and every
    /// non-allowlisted newline-class character block a cross-word window.
    @Test func T7_structuralSeparatorsAndCharacterModel() {
        let negatives = [
            "Dana. Vex",
            "Dana,\nVex",
            "Dana.\n\n## Vex",
            "**Dana** Vex",
            "- Dana\n- Vex",
            "Dana\u{2029}Vex",
            "Dana\u{000B}Vex",
            "Dana\u{000C}Vex",
        ]
        for input in negatives {
            let (rewritten, count) = NameSubstitution.applyTextCorrection(
                text: input, original: "Dana Vex", replacement: "Dana Quoll")
            #expect(count == 0, "unexpected structural match in \(input.debugDescription)")
            #expect(rewritten == input)
        }

        let positives = [
            ("Dana\tVex", "Dana Quoll"),
            ("Dana\u{00A0}Vex", "Dana Quoll"),
            ("Dana\r\nVex", "Dana Quoll"),
            ("**Dana Vex**", "**Dana Quoll**"),
        ]
        for (input, expected) in positives {
            let (rewritten, count) = NameSubstitution.applyTextCorrection(
                text: input, original: "Dana Vex", replacement: "Dana Quoll")
            #expect(count == 1, "expected structural match in \(input.debugDescription)")
            #expect(rewritten == expected)
        }
    }

    /// T8: disjoint corrections stabilize, while the locked shrink-class
    /// behavior is intentionally allowed to re-fire after the first edit.
    @Test func T8_idempotenceClassesArePinned() {
        let (disjointOnce, disjointCount) = NameSubstitution.applyTextCorrection(
            text: "Dana is here.", original: "Dana", replacement: "Quoll")
        let (disjointTwice, disjointSecondCount) = NameSubstitution.applyTextCorrection(
            text: disjointOnce, original: "Dana", replacement: "Quoll")
        #expect(disjointCount == 1)
        #expect(disjointSecondCount == 0)
        #expect(disjointTwice == disjointOnce)

        let (shrinkOnce, shrinkCount) = NameSubstitution.applyTextCorrection(
            text: "Dana Vex Vex", original: "Dana Vex", replacement: "Dana")
        let (shrinkTwice, shrinkSecondCount) = NameSubstitution.applyTextCorrection(
            text: shrinkOnce, original: "Dana Vex", replacement: "Dana")
        #expect(shrinkCount == 1)
        #expect(shrinkOnce == "Dana Vex")
        #expect(shrinkSecondCount == 1)
        #expect(shrinkTwice == "Dana")
    }

    /// T9(a–d): notes use the same identity domain as the digest, but the
    /// apply-all count excludes the already-full replacement.
    @Test func T9_notesModesCountsClassificationAndLockstep() {
        let notes = correctionNotes(
            summary: "Dana Quoll met Dana.", detailedNotes: "Dana")
        #expect(NameSubstitution.selectableOccurrenceCount(in: notes, original: "Dana") == 3)
        #expect(NameSubstitution.replaceableOccurrenceCount(
            in: notes, original: "Dana", replacement: "Dana Quoll") == 2)

        let all = NameSubstitution.applyNoteCorrection(
            notes: notes, original: "Dana", replacement: "Dana Quoll", allOccurrences: true)
        #expect(all.count == 2)
        #expect(all.notes.summary == "Dana Quoll met Dana Quoll.")
        #expect(all.notes.detailedNotes == "Dana Quoll")
        #expect(NameSubstitution.classifyNoteOccurrence(
            in: notes, original: "Dana", replacement: "Dana Quoll", occurrenceIndex: 0)
            == .alreadyCorrect)
        #expect(NameSubstitution.classifyNoteOccurrence(
            in: notes, original: "Dana", replacement: "Dana Quoll", occurrenceIndex: 1)
            == .replaceable)
        #expect(NameSubstitution.classifyNoteOccurrence(
            in: notes, original: "Dana", replacement: "Dana Quoll", occurrenceIndex: 9)
            == .absent)

        let selectedBare = NameSubstitution.applyNoteCorrection(
            notes: notes, original: "Dana", replacement: "Dana Quoll",
            allOccurrences: false, occurrenceIndex: 1)
        #expect(selectedBare.count == 1)
        #expect(selectedBare.notes.summary == "Dana Quoll met Dana Quoll.")
        #expect(selectedBare.notes.detailedNotes == "Dana")

        let selectedFull = NameSubstitution.applyNoteCorrection(
            notes: notes, original: "Dana", replacement: "Dana Quoll",
            allOccurrences: false, occurrenceIndex: 0)
        #expect(selectedFull.count == 0)
        #expect(selectedFull.notes == notes)
        #expect(!all.notes.summary.contains("Dana Quoll Quoll"))

        let digest = "Dana Quoll met Dana. Dana"
        let (digestAfter, digestCount) = NameSubstitution.applyTextCorrection(
            text: digest, original: "Dana", replacement: "Dana Quoll")
        #expect(digestCount == 2)
        #expect(digestAfter == "Dana Quoll met Dana Quoll. Dana Quoll")
        #expect(all.notes.summary == "Dana Quoll met Dana Quoll.")
    }

    /// T10: adjacent windows are both occurrences; overlapping starts inside
    /// an accepted window are not reopened, including after guard filtering.
    @Test func T10AdjacencyOverlapAndIdentityEscape() {
        let adjacent = NameSubstitution.applyTextCorrection(
            text: "Dana Vex Dana Vex", original: "Dana Vex", replacement: "Dana Quoll")
        #expect(adjacent.count == 2)
        #expect(adjacent.text == "Dana Quoll Dana Quoll")

        let overlapText = "Dana Dana Dana"
        #expect(NameSubstitution.selectableOccurrenceCount(
            in: overlapText, original: "Dana Dana") == 1)
        let overlap = NameSubstitution.applyTextCorrection(
            text: overlapText, original: "Dana Dana", replacement: "Dana Quoll")
        #expect(overlap.count == 1)
        #expect(overlap.text == "Dana Quoll Dana")

        let identityEscape = "Kip Rho Kip Rho Kip"
        #expect(NameSubstitution.selectableOccurrenceCount(
            in: identityEscape, original: "Kip Rho Kip") == 1)
        let escaped = NameSubstitution.applyTextCorrection(
            text: identityEscape, original: "Kip Rho Kip", replacement: "Kip Rho Kip Rho")
        #expect(escaped.count == 0)
        #expect(escaped.text == identityEscape)
    }

    /// T11: empty targets and overlong targets are no-ops; an empty folded
    /// replacement disables only the guard and still inserts verbatim.
    @Test func T11DegenerateInputs() {
        let empty = NameSubstitution.applyTextCorrection(
            text: "Dana", original: "", replacement: "Dana Quoll")
        #expect(empty.count == 0)
        #expect(empty.text == "Dana")

        let overlong = NameSubstitution.applyTextCorrection(
            text: "Dana Quoll", original: "Dana Quoll Kip Rho", replacement: "Dana")
        #expect(overlong.count == 0)
        #expect(overlong.text == "Dana Quoll")

        let punctuationReplacement = NameSubstitution.applyTextCorrection(
            text: "Dana", original: "Dana", replacement: "**")
        #expect(punctuationReplacement.count == 1)
        #expect(punctuationReplacement.text == "**")
    }
}


// Gate-0 regression (slice-A clause-9 deviation): the UI-facing counts and
// classification must traverse EXACTLY the fields applyNoteCorrection edits —
// including action-item TEXT, not only owners. Before this pin, an occurrence
// living only in an action item's text reported selectable == 0 while
// apply-all silently rewrote it.
@Suite struct OccurrenceFieldParityTests {
    @Test func occurrenceInActionItemTextIsCountedClassifiedAndApplied() {
        let notes = correctionNotes(
            summary: "Planning sync.",
            actionItems: [ActionItem(owner: "Okora", text: "Dana to send the Quoll Harbor deck")])
        #expect(NameSubstitution.selectableOccurrenceCount(in: notes, original: "Dana") == 1)
        #expect(NameSubstitution.replaceableOccurrenceCount(
            in: notes, original: "Dana", replacement: "Dana Quoll") == 1)
        let (edited, count) = NameSubstitution.applyNoteCorrection(
            notes: notes, original: "Dana", replacement: "Dana Quoll",
            allOccurrences: true)
        #expect(count == 1)
        #expect(edited.actionItems[0].text == "Dana Quoll to send the Quoll Harbor deck")
    }

    @Test func userActionItemTextParityAndIndexOrderMatchesApply() {
        // Occurrences: [0] actionItems[0].owner, [1] actionItems[0].text,
        // [2] userActionItems[0].text — position-scoped index 1 must hit the
        // action-item TEXT occurrence, proving the enumeration interleaves
        // owner/text exactly like the apply traversal.
        let notes = correctionNotes(
            summary: "Weekly review.",
            actionItems: [ActionItem(owner: "Dana", text: "Dana files the report")],
            userActionItems: [ActionItem(owner: "Okora", text: "ping Dana re budget")])
        #expect(NameSubstitution.selectableOccurrenceCount(in: notes, original: "Dana") == 3)
        let (edited, count) = NameSubstitution.applyNoteCorrection(
            notes: notes, original: "Dana", replacement: "Dana Quoll",
            allOccurrences: false, occurrenceIndex: 1)
        #expect(count == 1)
        #expect(edited.actionItems[0].owner == "Dana")
        #expect(edited.actionItems[0].text == "Dana Quoll files the report")
        #expect(edited.userActionItems[0].text == "ping Dana re budget")
    }
}

// Gate-0 completeness-critic pins: §4 invariant 4 sentence 2 (quoted spans are
// NOT immune in this engine — G2's quote immunity is deliberately not imported)
// and §3.2 applyAt's out-of-bounds branch on applyNoteCorrection itself.
@Suite struct CriticCoveragePinTests {
    @Test func quotedOccurrencesAreNotImmune() {
        let digest = "He said \"Dana Del Rosso\" and later “Dana Del Rosso” again."
        let (rewritten, count) = NameSubstitution.applyTextCorrection(
            text: digest, original: "Dana Del Rosso", replacement: "Dana Quoll")
        #expect(count == 2)
        #expect(rewritten == "He said \"Dana Quoll\" and later “Dana Quoll” again.")
    }

    @Test func positionModeOutOfBoundsIndexIsANoOpOnApply() {
        let notes = correctionNotes(summary: "Dana joined. Dana left.")
        let (edited, count) = NameSubstitution.applyNoteCorrection(
            notes: notes, original: "Dana", replacement: "Dana Quoll",
            allOccurrences: false, occurrenceIndex: 99)
        #expect(count == 0)
        #expect(edited.summary == "Dana joined. Dana left.")
    }
}
