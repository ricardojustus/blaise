// selectors.js — the SINGLE rotation point for every Meet DOM dependency.
//
// When Meet changes its DOM, this file (plus the fixtures) is the only thing
// that should need editing. Strategies are structural / data-attribute first;
// localized text is banned except the three bounded carve-outs marked
// CARVE-OUT below, all scheduled for replacement by structural markers
// discovered from the real sanitized snapshot at the live-Meet Human
// Touchpoint (see extension/README.md, "Updating selectors").
//
// Source annotations: each strategy cites where it was observed and the date
// it was last verified against a live source (research/c12_meet_extension.md
// has the full evidence table).
//
// Loaded as a classic script in the content-script world (globalThis
// namespace) and as a CommonJS module under vitest.

(() => {
  "use strict";

  // ---- Pinned data-* attributes (the allowlist the snapshot sanitizer
  // also uses). Stable across 2022→2026 sources; rotated rarely if ever. ----

  // People-panel row id. Source: meetingbot src/bots/meet/src/bot.ts
  // (verified 2026-06-10, repo pushed 2026-04-09); talk-time (2024).
  const DATA_PARTICIPANT_ID = "data-participant-id";

  // Video-tile id, same value space as the panel id. Source: meetingbot
  // (verified 2026-06-10).
  const DATA_REQUESTED_PARTICIPANT_ID = "data-requested-participant-id";

  // Name label div present on EVERY participant tile (not just self,
  // despite the attribute name); attribute value carries the name. Source:
  // talk-o-meter (2024), Lechner Medium post (2022); still present per
  // research 2026-06-10.
  const DATA_SELF_NAME = "data-self-name";

  const PINNED_DATA_ATTRIBUTES = [
    DATA_PARTICIPANT_ID,
    DATA_REQUESTED_PARTICIPANT_ID,
    DATA_SELF_NAME,
  ];

  // ---- Name-text hygiene (current Meet, June 2026). ----
  //
  // FIELD EVIDENCE (live capture, meeting abc-defg-hij): current
  // Meet tiles carry BOTH data-participant-id and data-requested-participant-id
  // (value shape "spaces/<space>/devices/<n>"), the [data-self-name] label is
  // GONE, and naive text reads leak hover-toolbar content — Material icon
  // ligature text glued to localized button labels, e.g.:
  //   "keep_outlineFixar Maria Silva na tela principal"  (pin button,
  //     pt-BR "Pin <name> to your main screen" — carries the participant name)
  //   "frame_personReenquadrar"                              (reframe, no name)
  // Defenses, in order: (1) icon-font elements are excluded from all name
  // text; (2) button/menu/tooltip subtrees are excluded from plain-name
  // positions; (3) pin-button labels are MINED for the embedded name via the
  // bounded localized templates below; (4) any candidate still containing an
  // underscore (icon-ligature shape; real display names with underscores are
  // sacrificed — nil name beats wrong name) is rejected.

  /** Icon-font classes observed on live Meet (google-symbols verified via
   * TranscripTonic 2026-06; material-* kept for older shapes). */
  const ICON_CLASS_PATTERN = /(?:^|\s)(?:google-symbols|google-material-icons|material-icons(?:-[a-z]+)?|material-symbols(?:-[a-z]+)?)(?:\s|$)/;

  function isIconElement(el) {
    if (!el || el.nodeType !== 1) return false;
    if (el.tagName === "I") return true;
    const cls = typeof el.className === "string" ? el.className : "";
    return ICON_CLASS_PATTERN.test(cls);
  }

  /** Containers whose text is UI chrome, never a plain name position. */
  const NON_NAME_CONTAINER_SELECTOR =
    'button, [role="button"], [role="menu"], [role="menuitem"], [role="tooltip"], [aria-hidden="true"], [data-tooltip]';

  // ---- CARVE-OUT #3 (bounded, localized): pin-button name templates. ----
  // The tile pin control's label embeds the participant's full display name.
  // pt-BR template FIELD-VERIFIED 2026-06-11 ("Fixar <name> na tela
  // principal"); the en template mirrors Google's documented control wording
  // ("Pin <name> to your main screen") and is NOT yet live-verified. Other
  // locales degrade safely: the ligature/underscore junk guard rejects them.
  const PIN_LABEL_TEMPLATES = [
    { prefix: "Fixar ", suffix: " na tela principal" },
    { prefix: "Pin ", suffix: " to your main screen" },
  ];

  /** Extract the embedded display name from a pin-button label (or any text
   * that CONTAINS one — icon ligatures glue to the front in innerText reads).
   * Returns null when no template matches. */
  function nameFromPinLabel(text) {
    if (!text) return null;
    for (const { prefix, suffix } of PIN_LABEL_TEMPLATES) {
      const start = text.indexOf(prefix);
      if (start === -1) continue;
      if (!text.endsWith(suffix)) continue;
      const name = text.slice(start + prefix.length, text.length - suffix.length).trim();
      if (name) return name;
    }
    return null;
  }

  /** Final hygiene gate for any name candidate. Underscores are the
   * icon-ligature signature ("keep_outline", "frame_person"); a real
   * display name containing one is sacrificed (nil beats wrong). */
  // A human display name is one short line of text. The 2026-06-11 field
  // capture showed whole CSS/JS blocks and UI sentences lifted into the name
  // position; none carries an underscore, so the ligature gate let them
  // through. Reject anything not name-shaped: markup/structural metacharacter
  // ({ } < > ; = newline/tab) or longer than any real display name.
  const MAX_NAME_LENGTH = 80;
  const MARKUP_CHARS = /[{}<>;=\n\r\t]/;
  function isNameShaped(candidate) {
    return (
      candidate.length <= MAX_NAME_LENGTH &&
      !candidate.includes("_") &&
      !MARKUP_CHARS.test(candidate)
    );
  }
  function cleanNameCandidate(raw) {
    if (!raw) return null;
    const trimmed = raw.trim();
    if (!trimmed) return null;
    const pinned = nameFromPinLabel(trimmed);
    if (pinned) return isNameShaped(pinned) ? pinned : null;
    return isNameShaped(trimmed) ? trimmed : null;
  }

  /** Concatenated text of el EXCLUDING icon-font elements and (optionally)
   * UI-chrome containers (buttons/menus/tooltips). */
  function nameText(el, { excludeChrome = true } = {}) {
    return textLeaves(el, { excludeChrome }).join("").trim();
  }

  /** Non-empty text-node values under el, in document order, skipping
   * icon-font elements and (optionally) UI-chrome containers. Per-node
   * granularity matters: pin labels must be template-matched against the
   * single text node that carries them, never against a concatenation. */
  function textLeaves(el, { excludeChrome = true } = {}) {
    const out = [];
    const walk = (node) => {
      for (const child of node.childNodes) {
        if (child.nodeType === 3) {
          if (child.textContent.trim()) out.push(child.textContent);
        } else if (child.nodeType === 1) {
          if (isIconElement(child)) continue;
          if (excludeChrome && child.matches(NON_NAME_CONTAINER_SELECTOR)) continue;
          walk(child);
        }
      }
    };
    walk(el);
    return out;
  }

  // ---- CARVE-OUT #1 (bounded, interim): localized self-tile label. ----
  // The self TILE's name position shows "You" (en) / "Você" (pt-BR), which
  // is a localized marker, not a name. This CLOSED set is the interim self
  // detector (spec self-model rule 1); the Touchpoint snapshot replaces it
  // with a structural marker. The listener-side denylist
  // (docs/meet_events_contract.md) is the belt to these braces if Meet
  // rotates the label. Last verified: TranscripTonic resolves self as "You"
  // (2026-06-03 source).
  const SELF_TILE_LABELS = new Set(["You", "Você", "you", "você"]);

  // ---- CARVE-OUT #2 (bounded, interim): in-call detector. ----
  // Honest statement: a purely structural in-call marker could not be pinned
  // from the OSS references (they wait on aria-labels or the Participants
  // panel). Interim: the leave-call button identified by a CLOSED aria-label
  // set (en + pt-BR); that button set is the SOLE signal. Replaced by the
  // snapshot-derived structural marker at the Touchpoint. Source for the
  // wait-for-end-call-button pattern: TranscripTonic (2026-06-03).
  const LEAVE_BUTTON_ARIA_LABELS = ["Leave call", "Sair da chamada"];

  /** True when the in-call UI is present (joined state). Pre-join preview
   * must return false: the preview has no leave-call control bar. */
  function isInCall(doc) {
    for (const label of LEAVE_BUTTON_ARIA_LABELS) {
      if (doc.querySelector(`button[aria-label="${label}"]`)) return true;
    }
    return false;
  }

  // ---- People panel (open-only; never opened by the extension). ----

  /** The participants list, found STRUCTURALLY: a role="list" element whose
   * listitems carry data-participant-id. Never matched by the localized
   * aria-label ("Participants"/"Participantes"). Source: meetingbot +
   * talk-time shape, structural matching per recall.ai advice
   * (verified 2026-06-10). Returns null when the panel is closed. */
  function findPanelList(doc) {
    for (const list of doc.querySelectorAll('[role="list"]')) {
      if (list.querySelector(`[role="listitem"][${DATA_PARTICIPANT_ID}]`)) {
        return list;
      }
    }
    return null;
  }

  /** Rows of the panel list, including rows nested under a "merged audio"
   * grouping node (adaptive audio wrinkle — meetingbot handles the same way:
   * any descendant carrying the id attribute counts). */
  function panelRows(listEl) {
    return Array.from(
      listEl.querySelectorAll(`[role="listitem"][${DATA_PARTICIPANT_ID}]`),
    );
  }

  /** Display name of a panel row: first span with non-empty NAME text
   * (icon-font elements and button/menu/tooltip subtrees excluded — field
   * 2026-06-11: naive first-span reads return hover-control text), falling
   * back to the row's aria-label (meetingbot reads aria-label = display
   * name). All candidates pass the ligature-junk gate. */
  function panelRowName(row) {
    for (const span of row.querySelectorAll("span")) {
      if (span.closest(NON_NAME_CONTAINER_SELECTOR)) continue;
      if (isIconElement(span)) continue;
      const text = cleanNameCandidate(nameText(span));
      if (text) return text;
    }
    return cleanNameCandidate(row.getAttribute("aria-label"));
  }

  function panelRowParticipantID(row) {
    return row.getAttribute(DATA_PARTICIPANT_ID) || null;
  }

  // ---- Video tiles (always rendered for on-screen participants). ----

  /** All rendered participant tiles. Primary: data-requested-participant-id
   * elements. Tiles that lack the id attribute are still discovered through
   * their data-self-name name label (ancestor walk). Sources: meetingbot
   * (id attr), talk-o-meter (name label), verified 2026-06-10. */
  function findTiles(doc) {
    const tiles = new Set(
      doc.querySelectorAll(`[${DATA_REQUESTED_PARTICIPANT_ID}]`),
    );
    for (const nameEl of doc.querySelectorAll(`[${DATA_SELF_NAME}]`)) {
      const tile = nameEl.closest(`[${DATA_REQUESTED_PARTICIPANT_ID}]`);
      if (tile) {
        tiles.add(tile);
      } else if (!nameEl.closest('[role="listitem"]')) {
        // Orphan name label outside the panel: treat the label element
        // itself as the tile anchor (degraded but capturable).
        tiles.add(nameEl);
      }
    }
    return Array.from(tiles);
  }

  /** Name at a tile's name position. Strategies, in order:
   *  1. LEGACY [data-self-name] label (pre-June-2026 shape; text wins over
   *     the attribute value — attribute observed stale on rename in
   *     talk-o-meter issues). Kept because buffered DOMs and tests still
   *     exercise it; harmless when absent.
   *  2. Pin-button label mining (CARVE-OUT #3): the tile's pin control
   *     embeds the full display name — the ONLY name surface confirmed by
   *     the 2026-06-11 field capture. Reads button aria-labels first, then
   *     any tile text containing a template (tooltip spans).
   *  3. Plain name-position text: first text leaf NOT inside icon/button/
   *     menu/tooltip subtrees (the visible name bar; reconstructed shape,
   *     not field-confirmed — see test/fixtures/meet_in_call_2026.html).
   * Every candidate passes the ligature-junk gate; null beats wrong. */
  function tileName(tile) {
    // 1: legacy label
    const el = tile.hasAttribute && tile.hasAttribute(DATA_SELF_NAME)
      ? tile
      : tile.querySelector(`[${DATA_SELF_NAME}]`);
    if (el) {
      const text = cleanNameCandidate(nameText(el));
      if (text) return text;
      const attr = cleanNameCandidate(el.getAttribute(DATA_SELF_NAME));
      if (attr) return attr;
    }
    if (!tile.querySelectorAll) return null;
    // 2: pin-button label (aria-label, then any single text leaf carrying a
    // template — tooltip spans; leaves scanned individually because the
    // template suffix must close the leaf, as in the field-captured
    // "keep_outlineFixar Maria Silva na tela principal")
    for (const button of tile.querySelectorAll('button[aria-label], [role="button"][aria-label]')) {
      const name = cleanNameCandidate(nameFromPinLabel(button.getAttribute("aria-label")));
      if (name) return name;
    }
    for (const leaf of textLeaves(tile, { excludeChrome: false })) {
      const name = cleanNameCandidate(nameFromPinLabel(leaf.trim()));
      if (name) return name;
    }
    // 3: plain name-position text: the FIRST clean text leaf outside UI
    // chrome (the visible name bar; reconstructed shape, not field-confirmed).
    // cleanNameCandidate extracts the name when the leaf is itself a pin
    // label, so a tooltip leaf here still yields a NAME, never the template.
    for (const leaf of textLeaves(tile)) {
      const name = cleanNameCandidate(leaf);
      if (name) return name;
    }
    return null;
  }

  function tileParticipantID(tile) {
    const host = tile.closest
      ? tile.closest(`[${DATA_REQUESTED_PARTICIPANT_ID}]`)
      : null;
    return host
      ? host.getAttribute(DATA_REQUESTED_PARTICIPANT_ID) || null
      : null;
  }

  // ---- Active-speaker signal scope. ----

  /** Given the target element of a class-attribute mutation, the enclosing
   * participant node (tile or panel row), or null when the mutation is
   * outside any participant scope. Mutation-presence (not class identity)
   * is the signal — class-rotation-proof per meetingbot/talk-time
   * (verified 2026-06-10). */
  function participantNodeFor(el) {
    if (!el || !el.closest) return null;
    return (
      el.closest(`[${DATA_REQUESTED_PARTICIPANT_ID}]`) ||
      el.closest(`[role="listitem"][${DATA_PARTICIPANT_ID}]`) ||
      null
    );
  }

  // ---- Meeting identity. ----

  /** Meeting code from the URL path: meet.google.com/abc-defg-hij[?...].
   * meet.google.com/lookup/<alias> paths use the alias as the code; other
   * non-meeting segments (landing, new) yield null. */
  function meetingCodeFromURL(href) {
    let path;
    try {
      path = new URL(href).pathname;
    } catch {
      return null;
    }
    const canonical = path.match(/^\/([a-z]{3}-[a-z]{4}-[a-z]{3})(?:\/|$)/);
    if (canonical) return canonical[1];
    const lookup = path.match(/^\/lookup\/([A-Za-z0-9_-]+)(?:\/|$)/);
    if (lookup) return lookup[1];
    const segment = path.match(/^\/([A-Za-z0-9_-]+)(?:\/|$)/);
    if (!segment) return null;
    if (segment[1] === "landing" || segment[1] === "new" || segment[1] === "lookup") {
      return null;
    }
    return segment[1];
  }

  const BlaiseSelectors = {
    DATA_PARTICIPANT_ID,
    DATA_REQUESTED_PARTICIPANT_ID,
    DATA_SELF_NAME,
    PINNED_DATA_ATTRIBUTES,
    SELF_TILE_LABELS,
    LEAVE_BUTTON_ARIA_LABELS,
    PIN_LABEL_TEMPLATES,
    NON_NAME_CONTAINER_SELECTOR,
    isIconElement,
    nameFromPinLabel,
    cleanNameCandidate,
    nameText,
    textLeaves,
    isInCall,
    findPanelList,
    panelRows,
    panelRowName,
    panelRowParticipantID,
    findTiles,
    tileName,
    tileParticipantID,
    participantNodeFor,
    meetingCodeFromURL,
  };

  globalThis.BlaiseSelectors = BlaiseSelectors;
  if (typeof module !== "undefined" && module.exports) {
    module.exports = BlaiseSelectors;
  }
})();
