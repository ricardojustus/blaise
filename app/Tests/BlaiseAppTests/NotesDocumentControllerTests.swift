import AppKit
import BlaiseCore
import SwiftUI
import Testing

@testable import BlaiseApp

// The one-text-view controller hosted in an off-screen window: placement,
// clicks, drawing work, lifetime and accessibility. Fictional notes only.

/// A window whose pointer location a test can set (nil: the real pointer).
private final class PointerWindow: NSWindow {
    var pointer: NSPoint?
    override var mouseLocationOutsideOfEventStream: NSPoint { pointer ?? super.mouseLocationOutsideOfEventStream }
}

@MainActor
private final class Hosted {
    let controller = NotesDocController()
    let window: PointerWindow
    var picked: [String] = []
    var cleared = 0
    var selections: [(String?, String?)] = []
    var toggled: [(String, Bool)] = []
    var menuActions: [(String, Bool)] = []
    /// The pane's selection as the pane keeps it, and the targets its
    /// right-click seam builds from it.
    var paneSelection: (blockID: String, span: SelectedSpan)?
    var targets: [EditingTarget] = []

    init(width: CGFloat = 818) {
        window = PointerWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 1000), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = controller.scrollView
        controller.scrollView.frame = NSRect(x: 0, y: 0, width: width, height: 1000)
        controller.scrollView.tile()
    }

    var callbacks: NotesDocCallbacks {
        NotesDocCallbacks(
            onSelection: { [unowned self] block, span in
                selections.append((block?.anchorID, span?.text))
                paneSelection = block.flatMap { block in span.map { (block.anchorID, $0) } }
            },
            onPassage: { _ in },
            onPick: { [unowned self] in
                picked.append($0.anchorID)
                paneSelection = nil
            },
            onClear: { [unowned self] in
                cleared += 1
                paneSelection = nil
            },
            onMenuAction: { [unowned self] kind, block, inSelection in
                menuActions.append((block.anchorID, inSelection))
                notesEditingContextMenuAction(
                    kind, section: block.section, blockText: block.blockText, occurrence: block.occurrence,
                    blockID: block.anchorID, selection: paneSelection, correctionEnabled: true,
                    engineCanEditNotes: true, hostText: block.hostText
                ) { targets.append($0) }
            },
            menuOffers: { (true, true) },
            onToggle: { [unowned self] item, done in toggled.append((item.text, done)) },
            onToggleCompleted: {}, onScroll: {})
    }

    func spec(
        _ doc: NotesDocument, marks: [String: NotesDocMark] = [:], attachments: [String: AnyView] = [:],
        composing: String? = nil, aim: NotesDocAim? = nil, rail: [String: AnyView] = [:]
    ) -> NotesDocumentView {
        NotesDocumentView(
            document: doc, marks: marks, attachments: attachments, composingAnchor: composing, rail: rail,
            railLane: !rail.isEmpty, completedExpanded: false, aim: aim,
            bar: aim == nil ? nil : NotesDocBarConfig(correctionEnabled: true, engineCanEditNotes: true) { _ in },
            scrollRequest: nil, callbacks: callbacks)
    }

    func show(_ spec: NotesDocumentView) {
        controller.update(spec)
        controller.update(spec)
    }

    func close() { window.contentView = nil }
}

@MainActor
private func document(summary: String = "The kelp survey moved to Thursday.", detailed: String) -> NotesDocument {
    NotesDocumentBuilder.build(
        NotesDocInput(
            structured: NotesStructured(
                summary: summary, detailedNotes: detailed, decisions: [], actionItems: [], userActionItems: []),
            doneKeys: [], searchTerms: [], portuguese: false, userActionTitle: "Demo User — Action Items",
            direction: .aquarela))
}

@MainActor
@Suite struct NotesDocumentDrawingTests {
    @Test("a span mark is drawn from the part of it on screen, one piece per line")
    func markWorkFollowsTheVisibleLines() throws {
        let long = String(repeating: "Quoll Harbor tide table and the Vexatron Labs buoy survey. ", count: 90)
        let doc = document(summary: long, detailed: "After the long paragraph, one closing line.")
        let hosted = Hosted(width: 500)
        defer { hosted.close() }
        hosted.show(hosted.spec(doc))
        let block = try #require(doc.blocks.first { $0.section == .summary && $0.range.length > 0 })
        let whole = hosted.controller.markRects(block.range, visible: NSRange(location: 0, length: doc.text.length))
        // One rounded piece per wrapped line of the paragraph, none twice.
        #expect(whole.count > 60)
        #expect(Set(whole.map { "\($0.minX),\($0.minY),\($0.width)" }).count == whole.count)
        // Only a window of it on screen: only that window's lines are walked.
        let window = NSRange(location: block.range.location + 1000, length: 200)
        let part = hosted.controller.markRects(block.range, visible: window)
        #expect(part.count >= 2 && part.count <= 5)
        // Off screen entirely: nothing.
        #expect(hosted.controller.markRects(block.range, visible: NSRange(location: NSMaxRange(block.range) + 1, length: 5)).isEmpty)
    }
}

@MainActor
@Suite struct NotesDocumentSelectionKeepTests {
    private let detailed = "The harbour crew checks the jetty lights.\n\n```\nbuild-4.2  frame p95 16.4 ms\n```\n\nVexatron Labs ships the buoy firmware."

    @Test("a copy selection inside code survives the aim being put down")
    func codeSelectionKeptForCopy() throws {
        let doc = document(detailed: detailed)
        let hosted = Hosted()
        defer { hosted.close() }
        let prose = try #require(doc.blocks.first { $0.blockText.hasPrefix("The harbour crew") })
        let code = try #require(doc.blocks.first { doc.paragraphs[$0.paragraph].isCode })
        // A block was picked: the bar stands at it.
        hosted.show(hosted.spec(doc, aim: NotesDocAim(anchorID: prose.anchorID, isSpan: false)))
        // The reader drags over code to copy it: nothing is aimed at…
        let inCode = NSRange(location: code.range.location + 2, length: 7)
        hosted.controller.textView.setSelectedRange(inCode)
        #expect(hosted.cleared == 1)
        // …the pane puts its aim down, and the code stays selected for Copy.
        hosted.controller.update(hosted.spec(doc, aim: nil))
        #expect(hosted.controller.textView.selectedRange() == inCode)
    }

    @Test("an aimed span is still collapsed when the pane puts the aim down")
    func aimedSpanCollapses() throws {
        let doc = document(detailed: detailed)
        let hosted = Hosted()
        defer { hosted.close() }
        let prose = try #require(doc.blocks.first { $0.blockText.hasPrefix("The harbour crew") })
        hosted.show(hosted.spec(doc))
        hosted.controller.textView.setSelectedRange(NSRange(location: prose.range.location + 4, length: 7))
        hosted.controller.update(hosted.spec(doc, aim: NotesDocAim(anchorID: prose.anchorID, isSpan: true)))
        hosted.controller.update(hosted.spec(doc, aim: nil))
        #expect(hosted.controller.textView.selectedRange().length == 0)
    }

    @Test("a new document with the selected block unchanged keeps the selection on the same words")
    func installKeepsSelection() throws {
        let doc = document(detailed: detailed)
        let hosted = Hosted()
        defer { hosted.close() }
        let last = try #require(doc.blocks.first { $0.blockText.hasPrefix("Vexatron Labs ships") })
        hosted.show(hosted.spec(doc))
        let span = NSRange(location: last.range.location + 14, length: 5)
        hosted.controller.textView.setSelectedRange(span)
        let words = (doc.text.string as NSString).substring(with: span)
        #expect(words == "ships")
        // The summary above it changes length (a rebuild, as a tick or a
        // search does): the same words stay selected at their new place.
        let rebuilt = document(summary: "The kelp survey moved to Thursday, then Friday.", detailed: detailed)
        hosted.controller.update(hosted.spec(rebuilt, aim: NotesDocAim(anchorID: last.anchorID, isSpan: true)))
        let kept = hosted.controller.textView.selectedRange()
        #expect(kept.length == 5)
        #expect((rebuilt.text.string as NSString).substring(with: kept) == "ships")
    }
}

@MainActor
@Suite struct NotesDocumentLifetimeTests {
    /// Hosts a pane, opens a composer under a block (its space slides open on
    /// the display link), then takes the pane down, torn down or not.
    private func slideThenDrop(tearDown: Bool) throws -> NotesDocController? {
        weak var weakController: NotesDocController?
        try autoreleasepool {
            let doc = document(detailed: "The harbour crew checks the jetty lights.\n\nVexatron Labs ships the buoy firmware.")
            let hosted = Hosted()
            weakController = hosted.controller
            let block = try #require(doc.blocks.first { $0.blockText.hasPrefix("The harbour crew") })
            hosted.show(hosted.spec(doc))
            let composer = AnyView(Text("Composer for Quoll Harbor").frame(height: 120))
            hosted.controller.update(hosted.spec(doc, attachments: [block.anchorID: composer], composing: block.anchorID))
            if tearDown { NotesDocumentView.dismantleNSView(hosted.controller.scrollView, coordinator: hosted.controller) }
            hosted.close()
        }
        return weakController
    }

    @Test("a pane torn down mid-slide lets its controller go")
    func teardownMidSlideReleases() throws {
        // Without the teardown the display link holds the controller: the
        // positive control that the check can see a leak at all.
        #expect(try slideThenDrop(tearDown: false) != nil)
        #expect(try slideThenDrop(tearDown: true) == nil)
    }
}

@MainActor
@Suite struct NotesDocumentTableClickTests {
    private func click(_ hosted: Hosted, at point: NSPoint) throws {
        let inWindow = hosted.controller.textView.convert(point, to: nil)
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: inWindow, modifierFlags: [], timestamp: 0,
            windowNumber: hosted.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        NSApplication.shared.sendEvent(event)
    }

