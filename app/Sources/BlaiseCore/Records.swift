import Foundation
import GRDB

// GRDB record conformances for the domain model. Column names are the
// snake_case CodingKeys raw values declared in Domain.swift; nested Codable
// values (attendees, provenances) are stored as JSON TEXT by GRDB's default
// Codable handling.

extension Meeting: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "meeting"
}

extension TranscriptSegment: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "transcript_segment"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension MeetingNotes: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "meeting_notes"
}

extension HandoffItem: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "handoff_queue"
}

extension ProcessingJob: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "processing_queue"
}
