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
Blaise asks as soon as processing starts, the meeting transcribes normally,
the notes wait until the names are confirmed (or the ask is skipped), and the
meeting stays marked in the library list until it is answered.

`automation.confirmParticipantsAutoSkip` (Bool, default **false**) is its
sub-toggle, indented under it and disabled while the parent is off: "Write the
notes anyway if I haven't answered in 5 minutes". OFF (the default) means the
meeting waits for the answer however long that takes; ON bounds the wait to
`AutomationSettings.confirmParticipantsAutoSkipSeconds` (300 s, pinned) past the
moment Blaise asked — see §2c.

## 2a. The ask (at run entry, moments after the stop)

The confirmation is raised as the meeting's processing run STARTS — which the
stop kicks, so in the ordinary case the question reaches the user moments after
they pressed Stop, while they are still at the computer, and no transcription
time is spent before it. It is raised at run entry rather than at the stop event
itself for one load-bearing reason: the C15 Slack / C12 Meet rosters are
absorbed into `attendees` by the run's entry transaction (§4), so BEFORE that
point "Blaise has no attendees" is not yet a true statement about the meeting.
Asking earlier would interrogate the user about a roster Blaise is about to
learn — the confirmation theater §2b rules out — and their answer would then be
refused, because by the time it arrived the attendees would no longer be empty.
Every stop that dispatches a processing run therefore leads to the ask: manual
stop, automatic stop, and "End & process" on a paused meeting. (An auto-stop
that enters the resume-grace window has not finished stopping; its ask, if the
meeting still qualifies, comes with the run it eventually kicks.)

**Timing, honestly:** processing runs are admitted through the durable queue and
serialized one at a time, so a stop taken while another meeting is still
processing raises its ask when that run finishes, not immediately.

- Raised iff the preference is ON **and**, after roster absorption,
  `meeting.attendees` is empty **and** the meeting has no notes yet **and** it
  is not already parked — exactly the states in which the gate would fire and an
  answer would be accepted. A regeneration never asks.
- Blaise frontmost → the confirm sheet, directly. Not frontmost → the
  `participantConfirm` notification, whose click opens Blaise and the sheet.
