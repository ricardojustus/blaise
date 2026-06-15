import AVFoundation
import Foundation
import GRDB
import Synchronization
import Testing

@testable import BlaiseCore

// C14 AC1: RecordingController.resume + per-part capture mechanics — part
// rows (row before session, closed at stop, row-follows-files deletion),
// part-suffixed retained artifacts, endedAt clear/set semantics, empty-part
// rules (part 1 → failed; part n ≥ 2 → alarm but status stays recording),
// the part-aware finalize/orphan sweep, and quit-during-grace recovery via
// the unchanged sweep → redispatchInterrupted path.

/// Parts-aware mock engine: plants CAF bytes at whatever URLs the
/// controller passes (part-suffixed for part n ≥ 2).
private final class PartsMockEngine: AudioCapturing, @unchecked Sendable {
    enum PlantMode {
        case real  // 1 s of real LPCM frames per track
        case emptyStubs  // header-only, zero frames
        case none
    }

    struct State {
        var plantModes: [PlantMode] = []  // consumed per start call; last repeats
        var startError: Error?
        var startedURLs: [(system: URL, mic: URL)] = []
        var onStart: (@Sendable () -> Void)?
        var startCalls = 0
    }

    let state = Mutex(State())

    @discardableResult
    func start(
        systemCAF: URL, micCAF: URL,
        onEvent: @escaping @Sendable (CaptureEngineEvent) -> Void
    ) async throws -> CaptureStartInfo {
        let (mode, error, hook) = state.withLock { s -> (PlantMode, Error?, (@Sendable () -> Void)?) in
            let mode = s.startCalls < s.plantModes.count ? s.plantModes[s.startCalls] : (s.plantModes.last ?? .real)
            s.startCalls += 1
            s.startedURLs.append((systemCAF, micCAF))
            return (mode, s.startError, s.onStart)
        }
        hook?()
        switch mode {
        case .real, .emptyStubs:
            for url in [systemCAF, micCAF] {
                let writer = try CaptureCAFWriter(url: url)
                if case .real = mode {
                    let buffer = AVAudioPCMBuffer(
                        pcmFormat: CaptureCAFWriter.format, frameCapacity: 16_000)!
                    buffer.frameLength = 16_000
                    try writer.write(buffer)
                }
                writer.close()
            }
        case .none:
            break
        }
        if let error { throw error }
        return CaptureStartInfo(micStreams: 1)
    }

    func stop() async {}
}

private struct PartsHarness {
    let database: BlaiseDatabase
    let engine: PartsMockEngine
    let controller: RecordingController
    let kicks: Recorder<MeetingID>

    func partRows(_ meetingID: MeetingID) async throws -> [CapturePartRecord] {
        try await CaptureParts.parts(database, meetingID: meetingID)
    }

    func meeting(_ id: MeetingID) async throws -> Meeting {
        try #require(try await MeetingRepository(database: database).fetch(id))
    }
}

private func makePartsHarness() throws -> PartsHarness {
    let database = try makeDatabase()
    let engine = PartsMockEngine()
    let kicks = Recorder<MeetingID>()
    let controller = RecordingController(
        database: database, engine: engine,
        processKicker: { kicks.append($0) },
        now: { Date() })
    return PartsHarness(database: database, engine: engine, controller: controller, kicks: kicks)
}

@Suite("C14 controller: resume + part mechanics")
struct CapturePartsTests {
    @Test("start inserts the part-1 row; stop closes it and sets endedAt")
    func partOneRowLifecycle() async throws {
        let h = try makePartsHarness()
        let meeting = try await h.controller.start(source: .meet, meetingCode: "abc-defg-hij")
        var rows = try await h.partRows(meeting.id)
        #expect(rows.map(\.partIndex) == [1])
        #expect(rows[0].endedAtMs == nil)
        _ = try await h.controller.stop()
        rows = try await h.partRows(meeting.id)
        #expect(rows[0].endedAtMs != nil)
        #expect(try await h.meeting(meeting.id).endedAt != nil)
    }

