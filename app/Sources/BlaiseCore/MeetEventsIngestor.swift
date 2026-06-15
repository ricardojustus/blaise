import Foundation
import GRDB
import Synchronization
import os

// C10: ingestion logic for the meet-events listener — every DB-touching
// obligation of docs/meet_events_contract.md, UI-free and fully testable.
// The NWListener HTTP wrapper (BlaiseApp) parses requests, calls
// `MeetEventsIngestor.handle`, and writes the response + signed ack header.

// MARK: - C11 seam

/// The live-recording session seam: C10 ships the nil-returning default;
/// C11 swaps in the real capture session. Live correlation matches the
/// active session FIRST and ONLY when `batch.meetingCode ==
/// session.meetingCode`, both non-nil — a nil-code session (in-person/zoom)
/// never claims Meet batches.
public protocol RecordingSessionProviding: Sendable {
    func currentSession() async -> RecordingSessionInfo?
}

public struct RecordingSessionInfo: Sendable, Equatable {
    public var meetingID: MeetingID
    public var meetingCode: String?

    public init(meetingID: MeetingID, meetingCode: String?) {
        self.meetingID = meetingID
        self.meetingCode = meetingCode
    }
}

/// The C10 default: no live capture exists yet.
public struct NoRecordingSessionProvider: RecordingSessionProviding {
    public init() {}
    public func currentSession() async -> RecordingSessionInfo? { nil }
}

/// Late-binding box (C11): the ingestor is constructed before the
/// `RecordingController` (which needs the pipeline, which needs the
/// ingestor); the composition root closes the cycle by setting the real
/// provider right after it exists. Unset = no live session.
public final class RecordingSessionBox: RecordingSessionProviding, Sendable {
    private let target = Mutex<(any RecordingSessionProviding)?>(nil)

    public init() {}

    public func set(_ provider: any RecordingSessionProviding) {
        target.withLock { $0 = provider }
    }

    public func currentSession() async -> RecordingSessionInfo? {
        let provider = target.withLock { $0 }
        return await provider?.currentSession()
    }
}

// MARK: - C14 signal seam (tracker liveness/lifecycle forwarding)

/// One accepted code-carrying batch as the tracker sees it: a per-batch
/// liveness signal (`capturedAtMs`) plus the lifecycle field when present.
/// Forwarded for EVERY accepted code-carrying batch — correlated or NOT (a
/// declined meeting has no recording to correlate with, and its heartbeats
/// must keep its suppression record alive) — fire-and-forget AFTER the
/// ingest transaction; the signed 200 never waits on it.
public struct MeetCallSignal: Sendable, Equatable {
    public var meetingCode: String
    public var capturedAtMs: Int64
    public var lifecycle: MeetWireLifecycle?

    public init(meetingCode: String, capturedAtMs: Int64, lifecycle: MeetWireLifecycle? = nil) {
        self.meetingCode = meetingCode
        self.capturedAtMs = capturedAtMs
        self.lifecycle = lifecycle
    }
}

public protocol MeetCallSignalReceiving: Sendable {
    func receive(_ signal: MeetCallSignal) async
}

public struct NoopMeetCallSignalReceiver: MeetCallSignalReceiving {
    public init() {}
    public func receive(_ signal: MeetCallSignal) async {}
}

/// Late-binding box (the ingestor is constructed before the tracker).
public final class MeetCallSignalBox: MeetCallSignalReceiving, Sendable {
    private let target = Mutex<(any MeetCallSignalReceiving)?>(nil)

    public init() {}

    public func set(_ receiver: any MeetCallSignalReceiving) {
        target.withLock { $0 = receiver }
    }

    public func receive(_ signal: MeetCallSignal) async {
        let receiver = target.withLock { $0 }
        await receiver?.receive(signal)
    }
}

// MARK: - Pipeline sweep seam

/// Pending-events sweep trigger seam (same pattern as `HandoffKicking`):
/// the pipeline calls it at every run entry (processing start AND
/// regenerate); import and meeting-code edits call it directly.
public protocol MeetEventsSweeping: Sendable {
    func sweep(meetingID: MeetingID) async
}

