import Foundation
import Testing
@testable import BlaiseCore

@Suite struct ImmutablePayloadWriterTests {
    @Test func writesBytesAtomically() throws {
        let root = try makeTempRoot()
        let url = root.appendingPathComponent("payloads/abc.json")
        let data = Data("{\"native_id\":\"x\"}\n".utf8)
        try ImmutablePayloadWriter.write(data, to: url)
        #expect(try Data(contentsOf: url) == data)
    }

    @Test func identicalBytesRewriteIsNoOp() throws {
        let root = try makeTempRoot()
        let url = root.appendingPathComponent("p.json")
        let data = Data("same".utf8)
        try ImmutablePayloadWriter.write(data, to: url)
        let before = try FileIdentity(of: url)
        try ImmutablePayloadWriter.write(data, to: url)
        let after = try FileIdentity(of: url)
        #expect(after == before, "identical rewrite must not touch the file (same inode, mtime, bytes)")
    }

    @Test func differentBytesWriteFails() throws {
        let root = try makeTempRoot()
        let url = root.appendingPathComponent("p.json")
        try ImmutablePayloadWriter.write(Data("original".utf8), to: url)
        #expect(throws: ImmutablePayloadWriter.WriteError.conflictingContent(path: url.path)) {
            try ImmutablePayloadWriter.write(Data("DIFFERENT".utf8), to: url)
        }
        #expect(try Data(contentsOf: url) == Data("original".utf8), "original bytes must survive the rejected overwrite")
    }

    @Test func injectedMidWriteFailureLeavesNoPartialFile() throws {
        let root = try makeTempRoot()
        let dir = root.appendingPathComponent("handoff", isDirectory: true)
        let url = dir.appendingPathComponent("p.json")
        #expect(throws: TestFailure.self) {
            try ImmutablePayloadWriter.write(Data("partial".utf8), to: url, midWriteHook: { throw TestFailure() })
        }
        #expect(!FileManager.default.fileExists(atPath: url.path), "no partial file at the final path")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(leftovers.isEmpty, "temp file must be cleaned up, found: \(leftovers)")
    }
}

@Suite struct MeetingPathsTests {
    @Test func layoutMatchesSpec() {
        let root = URL(fileURLWithPath: "/data/root")
        let paths = MeetingPaths(rootURL: root)
        let id: MeetingID = "01JX0EXAMP0000000000000TAB"
        #expect(paths.meetingDirectory(id).path == "/data/root/meetings/\(id)")
        #expect(paths.audioURL(id).path == "/data/root/meetings/\(id)/audio.m4a")
        #expect(paths.audioURL(id).pathExtension == AudioConstants.retainedFormat.fileExtension)
        #expect(paths.rawASRURL(id).path == "/data/root/meetings/\(id)/raw_asr.json")
        #expect(paths.transcriptURL(id).path == "/data/root/meetings/\(id)/transcript.json")
        #expect(paths.notesURL(id).path == "/data/root/meetings/\(id)/notes.md")
        #expect(paths.handoffPayloadURL(meetingID: id, versionHash: "h1").path == "/data/root/meetings/\(id)/handoff/h1.json")
        let relative = paths.relativeHandoffPayloadPath(meetingID: id, versionHash: "h1")
        #expect(root.appendingPathComponent(relative).path == paths.handoffPayloadURL(meetingID: id, versionHash: "h1").path)
    }

