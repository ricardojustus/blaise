import Foundation
import GRDB
import Testing
@testable import BlaiseCore

// G2 §4 store-level pins: interior-point anchor, artifact-present direct apply,
// the fresh-diarize fallback re-map + re-key, and both stale paths.

private func diar(_ segs: [(String, Double, Double)]) -> DiarizationOutput {
    DiarizationOutput(
        segments: segs.map { DiarizedSegment(speakerLabel: $0.0, startSeconds: $0.1, endSeconds: $0.2) },
        speakerCount: Set(segs.map(\.0)).count)
}

@Suite struct SpeakerRenameStoreTests {
    @Test func anchorIsMidpointOfLongestSegment() {
        // S0 has two segments; the longer one is 10..20 (mid 15s = 15000ms).
        let d = diar([("S0", 0, 2), ("S1", 2, 4), ("S0", 10, 20)])
        #expect(SpeakerRenameStore.anchorMs(for: "S0", in: d) == 15_000)
    }

    @Test func upsertAndDirectApply() async throws {
        let db = try makeDatabase()
        let meeting = makeMeeting()
        try await MeetingRepository(database: db).create(meeting)
        let d = diar([("S0", 0, 10), ("S1", 10, 20)])
        try await db.pool.write { conn in
            try SpeakerRenameStore.upsert(
                conn, meetingID: meeting.id, speakerLabel: "S0", name: "Alice",
                diarization: d, now: msDate())
        }
        let rows = try await db.pool.read { try SpeakerRenameStore.all($0, meetingID: meeting.id) }
        #expect(rows.count == 1)
        #expect(rows[0].name == "Alice")
        #expect(rows[0].anchorMs == 5_000) // midpoint of 0..10
        #expect(rows[0].stale == false)

        // Direct apply by label.
        let segments = [
            TranscriptSegment(meetingID: meeting.id, ord: 0, startSeconds: 0, endSeconds: 5, speakerLabel: "S0", text: "a"),
            TranscriptSegment(meetingID: meeting.id, ord: 1, startSeconds: 11, endSeconds: 15, speakerLabel: "S1", text: "b"),
        ]
        let applied = SpeakerRenameStore.applyRenames(rows, to: segments)
        #expect(applied[0].speakerName == "Alice")
        #expect(applied[1].speakerName == nil)
    }

    @Test func renameOverridesExistingName() {
        let row = SpeakerRename(
            meetingID: "M", speakerLabel: "S0", anchorMs: 5_000, name: "Alice", createdAt: msDate())
        let seg = TranscriptSegment(
            meetingID: "M", ord: 0, startSeconds: 0, endSeconds: 1, speakerLabel: "S0",
            speakerName: "Wrong LLM Name", text: "x")
        let applied = SpeakerRenameStore.applyRenames([row], to: [seg])
        #expect(applied[0].speakerName == "Alice")
    }

    @Test func fallbackReMapReKeys() async throws {
        let db = try makeDatabase()
        let meeting = makeMeeting()
        try await MeetingRepository(database: db).create(meeting)
        // Old clustering: S0 = 0..20 (anchor 10000ms).
        let old = diar([("S0", 0, 20), ("S1", 20, 40)])
        try await db.pool.write { conn in
            try SpeakerRenameStore.upsert(
                conn, meetingID: meeting.id, speakerLabel: "S0", name: "Alice",
                diarization: old, now: msDate())
        }
        // Fresh clustering: the same speaker is now labeled S2, covering 0..18
        // (contains 10s); a different speaker is S0.
        let fresh = diar([("S0", 19, 40), ("S2", 0, 18)])
        try await db.pool.write { conn in
            try SpeakerRenameStore.remapForFreshDiarization(
                conn, meetingID: meeting.id, fresh: fresh, now: msDate())
        }
        let rows = try await db.pool.read { try SpeakerRenameStore.all($0, meetingID: meeting.id) }
        #expect(rows.count == 1)
        #expect(rows[0].speakerLabel == "S2", "row re-keyed to the cluster containing the anchor")
        #expect(rows[0].stale == false)
        #expect(rows[0].anchorMs == 9_000, "anchor recomputed from the new cluster midpoint (0..18)")
    }

    @Test func fallbackStaleWhenAnchorInGap() async throws {
        let db = try makeDatabase()
        let meeting = makeMeeting()
        try await MeetingRepository(database: db).create(meeting)
        let old = diar([("S0", 0, 20)]) // anchor 10000ms
        try await db.pool.write { conn in
            try SpeakerRenameStore.upsert(
                conn, meetingID: meeting.id, speakerLabel: "S0", name: "Alice",
                diarization: old, now: msDate())
        }
        // Fresh clustering: no segment covers 10s (a silence gap there).
        let fresh = diar([("S0", 0, 5), ("S1", 15, 30)])
        try await db.pool.write { conn in
            try SpeakerRenameStore.remapForFreshDiarization(
                conn, meetingID: meeting.id, fresh: fresh, now: msDate())
        }
        let rows = try await db.pool.read { try SpeakerRenameStore.all($0, meetingID: meeting.id) }
        #expect(rows.count == 1)
        #expect(rows[0].stale == true, "no containing cluster → stale, not applied")
        // A stale row does not apply.
        let seg = TranscriptSegment(
            meetingID: meeting.id, ord: 0, startSeconds: 0, endSeconds: 1, speakerLabel: "S0", text: "x")
        #expect(SpeakerRenameStore.applyRenames(rows, to: [seg])[0].speakerName == nil)
    }

