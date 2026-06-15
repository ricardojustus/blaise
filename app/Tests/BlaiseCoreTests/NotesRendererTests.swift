import Foundation
import Testing
@testable import BlaiseCore

@Suite struct NotesRendererTests {
    private func fullStructured() -> NotesStructured {
        NotesStructured(
            title: "Weekly sync",
            summary: "We agreed on the launch plan.",
            detailedNotes: "The team reviewed the budget.",
            decisions: ["Ship on 21 March 2026"],
            actionItems: [ActionItem(owner: "Anna", text: "Send the deck")],
            userActionItems: [ActionItem(owner: "Sam", text: "Reply to Ed")]
        )
    }

    @Test func goldenEnglishDocumentIsByteIdentical() throws {
        let expected = """
        # Weekly sync

        ## Summary

        We agreed on the launch plan.

        ## Detailed notes

        The team reviewed the budget.

        ## Decisions

        - Ship on 21 March 2026

        ## Action items

        - **Anna:** Send the deck

        ## Sam's action items

        - **Sam:** Reply to Ed

        """
        let rendered = try NotesRenderer.render(
            fullStructured(), language: "en-US", meetingTitle: "fallback", userName: "Sam")
        #expect(rendered == expected)
        // Deterministic: same inputs → byte-identical output.
        #expect(
            try NotesRenderer.render(
                fullStructured(), language: "en-US", meetingTitle: "fallback", userName: "Sam")
                == rendered)
    }

    @Test func goldenEnglishUnnamedUsesNeutralSectionTitle() throws {
        // G3 AC3: an empty (pre-onboarding) identity renders the neutral
        // "My action items" title and marker.
        let rendered = try NotesRenderer.render(
            fullStructured(), language: "en-US", meetingTitle: "fallback", userName: "")
        #expect(rendered.contains("## My action items\n\n- **Sam:** Reply to Ed"))
        #expect(!rendered.contains("Sam's action items"))
    }

    @Test func goldenPortugueseDocumentIsByteIdentical() throws {
        let structured = NotesStructured(
            title: "Alinhamento semanal",
            summary: "Alinhamos o plano de lançamento.",
            detailedNotes: "O time revisou o orçamento de R$ 1.000,00.",
            decisions: ["Lançar em 21 de março de 2026"],
            actionItems: [ActionItem(owner: "Anna", text: "Enviar a apresentação")],
            userActionItems: [ActionItem(owner: "Sam", text: "Responder ao Ed")]
        )
        let expected = """
        # Alinhamento semanal

        ## Resumo

        Alinhamos o plano de lançamento.

        ## Notas detalhadas

        O time revisou o orçamento de R$ 1.000,00.

        ## Decisões

        - Lançar em 21 de março de 2026

        ## Itens de ação

        - **Anna:** Enviar a apresentação

        ## Ações de Sam

        - **Sam:** Responder ao Ed

        """
        let rendered = try NotesRenderer.render(
            structured, language: "pt-BR", meetingTitle: "fallback", userName: "Sam")
        #expect(rendered == expected)
        #expect(
            try NotesRenderer.render(
                structured, language: "pt-BR", meetingTitle: "fallback", userName: "Sam") == rendered)
    }

    @Test func goldenPortugueseUnnamedUsesNeutralSectionTitle() throws {
        // G3 AC3: empty identity → "Minhas ações".
        let structured = NotesStructured(
            title: "Alinhamento semanal", summary: "Alinhamos o plano de lançamento.",
            detailedNotes: "O time revisou o orçamento de R$ 1.000,00.",
            decisions: ["Lançar em 21 de março de 2026"],
            actionItems: [ActionItem(owner: "Anna", text: "Enviar a apresentação")],
            userActionItems: [ActionItem(owner: "Sam", text: "Responder ao Ed")]
        )
        let rendered = try NotesRenderer.render(
            structured, language: "pt-BR", meetingTitle: "fallback", userName: "")
        #expect(rendered.contains("## Minhas ações\n\n- **Sam:** Responder ao Ed"))
        #expect(!rendered.contains("Ações de"))
    }

    @Test func languageMatchIsBCP47PrefixBased() throws {
        let s = fullStructured()
        #expect(try NotesRenderer.render(s, language: "pt", meetingTitle: "t").contains("## Resumo"))
        #expect(try NotesRenderer.render(s, language: "pt-PT", meetingTitle: "t").contains("## Resumo"))
        #expect(try NotesRenderer.render(s, language: "PT-BR", meetingTitle: "t").contains("## Resumo"))
        // Anything else → English.
        #expect(try NotesRenderer.render(s, language: "es-ES", meetingTitle: "t").contains("## Summary"))
        #expect(try NotesRenderer.render(s, language: "", meetingTitle: "t").contains("## Summary"))
    }

    @Test func emptySectionsRenderLocalizedMarkersAndUserSectionIsAlwaysPresent() throws {
        let structured = NotesStructured(
            title: "Quick chat",
            summary: "Nothing was decided.",
            detailedNotes: "",
            decisions: [],
            actionItems: [],
            userActionItems: []
        )
        let en = try NotesRenderer.render(
            structured, language: "en", meetingTitle: "fallback", userName: "Sam")
        #expect(en.contains("## Detailed notes\n\nNone noted."))
        #expect(en.contains("## Decisions\n\nNone noted."))
        #expect(en.contains("## Action items\n\nNone noted."))
        #expect(en.contains("## Sam's action items\n\nNo action items for Sam."))

        let pt = try NotesRenderer.render(
            structured, language: "pt-BR", meetingTitle: "fallback", userName: "Sam")
        #expect(pt.contains("## Notas detalhadas\n\nNada registrado."))
        #expect(pt.contains("## Decisões\n\nNada registrado."))
        #expect(pt.contains("## Itens de ação\n\nNada registrado."))
        #expect(pt.contains("## Ações de Sam\n\nNenhuma ação para Sam."))

        // Unnamed (pre-onboarding): neutral title + neutral empty marker.
        let enUnnamed = try NotesRenderer.render(
            structured, language: "en", meetingTitle: "fallback", userName: "")
        #expect(enUnnamed.contains("## My action items\n\nNo action items for me."))
        let ptUnnamed = try NotesRenderer.render(
            structured, language: "pt-BR", meetingTitle: "fallback", userName: "")
        #expect(ptUnnamed.contains("## Minhas ações\n\nNenhuma ação para mim."))
    }

    @Test func emptySummaryIsRefusedNotRendered() {
        var structured = fullStructured()
        structured.summary = "  \n\t "
        #expect(throws: EngineError.invalidStructuredNotes("summary is empty")) {
            try NotesRenderer.render(structured, language: "en", meetingTitle: "t")
        }
    }

    @Test func hostileTitleIsFlattenedToSingleLineH1() throws {
        var structured = fullStructured()
        structured.title = "# Evil\n## Injected heading\nMore title"
        let rendered = try NotesRenderer.render(
            structured, language: "en", meetingTitle: "fallback", userName: "Sam")
        let lines = rendered.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines[0] == "# Evil ## Injected heading More title")
        // No injected H2: exactly the five section headings.
        let h2Lines = lines.filter { $0.hasPrefix("## ") }
        #expect(h2Lines == ["## Summary", "## Detailed notes", "## Decisions", "## Action items", "## Sam's action items"])
        #expect(lines.filter { $0.hasPrefix("# ") }.count == 1)
    }

    @Test func blankTitleFallsBackToFlattenedMeetingTitle() throws {
        var structured = fullStructured()
        structured.title = "   \n "
        let rendered = try NotesRenderer.render(structured, language: "en", meetingTitle: "## Board\nmeeting")
        #expect(rendered.hasPrefix("# Board meeting\n"))

        structured.title = nil
        let rendered2 = try NotesRenderer.render(structured, language: "en", meetingTitle: "Plain title")
        #expect(rendered2.hasPrefix("# Plain title\n"))
    }

    @Test func bodyHeadingsAreDemotedBelowH3() throws {
        var structured = fullStructured()
        structured.detailedNotes = "# Big\n## Sub\n### Fine\nplain text\n#### Deep\n  ## Indented\n#hashtag stays"
        structured.summary = "## Sneaky summary heading\nreal summary"
        let rendered = try NotesRenderer.render(
            structured, language: "en", meetingTitle: "t", userName: "Sam")
        let lines = rendered.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.contains("### Big"))
        #expect(lines.contains("### Sub"))
        #expect(lines.contains("### Fine"))
        #expect(lines.contains("#### Deep"))
        #expect(lines.contains("### Indented"))
        #expect(lines.contains("#hashtag stays"))
        #expect(lines.contains("### Sneaky summary heading"))
        // No engine string outranks H3: the only H1 is the title, the only
        // H2s are the section headings.
        #expect(lines.filter { $0.hasPrefix("# ") }.count == 1)
        #expect(lines.filter { $0.hasPrefix("## ") } == ["## Summary", "## Detailed notes", "## Decisions", "## Action items", "## Sam's action items"])
    }

    @Test func v2TypedSectionsRenderDemotedWithTablesIntact() throws {
        // Notes v2 detailed_notes: per-type "##" section plans (here a
        // budget_finance shape with a figures table). The renderer needs no
        // change: sections demote to H3 (so the document's own H2 sections
        // stay unique) and the markdown table passes through verbatim.
        var structured = fullStructured()
        structured.meetingType = .budgetFinance
        structured.detailedNotes = """
            ## Premissas
            - Headcount estável no trimestre
            ## Números discutidos
            | item | valor | período | quem disse |
            |---|---|---|---|
            | licenças | R$ 1.000,00 | abril | Sam |
            ## Pendências
            - Conferir o forecast
            """
        let rendered = try NotesRenderer.render(
            structured, language: "pt", meetingTitle: "t", userName: "Sam")
        let lines = rendered.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.contains("### Premissas"))
        #expect(lines.contains("### Números discutidos"))
        #expect(lines.contains("### Pendências"))
        #expect(lines.contains("| licenças | R$ 1.000,00 | abril | Sam |"))
        #expect(lines.filter { $0.hasPrefix("## ") } == ["## Resumo", "## Notas detalhadas", "## Decisões", "## Itens de ação", "## Ações de Sam"])
    }

    @Test func listItemsStripLeadingMarkersAndCollapseNewlines() throws {
        var structured = fullStructured()
        structured.decisions = [
            "## Fake heading decision",
            "- nested list item",
            "1. ordered item",
            "> quoted item",
            "1.5x growth target",
            "Line one\nLine two",
        ]
        structured.actionItems = [ActionItem(owner: "## Anna\nM.", text: "- do\nthe thing")]
        structured.userActionItems = [ActionItem(owner: "> Sam", text: "# follow\nup")]
        let rendered = try NotesRenderer.render(structured, language: "en", meetingTitle: "t")
        #expect(rendered.contains("- Fake heading decision\n"))
        #expect(rendered.contains("- nested list item\n"))
        #expect(rendered.contains("- ordered item\n"))
        #expect(rendered.contains("- quoted item\n"))
        #expect(rendered.contains("- 1.5x growth target\n"))
        #expect(rendered.contains("- Line one Line two\n"))
        #expect(rendered.contains("- **Anna M.:** do the thing\n"))
        #expect(rendered.contains("- **Sam:** follow up\n"))
        // The hostile strings introduced no headings.
        let lines = rendered.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.filter { $0.hasPrefix("#") }.count == 6) // H1 + five H2 sections
    }
}

