import AppKit
import BlaiseCore
import SwiftUI

// The notes as ONE TextKit 2 text view that owns its scrolling.
// SwiftUI gives this representable a frame and never learns the document's
// height. Everything that is not text — the composer, pending rows, note
// cards, tables, the done toggles, the selection bar — is an existing SwiftUI
// view hosted as a subview of the text view, placed in space the text makes
// for it: the paragraph above it grows its `paragraphSpacing`, one display
// frame at a time, on the same spring the SwiftUI pane uses.

/// A mark painted behind a block's words: `span` nil marks the whole block;
/// `range`, when set, is the exact range in the block's host text (a passage
/// piece) and wins over `span`.
struct NotesDocMark: Equatable {
    var span: SelectedSpan?
    var emphasized = false
    var range: NSRange? = nil
}

/// What the one selection bar stands at.
struct NotesDocAim: Equatable {
    var anchorID: String
    var isSpan: Bool
    /// A selection across paragraphs: the bar stands at its anchor block.
    var isPassage = false
}

struct NotesDocBarConfig {
    var correctionEnabled: Bool
    var engineCanEditNotes: Bool
    var onAction: (EditingTarget.Kind) -> Void
}

struct NotesDocScrollRequest: Equatable {
    /// A block anchor, or `NotesDocumentView.userActionBoxAnchor`.
    var anchorID: String
    var token: Int
    var center = true
    var animated = true
    /// Scroll only as far as it takes to show the block AND what stands under
    /// it (an opened composer), never further.
    var reveal = false
}

struct NotesDocCallbacks {
    /// A selection inside exactly one block (block + span), or none.
    var onSelection: (NotesDocBlock?, SelectedSpan?) -> Void
    /// A selection across paragraphs that yields two or more pieces.
    var onPassage: (PassageCapture) -> Void
    /// A click that selected no words, on a block.
    var onPick: (NotesDocBlock) -> Void
    /// A click off every block, or Escape.
    var onClear: () -> Void
    /// `inSelection`: the right-click landed inside the current selection.
    var onMenuAction: (EditingTarget.Kind, NotesDocBlock, _ inSelection: Bool) -> Void
    var menuOffers: () -> (correct: Bool, correctEnabled: Bool)
    var onToggle: (ActionItem, Bool) -> Void
    /// The "Completed (n)" disclosure was opened or closed.
    var onToggleCompleted: () -> Void
    var onScroll: () -> Void
}

struct NotesDocumentView: NSViewRepresentable {
    static let userActionBoxAnchor = "user-action-box"

    let document: NotesDocument
    let marks: [String: NotesDocMark]
    /// The SwiftUI stack placed under each block that has one, keyed by anchor.
    let attachments: [String: AnyView]
    /// The block whose composer is open: its stack slides in from the top.
    let composingAnchor: String?
    /// Margin notes in the right-hand rail, per anchor (the wide margin mode).
    let rail: [String: AnyView]
    /// The margin mode is live: the section boxes widen to hold the rail lane.
    let railLane: Bool
    let completedExpanded: Bool
    let aim: NotesDocAim?
    let bar: NotesDocBarConfig?
    let scrollRequest: NotesDocScrollRequest?
    let callbacks: NotesDocCallbacks
    /// Fluido: a change sweeps the shine over the notes (they just materialized).
    var shineTick = 0
    /// Timecode marks; nil when the switch is off or the audio is not ready.
    var timecodes: NotesDocTimecodes? = nil

    func makeCoordinator() -> NotesDocController { NotesDocController() }

    func makeNSView(context: Context) -> NSScrollView { context.coordinator.scrollView }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: NotesDocController) {
        coordinator.tearDown()
    }
}

// MARK: - The text view

final class NotesDocTextView: NSTextView {
    weak var controller: NotesDocController?

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        controller?.drawDecorations(in: rect)
    }

    override func mouseDown(with event: NSEvent) {
        // A Control-click arrives as a left mouse down: it opens the same menu
        // as a right-click and picks nothing.
        if event.modifierFlags.contains(.control) {
            if let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
            return
        }
        // A click on a timecode mark plays or pauses; it never selects or
        // picks. The second press of a double click does nothing.
        if let anchor = controller?.timecodeHit(at: convert(event.locationInWindow, from: nil)) {
            if event.clickCount == 1 { controller?.activateTimecode(anchor) }
            return
        }
        // A double or triple click selects words the way a click does: it
        // never aims a checklist item (the selection stays for Copy).
        controller?.multiClick = event.clickCount >= 2
        super.mouseDown(with: event)
        controller?.multiClick = false
        // The text system also routes a right-click through here; only a
        // left click picks a block or gives the page back.
        if event.type == .leftMouseDown { controller?.clickEnded(event) }
    }

    /// Copy, drag and Services carry clean text: no placeholder characters,
    /// line breaks as newlines, list markers as "• " / "1. ".
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let storage = textStorage else { return false }
        let joined = NSMutableAttributedString()
        for value in selectedRanges where value.rangeValue.length > 0 {
            if joined.length > 0 { joined.append(NSAttributedString(string: "\n")) }
            joined.append(storage.attributedSubstring(from: value.rangeValue))
        }
        guard joined.length > 0 else { return false }
        let clean = NotesDocument.copyText(joined)
        let whole = NSRange(location: 0, length: clean.length)
        let rich = NSMutableAttributedString(attributedString: clean)
        // The page's dark-mode ink and the search cues stay on the page.
        for key: NSAttributedString.Key in [.foregroundColor, .backgroundColor, .underlineStyle, .paragraphStyle] {
            rich.removeAttribute(key, range: whole)
        }
        pboard.declareTypes([.rtf, .string], owner: nil)
        if let rtf = rich.rtf(from: whole) { pboard.setData(rtf, forType: .rtf) }
        return pboard.setString(clean.string, forType: .string)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let controller else { return super.menu(for: event) }
        return controller.menu(for: event) { super.menu(for: event) }
    }

    override func cancelOperation(_ sender: Any?) {
        controller?.escape()
    }

    // The standard Mac pointer: the I-beam over the words, the arrow over
    // blank space, chrome (the Completed row too) and placed pieces, the
    // pointing hand on a link; a text input keeps its own (the composer's
    // field its I-beam). No I-beam rect of the text view's.
    override func resetCursorRects() {}

    override func cursorUpdate(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        controller?.pointerMoved(to: point)
        controller?.cursor(at: point)?.set()
    }

    /// Not the text view's own (it sets the I-beam wherever the pointer moves,
    /// placed pieces included).
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        controller?.pointerMoved(to: point)
        controller?.cursor(at: point)?.set()
    }

    /// Only for leaving the view: a timecode mark shows while the pointer is
    /// over its block.
    private var exitTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard exitTracking == nil else { return }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        exitTracking = area
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        controller?.pointerLeft()
    }

    /// A drag-selection is under way: the I-beam until the release.
    private var dragSelecting = false

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if stillSelecting, ranges.contains(where: { $0.rangeValue.length > 0 }) {
            dragSelecting = true
            NSCursor.iBeam.set()
        } else if !stillSelecting, dragSelecting {
            dragSelecting = false
            if let window {
                let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
                controller?.pointerMoved(to: point)
                controller?.cursor(at: point)?.set()
            }
        }
    }

    // Assistive tech reads the notes as today's pane: header, then each
    // section's title (a heading) and blocks, each placed piece right after
    // its text, the user-action box as a labelled container.
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Notes" }
    override func accessibilityChildren() -> [Any]? {
        controller?.accessibilityElements() ?? super.accessibilityChildren()
    }
}

/// One paragraph of the notes (a section title or a block) as its own
/// element. A block reads as today's per-block text area: its words are the
/// value, with the text interface assistive tech moves through by character,
/// word and line, and selects with (the selection is the text view's, so it
/// aims the AI actions as a drag does).
final class NotesDocAccessibilityText: NSAccessibilityElement {
    weak var controller: NotesDocController?
    var paragraph = 0
    /// The paragraph's characters in the document (its break excluded); the
    /// value maps onto them offset for offset.
    var range = NSRange(location: 0, length: 0)
    var words = ""

    private func onController<T: Sendable>(_ fallback: T, _ body: @MainActor (NotesDocController) -> T) -> T {
        let controller = controller
        return MainActor.assumeIsolated { controller.map(body) } ?? fallback
    }

    override func accessibilityFrame() -> NSRect {
        let paragraph = paragraph
        return onController(.zero) { $0.screenFrame(paragraph: paragraph) }
    }

    override func accessibilityValue() -> Any? { accessibilityRole() == .textArea ? words : nil }
    override func accessibilityNumberOfCharacters() -> Int { range.length }
    override func accessibilityVisibleCharacterRange() -> NSRange { NSRange(location: 0, length: range.length) }

    override func accessibilityString(for range: NSRange) -> String? {
        guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= self.range.length else { return nil }
        return (words as NSString).substring(with: range)
    }

    /// The block's links, each its own element (in the order they read).
    var links: [NotesDocAccessibilityLink] = []

    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        guard let string = accessibilityString(for: range) else { return nil }
        let out = NSMutableAttributedString(string: string)
        for link in links {
            let local = NSRange(location: link.range.location - self.range.location, length: link.range.length)
            let inside = NSIntersectionRange(local, range)
            guard inside.length > 0 else { continue }
            out.addAttribute(
                .accessibilityLink, value: link, range: NSRange(location: inside.location - range.location, length: inside.length))
        }
        return out
    }

    /// The laid-out lines, without the paragraph break the last one holds.
    private func lines() -> [NSRange] {
        let paragraph = paragraph
        let length = range.length
        return onController([]) { $0.lineRanges(paragraph: paragraph) }.map {
            NSRange(location: $0.location, length: max(0, min(NSMaxRange($0), length) - $0.location))
        }
    }

    override func accessibilityLine(for index: Int) -> Int {
        let lines = lines()
        return lines.firstIndex { index < NSMaxRange($0) } ?? max(0, lines.count - 1)
    }

    override func accessibilityRange(forLine line: Int) -> NSRange {
        let lines = lines()
        return lines.indices.contains(line) ? lines[line] : NSRange(location: NSNotFound, length: 0)
    }

    override func accessibilityFrame(for range: NSRange) -> NSRect {
        let global = NSRange(location: self.range.location + range.location, length: range.length)
        return onController(.zero) { $0.screenFrame(characters: global) }
    }

    override func accessibilitySelectedTextRange() -> NSRange {
        let whole = range
        let selected = onController(NSRange(location: 0, length: 0)) { $0.textView.selectedRange() }
        let inside = NSIntersectionRange(selected, whole)
        guard inside.length > 0 || (selected.length == 0 && NSLocationInRange(selected.location, whole)) else {
            return NSRange(location: 0, length: 0)
        }
        return NSRange(location: max(selected.location, whole.location) - whole.location, length: inside.length)
    }

    override func setAccessibilitySelectedTextRange(_ range: NSRange) {
        let start = min(max(0, range.location), self.range.length)
        let length = min(max(0, range.length), self.range.length - start)
        let global = NSRange(location: self.range.location + start, length: length)
        onController(()) { $0.textView.setSelectedRange(global) }
    }

    override func accessibilitySelectedText() -> String? {
        accessibilityString(for: accessibilitySelectedTextRange())
    }

    override func accessibilityInsertionPointLineNumber() -> Int {
        accessibilityLine(for: accessibilitySelectedTextRange().location)
    }
}

/// A link inside a block's words: announced as a link, pressed as a click on it.
final class NotesDocAccessibilityLink: NSAccessibilityElement {
    weak var controller: NotesDocController?
    /// The link's characters in the document.
    var range = NSRange(location: 0, length: 0)
    var url: URL?

    override func accessibilityFrame() -> NSRect {
        let controller = controller
        let range = range
        return MainActor.assumeIsolated { controller?.screenFrame(characters: range) } ?? .zero
    }

    override func accessibilityPerformPress() -> Bool {
        let controller = controller
        let range = range
        guard let url else { return false }
        MainActor.assumeIsolated { controller?.textView.clicked(onLink: url, at: range.location) }
        return true
    }
}

/// A block's timecode mark: a button before the block's text.
final class NotesDocAccessibilityTimecode: NSAccessibilityElement {
    weak var controller: NotesDocController?
    var anchorID = ""

    override func accessibilityFrame() -> NSRect {
        let controller = controller
        let anchorID = anchorID
        return MainActor.assumeIsolated { controller?.timecodeScreenFrame(anchorID) } ?? .zero
    }

    override func accessibilityPerformPress() -> Bool {
        let controller = controller
        let anchorID = anchorID
        MainActor.assumeIsolated { controller?.activateTimecode(anchorID) }
        return true
    }
}

/// The user-action box: a container named "Your action items".
final class NotesDocAccessibilityGroup: NSAccessibilityElement {
    weak var controller: NotesDocController?
    var paragraphs = 0..<0

    override func accessibilityFrame() -> NSRect {
        let controller = controller
        let paragraphs = paragraphs
        return MainActor.assumeIsolated {
            guard let controller else { return NSRect.zero }
            return paragraphs.reduce(NSRect.null) { $0.union(controller.screenFrame(paragraph: $1)) }
        }
    }
}

