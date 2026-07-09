import Foundation
import os

// C14: calendar pre-meeting "Launch & Record" notifications.
// `CalendarSuggestionBuilder` stays the parsing/matching core; this actor
// extends it into time. Pure over injected snapshots + a fake clock in
// tests; the EventKit adapter (BlaiseApp) re-fetches a rolling 24 h window
// every 5 min and on EKEventStoreChanged — armed ONLY when EventKit access
// is already granted.

public actor PreMeetingScheduler {
    /// The notification fires at `start − 60 s` (a constant, not a setting).
    public static let leadSeconds: TimeInterval = 60
    /// Unconditional withdrawal at `start + 15 min` — a stale "Launch &
    /// Record" hours later would restart the forget-to-stop incident this
    /// chunk exists to kill.
    public static let validitySeconds: TimeInterval = 15 * 60
    /// Adapter refresh cadence.
    public static let refreshIntervalSeconds: TimeInterval = 5 * 60

    public enum CodeRecordingState: Sendable, Equatable {
        case recording, grace, idle
    }

    private let notifier: any AutomationNotifying
    /// Is this code currently recording / in grace? (tracker + controller).
    private let recordingState: @Sendable (String) async -> CodeRecordingState
    /// Already done: a meeting row with this code whose `endedAt` falls
    /// inside the event window — the call was recorded and ended before a
    /// restart; re-firing Launch & Record would invite recording a dead
    /// meeting.
    private let alreadyDone: @Sendable (_ code: String, _ windowStart: Date, _ windowEnd: Date) async -> Bool
    private let now: @Sendable () -> Date
    private let logger = Logger(subsystem: BlaiseBundle.identifier, category: "automation.calendar")

    private var snapshots: [CalendarEventSnapshot] = []
    /// In-memory by design: the fired-set dies with the process, so a
    /// duplicate notification after a restart is accepted — restart must
    /// not eat the reminder.
    private var fired: Set<String> = []
    private var withdrawn: Set<String> = []
    /// Posted-and-still-valid notifications, for targeted withdrawal on
    /// recording-start / call-ended.
    private var postedByCode: [String: Set<String>] = [:]

    public init(
        notifier: any AutomationNotifying,
        recordingState: @escaping @Sendable (String) async -> CodeRecordingState,
        alreadyDone: @escaping @Sendable (String, Date, Date) async -> Bool,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.notifier = notifier
        self.recordingState = recordingState
        self.alreadyDone = alreadyDone
        self.now = now
    }

    public static func eventKey(_ event: CalendarEventSnapshot) -> String {
        "\(event.eventIdentifier)|\(Int64(event.start.timeIntervalSince1970 * 1000))"
    }

    public func update(snapshots: [CalendarEventSnapshot]) async {
        // Withdraw any posted Launch & Record notification whose event has
        // VANISHED from the new snapshot set — e.g. the user hid or disabled its
        // calendar. `evaluate()` only visits events still present, so a vanished
        // one would otherwise linger until time-expiry. Clearing fired/withdrawn
        // lets it re-post if the event later returns (un-hidden).
        let presentKeys = Set(snapshots.map(Self.eventKey))
        let posted = postedByCode  // copy to iterate while mutating the original
        for (code, keys) in posted {
            for key in keys where !presentKeys.contains(key) {
                await notifier.withdrawCalendarUpcoming(eventKey: key)
                postedByCode[code]?.remove(key)
                fired.remove(key)
                withdrawn.remove(key)
            }
        }
        postedByCode = postedByCode.filter { !$0.value.isEmpty }
        self.snapshots = snapshots
        await evaluate()
    }

    /// Fire/expire pass — the adapter calls it on refresh and on a short
    /// timer; tests call it directly with a fake clock.
    public func evaluate() async {
        let reference = now()
        for event in snapshots {
            let linkText = [event.location, event.notes, event.urlString]
                .compactMap { $0 }.joined(separator: "\n")
            guard let code = MeetLinkParser.meetingCode(from: linkText) else { continue }
            let key = Self.eventKey(event)
            let fireAt = event.start.addingTimeInterval(-Self.leadSeconds)
            let expireAt = event.start.addingTimeInterval(Self.validitySeconds)

            if reference >= expireAt {
                if !withdrawn.contains(key) {
                    withdrawn.insert(key)
                    if fired.contains(key) {
                        await notifier.withdrawCalendarUpcoming(eventKey: key)
                        postedByCode[code]?.remove(key)
                    }
                }
                continue
            }
            guard reference >= fireAt, !fired.contains(key) else { continue }
            // Skips: already recording or in grace (Launch & Record is
            // moot), or already recorded-and-ended inside the event window
            // (post-restart re-fire guard for a dead meeting).
            switch await recordingState(code) {
            case .recording, .grace:
                fired.insert(key)
                continue
            case .idle:
                break
            }
            if await alreadyDone(code, event.start, event.end) {
                fired.insert(key)
                continue
            }
            fired.insert(key)
            postedByCode[code, default: []].insert(key)
            await notifier.postCalendarUpcoming(
                eventKey: key, title: event.title, start: event.start, code: code,
                urlString: meetURLString(linkText: linkText, code: code))
            logger.notice("calendar Launch & Record posted for \(code, privacy: .private)")
        }
    }

    /// Withdraws the notification when a recording for its code starts by
    /// any path or when `call-ended` lands for the code (the tracker's
    /// `calendarHook` feeds both).
    public func withdrawForCode(_ code: String) async {
        guard let keys = postedByCode.removeValue(forKey: code) else { return }
        for key in keys {
            await notifier.withdrawCalendarUpcoming(eventKey: key)
        }
    }

    /// The Meet URL the Launch & Record action opens (in Chrome, never the
    /// default browser). Reconstructed from the code when the event carried
    /// a bare code rather than a full link.
    private func meetURLString(linkText: String, code: String) -> String {
        let pattern = #"https?://meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}[^\s>"']*"#
        if let range = linkText.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
            return String(linkText[range])
        }
        return "https://meet.google.com/\(code)"
    }
}
