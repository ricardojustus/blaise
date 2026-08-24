import Foundation
import Synchronization
import Testing

@testable import BlaiseCore

// N3 — the regeneration absence check. A claim the user's corrections removed
// from the notes must not come back through a later re-synthesis: the
// withdrawn set is derived from the stored notes, each withdrawn claim is
// searched once over the candidate, and a hit throws the candidate away.
//
// The helper suite pins the fold, the haystack's surfaces and the two set
// operations; the pipeline suite drives the gate through both install sites.

// MARK: - Fixtures (fictional universe only)

private func storedNotes(
    title: String? = "Sincronização do piloto",
    summary: String = "A Vexatron Labs revisou o cronograma.",
    detailedNotes: String = "O time discutiu o cronograma.\n\nO orçamento segue igual.",
    decisions: [String] = ["Manter o prazo de agosto"],
    actionItems: [ActionItem] = [ActionItem(owner: "Anna", text: "revisar o cronograma")],
    userActionItems: [ActionItem] = [ActionItem(owner: "Sam", text: "confirmar o orçamento")]
) -> NotesStructured {
    NotesStructured(
        title: title, summary: summary, detailedNotes: detailedNotes,
        decisions: decisions, actionItems: actionItems, userActionItems: userActionItems)
}

private func understanding(
    _ quote: String, section: MeetingCorrection.Section = .summary,
    status: MeetingCorrection.Status = .applied
) -> MeetingCorrection {
    MeetingCorrection(
        meetingID: "01J0000000000000000000000N", kind: .understanding, section: section,
        quotedText: quote, userText: "Isso nunca foi dito.", status: status,
        createdAt: Date(timeIntervalSince1970: 1_770_000_000))
}

/// The claim the user's corrections removed, used by every pipeline test: no
/// proper nouns, so no name pass can move its bytes.
private let removedClaim = "o piloto foi adiado para setembro"

@Suite struct N3AbsenceCheckHelperTests {

    // MARK: - SC-4: the fold and the containment boundary

