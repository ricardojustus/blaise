// @vitest-environment node
// DeliveryManager: ring buffer, status contract, signed-ack gating
// (mocked fetch; real WebCrypto).
import { describe, it, expect, vi } from "vitest";
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

const event = (n, pid = "pid-2") => ({
  displayName: "Maria Silva",
  participantID: pid,
  isSelf: false,
  startEpochMillis: n * 10000,
  endEpochMillis: n * 10000 + 2000,
});

const batchOf = (...events) => ({
  meetingCode: "abc-defg-hij",
  roster: [{ displayName: "Maria Silva", participantID: "pid-2", isSelf: false }],
  events,
});

/** A mock app: decrypts (or not), responds with a chosen status, signs the
 * ack correctly / wrongly / not at all. Captures wires for assertions. */
function mockApp({ status = 200, sign = "valid" } = {}) {
  const wires = [];
  const envelopes = [];
  const fetchFn = async (url, init) => {
    const envelope = JSON.parse(init.body);
    envelopes.push(envelope);
    wires.push(await BC.decryptBatch(SECRET, envelope));
    let ack = null;
    if (sign === "valid") ack = await BC.computeAck(SECRET, envelope.iv, status);
    else if (sign === "wrong") ack = await BC.computeAck("squatter-secret", envelope.iv, status);
    return {
      status,
      headers: { get: (h) => (h === "X-Blaise-Ack" ? ack : null) },
    };
  };
  return { fetchFn, wires, envelopes };
}

function makeManager({ fetchFn, storage, onBadge = () => {}, ringCap, now = () => 1_780_000_000_000 }) {
  return new E.DeliveryManager({
    storage,
    fetchFn,
    cryptoApi: BC,
    endpoint: ENDPOINT,
    now,
    onBadge,
    ...(ringCap ? { ringCap } : {}),
  });
}

describe("happy path: valid signed 200", () => {
  it("delivers, stamps schema/counters, resets counters, records the ack", async () => {
    const storage = memoryStorage({ blaiseSecret: SECRET });
    const app = mockApp({ status: 200 });
    const badge = vi.fn();
    const m = makeManager({ fetchFn: app.fetchFn, storage, onBadge: badge });
    await m.enqueue(batchOf(event(1)));
    expect(app.wires).toHaveLength(1);
    expect(app.wires[0]).toMatchObject({
      meetingCode: "abc-defg-hij",
      schemaVersion: 2,
      droppedCount: 0,
      poisonedCount: 0,
      capturedAtMs: 1_780_000_000_000,
    });
    expect(app.wires[0].events).toHaveLength(1);
    expect(await m.bufferedEventCount()).toBe(0);
    expect(badge).toHaveBeenCalledWith("ok");
    expect(await m.lastAckAgeMs()).toBe(0);
  });
});

describe("signed-ack gating (a squatter can fabricate codes, not signatures)", () => {
  it("UNSIGNED 200 is network-class: the batch stays buffered", async () => {
    const storage = memoryStorage({ blaiseSecret: SECRET });
    const app = mockApp({ status: 200, sign: "none" });
    const m = makeManager({ fetchFn: app.fetchFn, storage });
    await m.enqueue(batchOf(event(1)));
    expect(await m.bufferedEventCount()).toBe(1);
  });

  it("forged-signature 200 is network-class too", async () => {
    const storage = memoryStorage({ blaiseSecret: SECRET });
    const app = mockApp({ status: 200, sign: "wrong" });
    const m = makeManager({ fetchFn: app.fetchFn, storage });
    await m.enqueue(batchOf(event(1)));
    expect(await m.bufferedEventCount()).toBe(1);
  });

  it("UNSIGNED 400 does NOT poison-drop (only a signed 400 may)", async () => {
    const storage = memoryStorage({ blaiseSecret: SECRET });
    const app = mockApp({ status: 400, sign: "none" });
    const m = makeManager({ fetchFn: app.fetchFn, storage });
    await m.enqueue(batchOf(event(1)));
    expect(await m.bufferedEventCount()).toBe(1);
  });
});

