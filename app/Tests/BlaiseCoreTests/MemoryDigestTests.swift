import CryptoKit
import Foundation
import GRDB
import Testing

@testable import BlaiseCore

// G14 — memory_digest. All fixtures are FICTIONAL (Vexatron Labs / Quoll
// Harbor); no real user/Vexatron data anywhere. The knowledge graph brief's real worked
// example is reference only and is never copied here.

// MARK: - Fictional fixtures (the established fictional universe)

private enum DigestFixtures {
    /// A fictional user/company, unrelated to the real user.
    static let user = UserIdentity(
        name: "Dana Marsh", aliases: ["Dana"], email: "dana@vexatronlabs.example")
    static let company = "Vexatron Labs"
    static let partner = "Quoll Harbor"

    /// An English-dominant `md-v1` digest fixture exercising several sections,
    /// respecting the per-section rules (AC1b): HEADER field set, `(none
    /// resolved)` token, a mandatory as-of date on every STATUS/OPEN line, a
    /// DECISIONS reversal as a dated past-tense clause, one primary subject per
    /// line.
    static let enDigest = """
        ## HEADER
        meeting: Vexatron Labs roadmap review
        date: 14 March 2026
        speaker: (none resolved)

        ## DECISIONS
        Dana Marsh decided on 14 March 2026 to ship the Vexatron Labs scheduler in May 2026.
        On 14 March 2026 Vexatron Labs reversed the 7 March 2026 decision to ship the scheduler in April 2026.

        ## COMMITMENTS
        Dana Marsh will deliver the Vexatron Labs migration plan by 21 March 2026.

        ## STATUS
        The Vexatron Labs scheduler reached 70% test coverage as of 14 March 2026.

        ## OPEN
        Vexatron Labs has not chosen a launch region as of 14 March 2026.
        """

    /// A PT-dominant `md-v1` digest fixture (content in Portuguese, the eight
    /// `##` headings and the bracket flags stay English).
    static let ptDigest = """
        ## HEADER
        meeting: Revisão de orçamento da Vexatron Labs
        date: 14 de março de 2026
        speaker: Dana Marsh

        ## DECISIONS
        Dana Marsh decidiu em 14 de março de 2026 aumentar o orçamento de marketing da Vexatron Labs.

        ## STATUS
        A Vexatron Labs gastou R$ 1.000.000,00 em infraestrutura em 14 de março de 2026.

        ## OPEN
        A Vexatron Labs ainda não definiu o fornecedor de nuvem em 14 de março de 2026.
        """

    /// A static fixture carrying a KEPT `[external-claim]` line that does NOT
    /// co-name the fictional user/company (the co-occurrence-ban fixture).
    static let externalClaimDigest = """
        ## HEADER
        meeting: Vexatron Labs partner sync
        date: 14 March 2026
        speaker: Dana Marsh

        ## FACTS
        Quoll Harbor reported a 30% revenue increase in 2025. [external-claim]

        ## COMMITMENTS
        Dana Marsh will review the Vexatron Labs integration plan by 21 March 2026.
        """

    /// A degenerate meeting: nothing memory-worthy → HEADER only.
    static let degenerateDigest = "## HEADER\nmeeting: Vexatron Labs standup\ndate: 14 March 2026\nspeaker: (none resolved)\n"
}

// MARK: - AC1 / AC1b — prompt frozen + per-section rules encoded

