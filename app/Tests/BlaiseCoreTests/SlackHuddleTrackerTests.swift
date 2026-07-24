import Foundation
import Synchronization
import Testing

@testable import BlaiseCore

// C15: every rule in the spec's "Tracker state machine" section, driven by
// scripted event sequences with an explicit clock (the tracker awaits its
// emitter, so batch assertions are synchronous after `handle`/`tick`).

/// Records the batches the tracker emits into the ingestion seam.
private final class BatchRecorder: MeetBatchIngesting, @unchecked Sendable {
    private let store = Mutex<[MeetWireBatch]>([])
    func ingest(batch: MeetWireBatch) async { store.withLock { $0.append(batch) } }
    var all: [MeetWireBatch] { store.withLock { $0 } }
    var lifecycleKinds: [MeetWireLifecycle.Kind] { all.compactMap { $0.lifecycle?.kind } }
}

private let selfID = "U_SELF"
private let base = Date(timeIntervalSince1970: 1_781_135_000)
private func t(_ offset: TimeInterval) -> Date { base.addingTimeInterval(offset) }

private func selfEvent(
    callID: String?, inHuddle: Bool, ts: String, expiration: Int64? = nil
) -> SlackHuddleEvent {
    event(user: selfID, callID: callID, inHuddle: inHuddle, ts: ts, expiration: expiration)
}

private func event(
    user: String, callID: String?, inHuddle: Bool, ts: String, name: String? = nil,
    expiration: Int64? = nil
) -> SlackHuddleEvent {
    SlackHuddleEvent(
        type: SlackHuddleEvent.huddleChangedType,
        user: SlackUser(
            id: user, name: nil,
            profile: SlackUserProfile(
                displayName: name, realName: nil,
                huddleState: inHuddle ? SlackHuddleEvent.inHuddleState : "default_unset",
                huddleStateExpirationTs: expiration, huddleStateCallID: callID)),
        eventTS: ts)
}

private func makeTracker(_ recorder: BatchRecorder) -> SlackHuddleTracker {
    SlackHuddleTracker(selfUserID: selfID, emitter: recorder, now: { base })
}

@Suite("C15 SlackHuddleTracker")
struct SlackHuddleTrackerTests {
    @Test("self join → callStarted + roster containing self")
    func selfJoin() async {
        let rec = BatchRecorder()
        let tracker = makeTracker(rec)
        await tracker.handle(selfEvent(callID: "R1", inHuddle: true, ts: "1000.1"), at: t(0))
        #expect(rec.all.count == 1)
        let batch = rec.all[0]
        #expect(batch.meetingCode == "slack:R1")
        #expect(batch.schemaVersion == 2)
        #expect(batch.lifecycle?.kind == .callStarted)
        #expect(batch.roster.count == 1)
        let selfRow = batch.roster[0]
        #expect(selfRow.isSelf)
        #expect(selfRow.displayName == nil)  // consumer substitutes UserIdentity.name
        #expect(selfRow.participantID == selfID)
    }

