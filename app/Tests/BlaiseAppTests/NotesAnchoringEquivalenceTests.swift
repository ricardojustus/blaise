import BlaiseCore
import Foundation
import Testing

@testable import BlaiseApp

// Anchoring answers must not change when the folds are computed once per list
// instead of once per question. The reference is an oracle stated here from the
// shipped formulas — it shares no code with the value under test, so an equal
// answer is evidence rather than a restatement of the delegation.

/// The anchoring rules as the pane applied them before the folds were shared:
/// a fold per block per question, the resolve clamp, and the whole-block
/// occurrence rule. `fold` itself is unchanged and stays the one folding
/// implementation, so the oracle calls it rather than copying it.
enum LegacyAnchoring {
    static func matches(quote: String, in blocks: [String]) -> [Int] {
        let needle = CorrectionAnchoring.fold(quote)
        guard !needle.isEmpty else { return [] }
        return blocks.indices.filter { CorrectionAnchoring.fold(blocks[$0]).contains(needle) }
    }

    static func resolve(
        quote: String, occurrence: Int, in blocks: [String]
    ) -> (blockIndex: Int, occurrence: Int)? {
        let hits = matches(quote: quote, in: blocks)
        guard !hits.isEmpty else { return nil }
        let clamped = min(max(occurrence, 0), hits.count - 1)
        return (hits[clamped], clamped)
    }

    static func occurrence(ofBlockAt index: Int, in blocks: [String]) -> Int {
        guard blocks.indices.contains(index) else { return 0 }
        return matches(quote: blocks[index], in: blocks).firstIndex(of: index) ?? 0
    }
}

/// Asserts the oracle, the list-taking form and the folded form all say the
/// same thing about one question — and that the answer is the expected one.
private func expectMatches(
    _ quote: String, in blocks: [String], equal expected: [Int],
    _ note: String, sourceLocation: SourceLocation = #_sourceLocation
) {
    let folded = CorrectionAnchoring.FoldedBlocks(blocks)
    for (label, answer) in [
        ("oracle", LegacyAnchoring.matches(quote: quote, in: blocks)),
        ("list", CorrectionAnchoring.matches(quote: quote, in: blocks)),
        ("folded", CorrectionAnchoring.matches(quote: quote, in: folded)),
    ] {
        #expect(answer == expected, "\(note) — \(label) said \(answer)",
            sourceLocation: sourceLocation)
    }
}

private func expectResolve(
    _ quote: String, occurrence: Int, in blocks: [String],
    equal expected: (blockIndex: Int, occurrence: Int)?,
    _ note: String, sourceLocation: SourceLocation = #_sourceLocation
) {
    let folded = CorrectionAnchoring.FoldedBlocks(blocks)
    for (label, answer) in [
        ("oracle", LegacyAnchoring.resolve(quote: quote, occurrence: occurrence, in: blocks)),
        ("list", CorrectionAnchoring.resolve(quote: quote, occurrence: occurrence, in: blocks)),
        ("folded", CorrectionAnchoring.resolve(quote: quote, occurrence: occurrence, in: folded)),
    ] {
        #expect(
            answer?.blockIndex == expected?.blockIndex
                && answer?.occurrence == expected?.occurrence,
            "\(note) — \(label) said \(String(describing: answer))",
            sourceLocation: sourceLocation)
    }
}

private func expectOccurrence(
    ofBlockAt index: Int, in blocks: [String], equal expected: Int,
    _ note: String, sourceLocation: SourceLocation = #_sourceLocation
) {
    let folded = CorrectionAnchoring.FoldedBlocks(blocks)
    for (label, answer) in [
        ("oracle", LegacyAnchoring.occurrence(ofBlockAt: index, in: blocks)),
        ("list", CorrectionAnchoring.occurrence(ofBlockAt: index, in: blocks)),
        ("folded", CorrectionAnchoring.occurrence(ofBlockAt: index, in: folded)),
    ] {
        #expect(answer == expected, "\(note) — \(label) said \(answer)",
            sourceLocation: sourceLocation)
    }
}

// MARK: - The fixture matrix

/// A section list with a duplicated block (0 and 2), a styled block whose
/// markdown a plain quote must still match (3), and a blank one (4).
private let harborBlocks = [
    "The tide sensor calibration is finished on the north jetty.",
    "Vexatron Labs asked for the ferry timetable a week early.",
    "The tide sensor calibration is finished on the north jetty.",
    "**The harbour lights** stay amber until the survey lands.",
    "   ",
]

