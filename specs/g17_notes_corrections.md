# G17 — Span-anchored corrections and notes on a finished meeting

Status: briefing draft (written 2026-07-24, from the correction-flow design session; interactive mock reviewed by the user and by an external UX review, decisions below reflect both). Build on `g17-notes-corrections`.

## Purpose

After a meeting is processed, the notes sometimes carry an **understanding error** (the synthesis over-claimed, misattributed, or misread something) or are simply missing something only the user knows. Today the only remedies are surgical (correct-name, speaker rename — both deterministic string-level fixes) or nuclear (full Regenerate, which re-runs ASR and re-rolls the synthesis without any user guidance). There is no way to *tell the notes what was actually true* and have the synthesis honor it.

G17 adds two span-anchored actions on any notes block (summary, detailed-notes paragraph, decision, action item) of a `ready` meeting:

- **Suggest a correction** — the user states what's actually true; the notes are re-synthesized with that correction as authoritative context. Default scope re-uses the persisted transcript (notes-only re-run); a demoted "Re-transcribe from audio" escape hatch covers transcript-level mishearings.
- **Add a note** — a user-authored margin note. No model call: it renders deterministically into the notes and ships with the next delivery.

Both are **durable rows that survive every later re-run** — a full Regenerate re-reads them, so user truth is never erased by reprocessing. That durability is the core design commitment; everything else follows from it.

## UX decisions (post-review; the mock is the visual reference)

1. **"What's actually true?" is the sole primary decision.** The correction popover leads with the quoted span (trimmable) and the correction field. Processing depth is NOT a primary choice: notes-only re-write is the default and runs on save. "Re-transcribe from audio (~4 min)" sits behind a disclosure with one sentence of guidance ("use when a word itself was misheard — the transcript is re-created from the kept audio"). The save button's label follows the effective scope ("Save & re-write" / "Save & re-transcribe").
2. **Visible affordance, not bare prose.** Hovering a block reveals a trailing action control; right-click works as a shortcut; blocks are keyboard-focusable. Plain click continues to select text (never hijacked).
3. **Corrections are manageable, and deletion is the undo.** The provenance line counts corrections and notes separately ("2 corrections · 1 note"); its popover lists each row with edit/delete. Deleting a correction and re-running notes IS revert — synthesis re-runs without it. Payloads are immutable per version-hash regardless, so no delivered artifact is ever mutated in place.
4. **Auto re-delivery stays.** Every existing correction flow (rename, speaker, correct-name) re-delivers without asking; G17 matches. Copy says what happens: "Ships now" (note), "Re-writes and re-delivers" (correction).
5. **A note never dies silently.** If a re-run removes the paragraph a note was anchored to, the note drops to a "Your notes" section at the bottom of the meeting — still rendered, still shipped — showing its original anchor quote, with edit / delete / "pin next to a paragraph…" (picker over current blocks; picking one updates the stored quote + occurrence).
6. **Honest cost copy.** "~30 s" for the re-write, "~4 min" for re-transcription; no "model call" jargon. Spend lands in the existing G7 receipts.

## Data model

New table `meeting_correction` (migration in `BlaiseDatabase`):

```
id TEXT PK, meeting_id TEXT (FK, ON DELETE CASCADE),
kind TEXT ('understanding' | 'annotation'),
section TEXT ('summary' | 'detailed_notes' | 'decision' | 'action_item'),
quoted_text TEXT, occurrence INTEGER (nth fold-match within section, default 0),
user_text TEXT,
status TEXT ('pending' | 'applied' | 'stale'),
created_at INTEGER, applied_at INTEGER NULL
```

Anchoring is *quote + section + occurrence* — never character offsets, which die on every re-synthesis. The same fold-and-match discipline as `NameSubstitution`'s occurrence machinery.

Status: `pending` → written, not yet reflected in the current notes. `applied` → a synthesis run consumed it (corrections) / the anchor currently matches (annotations). `stale` → an annotation whose anchor no longer fold-matches any block; renders in "Your notes".

## Execution paths

**Annotation** (no engine): insert row → re-render markdown with annotations woven in (below) → rebuild payload → immutable write → `notes.upsert` + `HandoffRepository.enqueue` in one transaction → kick. This is `correctNameInNotes`'s exact shape (`ProcessingPipeline.swift:895-966`).

**Understanding correction** (engine): insert row (`pending`) → enqueue a **user-origin notes-only run**. This is `notesOnlyStages` (`ProcessingPipeline.swift:2645`) opened to `ready` meetings under a new processing origin: same single-flight chain, same queue dedup, same rebuild of `NotesRequest` from durable state. Failure is no-regress: the meeting stays `ready` with its previous notes and the correction stays `pending` (a later run picks it up); the error surfaces exactly like a regeneration failure. On success, consumed corrections flip to `applied` and every annotation re-anchors (fold-match) or goes `stale`. The escape hatch enqueues today's full Regenerate instead — the correction rows ride along identically because injection happens at request-build time.

**Injection**: `NotesRequest` gains `corrections: [NotesCorrection]` (kind, section, quoted, userText). `NotesPromptBuilder.userMessage` gains a block after the metadata section:

```
User corrections (authoritative — the user reviewed an earlier draft of these notes):
1. In <section>, an earlier draft said: "<quote>". The user corrects: <user_text>
User notes (the user's own margin notes; honor them, do not contradict them):
- (anchored to "<quote>") <user_text>
```

Corrections are instructions about *truth*, so they outrank transcript inference; the system prompt already demands grounding in the supplied material, and this block is part of that material. All three engines (API, CLI, MLX) share the builder, so injection is one seam.

## Rendering & payload

- `NotesRenderer` gains an `annotations:` parameter: anchored notes render as an attributed aside directly under their matched block; stale/unanchored notes render under a final "Your notes" heading with their original anchor quote. Deterministic, localized like the rest of the renderer.
- `EvidencePayloadBuilder` gains presence-gated fields `user_notes` and `corrections` (omitted when empty — the same legacy-key discipline that keeps OLD payloads re-materializing hash-stable, `EvidencePayloadBuilder.swift:96-108`). Downstream (Hermes ingest) sees user truth as attributable provenance, not silently blended content.

## Out of scope (deliberate)

- Character-level text selection as the anchor source (SwiftUI `.textSelection` exposes no selection; block-level + trimmable quote is v1 — the same punt the correct-name flow made, now with a visible affordance).
- Cross-meeting propagation of understanding corrections (a correction is a fact about ONE meeting; term-level fixes belong to the existing glossary/name-correction stores, and the correction popover links there when the correction looks like a term fix).
- Multi-version notes history/diff UI. Immutable payloads already preserve every delivered version; an in-app diff is a later layer.

## Acceptance criteria

1. Correction on a ready meeting → notes-only re-run completes → notes reflect the correction, `applied` status set, new payload delivered, old delivery superseded. Transcript untouched (byte-identical `transcript.json`).
2. A later full Regenerate still honors every non-deleted correction (rows re-injected).
3. Annotation renders instantly (no engine call), ships in `notes.md` + payload; deleting it re-mints without it.
4. Re-run that erases an annotation's anchor → the note appears under "Your notes" with its original quote; pinning it re-anchors (row updated).
5. Failed notes-only re-run: meeting stays `ready`, previous notes intact, correction stays `pending`, error surfaced.
6. Payloads with no corrections/notes are byte-identical to pre-G17 payloads (presence gating proven by hash equality in tests).
7. Deterministic tests for: store CRUD + status transitions, prompt-block assembly, fold-match re-anchoring, renderer output with anchored/stale notes, payload presence gating.
