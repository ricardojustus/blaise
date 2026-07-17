import CryptoKit
import Foundation
import Testing
@testable import BlaiseCore

// G5 v1.3 — superseded-payload cleanup at the destination (AC8) + opt-in audio
// delivery (AC9) + the docs-promise wording (AC9). Shares seedDeliverable /
// makeWorker / MockTransport / selectLocalFolder with the sibling G5 suites.

private func g5TempFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("g5-audio-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func selectLocalDest(
    _ database: BlaiseDatabase, _ folder: URL, sidecar: Bool = true,
    keepHistory: Bool? = nil, deliverAudio: Bool? = nil
) async throws {
    let store = SettingsStore(database: database)
    let bookmark = try folder.bookmarkData(
        options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    try await store.set(HandoffDestination.Key.kind, to: HandoffDestination.Kind.localFolder)
    try await store.set(HandoffDestination.Key.localBookmark, to: bookmark.base64EncodedString())
    try await store.set(HandoffDestination.Key.localPath, to: folder.path)
    try await store.set(HandoffDestination.Key.localMarkdownSidecar, to: sidecar)
    if let keepHistory { try await store.set(HandoffDestination.Key.keepPayloadHistory, to: keepHistory) }
    if let deliverAudio { try await store.set(HandoffDestination.Key.deliverAudio, to: deliverAudio) }
}

/// Writes a dummy retained audio file into the meeting dir.
@discardableResult
private func writeAudio(_ database: BlaiseDatabase, _ meetingID: MeetingID, _ name: String, bytes: Int) throws -> Int {
    let dir = database.paths.meetingDirectory(meetingID)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data(repeating: 0xAB, count: bytes).write(to: dir.appendingPathComponent(name))
    return bytes
}

/// Re-mints a DIFFERENT payload version for the same meeting (a correction /
/// regeneration) and enqueues it — a distinct `<hash>.json`.
@discardableResult
private func enqueueSecondVersion(_ database: BlaiseDatabase, _ meetingID: MeetingID) async throws -> HandoffItem {
    guard var notes = try await NotesRepository(database: database).fetch(meetingID: meetingID),
        let meeting = try await MeetingRepository(database: database).fetch(meetingID)
    else { throw TestFailure() }
    notes.markdown += "\n<!-- v2 correction -->"
    let segments = try await TranscriptRepository(database: database).segments(meetingID: meetingID)
    let payload = EvidencePayloadBuilder.build(
        meeting: meeting, segments: segments, notes: notes, user: .shippedDefault)
    let relative = database.paths.relativeHandoffPayloadPath(
        meetingID: meetingID, versionHash: payload.versionHash)
    try ImmutablePayloadWriter.write(
        payload.bytes, to: database.rootURL.appendingPathComponent(relative))
    let updatedNotes = notes
    try await database.pool.write { try updatedNotes.upsert($0) }
    return try await HandoffRepository(database: database)
        .enqueue(meetingID: meetingID, versionHash: payload.versionHash, payloadPath: relative)
}

private func jsonNames(_ dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        .filter { $0.hasSuffix(".json") }.sorted()
}
private func mdNames(_ dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        .filter { $0.hasSuffix(".md") }
}
private func audioNames(_ dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        .filter { $0.hasPrefix("audio") && $0.hasSuffix(".m4a") }.sorted()
}

// MARK: - AC8: superseded-payload cleanup

@Suite(.serialized) struct G5CleanupTests {
    @Test func localDeliverV1CorrectDeliverV2LeavesOnlyV2() async throws {
        let database = try makeDatabase()
        let v1 = try await seedDeliverable(database, title: "Correção")
        let folder = try g5TempFolder()
        try await selectLocalDest(database, folder, sidecar: true, keepHistory: false)

        let worker = makeWorker(database)
        await worker.start()
        await worker.waitUntilSettled()
        let destDir = folder.appendingPathComponent(v1.meetingID)
        #expect(jsonNames(destDir) == ["\(v1.versionHash).json"])

        // Correct → v2 → deliver again.
        let v2 = try await enqueueSecondVersion(database, v1.meetingID)
        #expect(v2.versionHash != v1.versionHash)
        await worker.kick()
        await worker.waitUntilSettled()

        // Exactly the v2 payload + one sidecar remain; v1's json is gone.
        #expect(jsonNames(destDir) == ["\(v2.versionHash).json"])
        #expect(mdNames(destDir).count == 1)

        // The LOCAL handoff/ snapshots are untouched (both hashes retained).
        let handoffDir = database.paths.handoffDirectory(v1.meetingID)
        #expect(FileManager.default.fileExists(
            atPath: handoffDir.appendingPathComponent("\(v1.versionHash).json").path))
        #expect(FileManager.default.fileExists(
            atPath: handoffDir.appendingPathComponent("\(v2.versionHash).json").path))
    }

    @Test func keepPayloadHistoryPreservesBothPayloads() async throws {
        let database = try makeDatabase()
        let v1 = try await seedDeliverable(database, title: "History")
        let folder = try g5TempFolder()
        try await selectLocalDest(database, folder, sidecar: false, keepHistory: true)

        let worker = makeWorker(database)
        await worker.start()
        await worker.waitUntilSettled()
        let v2 = try await enqueueSecondVersion(database, v1.meetingID)
        await worker.kick()
        await worker.waitUntilSettled()

        let destDir = folder.appendingPathComponent(v1.meetingID)
        #expect(jsonNames(destDir) == ["\(v1.versionHash).json", "\(v2.versionHash).json"].sorted())
    }

    @Test func sshCleanupEmitsGlobRemovalAfterDelivery() async throws {
        let database = try makeDatabase()
        let item = try await seedDeliverable(database, title: "SSH cleanup")  // sidecar OFF
        try await SettingsStore(database: database)
            .set(HandoffDestination.Key.keepPayloadHistory, to: false)  // cleanup ON
        let transport = MockTransport()
        let worker = makeWorker(database, transport: transport)
        await worker.kick()
        await worker.waitUntilSettled()

        // JSON (0) then the cleanup glob removal (1), default keepHistory=false.
        #expect(transport.calls.count == 2)
        let remoteDir = handoffValidExample.remoteRoot + "/" + item.meetingID
        #expect(transport.calls[1].argv == HandoffCommand.cleanupArgv(
            user: handoffValidExample.user, host: handoffValidExample.hosts[0],
            identityFile: handoffValidExample.identityFile,
            remoteDir: remoteDir, keepHash: item.versionHash))
        #expect(transport.calls[1].argv.last
            == "cd '\(remoteDir)' 2>/dev/null || exit 0; "
            + "for f in *.json; do [ -e \"$f\" ] || continue; "
            + "[ \"$f\" = '\(item.versionHash).json' ] || rm -f \"$f\"; done")
    }

    @Test func sshKeepHistorySkipsCleanupCall() async throws {
        let database = try makeDatabase()
        _ = try await seedDeliverable(database, title: "Keep")
        try await SettingsStore(database: database)
            .set(HandoffDestination.Key.keepPayloadHistory, to: true)
        let transport = MockTransport()
        let worker = makeWorker(database, transport: transport)
        await worker.kick()
        await worker.waitUntilSettled()
        #expect(transport.calls.count == 1, "keepPayloadHistory ⇒ no cleanup call")
    }

    @Test func sshCleanupFailureDoesNotFailDelivery() async throws {
        let database = try makeDatabase()
        let item = try await seedDeliverable(database, title: "Isolated cleanup")
        try await SettingsStore(database: database)
            .set(HandoffDestination.Key.keepPayloadHistory, to: false)  // cleanup ON
        // JSON succeeds; the cleanup call fails non-zero — isolated.
        let transport = MockTransport(script: [
            HandoffTransportOutcome(exitStatus: 0, stderrTail: "", timedOut: false),
            HandoffTransportOutcome(exitStatus: 255, stderrTail: "cleanup boom", timedOut: false),
        ])
        let worker = makeWorker(database, transport: transport)
        await worker.kick()
        await worker.waitUntilSettled()

        let rows = try await HandoffRepository(database: database).allItems()
        #expect(rows.first?.id == item.id)
        #expect(rows.first?.state == .delivered, "cleanup failure never un-delivers the JSON")
    }
}

