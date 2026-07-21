# C4 Spec — Diarization + speaker attribution

CHANGELOG: v5.6 (2026-07-21) — ROOM MODE (`source == .inPerson` captured meetings): the mic track carries the whole room through one shared channel, so blanket `user` attribution was confidently wrong (field exhibit: a 6-person workshop with 74 minutes of room speech attributed to the owner). The mic track is now diarized+merged exactly like a system track — estimate = attendees + 1 (the mixed-track rule; the owner is in this audio), system-track estimate = nil (attendees are in the room, not on the wire) — and NO segment is blanket-labeled `user`: the owner's voice is one anonymous cluster among the room's until fingerprints exist (measured basis: unconstrained FluidAudio collapses the workshop's room track to 1 cluster at every threshold 0.35–0.8, and `exactly: 6` produces an UNSTABLE K-Means partition — so honest anonymity, never forced attribution). Mic clusters live in their own reserved label namespace **`M<n>`** (C1 label classes amended): prefix — not offset — separation means no collisions whatever either track's count does, per-track artifacts (`diarization_mic.json`, C1) reuse independently, and a rename row's TRACK is derivable from its label forever — load-bearing for the §4-fallback re-key, where candidates are now scoped to the row label's namespace (`S`/`M`; other labels keep the unscoped set) because a bare time anchor is ambiguous across time-coextensive tracks. The G13 neutralizer grammar extends to `[SM]\d+`. Fresh-run re-key ordering: ONE remap against the COMBINED fresh output commits before ANY fresh artifact persists (G2 §4 / M-1 preserved). Non-room captured meetings and file-first are byte-identical to v5.5.  v5.5 (2026-07-21) — the speaker-count "hint" is not a hint: FluidAudio's offline path re-partitions with K-Means (nondeterministic) when VBx's detected count leaves the configured bounds, and on meeting-platform system audio it SATURATES the ceiling — measured on three field 1:1 recordings, `max: attendeeCount + 1` split the single remote speaker into two balanced phantom clusters on EVERY run (e.g. 604 s + 173 s, 22 alternations) while `max: 1` was correct on every run; unconstrained runs are deterministic but severely under-cluster multi-party system audio (a ~5-remote weekly collapsed to 2 clusters, 785 s + 4 s). Therefore: `diarize(audioURL:expectedSpeakerCount:)` — the caller's POINT ESTIMATE of speakers in THIS track, applied as `withSpeakers(min: 1, max: estimate)` with NO padding (`clusteringBounds`, unit-tested); C7 owns track topology: captured system track = attendee count (owner-excluded list, user not in track), file-first mixed track = attendees + 1 (user in track — numerically identical to the old rule, so file-first pins stand); count unknown → unconstrained. Eval harness: `DiarLab` executable re-runs retained meeting audio under config variants (a captured 1:1's system track = 1 speaker is free ground truth).  v5.4 (2026-06-10) — silence is a VALID diarization result: FluidAudio's noSpeechDetected maps to empty output (0 segments / 0 speakers), never a stage failure — an in-person capture's system track is legitimately silent (found by an early touchpoint recording).  v5.3 (2026-06-10) — C11 amendments: apply() rule 0 (label `user` immune to mappings); isSelf hint events excluded from system-track voting under two-track capture; merge post-conditions scoped per-track for interleaved two-track sets (cross-track overlap legal).  v5.2 (2026-06-10) — C6-round-2 revert: vocabularyNames removed again (ungrounded glossary mapping = the wrong-person class apply() blocks; C6 v3 grounds proposals in transcript-verbatim instead). v5.1, v5; four audit-fix revisions. GATE: round 4 = 0C/0H.

## Goal

Speaker-attributed transcripts: diarize the meeting audio, merge speaker turns with ASR segments (splitting at speaker changes using word timings), and resolve clusters to real names when signals exist. Pure BlaiseCore + tests; pipeline wiring is C7. **Audio topology assumption (V1, stated): one mixed mono track (file-first). Mic-channel hints are C11's future concern, not represented here.**

## Division of labor for NAMES (decision D10)