    @Test("a click on the selection bar standing over a table keeps the bar's aim; a click on the table picks it")
    func barOverTableKeepsItsClick() throws {
        let doc = document(
            detailed: "Vexatron Labs lists the harbour workstreams below.\n\n| Workstream | Owner |\n|---|---|\n| Buoy firmware | Quoll Harbor |\n| Tide table | Vexatron Labs |\n| Jetty lights | Quoll Harbor |\n\nAfter the table, one closing line.")
        let table = try #require(doc.blocks.first { $0.table != nil })
        let intro = try #require(doc.blocks.first { $0.blockText.hasPrefix("Vexatron Labs lists") })
        let hosted = Hosted()
        defer { hosted.close() }
        hosted.show(hosted.spec(
            doc, attachments: [table.anchorID: AnyView(MarkdownBlockView(block: table.table!, searchTerms: []))],
            aim: NotesDocAim(anchorID: intro.anchorID, isSpan: false)))
        let views = hosted.controller.textView.subviews.flatMap { $0.subviews }
        let tableClip = try #require(views.first { $0 is NotesDocClip })
        let bar = try #require(views.first {
            $0 is NSHostingView<AnyView> && abs($0.frame.height - SelectionActionBar.size.height) < 0.5
        })
        // The bar stands inside the table's space (the case that went wrong).
        #expect(!tableClip.frame.intersection(bar.frame).isEmpty)
        try click(hosted, at: NSPoint(x: bar.frame.midX, y: bar.frame.midY + 2))
        #expect(hosted.picked.isEmpty)
        // A click on the table's own rows, clear of the bar, picks the table.
        let onTable = NSPoint(x: tableClip.frame.maxX - 40, y: tableClip.frame.maxY - 20)
        #expect(!bar.frame.contains(onTable))
        try click(hosted, at: onTable)
        #expect(hosted.picked == [table.anchorID])
    }
}

@MainActor
@Suite struct NotesDocumentAccessibilityMembershipTests {
    /// Runs the slide to its end: waits out the spring, then one frame.
    private func settle(_ controller: NotesDocController) {
        Thread.sleep(forTimeInterval: 0.8)
        let link = controller.textView.displayLink(target: controller, selector: Selector(("tick:")))
        controller.perform(Selector(("tick:")), with: link)
        link.invalidate()
    }

    @Test("a composer that slid away is no longer in the accessibility children")
    func closedComposerLeavesTheTree() throws {
        let doc = document(detailed: "The harbour crew checks the jetty lights.\n\nVexatron Labs ships the buoy firmware.")
        let block = try #require(doc.blocks.first { $0.blockText.hasPrefix("The harbour crew") })
        let hosted = Hosted()
        defer { hosted.close() }
        let controller = hosted.controller
        hosted.show(hosted.spec(doc))
        let composer = AnyView(Text("Composer for Quoll Harbor").frame(height: 120))
        controller.update(hosted.spec(doc, attachments: [block.anchorID: composer], composing: block.anchorID))
        settle(controller)
        let hostViews = { (controller.textView.accessibilityChildren() ?? []).filter { $0 is NSView } }
        let withComposer = hostViews().count
        #expect(withComposer == 1)
        // Closing: the tree is read mid-slide (still there), then the slide ends.
        controller.update(hosted.spec(doc))
        #expect(hostViews().count == withComposer)
        settle(controller)
        #expect(hostViews().count == withComposer - 1)
    }
}

@MainActor
@Suite struct NotesDocumentAccessibilityTextTests {
    @Test("blocks read as text areas with character, line and selection access; headings and the box label stay")
    func blocksKeepTheTextInterface() throws {
        let paragraph = "Vexatron Labs moved the buoy survey to Thursday because the Quoll Harbor tide table slipped, and the jetty lights still need a check before the ferry runs again."
        let doc = NotesDocumentBuilder.build(
            NotesDocInput(
                structured: NotesStructured(
                    summary: "The kelp survey moved to Thursday.", detailedNotes: paragraph,
                    decisions: ["The harbour lights stay amber."], actionItems: [],
                    userActionItems: [ActionItem(owner: "Demo User", text: "Send the tide table to Quoll Harbor.")]),
                doneKeys: [], searchTerms: [], portuguese: false, userActionTitle: "Demo User — Action Items",
                direction: .aquarela))
        let hosted = Hosted(width: 420)
        defer { hosted.close() }
        hosted.show(hosted.spec(doc))
        let children = try #require(hosted.controller.textView.accessibilityChildren())
        let elements = children.compactMap { $0 as? NSAccessibilityElement }

        // Headings, and the box as a labelled group.
        let headings = elements.filter { $0.accessibilityRole() == NotesDocController.headingRole }
        #expect(headings.compactMap { $0.accessibilityLabel() }.contains("Summary"))
        let box = try #require(elements.first { $0.accessibilityLabel() == "Your action items" })
        #expect(box.accessibilityRole() == .group)

        // The detailed paragraph: a text area whose value is its words.
        let texts = elements.compactMap { $0 as? NotesDocAccessibilityText }.filter { $0.accessibilityRole() == .textArea }
        let element = try #require(texts.first { ($0.accessibilityValue() as? String) == paragraph })
        #expect(element.accessibilityNumberOfCharacters() == (paragraph as NSString).length)
        #expect(element.accessibilityString(for: NSRange(location: 9, length: 4)) == "Labs")

        // Lines: more than one at this width, contiguous, covering the words.
        var lines: [NSRange] = []
        var line = 0
        while case let range = element.accessibilityRange(forLine: line), range.location != NSNotFound {
            lines.append(range)
            line += 1
        }
        #expect(lines.count > 1)
        #expect(lines.first?.location == 0)
        #expect(NSMaxRange(lines.last!) == (paragraph as NSString).length)
        #expect(element.accessibilityLine(for: NSMaxRange(lines[0])) == 1)
        #expect(element.accessibilityFrame(for: NSRange(location: 0, length: 4)).width > 0)

        // Selecting through the element selects in the text view and aims.
        element.setAccessibilitySelectedTextRange(NSRange(location: 9, length: 4))
        #expect(element.accessibilitySelectedTextRange() == NSRange(location: 9, length: 4))
        #expect(element.accessibilitySelectedText() == "Labs")
        let block = try #require(doc.blocks.first { $0.blockText == paragraph })
        #expect(hosted.controller.textView.selectedRange() == NSRange(location: block.range.location + 9, length: 4))
        #expect(hosted.selections.last?.0 == block.anchorID)
        #expect(hosted.selections.last?.1 == "Labs")
    }
}

@MainActor
@Suite struct NotesDocumentAccessibilityLinkTests {
    @Test("a link in a block is its own link element, named by its words, with its URL, and marked in the block's text")
    func linksKeepTheirSemantics() throws {
        let summary = "The kelp survey moved to Thursday; see the [tide board](https://example.com/tide) for the dates."
        let doc = document(summary: summary, detailed: "The harbour crew checks the jetty lights.")
        let hosted = Hosted()
        defer { hosted.close() }
        hosted.show(hosted.spec(doc))
        let elements = try #require(hosted.controller.textView.accessibilityChildren())
            .compactMap { $0 as? NotesDocAccessibilityText }
        let block = try #require(elements.first { ($0.accessibilityValue() as? String)?.contains("tide board") == true })
        let links = try #require(block.accessibilityChildren()).compactMap { $0 as? NSAccessibilityElement }
        #expect(links.count == 1)
        let link = try #require(links.first)
        #expect(link.accessibilityRole() == .link)
        #expect(link.accessibilityLabel() == "tide board")
        #expect(link.accessibilityURL() == URL(string: "https://example.com/tide"))
        #expect(link.accessibilityFrame().width > 0)
        // The block's attributed text carries the link element over its words.
        let words = try #require(block.accessibilityValue() as? String) as NSString
        let whole = try #require(block.accessibilityAttributedString(for: NSRange(location: 0, length: words.length)))
        let at = words.range(of: "tide board")
        var effective = NSRange()
        let value = whole.attribute(.accessibilityLink, at: at.location, effectiveRange: &effective)
        #expect((value as AnyObject?) === link)
        #expect(effective == at)
        #expect(whole.attribute(.accessibilityLink, at: 0, effectiveRange: nil) == nil)
        // (Pressing it opens the URL; not done in a test. The driven build presses it.)
    }
}

@MainActor
@Suite struct NotesDocumentAccessibilityOrderTests {
    @Test("a checklist item reads its done button, then its words, as today's row does")
    func toggleBeforeItsWords() throws {
        let items = ["Send the tide table to Quoll Harbor.", "Book the jetty crane for Vexatron Labs."]
        let doc = NotesDocumentBuilder.build(
            NotesDocInput(
                structured: NotesStructured(
                    summary: "The kelp survey moved to Thursday.", detailedNotes: "One closing line.",
                    decisions: [], actionItems: [], userActionItems: items.map { ActionItem(owner: "Demo User", text: $0) }),
                doneKeys: [], searchTerms: [], portuguese: false, userActionTitle: "Demo User — Action Items",
                direction: .aquarela))
        let hosted = Hosted()
        defer { hosted.close() }
        hosted.show(hosted.spec(doc))
        let children = try #require(hosted.controller.textView.accessibilityChildren())
        let box = try #require(
            children.compactMap { $0 as? NSAccessibilityElement }.first { $0.accessibilityLabel() == "Your action items" })
        let inBox = try #require(box.accessibilityChildren())
        let order = inBox.map { child -> String in
            if let text = child as? NotesDocAccessibilityText { return "text \(text.words)" }
            return "button"
        }
        #expect(order == ["text Demo User — Action Items", "button", "text \(items[0])", "button", "text \(items[1])"])
    }
}

@MainActor
@Suite struct NotesDocumentFluidoReplaceTests {
    private func doc(summaryParagraphs: Int, items: [String], done: [String], expanded: Bool = false) -> NotesDocument {
        let summary = (0..<summaryParagraphs).map { "Quoll Harbor tide note \($0) for the Vexatron Labs crew." }
            .joined(separator: "\n\n")
        return NotesDocumentBuilder.build(
            NotesDocInput(
                structured: NotesStructured(
                    summary: summary, detailedNotes: "One closing line.", decisions: [], actionItems: [],
                    userActionItems: items.map { ActionItem(owner: "Demo User", text: $0) }),
                doneKeys: Set(done.map { ActionItemKey.key(for: $0) }), searchTerms: [], portuguese: false,
                userActionTitle: "Demo User — Action Items", completedExpanded: expanded, direction: .fluido))
    }

