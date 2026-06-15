import Foundation
import GRDB
import os

// C11: verified-encode gating for capture tracks + the orphan-CAF startup
// sweep. Hard floor 2 end to end: a capture CAF (retention-class while it
// exists — C1 v6.5) is deleted ONLY here, ONLY after the encoded m4a passes
// its verification decode. The same function serves the clean stop path and
// the post-crash recovery sweep.

public enum CaptureRecovery {
    /// The third processingNote writer class (C7 v3.3 / C1 v6.6 amendment):
    /// notes carrying this prefix SURVIVE run-entry clears until a run
    /// completes with both tracks or the user dismisses them.
    public static let notePrefix = "capture recovery:"

    private static let logger = Logger(subsystem: BlaiseBundle.identifier, category: "capture.recovery")

    // MARK: - The single audited verified-encode function

    /// Encodes a capture CAF into its retained m4a and releases (deletes)
    /// the CAF — the ONLY code path that may delete a `capture_*.caf`
    /// (C1 v6.5 amendment scopes the no-deletion-API claim to `audio*.m4a`
    /// plus this function). Steps:
    ///
    /// 1. m4a absent → encode via the C7 ingest encode path (AAC-LC 32 kbps,
    ///    temp + atomic rename) with the verification decode ON THE TEMP
    ///    file (duration within 0.5 s of the CAF); a failed verification
    ///    leaves no m4a and the CAF stays.
    /// 2. m4a present (crash landed between encode and release) → verify it
    ///    still decodes with the CAF's duration before letting the CAF go.
    /// 3. Only after a verified m4a exists is the CAF removed.
    public static func encodeVerifiedAndRelease(caf: URL, m4a: URL) throws {
        let fm = FileManager.default
        let cafDuration = try AudioTranscoder.duration(of: caf)
        if !fm.fileExists(atPath: m4a.path) {
            try AudioTranscoder.encodeToM4A(wav: caf, destination: m4a) { tempURL in
                let encoded = try AudioTranscoder.duration(of: tempURL)
                guard abs(encoded - cafDuration) <= 0.5 else {
                    throw PipelineIngestError.encodeVerificationFailed(
                        "capture encode duration \(encoded) vs CAF \(cafDuration)")
                }
            }
        } else {
            let encoded = try AudioTranscoder.duration(of: m4a)
            guard abs(encoded - cafDuration) <= 0.5 else {
                throw PipelineIngestError.encodeVerificationFailed(
                    "existing m4a duration \(encoded) vs CAF \(cafDuration); CAF retained")
            }
        }
        try fm.removeItem(at: caf)
    }

    // MARK: - Per-meeting track finalization (stop path + sweep share it)

    public enum TrackState: Equatable, Sendable {
        /// Verified retained audio exists (CAF released, or already encoded).
        case encoded
        /// Encode/verification failed — the CAF stays on disk, surfaced.
        case failed(String)
        /// No CAF and no retained m4a for this track.
        case absent
    }

    public struct TrackResult: Sendable {
        public let track: CaptureTrack
        public let state: TrackState
        /// Capture part this result belongs to (C14 multi-part; 1 = today's
        /// unsuffixed artifacts).
        public let part: Int

        init(track: CaptureTrack, state: TrackState, part: Int = 1) {
            self.track = track
            self.state = state
            self.part = part
        }
    }

    public struct FinalizeOutcome: Sendable {
        public let results: [TrackResult]

        public var encodedTracks: [CaptureTrack] {
            results.filter { $0.state == .encoded }.map(\.track)
        }
        public var failedTracks: [(CaptureTrack, String)] {
            results.compactMap {
                if case .failed(let reason) = $0.state { return ($0.track, reason) }
                return nil
            }
        }
        /// Both tracks have verified retained audio.
        public var bothTracks: Bool { encodedTracks.count == CaptureTrack.allCases.count }
        /// At least one track can feed processing.
        public var anyTrack: Bool { !encodedTracks.isEmpty }

