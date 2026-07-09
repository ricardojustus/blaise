import Foundation
import GRDB
import Testing

@testable import BlaiseCore

// G14 — engine-level digest tests: the Claude engine's free-text digest call,
// its NET-NEW bounded transient retry (H1), and `digest`-purpose receipting.
// No network: the transport seam plays the API. All fixtures FICTIONAL.

private func fictionalDigestRequest() -> DigestRequest {
    let meeting = Meeting(
        id: "01DIGESTMEETING000000000000",
        title: "Vexatron Labs roadmap review",
        startedAt: Date(timeIntervalSince1970: 1_774_000_000),
        source: .meet,
        status: .processing,
        attendees: [Attendee(name: "Dana Marsh", email: "dana@vexatronlabs.example", source: .manual)],
        createdAt: msDate(),
        updatedAt: msDate())
    return DigestRequest(
        meeting: meeting,
        transcript: [
            TranscriptSegment(
                meetingID: meeting.id, ord: 0, startSeconds: 0, endSeconds: 5,
                speakerLabel: "S0", speakerName: "Dana Marsh",
                text: "Vamos enviar o cronograma da Vexatron Labs."),
        ],
        notes: NotesStructured(
            title: "Roadmap", summary: "Resumo do roadmap.",
            detailedNotes: "Discussão.", decisions: ["Enviar cronograma"],
            actionItems: [ActionItem(owner: "Dana Marsh", text: "enviar cronograma")],
            userActionItems: []),
        dominantLanguage: "pt",
        vocabulary: ["Vexatron Labs"],
        user: UserIdentity(name: "Dana Marsh", aliases: ["Dana"], email: "dana@vexatronlabs.example"))
}

private func digestSuccessBody(text: String = "## HEADER\nmeeting: Vexatron Labs roadmap review\n") -> String {
    let escaped = text
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
    return """
        {"id": "msg_test", "type": "message", "role": "assistant",
         "content": [{"type": "text", "text": "\(escaped)"}],
         "stop_reason": "end_turn",
         "usage": {"input_tokens": 6000, "output_tokens": 800}}
        """
}

private struct DigestClaudeHarness {
    let engine: ClaudeSummarizationEngine
    let ledger: CloudSpendLedger
    let database: BlaiseDatabase
    let requests: Recorder<URLRequest>
}

private func makeDigestClaudeHarness(responses: [(Int, String)]) async throws -> DigestClaudeHarness {
    let database = try makeDatabase()
    let settings = SettingsStore(database: database)
    let secrets = InMemorySecretStore()
    try secrets.set(
        key: "engine.\(ClaudeSummarizationEngine.engineID).\(ClaudeSummarizationEngine.apiKeyConfigKey)",
        value: "sk-test-not-a-real-key")
    let configuration = EngineConfiguration(
        engineID: ClaudeSummarizationEngine.engineID,
        descriptors: ClaudeSummarizationEngine.descriptors,
        settings: settings, secrets: secrets)
    let ledger = CloudSpendLedger(database: database)
    let requests = Recorder<URLRequest>()
    let counter = Recorder<Int>()
    let transport: ClaudeSummarizationEngine.Transport = { request in
        requests.append(request)
        counter.append(1)
        let index = min(counter.values.count - 1, responses.count - 1)
        let (status, body) = responses[index]
        let http = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (Data(body.utf8), http)
    }
    let engine = ClaudeSummarizationEngine(
        configuration: configuration, ledger: ledger, transport: transport)
    return DigestClaudeHarness(engine: engine, ledger: ledger, database: database, requests: requests)
}

@Suite struct MemoryDigestClaudeEngineTests {
    /// The digest request is a FREE-TEXT Messages call: no `output_config`
    /// json_schema (the digest is Markdown, not a schema-shaped document).
    @Test func digestRequestIsFreeTextNoSchema() async throws {
        let harness = try await makeDigestClaudeHarness(responses: [(200, digestSuccessBody())])
        _ = try await harness.engine.generateDigest(fictionalDigestRequest())
        let request = try #require(harness.requests.values.first)
        let body = try #require(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        #expect(!body.contains("output_config"), "the digest call carries no json_schema")
        #expect(!body.contains("json_schema"))
        // The md-v1 system prompt rode the call.
        #expect(body.contains("memory-digest writer") || body.contains("memory digest"))
    }

