import Foundation
import Markdown

/// The front block of an exported PDF: the meeting's identity, above the notes.
public struct FrontBlock: Sendable, Equatable {
    public var title: String
    public var dateText: String
    public var timeText: String
    public var attendeesText: String
    public var kicker: String

    public init(
        title: String, dateText: String, timeText: String, attendeesText: String, kicker: String
    ) {
        self.title = title
        self.dateText = dateText
        self.timeText = timeText
        self.attendeesText = attendeesText
        self.kicker = kicker
    }

    /// Product conventions: DD/MM/YYYY, 24h, attendees as stored.
    public init(meeting: Meeting, language: String) {
        let portuguese = NotesRenderer.isPortuguese(language: language)
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "dd/MM/yyyy"
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")
        time.dateFormat = "HH:mm"

        var span = time.string(from: meeting.startedAt)
        if let endedAt = meeting.endedAt {
            span += "\u{2013}" + time.string(from: endedAt)
        }
        self.init(
            title: meeting.title,
            dateText: date.string(from: meeting.startedAt),
            timeText: span,
            attendeesText: meeting.attendees.map(\.name).joined(separator: ", "),
            kicker: portuguese ? "Notas da reunião" : "Meeting notes")
    }
}

public enum NotesPDFDocumentError: Error, Equatable, LocalizedError {
    /// A template or stylesheet is missing from the resource bundle.
    case missingResource(String)

    public var errorDescription: String? {
        switch self {
        case .missingResource(let name):
            return "The PDF template \u{201C}\(name)\u{201D} is missing from the app."
        }
    }
}

/// The stored notes markdown as a self-contained HTML document: a real parse
/// tree, every value escaped, one stylesheet inlined, no external reference of
/// any kind. Pure — same inputs, byte-identical output.
public enum NotesPDFDocument {
    public static func html(
        markdown: String, front: FrontBlock, style: PDFStyle, colophon: Bool, language: String
    ) throws -> String {
        let sections = NotesMarkdownSections.classify(markdown, language: language)
        // Section kinds keyed by the heading's 1-based source line, so the
        // parse tree and the classifier agree on which section a block is in.
        var kindByLine: [Int: NotesMarkdownSections.Kind] = [:]
        for section in sections { kindByLine[section.headingLine + 1] = section.kind }

        var visitor = HTMLVisitor(
            kindByLine: kindByLine,
            yourNoteLabel: NotesRenderer.yourNoteLabel(language: language))
        let document = Document(parsing: markdown, options: [.disableSmartOpts])
        let portuguese = NotesRenderer.isPortuguese(language: language)

        // The stylesheets declare `@page{size:A4}` so this document renders on
        // its own; the exporter rewrites the size for Letter.
        return fill(
            try resource("template", "html"),
            with: [
                "lang": portuguese ? "pt" : "en",
                "title": escape(front.title),
                "css": try resource(style.rawValue, "css"),
                "front": frontHTML(front, portuguese: portuguese),
                "body": visitor.body(of: document),
                "colophon": colophon ? colophonHTML(portuguese: portuguese) : "",
            ])
    }

    // MARK: - Fixed blocks

    private static func frontHTML(_ front: FrontBlock, portuguese: Bool) -> String {
        """
        <header class="front">
        <div class="kicker">\(escape(front.kicker))</div>
        <h1>\(escape(front.title))</h1>
        <dl class="meta">
        <dt>\(portuguese ? "Data" : "Date")</dt><dd>\(escape(front.dateText))</dd>
        <dt>\(portuguese ? "Horário" : "Time")</dt><dd>\(escape(front.timeText))</dd>
        <dt>\(portuguese ? "Participantes" : "Attendees")</dt><dd>\(escape(front.attendeesText))</dd>
        </dl>
        </header>
        """
    }

    private static func colophonHTML(portuguese: Bool) -> String {
        let text = portuguese ? "Notas geradas com " : "Made with "
        return "<div class=\"colophon\"><span class=\"mark\"></span>\(text)<b>Blaise</b></div>"
    }

    // MARK: - Template

    private static func resource(_ name: String, _ ext: String) throws -> String {
        guard
            let url = BlaiseResources.bundle.url(
                forResource: name, withExtension: ext, subdirectory: "pdf"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            throw NotesPDFDocumentError.missingResource("pdf/\(name).\(ext)")
        }
        return text
    }

