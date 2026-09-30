# G16 — Audio Retention & Storage Cleanup (v1)

**Goal (the user, 29/09/2026):** see how much space meeting audio takes, delete a
meeting's audio while keeping its transcript and notes, delete all audio at once,
and set a Spotify-style size cap ("keep up to N GB") that deletes the oldest
audio automatically.

**Floor (amends C1 retention guarantee and G10 Floor 2):** audio is deleted ONLY
under a durable owner-intent record. Two records qualify: a manual Delete Audio /
Delete All Audio action, and an owner-set size cap other than Unlimited. The
default cap is **Unlimited**, so an install that never touches the setting keeps
today's never-delete behaviour.

## 1. The mark and the single removal path

- Migration **v23**: nullable `meeting.audio_deleted_at` (datetime) and
  `meeting.audio_deleted_reason` (text: `manual` | `cap`). Metadata only: writing
  the mark NEVER bumps `meeting.updated_at` (C1 v6.7) and never re-mints the
  handoff payload (the payload carries no audio).
- `AudioRetention.removeAudioFiles` is the ONE function that deletes retained
  audio. It acts only on marked rows. The file set is an explicit list, never a
  glob: every `audio*.m4a` (`MeetingPaths.retainedAudioURLs`), every on-disk
  `capture_*.caf` part, and `import.wav`. Derived artifacts (`raw_asr*.json`,
  `diarization.json`, `room_treatment.json`, transcript, notes, handoff payloads)
  are kept.
- Every path goes through the G10 containment check
  (`MeetingDeletion.resolvedWithinMeetingsRoot`); a path that escapes
  `meetings/` or a symlinked leaf is refused and logged, never followed.
- **Order, crash-safe:** in the pipeline chain slot, (1) re-check eligibility,
  (2) commit the mark, (3) remove the files. Kill before (2) → nothing happened.
  Kill between (2) and (3) → launch recovery's `AudioRetention.sweepMarked`
  removes the remaining files. DB loss/recreation → no marks → nothing deleted.
- **Launch order (load-bearing):** `sweepMarked` runs right after the tombstone
  sweep and BEFORE `CaptureRecovery.sweepOrphanCAFs`. `sweepOrphanCAFs` and
  `redispatchInterrupted` skip marked rows, so leftover CAFs of a marked meeting
  are never re-encoded into fresh audio.

## 2. Eligibility

| State | Manual | Automatic (cap) |
|---|---|---|
| recording / paused / processing | refuse | skip |
| already marked | no-op | skip |
| queued or running processing job | refuse | skip |
| ready | allow | allow |
| failed / cancelled | allow; dialog warns it can no longer be retried | skip |
| handoff item pending/delivering/failed while audio delivery is on | allow; dialog warns it ships without audio | skip |
| the most recent meeting (by `startedAt`) | allow | skip |

## 3. After the audio is gone

- The meeting stays `ready`. Transcript, notes, PDF export and "Re-write the
  notes" keep working.
- Full reprocessing is refused, never silently downgraded:
  `dispatchProcessing` throws `PipelineDispatchError.audioDeleted`. A Meet-event
  re-mint needs speaker resolution from audio, which a notes rewrite does not do.
  Automatic origins (Meet events, meeting-code sweep) leave a `processingNote`
  and do not touch `status` or `lastProcessingError`. Queued jobs for a marked
  meeting complete instead of failing. Reprocess All excludes marked meetings.
- The detail view replaces the player with "Audio deleted on <date>", disables
  Regenerate / Process with an explanation, and the inspector shows the date.

## 4. Size cap

- Setting `storage.audioCap`: 250 / 500 MB, 1 / 2 / 5 / 10 / 20 / 50 GB / Unlimited (default).
- Usage counts ALL audio bytes (allocated size of m4a + CAF + import.wav) across
  every meeting. The cap plan takes cap-eligible meetings oldest-first by
  `startedAt` and deletes until usage ≤ cap. If only ineligible audio remains
  over the cap, the sweep stops and logs; it never forces.
- Triggers: launch (after recovery), a meeting reaching `ready`, the daily purge
  loop, and a setting change. A setting change that would delete audio shows the
  projected count and size first; cancelling reverts the setting.
- Sweeps are serialized (one in flight, one coalesced re-run); each deletion
  re-checks eligibility inside its chain slot.

## 5. Acceptance criteria

- **AC1** Deleting audio removes every `audio*.m4a`, `capture_*.caf` and
  `import.wav` of the meeting and keeps the meeting row, transcript segments,
  notes and handoff files; `updated_at` is unchanged.
- **AC2** Kill between mark and removal → relaunch removes the files; a leftover
  CAF on a marked row is not re-encoded and the meeting is not re-dispatched.
- **AC3** Traversal / symlinked-leaf paths are refused and logged.
- **AC4** The eligibility matrix of §2 holds for manual and cap origins.
- **AC5** `dispatchProcessing` refuses a marked meeting; a queued job for it
  completes rather than fails; Reprocess All excludes it.
- **AC6** Cap plan: Unlimited → nothing; oldest-first; never the most recent
  meeting; stops when only ineligible audio remains.

## 6. Out of scope

Deleting delivered copies at handoff destinations; age-based retention;
per-part or per-track audio deletion; undo.
