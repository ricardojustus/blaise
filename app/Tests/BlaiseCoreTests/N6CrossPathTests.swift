import Foundation
import GRDB
import Synchronization
import Testing

@testable import BlaiseCore

// N6 — the arc's cross-path compositions: three timing schedules no single
// chunk owns, plus the lifecycle sentinel. Every engine is scripted (zero model
// calls) and every fixture is FICTIONAL (Vexatron Labs / Quoll Harbor).

// MARK: - Fixtures

/// The claim the corrections move in and out of the notes. No proper nouns, so
/// no name pass can move its bytes.
private let arcClaim = "the pilot slipped to September"

/// A sentence every fixture keeps, so a later correction has something present
/// to anchor to.
private let arcAnchorLine = "The Quoll Harbor field kit ships in May."

/// A digest that ASSERTS the claim, so the reconcile pass has real work and the
/// notes/digest pair is observable in both directions.
private let arcDigestAssertingTheClaim = """
    ## HEADER
    meeting: Vexatron Labs field-kit review
    date: 2026-03-14
    speaker: Dana Marsh

    ## DECISIONS
    Dana Marsh decided on 2026-03-14 to ship the Quoll Harbor field kit in May 2026.

    ## STATUS
    The team recorded that \(arcClaim).
    """

private let arcDigestWithoutTheClaim = arcDigestAssertingTheClaim.replacingOccurrences(
    of: "The team recorded that \(arcClaim).",
    with: "The team recorded no pilot slip.")

private func eraseTheClaimFromTheDigest() -> DigestEditOperation {
    DigestEditOperation(
        find: "The team recorded that \(arcClaim).",
        replace: "The team recorded no pilot slip.", instruction: 1)
}

private func restoreTheClaimToTheDigest() -> DigestEditOperation {
    DigestEditOperation(
        find: "The team recorded no pilot slip.",
        replace: "The team recorded that \(arcClaim).", instruction: 1)
}

/// Structured notes carrying the claim in `detailedNotes`, beside the anchor
/// line the later instructions quote.
private func arcNotesCarryingTheClaim() -> NotesStructured {
    NotesStructured(
        title: "Field-kit review", summary: "Ships in May.",
        detailedNotes: "\(arcAnchorLine) The team confirmed that \(arcClaim).",
        decisions: ["Ship the field kit in May"],
        actionItems: [ActionItem(owner: "Dana Marsh", text: "Confirm the ship date")],
        userActionItems: [])
}

private func arcNotesWithoutTheClaim(title: String? = "Field-kit review") -> NotesStructured {
    NotesStructured(
        title: title, summary: "Ships in May.",
        detailedNotes: arcAnchorLine,
        decisions: ["Ship the field kit in May"],
        actionItems: [ActionItem(owner: "Dana Marsh", text: "Confirm the ship date")],
        userActionItems: [])
}

// MARK: - Payload readers

