import AppKit
import BlaiseCore
import SwiftUI

// The whole note as ONE attributed string for one TextKit 2 text view. This file builds the string and the map from its character ranges back
// onto the notes blocks the editing machinery already speaks (anchor id,
// section, block text, occurrence, host text). Nothing here is laid out; the
// view (NotesDocumentView.swift) owns geometry.

/// What the text of the document depends on. Correction rows, the composer,
/// the selection and the marks are NOT here: they never rebuild the string.
struct NotesDocInput: Equatable {
    var structured: NotesStructured
    var doneKeys: Set<String>
    var searchTerms: [String]
    var portuguese: Bool
    var userActionTitle: String
    /// The "Completed (n)" disclosure is open: the done items are laid out.
    var completedExpanded = false
    var direction: DesignDirection
}

/// One notes block inside the document: the characters `range` covers are
/// exactly `hostText` (UTF-16 for UTF-16), so a selected sub-range maps onto
/// the host text by offset alone.
struct NotesDocBlock {
    var anchorID: String
    var section: MeetingCorrection.Section
    var blockText: String
    var hostText: String
    var occurrence: Int
    var alwaysQuote: Bool
    var range: NSRange
    /// The paragraph index the block's text lives in; its spacing is what
    /// opens under the block when something is placed below it.
    var paragraph: Int
    /// Where anything placed under the block starts, from the column's edge.
    var indent: CGFloat
    /// A table is not laid out in the text flow (TextKit 2 has no tables): it
    /// is placed under a near-empty paragraph like any other widget.
    var table: MarkdownBlock?
    /// A completed action item: a block for placement, never an AI target.
    var targetable = true
    /// The block's words hold a current search match.
    var searchMatch = false
    /// Its index in the document's rendered space (`NotesDocument.space`);
    /// nil for the header and tail placeholders.
    var rendered: Int?
}

struct NotesDocSection {
    var kind: Design.NoteSectionKind
    var title: Int
    var firstContent: Int
    var lastContent: Int
}

struct NotesDocToggle {
    var paragraph: Int
    var item: ActionItem
    var done: Bool
}

struct NotesDocParagraph {
    var range: NSRange
    var style: NSParagraphStyle
    var section: Int?
    var isTitle = false
    var hasSeal = false
    /// A thematic break: a divider drawn across the box at this paragraph.
    var isRule = false
    /// A code block: a plate drawn behind its lines.
    var isCode = false
}

extension NSAttributedString.Key {
    /// Marks a list marker and the tab after it, so copied text can say "• ".
    static let notesDocListMarker = NSAttributedString.Key("BlaiseNotesDocListMarker")
    /// Marks the character a placeholder paragraph holds, so a copy drops it
    /// and keeps the same character where the notes' own text has it.
    static let notesDocPlaceholder = NSAttributedString.Key("BlaiseNotesDocPlaceholder")
}

@MainActor
final class NotesDocument {
    let text: NSAttributedString
    let paragraphs: [NotesDocParagraph]
    let blocks: [NotesDocBlock]
    let sections: [NotesDocSection]
    let toggles: [NotesDocToggle]
    let paragraphAt: [Int: Int]
    let blockIndex: [String: Int]
    /// The rendered space these blocks' texts come from, folded once per
    /// document: every passage question about these notes asks this value.
    let space: CorrectionAnchoring.RenderedSpace
    /// The summary and detailed notes as parsed for `space` (block kinds).
    let parsed: CorrectionAnchoring.ParsedNotes
    /// The pane block standing for each rendered block that is laid out.
    let anchorOfRendered: [Int: String]
    let look: NotesDocLook
    /// The user's own action items (non-blank, in order) and which are done:
    /// two documents with the same items and a larger done set are a tick.
    let userItems: [String]
    let doneUserKeys: Set<String>
    /// The anchor the user-action box scrolls to.
    let userActionTitle: Int?
    /// The "Completed (n)" line of the user-action box, when it has done items.
    let completedDisclosure: Int?
    /// The trailing placeholder where the orphaned composer and the
    /// "Your notes" tail are placed.
    static let tailAnchor = "notes-doc-tail"
    /// The leading placeholder the meeting header is placed under, so the
    /// header scrolls with the notes.
    static let headAnchor = "notes-doc-head"

    /// The two placeholders that carry pane chrome rather than a notes block.
    static func isEdge(_ anchor: String) -> Bool { anchor == tailAnchor || anchor == headAnchor }

    init(
        text: NSAttributedString, paragraphs: [NotesDocParagraph], blocks: [NotesDocBlock],
        sections: [NotesDocSection], toggles: [NotesDocToggle], userActionTitle: Int?,
        completedDisclosure: Int? = nil, space: CorrectionAnchoring.RenderedSpace,
        parsed: CorrectionAnchoring.ParsedNotes, look: NotesDocLook,
        userItems: [String] = [], doneUserKeys: Set<String> = []
    ) {
        self.space = space
        self.parsed = parsed
        self.look = look
        self.userItems = userItems
        self.doneUserKeys = doneUserKeys
        self.text = text
        self.paragraphs = paragraphs
        self.blocks = blocks
        self.sections = sections
        self.toggles = toggles
        self.userActionTitle = userActionTitle
        self.completedDisclosure = completedDisclosure
        var at: [Int: Int] = [:]
        for (index, paragraph) in paragraphs.enumerated() { at[paragraph.range.location] = index }
        paragraphAt = at
        var byAnchor: [String: Int] = [:]
        var byRendered: [Int: String] = [:]
        for (index, block) in blocks.enumerated() {
            byAnchor[block.anchorID] = index
            if let rendered = block.rendered { byRendered[rendered] = block.anchorID }
        }
        blockIndex = byAnchor
        anchorOfRendered = byRendered
    }

    func block(_ anchor: String) -> NotesDocBlock? { blockIndex[anchor].map { blocks[$0] } }

    /// A done item the closed "Completed (n)" line keeps off the page: it has
    /// no block to scroll to until the line opens.
    func hiddenInCompleted(_ anchor: String) -> Bool {
        guard completedDisclosure != nil, block(anchor) == nil else { return false }
        return userItems.indices.contains {
            UserActionAnchor.id($0) == anchor && doneUserKeys.contains(ActionItemKey.key(for: userItems[$0]))
        }
    }

    /// Where the content of the section a paragraph belongs to sits.
    func insets(ofParagraph paragraph: Int) -> NotesDocLook.Insets {
        guard let section = paragraphs[paragraph].section else { return look.content }
        return look.insets(sections[section].kind)
    }