    @Test("co-participant update upserts and refreshes the roster")
    func coParticipantJoin() async {
        let rec = BatchRecorder()
        let tracker = makeTracker(rec)
        await tracker.handle(selfEvent(callID: "R1", inHuddle: true, ts: "1000.1"), at: t(0))
        // 6 s later (> 5 s coalesce window) → immediate roster flush.
        await tracker.handle(
            event(user: "U_A", callID: "R1", inHuddle: true, ts: "1001.1", name: "Alice"), at: t(6))
        #expect(rec.all.count == 2)
        let roster = rec.all[1]
        #expect(roster.lifecycle == nil)
        #expect(roster.roster.contains {
            $0.participantID == "U_A" && $0.displayName == "Alice" && !$0.isSelf
        })
        #expect(roster.roster.contains { $0.isSelf })
    }

    @Test("roster churn inside 5 s coalesces into one tick-driven flush")
    func rosterCoalescing() async {
        let rec = BatchRecorder()
        let tracker = makeTracker(rec)
        await tracker.handle(selfEvent(callID: "R1", inHuddle: true, ts: "1000.1"), at: t(0))
        // Two co-joins within the 5 s window → no immediate emit (dirty).
        await tracker.handle(
            event(user: "U_A", callID: "R1", inHuddle: true, ts: "1001.1", name: "Alice"), at: t(1))
        await tracker.handle(
            event(user: "U_B", callID: "R1", inHuddle: true, ts: "1002.1", name: "Bob"), at: t(2))
        #expect(rec.all.count == 1)  // still just callStarted
        await tracker.tick(now: t(6))  // window elapsed → one coalesced roster
        #expect(rec.all.count == 2)
        let names = Set(rec.all[1].roster.compactMap(\.displayName))
        #expect(names == ["Alice", "Bob"])
    }

    @Test("redelivered envelope (same user id + event_ts) is deduped")
    func redeliveryDedupe() async {
        let rec = BatchRecorder()
        let tracker = makeTracker(rec)
        await tracker.handle(selfEvent(callID: "R1", inHuddle: true, ts: "1000.1"), at: t(0))
        await tracker.handle(
            event(user: "U_A", callID: "R1", inHuddle: true, ts: "1001.1", name: "Alice"), at: t(6))
        #expect(rec.all.count == 2)
        // Exact redelivery — no new batch.
        await tracker.handle(
            event(user: "U_A", callID: "R1", inHuddle: true, ts: "1001.1", name: "Alice"), at: t(7))
        #expect(rec.all.count == 2)
    }

    @Test("co-participant events buffered before self's join flush into the roster")
    func foreignRingFlush() async {
        let rec = BatchRecorder()
        let tracker = makeTracker(rec)
        // Self is not in a call yet — this co event is ring-buffered, not emitted.
        await tracker.handle(
            event(user: "U_A", callID: "R1", inHuddle: true, ts: "0999.1", name: "Alice"), at: t(0))
        #expect(rec.all.isEmpty)
        await tracker.handle(selfEvent(callID: "R1", inHuddle: true, ts: "1000.1"), at: t(1))
        #expect(rec.all.count == 1)
        let batch = rec.all[0]
        #expect(batch.lifecycle?.kind == .callStarted)
        #expect(batch.roster.contains { $0.participantID == "U_A" && $0.displayName == "Alice" })
        #expect(batch.roster.contains { $0.isSelf })
    }

    @Test("stale foreign-ring events (older than 60 s) do not flush")
    func foreignRingExpiry() async {
        let rec = BatchRecorder()
        let tracker = makeTracker(rec)
        await tracker.handle(
            event(user: "U_A", callID: "R1", inHuddle: true, ts: "0999.1", name: "Alice"), at: t(0))
        // Self joins 90 s later — the buffered event has aged out.
        await tracker.handle(selfEvent(callID: "R1", inHuddle: true, ts: "1000.1"), at: t(90))
        #expect(rec.all.count == 1)
        #expect(rec.all[0].roster.allSatisfy { $0.isSelf })  // only self
    }

    @Test("expiration is advisory: a passed expiry never ends the call")
    func expirationAdvisory() async {
        let rec = BatchRecorder()
        let tracker = makeTracker(rec)
        let expiry = Int64(t(10).timeIntervalSince1970)
        await tracker.handle(
            selfEvent(callID: "R1", inHuddle: true, ts: "1000.1", expiration: expiry), at: t(0))
        await tracker.tick(now: t(50))  // < expiry + 120 (and < 60 s, no heartbeat) → still live
        #expect(rec.lifecycleKinds == [.callStarted])
        // > expiry + 120: the stale stamp must NOT end the call — Slack's
        // refresh cadence for the stamp is unverified, and a false end here
        // would auto-stop a live recording (hard floor 1). The call stays
        // alive and heartbeats keep flowing.
        await tracker.tick(now: t(131))
        #expect(rec.all.compactMap(\.lifecycle).allSatisfy { $0.kind != .callEnded })
        #expect(rec.all.last?.lifecycle?.kind == .heartbeat)
        await tracker.tick(now: t(200))  // stamp cleared → no re-fire either
        #expect(rec.all.compactMap(\.lifecycle).allSatisfy { $0.kind != .callEnded })
        // The trusted signal keeps its power: an explicit self leave ends it.
        await tracker.handle(selfEvent(callID: nil, inHuddle: false, ts: "1000.9"), at: t(210))
        #expect(rec.all.last?.lifecycle?.kind == .callEnded)
        #expect(rec.all.last?.lifecycle?.reason == "left")
    }

    @Test("heartbeat emitted on cadence while in a call")
    func heartbeat() async {
        let rec = BatchRecorder()
        let tracker = makeTracker(rec)
        await tracker.handle(selfEvent(callID: "R1", inHuddle: true, ts: "1000.1"), at: t(0))
        await tracker.tick(now: t(30))  // < 60 s → no heartbeat
        #expect(rec.all.count == 1)
        await tracker.tick(now: t(61))  // ≥ 60 s → heartbeat
        let hb = rec.all.last
        #expect(hb?.lifecycle?.kind == .heartbeat)
        #expect(hb?.roster.isEmpty == true)
        #expect(hb?.events.isEmpty == true)
    }

    @Test("a roster shipped within 60 s suppresses the standalone heartbeat")
    func rosterSuppressesHeartbeat() async {
        let rec = BatchRecorder()
        let tracker = makeTracker(rec)
        await tracker.handle(selfEvent(callID: "R1", inHuddle: true, ts: "1000.1"), at: t(0))
        // Co-join at t(6) (> 5 s) → immediate roster flush; that batch is liveness.
        await tracker.handle(
            event(user: "U_A", callID: "R1", inHuddle: true, ts: "1001.1", name: "Alice"), at: t(6))
        #expect(rec.all.count == 2)
        // t(61): 55 s since the roster batch (< 60) → NO heartbeat.
        await tracker.tick(now: t(61))
        #expect(rec.all.count == 2)
        // t(67): 61 s since the roster batch → heartbeat now.
        await tracker.tick(now: t(67))
        #expect(rec.all.last?.lifecycle?.kind == .heartbeat)
    }

    @Test("a tick that flushes a roster does not also heartbeat on the same tick")
    func noSameTickCollision() async {
        let rec = BatchRecorder()
        let tracker = makeTracker(rec)
        await tracker.handle(selfEvent(callID: "R1", inHuddle: true, ts: "1000.1"), at: t(0))
        // Co-join within the 5 s window → dirty, no immediate emit.
        await tracker.handle(
            event(user: "U_A", callID: "R1", inHuddle: true, ts: "1001.1", name: "Alice"), at: t(1))
        #expect(rec.all.count == 1)
        // A late tick would both flush the dirty roster AND be heartbeat-due;
        // it must emit ONLY the roster (one batch), so no two batches collide
        // on the same timestamp.
        await tracker.tick(now: t(61))
        #expect(rec.all.count == 2)
        #expect(rec.all[1].lifecycle == nil)  // the roster flush, not a heartbeat
        #expect(rec.all[1].roster.contains { $0.participantID == "U_A" })
    }

    @Test("self leave → callEnded(\"left\")")
    func selfLeave() async {
        let rec = BatchRecorder()
        let tracker = makeTracker(rec)
        await tracker.handle(selfEvent(callID: "R1", inHuddle: true, ts: "1000.1"), at: t(0))
        await tracker.handle(selfEvent(callID: nil, inHuddle: false, ts: "1002.1"), at: t(5))
        #expect(rec.all.last?.lifecycle?.kind == .callEnded)
        #expect(rec.all.last?.lifecycle?.reason == "left")
    }

    @Test("same call id without leaving refreshes silently (no re-emit)")
    func refreshNoReemit() async {
        let rec = BatchRecorder()
        let tracker = makeTracker(rec)
        await tracker.handle(selfEvent(callID: "R1", inHuddle: true, ts: "1000.1"), at: t(0))
        await tracker.handle(selfEvent(callID: "R1", inHuddle: true, ts: "1001.1"), at: t(1))
        #expect(rec.lifecycleKinds == [.callStarted])
    }

    @Test("leave then rejoin the same call id re-emits callStarted (after callEnded)")
    func leaveRejoinSameCall() async {
        let rec = BatchRecorder()
        let tracker = makeTracker(rec)
        await tracker.handle(selfEvent(callID: "R1", inHuddle: true, ts: "1000.1"), at: t(0))
        await tracker.handle(selfEvent(callID: nil, inHuddle: false, ts: "1002.1"), at: t(1))
        await tracker.handle(selfEvent(callID: "R1", inHuddle: true, ts: "1003.1"), at: t(2))
        #expect(rec.lifecycleKinds == [.callStarted, .callEnded, .callStarted])
    }

    @Test("a co-participant leave removes them without retracting (no emit)")
    func coParticipantLeave() async {
        let rec = BatchRecorder()
        let tracker = makeTracker(rec)
        await tracker.handle(selfEvent(callID: "R1", inHuddle: true, ts: "1000.1"), at: t(0))
        await tracker.handle(
            event(user: "U_A", callID: "R1", inHuddle: true, ts: "1001.1", name: "Alice"), at: t(6))
        #expect(rec.all.count == 2)
        // Alice leaves — no new batch (roster is cumulative downstream).
        await tracker.handle(event(user: "U_A", callID: nil, inHuddle: false, ts: "1002.1"), at: t(7))
        #expect(rec.all.count == 2)
    }

    @Test("events for a foreign call while in a call are ignored")
    func foreignCallIgnoredWhileInCall() async {
        let rec = BatchRecorder()
        let tracker = makeTracker(rec)
        await tracker.handle(selfEvent(callID: "R1", inHuddle: true, ts: "1000.1"), at: t(0))
        await tracker.handle(
            event(user: "U_X", callID: "R2", inHuddle: true, ts: "1001.1", name: "Xavier"), at: t(6))
        #expect(rec.all.count == 1)  // only the self callStarted
    }

    @Test("events are ignored entirely until a self identity is configured")
    func noSelfIdentity() async {
        let rec = BatchRecorder()
        let tracker = SlackHuddleTracker(selfUserID: "", emitter: rec, now: { base })
        await tracker.handle(
            event(user: "U_A", callID: "R1", inHuddle: true, ts: "1.1", name: "Alice"), at: t(0))
        #expect(rec.all.isEmpty)
        // Configure identity, then self joins.
        await tracker.setSelfUserID(selfID)
        await tracker.handle(selfEvent(callID: "R1", inHuddle: true, ts: "2.1"), at: t(1))
        #expect(rec.all.count == 1)
        #expect(rec.all[0].lifecycle?.kind == .callStarted)
    }
}
