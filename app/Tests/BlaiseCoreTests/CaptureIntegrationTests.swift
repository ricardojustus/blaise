import AVFoundation
import Foundation
import Testing

@testable import BlaiseCore

// C11 AC2: the REAL capture integration test — gated on BLAISE_TEST_CAPTURE=1
// because starting an aggregate-with-tap device requires the TCC grants
// (Microphone + System Audio Recording Only). Until the Human Touchpoint
// (docs/touchpoint_capture.md) grants them, this is implemented-not-run and
// records a skip per the C3 skip protocol. NEVER run it blind: an ungranted
// run fires the TCC prompts.
//
// What it validates when run:
// 1. 30 s real capture (a 440 Hz fixture WAV played through the default
//    output), stop → both CAFs grew → encode produced two playable m4as →
//    AND a tone-energy discrimination of the IOProc buffer order (Goertzel
//    over the decoded PCM). Probe-confirmed runtime facts (real granted
//    run, 10/06/2026, during the C11 audit fix round): audio played by a
//    DESCENDANT of the capturing process (afplay spawned here) is excluded
//    from the process tap along with the capturing process itself — the
//    tone therefore reaches ONLY the microphone, acoustically, through the
//    speakers. So the discriminating assertion is: tone-band energy on the
//    MIC m4a must exceed the SYSTEM m4a's by > 5× (measured ~7000× on the
//    probe run: mic 8.4e-5 vs system 1.2e-8) and clear an absolute floor.
//    A swapped buffer order puts the acoustic tone on the "system" file
//    and fails both. REQUIREMENTS for the run: built-in speakers (not
//    headphones) at moderate volume, so the mic can hear the fixture; no
//    OTHER system audio playing (third-party audio carrying ~440 Hz energy
//    lands on the system track and can false-FAIL the ratio — the safe
//    direction: a false fail prompts a re-run in quiet conditions, never a
//    false pass). If the assertion fails in quiet conditions, the
//    mic/system track assignment in CaptureSession.Graph is wrong — do NOT
//    record real meetings until resolved.
// 2. kill -9 mid-capture (CrashRunner `capture` mode child process) → the
//    crash-safe CAFs decode as-is, and the startup sweep rescues them
//    (encode + verify + attach + auto-kick).
// Runtime assumptions this validates: the mono-tap behavior (confirmed
// delivering real mono system audio on the probe run) and the IOProc
// buffer order (confirmed: streams [0..<micStreamCount] are the input
// device's — the track lacking the speaker-emitted tone cannot be a
// microphone).

private let captureGateEnv = "BLAISE_TEST_CAPTURE"

