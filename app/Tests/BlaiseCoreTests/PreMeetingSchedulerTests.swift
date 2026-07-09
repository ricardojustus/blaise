import Foundation
import Synchronization
import Testing

@testable import BlaiseCore

// C14 AC1: PreMeetingScheduler fire times / dedupe / restart-refire (incl.
// the already-ended-meeting skip) / expiry withdrawal over fixture
// snapshots with a fake clock.

private final class SchedulerNotifier: AutomationNotifying, @unchecked Sendable {
    struct State {
        var posts: [(eventKey: String, title: String, code: String, url: String?)] = []
        var withdrawals: [String] = []
    }

    let state = Mutex(State())

    func postMeetStart(code: String, title: String?) async {}
    func withdrawMeetStart(code: String) async {}
    func postWatchdogStop(meetingID: MeetingID, title: String, canResume: Bool) async {}
    func withdrawWatchdogStop(meetingID: MeetingID) async {}
    func postNudge(meetingID: MeetingID, title: String) async {}
    func postCalendarUpcoming(
        eventKey: String, title: String, start: Date, code: String, urlString: String?
    ) async {
        state.withLock { $0.posts.append((eventKey, title, code, urlString)) }
    }
    func withdrawCalendarUpcoming(eventKey: String) async {
        state.withLock { $0.withdrawals.append(eventKey) }
    }

    var posts: [(eventKey: String, title: String, code: String, url: String?)] {
        state.withLock { $0.posts }
    }
    var withdrawals: [String] { state.withLock { $0.withdrawals } }
}

private final class SchedulerHarness: @unchecked Sendable {
    static let epoch = Date(timeIntervalSince1970: 1_781_136_000)

    let notifier = SchedulerNotifier()
    let clock = Mutex(SchedulerHarness.epoch)
    let codeState = Mutex(PreMeetingScheduler.CodeRecordingState.idle)
    let doneCodes = Mutex(Set<String>())
    private(set) var scheduler: PreMeetingScheduler!

    init() {
        scheduler = PreMeetingScheduler(
            notifier: notifier,
            recordingState: { [codeState = self.codeStateRef] _ in codeState.value },
            alreadyDone: { [doneCodes = self.doneCodesRef] code, _, _ in
                doneCodes.value.contains(code)
            },
            now: { [clock = self.clockRef] in clock.value })
    }

    func advance(_ seconds: TimeInterval) {
        clock.withLock { $0 = $0.addingTimeInterval(seconds) }
    }

    // Sendable accessors over the non-copyable mutexes for closure capture.
    private var clockRef: Accessor<Date> { Accessor { self.clock.withLock { $0 } } }
    private var codeStateRef: Accessor<PreMeetingScheduler.CodeRecordingState> {
        Accessor { self.codeState.withLock { $0 } }
    }
    private var doneCodesRef: Accessor<Set<String>> { Accessor { self.doneCodes.withLock { $0 } } }

    struct Accessor<T>: @unchecked Sendable {
        let read: () -> T
        init(_ read: @escaping () -> T) { self.read = read }
        var value: T { read() }
    }
}

private func makeSchedulerHarness() -> SchedulerHarness {
    SchedulerHarness()
}

private func meetEvent(
    id: String = "ek-1", title: String = "Weekly Vexatron sync",
    start: Date, durationMinutes: Double = 30,
    location: String? = "https://meet.google.com/abc-defg-hij"
) -> CalendarEventSnapshot {
    CalendarEventSnapshot(
        eventIdentifier: id, title: title, start: start,
        end: start.addingTimeInterval(durationMinutes * 60),
        location: location)
}

@Suite("C14 calendar pre-meeting scheduler")
struct PreMeetingSchedulerTests {
    @Test("fires ONE notification at start − 60 s; never before; never twice")
    func firesOnceAtLead() async {
        let h = makeSchedulerHarness()
        let start = SchedulerHarness.epoch.addingTimeInterval(600)
        await h.scheduler.update(snapshots: [meetEvent(start: start)])
        #expect(h.notifier.posts.isEmpty, "10 min early: nothing")
        h.advance(500)  // T−100 s
        await h.scheduler.evaluate()
        #expect(h.notifier.posts.isEmpty)
        h.advance(41)  // T−59 s
        await h.scheduler.evaluate()
        #expect(h.notifier.posts.count == 1)
        #expect(h.notifier.posts.first?.code == "abc-defg-hij")
        #expect(h.notifier.posts.first?.url == "https://meet.google.com/abc-defg-hij")
        h.advance(30)
        await h.scheduler.evaluate()
        await h.scheduler.update(snapshots: [meetEvent(start: start)])  // refresh re-delivers the snapshot
        #expect(h.notifier.posts.count == 1, "fired-set dedupe (eventIdentifier + start)")
    }

