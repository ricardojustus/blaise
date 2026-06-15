import Foundation
import GRDB
import Testing
@testable import BlaiseCore

// G2 AC3 (UI/model, pipeline side): rename row round-trip + regenerate
// persistence with diarization REUSE asserted; the fresh-diarize fallback
// re-map + re-key persisting across TWO consecutive regenerates.

@Suite(.serialized) struct SpeakerRenamePipelineTests {
    private func renames(_ db: BlaiseDatabase, _ id: MeetingID) async throws -> [SpeakerRename] {
        try await db.pool.read { try SpeakerRenameStore.all($0, meetingID: id) }
    }

    private func segments(_ h: PipelineHarness, _ id: MeetingID) async throws -> [TranscriptSegment] {
        try await h.segments(id)
    }

    @Test func renameRoundTripAndRegeneratePersistenceWithDiarizationReuse() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        try await harness.pipeline.process(meetingID: meeting.id)

        // The default mock diarization labels are S0/S1. Rename S0.
        let didRename = try await harness.pipeline.renameSpeaker(
            meetingID: meeting.id, speakerLabel: "S0", to: "Alice")
        #expect(didRename)

        // Round-trip: a row exists, and segments labeled S0 now carry "Alice".
        let rows = try await renames(harness.database, meeting.id)
        #expect(rows.contains { $0.speakerLabel == "S0" && $0.name == "Alice" && !$0.stale })
        let segs = try await segments(harness, meeting.id)
        #expect(segs.filter { $0.speakerLabel == "S0" }.allSatisfy { $0.speakerName == "Alice" })

        // Regenerate REUSES the persisted diarization (the diarizer is NOT
        // called again) and the rename still applies by label.
        let diarizeCallsBefore = harness.diarizer.state.withLock { $0.attendeeCounts.count }
        try await harness.pipeline.regenerate(meetingID: meeting.id)
        let diarizeCallsAfter = harness.diarizer.state.withLock { $0.attendeeCounts.count }
        #expect(diarizeCallsAfter == diarizeCallsBefore, "regenerate must reuse persisted diarization")

        let afterSegs = try await segments(harness, meeting.id)
        #expect(afterSegs.filter { $0.speakerLabel == "S0" }.allSatisfy { $0.speakerName == "Alice" })
    }

    @Test func freshDiarizeFallbackReKeysAcrossTwoConsecutiveRegenerates() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        try await harness.pipeline.process(meetingID: meeting.id)

        // Rename S0 against the original clustering (S0 = 0..0.95).
        _ = try await harness.pipeline.renameSpeaker(
            meetingID: meeting.id, speakerLabel: "S0", to: "Alice")

        // Force the MISSING-ARTIFACT fallback: delete the persisted diarization
        // file, and make the diarizer return a clustering where the SAME
        // speaker is now labeled S1 (covering the original S0 anchor ~0.475s).
        try FileManager.default.removeItem(at: harness.database.paths.diarizationURL(meeting.id))
        harness.diarizer.state.withLock {
            $0.output = DiarizationOutput(
                segments: [
                    DiarizedSegment(speakerLabel: "S1", startSeconds: 0.0, endSeconds: 0.95),
                    DiarizedSegment(speakerLabel: "S0", startSeconds: 0.98, endSeconds: 1.9),
                ],
                speakerCount: 2)
        }

        // Run N: regenerate falls back, re-maps the rename by anchor to S1, and
        // re-keys it (committing BEFORE the fresh artifact persist).
        try await harness.pipeline.regenerate(meetingID: meeting.id)
        let afterN = try await renames(harness.database, meeting.id)
        let row = try #require(afterN.first)
        #expect(row.speakerLabel == "S1", "row re-keyed to the fresh cluster containing the anchor")
        #expect(!row.stale)

        // The fresh artifact was persisted (the run wrote it forward).
        #expect(FileManager.default.fileExists(atPath: harness.database.paths.diarizationURL(meeting.id).path))

        // Run N+1: artifact present → reuse → direct apply by the NEW label. No
        // misattribution: the row says S1, the reused clustering's S1 is the
        // renamed speaker.
        try await harness.pipeline.regenerate(meetingID: meeting.id)
        let afterN1 = try await renames(harness.database, meeting.id)
        #expect(afterN1.first?.speakerLabel == "S1")
        #expect(afterN1.first?.stale == false)
        let segs = try await segments(harness, meeting.id)
        #expect(segs.filter { $0.speakerLabel == "S1" }.allSatisfy { $0.speakerName == "Alice" })
    }

    // M-1: if the re-key transaction THROWS on the fresh-diarize fallback, the
    // fresh diarization artifact must NOT be persisted — the next run falls back
    // again (one more safe fallback) rather than committing an artifact whose
    // labels the rename rows were never re-keyed to (a direct-apply against
    // stale keys). Pre-fix the remap error was swallowed (`try?`) and the
    // artifact persisted unconditionally. We force the throw by dropping the
    // speaker_rename table right before the fallback so the remap's read fails.
    @Test func reKeyFailureSkipsArtifactPersist_M1() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        try await harness.pipeline.process(meetingID: meeting.id)
        _ = try await harness.pipeline.renameSpeaker(
            meetingID: meeting.id, speakerLabel: "S0", to: "Alice")

        // Force the missing-artifact fallback AND make the remap throw.
        try FileManager.default.removeItem(at: harness.database.paths.diarizationURL(meeting.id))
        harness.diarizer.state.withLock {
            $0.output = DiarizationOutput(
                segments: [DiarizedSegment(speakerLabel: "S1", startSeconds: 0.0, endSeconds: 1.9)],
                speakerCount: 1)
        }
        // Drop the table so SpeakerRenameStore.all (inside the remap) throws.
        try await harness.database.pool.write { db in
            try db.execute(sql: "DROP TABLE speaker_rename")
        }

        // The regenerate now throws (the remap error propagates). Whether it
        // throws or merely fails the notes step, the INVARIANT is: the fresh
        // diarization artifact was NOT persisted.
        _ = try? await harness.pipeline.regenerate(meetingID: meeting.id)
        #expect(
            !FileManager.default.fileExists(
                atPath: harness.database.paths.diarizationURL(meeting.id).path),
            "a failed re-key must NOT persist the fresh artifact (M-1 ordering)")
    }

    @Test func fallbackStalePathInPipeline() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        try await harness.pipeline.process(meetingID: meeting.id)
        _ = try await harness.pipeline.renameSpeaker(
            meetingID: meeting.id, speakerLabel: "S0", to: "Alice")

        // Fallback where the anchor (~0.475s) falls into a silence gap.
        try FileManager.default.removeItem(at: harness.database.paths.diarizationURL(meeting.id))
        harness.diarizer.state.withLock {
            $0.output = DiarizationOutput(
                segments: [
                    DiarizedSegment(speakerLabel: "S0", startSeconds: 1.0, endSeconds: 1.9),
                ],
                speakerCount: 1)
        }
        try await harness.pipeline.regenerate(meetingID: meeting.id)
        let rows = try await renames(harness.database, meeting.id)
        #expect(rows.first?.stale == true, "anchor in a gap → stale, not applied")
        // The label is not named by a stale row.
        let segs = try await segments(harness, meeting.id)
        #expect(segs.allSatisfy { $0.speakerName != "Alice" })
    }
}
