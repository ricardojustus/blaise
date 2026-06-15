// Speaking state machine: mutation-driven via jsdom's MutationObserver,
// epoch-stubbed, per-participant coalescing (merge ≤ 3000 ms, drop < 500 ms),
// muted-visibility filter, ≤10 Hz processing, body-sentinel watchdog.
import { describe, it, expect, beforeEach } from "vitest";
import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import O from "../src/observer.js";
import E from "../src/events.js";

const FIXTURES = join(dirname(fileURLToPath(import.meta.url)), "fixtures");

const microtask = () => new Promise((r) => setTimeout(r, 0));

function harness({ display = "block" } = {}) {
  document.body.innerHTML = readFileSync(join(FIXTURES, "meet_in_call.html"), "utf8");
  const selfModel = new O.SelfModel();
  O.extractRoster(document, selfModel); // learn self pid-1
  const coalescer = new E.Coalescer();
  let nowMs = 1_000_000;
  const scheduled = [];
  const obs = O.createSpeakingObserver({
    doc: document,
    coalescer,
    selfModel,
    now: () => nowMs,
    getStyle: (el) => ({ display: el.dataset.testHidden ? "none" : display }),
    schedule: (fn) => scheduled.push(fn),
  });
  obs.attach();
  const runScheduled = () => {
    while (scheduled.length) scheduled.shift()();
  };
  return {
    obs,
    coalescer,
    setNow: (t) => (nowMs = t),
    runScheduled,
    bar: (pid) =>
      document.querySelector(`[data-requested-participant-id="${pid}"] .bar`),
  };
}

describe("mutation-driven ticks", () => {
  let h;
  beforeEach(() => {
    h = harness();
  });

  it("class mutations inside a tile become a coalesced utterance with stubbed epochs", async () => {
    for (const [cls, t] of [["a", 1000], ["b", 2000], ["c", 3000]]) {
      h.setNow(t);
      h.bar("pid-2").className = `bar ${cls}`;
      await microtask();
      h.runScheduled();
    }
    h.coalescer.sweep(10000);
    const events = h.coalescer.drain();
    expect(events).toEqual([
      {
        displayName: "Maria Silva",
        participantID: "pid-2",
        isSelf: false,
        startEpochMillis: 1000,
        endEpochMillis: 3000,
      },
    ]);
  });

  it("self-tile mutations attribute to self with null displayName", async () => {
    h.setNow(5000);
    h.bar("pid-1").className = "bar talking";
    await microtask();
    h.runScheduled();
    h.setNow(6000);
    h.bar("pid-1").className = "bar talking2";
    await microtask();
    h.runScheduled();
    h.coalescer.closeAll();
    expect(h.coalescer.drain()).toEqual([
      {
        displayName: null,
        participantID: "pid-1",
        isSelf: true,
        startEpochMillis: 5000,
        endEpochMillis: 6000,
      },
    ]);
  });

  it("per-participant independence: interleaved speakers do not merge", async () => {
    const seq = [
      ["pid-2", 1000],
      ["pid-3", 1500],
      ["pid-2", 2000],
      ["pid-3", 2500],
    ];
    let i = 0;
    for (const [pid, t] of seq) {
      h.setNow(t);
      h.bar(pid).className = `bar s${i++}`;
      await microtask();
      h.runScheduled();
    }
    h.coalescer.closeAll();
    const events = h.coalescer.drain();
    expect(events).toHaveLength(2);
    expect(events.find((e) => e.participantID === "pid-2")).toMatchObject({
      startEpochMillis: 1000,
      endEpochMillis: 2000,
    });
    expect(events.find((e) => e.participantID === "pid-3")).toMatchObject({
      startEpochMillis: 1500,
      endEpochMillis: 2500,
    });
  });

  it("hidden indicators (muted) produce no ticks", async () => {
    const bar = h.bar("pid-3");
    bar.dataset.testHidden = "1";
    h.setNow(1000);
    bar.className = "bar hidden-talk";
    await microtask();
    h.runScheduled();
    h.coalescer.closeAll();
    expect(h.coalescer.drain()).toEqual([]);
  });

  it("mutations outside any participant scope are ignored", async () => {
    h.setNow(1000);
    document.querySelector(".ctrl-bar").className = "ctrl-bar moved";
    await microtask();
    h.runScheduled();
    h.coalescer.closeAll();
    expect(h.coalescer.drain()).toEqual([]);
  });

  it("panel-row mutations (panel speaking indicators) also tick", async () => {
    h.setNow(1000);
    const row = document.querySelector('[data-participant-id="pid-4"]');
    row.querySelector("span").className = "speaking";
    await microtask();
    h.runScheduled();
    h.setNow(2500);
    row.querySelector("span").className = "speaking2";
    await microtask();
    h.runScheduled();
    h.coalescer.closeAll();
    expect(h.coalescer.drain()).toEqual([
      {
        displayName: "Participante Um",
        participantID: "pid-4",
        isSelf: false,
        startEpochMillis: 1000,
        endEpochMillis: 2500,
      },
    ]);
  });

  it("processes mutation bursts through ONE scheduled pass (≤10 Hz shape)", async () => {
    h.setNow(1000);
    // a burst of 20 mutations before any processing runs
    for (let i = 0; i < 20; i++) h.bar("pid-2").className = `bar burst${i}`;
    await microtask();
    // the observer coalesces the burst into one pending set / one schedule
    h.runScheduled();
    h.coalescer.closeAll();
    expect(h.coalescer.drain()).toEqual([]); // single tick = zero-length → dropped
  });

  it("watchdog re-attaches when document.body is replaced (sentinel)", async () => {
    expect(h.obs.watchdog()).toBe(false); // body intact → no-op
    const html = document.body.innerHTML;
    const newBody = document.createElement("body");
    newBody.innerHTML = html;
    document.documentElement.replaceChild(newBody, document.body);
    expect(h.obs.watchdog()).toBe(true); // detected replacement, re-attached
    h.setNow(1000);
    h.bar("pid-2").className = "bar after-replace";
    await microtask();
    h.runScheduled();
    h.setNow(2000);
    h.bar("pid-2").className = "bar after-replace2";
    await microtask();
    h.runScheduled();
    h.coalescer.closeAll();
    expect(h.coalescer.drain()).toHaveLength(1);
  });
});

