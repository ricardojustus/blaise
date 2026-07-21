import Foundation
import GRDB

/// G2 §4: one user-authored speaker rename per (meeting_id, speaker_label).
public struct SpeakerRename: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "speaker_rename"

    public var meetingID: MeetingID
    public var speakerLabel: String
    /// The MIDPOINT of the cluster's longest segment at write time (ms), an
    /// interior instant robust to boundary jitter (§4).
    public var anchorMs: Int64
    /// The R4-H1 lifecycle flag: a row the fresh-diarize fallback could not
    /// safely re-map. NOT applied; the label renders unnamed + re-confirmation.
    public var stale: Bool
    public var name: String
    public var createdAt: Date

    public init(
        meetingID: MeetingID, speakerLabel: String, anchorMs: Int64, stale: Bool = false,
        name: String, createdAt: Date
    ) {
        self.meetingID = meetingID
        self.speakerLabel = speakerLabel
        self.anchorMs = anchorMs
        self.stale = stale
        self.name = name
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case name, stale
        case meetingID = "meeting_id"
        case speakerLabel = "speaker_label"
        case anchorMs = "anchor_ms"
        case createdAt = "created_at"
    }
}

public enum SpeakerRenameStore {
    /// All rows for a meeting, by label.
    public static func all(_ db: Database, meetingID: MeetingID) throws -> [SpeakerRename] {
        try SpeakerRename
            .filter(Column("meeting_id") == meetingID)
            .order(Column("speaker_label"))
            .fetchAll(db)
    }

    /// The anchor for a label: the MIDPOINT (ms) of the LONGEST segment of the
    /// cluster carrying `speakerLabel` in `diarization`. Returns nil when the
    /// label has no segments.
    public static func anchorMs(
        for speakerLabel: String, in diarization: DiarizationOutput
    ) -> Int64? {
        let cluster = diarization.segments.filter { $0.speakerLabel == speakerLabel }
        guard let longest = cluster.max(by: {
            ($0.endSeconds - $0.startSeconds) < ($1.endSeconds - $1.startSeconds)
        }) else { return nil }
        let mid = (longest.startSeconds + longest.endSeconds) / 2.0
        return Int64((mid * 1000).rounded())
    }

    /// Upserts a rename: computes the interior-point anchor from the CURRENT
    /// diarization, clears any prior stale mark, and writes label+anchor+name.
    ///
    /// H-6: when no anchor can be derived (the diarization for this label is
    /// absent — e.g. a rename made on a meeting whose diarization artifact is
    /// missing), the row is written `stale = 1` with anchor 0 rather than a
    /// confident anchor-0. A stale row is NOT applied and is NEVER re-mapped by
    /// the fallback (so it can't be re-mapped onto whoever speaks at t=0); the
    /// label renders unnamed + "rename needs re-confirmation" until the user
    /// re-confirms against real diarization.
    public static func upsert(
        _ db: Database, meetingID: MeetingID, speakerLabel: String, name: String,
        diarization: DiarizationOutput, now: Date
    ) throws {
        let derived = anchorMs(for: speakerLabel, in: diarization)
        let row = SpeakerRename(
            meetingID: meetingID, speakerLabel: speakerLabel, anchorMs: derived ?? 0,
            stale: derived == nil, name: name, createdAt: now)
        try row.save(db)
    }

    public static func delete(_ db: Database, meetingID: MeetingID, speakerLabel: String) throws {
        _ = try SpeakerRename
            .filter(Column("meeting_id") == meetingID && Column("speaker_label") == speakerLabel)
            .deleteAll(db)
    }