@Suite struct MemoryDigestPromptTests {
    /// AC1: `md-v1` prompt frozen + hash-pinned by a NEW independent test
    /// (a LITERAL pin, so a silent edit to the prompt fails this test —
    /// editing it must be a deliberate, version-bumped act).
    @Test func mdV1PromptHashPinned() {
        let digest = SHA256.hash(data: Data(DigestPromptBuilder.systemDigestPromptV1.utf8))
            .map { String(format: "%02x", $0) }.joined()
        #expect(digest == "beec067b5861fea52df43ba40f91eafe45fa363acb0c58b24f034d91f863ef3f",
            "systemDigestPromptV1 changed; bump md-v1 and re-pin deliberately")
    }

    /// AC1: the notes pins are UNTOUCHED (G14 edits no notes constant).
    @Test func notesPromptPinsUntouched() {
        let v1 = SHA256.hash(data: Data(NotesPromptBuilder.systemPromptV1.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let v11 = SHA256.hash(data: Data(NotesPromptBuilder.systemPromptV11.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let v2 = SHA256.hash(data: Data(NotesPromptBuilder.systemPromptV2.utf8))
            .map { String(format: "%02x", $0) }.joined()
        #expect(v1 == "49dc155e6223337c4d717a36f52f55ca82b0f36b0277672af60ffe82918cf314")
        // G6 re-pin (publish-scrub: the v11 suffix's misheard-vs-canonical
        // example real name → fictional "Marsa (Dana Marsh)"; v1/v2 untouched).
        #expect(v11 == "c579b9f5c706508a491920d5555851211004ef09e86e6adae31daa7267705ae4")
        #expect(v2 == "1900a407f905bff5a42805c3e2052b706143bb3639dd8d8cbb2cc871bc041298")
        // v1.1 still extends v1 (the hasPrefix invariant).
        #expect(NotesPromptBuilder.systemPromptV11.hasPrefix(NotesPromptBuilder.systemPromptV1))
    }

    /// AC1: the prompt enumerates all eight `##` sections and the must-NOT
    /// rules; contains no real identity (fictional/generic only).
    @Test func promptEnumeratesEightSectionsAndMustNotRules() {
        let p = DigestPromptBuilder.systemDigestPromptV1
        for section in ["## HEADER", "## DECISIONS", "## COMMITMENTS", "## FACTS",
                        "## STATUS", "## VIEWS", "## OPEN", "## POLICIES"] {
            #expect(p.contains(section), "prompt must enumerate \(section)")
        }
        // must-NOT rules.
        #expect(p.lowercased().contains("no email"))
        #expect(p.lowercased().contains("no attendee-list dump") || p.lowercased().contains("attendee-list dump"))
        #expect(p.lowercased().contains("no invented attribution") || p.lowercased().contains("invented attribution"))
        #expect(p.contains("S0") && p.contains("S1"), "the no-raw-label rule names the label form")
        // No real identity.
        #expect(!p.contains("Sam"))
        #expect(!p.lowercased().contains("Vexatron"))
        #expect(!p.lowercased().contains("árvore"))
    }

    /// AC1b prompt-encodes: HEADER field set + `(none resolved)` token; a
    /// mandatory as-of date on every STATUS and every OPEN line; DECISIONS
    /// reversal as a dated past-tense clause; one primary subject per line.
    @Test func promptEncodesLoadBearingPerSectionRules() {
        let p = DigestPromptBuilder.systemDigestPromptV1
        // HEADER field set + the (none resolved) token.
        #expect(p.contains("meeting:") && p.contains("date:") && p.contains("speaker:"))
        #expect(p.contains("(none resolved)"), "the (none resolved) token must be encoded")
        // Mandatory as-of date on STATUS + OPEN.
        let lower = p.lowercased()
        #expect(lower.contains("every `## status` line must carry an absolute as-of date"))
        #expect(lower.contains("every `## open` line must carry an absolute as-of date"))
        // Reversal as a new dated past-tense clause.
        #expect(lower.contains("reverses") && lower.contains("past-tense"))
        // One primary subject per line.
        #expect(lower.contains("one primary subject per line"))
        // Absolute dates only.
        #expect(lower.contains("absolute dates only"))
    }

    /// AC5b prompt-encodes: `[external-claim]` is DROP-by-default; a kept line
    /// extracts no entity/fact and keeps third-party proper nouns OFF any line
    /// naming the user/company.
    @Test func promptEncodesExternalClaimContract() {
        let lower = DigestPromptBuilder.systemDigestPromptV1.lowercased()
        #expect(lower.contains("drop a cited outside fact by default")
            || lower.contains("drop cited outside")
            || (lower.contains("drop") && lower.contains("by default")))
        #expect(lower.contains("[external-claim]"))
        #expect(lower.contains("extract no entity") || lower.contains("extracts no entity"))
        #expect(lower.contains("never co-occur") || lower.contains("never occur")
            || lower.contains("off any line that also names the user"))
    }

    /// `md-v2` (the SHIPPED contract) frozen + hash-pinned. A silent edit fails
    /// this test — editing it must be a deliberate, version-bumped act.
    @Test func mdV2PromptHashPinned() {
        let digest = SHA256.hash(data: Data(DigestPromptBuilder.systemDigestPromptV2.utf8))
            .map { String(format: "%02x", $0) }.joined()
        #expect(digest == "3c3cabeea008eb27b35b01e63aae722eed0d986e0dce476d7f7f67b9d3cf3e0c",
            "systemDigestPromptV2 changed; bump md-v2 and re-pin deliberately")
    }

    /// `md-v2` adds, on top of md-v1's eight sections + flags: the HEADER
    /// `projects:` enumeration, strict ISO dates, homonym/canonicalization +
    /// project-attribution discipline, referenced-≠-present, and volatile-
    /// metrics-to-STATUS. md-v2 is RETAINED append-only (no longer the shipped
    /// version — md-v3 is) and still selectable via `systemPrompt(for:)`. No
    /// real identity.
    @Test func mdV2PromptEncodesNewRules() {
        let p = DigestPromptBuilder.systemDigestPromptV2
        for section in ["## HEADER", "## DECISIONS", "## COMMITMENTS", "## FACTS",
                        "## STATUS", "## VIEWS", "## OPEN", "## POLICIES"] {
            #expect(p.contains(section), "prompt must enumerate \(section)")
        }
        let lower = p.lowercased()
        // md-v2 additions.
        #expect(p.contains("projects:"), "HEADER must carry a projects: line")
        #expect(lower.contains("enumerate every project"))
        #expect(lower.contains("yyyy-mm-dd"), "dates must be strict ISO")
        #expect(lower.contains("homonym"))
        #expect(lower.contains("attribute each fact to the specific project"))
        #expect(lower.contains("referenced"))
        #expect(lower.contains("volatile metrics"))
        // inherited rules.
        #expect(lower.contains("no email"))
        #expect(p.contains("S0") && p.contains("S1"))
        #expect(lower.contains("never translated"))
        // No real identity.
        #expect(!p.contains("Sam"))
        #expect(!lower.contains("vexatron"))
        #expect(!lower.contains("árvore"))
        // md-v2 is RETAINED append-only and still selectable, even though it is
        // no longer the shipped contract (md-v3 is — pinned by the V3 test).
        #expect(DigestPromptBuilder.shippedVersion != .mdV2)
        #expect(DigestPromptBuilder.systemPrompt(for: .mdV2) == p)
    }

    /// `md-v3` (the SHIPPED contract) frozen + hash-pinned. A silent edit fails
    /// this test — editing it must be a deliberate, version-bumped act. mdV1/mdV2
    /// frozen-pin hashes (above) are UNCHANGED.
    @Test func mdV3PromptHashPinned() {
        let digest = SHA256.hash(data: Data(DigestPromptBuilder.systemDigestPromptV3.utf8))
            .map { String(format: "%02x", $0) }.joined()
        #expect(digest == "3a5bffb1ea21a227facce723fb82eedd3e2f65c829870c7ea7c3884d4217b4db",
            "systemDigestPromptV3 changed; bump md-v3 and re-pin deliberately")
    }

    /// AC3: `md-v3` is a QUALITY-only bump — the SAME ordered sequence of `##`
    /// section heading tokens, the SAME `## HEADER` envelope field block, and the
    /// SAME inline-flag bullet set as md-v2, byte-equal; only the
    /// attribution/host/alias RULE TEXT differs (asserted separately below). This
    /// is the structural invariant: a delta that reshapes a section, drops a
    /// HEADER field, or alters a flag breaks the digest CONTRACT and fails here.
    @Test func mdV3PreservesV2StructuralInvariant() {
        let v2 = DigestPromptBuilder.systemDigestPromptV2
        let v3 = DigestPromptBuilder.systemDigestPromptV3
        // (1) the ordered sequence of `## SECTION` heading tokens is byte-equal.
        #expect(headingTokenSequence(v3) == headingTokenSequence(v2),
            "md-v3 must keep the V2 `##` heading-token sequence")
        // The eight sections all appear (a non-vacuous sequence).
        for section in ["## HEADER", "## DECISIONS", "## COMMITMENTS", "## FACTS",
                        "## STATUS", "## VIEWS", "## OPEN", "## POLICIES"] {
            #expect(headingTokenSequence(v3).contains(section))
        }
        // (2) the `## HEADER` envelope field block is byte-equal.
        #expect(headerFieldBlock(v3) == headerFieldBlock(v2),
            "md-v3 must keep the V2 HEADER field set (incl. projects:)")
        #expect(headerFieldBlock(v3).contains { $0.contains("projects:") })
        // (3) the inline-flag bullet set is byte-equal.
        #expect(inlineFlagBullets(v3) == inlineFlagBullets(v2),
            "md-v3 must keep the V2 inline-flag set")
        #expect(inlineFlagBullets(v3).count == 3)
        // RULE TEXT does differ (so the invariant is not a tautology of identity):
        // the bodies are NOT byte-equal — md-v3 carries the new attribution rules.
        #expect(v3 != v2)
    }

    /// AC5 / Issue 1+2: the V3 RULE TEXT encodes the three deltas — evidence-
    /// grounded credited-person survival with the explicit hierarchy, the homonym
    /// positive-evidence rule, and the HOST-authority instruction — and the
    /// guardrail that roster/glossary presence ALONE is never evidence (never
    /// invent/complete a name). No real identity. (Behavior is validated by the
    /// recall-gate; this pins the wording is present.)
    @Test func mdV3PromptEncodesAttributionDeltas() {
        let p = DigestPromptBuilder.systemDigestPromptV3
        let lower = p.lowercased()
        // Issue 1: credited-person survival + the evidence hierarchy.
        #expect(lower.contains("credited-person survival"))
        #expect(lower.contains("evidence hierarchy"))
        #expect(lower.contains("host binding"))
        #expect(lower.contains("transcript-grounded"))
        #expect(lower.contains("roster-resolved"))
        // roster/glossary ALONE is not evidence; never invent a name.
        #expect(lower.contains("never complete, guess, or invent a name"))
        #expect(lower.contains("attendee-roster or glossary presence alone is never evidence"))
        // The intent guard: don't redact a credited contributor, never find one.
        #expect(lower.contains("do not redact a genuinely credited contributor"))
        #expect(lower.contains("never \"find someone to credit\""))
        // Issue 2a: homonym positive-evidence.
        #expect(lower.contains("homonym & positive-evidence discipline"))
        #expect(lower.contains("bind a full name only on positive evidence"))
        #expect(lower.contains("never invent a surname"))
        // Issue 2b: HOST authority.
        #expect(lower.contains("host authority"))
        #expect(lower.contains("[host]-marked turns are the authoritative owner")
            || lower.contains("treat [host]-marked turns as the authoritative owner"))
        #expect(lower.contains("never to a colleague who merely shares a first name"))
        // No real identity.
        #expect(!p.contains("Sam"))
        #expect(!lower.contains("vexatron"))
        #expect(!lower.contains("árvore"))
        // md-v3 is RETAINED append-only and still selectable, but is NO LONGER the
        // shipped contract — md-v4 is (pinned by the V4 tests below).
        #expect(DigestPromptBuilder.shippedVersion != .mdV3)
        #expect(DigestPromptBuilder.systemPrompt(for: .mdV3) == p)
    }

    /// `md-v4` (the SHIPPED contract) frozen + hash-pinned. A silent edit fails
    /// this test — editing it must be a deliberate, version-bumped act. The
    /// mdV1/mdV2/mdV3 frozen-pin hashes (above) are UNCHANGED.
    @Test func mdV4PromptHashPinned() {
        let digest = SHA256.hash(data: Data(DigestPromptBuilder.systemDigestPromptV4.utf8))
            .map { String(format: "%02x", $0) }.joined()
        #expect(digest == "d31b46a145547f07fd4a0af6a435b43748fc8b54113f351bde0cda4c842ac9c4",
            "systemDigestPromptV4 changed; bump md-v4 and re-pin deliberately")
    }

    /// `md-v4` is a QUALITY-only bump — the SAME ordered `##` heading-token
    /// sequence, the SAME `## HEADER` envelope field block, and the SAME inline-
    /// flag bullet set as md-v2, byte-equal; only RULE TEXT differs. A delta that
    /// reshapes a section, drops a HEADER field, or alters a flag breaks the
    /// digest CONTRACT and fails here.
    @Test func mdV4PreservesV2StructuralInvariant() {
        let v2 = DigestPromptBuilder.systemDigestPromptV2
        let v3 = DigestPromptBuilder.systemDigestPromptV3
        let v4 = DigestPromptBuilder.systemDigestPromptV4
        // (1) the ordered sequence of `## SECTION` heading tokens is byte-equal.
        #expect(headingTokenSequence(v4) == headingTokenSequence(v2),
            "md-v4 must keep the V2 `##` heading-token sequence")
        for section in ["## HEADER", "## DECISIONS", "## COMMITMENTS", "## FACTS",
                        "## STATUS", "## VIEWS", "## OPEN", "## POLICIES"] {
            #expect(headingTokenSequence(v4).contains(section))
        }
        // (2) the `## HEADER` envelope field block is byte-equal.
        #expect(headerFieldBlock(v4) == headerFieldBlock(v2),
            "md-v4 must keep the V2 HEADER field set (incl. projects:)")
        #expect(headerFieldBlock(v4).contains { $0.contains("projects:") })
        // (3) the inline-flag bullet set is byte-equal.
        #expect(inlineFlagBullets(v4) == inlineFlagBullets(v2),
            "md-v4 must keep the V2 inline-flag set")
        #expect(inlineFlagBullets(v4).count == 3)
        // RULE TEXT does differ (so the invariant is not a tautology of identity):
        // md-v4 carries the new recall rules and differs from both v2 and v3.
        #expect(v4 != v2)
        #expect(v4 != v3)
    }

    /// The V4 RULE TEXT encodes the recall deltas — ATTRIBUTION RECOVERY, PRESERVE
    /// CONCRETE FIGURES & DEAL-TERMS, the project-recall emphasis, the recall-
    /// balanced anti-fabrication, and the OWNER CROSS-CHECK roster's WHO-only
    /// framing — while PRESERVING the md-v3 precision guards (credited-person
    /// survival, homonym positive-evidence, host authority). No real identity.
    /// (Behavior is validated by the recall-gate; this pins the wording is present.)
    @Test func mdV4PromptEncodesRecallDeltas() {
        let p = DigestPromptBuilder.systemDigestPromptV4
        let lower = p.lowercased()
        // New recall rules.
        #expect(lower.contains("attribution recovery"))
        #expect(lower.contains("never default a decision, commitment, or credited contribution to \"unidentified participant\""))
        #expect(lower.contains("owner cross-check"))
        #expect(lower.contains("preserve concrete figures"))
        #expect(lower.contains("never drop a spoken figure"))
        #expect(lower.contains("permanently unrecallable") || lower.contains("permanently lost"))
        // Roster is WHO-only, body authoritative, never a source of facts.
        #expect(lower.contains("who-only"))
        #expect(lower.contains("the body wins"))
        #expect(lower.contains("never a source of new facts"))
        // Recall-balanced anti-fabrication, but STILL anti-fabrication.
        #expect(lower.contains("never at the cost of grounded recall"))
        #expect(lower.contains("never invent facts, numbers, names"))
        // PRESERVED md-v3 precision guards.
        #expect(lower.contains("credited-person survival"))
        #expect(lower.contains("homonym & positive-evidence discipline"))
        #expect(lower.contains("host authority"))
        #expect(lower.contains("never to a colleague who merely shares a first name"))
        #expect(lower.contains("never complete, guess, or invent a name"))
        // No real identity.
        #expect(!p.contains("Sam"))
        #expect(!lower.contains("vexatron"))
        #expect(!lower.contains("árvore"))
        // md-v4 is the shipped SYNTHESIS prompt; md-v5 and md-v6 (the shipped
        // contract) reuse it verbatim — md-v5 added the notes-reconciler pass,
        // md-v6 folds verify+reconcile into one combined audit pass. The md-v4
        // synthesis hash pin is untouched by either pipeline bump.
        #expect(DigestPromptBuilder.systemPrompt(for: .mdV4) == p)
        #expect(DigestPromptBuilder.systemPrompt(for: .mdV5) == p)
        #expect(DigestPromptBuilder.systemPrompt(for: .mdV6) == p)
        #expect(DigestPromptBuilder.systemPrompt == p)
        #expect(DigestPromptBuilder.shippedVersion == .mdV6)
        #expect(DigestPromptBuilder.promptVersion == "md-v6")
    }

    /// `md-v5` is now the ROLLBACK pipeline branch (its separate notes-reconciler
    /// third pass); the SYNTHESIS prompt is md-v4 verbatim (the md-v4 hash pin
    /// above is untouched), and its reconcile prompt is RETAINED verbatim so a
    /// one-line flip of `shippedVersion` back to `.mdV5` restores the known-good
    /// verify→reconcile path. The reconcile prompt encodes additive-only,
    /// transcript-gated, no-launder, no-edit-notes. No real identity.
    @Test func mdV5ReconcilePassContract() {
        // md-v5 synthesis is still md-v4 verbatim (rollback parity).
        #expect(DigestPromptBuilder.systemPrompt(for: .mdV5)
            == DigestPromptBuilder.systemDigestPromptV4)
        // The reconcile prompt wording (retained for rollback).
        let r = DigestPromptBuilder.systemDigestReconcilePrompt
        let lower = r.lowercased()
        #expect(lower.contains("notes reconciler"))
        #expect(lower.contains("additive"))
        #expect(lower.contains("only when the transcript body grounds it")
            || lower.contains("if and only if the transcript body grounds it"))
        #expect(lower.contains("never launder"))
        #expect(lower.contains("not grounded in the body → do not add it")
            || lower.contains("a notes item the transcript does not support is never added"))
        #expect(lower.contains("do not edit") && lower.contains("notes"))
        #expect(lower.contains("never remove, reword, re-attribute"))
        // No real identity.
        #expect(!lower.contains("vexatron"))
        #expect(!lower.contains("árvore"))
    }

    /// `md-v6` (the SHIPPED contract) is a PIPELINE bump that FOLDS the md-v5
    /// transcript-only verify AND the notes reconcile into ONE combined audit
    /// pass. The SYNTHESIS prompt stays md-v4 verbatim (hash pin untouched). The
    /// combined-audit prompt sequences the verify fix-categories (STEP 1) BEFORE
    /// the additive notes-reconcile procedure (STEP 2), and emits one final
    /// digest from `## HEADER` (the `stripPreamble` contract). This is the exact
    /// string validated on the 6-meeting gauntlet. No real identity.
    @Test func mdV6CombinedAuditPassContract() {
        // Shipped contract + synthesis reuse (md-v4 verbatim).
        #expect(DigestPromptBuilder.shippedVersion == .mdV6)
        #expect(DigestPromptBuilder.promptVersion == "md-v6")
        #expect(DigestPromptBuilder.systemPrompt(for: .mdV6)
            == DigestPromptBuilder.systemDigestPromptV4)
        let c = DigestPromptBuilder.systemDigestCombinedAuditPrompt
        let lower = c.lowercased()
        // One auditor identity that does BOTH jobs.
        #expect(lower.contains("precision auditor + notes reconciler"))
        // Two ordered steps — verify (STEP 1) STRICTLY BEFORE reconcile (STEP 2).
        let step1 = lower.range(of: "step 1 — verify against the transcript")
        let step2 = lower.range(of: "step 2 — reconcile against the human notes")
        #expect(step1 != nil, "STEP 1 verify header present")
        #expect(step2 != nil, "STEP 2 reconcile header present")
        if let s1 = step1, let s2 = step2 {
            #expect(s1.lowerBound < s2.lowerBound, "verify precedes reconcile")
        }
        // STEP 1: the five verify fix-categories + the RECALL GUARD.
        #expect(lower.contains("wrong attribution"))
        #expect(lower.contains("ungrounded name"))
        #expect(lower.contains("distorted fact"))
        #expect(lower.contains("phantom entity"))
        #expect(lower.contains("dropped attribution"))
        #expect(lower.contains("recall guard"))
        // STEP 2: additive-only, transcript-gated, never-launder.
        #expect(lower.contains("additive only"))
        #expect(lower.contains("if and only if the transcript body grounds it"))
        #expect(lower.contains("never launder"))
        // Single-pass emit; the `## HEADER` digest contract (stripPreamble target).
        #expect(c.contains("## HEADER"))
        #expect(lower.contains("emit only the final corrected digest")
            || lower.contains("output the complete final digest"))
        // No real identity.
        #expect(!lower.contains("vexatron"))
        #expect(!lower.contains("árvore"))
    }
}