    @Test("resume: endedAt cleared, part-2 row before session, part-2 CAF paths, live session re-registered")
    func resumeMechanics() async throws {
        let h = try makePartsHarness()
        let meeting = try await h.controller.start(source: .meet, meetingCode: "abc-defg-hij")
        _ = try await h.controller.autoStop(finalizeImmediately: false)
        #expect(try await h.meeting(meeting.id).endedAt != nil)
        #expect(h.kicks.values.isEmpty, "the processing kick moves to grace expiry")
        // Status stays `recording` during grace (capture lifecycle not
        // finalized) — the launch machinery treats it as live state.
        #expect(try await h.meeting(meeting.id).status == .recording)

        // Row-before-session: at engine-start time the part-2 row exists.
        let database = h.database
        let meetingID = meeting.id
        let rowAtStart = Recorder<Int>()
        h.engine.state.withLock { state in
            state.onStart = {
                let count =
                    (try? database.pool.read { db in
                        try Int.fetchOne(
                            db,
                            sql: "SELECT COUNT(*) FROM meeting_capture_part WHERE meeting_id = ?",
                            arguments: [meetingID]) ?? 0
                    }) ?? -1
                rowAtStart.append(count)
            }
        }
        let resumed = try await h.controller.resume(meetingID: meeting.id)
        #expect(resumed.endedAt == nil, "endedAt CLEARED at part start")
        #expect(try await h.meeting(meeting.id).endedAt == nil)
        #expect(rowAtStart.values == [2], "part row inserted BEFORE the capture session")

        let urls = h.engine.state.withLock { $0.startedURLs }
        #expect(urls.count == 2)
        #expect(urls[1].system.lastPathComponent == "capture_system_2.caf")
        #expect(urls[1].mic.lastPathComponent == "capture_mic_2.caf")

        // Live session re-registered (live correlation resumes).
        let session = try #require(await h.controller.currentSession())
        #expect(session.meetingID == meeting.id)
        #expect(session.meetingCode == "abc-defg-hij")

        // Stop of part 2: SAME stop path with part-n paths.
        _ = try await h.controller.stop()
        let paths = h.database.paths
        #expect(FileManager.default.fileExists(atPath: paths.audioURL(meeting.id).path))
        #expect(FileManager.default.fileExists(atPath: paths.audioMicURL(meeting.id).path))
        #expect(FileManager.default.fileExists(atPath: paths.audioURL(meeting.id, part: 2).path))
        #expect(FileManager.default.fileExists(atPath: paths.audioMicURL(meeting.id, part: 2).path))
        #expect(!FileManager.default.fileExists(atPath: paths.captureCAFURL(meeting.id, track: .system, part: 2).path))
        let rows = try await h.partRows(meeting.id)
        #expect(rows.map(\.partIndex) == [1, 2])
        #expect(rows.allSatisfy { $0.endedAtMs != nil })
        #expect(try await h.meeting(meeting.id).endedAt != nil)
        #expect(await waitUntil { h.kicks.values == [meeting.id] })
    }

