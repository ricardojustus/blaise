import AVFoundation
import Foundation
import Synchronization
import Testing

@testable import BlaiseCore

// C11 AC1: session lifecycle — start → Meeting row + live session
// registered (the C12 listener's live-correlation seam); stop → endedAt +
// verified encode + processing kick; the write-failure stop policy. The
// capture engine is mocked (plants real CAF bytes); no audio device, no TCC.

/// Mock engine: plants 1 s of valid LPCM CAF on start (so the stop path
/// exercises the REAL verified encode) and exposes the event callback.
/// Planting happens BEFORE a configured `startError` is thrown — like the
/// real engine, which creates the CAF writers before its graph build.
private final class MockCaptureEngine: AudioCapturing, @unchecked Sendable {
    enum PlantMode {
        /// 1 s of real LPCM frames per track.
        case real
        /// Header-only stubs (writer opened + closed, zero frames) — the
        /// real engine's footprint when the graph build fails.
        case emptyStubs
        case none
    }

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
        let (error, plant) = state.withLock { state -> (Error?, PlantMode) in
            state.startCalls += 1
            state.onEvent = onEvent
            return (state.startError, state.plantMode)
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

    func stop() async {
        state.withLock { $0.stopCalls += 1 }
    }

    func emit(_ event: CaptureEngineEvent) {
        let handler = state.withLock { $0.onEvent }
        handler?(event)
    }
}

private struct ControllerHarness {
    let database: BlaiseDatabase
    let engine: MockCaptureEngine
    let controller: RecordingController
    let kicks: Recorder<MeetingID>
}

private func makeControllerHarness() throws -> ControllerHarness {
    let database = try makeDatabase()
    let engine = MockCaptureEngine()
    let kicks = Recorder<MeetingID>()
    let controller = RecordingController(
        database: database, engine: engine,
        processKicker: { kicks.append($0) },
        now: { msDate() })
    return ControllerHarness(database: database, engine: engine, controller: controller, kicks: kicks)
}

@Suite("C11 recording controller")
struct RecordingControllerTests {
    @Test("start: Meeting row (source, code, recording status) + live session registered")
    func start() async throws {
        let harness = try makeControllerHarness()
        let meeting = try await harness.controller.start(
            source: .meet, meetingCode: "abc-defg-hij",
            attendees: [Attendee(name: "Fábio Souza", source: .calendar)])

        let stored = try #require(try await MeetingRepository(database: harness.database).fetch(meeting.id))
        #expect(stored.source == .meet)
        #expect(stored.status == .recording)
        // Durable captured marker (migration v6): the dispatch keys on it
        // even if a track file is later lost.
        #expect(stored.captured)
        #expect(stored.meetingCode == "abc-defg-hij")
        #expect(stored.startedAt == msDate())
        #expect(stored.endedAt == nil)
        #expect(stored.attendees.map(\.name) == ["Fábio Souza"])

        // The C10 seam, live: the listener's live-correlation case activates.
        let session = try #require(await harness.controller.currentSession())
        #expect(session.meetingID == meeting.id)
        #expect(session.meetingCode == "abc-defg-hij")

        await #expect(throws: RecordingControllerError.self) {
            try await harness.controller.start(source: .zoom)
        }
    }