    /// Single-pass `{{name}}` substitution — a value can never be rescanned for
    /// another placeholder.
    private static func fill(_ template: String, with values: [String: String]) -> String {
        var result = ""
        var rest = Substring(template)
        while let open = rest.range(of: "{{"), let close = rest[open.upperBound...].range(of: "}}") {
            let name = String(rest[open.upperBound..<close.lowerBound])
            result += rest[..<open.lowerBound]
            result += values[name] ?? ""
            rest = rest[close.upperBound...]
        }
        return result + rest
    }
}

/// The one escape primitive: every dynamic value in the document goes through
/// it, so escaped text may carry any bytes.
func escape(_ text: String) -> String {
    var out = ""
    out.reserveCapacity(text.count)
    for character in text {
        switch character {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        case "'": out += "&#39;"
        default: out.append(character)
        }
    }
    return out
}

/// Deny-by-default markdown → HTML: a fixed element allowlist, `class` the only
/// attribute, no URL ever emitted.
private struct HTMLVisitor: MarkupVisitor {
    typealias Result = String

    let kindByLine: [Int: NotesMarkdownSections.Kind]
    let yourNoteLabel: String

    private var section: NotesMarkdownSections.Kind = .other
    private var ledeOwed = false
    private var inActionItems = false
    private var inTableHead = false

    init(kindByLine: [Int: NotesMarkdownSections.Kind], yourNoteLabel: String) {
        self.kindByLine = kindByLine
        self.yourNoteLabel = yourNoteLabel
    }

    /// The notes body: top-level blocks in order, with the self section wrapped.
    mutating func body(of document: Document) -> String {
        var blocks: [String] = []
        var mineOpen = false
        for child in document.children {
            if let heading = child as? Heading, heading.level == 2 {
                let kind = kindByLine[heading.range?.lowerBound.line ?? -1] ?? .other
                if mineOpen {
                    blocks.append("</section>")
                    mineOpen = false
                }
                section = kind
                ledeOwed = kind == .summary
                if kind == .selfActionItems {
                    blocks.append("<section class=\"mine\">")
                    mineOpen = true
                }
            }
            let html = visit(child)
            if !html.isEmpty { blocks.append(html) }
        }
        if mineOpen { blocks.append("</section>") }
        return blocks.joined(separator: "\n")
    }

    // MARK: - Blocks

    mutating func defaultVisit(_ markup: Markup) -> String {
        markup.children.map { visit($0) }.joined()
    }

    mutating func visitHeading(_ heading: Heading) -> String {
        // The front block owns the title.
        guard heading.level > 1 else { return "" }
        let tag = heading.level == 2 ? "h2" : (heading.level == 3 ? "h3" : "h4")
        return "<\(tag)>\(inline(heading))</\(tag)>"
    }