final class NotesDocScrollView: NSScrollView {
    var onTile: (() -> Void)?
    override func tile() {
        super.tile()
        onTile?()
    }
}

/// Holds every hosted SwiftUI view above the text system's own subviews, and
/// lets clicks between them through to the text.
private final class NotesDocOverlay: NSView {
    override var isFlipped: Bool { true }
    /// A right-click or Control-click on a piece placed under a block opens
    /// that block's menu (the text view's), except in a text field, whose own
    /// menu (Paste) stays.
    var menuRouter: ((NSPoint) -> NSView?)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit === self { return nil }
        if let hit, Self.opensMenu(NSApp.currentEvent), !(hit is NSText), !(hit is NSTextField),
            let target = menuRouter?(convert(point, from: superview))
        {
            return target
        }
        return hit
    }

    private static func opensMenu(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        switch event.type {
        case .rightMouseDown: return true
        case .leftMouseDown: return event.modifierFlags.contains(.control)
        default: return false
        }
    }
}

/// The window a stack is seen through while its space opens or closes.
final class NotesDocClip: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - The controller

@MainActor
final class NotesDocController: NSObject, NSTextViewDelegate {
    let scrollView = NotesDocScrollView()
    let textView = NotesDocTextView(usingTextLayoutManager: true)
    private let overlay = NotesDocOverlay()
    private let motion = NotesDocMotionState()

    fileprivate var document: NotesDocument?
    fileprivate var spec: NotesDocumentView?
    private var resolvedMarks: [ResolvedMark] = []
    /// Arrival flashes that were just put down, fading out over 0.3 s.
    private var fadingMarks: [(mark: ResolvedMark, start: CFTimeInterval)] = []
    private var fadeTimer: Timer?
    private var stacks: [String: Stack] = [:]
    private var toggleViews: [NSHostingView<AnyView>] = []
    private var disclosureView: NSHostingView<AnyView>?
    private var barView: NSHostingView<AnyView>?
    private var displayLink: CADisplayLink?
    private var containerWidth: CGFloat = 0
    private var lastScrollToken: Int?
    private var previousAim: NotesDocAim?
    private var installing = false
    private var softTopEdge = false
    /// An un-ticked row whose arrival starts once the update has placed everything.
    private var pendingReopen: NotesDocReopen?
    nonisolated(unsafe) private var tableMonitor: Any?

    deinit {
        if let tableMonitor { NSEvent.removeMonitor(tableMonitor) }
    }

    /// The pane is gone (window closed, another meeting opened): a slide's or
    /// Fluido motion's display link and a fade's timer would otherwise keep this controller,
    /// and its app-wide mouse monitor, alive.
    func tearDown() {
        displayLink?.invalidate()
        displayLink = nil
        fadeTimer?.invalidate()
        fadeTimer = nil
        if let tableMonitor { NSEvent.removeMonitor(tableMonitor) }
        tableMonitor = nil
        motion.link?.invalidate()
        motion.link = nil
    }

    /// Today's `NotesEditingMotion.push`, as a curve this view can sample.
    private let spring = Spring(duration: 0.32, bounce: 0.14)
    static let inset = NSSize(width: 36, height: 28)
    /// Reduce Motion, read in one place: the slides become a crossfade.
    /// `nil` follows the system preference; a test pins it.
    var reduceMotionOverride: Bool?
    var reduceMotion: Bool { reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static let crossfade: TimeInterval = 0.16

    struct ResolvedMark: Equatable {
        var range: NSRange
        var emphasized: Bool
        /// The whole block: one rounded rectangle behind all of its lines.
        var block: String?
    }
    static let measure = NotesEditingLayout.proseMeasure - 72

    @MainActor
    final class Stack {
        let clip = NotesDocClip()
        let host: NSHostingController<AnyView>
        var measured: CGFloat = 0
        var leading: CGFloat = 6
        var value: CGFloat = 0
        var from: CGFloat = 0
        var target: CGFloat = 0
        var velocity: Double = 0
        var start: CFTimeInterval = 0
        var duration: Double = 0
        var animating = false
        /// While a composer arrives or leaves, the stack rides the bottom of
        /// its opening space, so it slides down out of the paragraph above
        /// (today's `.move(edge: .top)`) instead of being uncovered in place.
        var fromTop = false
        var composing = false
        /// Under Reduce Motion the piece crossfades; placement leaves its alpha alone.
        var crossfading = false
        /// What the stack shows once a closing composer has slid out: until
        /// then the composer rides the closing space up with what stood under it.
        var pendingRoot: AnyView?
        /// The height of what the stack shows now (the leaving view's, while
        /// `pendingRoot` waits).
        var shownHeight: CGFloat = 0
        /// The block's margin notes, beside its lines (the wide margin mode):
        /// placed and reserved with the piece under the block, and gone with it.
        var rail: NSHostingView<AnyView>?
        var railHeight: CGFloat = 0
        /// How far the rail reaches below the block's own lines.
        var railNeed: CGFloat = 0

        init(_ view: AnyView) {
            host = NSHostingController(rootView: view)
            host.sizingOptions = []
            clip.wantsLayer = true
            clip.layer?.masksToBounds = true
            clip.addSubview(host.view)
        }
    }

    override init() {
        super.init()
        let tv = textView
        tv.controller = self
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.importsGraphics = false
        tv.allowsUndo = false
        tv.drawsBackground = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainerInset = Self.inset
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.lineFragmentPadding = 0
        tv.appearance = NSAppearance(named: .darkAqua)
        tv.selectedTextAttributes = [.backgroundColor: BlockSelection.fill]
        tv.linkTextAttributes = [
            .foregroundColor: NSColor(Design.accent), .cursor: NSCursor.pointingHand,
        ]
        tv.delegate = self
        overlay.frame = tv.bounds
        tableMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated { self?.tableClick(event) }
            return event
        }
        overlay.menuRouter = { [weak self] point in
            guard let self, self.menuBlock(at: point) != nil else { return nil }
            return self.textView
        }
        overlay.autoresizingMask = [.width, .height]
        tv.addSubview(overlay)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = tv
        scrollView.documentCursor = .arrow
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.onTile = { [weak self] in self?.widthMayHaveChanged() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView)
    }

    @objc private func scrolled() {
        if !scrollingSelf { pinned = nil }
        refreshHover()
        spec?.callbacks.onScroll()
    }

    // MARK: Update from SwiftUI

    func update(_ new: NotesDocumentView) {
        let timecodesChanged = TimecodeKey(new.timecodes) != timecodeKey
        spec = new
        barContentStale = true
        accessibilityCache = nil
        if new.document !== document { install(new.document) }
        noteShine(new.shineTick)
        resolveMarks(new.marks)
        syncStacks(new.attachments, rail: new.rail, composing: new.composingAnchor)
        updateRailNeeds()
        if let previous = previousAim, new.aim == nil {
            if previous.isPassage { collapseSelection() } else { collapseSingleBlockSelection() }
        }
        previousAim = new.aim
        relayout()
        if let reopened = pendingReopen {
            // Once what stands under the row is placed: its picture carries it.
            pendingReopen = nil
            startReopen(reopened)
        }
        if let request = new.scrollRequest, request.token != lastScrollToken {
            lastScrollToken = request.token
            DispatchQueue.main.async { [weak self] in self?.scroll(to: request) }
        }
        if timecodesChanged {
            timecodeKey = TimecodeKey(new.timecodes)
            invalidateGutter(hoveredBlock)
            NSAccessibility.post(element: textView, notification: .layoutChanged)
        }
    }

    // MARK: Timecode marks

    /// What the marks depend on, for change detection.
    private struct TimecodeKey: Equatable {
        var targets: [String: NotesDocTimecode] = [:]
        var generation = -1
        var playing: String?

        init() {}

        init(_ timecodes: NotesDocTimecodes?) {
            guard let timecodes else { return }
            targets = timecodes.targets
            generation = timecodes.mappingGeneration
            playing = timecodes.playing
        }
    }
    private var timecodeKey = TimecodeKey()
    /// The block under the pointer; only its mark is drawn.
    private(set) var hoveredBlock: String?
    /// Where the pointer last was, in window coordinates, while it is over
    /// the view: a scroll or a layout change moves blocks under a pointer
    /// that stays put.
    private var pointerInWindow: NSPoint?

    /// Where a block's mark plays, nil when it has none.
    private func timecodePlayback(_ anchor: String) -> Double? {
        spec?.timecodes?.playback(anchor)
    }

    /// The mark's hit area: 22 × 22 centred on the glyph, which sits 18 left
    /// of the text column on the block's first line.
    static func timecodeHitRect(lineMidY: CGFloat, originX: CGFloat) -> NSRect {
        NSRect(x: originX - 18 - 11, y: lineMidY - 11, width: 22, height: 22)
    }

    /// The block laid out at the pointer's height, the gutter included.
    private func blockUnderPointer(y: CGFloat) -> NotesDocBlock? {
        guard let doc = document, let index = paragraphStart(at: NSPoint(x: textView.textContainerOrigin.x, y: y))
        else { return nil }
        return doc.block(atCharacter: index)
    }

    private func timecodeRect(_ anchor: String) -> NSRect? {
        guard let block = document?.block(anchor), let lines = lines(block.paragraph) else { return nil }
        return Self.timecodeHitRect(lineMidY: lines.first.midY, originX: textView.textContainerOrigin.x)
    }

    private func invalidateGutter(_ anchor: String?) {
        guard let anchor, spec?.timecodes?.targets[anchor] != nil, let rect = timecodeRect(anchor) else { return }
        textView.setNeedsDisplay(rect)
    }

    /// With no marks (the switch off, the player not ready) nothing is
    /// looked up and nothing is hovered.
    func pointerMoved(to point: NSPoint) {
        pointerInWindow = textView.convert(point, to: nil)
        let anchor = spec?.timecodes == nil ? nil : blockUnderPointer(y: point.y)?.anchorID
        guard anchor != hoveredBlock else { return }
        let previous = hoveredBlock
        hoveredBlock = anchor
        invalidateGutter(previous)
        invalidateGutter(anchor)
    }

    func pointerLeft() {
        pointerInWindow = nil
        let previous = hoveredBlock
        hoveredBlock = nil
        invalidateGutter(previous)
    }

    private func refreshHover() {
        if let pointerInWindow { pointerMoved(to: textView.convert(pointerInWindow, from: nil)) }
    }

    /// The block whose mark is under a point.
    func timecodeHit(at point: NSPoint) -> String? {
        return timecodeHit(at: point, block: blockUnderPointer(y: point.y)?.anchorID)
    }

    /// `anchor`'s mark, when it has one and its hit area holds the point.
    private func timecodeHit(at point: NSPoint, block anchor: String?) -> String? {
        guard let anchor, timecodePlayback(anchor) != nil, timecodeRect(anchor)?.contains(point) == true
        else { return nil }
        return anchor
    }

    func activateTimecode(_ anchor: String) {
        guard let timecodes = spec?.timecodes, let playback = timecodes.playback(anchor) else { return }
        timecodes.onActivate(anchor, playback)
    }

    /// "Play from m:ss", or "Pause" for the item playing.
    private func timecodeTitle(_ anchor: String) -> String? {
        guard let playback = timecodePlayback(anchor) else { return nil }
        return spec?.timecodes?.playing == anchor ? "Pause" : "Play from \(AudioPlayerView.clock(playback))"
    }

    fileprivate func timecodeScreenFrame(_ anchor: String) -> NSRect {
        guard let rect = timecodeRect(anchor), let window = textView.window else { return .zero }
        return window.convertToScreen(textView.convert(rect, to: nil))
    }

    @objc private func menuTimecode() {
        if let anchor = menuBlock?.anchorID { activateTimecode(anchor) }
    }

