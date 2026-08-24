import BlaiseCore
import Foundation
import SwiftUI
import Testing

@testable import BlaiseApp

// The rebuilt notes editing surface, tested where it is decidable without
// rendering a scene: the pending row's status mapping, the placement
// presentation model, the entry gate on every path, and the routing seams the
// right-click menu and the menu-bar commands share with the hover group.

private func row(
    id: String? = nil,
    kind: MeetingCorrection.Kind = .understanding,
    status: MeetingCorrection.Status = .pending,
    text: String = "The spike was in the render queue.",
    quote: String = "a latency spike caused by the audio bridge",
    createdAt: Date = Date(timeIntervalSince1970: 1_770_000_000),
    appliedAt: Date? = nil
) -> MeetingCorrection {
    MeetingCorrection(
        id: id ?? "01ROW0000000000000000000\(status.rawValue.prefix(2))",
        meetingID: "01TESTMEETING0000000000000", kind: kind, section: .summary,
        quotedText: quote, occurrence: 0, userText: text, status: status,
        createdAt: createdAt, appliedAt: appliedAt)
}

private struct MissingDeclaration: Error { let name: String }

/// The pane's own source. This surface's COMPOSITION — what stands in the row,
/// what stands below it, in what order — is decidable here and not in a
/// headless scene.
private func meetingDetailSource() throws -> String {
    let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources", isDirectory: true)
    return try String(
        contentsOf: sources.appendingPathComponent("BlaiseApp/MeetingDetailView.swift"),
        encoding: .utf8)
}

/// The block host's own source, read for the same reason.
private func notesBlockTextSource() throws -> String {
    let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources", isDirectory: true)
    return try String(
        contentsOf: sources.appendingPathComponent("BlaiseApp/NotesBlockText.swift"),
        encoding: .utf8)
}

/// One declaration's body, bounded by the declaration that follows it.
private func declaration(
    _ name: String, endingBefore next: String, in source: String
) throws -> Substring {
    guard let start = source.range(of: "private var \(name)") else {
        throw MissingDeclaration(name: name)
    }
    guard
        let end = source.range(
            of: "private var \(next)", options: [], range: start.upperBound..<source.endIndex)
    else { throw MissingDeclaration(name: next) }
    return source[start.upperBound..<end.lowerBound]
}

// MARK: - The occurrence a rendered block carries

/// The pane renders one block per parsed markdown block and hands each one the
/// occurrence that names WHICH fold-match it is. Two paragraphs with identical
/// text are the only case an occurrence decides, and the whole reason the
/// argument exists — a constant would anchor every one of them to the first.
@Suite struct RenderedBlockOccurrenceTests {
    private let detailed = """
        Alpha shipped on time.

        Owner to be confirmed.

        Beta slipped a week.

        Owner to be confirmed.
        """

    private var structured: NotesStructured {
        NotesStructured(
            summary: "The cohort review went well.", detailedNotes: detailed,
            decisions: [], actionItems: [], userActionItems: [])
    }

    @Test("a repeated paragraph anchors to the block the user acted on, not the first one")
    func repeatedParagraphAnchorsToItsOwnBlock() {
        let rendered = MarkdownBlocks.parse(detailed).map { String($0.text.characters) }
        let anchorBlocks = CorrectionAnchoring.blocks(of: structured, section: .detailedNotes)
        // The user acts on the SECOND "Owner to be confirmed." (rendered block 3).
        let index = 3
        #expect(rendered[index] == "Owner to be confirmed.")

        let carried = CorrectionAnchoring.occurrence(ofBlockAt: index, in: rendered)
        #expect(carried == 1, "it is the second block matching its own text")

        // Whole-block invocation: the quote equals the block, so the carried
        // occurrence is what gets stored.
        let stored = CorrectionAnchoring.occurrence(
            forQuote: rendered[index], takenFrom: rendered[index], blockOccurrence: carried,
            in: anchorBlocks)
        #expect(
            CorrectionAnchoring.resolve(
                quote: rendered[index], occurrence: stored, in: anchorBlocks)?.blockIndex == index)

        // The regression this pins: a constant occurrence weaves the margin
        // note under the FIRST repeated paragraph instead.
        #expect(
            CorrectionAnchoring.resolve(
                quote: rendered[index], occurrence: 0, in: anchorBlocks)?.blockIndex == 1)
    }

    @Test("a selection inside a repeated paragraph is recomputed into the quote's match space")
    func trimmedQuoteInARepeatedParagraph() {
        let rendered = MarkdownBlocks.parse(detailed).map { String($0.text.characters) }
        let anchorBlocks = CorrectionAnchoring.blocks(of: structured, section: .detailedNotes)
        let carried = CorrectionAnchoring.occurrence(ofBlockAt: 3, in: rendered)
        let stored = CorrectionAnchoring.occurrence(
            forQuote: "Owner", takenFrom: rendered[3], blockOccurrence: carried, in: anchorBlocks)
        #expect(
            CorrectionAnchoring.resolve(quote: "Owner", occurrence: stored, in: anchorBlocks)?
                .blockIndex == 3)
    }
}

// MARK: - Retiring the aim the pane keeps for the menu-bar commands

/// The pane holds the last block the pointer entered so a menu-bar invocation
/// has something to aim at after the pointer has left the prose. An aim kept
/// across a rewrite of the prose quotes a passage the notes no longer contain,
/// so it anchors to nothing.
@Suite struct RetainedAimInvalidationTests {
    private let stamped = Date(timeIntervalSince1970: 1_770_000_000)

    private func notes(_ detailedNotes: String) -> MeetingNotes {
        MeetingNotes(
            meetingID: "01TESTMEETING0000000000000", markdown: "",
            structured: NotesStructured(
                summary: "The cohort review went well.", detailedNotes: detailedNotes,
                decisions: [], actionItems: [], userActionItems: []),
            language: "en", generatedAt: stamped,
            provenance: NotesProvenance(
                engine: "fixture", model: "fixture", pipelineVersion: "fixture"))
    }

    @Test("an aim kept across such a rewrite anchors an instruction to nothing")
    func aStaleAimAnchorsToNothing() {
        let before = notes("The sonar demo slipped a week.")
        let after = notes("The Sonar demo slipped a week.")
        // What the aim captured on hover: the block's text, exactly as the
        // menu-bar invocation would quote it.
        let aimed = "The sonar demo slipped a week."

        #expect(
            CorrectionAnchoring.resolve(
                quote: aimed, occurrence: 0,
                in: CorrectionAnchoring.blocks(of: before.structured, section: .detailedNotes))
                != nil)
        // Case-insensitive folding is not enough to save a real rewrite: the
        // wording changes too.
        let rewritten = notes("The demo slipped a week; sonar is unaffected.")
        #expect(
            CorrectionAnchoring.resolve(
                quote: aimed, occurrence: 0,
                in: CorrectionAnchoring.blocks(
                    of: rewritten.structured, section: .detailedNotes)) == nil,
            "the instruction would anchor to prose that is gone")
        #expect(after.structured != before.structured)
    }
}

// MARK: - The pending row's truth table

@Suite struct PendingRowStatusTests {
    /// The same mapping covers the failed rewrite: it leaves the row `pending`
    /// and clears the run, which reads as Pending again — the instruction is
    /// still owed.
    @Test("a saved correction reads Pending until a run picks it up, and again if it fails")
    func pendingAndApplying() {
        #expect(
            pendingRowStatus(kind: .understanding, status: .pending, runActive: false)
                == .pending)
        #expect(
            pendingRowStatus(kind: .understanding, status: .pending, runActive: true)
                == .applying)
    }

    @Test("a consumed correction shows no row — the prose is clean again")
    func completionDissolvesTheRow() {
        #expect(pendingRowStatus(kind: .understanding, status: .applied, runActive: false) == nil)
        #expect(pendingRowStatus(kind: .understanding, status: .applied, runActive: true) == nil)
    }

    @Test("margin notes never show a pending row — they apply deterministically")
    func annotationsShowNoRow() {
        for status in [MeetingCorrection.Status.pending, .applied, .stale] {
            for active in [true, false] {
                #expect(pendingRowStatus(kind: .annotation, status: status, runActive: active) == nil)
            }
        }
    }

    /// §3.7: the panel preserves every management capability on its own,
    /// pin-back included — it cannot depend on the orphan tail being on screen
    /// to offer the one way back from a lost anchor.
    @Test("the Changes panel offers pin-back on exactly the rows that lost their anchor")
    func stalePanelRowsOfferPinBack() {
        #expect(changesRowCanPin(row(kind: .annotation, status: .stale)))
        #expect(!changesRowCanPin(row(kind: .annotation, status: .pending)))
        #expect(!changesRowCanPin(row(kind: .understanding, status: .pending)))
        #expect(!changesRowCanPin(row(status: .applied)))
    }

    @Test("AC-13: the Changes panel reports the editor lifecycle exactly")
    func changesPanelVocabulary() {
        let appliedAt = Date(timeIntervalSince1970: 1_770_003_600)
        let applied = row(status: .applied, appliedAt: appliedAt)
        let appliedStatus = changesRowStatus(applied, runActive: false)
        #expect(
            appliedStatus
                == "Applied · \(BlaiseDateFormat.dayMonthYearTime(appliedAt))")
        #expect(!appliedStatus.localizedCaseInsensitiveContains("edit"), "D18 carries no edit count")
        #expect(changesRowStatus(row(), runActive: false) == "Pending")
        #expect(changesRowStatus(row(), runActive: true) == "Applying…")
        #expect(changesRowStatus(row(status: .resolved), runActive: false) == "Resolved")
        #expect(
            changesRowStatus(row(kind: .annotation, status: .stale), runActive: false)
                == "No matching anchor")
    }

    @Test("AC-13: edited and reopened rows show their restamped instruction time")
    func restampedTimestampIsVisible() {
        let original = row(createdAt: Date(timeIntervalSince1970: 1_770_000_000))
        let restamped = row(createdAt: Date(timeIntervalSince1970: 1_770_086_400))
        #expect(changesRowStatus(restamped, runActive: false) == "Pending")
        #expect(changesRowTimestamp(restamped) != changesRowTimestamp(original))
        #expect(
            changesRowTimestamp(restamped)
                == BlaiseDateFormat.dayMonthYearTime(restamped.createdAt))
    }

    @Test("AC-13: a live run disables understanding edit and reopen, not annotation management")
    func activeRunMutationGates() {
        let correction = row()
        let resolvedCorrection = row(status: .resolved)
        let note = row(kind: .annotation, status: .applied)
        #expect(changesRowEditDisabled(correction, runActive: true, busy: false))
        #expect(changesRowResolveDisabled(
            correction, resolved: true, runActive: true, busy: false))
        #expect(!changesRowResolveDisabled(
            correction, resolved: false, runActive: true, busy: false))
        #expect(!changesRowResolveDisabled(
            resolvedCorrection, resolved: true, runActive: false, busy: false))
        #expect(!changesRowEditDisabled(note, runActive: true, busy: false))
        #expect(!changesRowResolveDisabled(note, resolved: true, runActive: true, busy: false))
        #expect(changesRowEditDisabled(note, runActive: false, busy: true))
    }

    @Test("AC-12: the Changes-panel action copy belongs to the editor, not synthesis")
    func notesEditorPanelCopyIsExact() {
        #expect(NotesEditorPanelCopy.actionLabel == "Send to Notes Editor")
        #expect(NotesEditorPanelCopy.busyLabel == "Applying…")
        #expect(!NotesEditorPanelCopy.help.localizedCaseInsensitiveContains("transcript"))
        #expect(!NotesEditorPanelCopy.help.localizedCaseInsensitiveContains("rewrite"))
    }

    /// A note changes nothing and waits on nothing, so it is never pending on
    /// anything: it says whether the notes carry it yet.
    @Test("a margin note is never labelled Pending, run or no run")
    func notesAreNotPending() {
        for active in [true, false] {
            #expect(
                changesRowStatus(row(kind: .annotation, status: .pending), runActive: active)
                    == "Not in the notes yet")
            #expect(
                changesRowStatus(row(kind: .annotation, status: .applied), runActive: active)
                    == "In your notes")
        }
    }

    /// The filter's two halves are exhaustive and disjoint — every row is in
    /// exactly one of them, whichever way it got there.
    @Test("the overview's filter splits the rows into open and resolved")
    func filterSplitsEveryRow() {
        let pending = row(id: "a")
        let consumed = row(id: "b", status: .applied)
        let note = row(id: "c", kind: .annotation, status: .applied)
        let putAway = row(id: "d", kind: .annotation, status: .applied)
        let all = [pending, consumed, note, putAway]
        let resolvedIDs: Set<String> = ["d"]

        let open = changesRows(all, filter: .open, resolvedIDs: resolvedIDs)
        let resolved = changesRows(all, filter: .resolved, resolvedIDs: resolvedIDs)
        #expect(open.map(\.id) == ["a", "c"])
        #expect(resolved.map(\.id) == ["b", "d"], "a consumed correction resolves on its evidence")
        #expect(open.count + resolved.count == all.count)
        #expect(ChangesFilter.open.label == "Open")
        #expect(ChangesFilter.resolved.label == "Resolved")
    }
}

