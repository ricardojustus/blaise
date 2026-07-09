import CryptoKit
import Foundation
import GRDB
import Synchronization
import Testing

@testable import BlaiseCore

// C10 listener contract tests — every obligation of
// docs/meet_events_contract.md, consuming the C12 golden fixtures
// (extension/test/fixtures/wire_batch_golden.json + expected_ingestion.json)
// as the executable cross-chunk contract.

// MARK: - Golden fixture loading

struct GoldenWire: Codable {
    struct Delivery: Codable {
        let iv: String
        let ciphertext: String
    }

    let testSecret: String
    let aad: String
    let ackHeader: String
    let deliveries: [Delivery]
}

struct GoldenExpectation: Codable {
    struct RosterEntry: Codable {
        let displayName: String
        let participantID: String?
        let isSelf: Bool
    }

    let meetingCode: String
    let selfSubstitutionName: String
    let expectedRoster: [RosterEntry]
    let activeSpeakerEvents: [ActiveSpeakerEvent]
}

enum MeetGolden {
    static var wire: GoldenWire {
        get throws {
            try JSONDecoder().decode(
                GoldenWire.self,
                from: Data(contentsOf: VocabFixtures.repoRoot.appendingPathComponent(
                    "extension/test/fixtures/wire_batch_golden.json")))
        }
    }

    static var expectation: GoldenExpectation {
        get throws {
            try JSONDecoder().decode(
                GoldenExpectation.self,
                from: Data(contentsOf: VocabFixtures.repoRoot.appendingPathComponent(
                    "extension/test/fixtures/expected_ingestion.json")))
        }
    }

    /// "now" inside the golden's freshness window (capturedAtMs = batch capture).
    static var goldenNow: Date {
        Date(timeIntervalSince1970: 1_781_136_000)  // == capturedAtMs / 1000
    }
}

// MARK: - Harness

struct MeetHarness {
    let database: BlaiseDatabase
    let secrets: InMemorySecretStore
    let ingestor: MeetEventsIngestor

    func envelopeBody(_ delivery: GoldenWire.Delivery) -> Data {
        try! JSONEncoder().encode(MeetWireEnvelope(iv: delivery.iv, ciphertext: delivery.ciphertext))
    }

    func storedEvents(_ meetingID: MeetingID) async throws -> [ActiveSpeakerEvent] {
        try await MeetEventsRepository(database: database).activeSpeakerEvents(meetingID: meetingID)
    }

    func pendingCount() async throws -> Int {
        try database.count("meet_events_pending")
    }

    /// Queued roster names awaiting absorption by the next content run.
    func pendingRosterNames(_ meetingID: MeetingID) async throws -> [String] {
        try await database.pool.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT display_name FROM meet_roster_pending
                    WHERE meeting_id = ? ORDER BY display_name
                    """,
                arguments: [meetingID])
        }
    }
}

/// A meeting whose window covers the golden events (code abc-defg-hij).
@discardableResult
func makeGoldenMeeting(
    _ database: BlaiseDatabase,
    code: String? = "abc-defg-hij",
    startedAt: Date = Date(timeIntervalSince1970: 1_781_134_800),  // events start ~3 min later
    endedAt: Date? = Date(timeIntervalSince1970: 1_781_138_400),
    status: MeetingStatus = .processing
) async throws -> Meeting {
    var meeting = makeMeeting(startedAt: startedAt, status: status)
    meeting.endedAt = endedAt
    meeting.meetingCode = code
    try await MeetingRepository(database: database).create(meeting)
    return meeting
}

func makeMeetHarness(
    session: any RecordingSessionProviding = NoRecordingSessionProvider(),
    dispatcher: any ProcessingDispatching = NoopProcessingDispatcher(),
    now: @escaping @Sendable () -> Date = { MeetGolden.goldenNow },
    midResponseHook: (@Sendable () throws -> Void)? = nil,
    selfName: String = "Conta Local"
) async throws -> MeetHarness {
    let database = try makeDatabase()
    let secrets = InMemorySecretStore()
    let wire = try MeetGolden.wire
    try secrets.set(key: MeetEventsSecret.secretStoreKey, value: wire.testSecret)
    try await SettingsStore(database: database).set(
        UserIdentity.settingsKey,
        to: UserIdentity(name: selfName, aliases: [], email: "local@example.com"))
    let ingestor = MeetEventsIngestor(
        database: database, secrets: secrets, session: session, dispatcher: dispatcher, now: now,
        midResponseHook: midResponseHook)
    return MeetHarness(database: database, secrets: secrets, ingestor: ingestor)
}

/// Records post-ready dispatches (the H-1 seam under test).
final class RecordingDispatcher: ProcessingDispatching, @unchecked Sendable {
    let ids = Mutex<[MeetingID]>([])

    func dispatch(meetingID: MeetingID) async {
        ids.withLock { $0.append(meetingID) }
    }

    var dispatched: [MeetingID] { ids.withLock { $0 } }
}

/// Test-only: drives the real pipeline synchronously (the pre-F1-Inc2 listener
/// seam behavior). In production the listener routes through the durable queue
/// (`QueueProcessingDispatcher`); this adapter lets the end-to-end
/// roster-absorption test still exercise a real regenerate run without spinning
/// up a worker. The AC9 admission guard scans app/Sources only, so a test-only
/// direct caller is fine.
struct DirectPipelineDispatcher: ProcessingDispatching, @unchecked Sendable {
    let pipeline: ProcessingPipeline
    func dispatch(meetingID: MeetingID) async {
        _ = try? await pipeline.dispatchProcessing(meetingID: meetingID, refuseCancelled: true)
    }
}

func expectedAck(secret: String, iv: String, status: Int) -> String {
    let key = SymmetricKey(data: SHA256.hash(data: Data((secret + "ack").utf8)))
    let mac = HMAC<SHA256>.authenticationCode(
        for: Data(("ack-v1:" + iv + ":" + String(status)).utf8), using: key)
    return Data(mac).base64EncodedString()
}

// MARK: - Migration v4 shape

@Suite struct MigrationV4Tests {
    @Test func v4TablesAndColumnsExist() throws {
        let database = try makeDatabase()
        let tables = try database.tableNames()
        #expect(tables.contains("meet_events_pending"))
        #expect(tables.contains("meet_seen_event_id"))
        #expect(tables.contains("meeting_speaker_event"))

        try database.pool.read { db in
            let meetingColumns = try db.columns(in: "meeting").map(\.name)
            #expect(meetingColumns.contains("meeting_code"))

            let pending = try db.columns(in: "meet_events_pending").map(\.name)
            #expect(Set(pending).isSuperset(of: [
                "id", "meeting_code", "batch_json", "batch_digest", "captured_at_ms", "received_at",
            ]))

            let seen = try db.columns(in: "meet_seen_event_id").map(\.name)
            #expect(Set(seen) == ["meeting_id", "event_id"])
            let seenPK = try db.primaryKey("meet_seen_event_id")
            #expect(seenPK.columns == ["meeting_id", "event_id"])

            let events = try db.columns(in: "meeting_speaker_event").map(\.name)
            #expect(Set(events).isSuperset(of: [
                "meeting_id", "dedupe_id", "display_name", "participant_id", "is_self",
                "start_epoch_ms", "end_epoch_ms",
            ]))
        }
    }

    @Test func speakerEventDedupeIsUniquePerMeeting() async throws {
        let database = try makeDatabase()
        let meeting = try await makeGoldenMeeting(database)
        try await database.pool.write { db in
            for _ in 0 ..< 2 {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO meeting_speaker_event
                            (meeting_id, dedupe_id, display_name, participant_id, is_self,
                             start_epoch_ms, end_epoch_ms)
                        VALUES (?, 'k:1:2', 'A', NULL, 0, 1, 2)
                        """,
                    arguments: [meeting.id])
            }
        }
        #expect(try database.count("meeting_speaker_event") == 1)
    }

    @Test func v5RosterPendingShapeAndDedupe() async throws {
        let database = try makeDatabase()
        #expect(try database.tableNames().contains("meet_roster_pending"))
        try await database.pool.read { db in
            let columns = try db.columns(in: "meet_roster_pending").map(\.name)
            #expect(Set(columns).isSuperset(of: [
                "id", "meeting_id", "display_name", "display_name_folded", "participant_id",
                "is_self",
            ]))
        }
        // UNIQUE(meeting_id, display_name_folded): same folded name queues once.
        let meeting = try await makeGoldenMeeting(database)
        try await database.pool.write { db in
            for name in ["María Silva", "maria silva"] {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO meet_roster_pending
                            (meeting_id, display_name, display_name_folded, participant_id, is_self)
                        VALUES (?, ?, 'maria silva', NULL, 0)
                        """,
                    arguments: [meeting.id, name])
            }
        }
        #expect(try database.count("meet_roster_pending") == 1)
    }

    @Test func pendingBatchDigestIsUnique() async throws {
        let database = try makeDatabase()
        try await database.pool.write { db in
            for _ in 0 ..< 2 {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO meet_events_pending
                            (meeting_code, batch_json, batch_digest, captured_at_ms, received_at)
                        VALUES ('abc', '{}', 'digest-1', 1, ?)
                        """,
                    arguments: [Date()])
            }
        }
        #expect(try database.count("meet_events_pending") == 1)
    }
}