public struct NoopMeetEventsSweeper: MeetEventsSweeping {
    public init() {}
    public func sweep(meetingID: MeetingID) async {}
}

// MARK: - Processing dispatch seam

/// Status-dependent processing dispatch (the C10 rule: `ready` →
/// `regenerate()`, non-ready → `process()`). The ingestor fires it when an
/// arrival-time ingest adds content (events or roster rows) to a meeting
/// that is already `ready`: the minted payload predates that content, so the
/// meeting must re-mint and supersede. Conformers swallow failures (the run
/// records its own).
public protocol ProcessingDispatching: Sendable {
    func dispatch(meetingID: MeetingID) async
}

public struct NoopProcessingDispatcher: ProcessingDispatching {
    public init() {}
    public func dispatch(meetingID: MeetingID) async {}
}

/// Late-binding box breaking the composition-root cycle (the pipeline needs
/// the ingestor as its sweeper; the ingestor needs the pipeline as its
/// dispatcher). `set` is called once, right after the pipeline exists.
public final class ProcessingDispatcherBox: ProcessingDispatching, Sendable {
    private let target = Mutex<(any ProcessingDispatching)?>(nil)

    public init() {}

    public func set(_ dispatcher: any ProcessingDispatching) {
        target.withLock { $0 = dispatcher }
    }

    public func dispatch(meetingID: MeetingID) async {
        let dispatcher = target.withLock { $0 }
        await dispatcher?.dispatch(meetingID: meetingID)
    }
}

// MARK: - Response

/// Status + the signed ack value for the `X-Blaise-Ack` header (nil only
/// when no shared secret is configured — there is no key to sign with; the
/// extension treats the unsigned response as network-class and retries).
public struct MeetEventsResponse: Sendable, Equatable {
    public var status: Int
    public var ackHeaderValue: String?

    public init(status: Int, ackHeaderValue: String?) {
        self.status = status
        self.ackHeaderValue = ackHeaderValue
    }
}

// MARK: - Ingestor

public struct MeetEventsIngestor: Sendable, MeetEventsSweeping {
    /// Localized-self denylist (contract): a rotated self-tile label that
    /// escaped the extension's closed set is treated as isSelf.
    public static let selfDenylist: Set<String> = ["You", "Você", "you", "você"]
    /// ±48 h freshness window on `capturedAtMs`.
    public static let freshnessWindowMs: Int64 = 48 * 3600 * 1000
    /// Correlation window padding around [startedAt, endedAt-or-now].
    public static let correlationPaddingSeconds: TimeInterval = 10 * 60
    /// Unmatched batches are retained 7 days, then discarded.
    public static let pendingRetentionSeconds: TimeInterval = 7 * 24 * 3600

    private let database: BlaiseDatabase
    private let secrets: any SecretStore
    private let session: any RecordingSessionProviding
    private let settings: SettingsStore
    private let dispatcher: any ProcessingDispatching
    /// C14: liveness/lifecycle forwarding to the automation tracker.
    private let signals: any MeetCallSignalReceiving
    private let now: @Sendable () -> Date
    /// Test seam: runs AFTER the ingest transaction commits and BEFORE the
    /// 200 is formed — a throw here simulates the crash-between-commit-and-
    /// respond window (the retried batch must get a deduped 200).
    private let midResponseHook: (@Sendable () throws -> Void)?
    private let logger = Logger(subsystem: BlaiseBundle.identifier, category: "meet.events")

    public init(
        database: BlaiseDatabase,
        secrets: any SecretStore,
        session: any RecordingSessionProviding = NoRecordingSessionProvider(),
        dispatcher: any ProcessingDispatching = NoopProcessingDispatcher(),
        signals: any MeetCallSignalReceiving = NoopMeetCallSignalReceiver(),
        now: @escaping @Sendable () -> Date = { Date() },
        midResponseHook: (@Sendable () throws -> Void)? = nil
    ) {
        self.database = database
        self.secrets = secrets
        self.session = session
        self.settings = SettingsStore(database: database)
        self.dispatcher = dispatcher
        self.signals = signals
        self.now = now
        self.midResponseHook = midResponseHook
    }

