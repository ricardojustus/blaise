import Foundation
import GRDB
import os

// G16 (specs/g16_audio_retention.md): owner-intent audio retention.
//
// Amends the C1 retention guarantee and G10 Floor 2: retained audio is deleted
// ONLY under a durable owner-intent record — the `meeting.audio_deleted_at`
// mark (migration v23), written by a manual Delete Audio action or by an
// owner-set size cap. Row-absence or a missing mark proves nothing: a
// recreated blaise.sqlite has no marks, so nothing is ever deleted (§1).
//
// Order, crash-safe (§1), driven by `ProcessingPipeline.deleteAudio` in its
// chain slot:
//   1. Re-check eligibility.
//   2. Commit the mark (`markDeleted`, targeted SQL; never bumps updated_at).
//   3. Remove the files (`removeAudioFiles`, the ONE audio-deleting function).
// Kill before (2) → nothing happened. Kill between (2) and (3) → launch
// recovery's `sweepMarked` removes the remaining files (it runs right after
// the tombstone sweep and BEFORE `CaptureRecovery.sweepOrphanCAFs`, which —
// with `redispatchInterrupted` — skips marked rows so a leftover CAF is never
// re-encoded into fresh audio).

/// Who asked for the deletion (§2 has one column per origin).
public enum AudioDeletionOrigin: String, Sendable, Equatable, CaseIterable {
    /// Delete Audio / Delete All Audio.
    case manual
    /// The owner-set size cap (automatic).
    case cap

    /// The reason recorded on the mark.
    public var reason: AudioDeletionReason {
        switch self {
        case .manual: return .manual
        case .cap: return .cap
        }
    }
}

/// A manual deletion that is allowed but deserves a confirmation-dialog note
/// (§2).
public enum AudioDeletionWarning: String, Sendable, Equatable, CaseIterable {
    /// The meeting is `failed` / `cancelled`: without audio it can no longer be
    /// retried.
    case cannotRetry
    /// A handoff item is still pending / delivering / failed while audio
    /// delivery is on: it will ship without audio.
    case pendingAudioDelivery
}

/// Why a deletion is refused (§2). For the cap origin every refusal means
/// "skip this meeting".
public enum AudioDeletionRefusal: String, Sendable, Equatable, CaseIterable {
    case recording, paused, processing
    /// A pending or running `processing_queue` job exists for the meeting.
    case processingQueued
    /// The meeting already carries the mark (manual: no-op; cap: skip).
    case alreadyDeleted
    /// Allowed manually but never automatically (failed / cancelled, pending
    /// audio delivery, the most recent meeting).
    case notEligibleForCap
    case notFound
}

/// The §2 verdict for one meeting and origin.
public enum AudioEligibility: Sendable, Equatable {
    case eligible(warnings: [AudioDeletionWarning])
    case refused(AudioDeletionRefusal)

    public var isEligible: Bool {
        if case .eligible = self { return true }
        return false
    }
}

/// Storage usage of retained audio across every meeting (§4).
public struct AudioUsage: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let meetingID: MeetingID
        public let title: String
        public let startedAt: Date
        /// Allocated bytes of the meeting's audio files (m4a + CAF + import.wav).
        public let bytes: Int64
        public let audioDeletedAt: Date?
        public let manualEligible: Bool
        public let capEligible: Bool
    }

    /// Every meeting, oldest first by `startedAt` (the cap plan's order).
    public let entries: [Entry]

    public var totalBytes: Int64 { entries.reduce(0) { $0 + $1.bytes } }
    public var meetingsWithAudio: Int { entries.filter { $0.bytes > 0 }.count }
    public var capEligibleBytes: Int64 {
        entries.filter(\.capEligible).reduce(0) { $0 + $1.bytes }
    }
    public var manualEligibleBytes: Int64 {
        entries.filter(\.manualEligible).reduce(0) { $0 + $1.bytes }
    }

    public init(entries: [Entry]) {
        self.entries = entries
    }
}

/// What a cap sweep would delete (§4). Pure output of `AudioRetention.capPlan`.
public struct AudioCapPlan: Sendable, Equatable {
    /// Meetings whose audio to delete, oldest first by `startedAt`.
    public let meetingIDs: [MeetingID]
    /// Bytes those deletions free.
    public let bytesFreed: Int64
    /// Bytes still over the cap after the plan (> 0 only when the remaining
    /// audio over the cap is all ineligible; the sweep never forces).
    public let remainingOverCap: Int64

    public init(meetingIDs: [MeetingID], bytesFreed: Int64, remainingOverCap: Int64) {
        self.meetingIDs = meetingIDs
        self.bytesFreed = bytesFreed
        self.remainingOverCap = remainingOverCap
    }

