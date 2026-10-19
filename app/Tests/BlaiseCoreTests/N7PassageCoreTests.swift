import Foundation
import Testing

@testable import BlaiseCore

// n7 stage 1 — the core halves of cross-paragraph AI Correct / Add Note: the
// rendered space, the passage rule, the prompt lines, the per-piece withdrawn
// check and the wire joiner. Every fixture is fictional (Vexatron Labs /
// Quoll Harbor).

private let sep = "\u{2029}"

private func passage(_ pieces: String...) -> String { pieces.joined(separator: sep) }

private func notes(
    summary: String = "",
    detailedNotes: String = "",
    decisions: [String] = [],
    actionItems: [ActionItem] = [],
    userActionItems: [ActionItem] = []
) -> NotesStructured {
    NotesStructured(
        title: "Quoll Harbor sonar review", summary: summary, detailedNotes: detailedNotes,
        decisions: decisions, actionItems: actionItems, userActionItems: userActionItems)
}

/// Each instance as (section, index) of every placed piece — nil for an
/// empty-fold piece — the anchor last.
private func layout(
    _ quote: String, _ section: MeetingCorrection.Section, in structured: NotesStructured
) -> [[String]] {
    let space = CorrectionAnchoring.RenderedSpace(structured)
    return CorrectionAnchoring.passageInstances(quote: quote, section: section, in: space).map {
        instance in
        instance.placements.map { placement in
            guard let placement else { return "-" }
            let id = space.blocks[placement.block].id
            return "\(id.section.rawValue)#\(id.index)"
        }
    }
}

private func anchorID(
    _ quote: String, occurrence: Int, _ section: MeetingCorrection.Section,
    in structured: NotesStructured
) -> String? {
    let space = CorrectionAnchoring.RenderedSpace(structured)
    guard
        let resolved = CorrectionAnchoring.resolvePassage(
            quote: quote, occurrence: occurrence, section: section, in: space)
    else { return nil }
    let id = space.blocks[resolved.instance.anchorBlock].id
    return "\(id.section.rawValue)#\(id.index)@\(resolved.occurrence)"
}

// MARK: - AC-3 (core half): the rendered space

@Suite struct N7RenderedBlocksTests {