    /// The block whose paragraph holds `location`.
    func block(atCharacter location: Int) -> NotesDocBlock? {
        var low = 0
        var high = blocks.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let paragraph = paragraphs[blocks[mid].paragraph].range
            if location < paragraph.location {
                high = mid - 1
            } else if location >= NSMaxRange(paragraph) {
                low = mid + 1
            } else {
                return blocks[mid]
            }
        }
        return nil
    }

    /// What a selection aims the AI actions at: the one block it lies in, and
    /// the selected range inside that block's host text. A selection across
    /// blocks, inside a code block (today's code is never aimed word by word)
    /// or on a completed item aims at nothing.
    func aim(for selection: NSRange) -> (block: NotesDocBlock, local: NSRange)? {
        guard selection.length > 0 else { return nil }
        let touched = blocks.filter { NSIntersectionRange($0.range, selection).length > 0 }
        guard touched.count == 1, let block = touched.first, block.targetable,
            !paragraphs[block.paragraph].isCode
        else { return nil }
        let inside = NSIntersectionRange(block.range, selection)
        return (block, NSRange(location: inside.location - block.range.location, length: inside.length))
    }

    /// What a selection across blocks yields (n7 §1).
    enum Capture: Equatable {
        case none
        /// One piece: that block and its ORIGINAL selected range in its host
        /// text, for today's one-paragraph entry.
        case onePiece(anchorID: String, local: NSRange)
        case passage(PassageCapture)
    }

    /// The pieces of a selection that touches more than one block: each
    /// correctable block's selected host text without an owner prefix, a
    /// U+2029 as a space, trimmed; empty pieces dropped; then the sloppy-drag
    /// rule (a first, then a last, piece holding no whole word is dropped
    /// while two or more remain). Cheap: no passage walk runs here.
    func capture(_ selection: NSRange) -> Capture {
        guard selection.length > 0 else { return .none }
        var pieces: [(block: NotesDocBlock, local: NSRange, original: NSRange)] = []
        for block in blocks where block.targetable && block.table == nil && block.rendered != nil {
            let inside = NSIntersectionRange(block.range, selection)
            guard inside.length > 0 else { continue }
            let original = NSRange(location: inside.location - block.range.location, length: inside.length)
            let host = block.hostText as NSString
            let prefix = Self.ownerPrefixLength(block)
            var local = NSIntersectionRange(original, NSRange(location: prefix, length: host.length - prefix))
            let blank = CharacterSet.whitespacesAndNewlines
            while local.length > 0, let scalar = UnicodeScalar(host.character(at: local.location)),
                blank.contains(scalar)
            {
                local = NSRange(location: local.location + 1, length: local.length - 1)
            }
            while local.length > 0, let scalar = UnicodeScalar(host.character(at: NSMaxRange(local) - 1)),
                blank.contains(scalar)
            {
                local.length -= 1
            }
            guard local.length > 0 else { continue }
            pieces.append((block, local, original))
        }
        if pieces.count >= 2, !Self.holdsWholeWord(pieces[0].block, pieces[0].local) { pieces.removeFirst() }
        if pieces.count >= 2, let last = pieces.last, !Self.holdsWholeWord(last.block, last.local) {
            pieces.removeLast()
        }
        switch pieces.count {
        case 0: return .none
        case 1: return .onePiece(anchorID: pieces[0].block.anchorID, local: pieces[0].original)
        default:
            return .passage(
                PassageCapture(
                    pieces: pieces.map { piece in
                        PassageCapture.Piece(
                            anchorID: piece.block.anchorID, section: piece.block.section, local: piece.local,
                            text: (piece.block.hostText as NSString).substring(with: piece.local)
                                .replacingOccurrences(of: "\u{2029}", with: " "))
                    }))
        }
    }

    /// The passage occurrence a capture stores: the index of the instance
    /// whose last piece sits where the last piece was dragged in the anchor
    /// block. Runs the passage walk once, when an action is taken.
    func occurrence(of passage: PassageCapture) -> Int {
        guard let last = passage.pieces.last, let anchor = block(last.anchorID), let rendered = anchor.rendered
        else { return 0 }
        let instances = CorrectionAnchoring.passageInstances(
            quote: passage.quote, section: anchor.section, in: space)
        let text = space.blocks[rendered].text
        let dragged = Self.foldOffset(atUTF16: last.local.location - Self.ownerPrefixLength(anchor), in: text)
        var best: (index: Int, distance: Int)?
        for (index, instance) in instances.enumerated() where instance.anchorBlock == rendered {
            guard let placed = instance.placements.last??.range.lowerBound else { continue }
            let distance = abs(placed - dragged)
            if best.map({ distance < $0.distance }) ?? true { best = (index, distance) }
        }
        return best?.index ?? 0
    }

    /// Where a piece placed by the passage rule sits in its block's host text,
    /// or nil when it lies on no laid-out text block (a table, a collapsed
    /// done item).
    func hostRange(of placement: CorrectionAnchoring.PiecePlacement) -> (anchorID: String, local: NSRange)? {
        guard let anchorID = anchorOfRendered[placement.block], let block = block(anchorID),
            block.table == nil, block.range.length > 0
        else { return nil }
        let text = space.blocks[placement.block].text
        let positions = CorrectionAnchoring.foldPositions(text)
        let characters = Array(text.indices)
        guard
            let first = positions.firstIndex(where: { $0.map { $0 >= placement.range.lowerBound } ?? false }),
            let last = positions.lastIndex(where: { $0.map { $0 < placement.range.upperBound } ?? false }),
            first <= last
        else { return nil }
        let local = NSRange(characters[first] ..< text.index(after: characters[last]), in: text)
        return (anchorID, NSRange(location: local.location + Self.ownerPrefixLength(block), length: local.length))
    }

    /// An action item's host text leads with "Owner: ", which is chrome.
    static func ownerPrefixLength(_ block: NotesDocBlock) -> Int {
        let host = block.hostText as NSString
        let text = block.blockText as NSString
        guard host.length > text.length, block.hostText.hasSuffix(block.blockText) else { return 0 }
        return host.length - text.length
    }

    /// Whether some word of the block's host text (as `.byWords` delimits
    /// words) whose fold is non-empty lies wholly inside `local`.
    private static func holdsWholeWord(_ block: NotesDocBlock, _ local: NSRange) -> Bool {
        let host = block.hostText as NSString
        var found = false
        host.enumerateSubstrings(in: NSRange(location: 0, length: host.length), options: .byWords) {
            word, range, _, stop in
            guard NSMaxRange(range) > local.location else { return }
            if range.location >= NSMaxRange(local) {
                stop.pointee = true
                return
            }
            if range.location >= local.location, NSMaxRange(range) <= NSMaxRange(local),
                let word, !CorrectionAnchoring.fold(word).isEmpty
            {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    /// The folded offset of the first folded Character at or after a UTF-16
    /// offset of `text`.
    private static func foldOffset(atUTF16 offset: Int, in text: String) -> Int {
        let positions = CorrectionAnchoring.foldPositions(text)
        let index = text.utf16.index(text.startIndex, offsetBy: max(0, min(offset, text.utf16.count)))
        let start = min(text.distance(from: text.startIndex, to: index), positions.count)
        return positions[start...].lazy.compactMap { $0 }.first
            ?? positions.lazy.compactMap { $0 }.last ?? 0
    }

    /// The text a copy carries: no placeholder characters, a line break inside
    /// a block as a newline, list markers as "• " / "1. ".
    static func copyText(_ source: NSAttributedString) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: source)
        var tabs: [NSRange] = []
        out.enumerateAttribute(.notesDocListMarker, in: NSRange(location: 0, length: out.length)) { value, range, _ in
            guard value != nil else { return }
            let text = (out.string as NSString).substring(with: range) as NSString
            let tab = text.range(of: "\t")
            if tab.location != NSNotFound { tabs.append(NSRange(location: range.location + tab.location, length: 1)) }
        }
        for tab in tabs.reversed() { out.replaceCharacters(in: tab, with: " ") }
        let string = out.string as NSString
        for index in stride(from: string.length - 1, through: 0, by: -1) where string.character(at: index) == 0x2028 {
            out.replaceCharacters(in: NSRange(location: index, length: 1), with: "\n")
        }
        var placeholders: [NSRange] = []
        out.enumerateAttribute(.notesDocPlaceholder, in: NSRange(location: 0, length: out.length)) { value, range, _ in
            if value != nil { placeholders.append(range) }
        }
        for range in placeholders.reversed() { out.deleteCharacters(in: range) }
        out.removeAttribute(.notesDocListMarker, range: NSRange(location: 0, length: out.length))
        return out
    }
}