    @Test("resume refuses while a session is active")
    func resumeWhileActiveThrows() async throws {
        let h = try makePartsHarness()
        let meeting = try await h.controller.start(source: .meet, meetingCode: "abc-defg-hij")
        await #expect(throws: RecordingControllerError.self) {
            try await h.controller.resume(meetingID: meeting.id)
        }
    }

    @Test("empty part 1: failed status + loud alarm + never multi-part (no grace entry)")
    func emptyPartOneFails() async throws {
        let h = try makePartsHarness()
        h.engine.state.withLock { $0.plantModes = [.emptyStubs] }
        let meeting = try await h.controller.start(source: .meet, meetingCode: "abc-defg-hij")
        let outcome = try await h.controller.autoStop(finalizeImmediately: false)
        #expect(!outcome.recoverableAudio, "§4 entry condition: no grace without recoverable audio")
        let stored = try await h.meeting(meeting.id)
        #expect(stored.status == .failed)
        #expect(stored.lastProcessingError == "capture produced no recoverable audio")
        // Zero-frame CAFs removed (the C1 rule), no m4a → the row followed
        // its files.
        #expect(try await h.partRows(meeting.id).isEmpty)
        let paths = h.database.paths
        #expect(!FileManager.default.fileExists(atPath: paths.captureCAFURL(meeting.id, track: .system).path))
        #expect(!FileManager.default.fileExists(atPath: paths.audioURL(meeting.id).path))
        #expect(h.kicks.values.isEmpty)
    }

    @Test("empty part n ≥ 2 with surviving earlier parts: alarm raised, status STAYS recording")
    func emptyPartTwoKeepsRecording() async throws {
        let h = try makePartsHarness()
        h.engine.state.withLock { $0.plantModes = [.real, .emptyStubs] }
        let meeting = try await h.controller.start(source: .meet, meetingCode: "abc-defg-hij")
        _ = try await h.controller.autoStop(finalizeImmediately: false)
        _ = try await h.controller.resume(meetingID: meeting.id)

        let events = await h.controller.events()
        let collected = Recorder<RecordingEvent>()
        let collector = Task { for await event in events { collected.append(event) } }
        let outcome = try await h.controller.autoStop(finalizeImmediately: false)
        #expect(outcome.recoverableAudio, "part 1 survives — grace continues")
        let stored = try await h.meeting(meeting.id)
        #expect(stored.status == .recording, "never a failed write while ANY part has audio")
        let alarmed = await waitUntil {
            collected.values.contains {
                if case .stopped(meeting.id, let alarm, _) = $0 {
                    return alarm?.contains("part 2") == true
                }
                return false
            }
        }
        #expect(alarmed, "the existing loud alarm fires for the empty part")
        // The empty part-2 row followed its (provably gone) files.
        #expect(try await h.partRows(meeting.id).map(\.partIndex) == [1])
        #expect(h.kicks.values.isEmpty, "grace continues; survivors process at grace end")
        collector.cancel()
    }

    @Test("encode-FAILED part with retained CAF keeps its row (rescue stays possible)")
    func encodeFailedPartKeepsRow() async throws {
        let h = try makePartsHarness()
        h.engine.state.withLock { $0.plantModes = [.real, .none] }
        let meeting = try await h.controller.start(source: .meet, meetingCode: "abc-defg-hij")
        _ = try await h.controller.autoStop(finalizeImmediately: false)
        _ = try await h.controller.resume(meetingID: meeting.id)
        // Plant an UNREADABLE part-2 CAF (duration probe fails → encode
        // fails → CAF retained, hard floor 2).
        let paths = h.database.paths
        try Data("not a caf".utf8).write(
            to: paths.captureCAFURL(meeting.id, track: .system, part: 2))
        _ = try await h.controller.autoStop(finalizeImmediately: false)
        #expect(FileManager.default.fileExists(
            atPath: paths.captureCAFURL(meeting.id, track: .system, part: 2).path),
            "unreadable CAF retained")
        #expect(try await h.partRows(meeting.id).map(\.partIndex) == [1, 2],
            "row kept — the next launch's part-aware sweep can still rescue the encode")
        let stored = try await h.meeting(meeting.id)
        #expect(stored.processingNote?.contains("part 2") == true, "recovery note flags the part")
    }

    // G11 §3 (AC6): the C14 quit-during-grace pins are REPLACED by the durable-
    // grace recovery. A real grace now persists `grace_until_ms`; at relaunch
    // the interrupted-flip EXEMPTS that row (it is cleanly stopped-and-encoded
    // by construction) and durable-grace recovery decides per deadline.

    @Test("quit PAST the grace deadline: the row is exempted from the interrupted flip, then processed")
    func quitDuringGracePastDeadlineProcesses() async throws {
        let h = try makePartsHarness()
        let meeting = try await h.controller.start(source: .meet, meetingCode: "abc-defg-hij")
        _ = try await h.controller.autoStop(finalizeImmediately: false)
        #expect(try await h.meeting(meeting.id).status == .recording)
        // The tracker's persist seam wrote a grace deadline (here a PAST one).
        let pastMs = Int64(Date().addingTimeInterval(-60).timeIntervalSince1970 * 1000)
        await h.controller.persistGraceDeadline(meetingID: meeting.id, until: pastMs)

        // Quit + relaunch: reopening runs the DB sweep — the non-nil grace
        // column EXEMPTS the row from the interrupted flip (stays `recording`).
        let reopened = try BlaiseDatabase(rootURL: h.database.rootURL)
        let exempted = try #require(try await MeetingRepository(database: reopened).fetch(meeting.id))
        #expect(exempted.status == .recording, "exempted: NOT flipped to failed/interrupted")
        #expect(exempted.graceUntilMs == pastMs)

        // Durable-grace recovery: deadline past → clear the column, process now.
        let kicked = Recorder<MeetingID>()
        let recovered = await CaptureRecovery.recoverDurableGrace(
            database: reopened, kick: { kicked.append($0) }, reenterGrace: { _ in })
        #expect(recovered.map(\.meetingID) == [meeting.id])
        #expect(kicked.values == [meeting.id])
        #expect(try await MeetingRepository(database: reopened).fetch(meeting.id)?.graceUntilMs == nil,
            "the column is cleared before the kick")
    }

    @Test("quit BEFORE the grace deadline: exempted, then re-enters grace (not processed)")
    func quitDuringGraceFutureReentersGrace() async throws {
        let h = try makePartsHarness()
        let meeting = try await h.controller.start(source: .meet, meetingCode: "abc-defg-hij")
        _ = try await h.controller.autoStop(finalizeImmediately: false)
        let futureMs = Int64(Date().addingTimeInterval(300).timeIntervalSince1970 * 1000)
        await h.controller.persistGraceDeadline(meetingID: meeting.id, until: futureMs)

        let reopened = try BlaiseDatabase(rootURL: h.database.rootURL)
        #expect(try await MeetingRepository(database: reopened).fetch(meeting.id)?.status == .recording)

        let kicked = Recorder<MeetingID>()
        let reentered = Recorder<MeetingID>()
        let recovered = await CaptureRecovery.recoverDurableGrace(
            database: reopened, kick: { kicked.append($0) },
            reenterGrace: { reentered.append($0.meetingID) })
        #expect(recovered.map(\.meetingID) == [meeting.id])
        #expect(kicked.values.isEmpty, "future deadline → NOT processed")
        #expect(reentered.values == [meeting.id], "future deadline → re-enters grace")
        #expect(try await MeetingRepository(database: reopened).fetch(meeting.id)?.graceUntilMs == futureMs,
            "the column stays set until the re-armed grace exits")
    }

    @Test("a recording row with NO grace column is still flipped to interrupted (nil-column path intact)")
    func quitDuringRecordingNoGraceColumnStillFlips() async throws {
        let h = try makePartsHarness()
        let meeting = try await h.controller.start(source: .meet, meetingCode: "abc-defg-hij")
        _ = try await h.controller.autoStop(finalizeImmediately: false)
        // No persistGraceDeadline call: the column stays NULL.
        let reopened = try BlaiseDatabase(rootURL: h.database.rootURL)
        let swept = try #require(try await MeetingRepository(database: reopened).fetch(meeting.id))
        #expect(swept.status == .failed)
        #expect(swept.lastProcessingError == "interrupted")
        let kicked = Recorder<MeetingID>()
        let redispatched = await CaptureRecovery.redispatchInterrupted(
            database: reopened, kick: { kicked.append($0) })
        #expect(redispatched == [meeting.id], "part-1 audio.m4a keys the re-dispatch")
    }

    @Test("deletePartRowIfFilesGone: any surviving file (CAF or m4a) keeps the row")
    func rowFollowsFiles() async throws {
        let database = try makeDatabase()
        let meeting = makeMeeting()
        try await MeetingRepository(database: database).create(meeting)
        try database.paths.createMeetingDirectory(meeting.id)
        try await CaptureParts.insertPart(database, meetingID: meeting.id, partIndex: 2, startedAtMs: 1000)

        // A part m4a on disk → row kept.
        let m4a = database.paths.audioURL(meeting.id, part: 2)
        try Data([0x01]).write(to: m4a)
        #expect(await !CaptureParts.deletePartRowIfFilesGone(database, meetingID: meeting.id, partIndex: 2))
        try FileManager.default.removeItem(at: m4a)

        // A retained CAF → row kept.
        let caf = database.paths.captureCAFURL(meeting.id, track: .mic, part: 2)
        try Data([0x02]).write(to: caf)
        #expect(await !CaptureParts.deletePartRowIfFilesGone(database, meetingID: meeting.id, partIndex: 2))
        try FileManager.default.removeItem(at: caf)

        // Every file provably gone → row deleted.
        #expect(await CaptureParts.deletePartRowIfFilesGone(database, meetingID: meeting.id, partIndex: 2))
        #expect(try await CaptureParts.parts(database, meetingID: meeting.id).isEmpty)
    }

    @Test("nextPartIndex counts rows AND file residue (a deleted row never reuses an index)")
    func nextPartIndexResidue() async throws {
        let database = try makeDatabase()
        let meeting = makeMeeting()
        try await MeetingRepository(database: database).create(meeting)
        try database.paths.createMeetingDirectory(meeting.id)
        #expect(await CaptureParts.nextPartIndex(database, meetingID: meeting.id) == 2)
        try await CaptureParts.insertPart(database, meetingID: meeting.id, partIndex: 2, startedAtMs: 0)
        #expect(await CaptureParts.nextPartIndex(database, meetingID: meeting.id) == 3)
        // Residue file for part 5 with no row: never overwrite it.
        try Data([0x01]).write(to: database.paths.audioMicURL(meeting.id, part: 5))
        #expect(await CaptureParts.nextPartIndex(database, meetingID: meeting.id) == 6)
    }
}