    // MARK: - Request handling (status semantics pinned)

    /// Handles one `POST /v1/meet-events` body. Status semantics:
    /// - 200 ONLY after durable acceptance (ingest or pending-store commit) —
    ///   or for replayed/stale-but-valid batches (acked, not ingested anew);
    /// - 401 = decryption failure (incl. missing secret/malformed envelope —
    ///   nothing decrypted);
    /// - 400 = decrypts but structurally unusable (never retried by the
    ///   extension — reserved for true schema garbage, NEVER transient);
    /// - 500 = a transient local failure (DB write error) — ring-retried.
    public func handle(body: Data) async -> MeetEventsResponse {
        let secret = (try? secrets.get(key: MeetEventsSecret.secretStoreKey)) ?? nil
        let envelope = try? JSONDecoder().decode(MeetWireEnvelope.self, from: body)
        let ivBase64 = envelope?.iv ?? ""

        func respond(_ status: Int) -> MeetEventsResponse {
            MeetEventsResponse(
                status: status,
                ackHeaderValue: secret.map {
                    MeetEventsCrypto.ackSignature(secret: $0, ivBase64: ivBase64, status: status)
                })
        }

        guard let secret else {
            logger.warning("meet-events batch rejected: no shared secret configured")
            return MeetEventsResponse(status: 401, ackHeaderValue: nil)
        }
        guard let envelope, let plaintext = try? MeetEventsCrypto.decrypt(envelope, secret: secret)
        else {
            return respond(401)  // decrypt failure (wrong/stale secret, garbage)
        }

        // Decrypts but structurally unusable → 400 (drop forever). C14:
        // schemaVersion ∈ {1, 2} — a v1 batch is a v2 batch with no
        // lifecycle (buffered pre-update batches still ingest).
        guard
            let batch = try? JSONDecoder().decode(MeetWireBatch.self, from: plaintext),
            [1, 2].contains(batch.schemaVersion), !batch.meetingCode.isEmpty
        else {
            logger.warning("meet-events batch rejected 400: undecodable or wrong schemaVersion")
            return respond(400)
        }

        // Freshness (±48 h on capturedAtMs): stale-but-valid → acked 200,
        // dropped — never silently double-ingested, never 400.
        let nowMs = Int64(now().timeIntervalSince1970 * 1000)
        guard abs(batch.capturedAtMs - nowMs) <= Self.freshnessWindowMs else {
            logger.info("meet-events batch outside ±48 h freshness window: acked, dropped")
            return respond(200)
        }

        do {
            if let meetingID = try await matchMeeting(for: batch) {
                let outcome = try await ingest(batch: batch, into: meetingID, pendingRowID: nil)
                // H-1: content landing AFTER the meeting is `ready` postdates
                // the minted payload — fire the status-dependent dispatch
                // (`ready` → regenerate: re-snapshot, re-mint, supersede) so
                // the new events/roster reach the notes and the Evidence
                // Store. Immediate dispatch costs one full re-run per
                // post-ready flush; the common case is a single post-meeting
                // flush, and deduped replays add no content, so they never
                // re-fire. Fire-and-forget: the 200 must not wait on a run.
                if outcome.addedContent, outcome.meetingStatus == .ready {
                    let dispatcher = self.dispatcher
                    Task { await dispatcher.dispatch(meetingID: meetingID) }
                }
            } else if !batch.isHeartbeatOnly {
                // Heartbeat-only batches matched to no meeting are NOT
                // stored pending (content-free; the signal below is their
                // entire purpose).
                try await storePending(batch: batch, plaintext: plaintext)
            }
            try midResponseHook?()
            // C14: forward the per-batch liveness signal (plus lifecycle
            // when present) for EVERY accepted code-carrying batch —
            // correlated or not. Fire-and-forget AFTER the transaction; the
            // signed 200 never waits on it. The tracker's monotonic guard
            // absorbs replays (a deduped re-delivery carries an old
            // timestamp and advances nothing).
            let signals = self.signals
            let signal = MeetCallSignal(
                meetingCode: batch.meetingCode, capturedAtMs: batch.capturedAtMs,
                lifecycle: batch.lifecycle)
            Task { await signals.receive(signal) }
            return respond(200)
        } catch {
            // Local/transient (DB write failure, crash-hook seam): 5xx —
            // the extension ring-retries; NEVER 400 for transient conditions.
            logger.error("meet-events ingest failed transiently: \(error)")
            return respond(500)
        }
    }

