# G15 — Participant Confirmation Gate (pre-notes, opt-in)

**Goal.** Meetings whose attendees Blaise could not learn (no calendar match, no
Meet/Slack roster) get their participant names from the ONE source that always
knows them — the user — BEFORE notes are written, so speaker naming and owner
attribution mint correctly instead of being corrected afterwards. Opt-in
preference; default off; zero engine cost (the gate holds the notes stage, it
never re-runs anything).

## 1. Preference

`automation.confirmParticipants` (Bool, default **false**), Settings →
Automation, alongside the meeting-automation toggles: "Ask me to confirm
participants before notes are written". Caption states the mechanism honestly:
the meeting transcribes normally and notes wait until the names are confirmed
(or the ask is skipped).

## 2. The gate

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
  bump `updatedAt`. A user notification is posted ("Confirm participants —
  <title>"); the meeting list shows the existing pending pill.
- Regeneration of a `ready` meeting never gates (its notes exist; corrections
  and G2 renames are the tool there). Pending-resume runs re-evaluate: a resume
  triggered by anything other than confirmation (app launch, key save) re-parks
  an unconfirmed gated meeting rather than silently proceeding.

## 3. The confirm sheet

Opened from the meeting detail view's pending banner. Clicking the notification
navigates to the meeting, where that banner opens the sheet. Contents:

- An editable name list, pre-filled from the best available hints in this
  order: calendar suggestions for the meeting's time window, grounded person
  hints, otherwise empty rows. A caption shows the diarization cluster count as
  a hint ("Blaise heard N distinct voices"), never as a required row count.
- Names entered here are attendee DISPLAY names (folded-deduped, empties
  dropped); no glossary or alias rows are created (G1 owns admission; the sheet
  links to Settings → Glossary for that).
- **Confirm** writes the names to `meeting.attendees` (a content mutation —
  attendees are a payload-builder input; one transaction, guarded on the meeting
  still being participant-parked) and dispatches the notes-only resume with the
  gate bypassed. The pending marker stays in place for the resume — the resume
  path requires it, and its finalize clears it, exactly like every other
  pending self-heal.
- **Skip** proceeds without attendees for THIS meeting (marker cleared, notes
  resume dispatched, nothing written). An inline "Don't ask again" control
  flips the preference off and skips.

## 4. Interactions (stated)

- The gate composes with the fallback-engine pending state: a gated meeting that
  ALSO lacks a notes engine parks once with the confirmation reason; after
  confirmation the resume hits the engine check and re-parks with the engine
  reason (two distinct pending reasons, never a combined marker).
- C14 auto-stop → processing flows hit the gate exactly like manual stops.
- The C15 Slack / C12 Meet rosters absorb into `attendees` at run entry —
  a rostered meeting therefore never gates (by the emptiness condition).

## 5. Acceptance criteria

- AC1: gate fires only under (preference ON ∧ attendees empty); rostered /
  calendar-merged / import-attendee meetings pass through untouched; preference
  OFF is byte-identical to today (regression pin).
- AC2: parked meeting carries the reserved marker, transcript visible, no
  handoff row, `updatedAt` untouched by the marker; notification posted once
  per park (not per resume re-park).
- AC3: Confirm writes folded-deduped attendees, clears the marker, dispatches
  notes-only resume; the minted notes' allowed-name gate and rule-2 candidates
  include the confirmed names (integration: a misheard owner corrects to a
  confirmed attendee with zero manual corrections).
- AC4: Skip mints without attendees; "Don't ask again" flips the preference and
  is honored by the next run.
- AC5: launch/key-save self-heal resumes re-park unconfirmed gated meetings
  (never silently proceed); confirmation-triggered resume proceeds.
- AC6: suite green; migrations additive-only (no new tables — the gate rides
  `lastProcessingError` + the preference key).

## 6. Out of scope

Editing attendees on non-gated meetings (separate backlog: per-meeting attendee
editor); glossary/alias admission from the sheet; renaming already-minted
notes (G2 owns corrections); any change to speaker RESOLUTION mechanics (the
gate only feeds it better inputs).

## CHANGELOG
- 25/07/2026: §2/§3 wording corrected to the shipped behaviour — the gate
  evaluates after transcript and diarization are PRODUCED (the transcript persist
  completes before the pending terminal becomes visible), and a notification
  click navigates to the meeting whose banner opens the sheet.
