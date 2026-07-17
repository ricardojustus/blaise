import Foundation
import GRDB
import Observation
import os

// C10 observation plumbing: GRDB ValueObservation drives the library list
// and detail; the pipeline progress stream feeds a @MainActor @Observable
// holder (the C8 HandoffStatusHolder pattern). UI-free — SwiftUI views in
// BlaiseApp read these.

// MARK: - Pinned date rendering (Brazilian conventions: DD/MM/YYYY)

/// Fixed-field-order date rendering for every surface that shows a date.
/// `Date.FormatStyle` orders day/month by the SYSTEM locale (en_US renders
/// MM/DD) — the product convention is DD/MM/YYYY always, so the format
/// string is explicit and the locale pinned to en_US_POSIX (numeric fields
/// only; the locale can never reorder an explicit dateFormat). Time zone
/// stays current: dates display in local time.
public enum BlaiseDateFormat {
    public static func dayMonthYear(_ date: Date) -> String {
        fixed("dd/MM/yyyy", date)
    }

    /// DD/MM/YYYY HH:mm (24 h — Brazilian time convention).
    public static func dayMonthYearTime(_ date: Date) -> String {
        fixed("dd/MM/yyyy HH:mm", date)
    }

    private static func fixed(_ format: String, _ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}

// MARK: - Attendee display names (V1.1)

/// Human display name for an attendee. Calendar sources frequently deliver
/// the email address AS the name; render the local-part prettified
/// ("robin.cole" → "Robin Cole") and keep the full email for a
/// tooltip/secondary line.
public enum AttendeeDisplay {
    /// Header-presentable attendees only: drops `.meetExtension` rows whose
    /// name is not name-shaped (markup/sentence junk a pre-0.2.0 extension
    /// scraped into the name position — field 2026-06-11, CSS blocks and UI
    /// sentences rendered verbatim as "json artifacts" in the header).
    /// Calendar/manual rows are never dropped (their name may legitimately be
    /// an email, prettified by `displayName`); only extension-sourced junk is
    /// filtered, and only at display — the durable row is untouched.
    public static func presentable(_ attendees: [Attendee]) -> [Attendee] {
        attendees.filter { attendee in
            guard attendee.source == .meetExtension else { return true }
            // Structural junk (CSS/markup blocks, over-length blobs).
            guard MeetDisplayNameSanitizer.sanitize(attendee.name) != nil else { return false }
            // Sentence junk a scraper lifted into the name position
            // ("As pessoas ainda podem ver seu vídeo completo."): a real Meet
            // display name is never a full sentence. Drop a many-word string
            // ending in sentence punctuation — abbreviation-suffix names
            // ("Jr.", "Bopp Jr.") stay (few tokens), compound names stay (no
            // terminal period).
            return !looksLikeSentence(attendee.name)
        }
    }

    /// A many-word string terminated by sentence punctuation — never a name.
    static func looksLikeSentence(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last, last == "." || last == "!" || last == "?" else {
            return false
        }
        return trimmed.split(whereSeparator: \.isWhitespace).count > 3
    }

    public static func displayName(_ attendee: Attendee) -> String {
        let name = attendee.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.contains("@") { return prettifyLocalPart(name) }
        if name.isEmpty, let email = attendee.email { return prettifyLocalPart(email) }
        return name
    }

    /// "robin.cole@example.com" → "Robin Cole" (split on `.`/`_`/`-`,
    /// capitalize each part). Digits-only parts are dropped ("joao.silva2"
    /// → "Joao Silva2" stays — only fully-numeric trailing parts go, e.g.
    /// "alex.kim.1984" → "Alex Kim"). Degenerate input with NO local
    /// part ("@example.com") falls back to the raw string — never render the
    /// domain as a name.
    static func prettifyLocalPart(_ emailish: String) -> String {
        let local =
            emailish.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
            .first ?? ""
        guard !local.isEmpty else { return emailish }
        let parts = local
            .split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" })
            .filter { !$0.allSatisfy(\.isNumber) }
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return parts.isEmpty ? String(local) : parts.joined(separator: " ")
    }