    @Test("AC-3: renderedBlocks covers every section and block kind, in documentOrder, stable identities")
    func everySectionAndBlockKind() {
        let blocks = CorrectionAnchoring.renderedBlocks(of: N7GoldenFixture.notes)
        let rows = blocks.map { "\($0.id.section.rawValue)#\($0.id.index) \($0.text)" }
        #expect(rows == [
            "summary#0 Vexatron Labs will ship the sonar rig in May.",
            "summary#1 The pilot budget stays at US$ 40.000,00.",
            "summary#2 Dana Marsh owns the harbor permits.",
            "user_action_item#0 Review the barge contract",
            "user_action_item#1 Send the permit draft",
            "decision#0 Ship the sonar rig in May",
            "decision#1 Keep the barge contract",
            "decision#2 Ship the sonar rig in May",
            "action_item#0 File the harbor permits",
            "action_item#1 Book the tide window",
            "detailed_notes#0 Logistics",
            "detailed_notes#1 The rig travels by barge.",
            "detailed_notes#2 Load the buoys",
            "detailed_notes#3 Seal the crates",
            "detailed_notes#4 step one\n\nstep two\n",
            "detailed_notes#5 Item | Owner\nBuoys | Dana",
            "detailed_notes#6 \u{2E3B}",
            "detailed_notes#7 Harlan Voss flagged the tide window.",
        ])
        #expect(
            CorrectionAnchoring.documentOrder
                == [.summary, .userActionItem, .decision, .actionItem, .detailedNotes])
        // Deterministic, and a block's identity does not depend on other
        // sections: editing the decisions leaves every other identity/text.
        #expect(CorrectionAnchoring.renderedBlocks(of: N7GoldenFixture.notes) == blocks)
        var edited = N7GoldenFixture.notes
        edited.decisions = ["Only one decision now"]
        let after = CorrectionAnchoring.renderedBlocks(of: edited)
        #expect(
            after.filter { $0.section != .decision } == blocks.filter { $0.section != .decision })
    }

    @Test("one parse: the space built from parsed notes equals the space built from the notes, folds included")
    func sharedParseGivesTheSameSpace() {
        let notes = N7GoldenFixture.notes
        let shared = CorrectionAnchoring.RenderedSpace(notes, parsed: CorrectionAnchoring.ParsedNotes(notes))
        let own = CorrectionAnchoring.RenderedSpace(notes)
        #expect(shared.blocks == own.blocks)
        for section in CorrectionAnchoring.documentOrder {
            let texts = own.blocks.filter { $0.section == section }.map(\.text)
            let folded = shared.foldedBlocks(of: section)
            #expect(folded.blocks == texts)
            #expect(folded.folds == CorrectionAnchoring.FoldedBlocks(texts).folds)
        }
    }

    @Test("AC-3: completed action items and tables are blocks; blank items and empty detailed notes are not")
    func completedItemsTablesAndBlanks() {
        // Completion is display state (the pane's done keys); the rendered
        // space counts every item with text, in stored order.
        let structured = notes(
            summary: "",
            detailedNotes: "   \n\n  ",
            actionItems: [
                ActionItem(owner: "Dana Marsh", text: "File the permits"),
                ActionItem(owner: "Dana Marsh", text: " \n"),
                ActionItem(owner: "Harlan Voss", text: "Book the tide window"),
            ],
            userActionItems: [ActionItem(owner: "Me", text: "Confirm the harbor slot")])
        let blocks = CorrectionAnchoring.renderedBlocks(of: structured)
        #expect(blocks.map(\.id) == [
            .init(section: .userActionItem, index: 0),
            .init(section: .actionItem, index: 0),
            .init(section: .actionItem, index: 1),
        ])
        #expect(CorrectionAnchoring.presentableItems(structured.actionItems).map(\.text)
            == ["File the permits", "Book the tide window"])
        let table = CorrectionAnchoring.renderedBlocks(
            of: notes(detailedNotes: "| Step |\n| --- |\n| Tow the rig |"))
        #expect(table.map(\.text) == ["Step\nTow the rig"])
    }

    @Test("AC-3: a fenced code block with a blank line inside is ONE rendered block")
    func codeBlockIsOneBlock() {
        let blocks = CorrectionAnchoring.renderedBlocks(
            of: notes(detailedNotes: "```\nstep one\n\nstep two\n```\n\nAfter the code."))
        #expect(blocks.map(\.text) == ["step one\n\nstep two\n", "After the code."])
        // …while the anchoring space splits it on the blank line.
        #expect(
            CorrectionAnchoring.blocks(
                of: notes(detailedNotes: "```\nstep one\n\nstep two\n```"), section: .detailedNotes
            ).count == 2)
    }

    @Test("AC-3: pieces split on U+2029 before any fold; a quote without one is itself")
    func piecesSplitBeforeTheFold() {
        #expect(CorrectionAnchoring.pieces(passage("Alpha **one**", "beta two")) == ["Alpha **one**", "beta two"])
        #expect(CorrectionAnchoring.fold(passage("a", "b")) == "a b", "the fold loses the boundary")
        for quote in N7GoldenFixture.rows.map(\.quotedText) + N7GoldenFixture.probeQuotes {
            #expect(CorrectionAnchoring.pieces(quote) == [quote])
            #expect(!CorrectionAnchoring.isPassage(quote))
        }
        #expect(CorrectionAnchoring.isPassage(passage("a", "b")))
    }
}

// MARK: - AC-3 (core half): the passage rule

@Suite struct N7PassageRuleTests {

