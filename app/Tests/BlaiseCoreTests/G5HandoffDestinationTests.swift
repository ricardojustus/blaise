import CryptoKit
import Foundation
import Testing
@testable import BlaiseCore

// G5 — generalized handoff destinations: LocalFolderTransport (verify-before-
// rename), markdown sidecar, D21 warning over folder errors, settings
// round-trip + migration, and byte-identical payloads across destinations.
//
// Shares `seedDeliverable`, `makeWorker`, `MockTransport` with
// HandoffWorkerTests (same target). The local-folder kill class (AC2) is the
// shell harness scripts/g5_local_kill.sh (the C8 kill-test shape).

private func tempFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("g5-dest-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func jsonCount(_ dir: URL) -> Int {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        .filter { $0.hasSuffix(".json") }.count
}

private func tmpCount(_ dir: URL) -> Int {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        .filter { $0.hasPrefix(".tmp-") }.count
}

/// Switches the active destination of a DB to a local folder via a real
/// security-scoped bookmark (resolved exactly as in production).
private func selectLocalFolder(_ database: BlaiseDatabase, _ folder: URL, sidecar: Bool = true) async throws {
    let store = SettingsStore(database: database)
    let bookmark = try folder.bookmarkData(
        options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    try await store.set(HandoffDestination.Key.kind, to: HandoffDestination.Kind.localFolder)
    try await store.set(HandoffDestination.Key.localBookmark, to: bookmark.base64EncodedString())
    try await store.set(HandoffDestination.Key.localPath, to: folder.path)
    try await store.set(HandoffDestination.Key.localMarkdownSidecar, to: sidecar)
}

// MARK: - AC1: LocalFolderTransport unit tests

@Suite struct LocalFolderTransportTests {
    /// verify-before-rename: a clean delivery produces a content-addressed
    /// JSON whose name equals its sha256, and leaves no `.tmp-*`.
    @Test func verifyBeforeRenameProducesContentAddressedFile() async throws {
        let root = try tempFolder()
        let meetingID = ULID.generate()
        let payload = Data("hello world payload".utf8)
        let hash = EvidencePayloadBuilder.sha256Hex(payload)
        let transport = LocalFolderTransport(root: root)
        let outcome = try await transport.deliver(
            argv: LocalFolderCommand.argv(meetingID: meetingID, hash: hash, nonce: "abcd"),
            payload: payload, timeout: 0)
        #expect(outcome.exitStatus == 0)
        let dir = root.appendingPathComponent(meetingID)
        #expect(jsonCount(dir) == 1)
        #expect(tmpCount(dir) == 0)
        let written = try Data(contentsOf: dir.appendingPathComponent("\(hash).json"))
        #expect(written == payload)
        #expect(EvidencePayloadBuilder.sha256Hex(written) == hash)
    }

    /// Corrupt-on-write injected via the read-back seam → exit 65 (transfer
    /// corruption, retriable), NO visible file, temp cleaned.
    @Test func corruptOnWriteLeavesNoVisibleFile() async throws {
        let root = try tempFolder()
        let meetingID = ULID.generate()
        let payload = Data("good bytes".utf8)
        let hash = EvidencePayloadBuilder.sha256Hex(payload)
        // The read-back source returns DIFFERENT bytes than were written —
        // modeling a write that did not land byte-identically.
        let transport = LocalFolderTransport(root: root, readBackHook: { _ in Data("tampered".utf8) })
        let outcome = try await transport.deliver(
            argv: LocalFolderCommand.argv(meetingID: meetingID, hash: hash, nonce: "ab"),
            payload: payload, timeout: 0)
        #expect(outcome.exitStatus == 65)
        #expect(outcome.failureClass == .transferTransient)
        let dir = root.appendingPathComponent(meetingID)
        #expect(jsonCount(dir) == 0)
        #expect(tmpCount(dir) == 0)  // temp self-removed on mismatch
    }

    /// M-1: the rename into visibility is ATOMIC — an already-visible
    /// `<hash>.json` is never momentarily absent, and a FAILED rename leaves the
    /// existing file intact. This FAILS under the old remove-then-move shape:
    /// `removeItem(final)` would succeed and the failing `moveItem` would then
    /// leave NO visible JSON (the ENOENT window the auditor flagged, made
    /// deterministic by deleting the temp source just before the rename).
    @Test func atomicReplaceNeverLeavesTheVisibleFileAbsent() async throws {
        let root = try tempFolder()
        let meetingID = ULID.generate()
        let payload = Data("the immutable payload".utf8)
        let hash = EvidencePayloadBuilder.sha256Hex(payload)
        let dir = root.appendingPathComponent(meetingID)

        // First delivery: a visible <hash>.json exists.
        _ = try await LocalFolderTransport(root: root).deliver(
            argv: LocalFolderCommand.argv(meetingID: meetingID, hash: hash, nonce: "n1"),
            payload: payload, timeout: 0)
        #expect(jsonCount(dir) == 1)

        // Redeliver, but delete the temp on disk just before the rename (after
        // the verify passed) — the rename's SOURCE is now gone, so the rename
        // FAILS. Under an atomic rename the existing <hash>.json is untouched.
        // Under remove-then-move, removeItem(final) already deleted the visible
        // file and the failed move leaves NONE — so this pin FAILS there.
        let transport = LocalFolderTransport(
            root: root, beforeRenameHook: { temp in try? FileManager.default.removeItem(at: temp) })
        let outcome = try await transport.deliver(
            argv: LocalFolderCommand.argv(meetingID: meetingID, hash: hash, nonce: "n2"),
            payload: payload, timeout: 0)
        #expect(outcome.exitStatus != 0)  // rename failed
        // The already-visible file SURVIVES — never momentarily or permanently absent.
        #expect(jsonCount(dir) == 1)
        let still = try Data(contentsOf: dir.appendingPathComponent("\(hash).json"))
        #expect(still == payload)
    }

    /// M-4 mutant check: the verify re-OPENS the temp FROM DISK. Corrupting the
    /// temp on disk AFTER the write (the `afterWriteHook`) but with the honest
    /// disk read-back must yield exit 65 and NO visible file. A mutant that
    /// verified the in-memory `payload` instead would miss the on-disk
    /// corruption and produce a visible JSON — so this test fails under that
    /// neutering, pinning the disk source the auditor proved was unpinned.
    @Test func verifyReReadsFromDiskNotInMemory() async throws {
        let root = try tempFolder()
        let meetingID = ULID.generate()
        let payload = Data("bytes that DID write correctly".utf8)
        let hash = EvidencePayloadBuilder.sha256Hex(payload)
        // Corrupt the temp ON DISK after write; the in-memory payload is fine.
        let transport = LocalFolderTransport(
            root: root,
            afterWriteHook: { temp in
                try? Data("CORRUPTED ON DISK".utf8).write(to: temp, options: .atomic)
            })
        let outcome = try await transport.deliver(
            argv: LocalFolderCommand.argv(meetingID: meetingID, hash: hash, nonce: "n"),
            payload: payload, timeout: 0)
        #expect(outcome.exitStatus == 65)  // disk read-back caught the corruption
        let dir = root.appendingPathComponent(meetingID)
        #expect(jsonCount(dir) == 0)  // never made visible
        #expect(tmpCount(dir) == 0)  // temp cleaned
    }

    /// Idempotent re-delivery: the same bytes re-delivered overwrite the
    /// identical file — exactly one JSON, identical content.
    @Test func idempotentRedeliveryRewritesIdenticalBytes() async throws {
        let root = try tempFolder()
        let meetingID = ULID.generate()
        let payload = Data("idempotent".utf8)
        let hash = EvidencePayloadBuilder.sha256Hex(payload)
        let transport = LocalFolderTransport(root: root)
        for nonce in ["n1", "n2"] {
            let outcome = try await transport.deliver(
                argv: LocalFolderCommand.argv(meetingID: meetingID, hash: hash, nonce: nonce),
                payload: payload, timeout: 0)
            #expect(outcome.exitStatus == 0)
        }
        let dir = root.appendingPathComponent(meetingID)
        #expect(jsonCount(dir) == 1)
        #expect(tmpCount(dir) == 0)
    }

    /// A missing destination root fails (silent-retry transient) rather than
    /// silently recreating the folder somewhere new.
    @Test func missingRootFailsTransient() async throws {
        let root = try tempFolder()
        try FileManager.default.removeItem(at: root)  // folder deleted / volume gone
        let meetingID = ULID.generate()
        let payload = Data("x".utf8)
        let hash = EvidencePayloadBuilder.sha256Hex(payload)
        let outcome = try await LocalFolderTransport(root: root).deliver(
            argv: LocalFolderCommand.argv(meetingID: meetingID, hash: hash, nonce: "z"),
            payload: payload, timeout: 0)
        #expect(outcome.exitStatus == nil)
        #expect(outcome.failureClass == .transient)
        #expect(outcome.stderrTail.contains("missing"))
    }

    /// `.tmp` hygiene: a stale (>1 day) orphan temp is swept on the next
    /// delivery; a fresh same-dir temp from another meeting is untouched.
    @Test func staleTempHygiene() async throws {
        let root = try tempFolder()
        let meetingID = ULID.generate()
        let dir = root.appendingPathComponent(meetingID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let staleTemp = dir.appendingPathComponent(".tmp-deadbeef-old")
        try Data("orphan".utf8).write(to: staleTemp)
        let twoDaysAgo = Date().addingTimeInterval(-2 * 24 * 60 * 60)
        try FileManager.default.setAttributes([.modificationDate: twoDaysAgo], ofItemAtPath: staleTemp.path)

        let payload = Data("fresh".utf8)
        let hash = EvidencePayloadBuilder.sha256Hex(payload)
        _ = try await LocalFolderTransport(root: root).deliver(
            argv: LocalFolderCommand.argv(meetingID: meetingID, hash: hash, nonce: "n"),
            payload: payload, timeout: 0)
        #expect(!FileManager.default.fileExists(atPath: staleTemp.path))  // swept
        #expect(jsonCount(dir) == 1)
    }
}

// MARK: - AC1 (integration): the worker delivers to a local folder

@Suite struct LocalFolderWorkerTests {
    @Test func workerDeliversToLocalFolderWithSidecar() async throws {
        let database = try makeDatabase()
        let item = try await seedDeliverable(database, title: "Reunião local")
        let folder = try tempFolder()
        try await selectLocalFolder(database, folder)

        let worker = makeWorker(database)
        await worker.start()
        await worker.waitUntilSettled()

        let dir = folder.appendingPathComponent(item.meetingID)
        #expect(jsonCount(dir) == 1)
        let json = try Data(contentsOf: dir.appendingPathComponent("\(item.versionHash).json"))
        #expect(EvidencePayloadBuilder.sha256Hex(json) == item.versionHash)
        // Sidecar present.
        let mds = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".md") }
        #expect(mds.count == 1)
        // Delivered locally.
        let rows = try await HandoffRepository(database: database).allItems()
        #expect(rows.allSatisfy { $0.state == .delivered })
    }

    @Test func sidecarToggleOffSkipsSidecar() async throws {
        let database = try makeDatabase()
        let item = try await seedDeliverable(database)
        let folder = try tempFolder()
        try await selectLocalFolder(database, folder, sidecar: false)
        let worker = makeWorker(database)
        await worker.start()
        await worker.waitUntilSettled()
        let dir = folder.appendingPathComponent(item.meetingID)
        #expect(jsonCount(dir) == 1)
        let mds = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".md") }
        #expect(mds.isEmpty)
    }
}

