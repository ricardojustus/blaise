import Foundation

/// #101: a grounded person-mention hint — one canonical person, plus the
/// everyday word(s) that person is sometimes MIS-TRANSCRIBED as (the
/// `.lexiconWord`-rejected glossary aliases). It is rendered, presence-gated,
/// in the LLM USER MESSAGE of the notes + digest prompts as a CONDITIONAL,
/// per-occurrence "leave-by-default" hint — it is NOT a substitution list and
/// never reaches any deterministic correction gate.
///
/// A hint is emitted when BOTH:
///   (a) the canonical comes from a CURATED glossary everyday-alias mapping
///       (`Canonical | everyday-surface`) — that curation IS the grounding (the
///       user's own data, not the circular self-grounding the model could
///       invent); a participant / full-name body match only RANKS it higher for
///       the per-meeting cap, AND
///   (b) the everyday surface actually appears in the corrected transcript body
///       (else there is nothing in the body to read as the person).
///
/// The everyday surface is the WORD as ASR wrote it (e.g. "riso"); `canonical`
/// is the person's name as the glossary spells it.
public struct GroundedPersonHint: Sendable, Equatable, Codable {
    public let canonical: String
    public let everydaySurfaces: [String]

    public init(canonical: String, everydaySurfaces: [String]) {
        self.canonical = canonical
        self.everydaySurfaces = everydaySurfaces
    }
}

/// #101: the standalone, digest-AGNOSTIC derivation of the grounded
/// person-mention hints for one meeting. Pure and app-owned (the model never
/// hand-authors these). Shared, IDENTICALLY, by both notes request-build sites
/// (full-run stage-9 + notes-only resume) and the digest entry
/// (`generateMemoryDigest`), so the resume request stays byte-equal to the
/// full run. Reuses `DigestStructuredInputs.nameIsBodyGrounded` as the
/// fold/grounding authority — it does NOT depend on `DigestRequest`.
public enum GroundedPersonHints {
    /// Hard caps (D8/D9): the most hints a single meeting may carry, the most
    /// everyday surfaces a single hint may carry, and the per-string length cap
    /// applied AFTER newline/control-char stripping and Unicode normalization.
    /// These bound prompt growth and injection surface; suppressed hints are not
    /// an error (precision-biased v1).
    static let maxHintsPerMeeting = 12
    static let maxSurfacesPerHint = 6
    static let maxRenderedLength = 80

