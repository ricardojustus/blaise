import AVFoundation
import CoreAudio
import Foundation
import Synchronization
import Testing

@testable import BlaiseCore

// C11 AC1: tap/aggregate descriptor construction — parameter SNAPSHOT tests
// against the research-verified forms. These
// construct description objects and dictionaries only; no HAL device is
// created, no IO starts, no TCC prompt can fire.

@Suite("C11 capture descriptors")
struct CaptureDescriptorTests {
    @Test("tap description: mono global tap excluding self, private, unmuted")
    func tapDescription() {
        let selfID = AudioObjectID(4242)
        let description = CaptureDescriptors.tapDescription(excludingSelf: selfID)
        #expect(description.isMono)
        #expect(description.isPrivate)
        #expect(description.muteBehavior == .unmuted)
        #expect(description.name == "Blaise capture tap")
        // Global-mix-minus-processes form: mixdown of everything EXCEPT the
        // excluded list (us). The UUID is the aggregate's sub-tap key.
        #expect(description.isMixdown)
        #expect(description.isExclusive)
        #expect(description.processes == [selfID])
        #expect(!description.uuid.uuidString.isEmpty)
    }

    @Test("aggregate composition: sub-device list + tap list + drift on BOTH + autostart OFF + private")
    func aggregateComposition() throws {
        let dict = CaptureDescriptors.aggregateComposition(
            tapUID: "TAP-UUID-STRING", inputDeviceUID: "BuiltInMicrophoneDevice",
            aggregateUID: "test.aggregate.uid")

        // Key strings pinned to the SDK constants (the research-verified
        // forms; a constant drifting would break the recipe silently).
        #expect(kAudioAggregateDeviceSubDeviceListKey == "subdevices")
        #expect(kAudioAggregateDeviceTapListKey == "taps")
        #expect(kAudioSubDeviceUIDKey == "uid")
        #expect(kAudioSubTapUIDKey == "uid")
        #expect(kAudioSubDeviceDriftCompensationKey == "drift")
        #expect(kAudioSubTapDriftCompensationKey == "drift")
        #expect(kAudioAggregateDeviceTapAutoStartKey == "tapautostart")
        #expect(kAudioAggregateDeviceIsPrivateKey == "private")

        #expect(dict[kAudioAggregateDeviceUIDKey as String] as? String == "test.aggregate.uid")
        #expect(dict[kAudioAggregateDeviceNameKey as String] as? String == "Blaise Capture")
        #expect(dict[kAudioAggregateDeviceIsPrivateKey as String] as? Bool == true)
        // B3: the mic is pinned as the aggregate time source ("master") so both
        // tracks are delivered at one rate (drift root fix).
        #expect(
            dict[kAudioAggregateDeviceMainSubDeviceKey as String] as? String
                == "BuiltInMicrophoneDevice")
        // Pinned FALSE: tap auto-start gates the whole aggregate's IO (mic
        // included) on another process playing audio — on a quiet system
        // nothing is captured at all (root-caused 10/06/2026, killMidCapture).
        #expect(dict[kAudioAggregateDeviceTapAutoStartKey as String] as? Bool == false)

        let subDevices = try #require(
            dict[kAudioAggregateDeviceSubDeviceListKey as String] as? [[String: Any]])
        #expect(subDevices.count == 1)
        #expect(subDevices[0][kAudioSubDeviceUIDKey as String] as? String == "BuiltInMicrophoneDevice")
        #expect(subDevices[0][kAudioSubDeviceDriftCompensationKey as String] as? Bool == true)

        let taps = try #require(
            dict[kAudioAggregateDeviceTapListKey as String] as? [[String: Any]])
        #expect(taps.count == 1)
        // The tap UID is the UUID STRING (CATapDescription objects crash
        // CoreAudio — capture note, pinned).
        #expect(taps[0][kAudioSubTapUIDKey as String] as? String == "TAP-UUID-STRING")
        #expect(taps[0][kAudioSubTapDriftCompensationKey as String] as? Bool == true)
    }

    @Test("aggregate UID carries the cleanup prefix")
    func aggregateUIDPrefix() {
        let uid = CaptureDescriptors.makeAggregateUID()
        #expect(uid.hasPrefix(BlaiseBundle.identifier + "."))
        #expect(uid.count > (BlaiseBundle.identifier + ".").count)
    }
}

