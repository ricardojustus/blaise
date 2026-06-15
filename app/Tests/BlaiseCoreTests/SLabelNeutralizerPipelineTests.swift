import Foundation
import GRDB
import Testing
@testable import BlaiseCore

// G13 AC1 (per-site end-to-end) + AC2 (substitution glue). The deterministic
// neutralizer runs as the LAST write to notes.structured at EACH of the four
// forward mint sites; a forward-minted payload carries no diarization label on
// EITHER notes-content surface. All test data is fictional (Vexatron Labs /
// Quoll Harbor; Dana Okonkwo) — no real names, partners, meeting IDs, content.

@Suite(.serialized) struct SLabelNeutralizerPipelineTests {
    // MARK: - helpers

    /// Overwrites the persisted notes row with an S-label-bearing structured +
    /// markdown value (simulating pre-G13 stored notes / a leaked engine
    /// output), so a subsequent forward re-mint must neutralize it.
    private func seedSLabelNotes(
        _ harness: PipelineHarness, _ id: MeetingID, language: String = "en"
    ) async throws {
        guard var notes = try await NotesRepository(database: harness.database)
            .fetch(meetingID: id)
        else { Issue.record("no notes row to seed"); return }
        notes.structured = NotesStructured(
            title: "Quoll Harbor sync",
            summary: "S0 walked the Vexatron Labs migration; _S1_ raised the timeline.",
            detailedNotes: "**S0** owns the rollout. S1 flagged a budget gap.",
            decisions: ["S0 ships the Quoll Harbor build by Friday"],
            actionItems: [
                ActionItem(owner: "S0", text: "send the Vexatron Labs contract"),
                ActionItem(owner: "S1", text: "review the timeline"),
            ],
            userActionItems: [])
        notes.language = language
        // The markdown deliberately still carries labels (the second surface).
        notes.markdown = try NotesRenderer.render(
            notes.structured, language: language, meetingTitle: "Quoll Harbor sync")
        try await NotesRepository(database: harness.database).upsert(notes)
    }

    private func persistedNotes(_ harness: PipelineHarness, _ id: MeetingID) async throws -> MeetingNotes {
        try #require(try await NotesRepository(database: harness.database).fetch(meetingID: id))
    }

