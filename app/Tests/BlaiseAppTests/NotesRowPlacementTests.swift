import BlaiseCore
import Foundation
import Testing

@testable import BlaiseApp

// Where a correction row or margin note RENDERS. The anchor space is the
// section's fold-split blocks; the pane's own markdown-block list is finer (a
// bullet list is one anchor block and many rendered blocks), so placement
// re-resolves the quote against what the reader actually sees.

private func note(quote: String, occurrence: Int = 0) -> MeetingCorrection {
    MeetingCorrection(
        id: "row-\(quote.prefix(12))-\(occurrence)",
        meetingID: "meeting-1", kind: .annotation, section: .detailedNotes,
        quotedText: quote, occurrence: occurrence, userText: "Not quite.",
        createdAt: Date(timeIntervalSince1970: 0))
}

/// The demo corpus's shapes, in the fictional universe.
private let detailedBody = """
    ## Quoll Harbor

    - Tide sensor calibration is finished on the north jetty.
    - Vexatron Labs asked for the ferry timetable a week early.
    - The harbour lights stay amber until the survey lands.

    ## Vexatron Labs

    The kelp survey moved to Thursday.
    """

/// The summary is markdown-parsed the same way, so it is the second section
/// whose rendered blocks are finer than its single anchor block.
private let summaryBody = """
    The ferry timetable ships Thursday.

    The kelp survey slipped a week and the harbour board wants a date.
    """

@Suite struct RenderedBlockPlacementTests {
    @Test(
        "every rendered block claims the row that quotes it",
        arguments: [summaryBody, detailedBody])
    func eachRenderedBlockClaimsItsOwnRow(body: String) {
        let uiTexts = CorrectionAnchoring.FoldedBlocks(
            MarkdownBlocks.parse(body).map { String($0.text.characters) })
        #expect(uiTexts.blocks.count > 1, "the fixture must produce several rendered blocks")
        for (index, text) in uiTexts.blocks.enumerated() {
            // What a whole-block invocation stores: the block's position among
            // the blocks whose folded text matches its own, so two blocks
            // carrying the same words anchor distinctly.
            let stored = CorrectionAnchoring.occurrence(ofBlockAt: index, in: uiTexts)
            let grouped = rowsByRenderedBlock(
                [note(quote: text, occurrence: stored)], uiTexts: uiTexts)
            #expect(
                grouped[index]?.count == 1,
                "block \(index) (\u{201C}\(text)\u{201D}) did not claim its own row")
            #expect(grouped.keys.count == 1)
        }
    }

    @Test("a bullet list is one anchor block and many rendered blocks — each keeps its own row")
    func listItemsPlaceIndividually() {
        let uiTexts = CorrectionAnchoring.FoldedBlocks(
            MarkdownBlocks.parse(detailedBody).map { String($0.text.characters) })
        let anchorBlocks = CorrectionAnchoring.blocks(
            of: NotesStructured(
                summary: "", detailedNotes: detailedBody, decisions: [], actionItems: [],
                userActionItems: []),
            section: .detailedNotes)
        // The whole list is ONE anchor block; the pane renders each item.
        let listAnchor = anchorBlocks.first { $0.contains("Tide sensor") }
        #expect(listAnchor?.contains("harbour lights") == true)

        let items = uiTexts.blocks.filter {
            $0.contains("Tide sensor") || $0.contains("harbour lights")
        }
        #expect(items.count == 2)
        let grouped = rowsByRenderedBlock(items.map { note(quote: $0) }, uiTexts: uiTexts)
        #expect(grouped.keys.count == 2, "two list items must occupy two rendered blocks")
        for (index, rows) in grouped {
            #expect(rows.count == 1)
            #expect(CorrectionAnchoring.fold(uiTexts.blocks[index]).contains(
                CorrectionAnchoring.fold(rows[0].quotedText)))
        }
    }

    @Test("a row is never dropped: a quote no rendered block carries falls to the last one")
    func unplaceableRowFallsToTheLastBlock() {
        let uiTexts = CorrectionAnchoring.FoldedBlocks(
            MarkdownBlocks.parse(detailedBody).map { String($0.text.characters) })
        let grouped = rowsByRenderedBlock([note(quote: "a phrase from another meeting")], uiTexts: uiTexts)
        #expect(grouped[uiTexts.blocks.count - 1]?.count == 1)
    }

    @Test("no rendered blocks, no placement")
    func emptySectionPlacesNothing() {
        #expect(
            rowsByRenderedBlock(
                [note(quote: "anything")], uiTexts: CorrectionAnchoring.FoldedBlocks([])
            ).isEmpty)
    }
}

@Suite struct UserActionAnchorTests {
    private let structured = NotesStructured(
        summary: "Quoll Harbor ferry timetable review.",
        detailedNotes: detailedBody,
        decisions: ["The ferry timetable ships Thursday."],
        actionItems: [ActionItem(owner: "Wren Calloway", text: "Send the tide survey to the harbour board.")],
        userActionItems: [ActionItem(owner: "", text: "Send the tide survey to the harbour board.")])

    @Test("the two action-item lists are separate anchor spaces")
    func aSharedQuoteResolvesOnlyWithinItsOwnSection() {
        let quote = "Send the tide survey to the harbour board."
        for section in [MeetingCorrection.Section.actionItem, .userActionItem] {
            let blocks = CorrectionAnchoring.blocks(of: structured, section: section)
            #expect(blocks.count == 1, "\(section) must carry exactly its own list")
            #expect(
                CorrectionAnchoring.resolve(quote: quote, occurrence: 0, in: blocks)?.blockIndex == 0)
        }
        // The meeting-wide list and the user's own list never share a block.
        let meetingBlocks = CorrectionAnchoring.blocks(of: structured, section: .actionItem)
        let userBlocks = CorrectionAnchoring.blocks(of: structured, section: .userActionItem)
        #expect(meetingBlocks == userBlocks, "the fixture's two lists carry the same text")
        #expect(
            CorrectionAnchoring.resolve(quote: quote, occurrence: 1, in: userBlocks)?.blockIndex == 0,
            "an out-of-range occurrence clamps INSIDE the section, never into the other list")
    }

    @Test("a user action item's anchor id can never collide with the meeting-wide list's")
    func anchorIDsAreDistinct() {
        for index in 0..<4 {
            #expect(UserActionAnchor.id(index) != NotesBlockAnchor.actionItem(index))
            #expect(UserActionAnchor.id(index) != NotesBlockAnchor.decision(index))
            #expect(UserActionAnchor.id(index) != NotesBlockAnchor.summary(index))
            #expect(UserActionAnchor.id(index) != NotesBlockAnchor.detailed(index))
        }
    }
}
