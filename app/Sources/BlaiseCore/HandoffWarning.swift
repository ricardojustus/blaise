import Foundation

// Persistent-failure warning for the handoff queue (owner directive,
// 2026-06-11, refining hard floor 8): TRANSIENT unreachability stays silent
// (the remote host offline must never nag); PERSISTENT failure becomes visible — a
// menu-bar badge, a dismissible main-window banner, and one Notification
// Center notification per failure episode. When delivery succeeds the
// surfaces clear silently.

/// The active warning value carried in `HandoffSnapshot.warning` (nil =
/// no warning). Computed by `HandoffWarningThreshold.evaluate` — a pure
/// function over queue rows — every time the worker publishes.
public struct HandoffWarning: Sendable, Equatable {
    /// Oldest undelivered enqueue time — "unreachable since".
    public var since: Date
    /// DISTINCT meetings waiting (several queued versions of one meeting
    /// count once — the user thinks in meetings, not queue rows).
    public var meetingsWaiting: Int
    /// Short human-readable reason from the latest failure
    /// ("SSH key rejected", "remote destination unreachable").
    public var shortReason: String
    /// Failure-episode identity: the latest error's class token + the newest
    /// undelivered row. Banner dismissal silences ONE episodeKey. A row that
    /// becomes warning-eligible while NOT already in the armed set RE-ARMS the
    /// episode: the key changes (re-notifies, un-dismisses the banner) and the
    /// armed set grows to include it. Further attempts on already-armed rows —
    /// and rows merely LEAVING (delivered/superseded) — never change the key.
    public var episodeKey: String
    /// The undelivered rows (by `createdSeq`) that armed this episode. The
    /// episode is STICKY: once armed it stays active while ANY of these rows is
    /// still undelivered, regardless of a later error-class downgrade (auth →
    /// transient must not silently clear the warning); it clears only when this
    /// set fully drains. The set only GROWS by re-arm (a new eligible row),
    /// never silently by a fresh transient row joining the queue.
    public var armedSeqs: Set<Int64>

    public init(
        since: Date, meetingsWaiting: Int, shortReason: String, episodeKey: String,
        armedSeqs: Set<Int64> = []
    ) {
        self.since = since
        self.meetingsWaiting = meetingsWaiting
        self.shortReason = shortReason
        self.episodeKey = episodeKey
        self.armedSeqs = armedSeqs
    }

    /// "since" label per the user's conventions: 24 h time, day-month prefix only
    /// when the episode started on another day (DD/MM).
    public func sinceLabel(now: Date = Date(), calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = calendar.isDate(since, inSameDayAs: now) ? "HH:mm" : "dd/MM HH:mm"
        return formatter.string(from: since)
    }

    /// The banner/notification sentence (shared so both surfaces agree).
    public func message(now: Date = Date()) -> String {
        let plural = meetingsWaiting == 1 ? "meeting" : "meetings"
        return "Evidence Store unreachable since \(sinceLabel(now: now)) — "
            + "\(meetingsWaiting) \(plural) waiting. Last error: \(shortReason)"
    }
}

/// The persistence threshold (pure, unit-tested). A warning exists when any
/// queue item is undelivered AND at least one of:
///
/// - some item has `attempts >= persistentAttempts` and its latest error is
///   non-transient-shaped (`auth:` / `hostKeyMismatch:`); OR any undelivered
///   item is `damaged:`-quarantined (a damaged payload NEVER self-heals — it
///   is persistent immediately, no attempt or hour wait, since quarantine
///   precedes the delivering claim and never increments attempts);
/// - the OLDEST undelivered item is older than `staleAge` (~1 h), regardless
///   of error shape (hours of silent retrying is persistent by definition);
/// - the worker is paused on `configurationInvalid` (settings validation —
///   deliveries cannot proceed and attempts never grow, so no attempt count
///   would ever trip; it cannot self-heal without the user).
///
/// EPISODE MEMORY (sticky episodes): once a warning episode is active it
/// STAYS active while ANY undelivered row that armed it remains, even if the
/// latest error class downgrades (auth → transient) — the warning clears
/// silently only when that armed set drains (delivery success or
/// supersession). Callers pass the previously active warning as `previous`;
/// the threshold carries the episode forward rather than hiding state in the
/// holder, keeping `evaluate` pure.
public enum HandoffWarningThreshold {
    public static let persistentAttempts = 3
    public static let staleAge: TimeInterval = 60 * 60