    @Test("AC-3: consecutive summary paragraphs")
    func consecutiveSummaryParagraphs() {
        let structured = notes(summary: "Quoll Harbor signs in May.\n\nShip the Vexatron pilot to Quoll Harbor.")
        #expect(
            layout(passage("signs in May.", "Ship the Vexatron pilot"), .summary, in: structured)
                == [["summary#0", "summary#1"]])
    }

    @Test("AC-3: summary [A, B, A, B] — the second copy is occurrence 1, both pieces on the second copy")
    func repeatedPassageInsideOneSummary() {
        let structured = notes(
            summary: "Quoll Harbor signs in May.\n\nShip the pilot.\n\nQuoll Harbor signs in May.\n\nShip the pilot.")
        let quote = passage("Quoll Harbor signs in May.", "Ship the pilot.")
        #expect(layout(quote, .summary, in: structured) == [
            ["summary#0", "summary#1"], ["summary#2", "summary#3"],
        ])
        #expect(anchorID(quote, occurrence: 1, .summary, in: structured) == "summary#3@1")
        // resolve clamps an out-of-range stored occurrence to the last instance.
        #expect(anchorID(quote, occurrence: 7, .summary, in: structured) == "summary#3@1")
    }

    @Test("AC-3: detailed-notes paragraphs; a list written without blank lines; list items")
    func detailedParagraphsListsAndItems() {
        let detailed = notes(detailedNotes: "First detail here.\n\nSecond detail there.")
        #expect(
            layout(passage("detail here.", "Second detail"), .detailedNotes, in: detailed)
                == [["detailed_notes#0", "detailed_notes#1"]])

        // One anchoring block, three rendered blocks: three bullets selected.
        let list = notes(detailedNotes: "- Load the buoys\n- Seal the crates\n- Tow the rig")
        #expect(CorrectionAnchoring.blocks(of: list, section: .detailedNotes).count == 1)
        #expect(
            layout(passage("the buoys", "Seal the crates", "Tow"), .detailedNotes, in: list)
                == [["detailed_notes#0", "detailed_notes#1", "detailed_notes#2"]])

        let items = notes(actionItems: [
            ActionItem(owner: "Dana Marsh", text: "File the permits"),
            ActionItem(owner: "Harlan Voss", text: "Book the tide window"),
        ])
        #expect(
            layout(passage("the permits", "Book the tide"), .actionItem, in: items)
                == [["action_item#0", "action_item#1"]])
    }

    @Test("AC-3: a code block with a blank line inside, plus the next paragraph")
    func codeBlockPlusNextParagraph() {
        let structured = notes(detailedNotes: "```\nstep one\n\nstep two\n```\n\nAfter the code.")
        #expect(
            layout(passage("step one\n\nstep two", "After the code."), .detailedNotes, in: structured)
                == [["detailed_notes#0", "detailed_notes#1"]])
    }

    @Test("AC-3: a paragraph containing a link matches by its rendered text")
    func paragraphWithALink() {
        let structured = notes(summary: "Read the [pilot brief](https://example.com/brief) today.\n\nThen sign.")
        #expect(
            layout(passage("Read the pilot brief today.", "Then sign."), .summary, in: structured)
                == [["summary#0", "summary#1"]])
    }

    @Test("AC-3: cross-section — summary into decisions; decisions into action items")
    func crossSection() {
        let structured = notes(
            summary: "Quoll Harbor signs in May.",
            decisions: ["Ship the Vexatron pilot to Quoll Harbor"],
            actionItems: [ActionItem(owner: "Dana Marsh", text: "File the harbor permits")],
            userActionItems: [ActionItem(owner: "Me", text: "Review the barge contract")])
        let summaryToDecision = passage("Quoll Harbor signs in May", "Ship the Vexatron pilot")
        #expect(layout(summaryToDecision, .decision, in: structured) == [["summary#0", "decision#0"]])
        let space = CorrectionAnchoring.RenderedSpace(structured)
        let resolved = CorrectionAnchoring.resolvePassage(
            quote: summaryToDecision, occurrence: 0, section: .decision, in: space)
        #expect(resolved?.instance.sections(in: space) == [.summary, .decision])

        #expect(
            layout(passage("Ship the Vexatron pilot to Quoll Harbor", "File the"), .actionItem, in: structured)
                == [["decision#0", "action_item#0"]])
    }

    @Test("AC-3: a divider or a table between two paragraphs")
    func dividerOrTableBetween() {
        let divided = notes(detailedNotes: "Before the rule.\n\n---\n\nAfter the rule.")
        #expect(
            layout(passage("Before the rule.", "After the rule."), .detailedNotes, in: divided)
                == [["detailed_notes#0", "detailed_notes#2"]])
        let tabled = notes(detailedNotes: "Before the table.\n\n| a | b |\n| - | - |\n| 1 | 2 |\n\nAfter the table.")
        #expect(
            layout(passage("Before the table.", "After the table."), .detailedNotes, in: tabled)
                == [["detailed_notes#0", "detailed_notes#2"]])
    }

    @Test("AC-3: an empty-fold middle piece takes no part; an empty-fold LAST piece matches nothing")
    func emptyFoldPieces() {
        let structured = notes(detailedNotes: "Before the rule.\n\n---\n\nAfter the rule.")
        #expect(
            layout(passage("Before the rule.", " ** ", "After"), .detailedNotes, in: structured)
                == [["detailed_notes#0", "-", "detailed_notes#2"]])
        #expect(layout(passage("Before the rule.", "__"), .detailedNotes, in: structured).isEmpty)
        #expect(layout(passage("Before the rule.", ""), .detailedNotes, in: structured).isEmpty)
    }

    @Test("AC-3: a reversed passage, and two identical pieces over one copy, give no instance")
    func reversedAndIdentical() {
        let structured = notes(detailedNotes: "Before the rule.\n\nAfter the rule.")
        #expect(layout(passage("After the rule.", "Before the rule."), .detailedNotes, in: structured).isEmpty)
        let once = notes(summary: "The barge leaves once.")
        #expect(layout(passage("once", "once"), .summary, in: once).isEmpty)
        // Order and distinctness hold INSIDE a block too: a passage within one
        // paragraph places its earlier piece before the later one.
        #expect(layout(passage("barge", "once"), .summary, in: once) == [["summary#0", "summary#0"]])
        #expect(layout(passage("once", "barge"), .summary, in: once).isEmpty)
    }

    @Test("AC-3/R3: a completed item or a table between two selected blocks that repeats the earlier piece takes it")
    func lenientWalkTakesTheNearerRepeat() {
        // Stored order: the open item first, its completed duplicate second.
        // The pane draws the completed one after the open one, so a drag from
        // the open item into the decisions passes it; the walk (stored order)
        // meets the completed copy first. Anchor and occurrence are the
        // dragged ones.
        let structured = notes(
            decisions: ["Keep the barge contract"],
            userActionItems: [
                ActionItem(owner: "Me", text: "Book the tide window"),
                ActionItem(owner: "Me", text: "Book the tide window"),
            ])
        let quote = passage("Book the tide window", "Keep the barge")
        #expect(layout(quote, .decision, in: structured) == [["user_action_item#1", "decision#0"]])
        #expect(anchorID(quote, occurrence: 0, .decision, in: structured) == "decision#0@0")

        let tabled = notes(detailedNotes: "Tow the rig.\n\n| Step |\n| --- |\n| Tow the rig |\n\nThen anchor here.")
        #expect(
            layout(passage("Tow the rig", "Then anchor"), .detailedNotes, in: tabled)
                == [["detailed_notes#1", "detailed_notes#2"]])
    }

    @Test("AC-3: instances come from the row's section only; inside it, the same words in one block are an ordered instance")
    func instancesComeFromTheRowsSection() {
        let structured = notes(
            summary: "Alpha one.\n\nBeta two.",
            detailedNotes: "Alpha one. Beta two. Both appear in this paragraph.")
        let quote = passage("Alpha one.", "Beta two.")
        // The raw space would have matched the unrelated paragraph.
        #expect(
            CorrectionAnchoring.matches(
                quote: quote, in: CorrectionAnchoring.blocks(of: structured, section: .detailedNotes))
                == [0])
        // A summary row never takes the detailed-notes paragraph.
        #expect(layout(quote, .summary, in: structured) == [["summary#0", "summary#1"]])
        // A detailed-notes row does: both pieces, in order, inside its one block.
        #expect(layout(quote, .detailedNotes, in: structured) == [["detailed_notes#0", "detailed_notes#0"]])
    }

    @Test("H-1: the passage walk scales — a missing earlier piece and a frequently repeated last piece")
    func passageWalkScales() {
        // 626 rendered blocks, 75.000 characters: every decision's "harbor"
        // takes its "Quoll" from the summary, up to 625 blocks back.
        let summary = "Quoll " + String(repeating: "z", count: 54)
        let decisions = Array(repeating: "harbor " + String(repeating: "z", count: 113), count: 624)
            + ["harbor " + String(repeating: "z", count: 53)]
        let farSpace = CorrectionAnchoring.RenderedSpace(notes(summary: summary, decisions: decisions))
        #expect(farSpace.blocks.count == 626)
        #expect(farSpace.blocks.map(\.text.count).reduce(0, +) == 75_000)
        // One block holding "go" 25.000 times; the earlier piece is nowhere.
        let repeatedSpace = CorrectionAnchoring.RenderedSpace(
            notes(decisions: [String(repeating: "go ", count: 25_000)]))

        var farCounts: Set<Int> = []
        var repeatedCounts: Set<Int> = []
        var farFromSummary = true
        // The bound is this thread's CPU time: the walk is synchronous on one thread, and wall
        // time also counts the time other suites running in parallel take the CPU from it.
        let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let elapsed = ContinuousClock().measure {
            for _ in 0 ..< 50 {
                let far = CorrectionAnchoring.passageInstances(
                    quote: passage("Quoll", "harbor"), section: .decision, in: farSpace)
                farCounts.insert(far.count)
                farFromSummary = farFromSummary && far.allSatisfy { $0.placements[0]?.block == 0 }
                repeatedCounts.insert(
                    CorrectionAnchoring.passageInstances(
                        quote: passage("Quoll", "go"), section: .decision, in: repeatedSpace
                    ).count)
            }
        }
        #expect(farCounts == [625])
        #expect(farFromSummary)
        #expect(repeatedCounts == [0])
        let cpu = Duration.nanoseconds(Int64(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart))
        print("H-1 scaling: 50 rows of each shape in \(cpu) of CPU time, \(elapsed) wall")
        #expect(cpu < .seconds(10), "50 rows of each shape took \(cpu) of CPU time")
    }

    @Test("AC-3: after reanchor, every fixture's stored occurrence still names the same instance")
    func reanchorKeepsTheInstance() {
        let fixtures: [(NotesStructured, String, MeetingCorrection.Section, Int)] = [
            (notes(summary: "Quoll Harbor signs in May.\n\nShip the pilot.\n\nQuoll Harbor signs in May.\n\nShip the pilot."),
             passage("Quoll Harbor signs in May.", "Ship the pilot."), .summary, 1),
            (notes(summary: "Quoll Harbor signs in May.\n\nShip the pilot."),
             passage("signs in May.", "Ship the"), .summary, 0),
            (notes(detailedNotes: "- Load the buoys\n- Seal the crates\n- Tow the rig\n- Load the buoys\n- Seal the crates"),
             passage("Load the buoys", "Seal the crates"), .detailedNotes, 1),
            (notes(detailedNotes: "```\nstep one\n\nstep two\n```\n\nAfter the code."),
             passage("step one\n\nstep two", "After the code."), .detailedNotes, 0),
            (notes(summary: "Quoll Harbor signs in May.", decisions: ["Ship the pilot", "Ship the pilot"]),
             passage("signs in May", "Ship the pilot"), .decision, 1),
            (notes(decisions: ["Keep the barge"], actionItems: [ActionItem(owner: "Dana Marsh", text: "File the permits")]),
             passage("Keep the barge", "File the"), .actionItem, 0),
        ]
        for (index, (structured, quote, section, occurrence)) in fixtures.enumerated() {
            let space = CorrectionAnchoring.RenderedSpace(structured)
            let before = CorrectionAnchoring.resolvePassage(
                quote: quote, occurrence: occurrence, section: section, in: space)
            #expect(before?.occurrence == occurrence, "fixture \(index)")
            let row = MeetingCorrection(
                id: "row-\(index)", meetingID: N7GoldenFixture.meetingID, kind: .annotation,
                section: section, quotedText: quote, occurrence: occurrence, userText: "Note",
                status: .stale, createdAt: N7GoldenFixture.baseTime)
            let updates = CorrectionAnchoring.reanchor(annotations: [row], against: structured)
            #expect(updates == [.init(id: row.id, occurrence: occurrence, status: .applied)], "fixture \(index)")
            let after = CorrectionAnchoring.resolvePassage(
                quote: quote, occurrence: updates[0].occurrence, section: section, in: space)
            #expect(after?.instance == before?.instance, "fixture \(index)")
        }
    }

    @Test("AC-3: reanchor — a passage whose first piece is gone goes stale; resolved rows stay resolved")
    func reanchorStaleAndResolved() {
        let structured = notes(summary: "Quoll Harbor signs in May.\n\nShip the pilot.")
        let gone = MeetingCorrection(
            id: "gone", meetingID: N7GoldenFixture.meetingID, kind: .annotation, section: .summary,
            quotedText: passage("The barge left", "Ship the pilot."), occurrence: 0,
            userText: "Note", status: .applied, createdAt: N7GoldenFixture.baseTime)
        var resolved = gone
        resolved.id = "resolved"
        resolved.status = .resolved
        resolved.quotedText = passage("signs in May.", "Ship the pilot.")
        resolved.occurrence = 4
        #expect(CorrectionAnchoring.reanchor(annotations: [gone, resolved], against: structured) == [
            .init(id: "gone", occurrence: 0, status: .stale),
            .init(id: "resolved", occurrence: 0, status: .resolved),
        ])
    }
}

