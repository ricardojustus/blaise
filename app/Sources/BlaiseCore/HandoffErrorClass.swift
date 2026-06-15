import Foundation

/// Reserved `handoff_queue.last_error` prefix registry (C8 spec §quarantine;
/// recorded C1 amendment). C1's "failed is retriable bookkeeping" gains two
/// RESERVED prefixes owned by C8:
///
/// - `damaged:` — payload-integrity quarantine. Wake-exempt: the FIFO scan
///   skips these rows so a poisoned item cannot starve the queue; app
///   relaunch re-checks once (C8 resets them to `pending`, and the
///   pre-stream self-check re-quarantines if still bad).
/// - `superseded:` — terminal per decision D12: a NEWER payload for the
///   same meeting was verified delivered, so the older undelivered row is
///   closed as content-superseded (never silently dropped).
///
/// Every consumer of queue rows (C8 worker, C10 retry-all, anything future)
/// MUST compile against these constants — no string scattering.
public enum HandoffErrorClass {
    public static let damagedPrefix = "damaged:"
    public static let supersededPrefix = "superseded:"

    /// `last_error` value for a payload-integrity quarantine.
    public static func damaged(_ detail: String) -> String {
        damagedPrefix + " " + detail
    }

    /// `last_error` value for a D12 supersession closure — exactly
    /// `superseded:<newer hash>` per the C8 spec.
    public static func superseded(byNewerHash hash: String) -> String {
        supersededPrefix + hash
    }

    public static func isDamaged(_ lastError: String?) -> Bool {
        lastError?.hasPrefix(damagedPrefix) ?? false
    }

    public static func isSuperseded(_ lastError: String?) -> Bool {
        lastError?.hasPrefix(supersededPrefix) ?? false
    }

    /// True when the row is under reserved-prefix semantics (quarantined or
    /// terminally closed) — the worker's FIFO scan and C10's retry-all must
    /// not treat it as plainly retriable.
    public static func isReserved(_ lastError: String?) -> Bool {
        isDamaged(lastError) || isSuperseded(lastError)
    }
}
