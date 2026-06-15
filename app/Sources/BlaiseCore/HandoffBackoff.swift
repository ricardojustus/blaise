import Foundation

/// Two-level retry parameters (C8 spec; full-jitter exponential backoff per
/// the AWS recommendation — `delay = random(0, min(cap, base·2^n))`).
///
/// Item level (delivery failed while a host was reachable): base 30 s, ×2,
/// cap 15 min; class floors override (auth 1 h, host-key/disk 15 min).
/// Host level (circuit breaker): base 10 s, ×2, cap 5 min, per host.
/// Every EXTERNAL wake (kick/launch/path-change) clears all item floors AND
/// all host benches + strike counts — the fixed-key-on-next-kick guarantee
/// is breaker-inclusive.
public enum HandoffBackoff {
    public static let itemBase: TimeInterval = 30
    public static let itemCap: TimeInterval = 15 * 60
    public static let hostBase: TimeInterval = 10
    public static let hostCap: TimeInterval = 5 * 60
    /// Auth will not self-heal — retry only at this floor (or on a wake).
    public static let authFloor: TimeInterval = 60 * 60
    /// Host-key mismatch: alert state, no retry burn.
    public static let hostKeyFloor: TimeInterval = 15 * 60
    public static let remoteDiskFloor: TimeInterval = 15 * 60
    /// Strikes before a TCP-reachable host that keeps failing ssh is benched.
    public static let benchStrikeLimit = 3

    /// Upper bound of the jitter window: `min(cap, base·2^exponent)`.
    /// `exponent` clamps at 20 (the cap dominates long before).
    public static func ceiling(base: TimeInterval, cap: TimeInterval, exponent: Int) -> TimeInterval {
        let clamped = min(max(exponent, 0), 20)
        return min(cap, base * pow(2, Double(clamped)))
    }

    /// Full-jitter delay. `random` is the injectable uniform-[0, x] source.
    public static func fullJitter(
        base: TimeInterval, cap: TimeInterval, exponent: Int,
        random: (TimeInterval) -> TimeInterval = { TimeInterval.random(in: 0...$0) }
    ) -> TimeInterval {
        random(ceiling(base: base, cap: cap, exponent: exponent))
    }
}
