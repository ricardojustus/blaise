import Foundation

// C11 (B-6): calendar-aware start suggestions + Meet-link parsing. Pure
// logic here (unit-tested over fixture snapshots); the EventKit adapter in
// BlaiseApp maps EKEvent → CalendarEventSnapshot and only ever runs after
// the user opts in (EventKit full access is its own TCC prompt).

// MARK: - Meet link parsing

public enum MeetLinkParser {
    /// Extracts a Google Meet meeting code ("abc-defg-hij") from arbitrary
    /// text: a meet.google.com link (with or without scheme/query) or a bare
    /// pasted code. nil when nothing matches — never a guess.
    public static func meetingCode(from text: String) -> String? {
        let pattern = #"(?:meet\.google\.com/)([a-z]{3}-[a-z]{4}-[a-z]{3})\b"#
        if let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
            let match = String(text[range])
            return String(match.split(separator: "/").last!).lowercased()
        }
        let bare = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if bare.range(of: #"^[a-z]{3}-[a-z]{4}-[a-z]{3}$"#, options: .regularExpression) != nil {
            return bare
        }
        return nil
    }
}

// MARK: - Calendar suggestions

/// EventKit-free event snapshot (EKEvent is mapped to this at the adapter).
public struct CalendarEventSnapshot: Sendable, Equatable {
    /// The EKEvent identifier, mapped at the adapter (C14: the
    /// pre-meeting-notification fired-set key, with `start`).
    public var eventIdentifier: String
    public var title: String
    public var start: Date
    public var end: Date
    public var location: String?
    public var notes: String?
    public var urlString: String?
    public var attendees: [AttendeeSnapshot]

    public struct AttendeeSnapshot: Sendable, Equatable {
        public var name: String
        public var email: String?

        public init(name: String, email: String? = nil) {
            self.name = name
            self.email = email
        }
    }

    public init(
        eventIdentifier: String = "",
        title: String, start: Date, end: Date, location: String? = nil,
        notes: String? = nil, urlString: String? = nil, attendees: [AttendeeSnapshot] = []
    ) {
        self.eventIdentifier = eventIdentifier
        self.title = title
        self.start = start
        self.end = end
        self.location = location
        self.notes = notes
        self.urlString = urlString
        self.attendees = attendees
    }
}

/// A one-click start: title + attendees prefilled, Meet code parsed from the
/// event's location/notes/URL.
public struct MeetingSuggestion: Sendable, Equatable {
    public var title: String
    public var start: Date
    public var source: MeetingSource
    public var meetingCode: String?
    public var attendees: [Attendee]
    /// G11 §1: the matched event's scheduled end — carried so a start bound to
    /// this suggestion can persist the §1 anchor (`scheduled_end_ms`) that the
    /// §2 classifier reads. nil for a manual/ad-hoc suggestion with no event.
    public var end: Date?
    /// G11 §1: the matched event's identifier — persisted as `calendar_event_id`
    /// at start. nil for a manual/ad-hoc suggestion.
    public var eventIdentifier: String?
    public var joinedLinkText: String?

    public init(
        title: String, start: Date, source: MeetingSource, meetingCode: String?,
        attendees: [Attendee], end: Date? = nil, eventIdentifier: String? = nil,
        joinedLinkText: String? = nil
    ) {
        self.title = title
        self.start = start
        self.source = source
        self.meetingCode = meetingCode
        self.attendees = attendees
        self.end = end
        self.eventIdentifier = eventIdentifier
        self.joinedLinkText = joinedLinkText
    }
}

/// G11 §1: the calendar anchor a suggestion-matched start persists ONCE at
/// meeting start (`calendar_event_id` + `scheduled_end_ms`). nil throughout a
/// start = ad-hoc (both columns stay NULL). Carried by every start path.
public struct CalendarAnchor: Sendable, Equatable {
    public var eventIdentifier: String?
    public var scheduledEnd: Date