describe("status contract", () => {
  it("signed 400 → drop batch, poisonedCount rides the NEXT delivered batch", async () => {
    const storage = memoryStorage({ blaiseSecret: SECRET });
    const dyn = {
      fetchFn: async (url, init) => {
        const envelope = JSON.parse(init.body);
        dyn.wires.push(await BC.decryptBatch(SECRET, envelope));
        const ack = await BC.computeAck(SECRET, envelope.iv, dyn.status);
        return { status: dyn.status, headers: { get: () => ack } };
      },
      wires: [],
      status: 400,
    };
    const m = makeManager({ fetchFn: dyn.fetchFn, storage });
    await m.enqueue(batchOf(event(1), event(2))); // poisoned (2 events)
    expect(await m.bufferedEventCount()).toBe(0); // dropped, not retried
    dyn.status = 200;
    await m.enqueue(batchOf(event(3)));
    const delivered = dyn.wires.at(-1);
    expect(delivered.poisonedCount).toBe(2);
    expect(delivered.droppedCount).toBe(0);
  });

  it("signed 401 ×3 → 'check secret' badge; batches keep buffering", async () => {
    const storage = memoryStorage({ blaiseSecret: SECRET });
    const app = mockApp({ status: 401, sign: "valid" });
    const badge = vi.fn();
    const m = makeManager({ fetchFn: app.fetchFn, storage, onBadge: badge });
    await m.enqueue(batchOf(event(1)));
    await m.flush();
    expect(badge).not.toHaveBeenCalledWith("check-secret");
    await m.flush(); // third consecutive 401
    expect(badge).toHaveBeenCalledWith("check-secret");
    expect(await m.bufferedEventCount()).toBe(1); // still buffered
  });

  it("signed 5xx → ring retry", async () => {
    const storage = memoryStorage({ blaiseSecret: SECRET });
    const app = mockApp({ status: 503, sign: "valid" });
    const m = makeManager({ fetchFn: app.fetchFn, storage });
    await m.enqueue(batchOf(event(1)));
    expect(await m.bufferedEventCount()).toBe(1);
  });

  it("network failure → ring retry, then a later flush delivers FIFO", async () => {
    const storage = memoryStorage({ blaiseSecret: SECRET });
    const ctl = { fail: true, wires: [] };
    const fetchFn = async (url, init) => {
      if (ctl.fail) throw new TypeError("connection refused");
      const envelope = JSON.parse(init.body);
      ctl.wires.push(await BC.decryptBatch(SECRET, envelope));
      const ack = await BC.computeAck(SECRET, envelope.iv, 200);
      return { status: 200, headers: { get: () => ack } };
    };
    const m = makeManager({ fetchFn, storage });
    await m.enqueue(batchOf(event(1)));
    await m.enqueue(batchOf(event(2)));
    expect(await m.bufferedEventCount()).toBe(2);
    ctl.fail = false;
    await m.flush();
    expect(await m.bufferedEventCount()).toBe(0);
    expect(ctl.wires.map((w) => w.events[0].startEpochMillis)).toEqual([10000, 20000]); // FIFO order
  });

  it("no secret configured → buffer silently, no fetch", async () => {
    const storage = memoryStorage(); // no blaiseSecret
    const fetchFn = vi.fn();
    const badge = vi.fn();
    const m = makeManager({ fetchFn, storage, onBadge: badge });
    await m.enqueue(batchOf(event(1)));
    expect(fetchFn).not.toHaveBeenCalled();
    expect(await m.bufferedEventCount()).toBe(1);
    expect(badge).toHaveBeenCalledWith("buffering");
  });
});

describe("retry re-encryption", () => {
  it("a retried batch gets a FRESH IV (never reused)", async () => {
    const storage = memoryStorage({ blaiseSecret: SECRET });
    const app = mockApp({ status: 503, sign: "valid" });
    const m = makeManager({ fetchFn: app.fetchFn, storage });
    await m.enqueue(batchOf(event(1)));
    await m.flush();
    await m.flush();
    expect(app.envelopes.length).toBeGreaterThanOrEqual(3);
    expect(new Set(app.envelopes.map((e) => e.iv)).size).toBe(app.envelopes.length);
  });
});

