import Foundation
import GRDB

// Span-anchored user corrections and margin notes on a finished meeting.
// One durable row per correction/note; every synthesis run re-reads the
// meeting's rows (a later full Regenerate can never erase user truth — the
// core commitment). Anchoring is quote + section + occurrence, never
// character offsets (offsets die on every re-synthesis).

public struct MeetingCorrection: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "meeting_correction"

    public enum Kind: String, Codable, Sendable {
        /// The notes misunderstood something; re-synthesis consumes the row
        /// as authoritative context.
        case understanding
        /// A user-authored margin note; rendered deterministically, no engine.
        case annotation
    }

    /// Which notes section the quote was taken from. Matches the
    /// `NotesStructured` field the block came from.
    public enum Section: String, Codable, Sendable {
        case summary
        case detailedNotes = "detailed_notes"
        case decision
        case actionItem = "action_item"
        /// The reader's OWN action items. Their own anchor space: the two
        /// action-item lists are separate, so a quote taken from one must never
        /// resolve into the other.
        case userActionItem = "user_action_item"
    }

    public enum Status: String, Codable, Sendable {
        /// Written, not yet reflected in the current notes.
        case pending
        /// A synthesis run consumed it (understanding) / the anchor currently
        /// fold-matches a block (annotation).
        case applied
        /// An annotation whose anchor no longer matches any block — renders
        /// under "Your notes", never silently dropped.
        case stale
        /// The person put the row away in the overview. Only they set it and
        /// only they take it back: no automatic pass may recompute over it,
        /// or their answer lasts exactly one synthesis run.
        case resolved
    }

    public var id: String
    public var meetingID: MeetingID
    public var kind: Kind
    public var section: Section
    /// The (possibly user-trimmed) span of the notes the row is anchored to.
    public var quotedText: String
    /// Which fold-match within the section this anchor means (0-based) when
    /// the quote matches more than one block.
    public var occurrence: Int
    /// The correction ("what's actually true") or the note body.
    public var userText: String
    public var status: Status
    public var createdAt: Date
    public var appliedAt: Date?

    public init(
        id: String = ULID.generate(),
        meetingID: MeetingID,
        kind: Kind,
        section: Section,
        quotedText: String,
        occurrence: Int = 0,
        userText: String,
        status: Status = .pending,
        createdAt: Date,
        appliedAt: Date? = nil
    ) {
        self.id = id
        self.meetingID = meetingID
        self.kind = kind
        self.section = section
        self.quotedText = quotedText
        self.occurrence = occurrence
        self.userText = userText
        self.status = status
        self.createdAt = createdAt
        self.appliedAt = appliedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, section, occurrence, status
        case meetingID = "meeting_id"
        case quotedText = "quoted_text"
        case userText = "user_text"
        case createdAt = "created_at"
        case appliedAt = "applied_at"
    }
}

/// CRUD + status transitions. All calls run inside the caller's GRDB
/// transaction (the pipeline's mutation paths already own one).
public enum MeetingCorrectionStore {
    /// All rows for a meeting, stable display order (creation, then id).
    public static func all(_ db: Database, meetingID: MeetingID) throws -> [MeetingCorrection] {
        try MeetingCorrection
            .filter(Column("meeting_id") == meetingID)
            .order(Column("created_at"), Column("id"))
            .fetchAll(db)
    }

    public static func insert(_ db: Database, _ row: MeetingCorrection) throws {
        try row.insert(db)
    }

