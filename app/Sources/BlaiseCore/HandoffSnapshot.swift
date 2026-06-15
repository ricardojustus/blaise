import Foundation
import Observation

/// Immutable observability value the worker publishes after every state
/// change (audit M-6). Sendable by construction — the actor→UI isolation
/// boundary is crossed only by value copy.
public struct HandoffSnapshot: Sendable, Equatable {
    public enum WorkerState: String, Sendable {
        /// Queue empty (or never started).
        case idle
        case delivering
        /// Blocked on an item backoff floor; the retry timer is armed.
        case waitingRetry
        /// Every configured endpoint is benched — one breaker state.
        case allEndpointsDown
        /// A `handoff.*` setting failed validation: the WORKER is paused,
        /// items stay `pending`; a settings fix + kick resumes immediately.
        case configurationInvalid
        /// Alert: key auth failed — will not self-heal without the user.
        case authFailure
        /// Alert: remote host identification changed — possible reinstall;
        /// one-time fix documented in README.
        case hostKeyMismatch
        /// Alert: remote volume out of space.
        case remoteDiskFull
    }

    public struct ItemStatus: Sendable, Equatable {
        public var id: HandoffID
        public var attempts: Int
        public var lastError: String?

        public init(id: HandoffID, attempts: Int, lastError: String?) {
            self.id = id
            self.attempts = attempts
            self.lastError = lastError
        }
    }

    public var state: WorkerState
    /// The endpoint the current cycle selected (first host answering TCP 22).
    public var activeEndpoint: String?
    /// Undelivered items excluding reserved-prefix closures (damaged rows
    /// are reported separately; superseded rows are terminal).
    public var pendingCount: Int
    public var currentItem: ItemStatus?
    public var damagedItems: [ItemStatus]
    /// Human-readable detail for alert states (validation message, host-key
    /// stderr excerpt…).
    public var detail: String?
    /// Persistent-failure warning (owner directive refining hard floor 8):
    /// non-nil when the `HandoffWarningThreshold` trips — drives the menu-bar
    /// badge, the main-window banner, and the per-episode notification.
    /// Transient unreachability keeps this nil (silent, as the floor demands).
    public var warning: HandoffWarning?

    public static let initial = HandoffSnapshot(
        state: .idle, activeEndpoint: nil, pendingCount: 0, currentItem: nil,
        damagedItems: [], detail: nil)

    public init(
        state: WorkerState, activeEndpoint: String?, pendingCount: Int,
        currentItem: ItemStatus?, damagedItems: [ItemStatus], detail: String?,
        warning: HandoffWarning? = nil
    ) {
        self.state = state
        self.activeEndpoint = activeEndpoint
        self.pendingCount = pendingCount
        self.currentItem = currentItem
        self.damagedItems = damagedItems
        self.detail = detail
        self.warning = warning
    }
}

/// The `@MainActor @Observable` holder C10's status UI reads. The worker
/// publishes to it via `MainActor.run` — explicit actor-to-UI isolation.
///
/// Warning-episode policy lives here (not in views): the banner is hidden
/// for a DISMISSED episode key (a distinct error or a new item mints a new
/// key and re-arms it — dismissal silences the episode, never the feature),
/// and `onWarningEpisode` fires exactly once per episode key (one
/// notification per failure episode, never one per attempt). Clearing is
/// silent: `onWarningCleared` only withdraws the standing notification.
@MainActor @Observable
public final class HandoffStatusHolder {
    /// Persisted episode bookkeeping (L-2): survives relaunch so the same
    /// ongoing failure episode does not re-notify or resurrect a dismissed
    /// banner once per launch. A NEW episode after relaunch still notifies.
    public struct EpisodeState: Codable, Sendable, Equatable {
        public var dismissedEpisodeKey: String?
        public var notifiedEpisodeKey: String?
        public init(dismissedEpisodeKey: String? = nil, notifiedEpisodeKey: String? = nil) {
            self.dismissedEpisodeKey = dismissedEpisodeKey
            self.notifiedEpisodeKey = notifiedEpisodeKey
        }
        /// `app_setting` key, via the SettingsStore JSON pattern.
        public static let settingsKey = "handoff.warning.episodeState"
    }

    public private(set) var snapshot: HandoffSnapshot = .initial
    /// The episode the user dismissed from the banner (banner-only silence; the
    /// menu-bar badge keeps reflecting the active state).
    public private(set) var dismissedEpisodeKey: String?
    /// The episode already announced via Notification Center.
    public private(set) var notifiedEpisodeKey: String?
    /// Side-effect hooks, wired by the composition root.
    public var onWarningEpisode: ((HandoffWarning) -> Void)?
    public var onWarningCleared: (() -> Void)?
    /// Persist episode bookkeeping (L-2). Wired by the composition root to the
    /// SettingsStore; nil in tests that exercise the in-memory policy.
    public var persistEpisodeState: ((EpisodeState) -> Void)?

    /// Banner visibility: the active warning unless THIS episode was
    /// dismissed.
    public var bannerWarning: HandoffWarning? {
        guard let warning = snapshot.warning, warning.episodeKey != dismissedEpisodeKey else {
            return nil
        }
        return warning
    }

    public init() {}

    /// Restore persisted episode bookkeeping at launch (L-2): a still-ongoing
    /// episode that was already notified/dismissed before quit stays silent.
    public func restore(_ state: EpisodeState) {
        dismissedEpisodeKey = state.dismissedEpisodeKey
        notifiedEpisodeKey = state.notifiedEpisodeKey
    }

    /// Suppress the episode NOTIFICATION until the worker completes its first
    /// post-launch delivery sweep (L-4): a stale queue that drains right away
    /// must never fire a notification that withdraws seconds later. The
    /// banner/menu surfaces still show immediately (they read `snapshot`).
    public private(set) var firstSweepComplete = false
    public func markFirstSweepComplete() {
        guard !firstSweepComplete else { return }
        firstSweepComplete = true
        // A warning that armed during the grace window (queue did NOT drain)
        // fires now — once, with its episode recorded.
        if let warning = snapshot.warning, warning.episodeKey != notifiedEpisodeKey {
            notifiedEpisodeKey = warning.episodeKey
            persist()
            onWarningEpisode?(warning)
        }
    }

    public func publish(_ snapshot: HandoffSnapshot) {
        let hadWarning = self.snapshot.warning != nil
        self.snapshot = snapshot
        if let warning = snapshot.warning {
            if warning.episodeKey != notifiedEpisodeKey {
                // L-4 startup grace: hold the notification (and the dedupe
                // record) until the first post-launch sweep finishes, so a
                // stale queue that drains immediately never notifies. The
                // banner/menu surfaces already reflect the warning (they read
                // `snapshot`). Once the sweep completes a still-active warning
                // is re-evaluated here and fires.
                if firstSweepComplete {
                    notifiedEpisodeKey = warning.episodeKey
                    persist()
                    onWarningEpisode?(warning)
                }
            }
        } else if hadWarning {
            // Delivery succeeded (or the queue drained): clear silently and
            // forget episode bookkeeping — a FUTURE failure is a new episode.
            dismissedEpisodeKey = nil
            notifiedEpisodeKey = nil
            persist()
            onWarningCleared?()
        }
    }

    /// Banner dismissal: silences the CURRENT episode only.
    public func dismissWarning() {
        dismissedEpisodeKey = snapshot.warning?.episodeKey
        persist()
    }

    private func persist() {
        persistEpisodeState?(
            EpisodeState(
                dismissedEpisodeKey: dismissedEpisodeKey,
                notifiedEpisodeKey: notifiedEpisodeKey))
    }
}
