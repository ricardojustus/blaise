import AVFoundation
import Foundation
import Testing

@testable import BlaiseCore

// A 16 kHz mono Int16 silent WAV of the given length — `stitchTrack`'s exact
// required input format, so its frame-count ground truth is comparable to the
// planner's placement math (H-1 cross-check).
private func writeSilentWAV(at url: URL, seconds: Double) throws {
    let sampleRate = 16_000.0
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ]
    let file = try AVAudioFile(
        forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
    let frames = AVAudioFrameCount((seconds * sampleRate).rounded())
    let format = file.processingFormat
    var remaining = frames
    while remaining > 0 {
        let chunk = min(remaining, 65_536)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk)!
        buffer.frameLength = chunk  // zero-initialized = silence
        try file.write(from: buffer)
        remaining -= chunk
    }
}

// Player composition planning (field bug 2026-06-12: the player mixed only the
// system track, dropping the user's own mic). These pin the PURE placement
// logic that the AVMutableComposition wiring (executable target) consumes:
// which file lands on which track at what absolute timeline offset, for the
// single-part and multi-part (C14) shapes. The AVMutableComposition build
// itself and measured both-voices-audible playback are verified by build +
// the integration check; this is the offset math.

private func sysURL(_ index: Int) -> URL { URL(fileURLWithPath: "/tmp/audio_\(index).m4a") }
private func micURL(_ index: Int) -> URL { URL(fileURLWithPath: "/tmp/audio_mic_\(index).m4a") }

@Suite("Player two-track placement planning")
struct PlaybackPlacementTests {
    @Test("single part: both tracks start at t=0 and are scaled onto the wall-clock span")
    func singlePartScaledToWallClock() {
        // Field truth (2026-06-12 sync bug): the mic and system files of one
        // part DRIFT apart — here a 1578.1 s wall-clock part wrote a 1578.3 s
        // system file (≈ real time) and a 1717.8 s mic file (1.088× — the same
        // ratio measured on every field meeting). Both start at t=0, and each
        // is stretched by wallSpan/fileDuration so they share one real-time
        // axis: system ≈ 1.0 (already real), mic ≈ 0.919 (compressed back).
        let parts = [
            CaptureStitcher.PlannedPart(
                index: 1, offsetMs: 0, wallSpanMs: 1_578_111,
                systemM4A: sysURL(1), micM4A: micURL(1))
        ]
        let durations = [sysURL(1): 1578.304, micURL(1): 1717.824]
        let placements = CaptureStitcher.playbackPlacements(parts: parts, durations: durations)
        #expect(placements.count == 2)
        let sys = try! #require(placements.first { $0.track == .system })
        let mic = try! #require(placements.first { $0.track == .mic })
        #expect(sys.startSeconds == 0)
        #expect(mic.startSeconds == 0)
        #expect(abs(sys.timeScale - 1578.111 / 1578.304) < 0.0001)  // ≈ 0.99988
        #expect(abs(mic.timeScale - 1578.111 / 1717.824) < 0.0001)  // ≈ 0.91867
        #expect(sys.scaleKnown && mic.scaleKnown)
        #expect(CaptureStitcher.playbackScalingTrustworthy(placements: placements))
    }

    @Test("L-4: a pathological span (scale outside the sanity band) is distrusted → unity fallback")
    func pathologicalSpanDistrusted() {
        // A closed row whose wall-clock span is wildly larger than the file
        // duration (here ~3.2×, far above the 1.18 band ceiling) is NOT genuine
        // clock drift — it is a corrupt/derived span. The planner must distrust
        // it: unity scale, scaleKnown false, so the multi-track trust gate drops
        // to single-track playback rather than stretching the file 3×.
        let parts = [
            CaptureStitcher.PlannedPart(
                index: 1, offsetMs: 0, wallSpanMs: 5_000_000,  // 5000 s span...
                systemM4A: sysURL(1), micM4A: micURL(1))
        ]
        let durations = [sysURL(1): 1578.0, micURL(1): 1578.0]  // ...for a 1578 s file
        let placements = CaptureStitcher.playbackPlacements(parts: parts, durations: durations)
        #expect(placements.allSatisfy { $0.timeScale == 1.0 && !$0.scaleKnown })
        #expect(!CaptureStitcher.playbackScalingTrustworthy(placements: placements))
    }