// MARK: - The placement presentation model + the host's rendered output

@MainActor
@Suite struct MarginNotePresentationTests {
    @Test("the Setting decides the mode; the width only decides whether the rail fits")
    func placementModeMapping() {
        let wide = NotesEditingLayout.railMinimumWidth
        #expect(NotesEditingLayout.mode(.inline, width: wide) == .inlineCards)
        #expect(NotesEditingLayout.mode(.inline, width: 320) == .inlineCards)
        #expect(NotesEditingLayout.mode(.margin, width: wide) == .marginRail)
        #expect(NotesEditingLayout.mode(.margin, width: wide - 1) == .marginChip)
    }

    @Test("a card cites its anchor only where adjacency cannot carry it")
    func viewModelPerMode() {
        let rows = [
            row(id: "01A", kind: .annotation, text: "First"),
            row(id: "01B", kind: .annotation, text: "Second"),
        ]
        // One rule, every placement: the note standing against its own line
        // never reprints that line; the one displaced behind it does.
        let models = NotesEditingPresentation.marginNotes(rows)
        #expect(models.map(\.text) == ["First", "Second"])
        #expect(
            !models[0].showsQuote,
            "the card against its own line would print that line twice")
        #expect(models[1].showsQuote, "a note pushed off its own row names its anchor")
    }

    @Test("a displaced card names its anchor, and the screen reader hears it too")
    func inlineCardNamesItsAnchor() {
        let rows = [
            row(id: "01A", kind: .annotation, text: "Earlier"),
            row(id: "01B", kind: .annotation, text: "Ask QA about the crouch case"),
        ]
        let models = NotesEditingPresentation.marginNotes(rows)
        let spoken = InlineNoteCard.accessibilityLabel(models[1], portuguese: false)
        #expect(spoken.contains(models[1].text))
        #expect(spoken.contains(models[1].quotedText), "the anchor is spoken, not only drawn")
        #expect(
            InlineNoteCard.accessibilityLabel(models[1], portuguese: true).hasPrefix("Sua nota"))

        // The card against its own line says only what the reader cannot
        // already read one row up — in the ear as well as on the screen.
        let quiet = InlineNoteCard.accessibilityLabel(models[0], portuguese: false)
        #expect(quiet.contains(models[0].text))
        #expect(!quiet.contains(models[0].quotedText))
    }

    @Test("a lost anchor always names its quote and is flagged")
    func staleNotesAlwaysQuote() {
        let stale = [row(kind: .annotation, status: .stale, text: "Check with the cohort lead")]
        let model = NotesEditingPresentation.marginNotes(stale)[0]
        #expect(model.showsQuote)
        #expect(model.isStale)
    }

    @Test("the teaching callout shows once and never returns after any use")
    func calloutPredicate() {
        #expect(NotesEditingSettings.showEditingCallout(seen: false, hasNotes: true))
        #expect(!NotesEditingSettings.showEditingCallout(seen: true, hasNotes: true))
        #expect(!NotesEditingSettings.showEditingCallout(seen: false, hasNotes: false))
    }

    /// The callout hangs off the first ordinary paragraph of the summary. Its
    /// second input is that paragraph's existence — a constant would put a
    /// teaching banner in an empty section, pointing at nothing.
    @Test("the callout's own input is whether there is a paragraph to teach on")
    func calloutHasNotesComesFromTheBlocks() {
        func hasParagraph(_ summary: String) -> Bool {
            MarkdownBlocks.parse(summary).contains { $0.kind == .paragraph }
        }
        #expect(hasParagraph("The cohort review went well."))
        #expect(!hasParagraph(""))
        #expect(!hasParagraph("   \n\n  "))
        #expect(!hasParagraph("# Resumo"), "a heading is not something to teach on")
        #expect(
            !NotesEditingSettings.showEditingCallout(seen: false, hasNotes: hasParagraph("")),
            "an empty summary offers no callout")
    }

    /// The index the pane draws the callout at: the FIRST ordinary paragraph of
    /// the summary, whatever stands above it. This is the resolver alone — that
    /// the summary section actually renders the banner at this index is a
    /// separate assertion, on the pane's own source, below.
    @Test("the callout's anchor resolves to the first ordinary paragraph of the summary")
    func calloutAnchorResolvesToItsParagraph() throws {
        #expect(NotesEditingCallout.text == "Select text to correct it, or add a note.")
        let blocks = MarkdownBlocks.parse(
            """
            # Resumo

            - a list item

            The cohort review went well.

            A second paragraph nobody teaches on.
            """)
        let anchor = try #require(
            NotesEditingCallout.anchorIndex(seen: false, summaryBlocks: blocks))
        #expect(anchor == blocks.firstIndex { $0.kind == .paragraph })
        #expect(
            String(blocks[anchor].text.characters) == "The cohort review went well.",
            "the heading and the list are not what the line teaches on")
    }

    @Test("a summary with no paragraph anchors — and so draws — no callout")
    func calloutWithoutAnAnchor() {
        #expect(
            NotesEditingCallout.anchorIndex(
                seen: false, summaryBlocks: MarkdownBlocks.parse("# Resumo")) == nil)
        #expect(
            NotesEditingCallout.anchorIndex(seen: false, summaryBlocks: []) == nil,
            "an empty summary offers no callout")
    }

    /// The effect the ✕'s action has, driven on the real holder: the shipped
    /// retire path flips the held flag, and the anchor the pane draws from is
    /// gone from that moment on, for every summary. That the ✕ IS this action
    /// is asserted on the pane's source, below — a test cannot press it.
    @Test("the retire path the ✕ calls flips the flag, and the anchor never returns")
    func calloutRetirePathRemovesTheAnchor() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("blaise-callout-tests-\(UUID().uuidString)")
        let settings = SettingsStore(database: try BlaiseDatabase(rootURL: root))
        let holder = NotesPresentationHolder()
        let blocks = MarkdownBlocks.parse("The cohort review went well.")
        #expect(
            NotesEditingCallout.anchorIndex(
                seen: holder.editingCalloutSeen, summaryBlocks: blocks) == 0)

        holder.retireEditingCallout(in: settings)

        #expect(holder.editingCalloutSeen)
        #expect(
            NotesEditingCallout.anchorIndex(
                seen: holder.editingCalloutSeen, summaryBlocks: blocks) == nil)
    }

    /// The control the test above cannot press: the pane's body needs an
    /// `AppEnvironment` to lay out, so the binding is read from its source. The
    /// ✕ glyph and the retire call must belong to ONE button — the glyph drawn
    /// between that button's `label:` and the modifiers that close it, the call
    /// in the action it runs. Co-location is not enough: an inert ✕ beside a
    /// separate hidden button owning the retire call would read the same to any
    /// whole-body search.
    @Test("the ✕ the callout draws is the control that runs the retire path")
    func calloutDismissIsWiredToRetire() throws {
        let source = try meetingDetailSource()
        let declared = try declaration("editingCallout", endingBefore: "selectionBar", in: source)
        // The declaration's own body ends where the next member begins.
        let body = declared[..<(try #require(declared.range(of: "@ViewBuilder")).lowerBound)]
        #expect(body.contains("NotesEditingCallout.text"))

        // Exactly one control, either spelling, so the ✕ cannot be the inert
        // half of a pair.
        let text = String(body)
        let buttons =
            (text.components(separatedBy: "Button {").count - 1)
            + (text.components(separatedBy: "Button(").count - 1)
        #expect(buttons == 1)
        let actionStart = try #require(body.range(of: "Button {")).upperBound
        let labelMarker = try #require(
            body.range(of: "} label:", range: actionStart..<body.endIndex))
        let action = body[actionStart..<labelMarker.lowerBound]
        // The label ends where the button's own modifiers begin, so a glyph
        // drawn by a LATER sibling control cannot stand in for this one's.
        let labelEnd = try #require(
            body.range(of: ".buttonStyle(", range: labelMarker.upperBound..<body.endIndex))
        let label = body[labelMarker.upperBound..<labelEnd.lowerBound]

        #expect(action.contains("retireEditingCallout(in: appEnv.settings)"))
        #expect(
            label.contains("xmark.circle"),
            "the glyph is drawn by the label of the button whose action retires")
        #expect(
            !action.contains("xmark.circle"),
            "the glyph belongs to that button's label, not to its action")
    }

    /// Where the pane draws the callout, read from its source: inside the
    /// summary section's own `ForEach`, keyed on the resolved anchor — so the
    /// banner is attached to the block the resolver named, not to a fixed
    /// position and not to the document above the sections.
    @Test("the summary section renders the callout at the resolved anchor, inside its ForEach")
    func calloutIsRenderedAtItsAnchor() throws {
        let source = try meetingDetailSource()
        let sections = try #require(source.range(of: "private func structuredSections("))
        let nextMember = try #require(
            source.range(
                of: "private func editableBlock<", range: sections.upperBound..<source.endIndex))
        let body = source[sections.upperBound..<nextMember.lowerBound]

        // The summary's own loop: from its ForEach to the section that follows.
        let loop = try #require(body.range(of: "ForEach(Array(summaryBlocks.enumerated())"))
        let afterLoop = try #require(
            body.range(of: "let userActionItems", range: loop.upperBound..<body.endIndex))
        let summaryLoop = body[loop.upperBound..<afterLoop.lowerBound]

        #expect(
            summaryLoop.contains("if index == calloutAnchor { editingCallout }"),
            "the banner is drawn in the summary loop, keyed on the resolved anchor")
        #expect(
            !summaryLoop.contains("ForEach("),
            "the banner is drawn in the block loop itself, not in a second loop")
        #expect(
            body.contains("let calloutAnchor = NotesEditingCallout.anchorIndex("),
            "and the anchor the loop reads IS the resolver's answer, not a literal")
    }

    /// The host swap must not cost the search highlighting: asserted on what the
    /// host actually renders, not on `SearchHighlight.applied` alone — that
    /// would pass even if the host dropped the runs on the way to the screen.
    @Test("search-highlight runs survive in the selection-capable host's rendered output")
    func searchHighlightSurvivesTheHost() {
        let source = MarkdownBlocks.parse(
            "O **warp core** foi entregue, detalhes em https://quollharbor.example/sonar hoje.")[0]
            .text
        let rendered = NotesBlockText.displayText(source: source, terms: ["entregue"])

        #expect(String(rendered.characters) == String(source.characters))
        let matched = rendered.runs.filter { String(rendered[$0.range].characters) == "entregue" }
        #expect(matched.count == 1)
        #expect(matched.first?.underlineStyle == .single)
        #expect(matched.first?.foregroundColor != nil)
        #expect(matched.first?.backgroundColor != nil)
        // …and the parser's own attributes are still there underneath.
        let bold = rendered.runs.filter {
            $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        }
        #expect(bold.contains { String(rendered[$0.range].characters) == "warp core" })
        #expect(rendered.runs.contains { $0.link != nil })
    }

    /// §3.3: a whole-block invocation washes the block, a selection washes the
    /// exact span. The span wash rides the text the host renders, so it can
    /// cover a range instead of the row.
    @Test("a selection-scoped composer washes exactly its span, and nothing else")
    func selectionWashesTheSpanOnly() {
        let source = MarkdownBlocks.parse(
            "The cohort review ran long and the sonar demo slipped a week.")[0].text
        let span = "the sonar demo slipped"
        let rendered = NotesBlockText.displayText(source: source, terms: [], washedSpan: SelectedSpan(text: span))

        #expect(String(rendered.characters) == String(source.characters))
        let washed = rendered.runs.filter { $0.backgroundColor != nil }
        #expect(washed.map { String(rendered[$0.range].characters) }.joined() == span)

        // A whole-block invocation passes no span: the block's own wash paints
        // it, and the text carries none.
        let plain = NotesBlockText.displayText(source: source, terms: [])
        #expect(plain.runs.allSatisfy { $0.backgroundColor == nil })
    }

    /// A block can repeat the same words. The wash is the cue that says which
    /// passage the instruction is about, so it has to land on the range the
    /// user dragged over — a first-match lookup paints the wrong one.
    @Test("selecting the second of two identical phrases washes the second")
    func spanWashFollowsTheSelectedOccurrence() {
        let source = MarkdownBlocks.parse(
            "Ship the sonar demo; confirm the sonar demo after the review.")[0].text
        let plain = String(source.characters)
        let phrase = "the sonar demo"
        // Where the SECOND one starts, and what the host reports for a drag
        // that begins there.
        let secondStart = plain.range(
            of: phrase, range: plain.range(of: "; ")!.upperBound..<plain.endIndex)!
        let offset = plain.distance(from: plain.startIndex, to: secondStart.lowerBound)
        let span = SelectedSpan(
            text: phrase, occurrence: spanOccurrence(of: phrase, startingAt: offset, in: plain))
        #expect(span.occurrence == 1)

        let rendered = NotesBlockText.displayText(source: source, terms: [], washedSpan: span)
        #expect(String(rendered.characters) == plain)
        let washed = rendered.runs.filter { $0.backgroundColor != nil }
        #expect(washed.map { String(rendered[$0.range].characters) }.joined() == phrase)
        #expect(
            rendered.characters.distance(
                from: rendered.startIndex, to: washed[0].range.lowerBound) == offset,
            "the second occurrence, not the first")

        // What a first-match lookup does with the same selection: the wrong
        // phrase, with nothing on screen to say so.
        let firstMatch = NotesBlockText.displayText(
            source: source, terms: [], washedSpan: SelectedSpan(text: phrase))
        let painted = firstMatch.runs.filter { $0.backgroundColor != nil }
        #expect(
            firstMatch.characters.distance(
                from: firstMatch.startIndex, to: painted[0].range.lowerBound) < offset)
    }

    @Test("an occurrence the rewritten block no longer has falls back to its last")
    func spanWashClampsToTheLastOccurrence() {
        let source = MarkdownBlocks.parse("Ship the sonar demo after the review.")[0].text
        let rendered = NotesBlockText.displayText(
            source: source, terms: [],
            washedSpan: SelectedSpan(text: "the sonar demo", occurrence: 3))
        let washed = rendered.runs.filter { $0.backgroundColor != nil }
        #expect(washed.map { String(rendered[$0.range].characters) }.joined() == "the sonar demo")
    }

    @Test("a span the block no longer contains washes nothing rather than guessing")
    func staleSpanWashesNothing() {
        let source = MarkdownBlocks.parse("The review overran its slot.")[0].text
        let rendered = NotesBlockText.displayText(
            source: source, terms: [], washedSpan: SelectedSpan(text: "the sonar demo slipped"))
        #expect(rendered.runs.allSatisfy { $0.backgroundColor == nil })
    }

    @Test("the span wash and the search highlight coexist on the same block")
    func spanWashKeepsTheSearchHighlight() {
        let source = MarkdownBlocks.parse(
            "O **warp core** foi entregue, detalhes em https://quollharbor.example/sonar hoje.")[0]
            .text
        let rendered = NotesBlockText.displayText(
            source: source, terms: ["entregue"], washedSpan: SelectedSpan(text: "foi entregue"))
        let matched = rendered.runs.filter { $0.underlineStyle == .single }
        #expect(matched.map { String(rendered[$0.range].characters) } == ["entregue"])
        let washed = rendered.runs.filter { $0.backgroundColor != nil }
        #expect(washed.map { String(rendered[$0.range].characters) }.joined() == "foi entregue")
    }

    @Test("the block's search accessibility hint survives the host swap")
    func accessibilityHintSurvives() {
        let source = MarkdownBlocks.parse("A revisão já está pronta.")[0].text
        #expect(
            NotesBlockText.searchHint(source: source, terms: ["revisão"])
                == "Contains the current search match")
        #expect(NotesBlockText.searchHint(source: source, terms: ["berthing"]).isEmpty)
    }

    @Test("an annotated passage says how many margin notes it carries")
    func annotatedPassageStatesItsNoteCount() {
        #expect(NotesBlockText.annotationHint(0).isEmpty)
        #expect(NotesBlockText.annotationHint(1) == "Has 1 margin note")
        #expect(NotesBlockText.annotationHint(3) == "Has 3 margin notes")
    }

    @Test("the passage's hint carries the note count beside the search state")
    func hintCarriesCountAndSearchState() {
        let source = MarkdownBlocks.parse("A revisão já está pronta.")[0].text
        #expect(NotesBlockText.hint(source: source, terms: [], annotations: 0).isEmpty)
        #expect(
            NotesBlockText.hint(source: source, terms: [], annotations: 2) == "Has 2 margin notes")
        #expect(
            NotesBlockText.hint(source: source, terms: ["revisão"], annotations: 1)
                == "Has 1 margin note. Contains the current search match")
        #expect(
            NotesBlockText.hint(source: source, terms: ["revisão"], annotations: 0)
                == "Contains the current search match")
    }
}

