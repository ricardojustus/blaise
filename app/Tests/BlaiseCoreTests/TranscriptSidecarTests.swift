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