    public static let empty = AudioCapPlan(meetingIDs: [], bytesFreed: 0, remainingOverCap: 0)
    public var isEmpty: Bool { meetingIDs.isEmpty }
}

public enum AudioRetention {
    private static let logger = Logger(subsystem: BlaiseBundle.identifier, category: "audio.retention")

    // MARK: - The file set (§1: explicit list, never a glob)

    /// The meeting's retained-audio files that exist on disk: every `audio*.m4a`
    /// (`MeetingPaths.retainedAudioURLs`), every on-disk `capture_*.caf` part
    /// (both tracks, from `CaptureParts.diskCAFPartIndices`), and `import.wav`.
    /// Derived artifacts (`raw_asr*.json`, `diarization.json`,
    /// `room_treatment.json`, transcript, notes, handoff payloads) are never in
    /// this list. Existence follows symlinks, so a symlinked leaf pointing at an
    /// existing file IS listed — `removeAudioFiles` refuses it.
    static func audioFileURLs(paths: MeetingPaths, meetingID: MeetingID) -> [URL] {
        let fm = FileManager.default
        var urls = paths.retainedAudioURLs(meetingID)
        for part in CaptureParts.diskCAFPartIndices(paths: paths, meetingID: meetingID).sorted() {
            for track in CaptureTrack.allCases {
                let caf = paths.captureCAFURL(meetingID, track: track, part: part)
                if fm.fileExists(atPath: caf.path) { urls.append(caf) }
            }
        }
        let importCopy = paths.importCopyURL(meetingID)
        if fm.fileExists(atPath: importCopy.path) { urls.append(importCopy) }
        return urls.filter { fm.fileExists(atPath: $0.path) }
    }

    // MARK: - The mark (§1 step 2)