// MARK: - AC3: markdown sidecar

@Suite struct MarkdownSidecarTests {
    private func fields(
        title: String, meetingID: String = ULID.generate(), attendees: [String] = ["Sam Rivera"]
    ) -> MarkdownSidecar.Fields {
        MarkdownSidecar.Fields(
            meetingID: meetingID, title: title,
            startedAt: Date(timeIntervalSince1970: 1_770_000_000),
            attendeeNames: attendees, versionHash: String(repeating: "a", count: 64),
            notesMarkdown: "# Notes\n\n- point\n")
    }

    @Test func frontmatterGoldenEN() {
        let doc = MarkdownSidecar.render(fields(title: "Q2 Budget Review", meetingID: "01EXAMPLE"))
        #expect(doc.contains("---\n"))
        #expect(doc.contains("title: Q2 Budget Review\n"))
        #expect(doc.contains("started_at: 2026-02-02T02:40:00Z"))
        #expect(doc.contains("source: blaise\n"))
        #expect(doc.contains("native_id: 01EXAMPLE\n"))
        #expect(doc.contains("version_hash: \(String(repeating: "a", count: 64))\n"))
        #expect(doc.contains("attendees:\n  - Sam Rivera\n"))
        #expect(doc.hasSuffix("# Notes\n\n- point\n"))
    }

