import Foundation

/// Which calendar IDs to fetch events from, given the full list and the user's
/// hidden set — the per-source picker's filtering rule (F3). Pure so the
/// empty-hidden=all / all-hidden=none / empty-fallback invariants are pinned.
public enum CalendarVisibility {
    /// The non-hidden calendar IDs. When the provider returns NO calendars, fall
    /// back to `emptyFallback` ONLY if nothing is hidden — so a user who has
    /// hidden calendars never gets a divergent fallback id resurrected.
    public static func visibleCalendarIDs(
        available: [String], hidden: Set<String>, emptyFallback: String = "primary"
    ) -> [String] {
        if available.isEmpty {
            return hidden.isEmpty ? [emptyFallback] : []
        }
        return available.filter { !hidden.contains($0) }
    }
}
