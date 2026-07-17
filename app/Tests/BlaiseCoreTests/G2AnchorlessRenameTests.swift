import Foundation
import GRDB
import Testing
@testable import BlaiseCore

// G2 §4 NH-E / AC9: the reserved `unattributed` label is label-literal — rename
// rows on it are written un-staled with no anchor, applied by direct label match
// to every unattributed segment, and exempt from anchor derivation, fallback
// re-mapping, and the stale lifecycle (a legacy stale row heals at apply time
// with no write). The `user` mic-track label stays non-renameable.

@Suite(.serialized) struct G2AnchorlessRenameTests {
    private func renames(_ db: BlaiseDatabase, _ id: MeetingID) async throws -> [SpeakerRename] {
        try await db.pool.read { try SpeakerRenameStore.all($0, meetingID: id) }
    }

    // MARK: - AC9 leg 1: immediate end-to-end apply on a ready meeting + re-mint

    @Test func unattributedRenameAppliesImmediatelyOnAReadyMeeting() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        try await harness.pipeline.process(meetingID: meeting.id)
        let prov = try #require((try await harness.meeting(meeting.id))?.asrProvenance)
        // Persist a transcript that carries an `unattributed` segment (diarization
        // did not cover it) alongside a normal S0 segment.
        let segs = [
            TranscriptSegment(
                meetingID: meeting.id, ord: 0, startSeconds: 0, endSeconds: 1,
                speakerLabel: "S0", speakerName: nil, text: "Olá"),
            TranscriptSegment(
                meetingID: meeting.id, ord: 1, startSeconds: 1, endSeconds: 2,
                speakerLabel: TranscriptSegment.unattributed, speakerName: nil, text: "sem dono"),
        ]
        _ = try await harness.database.persistTranscript(
            meetingID: meeting.id, segments: segs, asrProvenance: prov, dominantLanguage: "pt")
        let queueBefore = try await harness.queueRows(meeting.id)

        let didRename = try await harness.pipeline.renameSpeaker(
            meetingID: meeting.id, speakerLabel: TranscriptSegment.unattributed, to: "Convidada")
        #expect(didRename)