    @Test func digestSuccessReturnsTextAndVersion() async throws {
        let harness = try await makeDigestClaudeHarness(
            responses: [(200, digestSuccessBody(text: "## HEADER\nmeeting: X\n"))])
        let result = try await harness.engine.generateDigest(fictionalDigestRequest())
        #expect(result.digest == "## HEADER\nmeeting: X\n")
        #expect(result.promptVersion == "md-v6")
        #expect(result.usage?.inputUnits == 6000)
    }

    /// H1 bounded retry: a transient 429 is re-issued ONCE; the second attempt
    /// succeeds. So a transient blip never becomes a memory gap on first wobble.
    @Test func boundedRetryRecoversFromTransient429() async throws {
        let harness = try await makeDigestClaudeHarness(responses: [
            (429, #"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#),
            (200, digestSuccessBody()),
        ])
        let result = try await harness.engine.generateDigest(fictionalDigestRequest())
        #expect(result.digest.contains("Vexatron Labs"))
        #expect(harness.requests.values.count == 2, "exactly one bounded retry")
    }

    /// A transient that SURVIVES the one bounded retry escapes (→ the pipeline's
    /// digest-pending path). The engine does not retry forever.
    @Test func transientSurvivingTheRetryEscapes() async throws {
        let harness = try await makeDigestClaudeHarness(responses: [
            (529, #"{"type":"error","error":{"type":"overloaded_error","message":"overloaded"}}"#),
            (529, #"{"type":"error","error":{"type":"overloaded_error","message":"overloaded"}}"#),
        ])
        await #expect(throws: EngineError.self) {
            _ = try await harness.engine.generateDigest(fictionalDigestRequest())
        }
        #expect(harness.requests.values.count == 2, "two attempts then give up")
    }

    /// A non-transient error (refusal/4xx) is NOT retried — retrying cannot help.
    @Test func nonTransientErrorIsNotRetried() async throws {
        let harness = try await makeDigestClaudeHarness(responses: [
            (400, #"{"type":"error","error":{"type":"invalid_request_error","message":"bad"}}"#),
            (200, digestSuccessBody()),
        ])
        await #expect(throws: EngineError.self) {
            _ = try await harness.engine.generateDigest(fictionalDigestRequest())
        }
        #expect(harness.requests.values.count == 1, "a permanent error escapes without a retry")
    }

    /// A successful cloud digest call leaves a `digest`-purpose receipt.
    @Test func successReceiptsUnderDigestPurpose() async throws {
        let harness = try await makeDigestClaudeHarness(responses: [(200, digestSuccessBody())])
        _ = try await harness.engine.generateDigest(fictionalDigestRequest(), purpose: .digest)
        let purposes = try await harness.database.pool.read { db in
            try String.fetchAll(db, sql: "SELECT purpose FROM cloud_spend_receipt")
        }
        #expect(purposes == ["digest"], "the cloud digest call receipts under .digest")
    }

    /// md-v6 COMBINED AUDIT — ONE call that carries the combined-audit system
    /// prompt, the DRAFT digest to repair, AND the human-notes recall checklist
    /// (STEP 2). It REPLACES the md-v5 verify + reconcile pair (which would be two
    /// calls each re-sending the transcript). Result rides the md-v6 version.
    @Test func combinedAuditFiresOneCallWithCombinedPromptDraftAndNotes() async throws {
        let harness = try await makeDigestClaudeHarness(
            responses: [(200, digestSuccessBody(
                text: "## HEADER\nmeeting: Vexatron Labs roadmap review\n\n## DECISIONS\nDana Marsh decidiu enviar o cronograma.\n"))])
        let draft = "## HEADER\nmeeting: Vexatron Labs roadmap review\n\n## DECISIONS\nDraft decision line.\n"
        let result = try await harness.engine.combinedAuditDigest(
            fictionalDigestRequest(), draftDigest: draft, purpose: .digest)
        // ONE call (not two): the combined audit folds verify + reconcile.
        #expect(harness.requests.values.count == 1, "exactly one combined-audit call")
        let body = try #require(harness.requests.values.first?.httpBody
            .flatMap { String(data: $0, encoding: .utf8) })
        // The combined-audit SYSTEM prompt rode the call (verify-then-reconcile).
        #expect(body.contains("PRECISION AUDITOR + NOTES RECONCILER"))
        #expect(body.contains("STEP 1 — VERIFY against the TRANSCRIPT")
            || body.contains("STEP 1"))
        // The DRAFT digest to audit rode the call.
        #expect(body.contains("Draft decision line."))
        // The HUMAN NOTES recall checklist (STEP 2) rode the call — the fixture's
        // decision + action-item owner are present.
        #expect(body.contains("Enviar cronograma") || body.contains("enviar cronograma"))
        // Version + corrected digest.
        #expect(result.promptVersion == "md-v6")
        #expect(result.digest.hasPrefix("## HEADER"))
        #expect(result.digest.contains("enviar o cronograma"))
    }

