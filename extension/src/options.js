// options.js — shared-secret entry + a small status readout.

const secretInput = document.getElementById("secret");
const statusEl = document.getElementById("status");

async function refresh() {
  const { blaiseSecret, blaiseDelivery } = await chrome.storage.local.get([
    "blaiseSecret",
    "blaiseDelivery",
  ]);
  const lines = [];
  lines.push(blaiseSecret ? "Secret: configured." : "Secret: not configured.");
  if (blaiseDelivery) {
    const buffered = (blaiseDelivery.pending || []).reduce(
      (n, b) => n + b.events.length,
      0,
    );
    lines.push(`Buffered events awaiting delivery: ${buffered}`);
    if (blaiseDelivery.lastAckMs) {
      const age = Math.round((Date.now() - blaiseDelivery.lastAckMs) / 1000);
      lines.push(`Last confirmed delivery: ${age}s ago`);
    }
    if (blaiseDelivery.consecutive401 >= 3) {
      lines.push(
        "The app is rejecting deliveries — re-copy the secret from Blaise Settings.",
      );
    }
  }
  statusEl.textContent = lines.join("\n");
}

document.getElementById("save").addEventListener("click", async () => {
  const value = secretInput.value.trim();
  if (!value) return;
  await chrome.storage.local.set({ blaiseSecret: value });
  secretInput.value = "";
  await refresh();
});

refresh();