    @Test func slugHandlesPTAndAccents() {
        #expect(MarkdownSidecar.slug("Reunião de Orçamento") == "reuniao-de-orcamento")
        #expect(MarkdownSidecar.slug("Q2 Budget Review!") == "q2-budget-review")
        #expect(MarkdownSidecar.slug("   ") == "meeting")  // empty fallback
        #expect(MarkdownSidecar.slug("🎙️🎙️") == "meeting")
    }

    /// Slug collision across DISTINCT meetings in one folder → ULID-suffix on
    /// the second so neither overwrites the other.
    @Test func slugCollisionGetsULIDSuffix() throws {
        let dir = try tempFolder()
        let a = ULID.generate()
        let b = ULID.generate()
        let nameA = MarkdownSidecar.write(fields(title: "Weekly Sync", meetingID: a), to: dir)
        let nameB = MarkdownSidecar.write(fields(title: "Weekly Sync", meetingID: b), to: dir)
        #expect(nameA == "weekly-sync.md")
        #expect(nameB == "weekly-sync-\(b).md")
        #expect(jsonCountMD(dir) == 2)  // both survive
    }

    /// Overwrite-on-supersession: a newer version of the SAME meeting
    /// overwrites the sidecar; exactly one current sidecar remains.
    @Test func supersessionOverwritesSidecar() throws {
        let dir = try tempFolder()
        let m = ULID.generate()
        _ = MarkdownSidecar.write(
            MarkdownSidecar.Fields(
                meetingID: m, title: "Planning", startedAt: Date(), attendeeNames: [],
                versionHash: String(repeating: "1", count: 64), notesMarkdown: "v1"),
            to: dir)
        let name2 = MarkdownSidecar.write(
            MarkdownSidecar.Fields(
                meetingID: m, title: "Planning", startedAt: Date(), attendeeNames: [],
                versionHash: String(repeating: "2", count: 64), notesMarkdown: "v2 updated"),
            to: dir)
        #expect(jsonCountMD(dir) == 1)
        let text = try String(contentsOf: dir.appendingPathComponent(name2!), encoding: .utf8)
        #expect(text.contains("v2 updated"))
        #expect(text.contains("version_hash: \(String(repeating: "2", count: 64))"))
    }

