import Foundation
import Testing

@testable import BlaiseCore

// SC-001 / SC-002: the export's view of the stored notes markdown. Every
// fixture here is produced by `NotesRenderer.render` — the bytes under test are
// the renderer's own, never hand-authored.

@Suite struct NotesMarkdownSectionsTests {
    // MARK: - Fixtures

    private func structured(
        title: String = "Quoll Harbor kickoff",
        detailedNotes: String = "The team walked the launch window."
    ) -> NotesStructured {
        NotesStructured(
            title: title,
            summary: "The launch window moved to November.",
            detailedNotes: detailedNotes,
            decisions: ["Closed beta starts on 20/10/2026"],
            actionItems: [ActionItem(owner: "Dev Okafor", text: "Prototype the merge")],
            userActionItems: [ActionItem(owner: "Marina Solano", text: "Open the QA role")])
    }

    private func annotation(
        section: MeetingCorrection.Section, quote: String, text: String
    ) -> MeetingCorrection {
        MeetingCorrection(
            meetingID: "01J00000000000000000000000", kind: .annotation, section: section,
            quotedText: quote, userText: text, createdAt: msDate())
    }

    /// The line the given text sits on, or nil.
    private func lines(_ markdown: String) -> [String] {
        markdown.components(separatedBy: "\n")
    }

    /// The lines `after` dropped from `before`, or nil when `after` is not a
    /// pure deletion of `before` (any surviving byte moved or changed).
    private func removedLines(_ before: String, _ after: String) -> [String]? {
        let old = lines(before)
        let new = lines(after)
        var removed: [String] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < old.count {
            if newIndex < new.count, old[oldIndex] == new[newIndex] {
                oldIndex += 1
                newIndex += 1
            } else {
                removed.append(old[oldIndex])
                oldIndex += 1
            }
        }
        return newIndex == new.count ? removed : nil
    }

    // MARK: - SC-001 parity

    @Test("both toggles on returns the stored bytes untouched")
    func parityAcrossFixtures() throws {
        let notes = annotation(section: .summary, quote: "The launch window moved to November.",
                               text: "Confirm with the partner first")
        let listNote = annotation(section: .decision, quote: "Closed beta starts on 20/10/2026",
                                  text: "Check the freeze calendar")
        let stale = annotation(section: .summary, quote: "a quote that no longer exists",
                               text: "Still worth keeping")
        let fixtures = [
            try NotesRenderer.render(structured(), language: "en", meetingTitle: "t", userName: "Marina Solano"),
            try NotesRenderer.render(structured(), language: "en", meetingTitle: "t", userName: ""),
            try NotesRenderer.render(structured(), language: "pt-BR", meetingTitle: "t", userName: "Marina Solano"),
            try NotesRenderer.render(
                structured(), language: "en", meetingTitle: "t", userName: "Marina Solano",
                annotations: [notes, listNote, stale]),
            try NotesRenderer.render(
                structured(detailedNotes: "```\n## Minhas ações\n> **Sua nota:** fenced\n```"),
                language: "pt-BR", meetingTitle: "t", userName: "Marina Solano",
                annotations: [notes, stale]),
        ]
        for (index, markdown) in fixtures.enumerated() {
            let language = index >= 2 ? "pt-BR" : "en"
            let out = NotesMarkdownSections.apply(
                markdown, includeSelf: true, includeMarginNotes: true, language: language)
            #expect(Array(out.utf8) == Array(markdown.utf8), "fixture \(index) lost parity")
        }
    }

    @Test("a pipeline-minted row survives a rename and an annotation re-mint unchanged")
    func parityForPipelineMintedMarkdown() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        _ = try await harness.pipeline.process(meetingID: meeting.id)

