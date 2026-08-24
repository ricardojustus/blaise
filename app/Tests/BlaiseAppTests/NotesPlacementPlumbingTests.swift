import BlaiseCore
import Foundation
import Testing

@testable import BlaiseApp

// What the pane computes once per pass for each of its five rendered lists:
// the occurrence every block carries, and the rows that stand beside it. The
// fixtures are built so the CANONICAL anchor space and the RENDERED space
// disagree — a markdown summary that is one anchor block and several rendered
// ones, action lists whose blanks are dropped before rendering, the same
// sentence in two sections, and a section that repeats a block verbatim.

/// A meeting whose every section diverges from its rendered form.
private let structured = NotesStructured(
    summary: """
        The ferry timetable ships Thursday.

        The kelp survey slipped a week and the harbour board wants a date.
        """,
    detailedNotes: """
        - Tide sensor calibration is finished on the north jetty.
        - The harbour lights stay amber until the survey lands.

        Owner to be confirmed.

        Owner to be confirmed.
        """,
    decisions: [
        "The ferry timetable ships Thursday.",
        "The kelp survey moves to Thursday.",
        "The ferry timetable ships Thursday.",
    ],
    actionItems: [
        ActionItem(owner: "Wren Calloway", text: "   "),
        ActionItem(owner: "Wren Calloway", text: "Send the tide survey to the harbour board."),
        ActionItem(owner: "Ashby Fen", text: "Book the ferry drill."),
    ],
    userActionItems: [
        ActionItem(owner: "", text: "Reply to the Vexatron Labs schedule draft."),
        ActionItem(owner: "", text: ""),
        ActionItem(owner: "", text: "Walk the north jetty before the survey."),
    ])

/// The list each site anchors against — the pane's own, in the order it draws.
private func renderedList(_ section: MeetingCorrection.Section) -> [String] {
    switch section {
    case .summary:
        return MarkdownBlocks.parse(structured.summary).map { String($0.text.characters) }
    case .detailedNotes:
        return MarkdownBlocks.parse(
            structured.detailedNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        ).map { String($0.text.characters) }
    case .decision:
        return structured.decisions
    case .actionItem:
        return presentable(structured.actionItems)
    case .userActionItem:
        return presentable(structured.userActionItems)
    }
}