        /// The capture-recovery processingNote for a partial outcome; nil
        /// when both tracks verified (nothing to flag) or nothing survived
        /// at all is still flagged — never a silent loss.
        public var recoveryNote: String? {
            let failed = results.compactMap { result -> String? in
                guard case .failed(let reason) = result.state else { return nil }
                let partSuffix = result.part > 1 ? " part \(result.part)" : ""
                return "\(result.track.rawValue) track\(partSuffix) audio damaged (\(reason); CAF retained)"
            }
            guard !failed.isEmpty else { return nil }
            let damaged = failed.joined(separator: "; ")
            if anyTrack {
                var seen: Set<String> = []
                let survivors = encodedTracks.map(\.rawValue)
                    .filter { seen.insert($0).inserted }
                    .joined(separator: "+")
                return "\(CaptureRecovery.notePrefix) \(damaged) — transcript proceeds from the \(survivors) track"
            }
            return "\(CaptureRecovery.notePrefix) \(damaged) — no track recoverable"
        }
    }

    /// Encodes + verifies + releases every capture CAF of one meeting part
    /// (C14: part 1 = today's unsuffixed artifacts, byte-identical path).
    /// Never throws: per-track failures are reported, the CAF stays.
    ///
    /// Zero-frame rule (C1 amendment, the SECOND sanctioned deletion path):
    /// a CAF whose duration probe proves ZERO audio frames is removed
    /// without producing an m4a — no audio ever existed, so this is not a
    /// retention event (covers start failures and an empty part-n stop, the
    /// identical proof obligation). The track reports `.absent`.
    public static func finalizeTracks(
        paths: MeetingPaths, meetingID: MeetingID, part: Int = 1
    ) -> FinalizeOutcome {
        let fm = FileManager.default
        var results: [TrackResult] = []
        for track in CaptureTrack.allCases {
            let caf = paths.captureCAFURL(meetingID, track: track, part: part)
            let m4a = track.retainedURL(paths, meetingID: meetingID, part: part)
            if fm.fileExists(atPath: caf.path) {
                if !fm.fileExists(atPath: m4a.path),
                    let duration = try? AudioTranscoder.duration(of: caf), duration == 0
                {
                    // Zero-frame CAF, no retained m4a: provably empty.
                    try? fm.removeItem(at: caf)
                    logger.notice(
                        "removed zero-frame capture CAF (part \(part)): \(caf.lastPathComponent)")
                    results.append(TrackResult(track: track, state: .absent, part: part))
                    continue
                }
                do {
                    try encodeVerifiedAndRelease(caf: caf, m4a: m4a)
                    results.append(TrackResult(track: track, state: .encoded, part: part))
                } catch {
                    let reason = "\(error)"
                    logger.error("capture track \(track.rawValue) encode failed: \(reason)")
                    results.append(TrackResult(track: track, state: .failed(reason), part: part))
                }
            } else if fm.fileExists(atPath: m4a.path) {
                results.append(TrackResult(track: track, state: .encoded, part: part))
            } else {
                results.append(TrackResult(track: track, state: .absent, part: part))
            }
        }
        return FinalizeOutcome(results: results)
    }

    /// Part-aware whole-meeting finalize: every part with a CAF on disk plus
    /// part 1 (today's behavior). The sweep and the stop path share the
    /// per-part function above.
    public static func finalizeAllParts(paths: MeetingPaths, meetingID: MeetingID) -> FinalizeOutcome {
        var indices = CaptureParts.diskCAFPartIndices(paths: paths, meetingID: meetingID)
        indices.insert(1)
        var results: [TrackResult] = []
        for part in indices.sorted() {
            results.append(contentsOf: finalizeTracks(paths: paths, meetingID: meetingID, part: part).results)
        }
        return FinalizeOutcome(results: results)
    }

    // MARK: - Capture-recovery note writer (the third writer class)

    /// Sets the capture-recovery processingNote. Direct column write — this
    /// class is owned by capture recovery, not by a pipeline run (C7's
    /// single-writer-per-run rule governs the other two classes).
    public static func writeRecoveryNote(database: BlaiseDatabase, meetingID: MeetingID, note: String) async {
        try? await database.pool.write { db in
            try db.execute(
                sql: "UPDATE meeting SET processing_note = ? WHERE id = ?",
                arguments: [note, meetingID])
        }
    }

    /// User dismissal (C7 v3.3: the note survives until a both-tracks run
    /// completes OR the user dismisses it).
    public static func dismissRecoveryNote(database: BlaiseDatabase, meetingID: MeetingID) async {
        try? await database.pool.write { db in
            try db.execute(
                sql: "UPDATE meeting SET processing_note = NULL WHERE id = ? AND processing_note LIKE ?",
                arguments: [meetingID, "\(notePrefix)%"])
        }
    }