        try await harness.pipeline.renameSpeaker(
            meetingID: meeting.id, speakerLabel: "S0", to: "Marina Solano")
        let notesRepository = NotesRepository(database: harness.database)
        let renamed = try #require(try await notesRepository.fetch(meetingID: meeting.id))
        let anchor = try #require(
            renamed.structured.decisions.first ?? renamed.structured.actionItems.first?.text)
        _ = try await harness.pipeline.addCorrection(
            meetingID: meeting.id, kind: .annotation, section: .decision,
            quotedText: anchor, occurrence: 0, userText: "Check the freeze calendar")

        let stored = try #require(try await notesRepository.fetch(meetingID: meeting.id))
        #expect(stored.markdown.contains("Check the freeze calendar"))
        let out = NotesMarkdownSections.apply(
            stored.markdown, includeSelf: true, includeMarginNotes: true,
            language: stored.language)
        #expect(Array(out.utf8) == Array(stored.markdown.utf8))
        // The self section is found by position, so a renamed identity is
        // irrelevant to it.
        #expect(
            NotesMarkdownSections.classify(stored.markdown, language: stored.language)
                .contains { $0.kind == .selfActionItems })
    }

    // MARK: - SC-002 removals

    @Test("the classifier labels the renderer's sections in order")
    func classifyLabelsRendererSections() throws {
        let markdown = try NotesRenderer.render(
            structured(), language: "en", meetingTitle: "t", userName: "Marina Solano",
            annotations: [annotation(section: .summary, quote: "nowhere", text: "loose note")])
        let kinds = NotesMarkdownSections.classify(markdown, language: "en").map(\.kind)
        #expect(kinds == [.summary, .detailedNotes, .decisions, .actionItems, .selfActionItems, .yourNotes])
    }

    @Test("self removal drops exactly the named section")
    func selfRemovalEnglish() throws {
        let markdown = try NotesRenderer.render(
            structured(), language: "en", meetingTitle: "t", userName: "Marina Solano")
        let out = NotesMarkdownSections.apply(
            markdown, includeSelf: false, includeMarginNotes: true, language: "en")
        let removed = try #require(removedLines(markdown, out))
        #expect(removed.filter { !$0.isEmpty }
            == ["## Marina Solano's action items", "- **Marina Solano:** Open the QA role"])
        #expect(out.hasSuffix("- **Dev Okafor:** Prototype the merge\n"))
    }

    @Test("self removal is name-blind in Portuguese too")
    func selfRemovalPortuguese() throws {
        let markdown = try NotesRenderer.render(
            structured(), language: "pt-BR", meetingTitle: "t", userName: "Tomás Ferreira")
        let out = NotesMarkdownSections.apply(
            markdown, includeSelf: false, includeMarginNotes: true, language: "pt-BR")
        let removed = try #require(removedLines(markdown, out))
        #expect(removed.filter { !$0.isEmpty }
            == ["## Ações de Tomás Ferreira", "- **Marina Solano:** Open the QA role"])
        #expect(!out.contains("Tomás Ferreira"))
    }

    @Test("margin removal drops both aside shapes and the notes section")
    func marginRemovalEnglish() throws {
        let markdown = try NotesRenderer.render(
            structured(), language: "en", meetingTitle: "t", userName: "Marina Solano",
            annotations: [
                annotation(section: .summary, quote: "The launch window moved to November.",
                           text: "Confirm with the partner first"),
                annotation(section: .decision, quote: "Closed beta starts on 20/10/2026",
                           text: "Check the freeze calendar"),
                annotation(section: .summary, quote: "a quote that no longer exists",
                           text: "Still worth keeping"),
            ])
        #expect(NotesMarkdownSections.hasMarginNotes(markdown, language: "en"))
        let out = NotesMarkdownSections.apply(
            markdown, includeSelf: true, includeMarginNotes: false, language: "en")
        let removed = try #require(removedLines(markdown, out))
        #expect(removed.filter { !$0.isEmpty } == [
            "> **Your note:** Confirm with the partner first",
            "> **Your note** (on \u{201C}Closed beta starts on 20/10/2026\u{201D}): Check the freeze calendar",
            "## Your notes",
            "- Still worth keeping *(on \u{201C}a quote that no longer exists\u{201D})*",
        ])
        #expect(!out.contains("Your note"))
        #expect(!NotesMarkdownSections.hasMarginNotes(out, language: "en"))
    }

    @Test("margin removal drops both aside shapes and the notes section in Portuguese")
    func marginRemovalPortuguese() throws {
        let markdown = try NotesRenderer.render(
            structured(), language: "pt", meetingTitle: "t", userName: "Marina Solano",
            annotations: [
                annotation(section: .summary, quote: "The launch window moved to November.",
                           text: "Confirmar com o parceiro"),
                annotation(section: .summary, quote: "nowhere", text: "Guardar mesmo assim"),
            ])
        let out = NotesMarkdownSections.apply(
            markdown, includeSelf: true, includeMarginNotes: false, language: "pt")
        let removed = try #require(removedLines(markdown, out))
        #expect(removed.filter { !$0.isEmpty } == [
            "> **Sua nota:** Confirmar com o parceiro",
            "## Suas notas",
            "- Guardar mesmo assim *(sobre \u{201C}nowhere\u{201D})*",
        ])
    }

    @Test("a fenced block that quotes a heading and an aside is untouched")
    func fencedLookalikesSurvive() throws {
        let markdown = try NotesRenderer.render(
            structured(detailedNotes: "```\n## Minhas ações\n> **Sua nota:** dentro do bloco\n```"),
            language: "pt-BR", meetingTitle: "t", userName: "Marina Solano")
        let out = NotesMarkdownSections.apply(
            markdown, includeSelf: false, includeMarginNotes: false, language: "pt-BR")
        #expect(out.contains("```\n## Minhas ações\n> **Sua nota:** dentro do bloco\n```"))
        // The fenced lines are not sections and not asides.
        #expect(NotesMarkdownSections.classify(markdown, language: "pt-BR").map(\.kind)
            == [.summary, .detailedNotes, .decisions, .actionItems, .selfActionItems])
        #expect(!NotesMarkdownSections.hasMarginNotes(markdown, language: "pt-BR"))
    }

    @Test("an opener whose info string carries a backtick is not a fence")
    func backtickInTheInfoStringIsNotAFence() throws {
        let markdown = try NotesRenderer.render(
            structured(detailedNotes: "```lang`variant\nnot code, just a line"),
            language: "en", meetingTitle: "t", userName: "Marina Solano")
        // The renderer reads that line as ordinary text, so the headings after
        // it are real sections.
        #expect(NotesMarkdownSections.classify(markdown, language: "en").map(\.kind)
            == [.summary, .detailedNotes, .decisions, .actionItems, .selfActionItems])

        let out = NotesMarkdownSections.apply(
            markdown, includeSelf: false, includeMarginNotes: true, language: "en")
        #expect(!out.contains("Marina Solano's action items"))
        #expect(out.contains("```lang`variant"), "the line itself is untouched")
    }

    @Test("a tilde fence hides the headings inside it")
    func tildeFenceHidesItsContents() throws {
        let markdown = try NotesRenderer.render(
            structured(detailedNotes: "~~~\n## My action items\n~~~"),
            language: "en", meetingTitle: "t", userName: "Marina Solano")
        #expect(NotesMarkdownSections.classify(markdown, language: "en").map(\.kind)
            == [.summary, .detailedNotes, .decisions, .actionItems, .selfActionItems])

        let out = NotesMarkdownSections.apply(
            markdown, includeSelf: false, includeMarginNotes: true, language: "en")
        #expect(out.contains("~~~\n## My action items\n~~~"))
    }

    @Test("a closer longer than its opener closes the fence")
    func aLongerCloserClosesTheFence() throws {
        let markdown = try NotesRenderer.render(
            structured(detailedNotes: "```\n## My action items\n`````"),
            language: "en", meetingTitle: "t", userName: "Marina Solano")
        #expect(NotesMarkdownSections.classify(markdown, language: "en").map(\.kind)
            == [.summary, .detailedNotes, .decisions, .actionItems, .selfActionItems])

        let out = NotesMarkdownSections.apply(
            markdown, includeSelf: false, includeMarginNotes: true, language: "en")
        #expect(!out.contains("Marina Solano's action items"))
        #expect(out.contains("```\n## My action items\n`````"))
    }

    @Test("self removal leaves an unanchored note section standing")
    func selfRemovalKeepsYourNotes() throws {
        let markdown = try NotesRenderer.render(
            structured(), language: "en", meetingTitle: "t", userName: "Marina Solano",
            annotations: [annotation(section: .summary, quote: "nowhere", text: "loose note")])
        let out = NotesMarkdownSections.apply(
            markdown, includeSelf: false, includeMarginNotes: true, language: "en")
        #expect(out.contains("## Your notes"))
        #expect(!out.contains("Marina Solano's action items"))
        #expect(NotesMarkdownSections.classify(out, language: "en").map(\.kind)
            == [.summary, .detailedNotes, .decisions, .actionItems, .yourNotes])
    }

    @Test("an aside as the last block leaves the document ending in one newline")
    func trailingAsideRemovalKeepsOneNewline() throws {
        let markdown = try NotesRenderer.render(
            structured(), language: "en", meetingTitle: "t", userName: "Marina Solano",
            annotations: [
                annotation(section: .userActionItem, quote: "Open the QA role",
                           text: "Ask the recruiter first")
            ])
        #expect(markdown.hasSuffix("Ask the recruiter first\n"))
        let out = NotesMarkdownSections.apply(
            markdown, includeSelf: true, includeMarginNotes: false, language: "en")
        #expect(out.hasSuffix("- **Marina Solano:** Open the QA role\n"))
        #expect(!out.hasSuffix("\n\n"))
    }

    @Test("both toggles off remove both sections and every aside")
    func bothTogglesOff() throws {
        let markdown = try NotesRenderer.render(
            structured(), language: "en", meetingTitle: "t", userName: "Marina Solano",
            annotations: [
                annotation(section: .userActionItem, quote: "Open the QA role",
                           text: "Ask the recruiter first"),
                annotation(section: .summary, quote: "nowhere", text: "loose note"),
            ])
        let out = NotesMarkdownSections.apply(
            markdown, includeSelf: false, includeMarginNotes: false, language: "en")
        #expect(NotesMarkdownSections.classify(out, language: "en").map(\.kind)
            == [.summary, .detailedNotes, .decisions, .actionItems])
        #expect(!out.contains("Your note"))
        #expect(out.hasSuffix("- **Dev Okafor:** Prototype the merge\n"))
    }

    @Test("margin notes are detected from either shape alone")
    func hasMarginNotesShapes() throws {
        let plain = try NotesRenderer.render(
            structured(), language: "en", meetingTitle: "t", userName: "Marina Solano")
        #expect(!NotesMarkdownSections.hasMarginNotes(plain, language: "en"))

        let anchored = try NotesRenderer.render(
            structured(), language: "en", meetingTitle: "t", userName: "Marina Solano",
            annotations: [annotation(section: .summary, quote: "The launch window moved to November.",
                                     text: "Confirm with the partner first")])
        #expect(NotesMarkdownSections.hasMarginNotes(anchored, language: "en"))

        let unanchoredOnly = try NotesRenderer.render(
            structured(), language: "en", meetingTitle: "t", userName: "Marina Solano",
            annotations: [annotation(section: .summary, quote: "nowhere", text: "loose note")])
        #expect(NotesMarkdownSections.hasMarginNotes(unanchoredOnly, language: "en"))
        #expect(NotesMarkdownSections.apply(
            unanchoredOnly, includeSelf: true, includeMarginNotes: false, language: "en")
            .contains("## Your notes") == false)
    }
}