    private func leaving(_ hosted: Hosted) -> [NSImageView] {
        hosted.controller.textView.subviews.flatMap(\.subviews).compactMap { $0 as? NSImageView }
    }

    /// A tick starts the completion motion on a long note; before it settles a
    /// rewrite installs a much shorter note with the same items; frames go on.
    private func replaceMidMotion(items: [String], ticked: String) throws {
        let hosted = Hosted()
        defer { hosted.close() }
        hosted.show(hosted.spec(doc(summaryParagraphs: 100, items: items, done: [])))
        hosted.controller.update(hosted.spec(doc(summaryParagraphs: 100, items: items, done: [ticked])))
        // The motion is running: the ticked row's picture is on the page.
        try #require(!leaving(hosted).isEmpty, "no completion motion started (Reduce Motion on?)")
        let short = doc(summaryParagraphs: 1, items: items, done: [ticked])
        hosted.controller.update(hosted.spec(short))
        let link = hosted.controller.textView.displayLink(target: hosted.controller, selector: Selector(("motionTick:")))
        for _ in 0..<3 { hosted.controller.perform(Selector(("motionTick:")), with: link) }
        link.invalidate()
        // The old motion is over: no picture left, and every paragraph of the
        // new text keeps its own spacing.
        #expect(leaving(hosted).isEmpty)
        let storage = try #require(hosted.controller.textView.textStorage)
        for paragraph in short.paragraphs where paragraph.range.length > 0 {
            let style = storage.attribute(.paragraphStyle, at: paragraph.range.location, effectiveRange: nil) as? NSParagraphStyle
            #expect(style?.paragraphSpacing == paragraph.style.paragraphSpacing)
        }
    }

    @Test("a rewrite landing while an item's completion settles ends that motion; the new note is laid out as built")
    func rewriteMidSettle() throws {
        try replaceMidMotion(
            items: ["Send the tide table to Quoll Harbor.", "Book the jetty crane for Vexatron Labs."],
            ticked: "Send the tide table to Quoll Harbor.")
    }

