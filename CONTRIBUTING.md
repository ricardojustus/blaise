# Contributing to Blaise

Thanks for helping build Blaise. This document covers how to build it, how to run
the tests, and the rules a pull request needs to follow.

## Prerequisites

- **macOS 26 or later** and **Xcode 26** for the app and its tests.
- **Node.js 22 or later** for the Chrome extension's test suite.

The app is a pure Swift Package Manager project — there is no `.xcodeproj`. The
scripts invoke the Xcode toolchain's `swift` directly with an explicit SDK root,
so the Xcode licence does not need to be accepted to build or test.

**Activate the leak tripwire (one time, after cloning).** This repo ships a
pre-commit hook that blocks accidental commits of confidential data. Git does
not enable committed hooks automatically, so run once:

```sh
git config core.hooksPath .githooks
```

A required CI `secret-scan` job runs the same checks on every push as an
un-bypassable backstop, but activating the local hook catches issues before they
leave your machine.

## Building

```sh
scripts/build_app.sh      # release build → dist/Blaise.app, prints the app path
```

The first build fetches the pinned Swift package dependencies. Release builds are
unsigned by default; on a developer machine the script falls back to ad-hoc
signing with a warning.

## Testing

```sh
scripts/test.sh           # the full suite: Swift tests + the extension tests
```

`scripts/test.sh` runs the Swift Testing suite (`BlaiseCoreTests`) and the Chrome
extension's `vitest` suite. Extra arguments pass through to `swift test`, e.g.
`scripts/test.sh --filter ULIDTests`.

For the full run, `test.sh` shards the Swift suite across fresh processes
(`scripts/test_sharded.sh`): swift-testing parallelizes in-process, and running
the whole suite in a single process hits a cooperative-pool contention limit at
scale. **Run the full suite via `scripts/test.sh`, not a bare `swift test`** — a
bare full-suite run can hang. A filtered run (`scripts/test.sh --filter X`, or
`swift test --filter X` directly) is fine.

The extension suite can also be run on its own:

```sh
cd extension && npm install && npm test    # vitest + jsdom, no Chrome needed
npm run smoke                              # Chrome-for-Testing service-worker load smoke
```

### Environment-gated tests

Some tests need resources that are not present in every environment: real audio
hardware, a cloud API key, or heavyweight on-device models. These **skip cleanly
and record the reason** — a skipping test writes its reason to a file under
`.test-skips/`, and the run clears that directory first so a stale skip can never
mask a real result. A skip is a recorded, inspectable fact, never a silent pass.
The extension suite likewise records a skip reason if no suitable Node is found.

If you are working on something gated, run it with the required resource present
before you claim it passes, and say so in the PR.

## The honesty bar (non-negotiable)

This project's tests are trustworthy because of one rule: **never weaken, fake, or
game a test to make it pass.** A test that fails should be fixed by fixing the
code or by correcting the test's expectation when the expectation was genuinely
wrong — never by loosening a threshold, deleting an assertion, or stubbing out the
thing under test to dodge it. If a threshold feels too strict, raise it for
discussion in the PR rather than quietly relaxing it. A truthful red is worth more
than a dishonest green.

## Fixtures: real audio is openly licensed, not personal

The one audio fixture in the test suite is **real speech, but openly licensed and
free of personal data**. Everything else is invented.

- **The shipped audio fixture is a CC-BY clip, not a private meeting.** It is a
  roughly five-minute excerpt of the [ICSI Meeting Corpus](https://groups.inf.ed.ac.uk/ami/icsi/)
  (meeting `Bmr001`) — real multi-speaker English meeting speech from consenting
  research participants, recorded over twenty years ago, so it carries no
  personal-data or NDA exposure. It is distributed under **Creative Commons
  Attribution 4.0 (CC BY 4.0)**: redistributable and usable commercially, with
  attribution the only obligation. The clip and its derived speech-recognition and
  diarization JSON live under `fixtures/icsi_sample/`, alongside an `ATTRIBUTION.md`
  notice and the full `LICENSE-CC-BY-4.0.txt`. **That directory is not covered by
  the project's MIT licence, and the CC-BY attribution must be preserved on
  redistribution** — keep the notice and licence file intact if you copy the clip
  or its derivatives.
- **Every other fixture uses invented names.** Vocabulary lists, golden clauses,
  and mock demo meetings use the fictional Vexatron Labs / Quoll Harbour universe.
  The glossary used by the regression fixtures is an example glossary, not anyone's
  real contacts.

### Opportunistic-local tests

Some tests look for the developer's own locally recorded meetings to exercise the
real-world cases the CC-BY clip cannot — Portuguese/English code-switching in
particular. These are **opt-in and read-only**: they run only when explicitly
enabled, they read a snapshot of the local Blaise data root without ever mutating
it, and when no local meeting is present they **skip cleanly and record the reason**
to `.test-skips/`. None of this data is ever committed.

A PR that adds a fixture derived from a private meeting, a non-open-licensed
recording, or personal data will not be merged.

## Specs come first

Every subsystem is described by a spec under `specs/`. The specs are
**current-state prose** — they describe how the system behaves now, with no audit
trails, change logs, or "round N" annotations in the body.

If your change alters a subsystem's behaviour, **update its spec in the same PR**.
Treat the spec as part of the change, not documentation written afterwards. A
behaviour change without a matching spec edit is incomplete.

## Pull requests

- **`main` is protected.** You cannot push to it directly. Every change lands
  through a pull request.
- A PR can be merged only when **CI is green** and it has **at least one
  approving review**.
- Keep PRs focused. A bug fix does not need surrounding refactors; a one-shot
  change does not need new abstractions. Do the simplest thing that works well and
  leave unrelated cleanup for its own PR.

## Commit style

- Write commit subjects in the **imperative mood** ("Fix drift in two-track
  interleave", not "Fixed" or "Fixes").
- For a **bug fix, put the evidence in the commit message**: what was wrong, how
  you reproduced it, and how you confirmed it is fixed. A fix message that a cold
  reader can follow is part of the fix.