    /// A new string: set once, laid out whole (exact height, no estimated
    /// scroll jumps), with every open space re-applied to its paragraph.
    private func install(_ doc: NotesDocument) {
        installing = true
        defer { installing = false }
        let keep = scrollView.contentView.bounds.origin
        let selected = textView.selectedRange()
        let held = document.flatMap { Self.selectionInOneBlock($0, selected) }
        let completion = prepareCompletion(to: doc)
        pendingReopen = prepareReopen(to: doc)
        endDocumentMotion()
        document = doc
        justInstalled = true
        // The look never changes under a live pane (a new look re-roots the window).
        if doc.look.direction == .fluido, !softTopEdge {
            softTopEdge = true
            NotesDocMotion.setSoftTopEdge(scrollView)
        }
        textView.textStorage?.setAttributedString(doc.text)
        // A selection inside one block whose words are unchanged stays where
        // it was (a tick, a search, the Completed line); otherwise it is gone,
        // and so is the aim it made.
        if let held, let block = doc.block(held.anchor), block.hostText == held.hostText {
            textView.setSelectedRange(
                NSRange(location: block.range.location + held.local.location, length: held.local.length))
        } else if selected.length > 0 {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.textView.selectedRange().length == 0 else { return }
                self.spec?.callbacks.onSelection(nil, nil)
            }
        }
        for anchor in stacks.keys { applyGap(anchor) }
        if containerWidth > 0 { layoutWhole() }
        rebuildToggles(doc)
        scrollingSelf = true
        scrollView.contentView.scroll(to: keep)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        scrollingSelf = false
        if let completion { startCompletion(completion) }
    }

    /// The block a selection lies in, when it lies in exactly one, and the
    /// selected range inside that block.
    private static func selectionInOneBlock(_ doc: NotesDocument, _ range: NSRange)
        -> (anchor: String, hostText: String, local: NSRange)?
    {
        guard range.length > 0 else { return nil }
        let touched = doc.blocks.filter { NSIntersectionRange($0.range, range).length > 0 }
        guard touched.count == 1, let block = touched.first else { return nil }
        let inside = NSIntersectionRange(block.range, range)
        return (block.anchorID, block.hostText, NSRange(location: inside.location - block.range.location, length: inside.length))
    }

    private func layoutWhole() {
        guard let tlm = textView.textLayoutManager else { return }
        tlm.ensureLayout(for: tlm.documentRange)
        fitHeight()
    }

    /// The text view's height is the document's: SwiftUI never sees it.
    private func fitHeight() {
        guard let tlm = textView.textLayoutManager else { return }
        let height = ceil(tlm.usageBoundsForTextContainer.maxY + Self.inset.height * 2)
        let visible = scrollView.contentSize.height
        let wanted = max(height, visible)
        if abs(textView.frame.height - wanted) > 0.5 {
            textView.setFrameSize(NSSize(width: scrollView.contentSize.width, height: wanted))
        }
    }

    private func widthMayHaveChanged() {
        let available = scrollView.contentSize.width
        let width = max(200, min(available - Self.inset.width * 2, Self.measure))
        guard abs(width - containerWidth) > 0.5 else { return }
        containerWidth = width
        textView.textContainer?.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        if textView.frame.width != available {
            textView.setFrameSize(NSSize(width: available, height: textView.frame.height))
        }
        guard document != nil else { return }
        layoutWhole()
        // New width, new heights: every stack lands at once.
        for (anchor, stack) in stacks {
            measure(stack, anchor: anchor)
            let target = stack.measured > 0 ? stack.leading + stack.measured : 0
            stack.animating = false
            stack.target = target
            stack.value = target
            applyGapNow(anchor)
        }
        updateRailNeeds()
        relayout()
        if let request = pendingScroll {
            pendingScroll = nil
            scroll(to: request)
        }
    }

    // MARK: Marks

    private func resolveMarks(_ marks: [String: NotesDocMark]) {
        guard let doc = document else { return }
        var resolved: [ResolvedMark] = []
        for (anchor, mark) in marks {
            guard let block = doc.block(anchor) else { continue }
            if let range = mark.range {
                guard block.range.length > 0, NSMaxRange(range) <= block.range.length else { continue }
                resolved.append(
                    ResolvedMark(
                        range: NSRange(location: block.range.location + range.location, length: range.length),
                        emphasized: mark.emphasized))
            } else if let span = mark.span {
                guard block.range.length > 0,
                    let local = NotesProseHost.markRange(of: span, in: block.hostText)
                else { continue }
                resolved.append(
                    ResolvedMark(
                        range: NSRange(location: block.range.location + local.location, length: local.length),
                        emphasized: mark.emphasized))
            } else {
                resolved.append(ResolvedMark(range: block.range, emphasized: mark.emphasized, block: anchor))
            }
        }
        resolved.sort { $0.range.location < $1.range.location }
        guard resolved != resolvedMarks else { return }
        // The arrival flash is put down with today's 0.3 s fade, not at once.
        for mark in resolvedMarks where mark.emphasized && !resolved.contains(mark) {
            fadingMarks.append((mark, CACurrentMediaTime()))
        }
        if !fadingMarks.isEmpty, fadeTimer == nil {
            fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
                guard let self else {
                    timer.invalidate()
                    return
                }
                MainActor.assumeIsolated { self.fadeStep() }
            }
        }
        resolvedMarks = resolved
        textView.needsDisplay = true
    }

    private func fadeStep() {
        let now = CACurrentMediaTime()
        fadingMarks.removeAll { now - $0.start >= 0.3 }
        if fadingMarks.isEmpty {
            fadeTimer?.invalidate()
            fadeTimer = nil
        }
        textView.needsDisplay = true
    }

    // MARK: Stacks (the space that opens under a block)

    private func syncStacks(_ attachments: [String: AnyView], rail: [String: AnyView], composing: String?) {
        guard let doc = document else { return }
        // A block that left the document (ticked, the Completed line closed)
        // takes everything placed with it, at once.
        for (anchor, stack) in stacks where doc.block(anchor) == nil { removeStack(anchor, stack) }
        for (anchor, view) in attachments {
            guard doc.block(anchor) != nil else { continue }
            let stack: Stack
            if let existing = stacks[anchor] {
                stack = existing
                let leaving = existing.composing && composing != anchor
                if (leaving || existing.pendingRoot != nil), !justInstalled, !reduceMotion, containerWidth > 0 {
                    existing.pendingRoot = rooted(view)
                } else {
                    if leaving, reduceMotion, !justInstalled, containerWidth > 0 {
                        // Reduce Motion: the leaving composer crossfades into
                        // what stays under the block (today's 0.16 s crossfade).
                        let fade = CATransition()
                        fade.type = .fade
                        fade.duration = Self.crossfade
                        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                        existing.clip.layer?.add(fade, forKey: "crossfade")
                    }
                    existing.host.rootView = rooted(view)
                    existing.pendingRoot = nil
                }
            } else {
                stack = newStack(anchor, rooted(view))
            }
            if stack.clip.superview == nil { overlay.addSubview(stack.clip) }
            let isComposing = composing == anchor
            let composerMoved = isComposing != stack.composing
            if composerMoved, !isComposing { releaseFocus(from: stack) }
            stack.composing = isComposing
            measure(stack, anchor: anchor)
            let target = stack.measured > 0 ? stack.leading + stack.measured : 0
            // What already stands under a block when a document is installed
            // — a table, a note card — is simply there; only change moves. The
            // header is the top of the page, as today: its height changes at once.
            retarget(
                anchor, stack, to: target, animated: !justInstalled && anchor != NotesDocument.headAnchor,
                fromTop: composerMoved)
        }
        for (anchor, stack) in stacks where attachments[anchor] == nil {
            if stack.composing { releaseFocus(from: stack) }
            retarget(anchor, stack, to: 0, animated: !justInstalled, fromTop: stack.composing)
            stack.composing = false
        }
        syncRail(rail)
        justInstalled = false
    }

    private func newStack(_ anchor: String, _ view: AnyView) -> Stack {
        let stack = Stack(view)
        stack.leading = document?.block(anchor)?.table != nil || NotesDocument.isEdge(anchor) ? 0 : 6
        stacks[anchor] = stack
        return stack
    }

    private var justInstalled = false

    /// A closing composer hands the keyboard back to the notes. Its field
    /// would otherwise keep focus while it slides out and is removed, and the
    /// system's caret accessory stays on screen where the field was.
    private func releaseFocus(from stack: Stack) {
        guard let window = textView.window, let focused = window.firstResponder as? NSView,
            focused.isDescendant(of: stack.host.view)
        else { return }
        window.makeFirstResponder(textView)
    }

    /// A placed piece reports its own height, so content that changes on its
    /// own (an error line appearing, a field growing) re-opens its space.
    private func rooted(_ view: AnyView) -> AnyView {
        AnyView(
            NotesDocNaturalHeight {
                view.onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { [weak self] _ in
                    self?.contentHeightChanged()
                }
            })
    }

    private var remeasureQueued = false

    private func contentHeightChanged() {
        guard !remeasureQueued else { return }
        remeasureQueued = true
        DispatchQueue.main.async { [weak self] in self?.remeasure() }
    }

    private func remeasure() {
        remeasureQueued = false
        guard document != nil, containerWidth > 0 else { return }
        var changed = false
        for (anchor, stack) in stacks where stack.target > 0 && stack.pendingRoot == nil {
            let before = stack.measured
            measure(stack, anchor: anchor)
            guard abs(stack.measured - before) > 0.5 else { continue }
            retarget(
                anchor, stack, to: stack.leading + stack.measured, animated: stack.animating, fromTop: stack.fromTop)
            changed = true
        }
        if changed {
            updateRailNeeds()
            relayout()
        }
    }

    private func measure(_ stack: Stack, anchor: String) {
        guard let block = document?.block(anchor), containerWidth > 0 else { return }
        // A stack holding only margin notes has no piece to measure (an empty
        // hosted view reports an unbounded height).
        guard stack.clip.superview != nil else {
            stack.measured = 0
            return
        }
        let width = stackWidth(block)
        let proposal = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        if let pending = stack.pendingRoot {
            stack.measured = ceil(NSHostingController(rootView: pending).sizeThatFits(in: proposal).height)
        } else {
            stack.measured = ceil(stack.host.sizeThatFits(in: proposal).height)
            stack.shownHeight = stack.measured
        }
    }

    private func stackWidth(_ block: NotesDocBlock) -> CGFloat {
        NotesDocument.isEdge(block.anchorID)
            ? containerWidth : containerWidth - block.indent - trailing(block)
    }

    /// Where a block's section ends its content on the right.
    private func trailing(_ block: NotesDocBlock) -> CGFloat {
        document?.insets(ofParagraph: block.paragraph).trailing ?? NotesDocStyle.boxPadding
    }

    private func retarget(_ anchor: String, _ stack: Stack, to target: CGFloat, animated: Bool, fromTop: Bool) {
        guard abs(target - stack.target) > 0.25 || (stack.animating && abs(target - stack.value) > 0.25) else {
            return
        }
        let crossfade = animated && reduceMotion && containerWidth > 0
        if crossfade, target == 0 {
            // Reduce Motion: the piece fades out where it stands, then its
            // space closes at once.
            stack.animating = false
            stack.target = 0
            stack.crossfading = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.crossfade
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                stack.clip.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.crossfadeClosed(anchor, stack) }
            }
            return
        }
        if !animated || reduceMotion || containerWidth == 0 || belowView(anchor, stack) {
            let opening = target > stack.value
            stack.animating = false
            stack.target = target
            stack.value = target
            stack.fromTop = false
            if let root = stack.pendingRoot {
                stack.host.rootView = root
                stack.shownHeight = stack.measured
                stack.pendingRoot = nil
            }
            applyGapNow(anchor)
            if target == 0 {
                closePiece(anchor, stack)
            } else if crossfade, opening {
                // Reduce Motion: the space opens at once and the piece fades in.
                stack.crossfading = true
                stack.clip.alphaValue = 0
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = Self.crossfade
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    stack.clip.animator().alphaValue = 1
                } completionHandler: {
                    MainActor.assumeIsolated { stack.crossfading = false }
                }
            }
            return
        }
        let now = CACurrentMediaTime()
        // Interrupted mid-flight: carry the current position and speed.
        var velocity = 0.0
        if stack.animating {
            velocity = spring.velocity(
                target: Double(stack.target - stack.from), initialVelocity: stack.velocity,
                time: now - stack.start)
        }
        stack.from = stack.value
        stack.target = target
        stack.velocity = velocity
        stack.start = now
        stack.duration = spring.settlingDuration(
            target: Double(target - stack.from), initialVelocity: velocity, epsilon: 0.25)
        stack.animating = true
        stack.fromTop = fromTop || (stack.fromTop && stack.animating)
        startTicking()
    }

    /// A space whose top edge is below the page on screen moves nothing the
    /// reader sees: it lands at once, instead of re-laying the whole document
    /// out on every frame of a spring no one watches.
    private func belowView(_ anchor: String, _ stack: Stack) -> Bool {
        guard let block = document?.block(anchor), let lines = lines(block.paragraph) else { return false }
        return lines.bottom + stack.leading >= scrollView.documentVisibleRect.maxY
    }

    private func crossfadeClosed(_ anchor: String, _ stack: Stack) {
        stack.crossfading = false
        guard stacks[anchor] === stack else { return }
        guard stack.target == 0 else {
            stack.clip.alphaValue = 1
            return
        }
        stack.value = 0
        applyGapNow(anchor)
        closePiece(anchor, stack)
        relayout()
    }

    /// A closed space's piece leaves the page, and the accessibility tree
    /// stops listing it; the stack stays while its block keeps margin notes.
    private func closePiece(_ anchor: String, _ stack: Stack) {
        guard stack.rail != nil else { return removeStack(anchor, stack) }
        stack.clip.removeFromSuperview()
        accessibilityCache = nil
        NSAccessibility.post(element: textView, notification: .layoutChanged)
    }

    /// Everything placed with a block leaves the page.
    private func removeStack(_ anchor: String, _ stack: Stack) {
        stack.clip.removeFromSuperview()
        stack.rail?.removeFromSuperview()
        stacks[anchor] = nil
        accessibilityCache = nil
        NSAccessibility.post(element: textView, notification: .layoutChanged)
    }

    private func startTicking() {
        guard displayLink == nil else { return }
        let link = textView.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        var running = false
        textView.textStorage?.beginEditing()
        for (anchor, stack) in stacks where stack.animating {
            let elapsed = now - stack.start
            if elapsed >= stack.duration {
                stack.value = stack.target
                stack.animating = false
            } else {
                stack.value = stack.from
                    + CGFloat(spring.value(
                        target: Double(stack.target - stack.from), initialVelocity: stack.velocity,
                        time: elapsed))
                running = true
            }
            applyGap(anchor)
        }
        textView.textStorage?.endEditing()
        relayout()
        if !running {
            link.invalidate()
            displayLink = nil
            for (anchor, stack) in stacks where !stack.animating {
                stack.fromTop = false
                if let root = stack.pendingRoot {
                    stack.host.rootView = root
                    stack.shownHeight = stack.measured
                    stack.pendingRoot = nil
                }
                if stack.target == 0, stack.clip.superview != nil {
                    closePiece(anchor, stack)
                }
            }
            relayout()
        }
    }

    private func applyGapNow(_ anchor: String) {
        textView.textStorage?.beginEditing()
        applyGap(anchor)
        textView.textStorage?.endEditing()
    }

    /// The space open under a block: what is placed under it, or as far as
    /// its margin notes reach below its lines, whichever is more — today's
    /// row, where the rail stands beside the text and what hangs under it.
    private func gap(_ stack: Stack?) -> CGFloat {
        guard let stack else { return 0 }
        return max(max(0, stack.value), stack.railNeed)
    }

    /// The one mechanism: the block's paragraph spacing grows by its gap.
    private func applyGap(_ anchor: String) {
        guard let doc = document, let block = doc.block(anchor),
            let storage = textView.textStorage
        else { return }
        let paragraph = doc.paragraphs[block.paragraph]
        guard NSMaxRange(paragraph.range) <= storage.length, paragraph.range.length > 0 else { return }
        let style = paragraph.style.mutableCopy() as! NSMutableParagraphStyle
        var spacing = paragraph.style.paragraphSpacing + gap(stacks[anchor])
        if let opening = motion.opening, opening.paragraph == block.paragraph {
            // An arriving row's space: its lines and spacing at `fraction` of their height.
            let fraction = max(0, opening.fraction)
            spacing *= fraction
            style.minimumLineHeight = max(0.5, opening.lineHeight * fraction)
            style.maximumLineHeight = style.minimumLineHeight
        }
        // Space held for what left is not the arriving row's: it closes on its own.
        style.paragraphSpacing = max(0, spacing + motion.settle(block.paragraph))
        storage.addAttribute(.paragraphStyle, value: style, range: paragraph.range)
    }

    // MARK: Geometry

    private func location(_ offset: Int) -> NSTextLocation? {
        guard let tcm = textView.textLayoutManager?.textContentManager else { return nil }
        return tcm.location(tcm.documentRange.location, offsetBy: offset)
    }

    private func offset(_ location: NSTextLocation) -> Int {
        guard let tcm = textView.textLayoutManager?.textContentManager else { return 0 }
        return tcm.offset(from: tcm.documentRange.location, to: location)
    }

    /// The laid-out fragment of one paragraph, in text-container space.
    private func fragment(_ paragraph: Int) -> NSTextLayoutFragment? {
        guard let doc = document, let tlm = textView.textLayoutManager,
            let location = location(doc.paragraphs[paragraph].range.location)
        else { return nil }
        var found: NSTextLayoutFragment?
        tlm.enumerateTextLayoutFragments(from: location, options: [.ensuresLayout]) { fragment in
            found = fragment
            return false
        }
        return found
    }

    /// The top of a paragraph's first line and the bottom of its last, in
    /// text-view space.
    fileprivate func lines(_ paragraph: Int) -> (top: CGFloat, bottom: CGFloat, first: CGRect)? {
        guard let fragment = fragment(paragraph), let first = fragment.textLineFragments.first,
            let last = fragment.textLineFragments.last
        else { return nil }
        let origin = textView.textContainerOrigin
        let frame = fragment.layoutFragmentFrame
        let firstRect = first.typographicBounds.offsetBy(dx: frame.minX + origin.x, dy: frame.minY + origin.y)
        return (firstRect.minY, frame.minY + last.typographicBounds.maxY + origin.y, firstRect)
    }

    /// Positions everything hosted, after the text has moved. The whole
    /// document is laid out first: a space opening under one block moves every
    /// block below it, and a fragment TextKit has not laid out reports an
    /// ESTIMATED position — a piece placed from it lands on the wrong text and
    /// stays there when scrolling lays the real text out underneath.
    private func relayout() {
        guard let doc = document, containerWidth > 0, let tlm = textView.textLayoutManager else { return }
        tlm.ensureLayout(for: tlm.documentRange)
        fitHeight()
        let origin = textView.textContainerOrigin
        for (anchor, stack) in stacks {
            guard let block = doc.block(anchor), let lines = lines(block.paragraph) else { continue }
            let open = max(0, stack.value - stack.leading)
            let width = stackWidth(block)
            stack.clip.frame = NSRect(
                x: origin.x + (NotesDocument.isEdge(anchor) ? 0 : block.indent),
                y: lines.bottom + stack.leading, width: width, height: open)
            let height = max(stack.pendingRoot == nil ? stack.measured : stack.shownHeight, open)
            let y = stack.fromTop ? open - height : 0
            stack.host.view.frame = NSRect(x: 0, y: y, width: width, height: height)
            // Arriving, the piece comes in with its space (today's move +
            // opacity); leaving, it rides the closing space up at full ink.
            if motion.opening?.anchor == anchor {
                // An arriving row's pieces are in its picture until it lands.
                stack.clip.alphaValue = 0
            } else if !stack.crossfading {
                let arriving = stack.target >= stack.from
                stack.clip.alphaValue = stack.fromTop && arriving && height > 0 ? min(1, open / height * 1.4) : 1
            }
            // An arriving row's side notes come in with its picture.
            let arrival = motion.opening.flatMap { $0.anchor == anchor ? max(0, min(1, $0.fraction)) : nil }
            stack.rail?.alphaValue = arrival ?? 1
            stack.rail?.frame = NSRect(
                x: railX, y: lines.top, width: NotesEditingLayout.railWidth, height: stack.railHeight)
        }
        for (index, toggle) in toggleViews.enumerated() {
            guard index < doc.toggles.count, let lines = lines(doc.toggles[index].paragraph) else { continue }
            toggle.frame = NSRect(
                x: origin.x + doc.look.userContent.leading, y: lines.first.midY - 9,
                width: NotesDocStyle.toggleWidth + 4, height: 18)
        }
        if let disclosureView, let paragraph = doc.completedDisclosure, let lines = lines(paragraph) {
            disclosureView.frame = NSRect(
                x: origin.x + doc.look.userContent.leading - 2, y: lines.first.midY - 8, width: 16, height: 16)
        }
        layoutCards()
        layoutBar()
        if overlay.superview === textView, textView.subviews.last !== overlay {
            textView.addSubview(overlay, positioned: .above, relativeTo: nil)
        }
        overlay.frame = textView.bounds
        textView.needsDisplay = true
        holdPinnedScroll()
        // Text that moved under a pointer that stayed put.
        refreshHover()
    }

    // MARK: Section boxes

    private let cards = NotesDocCards()

    /// A section's chrome, from its first content line to its last and what
    /// stands under it, padded by its look's insets.
    private func sectionRect(_ section: NotesDocSection) -> NSRect? {
        guard let doc = document, let first = lines(section.firstContent), let last = lines(section.lastContent)
        else { return nil }
        let insets = doc.look.insets(section.kind)
        // A row's space held open under the title, or under the last row,
        // belongs inside the box.
        let top = first.top - insets.top - motion.settle(section.title)
        // An arriving last row's own spacing is still opening: the box ends
        // that much short, over the section under it.
        let arriving = motion.opening.flatMap { $0.paragraph == section.lastContent ? max(0, $0.fraction) : nil }
        let unopened = arriving.map {
            (1 - $0) * (doc.paragraphs[section.lastContent].style.paragraphSpacing
                + openSpace(afterParagraph: section.lastContent))
        } ?? 0
        let bottom = last.bottom + insets.bottom + openSpace(afterParagraph: section.lastContent)
            + motion.settle(section.lastContent) - unopened
        return NSRect(x: textView.textContainerOrigin.x, y: top, width: boxWidth, height: bottom - top)
    }

    /// Fluido's material cards follow their sections' boxes.
    private func layoutCards() {
        guard let doc = document else { return }
        var frames: [(rect: NSRect, radius: CGFloat)] = []
        if doc.look.chrome == .card {
            for section in doc.sections {
                guard let rect = sectionRect(section) else { continue }
                frames.append((rect, section.kind == .userActions ? doc.look.userRadius : doc.look.radius))
            }
        }
        cards.place(frames, in: scrollView.contentView, below: textView)
    }

    private struct BarKey: Equatable {
        var anchor: String
        var pointsUp: Bool
        var tail: CGFloat
    }

    private var barKey: BarKey?
    private var barContentStale = true

    // MARK: The margin rail

    /// Each block's margin notes join that block's stack; a block without
    /// notes loses its rail, and a stack holding nothing else leaves.
    private func syncRail(_ rail: [String: AnyView]) {
        guard let doc = document else { return }
        for (anchor, content) in rail where doc.block(anchor) != nil {
            let stack = stacks[anchor] ?? newStack(anchor, AnyView(EmptyView()))
            let rooted = AnyView(content.frame(width: NotesEditingLayout.railWidth, alignment: .leading))
            if let view = stack.rail {
                view.rootView = rooted
            } else {
                let view = NSHostingView(rootView: rooted)
                overlay.addSubview(view)
                stack.rail = view
            }
        }
        for (anchor, stack) in stacks where rail[anchor] == nil {
            guard let view = stack.rail else { continue }
            view.removeFromSuperview()
            stack.rail = nil
            stack.railHeight = 0
            stack.railNeed = 0
            if stack.clip.superview == nil {
                removeStack(anchor, stack)
            } else {
                applyGapNow(anchor)
            }
        }
    }

    /// How far each block's rail reaches below the block's own lines: the
    /// block's gap is at least that, so a tall note pushes the next block down.
    private func updateRailNeeds() {
        guard let doc = document, containerWidth > 0 else { return }
        for (anchor, stack) in stacks {
            guard let view = stack.rail, let block = doc.block(anchor), let lines = lines(block.paragraph) else { continue }
            let height = ceil(view.fittingSize.height)
            let need = max(0, height - (lines.bottom - lines.top))
            stack.railHeight = height
            guard abs(need - stack.railNeed) > 0.25 else { continue }
            stack.railNeed = need
            applyGapNow(anchor)
        }
    }

    /// The section boxes widen by the lane when the margin mode is live; the
    /// text keeps its measure.
    private var boxWidth: CGFloat {
        containerWidth + (spec?.railLane == true ? NotesEditingLayout.railGutter + NotesEditingLayout.railWidth : 0)
    }

    /// The rail's left edge: past the section content's right edge by the gutter.
    private var railX: CGFloat {
        textView.textContainerOrigin.x + containerWidth - (document?.look.content.trailing ?? NotesDocStyle.boxPadding)
            + NotesEditingLayout.railGutter
    }

    // MARK: Done toggles

    private func rebuildToggles(_ doc: NotesDocument) {
        toggleViews.forEach { $0.removeFromSuperview() }
        toggleViews = doc.toggles.map { toggle in
            let view = NSHostingView(
                rootView: AnyView(
                    NotesDocDoneToggle(done: toggle.done, text: toggle.item.text) { [weak self] in
                        self?.spec?.callbacks.onToggle(toggle.item, !toggle.done)
                    }))
            overlay.addSubview(view)
            return view
        }
        disclosureView?.removeFromSuperview()
        disclosureView = nil
        if let paragraph = doc.completedDisclosure {
            let label = (doc.text.string as NSString).substring(with: doc.paragraphs[paragraph].range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let view = NSHostingView(
                rootView: AnyView(
                    NotesDocDisclosureChevron(expanded: spec?.completedExpanded ?? false, label: label) {
                        [weak self] in self?.spec?.callbacks.onToggleCompleted()
                    }))
            overlay.addSubview(view)
            disclosureView = view
        }
    }

    // MARK: The selection bar

    private func layoutBar() {
        guard let doc = document, let aim = spec?.aim, let config = spec?.bar,
            let block = doc.block(aim.anchorID), let lines = lines(block.paragraph)
        else {
            if let leaving = barView {
                // Today's `.transition(.opacity)`.
                barView = nil
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = Self.barFade
                    leaving.animator().alphaValue = 0
                } completionHandler: {
                    MainActor.assumeIsolated { leaving.removeFromSuperview() }
                }
            }
            return
        }
        let origin = CGPoint(x: textView.textContainerOrigin.x + block.indent, y: lines.top)
        var frame = SelectionFrame(
            first: CGRect(x: 0, y: 0, width: 0, height: SelectionFrame.blockStart.first.height),
            last: CGRect(x: 0, y: blockBottom(block, lines: lines) - lines.top, width: 0, height: 0))
        let selected = textView.selectedRange()
        if aim.isSpan, selected.length > 0,
            let first = segment(NSRange(location: selected.location, length: 1)),
            let last = segment(NSRange(location: NSMaxRange(selected) - 1, length: 1))
        {
            frame = SelectionFrame(
                first: first.offsetBy(dx: -origin.x, dy: -origin.y),
                last: last.offsetBy(dx: -origin.x, dy: -origin.y))
        }
        let visible = scrollView.contentView.bounds
        // The bar stays inside the reading column, measured from where it
        // starts (an indented block, the user box, a narrow pane).
        let placement = SelectionBarPlacement.resolve(
            selection: frame, measure: containerWidth - block.indent, blockTop: origin.y - visible.minY,
            paneHeight: visible.height)
        let bar = SelectionActionBar(
            correctionEnabled: config.correctionEnabled, engineCanEditNotes: config.engineCanEditNotes,
            pointsUp: !placement.above, tailOffset: placement.tailOffset, onAction: config.onAction)
        let host = barView ?? NSHostingView(rootView: AnyView(EmptyView()))
        let key = BarKey(anchor: aim.anchorID, pointsUp: !placement.above, tail: placement.tailOffset)
        // The bar's content changes with the pane or its placement, never
        // per animation frame.
        if barContentStale || key != barKey {
            host.rootView = AnyView(bar)
            barKey = key
            barContentStale = false
        }
        if barView == nil {
            host.alphaValue = 0
            overlay.addSubview(host)
            barView = host
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.barFade
                host.animator().alphaValue = 1
            }
        }
        host.frame = NSRect(
            origin: CGPoint(x: origin.x + placement.origin.x, y: origin.y + placement.origin.y),
            size: SelectionActionBar.size)
    }

    static let barFade: TimeInterval = 0.2

    /// The bottom of a block: its last line, or the table placed under it.
    private func blockBottom(_ block: NotesDocBlock, lines: (top: CGFloat, bottom: CGFloat, first: CGRect)) -> CGFloat {
        guard block.table != nil, let stack = stacks[block.anchorID] else { return lines.bottom }
        return lines.bottom + stack.leading + stack.measured
    }

    /// One character's line segment, in text-view space.
    private func segment(_ range: NSRange) -> CGRect? {
        guard let tlm = textView.textLayoutManager, let start = location(range.location),
            let end = location(NSMaxRange(range)), let textRange = NSTextRange(location: start, end: end)
        else { return nil }
        var rect: CGRect?
        tlm.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, segment, _, _ in
            rect = segment
            return false
        }
        let origin = textView.textContainerOrigin
        return rect?.offsetBy(dx: origin.x, dy: origin.y)
    }

    // MARK: Selection → today's machinery

    /// A double or triple click is being tracked.
    var multiClick = false

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !installing, let doc = document, let callbacks = spec?.callbacks else { return }
        let range = textView.selectedRange()
        guard range.length > 0 else {
            callbacks.onSelection(nil, nil)
            return
        }
        if let (block, local) = doc.aim(for: range) {
            guard !(multiClick && block.section == .userActionItem) else {
                callbacks.onClear()
                return
            }
            callbacks.onSelection(block, NotesProseHost.span(of: local, in: block.hostText))
            return
        }
        // Across blocks: the pieces decide. Inside code or on a done item
        // alone: Copy and the system menu work; nothing is aimed at (no bar).
        switch doc.capture(range) {
        case .passage(let passage):
            callbacks.onPassage(passage)
        case .onePiece(let anchorID, let local):
            guard let block = doc.block(anchorID), !doc.paragraphs[block.paragraph].isCode,
                !(multiClick && block.section == .userActionItem)
            else {
                callbacks.onClear()
                return
            }
            callbacks.onSelection(block, NotesProseHost.span(of: local, in: block.hostText))
        case .none:
            callbacks.onClear()
        }
    }

    /// The block under a point, only when the point is on its lines — a click
    /// in the space between blocks is a click off every block.
    private func block(at point: NSPoint) -> NotesDocBlock? {
        guard let doc = document, let index = paragraphStart(at: point) else { return nil }
        guard let block = doc.block(atCharacter: index), block.targetable, block.range.length > 0, let lines = lines(block.paragraph),
            point.y >= lines.top - 3, point.y <= lines.bottom + 3
        else { return nil }
        return block
    }

    /// Where the paragraph laid out at `point` starts. Read from the layout,
    /// never through the text view's own hit-testing, which asks the window
    /// (and so this view's placed pieces) again.
    private func paragraphStart(at point: NSPoint) -> Int? {
        guard let tlm = textView.textLayoutManager else { return nil }
        let origin = textView.textContainerOrigin
        guard let fragment = tlm.textLayoutFragment(for: CGPoint(x: point.x - origin.x, y: point.y - origin.y))
        else { return nil }
        return offset(fragment.rangeInElement.location)
    }

    /// The block whose menu a right-click at `point` opens: its lines, the gap
    /// below them, and everything placed under or beside it (a table, the
    /// composer, rows, cards, rail notes).
    fileprivate func menuBlock(at point: NSPoint) -> NotesDocBlock? {
        guard let doc = document, containerWidth > 0 else { return nil }
        if let block = block(at: point) { return block }
        let left = textView.textContainerOrigin.x
        let inColumn = point.x >= left && point.x <= left + boxWidth
        for (anchor, stack) in stacks where !NotesDocument.isEdge(anchor) && inColumn {
            let area = stack.clip.frame
            guard area.height > 0, point.y >= area.minY - stack.leading - 3,
                point.y <= area.maxY + NotesDocStyle.blockGap
            else { continue }
            if let block = doc.block(anchor), block.targetable { return block }
        }
        for (anchor, stack) in stacks where stack.rail?.frame.insetBy(dx: 0, dy: -3).contains(point) == true {
            if let block = doc.block(anchor), block.targetable { return block }
        }
        guard inColumn else { return nil }
        for lift in [0, NotesDocStyle.blockGap] {
            guard let index = paragraphStart(at: NSPoint(x: point.x, y: point.y - lift)),
                let block = doc.block(atCharacter: index), block.targetable, block.range.length > 0,
                let lines = lines(block.paragraph),
                point.y >= lines.top - 3, point.y <= lines.bottom + NotesDocStyle.blockGap
            else { continue }
            return block
        }
        return nil
    }

    /// A click on a table (hosted, so the text view never sees it) picks the
    /// table as a whole block; the click still reaches the cells. Only a click
    /// that lands in the table's own hosted view: the selection bar or a rail
    /// note standing over the table keeps its click.
    private func tableClick(_ event: NSEvent) {
        guard let doc = document, let window = textView.window, event.window === window,
            !event.modifierFlags.contains(.control)
        else { return }
        let point = textView.convert(event.locationInWindow, from: nil)
        guard textView.visibleRect.contains(point), let hit = window.contentView?.hitTest(event.locationInWindow)
        else { return }
        for (anchor, stack) in stacks where hit.isDescendant(of: stack.host.view) {
            if let block = doc.block(anchor), block.table != nil { spec?.callbacks.onPick(block) }
            return
        }
    }

    func clickEnded(_ event: NSEvent) {
        guard textView.selectedRange().length == 0, let callbacks = spec?.callbacks else { return }
        let point = textView.convert(event.locationInWindow, from: nil)
        if let block = block(at: point) {
            // In the your-action-items box a plain click never aims an item:
            // the circle ticks; words are aimed by a drag or the right-click menu.
            if block.section == .userActionItem { callbacks.onClear() } else { callbacks.onPick(block) }
        } else if let paragraph = document?.completedDisclosure, let lines = lines(paragraph),
            point.y >= lines.top - 3, point.y <= lines.bottom + 3
        {
            callbacks.onToggleCompleted()
        } else {
            callbacks.onClear()
        }
    }

    /// The pointer at a point of the text view: the arrow over a placed
    /// piece, nil over a text input in one (it keeps its own).
    func cursor(at point: NSPoint) -> NSCursor? {
        // Every caller has just moved the hover to this point.
        if timecodeHit(at: point, block: hoveredBlock) != nil { return .pointingHand }
        if let hit = overlay.hitTest(point) { return hit is NSText || hit is NSTextField ? nil : .arrow }
        guard let index = character(at: point), let storage = textView.textStorage, index < storage.length,
            segment(NSRange(location: index, length: 1))?.insetBy(dx: -1, dy: -1).contains(point) == true
        else { return .arrow }
        // The Completed row is a control: a click opens or closes the list.
        if let doc = document, let row = doc.completedDisclosure, NSLocationInRange(index, doc.paragraphs[row].range) {
            return .arrow
        }
        return storage.attribute(.link, at: index, effectiveRange: nil) != nil ? .pointingHand : .iBeam
    }

    func escape() {
        collapseSelection()
        spec?.callbacks.onClear()
    }

    private func collapseSelection() {
        let range = textView.selectedRange()
        if range.length > 0 { textView.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0)) }
    }

    /// The pane put its aim down (the composer closed, the page was given
    /// back): a selection that was the aim goes with it. A selection that was
    /// never an aim (across blocks, inside code, on a done item) stays for Copy.
    private func collapseSingleBlockSelection() {
        guard let doc = document else { return }
        let range = textView.selectedRange()
        guard range.length > 0 else { return }
        if doc.aim(for: range) != nil {
            collapseSelection()
        }
    }

    // MARK: Accessibility

    private var accessibilityCache: [Any]?

    /// The screen frame of a paragraph's lines.
    fileprivate func screenFrame(paragraph: Int) -> NSRect {
        guard let lines = lines(paragraph), let window = textView.window else { return .zero }
        let rect = NSRect(
            x: textView.textContainerOrigin.x, y: lines.top, width: containerWidth, height: lines.bottom - lines.top)
        return window.convertToScreen(textView.convert(rect, to: nil))
    }

    /// The screen frame of a run of the document's characters.
    fileprivate func screenFrame(characters range: NSRange) -> NSRect {
        guard let tlm = textView.textLayoutManager, let window = textView.window, let start = location(range.location),
            let end = location(NSMaxRange(range)), let textRange = NSTextRange(location: start, end: end)
        else { return .zero }
        var union = NSRect.null
        tlm.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, segment, _, _ in
            union = union.union(segment)
            return true
        }
        guard !union.isNull else { return .zero }
        let origin = textView.textContainerOrigin
        return window.convertToScreen(textView.convert(union.offsetBy(dx: origin.x, dy: origin.y), to: nil))
    }

    /// Each laid-out line of a paragraph, as a range inside the paragraph.
    fileprivate func lineRanges(paragraph: Int) -> [NSRange] {
        guard let fragment = fragment(paragraph) else { return [] }
        return fragment.textLineFragments.map(\.characterRange)
    }

    fileprivate func accessibilityElements() -> [Any] {
        if let accessibilityCache { return accessibilityCache }
        guard let doc = document else { return [] }
        var blockAt: [Int: NotesDocBlock] = [:]
        for block in doc.blocks { blockAt[block.paragraph] = block }
        var toggleAt: [Int: NSView] = [:]
        for (index, toggle) in doc.toggles.enumerated() where index < toggleViews.count {
            toggleAt[toggle.paragraph] = toggleViews[index]
        }
        func text(_ paragraph: Int, role: NSAccessibility.Role, parent: Any) -> NotesDocAccessibilityText? {
            var range = doc.paragraphs[paragraph].range
            if range.length > 0, (doc.text.string as NSString).character(at: NSMaxRange(range) - 1) == 0x0A {
                range.length -= 1
            }
            // Offset for offset: copy keeps every character of a block's own
            // paragraph (placeholders live in paragraphs of their own).
            let words = NotesDocument.copyText(doc.text.attributedSubstring(from: range)).string
            guard !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let element = NotesDocAccessibilityText()
            element.controller = self
            element.paragraph = paragraph
            element.range = range
            element.words = words
            element.setAccessibilityRole(role)
            // A heading is announced by its label; a block reads its value.
            if role == Self.headingRole { element.setAccessibilityLabel(words) }
            element.setAccessibilityParent(parent)
            doc.text.enumerateAttribute(.link, in: range) { value, linkRange, _ in
                guard let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:)) else { return }
                let link = NotesDocAccessibilityLink()
                link.controller = self
                link.range = linkRange
                link.url = url
                link.setAccessibilityRole(.link)
                link.setAccessibilityLabel((doc.text.string as NSString).substring(with: linkRange))
                link.setAccessibilityURL(url)
                link.setAccessibilityParent(element)
                element.links.append(link)
            }
            if !element.links.isEmpty { element.setAccessibilityChildren(element.links) }
            return element
        }
        /// A block's text, then everything placed with it.
        func pieces(_ paragraph: Int, parent: Any) -> [Any] {
            var out: [Any] = []
            let block = blockAt[paragraph]
            if paragraph == doc.completedDisclosure, let disclosureView {
                return [disclosureView]
            }
            // A block with a timecode mark starts with its play button.
            if let block, let title = timecodeTitle(block.anchorID) {
                let button = NotesDocAccessibilityTimecode()
                button.controller = self
                button.anchorID = block.anchorID
                button.setAccessibilityRole(.button)
                button.setAccessibilityLabel(title)
                button.setAccessibilityParent(parent)
                out.append(button)
            }
            // A checklist item reads its done button first, as today's row does.
            if let toggle = toggleAt[paragraph] { out.append(toggle) }
            if let element = text(paragraph, role: .textArea, parent: parent) {
                if block?.searchMatch == true { element.setAccessibilityHelp("Contains the current search match") }
                out.append(element)
            }
            if let block {
                if let stack = stacks[block.anchorID] {
                    if stack.clip.superview != nil { out.append(stack.host.view) }
                    if let rail = stack.rail { out.append(rail) }
                }
                if spec?.aim?.anchorID == block.anchorID, let barView { out.append(barView) }
            }
            return out
        }
        var result: [Any] = []
        if let head = stacks[NotesDocument.headAnchor] { result.append(head.host.view) }
        for section in doc.sections {
            if section.kind == .userActions {
                let group = NotesDocAccessibilityGroup()
                group.controller = self
                group.paragraphs = section.title..<(section.lastContent + 1)
                group.setAccessibilityRole(.group)
                group.setAccessibilityLabel("Your action items")
                group.setAccessibilityParent(textView)
                var children: [Any] = []
                if let title = text(section.title, role: Self.headingRole, parent: group) { children.append(title) }
                for paragraph in section.firstContent...section.lastContent { children += pieces(paragraph, parent: group) }
                group.setAccessibilityChildren(children)
                result.append(group)
                continue
            }
            if let title = text(section.title, role: Self.headingRole, parent: textView) { result.append(title) }
            for paragraph in section.firstContent...section.lastContent { result += pieces(paragraph, parent: textView) }
        }
        if let tail = stacks[NotesDocument.tailAnchor] { result.append(tail.host.view) }
        accessibilityCache = result
        return result
    }

    /// `NSAccessibilityHeadingRole` (named in the SDK from macOS 26; the same
    /// string assistive tech has long read as a heading).
    static let headingRole = NSAccessibility.Role(rawValue: "AXHeading")

    // MARK: Right-click: the system text menu with the block actions on top

    private var menuBlock: NotesDocBlock?

    func menu(for event: NSEvent, system: () -> NSMenu?) -> NSMenu? {
        let point = textView.convert(event.locationInWindow, from: nil)
        let selected = textView.selectedRange()
        let inSelection = selected.length > 0
            && character(at: point).map { NSLocationInRange($0, selected) } == true
        let under = menuBlock(at: point)
        // A title, a done item or the Completed line inside an aimed
        // selection is part of it: the right-click acts on the selection (n7 §1).
        let aimed = under == nil && inSelection && spec?.aim != nil
            ? spec?.aim.flatMap { document?.block($0.anchorID) } : nil
        guard let block = under ?? aimed, let offers = spec?.callbacks.menuOffers() else { return system() }
        menuBlock = block
        menuInSelection = inSelection
        // Words a double click selected on a checklist item aim nothing (no
        // bar); a right-click inside them still acts on them.
        menuSpan = nil
        if inSelection, spec?.aim == nil, block.section == .userActionItem,
            let (held, local) = document?.aim(for: selected), held.anchorID == block.anchorID
        {
            menuSpan = NotesProseHost.span(of: local, in: held.hostText)
        }
        // On the words: the system text menu under the block's actions. On a
        // piece placed under the block (a table, cards, the composer): only
        // the block's actions, as today, and the text's selection is left alone.
        let menu = (self.block(at: point) != nil || aimed != nil ? system() : nil) ?? NSMenu()
        var index = 0
        if let title = timecodeTitle(block.anchorID) {
            let item = NSMenuItem(title: title, action: #selector(menuTimecode), keyEquivalent: "")
            item.target = self
            menu.insertItem(item, at: index)
            index += 1
        }
        if offers.correct {
            let item = NSMenuItem(
                title: "\(SelectionActionBar.title(.correct))…", action: #selector(menuCorrect), keyEquivalent: "")
            item.target = self
            item.isEnabled = offers.correctEnabled
            menu.insertItem(item, at: index)
            index += 1
        }
        let note = NSMenuItem(title: "Add Note…", action: #selector(menuNote), keyEquivalent: "")
        note.target = self
        menu.insertItem(note, at: index)
        index += 1
        if menu.items.count > index { menu.insertItem(.separator(), at: index) }
        menu.autoenablesItems = false
        return menu
    }

    @objc private func menuCorrect() { menuAction(.correct) }

    @objc private func menuNote() { menuAction(.note) }

    private func menuAction(_ kind: EditingTarget.Kind) {
        guard let block = menuBlock else { return }
        if let span = menuSpan { spec?.callbacks.onSelection(block, span) }
        spec?.callbacks.onMenuAction(kind, block, menuInSelection)
        // The words are lent to this action only: a later right-click outside
        // them acts on the block under the pointer (n7 §1).
        if menuSpan != nil { spec?.callbacks.onSelection(nil, nil) }
    }

    /// Whether the last right-click landed on a selected character.
    private var menuInSelection = false
    /// The unaimed checklist words the last right-click landed in.
    private var menuSpan: SelectedSpan?

    /// The character laid out under a point, read from the layout (never
    /// through the text view's own hit-testing).
    private func character(at point: NSPoint) -> Int? {
        guard let tlm = textView.textLayoutManager else { return nil }
        let origin = textView.textContainerOrigin
        let inContainer = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        guard let fragment = tlm.textLayoutFragment(for: inContainer) else { return nil }
        let frame = fragment.layoutFragmentFrame
        let inFragment = CGPoint(x: inContainer.x - frame.minX, y: inContainer.y - frame.minY)
        guard let line = fragment.textLineFragments.first(where: { $0.typographicBounds.maxY >= inFragment.y })
            ?? fragment.textLineFragments.last
        else { return nil }
        let base = offset(fragment.rangeInElement.location)
        let inLine = CGPoint(x: inFragment.x - line.typographicBounds.minX, y: inFragment.y - line.typographicBounds.minY)
        let index = line.characterIndex(for: inLine)
        return index == NSNotFound ? nil : base + index
    }

    // MARK: Scrolling to an anchor

    /// A scroll asked for before the document has a width (the meeting just
    /// opened) waits for the first whole layout; positions before it are guesses.
    private var pendingScroll: NotesDocScrollRequest?

    private func scroll(to request: NotesDocScrollRequest) {
        guard containerWidth > 0 else {
            pendingScroll = request
            return
        }
        guard let doc = document else { return }
        let paragraph: Int?
        if request.anchorID == NotesDocumentView.userActionBoxAnchor {
            paragraph = doc.userActionTitle
        } else {
            paragraph = doc.block(request.anchorID)?.paragraph
        }
        guard let paragraph, let lines = lines(paragraph) else { return }
        let visible = scrollView.contentView.bounds
        if request.reveal {
            var bottom = lines.bottom
            if let stack = stacks[request.anchorID] { bottom += stack.leading + stack.measured }
            guard bottom + 16 > visible.maxY || lines.top < visible.minY else { return }
            let y = max(0, min(lines.top - 16, bottom + 16 - visible.height))
            scrollClip(to: min(y, textView.frame.height - visible.height), animated: request.animated)
            return
        }
        var y = request.center ? lines.top - visible.height / 2 : lines.top - 16
        y = max(0, min(y, textView.frame.height - visible.height))
        scrollClip(to: y, animated: request.animated)
        // A jump made as the meeting opens stays on its anchor while pieces
        // above it are still arriving (the rows load after the text), until
        // the reader scrolls.
        pinned = request.animated ? nil : (request, CACurrentMediaTime() + 2)
    }

    private var pinned: (request: NotesDocScrollRequest, until: CFTimeInterval)?
    private var scrollingSelf = false

    private func holdPinnedScroll() {
        guard let pin = pinned else { return }
        guard CACurrentMediaTime() < pin.until else {
            pinned = nil
            return
        }
        scroll(to: pin.request)
        pinned = pin
    }

    fileprivate func scrollClip(to y: CGFloat, animated: Bool) {
        scrollingSelf = true
        defer { scrollingSelf = false }
        let clip = scrollView.contentView
        if animated, !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                clip.animator().setBoundsOrigin(NSPoint(x: 0, y: y))
            }
        } else {
            clip.setBoundsOrigin(NSPoint(x: 0, y: y))
        }
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: Drawing: section chrome, icons and marks behind the words

    func drawDecorations(in dirty: NSRect) {
        guard let doc = document, let tlm = textView.textLayoutManager, containerWidth > 0 else { return }
        let origin = textView.textContainerOrigin
        let area = dirty.offsetBy(dx: -origin.x, dy: -origin.y)
        // The fragments on screen, top to bottom.
        var visible: [(paragraph: Int, frame: CGRect, fragment: NSTextLayoutFragment)] = []
        let startLocation = tlm.textLayoutFragment(for: CGPoint(x: 0, y: max(0, area.minY)))?.rangeInElement.location
            ?? tlm.documentRange.location
        tlm.enumerateTextLayoutFragments(from: startLocation, options: []) { fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.minY > area.maxY { return false }
            if let paragraph = doc.paragraphAt[self.offset(fragment.rangeInElement.location)] {
                visible.append((paragraph, frame, fragment))
            }
            return true
        }
        guard !visible.isEmpty else { return }

        // Section boxes: the extent of each section's lines on screen, padded;
        // an edge off screen is drawn past the dirty rect, where it is clipped.
        var extents: [Int: (top: CGFloat, bottom: CGFloat)] = [:]
        for entry in visible {
            guard let sectionIndex = doc.paragraphs[entry.paragraph].section,
                !doc.paragraphs[entry.paragraph].isTitle
            else { continue }
            let section = doc.sections[sectionIndex]
            let insets = doc.look.insets(section.kind)
            var extent = extents[sectionIndex] ?? (area.minY - 40, area.maxY + 40)
            let lines = entry.fragment.textLineFragments
            if entry.paragraph == section.firstContent, let first = lines.first {
                extent.top = entry.frame.minY + first.typographicBounds.minY - insets.top
            }
            if entry.paragraph == section.lastContent, let last = lines.last {
                extent.bottom = entry.frame.minY + last.typographicBounds.maxY + insets.bottom
                    + openSpace(afterParagraph: entry.paragraph)
            }
            extents[sectionIndex] = extent
        }
        // A glowing user box is drawn whole whenever its glow meets the dirty
        // rect, so the glow never breaks at a tile's edge.
        if doc.look.userBox == .glass || doc.look.userBox == .panel,
            let index = doc.sections.firstIndex(where: { $0.kind == .userActions }),
            let rect = sectionRect(doc.sections[index])
        {
            extents[index] = nil
            if rect.insetBy(dx: -NotesDocChrome.glowReach, dy: -NotesDocChrome.glowReach).intersects(dirty) {
                NotesDocChrome.drawSection(doc.look, kind: .userActions, rect: rect)
            }
        }
        for (sectionIndex, extent) in extents {
            let rect = NSRect(x: origin.x, y: origin.y + extent.top, width: boxWidth, height: extent.bottom - extent.top)
            NotesDocChrome.drawSection(doc.look, kind: doc.sections[sectionIndex].kind, rect: rect)
        }

        // Thematic-break dividers and code-block plates.
        for entry in visible {
            let paragraph = doc.paragraphs[entry.paragraph]
            let insets = doc.insets(ofParagraph: entry.paragraph)
            let inner = (minX: origin.x + insets.leading, maxX: origin.x + containerWidth - insets.trailing)
            if paragraph.isRule {
                let y = (origin.y + entry.frame.minY).rounded(.down) + 0.5
                let line = NSBezierPath()
                line.move(to: NSPoint(x: inner.minX, y: y))
                line.line(to: NSPoint(x: inner.maxX, y: y))
                line.lineWidth = 1
                NSColor.separatorColor.setStroke()
                line.stroke()
            } else if paragraph.isCode, let first = entry.fragment.textLineFragments.first,
                let last = entry.fragment.textLineFragments.last
            {
                let top = origin.y + entry.frame.minY + first.typographicBounds.minY - NotesDocStyle.codePadding
                let bottom = origin.y + entry.frame.minY + last.typographicBounds.maxY + NotesDocStyle.codePadding
                let plate = NSRect(x: inner.minX, y: top, width: inner.maxX - inner.minX, height: bottom - top)
                // Today's `.quaternary.opacity(0.4)`: dark aqua's quaternary ink is white at 10%.
                NotesDocStyle.ink(0.10 * 0.4).setFill()
                NSBezierPath(roundedRect: plate, xRadius: 6, yRadius: 6).fill()
            }
        }

        // Title chips and decision seals.
        for entry in visible {
            let paragraph = doc.paragraphs[entry.paragraph]
            guard paragraph.isTitle || paragraph.hasSeal, let line = entry.fragment.textLineFragments.first
            else { continue }
            let lineRect = line.typographicBounds.offsetBy(dx: entry.frame.minX + origin.x, dy: entry.frame.minY + origin.y)
            if paragraph.isTitle, doc.look.heading != .chip {
                NotesDocChrome.drawHeading(
                    doc.look, line: lineRect, textWidth: line.typographicBounds.width, left: origin.x,
                    width: containerWidth)
            } else if paragraph.isTitle, let sectionIndex = paragraph.section {
                let kind = doc.sections[sectionIndex].kind
                let chip = NSRect(
                    x: origin.x, y: lineRect.midY - NotesDocStyle.chipSize / 2,
                    width: NotesDocStyle.chipSize, height: NotesDocStyle.chipSize)
                NSColor(Design.sectionTint(kind).opacity(0.85)).setFill()
                NSBezierPath(roundedRect: chip, xRadius: 6, yRadius: 6).fill()
                drawSymbol(Design.sectionIcon(kind), size: 10, weight: .semibold, color: NSColor(white: 1, alpha: 0.92), centeredIn: chip)
            } else {
                let leading = doc.insets(ofParagraph: entry.paragraph).leading
                let box = NSRect(x: origin.x + leading, y: lineRect.minY, width: 12, height: lineRect.height)
                drawSymbol("checkmark.seal.fill", size: 11, weight: .regular, color: NSColor(Design.support), centeredIn: box)
            }
        }

        // The hovered block's timecode mark, in the left inset.
        if let anchor = hoveredBlock, timecodePlayback(anchor) != nil, let rect = timecodeRect(anchor),
            rect.intersects(dirty)
        {
            let playing = spec?.timecodes?.playing == anchor
            drawSymbol(
                playing ? "pause.circle.fill" : "play.circle", size: 12, weight: .regular,
                color: playing ? NSColor(Design.accent) : NotesDocStyle.ink(NotesDocStyle.tertiary),
                centeredIn: rect)
        }

        // Marks: today's rounded, side-bled fill behind the exact words; a
        // whole block wears one rounded rectangle behind all of its lines.
        let now = CACurrentMediaTime()
        let marks = resolvedMarks.map { ($0, CGFloat(1)) }
            + fadingMarks.map { entry in
                let t = min(1, (now - entry.start) / 0.3)
                return (entry.mark, CGFloat(1 - (1 - (1 - t) * (1 - t))))
            }
        guard !marks.isEmpty, let first = visible.first, let last = visible.last else { return }
        let visibleStart = doc.paragraphs[first.paragraph].range.location
        let visibleEnd = NSMaxRange(doc.paragraphs[last.paragraph].range)
        for (mark, fade) in marks {
            NSColor(Design.accent.opacity(AnchorWash.composing.fill * (mark.emphasized ? 1.6 : 1) * fade)).setFill()
            if let anchor = mark.block {
                guard let block = doc.block(anchor), let lines = lines(block.paragraph) else { continue }
                let rect = NSRect(
                    x: origin.x + block.indent - 4, y: lines.top,
                    width: containerWidth - trailing(block) - block.indent + 8,
                    height: blockBottom(block, lines: lines) - lines.top)
                let radius = min(NotesEditingLayout.markRadius, rect.height / 2)
                NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
                continue
            }
            for rect in markRects(mark.range, visible: NSRange(location: visibleStart, length: visibleEnd - visibleStart)) {
                let radius = min(NotesEditingLayout.markRadius, rect.height / 2)
                NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            }
        }
    }

    private struct RectKey: Hashable {
        var x, y, width, height: CGFloat
    }

    /// The rounded pieces a span mark is drawn as: one per line segment of the
    /// part of the span inside the paragraphs on screen, each once.
    func markRects(_ range: NSRange, visible: NSRange) -> [NSRect] {
        let shown = NSIntersectionRange(range, visible)
        guard shown.length > 0, let tlm = textView.textLayoutManager, let start = location(shown.location),
            let end = location(NSMaxRange(shown)), let textRange = NSTextRange(location: start, end: end)
        else { return [] }
        let origin = textView.textContainerOrigin
        var seen: Set<RectKey> = []
        var rects: [NSRect] = []
        tlm.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, segment, _, _ in
            let rect = segment.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -4, dy: 1)
            if seen.insert(RectKey(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)).inserted {
                rects.append(rect)
            }
            return true
        }
        return rects
    }

    /// The space currently open under a paragraph's block, if any (the
    /// "Completed (n)" row's own reach below its label, when it ends a box).
    private func openSpace(afterParagraph paragraph: Int) -> CGFloat {
        guard let doc = document else { return 0 }
        if paragraph == doc.completedDisclosure { return NotesDocStyle.disclosureBelow }
        guard let anchor = doc.blocks.first(where: { $0.paragraph == paragraph })?.anchorID else { return 0 }
        return gap(stacks[anchor])
    }

    private func drawSymbol(_ name: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, centeredIn rect: NSRect) {
        // Tinted as one colour over the template, so a symbol's cut-outs (the
        // seal's check) stay open — how SwiftUI draws a filled symbol in one
        // foreground style.
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        guard let template = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        else { return }
        let image = NSImage(size: template.size, flipped: false) { rect in
            template.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let imageSize = image.size
        let target = NSRect(
            x: rect.midX - imageSize.width / 2, y: rect.midY - imageSize.height / 2,
            width: imageSize.width, height: imageSize.height)
        image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

// MARK: - Fluido motion

/// An un-ticked row caught before the document changed: its text, the pictures
/// of the lines it takes out of the box ("All done." when no item was open, the
/// Completed line when no done item is left, its done row in an expanded
/// Completed list), and where what followed them stood; in an expanded
/// Completed list, what followed its done row (the next done item, or nil for
/// what comes after the box) and where it stood.
struct NotesDocReopen {
    var text: String
    var departing: [(image: NSImage, frame: NSRect)] = []
    var followerTop: CGFloat?
    var rowFollower: (item: String?, top: CGFloat)?
}

/// A completed row caught before the document changed.
struct NotesDocCompletion {
    enum Follower { case item(String), completed }
    var leaving: [(image: NSImage, frame: NSRect)] = []
    /// What stood right under the row, and where its top was.
    var follower: Follower?
    var followerTop: CGFloat = 0
    var lastOpenDone = false
}

private final class NotesDocPassThroughHost: NSHostingView<AnyView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The shine's band, drawn only where the pictured notes (or a card) are.
final class NotesDocShineView: NSView {
    /// Where the notes are: their pictured pixels and the cards.
    var coverage: NSImage?
    /// The notes' rect when they were pictured.
    var content: CGRect = .zero
    var band: (start: CGPoint, end: CGPoint, alphas: [CGFloat])?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let band, let context = NSGraphicsContext.current?.cgContext,
            let gradient = CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                colors: band.alphas.map { NSColor(white: 1, alpha: $0).cgColor } as CFArray, locations: nil)
        else { return }
        // The band, then kept only where the notes are.
        context.drawLinearGradient(gradient, start: band.start, end: band.end, options: [])
        coverage?.draw(in: bounds, from: .zero, operation: .destinationIn, fraction: 1, respectFlipped: true, hints: nil)
    }
}