    /// md-v6 combined audit applies the SAME `stripPreamble` hardening as verify/
    /// reconcile: the auditor narrates its STEP-1 fixes + STEP-2 additions before
    /// `## HEADER`, and that preamble is dropped from the persisted digest.
    @Test func combinedAuditStripsAuditPreamble() async throws {
        let narrated = "STEP 1: re-bound one view to the answerer. STEP 2: added one grounded decision.\n\n## HEADER\nmeeting: Vexatron Labs roadmap review\n"
        let harness = try await makeDigestClaudeHarness(
            responses: [(200, digestSuccessBody(text: narrated))])
        let result = try await harness.engine.combinedAuditDigest(
            fictionalDigestRequest(), draftDigest: "## HEADER\nmeeting: X\n", purpose: .digest)
        #expect(result.digest.hasPrefix("## HEADER"), "preamble stripped to the line-start header")
        #expect(!result.digest.contains("STEP 1:"), "the audit narration is not persisted")
    }

    /// md-v6 FALLBACK CONTRACT: a 200 whose text carries NO line-start `## HEADER`
    /// (the auditor returned only prose, no corrected digest) makes
    /// combinedAuditDigest THROW via `stripPreamble`. This is the EXACT throw the
    /// pipeline's md-v6 do/catch relies on to fall back to the good synthesis
    /// draft — so the digest is NEVER lost when the audit pass misfires. Pins the
    /// throw end-to-end through `runDigestCall` (a real 200, not just the static
    /// `stripPreamble` unit), the load-bearing primitive of the "digest never
    /// lost" robustness guarantee. (The pipeline seam that consumes this throw is
    /// covered by the static SLabel grep-guard + this engine-level pin, mirroring
    /// the shipped md-v5 verify/reconcile posture.)
    @Test func combinedAuditThrowsOnUnparseableOutputSoThePipelineKeepsTheDraft() async throws {
        let harness = try await makeDigestClaudeHarness(
            responses: [(200, digestSuccessBody(
                text: "I reviewed the draft against the transcript and the notes; it looks fully grounded. No corrected digest emitted."))])
        await #expect(throws: EngineError.self) {
            _ = try await harness.engine.combinedAuditDigest(
                fictionalDigestRequest(), draftDigest: "## HEADER\nmeeting: X\n", purpose: .digest)
        }
    }
}

/// #102 — the wire-body `model` field of a captured request.
private func bodyModel(of request: URLRequest) throws -> String {
    let data = try #require(request.httpBody)
    let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    return try #require(body["model"] as? String)
}

/// #102 — model-aware pricing + cost MATH (pure units, no harness/network).
@Suite struct DigestModelPricingTests {
    /// `pricePerMTok` matches Haiku by EXACT string equality.
    @Test func pricePerMTokHaikuExactMatch() {
        let p = ClaudeSummarizationEngine.pricePerMTok(for: ClaudeSummarizationEngine.haikuModel)
        #expect(p.input == 1.0)
        #expect(p.output == 5.0)
    }

    /// A haiku-SHAPED but not-exact id does NOT inherit Haiku pricing — it falls
    /// through to the conservative (3,15) Sonnet default (F6, never substring).
    @Test func pricePerMTokHaikuShapedIdFallsThroughToSonnet() {
        let p = ClaudeSummarizationEngine.pricePerMTok(for: "claude-haiku-4-5-xyz")
        #expect(p.input == 3.0, "a non-exact haiku-shaped id is NOT Haiku-priced")
        #expect(p.output == 15.0)
    }

    /// The Sonnet `model` → (3,15).
    @Test func pricePerMTokSonnetIsThreeFifteen() {
        let p = ClaudeSummarizationEngine.pricePerMTok(for: ClaudeSummarizationEngine.model)
        #expect(p.input == 3.0)
        #expect(p.output == 15.0)
    }

