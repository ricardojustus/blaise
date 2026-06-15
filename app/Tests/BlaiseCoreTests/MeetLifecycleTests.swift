import Foundation
import Synchronization
import Testing

@testable import BlaiseCore

// C14 AC1/AC2: schema v2 at the ingestor — v1 AND v2 accepted; lifecycle +
// per-batch liveness signals forwarded post-commit for EVERY accepted
// code-carrying batch (correlated or not); heartbeat-only unmatched batches
// never stored pending; stale batches never forwarded — plus the
// cross-chunk lifecycle golden fixture consumption (the same pair the
// extension's vitest pin keeps self-consistent).

// MARK: - Lifecycle golden fixtures

private struct LifecycleGoldenExpectation: Codable {
    struct Lifecycle: Codable {
        let kind: String
        let atMs: Int64
        let reason: String?
    }

    let meetingCode: String
    let selfSubstitutionName: String
    let schemaVersion: Int
    let lifecycle: Lifecycle
    let capturedAtMs: Int64
    let activeSpeakerEvents: [ActiveSpeakerEvent]
    let expectedMeetStartNotifications: Int
}

private enum LifecycleGolden {
    static var wire: GoldenWire {
        get throws {
            try JSONDecoder().decode(
                GoldenWire.self,
                from: Data(contentsOf: VocabFixtures.repoRoot.appendingPathComponent(
                    "extension/test/fixtures/wire_batch_lifecycle_golden.json")))
        }
    }

    static var expectation: LifecycleGoldenExpectation {
        get throws {
            try JSONDecoder().decode(
                LifecycleGoldenExpectation.self,
                from: Data(contentsOf: VocabFixtures.repoRoot.appendingPathComponent(
                    "extension/test/fixtures/expected_lifecycle.json")))
        }
    }
}

/// Records signals the ingestor forwards (the tracker seam under test).
private final class SignalRecorder: MeetCallSignalReceiving, @unchecked Sendable {
    let signals = Mutex<[MeetCallSignal]>([])

    func receive(_ signal: MeetCallSignal) async {
        signals.withLock { $0.append(signal) }
    }

    var received: [MeetCallSignal] { signals.withLock { $0 } }
}

private func makeSignalHarness(
    session: any RecordingSessionProviding = NoRecordingSessionProvider()
) async throws -> (harness: MeetHarness, signals: SignalRecorder) {
    let database = try makeDatabase()
    let secrets = InMemorySecretStore()
    let wire = try MeetGolden.wire
    try secrets.set(key: MeetEventsSecret.secretStoreKey, value: wire.testSecret)
    try await SettingsStore(database: database).set(
        UserIdentity.settingsKey,
        to: UserIdentity(name: "Conta Local", aliases: [], email: "local@example.com"))
    let recorder = SignalRecorder()
    let ingestor = MeetEventsIngestor(
        database: database, secrets: secrets, session: session,
        signals: recorder, now: { MeetGolden.goldenNow })
    return (MeetHarness(database: database, secrets: secrets, ingestor: ingestor), recorder)
}

private func v2Batch(
    code: String = "abc-defg-hij", capturedAtMs: Int64 = 1_781_136_000_000,
    events: [MeetWireEvent] = [], roster: [MeetWireParticipant] = [],
    lifecycle: MeetWireLifecycle? = nil
) -> MeetWireBatch {
    MeetWireBatch(
        meetingCode: code, capturedAtMs: capturedAtMs, droppedCount: 0, poisonedCount: 0,
        roster: roster, events: events, schemaVersion: 2, lifecycle: lifecycle)
}

private func body(for batch: MeetWireBatch, secret: String) throws -> Data {
    let plaintext = String(decoding: try JSONEncoder().encode(batch), as: UTF8.self)
    return try JSONEncoder().encode(try encrypt(plaintext: plaintext, secret: secret))
}

@Suite("C14 ingestor: schema v2 + signal forwarding")
struct MeetLifecycleIngestorTests {
    @Test("v1 batches still ingest (a v1 batch is a v2 batch with no lifecycle)")
    func v1StillAccepted() async throws {
        let (h, signals) = try await makeSignalHarness()
        try await makeGoldenMeeting(h.database)
        // The committed C12 golden is schemaVersion 1.
        let wire = try MeetGolden.wire
        let response = await h.ingestor.handle(body: h.envelopeBody(wire.deliveries[0]))
        #expect(response.status == 200)
        let forwarded = await waitUntil { signals.received.count == 1 }
        #expect(forwarded)
        #expect(signals.received.first?.lifecycle == nil)
        #expect(signals.received.first?.meetingCode == "abc-defg-hij")
    }

