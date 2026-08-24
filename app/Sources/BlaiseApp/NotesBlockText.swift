import AppKit
import BlaiseCore
import SwiftUI

// The notes pane's text host. It renders exactly what the search-highlighted
// presentation produces; on macOS 26 it additionally REPORTS the range the user
// selected, which is what the selection capsule is anchored to. Selection is
// within-block by construction: each block is its own host, so a drag can never
// cross into another block.

struct NotesBlockText: View {
    let source: AttributedString
    let terms: [String]
    /// Whether this block may host a selection. Off for hosts where a selection
    /// has no editing meaning (table cells, headers) and pre-macOS 26.
    var selectable = false
    /// The passage this block's annotations stand on, when they stand on less
    /// than the whole block. The plain host carries it as a text attribute; the
    /// selection host is handed the span and paints it.
    var washedSpan: SelectedSpan?
    /// How many margin notes stand on this passage. The wash that shows them is
    /// colour on the glyphs and reaches nobody who cannot see it, so the count
    /// travels with the text.
    var annotations = 0
    /// The selected span and where it sits inside the block, or nil when the
    /// selection is empty/collapsed.
    var onSelectionChange: ((SelectedSpan?, SelectionFrame?) -> Void)?

    var body: some View {
        if selectable, #available(macOS 26.0, *) {
            // The selection host is handed the mark as a SPAN, never as a text
            // attribute: an attribute background reaches AppKit's text storage
            // and is painted only while the text view is editable, and this one
            // is not.
            SelectableBlockText(
                display: Self.displayText(source: source, terms: terms),
                mark: washedSpan,
                onSelectionChange: onSelectionChange ?? { _, _ in })
                .accessibilityHint(hint)
        } else {
            Text(Self.displayText(source: source, terms: terms, washedSpan: washedSpan))
                .accessibilityHint(hint)
        }
    }

    private var hint: String {
        Self.hint(source: source, terms: terms, annotations: annotations)
    }

    /// The presentation model both hosts render: the source with the search
    /// cues layered on, and the composing wash over the targeted span when the
    /// instruction targets one. The rendered-output check is the operator
    /// gate's; this is the model both hosts are handed.
    @MainActor
    static func displayText(
        source: AttributedString, terms: [String], washedSpan: SelectedSpan? = nil
    ) -> AttributedString {
        let highlighted = SearchHighlight.applied(to: source, terms: terms)
        guard let washedSpan else { return highlighted }
        return AnchorWash.composingSpan(in: highlighted, span: washedSpan)
    }

    static func searchHint(source: AttributedString, terms: [String]) -> String {
        SearchTextMatcher.contains(String(source.characters), terms: terms)
            ? "Contains the current search match" : ""
    }

    /// What the passage carries beyond its words: the search state, and how
    /// many margin notes stand on it. Both are cues a sighted reader takes
    /// from colour on the glyphs, so both are said in words here.
    static func annotationHint(_ count: Int) -> String {
        switch count {
        case ..<1: return ""
        case 1: return "Has 1 margin note"
        default: return "Has \(count) margin notes"
        }
    }

    static func hint(source: AttributedString, terms: [String], annotations: Int) -> String {
        [annotationHint(annotations), searchHint(source: source, terms: terms)]
            .filter { !$0.isEmpty }
            .joined(separator: ". ")
    }
}

/// The macOS 26 selection-capable host. SwiftUI reports a selection over rich
/// text from exactly one view — the attributed `TextEditor` — and that view is
/// an editor, so the block is an editor with editing taken away underneath:
/// `NotesProseHost` clears `isEditable`, which draws no insertion point and
/// refuses the keystroke at the source. Corrections are rewrites the model
/// performs; the prose is never typed into.
///
/// A text view that is not editable also stops driving SwiftUI's own selection
/// binding — measured, not assumed — so the binding is not asked for, and both
/// the span and where it sits on the page are read from the text view itself.
@available(macOS 26.0, *)
private struct SelectableBlockText: View {
    let display: AttributedString
    let mark: SelectedSpan?
    let onSelectionChange: (SelectedSpan?, SelectionFrame?) -> Void

    /// `NSTextContainer.lineFragmentPadding`, which the editor keeps at its
    /// default on both ends. Left alone, the prose sits off the column every
    /// plain block shares and wraps this much before the width it was measured
    /// at, which costs the last line. Cancelled by a negative inset, so the
    /// text view's own origin sits this far left of the block's.
    private static let hostInset: CGFloat = 5

