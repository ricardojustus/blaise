import AVFoundation
import Foundation
import Synchronization
import Testing

@testable import BlaiseCore

// G9 — Pause / Resume Recording. Covers the state-machine arcs (pause →
// paused, resume → recording, End-from-pause → processing), the single-
// transaction durability (AC3, via the controller's transactionHook seam),
// the sweep/dispatch gating (H-1), the universal refusal predicate (H-2/M-9),
// the accumulated timer, and the indicator priority order. The capture
// engine is mocked (plants real CAF bytes); no audio device, no TCC.

/// Mock engine reused from the controller tests' pattern: plants 1 s of valid
/// LPCM CAF per track on start so the encode path runs for real.
private final class PauseMockEngine: AudioCapturing, @unchecked Sendable {
    enum PlantMode { case real, emptyStubs, none }
    struct State {
        var startCalls = 0
        var stopCalls = 0
        var onEvent: (@Sendable (CaptureEngineEvent) -> Void)?
        var startError: Error?
        var plantMode: PlantMode = .real
        var micStreams = 1
    }
    let state = Mutex(State())

    @discardableResult
    func start(
        systemCAF: URL, micCAF: URL,
        onEvent: @escaping @Sendable (CaptureEngineEvent) -> Void
    ) async throws -> CaptureStartInfo {
        let (error, plant) = state.withLock { s -> (Error?, PlantMode) in
            s.startCalls += 1
            s.onEvent = onEvent
            return (s.startError, s.plantMode)
        }
        switch plant {
        case .real, .emptyStubs:
            for url in [systemCAF, micCAF] {
                let writer = try CaptureCAFWriter(url: url)
                if case .real = plant {
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
        return CaptureStartInfo(micStreams: state.withLock { $0.micStreams })
    }

    func stop() async { state.withLock { $0.stopCalls += 1 } }
    func emit(_ event: CaptureEngineEvent) {
        let h = state.withLock { $0.onEvent }
        h?(event)
    }
}

/// A simple async gate: the engine signals when it has entered start() and
/// parks until the test releases it — modeling the real engine's
/// hundreds-of-ms start window for the H-1 End/Resume race.
private final class Gate: @unchecked Sendable {
    private struct State {
        var entered = false
        var released = false
        var enteredWaiters: [CheckedContinuation<Void, Never>] = []
        var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())

    /// Called by the engine when it reaches the gate; resolves any test
    /// awaiting `waitUntilEntered`, then suspends until `release()`.
    func enterAndWait() async {
        let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.entered = true
            let w = s.enteredWaiters
            s.enteredWaiters = []
            return w
        }
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let releaseNow = state.withLock { s -> Bool in
                if s.released { return true }
                s.releaseWaiters.append(cont)
                return false
            }
            if releaseNow { cont.resume() }
        }
    }

    func waitUntilEntered() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let already = state.withLock { s -> Bool in
                if s.entered { return true }
                s.enteredWaiters.append(cont)
                return false
            }
            if already { cont.resume() }
        }
    }

    func release() {
        let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.released = true
            let w = s.releaseWaiters
            s.releaseWaiters = []
            return w
        }
        waiters.forEach { $0.resume() }
    }
}

/// An engine that plants real part CAFs, then parks inside start() on the gate
/// (the H-1 race window). `stop()` is counted (the lost-race teardown check).
private final class GatedPauseEngine: AudioCapturing, @unchecked Sendable {
    private let openGate: Gate
    private let stops = Mutex(0)
    init(openGate: Gate) { self.openGate = openGate }

    @discardableResult
    func start(
        systemCAF: URL, micCAF: URL,
        onEvent: @escaping @Sendable (CaptureEngineEvent) -> Void
    ) async throws -> CaptureStartInfo {
        for url in [systemCAF, micCAF] {
            let writer = try CaptureCAFWriter(url: url)
            let buffer = AVAudioPCMBuffer(pcmFormat: CaptureCAFWriter.format, frameCapacity: 16_000)!
            buffer.frameLength = 16_000
            try writer.write(buffer)
            writer.close()
        }
        await openGate.enterAndWait()  // park here — status still durably paused
        return CaptureStartInfo(micStreams: 1)
    }

    func stop() async { stops.withLock { $0 += 1 } }
    func stopCalls() -> Int { stops.withLock { $0 } }
}

private struct PauseHarness {
    let database: BlaiseDatabase
    let engine: PauseMockEngine
    let controller: RecordingController
    let kicks: Recorder<MeetingID>
}

private func makePauseHarness(
    transactionHook: (@Sendable () throws -> Void)? = nil
) throws -> PauseHarness {
    let database = try makeDatabase()
    let engine = PauseMockEngine()
    let kicks = Recorder<MeetingID>()
    let controller = RecordingController(
        database: database, engine: engine,
        processKicker: { kicks.append($0) },
        now: { Date() },  // wall clock so part durations are non-zero
        transactionHook: transactionHook)
    return PauseHarness(database: database, engine: engine, controller: controller, kicks: kicks)
}