    /// An unknown id → conservative (3,15) Sonnet default.
    @Test func pricePerMTokUnknownIsSonnetDefault() {
        let p = ClaudeSummarizationEngine.pricePerMTok(for: "some-future-model-id")
        #expect(p.input == 3.0)
        #expect(p.output == 15.0)
    }

    /// `cost(of:model:)` Haiku math: 6000 in × $1/M + 800 out × $5/M.
    @Test func costMathHaikuVsSonnet() {
        let usage = ClaudeSummarizationEngine.APIUsage(inputTokens: 6_000, outputTokens: 800)
        let haiku = ClaudeSummarizationEngine.cost(
            of: usage, model: ClaudeSummarizationEngine.haikuModel)
        let sonnet = ClaudeSummarizationEngine.cost(
            of: usage, model: ClaudeSummarizationEngine.model)
        let expectedHaiku = 6_000.0 / 1_000_000 * 1.0 + 800.0 / 1_000_000 * 5.0
        let expectedSonnet = 6_000.0 / 1_000_000 * 3.0 + 800.0 / 1_000_000 * 15.0
        #expect(abs(haiku - expectedHaiku) < 1e-12)
        #expect(abs(sonnet - expectedSonnet) < 1e-12)
        // The Haiku cost is ≈⅓ the Sonnet cost (exactly ⅓ here: in & out both 3×).
        #expect(abs(haiku - sonnet / 3.0) < 1e-12)
    }

    /// The DEFAULT `cost(of:)` (no model arg) bills Sonnet — byte-identical to
    /// every pre-#102 caller.
    @Test func costDefaultIsSonnet() {
        let usage = ClaudeSummarizationEngine.APIUsage(inputTokens: 6_000, outputTokens: 800)
        let dflt = ClaudeSummarizationEngine.cost(of: usage)
        let sonnet = ClaudeSummarizationEngine.cost(
            of: usage, model: ClaudeSummarizationEngine.model)
        #expect(dflt == sonnet)
    }
}

/// #102 — the combined-audit model-threading behavior: OFF-path pins Sonnet, the
/// single-Haiku-call consistency invariant (the prior HIGH escaped because
/// separate fixtures each passed), the F3 retry, and the F4 scope (notes +
/// synthesis + md-v5 verify/reconcile all stay Sonnet).
@Suite struct DigestHaikuAuditModelThreadingTests {
    private static let auditedBody = digestSuccessBody(
        text: "## HEADER\nmeeting: Vexatron Labs roadmap review\n\n## DECISIONS\nDana Marsh decidiu enviar o cronograma.\n")
    private static let draft = "## HEADER\nmeeting: Vexatron Labs roadmap review\n\n## DECISIONS\nDraft decision line.\n"

    /// NET-NEW OFF-path pin: the combined audit with NO model arg (today's only
    /// call shape) bills SONNET across ALL THREE local sinks — wire body, receipt
    /// model, and receipt cost. The combined-audit pins no model today, so this is
    /// the byte-identical-Sonnet baseline.
    @Test func combinedAuditDefaultIsSonnetBodyReceiptAndCost() async throws {
        let harness = try await makeDigestClaudeHarness(responses: [(200, Self.auditedBody)])
        _ = try await harness.engine.combinedAuditDigest(
            fictionalDigestRequest(), draftDigest: Self.draft, purpose: .digest)

        let request = try #require(harness.requests.values.first)
        #expect(try bodyModel(of: request) == "claude-sonnet-4-6", "OFF path: wire body Sonnet")

        let month = try await harness.ledger.monthReceipts()
        let receipt = try #require(month.receipts.first)
        #expect(receipt.model == "claude-sonnet-4-6", "OFF path: receipt model Sonnet")
        let expectedSonnet = ClaudeSummarizationEngine.cost(
            of: .init(inputTokens: 6_000, outputTokens: 800),
            model: ClaudeSummarizationEngine.model)
        #expect(abs(receipt.costUSD - expectedSonnet) < 1e-12, "OFF path: cost Sonnet")
    }

