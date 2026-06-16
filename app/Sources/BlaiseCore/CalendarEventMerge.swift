import Foundation

/// Combines snapshots from multiple calendar providers into the single stream
/// the suggestion, upcoming-list, scheduler, and end-anchor logic consume.
///
/// EventKit and Google Calendar often expose the same meeting with different
/// identifiers. Deduplication therefore keys first on a Meet code plus start
/// time (the strongest user-visible identity), then on title/start/end. The
/// merge keeps useful detail from either side: first non-empty link fields and
/// a de-duplicated attendee list.
public enum CalendarEventMerger {
    public static func merged(_ events: [CalendarEventSnapshot]) -> [CalendarEventSnapshot] {
        var canonicalByKey: [String: String] = [:]
        var byCanonicalKey: [String: CalendarEventSnapshot] = [:]
        var order: [String] = []

        for event in events {
            let keys = dedupeKeys(event)
            let canonical = keys.compactMap { canonicalByKey[$0] }.first ?? keys[0]
            if var existing = byCanonicalKey[canonical] {
                existing = merge(existing, event)
                byCanonicalKey[canonical] = existing
            } else {
                byCanonicalKey[canonical] = event
                order.append(canonical)
            }
            for key in keys {
                canonicalByKey[key] = canonical
            }
        }

        return order
            .compactMap { byCanonicalKey[$0] }
            .sorted { ($0.start, $0.title, $0.eventIdentifier) < ($1.start, $1.title, $1.eventIdentifier) }
    }

    private static func dedupeKeys(_ event: CalendarEventSnapshot) -> [String] {
        let linkText = [event.location, event.notes, event.urlString]
            .compactMap { $0 }.joined(separator: "\n")
        var keys: [String] = []
        if let code = MeetLinkParser.meetingCode(from: linkText) {
            keys.append("meet|\(code)|\(millis(event.start))")
        }
        keys.append("event|\(event.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(millis(event.start))|\(millis(event.end))")
        return keys
    }

    private static func merge(
        _ lhs: CalendarEventSnapshot, _ rhs: CalendarEventSnapshot
    ) -> CalendarEventSnapshot {
        CalendarEventSnapshot(
            eventIdentifier: lhs.eventIdentifier.isEmpty ? rhs.eventIdentifier : lhs.eventIdentifier,
            title: lhs.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? rhs.title : lhs.title,
            start: min(lhs.start, rhs.start),
            end: max(lhs.end, rhs.end),
            location: firstNonEmpty(lhs.location, rhs.location),
            notes: firstNonEmpty(lhs.notes, rhs.notes),
            urlString: firstNonEmpty(lhs.urlString, rhs.urlString),
            attendees: mergedAttendees(lhs.attendees, rhs.attendees))
    }

    private static func mergedAttendees(
        _ lhs: [CalendarEventSnapshot.AttendeeSnapshot],
        _ rhs: [CalendarEventSnapshot.AttendeeSnapshot]
    ) -> [CalendarEventSnapshot.AttendeeSnapshot] {
        var seen = Set<String>()
        var result: [CalendarEventSnapshot.AttendeeSnapshot] = []
        for attendee in lhs + rhs {
            let key = (attendee.email ?? attendee.name)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            result.append(attendee)
        }
        return result
    }

    private static func firstNonEmpty(_ lhs: String?, _ rhs: String?) -> String? {
        if let value = lhs?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return lhs
        }
        if let value = rhs?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return rhs
        }
        return nil
    }

    private static func millis(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }
}