- **C4 (mechanical):** cluster→name overlap-voting when an active-speaker timeline exists (C12's output). Deterministic, pure, re-runnable.
- **C6 (LLM, contextual):** when mechanical signals are absent/partial, the synthesis engine proposes a `speakerNameMapping`; C7 applies it through `SpeakerResolution.apply` (below) under validation that makes name invention impossible.
- Unresolvable clusters keep `speakerName = nil`. Never fabricate.

## Components (API signatures normative)

### 1. `Diarizing` protocol + `FluidAudioDiarizer`

```swift
protocol Diarizing: Sendable {
  func prepare() async throws
  func availability() async -> EngineAvailability
  func diarize(audioURL: URL, expectedSpeakerCount: Int?) async throws -> DiarizationOutput
}
struct DiarizationOutput { let segments: [DiarizedSegment]; let speakerCount: Int }
struct DiarizedSegment { let speakerLabel: String /* "S0"… */; let startSeconds: Double; let endSeconds: Double }
```

Label convention: `DiarizedSegment.speakerLabel` is normalized to `"S<n>"` (n = 0-based cluster index in first-appearance order) by the `Diarizing` implementation, whatever the library's native labels. `speakerCount` = distinct labels AFTER clamping/drops. Production impl: FluidAudio 0.15.2 `OfflineDiarizerManager` (pyannote community-1 CoreML port, 17 ms resolution; the 10 s snapping in early research was the CLI streaming mode). `OfflineDiarizerModels.load(from:)` (direct model loading — the C3 wipe-repair pattern owns failure handling; the manager's own prepare has a competing purge-retry) → cache `<dataRoot>/models/fluidaudio-diar`; config defaults; `withSpeakers(min: 1, max: expectedSpeakerCount)` when the caller supplied an estimate ≥ 1 (`clusteringBounds`) — the ceiling is the estimate EXACTLY, never padded: the offline VBx→K-Means constraint path saturates it on meeting-platform audio, so slack fabricates speakers (v5.5 CHANGELOG has the field measurements; C7 owns the per-track estimate: system track = attendees, mixed track = attendees + 1). Same actor + task-chain serialization, integrity/wipe-repair, and availability patterns as C3's FluidAudio engine. **Output post-processing (C4-owned): diarization segments are clamped to the audio duration** — the probed real output overruns it (max end 300.0849 on a 300.032 s file; frame-quantization overshoot), while C3-normalized ASR segments are already clamped; segments entirely past EOF are dropped. Embeddings exposed by the API are NOT persisted (V1.1 fingerprint material, noted only). SpeakerKit (MIT, argmax-oss-swift v1.0.0, verified OSS) is the recorded fallback — swap = one conformance (D10).

### 2. `SpeakerMerger`

```swift
enum SpeakerMerger {
  static func merge(asr: [ASRSegment], diarization: [DiarizedSegment], meetingID: MeetingID) -> MergeResult
}
struct MergeResult { let segments: [TranscriptSegment]; let report: MergeReport }
struct MergeReport { let splits: Int; let degenerateSegments: Int; let gapAssignedWords: Int; let healedFragments: Int }
```

