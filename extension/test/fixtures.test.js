// Fixture hygiene (spec "Tests"): committed fixtures may contain no emails,
// no URLs, no attributes outside the sanitizer allowlist, and — when the
// gitignored digests sidecar is present locally — no value whose SHA-256
// appears in the sidecar (i.e., no original name survived sanitization).
// In CI / fresh clones the sidecar is absent and the structural checks run.
import { describe, it, expect } from "vitest";
import { readFileSync, readdirSync, existsSync } from "node:fs";
import { join, dirname, basename } from "node:path";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";
import S from "../src/selectors.js";
import O from "../src/observer.js";

const FIXTURES = join(dirname(fileURLToPath(import.meta.url)), "fixtures");
const htmlFixtures = readdirSync(FIXTURES).filter((f) => f.endsWith(".html"));

const ALLOWED = new Set([
  ...O.SANITIZE_KEEP_ATTRIBUTES, // class, role
  ...S.PINNED_DATA_ATTRIBUTES,
]);
const isAllowed = (name) => ALLOWED.has(name) || name.startsWith("aria-");

const sha = (t) => createHash("sha256").update(t, "utf8").digest("hex");

describe.each(htmlFixtures)("hygiene: %s", (file) => {
  const raw = readFileSync(join(FIXTURES, file), "utf8");

  it("contains no emails and no URLs", () => {
    expect(raw).not.toMatch(/@/);
    expect(raw).not.toMatch(/https?:\/\//);
  });

  it("is labeled as a reconstruction (until a real sanitized snapshot lands)", () => {
    expect(raw).toContain("RECONSTRUCTED");
  });

  it("uses only allowlisted attributes", () => {
    document.body.innerHTML = raw;
    for (const el of document.body.querySelectorAll("*")) {
      for (const attr of el.attributes) {
        expect(
          isAllowed(attr.name.toLowerCase()),
          `non-allowlisted attribute "${attr.name}" on <${el.tagName.toLowerCase()}> in ${file}`,
        ).toBe(true);
      }
    }
  });

  it("contains no value whose digest appears in the local sidecar (when present)", () => {
    const sidecar = join(FIXTURES, `${basename(file, ".html")}.digests.json`);
    if (!existsSync(sidecar)) return; // CI fallback: structural checks above
    const digests = new Set(JSON.parse(readFileSync(sidecar, "utf8")));
    document.body.innerHTML = raw;
    const probe = (value) => {
      const v = value.trim();
      if (v) {
        expect(
          digests.has(sha(v)),
          `value "${v}" in ${file} matches a replaced-name digest`,
        ).toBe(false);
      }
    };
    for (const el of document.body.querySelectorAll("*")) {
      for (const attr of el.attributes) probe(attr.value);
    }
    const walker = document.createTreeWalker(document.body, 4 /* TEXT */);
    while (walker.nextNode()) probe(walker.currentNode.textContent);
  });
});

describe("digests sidecars are gitignored", () => {
  it(".gitignore covers extension/test/fixtures/*.digests.json", () => {
    const gitignore = readFileSync(
      join(dirname(fileURLToPath(import.meta.url)), "..", "..", ".gitignore"),
      "utf8",
    );
    expect(gitignore).toContain("extension/test/fixtures/*.digests.json");
  });
});