    // MARK: - Orphan-CAF startup sweep

    public struct SweepResult: Sendable, Equatable {
        public let meetingID: MeetingID
        public let kicked: Bool
        public let note: String?
    }

    /// Startup sweep (C11): a crashed capture leaves orphan `capture_*.caf`
    /// in meeting directories. For each such meeting: encode + verify +
    /// attach the retained audio, flag partial losses via the capture-
    /// recovery note, and AUTO-KICK processing (no babysitting) through
    /// `kick` — the status-dependent, track-inventory-aware dispatch.
    ///
    /// An ACTIVELY-RECORDING meeting is never touched: the DB startup sweep
    /// (at open, before this runs) has already flipped every crashed
    /// `recording` row to `failed`, so a row still in `recording` here IS a
    /// live session — finalizing it would unlink the CAF under the live
    /// writer and silently lose everything after the sweep point.
    ///
    /// G9: a `paused` meeting IS finalized (its parts encoded for retention,
    /// floor 2) but its kick is WITHHELD below. The Resume control is gated
    /// on this sweep's completion (round-3 M-8), so a live new-part CAF can
    /// never coexist with a `paused` row while this sweep runs — the live
    /// engine is only started AFTER the sweep reports done.
    @discardableResult
    public static func sweepOrphanCAFs(
        database: BlaiseDatabase,
        kick: @escaping @Sendable (MeetingID) async -> Void
    ) async -> [SweepResult] {
        let fm = FileManager.default
        let paths = database.paths
        guard
            let entries = try? fm.contentsOfDirectory(
                at: paths.meetingsDirectory, includingPropertiesForKeys: nil)
        else { return [] }

        var results: [SweepResult] = []
        for directory in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let meetingID = directory.lastPathComponent
            guard ULID.isValid(meetingID) else { continue }
            // Part-aware (C14): orphan `capture_*_<n>.caf` files key the
            // sweep alongside the unsuffixed pair.
            let hasOrphan = !CaptureParts.diskCAFPartIndices(paths: paths, meetingID: meetingID)
                .isEmpty
            guard hasOrphan else { continue }
            let status =
                (try? await database.pool.read { db in
                    try String.fetchOne(
                        db, sql: "SELECT status FROM meeting WHERE id = ?",
                        arguments: [meetingID])
                }) ?? nil
            guard let status else {
                logger.error("orphan capture CAFs for unknown meeting \(meetingID); files left in place")
                continue
            }
            guard status != MeetingStatus.recording.rawValue else {
                logger.notice("capture sweep: meeting \(meetingID) is actively recording — skipped")
                continue
            }

            let outcome = finalizeAllParts(paths: paths, meetingID: meetingID)
            if let note = outcome.recoveryNote {
                await writeRecoveryNote(database: database, meetingID: meetingID, note: note)
            }
            // G9 (H-1, the load-bearing change): a `paused` meeting keeps its
            // parts ENCODED (retention, floor 2) but its auto-kick is
            // WITHHELD — no path may process a paused meeting until End flips
            // it. The encode above is ungated; only the kick is gated. This
            // is the one hole the §2 gate closes; `dispatchProcessing` also
            // refuses `paused` (defense in depth).
            //
            // G10 §1: a `cancelled` meeting is the SAME shape — parts encoded
            // for retention, kick withheld. The user chose to cancel; the
            // sweep must not auto-resurrect the run. The kick closure also
            // passes `refuseCancelled: true` (defense in depth).
            var kicked = false
            if outcome.anyTrack,
                status != MeetingStatus.paused.rawValue,
                status != MeetingStatus.cancelled.rawValue
            {
                await kick(meetingID)
                kicked = true
            }
            logger.notice(
                "capture sweep: meeting \(meetingID) tracks=\(outcome.encodedTracks.map(\.rawValue).joined(separator: ",")) kicked=\(kicked)")
            results.append(
                SweepResult(meetingID: meetingID, kicked: kicked, note: outcome.recoveryNote))
        }
        return results
    }

    // MARK: - G11 durable-grace launch recovery

    /// One `recording` row that died mid-grace (the interrupted-flip exemption
    /// kept it from being flipped to `failed`). The launch recovery decides per
    /// row: deadline past → clear the column + process now; future → re-enter
    /// grace.
    public struct DurableGraceRow: Sendable, Equatable {
        public let meetingID: MeetingID
        public let code: String?
        public let title: String
        public let graceUntilMs: Int64
    }

    /// G11 §3 launch recovery. A `recording` row with a non-nil `grace_until_ms`
    /// at launch means "app died during grace" — performAutoStop completed
    /// (parts encoded) before the grace was written, so the row is cleanly
    /// stopped-and-encoded, NOT a crashed live session (the DB-open
    /// interrupted-flip exempted it).
    ///
    /// For each such row, by its deadline against `now`:
    /// - deadline PAST → clear the column and `kick` processing (the grace
    ///   lapsed while the app was down);
    /// - deadline FUTURE → leave the column and hand the row to `reenterGrace`,
    ///   which re-arms the in-memory timer + suppression-equivalent state on the
    ///   tracker (the meeting can still be rejoined for the remaining window).
    ///
    /// Runs AFTER the orphan-CAF sweep and redispatch (those skip `recording`
    /// rows, so an exempted in-grace row is untouched by them) and ON the same
    /// launch path.
    @discardableResult
    public static func recoverDurableGrace(
        database: BlaiseDatabase,
        now: Date = Date(),
        kick: @escaping @Sendable (MeetingID) async -> Void,
        reenterGrace: @escaping @Sendable (DurableGraceRow) async -> Void
    ) async -> [DurableGraceRow] {
        let rows =
            (try? await database.pool.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, meeting_code, title, grace_until_ms FROM meeting
                        WHERE status = ? AND grace_until_ms IS NOT NULL ORDER BY id
                        """,
                    arguments: [MeetingStatus.recording.rawValue])
            }) ?? []
        var recovered: [DurableGraceRow] = []
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        for row in rows {
            let grace = DurableGraceRow(
                meetingID: row["id"], code: row["meeting_code"], title: row["title"],
                graceUntilMs: row["grace_until_ms"])
            // A code-less grace can never be rejoined by signal (no correlation
            // key), so a future deadline is moot — process it like a lapsed one.
            if grace.graceUntilMs <= nowMs || grace.code == nil {
                // Deadline lapsed (or un-rejoinable): clear the column, then
                // dispatch processing (clear-before-action, matching the live
                // expiry exit).
                try? await database.pool.write { db in
                    try db.execute(
                        sql: "UPDATE meeting SET grace_until_ms = NULL WHERE id = ?",
                        arguments: [grace.meetingID])
                }
                await kick(grace.meetingID)
                logger.notice("durable grace recovery: \(grace.meetingID) deadline past — processed")
            } else {
                // Window still open: re-enter grace (timer + state) on the
                // tracker. The column stays set until the re-armed grace exits.
                await reenterGrace(grace)
                logger.notice("durable grace recovery: \(grace.meetingID) re-entered grace")
            }
            recovered.append(grace)
        }
        return recovered
    }

    // MARK: - Launch re-dispatch for interrupted meetings with retained audio

    /// Quit-during-recording (and any crash between the stop-encode and its
    /// pipeline run) leaves the meeting `failed`/"interrupted" via the DB
    /// startup sweep — with its retained audio fully on disk and no CAF for
    /// the orphan sweep to key on. Auto-kick those at launch (no
    /// babysitting). `excluding` skips meetings the CAF sweep just kicked.
    @discardableResult
    public static func redispatchInterrupted(
        database: BlaiseDatabase,
        excluding: Set<MeetingID> = [],
        kick: @escaping @Sendable (MeetingID) async -> Void
    ) async -> [MeetingID] {
        let fm = FileManager.default
        let paths = database.paths
        let rows =
            (try? await database.pool.read { db in
                try String.fetchAll(
                    db,
                    sql: "SELECT id FROM meeting WHERE status = ? AND last_processing_error = 'interrupted' ORDER BY id",
                    arguments: [MeetingStatus.failed.rawValue])
            }) ?? []
        var kicked: [MeetingID] = []
        for meetingID in rows where !excluding.contains(meetingID) {
            let hasAudio =
                fm.fileExists(atPath: paths.audioURL(meetingID).path)
                || fm.fileExists(atPath: paths.audioMicURL(meetingID).path)
            guard hasAudio else { continue }
            await kick(meetingID)
            kicked.append(meetingID)
            logger.notice("interrupted meeting \(meetingID) has retained audio — re-dispatched")
        }
        return kicked
    }
}