    /// Edit of an existing row (correction management, note pinning). The
    /// status is the caller's decision — `ProcessingPipeline.updateCorrection`
    /// returns understanding rows to `pending` (the edit is not yet reflected
    /// in the notes) and leaves an annotation's status alone.
    public static func update(
        _ db: Database, id: String,
        quotedText: String, occurrence: Int, userText: String, status: MeetingCorrection.Status,
        createdAt: Date? = nil
    ) throws {
        if let createdAt {
            try db.execute(
                sql: """
                    UPDATE meeting_correction
                    SET quoted_text = ?, occurrence = ?, user_text = ?, status = ?, created_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    quotedText, occurrence, userText, status.rawValue, createdAt, id,
                ])
        } else {
            try db.execute(
                sql: """
                    UPDATE meeting_correction
                    SET quoted_text = ?, occurrence = ?, user_text = ?, status = ?
                    WHERE id = ?
                    """,
                arguments: [quotedText, occurrence, userText, status.rawValue, id])
        }
    }

    /// Deletion IS the undo path: a deleted understanding row is simply
    /// absent from the next synthesis run.
    public static func delete(_ db: Database, id: String) throws {
        _ = try MeetingCorrection.filter(Column("id") == id).deleteAll(db)
    }

    /// Flips the consumed understanding rows after a successful synthesis run.
    public static func markApplied(_ db: Database, ids: [String], at now: Date) throws {
        guard !ids.isEmpty else { return }
        try db.execute(
            sql: """
                UPDATE meeting_correction SET status = 'applied', applied_at = ?
                WHERE id IN (\(ids.map { _ in "?" }.joined(separator: ",")))
                """,
            arguments: StatementArguments([now] + ids))
    }

    /// Rewrites anchor quotes in place, keyed by row id. A deterministic name
    /// correction applies to the ANCHORS as well as the prose — a note hung on
    /// a sentence is about the sentence, not its spelling. Sorted for a
    /// deterministic statement order.
    public static func applyQuoteRewrites(_ db: Database, rewrites: [String: String]) throws {
        for (id, quote) in rewrites.sorted(by: { $0.key < $1.key }) {
            try db.execute(
                sql: "UPDATE meeting_correction SET quoted_text = ? WHERE id = ?",
                arguments: [quote, id])
        }
    }

    /// The overview's Resolve / Reopen: the person's own lifecycle answer,
    /// written where a run cannot forget it.
    public static func setStatus(
        _ db: Database, id: String, status: MeetingCorrection.Status,
        createdAt: Date? = nil
    ) throws {
        if let createdAt {
            try db.execute(
                sql: "UPDATE meeting_correction SET status = ?, created_at = ? WHERE id = ?",
                arguments: [status.rawValue, createdAt, id])
        } else {
            try db.execute(
                sql: "UPDATE meeting_correction SET status = ? WHERE id = ?",
                arguments: [status.rawValue, id])
        }
    }

    /// The chronological-log restamp for an edited or reopened understanding.
    /// The caller invokes this from the SAME write transaction as the mutation.
    public static func strictlyLatestCreatedAt(
        _ db: Database, meetingID: MeetingID, now: Date
    ) throws -> Date {
        let currentMaximum = try Date.fetchOne(
            db,
            sql: "SELECT MAX(created_at) FROM meeting_correction WHERE meeting_id = ?",
            arguments: [meetingID])
        guard let currentMaximum else { return now }
        return max(now, currentMaximum.addingTimeInterval(0.001))
    }

    public static func hasPendingUnderstanding(
        _ db: Database, meetingID: MeetingID
    ) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM meeting_correction
                    WHERE meeting_id = ? AND kind = 'understanding' AND status = 'pending'
                )
                """,
            arguments: [meetingID]) ?? false
    }

    public static func meetingIDsWithPendingUnderstanding(_ db: Database) throws -> [MeetingID] {
        try String.fetchAll(
            db,
            sql: """
                SELECT DISTINCT meeting_id FROM meeting_correction
                WHERE kind = 'understanding' AND status = 'pending'
                ORDER BY meeting_id
                """)
    }

    /// Applies a re-anchoring pass result (annotation rows only).
    public static func applyReanchor(
        _ db: Database, updates: [CorrectionAnchoring.Update]
    ) throws {
        for update in updates {
            try db.execute(
                sql: "UPDATE meeting_correction SET occurrence = ?, status = ? WHERE id = ?",
                arguments: [update.occurrence, update.status.rawValue, update.id])
        }
    }

    /// The annotation-mutation companion write, run INSIDE the mutation's own
    /// transaction: the delivery debt is durable the moment the annotation row
    /// changes (a crash before the follow-on re-mint still leaves the debt
    /// recorded), and `meeting.updatedAt` moves strictly forward so the eventual
    /// settled payload can never ride a stale `updated_at_ms`.
    public static func recordAnnotationMutation(
        _ db: Database, meetingID: MeetingID, proposedTimestamp: Date
    ) throws {
        try db.execute(
            sql: "UPDATE meeting_notes SET delivery_owed = 1 WHERE meeting_id = ?",
            arguments: [meetingID])
        guard let live = try Meeting.fetchOne(db, key: meetingID) else { return }
        let timestamp = max(proposedTimestamp, live.updatedAt.addingTimeInterval(0.001))
        try db.execute(
            sql: "UPDATE meeting SET updated_at = ? WHERE id = ?",
            arguments: [timestamp, meetingID])
    }
}

/// What a correction write actually accomplished. The row is always durable;
/// `remintRefused` says the deterministic re-mint an ANNOTATION needs could
/// not run (meeting not ready, or notes-pending), so notes.md and the
/// delivered payload do not carry it yet — the next content run weaves it
/// instead. The UI must say that rather than imply the change already shipped.
public struct CorrectionWriteResult: Sendable, Equatable {
    public var row: MeetingCorrection
    public var remintRefused: Bool

