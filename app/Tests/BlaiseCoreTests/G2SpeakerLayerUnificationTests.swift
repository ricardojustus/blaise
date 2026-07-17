import Foundation
import GRDB
import Testing
@testable import BlaiseCore

// G2 §5 speaker-layer unification (NH-D) / AC8: a confirmed NOTES correction
// whose ORIGINAL surface fold-equals the CURRENT FULL display name of a
// resolved speaker ALSO upserts the §4 rename row(s) and re-applies them to the
// transcript + exported transcript JSON in the SAME re-mint — so the payload's
// transcript speaker names and its notes can never disagree about a person the
// user just corrected.

@Suite(.serialized) struct G2SpeakerLayerUnificationTests {
    private func renames(_ h: PipelineHarness, _ id: MeetingID) async throws -> [SpeakerRename] {
        try await h.database.pool.read { try SpeakerRenameStore.all($0, meetingID: id) }
    }

    /// The JSON of the most recently enqueued payload for a meeting.
    private func latestPayload(_ h: PipelineHarness, _ id: MeetingID) async throws -> [String: Any] {
        let path = try await h.database.pool.read { db in
            try String.fetchOne(
                db,
                sql:
                    "SELECT payload_path FROM handoff_queue WHERE meeting_id = ? ORDER BY created_seq DESC LIMIT 1",
                arguments: [id])
        }
        let url = h.database.rootURL.appendingPathComponent(try #require(path))
        return try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    // MARK: - AC8 positive: label + transcript + JSON + notes + payload in one re-mint

    @Test func notesCorrectionMatchingAFullNameUpdatesTheSpeakerLayer() async throws {
        let harness = try await makePipelineHarness()
        // Name S1 "Fábio" (transcript-verbatim → passes validation); the notes
        // owner is "Fábio" too. Both layers agree on "Fábio" going in.
        harness.notesPrimary.state.withLock { state in
            state.mapping = [
                SpeakerNameProposal(
                    label: "S1", name: "Fábio", confidence: .high,
                    evidence: "O Fábio vai mandar o contrato.")
            ]
        }
        let meeting = try await harness.importTestMeeting()
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        #expect(
            (try await harness.segments(meeting.id))
                .filter { $0.speakerLabel == "S1" }.allSatisfy { $0.speakerName == "Fábio" })

        // Correct the notes name "Fábio" → "Fábio Rosso": fold-equals S1's full
        // display name, so NH-D fires.
        let count = try await harness.pipeline.correctNameInNotes(
            meetingID: meeting.id, original: "Fábio", replacement: "Fábio Rosso",
            allOccurrences: true)
        #expect(count > 0)

        // Speaker layer: rename row + transcript rows updated.
        #expect((try await renames(harness, meeting.id))
            .contains { $0.speakerLabel == "S1" && $0.name == "Fábio Rosso" && !$0.stale })
        let segs = try await harness.segments(meeting.id)
        #expect(segs.filter { $0.speakerLabel == "S1" }.allSatisfy { $0.speakerName == "Fábio Rosso" })

        // Exported transcript JSON re-written with the corrected name.
        let transcriptJSON = try String(
            contentsOf: harness.database.paths.transcriptURL(meeting.id), encoding: .utf8)
        #expect(transcriptJSON.contains("Fábio Rosso"))

        // Notes owner corrected.
        let notes = try #require(
            try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id))
        #expect(notes.structured.actionItems.first?.owner == "Fábio Rosso")

        // The payload's transcript names == its notes names (the invariant NH-D
        // exists for): the corrected name is in BOTH, and the bare old name is
        // gone from the transcript speakers.
        let payload = try await latestPayload(harness, meeting.id)
        let transcript = try #require(payload["transcript"] as? [[String: Any]])
        let speakerNames = transcript.compactMap {
            ($0["speaker"] as? [String: Any])?["name"] as? String
        }
        let structured = try #require(payload["notes_structured"] as? [String: Any])
        let owners = (structured["action_items"] as? [[String: Any]] ?? [])
            .compactMap { $0["owner"] as? String }
        #expect(speakerNames.contains("Fábio Rosso"))
        #expect(owners.contains("Fábio Rosso"))
        #expect(!speakerNames.contains("Fábio"), "no bare pre-correction name lingers")
    }

    // MARK: - AC8 negative: a prose-only correction leaves the transcript byte-identical

    @Test func proseOnlyCorrectionLeavesTheTranscriptByteIdentical() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        _ = try await harness.pipeline.process(meetingID: meeting.id)

        let before = try Data(contentsOf: harness.database.paths.transcriptURL(meeting.id))
        // "contrato" is a prose word (decisions/detailed_notes), not any
        // speaker's name → NH-D does not fire.
        let count = try await harness.pipeline.correctNameInNotes(
            meetingID: meeting.id, original: "contrato", replacement: "acordo",
            allOccurrences: true)
        #expect(count > 0)
        let after = try Data(contentsOf: harness.database.paths.transcriptURL(meeting.id))
        #expect(after == before, "no label matched → the transcript JSON is untouched")
        #expect((try await renames(harness, meeting.id)).isEmpty)
    }

    // MARK: - AC8 negative: a bare-surname correction never fires against a full-name label

    @Test func bareSurnameNeverFiresAgainstAFullNameLabel() async throws {
        let harness = try await makePipelineHarness()
        // The notes summary carries a bare surname "Rosso" (prose).
        harness.notesPrimary.state.withLock { $0.summary = "Rosso enviou o material." }
        let meeting = try await harness.importTestMeeting()
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        // Give S1 the FULL name "Dana Rosso" via a user rename.
        _ = try await harness.pipeline.renameSpeaker(
            meetingID: meeting.id, speakerLabel: "S1", to: "Dana Rosso")

        // Correct the bare "Rosso" in the notes prose. fold("Rosso") ≠
        // fold("Dana Rosso") → NH-D must NOT touch the S1 label.
        let count = try await harness.pipeline.correctNameInNotes(
            meetingID: meeting.id, original: "Rosso", replacement: "Rosseau",
            allOccurrences: true)
        #expect(count > 0)

        let segs = try await harness.segments(meeting.id)
        #expect(
            segs.filter { $0.speakerLabel == "S1" }.allSatisfy { $0.speakerName == "Dana Rosso" },
            "the full-name label is untouched by a bare-surname prose correction")
        let rows = try await renames(harness, meeting.id)
        #expect(rows.first { $0.speakerLabel == "S1" }?.name == "Dana Rosso")
    }
}