// Impl-audit round-1 regression tests (audits/c2/impl_audit_round1.md)
@Suite struct NotesRendererHardeningTests {
    private func render(detailedNotes: String) throws -> String {
        let s = NotesStructured(
            title: "T", summary: "Resumo ok.", detailedNotes: detailedNotes,
            decisions: [], actionItems: [], userActionItems: []
        )
        return try NotesRenderer.render(s, language: "en", meetingTitle: "Fallback")
    }

    /// H1: setext headings (text + === / --- underline) must be demoted.
    @Test func setextHeadingsAreDemoted() throws {
        let out = try render(detailedNotes: "Injected H1\n===\n\nInjected H2\n---")
        #expect(!out.contains("Injected H1\n==="), "setext H1 must not survive")
        #expect(!out.contains("Injected H2\n---"), "setext H2 must not survive")
        #expect(out.contains("### Injected H1"))
        #expect(out.contains("### Injected H2"))
    }

    /// M1: an unclosed code fence is closed so later section headings can't
    /// be swallowed into a code block.
    @Test func unclosedFenceIsClosed() throws {
        let out = try render(detailedNotes: "before\n```swift\nlet x = 1")
        let fenceCount = out.components(separatedBy: "\n").filter { $0.hasPrefix("```") }.count
        #expect(fenceCount % 2 == 0, "fences must balance: got \(fenceCount)")
        // The user action-items section heading must remain a real heading
        // after the body (unnamed identity → neutral "My action items").
        #expect(out.contains("\n## My action items"))
    }