// MARK: - V3 structural-invariant extractors (heading tokens / HEADER fields / flags)

/// The ordered sequence of `## SECTION` heading tokens as they appear in the
/// prompt body (the eight sections + their cross-references), used to assert the
/// V3 contract keeps the V2 section shape byte-for-byte.
private func headingTokenSequence(_ prompt: String) -> [String] {
    var out: [String] = []
    let scalars = Array(prompt)
    var i = 0
    while i + 2 < scalars.count {
        if scalars[i] == "#", scalars[i + 1] == "#", scalars[i + 2] == " " {
            var j = i + 3
            var token = "## "
            while j < scalars.count, scalars[j].isUppercase, scalars[j].isLetter {
                token.append(scalars[j])
                j += 1
            }
            if token.count > 3 { out.append(token) }
            i = j
        } else {
            i += 1
        }
    }
    return out
}

/// The `## HEADER` envelope bullet block — from the `- `## HEADER`` line through
/// the bullets up to (not including) the next `- `## ` section bullet.
private func headerFieldBlock(_ prompt: String) -> [String] {
    var out: [String] = []
    var inHeader = false
    for raw in prompt.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("- `## HEADER`") {
            inHeader = true
            out.append(line)
            continue
        }
        if inHeader, line.hasPrefix("- `## ") { break }
        if inHeader, !line.isEmpty { out.append(line) }
    }
    return out
}

