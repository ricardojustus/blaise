import Foundation
import GRDB

// G17: span-anchored user corrections and margin notes on a finished meeting.
// One durable row per correction/note; every synthesis run re-reads the
// meeting's rows (a later full Regenerate can never erase user truth — the
// core G17 commitment). Anchoring is quote + section + occurrence, never
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
    public enum Section: String, Codable, Sendable, CaseIterable {
        case summary
        case detailedNotes = "detailed_notes"
        case decision
        case actionItem = "action_item"
    }

    public enum Status: String, Codable, Sendable {
        /// Written, not yet reflected in the current notes.
        case pending
        /// A synthesis run consumed it (understanding) / the anchor currently
        /// fold-matches a block (annotation).
        case applied
        /// An annotation whose anchor no longer matches any block — renders
        /// under "Your notes", never silently dropped (G17 §UX-5).
        case stale
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
    /// row returns to `pending` for understanding corrections (the edit is
    /// not yet reflected in notes); annotations pass their status explicitly.
    public static func update(
        _ db: Database, id: String,
        quotedText: String, occurrence: Int, userText: String, status: MeetingCorrection.Status
    ) throws {
        try db.execute(
            sql: """
                UPDATE meeting_correction
                SET quoted_text = ?, occurrence = ?, user_text = ?, status = ?
                WHERE id = ?
                """,
            arguments: [quotedText, occurrence, userText, status.rawValue, id])
    }

    /// Deletion IS the undo path (G17 §UX-3): a deleted understanding row is
    /// simply absent from the next synthesis run.
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
}

/// G17 FIX H: the single-line fold for USER-authored correction text and the
/// quotes that travel with it.
///
/// Deliberately separate from `NotesRenderer.flattenToTitleLine`: that one
/// owns TITLE bytes for every meeting (including the ones with no corrections
/// at all) and strips a leading `#` run, which is title semantics. This one
/// collapses EVERY Unicode line break — LF/CR/CRLF plus U+000B, U+000C,
/// U+0085, U+2028 and U+2029, which end a line for renderers that are not
/// strictly CommonMark and for the synthesis prompt alike. Two escapes close
/// with it: a note escaping its `>` blockquote in notes.md, and a quote or
/// note body forging an extra numbered entry inside the prompt's
/// AUTHORITATIVE corrections block.
///
/// A leading `#` is deliberately NOT stripped: inline after our
/// "**Your note:** " prefix it is inert, and stripping it would silently eat
/// the body of a note that is legitimately just "### TODO".
public enum CorrectionSanitize {
    public static func flatten(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\r\n", with: " ")
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
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
        }
    }

    /// Indexes of the blocks whose folded text contains the folded quote.
    public static func matches(quote: String, in blocks: [String]) -> [Int] {
        let needle = fold(quote)
        guard !needle.isEmpty else { return [] }
        return blocks.indices.filter { fold(blocks[$0]).contains(needle) }
    }

    /// The block index an anchor currently resolves to, or nil (stale). An
    /// out-of-range stored occurrence clamps to the first match: a re-write
    /// that collapsed duplicates should keep the note attached, not orphan it.
    public static func resolve(
        quote: String, occurrence: Int, in blocks: [String]
    ) -> (blockIndex: Int, occurrence: Int)? {
        let hits = matches(quote: quote, in: blocks)
        guard !hits.isEmpty else { return nil }
        let clamped = min(max(occurrence, 0), hits.count - 1)
        return (hits[clamped], clamped)
    }

    /// The re-anchor pass over a meeting's ANNOTATION rows against freshly
    /// synthesized notes: matched → `applied` (occurrence refreshed),
    /// unmatched → `stale`. Understanding rows are untouched (their lifecycle
    /// is pending → applied via `markApplied`).
    public static func reanchor(
        annotations: [MeetingCorrection], against structured: NotesStructured
    ) -> [Update] {
        annotations
            .filter { $0.kind == .annotation }
            .map { row in
                let sectionBlocks = blocks(of: structured, section: row.section)
                if let hit = resolve(
                    quote: row.quotedText, occurrence: row.occurrence, in: sectionBlocks)
                {
                    return Update(id: row.id, occurrence: hit.occurrence, status: .applied)
                }
                return Update(id: row.id, occurrence: row.occurrence, status: .stale)
            }
    }
}

/// G17: the SNAPSHOT of the correction rows that shaped a minted notes
/// artifact, stored on `meeting_notes.user_corrections` (nullable JSON) at
/// every mint. The payload emits THIS snapshot, never the live
/// `meeting_correction` rows — live rows are user-mutable (edit/delete is
/// the undo path) and therefore not a hash-stable re-materialization source.
public struct NotesCorrectionSnapshot: Codable, Sendable, Equatable {
    public var kind: MeetingCorrection.Kind
    public var section: MeetingCorrection.Section
    public var quotedText: String
    public var userText: String
    public var createdAt: Date

    public init(row: MeetingCorrection) {
        self.kind = row.kind
        self.section = row.section
        self.quotedText = row.quotedText
        self.userText = row.userText
        self.createdAt = row.createdAt
    }

    enum CodingKeys: String, CodingKey {
        case kind, section
        case quotedText = "quoted_text"
        case userText = "user_text"
        case createdAt = "created_at"
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
