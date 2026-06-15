import Foundation
import GRDB
import Synchronization
import Testing

@testable import BlaiseCore

// G14 — AC5c (H1 digest-pending self-heal via the digest-only resume) and
// AC5d (M3 name-edit deterministic rewrite vs. a non-name edit no-op). Mock
// engines only; FICTIONAL data (Vexatron Labs / Quoll Harbor).

private enum SelfHealFixtures {
    static let user = UserIdentity(name: "Dana Marsh", aliases: ["Dana"], email: "dana@vexatronlabs.example")
    static let attendees = [Attendee(name: "Dana Marsh", email: "dana@vexatronlabs.example", source: .manual)]
}

private func makeHarness(digest: String = "## HEADER\nmeeting: Vexatron Labs sync\nspeaker: (none resolved)\n")
    async throws -> PipelineHarness
{
    let harness = try await makePipelineHarness()
    try await SettingsStore(database: harness.database).set(UserIdentity.settingsKey, to: SelfHealFixtures.user)
    harness.notesPrimary.state.withLock { $0.digestString = digest }
    return harness
}

private func storedDigest(_ harness: PipelineHarness, _ id: MeetingID) async throws -> String? {
    try await NotesRepository(database: harness.database).fetch(meetingID: id)?.memoryDigest
}

private func parsePayload(_ harness: PipelineHarness, path: String) throws -> [String: Any] {
    let url = harness.database.rootURL.appendingPathComponent(path)
    return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
}

// MARK: - AC5c — H1 digest-pending + digest-only resume self-heal

@Suite struct MemoryDigestSelfHealTests {
    @Test func persistentDigestFailureIsDistinguishableAndSelfHeals() async throws {
        let harness = try await makeHarness()
        // Force the digest engine to fail past the (engine-level) bounded retry.
        harness.notesPrimary.state.withLock { $0.digestError = .permanent("forced digest failure") }
        let meeting = try await harness.importTestMeeting(attendees: SelfHealFixtures.attendees)
        let record = try await harness.pipeline.process(meetingID: meeting.id)

        // The run STILL COMPLETED: notes present, handoff enqueued, meeting ready
        // (Floor 8 — a digest failure never blocks or loses a meeting).
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.status == .ready)
        #expect(try await harness.queueRows(meeting.id) >= 1, "the meeting still handed off")
        #expect(try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id) != nil)

        // The payload omits memory_digest; the marker is digest-pending (distinct
        // from a toggle-off/legacy null).
        #expect(try await storedDigest(harness, meeting.id) == nil)
        let payload = try parsePayload(harness, path: try #require(record.payloadPath))
        #expect(payload["memory_digest"] == nil)
        #expect(DigestPendingClass.isPending(stored.lastProcessingError))
        #expect(!NotesPendingClass.isPending(stored.lastProcessingError), "distinct from notes-pending")

        // The notes call count BEFORE the resume.
        let notesCallsBefore = harness.notesPrimary.state.withLock { $0.requests.count }
        let digestCallsBefore = harness.notesPrimary.state.withLock { $0.digestRequests.count }

        // Now the digest engine recovers; a self-heal trigger drives the
        // digest-only resume.
        harness.notesPrimary.state.withLock { $0.digestError = nil }
        await harness.pipeline.resumePendingDigests()

        // The notes engine call count did NOT increase across the resume (notes
        // are final); the digest engine DID fire again.
        let notesCallsAfter = harness.notesPrimary.state.withLock { $0.requests.count }
        let digestCallsAfter = harness.notesPrimary.state.withLock { $0.digestRequests.count }
        #expect(notesCallsAfter == notesCallsBefore, "the resume does NOT re-run generateNotes")
        #expect(digestCallsAfter > digestCallsBefore, "the resume DID re-fire generateDigest")

        // The digest is now minted, stored, re-materialized, and the marker cleared.
        let healed = try #require(try await harness.meeting(meeting.id))
        #expect(!DigestPendingClass.isPending(healed.lastProcessingError))
        #expect(healed.lastProcessingError == nil)
        let digestNow = try #require(try await storedDigest(harness, meeting.id))
        #expect(digestNow.contains("## HEADER"))

        // The re-minted payload now carries memory_digest, and re-materialization
        // is byte-identical to the stored digest.
        let notes = try #require(try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id))
        let finalMeeting = try #require(try await harness.meeting(meeting.id))
        let segments = try await harness.segments(meeting.id)
        let rebuilt = EvidencePayloadBuilder.build(
            meeting: finalMeeting, segments: segments, notes: notes, user: SelfHealFixtures.user)
        let rebuiltParsed = try #require(
            try JSONSerialization.jsonObject(with: rebuilt.bytes) as? [String: Any])
        #expect(rebuiltParsed["memory_digest"] as? String == digestNow)
    }

    /// A digest-only resume on a meeting that is NOT digest-pending is a no-op
    /// (race-safe).
    @Test func resumeNoOpsWhenNotDigestPending() async throws {
        let harness = try await makeHarness()
        let meeting = try await harness.importTestMeeting(attendees: SelfHealFixtures.attendees)
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        let digestCallsBefore = harness.notesPrimary.state.withLock { $0.digestRequests.count }
        let didMint = try await harness.pipeline.processDigestOnly(meetingID: meeting.id)
        #expect(didMint == false, "a non-pending meeting is a no-op")
        #expect(harness.notesPrimary.state.withLock { $0.digestRequests.count } == digestCallsBefore)
    }
}

