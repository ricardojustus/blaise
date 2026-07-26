import BlaiseCore
import Foundation
import SwiftUI
import Testing

@testable import BlaiseApp

/// Notes presentation defects reported from the shipped app (26/07/2026):
/// tables scrolled sideways instead of wrapping, and an active search term
/// wiped every inline attribute out of the rendered notes.
@MainActor
@Suite struct NotesPresentationTests {
    private let proseTable = """
        | Feature | Detail |
        | --- | --- |
        | Warp core | A long label-plus-prose sentence that runs well past the width of the \
        notes column and therefore has to wrap onto several lines instead of being clipped. |
        | Quoll sonar | Another paragraph-length detail cell, also far too wide to sit on one \
        single line inside the reading measure. |
        """

    /// Defect 1: the table must lay out inside the notes column — no
    /// horizontally-scrolling wrapper anywhere in the block renderer.
    @Test func tableRendersWithoutAHorizontalScrollWrapper() {
        let layout = String(describing: type(of: MarkdownBlocksView(markdown: proseTable).body))
        #expect(!layout.contains("ScrollView"))
        #expect(layout.contains("Grid"))
    }

    /// …and no cell content is dropped on the way to the view.
    @Test func tableCellContentSurvivesInFull() {
        let blocks = MarkdownBlocks.parse(proseTable)
        guard case .table(let header, let rows, _) = blocks.first?.kind else {
            Issue.record("expected a .table block, got \(String(describing: blocks.first?.kind))")
            return
        }
        #expect(header.map { String($0.characters) } == ["Feature", "Detail"])
        #expect(rows.count == 2)
        #expect(String(rows[0][1].characters).hasPrefix("A long label-plus-prose sentence"))
        #expect(String(rows[0][1].characters).hasSuffix("instead of being clipped."))
        #expect(String(rows[1][0].characters) == "Quoll sonar")
    }

    /// Defect 3: an active search term highlights the match WITHOUT discarding
    /// the parser's bold, italics and links.
    @Test func searchHighlightPreservesBoldAndLinks() {
        let blocks = MarkdownBlocks.parse(
            "O **warp core** foi entregue, detalhes em https://quollharbor.example/sonar hoje.")
        let source = blocks[0].text
        let output = SearchHighlight.applied(to: source, terms: ["entregue"])

        // The source formatting survives.
        let bold = output.runs.filter {
            $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        }
        #expect(bold.contains { String(output[$0.range].characters) == "warp core" })
        let links = output.runs.compactMap { run -> String? in
            guard let url = run.link else { return nil }
            return "\(String(output[run.range].characters))|\(url.absoluteString)"
        }
        #expect(links == ["https://quollharbor.example/sonar|https://quollharbor.example/sonar"])

        // And the match is still highlighted (accent + underline + emphasis).
        let matched = output.runs.filter { String(output[$0.range].characters) == "entregue" }
        #expect(matched.count == 1)
        #expect(matched.first?.underlineStyle == .single)
        #expect(matched.first?.foregroundColor != nil)
        #expect(matched.first?.inlinePresentationIntent?.contains(.stronglyEmphasized) == true)
    }

    /// A match INSIDE a bold run keeps the surrounding text's formatting and
    /// the whole source text intact.
    @Test func searchHighlightKeepsTextAndNestedEmphasisIntact() {
        let source = MarkdownBlocks.parse("O **warp core entregue** hoje.")[0].text
        let output = SearchHighlight.applied(to: source, terms: ["core"])
        #expect(String(output.characters) == String(source.characters))
        let stillBold = output.runs.filter {
            $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        }
        .map { String(output[$0.range].characters) }
        .joined()
        #expect(stillBold == "warp core entregue")
    }

