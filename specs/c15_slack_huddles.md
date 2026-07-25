# C15 Spec — Slack Huddles integration (native, Socket Mode)

CHANGELOG: v1.2 (2026-07-24) — pre-merge audit amendments (artifact: `audits/pr4-fixdiff/`). End detection loses the expiration leg: `huddle_state_expiration_ts` is now ADVISORY (logged and cleared, never `callEnded`) because the stamp is untrusted JSON against wall clock with an unverified refresh cadence, and a false stop irrecoverably destroys a meeting's transcript and notes. Replacing it, a **liveness-belief bound** (rule 8): 4 h with no genuine self event stops ALL manufactured liveness — heartbeats and roster flushes alike, since downstream rearms its watchdog from any code-carrying batch — without ending the call, handing the end to the recording watchdog's normal path. Touchpoint gains sub-question (f) (self-event cadence during a long huddle), which sizes both constants and would allow tightening the bound by an order of magnitude if Slack refreshes periodically.  v1.1 (2026-07-14) — adversarial-review amendments after implementation (all fixed + tested, suite green): (1) **prompt socket teardown** — `URLSessionWebSocketTask.receive()` does NOT observe Swift task cancellation, so the pump wraps every receive in `withTaskCancellationHandler` that cancels the channel; without it, a Disconnect left the socket live and a late frame could still trigger an auto-record offer after the user wiped their tokens (Critical; the original test doubles used `Task.sleep`, which honors cancellation, and masked this — the suite now includes a genuinely non-cooperative channel stub); (2) **token rotation** — `connect()`'s success path stops the running socket (awaited) before starting with fresh tokens; (3) **connection-state feedback** — `run()` reports hello/session-end to the model; ≥3 consecutive hello-less sessions surface a persistent failure into `lastError` (mirrors the extension's 3×401 badge rule) and the status line shows Connecting/Reconnecting; (4) **liveness collision** — EVERY emitted batch counts as heartbeat liveness (a tick that flushed a roster never also emits a heartbeat), closing a same-millisecond collision with `MeetCallTracker`'s monotonic guard that could delay grace-resume by up to 60 s; (5) Keychain read failure at load is surfaced in Settings (was write-only state); (6) the tracker tick loop exits on actor dealloc; (7) frames are ACKed via a lenient envelope-id pre-parse even when the strict frame decode fails (unacked envelopes are redelivered forever). Implementation deviations adopted into the spec: unified 5 s evaluation tick (roster coalescing + heartbeat + expiration backstop — one timer seam); the expiration backstop takes the latest self event's expiry verbatim (a refresh omitting it clears the backstop — heartbeats/watchdog carry liveness; safer than a stale expiry force-ending a live huddle); stale foreign-ring entries (> 60 s) never seed a late self-join's roster; **migration v18** (below) — v1 baked a frozen `CHECK(source IN (…))` into `meeting`, so adding a `MeetingSource` case requires the standard SQLite table rebuild.  v1 (2026-07-14) — initial spec.

## Goal

While the user attends a Slack Huddle (desktop app or web — client-agnostic), Blaise
learns the huddle's participant roster and lifecycle **natively**, via Slack's own
APIs, and feeds them into the SAME downstream consumers the Meet extension feeds:
attendee absorption / speaker-naming inputs, and recording automation (auto-start
offer, auto-stop, watchdog). No bot joins the huddle; no message content is ever
read; audio capture remains the existing CoreAudio process tap.

**Mechanism (verified against Slack docs 2026-07):** a Socket Mode WebSocket
receives `user_huddle_changed` events (bot scope `users:read` only). Each event
carries the user object with `profile.huddle_state` (`"in_a_huddle"` /
`"default_unset"`), `profile.huddle_state_expiration_ts`, and
`profile.huddle_state_call_id` (e.g. `"R0123ABC456"`). When SELF enters a huddle,
that call id identifies the huddle; every other user whose event carries the SAME
call id is a co-participant. Join/leave timing = event arrival times.

