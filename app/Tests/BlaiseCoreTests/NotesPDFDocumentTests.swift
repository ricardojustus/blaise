import Foundation
import Testing

@testable import BlaiseCore

// SC-003 / SC-006 / SC-012: the exported HTML. The fixture markdown is produced
// by `NotesRenderer.render` — never hand-authored — and the goldens are compared
// byte for byte. Set BLAISE_REGEN_PDF_GOLDENS=1 to rewrite them after an
// intentional change.

@Suite struct NotesPDFDocumentTests {
    // MARK: - Fixtures

    private static let repoRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { url.deleteLastPathComponent() }  // file → BlaiseCoreTests → Tests → app
        return url
    }()

    private static var goldenDirectory: URL {
        repoRoot.appendingPathComponent("fixtures/pdf", isDirectory: true)
    }

    private func front() -> FrontBlock {
        FrontBlock(
            title: "Kickoff Quoll Harbor",
            dateText: "21/08/2026",
            timeText: "14:00–15:10",
            attendeesText: "Marina Solano, Dev Okafor, Tomás Ferreira",
            kicker: "Meeting notes")
    }

    /// Exercises every projection class the visitor emits.
    private func fixtureMarkdown() throws -> String {
        let detailed = """
            #### Launch window
            The closed beta opens on 20/10/2026. See [the plan](https://vexatron.test/plan) and \
            the [board](https://vexatron.test/board).

            - [x] Draft the rollout note
            - [ ] Book the load test

            ## Team shape
            Offline sync stays the central risk.
            """
        let structured = NotesStructured(
            title: "Kickoff Quoll Harbor",
            summary: "The team moved the Quoll Harbor launch window to November.",
            detailedNotes: detailed,
            decisions: ["Closed beta starts on 20/10/2026", "Budget approved without contingency"],
            actionItems: [
                ActionItem(owner: "Dev Okafor", text: "Prototype the conflict merge"),
                ActionItem(owner: "", text: "Publish the revised schedule"),
            ],
            userActionItems: [ActionItem(owner: "Marina Solano", text: "Open the QA role")])
        let annotations = [
            MeetingCorrection(
                meetingID: "01J00000000000000000000000", kind: .annotation, section: .summary,
                quotedText: "The team moved the Quoll Harbor launch window to November.",
                userText: "Confirm with the partner first", createdAt: msDate()),
            MeetingCorrection(
                meetingID: "01J00000000000000000000000", kind: .annotation, section: .summary,
                quotedText: "The team moved the Quoll Harbor launch window to November.",
                userText: "And tell the design team", createdAt: msDate()),
            MeetingCorrection(
                meetingID: "01J00000000000000000000000", kind: .annotation, section: .decision,
                quotedText: "Closed beta starts on 20/10/2026",
                userText: "Check the freeze calendar", createdAt: msDate()),
            MeetingCorrection(
                meetingID: "01J00000000000000000000000", kind: .annotation, section: .summary,
                quotedText: "a quote that no longer matches", userText: "Keep this one loose",
                createdAt: msDate()),
        ]
        return try NotesRenderer.render(
            structured, language: "en", meetingTitle: "Kickoff Quoll Harbor",
            userName: "Marina Solano", annotations: annotations)
    }

    private func hostileMarkdown() throws -> String {
        let detailed = """
            <div onclick="steal()">raw block</div>

            An <b onmouseover="x">inline</b> tag, ![alt](https://x.test/pixel.png) an image, \
            a [reference](https://x.test/a?src=leak) link, and url( in prose.
            """
        let structured = NotesStructured(
            title: "<img src=\"//x/y\">",
            summary: "Summary with <script>alert(1)</script> inside.",
            detailedNotes: detailed,
            decisions: ["Decide & move on"],
            actionItems: [ActionItem(owner: "\"><script>", text: "Escape everything")],
            userActionItems: [])
        return try NotesRenderer.render(
            structured, language: "en", meetingTitle: "t", userName: "Marina Solano")
    }

    private let toggles: [(name: String, includeSelf: Bool, includeMargin: Bool)] = [
        ("both", true, true),
        ("noself", false, true),
        ("nomargin", true, false),
        ("neither", false, false),
    ]

    // MARK: - SC-003 goldens

    @Test("every style and toggle combination matches its golden, byte for byte")
    func stylesAndTogglesMatchGoldens() throws {
        let markdown = try fixtureMarkdown()
        let regenerate = ProcessInfo.processInfo.environment["BLAISE_REGEN_PDF_GOLDENS"] == "1"
        if regenerate {
            try FileManager.default.createDirectory(
                at: Self.goldenDirectory, withIntermediateDirectories: true)
        }
        for style in PDFStyle.allCases {
            for toggle in toggles {
                let body = NotesMarkdownSections.apply(
                    markdown, includeSelf: toggle.includeSelf,
                    includeMarginNotes: toggle.includeMargin, language: "en")
                let html = try NotesPDFDocument.html(
                    markdown: body, front: front(), style: style, colophon: true, language: "en")
                let golden = Self.goldenDirectory
                    .appendingPathComponent("\(style.rawValue)-\(toggle.name).html")
                if regenerate {
                    try Data(html.utf8).write(to: golden, options: .atomic)
                    continue
                }
                let expected = try String(contentsOf: golden, encoding: .utf8)
                #expect(Array(html.utf8) == Array(expected.utf8), "\(golden.lastPathComponent)")
                // Same inputs, same bytes.
                let again = try NotesPDFDocument.html(
                    markdown: body, front: front(), style: style, colophon: true, language: "en")
                #expect(Array(again.utf8) == Array(html.utf8))
            }
        }
    }

    @Test("the projection classes the styles lay out are all present")
    func projectionClassesArePresent() throws {
        let html = try NotesPDFDocument.html(
            markdown: fixtureMarkdown(), front: front(), style: .atlas, colophon: true,
            language: "en")
        for fragment in [
            "<p class=\"lede\">", "<ol class=\"dec\">", "<ul class=\"items\">",
            "<span class=\"box\"></span>", "<span class=\"text\">", "<span class=\"who\">",
            "<section class=\"mine\">", "<aside class=\"aside\">", "<li class=\"task done\">",
            "<li class=\"task todo\">", "<span class=\"link\">", "<div class=\"colophon\">",
            "<h4>", "<h2>", "<h3>",
        ] {
            #expect(html.contains(fragment), "missing \(fragment)")
        }
        // Two consecutive asides keep their own elements.
        #expect(html.contains(
            "<aside class=\"aside\"><strong>Your note:</strong> Confirm with the partner first</aside>\n"
                + "<aside class=\"aside\"><strong>Your note:</strong> And tell the design team</aside>"))
        // The markdown H1 is the front block's job.
        #expect(!html.contains("<h1>Kickoff Quoll Harbor</h1>\n<h2>"))
        // A destination that repeats its text is not printed twice.
        #expect(html.contains("<span class=\"link\">the plan</span> (https://vexatron.test/plan)"))
        // An action item with no owner keeps the row, without the owner slot.
        #expect(html.contains(
            "<li><span class=\"box\"></span><span class=\"text\">Publish the revised schedule</span></li>"))
    }

    @Test("the colophon follows the setting and the notes language")
    func colophonFollowsSettingAndLanguage() throws {
        let markdown = try fixtureMarkdown()
        let off = try NotesPDFDocument.html(
            markdown: markdown, front: front(), style: .clean, colophon: false, language: "en")
        #expect(!off.contains("<div class=\"colophon\">"))

        let portuguese = try NotesPDFDocument.html(
            markdown: markdown, front: front(), style: .clean, colophon: true, language: "pt-BR")
        #expect(portuguese.contains("Notas geradas com <b>Blaise</b>"))
        #expect(portuguese.contains("<html lang=\"pt\">"))
        #expect(portuguese.contains("<dt>Participantes</dt>"))
    }

    // MARK: - SC-006 structural

    @Test("every element and attribute in the emitted HTML is on the allowlist")
    func structuralAllowlist() throws {
        var documents: [String] = []
        for style in PDFStyle.allCases {
            documents.append(try NotesPDFDocument.html(
                markdown: fixtureMarkdown(), front: front(), style: style, colophon: true,
                language: "en"))
            documents.append(try NotesPDFDocument.html(
                markdown: hostileMarkdown(), front: hostileFront(), style: style, colophon: true,
                language: "en"))
        }
        for html in documents {
            for tag in HTMLScan.tags(in: html) {
                #expect(HTMLScan.allowedElements.contains(tag.name), "element <\(tag.name)>")
                let allowedAttributes: Set<String>
                switch tag.name {
                case "meta": allowedAttributes = ["http-equiv", "content"]
                case "html": allowedAttributes = ["lang"]
                default: allowedAttributes = ["class"]
                }
                #expect(
                    tag.attributes.isSubset(of: allowedAttributes),
                    "<\(tag.name)> carries \(tag.attributes.subtracting(allowedAttributes))")
            }
            let style = try #require(HTMLScan.styleBlock(in: html))
            #expect(!style.contains("@import"))
            #expect(!style.contains("url("))
            #expect(html.contains(
                "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'\">"))
        }
    }

    @Test("hostile values survive only as escaped text")
    func hostileValuesAreEscaped() throws {
        let html = try NotesPDFDocument.html(
            markdown: hostileMarkdown(), front: hostileFront(), style: .ledger, colophon: true,
            language: "en")
        #expect(!html.contains("<script"))
        #expect(!html.contains("<img"))
        // Escaped text may spell an event handler; no element may carry one.
        #expect(!html.contains("onclick=\""))
        #expect(!html.contains("onmouseover=\""))
        #expect(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        #expect(html.contains("&lt;img src=&quot;//x/y&quot;&gt;"))
        #expect(html.contains("&quot;&gt;&lt;script&gt;"))
        #expect(html.contains("&lt;div onclick=&quot;steal()&quot;&gt;raw block&lt;/div&gt;"))
        #expect(html.contains("&lt;b onmouseover=&quot;x&quot;&gt;"))
        #expect(html.contains("https://x.test/a?src=leak"))
        // The image is alt text only; its source never reaches the document.
        #expect(!html.contains("pixel.png"))
        #expect(html.contains("url( in prose"))
    }

    private func hostileFront() -> FrontBlock {
        FrontBlock(
            title: "<img src=\"//x/y\">", dateText: "21/08/2026", timeText: "14:00",
            attendeesText: "\"><script>", kicker: "Meeting notes")
    }

    // MARK: - SC-013: what the alert reads

    @Test("a missing resource names itself in the error text")
    func missingResourceErrorNamesTheResource() {
        let error = NotesPDFDocumentError.missingResource("pdf/atlas.css")
        let text = error.errorDescription
        #expect(text != nil)
        #expect(text?.contains("pdf/atlas.css") == true)
        #expect(
            error.localizedDescription.contains("pdf/atlas.css"),
            "the alert and the log line read the localized text")
    }

    // MARK: - SC-012 boundaries

    @Test("the new Core files import only Foundation and Markdown")
    func newCoreFilesStayInsideTheirBoundary() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/BlaiseCore")
        let forbidden = ["NotesBlockText", "NotesEditing", "ProcessingPipeline", "NotesRenderer.render"]
        for name in [
            "NotesPDFDocument.swift", "NotesMarkdownSections.swift", "PDFExportSettings.swift",
            "NotesRendererAccessors.swift",
        ] {
            let text = try String(
                contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
            let imports = text.components(separatedBy: "\n")
                .filter { $0.hasPrefix("import ") }
                .map { String($0.dropFirst("import ".count)) }
            #expect(Set(imports).isSubset(of: ["Foundation", "Markdown"]), "\(name): \(imports)")
            for symbol in forbidden {
                #expect(!text.contains(symbol), "\(name) references \(symbol)")
            }
            #expect(!text.contains("Engine"))
        }
    }
}