    @Test("v2 batch with lifecycle ingests; the signal carries lifecycle + capturedAtMs")
    func v2LifecycleForwarded() async throws {
        let (h, signals) = try await makeSignalHarness()
        try await makeGoldenMeeting(h.database)
        let secret = try MeetGolden.wire.testSecret
        let lifecycle = MeetWireLifecycle(
            kind: .callEnded, atMs: 1_781_135_999_000, reason: "left")
        let response = await h.ingestor.handle(
            body: try body(for: v2Batch(lifecycle: lifecycle), secret: secret))
        #expect(response.status == 200)
        #expect(await waitUntil { signals.received.count == 1 })
        let signal = try #require(signals.received.first)
        #expect(signal.lifecycle == lifecycle)
        #expect(signal.capturedAtMs == 1_781_136_000_000)
    }

    @Test("schemaVersion 3 is still 400 (never silently accepted)")
    func v3Rejected() async throws {
        let (h, signals) = try await makeSignalHarness()
        let secret = try MeetGolden.wire.testSecret
        var batch = v2Batch()
        batch.schemaVersion = 3
        let response = await h.ingestor.handle(body: try body(for: batch, secret: secret))
        #expect(response.status == 400)
        try await Task.sleep(for: .milliseconds(50))
        #expect(signals.received.isEmpty)
    }

    @Test("UNCORRELATED batch (no matching meeting) still forwards its signal — declined calls stay alive")
    func uncorrelatedForwarded() async throws {
        let (h, signals) = try await makeSignalHarness()  // no meeting created
        let secret = try MeetGolden.wire.testSecret
        let lifecycle = MeetWireLifecycle(kind: .heartbeat, atMs: 1_781_136_000_000)
        let response = await h.ingestor.handle(
            body: try body(for: v2Batch(lifecycle: lifecycle), secret: secret))
        #expect(response.status == 200)
        #expect(await waitUntil { signals.received.count == 1 })
        #expect(signals.received.first?.lifecycle?.kind == .heartbeat)
    }

    @Test("heartbeat-only batch matched to no meeting is NOT stored pending (content-free)")
    func heartbeatOnlyNeverPending() async throws {
        let (h, _) = try await makeSignalHarness()
        let secret = try MeetGolden.wire.testSecret
        let heartbeat = v2Batch(lifecycle: MeetWireLifecycle(kind: .heartbeat, atMs: 1_781_136_000_000))
        let response = await h.ingestor.handle(body: try body(for: heartbeat, secret: secret))
        #expect(response.status == 200)
        #expect(try await h.pendingCount() == 0)

        // A content-carrying lifecycle batch (call-ended final flush) IS
        // stored pending when unmatched.
        let flush = v2Batch(
            events: [
                MeetWireEvent(
                    displayName: "Maria Silva", participantID: "pid-2", isSelf: false,
                    startEpochMillis: 1_781_135_000_000, endEpochMillis: 1_781_135_004_500)
            ],
            lifecycle: MeetWireLifecycle(kind: .callEnded, atMs: 1_781_136_000_500, reason: "left"))
        _ = await h.ingestor.handle(body: try body(for: flush, secret: secret))
        #expect(try await h.pendingCount() == 1)
    }

    @Test("stale batch (outside ±48 h): acked 200, dropped, NEVER forwarded")
    func staleNeverForwarded() async throws {
        let (h, signals) = try await makeSignalHarness()
        let secret = try MeetGolden.wire.testSecret
        let staleMs = Int64(MeetGolden.goldenNow.timeIntervalSince1970 * 1000) - 49 * 3600 * 1000
        let batch = v2Batch(
            capturedAtMs: staleMs,
            lifecycle: MeetWireLifecycle(kind: .callStarted, atMs: staleMs))
        let response = await h.ingestor.handle(body: try body(for: batch, secret: secret))
        #expect(response.status == 200)
        try await Task.sleep(for: .milliseconds(50))
        #expect(signals.received.isEmpty, "the ±48 h freshness gate applies first")
    }
}

@Suite("C14 lifecycle golden fixtures (cross-chunk contract)")
struct LifecycleGoldenTests {
    @Test("both deliveries ack 200; the event ingests ONCE; lifecycle + liveness forwarded")
    func goldenIngestion() async throws {
        let (h, signals) = try await makeSignalHarness()
        let wire = try LifecycleGolden.wire
        let expected = try LifecycleGolden.expectation
        // The harness secret matches (the goldens share the test secret).
        let meeting = try await makeGoldenMeeting(h.database, code: expected.meetingCode)

        for delivery in wire.deliveries {
            let response = await h.ingestor.handle(body: h.envelopeBody(delivery))
            #expect(response.status == 200)
            #expect(
                response.ackHeaderValue
                    == expectedAck(secret: wire.testSecret, iv: delivery.iv, status: 200))
        }
        let stored = try await h.storedEvents(meeting.id)
        #expect(stored == expected.activeSpeakerEvents, "replayed delivery ingests ONCE")