    /// Sidecar write failure is isolated from delivery: an unwritable dir
    /// (a FILE where the meeting dir should be) returns nil, never throws.
    @Test func writeFailureIsIsolated() throws {
        let parent = try tempFolder()
        // Put a regular file where the meeting directory would be → createDirectory fails.
        let blocked = parent.appendingPathComponent("blocked")
        try Data("not a dir".utf8).write(to: blocked)
        let result = MarkdownSidecar.write(fields(title: "X"), to: blocked)
        #expect(result == nil)
    }

    private func jsonCountMD(_ dir: URL) -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".md") }.count
    }
}

// MARK: - AC4: D21 warning over a persistent local failure + Retry Now

@Suite struct LocalFolderWarningTests {
    /// Folder deleted → the worker classifies the failure (transient,
    /// folder-specific reason), and after the 1-hour staleness boundary the
    /// D21 warning fires with the folder reason. Retry Now re-attempts.
    @Test func deletedFolderTripsStaleWarningAndRetryNowReattempts() async throws {
        let database = try makeDatabase()
        let item = try await seedDeliverable(database)
        let folder = try tempFolder()
        try await selectLocalFolder(database, folder)
        // Delete the destination so deliveries fail.
        try FileManager.default.removeItem(at: folder)

        // Clock past the 1-hour staleness boundary (the item was enqueued at
        // ~real now; advance the worker's clock).
        let future = Date().addingTimeInterval(2 * 60 * 60)
        let holder = await HandoffStatusHolder()
        let worker = makeWorker(database, holder: holder, now: { future })
        await worker.start()
        await worker.waitUntilSettled()

        let snapshot = await worker.currentSnapshot()
        // Not delivered (folder gone), warning armed.
        #expect(snapshot.warning != nil)
        #expect(snapshot.warning?.shortReason == "destination folder unavailable")

        // Restore the folder + Retry Now → delivers.
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await worker.retryNow()
        await worker.waitUntilSettled()
        let dir = folder.appendingPathComponent(item.meetingID)
        #expect(jsonCount(dir) == 1)
        let after = await worker.currentSnapshot()
        #expect(after.warning == nil)  // cleared silently on success
    }