// MARK: - The banners the surface speaks with

private struct TestRemintFailure: Error, CustomStringConvertible {
    var description = "the re-mint threw"
    var localizedDescription: String { description }
}

@Suite struct NotesEditingFeedbackTests {
    @Test("a note written during a run says it appears when that run finishes")
    func noteDuringRunMessage() {
        #expect(
            noteFeedback(remintRefused: false, runActive: true)
                == "Note saved — it appears in the notes when the current run finishes.")
        #expect(noteFeedback(remintRefused: false, runActive: false) == nil)
        #expect(
            noteFeedback(remintRefused: true, runActive: false)?
                .contains("when processing completes") == true)
    }

    /// The delete commits before the re-mint that publishes it can throw, so
    /// the stored outcome — not the transient error — has to drive the message.
    @Test("a committed delete is reported truthfully even when the re-mint throws")
    func committedDeleteIsReportedTruthfully() {
        let gone = deleteFeedback(rowSurvived: false, error: TestRemintFailure())
        #expect(gone.hasPrefix("Deleted"))
        #expect(!gone.contains("Could not delete"))
        #expect(deleteFeedback(rowSurvived: true, error: TestRemintFailure())
            .hasPrefix("Could not delete"))
    }

    /// The delete is adjudicated by reading the store back. A read that FAILS
    /// says nothing about the row — reporting it as a delete would tell the
    /// user an instruction is gone while it may still be there, waiting to
    /// steer the next rewrite.
    @Test("an unreadable store is reported as an unknown outcome, never as a delete")
    func unverifiableDeleteIsNotReportedAsDeleted() {
        let unknown = deleteFeedback(rowSurvived: nil, error: TestRemintFailure())
        #expect(!unknown.hasPrefix("Deleted"))
        #expect(unknown.contains("Could not confirm"))
        // …and it points at something the user can actually do. Not the
        // Changes chip: the same failed read empties the row list the chip
        // hangs off, so it is gone from the pane at that moment.
        #expect(unknown.contains("reopen the meeting"))
        #expect(!unknown.contains("Changes"))
    }
}

// MARK: - The entry gate and the routing seams