    public init(row: MeetingCorrection, remintRefused: Bool) {
        self.row = row
        self.remintRefused = remintRefused
    }
}

/// The single-line fold for USER-authored correction text and the quotes that
/// travel with it.
///
/// Deliberately separate from `NotesRenderer.flattenToTitleLine`: that one
/// owns TITLE bytes for every meeting (including the ones with no corrections
/// at all) and strips a leading `#` run, which is title semantics. This one
/// collapses EVERY Unicode line break — LF/CR/CRLF plus U+000B, U+000C,
/// U+0085, U+2028 and U+2029, which end a line for renderers that are not
/// strictly CommonMark and for the synthesis prompt alike. Two escapes close
/// with it: a note escaping its `>` blockquote in notes.md, and a quote or
/// correction body forging an extra numbered entry inside the prompt's
/// AUTHORITATIVE corrections block.
///
/// Punctuation is left exactly as the user typed it: nothing here delimits
/// anything in the rendered markdown, and `5"` must still mean five inches in
/// the human artifact. The prompt's own delimiter hardening is `promptField`.
///
/// A leading `#` is deliberately NOT stripped: inline after our
/// "**Your note:** " prefix it is inert, and stripping it would silently eat
/// the body of a note that is legitimately just "### TODO".
enum CorrectionSanitize {
    static func flatten(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\r\n", with: " ")
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// The fold PLUS the prompt-only delimiter hardening, for the two
    /// interpolations of the synthesis prompt's corrections block and nowhere
    /// else. The ASCII double quote (U+0022) DELIMITS the quoted draft text
    /// there, so a user quote carrying one would end its own data position
    /// mid-line and continue as prompt prose — enough to forge a second "The
    /// user corrects:" directive inside the block the prompt labels
    /// authoritative, with no line break needed.
    ///
    /// The map is per Unicode SCALAR, not per Character: `"` followed by a
    /// combining mark, a variation selector or a joiner is ONE extended
    /// grapheme cluster, and a Character- or substring-level replacement does
    /// not match a search string covering only part of a cluster — the quote
    /// would survive into the prompt. U+201D reads as a closing quote (and as
    /// inches) for the model and closes no ASCII delimiter.
    static func promptField(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in flatten(raw).unicodeScalars {
            scalars.append(scalar == "\"" ? "\u{201D}" : scalar)
        }
        return String(scalars)
    }
}

/// The pure anchoring discipline shared by the renderer, the re-anchor pass,
/// and the UI: a quote matches a block when the folded block CONTAINS the
/// folded quote; `occurrence` selects among multiple matching blocks.
public enum CorrectionAnchoring {
    public struct Update: Equatable, Sendable {
        public var id: String
        public var occurrence: Int
        public var status: MeetingCorrection.Status
        public init(id: String, occurrence: Int, status: MeetingCorrection.Status) {
            self.id = id
            self.occurrence = occurrence
            self.status = status
        }
    }

