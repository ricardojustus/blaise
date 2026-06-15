# G11 — Calendar-Aware End Detection (v3.2)

**Goal (the user's design, premise-corrected per round 1).** Reality check first: C14's grace ALREADY stops the engine at the end-signal (verified encode before grace — MeetCallTracker.swift:616-666, RecordingController.swift:779-809) and ALREADY auto-resumes a rejoin silently as a new part (:345-354). Rules 2/3 of the user's design are therefore largely SHIPPED. G11's real deltas:

1. **Rule 1 (new):** calendar-anchored meetings whose end-signal lands within 10 minutes before the scheduled end, or after it, SKIP grace — stop and process immediately.
2. **Durable grace (new):** the grace window survives an app restart (today's per-meeting map is in-memory — a relaunch mid-grace strands the meeting until a sweep catches it).
3. **Calendar anchoring + reliability (new):** the anchor must persist, and the matching must stop missing meetings (field evidence: today's real meetings carry default titles — no calendar match fired).

G9's pause verbs are NOT repurposed here (round-1 H-1/H-2/H-3: manualControl semantics, start-refusal blocking back-to-back meetings, and the resume predicate all contradict auto-use). Manual pause remains a manual-only verb; auto flow keeps C14's stopped+grace shape.

## 1. The anchor (round-1 C-1: persistence specified)

Additive migration: `meeting.calendar_event_id TEXT NULL`, `meeting.scheduled_end_ms INTEGER NULL`. Written ONCE at meeting start, by every start path, when the start was suggestion-matched (`MeetingSuggestion` gains `end`/`eventIdentifier` pass-through from the snapshot it currently drops — CalendarSuggestions.swift:71-77). No retroactive binding; both NULL = ad-hoc. The payload contract is untouched (calendar_event stays omitted in V1 — the anchor is internal).

## 2. The classifier

`EndAction classify(endSignalAt, scheduledEndMs?, ...)` — pure:
- scheduledEndMs != nil AND endSignalAt >= scheduledEndMs − 10 min → `.endAndProcess`
- otherwise → `.graceThenProcess` (today's behavior).

`endSignalAt` = the tracker's debounce-FIRE wall-clock (the moment performAutoStop is invoked — app clock, no extension-timestamp skew; defined, round-1 M-1). Multiple end-signals: the debounce already coalesces; classify runs once per fire. **Owned residual (round-1 H-5, the user's chosen trade):** an in-band FALSE end-signal (Meet glitch surviving the <25 s debounce) processes immediately instead of gracing — bounded loss: it lands within 10 minutes of the scheduled end and the audio to that point is fully retained. AFTERMATH OWNED PLAINLY (r2 H-1): no suppression record exists on non-manual stops (MeetCallTracker.swift:538-548 — manual-only, kept that way); a rejoin after an in-band process therefore raises the STANDARD Meet-start notification (one click to record a new meeting; the processed meeting is closed — no multi-part continuation). Within the band this is the accepted cost of instant processing; the recording resumes only on the click. The band is fixed at 10 min; grace stays the existing resume-window setting (its "Off"=0 reading under graceThenProcess = immediate process, already today's semantics).

## 3. Durable grace (r2 NEW-C1/H-2/H-3: writer named, recovery scoped, exits enumerated)

- **Writer:** the tracker holds no DB handle (MeetCallTracker.swift:153-164 — suppressions are in-memory; grace entry :630-653 writes nothing). Grace entry therefore calls a NEW environment callback (the same seam shape as its notification callbacks) which persists `meeting.grace_until_ms` in its own transaction, BEFORE the in-memory timer is armed (crash between write and arm = recovered at launch). Additive column beside §1's.
- **Every grace EXIT clears the column via the same callback** (enumerated against code, r3-M1: expiry-process, rejoin-resume, manual stop, pauseFromGrace, and the race-reachable `recordingPaused` removal at MeetCallTracker.swift:481 — no watchdog exit exists). EXIT ORDERING (r3-M2): the column CLEARS BEFORE the exit's action runs (clear-before-resume etc.) — a kill mid-exit then recovers as a plain crashed recording under today's flip+sweep, never as an exempted-but-live-crashed row. A non-nil column with no in-memory entry = "app died during grace".
- **Launch recovery, scoped:** the DB-open interrupted-flip (BlaiseDatabase.swift:336-356) gains ONE exemption: a `recording` row with `grace_until_ms` NON-NIL is not flipped (it is cleanly stopped-and-encoded by construction — performAutoStop completed before grace). Recovery then: deadline past → clear column, dispatch processing; future → re-enter grace (re-arm timer + suppression-equivalent state). Rows that are `paused` or `cancelled` are out of scope by their own gates (G9/G10 refusal sets untouched). The C14 quit-during-grace pins (CapturePartsTests.swift:248,269 — relaunch processes immediately) are REPLACED by name: relaunch mid-grace now re-enters grace; relaunch past-deadline processes — this is a deliberate behavior change of this chunk, sanctioned in AC6 explicitly (r2's AC4/AC6 conflict resolved by widening AC6's sanction to the durable-grace replacements, each named in the commit).
- The watchdog path is UNCHANGED in the body (r2 NEW-M1): its force-finalize exits grace via the same callback; classification applies to debounce-fired ends only.

## 4. Calendar reliability + diagnostics (carried from v1, privacy-corrected)

Diagnose-first protocol unchanged (miss classes: excluded calendars, pending invites, recurring expansion, refresh cadence — the former "Meet-link extraction" miss is SUPERSEDED by the v3.2 rule below: a calendar match anchors regardless of link, so an unparsed link is never an anchor miss) — now with a FIELD EXHIBIT: late-afternoon meetings carry default titles (no match) — reproduce against synthetic EventKit fixtures shaped like a normal workday. The diagnostic surface (Settings → Calendar: calendars scanned, next detected meetings, per-candidate matched/rejected reason) logs event titles ONLY in the UI surface; the unified log gets `.private`-marked values per the existing logging discipline (round-1 M-4). **Binding window WIDENED (the user's field batch: "detect meetings AROUND the time"; a Zoom meeting went undetected):** a start binds to a calendar event when it falls within [event.start − 15 min, event.end] (the whole scheduled span, not just the start vicinity — late joins mid-meeting are normal); among multiple candidates, the event whose span covers the start wins, else nearest start. The diagnosis protocol additionally verifies NON-MEET events bind (the suggestion layer must not require a Meet link to ANCHOR a meeting — link extraction gates the Launch&Record affordance only, not matching; if today's code requires a link to surface the event at all, that is miss-class (f), fix + pin).

### 4b. Upcoming-meetings list in the app (user field batch)

The main window's meetings list gains an **"Upcoming" section above the recorded meetings** (the day-grouped list already uses "Today" for recorded meetings — the user; separator; collapsible; no new tab): all of TODAY's remaining calendar meetings (all calendars the diagnosis surface lists, Meet link or not), each row = time, title, attendees count, and a **Record button** that starts a recording bound to that event (the §1 anchor written at start; with a Meet link it ALSO offers Launch & Record per C14). The list refreshes on the existing suggestion cadence + on day change; rows disappear as meetings are recorded or their end passes. Empty state: the section collapses to nothing (no "no meetings" chrome). Render checks batch to the deploy ask.

## 5. Acceptance criteria

- AC1 (classifier, pure): band edges (−10:00 exactly → end; −10:01 → grace; post-end → end; nil anchor → grace); endSignalAt source pinned.
- AC2 (anchor): migration additive; every start path writes the anchor when matched (each path pinned); unmatched/ad-hoc → NULLs; `MeetingSuggestion` carries end+eventIdentifier.
- AC3 (wiring): in-band end-signal → processed with NO grace entry (no suppression record — non-manual stops never write one, per §2's owned aftermath); early signal → today's grace, rejoin auto-resumes (existing pins re-asserted, not weakened); back-to-back starts during another meeting's grace stay green (the H-2 pin).
- AC4 (durable grace): relaunch mid-grace re-enters grace (the interrupted-flip exemption pinned); relaunch post-deadline processes; every enumerated exit clears the column (each pinned); kill between callback-write and timer-arm recovers; a paused/cancelled row with a stale column is never kicked (gate interplay pinned).
- AC5 (calendar): each diagnosed miss class fixture-pinned; diagnostic surface model-tested; log privacy pinned at a formatter seam (the diagnostic line builder returns redacted-for-log vs full-for-UI variants; the unit test asserts the log variant carries no event title — r2 NEW-L1's os.Logger untestability sidestepped).
- AC6: suite green; regression pins byte-identical; C14 pins REPLACED where the classifier OR the durable-grace recovery changes the action — the full replacement list named in the commit (incl. the quit-during-grace pair).
- AC7: zero engine calls.
- AC8 (upcoming list): the section's model (today-scoped query incl. calendars without Meet links, refresh triggers, row→start-with-anchor wiring incl. the §1 columns, day-rollover) unit-pinned; Record-from-row pinned to bind the anchor; render to the deploy GUI batch.

## 6. Out of scope

G9-pause repurposing; user-tunable band; Zoom/Teams lifecycle; retroactive anchoring; per-calendar enable/disable beyond diagnostics (BACKLOG if diagnosis demands).

## CHANGELOG
- v3.2 (12/06/2026): user field batch — binding window widened to the full event span +15min lead (Zoom meeting undetected; non-Meet events must anchor, miss-class (f) added); §4b upcoming-meetings Today section in the main window with per-row Record (AC8).
- v3.1 (12/06/2026): post-gate r3 Mediums — exit enumeration corrected to code (fictional watchdog exit removed; recordingPaused site added) + clear-before-exit-action ordering pinned. SPEC CYCLE CLOSED: r1 2C/5H -> r2 1C/3H -> r3 PASS 0C/0H/2M.
- v3 (12/06/2026): round-2 audit (1C/3H/1M/1L). NEW-C1: launch-recovery reality — the interrupted-flip exemption for non-nil grace_until_ms specified; quit-during-grace pin replacement sanctioned by name. NEW-H1: in-band aftermath owned truthfully (no suppression on auto-stops; rejoin = standard notification + click). NEW-H2: the writer is an environment callback with a real transaction, write-before-arm. NEW-H3: all five grace exits clear the column; recovery status-scoped vs G9/G10 gates. NEW-M1: watchdog-unchanged in the body. NEW-L1: formatter-seam privacy pin.
- v2 (12/06/2026): round-1 audit (2C/5H/4M/4L). C-1: anchor persistence fully specified (migration + suggestion pass-through + every start path). C-2: premise corrected — grace already stops + auto-resumes; deltas narrowed to rule-1 classifier, durable grace, calendar reliability. H-1/H-2/H-3: G9-pause repurposing DROPPED (manual pause stays manual; existing grace shape kept; back-to-back exemption preserved + pinned). H-4: grace_until_ms durable with launch recovery. H-5: in-band false-signal residual owned in words. M-1 endSignalAt defined; M-2 watchdog path unchanged (it keeps C14 semantics); M-3 "Off" reading stated; M-4 log privacy. L-1..L-4 absorbed (binding window stated; AC evidence in tests not commit prose where possible).
- v1 (12/06/2026): initial (premise flawed).