    // MARK: - Identity normalization (denylist + participantID merge)

    struct NormalizedEvent {
        var wire: MeetWireEvent
        var isSelf: Bool
        /// Post-substitution display name; nil = no grounded name (the event
        /// is marked seen but cannot vote — no name is ever invented).
        var displayName: String?
    }

    struct NormalizedRosterEntry: Equatable {
        var name: String
        var participantID: String?
    }

    struct NormalizedBatch {
        var events: [NormalizedEvent]
        /// Non-self roster identities bound for `meet_roster_pending`
        /// (isSelf dropped, identity-merged, batch-deduped by folded name);
        /// the next content run absorbs them into `Meeting.attendees`.
        var roster: [NormalizedRosterEntry]

        var rosterNames: [String] { roster.map(\.name) }
    }

    static func normalize(_ batch: MeetWireBatch, userName: String) -> NormalizedBatch {
        func denylisted(_ name: String?) -> Bool {
            guard let name else { return false }
            return selfDenylist.contains(name.trimmingCharacters(in: .whitespaces))
        }
        // Every wire name passes the icon-ligature/pin-label sanitizer FIRST
        // (field 2026-06-11: pre-0.2.0 extensions shipped hover-control text
        // as names). The RAW wire fields are untouched — the dedupe id stays
        // byte-stable across sanitizer revisions.
        func cleaned(_ raw: String?) -> String? {
            MeetDisplayNameSanitizer.sanitize(raw)
        }

        // Identity merge by participantID across roster + events: same pid =
        // same person; prefer the NAMED form for display, OR the isSelf flags.
        struct Identity {
            var name: String?
            var isSelf = false
        }
        var identities: [String: Identity] = [:]
        func feed(name rawName: String?, participantID: String?, isSelf rawIsSelf: Bool) {
            let isSelf = rawIsSelf || denylisted(rawName)
            let name = (isSelf || denylisted(rawName)) ? nil : rawName
            guard let pid = participantID else { return }
            var identity = identities[pid] ?? Identity()
            if identity.name == nil { identity.name = name }
            identity.isSelf = identity.isSelf || isSelf
            identities[pid] = identity
        }
        for entry in batch.roster {
            feed(
                name: cleaned(entry.displayName), participantID: entry.participantID,
                isSelf: entry.isSelf)
        }
        for event in batch.events {
            feed(
                name: cleaned(event.displayName), participantID: event.participantID,
                isSelf: event.isSelf)
        }

        let events = batch.events.map { event -> NormalizedEvent in
            let merged = event.participantID.flatMap { identities[$0] }
            let ownName = cleaned(event.displayName)
            let isSelf = event.isSelf || denylisted(ownName) || (merged?.isSelf ?? false)
            let name: String?
            if isSelf {
                // The substitution rule: no name to fall back on. G3: a
                // pre-onboarding (empty) identity contributes no self-name, so
                // the self event stays nameless rather than writing an empty
                // speaker name.
                name = userName.isEmpty ? nil : userName
            } else if let own = ownName, !denylisted(own) {
                name = own
            } else {
                name = merged?.name
            }
            return NormalizedEvent(wire: event, isSelf: isSelf, displayName: name)
        }

        var roster: [NormalizedRosterEntry] = []
        var seenFolded: Set<String> = []
        for entry in batch.roster {
            let merged = entry.participantID.flatMap { identities[$0] }
            let entryName = cleaned(entry.displayName)
            let isSelf = entry.isSelf || denylisted(entryName) || (merged?.isSelf ?? false)
            if isSelf { continue }  // the user is not his own attendee
            guard let name = (denylisted(entryName) ? nil : entryName) ?? merged?.name
            else { continue }
            let folded = VocabNormalization.canonicalMode(name)
            guard seenFolded.insert(folded).inserted else { continue }
            roster.append(NormalizedRosterEntry(name: name, participantID: entry.participantID))
        }
        return NormalizedBatch(events: events, roster: roster)
    }