// MARK: - Crypto + acks

@Suite struct MeetEventsCryptoTests {
    @Test func decryptsGoldenDelivery() throws {
        let wire = try MeetGolden.wire
        #expect(wire.aad == MeetEventsCrypto.aad)
        #expect(wire.ackHeader == MeetEventsCrypto.ackHeader)
        let plaintext = try MeetEventsCrypto.decrypt(
            MeetWireEnvelope(iv: wire.deliveries[0].iv, ciphertext: wire.deliveries[0].ciphertext),
            secret: wire.testSecret)
        let batch = try JSONDecoder().decode(MeetWireBatch.self, from: plaintext)
        #expect(batch.meetingCode == "abc-defg-hij")
        #expect(batch.schemaVersion == 1)
        #expect(batch.events.count == 4)
        #expect(batch.roster.count == 4)
    }

    @Test func decryptRejectsWrongSecret() throws {
        let wire = try MeetGolden.wire
        #expect(throws: MeetEventsCryptoError.decryptFailed) {
            try MeetEventsCrypto.decrypt(
                MeetWireEnvelope(iv: wire.deliveries[0].iv, ciphertext: wire.deliveries[0].ciphertext),
                secret: String(repeating: "0", count: 64))
        }
    }

    @Test func ackSignatureIsStatusAndMessageBound() throws {
        let wire = try MeetGolden.wire
        let iv = wire.deliveries[0].iv
        let signature = MeetEventsCrypto.ackSignature(secret: wire.testSecret, ivBase64: iv, status: 200)
        // Independent recomputation matches.
        #expect(signature == expectedAck(secret: wire.testSecret, iv: iv, status: 200))
        // Wrong status → different signature (a squatter cannot upgrade a 401 to a 200).
        #expect(signature != MeetEventsCrypto.ackSignature(secret: wire.testSecret, ivBase64: iv, status: 401))
        // Wrong key → different signature.
        #expect(signature != expectedAck(secret: String(repeating: "1", count: 64), iv: iv, status: 200))
        // Wrong IV (message binding).
        #expect(signature != MeetEventsCrypto.ackSignature(secret: wire.testSecret, ivBase64: "AAAA", status: 200))
    }

    @Test func dedupeIDMatchesContractFormula() {
        let withPid = MeetWireEvent(
            displayName: "Maria Silva", participantID: "pid-2", isSelf: false,
            startEpochMillis: 10000, endEpochMillis: 12000)
        #expect(withPid.dedupeID(meetingCode: "abc-defg-hij") == "abc-defg-hij:pid-2:10000:12000")
        let nameKeyed = MeetWireEvent(
            displayName: "Maria Silva", participantID: nil, isSelf: false,
            startEpochMillis: 1, endEpochMillis: 2)
        #expect(nameKeyed.dedupeID(meetingCode: "abc-defg-hij") == "abc-defg-hij:Maria Silva:1:2")
        let selfKeyed = MeetWireEvent(
            displayName: nil, participantID: nil, isSelf: true,
            startEpochMillis: 1, endEpochMillis: 2)
        #expect(selfKeyed.dedupeID(meetingCode: "abc-defg-hij") == "abc-defg-hij:self:1:2")
    }
}

// MARK: - Golden ingestion (the cross-chunk contract)

@Suite struct MeetEventsGoldenTests {
    @Test func goldenBatchIngestsExactlyOnceDespiteReplay() async throws {
        let harness = try await makeMeetHarness()
        let meeting = try await makeGoldenMeeting(harness.database)
        let wire = try MeetGolden.wire
        let expectation = try MeetGolden.expectation

        // Delivery 1: 200 with a valid signed ack, after durable commit.
        let first = await harness.ingestor.handle(body: harness.envelopeBody(wire.deliveries[0]))
        #expect(first.status == 200)
        #expect(first.ackHeaderValue == expectedAck(secret: wire.testSecret, iv: wire.deliveries[0].iv, status: 200))

        // Delivery 2 is a byte-identical REPLAY: 200-acked, not ingested anew.
        let second = await harness.ingestor.handle(body: harness.envelopeBody(wire.deliveries[1]))
        #expect(second.status == 200)

        // Stored events == expected_ingestion.json's activeSpeakerEvents,
        // each event ONCE (post-substitution display_name, snake_case form).
        let stored = try await harness.storedEvents(meeting.id)
        #expect(stored == expectation.activeSpeakerEvents)

        // isSelf substitution: the self event carries UserIdentity.name.
        #expect(stored.contains { $0.displayName == expectation.selfSubstitutionName })

        // Roster: non-self entries queue ONCE in meet_roster_pending (silent
        // attendee included; the user is not his own attendee) — ingestion
        // never mutates the meeting row (H-1); the next content run absorbs
        // the queued names into attendees as .meetExtension.
        let queued = try await harness.pendingRosterNames(meeting.id)
        let expectedNames = expectation.expectedRoster.filter { !$0.isSelf }.map(\.displayName).sorted()
        #expect(queued == expectedNames)
        #expect(!queued.contains(expectation.selfSubstitutionName))
        let row = try #require(try await MeetingRepository(database: harness.database).fetch(meeting.id))
        #expect(row.attendees.isEmpty)  // untouched at ingest
        #expect(row.updatedAt == meeting.updatedAt)  // no bump at ingest
    }

