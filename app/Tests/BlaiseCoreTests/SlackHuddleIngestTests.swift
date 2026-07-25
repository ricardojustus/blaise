import Foundation
import Synchronization
import Testing

@testable import BlaiseCore

// C15: the in-process ingest entry (`MeetEventsIngestor.ingest(batch:)`) shares
// dedupe, correlation (live-session + ±10-min window), pending storage, roster
// absorption, and the automation signal forward with the decrypt path. A
// `slack:` code correlates like any other.

private final class Signals: MeetCallSignalReceiving, @unchecked Sendable {
    private let store = Mutex<[MeetCallSignal]>([])
    func receive(_ signal: MeetCallSignal) async { store.withLock { $0.append(signal) } }
    var all: [MeetCallSignal] { store.withLock { $0 } }
}

private struct LiveSession: RecordingSessionProviding {
    let info: RecordingSessionInfo?
    func currentSession() async -> RecordingSessionInfo? { info }
}

private let slackNow = Date(timeIntervalSince1970: 1_781_136_000)
private func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

private func makeIngestor(
    session: any RecordingSessionProviding = NoRecordingSessionProvider()
) async throws -> (ingestor: MeetEventsIngestor, database: BlaiseDatabase, signals: Signals) {
    let database = try makeDatabase()
    let secrets = InMemorySecretStore()
    try secrets.set(key: MeetEventsSecret.secretStoreKey, value: String(repeating: "a", count: 64))
    try await SettingsStore(database: database).set(
        UserIdentity.settingsKey,
        to: UserIdentity(name: "Conta Local", aliases: [], email: "local@example.com"))
    let signals = Signals()
    let ingestor = MeetEventsIngestor(
        database: database, secrets: secrets, session: session, signals: signals, now: { slackNow })
    return (ingestor, database, signals)
}

private func slackMeeting(
    _ database: BlaiseDatabase, code: String = "slack:R1",
    startedAt: Date = slackNow.addingTimeInterval(-120),
    endedAt: Date? = nil, status: MeetingStatus = .processing
) async throws -> Meeting {
    var meeting = makeMeeting(startedAt: startedAt, status: status)
    meeting.meetingCode = code
    meeting.endedAt = endedAt
    try await MeetingRepository(database: database).create(meeting)
    return meeting
}

private func rosterBatch(
    code: String = "slack:R1", capturedAt: Date = slackNow,
    roster: [MeetWireParticipant], lifecycle: MeetWireLifecycle? = nil,
    events: [MeetWireEvent] = []
) -> MeetWireBatch {
    MeetWireBatch(
        meetingCode: code, capturedAtMs: ms(capturedAt), droppedCount: 0, poisonedCount: 0,
        roster: roster, events: events, schemaVersion: 2, lifecycle: lifecycle)
}

private func pendingRoster(_ database: BlaiseDatabase, _ meetingID: MeetingID) async throws -> [String] {
    try await database.pool.read { db in
        try String.fetchAll(
            db,
            sql: "SELECT display_name FROM meet_roster_pending WHERE meeting_id = ? ORDER BY display_name",
            arguments: [meetingID])
    }
}

@Suite("C15 in-process ingest")
struct SlackHuddleIngestTests {
    @Test("a slack roster batch correlates and queues its non-self roster + forwards the signal")
    func rosterAndSignal() async throws {
        let (ingestor, database, signals) = try await makeIngestor()
        let meeting = try await slackMeeting(database)
        await ingestor.ingest(batch: rosterBatch(
            roster: [
                MeetWireParticipant(displayName: "Alice", participantID: "U_A", isSelf: false),
                MeetWireParticipant(displayName: nil, participantID: "U_SELF", isSelf: true),
            ],
            lifecycle: MeetWireLifecycle(kind: .callStarted, atMs: ms(slackNow))))
        #expect(try await pendingRoster(database, meeting.id) == ["Alice"])  // self dropped
        #expect(await waitUntil { signals.all.count == 1 })
        #expect(signals.all.first?.meetingCode == "slack:R1")
        #expect(signals.all.first?.lifecycle?.kind == .callStarted)
    }