// MARK: - Look (aquarela; today's NoteSection / MarkdownBlockView values)

@MainActor
enum NotesDocStyle {
    static let boxPadding: CGFloat = 14
    static let sectionGap: CGFloat = 24
    static let titleGap: CGFloat = 9
    static let blockGap: CGFloat = 8
    static let chipSize: CGFloat = 19
    static let chipSpacing: CGFloat = 7
    static let toggleWidth: CGFloat = 14
    /// Today's code block pads its text 10 pt inside its plate.
    static let codePadding: CGFloat = 10
    /// Where the "Completed (n)" label starts after its chevron.
    static let disclosureIndent: CGFloat = 16
    /// Today's disclosure row is taller than its label: the label stands this
    /// much lower, and the row reaches this much further below it.
    static let disclosureAbove: CGFloat = 3
    static let disclosureBelow: CGFloat = 4.5

    static func ink(_ alpha: CGFloat) -> NSColor { NSColor(white: 1, alpha: alpha) }
    // Dark-aqua label ramp: primary 0.85, secondary 0.55, tertiary 0.25.
    static let primary: CGFloat = 0.85
    static let secondary: CGFloat = 0.55
    static let tertiary: CGFloat = 0.25
}

// MARK: - Builder

@MainActor
struct NotesDocumentBuilder {
    private var out = NSMutableAttributedString()
    private var paragraphs: [(start: Int, style: NSMutableParagraphStyle, gapAfter: CGFloat, section: Int?, isTitle: Bool, hasSeal: Bool, isRule: Bool, isCode: Bool)] = []
    private var blocks: [NotesDocBlock] = []
    private var sections: [NotesDocSection] = []
    private var toggles: [NotesDocToggle] = []
    private var userActionTitle: Int?
    private var completedDisclosure: Int?
    private var userItems: [String] = []
    private var doneUserKeys: Set<String> = []
    private var currentSection: Int?
    private let terms: [String]
    /// The rendered space every block's text comes from.
    private let space: CorrectionAnchoring.RenderedSpace
    /// The summary and detailed notes, parsed once for the space and the text.
    private let parsed: CorrectionAnchoring.ParsedNotes
    /// Where each section's blocks start in `space`.
    private let sectionStart: [MeetingCorrection.Section: Int]
    private let look: NotesDocLook
    /// Where the current section's content sits.
    private var inset = NotesDocLook.Insets.all(0)

    private init(terms: [String], structured: NotesStructured, look: NotesDocLook) {
        self.terms = terms
        self.look = look
        parsed = CorrectionAnchoring.ParsedNotes(structured)
        space = CorrectionAnchoring.RenderedSpace(structured, parsed: parsed)
        var starts: [MeetingCorrection.Section: Int] = [:]
        for (index, block) in space.blocks.enumerated() where starts[block.section] == nil {
            starts[block.section] = index
        }
        sectionStart = starts
    }

    static func build(_ input: NotesDocInput) -> NotesDocument {
        var builder = NotesDocumentBuilder(
            terms: input.searchTerms, structured: input.structured, look: .of(input.direction))
        builder.compose(input)
        return builder.finish()
    }

    /// A block's index in the rendered space and the text it draws.
    private func rendered(_ section: MeetingCorrection.Section, _ index: Int) -> (index: Int, text: String) {
        let at = sectionStart[section, default: 0] + index
        return (at, space.blocks[at].text)
    }

    // MARK: Sections

