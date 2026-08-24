import BlaiseCore
import SwiftUI

// The notes editing surface: at rest the notes are clean prose, and every
// editing affordance is transient. Four discovery paths (block hover, text
// selection, right-click, the app menu) reach ONE entry seam; the composer
// opens inline below the block; a semantic correction leaves a slim pending
// row until the rewrite completes; margin notes present per the placement
// Setting. Everything under `ProcessingPipeline.addCorrection` is untouched.

// MARK: - The entry seam

/// A span inside ONE block: the text of it, and which occurrence of that text
/// within the block it is. A block can repeat the same words, so the text alone
/// does not say which range the user dragged over — and the wash has to land on
/// the one they did.
struct SelectedSpan: Equatable {
    var text: String
    var occurrence: Int = 0
}

/// Where a selection sits inside its own block, in the block's coordinates: the
/// line it starts on and the line it ends on. A control placed against these
/// can stand at the words it acts on without standing on them. Kept apart from
/// `SelectedSpan` because it is geometry, not identity — the span survives a
/// reflow and these rectangles do not.
struct SelectionFrame: Equatable {
    var first: CGRect
    var last: CGRect

    /// The block's own first line, for a host that cannot say where inside
    /// itself the selection landed. The bar still stands at the passage's
    /// block; it just cannot point at the words.
    static let blockStart = SelectionFrame(
        first: CGRect(x: 0, y: 0, width: 0, height: 17),
        last: CGRect(x: 0, y: 0, width: 0, height: 17))

    /// The same selection read from a different corner: the text host answers
    /// in the window's own space, and the block that draws the bar thinks in
    /// its own.
    func offset(by origin: CGPoint) -> SelectionFrame {
        SelectionFrame(
            first: first.offsetBy(dx: -origin.x, dy: -origin.y),
            last: last.offsetBy(dx: -origin.x, dy: -origin.y))
    }
}

/// Where one notes block sits: in the window, which is the space the text host
/// answers in, and in the pane, which is what says whether the block is above
/// or below the fold. Held outside the view state — it changes on every scroll
/// tick, and nothing should be redrawn for that.
struct BlockGeometry: Equatable {
    var window: CGRect
    var pane: CGRect
    /// The block's place in the document, which does not move when the pane
    /// scrolls — where the one selection bar is drawn.
    var content: CGRect = .zero
}

@MainActor
final class BlockGeometryCache {
    var blocks: [String: BlockGeometry] = [:]
}

/// How many occurrences of `span` begin before `offset` characters into
/// `plain` — the index that names the range starting there among its equals.
func spanOccurrence(of span: String, startingAt offset: Int, in plain: String) -> Int {
    guard !span.isEmpty else { return 0 }
    var count = 0
    var cursor = plain.startIndex
    while let found = plain.range(of: span, range: cursor..<plain.endIndex) {
        guard plain.distance(from: plain.startIndex, to: found.lowerBound) < offset else { break }
        count += 1
        cursor = plain.index(after: found.lowerBound)
    }
    return count
}

/// What an editing action targets. `quotedText` is the exact span the
/// instruction anchors to — the whole block for a block-level invocation, the
/// selected range for a selection.
struct EditingTarget: Equatable {
    enum Kind: Equatable {
        case correct
        case note
    }

    var kind: Kind
    var section: MeetingCorrection.Section
    /// The anchor id of the block the invocation came from — positional, so it
    /// survives a re-synthesis that rewrites the prose under an open composer.
    var anchorID: String
    /// The UNTRIMMED text of the block acted on: the save path recomputes the
    /// stored occurrence against it when the quote is narrower.
    var blockText: String
    var quotedText: String
    /// What the composer SHOWS as the thing it will act on: the line as the
    /// block's host renders it, which for an action item carries the owner
    /// prefix the stored quote does not. Display only — `quotedText` remains
    /// the durable anchor.
    var displayQuote: String
    var occurrence: Int
    /// Which occurrence of `quotedText` the user acted on, counted inside the
    /// text the block's HOST RENDERS — for action items that is the
    /// owner-prefixed display line, not `blockText`.
    /// Display only — it says which range the wash paints; the durable anchor
    /// is quote + section + block occurrence, never a position inside a block.
    var spanOccurrence: Int = 0
    /// A block-level invocation washes the whole block; a selection washes the
    /// span it came from.
    var isWholeBlock: Bool

    /// The span the wash paints, in the host-rendered text: the selected range,
    /// or the whole quoted block when the invocation took no selection. Always
    /// a span, so the fill rides the glyphs instead of the block's row.
    var washedSpan: SelectedSpan {
        SelectedSpan(text: quotedText, occurrence: isWholeBlock ? 0 : spanOccurrence)
    }
}

/// What the composer hands back on submit.
struct CorrectionSubmission: Equatable {
    var section: MeetingCorrection.Section
    var quotedText: String
    var userText: String
    var occurrence: Int
    /// The block the quote was taken from — the save path recomputes the
    /// occurrence against it, since a trimmed quote lives in a different match
    /// space than the whole block.
    var blockText: String
}

/// The single routing seam every discovery path funnels through: the hover
/// group, the selection capsule, the block's context menu and the menu-bar
/// commands all build their target here and consult the same enablement.
enum NotesEditingEntry {
    /// The gate, per action. A correction may only be STARTED (and committed)
    /// when no run holds the meeting and the selected summarization engine can
    /// edit notes at all; a margin note is never run-gated and never depends on
    /// the engine — it is not an instruction and never touches synthesis.
    static func allowed(
        _ kind: EditingTarget.Kind, correctionEnabled: Bool, engineCanEditNotes: Bool
    ) -> Bool {
        offered(kind, engineCanEditNotes: engineCanEditNotes)
            && (kind == .note || correctionEnabled)
    }

    /// Whether the action is OFFERED at all — the question the surface asks
    /// before it draws a control. An engine that cannot edit notes leaves the
    /// correction path ABSENT rather than disabled: there is nothing the user
    /// could wait for.
    static func offered(_ kind: EditingTarget.Kind, engineCanEditNotes: Bool) -> Bool {
        switch kind {
        case .correct: return engineCanEditNotes
        case .note: return true
        }
    }

    /// Builds the target for an invocation. `selection` is the text selected
    /// inside the block, if any: present ⇒ the instruction anchors to that
    /// span, absent ⇒ to the whole block. A selection that is blank, or that
    /// the block does not contain, falls back to the whole block rather than
    /// anchoring to something the user cannot see. `hostText` is the text the
    /// block's host actually RENDERS — the space `spanOccurrence` is counted
    /// in; it differs from `blockText` where the host composes the line
    /// (an action item's owner prefix).
    static func target(
        _ kind: EditingTarget.Kind, section: MeetingCorrection.Section, anchorID: String,
        blockText: String, occurrence: Int, selection: SelectedSpan? = nil,
        hostText: String? = nil
    ) -> EditingTarget {
        let trimmed = selection?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let usable = !trimmed.isEmpty && CorrectionAnchoring.fold(blockText)
            .contains(CorrectionAnchoring.fold(trimmed))
        return EditingTarget(
            kind: kind, section: section, anchorID: anchorID, blockText: blockText,
            quotedText: usable ? trimmed : blockText,
            displayQuote: usable ? trimmed : (hostText ?? blockText), occurrence: occurrence,
            spanOccurrence: usable
                ? trimmedSpanOccurrence(
                    selection, trimmedTo: trimmed, in: hostText ?? blockText) : 0,
            isWholeBlock: !usable)
    }

