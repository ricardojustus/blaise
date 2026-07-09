# C2 Spec — Engine interfaces, registry, engine settings

CHANGELOG: v4.4 (2026-06-10) — impl-audit M-1 (D17 round 1): rule-2 substitution for the summarization slot prefers the first registered `.lightweight` engine (an unregistered persisted id can never resolve the heavyweight local engine as primary); the shipped registration order is also lightweight-first (`[claude, gemma]`) — belt and suspenders.  v4.3 (2026-06-10) — D17 amendment: `SummarizationEngine.loadProfile: EngineLoadProfile` (`.lightweight` / `.heavyweight(estimatedPeakBytes:)`, declared explicitly by every engine); the C6 runtime-fallback hop is bounded to lightweight fallbacks (heavyweight-only → C7's notes-pending outcome); `insufficientMemory` joins the pinned trigger reasons.  v4.2 (2026-06-10) — C7 amendment: the summarization slot skips the pre-run availability() gate (C6's thrown reason constants drive the fallback; a pre-gate would defeat it); ASR keeps the full resolve→prepare→availability→run contract.  v4.1 (2026-06-10) — C6 amendments: `NotesResult.speakerNameMapping: [SpeakerNameProposal]` (additive), `NotesProvenance.promptVersion: String` (decode-default ""). C3 amendment: ASRSegment.words. v4; three audit-fix revisions.

## Goal

The two engine seams mandated by the product requirements — ASR and summarization — as clean protocols with a registry and persisted selection, such that (a) adding an engine later = implement protocol + register at the composition root, nothing else changes; (b) Settings (C10) can list, configure, and switch engines generically; (c) switching affects subsequent processing and regeneration (C7 resolves at run start). Pure BlaiseCore code + tests; no concrete engines (C3/C6), no UI (C10).

## Inherited constraints

- D5: engine identity = model + runtime; provenance must reconstruct "what produced this".
- B-2: USD 20/month cloud ceiling — the protocol carries a generic cost surface so C6 can enforce and C10 can display without downcasts.
- B-3/AFM: summarization abstraction must fit a future Apple Foundation Models engine (plain async request/response — it does).
- Hard floor 1: post-meeting batch only; no streaming in V1 (a streaming refinement later is additive).

## Types (BlaiseCore; all new types Codable, Sendable, Equatable)

- `ASRSegment`: `startSeconds`, `endSeconds`, `text`, `words: [ASRWord]?` (`ASRWord = {word, startSeconds, endSeconds}`; additive C3 amendment — word timings feed C4 speaker-change splitting; decode-default nil).
- `ASRResult`: `segments: [ASRSegment]`, `detectedLanguage: String?` (BCP-47 whole-file judgment), `rawPayload: Data` (engine-native JSON), `usage: EngineUsage?`, `provenance: ASRProvenance`.
- `ASRRequest`: `audioURL: URL` (16 kHz mono WAV, C7 owns transcoding), `vocabularyHints: [String]`, `languageHint: String?` (nil = auto).
  - **Hints contract:** hints are engine-level *biasing* only (Apple `contextualStrings` etc.); engines that can't use them ignore them. The C5 correction layer remains the authoritative post-pass; double-correction is safe because C5 matches against canonical forms and is idempotent on already-correct text. `ASRProvenance` records what was passed (see below).
