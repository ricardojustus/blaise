# Changelog

All notable changes to Blaise are documented here. Dates are DD/MM/YYYY.

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

[1.4.0]: https://github.com/ricardojustus/blaise/releases/tag/v1.4.0
[1.3.0]: https://github.com/ricardojustus/blaise/releases/tag/v1.3.0
[1.2.0]: https://github.com/ricardojustus/blaise/releases/tag/v1.2.0