    @Test("SC-4(a): case, CR/LF/CRLF and inline markdown tokens are one equivalence class")
    func foldEquivalenceClasses() {
        #expect(CorrectionAnchoring.fold("O **Piloto**\r\nfoi\r ADIADO\npara setembro")
            == "o piloto foi adiado para setembro")
        #expect(CorrectionAnchoring.fold("  o _piloto_  foi   adiado para setembro ")
            == removedClaim)
        // The equivalence is what makes a resurrection differing only in those
        // dimensions a HIT.
        let candidate = storedNotes(summary: "Resumo: o **PILOTO**\r\nfoi adiado para setembro.")
        #expect(
            CorrectionAnchoring.resurrectedClaim(
                withdrawn: [removedClaim],
                candidateHaystack: CorrectionAnchoring.foldedHaystack(
                    of: candidate, meetingTitle: "Reunião")) == removedClaim)
    }

    @Test("SC-4(b): an NFC needle finds NFD text — canonical containment")
    func canonicalEquivalenceMatches() {
        // Decomposed in the candidate, precomposed in the quote.
        let decomposed = storedNotes(summary: "A sessa\u{0303}o pre\u{0301}via ficou registrada.")
        let haystack = CorrectionAnchoring.foldedHaystack(
            of: decomposed, meetingTitle: "Reunião")
        #expect(
            CorrectionAnchoring.resurrectedClaim(
                withdrawn: ["sessão prévia"], candidateHaystack: haystack) == "sessão prévia")
    }

    @Test("SC-4(c): a markdown token sharing a grapheme with a combining scalar strips alone")
    func markdownTokenStripsScalarWiseAndTheCombiningMarkSurvives() {
        // "*" + U+0301 is ONE grapheme; the fold filters SCALARS, so the token
        // goes and the combining mark stays — the two strings are then NOT
        // fold-equivalent. Asserted exactly, as the accepted behavior.
        #expect(CorrectionAnchoring.fold("piloto a*\u{0301}b") == "piloto a\u{0301}b")
        #expect(CorrectionAnchoring.fold("piloto ab") == "piloto ab")
        #expect(CorrectionAnchoring.fold("piloto a*\u{0301}b") != CorrectionAnchoring.fold("piloto ab"))
        // Same shape for the invisible joiners.
        #expect(CorrectionAnchoring.fold("a_\u{034F}b") == "a\u{034F}b")
        #expect(CorrectionAnchoring.fold("a`\u{200C}b") == "a\u{200C}b")
    }

    @Test("SC-4(d): a genuinely reworded resurrection is NOT caught (disclosed false negative)")
    func rewordedResurrectionPasses() {
        let reworded = storedNotes(
            summary: "O lançamento do piloto escorregou para o mês de setembro.")
        #expect(
            CorrectionAnchoring.resurrectedClaim(
                withdrawn: [removedClaim],
                candidateHaystack: CorrectionAnchoring.foldedHaystack(
                    of: reworded, meetingTitle: "Reunião")) == nil)
    }

    @Test("SC-4(e): the withdrawn bytes inside a negating sentence still withhold (false positive)")
    func negatedResurrectionIsStillWithheld() {
        let negating = storedNotes(
            summary: "A versão anterior dizia que o piloto foi adiado para setembro, o que estava errado.")
        #expect(
            CorrectionAnchoring.resurrectedClaim(
                withdrawn: [removedClaim],
                candidateHaystack: CorrectionAnchoring.foldedHaystack(
                    of: negating, meetingTitle: "Reunião")) == removedClaim)
    }

    @Test("SC-4(f): a quote carrying the joiner is stripped BEFORE folding, leaving no seam")
    func separatorInAQuoteIsStrippedBeforeTheFold() {
        // Between two spaces: folding first would leave "alfa  beta" (two
        // spaces) after the strip and miss; stripping first collapses to one.
        let stored = storedNotes(summary: "O bloco alfa beta ficou no resumo.")
        let haystack = CorrectionAnchoring.foldedHaystack(of: stored, meetingTitle: "Reunião")
        #expect(
            CorrectionAnchoring.withdrawnClaims(
                corrections: [understanding("alfa \u{1F} beta")], currentHaystack: haystack)
                .isEmpty,
            "the quote's separator is out-of-band, and its removal leaves no two-space seam")
        // The same strip runs on the haystack side.
        let separatorInNotes = storedNotes(summary: "O bloco alfa \u{1F} beta ficou no resumo.")
        #expect(
            CorrectionAnchoring.withdrawnClaims(
                corrections: [understanding("alfa beta")],
                currentHaystack: CorrectionAnchoring.foldedHaystack(
                    of: separatorInNotes, meetingTitle: "Reunião")).isEmpty)
    }

    // MARK: - SC-5: the derivation and the haystack's surfaces

    @Test("SC-5: a quote still present anywhere in the haystack never withdraws")
    func presentQuotesNeverWithdraw() {
        let haystack = CorrectionAnchoring.foldedHaystack(
            of: storedNotes(), meetingTitle: "Reunião de agosto")
        let present = [
            "O time discutiu o cronograma",  // a detailed-notes block
            "Manter o prazo de agosto",  // a decision
            "revisar o cronograma",  // an action-item text
            "Sincronização do piloto",  // the effective H1
            "Anna",  // an action-item owner
            "Sam",  // a user-action-item owner
            "confirmar o orçamento",  // a user-action-item text
        ].map { understanding($0) }
        #expect(
            CorrectionAnchoring.withdrawnClaims(corrections: present, currentHaystack: haystack)
                .isEmpty)
        // …and one the notes no longer carry does withdraw.
        #expect(
            CorrectionAnchoring.withdrawnClaims(
                corrections: [understanding(removedClaim)], currentHaystack: haystack)
                == [removedClaim])
    }

    @Test("SC-5: a PENDING row whose quote an earlier pass erased DOES enter the withdrawn set")
    func pendingRowsAreNotExcluded() {
        let haystack = CorrectionAnchoring.foldedHaystack(
            of: storedNotes(), meetingTitle: "Reunião de agosto")
        #expect(
            CorrectionAnchoring.withdrawnClaims(
                corrections: [understanding(removedClaim, status: .pending)],
                currentHaystack: haystack) == [removedClaim])
        // The other status-blind cases, positively.
        #expect(
            CorrectionAnchoring.withdrawnClaims(
                corrections: [understanding(removedClaim, status: .resolved)],
                currentHaystack: haystack) == [removedClaim])
    }

    @Test("SC-5: an empty-fold quote and an annotation row never enter the set")
    func emptyFoldsAndAnnotationsNeverWithdraw() {
        let haystack = CorrectionAnchoring.foldedHaystack(
            of: storedNotes(), meetingTitle: "Reunião de agosto")
        let annotation = MeetingCorrection(
            meetingID: "01J0000000000000000000000N", kind: .annotation, section: .summary,
            quotedText: removedClaim, userText: "Conferir depois.",
            createdAt: Date(timeIntervalSince1970: 1_770_000_000))
        #expect(
            CorrectionAnchoring.withdrawnClaims(
                corrections: [understanding("  "), understanding("###"), annotation],
                currentHaystack: haystack).isEmpty)
    }

    @Test("SC-5: a claim surviving only in a SHADOWED meeting title is withdrawn")
    func shadowedMeetingTitleIsNotPartOfTheCorrectedNotes() {
        // The structured title flattens NON-empty, so it stands over
        // `meetingTitle`: the shadowed string renders nowhere.
        let haystack = CorrectionAnchoring.foldedHaystack(
            of: storedNotes(), meetingTitle: "Piloto adiado para setembro")
        #expect(
            CorrectionAnchoring.withdrawnClaims(
                corrections: [understanding("Piloto adiado para setembro")],
                currentHaystack: haystack) == ["Piloto adiado para setembro"])
    }

    @Test("SC-5: a claim reappearing only via the candidate's H1 FALLBACK is caught, both empty forms")
    func fallbackTitleIsSearchedOnTheCandidateSide() {
        let meetingTitle = "Piloto adiado para setembro"
        // Precondition: shadowed in the stored notes, so the claim is withdrawn.
        let stored = CorrectionAnchoring.foldedHaystack(
            of: storedNotes(), meetingTitle: meetingTitle)
        let withdrawn = CorrectionAnchoring.withdrawnClaims(
            corrections: [understanding(meetingTitle)], currentHaystack: stored)
        #expect(withdrawn == [meetingTitle])

        // A blank candidate title falls back to `meetingTitle` — and so does a
        // markdown-only one, because the renderer FLATTENS before testing.
        for emptyForm in ["", "   ", "###"] {
            let candidate = storedNotes(title: emptyForm)
            #expect(
                CorrectionAnchoring.resurrectedClaim(
                    withdrawn: withdrawn,
                    candidateHaystack: CorrectionAnchoring.foldedHaystack(
                        of: candidate, meetingTitle: meetingTitle)) == meetingTitle,
                "a \"\(emptyForm)\" structured title renders the meeting title as H1")
        }
        // A candidate title that flattens NON-empty shadows it again: the
        // claim reaches no installable surface, so nothing withholds.
        #expect(
            CorrectionAnchoring.resurrectedClaim(
                withdrawn: withdrawn,
                candidateHaystack: CorrectionAnchoring.foldedHaystack(
                    of: storedNotes(title: "Sincronização"), meetingTitle: meetingTitle)) == nil)
    }

    @Test("SC-5: an owner field and an untruncated candidate title are searched too")
    func ownerAndUntruncatedTitleAreInstallableSurfaces() {
        let haystack = CorrectionAnchoring.foldedHaystack(
            of: storedNotes(), meetingTitle: "Reunião de agosto")
        let withdrawn = CorrectionAnchoring.withdrawnClaims(
            corrections: [understanding("Quoll Harbor")], currentHaystack: haystack)
        #expect(withdrawn == ["Quoll Harbor"])

        // Only in an owner chip.
        let owner = storedNotes(
            userActionItems: [ActionItem(owner: "Quoll Harbor", text: "confirmar o orçamento")])
        #expect(
            CorrectionAnchoring.resurrectedClaim(
                withdrawn: withdrawn,
                candidateHaystack: CorrectionAnchoring.foldedHaystack(
                    of: owner, meetingTitle: "Reunião de agosto")) == "Quoll Harbor")

        // Only BEYOND the 80-character cut the H1 would display: the haystack
        // joins the untruncated structured title, so it is still found.
        let longTitle = String(repeating: "x", count: 90) + " Quoll Harbor"
        #expect(ProcessingPipeline.promotedLLMTitle(from: longTitle)?.contains("Quoll") == false)
        #expect(
            CorrectionAnchoring.resurrectedClaim(
                withdrawn: withdrawn,
                candidateHaystack: CorrectionAnchoring.foldedHaystack(
                    of: storedNotes(title: longTitle), meetingTitle: "Reunião de agosto"))
                == "Quoll Harbor")
    }

    @Test("SC-5: a claim only beyond the displayed cut of the STORED title is NOT withdrawn")
    func storedTitleIsSourceOfTruthNotItsRender() {
        // The structured record defines the corrected notes; the ≤80-character
        // H1 is a render of it.
        let longTitle = String(repeating: "x", count: 90) + " Quoll Harbor"
        let haystack = CorrectionAnchoring.foldedHaystack(
            of: storedNotes(title: longTitle), meetingTitle: "Reunião de agosto")
        #expect(
            CorrectionAnchoring.withdrawnClaims(
                corrections: [understanding("Quoll Harbor")], currentHaystack: haystack).isEmpty)
    }

    @Test("SC-5: the block joiner stops junction matches — and true split resurrections alike")
    func blockBoundaryIsATradeNotAWin() {
        let haystack = CorrectionAnchoring.foldedHaystack(
            of: storedNotes(), meetingTitle: "Reunião de agosto")
        let withdrawn = CorrectionAnchoring.withdrawnClaims(
            corrections: [understanding(removedClaim)], currentHaystack: haystack)
        #expect(withdrawn == [removedClaim])

        // The property: two adjacent blocks whose junction happens to spell the
        // claim do not match across the boundary.
        let junction = storedNotes(decisions: ["Sobre o piloto", "foi adiado para setembro"])
        #expect(
            CorrectionAnchoring.resurrectedClaim(
                withdrawn: withdrawn,
                candidateHaystack: CorrectionAnchoring.foldedHaystack(
                    of: junction, meetingTitle: "Reunião de agosto")) == nil)
        // The COST, in the same test: a genuine resurrection the candidate
        // re-paragraphed across a block boundary is invisible for exactly the
        // same reason (the disclosed structural false negative).
        let split = storedNotes(
            detailedNotes: "Resumo do dia: o piloto\n\nfoi adiado para setembro.")
        #expect(
            CorrectionAnchoring.resurrectedClaim(
                withdrawn: withdrawn,
                candidateHaystack: CorrectionAnchoring.foldedHaystack(
                    of: split, meetingTitle: "Reunião de agosto")) == nil)
    }
}

