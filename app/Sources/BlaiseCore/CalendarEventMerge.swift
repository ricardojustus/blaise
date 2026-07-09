import Foundation

/// Combines snapshots from multiple calendar providers into the single stream
/// the suggestion, upcoming-list, scheduler, and end-anchor logic consume.
///
/// EventKit and Google Calendar often expose the same meeting with different
/// identifiers (commonly because macOS Calendar SUBSCRIBES to the same Google
/// account the direct API reads). Deduplication keys on a Meet code plus the
/// start MINUTE (the strongest user-visible identity), then on title + start/end
/// minute. Minute resolution tolerates the sub-minute drift between providers for
/// the same occurrence while still separating distinct occurrences of a recurring
/// series (which share a Meet code but start minutes/days apart). The merge keeps
/// useful detail from either side: first non-empty link fields and a de-duplicated
/// attendee list.
public enum CalendarEventMerger {
    public static func merged(_ events: [CalendarEventSnapshot]) -> [CalendarEventSnapshot] {
        // Union-find over dedupe keys. Each event unions ITS OWN keys together,
        // so two events that share ANY key (Meet code OR title+span) — even
        // transitively through a third event — collapse into one group. The
        // earlier "first existing key wins" approach left a duplicate row (and
        // orphaned the other bucket's attendees) when an event's two keys
        // pointed at two already-distinct buckets; union-find unifies them.
        var parent: [String: String] = [:]
        func root(_ key: String) -> String {
            var r = key
            while let next = parent[r], next != r { r = next }
            var cur = key
            while let next = parent[cur], next != r {
                parent[cur] = r
                cur = next
            }
            return r
        }
        func union(_ a: String, _ b: String) {
            let ra = root(a)
            let rb = root(b)
            if ra != rb { parent[rb] = ra }
        }

        let keysPerEvent = events.map(dedupeKeys)
        for keys in keysPerEvent {
            for key in keys where parent[key] == nil { parent[key] = key }
            for key in keys.dropFirst() { union(keys[0], key) }
        }

        var byRoot: [String: CalendarEventSnapshot] = [:]
        var order: [String] = []
        for (index, event) in events.enumerated() {
            // `dedupeKeys` always yields at least the title key, so [0] is safe.
            let key = root(keysPerEvent[index][0])
            if let existing = byRoot[key] {
                byRoot[key] = merge(existing, event)
            } else {
                byRoot[key] = event
                order.append(key)
            }
        }

        return order
            .compactMap { byRoot[$0] }
            .sorted { ($0.start, $0.title, $0.eventIdentifier) < ($1.start, $1.title, $1.eventIdentifier) }
    }

    private static func dedupeKeys(_ event: CalendarEventSnapshot) -> [String] {
        let linkText = [event.location, event.notes, event.urlString]
            .compactMap { $0 }.joined(separator: "\n")
        var keys: [String] = []
        if let code = MeetLinkParser.meetingCode(from: linkText) {
            keys.append("meet|\(code)|\(minute(event.start))")
        }
        keys.append("event|\(event.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(minute(event.start))|\(minute(event.end))")
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

    /// The start/end MINUTE since the epoch (nearest), so two providers'
    /// sub-minute-different timestamps for the same occurrence collide.
    private static func minute(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 / 60).rounded())
    }
}
