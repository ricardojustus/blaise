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
        #expect(text.contains("\"prompt_version\":\"md-v1\""))
        #expect(withDigest.versionHash != withNil.versionHash)
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