    @Test func crashBetweenCommitAndRespondRetriesToDeduped200() async throws {
        // The hook throws ONCE after the ingest transaction commits — the
        // extension sees a 5xx (network-class → ring retry); the retried
        // byte-identical batch must get a deduped 200, events exactly once.
        let shouldCrash = Mutex(true)
        let harness = try await makeMeetHarness(midResponseHook: {
            let crash = shouldCrash.withLock { value -> Bool in
                let was = value
                value = false
                return was
            }
            if crash { throw TestFailure() }
        })
        let meeting = try await makeGoldenMeeting(harness.database)
        let wire = try MeetGolden.wire

        let first = await harness.ingestor.handle(body: harness.envelopeBody(wire.deliveries[0]))
        #expect(first.status == 500)

        let retried = await harness.ingestor.handle(body: harness.envelopeBody(wire.deliveries[0]))
        #expect(retried.status == 200)
        let stored = try await harness.storedEvents(meeting.id)
        #expect(stored == (try MeetGolden.expectation.activeSpeakerEvents))
    }
}

// MARK: - Status semantics

@Suite struct MeetEventsStatusTests {
    @Test func badSecretGets401WithSignedAck() async throws {
        let harness = try await makeMeetHarness()
        try harness.secrets.set(key: MeetEventsSecret.secretStoreKey, value: String(repeating: "f", count: 64))
        let wire = try MeetGolden.wire
        let response = await harness.ingestor.handle(body: harness.envelopeBody(wire.deliveries[0]))
        #expect(response.status == 401)
        // The 401 ack is signed with the listener's CURRENT secret.
        #expect(response.ackHeaderValue
            == expectedAck(secret: String(repeating: "f", count: 64), iv: wire.deliveries[0].iv, status: 401))
    }

    @Test func missingSecretGets401Unsigned() async throws {
        let harness = try await makeMeetHarness()
        try harness.secrets.delete(key: MeetEventsSecret.secretStoreKey)
        let wire = try MeetGolden.wire
        let response = await harness.ingestor.handle(body: harness.envelopeBody(wire.deliveries[0]))
        #expect(response.status == 401)
        #expect(response.ackHeaderValue == nil)
    }

    @Test func garbageBodyGets401NotCrash() async throws {
        let harness = try await makeMeetHarness()
        let response = await harness.ingestor.handle(body: Data("not json".utf8))
        #expect(response.status == 401)
    }

    /// 400 is reserved for true schema garbage: decrypts, but the plaintext
    /// is structurally unusable. Built by re-encrypting a broken batch with
    /// the golden secret (round-trip through the same pinned parameters).
    @Test func schemaGarbageGets400() async throws {
        let harness = try await makeMeetHarness()
        let wire = try MeetGolden.wire
        for garbage in ["{\"nope\": true}", "[1,2,3]"] {
            let envelope = try encrypt(plaintext: garbage, secret: wire.testSecret)
            let response = await harness.ingestor.handle(body: try JSONEncoder().encode(envelope))
            #expect(response.status == 400)
        }
        // Wrong schemaVersion → 400 too (never silently misread).
        let plaintext = try String(
            decoding: MeetEventsCrypto.decrypt(
                MeetWireEnvelope(iv: wire.deliveries[0].iv, ciphertext: wire.deliveries[0].ciphertext),
                secret: wire.testSecret),
            as: UTF8.self
        ).replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":99")
        let response = await harness.ingestor.handle(
            body: try JSONEncoder().encode(try encrypt(plaintext: plaintext, secret: wire.testSecret)))
        #expect(response.status == 400)
        #expect(try await harness.pendingCount() == 0)
    }

    @Test func staleBatchIsAcked200AndDropped() async throws {
        // now = 49 h after capture → outside ±48 h: 200, nothing stored.
        let harness = try await makeMeetHarness(
            now: { MeetGolden.goldenNow.addingTimeInterval(49 * 3600) })
        let meeting = try await makeGoldenMeeting(harness.database)
        let wire = try MeetGolden.wire
        let response = await harness.ingestor.handle(body: harness.envelopeBody(wire.deliveries[0]))
        #expect(response.status == 200)
        #expect(try await harness.storedEvents(meeting.id).isEmpty)
        #expect(try await harness.pendingCount() == 0)
    }

    @Test func withinWindowBatchIngests() async throws {
        // 47 h after capture: still fresh.
        let harness = try await makeMeetHarness(
            now: { MeetGolden.goldenNow.addingTimeInterval(47 * 3600) })
        let meeting = try await makeGoldenMeeting(harness.database)
        let wire = try MeetGolden.wire
        let response = await harness.ingestor.handle(body: harness.envelopeBody(wire.deliveries[0]))
        #expect(response.status == 200)
        #expect(try await harness.storedEvents(meeting.id).count == 4)
    }
}

// MARK: - Identity (denylist + participantID merge)

@Suite struct MeetEventsIdentityTests {
    @Test func localizedSelfDenylistTreatsNamesAsSelf() {
        for label in ["You", "Você", "you", "você"] {
            let batch = MeetWireBatch(
                meetingCode: "abc-defg-hij", capturedAtMs: 0, droppedCount: 0, poisonedCount: 0,
                roster: [MeetWireParticipant(displayName: label, isSelf: false)],
                events: [
                    MeetWireEvent(
                        displayName: label, isSelf: false, startEpochMillis: 0, endEpochMillis: 1000)
                ],
                schemaVersion: 1)
            let normalized = MeetEventsIngestor.normalize(batch, userName: "Sam")
            #expect(normalized.events[0].isSelf)
            #expect(normalized.events[0].displayName == "Sam")
            #expect(normalized.rosterNames.isEmpty)  // self never becomes an attendee
        }
    }