/// A minimal tag scanner for the structural assertion — it reads the document
/// the way a browser's parser would see it, not the way it was built.
enum HTMLScan {
    static let allowedElements: Set<String> = [
        "html", "head", "meta", "title", "style", "body", "main", "header", "section", "div",
        "aside", "h1", "h2", "h3", "h4", "p", "ul", "ol", "li", "blockquote", "strong", "em",
        "code", "pre", "hr", "table", "thead", "tbody", "tr", "th", "td", "s", "br", "span",
        "dl", "dt", "dd", "b",
    ]

    struct Tag {
        let name: String
        let attributes: Set<String>
    }

    static func tags(in html: String) -> [Tag] {
        var result: [Tag] = []
        var rest = Substring(html)
        while let open = rest.firstIndex(of: "<") {
            rest = rest[rest.index(after: open)...]
            guard let close = rest.firstIndex(of: ">") else { break }
            var inner = rest[..<close]
            rest = rest[rest.index(after: close)...]
            if inner.first == "!" { continue }  // doctype
            if inner.first == "/" { inner = inner.dropFirst() }
            guard let first = inner.first, first.isLetter else { continue }
            let name = String(inner.prefix(while: { $0.isLetter || $0.isNumber })).lowercased()
            var attributes: Set<String> = []
            var tail = inner.dropFirst(name.count)
            while let equals = tail.firstIndex(of: "=") {
                let attribute = tail[..<equals].trimmingCharacters(in: .whitespaces)
                attributes.insert(attribute.lowercased())
                tail = tail[tail.index(after: equals)...]
                // Step over the quoted value so an `=` inside it is not read as
                // another attribute.
                guard let openQuote = tail.firstIndex(of: "\""),
                    let closeQuote = tail[tail.index(after: openQuote)...].firstIndex(of: "\"")
                else { break }
                tail = tail[tail.index(after: closeQuote)...]
            }
            result.append(Tag(name: name, attributes: attributes))
        }
        return result
    }

    static func styleBlock(in html: String) -> String? {
        guard let open = html.range(of: "<style>"), let close = html.range(of: "</style>") else {
            return nil
        }
        return String(html[open.upperBound..<close.lowerBound])
    }
}