    @Test("an un-ticked item comes back on the spring: its space opens from nothing while its picture fades in; then it is itself again")
    func untickArrives() throws {
        let items = ["Send the tide table to Quoll Harbor.", "Book the jetty crane for Vexatron Labs."]
        let hosted = Hosted()
        defer { hosted.close() }
        let oneDone = doc(summaryParagraphs: 3, items: items, done: [items[0]])
        hosted.show(hosted.spec(oneDone))
        let completed = oneDone.paragraphs[try #require(oneDone.completedDisclosure)].range
        let completedLine = try #require(hosted.controller.markRects(
            completed, visible: NSRange(location: 0, length: oneDone.text.length)).first)
        let back = doc(summaryParagraphs: 3, items: items, done: [])
        hosted.controller.update(hosted.spec(back))
        let row = try #require(back.blocks.first { $0.section == .userActionItem && $0.blockText == items[0] })
        let storage = try #require(hosted.controller.textView.textStorage)
        func style() -> NSParagraphStyle? {
            storage.attribute(.paragraphStyle, at: row.range.location, effectiveRange: nil) as? NSParagraphStyle
        }
        // Arriving: its picture is on the page, its own words are out of sight
        // and its lines take (almost) no height yet.
        try #require(leaving(hosted).count == 2, "the arriving row and the going Completed line (Reduce Motion on?)")
        #expect(leaving(hosted)[0].alphaValue < 0.05)
        // Its Completed line goes with it: pictured where it stood, fading out.
        #expect(leaving(hosted)[1].alphaValue == 1)
        #expect(leaving(hosted)[1].frame.contains(NSPoint(x: completedLine.midX, y: completedLine.midY)))
        #expect((style()?.maximumLineHeight ?? 99) <= 1)
        #expect((storage.attribute(.foregroundColor, at: row.range.location, effectiveRange: nil) as? NSColor)?.alphaComponent == 0)
        // The spring runs out: the picture goes, the row is its own again.
        Thread.sleep(forTimeInterval: NotesDocController.settleDuration + 0.05)
        let link = hosted.controller.textView.displayLink(target: hosted.controller, selector: Selector(("motionTick:")))
        hosted.controller.perform(Selector(("motionTick:")), with: link)
        link.invalidate()
        #expect(leaving(hosted).isEmpty)
        #expect(style()?.maximumLineHeight == 0)
        #expect(style()?.paragraphSpacing == back.paragraphs[row.paragraph].style.paragraphSpacing)
        #expect(
            storage.attribute(.foregroundColor, at: row.range.location, effectiveRange: nil) as? NSColor
                == back.text.attribute(.foregroundColor, at: row.range.location, effectiveRange: nil) as? NSColor)
        // Outside Fluido an un-tick is instant, as today.
        let plain = Hosted()
        defer { plain.close() }
        func aquarela(_ done: [String]) -> NotesDocument {
            NotesDocumentBuilder.build(
                NotesDocInput(
                    structured: NotesStructured(
                        summary: "The kelp survey moved to Thursday.", detailedNotes: "One closing line.", decisions: [],
                        actionItems: [], userActionItems: items.map { ActionItem(owner: "Demo User", text: $0) }),
                    doneKeys: Set(done.map { ActionItemKey.key(for: $0) }), searchTerms: [], portuguese: false,
                    userActionTitle: "Demo User — Action Items", direction: .aquarela))
        }
        plain.show(plain.spec(aquarela([items[0]])))
        plain.controller.update(plain.spec(aquarela([])))
        #expect(leaving(plain).isEmpty)
    }

    @Test("an un-ticked item's side notes arrive with it, and the last one back fades \"All done.\" out")
    func untickBringsItsNotesAndTakesAllDone() throws {
        func tick(_ hosted: Hosted) {
            let link = hosted.controller.textView.displayLink(target: hosted.controller, selector: Selector(("motionTick:")))
            hosted.controller.perform(Selector(("motionTick:")), with: link)
            link.invalidate()
        }
        // Margin mode: the returning item carries a side note.
        let items = ["Send the tide table to Quoll Harbor.", "Book the jetty crane for Vexatron Labs."]
        let hosted = Hosted(width: 1300)
        defer { hosted.close() }
        let back = doc(summaryParagraphs: 3, items: items, done: [])
        let row = try #require(back.blocks.first { $0.section == .userActionItem && $0.blockText == items[0] })
        let rail = [row.anchorID: AnyView(Color.clear.frame(height: 61))]
        hosted.show(hosted.spec(doc(summaryParagraphs: 3, items: items, done: [items[0]]), rail: rail))
        hosted.controller.update(hosted.spec(back, rail: rail))
        let picture = try #require(leaving(hosted).first, "no arrival started (Reduce Motion on?)")
        let note = try #require(hosted.controller.textView.subviews.flatMap(\.subviews).first {
            $0 is NSHostingView<AnyView> && abs($0.frame.width - NotesEditingLayout.railWidth) < 0.5
        })
        Thread.sleep(forTimeInterval: 0.12)
        tick(hosted)
        #expect(picture.alphaValue > 0.05)
        #expect(abs(note.alphaValue - picture.alphaValue) < 0.01, "the note arrives with its row")
        Thread.sleep(forTimeInterval: NotesDocController.settleDuration)
        tick(hosted)
        #expect(note.alphaValue == 1)
        // The last done item comes back: "All done." fades out on the same
        // spring while the row fades in.
        let one = [items[0]]
        let last = Hosted()
        defer { last.close() }
        let allDone = doc(summaryParagraphs: 3, items: one, done: one)
        last.show(last.spec(allDone))
        let box = try #require(allDone.sections.first { $0.kind == .userActions })
        let line = allDone.paragraphs[box.firstContent].range
        #expect((allDone.text.string as NSString).substring(with: line).hasPrefix("All done."))
        let shown = try #require(last.controller.markRects(line, visible: NSRange(location: 0, length: allDone.text.length)).first)
        last.controller.update(last.spec(doc(summaryParagraphs: 3, items: one, done: [])))
        #expect(leaving(last).count == 2, "the arriving row and the leaving \"All done.\"")
        let going = try #require(leaving(last).max { $0.alphaValue < $1.alphaValue })
        #expect(going.alphaValue == 1)
        #expect(going.frame.contains(NSPoint(x: shown.midX, y: shown.midY)), "the picture is of \"All done.\"")
        Thread.sleep(forTimeInterval: 0.12)
        tick(last)
        #expect(going.alphaValue < 0.95 && going.alphaValue >= 0)
        Thread.sleep(forTimeInterval: NotesDocController.settleDuration)
        tick(last)
        #expect(leaving(last).isEmpty)
    }

    @Test("an un-tick holds the space of what leaves the box (\"All done.\", the Completed line, an expanded list's done row) and closes it on the row's spring")
    func untickHoldsWhatLeaves() throws {
        let a = "Send the tide table to Quoll Harbor.", b = "Book the jetty crane for Vexatron Labs."
        let c = "Check the buoy firmware with Kestrel."
        // Items, done before the un-tick of `a`, whether the Completed list is
        // expanded, and whether the Completed line is watched (else the section
        // under the box).
        let cases: [(items: [String], done: [String], expanded: Bool, completedStays: Bool)] = [
            ([a, b], [a, b], false, true),  // "All done." leaves; "Completed (2)" becomes "Completed (1)"
            ([a], [a], false, false),  // "All done." and the Completed line leave
            ([a, b], [a], false, false),  // the Completed line leaves
            ([a, b, c], [a, b], true, false),  // `a`'s done row leaves the Completed list
            ([a, b], [a, b], true, false),  // "All done." leaves above the Completed line, `a`'s done row below it
        ]
        for (items, done, expanded, completedStays) in cases {
            let hosted = Hosted()
            defer { hosted.close() }
            let before = doc(summaryParagraphs: 3, items: items, done: done, expanded: expanded)
            let after = doc(summaryParagraphs: 3, items: items, done: done.filter { $0 != a }, expanded: expanded)
            func watched(_ doc: NotesDocument) throws -> Int {
                let box = try #require(doc.sections.first { $0.kind == .userActions })
                if completedStays { return try #require(doc.completedDisclosure) }
                return try #require(doc.sections.first { $0.title > box.lastContent }).title
            }
            func top(_ doc: NotesDocument) throws -> CGFloat {
                let range = doc.paragraphs[try watched(doc)].range
                return try #require(hosted.controller.markRects(
                    NSRange(location: range.location, length: 1), visible: NSRange(location: 0, length: doc.text.length)
                ).first).minY
            }
            hosted.show(hosted.spec(before))
            let start = try top(before)
            // The box's own card, found by the line it holds.
            let box = try #require(before.sections.first { $0.kind == .userActions })
            let inBox = try #require(hosted.controller.markRects(
                before.paragraphs[box.firstContent].range, visible: NSRange(location: 0, length: before.text.length)).first)
            let card = try #require(hosted.controller.scrollView.contentView.subviews.first {
                $0 is NSVisualEffectView && $0.frame.contains(NSPoint(x: inBox.midX, y: inBox.midY))
            })
            let cardStart = card.frame.maxY
            // An expanded list's done row, where it stood.
            let doneRow = expanded ? before.toggles.first { $0.done && $0.item.text == a }.flatMap {
                hosted.controller.markRects(
                    before.paragraphs[$0.paragraph].range, visible: NSRange(location: 0, length: before.text.length)).first
            } : nil
            hosted.controller.update(hosted.spec(after))
            try #require(!leaving(hosted).isEmpty, "no arrival started (Reduce Motion on?)")
            let rowPicture = doneRow.flatMap { row in
                leaving(hosted).first { $0.alphaValue == 1 && $0.frame.contains(NSPoint(x: row.midX, y: row.midY)) }
            }
            let link = hosted.controller.textView.displayLink(target: hosted.controller, selector: Selector(("motionTick:")))
            defer { link.invalidate() }
            var frames = [try top(after)]
            var cardFrames = [card.frame.maxY]
            var rowAlphas = [rowPicture?.alphaValue ?? 0]
            for _ in 0..<8 {
                Thread.sleep(forTimeInterval: 0.016)
                hosted.controller.perform(Selector(("motionTick:")), with: link)
                frames.append(try top(after))
                cardFrames.append(card.frame.maxY)
                rowAlphas.append(rowPicture?.alphaValue ?? 0)
            }
            Thread.sleep(forTimeInterval: NotesDocController.settleDuration)
            hosted.controller.perform(Selector(("motionTick:")), with: link)
            let settled = try top(after)
            #expect(leaving(hosted).isEmpty)
            // Nothing jumps off the path from where it stood to where it
            // settles: the line watched, and the box's bottom edge.
            func onPath(_ path: [CGFloat], _ from: CGFloat, _ to: CGFloat) -> Bool {
                path.allSatisfy { $0 >= min(from, to) - 1 && $0 <= max(from, to) + 1 }
            }
            let shape = "\(done.count) of \(items.count) done, expanded \(expanded), stays \(completedStays)"
            #expect(
                onPath(frames, start, settled) && abs(frames[0] - start) <= 1,
                "\(shape): before \(start) frames \(frames) settled \(settled)")
            #expect(
                onPath(cardFrames, cardStart, card.frame.maxY),
                "\(shape), box bottom: before \(cardStart) frames \(cardFrames) settled \(card.frame.maxY)")
            // The done row itself fades out over its held space (today's default `.opacity`).
            if doneRow != nil {
                #expect(
                    rowPicture != nil && zip(rowAlphas, rowAlphas.dropFirst()).allSatisfy { $1 <= $0 }
                        && rowAlphas.last! < rowAlphas[0],
                    "\(shape), done row: pictured \(rowPicture != nil), alphas \(rowAlphas)")
            }
        }
    }

    @Test("a rewrite landing while an un-ticked item arrives ends that motion; the new note is laid out as built")
    func rewriteMidArrival() throws {
        try replaceMidArrival(items: ["Send the tide table to Quoll Harbor.", "Book the jetty crane for Vexatron Labs."])
    }

    @Test("a rewrite landing while the last done item comes back takes the fading \"All done.\" away too")
    func rewriteMidLastArrival() throws {
        try replaceMidArrival(items: ["Send the tide table to Quoll Harbor."])
    }

    @Test("a rewrite landing while an expanded list's un-tick fades \"All done.\" and the done row takes both pictures away")
    func rewriteMidExpandedArrival() throws {
        let items = ["Send the tide table to Quoll Harbor.", "Book the jetty crane for Vexatron Labs."]
        try replaceMidArrival(items: items, done: items, expanded: true)
    }

    /// An un-tick of the first item starts the arrival on a long note (with
    /// "All done.", the Completed line or an expanded list's done row fading
    /// out); before it lands a rewrite installs a much shorter note; frames go on.
    private func replaceMidArrival(items: [String], done: [String]? = nil, expanded: Bool = false) throws {
        let hosted = Hosted()
        defer { hosted.close() }
        let done = done ?? [items[0]], back = done.filter { $0 != items[0] }
        hosted.show(hosted.spec(doc(summaryParagraphs: 100, items: items, done: done, expanded: expanded)))
        hosted.controller.update(hosted.spec(doc(summaryParagraphs: 100, items: items, done: back, expanded: expanded)))
        try #require(leaving(hosted).count == (expanded ? 3 : 2), "no arrival started (Reduce Motion on?)")
        let short = doc(summaryParagraphs: 1, items: items, done: back, expanded: expanded)
        hosted.controller.update(hosted.spec(short))
        let link = hosted.controller.textView.displayLink(target: hosted.controller, selector: Selector(("motionTick:")))
        for _ in 0..<3 { hosted.controller.perform(Selector(("motionTick:")), with: link) }
        link.invalidate()
        #expect(leaving(hosted).isEmpty)
        let storage = try #require(hosted.controller.textView.textStorage)
        for paragraph in short.paragraphs where paragraph.range.length > 0 {
            let style = storage.attribute(.paragraphStyle, at: paragraph.range.location, effectiveRange: nil) as? NSParagraphStyle
            #expect(style?.paragraphSpacing == paragraph.style.paragraphSpacing)
            #expect(style?.maximumLineHeight == paragraph.style.maximumLineHeight)
        }
    }

    @Test("a resize during the shine pictures the notes again; an unchanged frame keeps its picture; a scroll ends it")
    func shineFollowsTheLayout() throws {
        func sweep(_ body: (Hosted, () -> [NotesDocShineView]) throws -> Void) throws {
            let hosted = Hosted()
            defer { hosted.close() }
            var spec = hosted.spec(doc(summaryParagraphs: 60, items: ["Send the tide table to Quoll Harbor."], done: []))
            hosted.show(spec)
            spec.shineTick = 1
            hosted.controller.update(spec)
            let link = hosted.controller.textView.displayLink(target: hosted.controller, selector: Selector(("motionTick:")))
            defer { link.invalidate() }
            try body(hosted) {
                hosted.controller.perform(Selector(("motionTick:")), with: link)
                return hosted.controller.textView.subviews.flatMap(\.subviews).compactMap { $0 as? NotesDocShineView }
            }
        }
        // The pane narrows mid-sweep: the notes reflow, and the shine's
        // picture is theirs again, not the wider page's.
        try sweep { hosted, frame in
            let first = try #require(frame().first, "no shine started (Reduce Motion on?)")
            #expect(frame().first === first, "an unchanged layout is not pictured again")
            hosted.controller.scrollView.frame = NSRect(x: 0, y: 0, width: 560, height: 1000)
            hosted.controller.scrollView.tile()
            let shines = frame()
            #expect(shines.count == 1)
            let after = try #require(shines.first)
            #expect(after !== first)
            #expect(after.frame.width < first.frame.width)
        }
        // A scroll mid-sweep: the layout is unchanged, so the sweep ends
        // rather than picturing the viewport again on every scroll frame.
        try sweep { hosted, frame in
            let first = try #require(frame().first, "no shine started (Reduce Motion on?)")
            let textFrame = hosted.controller.textView.frame
            hosted.controller.textView.scroll(NSPoint(x: 0, y: 400))
            #expect(hosted.controller.textView.visibleRect.minY >= 400, "the notes did not scroll")
            #expect(hosted.controller.textView.frame == textFrame)
            #expect(frame().isEmpty, "a scroll ends the shine")
            #expect(first.superview == nil)
            #expect(frame().isEmpty, "the ended shine is not pictured again")
        }
    }

    @Test("a rewrite landing while the last item's completion fades \"All done.\" in ends that motion too")
    func rewriteMidLastItem() throws {
        try replaceMidMotion(items: ["Send the tide table to Quoll Harbor."], ticked: "Send the tide table to Quoll Harbor.")
    }
}