/// Every section populated, in the shapes the pane renders: a multi-paragraph
/// summary, detailed notes with a list and a repeated paragraph, decisions that
/// repeat a decision verbatim, and both action lists carrying a blank item.
private let populated = NotesStructured(
    summary: """
        The ferry timetable ships Thursday.

        The kelp survey slipped a week and the harbour board wants a date.
        """,
    detailedNotes: """
        ## Quoll Harbor

        - Tide sensor calibration is finished on the north jetty.
        - The harbour lights stay amber until the survey lands.

        Owner to be confirmed.

        ## Vexatron Labs

        Owner to be confirmed.
        """,
    decisions: [
        "The ferry timetable ships Thursday.",
        "The kelp survey moves to Thursday.",
        "The ferry timetable ships Thursday.",
    ],
    actionItems: [
        ActionItem(owner: "Wren Calloway", text: "Send the tide survey to the harbour board."),
        ActionItem(owner: "Wren Calloway", text: "   "),
        ActionItem(owner: "Ashby Fen", text: "Book the ferry drill."),
    ],
    userActionItems: [
        ActionItem(owner: "", text: "Send the tide survey to the harbour board."),
        ActionItem(owner: "", text: ""),
    ])

private let emptyNotes = NotesStructured(
    summary: "", detailedNotes: "", decisions: [], actionItems: [], userActionItems: [])

private let allSections: [MeetingCorrection.Section] = [
    .summary, .detailedNotes, .decision, .actionItem, .userActionItem,
]

@Suite struct AnchoringFoldReuseEquivalenceTests {

    @Test("no blocks at all: nothing matches, nothing resolves")
    func zeroBlocks() {
        expectMatches("the ferry timetable", in: [], equal: [], "an empty list holds no match")
        expectResolve(
            "the ferry timetable", occurrence: 0, in: [], equal: nil,
            "an empty list resolves nothing")
        expectOccurrence(ofBlockAt: 0, in: [], equal: 0, "and carries no occurrence")
    }