    /// Which occurrence of the TRIMMED quote the user acted on, counted in the
    /// host-rendered text the wash paints into. Trimming only ever removes
    /// whitespace, so the selection's own position carries over untouched
    /// unless the trim changed the text — then the quote is located inside the
    /// range that was actually selected.
    private static func trimmedSpanOccurrence(
        _ selection: SelectedSpan?, trimmedTo trimmed: String, in hostText: String
    ) -> Int {
        guard let selection else { return 0 }
        guard selection.text != trimmed else { return selection.occurrence }
        var cursor = hostText.startIndex
        var seen = 0
        while let found = hostText.range(of: selection.text, range: cursor..<hostText.endIndex) {
            if seen == selection.occurrence {
                guard let start = hostText.range(of: trimmed, range: found)?.lowerBound
                else { return 0 }
                return spanOccurrence(
                    of: trimmed,
                    startingAt: hostText.distance(from: hostText.startIndex, to: start),
                    in: hostText)
            }
            seen += 1
            cursor = hostText.index(after: found.lowerBound)
        }
        return 0
    }

    /// The reason a correction affordance is closed, reachable from the
    /// disabled control. nil when it is open. Only the run gate can produce a
    /// reason: an action the engine cannot serve is never drawn, so it has no
    /// disabled control to explain itself from.
    static func disabledReason(_ kind: EditingTarget.Kind, correctionEnabled: Bool) -> String? {
        kind == .note || correctionEnabled
            ? nil
            : "Updating notes — your correction will be ready to send when it finishes"
    }
}

/// The right-click menu's action seam: the same gate and the same target the
/// hover group builds. A selection anchors the instruction only when it lives
/// in the block that was right-clicked — a selection elsewhere in the notes is
/// not what this invocation is about.
@discardableResult
func notesEditingContextMenuAction(
    _ kind: EditingTarget.Kind, section: MeetingCorrection.Section, blockText: String,
    occurrence: Int, blockID: String, selection: (blockID: String, span: SelectedSpan)?,
    correctionEnabled: Bool, engineCanEditNotes: Bool, hostText: String? = nil,
    begin: (EditingTarget) -> Void
) -> Bool {
    guard NotesEditingEntry.allowed(
        kind, correctionEnabled: correctionEnabled, engineCanEditNotes: engineCanEditNotes)
    else { return false }
    begin(
        NotesEditingEntry.target(
            kind, section: section, anchorID: blockID, blockText: blockText,
            occurrence: occurrence,
            selection: selection?.blockID == blockID ? selection?.span : nil,
            hostText: hostText))
    return true
}

/// The composer's commit seam: the gate is re-read HERE, against the live run
/// state, because the composer may have been opened before the run started.
/// A refused commit leaves the composer — and the typed draft — standing, with
/// its reason already on screen; it re-enables when the gate reopens.
@discardableResult
func notesEditingCommitAction(
    _ target: EditingTarget, correctionEnabled: Bool, engineCanEditNotes: Bool,
    commit: (EditingTarget) -> Void
) -> Bool {
    guard NotesEditingEntry.allowed(
        target.kind, correctionEnabled: correctionEnabled,
        engineCanEditNotes: engineCanEditNotes)
    else { return false }
    commit(target)
    return true
}

/// Whether the open composer belongs to this block. Identity is the block's
/// stable anchor and never its prose: the run that reopens the correction gate
/// is the same event that rewrites the text, and the retained draft has to
/// survive it.
func composerBelongs(_ target: EditingTarget?, toBlockWith anchorID: String) -> Bool {
    target?.anchorID == anchorID
}

/// Whether the composer a block would host is actually PRESENTED: the target
/// belongs to the block AND its action is still offered under the selected
/// engine. Every mark that means "being composed" reads this rather than the
/// target alone — the composing wash, the suppression of the block's pending
/// mark, the selection outline and the selection bar — so a composer the
/// surface is not drawing leaves none of them behind. The target and its draft
/// stay stored either way, so selecting an editing engine again brings the
/// composer back with the typed words intact.
func composerPresented(
    _ target: EditingTarget?, inBlockWith anchorID: String, engineCanEditNotes: Bool
) -> Bool {
    guard let target, composerBelongs(target, toBlockWith: anchorID) else { return false }
    return NotesEditingEntry.offered(target.kind, engineCanEditNotes: engineCanEditNotes)
}

/// The anchor id of a rendered notes block: its section's own prefix and its
/// position within that section, so ids from two sections cannot collide.
enum NotesBlockAnchor {
    static func summary(_ index: Int) -> String { "notes-summary-\(index)" }
    static func detailed(_ index: Int) -> String { "notes-detailed-\(index)" }
    static func decision(_ index: Int) -> String { "notes-decision-\(index)" }
    static func actionItem(_ index: Int) -> String { "notes-action-\(index)" }

    /// Every block id the pane renders for these notes, in render order. The
    /// open composer's block is looked up here, so what is on screen and what
    /// the composer believes still exists cannot drift apart.
    static func rendered(in structured: NotesStructured) -> [String] {
        var ids = MarkdownBlocks.parse(structured.summary).indices.map(Self.summary)
        ids += structured.decisions.indices.map(Self.decision)
        ids += structured.actionItems
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .indices.map(Self.actionItem)
        let body = structured.detailedNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            ids += MarkdownBlocks.parse(body).indices.map(Self.detailed)
        }
        return ids
    }
}

/// Whether the open composer's block is gone from the notes on screen. Block
/// ids are positional, so a re-synthesis that removes blocks — or leaves fewer
/// of them than the composing index — retires the id the composer opened on.
/// It then presents off its retained quote instead of leaving the view tree and
/// taking the user's typed draft with it.
func composerIsOrphaned(_ target: EditingTarget?, renderedAnchorIDs: [String]) -> Bool {
    guard let target else { return false }
    return !renderedAnchorIDs.contains(target.anchorID)
}

// MARK: - The teaching callout

/// The surface's one first-run line. Any correction/note action — or the
/// callout's own ✕ — retires it forever through the `notes.editingCalloutSeen`
/// key.
enum NotesEditingCallout {
    static let text = "Select text to correct it, or add a note."

    /// Which of the summary's rendered blocks the callout hangs off: its FIRST
    /// ordinary paragraph, the text the line is teaching about. Nil once it has
    /// been dismissed, and nil where the summary has no paragraph at all — a
    /// teaching line with no anchor stands over an empty section pointing at
    /// nothing. Dismissal is read first, so a retired callout costs one
    /// comparison and no scan.
    static func anchorIndex(seen: Bool, summaryBlocks: [MarkdownBlock]) -> Int? {
        guard !seen else { return nil }
        let paragraph = summaryBlocks.firstIndex { $0.kind == .paragraph }
        guard NotesEditingSettings.showEditingCallout(seen: seen, hasNotes: paragraph != nil)
        else { return nil }
        return paragraph
    }
}

// MARK: - Keyboard reach

extension View {
    /// Keyboard focus for one notes block: it joins the pane's focus chain,
    /// shows the keyboard's position, and reports itself as what the commands
    /// aim at. The ring is drawn rather than inherited — the system's focus
    /// effect does not mark a plain container on this surface.
    /// `marked` is false where the block already carries a louder mark of its
    /// own — the selection bar standing on its own words — so one block never
    /// wears two.
    func notesBlockFocus(
        id: String, focus: FocusState<String?>.Binding, marked: Bool = true,
        onFocus: @escaping () -> Void
    ) -> some View {
        focusable()
            .focusEffectDisabled()
            .focused(focus, equals: id)
            .overlay {
                if focus.wrappedValue == id, marked {
                    // A hairline, never a frame: the mark says where the keyboard is,
                    // and it must not outshout the control it puts inside it.
                    RoundedRectangle(cornerRadius: NotesEditingLayout.markRadius)
                        .strokeBorder(Design.accent.opacity(0.6), lineWidth: 1)
                        .padding(-3)
                        .accessibilityHidden(true)
                }
            }
            .onChange(of: focus.wrappedValue == id) { _, holdsFocus in
                if holdsFocus { onFocus() }
            }
    }
}

