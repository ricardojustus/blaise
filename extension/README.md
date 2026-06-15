# Blaise Meet Companion (Chrome extension)

Passive MV3 extension: while the user attends a Google Meet call in their own
browser, it captures the participant roster and active-speaker timing from
the page DOM and delivers both — AES-256-GCM encrypted — to the Blaise app
at `127.0.0.1:18429`, buffering silently when the app is down. No bot joins
the meeting; nothing is automated in the Meet UI; nothing leaves the
machine.

## Privacy note

Captured: participant **display names**, **speaking start/end times**
(wall-clock), the **meeting code** from the URL, and Meet's **opaque
per-session participant ids** (used to link a tile to its panel row; not
account identifiers). Nothing else — no audio, no captions, no chat, no
URLs. Every batch is encrypted with a key
derived from a shared secret before it touches the network, and the only
network destination the extension can reach at all (`host_permissions`) is
`http://127.0.0.1:18429` — this machine. If another process squats that
port it receives ciphertext it cannot decrypt and cannot forge
acknowledgments for (see `docs/meet_events_contract.md`).

## Loading unpacked

1. Chrome → `chrome://extensions` → enable **Developer mode**.
2. **Load unpacked** → select this `extension/` directory.
3. The "Blaise Meet Companion" action icon appears. A `…` badge means
   buffering (no secret configured, or 3+ consecutive failed deliveries
   with the app down); `!` means check the secret (or, rarely, that
   extension storage writes are failing).

Branded Chrome 137+ removed `--load-extension`, so the automated smoke test
uses Chrome for Testing instead: `npm run smoke` (downloads CfT on first
run; asserts the extension's service worker registers).

### Updating an already-loaded copy

After pulling a new extension version (check `manifest.json` →
`"version"`), Chrome keeps running the OLD code until you:

1. `chrome://extensions` → press **Reload** (circular arrow) on
   "Blaise Meet Companion" — restarts the service worker with the new code;
   **and**
2. **refresh any Meet tab that is already open** — content scripts are
   injected at page load, so an open tab keeps running the old capture code
   until it reloads.

The configured secret and any buffered undelivered batches survive the
reload (`chrome.storage.local`).

## Options setup (one-time, ~30 s)

1. In Blaise: Settings → Meet extension → reveal the shared secret, copy it.
2. Right-click the extension icon → **Options** (or chrome://extensions →
   Details → Extension options).
3. Paste the secret, **Save**.

Rotating the secret = regenerate in Blaise Settings, paste the new value
here. A stale secret shows up as the persistent `!` badge after a few
rejected deliveries.

**Habit worth keeping:** open the People panel once after joining (one
click, leave it open). Tiles alone under-count participants in large calls;
the panel is the authoritative roster, and the extension never opens it for
you by design.

## Tests

```sh
cd extension && npm install && npm test     # vitest + jsdom, no Chrome needed
npm run smoke                               # Chrome-for-Testing load smoke
```

`scripts/test.sh` at the repo root runs the suite too (skips with a
recorded reason only if no Node ≥ 20 is available).

## Capturing a real DOM snapshot (Human Touchpoint)

The committed fixtures in `test/fixtures/` are **labeled reconstructions**
from OSS DOM references (see each file's header). To replace them with
reality:

1. Join any Meet call, open the People panel.
2. DevTools (⌥⌘I) → Console → context dropdown (top-left of the console,
   says "top") → select **Blaise Meet Companion**.
3. Run: `__blaiseSnapshot("meet_live")`
4. Two files download: `meet_live.html` (allowlist-sanitized: synthetic
   names, only `class`/`role`/pinned `data-*`/rewritten `aria-*` survive,
   all URLs and other attributes stripped at capture) and
   `meet_live.digests.json` (SHA-256 of the replaced names).
5. Move `meet_live.html` into `test/fixtures/`, update tests/selectors to
   the real structure, and replace the two interim carve-outs in
   `src/selectors.js` (self-tile label set, leave-button labels) with
   structural markers discovered from the snapshot.
6. The digests sidecar may sit next to it for the local hygiene check but
   is **gitignored — never commit it** (unsalted name digests are
   dictionary-recoverable).

## Updating selectors when Meet rotates

`src/selectors.js` is the single rotation point — every DOM dependency
lives there, annotated with its source and last-verified date. When Meet
changes:

1. `npm test` — the selectors tripwire and roster tests point at what broke.
2. Capture a fresh sanitized snapshot (above) and fix the strategy in
   `src/selectors.js` only. Prefer `data-*` attributes and `role` structure;
   never obfuscated class names; never localized text (the three carve-outs
   — self-tile labels, leave-button labels, pin-label name templates — are
   bounded exceptions documented in the file).
3. Re-run `npm test` and `npm run smoke`.

## Layout

- `manifest.json` — MV3; permissions: `storage`, `alarms`;
  host: `http://127.0.0.1:18429/*` only.
- `src/selectors.js` — DOM strategies (the rotation point).
- `src/observer.js` — roster extraction + self model, speaking
  MutationObserver, snapshot sanitizer.
- `src/events.js` — coalescing (merge ≤ 3000 ms, drop < 500 ms), FIFO ring
  (10k events), delivery manager (status contract + signed acks).
- `src/crypto.js` — AEAD + signed-ack primitives (WebCrypto).
- `src/content.js` — in-call lifecycle, batching glue, `__blaiseSnapshot`.
- `src/background.js` — service worker: chrome.storage / chrome.alarms /
  badge wiring around the delivery manager.
- `docs/meet_events_contract.md` (repo root) — the binding wire contract;
  `test/fixtures/wire_batch_golden.json` + `expected_ingestion.json` are its
  executable form, consumed by the app-side listener's acceptance tests.