@Suite("C14 part-aware finalize + orphan sweep")
struct PartAwareSweepTests {
    /// Plants a real 1 s CAF pair for one part of a meeting.
    private func plantCAFs(_ database: BlaiseDatabase, meetingID: MeetingID, part: Int) throws {
        for track in CaptureTrack.allCases {
            let writer = try CaptureCAFWriter(
                url: database.paths.captureCAFURL(meetingID, track: track, part: part))
            let buffer = AVAudioPCMBuffer(pcmFormat: CaptureCAFWriter.format, frameCapacity: 16_000)!
            buffer.frameLength = 16_000
            try writer.write(buffer)
            writer.close()
        }
    }

    @Test("finalizeTracks(part:) encodes into part-suffixed retained m4as")
    func partSuffixedFinalize() async throws {
        let database = try makeDatabase()
        let meeting = makeMeeting()
        try await MeetingRepository(database: database).create(meeting)
        try database.paths.createMeetingDirectory(meeting.id)
        try plantCAFs(database, meetingID: meeting.id, part: 3)
        let outcome = CaptureRecovery.finalizeTracks(
            paths: database.paths, meetingID: meeting.id, part: 3)
        #expect(outcome.bothTracks)
        #expect(FileManager.default.fileExists(
            atPath: database.paths.audioURL(meeting.id, part: 3).path))
        #expect(FileManager.default.fileExists(
            atPath: database.paths.audioMicURL(meeting.id, part: 3).path))
        #expect(!FileManager.default.fileExists(
            atPath: database.paths.captureCAFURL(meeting.id, track: .system, part: 3).path))
    }

    @Test("orphan sweep finds part-suffixed CAFs and auto-kicks (multi-part crash fixture)")
    func sweepFindsPartCAFs() async throws {
        let database = try makeDatabase()
        var meeting = makeMeeting(status: .failed)
        meeting.captured = true
        try await MeetingRepository(database: database).create(meeting)
        try database.paths.createMeetingDirectory(meeting.id)
        // Part 1 already encoded (clean stop); part 2's CAFs orphaned by a
        // crash mid-grace-rejoin.
        try plantCAFs(database, meetingID: meeting.id, part: 1)
        let part1 = CaptureRecovery.finalizeTracks(paths: database.paths, meetingID: meeting.id)
        #expect(part1.bothTracks)
        try plantCAFs(database, meetingID: meeting.id, part: 2)

        let kicked = Recorder<MeetingID>()
        let results = await CaptureRecovery.sweepOrphanCAFs(
            database: database, kick: { kicked.append($0) })
        #expect(results.map(\.meetingID) == [meeting.id])
        #expect(results.first?.kicked == true)
        #expect(kicked.values == [meeting.id])
        #expect(FileManager.default.fileExists(
            atPath: database.paths.audioURL(meeting.id, part: 2).path))
        #expect(!FileManager.default.fileExists(
            atPath: database.paths.captureCAFURL(meeting.id, track: .mic, part: 2).path))
    }

    @Test("live-session skip rule unchanged: a `recording` row's part CAFs are never touched")
    func sweepSkipsLiveSession() async throws {
        let database = try makeDatabase()
        let meeting = makeMeeting(status: .recording)
        try await MeetingRepository(database: database).create(meeting)
        try database.paths.createMeetingDirectory(meeting.id)
        try plantCAFs(database, meetingID: meeting.id, part: 2)
        let results = await CaptureRecovery.sweepOrphanCAFs(database: database, kick: { _ in })
        #expect(results.isEmpty)
        #expect(FileManager.default.fileExists(
            atPath: database.paths.captureCAFURL(meeting.id, track: .system, part: 2).path))
    }
}
