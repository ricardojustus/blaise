import Foundation
import Testing

@testable import BlaiseCore

// The silence auto-pause watchdog (RecordingTelemetry.swift §3): a pure,
// clock-injected dual-track silence timer that fires ONCE to auto-pause a
// recording, orthogonal to the MeetCallTracker end-detector. The clock is a
// MONOTONIC process-uptime value injected by the caller (no Date), so the math
// is deterministic AND a sleep/wake gap cannot false-fire. The math is pinned
// here with injected uptime values (no sleeps). No real personal or company data.
//
// `note`/`arm` are `mutating`, so each call is evaluated into a local BEFORE
// `#expect` (the `#expect` macro captures its expression as an immutable
// autoclosure). `up` is an arbitrary non-zero base uptime, as systemUptime is.
@Suite("SilenceWatchdog auto-pause")
struct SilenceWatchdogTests {
    // Below / above the reused silence floor — never a second constant.
    let quiet = SilenceWatchdog.silenceFloor / 2
    let loud = SilenceWatchdog.silenceFloor * 5
    // An arbitrary non-zero base uptime (process uptime is never 0 in practice).
    let up: TimeInterval = 4_200

    @Test("sustained dual silence reaches the threshold → fires")
    func firesAfterSustainedDualSilence() {
        var wd = SilenceWatchdog(enabled: true, thresholdSeconds: 600)
        wd.arm(nowUptime: up)
        // Both tracks below the floor, sampled every 5 s up to just short of it.
        for i in stride(from: 5, through: 595, by: 5) {
            let fired = wd.note(you: quiet, others: quiet, nowUptime: up + Double(i))
            #expect(!fired)
        }
        // At exactly the threshold → fires.
        let fired = wd.note(you: quiet, others: quiet, nowUptime: up + 600)
        #expect(fired)
    }

    @Test("any above-floor sample on EITHER track resets the timer")
    func anyAudioResets() {
        var wd = SilenceWatchdog(thresholdSeconds: 600)
        wd.arm(nowUptime: up)
        // 599 s of dual silence — one short of firing.
        let s599 = wd.note(you: quiet, others: quiet, nowUptime: up + 599)
        #expect(!s599)
        // A blip of MIC audio at 599 s resets the clock.
        let micBlip = wd.note(you: loud, others: quiet, nowUptime: up + 599)
        #expect(!micBlip)
        // 599 s after the reset (1198 total) is still short of a fresh window.
        let s1198 = wd.note(you: quiet, others: quiet, nowUptime: up + 1198)
        #expect(!s1198)
        // A blip of SYSTEM audio resets again.
        let sysBlip = wd.note(you: quiet, others: loud, nowUptime: up + 1198)
        #expect(!sysBlip)
        // Only a full fresh 600 s of dual silence fires.
        let s1797 = wd.note(you: quiet, others: quiet, nowUptime: up + 1797)
        #expect(!s1797)
        let s1798 = wd.note(you: quiet, others: quiet, nowUptime: up + 1798)
        #expect(s1798)
    }

    @Test("only-mic-silent never fires; only-system-silent never fires; BOTH fires")
    func bothTracksMustBeSilent() {
        // System has audio (mic silent) → never fires, even way past threshold.
        var sysAudio = SilenceWatchdog(thresholdSeconds: 100)
        sysAudio.arm(nowUptime: up)
        for i in 1...20 {
            let fired = sysAudio.note(you: quiet, others: loud, nowUptime: up + Double(i) * 50)
            #expect(!fired)
        }

        // Mic has audio (system silent) → never fires.
        var micAudio = SilenceWatchdog(thresholdSeconds: 100)
        micAudio.arm(nowUptime: up)
        for i in 1...20 {
            let fired = micAudio.note(you: loud, others: quiet, nowUptime: up + Double(i) * 50)
            #expect(!fired)
        }

        // BOTH silent → fires past the threshold.
        var both = SilenceWatchdog(thresholdSeconds: 100)
        both.arm(nowUptime: up)
        let before = both.note(you: quiet, others: quiet, nowUptime: up + 99)
        #expect(!before)
        let at = both.note(you: quiet, others: quiet, nowUptime: up + 100)
        #expect(at)
    }

    @Test("disabled never fires through the whole threshold")
    func disabledNeverFires() {
        var wd = SilenceWatchdog(enabled: false, thresholdSeconds: 600)
        wd.arm(nowUptime: up)
        let atThreshold = wd.note(you: quiet, others: quiet, nowUptime: up + 600)
        #expect(!atThreshold)
        let wayPast = wd.note(you: quiet, others: quiet, nowUptime: up + 6000)
        #expect(!wayPast)
    }

