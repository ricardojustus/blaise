# G1 — User Glossary (v4.2)

**Goal.** Replace the compiled-in default vocabulary with a per-user, agent-fillable glossary file plus a Settings editor, so any user can teach Blaise their people/product/project names. Foundation for G2 (deterministic name substitution) and a precondition for publication (D19).

**Hard floors touched:** floor 1 directly — the glossary is UNTRUSTED input at a system boundary. C5's safety today is curation-time (VocabTool, human-reviewed); G1 moves a MECHANICAL equivalent to load time. It is deliberately MORE conservative than the curated file on the canonical side (§5a.3: over-suppression by design — a name that loses automatic correction still spells correctly in notes; nothing can become LESS safe than C5). Scope discipline otherwise: no watchers, no multi-glossary, no per-language glossaries, no migration code, no per-entry user overrides (BACKLOG if over-suppression ever bites a name the user cares about).

## 1. Current state (what this replaces)

- A compiled-in default vocabulary file (`app/Sources/BlaiseCore/Resources/`) is in the BlaiseCore resource bundle (`Package.swift` `.copy`), loaded via `PipelineVocabulary.bundled()`.
- Construction sites (each switches per §3): `AppEnvironment.swift:148` (app), `PipelineTestSupport.swift:305`, `MintHarness.swift:87`, `CrashRunner/main.swift:194`, plus anything `git grep -n "PipelineVocabulary"` reveals at implementation time (final list in the commit message).
- Consumers: `VocabCorrector` (post-ASR correction; a canonical fires `.exact` on its case/diacritic variants — VocabularyCorrector.swift:128-148 — unless suppressed via the EXISTING `suppression:` parameter, which leaves that entry's ALIASES firing: VocabularyCorrector.swift:119-126 vs :136-142); `canonicalTerms` (notes prompt, C6); speaker-naming context (C7).
- C5's safety machinery in code: `AliasAdmission.evaluate` (BlaiseCore; whole-surface lexicon checks; typed `Rejection`); the **alias-core scan** at `VocabTool.swift:535-543` (VocabTool target; rejected "Open Door" on the record); the canonical-side **suppression set** sourced today from `stoplist_project.txt` dispositions (human-curated Level-A review outcomes — there is no single "Level-A threshold" in code; the bands that exist are the top-3,000 unsafe band at `VocabStopLists.swift:67`, the 40,000 rank cut at `VocabTool.swift:427`, and full lexicon membership).
- Entry grammar: `canonical` or `canonical|alias1|alias2`, `#` comments, blank lines ignored; parse() drops a whole entry on an empty alias field (VocabularyDictionary.swift:42-44); field trims lack `\r`.

## 2. The glossary file

**Location:** `<dataRoot>/Glossary.md`; `BLAISE_DATA_ROOT` overrides apply as everywhere else.

**Region rule:** parse ONLY between the first line equal to `## Entries` (after trimming space/tab/`\r`; case-sensitive, single space) and the next line starting with `## ` (same trim) or EOF. No heading → empty glossary + `noEntriesHeading`. If a `## ` line terminates the region BEFORE EOF and ANY non-blank, non-`#` line follows it, emit `regionEndedEarly(line)` — informational, surfaced in Settings, so a stray in-body heading cannot silently strand entries.

**In-region line handling** (wrapper over `VocabularyDictionary.parse`; divergences are deliberate amendments applied at parse(), with its tests updated):

- Blank lines and `#` comments ignored (organize with `#`; `##` would end the region — the template says so).
- Leading `- ` / `* ` list markers stripped before parsing (agents write bullets).
- Lines starting (post-strip) with ``` or `>`: `markdownArtifact` — skipped with diagnostic.
- Entries: `canonical` or `canonical | alias | …`, fields trimmed incl. `\r`. Empty alias field → dropped FIELD-WISE with `emptyAlias`, entry survives.
- **Size cap:** first 2,000 entries effective; remainder dropped with one `glossaryTruncated(count)`.

**Shipped template** (`Resources/glossary_template.md`; `synthetic_vocab.txt` REMOVED from the app target). Full text:

```markdown
# Blaise Glossary

This file teaches Blaise the names it will hear in your meetings: people,
companies, products, projects. Blaise uses it to fix misheard words in
transcripts and to spell names correctly in notes.

## Instructions for an AI agent

You are filling in a speech-recognition glossary for your user. Add one line
per name under the `## Entries` heading below, in this exact format:

    Canonical Name | misheard1 | misheard2

- The first field is the correct spelling. The fields after `|` are ways
  speech recognition plausibly mishears it (optional).
- Draw from: the user's contacts and colleagues, company and team names,
  product and project names, recurring meeting vocabulary. Prefer names that
  actually occur in their meetings; do not paste an entire address book.
- SAFETY — read carefully. Every alias tells Blaise to rewrite that word,
  wherever it appears, into the canonical form — and a canonical name also
  attracts its own close spelling variants. Blaise screens everything
  against Portuguese and English everyday-word lists and REJECTS or LIMITS
  anything that could rewrite normal speech (each decision is reported in
  the app's Settings, never silently applied). Do your part: never use a
  common word, a common given name, or a short everyday term as an alias;
  prefer distinctive spellings; when unsure, add the name with no aliases —
  a plain name still fixes note spelling even when automatic transcript
  correction is limited for it.
- Organize with `#` comment lines if you like. Do NOT add `##` headings
  inside the entries (that ends the section), and do not edit anything
  above the `## Entries` heading.

## Entries

# Examples (commented out — replace with your own):
# Vexatron Labs | Vexatron Labs Inc | Vexatrón
# Quoll Harbor | Quol Harbour
```

(Fictional, distinctive-core examples — agents imitate examples. Commented out: a fresh install has an EMPTY effective glossary.)

## 3. Loading and lifecycle

- `PipelineVocabulary.user(dataRoot:)`: read → region-extract → parse → admission (§5a) → dictionary + suppression set; called AT EACH PIPELINE RUN START, including the D17 notes-pending resume path — every run that constructs a corrector or notes vocabulary. The §1 sites switch: app → `user(dataRoot:)`; `PipelineTestSupport`, `MintHarness`, `CrashRunner`, regression/pin tests → `PipelineVocabulary.fixture()` — raw `parse` of `fixtures/synthetic_vocab.txt` resolved via the test target's existing `#filePath` fixtures convention (CrashRunner: its existing repo-relative path mechanism), NO region extraction, NO admission, suppression set from `stoplist_project.txt` exactly as `bundled()` wires it today — byte-preserving every pinned behavior. `bundled()` is then deleted with the resource.
- Missing file at run: empty glossary + `fileMissing` (recovery: launch provisioning §4 recreates on next launch; Settings' "Restore entries section" covers the headingless case; no run-time writes).
- Unreadable / non-UTF8: empty glossary + `fileUnreadable`.
- Construction faults are ISOLATED: entries are added to the dictionary one at a time; an entry whose insertion would throw (e.g. residual taxonomy overlap) is dropped with `entryRejected(reason)` and the rest survive. Only if construction fails outright despite that does the run proceed with an empty vocabulary + `glossaryRejected(reason)`. THE GLOSSARY NEVER FAILS A PIPELINE RUN — stated invariant, tested by fault injection at the named seam: the `user()` loader's dictionary-construction step takes an injectable `build` closure in tests (same seam style as the worker's injected clock).

## 4. First launch / provisioning

In the startup phase that ensures the data root and DB exist: if `Glossary.md` is absent, write the template via temp + atomic rename; never overwrite. The only writer besides the Settings editor. (Demo/`BLAISE_DATA_ROOT` roots included — same path, harmless.)

## 5. Safety and diagnostics

### 5a. Load-time admission — mechanical C5 equivalent, conservative by design

Applied to parsed entries; produces the runtime dictionary, the corrector suppression set, and diagnostics. THE FILE IS NEVER MODIFIED BY ADMISSION.

The admission gates fold the RAW surface of an alias, but the corrector keys on the tokenizer-PEELED cores (edge punctuation peeled, whitespace normalized). Gates 0a/0b close that representation gap BEFORE the lexicon gates, so nothing punctuation-decorated or empty can slip a bare everyday word past gates that inspected a different string:

0a. **Punctuation safety (alias) — the total no-punctuation rule.** This is C5's curation assertion relocated to load time at its full intent (`VocabTool.swift`, the "alias carries punctuation other than apostrophes" fail). An alias must be plain matchable text: after the canonical fold, an alias containing ANY character that is not a letter, a digit, or a single internal space is REJECTED field-wise with a punctuation-specific `aliasRejectedUnsafe(reason)`. No edge-vs-interior distinction — trailing periods, markdown (`**marsa**`), parentheses, commas, apostrophes (straight AND curly), quotes, em-dashes, interpuncts, fullwidth forms, zero-width characters, and INTERIOR hyphens all reject. Interior punctuation matters because the corrector keys on peeled cores: an interior hyphen (`segunda-feira`, `fim-de-semana`) survives peeling into the core, and the PT lexicon lists no hyphenated compounds, so such an alias would silently rewrite everyday Portuguese. The straight/curly apostrophe is rejected too (a possessive/quoted alias like `cat's`, `maria's`, `marsa'` otherwise fires on ordinary speech and can even consume an adjacent quote). **Owned consequence (the same trade C5's curation made): a legitimately hyphenated or apostrophe-bearing name loses alias rights and must be written unhyphenated/plain to serve as an alias.** Belt-and-braces: for multi-token aliases, gates 1–2 also re-run against the peeled-core representation, so no representation mismatch class can recur.

0b. **Empty-core safety (canonical and alias).** Any canonical or alias whose peeled core set is EMPTY (every token is pure edge punctuation, e.g. `---`, `...`) carries no matchable text and would otherwise register under the empty window key and fire on standalone punctuation transcript tokens. An empty-core canonical rejects the WHOLE entry with `emptyCanonical`; an empty-core alias drops field-wise with `aliasRejectedUnsafe(reason)`. Defense in depth: the corrector's `register` also refuses any surface whose tokens all peel to empty cores, AND the corrector's canonical-suppression membership check drops empty cores so a stray punctuation token cannot defeat it — so an empty window key can never register and a punctuation-token-bearing canonical can never escape its limitation. The gate is primary, the guard is structural.

1. **Alias lexicon gate:** every alias through `AliasAdmission.evaluate` (existing policy untouched). Rejected → field-wise drop, `aliasRejectedUnsafe(reason)`.
2. **Alias-core scan:** the `VocabTool.swift:535-543` scan RELOCATED into BlaiseCore beside `AliasAdmission` — same code, same lexicons (all BlaiseCore-reachable: FrequencyList, VocabTokenizer, VocabNormalization), VocabTool switching to the moved code. Its behavior is pinned by NEW BlaiseCore tests written from the scan's recorded decisions (the "Open Door" rejection among them) — VocabTool itself has no test target (Package.swift:70), so equivalence is pinned where the code now lives. An alias with no distinctive core → `aliasRejectedUnsafe(reason)`.
3. **Canonical correction-limitation scan — the named band, plus punctuation/empty-core.** For each canonical, compute its peeled cores (same tokenizer/fold as the alias scan; empty cores dropped before the everyday test, so a stray punctuation token never defeats the limitation). A core is **everyday** iff it is in the top-3,000 unsafe band (`VocabStopLists.swift:67`) OR is a member of either frequency lexicon (any rank) OR of `br_common_names.txt` — i.e. exactly the membership checks gates 1–2 already use, no new threshold invented. A canonical is correction-LIMITED when EITHER (a) every non-empty core is everyday, OR (b) its folded surface carries any character that is not a letter/digit/space, OR any of its tokens peels to an empty core (`**Vexatron**`, `Maria Silva -`, `Está -`, `Marsa. -`). The punctuation/empty-core arm (b) is symmetric with gate 0a on the alias side: gate 0a is not run over canonicals (a canonical's punctuation is the user's chosen spelling, kept for notes), but a decorated canonical must NOT register for correction — otherwise the raw canonical string replaces every transcript hit, injecting markdown/punctuation/diacritics into ordinary speech, and an empty-core token fires on a standalone dash. A limited canonical joins the corrector **suppression set** (the existing `suppression:` parameter — C5's own mechanism): its case/diacritic variants are NOT rewritten, while its ADMITTED ALIASES STILL FIRE (VocabularyCorrector.swift:119-126) and it remains in `canonicalTerms` for notes (so a decorated canonical still spells its decorated form in notes). Diagnostic `canonicalCorrectionLimited`, Settings wording: "used for note spelling (and its mishearings still correct); automatic variant-correction is off for this name because it matches everyday words". If at least one core is non-everyday AND the surface is punctuation-free with no empty-core token, the canonical corrects normally.
   - **Owned consequence:** this is intentionally MORE suppressive than the curated file. Lexicon-member names ("Claude", "Atlas", all-common-name people entries like "Maria Silva") lose variant-correction that today's curated file grants them — their aliases and note spelling are untouched, and the error direction is the safe one (under-correction, never rewriting real speech). This is the accepted trade for unsupervised input; a per-entry override is BACKLOG, not G1.
4. Order: parse-level checks → 0a/0b → 1 → 2 → 3; size cap at parse.
- Performance: gates 1–2 load the same lexicons C5 already ships; first use per process loads them, subsequent loads may cache the admitted result keyed on (mtime, size) — behavior identical.

### 5b. Diagnostics

`GlossaryDiagnostics` per load: counts (parsed, effective, aliases admitted, canonicals limited) + items `(absolute line number, prefix ≤ 40 chars, reason)`. Closed set — file-level: `noEntriesHeading`, `fileMissing`, `fileUnreadable`, `glossaryRejected(reason)`, `glossaryTruncated(count)`, `regionEndedEarly(line)`; line-level: `emptyCanonical`, `duplicateCanonical` (fold-dup, first wins), `aliasCollidesWithCanonical` (line skipped), `aliasDuplicated` (line skipped), `emptyAlias`, `aliasRejectedUnsafe(reason)`, `canonicalCorrectionLimited`, `entryRejected(reason)`, `markdownArtifact`. Fold = the C5 canonical fold. Fresh-launch state (no load yet): Settings shows "not loaded yet — runs at the next meeting's processing" with an on-demand **"Check now"** that performs a load (read-only) purely to refresh diagnostics. Latest load rides the pipeline-activity observable, timestamped with source; unified-logged.

## 6. Settings → Glossary tab

Placement: after Automation, before Identity & Handoff.

- **Source of truth = the file's RAW ENTRIES.** Table mirrors parsed entries in FILE ORDER, including entries with rejected aliases or limited correction — annotated inline (§5b wording), never dropped by the editor. Add appends at region end; edit in place; delete removes the row. Inline validation: `|` and leading `#` rejected with a hint.
- **Save = regenerate the region.** REQUIRED invariants: (1) outside-region bytes identical; (2) no entry lost or reordered; (3) top-of-region `#` comments preserved; (4) parser-skipped lines (`markdownArtifact` etc.) preserved verbatim in position. DOCUMENTED LIMITATION (not an invariant): `#` comments interleaved BETWEEN entries may be repositioned or dropped by a save that edits adjacent rows. Temp + atomic rename.
- **Concurrency:** mid-flight runs keep their loaded vocabulary; saves apply next run; atomic rename prevents torn reads. No locking.
- **"Copy agent prompt":** copies: `Open the file <absolute path>/Glossary.md and follow the instructions inside it: fill the ## Entries section with the people, companies, products, and projects from my context, one per line in the "Canonical Name | misheard1 | misheard2" format. Read the SAFETY note in the file before adding any mishearing. Do not edit anything above the ## Entries heading.`
- **"Show in Finder"**; **diagnostics strip** (counts; items with line + reason; `noEntriesHeading` warning with **"Restore entries section"** — appends `\n## Entries\n` + the template's commented examples at EOF, never touches existing text, disabled when the heading exists; "Check now" per §5b).

## 7. Acceptance criteria

- **AC1 (parser):** region extraction (missing heading; EOF heading; `##  Entries`/`## entries` non-match; first heading wins; `## People` terminates AND emits `regionEndedEarly` when entries follow; CRLF identical incl. field trims); bullet-strip; every §5b reason tested incl. `emptyAlias` survival, `markdownArtifact`, `glossaryTruncated` boundary; fold collisions incl. diacritics; template → zero effective entries.
- **AC2 (admission, all gates):** (a) stoplist-word/common-name single-token alias rejected, transcript NOT corrected (end-to-end, temp root); (b) no-distinctive-core multi-token alias ("Open Door" shape) rejected by the relocated scan, whose recorded-decision pins also pass; (c) safe multi-token alias admitted and corrects; (d) canonical `Mato`, no aliases → "mato" NOT rewritten in a transcript (the corrector-path pin at VocabularyCorrector.swift:128-148) AND `Mato` present in the notes prompt's CANONICAL VOCABULARY block; (e) canonical with a distinctive core corrects its diacritic variant as today; (f) a LIMITED canonical's admitted alias still fires (suppression-set semantics).
- **AC3 (lifecycle):** two-run hot reload without restart; missing file → run succeeds + `fileMissing`; injected build-closure fault → entry-level `entryRejected` isolation, and a full-construction fault → empty vocabulary + `glossaryRejected`, run succeeds (the never-fails invariant, at the §3-named seam).
- **AC4 (provisioning):** fresh root → template byte-identical; existing file never overwritten (byte-pinned).
- **AC5 (editor):** round-trip add/edit/delete with all four invariants (incl. a `markdownArtifact` line and a rejected-alias entry surviving verbatim); `|`/`#` field rejection.
- **AC6 (default-vocab removal, scoped):** built bundle contains no compiled-in default vocabulary file; `bundled()` gone; the relocated scan's BlaiseCore pins green. Surviving personal/company references in app sources listed verbatim in the commit message as the publish_plan Part 3 G6 handoff (G6's list, amended 11/06, owns them; the G1 section's earlier "move out" sentence is superseded by that list — publish_plan edited accordingly in this chunk).
- **AC7 (suite + pins):** `scripts/test.sh` exit 0; pinned regression outputs byte-UNCHANGED via `fixture()`; a moved pin is a FINDING, never a re-pin.

## 8. Out of scope (explicit)

G2 substitution; the G6 scrub beyond the publish-plan list amendment; per-entry suppression overrides; multi-glossary; per-language glossaries; file watching; editor undo; glossary sync.

## 9. Rollout note (operational, not code)

After merge: write the user's `Glossary.md` into their real data root — template header + Entries from `fixtures/synthetic_vocab.txt` (mechanical reformat). Verification is ONE-DIRECTIONAL by design: every term `stoplist_project.txt` suppresses today MUST appear as `canonicalCorrectionLimited` (a miss = unsafe regression = finding); the load gate WILL additionally limit lexicon-member names ("Claude", "Atlas", common-name people entries) — review that over-suppression list at rollout, note anything that hurts in BACKLOG (per-entry override candidate), and spot-check a known term on the next meeting.

## CHANGELOG

- v4.2 (11/06/2026): implementation-audit round-2 fix pass. Gate 0a becomes the TOTAL no-punctuation rule (any non-letter/digit/single-space character rejects an alias) — the round-1 edge-peel check let internal punctuation through, so a hyphenated everyday PT compound (`segunda-feira`) and the apostrophe carve-out (`cat's`, `maria's`) silently rewrote ordinary speech (R2-C-1/R2-H-1); the hyphenated/apostrophe-alias consequence is owned, mirroring C5's curation. Gate 3 gains a symmetric punctuation/empty-core arm so a decorated canonical (`**Vexatron**`) or one carrying a punctuation-only token (`Maria Silva -`, `Está -`, `Marsa. -`) is correction-limited instead of injecting its raw form into transcripts (R2-H-2/R2-M-1); the underlying empty-core holes are fixed structurally (gate 3 drops empty cores before the everyday test; the corrector's suppression-membership check drops them too). Editor rejected-alias annotations now attribute to the exact owning row by source line, fixing the n≥3 shared-alias mis-attribution (R2-L-3). Gate 0a, the empty-core helpers, and the corrector register guard each gain a direct, independently-failing unit pin (R2-L-1/R2-L-2). BACKLOG L-5 wording corrected to stop overstating the M-2 wiring (R2-L-4).
- v4.1 (11/06/2026): implementation-audit round-1 fix pass. §5a gains gates 0a (punctuation safety) and 0b (empty-core safety) ahead of the lexicon gates — the gates fold the raw alias surface but the corrector keys on tokenizer-peeled cores, so a punctuation-decorated alias (`marsa.`, `**marsa**`) or a punctuation-only entry (`---`) slipped past round-1 and rewrote everyday speech (C-1/C-2); gates 1–2 also run against the peeled representation, and the corrector's `register` refuses empty-core surfaces (defense in depth). Admission diagnostics now carry absolute file line numbers (M-1). The remaining round-1 Mediums (run-load on the pipeline-activity observable + unified log; mixed-line-ending byte preservation; editor field validation blocking saves; rejected-alias inline annotation) are implementation conformance to clauses already in §5b/§6, not spec changes. Round-1 Lows triaged internally.
- v4 (11/06/2026): round-3 audit (0C/1H/2M/13L). R3-H-1: the invented "Level-A thresholds" replaced by the NAMED everyday-core test (top-3,000 band + lexicon/common-name membership — the same checks gates 1–2 use); over-suppression owned as design with the safe error direction stated; §9 parity rescoped one-directional. R3-M-2: suppression-set mechanism (existing `suppression:` parameter) replaces entry exclusion — admitted aliases keep firing (AC2(f)); no PipelineVocabulary restructure assumed. R3-M-1: `regionEndedEarly` diagnostic. Lows fixed in-text: lexicon-loading premise, AC label hygiene, template language claim (PT/EN named), fixture()/CrashRunner sourcing named, fileMissing recovery path, mid-region-comment limitation documented, VocabTool-tests clause replaced with recorded-decision pins in BlaiseCore, fault-isolation per entry + named injection seam, publish_plan contradiction resolved (G6 list supersedes). Remaining round-3 Lows triage to BACKLOG at implementation.
- v3 (11/06/2026): complete load-time safety (canonical scan + relocated core scan), raw-file editor semantics, seams enumerated, cap, never-fails invariant.
- v2 (11/06/2026): load-time alias admission, safe fictional examples, AC corrections.
- v1 (11/06/2026): initial spec.
