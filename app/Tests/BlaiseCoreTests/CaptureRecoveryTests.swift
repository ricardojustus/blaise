import AVFoundation
import Foundation
import Testing

@testable import BlaiseCore

// C11 AC1: the orphan-CAF sweep + verified-encode gate over PLANTED CAF
// fixtures (no real capture, no TCC). Includes the truncated-CAF case:
// encode fails → CAF retained + surfaced via the capture-recovery note.

/// Plants a valid LPCM CAF capture track (1 s sine) at the track path.
private func plantCAF(paths: MeetingPaths, meetingID: MeetingID, track: CaptureTrack) throws {
    let writer = try CaptureCAFWriter(url: paths.captureCAFURL(meetingID, track: track))
    let format = CaptureCAFWriter.format
    let frames: AVAudioFrameCount = 16_000
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    let samples = buffer.int16ChannelData![0]
    for n in 0 ..< Int(frames) {
        samples[n] = Int16(5000 * sin(2 * .pi * 330 * Double(n) / 16_000))
    }
    try writer.write(buffer)
    writer.close()
}

/// Plants a CORRUPT capture CAF (a crash can truncate the header mid-write;
/// AVAudioFile cannot open it → the encode fails → retention must hold).
private func plantCorruptCAF(paths: MeetingPaths, meetingID: MeetingID, track: CaptureTrack) throws {
    try Data("caffXX-truncated-garbage".utf8)
        .write(to: paths.captureCAFURL(meetingID, track: track))
}

private func makeCapturedMeetingRow(
    _ database: BlaiseDatabase, status: MeetingStatus = .failed
) async throws -> MeetingID {
    let meeting = makeMeeting(source: .meet, status: status)
    try database.paths.createMeetingDirectory(meeting.id)
    try await MeetingRepository(database: database).create(meeting)
    return meeting.id
}

@Suite("C11 capture recovery")
struct CaptureRecoveryTests {
    @Test("encodeVerifiedAndRelease: m4a produced + verified, CAF deleted only after")
    func encodeAndRelease() async throws {
        let database = try makeDatabase()
        let id = try await makeCapturedMeetingRow(database)
        try plantCAF(paths: database.paths, meetingID: id, track: .system)
        let caf = database.paths.captureCAFURL(id, track: .system)
        let m4a = database.paths.audioURL(id)

        try CaptureRecovery.encodeVerifiedAndRelease(caf: caf, m4a: m4a)

        #expect(!FileManager.default.fileExists(atPath: caf.path))
        let duration = try AudioTranscoder.duration(of: m4a)
        #expect(abs(duration - 1.0) <= 0.5)
    }

    @Test("crash between encode and release: existing m4a verified, CAF released, no re-encode")
    func alreadyEncoded() async throws {
        let database = try makeDatabase()
        let id = try await makeCapturedMeetingRow(database)
        try plantCAF(paths: database.paths, meetingID: id, track: .mic)
        let caf = database.paths.captureCAFURL(id, track: .mic)
        let m4a = database.paths.audioMicURL(id)
        try CaptureRecovery.encodeVerifiedAndRelease(caf: caf, m4a: m4a)

        // Simulate the crash window: CAF back on disk, m4a already verified.
        try plantCAF(paths: database.paths, meetingID: id, track: .mic)
        let bytesBefore = try Data(contentsOf: m4a)
        try CaptureRecovery.encodeVerifiedAndRelease(caf: caf, m4a: m4a)
        #expect(!FileManager.default.fileExists(atPath: caf.path))
        #expect(try Data(contentsOf: m4a) == bytesBefore)  // untouched, not re-encoded
    }