        // Row written un-staled with anchor 0.
        let row = try #require(
            (try await renames(harness.database, meeting.id))
                .first { $0.speakerLabel == TranscriptSegment.unattributed })
        #expect(!row.stale)
        #expect(row.anchorMs == 0)
        #expect(row.isAnchorless)
        // Every unattributed segment named; the S0 segment untouched.
        let after = try await harness.segments(meeting.id)
        #expect(
            after.filter { $0.speakerLabel == TranscriptSegment.unattributed }
                .allSatisfy { $0.speakerName == "Convidada" })
        #expect(after.filter { $0.speakerLabel == "S0" }.allSatisfy { $0.speakerName == nil })
        // Re-minted (a new payload enqueued).
        #expect(try await harness.queueRows(meeting.id) == queueBefore + 1)
    }

    // MARK: - AC9 leg 4: regeneration re-applies the row verbatim

    @Test func unattributedRenameSurvivesRegenerationVerbatim() async throws {
        // A far-apart ASR segment (5–6 s) with a diarization that covers only
        // 0–0.95 s makes the merger emit an `unattributed` segment on EVERY run.
        let harness = try await makePipelineHarness()
        harness.asr.state.withLock {
            $0.segments = [
                ASRSegment(
                    startSeconds: 0.0, endSeconds: 0.9, text: "Olá",
                    words: [ASRWord(word: "Olá", startSeconds: 0.0, endSeconds: 0.9)]),
                ASRSegment(
                    startSeconds: 5.0, endSeconds: 6.0, text: "sozinho",
                    words: [ASRWord(word: "sozinho", startSeconds: 5.0, endSeconds: 6.0)]),
            ]
        }
        harness.diarizer.state.withLock {
            $0.output = DiarizationOutput(
                segments: [DiarizedSegment(speakerLabel: "S0", startSeconds: 0.0, endSeconds: 0.95)],
                speakerCount: 1)
        }
        let meeting = try await harness.importTestMeeting()
        try await harness.pipeline.process(meetingID: meeting.id)
        // Sanity: the merge produced an unattributed segment.
        #expect(
            (try await harness.segments(meeting.id))
                .contains { $0.speakerLabel == TranscriptSegment.unattributed })

        _ = try await harness.pipeline.renameSpeaker(
            meetingID: meeting.id, speakerLabel: TranscriptSegment.unattributed, to: "Convidada")
        #expect(
            (try await harness.segments(meeting.id))
                .filter { $0.speakerLabel == TranscriptSegment.unattributed }
                .allSatisfy { $0.speakerName == "Convidada" })

        // Regenerate → the row re-applies verbatim (still non-stale, still named).
        try await harness.pipeline.regenerate(meetingID: meeting.id)
        let afterRegen = try await harness.segments(meeting.id)
        #expect(
            afterRegen.filter { $0.speakerLabel == TranscriptSegment.unattributed }
                .allSatisfy { $0.speakerName == "Convidada" },
            "the unattributed rename re-applies on regeneration")
        #expect(
            (try await renames(harness.database, meeting.id))
                .first { $0.speakerLabel == TranscriptSegment.unattributed }?.stale == false)
    }

    // MARK: - AC9 leg 2: a legacy stale unattributed row applies with no write

    @Test func legacyStaleUnattributedRowAppliesAtReadTimeWithNoWrite() async throws {
        // Simulate a row written before NH-E: stale=1 on the reserved label. It
        // must still apply (read-time semantics) — and it stays stale in the DB
        // (no heal-write), while the UI badge is suppressed (isAnchorless).
        let database = try makeDatabase()
        let meeting = makeMeeting(title: "NH-E legacy")
        try await MeetingRepository(database: database).create(meeting)
        let meetingID = meeting.id
        try await database.pool.write { db in
            try SpeakerRename(
                meetingID: meetingID, speakerLabel: TranscriptSegment.unattributed,
                anchorMs: 0, stale: true, name: "Convidada", createdAt: msDate()
            ).save(db)
        }
        let rows = try await renames(database, meetingID)
        let segments = [
            TranscriptSegment(
                meetingID: meetingID, ord: 0, startSeconds: 0, endSeconds: 1,
                speakerLabel: TranscriptSegment.unattributed, speakerName: nil, text: "x")
        ]
        let applied = SpeakerRenameStore.applyRenames(rows, to: segments)
        #expect(applied.allSatisfy { $0.speakerName == "Convidada" }, "legacy stale row still applies")
        // Read-time only: the stored row is unchanged (still stale, no write).
        #expect((try await renames(database, meetingID)).first?.stale == true)
        #expect(rows.first?.isAnchorless == true, "isAnchorless drives the UI to suppress the badge")
    }

    // MARK: - AC9 leg 3: fallback re-map leaves unattributed rows untouched

    @Test func fallbackRemapLeavesUnattributedUntouchedWhileReKeyingSRows() async throws {
        let database = try makeDatabase()
        let meeting = makeMeeting(title: "NH-E remap")
        try await MeetingRepository(database: database).create(meeting)
        let meetingID = meeting.id
        let orig = DiarizationOutput(
            segments: [DiarizedSegment(speakerLabel: "S0", startSeconds: 0, endSeconds: 1)],
            speakerCount: 1)
        try await database.pool.write { db in
            try SpeakerRenameStore.upsert(
                db, meetingID: meetingID, speakerLabel: "S0", name: "Alice",
                diarization: orig, now: msDate())
            try SpeakerRenameStore.upsert(
                db, meetingID: meetingID, speakerLabel: TranscriptSegment.unattributed,
                name: "Convidada", diarization: orig, now: msDate())
        }
        // Fresh clustering: the S0 speaker is now labeled S1 (covers the S0 anchor).
        let fresh = DiarizationOutput(
            segments: [DiarizedSegment(speakerLabel: "S1", startSeconds: 0, endSeconds: 1)],
            speakerCount: 1)
        try await database.pool.write { db in
            try SpeakerRenameStore.remapForFreshDiarization(
                db, meetingID: meetingID, fresh: fresh, now: msDate())
        }
        let rows = try await renames(database, meetingID)
        // The S row re-keyed S0 → S1.
        #expect(rows.first { $0.speakerLabel == "S1" }?.name == "Alice")
        #expect(!rows.contains { $0.speakerLabel == "S0" })
        // The unattributed row is completely untouched.
        let unattr = try #require(rows.first { $0.speakerLabel == TranscriptSegment.unattributed })
        #expect(unattr.name == "Convidada" && !unattr.stale && unattr.anchorMs == 0)
    }

    // MARK: - AC9 leg 5: `user` stays non-renameable; `unattributed` is renameable

    @Test func userLabelIsNotAnchorlessAndDistinctFromUnattributed() {
        // The UI renameable predicate excludes ONLY `user` (unchanged). NH-E's
        // anchorless rule covers `unattributed`, never `user`.
        #expect(TranscriptSegment.unattributed != TranscriptSegment.userLabel)
        #expect(SpeakerRename.isAnchorless(TranscriptSegment.unattributed))
        #expect(!SpeakerRename.isAnchorless(TranscriptSegment.userLabel))
        #expect(!SpeakerRename.isAnchorless("S0"))
    }
}