    private mutating func compose(_ input: NotesDocInput) {
        let structured = input.structured
        let pt = input.portuguese

        // The header's place: it scrolls with the notes, 24 above them.
        let head = placeholderParagraph(gapAfter: NotesDocStyle.sectionGap)
        blocks.append(
            NotesDocBlock(
                anchorID: NotesDocument.headAnchor, section: .summary, blockText: "", hostText: "",
                occurrence: 0, alwaysQuote: false, range: head, paragraph: paragraphs.count - 1, indent: 0))

        // Summary
        beginSection(.summary, title: pt ? "Resumo" : "Summary")
        let summaryBlocks = parsed.summary
        let summaryOccurrences = fastOccurrences(in: space.foldedBlocks(of: .summary))
        for (index, block) in summaryBlocks.enumerated() {
            markdownBlock(
                block, section: .summary, anchorID: NotesBlockAnchor.summary(block.id),
                occurrence: summaryOccurrences[index], rendered: rendered(.summary, index))
        }
        endSection()

        // The user's own action items: the accented box.
        let userItems = CorrectionAnchoring.presentableItems(structured.userActionItems)
        self.userItems = userItems.map(\.text)
        doneUserKeys = input.doneKeys.intersection(userItems.map { ActionItemKey.key(for: $0.text) })
        if !userItems.isEmpty {
            beginSection(.userActions, title: input.userActionTitle)
            userActionTitle = sections.last?.title
            let occurrences = fastOccurrences(in: space.foldedBlocks(of: .userActionItem))
            let toggleIndent = inset.leading + NotesDocStyle.toggleWidth + 8
            var open = 0
            for (index, item) in userItems.enumerated()
            where !input.doneKeys.contains(ActionItemKey.key(for: item.text)) {
                open += 1
                let text = rendered(.userActionItem, index)
                let style = paragraphStyle(indent: toggleIndent, lineSpacing: 0)
                let range = appendParagraph(
                    [Run(text.text, look.readingFont(14, .medium), NotesDocStyle.primary)],
                    style: style, gapAfter: NotesDocStyle.blockGap)
                toggles.append(NotesDocToggle(paragraph: paragraphs.count - 1, item: item, done: false))
                blocks.append(
                    NotesDocBlock(
                        anchorID: UserActionAnchor.id(index), section: .userActionItem,
                        blockText: text.text, hostText: text.text, occurrence: occurrences[index],
                        alwaysQuote: false, range: range, paragraph: paragraphs.count - 1,
                        indent: inset.leading, searchMatch: matches(text.text), rendered: text.index))
            }
            if open == 0 {
                appendParagraph(
                    [Run(pt ? "Tudo concluído." : "All done.", look.readingFont(13), NotesDocStyle.secondary)],
                    style: paragraphStyle(indent: inset.leading, lineSpacing: 0),
                    gapAfter: NotesDocStyle.blockGap, highlight: false)
            }
            let completed = userItems.enumerated().filter {
                input.doneKeys.contains(ActionItemKey.key(for: $0.element.text))
            }
            if !completed.isEmpty {
                // Today's collapsed disclosure: a chevron is placed before the
                // label, and the done items are laid out only when it is open.
                appendParagraph(
                    [Run(pt ? "Concluídos (\(completed.count))" : "Completed (\(completed.count))",
                         .systemFont(ofSize: 12, weight: .medium), NotesDocStyle.secondary)],
                    style: paragraphStyle(
                        indent: inset.leading + NotesDocStyle.disclosureIndent, lineSpacing: 0),
                    gapAfter: NotesDocStyle.blockGap + NotesDocStyle.disclosureBelow,
                    extraBefore: look.disclosureAbove, highlight: false)
                completedDisclosure = paragraphs.count - 1
                if input.completedExpanded {
                    // Blocks in the same anchor space as the open items, so a
                    // row standing on a done item is placed under it; never a
                    // target for the AI actions.
                    for (index, item) in completed {
                        let text = rendered(.userActionItem, index)
                        let range = appendParagraph(
                            [Run(text.text, look.readingFont(14), NotesDocStyle.secondary)],
                            style: paragraphStyle(indent: toggleIndent, lineSpacing: 0),
                            gapAfter: NotesDocStyle.blockGap, strike: true)
                        toggles.append(NotesDocToggle(paragraph: paragraphs.count - 1, item: item, done: true))
                        blocks.append(
                            NotesDocBlock(
                                anchorID: UserActionAnchor.id(index), section: .userActionItem,
                                blockText: text.text, hostText: text.text, occurrence: occurrences[index],
                                alwaysQuote: false, range: range, paragraph: paragraphs.count - 1,
                                indent: inset.leading, targetable: false,
                                searchMatch: matches(text.text), rendered: text.index))
                    }
                }
            }
            endSection()
        }

        if !structured.decisions.isEmpty {
            beginSection(.decisions, title: pt ? "Decisões" : "Decisions")
            let occurrences = fastOccurrences(in: space.foldedBlocks(of: .decision))
            let sealIndent = inset.leading + 12 + 8
            for index in structured.decisions.indices {
                let decision = rendered(.decision, index)
                let range = appendParagraph(
                    [Run(decision.text, look.readingFont(14), NotesDocStyle.primary)],
                    style: paragraphStyle(indent: sealIndent, lineSpacing: Design.readingLineSpacing - 2),
                    gapAfter: NotesDocStyle.blockGap, seal: true)
                blocks.append(
                    NotesDocBlock(
                        anchorID: NotesBlockAnchor.decision(index), section: .decision,
                        blockText: decision.text, hostText: decision.text, occurrence: occurrences[index],
                        alwaysQuote: false, range: range, paragraph: paragraphs.count - 1,
                        indent: inset.leading, searchMatch: matches(decision.text),
                        rendered: decision.index))
            }
            endSection()
        }

        let actionItems = CorrectionAnchoring.presentableItems(structured.actionItems)
        if !actionItems.isEmpty {
            beginSection(.actions, title: pt ? "Itens de Ação" : "Action Items")
            let occurrences = fastOccurrences(in: space.foldedBlocks(of: .actionItem))
            for (index, item) in actionItems.enumerated() {
                let text = rendered(.actionItem, index)
                let host = item.owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? text.text : "\(item.owner): \(text.text)"
                let range = listParagraph(
                    marker: "•", markerFont: .systemFont(ofSize: 13),
                    markerColor: NSColor(Design.support), depthIndent: 0,
                    runs: [Run(host, look.readingFont(14), NotesDocStyle.primary)],
                    lineSpacing: 0)
                blocks.append(
                    NotesDocBlock(
                        anchorID: NotesBlockAnchor.actionItem(index), section: .actionItem,
                        blockText: text.text, hostText: host, occurrence: occurrences[index],
                        alwaysQuote: false, range: range, paragraph: paragraphs.count - 1,
                        indent: inset.leading, searchMatch: matches(host), rendered: text.index))
            }
            endSection()
        }

        let detailed = structured.detailedNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !detailed.isEmpty {
            beginSection(.detailed, title: pt ? "Notas Detalhadas" : "Detailed Notes")
            let detailedBlocks = parsed.detailed
            let occurrences = fastOccurrences(in: space.foldedBlocks(of: .detailedNotes))
            for (index, block) in detailedBlocks.enumerated() {
                markdownBlock(
                    block, section: .detailedNotes, anchorID: NotesBlockAnchor.detailed(block.id),
                    occurrence: occurrences[index], rendered: rendered(.detailedNotes, index))
            }
            endSection()
        }

        // The tail: where an orphaned composer and unanchored notes are placed.
        let range = placeholderParagraph(gapAfter: 0)
        blocks.append(
            NotesDocBlock(
                anchorID: NotesDocument.tailAnchor, section: .detailedNotes, blockText: "",
                hostText: "", occurrence: 0, alwaysQuote: false, range: range,
                paragraph: paragraphs.count - 1, indent: 0))
        // A last, empty-looking paragraph, so the tail's own spacing (what
        // opens under it) is never the document's final paragraph's.
        placeholderParagraph(gapAfter: 0)
    }