describe("FIFO ring (10k events)", () => {
  it("pins the capacity constant", () => {
    expect(E.RING_CAP_EVENTS).toBe(10000);
  });

  it("evicts oldest batches beyond the cap; losses ride droppedCount", async () => {
    const storage = memoryStorage({ blaiseSecret: SECRET });
    const ctl = { fail: true, wires: [] };
    const fetchFn = async (url, init) => {
      if (ctl.fail) throw new TypeError("down");
      const envelope = JSON.parse(init.body);
      ctl.wires.push(await BC.decryptBatch(SECRET, envelope));
      const ack = await BC.computeAck(SECRET, envelope.iv, 200);
      return { status: 200, headers: { get: () => ack } };
    };
    const m = makeManager({ fetchFn, storage, ringCap: 5 });
    await m.enqueue(batchOf(event(1), event(2), event(3))); // 3 buffered
    await m.enqueue(batchOf(event(4), event(5), event(6))); // 6 > 5 → evict oldest batch
    expect(await m.bufferedEventCount()).toBe(3);
    ctl.fail = false;
    await m.flush();
    expect(ctl.wires).toHaveLength(1);
    expect(ctl.wires[0].droppedCount).toBe(3); // the evicted batch's events
    expect(ctl.wires[0].events.map((e) => e.startEpochMillis)).toEqual([40000, 50000, 60000]);
  });

  it("a single oversized batch truncates its OLDEST events", async () => {
    const storage = memoryStorage({ blaiseSecret: SECRET });
    const ctl = { fail: true, wires: [] };
    const fetchFn = async (url, init) => {
      if (ctl.fail) throw new TypeError("down");
      const envelope = JSON.parse(init.body);
      ctl.wires.push(await BC.decryptBatch(SECRET, envelope));
      const ack = await BC.computeAck(SECRET, envelope.iv, 200);
      return { status: 200, headers: { get: () => ack } };
    };
    const m = makeManager({ fetchFn, storage, ringCap: 2 });
    await m.enqueue(batchOf(event(1), event(2), event(3), event(4)));
    expect(await m.bufferedEventCount()).toBe(2);
    ctl.fail = false;
    await m.flush();
    expect(ctl.wires[0].droppedCount).toBe(2);
    expect(ctl.wires[0].events.map((e) => e.startEpochMillis)).toEqual([30000, 40000]);
  });

  it("ring state survives a manager restart (storage-backed)", async () => {
    const storage = memoryStorage({ blaiseSecret: SECRET });
    const failing = makeManager({ fetchFn: async () => { throw new TypeError("down"); }, storage });
    await failing.enqueue(batchOf(event(1)));
    // "service worker death": a brand-new manager over the same storage
    const app = mockApp({ status: 200 });
    const revived = makeManager({ fetchFn: app.fetchFn, storage });
    await revived.flush();
    expect(app.wires).toHaveLength(1);
    expect(await revived.bufferedEventCount()).toBe(0);
  });
});

/** Fetch whose FIRST call is held open until release(); later calls answer
 * immediately. All calls return a validly signed `status`. */
function gatedApp({ status = 200 } = {}) {
  let release;
  const gate = new Promise((r) => (release = r));
  const wires = [];
  let calls = 0;
  const fetchFn = async (url, init) => {
    const n = ++calls;
    if (n === 1) await gate;
    const envelope = JSON.parse(init.body);
    wires.push(await BC.decryptBatch(SECRET, envelope));
    const ack = await BC.computeAck(SECRET, envelope.iv, status);
    return { status, headers: { get: () => ack } };
  };
  return { fetchFn, wires, release: () => release(), calls: () => calls };
}

const untilFirstPost = async (app) => {
  while (app.calls() < 1) await new Promise((r) => setTimeout(r, 1));
};

