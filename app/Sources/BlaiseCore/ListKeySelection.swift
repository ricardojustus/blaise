// Arrow-key selection advance for the meeting list (and any flat-ordered
// selectable list). The list view is a ScrollView + LazyVStack (the launch
// squished-cards fix ruled out SwiftUI List), so keyboard selection is
// hand-wired: the view supplies the visible flat row order (across day
// groups) and this pure function answers "where does ↑/↓ go" with native
// NSTableView semantics — testable without a window.

public enum ListKeySelection {
    /// The row that ↑ (`delta` -1) or ↓ (`delta` +1) should select.
    ///
    /// - `order`: the visible rows, top to bottom, across group headers.
    /// - No current selection (or a selection no longer in `order`, e.g.
    ///   filtered away): ↓ selects the first row, ↑ the last — native
    ///   list behavior.
    /// - Clamps at both ends; an empty list leaves the selection untouched.
    public static func moved<ID: Equatable>(
        from current: ID?, in order: [ID], delta: Int
    ) -> ID? {
        guard !order.isEmpty else { return current }
        guard let current, let index = order.firstIndex(of: current) else {
            return delta >= 0 ? order.first : order.last
        }
        return order[min(max(index + delta, 0), order.count - 1)]
    }
}