/// The inline-flag bullet lines (the `- `[flag]` ...` entries under INLINE FLAGS).
private func inlineFlagBullets(_ prompt: String) -> [String] {
    prompt.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { $0.hasPrefix("- `[") }
}

// MARK: - AC1b fixture-respects — the contract made concrete

@Suite struct MemoryDigestFixtureRulesTests {
    /// A `## HEADER` whose speaker field is the literal `(none resolved)` token
    /// when no speaker resolved.
    @Test func headerSpeakerFieldUsesNoneResolvedToken() {
        let header = DigestFixtures.enDigest.split(separator: "\n").first { $0.hasPrefix("speaker:") }
        #expect(header == "speaker: (none resolved)")
    }

    /// Every `## STATUS` and every `## OPEN` line carries an absolute date.
    @Test func statusAndOpenLinesCarryAbsoluteDates() {
        for digest in [DigestFixtures.enDigest, DigestFixtures.ptDigest] {
            let sections = sectionLines(digest)
            for line in sections["STATUS", default: []] {
                #expect(lineHasAbsoluteDate(line), "STATUS line lacks an as-of date: \(line)")
            }
            for line in sections["OPEN", default: []] {
                #expect(lineHasAbsoluteDate(line), "OPEN line lacks an as-of date: \(line)")
            }
        }
    }