extension NotesDocController {
    /// Before a tick replaces the document: each completed row's picture and
    /// the top of what stood under it, from the layout still on screen.
    fileprivate func prepareCompletion(to new: NotesDocument) -> NotesDocCompletion? {
        guard let old = document, new.look.direction == .fluido, !reduceMotion, containerWidth > 0 else { return nil }
        let done = NotesDocMotion.completed(from: old, to: new)
        guard !done.isEmpty else { return nil }
        var completion = NotesDocCompletion()
        completion.lastOpenDone = old.toggles.contains { !$0.done } && !new.toggles.contains { !$0.done }
        let origin = textView.textContainerOrigin
        let left = origin.x + old.look.userContent.leading - 2
        let right = origin.x + containerWidth - old.look.userContent.trailing
        for text in done {
            guard let toggle = old.toggles.first(where: { !$0.done && $0.item.text == text }),
                let row = lines(toggle.paragraph)
            else { continue }
            // The row and whatever stood under it (its note cards, rows).
            let bottom = (lines(toggle.paragraph + 1)?.top ?? row.bottom + NotesDocStyle.blockGap) - 2
            let frame = NSRect(x: left, y: row.top - 2, width: right - left, height: bottom - row.top + 2).integral
            if let rep = textView.bitmapImageRepForCachingDisplay(in: frame) {
                textView.cacheDisplay(in: frame, to: rep)
                let image = NSImage(size: frame.size)
                image.addRepresentation(rep)
                completion.leaving.append((image, frame))
            }
            // One row at a time slides what stood under it up.
            guard done.count == 1, let under = lines(toggle.paragraph + 1) else { continue }
            if let next = old.toggles.first(where: { !$0.done && $0.paragraph == toggle.paragraph + 1 }) {
                completion.follower = .item(next.item.text)
            } else if old.completedDisclosure == toggle.paragraph + 1 {
                completion.follower = .completed
            }
            completion.followerTop = under.top
        }
        return completion
    }