    @Test("no rows at all: every site groups nothing")
    func zeroRows() {
        let folded = CorrectionAnchoring.FoldedBlocks(harborBlocks)
        for section in allSections {
            for kind in [MeetingCorrection.Kind.annotation, .understanding] {
                #expect(
                    rowsByAnchoredBlock([], kind: kind, section: section, blocks: folded).isEmpty,
                    "\(section)/\(kind) groups nothing from no rows")
            }
        }
        #expect(
            rowsByRenderedBlock([], uiTexts: folded).isEmpty,
            "and neither does a coarse site")
    }

    @Test("a quote carried by one block")
    func singleMatch() {
        expectMatches(
            "ferry timetable a week early", in: harborBlocks, equal: [1], "one block carries it")
        expectResolve(
            "ferry timetable a week early", occurrence: 0, in: harborBlocks, equal: (1, 0),
            "and it resolves there")
    }

    @Test("a quote no block carries is stale")
    func noMatch() {
        expectMatches("the kelp survey", in: harborBlocks, equal: [], "nothing carries it")
        expectResolve(
            "the kelp survey", occurrence: 0, in: harborBlocks, equal: nil, "so it is stale")
    }

    @Test("duplicate blocks anchor distinctly, and the occurrence picks which")
    func duplicateBlocks() {
        let quote = "tide sensor calibration is finished"
        expectMatches(quote, in: harborBlocks, equal: [0, 2], "two blocks carry it")
        expectResolve(quote, occurrence: 0, in: harborBlocks, equal: (0, 0), "the first")
        expectResolve(quote, occurrence: 1, in: harborBlocks, equal: (2, 1), "the second")
        // What each block stores when the whole block is the quote.
        expectOccurrence(ofBlockAt: 0, in: harborBlocks, equal: 0, "the first of its pair")
        expectOccurrence(ofBlockAt: 2, in: harborBlocks, equal: 1, "the second of its pair")
        expectOccurrence(ofBlockAt: 1, in: harborBlocks, equal: 0, "a block matched only by itself")
    }

    @Test("the occurrence clamps to the last match, from either side")
    func clampBoundaries() {
        let quote = "tide sensor calibration is finished"
        expectResolve(quote, occurrence: -1, in: harborBlocks, equal: (0, 0), "negative clamps to 0")
        expectResolve(
            quote, occurrence: -97, in: harborBlocks, equal: (0, 0), "however negative")
        expectResolve(
            quote, occurrence: 2, in: harborBlocks, equal: (2, 1), "one past the end clamps back")
        expectResolve(
            quote, occurrence: 97, in: harborBlocks, equal: (2, 1), "however far past")
        // A single-match list clamps every occurrence onto its one hit.
        expectResolve(
            "ferry timetable a week early", occurrence: 4, in: harborBlocks, equal: (1, 0),
            "one hit takes every occurrence")
    }

    @Test("a quote that folds to nothing matches nothing")
    func emptyQuotes() {
        for quote in ["", "   ", "\n\t ", "**", "[]()", "#"] {
            expectMatches(quote, in: harborBlocks, equal: [], "\(quote.debugDescription) folds away")
            expectResolve(
                quote, occurrence: 0, in: harborBlocks, equal: nil,
                "\(quote.debugDescription) resolves nowhere")
        }
        // The same on the other side: a blank BLOCK is matched by nothing and
        // carries occurrence 0 rather than counting itself.
        expectOccurrence(ofBlockAt: 4, in: harborBlocks, equal: 0, "a blank block counts nothing")
        expectOccurrence(
            ofBlockAt: 0, in: ["", "  ", ""], equal: 0, "nor does a list of blanks")
    }

    @Test("an out-of-range block index carries occurrence 0")
    func outOfRangeIndex() {
        expectOccurrence(ofBlockAt: 5, in: harborBlocks, equal: 0, "past the end")
        expectOccurrence(ofBlockAt: -1, in: harborBlocks, equal: 0, "before the start")
        expectOccurrence(ofBlockAt: 3, in: harborBlocks, equal: 0, "the last real block")
    }

    @Test("a plain quote matches styled source, both forms")
    func styledSource() {
        expectMatches(
            "The harbour lights stay amber", in: harborBlocks, equal: [3],
            "the fold strips the emphasis on both sides")
        expectResolve(
            "The harbour lights stay amber", occurrence: 0, in: harborBlocks, equal: (3, 0),
            "and it resolves onto the styled block")
    }

    @Test("every section, populated: the three answers agree with the oracle")
    func everyPopulatedSection() {
        // The block counts the sections actually present, so a fixture that
        // stopped exercising a shape would fail here rather than pass silently.
        let expectedCounts: [MeetingCorrection.Section: Int] = [
            .summary: 1, .detailedNotes: 5, .decision: 3, .actionItem: 3, .userActionItem: 2,
        ]
        for section in allSections {
            let blocks = CorrectionAnchoring.blocks(of: populated, section: section)
            #expect(blocks.count == expectedCounts[section], "\(section) block count")
            for index in blocks.indices {
                expectOccurrence(
                    ofBlockAt: index, in: blocks, equal:
                        LegacyAnchoring.occurrence(ofBlockAt: index, in: blocks),
                    "\(section) block \(index) occurrence")
                for occurrence in [-1, 0, 1, 7] {
                    expectResolve(
                        blocks[index], occurrence: occurrence, in: blocks,
                        equal: LegacyAnchoring.resolve(
                            quote: blocks[index], occurrence: occurrence, in: blocks),
                        "\(section) block \(index) at occurrence \(occurrence)")
                }
            }
        }
        // The repeated decision is the case the occurrence exists for.
        let decisions = CorrectionAnchoring.blocks(of: populated, section: .decision)
        expectOccurrence(ofBlockAt: 2, in: decisions, equal: 1, "the repeated decision is the second")
    }

    @Test("every section, empty: no blocks, no answers")
    func everyEmptySection() {
        for section in allSections {
            let blocks = CorrectionAnchoring.blocks(of: emptyNotes, section: section)
            let expected = section == .summary ? 1 : 0
            #expect(blocks.count == expected, "\(section) on empty notes")
            expectMatches(
                "the ferry timetable", in: blocks, equal: [], "\(section) carries no quote")
            expectResolve(
                "the ferry timetable", occurrence: 0, in: blocks, equal: nil,
                "\(section) resolves nothing")
            expectOccurrence(ofBlockAt: 0, in: blocks, equal: 0, "\(section) carries no occurrence")
        }
    }

    @Test("anchoring is status-blind: every status resolves the same")
    func everyStatusAnchorsAlike() {
        let quote = "tide sensor calibration is finished"
        for status in [
            MeetingCorrection.Status.pending, .applied, .stale, .resolved,
        ] {
            let row = MeetingCorrection(
                id: "row-\(status.rawValue)", meetingID: "meeting-1", kind: .annotation,
                section: .detailedNotes, quotedText: quote, occurrence: 1,
                userText: "Check the jetty reading.", status: status,
                createdAt: Date(timeIntervalSince1970: 0))
            expectResolve(
                row.quotedText, occurrence: row.occurrence, in: harborBlocks, equal: (2, 1),
                "a \(status.rawValue) row anchors like any other")
        }
    }
}

