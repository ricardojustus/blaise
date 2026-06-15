import Foundation
import GRDB
import Testing
@testable import BlaiseCore

// G2 AC2 (integration): owner "SEMI" + store row → "Sammy" end-to-end, report
// present, re-mint, ZERO engine calls beyond the notes generation (the pass
// makes none). AC4: the pass runs in generate / regenerate / pending-resume.

private func everydayClosure() throws -> @Sendable (String) -> Bool {
    let lex = try PipelineVocabulary.sharedLexicons()
    return { PipelineVocabulary.isEveryday($0, lexicons: lex) }
}

/// Seeds a name_correction row through the §2 write path.
private func seedCorrection(
    _ database: BlaiseDatabase, _ key: String, _ replacement: String,
    sourceMeetingID: MeetingID? = nil
) async throws {
    let everyday = try everydayClosure()
    try await database.pool.write { db in
        _ = try NameCorrectionStore.upsert(
            db, mishearedSurface: key, replacement: replacement,
            sourceMeetingID: sourceMeetingID, now: msDate(), isEveryday: everyday)
    }
}

private func notes(_ database: BlaiseDatabase, _ id: MeetingID) async throws -> MeetingNotes? {
    try await NotesRepository(database: database).fetch(meetingID: id)
}

@Suite(.serialized) struct NameSubstitutionPipelineTests {
    @Test func ac2_ownerSemiCorrectedToSammyEndToEnd() async throws {
        let harness = try await makePipelineHarness()
        // "semi" is everyday → scoped to OWNER fields only (NC-1). The spec's
        // flagship: an OWNER "SEMI" becomes "Sammy"; "semi" in prose stays.
        harness.notesPrimary.state.withLock {
            $0.actionOwner = "SEMI"
            $0.summary = "houve um semi-intervalo e muito semi na sala"
        }
        try await seedCorrection(harness.database, "semi", "Sammy")

        let meeting = try await harness.importTestMeeting()
        try await harness.pipeline.process(meetingID: meeting.id)

        let stored = try #require(try await notes(harness.database, meeting.id))
        // Owner SEMI → Sammy.
        #expect(stored.structured.actionItems.first?.owner == "Sammy")
        // Prose "semi" untouched (everyday scoping), "semi-intervalo" hyphen-guarded.
        #expect(stored.structured.summary == "houve um semi-intervalo e muito semi na sala")
        // Report present in provenance, rule 1.
        #expect(stored.provenance.nameSubstitutions.contains { $0.replacement == "Sammy" && $0.rule == 1 })

        // Zero engine calls beyond the single notes generation (the pass is pure).
        #expect(harness.notesPrimary.state.withLock { $0.requests.count } == 1)
        // Re-mint: a handoff payload was queued (ready ⇒ queued).
        #expect(try await harness.queueRows(meeting.id) >= 1)
    }

    @Test func ac4_passRunsOnRegenerate() async throws {
        let harness = try await makePipelineHarness()
        harness.notesPrimary.state.withLock { $0.actionOwner = "SEMI" }
        let meeting = try await harness.importTestMeeting()
        try await harness.pipeline.process(meetingID: meeting.id)
        // First run: no store row → no substitution.
        let before = try #require(try await notes(harness.database, meeting.id))
        #expect(before.structured.actionItems.first?.owner == "SEMI")
        #expect(before.provenance.nameSubstitutions.isEmpty)

        // Add the row, regenerate — the pass must now fire on the regenerate
        // path (diarization is reused; no fresh engine clustering needed).
        try await seedCorrection(harness.database, "semi", "Sammy")
        try await harness.pipeline.regenerate(meetingID: meeting.id)
        let after = try #require(try await notes(harness.database, meeting.id))
        #expect(after.structured.actionItems.first?.owner == "Sammy")
        #expect(after.provenance.nameSubstitutions.contains { $0.rule == 1 })
    }

    @Test func ac4_passRunsOnPendingResume() async throws {
        // Pending-resume: the original process() reaches notes-pending (the
        // only fallback is heavyweight → never auto-loaded, D17), then a
        // self-heal resume produces notes and must run the pass.
        let harness = try await makePipelineHarness(
            fallbackLoadProfile: .heavyweight(estimatedPeakBytes: 18_000_000_000))
        harness.notesPrimary.state.withLock {
            $0.error = .notAvailable(reason: EngineFallbackReason.monthlyCeiling)
        }
        let meeting = try await harness.importTestMeeting()
        try await harness.pipeline.process(meetingID: meeting.id)
        // Notes-pending: transcript persisted, no notes.
        #expect(try await notes(harness.database, meeting.id) == nil)

        // Clear the failure, seed a correction, resume.
        harness.notesPrimary.state.withLock {
            $0.error = nil
            $0.actionOwner = "SEMI"
        }
        try await seedCorrection(harness.database, "semi", "Sammy")
        _ = try await harness.pipeline.processNotesOnly(meetingID: meeting.id)

        let resumed = try #require(try await notes(harness.database, meeting.id))
        #expect(resumed.structured.actionItems.first?.owner == "Sammy")
        #expect(resumed.provenance.nameSubstitutions.contains { $0.rule == 1 })
    }

