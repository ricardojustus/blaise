# Changelog

All notable changes to Blaise are documented here. Dates are DD/MM/YYYY.

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

[1.3.0]: https://github.com/ricardojustus/blaise/releases/tag/v1.3.0
[1.2.0]: https://github.com/ricardojustus/blaise/releases/tag/v1.2.0