    private mutating func beginSection(_ kind: Design.NoteSectionKind, title: String) {
        let style = NSMutableParagraphStyle()
        var attributes: [NSAttributedString.Key: Any] = [.font: look.titleFont]
        switch look.heading {
        case .chip:
            style.firstLineHeadIndent = NotesDocStyle.chipSize + NotesDocStyle.chipSpacing
            style.headIndent = style.firstLineHeadIndent
            style.minimumLineHeight = NotesDocStyle.chipSize
            style.maximumLineHeight = NotesDocStyle.chipSize
            attributes[.foregroundColor] = NSColor(Design.sectionTint(kind))
            attributes[.baselineOffset] = 2.5
        case .tick, .rule:
            attributes[.foregroundColor] = look.heading == .tick
                ? NotesDocStyle.ink(NotesDocStyle.secondary) : NSColor(Design.accent.opacity(0.92))
            attributes[.kern] = look.titleKerning
        }
        let sectionIndex = sections.count
        currentSection = sectionIndex
        inset = look.insets(kind)
        let attributed = NSAttributedString(string: look.titleText(title), attributes: attributes)
        appendRaw(attributed, style: style, gapAfter: look.titleGap + inset.top, isTitle: true)
        sections.append(
            NotesDocSection(kind: kind, title: paragraphs.count - 1, firstContent: paragraphs.count, lastContent: paragraphs.count))
    }

    private mutating func endSection() {
        guard let index = currentSection else { return }
        sections[index].lastContent = paragraphs.count - 1
        if sections[index].lastContent < sections[index].firstContent {
            // An empty section still draws its box around one empty line.
            placeholderParagraph(gapAfter: 0)
            sections[index].lastContent = paragraphs.count - 1
        }
        // A closed "Completed (n)" row ends the box, its reach below included.
        let below = completedDisclosure == paragraphs.count - 1 ? NotesDocStyle.disclosureBelow : 0
        paragraphs[paragraphs.count - 1].gapAfter = below + inset.bottom + NotesDocStyle.sectionGap
        currentSection = nil
    }

    // MARK: Markdown blocks (today's MarkdownBlockView values)

    private mutating func markdownBlock(
        _ block: MarkdownBlock, section: MeetingCorrection.Section, anchorID: String, occurrence: Int,
        rendered: (index: Int, text: String)
    ) {
        let host = rendered.text
        var range: NSRange
        var indent = inset.leading
        var table: MarkdownBlock?
        switch block.kind {
        case .paragraph, .blockQuote:
            range = appendParagraph(
                inlineRuns(block.text, font: look.readingFont(14), alpha: NotesDocStyle.primary * 0.9),
                style: paragraphStyle(indent: inset.leading, lineSpacing: Design.readingLineSpacing),
                gapAfter: NotesDocStyle.blockGap)
        case .header:
            range = appendParagraph(
                inlineRuns(block.text, font: look.readingFont(14, .semibold), alpha: NotesDocStyle.primary),
                style: paragraphStyle(indent: inset.leading, lineSpacing: 0),
                gapAfter: NotesDocStyle.blockGap, extraBefore: 4)
        case .listItem(let ordinal, let depth):
            let depthIndent = CGFloat(max(0, depth - 1)) * 16
            indent += depthIndent
            range = listParagraph(
                marker: ordinal.map { "\($0)." } ?? "•",
                markerFont: .monospacedDigitSystemFont(ofSize: 13, weight: .regular),
                markerColor: look.accentMarkers
                    ? NSColor(Design.accent.opacity(0.7)) : NotesDocStyle.ink(NotesDocStyle.tertiary),
                depthIndent: depthIndent,
                runs: inlineRuns(block.text, font: look.readingFont(14), alpha: NotesDocStyle.primary * 0.88),
                lineSpacing: Design.readingLineSpacing - 2)
        case .codeBlock:
            range = appendParagraph(
                inlineRuns(block.text, font: .monospacedSystemFont(ofSize: 12.5, weight: .regular), alpha: NotesDocStyle.primary),
                style: paragraphStyle(indent: inset.leading + 10, lineSpacing: 0),
                gapAfter: NotesDocStyle.blockGap + NotesDocStyle.codePadding,
                extraBefore: NotesDocStyle.codePadding, code: true)
        case .thematicBreak:
            range = placeholderParagraph(gapAfter: NotesDocStyle.blockGap, isRule: true)
        case .table:
            range = placeholderParagraph(gapAfter: NotesDocStyle.blockGap)
            table = block
        }
        blocks.append(
            NotesDocBlock(
                anchorID: anchorID, section: section, blockText: host,
                hostText: table == nil ? host : "", occurrence: occurrence, alwaysQuote: true,
                range: range, paragraph: paragraphs.count - 1, indent: indent, table: table,
                searchMatch: matches(host), rendered: rendered.index))
    }

    private func matches(_ text: String) -> Bool {
        !terms.isEmpty && SearchTextMatcher.contains(text, terms: terms)
    }

    private struct Run {
        var text: String
        var font: NSFont
        var alpha: CGFloat
        var link: URL?
        var strike = false

        init(_ text: String, _ font: NSFont, _ alpha: CGFloat, link: URL? = nil, strike: Bool = false) {
            self.text = text
            self.font = font
            self.alpha = alpha
            self.link = link
            self.strike = strike
        }
    }