describe("cold-start concurrency (H-1)", () => {
  it("two concurrent enqueues on a COLD manager both persist (single shared state load)", async () => {
    const storage = memoryStorage({ blaiseSecret: SECRET });
    const m = makeManager({
      fetchFn: async () => { throw new TypeError("down"); },
      storage,
    });
    await Promise.all([m.enqueue(batchOf(event(1))), m.enqueue(batchOf(event(2)))]);
    expect(await m.bufferedEventCount()).toBe(2);
    expect(storage._store.get(E.STORAGE_KEY).pending).toHaveLength(2);
  });

  it("serializes storage writes so a delayed older snapshot cannot erase a newer batch", async () => {
    let releaseFirst;
    let setCalls = 0;
    let persisted;
    const storage = {
      async get() { return undefined; }, // no secret: persist, then remain buffered
      async set(obj) {
        const snapshot = JSON.parse(JSON.stringify(obj[E.STORAGE_KEY]));
        setCalls += 1;
        if (setCalls === 1) {
          await new Promise((resolve) => {
            releaseFirst = () => {
              persisted = snapshot;
              resolve();
            };
          });
          return;
        }
        persisted = snapshot;
      },
    };
    const m = makeManager({ fetchFn: async () => { throw new TypeError("unused"); }, storage });

    const first = m.enqueue(batchOf(event(1)));
    while (setCalls < 1) await new Promise((resolve) => setTimeout(resolve, 1));
    const second = m.enqueue(batchOf(event(2)));

    // The second snapshot is queued behind the held first write, not racing it.
    await new Promise((resolve) => setTimeout(resolve, 5));
    expect(setCalls).toBe(1);
    releaseFirst();
    await Promise.all([first, second]);

    expect(setCalls).toBe(2);
    expect(persisted.pending).toHaveLength(2);
    expect(await m.bufferedEventCount()).toBe(2);
  });
});

describe("runtime message lifetime", () => {
  it("keeps the channel open and acknowledges only after enqueue settles", async () => {
    let settle;
    const manager = {
      enqueue: vi.fn(() => new Promise((resolve) => { settle = resolve; })),
    };
    const responses = [];
    const handler = E.createRuntimeMessageHandler(manager, vi.fn());

    const keepAlive = handler(
      { type: "blaiseBatch", batch: batchOf(event(1)), volatile: false },
      {},
      (response) => responses.push(response),
    );

    expect(keepAlive).toBe(true);
    expect(responses).toEqual([]);
    settle();
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(responses).toEqual([{ accepted: true }]);
  });

  it("reports a rejected durable acceptance to the content script", async () => {
    const manager = {
      enqueue: vi.fn(() => Promise.reject(new Error("storage failed"))),
    };
    const logError = vi.fn();
    const responses = [];
    const handler = E.createRuntimeMessageHandler(manager, logError);

    expect(handler(
      { type: "blaiseBatch", batch: batchOf(event(1)), volatile: false },
      {},
      (response) => responses.push(response),
    )).toBe(true);
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(responses).toEqual([{ accepted: false }]);
    expect(logError).toHaveBeenCalledOnce();
  });

  it("ignores unrelated runtime messages synchronously", () => {
    const manager = { enqueue: vi.fn() };
    const handler = E.createRuntimeMessageHandler(manager, vi.fn());
    expect(handler({ type: "other" }, {}, vi.fn())).toBe(false);
    expect(manager.enqueue).not.toHaveBeenCalled();
  });
});

describe("ring eviction vs in-flight POST (H-2)", () => {
  it("never evicts the in-flight batch; its 200 removes IT, not whatever sits at index 0", async () => {
    // Audit probe shape: ringCap 2, first POST held in flight, second batch
    // enqueued (would overflow), POST released with a valid signed 200.
    const storage = memoryStorage({ blaiseSecret: SECRET });
    const app = gatedApp({ status: 200 });
    const m = makeManager({ fetchFn: app.fetchFn, storage, ringCap: 2 });
    const p1 = m.enqueue(batchOf(event(1), event(2))); // POST held in flight
    await untilFirstPost(app);
    await m.enqueue(batchOf(event(3), event(4))); // overflow while in flight
    app.release();
    await p1; // flush loop drains everything
    // Both batches ride the wire exactly once; nothing silently lost.
    expect(app.wires).toHaveLength(2);
    expect(app.wires[0].events.map((e) => e.startEpochMillis)).toEqual([10000, 20000]);
    expect(app.wires[1].events.map((e) => e.startEpochMillis)).toEqual([30000, 40000]);
    expect(app.wires.map((w) => w.droppedCount)).toEqual([0, 0]);
    expect(await m.bufferedEventCount()).toBe(0);
  });

  it("eviction during an in-flight POST is not erased by that POST's 200 (only carried counts clear)", async () => {
    const storage = memoryStorage({ blaiseSecret: SECRET });
    const app = gatedApp({ status: 200 });
    const m = makeManager({ fetchFn: app.fetchFn, storage, ringCap: 4 });
    const p1 = m.enqueue(batchOf(event(1), event(2))); // POST held in flight
    await untilFirstPost(app);
    await m.enqueue(batchOf(event(3), event(4))); // 4 events: at cap
    await m.enqueue(batchOf(event(5), event(6))); // evicts batch 2 → droppedCount 2
    app.release();
    await p1;
    // Batch 1 carried droppedCount 0 (stamped before the eviction); its 200
    // must NOT zero the 2 dropped events, which ride the next wire.
    expect(app.wires).toHaveLength(2);
    expect(app.wires[0].events.map((e) => e.startEpochMillis)).toEqual([10000, 20000]);
    expect(app.wires[0].droppedCount).toBe(0);
    expect(app.wires[1].events.map((e) => e.startEpochMillis)).toEqual([50000, 60000]);
    expect(app.wires[1].droppedCount).toBe(2); // the evicted batch's events
    expect(storage._store.get(E.STORAGE_KEY).droppedCount).toBe(0); // cleared by the wire that carried it
  });
});