    /// Derive the grounded person-mention hints from the run vocabulary's
    /// everyday-rejected aliases, the meeting attendees, and the corrected
    /// transcript segments. Applies, IN ORDER:
    ///   (a) GROUNDING — every everyday-rejected canonical is a CURATED glossary
    ///       mapping, which IS the grounding; the person-slot tier (attendees ∪
    ///       resolved speakerNames, strength 2) and the full-name body-match tier
    ///       (`nameIsBodyGrounded`, strength 1) only RANK it for the cap, above a
    ///       glossary-only mapping (strength 0). No INDEPENDENT presence required.
    ///   (b) SURFACE-PRESENT gate (F3) — emit a surface ONLY when that everyday
    ///       surface actually occurs in the corrected transcript body.
    ///   (c) COLLISION-OMIT (D8) — if one surface maps to >1 grounded canonical,
    ///       OMIT that surface entirely (ambiguous → no hint for it).
    ///   (d) INJECTION-HARDENING (D9) — strip newlines/control chars,
    ///       length-cap, and Unicode-normalize (NFC) every canonical + surface.
    ///   (e) CAP per meeting (D8), ranked by grounding strength; drop empties.
    public static func groundedPersonHints(
        vocabulary: PipelineVocabulary,
        attendees: [Attendee],
        segments: [TranscriptSegment]
    ) -> [GroundedPersonHint] {
        let rejected = vocabulary.everydayRejectedAliases
        guard !rejected.isEmpty else { return [] }

        // The person-slot grounding pool: attendee names ∪ resolved speaker
        // names, folded to the canonical (diacritic-insensitive) core-join set.
        // Person-slot membership is the PRIMARY grounding (a participant /
        // resolved speaker), distinct from a body full-name match.
        let personSlotKeys: Set<String> = {
            var names: [String] = attendees.map(\.name)
            names.append(contentsOf: segments.compactMap(\.speakerName))
            return Set(names.map(canonicalKey).filter { !$0.isEmpty })
        }()

        // Admitted (non-everyday) aliases per canonical — the alternative
        // grounding surfaces for a canonical besides the canonical itself. These
        // are the dictionary's KEPT aliases (the everyday-rejected ones never
        // made it into `dictionary.entries`).
        var admittedAliasesByCanonical: [String: [String]] = [:]
        for entry in vocabulary.dictionary.entries {
            admittedAliasesByCanonical[entry.canonical, default: []]
                .append(contentsOf: entry.aliases)
        }

        // Group everyday-rejected surfaces by canonical (dedup surfaces within a
        // canonical, case-insensitively, first-spelling wins), preserving the
        // admission order of canonicals.
        var order: [String] = []
        var surfacesByCanonical: [String: [String]] = [:]
        var seenSurface: [String: Set<String>] = [:]
        for pair in rejected {
            let canonical = pair.canonical
            if surfacesByCanonical[canonical] == nil {
                order.append(canonical)
                surfacesByCanonical[canonical] = []
                seenSurface[canonical] = []
            }
            let key = surfaceKey(pair.alias)
            guard !key.isEmpty, seenSurface[canonical]?.contains(key) == false else { continue }
            seenSurface[canonical]?.insert(key)
            surfacesByCanonical[canonical]?.append(pair.alias)
        }

        // (a) GROUNDING — every everyday-rejected canonical comes from a CURATED
        // glossary mapping (`Canonical | everyday-surface`), which is itself valid,
        // meeting-independent grounding (the user's data — not the circular
        // self-grounding the model could invent). So a glossary mapping ALWAYS
        // qualifies; the surface-present gate (b) below still requires the everyday
        // word to actually occur in this meeting before any hint renders. The
        // grounding STRENGTH only RANKS the per-meeting cap.
        //
        // (#101 fix — approved override of the v1 "the everyday surface never
        // self-grounds (circular)" rule + the Codex circular-grounding caveat: the
        // v1 gate discarded the ONLY signal in the case the feature exists for — an
        // ad-hoc meeting with NO attendees where ASR garbled a surname into a common
        // everyday word and the clean full name never appears in the body. The model
        // discriminates person-vs-everyday per occurrence under the strongly
        // leave-by-default BLOCK 1 rule, and the combined audit reverts doubtful
        // resolutions.)
        struct GroundedGroup { let canonical: String; let surfaces: [String]; let strength: Int }
        var grounded: [GroundedGroup] = []
        for canonical in order {
            guard let surfaces = surfacesByCanonical[canonical], !surfaces.isEmpty else { continue }
            // Candidate grounding tokens for the STRENGTH tiers: the canonical name
            // itself + its admitted NON-everyday aliases (the everyday rejected
            // surfaces are excluded from the person-slot / full-name tiers — those
            // measure INDEPENDENT presence; the glossary-only tier needs none).
            let groundingNames = [canonical] + (admittedAliasesByCanonical[canonical] ?? [])
            let primary = groundingNames.contains { personSlotKeys.contains(canonicalKey($0)) }
            // A multi-token (surname-present) contiguous body match.
            // `nameIsBodyGrounded` is contiguous + token-boundary; require >1 token
            // so the full-name tier reflects genuine spelled-out evidence.
            let secondary = !primary && groundingNames.contains { name in
                isMultiToken(name) && DigestStructuredInputs.nameIsBodyGrounded(name, in: segments)
            }
            // strength 2 = participant/resolved speaker; 1 = full-name body match;
            // 0 = the curated glossary mapping alone (no independent presence).
            let strength = primary ? 2 : (secondary ? 1 : 0)
            grounded.append(GroundedGroup(canonical: canonical, surfaces: surfaces, strength: strength))
        }
        guard !grounded.isEmpty else { return [] }

        // (c) COLLISION-OMIT (D8), strength-aware: a surface shared by >1 grounded
        // canonical is ambiguous. Resolve by grounding STRENGTH — keep the surface
        // ONLY for a canonical that strictly outranks every OTHER canonical sharing
        // it; otherwise (a tie at the top) omit it from all. This stops a present
        // (participant / full-name) person's hint from being suppressed by an
        // ABSENT glossary-only row (strength 0) that happens to share the everyday
        // word, while still omitting genuinely ambiguous same-tier collisions (two
        // participants, or two glossary-only canonicals). Before the glossary-
        // grounding change every grounded canonical had independent evidence, so a
        // plain count sufficed; now strength-0 rows can share a surface with a
        // present person, so the resolution must be strength-aware.
        var strengthsPerSurfaceKey: [String: [(canonical: String, strength: Int)]] = [:]
        for group in grounded {
            for surface in group.surfaces {
                let key = surfaceKey(surface)
                guard !key.isEmpty else { continue }
                strengthsPerSurfaceKey[key, default: []].append(
                    (canonicalKey(group.canonical), group.strength))
            }
        }
        // A (surface, canonical) keeps the surface iff this canonical's strength is
        // strictly greater than the max strength among the OTHER canonicals on it.
        func surfaceKept(_ key: String, canonical: String, strength: Int) -> Bool {
            let maxOther = (strengthsPerSurfaceKey[key] ?? [])
                .filter { $0.canonical != canonical }
                .map(\.strength).max()
            guard let maxOther else { return true }  // unique on this surface → keep
            return strength > maxOther
        }

        // (b) SURFACE-PRESENT gate (F3) + (c) collision drop + (d) injection
        // hardening, surface-wise; then drop emptied groups.
        let bodyKeys = bodyCoreKeySet(segments)
        var hints: [(hint: GroundedPersonHint, strength: Int)] = []
        for group in grounded {
            var keptSurfaces: [String] = []
            var seen: Set<String> = []
            for surface in group.surfaces {
                let key = surfaceKey(surface)
                guard !key.isEmpty else { continue }
                // (c) strength-aware collision-omit.
                guard surfaceKept(key, canonical: canonicalKey(group.canonical), strength: group.strength)
                else { continue }
                // (b) the everyday surface must actually be in the body.
                guard bodyKeys.contains(key) else { continue }
                let clean = harden(surface)
                guard !clean.isEmpty else { continue }
                let cleanKey = surfaceKey(clean)
                guard seen.insert(cleanKey.isEmpty ? clean.lowercased() : cleanKey).inserted else { continue }
                keptSurfaces.append(clean)
                if keptSurfaces.count >= maxSurfacesPerHint { break }
            }
            guard !keptSurfaces.isEmpty else { continue }
            let cleanCanonical = harden(group.canonical)
            guard !cleanCanonical.isEmpty else { continue }
            hints.append((
                GroundedPersonHint(canonical: cleanCanonical, everydaySurfaces: keptSurfaces),
                group.strength))
        }
        guard !hints.isEmpty else { return [] }

        // (e) CAP per meeting, ranked by grounding strength (stable within a
        // strength tier — keeps admission order). Drop the weakest beyond the cap.
        let ranked = hints.enumerated()
            .sorted { ($0.element.strength, -$0.offset) > ($1.element.strength, -$1.offset) }
            .map(\.element.hint)
        return Array(ranked.prefix(maxHintsPerMeeting))
    }