@MainActor
@Suite struct NotesDocumentPassageMenuTests {
    @Test("a right-click on a section title inside a spanning selection offers the actions, on the selection")
    func titleInsideASelectionActsOnIt() throws {
        let doc = NotesDocumentBuilder.build(
            NotesDocInput(
                structured: NotesStructured(
                    summary: "The Quoll Harbor crew signs in May.", detailedNotes: "One closing line.",
                    decisions: ["Keep the Vexatron barge contract for the season."], actionItems: [], userActionItems: []),
                doneKeys: [], searchTerms: [], portuguese: false, userActionTitle: "Demo User — Action Items",
                direction: .aquarela))
        let summary = try #require(doc.blocks.first { $0.section == .summary && $0.range.length > 0 })
        let decision = try #require(doc.blocks.first { $0.section == .decision })
        let title = try #require(doc.sections.first { $0.kind == .decisions }).title
        let hosted = Hosted()
        defer { hosted.close() }
        let aim = NotesDocAim(anchorID: decision.anchorID, isSpan: true, isPassage: true)
        hosted.show(hosted.spec(doc))
        let selection = NSRange(
            location: summary.range.location + 21, length: decision.range.location + 20 - (summary.range.location + 21))
        hosted.controller.textView.setSelectedRange(selection)
        hosted.controller.update(hosted.spec(doc, aim: aim))
        let heading = try #require(hosted.controller.markRects(
            NSRange(location: doc.paragraphs[title].range.location + 1, length: 3),
            visible: NSRange(location: 0, length: doc.text.length)).first)
        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: hosted.controller.textView.convert(NSPoint(x: heading.midX, y: heading.midY), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: hosted.window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1))
        let system = NSMenu()
        system.addItem(withTitle: "Look Up", action: nil, keyEquivalent: "")
        let menu = try #require(hosted.controller.menu(for: event) { system })
        #expect(menu.items.map(\.title).prefix(2) == ["\(SelectionActionBar.title(.correct))…", "Add Note…"])
        #expect(menu.items.contains { $0.title == "Look Up" }, "the system text menu stays under them")
        let note = try #require(menu.items.first { $0.title == "Add Note…" })
        _ = (note.target as? NSObject)?.perform(note.action)
        #expect(hosted.menuActions.last?.0 == decision.anchorID)
        #expect(hosted.menuActions.last?.1 == true, "acts on the selection")
        // Outside the selection a title still gives only the system menu.
        hosted.controller.textView.setSelectedRange(NSRange(location: 0, length: 0))
        hosted.controller.update(hosted.spec(doc))
        #expect(hosted.controller.menu(for: event) { system } === system)
    }

    @Test("a right-click on a title inside a title-plus-one-paragraph selection acts on the aimed paragraph")
    func titleInsideAOnePieceSelectionActsOnIt() throws {
        let doc = NotesDocumentBuilder.build(
            NotesDocInput(
                structured: NotesStructured(
                    summary: "The Quoll Harbor crew signs in May.", detailedNotes: "One closing line.",
                    decisions: ["Keep the Vexatron barge contract for the season."], actionItems: [], userActionItems: []),
                doneKeys: [], searchTerms: [], portuguese: false, userActionTitle: "Demo User — Action Items",
                direction: .aquarela))
        let decision = try #require(doc.blocks.first { $0.section == .decision })
        let title = try #require(doc.sections.first { $0.kind == .decisions }).title
        let hosted = Hosted()
        defer { hosted.close() }
        hosted.show(hosted.spec(doc))
        // A drag from inside the title into the decision: one piece, aimed at the decision.
        let start = doc.paragraphs[title].range.location + 1
        hosted.controller.textView.setSelectedRange(NSRange(location: start, length: decision.range.location + 20 - start))
        #expect(hosted.selections.last?.0 == decision.anchorID)
        hosted.controller.update(hosted.spec(doc, aim: NotesDocAim(anchorID: decision.anchorID, isSpan: true)))
        let heading = try #require(hosted.controller.markRects(
            NSRange(location: start, length: 3), visible: NSRange(location: 0, length: doc.text.length)).first)
        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: hosted.controller.textView.convert(NSPoint(x: heading.midX, y: heading.midY), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: hosted.window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1))
        let system = NSMenu()
        system.addItem(withTitle: "Look Up", action: nil, keyEquivalent: "")
        let menu = try #require(hosted.controller.menu(for: event) { system })
        #expect(menu.items.map(\.title).prefix(2) == ["\(SelectionActionBar.title(.correct))…", "Add Note…"])
        let note = try #require(menu.items.first { $0.title == "Add Note…" })
        _ = (note.target as? NSObject)?.perform(note.action)
        #expect(hosted.menuActions.last?.0 == decision.anchorID)
        #expect(hosted.menuActions.last?.1 == true, "acts on the selection")
    }
}

@MainActor
@Suite struct NotesDocumentHeaderMotionTests {
    @Test("the header's height changes at once, as the top of today's page does; a composer still slides")
    func headerNeverSlides() throws {
        let doc = document(detailed: "The harbour crew checks the jetty lights.\n\nVexatron Labs ships the buoy firmware.")
        let block = try #require(doc.blocks.first { $0.blockText.hasPrefix("The harbour crew") })
        let hosted = Hosted()
        defer { hosted.close() }
        let header = { (height: CGFloat) in AnyView(Color.clear.frame(height: height)) }
        hosted.show(hosted.spec(doc, attachments: [NotesDocument.headAnchor: header(99)]))
        let clips = { hosted.controller.textView.subviews.flatMap(\.subviews).compactMap { $0 as? NotesDocClip } }
        let headClip = { try #require(clips().min { $0.frame.minY < $1.frame.minY }) }
        #expect(try headClip().frame.height == 99)
        // The header grows after first sight (a line loads into it): at once.
        let composer = AnyView(Color.clear.frame(height: 120))
        hosted.controller.update(hosted.spec(
            doc, attachments: [NotesDocument.headAnchor: header(128), block.anchorID: composer], composing: block.anchorID))
        #expect(try headClip().frame.height == 128)
        // The composer opened in the same update is still on its way.
        let composerClip = try #require(clips().max { $0.frame.minY < $1.frame.minY })
        #expect(composerClip.frame.height < 120)
    }
}

@MainActor
@Suite struct NotesDocumentMarginRailTests {
    private let items = ["Send the tide table to Quoll Harbor.", "Book the jetty crane for Vexatron Labs."]

    private func doc(done: Set<String> = []) -> NotesDocument {
        NotesDocumentBuilder.build(
            NotesDocInput(
                structured: NotesStructured(
                    summary: "The kelp survey moved to Thursday.", detailedNotes: "One closing line.",
                    decisions: ["The harbour lights stay amber.", "The buoy survey runs weekly.", "The ferry keeps its slot."],
                    actionItems: [], userActionItems: items.map { ActionItem(owner: "Demo User", text: $0) }),
                doneKeys: Set(done.map { ActionItemKey.key(for: $0) }), searchTerms: [], portuguese: false,
                userActionTitle: "Demo User — Action Items", direction: .aquarela))
    }

    /// A rail note taller than its one-line block, told apart by its height.
    private func note(_ height: CGFloat) -> AnyView { AnyView(Color.clear.frame(height: height)) }

    private func rails(_ hosted: Hosted) -> [NSView] {
        hosted.controller.textView.subviews.flatMap(\.subviews).filter {
            $0 is NSHostingView<AnyView> && abs($0.frame.width - NotesEditingLayout.railWidth) < 0.5
        }
    }

    /// The top of a paragraph's first line and the bottom of its last, read from the layout.
    private func lines(_ hosted: Hosted, _ doc: NotesDocument, _ paragraph: Int) throws -> (top: CGFloat, bottom: CGFloat) {
        let tv = hosted.controller.textView
        let tlm = try #require(tv.textLayoutManager)
        let tcm = try #require(tlm.textContentManager)
        let location = try #require(tcm.location(tcm.documentRange.location, offsetBy: doc.paragraphs[paragraph].range.location))
        var found: NSTextLayoutFragment?
        tlm.enumerateTextLayoutFragments(from: location, options: [.ensuresLayout]) {
            found = $0
            return false
        }
        let fragment = try #require(found)
        let frame = fragment.layoutFragmentFrame
        let origin = tv.textContainerOrigin
        return (
            frame.minY + fragment.textLineFragments.first!.typographicBounds.minY + origin.y,
            frame.minY + fragment.textLineFragments.last!.typographicBounds.maxY + origin.y)
    }

    @Test("rail notes stand level with their blocks, reserve exactly their reach, and leave with their block")
    func railIsPartOfItsBlock() throws {
        let hosted = Hosted(width: 1300)
        defer { hosted.close() }
        let open = doc()
        let decisions = open.blocks.filter { $0.section == .decision }
        let item = try #require(open.blocks.first { $0.section == .userActionItem })
        let rail = [
            item.anchorID: note(61), decisions[0].anchorID: note(62), decisions[1].anchorID: note(63),
        ]
        hosted.show(hosted.spec(open, rail: rail))
        #expect(rails(hosted).count == 3)
        // A new pane width re-measures every stack, a rail-only one included.
        hosted.controller.scrollView.setFrameSize(NSSize(width: 700, height: 1000))
        hosted.controller.scrollView.tile()
        // Level with each block's first line — two annotated blocks in a row
        // included (no creep) — and the next block starts one block gap under
        // the note (the note pushes it down).
        for (index, block) in [item, decisions[0], decisions[1]].enumerated() {
            let view = try #require(rails(hosted).first { abs($0.frame.height - CGFloat(61 + index)) < 0.5 })
            let own = try lines(hosted, open, block.paragraph)
            #expect(abs(view.frame.minY - own.top) < 0.5)
            let next = try #require(open.blocks.first { $0.paragraph > block.paragraph && $0.range.length > 0 })
            #expect(abs(try lines(hosted, open, next.paragraph).top - view.frame.maxY - NotesDocStyle.blockGap) < 0.5)
        }
        // Ticked: the item leaves the document and its note leaves with it.
        let ticked = doc(done: [items[0]])
        var kept = rail
        kept[item.anchorID] = note(61)
        hosted.show(hosted.spec(ticked, rail: kept))
        #expect(rails(hosted).count == 2)
        #expect(!rails(hosted).contains { abs($0.frame.height - 61) < 0.5 })
        let moved = try #require(ticked.block(decisions[0].anchorID))
        let view = try #require(rails(hosted).first { abs($0.frame.height - 62) < 0.5 })
        #expect(abs(view.frame.minY - (try lines(hosted, ticked, moved.paragraph).top)) < 0.5)
    }

    @Test("a composer opening under a railed block never pulls the text below up, on any frame")
    func composerNeverJumpsARail() throws {
        let hosted = Hosted(width: 1300)
        defer { hosted.close() }
        let open = doc()
        let block = try #require(open.blocks.first { $0.section == .decision })
        let next = try #require(open.blocks.first { $0.paragraph > block.paragraph && $0.range.length > 0 })
        let rail = [block.anchorID: note(80)]
        hosted.show(hosted.spec(open, rail: rail))
        let before = try lines(hosted, open, next.paragraph).top
        let composer = AnyView(Color.clear.frame(height: 160))
        hosted.controller.update(hosted.spec(open, attachments: [block.anchorID: composer], composing: block.anchorID, rail: rail))
        var tops = [try lines(hosted, open, next.paragraph).top]
        let link = hosted.controller.textView.displayLink(target: hosted.controller, selector: Selector(("tick:")))
        for _ in 0..<12 {
            Thread.sleep(forTimeInterval: 0.03)
            hosted.controller.perform(Selector(("tick:")), with: link)
            tops.append(try lines(hosted, open, next.paragraph).top)
        }
        Thread.sleep(forTimeInterval: 0.6)
        hosted.controller.perform(Selector(("tick:")), with: link)
        link.invalidate()
        tops.append(try lines(hosted, open, next.paragraph).top)
        // Never above where the rail held it; moving down only as the
        // composer grows past the rail; settled under the composer.
        #expect(tops.allSatisfy { $0 >= before - 0.5 })
        #expect(zip(tops, tops.dropFirst()).allSatisfy { $1 >= $0 - 0.5 })
        #expect(tops.last! > before + 60)
    }
}

@MainActor
@Suite struct NotesDocumentChecklistClickTests {
    private let item = "Send the tide table to Quoll Harbor before the ferry runs."