// MARK: - AC5d — M3 name-edit rewrite vs. non-name-edit no-op

@Suite struct MemoryDigestEditPathTests {
    /// A name-changing edit (correctNameInNotes) rewrites the STORED digest
    /// deterministically (corrected name, NO second engine call), and the
    /// re-minted payload shows the corrected name.
    @Test func nameCorrectionRewritesStoredDigestDeterministically() async throws {
        // The digest (and the notes summary) name a fictional person we will
        // correct by a single-token surname: "Okora" → "Okoro" (the notes
        // correction path matches fold-equal whole WORD runs, the UI's
        // token-scoped form).
        let digestWithName = "## HEADER\nmeeting: Vexatron Labs sync\nspeaker: Okora\n\n## COMMITMENTS\nOkora will review the Vexatron Labs plan by 21 March 2026.\n"
        let harness = try await makeHarness(digest: digestWithName)
        harness.notesPrimary.state.withLock {
            $0.summary = "Okora discutiu o plano da Vexatron Labs."
        }
        let meeting = try await harness.importTestMeeting(attendees: SelfHealFixtures.attendees)
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        #expect(try await storedDigest(harness, meeting.id) == digestWithName)
        let digestCallsBefore = harness.notesPrimary.state.withLock { $0.digestRequests.count }

        // The name correction.
        let count = try await harness.pipeline.correctNameInNotes(
            meetingID: meeting.id, original: "Okora", replacement: "Okoro",
            allOccurrences: true)
        #expect(count > 0)

        // The stored digest now shows the CORRECTED name — and NO second digest
        // engine call fired (the stored bytes were deterministically rewritten).
        let rewritten = try #require(try await storedDigest(harness, meeting.id))
        #expect(rewritten.contains("Okoro"))
        #expect(!rewritten.contains("Okora"))
        #expect(
            harness.notesPrimary.state.withLock { $0.digestRequests.count } == digestCallsBefore,
            "the name edit runs NO new digest engine call")