/// Every payload this meeting has enqueued, oldest first — the X-cases assert
/// on the SEQUENCE, which `latestPayload` cannot show.
private func deliveredPayloads(
    _ harness: SettleHarness, _ meetingID: MeetingID
) async throws -> [[String: Any]] {
    let items = try await harness.database.pool.read { db in
        try HandoffItem
            .filter(Column("meeting_id") == meetingID)
            .order(Column("created_seq").asc)
            .fetchAll(db)
    }
    return try items.map { item in
        let data = try Data(contentsOf: harness.root.appendingPathComponent(item.payloadPath))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private func retractedClaims(_ payload: [String: Any]) throws -> [String] {
    let records = try #require(payload["retractions"] as? [[String: Any]])
    return records.compactMap { $0["claim_text"] as? String }
}

private func summaryMarkdown(_ payload: [String: Any]) throws -> String {
    try #require(payload["summary_markdown"] as? String)
}

/// The COMPLETE payload notes expected at a boundary, written out from the
/// fixture values and the shipped section shape — never obtained by running the
/// renderer, which would only assert the code against itself. Only the two
/// things the arc moves vary: the H1 (the title promotion writes it) and the
/// detailed-notes body (the editor and the regeneration rewrite it). A
/// substring check on the claim would pass over a corrupted summary, decision
/// or action item; this does not.
private func expectedPayloadNotes(title: String, detailedNotes: String) -> String {
    """
    # \(title)

    ## Summary

    Ships in May.

    ## Detailed notes

    \(detailedNotes)

    ## Decisions

    - Ship the field kit in May

    ## Action items

    - **Dana Marsh:** Confirm the ship date

    ## Sam's action items

    No action items for Sam.

    """
}

/// The detailed-notes body once a correction has put the claim back beside the
/// anchor line.
private let arcDetailedNotesCarryingTheClaim =
    "\(arcAnchorLine) The team confirmed that \(arcClaim)."

private func updatedAtMS(_ payload: [String: Any]) throws -> Int {
    try #require(payload["updated_at_ms"] as? Int)
}

private func transcriptRows(
    _ harness: SettleHarness, _ meetingID: MeetingID
) async throws -> [TranscriptSegment] {
    try await TranscriptRepository(database: harness.database).segments(meetingID: meetingID)
}

private func storedNotes(
    _ harness: SettleHarness, _ meetingID: MeetingID
) async throws -> MeetingNotes {
    try #require(try await NotesRepository(database: harness.database).fetch(meetingID: meetingID))
}

// MARK: - X-1: the arc lifecycle sentinel

/// Deliberate CUMULATIVE confirmation, not an unowned composition: every step
/// is first-proven in the chunk that built it. The sentinel exists because one
/// uninterrupted run of the whole correction story makes the arc's close
/// legible, and because it carries the only whole-arc monotonic-timestamp and
/// transcript oracles.
///
/// The order is the mechanically coherent one: a clean rewrite finalizes its
/// OWN delivery and clears settle debt, so no settle follows it. The view is
/// held ATTACHED across the withheld step — a detached post-editor hook would
/// run the executor immediately and settle before the resurrection lands.
///
/// The strict-increase oracle's limit, stated plainly: it is proven here on the
/// LLM-TITLED path, where the clean rewrite's title promotion advances the
/// clock. A user- or calendar-titled meeting takes no promotion write and its
/// finalize embeds the pre-finalize stamp, so across a clean rewrite its
/// payloads TIE — same timestamp, different bytes and version hash.
@Suite struct N6ArcLifecycleSentinelTests {
    @Test("X-1: the whole correction lifecycle, one uninterrupted run")
    func arcLifecycleSentinel() async throws {
        let harness = try await makeSettleHarness()
        let meeting = try await seedSettleMeeting(
            harness, digest: arcDigestAssertingTheClaim, titleSource: .llm)
        try await NotesRepository(database: harness.database).upsert(
            MeetingNotes(
                meetingID: meeting.id,
                markdown: try NotesRenderer.render(
                    arcNotesCarryingTheClaim(), language: "en", meetingTitle: meeting.title,
                    userName: UserIdentity.onboardedUser.name, annotations: []),
                structured: arcNotesCarryingTheClaim(), language: "en",
                generatedAt: harness.clock.now(),
                provenance: NotesProvenance(
                    engine: "seed", model: "seed", pipelineVersion: "seed", runtime: "seed",
                    rendererVersion: NotesRenderer.version, promptVersion: "seed"),
                memoryDigest: arcDigestAssertingTheClaim,
                digestPromptVersion: DigestPromptBuilder.shippedVersion.rawValue))
        let transcriptBefore = try await transcriptRows(harness, meeting.id)
        await harness.pipeline.settleViewAttached(meeting.id)

        // 1. A correction withdraws the claim; the burst fires; the editor pass
        //    erases it.
        harness.engine.scriptNotes([[
            .replace(
                field: .detailedNotes, find: " The team confirmed that \(arcClaim).",
                replace: "", instruction: 1)
        ]])
        harness.engine.scriptDigest([
            [eraseTheClaimFromTheDigest()],
            [restoreTheClaimToTheDigest()],
        ])
        _ = try await harness.pipeline.addCorrection(
            meetingID: meeting.id, kind: .understanding, section: .detailedNotes,
            quotedText: arcClaim, occurrence: 0, userText: "That was never said — drop it.")
        harness.clock.advance(by: .seconds(300))
        #expect(await eventually { harness.engine.notesCallCount == 1 })
        #expect(
            await eventually {
                ((try? await storedNotes(harness, meeting.id))?.structured.detailedNotes)
                    == arcAnchorLine
            })
        #expect(try await harness.queueRows(meeting.id) == 0, "the editor pass delivers nothing")

        // 2. A forced resurrection through the rewrite verb is withheld: the
        //    previous notes are kept, the meeting is flagged, the settle debt
        //    the editor recorded survives.
        harness.engine.state.withLock { $0.notesSyntheses = [arcNotesCarryingTheClaim()] }
        _ = try await harness.pipeline.rewriteNotes(meetingID: meeting.id)
        let afterWithhold = try await storedNotes(harness, meeting.id)
        #expect(afterWithhold.structured.detailedNotes == arcAnchorLine, "the previous notes are kept")
        #expect(
            try #require(
                try await MeetingRepository(database: harness.database).fetch(meeting.id))
                .processingNote == ProcessingPipeline.resurrectedClaimNote)
        #expect(afterWithhold.digestEditOwed && afterWithhold.deliveryOwed, "settle debt preserved")
        #expect(try await harness.queueRows(meeting.id) == 0)

        // 3. The preserved debt settles: ONE digest pass, ONE delivery.
        await harness.pipeline.settleViewDetached(meeting.id)
        #expect(harness.engine.digestCallCount == 1)
        #expect(try await harness.queueRows(meeting.id) == 1)

        // 4. A later CLEAN rewrite installs and finalizes its OWN payload —
        //    and no settle follows it.
        harness.clock.advance(by: .seconds(60))
        harness.engine.state.withLock {
            $0.notesSyntheses = [arcNotesWithoutTheClaim(title: "Quoll Harbor field-kit review")]
            $0.digestSyntheses = [arcDigestWithoutTheClaim]
        }
        _ = try await harness.pipeline.rewriteNotes(meetingID: meeting.id)
        #expect(try await harness.queueRows(meeting.id) == 2, "the finalize minted its own delivery")
        let afterRewrite = try await storedNotes(harness, meeting.id)
        #expect(!afterRewrite.digestEditOwed && !afterRewrite.deliveryOwed, "settle debt cleared")
        harness.settleClock.advance(by: .seconds(600))
        harness.clock.advance(by: .seconds(600))
        await harness.pipeline.resumeOwedSettles()
        await harness.pipeline.settleViewDetached(meeting.id)
        _ = await eventually { harness.engine.digestCallCount > 1 }
        #expect(harness.engine.digestCallCount == 1, "no settle follows a clean rewrite")
        #expect(try await harness.queueRows(meeting.id) == 2)

        // 5. A newer correction restores the claim; the editor pass re-inserts
        //    it; the next settle's payload retires the record.
        harness.engine.scriptNotes([[
            .replace(
                field: .detailedNotes, find: arcAnchorLine,
                replace: "\(arcAnchorLine) The team confirmed that \(arcClaim).",
                instruction: 1)
        ]])
        _ = try await harness.pipeline.addCorrection(
            meetingID: meeting.id, kind: .understanding, section: .detailedNotes,
            quotedText: arcAnchorLine, occurrence: 0,
            userText: "The pilot DID slip to September — put that back.")
        harness.clock.advance(by: .seconds(300))
        #expect(await eventually { (try? await harness.queueRows(meeting.id)) == 3 })
        #expect(harness.engine.notesCallCount == 2)
        #expect(harness.engine.digestCallCount == 2)

        // The cross-step oracles.
        let payloads = try await deliveredPayloads(harness, meeting.id)
        #expect(payloads.count == 3)

        #expect(
            try summaryMarkdown(payloads[0])
                == expectedPayloadNotes(
                    title: "Vexatron Labs field-kit review", detailedNotes: arcAnchorLine))
        #expect(try #require(payloads[0]["memory_digest"] as? String) == arcDigestWithoutTheClaim)
        #expect(try retractedClaims(payloads[0]) == [arcClaim], "the withdrawn claim's record ships")

        // The clean rewrite's own payload: same corrected body, promoted title.
        #expect(
            try summaryMarkdown(payloads[1])
                == expectedPayloadNotes(
                    title: "Quoll Harbor field-kit review", detailedNotes: arcAnchorLine))
        #expect(try retractedClaims(payloads[1]) == [arcClaim])

        #expect(
            try summaryMarkdown(payloads[2])
                == expectedPayloadNotes(
                    title: "Quoll Harbor field-kit review",
                    detailedNotes: arcDetailedNotesCarryingTheClaim))
        #expect(try #require(payloads[2]["memory_digest"] as? String) == arcDigestAssertingTheClaim)
        #expect(try retractedClaims(payloads[2]).isEmpty, "the restored claim retires its record")

        let timestamps = try payloads.map(updatedAtMS)
        #expect(timestamps == timestamps.sorted() && Set(timestamps).count == timestamps.count,
            "updated_at_ms strictly increases across every delivered payload")

        #expect(try await transcriptRows(harness, meeting.id) == transcriptBefore,
            "no path in this lifecycle re-transcribes")
    }
}