    /// A new document ends the motion laid on the old one: the paragraphs it
    /// holds open or fades in, and the pictures of rows that left, belong to
    /// the old text.
    fileprivate func endDocumentMotion() {
        motion.settleHolds = [:]
        motion.fadingIn = nil
        motion.leaving.forEach { $0.view.removeFromSuperview() }
        motion.leaving = []
        if let opening = motion.opening {
            motion.opening = nil
            stacks[opening.anchor]?.clip.alphaValue = 1
            stacks[opening.anchor]?.rail?.alphaValue = 1
        }
        motion.arriving?.view.removeFromSuperview()
        motion.arriving = nil
        motion.departing.forEach { $0.removeFromSuperview() }
        motion.departing = []
        endShine()
    }

    /// Before an un-tick replaces the document: the item that comes back (one
    /// at a time, as the toggle makes it), the pictures of the lines it takes
    /// out of the box, and the top of what followed them.
    fileprivate func prepareReopen(to new: NotesDocument) -> NotesDocReopen? {
        guard let old = document, new.look.direction == .fluido, !reduceMotion, containerWidth > 0 else { return nil }
        let reopened = NotesDocMotion.reopened(from: old, to: new)
        guard reopened.count == 1 else { return nil }
        var reopen = NotesDocReopen(text: reopened[0])
        // "All done." leaves when no item was open; the Completed line when no
        // done item is left. When both leave they stand together.
        let allDone = !old.toggles.contains(where: { !$0.done })
        let completedGoes = old.completedDisclosure != nil && new.completedDisclosure == nil
        guard let box = old.sections.first(where: { $0.kind == .userActions }) else { return reopen }
        let origin = textView.textContainerOrigin
        let left = origin.x + old.look.userContent.leading - 2
        let right = origin.x + containerWidth - old.look.userContent.trailing
        func picture(_ top: CGFloat, _ bottom: CGFloat) {
            let frame = NSRect(x: left, y: top - 2, width: right - left, height: bottom - top + 4).integral
            guard let rep = textView.bitmapImageRepForCachingDisplay(in: frame) else { return }
            textView.cacheDisplay(in: frame, to: rep)
            let image = NSImage(size: frame.size)
            image.addRepresentation(rep)
            reopen.departing.append((image, frame))
        }
        // An expanded Completed list loses the item's done row too (when the
        // Completed line goes, the row is in the run pictured below).
        if !completedGoes, let row = old.toggles.first(where: { $0.done && $0.item.text == reopen.text }),
            row.paragraph + 1 < old.paragraphs.count, let top = lines(row.paragraph + 1)?.top,
            let rowLines = lines(row.paragraph)
        {
            let next = old.toggles.first { $0.done && $0.paragraph == row.paragraph + 1 }
            reopen.rowFollower = (next?.item.text, top)
            picture(rowLines.top, rowLines.bottom)
        }
        guard let firstGone = allDone ? box.firstContent : completedGoes ? old.completedDisclosure : nil,
            let first = lines(firstGone), let last = lines(completedGoes ? box.lastContent : firstGone)
        else { return reopen }
        picture(first.top, last.bottom)
        // What followed them: the Completed line when it stays, else what
        // comes after the box.
        if let follower = new.completedDisclosure != nil ? old.completedDisclosure : box.lastContent + 1,
            follower < old.paragraphs.count
        {
            reopen.followerTop = lines(follower)?.top
        }
        return reopen
    }