    // MARK: - Block rendering (byte-exact, LOCKED Council #2 strings)

    /// BLOCK 1 — the NOTES + DIGEST-SYNTHESIS header + rule (LOCKED, byte-exact).
    /// Rendered ONLY when there is at least one hint; the per-person BLOCK 2 lines
    /// follow it. Shared verbatim by both the notes and the digest user messages.
    static let block1Header = """
        CONDITIONAL PERSON MENTIONS (NOT a substitution list — the DEFAULT is to LEAVE the word exactly as written):
        Some people in the vocabulary are sometimes mis-transcribed as an ordinary everyday word. For each line below, decide SEPARATELY FOR EACH OCCURRENCE of the word: the same word may be the person in one sentence and the ordinary everyday word in the next. Read an occurrence as the person ONLY when that sentence's own wording clearly refers to a person — the word is the grammatical agent of a person-action (it says / asks / decides / will do / owns something), the word is directly addressed, the word is credited with an opinion or an action, or the word is assigned ownership of a task or item — AND the ordinary everyday reading does not fit there. In EVERY other case — any ambiguous occurrence, and every occurrence used in its ordinary everyday sense — leave the word EXACTLY as written. This is glossary presence only; it is NOT evidence that the person is present or referred to. Never introduce a person the sentence does not itself support, and never change an occurrence you are unsure about.
        """