@Suite("C11 capture integration (gated)", .serialized)
struct CaptureIntegrationTests {
    @Test("30 s real capture + stop-encode", .timeLimit(.minutes(5)))
    func realCapture() async throws {
        guard ProcessInfo.processInfo.environment[captureGateEnv] == "1" else {
            recordTestSkip(
                "capture_integration_real",
                reason:
                    "BLAISE_TEST_CAPTURE != 1 — requires the Mic + System Audio Recording TCC grants; run at/after the Human Touchpoint (docs/touchpoint_capture.md)")
            return
        }

        let database = try makeDatabase()
        let kicks = Recorder<MeetingID>()
        let controller = RecordingController(
            database: database, engine: CaptureSession(), processKicker: { kicks.append($0) })
        let meeting = try await controller.start(source: .inPerson, title: "Capture integration")

        // Drive the system-audio side: play a generated fixture WAV through
        // the default output for the duration of the capture.
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-playback-\(UUID().uuidString).wav")
        try writeTestWAV(to: fixture, seconds: 35)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [fixture.path]
        try player.run()
        defer { if player.isRunning { player.terminate() } }

        try await Task.sleep(for: .seconds(30))

        // Both CAFs grew during capture.
        let paths = database.paths
        let systemCAF = paths.captureCAFURL(meeting.id, track: .system)
        let micCAF = paths.captureCAFURL(meeting.id, track: .mic)
        for caf in [systemCAF, micCAF] {
            let size =
                (try? FileManager.default.attributesOfItem(atPath: caf.path))?[.size] as? Int ?? 0
            #expect(size > 100_000, "capture CAF did not grow: \(caf.lastPathComponent)")
        }

        _ = try await controller.stop()
        if player.isRunning { player.terminate() }

        // Encode produced two playable m4as (≥ ~25 s).
        for url in [paths.audioURL(meeting.id), paths.audioMicURL(meeting.id)] {
            let duration = try AudioTranscoder.duration(of: url)
            #expect(duration >= 25, "\(url.lastPathComponent) too short: \(duration) s")
        }
        #expect(!FileManager.default.fileExists(atPath: systemCAF.path))
        #expect(!FileManager.default.fileExists(atPath: micCAF.path))

        // Buffer-order discrimination (see the header for the probe-
        // confirmed mechanics): the fixture is played by OUR descendant
        // process, which the tap excludes — the tone reaches only the MIC,
        // acoustically. Any microphone signal must carry the speaker-
        // emitted tone; the track WITHOUT it cannot be the mic. A swapped
        // IOProc buffer order lands the acoustic tone on the "system" file
        // and fails both assertions. Requires speakers (not headphones) at
        // audible volume.
        let systemTone = try ToneProbe.bandPower(
            url: paths.audioURL(meeting.id), frequency: 440)
        let micTone = try ToneProbe.bandPower(
            url: paths.audioMicURL(meeting.id), frequency: 440)
        #expect(
            micTone > 1e-6,
            "mic track carries no 440 Hz tone energy (\(micTone)) — was the fixture audible through SPEAKERS at this volume?")
        #expect(
            micTone > 5 * systemTone,
            "mic/system tone-band energy \(micTone)/\(systemTone): the IOProc buffer order is wrong — DO NOT record real meetings until resolved")
    }

    @Test("kill -9 mid-capture → decodable CAFs, sweep rescues + auto-kicks", .timeLimit(.minutes(5)))
    func killMidCapture() async throws {
        guard ProcessInfo.processInfo.environment[captureGateEnv] == "1" else {
            recordTestSkip(
                "capture_integration_kill",
                reason:
                    "BLAISE_TEST_CAPTURE != 1 — requires the Mic + System Audio Recording TCC grants; run at/after the Human Touchpoint (docs/touchpoint_capture.md)")
            return
        }

        // Child-process harness (like C7's crash harness): CrashRunner's
        // `capture` mode records with the REAL CaptureSession until killed.
        let runnerPath =
            ProcessInfo.processInfo.environment["BLAISE_CRASHRUNNER_BIN"]
            ?? VocabFixtures.repoRoot.appendingPathComponent("app/.build/debug/CrashRunner").path
        try #require(
            FileManager.default.isExecutableFile(atPath: runnerPath),
            "CrashRunner binary not found (build first, or set BLAISE_CRASHRUNNER_BIN)")

        let dataRoot = try makeTempRoot()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: runnerPath)
        child.arguments = ["capture", dataRoot.path]
        let stdout = Pipe()
        child.standardOutput = stdout
        try child.run()

        // Capture ~10 s of real audio in the child, then kill -9.
        try await Task.sleep(for: .seconds(10))
        kill(child.processIdentifier, SIGKILL)
        child.waitUntilExit()

        let output = String(
            decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let meetingID = try #require(
            output.split(separator: "\n").first(where: { $0.hasPrefix("CAPTURING ") })?
                .replacingOccurrences(of: "CAPTURING ", with: ""))

        // Opening the DB runs the C1 startup sweeps (recording → failed) —
        // that IS the relaunch behavior.
        let database = try BlaiseDatabase(rootURL: dataRoot)
        let paths = database.paths

        // The crash-safe pattern: the un-finalized CAFs decode as-is.
        for track in CaptureTrack.allCases {
            let caf = paths.captureCAFURL(meetingID, track: track)
            #expect(FileManager.default.fileExists(atPath: caf.path))
            let file = try AVAudioFile(forReading: caf)
            #expect(file.length > 0, "\(caf.lastPathComponent) has no decodable frames")
        }

        // The startup sweep rescues + auto-kicks.
        let kicks = Recorder<MeetingID>()
        let results = await CaptureRecovery.sweepOrphanCAFs(database: database) { kicks.append($0) }
        #expect(results.contains { $0.meetingID == meetingID && $0.kicked })
        #expect(kicks.values == [meetingID])
        for track in CaptureTrack.allCases {
            #expect(
                FileManager.default.fileExists(
                    atPath: track.retainedURL(paths, meetingID: meetingID).path))
            #expect(
                !FileManager.default.fileExists(
                    atPath: paths.captureCAFURL(meetingID, track: track).path))
        }
    }

    // G9 AC4: kill -9 around a PAUSE with the REAL capture engine. The three
    // halves (post-commit kill → paused + encoded + NO kick; pre-commit kill →
    // today's interrupted semantics; resume-window kill → paused + new-part
    // residue + no process) are asserted at the seam level in
    // PauseResumeTests (the injected midTransactionHook + DB sweep), which is
    // the sanctioned approach for the transaction/state halves (kickoff;
    // audit L-13). This gated test is the real-hardware end-to-end pin: it
    // needs the Mic + System Audio TCC grants and a CrashRunner `pause` mode,
    // so without the grant it records a skip honestly rather than running
    // blind.
    @Test("G9 AC4: kill around pause with real capture (gated)", .timeLimit(.minutes(5)))
    func killAroundPause() async throws {
        guard ProcessInfo.processInfo.environment[captureGateEnv] == "1" else {
            recordTestSkip(
                "capture_integration_pause_kill",
                reason:
                    "BLAISE_TEST_CAPTURE != 1 — requires the Mic + System Audio Recording TCC grants AND a CrashRunner pause mode; the transaction/state halves are pinned at the seam in PauseResumeTests (post-commit-kill→paused+encoded+no-kick, resume-window-kill→paused+residue+no-process, atomic-rollback). Run at/after the Human Touchpoint.")
            return
        }
        // When the gate is on, the post-commit half is mechanically the same
        // sweep path the killMidCapture test pins PLUS the §2 paused-kick gate
        // (the sweep withholds the kick for a `paused` row) — both proven in
        // PauseResumeTests at the unit level. A full real-hardware harness for
        // the pause/resume kill points would extend CrashRunner; left as the
        // honest skip above until the Touchpoint provides the grants.
        recordTestSkip(
            "capture_integration_pause_kill",
            reason:
                "real-hardware pause-kill harness (CrashRunner pause mode) not yet built; seam-level halves pinned in PauseResumeTests")
    }
}

