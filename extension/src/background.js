// background.js — MV3 service worker: thin chrome glue around
// events.js DeliveryManager (ring + status contract + signed acks).
// All testable logic lives in events.js/crypto.js; this file only wires
// chrome.storage / chrome.alarms / fetch / the action badge.

importScripts("crypto.js", "events.js");

const ENDPOINT = "http://127.0.0.1:18429/v1/meet-events";
const RETRY_ALARM = "blaise-retry";

const storage = {
  async get(key) {
    const out = await chrome.storage.local.get(key);
    return out[key];
  },
  async set(obj) {
    await chrome.storage.local.set(obj);
  },
};

let badgeState = "ok"; // last state set; error badges own the tooltip

function setBadge(state) {
  badgeState = state;
  if (state === "check-secret") {
    chrome.action.setBadgeText({ text: "!" });
    chrome.action.setBadgeBackgroundColor({ color: "#c0392b" });
    chrome.action.setTitle({
      title: "Blaise: check the shared secret (3+ rejected deliveries)",
    });
  } else if (state === "ok") {
    chrome.action.setBadgeText({ text: "" });
  } else if (state === "buffering") {
    chrome.action.setBadgeText({ text: "…" });
    chrome.action.setBadgeBackgroundColor({ color: "#7f8c8d" });
    chrome.action.setTitle({
      title: "Blaise: buffering (no secret configured or app unreachable)",
    });
  } else if (state === "storage-error") {
    chrome.action.setBadgeText({ text: "!" });
    chrome.action.setBadgeBackgroundColor({ color: "#c0392b" });
    chrome.action.setTitle({
      title: "Blaise: failed to save buffered events (extension storage error)",
    });
  }
}

const manager = new BlaiseEvents.DeliveryManager({
  storage,
  fetchFn: (...args) => fetch(...args),
  cryptoApi: BlaiseCrypto,
  endpoint: ENDPOINT,
  now: () => Date.now(),
  onBadge: setBadge,
});

// The handler returns literal `true` for a Blaise batch and responds only after
// DeliveryManager finishes its acceptance path. That keeps the MV3 worker alive
// across the async storage write instead of abandoning it when this event ends.
chrome.runtime.onMessage.addListener(
  BlaiseEvents.createRuntimeMessageHandler(manager),
);

// Retry alarm: chrome.alarms minimum period is 30 s (0.5 min, Chrome 120+).
chrome.runtime.onInstalled.addListener(() => {
  chrome.alarms.create(RETRY_ALARM, { periodInMinutes: 0.5 });
});
chrome.runtime.onStartup.addListener(() => {
  chrome.alarms.create(RETRY_ALARM, { periodInMinutes: 0.5 });
});
// Self-heal: onInstalled/onStartup do not fire on plain worker restarts, so
// a lost alarm (cleared storage, crashed alarm store) would silence retries
// forever. Every worker start verifies it exists.
chrome.alarms.get(RETRY_ALARM).then((alarm) => {
  if (!alarm) chrome.alarms.create(RETRY_ALARM, { periodInMinutes: 0.5 });
});

chrome.alarms.onAlarm.addListener(async (alarm) => {
  if (alarm.name !== RETRY_ALARM) return;
  await manager.flush();
  // Badge "connected" = age of the last valid signed ack. Never clobber an
  // error badge's tooltip (e.g. "check secret" during a 401 streak).
  if (badgeState !== "ok") return;
  const age = await manager.lastAckAgeMs();
  if (age !== null) {
    chrome.action.setTitle({
      title: `Blaise: connected — last ack ${Math.round(age / 1000)}s ago`,
    });
  }
});