    public init(eventIdentifier: String?, scheduledEnd: Date) {
        self.eventIdentifier = eventIdentifier
        self.scheduledEnd = scheduledEnd
    }

    /// The anchor a suggestion carries, if it was a calendar-matched one (it
    /// has a scheduled end). A manual/ad-hoc suggestion (no `end`) yields nil.
    public init?(suggestion: MeetingSuggestion) {
        guard let end = suggestion.end else { return nil }
        self.eventIdentifier = suggestion.eventIdentifier
        self.scheduledEnd = end
    }

    public var scheduledEndMs: Int64 { Int64(scheduledEnd.timeIntervalSince1970 * 1000) }
}

public enum CalendarSuggestionBuilder {
    /// A just-started meeting still surfaces if it began within this look-BACK
    /// (you opened the menu a few minutes late).
    public static let lookbackSeconds: TimeInterval = 15 * 60
    /// Upcoming meetings surface this far AHEAD, so the menu is not empty unless
    /// you happen to open it within minutes of a meeting. (The Upcoming list is
    /// the comprehensive surface; the menu is the menu-bar quick-record glance.)
    public static let lookaheadSeconds: TimeInterval = 2 * 60 * 60
    /// G11 §4 (v3.2): the lead before an event's start at which a start binds
    /// to it — widened from "start vicinity only" to the WHOLE scheduled span
    /// (a real Zoom meeting joined mid-way went undetected). A start binds when
    /// it falls within [event.start − 15 min, event.end].
    public static let bindLeadSeconds: TimeInterval = 15 * 60

    /// Builds suggestions from event snapshots: current + upcoming events (a
    /// short look-back through a 2-hour look-ahead) that
    /// have attendees or a meeting link. The prefilled attendee list is the
    /// event's list LITERAL — the user is not filtered out of it; he is implicit
    /// in every meeting and the counting rule subtracts him structurally
    /// (`Attendee.othersCount`), which email matching could not do reliably.
    /// Source inferred from the link: a meet code → .meet, a zoom/teams host →
    /// .zoom/.teams, any other http(s) link or bare recognized-host mention —
    /// unrecognized platform or a recognized one with no branch of its own — →
    /// .online, and only a genuinely link-free event → .inPerson. Carries the event's
    /// `end`/`eventIdentifier` for the §1 anchor.
    public static func suggestions(
        from events: [CalendarEventSnapshot], now: Date
    ) -> [MeetingSuggestion] {
        events
            .filter {
                let delta = $0.start.timeIntervalSince(now)
                return delta >= -lookbackSeconds && delta <= lookaheadSeconds
            }
            .compactMap { event -> MeetingSuggestion? in
                let linkText = [event.location, event.notes, event.urlString]
                    .compactMap { $0 }.joined(separator: "\n")
                let code = MeetLinkParser.meetingCode(from: linkText)
                let hasLink = code != nil
                    || linkText.localizedCaseInsensitiveContains("zoom.us")
                    || linkText.localizedCaseInsensitiveContains("teams.microsoft.com")
                guard !event.attendees.isEmpty || hasLink else { return nil }
                let source = source(forLinkText: linkText, code: code)
                let attendees = event.attendees
                    .map { Attendee(name: $0.name, email: $0.email, source: .calendar) }
                return MeetingSuggestion(
                    title: event.title, start: event.start, source: source,
                    meetingCode: code, attendees: attendees,
                    end: event.end, eventIdentifier: event.eventIdentifier,
                    joinedLinkText: linkText)
            }
            .sorted { ($0.start, $0.title) < ($1.start, $1.title) }
    }