describe("coalescing constants and rules (epoch-stubbed, direct)", () => {
  it("pins the spec constants", () => {
    expect(E.MERGE_GAP_MS).toBe(3000);
    expect(E.MIN_UTTERANCE_MS).toBe(500);
    expect(E.PROCESS_INTERVAL_MS).toBe(100); // 10 Hz
  });

  const maria = { displayName: "Maria Silva", participantID: "pid-2", isSelf: false };

  it("merges ticks with gaps ≤ 3000 ms", () => {
    const c = new E.Coalescer();
    c.tick(maria, 0);
    c.tick(maria, 3000); // exactly the gap → merges
    c.tick(maria, 5000);
    c.sweep(99999);
    expect(c.drain()).toMatchObject([{ startEpochMillis: 0, endEpochMillis: 5000 }]);
  });

  it("a gap > 3000 ms splits utterances", () => {
    const c = new E.Coalescer();
    c.tick(maria, 0);
    c.tick(maria, 1000);
    c.tick(maria, 4001); // 3001 ms after the last tick → split
    c.tick(maria, 5000);
    c.closeAll();
    const events = c.drain();
    expect(events).toHaveLength(2);
    expect(events[0]).toMatchObject({ startEpochMillis: 0, endEpochMillis: 1000 });
    expect(events[1]).toMatchObject({ startEpochMillis: 4001, endEpochMillis: 5000 });
  });

  it("drops utterances < 500 ms", () => {
    const c = new E.Coalescer();
    c.tick(maria, 0);
    c.tick(maria, 499);
    c.closeAll();
    expect(c.drain()).toEqual([]);
  });

  it("keeps utterances of exactly 500 ms", () => {
    const c = new E.Coalescer();
    c.tick(maria, 0);
    c.tick(maria, 500);
    c.closeAll();
    expect(c.drain()).toMatchObject([{ startEpochMillis: 0, endEpochMillis: 500 }]);
  });

  it("sweep only closes utterances whose last tick is stale", () => {
    const c = new E.Coalescer();
    c.tick(maria, 0);
    c.tick({ displayName: "João Pereira", participantID: "pid-3", isSelf: false }, 4000);
    c.sweep(5000); // maria stale (5000-0 > 3000), joão fresh
    const closed = c.drain();
    expect(closed).toEqual([]); // maria's span 0..0 → dropped as < 500ms
    c.closeAll();
    expect(c.drain()).toEqual([]); // joão single tick → dropped too
  });
});
