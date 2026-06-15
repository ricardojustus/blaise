// @vitest-environment node
// C14 lifecycle signals (schema v2): call-started/call-ended emission,
// heartbeat cadence + skip-when-recently-sent (epoch-stubbed), volatile
// heartbeat delivery (never enters the ring on failure), and the v2
// lifecycle round-trip through crypto.js.
import { describe, it, expect, vi } from "vitest";
import C from "../src/content.js";
import E from "../src/events.js";
import BC from "../src/crypto.js";

const SECRET = "11aa22bb33cc44dd55ee66ff77aa88bb99cc00dd11ee22ff33aa44bb55cc66dd";
const ENDPOINT = "http://127.0.0.1:18429/v1/meet-events";

function memoryStorage(initial = {}) {
  const store = new Map(Object.entries(initial));
  return {
    async get(key) {
      return store.get(key);
    },
    async set(obj) {
      for (const [k, v] of Object.entries(obj)) store.set(k, v);
    },
    _store: store,
  };
}

function harness(startEpoch = 1_781_136_000_000) {
  let epoch = startEpoch;
  const sent = [];
  const signals = C.createAutomationSignals({
    now: () => epoch,
    send: (batch, opts) => sent.push({ batch, opts }),
  });
  return { signals, sent, advance: (ms) => (epoch += ms), epoch: () => epoch };
}

describe("createAutomationSignals", () => {
  it("call-started carries the roster + lifecycle with the transition epoch", () => {
    const { signals, sent, epoch } = harness();
    const roster = [{ displayName: "Maria Silva", participantID: "pid-2", isSelf: false }];
    signals.callStarted(roster);
    expect(sent).toHaveLength(1);
    expect(sent[0].batch).toEqual({
      events: [],
      roster,
      lifecycle: { kind: "call-started", atMs: epoch() },
    });
    expect(sent[0].opts.volatile).toBe(false);
  });

  it("call-ended lifecycle rides the final flush with the leave reason", () => {
    const { signals, epoch } = harness();
    expect(signals.callEnded("left")).toEqual({
      kind: "call-ended",
      atMs: epoch(),
      reason: "left",
    });
    expect(signals.callEnded("pagehide").reason).toBe("pagehide");
  });

  it("the glue maps poll-detected leave to 'left' and pagehide to 'pagehide'", () => {
    // The lifecycle machine reports {final}; the content glue maps it:
    // final:false → "left", final:true → "pagehide".
    const onLeave = vi.fn();
    let inCall = true;
    const lc = C.createLifecycle({ isInCall: () => inCall, onJoin: () => {}, onLeave });
    lc.poll(); // already in-call? no — starts idle; arm first
    inCall = true;
    lc.poll();
    inCall = false;
    lc.poll();
    expect(onLeave).toHaveBeenCalledWith({ final: false });
    inCall = true;
    lc.poll();
    lc.pagehide();
    expect(onLeave).toHaveBeenCalledWith({ final: true });
  });

  it("heartbeat fires volatile every 60 s and is SKIPPED when another batch shipped within 60 s", () => {
    const { signals, sent, advance } = harness();
    // A roster batch just shipped.
    signals.noteBatchSent();
    advance(30_000);
    expect(signals.heartbeatTick()).toBe(false); // 30 s since last batch: skip
    expect(sent).toHaveLength(0);
    advance(30_000);
    expect(signals.heartbeatTick()).toBe(true); // 60 s of silence: fire
    expect(sent).toHaveLength(1);
    expect(sent[0].batch.lifecycle.kind).toBe("heartbeat");
    expect(sent[0].batch.events).toEqual([]);
    expect(sent[0].batch.roster).toEqual([]);
    expect(sent[0].opts.volatile).toBe(true);
    // The heartbeat itself counts as a shipped batch (the glue's send path
    // calls noteBatchSent for every batch).
    signals.noteBatchSent();
    advance(10_000);
    expect(signals.heartbeatTick()).toBe(false);
  });

  it("first tick with no batch ever sent fires (lastBatchSentMs null)", () => {
    const { signals, sent } = harness();
    expect(signals.heartbeatTick()).toBe(true);
    expect(sent).toHaveLength(1);
  });
});