    /// The bytes of the most-recently enqueued handoff payload for a meeting.
    private func latestPayloadJSON(
        _ harness: PipelineHarness, _ id: MeetingID
    ) async throws -> [String: Any] {
        let path: String = try await harness.database.pool.read { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT payload_path FROM handoff_queue
                    WHERE meeting_id = ? ORDER BY created_seq DESC LIMIT 1
                    """,
                arguments: [id]) ?? ""
        }
        let url = harness.database.rootURL.appendingPathComponent(path)
        let bytes = try Data(contentsOf: url)
        return try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }

    /// Recursively collects every string under a JSON value.
    private func collectStrings(_ value: Any) -> [String] {
        switch value {
        case let s as String: return [s]
        case let arr as [Any]: return arr.flatMap(collectStrings)
        case let obj as [String: Any]: return obj.values.flatMap(collectStrings)
        default: return []
        }
    }

    /// Asserts the no-S-label invariant over a forward-minted payload's
    /// notes-content surfaces (notes_structured + summary_markdown +
    /// summary_text), excluding transcript labels and the substitution report.
    private func assertNoLabelInNotesContent(_ json: [String: Any]) throws {
        let structured = try #require(json["notes_structured"] as? [String: Any])
        for s in collectStrings(structured) {
            #expect(!SLabelNeutralizer.containsLabel(s), "notes_structured leaked a label: \(s)")
        }
        let summaryMarkdown = try #require(json["summary_markdown"] as? String)
        #expect(!SLabelNeutralizer.containsLabel(summaryMarkdown), "summary_markdown leaked a label")
        let summaryText = try #require(json["summary_text"] as? String)
        #expect(!SLabelNeutralizer.containsLabel(summaryText))
        // The transcript diarization_label surface STILL carries S-labels.
        let transcript = try #require(json["transcript"] as? [[String: Any]])
        let diar = transcript.compactMap {
            ($0["speaker"] as? [String: Any])?["diarization_label"] as? String
        }
        #expect(diar.contains { $0.hasPrefix("S") }, "transcript labels must be preserved")
    }

    // MARK: - Site 1: renameMeeting (the TITLE rename) — ProcessingPipeline:720

    @Test func titleRenameNeutralizesStoredLabels() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        try await harness.pipeline.process(meetingID: meeting.id)
        try await seedSLabelNotes(harness, meeting.id)

        let changed = try await harness.pipeline.renameMeeting(
            meetingID: meeting.id, to: "Quoll Harbor partner sync")
        #expect(changed)

        let notes = try await persistedNotes(harness, meeting.id)
        // S0/S1 unresolved (no mapping, no rename) → neutralized, never labels.
        #expect(!SLabelNeutralizer.containsLabel(notes.structured.summary))
        #expect(!SLabelNeutralizer.containsLabel(notes.markdown))
        #expect(notes.structured.actionItems[0].owner.isEmpty)
        try await assertNoLabelInNotesContent(latestPayloadJSON(harness, meeting.id))
    }

    // MARK: - Site 2: renameSpeaker (the speaker rename) — ProcessingPipeline:814

    @Test func speakerRenameNeutralizesStoredLabels() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        try await harness.pipeline.process(meetingID: meeting.id)
        try await seedSLabelNotes(harness, meeting.id)

        // Rename S1 → a fictional name; S0 stays unresolved.
        let didRename = try await harness.pipeline.renameSpeaker(
            meetingID: meeting.id, speakerLabel: "S1", to: "Theo Vasquez")
        #expect(didRename)

        let notes = try await persistedNotes(harness, meeting.id)
        // S1 resolved by the rename row → the name appears; S0 neutralized.
        #expect(notes.structured.detailedNotes.contains("Theo Vasquez flagged a budget gap"))
        #expect(notes.structured.actionItems[1].owner == "Theo Vasquez")
        #expect(notes.structured.actionItems[0].owner.isEmpty)  // S0 unresolved → empty
        for field in SLabelFixture.allFields(notes.structured) {
            #expect(!SLabelNeutralizer.containsLabel(field))
        }
        try await assertNoLabelInNotesContent(latestPayloadJSON(harness, meeting.id))
    }

    // MARK: - Site 3: notes-correction re-mint — ProcessingPipeline:901

    @Test func notesCorrectionRemintNeutralizesStoredLabels() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        try await harness.pipeline.process(meetingID: meeting.id)
        try await seedSLabelNotes(harness, meeting.id)

        // An unrelated correction (Vexatron → Vexatron Labs Inc) re-mints; the
        // neutralizer must still run on the re-minted notes.structured.
        let count = try await harness.pipeline.correctNameInNotes(
            meetingID: meeting.id, original: "Quoll", replacement: "Quollheim",
            allOccurrences: true)
        #expect(count > 0)

        let notes = try await persistedNotes(harness, meeting.id)
        for field in SLabelFixture.allFields(notes.structured) {
            #expect(!SLabelNeutralizer.containsLabel(field))
        }
        #expect(!SLabelNeutralizer.containsLabel(notes.markdown))
        try await assertNoLabelInNotesContent(latestPayloadJSON(harness, meeting.id))
    }

    // MARK: - Site 4: pipeline finalize (stage 12 → stage 13) — ProcessingPipeline:1936

    @Test func finalizeNeutralizesEngineAuthoredLabels() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting(attendees: [
            Attendee(name: "Dana Okonkwo", email: nil, source: .manual),
            Attendee(name: "Mira Kovač", email: nil, source: .manual),
        ])
        // The engine authors S-labels in prose AND in an owner; S0 resolves to
        // the attendee Dana Okonkwo, S1 stays unresolved.
        harness.notesPrimary.state.withLock { state in
            state.summary = "S0 apresentou o plano; S1 levantou o prazo."
            state.actionOwner = "S1"
            state.mapping = [
                SpeakerNameProposal(
                    label: "S0", name: "Dana Okonkwo", confidence: .medium, evidence: "attendee"),
            ]
        }
        let record = try await harness.pipeline.process(meetingID: meeting.id)

        let notes = try await persistedNotes(harness, meeting.id)
        // S0 resolved → Dana Okonkwo; S1 unresolved → neutral descriptor + empty
        // owner. (The meeting language is pt by default → PT descriptors.)
        #expect(notes.structured.summary.contains("Dana Okonkwo apresentou o plano"))
        #expect(notes.structured.summary.contains("participante"))
        #expect(notes.structured.actionItems[0].owner.isEmpty)
        for field in SLabelFixture.allFields(notes.structured) {
            #expect(!SLabelNeutralizer.containsLabel(field))
        }
        #expect(!SLabelNeutralizer.containsLabel(notes.markdown))

        // The stage-13 build()'d payload (recorded on the run) is clean too.
        let payloadURL = harness.database.rootURL.appendingPathComponent(
            try #require(record.payloadPath))
        let json = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: payloadURL)) as? [String: Any])
        try assertNoLabelInNotesContent(json)
    }

    // MARK: - AC2: the substitution glue (NEW, not a free consequence)

    @Test func renamePopulatesNotesStructured_AC2() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        try await harness.pipeline.process(meetingID: meeting.id)
        try await seedSLabelNotes(harness, meeting.id)

        // Before the rename: notes.structured carries the raw label everywhere.
        let before = try await persistedNotes(harness, meeting.id)
        #expect(before.structured.summary.contains("S0"))
        #expect(before.structured.actionItems[0].owner == "S0")

        // Rename S0 → Dana Okonkwo. Today (pre-G13) this only touched the
        // transcript; G13's added label-substitution pass must carry the name
        // into notes.structured EVERYWHERE S0 appeared.
        let didRename = try await harness.pipeline.renameSpeaker(
            meetingID: meeting.id, speakerLabel: "S0", to: "Dana Okonkwo")
        #expect(didRename)

        let after = try await persistedNotes(harness, meeting.id)
        #expect(after.structured.summary.contains("Dana Okonkwo walked"))
        #expect(after.structured.detailedNotes.contains("**Dana Okonkwo** owns the rollout"))
        #expect(after.structured.decisions[0].contains("Dana Okonkwo ships"))
        #expect(after.structured.actionItems[0].owner == "Dana Okonkwo")
        // Zero engine calls — the rename is a deterministic re-mint.
        let notesCalls = harness.notesPrimary.state.withLock { $0.requests.count }
        #expect(notesCalls == 1, "only the initial process() called the notes engine; rename made zero")
        // The label is gone from the structured value (the proof the pass ran
        // over notes.structured, not only the transcript).
        #expect(!after.structured.summary.contains("S0"))
        #expect(!after.structured.actionItems[0].owner.contains("S0"))
    }
}