private func status(_ database: BlaiseDatabase, _ id: MeetingID) async throws -> String {
    try await database.pool.read { db in
        try String.fetchOne(db, sql: "SELECT status FROM meeting WHERE id = ?", arguments: [id]) ?? ""
    }
}

private func partCount(_ database: BlaiseDatabase, _ id: MeetingID) async throws -> Int {
    try await database.pool.read { db in
        try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM meeting_capture_part WHERE meeting_id = ?",
            arguments: [id]) ?? -1
    }
}

@Suite("G9 pause / resume")
struct PauseResumeTests {

    // MARK: - AC1: state-machine arcs

    @Test("pause: finalizes the part, commits paused, releases the session, NO kick")
    func pauseArc() async throws {
        let harness = try makePauseHarness()
        let meeting = try await harness.controller.start(source: .meet)

        let paused = try await harness.controller.pause()
        #expect(paused.status == .paused)
        #expect(paused.endedAt != nil)
        // Durable status is paused.
        #expect(try await status(harness.database, meeting.id) == "paused")
        // Session released — the controller is responsive (but a new start is
        // refused while paused; verified separately).
        #expect(await harness.controller.currentSession() == nil)
        // The part encoded (floor 2): retained m4a exists, CAF released.
        let paths = harness.database.paths
        #expect(FileManager.default.fileExists(atPath: paths.audioURL(meeting.id).path))
        #expect(!FileManager.default.fileExists(atPath: paths.captureCAFURL(meeting.id, track: .system).path))
        // NO processing kick on pause.
        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.kicks.values.isEmpty)
    }

    @Test("resume from pause: opens a NEW part, commits recording, re-registers the session")
    func resumeArc() async throws {
        let harness = try makePauseHarness()
        let meeting = try await harness.controller.start(source: .meet)
        try await harness.controller.pause()
        #expect(try await partCount(harness.database, meeting.id) == 1)

        let resumed = try await harness.controller.resumePaused(meetingID: meeting.id)
        #expect(resumed.status == .recording)
        #expect(resumed.endedAt == nil)  // cleared on resume
        #expect(try await status(harness.database, meeting.id) == "recording")
        // A second part row exists (no new part overwrites part 1).
        #expect(try await partCount(harness.database, meeting.id) == 2)
        let session = try #require(await harness.controller.currentSession())
        #expect(session.meetingID == meeting.id)
    }

    @Test("unbounded pause/resume cycles: each resume opens the next part")
    func pauseResumeCycles() async throws {
        let harness = try makePauseHarness()
        let meeting = try await harness.controller.start(source: .meet)
        for cycle in 0..<3 {
            try await harness.controller.pause()
            #expect(try await status(harness.database, meeting.id) == "paused")
            try await harness.controller.resumePaused(meetingID: meeting.id)
            #expect(try await status(harness.database, meeting.id) == "recording")
            // After cycle n: parts = n+2 (part 1 + one new part per resume).
            #expect(try await partCount(harness.database, meeting.id) == cycle + 2)
        }
    }

    @Test("End-from-pause: flips paused→processing FIRST, then kicks; no new part")
    func endFromPause() async throws {
        let harness = try makePauseHarness()
        let meeting = try await harness.controller.start(source: .meet)
        try await harness.controller.pause()
        let partsBefore = try await partCount(harness.database, meeting.id)

        let ended = try await harness.controller.endPaused(meetingID: meeting.id)
        #expect(ended.status == .processing)
        // The status flipped to processing (no longer paused).
        #expect(try await status(harness.database, meeting.id) == "processing")
        // No new part was opened.
        #expect(try await partCount(harness.database, meeting.id) == partsBefore)
        // The kick fired (the normal finalize→processing flow).
        #expect(await waitUntil { harness.kicks.values == [meeting.id] })
    }

    @Test("End-from-pause: endedAt is the last part's end (set at pause), unchanged by End")
    func endFromPauseEndedAt() async throws {
        let harness = try makePauseHarness()
        let meeting = try await harness.controller.start(source: .meet)
        try await harness.controller.pause()
        // The durable endedAt set at pause.
        let atPause = try #require(
            try await MeetingRepository(database: harness.database).fetch(meeting.id)).endedAt
        #expect(atPause != nil)
        try await harness.controller.endPaused(meetingID: meeting.id)
        // End-from-pause does NOT bump endedAt — it remains the last part's
        // end (no new part).
        let afterEnd = try #require(
            try await MeetingRepository(database: harness.database).fetch(meeting.id)).endedAt
        #expect(afterEnd == atPause)
    }

    @Test("pause on a seconds-old meeting is LEGAL (no zero-audio failed write)")
    func pauseSecondsOldMeetingLegal() async throws {
        let harness = try makePauseHarness()
        // Plant header-only stubs (an empty part — the seconds-old case).
        harness.engine.state.withLock { $0.plantMode = .emptyStubs }
        let meeting = try await harness.controller.start(source: .meet)
        let paused = try await harness.controller.pause()
        // Pause is legal — status is paused, NOT failed.
        #expect(paused.status == .paused)
        #expect(try await status(harness.database, meeting.id) == "paused")
    }

    // MARK: - AC3: single-transaction durability (the midTransactionHook seam)

    @Test("AC3: a throw BETWEEN part-close and status-write rolls BOTH back")
    func pauseTransactionAtomic() async throws {
        let harness = try makePauseHarness(transactionHook: { throw TestFailure() })
        let meeting = try await harness.controller.start(source: .meet)

        await #expect(throws: TestFailure.self) {
            try await harness.controller.pause()
        }
        // Neither the status flip NOR the part close committed: status stays
        // `recording` and the part row is still OPEN (no ended_at) — today's
        // kill-mid-capture semantics, exactly as AC4's pre-commit half says.
        #expect(try await status(harness.database, meeting.id) == "recording")
        let openParts = try await harness.database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM meeting_capture_part WHERE meeting_id = ? AND ended_at_ms IS NULL",
                arguments: [meeting.id]) ?? -1
        }
        #expect(openParts == 1)
    }

    @Test("AC3: a NON-discriminating hook (success) commits both writes together")
    func pauseTransactionCommitsTogether() async throws {
        // The control: the SAME path with a no-op hook commits both halves —
        // proving the discrimination above is non-vacuous.
        let observed = Mutex(false)
        let harness = try makePauseHarness(transactionHook: { observed.withLock { $0 = true } })
        let meeting = try await harness.controller.start(source: .meet)
        try await harness.controller.pause()
        #expect(observed.withLock { $0 })  // the hook ran inside the transaction
        #expect(try await status(harness.database, meeting.id) == "paused")
        let closedParts = try await harness.database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM meeting_capture_part WHERE meeting_id = ? AND ended_at_ms IS NOT NULL",
                arguments: [meeting.id]) ?? -1
        }
        #expect(closedParts == 1)
    }

    @Test("resume commit-failure: engine torn down, meeting stays paused, error surfaced")
    func resumeCommitFailureTearsDown() async throws {
        // Start + pause on a hook-free controller.
        let harness = try makePauseHarness()
        let meeting = try await harness.controller.start(source: .meet)
        try await harness.controller.pause()
        #expect(try await status(harness.database, meeting.id) == "paused")

        // A controller over the SAME DB whose transactionHook throws — the
        // resume commit fails AFTER the engine started.
        let failingEngine = PauseMockEngine()
        let failing = RecordingController(
            database: harness.database, engine: failingEngine,
            processKicker: { _ in }, now: { Date() },
            transactionHook: { throw TestFailure() })
        await #expect(throws: TestFailure.self) {
            try await failing.resumePaused(meetingID: meeting.id)
        }
        // The engine started then was torn down (stop called); no live
        // session persists; the meeting stays durably paused.
        #expect(failingEngine.state.withLock { $0.startCalls } == 1)
        #expect(failingEngine.state.withLock { $0.stopCalls } == 1)
        #expect(await failing.currentSession() == nil)
        #expect(try await status(harness.database, meeting.id) == "paused")
    }

    @Test("M-2: resume part-open + status write are ONE transaction — a mid throw leaves NO stray part row")
    func resumeTransactionAtomic() async throws {
        // The G7 discriminating pattern for resume (mirrors pauseTransaction-
        // Atomic): a throw BETWEEN the new-part INSERT and the status write
        // must roll BOTH back. If the two were split into separate
        // transactions, the part-2 row would survive — this test catches that.
        let harness = try makePauseHarness()
        let meeting = try await harness.controller.start(source: .meet)
        try await harness.controller.pause()
        #expect(try await partCount(harness.database, meeting.id) == 1)  // only part 1

        let failingEngine = PauseMockEngine()
        let failing = RecordingController(
            database: harness.database, engine: failingEngine,
            processKicker: { _ in }, now: { Date() },
            transactionHook: { throw TestFailure() })
        await #expect(throws: TestFailure.self) {
            try await failing.resumePaused(meetingID: meeting.id)
        }
        // BOTH halves rolled back: status stays paused AND the part-2 row never
        // committed — the meeting still has exactly its one paused part.
        #expect(try await status(harness.database, meeting.id) == "paused")
        #expect(try await partCount(harness.database, meeting.id) == 1)
    }

    @Test("M-2 control: a NON-discriminating (success) hook commits the resume part-open + status together")
    func resumeTransactionCommitsTogether() async throws {
        // Proves the discrimination above is non-vacuous: the SAME path with a
        // no-op hook commits both halves (status recording + the new part row).
        let observed = Mutex(false)
        let harness = try makePauseHarness()
        let meeting = try await harness.controller.start(source: .meet)
        try await harness.controller.pause()

        let engine = PauseMockEngine()
        let controller = RecordingController(
            database: harness.database, engine: engine,
            processKicker: { _ in }, now: { Date() },
            transactionHook: { observed.withLock { $0 = true } })
        try await controller.resumePaused(meetingID: meeting.id)
        #expect(observed.withLock { $0 })  // the hook ran inside the transaction
        #expect(try await status(harness.database, meeting.id) == "recording")
        #expect(try await partCount(harness.database, meeting.id) == 2)
    }

    // MARK: - H-1: End-from-pause racing Resume processes a LIVE meeting

    @Test("H-1: End landing inside Resume's engine-start window does NOT kick a live meeting; Resume loses the race cleanly")
    func endRacingResumeDoesNotProcessLive() async throws {
        // The auditor's deterministic probe: a gated engine blocks inside
        // resumePaused's engine.start (modeling the real engine's hundreds-of-
        // ms start window). While the resume is blocked there — status still
        // durably `paused` — an End-from-pause runs to completion. The two
        // fixes converge: endPaused's flip is guarded+result-checked (it owns
        // the paused→processing flip and kicks), and the resume's status write
        // is guarded `WHERE status='paused'` (it now finds `processing`, the
        // whole transaction rolls back, the engine is torn down). Floor-2: the
        // resumed (live) meeting is NEVER processed under a live session.
        let harness = try makePauseHarness()
        let meeting = try await harness.controller.start(source: .meet)
        try await harness.controller.pause()
        #expect(try await status(harness.database, meeting.id) == "paused")

        // A gated engine: its start() blocks until released, AFTER planting the
        // new-part CAFs (so the resume is parked between engine-start and its
        // guarded commit — the exact race window).
        let gate = Gate()
        let gatedEngine = GatedPauseEngine(openGate: gate)
        let resumingController = RecordingController(
            database: harness.database, engine: gatedEngine,
            processKicker: { _ in }, now: { Date() })

        // Kick the resume; it parks inside engine.start.
        let resumeTask = Task { try await resumingController.resumePaused(meetingID: meeting.id) }
        await gate.waitUntilEntered()  // engine.start reached, status still paused

        // The End runs while the resume is parked — it owns the flip and kicks.
        let ended = try await harness.controller.endPaused(meetingID: meeting.id)
        #expect(ended.status == .processing)
        #expect(try await status(harness.database, meeting.id) == "processing")
        #expect(await waitUntil { harness.kicks.values == [meeting.id] })

        // Release the parked engine; the resume's guarded commit now finds the
        // meeting `processing`, NOT `paused` → it loses the race and throws.
        gate.release()
        await #expect(throws: CapturePartsError.self) {
            _ = try await resumeTask.value
        }
        // FLOOR 2: the meeting is durably `processing` (the End's write stands —
        // the resume never clobbered it back to `recording`) and NO live
        // session persists (the resume's engine was torn down).
        #expect(try await status(harness.database, meeting.id) == "processing")
        #expect(await resumingController.currentSession() == nil)
        #expect(gatedEngine.stopCalls() == 1)  // engine torn down on the lost race
    }

    // MARK: - AC1/AC4: sweep gating (H-1) — paused meeting is encoded, NOT kicked

    @Test("H-1: the orphan sweep encodes a paused meeting's CAFs but WITHHOLDS the kick")
    func sweepGatesKickForPaused() async throws {
        let database = try makeDatabase()
        // A paused meeting with an orphan part-1 CAF on disk (a crash after a
        // pause committed, before the encode finished — or a resume-window
        // crash leaving a new-part CAF).
        let meeting = makeMeeting(status: .paused)
        try await MeetingRepository(database: database).create(meeting)
        try database.paths.createMeetingDirectory(meeting.id)
        // Plant a real CAF (zero-frame would be unlinked; we want it encoded).
        for track in CaptureTrack.allCases {
            let writer = try CaptureCAFWriter(
                url: database.paths.captureCAFURL(meeting.id, track: track))
            let buffer = AVAudioPCMBuffer(pcmFormat: CaptureCAFWriter.format, frameCapacity: 16_000)!
            buffer.frameLength = 16_000
            try writer.write(buffer)
            writer.close()
        }

        let kicks = Recorder<MeetingID>()
        let results = await CaptureRecovery.sweepOrphanCAFs(
            database: database, kick: { kicks.append($0) })

        // The part WAS encoded (floor 2 — retention retained).
        #expect(FileManager.default.fileExists(atPath: database.paths.audioURL(meeting.id).path))
        // But the kick was WITHHELD (paused).
        try await Task.sleep(for: .milliseconds(50))
        #expect(kicks.values.isEmpty)
        let swept = try #require(results.first { $0.meetingID == meeting.id })
        #expect(!swept.kicked)
    }

    @Test("H-1: a NON-paused interrupted meeting IS kicked by the sweep (control)")
    func sweepKicksNonPaused() async throws {
        let database = try makeDatabase()
        // A `failed`/interrupted meeting (the normal recovery case) IS kicked.
        let meeting = makeMeeting(status: .failed)
        try await MeetingRepository(database: database).create(meeting)
        try database.paths.createMeetingDirectory(meeting.id)
        for track in CaptureTrack.allCases {
            let writer = try CaptureCAFWriter(
                url: database.paths.captureCAFURL(meeting.id, track: track))
            let buffer = AVAudioPCMBuffer(pcmFormat: CaptureCAFWriter.format, frameCapacity: 16_000)!
            buffer.frameLength = 16_000
            try writer.write(buffer)
            writer.close()
        }
        let kicks = Recorder<MeetingID>()
        _ = await CaptureRecovery.sweepOrphanCAFs(database: database, kick: { kicks.append($0) })
        #expect(await waitUntil { kicks.values == [meeting.id] })
    }

    // MARK: - AC4-class: kill semantics asserted at the DB level

    @Test("kill AFTER pause commit → relaunch lands paused, parts encoded, NO dispatch")
    func killAfterPauseCommitLandsPaused() async throws {
        // The post-commit kill half: the paused row is durable. The DB
        // startup sweep (run at every open) must NOT touch it, and the orphan
        // sweep encodes-without-kicking (covered above). Here we assert the
        // DB-startup-sweep survival directly.
        let root = try makeTempRoot()
        let meetingID = ULID.generate()
        do {
            let database = try BlaiseDatabase(rootURL: root)
            let meeting = makeMeeting(id: meetingID, status: .paused)
            try await MeetingRepository(database: database).create(meeting)
        }
        // Reopen (relaunch): the startup status sweep runs at open.
        let reopened = try BlaiseDatabase(rootURL: root)
        #expect(try await status(reopened, meetingID) == "paused")  // survived intact
    }

    @Test("kill in the RESUME window (paused row, no part-2 row yet) → relaunch lands paused")
    func killInResumeWindowLandsPaused() async throws {
        // Mid-resume crash: status still `paused`, the new-part CAF on disk
        // but no part-2 row committed. Relaunch: the DB sweep leaves `paused`;
        // the orphan sweep encodes the new-part CAF as residue, no kick.
        let database = try makeDatabase()
        let meeting = makeMeeting(status: .paused)
        try await MeetingRepository(database: database).create(meeting)
        try database.paths.createMeetingDirectory(meeting.id)
        // Part 1 retained (from the earlier recording) + a part-2 orphan CAF
        // (the live resume part the crash interrupted), but no part-2 row.
        try await CaptureParts.insertPart(
            database, meetingID: meeting.id, partIndex: 1,
            startedAtMs: Int64(meeting.startedAt.timeIntervalSince1970 * 1000))
        let part2System = database.paths.captureCAFURL(meeting.id, track: .system, part: 2)
        let part2Mic = database.paths.captureCAFURL(meeting.id, track: .mic, part: 2)
        for url in [part2System, part2Mic] {
            let writer = try CaptureCAFWriter(url: url)
            let buffer = AVAudioPCMBuffer(pcmFormat: CaptureCAFWriter.format, frameCapacity: 16_000)!
            buffer.frameLength = 16_000
            try writer.write(buffer)
            writer.close()
        }
        let kicks = Recorder<MeetingID>()
        _ = await CaptureRecovery.sweepOrphanCAFs(database: database, kick: { kicks.append($0) })
        // The part-2 residue m4a was encoded (rescued as gap-free residue).
        #expect(FileManager.default.fileExists(
            atPath: database.paths.audioURL(meeting.id, part: 2).path))
        // No kick (still paused).
        try await Task.sleep(for: .milliseconds(50))
        #expect(kicks.values.isEmpty)
        #expect(try await status(database, meeting.id) == "paused")
    }

    // MARK: - H-3: grace→Pause conversion lands paused, NOT a false "processing"

    @Test("H-3 (controller half): pauseGraceMeeting emits .paused so the holder shows paused, not processing")
    func gracePauseEmitsPausedEvent() async throws {
        let harness = try makePauseHarness()
        // A grace meeting: auto-stopped into grace — its part is finalized but
        // the row is still `recording` and there is NO live session (exactly
        // what pauseFromGrace converts).
        let meeting = makeMeeting(status: .recording)
        try await MeetingRepository(database: harness.database).create(meeting)
        try await CaptureParts.insertPart(
            harness.database, meetingID: meeting.id, partIndex: 1, startedAtMs: 0)
        try await CaptureParts.closePart(
            harness.database, meetingID: meeting.id, partIndex: 1, endedAtMs: 12_000)

        // The controller's AsyncStream registers its continuation LAZILY (only
        // on first iteration), so an immediate single emit can be lost before
        // iteration begins, AND a background drain Task can be starved under
        // the parallel full suite. `subscribeForTest` registers the
        // continuation SYNCHRONOUSLY, and we drain the iterator INLINE (no
        // background Task) with a finite finish — `pauseGraceMeeting` emits
        // exactly `.paused` and the conversion path emits nothing further, so
        // finishing the stream after the conversion lets the iterator return
        // the buffered events then terminate cleanly.
        var iterator = await harness.controller.subscribeForTest().makeAsyncIterator()
        await harness.controller.pauseGraceMeeting(meetingID: meeting.id)
        await harness.controller.finishEventStreamsForTest()

        // Durable status flipped to paused.
        #expect(try await status(harness.database, meeting.id) == "paused")
        // Drain inline: the buffered `.paused` is delivered, then the stream
        // terminates (no hang). This is the half that, in the app, sets
        // `pausedMeetingID` + applies `.meetingPaused` (drives the paused
        // display + reachable Resume/End). Without it the conversion left no
        // holder signal and the meeting was trapped (H-3).
        var sawPaused = false
        var sawStopped = false
        while let event = await iterator.next() {
            if case .paused(meeting.id, let secs) = event {
                #expect(secs == 12.0)  // sum of the closed part-1 duration
                sawPaused = true
            }
            if case .stopped = event { sawStopped = true }
        }
        #expect(sawPaused)
        // It is a pause, never a stop/processing kick.
        #expect(!sawStopped)
        #expect(harness.kicks.values.isEmpty)
    }

    @Test("H-3 (handler half): the grace→Pause machine-input order lands .paused with NO processing display")
    func gracePauseHandlerLandsPaused() async throws {
        // Replays the EXACT IndicatorStateMachine inputs the AppEnvironment
        // grace-end + recording-event handlers now produce for a grace→Pause
        // conversion, plus the processingMeetingID flag the handler would set.
        // Pre-fix this order landed a PERMANENT false `.processing` (graceEnded
        // applied `.graceExpired` + set processingMeetingID); the auditor's
        // probe `gracePauseLandsProcessingForever`. This pins the inverse.
        var machine = IndicatorStateMachine()
        // 1. The grace window stood (auto-stop into grace).
        machine.apply(.graceEntered(meetingTitle: "Standup", until: Date().addingTimeInterval(60)))
        #expect({ if case .grace = machine.apply(.tick(now: Date())) { return true }; return false }())
        // 2. graceEnded(reason: .paused) → the handler clears grace WITHOUT
        //    forcing expiry/processing (it applies `.graceResumed`, not
        //    `.graceExpired`, and does NOT set processingMeetingID).
        machine.apply(.graceResumed)
        // 3. The controller's `.paused` recording event → `.meetingPaused`.
        let state = machine.apply(.meetingPaused(meetingTitle: "Standup", accumulatedSeconds: 12.0))

        // The display is paused (Resume / End & process reachable), never the
        // false processing the pre-fix wiring produced.
        guard case .paused(_, let secs) = state else {
            Issue.record("expected .paused, got \(state)"); return
        }
        #expect(secs == 12.0)
        #expect({ if case .processing = state { return true }; return false }() == false)
        // Even a hypothetical late `.processingFinished` cannot resurface a
        // false processing — the machine never held a processing flag for this
        // conversion (the discriminating contrast with the expiry path).
        let after = machine.apply(.processingFinished)
        #expect({ if case .paused = after { return true }; return false }())
    }

    // MARK: - AC1/H-2/M-9: the universal refusal predicate

    @Test("start() refuses while ANY meeting is paused (typed meetingPaused)")
    func startRefusesWhilePaused() async throws {
        let harness = try makePauseHarness()
        let meeting = try await harness.controller.start(source: .meet, title: "Paused one")
        try await harness.controller.pause()
        // A fresh start is refused with the typed paused refusal carrying the
        // title for the prompt.
        await #expect {
            try await harness.controller.start(source: .zoom)
        } throws: { error in
            guard case RecordingControllerError.meetingPaused(let id, let title) = error else { return false }
            return id == meeting.id && title == "Paused one"
        }
    }

    @Test("M-9: resumePaused of X refuses if ANOTHER meeting is paused")
    func resumeRefusesIfOtherPaused() async throws {
        let harness = try makePauseHarness()
        // Meeting A: paused.
        let a = try await harness.controller.start(source: .meet, title: "A")
        try await harness.controller.pause()
        // Plant a SECOND paused meeting B directly in the DB.
        let b = makeMeeting(title: "B", status: .paused)
        try await MeetingRepository(database: harness.database).create(b)
        // Resuming A must refuse — B is another paused meeting.
        await #expect {
            try await harness.controller.resumePaused(meetingID: a.id)
        } throws: { error in
            if case RecordingControllerError.meetingPaused(let id, _) = error { return id == b.id }
            return false
        }
    }

    @Test("M-9: the C14 grace resume entry refuses while another meeting is paused")
    func graceResumeRefusesIfOtherPaused() async throws {
        let harness = try makePauseHarness()
        // A paused meeting B exists.
        let b = makeMeeting(title: "B paused", status: .paused)
        try await MeetingRepository(database: harness.database).create(b)
        // A graced meeting A (status recording, no live session). resume() is
        // the C14 grace rejoin path.
        let a = makeMeeting(title: "A grace", status: .recording)
        try await MeetingRepository(database: harness.database).create(a)
        await #expect {
            try await harness.controller.resume(meetingID: a.id)
        } throws: { error in
            if case RecordingControllerError.meetingPaused = error { return true }
            return false
        }
    }

    @Test("non-refusal: start during a grace meeting (recording status, no session) is allowed")
    func startNotRefusedDuringGrace() async throws {
        let harness = try makePauseHarness()
        // A graced meeting: status `recording`, NO live session, NOT paused.
        let graced = makeMeeting(title: "Graced", status: .recording)
        try await MeetingRepository(database: harness.database).create(graced)
        // A fresh start is NOT refused (the back-to-back path stays green).
        let fresh = try await harness.controller.start(source: .meet)
        #expect(fresh.status == .recording)
    }

    @Test("resumePaused of X is NOT refused by X's OWN paused status")
    func resumeNotRefusedBySelf() async throws {
        let harness = try makePauseHarness()
        let meeting = try await harness.controller.start(source: .meet)
        try await harness.controller.pause()
        // Resuming the paused meeting is the point — its own paused status
        // must not refuse it.
        let resumed = try await harness.controller.resumePaused(meetingID: meeting.id)
        #expect(resumed.status == .recording)
    }

    // MARK: - dispatch refusal (defense in depth)

    @Test("dispatchProcessing refuses a paused meeting (PipelineDispatchError)")
    func dispatchRefusesPaused() async throws {
        let harness = try await makePipelineHarness()
        let meeting = makeMeeting(status: .paused)
        try await MeetingRepository(database: harness.database).create(meeting)
        await #expect(throws: PipelineDispatchError.self) {
            try await harness.pipeline.dispatchProcessing(meetingID: meeting.id)
        }
    }

    // MARK: - AC1: pause on a finalizing meeting is a NO-OP (TOCTOU backstop)

    @Test("pause while no live session (already finalizing) is a notRecording no-op")
    func pauseWhileFinalizingNoOp() async throws {
        let harness = try makePauseHarness()
        // No active session at all (the disabled-control + late-click case).
        await #expect(throws: RecordingControllerError.self) {
            try await harness.controller.pause()
        }
    }

    // MARK: - AC2: the stitcher treats a pause gap as an ordinary inter-part gap

    @Test("AC2: pause→resume→stop yields a 2-part plan; the pause gap is an ordinary inter-part gap, no filler")
    func pauseResumeStopTwoPartPlan() async throws {
        let harness = try makePauseHarness()
        // A controlled clock so part offsets are deterministic.
        let clock = Mutex(Date(timeIntervalSince1970: 1_781_000_000))
        let controller = RecordingController(
            database: harness.database, engine: harness.engine,
            processKicker: { harness.kicks.append($0) },
            now: { clock.withLock { $0 } })

        let meeting = try await controller.start(source: .meet)
        clock.withLock { $0 = $0.addingTimeInterval(10) }  // part 1 ~ [0, 10]
        try await controller.pause()
        clock.withLock { $0 = $0.addingTimeInterval(30) }  // a 30 s pause gap
        try await controller.resumePaused(meetingID: meeting.id)
        clock.withLock { $0 = $0.addingTimeInterval(10) }  // part 2 ~ [40, 50]
        try await controller.stop()

        // The stitcher's plan enumerates BOTH parts with absolute offsets; the
        // pause gap is just the offset difference (no synthetic filler part).
        let plan = await CaptureStitcher.plan(database: harness.database, meetingID: meeting.id)
        #expect(plan.count == 2)
        #expect(plan[0].index == 1)
        #expect(plan[1].index == 2)
        #expect(plan[0].offsetMs == 0)
        // Part 2's absolute offset is ~40 s (10 s of part 1 + 30 s pause gap).
        let offset2 = try #require(plan[1].offsetMs)
        #expect(abs(offset2 - 40_000) <= 200)
        // Both parts carry real audio on both tracks (no row-less residue).
        #expect(plan.allSatisfy { $0.systemM4A != nil && $0.micM4A != nil && $0.offsetMs != nil })
    }

    @Test("H-1: a Resume winning the fetch→flip TOCTOU makes End's flip a no-op → NO kick (flip-result checked)")
    func endFlipNoOpWhenResumeWinsToctou() async throws {
        // The narrow TOCTOU the flip-result check defends: endPaused fetches the
        // meeting as `paused`, but BEFORE its guarded flip executes a concurrent
        // Resume flips the row to `recording` (live session). The flip then
        // changes 0 rows and returns false. With the result CHECKED, endPaused
        // bails — no kick against the now-live meeting. Without the check, it
        // would set status=processing locally and fire a handoff kick at a LIVE
        // recording (floor-2 violation). The endFlipHook drives the exact race.
        let database = try makeDatabase()
        let kicks = Recorder<MeetingID>()
        // The resume that wins the race runs on a SEPARATE controller over the
        // same DB, inside the hook.
        let resumeEngine = PauseMockEngine()
        let resumer = RecordingController(
            database: database, engine: resumeEngine, processKicker: { _ in }, now: { Date() })
        let meetingBox = Mutex<MeetingID?>(nil)
        let ending = RecordingController(
            database: database, engine: PauseMockEngine(),
            processKicker: { kicks.append($0) }, now: { Date() },
            endFlipHook: {
                // Resume wins between End's fetch and End's flip.
                if let id = meetingBox.withLock({ $0 }) {
                    _ = try? await resumer.resumePaused(meetingID: id)
                }
            })

        // Start + pause on the ending controller (writes the durable paused row).
        let meeting = try await ending.start(source: .meet)
        try await ending.pause()
        meetingBox.withLock { $0 = meeting.id }
        #expect(try await status(database, meeting.id) == "paused")

        // End: fetches paused, the hook resumes (→ recording + live session),
        // then the guarded flip is a no-op → endPaused returns without kicking.
        let ended = try await ending.endPaused(meetingID: meeting.id)
        #expect(ended.status == .recording)  // the live state, NOT processing
        // FLOOR 2: the meeting is durably `recording` with a live session; no
        // processing kick fired against it.
        #expect(try await status(database, meeting.id) == "recording")
        #expect(await resumer.currentSession() != nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(kicks.values.isEmpty)
    }

    // MARK: - H-2: relaunch restores the paused meeting

    @Test("H-2: a FRESH controller over a DB with a paused meeting restores it (id + accumulated time)")
    func relaunchRestoresPausedMeeting() async throws {
        // Session 1: start, pause, then "quit" (drop the controller). The
        // durable `paused` row + its closed part survive.
        let database = try makeDatabase()
        let engine1 = PauseMockEngine()
        let controller1 = RecordingController(
            database: database, engine: engine1, processKicker: { _ in }, now: { Date() })
        let meeting = try await controller1.start(source: .meet, title: "Standup")
        try await controller1.pause()
        #expect(try await status(database, meeting.id) == "paused")

        // Session 2: a FRESH controller over the SAME DB (the relaunch shape —
        // no in-memory state carried over). Restoration reads the paused row
        // back so the paused surfaces are reachable.
        let controller2 = RecordingController(
            database: database, engine: PauseMockEngine(), processKicker: { _ in }, now: { Date() })
        let restored = try #require(await controller2.restorablePausedMeeting())
        #expect(restored.meeting.id == meeting.id)
        #expect(restored.meeting.title == "Standup")
        // The paused-timer base is actually carried (the closed part-1 has a
        // real wall-clock duration — `> 0`, not the vacuous `>= 0`).
        #expect(restored.accumulatedSeconds > 0)  // sum of closed parts

        // Resume is reachable on the fresh controller (End similarly): the user
        // is NOT trapped in a refuse-everything state.
        let resumed = try await controller2.resumePaused(meetingID: meeting.id)
        #expect(resumed.status == .recording)
    }

    @Test("H-2: restorablePausedMeeting is nil when no meeting is paused")
    func relaunchNoPausedMeeting() async throws {
        let database = try makeDatabase()
        let controller = RecordingController(
            database: database, engine: PauseMockEngine(), processKicker: { _ in }, now: { Date() })
        // A normal recording meeting (not paused) must not be restored as paused.
        let m = makeMeeting(title: "Live", status: .recording)
        try await MeetingRepository(database: database).create(m)
        #expect(await controller.restorablePausedMeeting() == nil)
    }

    // MARK: - accumulated timer

    @Test("accumulatedRecordedSeconds sums closed part durations")
    func accumulatedTimer() async throws {
        let database = try makeDatabase()
        let meeting = makeMeeting(status: .paused)
        try await MeetingRepository(database: database).create(meeting)
        // Two closed parts: 10 s and 5 s; one open part (excluded).
        try await CaptureParts.insertPart(database, meetingID: meeting.id, partIndex: 1, startedAtMs: 0)
        try await CaptureParts.closePart(database, meetingID: meeting.id, partIndex: 1, endedAtMs: 10_000)
        try await CaptureParts.insertPart(database, meetingID: meeting.id, partIndex: 2, startedAtMs: 20_000)
        try await CaptureParts.closePart(database, meetingID: meeting.id, partIndex: 2, endedAtMs: 25_000)
        try await CaptureParts.insertPart(database, meetingID: meeting.id, partIndex: 3, startedAtMs: 30_000)
        let total = await CaptureParts.accumulatedRecordedSeconds(database, meetingID: meeting.id)
        #expect(total == 15.0)  // 10 + 5; the open part 3 contributes nothing
    }
}