/// B3: capture-drift converter-rate resolution — the deterministic, headless-
/// testable parts of the fix. The WIRING in `CaptureSession.buildGraph` (which
/// format each converter actually receives) is covered only by the deferred
/// live-capture FFT / frames-vs-wallclock check (needs audio hardware + TCC).
struct CaptureRateResolutionTests {

    @Test("resolvedConverterRate: plausible Fs passes; nil/0/implausible -> nil (all-or-nothing fallback)")
    func resolvedRate() {
        let ok: (Double) -> Bool = { $0 == 48000 || $0 == 44100 }
        #expect(CaptureSession.resolvedConverterRate(aggregateRate: 48000, plausible: ok) == 48000)
        #expect(CaptureSession.resolvedConverterRate(aggregateRate: 44100, plausible: ok) == 44100)
        #expect(CaptureSession.resolvedConverterRate(aggregateRate: nil, plausible: ok) == nil)
        #expect(CaptureSession.resolvedConverterRate(aggregateRate: 0, plausible: ok) == nil)
        #expect(CaptureSession.resolvedConverterRate(aggregateRate: 999_999, plausible: ok) == nil)
        #expect(CaptureSession.resolvedConverterRate(aggregateRate: 1, plausible: ok) == nil)
    }

    @Test("isPlausibleRate: inside advertised ranges, or the sane bound when none advertised")
    func plausible() {
        let ranges = [
            AudioValueRange(mMinimum: 44100, mMaximum: 44100),
            AudioValueRange(mMinimum: 48000, mMaximum: 48000),
        ]
        #expect(CaptureSession.isPlausibleRate(48000, within: ranges))
        #expect(CaptureSession.isPlausibleRate(44100, within: ranges))
        #expect(!CaptureSession.isPlausibleRate(96000, within: ranges))  // not advertised
        #expect(!CaptureSession.isPlausibleRate(1, within: ranges))
        // No advertised ranges -> the sane absolute bound 8000...192000.
        #expect(CaptureSession.isPlausibleRate(48000, within: []))
        #expect(!CaptureSession.isPlausibleRate(5000, within: []))
        #expect(!CaptureSession.isPlausibleRate(200_000, within: []))
    }

    @Test("fallbackInputFormat: a degenerate per-stream rate is a FAILED build, never a converter input")
    func fallbackFormatRateGuard() throws {
        let base = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: 44100, channels: 1, interleaved: true))
        let asbd = base.streamDescription.pointee
        // The normal fallback case: the stream's own virtual format, verbatim.
        #expect(try CaptureSession.fallbackInputFormat(streamASBD: asbd).sampleRate == 44100)
        // 0 Hz is the reproduced crash input: it builds a NON-nil AVAudioFormat
        // and a NON-nil AVAudioConverter, so every downstream guard passes it
        // through to `ratio = 16000/0 = inf` and a trap. It must fail the BUILD
        // (→ retry ladder), which is what this branch had no guard for.
        var zero = asbd
        zero.mSampleRate = 0
        #expect(throws: CaptureSessionError.self) {
            try CaptureSession.fallbackInputFormat(streamASBD: zero)
        }
        var nonFinite = asbd
        nonFinite.mSampleRate = .infinity
        #expect(throws: CaptureSessionError.self) {
            try CaptureSession.fallbackInputFormat(streamASBD: nonFinite)
        }
        var negative = asbd
        negative.mSampleRate = -48000
        #expect(throws: CaptureSessionError.self) {
            try CaptureSession.fallbackInputFormat(streamASBD: negative)
        }
    }

    @Test("resampleCapacity: a degenerate source rate throws instead of trapping the process")
    func resampleCapacityGuard() throws {
        // 48 kHz → the 16 kHz writer format: a third of the frames, plus the pad.
        #expect(try CaptureSession.resampleCapacity(frames: 480, sourceRate: 48000) == 224)
        #expect(try CaptureSession.resampleCapacity(frames: 160, sourceRate: 16000) == 224)
        // The belt behind the build-time guard. `AVAudioFrameCount(inf)` and
        // `AVAudioFrameCount(4.3e9)` are Swift runtime TRAPS — the process dies
        // mid-recording, bypassing the ladder, the warning and the salvage.
        for badRate in [0, .infinity, .nan, 1e-300, -48000] as [Double] {
            #expect(throws: CaptureCAFWriterError.self) {
                try CaptureSession.resampleCapacity(frames: 400, sourceRate: badRate)
            }
        }
    }

    @Test("converterInputFormat: overrides ONLY the sample rate; channels + format preserved")
    func inputFormat() throws {
        let base = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: 44100, channels: 1, interleaved: true))
        let asbd = base.streamDescription.pointee
        let overridden = try #require(
            CaptureSession.converterInputFormat(streamASBD: asbd, rate: 48000))
        #expect(overridden.sampleRate == 48000)
        #expect(overridden.channelCount == 1)
        #expect(overridden.streamDescription.pointee.mBytesPerFrame == asbd.mBytesPerFrame)
        #expect(overridden.streamDescription.pointee.mFormatID == asbd.mFormatID)
        let same = try #require(
            CaptureSession.converterInputFormat(streamASBD: asbd, rate: 44100))
        #expect(same.sampleRate == 44100)
    }
}