    mutating func visitParagraph(_ paragraph: Paragraph) -> String {
        if ledeOwed, paragraph.parent is Document {
            ledeOwed = false
            return "<p class=\"lede\">\(inline(paragraph))</p>"
        }
        return "<p>\(inline(paragraph))</p>"
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> String {
        if isAside(blockQuote) {
            return "<aside class=\"aside\">\(tight(blockQuote))</aside>"
        }
        return "<blockquote>\(blockQuote.children.map { visit($0) }.joined())</blockquote>"
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) -> String {
        list(unorderedList, tag: "ul")
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) -> String {
        list(orderedList, tag: "ol")
    }

    private mutating func list(_ list: Markup, tag: String) -> String {
        let projected = list.parent is Document
        if projected, section == .decisions {
            return wrap("ol", "dec", items(of: list))
        }
        if projected, section == .actionItems || section == .selfActionItems {
            inActionItems = true
            let body = items(of: list)
            inActionItems = false
            return wrap("ul", "items", body)
        }
        return "<\(tag)>\n\(items(of: list))\n</\(tag)>"
    }

    private mutating func items(of list: Markup) -> String {
        list.children.map { visit($0) }.joined(separator: "\n")
    }

    private func wrap(_ tag: String, _ className: String, _ body: String) -> String {
        "<\(tag) class=\"\(className)\">\n\(body)\n</\(tag)>"
    }

    mutating func visitListItem(_ listItem: ListItem) -> String {
        if inActionItems { return actionItem(listItem) }
        let body = tight(listItem)
        guard let checkbox = listItem.checkbox else { return "<li>\(body)</li>" }
        let done = checkbox == .checked
        return "<li class=\"task \(done ? "done" : "todo")\">\(done ? "☑" : "☐") \(body)</li>"
    }

    /// `- **Owner:** text` becomes the checkbox row the styles lay out; an item
    /// with no bold owner keeps the same shape without the owner slot.
    private mutating func actionItem(_ listItem: ListItem) -> String {
        var owner: String?
        var body = ""
        for (index, child) in listItem.children.enumerated() {
            guard index == 0, let paragraph = child as? Paragraph else {
                body += visit(child)
                continue
            }
            var inlines = Array(paragraph.children)
            if let strong = inlines.first as? Strong, strong.plainText.hasSuffix(":") {
                owner = String(strong.plainText.dropLast())
                inlines.removeFirst()
            }
            body += inlines.map { visit($0) }.joined()
        }
        while body.first == " " { body.removeFirst() }
        let who = owner.map { "<span class=\"who\">\(escape($0))</span>" } ?? ""
        return "<li><span class=\"box\"></span><span class=\"text\">\(body)</span>\(who)</li>"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> String {
        "<pre>\(escape(codeBlock.code))</pre>"
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> String {
        "<hr>"
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) -> String {
        escape(html.rawHTML)
    }

    // MARK: - Tables

    mutating func visitTable(_ table: Table) -> String {
        "<table>\(table.children.map { visit($0) }.joined())</table>"
    }

    mutating func visitTableHead(_ tableHead: Table.Head) -> String {
        inTableHead = true
        let row = tableHead.children.map { visit($0) }.joined()
        inTableHead = false
        return "<thead><tr>\(row)</tr></thead>"
    }

    mutating func visitTableBody(_ tableBody: Table.Body) -> String {
        "<tbody>\(tableBody.children.map { visit($0) }.joined())</tbody>"
    }

    mutating func visitTableRow(_ tableRow: Table.Row) -> String {
        "<tr>\(tableRow.children.map { visit($0) }.joined())</tr>"
    }

    mutating func visitTableCell(_ tableCell: Table.Cell) -> String {
        let tag = inTableHead ? "th" : "td"
        return "<\(tag)>\(inline(tableCell))</\(tag)>"
    }

    // MARK: - Inlines

    mutating func visitText(_ text: Text) -> String {
        escape(text.string)
    }

    mutating func visitStrong(_ strong: Strong) -> String {
        "<strong>\(inline(strong))</strong>"
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) -> String {
        "<em>\(inline(emphasis))</em>"
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) -> String {
        "<s>\(inline(strikethrough))</s>"
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> String {
        "<code>\(escape(inlineCode.code))</code>"
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) -> String {
        escape(inlineHTML.rawHTML)
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> String {
        " "
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) -> String {
        "<br>"
    }

    /// The destination is never an attribute: it appears as escaped text, and
    /// only when it says something the link text does not.
    mutating func visitLink(_ link: Link) -> String {
        let text = inline(link)
        let span = "<span class=\"link\">\(text)</span>"
        guard let destination = link.destination, destination != link.plainText else { return span }
        return span + " (" + escape(destination) + ")"
    }

    mutating func visitImage(_ image: Image) -> String {
        escape(image.plainText)
    }

    // MARK: - Helpers

    private mutating func inline(_ markup: Markup) -> String {
        markup.children.map { visit($0) }.joined()
    }

    /// A container rendered without paragraph wrappers (list items, asides).
    private mutating func tight(_ markup: Markup) -> String {
        markup.children.map { child in
            child is Paragraph ? inline(child) : visit(child)
        }.joined(separator: "\n")
    }

    /// The renderer's own margin-note shape: a blockquote opening with the bold
    /// note label. A blockquote that merely begins with the label reads as one.
    private func isAside(_ blockQuote: BlockQuote) -> Bool {
        guard let paragraph = blockQuote.child(at: 0) as? Paragraph,
            let strong = paragraph.child(at: 0) as? Strong
        else { return false }
        return strong.plainText.hasPrefix(yourNoteLabel)
    }
}