    private func doc() -> NotesDocument {
        NotesDocumentBuilder.build(
            NotesDocInput(
                structured: NotesStructured(
                    summary: "The kelp survey moved to Thursday.", detailedNotes: "One closing line.",
                    decisions: [], actionItems: [],
                    userActionItems: [ActionItem(owner: "Demo User", text: item)]),
                doneKeys: [], searchTerms: [], portuguese: false, userActionTitle: "Demo User — Action Items",
                direction: .aquarela))
    }

    private func event(_ type: NSEvent.EventType, _ hosted: Hosted, at point: NSPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: hosted.controller.textView.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: hosted.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    @Test("a plain click on a checklist item aims nothing; a click on a paragraph still picks it")
    func clickOnItemNeverAims() throws {
        let doc = doc()
        let hosted = Hosted()
        defer { hosted.close() }
        hosted.show(hosted.spec(doc))
        let block = try #require(doc.blocks.first { $0.section == .userActionItem })
        let words = try #require(hosted.controller.markRects(
            NSRange(location: block.range.location + 5, length: 3), visible: NSRange(location: 0, length: doc.text.length)).first)
        hosted.controller.clickEnded(try event(.leftMouseDown, hosted, at: NSPoint(x: words.midX, y: words.midY)))
        #expect(hosted.picked.isEmpty)
        #expect(hosted.cleared == 1)
        // Control: the same click on the summary paragraph picks it.
        let summary = try #require(doc.blocks.first { $0.section == .summary && $0.range.length > 0 })
        let line = try #require(hosted.controller.markRects(
            NSRange(location: summary.range.location + 4, length: 3), visible: NSRange(location: 0, length: doc.text.length)).first)
        hosted.controller.clickEnded(try event(.leftMouseDown, hosted, at: NSPoint(x: line.midX, y: line.midY)))
        #expect(hosted.picked == [summary.anchorID])
        // Words dragged over inside the item still aim the AI actions.
        hosted.controller.textView.setSelectedRange(NSRange(location: block.range.location + 5, length: 10))
        #expect(hosted.selections.last?.0 == block.anchorID)
    }

    @Test("a double or triple click on a checklist item selects its words but aims nothing; on a paragraph it still aims")
    func multiClickOnItemNeverAims() throws {
        let doc = doc()
        let hosted = Hosted()
        defer { hosted.close() }
        hosted.show(hosted.spec(doc))
        let tv = hosted.controller.textView
        // What the text view's own double / triple click does: selects a word
        // or the paragraph while the multi-click is tracked. (Its tracking
        // loop cannot run in the test process; the driven build clicks.)
        func multiClick(selecting range: NSRange) {
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            hosted.controller.multiClick = true
            tv.setSelectedRange(range)
            hosted.controller.multiClick = false
        }
        let item = try #require(doc.blocks.first { $0.section == .userActionItem })
        let word = NSRange(location: item.range.location + 5, length: 4)
        let paragraph = doc.paragraphs[item.paragraph].range
        for range in [word, paragraph] {
            hosted.selections = []
            let cleared = hosted.cleared
            multiClick(selecting: range)
            #expect(tv.selectedRange() == range, "the selection stays for Copy")
            #expect(!hosted.selections.contains { $0.0 == item.anchorID }, "\(range) aimed the item")
            #expect(hosted.cleared > cleared)
        }
        // Control: a double click on the summary paragraph aims its word.
        let summary = try #require(doc.blocks.first { $0.section == .summary && $0.range.length > 0 })
        hosted.selections = []
        multiClick(selecting: NSRange(location: summary.range.location + 4, length: 4))
        #expect(hosted.selections.last?.0 == summary.anchorID)
        // A drag over the item's words still aims.
        tv.setSelectedRange(NSRange(location: item.range.location + 5, length: 10))
        #expect(hosted.selections.last?.0 == item.anchorID)
    }

    @Test("a right-click inside a double-clicked item's words acts on those words; the bar never stood at them")
    func multiClickWordsAreTheMenuTarget() throws {
        let doc = doc()
        let hosted = Hosted()
        defer { hosted.close() }
        hosted.show(hosted.spec(doc))
        let tv = hosted.controller.textView
        let block = try #require(doc.blocks.first { $0.section == .userActionItem })
        let word = NSRange(location: block.range.location + 9, length: 4)
        #expect((doc.text.string as NSString).substring(with: word) == "tide")
        // The text view's own double click selects the word (see above).
        hosted.controller.multiClick = true
        tv.setSelectedRange(word)
        hosted.controller.multiClick = false
        #expect(!hosted.selections.contains { $0.0 == block.anchorID }, "no bar at the word")
        let rect = try #require(hosted.controller.markRects(word, visible: NSRange(location: 0, length: doc.text.length)).first)
        let menu = try #require(hosted.controller.menu(for: try event(.rightMouseDown, hosted, at: NSPoint(x: rect.midX, y: rect.midY))) {
            NSMenu()
        })
        let note = try #require(menu.items.first { $0.title == "Add Note…" })
        _ = (note.target as? NSObject)?.perform(note.action)
        // The word is the target: handed over, then acted on.
        #expect(hosted.selections.contains { $0.0 == block.anchorID && $0.1 == "tide" })
        #expect(hosted.targets.last?.quotedText == "tide")
        #expect(hosted.menuActions.last?.0 == block.anchorID)
        #expect(hosted.menuActions.last?.1 == true)
        #expect(tv.selectedRange() == word)
    }

    @Test("the double-clicked words are lent to that one menu action; a later right-click outside them acts on the block")
    func multiClickWordsDoNotOutliveTheirAction() throws {
        let doc = doc()
        let hosted = Hosted()
        defer { hosted.close() }
        hosted.show(hosted.spec(doc))
        let tv = hosted.controller.textView
        let block = try #require(doc.blocks.first { $0.section == .userActionItem })
        let word = NSRange(location: block.range.location + 9, length: 4)
        hosted.controller.multiClick = true
        tv.setSelectedRange(word)
        hosted.controller.multiClick = false
        let rect = try #require(hosted.controller.markRects(word, visible: NSRange(location: 0, length: doc.text.length)).first)
        func addNote(at point: NSPoint) throws {
            let menu = try #require(hosted.controller.menu(for: try event(.rightMouseDown, hosted, at: point)) { NSMenu() })
            let note = try #require(menu.items.first { $0.title == "Add Note…" })
            _ = (note.target as? NSObject)?.perform(note.action)
        }
        try addNote(at: NSPoint(x: rect.midX, y: rect.midY))
        #expect(hosted.targets.last?.quotedText == "tide")
        // The composer opens under the item (the aim is put down while it stands).
        let composer = AnyView(Color.clear.frame(height: 120))
        hosted.controller.update(hosted.spec(doc, attachments: [block.anchorID: composer], composing: block.anchorID))
        Thread.sleep(forTimeInterval: 0.8)
        let link = tv.displayLink(target: hosted.controller, selector: Selector(("tick:")))
        hosted.controller.perform(Selector(("tick:")), with: link)
        link.invalidate()
        let clip = try #require(tv.subviews.flatMap(\.subviews).first { $0 is NotesDocClip && $0.frame.height > 100 })
        // A right-click on the composer, outside the words: the whole item.
        try addNote(at: NSPoint(x: clip.frame.midX, y: clip.frame.midY))
        #expect(hosted.menuActions.last?.0 == block.anchorID)
        #expect(hosted.menuActions.last?.1 == false)
        #expect(hosted.targets.count == 2)
        #expect(hosted.targets.last?.quotedText == block.blockText, "the old words were acted on again")
        #expect(hosted.targets.last?.isWholeBlock == true)
    }

    @Test("the circle takes the click across its whole face; it never falls through to the text")
    func circleTakesTheClick() throws {
        let doc = doc()
        let hosted = Hosted()
        defer { hosted.close() }
        hosted.show(hosted.spec(doc))
        let toggle = try #require(hosted.controller.textView.subviews.flatMap(\.subviews).first {
            $0 is NSHostingView<AnyView> && abs($0.frame.width - (NotesDocStyle.toggleWidth + 4)) < 0.5
        })
        let face = toggle.frame
        let points = [
            NSPoint(x: face.midX, y: face.midY), NSPoint(x: face.minX + 1.5, y: face.minY + 1.5),
            NSPoint(x: face.maxX - 1.5, y: face.minY + 1.5), NSPoint(x: face.minX + 1.5, y: face.maxY - 1.5),
            NSPoint(x: face.maxX - 1.5, y: face.maxY - 1.5),
        ]
        for point in points {
            let inWindow = hosted.controller.textView.convert(point, to: nil)
            let hit = try #require(hosted.window.contentView?.hitTest(inWindow))
            #expect(hit.isDescendant(of: toggle), "\(point) hit \(type(of: hit))")
        }
        // (A SwiftUI button does not fire from synthetic events in an
        // off-screen test window; the driven build clicks the circle for real.)
    }
}

/// A layout whose lines find no character under any point (the answer
/// `NSTextLineFragment.characterIndex(for:)` gives when it has none).
private final class NoCharacterLayout: NSObject, NSTextLayoutManagerDelegate {
    final class Line: NSTextLineFragment {
        override func characterIndex(for point: CGPoint) -> Int { NSNotFound }
    }

    final class Fragment: NSTextLayoutFragment {
        override var textLineFragments: [NSTextLineFragment] {
            super.textLineFragments.map { Line(attributedString: $0.attributedString, range: $0.characterRange) }
        }
    }

    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        Fragment(textElement: textElement, range: textElement.elementRange)
    }
}