    /// The markdown parser's inline styles (bold, italics, code, strikethrough,
    /// links), as today's SwiftUI Text renders them.
    private func inlineRuns(_ source: AttributedString, font: NSFont, alpha: CGFloat) -> [Run] {
        source.runs.map { run in
            var runFont = font
            var strike = false
            if let intent = run.inlinePresentationIntent {
                strike = intent.contains(.strikethrough)
                if intent.contains(.stronglyEmphasized) {
                    runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .boldFontMask)
                }
                if intent.contains(.emphasized) {
                    runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .italicFontMask)
                }
                if intent.contains(.code) {
                    runFont = .monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
                }
            }
            return Run(String(source[run.range].characters), runFont, alpha, link: run.link, strike: strike)
        }
    }

    // MARK: Paragraph primitives

    private func paragraphStyle(indent: CGFloat, lineSpacing: CGFloat) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        style.tailIndent = -inset.trailing
        style.lineSpacing = lineSpacing
        return style
    }

    @discardableResult
    private mutating func listParagraph(
        marker: String, markerFont: NSFont, markerColor: NSColor, depthIndent: CGFloat, runs: [Run],
        lineSpacing: CGFloat
    ) -> NSRange {
        let start = inset.leading + depthIndent
        let markerWidth = ceil((marker as NSString).size(withAttributes: [.font: markerFont]).width)
        let textX = start + markerWidth + 8
        let style = paragraphStyle(indent: start, lineSpacing: lineSpacing)
        style.headIndent = textX
        style.tabStops = [NSTextTab(textAlignment: .left, location: textX)]
        style.defaultTabInterval = 0
        let prefix = NSAttributedString(
            string: marker + "\t",
            attributes: [.font: markerFont, .foregroundColor: markerColor, .notesDocListMarker: true])
        return appendParagraph(runs, style: style, gapAfter: NotesDocStyle.blockGap, prefix: prefix)
    }

    /// Appends one paragraph; returns the range of `runs` (the block's host
    /// text), never the marker prefix or the paragraph break.
    @discardableResult
    private mutating func appendParagraph(
        _ runs: [Run], style: NSMutableParagraphStyle, gapAfter: CGFloat, extraBefore: CGFloat = 0,
        prefix: NSAttributedString? = nil, seal: Bool = false, strike: Bool = false, code: Bool = false,
        highlight: Bool = true
    ) -> NSRange {
        let body = NSMutableAttributedString()
        if let prefix { body.append(prefix) }
        let hostStart = body.length
        for run in runs {
            let text = Self.oneParagraph(run.text)
            var attributes: [NSAttributedString.Key: Any] = [
                .font: run.font, .foregroundColor: NotesDocStyle.ink(run.alpha),
            ]
            if strike || run.strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attributes[.link] = link }
            body.append(NSAttributedString(string: text, attributes: attributes))
        }
        let hostRange = NSRange(location: hostStart, length: body.length - hostStart)
        if highlight { highlightSearch(in: body, range: hostRange) }
        if extraBefore > 0, !paragraphs.isEmpty { paragraphs[paragraphs.count - 1].gapAfter += extraBefore }
        let location = appendRaw(body, style: style, gapAfter: gapAfter, hasSeal: seal, isCode: code)
        return NSRange(location: location + hostStart, length: hostRange.length)
    }

    /// Every paragraph break the text system knows (newline, return, U+2029,
    /// U+0085) becomes a line separator, one UTF-16 unit for one, so a block
    /// is always ONE paragraph and offsets into its host text still hold.
    static func oneParagraph(_ text: String) -> String {
        let units = Array(text.utf16)
        guard units.contains(where: { $0 == 0x0A || $0 == 0x0D || $0 == 0x2029 || $0 == 0x85 }) else { return text }
        return String(
            utf16CodeUnits: units.map { $0 == 0x0A || $0 == 0x0D || $0 == 0x2029 || $0 == 0x85 ? 0x2028 : $0 },
            count: units.count)
    }

    /// A near-empty paragraph: the anchor for something placed in the flow
    /// that is not text (a table, a divider, the tail).
    @discardableResult
    private mutating func placeholderParagraph(gapAfter: CGFloat, isRule: Bool = false) -> NSRange {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = 0.5
        style.maximumLineHeight = 0.5
        let location = appendRaw(
            NSAttributedString(
                string: "\u{200B}", attributes: [.font: NSFont.systemFont(ofSize: 0.5), .notesDocPlaceholder: true]),
            style: style, gapAfter: gapAfter, isRule: isRule)
        return NSRange(location: location, length: 0)
    }

    @discardableResult
    private mutating func appendRaw(
        _ body: NSAttributedString, style: NSMutableParagraphStyle, gapAfter: CGFloat,
        isTitle: Bool = false, hasSeal: Bool = false, isRule: Bool = false, isCode: Bool = false
    ) -> Int {
        let location = out.length
        out.append(body)
        let font = body.length > 0
            ? (body.attribute(.font, at: body.length - 1, effectiveRange: nil) ?? NSFont.systemFont(ofSize: 0.5))
            : NSFont.systemFont(ofSize: 0.5)
        out.append(NSAttributedString(string: "\n", attributes: [.font: font]))
        paragraphs.append((location, style, gapAfter, currentSection, isTitle, hasSeal, isRule, isCode))
        return location
    }

    private func highlightSearch(in body: NSMutableAttributedString, range: NSRange) {
        guard !terms.isEmpty else { return }
        let plain = (body.string as NSString).substring(with: range)
        var offset = range.location
        for segment in SearchTextMatcher.segments(plain, matching: terms) {
            let length = (segment.text as NSString).length
            defer { offset += length }
            guard segment.isMatch else { continue }
            let match = NSRange(location: offset, length: length)
            body.enumerateAttribute(.font, in: match) { value, sub, _ in
                if let font = value as? NSFont {
                    body.addAttribute(
                        .font, value: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask), range: sub)
                }
            }
            body.addAttributes(
                [
                    .foregroundColor: NSColor(Design.accent),
                    .backgroundColor: NSColor(Design.accent.opacity(0.2)),
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ], range: match)
        }
    }

    // MARK: Finish

    /// Paragraph spacing is set once every paragraph is known: TextKit 2 puts a
    /// paragraph's line spacing ABOVE its first line (measured), so the gap
    /// today's stacks leave between two blocks is this paragraph's spacing plus
    /// the NEXT one's line spacing.
    private mutating func finish() -> NotesDocument {
        // Drop the final paragraph break so the document has no empty last line.
        out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
        var result: [NotesDocParagraph] = []
        for index in paragraphs.indices {
            let entry = paragraphs[index]
            let end = index + 1 < paragraphs.count ? paragraphs[index + 1].start : out.length
            let nextLineSpacing = index + 1 < paragraphs.count ? paragraphs[index + 1].style.lineSpacing : 0
            entry.style.paragraphSpacing = max(0, entry.gapAfter - nextLineSpacing)
            let range = NSRange(location: entry.start, length: end - entry.start)
            if range.length > 0 { out.addAttribute(.paragraphStyle, value: entry.style, range: range) }
            result.append(
                NotesDocParagraph(
                    range: range, style: entry.style.copy() as! NSParagraphStyle, section: entry.section,
                    isTitle: entry.isTitle, hasSeal: entry.hasSeal, isRule: entry.isRule, isCode: entry.isCode))
        }
        return NotesDocument(
            text: out, paragraphs: result, blocks: blocks, sections: sections, toggles: toggles,
            userActionTitle: userActionTitle, completedDisclosure: completedDisclosure, space: space,
            parsed: parsed, look: look,
            userItems: userItems, doneUserKeys: doneUserKeys)
    }
}

