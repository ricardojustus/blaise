# G15 — Participant Confirmation Gate (pre-notes, opt-in)

**Goal.** Meetings whose attendees Blaise could not learn (no calendar match, no
Meet/Slack roster) get their participant names from the ONE source that always
knows them — the user — BEFORE notes are written, so speaker naming and owner
attribution mint correctly instead of being corrected afterwards. Opt-in
preference; default off; zero engine cost (the gate holds the notes stage, it
never re-runs anything).

## 1. Preferences

`automation.confirmParticipants` (Bool, default **false**), Settings →
Automation, alongside the meeting-automation toggles: "Ask me to confirm
participants before notes are written". Caption states the mechanism honestly:
Blaise asks as soon as the recording stops, the meeting transcribes normally,
the notes wait until the names are confirmed (or the ask is skipped), and the
meeting stays marked in the library list until it is answered.

`automation.confirmParticipantsAutoSkip` (Bool, default **false**) is its
sub-toggle, indented under it and disabled while the parent is off: "Write the
notes anyway if I haven't answered in 5 minutes". OFF (the default) means the
meeting waits for the answer however long that takes; ON bounds the wait to
`AutomationSettings.confirmParticipantsAutoSkipSeconds` (300 s, pinned) past the
recording stop — see §2c.

## 2a. The ask (at recording stop)

The confirmation is raised when the recording STOPS — the user is at the
computer then (they usually pressed Stop themselves), and no processing time is
spent before the question. Every stop that dispatches a processing run raises
it: manual stop, automatic stop, and "End & process" on a paused meeting. (An
auto-stop that enters the resume-grace window has not finished stopping; its
ask, if the meeting still qualifies, comes with the notes-stage park below.)

- Raised iff the preference is ON **and** `meeting.attendees` is empty — the
  same condition the gate uses, evaluated early.
- Blaise frontmost → the confirm sheet, directly. Not frontmost → the
  `participantConfirm` notification, whose click opens Blaise and the sheet.