    var body: some View {
        ProseHeight {
            // The ruler: the same prose in the plain host, measured by the same
            // layout pass that sizes the editor. It draws nothing.
            Text(display).hidden()
            // The editor owns its text storage once it exists: a changed
            // `display` is never re-read from the binding, so a block rewritten
            // under the reader (an editor apply, a name correction) would keep
            // showing the old prose until the pane was rebuilt. Identity keyed
            // on the prose is what makes the new text land. The selection goes
            // with it, which is correct — it stood on words that no longer
            // exist.
            //
            // The identity is applied LAST, around the plate and the bridge as
            // well as the editor: a fresh text view arrives editable, in the
            // light appearance and reporting nothing, and it is the plate that
            // takes those away again. Re-created together, the plate claims the
            // new view through its own first layout; re-created alone, the old
            // plate has to notice the swap by frame, and until it does the
            // prose carries a caret.
            TextEditor(text: .constant(display))
            .textEditorStyle(.plain)
            .scrollDisabled(true)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, -Self.hostInset)
            .background { BlockTextHostBridge(mark: mark, onSelectionChange: onSelectionChange) }
            .overlay { BlockContextMenuPlate() }
            .id(display)
        }
    }
}

/// Sizes a block by its prose, not by the editor hosting it. The editor's own
/// ideal height is the height its text occupied in the PREVIOUS layout pass, so
/// a block laid out at a width it has not been measured at yet reports the
/// wrong number of lines and the rest are never allotted space. Here the first
/// subview — the plain text host, which wraps correctly — is measured at the
/// width this layout is actually proposed, in the same pass, and that height is
/// what the editor is placed at.
private struct ProseHeight: Layout {
    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        let ruler = subviews[0].sizeThatFits(proposal)
        return CGSize(width: proposal.width ?? ruler.width, height: ruler.height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let size = ProposedViewSize(width: bounds.width, height: bounds.height)
        for subview in subviews {
            subview.place(at: CGPoint(x: bounds.minX, y: bounds.minY), anchor: .topLeading, proposal: size)
        }
    }

    /// The block's vertical guides are the ruler's. A custom layout reports no
    /// baseline of its own unless it says so, and a silent layout's first
    /// baseline is its frame top — so anything aligned on this block, a list
    /// marker above all, would sit a whole ascent above the words it marks.
    /// The ruler is the plain host laid out over the same prose at the same
    /// proposal, which is exactly where the editor draws it.
    func explicitAlignment(
        of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
        subviews: Subviews, cache: inout ()
    ) -> CGFloat? {
        let size = ProposedViewSize(width: bounds.width, height: bounds.height)
        return bounds.minY + subviews[0].dimensions(in: size)[guide]
    }
}

/// What the prose host is, once the text system has built it: a passage that
/// can be selected and cannot be written to. `isSelectable` is deliberately
/// left alone — a text view that is not editable still selects and drags, which
/// is the whole reason this host is an editor at all.
@MainActor
enum NotesProseHost {
    static func configure(_ textView: NSTextView) {
        // The host otherwise runs in the LIGHT system appearance inside a dark
        // pane, so every fill the text system draws itself resolves pale.
        textView.appearance = NSAppearance(named: .darkAqua)
        textView.isEditable = false
        textView.isSelectable = true
        // The ink the host already draws prose in is deliberately NOT written
        // into the selection attributes: a semantic colour written there
        // resolves in the host's light appearance and the selected words go
        // black. Only the fill is replaced.
        textView.selectedTextAttributes[.backgroundColor] = BlockSelection.fill
    }

    /// The text view a plate is laid out over. A plate is the editor's own
    /// background or its own overlay, so the two stand on the same centre —
    /// which is what identifies it; their widths differ by the inset that
    /// cancels the text container's padding. The search starts at the window
    /// because SwiftUI does not host every block's editor under the same
    /// platform node, and it is pinned to the centre because the pane's other
    /// text views must be left alone: the composer's is genuinely editable and
    /// taking that away leaves no way to write a correction.
    static func textView(under plate: NSView) -> NSTextView? {
        guard let root = plate.window?.contentView else { return nil }
        var hosts: [NSTextView] = []
        collect(in: root, into: &hosts)
        return hosts.first { concentric($0, with: plate) }
    }

