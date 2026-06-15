// Current-Meet (June 2026) extraction — pinned against the FIELD failure of
// 2026-06-11: live tiles carry data-participant-id AND
// data-requested-participant-id, [data-self-name] is gone, and naive text
// reads leaked icon-ligature + localized button labels as display names
// (verbatim field strings below). Fixture: meet_in_call_2026.html
// (reconstructed from the field wire batches, NOT a full live-DOM dump).
import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import S from "../src/selectors.js";
import O from "../src/observer.js";

const FIXTURES = join(dirname(fileURLToPath(import.meta.url)), "fixtures");
const load = () => {
  document.body.innerHTML = readFileSync(
    join(FIXTURES, "meet_in_call_2026.html"),
    "utf8",
  );
};
const tile = (n) =>
  document.querySelector(
    `main [data-requested-participant-id="spaces/demo/devices/${n}"]`,
  );

// Verbatim garbage the OLD extraction shipped in live wire batches.
const FIELD_GARBAGE = [
  "keep_outlineFixar Adrian Cole na tela principal",
  "keep_outlineFixar Maria Silva na tela principal",
  "frame_personReenquadrar",
  "stylus_laser_pointerFaça anotações (visíveis para todos)arrow_drop_upElas vão aparecer para todos",
];

describe("name hygiene primitives", () => {
  it("nameFromPinLabel extracts the embedded name from pt-BR pin labels, icon-glued or clean", () => {
    expect(
      S.nameFromPinLabel("keep_outlineFixar Adrian Cole na tela principal"),
    ).toBe("Adrian Cole");
    expect(S.nameFromPinLabel("Fixar Maria Silva na tela principal")).toBe(
      "Maria Silva",
    );
    expect(S.nameFromPinLabel("Pin Maria Silva to your main screen")).toBe(
      "Maria Silva",
    );
    expect(S.nameFromPinLabel("frame_personReenquadrar")).toBeNull();
    expect(S.nameFromPinLabel("Maria Silva")).toBeNull();
  });

  it("cleanNameCandidate rejects every verbatim field-garbage string that is not a pin label", () => {
    expect(
      S.cleanNameCandidate("keep_outlineFixar Adrian Cole na tela principal"),
    ).toBe("Adrian Cole");
    expect(S.cleanNameCandidate("frame_personReenquadrar")).toBeNull();
    expect(
      S.cleanNameCandidate(
        "stylus_laser_pointerFaça anotações (visíveis para todos)arrow_drop_upElas vão aparecer para todos",
      ),
    ).toBeNull();
    expect(S.cleanNameCandidate("  Anna Reyes ")).toBe("Anna Reyes");
    expect(S.cleanNameCandidate("")).toBeNull();
    expect(S.cleanNameCandidate(null)).toBeNull();
  });

  it("cleanNameCandidate rejects markup junk lifted into the name position (2026-06-11 field)", () => {
    // Verbatim CSS block captured as a .meetExtension attendee/speaker name —
    // rejected on the markup metacharacters ({ } : ;) and newlines.
    expect(
      S.cleanNameCandidate(
        ".ink-canvas-parent {\n          height: 100%;\n          position: relative;\n          width: 100%;\n        }",
      ),
    ).toBeNull();
    // Over-length blob with no markup char is rejected on length alone.
    expect(
      S.cleanNameCandidate("x".repeat(120)),
    ).toBeNull();
    // Real names — including long Brazilian compound names — still pass.
    expect(S.cleanNameCandidate("Leo Marston")).toBe("Leo Marston");
    expect(
      S.cleanNameCandidate("Maria Eduarda da Silva Santos Oliveira"),
    ).toBe("Maria Eduarda da Silva Santos Oliveira");
  });
});

describe("tileName on the 2026 tile shapes", () => {
  it("reads the plain name bar, never hover-control text", () => {
    load();
    expect(S.tileName(tile(2))).toBe("Maria Silva");
  });

  it("harvests the pin label when the name bar is absent (degraded field shape)", () => {
    load();
    expect(S.tileName(tile(3))).toBe("João Pereira");
  });

  it("yields NULL (never icon/menu text) when no name surface exists", () => {
    load();
    expect(S.tileName(tile(4))).toBeNull();
  });

  it("still finds the localized self label in the name bar", () => {
    load();
    expect(S.tileName(tile(1))).toBe("Você");
  });
});