    /// Pure threshold over queue rows. `items` may be any set of rows;
    /// delivered and `superseded:`-terminal rows are ignored here, so callers
    /// can pass whatever undelivered query they have. `previous` is the
    /// warning active at the last publish (nil = none), used to keep an armed
    /// episode sticky across error-class downgrades.
    public static func evaluate(
        items: [HandoffItem], configurationInvalid: Bool, now: Date,
        previous: HandoffWarning? = nil
    ) -> HandoffWarning? {
        let undelivered = items.filter {
            $0.state != .delivered && !HandoffErrorClass.isSuperseded($0.lastError)
        }
        guard let oldest = undelivered.min(by: { $0.createdSeq < $1.createdSeq }),
            let newest = undelivered.max(by: { $0.createdSeq < $1.createdSeq })
        else { return nil }

        // Rows that INDEPENDENTLY cause a warning ("eligible"): a persistent
        // shape past the attempt floor, or a damaged quarantine, or — when the
        // queue is stale / config-invalid (queue-wide conditions) — every
        // undelivered row. A fresh TRANSIENT row under the hour is NOT eligible:
        // it neither arms nor re-arms (that would reintroduce the flap).
        let stale = now.timeIntervalSince(oldest.createdAt) >= staleAge
        let perRowEligible = undelivered.filter {
            ($0.attempts >= persistentAttempts && isPersistentShaped($0.lastError))
                || HandoffErrorClass.isDamaged($0.lastError)
        }
        let eligible = (stale || configurationInvalid) ? undelivered : perRowEligible
        let eligibleSeqs = Set(eligible.map(\.createdSeq))
        let perRowEligibleSeqs = Set(perRowEligible.map(\.createdSeq))

        // Episode memory. An active episode stays armed while any of the rows
        // that armed it is still undelivered, even if the threshold no longer
        // trips on the CURRENT error shape (the auth → transient downgrade).
        let undeliveredSeqs = Set(undelivered.map(\.createdSeq))
        let stillArmed = previous.map { $0.armedSeqs.intersection(undeliveredSeqs) } ?? []
        let stickyActive = !stillArmed.isEmpty

        guard !eligibleSeqs.isEmpty || stickyActive else { return nil }

        // "Latest error" = the most recently attempted row that carries one.
        let latestError = undelivered
            .filter { $0.lastError != nil }
            .max { ($0.lastAttemptAt ?? .distantPast, $0.createdSeq) < ($1.lastAttemptAt ?? .distantPast, $1.createdSeq) }?
            .lastError
        let token = configurationInvalid ? "config" : classToken(of: latestError)
        let freshKey = "\(token)|\(newest.createdSeq)"

        // Re-arm: a genuinely NEW persistent failure must NOT be masked behind
        // an armed (possibly dismissed) episode (round-2 M-1). It fires when a
        // PERSISTENT-SHAPED row (auth/hostKey/damaged) is present AND either it
        // is not yet in the armed set (a new failing item, P6) OR a class
        // ESCALATION on an already-armed row would change the freshly-minted
        // key (transient→auth on the armed row itself). A plain transient
        // downgrade or a fresh transient row never re-arms — only the
        // per-row-persistent shapes do, so the auth→transient anti-flap holds.
        let newPersistentRow = stickyActive && !perRowEligibleSeqs.isSubset(of: stillArmed)
        let classEscalation = stickyActive && !perRowEligible.isEmpty && freshKey != previous!.episodeKey
        let newlyEligible = newPersistentRow || classEscalation

        // Carry the ORIGINAL identity only while the episode stays armed AND no
        // new eligible row appeared; a re-arm or a fresh start mints a new key
        // and a new armed set (the union of what survived + the newcomers).
        if stickyActive && !newlyEligible {
            return HandoffWarning(
                since: oldest.createdAt,
                meetingsWaiting: Set(undelivered.map(\.meetingID)).count,
                shortReason: shortReason(latestError: latestError, configurationInvalid: configurationInvalid),
                episodeKey: previous!.episodeKey,
                armedSeqs: stillArmed)
        }
        return HandoffWarning(
            since: oldest.createdAt,
            meetingsWaiting: Set(undelivered.map(\.meetingID)).count,
            shortReason: shortReason(latestError: latestError, configurationInvalid: configurationInvalid),
            episodeKey: freshKey,
            armedSeqs: stillArmed.union(eligibleSeqs))
    }

    /// Error shapes that will not self-heal: ssh auth, host-key mismatch,
    /// and payload-validation quarantine (`damaged:`). Everything else
    /// (host/transfer/plain transient, remote disk) stays silent until the
    /// 1-hour staleness rule catches it.
    public static func isPersistentShaped(_ lastError: String?) -> Bool {
        guard let lastError else { return false }
        return lastError.hasPrefix(HandoffFailureClass.auth.rawValue + ":")
            || lastError.hasPrefix(HandoffFailureClass.hostKeyMismatch.rawValue + ":")
            || HandoffErrorClass.isDamaged(lastError)
    }

    /// The class token of a stored `lastError` ("auth", "hostKeyMismatch",
    /// "damaged", …) — the worker writes `<class>: exit=<…> <stderr tail>`.
    static func classToken(of lastError: String?) -> String {
        guard let lastError, let colon = lastError.firstIndex(of: ":") else { return "none" }
        return String(lastError[..<colon])
    }

    /// Calm short reason for the banner/notification line.
    public static func shortReason(latestError: String?, configurationInvalid: Bool) -> String {
        if configurationInvalid { return "handoff settings invalid" }
        guard let latestError else { return "remote destination unreachable" }
        // Local-folder destination (G5): folder-specific reason, recognised by
        // the transport's stderr signature, so the banner reads sensibly for a
        // deleted/unplugged folder rather than surfacing the raw error string.
        if latestError.contains("local destination folder is missing")
            || latestError.contains("local folder error")
        {
            return "destination folder unavailable"
        }
        switch classToken(of: latestError) {
        case HandoffFailureClass.auth.rawValue: return "SSH key rejected"
        case HandoffFailureClass.hostKeyMismatch.rawValue: return "host key changed"
        case HandoffFailureClass.remoteDisk.rawValue: return latestError.contains("local") ? "destination disk full" : "remote destination disk full"
        case "damaged": return "payload damaged"
        default: return String(latestError.prefix(80))
        }
    }
}