    @Test("G3 AC2: empty (pre-onboarding) identity → self event stays nameless, not empty-named")
    func selfEventStaysNamelessWithEmptyIdentity() {
        // A pre-onboarding user has no name to substitute. The self event must
        // resolve to NIL display name (nameless) rather than the empty string,
        // so downstream "You"/null handling fires instead of an empty label.
        let batch = MeetWireBatch(
            meetingCode: "abc-defg-hij", capturedAtMs: 0, droppedCount: 0, poisonedCount: 0,
            roster: [MeetWireParticipant(displayName: "You", isSelf: false)],
            events: [
                MeetWireEvent(
                    displayName: "You", isSelf: false, startEpochMillis: 0, endEpochMillis: 1000)
            ],
            schemaVersion: 1)
        let normalized = MeetEventsIngestor.normalize(batch, userName: "")
        #expect(normalized.events[0].isSelf)
        #expect(normalized.events[0].displayName == nil)  // nameless, NOT ""
        #expect(normalized.rosterNames.isEmpty)
    }

    @Test func participantIDMergePrefersNamedFormAndOrsSelfFlag() {
        // A panel self row arriving as an ordinary NAMED participant (missed
        // tile link) + an unnamed self event sharing the participantID: the
        // merge resolves both to self, and the unnamed non-self event gains
        // the merged name.
        let batch = MeetWireBatch(
            meetingCode: "abc-defg-hij", capturedAtMs: 0, droppedCount: 0, poisonedCount: 0,
            roster: [
                MeetWireParticipant(displayName: "Sam J", participantID: "pid-9", isSelf: false),
                MeetWireParticipant(displayName: "Maria Silva", participantID: "pid-2", isSelf: false),
            ],
            events: [
                MeetWireEvent(
                    displayName: nil, participantID: "pid-9", isSelf: true,
                    startEpochMillis: 0, endEpochMillis: 1000),
                MeetWireEvent(
                    displayName: nil, participantID: "pid-2", isSelf: false,
                    startEpochMillis: 2000, endEpochMillis: 3000),
            ],
            schemaVersion: 1)
        let normalized = MeetEventsIngestor.normalize(batch, userName: "Sam")
        #expect(normalized.events[0].isSelf)
        #expect(normalized.events[0].displayName == "Sam")  // substitution, not "Sam J"
        #expect(normalized.events[1].displayName == "Maria Silva")  // merged name
        // The self-merged roster identity is skipped from attendees.
        #expect(normalized.rosterNames == ["Maria Silva"])
    }

    @Test func namelessEventIsSeenButCannotVote() async throws {
        let harness = try await makeMeetHarness()
        let meeting = try await makeGoldenMeeting(harness.database)
        let wire = try MeetGolden.wire
        let batch = MeetWireBatch(
            meetingCode: "abc-defg-hij",
            capturedAtMs: Int64(MeetGolden.goldenNow.timeIntervalSince1970 * 1000),
            droppedCount: 0, poisonedCount: 0,
            roster: [],
            events: [
                MeetWireEvent(
                    displayName: nil, participantID: "pid-x", isSelf: false,
                    startEpochMillis: 1_781_135_000_000, endEpochMillis: 1_781_135_002_000)
            ],
            schemaVersion: 1)
        let body = try JSONEncoder().encode(
            try encrypt(plaintext: String(decoding: JSONEncoder().encode(batch), as: UTF8.self),
                        secret: wire.testSecret))
        let response = await harness.ingestor.handle(body: body)
        #expect(response.status == 200)
        #expect(try await harness.storedEvents(meeting.id).isEmpty)
        #expect(try harness.database.count("meet_seen_event_id") == 1)
    }
}

// MARK: - Correlation

@Suite struct MeetEventsCorrelationTests {
    @Test func unmatchedBatchStoresPendingOnceAndSweepsOnImport() async throws {
        let harness = try await makeMeetHarness()
        let wire = try MeetGolden.wire

        // No meeting with the code yet → pending (200 after durable store).
        let first = await harness.ingestor.handle(body: harness.envelopeBody(wire.deliveries[0]))
        #expect(first.status == 200)
        #expect(try await harness.pendingCount() == 1)

        // Replayed unmatched batch: UNIQUE(batch_digest) → still one row.
        let replay = await harness.ingestor.handle(body: harness.envelopeBody(wire.deliveries[1]))
        #expect(replay.status == 200)
        #expect(try await harness.pendingCount() == 1)

        // Meeting creation sweep: matched batch ingests atomically and the
        // pending row is removed.
        let meeting = try await makeGoldenMeeting(harness.database)
        await harness.ingestor.sweep(meetingID: meeting.id)
        #expect(try await harness.pendingCount() == 0)
        #expect(try await harness.storedEvents(meeting.id) == (try MeetGolden.expectation.activeSpeakerEvents))
    }

    @Test func recurringCodeTiebreaksByGreatestOverlap() async throws {
        let harness = try await makeMeetHarness()
        // Two meetings share the recurring code; both padded windows touch
        // the events span (≈ 1_781_135_000–021 s) but the second overlaps
        // far more. The LATER-started meeting is the lesser overlap, so a
        // recency shortcut would pick wrong — overlap must decide.
        try await makeGoldenMeeting(
            harness.database,
            startedAt: Date(timeIntervalSince1970: 1_781_134_380),
            endedAt: Date(timeIntervalSince1970: 1_781_134_410))  // padded end cuts the span at +10 s
        let better = try await makeGoldenMeeting(
            harness.database,
            startedAt: Date(timeIntervalSince1970: 1_781_133_000),
            endedAt: Date(timeIntervalSince1970: 1_781_136_400))  // covers the whole span
        let wire = try MeetGolden.wire
        let response = await harness.ingestor.handle(body: harness.envelopeBody(wire.deliveries[0]))
        #expect(response.status == 200)
        #expect(try await harness.storedEvents(better.id).count == 4)
        #expect(try harness.database.count("meeting_speaker_event") == 4)
    }

    @Test func codeMatchOutsideWindowStaysPending() async throws {
        let harness = try await makeMeetHarness()
        // Same code, but a meeting from days before the events.
        try await makeGoldenMeeting(
            harness.database,
            startedAt: Date(timeIntervalSince1970: 1_780_000_000),
            endedAt: Date(timeIntervalSince1970: 1_780_003_600))
        let wire = try MeetGolden.wire
        let response = await harness.ingestor.handle(body: harness.envelopeBody(wire.deliveries[0]))
        #expect(response.status == 200)
        #expect(try await harness.pendingCount() == 1)
        #expect(try harness.database.count("meeting_speaker_event") == 0)
    }

    @Test func liveSessionClaimsBatchOnlyWithEqualNonNilCodes() async throws {
        // Stub session with the matching code: the live meeting wins even
        // though another code-matching meeting exists.
        struct StubSession: RecordingSessionProviding {
            let info: RecordingSessionInfo?
            func currentSession() async -> RecordingSessionInfo? { info }
        }
        let liveID = ULID.generate()
        let harness = try await makeMeetHarness(
            session: StubSession(info: RecordingSessionInfo(meetingID: liveID, meetingCode: "abc-defg-hij")))
        var live = makeMeeting(id: liveID, startedAt: MeetGolden.goldenNow)
        live.meetingCode = "abc-defg-hij"
        try await MeetingRepository(database: harness.database).create(live)
        try await makeGoldenMeeting(harness.database)  // window-matching decoy
        let wire = try MeetGolden.wire
        let response = await harness.ingestor.handle(body: harness.envelopeBody(wire.deliveries[0]))
        #expect(response.status == 200)
        #expect(try await harness.storedEvents(liveID).count == 4)
    }