@MainActor
@Suite struct NotesDocumentCursorTests {
    @Test("a line with no character under the pointer gives the arrow, past the note's first paragraph too")
    func noCharacterUnderThePointer() throws {
        let doc = document(detailed: "The harbour crew checks the jetty lights.")
        let text = doc.text.string as NSString
        let words = text.range(of: "jetty lights")
        // Where the words stand, from the note laid out as usual.
        let plain = Hosted()
        defer { plain.close() }
        plain.show(plain.spec(doc))
        let rect = try #require(plain.controller.markRects(words, visible: NSRange(location: 0, length: text.length)).first)
        let point = NSPoint(x: rect.midX, y: rect.midY)
        #expect(plain.controller.cursor(at: point) === NSCursor.iBeam)
        // The same note laid out with lines that find no character there.
        let hosted = Hosted()
        defer { hosted.close() }
        let layout = NoCharacterLayout()
        let tlm = try #require(hosted.controller.textView.textLayoutManager)
        tlm.delegate = layout
        hosted.show(hosted.spec(doc))
        let origin = hosted.controller.textView.textContainerOrigin
        let fragment = try #require(tlm.textLayoutFragment(for: CGPoint(x: point.x - origin.x, y: point.y - origin.y)))
        // Far into the text: the line's answer is added to the paragraph's start.
        #expect(fragment is NoCharacterLayout.Fragment)
        #expect(tlm.offset(from: tlm.documentRange.location, to: fragment.rangeInElement.location) > 0)
        #expect(hosted.controller.cursor(at: point) === NSCursor.arrow)
    }

    @Test("a sweep of points in and around a note with every block kind: the pointer lookup answers each one")
    func pointerLookupNeverTraps() throws {
        let doc = document(
            summary: "Quoll Harbor opens Friday.\n\n---\n\n```\nlet buoy = 4\n\nlet tide = 2\n```",
            detailed: "| Crew | Shift |\n|---|---|\n| Kestrel | Night |\n\n- one\n  - two\n\n> quoted\n\nLast line.")
        let hosted = Hosted()
        defer { hosted.close() }
        hosted.show(hosted.spec(doc, attachments: [NotesDocument.headAnchor: AnyView(Color.clear.frame(height: 300))]))
        let bounds = hosted.controller.textView.bounds
        for y in stride(from: bounds.minY - 300, through: bounds.maxY + 300, by: 2) {
            for x in stride(from: bounds.minX - 300, through: bounds.maxX + 300, by: 11) {
                _ = hosted.controller.cursor(at: NSPoint(x: x, y: y))
            }
        }
    }

    @Test("the I-beam over the words, the arrow over blank space, chrome and placed pieces, the hand on a link; a text input keeps its own")
    func pointerNotTextCursor() throws {
        let doc = document(
            summary: "The kelp survey moved to Thursday; see the [tide board](https://example.com/tide) for the dates.",
            detailed: "The harbour crew checks the jetty lights.\n\nVexatron Labs ships the buoy firmware.")
        let hosted = Hosted()
        defer { hosted.close() }
        let block = try #require(doc.blocks.first { $0.blockText.hasPrefix("The harbour crew") })
        let piece = AnyView(Color.clear.frame(height: 120))
        let composer = AnyView(TextEditor(text: .constant("")).frame(height: 80))
        hosted.show(hosted.spec(doc, attachments: [block.anchorID: piece, NotesDocument.headAnchor: composer]))
        let controller = hosted.controller
        let all = NSRange(location: 0, length: doc.text.length)
        let text = doc.text.string as NSString
        func rect(_ words: String) throws -> NSRect {
            try #require(controller.markRects(text.range(of: words), visible: all).first)
        }
        func point(_ words: String) throws -> NSPoint {
            let rect = try rect(words)
            return NSPoint(x: rect.midX, y: rect.midY)
        }
        let words = try point("jetty lights")
        #expect(controller.cursor(at: words) === NSCursor.iBeam)
        #expect(controller.cursor(at: try point("see the")) === NSCursor.iBeam)
        #expect(controller.cursor(at: try point("Detailed Notes")) === NSCursor.iBeam)
        #expect(controller.cursor(at: try point("tide board")) === NSCursor.pointingHand)
        // Blank space: just past a short line's end, far past it, the page
        // margin, between two paragraphs, below the last line.
        let lastLine = try rect("buoy firmware.")
        #expect(controller.cursor(at: NSPoint(x: lastLine.maxX + 1, y: lastLine.midY)) === NSCursor.arrow)
        #expect(controller.cursor(at: NSPoint(x: words.x + 400, y: words.y)) === NSCursor.arrow)
        #expect(controller.cursor(at: NSPoint(x: 8, y: words.y)) === NSCursor.arrow)
        let summaryEnd = try rect("the dates.")
        let title = try rect("Detailed Notes")
        #expect(controller.cursor(at: NSPoint(x: summaryEnd.midX, y: (summaryEnd.maxY + title.minY) / 2)) === NSCursor.arrow)
        #expect(controller.cursor(at: NSPoint(x: lastLine.midX, y: lastLine.maxY + 30)) === NSCursor.arrow)
        // A section title's empty area.
        #expect(controller.cursor(at: NSPoint(x: title.maxX + 200, y: title.midY)) === NSCursor.arrow)
        // A piece placed under a block: the arrow; the composer's field keeps its own (the I-beam).
        let clips = controller.textView.subviews.flatMap(\.subviews).filter { $0 is NotesDocClip }
        let clip = try #require(clips.first { $0.frame.height > 100 })
        let field = try #require(clips.first { $0.frame.height > 70 && $0.frame.height < 100 })
        // (The editor's own AppKit view is made on the piece's first layout pass.)
        field.subviews.first?.layoutSubtreeIfNeeded()
        #expect(controller.cursor(at: NSPoint(x: clip.frame.midX, y: clip.frame.midY)) === NSCursor.arrow)
        #expect(controller.cursor(at: NSPoint(x: field.frame.midX, y: field.frame.midY)) == nil)
        // The scroll view's own cursor is the arrow; a move over the words sets
        // the I-beam, over blank space the arrow.
        #expect(controller.scrollView.documentCursor === NSCursor.arrow)
        func move(to point: NSPoint) throws {
            let event = try #require(NSEvent.mouseEvent(
                with: .mouseMoved, location: controller.textView.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: hosted.window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
            controller.textView.mouseMoved(with: event)
        }
        NSCursor.arrow.set()
        try move(to: words)
        #expect(NSCursor.current === NSCursor.iBeam)
        try move(to: NSPoint(x: words.x + 400, y: words.y))
        #expect(NSCursor.current === NSCursor.arrow)
        // Straight from the words onto a placed piece: the I-beam does not stay.
        try move(to: words)
        try move(to: NSPoint(x: clip.frame.midX, y: clip.frame.midY))
        #expect(NSCursor.current === NSCursor.arrow)
        // Over the composer's field the text view sets nothing.
        NSCursor.crosshair.set()
        try move(to: NSPoint(x: field.frame.midX, y: field.frame.midY))
        #expect(NSCursor.current === NSCursor.crosshair)
    }

    @Test("the arrow over the \"Completed (n)\" row, a control; a section title's words keep the I-beam")
    func completedRowIsAControl() throws {
        let items = ["Send the tide table to Quoll Harbor.", "Book the jetty crane for Vexatron Labs."]
        let doc = NotesDocumentBuilder.build(
            NotesDocInput(
                structured: NotesStructured(
                    summary: "The kelp survey moved to Thursday.", detailedNotes: "One closing line.", decisions: [],
                    actionItems: [], userActionItems: items.map { ActionItem(owner: "Demo User", text: $0) }),
                doneKeys: [ActionItemKey.key(for: items[1])], searchTerms: [], portuguese: false,
                userActionTitle: "Demo User — Action Items", direction: .aquarela))
        let hosted = Hosted()
        defer { hosted.close() }
        hosted.show(hosted.spec(doc))
        let all = NSRange(location: 0, length: doc.text.length)
        func point(_ words: String) throws -> NSPoint {
            let rect = try #require(hosted.controller.markRects((doc.text.string as NSString).range(of: words), visible: all).first)
            return NSPoint(x: rect.midX, y: rect.midY)
        }
        #expect(hosted.controller.cursor(at: try point("Completed (1)")) === NSCursor.arrow)
        #expect(hosted.controller.cursor(at: try point("Action Items")) === NSCursor.iBeam)
        #expect(hosted.controller.cursor(at: try point("tide table")) === NSCursor.iBeam)
    }

    @Test("a drag-selection keeps the I-beam wherever the pointer goes; the release gives the pointer back")
    func dragKeepsTheIBeam() throws {
        let doc = document(detailed: "The harbour crew checks the jetty lights.")
        let hosted = Hosted()
        defer { hosted.close() }
        let block = try #require(doc.blocks.first { $0.blockText.hasPrefix("The harbour crew") })
        hosted.show(hosted.spec(doc, attachments: [block.anchorID: AnyView(Color.clear.frame(height: 120))]))
        let tv = hosted.controller.textView
        let words = (doc.text.string as NSString).range(of: "jetty lights")
        // The text system reports a live drag as a selection still selecting.
        NSCursor.arrow.set()
        tv.setSelectedRange(words, affinity: .downstream, stillSelecting: true)
        #expect(NSCursor.current === NSCursor.iBeam)
        // The release: the pointer follows the rule for where it stands.
        NSCursor.crosshair.set()
        tv.setSelectedRange(words, affinity: .downstream, stillSelecting: false)
        let here = tv.convert(hosted.window.mouseLocationOutsideOfEventStream, from: nil)
        #expect(NSCursor.current === (hosted.controller.cursor(at: here) ?? NSCursor.crosshair))
        // A selection made by the pane (not a drag) leaves the pointer alone.
        NSCursor.crosshair.set()
        tv.setSelectedRange(NSRange(location: words.location, length: 0))
        tv.setSelectedRange(words)
        #expect(NSCursor.current === NSCursor.crosshair)
        // Released over a placed piece: the arrow, not the drag's I-beam.
        let clip = try #require(tv.subviews.flatMap(\.subviews).first { $0 is NotesDocClip && $0.frame.height > 100 })
        hosted.window.pointer = tv.convert(NSPoint(x: clip.frame.midX, y: clip.frame.midY), to: nil)
        tv.setSelectedRange(words, affinity: .downstream, stillSelecting: true)
        #expect(NSCursor.current === NSCursor.iBeam)
        tv.setSelectedRange(words, affinity: .downstream, stillSelecting: false)
        #expect(NSCursor.current === NSCursor.arrow)
    }
}