@Suite struct NotesEditingEntryTests {
    @Test("the gate closes the correction path only — a margin note is not an instruction")
    func gatePerAction() {
        #expect(NotesEditingEntry.allowed(
            .correct, correctionEnabled: true, engineCanEditNotes: true))
        #expect(!NotesEditingEntry.allowed(
            .correct, correctionEnabled: false, engineCanEditNotes: true))
        #expect(NotesEditingEntry.allowed(
            .note, correctionEnabled: true, engineCanEditNotes: true))
        #expect(NotesEditingEntry.allowed(
            .note, correctionEnabled: false, engineCanEditNotes: true))
    }

    @Test("a closed correction gate carries its reason; the note path never has one")
    func disabledReasonIsReachable() {
        let reason = NotesEditingEntry.disabledReason(.correct, correctionEnabled: false)
        #expect(reason?.contains("Updating notes") == true)
        #expect(NotesEditingEntry.disabledReason(.correct, correctionEnabled: true) == nil)
        #expect(NotesEditingEntry.disabledReason(.note, correctionEnabled: false) == nil)
    }

    @Test("a whole-block invocation anchors to the block; a selection anchors to the span")
    func targetAnchoring() {
        let block = "Quoll Harbor's onboarding tested well with the new cohort."
        let whole = NotesEditingEntry.target(
            .correct, section: .summary, anchorID: "notes-summary-0", blockText: block,
            occurrence: 2)
        #expect(whole.quotedText == block)
        #expect(whole.isWholeBlock)
        #expect(whole.occurrence == 2)

        let span = NotesEditingEntry.target(
            .correct, section: .summary, anchorID: "notes-summary-0", blockText: block,
            occurrence: 2, selection: SelectedSpan(text: "onboarding tested well"))
        #expect(span.quotedText == "onboarding tested well")
        #expect(!span.isWholeBlock)
        #expect(span.blockText == block, "the block travels along so the occurrence can be recomputed")
    }

    /// Which of a block's equal phrases the user selected travels with the
    /// target, so the composer's wash paints that one. The DURABLE anchor is
    /// unaffected — it is quote + section + block occurrence, and a position
    /// inside one block is not something it can express.
    @Test("a selection of a repeated phrase carries the occurrence it was taken from")
    func targetCarriesTheSelectedOccurrence() {
        let block = "Ship the sonar demo; confirm the sonar demo after the review."
        let second = NotesEditingEntry.target(
            .correct, section: .detailedNotes, anchorID: "notes-detailed-0", blockText: block,
            occurrence: 0, selection: SelectedSpan(text: "the sonar demo", occurrence: 1))
        #expect(second.quotedText == "the sonar demo")
        #expect(!second.isWholeBlock)
        #expect(second.spanOccurrence == 1)

        let first = NotesEditingEntry.target(
            .correct, section: .detailedNotes, anchorID: "notes-detailed-0", blockText: block,
            occurrence: 0, selection: SelectedSpan(text: "the sonar demo", occurrence: 0))
        #expect(first.spanOccurrence == 0)

        // A drag that swept up a trailing space still names the phrase it swept.
        let padded = NotesEditingEntry.target(
            .correct, section: .detailedNotes, anchorID: "notes-detailed-0", blockText: block,
            occurrence: 0, selection: SelectedSpan(text: "the sonar demo ", occurrence: 0))
        #expect(padded.quotedText == "the sonar demo")
        #expect(padded.spanOccurrence == 1, "the trim does not move which phrase was selected")

        // An action item's host renders the owner-prefixed line, so the space
        // the wash paints in is not `blockText`: the swept selection has to
        // name the phrase the user dragged over in the RENDERED text.
        let itemText = "Mira ships the Quoll Harbor build, then Mira files the report."
        let rendered = "Mira: \(itemText)"
        let actionItem = NotesEditingEntry.target(
            .correct, section: .actionItem, anchorID: "notes-action-0", blockText: itemText,
            occurrence: 0, selection: SelectedSpan(text: " Mira", occurrence: 1),
            hostText: rendered)
        #expect(actionItem.quotedText == "Mira")
        #expect(
            actionItem.spanOccurrence == 2,
            "the occurrence is counted in the host-rendered line, where the owner prefix is itself an occurrence of the selected phrase")
        // What the wash consumes: that index, counted in the rendered line.
        // The phrase the user swept is the last "Mira" there — the owner
        // prefix and the item's first word precede it.
        var offsets: [Int] = []
        var cursor = rendered.startIndex
        while let found = rendered.range(of: "Mira", range: cursor..<rendered.endIndex) {
            offsets.append(rendered.distance(from: rendered.startIndex, to: found.lowerBound))
            cursor = rendered.index(after: found.lowerBound)
        }
        #expect(offsets.count == 3)
        #expect(
            offsets[actionItem.spanOccurrence] == offsets.last,
            "the wash lands on the phrase the user selected")

        // A whole-block invocation has no span position to carry.
        let whole = NotesEditingEntry.target(
            .correct, section: .detailedNotes, anchorID: "notes-detailed-0", blockText: block,
            occurrence: 0)
        #expect(whole.spanOccurrence == 0)

        // The stored anchor resolves to the paragraph the user acted on, as it
        // did before: the quote is the same either way.
        let blocks = [block]
        let stored = CorrectionAnchoring.occurrence(
            forQuote: second.quotedText, takenFrom: block, blockOccurrence: 0, in: blocks)
        #expect(
            CorrectionAnchoring.resolve(quote: second.quotedText, occurrence: stored, in: blocks)?
                .blockIndex == 0)
    }

    @Test("a selection the block does not contain falls back to the whole block")
    func unusableSelectionFallsBack() {
        let block = "Ship date holds at 21 March."
        for selection in ["", "   ", "a sentence from another block"] {
            let target = NotesEditingEntry.target(
                .note, section: .decision, anchorID: "notes-decision-0", blockText: block,
                occurrence: 0, selection: SelectedSpan(text: selection))
            #expect(target.quotedText == block)
            #expect(target.isWholeBlock)
        }
    }

    @Test("the right-click menu reaches the same target the hover group builds")
    func contextMenuRoutesLikeTheHoverGroup() {
        let block = "Cut the tide mini-game from the March build."
        var opened: [EditingTarget] = []
        #expect(
            notesEditingContextMenuAction(
                .correct, section: .decision, blockText: block, occurrence: 1,
                blockID: "notes-decision-3", selection: ("notes-decision-3", SelectedSpan(text: "tide mini-game")),
                correctionEnabled: true, engineCanEditNotes: true,
                begin: { opened.append($0) }))
        // The hover group's own construction, for the same invocation.
        let hover = NotesEditingEntry.target(
            .correct, section: .decision, anchorID: "notes-decision-3", blockText: block,
            occurrence: 1, selection: SelectedSpan(text: "tide mini-game"))
        #expect(opened == [hover])
    }

    @Test("a selection in another block never anchors this block's right-click")
    func contextMenuIgnoresAForeignSelection() {
        let block = "Cut the tide mini-game from the March build."
        var opened: [EditingTarget] = []
        notesEditingContextMenuAction(
            .note, section: .decision, blockText: block, occurrence: 1,
            blockID: "notes-decision-3", selection: ("notes-summary-1", SelectedSpan(text: "the new cohort")),
            correctionEnabled: true, engineCanEditNotes: true,
            begin: { opened.append($0) })
        #expect(opened.count == 1)
        #expect(opened[0].quotedText == block)
        #expect(opened[0].isWholeBlock)
    }

    /// The run that reopens the correction gate is the same event that rewrites
    /// the prose. If the composer's identity were its block's text, that run
    /// would tear the composer out of the tree and take the typed draft with
    /// it — at exactly the moment §3.2 promises the commit re-enables.
    @Test("an open composer survives the re-synthesis that rewrites its block")
    func composerIdentitySurvivesARewrite() {
        let openedOn = "The cohort review ran long."
        // What the same block renders after the run: prose phrasing is not
        // byte-stable across a re-synthesis.
        let rewrittenTo = "The review overran its slot."
        let opened = NotesEditingEntry.target(
            .correct, section: .detailedNotes, anchorID: "notes-detailed-2",
            blockText: openedOn, occurrence: 0)

        #expect(opened.blockText == openedOn)
        #expect(openedOn != rewrittenTo, "the block the composer hangs under changed")
        #expect(
            composerBelongs(opened, toBlockWith: "notes-detailed-2"),
            "identity is the anchor, so the composer and its draft stay in the tree")
        #expect(!composerBelongs(opened, toBlockWith: "notes-detailed-3"))
        #expect(!composerBelongs(nil, toBlockWith: "notes-detailed-2"))
    }

    /// Block ids are positional, and a full re-synthesis can return FEWER
    /// blocks than the one the composer opened on. §3.2 promises the draft is
    /// retained across that run, so the composer cannot depend on its block
    /// still being there: it presents off its retained quote instead.
    @Test("a rewrite that removes the composing block leaves the composer standing")
    func composerSurvivesItsBlockLeavingTheNotes() {
        var notes = NotesStructured(
            summary: "The cohort review went well.",
            detailedNotes: """
                Alpha shipped on time.

                The sonar demo slipped a week.

                Beta slipped a week.
                """,
            decisions: [], actionItems: [], userActionItems: [])
        // Opened on the LAST detailed block.
        let opened = NotesEditingEntry.target(
            .correct, section: .detailedNotes, anchorID: NotesBlockAnchor.detailed(2),
            blockText: "Beta slipped a week.", occurrence: 0)
        #expect(!composerIsOrphaned(opened, renderedAnchorIDs: NotesBlockAnchor.rendered(in: notes)))

        // The run merges two paragraphs into one: the id it opened on is gone.
        notes.detailedNotes = """
            Alpha shipped on time.

            The sonar demo and Beta both slipped a week.
            """
        let rebuilt = NotesBlockAnchor.rendered(in: notes)
        #expect(!rebuilt.contains(NotesBlockAnchor.detailed(2)))
        #expect(composerIsOrphaned(opened, renderedAnchorIDs: rebuilt))

        // What stays with it: the quote it names, the reason its commit is
        // closed while the run holds the meeting, and the commit itself once
        // the gate reopens.
        #expect(opened.quotedText == "Beta slipped a week.")
        #expect(
            NotesEditingEntry.disabledReason(.correct, correctionEnabled: false)?
                .contains("Updating notes") == true)
        var committed: [EditingTarget] = []
        #expect(
            notesEditingCommitAction(
                opened, correctionEnabled: true, engineCanEditNotes: true,
                commit: { committed.append($0) }))
        #expect(committed == [opened])
    }

    @Test("a rewrite that only rephrases the block keeps the composer under it")
    func composerStaysWhereItsBlockSurvives() {
        var notes = NotesStructured(
            summary: "The cohort review went well.",
            detailedNotes: "Alpha shipped on time.\n\nThe sonar demo slipped a week.",
            decisions: [], actionItems: [], userActionItems: [])
        let opened = NotesEditingEntry.target(
            .correct, section: .detailedNotes, anchorID: NotesBlockAnchor.detailed(1),
            blockText: "The sonar demo slipped a week.", occurrence: 0)
        notes.detailedNotes = "Alpha shipped on time.\n\nThe sonar demo slipped by a week."
        #expect(!composerIsOrphaned(opened, renderedAnchorIDs: NotesBlockAnchor.rendered(in: notes)))
        #expect(!composerIsOrphaned(nil, renderedAnchorIDs: []))
    }

    @Test("every block the pane renders has an id, and no two sections share one")
    func renderedAnchorIDsCoverEverySection() {
        let notes = NotesStructured(
            summary: "The cohort review went well.\n\nQuoll Harbor onboarding is next.",
            detailedNotes: "The sonar demo slipped a week.",
            decisions: ["Ship the warp core in March."],
            actionItems: [
                ActionItem(owner: "Platform", text: "Book the sonar pass."),
                ActionItem(owner: "Platform", text: "   "),
            ],
            userActionItems: [])
        let ids = NotesBlockAnchor.rendered(in: notes)

        #expect(Set(ids).count == ids.count, "section prefixes keep the ids distinct")
        #expect(ids.contains(NotesBlockAnchor.summary(1)))
        #expect(ids.contains(NotesBlockAnchor.decision(0)))
        #expect(ids.contains(NotesBlockAnchor.detailed(0)))
        #expect(
            !ids.contains(NotesBlockAnchor.actionItem(1)),
            "a blank action item never renders, so it has no block to compose on")
        #expect(ids.contains(NotesBlockAnchor.actionItem(0)))
    }

    @Test("a run that starts while the composer is open refuses the commit and keeps the draft")
    func commitSeamRereadsTheGate() {
        let correction = NotesEditingEntry.target(
            .correct, section: .summary, anchorID: "notes-summary-0",
            blockText: "The cohort review went well.", occurrence: 0)
        var committed: [EditingTarget] = []
        // Opened before the run: the composer is on screen with a draft in it.
        #expect(
            !notesEditingCommitAction(
                correction, correctionEnabled: false, engineCanEditNotes: true,
                commit: { committed.append($0) }))
        #expect(committed.isEmpty, "nothing is closed and nothing is saved")
        // The run finishes, the gate reopens, the same draft commits.
        #expect(
            notesEditingCommitAction(
                correction, correctionEnabled: true, engineCanEditNotes: true,
                commit: { committed.append($0) }))
        #expect(committed == [correction])

        // A margin note is not an instruction and is never run-gated.
        let note = NotesEditingEntry.target(
            .note, section: .summary, anchorID: "notes-summary-0",
            blockText: "The cohort review went well.", occurrence: 0)
        #expect(
            notesEditingCommitAction(
                note, correctionEnabled: false, engineCanEditNotes: true,
                commit: { committed.append($0) }))
        #expect(committed.map(\.kind) == [.correct, .note])
    }

    @Test("the right-click menu closes Correct… on a run and leaves Add Note… open")
    func contextMenuFollowsTheGate() {
        let block = "Cut the tide mini-game from the March build."
        var opened: [EditingTarget] = []
        #expect(
            !notesEditingContextMenuAction(
                .correct, section: .decision, blockText: block, occurrence: 1,
                blockID: "notes-decision-3", selection: nil, correctionEnabled: false,
                engineCanEditNotes: true, begin: { opened.append($0) }))
        #expect(opened.isEmpty)
        #expect(
            notesEditingContextMenuAction(
                .note, section: .decision, blockText: block, occurrence: 1,
                blockID: "notes-decision-3", selection: nil, correctionEnabled: false,
                engineCanEditNotes: true, begin: { opened.append($0) }))
        #expect(opened.map(\.kind) == [.note])
    }
}

// MARK: - The surface under an engine that cannot edit notes

/// A summarization engine that also edits notes, and one that only summarizes —
/// the distinction the notes surface reads before it offers the correction path.
private struct FakeEditingSummarizer: SummarizationEngine, NotesEditingEngine {
    let id: String
    let displayName = "Vexatron cloud summarizer"
    let kind: EngineKind = .cloud
    let loadProfile: EngineLoadProfile = .lightweight
    let costDescriptor: EngineCostDescriptor? = nil
    let configDescriptors: [EngineConfigDescriptor] = []

    func availability() async -> EngineAvailability { .available }

    func generateNotes(
        _ request: NotesRequest, purpose: CloudSpendPurpose
    ) async throws -> NotesResult {
        throw EngineError.permanent("not used by this suite")
    }

    func generateDigest(
        _ request: DigestRequest, purpose: CloudSpendPurpose
    ) async throws -> DigestResult {
        throw EngineError.permanent("not used by this suite")
    }

    func editNotes(
        _ request: NotesEditorRequest, purpose: CloudSpendPurpose
    ) async throws -> NotesEditorResult {
        throw EngineError.permanent("not used by this suite")
    }
}

private struct FakeSummarizerWithoutEditor: SummarizationEngine {
    let id: String
    let displayName = "Quoll Harbor local summarizer"
    let kind: EngineKind = .local
    let loadProfile: EngineLoadProfile = .lightweight
    let costDescriptor: EngineCostDescriptor? = nil
    let configDescriptors: [EngineConfigDescriptor] = []

    func availability() async -> EngineAvailability { .available }

    func generateNotes(
        _ request: NotesRequest, purpose: CloudSpendPurpose
    ) async throws -> NotesResult {
        throw EngineError.permanent("not used by this suite")
    }

    func generateDigest(
        _ request: DigestRequest, purpose: CloudSpendPurpose
    ) async throws -> DigestResult {
        throw EngineError.permanent("not used by this suite")
    }
}

@Suite struct NotesEditingEngineCapabilityTests {
    private let editor = FakeEditingSummarizer(id: "vexatron-cloud")
    private let plain = FakeSummarizerWithoutEditor(id: "quoll-local")

    private func registry() throws -> EngineRegistry {
        try EngineRegistry(asr: [], summarization: [editor, plain])
    }

