import Foundation
import os

// C15: the huddle state machine. Consumes `user_huddle_changed` events (fed
// by the Socket Mode client) plus a periodic tick, and emits `MeetWireBatch`es
// — roster batches and lifecycle signals — into the SAME ingestion core the
// Meet extension feeds (`MeetBatchIngesting`). Pure and clock-injected: no
// URLSession, no Keychain, no UI. Every rule in the C15 spec's "Tracker state
// machine" section is a unit test.
//
// Downstream, one seam does everything: `MeetEventsIngestor.ingest(batch:)`
// persists roster/lifecycle AND forwards the per-batch liveness/lifecycle
// signal to `MeetCallTracker` (auto-record notification, auto-stop, watchdog).
// Slack is thus just another producer of `MeetWireBatch`es; it never touches
// audio and never reads a message.
public actor SlackHuddleTracker {
    /// Roster-churn coalescing: at most one roster batch per this window.
    public static let rosterCoalesceSeconds: TimeInterval = 5
    /// Heartbeat cadence while in a call (feeds MeetCallTracker's 5-min
    /// watchdog, same role as the extension's 1 s poll heartbeat).
    public static let heartbeatIntervalSeconds: TimeInterval = 60
    /// Expiration backstop: `huddle_state` can linger after a huddle ends, so
    /// this many seconds past `huddle_state_expiration_ts` with no refreshing
    /// self event is treated as self-left.
    public static let expirationBackstopSeconds: TimeInterval = 120
    /// Foreign-call events (a co-participant's event that arrives before self's
    /// own join) are retained this long — ordering across the workspace stream
    /// is not guaranteed.
    public static let foreignRingSeconds: TimeInterval = 60
    /// A single evaluation tick drives roster-flush coalescing (5 s),
    /// heartbeat (60 s, timestamp-gated), and the expiration backstop.
    public static let tickIntervalSeconds: TimeInterval = 5
    /// Dedupe-key ring bound (redelivered-envelope guard). A session never
    /// approaches this; the FIFO cap only keeps memory flat over a long uptime.
    static let seenKeyCap = 4096

    // Injected.
    /// The user's own Slack member id. Mutable: it loads asynchronously from
    /// settings and can be edited, so the composition root pushes it in after
    /// construction (`setSelfUserID`). Empty = self can never be identified, so
    /// no huddle is ever tracked (a safe no-op until configured).
    private var selfUserID: String
    private let emitter: any MeetBatchIngesting
    private let now: @Sendable () -> Date
    private let logger = Logger(subsystem: BlaiseBundle.identifier, category: "slack.huddle")

    // MARK: State

    private var currentCallID: String?
    /// userID → (name, joinedAt). Cumulative for the life of the call; a leave
    /// removes the entry (stops heartbeating presence) but the attendee is
    /// already durably queued, so the roster is never retracted downstream.
    private var participants: [String: Participant] = [:]
    private var expirationTs: Int64?
    private var lastSelfEventAt: Date?

    private var lastRosterFlushAt: Date?
    private var rosterDirty = false
    private var lastHeartbeatAt: Date?

    /// Redelivery dedupe (`user.id + ":" + event_ts`), FIFO-bounded.
    private var seenEventKeys: Set<String> = []
    private var seenEventOrder: [String] = []

    /// Events for a foreign call id seen while self is NOT in a call — retained
    /// briefly because a co-participant's event can precede self's own join.
    private var foreignRing: [RingEntry] = []

    private var tickTask: Task<Void, Never>?

    struct Participant {
        var name: String?
        var joinedAt: Date
    }

    struct RingEntry {
        var event: SlackHuddleEvent
        var at: Date
    }

    public init(
        selfUserID: String,
        emitter: any MeetBatchIngesting,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.selfUserID = selfUserID
        self.emitter = emitter
        self.now = now
    }

    /// Update the tracked self identity (member-ID load / edit). A change to a
    /// different id abandons the current call's in-memory state without
    /// emitting — a new identity cannot own the old call, and editing the id
    /// mid-huddle is pathological; the durable roster already queued survives.
    public func setSelfUserID(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != selfUserID else { return }
        selfUserID = trimmed
        currentCallID = nil
        participants = [:]
        expirationTs = nil
        lastSelfEventAt = nil
        lastRosterFlushAt = nil
        lastHeartbeatAt = nil
        rosterDirty = false
        foreignRing.removeAll()
        seenEventKeys.removeAll()
        seenEventOrder.removeAll()
    }

    /// Production 5 s evaluation timer (roster coalescing + heartbeat +
    /// expiration backstop). Tests never call it — they drive `tick(now:)`
    /// with an injected clock, exactly like `MeetCallTracker`.
    public func startTicking() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.tickIntervalSeconds))
                guard let self else { return }  // stop the loop once the actor is gone
                await self.tick()
            }
        }
    }

    public func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }

    // MARK: - Input: one user_huddle_changed event

    /// Applies one `user_huddle_changed` event at receipt time `at`.
    public func handle(_ event: SlackHuddleEvent, at at: Date) async {
        guard event.type == SlackHuddleEvent.huddleChangedType else { return }
        // Redelivery dedupe: Slack redelivers unacked envelopes, and the ring
        // buffer can replay a foreign event that was already seen.
        guard markSeen(event.user.id + ":" + event.eventTS) else { return }

        if event.user.id == selfUserID {
            await handleSelfEvent(event, at: at)
        } else {
            await handleOtherEvent(event, at: at)
        }
    }

    // MARK: - Input: periodic evaluation

    /// One evaluation pass (production: every 5 s). Flushes a coalesced roster,
    /// applies the expiration backstop, and emits a heartbeat when due. Also
    /// prunes the foreign-event ring while idle.
    public func tick(now injected: Date? = nil) async {
        let clock = injected ?? now()
        pruneForeignRing(before: clock)
        guard let callID = currentCallID else { return }

        // Coalesced roster flush (a co-participant change inside the 5 s window
        // marked the roster dirty rather than emitting).
        if rosterDirty, let last = lastRosterFlushAt,
            clock.timeIntervalSince(last) >= Self.rosterCoalesceSeconds
        {
            await flushRoster(at: clock)
        }

        // Expiration ADVISORY: `now > huddle_state_expiration_ts + 120 s` with
        // no refreshing self event. Slack's refresh cadence for
        // `huddle_state_expiration_ts` during a long huddle is UNVERIFIED (the
        // spec's live-workspace touchpoint is open), so a passed expiry must
        // never end the call — a stale stamp on a live huddle would auto-stop a
        // real recording mid-meeting (hard floor 1). Log once and clear the
        // stamp; automatic stops belong to the audio-keyed silence watchdog and
        // an explicit self leave event, both grounded in signals we trust.
        if let exp = expirationTs,
            clock.timeIntervalSince1970 > Double(exp) + Self.expirationBackstopSeconds
        {
            logger.notice(
                "huddle expiry passed for \(callID, privacy: .public) with no refresh — advisory only, call kept alive")
            expirationTs = nil
        }

        // Heartbeat.
        if let last = lastHeartbeatAt,
            clock.timeIntervalSince(last) >= Self.heartbeatIntervalSeconds
        {
            await emitHeartbeat(at: clock)
        }
    }

    // MARK: - Self transitions

    private func handleSelfEvent(_ event: SlackHuddleEvent, at at: Date) async {
        if event.isInHuddle, let callID = event.callID {
            if currentCallID == callID {
                // Refresh: same call, no lifecycle re-emit. Take the latest
                // event's expiration verbatim (a refresh that omits it clears
                // the backstop — a live huddle is kept alive by heartbeats/the
                // watchdog, not force-ended on a stale expiry).
                expirationTs = event.expirationTs
                lastSelfEventAt = at
                return
            }
            // Self joins a NEW call id (nil or different). A different id means
            // self switched huddles without a clearing event — end the old one
            // first so its recording settles.
            if currentCallID != nil {
                await endCurrentCall(reason: "left", at: at)
            }
            await startCall(callID: callID, expirationTs: event.expirationTs, at: at)
        } else {
            // State cleared / not in a huddle → self left.
            if currentCallID != nil {
                await endCurrentCall(reason: "left", at: at)
            }
        }
    }

    private func startCall(callID: String, expirationTs: Int64?, at: Date) async {
        currentCallID = callID
        self.expirationTs = expirationTs
        lastSelfEventAt = at
        participants = [selfUserID: Participant(name: nil, joinedAt: at)]
        lastRosterFlushAt = at
        rosterDirty = false
        // `lastHeartbeatAt` is set by the callStarted `emitBatch` below.
        // Absorb any FRESH co-participant events buffered for this call id
        // before self's own join landed (workspace stream ordering is not
        // guaranteed). Entries older than the ring window are stale presence
        // and never seed the roster.
        var flushed = false
        for entry in foreignRing
        where entry.event.callID == callID && entry.event.isInHuddle
            && at.timeIntervalSince(entry.at) <= Self.foreignRingSeconds {
            participants[entry.event.user.id] = Participant(
                name: entry.event.preferredDisplayName, joinedAt: entry.at)
            flushed = true
        }
        foreignRing.removeAll()
        // callStarted + the initial roster (self, plus any flushed co-joiners)
        // ride ONE batch — the ingestor's signal forward turns callStarted into
        // the auto-record offer.
        await emitBatch(
            callID: callID, roster: currentRoster(),
            lifecycle: MeetWireLifecycle(kind: .callStarted, atMs: ms(at)), at: at)
        if flushed { logger.notice("flushed buffered co-participant events into new huddle roster") }
    }

    private func endCurrentCall(reason: String, at: Date) async {
        guard let callID = currentCallID else { return }
        await emitBatch(
            callID: callID, roster: [],
            lifecycle: MeetWireLifecycle(kind: .callEnded, atMs: ms(at), reason: reason), at: at)
        currentCallID = nil
        participants = [:]
        expirationTs = nil
        lastSelfEventAt = nil
        lastRosterFlushAt = nil
        lastHeartbeatAt = nil
        rosterDirty = false
    }

    // MARK: - Co-participant transitions

    private func handleOtherEvent(_ event: SlackHuddleEvent, at at: Date) async {
        guard let currentCallID else {
            // Self is not in a call: buffer in-huddle foreign events briefly —
            // they may precede self's own join. Everything else is ignored
            // (Blaise only ever observes huddles the user is in).
            if event.isInHuddle, event.callID != nil {
                foreignRing.append(RingEntry(event: event, at: at))
                pruneForeignRing(before: at)
            }
            return
        }
        if event.isInHuddle, event.callID == currentCallID {
            // Co-participant joined/updated in our call.
            let existing = participants[event.user.id]
            participants[event.user.id] = Participant(
                name: event.preferredDisplayName ?? existing?.name,
                joinedAt: existing?.joinedAt ?? at)
            await noteRosterChanged(at: at)
        } else if participants[event.user.id] != nil {
            // Co-participant left (state cleared or moved to another call).
            // Removal stops heartbeating their presence; it does NOT retract
            // the attendee (the roster is cumulative downstream).
            participants[event.user.id] = nil
        }
        // A foreign-call event while we ARE in a call is ignored.
    }

    // MARK: - Roster emission (coalesced)

    private func noteRosterChanged(at: Date) async {
        let elapsed = lastRosterFlushAt.map { at.timeIntervalSince($0) } ?? .infinity
        if elapsed >= Self.rosterCoalesceSeconds {
            await flushRoster(at: at)
        } else {
            rosterDirty = true  // the tick flushes it once the window elapses
        }
    }

    private func flushRoster(at: Date) async {
        guard let callID = currentCallID else {
            rosterDirty = false
            return
        }
        lastRosterFlushAt = at
        rosterDirty = false
        await emitBatch(callID: callID, roster: currentRoster(), lifecycle: nil, at: at)
    }

    private func emitHeartbeat(at: Date) async {
        guard let callID = currentCallID else { return }
        await emitBatch(
            callID: callID, roster: [],
            lifecycle: MeetWireLifecycle(kind: .heartbeat, atMs: ms(at)), at: at)
    }

    /// The current roster as wire participants, join-order stable. Self carries
    /// a nil display name (the consumer substitutes `UserIdentity.name`, same
    /// rule as Meet) and its member id as the participant id.
    private func currentRoster() -> [MeetWireParticipant] {
        participants
            .sorted { lhs, rhs in
                if lhs.value.joinedAt != rhs.value.joinedAt {
                    return lhs.value.joinedAt < rhs.value.joinedAt
                }
                return lhs.key < rhs.key
            }
            .map { userID, participant in
                let isSelf = userID == selfUserID
                return MeetWireParticipant(
                    displayName: isSelf ? nil : participant.name,
                    participantID: userID, isSelf: isSelf)
            }
    }

    private func emitBatch(
        callID: String, roster: [MeetWireParticipant], lifecycle: MeetWireLifecycle?, at: Date
    ) async {
        // EVERY emitted batch is liveness (matches the Meet extension's rule
        // "skip the heartbeat when any batch shipped within 60 s"): advancing
        // `lastHeartbeatAt` here means a tick that already flushed a roster
        // never ALSO emits a standalone heartbeat with the same `at` — which
        // MeetCallTracker's strict-`<=` monotonic guard would reject outright,
        // delaying the kind-gated grace-resume path by up to 60 s.
        lastHeartbeatAt = at
        let batch = MeetWireBatch(
            meetingCode: SlackHuddle.meetingCode(callID: callID),
            capturedAtMs: ms(at), droppedCount: 0, poisonedCount: 0,
            roster: roster, events: [], schemaVersion: 2, lifecycle: lifecycle)
        await emitter.ingest(batch: batch)
    }

    // MARK: - Helpers

    private func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

    private func markSeen(_ key: String) -> Bool {
        guard seenEventKeys.insert(key).inserted else { return false }
        seenEventOrder.append(key)
        if seenEventOrder.count > Self.seenKeyCap {
            let dropped = seenEventOrder.removeFirst()
            seenEventKeys.remove(dropped)
        }
        return true
    }

    private func pruneForeignRing(before reference: Date) {
        guard !foreignRing.isEmpty else { return }
        foreignRing.removeAll { reference.timeIntervalSince($0.at) > Self.foreignRingSeconds }
    }
}