    /// M-2: timer parity with the remote host-offline. An unresolvable bookmark (deleted
    /// folder / unplugged drive) must ARM the retry timer like the SSH-offline
    /// path — so once the folder is back, delivery resumes on the timer's OWN
    /// wake, with NO manual Retry Now and NO unrelated external wake. This fails
    /// under the pre-fix shape, where the unresolvable branch returned after
    /// only the stale-boundary arm (null while the queue is fresh) and parked.
    @Test func unresolvableBookmarkArmsRetryTimerAndResumesOnRestore() async throws {
        let database = try makeDatabase()
        let item = try await seedDeliverable(database)
        // Select a local folder, then DELETE it so the bookmark cannot resolve
        // (the production unplugged-drive path, not the missing-root branch).
        let folder = try tempFolder()
        try await selectLocalFolder(database, folder)
        try FileManager.default.removeItem(at: folder)

        // jitter 0 ⇒ the item floor (and thus the armed timer's delay) is ~0,
        // so the timer fires promptly without a real 30 s wait — the cadence is
        // what is under test, not the literal delay.
        let worker = HandoffWorker(
            database: database, jitter: { _ in 0 }, nonce: { testNonce })
        await worker.start()
        await worker.waitUntilSettled()

        // Queue is stale-failed (no delivery yet); restore the folder. NO kick,
        // NO retryNow — the timer that the unresolvable branch armed must drive
        // the next attempt on its own.
        let dir = folder.appendingPathComponent(item.meetingID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Poll for the timer-driven delivery (bounded; no external wake issued).
        var delivered = false
        for _ in 0..<200 where !delivered {
            try? await Task.sleep(for: .milliseconds(25))
            await worker.waitUntilSettled()
            delivered = jsonCount(dir) == 1
        }
        #expect(delivered, "armed retry timer did not resume delivery after the folder was restored")
        let rows = try await HandoffRepository(database: database).allItems()
        #expect(rows.allSatisfy { $0.state == .delivered })
    }
}

// MARK: - AC5: settings round-trip + migration

@Suite struct HandoffDestinationSettingsTests {
    /// Migration: a fixture with ONLY the existing SSH keys (no destination
    /// discriminator) resolves to `.ssh` with those exact values — zero
    /// behavior change for existing installs.
    @Test func migrationExistingInstallResolvesToSSH() async throws {
        let database = try makeDatabase()
        let store = SettingsStore(database: database)
        // Pre-G5 install: only handoff.* SSH keys present, no handoff.destination.
        // L-1: use NON-default values so the assertion is non-vacuous — an
        // implementation that ignored the store and returned shippedDefault
        // would now fail. These are still injection-safe (validated below).
        let stored = HandoffSettings(
            user: "custombot",
            identityFile: "~/.ssh/blaise_migrated",
            hosts: ["10.0.0.9", "10.0.0.10"],
            remoteRoot: "/Users/custombot/Inbox/blaise")
        try await store.set(HandoffSettings.Key.user, to: stored.user)
        try await store.set(HandoffSettings.Key.identityFile, to: stored.identityFile)
        try await store.set(HandoffSettings.Key.hosts, to: stored.hosts)
        try await store.set(HandoffSettings.Key.remoteRoot, to: stored.remoteRoot)

        let destination = try await HandoffDestination.load(from: store)
        guard case .ssh(let settings, _) = destination else {
            #expect(Bool(false), "expected .ssh after migration"); return
        }
        #expect(settings == stored)
        #expect(settings != HandoffSettings.shippedDefault)  // proves the store was read
        try settings.validate()  // migrated values remain injection-safe
        #expect(destination.kind == .ssh)
    }

    /// A completely empty store (fresh install) also resolves to `.ssh` with
    /// shipped defaults (absent discriminator ⇒ ssh).
    @Test func absentDiscriminatorDefaultsToSSH() async throws {
        let database = try makeDatabase()
        let destination = try await HandoffDestination.load(from: SettingsStore(database: database))
        #expect(destination.kind == .ssh)
    }

