import AppKit
import BlaiseCore
import Foundation
import Testing

@testable import BlaiseApp

// The pane half of the whole-table fallback: a note or a pending correction
// aimed at a whole table (a click on the hosted table) stands under the table,
// never in the "Your notes" tail; every other one-piece row is grouped as
// before. Fictional notes only (Vexatron Labs / Quoll Harbor).

private let table = "| Probe | Latency |\n| --- | --- |\n| Kestrel | 12 ms |\n| Osprey | 4 ms |"

private let structured = NotesStructured(
    title: "Quoll Harbor sonar review",
    summary: "Vexatron Labs ran the latency probes.\n\n" + table
        + "\n\nThe [pilot](https://example.com/pilot) budget stays at US$ 40.000,00.",
    detailedNotes: "The rig travels by barge.\n\n" + table + "\n\n```\nstep one\n\nstep two\n```\n\nAfter the table.",
    decisions: ["Keep the barge contract", "Ship the sonar rig in May"],
    actionItems: [ActionItem(owner: "Dana Marsh", text: "File the harbor permits")],
    userActionItems: [ActionItem(owner: "Me", text: "Send the permit draft")])

@MainActor
private func build() -> NotesDocument {
    NotesDocumentBuilder.build(
        NotesDocInput(
            structured: structured, doneKeys: [], searchTerms: [], portuguese: false,
            userActionTitle: "Demo User — Action Items", direction: .aquarela))
}

private func row(
    _ id: String, _ kind: MeetingCorrection.Kind, _ section: MeetingCorrection.Section, _ quote: String,
    occurrence: Int = 0
) -> MeetingCorrection {
    MeetingCorrection(
        id: id, meetingID: "meeting-table", kind: kind, section: section, quotedText: quote,
        occurrence: occurrence, userText: "Note \(id)", status: kind == .annotation ? .applied : .pending,
        createdAt: Date(timeIntervalSince1970: 1_780_000_000))
}

@MainActor
@Suite struct WholeTablePaneTests {

    @Test("a whole-table pick: the note and the pending correction stand under the table, in both sections; neither is in the tail")
    func placedUnderTheTable() throws {
        let doc = build()
        for section in [MeetingCorrection.Section.summary, .detailedNotes] {
            let block = try #require(doc.blocks.first { $0.section == section && $0.table != nil })
            // The target a click on the table builds (the selection bar's pick).
            let target = NotesEditingEntry.target(
                .note, section: block.section, anchorID: block.anchorID, blockText: block.blockText,
                occurrence: block.occurrence)
            let note = row("note", .annotation, section, target.quotedText, occurrence: target.occurrence)
            let fix = row("fix", .understanding, section, target.quotedText, occurrence: target.occurrence)
            let (rows, _) = notesDocRows([note, fix], document: doc, structured: structured)
            #expect(rows[block.anchorID]?.notes.map(\.id) == ["note"])
            #expect(rows[block.anchorID]?.pending.map(\.id) == ["fix"])
            #expect(notesDocUnanchored([note, fix], structured: structured, space: doc.space).isEmpty)
        }
    }

    @Test("byte identity: non-table one-piece rows are grouped and tailed as the base revision did")
    func nonTableRowsUnchanged() {
        let doc = build()
        let rows = [
            row("a", .annotation, .summary, "Vexatron Labs ran"),
            row("b", .annotation, .summary, "The pilot budget stays"),
            row("c", .understanding, .summary, "latency probes"),
            row("d", .annotation, .detailedNotes, "step one step two"),
            row("e", .understanding, .detailedNotes, "After the table."),
            row("f", .annotation, .detailedNotes, "Kestrel"),
            row("g", .annotation, .decision, "Ship the sonar rig in May", occurrence: 3),
            row("h", .understanding, .actionItem, "File the harbor permits"),
            row("i", .annotation, .userActionItem, "a quote that is gone"),
        ]
        let (grouped, _) = notesDocRows(rows, document: doc, structured: structured)
        let signature = grouped.keys.sorted().map { anchor in
            "\(anchor):\(grouped[anchor]!.notes.map(\.id).joined())/\(grouped[anchor]!.pending.map(\.id).joined())"
        }
        #expect(signature == [
            "notes-action-0:/h", "notes-decision-1:g/", "notes-detailed-1:f/", "notes-detailed-3:/e", "notes-summary-0:a/c",
        ])
        #expect(notesDocUnanchored(rows, structured: structured, space: doc.space).map(\.id) == ["b", "d", "i"])
    }
}