    /// Today's `.transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .leading)))`
    /// on the box's spring, for a row coming back: its picture (words, circle
    /// and what stands under it) fades and grows in while its space opens from
    /// nothing, the rows under it sliding down; "All done.", a Completed line
    /// that goes and an expanded list's done row fade out on the same spring
    /// (today's `.transition(.opacity)`, which the done row has by default), their
    /// space closing on it as the box's does today.
    fileprivate func startReopen(_ reopen: NotesDocReopen) {
        guard let doc = document, let storage = textView.textStorage,
            let index = doc.toggles.firstIndex(where: { !$0.done && $0.item.text == reopen.text }),
            let block = doc.blocks.first(where: { $0.paragraph == doc.toggles[index].paragraph }),
            let row = lines(block.paragraph), let lineCount = fragment(block.paragraph)?.textLineFragments.count,
            lineCount > 0
        else { return }
        let origin = textView.textContainerOrigin
        let left = origin.x + doc.look.userContent.leading - 2
        let right = origin.x + containerWidth - doc.look.userContent.trailing
        let bottom = (lines(block.paragraph + 1)?.top ?? row.bottom + NotesDocStyle.blockGap) - 2
        let frame = NSRect(x: left, y: row.top - 2, width: right - left, height: bottom - row.top + 2).integral
        guard let rep = textView.bitmapImageRepForCachingDisplay(in: frame) else { return }
        textView.cacheDisplay(in: frame, to: rep)
        let image = NSImage(size: frame.size)
        image.addRepresentation(rep)
        let view = NSImageView(frame: frame)
        view.image = image
        view.imageScaling = .scaleAxesIndependently
        view.alphaValue = 0
        overlay.addSubview(view)
        motion.arriving = (view, frame)
        for (image, frame) in reopen.departing {
            let view = NSImageView(frame: frame)
            view.image = image
            view.imageScaling = .scaleAxesIndependently
            overlay.addSubview(view)
            motion.departing.append(view)
        }
        // The row itself stays out of sight until it lands.
        let range = doc.paragraphs[block.paragraph].range
        storage.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
        if index < toggleViews.count { toggleViews[index].alphaValue = 0 }
        motion.opening = (block.paragraph, block.anchorID, (row.bottom - row.top) / CGFloat(lineCount), 0)
        motion.openingStart = CACurrentMediaTime()
        applyGapNow(block.anchorID)
        relayout()
        // The lines that left keep their space, held over the paragraph now
        // above what followed them, and give it up on the row's spring: those
        // above the Completed line first, then the done row under it.
        if let box = doc.sections.first(where: { $0.kind == .userActions }) {
            let after = box.lastContent + 1
            let rowFollower = reopen.rowFollower.map { follower in
                follower.item.flatMap { item in doc.toggles.first { $0.done && $0.item.text == item }?.paragraph } ?? after
            }
            let holds = [(reopen.followerTop, doc.completedDisclosure ?? after), (reopen.rowFollower?.top, rowFollower)]
            for case let (top?, follower?) in holds where follower < doc.paragraphs.count {
                guard let now = lines(follower), top - now.top > 0.5 else { continue }
                motion.settleHolds[follower - 1] = top - now.top
                motion.settleLeft = 1
                motion.settleStart = motion.openingStart
                applySettle()
                relayout()
            }
        }
        startMotion()
    }

