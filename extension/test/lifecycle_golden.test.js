// @vitest-environment node
// C14 cross-chunk golden pin: wire_batch_lifecycle_golden.json must decrypt
// to a schema-v2 batch whose lifecycle/events/roster match
// expected_lifecycle.json — the Swift acceptance consumes the SAME pair;
// this test keeps it self-consistent (same pattern as golden.test.js).
import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import BC from "../src/crypto.js";
import E from "../src/events.js";

const FIXTURES = join(dirname(fileURLToPath(import.meta.url)), "fixtures");
const wire = JSON.parse(
  readFileSync(join(FIXTURES, "wire_batch_lifecycle_golden.json"), "utf8"),
);
const expected = JSON.parse(readFileSync(join(FIXTURES, "expected_lifecycle.json"), "utf8"));

describe("wire_batch_lifecycle_golden.json", () => {
  it("pins the transport constants and the replay delivery", () => {
    expect(wire.endpoint).toBe("POST /v1/meet-events");
    expect(wire.aad).toBe("blaise-meet-events-v1");
    expect(wire.ackHeader).toBe("X-Blaise-Ack");
    expect(wire.deliveries).toHaveLength(2);
    expect(wire.deliveries[1]).toEqual(wire.deliveries[0]); // byte-identical replay
  });

  it("decrypts to a v2 batch matching the expected lifecycle/event outcomes", async () => {
    const batch = await BC.decryptBatch(wire.testSecret, wire.deliveries[0]);
    expect(batch.schemaVersion).toBe(2);
    expect(batch.meetingCode).toBe(expected.meetingCode);
    expect(batch.capturedAtMs).toBe(expected.capturedAtMs);
    expect(batch.lifecycle).toEqual(expected.lifecycle);
    // The replayed second delivery must dedupe to ONE ingested event.
    const seen = new Set();
    const events = [];
    for (const envelope of wire.deliveries) {
      const decrypted = await BC.decryptBatch(wire.testSecret, envelope);
      for (const event of decrypted.events) {
        const id = E.dedupeID(decrypted.meetingCode, event);
        if (seen.has(id)) continue;
        seen.add(id);
        events.push({
          display_name: event.isSelf ? expected.selfSubstitutionName : event.displayName,
          ...(event.participantID ? { participant_id: event.participantID } : {}),
          start_epoch_millis: event.startEpochMillis,
          end_epoch_millis: event.endEpochMillis,
        });
      }
    }
    expect(events).toEqual(expected.activeSpeakerEvents);
  });
});