// MARK: - AC9: opt-in audio delivery

@Suite(.serialized) struct G5AudioDeliveryTests {
    @Test func audioOffDeliversNoAudioAtDestination() async throws {
        let database = try makeDatabase()
        let item = try await seedDeliverable(database, title: "No audio")
        try writeAudio(database, item.meetingID, "audio.m4a", bytes: 256)
        let folder = try g5TempFolder()
        try await selectLocalDest(database, folder, sidecar: false)  // deliverAudio absent ⇒ OFF

        let worker = makeWorker(database)
        await worker.start()
        await worker.waitUntilSettled()

        let destDir = folder.appendingPathComponent(item.meetingID)
        #expect(jsonNames(destDir) == ["\(item.versionHash).json"])
        #expect(audioNames(destDir).isEmpty, "OFF ⇒ zero audio at the destination (regression pin)")
    }

    @Test func audioOnDeliversFullRetainedSetAndKeepsPayloadStable() async throws {
        let database = try makeDatabase()
        let item = try await seedDeliverable(database, title: "With audio")
        try writeAudio(database, item.meetingID, "audio.m4a", bytes: 300)
        try writeAudio(database, item.meetingID, "audio_mic.m4a", bytes: 200)
        try writeAudio(database, item.meetingID, "audio_2.m4a", bytes: 100)
        let folder = try g5TempFolder()
        try await selectLocalDest(database, folder, sidecar: false, deliverAudio: true)

        let worker = makeWorker(database)
        await worker.start()
        await worker.waitUntilSettled()

        let destDir = folder.appendingPathComponent(item.meetingID)
        // Full retained set delivered under canonical names.
        #expect(audioNames(destDir) == ["audio.m4a", "audio_2.m4a", "audio_mic.m4a"])
        for name in ["audio.m4a", "audio_mic.m4a", "audio_2.m4a"] {
            let src = try Data(contentsOf: database.paths.meetingDirectory(item.meetingID)
                .appendingPathComponent(name))
            let dst = try Data(contentsOf: destDir.appendingPathComponent(name))
            #expect(src == dst)
        }
        // The payload bytes/hash are unchanged by the toggle (no audio field).
        let json = try Data(contentsOf: destDir.appendingPathComponent("\(item.versionHash).json"))
        #expect(EvidencePayloadBuilder.sha256Hex(json) == item.versionHash)
    }