// MARK: - X-2: a correction mutation during a SUCCESSFUL digest-editor await

/// CHARACTERIZATION of ratified behaviour — it builds and changes nothing.
///
/// Gap: N4 SC-11 owns the editor injected BETWEEN the digest step and delivery
/// (a chain-slot schedule) and the permanent-failure variant; N5 SC-2 owns
/// deletion freshness during the regeneration and digest-heal awaits. Nobody
/// owns the mutation-during-SUCCESSFUL-await ordering end to end.
///
/// Mechanism: correction mutations are pool writes, not chain entries, so one
/// CAN land while the digest call holds the chain suspended. The editor body IS
/// a chain entry, so it stays asleep behind the chain and the notes cannot move
/// mid-await. The successful response clears the digest bit, the delivery guard
/// does not refuse, and the activation ships a stale-but-coherent pair; the
/// mutation's own armed editor then converges everything one settle later.
@Suite struct N6DigestAwaitMutationTests {
    @Test("X-2: a mutation during a successful digest await ships stale-but-coherent, then converges")
    func mutationDuringASuccessfulDigestAwait() async throws {
        let digestGate = EditorGate()
        let harness = try await makeSettleHarness()
        harness.engine.state.withLock { $0.digestGate = digestGate }
        let meeting = try await seedSettleMeeting(harness, digest: arcDigestAssertingTheClaim)
        try await NotesRepository(database: harness.database).upsert(
            MeetingNotes(
                meetingID: meeting.id,
                markdown: try NotesRenderer.render(
                    arcNotesWithoutTheClaim(), language: "en", meetingTitle: meeting.title,
                    userName: UserIdentity.onboardedUser.name, annotations: []),
                structured: arcNotesWithoutTheClaim(), language: "en",
                generatedAt: harness.clock.now(),
                provenance: NotesProvenance(
                    engine: "seed", model: "seed", pipelineVersion: "seed", runtime: "seed",
                    rendererVersion: NotesRenderer.version, promptVersion: "seed"),
                memoryDigest: arcDigestAssertingTheClaim,
                digestPromptVersion: DigestPromptBuilder.shippedVersion.rawValue))
        // The withdrawn claim: an applied instruction whose quoted text the
        // notes no longer carry, so the payload derives its retraction record.
        let withdrawn = try await seedSettleCorrection(
            harness, meetingID: meeting.id, status: .applied, section: .detailedNotes,
            quotedText: arcClaim, userText: "That was never said.",
            createdAt: harness.clock.now())
        try await setDigestOwed(harness, meeting.id)
        try await setDeliveryOwed(harness, meeting.id)
        let transcriptBefore = try await transcriptRows(harness, meeting.id)

        harness.engine.scriptDigest([
            [eraseTheClaimFromTheDigest()],
            [restoreTheClaimToTheDigest()],
        ])
        harness.engine.scriptNotes([[
            .replace(
                field: .detailedNotes, find: arcAnchorLine,
                replace: "\(arcAnchorLine) The team confirmed that \(arcClaim).",
                instruction: 1)
        ]])

        // The executor suspends inside the digest call, holding the chain.
        let executor = Task { await harness.pipeline.settleViewDetached(meeting.id) }
        await digestGate.waitUntilEntered()

        // The mutation is a POOL write, so it lands while the chain is held: it
        // restamps the row into a restoration instruction, arms a future editor
        // activation, and signals settle state. The editor itself stays asleep.
        _ = try await harness.pipeline.updateCorrection(
            meetingID: meeting.id, id: withdrawn.id, quotedText: arcClaim, occurrence: 0,
            userText: "That WAS said — put it back.")
        // The editor is a chain entry AND is asleep on its own burst window;
        // that the notes could not move mid-await is what the first payload
        // below proves.
        #expect(harness.engine.notesCallCount == 0)

        digestGate.release()
        await executor.value

        // The armed editor drains on the next settle and converges everything.
        harness.settleClock.advance(by: .seconds(600))
        #expect(await eventually { (try? await harness.queueRows(meeting.id)) == 2 })
        #expect(await eventually { harness.engine.digestCallCount == 2 })

        let payloads = try await deliveredPayloads(harness, meeting.id)
        #expect(payloads.count == 2, "exactly two payloads across the whole schedule")

        // The FIRST pair is mutually coherent and entirely pre-mutation:
        // neither the notes nor the digest reflect the restoration.
        let first = payloads[0]
        #expect(
            try summaryMarkdown(first)
                == expectedPayloadNotes(title: "Field-kit review", detailedNotes: arcAnchorLine))
        #expect(try #require(first["memory_digest"] as? String) == arcDigestWithoutTheClaim)
        // The ⚠ advisory made visible: the first payload still carries a
        // retraction record for the claim the user just asked restored. The
        // Evidence Store retires it and the next payload un-retires it — the
        // ratified one-settle-later price, characterized here, not changed.
        #expect(try retractedClaims(first) == [arcClaim])