    /// BLOCK 3 — the DIGEST COMBINED-AUDIT reconciliation clause (LOCKED,
    /// byte-exact). Appended by `combinedAuditUserMessage` AFTER the base
    /// userMessage hint block, inside the STEP 1 VERIFY frame.
    static let block3AuditClause = """
        CONDITIONAL PERSON-MENTION RECONCILIATION (STEP 1 — read together with the CONDITIONAL PERSON MENTIONS above; subordinate to the RECALL GUARD):
        The draft above may already read one of the listed everyday words as the person it can be mis-transcribed as. For such a person, the transcript body contains the everyday SURFACE word, not the person's spelled-out name — so the everyday surface in the body IS that name's transcript-body grounding. Therefore do NOT apply the UNGROUNDED NAME rule (2) to demote, or the PHANTOM ENTITY rule (4) to remove, such a name SOLELY because its surname (or spelled-out form) is absent from the body. This exception is NARROW: it covers ONLY a name that (a) appears in the CONDITIONAL PERSON MENTIONS list AND (b) the DRAFT ITSELF already resolved. KEEP such a resolution only where that sentence clearly supports a person (the resolved word is the grammatical agent of a person-action, is directly addressed, is credited an opinion or action, or owns a task). Where the sentence does NOT clearly support a person — it is ambiguous, or plainly the ordinary everyday word, or contradicted by the transcript (wrong speaker, wrong action) — REVERT that occurrence to the ordinary everyday word it was mis-transcribed as; reverting to the verbatim transcript word loses no recall, so the RECALL GUARD does not require keeping a doubtful person-resolution. You must NOT yourself newly resolve any everyday word the draft left as the ordinary word, and you must NOT convert any further occurrence. The hint is NOT evidence by itself.
        """

    /// One BLOCK 2 per-person line (LOCKED, byte-exact format). The locked
    /// template is:
    ///   `- The everyday word "<surface>" (e.g. also "<surface2>") is occasionally
    ///    a mis-transcription of the person <Canonical Name>; apply the rule above
    ///    per occurrence.`
    /// The `(e.g. also "<surface2>")` parenthetical is the SECONDARY-surface
    /// affordance: it lists every surface BEYOND the first, joined by `, `. When a
    /// hint carries a single surface there is no secondary surface, so the
    /// parenthetical is omitted (the locked template's `<surface2>` slot has no
    /// value to fill — emitting `also "<surface>"` would echo the only word).
    static func block2Line(for hint: GroundedPersonHint) -> String {
        let surfaces = hint.everydaySurfaces
        let primary = surfaces.first ?? ""
        let alsoSurfaces = surfaces.dropFirst()
        let alsoClause = alsoSurfaces.isEmpty
            ? ""
            : " (e.g. also " + alsoSurfaces.map { "\"\($0)\"" }.joined(separator: ", ") + ")"
        return "- The everyday word \"\(primary)\"\(alsoClause) is occasionally a mis-transcription of the person \(hint.canonical); apply the rule above per occurrence."
    }