/// B4: route-change resilience — the deterministic, headless-testable parts
/// (rate-move gate, gap-fill sizing, debounce-ceiling math, and the
/// capture-down alarm's own scheduling, which owns no HAL object). The REST
/// of the wiring (debounced rebuild firing, retry ladder
/// timing, silence actually landing in the CAFs) needs live HAL devices and
/// has NO automated coverage — the gated capture integration test does not
/// exercise route changes; wiring-level discrimination there rests on the
/// audit lenses and live verification (round-1 F-4, minimality ruling 25/07).
struct RouteChangeResilienceTests {

    /// Thread-safe sink: the alarm emits from its own queue.
    private final class EventRecorder: @unchecked Sendable {
        private let events = Mutex<[CaptureEngineEvent]>([])
        private let arrived = DispatchSemaphore(value: 0)
        func record(_ event: CaptureEngineEvent) {
            events.withLock { $0.append(event) }
            arrived.signal()
        }
        /// True if an event arrived within the timeout.
        func waitForEvent(timeout: TimeInterval) -> Bool {
            arrived.wait(timeout: .now() + timeout) == .success
        }
        var recorded: [CaptureEngineEvent] { events.withLock { $0 } }
    }

    @Test("capture-down alarm fires at its deadline while a build blocks the processing queue")
    func alarmFiresWhileProcessingQueueBlocked() {
        let alarm = CaptureDownAlarm(threshold: 0.05)
        let recorder = EventRecorder()
        alarm.reset(onEvent: { recorder.record($0) })

        // The production sequence: the down-clock is armed on the processing
        // queue at teardown, and `buildGraph()` — a synchronous CoreAudio call,
        // slow or hung is exactly the case this warning exists for — then holds
        // that queue ACROSS the deadline. An alarm scheduled on the processing
        // queue cannot run here, and the rebuild's success would clear it
        // unfired: >8 s of dead air behind a green indicator (audit H-R2-1).
        let processingQueue = DispatchQueue(label: "test.capture.processing")
        let building = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        processingQueue.async {
            alarm.arm(now: ProcessInfo.processInfo.systemUptime)
            building.signal()
            release.wait()
        }
        #expect(building.wait(timeout: .now() + 2) == .success)

        #expect(recorder.waitForEvent(timeout: 2))
        #expect(recorder.recorded == [.captureDown(active: true)])
        // A raised warning is the one a successful rebuild clears — and the
        // clear lands AFTER the raise, never inverting it, because both ride
        // the alarm queue. (Issued here from the test thread; in production
        // its caller is the processing queue, which is still blocked below.)
        alarm.clear()
        #expect(recorder.waitForEvent(timeout: 2))
        #expect(recorder.recorded == [.captureDown(active: true), .captureDown(active: false)])
        release.signal()
    }