        // The SECOND payload is fully converged.
        let second = payloads[1]
        #expect(
            try summaryMarkdown(second)
                == expectedPayloadNotes(
                    title: "Field-kit review", detailedNotes: arcDetailedNotesCarryingTheClaim))
        #expect(try #require(second["memory_digest"] as? String) == arcDigestAssertingTheClaim)
        #expect(try retractedClaims(second).isEmpty, "the restored claim retires its record")
        #expect(try updatedAtMS(second) > (try updatedAtMS(first)))

        // After convergence, no further model call without a fresh trigger.
        // Three calls are structural to the schedule: the suspended digest, the
        // editor drain, the converging digest.
        #expect(harness.engine.totalModelCallCount == 3)
        harness.settleClock.advance(by: .seconds(3_600))
        harness.clock.advance(by: .seconds(3_600))
        await harness.pipeline.resumeOwedSettles()
        #expect(harness.engine.totalModelCallCount == 3, "quiescent without a fresh trigger")
        #expect(try await harness.queueRows(meeting.id) == 2)

        #expect(try await transcriptRows(harness, meeting.id) == transcriptBefore)
    }
}

// MARK: - X-3: a regeneration consumes an armed session

/// Gap: N3 owns clean installation and N4 owns finalize delivery and the arming
/// rules separately; the unowned property is the no-duplicate-delivery half —
/// timers and debt armed BEFORE a regeneration cannot duplicate its delivery
/// AFTER it. The zero-editor-call half re-drives N2 AC-8's cancel arm through
/// the REGENERATION path (acknowledged overlap).
@Suite struct N6RegenerationConsumesArmedSessionTests {
    @Test("X-3: a regeneration consuming the armed session leaves nothing behind to deliver twice")
    func regenerationConsumesTheArmedSession() async throws {
        let harness = try await makeSettleHarness()
        let meeting = try await seedSettleMeeting(harness, digest: arcDigestAssertingTheClaim)
        let transcriptBefore = try await transcriptRows(harness, meeting.id)

        // A pending instruction arms BOTH the editor burst and the settle slot.
        _ = try await harness.pipeline.addCorrection(
            meetingID: meeting.id, kind: .understanding, section: .detailedNotes,
            quotedText: arcClaim, occurrence: 0, userText: "That was never said.")
        #expect(await eventually { harness.clock.activeSleeperCount == 1 })
        #expect(await eventually { harness.settleClock.activeSleeperCount == 1 })

        // The regeneration starts and finalizes before either fires. Its
        // candidate does not carry the withdrawn claim, so it installs cleanly.
        harness.engine.state.withLock {
            $0.notesSyntheses = [arcNotesWithoutTheClaim()]
            $0.digestSyntheses = [arcDigestWithoutTheClaim]
        }
        _ = try await harness.pipeline.rewriteNotes(meetingID: meeting.id)

        #expect(try await harness.queueRows(meeting.id) == 1, "the finalize minted its own delivery")
        #expect(harness.engine.notesSynthesisCallCount == 1)
        #expect(harness.engine.digestSynthesisCallCount == 1)

        // Detach, scheduler expiry, and the owed sweep — every trigger the
        // armed session could still fire through.
        await harness.pipeline.settleViewDetached(meeting.id)
        harness.settleClock.advance(by: .seconds(600))
        harness.clock.advance(by: .seconds(600))
        await harness.pipeline.resumeOwedSettles()
        _ = await eventually { harness.engine.totalModelCallCount > 2 }

        #expect(harness.engine.notesCallCount == 0, "no notes-editor call")
        #expect(harness.engine.digestCallCount == 0, "no digest-editor call")
        #expect(try await harness.queueRows(meeting.id) == 1, "no second delivery")

        // The regeneration's one payload carries the current retraction set.
        let payloads = try await deliveredPayloads(harness, meeting.id)
        #expect(try retractedClaims(try #require(payloads.last)) == [arcClaim])

        #expect(try await transcriptRows(harness, meeting.id) == transcriptBefore)
    }
}