    /// The arriving row lands: its own words, circle and pieces again.
    private func endReopen() {
        guard let doc = document, let opening = motion.opening else { return }
        motion.opening = nil
        motion.arriving?.view.removeFromSuperview()
        motion.arriving = nil
        motion.departing.forEach { $0.removeFromSuperview() }
        motion.departing = []
        let range = doc.paragraphs[opening.paragraph].range
        if let storage = textView.textStorage, NSMaxRange(range) <= storage.length {
            doc.text.enumerateAttribute(.foregroundColor, in: range) { value, run, _ in
                if let value { storage.addAttribute(.foregroundColor, value: value, range: run) }
            }
        }
        if let index = doc.toggles.firstIndex(where: { $0.paragraph == opening.paragraph }), index < toggleViews.count {
            toggleViews[index].alphaValue = 1
        }
        applyGapNow(opening.anchor)
    }

    /// After the new document is laid out: the space the row left stays open
    /// and closes on the settle spring while the row fades and shrinks away;
    /// the last open item fires the burst.
    fileprivate func startCompletion(_ completion: NotesDocCompletion) {
        guard let doc = document else { return }
        let follower: Int?
        switch completion.follower {
        case .item(let text): follower = doc.toggles.first { !$0.done && $0.item.text == text }?.paragraph
        case .completed: follower = doc.completedDisclosure
        case nil: follower = nil
        }
        if let follower, follower > 0, let now = lines(follower) {
            let gap = completion.followerTop - now.top
            if gap > 0.5 {
                motion.settleHolds = [follower - 1: gap]
                motion.settleLeft = 1
                applySettle()
            }
        }
        for (image, frame) in completion.leaving {
            let view = NSImageView(frame: frame)
            view.image = image
            view.imageScaling = .scaleAxesIndependently
            overlay.addSubview(view)
            motion.leaving.append((view, frame))
        }
        if completion.lastOpenDone, let box = doc.sections.first(where: { $0.kind == .userActions }) {
            // "All done." comes in on the same spring (today's `.transition(.opacity)`).
            motion.fadingIn = box.firstContent
            fadeIn(0)
        }
        motion.settleStart = CACurrentMediaTime()
        relayout()
        if completion.lastOpenDone { startBurst() }
        startMotion()
    }