    @Test("capture-down alarm: a rebuild that succeeds before the deadline never fires it")
    func alarmClearedBeforeDeadline() {
        let alarm = CaptureDownAlarm(threshold: 0.1)
        let recorder = EventRecorder()
        alarm.reset(onEvent: { recorder.record($0) })
        alarm.arm(now: ProcessInfo.processInfo.systemUptime)
        // Success below the threshold: nothing was raised, so nothing is
        // cleared either — a normal rebuild causes no UI churn at all.
        alarm.clear()
        // And the armed alarm stays silent past its deadline (0 stale fires).
        #expect(!recorder.waitForEvent(timeout: 0.4))
        #expect(recorder.recorded.isEmpty)
    }

    /// A sink that PINS the alarm queue while it emits: the handler holds
    /// inside the raise for a bounded `hold`, so anything queued behind it (a
    /// clear, a later raise) is provably still pending while the test drives
    /// `reset`. The hold releases ITSELF — the test thread must stay free to
    /// call `reset`, and no externally-signalled release could be ordered
    /// against reset's internals. It is a window, never a race margin: the
    /// assertions below compare recorded instants, never durations.
    private final class PinningSink: @unchecked Sendable {
        let recorder = EventRecorder()
        private let pinned = DispatchSemaphore(value: 0)
        private let unpinned = DispatchSemaphore(value: 0)
        private let releasedAt = Mutex<TimeInterval?>(nil)
        private let hold: TimeInterval

        init(hold: TimeInterval) { self.hold = hold }

        func handle(_ event: CaptureEngineEvent) {
            recorder.record(event)
            guard event == .captureDown(active: true) else { return }
            pinned.signal()
            Thread.sleep(forTimeInterval: hold)
            releasedAt.withLock { $0 = ProcessInfo.processInfo.systemUptime }
            unpinned.signal()
        }
        /// Waits until the raise is mid-emission (the queue is pinned).
        func waitUntilPinned() -> Bool { pinned.wait(timeout: .now() + 2) == .success }
        /// Waits until that emission has finished.
        func waitUntilReleased() -> Bool { unpinned.wait(timeout: .now() + 2) == .success }
        /// The instant the pinned emission finished; nil while it is running.
        var releasedAtUptime: TimeInterval? { releasedAt.withLock { $0 } }
    }

    /// R3-F1: `reset` is a FENCE. A clear whose emission is already queued
    /// cannot deliver through the sink reset dropped, and reset cannot return
    /// while an emission through that sink is still in flight.
    @Test("capture-down alarm: reset fences a clear already queued on the alarm queue")
    func resetFencesQueuedClear() {
        let alarm = CaptureDownAlarm(threshold: 0.05)
        let sink = PinningSink(hold: 1)
        alarm.reset(onEvent: { sink.handle($0) })
        alarm.arm(now: ProcessInfo.processInfo.systemUptime)
        #expect(sink.waitUntilPinned())
        #expect(sink.recorder.waitForEvent(timeout: 2))

        // The rebuild succeeds while the raise is still being emitted, so the
        // clear's `false` queues behind it; the recording then stops.
        alarm.clear()
        alarm.reset(onEvent: nil)
        let resetReturnedAt = ProcessInfo.processInfo.systemUptime

        // The fence outlived the emission that was in flight (nil = reset
        // returned while the old sink was still running).
        #expect(sink.releasedAtUptime.map { $0 <= resetReturnedAt } ?? false)
        // And the queued `false`, re-reading the sink at emission time, found
        // it replaced and dropped it: the old sink never sees it.
        #expect(sink.waitUntilReleased())
        #expect(!sink.recorder.waitForEvent(timeout: 0.3))
        #expect(sink.recorder.recorded == [.captureDown(active: true)])
    }