    @Test("AC-13: the capability is derived from the live selection, never stored")
    func capabilityFollowsTheSelection() throws {
        let registry = try registry()
        #expect(notesEditingEngineCanEdit(
            selectedSummarizationID: editor.id, registry: registry))
        // The same registry, the other selection: no relaunch, no cached flag.
        #expect(!notesEditingEngineCanEdit(
            selectedSummarizationID: plain.id, registry: registry))
    }

    @Test("AC-13: the surface reads the capability of the engine a run would actually resolve")
    func capabilityFollowsTheResolvedSubstitute() throws {
        // An id that is no longer registered resolves to a substitute, and this
        // registry's substitute edits notes — so the pass would run and the
        // surface must offer the correction path.
        #expect(notesEditingEngineCanEdit(
            selectedSummarizationID: "not-registered", registry: try registry()))
        // The same unregistered id where the substitute cannot edit: the pass
        // would refuse, and the surface says so.
        #expect(!notesEditingEngineCanEdit(
            selectedSummarizationID: "not-registered",
            registry: try EngineRegistry(asr: [], summarization: [plain])))
        // Nothing to resolve at all.
        #expect(!notesEditingEngineCanEdit(
            selectedSummarizationID: editor.id,
            registry: try EngineRegistry(asr: [], summarization: [])))
    }

    /// Corrections left pending under an engine that could not edit them have no
    /// timer waiting, so the summarization picker is what makes them live again.
    /// That wiring is one line and nothing else observes it.
    @Test("§9: the summarization picker re-arms pending corrections after it selects")
    func theSummarizationPickerRearmsPendingCorrections() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources", isDirectory: true)
        let settingsView = try String(
            contentsOf: sources.appendingPathComponent("BlaiseApp/SettingsView.swift"),
            encoding: .utf8)
        let branch = try #require(settingsView.range(of: "if slot == .summarization {"))
        #expect(settingsView[branch.upperBound...].prefix(200).contains(
            ".rearmPendingNotesEditorActivationsIfEngineCanEdit()"))
    }

    @Test("AC-13: a non-editing engine withdraws the correction path and keeps the note path")
    func correctionPathIsAbsentWithoutAnEditingEngine() {
        #expect(!NotesEditingEntry.offered(.correct, engineCanEditNotes: false))
        #expect(NotesEditingEntry.offered(.note, engineCanEditNotes: false))
        #expect(NotesEditingEntry.offered(.correct, engineCanEditNotes: true))
        // Not merely disabled: no run is holding the meeting here.
        #expect(!NotesEditingEntry.allowed(
            .correct, correctionEnabled: true, engineCanEditNotes: false))
        #expect(NotesEditingEntry.allowed(
            .note, correctionEnabled: true, engineCanEditNotes: false))
    }

    @Test("AC-13: every routing seam refuses a correction and still takes a note")
    func seamsFollowTheCapability() {
        let block = "Cut the tide mini-game from the March build."
        var opened: [EditingTarget] = []
        #expect(
            !notesEditingContextMenuAction(
                .correct, section: .decision, blockText: block, occurrence: 1,
                blockID: "notes-decision-3", selection: nil, correctionEnabled: true,
                engineCanEditNotes: false, begin: { opened.append($0) }))
        #expect(
            notesEditingContextMenuAction(
                .note, section: .decision, blockText: block, occurrence: 1,
                blockID: "notes-decision-3", selection: nil, correctionEnabled: true,
                engineCanEditNotes: false, begin: { opened.append($0) }))
        #expect(opened.map(\.kind) == [.note])

        var committed: [EditingTarget] = []
        let correction = NotesEditingEntry.target(
            .correct, section: .decision, anchorID: "notes-decision-3", blockText: block,
            occurrence: 1)
        #expect(
            !notesEditingCommitAction(
                correction, correctionEnabled: true, engineCanEditNotes: false,
                commit: { committed.append($0) }))
        #expect(committed.isEmpty)
        let note = NotesEditingEntry.target(
            .note, section: .decision, anchorID: "notes-decision-3", blockText: block,
            occurrence: 1)
        #expect(
            notesEditingCommitAction(
                note, correctionEnabled: true, engineCanEditNotes: false,
                commit: { committed.append($0) }))
        #expect(committed.map(\.kind) == [.note])
    }

    @Test("AC-13: the send action stands only on a pending row, in both placements")
    func sendOfferedFollowsPendingRowsAndCapability() {
        let pending = row(id: "01ROWPENDING00000000000000", status: .pending)
        let applied = row(
            id: "01ROWAPPLIED00000000000000", status: .applied,
            appliedAt: Date(timeIntervalSince1970: 1_770_000_100))
        let resolved = row(id: "01ROWRESOLVED0000000000000", status: .resolved)
        let annotation = row(
            id: "01ROWNOTE00000000000000000", kind: .annotation, status: .pending)

        #expect(notesEditorSendOffered(
            rows: [applied, pending], engineCanEditNotes: true))
        #expect(!notesEditorSendOffered(
            rows: [applied, resolved], engineCanEditNotes: true))
        #expect(!notesEditorSendOffered(rows: [annotation], engineCanEditNotes: true))
        #expect(!notesEditorSendOffered(rows: [], engineCanEditNotes: true))
        // The engine that cannot edit withdraws BOTH placements.
        #expect(!notesEditorSendOffered(
            rows: [applied, pending], engineCanEditNotes: false))
    }

    @Test("AC-13: the send action stands on its own line under the provenance row")
    func sendLinePlacementIsWiredToTheOneEntry() throws {
        let detail = try meetingDetailSource()
        let sendLine = try declaration("notesEditorSendLine", endingBefore: "provenanceStamp", in: detail)
        // Its own placement: the shared visibility predicate, the run gate, and
        // the SAME send entry the Changes panel calls.
        #expect(sendLine.contains("notesEditorSendOffered("))
        #expect(sendLine.contains("sendToNotesEditorNow()"))
        #expect(sendLine.contains(".disabled(runActive)"))
        #expect(sendLine.contains("NotesEditorPanelCopy.actionLabel"))
        #expect(sendLine.contains("NotesEditorPanelCopy.busyLabel"))
        #expect(sendLine.contains("NotesEditorPanelCopy.help"))
        // The line stands BELOW the row, not inside it: the row's own controls
        // carry no send action, and the line is drawn after the fitting row.
        let controls = try declaration(
            "provenanceControls", endingBefore: "correctionChipTitle", in: detail)
        #expect(!controls.contains("NotesEditorPanelCopy."))
        let line = try declaration("provenanceLine", endingBefore: "notesEditorSendLine", in: detail)
        let row = try #require(line.range(of: "ViewThatFits(in: .horizontal)"))
        let below = try #require(line.range(of: "notesEditorSendLine"))
        #expect(row.upperBound < below.lowerBound)
        // BELOW the fitting row, never a candidate INSIDE it: `ViewThatFits`
        // renders one alternative, so a send line offered as a third candidate
        // would not stand under the row — it would simply never draw. Order
        // alone cannot tell those apart; the brace can.
        var depth = 0
        var closedAt: String.Index?
        var i = row.upperBound
        while i < below.lowerBound {
            if line[i] == "{" { depth += 1 }
            if line[i] == "}" {
                depth -= 1
                if depth == 0 { closedAt = i; break }
            }
            i = line.index(after: i)
        }
        #expect(closedAt != nil, "the send line stands after the fitting row's closing brace")
        // One entry point, two placements: the panel's own closure calls the
        // same action, and only one function reaches the pipeline.
        #expect(detail.contains("onSend: { sendToNotesEditorNow() }"))
        #expect(detail.components(separatedBy: "func sendToNotesEditorNow").count - 1 == 1)
        #expect(detail.components(separatedBy: "pipeline.sendPendingNotesToEditor").count - 1 == 1)
    }

    @Test("AC-13: the send action reads as a control, with a border")
    func theSendLineIsBordered() throws {
        let detail = try meetingDetailSource()
        let sendLine = try declaration("notesEditorSendLine", endingBefore: "provenanceStamp", in: detail)
        #expect(sendLine.contains(".buttonStyle(.bordered)"))
        #expect(!sendLine.contains(".borderless"))
        // The label holds one line on its own. Standing in the row it inherited
        // this from the group around it; standing alone it carries it itself,
        // and without it the narrow pane wraps the label instead of clamping.
        #expect(sendLine.contains(".lineLimit(1)"))
    }

    @Test("AC-13: a divider divides the copy action from the annotation affordances")
    func theRowDividesCopyFromTheAnnotationAffordances() throws {
        let detail = try meetingDetailSource()
        let controls = try declaration(
            "provenanceControls", endingBefore: "correctionChipTitle", in: detail)
        let changes = try #require(controls.range(of: "ChangesPanel("))
        let divider = try #require(controls.range(of: "Rectangle()"))
        let copy = try #require(controls.range(of: "CopyAllButton("))
        #expect(changes.upperBound < divider.lowerBound)
        #expect(divider.upperBound < copy.lowerBound)
        // The system rule is invisible against this ground, so the seam is
        // drawn with its own ink and its own height.
        let seam = controls[divider.lowerBound..<copy.lowerBound]
        #expect(seam.contains(".fill(.white.opacity("))
        #expect(seam.contains(".frame(width: 1, height:"))
        #expect(!seam.contains("Divider()"))
        // It is drawn only where the set it divides from is drawn: the two
        // annotation affordances stand on the base gate, so the rule does too.
        let gate = controls[..<divider.lowerBound]
        let opener = try #require(gate.range(of: "if correctionsAvailable {", options: .backwards))
        let between = gate[opener.upperBound...]
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("//") }
        #expect(between.isEmpty)
    }

    @Test("AC-13: both send placements stand on the same base availability")
    func sendPlacementsAgreeOnBaseAvailability() throws {
        let detail = try meetingDetailSource()
        // The popover placement lives behind the base gate: final notes on a
        // ready meeting.
        let controls = try declaration(
            "provenanceControls", endingBefore: "correctionChipTitle", in: detail)
        let panelStart = try #require(controls.range(of: "ChangesPanel("))
        #expect(controls[..<panelStart.lowerBound].contains("if correctionsAvailable {"))
        // The line placement asks it too, so the two cannot disagree with notes
        // present on a meeting that is not ready — where the pipeline refuses
        // silently and an enabled control would be a dead end.
        let sendLine = try declaration("notesEditorSendLine", endingBefore: "provenanceStamp", in: detail)
        let sendCondition = sendLine[
            ..<(try #require(sendLine.range(of: "sendToNotesEditorNow()")).lowerBound)]
        #expect(sendCondition.contains("correctionsAvailable"))
        #expect(sendCondition.contains("notesEditorSendOffered("))
    }

    @Test("AC-13/§10: a composer already on screen withdraws when its action is not offered")
    func openComposerFollowsTheCapability() throws {
        // The term both presentations rest on: a correction is not offered
        // under an engine that cannot edit, a margin note always is.
        #expect(!NotesEditingEntry.offered(.correct, engineCanEditNotes: false))
        #expect(NotesEditingEntry.offered(.note, engineCanEditNotes: false))

        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources", isDirectory: true)
        let detail = try String(
            contentsOf: sources.appendingPathComponent("BlaiseApp/MeetingDetailView.swift"),
            encoding: .utf8)
        // Every composer the pane presents — the orphaned one first in the file,
        // then the in-block one — is drawn only while its own action is still
        // offered: the orphan asks the term directly, the in-block one through
        // the shared presented-composer value its block's marks also read.
        let sites = detail.components(separatedBy: "InlineComposer(")
        #expect(sites.count - 1 == 2, "both composer presentations are covered here")
        #expect(sites[0].suffix(400).contains("NotesEditingEntry.offered("))
        #expect(sites[1].suffix(300).contains("if composing, let target = editingTarget {"))
    }

    /// The composer's withdrawal has to take its block's marks with it. Three
    /// other things in the pane read "this block is being composed": the
    /// composing wash, the branch that suppresses the block's pending-correction
    /// mark, and the selection-bar suppression. All three must agree with what
    /// is drawn — a block wearing an accent fill with no composer under it, with
    /// its pending mark suppressed and no bar on a selection, would offer nothing
    /// at all on the words inside it, and AC-13 requires `Add a note about this
    /// text` to remain.
    @Test("AC-13/§10: a withdrawn composer leaves none of its marks on the block")
    func presentedComposerFollowsTheCapability() throws {
        let block = "Cut the tide mini-game from the March build."
        let anchor = NotesBlockAnchor.detailed(2)
        let correction = NotesEditingEntry.target(
            .correct, section: .detailedNotes, anchorID: anchor, blockText: block, occurrence: 0)
        let note = NotesEditingEntry.target(
            .note, section: .detailedNotes, anchorID: anchor, blockText: block, occurrence: 0)

        // The value the wash, the pending mark and the selection bar consume.
        #expect(composerPresented(correction, inBlockWith: anchor, engineCanEditNotes: true))
        // The SAME stored target under an engine that cannot edit: the composer
        // is gone, so the marks are too — while the target and its draft stay
        // stored, which is what brings the composer back with the typed words.
        #expect(!composerPresented(correction, inBlockWith: anchor, engineCanEditNotes: false))
        #expect(composerPresented(correction, inBlockWith: anchor, engineCanEditNotes: true))
        // A margin note never depends on the engine.
        #expect(composerPresented(note, inBlockWith: anchor, engineCanEditNotes: false))
        // Neither kind marks a block the composer does not belong to.
        #expect(!composerPresented(
            correction, inBlockWith: NotesBlockAnchor.detailed(3), engineCanEditNotes: true))
        #expect(!composerPresented(
            note, inBlockWith: NotesBlockAnchor.detailed(3), engineCanEditNotes: true))
        #expect(!composerPresented(nil, inBlockWith: anchor, engineCanEditNotes: true))

        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources", isDirectory: true)
        let detail = try String(
            contentsOf: sources.appendingPathComponent("BlaiseApp/MeetingDetailView.swift"),
            encoding: .utf8)
        // One derived value, capability-aware at its definition.
        let definition = try #require(detail.range(of: "let composing = "))
        let composingTail = detail[definition.upperBound...].prefix(160)
        #expect(composingTail.contains("composerPresented("))
        #expect(composingTail.contains("engineCanEditNotes: engineCanEditNotes"))
        #expect(detail.components(separatedBy: "let composing = ").count - 1 == 1)
        // And the three marks read it: the wash, the pending-mark suppression,
        // and the bar that must stand at the block again.
        #expect(detail.contains("composing && composedSpan == nil ? .composing"))
        #expect(detail.contains("?? (composing\n                ? nil"))
        let bar = try #require(detail.range(of: "private var selectionBar"))
        let barCondition = detail[bar.upperBound...].prefix(400)
        #expect(barCondition.contains("!composerPresented("))
        #expect(barCondition.contains("engineCanEditNotes: engineCanEditNotes"))
    }

    @Test("AC-13: the selection bar and the block menu draw the correct target only when offered")
    func correctionControlsConsultTheOfferedSeam() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources", isDirectory: true)
        let editing = try String(
            contentsOf: sources.appendingPathComponent("BlaiseApp/NotesEditing.swift"),
            encoding: .utf8)
        let plateStart = try #require(editing.range(of: "private var plate: some View"))
        let plateTail = editing[plateStart.upperBound...]
        let plateEnd = try #require(plateTail.range(of: "private var tail: some View"))
        let plate = plateTail[..<plateEnd.lowerBound]
        #expect(plate.contains("NotesEditingEntry.offered(.correct"))
        #expect(plate.contains("actionTarget(.note)"))
        // The panel's placement asks the same question the header does.
        #expect(editing.contains("if notesEditorSendOffered(rows: rows,"))

        let detail = try String(
            contentsOf: sources.appendingPathComponent("BlaiseApp/MeetingDetailView.swift"),
            encoding: .utf8)
        let menuStart = try #require(detail.range(of: ".contextMenu {"))
        let menuTail = detail[menuStart.upperBound...]
        let menuEnd = try #require(menuTail.range(of: "Button(\"Add Note…\")"))
        let correctItem = menuTail[..<menuEnd.lowerBound]
        #expect(correctItem.contains("NotesEditingEntry.offered(.correct"))
    }
}

@MainActor
@Suite struct NotesEditingCommandTests {
    private func context(
        ready: Bool = true, hasTarget: Bool = true, correctionEnabled: Bool = true,
        engineCanEditNotes: Bool = true
    ) -> AppUIState.NotesEditingContext {
        AppUIState.NotesEditingContext(
            meetingID: "01TESTMEETING0000000000000", surfaceReady: ready,
            hasTarget: hasTarget, correctionEnabled: correctionEnabled,
            engineCanEditNotes: engineCanEditNotes)
    }

