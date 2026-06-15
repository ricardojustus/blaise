# Handoff — delivering finished meetings to a folder or a remote

After Blaise records and processes a meeting, it can **hand the finished result
off to a destination you choose** — a local folder (for example an Obsidian
vault) or a remote host over SSH. This is the "bring your own tools" seam: your
notes and transcript land somewhere your other software can pick them up. Your
audio never leaves your Mac; only the generated notes/transcript/metadata are
delivered.

You pick the destination in **Settings → Handoff**. One destination is active at
a time. Delivery is automatic, queued, and retried — if the destination is
offline, the meeting waits and is delivered when it comes back.

## What gets delivered

Per meeting, into a per-meeting directory:

```
<root>/
  <meeting-id>/                       one directory per meeting
    <version_hash>.json               the canonical record (immutable)
    <slug-of-title>.md                optional human-facing Markdown sidecar
```

- **`<meeting-id>`** — a 26-character ULID, unique per meeting.
- **`<version_hash>.json`** — the canonical JSON record (schema below). Its file
  name is the **SHA-256 of its exact bytes**, so the name *is* an integrity
  check: `shasum -a 256 <file>` must equal the name.
- **`<slug>.md`** — an optional, Obsidian-ready Markdown file (YAML frontmatter +
  the rendered notes), governed by a Settings toggle (default on). Convenience
  only; the `.json` is the source of truth. One current sidecar per meeting (a
  newer version overwrites it).

## Reliability guarantees

- **Atomic, never partial.** A record becomes visible only after a
  verify-before-rename: Blaise writes to a temp file, re-reads and SHA-256-checks
  it, then atomically renames it into place on a match. You never see a
  half-written `<hash>.json`.
- **Idempotent.** Re-delivering the same content re-writes identical bytes over
  the identical file name — duplicates are impossible.
- **Queue-and-retry.** Delivery survives the app restarting and the destination
  being unreachable; nothing is lost.
- **Immutable history.** Regenerating a meeting (better engine, corrected names)
  produces a *new* content-addressed file; older versions are not deleted. Use
  the record's own `updated_at_ms` to order versions of the same meeting — not
  the file mtime (re-deliveries and idempotent rewrites can change mtime).

## The JSON record

One document per file, canonical JSON (object keys sorted byte-wise; every
numeric field is an integer — epoch/offset **milliseconds** — so the bytes are
deterministic). The fields:

| Field | Type | Meaning |
|---|---|---|
| `native_id` | string | The meeting ULID; equals the directory name. |
| `source` | string | Always `"blaise"`. |
| `title` | string | Meeting title. |
| `started_at_ms` / `ended_at_ms` | integer / integer\|null | Wall-clock bounds (epoch ms); `ended_at_ms` null only if never closed. |
| `created_at_ms` / `updated_at_ms` | integer | Record create/update times (epoch ms). |
| `owner` | `{name, email}` | The recording user's identity; may be empty (`{name:"", email:""}`) before onboarding. |
| `attendees` | array of `{name, email?}` | Attendees; `email` present when known. |
| `dominant_language` | string\|null | The meeting's dominant language (e.g. `"pt"`, `"en"`). |
| `summary_text` | string | Plain-text summary. |
| `summary_markdown` | string | The full rendered notes document (human-facing). |
| `notes_structured` | object | `{title, summary, detailed_notes, decisions[], action_items[{owner,text}], user_action_items[{owner,text}], meeting_type?}` — the structured notes the markdown is rendered from. |
| `transcript` | array | Ordered speaker turns (see below). |
| `provenance` | object | `{asr, notes, pipeline_version}` — the engines/models/versions that produced this content. |

A transcript turn:

```json
{
  "speaker": { "source": "microphone" | "speaker", "diarization_label": "S0", "name": "Dana Marsh" | null },
  "text": "…verbatim corrected text…",
  "start_time_ms": 0,
  "end_time_ms": 2500
}
```

`speaker.source == "microphone"` marks the recording user's own speech;
`speaker.name` is Blaise's resolved name for the turn (or `null` when no grounded
name exists).

## Consuming it

Read the `<hash>.json` (canonical record) or, for a human/Obsidian view, the
`.md` sidecar. Only `<64-hex>.json` names are records; ignore anything else
(in-flight temp uploads are dot-prefixed and may be cleaned up later). Files are
immutable once visible: same name ⇒ same bytes, forever. To track "current,"
order a meeting's versions by `updated_at_ms`.
