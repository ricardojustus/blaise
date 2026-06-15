// @vitest-environment node
// Cross-chunk golden contract test. Decrypts test/fixtures/
// wire_batch_golden.json exactly as the C10/C11 listener must, applies the
// listener obligations from docs/meet_events_contract.md (isSelf
// substitution, replay dedupe by per-meeting seen-id set), and asserts the
// result equals expected_ingestion.json. The Swift listener's acceptance
// consumes the SAME two files; this test keeps the pair self-consistent.
import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import BC from "../src/crypto.js";
import E from "../src/events.js";

const FIXTURES = join(dirname(fileURLToPath(import.meta.url)), "fixtures");
const wire = JSON.parse(readFileSync(join(FIXTURES, "wire_batch_golden.json"), "utf8"));
const expected = JSON.parse(readFileSync(join(FIXTURES, "expected_ingestion.json"), "utf8"));

/** Reference listener ingestion (contract rules, JS mirror). */
async function ingest(deliveries, secret, selfName) {
  const seen = new Set(); // per-meeting seen-id set
  const events = [];
  for (const envelope of deliveries) {
    const batch = await BC.decryptBatch(secret, envelope);
    expect(batch.schemaVersion).toBe(1);
    for (const event of batch.events) {
      const id = E.dedupeID(batch.meetingCode, event);
      if (seen.has(id)) continue; // replayed duplicate ingests once
      seen.add(id);
      // isSelf substitution: displayName is null on the wire BY DESIGN —
      // the consumer MUST substitute the account name (no fallback exists).
      const display = event.isSelf ? selfName : event.displayName;
      events.push({
        display_name: display,
        ...(event.participantID ? { participant_id: event.participantID } : {}),
        start_epoch_millis: event.startEpochMillis,
        end_epoch_millis: event.endEpochMillis,
      });
    }
  }
  return events;
}

describe("wire_batch_golden.json", () => {
  it("pins the transport constants", () => {
    expect(wire.endpoint).toBe("POST /v1/meet-events");
    expect(wire.aad).toBe("blaise-meet-events-v1");
    expect(wire.ackHeader).toBe("X-Blaise-Ack");
    expect(wire.testSecret).toMatch(/^[0-9a-f]{64}$/);
  });

  it("contains a byte-identical replayed delivery (the replay case)", () => {
    expect(wire.deliveries).toHaveLength(2);
    expect(wire.deliveries[1]).toEqual(wire.deliveries[0]);
  });

  it("decrypts with the test secret and carries the schema", async () => {
    const batch = await BC.decryptBatch(wire.testSecret, wire.deliveries[0]);
    expect(batch).toMatchObject({
      meetingCode: "abc-defg-hij",
      schemaVersion: 1,
      droppedCount: 0,
      poisonedCount: 0,
    });
    expect(typeof batch.capturedAtMs).toBe("number");
    expect(batch.roster.length).toBeGreaterThan(0);
    expect(batch.events.length).toBeGreaterThan(0);
  });

  it("the wire batch never carries a self displayName (null by design)", async () => {
    const batch = await BC.decryptBatch(wire.testSecret, wire.deliveries[0]);
    for (const entry of [...batch.roster, ...batch.events]) {
      if (entry.isSelf) expect(entry.displayName).toBeNull();
      // and no localized self label travels as a name, ever
      expect(["You", "Você", "you", "você"]).not.toContain(entry.displayName);
    }
  });

  it("includes an isSelf event (the substitution case)", async () => {
    const batch = await BC.decryptBatch(wire.testSecret, wire.deliveries[0]);
    expect(batch.events.some((e) => e.isSelf)).toBe(true);
  });
});

describe("expected_ingestion.json (listener obligations applied)", () => {
  it("reference ingestion of BOTH deliveries equals the expected events — replay ingests once", async () => {
    const events = await ingest(
      wire.deliveries,
      wire.testSecret,
      expected.selfSubstitutionName,
    );
    expect(events).toEqual(expected.activeSpeakerEvents);
  });

  it("expected events are in ActiveSpeakerEvent Codable form (snake_case keys, no isSelf on output)", () => {
    for (const e of expected.activeSpeakerEvents) {
      const keys = Object.keys(e).sort();
      expect(keys).toContain("display_name");
      expect(keys).toContain("start_epoch_millis");
      expect(keys).toContain("end_epoch_millis");
      expect(keys).not.toContain("isSelf");
      expect(keys).not.toContain("displayName");
      expect(typeof e.display_name).toBe("string"); // non-null after substitution
    }
    // includes the substituted self event
    expect(
      expected.activeSpeakerEvents.some(
        (e) => e.display_name === expected.selfSubstitutionName,
      ),
    ).toBe(true);
    // includes a no-participant_id event (name-keyed dedupe path)
    expect(expected.activeSpeakerEvents.some((e) => !("participant_id" in e))).toBe(true);
  });

  it("fixture hygiene: no real names, emails, or URLs in the goldens", () => {
    const raw =
      readFileSync(join(FIXTURES, "wire_batch_golden.json"), "utf8") +
      readFileSync(join(FIXTURES, "expected_ingestion.json"), "utf8");
    expect(raw).not.toMatch(/@/);
    expect(raw).not.toMatch(/https?:\/\//);
  });
});