@MainActor
@Suite struct NotesDocumentSelectionPaintTests {
    @Test("the selection is the text system's own highlight, so it shows while the drag is still going")
    func selectionShowsWhileDragging() throws {
        let doc = document(detailed: "The harbour crew checks the jetty lights.")
        let hosted = Hosted()
        defer { hosted.close() }
        hosted.show(hosted.spec(doc))
        let tv = hosted.controller.textView
        let highlight = try #require((tv.selectedTextAttributes[.backgroundColor] as? NSColor)?.usingColorSpace(.sRGB))
        let fill = try #require(BlockSelection.fill.usingColorSpace(.sRGB))
        #expect(highlight.alphaComponent > 0.1)
        #expect(abs(highlight.alphaComponent - fill.alphaComponent) < 0.01)
        #expect(abs(highlight.redComponent - fill.redComponent) < 0.01)
        #expect(abs(highlight.greenComponent - fill.greenComponent) < 0.01)
        #expect(abs(highlight.blueComponent - fill.blueComponent) < 0.01)
    }
}

@MainActor
@Suite struct NotesDocumentBarMeasureTests {
    @Test("the bar for words at the end of a checklist item stays inside the reading column")
    func barInsideTheColumn() throws {
        let item = "Send the tide table to Quoll Harbor before the ferry runs on Thursday, and copy the jetty crew on the new buoy firmware schedule for the week."
        let doc = NotesDocumentBuilder.build(
            NotesDocInput(
                structured: NotesStructured(
                    summary: "The kelp survey moved to Thursday.", detailedNotes: "One closing line.",
                    decisions: [], actionItems: [], userActionItems: [ActionItem(owner: "Demo User", text: item)]),
                doneKeys: [], searchTerms: [], portuguese: false, userActionTitle: "Demo User — Action Items",
                direction: .aquarela))
        let hosted = Hosted(width: 1300)
        defer { hosted.close() }
        let block = try #require(doc.blocks.first { $0.section == .userActionItem })
        hosted.show(hosted.spec(doc))
        // The last characters of the item's first line.
        let all = NSRange(location: 0, length: doc.text.length)
        let firstLine = try #require(hosted.controller.markRects(NSRange(location: block.range.location, length: 1), visible: all).first).minY
        let onFirstLine = (block.range.location..<NSMaxRange(block.range)).filter {
            hosted.controller.markRects(NSRange(location: $0, length: 1), visible: all).first.map { abs($0.minY - firstLine) < 1 } ?? false
        }
        hosted.controller.textView.setSelectedRange(NSRange(location: onFirstLine.last! - 5, length: 5))
        hosted.show(hosted.spec(doc, aim: NotesDocAim(anchorID: block.anchorID, isSpan: true)))
        let bar = try #require(hosted.controller.textView.subviews.flatMap(\.subviews).first {
            $0 is NSHostingView<AnyView> && abs($0.frame.height - SelectionActionBar.size.height) < 0.5
        })
        let tv = hosted.controller.textView
        let right = tv.textContainerOrigin.x + (tv.textContainer?.size.width ?? 0)
        #expect(bar.frame.maxX <= right + 0.5)
        // It still stands at the right end, as far as the column lets it.
        #expect(bar.frame.maxX >= right - 0.5)
    }

    @Test("in a pane narrower than the full measure, the bar for words at a line's end stays inside the pane", arguments: [518, 600, 700])
    func barInsideANarrowPane(width: Int) throws {
        let line = "Vexatron Labs moved the kelp survey to Thursday so the jetty crew at Quoll Harbor can calibrate the buoy firmware first, then log the tide readings."
        let doc = NotesDocumentBuilder.build(
            NotesDocInput(
                structured: NotesStructured(
                    summary: line, detailedNotes: "One closing line.",
                    decisions: [], actionItems: [], userActionItems: []),
                doneKeys: [], searchTerms: [], portuguese: false, userActionTitle: "Demo User — Action Items",
                direction: .aquarela))
        let hosted = Hosted(width: CGFloat(width))
        defer { hosted.close() }
        let block = try #require(doc.blocks.first { $0.section == .summary && $0.range.length > 0 })
        hosted.show(hosted.spec(doc))
        let all = NSRange(location: 0, length: doc.text.length)
        let firstLine = try #require(hosted.controller.markRects(NSRange(location: block.range.location, length: 1), visible: all).first).minY
        let onFirstLine = (block.range.location..<NSMaxRange(block.range)).filter {
            hosted.controller.markRects(NSRange(location: $0, length: 1), visible: all).first.map { abs($0.minY - firstLine) < 1 } ?? false
        }
        hosted.controller.textView.setSelectedRange(NSRange(location: onFirstLine.last! - 5, length: 5))
        hosted.show(hosted.spec(doc, aim: NotesDocAim(anchorID: block.anchorID, isSpan: true)))
        let bar = try #require(hosted.controller.textView.subviews.flatMap(\.subviews).first {
            $0 is NSHostingView<AnyView> && abs($0.frame.height - SelectionActionBar.size.height) < 0.5
        })
        let pane = hosted.controller.scrollView
        #expect(bar.convert(bar.bounds, to: pane).maxX <= pane.bounds.maxX + 0.5)
    }
}

@MainActor
@Suite struct NotesDocumentCompletedRowTests {
    @Test("the Completed (n) label stands as low as today's disclosure row, and the box ends as far below it")
    func completedRowKeepsTodaysHeight() throws {
        let items = ["Send the tide table to Quoll Harbor.", "Book the jetty crane.", "Check the buoy firmware."]
        for direction in [DesignDirection.aquarela, .estudio, .caderno, .fluido] {
            let doc = NotesDocumentBuilder.build(
                NotesDocInput(
                    structured: NotesStructured(
                        summary: "The kelp survey moved to Thursday.", detailedNotes: "One closing line.",
                        decisions: ["The harbour lights stay amber."], actionItems: [],
                        userActionItems: items.map { ActionItem(owner: "Demo User", text: $0) }),
                    doneKeys: [ActionItemKey.key(for: items[2])], searchTerms: [], portuguese: false,
                    userActionTitle: "Demo User — Action Items", direction: direction))
            let hosted = Hosted()
            defer { hosted.close() }
            hosted.show(hosted.spec(doc))
            let completed = try #require(doc.completedDisclosure)
            let lastOpen = try #require(doc.blocks.last { $0.section == .userActionItem }).paragraph
            let decisions = try #require(doc.sections.first { $0.kind == .decisions })
            let tv = hosted.controller.textView
            func lines(_ paragraph: Int) throws -> (top: CGFloat, bottom: CGFloat) {
                let tlm = try #require(tv.textLayoutManager)
                let tcm = try #require(tlm.textContentManager)
                let location = try #require(tcm.location(tcm.documentRange.location, offsetBy: doc.paragraphs[paragraph].range.location))
                var found: NSTextLayoutFragment?
                tlm.enumerateTextLayoutFragments(from: location, options: [.ensuresLayout]) {
                    found = $0
                    return false
                }
                let fragment = try #require(found)
                let frame = fragment.layoutFragmentFrame
                return (
                    frame.minY + fragment.textLineFragments.first!.typographicBounds.minY,
                    frame.minY + fragment.textLineFragments.last!.typographicBounds.maxY)
            }
            let label = try lines(completed)
            // Today's row: 3 pt lower than a plain paragraph; Caderno's 4.
            let above: CGFloat = direction == .caderno ? 4 : 3
            #expect(abs(label.top - (try lines(lastOpen).bottom) - NotesDocStyle.blockGap - above) < 0.5, "\(direction)")
            let box = doc.look.insets(.userActions).bottom
            #expect(abs(try lines(decisions.title).top - label.bottom - NotesDocStyle.disclosureBelow - box - NotesDocStyle.sectionGap) < 0.5)
        }
    }
}

@MainActor
@Suite struct NotesDocumentOffscreenSpaceTests {
    @Test("a space opening or closing below the page on screen lands at once; one on screen still slides")
    func belowViewLandsAtOnce() throws {
        let paragraphs = (1...80).map { "Quoll Harbor tide log \($0): the Vexatron Labs buoy reported a steady swell all night." }
        let doc = document(detailed: paragraphs.joined(separator: "\n\n"))
        let near = try #require(doc.blocks.first { $0.blockText.hasPrefix("Quoll Harbor tide log 1:") })
        let far = try #require(doc.blocks.first { $0.blockText.hasPrefix("Quoll Harbor tide log 80:") })
        let hosted = Hosted()
        defer { hosted.close() }
        hosted.show(hosted.spec(doc))
        let card = { (height: CGFloat) in AnyView(Color.clear.frame(height: height)) }
        let clips = { hosted.controller.textView.subviews.flatMap(\.subviews).compactMap { $0 as? NotesDocClip } }
        hosted.controller.update(hosted.spec(doc, attachments: [near.anchorID: card(120), far.anchorID: card(400)]))
        let placed = clips().sorted { $0.frame.minY < $1.frame.minY }
        #expect(placed.count == 2)
        let nearClip = try #require(placed.first)
        let farClip = try #require(placed.last)
        let visible = hosted.controller.scrollView.documentVisibleRect
        // The far card's space starts below the page on screen: it is open in full, with no frame to wait for.
        #expect(farClip.frame.minY >= visible.maxY)
        #expect(farClip.frame.height == 400)
        // The card on screen is still on its way (positive control: the spring still runs there).
        #expect(nearClip.frame.minY < visible.maxY)
        #expect(nearClip.frame.height < 120)
        // Taken away below the page, the far card leaves at once; the near one stays.
        hosted.controller.update(hosted.spec(doc, attachments: [near.anchorID: card(120)]))
        #expect(farClip.superview == nil)
        #expect(nearClip.superview != nil)
    }
}