// MARK: - Status vocabularies

/// The pending row's displayed status. `nil` from the mapping below means NO
/// row: the instruction is not one that shows one, or it is done.
enum PendingRowStatus: Equatable {
    case pending
    case applying

    var label: String {
        switch self {
        case .pending: return "Pending"
        case .applying: return "Applying…"
        }
    }
}

/// (instruction status × kind × run activity) → the row shown under the block.
///
/// Only semantic corrections show a row: a margin note applies deterministically
/// and never has an interval to report. A consumed correction shows nothing —
/// the row dissolves and the prose is clean; a failed rewrite leaves the row
/// `pending`, which reads as Pending again.
func pendingRowStatus(
    kind: MeetingCorrection.Kind, status: MeetingCorrection.Status, runActive: Bool
) -> PendingRowStatus? {
    guard kind == .understanding else { return nil }
    switch status {
    case .applied, .resolved: return nil
    case .pending, .stale: return runActive ? .applying : .pending
    }
}

/// Whether the panel offers the way back from a lost anchor on this row. A
/// stale row is the only kind that has one: its quote no longer matches any
/// block, so nothing else in the app can re-attach it. Only annotations ever
/// reach that status — the panel carries pin-back because §3.7 asks it to
/// preserve every management capability on its own, not because the orphan
/// tail covers a different set of rows.
func changesRowCanPin(_ row: MeetingCorrection) -> Bool {
    row.status == .stale
}

/// The Changes overview's per-row status. An understanding row becomes applied
/// only when an attributed editor operation changed bytes. A margin note waits
/// on nothing and changes nothing, so it never reads as pending — it says
/// whether it is in the notes yet.
func changesRowStatus(_ row: MeetingCorrection, runActive: Bool) -> String {
    switch row.status {
    case .resolved:
        return "Resolved"
    case .stale:
        return "No matching anchor"
    case .applied:
        guard row.kind == .understanding else { return "In your notes" }
        return "Applied · \(BlaiseDateFormat.dayMonthYearTime(row.appliedAt ?? row.createdAt))"
    case .pending:
        guard row.kind == .understanding else { return "Not in the notes yet" }
        return runActive ? PendingRowStatus.applying.label : PendingRowStatus.pending.label
    }
}

/// The row's visible timestamp follows `createdAt`, which the store restamps on
/// an understanding edit or reopen so the panel shows the new instruction time.
func changesRowTimestamp(_ row: MeetingCorrection) -> String {
    BlaiseDateFormat.dayMonthYearTime(row.createdAt)
}

func changesRowEditDisabled(
    _ row: MeetingCorrection, runActive: Bool, busy: Bool
) -> Bool {
    busy || (runActive && row.kind == .understanding)
}

func changesRowResolveDisabled(
    _ row: MeetingCorrection, resolved: Bool, runActive: Bool, busy: Bool
) -> Bool {
    busy || (resolved && runActive && row.kind == .understanding)
}

/// Which half of the meeting's annotations the overview is showing. The control
/// states its value in words; colour never carries this.
enum ChangesFilter: String, CaseIterable, Identifiable {
    case open
    case resolved

    var id: String { rawValue }

    var label: String {
        switch self {
        case .open: return "Open"
        case .resolved: return "Resolved"
        }
    }

    /// What the overview says when this half is empty.
    var emptyLabel: String {
        switch self {
        case .open: return "Nothing open — everything here is resolved."
        case .resolved: return "Nothing resolved yet."
        }
    }
}

/// Whether the person is done with this row. A processed correction is done by
/// evidence — a rewrite consumed it and the notes already carry it; everything
/// else is done only because the person put it away.
func changesRowIsResolved(_ row: MeetingCorrection, resolvedIDs: Set<String>) -> Bool {
    if row.kind == .understanding, row.status == .applied { return true }
    return resolvedIDs.contains(row.id)
}

/// The rows one half of the filter shows, in the order they were given.
func changesRows(
    _ rows: [MeetingCorrection], filter: ChangesFilter, resolvedIDs: Set<String>
) -> [MeetingCorrection] {
    rows.filter {
        changesRowIsResolved($0, resolvedIDs: resolvedIDs) == (filter == .resolved)
    }
}

// MARK: - Layout mode (the placement Setting, resolved against the width)

/// How the notes column presents margin notes right now: the Setting decides
/// the mode, the window width decides whether the rail fits.
enum NotesLayoutMode: Equatable {
    /// Notes are always-visible cards under their anchored block, pushing
    /// content down. The Setting's default; safe at any width.
    case inlineCards
    /// Quiet typography in a right-hand rail beside the text.
    case marginRail
    /// The rail does not fit: the note collapses to a chip at the block end
    /// that expands in place. The only chip in the design.
    case marginChip

    var usesRail: Bool { self == .marginRail }
}

enum NotesEditingLayout {
    /// The prose column's own measure (the notes pane's existing cap).
    static let proseMeasure: CGFloat = 740
    static let railWidth: CGFloat = 200
    static let railGutter: CGFloat = 18
    /// The one card measure. An aside must not share the prose's measure, or it
    /// reads as another paragraph of the notes rather than as a mark the reader
    /// made on them — every card the annotation layer draws stops here.
    static let asideMeasure: CGFloat = 460
    /// One radius for everything the annotation layer draws, so a mark on a
    /// passage, the card carrying that mark's note, and the control that made it
    /// are visibly the same family. There is no second radius.
    static let markRadius: CGFloat = 8
    /// Below this the rail cannot sit beside a readable measure, so the margin
    /// mode falls back to its chip. It is the surface's ONE width threshold:
    /// the transient control stands at the selection rather than in a lane, so
    /// no second breakpoint can disagree with this one.
    static let railMinimumWidth: CGFloat = proseMeasure + railGutter + railWidth

    static func mode(_ placement: MarginNotesPlacement, width: CGFloat) -> NotesLayoutMode {
        switch placement {
        case .inline: return .inlineCards
        case .margin: return width >= railMinimumWidth ? .marginRail : .marginChip
        }
    }
}

// MARK: - The two kinds

/// The two marks a person can leave on a meeting's notes, and — derived from
/// what each one IS — how each presents.
///
/// A margin note is the person's own content. It belongs to the document: it
/// survives every re-synthesis, it exports with the notes, and it is meant to be
/// read alongside the prose. So it is set IN the page — reading type against a
/// rule, no plane of its own, the way a document carries an aside.
///
/// A correction is an instruction the notes have not honoured yet. It describes
/// work in flight, and the moment a rewrite lands it has nothing left to say and
/// goes. So it sits ON the page — a plate, UI type, a status marker — the same
/// family of object as the transient control that made it.
///
/// Nothing here is carried by hue: the two differ in whether there is a plane at
/// all, in what marks their leading edge, in type family and size, in ink, and in
/// whether they report a state.
enum AnnotationKindStyle: Equatable, CaseIterable {
    case note
    case correction

    /// Whether the mark is drawn on a plane of its own. Only the transient kind
    /// is: a plate reads as something resting on the page, which is what an
    /// instruction awaiting its rewrite is.
    var isPlated: Bool { self == .correction }

