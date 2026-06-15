import Foundation

// G11 §4b: the "Upcoming" meetings list MODEL — the pure datum behind the
// (deferred) main-window section. All of TODAY's remaining calendar meetings
// (every scanned calendar, Meet link or not), each row a one-click Record that
// starts a recording bound to the §1 anchor. The GUI render batches to the
// deploy ask; the model + its row→start-with-anchor wiring are headless and
// unit-pinned here (AC8). The list refreshes on the existing suggestion cadence
// + on day change; a row disappears once its meeting is recorded or its end
// passes.

/// One Upcoming-section row. `time`/`title`/`attendeeCount` are the display
/// fields; `anchor` (the §1 calendar anchor) and `source`/`meetingCode` drive
/// the Record action's start. `urlString` (a Meet link) gates the additional
/// Launch & Record affordance per C14.
public struct UpcomingMeetingRow: Sendable, Equatable, Identifiable {
    public var eventIdentifier: String
    public var title: String
    public var start: Date
    public var end: Date
    public var attendeeCount: Int
    public var source: MeetingSource
    public var meetingCode: String?
    public var attendees: [Attendee]
    public var urlString: String?

    /// Stable identity for SwiftUI list diffing (the deferred render).
    public var id: String { PreMeetingScheduler.eventKey(snapshotKey) }
    private var snapshotKey: CalendarEventSnapshot {
        CalendarEventSnapshot(eventIdentifier: eventIdentifier, title: title, start: start, end: end)
    }

    /// G11 §1: the calendar anchor this row's Record action persists at start.
    public var anchor: CalendarAnchor {
        CalendarAnchor(eventIdentifier: eventIdentifier, scheduledEnd: end)
    }

    /// The §4b Meet-link affordance is available when a code parsed from the
    /// event (the row ALSO offers Launch & Record per C14).
    public var offersLaunchAndRecord: Bool { meetingCode != nil && urlString != nil }

    public init(
        eventIdentifier: String, title: String, start: Date, end: Date, attendeeCount: Int,
        source: MeetingSource, meetingCode: String?, attendees: [Attendee], urlString: String?
    ) {
        self.eventIdentifier = eventIdentifier
        self.title = title
        self.start = start
        self.end = end
        self.attendeeCount = attendeeCount
        self.source = source
        self.meetingCode = meetingCode
        self.attendees = attendees
        self.urlString = urlString
    }
}

public enum UpcomingMeetings {
    /// Builds today's remaining-meeting rows from event snapshots:
    /// - within `now`'s calendar day (America/Sao_Paulo by default — the user's tz),
    /// - whose END is still in the future (a meeting whose end passed drops),
    /// - excluding any whose code is in `recordedCodes` (already recorded /
    ///   recording — the row disappears),
    /// - INCLUDING calendars without a Meet link (every scanned calendar; the
    ///   §4b list is not Meet-gated). An event with neither attendees nor a link
    ///   is still a real meeting — it surfaces (the user can always Record).
    ///
    /// `userEmail` self-excludes the user from each row's prefilled attendees
    /// (case-insensitive; empty identity no-ops, G3). Sorted by start then
    /// title. Empty when nothing remains (the deferred section collapses to
    /// nothing — no "no meetings" chrome).
    public static func rows(
        from events: [CalendarEventSnapshot],
        now: Date,
        recordedCodes: Set<String> = [],
        userEmail: String,
        calendar: Calendar = saoPauloCalendar
    ) -> [UpcomingMeetingRow] {
        let userEmailFolded = userEmail.lowercased()
        let selfExcludes = !userEmailFolded.isEmpty
        return events
            .filter { event in
                // Today (now's calendar day) AND end still in the future.
                calendar.isDate(event.start, inSameDayAs: now) && event.end > now
            }
            .compactMap { event -> UpcomingMeetingRow? in
                let linkText = [event.location, event.notes, event.urlString]
                    .compactMap { $0 }.joined(separator: "\n")
                let code = MeetLinkParser.meetingCode(from: linkText)
                // A row already recorded (by code) disappears.
                if let code, recordedCodes.contains(code) { return nil }
                let source = CalendarSuggestionBuilder.source(forLinkText: linkText, code: code)
                let attendees = event.attendees
                    .filter { !selfExcludes || ($0.email ?? "").lowercased() != userEmailFolded }
                    .map { Attendee(name: $0.name, email: $0.email, source: .calendar) }
                return UpcomingMeetingRow(
                    eventIdentifier: event.eventIdentifier, title: event.title,
                    start: event.start, end: event.end, attendeeCount: attendees.count,
                    source: source, meetingCode: code, attendees: attendees,
                    urlString: meetURLString(event: event, linkText: linkText, code: code))
            }
            .sorted { ($0.start, $0.title) < ($1.start, $1.title) }
    }

    /// America/Sao_Paulo (the user's timezone) — the day-grouping reference for the
    /// "Today" scoping and the day-rollover refresh.
    public static var saoPauloCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Sao_Paulo") ?? .current
        return calendar
    }

    /// The day-rollover trigger: true when `now` and `lastRefresh` fall on
    /// different calendar days — the list must rebuild (yesterday's rows are
    /// gone, today's appear). The adapter polls this beside the suggestion
    /// cadence (§4b).
    public static func dayChanged(
        from lastRefresh: Date, to now: Date, calendar: Calendar = saoPauloCalendar
    ) -> Bool {
        !calendar.isDate(lastRefresh, inSameDayAs: now)
    }

    private static func meetURLString(
        event: CalendarEventSnapshot, linkText: String, code: String?
    ) -> String? {
        guard code != nil else { return nil }
        let pattern = #"https?://meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}[^\s>"']*"#
        if let range = linkText.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
            return String(linkText[range])
        }
        return code.map { "https://meet.google.com/\($0)" }
    }
}
