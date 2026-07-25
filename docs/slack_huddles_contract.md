# Slack Huddles contract (C15)

Native Slack Huddles integration. While you attend a Slack huddle (desktop or
web — client-agnostic), Blaise learns the huddle's participant roster and call
lifecycle **through Slack's own API** and feeds them into the same downstream
consumers as the Google Meet extension: speaker-naming inputs (attendee
absorption) and recording automation (the meet-start offer, auto-stop, and the
watchdog). No bot joins the huddle; no message is ever read; audio capture
stays the existing on-device CoreAudio process tap.

## Privacy model

- **Metadata only.** The bot scope is `users:read` — nothing else. Blaise reads
  *who* is in a huddle and *when* (presence transitions), never messages,
  never audio, never a huddle's contents.
- **Tokens never leave the machine.** Both tokens live in the macOS Keychain
  (via `SecretStore`), never in the settings database and never on disk in
  plaintext. The only network traffic is Blaise's own calls to `slack.com`
  (`apps.connections.open`, `auth.test`, `users.info`, and the Socket Mode
  WebSocket).
- **You are in control.** The connection runs only while the integration is
  enabled in Settings. Disconnect drops both tokens from the Keychain and
  closes the socket.

## Mechanism

A [Socket Mode](https://api.slack.com/apis/socket-mode) WebSocket receives
`user_huddle_changed` events. Each event carries the user object with
`profile.huddle_state` (`in_a_huddle` / `default_unset`),
`profile.huddle_state_expiration_ts`, and `profile.huddle_state_call_id` (e.g.
`R0123ABC456`). When **you** (self) enter a huddle, that call id identifies the
huddle; every other user whose event carries the **same** call id is a
co-participant. Join/leave timing is the event arrival time.

Batches enter the shared ingestion core as `MeetWireBatch`es with
`meetingCode: "slack:<callID>"`, `schemaVersion: 2`, `events: []`, and a roster
and/or a lifecycle signal — exactly the shape the Meet extension delivers, so
correlation, roster absorption, and the automation signal forward are shared
code (`MeetEventsIngestor.ingest(batch:)`). A recorded huddle files under
`MeetingSource.slack`.

### Honest limitations

- **No speaking intervals.** `user_huddle_changed` is presence, not
  who-spoke-when. Mechanical cluster→name voting stays empty for Slack
  meetings; naming flows through attendees → the allowed-name gate → the LLM
  naming pass. Roster names and stable Slack user ids are still delivered.
- **Workspace-wide delivery.** Slack documents `user_huddle_changed` as sent to
  all of a workspace's connections. If a workspace suppresses it for some
  users, the roster under-counts — degradation is *missing names, never wrong
  names*.
- **Setup needs a personal Slack app** (manifest below). Workspaces that
  restrict app installs need admin approval.
- **Lingering state.** `huddle_state` can linger after a huddle ends. End
  detection has two legs: an explicit state clear (the trusted signal), and the
  existing recording watchdog. `huddle_state_expiration_ts` is parsed but
  never consulted — it is an untrusted timestamp with an unverified refresh
  cadence, and ending a live recording on it would irrecoverably destroy that
  meeting's transcript and notes.
- **Belief is bounded.** Between self events "still in a call" is belief, and
  both the heartbeat and the roster flush are manufactured from it. After 4
  hours with no genuine self event the tracker stops **all** manufactured
  liveness — heartbeats *and* roster flushes — without ending the call, which
  lets the recording watchdog reclaim the session through its normal path (a
  notification with Resume when a resume window is configured, the default;
  an immediate finalize with an informational notification when it is Off —
  audio retained either way). Gating only the heartbeat would leave the bound
  inert whenever co-participants stay in the huddle, because downstream rearms
  its watchdog from any batch. Without the bound a dropped self-leave event
  would keep a recording running indefinitely.

## Tokens

| Keychain key | Token | Used for |
|---|---|---|
| `slack.appToken` | `xapp-…` (app-level, `connections:write`) | `apps.connections.open` |
| `slack.botToken` | `xoxb-…` (bot, `users:read`) | `auth.test` validation, `users.info` fallback |

Your own Slack member id (`U…`/`W…`, validated `^[UW][A-Z0-9]{5,}$`) is pasted at
setup and stored in the settings JSON (it is not a secret — it appears in every
event). Copy it from Slack: **Profile → ⋯ → Copy member ID**.

## Socket Mode lifecycle

1. `POST https://slack.com/api/apps.connections.open`, `Authorization: Bearer
   <xapp>` → `{ok: true, url: "wss://…"}`. Non-ok surfaces `lastError`.
2. Open the WebSocket. First frame is `{"type":"hello"}` (resets the backoff).
3. Event frames: `{"envelope_id": "…", "type": "events_api", "payload":
   {"event": {…}}}`. Blaise **acks immediately** — `{"envelope_id": "<id>"}`
   before processing; Slack redelivers unacked envelopes, so the tracker
   dedupes by `user.id + ":" + event_ts`.
4. `{"type":"disconnect"}` → close and reopen from step 1 (Slack refreshes
   links routinely; this is normal, not an error).
5. Reconnect: exponential backoff 1 s → 2 s → 4 s … capped at 60 s with jitter,
   reset on a successful `hello`. WebSocket pings every 30 s.
6. The connection runs only while enabled. An instance on a `BLAISE_DATA_ROOT`
   override does not connect unless `BLAISE_SLACK_SOCKET=1` (the same
   dev-instance hygiene as the Meet listener bind policy).

### `user_huddle_changed`

```json
{ "type": "user_huddle_changed",
  "user": { "id": "U012AB3CD", "name": "sam",
    "profile": { "display_name": "Sam", "real_name": "Sam Rivera",
                 "huddle_state": "in_a_huddle",
                 "huddle_state_expiration_ts": 1781136000,
                 "huddle_state_call_id": "R0123ABC456" } },
  "event_ts": "1781135000.001300" }
```

Display-name preference: `profile.display_name` if non-empty, else
`profile.real_name`, else `user.name`, else a `users.info` fetch; if that fails,
a nil name (the stable member id still travels) beats a wrong name.

## Tracker state machine (`SlackHuddleTracker`)

Driven per `user_huddle_changed` event plus a periodic evaluation tick:

1. **Self joins** (`user.id == selfUserID`, `in_a_huddle`, a call id, and no/other
   current call): set the current call id; emit a `callStarted` lifecycle plus a
   roster batch with self (`isSelf`, no display name — the consumer substitutes
   your identity name). Co-participant events buffered before your own join
   (see 4) flush into the roster.
2. **Co-participant update** (other user, `in_a_huddle`, same call id): upsert
   into the roster; emit/refresh the roster batch (coalesced to at most one per
   5 s of churn).
3. **Participant leaves** (other user, state cleared or call id changed): drop
   from the live roster. The roster is cumulative downstream — a leave does not
   retract the attendee.
4. **Foreign-call events while self is not in a call**: retained in a 60 s ring
   (they may precede your own join — stream order is not guaranteed);
   otherwise ignored. Blaise only ever tracks huddles you are in.
5. **Self leaves** (self event, state cleared or a different call id): emit
   `callEnded` (`reason: "left"`); clear state.
6. **Heartbeat** (tick): while in a call, emit a `heartbeat` lifecycle when no
   other batch has shipped for 60 s (feeds the recording watchdog's 5-min
   silence timer). Every emitted batch — callStarted, a roster flush, callEnded
   — counts as liveness and resets that 60 s window, so a busy call never emits
   a redundant heartbeat, and no two batches ever share a timestamp (which the
   downstream monotonic guard would otherwise reject).
7. **Liveness-belief bound** (tick): 4 hours past the last genuine self event,
   ALL manufactured liveness STOPS — heartbeats AND roster flushes (rule 2
   emits are liveness downstream exactly as a heartbeat is). The call is not
   ended — going quiet lets the recording watchdog reclaim the session through
   its normal path (a notification WITH Resume when a resume window is
   configured, the default; immediate finalize with an informational
   notification when it is Off — audio retained either way).
   Because every manufactured heartbeat refreshes that watchdog's signal clock,
   without this bound a dropped self-leave would suppress the watchdog forever
   and leave a recording running indefinitely. A fresh self event revives the belief; a
   roster change buffered while stale is not lost — it flushes on the next
   ELIGIBLE flush (normally the next tick, or immediately if a further roster
   event opens the direct-flush door), carrying the heartbeat lifecycle in the
   SAME batch so the revival is recognised by the kind-gated grace-resume path.

## App manifest

Create a Slack app **From an app manifest**, paste this, install to your
workspace, then copy the two tokens and your member id into Blaise's Settings →
Automation → Slack Huddles.

```yaml
display_information:
  name: Blaise Huddle Roster
  description: Feeds huddle participant names to the local Blaise app. Metadata only.
features:
  bot_user:
    display_name: blaise-roster
    always_online: false
oauth_config:
  scopes:
    bot: [ "users:read" ]
settings:
  event_subscriptions:
    bot_events: [ "user_huddle_changed" ]
  socket_mode_enabled: true
  org_deploy_enabled: false
```

## Setup walkthrough

1. Go to <https://api.slack.com/apps> → **Create New App** → **From an app
   manifest** → pick your workspace → paste the YAML above.
2. **Basic Information → App-Level Tokens** → generate a token with the
   `connections:write` scope. Copy the `xapp-…` value.
3. **Install App** (to your workspace; admin approval may be required). Copy the
   **Bot User OAuth Token** (`xoxb-…`).
4. In Slack, open your profile → **⋯ → Copy member ID** (`U…`).
5. In Blaise: **Settings → Automation → Slack Huddles** → paste the app token,
   the bot token, and your member id → **Connect**. The status line shows the
   workspace name and connection state.

## Out of scope (v1)

`huddle_thread` room-object history enrichment (needs history scopes), speaking
intervals (no public source), multi-workspace, OAuth-flow token acquisition
(manifest + paste is the v1 path), and renaming the `meet_*` tables/types.