    /// R3-F1: once reset has installed the NEXT recording's sink, nothing from
    /// the previous generation may emit — not late through the old sink (the
    /// indicator state machine is shared across recordings, so a stale
    /// `captureDown` would stand a false warning over a healthy recording with
    /// nothing to clear it), and not through the new sink either.
    @Test("capture-down alarm: reset to the next recording's sink retires the previous generation")
    func resetRetiresPreviousGeneration() {
        let alarm = CaptureDownAlarm(threshold: 0.05)
        let previous = PinningSink(hold: 1)
        let next = EventRecorder()
        alarm.reset(onEvent: { previous.handle($0) })
        alarm.arm(now: ProcessInfo.processInfo.systemUptime)
        #expect(previous.waitUntilPinned())
        #expect(previous.recorder.waitForEvent(timeout: 2))

        // The rebuild succeeds (the `false` queues behind the pinned sink),
        // the recording stops, and the next one installs its own sink.
        alarm.clear()
        alarm.reset(onEvent: { next.record($0) })
        let resetReturnedAt = ProcessInfo.processInfo.systemUptime
        #expect(previous.releasedAtUptime.map { $0 <= resetReturnedAt } ?? false)

        // The next recording's first route change arms its own down-period.
        alarm.arm(now: ProcessInfo.processInfo.systemUptime)
        #expect(previous.waitUntilReleased())

        // Nothing from the previous generation lands anywhere: not late
        // through the old sink...
        #expect(!previous.recorder.waitForEvent(timeout: 0.3))
        #expect(previous.recorder.recorded == [.captureDown(active: true)])
        // ...and the new sink sees ONLY its own period's raise.
        #expect(next.waitForEvent(timeout: 2))
        #expect(!next.waitForEvent(timeout: 0.3))
        #expect(next.recorded == [.captureDown(active: true)])
    }

    @Test("effectiveDebounceDelay: trailing window clamps to the ceiling, never restarts")
    func debounceCeiling() {
        let f = CaptureSession.effectiveDebounceDelay
        // First trigger of a burst: full debounce window.
        #expect(f(0.5, nil, 100, 3) == 0.5)
        // Mid-burst: the ceiling counts from the FIRST trigger.
        #expect(f(0.5, 100, 101, 3) == 0.5)
        #expect(f(0.5, 100, 102.75, 3) == 0.25)
        // At/past the ceiling: fire immediately no matter how fast triggers arrive.
        #expect(f(0.5, 100, 103, 3) == 0)
        #expect(f(0.5, 100, 200, 3) == 0)
        // A LADDER delay routed through this math is CLAMPED — the reason
        // retries must NOT pass through it (F-2; scheduleRetry exists so the
        // 4 s/8 s rungs run at full length). This pins the hazard.
        #expect(f(8, 100, 100, 3) == 3)
    }

    @Test("rateChangeRequiresRebuild: only a MOVED readable rate rebuilds (loop-proof)")
    func rateMoveGate() {
        // Unreadable now -> zero information, never rebuild (would loop while
        // the rate stays unreadable).
        #expect(!CaptureSession.rateChangeRequiresRebuild(current: nil, observedAtBuild: 48000))
        #expect(!CaptureSession.rateChangeRequiresRebuild(current: nil, observedAtBuild: nil))
        // Readable now, unreadable at build -> one upgrade rebuild.
        #expect(CaptureSession.rateChangeRequiresRebuild(current: 48000, observedAtBuild: nil))
        // Same rate (an aggregate notifies for its own initial rate) -> skip.
        #expect(!CaptureSession.rateChangeRequiresRebuild(current: 48000, observedAtBuild: 48000))
        #expect(!CaptureSession.rateChangeRequiresRebuild(current: 48000.5, observedAtBuild: 48000))
        // A real move (the observed Bluetooth 48k<->24k flap) -> rebuild.
        #expect(CaptureSession.rateChangeRequiresRebuild(current: 24000, observedAtBuild: 48000))
        #expect(CaptureSession.rateChangeRequiresRebuild(current: 48000, observedAtBuild: 24000))
    }

