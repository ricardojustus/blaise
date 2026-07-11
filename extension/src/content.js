// content.js — in-call lifecycle state machine + content-script glue.
// DOM work only; batches go to the service worker via runtime messages.
// The lifecycle factory is pure (epoch-stubbed in tests); the chrome glue
// at the bottom only runs inside the extension.

(() => {
  "use strict";

  const isTestModule = typeof module !== "undefined" && module.exports;
  const S = isTestModule ? require("./selectors.js") : globalThis.BlaiseSelectors;
  const E = isTestModule ? require("./events.js") : globalThis.BlaiseEvents;
  const O = isTestModule ? require("./observer.js") : globalThis.BlaiseObserver;

  const ROSTER_SCAN_MS = 5000;
  const BATCH_SEND_MS = 5000;
  const LIFECYCLE_POLL_MS = 1000;
  const HEARTBEAT_MS = 60000;

  /**
   * Lifecycle state machine. States: "idle" (pre-join preview or no call —
   * produces NOTHING) → "in-call" (capture armed) → back to "idle" on leave
   * (final flush fires). Injected: isInCall() probe, onJoin/onLeave.
   */
  function createLifecycle({ isInCall, onJoin, onLeave }) {
    let state = "idle";
    const poll = () => {
      const inCall = isInCall();
      if (state === "idle" && inCall) {
        state = "in-call";
        onJoin();
      } else if (state === "in-call" && !inCall) {
        state = "idle";
        onLeave({ final: false });
      }
    };
    /** pagehide / tab close: terminal flush if armed. */
    const pagehide = () => {
      if (state === "in-call") {
        state = "idle";
        onLeave({ final: true });
      }
    };
    return { poll, pagehide, get state() { return state; } };
  }

  /** Roster equality (order-insensitive) so unchanged rosters do not spam
   * batches. */
  function rosterFingerprint(roster) {
    return roster
      .map((r) => `${r.participantID ?? ""}|${r.displayName ?? ""}|${r.isSelf}`)
      .sort()
      .join("\n");
  }

  /**
   * C14 lifecycle/heartbeat signal source (schema v2). Pure and
   * epoch-stubbed in tests; the chrome glue wires it to the lifecycle
   * machine and the 60 s heartbeat timer. Injected: now(), send(batch,
   * {volatile}) where batch = {events, roster, lifecycle}.
   *
   * - callStarted(roster): idle→in-call transition — the batch carries the
   *   current roster plus `{kind:"call-started", atMs}`. Tab reloads
   *   re-fire it by design; the APP debounces (it has the durable state).
   * - callEnded(reason): in-call→idle — returns the lifecycle object that
   *   RIDES the existing final-flush batch (closed events + roster +
   *   lifecycle in ONE batch; atomic ordering, no extra POST).
   *   reason ∈ {"left","pagehide"}.
   * - heartbeatTick(): every 60 s while in-call, SKIPPED when any other
   *   batch shipped within the last 60 s (roster churn and speech already
   *   prove liveness). Heartbeat batches are volatile: one POST, dropped on
   *   any failure, never ring-buffered.
   * - noteBatchSent(): the send path calls it for every shipped batch.
   */
  function createAutomationSignals({ now, send }) {
    let lastBatchSentMs = null;
    return {
      noteBatchSent() {
        lastBatchSentMs = now();
      },
      callStarted(roster) {
        send(
          { events: [], roster, lifecycle: { kind: "call-started", atMs: now() } },
          { volatile: false },
        );
      },
      callEnded(reason) {
        return { kind: "call-ended", atMs: now(), reason };
      },
      heartbeatTick() {
        const t = now();
        if (lastBatchSentMs !== null && t - lastBatchSentMs < HEARTBEAT_MS) {
          return false; // a recent batch already proved liveness
        }
        send(
          { events: [], roster: [], lifecycle: { kind: "heartbeat", atMs: t } },
          { volatile: true },
        );
        return true;
      },
    };
  }

  const BlaiseContent = {
    createLifecycle,
    rosterFingerprint,
    createAutomationSignals,
    ROSTER_SCAN_MS,
    BATCH_SEND_MS,
    LIFECYCLE_POLL_MS,
    HEARTBEAT_MS,
  };
  globalThis.BlaiseContent = BlaiseContent;
  if (isTestModule) {
    module.exports = BlaiseContent;
    return; // no side effects under test
  }

  // ---- Chrome glue (extension runtime only). ----
  if (typeof chrome === "undefined" || !chrome.runtime?.id) return;

  const selfModel = new O.SelfModel();
  const coalescer = new E.Coalescer();
  const speaking = O.createSpeakingObserver({
    doc: document,
    coalescer,
    selfModel,
    now: () => Date.now(),
    getStyle: (el) => getComputedStyle(el),
  });

  let timers = [];
  let lastRosterFingerprint = null;
  let pendingRoster = [];

  const meetingCode = () => S.meetingCodeFromURL(location.href);

  const send = (events, roster, lifecycle = null, volatile = false) => {
    const code = meetingCode();
    if (!code) return;
    if (events.length === 0 && roster === null && !lifecycle) return;
    signals.noteBatchSent();
    chrome.runtime.sendMessage({
      type: "blaiseBatch",
      batch: {
        meetingCode: code,
        roster: roster ?? pendingRoster,
        events,
        ...(lifecycle ? { lifecycle } : {}),
      },
      volatile,
    }).then((response) => {
      if (response?.accepted === false) {
        console.warn("Blaise: background worker did not accept a Meet batch");
      }
    }).catch((error) => {
      // The background ring owns retry after acceptance. This is the narrower
      // content→worker failure boundary (extension reload/context loss), which
      // must at least be observable instead of becoming an unhandled rejection.
      console.warn("Blaise: could not hand Meet batch to background worker", error);
    });
  };

  const signals = createAutomationSignals({
    now: () => Date.now(),
    send: ({ events, roster, lifecycle }, { volatile }) =>
      send(events, roster, lifecycle, volatile),
  });

  const scanRoster = () => {
    const roster = O.extractRoster(document, selfModel);
    pendingRoster = roster;
    const fp = rosterFingerprint(roster);
    if (fp !== lastRosterFingerprint) {
      lastRosterFingerprint = fp;
      send([], roster); // roster change ships immediately
    }
  };

  const sendClosed = () => {
    coalescer.sweep(Date.now());
    const events = coalescer.drain();
    if (events.length > 0) send(events, null);
  };

  const lifecycle = createLifecycle({
    isInCall: () => S.isInCall(document),
    onJoin: () => {
      speaking.attach();
      // call-started carries the current roster (one batch, no extra POST).
      const roster = O.extractRoster(document, selfModel);
      pendingRoster = roster;
      lastRosterFingerprint = rosterFingerprint(roster);
      signals.callStarted(roster);
      timers.push(setInterval(scanRoster, ROSTER_SCAN_MS));
      timers.push(setInterval(sendClosed, BATCH_SEND_MS));
      timers.push(setInterval(() => speaking.watchdog(), 1000));
      timers.push(setInterval(() => signals.heartbeatTick(), HEARTBEAT_MS));
    },
    onLeave: ({ final }) => {
      for (const t of timers) clearInterval(t);
      timers = [];
      speaking.detach();
      coalescer.closeAll();
      const events = coalescer.drain();
      // call-ended RIDES the final flush (events + roster + lifecycle in
      // one batch — atomic ordering).
      send(events, pendingRoster, signals.callEnded(final ? "pagehide" : "left"));
      lastRosterFingerprint = null;
    },
  });

  setInterval(lifecycle.poll, LIFECYCLE_POLL_MS);
  window.addEventListener("pagehide", lifecycle.pagehide);

  // ---- Snapshot tool (manual, dev-time; see README). Run from the
  // extension's content-script context in DevTools:
  //   __blaiseSnapshot("meet_live")
  // Downloads <name>.html (sanitized by allowlist) and <name>.digests.json
  // (SHA-256 of replaced names — keep LOCAL, the sidecar is gitignored). ----
  globalThis.__blaiseSnapshot = async (name = "meet_snapshot") => {
    const C = globalThis.BlaiseCrypto;
    const surfaces = [];
    const panel = S.findPanelList(document);
    if (panel) surfaces.push(panel);
    const tile = document.querySelector(`[${S.DATA_REQUESTED_PARTICIPANT_ID}]`);
    if (tile) surfaces.push(tile);
    const captions = document.querySelector('div[role="region"][tabindex="0"]');
    if (captions) surfaces.push(captions);
    const controlBar = S.findLeaveButton(document)?.parentElement;
    if (controlBar) surfaces.push(controlBar);

    let html = `<!-- SANITIZED Meet snapshot (${new Date().toISOString()}). Allowlist-serialized; synthetic names. -->\n`;
    const digests = new Set();
    for (const surface of surfaces) {
      const result = await O.sanitizeSurface(surface, C.sha256Hex);
      html += result.html + "\n";
      for (const d of result.digests) digests.add(d);
    }
    const download = (filename, text, mime) => {
      const a = document.createElement("a");
      a.href = URL.createObjectURL(new Blob([text], { type: mime }));
      a.download = filename;
      a.click();
      URL.revokeObjectURL(a.href);
    };
    download(`${name}.html`, html, "text/html");
    download(
      `${name}.digests.json`,
      JSON.stringify(Array.from(digests), null, 2),
      "application/json",
    );
    return `${surfaces.length} surface(s) captured`;
  };
})();