describe("batch-count cap and storage-write failures (M-1)", () => {
  it("zero-event (roster-only) batches are bounded by the 200-batch cap", async () => {
    const storage = memoryStorage({ blaiseSecret: SECRET });
    const m = makeManager({
      fetchFn: async () => { throw new TypeError("down"); },
      storage,
    });
    for (let i = 0; i < 210; i += 1) {
      await m.enqueue({ meetingCode: "abc-defg-hij", roster: [], events: [] });
    }
    expect(E.RING_CAP_BATCHES).toBe(200);
    expect(storage._store.get(E.STORAGE_KEY).pending).toHaveLength(200);
  });

  it("a storage write failure rejects durable acceptance and surfaces badge + counter", async () => {
    const failingStorage = {
      async get(key) {
        return key === "blaiseSecret" ? SECRET : undefined;
      },
      async set() {
        throw new Error("QUOTA_BYTES quota exceeded");
      },
    };
    const badge = vi.fn();
    const app = mockApp({ status: 503, sign: "valid" }); // batch stays buffered
    const m = makeManager({ fetchFn: app.fetchFn, storage: failingStorage, onBadge: badge });
    let acceptanceError;
    try {
      await m.enqueue(batchOf(event(1)));
    } catch (error) {
      acceptanceError = error;
    }
    expect(acceptanceError?.message).toBe("Blaise: could not persist Meet batch");
    expect(badge).toHaveBeenCalledWith("storage-error");
    expect(m.persistFailures).toBeGreaterThanOrEqual(1);
    expect(await m.bufferedEventCount()).toBe(1); // still usable in memory
  });

  it("a storage failure still makes a best-effort direct delivery while reporting non-durable acceptance", async () => {
    const failingStorage = {
      async get(key) {
        return key === "blaiseSecret" ? SECRET : undefined;
      },
      async set() {
        throw new Error("transient storage failure");
      },
    };
    const app = mockApp({ status: 200, sign: "valid" });
    const m = makeManager({ fetchFn: app.fetchFn, storage: failingStorage });

    let acceptanceError;
    try {
      await m.enqueue(batchOf(event(1)));
    } catch (error) {
      acceptanceError = error;
    }

    expect(acceptanceError?.message).toBe("Blaise: could not persist Meet batch");
    expect(app.wires).toHaveLength(1);
    expect(await m.bufferedEventCount()).toBe(0);
  });
});

