import AVFoundation
import CoreAudio
import Foundation
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
/// (rate-move gate, gap-fill sizing, debounce-ceiling math, capture-down
/// predicate). The WIRING (debounced rebuild firing, retry ladder timing,
/// silence actually landing in the CAFs) needs live HAL devices and has NO
/// automated coverage — the gated capture integration test does not exercise
/// route changes; wiring-level discrimination rests on the audit lenses and
/// live verification (round-1 F-4, minimality ruling 25/07).
struct RouteChangeResilienceTests {

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

    @Test("shouldRaiseCaptureDown: raises exactly at the threshold, once")
    func captureDownPredicate() {
        let f = CaptureSession.shouldRaiseCaptureDown
        // No down-period, nothing to raise.
        #expect(!f(nil, 100, false, 8))
        // Below the threshold: quiet (sub-threshold blips produce no UI).
        #expect(!f(100, 107.999, false, 8))
        // At/past the threshold: raise.
        #expect(f(100, 108, false, 8))
        #expect(f(100, 500, false, 8))
        // Already raised: never twice per down-period.
        #expect(!f(100, 500, true, 8))
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
