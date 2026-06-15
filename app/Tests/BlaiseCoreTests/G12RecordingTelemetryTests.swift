import Foundation
import Testing

@testable import BlaiseCore

// G12 §1/§2 AC4 — the pure, headless models behind the menu-bar live timer and
// the two-channel level meter: timer formatting + state mapping, RMS smoothing,
// the ≤ 10 Hz publish cap, and the silence-detection thresholds. The SwiftUI
// renders are deferred to the deploy ask; the math is pinned here.

@Suite("G12 recording telemetry models")
struct G12RecordingTelemetryTests {

    // MARK: - Menu-bar timer (§1)

    @Test("timer formats MM:SS, rolls to H:MM:SS past an hour, clamps negatives")
    func timerFormatting() {
        #expect(RecordingTimerModel.format(seconds: 0) == "00:00")
        #expect(RecordingTimerModel.format(seconds: 5) == "00:05")
        #expect(RecordingTimerModel.format(seconds: 65) == "01:05")
        #expect(RecordingTimerModel.format(seconds: 59 * 60 + 59) == "59:59")
        #expect(RecordingTimerModel.format(seconds: 3600) == "1:00:00")
        #expect(RecordingTimerModel.format(seconds: 3661) == "1:01:01")
        // A clock skew (start ahead of now) clamps to zero, never negative.
        #expect(RecordingTimerModel.format(seconds: -42) == "00:00")
    }