    @Test("a posted event removed from the snapshot set (hidden calendar) is withdrawn")
    func vanishedEventWithdrawn() async {
        let h = makeSchedulerHarness()
        let start = SchedulerHarness.epoch.addingTimeInterval(600)
        await h.scheduler.update(snapshots: [meetEvent(start: start)])
        h.advance(541)  // T−59 s → posts
        await h.scheduler.evaluate()
        #expect(h.notifier.posts.count == 1)
        #expect(h.notifier.withdrawals.isEmpty)
        // The event's calendar is hidden → it vanishes from the next snapshot
        // set; its already-posted Launch & Record notification must be withdrawn.
        await h.scheduler.update(snapshots: [])
        let key = PreMeetingScheduler.eventKey(meetEvent(start: start))
        #expect(h.notifier.withdrawals.contains(key))
    }

    @Test("events without a Meet code never fire (Zoom/Teams out of scope)")
    func nonMeetSkipped() async {
        let h = makeSchedulerHarness()
        let start = SchedulerHarness.epoch.addingTimeInterval(30)
        await h.scheduler.update(snapshots: [
            meetEvent(id: "zoom", start: start, location: "https://acme.zoom.us/j/123")
        ])
        #expect(h.notifier.posts.isEmpty)
    }

    @Test("unconditional withdrawal at start + 15 min")
    func expiryWithdrawal() async {
        let h = makeSchedulerHarness()
        let start = SchedulerHarness.epoch.addingTimeInterval(120)
        await h.scheduler.update(snapshots: [meetEvent(start: start)])
        h.advance(70)  // inside [T−60, …]
        await h.scheduler.evaluate()
        #expect(h.notifier.posts.count == 1)
        h.advance(15 * 60 + 60)  // past start + 15 min
        await h.scheduler.evaluate()
        #expect(h.notifier.withdrawals == [h.notifier.posts.first!.eventKey])
        // And only once.
        h.advance(60)
        await h.scheduler.evaluate()
        #expect(h.notifier.withdrawals.count == 1)
    }

    @Test("restart re-fire: an event still inside its validity re-fires (the fired-set died)")
    func restartRefires() async {
        let h = makeSchedulerHarness()
        let start = SchedulerHarness.epoch.addingTimeInterval(60)
        await h.scheduler.update(snapshots: [meetEvent(start: start)])
        h.advance(120)  // T+60 s — mid-meeting
        await h.scheduler.evaluate()
        #expect(h.notifier.posts.count == 1)

        // "Restart": a FRESH scheduler (in-memory fired-set gone) sees the
        // same snapshot still inside [start − 60 s, start + 15 min].
        let h2 = makeSchedulerHarness()
        h2.clock.withLock { $0 = h.clock.withLock { $0 } }
        await h2.scheduler.update(snapshots: [meetEvent(start: start)])
        #expect(h2.notifier.posts.count == 1, "restart must not eat the reminder")
    }

    @Test("restart guard: code already recording or in grace is skipped")
    func recordingOrGraceSkips() async {
        for state in [PreMeetingScheduler.CodeRecordingState.recording, .grace] {
            let h = makeSchedulerHarness()
            h.codeState.withLock { $0 = state }
            let start = SchedulerHarness.epoch.addingTimeInterval(30)
            await h.scheduler.update(snapshots: [meetEvent(start: start)])
            #expect(h.notifier.posts.isEmpty, "\(state) must skip")
        }
    }

    @Test("restart guard: an already-recorded-and-ended meeting is skipped (dead-meeting re-fire)")
    func alreadyDoneSkips() async {
        let h = makeSchedulerHarness()
        h.doneCodes.withLock { _ = $0.insert("abc-defg-hij") }
        let start = SchedulerHarness.epoch.addingTimeInterval(-300)  // started 5 min ago
        await h.scheduler.update(snapshots: [meetEvent(start: start)])
        #expect(h.notifier.posts.isEmpty, "re-firing Launch & Record would invite recording a dead meeting")
    }

    @Test("withdrawForCode (recording started / call-ended) withdraws the posted notification")
    func withdrawForCode() async {
        let h = makeSchedulerHarness()
        let start = SchedulerHarness.epoch.addingTimeInterval(30)
        await h.scheduler.update(snapshots: [meetEvent(start: start)])
        #expect(h.notifier.posts.count == 1)
        await h.scheduler.withdrawForCode("abc-defg-hij")
        #expect(h.notifier.withdrawals == [h.notifier.posts.first!.eventKey])
        await h.scheduler.withdrawForCode("abc-defg-hij")
        #expect(h.notifier.withdrawals.count == 1, "idempotent")
    }

    @Test("a bare code in the event reconstructs the canonical Meet URL")
    func bareCodeURL() async {
        let h = makeSchedulerHarness()
        let start = SchedulerHarness.epoch.addingTimeInterval(30)
        await h.scheduler.update(snapshots: [
            meetEvent(start: start, location: "abc-defg-hij")
        ])
        #expect(h.notifier.posts.first?.url == "https://meet.google.com/abc-defg-hij")
    }
}