    @Test("Correct Selection… follows the correction gate; Add Note… does not")
    func commandEnablement() {
        #expect(notesEditingCommandEnabled(.correct, context: context()))
        #expect(!notesEditingCommandEnabled(.correct, context: context(correctionEnabled: false)))
        #expect(notesEditingCommandEnabled(.note, context: context(correctionEnabled: false)))
        // An engine that cannot edit notes closes the correction command too.
        #expect(!notesEditingCommandEnabled(
            .correct, context: context(engineCanEditNotes: false)))
        #expect(notesEditingCommandEnabled(.note, context: context(engineCanEditNotes: false)))
        // No notes surface: neither command is offered.
        #expect(!notesEditingCommandEnabled(.correct, context: context(ready: false)))
        #expect(!notesEditingCommandEnabled(.note, context: context(ready: false)))
    }

    @Test("both commands need something to aim at — no block, nothing offered")
    func commandEnablementFollowsTheTarget() {
        #expect(!notesEditingCommandEnabled(.correct, context: context(hasTarget: false)))
        #expect(!notesEditingCommandEnabled(.note, context: context(hasTarget: false)))
        // A target alone is not enough for the correction path.
        #expect(
            !notesEditingCommandEnabled(
                .correct, context: context(hasTarget: true, correctionEnabled: false)))
        #expect(notesEditingCommandEnabled(.note, context: context(hasTarget: true)))
    }

    /// The selection host is macOS 26 only and prose only. If the commands
    /// needed one, they would be permanently dead on the whole best-effort
    /// tier — where the spec puts the menu among the paths that CARRY the
    /// capability — and on every list item, header and table cell on 26.
    @Test("a block aimed at without a selection still offers and routes both commands")
    func commandsRideAWholeBlockTarget() {
        var routed: [AppUIState.NotesEditingRequest] = []
        let aimed = context(hasTarget: true)
        #expect(notesEditingCommandEnabled(.correct, context: aimed))
        #expect(notesEditingCommandEnabled(.note, context: aimed))
        #expect(
            notesEditingCommandAction(
                .correct, context: aimed, token: 1, route: { routed.append($0) }))
        #expect(routed.map(\.kind) == [.correct])

        // What that invocation anchors to: the whole block, exactly as the
        // hover group's and right-click's selection-less invocation does.
        let block = "Quoll Harbor's onboarding tested well with the new cohort."
        let target = NotesEditingEntry.target(
            .correct, section: .summary, anchorID: "notes-summary-0", blockText: block,
            occurrence: 0, selection: SelectedSpan(text: ""))
        #expect(target.quotedText == block)
        #expect(target.isWholeBlock)
    }

    @Test("the command routes the invocation to the open notes surface")
    func commandRoutes() {
        var routed: [AppUIState.NotesEditingRequest] = []
        #expect(
            notesEditingCommandAction(
                .correct, context: context(), token: 3, route: { routed.append($0) }))
        #expect(routed.count == 1)
        #expect(routed[0].meetingID == "01TESTMEETING0000000000000")
        #expect(routed[0].kind == .correct)
        #expect(routed[0].token == 3, "the token re-fires a repeated invocation")
    }

    @Test("a run in flight routes no correction, and routes the note anyway")
    func commandRespectsTheGate() {
        var routed: [AppUIState.NotesEditingRequest] = []
        #expect(
            !notesEditingCommandAction(
                .correct, context: context(correctionEnabled: false), token: 1,
                route: { routed.append($0) }))
        #expect(routed.isEmpty)
        #expect(
            notesEditingCommandAction(
                .note, context: context(correctionEnabled: false), token: 1,
                route: { routed.append($0) }))
        #expect(routed.map(\.kind) == [.note])
    }

    @Test("no meeting selected routes nothing")
    func commandWithoutAMeeting() {
        var routed: [AppUIState.NotesEditingRequest] = []
        let empty = AppUIState.NotesEditingContext(
            meetingID: nil, surfaceReady: true, hasTarget: true, correctionEnabled: true,
            engineCanEditNotes: true)
        #expect(!notesEditingCommandAction(.note, context: empty, token: 1, route: { routed.append($0) }))
        #expect(routed.isEmpty)
    }
}

// MARK: - The selection-capable host occupies the same space as the plain one

/// A block's height must be a function of the width it is laid out at, resolved
/// in that same pass. The plain `Text` host is the reference — it wraps
/// correctly at every width — so the selection-capable host has to agree with
/// it: a host that reports less than the reference has lines the layout never
/// allotted space for, and TextKit never draws them.
///
/// Measured through a real SwiftUI layout pass (`ImageRenderer` lays the view
/// out for rendering), which is the pass an ideal height carried over from the
/// previous one fails in.
@MainActor
@Suite struct SelectableBlockHeightTests {
    /// Fictional prose that wraps to different line counts across the four
    /// widths, including a block short enough never to wrap at any of them.
    private let corpus = [
        "Ship it.",
        "The Quoll Harbor sonar demo slipped a week.",
        "The warp core review overran its slot because the Quoll Harbor sonar rig "
            + "needs a staffing decision before the freeze.",
        "Vexatron Labs will re-run the berthing survey after the code freeze, publish "
            + "the corrected sonar figures to the crew wiki, and hand the regression "
            + "list to the harbor team the same afternoon so nothing waits on a single "
            + "reviewer.",
    ]

    private func height(_ text: String, selectable: Bool, width: Double) -> Double {
        let renderer = ImageRenderer(
            content: NotesBlockText(
                source: MarkdownBlocks.parse(text)[0].text, terms: [], selectable: selectable)
                .font(Design.readingFont(14))
                .lineSpacing(Design.readingLineSpacing)
                .frame(width: width, alignment: .leading))
        return Double(renderer.nsImage?.size.height ?? -1)
    }

    @Test("the selectable host is as tall as the plain host at every reading width")
    func selectableHostMatchesThePlainHost() {
        for block in corpus {
            for width in [439.0, 520.0, 668.0, 740.0] {
                let plain = height(block, selectable: false, width: width)
                let selectable = height(block, selectable: true, width: width)
                #expect(plain > 0, "the reference host measured nothing at width \(width)")
                #expect(
                    abs(selectable - plain) <= 1,
                    """
                    at width \(width) the selectable host measured \(selectable) and the \
                    plain host \(plain) — "\(block.prefix(40))…"
                    """)
            }
        }
    }

    /// Semantic colours only resolve inside an appearance; the notes pane is
    /// dark, so that is the one they are read in.
    private func components(_ color: NSColor) -> (r: Double, g: Double, b: Double, a: Double) {
        var out = (r: 1.0, g: 1.0, b: 1.0, a: 1.0)
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            guard let resolved = color.usingColorSpace(.sRGB) else { return }
            out = (
                resolved.redComponent, resolved.greenComponent, resolved.blueComponent,
                resolved.alphaComponent
            )
        }
        return out
    }

    private func over(_ color: NSColor, _ backdrop: (r: Double, g: Double, b: Double, a: Double))
        -> (r: Double, g: Double, b: Double, a: Double)
    {
        let top = components(color)
        return (
            backdrop.r + top.a * (top.r - backdrop.r), backdrop.g + top.a * (top.g - backdrop.g),
            backdrop.b + top.a * (top.b - backdrop.b), 1.0
        )
    }

    private func contrast(
        _ first: (r: Double, g: Double, b: Double, a: Double),
        _ second: (r: Double, g: Double, b: Double, a: Double)
    ) -> Double {
        func luminance(_ colour: (r: Double, g: Double, b: Double, a: Double)) -> Double {
            func channel(_ value: Double) -> Double {
                value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(colour.r) + 0.7152 * channel(colour.g) + 0.0722 * channel(colour.b)
        }
        let lighter = max(luminance(first), luminance(second))
        let darker = min(luminance(first), luminance(second))
        return (lighter + 0.05) / (darker + 0.05)
    }

    @Test("selected prose is the most legible text on the page, not the least")
    func selectedProseClearsTheTextContrastFloor() {
        let page = components(NSColor(Design.listColumn))
        let fill = over(BlockSelection.fill, page)
        let ink = over(NSColor.labelColor, fill)
        #expect(
            contrast(ink, fill) >= 4.5,
            "selected ink measured \(contrast(ink, fill)):1 against its own fill")
        #expect(
            contrast(fill, page) >= 3.0,
            "the selection fill measured \(contrast(fill, page)):1 against the page")
    }
}

// MARK: - Reaching the controls without a pointer

/// The commands are keyboard commands, so what they aim at may never depend on
/// a pointer having been somewhere. `notesBlockFocus` is what puts a block into
/// the pane's aim.
@MainActor
@Suite struct NotesEditingKeyboardReachTests {
    @Test("both commands carry a key equivalent")
    func commandsCarryKeyEquivalents() {
        #expect(NotesEditingCommandButtons.correctShortcut.key.character == "k")
        #expect(NotesEditingCommandButtons.correctShortcut.modifiers == [.command, .shift])
        #expect(NotesEditingCommandButtons.noteShortcut.key.character == "k")
        #expect(NotesEditingCommandButtons.noteShortcut.modifiers == [.command, .option])
        #expect(
            NotesEditingCommandButtons.correctShortcut.modifiers
                != NotesEditingCommandButtons.noteShortcut.modifiers,
            "two commands on one key must differ by modifier")
    }

    @Test("both commands open on a target whose source the gate never asks about")
    func commandGateOpensOnAnyTarget() {
        // The gate reads only THAT there is a target — never where it came
        // from — which is what lets keyboard focus reach the commands at all,
        // in a surface where hover was once the only source of one.
        let context = AppUIState.NotesEditingContext(
            meetingID: "01TESTMEETING0000000000000", surfaceReady: true,
            hasTarget: true, correctionEnabled: true, engineCanEditNotes: true)
        #expect(notesEditingCommandEnabled(.correct, context: context))
        #expect(notesEditingCommandEnabled(.note, context: context))
    }
}

// MARK: - The controls themselves

@MainActor
@Suite struct NotesEditingControlShapeTests {
    @Test("each action target is a real target, and the AI path says so")
    func actionTargets() {
        #expect(SelectionActionBar.targetHeight >= 22, "under 22 points is not a control")
        #expect(MarginNoteChip.targetHeight >= 22, "the chip is a target like any other")
        #expect(SelectionActionBar.title(.correct) == "AI Correct")
        #expect(SelectionActionBar.title(.note) == "Add Note")
        // The two actions are independent, so their labels and their
        // accessibility labels are distinct on every path.
        #expect(SelectionActionBar.title(.correct) != SelectionActionBar.title(.note))
        #expect(
            SelectionActionBar.accessibilityLabel(.correct)
                != SelectionActionBar.accessibilityLabel(.note))
    }

    @Test("the bar stands inside the reading measure it is a control for")
    func barFitsTheMeasure() {
        #expect(SelectionActionBar.plateWidth == SelectionActionBar.targetWidth * 2 + 1)
        #expect(
            SelectionActionBar.size.width <= NotesEditingLayout.proseMeasure,
            "the bar never has to leave the column to fit")
        #expect(
            SelectionActionBar.size.height
                == SelectionActionBar.targetHeight + SelectionActionBar.tailHeight)
    }

    @Test("the composer asks for something in words, per kind")
    func composerPrompts() {
        #expect(InlineComposer.prompt(.correct) == "What is actually true?")
        #expect(InlineComposer.prompt(.note) == "Your note")
    }

    @Test("the composer quotes the line as the reader sees it, prefix included")
    func composerQuotesTheRenderedLine() {
        // An action item's host renders "<owner>: <task>"; the stored anchor is
        // the task alone. The composer must state the whole line.
        let task = "File the takedown animation for the 1.5 cycle."
        let rendered = "Marcos Lima: \(task)"
        let target = NotesEditingEntry.target(
            .correct, section: .actionItem, anchorID: "notes-action-1", blockText: task,
            occurrence: 0, hostText: rendered)
        #expect(target.displayQuote == rendered)
        #expect(target.quotedText == task, "the durable anchor keeps the stored quote")
        #expect(target.isWholeBlock)
    }

    @Test("a selection quotes exactly the selected span")
    func composerQuotesTheSelection() {
        let task = "File the takedown animation for the 1.5 cycle."
        let target = NotesEditingEntry.target(
            .note, section: .actionItem, anchorID: "notes-action-1", blockText: task,
            occurrence: 0, selection: SelectedSpan(text: "takedown animation"),
            hostText: "Marcos Lima: \(task)")
        #expect(target.displayQuote == "takedown animation")
        #expect(target.quotedText == "takedown animation")
        #expect(!target.isWholeBlock)
    }

    @Test("the wash always has a span to ride, so it never falls back to the row")
    func washRidesASpan() {
        let block = "Quoll Harbor's onboarding tested well with the new cohort."
        let whole = NotesEditingEntry.target(
            .correct, section: .summary, anchorID: "notes-summary-0", blockText: block,
            occurrence: 0)
        #expect(whole.washedSpan == SelectedSpan(text: block, occurrence: 0))
        let span = NotesEditingEntry.target(
            .correct, section: .summary, anchorID: "notes-summary-0", blockText: block,
            occurrence: 0, selection: SelectedSpan(text: "onboarding"))
        #expect(span.washedSpan == SelectedSpan(text: "onboarding", occurrence: 0))
    }

    /// The fill has to ride the glyphs of the passage, which means the call
    /// site needs a span for a row that was stored days ago — its own quote.
    @Test("a stored annotation hands the host the span its quote occupies")
    func storedRowsOfferASpan() {
        let quote = "the stealth-AI fixes"
        let stored = row(kind: .annotation, status: .applied, quote: quote)
        #expect(AnchorWash.washedSpan(for: [stored]) == SelectedSpan(text: quote, occurrence: 0))
        #expect(AnchorWash.washedSpan(for: []) == nil)
    }

    @Test("the anchor wash stays in the reference band, well under the text it marks")
    func washStaysQuiet() {
        for wash in [AnchorWash.composing, .pending, .note] {
            #expect(wash.fill >= 0.10 && wash.fill <= 0.14)
        }
        #expect(AnchorWash.none.fill == 0)
    }

    @Test("every live wash is one alpha — the mark never grades itself in the accent hue")
    func washIsOneAlpha() {
        let live = [AnchorWash.composing, .pending, .note].map(\.fill)
        #expect(Set(live).count == 1, "one hue at several alphas is not several states")
        #expect(AnchorWash.none.fill == 0)
    }
}