    /// The two views stand on the same point of the window, to within the
    /// rounding a layout pass leaves behind.
    private static func concentric(_ textView: NSTextView, with plate: NSView) -> Bool {
        guard textView.window === plate.window else { return false }
        let mine = plate.convert(plate.bounds, to: nil)
        let theirs = textView.convert(textView.bounds, to: nil)
        return abs(mine.midX - theirs.midX) < tolerance && abs(mine.midY - theirs.midY) < tolerance
    }

    private static let tolerance: CGFloat = 2

    private static func collect(in view: NSView, into hosts: inout [NSTextView]) {
        if let textView = view as? NSTextView { hosts.append(textView) }
        for subview in view.subviews { collect(in: subview, into: &hosts) }
    }

    /// Where a marked passage sits in the block's own characters. A block can
    /// repeat the same words, so the span names WHICH of its equals is marked;
    /// an occurrence the text no longer has falls back to its last one, the
    /// same choice the anchor resolver makes when a rewrite collapses
    /// duplicates. Text the block no longer contains marks nothing rather than
    /// guessing.
    static func markRange(of mark: SelectedSpan, in text: String) -> NSRange? {
        guard !mark.text.isEmpty else { return nil }
        var found: [Range<String.Index>] = []
        var cursor = text.startIndex
        while let next = text.range(of: mark.text, range: cursor..<text.endIndex) {
            found.append(next)
            cursor = text.index(after: next.lowerBound)
        }
        guard let hit = found.indices.contains(mark.occurrence) ? found[mark.occurrence] : found.last
        else { return nil }
        return NSRange(hit, in: text)
    }

    /// The selected span — its text and which occurrence of that text inside
    /// the block it is — or nil for an insertion point / empty range. The
    /// occurrence comes from where the selection actually starts, so selecting
    /// the second of two identical phrases reports the second.
    static func span(of range: NSRange, in text: String) -> SelectedSpan? {
        guard range.length > 0, let swift = Range(range, in: text) else { return nil }
        let selected = String(text[swift])
        guard !selected.isEmpty else { return nil }
        return SelectedSpan(
            text: selected,
            occurrence: spanOccurrence(
                of: selected, startingAt: text.distance(from: text.startIndex, to: swift.lowerBound),
                in: text))
    }
}

/// How selected prose is painted. The AppKit text host runs in the LIGHT
/// system appearance even though the pane around it is dark, so the system
/// fill it inherits is the light-mode one — pale blue under this palette's
/// near-white glyphs, which makes the one word the person is trying to correct
/// the least legible thing on screen. The fill is replaced with the palette's
/// own accent, at the alpha where it is still dark enough to carry the prose
/// ink and already light enough to read as a selection against the page.
@MainActor
enum BlockSelection {
    static var fill: NSColor { NSColor(Design.accent.opacity(0.45)) }
}

/// The block's one seam onto its own text view: it configures the host, it
/// paints the anchor mark, and it reports what the reader selected and where on
/// the page that landed.
///
/// The reporting is read from the text system rather than from the editor's own
/// selection binding, because that binding is only driven while the editor is
/// editable — and this prose must not be. SwiftUI exposes no hook for any of
/// it, so the text view is reached from the editor's own background.
private struct BlockTextHostBridge: NSViewRepresentable {
    let mark: SelectedSpan?
    let onSelectionChange: (SelectedSpan?, SelectionFrame?) -> Void

    func makeNSView(context: Context) -> NSView {
        let plate = BlockTextHostPlate()
        plate.mark = mark
        plate.onSelectionChange = onSelectionChange
        return plate
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let plate = nsView as? BlockTextHostPlate else { return }
        plate.mark = mark
        plate.onSelectionChange = onSelectionChange
        plate.claimTextView()
    }
}

private final class BlockTextHostPlate: NSView {
    var onSelectionChange: ((SelectedSpan?, SelectionFrame?) -> Void)?
    /// The passage this block's annotations stand on, painted here rather than
    /// carried as a text attribute: the text system draws no background in a
    /// host that is not editable, and an attribute could hold neither the radius
    /// the annotation layer uses nor the bleed that keeps the fill off the first
    /// glyph's stem.
    var mark: SelectedSpan? {
        didSet { if mark != oldValue { needsDisplay = true } }
    }
    private weak var host: NSTextView?
    /// Whether a deferred re-claim is already queued, so a burst of passes
    /// leaves ONE pending retry rather than a chain per pass.
    private var claimRetryQueued = false