    /// **F5 SINGLE-HAIKU-CALL CONSISTENCY** — in ONE `combinedAuditDigest(model:
    /// haikuModel)` call: wire body model == receipt model == `claude-haiku-4-5`,
    /// the receipt `costUSD` == `cost(of:model:haiku)`, AND the accumulator delta
    /// == that SAME costUSD (≈⅓ the Sonnet figure). This is the pin the prior
    /// `BLAISE_DIGEST_MODEL` HIGH escaped (separate fixtures each passed while the
    /// wire model and the billed cost silently diverged).
    @Test func singleHaikuCallBodyReceiptCostAndAccumulatorAllAgree() async throws {
        let harness = try await makeDigestClaudeHarness(responses: [(200, Self.auditedBody)])
        let before = try await harness.ledger.accumulatedThisMonth()

        _ = try await harness.engine.combinedAuditDigest(
            fictionalDigestRequest(), draftDigest: Self.draft, purpose: .digest,
            model: ClaudeSummarizationEngine.haikuModel)

        // Sink (a): wire body.
        let request = try #require(harness.requests.values.first)
        #expect(try bodyModel(of: request) == "claude-haiku-4-5")

        // Sink (b): receipt model.
        let month = try await harness.ledger.monthReceipts()
        let receipt = try #require(month.receipts.first)
        #expect(receipt.model == "claude-haiku-4-5")

        // Sink (c): receipt cost == cost(of:model:haiku).
        let expectedHaiku = ClaudeSummarizationEngine.cost(
            of: .init(inputTokens: 6_000, outputTokens: 800),
            model: ClaudeSummarizationEngine.haikuModel)
        #expect(abs(receipt.costUSD - expectedHaiku) < 1e-12)

        // The accumulator bump == that SAME costUSD (the ledger truth agrees).
        let after = try await harness.ledger.accumulatedThisMonth()
        #expect(abs((after - before) - expectedHaiku) < 1e-12,
            "accumulatedThisMonth delta == the receipt costUSD")

        // And that figure is ≈⅓ the Sonnet figure for the same usage.
        let sonnet = ClaudeSummarizationEngine.cost(
            of: .init(inputTokens: 6_000, outputTokens: 800),
            model: ClaudeSummarizationEngine.model)
        #expect(abs(expectedHaiku - sonnet / 3.0) < 1e-12)
    }

    /// **F3 RETRY** — a Haiku audit that hits a transient 429 then succeeds
    /// re-issues a HAIKU body on BOTH attempts (the retry carries the same model).
    @Test func haikuAuditRetryEmitsHaikuOnBothRequestBodies() async throws {
        let harness = try await makeDigestClaudeHarness(responses: [
            (429, #"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#),
            (200, Self.auditedBody),
        ])
        _ = try await harness.engine.combinedAuditDigest(
            fictionalDigestRequest(), draftDigest: Self.draft, purpose: .digest,
            model: ClaudeSummarizationEngine.haikuModel)
        #expect(harness.requests.values.count == 2, "exactly one bounded retry")
        for request in harness.requests.values {
            #expect(try bodyModel(of: request) == "claude-haiku-4-5",
                "both the initial and the retry body are Haiku")
        }
    }

    /// **F4 SCOPE** — the four NON-audit paths emit SONNET (wire body + receipt +
    /// returned/estimated cost), even when the engine knows how to thread Haiku:
    /// synthesis (`generateDigest`), md-v5 `verifyDigest`, md-v5 `reconcileDigest`,
    /// and notes (`generateNotes`). The Haiku toggle never leaks past the combined
    /// audit.
    @Test func synthesisStaysSonnetInBodyReceiptAndCost() async throws {
        let harness = try await makeDigestClaudeHarness(responses: [(200, Self.auditedBody)])
        let result = try await harness.engine.generateDigest(
            fictionalDigestRequest(), purpose: .digest)
        let request = try #require(harness.requests.values.first)
        #expect(try bodyModel(of: request) == "claude-sonnet-4-6")
        let receipt = try #require((try await harness.ledger.monthReceipts()).receipts.first)
        #expect(receipt.model == "claude-sonnet-4-6")
        let sonnet = ClaudeSummarizationEngine.cost(
            of: .init(inputTokens: 6_000, outputTokens: 800),
            model: ClaudeSummarizationEngine.model)
        #expect(abs(receipt.costUSD - sonnet) < 1e-12)
        #expect(abs((result.usage?.estimatedCostUSD ?? -1) - sonnet) < 1e-12,
            "the returned estimatedCostUSD is the Sonnet figure")
    }

    @Test func md5VerifyStaysSonnetInBodyReceiptAndCost() async throws {
        let harness = try await makeDigestClaudeHarness(responses: [(200, Self.auditedBody)])
        let result = try await harness.engine.verifyDigest(
            fictionalDigestRequest(), draftDigest: Self.draft, purpose: .digest)
        let request = try #require(harness.requests.values.first)
        #expect(try bodyModel(of: request) == "claude-sonnet-4-6")
        let receipt = try #require((try await harness.ledger.monthReceipts()).receipts.first)
        #expect(receipt.model == "claude-sonnet-4-6")
        let sonnet = ClaudeSummarizationEngine.cost(
            of: .init(inputTokens: 6_000, outputTokens: 800),
            model: ClaudeSummarizationEngine.model)
        #expect(abs(receipt.costUSD - sonnet) < 1e-12)
        #expect(abs((result.usage?.estimatedCostUSD ?? -1) - sonnet) < 1e-12)
    }

    @Test func md5ReconcileStaysSonnetInBodyReceiptAndCost() async throws {
        let harness = try await makeDigestClaudeHarness(responses: [(200, Self.auditedBody)])
        let result = try await harness.engine.reconcileDigest(
            fictionalDigestRequest(), draftDigest: Self.draft, purpose: .digest)
        let request = try #require(harness.requests.values.first)
        #expect(try bodyModel(of: request) == "claude-sonnet-4-6")
        let receipt = try #require((try await harness.ledger.monthReceipts()).receipts.first)
        #expect(receipt.model == "claude-sonnet-4-6")
        let sonnet = ClaudeSummarizationEngine.cost(
            of: .init(inputTokens: 6_000, outputTokens: 800),
            model: ClaudeSummarizationEngine.model)
        #expect(abs(receipt.costUSD - sonnet) < 1e-12)
        #expect(abs((result.usage?.estimatedCostUSD ?? -1) - sonnet) < 1e-12)
    }

    // F4 scope — NOTES: the SEPARATE notes call (`generateNotes` →
    // `performAttempt` → `buildURLRequest`, untouched by #102) is already pinned
    // to Sonnet across wire body, provenance.model, receipt model, and cost by
    // `ClaudeEngineTests.successMapsIntoNotesResultWithCost` (body model,
    // estimatedCostUSD, provenance.model) and
    // `…successWritesReceiptAtomicallyWithMatchingCost` (receipt model + cost).
    // Those pins live with the notes fixtures and stay green — the digest `model`
    // threading never reaches the notes path.
}