    /// The full presence-gated NOTES + DIGEST-SYNTHESIS hint block (BLOCK 1 header
    /// + one BLOCK 2 line per hint), or `nil` when there are no hints (so the
    /// caller appends NOTHING and the user message stays byte-identical). Shared
    /// verbatim by the notes and digest userMessage builders.
    static func synthesisBlock(_ hints: [GroundedPersonHint]) -> String? {
        guard !hints.isEmpty else { return nil }
        let lines = hints.map(block2Line(for:))
        return block1Header + "\n" + lines.joined(separator: "\n")
    }

    // MARK: - Folding / matching helpers (mirror the corrector's authorities)

    /// Replace control characters (incl. newlines) with a space BEFORE folding,
    /// so an injection-laden canonical/surface still tokenizes, grounds, and gates
    /// the same way its hardened render reads. A no-op on clean text (no control
    /// chars → unchanged), so it never perturbs the byte-identical clean path.
    private static func controlStripped(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: {
            $0.properties.generalCategory == .control || CharacterSet.newlines.contains($0)
        }) else { return s }
        return String(s.unicodeScalars.map { scalar -> Character in
            (scalar.properties.generalCategory == .control || CharacterSet.newlines.contains(scalar))
                ? " " : Character(scalar)
        })
    }

    /// Canonical-mode (diacritic-insensitive) single-string core join — used for
    /// person-slot membership and per-canonical identity. Mirrors
    /// `DigestStructuredInputs`' canonical fold of a name (control chars stripped
    /// first so matching agrees with the hardened render).
    private static func canonicalKey(_ s: String) -> String {
        VocabTokenizer.tokenize(controlStripped(s))
            .map { VocabNormalization.canonicalMode($0.core) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The folded core key for an everyday SURFACE (single everyday word). The
    /// surface is one token; the join collapses to that token's canonical fold.
    private static func surfaceKey(_ s: String) -> String { canonicalKey(s) }

    /// The set of ALL single-token canonical-fold core keys present in the
    /// corrected transcript body — the membership test for the F3 surface-present
    /// gate (an everyday surface is one token).
    private static func bodyCoreKeySet(_ segments: [TranscriptSegment]) -> Set<String> {
        var keys: Set<String> = []
        for segment in segments {
            for token in VocabTokenizer.tokenize(controlStripped(segment.text)) {
                let core = VocabNormalization.canonicalMode(token.core)
                if !core.isEmpty { keys.insert(core) }
            }
        }
        return keys
    }

    /// True when `name` carries more than one matchable token (a full name with a
    /// surname) — the secondary body-grounding admits ONLY multi-token names.
    private static func isMultiToken(_ name: String) -> Bool {
        VocabTokenizer.tokenize(controlStripped(name))
            .map { VocabNormalization.canonicalMode($0.core) }
            .filter { !$0.isEmpty }
            .count > 1
    }

    /// D9 injection-hardening for a string rendered as DATA in the prompt:
    /// Unicode-normalize (NFC), strip newlines + control characters, collapse
    /// internal whitespace, and length-cap. Returns "" when nothing survives.
    private static func harden(_ s: String) -> String {
        let normalized = s.precomposedStringWithCanonicalMapping
        let stripped = String(normalized.unicodeScalars.map { scalar -> Character in
            // Newlines and other control characters → a single space; the
            // collapse below removes the resulting runs.
            if scalar.properties.generalCategory == .control || CharacterSet.newlines.contains(scalar) {
                return " "
            }
            return Character(scalar)
        })
        let collapsed = stripped
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return "" }
        guard collapsed.count > maxRenderedLength else { return collapsed }
        return String(collapsed.prefix(maxRenderedLength)).trimmingCharacters(in: .whitespaces)
    }
}
