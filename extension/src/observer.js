// observer.js — roster extraction (self model rules 1–3), the speaking
// MutationObserver, and the __blaiseSnapshot() allowlist sanitizer.
// DOM-dependent but chrome.*-free; vitest exercises it under jsdom.

(() => {
  "use strict";

  const S =
    typeof module !== "undefined" && module.exports
      ? require("./selectors.js")
      : globalThis.BlaiseSelectors;
  const E =
    typeof module !== "undefined" && module.exports
      ? require("./events.js")
      : globalThis.BlaiseEvents;

  // ---- Self model (participantID-anchored; spec rules 1–3). ----
  //
  // Rule 1: a tile whose name position exactly matches the CLOSED localized
  //         set is self → isSelf:true, displayName:null (the meaningless
  //         label never travels), participantID captured when present.
  // Rule 2: once a self participantID is known, ANY entry (tile or panel)
  //         with that participantID is self (same null-name treatment).
  // Rule 3: a panel self row NOT linked by participantID flows as an
  //         ordinary named participant (stated, harmless miss — it carries
  //         the real account name; the listener merges by participantID
  //         and the C4 voter resolves the name correctly).
  class SelfModel {
    constructor() {
      this.selfParticipantID = null;
    }
    noteSelfParticipantID(pid) {
      if (pid && !this.selfParticipantID) this.selfParticipantID = pid;
    }
    isSelfLabel(name) {
      return name !== null && S.SELF_TILE_LABELS.has(name.trim());
    }
    isSelfParticipantID(pid) {
      return pid !== null && pid === this.selfParticipantID;
    }
  }

  /**
   * Extract the current roster from tiles + the People panel (when open).
   * Returns contract-shaped entries: {displayName|null, participantID?, isSelf}.
   * Entries sharing a participantID merge (panel name preferred for display;
   * self wins and nulls the name).
   */
  function extractRoster(doc, selfModel) {
    const byKey = new Map(); // participantID or "name:<displayName>"

    const add = (displayName, participantID, isSelf) => {
      const key = participantID || `name:${displayName}`;
      const prior = byKey.get(key);
      if (prior) {
        if (isSelf) {
          prior.isSelf = true;
        }
        if (displayName && !prior.isSelf && !prior.displayName) {
          prior.displayName = displayName;
        }
        return;
      }
      byKey.set(key, {
        displayName: isSelf ? null : displayName,
        participantID,
        isSelf,
      });
    };

    // Tiles first: rule 1 can learn the self participantID that rule 2
    // then applies to panel rows in the same pass.
    for (const tile of S.findTiles(doc)) {
      const name = S.tileName(tile);
      const pid = S.tileParticipantID(tile);
      if (selfModel.isSelfLabel(name)) {
        selfModel.noteSelfParticipantID(pid);
        add(null, pid, true);
      } else if (name || pid) {
        add(name, pid, false);
      }
    }

    const panel = S.findPanelList(doc);
    if (panel) {
      for (const row of S.panelRows(panel)) {
        const name = S.panelRowName(row);
        const pid = S.panelRowParticipantID(row);
        // Rule 1 also applies if a panel row somehow shows the localized
        // self label; otherwise rule 3: unlinked self rows flow named.
        if (selfModel.isSelfLabel(name)) {
          selfModel.noteSelfParticipantID(pid);
          add(null, pid, true);
        } else if (name || pid) {
          add(name, pid, false);
        }
      }
    }

    // Rule 2 post-pass: anything carrying the known self participantID is
    // self, displayName nulled.
    const roster = [];
    for (const entry of byKey.values()) {
      if (selfModel.isSelfParticipantID(entry.participantID)) {
        entry.isSelf = true;
      }
      if (entry.isSelf) entry.displayName = null;
      roster.push({
        displayName: entry.displayName ?? null,
        ...(entry.participantID ? { participantID: entry.participantID } : {}),
        isSelf: entry.isSelf,
      });
    }
    return roster;
  }

  /** Contract participant for a tile/panel participant node (speaking
   * attribution), applying the same self rules. Null when no identity.
   * FIELD BUG (2026-06-11): current Meet TILES carry data-participant-id
   * too, so attribute presence cannot distinguish a tile from a panel row —
   * doing so read tile hover-button text as names ("keep_outlineFixar
   * Maria Silva na tela principal"). Panel rows are role="listitem";
   * everything else is a tile. */
  function participantFromNode(node, selfModel) {
    const pid =
      node.getAttribute(S.DATA_REQUESTED_PARTICIPANT_ID) ||
      node.getAttribute(S.DATA_PARTICIPANT_ID) ||
      null;
    const name = node.getAttribute("role") === "listitem"
      ? S.panelRowName(node)
      : S.tileName(node);
    if (selfModel.isSelfLabel(name)) {
      selfModel.noteSelfParticipantID(pid);
      return { displayName: null, participantID: pid, isSelf: true };
    }
    if (selfModel.isSelfParticipantID(pid)) {
      return { displayName: null, participantID: pid, isSelf: true };
    }
    if (!name && !pid) return null;
    return { displayName: name ?? null, participantID: pid, isSelf: false };
  }

  /**
   * Speaking observer: body-level MutationObserver (survives Meet layout
   * re-renders) on class attributes, subtree-wide; visibility-checked ticks
   * feed the coalescer, processed at ≤10 Hz. A 1 s watchdog re-attaches if
   * the observed body is ever replaced (sentinel).
   *
   * Injected: doc, coalescer, selfModel, now() (epoch ms),
   * getStyle(el) → CSSStyleDeclaration (stubbed in jsdom tests),
   * schedule(fn, ms) → timer id (setTimeout in production).
   */
  function createSpeakingObserver({
    doc,
    coalescer,
    selfModel,
    now,
    getStyle,
    schedule = (fn, ms) => setTimeout(fn, ms),
    processIntervalMs = E.PROCESS_INTERVAL_MS,
  }) {
    let observedBody = null;
    let pendingNodes = new Set();
    let processScheduled = false;

    const processPending = () => {
      processScheduled = false;
      const nodes = pendingNodes;
      pendingNodes = new Set();
      const t = now();
      for (const node of nodes) {
        const participant = participantFromNode(node, selfModel);
        if (participant) coalescer.tick(participant, t);
      }
    };

    const observer = new (doc.defaultView || globalThis).MutationObserver(
      (records) => {
        for (const r of records) {
          if (r.type !== "attributes" || r.attributeName !== "class") continue;
          const el = r.target;
          if (r.oldValue !== null && r.oldValue === el.className) continue; // no-op mutation
          // Muted-visibility filter: hidden talk bars are not speech.
          if (getStyle(el).display === "none") continue;
          const node = S.participantNodeFor(el);
          if (node) pendingNodes.add(node);
        }
        if (pendingNodes.size > 0 && !processScheduled) {
          processScheduled = true;
          schedule(processPending, processIntervalMs); // ≤ 10 Hz
        }
      },
    );

    const attach = () => {
      observedBody = doc.body;
      observer.observe(observedBody, {
        attributes: true,
        subtree: true,
        attributeFilter: ["class"],
        attributeOldValue: true,
      });
    };

    /** Sentinel: re-attach if the body node was replaced. */
    const watchdog = () => {
      if (doc.body && doc.body !== observedBody) {
        observer.disconnect();
        attach();
        return true;
      }
      return false;
    };

    const detach = () => {
      observer.disconnect();
      observedBody = null;
    };

    return { attach, detach, watchdog, _processPending: processPending };
  }

  // ---- __blaiseSnapshot() allowlist sanitizer. ----
  //
  // Serializes a DOM surface keeping ONLY what selector work needs:
  //   - tag names
  //   - `class`, `role`, the pinned data-* set (selectors.js)
  //   - aria-* attributes with values REWRITTEN (names → synthetic,
  //     everything else → "")
  //   - name-position text → synthetic names; ALL other text dropped
  // Every other attribute (ids, jsname/jscontroller/jsmodel, src, href,
  // style, URLs, everything) is stripped at capture. The localized self
  // labels ("You"/"Você") are preserved verbatim — discovering their
  // structural marker is the snapshot's purpose, and they are not names.
  //
  // Returns { html, digests } where digests = SHA-256 hex of each ORIGINAL
  // replaced name (the gitignored .digests.json sidecar; used locally by
  // the hygiene test, never committed — unsalted digests are
  // dictionary-recoverable).

  const SANITIZE_KEEP_ATTRIBUTES = new Set(["class", "role"]);
  const SYNTHETIC_NAMES = [
    "Participante Um",
    "Maria Silva",
    "João Pereira",
    "Participante Quatro",
    "Ana Souza",
    "Participante Seis",
    "Carlos Lima",
    "Participante Oito",
  ];

  async function sanitizeSurface(rootEl, sha256Hex) {
    const nameMap = new Map(); // original → synthetic
    const pidMap = new Map(); // original pid → synthetic pid
    const digests = new Set();

    const syntheticFor = async (original) => {
      const trimmed = original.trim();
      if (S.SELF_TILE_LABELS.has(trimmed)) return trimmed; // preserve marker
      if (!nameMap.has(trimmed)) {
        nameMap.set(
          trimmed,
          SYNTHETIC_NAMES[nameMap.size % SYNTHETIC_NAMES.length] +
            (nameMap.size >= SYNTHETIC_NAMES.length
              ? ` ${Math.floor(nameMap.size / SYNTHETIC_NAMES.length) + 1}`
              : ""),
        );
        digests.add(await sha256Hex(trimmed));
      }
      return nameMap.get(trimmed);
    };

    const syntheticPid = (original) => {
      if (!pidMap.has(original)) {
        pidMap.set(original, `pid-${pidMap.size + 1}`);
      }
      return pidMap.get(original);
    };

    const isNamePosition = (el) =>
      el.hasAttribute(S.DATA_SELF_NAME) ||
      (el.tagName === "SPAN" && el.closest(`[role="listitem"][${S.DATA_PARTICIPANT_ID}]`) !== null);

    const sanitizeElement = async (el, out) => {
      const node = out; // sanitized twin of el
      // Attributes by strict allowlist.
      for (const attr of Array.from(el.attributes)) {
        const name = attr.name.toLowerCase();
        if (SANITIZE_KEEP_ATTRIBUTES.has(name)) {
          node.setAttribute(name, attr.value);
        } else if (
          name === S.DATA_PARTICIPANT_ID ||
          name === S.DATA_REQUESTED_PARTICIPANT_ID
        ) {
          node.setAttribute(name, syntheticPid(attr.value));
        } else if (name === S.DATA_SELF_NAME) {
          node.setAttribute(name, await syntheticFor(attr.value));
        } else if (name.startsWith("aria-")) {
          // aria values rewritten: the panel ROW's own aria-label carries
          // the name → synthetic; the leave-button labels stay (carve-out
          // #2 marker, not a name); everything else — including labels on
          // row-inner chrome like a "More actions" button — empties.
          const value = attr.value.trim();
          if (S.LEAVE_BUTTON_ARIA_LABELS.includes(value)) {
            node.setAttribute(name, value);
          } else if (
            name === "aria-label" &&
            el.matches(`[role="listitem"][${S.DATA_PARTICIPANT_ID}]`)
          ) {
            node.setAttribute(name, await syntheticFor(attr.value));
          } else {
            node.setAttribute(name, "");
          }
        }
        // everything else: dropped
      }
      // Children: elements recurse; text survives ONLY at name positions.
      for (const child of Array.from(el.childNodes)) {
        if (child.nodeType === 1) {
          const twin = node.ownerDocument.createElement(
            child.tagName.toLowerCase(),
          );
          node.appendChild(twin);
          await sanitizeElement(child, twin);
        } else if (child.nodeType === 3) {
          const text = child.textContent.trim();
          if (text && isNamePosition(el)) {
            node.appendChild(
              node.ownerDocument.createTextNode(await syntheticFor(text)),
            );
          }
        }
      }
    };

    const doc = rootEl.ownerDocument;
    const twin = doc.createElement(rootEl.tagName.toLowerCase());
    await sanitizeElement(rootEl, twin);
    return { html: twin.outerHTML, digests: Array.from(digests) };
  }

  const BlaiseObserver = {
    SelfModel,
    extractRoster,
    participantFromNode,
    createSpeakingObserver,
    sanitizeSurface,
    SANITIZE_KEEP_ATTRIBUTES,
    SYNTHETIC_NAMES,
  };

  globalThis.BlaiseObserver = BlaiseObserver;
  if (typeof module !== "undefined" && module.exports) {
    module.exports = BlaiseObserver;
  }
})();
