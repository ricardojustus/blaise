import AVFoundation
import Accelerate
import BlaiseCore
import Foundation
import Testing

@testable import BlaiseApp

// Cross-track real-time alignment + clock-drift PITCH correction, rendered
// through the REAL production composition builder `AudioPlayerView.composition`
// (sync-fix audit: L-2 — the pin calls the production code, not a replica; L-1
// — both drift polarities are covered; H-1 — the drifted track's pitch is
// corrected, not just its timing).
//
// The capture artifact is reproduced faithfully: a part with a 100 s wall-clock
// span where ONE track is written at wall-clock (≈ real time) and the OTHER is
// the drifted file — time-dilated by the field-measured 48000/44100 ≈ 1.0886
// converter ratio AND, because the dilation is baked into the samples, pitched
// by the inverse of that ratio. Each track carries a steady tone whose true
// frequency is known; the builder must (a) land both tracks' content at the
// same REAL time (sync) and (b) bring the drifted track's rendered tone back to
// the true frequency (pitch), via per-track `.varispeed` on the scaled track.

@Suite("Playback composition render (real builder)")
@MainActor
struct PlaybackCompositionRenderTests {
    private static let rate = 16_000.0

    /// A WAV of `seconds` carrying a steady `toneHz` sine, 16 kHz mono float.
    private func writeToneWAV(at url: URL, seconds: Double, toneHz: Double) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.rate,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: true)
        let total = AVAudioFrameCount((seconds * Self.rate).rounded())
        let format = file.processingFormat
        var written = 0
        while AVAudioFrameCount(written) < total {
            let chunk = Int(min(total - AVAudioFrameCount(written), 65_536))
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk))!
            buffer.frameLength = AVAudioFrameCount(chunk)
            let ptr = buffer.floatChannelData![0]
            for i in 0..<chunk {
                ptr[i] = Float(sin(2.0 * .pi * toneHz * Double(written + i) / Self.rate))
            }
            try file.write(from: buffer)
            written += chunk
        }
    }

    /// A silent WAV with one 1 s full-scale 440 Hz burst centered at `burstAt`.
    private func writeBurstWAV(at url: URL, seconds: Double, burstAt: Double) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.rate,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: true)
        let total = AVAudioFrameCount((seconds * Self.rate).rounded())
        let burstLo = Int((burstAt - 0.5) * Self.rate)
        let burstHi = Int((burstAt + 0.5) * Self.rate)
        let format = file.processingFormat
        var written = 0
        while AVAudioFrameCount(written) < total {
            let chunk = Int(min(total - AVAudioFrameCount(written), 65_536))
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk))!
            buffer.frameLength = AVAudioFrameCount(chunk)
            let ptr = buffer.floatChannelData![0]
            for i in 0..<chunk {
                let g = written + i
                ptr[i] = (g >= burstLo && g < burstHi)
                    ? Float(sin(2.0 * .pi * 440.0 * Double(g) / Self.rate)) : 0
            }
            try file.write(from: buffer)
            written += chunk
        }
    }

    /// Render one composition track offline (under the builder's audioMix) and
    /// return its mono float samples.
    private func renderTrack(
        _ composition: AVMutableComposition, mix: AVAudioMix?, track: AVAssetTrack
    ) throws -> [Float] {
        let reader = try AVAssetReader(asset: composition)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.rate,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        // Per-track render: a single-track mix output so the per-track
        // audioTimePitchAlgorithm of THIS track governs the rendering.
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: settings)
        output.audioMix = mix
        reader.add(output)
        reader.startReading()
        var out = [Float]()
        while let sb = output.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            let len = CMBlockBufferGetDataLength(bb)
            var buf = [Float](repeating: 0, count: len / 4)
            CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: &buf)
            out.append(contentsOf: buf)
            CMSampleBufferInvalidate(sb)
        }
        return out
    }

    /// Real time of the loudest 100 ms window in a rendered track.
    private func peakTime(_ samples: [Float]) -> Double {
        let win = Int(Self.rate * 0.1)
        var bestE = -1.0, bestStart = 0, acc = 0.0, accStart = 0, frame = 0
        for v in samples {
            acc += Double(v) * Double(v)
            frame += 1
            if frame - accStart >= win {
                if acc > bestE { bestE = acc; bestStart = accStart }
                acc = 0; accStart = frame
            }
        }
        return Double(bestStart) / Self.rate
    }

    /// Dominant frequency (FFT peak) of a steady-tone rendering, ignoring the
    /// scale-discontinuity edges.
    private func peakHz(_ samples: [Float]) -> Double {
        guard samples.count > 8192 else { return 0 }
        let n = 1 << Int(floor(log2(Double(min(samples.count - 2048, 65536)))))
        let mid = samples.count / 2
        var w = [Float](repeating: 0, count: n)
        var win = [Float](repeating: 0, count: n)
        vDSP_hann_window(&win, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        for i in 0..<n { w[i] = samples[mid - n / 2 + i] * win[i] }
        let log2n = vDSP_Length(log2(Double(n)))
        let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        defer { vDSP_destroy_fftsetup(setup) }
        var real = w, imag = [Float](repeating: 0, count: n)
        var mag = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var sp = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                w.withUnsafeBytes {
                    vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &sp, 1, vDSP_Length(n / 2))
                }
                vDSP_fft_zrip(setup, &sp, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&sp, 1, &mag, 1, vDSP_Length(n / 2))
            }
        }
        var mv: Float = 0, mk = 0
        for k in 1..<(n / 2) where mag[k] > mv { mv = mag[k]; mk = k }
        return Double(mk) * Self.rate / Double(n)
    }

    /// One end-to-end render of a single drifted-part meeting through the real
    /// builder. `driftMic` selects the polarity: true → mic drifted (mic file
    /// dilated), false → system drifted.
    private func renderDriftedPart(driftMic: Bool) async throws -> (
        sysPeakTime: Double, micPeakTime: Double,
        driftedToneHz: Double, unityToneHz: Double, driftedScale: Double
    ) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blaise-render-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let wallSpan = 100.0
        let drift = 48000.0 / 44100.0  // ≈ 1.0886, the field converter ratio
        // Tones: both tracks carry a TRUE 300 Hz tone in real life. The drifted
        // file, written at the drifted clock, stores it shifted by 1/drift so
        // that scaleTimeRange+varispeed must restore 300 Hz. We synthesize the
        // drifted file's ON-DISK tone at trueHz / drift (its samples already
        // carry the baked pitch error), and add a 440 Hz burst at real t=50 on
        // each track to measure sync.
        let trueHz = 300.0
        let driftedOnDiskHz = trueHz / drift  // what the dilated file contains
        let sysURL = dir.appendingPathComponent("audio.m4a.wav")
        let micURL = dir.appendingPathComponent("audio_mic.m4a.wav")

        // Burst test files (sync). Drifted track file is `wallSpan * drift` long
        // with its burst at file position 50*drift; unity track is wallSpan with
        // its burst at 50.
        let driftURL = driftMic ? micURL : sysURL
        let unityURL = driftMic ? sysURL : micURL
        try writeBurstWAV(at: unityURL, seconds: wallSpan, burstAt: 50.0)
        try writeBurstWAV(at: driftURL, seconds: wallSpan * drift, burstAt: 50.0 * drift)

        let durations = [
            sysURL: driftMic ? wallSpan : wallSpan * drift,
            micURL: driftMic ? wallSpan * drift : wallSpan,
        ]
        let parts = [
            CaptureStitcher.PlannedPart(
                index: 1, offsetMs: 0, wallSpanMs: Int64(wallSpan * 1000),
                systemM4A: sysURL, micM4A: micURL)
        ]
        let placements = CaptureStitcher.playbackPlacements(parts: parts, durations: durations)
        #expect(CaptureStitcher.playbackScalingTrustworthy(placements: placements))

        // Sync render (burst files) through the REAL builder.
        let built = await AudioPlayerView.composition(for: placements, durations: durations)
        let comp = built.asset as! AVMutableComposition
        let tracks = comp.tracks(withMediaType: .audio)
        #expect(tracks.count == 2)
        // Track order follows placement order: system first, then mic.
        let sysPeak = peakTime(try renderTrack(comp, mix: built.audioMix, track: tracks[0]))
        let micPeak = peakTime(try renderTrack(comp, mix: built.audioMix, track: tracks[1]))

        // Pitch render: rewrite the SAME files with steady tones (drifted file
        // at the on-disk-shifted frequency), rebuild, and measure the rendered
        // tone of each track.
        try writeToneWAV(at: unityURL, seconds: wallSpan, toneHz: trueHz)
        try writeToneWAV(at: driftURL, seconds: wallSpan * drift, toneHz: driftedOnDiskHz)
        let builtT = await AudioPlayerView.composition(for: placements, durations: durations)
        let compT = builtT.asset as! AVMutableComposition
        let tracksT = compT.tracks(withMediaType: .audio)
        let sysHz = peakHz(try renderTrack(compT, mix: builtT.audioMix, track: tracksT[0]))
        let micHz = peakHz(try renderTrack(compT, mix: builtT.audioMix, track: tracksT[1]))
        let driftedHz = driftMic ? micHz : sysHz
        let unityHz = driftMic ? sysHz : micHz
        let driftedScale = driftMic
            ? wallSpan / (wallSpan * drift) : wallSpan / (wallSpan * drift)
        return (sysPeak, micPeak, driftedHz, unityHz, driftedScale)
    }

    @Test("mic-drifted: both tracks sync to real time AND the drifted track's pitch is corrected")
    func micDriftedSyncAndPitch() async throws {
        let r = try await renderDriftedPart(driftMic: true)
        // Sync: both bursts at real t≈50 (≤0.7 s window granularity).
        #expect(abs(r.sysPeakTime - 50.0) < 0.7)
        #expect(abs(r.micPeakTime - 50.0) < 0.7)
        #expect(abs(r.micPeakTime - r.sysPeakTime) < 0.7)
        // Pitch: the unity (system) tone renders at true 300 Hz; the drifted
        // (mic) tone, varispeed-restored, also lands at ≈300 Hz — within 1% of
        // true and FAR from the uncorrected on-disk 300/1.0886 ≈ 275.6 Hz.
        #expect(abs(r.unityToneHz - 300.0) < 6.0)
        #expect(abs(r.driftedToneHz - 300.0) / 300.0 < 0.01)  // ≤1% of true
        #expect(abs(r.driftedToneHz - 275.6) > 10.0)  // genuinely corrected, not the squeak
    }

    @Test("system-drifted (L-1 opposite polarity): sync AND pitch corrected on the system track")
    func systemDriftedSyncAndPitch() async throws {
        let r = try await renderDriftedPart(driftMic: false)
        #expect(abs(r.sysPeakTime - 50.0) < 0.7)
        #expect(abs(r.micPeakTime - 50.0) < 0.7)
        #expect(abs(r.micPeakTime - r.sysPeakTime) < 0.7)
        #expect(abs(r.unityToneHz - 300.0) < 6.0)
        #expect(abs(r.driftedToneHz - 300.0) / 300.0 < 0.01)
        #expect(abs(r.driftedToneHz - 275.6) > 10.0)
    }

    @Test("the builder assigns .varispeed to the drifted track and not to the unity track")
    func varispeedOnlyOnDriftedTrack() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blaise-algo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wallSpan = 100.0, drift = 48000.0 / 44100.0
        let sysURL = dir.appendingPathComponent("audio.m4a.wav")
        let micURL = dir.appendingPathComponent("audio_mic.m4a.wav")
        // Mic drifted.
        try writeBurstWAV(at: sysURL, seconds: wallSpan, burstAt: 10)
        try writeBurstWAV(at: micURL, seconds: wallSpan * drift, burstAt: 10)
        let durations = [sysURL: wallSpan, micURL: wallSpan * drift]
        let parts = [
            CaptureStitcher.PlannedPart(
                index: 1, offsetMs: 0, wallSpanMs: Int64(wallSpan * 1000),
                systemM4A: sysURL, micM4A: micURL)
        ]
        let placements = CaptureStitcher.playbackPlacements(parts: parts, durations: durations)
        let built = await AudioPlayerView.composition(for: placements, durations: durations)
        let comp = built.asset as! AVMutableComposition
        let tracks = comp.tracks(withMediaType: .audio)
        let mix = try #require(built.audioMix)
        // Map trackID → algorithm from the returned mix parameters.
        var algo: [CMPersistentTrackID: AVAudioTimePitchAlgorithm?] = [:]
        for p in mix.inputParameters { algo[p.trackID] = p.audioTimePitchAlgorithm }
        // tracks[0] = system (unity), tracks[1] = mic (drifted).
        // The mic track must carry .varispeed; the system track must NOT (it is
        // either absent from the mix or present only for attenuation with a nil
        // algorithm, which falls back to the item's .spectral).
        #expect(algo[tracks[1].trackID] ?? nil == .varispeed)
        #expect((algo[tracks[0].trackID] ?? nil) != .varispeed)
    }
}
