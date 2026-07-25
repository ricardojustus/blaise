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
    removeSuperseded: Bool? = nil, deliverAudio: Bool? = nil
) async throws {
    let store = SettingsStore(database: database)
    let bookmark = try folder.bookmarkData(
        options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    try await store.set(HandoffDestination.Key.kind, to: HandoffDestination.Kind.localFolder)
    try await store.set(HandoffDestination.Key.localBookmark, to: bookmark.base64EncodedString())
    try await store.set(HandoffDestination.Key.localPath, to: folder.path)
    try await store.set(HandoffDestination.Key.localMarkdownSidecar, to: sidecar)
    if let removeSuperseded {
        try await store.set(HandoffDestination.Key.removeSupersededPayloads, to: removeSuperseded)
    }
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

/// A transport that runs a side effect INSIDE its first `deliver` — the seam for
/// "the user flips a Settings toggle while a slow transfer is in flight": the
/// worker is suspended at that await and the actor is reentrant there, so any
/// value it cached before the await is stale when the call returns. Recording
/// and outcomes are `inner`'s job: by default the sibling suites' `MockTransport`
/// (so `calls` reads through to it), or the real folder transport where the
/// local destination has to actually write.
private final class FlipDuringDeliveryTransport: HandoffTransporting, @unchecked Sendable {
    private let inner: any HandoffTransporting
    private let duringFirstCall: @Sendable () async -> Void
    private let lock = NSLock()
    private var fired = false

    init(
        inner: any HandoffTransporting = MockTransport(),
        duringFirstCall: @escaping @Sendable () async -> Void
    ) {
        self.inner = inner
        self.duringFirstCall = duringFirstCall
    }

    var calls: [MockTransport.Call] { (inner as? MockTransport)?.calls ?? [] }

    /// Latches the first call (lock work stays out of the async context).
    private func claimFirst() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let first = !fired
        fired = true
        return first
    }

    func deliver(argv: [String], payload: Data, timeout: TimeInterval) async throws
        -> HandoffTransportOutcome
    {
        if claimFirst() { await duringFirstCall() }
        return try await inner.deliver(argv: argv, payload: payload, timeout: timeout)
    }
}

/// Records queue-row states observed INSIDE the candidate-acquisition seam —
/// the hook is `@Sendable`, so the observation needs a Sendable box.
private actor StateProbe {
    private(set) var states: [String] = []
    func record(_ states: [String]) { self.states = states }
}

/// Inserts a raw `pending` queue row for `meetingID` — bypassing `enqueue` so
/// the row's `created_seq` and its `delivered_endpoint` can both be chosen.
private func insertPendingRow(
    _ database: BlaiseDatabase, meetingID: MeetingID, versionHash: String, createdSeq: Int64,
    deliveredEndpoint: String? = nil
) async throws {
    try await database.pool.write { db in
        try db.execute(
            sql: """
                INSERT INTO handoff_queue
                    (id, meeting_id, payload_path, version_hash, state, attempts,
                     created_at, created_seq, delivered_endpoint)
                VALUES (?, ?, ?, ?, 'pending', 0, ?, ?, ?)
                """,
            arguments: [
                ULID.generate(), meetingID, "never/written.json", versionHash, msDate(),
                createdSeq, deliveredEndpoint,
            ])
    }
}

/// The state of one queue row, by version hash (nil ⇒ no such row).
private func rowState(_ database: BlaiseDatabase, versionHash: String) async throws -> String? {
    try await database.pool.read { db in
        try String.fetchOne(
            db, sql: "SELECT state FROM handoff_queue WHERE version_hash = ?",
            arguments: [versionHash])
    }
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
        try await selectLocalDest(database, folder, sidecar: true, removeSuperseded: true)

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

    /// The DEFAULT with the key entirely ABSENT — the state every existing
    /// install upgrades into. This is the regression pin that matters most: the
    /// shipped behaviour must be "delivered evidence accumulates", so an upgrade
    /// never starts silently deleting files at someone's destination. Asserted
    /// from the absent key, never from an explicitly seeded value, because a
    /// seeded value tests the seed rather than the default.
    @Test func absentKeyPreservesBothPayloads() async throws {
        let database = try makeDatabase()
        let v1 = try await seedDeliverable(database, title: "Default history")
        let folder = try g5TempFolder()
        // `removeSuperseded` deliberately not passed — the key stays unset.
        try await selectLocalDest(database, folder, sidecar: false)

        let worker = makeWorker(database)
        await worker.start()
        await worker.waitUntilSettled()
        let v2 = try await enqueueSecondVersion(database, v1.meetingID)
        await worker.kick()
        await worker.waitUntilSettled()

        let destDir = folder.appendingPathComponent(v1.meetingID)
        #expect(
            jsonNames(destDir) == ["\(v1.versionHash).json", "\(v2.versionHash).json"].sorted(),
            "absent key ⇒ payloads accumulate; an upgrade must not delete delivered evidence")
    }

    @Test func defaultPreservesBothPayloads() async throws {
        let database = try makeDatabase()
        let v1 = try await seedDeliverable(database, title: "History")
        let folder = try g5TempFolder()
        try await selectLocalDest(database, folder, sidecar: false, removeSuperseded: false)

        let worker = makeWorker(database)
        await worker.start()
        await worker.waitUntilSettled()
        let v2 = try await enqueueSecondVersion(database, v1.meetingID)
        await worker.kick()
        await worker.waitUntilSettled()

        let destDir = folder.appendingPathComponent(v1.meetingID)
        #expect(jsonNames(destDir) == ["\(v1.versionHash).json", "\(v2.versionHash).json"].sorted())
    }

    @Test func sshCleanupNamesOnlyKnownSupersededHashes() async throws {
        let database = try makeDatabase()
        let v1 = try await seedDeliverable(database, title: "SSH cleanup")  // sidecar OFF
        try await SettingsStore(database: database)
            .set(HandoffDestination.Key.removeSupersededPayloads, to: true)  // cleanup ON
        let transport = MockTransport()
        let worker = makeWorker(database, transport: transport)
        await worker.kick()
        await worker.waitUntilSettled()
        // v1 is the meeting's ONLY known version ⇒ nothing to remove, no call.
        #expect(transport.calls.count == 1, "no known superseded version ⇒ no cleanup command")

        let v2 = try await enqueueSecondVersion(database, v1.meetingID)
        await worker.kick()
        await worker.waitUntilSettled()

        // v2's JSON (1) then the cleanup (2), naming v1's file EXACTLY — never a
        // `*.json` glob, so a non-payload file, a foreign 64-hex name Blaise
        // never wrote, or a directory in that dir is not a deletion candidate.
        #expect(transport.calls.count == 3)
        let remoteDir = handoffValidExample.remoteRoot + "/" + v1.meetingID
        #expect(transport.calls[2].argv == HandoffCommand.cleanupArgv(
            user: handoffValidExample.user, host: handoffValidExample.hosts[0],
            identityFile: handoffValidExample.identityFile,
            remoteDir: remoteDir, hashes: [v1.versionHash]))
        let expectedCommand: String =
            "cd '\(remoteDir)' 2>/dev/null || exit 0; "
            + "for f in '\(v1.versionHash).json'; do [ -f \"$f\" ] || continue; "
            + "A=$(/usr/bin/shasum -a 256 \"$f\" | cut -d' ' -f1); "
            + "if [ \"$A\" = \"${f%.json}\" ]; then echo \"removed $f\"; rm -f -- \"$f\"; "
            + "else echo \"skipped $f\"; fi; done"
        #expect(transport.calls[2].argv.last == expectedCommand)
        let command = try #require(transport.calls[2].argv.last)
        #expect(!command.contains("*.json"), "no glob: only Blaise's own records authorize a delete")
        #expect(!command.contains(v2.versionHash), "the just-delivered payload is never named")
        // G5 v1.7 (R4-F2), the remote half of verify-before-delete: the
        // file's own bytes must hash to its own name — the same
        // `shasum -a 256` the DELIVERY command already trusts — and the `rm`
        // sits INSIDE that branch. A named-but-foreign remote file is echoed
        // `skipped`, never removed.
        let matchBranch = try #require(command.range(of: "if [ \"$A\" = \"${f%.json}\" ]"))
        let removal = try #require(command.range(of: "rm -f -- "))
        #expect(command.contains("A=$(/usr/bin/shasum -a 256 \"$f\" | cut -d' ' -f1)"))
        #expect(
            removal.lowerBound > matchBranch.lowerBound,
            "the delete is inside the hash-match branch, never before it")
    }

    /// C-1: a destination dir holding a non-payload JSON, a DIRECTORY named
    /// `*.json`, and a valid-looking 64-hex payload Blaise never wrote loses NONE
    /// of them — only the meeting's own older version goes. The pre-fix wildcard
    /// sweep removed all four.
    @Test func localCleanupRemovesOnlyThisMeetingsKnownSupersededPayloads() async throws {
        let database = try makeDatabase()
        let v1 = try await seedDeliverable(database, title: "Surgical")
        let folder = try g5TempFolder()
        try await selectLocalDest(database, folder, sidecar: false, removeSuperseded: true)

        let worker = makeWorker(database)
        await worker.start()
        await worker.waitUntilSettled()
        let destDir = folder.appendingPathComponent(v1.meetingID)

        // Foreign inhabitants of the meeting dir, all of them NOT Blaise's records.
        let foreignHash = String(repeating: "ab", count: 32)  // valid 64-hex, never enqueued
        try Data("{}".utf8).write(to: destDir.appendingPathComponent("metadata.json"))
        try Data("{}".utf8).write(to: destDir.appendingPathComponent("\(foreignHash).json"))
        try FileManager.default.createDirectory(
            at: destDir.appendingPathComponent("archive.json", isDirectory: true),
            withIntermediateDirectories: true)
        try Data("kept".utf8).write(
            to: destDir.appendingPathComponent("archive.json").appendingPathComponent("old.json"))

        let v2 = try await enqueueSecondVersion(database, v1.meetingID)
        await worker.kick()
        await worker.waitUntilSettled()

        #expect(
            jsonNames(destDir) == [
                "\(foreignHash).json", "archive.json", "metadata.json", "\(v2.versionHash).json",
            ].sorted(),
            "only THIS meeting's known superseded payload is removed")
        #expect(!FileManager.default.fileExists(
            atPath: destDir.appendingPathComponent("\(v1.versionHash).json").path))
        // The directory survived WITH its contents (removeItem would recurse).
        #expect(FileManager.default.fileExists(
            atPath: destDir.appendingPathComponent("archive.json")
                .appendingPathComponent("old.json").path))
    }

    /// C-2: the toggle flipped OFF DURING a slow delivery wins — the destructive
    /// authorization is re-read after the transport await, never cached across it.
    @Test func localCleanupSkippedWhenToggleFlipsOffDuringDelivery() async throws {
        let database = try makeDatabase()
        let v1 = try await seedDeliverable(database, title: "Flip local")
        let folder = try g5TempFolder()
        try await selectLocalDest(database, folder, sidecar: false, removeSuperseded: true)

        let first = makeWorker(database)
        await first.start()
        await first.waitUntilSettled()
        let destDir = folder.appendingPathComponent(v1.meetingID)
        #expect(jsonNames(destDir) == ["\(v1.versionHash).json"])

        let v2 = try await enqueueSecondVersion(database, v1.meetingID)
        // The user turns removal OFF while v2's bytes are still being written.
        let store = SettingsStore(database: database)
        let worker = HandoffWorker(
            database: database,
            prober: MockProber(),
            localTransportFactory: { root in
                FlipDuringDeliveryTransport(inner: LocalFolderTransport(root: root)) {
                    try? await store.set(HandoffDestination.Key.removeSupersededPayloads, to: false)
                }
            },
            nonce: { testNonce })
        await worker.kick()
        await worker.waitUntilSettled()

        #expect(
            jsonNames(destDir) == ["\(v1.versionHash).json", "\(v2.versionHash).json"].sorted(),
            "OFF during the transfer ⇒ the sweep that was authorized before it must not run")
    }

    @Test func sshCleanupSkippedWhenToggleFlipsOffDuringDelivery() async throws {
        let database = try makeDatabase()
        let v1 = try await seedDeliverable(database, title: "Flip ssh")
        try await SettingsStore(database: database)
            .set(HandoffDestination.Key.removeSupersededPayloads, to: true)
        let first = makeWorker(database)
        await first.kick()
        await first.waitUntilSettled()

        _ = try await enqueueSecondVersion(database, v1.meetingID)
        let store = SettingsStore(database: database)
        let transport = FlipDuringDeliveryTransport {
            try? await store.set(HandoffDestination.Key.removeSupersededPayloads, to: false)
        }
        let worker = HandoffWorker(
            database: database, transport: transport, prober: MockProber(), nonce: { testNonce })
        await worker.kick()
        await worker.waitUntilSettled()

        #expect(
            transport.calls.count == 1,
            "OFF during the transfer ⇒ the JSON is delivered and NO cleanup command is sent")
    }

    /// R2-C1 (Critical), the attack trace verbatim, LOCAL transport: v1 is
    /// delivered to folder A; the user switches the destination to folder B; B
    /// already holds a same-named `<v1hash>.json` written by somebody else; v2
    /// is delivered to B. Queue membership says "Blaise knows this hash" — and
    /// it is a lie about THIS destination. Only delivery provenance keyed to the
    /// currently active destination may authorize a delete.
    @Test func localDestinationSwitchNeverDeletesAForeignSameHashPayload() async throws {
        let database = try makeDatabase()
        let v1 = try await seedDeliverable(database, title: "Switch local")
        let folderA = try g5TempFolder()
        try await selectLocalDest(database, folderA, sidecar: false, removeSuperseded: true)

        let first = makeWorker(database)
        await first.start()
        await first.waitUntilSettled()
        #expect(jsonNames(folderA.appendingPathComponent(v1.meetingID))
            == ["\(v1.versionHash).json"], "v1 landed at destination A")

        // The user switches destinations. B is a DIFFERENT store that happens to
        // hold a file with v1's name — another producer's, not Blaise's.
        let folderB = try g5TempFolder()
        try await selectLocalDest(database, folderB, sidecar: false, removeSuperseded: true)
        let destB = folderB.appendingPathComponent(v1.meetingID, isDirectory: true)
        try FileManager.default.createDirectory(at: destB, withIntermediateDirectories: true)
        let foreign = Data("not Blaise's payload".utf8)
        try foreign.write(to: destB.appendingPathComponent("\(v1.versionHash).json"))

        let v2 = try await enqueueSecondVersion(database, v1.meetingID)
        let worker = makeWorker(database)
        await worker.kick()
        await worker.waitUntilSettled()

        #expect(
            jsonNames(destB) == ["\(v1.versionHash).json", "\(v2.versionHash).json"].sorted(),
            "a version delivered to the PREVIOUS destination is no authority to delete here")
        #expect(
            try Data(contentsOf: destB.appendingPathComponent("\(v1.versionHash).json")) == foreign,
            "the foreign file is untouched, byte for byte")
        // A's copy is equally untouched — cleanup only ever visits the active one.
        #expect(FileManager.default.fileExists(
            atPath: folderA.appendingPathComponent(v1.meetingID)
                .appendingPathComponent("\(v1.versionHash).json").path))
    }

    /// The SSH half of the same trace: the remote root moves (a destination
    /// switch on the same machine), so v1's delivery proves nothing about the
    /// new root and the cleanup command must not be sent at all.
    @Test func sshDestinationSwitchSendsNoCleanupForTheOldRootsVersions() async throws {
        let database = try makeDatabase()
        let v1 = try await seedDeliverable(database, title: "Switch ssh")
        try await SettingsStore(database: database)
            .set(HandoffDestination.Key.removeSupersededPayloads, to: true)
        let first = makeWorker(database)
        await first.kick()
        await first.waitUntilSettled()

        // Switch the destination: same host list and user, a NEW remote root.
        let moved = HandoffSettings(
            user: handoffValidExample.user, identityFile: handoffValidExample.identityFile,
            hosts: handoffValidExample.hosts, remoteRoot: "/srv/blaise/evidence-inbox/moved")
        try await seedHandoffConfig(database, moved)
        // seedHandoffConfig re-seeds the destination-independent toggles to
        // their no-extra-call state; the cleanup opt-in has to go back ON, or
        // this test would pass for the wrong reason.
        try await SettingsStore(database: database)
            .set(HandoffDestination.Key.removeSupersededPayloads, to: true)

        _ = try await enqueueSecondVersion(database, v1.meetingID)
        let transport = MockTransport()
        let worker = makeWorker(database, transport: transport)
        await worker.kick()
        await worker.waitUntilSettled()

        #expect(
            transport.calls.count == 1,
            "v1 was delivered to the OLD root: no candidate here, so no remote rm command")
    }

    /// Same-path replacement: deliver to a folder/volume at `<path>`, lose it,
    /// put a DIFFERENT store at the same `<path>`, and re-pick it in Settings.
    /// Every visible part of the configuration is identical, so the identity
    /// matches and v1's delivered row IS a candidate here. The BYTES are what
    /// saves the same-named file: it is somebody else's, it does not hash to
    /// the name it wears, and it survives untouched.
    @MainActor @Test func localSamePathReplacementNeverDeletesTheNewResourcesFile() async throws {
        let database = try makeDatabase()
        let v1 = try await seedDeliverable(database, title: "Replaced at the same path")
        let parent = try g5TempFolder()
        let path = parent.appendingPathComponent("Evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try await selectLocalDest(database, path, sidecar: false, removeSuperseded: true)

        let first = makeWorker(database)
        await first.start()
        await first.waitUntilSettled()
        #expect(jsonNames(path.appendingPathComponent(v1.meetingID))
            == ["\(v1.versionHash).json"], "v1 landed at the original store")

        // The store at `<path>` is replaced, and the user re-picks the folder
        // they have always had — through the real Settings path.
        let store = SettingsStore(database: database)
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let model = HandoffSettingsModel(settings: store, kicker: NoopHandoffKicker())
        await model.load()
        #expect(await model.chooseLocalFolder(path))

        // A file with v1's name at the new store: another producer's, not ours.
        let dest = path.appendingPathComponent(v1.meetingID, isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let foreign = Data("not Blaise's payload".utf8)
        try foreign.write(to: dest.appendingPathComponent("\(v1.versionHash).json"))

        let v2 = try await enqueueSecondVersion(database, v1.meetingID)
        let worker = makeWorker(database)
        await worker.kick()
        await worker.waitUntilSettled()

        #expect(
            jsonNames(dest) == ["\(v1.versionHash).json", "\(v2.versionHash).json"].sorted(),
            "the name was authorized, the bytes were not")
        #expect(
            try Data(contentsOf: dest.appendingPathComponent("\(v1.versionHash).json")) == foreign,
            "the foreign file is untouched, byte for byte")
    }

    // MARK: - G5 v1.7 (R4-F2): verify before delete

    /// R4-F2 (Critical), Codex's trace at the seam that times it: the local
    /// cleanup dereferences the destination PATHNAME long after the resource
    /// identity was sampled, so a store swapped in at that pathname during the
    /// drain is the one that receives the delete. The identity metadata cannot
    /// see it. The BYTES can: a foreign file does not hash to the name it
    /// wears, so it survives — and the drain's own delivery is untouched at the
    /// store it actually went to.
    @Test func localCleanupNeverDeletesAForeignFileAtAResourceSwappedMidDrain() async throws {
        let database = try makeDatabase()
        let v1 = try await seedDeliverable(database, title: "Swapped mid-drain")
        let parent = try g5TempFolder()
        let path = parent.appendingPathComponent("Evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try await selectLocalDest(database, path, sidecar: false, removeSuperseded: true)

        let first = makeWorker(database)
        await first.start()
        await first.waitUntilSettled()
        #expect(jsonNames(path.appendingPathComponent(v1.meetingID))
            == ["\(v1.versionHash).json"], "v1 landed at the store that was here")

        _ = try await enqueueSecondVersion(database, v1.meetingID)
        let movedAside = parent.appendingPathComponent("Evidence-old", isDirectory: true)
        let foreign = Data("another store's file, wearing the same name".utf8)
        let worker = HandoffWorker(
            database: database, prober: MockProber(), nonce: { testNonce },
            duringCandidateAcquisition: {
                // The sampled resource moves; a DIFFERENT store takes the
                // pathname, holding a file with v1's name that it wrote itself.
                try? FileManager.default.moveItem(at: path, to: movedAside)
                let dir = path.appendingPathComponent(v1.meetingID, isDirectory: true)
                try? FileManager.default.createDirectory(
                    at: dir, withIntermediateDirectories: true)
                try? foreign.write(to: dir.appendingPathComponent("\(v1.versionHash).json"))
            })
        await worker.kick()
        await worker.waitUntilSettled()

        let replacement = path.appendingPathComponent(v1.meetingID)
        #expect(
            jsonNames(replacement) == ["\(v1.versionHash).json"],
            "the replacement store keeps its file: the name was authorized, the bytes were not")
        #expect(
            try Data(contentsOf: replacement.appendingPathComponent("\(v1.versionHash).json"))
                == foreign,
            "untouched, byte for byte")
    }

    /// The other half of the same rule, asserted explicitly so the pair
    /// discriminates a CONTENT check from a blanket "never delete after a
    /// swap": the file planted at the swapped-in store is BYTE-IDENTICAL to the
    /// payload Blaise delivered, so it hashes to its own name and may go —
    /// removing it destroys nothing unique, which is exactly why
    /// verify-before-delete is safe rather than merely conservative.
    @Test func localCleanupStillRemovesAByteIdenticalPayloadAtASwappedResource() async throws {
        let database = try makeDatabase()
        let v1 = try await seedDeliverable(database, title: "Identical mid-drain")
        let parent = try g5TempFolder()
        let path = parent.appendingPathComponent("Evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try await selectLocalDest(database, path, sidecar: false, removeSuperseded: true)

        let first = makeWorker(database)
        await first.start()
        await first.waitUntilSettled()
        let deliveredBytes = try Data(
            contentsOf: path.appendingPathComponent(v1.meetingID)
                .appendingPathComponent("\(v1.versionHash).json"))
        #expect(
            EvidencePayloadBuilder.sha256Hex(deliveredBytes) == v1.versionHash,
            "the delivered payload hashes to its own name — the store is content-addressed")

        _ = try await enqueueSecondVersion(database, v1.meetingID)
        let movedAside = parent.appendingPathComponent("Evidence-old", isDirectory: true)
        let worker = HandoffWorker(
            database: database, prober: MockProber(), nonce: { testNonce },
            duringCandidateAcquisition: {
                try? FileManager.default.moveItem(at: path, to: movedAside)
                let dir = path.appendingPathComponent(v1.meetingID, isDirectory: true)
                try? FileManager.default.createDirectory(
                    at: dir, withIntermediateDirectories: true)
                try? deliveredBytes.write(to: dir.appendingPathComponent("\(v1.versionHash).json"))
            })
        await worker.kick()
        await worker.waitUntilSettled()

        #expect(
            jsonNames(path.appendingPathComponent(v1.meetingID)) == [],
            "identical bytes ARE the payload the records authorize: removable")
    }

    /// The other half of R2-C1: a version that only ever sat in the queue
    /// (pending / failed / damaged — never delivered anywhere) is not authority
    /// either. The pre-fix `any state` query made it one.
    @Test func aNeverDeliveredHashIsNeverADeletionCandidate() async throws {
        let database = try makeDatabase()
        let v1 = try await seedDeliverable(database, title: "Pending only")
        let folder = try g5TempFolder()
        try await selectLocalDest(database, folder, sidecar: false, removeSuperseded: true)

        // A queue row Blaise enqueued and NEVER delivered, and a same-named file
        // at the destination that is therefore somebody else's.
        let pendingHash = String(repeating: "cd", count: 32)
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO handoff_queue
                        (id, meeting_id, payload_path, version_hash, state, attempts,
                         created_at, created_seq)
                    VALUES (?, ?, ?, ?, 'pending', 0, ?, ?)
                    """,
                arguments: [
                    ULID.generate(), v1.meetingID, "never/written.json", pendingHash, msDate(),
                    v1.createdSeq + 1000,
                ])
        }
        let worker = makeWorker(database)
        await worker.start()
        await worker.waitUntilSettled()
        let destDir = folder.appendingPathComponent(v1.meetingID)
        try Data("someone else's".utf8)
            .write(to: destDir.appendingPathComponent("\(pendingHash).json"))

        let v2 = try await enqueueSecondVersion(database, v1.meetingID)
        await worker.kick()
        await worker.waitUntilSettled()

        #expect(
            jsonNames(destDir) == ["\(pendingHash).json", "\(v2.versionHash).json"].sorted(),
            "enqueued ≠ delivered: an undelivered version authorizes nothing")
    }

    /// The literal pending-row case (round-3 R2-F1 test-discrimination note):
    /// a row that is STILL `pending` at the moment the cleanup acquires its
    /// candidate set — not one the worker already quarantined — authorizes
    /// nothing. Two pending rows are planted, both with a `created_seq` ABOVE
    /// v2's so the D12 supersession sweep leaves them alone, and the hook
    /// inside the acquisition seam records that both were `pending` right
    /// there:
    ///
    /// - the ordinary shape: `pending`, provenance NULL (never delivered);
    /// - a `pending` row carrying THIS destination's identity — the shape that
    ///   makes `state = 'delivered'` the ONLY filter standing between it and
    ///   the candidate set (a NULL provenance is already excluded by the
    ///   endpoint match, so it cannot show what the state filter is worth).
    ///
    /// Both hashes name a file at the destination. Both files survive.
    @Test func aRowStillPendingDuringCandidateAcquisitionIsNeverADeletionCandidate() async throws {
        let database = try makeDatabase()
        let v1 = try await seedDeliverable(database, title: "Ainda na fila")
        let folder = try g5TempFolder()
        try await selectLocalDest(database, folder, sidecar: false, removeSuperseded: true)

        let first = makeWorker(database)
        await first.start()
        await first.waitUntilSettled()
        let destDir = folder.appendingPathComponent(v1.meetingID)
        #expect(jsonNames(destDir) == ["\(v1.versionHash).json"])

        // The identity v1's delivery stamped — the same one v2's drain presents.
        let delivered = try await HandoffRepository(database: database).allItems()
        let activeIdentity = try #require(delivered.first { $0.id == v1.id }?.deliveredEndpoint)

        // Same-named files at the destination: neither hash was ever delivered,
        // so each belongs to somebody else.
        let plainPendingHash = String(repeating: "ef", count: 32)
        let stampedPendingHash = String(repeating: "9a", count: 32)
        let foreign = Data("not Blaise's payload".utf8)
        try foreign.write(to: destDir.appendingPathComponent("\(plainPendingHash).json"))
        try foreign.write(to: destDir.appendingPathComponent("\(stampedPendingHash).json"))

        let v2 = try await enqueueSecondVersion(database, v1.meetingID)
        try await insertPendingRow(
            database, meetingID: v1.meetingID, versionHash: plainPendingHash,
            createdSeq: v2.createdSeq + 1000)
        try await insertPendingRow(
            database, meetingID: v1.meetingID, versionHash: stampedPendingHash,
            createdSeq: v2.createdSeq + 2000, deliveredEndpoint: activeIdentity)

        let probe = StateProbe()
        let worker = HandoffWorker(
            database: database, prober: MockProber(), nonce: { testNonce },
            duringCandidateAcquisition: {
                let plain = try? await rowState(database, versionHash: plainPendingHash)
                let stamped = try? await rowState(database, versionHash: stampedPendingHash)
                await probe.record([plain, stamped].compactMap { $0 })
            })
        await worker.kick()
        await worker.waitUntilSettled()

        #expect(
            await probe.states == ["pending", "pending"],
            "both rows were still pending WHEN the candidate set was acquired")
        #expect(
            jsonNames(destDir) == [
                "\(plainPendingHash).json", "\(stampedPendingHash).json", "\(v2.versionHash).json",
            ].sorted(),
            "a merely pending row, even one carrying this destination's identity, proves nothing was written here")
        #expect(
            try Data(contentsOf: destDir.appendingPathComponent("\(plainPendingHash).json"))
                == foreign)
        #expect(
            try Data(contentsOf: destDir.appendingPathComponent("\(stampedPendingHash).json"))
                == foreign)
    }

    /// The literal pre-provenance upgrade case (round-3 R2-F1
    /// test-discrimination note): v19 adds `delivered_endpoint` nullable, so
    /// every row a pre-v19 binary delivered upgrades into `delivered` with NULL
    /// provenance. NULL says "delivered — destination unknown", which is no
    /// proof this destination holds Blaise's file, so its payload stays.
    @Test func aDeliveredRowWithNullProvenanceIsNeverADeletionCandidate() async throws {
        let database = try makeDatabase()
        let v1 = try await seedDeliverable(database, title: "Entrega sem proveniência")
        let folder = try g5TempFolder()
        try await selectLocalDest(database, folder, sidecar: false, removeSuperseded: true)

        let first = makeWorker(database)
        await first.start()
        await first.waitUntilSettled()
        let destDir = folder.appendingPathComponent(v1.meetingID)
        #expect(jsonNames(destDir) == ["\(v1.versionHash).json"])
        let deliveredBytes = try Data(
            contentsOf: destDir.appendingPathComponent("\(v1.versionHash).json"))

        // Rewrite v1's row into the post-upgrade shape: delivered, provenance
        // unknown. (The row is otherwise untouched — same hash, same state.)
        try await database.pool.write { db in
            try db.execute(
                sql: "UPDATE handoff_queue SET delivered_endpoint = NULL WHERE id = ?",
                arguments: [v1.id])
        }
        #expect(try await rowState(database, versionHash: v1.versionHash) == "delivered")
        let upgraded = try await HandoffRepository(database: database).allItems()
        #expect(upgraded.first { $0.id == v1.id }?.deliveredEndpoint == nil)

        let v2 = try await enqueueSecondVersion(database, v1.meetingID)
        let worker = makeWorker(database)
        await worker.kick()
        await worker.waitUntilSettled()

        #expect(
            jsonNames(destDir) == ["\(v1.versionHash).json", "\(v2.versionHash).json"].sorted(),
            "NULL provenance names no destination: it authorizes no deletion at this one")
        #expect(
            try Data(contentsOf: destDir.appendingPathComponent("\(v1.versionHash).json"))
                == deliveredBytes,
            "the pre-provenance payload is untouched, byte for byte")
    }

    /// R2-C2 (Critical): the destructive toggle must be re-read AFTER the
    /// deletion-candidate set is acquired — that acquisition is itself an await,
    /// and the actor is reentrant there. Flipping OFF inside that window must
    /// win. (With the pre-fix order — re-read, THEN acquire — this flip lands
    /// after the authorization was captured and both payloads would go.)
    @Test func cleanupSkippedWhenToggleFlipsOffDuringCandidateAcquisition() async throws {
        let database = try makeDatabase()
        let v1 = try await seedDeliverable(database, title: "Flip mid-candidates")
        let folder = try g5TempFolder()
        try await selectLocalDest(database, folder, sidecar: false, removeSuperseded: true)

        let first = makeWorker(database)
        await first.start()
        await first.waitUntilSettled()
        let destDir = folder.appendingPathComponent(v1.meetingID)
        #expect(jsonNames(destDir) == ["\(v1.versionHash).json"])

        let v2 = try await enqueueSecondVersion(database, v1.meetingID)
        let store = SettingsStore(database: database)
        let worker = HandoffWorker(
            database: database, prober: MockProber(), nonce: { testNonce },
            duringCandidateAcquisition: {
                try? await store.set(HandoffDestination.Key.removeSupersededPayloads, to: false)
            })
        await worker.kick()
        await worker.waitUntilSettled()

        #expect(
            jsonNames(destDir) == ["\(v1.versionHash).json", "\(v2.versionHash).json"].sorted(),
            "OFF during candidate acquisition ⇒ the sweep must not run")
    }

    @Test func sshDefaultSkipsCleanupCall() async throws {
        let database = try makeDatabase()
        _ = try await seedDeliverable(database, title: "Keep")
        try await SettingsStore(database: database)
            .set(HandoffDestination.Key.removeSupersededPayloads, to: false)
        let transport = MockTransport()
        let worker = makeWorker(database, transport: transport)
        await worker.kick()
        await worker.waitUntilSettled()
        #expect(transport.calls.count == 1, "removal OFF (the default) ⇒ no cleanup call")
    }

    @Test func sshCleanupFailureDoesNotFailDelivery() async throws {
        let database = try makeDatabase()
        let v1 = try await seedDeliverable(database, title: "Isolated cleanup")
        try await SettingsStore(database: database)
            .set(HandoffDestination.Key.removeSupersededPayloads, to: true)  // cleanup ON
        // v1's JSON succeeds (no superseded version yet ⇒ no cleanup call), then
        // v2's JSON succeeds and ITS cleanup call fails non-zero — isolated.
        let transport = MockTransport(script: [
            HandoffTransportOutcome(exitStatus: 0, stderrTail: "", timedOut: false),
            HandoffTransportOutcome(exitStatus: 0, stderrTail: "", timedOut: false),
            HandoffTransportOutcome(exitStatus: 255, stderrTail: "cleanup boom", timedOut: false),
        ])
        let worker = makeWorker(database, transport: transport)
        await worker.kick()
        await worker.waitUntilSettled()
        let v2 = try await enqueueSecondVersion(database, v1.meetingID)
        await worker.kick()
        await worker.waitUntilSettled()

        #expect(transport.calls.count == 3, "the failing call WAS the cleanup")
        let rows = try await HandoffRepository(database: database).allItems()
        #expect(rows.last?.id == v2.id)
        #expect(rows.last?.state == .delivered, "cleanup failure never un-delivers the JSON")
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
        // The promotion is gated on the RECEIVED byte count matching the local
        // one, so a died stream whose `cat` still exits 0 cannot install a
        // truncated file at the visible name.
        #expect(commands.contains {
            $0 == "mkdir -p '\(remoteDir)' && cat > '\(remoteDir)/.tmp-audio-audio.m4a' && "
                + "[ $(wc -c < '\(remoteDir)/.tmp-audio-audio.m4a') -eq 320 ] && "
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
        // Whitespace-collapsed: these phrases are prose and wrap across lines,
        // so a raw `contains` would assert the line-breaking rather than the
        // claim.
        let doc = flat(try read("docs/handoff.md"))
        #expect(doc.contains("Include audio recordings"))
        #expect(doc.contains("Remove superseded payloads at the destination"))
        // The immutable-history guarantee STANDS as the default. An earlier
        // draft made removal the default and asserted this sentence had to be
        // GONE; the operator reversed that (24/07/2026), so the doc must state
        // the guarantee AND present removal as the opt-in. Asserting both
        // directions is the point — the doc has to be unambiguous about which
        // behaviour you get by doing nothing.
        #expect(doc.contains("older versions are not deleted"))
        #expect(doc.contains("Removing superseded payloads (opt-in, off by default)"))
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