    @Test func nilCodeSessionNeverClaimsMeetBatches() async throws {
        struct StubSession: RecordingSessionProviding {
            let info: RecordingSessionInfo?
            func currentSession() async -> RecordingSessionInfo? { info }
        }
        let liveID = ULID.generate()
        let harness = try await makeMeetHarness(
            session: StubSession(info: RecordingSessionInfo(meetingID: liveID, meetingCode: nil)))
        var live = makeMeeting(id: liveID, startedAt: MeetGolden.goldenNow)
        try await MeetingRepository(database: harness.database).create(live)
        live.meetingCode = nil
        let matched = try await makeGoldenMeeting(harness.database)
        let wire = try MeetGolden.wire
        let response = await harness.ingestor.handle(body: harness.envelopeBody(wire.deliveries[0]))
        #expect(response.status == 200)
        #expect(try await harness.storedEvents(liveID).isEmpty)
        #expect(try await harness.storedEvents(matched.id).count == 4)
    }

    @Test func nilDefaultSessionProviderReturnsNil() async {
        #expect(await NoRecordingSessionProvider().currentSession() == nil)
    }

    @Test func startupPurgeDiscardsPendingOlderThan7Days() async throws {
        let nowBox = Mutex(MeetGolden.goldenNow)
        let harness = try await makeMeetHarness(now: { nowBox.withLock { $0 } })
        let wire = try MeetGolden.wire
        _ = await harness.ingestor.handle(body: harness.envelopeBody(wire.deliveries[0]))
        #expect(try await harness.pendingCount() == 1)

        // 6 days later: retained.
        nowBox.withLock { $0 = MeetGolden.goldenNow.addingTimeInterval(6 * 24 * 3600) }
        #expect(try await harness.ingestor.purgeStalePending() == 0)
        // 8 days later: discarded.
        nowBox.withLock { $0 = MeetGolden.goldenNow.addingTimeInterval(8 * 24 * 3600) }
        #expect(try await harness.ingestor.purgeStalePending() == 1)
        #expect(try await harness.pendingCount() == 0)
    }
}

// MARK: - Pipeline wiring (stage 8 reads the consumer table)

@Suite struct MeetEventsPipelineWiringTests {
    /// 12 s audio: two diarization clusters of 6 s each so the resolver's
    /// dominance floor (≥ 5 s vote mass) can be met by the stored events.
    static func configureLongMeeting(_ harness: PipelineHarness) {
        harness.asr.state.withLock {
            $0.segments = [
                ASRSegment(startSeconds: 0.2, endSeconds: 5.5, text: "Olá, vamos começar a revisão."),
                ASRSegment(startSeconds: 6.2, endSeconds: 11.5, text: "Perfeito, eu mando o resumo depois."),
            ]
        }
        harness.diarizer.state.withLock {
            $0.output = DiarizationOutput(
                segments: [
                    DiarizedSegment(speakerLabel: "S0", startSeconds: 0.0, endSeconds: 6.0),
                    DiarizedSegment(speakerLabel: "S1", startSeconds: 6.0, endSeconds: 12.0),
                ],
                speakerCount: 2)
        }
    }

    static func twoSpeakerEvents(startMs: Int64) -> [MeetWireEvent] {
        [
            MeetWireEvent(
                displayName: "Maria Silva", participantID: "pid-2", isSelf: false,
                startEpochMillis: startMs, endEpochMillis: startMs + 5900),
            MeetWireEvent(
                displayName: "João Pereira", participantID: "pid-3", isSelf: false,
                startEpochMillis: startMs + 6100, endEpochMillis: startMs + 11900),
        ]
    }

    @Test func storedEventsNameSpeakersThroughStage8() async throws {
        // Ingest a batch into an imported meeting, then run the mock
        // pipeline: stage 8's hints come from meeting_speaker_event and the
        // dominant clusters resolve to the event speakers' names.
        let harness = try await makePipelineHarness()
        Self.configureLongMeeting(harness)
        let secrets = InMemorySecretStore()
        let wire = try MeetGolden.wire
        try secrets.set(key: MeetEventsSecret.secretStoreKey, value: wire.testSecret)

        let wav = harness.dataRoot.appendingPathComponent("stage8-\(UUID().uuidString).wav")
        try writeTestWAV(to: wav, seconds: 12)
        let meeting = try await harness.pipeline.importMeeting(
            sourceURL: wav, title: "Stage 8 wiring", startedAt: msDate(), meetingCode: "xyz-meet-001")

        let startMs = Int64(meeting.startedAt.timeIntervalSince1970 * 1000)
        let batch = MeetWireBatch(
            meetingCode: "xyz-meet-001",
            capturedAtMs: startMs,
            droppedCount: 0, poisonedCount: 0,
            roster: [],
            events: Self.twoSpeakerEvents(startMs: startMs),
            schemaVersion: 1)
        let ingestor = MeetEventsIngestor(
            database: harness.database, secrets: secrets,
            now: { meeting.startedAt })
        try await ingestor.ingest(batch: batch, into: meeting.id, pendingRowID: nil)

        _ = try await harness.pipeline.process(meetingID: meeting.id)
        let segments = try await harness.segments(meeting.id)
        let names = Set(segments.compactMap(\.speakerName))
        #expect(names.contains("Maria Silva"))
        #expect(names.contains("João Pereira"))
    }