- **Primary path (every segment, stated explicitly):** whole-segment assignment to the diarization speaker with the greatest summed overlap, UNLESS the split trigger fires.
- **Distance and coverage conventions (pinned):** "midpoint distance" = distance from the midpoint to the diarization segment's INTERVAL (0 if inside, else distance to the nearest edge). Overlapping diarization segments are legal input: coverage sums per speaker (double-counting harmless); a midpoint covered by 2+ segments goes to the one with greater total overlap with the enclosing ASR segment; tie → the earlier-starting segment.
- **Split trigger (research §4, OR semantics):** an ASR segment splits when ≥ 2 diarization speakers each cover **≥ 0.5 s OR ≥ 20 %** of it.
- **Word assignment:** each word → the speaker covering its midpoint (conventions above); midpoint in a GAP → nearest diarization segment within 2.0 s; farther → the previous word's speaker; first word → the FOLLOWING assigned word's speaker; if NO word in the segment gets a direct assignment (edge-only coverage is constructible), the whole segment falls back to the primary whole-segment path. Contiguous same-speaker words form pieces.
- **Piece boundary repair (C3 rule-5 analogue — word timings within a segment may overlap or tie):** walking pieces left-to-right, `next.start = max(next.start, prev.end)`; a piece emptied by this merges into its left neighbor. Establishes the post-conditions instead of merely asserting them.
- **Fragment healing (research guardrail, AND semantics):** a piece is a fragment iff `< 2 words AND < 1.0 s` (a one-word turn ≥ 1.0 s — "approved" — is NEVER healed; sub-second one-word interjections may be absorbed: accepted boundary-noise trade-off, recorded). Healing is ONE deterministic left-to-right pass: a fragment merges into its LEFT neighbor (the leftmost piece merges right), the absorber's speaker wins, and adjacent same-speaker pieces consolidate as the walk proceeds. No iteration, no preference rules — order IS the rule.
- **Reconstruction:** split-piece text = its words joined by single spaces, each word's WHITESPACE-only edges trimmed — punctuation is part of the word token and is preserved (deterministic, near-byte-faithful; the C7 regression pin covers determinism); start = first word's start, end = last word's end. Whole-segment path keeps original text/timing. Words dropped by C3's normalizer were out-of-bounds garbage; their absence here is correct, not loss.
- **Per-segment degeneracy:** nil/empty `words` on a segment → whole-segment path for that segment; counted.
- **Zero-overlap segments:** nearest diarization segment within 2.0 s (conventions above); else `speakerLabel = TranscriptSegment.unattributed`.
- **Consolidation:** adjacent same-speaker segments with gap ≤ 2.0 s merge (single-space join; an alternative 0.35 s/8-char no-space concatenation rule deliberately dropped — single-space join is deterministic across engines and the difference is cosmetic).
- **Post-conditions (established by the repair step, asserted):** strictly monotonic starts, non-overlapping, `ord` re-sequenced 0…n−1, `speakerName = nil` throughout.

### 3. `SpeakerResolver`

```swift
enum SpeakerResolver {
  static func resolve(diarization: [DiarizedSegment], hints: SpeakerHints, audioDuration: Double) -> SpeakerResolution
}
struct SpeakerHints {
  let activeSpeakerEvents: [ActiveSpeakerEvent]?
  let recordingStartEpochMillis: Int64?        // C7 supplies from Meeting.startedAt; events with this nil are ignored (logged)
}
// (Attendees play no role in resolve() — events carry the names; C7 keeps the
// attendee list for apply()'s allowed names and for Diarizing's
// expectedSpeakerCount estimates.)
struct ActiveSpeakerEvent: Codable, Equatable {  // C12 contract, pinned here
  let displayName: String
  let participantID: String?                   // Meet's stable participant id when scrape-able; nil tolerated
  let startEpochMillis: Int64                  // WALL-CLOCK epoch — C12 cannot know recording start
  let endEpochMillis: Int64
}
struct SpeakerResolution { let assignments: [String: String]; let unresolved: [String] }
// unresolved = clusters that had ≥ 1 vote but failed dominance, plus clusters whose top name was ambiguous
// (ambiguous names still contribute vote mass as runner-up — conservative).
```