    @Test("L-4: the real ±8.8% drift stays comfortably inside the sanity band (trusted)")
    func realDriftInsideBand() {
        // Both field polarities — 0.919 (mic-drifted) and 1.088 (system-drifted)
        // — must remain TRUSTED; the band only rejects pathological rows.
        for (sysDur, micDur) in [(1578.304, 1717.824), (1465.920, 1595.520)] {
            let parts = [
                CaptureStitcher.PlannedPart(
                    index: 1, offsetMs: 0, wallSpanMs: 1_578_111,
                    systemM4A: sysURL(1), micM4A: micURL(1))
            ]
            let durations = [sysURL(1): sysDur, micURL(1): micDur]
            let placements = CaptureStitcher.playbackPlacements(parts: parts, durations: durations)
            let allKnown = placements.allSatisfy { $0.scaleKnown }
            #expect(allKnown)
            let inBand = CaptureStitcher.timeScaleSanityBand.contains(1578.111 / micDur)
            #expect(inBand)
        }
    }

    @Test("no wall-clock span: tracks fall back to unity (untrusted scale)")
    func singlePartNoSpanUntrusted() {
        // Without a closed part row (wallSpanMs nil) the cross-track drift is
        // unknown: unity scale, scaleKnown false, and the trust gate refuses
        // to mix both tracks (single-track fallback at the call site).
        let parts = [
            CaptureStitcher.PlannedPart(
                index: 1, offsetMs: 0, systemM4A: sysURL(1), micM4A: micURL(1))
        ]
        let durations = [sysURL(1): 1578.3, micURL(1): 1717.8]
        let placements = CaptureStitcher.playbackPlacements(parts: parts, durations: durations)
        #expect(placements.allSatisfy { $0.timeScale == 1.0 && !$0.scaleKnown })
        #expect(!CaptureStitcher.playbackScalingTrustworthy(placements: placements))
    }

    @Test("system-only part (mic lost): one system placement, no mic")
    func systemOnly() {
        let parts = [
            CaptureStitcher.PlannedPart(index: 1, offsetMs: 0, systemM4A: sysURL(1), micM4A: nil)
        ]
        let placements = CaptureStitcher.playbackPlacements(parts: parts)
        #expect(placements == [.init(track: .system, url: sysURL(1), startSeconds: 0)])
    }

    @Test("mic-only part (system lost): one mic placement, no system")
    func micOnly() {
        let parts = [
            CaptureStitcher.PlannedPart(index: 1, offsetMs: 0, systemM4A: nil, micM4A: micURL(1))
        ]
        let placements = CaptureStitcher.playbackPlacements(parts: parts)
        #expect(placements == [.init(track: .mic, url: micURL(1), startSeconds: 0)])
    }

    @Test("multi-part: each part anchored at its absolute wall-clock offset")
    func multiPartAbsoluteOffsets() {
        // Part 2 started 20 s after part 1 — both its tracks land at 20.0,
        // matching the transcode stitcher's absolute re-anchoring exactly.
        let parts = [
            CaptureStitcher.PlannedPart(
                index: 1, offsetMs: 0, systemM4A: sysURL(1), micM4A: micURL(1)),
            CaptureStitcher.PlannedPart(
                index: 2, offsetMs: 20_000, systemM4A: sysURL(2), micM4A: micURL(2)),
        ]
        let placements = CaptureStitcher.playbackPlacements(parts: parts)
        #expect(placements.count == 4)
        #expect(placements.contains(.init(track: .system, url: sysURL(1), startSeconds: 0)))
        #expect(placements.contains(.init(track: .mic, url: micURL(1), startSeconds: 0)))
        #expect(placements.contains(.init(track: .system, url: sysURL(2), startSeconds: 20.0)))
        #expect(placements.contains(.init(track: .mic, url: micURL(2), startSeconds: 20.0)))
    }

    @Test("multi-part: a missing track in one part does not shift the other parts")
    func multiPartMissingTrackNoShift() {
        // Part 2 lost its mic; part 2 system still anchors at 20.0 and part 3
        // (both tracks) still anchors at 50.0 — absolute offsets, not running
        // sums, so a gap never propagates.
        let parts = [
            CaptureStitcher.PlannedPart(
                index: 1, offsetMs: 0, systemM4A: sysURL(1), micM4A: micURL(1)),
            CaptureStitcher.PlannedPart(
                index: 2, offsetMs: 20_000, systemM4A: sysURL(2), micM4A: nil),
            CaptureStitcher.PlannedPart(
                index: 3, offsetMs: 50_000, systemM4A: sysURL(3), micM4A: micURL(3)),
        ]
        let placements = CaptureStitcher.playbackPlacements(parts: parts)
        #expect(placements.contains(.init(track: .system, url: sysURL(2), startSeconds: 20.0)))
        #expect(!placements.contains { $0.track == .mic && $0.startSeconds == 20.0 })
        #expect(placements.contains(.init(track: .system, url: sysURL(3), startSeconds: 50.0)))
        #expect(placements.contains(.init(track: .mic, url: micURL(3), startSeconds: 50.0)))
    }