- Processing continues concurrently; nothing waits here. An answer that lands
  before the run reaches its notes stage means the gate condition is simply
  false and the meeting never parks: Confirm writes the attendees (the notes
  stage re-reads them, so the run's own notes request carries the names), Skip
  is carried by the run for its notes stage — there is no pending marker to
  hang it on yet.
- One ask per meeting stop, not one per park: a meeting whose stop already
  asked does not post the notification again when it parks (§2b). Its list-row
  state is the standing surface from there on.

## 2b. The gate (notes stage)

Evaluated ONCE per content run, at the notes-stage entry — transcript and
diarization have been PRODUCED, and the transcript persist still completes
before the pending terminal becomes visible, so the gate never blocks
transcription or audio retention:

- Fires iff the preference is ON **and** `meeting.attendees` is empty. Attendees
  from ANY source (calendar merge, import, Meet/Slack roster absorption) satisfy
  the gate — the prompt exists for the unknown-roster case only, never as
  confirmation theater over names Blaise already has.
- Firing = the meeting parks as notes-pending with the reserved reason
  `NotesPendingClass.marker("awaiting participant confirmation")` — the existing
  D17 semantics apply verbatim: transcript persisted and visible, audio
  retained, NO handoff enqueued (ready ⇒ queued holds), marker write does not
  bump `updatedAt`. The "Confirm participants — <title>" notification is posted
  unless the stop already asked (§2a).
- The park is VISIBLE in the library list, not only in the detail pane: the row
  carries a persistent "Confirm participants" badge (the list's existing
  capsule language, beside Ready and the action-item count) for as long as the
  meeting holds the marker. A wait the user chose is a loud state; the detail
  banner remains the action path.
- Regeneration of a `ready` meeting never gates (its notes exist; corrections
  and G2 renames are the tool there). Pending-resume runs re-evaluate: a resume
  triggered by anything other than confirmation (app launch, key save) re-parks
  an unconfirmed gated meeting rather than silently proceeding.

## 2c. The auto-skip window (sub-toggle, default OFF)

With `automation.confirmParticipantsAutoSkip` ON, an unanswered meeting past its
deadline proceeds WITHOUT attendees instead of parking or re-parking — the
existing skip outcome, taken automatically. The deadline is the meeting's
recording stop (`endedAt`, the ask time by construction — §2a) plus the pinned
300 s, so it survives a restart with no second timestamp anywhere. It is
evaluated wherever the gate is: a run reaching its notes stage past the deadline
mints the notes; a recovery pass (launch, key save, network restore) past the
deadline proceeds instead of re-parking. Inside the window, and with the
sub-toggle OFF, the park-until-answered semantics above are untouched.

## 3. The confirm sheet

Opened three ways: at the recording stop with Blaise frontmost (§2a), from the
confirm notification's click, and from the meeting detail view's pending banner
once the meeting has parked. The first two present it at the window level — at
stop time there is no pending banner yet to hang it on. Contents:

- An editable name list, pre-filled from the best available hints in this
  order: calendar suggestions for the meeting's time window, grounded person
  hints, otherwise empty rows. A caption shows the diarization cluster count as
  a hint ("Blaise heard N distinct voices"), never as a required row count.
- Names entered here are attendee DISPLAY names (folded-deduped, empties
  dropped); no glossary or alias rows are created (G1 owns admission; the sheet
  links to Settings → Glossary for that).
- **Confirm** writes the names to `meeting.attendees` (a content mutation —
  attendees are a payload-builder input; one guarded transaction, which does NOT
  join the single-flight engine chain: an answer given at stop time has to land
  while the run it answers is still transcribing). From a PARKED meeting it then
  dispatches the notes-only resume with the gate bypassed, and the pending
  marker stays in place for that resume — the resume path requires it, and its
  finalize clears it, exactly like every other pending self-heal. Answered
  before the park, the write is all there is: the in-flight run carries it.
  Refused once notes exist (post-hoc attendee editing belongs to the
  notes-editing arc) or once the meeting is no longer in either window.
- **Skip** proceeds without attendees for THIS meeting (marker cleared, notes
  resume dispatched, nothing written); answered before the park, the run carries
  the skip to its own notes stage instead. An inline "Don't ask again" control
  flips the preference off and skips.

## 4. Interactions (stated)

- The gate composes with the fallback-engine pending state: a gated meeting that
  ALSO lacks a notes engine parks once with the confirmation reason; after
  confirmation the resume hits the engine check and re-parks with the engine
  reason (two distinct pending reasons, never a combined marker).
- C14 auto-stop → processing flows raise the ask and hit the gate exactly like
  manual stops.
- The C15 Slack / C12 Meet rosters absorb into `attendees` at run entry —
  a rostered meeting therefore never gates (by the emptiness condition).

## 5. Acceptance criteria

- AC1: gate fires only under (preference ON ∧ attendees empty); rostered /
  calendar-merged / import-attendee meetings pass through untouched; preference
  OFF is byte-identical to today (regression pin).
- AC2: parked meeting carries the reserved marker, transcript visible, no
  handoff row, `updatedAt` untouched by the marker; notification posted once
  per park (not per resume re-park), and NOT at all when the stop already asked.
- AC2b: the ask fires at a stop under exactly the gate's condition (preference
  ON ∧ attendees empty) and nowhere else; a parked meeting's library row carries
  the participant-specific waiting badge, and a meeting parked on any other
  notes-pending reason does not.
- AC2c: an answer given during the run (Confirm or Skip) means no park ever
  happens, and a Confirm's names reach that run's own notes request.
- AC3: Confirm writes folded-deduped attendees, clears the marker, dispatches
  notes-only resume; the minted notes' allowed-name gate and rule-2 candidates
  include the confirmed names (integration: a misheard owner corrects to a
  confirmed attendee with zero manual corrections).
- AC4: Skip mints without attendees; "Don't ask again" flips the preference and
  is honored by the next run.
- AC5: launch/key-save self-heal resumes re-park unconfirmed gated meetings
  (never silently proceed); confirmation-triggered resume proceeds.
- AC5b: with the auto-skip sub-toggle ON, a meeting past its deadline proceeds
  without attendees — at the first park and at a recovery pass alike — while the
  same meeting inside its window, and any meeting with the sub-toggle OFF, still
  parks and re-parks.
- AC6: suite green; migrations additive-only (no new tables — the gate rides
  `lastProcessingError`, the meeting's own `endedAt`, and the two preference
  keys).

## 6. Out of scope

Editing attendees on non-gated meetings (separate backlog: per-meeting attendee
editor); glossary/alias admission from the sheet; renaming already-minted
notes (G2 owns corrections); any change to speaker RESOLUTION mechanics (the
gate only feeds it better inputs).

## CHANGELOG
- 25/07/2026: the ask moves to the recording stop (§2a), the park becomes a
  visible library-row state (§2b), and a default-OFF auto-skip sub-toggle bounds
  the wait when the user wants it bounded (§1, §2c). Park-until-answered stays
  the default. Artifacts: `audits/pr5-handoff/round-1/`.
- 25/07/2026: §2/§3 wording corrected to the shipped behaviour — the gate
  evaluates after transcript and diarization are PRODUCED (the transcript persist
  completes before the pending terminal becomes visible), and a notification
  click navigates to the meeting whose banner opens the sheet.
