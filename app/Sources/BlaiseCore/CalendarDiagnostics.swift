import Foundation

// G11 §4: calendar-reliability diagnostics — the PURE model behind the
// (deferred) Settings → Calendar diagnostic surface. It classifies each
// candidate event as bindable-or-not against the §4 widened binding window,
// names the miss class for a rejected one, and builds two line variants per
// candidate: a FULL one for the UI (carries the event title) and a REDACTED
// one for the unified log (NO title — privacy discipline, round-1 M-4). The
// UI render batches to the deploy ask; the model + its formatter are headless
// and unit-pinned here (AC5).

/// Why a calendar candidate did NOT anchor a start — the miss classes the
/// diagnose-first protocol enumerates (§4). `.bindable` is the success case.
public enum CalendarMissClass: String, Sendable, Equatable, CaseIterable {
    /// The event would bind — no miss.
    case bindable
    /// (a) The event's calendar is excluded from the scan set.
    case excludedCalendar
    /// (b) A pending invite (the user has not accepted) — surfaced but not
    /// auto-bound.
    case pendingInvite
    /// (c) A recurring series that did not expand to a concrete instance in
    /// the scanned window.
    case recurringNotExpanded
    /// (d) The event falls outside the scanned time window (refresh cadence /
    /// horizon) — it was never fetched.
    case outsideWindow
    // §4 v3.2 supersedes the former (e) "Meet-link unparsed" miss: a calendar
    // match anchors a meeting regardless of whether a Meet link parses — link
    // extraction gates the Launch & Record affordance only, never matching. An
    // unparsed link is therefore NOT an anchor miss; such an event is `.bindable`.
}

/// One diagnosed calendar candidate (the surface's per-row datum). Pure; the
/// adapter maps EventKit state (calendar membership, invite status, recurrence)
/// onto the inputs.
public struct CalendarCandidateDiagnostic: Sendable, Equatable {
    public var eventIdentifier: String
    public var title: String
    public var start: Date
    public var end: Date
    /// The parsed Meet code, if any (nil = no Meet link or unparsable).
    public var meetingCode: String?
    public var missClass: CalendarMissClass

    public var bindable: Bool { missClass == .bindable }

    public init(
        eventIdentifier: String, title: String, start: Date, end: Date,
        meetingCode: String?, missClass: CalendarMissClass
    ) {
        self.eventIdentifier = eventIdentifier
        self.title = title
        self.start = start
        self.end = end
        self.meetingCode = meetingCode
        self.missClass = missClass
    }
}

/// Per-candidate adapter-supplied facts the pure classifier cannot derive from
/// a snapshot alone (calendar membership, invite acceptance, recurrence
/// expansion). The EventKit adapter fills these; tests inject them directly.
public struct CalendarCandidateContext: Sendable, Equatable {
    public var snapshot: CalendarEventSnapshot
    /// The event's calendar is in the scan set.
    public var calendarIncluded: Bool
    /// The user has accepted (or owns) the event — not a pending invite.
    public var accepted: Bool
    /// A recurring series expanded to this concrete instance (true for a
    /// single event).
    public var expanded: Bool

    public init(
        snapshot: CalendarEventSnapshot, calendarIncluded: Bool = true,
        accepted: Bool = true, expanded: Bool = true
    ) {
        self.snapshot = snapshot
        self.calendarIncluded = calendarIncluded
        self.accepted = accepted
        self.expanded = expanded
    }
}

public enum CalendarDiagnostics {
    /// Diagnoses each candidate against the §4 binding rules for a hypothetical
    /// start at `now` (the surface shows what WOULD bind right now). The
    /// classes are evaluated in the order a real bind would fail:
    /// excluded-calendar → pending-invite → recurring-not-expanded →
    /// outside-window → bindable (a Meet link is not required to anchor).
    public static func diagnose(
        candidates: [CalendarCandidateContext], now: Date
    ) -> [CalendarCandidateDiagnostic] {
        candidates
            .map { context -> CalendarCandidateDiagnostic in
                let event = context.snapshot
                let code = CalendarSuggestionBuilder.meetingCode(of: event)
                let missClass = classify(context: context, now: now)
                return CalendarCandidateDiagnostic(
                    eventIdentifier: event.eventIdentifier, title: event.title,
                    start: event.start, end: event.end, meetingCode: code, missClass: missClass)
            }
            .sorted { ($0.start, $0.title) < ($1.start, $1.title) }
    }

    private static func classify(
        context: CalendarCandidateContext, now: Date
    ) -> CalendarMissClass {
        let event = context.snapshot
        if !context.calendarIncluded { return .excludedCalendar }
        if !context.accepted { return .pendingInvite }
        if !context.expanded { return .recurringNotExpanded }
        // The §4 widened bind window: [start − 15 min, end].
        let windowOpen = event.start.addingTimeInterval(-CalendarSuggestionBuilder.bindLeadSeconds)
        guard now >= windowOpen, now <= event.end else { return .outsideWindow }
        // §4 v3.2: an in-window, accepted, expanded calendar match BINDS — a
        // NON-MEET event, or one whose Meet link does not parse, still anchors
        // (link extraction gates Launch & Record only, not matching). Bindable,
        // never a miss; the `code` is carried for the affordance, not the anchor.
        return .bindable
    }

    /// AC5 formatter seam: a diagnostic line in two variants. `ui` carries the
    /// event title (shown in the Settings surface only); `log` carries NO title
    /// (the unified-log variant — the call site marks it `.private` per the
    /// logging discipline, but the BUILDER already excludes the title so a
    /// future plain-text log can never leak it).
    public struct DiagnosticLine: Sendable, Equatable {
        public let ui: String
        public let log: String
    }

    public static func line(for diagnostic: CalendarCandidateDiagnostic) -> DiagnosticLine {
        let verdict = diagnostic.bindable ? "binds" : "skipped (\(diagnostic.missClass.rawValue))"
        let codePart = diagnostic.meetingCode.map { " code=\($0)" } ?? ""
        // UI: full, title included.
        let ui = "\(diagnostic.title): \(verdict)\(codePart)"
        // Log: identifier + verdict ONLY — no title, ever.
        let log = "event=\(diagnostic.eventIdentifier): \(verdict)\(codePart)"
        return DiagnosticLine(ui: ui, log: log)
    }
}
