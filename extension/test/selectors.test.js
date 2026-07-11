// Selectors tripwire: pins the rotation point's attribute names and proves
// every strategy still matches the committed fixtures. If Meet rotates and
// a new sanitized snapshot lands, these fail loudly and point at
// src/selectors.js as the single file to fix.
import { describe, it, expect, beforeEach } from "vitest";
import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import S from "../src/selectors.js";

const FIXTURES = join(dirname(fileURLToPath(import.meta.url)), "fixtures");
const fixture = (name) => readFileSync(join(FIXTURES, name), "utf8");

describe("pinned attribute names (rotation tripwire)", () => {
  it("pins the data-* attribute set", () => {
    expect(S.DATA_PARTICIPANT_ID).toBe("data-participant-id");
    expect(S.DATA_REQUESTED_PARTICIPANT_ID).toBe("data-requested-participant-id");
    expect(S.DATA_SELF_NAME).toBe("data-self-name");
    expect(S.PINNED_DATA_ATTRIBUTES).toEqual([
      "data-participant-id",
      "data-requested-participant-id",
      "data-self-name",
    ]);
  });

  it("pins the closed localized self-label set (carve-out #1)", () => {
    expect(Array.from(S.SELF_TILE_LABELS).sort()).toEqual(
      ["You", "Você", "you", "você"].sort(),
    );
  });

  it("pins the leave-button carve-out (#2) labels", () => {
    expect(S.LEAVE_BUTTON_ARIA_LABELS).toEqual(["Leave call", "Sair da chamada"]);
  });
});

describe("strategies against the in-call fixture", () => {
  beforeEach(() => {
    document.body.innerHTML = fixture("meet_in_call.html");
  });

  it("finds the People panel structurally (no localized label match)", () => {
    const panel = S.findPanelList(document);
    expect(panel).not.toBeNull();
    expect(panel.getAttribute("role")).toBe("list");
  });

  it("finds all panel rows including merged-audio nesting", () => {
    const rows = S.panelRows(S.findPanelList(document));
    expect(rows).toHaveLength(5);
    expect(rows.map(S.panelRowParticipantID)).toEqual([
      "pid-1",
      "pid-2",
      "pid-3",
      "pid-4",
      "pid-5",
    ]);
    expect(S.panelRowName(rows[4])).toBe("Ana Souza");
  });

  it("finds rendered tiles with names and ids", () => {
    const tiles = S.findTiles(document);
    expect(tiles).toHaveLength(3);
    const byPid = new Map(tiles.map((t) => [S.tileParticipantID(t), S.tileName(t)]));
    expect(byPid.get("pid-2")).toBe("Maria Silva");
    expect(byPid.get("pid-3")).toBe("João Pereira");
    expect(byPid.get("pid-1")).toBe("Você");
  });

  it("detects the in-call state (PT leave button)", () => {
    expect(S.isInCall(document)).toBe(true);
  });

  it("detects a call structurally when the leave aria-label is localized differently", () => {
    document.body.innerHTML = `
      <main>
        <button aria-label="Ver llamada">
          <i class="google-symbols">call_end</i>
        </button>
      </main>`;
    expect(S.findLeaveButton(document)?.getAttribute("aria-label")).toBe("Ver llamada");
    expect(S.isInCall(document)).toBe(true);
  });

  it("maps a mutated descendant to its participant node", () => {
    const bar = document.querySelector('[data-requested-participant-id="pid-2"] .bar');
    const node = S.participantNodeFor(bar);
    expect(node.getAttribute(S.DATA_REQUESTED_PARTICIPANT_ID)).toBe("pid-2");
    const rowSpan = document.querySelector('[data-participant-id="pid-4"] span');
    expect(S.participantNodeFor(rowSpan).getAttribute(S.DATA_PARTICIPANT_ID)).toBe("pid-4");
    expect(S.participantNodeFor(document.querySelector(".ctrl-bar"))).toBeNull();
  });
});

describe("pre-join fixture produces nothing", () => {
  beforeEach(() => {
    document.body.innerHTML = fixture("meet_prejoin.html");
  });

  it("is not in-call", () => {
    expect(S.isInCall(document)).toBe(false);
  });

  it("has no panel and no tiles", () => {
    expect(S.findPanelList(document)).toBeNull();
    expect(S.findTiles(document)).toHaveLength(0);
  });
});

describe("meetingCodeFromURL", () => {
  it("extracts the canonical code", () => {
    expect(S.meetingCodeFromURL("https://meet.google.com/abc-defg-hij")).toBe("abc-defg-hij");
    expect(S.meetingCodeFromURL("https://meet.google.com/abc-defg-hij?authuser=0")).toBe("abc-defg-hij");
    expect(S.meetingCodeFromURL("https://meet.google.com/abc-defg-hij/extra")).toBe("abc-defg-hij");
  });

  it("rejects non-meeting paths", () => {
    expect(S.meetingCodeFromURL("https://meet.google.com/")).toBeNull();
    expect(S.meetingCodeFromURL("https://meet.google.com/landing")).toBeNull();
    expect(S.meetingCodeFromURL("https://meet.google.com/new")).toBeNull();
    expect(S.meetingCodeFromURL("not a url")).toBeNull();
  });

  it("falls back to the first path segment for lookup-style paths", () => {
    expect(S.meetingCodeFromURL("https://meet.google.com/lookup-code-x")).toBe("lookup-code-x");
  });

  it("uses the alias as the code for /lookup/<alias> paths; bare /lookup is not a code", () => {
    expect(S.meetingCodeFromURL("https://meet.google.com/lookup/team-sync")).toBe("team-sync");
    expect(S.meetingCodeFromURL("https://meet.google.com/lookup/team-sync?authuser=0")).toBe(
      "team-sync",
    );
    expect(S.meetingCodeFromURL("https://meet.google.com/lookup")).toBeNull();
  });
});
