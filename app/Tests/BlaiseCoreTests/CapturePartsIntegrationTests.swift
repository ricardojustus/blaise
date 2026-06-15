import AVFoundation
import Foundation
import Testing

@testable import BlaiseCore

// C14 AC3: the gated multi-part capture test — REAL capture, simulated
// auto-stop into grace, resume, finalize. Gated on BLAISE_TEST_CAPTURE=1
// (same TCC grants as the C11 gated test, no new ones); records a skip per
// the C3 protocol otherwise. NEVER run blind: an ungranted run fires the
// TCC prompts.

private let captureGateEnv = "BLAISE_TEST_CAPTURE"

@Suite("C14 multi-part capture integration (gated)", .serialized)
struct CapturePartsIntegrationTests {
    @Test("~10 s, auto-stop → grace, resume, ~10 s, finalize: two parts, four m4as, stitched wall span", .timeLimit(.minutes(5)))
    func multiPartCaptureResumeStitch() async throws {
        guard ProcessInfo.processInfo.environment[captureGateEnv] == "1" else {
            recordTestSkip(
                "capture_parts_integration",
                reason:
                    "BLAISE_TEST_CAPTURE != 1 — requires the Mic + System Audio Recording TCC grants; run at/after the Human Touchpoint (docs/touchpoint_capture.md)")
            return
        }

        let database = try makeDatabase()
        let kicks = Recorder<MeetingID>()
        let controller = RecordingController(
            database: database, engine: CaptureSession(), processKicker: { kicks.append($0) })

        // Part 1: ~10 s real capture, then the SIMULATED auto-stop (the
        // tracker's debounced end) — kick suppressed, grace pending.
        let meeting = try await controller.start(
            source: .meet, title: "C14 parts integration", meetingCode: "abc-defg-hij")
        try await Task.sleep(for: .seconds(10))
        let stop1 = try await controller.autoStop(finalizeImmediately: false)
        #expect(stop1.recoverableAudio)
        #expect(kicks.values.isEmpty, "the processing kick moves to grace expiry")
        let fm = FileManager.default
        let paths = database.paths
        #expect(fm.fileExists(atPath: paths.audioURL(meeting.id).path))
        #expect(fm.fileExists(atPath: paths.audioMicURL(meeting.id).path))

        // Grace: rejoin → resume as part 2, ~10 s, then finalize (manual
        // stop = the grace-expiry equivalent with an immediate kick).
        try await Task.sleep(for: .seconds(2))
        _ = try await controller.resume(meetingID: meeting.id)
        try await Task.sleep(for: .seconds(10))
        _ = try await controller.stop()

        // Two parts on disk, all four m4as verified (decodable, sane
        // durations).
        let expected = [
            paths.audioURL(meeting.id), paths.audioMicURL(meeting.id),
            paths.audioURL(meeting.id, part: 2), paths.audioMicURL(meeting.id, part: 2),
        ]
        for m4a in expected {
            #expect(fm.fileExists(atPath: m4a.path), "\(m4a.lastPathComponent) missing")
            let duration = try AudioTranscoder.duration(of: m4a)
            #expect(duration > 8, "\(m4a.lastPathComponent) too short: \(duration)")
        }
        for part in [1, 2] {
            for track in CaptureTrack.allCases {
                #expect(
                    !fm.fileExists(
                        atPath: paths.captureCAFURL(meeting.id, track: track, part: part).path),
                    "CAF released after verified encode")
            }
        }
        let rows = try await CaptureParts.parts(database, meetingID: meeting.id)
        #expect(rows.map(\.partIndex) == [1, 2])
        #expect(rows.allSatisfy { $0.endedAtMs != nil })

        // Stitch: per-track WAV duration ≈ wall span (gap included).
        let stored = try #require(try await MeetingRepository(database: database).fetch(meeting.id))
        let wallSpan = try #require(stored.endedAt).timeIntervalSince(stored.startedAt)
        let tempSystem = fm.temporaryDirectory.appendingPathComponent("c14-int-sys-\(UUID()).wav")
        let tempMic = fm.temporaryDirectory.appendingPathComponent("c14-int-mic-\(UUID()).wav")
        defer { [tempSystem, tempMic].forEach { try? fm.removeItem(at: $0) } }
        let outcome = try await CaptureStitcher.prepareTracks(
            database: database, meeting: stored,
            tempSystemWAV: tempSystem, tempMicWAV: tempMic,
            tempDirectory: fm.temporaryDirectory)
        #expect(outcome.partCount == 2)
        #expect(outcome.complete)
        for wav in [tempSystem, tempMic] {
            let duration = try WAVHeader.read(at: wav).duration
            #expect(abs(duration - wallSpan) < 1.5, "stitched \(wav.lastPathComponent): \(duration) vs wall \(wallSpan)")
        }
        #expect(outcome.systemGaps.count == 1, "one structural gap between the parts")

        // One meeting, one pipeline run (the final stop's kick).
        #expect(await waitUntil { kicks.values == [meeting.id] })
        #expect(try database.count("meeting") == 1)
    }
}
