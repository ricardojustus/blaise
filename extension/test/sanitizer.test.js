// __blaiseSnapshot() allowlist sanitizer: only known-needed attributes
// survive, names → synthetic, aria values rewritten, URLs/emails/ids
// stripped at capture, digests sidecar lists replaced names.
import { describe, it, expect } from "vitest";
import { createHash } from "node:crypto";
import O from "../src/observer.js";
import BC from "../src/crypto.js";

const sha = (t) => createHash("sha256").update(t, "utf8").digest("hex");

// A deliberately dirty reconstruction: realistic Meet noise (jsname,
// jscontroller, ids, URLs, emails, styles) around the structures the
// selectors need. Names here are ALREADY synthetic (no real names may
// appear anywhere in the repo), standing in for real captured names.
function dirtySurface() {
  document.body.innerHTML = `
    <div role="list" class="pl" jsname="QpN8Cf" jscontroller="X9ZZ"
         style="color:red" id="pl-1" data-internal-thing="zzz">
      <div role="listitem" data-participant-id="spaces/AAA/devices/123"
           aria-label="Participante Real Um" jsmodel="hash1"
           data-tooltip="participante@exemplo.com">
        <span>Participante Real Um</span>
        <img src="https://lh3.googleusercontent.com/avatar/xyz" alt="x">
        <button aria-label="Mais ações" class="opt"></button>
      </div>
      <div role="listitem" data-participant-id="spaces/AAA/devices/456"
           aria-label="Participante Real Dois" aria-pressed="false">
        <span>Participante Real Dois</span>
        <a href="http://internal.example/page">link</a>
      </div>
    </div>
    <div data-requested-participant-id="spaces/AAA/devices/123" class="tile">
      <div data-self-name="Você" class="nm">Você</div>
    </div>
    <div data-requested-participant-id="spaces/AAA/devices/456" class="tile">
      <div data-self-name="Participante Real Dois" class="nm">Participante Real Dois</div>
    </div>
    <button aria-label="Sair da chamada" class="end"></button>
  `;
  return document.body;
}

describe("sanitizeSurface", () => {
  it("strips every non-allowlisted attribute, all URLs and emails", async () => {
    const { html } = await O.sanitizeSurface(dirtySurface(), BC.sha256Hex);
    expect(html).not.toContain("@");
    expect(html).not.toContain("http://");
    expect(html).not.toContain("https://");
    expect(html).not.toContain("jsname");
    expect(html).not.toContain("jscontroller");
    expect(html).not.toContain("jsmodel");
    expect(html).not.toContain("style=");
    expect(html).not.toContain(' id="'); // the id attribute itself
    expect(html).not.toContain("data-internal-thing");
    expect(html).not.toContain("data-tooltip");
    expect(html).not.toContain("src=");
    expect(html).not.toContain("href=");
  });

  it("replaces names (text, aria-label, data-self-name) with synthetic names and rewrites participant ids", async () => {
    const { html } = await O.sanitizeSurface(dirtySurface(), BC.sha256Hex);
    expect(html).not.toContain("Participante Real Um");
    expect(html).not.toContain("Participante Real Dois");
    expect(html).not.toContain("spaces/AAA");
    // structural linkage preserved: tile pid == panel pid after rewrite
    const pids = [...html.matchAll(/data-participant-id="([^"]+)"/g)].map((m) => m[1]);
    const tilePids = [...html.matchAll(/data-requested-participant-id="([^"]+)"/g)].map((m) => m[1]);
    expect(tilePids.every((p) => pids.includes(p))).toBe(true);
  });

  it("preserves the localized self label and the leave-button carve-out verbatim (structural markers, not names)", async () => {
    const { html } = await O.sanitizeSurface(dirtySurface(), BC.sha256Hex);
    expect(html).toContain('data-self-name="Você"');
    expect(html).toContain('aria-label="Sair da chamada"');
  });

  it("empties non-name aria values", async () => {
    const { html } = await O.sanitizeSurface(dirtySurface(), BC.sha256Hex);
    expect(html).toContain('aria-pressed=""');
    expect(html).not.toContain('aria-pressed="false"');
  });

  it("empties (does not name-synthesize) aria-labels on row-INNER chrome", async () => {
    const { html, digests } = await O.sanitizeSurface(dirtySurface(), BC.sha256Hex);
    expect(html).not.toContain("Mais ações");
    const button = html.match(/<button[^>]*class="opt"[^>]*>/)[0];
    expect(button).toContain('aria-label=""'); // emptied, not a fake name
    expect(digests).not.toContain(sha("Mais ações")); // and never digested
  });

  it("digests sidecar = SHA-256 of each ORIGINAL replaced name; self labels not digested", async () => {
    const { digests } = await O.sanitizeSurface(dirtySurface(), BC.sha256Hex);
    expect(digests).toContain(sha("Participante Real Um"));
    expect(digests).toContain(sha("Participante Real Dois"));
    expect(digests).not.toContain(sha("Você"));
  });

  it("same original name maps to the same synthetic everywhere (consistency)", async () => {
    const { html } = await O.sanitizeSurface(dirtySurface(), BC.sha256Hex);
    // "Participante Real Dois" appears in panel (span + aria-label) and on
    // a tile (text + data-self-name); all four positions must agree.
    const synth = O.SYNTHETIC_NAMES;
    const counts = synth
      .map((name) => [...html.matchAll(new RegExp(name.replace(" ", "\\s"), "g"))].length)
      .filter((n) => n > 0);
    expect(Math.max(...counts)).toBeGreaterThanOrEqual(4);
  });
});