    /// M2: heading-like lines INSIDE a closed fence are untouched.
    @Test func fencedContentIsNeverRewritten() throws {
        let out = try render(detailedNotes: "```\n# comment in code\n## another\n===\n```")
        #expect(out.contains("# comment in code"), "code content must be verbatim")
        #expect(out.contains("## another"))
        #expect(!out.contains("### comment in code"))
    }

    /// M3: a title of only '#' characters falls back to meetingTitle.
    @Test func hashOnlyTitleFallsBack() throws {
        let s = NotesStructured(
            title: "###", summary: "S.", detailedNotes: "",
            decisions: [], actionItems: [], userActionItems: []
        )
        let out = try NotesRenderer.render(s, language: "en", meetingTitle: "Real Title")
        #expect(out.hasPrefix("# Real Title\n"))
    }

    /// Setext look-alike after a blank line is a thematic break — untouched.
    @Test func thematicBreakIsNotTreatedAsSetext() throws {
        let out = try render(detailedNotes: "para one\n\n---\n\npara two")
        #expect(out.contains("para one\n\n---\n\npara two"))
    }
}

// Fix-verification round-2 regressions (N1–N5, audits/c2/impl_audit_round1.md)
@Suite struct NotesRendererFenceEdgeTests {
    private func render(_ detailedNotes: String) throws -> String {
        let s = NotesStructured(title: "T", summary: "S.", detailedNotes: detailedNotes,
                                decisions: [], actionItems: [], userActionItems: [])
        return try NotesRenderer.render(s, language: "en", meetingTitle: "F")
    }

