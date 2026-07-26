import Foundation
import Testing

@testable import BlaiseCore

// The opt-in transcript Markdown sidecar (community request): a second `.md`
// beside the notes sidecar at the LOCAL destination, default OFF. Shares
// seedDeliverable / makeWorker with the sibling handoff suites.

private func tsTempFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("transcript-sidecar-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Selects the local destination. `transcript` left nil leaves the key ABSENT —
/// the state every existing install upgrades into, which is what the default
/// must be asserted from.
private func selectLocalDest(
    _ database: BlaiseDatabase, _ folder: URL, transcript: Bool? = nil,
    removeSuperseded: Bool? = nil
) async throws {
    let store = SettingsStore(database: database)
    let bookmark = try folder.bookmarkData(
        options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    try await store.set(HandoffDestination.Key.kind, to: HandoffDestination.Kind.localFolder)
    try await store.set(HandoffDestination.Key.localBookmark, to: bookmark.base64EncodedString())
    try await store.set(HandoffDestination.Key.localPath, to: folder.path)
    try await store.set(HandoffDestination.Key.localMarkdownSidecar, to: true)
    if let transcript {
        try await store.set(HandoffDestination.Key.transcriptSidecar, to: transcript)
    }
    if let removeSuperseded {
        try await store.set(HandoffDestination.Key.removeSupersededPayloads, to: removeSuperseded)
    }
}

private func markdownNames(_ dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        .filter { $0.hasSuffix(".md") }.sorted()
}

@Suite(.serialized) struct TranscriptSidecarTests {
    /// Absent key ⇒ OFF ⇒ byte-identical to today: the notes sidecar alone.
    @Test func absentKeyWritesNoTranscriptSidecar() async throws {
        let database = try makeDatabase()
        let item = try await seedDeliverable(database, title: "Quoll Harbor sync")
        let folder = try tsTempFolder()
        try await selectLocalDest(database, folder)  // key deliberately unset

        let worker = makeWorker(database)
        await worker.start()
        await worker.waitUntilSettled()

        let destDir = folder.appendingPathComponent(item.meetingID)
        #expect(markdownNames(destDir) == ["quoll-harbor-sync.md"])
    }

    /// ON ⇒ the transcript lands as its own sibling `.md`, rendered by the app's
    /// existing copy-transcript renderer.
    @Test func toggleOnWritesTranscriptBesideNotes() async throws {
        let database = try makeDatabase()
        let item = try await seedDeliverable(database, title: "Quoll Harbor sync")
        let folder = try tsTempFolder()
        try await selectLocalDest(database, folder, transcript: true)

        let worker = makeWorker(database)
        await worker.start()
        await worker.waitUntilSettled()

        let destDir = folder.appendingPathComponent(item.meetingID)
        #expect(markdownNames(destDir) == ["quoll-harbor-sync-transcript.md", "quoll-harbor-sync.md"])

        let segments = try await TranscriptRepository(database: database)
            .segments(meetingID: item.meetingID)
        let text = try String(
            contentsOf: destDir.appendingPathComponent("quoll-harbor-sync-transcript.md"),
            encoding: .utf8)
        #expect(text.contains("\nkind: transcript\n"))
        #expect(text.contains("native_id: \(item.meetingID)\n"))
        #expect(text.hasSuffix(TranscriptCopyText.assemble(segments) + "\n"))
        // The notes sidecar is unchanged by the new kind — no `kind:` line.
        let notesText = try String(
            contentsOf: destDir.appendingPathComponent("quoll-harbor-sync.md"), encoding: .utf8)
        #expect(!notesText.contains("kind: transcript"))
    }

    /// Re-delivery overwrites each sidecar IN PLACE, and neither kind deletes
    /// the other (the prior-sidecar sweep is kind-aware).
    @Test func redeliveryOverwritesAndNeitherKindDeletesTheOther() async throws {
        let database = try makeDatabase()
        let item = try await seedDeliverable(database, title: "Quoll Harbor sync")
        let folder = try tsTempFolder()
        try await selectLocalDest(database, folder, transcript: true)

        let worker = makeWorker(database)
        await worker.start()
        await worker.waitUntilSettled()

        let v2 = try await enqueueSecondTranscriptVersion(database, item.meetingID)
        await worker.kick()
        await worker.waitUntilSettled()

        let destDir = folder.appendingPathComponent(item.meetingID)
        #expect(markdownNames(destDir) == ["quoll-harbor-sync-transcript.md", "quoll-harbor-sync.md"])
        let notesText = try String(
            contentsOf: destDir.appendingPathComponent("quoll-harbor-sync.md"), encoding: .utf8)
        #expect(
            notesText.contains("version_hash: \(v2.versionHash)\n"),
            "the notes sidecar was overwritten by the re-delivery")
        // The transcript carries NO payload hash — its provenance is the
        // transcript rows, which a payload correction does not touch.
        let transcriptText = try String(
            contentsOf: destDir.appendingPathComponent("quoll-harbor-sync-transcript.md"),
            encoding: .utf8)
        #expect(!transcriptText.contains("version_hash:"))
    }

    /// The superseded-payload sweep is `<hash>.json`-only: opting INTO it never
    /// removes either `.md`.
    @Test func cleanupSweepNeverTouchesEitherMarkdown() async throws {
        let database = try makeDatabase()
        let item = try await seedDeliverable(database, title: "Quoll Harbor sync")
        let folder = try tsTempFolder()
        try await selectLocalDest(database, folder, transcript: true, removeSuperseded: true)

        let worker = makeWorker(database)
        await worker.start()
        await worker.waitUntilSettled()
        let v2 = try await enqueueSecondTranscriptVersion(database, item.meetingID)
        await worker.kick()
        await worker.waitUntilSettled()

        let destDir = folder.appendingPathComponent(item.meetingID)
        let jsons = ((try? FileManager.default.contentsOfDirectory(atPath: destDir.path)) ?? [])
            .filter { $0.hasSuffix(".json") }
        #expect(jsons == ["\(v2.versionHash).json"], "the sweep removed the superseded payload")
        #expect(markdownNames(destDir) == ["quoll-harbor-sync-transcript.md", "quoll-harbor-sync.md"])
    }

    /// No transcript rows ⇒ skip, exactly like a missing notes row: no
    /// header-only file is written.
    @Test func noTranscriptRowsSkipsTheSidecar() async throws {
        let database = try makeDatabase()
        let item = try await seedDeliverable(database, title: "Quoll Harbor sync")
        let folder = try tsTempFolder()
        try await selectLocalDest(database, folder, transcript: true)
        try await TranscriptRepository(database: database).deleteTranscript(
            meetingID: item.meetingID)

        let worker = makeWorker(database)
        await worker.start()
        await worker.waitUntilSettled()

        let destDir = folder.appendingPathComponent(item.meetingID)
        #expect(markdownNames(destDir) == ["quoll-harbor-sync.md"])
    }

    // MARK: - Kind detection (the frontmatter-scoped classifier)

    /// A notes BODY containing the line `kind: transcript` (a note quoting this
    /// very format) must not be read as the transcript sidecar: classification
    /// is frontmatter-only. Otherwise the transcript write deletes the notes
    /// file and a notes re-delivery mints a ULID-suffixed twin.
    @Test func poisonedNotesBodyKeepsItsKind() throws {
        let dir = try tsTempFolder()
        let m = ULID.generate()
        let poisoned = "# Notes\n\nWe agreed the frontmatter reads:\n\nkind: transcript\n"
        let notesName = MarkdownSidecar.write(tsFields(m, body: poisoned), to: dir)
        MarkdownSidecar.write(tsFields(m, body: "Sam: olá", kind: .transcript), to: dir)
        #expect(markdownNames(dir) == ["quoll-harbor-sync-transcript.md", "quoll-harbor-sync.md"])

        // Toggle OFF ⇒ a notes-only re-delivery: overwrites in place, no twin.
        let again = MarkdownSidecar.write(tsFields(m, body: "# Notes v2\n"), to: dir)
        #expect(again == notesName)
        #expect(markdownNames(dir) == ["quoll-harbor-sync-transcript.md", "quoll-harbor-sync.md"])
        let text = try String(contentsOf: dir.appendingPathComponent(notesName!), encoding: .utf8)
        #expect(text.hasSuffix("# Notes v2\n"))
    }

    /// A newline in a title cannot inject a frontmatter line.
    @Test func newlineInTitleCannotInjectFrontmatter() {
        let doc = MarkdownSidecar.render(
            tsFields(ULID.generate(), title: "Quoll Harbor\nkind: transcript", body: "# Notes\n"))
        let header = doc.components(separatedBy: "\n---\n")[0]
        #expect(!header.contains("\nkind: transcript"))
        #expect(header.contains("title: "))
    }

    /// A sidecar written before the `kind:` line existed is still THIS meeting's
    /// NOTES sidecar: a transcript write leaves it alone, a notes re-delivery
    /// overwrites it in place.
    @Test func legacyKindlessSidecarIsStillTheNotesSidecar() throws {
        let dir = try tsTempFolder()
        let m = ULID.generate()
        let legacy = dir.appendingPathComponent("quoll-harbor-sync.md")
        try Data(
            """
            ---
            title: Quoll Harbor sync
            source: blaise
            native_id: \(m)
            version_hash: \(String(repeating: "a", count: 64))
            ---

            legacy body

            """.utf8
        ).write(to: legacy)

        MarkdownSidecar.write(tsFields(m, body: "Sam: olá", kind: .transcript), to: dir)
        #expect(try String(contentsOf: legacy, encoding: .utf8).contains("legacy body"))

        let name = MarkdownSidecar.write(tsFields(m, body: "# Notes v2\n"), to: dir)
        #expect(name == "quoll-harbor-sync.md")
        #expect(markdownNames(dir) == ["quoll-harbor-sync-transcript.md", "quoll-harbor-sync.md"])
        #expect(try String(contentsOf: legacy, encoding: .utf8).hasSuffix("# Notes v2\n"))

        // Block path for the closing-delimiter guard: a `---`-opened file with
        // NO closing `---` is unclassifiable, so it survives untouched and the
        // transcript write mints a ULID-suffixed twin instead of claiming it.
        let mangled = dir.appendingPathComponent("quoll-harbor-sync-transcript.md")
        let truncated = "---\ntitle: Quoll Harbor sync\nnative_id: \(m)\nkind: transcript\n"
        try Data(truncated.utf8).write(to: mangled)
        MarkdownSidecar.write(tsFields(m, body: "Sam: olá", kind: .transcript), to: dir)
        #expect(try String(contentsOf: mangled, encoding: .utf8) == truncated)
        #expect(markdownNames(dir).contains("quoll-harbor-sync-transcript-\(m).md"))
    }

    /// A user's OWN note — no frontmatter at all, but a `---` rule in the body
    /// and a line quoting `native_id:` — is nobody's sidecar: classification
    /// starts at a leading `---`. Neither a notes nor a transcript write may
    /// claim it (claiming it means deleting it as a "prior sidecar").
    @Test func frontmatterlessNoteQuotingNativeIDIsNeverOurs() throws {
        let dir = try tsTempFolder()
        let m = ULID.generate()
        let mine = dir.appendingPathComponent("my-thoughts.md")
        let text = """
            # My own note

            native_id: \(m)

            ---

            still mine

            """
        try Data(text.utf8).write(to: mine)

        MarkdownSidecar.write(tsFields(m, body: "# Notes\n"), to: dir)
        MarkdownSidecar.write(tsFields(m, body: "Sam: olá", kind: .transcript), to: dir)
        #expect(try String(contentsOf: mine, encoding: .utf8) == text)
        #expect(markdownNames(dir).contains("my-thoughts.md"))
    }
}

// MARK: - The transcript sidecar over SSH (destination parity with the notes sidecar)

/// Opts the SSH path into a sidecar combination. Both keys are
/// destination-independent; `seedDeliverable` leaves the notes key OFF.
private func setSSHSidecars(
    _ database: BlaiseDatabase, notes: Bool, transcript: Bool
) async throws {
    let store = SettingsStore(database: database)
    try await store.set(HandoffDestination.Key.localMarkdownSidecar, to: notes)
    try await store.set(HandoffDestination.Key.transcriptSidecar, to: transcript)
}

/// Replay a recorded remote command against a real `sh`, rooted at a temp dir
/// standing in for the remote root, with the recorded payload on stdin. The
/// remote LOGIN SHELL is what expands the command's globs, so re-implementing
/// that expansion in Swift would pin an assumption rather than the behaviour.
private func replayRemoteCommand(_ call: MockTransport.Call, root: URL) throws {
    let command = (call.argv.last ?? "")
        .replacingOccurrences(of: handoffValidExample.remoteRoot, with: root.path)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    let stdin = Pipe()
    process.standardInput = stdin
    try process.run()
    stdin.fileHandleForWriting.write(call.payload)
    try stdin.fileHandleForWriting.close()
    process.waitUntilExit()
}

@Suite struct SSHTranscriptSidecarTests {
    /// Toggle ON: a THIRD ssh invocation uploads the transcript to the same
    /// remote meeting dir under the `-transcript` name, with `kind: transcript`
    /// frontmatter and the persisted-transcript body.
    @Test func sshUploadsTranscriptSidecarWhenToggleOn() async throws {
        let database = try makeDatabase()
        let item = try await seedDeliverable(database, title: "Q2 Budget Review")
        try await setSSHSidecars(database, notes: true, transcript: true)
        let transport = MockTransport()
        let worker = makeWorker(database, transport: transport)
        await worker.kick()
        await worker.waitUntilSettled()

        let rows = try await HandoffRepository(database: database).allItems()
        #expect(rows.allSatisfy { $0.state == .delivered })
        #expect(transport.calls.count == 3)  // JSON, notes sidecar, transcript sidecar

        let settings = handoffValidExample
        let remoteDir = settings.remoteRoot + "/" + item.meetingID
        let transcriptCall = transport.calls[2]
        #expect(transcriptCall.argv == HandoffCommand.sidecarArgv(
            user: settings.user, host: settings.hosts[0], identityFile: settings.identityFile,
            remoteDir: remoteDir, slug: "q2-budget-review", kind: .transcript))
        #expect(transcriptCall.argv.last
            == "mkdir -p '\(remoteDir)' && cat > '\(remoteDir)/q2-budget-review-transcript.md'")

        // The streamed bytes are the transcript render — byte-identical to what
        // the LOCAL writer would produce for this meeting (same fields, same
        // renderer), which is what "one source" buys.
        let segments = try await TranscriptRepository(database: database)
            .segments(meetingID: item.meetingID)
        let body = String(decoding: transcriptCall.payload, as: UTF8.self)
        #expect(body.contains("\nkind: transcript\n"))
        #expect(body.contains("native_id: \(item.meetingID)\n"))
        #expect(!body.contains("version_hash:"))
        #expect(body.hasSuffix(TranscriptCopyText.assemble(segments) + "\n"))
    }

    /// Toggle OFF (the shipped default, asserted from the ABSENT key): the SSH
    /// path uploads the notes sidecar only — no transcript file.
    @Test func sshUploadsNoTranscriptSidecarWhenToggleOff() async throws {
        let database = try makeDatabase()
        _ = try await seedDeliverable(database, title: "Q2 Budget Review")
        // Notes ON, transcript key deliberately never set.
        try await SettingsStore(database: database)
            .set(HandoffDestination.Key.localMarkdownSidecar, to: true)
        let transport = MockTransport()
        let worker = makeWorker(database, transport: transport)
        await worker.kick()
        await worker.waitUntilSettled()

        #expect(transport.calls.count == 2)  // JSON + notes sidecar
        #expect(transport.calls.allSatisfy { $0.argv.last?.contains("-transcript.md") == false })
    }

    /// The two kinds COEXIST remotely: distinct file names, and each command's
    /// prior-slug `rm` is scoped to its own kind, so neither upload removes the
    /// other's remote file.
    @Test func notesAndTranscriptSidecarsCoexistRemotely() async throws {
        let database = try makeDatabase()
        let item = try await seedDeliverable(database, title: "Q2 Budget Review")
        try await setSSHSidecars(database, notes: true, transcript: true)
        let transport = MockTransport()
        let worker = makeWorker(database, transport: transport)
        await worker.kick()
        await worker.waitUntilSettled()

        let remoteDir = handoffValidExample.remoteRoot + "/" + item.meetingID
        let notesCommand = transport.calls[1].argv.last ?? ""
        let transcriptCommand = transport.calls[2].argv.last ?? ""
        // Different targets…
        #expect(notesCommand.hasSuffix("cat > '\(remoteDir)/q2-budget-review.md'"))
        #expect(transcriptCommand.hasSuffix("cat > '\(remoteDir)/q2-budget-review-transcript.md'"))
        // …and the transcript command sweeps nothing at all, so it cannot reach
        // the notes file, while the notes sweep runs FIRST, before the
        // transcript is written back.
        #expect(!transcriptCommand.contains("rm -f"))
        #expect(notesCommand.contains("rm -f '\(remoteDir)'/*.md"))
    }

    /// Coexistence as the PROPERTY, not as command text: a title whose slug
    /// already ends in `-transcript` gives the notes sidecar a remote name that
    /// any `*-transcript.md` sweep would match. Both commands are replayed, in
    /// the worker's order, against a real shell — BOTH files must survive.
    @Test func sidecarsCoexistWhenTheSlugEndsInTranscript() async throws {
        let database = try makeDatabase()
        let item = try await seedDeliverable(database, title: "Quoll Harbor transcript")
        try await setSSHSidecars(database, notes: true, transcript: true)
        let transport = MockTransport()
        let worker = makeWorker(database, transport: transport)
        await worker.kick()
        await worker.waitUntilSettled()

        #expect(transport.calls.count == 3)  // JSON, notes sidecar, transcript sidecar
        let root = try tsTempFolder()
        try replayRemoteCommand(transport.calls[1], root: root)  // notes first, as the worker orders them
        try replayRemoteCommand(transport.calls[2], root: root)

        let remoteDir = root.appendingPathComponent(item.meetingID)
        #expect(markdownNames(remoteDir)
            == ["quoll-harbor-transcript-transcript.md", "quoll-harbor-transcript.md"])
    }

    /// A hostile, shell-metacharacter-laden title reaches the transcript command
    /// only through the `[a-z0-9-]` slug — no injectable token, no breakout.
    @Test func sshTranscriptSlugFromHostileTitleIsSafe() async throws {
        let database = try makeDatabase()
        let hostile = "'; rm -rf / # $(whoami) `id` && echo pwned"
        let item = try await seedDeliverable(database, title: hostile)
        try await setSSHSidecars(database, notes: false, transcript: true)
        let transport = MockTransport()
        let worker = makeWorker(database, transport: transport)
        await worker.kick()
        await worker.waitUntilSettled()

        #expect(transport.calls.count == 2)  // JSON + transcript sidecar
        let remoteDir = handoffValidExample.remoteRoot + "/" + item.meetingID
        let slug = MarkdownSidecar.slug(hostile)
        #expect(HandoffCommand.isSafeSlug(slug))
        let command = transport.calls[1].argv.last
        #expect(command
            == "mkdir -p '\(remoteDir)' && cat > '\(remoteDir)/\(slug)-transcript.md'")
        #expect(command?.contains("rm -rf") == false)
    }

    /// The block path of the slug guard: an unsafe slug is rejected outright, so
    /// the uploader SKIPS rather than ever emitting such a command. (The
    /// production `slug` cannot produce one; this pins the guard itself.)
    @Test func unsafeSlugsAreRejectedByTheGuard() {
        #expect(!HandoffCommand.isSafeSlug("q2'; rm -rf /"))
        #expect(!HandoffCommand.isSafeSlug("Q2-budget"))
        #expect(!HandoffCommand.isSafeSlug("q2 budget"))
        #expect(!HandoffCommand.isSafeSlug("q2/../budget"))
        #expect(HandoffCommand.isSafeSlug("q2-budget-review"))
    }

    /// Failure isolation: a transcript-upload failure never fails or retries the
    /// JSON queue item (the JSON is the contract; the sidecar is convenience).
    @Test func transcriptUploadFailureDoesNotFailJSONDelivery() async throws {
        let database = try makeDatabase()
        let item = try await seedDeliverable(database, title: "Q2 Budget Review")
        try await setSSHSidecars(database, notes: false, transcript: true)
        // Call 1 (JSON) succeeds; call 2 (transcript sidecar) fails non-zero.
        let transport = MockTransport(script: [
            HandoffTransportOutcome(exitStatus: 0, stderrTail: "", timedOut: false),
            HandoffTransportOutcome(exitStatus: 255, stderrTail: "transcript boom", timedOut: false),
        ])
        let worker = makeWorker(database, transport: transport)
        await worker.kick()
        await worker.waitUntilSettled()

        let rows = try await HandoffRepository(database: database).allItems()
        #expect(rows.first?.state == .delivered)
        #expect(rows.first?.id == item.id)
        #expect(transport.calls.count == 2)  // attempted once, not retried
        let history = await worker.deliveryHistory()
        #expect(history.map(\.itemID) == [item.id])
        await #expect(worker.currentSnapshot().state == .idle)
    }

    /// No transcript rows ⇒ no upload at all (the local skip, over SSH).
    @Test func noTranscriptRowsSkipsTheUpload() async throws {
        let database = try makeDatabase()
        let item = try await seedDeliverable(database, title: "Q2 Budget Review")
        try await setSSHSidecars(database, notes: false, transcript: true)
        try await TranscriptRepository(database: database).deleteTranscript(
            meetingID: item.meetingID)
        let transport = MockTransport()
        let worker = makeWorker(database, transport: transport)
        await worker.kick()
        await worker.waitUntilSettled()

        #expect(transport.calls.count == 1)  // JSON only
    }
}

private func tsFields(
    _ meetingID: String, title: String = "Quoll Harbor sync", body: String,
    kind: MarkdownSidecar.Kind = .notes
) -> MarkdownSidecar.Fields {
    MarkdownSidecar.Fields(
        meetingID: meetingID, title: title,
        startedAt: Date(timeIntervalSince1970: 1_770_000_000),
        attendeeNames: ["Sam Rivera"], versionHash: String(repeating: "a", count: 64),
        bodyMarkdown: body, kind: kind)
}

/// Re-mints a different payload version for the same meeting (a correction) and
/// enqueues it — the transcript rows are untouched, matching the filed request's
/// "transcripts are unchanged by note edits".
@discardableResult
private func enqueueSecondTranscriptVersion(
    _ database: BlaiseDatabase, _ meetingID: MeetingID
) async throws -> HandoffItem {
    guard var notes = try await NotesRepository(database: database).fetch(meetingID: meetingID),
        let meeting = try await MeetingRepository(database: database).fetch(meetingID)
    else { throw TestFailure() }
    notes.markdown += "\n<!-- corrected -->"
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