    // MARK: - Correlation (batch → meeting)

    /// Live-session case first (preconditions pinned: both codes non-nil and
    /// equal); otherwise code + window overlap, recurring-code ambiguity
    /// resolved by greatest event-overlap duration.
    func matchMeeting(for batch: MeetWireBatch) async throws -> MeetingID? {
        if let live = await session.currentSession(),
            let liveCode = live.meetingCode, liveCode == batch.meetingCode
        {
            return live.meetingID
        }
        let referenceNow = now()
        let candidates = try await database.pool.read { db in
            try Meeting
                .filter(Column("meeting_code") == batch.meetingCode)
                .fetchAll(db)
        }
        guard !candidates.isEmpty else { return nil }

        // Events span (ms); an events-free batch degenerates to capturedAtMs.
        let spanStart = batch.events.map(\.startEpochMillis).min() ?? batch.capturedAtMs
        let spanEnd = batch.events.map(\.endEpochMillis).max() ?? batch.capturedAtMs

        // Deterministic order (L-1): greatest overlap, then earliest
        // startedAt, then lowest id — never SQLite scan order.
        var best: (id: MeetingID, overlap: Int64, startedAt: Date)?
        for meeting in candidates {
            let windowStart = Int64(
                (meeting.startedAt.timeIntervalSince1970 - Self.correlationPaddingSeconds) * 1000)
            let windowEnd = Int64(
                ((meeting.endedAt ?? referenceNow).timeIntervalSince1970
                    + Self.correlationPaddingSeconds) * 1000)
            guard spanStart <= windowEnd, spanEnd >= windowStart else { continue }
            let overlap: Int64 = min(spanEnd, windowEnd) - max(spanStart, windowStart)
            let wins: Bool
            if let current = best {
                if overlap != current.overlap {
                    wins = overlap > current.overlap
                } else if meeting.startedAt != current.startedAt {
                    wins = meeting.startedAt < current.startedAt
                } else {
                    wins = meeting.id < current.id
                }
            } else {
                wins = true
            }
            if wins {
                best = (meeting.id, overlap, meeting.startedAt)
            }
        }
        return best?.id
    }

    // MARK: - Ingestion (ONE transaction per batch)

    /// What one batch ingest durably added — drives the post-ready dispatch
    /// (`handle`) and the receiver list (`sweep(meetingCode:)`).
    struct IngestOutcome: Sendable {
        var storedEventCount = 0
        var newRosterRowCount = 0
        var meetingStatus: MeetingStatus?

        var addedContent: Bool { storedEventCount > 0 || newRosterRowCount > 0 }
    }

    /// Seen-ids + speaker events + roster queue rows + pending-row removal
    /// commit together; the 200 responds only after this commit — no crash
    /// point can record a batch as seen without its events. The meeting row
    /// itself is NEVER touched here (H-1): `attendees` and `updated_at_ms`
    /// are payload-builder inputs, and mutating them outside a content run
    /// would break C8's re-materialization recovery (rebuild from durable
    /// state must hash-equal the stored version_hash). Roster names land in
    /// `meet_roster_pending`; the next content run absorbs them
    /// (`absorbPendingRoster`) inside its entry transaction.
    @discardableResult
    func ingest(
        batch: MeetWireBatch, into meetingID: MeetingID, pendingRowID: Int64?
    ) async throws -> IngestOutcome {
        let userName = await userIdentity().name
        let normalized = Self.normalize(batch, userName: userName)
        let meetingCode = batch.meetingCode
        return try await database.pool.write { db in
            var outcome = IngestOutcome()
            for event in normalized.events {
                let dedupeID = event.wire.dedupeID(meetingCode: meetingCode)
                try db.execute(
                    sql: "INSERT OR IGNORE INTO meet_seen_event_id (meeting_id, event_id) VALUES (?, ?)",
                    arguments: [meetingID, dedupeID])
                guard db.changesCount > 0 else { continue }  // replayed: seen, skip
                guard let name = event.displayName else { continue }  // nameless: seen, cannot vote
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO meeting_speaker_event
                            (meeting_id, dedupe_id, display_name, participant_id, is_self,
                             start_epoch_ms, end_epoch_ms)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        meetingID, dedupeID, name, event.wire.participantID, event.isSelf,
                        event.wire.startEpochMillis, event.wire.endEpochMillis,
                    ])
                outcome.storedEventCount += db.changesCount
            }