/// `CorrectionAnchoring.occurrence(ofBlockAt:in:)` for every block — how many
/// EARLIER blocks' folds contain this block's fold — without its cost: the
/// library call measured ~47 ms on the largest note's 160 blocks (quadratic
/// `String.contains`). A literal code-unit search over the canonically
/// decomposed folds rules out almost every pair in a few ms, and each pair it
/// finds is confirmed by the library's own `contains`, so the count is the
/// library's. The search only rules a pair out where that is safe: a needle
/// that starts and ends on a base character keeps its code units inside any
/// decomposed text that contains it. A needle starting or ending on a
/// combining mark (marks around it can reorder across its edge), or either
/// side holding U+0F73 / U+0F75 / U+0F81 (Foundation leaves their marks out of
/// canonical order), is compared in full.
func fastOccurrences(in blocks: CorrectionAnchoring.FoldedBlocks) -> [Int] {
    let folds = blocks.folds
    let decomposed = folds.map { $0.decomposedStringWithCanonicalMapping as NSString }
    let unordered = folds.map { $0.unicodeScalars.contains { [0x0F73, 0x0F75, 0x0F81].contains($0.value) } }
    return folds.indices.map { index in
        let needle = decomposed[index]
        guard needle.length > 0 else { return 0 }
        let scalars = (needle as String).unicodeScalars
        let fullOnly = unordered[index]
            || [scalars.first, scalars.last].contains { $0?.properties.canonicalCombiningClass != .notReordered }
        var count = 0
        for earlier in 0..<index where
            (fullOnly || unordered[earlier]
                || (decomposed[earlier].length >= needle.length
                    && decomposed[earlier].range(of: needle as String, options: .literal).location != NSNotFound))
            && folds[earlier].contains(folds[index])
        {
            count += 1
        }
        return count
    }
}

// MARK: - The rows beside each block (today's grouping, per anchor)

struct NotesDocRows {
    var notes: [MeetingCorrection] = []
    var pending: [MeetingCorrection] = []
}

/// Where a passage row's pieces sit on the laid-out blocks, in piece order —
/// what each piece's mark paints.
struct NotesDocPieceMark: Equatable {
    var anchorID: String
    var local: NSRange
}

/// The rows the reading column shows: an annotation until it is resolved, a
/// correction until it is applied or resolved.
private func isLive(_ row: MeetingCorrection) -> Bool {
    switch row.kind {
    case .annotation: return row.status != .resolved
    case .understanding: return row.status != .applied && row.status != .resolved
    }
}

/// Groups correction rows onto the rendered blocks, keyed by anchor id. A
/// one-piece row is grouped exactly as today's `structuredSections` does; a
/// passage is placed under its anchor block by the passage rule, over the
/// document's rendered space, and its pieces' marks are located there too.
@MainActor
func notesDocRows(
    _ rows: [MeetingCorrection], document: NotesDocument, structured: NotesStructured
) -> (rows: [String: NotesDocRows], pieces: [String: [NotesDocPieceMark]]) {
    var grouped: [String: NotesDocRows] = [:]
    let onePiece = rows.filter { !CorrectionAnchoring.isPassage($0.quotedText) }
    let live = onePiece.filter(isLive)
    // Each section is folded once for every row resolved against it.
    var folded: [MeetingCorrection.Section: CorrectionAnchoring.FoldedBlocks] = [:]
    func anchored(_ kind: MeetingCorrection.Kind, _ section: MeetingCorrection.Section) -> [MeetingCorrection] {
        let blocks = folded[section]
            ?? CorrectionAnchoring.FoldedBlocks(CorrectionAnchoring.blocks(of: structured, section: section))
        folded[section] = blocks
        return live.filter {
            $0.kind == kind && $0.section == section
                && (CorrectionAnchoring.resolve(quote: $0.quotedText, occurrence: $0.occurrence, in: blocks)
                    ?? CorrectionAnchoring.resolveTable(
                        quote: $0.quotedText, occurrence: $0.occurrence, section: section, in: document.space)) != nil
        }
    }
    func place(_ byIndex: [Int: [MeetingCorrection]], pending: Bool, anchor: (Int) -> String) {
        for (index, rows) in byIndex {
            if pending {
                grouped[anchor(index), default: NotesDocRows()].pending += rows
            } else {
                grouped[anchor(index), default: NotesDocRows()].notes += rows
            }
        }
    }
    // The rendered summary and detailed blocks are the document's own space,
    // parsed and folded once per document (a block's index is its id).
    let summaryFolds = document.space.foldedBlocks(of: .summary)
    place(rowsByRenderedBlock(anchored(.annotation, .summary), uiTexts: summaryFolds), pending: false) {
        NotesBlockAnchor.summary($0)
    }
    place(rowsByRenderedBlock(anchored(.understanding, .summary), uiTexts: summaryFolds), pending: true) {
        NotesBlockAnchor.summary($0)
    }
    let folds = document.space.foldedBlocks(of: .detailedNotes)
    if !folds.blocks.isEmpty {
        place(rowsByRenderedBlock(anchored(.annotation, .detailedNotes), uiTexts: folds), pending: false) {
            NotesBlockAnchor.detailed($0)
        }
        place(rowsByRenderedBlock(anchored(.understanding, .detailedNotes), uiTexts: folds), pending: true) {
            NotesBlockAnchor.detailed($0)
        }
    }
    let lists: [(MeetingCorrection.Section, [String], (Int) -> String)] = [
        (.decision, structured.decisions, NotesBlockAnchor.decision),
        (.actionItem, CorrectionAnchoring.presentableItems(structured.actionItems).map(\.text), NotesBlockAnchor.actionItem),
        (.userActionItem, CorrectionAnchoring.presentableItems(structured.userActionItems).map(\.text), UserActionAnchor.id),
    ]
    for (section, texts, anchor) in lists {
        let folds = CorrectionAnchoring.FoldedBlocks(texts)
        place(rowsByAnchoredBlock(onePiece, kind: .annotation, section: section, blocks: folds), pending: false, anchor: anchor)
        place(rowsByAnchoredBlock(onePiece, kind: .understanding, section: section, blocks: folds), pending: true, anchor: anchor)
    }

    // Passages: resolved once here (a document or row change), never per draw.
    var pieces: [String: [NotesDocPieceMark]] = [:]
    for row in rows where CorrectionAnchoring.isPassage(row.quotedText) && isLive(row) {
        guard
            let resolved = CorrectionAnchoring.resolvePassage(
                quote: row.quotedText, occurrence: row.occurrence, section: row.section, in: document.space),
            let anchor = document.anchorOfRendered[resolved.instance.anchorBlock]
        else { continue }
        if row.kind == .understanding {
            grouped[anchor, default: NotesDocRows()].pending.append(row)
        } else {
            grouped[anchor, default: NotesDocRows()].notes.append(row)
        }
        pieces[row.id] = resolved.instance.placements.compactMap { placement in
            placement.flatMap(document.hostRange).map { NotesDocPieceMark(anchorID: $0.anchorID, local: $0.local) }
        }
    }
    // One block's rows in stored order, passages among them.
    if !pieces.isEmpty {
        let order = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.id, $0) })
        for anchor in grouped.keys {
            grouped[anchor]?.notes.sort { order[$0.id, default: 0] < order[$1.id, default: 0] }
            grouped[anchor]?.pending.sort { order[$0.id, default: 0] < order[$1.id, default: 0] }
        }
    }
    return (grouped, pieces)
}