## Honest limitations (stated up front)

- **No speaking intervals.** `user_huddle_changed` gives presence, not who-spoke-when.
  Mechanical cluster→name voting (`SpeakerResolver.resolve`) stays empty for Slack
  meetings; naming flows through attendees → allowed-name gate → LLM naming pass.
  Roster names + stable Slack user IDs are still delivered.
- **Workspace-wide event delivery must be verified live** (Touchpoint below). Docs
  say `user_huddle_changed` is "sent to all connections for a workspace"; if a
  workspace suppresses it for non-shared-channel users, roster under-counts —
  degradation is missing names, never wrong names.
- **Setup requires creating a personal Slack app** (manifest in
  `docs/slack_huddles_contract.md`). Workspaces that restrict app installs need
  admin approval — stated in the docs, not worked around.
- `huddle_state` can linger after a huddle ends. End detection has two legs: an
  explicit state clear (the trusted signal) and the existing tracker watchdog.
  `huddle_state_expiration_ts` is ADVISORY — untrusted JSON compared against wall
  clock, with an unverified refresh cadence, so a passed expiry is logged and
  cleared and never ends a call (hard floor 1: a false stop irrecoverably
  destroys that meeting's transcript and notes).
- Between self events, "in a call" is BELIEF and the heartbeat is manufactured
  from it. Every heartbeat refreshes the downstream watchdog's signal clock, so
  an undelivered self-leave would suppress that watchdog indefinitely — hence
  the belief is BOUNDED: 4 h with no genuine self event stops ALL manufactured
  liveness — heartbeats and roster flushes alike (never ends the call), handing
  the end to the watchdog. With a resume window configured (the default) that is
  a notification WITH Resume; with "Resume window: Off" the stop finalizes
  immediately per C14. Audio is retained either way.

## Repo layout

- `app/Sources/BlaiseApp/SlackHuddlesIntegration.swift` — `SlackHuddlesModel`
  (settings/connect model, mirrors `GoogleCalendarModel`) + `SlackSocketClient`
  actor (injectable HTTP transport + WebSocket opener).
- `app/Sources/BlaiseCore/SlackHuddleTracker.swift` — pure clock-injectable state
  machine (event stream in → roster batches + lifecycle signals out).
- `app/Sources/BlaiseCore/SlackEvents.swift` — wire types (`Codable`): socket
  frames, `user_huddle_changed`, Web-API responses; `SlackHuddle` code namespace;
  `SlackMemberID` shape gate; `SlackSocketPolicy` dev gating.
- Tests: `SlackEventsTests`, `SlackHuddleTrackerTests`, `SlackHuddleIngestTests`
  (BlaiseCore); `SlackSocketClientTests`, `SlackHuddlesModelTests` (BlaiseApp).
- `docs/slack_huddles_contract.md` — contract + privacy note + app-manifest YAML +
  setup walkthrough. README: feature bullet + privacy-model line.

## Slack protocol contract

### Tokens (both stored via `SecretStore`, Keychain)

| Key | Token | Used for |
|---|---|---|
| `slack.appToken` | `xapp-…` (app-level, `connections:write`) | `apps.connections.open` |
| `slack.botToken` | `xoxb-…` (bot, `users:read`) | `auth.test` validation, `users.info` fallback |

Self identity: the user's Slack member ID (`U…`/`W…`), pasted at setup (Slack
profile → "Copy member ID"). Stored in settings JSON (not secret). Shape gate
`^[UW][A-Z0-9]{5,}$` at connect. The model pushes it into the tracker after
settings load (`setSelfUserID`); empty = safe no-op, no huddle ever tracked.

### Socket Mode lifecycle

1. `POST https://slack.com/api/apps.connections.open`, `Authorization: Bearer <xapp>`
   → `{ok: true, url: "wss://…"}`. Non-ok → surface `lastError`, retry with backoff.
