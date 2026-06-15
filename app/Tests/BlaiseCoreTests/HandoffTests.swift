import Foundation
import GRDB
import Testing
@testable import BlaiseCore

@Suite struct HandoffTests {
    @Test func enqueueRequiresPayloadFileOnDisk() async throws {
        let database = try makeDatabase()
        let meeting = makeMeeting()
        try await MeetingRepository(database: database).create(meeting)
        let missingPath = database.paths.relativeHandoffPayloadPath(meetingID: meeting.id, versionHash: "nope")
        await #expect(throws: BlaiseDatabaseError.missingPayloadFile(relativePath: missingPath)) {
            try await HandoffRepository(database: database)
                .enqueue(meetingID: meeting.id, versionHash: "nope", payloadPath: missingPath)
        }
        #expect(try database.count("handoff_queue") == 0)
    }

    @Test func duplicateEnqueueIsIdempotentNoOp() async throws {
        let database = try makeDatabase()
        let (meeting, hash, path) = try await makeEnqueueableMeeting(database)
        let repo = HandoffRepository(database: database)
        let first = try await repo.enqueue(meetingID: meeting.id, versionHash: hash, payloadPath: path)
        let second = try await repo.enqueue(meetingID: meeting.id, versionHash: hash, payloadPath: path)
        #expect(second == first, "duplicate enqueue must return the existing item unchanged")
        #expect(try database.count("handoff_queue") == 1)
    }

    @Test func identicalPayloadBytesForDistinctMeetingsBothEnqueue() async throws {
        let database = try makeDatabase()
        let repo = HandoffRepository(database: database)
        let meetings = MeetingRepository(database: database)
        // Same bytes, same version hash — but distinct meetings must never dedup.
        let bytes = Data("{\"identical\":true}\n".utf8)
        let hash = "same-hash"
        var items: [HandoffItem] = []
        for _ in 0..<2 {
            let meeting = makeMeeting()
            try await meetings.create(meeting)
            let path = try plantPayload(database, meetingID: meeting.id, versionHash: hash, bytes: bytes)
            items.append(try await repo.enqueue(meetingID: meeting.id, versionHash: hash, payloadPath: path))
        }
        #expect(try database.count("handoff_queue") == 2)
        #expect(items[0].meetingID != items[1].meetingID)
    }

    @Test func nextPendingIsFIFOByCreatedSeq() async throws {
        let database = try makeDatabase()
        let repo = HandoffRepository(database: database)
        var enqueued: [HandoffItem] = []
        for _ in 0..<3 {
            let (meeting, hash, path) = try await makeEnqueueableMeeting(database)
            enqueued.append(try await repo.enqueue(meetingID: meeting.id, versionHash: hash, payloadPath: path))
        }
        #expect(enqueued.map(\.createdSeq) == [1, 2, 3], "created_seq is assigned monotonically")

        let first = try #require(try await repo.nextPending())
        #expect(first.id == enqueued[0].id)
        try await repo.transition(first.id, to: .delivering)
        let second = try #require(try await repo.nextPending())
        #expect(second.id == enqueued[1].id)
    }

    @Test func transitionBookkeeping() async throws {
        let database = try makeDatabase()
        let repo = HandoffRepository(database: database)
        let (meeting, hash, path) = try await makeEnqueueableMeeting(database)
        let item = try await repo.enqueue(meetingID: meeting.id, versionHash: hash, payloadPath: path)
        #expect(item.state == .pending)
        #expect(item.attempts == 0)

        let delivering = try await repo.transition(item.id, to: .delivering)
        #expect(delivering.state == .delivering)
        #expect(delivering.attempts == 1)
        #expect(delivering.lastAttemptAt != nil)
        #expect(delivering.deliveredAt == nil)

        let failed = try await repo.transition(item.id, to: .failed, error: "the remote host unreachable")
        #expect(failed.state == .failed)
        #expect(failed.lastError == "the remote host unreachable")

        let retried = try await repo.transition(item.id, to: .delivering)
        #expect(retried.attempts == 2)

        let delivered = try await repo.transition(item.id, to: .delivered)
        #expect(delivered.state == .delivered)
        #expect(delivered.deliveredAt != nil)

        await #expect(throws: BlaiseDatabaseError.handoffItemNotFound("missing-id")) {
            try await repo.transition("missing-id", to: .delivering)
        }
    }

    @Test func finalizeMeetingProcessingMintsReadyWithQueueRow() async throws {
        let database = try makeDatabase()
        let (meeting, hash, path) = try await makeEnqueueableMeeting(database)
        let notes = makeNotes(meetingID: meeting.id)

        let item = try await database.finalizeMeetingProcessing(
            meetingID: meeting.id,
            versionHash: hash,
            payloadPath: path,
            notes: notes
        )
        #expect(item.state == .pending)
        #expect(item.versionHash == hash)
        #expect(item.payloadPath == path)

        let finalized = try #require(try await MeetingRepository(database: database).fetch(meeting.id))
        #expect(finalized.status == .ready)
        #expect(finalized.lastProcessingError == nil)
        #expect(try await NotesRepository(database: database).fetch(meetingID: meeting.id) == notes)
        #expect(try database.count("handoff_queue") == 1)
    }

    @Test func finalizeMeetingProcessingIsAtomic() async throws {
        let database = try makeDatabase()
        let (meeting, hash, path) = try await makeEnqueueableMeeting(database)

        // Thrown mid-transaction, after the status flip + notes upsert,
        // before the enqueue: EVERYTHING must roll back.
        await #expect(throws: TestFailure.self) {
            try await database.finalizeMeetingProcessing(
                meetingID: meeting.id,
                versionHash: hash,
                payloadPath: path,
                notes: makeNotes(meetingID: meeting.id),
                midTransactionHook: { throw TestFailure() }
            )
        }

        let unchanged = try #require(try await MeetingRepository(database: database).fetch(meeting.id))
        #expect(unchanged.status == .processing, "status flip must roll back with the failed enqueue")
        #expect(try await NotesRepository(database: database).fetch(meetingID: meeting.id) == nil)
        #expect(try database.count("handoff_queue") == 0)
    }

    @Test func finalizeRequiresPayloadFileAndExistingMeeting() async throws {
        let database = try makeDatabase()
        let meeting = makeMeeting()
        try await MeetingRepository(database: database).create(meeting)
        let missing = database.paths.relativeHandoffPayloadPath(meetingID: meeting.id, versionHash: "h")
        await #expect(throws: BlaiseDatabaseError.missingPayloadFile(relativePath: missing)) {
            try await database.finalizeMeetingProcessing(
                meetingID: meeting.id, versionHash: "h", payloadPath: missing, notes: makeNotes(meetingID: meeting.id)
            )
        }

        let ghostID = ULID.generate()
        let path = try plantPayload(database, meetingID: ghostID, versionHash: "h2")
        await #expect(throws: BlaiseDatabaseError.meetingNotFound(ghostID)) {
            try await database.finalizeMeetingProcessing(
                meetingID: ghostID, versionHash: "h2", payloadPath: path, notes: makeNotes(meetingID: ghostID)
            )
        }
    }
}