    // H-3: store rule 1 reaches SPEAKER LABELS, not just notes. A mechanically
    // applied speaker NAME ("Fábio", transcript-verbatim so it survives naming)
    // is outranked by a store row `fabio → Fabius` — the corrected name reaches
    // the persisted transcript segments and (via re-mint) the payload, not just
    // notes prose. Pre-fix the pass ran only over notes and the label survived.
    @Test func storeRule1AppliesToSpeakerLabels_H3() async throws {
        let harness = try await makePipelineHarness()
        // Name label S1 "Fábio" (verbatim in the mock transcript → passes the
        // SpeakerResolution verbatim rule), high confidence.
        harness.notesPrimary.state.withLock {
            $0.mapping = [SpeakerNameProposal(
                label: "S1", name: "Fábio", confidence: .high, evidence: "said it")]
        }
        try await seedCorrection(harness.database, "fabio", "Fabius")

        let meeting = try await harness.importTestMeeting()
        try await harness.pipeline.process(meetingID: meeting.id)

        let segs = try await TranscriptRepository(database: harness.database)
            .segments(meetingID: meeting.id)
        // The S1 segment's name was corrected at the LABEL by the store.
        #expect(segs.filter { $0.speakerLabel == "S1" }.allSatisfy { $0.speakerName == "Fabius" })
        #expect(!segs.contains { $0.speakerName == "Fábio" }, "the misheard label name is gone")
    }

    // H-4: §4 store rule-1/3 normalization applies to RENAME INPUT too. A user
    // renaming a label to the misheard surface they see on screen ("SEMI")
    // durably stores the CORRECTED name ("Sammy") when a store row covers it —
    // not the mishearing. Pre-fix renameSpeaker ran only the parenthetical
    // cleanup and stored "SEMI"; normalizeRename had zero production callers.
    @Test func renameInputNormalizedThroughStore_H4() async throws {
        let harness = try await makePipelineHarness()
        try await seedCorrection(harness.database, "semi", "Sammy")
        let meeting = try await harness.importTestMeeting()
        try await harness.pipeline.process(meetingID: meeting.id)

        _ = try await harness.pipeline.renameSpeaker(
            meetingID: meeting.id, speakerLabel: "S0", to: "SEMI")

        let rows = try await harness.database.pool.read {
            try SpeakerRenameStore.all($0, meetingID: meeting.id)
        }
        let s0 = try #require(rows.first { $0.speakerLabel == "S0" })
        #expect(s0.name == "Sammy", "rename input normalized through the store row")
        // And the corrected name lands on the segments.
        let segs = try await TranscriptRepository(database: harness.database)
            .segments(meetingID: meeting.id)
        #expect(segs.filter { $0.speakerLabel == "S0" }.allSatisfy { $0.speakerName == "Sammy" })
    }

    // M-3: a NOTES replacement is applied VERBATIM (only trimmed) — the rename
    // X-(Y) parenthetical heuristic does NOT run on it, so "Sammy (PM)" stays
    // "Sammy (PM)" in the notes (pre-fix it became "PM"), matching the RAW
    // surface rememberCorrection would store.
    @Test func correctNameInNotesUsesReplacementVerbatim_M3() async throws {
        let harness = try await makePipelineHarness()
        harness.notesPrimary.state.withLock { $0.summary = "Caco fechou o contrato" }
        let meeting = try await harness.importTestMeeting()
        try await harness.pipeline.process(meetingID: meeting.id)

        let count = try await harness.pipeline.correctNameInNotes(
            meetingID: meeting.id, original: "Caco", replacement: "Sammy (PM)",
            allOccurrences: false)
        #expect(count == 1)
        let stored = try #require(try await notes(harness.database, meeting.id))
        #expect(stored.structured.summary == "Sammy (PM) fechou o contrato")
    }

    // H-8 at the pipeline level: a position-scoped correction fixes the chosen
    // occurrence (here the second), re-rendering + re-minting deterministically.
    @Test func correctNameInNotesPositionScoped_H8() async throws {
        let harness = try await makePipelineHarness()
        harness.notesPrimary.state.withLock { $0.summary = "Riso e Riso conversaram" }
        let meeting = try await harness.importTestMeeting()
        try await harness.pipeline.process(meetingID: meeting.id)

        let count = try await harness.pipeline.correctNameInNotes(
            meetingID: meeting.id, original: "Riso", replacement: "Marco Vidal",
            allOccurrences: false, occurrenceIndex: 1)
        #expect(count == 1)
        let stored = try #require(try await notes(harness.database, meeting.id))
        #expect(stored.structured.summary == "Riso e Marco Vidal conversaram")
    }

    @Test func ac6_emptyStorePipelineLeavesNotesUnsubstituted() async throws {
        // The full-pipeline complement to the pure identity test: with NO store
        // rows, the persisted notes carry an empty report and the engine's
        // owner survives verbatim.
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        try await harness.pipeline.process(meetingID: meeting.id)
        let stored = try #require(try await notes(harness.database, meeting.id))
        #expect(stored.provenance.nameSubstitutions.isEmpty)
        #expect(stored.structured.actionItems.first?.owner == "Fábio")
    }
}
