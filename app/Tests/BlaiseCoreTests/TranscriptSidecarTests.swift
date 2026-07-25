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
        for name in markdownNames(destDir) {
            let text = try String(
                contentsOf: destDir.appendingPathComponent(name), encoding: .utf8)
            #expect(
                text.contains("version_hash: \(v2.versionHash)\n"),
                "\(name) was overwritten by the re-delivery")
        }
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
    /// header-only file, and any previously written transcript survives.
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