    /// Whether the mark carries a rule at its leading edge — the document's own
    /// way of setting an aside apart from the prose beside it.
    var hasLeadingRule: Bool { self == .note }

    /// The rule's ink over the page. It is the shape that says "a note stands
    /// here" from across the room, so it clears the 3:1 floor a non-text mark
    /// carries; below that it is decoration nobody can rely on.
    static let ruleAlpha: Double = 0.68

    /// Whether the mark reports a state. Content has no state to report.
    var reportsState: Bool { self == .correction }

    /// Reading type for the words that belong to the notes; interface type for
    /// the words that describe pending work.
    var usesReadingType: Bool { self == .note }

    /// The body's point size. The note is set at the notes' own reading size —
    /// it is one of the notes; the correction is set at interface size, because
    /// it describes work rather than saying something.
    var bodyPointSize: CGFloat { self == .note ? 14 : 12 }

    /// The body's ink. The note reads at content contrast — it is meant to be
    /// read as part of the notes; the correction reads a step back, as a
    /// description of work rather than a paragraph.
    var bodyInk: Double { self == .note ? 0.92 : 0.72 }

    @MainActor
    var body: Font {
        usesReadingType
            ? Design.readingFont(bodyPointSize) : .system(size: bodyPointSize)
    }
}

// MARK: - The card grammar

/// What a card IS in this product, decided once: one flat fill, one radius, one
/// measure — no stroke, no accent rail, no second surface idea. It governs the
/// containers this layer draws (the composer, the pending correction, the
/// overview card), so the reading column never carries two ideas of a plane or
/// two right edges. It does not make everything a container: a margin note is
/// content and draws no plane at all.
enum NotesEditingSurface {
    /// Quiet, not loud. A card has to read as a plane the page carries rather
    /// than a frame drawn on it, so it sits just clear of the page — the band
    /// the reference surfaces hold. Below it there is no surface at all; above
    /// it the container starts outshouting the words it is about.
    static let cardFillAlpha: Double = 0.07
    static let cardFill = Color.white.opacity(cardFillAlpha)
}

extension View {
    /// The card grammar, applied. `measure` is only ever overridden where the
    /// card is not in the reading column and the enclosing surface already
    /// states its width.
    func annotationCard(measure: CGFloat? = NotesEditingLayout.asideMeasure) -> some View {
        frame(maxWidth: measure ?? .infinity, alignment: .leading)
            .background(
                NotesEditingSurface.cardFill,
                in: RoundedRectangle(cornerRadius: NotesEditingLayout.markRadius))
    }
}

/// The anchor quote as the references draw it: a short rule with the quoted
/// words beside it, well inside the card. Never a full-column echo of a line the
/// reader can already see.
struct AnchorQuote: View {
    var quote: String
    var limit: Int = 64

    var body: some View {
        Text("\u{201C}\(NotesEditingText.clip(quote, limit: limit))\u{201D}")
            .font(Design.readingFont(11.5).italic())
            .foregroundStyle(.tertiary)
            .lineLimit(2)
            .padding(.leading, 7)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Design.accent.opacity(0.55))
                    .frame(width: 2)
                    .accessibilityHidden(true)
            }
    }
}

/// The type label a container leads with. It names what the reader is looking
/// at; it is never what tells the two kinds apart — the way each one is drawn
/// does that, and a label that has to be read has already failed.
struct CardKindLabel: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .kerning(0.8)
            .textCase(.uppercase)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
    }
}

/// One margin note as the notes column will present it. The excerpt is carried
/// when adjacency alone cannot say what the note is about: a note displaced off
/// its own row in the rail, a coarse placement, or a lost anchor.
struct MarginNoteViewModel: Equatable, Identifiable {
    var id: String
    var text: String
    var quotedText: String
    var showsQuote: Bool
    var isStale: Bool
}

enum NotesEditingPresentation {
    /// The notes anchored to one block, as the given mode presents them.
    ///
    /// A card cites its anchor only where the anchor is not already on screen
    /// directly above it. The first note of a block stands against the line it
    /// is about in every placement — under it as a card, beside it in the rail —
    /// so quoting there prints the sentence twice, truncated underneath the
    /// legible original. A later note on the same block has another card between
    /// it and the line, and the block's mark names only the first note's span,
    /// so its own words are the only thing saying which passage it means. A note
    /// whose anchor is gone has nothing to stand against at all.
    ///
    /// One rule, every mode: cite when adjacency cannot carry the anchor.
    static func marginNotes(_ rows: [MeetingCorrection]) -> [MarginNoteViewModel] {
        rows.enumerated().map { index, row in
            MarginNoteViewModel(
                id: row.id, text: row.userText, quotedText: row.quotedText,
                showsQuote: index > 0 || row.status == .stale,
                isStale: row.status == .stale)
        }
    }
}

// MARK: - Motion

/// The one motion vocabulary this surface uses: an interruptible spring under
/// ~400 ms on transform + opacity, replaced by a plain crossfade under Reduce
/// Motion.
enum NotesEditingMotion {
    static let push = Animation.spring(duration: 0.32, bounce: 0.14)
    static let crossfade = Animation.easeOut(duration: 0.16)
    static let reveal = Animation.easeOut(duration: 0.09)

    static func expand(reduceMotion: Bool) -> Animation {
        reduceMotion ? crossfade : push
    }
}

// MARK: - The anchor wash

/// The wash lifetime rule: strong while composing, restrained while pending,
/// absent once a correction applies, persistent for a margin note's anchor.
enum AnchorWash: Equatable {
    case none
    case composing
    case pending
    case note

    /// The wash sits well below the text's own contrast — the passage stays the
    /// loudest thing on its line. 10–14% is the band the reference frames hold.
    ///
    /// ONE alpha for every live wash. Three intensities of one hue do not read
    /// as three states; they read as an unsteady highlight, and they crowd the
    /// same hue the selection already uses. Which state a marked passage is in
    /// is said by the card under it and by that card's own status word.
    static let liveFill: Double = 0.12

    var fill: Double {
        self == .none ? 0 : Self.liveFill
    }
}

extension AnchorWash {
    /// The composing wash painted over an exact span of the block's own text
    /// instead of behind the whole block: what a selection-scoped invocation
    /// gets, so the user sees precisely what the instruction targets. A block
    /// can repeat the same words, so the span names WHICH of its equals the
    /// user selected. A span the text no longer contains paints nothing rather
    /// than guessing; an occurrence the text no longer has falls back to its
    /// last one, the same choice the anchor resolver makes when a rewrite
    /// collapses duplicates.
    @MainActor
    static func composingSpan(in text: AttributedString, span: SelectedSpan) -> AttributedString {
        let plain = String(text.characters)
        let matches = Self.ranges(of: span.text, in: plain)
        guard let found = matches.indices.contains(span.occurrence)
            ? matches[span.occurrence] : matches.last
        else { return text }
        var output = text
        let start = output.index(
            output.startIndex,
            offsetByCharacters: plain.distance(from: plain.startIndex, to: found.lowerBound))
        let end = output.index(
            start, offsetByCharacters: plain.distance(from: found.lowerBound, to: found.upperBound))
        var cues = AttributeContainer()
        cues.backgroundColor = Design.accent.opacity(AnchorWash.composing.fill)
        output[start..<end].mergeAttributes(cues)
        return output
    }

    /// The span a block's stored annotations ride: the first row's own quote,
    /// which the host locates in the text it renders. It is the whole line only
    /// when the person annotated the whole line, so the fill ends at the last
    /// glyph of the passage instead of spanning the block's row.
    static func washedSpan(for rows: [MeetingCorrection]) -> SelectedSpan? {
        rows.first.map { SelectedSpan(text: $0.quotedText) }
    }