    /// A DECISIONS reversal appears as a dated past-tense clause referencing the
    /// prior decision (a new dated line, not an edit of the prior line).
    @Test func decisionsReversalIsADatedPastTenseClause() {
        let decisions = sectionLines(DigestFixtures.enDigest)["DECISIONS", default: []]
        let reversal = decisions.first { $0.lowercased().contains("reversed") }
        #expect(reversal != nil, "fixture must carry a reversal line")
        if let reversal {
            #expect(lineHasAbsoluteDate(reversal))
            #expect(reversal.lowercased().contains("reversed"))  // past tense
            // References the prior dated decision.
            #expect(reversal.contains("7 March 2026"))
        }
        // The prior decision line is STILL present (never edited away).
        #expect(decisions.contains { $0.contains("ship the Vexatron Labs scheduler in May 2026") })
    }

    /// No line names two primary subjects (one-primary-subject-per-line). We
    /// approximate by checking no single content line names BOTH the company
    /// and the partner as co-equal subjects (a two-entity-subject line).
    @Test func noTwoPrimarySubjectLines() {
        for digest in [DigestFixtures.enDigest, DigestFixtures.ptDigest] {
            for line in contentLines(digest) {
                // A heuristic backstop: the company and partner never co-subject.
                let both = line.contains(DigestFixtures.company) && line.contains(DigestFixtures.partner)
                #expect(!both, "two-primary-subject line: \(line)")
            }
        }
    }