    @Test("an unarmed watchdog never fires")
    func unarmedNeverFires() {
        var wd = SilenceWatchdog(thresholdSeconds: 600)
        // Never armed.
        let atThreshold = wd.note(you: quiet, others: quiet, nowUptime: up + 600)
        #expect(!atThreshold)
        let wayPast = wd.note(you: quiet, others: quiet, nowUptime: up + 6000)
        #expect(!wayPast)
    }

    @Test("the watchdog reuses the level meter's silence floor (one floor)")
    func reusesSilenceFloor() {
        #expect(SilenceWatchdog.silenceFloor == LevelMeterChannel.silenceFloor)
    }

    // MARK: - Once-per-session (external disarm) + re-arm

    @Test("note keeps returning true until the caller disarms (the once-guard is external)")
    func noteFiresRepeatedlyUntilExternalDisarm() {
        var wd = SilenceWatchdog(thresholdSeconds: 600)
        wd.arm(nowUptime: up)
        // Past the threshold the struct itself signals true on EVERY subsequent
        // silent sample — the at-most-once-per-session guard is the caller's
        // `disarm()`, not internal state.
        let fire1 = wd.note(you: quiet, others: quiet, nowUptime: up + 600)
        #expect(fire1)
        let fire2 = wd.note(you: quiet, others: quiet, nowUptime: up + 601)
        #expect(fire2)
        let fire3 = wd.note(you: quiet, others: quiet, nowUptime: up + 900)
        #expect(fire3)
    }

    @Test("disarm (the .stopping / .paused wiring) stops firing immediately")
    func disarmStopsFiring() {
        var wd = SilenceWatchdog(thresholdSeconds: 600)
        wd.arm(nowUptime: up)
        // A stop/pause disarms mid-session (AppEnvironment's `.stopping` /
        // `.paused` cases): no fire thereafter, regardless of elapsed silence.
        wd.disarm()
        let afterDisarm1 = wd.note(you: quiet, others: quiet, nowUptime: up + 600)
        #expect(!afterDisarm1)
        let afterDisarm2 = wd.note(you: quiet, others: quiet, nowUptime: up + 6000)
        #expect(!afterDisarm2)
    }

    @Test("fires once, the caller disarms, and resume's re-arm starts a fresh window")
    func firesOnceThenReArmsOnResume() {
        var wd = SilenceWatchdog(thresholdSeconds: 600)
        wd.arm(nowUptime: up)
        let firstFire = wd.note(you: quiet, others: quiet, nowUptime: up + 600)
        #expect(firstFire)
        // The caller disarms after firing — it must not fire again this session.
        wd.disarm()
        let afterDisarm = wd.note(you: quiet, others: quiet, nowUptime: up + 1300)
        #expect(!afterDisarm)
        // Resume re-emits `.started`, which re-arms with a fresh uptime → a new
        // full window can fire again.
        let resume = up + 10_000
        wd.arm(nowUptime: resume)
        let reShort = wd.note(you: quiet, others: quiet, nowUptime: resume + 599)
        #expect(!reShort)
        let reFire = wd.note(you: quiet, others: quiet, nowUptime: resume + 600)
        #expect(reFire)
    }

    // MARK: - Monotonic clock (sleep/wake & NTP step)

    @Test("a sleep/wake gap (monotonic uptime barely advances) does NOT count as silence")
    func sleepWakeGapDoesNotFalseFire() {
        var wd = SilenceWatchdog(thresholdSeconds: 600)
        wd.arm(nowUptime: up)
        // The machine sleeps ~1 h of WALL-CLOCK time with no observed samples.
        // `systemUptime` does not advance while suspended, so the first sample
        // after wake carries only a few extra seconds of monotonic uptime —
        // nowhere near the 600 s threshold. A wall-clock (`Date`) timer would
        // have false-fired here; the monotonic clock does not.
        let afterWake = wd.note(you: quiet, others: quiet, nowUptime: up + 3)
        #expect(!afterWake)
        // Firing still requires a full CONTINUOUS threshold of running-time
        // (uptime) silence — measured from the arm, since every sample so far is
        // below the floor and never reset the clock.
        let justShort = wd.note(you: quiet, others: quiet, nowUptime: up + 599)
        #expect(!justShort)
        let atThreshold = wd.note(you: quiet, others: quiet, nowUptime: up + 600)
        #expect(atThreshold)
    }
}