    /// The dangerous shape: a match that STARTS inside an existing bold run and
    /// runs across plain text into a link. Every run the match covers must carry
    /// all three cues, the link must survive, and not one character may be lost,
    /// duplicated or reordered.
    @Test func searchHighlightSpansFromInsideBoldIntoALink() {
        let source = MarkdownBlocks.parse(
            "**Quoll** sonar https://quollharbor.example/sonar hoje.")[0].text
        let plain = String(source.characters)
        let term = "oll sonar https://quollharbor.example/sonar"
        guard let matchRange = plain.range(of: term) else {
            Issue.record("fixture no longer contains the match")
            return
        }
        let matchStart = plain.distance(from: plain.startIndex, to: matchRange.lowerBound)
        let matchEnd = plain.distance(from: plain.startIndex, to: matchRange.upperBound)

        let output = SearchHighlight.applied(to: source, terms: [term])

        // No character loss, duplication or reordering.
        #expect(String(output.characters) == plain)

        // Every run inside the match carries the full cue set; every run outside
        // carries none of it.
        var cursor = 0
        var linkRuns: [String] = []
        for run in output.runs {
            let length = output.characters.distance(
                from: run.range.lowerBound, to: run.range.upperBound)
            let text = String(output[run.range].characters)
            let inside = cursor >= matchStart && cursor + length <= matchEnd
            if inside {
                #expect(run.underlineStyle == .single, "no underline on matched run '\(text)'")
                #expect(run.foregroundColor != nil, "no accent on matched run '\(text)'")
                #expect(run.backgroundColor != nil, "no accent field on matched run '\(text)'")
                #expect(
                    run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true,
                    "no emphasis on matched run '\(text)'")
            } else if cursor >= matchEnd || cursor + length <= matchStart {
                #expect(run.underlineStyle == nil, "cue leaked onto unmatched run '\(text)'")
                #expect(run.backgroundColor == nil, "cue leaked onto unmatched run '\(text)'")
            }
            if let url = run.link { linkRuns.append("\(text)|\(url.absoluteString)") }
            cursor += length
        }
        #expect(cursor == plain.count)
        #expect(
            linkRuns == [
                "https://quollharbor.example/sonar|https://quollharbor.example/sonar"
            ])
        // The bold that predates the search is still bold across its whole word.
        let bold = output.runs.filter {
            $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        }
        .map { String(output[$0.range].characters) }
        .joined()
        #expect(bold.hasPrefix("Quoll"))
    }

    /// Several terms, adjacent and back-to-back matches, in one pass.
    @Test func searchHighlightHandlesAdjacentAndMultipleTerms() {
        let source = MarkdownBlocks.parse("O **warp** core warp core hoje.")[0].text
        let output = SearchHighlight.applied(to: source, terms: ["warp", "core"])
        #expect(String(output.characters) == String(source.characters))
        let underlined = output.runs.filter { $0.underlineStyle == .single }
            .map { String(output[$0.range].characters) }
            .joined()
        #expect(underlined == "warpcorewarpcore")
    }

    /// A diacritic- and case-folded match whose source spelling differs from the
    /// term must still land on the right characters.
    @Test func searchHighlightMatchesFoldedTextWithoutDrift() {
        let source = MarkdownBlocks.parse("A **revisão** já está pronta.")[0].text
        let output = SearchHighlight.applied(to: source, terms: ["REVISAO"])
        #expect(String(output.characters) == String(source.characters))
        let underlined = output.runs.filter { $0.underlineStyle == .single }
            .map { String(output[$0.range].characters) }
            .joined()
        #expect(underlined == "revisão")
    }

    @Test func noSearchTermsLeavesTheSourceUntouched() {
        let source = MarkdownBlocks.parse("O **warp core** foi entregue.")[0].text
        #expect(SearchHighlight.applied(to: source, terms: []) == source)
    }
}


/// Table column widths are content-driven, measured through a real SwiftUI
/// layout pass (`ImageRenderer` lays the view out for rendering). Heights are
/// the observable: the narrower a column, the more its prose wraps.
@MainActor
@Suite struct TableColumnWidthTests {
    private let prose =
        "A long label-plus-prose sentence that runs well past the width of the notes "
        + "column and therefore has to wrap onto several lines instead of being clipped."

    private func height(_ markdown: String, width: Double) -> Double {
        let renderer = ImageRenderer(
            content: MarkdownBlocksView(markdown: markdown).frame(width: width))
        return Double(renderer.nsImage?.size.height ?? -1)
    }

    /// A short label column must NOT claim an equal share: the prose column has
    /// to wrap as it would with well over half the table's width. The reference
    /// is the same prose in a one-column table (identical cell styling and row
    /// overhead) at the width an equal split would have left it.
    @Test func aShortLabelColumnLeavesTheProseColumnMostOfTheWidth() {
        let labelPlusProse = "| Feature | Detail |\n| --- | --- |\n| Warp | \(prose) |"
        let proseAlone = "| Detail |\n| --- |\n| \(prose) |"
        for width in [700.0, 480.0, 320.0] {
            let table = height(labelPlusProse, width: width)
            #expect(
                table < height(proseAlone, width: width / 2),
                "the prose column got no more than an equal share at width \(width)")
            #expect(
                table <= height(proseAlone, width: width * 0.75),
                "the prose column got less than three quarters of the width at \(width)")
        }
    }

    /// Five columns must not collapse into equal slivers either: the prose cell
    /// still wraps better than a one-fifth share would allow.
    @Test func manyColumnsDoNotBecomeEqualSlivers() {
        let five =
            "| A | B | C | D | E |\n| --- | --- | --- | --- | --- |\n"
            + "| Warp | \(prose) | short | mid-length detail | x |"
        let proseAlone = "| B |\n| --- |\n| \(prose) |"
        let width = 700.0
        #expect(height(five, width: width) < height(proseAlone, width: width / 5))
    }

    /// Per-column alignment still positions the cell inside its column: the same
    /// table rendered left- and right-aligned must not produce the same pixels.
    @Test func perColumnAlignmentStillApplies() {
        func png(_ separator: String) -> Data? {
            let markdown = "| Feature | Detail |\n\(separator)\n| Warp | x |\n| Quoll | wider cell |"
            let renderer = ImageRenderer(
                content: MarkdownBlocksView(markdown: markdown).frame(width: 400))
            return renderer.nsImage?.tiffRepresentation
        }
        let left = png("| --- | --- |")
        let right = png("| --- | ---: |")
        #expect(left != nil && right != nil)
        #expect(left != right, "column alignment made no visible difference")
    }
}