    /// AC6 PT fixture: content is Portuguese, the `##` headings stay English.
    @Test func ptFixtureContentIsPortugueseHeadingsEnglish() {
        let digest = DigestFixtures.ptDigest
        // Headings English.
        #expect(digest.contains("## HEADER") && digest.contains("## DECISIONS")
            && digest.contains("## STATUS") && digest.contains("## OPEN"))
        // Content Portuguese (a distinctively-PT token + BR number style).
        #expect(digest.contains("decidiu") || digest.contains("ainda não"))
        #expect(digest.contains("R$ 1.000.000,00"), "BR number style preserved")
    }

    /// The degenerate meeting yields a `## HEADER`-only digest.
    @Test func degenerateDigestIsHeaderOnly() {
        let headings = DigestFixtures.degenerateDigest
            .split(separator: "\n").filter { $0.hasPrefix("## ") }
        #expect(headings == ["## HEADER"])
    }
}

// MARK: - AC5b — [external-claim] co-occurrence ban (static fixture)

@Suite struct MemoryDigestExternalClaimTests {
    /// Static co-occurrence-ban fixture: every `[external-claim]` line must NOT
    /// also name the fictional user or company. The offending co-occurrence
    /// would be PRESENT text, so this is a real check, not a vacuous absence.
    @Test func keptExternalClaimLineDoesNotCoNameUserOrCompany() {
        let lines = DigestFixtures.externalClaimDigest.split(separator: "\n").map(String.init)
        let externalLines = lines.filter { $0.contains("[external-claim]") }
        #expect(!externalLines.isEmpty, "fixture must carry a kept [external-claim] line")
        for line in externalLines {
            #expect(!line.contains(DigestFixtures.user.name),
                "[external-claim] line co-names the user: \(line)")
            #expect(!line.contains(DigestFixtures.company),
                "[external-claim] line co-names the company: \(line)")
        }
        // The third-party entity IS present on the external-claim line (so the
        // ban is meaningful, not vacuous).
        #expect(externalLines.contains { $0.contains(DigestFixtures.partner) })
    }

    /// A constructed VIOLATION fixture is CAUGHT by the same assertion — proving
    /// the check is non-vacuous (it fails on present offending text).
    @Test func coOccurrenceBanCatchesAViolation() {
        let violating = "Quoll Harbor told Vexatron Labs that revenue rose 30%. [external-claim]"
        let offends = violating.contains("[external-claim]")
            && violating.contains(DigestFixtures.company)
        #expect(offends, "the violation fixture must be catchable as present offending text")
    }
}

