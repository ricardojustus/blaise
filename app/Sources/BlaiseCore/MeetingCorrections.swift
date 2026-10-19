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
    /// the quote matches more than one block. For a quote containing U+2029
    /// (a passage), the index of an instance in the rendered space, which can
    /// be above 0 inside one block (`CorrectionAnchoring.passageInstances`).
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

    /// A stored quote as every prompt template quotes it: one piece is
    /// `"` + `promptField` + `"`, the exact bytes the templates wrote before
    /// passages existed; a passage quotes each piece on its own, joined by
    /// ` / `, so the model never sees pieces run together into text that
    /// exists nowhere in the notes.
    static func promptQuote(_ quote: String) -> String {
        CorrectionAnchoring.pieces(quote)
            .map { "\"" + promptField($0) + "\"" }
            .joined(separator: " / ")
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

    /// Where each Character of `text` lands in `fold(text)`: its offset there,
    /// or nil for a Character the fold drops (whitespace, a markdown token).
    /// `fold`'s own steps over the whole string, each output scalar
    /// remembering the Character it came from — how a passage piece maps
    /// between the text the pane draws and the folded positions the passage
    /// rule counts in. A Character whose kept scalars join a neighbour once
    /// the syntax between them is gone lands where that neighbour does.
    public static func foldPositions(_ text: String) -> [Int?] {
        var scalars = String.UnicodeScalarView()
        var sources: [Int?] = []
        var gap = false
        for (index, character) in text.enumerated() {
            for scalar in character.unicodeScalars where !markdownTokens.contains(scalar) {
                for lower in scalar.properties.lowercaseMapping.unicodeScalars {
                    if CharacterSet.whitespacesAndNewlines.contains(lower) {
                        if !sources.isEmpty { gap = true }
                        continue
                    }
                    if gap {
                        scalars.append(" ")
                        sources.append(nil)
                        gap = false
                    }
                    scalars.append(lower)
                    sources.append(index)
                }
            }
        }
        var positions = [Int?](repeating: nil, count: text.count)
        var scalar = 0
        for (offset, character) in String(scalars).enumerated() {
            for _ in character.unicodeScalars {
                if let source = sources[scalar], positions[source] == nil { positions[source] = offset }
                scalar += 1
            }
        }
        return positions
    }

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
        var blockTexts: [String] = []
        for section: MeetingCorrection.Section in [
            .summary, .detailedNotes, .decision, .actionItem, .userActionItem,
        ] {
            blockTexts.append(contentsOf: blocks(of: notes, section: section))
        }
        return haystack(of: notes, meetingTitle: meetingTitle, blockTexts: blockTexts)
    }

    /// The same construction as `foldedHaystack` with every RENDERED block
    /// (`renderedBlocks(of:)`) in place of the anchoring blocks: the haystack a
    /// passage's pieces are searched in, since they were captured from the
    /// text the pane draws. Built only when a passage row needs it.
    public static func renderedHaystack(
        of notes: NotesStructured, meetingTitle: String
    ) -> String {
        haystack(
            of: notes, meetingTitle: meetingTitle,
            blockTexts: renderedBlocks(of: notes).map(\.text))
    }

    private static func haystack(
        of notes: NotesStructured, meetingTitle: String, blockTexts: [String]
    ) -> String {
        let structuredTitle = notes.title ?? ""
        let effectiveTitle =
            NotesRenderer.flattenToTitleLine(structuredTitle).isEmpty
            ? meetingTitle : structuredTitle
        var components = [effectiveTitle]
        components.append(contentsOf: blockTexts)
        components.append(contentsOf: notes.actionItems.map(\.owner))
        components.append(contentsOf: notes.userActionItems.map(\.owner))
        return components
            .map { fold(withoutHaystackSeparator($0)) }
            .joined(separator: String(haystackSeparator))
    }

    /// The withdrawn-claim containment core: one row, one semantics. Every
    /// public entry point below delegates here, so the regeneration gate and
    /// the payload derivation cannot fork.
    ///
    /// Kind-filtered exactly like the injection (annotations never withdraw)
    /// and status-blind: a PENDING row whose quote an earlier pass erased
    /// belongs in the set, because the quote bytes are the erased wrong text
    /// whatever the row's bookkeeping says. Occurrence is irrelevant —
    /// absence is document-wide. A quote (or piece) whose fold is empty never
    /// enters.
    ///
    /// A one-piece quote is checked whole against the raw haystack and comes
    /// back as `[quotedText]` when absent. A passage is checked piece by
    /// piece against the rendered haystack, and only its absent pieces come
    /// back, each as stored.
    private static func absentPieces(
        _ row: MeetingCorrection, rawHaystack: String, renderedHaystack: () -> String
    ) -> [String] {
        guard row.kind == .understanding else { return [] }
        guard isPassage(row.quotedText) else {
            let needle = fold(withoutHaystackSeparator(row.quotedText))
            return !needle.isEmpty && !rawHaystack.contains(needle) ? [row.quotedText] : []
        }
        let rendered = renderedHaystack()
        return pieces(row.quotedText).filter { piece in
            let needle = fold(withoutHaystackSeparator(piece))
            return !needle.isEmpty && !rendered.contains(needle)
        }
    }

    /// A withdrawn understanding row and the part of its quote no longer in
    /// the notes.
    public struct WithdrawnRow: Equatable, Sendable {
        public let row: MeetingCorrection
        /// The whole quote for a one-piece row; the absent pieces, in order,
        /// for a passage.
        public let absentPieces: [String]

        /// The record's claim: the absent pieces, each as stored, joined by
        /// "\n" — never U+2029. One piece is the stored quote verbatim.
        public var claimText: String { absentPieces.joined(separator: "\n") }
    }

    /// Understanding ROWS with something absent from the current notes — the
    /// withdrawn-claim set carrying each row's own identity and timestamp,
    /// which a claim-level record needs and the quoted-text form cannot
    /// supply. `renderedHaystack` is evaluated at most once, and only when a
    /// passage row is present.
    public static func withdrawnRows(
        corrections: [MeetingCorrection], currentHaystack: String,
        renderedHaystack: @autoclosure () -> String
    ) -> [WithdrawnRow] {
        var rendered: String?
        return corrections.compactMap { row in
            let absent = absentPieces(row, rawHaystack: currentHaystack) {
                if let rendered { return rendered }
                let built = renderedHaystack()
                rendered = built
                return built
            }
            return absent.isEmpty ? nil : WithdrawnRow(row: row, absentPieces: absent)
        }
    }

    /// The withdrawn set in its two groups, each searched in the haystack of
    /// its own type: one-piece claims (raw) and passage pieces (rendered).
    public struct WithdrawnClaims: Equatable, Sendable {
        public var claims: [String]
        public var pieces: [String]

        public init(claims: [String] = [], pieces: [String] = []) {
            self.claims = claims
            self.pieces = pieces
        }

        public var isEmpty: Bool { claims.isEmpty && pieces.isEmpty }
    }

    /// The same set, projected: what an earlier editor pass erased from the
    /// notes, grouped by the haystack each claim is searched in.
    public static func withdrawnClaims(
        corrections: [MeetingCorrection], currentHaystack: String,
        renderedHaystack: @autoclosure () -> String
    ) -> WithdrawnClaims {
        var set = WithdrawnClaims()
        for withdrawn in withdrawnRows(
            corrections: corrections, currentHaystack: currentHaystack,
            renderedHaystack: renderedHaystack())
        {
            if isPassage(withdrawn.row.quotedText) {
                set.pieces.append(contentsOf: withdrawn.absentPieces)
            } else {
                set.claims.append(withdrawn.row.quotedText)
            }
        }
        return set
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

    /// The gate's search over both groups: one-piece claims in the
    /// candidate's raw haystack, passage pieces in its rendered haystack
    /// (evaluated only when a piece is withdrawn). The first claim contained
    /// wins.
    public static func resurrectedClaim(
        withdrawn: WithdrawnClaims, candidateHaystack: String,
        candidateRenderedHaystack: @autoclosure () -> String
    ) -> String? {
        if let claim = resurrectedClaim(
            withdrawn: withdrawn.claims, candidateHaystack: candidateHaystack)
        {
            return claim
        }
        guard !withdrawn.pieces.isEmpty else { return nil }
        return resurrectedClaim(
            withdrawn: withdrawn.pieces, candidateHaystack: candidateRenderedHaystack())
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

        init(blocks: [String], folds: [String]) {
            self.blocks = blocks
            self.folds = folds
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

    /// The fallback for a one-piece quote `resolve` finds in none of its
    /// section's raw blocks: a whole-table quote is the table's on-screen text,
    /// which no raw block holds (cell pipes, the divider row). It resolves among
    /// the section's rendered blocks — the space its occurrence was captured
    /// in — and the hit counts only when that block is a table whose whole
    /// on-screen text is the quote. Containment alone would also accept a
    /// paragraph quote that a table's flattening happens to hold (across two
    /// rows, or across a link whose URL a cell drops). `blockIndex` is within
    /// the section's rendered blocks.
    public static func resolveTable(
        quote: String, occurrence: Int, section: MeetingCorrection.Section, in space: RenderedSpace
    ) -> (blockIndex: Int, occurrence: Int)? {
        let indices = space.blocks.indices.filter { space.blocks[$0].section == section }
        let folded = space.foldedBlocks(of: section)
        guard let hit = resolve(quote: quote, occurrence: occurrence, in: folded),
            folded.folds[hit.blockIndex] == fold(quote),
            space.tables.contains(indices[hit.blockIndex])
        else { return nil }
        return hit
    }

    // MARK: - Passages (a quote whose pieces span paragraphs)

    /// Capture's joiner: a quote spanning paragraphs stores the selected text
    /// of each paragraph, in order, joined by U+2029 (PARAGRAPH SEPARATOR).
    public static let pieceSeparator: Unicode.Scalar = "\u{2029}"

    /// A quote split on U+2029 BEFORE any fold (the fold reads U+2029 as
    /// whitespace, so a folded quote has lost its boundaries). A quote with
    /// no U+2029 is one piece: itself.
    public static func pieces(_ quote: String) -> [String] {
        quote.unicodeScalars
            .split(separator: pieceSeparator, omittingEmptySubsequences: false)
            .map { String(String.UnicodeScalarView($0)) }
    }

    /// Whether a stored quote is a passage — it contains capture's joiner.
    /// Everything else is matched by the raw-space functions above.
    public static func isPassage(_ quote: String) -> Bool {
        quote.unicodeScalars.contains(pieceSeparator)
    }

    /// The order the notes pane draws the sections in, and the order a
    /// passage's earlier pieces are walked back through.
    public static let documentOrder: [MeetingCorrection.Section] = [
        .summary, .userActionItem, .decision, .actionItem, .detailedNotes,
    ]

    /// Action items with text, in stored order — the rendered space both
    /// action lists are counted in (a blank item never fold-matches a quote).
    /// Completed items stay: ticking an item never moves a passage.
    public static func presentableItems(_ items: [ActionItem]) -> [ActionItem] {
        items.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// One block of the rendered space: the text the notes pane draws for it.
    public struct RenderedBlock: Equatable, Sendable, Identifiable {
        /// Stable identity: the section and the block's index within it.
        public struct ID: Hashable, Sendable {
            public let section: MeetingCorrection.Section
            public let index: Int

            public init(section: MeetingCorrection.Section, index: Int) {
                self.section = section
                self.index = index
            }
        }

        public let id: ID
        public let text: String

        public var section: MeetingCorrection.Section { id.section }
    }

    /// Every block of the notes as the pane draws it, sections in
    /// `documentOrder`: summary and detailed notes as `MarkdownBlocks.parse`
    /// blocks by their rendered characters (detailed notes trimmed first;
    /// empty ⇒ no blocks), decisions as stored, both action lists as
    /// `presentableItems` texts in stored order. Every block counts —
    /// headings, dividers, tables and completed action items included.
    public static func renderedBlocks(of structured: NotesStructured) -> [RenderedBlock] {
        renderedBlocks(of: structured, parsed: ParsedNotes(structured))
    }

    /// The summary and detailed notes as `MarkdownBlocks.parse` blocks
    /// (detailed notes trimmed first; empty ⇒ no blocks): parsed once, so the
    /// pane that draws these blocks and the rendered space share one parse.
    public struct ParsedNotes: Sendable {
        public let summary: [MarkdownBlock]
        public let detailed: [MarkdownBlock]

        public init(_ structured: NotesStructured) {
            summary = MarkdownBlocks.parse(structured.summary)
            let body = structured.detailedNotes.trimmingCharacters(in: .whitespacesAndNewlines)
            detailed = body.isEmpty ? [] : MarkdownBlocks.parse(body)
        }
    }

    static func renderedBlocks(of structured: NotesStructured, parsed: ParsedNotes) -> [RenderedBlock] {
        documentOrder.flatMap { section in
            renderedTexts(section, in: structured, parsed: parsed).enumerated().map { index, text in
                RenderedBlock(id: RenderedBlock.ID(section: section, index: index), text: text)
            }
        }
    }

    private static func renderedTexts(
        _ section: MeetingCorrection.Section, in structured: NotesStructured, parsed: ParsedNotes
    ) -> [String] {
        switch section {
        case .summary:
            return parsed.summary.map { String($0.text.characters) }
        case .detailedNotes:
            return parsed.detailed.map { String($0.text.characters) }
        case .decision:
            return structured.decisions
        case .actionItem:
            return presentableItems(structured.actionItems).map(\.text)
        case .userActionItem:
            return presentableItems(structured.userActionItems).map(\.text)
        }
    }

    /// The rendered space of one document, folded once: every passage
    /// question asks this value, never re-folding per row.
    public struct RenderedSpace: Sendable {
        public let blocks: [RenderedBlock]
        let folds: [[Character]]
        private let foldTexts: [String]
        /// The indices of the blocks that are tables.
        let tables: Set<Int>

        public init(_ structured: NotesStructured) {
            self.init(structured, parsed: ParsedNotes(structured))
        }

        /// The same space from notes already parsed.
        public init(_ structured: NotesStructured, parsed: ParsedNotes) {
            let blocks = CorrectionAnchoring.renderedBlocks(of: structured, parsed: parsed)
            self.blocks = blocks
            foldTexts = blocks.map { CorrectionAnchoring.fold($0.text) }
            folds = foldTexts.map(Array.init)
            tables = Set(blocks.indices.filter { index in
                let id = blocks[index].id
                let source = id.section == .summary ? parsed.summary
                    : id.section == .detailedNotes ? parsed.detailed : []
                guard source.indices.contains(id.index), case .table = source[id.index].kind else { return false }
                return true
            })
        }

        /// One section's blocks with the folds this space already holds, in
        /// block order — `FoldedBlocks(texts)` without folding again.
        public func foldedBlocks(of section: MeetingCorrection.Section) -> FoldedBlocks {
            let indices = blocks.indices.filter { blocks[$0].section == section }
            return FoldedBlocks(blocks: indices.map { blocks[$0].text }, folds: indices.map { foldTexts[$0] })
        }
    }

    /// Where one piece of a passage sits: a block of the rendered space (its
    /// index in `RenderedSpace.blocks`) and the piece's position in that
    /// block's folded text, in Characters.
    public struct PiecePlacement: Equatable, Sendable {
        public let block: Int
        public let range: Range<Int>
    }

    /// One instance of a passage in the rendered space.
    public struct PassageInstance: Equatable, Sendable {
        /// One entry per piece of the quote, in order; nil for a piece whose
        /// fold is empty (it takes no part).
        public let placements: [PiecePlacement?]

        /// The block of the last piece — where the row is placed.
        public let anchorBlock: Int

        /// The distinct sections the pieces sit in, in piece order.
        public func sections(in space: RenderedSpace) -> [MeetingCorrection.Section] {
            var sections: [MeetingCorrection.Section] = []
            for placement in placements.compactMap({ $0 }) {
                let section = space.blocks[placement.block].section
                if !sections.contains(section) { sections.append(section) }
            }
            return sections
        }
    }

    /// Every instance of a passage in its row's section, ordered by block then
    /// position. For each occurrence of the last piece in a block of the
    /// section (every start position, overlapping ones included), each earlier
    /// piece is placed, from the next-to-last back to the first, at its LAST
    /// occurrence ending at or before the start of the next piece's placement
    /// in the same block; failing that, at its last occurrence in the nearest
    /// preceding block that contains it, walking back in `documentOrder`
    /// across sections. The occurrence is an instance when every piece is
    /// placed. A quote whose last piece folds empty has no instance; other
    /// empty-fold pieces take no part.
    public static func passageInstances(
        quote: String, section: MeetingCorrection.Section, in space: RenderedSpace
    ) -> [PassageInstance] {
        let rawPieces = pieces(quote)
        let needles = rawPieces.map { Array(fold($0)) }
        guard let lastNeedle = needles.last, !lastNeedle.isEmpty else { return [] }
        let lastPiece = needles.count - 1
        let earlier = needles.indices.dropLast().filter { !needles[$0].isEmpty }

        // Every start of an earlier piece in a block, ascending, found once
        // per (piece, block): each instance then asks for the last one ending
        // by a limit with a binary search instead of rescanning the prefix.
        var startsIn: [Int: [Int: [Int]]] = [:]
        func pieceStarts(_ piece: Int, _ block: Int) -> [Int] {
            if let known = startsIn[piece]?[block] { return known }
            let found = starts(of: needles[piece], in: space.folds[block])
            startsIn[piece, default: [:]][block] = found
            return found
        }
        // The nearest block before `block` holding a piece, found once per
        // (piece, block): the walk back is shared by every instance that
        // reaches the same block instead of repeated for each.
        var nearestBefore: [Int: [Int: Int?]] = [:]
        func nearestBlock(_ piece: Int, before block: Int) -> Int? {
            var visited: [Int] = []
            var candidate = block - 1
            var answer: Int?
            while candidate >= 0 {
                if let known = nearestBefore[piece]?[candidate + 1] {
                    answer = known
                    break
                }
                visited.append(candidate + 1)
                if !pieceStarts(piece, candidate).isEmpty {
                    answer = candidate
                    break
                }
                candidate -= 1
            }
            for entry in visited { nearestBefore[piece, default: [:]][entry] = answer }
            return answer
        }

        var instances: [PassageInstance] = []
        for block in space.blocks.indices where space.blocks[block].section == section {
            for start in starts(of: lastNeedle, in: space.folds[block]) {
                var placements = [PiecePlacement?](repeating: nil, count: needles.count)
                placements[lastPiece] = PiecePlacement(
                    block: block, range: start ..< start + lastNeedle.count)
                var next = (block: block, start: start)
                var placedAll = true
                for piece in earlier.reversed() {
                    let length = needles[piece].count
                    if let found = lastStart(
                        in: pieceStarts(piece, next.block), endingBy: next.start - length)
                    {
                        placements[piece] = PiecePlacement(
                            block: next.block, range: found ..< found + length)
                        next = (next.block, found)
                        continue
                    }
                    let walked = nearestBlock(piece, before: next.block).map { previous in
                        (block: previous, start: pieceStarts(piece, previous).last!)
                    }
                    guard let walked else {
                        placedAll = false
                        break
                    }
                    placements[piece] = PiecePlacement(
                        block: walked.block, range: walked.start ..< walked.start + length)
                    next = walked
                }
                if placedAll {
                    instances.append(PassageInstance(placements: placements, anchorBlock: block))
                }
            }
        }
        return instances
    }

    /// The instance a stored passage occurrence names, or nil (stale). An
    /// out-of-range occurrence clamps to the LAST instance, as `resolve` does.
    public static func resolvePassage(
        quote: String, occurrence: Int, section: MeetingCorrection.Section,
        in space: RenderedSpace
    ) -> (instance: PassageInstance, occurrence: Int)? {
        let instances = passageInstances(quote: quote, section: section, in: space)
        guard !instances.isEmpty else { return nil }
        let clamped = min(max(occurrence, 0), instances.count - 1)
        return (instances[clamped], clamped)
    }

    /// Every start offset of `needle` in `haystack`, ascending, overlapping
    /// occurrences included.
    private static func starts(of needle: [Character], in haystack: [Character]) -> [Int] {
        guard let first = needle.first, needle.count <= haystack.count else { return [] }
        return (0 ... haystack.count - needle.count).filter { start in
            haystack[start] == first && haystack[start ..< start + needle.count].elementsEqual(needle)
        }
    }

    /// The last of the ascending `starts` at or before `limit`, or nil.
    private static func lastStart(in starts: [Int], endingBy limit: Int) -> Int? {
        var low = 0
        var high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] <= limit { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? starts[low - 1] : nil
    }

    /// The re-anchor pass over a meeting's ANNOTATION rows against freshly
    /// synthesized notes: matched → `applied` (occurrence refreshed),
    /// unmatched → `stale`. Understanding rows are untouched (their lifecycle
    /// is pending → applied via `markApplied`).
    ///
    /// A row the person resolved keeps that status through every run: the pass
    /// refreshes WHERE it points, never WHAT it is. Recomputing the status here
    /// is what made resolution last only until the next synthesis.
    ///
    /// A passage, or a whole-table quote, resolves in the rendered space,
    /// folded once for the whole pass and only when such a row needs it.
    public static func reanchor(
        annotations: [MeetingCorrection], against structured: NotesStructured
    ) -> [Update] {
        let rows = annotations.filter { $0.kind == .annotation }
        lazy var space = RenderedSpace(structured)
        return rows
            .map { row in
                let hit: (blockIndex: Int, occurrence: Int)?
                if isPassage(row.quotedText) {
                    hit = resolvePassage(
                        quote: row.quotedText, occurrence: row.occurrence,
                        section: row.section, in: space
                    ).map { ($0.instance.anchorBlock, $0.occurrence) }
                } else {
                    let sectionBlocks = blocks(of: structured, section: row.section)
                    hit = resolve(
                        quote: row.quotedText, occurrence: row.occurrence, in: sectionBlocks)
                        ?? resolveTable(
                            quote: row.quotedText, occurrence: row.occurrence,
                            section: row.section, in: space)
                }
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