describe("DeliveryManager volatile batches", () => {
  function makeManager({ fetchFn, storage, now = () => 1_781_136_000_000 }) {
    return new E.DeliveryManager({
      storage,
      fetchFn,
      cryptoApi: BC,
      endpoint: ENDPOINT,
      now,
      onBadge: () => {},
    });
  }

  const heartbeat = {
    meetingCode: "abc-defg-hij",
    roster: [],
    events: [],
    lifecycle: { kind: "heartbeat", atMs: 1_781_136_000_000 },
  };

  it("volatile heartbeat never enters the ring on fetch failure", async () => {
    const storage = memoryStorage({ blaiseSecret: SECRET });
    const fetchFn = vi.fn(async () => {
      throw new Error("app down");
    });
    const m = makeManager({ fetchFn, storage });
    await m.enqueue(heartbeat, { volatile: true });
    expect(fetchFn).toHaveBeenCalledTimes(1); // exactly one attempt
    expect(await m.bufferedEventCount()).toBe(0);
    const persisted = storage._store.get(E.STORAGE_KEY);
    expect(persisted?.pending ?? []).toHaveLength(0); // never ring-buffered
    // A later flush retries nothing.
    await m.flush();
    expect(fetchFn).toHaveBeenCalledTimes(1);
  });

  it("volatile heartbeat is dropped (not retried) even on a non-200 response", async () => {
    const storage = memoryStorage({ blaiseSecret: SECRET });
    const fetchFn = vi.fn(async () => ({
      status: 500,
      headers: { get: () => null },
    }));
    const m = makeManager({ fetchFn, storage });
    await m.enqueue(heartbeat, { volatile: true });
    await m.flush();
    expect(fetchFn).toHaveBeenCalledTimes(1);
    expect(storage._store.get(E.STORAGE_KEY)?.pending ?? []).toHaveLength(0);
  });

  it("volatile heartbeat POSTs a decryptable v2 batch with lifecycle and current counters", async () => {
    const storage = memoryStorage({
      blaiseSecret: SECRET,
      [E.STORAGE_KEY]: { pending: [], droppedCount: 7, poisonedCount: 2 },
    });
    const wires = [];
    const fetchFn = async (url, init) => {
      const envelope = JSON.parse(init.body);
      wires.push(await BC.decryptBatch(SECRET, envelope));
      return { status: 200, headers: { get: () => null } };
    };
    const m = makeManager({ fetchFn, storage });
    await m.enqueue(heartbeat, { volatile: true });
    expect(wires).toHaveLength(1);
    expect(wires[0].schemaVersion).toBe(2);
    expect(wires[0].lifecycle).toEqual({ kind: "heartbeat", atMs: 1_781_136_000_000 });
    expect(wires[0].droppedCount).toBe(7);
    // Counters are NOT reset by a volatile delivery (the next
    // ring-delivered batch carries and resets them).
    const persisted = storage._store.get(E.STORAGE_KEY);
    expect(persisted.droppedCount).toBe(7);
    expect(persisted.poisonedCount).toBe(2);
  });

  it("missing secret: volatile batch silently dropped, no fetch", async () => {
    const storage = memoryStorage({});
    const fetchFn = vi.fn();
    const m = makeManager({ fetchFn, storage });
    await m.enqueue(heartbeat, { volatile: true });
    expect(fetchFn).not.toHaveBeenCalled();
  });
});

describe("schema v2 round-trip through crypto.js", () => {
  it("a ring batch with a call-ended lifecycle survives encrypt/decrypt byte-exactly", async () => {
    const batch = {
      meetingCode: "abc-defg-hij",
      capturedAtMs: 1_781_136_000_000,
      droppedCount: 0,
      poisonedCount: 0,
      roster: [{ displayName: null, participantID: "pid-1", isSelf: true }],
      events: [
        {
          displayName: "Maria Silva",
          participantID: "pid-2",
          isSelf: false,
          startEpochMillis: 1_781_135_000_000,
          endEpochMillis: 1_781_135_004_500,
        },
      ],
      schemaVersion: 2,
      lifecycle: { kind: "call-ended", atMs: 1_781_136_000_000, reason: "left" },
    };
    const envelope = await BC.encryptBatch(SECRET, batch);
    expect(await BC.decryptBatch(SECRET, envelope)).toEqual(batch);
  });
});