    /// Tooltip body: one "Name <email>" line per attendee (email omitted
    /// when absent or identical to the shown name).
    public static func tooltip(_ attendees: [Attendee]) -> String {
        attendees.map { attendee in
            let shown = displayName(attendee)
            if let email = attendee.email, email != shown {
                return "\(shown) <\(email)>"
            }
            // Email-as-name case without a separate email field.
            if attendee.email == nil, attendee.name.contains("@") {
                return "\(shown) <\(attendee.name)>"
            }
            return shown
        }.joined(separator: "\n")
    }
}

// MARK: - Copy All assembly (V1.1)

/// Plain-text transcript for the clipboard: one "[h:mm:ss] Speaker: text"
/// line per segment, in `ord` order. (Notes copy needs no assembler — the
/// rendered `MeetingNotes.markdown` IS the copyable human artifact.)
public enum TranscriptCopyText {
    public static func assemble(_ segments: [TranscriptSegment]) -> String {
        segments.map { segment in
            let speaker = segment.speakerName ?? segment.speakerLabel
            return "[\(timestamp(segment.startSeconds))] \(speaker): "
                + segment.text.trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
    }

    static func timestamp(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

// MARK: - Library list item

/// One library row: the meeting joined with its notes-derived metadata
/// (D16: B's borrowed action-count badge; C's row content).
public struct MeetingListItem: Identifiable, Equatable, Sendable {
    public var meeting: Meeting
    public var summary: String?
    public var actionItemCount: Int
    public var userActionItemCount: Int

    public var id: MeetingID { meeting.id }

    public init(meeting: Meeting, summary: String?, actionItemCount: Int, userActionItemCount: Int) {
        self.meeting = meeting
        self.summary = summary
        self.actionItemCount = actionItemCount
        self.userActionItemCount = userActionItemCount
    }
}

/// One flattened "My Action Items" row (load-bearing sidebar group):
/// item text + meeting title/date, recency-ordered, grouped by meeting.
public struct UserActionEntry: Identifiable, Equatable, Sendable {
    public var meetingID: MeetingID
    public var meetingTitle: String
    public var startedAt: Date
    public var text: String
    /// V1.1 done/archive state (`action_item_state`, local-only).
    public var done: Bool

    public var id: String { "\(meetingID)#\(text)" }

    public init(
        meetingID: MeetingID, meetingTitle: String, startedAt: Date, text: String,
        done: Bool = false
    ) {
        self.meetingID = meetingID
        self.meetingTitle = meetingTitle
        self.startedAt = startedAt
        self.text = text
        self.done = done
    }
}

/// A resolved search row (the view-model path the DoD exercises): the FTS
/// hit joined with its meeting title and the delimiter-mapped segments.
public struct SearchResultItem: Identifiable, Equatable, Sendable {
    public var hit: SearchHit
    public var meetingTitle: String
    public var startedAt: Date
    public var segments: [SearchSnippetFormatter.Segment]

    public var id: Int64 { hit.segmentID }

    public init(hit: SearchHit, meetingTitle: String, startedAt: Date) {
        self.hit = hit
        self.meetingTitle = meetingTitle
        self.startedAt = startedAt
        self.segments = SearchSnippetFormatter.segments(hit.snippet)
    }
}

/// A NOTES hit (F2) joined with its meeting title and delimiter-mapped
/// segments. Notes are one row per meeting, so `id` is the meeting id.
public struct NotesSearchResultItem: Identifiable, Equatable, Sendable {
    public var hit: NotesSearchHit
    public var meetingTitle: String
    public var startedAt: Date
    public var segments: [SearchSnippetFormatter.Segment]

    public var id: MeetingID { hit.meetingID }

    public init(hit: NotesSearchHit, meetingTitle: String, startedAt: Date) {
        self.hit = hit
        self.meetingTitle = meetingTitle
        self.startedAt = startedAt
        self.segments = SearchSnippetFormatter.segments(hit.snippet)
    }
}

/// The two labelled search surfaces (F2). bm25 is not comparable across the
/// two FTS tables, so notes and transcript stay as separate, internally-ranked
/// groups; the UI shows Notes first (notes are for humans — Floor 5).
public struct SearchResults: Equatable, Sendable {
    public var notes: [NotesSearchResultItem]
    public var transcripts: [SearchResultItem]

    public var isEmpty: Bool { notes.isEmpty && transcripts.isEmpty }

    public init(notes: [NotesSearchResultItem] = [], transcripts: [SearchResultItem] = []) {
        self.notes = notes
        self.transcripts = transcripts
    }
}

// MARK: - LibraryModel

/// Drives the library window: ValueObservation over `meeting` +
/// `meeting_notes` (live rows), the three V1 smart groups, day grouping,
/// and FTS search through `TranscriptRepository.search`.
@MainActor @Observable
public final class LibraryModel {
    public enum SmartGroup: String, CaseIterable, Sendable {
        case all, thisWeek, myActionItems
    }

    public private(set) var items: [MeetingListItem] = []
    public private(set) var userEntries: [UserActionEntry] = []
    /// Meetings whose finalize just completed (ready pulse + "Ready" badge).
    public private(set) var recentlyReady: Set<MeetingID> = []

    private let database: BlaiseDatabase
    private var observationTask: Task<Void, Never>?
    private let logger = Logger(subsystem: BlaiseBundle.identifier, category: "library.model")

    public init(database: BlaiseDatabase) {
        self.database = database
    }

    /// Starts the ValueObservation (idempotent).
    public func start() {
        guard observationTask == nil else { return }
        let observation = ValueObservation.tracking { db -> ([Meeting], [MeetingNotes], [(MeetingID, String)]) in
            let meetings = try Meeting
                .order(Column("started_at").desc, Column("id").desc)
                .fetchAll(db)
            let notes = try MeetingNotes.fetchAll(db)
            let doneRows = try Row.fetchAll(
                db, sql: "SELECT meeting_id, item_key FROM action_item_state"
            ).map { ($0["meeting_id"] as MeetingID, $0["item_key"] as String) }
            return (meetings, notes, doneRows)
        }
        let pool = database.pool
        observationTask = Task { [weak self] in
            do {
                for try await (meetings, notes, doneRows) in observation.values(in: pool) {
                    guard let self else { return }
                    self.apply(meetings: meetings, notes: notes, doneRows: doneRows)
                }
            } catch {
                self?.logger.error("library observation failed: \(error)")
            }
        }
    }

    public func stop() {
        observationTask?.cancel()
        observationTask = nil
    }

    private func apply(meetings: [Meeting], notes: [MeetingNotes], doneRows: [(MeetingID, String)] = []) {
        let notesByMeeting = Dictionary(uniqueKeysWithValues: notes.map { ($0.meetingID, $0) })
        var doneKeys: [MeetingID: Set<String>] = [:]
        for (meetingID, key) in doneRows {
            doneKeys[meetingID, default: []].insert(key)
        }
        items = meetings.map { meeting in
            let structured = notesByMeeting[meeting.id]?.structured
            return MeetingListItem(
                meeting: meeting,
                summary: structured?.summary,
                actionItemCount: structured?.actionItems.count ?? 0,
                userActionItemCount: structured?.userActionItems.count ?? 0)
        }
        userEntries = meetings.flatMap { meeting -> [UserActionEntry] in
            guard let structured = notesByMeeting[meeting.id]?.structured else { return [] }
            let done = doneKeys[meeting.id] ?? []
            return structured.userActionItems.map {
                UserActionEntry(
                    meetingID: meeting.id, meetingTitle: meeting.title,
                    startedAt: meeting.startedAt, text: $0.text,
                    done: done.contains(ActionItemKey.key(for: $0.text)))
            }
        }
    }

    /// Test seam: drive the grouping/filter logic without an observation.
    func setItemsForTesting(_ items: [MeetingListItem]) {
        self.items = items
    }

    // MARK: Smart groups + day grouping

    public func items(in group: SmartGroup, now: Date = Date()) -> [MeetingListItem] {
        switch group {
        case .all:
            return items
        case .thisWeek:
            let cutoff = now.addingTimeInterval(-7 * 24 * 3600)
            return items.filter { $0.meeting.startedAt >= cutoff }
        case .myActionItems:
            return items.filter { $0.userActionItemCount > 0 }
        }
    }

    public struct DayGroup: Identifiable, Equatable, Sendable {
        public var day: Date
        public var label: String
        public var items: [MeetingListItem]
        public var id: Date { day }
    }

    /// Day-grouped rows (C's borrowed grouping), newest day first; rows
    /// inside a day keep recency order.
    public static func dayGroups(
        _ items: [MeetingListItem], calendar: Calendar = .current, now: Date = Date()
    ) -> [DayGroup] {
        let grouped = Dictionary(grouping: items) { calendar.startOfDay(for: $0.meeting.startedAt) }
        return grouped.keys.sorted(by: >).map { day in
            DayGroup(day: day, label: Self.dayLabel(day, calendar: calendar, now: now), items: grouped[day]!)
        }
    }

    static func dayLabel(_ day: Date, calendar: Calendar, now: Date) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(day, inSameDayAs: yesterday)
        {
            return "Yesterday"
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "EEEE, dd/MM/yyyy"  // DD/MM/YYYY (Brazilian convention)
        return formatter.string(from: day)
    }

    // MARK: Ready pulse

    /// Called by the pipeline-events subscriber on `stageFinished(.finalize)`.
    public func markReady(_ meetingID: MeetingID) {
        recentlyReady.insert(meetingID)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            self?.recentlyReady.remove(meetingID)
        }
    }

    // MARK: Search (the view-model path)

    public func search(_ query: String) async -> SearchResults {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return SearchResults() }
        let titles = Dictionary(
            uniqueKeysWithValues: items.map { ($0.meeting.id, ($0.meeting.title, $0.meeting.startedAt)) })
        do {
            // Both reads run concurrently (GRDB pool allows parallel reads).
            async let transcriptHitsTask = TranscriptRepository(database: database).search(trimmed)
            async let notesHitsTask = NotesRepository(database: database).searchNotes(trimmed)
            let transcriptHits = try await transcriptHitsTask
            let notesHits = try await notesHitsTask
            let transcripts = try await withResolvedTitles(hits: transcriptHits, known: titles)
            let notes = try await withResolvedNotesTitles(hits: notesHits, known: titles)
            return SearchResults(notes: notes, transcripts: transcripts)
        } catch {
            logger.error("search failed: \(error)")
            return SearchResults()
        }
    }

    private func withResolvedTitles(
        hits: [SearchHit], known: [MeetingID: (String, Date)]
    ) async throws -> [SearchResultItem] {
        var results: [SearchResultItem] = []
        for hit in hits {
            if let (title, started) = try await resolveTitle(hit.meetingID, known: known) {
                results.append(SearchResultItem(hit: hit, meetingTitle: title, startedAt: started))
            }
        }
        return results
    }

    private func withResolvedNotesTitles(
        hits: [NotesSearchHit], known: [MeetingID: (String, Date)]
    ) async throws -> [NotesSearchResultItem] {
        var results: [NotesSearchResultItem] = []
        for hit in hits {
            if let (title, started) = try await resolveTitle(hit.meetingID, known: known) {
                results.append(NotesSearchResultItem(hit: hit, meetingTitle: title, startedAt: started))
            }
        }
        return results
    }

    /// Resolve a meeting's title + date: from the live in-memory rows if loaded,
    /// else a direct fetch (a hit can reference a meeting not in the current
    /// smart-group view).
    private func resolveTitle(
        _ meetingID: MeetingID, known: [MeetingID: (String, Date)]
    ) async throws -> (String, Date)? {
        if let hit = known[meetingID] { return hit }
        if let meeting = try await MeetingRepository(database: database).fetch(meetingID) {
            return (meeting.title, meeting.startedAt)
        }
        return nil
    }
}

// MARK: - DetailModel

/// Drives one meeting's detail pane: ValueObservation over the meeting row,
/// its notes, and its transcript segments.
@MainActor @Observable
public final class MeetingDetailModel {
    public private(set) var meeting: Meeting?
    public private(set) var notes: MeetingNotes?
    public private(set) var segments: [TranscriptSegment] = []
    /// `ActionItemKey`s of user action items marked done (V1.1, local-only).
    public private(set) var doneActionKeys: Set<String> = []
    /// G2 §4: the durable speaker renames for this meeting (label → row),
    /// including stale rows (which render the label unnamed + re-confirm).
    public private(set) var speakerRenames: [String: SpeakerRename] = [:]
    /// True once the first observation delivery has landed: before that the
    /// detail renders a clear placeholder over the direction backdrop (a nil
    /// `meeting` only means "not found" AFTER a load has happened — showing
    /// it pre-load made every meeting swap flash).
    public private(set) var loaded = false