    /// Local folder round-trip: pick a folder (bookmark), relaunch resolves the
    /// SAME url; SSH keys are untouched.
    @Test func localFolderBookmarkRoundTrips() async throws {
        let database = try makeDatabase()
        let folder = try tempFolder()
        try await selectLocalFolder(database, folder, sidecar: false)
        // "Relaunch": fresh resolution from the same store.
        let destination = try await HandoffDestination.load(from: SettingsStore(database: database))
        guard case .localFolder(let url, let sidecar) = destination else {
            #expect(Bool(false), "expected .localFolder"); return
        }
        #expect(url.resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path)
        #expect(sidecar == false)
    }

    /// Local destination selected but no bookmark saved → resolution throws
    /// (the worker surfaces configurationInvalid; nothing lost).
    @Test func localFolderMissingBookmarkThrows() async throws {
        let database = try makeDatabase()
        let store = SettingsStore(database: database)
        try await store.set(HandoffDestination.Key.kind, to: HandoffDestination.Kind.localFolder)
        await #expect(throws: HandoffDestination.ResolutionError.self) {
            _ = try await HandoffDestination.load(from: store)
        }
    }

    /// R3-C1: the local half of the destination-instance identity is the chosen
    /// folder's RESOURCE (volume + file id), never its pathname. Both directions
    /// are load-bearing: a folder that MOVES keeps its identity — the whole
    /// point of the security-scoped bookmark, and path-keying would strand every
    /// payload already delivered there — while the volume the folder lives on is
    /// part of the string, so a different volume mounted at the same mountpoint
    /// (the silent remount, with no Settings interaction to bump the epoch)
    /// cannot match a row delivered to the previous one.
    @Test func localIdentityFollowsTheResourceNotThePath() throws {
        let parent = try tempFolder()
        let folder = parent.appendingPathComponent("Evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let identity = HandoffDestination.localFolder(url: folder, markdownSidecar: false)
            .endpointIdentity(epoch: 3)
        #expect(identity.hasPrefix("e3:local:"))
        #expect(!identity.contains(folder.path), "the path is not what authorizes a deletion")

        let volumeUUID = try #require(
            try folder.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
        #expect(identity.contains(volumeUUID), "a replacement volume reads as a different store")

        let moved = parent.appendingPathComponent("Evidence renamed", isDirectory: true)
        try FileManager.default.moveItem(at: folder, to: moved)
        #expect(
            HandoffDestination.localFolder(url: moved, markdownSidecar: false)
                .endpointIdentity(epoch: 3) == identity,
            "the bookmark follows a move, and so does cleanup continuity")

        let other = try tempFolder()
        #expect(
            HandoffDestination.localFolder(url: other, markdownSidecar: false)
                .endpointIdentity(epoch: 3) != identity,
            "a different folder is a different store")
    }

    /// The Settings view-model load + save round-trips the destination kind and
    /// sidecar toggle (AC5 round-trip through the model the UI binds).
    @MainActor @Test func settingsModelRoundTripsDestination() async throws {
        let database = try makeDatabase()
        let store = SettingsStore(database: database)
        let model = HandoffSettingsModel(settings: store, kicker: NoopHandoffKicker())
        await model.load()
        #expect(model.destinationKind == .ssh)  // default
        model.destinationKind = .localFolder
        let folder = try tempFolder()
        _ = await model.chooseLocalFolder(folder)
        model.markdownSidecar = false
        let saved = await model.save()
        #expect(saved)  // folder chosen → valid

        let reloaded = HandoffSettingsModel(settings: store, kicker: NoopHandoffKicker())
        await reloaded.load()
        #expect(reloaded.destinationKind == .localFolder)
        #expect(reloaded.markdownSidecar == false)
        #expect(!reloaded.localFolderPath.isEmpty)
    }
}

// MARK: - AC6: byte-identical payloads across destinations

