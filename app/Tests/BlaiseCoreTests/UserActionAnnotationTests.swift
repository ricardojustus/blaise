import Foundation
import Testing

@testable import BlaiseCore

// The reader's own action items are their own anchor space. A note taken there
// must render under that list — never under the meeting-wide one, and never
// silently nowhere.

private let structured = NotesStructured(
    summary: "Quoll Harbor ferry timetable review.",
    detailedNotes: "The kelp survey moved to Thursday.",
    decisions: ["The ferry timetable ships Thursday."],
    actionItems: [ActionItem(owner: "Wren Calloway", text: "Send the tide survey to the harbour board.")],
    userActionItems: [ActionItem(owner: "", text: "Send the tide survey to the harbour board.")])

private func annotation(section: MeetingCorrection.Section, quote: String, text: String)
    -> MeetingCorrection
{
    MeetingCorrection(
        id: "note-\(section.rawValue)", meetingID: "meeting-1", kind: .annotation,
        section: section, quotedText: quote, userText: text, status: .applied,
        createdAt: Date(timeIntervalSince1970: 0))
}

@Suite struct UserActionAnnotationTests {
    private let quote = "Send the tide survey to the harbour board."

    @Test("each action-item list anchors only its own blocks")
    func separateAnchorSpaces() {
        #expect(
            CorrectionAnchoring.blocks(of: structured, section: .userActionItem)
                == structured.userActionItems.map(\.text))
        #expect(
            CorrectionAnchoring.blocks(of: structured, section: .actionItem)
                == structured.actionItems.map(\.text))
    }

    @Test("a note on a user action item renders under that list, not the meeting-wide one")
    func userActionNoteReachesTheDocument() throws {
        let markdown = try NotesRenderer.render(
            structured, language: "en", meetingTitle: "Ferry sync", userName: "Sam",
            annotations: [annotation(section: .userActionItem, quote: quote, text: "Before the survey lands.")])
        let aside = "> **Your note** (on \u{201C}\(quote)\u{201D}): Before the survey lands."
        #expect(markdown.contains(aside))
        #expect(!markdown.contains("## Your notes"), "an anchored note never falls to the tail")
        // Placement: the aside follows the user's list, which follows the
        // meeting-wide one.
        let asideAt = try #require(markdown.range(of: aside)).lowerBound
        let meetingListAt = try #require(markdown.range(of: "Wren Calloway")).lowerBound
        #expect(asideAt > meetingListAt)
    }

    @Test("the two lists never borrow each other's notes")
    func notesDoNotCrossLists() throws {
        let markdown = try NotesRenderer.render(
            structured, language: "en", meetingTitle: "Ferry sync", userName: "Sam",
            annotations: [
                annotation(section: .userActionItem, quote: quote, text: "Mine."),
                annotation(section: .actionItem, quote: quote, text: "Theirs."),
            ])
        #expect(markdown.contains("Mine."))
        #expect(markdown.contains("Theirs."))
        let mineAt = try #require(markdown.range(of: "Mine.")).lowerBound
        let theirsAt = try #require(markdown.range(of: "Theirs.")).lowerBound
        #expect(theirsAt < mineAt, "the meeting-wide aside sits with its own list, above the user's")
    }

    @Test("a user-action note whose quote is gone is still surfaced, never dropped")
    func staleUserActionNoteReachesTheTail() throws {
        let markdown = try NotesRenderer.render(
            structured, language: "en", meetingTitle: "Ferry sync", userName: "Sam",
            annotations: [
                annotation(
                    section: .userActionItem, quote: "an item the rewrite removed",
                    text: "Still matters.")
            ])
        #expect(markdown.contains("## Your notes"))
        #expect(markdown.contains("Still matters."))
    }
}