// MARK: - The two kinds

/// A margin note and a correction are different objects, and the surface has to
/// say so without either of them being read. The test a critic applies is
/// obscuring both labels and asking which is which; these assertions are that
/// test written down — every claim is about how the two are DRAWN, and the
/// labels are excluded from all of it.
@MainActor
@Suite struct AnnotationKindDistinctionTests {
    /// The notes page the two are read on, sampled from a capture of the
    /// reading surface.
    private static let page = (r: 16.0, g: 20.0, b: 30.0)

    private static func luminance(_ colour: (r: Double, g: Double, b: Double)) -> Double {
        func channel(_ value: Double) -> Double {
            let unit = value / 255
            return unit <= 0.03928 ? unit / 12.92 : pow((unit + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(colour.r) + 0.7152 * channel(colour.g) + 0.0722 * channel(colour.b)
    }

    private static func contrast(
        _ a: (r: Double, g: Double, b: Double), _ b: (r: Double, g: Double, b: Double)
    ) -> Double {
        let high = max(luminance(a), luminance(b))
        let low = min(luminance(a), luminance(b))
        return (high + 0.05) / (low + 0.05)
    }

    @Test("the note is content in the page; the correction is a plate on it")
    func planeCarriesTheKind() {
        // The most legible difference at a distance: one of them has a
        // container and the other has none at all.
        #expect(AnnotationKindStyle.correction.isPlated)
        #expect(!AnnotationKindStyle.note.isPlated)
        #expect(AnnotationKindStyle.note.hasLeadingRule)
        #expect(!AnnotationKindStyle.correction.hasLeadingRule)
    }

    @Test("the note is set as prose, the correction as interface text")
    func typeCarriesTheKind() {
        #expect(AnnotationKindStyle.note.usesReadingType)
        #expect(!AnnotationKindStyle.correction.usesReadingType)
        // The note reads at the notes' own contrast — it IS the notes; the
        // correction reads a step back, and still well clear of the floor its
        // plate gives it.
        #expect(AnnotationKindStyle.note.bodyInk > AnnotationKindStyle.correction.bodyInk)
        #expect(AnnotationKindStyle.correction.bodyInk >= 0.6, "a statement nobody can read")
        #expect(AnnotationKindStyle.note.bodyPointSize != AnnotationKindStyle.correction.bodyPointSize)
    }

    @Test("only the transient kind reports a state")
    func stateBelongsToTheCorrection() {
        #expect(AnnotationKindStyle.correction.reportsState)
        #expect(!AnnotationKindStyle.note.reportsState)
        // And the two states it reports are separated by a word — beside a
        // marker whose shape changes with them. One hue at two alphas is what
        // this run keeps recording as a non-distinction.
        #expect(PendingRowStatus.pending.label != PendingRowStatus.applying.label)
    }

    @Test("the note's rule is a mark, not decoration")
    func theRuleClearsTheNonTextFloor() {
        // Estudio's support violet, composited over the page at the rule's own
        // alpha. Under 3:1 the one shape that says "a note stands here" cannot
        // be relied on.
        let violet = (r: 0.57 * 255, g: 0.51 * 255, b: 0.97 * 255)
        let alpha = AnnotationKindStyle.ruleAlpha
        let composited = (
            r: Self.page.r + (violet.r - Self.page.r) * alpha,
            g: Self.page.g + (violet.g - Self.page.g) * alpha,
            b: Self.page.b + (violet.b - Self.page.b) * alpha
        )
        #expect(Self.contrast(composited, Self.page) >= 3.0)
    }
}

// MARK: - The card grammar

/// What a card IS in this product, asserted as a contract rather than as pixels.
/// The three properties a cold critic counts across a document — how many radii,
/// how many card widths, how many ideas of a surface — are each one value here.
@MainActor
@Suite struct AnnotationCardGrammarTests {
    /// The notes page the cards are read on, as sampled from a capture of the
    /// reading surface. Contrast claims are meaningless without the plane the
    /// card is claimed to sit on.
    private static let page = (r: 14.0, g: 17.0, b: 26.0)

    /// WCAG relative luminance of an 8-bit sRGB triple.
    private static func luminance(_ colour: (r: Double, g: Double, b: Double)) -> Double {
        func channel(_ value: Double) -> Double {
            let unit = value / 255
            return unit <= 0.03928 ? unit / 12.92 : pow((unit + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(colour.r) + 0.7152 * channel(colour.g) + 0.0722 * channel(colour.b)
    }

    private static func contrast(
        _ a: (r: Double, g: Double, b: Double), _ b: (r: Double, g: Double, b: Double)
    ) -> Double {
        let high = max(luminance(a), luminance(b))
        let low = min(luminance(a), luminance(b))
        return (high + 0.05) / (low + 0.05)
    }

    @Test("the card fill is a surface — quiet, and not invisible")
    func theCardIsASurface() {
        let alpha = NotesEditingSurface.cardFillAlpha
        let composited = (
            r: Self.page.r + (255 - Self.page.r) * alpha,
            g: Self.page.g + (255 - Self.page.g) * alpha,
            b: Self.page.b + (255 - Self.page.b) * alpha
        )
        let ratio = Self.contrast(composited, Self.page)
        // Below the band a container is not a plane at all; above it the card
        // starts outshouting the words it is a note about.
        #expect(ratio >= 1.11, "a fill this close to the page is not a surface")
        #expect(ratio <= 1.20, "a card must not be louder than the reference plates")
    }

    @Test("one radius — the annotation layer draws no second corner")
    func oneRadius() {
        #expect(NotesEditingLayout.markRadius >= 8 && NotesEditingLayout.markRadius <= 10)
    }

    @Test("a card is narrower than the measure it is a note about")
    func aCardIsNotAParagraph() {
        #expect(NotesEditingLayout.asideMeasure < NotesEditingLayout.proseMeasure)
    }
}

// MARK: - Where the selection bar stands

/// The bar is the whole interaction model: it is the only transient control on
/// the surface, and everything that makes it trustworthy is geometry. Each
/// expectation below is one of the promises the design makes.
@MainActor
@Suite struct SelectionBarPlacementTests {
    /// One line of prose, 17 points tall, starting 120 points into the block.
    private func oneLine(y: CGFloat = 0, x: CGFloat = 120, width: CGFloat = 240) -> SelectionFrame {
        let line = CGRect(x: x, y: y, width: width, height: 17)
        return SelectionFrame(first: line, last: line)
    }

    @Test("the bar never covers the passage it acts on, on one line or on many")
    func neverCoversItsAnchor() {
        let single = oneLine(y: 40)
        let multi = SelectionFrame(
            first: CGRect(x: 300, y: 40, width: 340, height: 17),
            last: CGRect(x: 0, y: 61, width: 180, height: 17))
        for selection in [single, multi] {
            for blockTop in [CGFloat(0), 300, 700, 860] {
                let placed = SelectionBarPlacement.resolve(
                    selection: selection, measure: 668, blockTop: blockTop, paneHeight: 900)
                let bar = SelectionBarPlacement.frame(placed)
                #expect(!bar.intersects(selection.first), "bar \(bar) over \(selection.first)")
                #expect(!bar.intersects(selection.last), "bar \(bar) over \(selection.last)")
            }
        }
    }

    @Test("it stands under the passage where there is room, and above it where there is not")
    func flipsRatherThanFallingOffTheFold() {
        let selection = oneLine(y: 10)
        let roomy = SelectionBarPlacement.resolve(
            selection: selection, measure: 668, blockTop: 200, paneHeight: 900)
        #expect(!roomy.above)
        #expect(roomy.origin.y > selection.last.maxY)

        // The same selection on the last line the reader can see.
        let atTheFold = SelectionBarPlacement.resolve(
            selection: selection, measure: 668, blockTop: 870, paneHeight: 900)
        #expect(atTheFold.above)
        #expect(
            atTheFold.origin.y + SelectionActionBar.size.height <= selection.first.minY,
            "standing above means standing clear above")
        #expect(870 + atTheFold.origin.y >= 0, "and still inside the pane")
    }

    @Test("a passage with no room either side keeps the bar under it, where the page continues")
    func prefersBelowWhenNeitherFits() {
        // A block whose top is off the top of the pane AND whose selection sits
        // at the bottom of it: above would be off-screen too, so below wins.
        let placed = SelectionBarPlacement.resolve(
            selection: oneLine(y: 0), measure: 668, blockTop: -4, paneHeight: 60)
        #expect(!placed.above)
    }

    @Test("it stays inside the reading measure however far right the passage starts")
    func staysInsideTheMeasure() {
        let farRight = oneLine(x: 610, width: 50)
        let placed = SelectionBarPlacement.resolve(
            selection: farRight, measure: 668, blockTop: 100, paneHeight: 900)
        let bar = SelectionBarPlacement.frame(placed)
        #expect(bar.minX >= 0)
        #expect(bar.maxX <= 668)
    }

    @Test("the tail points at the first word of the passage, and never off the bar")
    func tailPointsAtTheAnchor() {
        let placed = SelectionBarPlacement.resolve(
            selection: oneLine(x: 120), measure: 668, blockTop: 100, paneHeight: 900)
        #expect(
            placed.origin.x + placed.tailOffset == 120,
            "the tail lands on the passage's own first character")
        #expect(placed.tailOffset >= SelectionActionBar.tailWidth)
        #expect(placed.tailOffset <= SelectionActionBar.size.width - SelectionActionBar.tailWidth)

        // Pushed left to stay inside the measure, the tail still leans toward
        // the words rather than snapping back to the bar's middle.
        let clamped = SelectionBarPlacement.resolve(
            selection: oneLine(x: 640, width: 20), measure: 668, blockTop: 100, paneHeight: 900)
        #expect(
            clamped.tailOffset > SelectionActionBar.size.width / 2,
            "the passage is to the bar's right, so the tail leans right")
    }
}

// MARK: - The prose offers no editing

/// The operator's rejection, as a check: a notes block may present no editing
/// affordance of any kind. Selection is untouched — it is the whole way in.
@MainActor
@Suite struct NotesProseHostTests {
    @Test("the host takes no typing and still selects")
    func hostTakesNoTyping() {
        let textView = NSTextView(frame: CGRect(x: 0, y: 0, width: 400, height: 40))
        textView.string = "Patch 1.4 ships Thursday."
        NotesProseHost.configure(textView)
        #expect(!textView.isEditable, "a caret offers editing this version does not have")
        #expect(textView.isSelectable, "selection is the surface's only way in")
        #expect(textView.selectedTextAttributes[.backgroundColor] != nil)
        #expect(
            textView.attributedString().attribute(
                .strikethroughStyle, at: 0, effectiveRange: nil) == nil,
            "correction lifecycle must not decorate notes prose")
    }

    /// The pane is dark and this host is not: left alone it resolves every fill
    /// the text system draws itself in the light appearance.
    @Test("the host is given the pane's own appearance")
    func hostRunsDark() {
        let textView = NSTextView(frame: CGRect(x: 0, y: 0, width: 400, height: 40))
        NotesProseHost.configure(textView)
        #expect(textView.appearance?.name == .darkAqua)
    }

    /// A block rewritten under the reader — an editor apply, a name correction —
    /// must reach the screen while the pane stays open. The selection host is a
    /// `TextEditor`, which owns its text storage from the moment it exists and
    /// never re-reads its binding, so the ONLY thing that carries new prose into
    /// it is a new identity keyed on that prose — and that identity has to
    /// enclose the plate, which is what takes editability, the light appearance
    /// and the silent selection away from a freshly created text view. Asserted
    /// on the host's source: the editor cannot be laid out in a test, and what
    /// it displays is AppKit's, not ours.
    @Test("the prose re-identifies the editor, and the plate is inside that identity")
    func selectionHostAdoptsRewrittenProse() throws {
        let source = try notesBlockTextSource()
        let host = try #require(source.range(of: "private struct SelectableBlockText: View {"))
        let end = try #require(
            source.range(of: "private struct ProseHeight", range: host.upperBound..<source.endIndex))
        let body = source[host.upperBound..<end.lowerBound]

        // The whole chain, in order, each search starting where the previous
        // match ended: the editor, the bridge that configures its text view,
        // the menu overlay, and only then the identity. Bound this way, neither
        // a bridge moved outside the identity nor an `.id(display)` on some
        // later sibling can satisfy it.
        let editor = try #require(body.range(of: "TextEditor(text: .constant(display))"))
        let bridge = try #require(
            body.range(
                of: ".background { BlockTextHostBridge(",
                range: editor.upperBound..<body.endIndex))
        let plate = try #require(
            body.range(
                of: ".overlay { BlockContextMenuPlate() }",
                range: bridge.upperBound..<body.endIndex))
        let identity = try #require(
            body.range(of: ".id(display)", range: plate.upperBound..<body.endIndex))
        #expect(
            body[plate.upperBound..<identity.lowerBound]
                .allSatisfy { $0.isWhitespace },
            "the identity is the next modifier on the chain, not a later sibling's")
        #expect(
            body[plate.upperBound...].contains(".id(display)"),
            "without an identity keyed on the prose the editor keeps showing the old block")
        #expect(
            !body[editor.upperBound..<plate.lowerBound].contains(".id(display)"),
            "an identity inside the plate swaps the text view out from under it, editable")
    }

    /// A fresh text view arrives editable, light and silent, and only the
    /// plate's claim takes those away — so a plate that is on screen holding no
    /// claim must keep asking. PINNED HERE: that the retry exists, that it is
    /// coalesced, and that its two stop conditions are the ones named (a live
    /// claim, or leaving the window). NOT PROVEN HERE: that the retry actually
    /// lands the claim — that needs a real window and a real layout pass, which
    /// is the operator's driven check, not this test.
    @Test("an attached plate with no live claim keeps asking for its text view")
    func plateRetriesUntilItHoldsALiveClaim() throws {
        let source = try notesBlockTextSource()
        let plate = try #require(source.range(of: "private final class BlockTextHostPlate: NSView {"))
        let body = source[plate.upperBound...]

        // The claim path ends by scheduling, so a miss is never the last word.
        let claim = try #require(body.range(of: "func claimTextView() {"))
        let claimEnd = try #require(
            body.range(of: "\n    }\n", range: claim.upperBound..<body.endIndex))
        #expect(
            body[claim.upperBound..<claimEnd.lowerBound].contains("scheduleClaimRetryIfNeeded()"),
            "a claim that came back empty has to ask again")

        let retry = try #require(body.range(of: "private func scheduleClaimRetryIfNeeded() {"))
        let retryEnd = try #require(
            body.range(of: "\n    }\n", range: retry.upperBound..<body.endIndex))
        let retryBody = body[retry.upperBound..<retryEnd.lowerBound]
        #expect(
            retryBody.contains("guard window != nil, host?.window == nil, !claimRetryQueued"),
            "attached, holding no LIVE claim, and nothing already queued — all three")
        #expect(retryBody.contains("DispatchQueue.main.async"))
        #expect(
            retryBody.contains("claimTextView()"),
            "the retry re-runs the claim rather than a copy of it")

        // The guard only coalesces while the flag moves both ways, and each
        // move has to happen on the right side of the hop: raised before the
        // work is queued, lowered inside it before the claim runs again.
        let raised = try #require(
            retryBody.range(of: "claimRetryQueued = true"),
            "without the flag raised, a burst of passes queues a retry per pass")
        let dispatch = try #require(
            retryBody.range(
                of: "DispatchQueue.main.async", range: raised.upperBound..<retryBody.endIndex),
            "raised after the hop is queued, the guard is open for the whole burst")

        // The closure, bounded by its own close, so a later statement in the
        // function body cannot stand in for one inside the retry.
        let closureEnd = try #require(
            retryBody.range(of: "\n        }", range: dispatch.upperBound..<retryBody.endIndex))
        let closure = retryBody[dispatch.upperBound..<closureEnd.lowerBound]
        let lowered = try #require(
            closure.range(of: "claimRetryQueued = false"),
            "left raised, the plate retries once and then never asks again")
        #expect(
            closure.range(of: "claimTextView()", range: lowered.upperBound..<closure.endIndex)
                != nil,
            "lowered after the claim, a miss on this turn cannot queue the next one")
    }

    /// The mark is painted from a span, so which of a block's equal passages it
    /// names has to survive the trip into character offsets.
    @Test("the mark lands on the occurrence it names")
    func markRangeNamesTheOccurrence() {
        let text = "Owner to be confirmed. Owner to be confirmed."
        let first = NotesProseHost.markRange(of: SelectedSpan(text: "Owner"), in: text)
        let second = NotesProseHost.markRange(
            of: SelectedSpan(text: "Owner", occurrence: 1), in: text)
        #expect(first == NSRange(location: 0, length: 5))
        #expect(second == NSRange(location: 23, length: 5))
        #expect(NotesProseHost.markRange(of: SelectedSpan(text: ""), in: text) == nil)
        #expect(NotesProseHost.markRange(of: SelectedSpan(text: "Deadline"), in: text) == nil)
    }

    /// A rewrite that collapses duplicates leaves a row naming an occurrence the
    /// text no longer has. It marks the last one rather than nothing, which is
    /// the choice the anchor resolver already makes.
    @Test("an occurrence the text lost falls back to the last one")
    func markRangeFallsBackToTheLast() {
        let text = "Owner to be confirmed. Owner to be confirmed."
        let range = NotesProseHost.markRange(
            of: SelectedSpan(text: "Owner", occurrence: 7), in: text)
        #expect(range == NSRange(location: 23, length: 5))
    }

    @Test("the span it reports is the exact range, counted among that block's equals")
    func spanNamesWhichOccurrence() {
        let text = "Owner to be confirmed. Owner to be confirmed."
        let first = NotesProseHost.span(of: NSRange(location: 0, length: 5), in: text)
        let second = NotesProseHost.span(of: NSRange(location: 23, length: 5), in: text)
        #expect(first == SelectedSpan(text: "Owner", occurrence: 0))
        #expect(second == SelectedSpan(text: "Owner", occurrence: 1))
        #expect(NotesProseHost.span(of: NSRange(location: 4, length: 0), in: text) == nil)
    }

    /// A block whose text carries characters outside the basic plane counts one
    /// way in UTF-16 and another in characters; the occurrence is a character
    /// count, so the range has to be converted rather than used raw.
    @Test("an accented block still reports the occurrence it selected")
    func spanAcrossWideCharacters() {
        let text = "Decisão adiada. Decisão adiada."
        let range = (text as NSString).range(of: "adiada", options: .backwards)
        #expect(NotesProseHost.span(of: range, in: text)
            == SelectedSpan(text: "adiada", occurrence: 1))
    }
}