    @Test func runEntrySweepsPendingEvents() async throws {
        // An unmatched batch arrives BEFORE the meeting exists; importing a
        // meeting with the code and processing it sweeps + names speakers.
        let harness = try await makePipelineHarness()
        Self.configureLongMeeting(harness)
        let secrets = InMemorySecretStore()
        let wire = try MeetGolden.wire
        try secrets.set(key: MeetEventsSecret.secretStoreKey, value: wire.testSecret)

        let startedAt = msDate()
        let startMs = Int64(startedAt.timeIntervalSince1970 * 1000)
        let batch = MeetWireBatch(
            meetingCode: "xyz-meet-002",
            capturedAtMs: startMs,
            droppedCount: 0, poisonedCount: 0,
            roster: [MeetWireParticipant(displayName: "Maria Silva", participantID: "pid-2", isSelf: false)],
            events: Array(Self.twoSpeakerEvents(startMs: startMs).prefix(1)),
            schemaVersion: 1)
        let ingestor = MeetEventsIngestor(
            database: harness.database, secrets: secrets, now: { startedAt })
        let body = try JSONEncoder().encode(
            try encrypt(plaintext: String(decoding: JSONEncoder().encode(batch), as: UTF8.self),
                        secret: wire.testSecret))
        let response = await ingestor.handle(body: body)
        #expect(response.status == 200)

        // Pipeline with the REAL sweeper wired (composition-root shape).
        let pipeline = ProcessingPipeline(
            database: harness.database,
            registry: try EngineRegistry(asr: [harness.asr], summarization: [harness.notesPrimary]),
            diarizer: harness.diarizer,
            vocabulary: try VocabFixtures.pipelineVocabulary(),
            meetEventsSweeper: ingestor,
            tempDirectory: harness.tempDir,
            now: { startedAt })
        let wav = harness.dataRoot.appendingPathComponent("sweep-\(UUID().uuidString).wav")
        try writeTestWAV(to: wav, seconds: 12)
        let meeting = try await pipeline.importMeeting(
            sourceURL: wav, title: "Sweep test", startedAt: startedAt, meetingCode: "xyz-meet-002")
        _ = try await pipeline.process(meetingID: meeting.id)

        #expect(try harness.database.count("meet_events_pending") == 0)
        let segments = try await harness.segments(meeting.id)
        #expect(segments.compactMap(\.speakerName).contains("Maria Silva"))
        // Roster merge reached attendees.
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.attendees.contains { $0.name == "Maria Silva" && $0.source == .meetExtension })
    }
}

// MARK: - Post-ready ingestion (H-1: ingestion never mutates the meeting row)

/// Finalizes the golden meeting through the real mint path: builds the
/// canonical payload from the STORED row, writes it immutably, and runs
/// `finalizeMeetingProcessing` → `ready` with a queued handoff row.
func finalizeGoldenMeeting(
    _ database: BlaiseDatabase, meetingID: MeetingID, user: UserIdentity = .onboardedUser
) async throws -> HandoffItem {
    guard let stored = try await MeetingRepository(database: database).fetch(meetingID) else {
        throw TestFailure()
    }
    let notes = makeNotes(meetingID: meetingID)
    let payload = EvidencePayloadBuilder.build(
        meeting: stored, segments: [], notes: notes, user: user)
    let relative = database.paths.relativeHandoffPayloadPath(
        meetingID: meetingID, versionHash: payload.versionHash)
    try database.paths.createMeetingDirectory(meetingID)
    try ImmutablePayloadWriter.write(
        payload.bytes, to: database.rootURL.appendingPathComponent(relative))
    return try await database.finalizeMeetingProcessing(
        meetingID: meetingID, versionHash: payload.versionHash, payloadPath: relative, notes: notes)
}

@Suite struct MeetEventsReadyMeetingTests {
    /// The audit probe, inverted (H-1 regression): ingesting a batch into a
    /// `ready` meeting must leave every payload-builder input untouched — a
    /// payload rebuilt from durable state still hash-equals the enqueued
    /// version_hash (C8 re-materialization recovery stays possible).
    @Test func ingestIntoReadyMeetingKeepsRebuiltPayloadHashEqual() async throws {
        let harness = try await makeMeetHarness()
        let meeting = try await makeGoldenMeeting(harness.database)
        let item = try await finalizeGoldenMeeting(harness.database, meetingID: meeting.id)

        // Arrival-time ingest of the golden batch (events + roster names).
        let response = await harness.ingestor.handle(
            body: harness.envelopeBody(try MeetGolden.wire.deliveries[0]))
        #expect(response.status == 200)
        #expect(try await harness.storedEvents(meeting.id).count == 4)

        // Rebuild from durable state — must still hash-equal the stored row.
        let after = try #require(try await MeetingRepository(database: harness.database).fetch(meeting.id))
        let notes = try #require(try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id))
        let segments = try await TranscriptRepository(database: harness.database).segments(meetingID: meeting.id)
        let rebuilt = EvidencePayloadBuilder.build(
            meeting: after, segments: segments, notes: notes, user: .onboardedUser)
        #expect(rebuilt.versionHash == item.versionHash)
    }

    /// H-1 second half: arrival-time content landing on a `ready` meeting
    /// fires the status-dependent dispatch exactly once — a byte-identical
    /// replay adds nothing and never re-fires.
    @Test func postReadyIngestFiresStatusDependentDispatchOnce() async throws {
        let dispatcher = RecordingDispatcher()
        let harness = try await makeMeetHarness(dispatcher: dispatcher)
        let meeting = try await makeGoldenMeeting(harness.database)
        _ = try await finalizeGoldenMeeting(harness.database, meetingID: meeting.id)

        let wire = try MeetGolden.wire
        let first = await harness.ingestor.handle(body: harness.envelopeBody(wire.deliveries[0]))
        #expect(first.status == 200)
        #expect(await waitUntil { dispatcher.dispatched == [meeting.id] })

        let replay = await harness.ingestor.handle(body: harness.envelopeBody(wire.deliveries[1]))
        #expect(replay.status == 200)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(dispatcher.dispatched == [meeting.id])
    }

    /// Pre-ready ingest never dispatches: the batch's content reaches the
    /// run that is still to come (run-entry sweep/absorption), not a re-run.
    @Test func preReadyIngestNeverDispatches() async throws {
        let dispatcher = RecordingDispatcher()
        let harness = try await makeMeetHarness(dispatcher: dispatcher)
        _ = try await makeGoldenMeeting(harness.database)  // status .processing
        let wire = try MeetGolden.wire
        let response = await harness.ingestor.handle(body: harness.envelopeBody(wire.deliveries[0]))
        #expect(response.status == 200)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(dispatcher.dispatched.isEmpty)
    }

