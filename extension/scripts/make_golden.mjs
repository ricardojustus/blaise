// make_golden.mjs — regenerates the cross-chunk golden fixtures:
//   test/fixtures/wire_batch_golden.json   (encrypted batch + test secret)
//   test/fixtures/expected_ingestion.json  (post-substitution events)
// Run only when the wire contract changes (docs/meet_events_contract.md);
// the C10/C11 listener's acceptance consumes BOTH files, so regeneration is
// a contract event, not housekeeping.
//
// Usage: node scripts/make_golden.mjs
import { createRequire } from "node:module";
import { writeFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const BC = require("../src/crypto.js");

const FIXTURES = join(dirname(fileURLToPath(import.meta.url)), "..", "test", "fixtures");

// Test-only secret (the app generates 32 random bytes hex; this one is
// fixed so both sides can decrypt the committed golden).
const TEST_SECRET = "5db1ae0d3b1f6c2a9e84d7f0c6b35a18e29f4c7d8a01b3e5f6a7c8d9e0f1a2b3";

// Synthetic identities only. "Conta Local" stands in for the account
// display name the listener substitutes for isSelf events.
const SELF_SUBSTITUTION_NAME = "Conta Local";

const batch = {
  meetingCode: "abc-defg-hij",
  capturedAtMs: 1781136000000, // 2026-06-07 00:00:00 UTC-ish, fixed
  droppedCount: 0,
  poisonedCount: 0,
  roster: [
    { displayName: null, participantID: "pid-1", isSelf: true },
    { displayName: "Maria Silva", participantID: "pid-2", isSelf: false },
    { displayName: "João Pereira", participantID: "pid-3", isSelf: false },
    { displayName: "Participante Um", isSelf: false }, // tile-only, no id scraped
  ],
  events: [
    {
      displayName: "Maria Silva",
      participantID: "pid-2",
      isSelf: false,
      startEpochMillis: 1781135000000,
      endEpochMillis: 1781135004500,
    },
    {
      displayName: null,
      participantID: "pid-1",
      isSelf: true, // the isSelf case: listener substitutes the account name
      startEpochMillis: 1781135005000,
      endEpochMillis: 1781135012000,
    },
    {
      displayName: "Participante Um",
      isSelf: false, // no participantID: dedupe id falls back to the name
      startEpochMillis: 1781135013000,
      endEpochMillis: 1781135015500,
    },
    {
      displayName: "Maria Silva",
      participantID: "pid-2",
      isSelf: false,
      startEpochMillis: 1781135016000,
      endEpochMillis: 1781135021000,
    },
  ],
  schemaVersion: 1,
};

const envelope = await BC.encryptBatch(TEST_SECRET, batch);

const wire = {
  _comment:
    "Cross-chunk golden (C12 -> C10/C11 listener acceptance). deliveries[1] is a byte-identical REPLAY of deliveries[0] (AEAD does not prevent replay; the listener's per-meeting seen-id dedupe must ingest its events exactly once). Synthetic names only. Regenerate with scripts/make_golden.mjs only on contract changes.",
  contract: "docs/meet_events_contract.md",
  testSecret: TEST_SECRET,
  endpoint: "POST /v1/meet-events",
  aad: "blaise-meet-events-v1",
  ackHeader: "X-Blaise-Ack",
  deliveries: [envelope, envelope],
};

const expected = {
  _comment:
    "Expected listener ingestion for wire_batch_golden.json: decrypt both deliveries with testSecret, substitute selfSubstitutionName for isSelf events (displayName is null on the wire by design), dedupe by per-meeting seen-id set. Events are in ActiveSpeakerEvent Codable form (snake_case, BlaiseCore/SpeakerResolver.swift). Each event appears ONCE despite the replayed delivery.",
  meetingCode: "abc-defg-hij",
  selfSubstitutionName: SELF_SUBSTITUTION_NAME,
  expectedRoster: [
    { displayName: SELF_SUBSTITUTION_NAME, participantID: "pid-1", isSelf: true },
    { displayName: "Maria Silva", participantID: "pid-2", isSelf: false },
    { displayName: "João Pereira", participantID: "pid-3", isSelf: false },
    { displayName: "Participante Um", isSelf: false },
  ],
  activeSpeakerEvents: [
    {
      display_name: "Maria Silva",
      participant_id: "pid-2",
      start_epoch_millis: 1781135000000,
      end_epoch_millis: 1781135004500,
    },
    {
      display_name: SELF_SUBSTITUTION_NAME,
      participant_id: "pid-1",
      start_epoch_millis: 1781135005000,
      end_epoch_millis: 1781135012000,
    },
    {
      display_name: "Participante Um",
      start_epoch_millis: 1781135013000,
      end_epoch_millis: 1781135015500,
    },
    {
      display_name: "Maria Silva",
      participant_id: "pid-2",
      start_epoch_millis: 1781135016000,
      end_epoch_millis: 1781135021000,
    },
  ],
};

writeFileSync(
  join(FIXTURES, "wire_batch_golden.json"),
  JSON.stringify(wire, null, 2) + "\n",
);
writeFileSync(
  join(FIXTURES, "expected_ingestion.json"),
  JSON.stringify(expected, null, 2) + "\n",
);
console.log("golden fixtures written to", FIXTURES);
