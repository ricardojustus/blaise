import Foundation
import Synchronization
import Testing
@testable import BlaiseCore

// G15: the participant-confirmation gate — an opt-in pre-notes gate that parks a
// meeting with EMPTY attendees on the reserved `notes-pending: awaiting
// participant confirmation` marker until the user confirms or skips. All with
// mock engines (no models, no network).

@Suite struct ParticipantConfirmationTests {
    /// Turns the opt-in preference on for a harness DB.
    private func enableGate(_ harness: PipelineHarness) async throws {
        try await SettingsStore(database: harness.database)
            .set(AutomationSettings.confirmParticipantsKey, to: true)
    }

    private func isParticipantMarker(_ meeting: Meeting?) -> Bool {
        NotesPendingClass.isAwaitingParticipantConfirmation(meeting?.lastProcessingError)
    }

    /// Counts `.participantConfirmationNeeded` events across `body`, breaking each
    /// run at its `.runCompleted` (every run — pending or not — emits one).
    private func participantEvents(
        _ harness: PipelineHarness, runs: Int, _ body: () async throws -> Void
    ) async throws -> Int {
        let events = await harness.pipeline.events()
        try await body()
        var count = 0
        var completed = 0
        for await event in events {
            if case .participantConfirmationNeeded = event { count += 1 }
            if case .runCompleted = event {
                completed += 1
                if completed >= runs { break }
            }
        }
        return count
    }

    // MARK: - AC1: fires only under (preference ON ∧ attendees empty)

    @Test func gateFiresOnlyWhenPreferenceOnAndAttendeesEmpty() async throws {
        // (a) preference ON + EMPTY attendees → parks on the reserved marker.
        let onEmpty = try await makePipelineHarness()
        try await enableGate(onEmpty)
        let m1 = try await onEmpty.importTestMeeting(attendees: [])
        let r1 = try await onEmpty.pipeline.process(meetingID: m1.id)
        #expect(r1.notesPending == NotesPendingClass.awaitingParticipantConfirmation)
        #expect(isParticipantMarker(try await onEmpty.meeting(m1.id)))

        // (b) preference ON + import ATTENDEES present → passes through untouched.
        let onAttendees = try await makePipelineHarness()
        try await enableGate(onAttendees)
        let m2 = try await onAttendees.importTestMeeting()  // default Sam attendee
        let r2 = try await onAttendees.pipeline.process(meetingID: m2.id)
        #expect(r2.notesPending == nil)
        #expect(try #require(try await onAttendees.meeting(m2.id)).status == .ready)
    }