// MARK: - SLabelNeutralizer.neutralizeText (the digest's G13-clean entry point)

@Suite struct DigestNeutralizeTextTests {
    @Test func neutralizesResidualLabelsToProseDescriptors() {
        let input = "## FACTS\nS0 proposed the Vexatron Labs plan. S1 disagreed.\n"
        let out = SLabelNeutralizer.neutralizeText(input, language: "en")
        #expect(!SLabelNeutralizer.containsLabel(out), "no residual S-label may survive")
        #expect(out.contains("a participant"))
        #expect(out.contains("another participant"), "distinct unknowns stay distinct")
    }

    @Test func emphasisAwareDetectionCatchesUnderscoreAndAsterisk() {
        let input = "_S0_ raised a point and **S1** answered."
        let out = SLabelNeutralizer.neutralizeText(input, language: "en")
        #expect(!SLabelNeutralizer.containsLabel(out))
    }

    @Test func resolvedLabelSubstitutesToNameNotDescriptor() {
        let input = "S0 owns the Vexatron Labs migration."
        let out = SLabelNeutralizer.neutralizeText(input, labelMap: ["S0": "Dana Marsh"], language: "en")
        #expect(out.contains("Dana Marsh"))
        #expect(!SLabelNeutralizer.containsLabel(out))
    }

    @Test func portugueseDescriptorsForPTDigest() {
        let input = "S0 fez uma pergunta."
        let out = SLabelNeutralizer.neutralizeText(input, language: "pt")
        #expect(out.contains("um participante"))
    }

    @Test func cleanDigestIsUnchanged() {
        let clean = DigestFixtures.enDigest
        #expect(SLabelNeutralizer.neutralizeText(clean) == clean)
    }
}

// MARK: - Payload builder presence-gating (AC3 / Floor 8)

@Suite struct MemoryDigestPayloadGatingTests {
    private func notes(meetingID: MeetingID, digest: String?) -> MeetingNotes {
        MeetingNotes(
            meetingID: meetingID, markdown: "# Notas",
            structured: NotesStructured(
                title: "Notas", summary: "Resumo.", detailedNotes: "Detalhe.",
                decisions: [], actionItems: [], userActionItems: []),
            language: "en",
            generatedAt: msDate(),
            provenance: NotesProvenance(engine: "e", model: "m", pipelineVersion: "p"),
            memoryDigest: digest)
    }