        // The re-minted payload carries the corrected digest.
        let notes = try #require(try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id))
        let m = try #require(try await harness.meeting(meeting.id))
        let segs = try await harness.segments(meeting.id)
        let payload = EvidencePayloadBuilder.build(meeting: m, segments: segs, notes: notes, user: SelfHealFixtures.user)
        let parsed = try #require(try JSONSerialization.jsonObject(with: payload.bytes) as? [String: Any])
        #expect((parsed["memory_digest"] as? String)?.contains("Okoro") == true)
    }

    /// A speaker rename (renameSpeaker) rewrites the stored digest's mentions of
    /// the speaker's prior resolved name to the new name — deterministically, NO
    /// second engine call.
    @Test func speakerRenameRewritesStoredDigestDeterministically() async throws {
        // The digest mentions the speaker's prior resolved name "Fabius".
        let digest = "## HEADER\nmeeting: Vexatron Labs sync\nspeaker: Fabius\n\n## COMMITMENTS\nFabius will send the Vexatron Labs contract by 21 March 2026.\n"
        let harness = try await makeHarness(digest: digest)
        // Resolve S1's name to "Fabius" via a mapping the rename will change.
        // (The mock transcript carries a verbatim token the resolver accepts;
        // we then rename the label, so the digest's prior name must update.)
        harness.notesPrimary.state.withLock {
            $0.mapping = [SpeakerNameProposal(label: "S1", name: "Fábio", confidence: .high, evidence: "x")]
        }
        let meeting = try await harness.importTestMeeting(attendees: SelfHealFixtures.attendees)
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        let digestCallsBefore = harness.notesPrimary.state.withLock { $0.digestRequests.count }

        // The S1 segment resolved to "Fábio"; rename it. We seed the digest with
        // the resolved name so the deterministic rewrite has a target.
        let segs = try await harness.segments(meeting.id)
        let priorName = segs.first { $0.speakerLabel == "S1" }?.speakerName ?? "Fábio"
        // Re-store a digest naming the actual prior resolved name, then rename.
        var notes0 = try #require(try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id))
        notes0.memoryDigest = "## HEADER\nmeeting: Vexatron Labs sync\nspeaker: \(priorName)\n\n## COMMITMENTS\n\(priorName) will send the Vexatron Labs contract by 21 March 2026.\n"
        try await NotesRepository(database: harness.database).upsert(notes0)

        _ = try await harness.pipeline.renameSpeaker(
            meetingID: meeting.id, speakerLabel: "S1", to: "Vega Quoll")

        let rewritten = try #require(try await storedDigest(harness, meeting.id))
        #expect(rewritten.contains("Vega Quoll"), "the digest shows the renamed speaker")
        #expect(!rewritten.contains(priorName), "the prior name is gone from the digest")
        #expect(
            harness.notesPrimary.state.withLock { $0.digestRequests.count } == digestCallsBefore,
            "a speaker rename runs NO new digest engine call")
    }

    /// A non-name edit (renameMeeting) reproduces the stored digest bytes
    /// UNCHANGED (the M5 invariant: a title rename never re-rolls the digest).
    @Test func titleRenameLeavesStoredDigestUnchanged() async throws {
        let digest = "## HEADER\nmeeting: Vexatron Labs sync\nspeaker: Dana Marsh\n\n## DECISIONS\nDana Marsh decided on 14 March 2026 to ship the Vexatron Labs scheduler.\n"
        let harness = try await makeHarness(digest: digest)
        let meeting = try await harness.importTestMeeting(attendees: SelfHealFixtures.attendees)
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        let before = try #require(try await storedDigest(harness, meeting.id))
        let digestCallsBefore = harness.notesPrimary.state.withLock { $0.digestRequests.count }

        _ = try await harness.pipeline.renameMeeting(meetingID: meeting.id, to: "Vexatron Labs planning")

        let after = try #require(try await storedDigest(harness, meeting.id))
        #expect(after == before, "a title rename reproduces the stored digest unchanged")
        #expect(
            harness.notesPrimary.state.withLock { $0.digestRequests.count } == digestCallsBefore,
            "a non-name edit runs NO digest engine call")
    }

    /// AC5d direct unit: the deterministic text rewrite is fold-equal whole-word,
    /// no LLM, and reproduces unchanged when the old name is absent.
    @Test func applyTextCorrectionIsDeterministicWholeWord() {
        let digest = "## COMMITMENTS\nOkora owns the plan. Okora ships it.\n"
        let (rewritten, count) = NameSubstitution.applyTextCorrection(
            text: digest, original: "Okora", replacement: "Okoro")
        #expect(count == 2)
        #expect(!rewritten.contains("Okora"))
        // Absent name → unchanged, zero replacements.
        let (same, zero) = NameSubstitution.applyTextCorrection(
            text: digest, original: "Nonexistent", replacement: "X")
        #expect(zero == 0)
        #expect(same == digest)
    }
}
