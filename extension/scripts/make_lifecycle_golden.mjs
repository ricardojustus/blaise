// make_lifecycle_golden.mjs — regenerates the C14 cross-chunk golden pair:
//   test/fixtures/wire_batch_lifecycle_golden.json   (encrypted v2 batch:
//     lifecycle call-started + events + roster)
//   test/fixtures/expected_lifecycle.json            (expected tracker/
//     ingestion outcomes the app-side acceptance asserts)
// Same pattern as make_golden.mjs (the C12 pair stays green untouched).
// Regenerate only on contract changes (docs/meet_events_contract.md v2).
//
// Usage: node scripts/make_lifecycle_golden.mjs
import { createRequire } from "node:module";
import { writeFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const BC = require("../src/crypto.js");

const FIXTURES = join(dirname(fileURLToPath(import.meta.url)), "..", "test", "fixtures");

const TEST_SECRET = "5db1ae0d3b1f6c2a9e84d7f0c6b35a18e29f4c7d8a01b3e5f6a7c8d9e0f1a2b3";
const SELF_SUBSTITUTION_NAME = "Conta Local";

// A v2 batch as the extension ships it on the idle→in-call transition that
// also carried one closed utterance: lifecycle + roster + events in one
// envelope. Synthetic identities only.
const batch = {
  meetingCode: "abc-defg-hij",
  capturedAtMs: 1781136000000,
  droppedCount: 0,
  poisonedCount: 0,
  roster: [
    { displayName: null, participantID: "pid-1", isSelf: true },
    { displayName: "Maria Silva", participantID: "pid-2", isSelf: false },
  ],
  events: [
    {
      displayName: "Maria Silva",
      participantID: "pid-2",
      isSelf: false,
      startEpochMillis: 1781135990000,
      endEpochMillis: 1781135995500,
    },
  ],
  schemaVersion: 2,
  lifecycle: { kind: "call-started", atMs: 1781135999000 },
};

const envelope = await BC.encryptBatch(TEST_SECRET, batch);

const wire = {
  _comment:
    "C14 cross-chunk golden (extension -> listener/tracker). deliveries[1] is a byte-identical REPLAY of deliveries[0]: the per-meeting seen-id dedupe ingests its event once, and the tracker's per-code monotonic guard must let the replay re-fire NOTHING. Synthetic names only. Regenerate with scripts/make_lifecycle_golden.mjs only on contract changes.",
  contract: "docs/meet_events_contract.md (schema v2)",
  testSecret: TEST_SECRET,
  endpoint: "POST /v1/meet-events",
  aad: "blaise-meet-events-v1",
  ackHeader: "X-Blaise-Ack",
  deliveries: [envelope, envelope],
};

const expected = {
  _comment:
    "Expected outcomes for wire_batch_lifecycle_golden.json: both deliveries ack 200; the event ingests ONCE; the ingestor forwards ONE acted-on signal (meetingCode, capturedAtMs, lifecycle) per delivery but the tracker's monotonic guard drops the replay; a fresh call-started (now - atMs <= 120 s) posts exactly ONE 'Meeting in progress' notification.",
  meetingCode: "abc-defg-hij",
  selfSubstitutionName: SELF_SUBSTITUTION_NAME,
  schemaVersion: 2,
  lifecycle: { kind: "call-started", atMs: 1781135999000 },
  capturedAtMs: 1781136000000,
  activeSpeakerEvents: [
    {
      display_name: "Maria Silva",
      participant_id: "pid-2",
      start_epoch_millis: 1781135990000,
      end_epoch_millis: 1781135995500,
    },
  ],
  expectedMeetStartNotifications: 1,
};

writeFileSync(
  join(FIXTURES, "wire_batch_lifecycle_golden.json"),
  JSON.stringify(wire, null, 2) + "\n",
);
writeFileSync(
  join(FIXTURES, "expected_lifecycle.json"),
  JSON.stringify(expected, null, 2) + "\n",
);
console.log("lifecycle golden fixtures written to", FIXTURES);
