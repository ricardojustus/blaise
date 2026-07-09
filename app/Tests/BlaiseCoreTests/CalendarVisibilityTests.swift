import Foundation
import Testing

@testable import BlaiseCore

/// Pins the F3 per-calendar visibility rule (empty-hidden = all, all-hidden =
/// none, and the empty-list "primary" fallback that must NOT fire once the user
/// has hidden anything).
@Suite struct CalendarVisibilityTests {
    @Test("empty hidden set shows all calendars, order preserved")
    func emptyHiddenShowsAll() {
        #expect(
            CalendarVisibility.visibleCalendarIDs(available: ["a", "b", "c"], hidden: [])
                == ["a", "b", "c"])
    }

    @Test("hidden calendars are excluded")
    func hiddenExcluded() {
        #expect(
            CalendarVisibility.visibleCalendarIDs(available: ["a", "b", "c"], hidden: ["b"])
                == ["a", "c"])
    }

    @Test("all hidden shows none")
    func allHiddenShowsNone() {
        #expect(
            CalendarVisibility.visibleCalendarIDs(available: ["a", "b"], hidden: ["a", "b"]).isEmpty)
    }

    @Test("empty list + nothing hidden falls back to primary")
    func emptyListFallsBackToPrimary() {
        #expect(CalendarVisibility.visibleCalendarIDs(available: [], hidden: []) == ["primary"])
    }

    @Test("empty list + something hidden does NOT resurrect primary")
    func emptyListNoFallbackWhenHidden() {
        #expect(
            CalendarVisibility.visibleCalendarIDs(available: [], hidden: ["x"]).isEmpty)
    }
}