// MARK: - AC-10: the synthesis, digest-editor and memory-digest lines

@Suite struct N7PromptLineTests {

    @Test("AC-10: promptQuote — one piece is today's bytes, a passage quotes each piece joined by ' / '")
    func promptQuote() {
        #expect(CorrectionSanitize.promptQuote("Ship \"it\"\nnow") == "\"Ship \u{201D}it\u{201D} now\"")
        #expect(
            CorrectionSanitize.promptQuote(passage("Quoll Harbor signs in May", "Ship \"the\" pilot", "Tow\r\nit"))
                == "\"Quoll Harbor signs in May\" / \"Ship \u{201D}the\u{201D} pilot\" / \"Tow it\"")
    }

    @Test("AC-10: synthesis, digest-editor and memory-digest lines for a multi-piece row")
    func otherPromptLines() throws {
        let quote = passage("Quoll Harbor signs in May", "Ship the Vexatron pilot to Quoll Harbor")
        let userText = "The pilot slipped to September; nothing ships before then."
        let onePiece = NotesCorrection(
            kind: .understanding, section: .summary, quotedText: "ship the sonar rig in May",
            userText: "It ships in June")
        let spanning = NotesCorrection(
            kind: .understanding, section: .decision, quotedText: quote, userText: userText)
        let synthesis = try #require(NotesPromptBuilder.correctionsBlock([onePiece, spanning]))
        #expect(synthesis.hasSuffix("""
            1. In the summary, an earlier draft said: "ship the sonar rig in May". The user corrects: It ships in June
            2. In the decisions, an earlier draft said: "Quoll Harbor signs in May" / "Ship the Vexatron pilot to Quoll Harbor". The user corrects: The pilot slipped to September; nothing ships before then.
            """))

        let instructions = [
            NotesEditorInstruction(
                rowID: "a", section: .summary, quotedText: onePiece.quotedText,
                userText: onePiece.userText),
            NotesEditorInstruction(
                rowID: "b", section: .decision, sections: [.summary, .decision], quotedText: quote,
                userText: userText),
        ]
        let digestEditor = DigestEditorWireContract.userMessage(
            for: DigestEditorRequest(
                meetingID: N7GoldenFixture.meetingID, currentDigest: "## HEADER", instructions: instructions))
        #expect(digestEditor == """
            CURRENT DIGEST:
            ## HEADER
            CORRECTIONS:
            1. The user corrected the meeting record. The notes said: "ship the sonar rig in May". The user corrects: It ships in June
            2. The user corrected the meeting record. The notes said: "Quoll Harbor signs in May" / "Ship the Vexatron pilot to Quoll Harbor". The user corrects: The pilot slipped to September; nothing ships before then.
            """)
        let memory = try #require(DigestPromptBuilder.correctionsBlock(instructions))
        #expect(memory.hasSuffix("""
            1. The notes said: "ship the sonar rig in May". The user corrects: It ships in June
            2. The notes said: "Quoll Harbor signs in May" / "Ship the Vexatron pilot to Quoll Harbor". The user corrects: The pilot slipped to September; nothing ships before then.
            """))
    }
}

// MARK: - AC-11 / AC-12: the withdrawn check and the wire

@Suite struct N7WithdrawnPiecesTests {

    private static let meetingID: MeetingID = N7GoldenFixture.meetingID
    private static let rowID = "01ARZ3NDEKTSV4RRFFQ69G5NP1"
    private static let pieceA = "Quoll Harbor signs in May."
    private static let pieceB = "Ship the Vexatron pilot."
    private static let codePiece = "step one\n\nstep two"
    private static let linkPiece = "Read the pilot brief today."

    private static func structured(summary: String, detailedNotes: String = "") -> NotesStructured {
        notes(summary: summary, detailedNotes: detailedNotes)
    }

    private static let bothPresent = structured(summary: "\(pieceA)\n\n\(pieceB)")
    private static let aRemoved = structured(summary: "The harbor date is open.\n\n\(pieceB)")
    private static let bothRemoved = structured(summary: "The harbor date is open.\n\nNothing ships yet.")
    private static let aRestored = structured(summary: "\(pieceA)\n\nNothing ships yet.")

    private static func row(
        _ quote: String = passage(pieceA, pieceB), kind: MeetingCorrection.Kind = .understanding
    ) -> MeetingCorrection {
        MeetingCorrection(
            id: rowID, meetingID: meetingID, kind: kind, section: .summary, quotedText: quote,
            userText: "The pilot slipped to September.", status: .pending,
            createdAt: N7GoldenFixture.baseTime)
    }

    private func records(
        _ structured: NotesStructured, rows: [MeetingCorrection] = [row()]
    ) throws -> [[String: Any]] {
        var meetingNotes = N7GoldenFixture.meetingNotes
        meetingNotes.structured = structured
        let payload = EvidencePayloadBuilder.build(
            meeting: N7GoldenFixture.meeting, segments: [], notes: meetingNotes,
            user: .shippedDefault, corrections: rows)
        #expect(!String(decoding: payload.bytes, as: UTF8.self).unicodeScalars.contains("\u{2029}"))
        let object = try #require(
            JSONSerialization.jsonObject(with: payload.bytes) as? [String: Any])
        return try #require(object["retractions"] as? [[String: Any]])
    }

    private func claimTexts(_ structured: NotesStructured) throws -> [String] {
        try records(structured).compactMap { $0["claim_text"] as? String }
    }

    /// The gate's verdict for `candidate` against the set withdrawn in `stored`.
    private func withholds(stored: NotesStructured, candidate: NotesStructured) -> Bool {
        let title = N7GoldenFixture.meetingTitle
        let withdrawn = CorrectionAnchoring.withdrawnClaims(
            corrections: [Self.row()],
            currentHaystack: CorrectionAnchoring.foldedHaystack(of: stored, meetingTitle: title),
            renderedHaystack: CorrectionAnchoring.renderedHaystack(of: stored, meetingTitle: title))
        return CorrectionAnchoring.resurrectedClaim(
            withdrawn: withdrawn,
            candidateHaystack: CorrectionAnchoring.foldedHaystack(of: candidate, meetingTitle: title),
            candidateRenderedHaystack: CorrectionAnchoring.renderedHaystack(
                of: candidate, meetingTitle: title)) != nil
    }

    @Test("AC-11: all words present — no record, the gate withholds nothing (the raw space would ship a phantom)")
    func allPresentNoRecord() throws {
        #expect(try records(Self.bothPresent).isEmpty)
        #expect(!withholds(stored: Self.bothPresent, candidate: Self.bothPresent))
        // Two detailed-notes paragraphs: today's whole-quote predicate over
        // the raw haystack would call the passage withdrawn (the U+001F block
        // boundary splits it) and ship a phantom record.
        let paragraphs = Self.structured(summary: "", detailedNotes: "\(Self.pieceA)\n\n\(Self.pieceB)")
        let raw = CorrectionAnchoring.foldedHaystack(
            of: paragraphs, meetingTitle: N7GoldenFixture.meetingTitle)
        #expect(!raw.contains(CorrectionAnchoring.fold(passage(Self.pieceA, Self.pieceB))))
        #expect(try records(paragraphs).isEmpty)
        #expect(!withholds(stored: paragraphs, candidate: paragraphs))

        // A piece that is a code block with a blank line inside.
        let code = Self.structured(
            summary: "", detailedNotes: "```\n\(Self.codePiece)\n```\n\nAfter the code.")
        let codeRow = Self.row(passage(Self.codePiece, "After the code."))
        #expect(try records(code, rows: [codeRow]).isEmpty)

        // A piece containing a link, unchanged.
        let link = Self.structured(summary: "Read the [pilot brief](https://example.com/brief) today.\n\n\(Self.pieceB)")
        #expect(try records(link, rows: [Self.row(passage(Self.linkPiece, Self.pieceB))]).isEmpty)
    }

    @Test("AC-11: remove A → A; regeneration restoring A withheld, keeping B installed; remove B → A\\nB; restore A → B")
    func theFeasibilityStory() throws {
        let aRecords = try records(Self.aRemoved)
        #expect(aRecords.count == 1)
        #expect(aRecords.first?["id"] as? String == Self.rowID)
        #expect(aRecords.first?["claim_text"] as? String == Self.pieceA)

        #expect(withholds(stored: Self.aRemoved, candidate: Self.bothPresent), "restoring A")
        #expect(!withholds(stored: Self.aRemoved, candidate: Self.aRemoved), "keeping B")
        #expect(
            !withholds(
                stored: Self.aRemoved,
                candidate: Self.structured(summary: "The harbor date is open.\n\n\(Self.pieceB) More.")))

        let both = try records(Self.bothRemoved)
        #expect(both.map { $0["id"] as? String } == [Self.rowID], "same id")
        #expect(both.first?["claim_text"] as? String == "\(Self.pieceA)\n\(Self.pieceB)")

        #expect(try claimTexts(Self.aRestored) == [Self.pieceB])
    }

    @Test("AC-11: an empty-fold piece never withdraws; annotations never withdraw")
    func emptyFoldAndAnnotations() throws {
        let emptyMiddle = Self.row(passage(Self.pieceA, " ** ", Self.pieceB))
        #expect(try records(Self.bothPresent, rows: [emptyMiddle]).isEmpty)
        #expect(
            try records(Self.aRemoved, rows: [emptyMiddle]).compactMap { $0["claim_text"] as? String }
                == [Self.pieceA])
        #expect(try records(Self.bothRemoved, rows: [Self.row(kind: .annotation)]).isEmpty)
    }

    @Test("AC-11/AC-12: pieces keep their own bytes and inner line breaks; the wire never carries U+2029")
    func piecesVerbatim() throws {
        let pieceWithBreak = "  Tow the rig\nat dawn "
        let quote = passage(pieceWithBreak, "Ship \"the\" pilot")
        let texts = try records(Self.bothRemoved, rows: [Self.row(quote)])
            .compactMap { $0["claim_text"] as? String }
        #expect(texts == ["\(pieceWithBreak)\nShip \"the\" pilot"])
    }

    @Test("AC-11: the rendered haystack is built only when a passage row exists")
    func renderedHaystackIsLazy() {
        let onePiece = MeetingCorrection(
            id: "one", meetingID: Self.meetingID, kind: .understanding, section: .summary,
            quotedText: "absent claim", userText: "x", createdAt: N7GoldenFixture.baseTime)
        var built = 0
        func rendered() -> String {
            built += 1
            return CorrectionAnchoring.renderedHaystack(
                of: Self.bothRemoved, meetingTitle: N7GoldenFixture.meetingTitle)
        }
        let raw = CorrectionAnchoring.foldedHaystack(
            of: Self.bothRemoved, meetingTitle: N7GoldenFixture.meetingTitle)
        _ = CorrectionAnchoring.withdrawnRows(
            corrections: [onePiece], currentHaystack: raw, renderedHaystack: rendered())
        #expect(built == 0)
        _ = CorrectionAnchoring.withdrawnRows(
            corrections: [onePiece, Self.row(), Self.row()], currentHaystack: raw,
            renderedHaystack: rendered())
        #expect(built == 1, "once per document, not per row")
    }
}

// MARK: - AC-11 at the seams: the regeneration gate and the minted payload

@Suite struct N7WithdrawnPipelineTests {

    private static let pieceA = "Quoll Harbor signs in May."
    /// The mock engine's fixed decision: a cross-section passage's last piece.
    private static let pieceB = "Fábio manda o contrato"

    private func latestRetractions(
        _ harness: PipelineHarness, _ id: MeetingID
    ) async throws -> [String] {
        let path = try #require(
            try await harness.database.pool.read { db in
                try String.fetchOne(
                    db,
                    sql: """
                        SELECT payload_path FROM handoff_queue
                        WHERE meeting_id = ? ORDER BY created_seq DESC LIMIT 1
                        """,
                    arguments: [id])
            })
        let data = try Data(contentsOf: harness.database.rootURL.appendingPathComponent(path))
        #expect(!String(decoding: data, as: UTF8.self).unicodeScalars.contains("\u{2029}"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let records = try #require(object["retractions"] as? [[String: Any]])
        return records.compactMap { $0["claim_text"] as? String }
    }

    private func storedSummary(_ harness: PipelineHarness, _ id: MeetingID) async throws -> String {
        try #require(try await NotesRepository(database: harness.database).fetch(meetingID: id))
            .structured.summary
    }

    private func rewrite(_ harness: PipelineHarness, _ id: MeetingID, summary: String) async throws {
        harness.notesPrimary.state.withLock { $0.summary = summary }
        _ = try await harness.pipeline.rewriteNotes(meetingID: id)
    }

    @Test("AC-11: a cross-section passage — no phantom, A withdrawn alone, restoring A withheld, keeping B installed")
    func gateAndPayloadThroughTheRewriteSite() async throws {
        let harness = try await makePipelineHarness()
        harness.notesPrimary.state.withLock { $0.summary = "\(Self.pieceA)\n\nThe barge is ready." }
        let meeting = try await harness.importTestMeeting()
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        let row = MeetingCorrection(
            meetingID: meeting.id, kind: .understanding, section: .decision,
            quotedText: "\(Self.pieceA)\u{2029}\(Self.pieceB)",
            userText: "The pilot slipped to September.", status: .applied,
            createdAt: msDate())
        try await harness.database.pool.write { db in try MeetingCorrectionStore.insert(db, row) }

        // Every word still in the notes: installed, and no record.
        try await rewrite(harness, meeting.id, summary: "\(Self.pieceA)\n\nThe barge is ready.")
        #expect(try await latestRetractions(harness, meeting.id) == [])

        // Piece A leaves the notes: one record carrying A alone.
        try await rewrite(harness, meeting.id, summary: "The harbor date is open.")
        #expect(try await storedSummary(harness, meeting.id) == "The harbor date is open.")
        #expect(try await latestRetractions(harness, meeting.id) == [Self.pieceA])

        // A regeneration restoring A is withheld; the notes are kept.
        try await rewrite(harness, meeting.id, summary: "Signed: \(Self.pieceA)")
        #expect(try await storedSummary(harness, meeting.id) == "The harbor date is open.")
        #expect(
            try await harness.meeting(meeting.id)?.processingNote
                == ProcessingPipeline.resurrectedClaimNote)

        // One keeping only B (the mock's decision) is installed.
        try await rewrite(harness, meeting.id, summary: "Nothing is signed yet.")
        #expect(try await storedSummary(harness, meeting.id) == "Nothing is signed yet.")
        #expect(try await latestRetractions(harness, meeting.id) == [Self.pieceA])
    }
}
