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

    // MARK: - AC8: ONE effective replacement across the layers (store-resolved surface)

    /// The typed surface hits a correction-store row that resolves it to a
    /// DIFFERENT name. That single resolved value must drive the notes, the
    /// rename row, the transcript and the re-minted payload alike — applying it
    /// to the speaker layer only is the exact notes/transcript disagreement NH-D
    /// exists to kill.
    @Test func storeResolvedReplacementLandsInEveryLayer() async throws {
        let harness = try await makePipelineHarness()
        harness.notesPrimary.state.withLock { state in
            state.mapping = [
                SpeakerNameProposal(
                    label: "S1", name: "Fábio", confidence: .high,
                    evidence: "O Fábio vai mandar o contrato.")
            ]
        }
        let meeting = try await harness.importTestMeeting()
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        // `Marsa → Dana Marsh`: normalizeRename("Marsa") != "Marsa".
        _ = try await harness.pipeline.rememberCorrection(
            mishearedSurface: "Marsa", replacement: "Dana Marsh", sourceMeetingID: meeting.id)

        let count = try await harness.pipeline.correctNameInNotes(
            meetingID: meeting.id, original: "Fábio", replacement: "Marsa", allOccurrences: true)
        #expect(count > 0)

        let notes = try #require(
            try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id))
        #expect(notes.structured.actionItems.first?.owner == "Dana Marsh")
        #expect(!notes.markdown.contains("Marsa"), "the notes never keep the un-resolved surface")
        #expect((try await renames(harness, meeting.id))
            .contains { $0.speakerLabel == "S1" && $0.name == "Dana Marsh" })
        let segs = try await harness.segments(meeting.id)
        #expect(segs.filter { $0.speakerLabel == "S1" }.allSatisfy { $0.speakerName == "Dana Marsh" })

        // And the payload's two layers agree.
        let payload = try await latestPayload(harness, meeting.id)
        let transcript = try #require(payload["transcript"] as? [[String: Any]])
        let speakerNames = transcript.compactMap {
            ($0["speaker"] as? [String: Any])?["name"] as? String
        }
        let structured = try #require(payload["notes_structured"] as? [String: Any])
        let owners = (structured["action_items"] as? [[String: Any]] ?? [])
            .compactMap { $0["owner"] as? String }
        #expect(speakerNames.contains("Dana Marsh"))
        #expect(owners.contains("Dana Marsh"))
    }

    // MARK: - NH-D never reaches the reserved `user` mic-track label

    /// A correction whose original fold-equals the RECORDING USER's name must not
    /// write a rename row keyed `user`: that label is non-renameable in the UI, so
    /// the row's "needs re-confirmation" badge could never be cleared. The notes
    /// correction itself still applies.
    @Test func correctingTheUsersOwnNameWritesNoUserLabelRenameRow() async throws {
        let harness = try await makePipelineHarness()
        // The harness identity is "Sam"; the notes name the user.
        harness.notesPrimary.state.withLock { $0.summary = "Sam fechou o contrato" }
        let meeting = try await harness.importTestMeeting()
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        let provenance = try #require((try await harness.meeting(meeting.id))?.asrProvenance)
        // Persist the mic-track shape a two-track captured run produces: the
        // reserved `user` label carrying the identity name.
        let segments = [
            TranscriptSegment(
                meetingID: meeting.id, ord: 0, startSeconds: 0, endSeconds: 1,
                speakerLabel: TranscriptSegment.userLabel, speakerName: "Sam", text: "Olá"),
            TranscriptSegment(
                meetingID: meeting.id, ord: 1, startSeconds: 1, endSeconds: 2,
                speakerLabel: "S1", speakerName: "Fábio", text: "Tudo bem"),
        ]
        _ = try await harness.database.persistTranscript(
            meetingID: meeting.id, segments: segments, asrProvenance: provenance,
            dominantLanguage: "pt")

        let count = try await harness.pipeline.correctNameInNotes(
            meetingID: meeting.id, original: "Sam", replacement: "Sam Rivera",
            allOccurrences: true)
        #expect(count > 0)

        let rows = try await renames(harness, meeting.id)
        #expect(
            !rows.contains { $0.speakerLabel == TranscriptSegment.userLabel },
            "a rename row on the non-renameable `user` label is an unclearable stale badge")
        let notes = try #require(
            try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id))
        #expect(notes.structured.summary == "Sam Rivera fechou o contrato", "the notes still correct")
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
