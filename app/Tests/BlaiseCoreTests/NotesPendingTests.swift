import Foundation
import Synchronization
import Testing
@testable import BlaiseCore

// D17: lightweight-only auto-fallback, the notes-pending outcome, and the
// notes-only self-heal resume — all with mock engines (no models, no
// network, no gated runs).

@Suite struct NotesPendingTests {
    /// Drives a fresh harness meeting into the notes-pending state: the
    /// primary throws a fallback trigger and the only fallback is
    /// heavyweight (never auto-loaded).
    private func makePendingMeeting(
        trigger: EngineError = .configurationMissing(key: "apiKey")
    ) async throws -> (PipelineHarness, Meeting, PipelineRunRecord) {
        let harness = try await makePipelineHarness(
            fallbackLoadProfile: .heavyweight(estimatedPeakBytes: 18 * 1_073_741_824))
        let meeting = try await harness.importTestMeeting()
        harness.notesPrimary.state.withLock { $0.error = trigger }
        let record = try await harness.pipeline.process(meetingID: meeting.id)
        return (harness, meeting, record)
    }

    // MARK: - The pending outcome (auto-fallback never loads heavyweight)

    @Test func heavyweightOnlyFallbackResolvesToNotesPending() async throws {
        let (harness, meeting, record) = try await makePendingMeeting()

        // The run COMPLETED (no throw); the record carries the pending reason.
        #expect(record.notesPending == "configuration missing: apiKey")
        #expect(record.fallback == nil)
        #expect(record.notesEngineID == nil)

        // The heavyweight fallback was NEVER prepared or invoked.
        #expect(harness.notesFallback.state.withLock { $0.prepareCalls } == 0)
        #expect(harness.notesFallback.state.withLock { $0.requests.isEmpty })

        // Meeting state: distinguishable via the reserved marker; NOT ready.
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.status == .failed)
        #expect(NotesPendingClass.isPending(stored.lastProcessingError))
        #expect(stored.processingNote == nil, "pending is not a fallback note")

