import Foundation
import GRDB
@testable import BlaiseCore

struct TestFailure: Error {}

/// The onboarded identity the pipeline harness seeds (G3: the shipped default
/// is now empty). Payload-comparison tests that re-materialize a payload to
/// compare against a pipeline-minted one MUST use this exact identity so the
/// owner block matches byte-for-byte.
extension UserIdentity {
    static let onboardedUser = UserIdentity(
        name: "Sam", aliases: ["Sam", "Sam Rivera"], email: "sam.rivera@vexatron.test")
}

/// Millisecond-precision date with a binary-exact fraction (GRDB stores
/// datetimes with ms precision, so round-trip equality holds for these).
func msDate(_ secondsSince1970: Double = 1_770_000_000.5) -> Date {
    Date(timeIntervalSince1970: secondsSince1970)
}

func makeTempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("BlaiseTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func makeDatabase() throws -> BlaiseDatabase {
    try BlaiseDatabase(rootURL: makeTempRoot())
}

func makeMeeting(
    id: MeetingID = ULID.generate(),
    title: String = "Weekly sync",
    startedAt: Date = msDate(),
    source: MeetingSource = .meet,
    status: MeetingStatus = .processing,
    attendees: [Attendee] = []
) -> Meeting {
    Meeting(
        id: id,
        title: title,
        startedAt: startedAt,
        source: source,
        status: status,
        attendees: attendees,
        createdAt: msDate(),
        updatedAt: msDate()
    )
}

func makeStructuredNotes() -> NotesStructured {
    NotesStructured(
        title: "Notas",
        summary: "Resumo da reunião.",
        detailedNotes: "Discussão sobre a proposta.",
        decisions: ["Enviar proposta"],
        actionItems: [ActionItem(owner: "Sam", text: "enviar proposta")],
        userActionItems: [ActionItem(owner: "Sam", text: "enviar proposta")]
    )
}

func makeNotes(meetingID: MeetingID, markdown: String = "# Notas\n- Sam: enviar proposta") -> MeetingNotes {
    MeetingNotes(
        meetingID: meetingID,
        markdown: markdown,
        structured: makeStructuredNotes(),
        language: "pt-BR",
        generatedAt: msDate(),
        provenance: NotesProvenance(
            engine: "test-engine",
            model: "test-model",
            pipelineVersion: "0.1",
            runtime: "test-runtime",
            rendererVersion: NotesRenderer.version
        )
    )
}

/// Writes a payload file under the meeting's handoff directory and returns
/// its root-relative path (the form `enqueue` expects).
@discardableResult
func plantPayload(
    _ database: BlaiseDatabase,
    meetingID: MeetingID,
    versionHash: String,
    bytes: Data? = nil
) throws -> String {
    let data = bytes ?? Data("{\"native_id\":\"\(meetingID)\",\"version_hash\":\"\(versionHash)\"}\n".utf8)
    let relative = database.paths.relativeHandoffPayloadPath(meetingID: meetingID, versionHash: versionHash)
    try ImmutablePayloadWriter.write(data, to: database.rootURL.appendingPathComponent(relative))
    return relative
}

/// Creates a meeting row plus an on-disk payload, ready for enqueue.
func makeEnqueueableMeeting(
    _ database: BlaiseDatabase,
    versionHash: String = "hash-\(UUID().uuidString)"
) async throws -> (meeting: Meeting, versionHash: String, payloadPath: String) {
    let meeting = makeMeeting()
    try await MeetingRepository(database: database).create(meeting)
    let path = try plantPayload(database, meetingID: meeting.id, versionHash: versionHash)
    return (meeting, versionHash, path)
}

extension BlaiseDatabase {
    func tableNames() throws -> Set<String> {
        try pool.read { db in
            try Set(String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
        }
    }

    func count(_ table: String) throws -> Int {
        try pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? -1
        }
    }

    func rawFTSMatchCount(_ term: String) throws -> Int {
        try pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM transcript_fts WHERE transcript_fts MATCH ?",
                arguments: [term]
            ) ?? -1
        }
    }

    /// FTS5 external-content integrity check: throws SQLITE_CORRUPT_VTAB if
    /// the index does not match the content table.
    func checkFTSIntegrity() throws {
        try pool.write { db in
            try db.execute(sql: "INSERT INTO transcript_fts(transcript_fts, rank) VALUES('integrity-check', 1)")
        }
    }
}

struct FileIdentity: Equatable {
    let inode: UInt64
    let modificationDate: Date
    let bytes: Data

    init(of url: URL) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        self.inode = (attrs[.systemFileNumber] as? UInt64) ?? UInt64(attrs[.systemFileNumber] as? Int ?? -1)
        self.modificationDate = attrs[.modificationDate] as? Date ?? .distantPast
        self.bytes = try Data(contentsOf: url)
    }
}