    @Test("corrupt CAF: encode fails, CAF RETAINED, no m4a appears")
    func corruptCAFRetained() async throws {
        let database = try makeDatabase()
        let id = try await makeCapturedMeetingRow(database)
        try plantCorruptCAF(paths: database.paths, meetingID: id, track: .system)
        let caf = database.paths.captureCAFURL(id, track: .system)
        let m4a = database.paths.audioURL(id)

        #expect(throws: (any Error).self) {
            try CaptureRecovery.encodeVerifiedAndRelease(caf: caf, m4a: m4a)
        }
        #expect(FileManager.default.fileExists(atPath: caf.path))
        #expect(!FileManager.default.fileExists(atPath: m4a.path))
    }

    @Test("finalizeTracks: both tracks verified → bothTracks, no note")
    func finalizeBoth() async throws {
        let database = try makeDatabase()
        let id = try await makeCapturedMeetingRow(database)
        try plantCAF(paths: database.paths, meetingID: id, track: .system)
        try plantCAF(paths: database.paths, meetingID: id, track: .mic)

        let outcome = CaptureRecovery.finalizeTracks(paths: database.paths, meetingID: id)
        #expect(outcome.bothTracks)
        #expect(outcome.recoveryNote == nil)
        #expect(FileManager.default.fileExists(atPath: database.paths.audioURL(id).path))
        #expect(FileManager.default.fileExists(atPath: database.paths.audioMicURL(id).path))
    }

    @Test("finalizeTracks: one corrupt track → survivor encoded, CAF retained, note flags it")
    func finalizePartial() async throws {
        let database = try makeDatabase()
        let id = try await makeCapturedMeetingRow(database)
        try plantCAF(paths: database.paths, meetingID: id, track: .system)
        try plantCorruptCAF(paths: database.paths, meetingID: id, track: .mic)

        let outcome = CaptureRecovery.finalizeTracks(paths: database.paths, meetingID: id)
        #expect(!outcome.bothTracks)
        #expect(outcome.anyTrack)
        #expect(outcome.encodedTracks == [.system])
        let note = try #require(outcome.recoveryNote)
        #expect(note.hasPrefix(CaptureRecovery.notePrefix))
        #expect(note.contains("mic track audio damaged"))
        #expect(note.contains("system"))
        // The truncated CAF stays on disk; no audio_mic.m4a appears.
        #expect(
            FileManager.default.fileExists(
                atPath: database.paths.captureCAFURL(id, track: .mic).path))
        #expect(!FileManager.default.fileExists(atPath: database.paths.audioMicURL(id).path))
    }

    @Test("startup sweep: orphans encoded + auto-kicked; partial gets the note; survivor still kicks")
    func sweep() async throws {
        let database = try makeDatabase()
        let healthy = try await makeCapturedMeetingRow(database)
        try plantCAF(paths: database.paths, meetingID: healthy, track: .system)
        try plantCAF(paths: database.paths, meetingID: healthy, track: .mic)
        let partial = try await makeCapturedMeetingRow(database)
        try plantCAF(paths: database.paths, meetingID: partial, track: .system)
        try plantCorruptCAF(paths: database.paths, meetingID: partial, track: .mic)

        let kicked = Recorder<MeetingID>()
        let results = await CaptureRecovery.sweepOrphanCAFs(database: database) { id in
            kicked.append(id)
        }

        #expect(results.count == 2)
        #expect(Set(kicked.values) == [healthy, partial])
        // Healthy: both m4as, CAFs gone, no note.
        #expect(FileManager.default.fileExists(atPath: database.paths.audioURL(healthy).path))
        #expect(FileManager.default.fileExists(atPath: database.paths.audioMicURL(healthy).path))
        #expect(
            !FileManager.default.fileExists(
                atPath: database.paths.captureCAFURL(healthy, track: .system).path))
        let healthyNote = try await MeetingRepository(database: database).fetch(healthy)?.processingNote
        #expect(healthyNote == nil)
        // Partial: note persisted on the row; damaged CAF retained.
        let partialNote = try await MeetingRepository(database: database).fetch(partial)?.processingNote
        #expect(partialNote?.hasPrefix(CaptureRecovery.notePrefix) == true)
        #expect(
            FileManager.default.fileExists(
                atPath: database.paths.captureCAFURL(partial, track: .mic).path))
    }

    @Test("sweep NEVER touches an actively-recording meeting (live writer protection)")
    func sweepSkipsLiveRecording() async throws {
        let database = try makeDatabase()
        // A row still in `recording` when the sweep runs IS a live session:
        // the DB startup sweep (at open) has already failed every crashed one.
        let live = try await makeCapturedMeetingRow(database, status: .recording)
        try plantCAF(paths: database.paths, meetingID: live, track: .system)
        try plantCAF(paths: database.paths, meetingID: live, track: .mic)

        let kicked = Recorder<MeetingID>()
        let results = await CaptureRecovery.sweepOrphanCAFs(database: database) { kicked.append($0) }

        #expect(results.isEmpty)
        #expect(kicked.values.isEmpty)
        // The live CAFs are untouched; no m4a appeared; no note written.
        for track in CaptureTrack.allCases {
            #expect(
                FileManager.default.fileExists(
                    atPath: database.paths.captureCAFURL(live, track: track).path))
        }
        #expect(!FileManager.default.fileExists(atPath: database.paths.audioURL(live).path))
        #expect(!FileManager.default.fileExists(atPath: database.paths.audioMicURL(live).path))
        let note = try await MeetingRepository(database: database).fetch(live)?.processingNote
        #expect(note == nil)
    }

    @Test("G10 §1: sweep ENCODES a cancelled meeting's parts (retention) but WITHHOLDS the kick")
    func sweepEncodesCancelledButWithholdsKick() async throws {
        let database = try makeDatabase()
        let cancelled = try await makeCapturedMeetingRow(database, status: .cancelled)
        try plantCAF(paths: database.paths, meetingID: cancelled, track: .system)
        try plantCAF(paths: database.paths, meetingID: cancelled, track: .mic)

        let kicked = Recorder<MeetingID>()
        let results = await CaptureRecovery.sweepOrphanCAFs(database: database) { kicked.append($0) }

        // Encoded for retention (floor 2): the m4a exists, the CAF released.
        #expect(FileManager.default.fileExists(atPath: database.paths.audioURL(cancelled).path))
        #expect(!FileManager.default.fileExists(atPath: database.paths.captureCAFURL(cancelled, track: .system).path))
        // But the kick is WITHHELD — the user cancelled; no auto-resurrection.
        #expect(kicked.values.isEmpty, "a cancelled meeting's kick is withheld")
        #expect(results.first?.kicked == false)
    }

    @Test("sweep skips directories without a meeting row, leaves files in place")
    func sweepUnknownMeeting() async throws {
        let database = try makeDatabase()
        let orphanID = ULID.generate()
        try database.paths.createMeetingDirectory(orphanID)
        try plantCAF(paths: database.paths, meetingID: orphanID, track: .system)

        let kicked = Recorder<MeetingID>()
        let results = await CaptureRecovery.sweepOrphanCAFs(database: database) { kicked.append($0) }
        #expect(results.isEmpty)
        #expect(kicked.values.isEmpty)
        #expect(
            FileManager.default.fileExists(
                atPath: database.paths.captureCAFURL(orphanID, track: .system).path))
    }

    @Test("dismissRecoveryNote clears only the capture-recovery class")
    func dismissal() async throws {
        let database = try makeDatabase()
        let id = try await makeCapturedMeetingRow(database)
        await CaptureRecovery.writeRecoveryNote(
            database: database, meetingID: id,
            note: "\(CaptureRecovery.notePrefix) mic track audio damaged")
        await CaptureRecovery.dismissRecoveryNote(database: database, meetingID: id)
        let note = try await MeetingRepository(database: database).fetch(id)?.processingNote
        #expect(note == nil)

        // A fallback-class note is NOT dismissable through this path.
        await CaptureRecovery.writeRecoveryNote(
            database: database, meetingID: id, note: "fallback: input too long")
        await CaptureRecovery.dismissRecoveryNote(database: database, meetingID: id)
        let fallbackNote = try await MeetingRepository(database: database).fetch(id)?.processingNote
        #expect(fallbackNote == "fallback: input too long")
    }
}