    /// The plate shares the text view's frame, so a rectangle converted into it
    /// is already in the block's own top-left space — but only if it counts
    /// downward the way SwiftUI does.
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        claimTextView()
    }

    /// Which text view is this plate's own is a question about frames, and a
    /// frame is only true after layout.
    override func layout() {
        super.layout()
        claimTextView()
    }

    /// A window resize reaches this plate a pass before it reaches the text view
    /// underneath, so for that pass the two are not on the same centre and the
    /// lookup comes back empty. A claim already held is kept until the view it
    /// names leaves the window: dropped instead, the block loses its mark and
    /// its selection reports for as long as the window stays at that width.
    func claimTextView() {
        if let mine = NotesProseHost.textView(under: self) {
            NotesProseHost.configure(mine)
            if mine !== host {
                host = mine
                watch(mine)
            }
        } else if host?.window == nil {
            host = nil
            watch(nil)
        }
        needsDisplay = true
        scheduleClaimRetryIfNeeded()
    }

    /// The lookup can answer "not yet": the text view this plate belongs to may
    /// not be attached — or not yet concentric — on any of the passes that reach
    /// `claimTextView`, and nothing in AppKit promises another one. Until the
    /// claim lands, that text view is what a fresh one always is: editable, in
    /// the light appearance, reporting no selection. So an attached plate
    /// holding no live claim asks again on the next main-queue turn, instead of
    /// waiting for a re-render that may not come.
    ///
    /// It stops on its own terms: a claim on a text view still in the window, or
    /// this plate leaving the window. One retry is outstanding at a time.
    private func scheduleClaimRetryIfNeeded() {
        guard window != nil, host?.window == nil, !claimRetryQueued else { return }
        claimRetryQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            claimRetryQueued = false
            claimTextView()
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// The plate answers for one text view: what the reader selected in it, and
    /// the mark its text carries. The mark arrives with the text — after the
    /// layout pass that placed this plate — so the storage is watched too, or
    /// the plate would keep drawing the block as it stood before it was marked.
    private func watch(_ textView: NSTextView?) {
        let centre = NotificationCenter.default
        centre.removeObserver(self, name: NSTextView.didChangeSelectionNotification, object: nil)
        centre.removeObserver(self, name: NSTextStorage.didProcessEditingNotification, object: nil)
        guard let textView else { return }
        centre.addObserver(
            self, selector: #selector(selectionChanged), name: NSTextView.didChangeSelectionNotification,
            object: textView)
        guard let storage = textView.textStorage else { return }
        centre.addObserver(
            self, selector: #selector(textChanged),
            name: NSTextStorage.didProcessEditingNotification, object: storage)
    }

    @objc private func selectionChanged(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        let range = textView.selectedRange()
        let span = NotesProseHost.span(of: range, in: textView.string)
        onSelectionChange?(span, span == nil ? nil : selectionFrame(range, in: textView))
    }

    @objc private func textChanged() {
        needsDisplay = true
    }

    /// The plate is the editor's own background, so what it draws lands behind
    /// the words — which is what the anchor mark is: a fill behind the passage,
    /// never a box around the block.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let host, let mark, let range = NotesProseHost.markRange(of: mark, in: host.string)
        else { return }
        NSColor(Design.accent.opacity(AnchorWash.composing.fill)).setFill()
        for rect in marks(for: range, in: host) {
            let radius = min(NotesEditingLayout.markRadius, rect.height / 2)
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        }
    }

    /// Where a character range sits on this plate, one rect per line it runs
    /// across, bled sideways so the fill clears the glyphs it marks instead of
    /// clipping against them.
    private func marks(for range: NSRange, in host: NSTextView) -> [NSRect] {
        guard let layout = host.textLayoutManager, let content = layout.textContentManager,
            let start = content.location(content.documentRange.location, offsetBy: range.location),
            let end = content.location(start, offsetBy: range.length),
            let span = NSTextRange(location: start, end: end)
        else { return [] }
        let origin = host.textContainerOrigin
        var rects: [NSRect] = []
        layout.enumerateTextSegments(in: span, type: .standard, options: []) { _, rect, _, _ in
            let onHost = rect.offsetBy(dx: origin.x, dy: origin.y)
            let onPlate = convert(onHost, from: host)
                .insetBy(dx: -Self.markBleed, dy: Self.markInset)
            // The same line comes back once per text element it is made of, and
            // a translucent fill painted twice is twice the alpha the pack pins.
            if !rects.contains(where: { $0.equalTo(onPlate) }) { rects.append(onPlate) }
            return true
        }
        return rects
    }

    /// The fill clears the first and last glyph instead of touching them, and
    /// stops short of the line box so two marked lines never meet.
    static let markBleed: CGFloat = 4
    static let markInset: CGFloat = 1

    /// Where the selection sits, in the space SwiftUI measures a view's frame
    /// in: down from the window's top-left corner. The caller subtracts its own
    /// frame's origin to land in its own coordinates — which is the only honest
    /// way across this seam, since the block's row is wider than the text host
    /// standing inside it.
    private func selectionFrame(_ range: NSRange, in textView: NSTextView) -> SelectionFrame? {
        guard let window = textView.window,
            let first = lineRect(at: range.location, in: textView, window: window),
            let last = lineRect(
                at: range.location + range.length - 1, in: textView, window: window)
        else { return nil }
        return SelectionFrame(first: first, last: last)
    }

    /// The rectangle of one character. The text input protocol answers in screen
    /// space — the only space both TextKit generations agree on — and AppKit
    /// counts up from the bottom of the window where SwiftUI counts down from
    /// the top, so the rectangle is turned over here.
    private func lineRect(at location: Int, in textView: NSTextView, window: NSWindow) -> CGRect? {
        var actual = NSRange()
        let onScreen = textView.firstRect(
            forCharacterRange: NSRange(location: location, length: 1), actualRange: &actual)
        guard onScreen.height > 0, let content = window.contentView else { return nil }
        let inWindow = window.convertFromScreen(onScreen)
        return CGRect(
            x: inWindow.minX, y: content.bounds.height - inWindow.maxY,
            width: inWindow.width, height: inWindow.height)
    }
}

