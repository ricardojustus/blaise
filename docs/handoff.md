# Handoff — delivering finished meetings to a folder or a remote

After Blaise records and processes a meeting, it can **hand the finished result
off to a destination you choose** — a local folder (for example an Obsidian
vault) or a remote host over SSH. This is the "bring your own tools" seam: your
notes and transcript land somewhere your other software can pick them up. By
default only the generated notes/transcript/metadata are delivered; your audio
never leaves your Mac unless you explicitly enable audio delivery to a destination
(see "Audio delivery" below).

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
    <slug-of-title>-transcript.md     optional transcript sidecar (own toggle, default off)
```

- **`<meeting-id>`** — a 26-character ULID, unique per meeting.
- **`<version_hash>.json`** — the canonical JSON record (schema below). Its file
  name is the **SHA-256 of its exact bytes**, so the name *is* an integrity
  check: `shasum -a 256 <file>` must equal the name.
- **`<slug>-transcript.md`** — an optional second Markdown file (its own toggle,
  default off, Local Folder destinations): the full transcript beside the notes
  sidecar. Frontmatter carries `kind: transcript` (and no version_hash); overwritten
  in place on re-delivery; never touched by payload cleanup.
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
- **Immutable history (default).** Regenerating a meeting (better engine,
  corrected names) produces a *new* content-addressed file, and older versions
  are not deleted. Order versions of the same meeting by the record's own
  `updated_at_ms`, not the file mtime (re-deliveries and idempotent rewrites can
  change mtime). This is the shipped default, so anything that referenced an
  older payload by hash can still resolve it.
- **Removing superseded payloads (opt-in, off by default).** If you would rather
  each meeting keep exactly one current file at the destination, turn on "Remove
  superseded payloads at the destination" (Settings → Evidence Store). Then,
  after a new payload is delivered and the older queue rows are superseded,
  Blaise removes this meeting's KNOWN older `<hash>.json` payload versions from
  the destination meeting dir — an explicit candidate set built from Blaise's
  own delivery records, never a `*.json` pattern — so a correction *replaces*
  the delivered evidence instead of accumulating beside it. A file is a
  candidate only where Blaise's records show it delivered that version of that
  meeting to the destination you are using NOW: non-payload JSON, the sidecar
  `.md`, any delivered audio, `.tmp-*`, a version that was only ever queued and
  never delivered, and anything sitting at a destination you switched to later
  are all untouched. Removal is failure-isolated (it never fails or
  retries the JSON delivery; it retries on the meeting's next delivery).
  **Weigh it if anything downstream cites payloads by hash:** an accumulating
  destination is easy to tidy later; a deleted payload is not recoverable.
  Either way, the LOCAL `handoff/<hash>.json` snapshots under the meeting
  directory (Blaise's own archive) are never touched — the destination is a
  delivery target, not the archive.
- **Audio delivery (opt-in, off by default).** With "Include audio recordings"
  (Settings → Evidence Store) turned on, Blaise delivers a meeting's retained
  `audio*.m4a` set (system + mic + part files) into the destination meeting dir
  under their canonical names, after the sidecar. This is the ONLY path by which
  audio leaves the machine; a destination that syncs (iCloud/network) then carries
  the recordings off-device. Delivery is failure-isolated from the JSON, idempotent
  by byte length (an already-delivered file of matching size is skipped), and there
  is no retroactive sweep — flipping the toggle on back-delivers on each meeting's
  NEXT delivery only. The payload JSON is unchanged (no audio field), so payload
  bytes and hashes are stable across the toggle.
- **Deletion never reaches into the destination.** Deleting a meeting in Blaise
  removes its local data (including any retained audio); it does NOT delete the
  delivered `<hash>.json`, sidecar, or any delivered audio at the destination — the
  destination is owned by its consumer.

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