// MARK: - The gate, driven through both install sites

@Suite struct N3AbsenceCheckPipelineTests {

    /// Every event the pipeline emitted while `body` ran — the whole window,
    /// so a DUPLICATE terminal event is visible (breaking at the first
    /// `.runCompleted` would hide exactly the defect the sites' event rules
    /// exist to prevent).
    private func eventsDuring(
        _ harness: PipelineHarness, _ body: () async throws -> Void
    ) async throws -> [PipelineEvent] {
        let stream = await harness.pipeline.events()
        let collector = Task { () -> [PipelineEvent] in
            var events: [PipelineEvent] = []
            for await event in stream { events.append(event) }
            return events
        }
        try await body()
        try await Task.sleep(for: .milliseconds(200))
        collector.cancel()
        return await collector.value
    }

    private func notesRow(_ harness: PipelineHarness, _ id: MeetingID) async throws -> MeetingNotes {
        try #require(try await NotesRepository(database: harness.database).fetch(meetingID: id))
    }

    private func notesFile(_ harness: PipelineHarness, _ id: MeetingID) throws -> String {
        try String(contentsOf: harness.database.paths.notesURL(id), encoding: .utf8)
    }

    private func correction(
        _ harness: PipelineHarness, _ id: MeetingID, _ rowID: String
    ) async throws -> MeetingCorrection {
        try #require(
            try await harness.database.pool.read { db in
                try MeetingCorrection.fetchOne(db, key: rowID)
            })
    }

    /// A processed meeting carrying one understanding correction whose quoted
    /// text the notes no longer contain: the withdrawn claim.
    private func seedWithdrawnClaim(
        _ harness: PipelineHarness, _ meetingID: MeetingID
    ) async throws -> MeetingCorrection {
        try await harness.pipeline.addCorrection(
            meetingID: meetingID, kind: .understanding, section: .summary,
            quotedText: removedClaim, occurrence: 0,
            userText: "Isso nunca foi dito na reunião.").row
    }

    private func resurrect(_ harness: PipelineHarness) {
        harness.notesPrimary.state.withLock {
            $0.summary = "Resumo revisado: \(removedClaim)."
        }
    }

    // MARK: - SC-1 / SC-9: the rewrite path

    @Test("SC-1: a rewrite that restores a withdrawn claim keeps the notes and flags the meeting")
    func withheldRewriteKeepsEverything() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        try await harness.pipeline.process(meetingID: meeting.id)
        let before = try await notesRow(harness, meeting.id)
        let fileBefore = try notesFile(harness, meeting.id)
        let queueBefore = try await harness.queueRows(meeting.id)
        let segmentsBefore = try await harness.segments(meeting.id)
        let digestRequestsBefore = harness.notesPrimary.state.withLock { $0.digestRequests.count }
        let row = try await seedWithdrawnClaim(harness, meeting.id)
        resurrect(harness)

        let events = try await eventsDuring(harness) {
            _ = try await harness.pipeline.rewriteNotes(meetingID: meeting.id)
        }

        let after = try await notesRow(harness, meeting.id)
        #expect(after == before, "the stored notes row is byte-unchanged")
        #expect(after.generatedAt == before.generatedAt)
        #expect(after.memoryDigest == before.memoryDigest)
        #expect(
            harness.notesPrimary.state.withLock { $0.digestRequests.count }
                == digestRequestsBefore,
            "the gate runs BEFORE digest generation — no digest call was made")
        #expect(try notesFile(harness, meeting.id) == fileBefore)
        #expect(try notesFile(harness, meeting.id) == after.markdown)
        #expect(try await harness.queueRows(meeting.id) == queueBefore, "no new handoff row")
        #expect(try await correction(harness, meeting.id, row.id).status == row.status)
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.processingNote == ProcessingPipeline.resurrectedClaimNote)
        #expect(stored.status == .ready)
        // SC-10: the withheld path writes no notes-pending value.
        #expect(stored.lastProcessingError == nil)
        #expect(events.filter { $0 == .runCompleted(meeting.id) }.count == 1)

        // SC-9: the transcript is byte-identical across the withheld rewrite.
        #expect(try await harness.segments(meeting.id) == segmentsBefore)
    }

    @Test("SC-1: a raw label that resolves into the withdrawn claim is screened and withheld")
    func rawLabelResolvingIntoTheClaimIsWithheld() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        try await harness.pipeline.process(meetingID: meeting.id)
        // A shipped user rename names the label the candidate carries raw, so
        // the value stage 12 persists differs from the value the engine
        // returned — the screen must see the persisted one.
        _ = try await harness.pipeline.renameSpeaker(
            meetingID: meeting.id, speakerLabel: "S1", to: "Anna")
        let before = try await notesRow(harness, meeting.id)
        let namedClaim = "Anna disse que \(removedClaim)"
        _ = try await harness.pipeline.addCorrection(
            meetingID: meeting.id, kind: .understanding, section: .summary,
            quotedText: namedClaim, occurrence: 0, userText: "Isso nunca foi dito na reunião.")
        harness.notesPrimary.state.withLock {
            $0.summary = "Resumo revisado: S1 disse que \(removedClaim)."
        }

        _ = try await harness.pipeline.rewriteNotes(meetingID: meeting.id)

        let after = try await notesRow(harness, meeting.id)
        #expect(after == before, "nothing installed")
        #expect(!after.structured.summary.contains(namedClaim))
        #expect(
            try #require(try await harness.meeting(meeting.id)).processingNote
                == ProcessingPipeline.resurrectedClaimNote)
    }

    @Test("SC-2: a clean regeneration installs normally — the check adds nothing")
    func cleanRewriteInstalls() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        try await harness.pipeline.process(meetingID: meeting.id)
        let before = try await notesRow(harness, meeting.id)
        let queueBefore = try await harness.queueRows(meeting.id)
        let row = try await seedWithdrawnClaim(harness, meeting.id)
        harness.notesPrimary.state.withLock {
            $0.summary = "Resumo revisado sem a alegação removida."
        }

        _ = try await harness.pipeline.rewriteNotes(meetingID: meeting.id)

        let after = try await notesRow(harness, meeting.id)
        #expect(after != before)
        #expect(after.structured.summary.contains("Resumo revisado sem a alegação removida"))
        #expect(try notesFile(harness, meeting.id) == after.markdown)
        #expect(try await harness.queueRows(meeting.id) == queueBefore + 1)
        #expect(try await correction(harness, meeting.id, row.id).status == .applied)
        #expect(try #require(try await harness.meeting(meeting.id)).processingNote == nil)
    }

    // MARK: - SC-3: the full-run site

    @Test("SC-3: the full run's site withholds, keeps the re-transcribed segments, emits once")
    func withheldFullRunKeepsTheTranscript() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        try await harness.pipeline.process(meetingID: meeting.id)
        let before = try await notesRow(harness, meeting.id)
        let segmentsBefore = try await harness.segments(meeting.id)
        let queueBefore = try await harness.queueRows(meeting.id)
        let digestCallsBefore = harness.notesPrimary.state.withLock { $0.digestRequests.count }
        _ = try await seedWithdrawnClaim(harness, meeting.id)
        resurrect(harness)
        // THIS run re-transcribes to a sentinel the first run never produced,
        // so the surviving transcript is provably stage 11's output from this
        // run — not the old one left standing.
        let sentinel = "O cronograma do trimestre foi revisado."
        let sentinelWords = sentinel.split(separator: " ").enumerated().map { index, word in
            ASRWord(
                word: String(word), startSeconds: Double(index) * 0.2,
                endSeconds: Double(index) * 0.2 + 0.15)
        }
        harness.asr.state.withLock {
            $0.segments = [
                ASRSegment(
                    startSeconds: 0.0, endSeconds: 1.9, text: sentinel, words: sentinelWords)
            ]
        }

        let events = try await eventsDuring(harness) {
            _ = try await harness.pipeline.regenerate(meetingID: meeting.id)
        }

        // Stage 11 ran before the check: the transcript this run produced
        // stands, exactly as it does for a late-stage regeneration failure.
        let segmentsAfter = try await harness.segments(meeting.id)
        #expect(!segmentsAfter.isEmpty)
        #expect(segmentsAfter.contains { $0.text.contains(sentinel) })
        #expect(segmentsAfter.map(\.text) != segmentsBefore.map(\.text))
        // Nothing else moved.
        #expect(try await notesRow(harness, meeting.id) == before)
        #expect(try notesFile(harness, meeting.id) == before.markdown)
        #expect(try await harness.queueRows(meeting.id) == queueBefore)
        #expect(
            harness.notesPrimary.state.withLock { $0.digestRequests.count } == digestCallsBefore,
            "the check runs BEFORE digest generation")
        #expect(
            try #require(try await harness.meeting(meeting.id)).processingNote
                == ProcessingPipeline.resurrectedClaimNote)
        // The full site emits nothing itself; the outer wrapper owns the one
        // terminal event (a second emit would duplicate it).
        #expect(events.filter { $0 == .runCompleted(meeting.id) }.count == 1)
    }

    // MARK: - SC-6: no self-heal loop

    @Test("SC-6: a withheld resume clears the parked marker, so the self-heal stops re-firing")
    func withheldResumeClearsTheMarker() async throws {
        let harness = try await makePipelineHarness(
            fallbackLoadProfile: .heavyweight(estimatedPeakBytes: 18 * 1_073_741_824))
        let meeting = try await harness.importTestMeeting()
        try await harness.pipeline.process(meetingID: meeting.id)
        let before = try await notesRow(harness, meeting.id)
        _ = try await seedWithdrawnClaim(harness, meeting.id)

        // Park the meeting on the notes-pending marker.
        harness.notesPrimary.state.withLock { $0.error = .configurationMissing(key: "apiKey") }
        _ = try await harness.pipeline.rewriteNotes(meetingID: meeting.id)
        #expect(
            NotesPendingClass.isPending(
                try #require(try await harness.meeting(meeting.id)).lastProcessingError))

        // The self-heal resume now produces a resurrection.
        harness.notesPrimary.state.withLock { $0.error = nil }
        resurrect(harness)
        await harness.pipeline.resumePendingNotes()

        let healed = try #require(try await harness.meeting(meeting.id))
        #expect(healed.lastProcessingError == nil, "the doomed retry loop is retired")
        #expect(healed.processingNote == ProcessingPipeline.resurrectedClaimNote)
        #expect(try await notesRow(harness, meeting.id) == before)
        #expect(try notesFile(harness, meeting.id) == before.markdown)

        // …and the next enumeration dispatches nothing for it.
        let callsBefore = harness.notesPrimary.state.withLock { $0.requests.count }
        await harness.pipeline.resumePendingNotes()
        try await Task.sleep(for: .milliseconds(200))
        #expect(harness.notesPrimary.state.withLock { $0.requests.count } == callsBefore)
    }

    @Test("SC-6: a withheld verdict converges a diverged notes.md")
    func withheldConvergesADivergedFile() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        try await harness.pipeline.process(meetingID: meeting.id)
        let row = try await notesRow(harness, meeting.id)
        _ = try await seedWithdrawnClaim(harness, meeting.id)
        // The file behind the row is the state three shipped windows can leave
        // behind; the withheld path's re-assert is what converges it.
        try Data("STALE FILE — the row moved on\n".utf8)
            .write(to: harness.database.paths.notesURL(meeting.id), options: .atomic)
        resurrect(harness)

        _ = try await harness.pipeline.rewriteNotes(meetingID: meeting.id)

        let after = try await notesRow(harness, meeting.id)
        #expect(after == row)
        #expect(try notesFile(harness, meeting.id) == after.markdown)
    }

    @Test("SC-6: the clear is notes-pending-scoped — a digest-pending marker survives it")
    func digestPendingMarkerSurvivesTheClear() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        try await harness.pipeline.process(meetingID: meeting.id)
        _ = try await seedWithdrawnClaim(harness, meeting.id)
        let digestMarker = DigestPendingClass.marker("mock digest failure")
        try await harness.database.pool.write { db in
            try db.execute(
                sql: "UPDATE meeting SET last_processing_error = ? WHERE id = ?",
                arguments: [digestMarker, meeting.id])
        }
        resurrect(harness)

        _ = try await harness.pipeline.rewriteNotes(meetingID: meeting.id)

        #expect(
            try #require(try await harness.meeting(meeting.id)).lastProcessingError
                == digestMarker)
    }

    @Test("SC-6: a capture-recovery note outranks the withheld notice")
    func captureRecoveryNoteWins() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        try await harness.pipeline.process(meetingID: meeting.id)
        _ = try await seedWithdrawnClaim(harness, meeting.id)
        let recoveryNote = "\(CaptureRecovery.notePrefix) trilha do mic — transcrição parcial"
        try await harness.database.pool.write { db in
            try db.execute(
                sql: "UPDATE meeting SET processing_note = ? WHERE id = ?",
                arguments: [recoveryNote, meeting.id])
        }
        resurrect(harness)

        _ = try await harness.pipeline.rewriteNotes(meetingID: meeting.id)

        #expect(
            try #require(try await harness.meeting(meeting.id)).processingNote == recoveryNote)
    }

    // MARK: - SC-10: the class and cancellation boundaries

    @Test("SC-10: a process-class run never withholds")
    func processClassRunsAreExempt() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        try await harness.pipeline.process(meetingID: meeting.id)
        _ = try await seedWithdrawnClaim(harness, meeting.id)
        resurrect(harness)

        // The public process() entry — no in-app caller reaches it on a
        // notes-bearing meeting; the gate excludes it because an early return
        // would strand a `.processing` meeting.
        _ = try await harness.pipeline.process(meetingID: meeting.id)

        let after = try await notesRow(harness, meeting.id)
        #expect(after.structured.summary.contains(removedClaim), "the candidate installed")
        #expect(try #require(try await harness.meeting(meeting.id)).processingNote == nil)
    }

    @Test("SC-10: a cancellation before the verdict does no withheld bookkeeping and installs nothing")
    func cancellationBeatsTheVerdict() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        try await harness.pipeline.process(meetingID: meeting.id)
        let before = try await notesRow(harness, meeting.id)
        _ = try await seedWithdrawnClaim(harness, meeting.id)
        resurrect(harness)
        // Cancel from inside the engine call — the token is set before the
        // candidate reaches the gate.
        let pipeline = harness.pipeline
        let meetingID = meeting.id
        harness.notesPrimary.state.withLock { state in
            state.onGenerate = { _ = await pipeline.cancel(meetingID: meetingID) }
        }

        do {
            _ = try await harness.pipeline.rewriteNotes(meetingID: meeting.id)
            Issue.record("a cancelled rewrite must not complete")
        } catch let error as PipelineError {
            #expect(
                error.stage == .persistNotes,
                "the run dies at the next existing cancellation checkpoint")
        }

        // The run died at the existing checkpoint: previous notes intact, and
        // NO withheld bookkeeping ran.
        #expect(try await notesRow(harness, meeting.id) == before)
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.processingNote != ProcessingPipeline.resurrectedClaimNote)
        #expect(stored.status == .ready)
    }

    /// The gate seam's shared state: the run to cancel, and whether the pin is
    /// armed (the setup runs pass through the gate too).
    private final class GateCancel: @unchecked Sendable {
        private let state = Mutex<(pipeline: ProcessingPipeline?, armed: Bool)>((nil, false))
        func bind(_ pipeline: ProcessingPipeline) { state.withLock { $0.pipeline = pipeline } }
        func arm() { state.withLock { $0.armed = true } }
        fileprivate func target() -> ProcessingPipeline? {
            state.withLock { $0.armed ? $0.pipeline : nil }
        }
    }

    /// A harness whose gate cancels the run at `phase`, once armed. The seam
    /// replaces a race: the gate's own database awaits are cancellation-aware,
    /// so the window has to be entered deliberately.
    private func makeGateCancellingHarness(
        at phase: ProcessingPipeline.ResurrectionGatePhase, _ arm: GateCancel
    ) async throws -> PipelineHarness {
        let harness = try await makePipelineHarness(
            duringResurrectionGate: { meetingID, reached in
                guard reached == phase, let pipeline = arm.target() else { return }
                _ = await pipeline.cancel(meetingID: meetingID)
            })
        arm.bind(harness.pipeline)
        return harness
    }

    @Test("SC-10: a full-run cancel landing on the gate's stored-row read withholds nothing")
    func cancellationAtTheStoredRowRead() async throws {
        let arm = GateCancel()
        let harness = try await makeGateCancellingHarness(at: .beforeStoredRead, arm)
        let meeting = try await harness.importTestMeeting()
        try await harness.pipeline.process(meetingID: meeting.id)
        let before = try await notesRow(harness, meeting.id)
        let fileBefore = try notesFile(harness, meeting.id)
        let digestsBefore = harness.notesPrimary.state.withLock { $0.digestRequests.count }
        _ = try await seedWithdrawnClaim(harness, meeting.id)
        resurrect(harness)
        arm.arm()

        do {
            _ = try await harness.pipeline.regenerate(meetingID: meeting.id)
            Issue.record("a cancelled regeneration must not complete")
        } catch {}

        // The cancel was absorbed by the gate and owned by the existing
        // checkpoint: no withheld bookkeeping, and nothing installed.
        #expect(try await notesRow(harness, meeting.id) == before)
        #expect(try notesFile(harness, meeting.id) == fileBefore)
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.processingNote != ProcessingPipeline.resurrectedClaimNote)
        #expect(stored.status == .ready)
        // Attribution, exactly: the gate returned "proceed" and the run was
        // recorded by the next checkpoint it reached, under the stage the run
        // had last ENTERED — the gate itself sits outside any stage wrapper.
        #expect(stored.lastProcessingError == "persistTranscript: cancelled")
        #expect(
            harness.notesPrimary.state.withLock { $0.digestRequests.count } == digestsBefore,
            "no digest was generated for the cancelled run")
    }

    @Test("SC-10: a cancel inside the candidate re-derivation is pre-verdict, not a withheld verdict")
    func cancellationInsideTheCandidateDerivation() async throws {
        let arm = GateCancel()
        let harness = try await makeGateCancellingHarness(at: .duringCandidateDerivation, arm)
        let meeting = try await harness.importTestMeeting()
        try await harness.pipeline.process(meetingID: meeting.id)
        let before = try await notesRow(harness, meeting.id)
        _ = try await seedWithdrawnClaim(harness, meeting.id)
        // Parked on the self-heal marker, with the file behind the row: the
        // marker clear and the file re-assert are both observable, so a verdict
        // reached under a cancelled token cannot hide.
        try await harness.database.pool.write { db in
            try db.execute(
                sql: "UPDATE meeting SET last_processing_error = ? WHERE id = ?",
                arguments: [NotesPendingClass.marker("mock notes failure"), meeting.id])
        }
        let staleFile = "STALE FILE\n"
        try Data(staleFile.utf8)
            .write(to: harness.database.paths.notesURL(meeting.id), options: .atomic)
        resurrect(harness)
        arm.arm()

        let events = try await eventsDuring(harness) {
            _ = try? await harness.pipeline.rewriteNotes(meetingID: meeting.id)
        }

        #expect(try await notesRow(harness, meeting.id) == before, "nothing installed")
        #expect(try notesFile(harness, meeting.id) == staleFile, "no file re-assert ran")
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.processingNote != ProcessingPipeline.resurrectedClaimNote)
        #expect(
            NotesPendingClass.isPending(stored.lastProcessingError),
            "the self-heal marker was not retired by a cancelled run")
        #expect(
            events.filter { $0 == .runCompleted(meeting.id) }.isEmpty,
            "a cancelled run must not report a clean completion")
    }

    @Test("SC-10: a full-run cancel landing after the verdict still completes the bookkeeping")
    func cancellationAfterTheVerdictCompletesTheBookkeeping() async throws {
        let arm = GateCancel()
        let harness = try await makeGateCancellingHarness(at: .afterVerdict, arm)
        let meeting = try await harness.importTestMeeting()
        try await harness.pipeline.process(meetingID: meeting.id)
        let before = try await notesRow(harness, meeting.id)
        _ = try await seedWithdrawnClaim(harness, meeting.id)
        // A parked marker and a stale file, so every write of the bookkeeping
        // is observable.
        try await harness.database.pool.write { db in
            try db.execute(
                sql: "UPDATE meeting SET last_processing_error = ? WHERE id = ?",
                arguments: [NotesPendingClass.marker("mock notes failure"), meeting.id])
        }
        try Data("STALE FILE\n".utf8)
            .write(to: harness.database.paths.notesURL(meeting.id), options: .atomic)
        resurrect(harness)
        arm.arm()

        _ = try? await harness.pipeline.regenerate(meetingID: meeting.id)

        let after = try #require(try await harness.meeting(meeting.id))
        #expect(after.lastProcessingError == nil, "the marker clear committed")
        #expect(after.processingNote == ProcessingPipeline.resurrectedClaimNote)
        #expect(try await notesRow(harness, meeting.id) == before)
        #expect(try notesFile(harness, meeting.id) == before.markdown)
    }

    // MARK: - SC-7 / SC-8: the shipped substrate, pinned

    @Test("SC-7: both synthesis seams inject every understanding row, any status, in store order")
    func bothSeamsInjectEveryUnderstandingRow() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        try await harness.pipeline.process(meetingID: meeting.id)
        // First row, consumed by a rewrite → `applied`.
        _ = try await harness.pipeline.addCorrection(
            meetingID: meeting.id, kind: .understanding, section: .summary,
            quotedText: "Resumo", occurrence: 0, userText: "Na verdade foi terça.")
        _ = try await harness.pipeline.rewriteNotes(meetingID: meeting.id)
        // Second row, still `pending`, plus a margin note that never injects.
        _ = try await harness.pipeline.addCorrection(
            meetingID: meeting.id, kind: .understanding, section: .summary,
            quotedText: "Resumo", occurrence: 0, userText: "O prazo é agosto.")
        _ = try await harness.pipeline.addCorrection(
            meetingID: meeting.id, kind: .annotation, section: .summary,
            quotedText: "Resumo", occurrence: 0, userText: "Conferir com Anna.")
        let expected = ["Na verdade foi terça.", "O prazo é agosto."]

        // The notes-only seam.
        _ = try await harness.pipeline.rewriteNotes(meetingID: meeting.id)
        #expect(
            harness.notesPrimary.state.withLock { $0.requests.last }?.corrections
                .map(\.userText) == expected)
        // The full run's stage-9 seam.
        _ = try await harness.pipeline.regenerate(meetingID: meeting.id)
        let request = try #require(harness.notesPrimary.state.withLock { $0.requests.last })
        #expect(request.corrections.map(\.userText) == expected)
        #expect(request.corrections.allSatisfy { $0.kind == .understanding })
    }

    @Test("SC-8: a clean regeneration re-weaves the anchored aside and the orphan tail")
    func regenerationReweavesAnnotations() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        try await harness.pipeline.process(meetingID: meeting.id)
        let anchored = try await harness.pipeline.addCorrection(
            meetingID: meeting.id, kind: .annotation, section: .summary,
            quotedText: "Resumo da reunião de teste.", occurrence: 0,
            userText: "Confirmar o prazo com Anna.").row
        let orphan = try await harness.pipeline.addCorrection(
            meetingID: meeting.id, kind: .annotation, section: .summary,
            quotedText: "um parágrafo que sumiu", occurrence: 0,
            userText: "Conferir depois.").row

        try await harness.pipeline.regenerate(meetingID: meeting.id)

        let notes = try await notesRow(harness, meeting.id)
        #expect(notes.markdown.contains("> **Sua nota:** Confirmar o prazo com Anna."))
        #expect(notes.markdown.contains("## Suas notas"))
        #expect(notes.markdown.contains("Conferir depois."))
        #expect(try await correction(harness, meeting.id, anchored.id).status == .applied)
        #expect(try await correction(harness, meeting.id, orphan.id).status == .stale)
    }
}