    @Test func preferenceOffIsByteIdenticalToToday() async throws {
        // Regression pin: preference OFF (the harness default) + empty attendees
        // is a normal ready run — notes minted, handoff enqueued, no marker.
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting(attendees: [])
        let record = try await harness.pipeline.process(meetingID: meeting.id)
        #expect(record.notesPending == nil)
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.status == .ready)
        #expect(stored.lastProcessingError == nil)
        #expect(try await harness.queueRows(meeting.id) == 1)
        let notes = try await NotesRepository(database: harness.database)
            .fetch(meetingID: meeting.id)
        #expect(notes != nil)
    }

    @Test func regenerationOfANotedMeetingNeverGates() async throws {
        // A ready meeting (has notes) regenerated with empty attendees + the
        // preference ON must NOT gate — corrections/renames are the tool there.
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting(attendees: [])
        _ = try await harness.pipeline.process(meetingID: meeting.id)  // ready + notes
        try await enableGate(harness)
        let record = try await harness.pipeline.regenerate(meetingID: meeting.id)
        #expect(record.notesPending == nil)
        #expect(try #require(try await harness.meeting(meeting.id)).status == .ready)
    }

    // MARK: - AC2: reserved marker, transcript visible, no handoff, updatedAt untouched

    @Test func parkedMeetingCarriesMarkerTranscriptNoHandoff() async throws {
        let harness = try await makePipelineHarness()
        try await enableGate(harness)
        let meeting = try await harness.importTestMeeting(attendees: [])
        _ = try await harness.pipeline.process(meetingID: meeting.id)

        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.status == .failed)
        #expect(
            stored.lastProcessingError
                == NotesPendingClass.marker(NotesPendingClass.awaitingParticipantConfirmation))
        // Transcript persisted + visible; audio retained; NO handoff; NO notes.
        #expect(!(try await harness.segments(meeting.id)).isEmpty)
        #expect(
            FileManager.default.fileExists(atPath: harness.database.paths.audioURL(meeting.id).path))
        #expect(try await harness.queueRows(meeting.id) == 0)
        #expect(
            try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id)
                == nil)
    }

    @Test func markerReparkDoesNotBumpUpdatedAtNorRepostNotification() async throws {
        let harness = try await makePipelineHarness()
        try await enableGate(harness)
        let meeting = try await harness.importTestMeeting(attendees: [])

        // Park (1 run) then self-heal re-park (1 run): exactly ONE notification
        // event across both — one per PARK, never per resume re-park.
        let events = try await participantEvents(harness, runs: 2) {
            _ = try await harness.pipeline.process(meetingID: meeting.id)
            await harness.pipeline.resumePendingNotes()
        }
        #expect(events == 1, "notification fires once per park, not per resume re-park")

        // updatedAt is untouched by the re-park marker write.
        let afterPark = try #require(try await harness.meeting(meeting.id))
        await harness.pipeline.resumePendingNotes()
        let afterRepark = try #require(try await harness.meeting(meeting.id))
        #expect(afterRepark.updatedAt == afterPark.updatedAt, "the marker write never bumps updatedAt")
        #expect(isParticipantMarker(afterRepark))
    }

    // MARK: - AC3: Confirm writes folded-deduped attendees, resumes, includes names

    @Test func confirmWritesAttendeesResumesAndFixesMisheardOwner() async throws {
        let harness = try await makePipelineHarness()
        try await enableGate(harness)
        // The mock owner is a d=1 mishearing of the confirmed attendee "Marina"
        // (len 6 → tolerance 2): rule-2 fixes it with ZERO manual corrections.
        harness.notesPrimary.state.withLock { $0.actionOwner = "Marna" }
        let meeting = try await harness.importTestMeeting(attendees: [])
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        #expect(isParticipantMarker(try await harness.meeting(meeting.id)))

        // Confirm with a duplicate + an empty row — folded-deduped, empties dropped.
        let confirmed = try await harness.pipeline.confirmParticipants(
            meetingID: meeting.id, names: ["Marina", "  marina ", ""])
        #expect(confirmed)

        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.status == .ready)
        #expect(stored.lastProcessingError == nil, "marker cleared by the resume finalize")
        #expect(stored.attendees == [Attendee(name: "Marina", source: .manual)])
        #expect(try await harness.queueRows(meeting.id) == 1)

        // The resume's notes request carried the confirmed attendee (allowed-name
        // gate + rule-2 candidate), and the minted owner was fixed.
        let resumed = try #require(harness.notesPrimary.state.withLock { $0.requests.last })
        #expect(resumed.meeting.attendees.contains { $0.name == "Marina" })
        let notes = try #require(
            try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id))
        #expect(notes.structured.actionItems.first?.owner == "Marina")
    }

    // MARK: - AC4: Skip mints without attendees; preference off is honored next run

    @Test func skipMintsWithoutAttendees() async throws {
        let harness = try await makePipelineHarness()
        try await enableGate(harness)
        let meeting = try await harness.importTestMeeting(attendees: [])
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        #expect(isParticipantMarker(try await harness.meeting(meeting.id)))

        let skipped = try await harness.pipeline.skipParticipantConfirmation(meetingID: meeting.id)
        #expect(skipped)
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.status == .ready)
        #expect(stored.lastProcessingError == nil)
        #expect(stored.attendees.isEmpty, "skip writes no attendees")
        #expect(try await harness.queueRows(meeting.id) == 1)
        #expect(
            try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id)
                != nil)
    }

    @Test func preferenceFlippedOffIsHonoredByTheNextRun() async throws {
        // "Don't ask again" flips the preference off; a subsequent empty-attendee
        // run then does NOT gate (the app layer flips the key; here we flip it
        // directly and assert the next run's behavior).
        let harness = try await makePipelineHarness()
        try await enableGate(harness)
        let gated = try await harness.importTestMeeting(attendees: [])
        _ = try await harness.pipeline.process(meetingID: gated.id)
        #expect(isParticipantMarker(try await harness.meeting(gated.id)))

        try await SettingsStore(database: harness.database)
            .set(AutomationSettings.confirmParticipantsKey, to: false)
        let after = try await harness.importTestMeeting(attendees: [])
        let record = try await harness.pipeline.process(meetingID: after.id)
        #expect(record.notesPending == nil, "preference off → no gate on the next run")
        #expect(try #require(try await harness.meeting(after.id)).status == .ready)
    }

    // MARK: - AC5: self-heal re-parks; confirmation-triggered resume proceeds

    @Test func selfHealReParksButConfirmationResumeProceeds() async throws {
        let harness = try await makePipelineHarness()
        try await enableGate(harness)
        let meeting = try await harness.importTestMeeting(attendees: [])
        _ = try await harness.pipeline.process(meetingID: meeting.id)

        // Self-heal (launch/key-save) re-parks an unconfirmed gated meeting.
        await harness.pipeline.resumePendingNotes()
        let afterSelfHeal = try #require(try await harness.meeting(meeting.id))
        #expect(isParticipantMarker(afterSelfHeal), "self-heal never silently proceeds")
        #expect(
            try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id)
                == nil)

        // A confirmation-triggered resume (the bypass) proceeds.
        _ = try await harness.pipeline.processNotesOnly(
            meetingID: meeting.id, confirmingParticipants: true)
        #expect(try #require(try await harness.meeting(meeting.id)).status == .ready)
    }

    @Test func skipIsDurableAcrossAnEngineParkAndLaterSelfHeal() async throws {
        // §3/AC5 durability: after a Skip, if the notes engine is unavailable the
        // resume ENGINE-parks (a distinct reason). A later self-heal must proceed
        // to the engine check (re-park engine), NOT re-gate the participant marker.
        let harness = try await makePipelineHarness(
            fallbackLoadProfile: .heavyweight(estimatedPeakBytes: 18 * 1_073_741_824))
        try await enableGate(harness)
        let meeting = try await harness.importTestMeeting(attendees: [])
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        #expect(isParticipantMarker(try await harness.meeting(meeting.id)))

        // Skip while the engine is broken → engine-park (NOT the participant marker).
        harness.notesPrimary.state.withLock { $0.error = .configurationMissing(key: "apiKey") }
        _ = try await harness.pipeline.skipParticipantConfirmation(meetingID: meeting.id)
        let afterSkip = try #require(try await harness.meeting(meeting.id))
        #expect(NotesPendingClass.isPending(afterSkip.lastProcessingError))
        #expect(!isParticipantMarker(afterSkip), "skip moved past the gate; engine reason now")

        // A later self-heal does NOT re-gate — it retries the engine (still broken).
        await harness.pipeline.resumePendingNotes()
        let afterSelfHeal = try #require(try await harness.meeting(meeting.id))
        #expect(!isParticipantMarker(afterSelfHeal), "a skipped meeting is never re-gated")

        // Fix the engine → the next self-heal completes without any re-gate.
        harness.notesPrimary.state.withLock { $0.error = nil }
        await harness.pipeline.resumePendingNotes()
        #expect(try #require(try await harness.meeting(meeting.id)).status == .ready)
    }

    // MARK: - Review fixes (L1, L2, L4)

    @Test func skipNoOpsWhenNotAwaitingParticipantConfirmation() async throws {
        // L1: a stale sheet — the meeting engine-parked after the sheet opened.
        // Skip must NOT fire a gate-bypassing resume / out-of-cadence engine retry.
        let harness = try await makePipelineHarness(
            fallbackLoadProfile: .heavyweight(estimatedPeakBytes: 18 * 1_073_741_824))
        harness.notesPrimary.state.withLock { $0.error = .configurationMissing(key: "apiKey") }
        let meeting = try await harness.importTestMeeting()  // has attendees → no gate
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(NotesPendingClass.isPending(stored.lastProcessingError))
        #expect(!isParticipantMarker(stored), "engine-pending, not participant-pending")
        let callsBefore = harness.notesPrimary.state.withLock { $0.requests.count }

        let didSkip = try await harness.pipeline.skipParticipantConfirmation(meetingID: meeting.id)
        #expect(!didSkip, "skip is a no-op unless the meeting is participant-pending")
        #expect(
            harness.notesPrimary.state.withLock { $0.requests.count } == callsBefore,
            "no engine call from a stale-sheet skip")
    }

    @Test func confirmWithAllEmptyNamesIsANoOp() async throws {
        // L2: an all-empty/whitespace confirm writes nothing and dispatches nothing.
        let harness = try await makePipelineHarness()
        try await enableGate(harness)
        let meeting = try await harness.importTestMeeting(attendees: [])
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        #expect(isParticipantMarker(try await harness.meeting(meeting.id)))
        let callsBefore = harness.notesPrimary.state.withLock { $0.requests.count }

        let didConfirm = try await harness.pipeline.confirmParticipants(
            meetingID: meeting.id, names: ["", "   ", "\t"])
        #expect(!didConfirm)
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(isParticipantMarker(stored), "still parked; nothing written")
        #expect(stored.attendees.isEmpty)
        #expect(harness.notesPrimary.state.withLock { $0.requests.count } == callsBefore)
    }

    @Test func rosterAbsorptionAtRunEntryPreventsTheGate() async throws {
        // L4: preference ON, attendees EMPTY in the DB, but a Meet roster row is
        // pending — run entry absorbs it into attendees BEFORE the gate, so the
        // gate does NOT fire (the emptiness condition is already satisfied away).
        let harness = try await makePipelineHarness()
        try await enableGate(harness)
        let meeting = try await harness.importTestMeeting(attendees: [])
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
        let record = try await harness.pipeline.process(meetingID: meeting.id)
        #expect(record.notesPending == nil, "absorbed roster fills attendees → no gate")
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.status == .ready)
        #expect(stored.attendees.contains { $0.name == "Marina Souza" })
    }

    // MARK: - §2 ask-at-stop: who gets asked, and who gets notified

    @Test func stopTimeAskFiresOnlyWhenTheGateWouldFire() async throws {
        // (a) The ask raised at a recording stop answers the SAME question the
        // notes-stage gate would: preference ON and no attendees known. Anything
        // else must return nil — an ask nobody needed is the confirmation
        // theater §2 exists to avoid.
        let harness = try await makePipelineHarness()
        let unknown = try await harness.importTestMeeting(attendees: [])
        let known = try await harness.importTestMeeting()  // default Sam attendee

        // Preference OFF (the harness default): nobody is asked.
        #expect(await harness.pipeline.participantAskAtStop(meetingID: unknown.id) == nil)
        try await enableGate(harness)
        // Preference ON + attendees already known: still nobody.
        #expect(await harness.pipeline.participantAskAtStop(meetingID: known.id) == nil)
        // Preference ON + attendees unknown: the ask fires, carrying the meeting
        // the sheet/notification needs.
        let asked = try #require(
            await harness.pipeline.participantAskAtStop(meetingID: unknown.id))
        #expect(asked.id == unknown.id)
    }

    @Test func aStopTimeAskIsNotRepeatedAsAParkNotification() async throws {
        // (b) The park still happens (nothing was answered), but the user was
        // already asked at the stop — no second notification for one stop. The
        // control below proves the counter is non-vacuous: the same run WITHOUT
        // a stop-time ask emits exactly one.
        let asked = try await makePipelineHarness()
        try await enableGate(asked)
        let m1 = try await asked.importTestMeeting(attendees: [])
        #expect(await asked.pipeline.participantAskAtStop(meetingID: m1.id) != nil)
        let askedEvents = try await participantEvents(asked, runs: 1) {
            _ = try await asked.pipeline.process(meetingID: m1.id)
        }
        #expect(askedEvents == 0, "the stop-time ask already covered this park")
        #expect(isParticipantMarker(try await asked.meeting(m1.id)), "it still parks, visibly")

        let notAsked = try await makePipelineHarness()
        try await enableGate(notAsked)
        let m2 = try await notAsked.importTestMeeting(attendees: [])
        let unaskedEvents = try await participantEvents(notAsked, runs: 1) {
            _ = try await notAsked.pipeline.process(meetingID: m2.id)
        }
        #expect(unaskedEvents == 1, "with no stop-time ask the park notifies")
    }

    @Test func answeringDuringTheRunMeansNoParkEverHappens() async throws {
        // §2: the ask is raised at the stop, so the answer usually lands while
        // ASR is still running. Confirm mid-run (the ASR hook stands in for the
        // user answering during transcription): the notes stage re-reads the
        // attendees, so the gate never fires, no notification is emitted, and
        // the notes are minted WITH the confirmed name.
        let harness = try await makePipelineHarness()
        try await enableGate(harness)
        harness.notesPrimary.state.withLock { $0.actionOwner = "Marna" }
        let meeting = try await harness.importTestMeeting(attendees: [])
        #expect(await harness.pipeline.participantAskAtStop(meetingID: meeting.id) != nil)
        let pipeline = harness.pipeline
        let meetingID = meeting.id
        harness.asr.state.withLock {
            $0.onTranscribe = {
                _ = try? await pipeline.confirmParticipants(
                    meetingID: meetingID, names: ["Marina"])
            }
        }

        let events = try await participantEvents(harness, runs: 1) {
            _ = try await harness.pipeline.process(meetingID: meetingID)
        }
        #expect(events == 0, "answered before the notes stage — nothing to notify")
        let stored = try #require(try await harness.meeting(meetingID))
        #expect(stored.status == .ready)
        #expect(stored.lastProcessingError == nil, "never parked")
        #expect(stored.attendees == [Attendee(name: "Marina", source: .manual)])
        let request = try #require(harness.notesPrimary.state.withLock { $0.requests.last })
        #expect(
            request.meeting.attendees.contains { $0.name == "Marina" },
            "the in-flight run's notes request carries the confirmed name")
    }

    @Test func skippingDuringTheRunMeansNoParkEverHappens() async throws {
        // The Skip half of the same window: there is no pending marker yet to
        // hang the answer on, so the run carries it — notes are minted without
        // attendees instead of parking on a question the user already dismissed.
        let harness = try await makePipelineHarness()
        try await enableGate(harness)
        let meeting = try await harness.importTestMeeting(attendees: [])
        #expect(await harness.pipeline.participantAskAtStop(meetingID: meeting.id) != nil)
        let pipeline = harness.pipeline
        let meetingID = meeting.id
        harness.asr.state.withLock {
            $0.onTranscribe = {
                _ = try? await pipeline.skipParticipantConfirmation(meetingID: meetingID)
            }
        }

        _ = try await harness.pipeline.process(meetingID: meetingID)
        let stored = try #require(try await harness.meeting(meetingID))
        #expect(stored.status == .ready)
        #expect(stored.lastProcessingError == nil, "never parked")
        #expect(stored.attendees.isEmpty, "skip writes no attendees")
    }

    // MARK: - §2 list-row state: the wait is visible from the LIST

    @Test func aParkedMeetingCarriesTheWaitingStateOnItsListRow() async throws {
        // (c) The library row renders its "Confirm participants" badge from
        // exactly this property. A meeting parked on the gate carries it; a
        // meeting parked on any OTHER notes-pending reason does not (that state
        // completes by itself and is not waiting for the user).
        let harness = try await makePipelineHarness()
        try await enableGate(harness)
        let gated = try await harness.importTestMeeting(attendees: [])
        _ = try await harness.pipeline.process(meetingID: gated.id)
        let parked = try #require(try await harness.meeting(gated.id))
        #expect(
            MeetingListItem(
                meeting: parked, summary: nil, actionItemCount: 0, userActionItemCount: 0
            ).awaitsParticipantConfirmation)

        var enginePending = parked
        enginePending.lastProcessingError = NotesPendingClass.marker("notes engine unavailable")
        #expect(
            !MeetingListItem(
                meeting: enginePending, summary: nil, actionItemCount: 0, userActionItemCount: 0
            ).awaitsParticipantConfirmation)

        var ready = parked
        ready.lastProcessingError = nil
        #expect(
            !MeetingListItem(
                meeting: ready, summary: nil, actionItemCount: 0, userActionItemCount: 0
            ).awaitsParticipantConfirmation)
    }

    // MARK: - §2 auto-skip sub-toggle (opt-in, default OFF)

    /// Moves the meeting's persisted stop time `minutes` into the past — the
    /// auto-skip deadline is measured from it, so this is how a five-minute
    /// window is crossed without waiting five minutes.
    private func backdateStop(
        _ harness: PipelineHarness, _ meetingID: MeetingID, minutes: Double
    ) async throws {
        try await harness.database.pool.write { db in
            try db.execute(
                sql: "UPDATE meeting SET ended_at = ? WHERE id = ?",
                arguments: [msDate().addingTimeInterval(-minutes * 60), meetingID])
        }
    }

    @Test func autoSkipPastTheDeadlineOnlyWithTheSubToggleOn() async throws {
        // (d)/(e) Same meeting state — stopped ten minutes ago, unanswered — and
        // the sub-toggle is the ONLY difference: OFF parks (Arthur's semantics,
        // the default), ON writes the notes without attendees.
        let off = try await makePipelineHarness()
        try await enableGate(off)
        let parked = try await off.importTestMeeting(attendees: [])
        try await backdateStop(off, parked.id, minutes: 10)
        _ = try await off.pipeline.process(meetingID: parked.id)
        #expect(
            isParticipantMarker(try await off.meeting(parked.id)),
            "sub-toggle OFF: the meeting waits, however long that takes")

        let on = try await makePipelineHarness()
        try await enableGate(on)
        try await SettingsStore(database: on.database)
            .set(AutomationSettings.confirmParticipantsAutoSkipKey, to: true)
        let skipped = try await on.importTestMeeting(attendees: [])
        try await backdateStop(on, skipped.id, minutes: 10)
        let record = try await on.pipeline.process(meetingID: skipped.id)
        #expect(record.notesPending == nil, "past the window → notes proceed")
        let stored = try #require(try await on.meeting(skipped.id))
        #expect(stored.status == .ready)
        #expect(stored.attendees.isEmpty, "auto-skip writes no attendees")
    }

    @Test func insideTheWindowTheSubToggleStillParks() async throws {
        // The deadline is a deadline, not an off-switch: with the sub-toggle ON
        // a meeting still inside its five minutes parks and waits, exactly like
        // the default. (Pairs with the test above: together they pin the
        // behavior to the elapsed time, not to the preference alone.)
        let harness = try await makePipelineHarness()
        try await enableGate(harness)
        try await SettingsStore(database: harness.database)
            .set(AutomationSettings.confirmParticipantsAutoSkipKey, to: true)
        let meeting = try await harness.importTestMeeting(attendees: [])
        try await backdateStop(harness, meeting.id, minutes: 1)
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        #expect(isParticipantMarker(try await harness.meeting(meeting.id)))
    }

    @Test func aRecoveryPassPastTheDeadlineAutoSkipsInsteadOfReParking() async throws {
        // (d) The inversion the sub-toggle buys: a meeting that parked inside
        // its window is re-parked by every self-heal while the window stands,
        // and PROCEEDS on the first self-heal past it. Ask-time survives the
        // restart because it is the meeting's own persisted stop time.
        let harness = try await makePipelineHarness()
        try await enableGate(harness)
        try await SettingsStore(database: harness.database)
            .set(AutomationSettings.confirmParticipantsAutoSkipKey, to: true)
        let meeting = try await harness.importTestMeeting(attendees: [])
        try await backdateStop(harness, meeting.id, minutes: 1)
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        #expect(isParticipantMarker(try await harness.meeting(meeting.id)), "parked inside the window")

        // Still inside the window: the recovery pass re-parks (AC5 holds).
        await harness.pipeline.resumePendingNotes()
        #expect(isParticipantMarker(try await harness.meeting(meeting.id)))

        // Past it: the same recovery pass proceeds without attendees.
        try await backdateStop(harness, meeting.id, minutes: 10)
        await harness.pipeline.resumePendingNotes()
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.status == .ready)
        #expect(stored.lastProcessingError == nil)
        #expect(stored.attendees.isEmpty)
    }

    // MARK: - AC6 support: additive-only (rides lastProcessingError + the key)

    @Test func foldedDedupedAttendeesDropsEmptiesAndFolds() async throws {
        let out = ProcessingPipeline.foldedDedupedAttendees(
            ["Dana Rosso", "  ", "dana rosso", "Théo", "theo", "Marina"])
        #expect(out.map(\.name) == ["Dana Rosso", "Théo", "Marina"])
        #expect(out.allSatisfy { $0.source == .manual })
    }
}
