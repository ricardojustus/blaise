# G3 — Identity Onboarding + Neutral Defaults (v1)

**Goal.** Any user becomes "the user" the way a single hardcoded identity did before: first-launch onboarding writes their identity; the shipped defaults carry no personal data. (publish_plan G3; D19.)

## 1. Current state
- `UserIdentity.shippedDefault` = a hardcoded name/aliases/email (Engines.swift:117-121), reached via `?? .shippedDefault` at: ProcessingPipeline.swift:1563, MeetEventsIngestor.swift:630, HandoffWorker.swift:457, SettingsModels.swift:270, AppEnvironment.swift:78 (boot-time `userEmail`). Settings → Identity edits all fields (SettingsView IdentitySection).
- Notes render "<name>'s action items"/"Ações de <name>" (NotesRenderer LocalizedStrings); UI section "<name> — Action Items" (MeetingDetailView); prompts carry a worked example "<name> — enviar proposta…". The schema KEY rename is G4, not here.

## 2. Changes
1. **Neutral default:** `shippedDefault` becomes `UserIdentity(name: "", aliases: [], email: "")`. Every `?? .shippedDefault` site keeps compiling; empty identity = "not yet onboarded".
2. **Onboarding sheet** on launch when identity is empty (name field, optional nicknames, optional email with the one-line why: "matches you in calendar invites"). Skippable (Later) — the app works unnamed: mic track labels "You"; the action-items section renders "My action items"/"Minhas ações". Re-offered from Settings, never nagging (one sheet per launch at most).
3. **Name-driven rendering:** renderer + UI derive the section title from identity (`<name> — Action Items` / `Ações de <name>`; empty → My/Minhas). The notes PROMPT keeps its generic instruction (it already keys on "the user"); the worked example switches from the prior hardcoded name to a neutral invented name. CAUTION: prompts are HASH-PINNED — this re-pins `systemPromptV1` (and the flagged v11/v2 texts). Re-pinning a frozen prompt requires a paired BLIND faithfulness re-gate? NO — by D-record the v1 prompt's example-name is non-semantic; the change is mechanical. Required instead: the wire-order pins stay green, the new hash is recorded in the same commit, and ONE cloud generation on the regression transcript is diffed for structural equality (same sections, same item counts) as a smoke gate — logged with cost (~$0.06, announced).
4. **The user's machine:** their stored Settings identity already carries their values (verify before merging; if the store still relies on the compiled default, write the values into the store as a deploy step — no code).
5. Demo seeder stays demo-flavored until G6; it sets an explicit demo identity so demos don't trigger onboarding.

## 3. Acceptance criteria
- AC1: empty-identity launch shows onboarding once; Later → functional app, "My action items" rendering, mic labeled "You"; completing it writes the same store Settings edits.
- AC2: every `?? .shippedDefault` consumer behaves with empty identity (attendee self-exclusion no-ops without email; payload owner carries empty fields honestly — the evidence contract §2 owner note gains "may be empty pre-onboarding", contract doc bumped).
- AC3: renderer goldens for named + unnamed in EN/PT; UI section title follows.
- AC4: prompt hash re-pin recorded; wire-order pins green; the one-generation structural smoke diff logged with receipts.
- AC5: suite green; transcript pins byte-unchanged (notes pins move ONLY by the §2.3 example-name change — if so, re-pin in the same commit with the structural-equality evidence, explicitly logged; this is the single sanctioned pin move).
- AC6: demo seeder identity explicit; demos never show onboarding.

## CHANGELOG
- v1 (12/06/2026): initial spec.