    /// §4 fallback re-map. Given the FRESH diarization (the missing-artifact
    /// branch), re-key every non-stale rename row by its `anchor_ms` to the new
    /// cluster that CONTAINS that instant, recomputing the anchor from the new
    /// cluster. A row whose anchor falls in no cluster, OR two rows mapping to
    /// the SAME new cluster (undecidable merge) → `stale = 1`, NOT re-keyed.
    /// All within ONE transaction; the caller commits THIS before persisting
    /// the fresh diarization artifact (R4-H1 ordering rule).
    public static func remapForFreshDiarization(
        _ db: Database, meetingID: MeetingID, fresh: DiarizationOutput, now: Date
    ) throws {
        let allRows = try all(db, meetingID: meetingID)
        let rows = allRows.filter { !$0.stale }
        guard !rows.isEmpty else { return }
        // Pre-existing stale rows keep their original key untouched; a re-keyed
        // row must NOT land on one of them.
        let existingStaleKeys = Set(allRows.filter { $0.stale }.map(\.speakerLabel))

        // A row's label carries its track (C4 v5.6): `S<n>` = system
        // clusters, `M<n>` = room-mode mic clusters. The two tracks are
        // time-coextensive, so a bare instant is ambiguous across them —
        // candidates are scoped to the row's own namespace. Labels outside
        // both grammars (e.g. `unattributed`) keep the unscoped candidate
        // set, preserving the pre-room-mode re-key behavior.
        func labelNamespace(_ label: String) -> Character? {
            guard let first = label.first, first == "S" || first == "M",
                label.dropFirst().allSatisfy(\.isNumber), label.count > 1
            else { return nil }
            return first
        }

        // Which fresh cluster contains this row's anchor instant?
        func containingLabel(_ anchorMs: Int64, rowLabel: String) -> String? {
            let t = Double(anchorMs) / 1000.0
            let namespace = labelNamespace(rowLabel)
            let hits = Set(
                fresh.segments
                    .filter { namespace == nil || labelNamespace($0.speakerLabel) == namespace }
                    .filter { $0.startSeconds <= t && t <= $0.endSeconds }
                    .map(\.speakerLabel))
            // A single containing cluster only (overlapping segments of one
            // cluster are fine; two distinct clusters = ambiguous → no map).
            return hits.count == 1 ? hits.first : nil
        }

        var targets: [(row: SpeakerRename, newLabel: String?)] = []
        for row in rows {
            targets.append((row, containingLabel(row.anchorMs, rowLabel: row.speakerLabel)))
        }
        // Two rows mapping to the SAME new cluster → BOTH stale (R4-L4).
        var labelCounts: [String: Int] = [:]
        for t in targets { if let l = t.newLabel { labelCounts[l, default: 0] += 1 } }

        // The FINAL key each row will occupy: a successful re-map takes its
        // newLabel; an unmapped/merge-collision row stays stale at its ORIGINAL
        // key. H-5: a re-keyed row whose newLabel collides with another row's
        // final key (a sibling that stays stale at that key, or a pre-existing
        // stale row) must NOT silently overwrite it. Both rows are demoted to
        // stale at their original keys instead — never silently destroyed.
        func remapsSuccessfully(_ t: (row: SpeakerRename, newLabel: String?)) -> Bool {
            guard let l = t.newLabel else { return false }
            return labelCounts[l] == 1
        }
        // Keys that will be held by a row staying stale at its original key.
        var staleKeptKeys = existingStaleKeys
        for t in targets where !remapsSuccessfully(t) {
            staleKeptKeys.insert(t.row.speakerLabel)
        }
        // Demote any re-mapped row whose target key is held by a stale-kept key
        // (a destructive collision) to stale at its own original key. H-10: a
        // forced-stale demotion ITSELF keeps its original key, which can be the
        // target of yet another row's re-key — so iterate to a fixed point,
        // adding each demoted row's kept key to the protected set and rechecking,
        // until no further demotion is forced. Without this, a chain (Eve stale
        // at S5; Alice S0→S5 demoted to S0; Bob S1→S0) silently overwrites the
        // demoted Alice row at S0, destroying her rename + re-confirmation state.
        var forcedStale = Set<String>()
        var changed = true
        while changed {
            changed = false
            for t in targets where remapsSuccessfully(t) && !forcedStale.contains(t.row.speakerLabel) {
                if let l = t.newLabel, staleKeptKeys.contains(l) {
                    forcedStale.insert(t.row.speakerLabel)
                    // Its original key is now held by a stale row — protect it.
                    staleKeptKeys.insert(t.row.speakerLabel)
                    changed = true
                }
            }
        }

        // Delete the non-stale rows we are rewriting (pre-existing stale rows
        // are left in place — a re-key never lands on them, enforced above) and
        // rewrite each in its resolved state.
        try delete(db, meetingID: meetingID, allLabels: rows.map(\.speakerLabel))
        for (row, newLabel) in targets {
            let collides = forcedStale.contains(row.speakerLabel)
            if let newLabel, labelCounts[newLabel] == 1, !collides {
                // Successful re-map: re-key + recompute anchor from the new cluster.
                let newAnchor = anchorMs(for: newLabel, in: fresh) ?? row.anchorMs
                let rekeyed = SpeakerRename(
                    meetingID: meetingID, speakerLabel: newLabel, anchorMs: newAnchor,
                    stale: false, name: row.name, createdAt: now)
                try rekeyed.save(db)
            } else {
                // No containing cluster, merge collision, or a destructive PK
                // collision → stale (keep the original key so a re-confirmation
                // can find/rewrite it; the row is preserved, not destroyed).
                let staleRow = SpeakerRename(
                    meetingID: meetingID, speakerLabel: row.speakerLabel, anchorMs: row.anchorMs,
                    stale: true, name: row.name, createdAt: row.createdAt)
                try staleRow.save(db)
            }
        }
    }

    private static func delete(_ db: Database, meetingID: MeetingID, allLabels: [String]) throws {
        for label in allLabels {
            try delete(db, meetingID: meetingID, speakerLabel: label)
        }
    }

    /// Applies non-stale rename rows to segments by `speaker_label` (the
    /// artifact-present direct-apply path). Renames OVERRIDE existing names
    /// (a user rename outranks mechanical/LLM naming, §1).
    public static func applyRenames(
        _ renames: [SpeakerRename], to segments: [TranscriptSegment]
    ) -> [TranscriptSegment] {
        let byLabel = Dictionary(
            uniqueKeysWithValues: renames.filter { !$0.stale }.map { ($0.speakerLabel, $0.name) })
        guard !byLabel.isEmpty else { return segments }
        return segments.map { segment in
            guard let name = byLabel[segment.speakerLabel] else { return segment }
            var copy = segment
            copy.speakerName = name
            return copy
        }
    }
}