    @Test func sshAudioSizeMatchSkipsRewrite() async throws {
        let database = try makeDatabase()
        let item = try await seedDeliverable(database, title: "Size skip")
        let size = try writeAudio(database, item.meetingID, "audio.m4a", bytes: 512)
        try await SettingsStore(database: database)
            .set(HandoffDestination.Key.deliverAudio, to: true)
        // Call 0 = JSON; call 1 = the `wc -c` pre-check returning the MATCHING
        // size on stdout → the write is skipped.
        let transport = MockTransport(script: [
            HandoffTransportOutcome(exitStatus: 0, stderrTail: "", timedOut: false),
            HandoffTransportOutcome(
                exitStatus: 0, stderrTail: "", timedOut: false, stdout: Data("\(size)\n".utf8)),
        ])
        let worker = makeWorker(database, transport: transport)
        await worker.kick()
        await worker.waitUntilSettled()

        let remoteDir = handoffValidExample.remoteRoot + "/" + item.meetingID
        let commands = transport.calls.compactMap { $0.argv.last }
        #expect(commands.contains { $0 == "wc -c < '\(remoteDir)/audio.m4a' 2>/dev/null" })
        #expect(
            !commands.contains { $0.contains("cat > '\(remoteDir)/audio.m4a'") },
            "a size-matched audio file is not re-written")
    }

    @Test func sshAudioFailureNeverFailsJSONDelivery() async throws {
        let database = try makeDatabase()
        let item = try await seedDeliverable(database, title: "Audio fail")
        try writeAudio(database, item.meetingID, "audio.m4a", bytes: 400)
        try await SettingsStore(database: database)
            .set(HandoffDestination.Key.deliverAudio, to: true)
        // JSON ok; wc -c returns no match (empty stdout); the write fails 255.
        let transport = MockTransport(script: [
            HandoffTransportOutcome(exitStatus: 0, stderrTail: "", timedOut: false),  // JSON
            HandoffTransportOutcome(exitStatus: 0, stderrTail: "", timedOut: false),  // wc -c (no match)
            HandoffTransportOutcome(exitStatus: 255, stderrTail: "audio boom", timedOut: false),  // write
        ])
        let worker = makeWorker(database, transport: transport)
        await worker.kick()
        await worker.waitUntilSettled()

        let rows = try await HandoffRepository(database: database).allItems()
        #expect(rows.first?.id == item.id)
        #expect(rows.first?.state == .delivered, "audio failure never fails the JSON delivery")
    }

    @Test func staleAudioTempIsSweptByStaleTempHygiene() async throws {
        // M2: an orphaned `.tmp-audio-*` (crash between copy and rename) carries
        // the `.tmp-` prefix so LocalFolderTransport's 24h sweep reclaims it; a
        // fresh one stays. (The *.json cleanup glob never touches either.)
        let root = try g5TempFolder()
        let meetingID = ULID.generate()
        let dir = root.appendingPathComponent(meetingID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let staleAudioTemp = dir.appendingPathComponent(".tmp-audio-deadbeef-nonce-audio.m4a")
        try Data("orphan".utf8).write(to: staleAudioTemp)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-2 * 24 * 60 * 60)],
            ofItemAtPath: staleAudioTemp.path)
        let freshAudioTemp = dir.appendingPathComponent(".tmp-audio-fresh-nonce-audio_mic.m4a")
        try Data("recent".utf8).write(to: freshAudioTemp)

        let payload = Data("fresh".utf8)
        let hash = EvidencePayloadBuilder.sha256Hex(payload)
        _ = try await LocalFolderTransport(root: root).deliver(
            argv: LocalFolderCommand.argv(meetingID: meetingID, hash: hash, nonce: "n"),
            payload: payload, timeout: 0)
        #expect(!FileManager.default.fileExists(atPath: staleAudioTemp.path), "stale audio temp swept")
        #expect(FileManager.default.fileExists(atPath: freshAudioTemp.path), "fresh audio temp kept")
    }

    @Test func sshAudioWriteStreamsToRemoteTempThenRenames() async throws {
        // M2: a size MISMATCH forces a write; the write streams to a `.tmp-audio-*`
        // remote temp then `mv`s into place — a died stream never leaves a
        // truncated file at the visible name.
        let database = try makeDatabase()
        let item = try await seedDeliverable(database, title: "Remote temp")
        try writeAudio(database, item.meetingID, "audio.m4a", bytes: 320)
        try await SettingsStore(database: database)
            .set(HandoffDestination.Key.deliverAudio, to: true)
        let transport = MockTransport(script: [
            HandoffTransportOutcome(exitStatus: 0, stderrTail: "", timedOut: false),  // JSON
            HandoffTransportOutcome(
                exitStatus: 0, stderrTail: "", timedOut: false, stdout: Data("999\n".utf8)),  // wc -c mismatch
        ])
        let worker = makeWorker(database, transport: transport)
        await worker.kick()
        await worker.waitUntilSettled()

        let remoteDir = handoffValidExample.remoteRoot + "/" + item.meetingID
        let commands = transport.calls.compactMap { $0.argv.last }
        #expect(commands.contains {
            $0 == "mkdir -p '\(remoteDir)' && cat > '\(remoteDir)/.tmp-audio-audio.m4a' && "
                + "mv '\(remoteDir)/.tmp-audio-audio.m4a' '\(remoteDir)/audio.m4a'"
        })
        // M3: the bytes NEVER stream directly onto the visible final name — a
        // died stream/watchdog kill leaves only the `.tmp-audio-*` (swept later),
        // never a truncated `audio.m4a`.
        #expect(
            !commands.contains { $0.contains("cat > '\(remoteDir)/audio.m4a'") },
            "audio must stream to a temp, never the final name")
        // The 320 audio bytes stream on that write's stdin.
        let writeCall = transport.calls.first {
            ($0.argv.last?.contains("mv '\(remoteDir)/.tmp-audio-audio.m4a'")) == true
        }
        #expect(writeCall?.payload.count == 320)
        let rows = try await HandoffRepository(database: database).allItems()
        #expect(rows.first?.state == .delivered)
    }

    @Test func isSafeAudioNameGuardsInjection() {
        #expect(HandoffCommand.isSafeAudioName("audio.m4a"))
        #expect(HandoffCommand.isSafeAudioName("audio_mic.m4a"))
        #expect(HandoffCommand.isSafeAudioName("audio_2.m4a"))
        #expect(HandoffCommand.isSafeAudioName("audio_mic_2.m4a"))
        #expect(!HandoffCommand.isSafeAudioName("audio';rm -rf /.m4a"))
        #expect(!HandoffCommand.isSafeAudioName("evil.m4a"))
        #expect(!HandoffCommand.isSafeAudioName("audio.wav"))
    }
}