/// Both action lists render without their blank items, which is the space
/// their occurrences are counted in.
private func presentable(_ items: [ActionItem]) -> [String] {
    items.map(\.text).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

private func row(
    _ id: String, _ kind: MeetingCorrection.Kind, _ section: MeetingCorrection.Section,
    quote: String, occurrence: Int = 0, status: MeetingCorrection.Status = .pending
) -> MeetingCorrection {
    MeetingCorrection(
        id: id, meetingID: "meeting-1", kind: kind, section: section, quotedText: quote,
        occurrence: occurrence, userText: "Check this.", status: status,
        createdAt: Date(timeIntervalSince1970: 0))
}

/// The placements a grouping states, as (row id, block index, the occurrence
/// the row's anchor resolves to in that list) — sorted, so the comparison is
/// about content and not dictionary order.
private func placements(
    _ grouped: [Int: [MeetingCorrection]], in list: [String]
) -> [String] {
    grouped.flatMap { index, rows in
        rows.map { row -> String in
            let resolved = LegacyAnchoring.resolve(
                quote: row.quotedText, occurrence: row.occurrence, in: list)
            return "\(row.id)@\(index)#\(resolved.map { String($0.occurrence) } ?? "nil")"
        }
    }
    .sorted()
}

/// The same, computed by the legacy oracle over the site's own list: the rows
/// of that kind and section the reading column keeps, each placed on the block
/// its anchor resolves to.
private func oraclePlacements(
    _ rows: [MeetingCorrection], kind: MeetingCorrection.Kind,
    section: MeetingCorrection.Section, in list: [String]
) -> [String] {
    rows.filter { row in
        guard row.kind == kind, row.section == section else { return false }
        switch kind {
        case .annotation: return row.status != .resolved
        case .understanding: return row.status != .applied && row.status != .resolved
        }
    }
    .compactMap { row in
        guard
            let resolved = LegacyAnchoring.resolve(
                quote: row.quotedText, occurrence: row.occurrence, in: list)
        else { return nil }
        return "\(row.id)@\(resolved.blockIndex)#\(resolved.occurrence)"
    }
    .sorted()
}

@Suite struct NotesPlacementPlumbingTests {

    @Test("the rendered lists diverge from the canonical anchor spaces")
    func theFixtureActuallyDiverges() {
        // Without this the equivalence below would be asserted on a fixture
        // where the two spaces happen to agree, and would prove nothing.
        for section in [
            MeetingCorrection.Section.summary, .detailedNotes, .actionItem, .userActionItem,
        ] {
            #expect(
                renderedList(section)
                    != CorrectionAnchoring.blocks(of: structured, section: section),
                "\(section) must render a different list than it anchors in")
        }
        #expect(renderedList(.summary).count == 2, "one canonical block, two rendered")
        #expect(renderedList(.detailedNotes).count == 4, "a list item is its own rendered block")
        #expect(renderedList(.actionItem).count == 2, "the blank item is dropped")
        #expect(renderedList(.userActionItem).count == 2)
    }

    /// The two action lists are separate anchor spaces that the pane draws one
    /// under the other. Their texts differ, so a mix-up between exactly this
    /// pair — the easiest one to make — is visible here: each row's quote is
    /// carried by its own space and by no block of the other.
    @Test("a row anchored in one action space places in neither block of the other")
    func theActionSpacesDoNotCrossOver() {
        let lists: [MeetingCorrection.Section: [String]] = [
            .actionItem: renderedList(.actionItem), .userActionItem: renderedList(.userActionItem),
        ]
        #expect(lists[.actionItem] != lists[.userActionItem], "the two action spaces must differ")
        let rows = [
            row("act-only", .annotation, .actionItem, quote: "Book the ferry drill."),
            row("user-only", .annotation, .userActionItem,
                quote: "north jetty before the survey"),
        ]
        for (section, list) in lists {
            let own = section == .actionItem ? "act-only" : "user-only"
            let foreign = rows.first { $0.id != own }!
            #expect(
                LegacyAnchoring.resolve(quote: foreign.quotedText, occurrence: 0, in: list) == nil,
                "\(foreign.section)'s quote must match no block of \(section)")
            let grouped = rowsByAnchoredBlock(
                rows, kind: .annotation, section: section,
                blocks: CorrectionAnchoring.FoldedBlocks(list))
            #expect(
                grouped.values.flatMap { $0 }.map(\.id) == [own],
                "\(section) places its own row and only its own")
        }
    }

    @Test("every site's blocks carry the occurrence the legacy rule gave them")
    func occurrencesMatchTheOracle() {
        let expected: [MeetingCorrection.Section: [Int]] = [
            .summary: [0, 0],
            // The two identical paragraphs are the second and third rendered
            // blocks, and they anchor distinctly.
            .detailedNotes: [0, 0, 0, 1],
            .decision: [0, 0, 1],
            .actionItem: [0, 0],
            .userActionItem: [0, 0],
        ]
        for (section, expectedOccurrences) in expected {
            let list = renderedList(section)
            let computed = blockOccurrences(in: CorrectionAnchoring.FoldedBlocks(list))
            #expect(computed == expectedOccurrences, "\(section) occurrences")
            #expect(
                computed == list.indices.map {
                    LegacyAnchoring.occurrence(ofBlockAt: $0, in: list)
                },
                "\(section) occurrences disagree with the legacy rule")
        }
    }

    /// The three list sites: decisions, action items, and the reader's own
    /// action items. Every row of the fixture is eligible, so what is asserted
    /// here is placement — including a quote that belongs to another section
    /// and a stored occurrence that picks the second of two identical blocks.
    @Test("each list site places its rows exactly where the legacy rule placed them")
    func listSitePlacementsMatchTheOracle() {
        let rows = [
            row("dec-note", .annotation, .decision, quote: "The ferry timetable ships Thursday.",
                occurrence: 1),
            row("dec-pending", .understanding, .decision, quote: "kelp survey moves"),
            row("dec-stale", .annotation, .decision, quote: "the tide survey", status: .stale),
            row("act-note", .annotation, .actionItem, quote: "tide survey to the harbour board"),
            row("act-pending", .understanding, .actionItem, quote: "Book the ferry drill."),
            row("user-note", .annotation, .userActionItem, quote: "north jetty before the survey"),
            row("user-pending", .understanding, .userActionItem,
                quote: "Vexatron Labs schedule draft"),
            // Same sentence, wrong section: it must never cross over.
            row("summary-note", .annotation, .summary, quote: "The ferry timetable ships Thursday."),
        ]
        let expected: [MeetingCorrection.Section: (annotation: [String], understanding: [String])] = [
            // The stored occurrence 1 picks the SECOND identical decision.
            .decision: (["dec-note@2#1"], ["dec-pending@1#0"]),
            .actionItem: (["act-note@0#0"], ["act-pending@1#0"]),
            .userActionItem: (["user-note@1#0"], ["user-pending@0#0"]),
        ]
        for (section, expectedPlacements) in expected {
            let list = renderedList(section)
            let folded = CorrectionAnchoring.FoldedBlocks(list)
            for (kind, wanted) in [
                (MeetingCorrection.Kind.annotation, expectedPlacements.annotation),
                (.understanding, expectedPlacements.understanding),
            ] {
                let grouped = rowsByAnchoredBlock(
                    rows, kind: kind, section: section, blocks: folded)
                #expect(placements(grouped, in: list) == wanted, "\(section)/\(kind) placement")
                #expect(
                    placements(grouped, in: list)
                        == oraclePlacements(rows, kind: kind, section: section, in: list),
                    "\(section)/\(kind) disagrees with the legacy rule")
            }
        }
        // `dec-stale` quotes a passage no decision carries: it is placed on no
        // block at all, and the section's tail surfaces it instead.
        let decisionNotes = rowsByAnchoredBlock(
            rows, kind: .annotation, section: .decision,
            blocks: CorrectionAnchoring.FoldedBlocks(renderedList(.decision)))
        #expect(!decisionNotes.values.flatMap { $0 }.contains { $0.id == "dec-stale" })
    }

    /// The eligibility rules the list sites carry: an annotation leaves the
    /// page when the reader resolves it; a correction leaves when it is applied
    /// or resolved. Every status, both kinds, at all three list sites — a
    /// dropped predicate shows up here as a row that should not be on the page.
    @Test("every status × both kinds, at every list site")
    func statusEligibilityIsExplicit() {
        let quotes: [MeetingCorrection.Section: String] = [
            .decision: "The kelp survey moves to Thursday.",
            .actionItem: "Book the ferry drill.",
            .userActionItem: "Walk the north jetty before the survey.",
        ]
        let eligible: [MeetingCorrection.Kind: Set<MeetingCorrection.Status>] = [
            .annotation: [.pending, .applied, .stale],
            .understanding: [.pending, .stale],
        ]
        for (section, quote) in quotes {
            let folded = CorrectionAnchoring.FoldedBlocks(renderedList(section))
            for kind in [MeetingCorrection.Kind.annotation, .understanding] {
                for status in [MeetingCorrection.Status.pending, .applied, .stale, .resolved] {
                    let subject = row("subject", kind, section, quote: quote, status: status)
                    let placed = rowsByAnchoredBlock(
                        [subject], kind: kind, section: section, blocks: folded)
                        .values.flatMap { $0 }.contains { $0.id == "subject" }
                    #expect(
                        placed == eligible[kind]!.contains(status),
                        "\(section)/\(kind)/\(status) placement eligibility")
                }
            }
        }
    }

    /// The two coarse sites: the summary and the detailed notes anchor in the
    /// canonical space and RENDER a finer one, so their rows are re-resolved
    /// against what the reader sees — and a row no rendered block carries falls
    /// to the section's last block rather than being dropped.
    @Test("the coarse sites re-place their rows against the rendered list")
    func coarseSitePlacementsMatchTheOracle() {
        let cases: [(MeetingCorrection.Section, [MeetingCorrection], [String])] = [
            (
                .summary,
                [
                    row("sum-first", .annotation, .summary, quote: "ferry timetable ships"),
                    row("sum-second", .annotation, .summary, quote: "the harbour board wants a date"),
                    row("sum-orphan", .annotation, .summary, quote: "the north jetty"),
                ],
                ["sum-first@0#0", "sum-orphan@1#nil", "sum-second@1#0"]
            ),
            (
                .detailedNotes,
                [
                    row("det-item", .annotation, .detailedNotes, quote: "harbour lights stay amber"),
                    // The stored occurrence names the SECOND identical paragraph.
                    row("det-repeat", .annotation, .detailedNotes, quote: "Owner to be confirmed.",
                        occurrence: 1),
                    row("det-orphan", .annotation, .detailedNotes, quote: "the kelp survey"),
                ],
                ["det-item@1#0", "det-orphan@3#nil", "det-repeat@3#1"]
            ),
        ]
        for (section, rows, expected) in cases {
            let list = renderedList(section)
            let grouped = rowsByRenderedBlock(rows, uiTexts: CorrectionAnchoring.FoldedBlocks(list))
            #expect(placements(grouped, in: list) == expected, "\(section) placement")
            // The oracle's own answer, with the same fallback-to-last rule.
            let fallback = list.count - 1
            let oracle = rows.map { row -> String in
                let resolved = LegacyAnchoring.resolve(
                    quote: row.quotedText, occurrence: row.occurrence, in: list)
                return "\(row.id)@\(resolved?.blockIndex ?? fallback)"
                    + "#\(resolved.map { String($0.occurrence) } ?? "nil")"
            }
            .sorted()
            #expect(placements(grouped, in: list) == oracle, "\(section) disagrees with the oracle")
        }
    }
}
