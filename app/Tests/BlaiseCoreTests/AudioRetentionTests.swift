import Foundation
import GRDB
import Testing
@testable import BlaiseCore

// G16 (specs/g16_audio_retention.md): owner-intent audio retention. AC1 the
// delete removes exactly the audio set and keeps everything else (row,
// transcript, notes, handoff, derived JSON; `updated_at` untouched); the mark
// survives full-record `Meeting` writes; AC2 kill between mark and removal →
// `sweepMarked` finishes, and a marked row's leftover CAF is neither re-encoded
// nor re-dispatched; AC3 a symlinked leaf is refused; AC4 the §2 eligibility
// matrix for manual vs cap; §4 usage totals; the handoff payload is unaffected.

private let sentinelUpdatedAt = "2020-01-01 00:00:00.000"

private func rawColumn(_ database: BlaiseDatabase, _ column: String, _ id: MeetingID) async throws -> String? {
    try await database.pool.read { db in
        try String.fetchOne(db, sql: "SELECT \(column) FROM meeting WHERE id = ?", arguments: [id])
    }
}

private func touch(_ url: URL, bytes: Int = 1024) throws {
    try Data((0..<bytes).map { UInt8($0 % 251) }).write(to: url)
}

/// A meeting row with no pipeline behind it (eligibility / recovery tests).
@discardableResult
private func insertMeeting(
    _ database: BlaiseDatabase,
    status: MeetingStatus = .ready,
    startedAt: Date = msDate(),
    lastProcessingError: String? = nil
) async throws -> MeetingID {
    var meeting = makeMeeting(startedAt: startedAt, status: status)
    meeting.lastProcessingError = lastProcessingError
    try database.paths.createMeetingDirectory(meeting.id)
    try await MeetingRepository(database: database).create(meeting)
    return meeting.id
}

@Suite struct AudioRetentionTests {