2. Open `URLSessionWebSocketTask` on the URL. First frame is `{"type":"hello"}`.
3. Event frames: `{"envelope_id": "…", "type": "events_api", "payload": {"event": {…}}}`.
   **Ack immediately** (`{"envelope_id": "<id>"}`) — BEFORE processing and
   independently of the strict frame decode (lenient envelope-id pre-parse; an
   unacked envelope is redelivered forever). The tracker's dedupe absorbs any
   redelivery.
4. `{"type":"disconnect", "reason": …}` → close, reopen from step 1 (Slack refreshes
   links routinely; this is normal, not an error).
5. Reconnect: exponential backoff 1 s → cap 60 s with jitter; reset only after a
   session that saw `hello`. WS pings every 30 s. Every receive is wrapped in
   `withTaskCancellationHandler` cancelling the channel — `URLSessionWebSocketTask.
   receive()` does not observe Swift task cancellation, so without the explicit
   channel cancel a disconnect would leave the pump blocked until the next inbound
   frame, which would still be ACKed and delivered AFTER the user disconnected.
6. Connection-state feedback: `run()` reports connected/session-ended to the
   model; ≥ 3 consecutive hello-less sessions → persistent failure in `lastError`
   (mirrors the extension's 3×401 badge rule); status shows
   Connecting/Reconnecting while not live.
7. Connection runs ONLY while the integration is enabled in Settings. Instances
   running with a `BLAISE_DATA_ROOT` override do not connect unless
   `BLAISE_SLACK_SOCKET=1` (same dev-instance hygiene rationale as the Meet
   listener bind policy).

### `user_huddle_changed` (the only event consumed)

```json
{ "type": "user_huddle_changed",
  "user": { "id": "U012AB3CD", "name": "sam",
    "profile": { "display_name": "Sam", "real_name": "Sam Rivera",
                 "huddle_state": "in_a_huddle",
                 "huddle_state_expiration_ts": 1781136000,
                 "huddle_state_call_id": "R0123ABC456" } },
  "event_ts": "1781135000.001300" }
```

Display name preference: `profile.display_name` if non-empty, else
`profile.real_name`, else `user.name`, else nil with a `users.info` fetch as the
caller's last resort (cached per user id; nil name beats wrong name).

## Tracker state machine (`SlackHuddleTracker`, actor, BlaiseCore)

State: `selfUserID`, `currentCallID?`, `participants: [userID: (name, joinedAt)]`,
`seenEventKeys` (dedupe: `user.id + ":" + event_ts`, FIFO-capped 4096), foreign
ring, roster/heartbeat clocks. One unified 5 s evaluation tick drives roster
coalescing, heartbeat, the expiration advisory, the liveness-belief bound, and ring pruning; tests drive
`tick(now:)` with an injected clock (`MeetCallTracker` pattern).

Transitions (all driven by `user_huddle_changed`):

1. **Self joins** — self event, `in_a_huddle`, call id `R…`, different from
   `currentCallID`: (a different id ends the old call first, reason `"left"`) set
   `currentCallID`; emit `callStarted` riding ONE batch with the initial roster —
   self (`isSelf: true`, **`displayName: nil`** — the consumer substitutes
   `UserIdentity.name`, same rule as Meet; `participantID` = member id) plus any
   FRESH (≤ 60 s) buffered co-participant events for that call id.
2. **Co-participant update** — other user, `in_a_huddle`, call id ==
   `currentCallID`: upsert `{displayName, participantID: userID, isSelf: false}`;
   roster batches coalesce to at most one per 5 s (immediate when the window
   already elapsed, else tick-flushed).
3. **Participant leaves** — other user, state cleared or call id changed: remove
   from `participants`. The roster is cumulative downstream — removal never
   retracts an attendee, it only stops asserting their presence.
4. **Foreign-call events while self not in a call**: retained in a 60 s ring —
   they may precede self's own join (workspace stream ordering is not
   guaranteed); stale entries never seed a roster. Foreign-call events while IN a
   call are ignored. Blaise only ever observes huddles the user is in.