- Events are converted to recording-relative seconds via `recordingStartEpochMillis`, then a **±2 s drift sweep** (step 0.25 s, offsets evaluated ascending; per-offset, events entirely outside [0, audioDuration] are excluded; objective = total cluster×event overlap; argmax ties → smallest |offset|, then the earlier offset) absorbs clock skew. Deterministic.
- **Voting:** matrix over DIARIZATION segments × identity key. **The identity key is `displayName`**; `participantID` serves only to DETECT ambiguity — two distinct non-nil participantIDs sharing one displayName make that name ambiguous ONLY if their events overlap in time (time-disjoint same-name ids are a rejoin — one person; Meet reassigns ids on rejoin) → ambiguous names' clusters stay unresolved (flagged); nil/non-nil mixtures of the same displayName are one key. Overlapping simultaneous events each vote. The `unattributed` sentinel never participates and is never named.
- **Dominance rule:** a cluster resolves iff its top vote **> 2×** the runner-up (strict — exact 2× is unresolved; AC matches) AND ≥ 5 s total. Many-to-one allowed (rejoins).
- No owner-exclusion step (deviation from research §5, deliberate: with one mixed track the owner is just another cluster and symmetric voting handles them). The user's identity plays no role in `resolve()`; C7 passes `userName` to `apply()` and matches the owner attendee by email (`UserIdentity.email` vs `Attendee.email`) for its own bookkeeping.
- **`SpeakerResolution.apply(to: [TranscriptSegment], attendeeNames: Set<String>, eventNames: Set<String>, userName: String, suppression: Set<String> /* SuppressionSet.effective(...) */, commonNames: Set<String>) -> [TranscriptSegment]`** — the SINGLE application path for both mechanical and LLM mappings; ALL validation is callee-side, dependencies explicitly injected (same channel as C5's corrector: C7 already loads the suppression fixtures and `br_common_names.txt`; unit tests load the same fixtures):
  1. A mapping may only target cluster labels that exist among the segments, never `unattributed`. Violating entries are dropped + logged (entry granularity).
  2. A name is allowed iff it is in `attendeeNames ∪ eventNames ∪ {userName}` (compared case-insensitively, diacritic-folded), OR it passes the transcript-verbatim rule: the FULL name (all its tokens, contiguously, at token boundaries, case-insensitive, diacritic-folded — so "Fábio" matches transcript "Fabio") occurs WITHIN A SINGLE segment's text (per-segment scope, pinned: conservative-miss for names split across a segment boundary, never invention) AND no token is BLOCKED AND the name is ≥ 2 characters. **Blocked token (pinned):** (folded) member of the EFFECTIVE SUPPRESSION SET (C5's `SuppressionSet.effective` = top-3000 ∪ project − exclusions) AND NOT a member of `commonNames` (br_common_names.txt) — so "Vamos"/"Sim"/"Então" are blocked (suppression members, not names) while "Maria" (suppression member at rank 1510 BUT a known given name) and "Fábio" (rank 17k, outside suppression) pass. Violations dropped + logged.
  3. **No-overwrite precedence:** a segment whose `speakerName` is already set is never changed by a later application (mechanical wins over LLM; first application wins).

## Acceptance criteria

1. `scripts/test.sh` green. Unit tests (no models): SpeakerMerger — OR-trigger split (incl. the 19.7 % / 5.9 s case), word-midpoint assignment, gap words (within 2 s, beyond 2 s continuity, first-word case), healing (left-merge single pass, leftmost-merges-right, walk consolidation, AND-guardrail: 1-word ≥1 s kept / 1-word <1 s healed), reconstruction text/timing, per-segment degeneracy, zero-overlap paths, consolidation, post-conditions, determinism; SpeakerResolver — strict dominance (exact 2× unresolved), ≥ 5 s floor, drift sweep (synthetic offset recovered), participantID vs displayName keys, ambiguous duplicate names, out-of-bounds events ignored, sentinel exclusion; apply() — all three rules incl. transcript-verbatim allowance and no-overwrite; ActiveSpeakerEvent Codable golden (C12 contract pin).
2. Sample-audio integration (C3 skip protocol): `FluidAudioDiarizer` on seg_b → ≥ 2 speakers, ≥ 15 segments, boundary anti-snap: ≥ 3 distinct fractional parts among segment boundary times, all clamped within [0, 300.04]; **a LIVE MLXWhisperEngine run on seg_b** (same venv/HF-cache seams and cost ownership as C3's AC2; the committed sample-oracle seg_b JSON predates word timestamps and cannot serve) merged against the diarization → ≥ 1 segment carries a non-`unattributed` label and `unattributed` segments ≤ 20 % of total; ≥ 1 split observed (recorded count; if 0, the chunk does not close — investigate, do not relax); post-conditions hold. Skip separability: the diarizer test and the whisper-dependent merge test write SEPARATE skip entries; the merge test runs only when both stacks are available.
3. Diarizer provisioning/repair decision-logic unit tests over filesystem fixtures (C3 pattern).
4. No regression: full suite green.

## Open question (recorded in the internal open-questions log)

seg_b true speaker count (streaming mode found 2, offline 3): no ground truth exists without listening; resolved at C7's sample evaluation by transcript-coherence judgment + the LLM mapping's plausibility, documented in the regression artifact.

## Out of scope

LLM mapping prompt (C6) and pipeline order (C7); the Chrome extension (C12 — only the event contract is pinned); voice fingerprinting (V1.1); pyannote referee (C7 optional); live attribution (V1.1+); mic-channel hints (C11).