/// FIX 2 — `stripPreamble` only accepts a verify output that carries a digest
/// beginning at a LINE-START `## HEADER`; anything else THROWS so the pipeline's
/// do/catch falls back to the good draft instead of persisting malformed output.
@Suite struct DigestVerifyStripPreambleTests {
    @Test func lineStartHeaderExtractsFromHeaderTrimmed() throws {
        // Auditor narrates reasoning, THEN emits the corrected digest at a
        // line-start `## HEADER`: the preamble is dropped, the digest survives.
        let input = """
            no errors of attribution found in the draft; one date fixed.

            ## HEADER
            meeting: Vexatron Labs roadmap review
            date: 2026-06-15
            """
        let result = try ClaudeSummarizationEngine.stripPreamble(input)
        #expect(result.hasPrefix("## HEADER"))
        #expect(result.contains("Vexatron Labs roadmap review"))
        #expect(!result.contains("no errors of attribution"))
    }

    @Test func pureProseWithNoHeaderThrows() {
        // The auditor returned reasoning prose only, no `## HEADER` → THROW, so
        // the pipeline keeps the draft.
        let input = "I reviewed the draft against the transcript and it looks fine."
        #expect(throws: EngineError.self) {
            _ = try ClaudeSummarizationEngine.stripPreamble(input)
        }
    }

    @Test func headerOnlyInsideBacktickedReasoningThrows() {
        // `## HEADER` appears ONLY mid-line inside backticked reasoning — never
        // at column 0 — so it does not qualify as the start of a digest. THROW.
        let input = "The draft's `## HEADER` line already has the right date, so no change is needed."
        #expect(throws: EngineError.self) {
            _ = try ClaudeSummarizationEngine.stripPreamble(input)
        }
    }

    @Test func emptyInputThrows() {
        #expect(throws: EngineError.self) {
            _ = try ClaudeSummarizationEngine.stripPreamble("")
        }
    }
}