// MARK: - The fold invariant, pinned at the source

/// Where folding happens is a structural property of the code, not a value a
/// test can read: the reuse is only real while the folded overloads fold the
/// QUOTE and nothing else, and while the folds are computed in exactly one
/// place. The oracle is the source itself — the suite's house style for
/// properties of this shape, and it needs no counter in shipping code.
@Suite struct AnchoringFoldInvariantTests {
    private func correctionsSource() throws -> String {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { root.deleteLastPathComponent() }
        return try String(
            contentsOf: root.appendingPathComponent("app/Sources/BlaiseCore/MeetingCorrections.swift"),
            encoding: .utf8)
    }

    /// One declaration's body: from its signature to the first line that closes
    /// a member of the enum.
    private func body(_ signature: String, in source: String) throws -> Substring {
        let start = try #require(source.range(of: signature), "missing: \(signature)")
        let end = try #require(
            source.range(of: "\n    }", range: start.upperBound ..< source.endIndex))
        return source[start.upperBound ..< end.lowerBound]
    }

    private func folds(in body: Substring) -> [String] {
        body.components(separatedBy: "fold(").dropFirst().map {
            String($0.prefix(while: { $0 != ")" }))
        }
    }

    @Test("the folded overloads fold the quote and nothing else")
    func overloadsFoldOnlyTheQuote() throws {
        let source = try correctionsSource()
        let matchesBody = try body(
            "public static func matches(quote: String, in blocks: FoldedBlocks) -> [Int] {",
            in: source)
        #expect(
            folds(in: matchesBody) == ["quote"],
            "matches folds the quote once and no block")
        #expect(!matchesBody.contains("fold(blocks"))

        let resolveBody = try body(
            "quote: String, occurrence: Int, in blocks: FoldedBlocks\n    ) -> (blockIndex: Int, occurrence: Int)? {",
            in: source)
        // The body each absence is read from is the real one: without this the
        // two assertions below would pass on an empty extraction.
        #expect(resolveBody.contains("min(max(occurrence, 0), hits.count - 1)"))
        #expect(folds(in: resolveBody).isEmpty, "resolve folds nothing of its own")

        let occurrenceBody = try body(
            "public static func occurrence(ofBlockAt index: Int, in blocks: FoldedBlocks) -> Int {",
            in: source)
        #expect(occurrenceBody.contains("firstIndex(of: index) ?? 0"))
        #expect(
            folds(in: occurrenceBody).isEmpty,
            "the stored fold IS the needle — the occurrence overload folds nothing")
    }

    @Test("the blocks are folded in FoldedBlocks.init and nowhere else")
    func initIsTheOnlyBlockFold() throws {
        let source = try correctionsSource()
        #expect(
            source.components(separatedBy: "blocks.map(CorrectionAnchoring.fold)").count - 1 == 1,
            "exactly one site folds a block list")
        let structStart = try #require(source.range(of: "public struct FoldedBlocks: Sendable {"))
        let structEnd = try #require(
            source.range(of: "\n    }", range: structStart.upperBound ..< source.endIndex))
        #expect(
            source[structStart.upperBound ..< structEnd.lowerBound]
                .contains("self.folds = blocks.map(CorrectionAnchoring.fold)"),
            "and that site is the initializer")
        // The fold itself stays single-sourced.
        #expect(source.components(separatedBy: "public static func fold(").count - 1 == 1)
    }
}