describe("extractRoster on the 2026 fixture", () => {
  it("self by rule 1, names from bar + pin label, null for the surfaceless tile — no garbage ever", () => {
    load();
    const selfModel = new O.SelfModel();
    const roster = O.extractRoster(document, selfModel);
    const byPid = Object.fromEntries(roster.map((r) => [r.participantID, r]));
    expect(byPid["spaces/demo/devices/1"]).toMatchObject({
      isSelf: true,
      displayName: null,
    });
    expect(selfModel.selfParticipantID).toBe("spaces/demo/devices/1");
    expect(byPid["spaces/demo/devices/2"]).toMatchObject({
      displayName: "Maria Silva",
      isSelf: false,
    });
    expect(byPid["spaces/demo/devices/3"]).toMatchObject({
      displayName: "João Pereira",
      isSelf: false,
    });
    expect(byPid["spaces/demo/devices/4"]).toMatchObject({
      displayName: null,
      isSelf: false,
    });
    for (const r of roster) {
      expect(FIELD_GARBAGE).not.toContain(r.displayName);
    }
  });
});

describe("participantFromNode on 2026 tiles (the field bug)", () => {
  // FIELD BUG pinned: tiles carry data-participant-id, and the old code used
  // that attribute to classify the node as a PANEL ROW, then took the first
  // span's text — the pin button's "keep_outlineFixar … na tela principal".
  it("a tile carrying data-participant-id is still named via tileName, not first-span text", () => {
    load();
    const selfModel = new O.SelfModel();
    O.extractRoster(document, selfModel);
    const p = O.participantFromNode(tile(2), selfModel);
    expect(p.displayName).toBe("Maria Silva"); // old code: field garbage
    expect(p.participantID).toBe("spaces/demo/devices/2");
    expect(p.isSelf).toBe(false);
  });

  it("the surfaceless tile attributes by participantID with a null name", () => {
    load();
    const selfModel = new O.SelfModel();
    const p = O.participantFromNode(tile(4), selfModel);
    expect(p.displayName).toBeNull(); // old code: "frame_personReenquadrar"
    expect(p.participantID).toBe("spaces/demo/devices/4");
  });

  it("self tile mutations attribute to self with a null name", () => {
    load();
    const selfModel = new O.SelfModel();
    O.extractRoster(document, selfModel); // learn self pid
    const p = O.participantFromNode(tile(1), selfModel);
    expect(p).toMatchObject({ displayName: null, isSelf: true });
  });

  it("panel listitem rows still go through panelRowName", () => {
    load();
    document.body.insertAdjacentHTML(
      "beforeend",
      `<div role="list"><div role="listitem" data-participant-id="spaces/demo/devices/9"
         aria-label="Carlos Lima"><span>Carlos Lima</span></div></div>`,
    );
    const row = document.querySelector('[role="listitem"]');
    const p = O.participantFromNode(row, new O.SelfModel());
    expect(p).toMatchObject({
      displayName: "Carlos Lima",
      participantID: "spaces/demo/devices/9",
    });
  });
});

describe("panelRowName hygiene on rows with hover controls", () => {
  it("skips button/icon spans and reads the real name span", () => {
    document.body.innerHTML = `
      <div role="list"><div role="listitem" data-participant-id="p1">
        <button><span class="tip"><i class="google-symbols">keep_outline</i>Fixar Ana Souza na tela principal</span></button>
        <span>Ana Souza</span>
      </div></div>`;
    const row = document.querySelector('[role="listitem"]');
    expect(S.panelRowName(row)).toBe("Ana Souza");
  });

  it("falls back to the aria-label, junk-gated", () => {
    document.body.innerHTML = `
      <div role="list"><div role="listitem" data-participant-id="p1" aria-label="Ana Souza">
        <button><span><i class="google-symbols">more_vert</i></span></button>
      </div></div>`;
    const row = document.querySelector('[role="listitem"]');
    expect(S.panelRowName(row)).toBe("Ana Souza");
  });
});