// UNGATED sanity check of the probe itself (no TCC: pure files), so the
// gated test's discriminating assertion is known-good before the Touchpoint:
// a 440 Hz m4a must dominate a silent m4a by far more than the 5× gate.
@Suite("C11 tone probe")
struct ToneProbeTests {
    @Test("Goertzel band power separates a 440 Hz tone from silence through the real encoder")
    func discriminates() async throws {
        let root = try makeTempRoot()
        let toneWAV = root.appendingPathComponent("tone.wav")
        try writeTestWAV(to: toneWAV, seconds: 3)  // 440 Hz sine (the fixture generator)
        let silentWAV = try writeTestWAV(at: root.appendingPathComponent("silent.wav"), seconds: 3)
        let toneM4A = root.appendingPathComponent("tone.m4a")
        let silentM4A = root.appendingPathComponent("silent.m4a")
        try AudioTranscoder.encodeToM4A(wav: toneWAV, destination: toneM4A)
        try AudioTranscoder.encodeToM4A(wav: silentWAV, destination: silentM4A)

        let tone = try ToneProbe.bandPower(url: toneM4A, frequency: 440)
        let silence = try ToneProbe.bandPower(url: silentM4A, frequency: 440)
        #expect(tone > 1e-6)
        #expect(tone > 100 * max(silence, 1e-12))
        // Off-band: the tone file carries little energy at 1 kHz.
        let offBand = try ToneProbe.bandPower(url: toneM4A, frequency: 1000)
        #expect(tone > 100 * max(offBand, 1e-12))
    }
}

// MARK: - Tone-band energy probe (Goertzel)

/// Decodes an audio file to mono float PCM and measures the mean power in a
/// narrow band around `frequency` via the Goertzel algorithm, normalized by
/// window size — comparable across files of similar length.
enum ToneProbe {
    static func bandPower(url: URL, frequency: Double) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return 0 }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        let sampleRate = format.sampleRate

        // Goertzel over 1 s windows; average the per-window band power so a
        // partially-silent file still reports honest energy.
        let window = Int(sampleRate)
        guard window > 0, n >= window else { return goertzel(channel, 0, n, frequency, sampleRate) }
        var total = 0.0
        var windows = 0
        var start = 0
        while start + window <= n {
            total += goertzel(channel, start, window, frequency, sampleRate)
            windows += 1
            start += window
        }
        return total / Double(windows)
    }

    /// Classic Goertzel: power at `frequency` over `count` samples starting
    /// at `offset`, normalized by count² (mean-square of the band).
    private static func goertzel(
        _ samples: UnsafePointer<Float>, _ offset: Int, _ count: Int,
        _ frequency: Double, _ sampleRate: Double
    ) -> Double {
        let omega = 2.0 * Double.pi * frequency / sampleRate
        let coefficient = 2.0 * cos(omega)
        var s0 = 0.0
        var s1 = 0.0
        var s2 = 0.0
        for index in offset ..< (offset + count) {
            s0 = Double(samples[index]) + coefficient * s1 - s2
            s2 = s1
            s1 = s0
        }
        let power = s1 * s1 + s2 * s2 - coefficient * s1 * s2
        return power / (Double(count) * Double(count))
    }
}