    @Test("silenceFillFrames: sub-minimum gaps are jitter; real gaps fill; the cap bounds")
    func gapSizing() {
        let rate = CaptureCAFWriter.sampleRate
        // Below the minimum: no fill (sub-buffer jitter, not a gap).
        #expect(CaptureSession.silenceFillFrames(gapSeconds: 0, sampleRate: rate) == 0)
        #expect(CaptureSession.silenceFillFrames(gapSeconds: 0.04, sampleRate: rate) == 0)
        // The observed per-rebuild loss band (0.1–2.2 s) fills exactly.
        #expect(CaptureSession.silenceFillFrames(gapSeconds: 0.5, sampleRate: rate) == 8000)
        #expect(CaptureSession.silenceFillFrames(gapSeconds: 2.2, sampleRate: rate) == 35200)
        // The cap bounds a pathological anchor.
        #expect(
            CaptureSession.silenceFillFrames(gapSeconds: 10_000, sampleRate: rate)
                == Int(CaptureSession.gapFillMaximumSeconds * rate))
    }

    @Test("route-resilience constants: the operator-ratified values, pinned")
    func ratifiedConstants() {
        // Operator-ratified B4 values: silent drift here changes what the
        // recording does under a route change, with nothing else failing.
        #expect(CaptureSession.rebuildDebounceSeconds == 0.5)
        #expect(CaptureSession.rebuildMaxWaitSeconds == 3)
        #expect(CaptureSession.captureDownAlarmSeconds == 8)
        #expect(CaptureSession.rebuildRetryDelays == [0.5, 1, 2, 4, 8])
        #expect(CaptureSession.maxRateTriggeredRebuilds == 3)
    }

    @Test("retry ladder: bounded, monotonic, finite total")
    func retryLadder() {
        let delays = CaptureSession.rebuildRetryDelays
        #expect(!delays.isEmpty)
        #expect(delays == delays.sorted())
        // The whole ladder resolves (or gives up) well under a minute — the
        // user-visible ceiling for "recording still green but silent".
        #expect(delays.reduce(0, +) < 60)
    }
}

// MARK: - CAF writer format assertions (AC1)

@Suite("C11 capture CAF writer")
struct CaptureCAFWriterTests {
    @Test("writes LPCM Int16 16 kHz mono CAF (the probed crash-safe format)")
    func formatAssertions() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-writer-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try CaptureCAFWriter(url: url)
        let format = CaptureCAFWriter.format
        #expect(format.sampleRate == 16_000)
        #expect(format.channelCount == 1)
        #expect(format.commonFormat == .pcmFormatInt16)

        let frames: AVAudioFrameCount = 16_000  // 1 s
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.int16ChannelData![0]
        for n in 0 ..< Int(frames) {
            samples[n] = Int16(6000 * sin(2 * .pi * 440 * Double(n) / 16_000))
        }
        try writer.write(buffer)
        #expect(writer.framesWritten == Int64(frames))
        writer.close()

        let readBack = try AVAudioFile(forReading: url)
        #expect(readBack.fileFormat.sampleRate == 16_000)
        #expect(readBack.fileFormat.channelCount == 1)
        #expect(readBack.length == Int64(frames))
        // CAF container, not WAV/m4a: first bytes are the 'caff' magic.
        let head = try Data(contentsOf: url, options: .mappedIfSafe).prefix(4)
        #expect(head == Data("caff".utf8))
    }

    @Test("a never-closed CAF is fully decodable (crash-safety by construction)")
    func decodableWithoutClose() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-writer-noclose-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try CaptureCAFWriter(url: url)
        let format = CaptureCAFWriter.format
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000)!
        buffer.frameLength = 8000
        try writer.write(buffer)
        // NO close: open a second reader against the live file — the LPCM
        // CAF data chunk is sized -1 ("rest of file") until close, so every
        // written frame is already readable (the probed kill -9 property).
        let readBack = try AVAudioFile(forReading: url)
        #expect(readBack.length == 8000)
        writer.close()
    }
}