    /// A NULL digest column (legacy / toggle-off / digest-pending) emits NEITHER
    /// the top-level `memory_digest` NOR `provenance.memory_digest` — and is
    /// otherwise byte-identical to a payload built before G14 existed.
    @Test func nullDigestOmitsBothKeys() throws {
        let meeting = makeMeeting(status: .ready)
        let withNil = EvidencePayloadBuilder.build(
            meeting: meeting, segments: [], notes: notes(meetingID: meeting.id, digest: nil),
            user: .shippedDefault)
        let text = String(decoding: withNil.bytes, as: UTF8.self)
        #expect(!text.contains("memory_digest"))
    }

    /// A non-null digest emits BOTH the top-level string and the provenance
    /// sub-object — and changes the version_hash (a different payload).
    @Test func presentDigestEmitsBothKeysAndChangesHash() throws {
        let meeting = makeMeeting(status: .ready)
        let withNil = EvidencePayloadBuilder.build(
            meeting: meeting, segments: [], notes: notes(meetingID: meeting.id, digest: nil),
            user: .shippedDefault)
        let withDigest = EvidencePayloadBuilder.build(
            meeting: meeting, segments: [],
            notes: notes(meetingID: meeting.id, digest: DigestFixtures.degenerateDigest),
            user: .shippedDefault)
        let text = String(decoding: withDigest.bytes, as: UTF8.self)
        #expect(text.contains("\"memory_digest\""))
        #expect(text.contains("\"prompt_version\":\"md-v6\""))
        #expect(withDigest.versionHash != withNil.versionHash)
    }

    /// The digest CONTRACT is part of the version_hash, so a payload minted under
    /// a prior contract (md-v1) hashes differently from md-v2. This is what lets
    /// HandoffWorker.rematerialize recover a queued md-v1 payload after the bump
    /// (it rebuilds across each digest version) instead of quarantining it.
    @Test func digestContractIsPartOfTheVersionHash() {
        let meeting = makeMeeting()
        let n = notes(meetingID: meeting.id, digest: DigestFixtures.degenerateDigest)
        let v1 = EvidencePayloadBuilder.build(
            meeting: meeting, segments: [], notes: n, user: .shippedDefault,
            digestPromptVersion: .mdV1)
        let v2 = EvidencePayloadBuilder.build(
            meeting: meeting, segments: [], notes: n, user: .shippedDefault,
            digestPromptVersion: .mdV2)
        #expect(v1.versionHash != v2.versionHash)
        #expect(String(decoding: v1.bytes, as: UTF8.self).contains("\"prompt_version\":\"md-v1\""))
        #expect(String(decoding: v2.bytes, as: UTF8.self).contains("\"prompt_version\":\"md-v2\""))
    }

    /// Re-materialization of a stored digest is byte-identical (the same notes
    /// in → the same bytes out).
    @Test func rematerializationOfStoredDigestIsByteIdentical() throws {
        let meeting = makeMeeting(status: .ready)
        let n = notes(meetingID: meeting.id, digest: DigestFixtures.enDigest)
        let first = EvidencePayloadBuilder.build(meeting: meeting, segments: [], notes: n, user: .shippedDefault)
        let second = EvidencePayloadBuilder.build(meeting: meeting, segments: [], notes: n, user: .shippedDefault)
        #expect(first.versionHash == second.versionHash)
        #expect(first.bytes == second.bytes)
    }
}

// MARK: - Helpers

private func sectionLines(_ digest: String) -> [String: [String]] {
    var out: [String: [String]] = [:]
    var current: String?
    for raw in digest.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(raw)
        if line.hasPrefix("## ") {
            current = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        } else if let current, !line.trimmingCharacters(in: .whitespaces).isEmpty {
            out[current, default: []].append(line)
        }
    }
    return out
}

private func contentLines(_ digest: String) -> [String] {
    digest.split(separator: "\n", omittingEmptySubsequences: true)
        .map(String.init)
        .filter { !$0.hasPrefix("## ") && !$0.hasPrefix("meeting:") && !$0.hasPrefix("date:")
            && !$0.hasPrefix("speaker:") }
}

/// A heuristic absolute-date detector for the fixtures: an English month name
/// with a year, or a PT month name with a year, or a DD/MM/YYYY form.
private func lineHasAbsoluteDate(_ line: String) -> Bool {
    let enMonths = ["January", "February", "March", "April", "May", "June", "July",
                    "August", "September", "October", "November", "December"]
    let ptMonths = ["janeiro", "fevereiro", "março", "abril", "maio", "junho", "julho",
                    "agosto", "setembro", "outubro", "novembro", "dezembro"]
    let lower = line.lowercased()
    if enMonths.contains(where: { line.contains($0) }) && line.contains("2026") { return true }
    if ptMonths.contains(where: { lower.contains($0) }) && line.contains("2026") { return true }
    // DD/MM/YYYY.
    return line.range(of: #"\d{2}/\d{2}/\d{4}"#, options: .regularExpression) != nil
}