    /// G2 §4 (L-6): true when a persisted diarization artifact exists for this
    /// meeting. When it does NOT, a rename cannot derive an anchor and parks as
    /// `stale` (applied only after the next regenerate) — the rename popover
    /// shows truthful copy in that case rather than promising immediate effect.
    public var hasDiarizationArtifact: Bool {
        let url = database.paths.diarizationURL(meetingID)
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// G2 §5 (L-5): the distinct resolved speaker names on the transcript — a
    /// rule-2 pre-fill candidate set is "resolved speakers + attendees", so the
    /// correct-name popover must see speakers named on the transcript even when
    /// they are absent from the attendee list / action-item owners.
    public var resolvedSpeakerNames: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for segment in segments {
            guard let name = segment.speakerName, !name.isEmpty else { continue }
            if seen.insert(name).inserted { result.append(name) }
        }
        return result
    }

    private let database: BlaiseDatabase
    private let meetingID: MeetingID
    private var observationTask: Task<Void, Never>?
    private let logger = Logger(subsystem: BlaiseBundle.identifier, category: "detail.model")

    public init(database: BlaiseDatabase, meetingID: MeetingID) {
        self.database = database
        self.meetingID = meetingID
    }

    public func start() {
        guard observationTask == nil else { return }
        let id = meetingID
        let observation = ValueObservation.tracking { db -> (Meeting?, MeetingNotes?, [TranscriptSegment], Set<String>, [SpeakerRename]) in
            let meeting = try Meeting.fetchOne(db, key: id)
            let notes = try MeetingNotes.fetchOne(db, key: id)
            let segments = try TranscriptSegment
                .filter(Column("meeting_id") == id)
                .order(Column("ord").asc)
                .fetchAll(db)
            let doneKeys = try Set(String.fetchAll(
                db, sql: "SELECT item_key FROM action_item_state WHERE meeting_id = ?",
                arguments: [id]))
            let renames = try SpeakerRenameStore.all(db, meetingID: id)
            return (meeting, notes, segments, doneKeys, renames)
        }
        let pool = database.pool
        observationTask = Task { [weak self] in
            do {
                for try await (meeting, notes, segments, doneKeys, renames) in observation.values(in: pool) {
                    guard let self else { return }
                    self.meeting = meeting
                    self.notes = notes
                    self.segments = segments
                    self.doneActionKeys = doneKeys
                    self.speakerRenames = Dictionary(
                        uniqueKeysWithValues: renames.map { ($0.speakerLabel, $0) })
                    self.loaded = true
                }
            } catch {
                self?.logger.error("detail observation failed: \(error)")
                // The load is over, even though it failed (DB-error-only in
                // practice): flip `loaded` so the pane shows its honest
                // placeholder instead of staying clear forever.
                self?.loaded = true
            }
        }
    }