    @Test("parts arrive out of order: placements still anchored by part offset")
    func outOfOrderInputAnchorsCorrectly() {
        let parts = [
            CaptureStitcher.PlannedPart(
                index: 2, offsetMs: 20_000, systemM4A: sysURL(2), micM4A: micURL(2)),
            CaptureStitcher.PlannedPart(
                index: 1, offsetMs: 0, systemM4A: sysURL(1), micM4A: micURL(1)),
        ]
        let placements = CaptureStitcher.playbackPlacements(parts: parts)
        #expect(placements.contains(.init(track: .system, url: sysURL(1), startSeconds: 0)))
        #expect(placements.contains(.init(track: .system, url: sysURL(2), startSeconds: 20.0)))
    }

    @Test("row-less residue (offsetMs nil) appends at the END of the prior part's audio")
    func rowlessResidueAppendsAtFrontier() {
        // Part 1 anchored at 0 with 10 s of audio on each track; part 2 is
        // row-less residue (no part metadata). It must append AFTER part 1's
        // audio — at 10.0 s — exactly as `stitchTrack` does (its `offsetMs ==
        // nil` source appends at `emitted`, the end of audio already written),
        // NOT at the anchored start (0) where it would play over part 1
        // (double-talk) and diverge from the transcript by the full prior
        // duration. This is the auditor's H-1 probe, pinned to the
        // stitcher-true value.
        let parts = [
            CaptureStitcher.PlannedPart(
                index: 1, offsetMs: 0, systemM4A: sysURL(1), micM4A: micURL(1)),
            CaptureStitcher.PlannedPart(
                index: 2, offsetMs: nil, systemM4A: sysURL(2), micM4A: micURL(2)),
        ]
        let durations = [sysURL(1): 10.0, micURL(1): 10.0]
        let placements = CaptureStitcher.playbackPlacements(parts: parts, durations: durations)
        #expect(placements.contains(.init(track: .system, url: sysURL(2), startSeconds: 10.0)))
        #expect(placements.contains(.init(track: .mic, url: micURL(2), startSeconds: 10.0)))
        // Part 1 still anchored at 0.
        #expect(placements.contains(.init(track: .system, url: sysURL(1), startSeconds: 0)))
        #expect(placements.contains(.init(track: .mic, url: micURL(1), startSeconds: 0)))
    }

    @Test("row-less residue matches stitchTrack frame-for-frame (10 s + residue)")
    func rowlessResidueMatchesStitcher() throws {
        // Cross-check the planner's residue start against the stitcher GROUND
        // TRUTH on real 16 kHz mono WAVs: 10 s of part-1 audio then a row-less
        // part 2. stitchTrack places part 2 at `emitted` = 10.0 s (its frame
        // count proves it); the planner must return the SAME 10.0 s start.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blaise-residue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let p1 = dir.appendingPathComponent("p1.wav")
        let p2 = dir.appendingPathComponent("p2.wav")
        try writeSilentWAV(at: p1, seconds: 10.0)
        try writeSilentWAV(at: p2, seconds: 4.0)
        // Stitcher ground truth: part 1 anchored at 0, part 2 row-less.
        let result = try CaptureStitcher.stitchTrack(
            sources: [(offsetMs: 0, wav: p1), (offsetMs: nil, wav: p2)],
            destination: dir.appendingPathComponent("out.wav"))
        // 14 s total → part 2's audio begins at exactly 10.0 s (= emitted).
        #expect(abs(result.duration - 14.0) < 0.01)
        // Planner agrees: residue start = end of prior audio = 10.0 s.
        let parts = [
            CaptureStitcher.PlannedPart(index: 1, offsetMs: 0, systemM4A: p1, micM4A: nil),
            CaptureStitcher.PlannedPart(index: 2, offsetMs: nil, systemM4A: p2, micM4A: nil),
        ]
        let durations = try [p1: WAVHeader.read(at: p1).duration]
        let placements = CaptureStitcher.playbackPlacements(parts: parts, durations: durations)
        let residue = try #require(placements.first { $0.url == p2 })
        #expect(abs(residue.startSeconds - 10.0) < 0.01)
    }