    /// Every range of `span` in `plain`, in order.
    private static func ranges(of span: String, in plain: String) -> [Range<String.Index>] {
        guard !span.isEmpty else { return [] }
        var found: [Range<String.Index>] = []
        var cursor = plain.startIndex
        while let next = plain.range(of: span, range: cursor..<plain.endIndex) {
            found.append(next)
            cursor = plain.index(after: next.lowerBound)
        }
        return found
    }
}

extension View {
    /// Paints the wash behind a block, for the hosts that cannot carry it on
    /// their glyphs. No outline: a rule around the row reads as a box around
    /// the block, and the mark belongs to the words. `emphasized` is the margin
    /// mode's reciprocal hover — hovering a note strengthens its anchor.
    ///
    /// Cyan whatever the wash: the anchor mark is one primary, and a violet
    /// fill would read as a second one.
    func anchorWash(_ wash: AnchorWash, emphasized: Bool = false) -> some View {
        let boost = emphasized ? 1.6 : 1.0
        return padding(.horizontal, wash == .none ? 0 : 4)
            .background(
                Design.accent.opacity(wash.fill * boost),
                in: RoundedRectangle(cornerRadius: NotesEditingLayout.markRadius))
    }
}

// MARK: - The selection action bar

/// The one transient control on this surface: a compact bar that arrives at the
/// text the person selected, and nowhere else. Nothing reveals it — not the
/// pointer crossing a line, not a click, not focus. A selection is the only
/// thing that brings it, and losing the selection is the only thing that takes
/// it away.
///
/// Its shape is a real control: two side-by-side targets on an opaque plate,
/// split by a hairline, with a small tail that points back at the first word of
/// the selection. Side by side rather than stacked because it stands under a
/// line of prose, where width is cheap and height is what would cover the next
/// line.
struct SelectionActionBar: View {
    var correctionEnabled: Bool
    /// False leaves the bar with its annotation target alone: the correction
    /// path is not something this engine can serve, so it is not drawn.
    var engineCanEditNotes: Bool
    /// Which way the tail points, and where along the bar it sits — the offset
    /// is measured from the bar's own leading edge.
    var pointsUp: Bool
    var tailOffset: CGFloat
    var onAction: (EditingTarget.Kind) -> Void

    /// The tappable height of each target. Under 22 points is not a control;
    /// the reference bar's is about 28.
    nonisolated static let targetHeight: CGFloat = 28
    /// Each target's width, and so the plate's. Pinned rather than grown from
    /// whichever label is longest, because the placement resolver has to know
    /// the bar's size before the bar is laid out.
    nonisolated static let targetWidth: CGFloat = 88
    nonisolated static let plateWidth: CGFloat = targetWidth * 2 + 1
    /// The tail's footprint. It is drawn outside the plate, so the control's
    /// whole height is the plate plus it.
    nonisolated static let tailHeight: CGFloat = 5
    nonisolated static let tailWidth: CGFloat = 11
    nonisolated static var size: CGSize {
        CGSize(width: plateWidth, height: targetHeight + tailHeight)
    }

    /// The annotation layer's one radius: a mark on a passage, the card
    /// carrying a note about it, and this bar are the same family of object.
    private static let shape = RoundedRectangle(
        cornerRadius: NotesEditingLayout.markRadius)
    /// The plate is the page's own blue-black lifted toward white and kept in
    /// palette by the accent, never a neutral grey. It has to read as a surface
    /// a control sits ON — a fill a shade off the page reads as a tint through
    /// it, and the enclosing frame then outshouts the only actionable thing
    /// inside it.
    private static let lift: Double = 0.10
    private static let plateBase: Double = 0.10
    /// The rule between the two targets carries the non-text 3:1 floor: below
    /// it the two targets read as one wide button.
    private static let dividerInk: Double = 0.20
    /// The label brightness: legible on the plate, never brighter than the body
    /// prose it floats over.
    private static let labelInk = Color(white: 0.74)

    /// The model rewrites the passage — the label says so, and says it apart
    /// from the header's deterministic name correction.
    static func title(_ kind: EditingTarget.Kind) -> String {
        switch kind {
        case .correct: return "AI Correct"
        case .note: return "Add Note"
        }
    }

    static func accessibilityLabel(_ kind: EditingTarget.Kind) -> String {
        switch kind {
        case .correct: return "AI Correct this text"
        case .note: return "Add a note about this text"
        }
    }

    private static func help(_ kind: EditingTarget.Kind) -> String {
        switch kind {
        case .correct: return "Say what is actually true; the model rewrites this passage"
        case .note: return "Write a note in the margin; the notes themselves are untouched"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if pointsUp { tail }
            plate
            if !pointsUp { tail.rotationEffect(.degrees(180)) }
        }
        .frame(width: Self.plateWidth, height: Self.size.height)
        // A container, so a label applied to the whole bar names the bar and
        // the two targets keep their own.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Actions for the selected text")
    }

    private var plate: some View {
        HStack(spacing: 0) {
            if NotesEditingEntry.offered(.correct, engineCanEditNotes: engineCanEditNotes) {
                actionTarget(.correct)
                // A seam between two targets, edge to edge. Short and bright it
                // reads as an insertion point, which is the one thing this
                // surface must never appear to offer.
                Rectangle()
                    .fill(.white.opacity(Self.dividerInk))
                    .frame(width: 1, height: Self.targetHeight)
                    .accessibilityHidden(true)
            }
            actionTarget(.note)
        }
        .frame(width: Self.plateWidth, height: Self.targetHeight)
        // Opaque: the bar is a plate over the page, never a tint through it.
        .background(Design.accent.opacity(Self.lift), in: Self.shape)
        .background(Color.white.opacity(Self.plateBase), in: Self.shape)
        .background(Design.listColumn, in: Self.shape)
        .overlay(Self.shape.strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 8, y: 3)
    }

