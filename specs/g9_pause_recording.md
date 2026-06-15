# G9 — Pause / Resume Recording (v4)

**Goal (the user, 12/06/2026):** a pause button; resume without processing starting; from pause, the option to end+process.

**Hard floor 2 above all:** nothing recorded before a pause may be lost; a crash near a pause recovers to `paused` (or to plain recording-recovery if the pause never committed) — never to silent processing, handoff, or loss.

## 1. Design: pause = a closed capture part on the C14 substrate

- **Pause** = finalize the current capture part (the C14 part-finalize path) with the meeting status write to `'paused'` JOINED INTO the part-finalize transaction (same DB; one transaction — the C11 flag discipline). `status` is TEXT with NO CHECK constraint (C1's deliberate choice — verified; no migration is needed for the new value); the C1 status state-machine spec gains the arcs recording→paused→recording|processing and the dispatch rules below.
- **Resume** = start the engine and open the new capture part FIRST, then commit the part row AND status→`recording` in ONE transaction (the same single-transaction discipline as pause). A crash at ANY point before that commit leaves the meeting durably `paused` — where §2's encode-no-kick gate protects it (an orphaned new-part CAF is rescued as a part, nothing processes) — never the `interrupted`→silent-processing path round-2 M-7 traced. Engine-start failure OR commit failure → the engine is torn down, the meeting stays `paused`, the error surfaced (no live-engine-against-paused-row state may persist). Resume is GATED on launch-sweep completion (the detached sweep finishes in seconds; the Resume control is disabled until it reports done) — the live new-part CAF can never race the sweep's zero-frame unlink (round-3 M-8).
- **End & process** = leave `paused` directly into the normal finalize→processing flow over existing parts (no new part). The zero/no-recoverable-audio failure write fires ONLY on End-path evaluation, never on pause — pausing a seconds-old meeting is legal and leaves a near-empty part.
- Unbounded pause/resume cycles; the stitcher treats pause gaps as ordinary inter-part gaps.

## 2. The H-1 fix: sweep/dispatch gating (the load-bearing change)

`CaptureRecovery.sweepOrphanCAFs` (CaptureRecovery.swift:236-262) keeps ENCODING orphaned CAFs for paused meetings (retention, floor 2) but its auto-kick is GATED: `dispatchProcessing` is invoked only when the meeting's durable status is process-class AND NOT `'paused'`; `dispatchProcessing` itself (ProcessingPipeline.swift:418-431) adds `paused` to its refusal set (defense in depth — no path may process a paused meeting until End flips it). Launch sweeps, notes-pending self-heal, and handoff already cannot touch a clean paused meeting (verified by the audit); the kick gate closes the one hole.

## 3. Tracker / automation contract (C14)

- Manual pause sets a per-meeting `manualControl` flag in `MeetCallTracker`: lifecycle end events for that meeting are INGESTED (speaker windows; they pend past the ±10-minute correlation padding and correlate at End only if End falls within the window — a >10-minute pause WITHOUT resume leaves those events permanently pending; accepted: the cost is name-vote loss for that tail, never content loss) but produce NO state transitions; the `pendingEnds` buffer is drained without effect on resume.
- Pause during an ACTIVE grace window converts grace→paused (cancel that meeting's grace timer — the entry exists in that state, so cancellation is real). Pause while the auto-stop finalize is already running: the Pause control is DISABLED from controller state (not DB status) — no race window for the click.
- A paused meeting writes a paused-class suppression record that does NOT expire on the 10-minute silence rule (keyed to the durable status; cleared on Resume/End) — its own call can never re-post "Meeting in progress".
- The watchdog keys on in-memory `activeCall` (verified — not status); pause clears the active-call linkage so the watchdog has nothing to orphan; AC1 pins that a paused meeting survives a watchdog pass untouched.

## 4. Single-open-meeting + quit + UI

- `start()` REFUSES only when (a) a LIVE capture session exists in the controller, or (b) any meeting's durable status is `paused` — grace-window and finalize-in-flight meetings (durable status still `recording`, no live session) do NOT refuse, preserving the shipped stop-then-start back-to-back path (MeetCallTracker.swift:641-674); a typed refusal is returned. THE SAME PREDICATE GUARDS EVERY RESUME ENTRY (menu Resume, the C14 rejoin path, any watchdog-driven resume): resuming meeting X refuses when a live session exists or any OTHER meeting is `paused` (round-3 M-9 — never two open meetings through any door). The paused-refusal maps on every start surface (menu, main window, Record notification, calendar) to the prompt: "'<title>' is paused — End & process it, or Resume it instead?" Never two open meetings.
- Quit intercept: `paused` counts as open — dialog "End & process, or quit and keep it paused?"; quitting preserves state; relaunch surfaces the paused meeting with Resume / End & process.
- Indicator: NEW controller events `paused`/`resumed` (the shared stop path's `.stopping/.stopped` map to processing-display and are not reused), with display priority fully ordered: alarm > recording > processing > grace > paused > idle; static accent visual in all four directions. Menu + main-window controls show the three-state model; timer shows accumulated recorded time (sum of part durations) with "paused".
- No notifications for manual pause/resume.

## 5. Acceptance criteria

- AC1 (state machine + automation): every arc and refusal — pause/resume cycle; End-from-pause (the finalize entry flips paused→processing FIRST — in its own transaction, before any dispatch — so §2's refusal set never blocks a deliberate End; endedAt = the last part's end); quit-and-relaunch restores; auto-stop end event during pause = ingest-no-transition; grace→paused conversion WITHDRAWS the pending grace/watchdog notification; watchdog pass leaves paused untouched; start() refusal + prompt model AND the non-refusal cases (start during another meeting's grace window and the back-to-back correlated path stay green); suppression non-expiry while paused; `manualControl` cleared on Resume and on End; pause on a meeting already finalizing is a NO-OP (the disabled control minimizes but cannot eliminate the TOCTOU — the controller treats the late click as no-op).
- AC2 (pipeline): paused-then-resumed meeting processes end-to-end, transcript spans parts, no gap filler; End-from-pause processes N parts with no new part; zero-audio pause then End → the existing zero-audio handling fires at End only.
- AC3 (durability): the paused-status+part-finalize single transaction discriminated via the midTransactionHook seam (G7 pattern).
- AC4 (kill, gated BLAISE_TEST_CAPTURE): kill -9 AFTER the pause transaction commits → relaunch: part CAFs encoded by the sweep, NO dispatch kick, meeting `paused`, nothing handed off (the H-1 pin). Kill BEFORE the commit → today's kill-mid-capture semantics (it was never paused). Kill in the RESUME window (engine live, status still paused) → relaunch lands `paused`, the orphaned new-part CAF rescued as gap-free part residue, nothing processed. All three halves asserted.
- AC5 (UI/model): three-state control model; new indicator events + priority; timer accumulation. Renders eye-verified honestly.
- AC6: suite green; pins byte-identical; never-paused meetings byte-stable (asserted on the pinned meeting).

## 6. Out of scope

Extension-initiated pause; auto-pause heuristics; per-part editing/deletion.

## CHANGELOG
- v4 (12/06/2026): post-gate round-3 Mediums + wording Lows — Resume gated on sweep completion + no persistent live-engine-against-paused state (M-8); one refusal predicate guards every resume entry (M-9); priority fully ordered; End's flip-before-dispatch stated; AC4 gains the resume-window kill; prompt scoped to the paused refusal. L-18 (pre-existing start reentrancy) and remaining nits to BACKLOG at untangle. Spec cycle CLOSED: r1 0C/1H -> r2 0C/1H -> r3 PASS 0C/0H/2M/8L + v4 hygiene.
- v3 (12/06/2026): round-2 audit (0C/1H/1M/6L). H-2: start-refusal predicate = live-session OR durable paused (grace/finalize don't refuse; back-to-back path pinned green in AC1). M-7: resume order inverted — part-open then atomic part-row+status commit; every pre-commit crash lands durable paused under the §2 gate. Lows: >10-min-pause event-pend honesty, display priority given, manualControl lifetime, End-from-pause mechanics, grace-conversion notification withdrawal, finalize-click no-op TOCTOU wording.
- v2 (12/06/2026): round-1 audit (0C/1H/6M/4L). H-1: the sweep's auto-kick (not its encode) gated on `paused` + `dispatchProcessing` refusal set — the spec's false "keys on status" claim corrected against CaptureRecovery.swift:236-262/ProcessingPipeline.swift:418-431. M-1: no CHECK exists; migration directive removed. M-2: tracker contract specified (manualControl, pendingEnds drain, pend-past-padding stated). M-3: grace→paused conversion + controller-state-disabled button (the vacuous cancellation sentence dropped). M-4: zero-audio write is End-only. M-5: start() typed refusal + paused-class non-expiring suppression. M-6: status joins the finalize transaction; AC4 split pre/post-commit. Lows: resume write order, new indicator events, §2/§6 circularity resolved, speaker-event padding owned.
- v1 (12/06/2026): initial spec.