- Processing continues concurrently; nothing waits here. An answer that lands
  before the run reaches its notes stage means the gate condition is simply
  false and the meeting never parks: Confirm writes the attendees (the notes
  stage re-reads them, so the run's own notes request carries the names), Skip
  is carried by the run for its notes stage — there is no pending marker to
  hang it on yet.
- One ask per meeting, not one per park: the ask is raised at most once per
  meeting per app session, and a meeting that was asked does not post the
  notification again when it parks (§2b). Its list-row state is the standing
  surface from there on.
- **The late answer.** Between the gate's decision to park and the commit of the
  pending marker the run persists the transcript, so an answer can land when
  there is no longer a decision to change and not yet a marker to hang a resume
  on. That window is closed at the commit, not narrowed: the marker's own
  transaction re-reads `attendees`, and a Skip that landed there is claimed from
  the run's skip record, so an answered meeting has its notes-only resume
  dispatched the instant the marker exists. Whichever side observes the other
  dispatches, exactly once. An answer given during the run therefore always
  reaches the notes — through the run itself when it wins, through a resume
  dispatched at the park when it does not — and is never refused.

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
  unless this meeting was already asked (§2a) — the park of an asked meeting is
  a state change, not a second question. A park with no prior ask (the
  preference switched on mid-run, a resume that re-gates) notifies.
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
existing skip outcome, taken automatically. "Five minutes" means five minutes of
the user not answering, so the deadline is the moment the QUESTION was put to
them — the ask of §2a — plus the pinned 300 s; for a meeting nobody asked in this
session it starts at the first gate evaluation that consults it. It is
deliberately NOT the recording's own timestamps: an imported recording dated
last week carries an `endedAt` that expired before Blaise ever saw the file, and
measuring from it would silently skip the very question the user opted into
being asked. The ask time is held in memory, so a relaunch restarts the window
for a still-parked meeting — it fails toward asking, never toward skipping
unasked, which is the direction the default posture points. It is evaluated
wherever the gate is: a run whose notes stage arrives past the deadline mints
the notes; a recovery pass (launch, key save, network restore) past the deadline
proceeds instead of re-parking. Inside the window, and with the sub-toggle OFF,
the park-until-answered semantics above are untouched.

## 3. The confirm sheet

Opened three ways: at the ask with Blaise frontmost (§2a), from the confirm
notification's click, and from the meeting detail view's pending banner once the
meeting has parked. The first two present it at the window level — at ask time
there is no pending banner yet to hang it on. Contents:

- An editable name list, pre-filled from the best available hints in this
  order: calendar suggestions for the meeting's time window, grounded person
  hints, otherwise empty rows. A caption shows the diarization cluster count as
  a hint ("Blaise heard N distinct voices"), never as a required row count.
- **Which hints each entry path can actually show, stated plainly.** Two of the
  three are derived from artifacts the RUN produces — grounded person hints read
  the persisted transcript, the voice count reads the persisted diarization — so
  at the ask (§2a, run entry) neither exists yet: that sheet offers the calendar
  suggestions and empty rows, and shows no voice caption. The park/banner and
  post-park notification paths, which open after the run produced both, show all
  three. This is a real cost of asking early rather than at the notes stage: the
  sheet the user sees most often is the poorer of the two. The same code renders
  both — the difference is only which artifacts exist when it is opened.
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
  before the park, the write is all there is: the in-flight run carries it — or,
  if the run was already committing its park, that park dispatches the resume
  (§2a, the late answer). Refused once notes exist (post-hoc attendee editing
  belongs to the notes-editing arc) or once the meeting is no longer in either
  window.
- **Skip** proceeds without attendees for THIS meeting (marker cleared, notes
  resume dispatched, nothing written); answered before the park, the run carries
  the skip to its own notes stage instead, and a Skip that lands in the
  park-commit window is carried by the park (§2a). A Skip is accepted for a
  meeting whose run raised the ask and has not yet produced notes, or for one
  parked on the marker; a sheet left standing over a finished meeting is a
  no-op. An inline "Don't ask again" control flips the preference off and skips.

## 4. Interactions (stated)

- The gate composes with the fallback-engine pending state: a gated meeting that
  ALSO lacks a notes engine parks once with the confirmation reason; after
  confirmation the resume hits the engine check and re-parks with the engine
  reason (two distinct pending reasons, never a combined marker).
- C14 auto-stop → processing flows raise the ask and hit the gate exactly like
  manual stops.
- The C15 Slack / C12 Meet rosters absorb into `attendees` at run entry, and
  the ask is evaluated immediately AFTER that absorption — so a rostered meeting
  is neither asked nor gated, by the same emptiness condition read at the same
  point (§2a).

## 5. Acceptance criteria

- AC1: gate fires only under (preference ON ∧ attendees empty); rostered /
  calendar-merged / import-attendee meetings pass through untouched; preference
  OFF is byte-identical to today (regression pin).
- AC2: parked meeting carries the reserved marker, transcript visible, no
  handoff row, `updatedAt` untouched by the marker; the question surfaces
  exactly once — one ask at run entry and no park notification behind it, or, for
  a park with no ask before it, one notification.
- AC2b: the ask fires at run entry under exactly the gate's condition
  (preference ON ∧ attendees empty ∧ no notes ∧ not already parked) and nowhere
  else — in particular a meeting whose Meet roster is queued for absorption is
  never asked; a parked meeting's library row carries the participant-specific
  waiting badge, and a meeting parked on any other notes-pending reason does not.
- AC2c: an answer given during the run (Confirm or Skip) always reaches that
  meeting's notes and is never refused — before the notes stage, no park happens
  at all and a Confirm's names reach the run's own notes request; landing in the
  park-commit window, the park itself dispatches the notes-only resume, so the
  meeting ends `ready` with no standing question.
- AC2d: with the auto-skip sub-toggle ON, a meeting imported with a date in the
  past is still asked (the window opens at the ask, never at the recording's own
  timestamps) and closes five minutes after that ask.
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
- AC6: suite green; NO migration at all — the gate rides `lastProcessingError`,
  the two preference keys, and in-session memory for the ask bookkeeping and the
  ask time.

## 6. Out of scope

Editing attendees on non-gated meetings (separate backlog: per-meeting attendee
editor); glossary/alias admission from the sheet; renaming already-minted
notes (G2 owns corrections); any change to speaker RESOLUTION mechanics (the
gate only feeds it better inputs).

## CHANGELOG
- 25/07/2026: the ask is evaluated at RUN ENTRY, after roster absorption (§2a) —
  early enough to keep the at-stop experience, late enough that it is never put
  to the user about a roster Blaise already has; the answer and the park become
  one reconciled transition, so a Confirm or Skip landing while the run commits
  its park still reaches the notes (§2a, AC2c); the auto-skip window is measured
  from the ask rather than from the recording's timestamps (§2c, AC2d); §3
  states which hints each entry path can show. Artifacts:
  `audits/pr5-handoff/round-2/`.
- 25/07/2026: the ask moves to the recording stop (§2a), the park becomes a
  visible library-row state (§2b), and a default-OFF auto-skip sub-toggle bounds
  the wait when the user wants it bounded (§1, §2c). Park-until-answered stays
  the default. Artifacts: `audits/pr5-handoff/round-1/`.
- 25/07/2026: §2/§3 wording corrected to the shipped behaviour — the gate
  evaluates after transcript and diarization are PRODUCED (the transcript persist
  completes before the pending terminal becomes visible), and a notification
  click navigates to the meeting whose banner opens the sheet.