    @Test("state → display mapping: recording shows live elapsed, paused shows accumulated, else glyph")
    func displayMapping() {
        let start = Date(timeIntervalSince1970: 1_000)
        let now = start.addingTimeInterval(125)

        #expect(
            RecordingTimerModel.display(for: .recording(startedAt: start), now: now)
                == .recording(formatted: "02:05"))
        // A warning (long-session) still shows the live timer (still recording).
        #expect(
            RecordingTimerModel.display(for: .warning(startedAt: start, message: "x"), now: now)
                == .recording(formatted: "02:05"))
        // Paused rides the accumulated seconds on the state — no clock read.
        #expect(
            RecordingTimerModel.display(
                for: .paused(meetingTitle: "Vexatron sync", accumulatedSeconds: 90), now: now)
                == .paused(formatted: "01:30"))
        #expect(RecordingTimerModel.display(for: .idle, now: now) == .glyph)
        #expect(RecordingTimerModel.display(for: .processing, now: now) == .glyph)
        #expect(RecordingTimerModel.display(for: .alarm(message: "x"), now: now) == .glyph)
        #expect(
            RecordingTimerModel.display(for: .grace(meetingTitle: "x", until: now), now: now) == .glyph)
    }

    @Test("recording/paused are NOT quiet states; idle/processing/grace/alarm are")
    func quietStates() {
        #expect(!RecordingTimerModel.isQuietState(.recording(startedAt: Date())))
        #expect(!RecordingTimerModel.isQuietState(.warning(startedAt: Date(), message: "x")))
        #expect(!RecordingTimerModel.isQuietState(.paused(meetingTitle: "x", accumulatedSeconds: 0)))
        #expect(RecordingTimerModel.isQuietState(.idle))
        #expect(RecordingTimerModel.isQuietState(.processing))
        #expect(RecordingTimerModel.isQuietState(.grace(meetingTitle: "x", until: Date())))
        #expect(RecordingTimerModel.isQuietState(.alarm(message: "x")))
    }

    // MARK: - RMS (§2)

    @Test("RMS: Int16 and Float32 normalize to [0,1]; full-scale is ~1; empty is 0")
    func rmsMath() {
        // Empty / unknown format → 0.
        #expect(AudioRMS.rms(of: Data(), bytesPerSample: 2) == 0)
        #expect(AudioRMS.rms(of: Data([1, 2, 3, 4]), bytesPerSample: 3) == 0)

        // Int16 full-scale square wave → RMS ≈ 1.
        var int16 = Data()
        for _ in 0..<100 {
            withUnsafeBytes(of: Int16(32767).littleEndian) { int16.append(contentsOf: $0) }
        }
        #expect(abs(AudioRMS.rms(of: int16, bytesPerSample: 2) - 1.0) < 0.01)
        // Int16 silence → 0.
        let int16Silence = Data(repeating: 0, count: 200)
        #expect(AudioRMS.rms(of: int16Silence, bytesPerSample: 2) == 0)

        // Float32 half-scale constant → RMS = 0.5.
        var f32 = Data()
        for _ in 0..<100 {
            withUnsafeBytes(of: Float32(0.5).bitPattern.littleEndian) { f32.append(contentsOf: $0) }
        }
        #expect(abs(AudioRMS.rms(of: f32, bytesPerSample: 4) - 0.5) < 0.001)
    }

    // MARK: - Smoothing + silence (§2)

    @Test("channel: EMA smoothing settles toward the input; silence is below floor for ≥ 10 s")
    func channelSmoothingAndSilence() throws {
        let start = Date(timeIntervalSince1970: 0)
        var channel = LevelMeterChannel()
        // Feed a steady 0.8 — the EMA climbs toward it but does not overshoot.
        for i in 0..<20 {
            channel.ingest(rms: 0.8, at: start.addingTimeInterval(Double(i) * 0.1))
        }
        #expect(channel.smoothed > 0.7 && channel.smoothed <= 0.8)
        // While above the floor it is never "silent".
        #expect(!channel.isSilent(now: start.addingTimeInterval(2), since: start))

        // Now go quiet; the EMA decays below the floor after enough quiet
        // samples, and silence only fires 10 s after the last above-floor one.
        let quietStart = start.addingTimeInterval(2)
        for i in 0..<30 {
            channel.ingest(rms: 0.0, at: quietStart.addingTimeInterval(Double(i) * 0.1))
        }
        #expect(channel.smoothed < LevelMeterChannel.silenceFloor)
        // The silence clock is anchored at the LAST above-floor sample (the EMA
        // stays above the floor for a few quiet samples, so the anchor is a bit
        // after the quiet start), not at the recording start — silence fires
        // 10 s after that anchor.
        let anchor = try #require(channel.lastAboveFloorAt)
        #expect(!channel.isSilent(now: anchor.addingTimeInterval(9), since: start))
        #expect(channel.isSilent(now: anchor.addingTimeInterval(11), since: start))
    }

    @Test("a channel silent from the START is silent only after 10 s from recording start")
    func silenceFromStart() {
        let start = Date(timeIntervalSince1970: 0)
        let channel = LevelMeterChannel()  // never fed above the floor
        #expect(!channel.isSilent(now: start.addingTimeInterval(9), since: start))
        #expect(channel.isSilent(now: start.addingTimeInterval(10), since: start))
    }

    @Test("meter: the publish gate caps at ≤ 10 Hz; the first frame always publishes")
    func publishRateCap() {
        let start = Date(timeIntervalSince1970: 0)
        var meter = LevelMeter(recordingStart: start)
        // First frame: always publishes.
        #expect(meter.shouldPublish(now: start))
        _ = meter.publish(now: start)
        // 50 ms later (faster than 10 Hz): NOT due.
        #expect(!meter.shouldPublish(now: start.addingTimeInterval(0.05)))
        // 100 ms later (exactly the 10 Hz interval): due.
        #expect(meter.shouldPublish(now: start.addingTimeInterval(0.1)))
        #expect(LevelMeter.minPublishInterval == 0.1)
    }

    @Test("meter: ingested RMS flows through to a smoothed, silence-aware published pair")
    func meterEndToEnd() {
        let start = Date(timeIntervalSince1970: 0)
        var meter = LevelMeter(recordingStart: start)
        // You speaks, others is silent.
        for i in 0..<20 {
            let at = start.addingTimeInterval(Double(i) * 0.1)
            meter.ingestYou(rms: 0.6, at: at)
            meter.ingestOthers(rms: 0.0, at: at)
        }
        let now = start.addingTimeInterval(12)
        let levels = meter.publish(now: now)
        #expect(levels.you.level > 0.5)
        #expect(!levels.you.silent)
        // Others never rose above the floor → silent past the 10 s threshold.
        #expect(levels.others.silent)
        #expect(levels.others.level < LevelMeterChannel.silenceFloor)
    }
}