    @Test("multiple row-less residue parts stack in order, not at one instant")
    func multipleRowlessResidueStack() {
        // Three residue parts (5 s each) following a 10 s anchored part must
        // land at 10, 15, 20 — ordered and non-overlapping — not all at the
        // same frontier (the old bug stacked them at one instant).
        let parts = [
            CaptureStitcher.PlannedPart(index: 1, offsetMs: 0, systemM4A: sysURL(1), micM4A: nil),
            CaptureStitcher.PlannedPart(index: 2, offsetMs: nil, systemM4A: sysURL(2), micM4A: nil),
            CaptureStitcher.PlannedPart(index: 3, offsetMs: nil, systemM4A: sysURL(3), micM4A: nil),
            CaptureStitcher.PlannedPart(index: 4, offsetMs: nil, systemM4A: sysURL(4), micM4A: nil),
        ]
        let durations = [sysURL(1): 10.0, sysURL(2): 5.0, sysURL(3): 5.0, sysURL(4): 5.0]
        let placements = CaptureStitcher.playbackPlacements(parts: parts, durations: durations)
        #expect(placements.contains(.init(track: .system, url: sysURL(2), startSeconds: 10.0)))
        #expect(placements.contains(.init(track: .system, url: sysURL(3), startSeconds: 15.0)))
        #expect(placements.contains(.init(track: .system, url: sysURL(4), startSeconds: 20.0)))
    }

    @Test("empty parts: no placements")
    func emptyParts() {
        #expect(CaptureStitcher.playbackPlacements(parts: []).isEmpty)
    }
}

// MARK: - Mix balance (M-2): the user's mic must not be buried under the
// other side. This renders the REAL composition+AVAudioMix path offline (no
// audio device, no private meeting audio — synthetic noise at the measured
// FIELD levels: mic median ≈ −34 dBFS, system median ≈ −21 dBFS), then asserts
// the system attenuation (`systemTrackPlaybackGain`) closes the residual gap to
// ≤6 dB. Mirrors the offline re-measurement on the real meeting (residual gap
// there ≈ 4.0 dB).

@Suite("Player mix balance (system attenuation)")
struct PlaybackMixBalanceTests {
    private static let rate = 16_000.0

    private func dB(_ rms: Double) -> Double { rms > 0 ? 20 * log10(rms) : -160 }