describe("buffering badge on network-failure streaks (M-2)", () => {
  it("3 consecutive network-class failures show the buffering badge", async () => {
    const storage = memoryStorage({ blaiseSecret: SECRET });
    const badge = vi.fn();
    const m = makeManager({
      fetchFn: async () => { throw new TypeError("connection refused"); },
      storage,
      onBadge: badge,
    });
    await m.enqueue(batchOf(event(1))); // failure 1
    await m.flush(); // failure 2
    expect(badge).not.toHaveBeenCalledWith("buffering");
    await m.flush(); // failure 3
    expect(badge).toHaveBeenCalledWith("buffering");
  });

  it("unsigned responses count toward the streak; any validly signed ack resets it", async () => {
    const storage = memoryStorage({ blaiseSecret: SECRET });
    const badge = vi.fn();
    const ctl = { sign: "none", status: 503 };
    const fetchFn = async (url, init) => {
      const envelope = JSON.parse(init.body);
      const ack =
        ctl.sign === "valid" ? await BC.computeAck(SECRET, envelope.iv, ctl.status) : null;
      return { status: ctl.status, headers: { get: () => ack } };
    };
    const m = makeManager({ fetchFn, storage, onBadge: badge });
    await m.enqueue(batchOf(event(1))); // unsigned → streak 1
    await m.flush(); // unsigned → streak 2
    ctl.sign = "valid";
    await m.flush(); // signed 503: app reachable → streak resets
    ctl.sign = "none";
    await m.flush(); // streak 1
    await m.flush(); // streak 2
    expect(badge).not.toHaveBeenCalledWith("buffering");
    await m.flush(); // streak 3
    expect(badge).toHaveBeenCalledWith("buffering");
  });
});

describe("fetch timeout (FIELD bug 2026-06-11: a listener that accepts and never answers)", () => {
  // The live failure: a wedged/squatted port holder accepted the TCP
  // connection and never responded. Without a timeout the un-settled fetch
  // froze `flushing` and every counter for the worker's whole lifetime —
  // pending grew with lastAckMs null and zero 401/net-fail movement.
  it("aborts a never-resolving fetch via the timeout signal and classifies it network-class", async () => {
    const storage = memoryStorage({ blaiseSecret: SECRET });
    const hangingFetch = (url, init) =>
      new Promise((_, reject) => {
        expect(init.signal).toBeInstanceOf(AbortSignal);
        // A real fetch rejects with the signal's reason on abort; without
        // the signal this promise would never settle (the old behavior).
        init.signal.addEventListener("abort", () => reject(init.signal.reason));
      });
    const m = new E.DeliveryManager({
      storage,
      fetchFn: hangingFetch,
      cryptoApi: BC,
      endpoint: ENDPOINT,
      now: () => 1_780_000_000_000,
      onBadge: () => {},
      fetchTimeoutMs: 20,
    });
    await m.enqueue(batchOf(event(1)));
    const state = storage._store.get(E.STORAGE_KEY);
    expect(state.consecutiveNetFail).toBe(1); // counters MOVE — no silent wedge
    expect(state.pending).toHaveLength(1); // batch retained for ring retry
    expect(state.lastAckMs).toBeNull();
  });

  it("passes an abort signal on every delivery attempt (incl. volatile)", async () => {
    const storage = memoryStorage({ blaiseSecret: SECRET });
    const seen = [];
    const fetchFn = async (url, init) => {
      seen.push(init.signal);
      const envelope = JSON.parse(init.body);
      const ack = await BC.computeAck(SECRET, envelope.iv, 200);
      return { status: 200, headers: { get: (h) => (h === "X-Blaise-Ack" ? ack : null) } };
    };
    const m = makeManager({ fetchFn, storage });
    await m.enqueue(batchOf(event(1)));
    await m.enqueue({ ...batchOf(), lifecycle: { kind: "heartbeat", atMs: 1 } }, { volatile: true });
    expect(seen).toHaveLength(2);
    for (const s of seen) expect(s).toBeInstanceOf(AbortSignal);
  });
});

describe("dedupe id (contract-pinned)", () => {
  it("uses meetingCode:participantID-or-displayName-or-self:startMs:endMs", () => {
    expect(E.dedupeID("abc-defg-hij", event(1))).toBe("abc-defg-hij:pid-2:10000:12000");
    expect(
      E.dedupeID("abc-defg-hij", {
        displayName: "Maria Silva",
        isSelf: false,
        startEpochMillis: 1,
        endEpochMillis: 2,
      }),
    ).toBe("abc-defg-hij:Maria Silva:1:2");
    expect(
      E.dedupeID("abc-defg-hij", {
        displayName: null,
        isSelf: true,
        startEpochMillis: 1,
        endEpochMillis: 2,
      }),
    ).toBe("abc-defg-hij:self:1:2");
  });
});