5. **Self leaves** — self event with state cleared or different call id: emit
   `callEnded`, reason `"left"`.
6. **Expiration advisory** — tick: `now > huddle_state_expiration_ts + 120 s` with
   no refreshing self event → log once, clear the stamp. **No lifecycle emitted;
   the call is never ended.** The latest self event's expiry is taken verbatim (a
   refresh omitting it clears the stamp). An untrusted timestamp must never stop a
   possibly-live recording.
7. **Heartbeat** — while in a call, a `heartbeat` lifecycle batch every 60 s of
   emission silence. EVERY emitted batch counts as liveness: a tick that flushed
   a roster never also emits a heartbeat, so no two batches share a timestamp and
   `MeetCallTracker`'s monotonic guard never starves the kind-gated grace-resume
   path (same rule as the extension's "heartbeats skipped when any batch shipped
   within 60 s").
8. **Liveness-belief bound** — tick: `SlackHuddleTracker.livenessBeliefMaxAgeSeconds`
   (4 h) past the last genuine self event, ALL manufactured liveness stops —
   heartbeats AND roster flushes (rule 2), since downstream rearms its watchdog
   from ANY code-carrying batch, so gating only the heartbeat leaves the bound
   inert whenever co-participants remain in the huddle. The call is not ended
   and no lifecycle is emitted. Rationale: rule 7's heartbeat is manufactured from
   belief and refreshes `MeetCallTracker.lastSignalAt`, so an undelivered
   self-leave would suppress that 5-min watchdog forever and leave a recording
   running indefinitely. Going quiet instead lets the watchdog stop the recording
   through its normal path: with a resume window configured (the default) that is
   a user-visible notification WITH Resume and a grace window, so a false trigger
   costs one click rather than a lost meeting; with "Resume window: Off" the stop
   finalizes immediately and the notification is informational, per C14 §3. Audio
   is retained either way. A fresh self event revives the belief;
   the roster change buffered while stale is NOT lost — it flushes on the next
   tick, carrying the heartbeat lifecycle in the same batch so the revival is
   recognised by the kind-gated grace-resume path. The constant is generous
   against a ~45-min average meeting because Slack's self-event cadence during a
   long huddle is UNVERIFIED (Human Touchpoint below); confirming a periodic
   refresh would allow tightening it by an order of magnitude.

All emissions are `MeetWireBatch`es (`meetingCode: "slack:<callID>"`,
`events: []`, `schemaVersion: 2`) through ONE seam: the `MeetBatchIngesting`
protocol → `MeetEventsIngestor.ingest(batch:)`, the new public in-process entry
sharing the decrypt path's core (`accept`: freshness gate, ±10-min / live-session
correlation, pending storage, roster absorption, post-commit signal forward to
`MeetCallTracker` — auto-record offer, auto-stop, watchdog all come free).

## Generalizations (minimal, mechanical)

- `MeetingSource` gains `.slack` + `init(forMeetingCode:)` (prefix-derived);
  `MeetCallTracker.startCorrelated` uses it instead of hardcoding `.meet`.