    /// The settle space, on the paragraphs that hold it.
    private func applySettle() {
        guard let doc = document else { return }
        for paragraphIndex in motion.settleHolds.keys {
            if let block = doc.blocks.first(where: { $0.paragraph == paragraphIndex }) {
                applyGapNow(block.anchorID)
                continue
            }
            let paragraph = doc.paragraphs[paragraphIndex]
            guard let storage = textView.textStorage, NSMaxRange(paragraph.range) <= storage.length else { continue }
            let style = paragraph.style.mutableCopy() as! NSMutableParagraphStyle
            style.paragraphSpacing = max(0, paragraph.style.paragraphSpacing + motion.settle(paragraphIndex))
            storage.addAttribute(.paragraphStyle, value: style, range: paragraph.range)
        }
    }

    private func fadeIn(_ progress: CGFloat) {
        guard let doc = document, let paragraph = motion.fadingIn, let storage = textView.textStorage else { return }
        let range = doc.paragraphs[paragraph].range
        guard NSMaxRange(range) <= storage.length else { return }
        storage.addAttribute(
            .foregroundColor, value: NotesDocStyle.ink(NotesDocStyle.secondary * max(0, min(1, progress))), range: range)
    }

    /// Today's `FluidoUserActionCelebration`: one sparkle burst over the box.
    private func startBurst() {
        guard let doc = document, let section = doc.sections.first(where: { $0.kind == .userActions }),
            let box = sectionRect(section)
        else { return }
        motion.burst?.removeFromSuperview()
        let view = NotesDocPassThroughHost(
            rootView: AnyView(FluidoSparkleBurst(start: Date()).accessibilityHidden(true)))
        view.frame = box.insetBy(dx: -46, dy: -46)
        overlay.addSubview(view)
        motion.burst = view
        DispatchQueue.main.asyncAfter(deadline: .now() + FluidoSparkleBurst.duration + 0.2) { [weak self, weak view] in
            view?.removeFromSuperview()
            if let self, self.motion.burst === view { self.motion.burst = nil }
        }
    }

    fileprivate func noteShine(_ tick: Int) {
        guard tick != motion.lastShineTick else { return }
        motion.lastShineTick = tick
        guard document?.look.direction == .fluido, !reduceMotion else { return }
        motion.shineStart = CACurrentMediaTime()
        startMotion()
    }

    /// Pow's shine over the notes, as today's `sourceAtop` sweep: a white band
    /// lighting only the notes' own pixels — the section cards and the user
    /// panel, and every title, word, circle and card drawn over them — never
    /// the page between them. The pixels are pictured once per sweep (and per
    /// document, and again whenever the notes move or reflow), over the part of
    /// the notes on screen. A scroll alone ends the sweep: re-picturing the
    /// viewport on every scroll frame would cost the scroll its smoothness.
    fileprivate func drawShineFrame(_ start: CFTimeInterval) {
        guard let doc = document, containerWidth > 0, let first = doc.sections.first, let last = doc.sections.last,
            let top = lines(first.title)?.top, let bottom = sectionRect(last)?.maxY
        else { return }
        let origin = textView.textContainerOrigin
        let content = CGRect(x: origin.x, y: top, width: boxWidth, height: bottom - top)
        let region = content.intersection(textView.visibleRect).integral
        if let view = motion.shineView {
            if view.content != content {
                endShine()
            } else if view.frame != region {
                motion.shineStart = nil
                endShine()
                return
            }
        }
        if motion.shineView == nil {
            guard !region.isEmpty, let rep = textView.bitmapImageRepForCachingDisplay(in: region) else { return }
            textView.cacheDisplay(in: region, to: rep)
            // The cards join the pictured pixels (the bitmap's space is unflipped).
            if doc.look.chrome == .card, let context = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                NSColor.white.setFill()
                for section in doc.sections {
                    guard let rect = sectionRect(section) else { continue }
                    let radius = section.kind == .userActions ? doc.look.userRadius : doc.look.radius
                    let local = NSRect(
                        x: rect.minX - region.minX, y: region.maxY - rect.maxY, width: rect.width, height: rect.height)
                    NSBezierPath(roundedRect: local, xRadius: radius, yRadius: radius).fill()
                }
                NSGraphicsContext.restoreGraphicsState()
            }
            let coverage = NSImage(size: region.size)
            coverage.addRepresentation(rep)
            let view = NotesDocShineView(frame: region)
            view.coverage = coverage
            view.content = content
            overlay.addSubview(view)
            motion.shineView = view
        }
        guard let view = motion.shineView else { return }
        let fraction = NotesDocMotion.easeInOut((CACurrentMediaTime() - start) / NotesDocMotion.shineDuration)
        let shine = NotesDocMotion.shine(over: content, fraction: fraction)
        view.band = (
            CGPoint(x: shine.start.x - view.frame.minX, y: shine.start.y - view.frame.minY),
            CGPoint(x: shine.end.x - view.frame.minX, y: shine.end.y - view.frame.minY), shine.alphas)
        view.needsDisplay = true
    }

    private func endShine() {
        motion.shineView?.removeFromSuperview()
        motion.shineView = nil
    }

    private func startMotion() {
        guard motion.link == nil else { return }
        let link = textView.displayLink(target: self, selector: #selector(motionTick(_:)))
        link.add(to: .main, forMode: .common)
        motion.link = link
    }

    @objc private func motionTick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        var running = false
        if !motion.settleHolds.isEmpty || !motion.leaving.isEmpty || motion.fadingIn != nil {
            let elapsed = now - motion.settleStart
            let finished = elapsed >= Self.settleDuration
            let progress = finished
                ? 1 : CGFloat(NotesDocMotion.settle.value(target: 1.0, initialVelocity: 0, time: elapsed))
            textView.textStorage?.beginEditing()
            if !motion.settleHolds.isEmpty {
                motion.settleLeft = 1 - progress
                applySettle()
                if finished { motion.settleHolds = [:] }
            }
            fadeIn(progress)
            if finished { motion.fadingIn = nil }
            textView.textStorage?.endEditing()
            // Today's `.opacity.combined(with: .scale(scale: 0.97, anchor: .leading))`.
            let scale = 1 - 0.03 * progress
            for (view, frame) in motion.leaving {
                view.alphaValue = max(0, min(1, 1 - progress))
                view.frame = NSRect(
                    x: frame.minX, y: frame.midY - frame.height * scale / 2, width: frame.width * scale,
                    height: frame.height * scale)
            }
            if finished {
                motion.leaving.forEach { $0.view.removeFromSuperview() }
                motion.leaving = []
            }
            running = !finished
            // A space held for an arriving row is laid out once, with the row, below.
            if motion.opening == nil { relayout() }
        }
        if motion.opening != nil {
            let elapsed = now - motion.openingStart
            let finished = elapsed >= Self.settleDuration
            let progress = finished
                ? 1 : CGFloat(NotesDocMotion.settle.value(target: 1.0, initialVelocity: 0, time: elapsed))
            if finished {
                endReopen()
            } else {
                motion.opening?.fraction = progress
                if let anchor = motion.opening?.anchor { applyGapNow(anchor) }
                if let (view, frame) = motion.arriving {
                    let scale = 0.97 + 0.03 * progress
                    view.alphaValue = max(0, min(1, progress))
                    view.frame = NSRect(
                        x: frame.minX, y: frame.midY - frame.height * scale / 2, width: frame.width * scale,
                        height: frame.height * scale)
                }
                motion.departing.forEach { $0.alphaValue = max(0, min(1, 1 - progress)) }
                running = true
            }
            relayout()
        }
        if let start = motion.shineStart {
            if now - start >= NotesDocMotion.shineDuration {
                motion.shineStart = nil
                endShine()
            } else {
                drawShineFrame(start)
                running = true
            }
        }
        if !running {
            link.invalidate()
            motion.link = nil
        }
    }

    static let settleDuration = NotesDocMotion.settle.settlingDuration(target: 1.0, initialVelocity: 0, epsilon: 0.001)
}

// MARK: - Hosted pieces

/// The user-action item's done toggle, placed beside its line.
struct NotesDocDoneToggle: View {
    var done: Bool
    var text: String
    var action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13))
                .foregroundStyle(done ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.accent))
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(done ? "Mark not done: \(text)" : "Mark done: \(text)")
        .help(done ? "Mark as not done" : "Mark as done")
    }
}

/// The chevron of the user-action box's "Completed (n)" disclosure.
struct NotesDocDisclosureChevron: View {
    var expanded: Bool
    var label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
    }
}

/// Lays a placed piece out at its own height for the width it is given (the
/// proposal the space under a block is measured with), top-aligned, whatever
/// height its frame has while that space opens or closes.
private struct NotesDocNaturalHeight: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: .infinity))
        return CGSize(width: proposal.width ?? size.width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: .infinity))
    }
}