    public func stop() {
        observationTask?.cancel()
        observationTask = nil
    }
}

// MARK: - Pipeline activity holder

/// `@MainActor @Observable` holder fed by the pipeline's progress stream:
/// per-meeting current stage while a run is in flight (the detail overlay +
/// row glyph read it), plus the finalize signal for the ready pulse.
@MainActor @Observable
public final class PipelineActivityHolder {
    public struct Activity: Equatable, Sendable {
        public var stage: PipelineStage
        public var regeneration: Bool
    }

    public private(set) var activeRuns: [MeetingID: Activity] = [:]

    public init() {}

    /// Applies one pipeline event; returns the meeting id when the event was
    /// `stageFinished(.finalize)` (the immediate-notes-surfacing signal).
    @discardableResult
    public func apply(_ event: PipelineEvent) -> MeetingID? {
        switch event {
        case .runStarted(let id, let regeneration):
            activeRuns[id] = Activity(stage: .ingest, regeneration: regeneration)
        case .stageBegan(let id, let stage):
            activeRuns[id] = Activity(
                stage: stage, regeneration: activeRuns[id]?.regeneration ?? false)
        case .stageFinished(let id, let stage):
            if stage == .finalize { return id }
        case .runCompleted(let id), .runFailed(let id, _, _):
            activeRuns[id] = nil
        case .glossaryLoaded:
            break // informational (§5b); does not change run activity
        case .participantConfirmationNeeded:
            break // G15: the app posts the notification; run activity is cleared
                  // by the run's own runCompleted at the pending terminal.
        }
        return nil
    }
}
