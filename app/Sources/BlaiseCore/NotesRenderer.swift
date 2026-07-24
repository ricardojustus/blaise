import Foundation

/// Renders the human markdown document from `NotesStructured` — pure and
/// deterministic (same inputs → byte-identical output). Engines never return
/// markdown; consistency between markdown and structured holds by
/// construction (C7 stores both).
///
/// ALL engine strings are treated as untrusted markdown: no engine string
/// can introduce an H1/H2 or impersonate a section heading.
public enum NotesRenderer {
    /// Travels in `NotesProvenance.rendererVersion` — the markdown artifact
    /// depends on it (D5 parity).
    ///
    /// G3 bumped "1" → "2": the user action-items section title is now
    /// name-driven ("Ações do the user" → "Ações de <name>", plus the unnamed
    /// "My action items"/"Minhas ações" variants), so the SAME
    /// `(structured, language, meetingTitle)` renders different bytes than a
    /// pre-G3 renderer. The identity name those bytes depend on is captured
    /// separately in `NotesProvenance.userName`.
    public static let version = "2"

    /// - Parameters:
    ///   - language: BCP-47; prefix match `pt*` → Portuguese headings,
    ///     anything else → English (B-1: notes in the dominant language; the
    ///     user's action-items section is always rendered, same language).
    ///   - meetingTitle: H1 fallback when `s.title` is nil/blank.
    ///   - userName: drives the user action-items section title
    ///     (`<name> — Action Items` / `Ações de <name>`). Empty (pre-onboarding
    ///     identity) → the neutral "My action items" / "Minhas ações" (G3).
    /// - Throws: `EngineError.invalidStructuredNotes` if `summary` is
    ///   empty/whitespace (refusal, not rendering — anti-hallucination).
    ///
    /// G17 `annotations`: the meeting's user margin notes, woven in
    /// deterministically — an anchored note renders as a blockquote aside by
    /// its matched block; an unanchored note lands under a final "Your notes"
    /// heading with its original anchor quote (never silently dropped). HARD
    /// presence gate: no annotation rows → byte-identical pre-G17 output.
    public static func render(
        _ s: NotesStructured, language: String, meetingTitle: String, userName: String = "",
        annotations: [MeetingCorrection] = []
    ) throws -> String {
        let strings = LocalizedStrings.match(language, userName: userName)

        let summary = s.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else {
            throw EngineError.invalidStructuredNotes("summary is empty")
        }

        // Title is flattened FIRST; a title that flattens to nothing (e.g.
        // only "#" characters) falls back to meetingTitle (impl audit M3).
        var titleLine = s.title.map(flattenToTitleLine) ?? ""
        if titleLine.isEmpty {
            titleLine = flattenToTitleLine(meetingTitle)
        }

        let detailedNotes = s.detailedNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let weave = AnnotationWeave.plan(annotations: annotations, structured: s)

        var blocks: [String] = []
        blocks.append("# \(titleLine)")
        blocks.append("## \(strings.summary)")
        blocks.append(demoteHeadings(in: summary))
        blocks.append(contentsOf: weave.summaryAsides.map { aside($0, strings: strings) })
        blocks.append("## \(strings.detailedNotes)")
        if weave.detailedAsides.isEmpty {
            blocks.append(detailedNotes.isEmpty ? strings.noneMarker : demoteHeadings(in: detailedNotes))
        } else if containsCode(detailedNotes) {
            // FIX B: the per-paragraph path splits on blank lines, but a
            // fenced code block that spans a blank line is split mid-fence and
            // `demoteHeadings` force-closes it per fragment — corrupting the
            // block. When this section has anchored asides AND a fence, render
            // the whole blob once (fence intact) and append the asides after
            // it in the quoted form (they can no longer sit under their exact
            // paragraph, so the quote names the anchor). Deterministic order:
            // by block index, then row order within a block.
            blocks.append(demoteHeadings(in: detailedNotes))
            for entry in weave.detailedAsides.sorted(by: { $0.key < $1.key }).flatMap(\.value) {
                blocks.append(aside(entry.text, on: entry.quote, strings: strings))
            }
        } else {
            // Per-paragraph render so each aside lands under its anchor. The
            // paragraph split mirrors `CorrectionAnchoring.blocks`; demoting
            // per paragraph is equivalent for fence-free prose (the fenced
            // case is handled above).
            let paragraphs = CorrectionAnchoring.blocks(of: s, section: .detailedNotes)
            for (index, paragraph) in paragraphs.enumerated() {
                blocks.append(demoteHeadings(in: paragraph))
                for entry in weave.detailedAsides[index] ?? [] {
                    blocks.append(aside(entry.text, strings: strings))
                }
            }
            if paragraphs.isEmpty {
                blocks.append(strings.noneMarker)
            }
        }
        blocks.append("## \(strings.decisions)")
        blocks.append(renderList(s.decisions.map { "- \(normalizeListText($0))" }, emptyMarker: strings.noneMarker))
        blocks.append(contentsOf: weave.decisionAsides.map { aside($0.text, on: $0.quote, strings: strings) })
        blocks.append("## \(strings.actionItems)")
        blocks.append(renderList(
            s.actionItems.filter { !normalizeListText($0.text).isEmpty }.map(renderActionItem),
            emptyMarker: strings.noneMarker))
        blocks.append(contentsOf: weave.actionAsides.map { aside($0.text, on: $0.quote, strings: strings) })
        blocks.append("## \(strings.userActionItems)")
        blocks.append(renderList(
            s.userActionItems.filter { !normalizeListText($0.text).isEmpty }.map(renderActionItem),
            emptyMarker: strings.userNoneMarker))
        if !weave.unanchored.isEmpty {
            blocks.append("## \(strings.yourNotes)")
            blocks.append(weave.unanchored.map { note in
                "- \(CorrectionSanitize.flatten(note.text)) *(\(strings.wasOn) \u{201C}\(anchorQuote(note.quote))\u{201D})*"
            }.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    // MARK: - G17 annotation weaving

    /// Where each annotation lands: an aside under its anchor, or the tail
    /// "Your notes" list. Pure and order-preserving (row order = display
    /// order within each bucket).
    struct AnnotationWeave {
        var summaryAsides: [String] = []
        // FIX B: detailed asides carry their anchor quote as well as the text.
        // The per-paragraph path renders the text under its paragraph (quote
        // redundant there); the fenced-blob path renders the quoted form after
        // the whole blob, where adjacency no longer names the anchor.
        var detailedAsides: [Int: [(quote: String, text: String)]] = [:]
        var decisionAsides: [(quote: String, text: String)] = []
        var actionAsides: [(quote: String, text: String)] = []
        var unanchored: [(quote: String, text: String)] = []

        static func plan(annotations: [MeetingCorrection], structured: NotesStructured) -> AnnotationWeave {
            var weave = AnnotationWeave()
            for row in annotations where row.kind == .annotation {
                let blocks = CorrectionAnchoring.blocks(of: structured, section: row.section)
                guard
                    let hit = CorrectionAnchoring.resolve(
                        quote: row.quotedText, occurrence: row.occurrence, in: blocks)
                else {
                    weave.unanchored.append((row.quotedText, row.userText))
                    continue
                }
                switch row.section {
                case .summary:
                    weave.summaryAsides.append(row.userText)
                case .detailedNotes:
                    weave.detailedAsides[hit.blockIndex, default: []]
                        .append((blocks[hit.blockIndex], row.userText))
                case .decision:
                    weave.decisionAsides.append((blocks[hit.blockIndex], row.userText))
                case .actionItem:
                    weave.actionAsides.append((blocks[hit.blockIndex], row.userText))
                }
            }
            return weave
        }
    }

    /// FIX B/L: whether the raw detailed-notes blob carries code that the
    /// per-paragraph aside weaving would corrupt. Two shapes qualify:
    ///
    /// - A FENCE (``` / ~~~), which the paragraph split can cut in half — each
    ///   fragment then gets its own force-closed fence from `demoteHeadings`.
    /// - An INDENTED code block (4+ spaces or a tab), which the paragraph
    ///   split destroys more quietly: the split TRIMS each paragraph, so the
    ///   leading indent that made it code is simply gone and the lines
    ///   re-render as prose.
    ///
    /// Either sends the section down the whole-blob path, where the text is
    /// rendered once, intact, with the asides appended in quoted form.
    private static func containsCode(_ body: String) -> Bool {
        if body.contains("```") || body.contains("~~~") { return true }
        return body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .contains { paragraph in
                guard let first = paragraph.split(separator: "\n", omittingEmptySubsequences: false)
                    .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
                else { return false }
                return first.hasPrefix("    ") || first.hasPrefix("\t")
            }
    }

    /// A note aside: one blockquote paragraph. The note body flattens to one
    /// line (a multi-line note must not escape the blockquote) through the
    /// correction fold, which keeps a `#`-only note's body (FIX H).
    private static func aside(_ text: String, strings: LocalizedStrings) -> String {
        "> **\(strings.yourNote):** \(CorrectionSanitize.flatten(text))"
    }

    /// A list-adjacent aside names its anchor (the aside sits after the list,
    /// so adjacency alone cannot associate it).
    private static func aside(_ text: String, on quote: String, strings: LocalizedStrings) -> String {
        "> **\(strings.yourNote)** (\(strings.wasOn) \u{201C}\(anchorQuote(quote))\u{201D}): \(CorrectionSanitize.flatten(text))"
    }

    /// Anchor quotes render flattened and bounded (a full paragraph quote
    /// would swallow the document).
    private static func anchorQuote(_ quote: String) -> String {
        let flat = CorrectionSanitize.flatten(quote)
        guard flat.count > 60 else { return flat }
        return flat.prefix(59).trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: - Localization (BCP-47 primary-subtag match)

    struct LocalizedStrings {
        let summary: String
        let detailedNotes: String
        let decisions: String
        let actionItems: String
        let userActionItems: String
        /// anti-hallucination pattern: an empty section is stated, not invented.
        let noneMarker: String
        let userNoneMarker: String
        /// G17: the anchored-aside tag, the unanchored tail heading, and the
        /// anchor-quote intro ("on" / "sobre").
        let yourNote: String
        let yourNotes: String
        let wasOn: String

        /// G3 name-driven: `userName` empty → neutral "My action items" /
        /// "Minhas ações"; otherwise `<name>'s action items` (EN) / "Ações de
        /// <name>" (PT). The empty-section marker follows the same name.
        static func english(userName: String) -> LocalizedStrings {
            let name = userName.trimmingCharacters(in: .whitespacesAndNewlines)
            return LocalizedStrings(
                summary: "Summary",
                detailedNotes: "Detailed notes",
                decisions: "Decisions",
                actionItems: "Action items",
                userActionItems: name.isEmpty ? "My action items" : "\(name)'s action items",
                noneMarker: "None noted.",
                userNoneMarker: name.isEmpty ? "No action items for me." : "No action items for \(name).",
                yourNote: "Your note",
                yourNotes: "Your notes",
                wasOn: "on"
            )
        }

        static func portuguese(userName: String) -> LocalizedStrings {
            let name = userName.trimmingCharacters(in: .whitespacesAndNewlines)
            return LocalizedStrings(
                summary: "Resumo",
                detailedNotes: "Notas detalhadas",
                decisions: "Decisões",
                actionItems: "Itens de ação",
                userActionItems: name.isEmpty ? "Minhas ações" : "Ações de \(name)",
                noneMarker: "Nada registrado.",
                userNoneMarker: name.isEmpty ? "Nenhuma ação para mim." : "Nenhuma ação para \(name).",
                yourNote: "Sua nota",
                yourNotes: "Suas notas",
                wasOn: "sobre"
            )
        }

        static func match(_ language: String, userName: String) -> LocalizedStrings {
            let primary = language.split(separator: "-").first.map(String.init) ?? language
            return primary.lowercased() == "pt"
                ? .portuguese(userName: userName) : .english(userName: userName)
        }
    }

    // MARK: - Normalization of untrusted engine strings

    /// Title/meetingTitle → single line: newlines become spaces, leading `#`
    /// run stripped, surrounding whitespace trimmed.
    ///
    /// FIX H: deliberately NOT widened to the other Unicode line separators.
    /// This function owns TITLE bytes for every meeting, including the ones
    /// with no corrections at all — widening it moved the rendered output of
    /// a pre-G17 title containing U+2028. User correction text has its own
    /// fold (`CorrectionSanitize.flatten`), which is where that hardening
    /// belongs.
    static func flattenToTitleLine(_ raw: String) -> String {
        var line = raw
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
        while line.hasPrefix("#") {
            line.removeFirst()
        }
        return line.trimmingCharacters(in: .whitespaces)
    }

    /// Demotes headings so none outranks H3, fence-aware (impl audit H1/M1/M2):
    /// - ATX (`#`/`##` …): rewritten to `###`.
    /// - Setext (text line + `===`/`---` underline): the text line becomes an
    ///   H3 and the underline is dropped.
    /// - Lines inside fenced code blocks (``` / ~~~) are never touched.
    /// - An unclosed fence is closed at the end of the body so engine output
    ///   cannot swallow subsequent section headings into a code block.
    static func demoteHeadings(in body: String) -> String {
        // CRLF/CR normalize first: every rule below is line-based and a
        // trailing \r must not hide an underline or marker (verify N2).
        let normalized = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var result: [String] = []
        var openFence: String? = nil
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if let open = openFence {
                result.append(line) // verbatim inside code block
                if isClosingFence(line, for: open) {
                    openFence = nil
                }
                index += 1
                continue
            }
            if let delimiter = openingFenceDelimiter(of: line) {
                openFence = delimiter
                result.append(line)
                index += 1
                continue
            }
            // Setext: a paragraph line followed by an `===`/`---` underline
            // forms an H1/H2 — demote to ATX H3. Only a PARAGRAPH line can
            // host a setext heading (not list items, blockquotes, headings —
            // there `---` is a thematic break; verify N5).
            if index + 1 < lines.count,
               isParagraphLine(line),
               isSetextUnderline(lines[index + 1]) {
                result.append("### " + line.trimmingCharacters(in: .whitespaces))
                index += 2 // drop the underline
                continue
            }
            result.append(demoteHeadingLine(line))
            index += 1
        }
        if let open = openFence {
            result.append(open) // close an unclosed fence with ITS OWN delimiter (verify N4)
        }
        return result.joined(separator: "\n")
    }

    /// CommonMark opening fence: ≤3 spaces indent, 3+ of ` or ~; a BACKTICK
    /// fence's info string may not contain a backtick (verify N1).
    private static func openingFenceDelimiter(of line: String) -> String? {
        let indent = line.prefix(while: { $0 == " " })
        guard indent.count <= 3 else { return nil }
        let afterIndent = line.dropFirst(indent.count)
        for fenceChar: Character in ["`", "~"] {
            let run = afterIndent.prefix(while: { $0 == fenceChar })
            if run.count >= 3 {
                let info = afterIndent.dropFirst(run.count)
                if fenceChar == "`" && info.contains("`") { return nil }
                return String(run)
            }
        }
        return nil
    }

    /// CommonMark closing fence: same char, ≥ opening length, nothing but
    /// spaces/tabs after (verify N3).
    private static func isClosingFence(_ line: String, for open: String) -> Bool {
        guard let fenceChar = open.first else { return false }
        let indent = line.prefix(while: { $0 == " " })
        guard indent.count <= 3 else { return false }
        let afterIndent = line.dropFirst(indent.count)
        let run = afterIndent.prefix(while: { $0 == fenceChar })
        guard run.count >= open.count else { return false }
        return afterIndent.dropFirst(run.count).allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// A line that can host a setext heading: non-blank, not an ATX heading,
    /// not a fence, not a list item / blockquote / thematic-break-ish line.
    private static func isParagraphLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        guard atxHeadingLevel(of: line) == nil, openingFenceDelimiter(of: line) == nil else { return false }
        if let first = trimmed.first {
            if first == ">" { return false }
            if (first == "-" || first == "*" || first == "+"),
               trimmed.count == 1 || trimmed.dropFirst().first == " " { return false }
            if first.isASCII && first.isNumber {
                // CommonMark ordered-list marker: 1–9 ASCII digits + . or )
                // (an uncapped/non-ASCII run is a paragraph and CAN host a
                // setext heading — verify N7).
                let digits = trimmed.prefix(while: { $0.isASCII && $0.isNumber })
                let rest = trimmed.dropFirst(digits.count)
                if digits.count <= 9,
                   let punct = rest.first, punct == "." || punct == ")",
                   rest.count == 1 || rest.dropFirst().first == " " { return false }
            }
        }
        return true
    }

    /// CommonMark setext underline: only `=` or only `-` (1+), ≤3 spaces indent.
    private static func isSetextUnderline(_ line: String) -> Bool {
        let indent = line.prefix(while: { $0 == " " })
        guard indent.count <= 3 else { return false }
        let body = line.dropFirst(indent.count).trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return false }
        return body.allSatisfy { $0 == "=" } || body.allSatisfy { $0 == "-" }
    }

    /// ATX heading level (1–6) of a line, or nil.
    private static func atxHeadingLevel(of line: String) -> Int? {
        let indent = line.prefix(while: { $0 == " " })
        guard indent.count <= 3 else { return nil }
        let afterIndent = line.dropFirst(indent.count)
        let hashes = afterIndent.prefix(while: { $0 == "#" })
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = afterIndent.dropFirst(hashes.count)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        return hashes.count
    }

    private static func demoteHeadingLine(_ line: String) -> String {
        let indent = line.prefix(while: { $0 == " " })
        guard indent.count <= 3 else { return line } // 4+ spaces = code block
        let afterIndent = line.dropFirst(indent.count)
        let hashes = afterIndent.prefix(while: { $0 == "#" })
        guard (1...2).contains(hashes.count) else { return line } // H3+ already fine; 7+ # is not a heading
        let rest = afterIndent.dropFirst(hashes.count)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return line } // "#hashtag" is not a heading
        return "###" + rest
    }

    /// List-item strings (decisions, ActionItem owner/text): internal
    /// newlines collapse to spaces; leading markdown structure tokens
    /// (heading `#` runs, list markers `-`/`*`/`+`, ordered markers `1.`/`1)`,
    /// blockquote `>`) are stripped repeatedly.
    static func normalizeListText(_ raw: String) -> String {
        let oneLine = raw
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        var text = Substring(oneLine)
        while true {
            let before = text
            text = text.drop(while: { $0 == " " || $0 == "\t" })
            if let first = text.first {
                if first == ">" {
                    text = text.dropFirst()
                } else if first == "#" {
                    let run = text.prefix(while: { $0 == "#" })
                    if isMarkerBoundary(text.dropFirst(run.count)) { text = text.dropFirst(run.count) }
                } else if first == "-" || first == "*" || first == "+" {
                    if isMarkerBoundary(text.dropFirst()) { text = text.dropFirst() }
                } else if first.isWholeNumber {
                    let digits = text.prefix(while: { $0.isWholeNumber })
                    let afterDigits = text.dropFirst(digits.count)
                    if let punct = afterDigits.first, punct == "." || punct == ")",
                       isMarkerBoundary(afterDigits.dropFirst()) {
                        text = afterDigits.dropFirst()
                    }
                }
            }
            if text == before { break }
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// A structure marker only counts when followed by whitespace or
    /// end-of-string ("1.5x" and "#hashtag" stay intact).
    private static func isMarkerBoundary(_ rest: Substring) -> Bool {
        rest.isEmpty || rest.first == " " || rest.first == "\t"
    }

    private static func renderActionItem(_ item: ActionItem) -> String {
        let owner = normalizeListText(item.owner)
        let text = normalizeListText(item.text)
        // No owner (e.g. an unresolved speaker) → drop the prefix rather than
        // emit an empty "**:**".
        return owner.isEmpty ? "- \(text)" : "- **\(owner):** \(text)"
    }

    private static func renderList(_ lines: [String], emptyMarker: String) -> String {
        lines.isEmpty ? emptyMarker : lines.joined(separator: "\n")
    }
}