@Suite struct CrossDestinationPayloadParityTests {
    /// The SAME builder produces the SAME bytes regardless of destination: the
    /// JSON delivered to a local folder is byte-identical to what the SSH path
    /// would stream (the transport differs only in WHERE the bytes land).
    @Test func localFolderJSONByteIdenticalToBuilder() async throws {
        let database = try makeDatabase()
        let item = try await seedDeliverable(database, title: "Parity meeting", segmentText: "Olá, çãé 🎙")
        let folder = try tempFolder()
        try await selectLocalFolder(database, folder, sidecar: true)
        let worker = makeWorker(database)
        await worker.start()
        await worker.waitUntilSettled()

        // The on-disk local JSON.
        let dir = folder.appendingPathComponent(item.meetingID)
        let localJSON = try Data(contentsOf: dir.appendingPathComponent("\(item.versionHash).json"))

        // What the builder produces from the same durable state (= what the SSH
        // path streams: the worker's selfCheck returns these exact bytes).
        guard let meeting = try await MeetingRepository(database: database).fetch(item.meetingID),
            let notes = try await NotesRepository(database: database).fetch(meetingID: item.meetingID)
        else { throw TestFailure() }
        let segments = try await TranscriptRepository(database: database).segments(meetingID: item.meetingID)
        let built = EvidencePayloadBuilder.build(
            meeting: meeting, segments: segments, notes: notes, user: .shippedDefault)

        #expect(localJSON == built.bytes)
        #expect(EvidencePayloadBuilder.sha256Hex(localJSON) == built.versionHash)
        #expect(built.versionHash == item.versionHash)
    }
}

// MARK: - G6: destination-independent Markdown sidecar over SSH

/// Flips the destination-independent Markdown-sidecar toggle (the SSH path
/// uploads the .md alongside the JSON when ON). `seedDeliverable` defaults it
/// OFF for the JSON-mechanics tests, so the SSH-sidecar tests opt in here.
private func setSSHSidecar(_ database: BlaiseDatabase, _ on: Bool) async throws {
    try await SettingsStore(database: database)
        .set(HandoffDestination.Key.localMarkdownSidecar, to: on)
}

