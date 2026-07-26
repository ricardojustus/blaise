# Changelog

All notable changes to Blaise are documented here. Dates are DD/MM/YYYY.

## [1.5.0] — 26/07/2026

The community release. Slack Huddles support, a participant confirmation gate, capture that
survives audio-device changes, and readable tables in notes. Three of the four largest changes
here are contributed by @arthursoares.

> This build is not signed with a Developer ID. macOS will warn on first open (right-click →
> Open, or System Settings → Privacy & Security → Open Anyway). Signed and notarised builds ship
> in the next release.

### Added
- **Slack Huddles integration** (@arthursoares). While you are in a huddle, Blaise learns the
  participant roster and the call lifecycle through Slack's own API and feeds them into the same
  speaker-naming and recording-automation flow as Google Meet. Metadata only — the bot scope is
  `users:read`, so Blaise reads who is in a huddle and when, never messages, never audio, and no
  bot joins the call. Both tokens live in the macOS Keychain. Setup uses a personal Slack app from
  the manifest in `docs/slack_huddles_contract.md`. Honest limitation: Slack exposes presence, not
  who-spoke-when, so huddle speaker naming leans on the roster rather than voice matching.
- **Slack in the manual recording source picker**, bound to the live huddle when one is tracked.
  Requested by @bdejong (#7).
- **Participant confirmation gate** (@arthursoares, opt-in, off by default). When Blaise cannot
  learn who attended from your calendar or a roster, it asks. Names land before the notes are
  written, so speaker labels and action-item owners are attributed correctly instead of being
  corrected afterwards. Transcription and audio retention are never held up — only the notes wait.
  A meeting awaiting your answer stays visibly marked in the library list, and an optional
  sub-toggle writes the notes without names after five minutes.
- **Transcript Markdown sidecar** (opt-in, off by default): writes the full transcript as its own
  Markdown file alongside the delivered payload, on whichever destination you have configured.
- **Destination hygiene and audio delivery** (@arthursoares): optionally remove superseded payloads
  at the destination so one current file per meeting remains (off by default — every delivered
  version is kept unless you turn it on), and optionally include the meeting's audio recordings
  with the delivery (off by default, the privacy default, since a syncing destination means audio
  leaves the machine).

### Changed
- **Markdown tables render as tables** in the notes view, wrapping to the notes column instead of
  running off the edge. No new dependencies.
- **Speaker-layer unification** (@arthursoares): correcting a name in the notes now also updates
  the matching speaker rename and the stored transcript in the same pass, so a meeting's transcript
  and its notes can no longer disagree about who someone is.

### Fixed
- **Recording no longer breaks when audio devices change** (@arthursoares). Switching or unplugging
  a device mid-meeting could leave a track silently empty behind a healthy-looking indicator. The
  capture path now detects the change, rebuilds cleanly, tolerates transient failures through a
  bounded retry ladder, and raises a visible warning if capture is genuinely down. Two pre-existing
  failure modes and a reproducible crash on a degenerate fallback sample rate were fixed alongside.
- **The participant dialogue closes as soon as your answer is saved**, instead of staying frozen
  until the notes finish generating.
- **Searching no longer strips formatting.** Bold, italics and links now survive while a match is
  highlighted.

## [1.4.0] — 10/07/2026

A polish and reliability release: live recording feedback, clearer menu-bar state,
search highlighting, faster meeting notifications, and a community fix for the
Google Calendar connection.

### Added
- **OAuth client secret field** for Google Calendar. Google's token endpoint requires
  `client_secret` for "Desktop app" OAuth clients even with PKCE, so token exchange
  always failed without it. The secret is stored in the Keychain (never the settings
  database) and sent only on token grants. Thanks to **@arthursoares** (#2, #3).
- **Cancellable Google sign-in.** A Cancel button and a "Waiting for Google sign-in…"
  status while authorizing; pre-consent errors in the browser no longer leave
  Settings stuck behind a disabled button.
- **Menu-bar status states.** Distinct icons for ready, meeting detected, recording,
  paused, processing, and warning, with a rebuilt menu-bar layout and recording
  controls.
- **Search-term highlighting.** Matching query terms are highlighted throughout
  notes, action items, decisions, and transcript text, with punctuation- and
  diacritic-normalized matching.

### Changed
- **Live recording visualization.** The mic and system level meters now reflect live
  audio instead of sitting low.
- **Faster meeting notifications.** Meet start/end events are evaluated on arrival
  instead of waiting for a later sweep; meeting detection is visible in the menu and
  sidebar even when notification delivery fails.
- **Reason-aware meeting-end handling.** Explicitly leaving a call stops the
  recording after a visible 5-second countdown; a tab close or reload keeps the
  25-second reconnect cushion. Reconnecting cancels the pending stop.
- **Visual pass.** Transparent native window chrome, refined design tokens and
  cards, responsive toolbar behavior, and transient overlay scroll indicators.
- **Notification actions.** Rebuilt categories and actions (Record, Launch & Record,
  Resume, Open Blaise) with observable delivery diagnostics.
- **Chrome extension.** Meet start/end signal lifecycle, selectors, and event
  batching hardened.
- Build numbers are now monotonic (derived from the commit count) instead of
  hardcoded.

### Fixed
- Google Calendar token exchange for Desktop-app OAuth clients (see Added).
- Calendar connection errors are surfaced in Settings instead of hiding behind a
  green "Connected" badge, and credential persistence failures are reported.
- First day-group header spacing under the transparent chrome.

## [1.3.0] — 2026-07-09

The first feature release since the initial public 1.2. Focus: notes and digest
quality, recording reliability, calendar awareness, and a zero-cost local-account
synthesis option.

### Added
- **Google Calendar (optional, read-only).** Connect a Google account via OAuth to
  see upcoming meetings alongside the local calendar, with a per-calendar picker,
  all-day filtering, and a collapsible upcoming list.
- **Account synthesis engine.** Generate notes and the memory digest through your
  Claude subscription CLI as a selectable engine — a near-zero-marginal-cost
  alternative to the metered API path, chosen in Settings.
- **Silence auto-pause.** Recording automatically pauses after a sustained window of
  dual-track silence (mic and system both quiet), guarding against runaway
  recordings when a meeting's end isn't detected. Configurable, on by default.
- **Cost tab.** A Settings breakdown of per-run synthesis spend.
- **Audit-model toggle.** Opt into a cheaper model for the digest audit pass as a
  cost lever (off by default).

### Changed
- **Memory digest quality.** The machine-facing digest was reworked across several
  iterations: transcript-grounded extraction, a combined verify-and-reconcile audit
  pass, an optional knowledge-glossary for entity resolution, and grounded
  person-mention hints — substantially reducing misattribution and phantom entries.
- **Speaker attribution.** Per-segment re-attribution using the meeting's
  active-speaker timeline improves who-said-what accuracy.
- **Notes reliability.** Notes generation now enforces a JSON schema, retries thin or
  truncated output, coerces loose model output to the schema, and drops empty action
  items at render time.
- **Language detection.** More robust multi-window detection of a meeting's dominant
  language.

### Fixed
- Stuck "Processing" indicator in some states.
- Escaping and formatting edge cases in account-engine notes output.

[1.5.0]: https://github.com/ricardojustus/blaise/releases/tag/v1.5.0
[1.4.0]: https://github.com/ricardojustus/blaise/releases/tag/v1.4.0
[1.3.0]: https://github.com/ricardojustus/blaise/releases/tag/v1.3.0
[1.2.0]: https://github.com/ricardojustus/blaise/releases/tag/v1.2.0