            // Roster → meet_roster_pending (read-only against the meeting
            // row: names already present as attendees never queue, so a
            // re-flush of known names cannot re-fire the dispatch).
            let meeting = try Meeting.fetchOne(db, key: meetingID)
            outcome.meetingStatus = meeting?.status
            let existing = Set(
                (meeting?.attendees ?? []).map { VocabNormalization.canonicalMode($0.name) })
            for entry in normalized.roster {
                let folded = VocabNormalization.canonicalMode(entry.name)
                guard !existing.contains(folded) else { continue }
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO meet_roster_pending
                            (meeting_id, display_name, display_name_folded, participant_id, is_self)
                        VALUES (?, ?, ?, ?, 0)
                        """,
                    arguments: [meetingID, entry.name, folded, entry.participantID])
                outcome.newRosterRowCount += db.changesCount
            }

            if let pendingRowID {
                try db.execute(
                    sql: "DELETE FROM meet_events_pending WHERE id = ?", arguments: [pendingRowID])
            }
            return outcome
        }
    }

    /// Absorbs this meeting's queued roster rows into `meeting.attendees`
    /// (source `.meetExtension`, isSelf skipped, folded-name dedupe against
    /// the existing attendees) and clears them. Called by the pipeline INSIDE
    /// the run-entry transaction — the one place a content run already bumps
    /// `updatedAt`, and the run's finalize re-reads the row, so absorbed
    /// attendees reach C4's allowed-name set and the new payload.
    static func absorbPendingRoster(_ db: Database, meeting: inout Meeting) throws {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT display_name FROM meet_roster_pending
                WHERE meeting_id = ? AND is_self = 0 ORDER BY id
                """,
            arguments: [meeting.id])
        var existing = Set(meeting.attendees.map { VocabNormalization.canonicalMode($0.name) })
        for row in rows {
            let name: String = row["display_name"]
            if existing.insert(VocabNormalization.canonicalMode(name)).inserted {
                meeting.attendees.append(Attendee(name: name, source: .meetExtension))
            }
        }
        try db.execute(
            sql: "DELETE FROM meet_roster_pending WHERE meeting_id = ?", arguments: [meeting.id])
    }

    // MARK: - Pending store / sweep / purge

    /// Unmatched batches are retained (7 days) keyed by content digest —
    /// a replayed unmatched batch stores once (`UNIQUE(batch_digest)`).
    func storePending(batch: MeetWireBatch, plaintext: Data) async throws {
        let digest = EvidencePayloadBuilder.sha256Hex(plaintext)
        let json = String(decoding: plaintext, as: UTF8.self)
        let timestamp = now()
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO meet_events_pending
                        (meeting_code, batch_json, batch_digest, captured_at_ms, received_at)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [batch.meetingCode, json, digest, batch.capturedAtMs, timestamp])
        }
    }

    /// Sweep trigger: meeting creation / processing start / regenerate /
    /// meeting-code edit. No-op for a meeting without a code.
    public func sweep(meetingID: MeetingID) async {
        guard
            let meeting = try? await MeetingRepository(database: database).fetch(meetingID),
            let code = meeting.meetingCode
        else { return }
        await sweep(meetingCode: code)
    }

    /// Re-runs correlation for every pending batch with this code; matched
    /// batches ingest atomically (events + seen-ids + pending-row removal).
    /// Freshness is NOT re-checked here: it gated arrival; retention (7 d)
    /// bounds the sweep window. Returns the meetings that actually RECEIVED
    /// new content (M-2): under a recurring code a batch may correlate to a
    /// DIFFERENT meeting than the one whose edit triggered the sweep — the
    /// caller's status-dependent dispatch must target the receivers.
    @discardableResult
    public func sweep(meetingCode: String) async -> [MeetingID] {
        guard
            let rows = try? await database.pool.read({ db in
                try Row.fetchAll(
                    db,
                    sql: "SELECT id, batch_json FROM meet_events_pending WHERE meeting_code = ?",
                    arguments: [meetingCode])
            })
        else { return [] }
        var matched = 0
        var receivers: [MeetingID] = []
        for row in rows {
            let rowID: Int64 = row["id"]
            let json: String = row["batch_json"]
            guard
                let batch = try? JSONDecoder().decode(MeetWireBatch.self, from: Data(json.utf8)),
                let meetingID = try? await matchMeeting(for: batch)
            else { continue }
            do {
                let outcome = try await ingest(batch: batch, into: meetingID, pendingRowID: rowID)
                matched += 1
                if outcome.addedContent, !receivers.contains(meetingID) {
                    receivers.append(meetingID)
                }
            } catch {
                logger.error("pending sweep ingest failed: \(error)")
            }
        }
        if matched > 0 {
            logger.info("pending sweep matched \(matched) batch(es) for code \(meetingCode, privacy: .private)")
        }
        return receivers
    }

    /// Startup + daily-timer purge: unmatched batches older than 7 days are
    /// discarded (contract).
    @discardableResult
    public func purgeStalePending() async throws -> Int {
        let cutoff = now().addingTimeInterval(-Self.pendingRetentionSeconds)
        return try await database.pool.write { db in
            try db.execute(
                sql: "DELETE FROM meet_events_pending WHERE received_at < ?", arguments: [cutoff])
            return db.changesCount
        }
    }

    private func userIdentity() async -> UserIdentity {
        (try? await settings.get(UserIdentity.settingsKey, as: UserIdentity.self))
            ?? nil ?? .shippedDefault
    }
}

