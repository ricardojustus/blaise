// Roster extraction + self model rules 1–3 (spec "Self model").
import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import O from "../src/observer.js";

const FIXTURES = join(dirname(fileURLToPath(import.meta.url)), "fixtures");
const load = (name) => {
  document.body.innerHTML = readFileSync(join(FIXTURES, name), "utf8");
};

const entry = (roster, pid) => roster.find((r) => r.participantID === pid);

describe("extractRoster on the linked in-call fixture", () => {
  it("rule 1: the 'Você' tile is self with NULL displayName and its participantID", () => {
    load("meet_in_call.html");
    const selfModel = new O.SelfModel();
    const roster = O.extractRoster(document, selfModel);
    const self = entry(roster, "pid-1");
    expect(self).toBeDefined();
    expect(self.isSelf).toBe(true);
    expect(self.displayName).toBeNull();
    expect(selfModel.selfParticipantID).toBe("pid-1");
  });

  it("rule 2: the panel self row sharing the participantID merges into self — the account name never travels as a separate identity", () => {
    load("meet_in_call.html");
    const selfModel = new O.SelfModel();
    const roster = O.extractRoster(document, selfModel);
    // pid-1 appears exactly once, self, null name; "Conta Local" is gone.
    expect(roster.filter((r) => r.participantID === "pid-1")).toHaveLength(1);
    expect(roster.some((r) => r.displayName === "Conta Local")).toBe(false);
  });

  it("extracts named participants from both surfaces, merged by participantID", () => {
    load("meet_in_call.html");
    const roster = O.extractRoster(document, new O.SelfModel());
    expect(roster).toHaveLength(5); // self + 4 named
    expect(entry(roster, "pid-2")).toMatchObject({ displayName: "Maria Silva", isSelf: false });
    expect(entry(roster, "pid-3")).toMatchObject({ displayName: "João Pereira", isSelf: false });
    expect(entry(roster, "pid-4")).toMatchObject({ displayName: "Participante Um", isSelf: false });
    // merged-audio nested row still extracted (adaptive-audio wrinkle)
    expect(entry(roster, "pid-5")).toMatchObject({ displayName: "Ana Souza", isSelf: false });
  });

  it("no localized self label ever appears as a displayName", () => {
    load("meet_in_call.html");
    const roster = O.extractRoster(document, new O.SelfModel());
    for (const r of roster) {
      expect(["You", "Você", "you", "você"]).not.toContain(r.displayName);
    }
  });
});

describe("extractRoster on the UNLINKED self fixture (rule 3)", () => {
  it("the id-less 'You' tile becomes the anonymous self entry", () => {
    load("meet_unlinked_self.html");
    const selfModel = new O.SelfModel();
    const roster = O.extractRoster(document, selfModel);
    const self = roster.find((r) => r.isSelf);
    expect(self).toBeDefined();
    expect(self.displayName).toBeNull();
    expect(self.participantID).toBeUndefined();
    expect(selfModel.selfParticipantID).toBeNull(); // nothing to anchor
  });

  it("the unlinked panel self row flows as an ORDINARY named participant (stated, harmless miss)", () => {
    load("meet_unlinked_self.html");
    const roster = O.extractRoster(document, new O.SelfModel());
    const panelSelf = entry(roster, "pid-9");
    expect(panelSelf).toMatchObject({ displayName: "Conta Local", isSelf: false });
    expect(roster).toHaveLength(3); // anonymous self + Conta Local + Maria
  });
});

describe("rule 2 persistence across scans", () => {
  it("a previously learned self participantID flags panel rows even when the tile is gone", () => {
    load("meet_in_call.html");
    const selfModel = new O.SelfModel();
    O.extractRoster(document, selfModel); // learns pid-1
    // Layout switch: self tile disappears, only the panel remains.
    document.querySelector('[data-requested-participant-id="pid-1"]').remove();
    const roster = O.extractRoster(document, selfModel);
    const self = entry(roster, "pid-1");
    expect(self.isSelf).toBe(true);
    expect(self.displayName).toBeNull();
  });
});

describe("participantFromNode (speaking attribution identity)", () => {
  it("applies the same self rules to mutation-scoped nodes", () => {
    load("meet_in_call.html");
    const selfModel = new O.SelfModel();
    O.extractRoster(document, selfModel); // learns pid-1
    const selfRow = document.querySelector('[data-participant-id="pid-1"]');
    expect(O.participantFromNode(selfRow, selfModel)).toEqual({
      displayName: null,
      participantID: "pid-1",
      isSelf: true,
    });
    const maria = document.querySelector('[data-requested-participant-id="pid-2"]');
    expect(O.participantFromNode(maria, selfModel)).toEqual({
      displayName: "Maria Silva",
      participantID: "pid-2",
      isSelf: false,
    });
  });

  it("pre-join: extractRoster yields an empty roster", () => {
    load("meet_prejoin.html");
    expect(O.extractRoster(document, new O.SelfModel())).toEqual([]);
  });
});