    /// (c) end to end with the real (mock-engine) pipeline as dispatcher:
    /// post-ready ingest → regenerate fires → the run absorbs the queued
    /// roster into attendees (.meetExtension) → the NEW payload embeds the
    /// attendee and still rebuilds hash-equal from durable state.
    @Test func postReadyRosterIsAbsorbedByTheDispatchedRegenerateIntoTheNewPayload() async throws {
        let harness = try await makePipelineHarness()
        let secrets = InMemorySecretStore()
        let wire = try MeetGolden.wire
        try secrets.set(key: MeetEventsSecret.secretStoreKey, value: wire.testSecret)

        let wav = harness.dataRoot.appendingPathComponent("ready-\(UUID().uuidString).wav")
        try writeTestWAV(to: wav)
        let meeting = try await harness.pipeline.importMeeting(
            sourceURL: wav, title: "Post-ready ingest", startedAt: msDate(),
            meetingCode: "xyz-meet-009")
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        #expect(try await harness.queueRows(meeting.id) == 1)

        let ingestor = MeetEventsIngestor(
            database: harness.database, secrets: secrets,
            dispatcher: DirectPipelineDispatcher(pipeline: harness.pipeline),
            now: { msDate() })
        let startMs = Int64(msDate().timeIntervalSince1970 * 1000)
        let batch = MeetWireBatch(
            meetingCode: "xyz-meet-009", capturedAtMs: startMs, droppedCount: 0, poisonedCount: 0,
            roster: [
                MeetWireParticipant(displayName: "Maria Silva", participantID: "pid-2", isSelf: false)
            ],
            events: [
                MeetWireEvent(
                    displayName: "Maria Silva", participantID: "pid-2", isSelf: false,
                    startEpochMillis: startMs, endEpochMillis: startMs + 1500)
            ],
            schemaVersion: 1)
        let body = try JSONEncoder().encode(
            try encrypt(
                plaintext: String(decoding: JSONEncoder().encode(batch), as: UTF8.self),
                secret: wire.testSecret))
        let response = await ingestor.handle(body: body)
        #expect(response.status == 200)

        // The fire-and-forget dispatch regenerates and re-mints (supersession
        // of the old row happens at delivery, not enqueue).
        #expect(try await waitUntil { try await harness.queueRows(meeting.id) == 2 })
        let after = try #require(try await harness.meeting(meeting.id))
        #expect(after.status == .ready)
        #expect(after.attendees.contains { $0.name == "Maria Silva" && $0.source == .meetExtension })
        #expect(try harness.database.count("meet_roster_pending") == 0)

        // Newest queue row: payload embeds the absorbed attendee and the
        // rebuilt-from-durable-state hash still equals its version_hash.
        let newest = try #require(
            try await HandoffRepository(database: harness.database).allItems().last)
        let bytes = try Data(
            contentsOf: harness.database.rootURL.appendingPathComponent(newest.payloadPath))
        #expect(String(decoding: bytes, as: UTF8.self).contains("Maria Silva"))
        let notes = try #require(
            try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id))
        let segments = try await TranscriptRepository(database: harness.database)
            .segments(meetingID: meeting.id)
        let rebuilt = EvidencePayloadBuilder.build(
            meeting: after, segments: segments, notes: notes, user: .onboardedUser)
        #expect(rebuilt.versionHash == newest.versionHash)
    }

    /// (d) `meetingCode` is correlation metadata, not content: the edit never
    /// bumps `updatedAt` (C1 semantics, amended v6.7).
    @Test func setMeetingCodeLeavesUpdatedAtUnchanged() async throws {
        let database = try makeDatabase()
        let repository = MeetingRepository(database: database)
        let meeting = makeMeeting()
        try await repository.create(meeting)
        try await repository.setMeetingCode(meeting.id, to: "abc-defg-hij")
        let after = try #require(try await repository.fetch(meeting.id))
        #expect(after.meetingCode == "abc-defg-hij")
        #expect(after.updatedAt == meeting.updatedAt)
    }

    /// M-2: the sweep reports the meetings that actually RECEIVED data —
    /// under a recurring code that may not be the edited meeting.
    @Test func sweepReturnsTheMeetingsThatReceivedData() async throws {
        let harness = try await makeMeetHarness()
        let wire = try MeetGolden.wire
        _ = await harness.ingestor.handle(body: harness.envelopeBody(wire.deliveries[0]))
        #expect(try await harness.pendingCount() == 1)

        // The "edited" meeting reuses the recurring code but its window
        // misses the events span entirely; an earlier sibling covers it.
        let edited = try await makeGoldenMeeting(
            harness.database,
            startedAt: Date(timeIntervalSince1970: 1_781_200_000),
            endedAt: Date(timeIntervalSince1970: 1_781_203_600))
        let receiver = try await makeGoldenMeeting(harness.database)

        let receivers = await harness.ingestor.sweep(meetingCode: "abc-defg-hij")
        #expect(receivers == [receiver.id])
        #expect(try await harness.storedEvents(receiver.id).count == 4)
        #expect(try await harness.storedEvents(edited.id).isEmpty)

        // Nothing left pending: a repeat sweep reports no receivers.
        #expect(await harness.ingestor.sweep(meetingCode: "abc-defg-hij") == [])
    }

    /// L-1: exact correlation ties are deterministic by contract — greatest
    /// overlap, then earliest startedAt, then lowest id (never scan order).
    @Test func exactCorrelationTieIsDeterministic() async throws {
        let harness = try await makeMeetHarness()
        let wire = try MeetGolden.wire
        let plaintext = try MeetEventsCrypto.decrypt(
            MeetWireEnvelope(iv: wire.deliveries[0].iv, ciphertext: wire.deliveries[0].ciphertext),
            secret: wire.testSecret)
        let batch = try JSONDecoder().decode(MeetWireBatch.self, from: plaintext)

        // Equal overlap (both windows contain the whole events span),
        // different startedAt → earliest wins.
        let early = try await makeGoldenMeeting(
            harness.database,
            startedAt: Date(timeIntervalSince1970: 1_781_130_000),
            endedAt: Date(timeIntervalSince1970: 1_781_140_000))
        try await makeGoldenMeeting(
            harness.database,
            startedAt: Date(timeIntervalSince1970: 1_781_133_000),
            endedAt: Date(timeIntervalSince1970: 1_781_140_000))
        #expect(try await harness.ingestor.matchMeeting(for: batch) == early.id)

        // Fully identical windows → lowest id wins, stable across runs.
        let tied = try await makeMeetHarness()
        let a = try await makeGoldenMeeting(tied.database)
        let b = try await makeGoldenMeeting(tied.database)
        let expected = min(a.id, b.id)
        for _ in 0 ..< 5 {
            #expect(try await tied.ingestor.matchMeeting(for: batch) == expected)
        }
    }
}

/// Polls a condition until it holds or the timeout lapses (fire-and-forget
/// dispatch assertions).
func waitUntil(
    timeout: Duration = .seconds(10), _ condition: @Sendable () async throws -> Bool
) async rethrows -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if try await condition() { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return try await condition()
}

// MARK: - Field garbage names (live capture 2026-06-11) + listener bind policy