// MARK: - Launch re-dispatch for interrupted meetings (quit-during-recording)

@Suite("C11 interrupted re-dispatch")
struct RedispatchInterruptedTests {
    private func plantInterrupted(
        _ database: BlaiseDatabase, error: String = "interrupted", withAudio: Bool
    ) async throws -> MeetingID {
        let meeting = makeMeeting(source: .meet, status: .failed)
        try database.paths.createMeetingDirectory(meeting.id)
        try await MeetingRepository(database: database).create(meeting)
        try await database.pool.write { db in
            try db.execute(
                sql: "UPDATE meeting SET last_processing_error = ? WHERE id = ?",
                arguments: [error, meeting.id])
        }
        if withAudio {
            try Data("m4a-bytes".utf8).write(to: database.paths.audioURL(meeting.id))
        }
        return meeting.id
    }

    @Test("interrupted meeting with retained audio is auto-kicked at launch")
    func kicksInterruptedWithAudio() async throws {
        let database = try makeDatabase()
        let withAudio = try await plantInterrupted(database, withAudio: true)
        let withoutAudio = try await plantInterrupted(database, withAudio: false)
        let otherError = try await plantInterrupted(
            database, error: "asr exploded", withAudio: true)

        let kicked = Recorder<MeetingID>()
        let result = await CaptureRecovery.redispatchInterrupted(database: database) {
            kicked.append($0)
        }
        #expect(result == [withAudio])
        #expect(kicked.values == [withAudio])
        _ = withoutAudio
        _ = otherError
    }

    @Test("mic-only retained audio also qualifies; excluded meetings are skipped")
    func micOnlyAndExclusion() async throws {
        let database = try makeDatabase()
        let micOnly = try await plantInterrupted(database, withAudio: false)
        try Data("m4a-bytes".utf8).write(to: database.paths.audioMicURL(micOnly))
        let excluded = try await plantInterrupted(database, withAudio: true)

        let kicked = Recorder<MeetingID>()
        let result = await CaptureRecovery.redispatchInterrupted(
            database: database, excluding: [excluded]
        ) { kicked.append($0) }
        #expect(result == [micOnly])
        #expect(kicked.values == [micOnly])
    }
}

// MARK: - Stale-aggregate guard (live sessions protected)

@Suite("C11 stale-aggregate guard")
struct StaleAggregateGuardTests {
    @Test("a live session's aggregate UID is never classified stale")
    func liveUIDProtected() {
        let liveUID = CaptureDescriptors.makeAggregateUID()
        let crashedUID = CaptureDescriptors.makeAggregateUID()
        CaptureSession.liveAggregateUIDs.withLock { _ = $0.insert(liveUID) }
        defer { CaptureSession.liveAggregateUIDs.withLock { _ = $0.remove(liveUID) } }

        #expect(!CaptureSession.isStaleAggregate(uid: liveUID))
        #expect(CaptureSession.isStaleAggregate(uid: crashedUID))
        // Foreign devices are never ours to destroy.
        #expect(!CaptureSession.isStaleAggregate(uid: "com.apple.BuiltInSpeakerDevice"))
    }
}
