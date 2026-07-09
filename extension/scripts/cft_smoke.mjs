// cft_smoke.mjs — unpacked-load smoke test via Chrome for Testing.
//
// Branded Chrome removed --load-extension in 137 (Chromium extensions PSA;
// developer.chrome.com/blog/extension-news-june-2025). Chrome for Testing
// retains it,
// so this script:
//   1. downloads CfT stable via `npx @puppeteer/browsers install` into
//      extension/.cft/ (gitignored, dev-time only, ~150 MB on first run)
//   2. launches it headless with --load-extension=<extension dir> and a
//      DevTools port
//   3. asserts THE OBSERVABLE: the extension's MV3 service worker appears
//      in the DevTools target list (a vacuous pass is impossible — no
//      worker target, no pass).
//
// Exit 0 = PASS, 1 = FAIL, 2 = CfT unavailable (offline) — the recorded
// fallback is manifest schema validation (npm test covers the manifest
// shape) plus a DoD split until the download can run.
import { execFileSync, spawn } from "node:child_process";
import { mkdtempSync, rmSync, existsSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const EXT_DIR = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const CFT_CACHE = join(EXT_DIR, ".cft");
const DEBUG_PORT = 9377;

function installCfT() {
  console.log("[smoke] installing Chrome for Testing (stable) into .cft/ ...");
  const out = execFileSync(
    "npx",
    ["--yes", "@puppeteer/browsers", "install", "chrome@stable", "--path", CFT_CACHE],
    { encoding: "utf8", stdio: ["ignore", "pipe", "inherit"], timeout: 300_000 },
  );
  // Last non-empty line: "chrome@<version> <absolute path to binary>"
  const line = out.trim().split("\n").filter(Boolean).at(-1);
  const path = line.slice(line.indexOf(" ") + 1).trim();
  if (!existsSync(path)) throw new Error(`parsed CfT path does not exist: ${path}`);
  console.log(`[smoke] CfT binary: ${path}`);
  return path;
}

async function targets() {
  const res = await fetch(`http://127.0.0.1:${DEBUG_PORT}/json`);
  return res.json();
}

async function main() {
  // Sanity: manifest parses and pins the minimal surface before launching.
  const manifest = JSON.parse(readFileSync(join(EXT_DIR, "manifest.json"), "utf8"));
  if (manifest.manifest_version !== 3) throw new Error("manifest_version must be 3");

  let chrome;
  try {
    chrome = installCfT();
  } catch (err) {
    console.error(`[smoke] CfT unavailable (offline?): ${err.message}`);
    process.exit(2);
  }

  const profile = mkdtempSync(join(tmpdir(), "blaise-cft-"));
  const proc = spawn(
    chrome,
    [
      "--headless=new",
      "--no-first-run",
      "--no-default-browser-check",
      "--disable-gpu",
      `--user-data-dir=${profile}`,
      `--load-extension=${EXT_DIR}`,
      `--remote-debugging-port=${DEBUG_PORT}`,
      "about:blank",
    ],
    { stdio: "ignore" },
  );

  const cleanup = () => {
    proc.kill("SIGKILL");
    rmSync(profile, { recursive: true, force: true });
  };

  try {
    const deadline = Date.now() + 30_000;
    while (Date.now() < deadline) {
      await new Promise((r) => setTimeout(r, 500));
      let list;
      try {
        list = await targets();
      } catch {
        continue; // DevTools port not up yet
      }
      const worker = list.find(
        (t) =>
          t.type === "service_worker" &&
          t.url.startsWith("chrome-extension://") &&
          t.url.endsWith("/src/background.js"),
      );
      if (worker) {
        console.log(`[smoke] PASS — extension service worker registered: ${worker.url}`);
        cleanup();
        process.exit(0);
      }
    }
    console.error("[smoke] FAIL — no extension service worker in the target list after 30 s");
    const list = await targets().catch(() => []);
    console.error(`[smoke] targets seen: ${JSON.stringify(list.map((t) => [t.type, t.url]))}`);
    cleanup();
    process.exit(1);
  } catch (err) {
    cleanup();
    throw err;
  }
}

main().catch((err) => {
  console.error(`[smoke] error: ${err.message}`);
  process.exit(1);
});
