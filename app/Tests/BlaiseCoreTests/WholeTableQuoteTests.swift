import Foundation
import Testing

@testable import BlaiseCore

// A whole-table aim stores the table's on-screen text, which no raw anchoring
// block holds (cell pipes, the divider row): the quote resolves by the
// table fallback, and every other one-piece quote resolves exactly as before.
// Fictional notes only (Vexatron Labs / Quoll Harbor).

private let table = "| Probe | Latency |\n| --- | --- |\n| Kestrel | 12 ms |\n| Osprey | 4 ms |"
private let onScreen = "Probe | Latency\nKestrel | 12 ms\nOsprey | 4 ms"
private let linkQuote = "The pilot budget stays"

private let structured = NotesStructured(
    title: "Quoll Harbor sonar review",
    summary: "Vexatron Labs ran the latency probes.\n\n" + table
        + "\n\nThe [pilot](https://example.com/pilot) budget stays at US$ 40.000,00.",
    detailedNotes: "The rig travels by barge.\n\n" + table.replacingOccurrences(of: "Osprey", with: "Heron")
        + "\n\nAfter the table.",
    decisions: ["Keep the barge contract"], actionItems: [], userActionItems: [])

private let detailedOnScreen = onScreen.replacingOccurrences(of: "Osprey", with: "Heron")

private func row(
    _ id: String, _ kind: MeetingCorrection.Kind, _ section: MeetingCorrection.Section, _ quote: String,
    occurrence: Int = 0, status: MeetingCorrection.Status = .applied
) -> MeetingCorrection {
    MeetingCorrection(
        id: id, meetingID: N7GoldenFixture.meetingID, kind: kind, section: section, quotedText: quote,
        occurrence: occurrence, userText: "Note \(id)", status: status,
        createdAt: N7GoldenFixture.baseTime)
}

@Suite struct WholeTableQuoteTests {