// MARK: - X-4: a withheld regeneration with a settle queued behind it

/// Gap: N3 SC-1/SC-3 own keep-and-flag in isolation and N4 owns chain gating
/// among its own steps; nobody owns the N4 continuation surviving N3's
/// early-return arm.
@Suite struct N6WithheldRegenerationWithQueuedSettleTests {
    @Test("X-4: a settle queued behind a withheld regeneration still delivers the KEPT notes once")
    func withheldRegenerationWithASettleQueuedBehindIt() async throws {
        let synthesisGate = EditorGate()
        let digestGate = EditorGate()
        let harness = try await makeSettleHarness()
        harness.engine.state.withLock {
            $0.notesSynthesisGate = synthesisGate
            $0.digestGate = digestGate
        }
        let meeting = try await seedSettleMeeting(harness, digest: arcDigestAssertingTheClaim)
        // Corrected notes: the claim is gone and its instruction is applied, so
        // an active retraction record stands.
        try await NotesRepository(database: harness.database).upsert(
            MeetingNotes(
                meetingID: meeting.id,
                markdown: try NotesRenderer.render(
                    arcNotesWithoutTheClaim(), language: "en", meetingTitle: meeting.title,
                    userName: UserIdentity.onboardedUser.name, annotations: []),
                structured: arcNotesWithoutTheClaim(), language: "en",
                generatedAt: harness.clock.now(),
                provenance: NotesProvenance(
                    engine: "seed", model: "seed", pipelineVersion: "seed", runtime: "seed",
                    rendererVersion: NotesRenderer.version, promptVersion: "seed"),
                memoryDigest: arcDigestAssertingTheClaim,
                digestPromptVersion: DigestPromptBuilder.shippedVersion.rawValue))
        _ = try await seedSettleCorrection(
            harness, meetingID: meeting.id, status: .applied, section: .detailedNotes,
            quotedText: arcClaim, userText: "That was never said.",
            createdAt: harness.clock.now())
        try await setDigestOwed(harness, meeting.id)
        try await setDeliveryOwed(harness, meeting.id)
        let notesBefore = try await storedNotes(harness, meeting.id)
        let transcriptBefore = try await transcriptRows(harness, meeting.id)

        // The regeneration would resurrect the claim; it suspends at the engine.
        harness.engine.state.withLock { $0.notesSyntheses = [arcNotesCarryingTheClaim()] }
        harness.engine.scriptDigest([[eraseTheClaimFromTheDigest()]])
        let regeneration = Task { try await harness.pipeline.rewriteNotes(meetingID: meeting.id) }
        await synthesisGate.waitUntilEntered()

        // The settle ENGAGES while the regeneration holds the chain: a sleeping
        // settle slot is armed FIRST, and `settleViewDetached` cancels that slot
        // as its very first action, so the slot's disappearance says the settle
        // invocation is running — the one thing "no digest call yet" cannot
        // distinguish from a settle that never started. Its exact position in
        // the chain queue is NOT observable test-side (the chain's internals are
        // private), so nothing here claims one; what the digest gate below
        // proves instead is the ordering the case is about.
        await harness.pipeline.settleViewAttached(meeting.id)
        #expect(
            await eventually { harness.settleClock.activeSleeperCount == 1 },
            "the slot is armed — the rendezvous instrument itself works")
        let settle = Task { await harness.pipeline.settleViewDetached(meeting.id) }
        #expect(
            await eventually { harness.settleClock.activeSleeperCount == 0 },
            "the settle is engaged while the regeneration holds the chain")
        #expect(harness.engine.digestCallCount == 0, "no digest step has begun")
        #expect(try await harness.queueRows(meeting.id) == 0, "nothing shipped while the chain is held")

        synthesisGate.release()
        _ = try await regeneration.value

        // The candidate was withheld: its bytes never became durable.
        let notesAfter = try await storedNotes(harness, meeting.id)
        #expect(notesAfter.structured == notesBefore.structured)
        #expect(!notesAfter.structured.detailedNotes.contains(arcClaim))
        #expect(
            !(try String(
                contentsOf: harness.database.paths.notesURL(meeting.id), encoding: .utf8)
                .contains(arcClaim)))
        let stored = try #require(
            try await MeetingRepository(database: harness.database).fetch(meeting.id))
        #expect(stored.processingNote == ProcessingPipeline.resurrectedClaimNote)
        #expect(stored.status == .ready)

        // The held digest gate is the deterministic proof of the ordering: the
        // settle's continuation reaches its digest step only AFTER the
        // regeneration's early return, with nothing delivered yet.
        await digestGate.waitUntilEntered()
        #expect(
            try await harness.queueRows(meeting.id) == 0,
            "the continuation is at its digest step and has delivered nothing")

        digestGate.release()
        await settle.value

        // The pre-existing settle debt still settles the KEPT notes, once.
        #expect(harness.engine.digestCallCount == 1, "the queued digest step ran after the release")
        #expect(harness.engine.notesCallCount == 0)
        #expect(try await harness.queueRows(meeting.id) == 1)
        let payload = try #require(try await deliveredPayloads(harness, meeting.id).last)
        #expect(
            try summaryMarkdown(payload)
                == expectedPayloadNotes(title: "Field-kit review", detailedNotes: arcAnchorLine))
        #expect(try retractedClaims(payload) == [arcClaim], "the record is intact")
        #expect(try #require(payload["memory_digest"] as? String) == arcDigestWithoutTheClaim)
        let settledNotes = try await storedNotes(harness, meeting.id)
        #expect(try #require(payload["memory_digest"] as? String) == settledNotes.memoryDigest)
        #expect(!settledNotes.deliveryOwed)

        #expect(try await transcriptRows(harness, meeting.id) == transcriptBefore)
    }
}