/// The margin notes that stand in the "Your notes" tail: an annotation the
/// reading column shows whose anchor resolves nowhere — by the passage rule
/// for a passage, today's resolve otherwise (a whole table by its rendered
/// fallback), each section folded once.
@MainActor
func notesDocUnanchored(
    _ rows: [MeetingCorrection], structured: NotesStructured, space: CorrectionAnchoring.RenderedSpace
) -> [MeetingCorrection] {
    var folded: [MeetingCorrection.Section: CorrectionAnchoring.FoldedBlocks] = [:]
    return rows.filter { $0.kind == .annotation && $0.status != .resolved }.filter { row in
        if CorrectionAnchoring.isPassage(row.quotedText) {
            return CorrectionAnchoring.resolvePassage(
                quote: row.quotedText, occurrence: row.occurrence, section: row.section, in: space) == nil
        }
        let blocks = folded[row.section]
            ?? CorrectionAnchoring.FoldedBlocks(CorrectionAnchoring.blocks(of: structured, section: row.section))
        folded[row.section] = blocks
        return (CorrectionAnchoring.resolve(quote: row.quotedText, occurrence: row.occurrence, in: blocks)
            ?? CorrectionAnchoring.resolveTable(
                quote: row.quotedText, occurrence: row.occurrence, section: row.section, in: space)) == nil
    }
}

/// Today's one-paragraph re-pin of a loose note: the picked block's text is
/// the new quote — a U+2029 in it written as a space, since a stored U+2029 is
/// capture's piece joiner — with the block's occurrence among its equals.
func notesDocPin(_ blocks: [String], at index: Int) -> (quote: String, occurrence: Int)? {
    guard blocks.indices.contains(index) else { return nil }
    return (
        blocks[index].replacingOccurrences(of: "\u{2029}", with: " "),
        CorrectionAnchoring.occurrence(ofBlockAt: index, in: blocks)
    )
}

/// The anchor id of a rendered block.
func notesDocAnchorID(_ id: CorrectionAnchoring.RenderedBlock.ID) -> String {
    switch id.section {
    case .summary: return NotesBlockAnchor.summary(id.index)
    case .detailedNotes: return NotesBlockAnchor.detailed(id.index)
    case .decision: return NotesBlockAnchor.decision(id.index)
    case .actionItem: return NotesBlockAnchor.actionItem(id.index)
    case .userActionItem: return UserActionAnchor.id(id.index)
    }
}

/// Where "Go to this passage" takes the reader: a passage's FIRST piece's
/// block; a one-piece row's block among its section's rendered blocks. nil
/// when the row resolves nowhere.
func notesDocNavigationAnchor(_ row: MeetingCorrection, space: CorrectionAnchoring.RenderedSpace) -> String? {
    if CorrectionAnchoring.isPassage(row.quotedText) {
        guard
            let resolved = CorrectionAnchoring.resolvePassage(
                quote: row.quotedText, occurrence: row.occurrence, section: row.section, in: space),
            let first = resolved.instance.placements.compactMap({ $0 }).first
        else { return nil }
        return notesDocAnchorID(space.blocks[first.block].id)
    }
    let blocks = space.blocks.filter { $0.section == row.section }
    guard
        let resolved = CorrectionAnchoring.resolve(
            quote: row.quotedText, occurrence: row.occurrence, in: blocks.map(\.text))
    else { return nil }
    return notesDocAnchorID(blocks[resolved.blockIndex].id)
}

/// Keeps the built document across pane re-renders: a selection, a click or a
/// keystroke in the composer re-renders the pane, and none of them may rebuild
/// the string.
@MainActor
final class NotesDocCache {
    private var input: NotesDocInput?
    private(set) var document: NotesDocument?
    private var rowsInput: [MeetingCorrection]?
    private var rowsDocument: NotesDocument?
    private(set) var rows: [String: NotesDocRows] = [:]
    private(set) var pieces: [String: [NotesDocPieceMark]] = [:]
    /// The "Your notes" tail for the same rows and document.
    private(set) var unanchored: [MeetingCorrection] = []
    private var timecodeInput: [NotesTimecode]?
    private var timecodeDocument: NotesDocument?
    private(set) var timecodes: [String: NotesDocTimecode] = [:]

    func document(for input: NotesDocInput) -> NotesDocument {
        if let document, self.input == input { return document }
        let built = NotesDocumentBuilder.build(input)
        self.input = input
        document = built
        return built
    }

    func rows(_ correctionRows: [MeetingCorrection], for document: NotesDocument, structured: NotesStructured)
        -> [String: NotesDocRows]
    {
        if rowsInput == correctionRows, rowsDocument === document { return rows }
        (rows, pieces) = notesDocRows(correctionRows, document: document, structured: structured)
        unanchored = notesDocUnanchored(correctionRows, structured: structured, space: document.space)
        rowsInput = correctionRows
        rowsDocument = document
        return rows
    }

    func timecodes(_ rows: [NotesTimecode], for document: NotesDocument) -> [String: NotesDocTimecode] {
        if timecodeInput == rows, timecodeDocument === document { return timecodes }
        timecodes = notesDocTimecodes(rows, document: document)
        timecodeInput = rows
        timecodeDocument = document
        return timecodes
    }
}