    @Test("re-ingesting the same batch does not double-queue the roster")
    func rosterDedupe() async throws {
        let (ingestor, database, _) = try await makeIngestor()
        let meeting = try await slackMeeting(database)
        let batch = rosterBatch(roster: [
            MeetWireParticipant(displayName: "Alice", participantID: "U_A", isSelf: false)
        ])
        await ingestor.ingest(batch: batch)
        await ingestor.ingest(batch: batch)
        #expect(try await pendingRoster(database, meeting.id) == ["Alice"])
    }

    @Test("the in-process and decrypt paths share event dedupe (lands once)")
    func sharedEventDedupe() async throws {
        let (ingestor, database, _) = try await makeIngestor()
        let meeting = try await slackMeeting(database)
        let secret = String(repeating: "a", count: 64)
        let batch = rosterBatch(
            roster: [],
            events: [
                MeetWireEvent(
                    displayName: "Alice", participantID: "U_A", isSelf: false,
                    startEpochMillis: ms(slackNow), endEpochMillis: ms(slackNow) + 1000)
            ])
        // In-process first, then the SAME batch via the decrypt path.
        await ingestor.ingest(batch: batch)
        let plaintext = String(decoding: try JSONEncoder().encode(batch), as: UTF8.self)
        let response = await ingestor.handle(
            body: try JSONEncoder().encode(try encrypt(plaintext: plaintext, secret: secret)))
        #expect(response.status == 200)
        let stored = try await MeetEventsRepository(database: database)
            .activeSpeakerEvents(meetingID: meeting.id)
        #expect(stored.count == 1)  // deduped by the shared seen-id guard
    }

    @Test("slack code correlates to a live recording session")
    func liveSessionCorrelation() async throws {
        let database = try makeDatabase()
        let secrets = InMemorySecretStore()
        try await SettingsStore(database: database).set(
            UserIdentity.settingsKey,
            to: UserIdentity(name: "Conta Local", aliases: [], email: "local@example.com"))
        // A recording row + a live session pointing at it via the slack code.
        var meeting = makeMeeting(startedAt: slackNow, status: .recording)
        meeting.meetingCode = "slack:LIVE"
        try await MeetingRepository(database: database).create(meeting)
        let signals = Signals()
        let ingestor = MeetEventsIngestor(
            database: database, secrets: secrets,
            session: LiveSession(info: RecordingSessionInfo(
                meetingID: meeting.id, meetingCode: "slack:LIVE")),
            signals: signals, now: { slackNow })
        await ingestor.ingest(batch: rosterBatch(
            code: "slack:LIVE",
            roster: [MeetWireParticipant(displayName: "Bob", participantID: "U_B", isSelf: false)]))
        #expect(try await pendingRoster(database, meeting.id) == ["Bob"])
    }

    @Test("slack code correlates to a closed meeting via the ±10-min window")
    func closedMeetingCorrelation() async throws {
        let (ingestor, database, _) = try await makeIngestor()
        // Ended 5 min ago; the batch captured now falls inside the ±10-min pad.
        let meeting = try await slackMeeting(
            database, code: "slack:CLOSED",
            startedAt: slackNow.addingTimeInterval(-1800),
            endedAt: slackNow.addingTimeInterval(-300), status: .ready)
        await ingestor.ingest(batch: rosterBatch(
            code: "slack:CLOSED",
            roster: [MeetWireParticipant(displayName: "Cara", participantID: "U_C", isSelf: false)]))
        #expect(try await pendingRoster(database, meeting.id) == ["Cara"])
    }

    @Test("an uncorrelated non-heartbeat batch stores pending; a heartbeat does not")
    func pendingStoreRules() async throws {
        let (ingestor, database, signals) = try await makeIngestor()
        // No meeting with this code.
        await ingestor.ingest(batch: rosterBatch(
            code: "slack:ORPHAN",
            roster: [MeetWireParticipant(displayName: "Dana", participantID: "U_D", isSelf: false)]))
        #expect(try database.count("meet_events_pending") == 1)
        // A heartbeat-only batch is content-free: not stored, but still forwarded.
        await ingestor.ingest(batch: rosterBatch(
            code: "slack:ORPHAN", capturedAt: slackNow.addingTimeInterval(1),
            roster: [], lifecycle: MeetWireLifecycle(kind: .heartbeat, atMs: ms(slackNow) + 1000)))
        #expect(try database.count("meet_events_pending") == 1)
        #expect(await waitUntil { signals.all.count == 2 })
    }
}