    /// G11 §4 (miss-class fix): the calendar EVENT a start should bind to (the
    /// §1 anchor source) — independent of the suggestion-surfacing window and
    /// of Meet-link presence (link extraction gates the Launch & Record
    /// affordance only, NOT anchoring). A start binds to an event when it falls
    /// within [event.start − 15 min, event.end]; among multiple candidates the
    /// event whose span COVERS the start wins, else the nearest start. Returns
    /// nil when no event covers the start in its bind window (ad-hoc).
    ///
    /// FIELD EXHIBIT (§4): default-titled meetings still bind — title is never
    /// a matching input; only the time span and (where present) the meeting
    /// code are.
    public static func bindingEvent(
        for startTime: Date, code: String?, in events: [CalendarEventSnapshot]
    ) -> CalendarEventSnapshot? {
        let candidates = events.filter { event in
            // Code-matched events bind regardless of time vicinity (a
            // correlated start IS this event); otherwise the start must fall in
            // the bind window of the whole scheduled span.
            if let code, let eventCode = meetingCode(of: event), eventCode == code {
                return true
            }
            let windowOpen = event.start.addingTimeInterval(-bindLeadSeconds)
            return startTime >= windowOpen && startTime <= event.end
        }
        guard !candidates.isEmpty else { return nil }
        // Prefer an event whose span covers the start; among those (or, if
        // none cover, among all candidates) the nearest start wins.
        let covering = candidates.filter { startTime >= $0.start && startTime <= $0.end }
        let pool = covering.isEmpty ? candidates : covering
        return pool.min {
            abs($0.start.timeIntervalSince(startTime)) < abs($1.start.timeIntervalSince(startTime))
        }
    }

    /// G11 §4 (v3.2 wiring): the calendar anchor a QUICK-START (no surfaced
    /// suggestion) should persist — the headline late-join / undetected-Zoom
    /// fix. Finds the event the start binds to (`bindingEvent`), then anchors
    /// ONLY when that event's span actually COVERS `startTime`: a covering
    /// event gives a real `scheduled_end_ms` the §2 classifier can Rule-1.
    /// A pre-start (within the −15 min lead but before the event begins) or a
    /// bare-nearest candidate that does not cover the start stays ad-hoc — we
    /// never anchor a start to a meeting it is not actually inside, which would
    /// fabricate a `scheduled_end_ms` for a still-unstarted event. Returns nil
    /// = ad-hoc (both §1 columns stay NULL). Respects §1 "written once at
    /// start when matched"; callers only invoke this when no anchor was already
    /// supplied (a surfaced suggestion's anchor wins).
    public static func quickStartAnchor(
        for startTime: Date, code: String?, in events: [CalendarEventSnapshot]
    ) -> CalendarAnchor? {
        guard let event = bindingEvent(for: startTime, code: code, in: events) else { return nil }
        // Anchor only on actual coverage. A code-match outside the time span
        // (the user pasted a link for a meeting not yet started, or long over)
        // is a surfacing/correlation concern, not an end-anchor — without
        // coverage there is no trustworthy "currently scheduled to end" time.
        guard startTime >= event.start && startTime <= event.end else { return nil }
        return CalendarAnchor(eventIdentifier: event.eventIdentifier, scheduledEnd: event.end)
    }

    /// The Meet code embedded in an event's link fields, if any.
    public static func meetingCode(of event: CalendarEventSnapshot) -> String? {
        let linkText = [event.location, event.notes, event.urlString]
            .compactMap { $0 }.joined(separator: "\n")
        return MeetLinkParser.meetingCode(from: linkText)
    }

    static func source(forLinkText linkText: String, code: String?) -> MeetingSource {
        if code != nil {
            return .meet
        } else if linkText.localizedCaseInsensitiveContains("zoom.us") {
            return .zoom
        } else if linkText.localizedCaseInsensitiveContains("teams.microsoft.com") {
            return .teams
        } else if CaptureLinkClassifier.containsGenericLink(in: linkText) {
            // An http(s) link on an unrecognized platform: still an online
            // meeting. `.inPerson` is reserved for a genuinely link-free event.
            return .online
        } else if CaptureLinkClassifier.containsRecognizedLink(in: linkText) {
            // A recognized platform with no branch above — a Slack huddle link,
            // or a meet.google.com URL carrying no parseable code. Still an
            // online meeting: a link-bearing event must never read `.inPerson`.
            return .online
        } else {
            return .inPerson
        }
    }
}
