# G7 — Per-Call Cloud-Spend Receipts (v1)

**Goal.** Every cloud call leaves a receipt; Settings → Cloud Spend explains the bill line-by-line. Motivated by a user field question ("$2.07 with 6 meetings… something HAS to be wrong") that took manual reconstruction to answer. (BACKLOG 11/06.)

## 1. Design (settled)
- **Migration (additive):** `cloud_spend_receipt` table: id ULID, timestamp, month_key, engine_id, model, purpose TEXT CHECK IN ('generation','regeneration','validation','smoke'), meeting_id NULLABLE (FK, ON DELETE SET NULL), input_tokens, output_tokens, cost_usd REAL, note TEXT NULL. The existing `cloud_spend` month accumulator STAYS (it is the ceiling-enforcement source of truth; receipts are the explanation, accumulator the gate — they must reconcile but the gate never depends on a JOIN).
- **Write point:** the SAME place the accumulator is bumped today (engine post-hoc usage accounting) — one transaction updates both; a receipt-write failure fails neither the call nor the accumulator bump (log loudly; the accumulator is authoritative). A receipt whose `meeting_id` has no meeting row (a harness/validation call made outside a pipeline run) is NOT dropped on its foreign-key violation: the ledger detects the missing row and writes the receipt with `meeting_id` NULL — the money and the line item survive, only attribution is lost (the row shows a purpose badge).
- **Purpose attribution:** the pipeline passes purpose down. `process()`/`processCaptured()` = generation. `regenerate()` of a ready meeting = regeneration. The notes-pending self-heal resume is attributed by whether the meeting was ALREADY noted: a resume that re-produces notes for a meeting that already had a `meeting_notes` row = regeneration; a resume that produces a meeting's FIRST notes (the common case where the original `process()` reached the ceiling or had no key and never noted it) = generation. Harness/tests = validation; G3/G4 smoke gates = smoke (the smoke purpose is reserved — not yet written by any code path until those gates land). Default 'generation' if unspecified.
- **Settings UI:** Cloud Spend panel gains the receipts table (month-filtered, newest first: time, meeting title (or purpose badge), tokens in/out, cost) + a per-purpose month subtotal strip ("Meetings $0.33 · Regenerations $0.25 · Validation $0.00") + a reconciliation line (receipts sum vs accumulator; mismatch shown honestly with the delta — pre-receipts history makes a permanent initial delta, labeled "before receipts existed").
- Test/demo data roots get their own receipts naturally (separate DBs) — the real ledger stays clean of dev spend BY CONSTRUCTION (the 11/06 confusion class).

## 2. Acceptance criteria
- AC1: migration additive; old DBs open; pinned payload/regression unaffected.
- AC2: engine-level test — one generate() writes accumulator + receipt atomically with matching cost; injected receipt-write failure leaves accumulator bumped + call successful + loud log.
- AC3: purpose threading — process/regenerate/pending-retry produce the right purpose (integration tests with the recording engine stub).
- AC4: UI renders the table + subtotals + reconciliation from a fixture DB (golden-ish assertions at the model layer; rendering eye-verified honestly).
- AC5: suite green; no engine call added anywhere (receipts are bookkeeping on existing calls).

## CHANGELOG
- v1 (12/06/2026): initial spec.
- v1.1 (12/06/2026): round-1 audit fixes clarified in the design — notes-pending resume purpose discriminated by prior `meeting_notes` existence (never-noted resume = generation); FK-absent receipts kept with `meeting_id` NULL rather than dropped; smoke purpose documented as reserved.
