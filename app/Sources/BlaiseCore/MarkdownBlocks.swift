import Foundation

// C10: block-level markdown support for the native notes view.
//
// Plain SwiftUI `Text` COLLAPSES PresentationIntent blocks (paragraphs and
// list items run together) — pinned in the C10 spec. So the detail view
// splits parsed markdown into blocks here and stacks them as views; inline
// intents (emphasis, code) survive inside each block's AttributedString.
//
// Parsing is PINNED to `AttributedString(markdown:, interpretedSyntax:
// .full)`: .full preserves raw HTML as literal text (no interpretation, no
// stripping) — the N8 html-off guarantee, asserted in a test.

public struct MarkdownBlock: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case paragraph
        case header(level: Int)
        /// `ordinal` nil for unordered lists; `depth` ≥ 1.
        case listItem(ordinal: Int?, depth: Int)
        case codeBlock
        case blockQuote
        case thematicBreak
    }

    public let id: Int
    public let kind: Kind
    public let text: AttributedString

    public init(id: Int, kind: Kind, text: AttributedString) {
        self.id = id
        self.kind = kind
        self.text = text
    }
}

public enum MarkdownBlocks {
    /// Parses markdown into presentation blocks. Unparseable input falls
    /// back to a single literal paragraph (never drops content).
    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        guard
            let attributed = try? AttributedString(
                markdown: markdown,
                options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full))
        else {
            return [MarkdownBlock(id: 0, kind: .paragraph, text: AttributedString(markdown))]
        }

        var blocks: [MarkdownBlock] = []
        var currentIntent: PresentationIntent??
        var currentText = AttributedString()

        func flush() {
            guard let intent = currentIntent else { return }
            let trimmedEmpty = String(currentText.characters)
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let kind = classify(intent ?? nil)
            if !trimmedEmpty || kind == .thematicBreak {
                var text = currentText
                text.presentationIntent = nil
                blocks.append(MarkdownBlock(id: blocks.count, kind: kind, text: text))
            }
            currentText = AttributedString()
        }

        for run in attributed.runs {
            let intent = run.presentationIntent
            if currentIntent == nil || currentIntent! != intent {
                flush()
                currentIntent = .some(intent)
            }
            currentText += AttributedString(attributed[run.range])
        }
        flush()
        return blocks
    }

    static func classify(_ intent: PresentationIntent?) -> MarkdownBlock.Kind {
        guard let intent else { return .paragraph }
        var listDepth = 0
        var ordinal: Int?
        var isListItem = false
        for component in intent.components {
            switch component.kind {
            case .header(let level):
                return .header(level: level)
            case .codeBlock:
                return .codeBlock
            case .blockQuote:
                return .blockQuote
            case .thematicBreak:
                return .thematicBreak
            case .listItem(let itemOrdinal):
                isListItem = true
                if ordinal == nil { ordinal = itemOrdinal }
            case .orderedList, .unorderedList:
                listDepth += 1
            default:
                break
            }
        }
        if isListItem {
            // Ordinals only make sense when the INNERMOST list is ordered.
            let innermostOrdered = intent.components.first { component in
                if case .orderedList = component.kind { return true }
                if case .unorderedList = component.kind { return true }
                return false
            }.map { component -> Bool in
                if case .orderedList = component.kind { return true }
                return false
            } ?? false
            return .listItem(ordinal: innermostOrdered ? ordinal : nil, depth: max(listDepth, 1))
        }
        return .paragraph
    }
}

// MARK: - Search-snippet delimiter mapping

/// Maps FTS5 snippets carrying the pinned `\u{FFF9}`/`\u{FFFA}` match
/// delimiters (`SearchHit`) into renderable segments — the view shows
/// `isMatch` runs in bold accent.
public enum SearchSnippetFormatter {
    public struct Segment: Equatable, Sendable {
        public let text: String
        public let isMatch: Bool

        public init(text: String, isMatch: Bool) {
            self.text = text
            self.isMatch = isMatch
        }
    }

    public static func segments(_ snippet: String) -> [Segment] {
        var segments: [Segment] = []
        var current = ""
        var inMatch = false
        for character in snippet {
            switch String(character) {
            case SearchHit.matchStartDelimiter:
                if !current.isEmpty { segments.append(Segment(text: current, isMatch: inMatch)) }
                current = ""
                inMatch = true
            case SearchHit.matchEndDelimiter:
                if !current.isEmpty { segments.append(Segment(text: current, isMatch: inMatch)) }
                current = ""
                inMatch = false
            default:
                current.append(character)
            }
        }
        if !current.isEmpty { segments.append(Segment(text: current, isMatch: inMatch)) }
        return segments
    }
}