    /// Commits the owner-intent mark. Targeted SQL on the two columns only:
    /// NEVER bumps `updated_at` (C1 v6.7, metadata) and never re-mints the
    /// handoff payload (the payload carries no audio). This is the ONLY writer
    /// of the columns — `Meeting`'s encoder omits them, so full-record writes
    /// can neither set nor clear the mark.
    static func markDeleted(
        database: BlaiseDatabase,
        meetingID: MeetingID,
        reason: AudioDeletionReason,
        now: Date = Date()
    ) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    UPDATE meeting SET audio_deleted_at = ?, audio_deleted_reason = ?
                    WHERE id = ?
                    """,
                arguments: [now, reason.rawValue, meetingID])
            guard db.changesCount == 1 else {
                throw BlaiseDatabaseError.meetingNotFound(meetingID)
            }
        }
        logger.notice(
            "audio deletion mark written for \(meetingID, privacy: .public) (reason: \(reason.rawValue, privacy: .public))")
    }

    // MARK: - The single removal path (§1 step 3)

    /// THE one function that deletes retained audio (C1/G10 floor-2 amendment).
    /// Acts ONLY on a row carrying the mark; an unmarked or missing row is a
    /// no-op (returns false when audio remains). Each file goes through the G10
    /// containment check (`MeetingDeletion.resolvedWithinMeetingsRoot`); a
    /// symlinked leaf (checked BEFORE resolving) or a path escaping `meetings/`
    /// is refused and logged, never followed. Returns true iff no audio file of
    /// the meeting remains afterwards.
    @discardableResult
    static func removeAudioFiles(database: BlaiseDatabase, meetingID: MeetingID) async -> Bool {
        let marked =
            (try? await database.pool.read { db in
                try Bool.fetchOne(
                    db,
                    sql: "SELECT audio_deleted_at IS NOT NULL FROM meeting WHERE id = ?",
                    arguments: [meetingID])
            }) ?? nil
        let paths = database.paths
        guard marked == true else {
            logger.error(
                "audio removal requested for \(meetingID, privacy: .public) without an owner-intent mark — refused")
            return audioFileURLs(paths: paths, meetingID: meetingID).isEmpty
        }
        let fm = FileManager.default
        for url in audioFileURLs(paths: paths, meetingID: meetingID) {
            let isSymlink =
                ((try? fm.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType)
                == .typeSymbolicLink
            guard !isSymlink else {
                logger.warning(
                    "audio file \(url.lastPathComponent, privacy: .public) of \(meetingID, privacy: .public) is a symlink — REFUSED, not followed")
                continue
            }
            guard MeetingDeletion.resolvedWithinMeetingsRoot(url, database: database) != nil else {
                logger.error(
                    "audio file \(url.lastPathComponent, privacy: .public) of \(meetingID, privacy: .public) resolves OUTSIDE the meetings directory — REFUSED")
                continue
            }
            do {
                try fm.removeItem(at: url)
            } catch {
                // Residue, never loss: the mark stays, the next launch's
                // `sweepMarked` retries.
                logger.error(
                    "audio file removal failed for \(meetingID, privacy: .public) (\(url.lastPathComponent, privacy: .public)): \(error)")
            }
        }
        let remaining = audioFileURLs(paths: paths, meetingID: meetingID)
        if remaining.isEmpty {
            logger.notice("audio removed for \(meetingID, privacy: .public)")
        }
        return remaining.isEmpty
    }

    /// Launch sweep (§1): every marked row whose audio files remain (a kill
    /// between mark and removal, or an earlier failed removal) → the single
    /// removal path. Keys ONLY on the mark, never on dir-vs-row
    /// reconciliation. Runs right after the tombstone sweep and BEFORE
    /// `CaptureRecovery.sweepOrphanCAFs`. Returns the swept meeting ids.
    @discardableResult
    public static func sweepMarked(database: BlaiseDatabase) async -> [MeetingID] {
        let marked =
            (try? await database.pool.read { db in
                try String.fetchAll(
                    db,
                    sql: "SELECT id FROM meeting WHERE audio_deleted_at IS NOT NULL ORDER BY id")
            }) ?? []
        let paths = database.paths
        var swept: [MeetingID] = []
        for meetingID in marked where ULID.isValid(meetingID) {
            guard !audioFileURLs(paths: paths, meetingID: meetingID).isEmpty else { continue }
            await removeAudioFiles(database: database, meetingID: meetingID)
            swept.append(meetingID)
        }
        if !swept.isEmpty {
            logger.notice("marked-audio sweep removed residue for \(swept.count) meeting(s)")
        }
        return swept
    }

    // MARK: - Eligibility (§2)

    /// The per-meeting inputs of the §2 table, fetched in batch for `usage`
    /// or singly for `eligibility`.
    struct EligibilityFacts: Sendable, Equatable {
        var status: MeetingStatus
        var marked: Bool
        var liveProcessingJob: Bool
        var undeliveredHandoff: Bool
        var deliverAudio: Bool
        var isMostRecent: Bool
    }

    /// The §2 table, applied in its row order so multi-condition meetings get
    /// a deterministic verdict: status refusals → already marked → queued or
    /// running job → failed/cancelled → pending audio delivery → most recent.
    static func evaluate(_ facts: EligibilityFacts, origin: AudioDeletionOrigin) -> AudioEligibility {
        switch facts.status {
        case .recording: return .refused(.recording)
        case .paused: return .refused(.paused)
        case .processing: return .refused(.processing)
        case .ready, .failed, .cancelled: break
        }
        if facts.marked { return .refused(.alreadyDeleted) }
        if facts.liveProcessingJob { return .refused(.processingQueued) }
        var warnings: [AudioDeletionWarning] = []
        if facts.status == .failed || facts.status == .cancelled {
            guard origin == .manual else { return .refused(.notEligibleForCap) }
            warnings.append(.cannotRetry)
        }
        if facts.undeliveredHandoff && facts.deliverAudio {
            guard origin == .manual else { return .refused(.notEligibleForCap) }
            warnings.append(.pendingAudioDelivery)
        }
        if facts.isMostRecent && origin == .cap {
            return .refused(.notEligibleForCap)
        }
        return .eligible(warnings: warnings)
    }

    private static let liveJobStates = "('pending','running')"
    private static let undeliveredHandoffStates = "('pending','delivering','failed')"

    /// The §2 verdict for one meeting. Read-only; `ProcessingPipeline.deleteAudio`
    /// re-runs it inside its chain slot before committing the mark.
    public static func eligibility(
        database: BlaiseDatabase,
        meetingID: MeetingID,
        origin: AudioDeletionOrigin
    ) async throws -> AudioEligibility {
        let deliverAudio = await HandoffDestination.deliverAudio(from: SettingsStore(database: database))
        let facts: EligibilityFacts? = try await database.pool.read { db in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql: "SELECT status, audio_deleted_at IS NOT NULL AS marked FROM meeting WHERE id = ?",
                    arguments: [meetingID])
            else { return nil }
            let rawStatus: String = row["status"]
            guard let status = MeetingStatus(rawValue: rawStatus) else { return nil }
            let liveJob =
                try Bool.fetchOne(
                    db,
                    sql: """
                        SELECT EXISTS(SELECT 1 FROM processing_queue
                        WHERE meeting_id = ? AND state IN \(liveJobStates))
                        """,
                    arguments: [meetingID]) ?? false
            let undelivered =
                try Bool.fetchOne(
                    db,
                    sql: """
                        SELECT EXISTS(SELECT 1 FROM handoff_queue
                        WHERE meeting_id = ? AND state IN \(undeliveredHandoffStates))
                        """,
                    arguments: [meetingID]) ?? false
            let mostRecent =
                try Bool.fetchOne(
                    db,
                    sql: """
                        SELECT started_at = (SELECT MAX(started_at) FROM meeting)
                        FROM meeting WHERE id = ?
                        """,
                    arguments: [meetingID]) ?? false
            return EligibilityFacts(
                status: status, marked: row["marked"], liveProcessingJob: liveJob,
                undeliveredHandoff: undelivered, deliverAudio: deliverAudio,
                isMostRecent: mostRecent)
        }
        guard let facts else { return .refused(.notFound) }
        return evaluate(facts, origin: origin)
    }

    // MARK: - Usage (§4)

    /// Allocated bytes of every meeting's audio files (`totalFileAllocatedSize`,
    /// falling back to `fileSize`) plus each meeting's manual / cap eligibility.
    /// Four queries in total regardless of meeting count; the rest is disk.
    public static func usage(database: BlaiseDatabase) async throws -> AudioUsage {
        let deliverAudio = await HandoffDestination.deliverAudio(from: SettingsStore(database: database))
        struct MeetingFacts {
            let id: MeetingID
            let title: String
            let startedAt: Date
            let status: String
            let audioDeletedAt: Date?
        }
        let (meetings, liveJobs, undelivered) = try await database.pool.read { db in
            let meetings = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, title, started_at, status, audio_deleted_at FROM meeting
                    ORDER BY started_at ASC, id ASC
                    """
            ).map { row in
                MeetingFacts(
                    id: row["id"], title: row["title"], startedAt: row["started_at"],
                    status: row["status"], audioDeletedAt: row["audio_deleted_at"])
            }
            let liveJobs = Set(
                try String.fetchAll(
                    db,
                    sql: "SELECT DISTINCT meeting_id FROM processing_queue WHERE state IN \(liveJobStates)"))
            let undelivered = Set(
                try String.fetchAll(
                    db,
                    sql: "SELECT DISTINCT meeting_id FROM handoff_queue WHERE state IN \(undeliveredHandoffStates)"))
            return (meetings, liveJobs, undelivered)
        }
        let latestStart = meetings.map(\.startedAt).max()
        let paths = database.paths
        let entries: [AudioUsage.Entry] = meetings.compactMap { meeting in
            guard ULID.isValid(meeting.id), let status = MeetingStatus(rawValue: meeting.status)
            else { return nil }
            let facts = EligibilityFacts(
                status: status, marked: meeting.audioDeletedAt != nil,
                liveProcessingJob: liveJobs.contains(meeting.id),
                undeliveredHandoff: undelivered.contains(meeting.id),
                deliverAudio: deliverAudio,
                isMostRecent: meeting.startedAt == latestStart)
            let bytes = audioFileURLs(paths: paths, meetingID: meeting.id)
                .reduce(Int64(0)) { $0 + allocatedSize(of: $1) }
            return AudioUsage.Entry(
                meetingID: meeting.id, title: meeting.title, startedAt: meeting.startedAt,
                bytes: bytes, audioDeletedAt: meeting.audioDeletedAt,
                manualEligible: evaluate(facts, origin: .manual).isEligible,
                capEligible: evaluate(facts, origin: .cap).isEligible)
        }
        return AudioUsage(entries: entries)
    }

    private static func allocatedSize(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        return Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
    }

    // MARK: - Cap plan (§4)

    /// The §4 cap plan: cap-eligible meetings (which already excludes the
    /// most recent meeting, failed / cancelled, pending audio delivery, queued
    /// or in-flight ones and marked rows) oldest-first by `startedAt`, until
    /// total usage ≤ cap. Pure; `.unlimited` plans nothing.
    public static func capPlan(usage: AudioUsage, cap: AudioRetentionCap) -> AudioCapPlan {
        capPlan(usage: usage, capBytes: cap.bytes)
    }

    /// `capPlan` on a raw byte limit (nil = unlimited); tests use sub-GB caps.
    static func capPlan(usage: AudioUsage, capBytes: Int64?) -> AudioCapPlan {
        guard let limit = capBytes else { return .empty }
        var total = usage.totalBytes
        guard total > limit else { return .empty }
        let candidates = usage.entries
            .filter { $0.capEligible && $0.bytes > 0 }
            .sorted { ($0.startedAt, $0.meetingID) < ($1.startedAt, $1.meetingID) }
        var ids: [MeetingID] = []
        var freed: Int64 = 0
        for entry in candidates {
            guard total > limit else { break }
            ids.append(entry.meetingID)
            freed += entry.bytes
            total -= entry.bytes
        }
        return AudioCapPlan(meetingIDs: ids, bytesFreed: freed, remainingOverCap: max(0, total - limit))
    }
}
