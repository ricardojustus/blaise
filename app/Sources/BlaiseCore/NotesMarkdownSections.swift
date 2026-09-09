import Foundation

/// The stored notes markdown, read as the renderer's own sections — the one
/// input every pipeline writer agrees on. Pure: line arithmetic over the bytes,
/// no re-render, no correction rows.
///
/// The self action-items section is found by POSITION (the heading after the
/// action-items heading), never by the user's name: the stored heading carries
/// whatever name the renderer had at mint time, which is not recoverable later.
/// A margin note is recognised by the renderer's own bold label.
public enum NotesMarkdownSections {
    public enum Kind: String, Sendable, Equatable {
        case summary
        case detailedNotes
        case decisions
        case actionItems
        case selfActionItems
        case yourNotes
        case other
    }

    /// One `## ` heading and everything up to the next one. Line indices are
    /// offsets into the `\n` split of the markdown handed to `classify`.
    public struct Section: Sendable, Equatable {
        public let kind: Kind
        public let headingLine: Int
        public let lines: Range<Int>
    }

    public static func classify(_ markdown: String, language: String) -> [Section] {
        let lines = split(markdown)
        let headings = headingLines(lines)
        guard !headings.isEmpty else { return [] }

        var kinds = headings.map { kind(ofHeadingAt: $0, in: lines, language: language) }
        // The self section is the heading that FOLLOWS the action items — the
        // only section whose title carries a name, so position, not text,
        // identifies it (a name that equals another section's title would
        // otherwise be mislabelled).
        if let actionIndex = kinds.firstIndex(of: .actionItems),
            actionIndex + 1 < kinds.count,
            kinds[actionIndex + 1] != .yourNotes {
            kinds[actionIndex + 1] = .selfActionItems
        }

        return headings.enumerated().map { position, headingLine in
            let end = position + 1 < headings.count ? headings[position + 1] : lines.count
            return Section(kind: kinds[position], headingLine: headingLine, lines: headingLine..<end)
        }
    }

    public static func hasMarginNotes(_ markdown: String, language: String) -> Bool {
        let lines = split(markdown)
        let label = NotesRenderer.yourNoteLabel(language: language)
        if asideLines(lines, label: label).isEmpty {
            return classify(markdown, language: language).contains { $0.kind == .yourNotes }
        }
        return true
    }

    public static func apply(
        _ markdown: String, includeSelf: Bool, includeMarginNotes: Bool, language: String
    ) -> String {
        let lines = split(markdown)
        var doomed = Set<Int>()

        if !includeSelf || !includeMarginNotes {
            for section in classify(markdown, language: language) {
                let removed =
                    (section.kind == .selfActionItems && !includeSelf)
                    || (section.kind == .yourNotes && !includeMarginNotes)
                if removed { doomed.formUnion(section.lines) }
            }
        }
        if !includeMarginNotes {
            let label = NotesRenderer.yourNoteLabel(language: language)
            for index in asideLines(lines, label: label) {
                doomed.insert(index)
                // The renderer separates blocks with a blank line; taking the
                // aside's own separator keeps the neighbours' spacing intact.
                if index + 1 < lines.count, lines[index + 1].isEmpty {
                    doomed.insert(index + 1)
                }
            }
        }
        guard !doomed.isEmpty else { return markdown }

        var result = lines.enumerated()
            .filter { !doomed.contains($0.offset) }
            .map(\.element)
            .joined(separator: "\n")
        while result.hasSuffix("\n") { result.removeLast() }
        return result + "\n"
    }

    // MARK: - Line reading

    private static func split(_ markdown: String) -> [String] {
        markdown.components(separatedBy: "\n")
    }

    /// Column-0 `## ` lines outside fenced code.
    private static func headingLines(_ lines: [String]) -> [Int] {
        var result: [Int] = []
        var fence: Fence?
        for (index, line) in lines.enumerated() {
            if step(&fence, line) { continue }
            if line.hasPrefix("## ") { result.append(index) }
        }
        return result
    }

    /// Column-0 blockquote lines outside fenced code that open with the
    /// renderer's bold note label — both aside shapes start `> **<label>`.
    private static func asideLines(_ lines: [String], label: String) -> [Int] {
        var result: [Int] = []
        var fence: Fence?
        for (index, line) in lines.enumerated() {
            if step(&fence, line) { continue }
            if line.hasPrefix("> **" + label) { result.append(index) }
        }
        return result
    }

    private static func kind(ofHeadingAt index: Int, in lines: [String], language: String) -> Kind {
        let text = lines[index].dropFirst(3).trimmingCharacters(in: .whitespaces)
        switch text {
        case NotesRenderer.summaryHeading(language: language): return .summary
        case NotesRenderer.detailedNotesHeading(language: language): return .detailedNotes
        case NotesRenderer.decisionsHeading(language: language): return .decisions
        case NotesRenderer.actionItemsHeading(language: language): return .actionItems
        case NotesRenderer.yourNotesHeading(language: language): return .yourNotes
        default: return .other
        }
    }

    // MARK: - Fences

    private struct Fence {
        let character: Character
        let length: Int
    }

    /// Advances the fence state for one line; true when the line belongs to a
    /// fenced code block (fence markers included) and must be ignored.
    private static func step(_ fence: inout Fence?, _ line: String) -> Bool {
        let indent = line.prefix(while: { $0 == " " })
        guard indent.count <= 3 else { return fence != nil }
        let body = line.dropFirst(indent.count)

        if let open = fence {
            let run = body.prefix(while: { $0 == open.character })
            if run.count >= open.length, body.dropFirst(run.count).allSatisfy({ $0 == " " || $0 == "\t" }) {
                fence = nil
            }
            return true
        }
        for character: Character in ["`", "~"] {
            let run = body.prefix(while: { $0 == character })
            if run.count >= 3 {
                // CommonMark: a backtick fence's info string may not contain a
                // backtick, and the renderer's fences are the ones that count.
                if character == "`", body.dropFirst(run.count).contains("`") { return false }
                fence = Fence(character: character, length: run.count)
                return true
            }
        }
        return false
    }
}