/// Puts the block's own actions at the top of the menu the text system already
/// offers, so a right-click on the prose carries AI Correct and Add Note above
/// the standard macOS text items. The plate is transparent to every other
/// event, so the drag that makes a selection still reaches the text.
private struct BlockContextMenuPlate: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ContextMenuPlate() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class ContextMenuPlate: NSView {
    /// Held while the menu is up: the block's items are copies, and a copy's
    /// target is not owned by the copy — the menu they came from keeps it alive.
    private var blockMenu: NSMenu?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent, Self.opensAMenu(event) else { return nil }
        return super.hitTest(point)
    }

    /// The system's text menu with the block's own actions inserted on top.
    override func menu(for event: NSEvent) -> NSMenu? {
        let block = blockMenu(for: event)
        blockMenu = block
        guard let host = NotesProseHost.textView(under: self),
            let system = host.menu(for: event), !system.items.isEmpty
        else { return block }
        aim(system, at: host)
        guard let block else { return system }
        var index = 0
        for item in block.items {
            guard let copy = item.copy() as? NSMenuItem else { continue }
            system.insertItem(copy, at: index)
            index += 1
        }
        if index > 0 { system.insertItem(.separator(), at: index) }
        return system
    }

    /// The system's items carry no target of their own — they are meant for
    /// whatever holds the keyboard, and on this surface that is never the text
    /// view: the block owns the focus, so Copy would stand greyed over a live
    /// selection. They are aimed at the text view they were built for, which is
    /// also what validates them.
    private func aim(_ menu: NSMenu, at host: NSTextView) {
        for item in menu.items {
            if let submenu = item.submenu { aim(submenu, at: host) }
            guard item.target == nil, let action = item.action, host.responds(to: action)
            else { continue }
            item.target = host
        }
    }

    /// The block's own menu, wherever it is attached above this plate.
    private func blockMenu(for event: NSEvent) -> NSMenu? {
        var view = superview
        while let current = view {
            if let menu = current.menu(for: event) { return menu }
            view = current.superview
        }
        return nil
    }

    /// A Control-click arrives as a left mouse down; AppKit's own menu handling
    /// only covers the right button.
    override func mouseDown(with event: NSEvent) {
        guard let menu = menu(for: event) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private static func opensAMenu(_ event: NSEvent) -> Bool {
        switch event.type {
        case .rightMouseDown, .rightMouseUp: return true
        case .leftMouseDown, .leftMouseUp: return event.modifierFlags.contains(.control)
        default: return false
        }
    }
}