- **Migration v18** — v1 baked `CHECK(source IN (…))` into `meeting` with the
  rawValues frozen at v1-run time, so a `slack` INSERT would fail on any migrated
  DB. Standard SQLite table rebuild (v14 precedent, generalized to an FK-target
  parent table; the migrator's default deferred FK checks make the drop/rename
  safe); the rebuilt table drops the source CHECK entirely — the Swift enum is
  the validity boundary (v1's own stated stance for `status`), so future source
  additions never need another rebuild. Fresh and migrated DBs converge on
  identical schema.
- `meet_*` table names and `MeetWire*` type names stay (string-generic already);
  renaming is cosmetic churn, out of scope.

## Settings (`SlackHuddlesModel`, mirrors `GoogleCalendarModel`)

- Section "Slack Huddles" (Automation tab): enable toggle; two SecureFields (app
  token, bot token → Keychain); member-ID field; status line (Disconnected /
  Connecting / Reconnecting / Connected + age of last event); Connect / Reconnect
  / Cancel / Disconnect (Disconnect drops both tokens from the Keychain and tears
  the socket down).
- Connect validates `auth.test` (bot token; yields workspace name), 
  `apps.connections.open` (app token), member-ID shape. Epoch-guarded (Google
  precedent): a connect resolving after Cancel/Disconnect cannot store tokens or
  resurrect the connection. Reconnect with rotated tokens stops the old socket
  first (an awaited teardown — otherwise the old socket streams the old
  workspace forever). A Keychain read failure at load is surfaced via
  `settingsError`, never rendered as "no tokens saved".

## Tests (no network; swift-testing, fixture-driven)

Decode fixtures (hello / disconnect / envelope variants incl. missing call id and
empty names); every tracker transition above (redelivery dedupe, ring flush +
stale-ring guard, the expiration advisory, the liveness-belief bound (heartbeats AND roster flushes stop; a co-participant event emits nothing; revival flushes the buffered roster), heartbeat cadence + roster-suppression +
no-same-tick-collision, rejoin semantics, unconfigured-self no-op); socket client
(connections.open non-ok, ack-before-process, ack-despite-undecodable-frame,
disconnect→reconnect, backoff caps, status reporting, **prompt teardown against a
genuinely non-cooperative channel** — one that ignores task cancellation like the
real `URLSessionWebSocketTask.receive()`); model (validation failures, token
store/clear, epoch guard, token rotation, connection-health streak, Keychain
read-failure surfacing); in-process ingest parity with the decrypt path
(dedupe/correlation shared; `slack:` codes correlate live and via the ±10-min
rule); migration v18 (populated-v17 rebuild preserves rows + indexes; schema
convergence).

## Acceptance criteria

1. `swift build` + full suite green (`scripts/test.sh`, all shards).
2. New unit tests above green; no regression in Meet ingestor/tracker tests.
3. `docs/slack_huddles_contract.md` + README privacy note written.
4. No new network calls except `slack.com` (`apps.connections.open`, `auth.test`,
   `users.info`, the WS). No message-content scopes anywhere.
5. Dev-instance hygiene: `BLAISE_DATA_ROOT` set → no socket unless `BLAISE_SLACK_SOCKET=1`.

## Human Touchpoint (OPEN — blocks the final "done" claim)

Live huddle with ≥ 2 participants: verify (a) `user_huddle_changed` arrives for ALL
participants over Socket Mode with bot `users:read`; (b) `huddle_state_call_id`
present and shared; (c) display names inline vs needing `users.info`; (d) event
latency vs join time; (e) auto-record offer fires and auto-stop lands after
leaving; **(f) SELF-EVENT CADENCE during a long huddle — does Slack re-emit a self
`user_huddle_changed` (refreshing `huddle_state_expiration_ts`) periodically, or
only at join?** Amend this spec with findings (C12's field-amendment precedent).

(f) is load-bearing for rules 6 and 8: both the expiration advisory and the 4 h
liveness-belief bound are sized for the pessimistic answer ("only at join").
A confirmed periodic refresh would let rule 8's constant tighten by an order of
magnitude, and would make a passed expiry meaningfully informative rather than
merely advisory. Until (f) is answered, treat both constants as deliberately
conservative rather than tuned.

## Out of scope

`huddle_thread` room-object history enrichment (needs history scopes), speaking
intervals (no public source), multi-workspace, OAuth-flow token acquisition
(manifest + paste is the v1 touchpoint), renaming `meet_*` tables/types.