// Impl-audit round-1 regression tests (audits/c1/impl_audit_round1.md)
@Suite struct HandoffTransitionContractTests {
    /// F3: `delivered` is terminal — any transition out of it throws.
    @Test func deliveredIsTerminal() async throws {
        let database = try makeDatabase()
        let (meeting, hash, path) = try await makeEnqueueableMeeting(database)
        let repo = HandoffRepository(database: database)
        let item = try await repo.enqueue(meetingID: meeting.id, versionHash: hash, payloadPath: path)
        _ = try await repo.transition(item.id, to: .delivering)
        _ = try await repo.transition(item.id, to: .delivered)
        await #expect(throws: BlaiseDatabaseError.illegalHandoffTransition(from: .delivered, to: .pending)) {
            try await repo.transition(item.id, to: .pending)
        }
        await #expect(throws: BlaiseDatabaseError.illegalHandoffTransition(from: .delivered, to: .delivering)) {
            try await repo.transition(item.id, to: .delivering)
        }
        let stored = try await database.pool.read { try HandoffItem.fetchOne($0, key: item.id) }
        #expect(stored?.state == .delivered, "failed illegal transitions must not mutate the row")
    }

    /// F2: `transition` returns the stored row — equal to a fresh fetch.
    @Test func transitionReturnsStoredRow() async throws {
        let database = try makeDatabase()
        let (meeting, hash, path) = try await makeEnqueueableMeeting(database)
        let repo = HandoffRepository(database: database)
        let item = try await repo.enqueue(meetingID: meeting.id, versionHash: hash, payloadPath: path)
        let returned = try await repo.transition(item.id, to: .delivering)
        let fetched = try await database.pool.read { try HandoffItem.fetchOne($0, key: item.id) }
        #expect(returned == fetched)
    }
}