    /// The tail: what makes the bar point at its own passage instead of merely
    /// sitting near it. It carries the plate's fill, so the two read as one
    /// object.
    private var tail: some View {
        Triangle()
            .fill(Design.listColumn)
            .overlay(Triangle().fill(Color.white.opacity(Self.plateBase)))
            .overlay(Triangle().fill(Design.accent.opacity(Self.lift)))
            .frame(width: Self.tailWidth, height: Self.tailHeight)
            .frame(width: Self.plateWidth, alignment: .leading)
            .offset(x: tailOffset - Self.tailWidth / 2)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func actionTarget(_ kind: EditingTarget.Kind) -> some View {
        let reason = NotesEditingEntry.disabledReason(kind, correctionEnabled: correctionEnabled)
        Button {
            onAction(kind)
        } label: {
            Text(Self.title(kind))
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(reason == nil ? Self.labelInk : Self.labelInk.opacity(0.42))
                .frame(maxWidth: .infinity)
                .frame(height: Self.targetHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(reason != nil)
        .help(reason ?? Self.help(kind))
        .accessibilityLabel(Self.accessibilityLabel(kind))
    }
}

/// The bar's tail, apex at the top edge.
private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Where the selection bar stands. The rules, in order: it never covers the
/// passage it acts on, it points at the first word of that passage, it stays
/// inside the reading measure, and it stays inside the pane the reader can see
/// — flipping above the selection when standing under it would put it below the
/// fold.
enum SelectionBarPlacement {
    /// The clearance between the bar and the line it belongs to.
    static let gap: CGFloat = 6
    /// How close to the pane's own edge the bar may stand.
    static let paneMargin: CGFloat = 10
    /// Where the tail sits along the bar when the bar is free to place itself,
    /// which is what the bar is offset by so the tail lands on the words.
    static let tailInset: CGFloat = 16

    struct Result: Equatable {
        /// The bar's origin in the BLOCK's coordinates.
        var origin: CGPoint
        /// True when the bar stands above the selection, so its tail points down.
        var above: Bool
        /// Where the tail sits along the bar, from the bar's leading edge.
        var tailOffset: CGFloat
    }

    /// - Parameters:
    ///   - selection: the selection's first and last line, in block coordinates.
    ///   - measure: the reading column's width, which the bar stays inside.
    ///   - blockTop: the block's own top in the visible pane.
    ///   - paneHeight: the height of the pane the reader can see.
    static func resolve(
        selection: SelectionFrame, measure: CGFloat, blockTop: CGFloat, paneHeight: CGFloat
    ) -> Result {
        let size = SelectionActionBar.size
        let below = selection.last.maxY + gap
        let above = selection.first.minY - gap - size.height
        // Standing under the passage is the default; it is given up only when
        // the bar would land off the bottom of the pane, and taken back when
        // standing above would land off the top.
        var isAbove = blockTop + below + size.height > paneHeight - paneMargin
        if isAbove, blockTop + above < paneMargin { isAbove = false }
        // The bar stands against the passage's last line when it is under it
        // and its first when above, but it always points at the passage's FIRST
        // character — the word the reader began the selection on is what names
        // the target.
        let x = min(max(selection.first.minX - tailInset, 0), max(measure - size.width, 0))
        // Past the plate's own rounded end at either edge, so the tail is never
        // a nick out of a corner.
        let tail = min(
            max(selection.first.minX - x, SelectionActionBar.tailWidth),
            size.width - SelectionActionBar.tailWidth)
        return Result(
            origin: CGPoint(x: x, y: isAbove ? above : below), above: isAbove, tailOffset: tail)
    }

    /// The bar's own frame, from a resolved placement.
    static func frame(_ result: Result) -> CGRect {
        CGRect(origin: result.origin, size: SelectionActionBar.size)
    }
}

// MARK: - The inline composer

/// Expands below the block, pushing content down. It states exactly what it
/// targets: the clipped verbatim quote under "About".
struct InlineComposer: View {
    var target: EditingTarget
    /// The section name, shown when the quote alone is ambiguous (a coarse
    /// placement, or a quote repeated in the notes).
    var sectionName: String?
    /// False while a run holds the meeting: the draft is kept, the commit
    /// control closes, and the reason stays reachable.
    var commitEnabled: Bool
    /// True once the block this was opened on has left the notes: the composer
    /// presents off its retained quote instead of disappearing with the prose.
    var orphaned = false
    /// Held by the pane, not by this view: a re-synthesis that removes the
    /// composing block takes this view out of the tree, and the draft must not
    /// go with it.
    @Binding var userText: String
    var onCancel: () -> Void
    var onSubmit: (String) -> Void

    @FocusState private var focused: Bool

    /// What the empty field asks for, shown in the field itself.
    static func prompt(_ kind: EditingTarget.Kind) -> String {
        switch kind {
        case .note: return "Your note"
        case .correct: return "What is actually true?"
        }
    }

    private var isNote: Bool { target.kind == .note }

    private var trimmed: String {
        userText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var disabledReason: String? {
        NotesEditingEntry.disabledReason(target.kind, correctionEnabled: commitEnabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            CardKindLabel(text: isNote ? "Note on" : "Correcting")

            // The composer is the one place the quote is always cited: it is
            // stating what the action will target, not repeating something the
            // reader is already looking at.
            AnchorQuote(quote: target.displayQuote, limit: 90)

            if let sectionName {
                Text(sectionName)
                    .font(.system(size: 10))
                    .foregroundStyle(.quaternary)
            }
            if orphaned {
                Text("The notes no longer contain this passage — what you write still names it.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // A hairline, not a second container: the field is part of this
            // card's plane, and a box inside a box is the surface saying the
            // same thing twice.
            Rectangle()
                .fill(.white.opacity(0.10))
                .frame(height: 1)
                .accessibilityHidden(true)

            TextEditor(text: $userText)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .frame(minHeight: 54, maxHeight: 108)
                // The prompt is on screen, not only in the accessibility tree:
                // a sighted user is told what to type, same as anyone else.
                .overlay(alignment: .topLeading) {
                    if userText.isEmpty {
                        Text(Self.prompt(target.kind))
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 1)
                            .allowsHitTesting(false)
                    }
                }
                .focused($focused)
                .accessibilityLabel(Self.prompt(target.kind))

            HStack(spacing: 8) {
                if let disabledReason {
                    Text(disabledReason)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(isNote ? "Add note" : "Correct") { onSubmit(trimmed) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed.isEmpty || disabledReason != nil)
                    .help(disabledReason ?? "")
            }
        }
        .padding(11)
        .annotationCard()
        // Escape closes the composer wherever focus sits inside it — the Cancel
        // button's key equivalent only fires while the button chain has it.
        .onExitCommand(perform: onCancel)
        // The caret is claimed after the composer has finished arriving: the
        // page's own read-only text hosts are text views too, and focus
        // asserted while this one is still being inserted loses to whichever of
        // them the responder chain is holding.
        .task {
            try? await Task.sleep(for: .milliseconds(140))
            focused = true
        }
    }
}

// MARK: - The pending row

/// The card a submitted correction collapses into: kind, the person's own
/// statement, honest status. It stays under the block until the rewrite
/// completes, then dissolves.
///
/// It is the only mark in the reading column that sits on a plate, and the plate
/// carries a shadow so it reads as resting on the page rather than set in it —
/// which is what it is: work the notes have not done yet. Everything about it is
/// interface rather than prose. The statement is not quoted: these are the
/// reader's words, not a citation of the notes.
struct PendingInstructionRow: View {
    var statement: String
    var status: PendingRowStatus

    private static let style = AnnotationKindStyle.correction

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                CardKindLabel(text: "Correction")
                Spacer(minLength: 6)
                PendingStatusMarker(status: status)
            }
            Text(NotesEditingText.clip(statement))
                .font(Self.style.body)
                .foregroundStyle(.primary.opacity(Self.style.bodyInk))
                .lineLimit(2)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .annotationCard()
        // A plate lifted off the page. Without it the fill reads as a tint set
        // into the column, which is the one thing a pending instruction is not.
        .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Correction \u{201C}\(statement)\u{201D}, \(status.label)")
    }
}

/// The state a correction is in: the word, and a marker whose SHAPE carries the
/// same thing — a ring while it waits, a filled disc while a run is applying it.
/// One hue at two alphas is not a distinction; a ring and a disc are.
struct PendingStatusMarker: View {
    var status: PendingRowStatus

    /// The marker's diameter. Small enough to read as a state light beside a
    /// word rather than as a bullet in front of one.
    private static let diameter: CGFloat = 6

    var body: some View {
        HStack(spacing: 5) {
            Group {
                switch status {
                case .pending:
                    Circle().strokeBorder(Design.accent.opacity(0.85), lineWidth: 1.2)
                case .applying:
                    Circle().fill(Design.accent.opacity(0.85))
                }
            }
            .frame(width: Self.diameter, height: Self.diameter)
            Text(status.label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Margin-note presentations

/// A margin note under its anchored block (the `inline` Setting, and the
/// expanded state of the narrow chip).
///
/// It draws no plane. A note is the person's own content — it survives every
/// rewrite and it exports with the notes — so it is set the way a document sets
/// an aside: a rule at the leading edge, reading type at reading contrast, an
/// italic byline saying whose voice it is. The anchor citation comes after the
/// words and only where the note is not already standing against the line it is
/// about.
///
/// The rail presentation of the same note is the same object — rule, byline,
/// prose — so the placement Setting changes where a note sits, never what it is.
struct InlineNoteCard: View {
    var note: MarginNoteViewModel
    var portuguese: Bool
    var pinBlocks: [String] = []
    var pinDisabled = false
    var onPin: ((Int) -> Void)?

    private static let style = AnnotationKindStyle.note
    /// The rule's own width, and the space between it and the words. Wide enough
    /// to read as a mark down the side of the passage, never as a border.
    private static let ruleWidth: CGFloat = 2
    private static let ruleGap: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(portuguese ? "Sua nota" : "Your note")
                .font(Design.readingFont(10.5).italic())
                .foregroundStyle(.secondary)
            Text(note.text)
                .font(Self.style.body)
                .foregroundStyle(.primary.opacity(Self.style.bodyInk))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if note.showsQuote, !note.quotedText.isEmpty {
                AnchorQuote(quote: note.quotedText, limit: 56)
                    .padding(.top, 1)
            }
            if note.isStale {
                Text(portuguese ? "Âncora ausente" : "Anchor missing")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                MarginNotePinMenu(
                    blocks: pinBlocks, disabled: pinDisabled, portuguese: portuguese, onPin: onPin)
            }
        }
        .padding(.leading, Self.ruleWidth + Self.ruleGap)
        .padding(.vertical, 2)
        .frame(maxWidth: NotesEditingLayout.asideMeasure, alignment: .leading)
        .overlay(alignment: .leading) {
            Capsule()
                .fill(Design.support.opacity(AnnotationKindStyle.ruleAlpha))
                .frame(width: Self.ruleWidth)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityLabel(note, portuguese: portuguese))
    }

    /// The card reads aloud the way it reads on screen: whose note, which
    /// words, then the note.
    static func accessibilityLabel(_ note: MarginNoteViewModel, portuguese: Bool) -> String {
        let label = portuguese ? "Sua nota" : "Your note"
        guard note.showsQuote, !note.quotedText.isEmpty else { return "\(label): \(note.text)" }
        let on = portuguese ? "sobre" : "on"
        return "\(label) \(on) \u{201C}\(note.quotedText)\u{201D}: \(note.text)"
    }
}

/// A margin note in the right-hand rail: the same object the inline placement
/// draws — rule, italic byline, prose — a step quieter because it sits outside
/// the reading measure. Nothing about it answers the pointer: the rail reads the
/// same whether the pointer is over it or across the room.
struct MarginRailNote: View {
    var note: MarginNoteViewModel
    var portuguese: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(portuguese ? "Sua nota" : "Your note")
                .font(Design.readingFont(10).italic())
                .foregroundStyle(.secondary)
            Text(note.text)
                .font(Design.readingFont(12))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if note.showsQuote {
                Text("\u{201C}\(NotesEditingText.clip(note.quotedText, limit: 48))\u{201D}")
                    .font(.system(size: 10))
                    .foregroundStyle(.quaternary)
                    .lineLimit(2)
            }
            if note.isStale {
                Text(portuguese ? "Âncora ausente" : "Anchor missing")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.leading, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            Capsule()
                .fill(Design.support.opacity(AnnotationKindStyle.ruleAlpha))
                .frame(width: 2)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(portuguese ? "Sua nota" : "Your note"): \(note.text)")
    }
}

/// The narrow margin mode's fallback: an always-visible chip at the block end
/// that expands the note in place. The only chip in the design.
struct MarginNoteChip: View {
    var count: Int
    var expanded: Bool
    var portuguese: Bool
    var onToggle: () -> Void

    /// The chip is the whole way into a note wherever the rail does not fit, so
    /// it carries the same floor as any other target: under 22 points is not a
    /// control.
    nonisolated static let targetHeight: CGFloat = 22

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 5) {
                Circle()
                    .fill(Design.support.opacity(0.9))
                    .frame(width: 5, height: 5)
                Text(label)
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 9)
            .frame(height: Self.targetHeight)
            .foregroundStyle(Design.support)
            .contentShape(Capsule())
            .overlay(Capsule().strokeBorder(Design.support.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(expanded ? "Hide \(label)" : "Show \(label)")
    }

    private var label: String {
        if portuguese { return count == 1 ? "1 nota" : "\(count) notas" }
        return count == 1 ? "1 note" : "\(count) notes"
    }
}

/// The way back from a lost anchor: pin the note next to a paragraph that still
/// exists. Nothing else in the app re-anchors a note.
private struct MarginNotePinMenu: View {
    var blocks: [String]
    var disabled: Bool
    var portuguese: Bool
    var onPin: ((Int) -> Void)?

    var body: some View {
        if !blocks.isEmpty, let onPin {
            Menu(portuguese ? "Fixar em um texto…" : "Pin to text…") {
                ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                    Button(NotesEditingText.clip(block, limit: 60)) { onPin(index) }
                }
            }
            .menuStyle(.borderlessButton)
            .font(.system(size: 11))
            .fixedSize()
            .disabled(disabled)
        }
    }
}

// MARK: - The Changes overview

/// The one surface that answers "what have I flagged on this meeting": a card
/// per annotation carrying its anchor, its body and its age, a filter that
/// reads its value in words, and — the point of an overview — a way back to the
/// passage each card belongs to.
struct ChangesPanel: View {
    var rows: [MeetingCorrection]
    var runActive: Bool
    var busy: Bool
    /// Whether the selected summarization engine can edit notes. False keeps
    /// every row listed and manageable and withdraws only the send action.
    var engineCanEditNotes: Bool
    /// The rows the person has put away. A processed correction resolves itself
    /// on the evidence of the rewrite; a note resolves only because they said
    /// so, so its resolved set is the caller's to keep.
    var resolvedIDs: Set<String> = []
    /// The blocks a stale row can be pinned back onto, in its own section.
    var pinTargets: (MeetingCorrection) -> [String]
    /// Go to the passage this row is anchored to, and confirm it there.
    var onNavigate: (MeetingCorrection) -> Void = { _ in }
    var onResolve: (MeetingCorrection, Bool) -> Void = { _, _ in }
    var onDelete: (MeetingCorrection) -> Void
    var onEdit: (MeetingCorrection, String) -> Void
    var onPin: (MeetingCorrection, Int) -> Void
    var onSend: () -> Void

    @State private var filter: ChangesFilter = .open

    /// The list scrolls past this: a meeting's annotations have no upper bound,
    /// and a popover taller than the screen puts its own cards — and the
    /// rewrite action below them — out of reach.
    private static let listMaxHeight: CGFloat = 420

    private var visible: [MeetingCorrection] {
        changesRows(rows, filter: filter, resolvedIDs: resolvedIDs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Changes")
                    .font(.system(size: 13, weight: .bold))
                Spacer(minLength: 0)
                Picker("Show", selection: $filter) {
                    ForEach(ChangesFilter.allCases) { value in
                        Text(value.label).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Show")
            }

            if rows.isEmpty {
                Text("Nothing yet. Select any line in the notes to correct it, or add a note.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        // The ruler: every row, drawn hidden. A popover cannot
                        // grow back after it is presented, so the height must
                        // not depend on which half the filter is showing —
                        // otherwise switching to the emptier half strands the
                        // other half's cards in a collapsed panel.
                        cards(rows)
                            .hidden()
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                        if visible.isEmpty {
                            Text(filter.emptyLabel)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        } else {
                            cards(visible)
                        }
                    }
                }
                .frame(maxHeight: Self.listMaxHeight)
            }

            if notesEditorSendOffered(rows: rows, engineCanEditNotes: engineCanEditNotes) {
                Button {
                    onSend()
                } label: {
                    Label(
                        busy || runActive
                            ? NotesEditorPanelCopy.busyLabel : NotesEditorPanelCopy.actionLabel,
                        systemImage: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .disabled(busy || runActive)
                .help(NotesEditorPanelCopy.help)
            }
        }
        .padding(14)
        .frame(width: 380)
        // The popover is its own window, so the pane's own configurator never
        // reaches this list.
        .transientScrollIndicators()
    }

    @ViewBuilder
    private func cards(_ list: [MeetingCorrection]) -> some View {
        LazyVStack(alignment: .leading, spacing: 6) {
            ForEach(list, id: \.id) { row in
                ChangesCard(
                    row: row,
                    status: changesRowStatus(row, runActive: runActive),
                    resolved: changesRowIsResolved(row, resolvedIDs: resolvedIDs),
                    busy: busy, runActive: runActive,
                    pinBlocks: changesRowCanPin(row) ? pinTargets(row) : [],
                    onNavigate: { onNavigate(row) },
                    onResolve: { onResolve(row, $0) },
                    onEdit: { onEdit(row, $0) },
                    onDelete: { onDelete(row) },
                    onPin: { onPin(row, $0) })
            }
        }
    }
}

enum NotesEditorPanelCopy {
    static let actionLabel = "Send to Notes Editor"
    static let busyLabel = "Applying…"
    static let help = "Sends every pending correction to the Notes Editor"
}

/// Whether the selected summarization engine can edit notes at all. Derived
/// from the live selection each time it is asked — nothing is stored — so a
/// Settings change reaches the surface without a relaunch. It asks the same
/// resolution rule a run asks, substitution included: an id that is no longer
/// registered resolves to a substitute, and what THAT engine can do is what the
/// pass would actually do.
func notesEditingEngineCanEdit(
    selectedSummarizationID: String, registry: EngineRegistry
) -> Bool {
    EngineResolver.resolveSummarization(id: selectedSummarizationID, registry: registry)?
        .engine is any NotesEditingEngine
}

/// Whether the immediate-send action stands, asked identically by both of its
/// placements: a correction is waiting for the editor, and the selected engine
/// can edit notes at all.
func notesEditorSendOffered(rows: [MeetingCorrection], engineCanEditNotes: Bool) -> Bool {
    engineCanEditNotes
        && rows.contains { $0.kind == .understanding && $0.status == .pending }
}

/// One annotation as the overview presents it: what it is anchored to, what it
/// says, when it was written, and what can be done about it. The whole reading
/// half is the way back to the passage.
private struct ChangesCard: View {
    var row: MeetingCorrection
    var status: String
    var resolved: Bool
    var busy: Bool
    var runActive: Bool
    var pinBlocks: [String]
    var onNavigate: () -> Void
    var onResolve: (Bool) -> Void
    var onEdit: (String) -> Void
    var onDelete: () -> Void
    var onPin: (Int) -> Void

    @State private var editing = false
    @State private var draft = ""

    private var kindName: String { row.kind == .understanding ? "Correction" : "Note" }

    /// The overview is a list of objects, so every row keeps the list's own
    /// card. What travels here from the reading surface is the type: a note's
    /// words are content and are set as prose, a correction's describe pending
    /// work and are set as interface text.
    private var style: AnnotationKindStyle {
        row.kind == .understanding ? .correction : .note
    }

    /// An applied correction is resolved by the editor operation that changed
    /// bytes for it — there is nothing for the person to put away or take back.
    private var lifecycleIsTheirs: Bool {
        !(row.kind == .understanding && row.status == .applied)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button(action: onNavigate) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        CardKindLabel(text: kindName)
                        Spacer(minLength: 0)
                        Text(status)
                            .font(.system(size: 11))
                            .foregroundStyle(statusTint)
                    }
                    // The overview is the one surface where a card is NOT beside
                    // its anchor — the citation is the only thing saying which
                    // passage it belongs to, so it is always drawn here.
                    if !editing {
                        Text(row.userText)
                            .font(style.body)
                            .foregroundStyle(.primary.opacity(style.bodyInk))
                            .lineLimit(4)
                    }
                    AnchorQuote(quote: row.quotedText, limit: 70)
                    Text(changesRowTimestamp(row))
                        .font(.system(size: 10))
                        .foregroundStyle(.quaternary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Go to this passage in the notes")
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(kindName) on \u{201C}\(row.quotedText)\u{201D}: \(row.userText). \(status)")
            .accessibilityHint("Go to this passage in the notes")

            if editing { editor }

            HStack(spacing: 8) {
                if lifecycleIsTheirs {
                    Button(resolved ? "Reopen" : "Resolve") { onResolve(!resolved) }
                        .disabled(changesRowResolveDisabled(
                            row, resolved: resolved, runActive: runActive, busy: busy))
                        .help(resolved
                            ? "Puts this back among the open ones"
                            : "Puts this away — it stays reachable under Resolved")
                }
                Spacer(minLength: 0)
                Menu {
                    Button("Edit\u{2026}") {
                        draft = row.userText
                        editing = true
                    }
                    .disabled(changesRowEditDisabled(row, runActive: runActive, busy: busy))
                    Divider()
                    Button(deleteTitle, role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                // A real target, not a glyph: the menu carries the card's
                // secondary actions and has to be hittable without aim.
                .controlSize(.extraLarge)
                .fixedSize()
                .disabled(busy)
                .help(deleteTitle)
                .accessibilityLabel("More actions for this \(kindName.lowercased())")
            }

            if !pinBlocks.isEmpty {
                MarginNotePinMenu(
                    blocks: pinBlocks, disabled: runActive || busy, portuguese: false,
                    onPin: onPin)
            }
        }
        .padding(9)
        // The popover already states this card's width; the card grammar
        // supplies its plane and its radius.
        .annotationCard(measure: nil)
        // The overview is a list, so every row keeps the list's card — but the
        // note's own mark comes with it, or the one place the two kinds sit
        // touching is the one place they look alike.
        .overlay(alignment: .leading) {
            if style.hasLeadingRule {
                Capsule()
                    .fill(Design.support.opacity(AnnotationKindStyle.ruleAlpha))
                    .frame(width: 2)
                    .padding(.vertical, 6)
                    .accessibilityHidden(true)
            }
        }
    }

    private var statusTint: AnyShapeStyle {
        switch row.status {
        case .stale: return AnyShapeStyle(.orange)
        case .pending where row.kind == .understanding && runActive:
            return AnyShapeStyle(Design.accent)
        default: return AnyShapeStyle(.secondary)
        }
    }

    /// Deleting is never labelled Undo: nothing is reverted byte-wise.
    private var deleteTitle: String {
        if row.kind == .annotation { return "Delete note" }
        return row.status == .applied ? "Delete — later rewrites run without it" : "Delete correction"
    }

    @ViewBuilder
    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .lineLimit(2...5)
                .accessibilityLabel("Edit this \(kindName.lowercased())")
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel") { editing = false }
                Button("Save") {
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    editing = false
                    onEdit(text)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    busy
                        || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || draft.trimmingCharacters(in: .whitespacesAndNewlines) == row.userText)
            }
        }
    }
}

// MARK: - Text helpers

enum NotesEditingText {
    /// One calm line: line breaks folded, clipped with an ellipsis. The full
    /// text is always somewhere the reader can reach.
    static func clip(_ text: String, limit: Int = 90) -> String {
        let flat = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return flat.count > limit ? flat.prefix(limit - 1) + "…" : flat
    }
}