    @Test("the table's on-screen text matches no raw block; the fallback resolves it to the table, in both sections")
    func fallbackResolvesTheTable() {
        let space = CorrectionAnchoring.RenderedSpace(structured)
        let summary = space.blocks.filter { $0.section == .summary }.map(\.text)
        #expect(summary[1] == onScreen)
        for (section, quote) in [(MeetingCorrection.Section.summary, onScreen), (.detailedNotes, detailedOnScreen)] {
            #expect(
                CorrectionAnchoring.resolve(
                    quote: quote, occurrence: 0, in: CorrectionAnchoring.blocks(of: structured, section: section))
                    == nil)
            #expect(
                CorrectionAnchoring.resolveTable(quote: quote, occurrence: 0, section: section, in: space)
                    .map { "\($0.blockIndex),\($0.occurrence)" } == "1,0")
        }
    }

    @Test("only a table takes the fallback: a quote across a link, or one found only in a code block, still resolves nowhere")
    func onlyATableTakesTheFallback() throws {
        let space = CorrectionAnchoring.RenderedSpace(structured)
        #expect(CorrectionAnchoring.resolveTable(quote: linkQuote, occurrence: 0, section: .summary, in: space) == nil)
        let code = NotesStructured(
            title: nil, summary: "Plain.", detailedNotes: "```\nstep one\n\nstep two\n```",
            decisions: [], actionItems: [], userActionItems: [])
        #expect(
            CorrectionAnchoring.resolveTable(
                quote: "step one step two", occurrence: 0, section: .detailedNotes,
                in: CorrectionAnchoring.RenderedSpace(code)) == nil)

        let updates = CorrectionAnchoring.reanchor(
            annotations: [row("link", .annotation, .summary, linkQuote)], against: structured)
        #expect(updates.map(\.status) == [.stale])
        let text = try NotesRenderer.render(
            structured, language: "en", meetingTitle: "Quoll Harbor",
            annotations: [row("link", .annotation, .summary, linkQuote)])
        #expect(text.contains("## Your notes\n\n- Note link"))
    }

    @Test(
        "a quote a table's flattened text merely holds stays unplaced: across two rows, or across a link in a cell",
        arguments: [
            // A stale paragraph note whose words now run from one row's last cell into the next row.
            ("| Crew | calibrate Dana |\n| --- | --- |\n| owns the permits | file |", "Dana owns the permits"),
            // A partial quote across a link, taken from the paragraph; the table's cell drops the same URL.
            ("| Plan | Note |\n| --- | --- |\n| Review | the [Vexatron plan](https://example.com/p) today |"
                + "\n\nWe will review the [Vexatron plan](https://example.com/p) today with the crew.",
                "Vexatron plan today"),
            // A paragraph quote across a link, whose paragraph was rewritten into a table cell.
            ("| Topic | Status |\n| --- | --- |\n| Funding | The [pilot](https://example.com/pilot) budget stays |",
                linkQuote),
        ])
    func containedIsNotWhole(summary: String, quote: String) throws {
        let notes = NotesStructured(
            title: nil, summary: summary, detailedNotes: "", decisions: [], actionItems: [], userActionItems: [])
        #expect(
            CorrectionAnchoring.resolveTable(
                quote: quote, occurrence: 0, section: .summary, in: CorrectionAnchoring.RenderedSpace(notes)) == nil)
        let rows = [row("p", .annotation, .summary, quote)]
        #expect(CorrectionAnchoring.reanchor(annotations: rows, against: notes).map(\.status) == [.stale])
        let text = try NotesRenderer.render(notes, language: "en", meetingTitle: "Quoll Harbor", annotations: rows)
        #expect(text.contains("## Your notes\n\n- Note p"))
    }

    @Test("two identical tables: the stored occurrence names the second, counted the way capture counts it")
    func repeatedTables() {
        let twice = NotesStructured(
            title: nil, summary: "First run.\n\n" + table + "\n\nSecond run.\n\n" + table,
            detailedNotes: "", decisions: [], actionItems: [], userActionItems: [])
        let space = CorrectionAnchoring.RenderedSpace(twice)
        let texts = space.blocks.filter { $0.section == .summary }.map(\.text)
        let captured = CorrectionAnchoring.occurrence(ofBlockAt: 3, in: texts)
        #expect(captured == 1)
        #expect(
            CorrectionAnchoring.resolveTable(quote: onScreen, occurrence: captured, section: .summary, in: space)?
                .blockIndex == 3)
    }

    @Test("a non-table block holding the same text counts before the tables: occurrence 1 names the first table")
    func occurrenceCountsEveryRenderedBlock() {
        // The link keeps this paragraph out of the raw match while its on-screen text is the table's.
        let mixed = NotesStructured(
            title: nil,
            summary: "Probe | [Latency](https://example.com/l) Kestrel | 12 ms Osprey | 4 ms\n\n" + table
                + "\n\nSecond run.\n\n" + table,
            detailedNotes: "", decisions: [], actionItems: [], userActionItems: [])
        let space = CorrectionAnchoring.RenderedSpace(mixed)
        let texts = space.blocks.filter { $0.section == .summary }.map(\.text)
        #expect(CorrectionAnchoring.fold(texts[0]) == CorrectionAnchoring.fold(onScreen))
        let captured = CorrectionAnchoring.occurrence(ofBlockAt: 1, in: texts)
        #expect(captured == 1)
        #expect(
            CorrectionAnchoring.resolveTable(quote: onScreen, occurrence: captured, section: .summary, in: space)?
                .blockIndex == 1)
    }

    @Test("a detailed table whose index within its section is no table's index in the whole document still resolves")
    func sectionIndexIsNotGlobalIndex() {
        let notes = NotesStructured(
            title: nil, summary: "Vexatron Labs ran the probes.\n\nNo table this time.",
            detailedNotes: "The rig travels by barge.\n\n" + table,
            decisions: [], actionItems: [], userActionItems: [])
        let space = CorrectionAnchoring.RenderedSpace(notes)
        #expect(!space.tables.contains(1))
        #expect(
            CorrectionAnchoring.resolveTable(quote: onScreen, occurrence: 0, section: .detailedNotes, in: space)?
                .blockIndex == 1)
    }

    @Test("re-anchor keeps a whole-table note applied; the weave puts its aside in its section, never in Your notes")
    func reanchorAndWeave() throws {
        let rows = [
            row("sum", .annotation, .summary, onScreen),
            row("det", .annotation, .detailedNotes, detailedOnScreen),
        ]
        #expect(
            CorrectionAnchoring.reanchor(annotations: rows, against: structured)
                == [.init(id: "sum", occurrence: 0, status: .applied), .init(id: "det", occurrence: 0, status: .applied)])
        let text = try NotesRenderer.render(
            structured, language: "en", meetingTitle: "Quoll Harbor", annotations: rows)
        #expect(!text.contains("## Your notes"))
        let summaryAside = try #require(text.range(of: "> **Your note:** Note sum"))
        let detailedHeading = try #require(text.range(of: "## Detailed notes"))
        #expect(summaryAside.lowerBound < detailedHeading.lowerBound)
        let detailedAside = try #require(
            text.range(of: "> **Your note** (on \u{201C}Probe | Latency Kestrel | 12 ms Heron | 4 ms\u{201D}): Note det"))
        let afterTable = try #require(text.range(of: "After the table."))
        let decisions = try #require(text.range(of: "## Decisions"))
        #expect(afterTable.lowerBound < detailedAside.lowerBound && detailedAside.lowerBound < decisions.lowerBound)
    }

    @Test("reopening a whole-table note reads the fallback: applied, not stale")
    func reopen() async throws {
        let harness = try await makePipelineHarness()
        harness.notesPrimary.state.withLock { $0.summary = "Vexatron Labs ran the probes.\n\n" + table }
        let meeting = try await harness.importTestMeeting()
        try await harness.pipeline.process(meetingID: meeting.id)
        let added = try await harness.pipeline.addCorrection(
            meetingID: meeting.id, kind: .annotation, section: .summary,
            quotedText: onScreen, occurrence: 0, userText: "Re-run Osprey.")
        let notes = try #require(
            try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id))
        try await harness.pipeline.setCorrectionResolved(
            meetingID: meeting.id, id: added.row.id, resolved: true, structuredNotes: notes.structured)
        try await harness.pipeline.setCorrectionResolved(
            meetingID: meeting.id, id: added.row.id, resolved: false, structuredNotes: notes.structured)
        await harness.pipeline.settleViewDetached(meeting.id)
        let reopened = try #require(
            try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id)).markdown
        let stored = try #require(
            try await harness.database.pool.read { db in
                try MeetingCorrectionStore.all(db, meetingID: meeting.id).first { $0.id == added.row.id }
            })
        #expect(stored.status == .applied)
        #expect(!reopened.contains("## Suas notas"))
        #expect(reopened.components(separatedBy: "Re-run Osprey.").count == 2)
        let aside = try #require(reopened.range(of: "> **Sua nota:** Re-run Osprey."))
        let lastRow = try #require(reopened.range(of: "| Osprey | 4 ms |"))
        #expect(lastRow.upperBound < aside.lowerBound)
    }

    @Test("disclosed, not fixed: the withdrawn-claim check still reads a pending whole-table correction as absent (it reads the raw notes text)")
    func withdrawnCheckUnchanged() {
        let pending = row("fix", .understanding, .summary, onScreen, status: .pending)
        let withdrawn = CorrectionAnchoring.withdrawnRows(
            corrections: [pending],
            currentHaystack: CorrectionAnchoring.foldedHaystack(of: structured, meetingTitle: "Quoll Harbor"),
            renderedHaystack: CorrectionAnchoring.renderedHaystack(of: structured, meetingTitle: "Quoll Harbor"))
        #expect(withdrawn.map(\.claimText) == [onScreen])
    }

    @Test("byte identity: notes.md for the one-piece golden rows is the base revision's bytes")
    func goldenWeave() throws {
        let text = try NotesRenderer.render(
            N7GoldenFixture.notes, language: "en", meetingTitle: N7GoldenFixture.meetingTitle,
            annotations: N7GoldenFixture.rows + [row("link", .annotation, .summary, linkQuote)])
        #expect(EvidencePayloadBuilder.sha256Hex(Data(text.utf8)) == "d1c82d3e76a73e10d7259fd8a1bd938bae119635ad1639c656a1ae5dd3f0fe5a")
    }
}