    /// White noise at a target RMS amplitude, written as 16 kHz mono float WAV.
    private func writeNoiseWAV(at url: URL, seconds: Double, rms: Float) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.rate,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: true)
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        func next() -> Float {  // xorshift, uniform [-1,1] scaled to target RMS
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            let u = Double(state >> 11) / Double(1 << 53)  // [0,1)
            return Float((u * 2 - 1) * 1.7320508)  // uniform var → unit RMS
        }
        let total = AVAudioFrameCount((seconds * Self.rate).rounded())
        let format = file.processingFormat
        var written: AVAudioFrameCount = 0
        while written < total {
            let chunk = min(total - written, 65_536)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk)!
            buffer.frameLength = chunk
            let ptr = buffer.floatChannelData![0]
            for i in 0..<Int(chunk) { ptr[i] = next() * rms }
            try file.write(from: buffer)
            written += chunk
        }
    }

    /// RMS of the rendered mix output (offline, AVAssetReaderAudioMixOutput).
    private func renderRMS(
        composition: AVMutableComposition, mix: AVAudioMix?
    ) throws -> Double {
        let reader = try AVAssetReader(asset: composition)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.rate,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderAudioMixOutput(
            audioTracks: composition.tracks(withMediaType: .audio), audioSettings: settings)
        output.audioMix = mix
        reader.add(output)
        reader.startReading()
        var acc = 0.0
        var count = 0
        while let sb = output.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            let len = CMBlockBufferGetDataLength(bb)
            var buf = [Float](repeating: 0, count: len / 4)
            CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: &buf)
            for v in buf { acc += Double(v) * Double(v) }
            count += buf.count
            CMSampleBufferInvalidate(sb)
        }
        return count > 0 ? (acc / Double(count)).squareRoot() : 0
    }

    private func track(_ comp: AVMutableComposition, url: URL) async throws -> AVMutableCompositionTrack {
        let asset = AVURLAsset(url: url)
        let src = try await asset.loadTracks(withMediaType: .audio).first!
        let dur = try await asset.load(.duration)
        let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try t.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: src, at: .zero)
        return t
    }

    @Test("system attenuation brings the buried mic within 6 dB of the other side")
    func systemAttenuationClosesGap() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blaise-mix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Measured field levels: mic −34 dBFS (0.020), system −21 dBFS (0.089).
        let micURL = dir.appendingPathComponent("mic.wav")
        let sysURL = dir.appendingPathComponent("sys.wav")
        try writeNoiseWAV(at: micURL, seconds: 3, rms: 0.0200)  // −34 dBFS
        try writeNoiseWAV(at: sysURL, seconds: 3, rms: 0.0891)  // −21 dBFS

        // Solo loudness of each track in isolation (one-track composition).
        let micComp = AVMutableComposition()
        _ = try await track(micComp, url: micURL)
        let micSolo = dB(try renderRMS(composition: micComp, mix: nil))

        let sysCompRaw = AVMutableComposition()
        _ = try await track(sysCompRaw, url: sysURL)
        let sysRawSolo = dB(try renderRMS(composition: sysCompRaw, mix: nil))

        // Confirm the pre-fix gap is the field gap (~13 dB), i.e. the mic is
        // genuinely the quieter, buried track.
        let rawGap = sysRawSolo - micSolo
        #expect(rawGap > 10)  // mic is buried before the fix

        // System solo WITH the playback gain applied (the M-2 mix).
        let sysComp = AVMutableComposition()
        let sysTrack = try await track(sysComp, url: sysURL)
        let mix = AVMutableAudioMix()
        let params = AVMutableAudioMixInputParameters(track: sysTrack)
        params.setVolume(CaptureStitcher.systemTrackPlaybackGain, at: .zero)
        mix.inputParameters = [params]
        let sysGainSolo = dB(try renderRMS(composition: sysComp, mix: mix))

        // Residual gap after attenuation must be within the ≤6 dB target, and
        // the mic must remain the SAME loudness (never boosted/cut).
        let residualGap = sysGainSolo - micSolo
        #expect(residualGap <= 6.0)
        #expect(residualGap > 0)  // system still the louder side, not flipped
        // The attenuation is exactly the gain in dB (sanity on the mix path).
        let expectedDrop = 20 * log10(Double(CaptureStitcher.systemTrackPlaybackGain))
        #expect(abs((sysGainSolo - sysRawSolo) - expectedDrop) < 0.5)
    }
}

// MARK: - Honest failure (M-3): an empty composition (every retained file
// unreadable) must NOT silently pretend to play. This pins the platform fact
// the fix relies on — an AVPlayerItem over an empty AVMutableComposition never
// resolves to `.failed`; its status stays `.unknown`. So the UI cannot key the
// read-error state on item status; the view keys it on the resolved
// `anyReadable` flag instead (the empty composition yields no tracks).

@Suite("Player honest-failure (empty composition)")
struct PlaybackEmptyCompositionTests {
    @MainActor
    @Test("an AVPlayerItem over an empty composition stays .unknown (never .failed)")
    func emptyCompositionNeverFails() async throws {
        let empty = AVMutableComposition()  // zero tracks — the all-unreadable case
        #expect(empty.tracks.isEmpty)  // the flag the view actually keys on
        let item = AVPlayerItem(asset: empty)
        let player = AVPlayer(playerItem: item)
        player.rate = 1.0  // even a play attempt does not flip it to .failed
        // Poll briefly: the status never reaches .failed (it stays .unknown,
        // occasionally .readyToPlay on an empty asset, but never .failed).
        var sawFailed = false
        for _ in 0..<20 {
            if item.status == .failed { sawFailed = true; break }
            try await Task.sleep(nanoseconds: 50_000_000)  // 50 ms × 20 = 1 s
        }
        player.pause()
        #expect(!sawFailed)
        #expect(item.error == nil)
    }
}
// MARK: - Cross-track real-time alignment + clock-drift pitch correction.
//
// These now live in `BlaiseAppTests/PlaybackCompositionRenderTests.swift`, which
// renders the REAL production builder `AudioPlayerView.composition(for:)` (not a
// replica) for BOTH drift polarities and asserts cross-track sync AND that the
// drifted track's pitch is corrected to ≤1% of true via per-track `.varispeed`
// (sync-fix audit L-1/L-2/H-1). The pure placement/trust math they consume is
// pinned above in `PlaybackPlacementTests`.