    @Test("stop: endedAt + verified encode (CAFs released) + processing kicked")
    func stop() async throws {
        let harness = try makeControllerHarness()
        let meeting = try await harness.controller.start(source: .inPerson)
        let stopped = try await harness.controller.stop()
        #expect(stopped.endedAt != nil)

        let paths = harness.database.paths
        #expect(FileManager.default.fileExists(atPath: paths.audioURL(meeting.id).path))
        #expect(FileManager.default.fileExists(atPath: paths.audioMicURL(meeting.id).path))
        #expect(!FileManager.default.fileExists(atPath: paths.captureCAFURL(meeting.id, track: .system).path))
        #expect(!FileManager.default.fileExists(atPath: paths.captureCAFURL(meeting.id, track: .mic).path))
        #expect(await harness.controller.currentSession() == nil)

        // The kick is fire-and-forget; await its arrival.
        let kicked = await waitUntil { harness.kicks.values == [meeting.id] }
        #expect(kicked)
        #expect(harness.engine.state.withLock { $0.stopCalls } == 1)

        await #expect(throws: RecordingControllerError.self) {
            try await harness.controller.stop()
        }
    }

    @Test("write failure → the one sanctioned automatic stop, with the loud alarm")
    func writeFailureStops() async throws {
        let harness = try makeControllerHarness()
        let events = await harness.controller.events()
        let collected = Recorder<RecordingEvent>()
        let collector = Task {
            for await event in events { collected.append(event) }
        }
        let meeting = try await harness.controller.start(source: .meet)

        harness.engine.emit(.writeFailure("disk full"))

        let stopped = await waitUntil { await harness.controller.currentSession() == nil }
        #expect(stopped)
        let alarmEvent = await waitUntil {
            collected.values.contains {
                if case .stopped(meeting.id, let alarm, _) = $0 {
                    return alarm?.contains("disk full") == true
                }
                return false
            }
        }
        #expect(alarmEvent)
        // Salvage ran: whatever was on disk encoded, kick fired.
        #expect(await waitUntil { harness.kicks.values == [meeting.id] })
        let paths = harness.database.paths
        #expect(FileManager.default.fileExists(atPath: paths.audioURL(meeting.id).path))
        collector.cancel()
    }

    @Test("mic-silence events pass through to the UI stream")
    func micSilencePassthrough() async throws {
        let harness = try makeControllerHarness()
        let events = await harness.controller.events()
        let collected = Recorder<RecordingEvent>()
        let collector = Task { for await event in events { collected.append(event) } }
        _ = try await harness.controller.start(source: .meet)

        harness.engine.emit(.micSilence(active: true))
        let arrived = await waitUntil {
            collected.values.contains { $0 == .micSilence(active: true) }
        }
        #expect(arrived)
        collector.cancel()
    }

    @Test("capture-down events pass through to the UI stream (and do NOT stop the recording)")
    func captureDownPassthrough() async throws {
        let harness = try makeControllerHarness()
        let events = await harness.controller.events()
        let collected = Recorder<RecordingEvent>()
        let collector = Task { for await event in events { collected.append(event) } }
        _ = try await harness.controller.start(source: .meet)

        harness.engine.emit(.captureDown(active: true))
        let raised = await waitUntil {
            collected.values.contains { $0 == .captureDown(active: true) }
        }
        #expect(raised)
        // Unlike writeFailure, this must NOT stop the recording — the retry
        // ladder is still working; the warning buys visibility, not a stop.
        #expect(await harness.controller.currentSession() != nil)

        harness.engine.emit(.captureDown(active: false))
        let cleared = await waitUntil {
            collected.values.contains { $0 == .captureDown(active: false) }
        }
        #expect(cleared)
        #expect(await harness.controller.currentSession() != nil)
        collector.cancel()
    }

    @Test("engine start failure: row stays, marked failed with the reason (never deleted)")
    func engineStartFailure() async throws {
        let harness = try makeControllerHarness()
        harness.engine.state.withLock { $0.startError = CaptureSessionError.noDefaultInputDevice }

        await #expect(throws: (any Error).self) {
            try await harness.controller.start(source: .meet)
        }
        let meetings = try await harness.database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meeting") ?? -1
        }
        #expect(meetings == 1)
        let status = try await harness.database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT status FROM meeting") ?? ""
        }
        #expect(status == "failed")
        let error = try await harness.database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT last_processing_error FROM meeting") ?? ""
        }
        #expect(error.contains("capture start failed"))
        #expect(await harness.controller.currentSession() == nil)
    }

    @Test("stop emits .stopping (immediate UI hand-off) before .stopped (encode done)")
    func stoppingPrecedesStopped() async throws {
        let harness = try makeControllerHarness()
        let events = await harness.controller.events()
        let collected = Recorder<RecordingEvent>()
        let collector = Task { for await event in events { collected.append(event) } }
        let meeting = try await harness.controller.start(source: .meet)
        _ = try await harness.controller.stop()

        let done = await waitUntil {
            collected.values.contains {
                if case .stopped = $0 { return true }
                return false
            }
        }
        #expect(done)
        let stoppingIndex = collected.values.firstIndex {
            if case .stopping(meeting.id) = $0 { return true }
            return false
        }
        let stoppedIndex = collected.values.firstIndex {
            if case .stopped(meeting.id, nil, true) = $0 { return true }
            return false
        }
        #expect(stoppingIndex != nil && stoppedIndex != nil)
        if let stoppingIndex, let stoppedIndex {
            #expect(stoppingIndex < stoppedIndex)
        }
        collector.cancel()
    }

    @Test("no recoverable audio at stop: loud alarm, no kick, honest failed status")
    func noTrackStopAlarms() async throws {
        let harness = try makeControllerHarness()
        harness.engine.state.withLock { $0.plantMode = .none }
        let events = await harness.controller.events()
        let collected = Recorder<RecordingEvent>()
        let collector = Task { for await event in events { collected.append(event) } }
        let meeting = try await harness.controller.start(source: .meet)
        _ = try await harness.controller.stop()

        let alarmed = await waitUntil {
            collected.values.contains {
                if case .stopped(meeting.id, let alarm, let kicked) = $0 {
                    return alarm?.contains("no recoverable audio") == true && !kicked
                }
                return false
            }
        }
        #expect(alarmed)
        #expect(harness.kicks.values.isEmpty)
        let stored = try #require(try await MeetingRepository(database: harness.database).fetch(meeting.id))
        #expect(stored.status == .failed)
        #expect(stored.lastProcessingError?.contains("no recoverable audio") == true)

        // NOT a dead end: the next start works immediately.
        _ = try await harness.controller.start(source: .zoom)
        #expect(await harness.controller.currentSession() != nil)
        collector.cancel()
    }

    @Test("start failure deletes ONLY zero-frame CAF stubs (no audio ever existed)")
    func startFailureRemovesEmptyStubs() async throws {
        let harness = try makeControllerHarness()
        harness.engine.state.withLock {
            $0.plantMode = .emptyStubs
            $0.startError = CaptureSessionError.coreAudio("AudioDeviceStart", -1)
        }
        await #expect(throws: (any Error).self) {
            try await harness.controller.start(source: .meet)
        }
        let meetingID = try await harness.database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM meeting") ?? ""
        }
        for track in CaptureTrack.allCases {
            #expect(
                !FileManager.default.fileExists(
                    atPath: harness.database.paths.captureCAFURL(meetingID, track: track).path),
                "zero-frame stub for \(track.rawValue) should be deleted")
        }
        let status = try await harness.database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT status FROM meeting") ?? ""
        }
        #expect(status == "failed")
    }

    @Test("start failure RETAINS CAFs that carry audio frames (hard floor 2)")
    func startFailureRetainsNonEmptyCAFs() async throws {
        let harness = try makeControllerHarness()
        harness.engine.state.withLock {
            $0.plantMode = .real
            $0.startError = CaptureSessionError.coreAudio("AudioDeviceStart", -1)
        }
        await #expect(throws: (any Error).self) {
            try await harness.controller.start(source: .meet)
        }
        let meetingID = try await harness.database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM meeting") ?? ""
        }
        for track in CaptureTrack.allCases {
            #expect(
                FileManager.default.fileExists(
                    atPath: harness.database.paths.captureCAFURL(meetingID, track: track).path),
                "CAF with real frames must survive a start failure")
        }
    }

    @Test("default title: DD/MM/YYYY + 24 h per the notes conventions")
    func defaultTitle() {
        var components = DateComponents()
        components.year = 2026
        components.month = 6
        components.day = 10
        components.hour = 14
        components.minute = 30
        let date = Calendar.current.date(from: components)!
        #expect(RecordingController.defaultTitle(for: date) == "Meeting 10/06/2026 14:30")
    }

    @Test("awaitQuiescence: idle returns immediately; in-flight stop is awaited through encode completion")
    func awaitQuiescence() async throws {
        // The real encode is too fast to observe, so the harness HOLDS the
        // injected finalizer open on a gate: a no-op awaitQuiescence would
        // return while the gate is held — the vacuity this test exists to
        // prevent (audit round 3, M-8).
        let database = try makeDatabase()
        let engine = MockCaptureEngine()
        let order = Recorder<String>()
        let gate = DispatchSemaphore(value: 0)
        let controller = RecordingController(
            database: database, engine: engine,
            processKicker: { _ in },
            now: { msDate() },
            finalizer: { paths, meetingID, part in
                order.append("encodeEntered")
                // Bounded: gate.signal() (after the 200ms hold below) normally
                // arrives well within this window, so the timeout never fires on
                // the happy path. It exists only so a gated finalizer can never
                // permanently block its thread under full-suite parallelism.
                _ = gate.wait(timeout: .now() + .seconds(30))
                let outcome = CaptureRecovery.finalizeTracks(
                    paths: paths, meetingID: meetingID, part: part)
                order.append("encodeDone")
                return outcome
            })

        // Idle: no finalization in flight — must not hang.
        await controller.awaitQuiescence()

        let meeting = try await controller.start(source: .meet)
        // A MANUAL stop driven concurrently (the quit-intercept scenario:
        // the user stopped, then hit ⌘Q while the encode runs).
        let stopper = Task { try await controller.stop() }
        let entered = await waitUntil { order.values.contains("encodeEntered") }
        #expect(entered)

        let quiesced = Recorder<Bool>()
        let waiter = Task {
            await controller.awaitQuiescence()
            quiesced.append(true)
        }
        // With the encode gated open, a CORRECT awaitQuiescence cannot
        // return; the neutered no-op returns within microseconds.
        try await Task.sleep(for: .milliseconds(200))
        #expect(quiesced.values.isEmpty, "awaitQuiescence returned while the encode was still running")

        gate.signal()
        await waiter.value
        order.append("quiescenceReturned")
        _ = try await stopper.value
        // Quiescence returned only after the encode finished, and the
        // retained m4a exists (terminating here would NOT orphan the CAFs).
        let encodeDone = order.values.firstIndex(of: "encodeDone")
        let quiescenceReturned = order.values.firstIndex(of: "quiescenceReturned")
        #expect(encodeDone != nil && quiescenceReturned != nil)
        if let encodeDone, let quiescenceReturned {
            #expect(encodeDone < quiescenceReturned)
        }
        #expect(
            FileManager.default.fileExists(
                atPath: database.paths.audioURL(meeting.id).path))
    }

    @Test("zero mic streams: warning emitted AFTER started (survives the state machine's start reset)")
    func zeroStreamWarningOrdering() async throws {
        let harness = try makeControllerHarness()
        harness.engine.state.withLock { $0.micStreams = 0 }
        let events = await harness.controller.events()
        let collected = Recorder<RecordingEvent>()
        let collector = Task { for await event in events { collected.append(event) } }
        _ = try await harness.controller.start(source: .meet)

        let warned = await waitUntil {
            collected.values.contains {
                if case .micSilence(true) = $0 { return true }
                return false
            }
        }
        #expect(warned)
        let startedIndex = collected.values.firstIndex {
            if case .started = $0 { return true }
            return false
        }
        let warningIndex = collected.values.firstIndex {
            if case .micSilence(true) = $0 { return true }
            return false
        }
        #expect(startedIndex != nil && warningIndex != nil)
        if let startedIndex, let warningIndex {
            #expect(startedIndex < warningIndex)
        }
        // Through the state machine: the warning lands in .warning, not
        // erased — the exact failure mode of an event fired during start.
        var machine = IndicatorStateMachine()
        var finalState = IndicatorState.idle
        for event in collected.values {
            switch event {
            case .started(_, let at): finalState = machine.apply(.captureStarted(at: at))
            case .micSilence(let active): finalState = machine.apply(.micSilence(active: active))
            default: break
            }
        }
        guard case .warning = finalState else {
            Issue.record("expected .warning, got \(finalState)")
            collector.cancel()
            return
        }
        collector.cancel()
    }
}