- `ASRProvenance` (C1 type, **extended by this chunk**): + `vocabularyHintsApplied: Bool` (decode default `false` for any previously-persisted JSON — additive, no migration), `languageHint: String?` — same engine ± hints produces different transcripts; provenance must say which ran.
- `NotesRequest`: `meeting: Meeting`, `transcript: [TranscriptSegment]` (speaker-attributed, corrected), `dominantLanguage: String` (producer: C7's deterministic language-stats step over the transcript — recomputable for regeneration; never fabricated), `vocabulary: [String]`, `user: UserIdentity`.
- `UserIdentity`: `name: String`, `aliases: [String]`, `email: String` — who "the user" is, so every engine can produce `userActionItems` without out-of-band knowledge. Persisted in `SettingsStore` (`user.identity`); shipped default is the NEUTRAL empty identity (`name`/`aliases`/`email` all empty — "not yet onboarded", G3/D19), populated by first-launch onboarding. Design-for-one, door open for many.
- `NotesStructured` — **the single source of truth for notes content**: `title: String?`, `summary: String`, `detailedNotes: String` (long-form markdown body), `decisions: [String]`, `actionItems: [ActionItem]`, `userActionItems: [ActionItem]` (wire/schema key `user_action_items`, G4), with `ActionItem = {owner: String, text: String}`.
- `NotesProvenance` (C1 type, **extended by this chunk**): existing `engine`/`model`/`pipelineVersion` + `runtime: String`, `rendererVersion: String`, `promptVersion: String` (C6 amendment), and `userName: String` (G3) — all decode-default `""`, additive, no migration. Parity with D5's engine-identity rule on the notes side; renderer/prompt versions and the identity name travel because the markdown artifact depends on them.
- `NotesResult`: `structured: NotesStructured`, `usage: EngineUsage?`, `provenance: NotesProvenance`, `speakerNameMapping: [SpeakerNameProposal]` (C6 amendment: `SpeakerNameProposal = {label: String, name: String?, confidence: ProposalConfidence(high|medium|low), evidence: String}`; engines without mapping ability return []). **Engines do not return markdown.** The human markdown document is rendered deterministically by `NotesRenderer` (C2, pure function, tested); consistency between markdown and structured holds by construction. C7 stores both: `markdown = NotesRenderer.render(structured, language:meetingTitle:)` and `structured` itself.
- **`NotesRenderer` normative contract (B-1-bearing):**
  - Signature: `render(_ s: NotesStructured, language: String, meetingTitle: String, userName: String = "") throws -> String` — throws `EngineError.invalidStructuredNotes` (refusal cases below); pure otherwise. `rendererVersion` is "2" (G3: the user action-items title is name-driven, so the same structured/language/title renders different bytes than pre-G3).
  - Document: H1 = `s.title ?? meetingTitle`; then sections in fixed order with H2 headings: summary, detailed notes, decisions, action items, user action items.
  - **Headings are localized by `language`** (BCP-47 prefix match): `pt*` → "Resumo", "Notas detalhadas", "Decisões", "Itens de ação"; anything else → "Summary", "Detailed notes", "Decisions", "Action items". The user action-items heading is **name-driven** (G3): `<name>'s action items` (EN) / `Ações de <name>` (PT) when an identity name is present; an empty (pre-onboarding) identity renders the neutral "My action items" / "Minhas ações". (B-1: notes in the dominant language; the user section always rendered, same language.)
  - **Empty-section policy:** `decisions`/`actionItems` empty → heading + localized none-marker ("Nada registrado." / "None noted." — anti-hallucination pattern). `userActionItems` empty → heading + the name-driven none-marker ("Nenhuma ação para `<name>`." / "No action items for `<name>`.", or "Nenhuma ação para mim." / "No action items for me." when unnamed) — the section is ALWAYS rendered (B-1). Empty `summary` → `.invalidStructuredNotes` (refusal, not rendering).
  - **Normalization (ALL engine strings are untrusted markdown):** `title` and `meetingTitle` are flattened to a single line (newlines→space, leading `#` stripped) before becoming the H1; `summary` and `detailedNotes` are markdown bodies with any headings demoted so none outranks H3; list-item strings (`decisions`, `ActionItem.text/.owner`) have leading markdown tokens stripped and internal newlines collapsed to spaces. No engine string can introduce an H1/H2 or impersonate a section heading. Action items render as `- **{owner}:** {text}`.
  - **Remaining empty-input rules:** empty/whitespace `title` is treated as nil (falls back to `meetingTitle`); empty `detailedNotes` renders the localized none-marker like the list sections.
  - Deterministic: same inputs → byte-identical output (golden-tested in both languages).
- `EngineUsage`: `inputUnits: Int?`, `outputUnits: Int?`, `estimatedCostUSD: Double?` (nil for local engines; cloud engines fill what they know). Enforcement/accounting of the B-2 ceiling is C6; display is C10; C2 only carries the data.
- `EngineCostDescriptor`: `pricingSummary: String`, `estimatedPerMeetingUSD: Double?` — static engine-level descriptor for Settings display.
- `EngineAvailability`: `available` | `unavailable(reason: String)`.
- `EngineError` (taxonomy all engines map into): `.transient(String)` (retry may help), `.permanent(String)`, `.cancelled`, `.configurationMissing(key: String)`, `.notAvailable(reason: String)`; registry/resolution add `.duplicateEngineID(String)`, `.noEnginesRegistered(slot: String)`; the renderer adds `.invalidStructuredNotes(String)`.

## Persistence change (this chunk owns migration v2)

Schema migration `v2`: `meeting_notes` gains `structured TEXT` (JSON `NotesStructured`, NOT NULL without DEFAULT — valid because the table is provably empty at migration time in every deployment that can exist [no C7 yet]; SQLite allows ADD COLUMN NOT NULL sans DEFAULT only on empty tables, verified on system SQLite 3.51 — stated so the constraint is understood, not stumbled on). `MeetingNotes` (C1 type) gains `structured: NotesStructured`. This restores C1's payload re-materialization contract: the D4 payload's structured fields are derivable from the DB alone (meeting + transcript + notes.markdown + notes.structured + provenance all persisted).

**Contract amendment to C1 (recorded here, single line added to C1 spec):** `raw_asr.json` = raw output of the *current* ASR run, wrapped as `{provenance: ASRProvenance, payload: <engine-native JSON>}`; replaced atomically (temp+rename) on regeneration. C1's "immutable" means never edited in place — only replaced whole by a new run's output.

## Protocols

```swift
public protocol ASREngine: Sendable {
  var id: String { get }                       // stable, persisted ("mlx-whisper-large-v3-turbo")
  var displayName: String { get }
  var kind: EngineKind { get }                 // .local | .cloud
  var costDescriptor: EngineCostDescriptor? { get }   // nil for local
  var configDescriptors: [EngineConfigDescriptor] { get }
  func availability() async -> EngineAvailability
  func prepare() async throws                  // default no-op; idempotent; model download etc.
                                               // OWNERS: C7 awaits prepare() at every run start (covers shipped-default first run);
                                               // C10 additionally calls it on switch for eager UX.
  func transcribe(_ request: ASRRequest) async throws -> ASRResult
}
```
`SummarizationEngine`: identical surface with `generateNotes(_ request: NotesRequest) async throws -> NotesResult`.

Cancellation: engines check `Task.isCancelled` at natural boundaries and throw `EngineError.cancelled` (documented; mock-tested).

## Per-engine configuration seam

- `EngineConfigDescriptor`: `key: String`, `label: String`, `kind: ConfigKind` (`.string | .path | .secret`), `required: Bool`. Engines declare; C10 renders generically.
- Values live in: non-secrets → C1 `SettingsStore` under `engine.<id>.<key>`; secrets → `SecretStore`.
- `SecretStore` protocol (`get/set/delete(key:)`) with two implementations: `KeychainSecretStore` (macOS Keychain, generic password items, service `app.blaise.mac`; smoke-tested) and `InMemorySecretStore` (tests). **No secret ever lands in SQLite or on disk.**
- `EngineConfiguration` (defined here, C3/C6 construct against it): `struct EngineConfiguration: Sendable { let engineID: String; func value(for key: String) async throws -> String? }` — routes by the engine's descriptor kind: `.secret` → `SecretStore`, others → `SettingsStore`, all under `engine.<id>.<key>`. Engines are CONSTRUCTED at the composition root with an `EngineConfiguration` handle. **Normative: configuration VALUES are read from the stores at call time (live read-through); only descriptors are static.** A key entered in Settings after launch reaches already-constructed engines on their next call — no restart, no registry rebuild (B-8's "5-second fix"). Adding an engine = implement protocol + construct + register. Missing required config → engine reports `unavailable(reason:)` and calls throw `.configurationMissing` — never a crash.
- **Secret namespacing:** Keychain account = `engine.<id>.<key>` (same scheme as SettingsStore keys) — two engines declaring `apiKey` can never collide.
- **Ad-hoc-signing caveat (accepted, documented):** per-build ad-hoc identities may force re-granting Keychain access (or re-entering the secret) after rebuilds on the dev machine. Accepted for V1 (one secret, entered rarely; installed builds don't churn). BACKLOG: stable signing identity.

## Registry (immutable by construction)

`EngineRegistry(asr: [any ASREngine], summarization: [any SummarizationEngine]) throws` — validates unique ids per slot (`.duplicateEngineID` otherwise), preserves order (stable for UI), exposes `asrEngines`, `summarizationEngines`, `asrEngine(id:)`, `summarizationEngine(id:)`. Immutable after init ⇒ trivially Sendable; no freeze rules, no locking.

## Selection + resolution

Keys `asrEngineID` / `summarizationEngineID` in `SettingsStore`. Shipped defaults: constants `EngineDefaults.asrEngineID = "mlx-whisper-large-v3-turbo"` and `EngineDefaults.summarizationEngineID` (placeholder until C6's bake-off; resolution semantics make this safe).

**Resolution precedence (deterministic, registration-order-independent for the normal path):** effective id = settings value if present, else the `EngineDefaults` constant. Then: id in registry → return `{engine, usedFallback: false}`; id not in registry → substituted engine with `usedFallback: true` — for the summarization slot the first registered `.lightweight` engine when one exists (substitution is never a deliberate selection, so it must not resolve a heavyweight engine — D17 guarantee clause (a)); the ASR slot, and a summarization slot with no lightweight engine, substitute the first registered engine; empty slot → throw. Resolver = `EngineResolver` struct (init with registry + SettingsStore; async funcs, matching SettingsStore's async API).

`resolveASR() async throws -> ResolvedEngine` / `resolveSummarization() async throws -> ResolvedEngine` (async — they read SettingsStore), where `ResolvedEngine = {engine, usedFallback: Bool}`:
1. selected id present in registry → return it.
2. id missing/unregistered → substituted engine with `usedFallback: true` — summarization prefers the first `.lightweight` engine (D17), ASR takes the first registered (C10 displays it; C7 logs provenance truthfully). The shipped composition root also registers the summarization slot lightweight-first (`[claude, gemma]`), so the guarantee holds in both layers.
3. slot empty → throw `.noEnginesRegistered` (defined, testable; C7 surfaces as processing failure, C10 as empty state).

**Availability is not resolution's job:** C7 contract = resolve → `availability()` → if `unavailable`, the run fails with the engine's reason (no silent engine swap at resolution time — provenance honesty; user remedies via Settings). **C6 amendment (summarization slot only):** at RUNTIME, `.permanent(input too long / OOM)` / `.notAvailable(monthly ceiling / insufficient memory headroom)` / `.configurationMissing` from the resolved engine permits C7 ONE fallback hop to the other registered engine (no cycling) — **and only when that engine declares `loadProfile == .lightweight` (D17): `SummarizationEngine` gains `var loadProfile: EngineLoadProfile { get }` (`.lightweight` / `.heavyweight(estimatedPeakBytes:)`), and a heavyweight engine is never auto-loaded; with a heavyweight-only fallback the stage resolves to C7's notes-pending outcome (transcript persisted, no handoff, self-healing retry)**. Both-fail on a lightweight hop → honest processing failure with both reasons. A successful fallback is recorded in provenance (which names the engine that actually ran) and in `Meeting.processingNote` — never silent, never misattributed.

## ASR granularity justification (recorded)

Segment-level output suffices for V1: C4 merges diarization by time-overlap at segment granularity (validated); word-level timing/confidence stay reachable in `rawPayload` for future chunks without a protocol change.

## Acceptance criteria

1. `scripts/test.sh` green. New tests: registry init order/lookup/duplicate-throw; resolution paths 1/2/3 incl. fallback flag and empty-slot throw; `NotesRenderer` golden tests in BOTH languages (byte-identical output; PT headings under `pt-BR`; EN otherwise; empty-section markers; always-rendered, name-driven user action-items section; heading-demotion, title-flattening (hostile multi-line `#`-laden title), and list-item normalization against hostile engine output) and refusal of empty `summary` (`.invalidStructuredNotes`); `UserIdentity` default + round-trip; migration v2 applies on top of v1 (fresh DB ends at v2; `structured` column present); populated-v1 upgrade test: a v1 DB with a planted `meeting_notes` row makes the v2 migration fail loudly (defined behavior, asserted) — acceptable because a populated v1 cannot exist outside tests (the first notes-writer, C7, ships after v2; invariant stated here so it is never silently broken); `MeetingNotes` round-trip with structured; `EngineUsage`/cost descriptor Codable round-trips; mock engines (`MockASREngine`, `MockSummarizationEngine` in test support) exercising: hints contract recording, `.cancelled` on cancelled Task, `.configurationMissing` path via `InMemorySecretStore` lacking a required secret; `KeychainSecretStore` set/get/delete smoke test (skipped with explicit reason if the test host lacks keychain access — never silently green).
2. No UI, no concrete engines, no network. BlaiseApp unchanged except composition-root constructing an empty-slot registry (mocks exist only in tests).
3. Build green via `scripts/build_app.sh`; C1 suite still green (migration v2 must not break v1 assertions beyond the intended `user_version` change).
4. C1 spec amendment line (raw_asr.json envelope) applied to specs/c1_scaffold_storage.md by this chunk, referencing this spec.

## Out of scope

Concrete engines (C3/C6), Settings UI (C10), cost-ceiling *enforcement* (C6), streaming/live (V1.1+), word-level ASR output (rawPayload covers future needs).