@Suite struct SSHSidecarUploadTests {
    /// Toggle ON: after the JSON delivers, a SECOND ssh invocation uploads the
    /// rendered .md to the SAME remote meeting dir via the pinned sidecar
    /// command, streaming the rendered bytes on stdin.
    @Test func sshUploadsSidecarWhenToggleOn() async throws {
        let database = try makeDatabase()
        let item = try await seedDeliverable(database, title: "Q2 Budget Review")
        try await setSSHSidecar(database, true)
        let transport = MockTransport()
        let worker = makeWorker(database, transport: transport)
        await worker.kick()
        await worker.waitUntilSettled()

        // Delivered, and exactly two transport calls: JSON then sidecar.
        let rows = try await HandoffRepository(database: database).allItems()
        #expect(rows.allSatisfy { $0.state == .delivered })
        #expect(transport.calls.count == 2)

        let settings = handoffValidExample
        let remoteDir = settings.remoteRoot + "/" + item.meetingID
        // Call 1 = JSON (pinned argv, exact payload bytes).
        let json = transport.calls[0]
        #expect(json.argv == HandoffCommand.argv(
            user: settings.user, host: settings.hosts[0], identityFile: settings.identityFile,
            remoteDir: remoteDir, hash: item.versionHash, nonce: testNonce))
        // Call 2 = sidecar (pinned sidecar argv + the rendered .md bytes).
        let sidecar = transport.calls[1]
        #expect(sidecar.argv == HandoffCommand.sidecarArgv(
            user: settings.user, host: settings.hosts[0], identityFile: settings.identityFile,
            remoteDir: remoteDir, slug: "q2-budget-review"))
        #expect(sidecar.argv.last
            == "mkdir -p '\(remoteDir)' && rm -f '\(remoteDir)'/*.md 2>/dev/null; "
            + "cat > '\(remoteDir)/q2-budget-review.md'")
        // The streamed bytes are the rendered sidecar (frontmatter + notes).
        let body = String(decoding: sidecar.payload, as: UTF8.self)
        #expect(body.contains("title: Q2 Budget Review\n"))
        #expect(body.contains("native_id: \(item.meetingID)\n"))
        #expect(body.contains("version_hash: \(item.versionHash)\n"))
    }

    /// Toggle OFF: the SSH path delivers ONLY the JSON — no sidecar upload.
    @Test func sshSkipsSidecarWhenToggleOff() async throws {
        let database = try makeDatabase()
        _ = try await seedDeliverable(database, title: "Q2 Budget Review")
        try await setSSHSidecar(database, false)
        let transport = MockTransport()
        let worker = makeWorker(database, transport: transport)
        await worker.kick()
        await worker.waitUntilSettled()

        let rows = try await HandoffRepository(database: database).allItems()
        #expect(rows.allSatisfy { $0.state == .delivered })
        #expect(transport.calls.count == 1)  // JSON only
        #expect(transport.calls[0].argv.last?.contains(".md") == false)
    }

    /// A hostile, shell-metacharacter-laden meeting title still uploads via a
    /// safe [a-z0-9-] slug — the command carries no injectable token.
    @Test func sshSidecarSlugFromHostileTitleIsSafe() async throws {
        let database = try makeDatabase()
        let hostile = "'; rm -rf / # $(whoami) `id` && echo pwned"
        let item = try await seedDeliverable(database, title: hostile)
        try await setSSHSidecar(database, true)
        let transport = MockTransport()
        let worker = makeWorker(database, transport: transport)
        await worker.kick()
        await worker.waitUntilSettled()

        #expect(transport.calls.count == 2)
        let remoteDir = handoffValidExample.remoteRoot + "/" + item.meetingID
        let slug = MarkdownSidecar.slug(hostile)
        #expect(slug.allSatisfy { $0 == "-" || ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") })
        let command = transport.calls[1].argv.last
        #expect(command == "mkdir -p '\(remoteDir)' && rm -f '\(remoteDir)'/*.md 2>/dev/null; "
            + "cat > '\(remoteDir)/\(slug).md'")
        // No stray single quote outside the delimiter pairs ⇒ no breakout.
        #expect(command?.contains("rm -rf") == false)
    }

    /// Failure-isolation (CRITICAL): a sidecar-upload FAILURE never fails or
    /// retries the JSON queue item. The JSON delivers (exit 0) and the item is
    /// `.delivered`; the sidecar's non-zero exit is logged and swallowed.
    @Test func sidecarUploadFailureDoesNotFailJSONDelivery() async throws {
        let database = try makeDatabase()
        let item = try await seedDeliverable(database, title: "Q2 Budget Review")
        try await setSSHSidecar(database, true)
        // Call 1 (JSON) succeeds; call 2 (sidecar) fails non-zero.
        let transport = MockTransport(script: [
            HandoffTransportOutcome(exitStatus: 0, stderrTail: "", timedOut: false),
            HandoffTransportOutcome(exitStatus: 255, stderrTail: "sidecar boom", timedOut: false),
        ])
        let worker = makeWorker(database, transport: transport)
        await worker.kick()
        await worker.waitUntilSettled()

        // JSON still delivered (the sidecar failure is isolated); no retry burn.
        let rows = try await HandoffRepository(database: database).allItems()
        #expect(rows.first?.state == .delivered)
        #expect(rows.first?.id == item.id)
        #expect(transport.calls.count == 2)  // attempted once, not retried
        let history = await worker.deliveryHistory()
        #expect(history.map(\.itemID) == [item.id])
        await #expect(worker.currentSnapshot().state == .idle)
    }

    /// A spawn-error (thrown) on the sidecar upload is equally isolated: the
    /// JSON stays delivered, the queue item is not re-attempted.
    @Test func sidecarUploadThrowDoesNotFailJSONDelivery() async throws {
        let database = try makeDatabase()
        let item = try await seedDeliverable(database, title: "Planning")
        try await setSSHSidecar(database, true)
        // First call succeeds (JSON); the second THROWS (spawn-style failure).
        // Construct the worker directly so the throwing transport (any
        // HandoffTransporting) can be injected — makeWorker pins MockTransport.
        let transport = ThrowOnNthCallTransport(throwOnCall: 2)
        let worker = HandoffWorker(
            database: database, transport: transport, prober: MockProber(),
            jitter: { $0 }, nonce: { testNonce })
        await worker.kick()
        await worker.waitUntilSettled()

        let rows = try await HandoffRepository(database: database).allItems()
        #expect(rows.first?.state == .delivered)
        #expect(rows.first?.id == item.id)
        let state = await worker.currentSnapshot().state
        #expect(state == .idle)
    }
}

/// A transport that succeeds on every call EXCEPT the Nth, where it throws —
/// models a sidecar-upload spawn failure while the JSON delivery succeeds.
private final class ThrowOnNthCallTransport: HandoffTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let throwOnCall: Int
    struct Boom: Error {}

    init(throwOnCall: Int) { self.throwOnCall = throwOnCall }

    func deliver(argv: [String], payload: Data, timeout: TimeInterval) async throws -> HandoffTransportOutcome {
        let n: Int = lock.withLock { count += 1; return count }
        if n == throwOnCall { throw Boom() }
        return HandoffTransportOutcome(exitStatus: 0, stderrTail: "", timedOut: false)
    }
}