// MARK: - AC9: the docs-promise wording (kept in one commit with the behavior)

@Suite struct G5DocsPromiseTests {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // BlaiseCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // app
            .deletingLastPathComponent()  // repo root
    }

    private func read(_ rel: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(rel), encoding: .utf8)
    }

    /// Whitespace-collapsed (so a line-wrapped claim is still detected).
    private func flat(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    @Test func readmeAudioPromiseIsRewritten() throws {
        #expect(flat(try read("README.md")).contains(
            "no upload path for audio unless you explicitly enable audio delivery to a destination"))
    }

    @Test func handoffDocStatesAudioAndCleanupSemantics() throws {
        let doc = try read("docs/handoff.md")
        #expect(doc.contains("Include audio recordings"))
        #expect(doc.contains("Keep superseded payloads at the destination"))
        // The stale "older versions are not deleted" paragraph is superseded.
        #expect(!doc.contains("older versions are not deleted"))
    }

    /// H1: NO unqualified audio-privacy claim may survive anywhere in the docs —
    /// every "never leaves" must carry the audio-delivery caveat, and the exact
    /// pre-fix sentences must be gone. (The prior tests passed WITH the
    /// contradiction in place; these negative assertions are what close it.)
    @Test func noUnqualifiedAudioClaimSurvivesInDocs() throws {
        let readme = flat(try read("README.md"))
        let handoff = flat(try read("docs/handoff.md"))
        // The exact unqualified sentences the review flagged must be gone.
        #expect(!readme.contains("Your audio never leaves the machine"))
        #expect(!handoff.contains("audio never leaves your Mac; only the generated"))
        // Every remaining "never leaves" must be caveated within a short window.
        for (label, text) in [("README.md", readme), ("docs/handoff.md", handoff)] {
            var cursor = text.startIndex
            while let r = text.range(of: "never leaves", range: cursor ..< text.endIndex) {
                let window = text[r.upperBound...].prefix(90)
                #expect(
                    window.contains("unless you explicitly enable"),
                    "\(label): an uncaveated 'never leaves' audio claim survives")
                cursor = r.upperBound
            }
        }
    }
}