// MARK: - Stored speaker events (C7 stage 8 reader)

/// `meeting_speaker_event` reads — THE durable home of matched events;
/// `SpeakerHints.activeSpeakerEvents` = these rows.
public struct MeetEventsRepository: Sendable {
    let database: BlaiseDatabase

    public init(database: BlaiseDatabase) {
        self.database = database
    }

    /// Stored events in `ActiveSpeakerEvent` form, ordered by start time.
    /// `excludingSelf` (C11/C4 v5.3): under two-track capture, isSelf events
    /// are excluded from system-track voting — the user is not on that track.
    public func activeSpeakerEvents(
        meetingID: MeetingID, excludingSelf: Bool = false
    ) async throws -> [ActiveSpeakerEvent] {
        try await database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT display_name, participant_id, start_epoch_ms, end_epoch_ms
                    FROM meeting_speaker_event WHERE meeting_id = ?
                    \(excludingSelf ? "AND is_self = 0" : "")
                    ORDER BY start_epoch_ms, end_epoch_ms
                    """,
                arguments: [meetingID]
            ).compactMap { row -> ActiveSpeakerEvent? in
                let rawName: String = row["display_name"]
                // Pre-0.2.0 extensions stored markup/sentence junk as event
                // names (field 2026-06-11); re-sanitize on read so the
                // resolver never votes junk onto a diarized cluster (the internal project
                // transcript's "As pessoas ainda podem ver seu vídeo completo."
                // speaker came from exactly such an event). Raw rows are kept;
                // only the in-memory vote input is cleaned.
                guard let name = MeetDisplayNameSanitizer.sanitize(rawName),
                    !AttendeeDisplay.looksLikeSentence(name)
                else { return nil }
                return ActiveSpeakerEvent(
                    displayName: name,
                    participantID: row["participant_id"],
                    startEpochMillis: row["start_epoch_ms"],
                    endEpochMillis: row["end_epoch_ms"])
            }
        }
    }
}
