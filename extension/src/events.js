// events.js — pure event logic: utterance coalescing, dedupe ids, the
// FIFO ring, and the delivery manager (status contract + signed acks).
// No chrome.* here; background.js injects the platform pieces so vitest
// exercises everything in node.

(() => {
  "use strict";

  // Closed-utterance coalescing constants (spec-pinned; meetingbot-derived).
  const MERGE_GAP_MS = 3000; // ticks ≤ this far apart merge into one utterance
  const MIN_UTTERANCE_MS = 500; // closed utterances shorter than this drop
  const RING_CAP_EVENTS = 10000; // FIFO ring capacity, counted in events
  const RING_CAP_BATCHES = 200; // FIFO ring capacity, counted in batches
  const PROCESS_INTERVAL_MS = 100; // mutation processing ≤ 10 Hz
  const SCHEMA_VERSION = 2; // v2 (C14): optional lifecycle field; v1 batches still accepted app-side
  const BADGE_401_THRESHOLD = 3; // consecutive 401s before "check secret"
  const BADGE_NETFAIL_THRESHOLD = 3; // consecutive network-class failures before "buffering"
  // FIELD BUG (2026-06-11): a listener that accepts the TCP connection but
  // never answers (wedged app, port squatter) left the un-timeboxed fetch
  // hanging forever — `flushing` stayed true, every counter froze, pending
  // grew silently, and the MV3 worker died mid-flight. A timeout converts
  // the hang into an honest network-class failure (ring retry + counters).
  const FETCH_TIMEOUT_MS = 15000;

  /** Stable per-participant key for coalescing and dedupe ids:
   * participantID when present, else displayName, else "self". */
  function participantKey(p) {
    if (p.participantID) return p.participantID;
    if (p.displayName) return p.displayName;
    return p.isSelf ? "self" : null;
  }

  /** Dedupe id (contract-pinned):
   * meetingCode:participantID-or-displayName-or-self:startMs:endMs */
  function dedupeID(meetingCode, event) {
    return `${meetingCode}:${participantKey(event)}:${event.startEpochMillis}:${event.endEpochMillis}`;
  }

  /** Per-participant tick → closed-utterance coalescer. Epochs are injected
   * (Date.now() in production, stubs in tests). */
  class Coalescer {
    constructor({ mergeGapMs = MERGE_GAP_MS, minUtteranceMs = MIN_UTTERANCE_MS } = {}) {
      this.mergeGapMs = mergeGapMs;
      this.minUtteranceMs = minUtteranceMs;
      this.open = new Map(); // key → {participant, startMs, lastMs}
      this.closed = [];
    }

    /** Record a speaking tick for a participant at epoch nowMs. */
    tick(participant, nowMs) {
      const key = participantKey(participant);
      if (key === null) return;
      const open = this.open.get(key);
      if (!open) {
        this.open.set(key, { participant, startMs: nowMs, lastMs: nowMs });
        return;
      }
      if (nowMs - open.lastMs <= this.mergeGapMs) {
        open.lastMs = Math.max(open.lastMs, nowMs);
        open.participant = participant; // latest identity info wins
        return;
      }
      this.#close(key, open);
      this.open.set(key, { participant, startMs: nowMs, lastMs: nowMs });
    }

    /** Close every open utterance whose last tick is more than mergeGapMs
     * in the past. Call periodically with the current epoch. */
    sweep(nowMs) {
      for (const [key, open] of this.open) {
        if (nowMs - open.lastMs > this.mergeGapMs) this.#close(key, open);
      }
    }

    /** Close everything unconditionally (leave / pagehide final flush). */
    closeAll() {
      for (const [key, open] of this.open) this.#close(key, open);
    }

    /** Remove and return all closed utterances (events, contract shape). */
    drain() {
      const out = this.closed;
      this.closed = [];
      return out;
    }

    #close(key, open) {
      this.open.delete(key);
      if (open.lastMs - open.startMs < this.minUtteranceMs) return; // drop short
      const p = open.participant;
      this.closed.push({
        displayName: p.isSelf ? null : (p.displayName ?? null),
        ...(p.participantID ? { participantID: p.participantID } : {}),
        isSelf: !!p.isSelf,
        startEpochMillis: open.startMs,
        endEpochMillis: open.lastMs,
      });
    }
  }

  /**
   * Delivery manager: FIFO ring of plaintext batches in injected storage,
   * AEAD encryption per send attempt (fresh IV), signed-ack verification,
   * and the status contract:
   *   valid signed 200 → delivered (counters that rode it reset)
   *   valid signed 400 → drop batch, poisonedCount += its events
   *   valid signed 401 → keep buffering; ≥3 consecutive → "check secret" badge
   *   valid signed 5xx → ring retry
   *   ANY unsigned/invalid-signature response, any status → network-class → ring retry
   *   fetch failure → ring retry
   *
   * Injected: storage {get(), set(obj)} (async, chrome.storage.local-shaped
   * over the single STORAGE_KEY), fetchFn, cryptoApi (BlaiseCrypto), now(),
   * onBadge(state) with state ∈ {"ok","check-secret","buffering","storage-error"}.
   */
  const STORAGE_KEY = "blaiseDelivery";

  class DeliveryManager {
    constructor({
      storage,
      fetchFn,
      cryptoApi,
      endpoint,
      now,
      onBadge,
      ringCap = RING_CAP_EVENTS,
      batchCap = RING_CAP_BATCHES,
      fetchTimeoutMs = FETCH_TIMEOUT_MS,
    }) {
      this.storage = storage;
      this.fetchFn = fetchFn;
      this.cryptoApi = cryptoApi;
      this.endpoint = endpoint;
      this.now = now;
      this.onBadge = onBadge || (() => {});
      this.ringCap = ringCap;
      this.batchCap = batchCap;
      this.fetchTimeoutMs = fetchTimeoutMs;
      this.state = null; // lazy-loaded
      this.loadPromise = null; // single shared in-flight load
      this.flushing = false;
      this.inFlight = null; // batch currently riding a POST (eviction skips it)
      this.persistFailures = 0; // consecutive storage-write failures
    }

    /** Load state from storage exactly once: concurrent callers on a cold
     * manager share ONE in-flight promise, so they all mutate the same
     * state object (a lost-update race here silently drops batches). */
    async #load() {
      if (!this.loadPromise) {
        this.loadPromise = (async () => {
          const stored = (await this.storage.get(STORAGE_KEY)) || {};
          this.state = {
            pending: stored.pending || [], // FIFO of plaintext batches
            droppedCount: stored.droppedCount || 0,
            poisonedCount: stored.poisonedCount || 0,
            consecutive401: stored.consecutive401 || 0,
            consecutiveNetFail: stored.consecutiveNetFail || 0,
            lastAckMs: stored.lastAckMs || null,
          };
          return this.state;
        })();
        // A failed load (storage.get rejection) must not poison the manager
        // forever; the next call retries.
        this.loadPromise.catch(() => {
          this.loadPromise = null;
        });
      }
      return this.loadPromise;
    }

    /** Persist state. Write failures (e.g. storage quota) are surfaced via
     * counter + badge, never thrown into fire-and-forget callers; the state
     * stays valid in memory for this worker's lifetime. */
    async #persist() {
      try {
        await this.storage.set({ [STORAGE_KEY]: this.state });
        this.persistFailures = 0;
      } catch {
        this.persistFailures += 1;
        this.onBadge("storage-error");
      }
    }

    #pendingEventCount() {
      return this.state.pending.reduce((n, b) => n + b.events.length, 0);
    }

    /** Enqueue a batch (meetingCode, roster, events, optional lifecycle)
     * and try to flush.
     *
     * `volatile: true` (heartbeat-only batches, C14): ONE POST attempt,
     * dropped on ANY failure — the batch never enters the ring (a stale
     * heartbeat is worthless and would only displace real events; the
     * 10k-event/200-batch caps stay honest). It carries the CURRENT loss
     * counters for honesty but never resets them (the next ring-delivered
     * batch does) and never touches badges or persisted state. */
    async enqueue({ meetingCode, roster, events, lifecycle }, { volatile = false } = {}) {
      const s = await this.#load();
      const newest = {
        meetingCode,
        capturedAtMs: this.now(),
        roster,
        events,
        schemaVersion: SCHEMA_VERSION,
        ...(lifecycle ? { lifecycle } : {}),
      };
      if (volatile) {
        await this.#postVolatile(s, newest);
        return;
      }
      s.pending.push(newest);
      this.#evictToCaps(s, newest);
      await this.#persist();
      await this.flush();
    }

    /** Fire-and-forget delivery of a volatile batch. Silent by design:
     * no ring, no retry, no badge, no counter mutation. */
    async #postVolatile(s, batch) {
      const secret = await this.storage.get("blaiseSecret");
      if (!secret) return;
      const wire = {
        ...batch,
        droppedCount: s.droppedCount,
        poisonedCount: s.poisonedCount,
      };
      try {
        const envelope = await this.cryptoApi.encryptBatch(secret, wire);
        await this.fetchFn(this.endpoint, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(envelope),
          signal: AbortSignal.timeout(this.fetchTimeoutMs),
        });
      } catch {
        // dropped on ANY failure — a stale heartbeat is worthless
      }
    }

    /** Ring eviction: drop OLDEST batches until within both caps (events
     * and batch count); losses ride droppedCount on the next delivered
     * batch. Never evicts the batch riding an in-flight POST (its delivery
     * would remove the wrong batch and strand un-carried loss counts) nor
     * the just-pushed newest. */
    #evictToCaps(s, newest) {
      while (
        this.#pendingEventCount() > this.ringCap ||
        s.pending.length > this.batchCap
      ) {
        const idx = s.pending.findIndex(
          (b) => b !== this.inFlight && b !== newest,
        );
        if (idx === -1) break; // only in-flight/newest left: tolerate overage
        const evicted = s.pending.splice(idx, 1)[0];
        s.droppedCount += evicted.events.length;
      }
      if (this.#pendingEventCount() > this.ringCap && newest.events.length > this.ringCap) {
        // Single oversized batch: truncate oldest events within it.
        const excess = newest.events.length - this.ringCap;
        newest.events.splice(0, excess);
        s.droppedCount += excess;
      }
    }

    /** Attempt to deliver pending batches in FIFO order. */
    async flush() {
      if (this.flushing) return;
      this.flushing = true;
      try {
        const s = await this.#load();
        while (s.pending.length > 0) {
          const secret = await this.storage.get("blaiseSecret");
          if (!secret) {
            this.onBadge("buffering");
            return;
          }
          const batch = s.pending[0];
          this.inFlight = batch; // eviction skips this batch until resolved
          // Counters ride the outgoing batch (stamped at send time).
          const wire = {
            ...batch,
            droppedCount: s.droppedCount,
            poisonedCount: s.poisonedCount,
          };
          const envelope = await this.cryptoApi.encryptBatch(secret, wire);
          let response;
          try {
            response = await this.fetchFn(this.endpoint, {
              method: "POST",
              headers: { "Content-Type": "application/json" },
              body: JSON.stringify(envelope),
              signal: AbortSignal.timeout(this.fetchTimeoutMs),
            });
          } catch {
            // Rejection OR timeout abort (a listener that accepts and never
            // answers must not wedge the manager) → network-class.
            await this.#noteNetworkFailure(s);
            return; // network failure → ring retry later
          }
          const status = response.status;
          const ack = response.headers.get("X-Blaise-Ack");
          const signed = await this.cryptoApi.verifyAck(secret, envelope.iv, status, ack);
          if (!signed) {
            // Unsigned or forged, whatever the status code: a squatter can
            // fabricate codes but not signatures → network-class.
            await this.#noteNetworkFailure(s);
            return;
          }
          s.consecutiveNetFail = 0; // any validly signed ack = app reachable
          if (status === 200) {
            // Remove the delivered batch BY IDENTITY (concurrent enqueues
            // may have changed the ring while the POST was in flight) and
            // clear only the loss counts this wire actually carried —
            // counts accrued during the in-flight window stay owed.
            this.#removeBatch(s, batch);
            s.droppedCount -= wire.droppedCount;
            s.poisonedCount -= wire.poisonedCount;
            s.consecutive401 = 0;
            s.lastAckMs = this.now();
            this.onBadge("ok");
            await this.#persist();
            continue;
          }
          if (status === 400) {
            this.#removeBatch(s, batch);
            s.poisonedCount += batch.events.length;
            s.consecutive401 = 0;
            await this.#persist();
            continue;
          }
          if (status === 401) {
            s.consecutive401 += 1;
            if (s.consecutive401 >= BADGE_401_THRESHOLD) {
              this.onBadge("check-secret");
            }
            await this.#persist();
            return; // keep buffering (bounded by the ring)
          }
          // signed 5xx / anything else → ring retry
          await this.#persist();
          return;
        }
      } finally {
        this.inFlight = null;
        this.flushing = false;
      }
    }

    #removeBatch(s, batch) {
      const idx = s.pending.indexOf(batch);
      if (idx !== -1) s.pending.splice(idx, 1);
    }

    /** Network-class failure (fetch threw, or unsigned/forged response):
     * count it; a streak means the app is down → honest "buffering" badge. */
    async #noteNetworkFailure(s) {
      s.consecutiveNetFail += 1;
      if (s.consecutiveNetFail >= BADGE_NETFAIL_THRESHOLD) {
        this.onBadge("buffering");
      }
      await this.#persist();
    }

    /** Age of the last valid ack in ms, or null. Drives the badge title. */
    async lastAckAgeMs() {
      const s = await this.#load();
      return s.lastAckMs === null ? null : this.now() - s.lastAckMs;
    }

    /** Buffered (undelivered) event count, for the options page. */
    async bufferedEventCount() {
      await this.#load();
      return this.#pendingEventCount();
    }
  }

  const BlaiseEvents = {
    MERGE_GAP_MS,
    MIN_UTTERANCE_MS,
    RING_CAP_EVENTS,
    RING_CAP_BATCHES,
    PROCESS_INTERVAL_MS,
    SCHEMA_VERSION,
    BADGE_401_THRESHOLD,
    BADGE_NETFAIL_THRESHOLD,
    FETCH_TIMEOUT_MS,
    STORAGE_KEY,
    participantKey,
    dedupeID,
    Coalescer,
    DeliveryManager,
  };

  globalThis.BlaiseEvents = BlaiseEvents;
  if (typeof module !== "undefined" && module.exports) {
    module.exports = BlaiseEvents;
  }
})();