        // Transcript persisted and visible; notes absent; NO handoff row
        // (ready ⇒ queued holds: the meeting is not ready).
        let segments = try await harness.segments(meeting.id)
        #expect(!segments.isEmpty)
        let notes = try await NotesRepository(database: harness.database)
            .fetch(meetingID: meeting.id)
        #expect(notes == nil)
        #expect(try await harness.queueRows(meeting.id) == 0)
        // Retained audio untouched (hard floor 2).
        #expect(
            FileManager.default.fileExists(
                atPath: harness.database.paths.audioURL(meeting.id).path))
    }

    @Test func everyFallbackTriggerResolvesToPendingWithHeavyweightFallback() async throws {
        let triggers: [EngineError] = [
            .permanent(EngineFallbackReason.inputTooLong),
            .permanent(EngineFallbackReason.outOfMemory),
            .notAvailable(reason: EngineFallbackReason.monthlyCeiling),
            .notAvailable(reason: EngineFallbackReason.insufficientMemory),
        ]
        for trigger in triggers {
            let (_, _, record) = try await makePendingMeeting(trigger: trigger)
            #expect(record.notesPending != nil, "expected pending for \(trigger)")
        }
    }

    @Test func lightweightFallbackStillHops() async throws {
        // Both engines lightweight (the harness default): the one-hop
        // fallback fires exactly as before D17.
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        harness.notesPrimary.state.withLock {
            $0.error = .permanent(EngineFallbackReason.inputTooLong)
        }
        let record = try await harness.pipeline.process(meetingID: meeting.id)
        #expect(record.notesPending == nil)
        #expect(record.fallback?.fallbackEngineID == "pipeline-mock-notes-fallback")
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.status == .ready)
        #expect(try await harness.queueRows(meeting.id) == 1)
    }

    @Test func suppressAutoFallbackPrimaryGoesPendingDespiteLightweightFallback() async throws {
        // Decision B ("stay free, but not silent"): the user-SELECTED primary
        // suppresses auto-fallback (the subscription `claude -p` engine). Even
        // though a LIGHTWEIGHT fallback is registered (which would normally hop),
        // a fallback-trigger failure leaves the notes PENDING with a warning — it
        // is NEVER silently routed to the metered/other engine. The pending reason
        // names the engine + cause so the marker is user-visible.
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        harness.notesPrimary.state.withLock {
            $0.suppressesAutoFallback = true
            $0.error = .configurationMissing(key: "oauthToken")
        }
        let record = try await harness.pipeline.process(meetingID: meeting.id)

        // Pending, not a fallback hop: the record carries the reason and NO
        // fallback record; the fallback engine was never invoked.
        #expect(record.notesPending != nil)
        #expect(
            record.notesPending?.contains("pipeline-mock-notes-primary") == true,
            "the pending reason names the selected engine")
        #expect(record.fallback == nil)
        #expect(record.notesEngineID == nil)
        #expect(
            harness.notesFallback.state.withLock { $0.requests.isEmpty },
            "the fallback engine is NEVER invoked when the primary suppresses auto-fallback")

        // Meeting state mirrors the heavyweight-pending terminal: failed + marker,
        // no notes, no handoff row.
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.status == .failed)
        #expect(NotesPendingClass.isPending(stored.lastProcessingError))
        let notes = try await NotesRepository(database: harness.database)
            .fetch(meetingID: meeting.id)
        #expect(notes == nil)
        #expect(try await harness.queueRows(meeting.id) == 0)
    }

    @Test func nonSuppressingPrimaryStillHopsToLightweightFallback() async throws {
        // Control for the above: with `suppressesAutoFallback` left at the default
        // `false`, the SAME trigger hops to the lightweight fallback (unchanged
        // behavior for the cloud/local engines).
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        harness.notesPrimary.state.withLock {
            $0.error = .configurationMissing(key: "apiKey")
        }
        let record = try await harness.pipeline.process(meetingID: meeting.id)
        #expect(record.notesPending == nil)
        #expect(record.fallback?.fallbackEngineID == "pipeline-mock-notes-fallback")
        #expect(!harness.notesFallback.state.withLock { $0.requests.isEmpty })
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.status == .ready)
    }

    @Test func deliberateHeavyweightPrimarySelectionStillRuns() async throws {
        // A heavyweight engine as the user-selected PRIMARY runs (its own
        // memory gate is the engine's concern, exercised in the MLX tests).
        let harness = try await makePipelineHarness(
            primaryLoadProfile: .heavyweight(estimatedPeakBytes: 18 * 1_073_741_824))
        let meeting = try await harness.importTestMeeting()
        let record = try await harness.pipeline.process(meetingID: meeting.id)
        #expect(record.notesPending == nil)
        #expect(record.notesEngineID == "pipeline-mock-notes-primary")
        #expect(record.fallback == nil)
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.status == .ready)
    }

    @Test func regenerationPendingKeepsReadyAndOldNotes() async throws {
        // Ready meeting (successful run), then a regeneration whose notes
        // stage goes pending: status stays ready (C1 no-regress), the OLD
        // notes survive, the marker surfaces the mixed generation.
        let harness = try await makePipelineHarness(
            fallbackLoadProfile: .heavyweight(estimatedPeakBytes: 18 * 1_073_741_824))
        let meeting = try await harness.importTestMeeting()
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        harness.notesPrimary.state.withLock {
            $0.error = .notAvailable(reason: EngineFallbackReason.monthlyCeiling)
        }
        let record = try await harness.pipeline.regenerate(meetingID: meeting.id)
        #expect(record.notesPending == EngineFallbackReason.monthlyCeiling)
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.status == .ready)
        #expect(NotesPendingClass.isPending(stored.lastProcessingError))
        let notes = try await NotesRepository(database: harness.database)
            .fetch(meetingID: meeting.id)
        #expect(notes != nil, "previous notes survive a pending regeneration")
        #expect(try await harness.queueRows(meeting.id) == 1, "no second enqueue without a finalize")
    }

    // MARK: - Notes-only resume (self-heal)

    @Test func processNotesOnlyResumesPendingMeetingAndFinalizes() async throws {
        let (harness, meeting, _) = try await makePendingMeeting()
        // Heal the primary (the user pasted the API key).
        harness.notesPrimary.state.withLock { $0.error = nil }

        let record = try #require(
            try await harness.pipeline.processNotesOnly(meetingID: meeting.id))
        #expect(record.notesPending == nil)
        #expect(record.notesEngineID == "pipeline-mock-notes-primary")

        // Finalized: notes persisted, status ready, marker cleared, handoff
        // enqueued — all by the one finalize transaction.
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.status == .ready)
        #expect(stored.lastProcessingError == nil)
        let notes = try #require(
            try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id))
        #expect(!notes.markdown.isEmpty)
        #expect(notes.provenance.pipelineVersion == PipelineVersion.current)
        #expect(try await harness.queueRows(meeting.id) == 1)
        // notes.md + payload exported like a full run.
        #expect(
            FileManager.default.fileExists(
                atPath: harness.database.paths.notesURL(meeting.id).path))
        let payloadURL = harness.database.rootURL.appendingPathComponent(
            try #require(record.payloadPath))
        #expect(FileManager.default.fileExists(atPath: payloadURL.path))
    }

    @Test func resumeRebuildsTheSamePromptInputsAsStageNine() async throws {
        let (harness, meeting, _) = try await makePendingMeeting()
        harness.notesPrimary.state.withLock { $0.error = nil }
        _ = try await harness.pipeline.processNotesOnly(meetingID: meeting.id)

        let requests = harness.notesPrimary.state.withLock { $0.requests }
        #expect(requests.count == 2, "stage-9 attempt + resume attempt")
        let original = try #require(requests.first)
        let resumed = try #require(requests.last)
        // The regression-pin-relevant inputs are identical: same transcript
        // CONTENT (the pending run applied no LLM names; the resumed
        // segments carry DB row ids — pin-irrelevant bookkeeping, erased
        // exactly as the committed pins erase it), same language,
        // vocabulary, user — and the two requests assemble byte-identical
        // prompts.
        #expect(resumed.transcript.map(PinnedSegment.init) == original.transcript.map(PinnedSegment.init))
        #expect(resumed.dominantLanguage == original.dominantLanguage)
        #expect(resumed.vocabulary == original.vocabulary)
        #expect(resumed.user == original.user)
        #expect(
            NotesPromptBuilder.userMessage(for: resumed)
                == NotesPromptBuilder.userMessage(for: original))
    }

    @Test func resumeAppliesLLMNamesToThePersistedTranscript() async throws {
        let (harness, meeting, _) = try await makePendingMeeting()
        harness.notesPrimary.state.withLock { state in
            state.error = nil
            state.mapping = [
                // Transcript-verbatim name ("Fábio" occurs in segment text).
                SpeakerNameProposal(
                    label: "S1", name: "Fábio", confidence: .high,
                    evidence: "O Fábio vai mandar o contrato.")
            ]
        }
        _ = try await harness.pipeline.processNotesOnly(meetingID: meeting.id)
        let segments = try await harness.segments(meeting.id)
        let named = segments.filter { $0.speakerName != nil }
        #expect(!named.isEmpty)
        #expect(named.allSatisfy { $0.speakerLabel == "S1" && $0.speakerName == "Fábio" })
    }

    @Test func processNotesOnlyNoOpsWhenNotPending() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        let callsBefore = harness.notesPrimary.state.withLock { $0.requests.count }

        let record = try await harness.pipeline.processNotesOnly(meetingID: meeting.id)
        #expect(record == nil, "ready meeting without the marker → no-op")
        #expect(harness.notesPrimary.state.withLock { $0.requests.count } == callsBefore)
        #expect(try await harness.queueRows(meeting.id) == 1)
    }

    @Test func concurrentResumesRunExactlyOnce() async throws {
        // Race safety: re-dispatch is serialized by the pipeline's
        // single-flight chain; the second resume sees the first's terminal
        // state (marker gone) and no-ops.
        let (harness, meeting, _) = try await makePendingMeeting()
        harness.notesPrimary.state.withLock { $0.error = nil }

        async let first = harness.pipeline.processNotesOnly(meetingID: meeting.id)
        async let second = harness.pipeline.processNotesOnly(meetingID: meeting.id)
        let firstRecord = try await first
        let secondRecord = try await second
        #expect(
            [firstRecord, secondRecord].compactMap { $0 }.count == 1,
            "exactly one resume runs; the other no-ops")
        // 1 stage-9 attempt (pending run) + 1 resume generation.
        #expect(harness.notesPrimary.state.withLock { $0.requests.count } == 2)
        #expect(try await harness.queueRows(meeting.id) == 1)
    }

    @Test func resumeFailureKeepsTheMeetingPending() async throws {
        let (harness, meeting, _) = try await makePendingMeeting()
        // Non-trigger failure (e.g. a network blip): the resume throws, but
        // the meeting STAYS pending so the next trigger retries.
        harness.notesPrimary.state.withLock { $0.error = .transient("network blip") }
        await #expect(throws: PipelineError.self) {
            try await harness.pipeline.processNotesOnly(meetingID: meeting.id)
        }
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(NotesPendingClass.isPending(stored.lastProcessingError))
        #expect(stored.lastProcessingError == NotesPendingClass.marker("network blip"))
        #expect(stored.status == .failed)
        #expect(try await harness.queueRows(meeting.id) == 0)
    }

    @Test func resumePendingNotesKicksOnlyPendingMeetings() async throws {
        // The trigger entry (launch / key save / network): finds marked
        // meetings, resumes them, leaves healthy meetings alone.
        let harness = try await makePipelineHarness(
            fallbackLoadProfile: .heavyweight(estimatedPeakBytes: 18 * 1_073_741_824))
        let healthy = try await harness.importTestMeeting()
        _ = try await harness.pipeline.process(meetingID: healthy.id)

        let pending = try await harness.importTestMeeting()
        harness.notesPrimary.state.withLock { $0.error = .configurationMissing(key: "apiKey") }
        _ = try await harness.pipeline.process(meetingID: pending.id)
        harness.notesPrimary.state.withLock { $0.error = nil }
        let callsBefore = harness.notesPrimary.state.withLock { $0.requests.count }

        await harness.pipeline.resumePendingNotes()

        let healed = try #require(try await harness.meeting(pending.id))
        #expect(healed.status == .ready)
        #expect(healed.lastProcessingError == nil)
        #expect(try await harness.queueRows(pending.id) == 1)
        // Exactly ONE new generation (the pending meeting); the healthy one
        // was not re-dispatched.
        #expect(harness.notesPrimary.state.withLock { $0.requests.count } == callsBefore + 1)
    }

    @Test func resumeAbsorbsRosterQueuedWhilePending() async throws {
        // A Meet roster flushed while the meeting sat pending lands in
        // `meet_roster_pending` (ingestion never mutates the meeting row)
        // and the full run's absorption point is bypassed by the resume —
        // so the resume itself absorbs: the late attendee must reach the
        // notes prompt, the request, and the minted payload, and the
        // queued rows must be consumed.
        let (harness, meeting, _) = try await makePendingMeeting()
        try await harness.database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO meet_roster_pending
                        (meeting_id, display_name, display_name_folded, participant_id, is_self)
                    VALUES (?, ?, ?, ?, 0)
                    """,
                arguments: [
                    meeting.id, "Marina Souza",
                    VocabNormalization.canonicalMode("Marina Souza"), "pid-marina",
                ])
        }
        harness.notesPrimary.state.withLock { $0.error = nil }

        let record = try #require(
            try await harness.pipeline.processNotesOnly(meetingID: meeting.id))

        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(
            stored.attendees.contains {
                $0.name == "Marina Souza" && $0.source == .meetExtension
            })
        let resumed = try #require(harness.notesPrimary.state.withLock { $0.requests.last })
        #expect(resumed.meeting.attendees.contains { $0.name == "Marina Souza" })
        #expect(NotesPromptBuilder.userMessage(for: resumed).contains("Marina Souza"))
        let payloadURL = harness.database.rootURL.appendingPathComponent(
            try #require(record.payloadPath))
        let payload = try String(contentsOf: payloadURL, encoding: .utf8)
        #expect(payload.contains("Marina Souza"))
        let rosterRows = try await harness.database.pool.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM meet_roster_pending WHERE meeting_id = ?",
                arguments: [meeting.id]) ?? -1
        }
        #expect(rosterRows == 0, "queued roster rows are consumed by the resume")
    }

    @Test func kickRacingAResumeNeverRegressesTheHealedMeeting() async throws {
        // M-4 (D17 audit): `dispatchProcessing` takes its process-vs-
        // regenerate decision INSIDE the chained body. Interleaving is
        // pinned via the mock seams (no sleeps): the resume parks inside
        // its notes generation while the kick is issued — the meeting
        // still reads failed+marker at issue time — then the resume
        // completes (failed → ready) and the kick's body runs. The kick's
        // own run is forced to fail at notes (ASR seam re-arms the error;
        // ASR runs only in the kick's body): under C1 no-regress a
        // regeneration-class failure keeps `ready`, while a stale
        // process()-class run would land the healed meeting on `failed`.
        let (harness, meeting, _) = try await makePendingMeeting()
        harness.notesPrimary.state.withLock { $0.error = nil }

        let resumeEntered = OneShotGate()
        let releaseResume = OneShotGate()
        harness.notesPrimary.state.withLock { state in
            state.onGenerate = {
                resumeEntered.open()
                try? await releaseResume.wait()
            }
        }
        harness.asr.state.withLock { state in
            state.onTranscribe = { [notesPrimary = harness.notesPrimary] in
                notesPrimary.state.withLock { $0.error = .transient("kick-run blip") }
            }
        }

        let resumeTask = Task { try await harness.pipeline.processNotesOnly(meetingID: meeting.id) }
        try await resumeEntered.wait()
        let kickTask = Task { try await harness.pipeline.dispatchProcessing(meetingID: meeting.id) }
        // Give the kick task scheduler turns to run any pre-chain section
        // before the heal completes (a stale outside-the-chain status read
        // would happen here, while the meeting is still failed+marker).
        // The fixed code has NO pre-chain section, so the assertions below
        // hold under every interleaving.
        for _ in 0..<50 { await Task.yield() }
        releaseResume.open()

        let resumeRecord = try await resumeTask.value
        #expect(resumeRecord != nil, "the resume heals the meeting")
        await #expect(throws: PipelineError.self) { try await kickTask.value }

        // No status regression: the kick ran as a regeneration-class run
        // against the healed meeting; its failure keeps ready, notes and
        // the queue row intact.
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.status == .ready)
        let notes = try await NotesRepository(database: harness.database)
            .fetch(meetingID: meeting.id)
        #expect(notes != nil)
        #expect(try await harness.queueRows(meeting.id) == 1)
    }

    /// G10 §1 (H-1): the notes-pending self-heal is an AUTO-KICK path and MUST
    /// refuse a user-cancelled meeting. Reproduces the auditor's reachability:
    /// run 1 hits notes-pending (status `failed` + live `notes-pending:`
    /// marker); the user clicks Process; the re-run installs a token and clears
    /// only `processingNote` — the stale marker PERSISTS; the user cancels
    /// mid-ASR, committing `cancelled`. The next self-heal trigger
    /// (`resumePendingNotes`) must leave the meeting `cancelled` with NO engine
    /// call and NO notes (the cancel is never silently undone, no cloud spend
    /// is incurred on a cancelled meeting).
    @Test func selfHealRefusesCancelledMeetingWithStalePendingMarker() async throws {
        let (harness, meeting, _) = try await makePendingMeeting()
        // Durable state coming in: failed + live notes-pending marker.
        let pendingState = try #require(try await harness.meeting(meeting.id))
        #expect(pendingState.status == .failed)
        #expect(NotesPendingClass.isPending(pendingState.lastProcessingError))

        // The user clicks Process: a FULL re-run. Heal the primary so the only
        // thing stopping completion is the cancel. Block on ASR so the cancel
        // lands mid-run; the re-run's writeRunEntry clears processingNote but
        // NOT lastProcessingError, so the pending marker survives.
        harness.notesPrimary.state.withLock { $0.error = nil }
        harness.asr.state.withLock { $0.transcribeDelaySeconds = 5 }
        let pipeline = harness.pipeline
        let runTask = Task { try await pipeline.process(meetingID: meeting.id) }
        #expect(await waitUntil { await pipeline.hasRunInFlight(meeting.id) })
        let signalled = await pipeline.cancel(meetingID: meeting.id)
        #expect(signalled, "cancel of the in-flight re-run must signal")
        _ = try? await runTask.value

        // Durable state after cancel: cancelled, BUT the stale marker persists.
        let afterCancel = try #require(try await harness.meeting(meeting.id))
        #expect(afterCancel.status == .cancelled)
        #expect(
            NotesPendingClass.isPending(afterCancel.lastProcessingError),
            "the stale notes-pending marker survives the cancel — this is the trap")

        // The self-heal must STAY cancelled with zero engine calls. Make any
        // engine call observable: a fresh primary request would land here.
        let callsBefore = harness.notesPrimary.state.withLock { $0.requests.count }
        harness.asr.state.withLock { $0.transcribeDelaySeconds = 0 }
        await harness.pipeline.resumePendingNotes()  // app launch / API-key save / network restore

        let healed = try #require(try await harness.meeting(meeting.id))
        #expect(healed.status == .cancelled, "self-heal must NOT resurrect a cancelled meeting")
        #expect(
            harness.notesPrimary.state.withLock { $0.requests.count } == callsBefore,
            "zero engine calls — no cloud spend on a cancelled meeting")
        let notes = try await NotesRepository(database: harness.database)
            .fetch(meetingID: meeting.id)
        #expect(notes == nil, "no notes minted for the cancelled meeting")

        // Defence in depth: a DIRECT processNotesOnly is also a no-op.
        let direct = try await harness.pipeline.processNotesOnly(meetingID: meeting.id)
        #expect(direct == nil, "direct notes-only resume of a cancelled meeting is a no-op")
        #expect(
            try #require(try await harness.meeting(meeting.id)).status == .cancelled)
    }

    @Test func dispatchAfterResumeDoesNotDoubleRun() async throws {
        // A full reprocess racing the resume: the chain serializes them and
        // the loser keys off the winner's terminal state. Deterministic
        // sequential probe of the same guard: resume first, then a status-
        // dependent dispatch sees `ready` and takes the regenerate path —
        // there is no path by which the pending marker dispatches twice.
        let (harness, meeting, _) = try await makePendingMeeting()
        harness.notesPrimary.state.withLock { $0.error = nil }
        _ = try await harness.pipeline.processNotesOnly(meetingID: meeting.id)
        let again = try await harness.pipeline.processNotesOnly(meetingID: meeting.id)
        #expect(again == nil)
        #expect(try await harness.queueRows(meeting.id) == 1)
    }
}