/// A block picked with one click is the target in its entirety, so the extent
/// the bar stands clear of is the block's own height, never just its first
/// line: standing under the first line would put the bar on the second, which
/// is text the action would rewrite.
@Suite struct WholeBlockAimPlacementTests {
    /// What a whole-block aim resolves against: the block's first line, and its
    /// bottom edge.
    private func wholeBlock(height: CGFloat) -> SelectionFrame {
        SelectionFrame(
            first: CGRect(x: 0, y: 0, width: 0, height: 17),
            last: CGRect(x: 0, y: height, width: 0, height: 0))
    }

    @Test("the bar clears every line of a block picked whole, not only its first")
    func clearsTheWholeBlock() {
        for height in [CGFloat(17), 38, 76] {
            let placed = SelectionBarPlacement.resolve(
                selection: wholeBlock(height: height), measure: 668, blockTop: 200,
                paneHeight: 900)
            let bar = SelectionBarPlacement.frame(placed)
            #expect(!placed.above)
            #expect(
                !bar.intersects(CGRect(x: 0, y: 0, width: 668, height: height)),
                "bar \(bar) over a block \(height) points tall")
        }
    }

    @Test("a block picked whole is still pointed at by its first word")
    func pointsAtTheFirstWord() {
        let placed = SelectionBarPlacement.resolve(
            selection: wholeBlock(height: 38), measure: 668, blockTop: 200, paneHeight: 900)
        #expect(placed.origin.x == 0)
        #expect(placed.tailOffset == SelectionActionBar.tailWidth)
    }
}

// MARK: - SC-12: the settle observation adds no surface

/// The registrations §4 mandates are asserted to EXIST, and the surface they
/// ride is asserted to stay silent: none of them renders a node, a label or an
/// affordance, and the ≤1/s debounce stands between the signals and the
/// pipeline.
///
/// The oracle is the pane's own source. The rendering surface these modifiers
/// hang on is `MeetingDetailView`'s private body, which cannot be laid out in a
/// test without an `AppEnvironment` (the composition root that opens the real
/// database, keychain and listeners), so what is decidable here is that every
/// settle entry point is attached as a NON-rendering modifier and that no
/// settle vocabulary reaches a rendered string.
@Suite struct SettleObservationSurfaceTests {
    private func source() throws -> String { try meetingDetailSource() }

    private func line(containing needle: String, in source: String) throws -> String {
        let match = source.split(separator: "\n", omittingEmptySubsequences: false)
            .first { $0.contains(needle) }
        return String(try #require(match))
    }

    @Test("SC-12: attach, detach and the three activity signals are registered")
    func registrationsExist() throws {
        let source = try source()
        // Attach rides the view's own `.task(id:)`; detach rides `.onDisappear`.
        let taskRange = try #require(source.range(of: ".task(id: meetingID)"))
        let disappearRange = try #require(
            source.range(of: ".onDisappear", range: taskRange.upperBound ..< source.endIndex))
        let taskBody = source[taskRange.upperBound ..< disappearRange.lowerBound]
        #expect(taskBody.contains("settleViewAttached(meetingID)"))
        let disappearBody = source[
            disappearRange.upperBound
                ..< (source.range(
                    of: ".onChange", range: disappearRange.upperBound ..< source.endIndex)?
                    .lowerBound ?? source.endIndex)]
        #expect(disappearBody.contains("settleViewDetached(id)"))

        // The three signal classes: scroll geometry, selection change, composer.
        #expect(
            try line(containing: ".onScrollGeometryChange", in: source).contains("CGFloat"),
            "scrolling is observed through the pane's scroll geometry")
        let scrollAction = try #require(
            source.range(of: ".onScrollGeometryChange(for: CGFloat.self)")).upperBound
        let afterScroll = source[scrollAction...].prefix(400)
        #expect(afterScroll.contains("noteSettleActivity()"))
        #expect(
            source.contains(".onChange(of: selection) { _, _ in noteSettleActivity() }"),
            "a selection change is an activity signal")
        #expect(
            source.contains(".onChange(of: composerDraft) { _, _ in noteSettleActivity() }"),
            "composer typing is an activity signal")
    }

    @Test("SC-12: the activity signals are debounced to at most one a second")
    func debouncePinned() throws {
        let source = try source()
        let start = try #require(source.range(of: "private func noteSettleActivity()"))
        let body = source[start.upperBound...].prefix(400)
        let guardLine = try #require(
            body.split(separator: "\n").first { $0.contains("guard") })
        #expect(guardLine.contains("timeIntervalSince(lastSettleActivitySignal) >= 1"))
        #expect(guardLine.contains("return"), "a signal inside the second is dropped")
        // The stamp is taken only for a signal that passes, and before the call.
        let lines = body.split(separator: "\n").map(String.init)
        let stamp = try #require(lines.firstIndex { $0.contains("lastSettleActivitySignal = ") })
        let call = try #require(lines.firstIndex { $0.contains("noteMeetingActivity(id)") })
        #expect(stamp < call)
    }

    @Test("SC-12: the settle wiring renders nothing — no node, label or affordance")
    func settleWiringIsInvisible() throws {
        let source = try source()
        let renderingConstructors = [
            "Text(", "Label(", "Button(", "Image(", "ProgressView(", "Toggle(", "Menu(",
            "accessibilityLabel", "accessibilityValue", "accessibilityIdentifier", "help(",
        ]
        let settleTokens = [
            "settleViewAttached", "settleViewDetached", "noteMeetingActivity",
            "noteSettleActivity", "lastSettleActivitySignal",
        ]
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            guard settleTokens.contains(where: { line.contains($0) }) else { continue }
            for constructor in renderingConstructors {
                #expect(
                    !line.contains(constructor),
                    "the settle wiring must not reach a rendered node: \(line)")
            }
        }
        // And no rendered string names the settle, the pooled delivery or the
        // digest pass anywhere on the surface.
        for forbidden in ["Settling", "Pending delivery", "Reconciling", "Digest editor"] {
            #expect(!source.contains("Text(\"\(forbidden)"), "no \(forbidden) affordance")
            #expect(!source.contains("\"\(forbidden)\""), "no \(forbidden) label")
        }
    }
}