    /// Drives a meeting to `ready` and plants the full audio set beside the
    /// imported `audio.m4a`: a second part of both tracks, a leftover capture
    /// CAF, and the lossless import copy (the import path removes it after the
    /// verified encode, so it is re-created here), plus a derived JSON.
    private func readyHarnessWithFullAudioSet() async throws -> (PipelineHarness, Meeting) {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        let paths = harness.database.paths
        #expect(FileManager.default.fileExists(atPath: paths.audioURL(meeting.id).path))
        try touch(paths.audioURL(meeting.id, part: 2))
        try touch(paths.audioMicURL(meeting.id, part: 2))
        try touch(paths.captureCAFURL(meeting.id, track: .system))
        try touch(paths.captureCAFURL(meeting.id, track: .mic, part: 2))
        try touch(paths.importCopyURL(meeting.id))
        try touch(paths.roomTreatmentURL(meeting.id))
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.status == .ready)
        return (harness, stored)
    }

    // MARK: AC1

    @Test("AC1: delete removes the audio set, keeps row/transcript/notes/handoff/derived JSON, updated_at untouched")
    func deleteKeepsEverythingButAudio() async throws {
        let (harness, meeting) = try await readyHarnessWithFullAudioSet()
        let db = harness.database
        let paths = db.paths
        try await db.pool.write { db in
            try db.execute(
                sql: "UPDATE meeting SET updated_at = ? WHERE id = ?",
                arguments: [sentinelUpdatedAt, meeting.id])
        }
        let segmentsBefore = try await harness.segments(meeting.id)
        #expect(!segmentsBefore.isEmpty)
        let queueBefore = try await harness.queueRows(meeting.id)
        let handoffFilesBefore = try FileManager.default
            .contentsOfDirectory(atPath: paths.handoffDirectory(meeting.id).path).sorted()
        #expect(!handoffFilesBefore.isEmpty)
        let audioBefore = AudioRetention.audioFileURLs(paths: paths, meetingID: meeting.id)
        #expect(audioBefore.count == 6, "audio.m4a, audio_2, audio_mic_2, two CAFs, import.wav")

        let warnings = try await harness.pipeline.deleteAudio(meetingID: meeting.id, origin: .manual)
        #expect(warnings.isEmpty)

        for url in [
            paths.audioURL(meeting.id), paths.audioURL(meeting.id, part: 2),
            paths.audioMicURL(meeting.id, part: 2),
            paths.captureCAFURL(meeting.id, track: .system),
            paths.captureCAFURL(meeting.id, track: .mic, part: 2),
            paths.importCopyURL(meeting.id),
        ] {
            #expect(!FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent) removed")
        }
        #expect(AudioRetention.audioFileURLs(paths: paths, meetingID: meeting.id).isEmpty)
        // Derived artifacts and handoff payloads are kept.
        #expect(FileManager.default.fileExists(atPath: paths.roomTreatmentURL(meeting.id).path))
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: paths.handoffDirectory(meeting.id).path)
                .sorted() == handoffFilesBefore)
        // Row, transcript, notes, handoff rows kept; status stays ready.
        let after = try #require(try await harness.meeting(meeting.id))
        #expect(after.status == .ready)
        #expect(after.audioDeletedReason == .manual)
        #expect(after.audioDeletedAt != nil)
        #expect(try await harness.segments(meeting.id) == segmentsBefore)
        #expect(try await NotesRepository(database: db).fetch(meetingID: meeting.id) != nil)
        #expect(try await harness.queueRows(meeting.id) == queueBefore)
        // The mark is metadata: updated_at is byte-identical.
        #expect(try await rawColumn(db, "updated_at", meeting.id) == sentinelUpdatedAt)
    }

    @Test("the mark survives a full-record Meeting write from a struct fetched before the mark")
    func staleFullRecordWriteKeepsMark() async throws {
        let (harness, meeting) = try await readyHarnessWithFullAudioSet()
        let db = harness.database
        let repository = MeetingRepository(database: db)
        let stale = try #require(try await repository.fetch(meeting.id))
        #expect(stale.audioDeletedAt == nil)

        try await harness.pipeline.deleteAudio(meetingID: meeting.id, origin: .manual)
        // A full-record update of the STALE struct (audioDeletedAt == nil).
        try await repository.update(stale)
        #expect(try await rawColumn(db, "audio_deleted_at", meeting.id) != nil)
        #expect(try await rawColumn(db, "audio_deleted_reason", meeting.id) == "manual")

        // And through the real content write paths too (rename re-mints).
        try await harness.pipeline.renameMeeting(meetingID: meeting.id, to: "Renamed after audio deletion")
        let after = try #require(try await repository.fetch(meeting.id))
        #expect(after.title == "Renamed after audio deletion")
        #expect(after.audioDeletedAt != nil)
        #expect(after.audioDeletedReason == .manual)
    }

    @Test("full-record inserts never write the mark (the SQL UPDATE is its only writer)")
    func insertOmitsMarkColumns() async throws {
        let database = try makeDatabase()
        var meeting = makeMeeting(status: .ready)
        meeting.audioDeletedAt = msDate()
        meeting.audioDeletedReason = .cap
        try await MeetingRepository(database: database).create(meeting)
        #expect(try await rawColumn(database, "audio_deleted_at", meeting.id) == nil)
        #expect(try await rawColumn(database, "audio_deleted_reason", meeting.id) == nil)
    }

    // MARK: AC2

    @Test("AC2: kill between mark and removal → files remain → sweepMarked removes them")
    func killBetweenMarkAndRemovalSweptAtLaunch() async throws {
        let (harness, meeting) = try await readyHarnessWithFullAudioSet()
        let db = harness.database
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await harness.pipeline.deleteAudio(meetingID: meeting.id, origin: .manual) { throw Boom() }
        }
        #expect(try await rawColumn(db, "audio_deleted_at", meeting.id) != nil, "mark committed before the kill")
        #expect(!AudioRetention.audioFileURLs(paths: db.paths, meetingID: meeting.id).isEmpty)

        let swept = await AudioRetention.sweepMarked(database: db)
        #expect(swept == [meeting.id])
        #expect(AudioRetention.audioFileURLs(paths: db.paths, meetingID: meeting.id).isEmpty)
        #expect(FileManager.default.fileExists(atPath: db.paths.roomTreatmentURL(meeting.id).path))
        #expect(await AudioRetention.sweepMarked(database: db).isEmpty, "nothing left to sweep")
    }

    @Test("kill BEFORE the mark (eligibility refused) → nothing happened")
    func refusalLeavesEverything() async throws {
        let harness = try await makePipelineHarness()
        let meetingID = try await insertMeeting(harness.database, status: .recording)
        try touch(harness.database.paths.audioURL(meetingID))
        await #expect(throws: PipelineAudioDeleteError.refused(.recording)) {
            try await harness.pipeline.deleteAudio(meetingID: meetingID, origin: .manual)
        }
        #expect(try await rawColumn(harness.database, "audio_deleted_at", meetingID) == nil)
        #expect(FileManager.default.fileExists(atPath: harness.database.paths.audioURL(meetingID).path))
    }

    @Test("AC2: a marked row's leftover CAF is not re-encoded and the meeting is not re-dispatched")
    func recoverySkipsMarkedRows() async throws {
        let database = try makeDatabase()
        let paths = database.paths
        let marked = try await insertMeeting(
            database, status: .failed, lastProcessingError: "interrupted")
        try await AudioRetention.markDeleted(database: database, meetingID: marked, reason: .manual)
        // Residue a kill left behind: a CAF (garbage — must never reach the
        // encoder) and a retained m4a.
        try touch(paths.captureCAFURL(marked, track: .system))
        try touch(paths.audioURL(marked))
        // Control: an unmarked interrupted meeting with retained audio.
        let control = try await insertMeeting(
            database, status: .failed, lastProcessingError: "interrupted")
        try touch(paths.audioURL(control))

        let kicked = Recorder<MeetingID>()
        let sweep = await CaptureRecovery.sweepOrphanCAFs(database: database) { kicked.append($0) }
        #expect(sweep.isEmpty)
        #expect(kicked.values.isEmpty)
        #expect(FileManager.default.fileExists(atPath: paths.captureCAFURL(marked, track: .system).path))
        let note = try await MeetingRepository(database: database).fetch(marked)?.processingNote
        #expect(note == nil, "no recovery note — the encoder never ran")

        let redispatched = await CaptureRecovery.redispatchInterrupted(database: database) { kicked.append($0) }
        #expect(redispatched == [control], "only the unmarked meeting is re-dispatched")
    }

    // MARK: AC3

    @Test("AC3: a symlinked audio leaf is refused — the outside target survives")
    func symlinkedLeafRefused() async throws {
        let (harness, meeting) = try await readyHarnessWithFullAudioSet()
        let db = harness.database
        let victim = harness.dataRoot.appendingPathComponent("victim.m4a")
        try touch(victim)
        let link = db.paths.audioURL(meeting.id, part: 3)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: victim)

        try await harness.pipeline.deleteAudio(meetingID: meeting.id, origin: .manual)

        #expect(FileManager.default.fileExists(atPath: victim.path), "the symlink target is never followed")
        #expect(
            (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil,
            "the refused link itself is left in place")
        #expect(!FileManager.default.fileExists(atPath: db.paths.audioURL(meeting.id).path))
        #expect(
            await AudioRetention.removeAudioFiles(database: db, meetingID: meeting.id) == false,
            "a refused file remains, so removal does not report done")
    }

    @Test("removeAudioFiles refuses an unmarked row")
    func removalRequiresMark() async throws {
        let database = try makeDatabase()
        let id = try await insertMeeting(database)
        try touch(database.paths.audioURL(id))
        #expect(await AudioRetention.removeAudioFiles(database: database, meetingID: id) == false)
        #expect(FileManager.default.fileExists(atPath: database.paths.audioURL(id).path))
        #expect(await AudioRetention.sweepMarked(database: database).isEmpty)
    }

    @Test("containment: resolvedWithinMeetingsRoot accepts only paths strictly inside meetings/")
    func containment() throws {
        let database = try makeDatabase()
        let id = ULID.generate()
        try database.paths.createMeetingDirectory(id)
        let inside = database.paths.audioURL(id)
        #expect(MeetingDeletion.resolvedWithinMeetingsRoot(inside, database: database) != nil)
        #expect(MeetingDeletion.resolvedWithinMeetingsRoot(database.paths.meetingsDirectory, database: database) == nil)
        let traversal = database.paths.meetingDirectory(id).appendingPathComponent("../../victim")
        #expect(MeetingDeletion.resolvedWithinMeetingsRoot(traversal, database: database) == nil)
        #expect(MeetingDeletion.resolvedWithinMeetingsRoot(URL(fileURLWithPath: "/tmp/x"), database: database) == nil)
    }

    // MARK: AC4

    private func facts(
        _ status: MeetingStatus = .ready, marked: Bool = false, job: Bool = false,
        handoff: Bool = false, deliverAudio: Bool = false, mostRecent: Bool = false
    ) -> AudioRetention.EligibilityFacts {
        .init(
            status: status, marked: marked, liveProcessingJob: job,
            undeliveredHandoff: handoff, deliverAudio: deliverAudio, isMostRecent: mostRecent)
    }

    @Test("AC4: the §2 matrix, manual vs cap")
    func eligibilityMatrix() {
        let rows: [(AudioRetention.EligibilityFacts, AudioEligibility, AudioEligibility)] = [
            (facts(.recording), .refused(.recording), .refused(.recording)),
            (facts(.paused), .refused(.paused), .refused(.paused)),
            (facts(.processing), .refused(.processing), .refused(.processing)),
            (facts(marked: true), .refused(.alreadyDeleted), .refused(.alreadyDeleted)),
            (facts(job: true), .refused(.processingQueued), .refused(.processingQueued)),
            (facts(), .eligible(warnings: []), .eligible(warnings: [])),
            (facts(.failed), .eligible(warnings: [.cannotRetry]), .refused(.notEligibleForCap)),
            (facts(.cancelled), .eligible(warnings: [.cannotRetry]), .refused(.notEligibleForCap)),
            (facts(handoff: true, deliverAudio: true),
             .eligible(warnings: [.pendingAudioDelivery]), .refused(.notEligibleForCap)),
            (facts(handoff: true, deliverAudio: false), .eligible(warnings: []), .eligible(warnings: [])),
            (facts(mostRecent: true), .eligible(warnings: []), .refused(.notEligibleForCap)),
            (facts(.failed, handoff: true, deliverAudio: true),
             .eligible(warnings: [.cannotRetry, .pendingAudioDelivery]), .refused(.notEligibleForCap)),
        ]
        for (input, manual, cap) in rows {
            #expect(AudioRetention.evaluate(input, origin: .manual) == manual, "manual \(input)")
            #expect(AudioRetention.evaluate(input, origin: .cap) == cap, "cap \(input)")
        }
    }

    @Test("AC4: eligibility reads the facts from the database")
    func eligibilityFromDatabase() async throws {
        let database = try makeDatabase()
        let oldest = try await insertMeeting(database, startedAt: msDate(1_770_000_000))
        let failed = try await insertMeeting(database, status: .failed, startedAt: msDate(1_770_000_100))
        let queued = try await insertMeeting(database, startedAt: msDate(1_770_000_200))
        let undelivered = try await insertMeeting(database, startedAt: msDate(1_770_000_300))
        let processing = try await insertMeeting(database, status: .processing, startedAt: msDate(1_770_000_400))
        let newest = try await insertMeeting(database, startedAt: msDate(1_770_000_500))
        _ = try await ProcessingQueueRepository(database: database).enqueue(meetingID: queued, origin: .user)
        let path = try plantPayload(database, meetingID: undelivered, versionHash: "h-undelivered")
        _ = try await HandoffRepository(database: database)
            .enqueue(meetingID: undelivered, versionHash: "h-undelivered", payloadPath: path)

        func verdict(_ id: MeetingID, _ origin: AudioDeletionOrigin) async throws -> AudioEligibility {
            try await AudioRetention.eligibility(database: database, meetingID: id, origin: origin)
        }
        #expect(try await verdict(oldest, .cap) == .eligible(warnings: []))
        #expect(try await verdict(failed, .manual) == .eligible(warnings: [.cannotRetry]))
        #expect(try await verdict(failed, .cap) == .refused(.notEligibleForCap))
        #expect(try await verdict(queued, .manual) == .refused(.processingQueued))
        #expect(try await verdict(processing, .manual) == .refused(.processing))
        #expect(try await verdict(newest, .manual) == .eligible(warnings: []))
        #expect(try await verdict(newest, .cap) == .refused(.notEligibleForCap), "never the most recent")
        #expect(try await verdict(ULID.generate(), .manual) == .refused(.notFound))
        // Audio delivery OFF: the undelivered item does not matter.
        #expect(try await verdict(undelivered, .cap) == .eligible(warnings: []))
        try await SettingsStore(database: database).set(HandoffDestination.Key.deliverAudio, to: true)
        #expect(try await verdict(undelivered, .manual) == .eligible(warnings: [.pendingAudioDelivery]))
        #expect(try await verdict(undelivered, .cap) == .refused(.notEligibleForCap))

        try await AudioRetention.markDeleted(database: database, meetingID: oldest, reason: .cap)
        #expect(try await verdict(oldest, .manual) == .refused(.alreadyDeleted))
        #expect(try await verdict(oldest, .cap) == .refused(.alreadyDeleted))
    }

    @Test("deleteAudio on an already-marked meeting is a no-op that finishes residue")
    func alreadyDeletedIsNoOp() async throws {
        let (harness, meeting) = try await readyHarnessWithFullAudioSet()
        try await harness.pipeline.deleteAudio(meetingID: meeting.id, origin: .manual)
        let markedAt = try await rawColumn(harness.database, "audio_deleted_at", meeting.id)
        try touch(harness.database.paths.importCopyURL(meeting.id))  // residue
        let warnings = try await harness.pipeline.deleteAudio(meetingID: meeting.id, origin: .cap)
        #expect(warnings.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: harness.database.paths.importCopyURL(meeting.id).path))
        #expect(try await rawColumn(harness.database, "audio_deleted_at", meeting.id) == markedAt)
        #expect(try await rawColumn(harness.database, "audio_deleted_reason", meeting.id) == "manual")
    }

    // MARK: §4 usage

    @Test("§4 usage: allocated bytes per meeting, totals, eligibility sums")
    func usageTotals() async throws {
        let database = try makeDatabase()
        let paths = database.paths
        let older = try await insertMeeting(database, startedAt: msDate(1_770_000_000))
        let empty = try await insertMeeting(database, startedAt: msDate(1_770_000_100))
        let newest = try await insertMeeting(database, startedAt: msDate(1_770_000_200))
        _ = empty
        try touch(paths.audioURL(older), bytes: 10_000)
        try touch(paths.captureCAFURL(older, track: .mic), bytes: 5_000)
        try touch(paths.importCopyURL(older), bytes: 3_000)
        try touch(paths.rawASRURL(older), bytes: 50_000)  // derived: not counted
        try touch(paths.audioMicURL(newest, part: 2), bytes: 7_000)

        func allocated(_ url: URL) -> Int64 {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            return Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        let olderBytes = [paths.audioURL(older), paths.captureCAFURL(older, track: .mic), paths.importCopyURL(older)]
            .reduce(Int64(0)) { $0 + allocated($1) }
        let newestBytes = allocated(paths.audioMicURL(newest, part: 2))
        #expect(olderBytes >= 18_000)

        let usage = try await AudioRetention.usage(database: database)
        #expect(usage.entries.map(\.meetingID) == [older, empty, newest], "oldest first")
        #expect(usage.entries[0].bytes == olderBytes)
        #expect(usage.entries[1].bytes == 0)
        #expect(usage.entries[2].bytes == newestBytes)
        #expect(usage.totalBytes == olderBytes + newestBytes)
        #expect(usage.meetingsWithAudio == 2)
        #expect(usage.entries[2].capEligible == false, "the most recent is never cap-eligible")
        #expect(usage.entries[2].manualEligible)
        #expect(usage.capEligibleBytes == olderBytes)
        #expect(usage.manualEligibleBytes == olderBytes + newestBytes)

        try await AudioRetention.markDeleted(database: database, meetingID: older, reason: .manual)
        let marked = try await AudioRetention.usage(database: database)
        #expect(marked.entries[0].audioDeletedAt != nil)
        #expect(marked.entries[0].manualEligible == false)
        #expect(marked.entries[0].capEligible == false)
    }

    // MARK: payload / encoding

    @Test("the mark never reaches the handoff payload or the Meeting encoding")
    func payloadUnaffectedByMark() async throws {
        let (harness, meeting) = try await readyHarnessWithFullAudioSet()
        let db = harness.database
        let notes = try #require(try await NotesRepository(database: db).fetch(meetingID: meeting.id))
        let segments = try await harness.segments(meeting.id)
        let before = EvidencePayloadBuilder.build(
            meeting: meeting, segments: segments, notes: notes, user: .onboardedUser, corrections: [])

        try await harness.pipeline.deleteAudio(meetingID: meeting.id, origin: .manual)
        let marked = try #require(try await harness.meeting(meeting.id))
        #expect(marked.audioDeletedAt != nil)
        let after = EvidencePayloadBuilder.build(
            meeting: marked, segments: segments, notes: notes, user: .onboardedUser, corrections: [])
        #expect(after.versionHash == before.versionHash)
        #expect(after.bytes == before.bytes)

        let encoded = String(decoding: try JSONEncoder().encode(marked), as: UTF8.self)
        #expect(!encoded.contains("audio_deleted"))
        var unmarked = marked
        unmarked.audioDeletedAt = nil
        unmarked.audioDeletedReason = nil
        #expect(try JSONEncoder().encode(unmarked) == JSONEncoder().encode(marked))
    }
}