    @Test func fallbackStaleWhenTwoRowsMapToOneCluster() async throws {
        let db = try makeDatabase()
        let meeting = makeMeeting()
        try await MeetingRepository(database: db).create(meeting)
        // Two renames anchored in two old clusters.
        let old = diar([("S0", 0, 10), ("S1", 20, 30)]) // anchors 5000, 25000
        try await db.pool.write { conn in
            try SpeakerRenameStore.upsert(
                conn, meetingID: meeting.id, speakerLabel: "S0", name: "Alice",
                diarization: old, now: msDate())
            try SpeakerRenameStore.upsert(
                conn, meetingID: meeting.id, speakerLabel: "S1", name: "Bob",
                diarization: old, now: msDate())
        }
        // Fresh clustering MERGED them into one cluster S0 covering both anchors.
        let fresh = diar([("S0", 0, 30)])
        try await db.pool.write { conn in
            try SpeakerRenameStore.remapForFreshDiarization(
                conn, meetingID: meeting.id, fresh: fresh, now: msDate())
        }
        let rows = try await db.pool.read { try SpeakerRenameStore.all($0, meetingID: meeting.id) }
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.stale }, "both rows stale on an undecidable merge")
    }

    // H-5: a re-keyed row whose target label collides with a sibling staying
    // stale at that same key must NOT silently overwrite it — BOTH rows are
    // preserved (stale, never destroyed). Probe P6: Alice(S0) + Bob(S1); fresh
    // clustering maps Bob's anchor to "S0" while Alice's anchor falls in a gap
    // (stale, keeps "S0"). Pre-fix the table ended with ONE row (Bob@S0),
    // Alice's rename + her re-confirmation state gone without trace.
    @Test func reKeyOntoStaleKeyPreservesBothRows_H5() async throws {
        let db = try makeDatabase()
        let meeting = makeMeeting()
        try await MeetingRepository(database: db).create(meeting)
        // Old: S0=0..10 (anchor 5000), S1=20..30 (anchor 25000).
        let old = diar([("S0", 0, 10), ("S1", 20, 30)])
        try await db.pool.write { conn in
            try SpeakerRenameStore.upsert(
                conn, meetingID: meeting.id, speakerLabel: "S0", name: "Alice",
                diarization: old, now: msDate())
            try SpeakerRenameStore.upsert(
                conn, meetingID: meeting.id, speakerLabel: "S1", name: "Bob",
                diarization: old, now: msDate())
        }
        // Fresh: a cluster "S0" covers 20..30 (contains Bob's 25000 anchor); no
        // cluster covers Alice's 5000 anchor (a gap there) → Alice goes stale,
        // keeping key "S0". Bob would re-key to "S0" — a destructive collision.
        let fresh = diar([("S0", 20, 30), ("S2", 40, 50)])
        try await db.pool.write { conn in
            try SpeakerRenameStore.remapForFreshDiarization(
                conn, meetingID: meeting.id, fresh: fresh, now: msDate())
        }
        let rows = try await db.pool.read { try SpeakerRenameStore.all($0, meetingID: meeting.id) }
        // BOTH renames survive — neither silently destroyed.
        #expect(rows.count == 2, "both rows preserved on a PK collision")
        #expect(Set(rows.map(\.name)) == ["Alice", "Bob"])
        // Both ended stale (Alice: gap; Bob: demoted off the colliding key).
        #expect(rows.allSatisfy { $0.stale }, "colliding re-key demoted to stale, not destroyed")
        #expect(Set(rows.map(\.speakerLabel)) == ["S0", "S1"], "stale rows keep original keys")
    }

    // H-10: the H-5 harm one level deeper. A row demoted to FORCED stale keeps
    // its original key — that key must ALSO be protected from a sibling's re-key,
    // computed to a FIXED POINT. Auditor's probe (Alice destroyed): a pre-existing
    // stale row Eve at "S5"; Alice(S0) re-maps to "S5" → forced stale at "S0";
    // Bob(S1) re-maps to "S0". Pre-fix `staleKeptKeys` was frozen before the Eve
    // collision demoted Alice, so "S0" was unprotected and Bob's re-key landed on
    // it — Alice's rename + re-confirmation state silently destroyed (table ended
    // ["S0 Bob false", "S5 Eve true"]). Fixed: Bob is also demoted, all three
    // survive stale at their original keys.
    @Test func forcedStaleKeyProtectedToFixedPoint_H10() async throws {
        let db = try makeDatabase()
        let meeting = makeMeeting()
        try await MeetingRepository(database: db).create(meeting)
        // Old clusters for the live rows: Alice@S0 (0..10, anchor 5000),
        // Bob@S1 (20..30, anchor 25000). Eve is already a stale row at "S5".
        let old = diar([("S0", 0, 10), ("S1", 20, 30)])
        try await db.pool.write { conn in
            try SpeakerRenameStore.upsert(
                conn, meetingID: meeting.id, speakerLabel: "S0", name: "Alice",
                diarization: old, now: msDate())
            try SpeakerRenameStore.upsert(
                conn, meetingID: meeting.id, speakerLabel: "S1", name: "Bob",
                diarization: old, now: msDate())
            // Eve: a pre-existing stale row holding key "S5".
            try SpeakerRename(
                meetingID: meeting.id, speakerLabel: "S5", anchorMs: 0, stale: true,
                name: "Eve", createdAt: msDate()).save(conn)
        }
        // Fresh clustering: a cluster "S5" covers Alice's 5000 anchor (so Alice
        // would re-key to "S5" — but Eve holds it stale → Alice forced stale at
        // "S0"); a cluster "S0" covers Bob's 25000 anchor (Bob would re-key to
        // "S0" — but the now-demoted Alice holds it → Bob must ALSO be demoted).
        let fresh = diar([("S5", 0, 10), ("S0", 20, 30)])
        try await db.pool.write { conn in
            try SpeakerRenameStore.remapForFreshDiarization(
                conn, meetingID: meeting.id, fresh: fresh, now: msDate())
        }
        let rows = try await db.pool.read { try SpeakerRenameStore.all($0, meetingID: meeting.id) }
        // All three survive — Alice NOT destroyed by Bob's re-key.
        #expect(rows.count == 3, "all three rows preserved (Alice not overwritten)")
        #expect(Set(rows.map(\.name)) == ["Alice", "Bob", "Eve"])
        #expect(rows.allSatisfy { $0.stale }, "every conflicted row demoted to stale")
        // Each keeps its ORIGINAL key — no row silently overwritten.
        let byName = Dictionary(uniqueKeysWithValues: rows.map { ($0.name, $0.speakerLabel) })
        #expect(byName["Alice"] == "S0", "Alice's forced-stale key preserved against Bob's re-key")
        #expect(byName["Bob"] == "S1")
        #expect(byName["Eve"] == "S5")
    }

    // H-6: a rename made when no diarization is available for the label must be
    // written stale (NOT anchor 0 / not-stale), so the next fallback cannot
    // confidently re-map it onto whoever speaks at t=0.
    @Test func renameWithoutDiarizationIsStale_H6() async throws {
        let db = try makeDatabase()
        let meeting = makeMeeting()
        try await MeetingRepository(database: db).create(meeting)
        let empty = DiarizationOutput(segments: [], speakerCount: 0)
        try await db.pool.write { conn in
            try SpeakerRenameStore.upsert(
                conn, meetingID: meeting.id, speakerLabel: "S3", name: "Alice",
                diarization: empty, now: msDate())
        }
        let rows = try await db.pool.read { try SpeakerRenameStore.all($0, meetingID: meeting.id) }
        #expect(rows.count == 1)
        #expect(rows[0].stale == true, "no anchor derivable → stale, not anchor-0")
        // And the fallback does NOT re-map a stale row onto the t=0 cluster.
        let fresh = diar([("S0", 0, 10), ("S1", 10, 20)])
        try await db.pool.write { conn in
            try SpeakerRenameStore.remapForFreshDiarization(
                conn, meetingID: meeting.id, fresh: fresh, now: msDate())
        }
        let after = try await db.pool.read { try SpeakerRenameStore.all($0, meetingID: meeting.id) }
        #expect(after.first?.speakerLabel == "S3", "stale row not re-keyed onto t=0 cluster")
        #expect(after.first?.stale == true)
    }

    @Test func reconfirmClearsStale() async throws {
        let db = try makeDatabase()
        let meeting = makeMeeting()
        try await MeetingRepository(database: db).create(meeting)
        let old = diar([("S0", 0, 20)])
        try await db.pool.write { conn in
            try SpeakerRenameStore.upsert(
                conn, meetingID: meeting.id, speakerLabel: "S0", name: "Alice",
                diarization: old, now: msDate())
        }
        let fresh = diar([("S0", 0, 5), ("S1", 15, 30)]) // gap at 10s → stale
        try await db.pool.write { conn in
            try SpeakerRenameStore.remapForFreshDiarization(
                conn, meetingID: meeting.id, fresh: fresh, now: msDate())
        }
        // The user re-confirms against the fresh clustering (label S1 now).
        try await db.pool.write { conn in
            try SpeakerRenameStore.upsert(
                conn, meetingID: meeting.id, speakerLabel: "S1", name: "Alice",
                diarization: fresh, now: msDate())
        }
        let rows = try await db.pool.read { try SpeakerRenameStore.all($0, meetingID: meeting.id) }
        // The S1 row is fresh (stale=0); the old stale S0 row remains until the
        // next fallback (the user re-confirmed onto the correct cluster).
        let s1 = try #require(rows.first { $0.speakerLabel == "S1" })
        #expect(s1.stale == false)
    }
}