/// Pins the FIELD bug: live Meet (June 2026) shipped icon-ligature +
/// localized-control text as display names. The strings below are VERBATIM
/// from the wire batches captured during meeting abc-defg-hij. The old
/// ingestor stored them as speaker names; sanitized ingestion must extract
/// the embedded real name from pin labels and reject pure junk (nil name,
/// never wrong name).
@Suite struct MeetFieldGarbageNameTests {
    @Test func sanitizerHandlesVerbatimFieldStrings() {
        #expect(
            MeetDisplayNameSanitizer.sanitize("keep_outlineFixar Adrian Cole na tela principal")
                == "Adrian Cole")
        #expect(
            MeetDisplayNameSanitizer.sanitize("Fixar Anna Reyes na tela principal")
                == "Anna Reyes")
        #expect(
            MeetDisplayNameSanitizer.sanitize("Pin Maria Silva to your main screen")
                == "Maria Silva")
        #expect(MeetDisplayNameSanitizer.sanitize("frame_personReenquadrar") == nil)
        #expect(
            MeetDisplayNameSanitizer.sanitize(
                "stylus_laser_pointerFaça anotações (visíveis para todos)arrow_drop_upElas vão aparecer para todos"
            ) == nil)
        #expect(MeetDisplayNameSanitizer.sanitize("Anna Reyes") == "Anna Reyes")
        #expect(MeetDisplayNameSanitizer.sanitize("  Anna Reyes ") == "Anna Reyes")
        #expect(MeetDisplayNameSanitizer.sanitize("") == nil)
        #expect(MeetDisplayNameSanitizer.sanitize(nil) == nil)
    }

    /// Field 2026-06-11 (internal): the scraper also lifted a whole CSS block into
    /// the name position — it carried no underscore, so the ligature gate let
    /// it through and it reached `meeting_speaker_event`/`attendees` and
    /// rendered as "json artifacts". The structural gate rejects markup
    /// metacharacters ({ } : ;) and newlines, and over-length blobs, while
    /// long compound real names still pass.
    @Test func sanitizerRejectsMarkupAndOverLengthJunk() {
        let cssBlock = """
            .ink-canvas-parent {
                      height: 100%;
                      position: relative;
                      width: 100%;
                    }
            """
        #expect(MeetDisplayNameSanitizer.sanitize(cssBlock) == nil)
        #expect(MeetDisplayNameSanitizer.sanitize("<b>Name</b>") == nil)
        #expect(MeetDisplayNameSanitizer.sanitize("display:none;") == nil)
        #expect(MeetDisplayNameSanitizer.sanitize(String(repeating: "x", count: 120)) == nil)
        #expect(
            MeetDisplayNameSanitizer.sanitize("Maria Eduarda da Silva Santos Oliveira")
                == "Maria Eduarda da Silva Santos Oliveira")
    }

    @Test func normalizeSanitizesEventAndRosterNamesButKeepsRawWire() {
        let batch = MeetWireBatch(
            meetingCode: "abc-defg-hij", capturedAtMs: 0, droppedCount: 0, poisonedCount: 0,
            roster: [
                MeetWireParticipant(
                    displayName: nil, participantID: "spaces/x/devices/220", isSelf: false)
            ],
            events: [
                MeetWireEvent(
                    displayName: "keep_outlineFixar Adrian Cole na tela principal",
                    participantID: "spaces/x/devices/220", isSelf: false,
                    startEpochMillis: 0, endEpochMillis: 2000),
                MeetWireEvent(
                    displayName: "frame_personReenquadrar",
                    participantID: "spaces/x/devices/214", isSelf: false,
                    startEpochMillis: 0, endEpochMillis: 2000),
            ],
            schemaVersion: 2)
        let normalized = MeetEventsIngestor.normalize(batch, userName: "Sam")
        // Pin-label garbage → the embedded real name (old behavior: stored verbatim).
        #expect(normalized.events[0].displayName == "Adrian Cole")
        // Pure junk → nil (seen, cannot vote) — never "frame_personReenquadrar".
        #expect(normalized.events[1].displayName == nil)
        // RAW wire fields untouched → dedupe ids stay byte-stable.
        #expect(
            normalized.events[0].wire.dedupeID(meetingCode: "abc-defg-hij")
                == "abc-defg-hij:spaces/x/devices/220:0:2000")
        // The merged identity (pid 220) carries the SANITIZED name into the roster.
        #expect(normalized.rosterNames == ["Adrian Cole"])
    }

    @Test func ingestStoresSanitizedNamesEndToEnd() async throws {
        let harness = try await makeMeetHarness()
        let meeting = try await makeGoldenMeeting(harness.database, code: "abc-defg-hij")
        let capturedAtMs = Int64(MeetGolden.goldenNow.timeIntervalSince1970 * 1000)
        let batch = MeetWireBatch(
            meetingCode: "abc-defg-hij", capturedAtMs: capturedAtMs,
            droppedCount: 0, poisonedCount: 0,
            roster: [],
            events: [
                MeetWireEvent(
                    displayName: "keep_outlineFixar Adrian Cole na tela principal",
                    participantID: "spaces/x/devices/220", isSelf: false,
                    startEpochMillis: capturedAtMs - 5000, endEpochMillis: capturedAtMs - 1000),
                MeetWireEvent(
                    displayName: "frame_personReenquadrar",
                    participantID: "spaces/x/devices/214", isSelf: false,
                    startEpochMillis: capturedAtMs - 5000, endEpochMillis: capturedAtMs - 1000),
            ],
            schemaVersion: 2)
        let secret = try MeetGolden.wire.testSecret
        let plaintext = String(decoding: try JSONEncoder().encode(batch), as: UTF8.self)
        let body = try JSONEncoder().encode(try encrypt(plaintext: plaintext, secret: secret))
        let response = await harness.ingestor.handle(body: body)
        #expect(response.status == 200)
        let stored = try await harness.storedEvents(meeting.id)
        // ONE named event stored with the extracted real name; the junk-only
        // event is seen (deduped) but never stored under a garbage name.
        #expect(stored.map(\.displayName) == ["Adrian Cole"])
        let seenCount = try await harness.database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM meet_seen_event_id")!
        }
        #expect(seenCount == 2)
    }
}

@Suite struct MeetListenerBindPolicyTests {
    // FIELD FAILURE 2026-06-11: BLAISE_DATA_ROOT dev instances squatted the
    // production port and swallowed live batches into throwaway databases.
    @Test func dataRootOverrideForbidsBinding() {
        #expect(MeetEventsListenerPolicy.bindAllowed(environment: [:]))
        #expect(!MeetEventsListenerPolicy.bindAllowed(environment: ["BLAISE_DATA_ROOT": "/tmp/x"]))
        #expect(
            MeetEventsListenerPolicy.bindAllowed(environment: [
                "BLAISE_DATA_ROOT": "/tmp/x", "BLAISE_MEET_LISTENER": "1",
            ]))
        #expect(
            !MeetEventsListenerPolicy.bindAllowed(environment: [
                "BLAISE_DATA_ROOT": "/tmp/x", "BLAISE_MEET_LISTENER": "0",
            ]))
    }
}

// MARK: - Test-side AES-GCM encryption (round-trips the pinned parameters)

func encrypt(plaintext: String, secret: String) throws -> MeetWireEnvelope {
    let key = SymmetricKey(data: SHA256.hash(data: Data(secret.utf8)))
    let nonce = AES.GCM.Nonce()
    let box = try AES.GCM.seal(
        Data(plaintext.utf8), using: key, nonce: nonce,
        authenticating: Data(MeetEventsCrypto.aad.utf8))
    return MeetWireEnvelope(
        iv: Data(nonce).base64EncodedString(),
        ciphertext: (box.ciphertext + box.tag).base64EncodedString())
}
