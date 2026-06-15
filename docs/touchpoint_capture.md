# Human Touchpoint — Capture permissions (≤ 3 minutes)

Blaise records meetings from two sources at once: the **microphone** (your
voice) and **system audio** (everyone else, via a Core Audio process tap).
macOS gates each behind its own one-time permission dialog. Nothing else in
this touchpoint is needed — the rest of the capture path ships tested.

**One-time only.** The app is signed with a stable identity
(`Apple Development: <your-apple-id> (<TEAMID>)`), so macOS keeps
treating every rebuild as the same app and the grants persist. (If a build
ever warns about ad-hoc signing, the grants will stop sticking — fix the
keychain identity first.)

## Step 1 — Start a recording once (~1 min)

1. Open `dist/Blaise.app` (or launch the freshly built app).
2. Click the Blaise icon in the **menu bar** (waveform circle) →
   **Start Recording → In Person**.
3. Two dialogs appear, one after the other:
   - **"Blaise would like to access the microphone."** → **Allow**.
   - **"Blaise would like to record audio from other applications."** →
     **Allow**.
4. Wait a few seconds, then menu bar → **Stop Recording**. (This throwaway
   meeting will process in the background; delete-by-ignore is fine.)

## Step 2 — If you dismissed a dialog (recovery click paths)

Both grants live in **System Settings → Privacy & Security**:

- **Microphone**: System Settings → Privacy & Security → **Microphone** →
  toggle **Blaise** ON.
- **System audio**: System Settings → Privacy & Security →
  **Screen & System Audio Recording** → **System Audio Recording Only**
  section → add/toggle **Blaise** ON.

What each grant covers: Microphone = the input device only (your voice
track). System Audio Recording Only = the global audio mix of other apps
(the system track) — this is NOT screen recording; no screen content is
captured.

## Step 3 — Run the gated capture integration test (~2 min)

With both grants in place:

```bash
cd path/to/blaise/app
BLAISE_TEST_CAPTURE=1 ../scripts/test.sh --filter CaptureIntegrationTests
```

Green = the real capture path is verified end to end: 30 s two-track
capture, stop-encode to playable m4as, and the kill -9 crash variant whose
CAFs the startup sweep rescues. (The kill variant runs a child process from
`app/.build/debug/CrashRunner`; run from the same terminal so it inherits
the grants' responsible-process context. If only the kill variant fails with
a TCC prompt, approve it once and re-run.)

## Optional — Calendar suggestions (separate, skippable)

The menu's **Show Calendar Suggestions…** fires its own one-time prompt
(**"Blaise would like full access to your calendar"** → Allow). Decline and
the menu simply stays manual — nothing else depends on it.

## Notifications (C14 — meeting automation, ~30 s)

Recording automation (the "Meeting in progress — Record" offer, the
watchdog's Resume notification, and the calendar "Launch & Record"
reminder) uses standard macOS notifications.

1. At the first launch with **Meeting automation** enabled (Settings →
   Automation; it ships ON), macOS shows **"Blaise" Notifications May
   Include Alerts, Sounds, and Badges** → click **Allow**.
2. That is the whole touchpoint. Banners appear with the default style; no
   sounds are configured.

**If you clicked Don't Allow** (recovery path): System Settings →
**Notifications** → **Blaise** → toggle **Allow Notifications** ON and pick
**Banners** (or Alerts). Until then Blaise degrades honestly: auto-stop,
the rejoin grace window, and the watchdog still run, and every notification
surface has a menu-bar equivalent — "Meeting detected — Record", the
"Waiting for rejoin" countdown with **Resume Recording**, the calendar
reminder line, and the no-signals nudge all appear in the menu-bar menu. A
banner in Settings → Automation explains what is being missed. Be aware of
the named residual: with notifications denied, a watchdog false stop of a
still-live meeting is recoverable only if you glance at the menu bar within
the Resume window.

### C14 verification walkthrough (after the grant; ~20 min, needs a real Meet)

1. **Auto start/stop + grace**: join an ad-hoc meeting at meet.google.com
   in Chrome (extension installed, secret pasted). Within seconds a
   **"Meeting in progress"** notification appears → click **Record** (or
   the banner body). Speak briefly; roster/speaker events correlate live.
   **Leave** the call → the recording auto-stops within ~30 s (25 s
   debounce + signal latency), silently; the menu-bar icon shows the pause
   glyph and the menu shows **Waiting for rejoin (m:ss)**. Rejoin the same
   link within 5 min → recording resumes by itself (icon back to red).
   Leave again and let the window lapse → processing kicks; the library
   shows **ONE** meeting whose audio spans both parts (stitched, with
   silence in the gap) and whose notes cover both.
2. **Calendar path**: create a calendar event 3 min out with a Meet link
   (calendar access granted). At T−1 min the event-titled notification
   appears → **Launch & Record** opens the link in **Chrome** (not Safari)
   and recording starts carrying the event title/attendees.
3. **Watchdog path**: while recording a Meet call, **force-quit Chrome**
   (⌥⌘Esc → Force Quit, or `kill -9` — a normal quit runs pagehide and
   exercises the clean stop instead). Within ~6–7 min: auto-stop +
   **"Recording stopped — meeting appears to have ended"** with **Resume**.