    /// Case-, whitespace- and markdown-token-insensitive fold. The UI quotes
    /// PLAIN rendered text (AttributedString markdown parsing strips `**`/`_`
    /// etc.) while the structured source carries raw markdown — stripping
    /// inline tokens on BOTH sides lets a plain quote match styled source.
    /// Deliberately NOT the name-store's `canonicalMode` (word semantics):
    /// prose matching needs only case + whitespace + syntax tolerance.
    public static func fold(_ s: String) -> String {
        let stripped = String(s.unicodeScalars.filter { !Self.markdownTokens.contains($0) })
        return stripped.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Inline markdown syntax scalars ignored by the fold (emphasis, code,
    /// links, headings, blockquotes).
    private static let markdownTokens = Set("*_`~[]()>#".unicodeScalars)

    /// The anchorable blocks of each section, in render order. Detailed notes
    /// split on blank lines (the same paragraph granularity the UI presents);
    /// action-item blocks are the item TEXTS (owners are chips, not prose).
    public static func blocks(
        of structured: NotesStructured, section: MeetingCorrection.Section
    ) -> [String] {
        switch section {
        case .summary:
            return [structured.summary]
        case .detailedNotes:
            return structured.detailedNotes
                .replacingOccurrences(of: "\r\n", with: "\n")
                .components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        case .decision:
            return structured.decisions
        case .actionItem:
            return structured.actionItems.map(\.text)
        case .userActionItem:
            return structured.userActionItems.map(\.text)
        }
    }

    /// The separator joining the haystack's components. Every component is
    /// stripped of it before folding, so it is provably out-of-band whatever
    /// the notes or a quote contain, and a needle can never match across a
    /// component boundary.
    private static let haystackSeparator: Unicode.Scalar = "\u{1F}"

    private static func withoutHaystackSeparator(_ s: String) -> String {
        String(s.unicodeScalars.filter { $0 != haystackSeparator })
    }

    /// The fold of a document's installable text surfaces, joined by U+001F:
    /// the EFFECTIVE H1, the five anchorable sections' blocks, then
    /// action-item and user-action-item owners. Wider than the anchorable
    /// sections on purpose: the H1 and the owner fields are installable
    /// destinations too, so a claim reappearing in one of them would install
    /// under a sections-only search.
    ///
    /// The effective H1 is chosen by THE RENDERER'S OWN predicate — the
    /// structured title joins unless `NotesRenderer.flattenToTitleLine(title)`
    /// is EMPTY, in which case `meetingTitle` joins (the renderer flattens
    /// FIRST, so a "###" title falls back even though it is non-blank after
    /// trimming). The raw structured title may join unflattened, because
    /// `fold(x) == fold(flattenToTitleLine(x))` — the flatten strips only what
    /// the fold strips; the PREDICATE is the sole divergence, and it is the
    /// renderer's, called rather than approximated. A shadowed `meetingTitle`
    /// stays out: it renders nowhere, and counting it present would let it
    /// mask a resurrection into the body.
    ///
    /// Every component is STRIPPED of U+001F at the scalar level and THEN
    /// folded — strip first, so a stripped separator can never leave a
    /// two-space seam the fold would have collapsed.
    public static func foldedHaystack(
        of notes: NotesStructured, meetingTitle: String
    ) -> String {
        let structuredTitle = notes.title ?? ""
        let effectiveTitle =
            NotesRenderer.flattenToTitleLine(structuredTitle).isEmpty
            ? meetingTitle : structuredTitle
        var components = [effectiveTitle]
        for section: MeetingCorrection.Section in [
            .summary, .detailedNotes, .decision, .actionItem, .userActionItem,
        ] {
            components.append(contentsOf: blocks(of: notes, section: section))
        }
        components.append(contentsOf: notes.actionItems.map(\.owner))
        components.append(contentsOf: notes.userActionItems.map(\.owner))
        return components
            .map { fold(withoutHaystackSeparator($0)) }
            .joined(separator: String(haystackSeparator))
    }

    /// The withdrawn-claim containment core: one row, one containment, one
    /// semantics. Both public entry points below delegate here, so the
    /// regeneration gate and the payload derivation cannot fork.
    ///
    /// Kind-filtered exactly like the injection (annotations never withdraw)
    /// and status-blind: a PENDING row whose quote an earlier pass erased
    /// belongs in the set, because the quote bytes are the erased wrong text
    /// whatever the row's bookkeeping says. Occurrence is irrelevant —
    /// absence is document-wide. A quote whose fold is empty never enters.
    private static func isWithdrawn(
        _ row: MeetingCorrection, currentHaystack: String
    ) -> Bool {
        guard row.kind == .understanding else { return false }
        let needle = fold(withoutHaystackSeparator(row.quotedText))
        return !needle.isEmpty && !currentHaystack.contains(needle)
    }

    /// Understanding ROWS whose stripped-then-folded quote is NOT contained in
    /// `currentHaystack` — the withdrawn-claim set carrying each row's own
    /// identity and timestamp, which a claim-level record needs and the
    /// quoted-text form cannot supply.
    public static func withdrawnRows(
        corrections: [MeetingCorrection], currentHaystack: String
    ) -> [MeetingCorrection] {
        corrections.filter { isWithdrawn($0, currentHaystack: currentHaystack) }
    }

    /// Quoted texts of the withdrawn rows — the same set, projected: what an
    /// earlier editor pass erased from the notes.
    public static func withdrawnClaims(
        corrections: [MeetingCorrection], currentHaystack: String
    ) -> [String] {
        withdrawnRows(corrections: corrections, currentHaystack: currentHaystack)
            .map(\.quotedText)
    }

    /// The first withdrawn claim whose stripped-then-folded quote IS contained
    /// in `candidateHaystack`, or nil: one containment per withdrawn claim
    /// over the pre-built haystack.
    ///
    /// Containment is plain Swift `contains` — canonical-equivalence matching,
    /// for parity with `matches` above, whose predicate this extends. It errs
    /// toward CATCHING a resurrection that differs only in normalization.
    public static func resurrectedClaim(
        withdrawn: [String], candidateHaystack: String
    ) -> String? {
        withdrawn.first { candidateHaystack.contains(fold(withoutHaystackSeparator($0))) }
    }

    /// A block list carrying the folds every anchoring question compares
    /// against, computed once here. One render pass asks the same list many
    /// questions — one per block, one per row — and folding the list for each
    /// of them is quadratic in the list's length; sharing this value makes the
    /// folding linear. The folds are derived from the blocks at init and
    /// nowhere else, so a fold can never describe a list other than its own.
    public struct FoldedBlocks: Sendable {
        public let blocks: [String]
        public let folds: [String]

        public init(_ blocks: [String]) {
            self.blocks = blocks
            self.folds = blocks.map(CorrectionAnchoring.fold)
        }
    }

    /// Indexes of the blocks whose folded text contains the folded quote.
    /// Only the QUOTE is folded here — the blocks arrive folded.
    public static func matches(quote: String, in blocks: FoldedBlocks) -> [Int] {
        let needle = fold(quote)
        guard !needle.isEmpty else { return [] }
        return blocks.folds.indices.filter { blocks.folds[$0].contains(needle) }
    }

    /// The same question over a list folded on the spot.
    public static func matches(quote: String, in blocks: [String]) -> [Int] {
        guard !fold(quote).isEmpty else { return [] }
        return matches(quote: quote, in: FoldedBlocks(blocks))
    }

    /// The block index an anchor currently resolves to, or nil (stale). An
    /// out-of-range stored occurrence clamps to the LAST match: a re-write
    /// that collapsed duplicates should keep the note attached rather than
    /// orphan it, and the last surviving match is the closest thing to "the
    /// one that used to be further down".
    public static func resolve(
        quote: String, occurrence: Int, in blocks: FoldedBlocks
    ) -> (blockIndex: Int, occurrence: Int)? {
        let hits = matches(quote: quote, in: blocks)
        guard !hits.isEmpty else { return nil }
        let clamped = min(max(occurrence, 0), hits.count - 1)
        return (hits[clamped], clamped)
    }

    /// The same resolution over a list folded on the spot.
    public static func resolve(
        quote: String, occurrence: Int, in blocks: [String]
    ) -> (blockIndex: Int, occurrence: Int)? {
        guard !fold(quote).isEmpty else { return nil }
        return resolve(quote: quote, occurrence: occurrence, in: FoldedBlocks(blocks))
    }

    /// The occurrence to STORE for an anchor taken whole from the block at
    /// `index`: that block's position among the blocks whose folded text
    /// matches its own, so two blocks with identical text anchor distinctly
    /// instead of both collapsing onto the first. An out-of-range index
    /// yields 0 — the same fallback a quote that matches nothing gets.
    ///
    /// The needle is the block's OWN stored fold, so nothing is folded here.
    public static func occurrence(ofBlockAt index: Int, in blocks: FoldedBlocks) -> Int {
        guard blocks.folds.indices.contains(index) else { return 0 }
        let needle = blocks.folds[index]
        // A block that folds to nothing is contained by every other block;
        // it has no position of its own to count, and takes the same 0.
        guard !needle.isEmpty else { return 0 }
        return blocks.folds.indices
            .filter { blocks.folds[$0].contains(needle) }
            .firstIndex(of: index) ?? 0
    }

    /// The same occurrence over a list folded on the spot.
    public static func occurrence(ofBlockAt index: Int, in blocks: [String]) -> Int {
        guard blocks.indices.contains(index) else { return 0 }
        return occurrence(ofBlockAt: index, in: FoldedBlocks(blocks))
    }

    /// The occurrence to STORE when the user trims the quote away from the
    /// block it was taken from. A trimmed quote lives in a DIFFERENT match
    /// space than the whole block — "Ship it" matches both "Ship it after
    /// security review" and "Ship it after legal review", where the full block
    /// matched only its own — so carrying the block's occurrence through
    /// unchanged anchors the correction to the wrong paragraph. Resolve the
    /// block the user actually acted on, then take ITS position among the
    /// trimmed quote's matches. An unchanged quote keeps `blockOccurrence`; an
    /// unresolvable block falls back to 0 (the re-anchor pass will call it
    /// stale rather than let it mis-attach silently).
    public static func occurrence(
        forQuote quote: String, takenFrom blockText: String, blockOccurrence: Int,
        in blocks: [String]
    ) -> Int {
        guard fold(quote) != fold(blockText) else { return blockOccurrence }
        guard let targeted = resolve(
            quote: blockText, occurrence: blockOccurrence, in: blocks)
        else { return 0 }
        return matches(quote: quote, in: blocks).firstIndex(of: targeted.blockIndex) ?? 0
    }

    /// The re-anchor pass over a meeting's ANNOTATION rows against freshly
    /// synthesized notes: matched → `applied` (occurrence refreshed),
    /// unmatched → `stale`. Understanding rows are untouched (their lifecycle
    /// is pending → applied via `markApplied`).
    ///
    /// A row the person resolved keeps that status through every run: the pass
    /// refreshes WHERE it points, never WHAT it is. Recomputing the status here
    /// is what made resolution last only until the next synthesis.
    public static func reanchor(
        annotations: [MeetingCorrection], against structured: NotesStructured
    ) -> [Update] {
        annotations
            .filter { $0.kind == .annotation }
            .map { row in
                let sectionBlocks = blocks(of: structured, section: row.section)
                let hit = resolve(
                    quote: row.quotedText, occurrence: row.occurrence, in: sectionBlocks)
                if row.status == .resolved {
                    return Update(
                        id: row.id, occurrence: hit?.occurrence ?? row.occurrence,
                        status: .resolved)
                }
                if let hit {
                    return Update(id: row.id, occurrence: hit.occurrence, status: .applied)
                }
                return Update(id: row.id, occurrence: row.occurrence, status: .stale)
            }
    }
}

/// The request-level value injected into notes synthesis (`NotesRequest.
/// corrections`): the durable row minus its lifecycle bookkeeping.
public struct NotesCorrection: Codable, Sendable, Equatable {
    public var kind: MeetingCorrection.Kind
    public var section: MeetingCorrection.Section
    public var quotedText: String
    public var userText: String

    public init(
        kind: MeetingCorrection.Kind, section: MeetingCorrection.Section,
        quotedText: String, userText: String
    ) {
        self.kind = kind
        self.section = section
        self.quotedText = quotedText
        self.userText = userText
    }

    public init(row: MeetingCorrection) {
        self.init(
            kind: row.kind, section: row.section,
            quotedText: row.quotedText, userText: row.userText)
    }

    enum CodingKeys: String, CodingKey {
        case kind, section
        case quotedText = "quoted_text"
        case userText = "user_text"
    }
}