    @Test func createMeetingDirectoryCreatesHandoffSubdirectory() throws {
        let root = try makeTempRoot()
        let paths = MeetingPaths(rootURL: root)
        let id = ULID.generate()
        try paths.createMeetingDirectory(id)
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: paths.handoffDirectory(id).path, isDirectory: &isDir))
        #expect(isDir.boolValue)
    }

    /// AC6 audio-retention guard: plant audio.m4a, exercise every mutating
    /// C1 API around it, assert the file is untouched. (No BlaiseCore API
    /// deletes or overwrites audio*.m4a; MeetingPaths has no removal helper.)
    @Test func retainedAudioSurvivesAllC1Mutations() async throws {
        let database = try makeDatabase()
        let meeting = makeMeeting()
        try await MeetingRepository(database: database).create(meeting)

        let paths = database.paths
        try paths.createMeetingDirectory(meeting.id)
        let audioURL = paths.audioURL(meeting.id)
        let audioBytes = Data((0..<4096).map { UInt8($0 % 251) })
        try audioBytes.write(to: audioURL)
        let before = try FileIdentity(of: audioURL)

        // Exercise transcript replace + delete, notes upsert, handoff enqueue, finalize.
        let transcripts = TranscriptRepository(database: database)
        try await transcripts.replaceAllSegments(
            meetingID: meeting.id,
            with: [TranscriptSegment(meetingID: meeting.id, ord: 0, startSeconds: 0, endSeconds: 1, text: "áudio retido")]
        )
        try await transcripts.deleteTranscript(meetingID: meeting.id)
        try await NotesRepository(database: database).upsert(makeNotes(meetingID: meeting.id))
        let path = try plantPayload(database, meetingID: meeting.id, versionHash: "h-audio")
        try await HandoffRepository(database: database).enqueue(meetingID: meeting.id, versionHash: "h-audio", payloadPath: path)
        try await database.finalizeMeetingProcessing(
            meetingID: meeting.id, versionHash: "h-audio", payloadPath: path, notes: makeNotes(meetingID: meeting.id)
        )

        let after = try FileIdentity(of: audioURL)
        #expect(after == before, "audio.m4a must be byte-identical and untouched (inode + mtime + bytes)")
    }
}

// Impl-audit round-1 regression tests (audits/c1/impl_audit_round1.md)
@Suite struct ImmutableWriterConcurrencyTests {
    /// F1: two writers racing the exists-check must never both succeed with
    /// different bytes — RENAME_EXCL makes check-and-rename atomic.
    @Test func concurrentWritersCannotClobber() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }

        for round in 0..<25 {
            let url = dir.appendingPathComponent("race-\(round).json")
            let outcomes = await withTaskGroup(of: Bool.self) { group in
                for i in 0..<4 {
                    group.addTask {
                        do {
                            try ImmutablePayloadWriter.write(Data("content-\(i)".utf8), to: url)
                            return true
                        } catch { return false }
                    }
                }
                var results: [Bool] = []
                for await ok in group { results.append(ok) }
                return results
            }
            let winners = outcomes.filter { $0 }.count
            #expect(winners == 1, "exactly one distinct-bytes writer may win (round \(round), got \(winners))")
            let final = try Data(contentsOf: url)
            #expect(final.count == "content-0".utf8.count)
        }
    }

    /// F1 corollary: losing a race to IDENTICAL bytes is a no-op success.
    @Test func raceToIdenticalBytesIsNoOp() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("same.json")
        let data = Data("same-bytes".utf8)
        let outcomes = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    do { try ImmutablePayloadWriter.write(data, to: url); return true }
                    catch { return false }
                }
            }
            var results: [Bool] = []
            for await ok in group { results.append(ok) }
            return results
        }
        #expect(outcomes.allSatisfy { $0 }, "identical-bytes writers must all no-op successfully")
    }
}

@Suite struct UlidAndHashValidationTests {
    @Test func ulidValidation() {
        #expect(ULID.isValid(ULID.generate()))
        #expect(!ULID.isValid("not-a-ulid"))
        #expect(!ULID.isValid("../escape/../../etc/passwd"))
        #expect(!ULID.isValid(String(repeating: "Z", count: 26)), "first char > 7 exceeds 48-bit time")
        #expect(!ULID.isValid(""))
    }

    @Test func versionHashValidation() {
        #expect(MeetingPaths.isValidVersionHash(String(repeating: "ab12", count: 16)))
        #expect(!MeetingPaths.isValidVersionHash("ABCD"), "uppercase/short rejected")
        #expect(!MeetingPaths.isValidVersionHash(String(repeating: "g", count: 64)), "non-hex rejected")
    }
}