    /// N1: backtick fence with backtick in info string is NOT a fence —
    /// the following "# Injected" must be demoted, and no phantom fence opens.
    @Test func backtickInInfoStringIsNotAFence() throws {
        let out = try render("``` a`b\n# Injected\nrest")
        #expect(out.contains("### Injected"), "heading after non-fence must demote")
        #expect(out.contains("\n## My action items"), "sections must survive")
    }

    /// N2: CRLF line endings must not hide a setext underline.
    @Test func crlfSetextIsDemoted() throws {
        let out = try render("Injected\r\n===\r\nrest")
        #expect(!out.contains("Injected\n==="))
        #expect(out.contains("### Injected"))
    }

    /// N3: a "close" with trailing text does not close; the fence stays open
    /// and is force-closed at the end so sections survive.
    @Test func fenceCloseWithTrailingTextDoesNotClose() throws {
        let out = try render("```\ncode\n``` not-a-close\nstill code")
        // The "``` not-a-close" line is CONTENT (CommonMark: a close fence
        // allows only trailing spaces/tabs), so the block must be force-closed
        // AFTER "still code" and the section headings must survive as headings.
        #expect(out.contains("still code\n```"), "force-close must come after the open block's content")
        #expect(out.contains("\n## My action items"))
    }

    /// N4: a tilde fence is force-closed with tildes, not backticks.
    @Test func tildeFenceIsClosedWithTildes() throws {
        let out = try render("~~~\nopen tilde code")
        #expect(out.hasSuffix("~~~\n") || out.contains("open tilde code\n~~~"), "tilde closer expected: \(out.suffix(60))")
    }

    /// N5: list items and blockquotes followed by --- are NOT setext hosts.
    @Test func listAndQuoteLinesAreNotSetextHosts() throws {
        let out = try render("- item\n---\n\n> quote\n---")
        #expect(out.contains("- item\n---"), "list + thematic break untouched")
        #expect(out.contains("> quote\n---"), "quote + thematic break untouched")
    }
}

// Fix-verification round-3 regressions (N7, N10 twins)
@Suite struct NotesRendererSetextMarkerEdgeTests {
    private func render(_ detailedNotes: String) throws -> String {
        let s = NotesStructured(title: "T", summary: "S.", detailedNotes: detailedNotes,
                                decisions: [], actionItems: [], userActionItems: [])
        return try NotesRenderer.render(s, language: "en", meetingTitle: "F")
    }

    /// N7: a 10+-digit "marker" is a paragraph (CommonMark caps markers at 9
    /// digits) and CAN host setext — it must be demoted.
    @Test func tenDigitMarkerLineIsSetextHost() throws {
        let out = try render("1234567890. injected\n---")
        #expect(out.contains("### 1234567890. injected"), "10-digit line + --- must demote, got: \(out)")
        let out2 = try render("1234567890) injected\n===")
        #expect(out2.contains("### 1234567890) injected"))
    }

    /// N7: a true 1–9-digit ordered marker followed by --- stays untouched.
    @Test func realOrderedMarkerIsNotSetextHost() throws {
        let out = try render("123456789. item\n---")
        #expect(out.contains("123456789. item\n---"))
    }

    /// N10 twin: 4-backtick fence force-closes with 4 backticks.
    @Test func fourBacktickFenceForceCloses() throws {
        let out = try render("````\ncode")
        #expect(out.contains("code\n````"), "4-backtick closer expected")
    }

    /// N10 twin: lone-CR setext underline is normalized and demoted.
    @Test func loneCRSetextIsDemoted() throws {
        let out = try render("Injected\r===")
        #expect(out.contains("### Injected"))
    }
}