        // One forwarded signal per accepted batch (the REPLAY is accepted —
        // deduped 200 — so it forwards too; the tracker's monotonic guard
        // is what must drop it).
        #expect(await waitUntil { signals.received.count == 2 })
        for signal in signals.received {
            #expect(signal.meetingCode == expected.meetingCode)
            #expect(signal.capturedAtMs == expected.capturedAtMs)
            #expect(signal.lifecycle?.kind.rawValue == expected.lifecycle.kind)
            #expect(signal.lifecycle?.atMs == expected.lifecycle.atMs)
        }
    }

    @Test("tracker outcome: the golden's fresh call-started posts exactly ONE notification across the replay")
    func goldenTrackerOutcome() async throws {
        let wire = try LifecycleGolden.wire
        let expected = try LifecycleGolden.expectation

        // Tracker with a clock just after the batch capture (fresh window).
        let controller = NoSessionAutomationController()
        let notifier = CountingNotifier()
        let tracker = MeetCallTracker(
            controller: controller, notifier: notifier,
            resumeWindowSeconds: { 300 },
            now: { Date(timeIntervalSince1970: Double(expected.capturedAtMs) / 1000.0 + 5) },
            schedule: { _, _ in })

        let (h, _) = try await makeSignalHarness()
        _ = try await makeGoldenMeeting(h.database, code: expected.meetingCode)
        // Re-create the ingestor wired straight to the tracker.
        let secrets = InMemorySecretStore()
        try secrets.set(key: MeetEventsSecret.secretStoreKey, value: wire.testSecret)
        let ingestor = MeetEventsIngestor(
            database: h.database, secrets: secrets, signals: tracker,
            now: { Date(timeIntervalSince1970: Double(expected.capturedAtMs) / 1000.0 + 5) })
        for delivery in wire.deliveries {
            let response = await ingestor.handle(
                body: try JSONEncoder().encode(
                    MeetWireEnvelope(iv: delivery.iv, ciphertext: delivery.ciphertext)))
            #expect(response.status == 200)
        }
        let posted = await waitUntil {
            notifier.meetStartCount.withLock { $0 } >= expected.expectedMeetStartNotifications
        }
        #expect(posted)
        try await Task.sleep(for: .milliseconds(100))
        #expect(
            notifier.meetStartCount.withLock { $0 } == expected.expectedMeetStartNotifications,
            "the byte-identical replay re-fires NOTHING (monotonic guard)")
    }
}

// MARK: - Minimal tracker collaborators for the golden test

private final class NoSessionAutomationController: RecordingAutomating, @unchecked Sendable {
    func currentSession() async -> RecordingSessionInfo? { nil }
    @discardableResult
    func start(
        source: MeetingSource, title: String?, meetingCode: String?, attendees: [Attendee],
        anchor: CalendarAnchor?
    ) async throws -> Meeting {
        makeMeeting()
    }
    @discardableResult
    func stop(alarm: String?) async throws -> Meeting { throw RecordingControllerError.notRecording }
    func autoStop(finalizeImmediately: Bool) async throws -> AutoStopOutcome {
        throw RecordingControllerError.notRecording
    }
    @discardableResult
    func resume(meetingID: MeetingID) async throws -> Meeting {
        throw BlaiseDatabaseError.meetingNotFound(meetingID)
    }
    func kickProcessing(meetingID: MeetingID) async {}
    @discardableResult
    func pause() async throws -> Meeting { throw RecordingControllerError.notRecording }
    @discardableResult
    func resumePaused(meetingID: MeetingID) async throws -> Meeting {
        throw BlaiseDatabaseError.meetingNotFound(meetingID)
    }
    @discardableResult
    func endPaused(meetingID: MeetingID) async throws -> Meeting {
        throw BlaiseDatabaseError.meetingNotFound(meetingID)
    }
    func pauseGraceMeeting(meetingID: MeetingID) async {}
    func pausedMeetingID(excluding: MeetingID?) async -> MeetingID? { nil }
}

private final class CountingNotifier: AutomationNotifying, @unchecked Sendable {
    let meetStartCount = Mutex(0)

    func postMeetStart(code: String, title: String?) async {
        meetStartCount.withLock { $0 += 1 }
    }
    func withdrawMeetStart(code: String) async {}
    func postWatchdogStop(meetingID: MeetingID, title: String, canResume: Bool) async {}
    func withdrawWatchdogStop(meetingID: MeetingID) async {}
    func postNudge(meetingID: MeetingID, title: String) async {}
    func postCalendarUpcoming(eventKey: String, title: String, start: Date, code: String, urlString: String?) async {}
    func withdrawCalendarUpcoming(eventKey: String) async {}
}
