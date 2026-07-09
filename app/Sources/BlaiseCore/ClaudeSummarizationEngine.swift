import Foundation
import os

/// C6 engine 2: Anthropic Messages API via raw URLSession (no SDK
/// dependency exists for Swift; raw HTTPS is the supported path).
/// Structured output via `output_config.format` json_schema (the current
/// API mechanism; the top-level `output_format` is deprecated).
///
/// Privacy boundary (project policy): the request carries EXACTLY these fields
/// and nothing else — transcript text with speaker labels, meeting title,
/// meeting date, attendee NAMES (no emails), the vocabulary list, the
/// user's name and aliases, the dominant language. All of it travels inside
/// the two prompt strings assembled by the shared `NotesPromptBuilder`;
/// asserted by a unit test over the assembled request.
public actor ClaudeSummarizationEngine: SummarizationEngine {
    public static let engineID = "claude-sonnet"
    /// Engine identity = model + runtime (D5). Both the notes and the digest
    /// calls run on this model (Sonnet) — the cost/receipt accounting is keyed on
    /// it, so the wire model must match unconditionally.
    public static let model = "claude-sonnet-4-6"
    /// #102: the OPTIONAL combined-audit model (md-v6 STEP-1/STEP-2 auditor).
    /// `claude-haiku-4-5` is the exact API id (Haiku 4.5, 200K ctx, $1/$5 in the
    /// current model table). Used ONLY by the combined-audit call, ONLY when the
    /// Haiku-audit toggle is ON; notes + synthesis + md-v5 verify/reconcile stay
    /// on `model` (Sonnet). The wire body, the receipt `model:` field, and the
    /// cost feeding both the ledger AND `DigestResult.estimatedCostUSD` all carry
    /// this SAME string for a Haiku audit call (the consistency invariant — see
    /// `cost(of:model:)` / `pricePerMTok(for:)`).
    public static let haikuModel = "claude-haiku-4-5"
    public static let apiKeyConfigKey = "apiKey"
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let apiVersion = "2023-06-01"
    /// Verified pricing (live 2026-06-10). Sonnet 4.6 = $3 in / $15 out per MTok.
    public static let inputUSDPerMTok = 3.0
    public static let outputUSDPerMTok = 15.0
    /// #102: Haiku 4.5 pricing = $1 in / $5 out per MTok (≈⅓ of Sonnet). Used by
    /// `pricePerMTok(for:)` for an EXACT `haikuModel` string match only.
    public static let haikuInputUSDPerMTok = 1.0
    public static let haikuOutputUSDPerMTok = 5.0
    public static let maxInputTokens = 150_000
    public static let maxTokensFirstAttempt = 8_192
    public static let maxTokensRetryAttempt = 16_384
    /// #104 notes-completeness guard (PROVISIONAL, calibratable — like #100's).
    /// The output-token floor below which even a tiny meeting's notes look
    /// anomalously thin: the stub-anomaly gate (C) never fires above it, so a
    /// genuinely short meeting whose notes run ≥ this many output tokens is
    /// never second-guessed. Queue: confirm against the real 505-stub's numbers.
    public static let stubMinOutputFloor = 400
    /// #104: transcript-proportional output expectation (output tokens per
    /// transcript byte denominator). A meeting's notes should scale with its
    /// transcript; `transcriptBytes / slope` is the per-meeting output floor
    /// the size-anomaly gate (C) compares against. Larger slope → laxer gate.
    public static let stubTranscriptSlope = 20
    /// Per-attempt request timeouts: 16k tokens of output at realistic
    /// stream rates does not fit 120 s.
    public static let firstAttemptTimeout: TimeInterval = 300
    public static let retryAttemptTimeout: TimeInterval = 480

    public nonisolated let id: String = ClaudeSummarizationEngine.engineID
    public nonisolated let displayName = "Claude Sonnet 4.6 (cloud)"
    public nonisolated let kind: EngineKind = .cloud
    /// Lightweight (D17): an HTTPS call, no local weights — the runtime
    /// fallback may auto-fire to this engine.
    public nonisolated let loadProfile: EngineLoadProfile = .lightweight
    /// #102 (F9): `pricingSummary`/`estimatedPerMeetingUSD` describe the engine's
    /// SONNET calls (notes + synthesis), the dominant cost. `0.074` is the
    /// conservative Sonnet per-meeting estimate used ONLY by the reprocess-budget
    /// UI dialog — it is display-only, never ledgered, so over-estimating the
    /// budget is safe even when the combined-audit runs on the cheaper Haiku. The
    /// LEDGER truth is always the per-receipt model + `cost(of:model:)`.
    public nonisolated let costDescriptor: EngineCostDescriptor? = EngineCostDescriptor(
        pricingSummary: "US$ 3 in / US$ 15 out per million tokens (Claude Sonnet 4.6)",
        estimatedPerMeetingUSD: 0.074
    )
    public static let descriptors: [EngineConfigDescriptor] = [
        EngineConfigDescriptor(
            key: ClaudeSummarizationEngine.apiKeyConfigKey, label: "Anthropic API key",
            kind: .secret, required: true)
    ]
    public nonisolated let configDescriptors: [EngineConfigDescriptor] =
        ClaudeSummarizationEngine.descriptors

    /// HTTP seam for tests; the default performs the real request.
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let configuration: EngineConfiguration
    private let ledger: CloudSpendLedger
    private let transport: Transport
    private let chain = EngineTaskChain()
    private let logger = Logger(subsystem: BlaiseBundle.identifier, category: "notes.claude")

    /// Services are constructor-injected at the composition root (C2);
    /// `EngineConfiguration` carries user config only.
    public init(configuration: EngineConfiguration, ledger: CloudSpendLedger) {
        self.init(configuration: configuration, ledger: ledger, transport: Self.urlSessionTransport)
    }

    init(configuration: EngineConfiguration, ledger: CloudSpendLedger, transport: @escaping Transport) {
        self.configuration = configuration
        self.ledger = ledger
        self.transport = transport
    }

    private static let urlSessionTransport: Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw EngineError.transient("non-HTTP response from the Anthropic API")
        }
        return (data, http)
    }

    // MARK: - Availability

    public func availability() async -> EngineAvailability {
        let key: String?
        do {
            key = try await configuration.value(for: Self.apiKeyConfigKey)
        } catch {
            return .unavailable(reason: "configuration unreadable: \(error)")
        }
        guard let key, !key.isEmpty else {
            return .unavailable(reason: "Anthropic API key not configured")
        }
        if (try? await ledger.ceilingReached()) == true {
            return .unavailable(reason: EngineFallbackReason.monthlyCeiling)
        }
        return .available
    }

    public func prepare() async throws {}

    // MARK: - Generation (chained single-flight)

    public func generateNotes(_ request: NotesRequest, purpose: CloudSpendPurpose) async throws -> NotesResult {
        try await chain.run { try await self.generateNotesBody(request, purpose: purpose) }
    }

    private func generateNotesBody(_ request: NotesRequest, purpose: CloudSpendPurpose) async throws -> NotesResult {
        if Task.isCancelled { throw EngineError.cancelled }

        let apiKey: String?
        do {
            apiKey = try await configuration.value(for: Self.apiKeyConfigKey)
        } catch {
            throw EngineError.transient("cannot read engine configuration: \(error)")
        }
        guard let apiKey, !apiKey.isEmpty else {
            throw EngineError.configurationMissing(key: Self.apiKeyConfigKey)
        }

        // B-2 ceiling enforcement (100 % → hard stop; a fallback trigger —
        // with the shipped heavyweight-only fallback the run resolves to
        // notes-pending and self-heals after the month rolls over, D17).
        if try await ledger.ceilingReached() {
            throw EngineError.notAvailable(reason: EngineFallbackReason.monthlyCeiling)
        }

        // Prompt version: live read-through of the global setting
        // (`notes.promptVersion`); unset/invalid → the shipped default.
        let promptVersion = NotesPromptBuilder.resolve(
            try? await configuration.globalValue(key: NotesPromptBuilder.versionSettingsKey))
        let system = NotesPromptBuilder.systemPrompt(for: promptVersion)
        let user = NotesPromptBuilder.userMessage(for: request)

        // Conservative pre-screen against the 150k budget (UTF-8 bytes / 3 —
        // an OVER-count for realistic text, so it refuses early; an
        // under-estimate merely means the API itself rejects the oversized
        // prompt, which maps to the same fallback reason below).
        let estimatedTokens = (system.utf8.count + user.utf8.count) / 3
        if estimatedTokens > Self.maxInputTokens {
            throw EngineError.permanent(EngineFallbackReason.inputTooLong)
        }

        // First attempt at 8_192 output tokens; `stop_reason == "max_tokens"`
        // → ONE retry at 16_384, then permanent.
        // G10 §1: the cancel token binds at ATTEMPT BOUNDARIES. Checked before
        // each send (here and before the retry), never mid-flight: an in-flight
        // attempt is shielded so its usage/receipt always land — interrupting
        // it would make Anthropic-side spend invisible to the ledger.
        if CancellationToken.current?.isCancelled == true { throw EngineError.cancelled }
        let first = try await performAttempt(
            apiKey: apiKey, system: system, user: user,
            maxTokens: Self.maxTokensFirstAttempt, timeout: Self.firstAttemptTimeout,
            request: request, purpose: purpose)
        var final: APIResponse
        if first.stopReason == "max_tokens" {
            logger.warning("notes output hit max_tokens at \(Self.maxTokensFirstAttempt); retrying at \(Self.maxTokensRetryAttempt)")
            // Attempt boundary: a cancel landing during the first send takes
            // effect HERE, before the retry — no new call starts.
            if CancellationToken.current?.isCancelled == true { throw EngineError.cancelled }
            let second = try await performAttempt(
                apiKey: apiKey, system: system, user: user,
                maxTokens: Self.maxTokensRetryAttempt, timeout: Self.retryAttemptTimeout,
                request: request, purpose: purpose)
            if second.stopReason == "max_tokens" {
                throw EngineError.permanent("output exceeds retry budget")
            }
            final = second
        } else {
            // #104 notes-completeness guard (F1). This branch is a STRUCTURAL
            // PEER of the max_tokens `if` — it is reached ONLY when the first
            // attempt ended on its own (end_turn etc.), NEVER on the
            // max_tokens→retry path. So the stub retry can add AT MOST one extra
            // call here; the run is bounded at 2 calls total, NEVER 3.
            //
            // Detect the "valid JSON but thin/truncated stub" class (the
            // 505-token-stub: full summary, detailed_notes cut mid-sentence,
            // empty action arrays, anomalously low output vs transcript size) and
            // retry ONCE at the higher budget, then ship the better of the two.
            // The retry rides the same atomic ledger+receipt shield as
            // performAttempt's every other call — both attempts are billed.
            //
            // Ceiling note (F6): like the max_tokens retry, this stub retry does
            // NOT re-check the monthly ceiling, so a meeting near 100 % may
            // overspend by ONE bounded call. Accepted, mirrors the existing path.
            //
            // Scope (F6/D5): cloud notes only. The MLX local engine is a
            // SCOPED-RISK exclusion — constrained decoding guarantees VALID JSON,
            // not semantic completeness, so a thin-but-valid local stub is
            // possible; out of scope for v1.
            final = first
            if let firstDecoded = Self.decodeNotes(first) {
                let transcriptBytes = request.transcript.reduce(0) { $0 + $1.text.utf8.count }
                let firstStub = Self.isLikelyStub(
                    firstDecoded, outputTokens: first.usage.outputTokens,
                    transcriptBytes: transcriptBytes)
                if firstStub && CancellationToken.current?.isCancelled != true {
                    // FIX 1 (always-finalizes invariant): the first attempt is a
                    // decodable, thin-but-VALID stub and is ALREADY billed. If the
                    // retry throws — transient/network/permanent — that throw must
                    // NOT propagate and discard the usable first result; the meeting
                    // must still ship the first stub. So the retry call AND its
                    // decode are wrapped: on ANY throw we keep `final = first`
                    // (already set above) and log, then fall through to the shared
                    // decode/assembly on the good first attempt.
                    do {
                        let retry = try await performAttempt(
                            apiKey: apiKey, system: system, user: user,
                            maxTokens: Self.maxTokensRetryAttempt, timeout: Self.retryAttemptTimeout,
                            request: request, purpose: purpose)
                        let retryDecoded = Self.decodeNotes(retry)
                        let firstCand = StubCandidate(
                            attempt: .first, response: first, decoded: firstDecoded,
                            isStub: firstStub)
                        let retryStub =
                            retryDecoded.map {
                                Self.isLikelyStub(
                                    $0, outputTokens: retry.usage.outputTokens,
                                    transcriptBytes: transcriptBytes)
                            } ?? true
                        let retryCand = StubCandidate(
                            attempt: .retry, response: retry, decoded: retryDecoded,
                            isStub: retryStub)
                        let winner = Self.bestOfNotes(firstCand, retryCand)
                        Self.logStubRetry(
                            logger: logger, first: firstCand, retry: retryCand,
                            chosenIsFirst: winner.attempt == .first,
                            firstBits: Self.stubBits(
                                firstDecoded, outputTokens: first.usage.outputTokens,
                                transcriptBytes: transcriptBytes))
                        final = winner.response
                    } catch {
                        // The retry failed; the first stub is already billed and
                        // decodable. Keep it (final stays `first`) so the meeting
                        // finalizes with the thin-but-valid notes rather than
                        // failing on a transient/permanent retry error.
                        logger.warning(
                            "notes stub retry threw, keeping first attempt: \(error.localizedDescription, privacy: .public)")
                    }
                } else {
                    // Always-log even when no retry fires (F4): the predicate bits
                    // for this single attempt, so a near-miss is observable.
                    let bits = Self.stubBits(
                        firstDecoded, outputTokens: first.usage.outputTokens,
                        transcriptBytes: transcriptBytes)
                    logger.info(
                        """
                        notes completeness: no stub retry \
                        (first_stop=\(first.stopReason ?? "nil", privacy: .public) \
                        first_out=\(first.usage.outputTokens, privacy: .public) \
                        C=\(bits.c, privacy: .public) A=\(bits.a, privacy: .public) \
                        B=\(bits.b, privacy: .public) fired=\(firstStub, privacy: .public))
                        """)
                }
            }
        }

        // A refusal is deterministic — retrying the same content cannot succeed
        // (impl audit M-2).
        if final.stopReason == "refusal" {
            throw EngineError.permanent("model refused the request")
        }
        guard let text = final.content.first(where: { $0.type == "text" })?.text else {
            throw EngineError.permanent("response carried no text content block (stop_reason: \(final.stopReason ?? "nil"))")
        }
        let response: NotesEngineResponse
        do {
            response = try NotesEngineResponse.decode(from: Data(text.utf8))
        } catch {
            // Structured output is decoder-enforced server-side; a non-schema
            // 200 is deterministic for this request, not transient (M-2).
            throw EngineError.permanent("response text was not schema-shaped JSON: \(error)")
        }

        let (structured, mapping) = response.toNotes()
        return NotesResult(
            structured: structured,
            usage: EngineUsage(
                inputUnits: final.usage.inputTokens,
                outputUnits: final.usage.outputTokens,
                estimatedCostUSD: Self.cost(of: final.usage)
            ),
            provenance: NotesProvenance(
                engine: id,
                model: Self.model,
                pipelineVersion: "",
                runtime: "anthropic-messages-api/URLSession",
                promptVersion: promptVersion.rawValue
            ),
            speakerNameMapping: mapping
        )
    }

    // MARK: - #104 notes-completeness guard (stub detect + best-of-two)

    /// Which of the two attempts a candidate is — a stable identity tag so the
    /// caller can map `bestOfNotes`'s winner back to an attempt (APIResponse is a
    /// value type; reference identity is unavailable).
    enum StubAttempt { case first, retry }

    /// A decoded attempt paired with its wire response and stub verdict, so
    /// `bestOfNotes` can order the two candidates without re-decoding. `decoded`
    /// is nil when a 200 returned non-schema text (a retry could legitimately
    /// produce that); such a candidate is always treated as a stub.
    struct StubCandidate {
        let attempt: StubAttempt
        let response: APIResponse
        let decoded: NotesEngineResponse?
        let isStub: Bool
    }

    /// The terminal-punctuation set for the truncation gate (A). A detailed_notes
    /// body whose last non-whitespace char is NOT one of these "ended
    /// mid-sentence". Terminal punctuation ONLY — deliberately NOT widened for
    /// markdown (`-`, `*`, `#`) or PT abbreviations, which would make A
    /// never-fire on legitimately formatted notes (F2, Codex split-A).
    static let stubTerminalChars: Set<Character> = [
        ".", "!", "?", "\u{2026}", ":", "\"", "\u{201D}", ")", "]", "}",
    ]

    /// Decode a 200's text content block into `NotesEngineResponse`, or nil if it
    /// carried no text block or non-schema text. Pure mirror of the shared
    /// decode at the bottom of `generateNotesBody` (the text-guard + decode),
    /// applied LOCALLY to a single attempt so the stub predicate can run before
    /// the shared decode picks the winner.
    static func decodeNotes(_ response: APIResponse) -> NotesEngineResponse? {
        guard let text = response.content.first(where: { $0.type == "text" })?.text else {
            return nil
        }
        return try? NotesEngineResponse.decode(from: Data(text.utf8))
    }

    /// The three predicate bits (F4 always-log). C = size-anomaly gate;
    /// A = truncation; B = all-action-arrays-empty. Pure/deterministic.
    static func stubBits(
        _ r: NotesEngineResponse, outputTokens: Int, transcriptBytes: Int
    ) -> (c: Bool, a: Bool, b: Bool) {
        let floor = max(stubMinOutputFloor, transcriptBytes / stubTranscriptSlope)
        let c = outputTokens < floor
        let trimmed = r.detailedNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        // A fires when the body ends mid-sentence: empty body, or a last
        // non-whitespace char outside the terminal set. (An empty body is
        // maximally truncated.)
        let a: Bool
        if let last = trimmed.last {
            a = !stubTerminalChars.contains(last)
        } else {
            a = true
        }
        let b = r.decisions.isEmpty && r.actionItems.isEmpty && r.userActionItems.isEmpty
        return (c, a, b)
    }

    /// #104 predicate (F2): the notes look like a thin/truncated STUB. Fires iff
    /// **C AND (A OR B′)** — the size-anomaly gate C is mandatory (the
    /// load-bearing false-positive guard: a normal meeting whose output scales
    /// with its transcript never retries), AND at least one of truncation (A) or
    /// total emptiness (B′). Decoupled (Codex): a stub can be truncated WITH
    /// decisions present (A without B), or complete-shaped but wholly empty (B
    /// without A). Pure, static, deterministic.
    static func isLikelyStub(
        _ r: NotesEngineResponse, outputTokens: Int, transcriptBytes: Int
    ) -> Bool {
        let bits = stubBits(r, outputTokens: outputTokens, transcriptBytes: transcriptBytes)
        return bits.c && (bits.a || bits.b)
    }

    /// True when this candidate's notes are "rich" — terminal-terminated AND at
    /// least one non-empty action array (the inverse of the stub shape). A nil
    /// decode is never rich. Used as `bestOfNotes` tie-break rung 3.
    static func isRich(_ c: StubCandidate) -> Bool {
        guard let r = c.decoded else { return false }
        let trimmed = r.detailedNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last, stubTerminalChars.contains(last) else { return false }
        return !(r.decisions.isEmpty && r.actionItems.isEmpty && r.userActionItems.isEmpty)
    }

    /// #104 best-of-two (F3): pick the winner of the first + retry attempts by a
    /// deterministic ORDERING (never outputTokens alone), NEVER throwing — the
    /// meeting ALWAYS finalizes `ready`, degraded-but-not-stuck:
    ///   1. non-stub beats stub;
    ///   2. a non-`max_tokens` stop_reason beats `max_tokens` (a capped retry is
    ///      incomplete — it must not win on raw length);
    ///   3. richer (terminal-terminated AND non-empty action arrays);
    ///   4. DECODABLE (decoded != nil) beats nil-decoded — a non-schema 200 whose
    ///      text fails the schema decode is the WORST candidate: the shared decode
    ///      at the bottom of `generateNotesBody` throws `.permanent` on it, so a
    ///      nil-decoded winner would FAIL the meeting. This rung sits ABOVE the
    ///      raw-length rung so a higher-`outputTokens` nil retry can never beat a
    ///      decodable first (FIX 2, always-finalizes invariant);
    ///   5. higher `outputTokens`;
    ///   6. deterministic tie → `first`.
    /// Combined with rung 4, `bestOfNotes` NEVER returns a nil-decoded winner when
    /// a decodable candidate exists.
    static func bestOfNotes(_ first: StubCandidate, _ retry: StubCandidate) -> StubCandidate {
        // 1. non-stub beats stub.
        if first.isStub != retry.isStub {
            return first.isStub ? retry : first
        }
        // 2. non-max_tokens beats max_tokens.
        let firstCapped = first.response.stopReason == "max_tokens"
        let retryCapped = retry.response.stopReason == "max_tokens"
        if firstCapped != retryCapped {
            return firstCapped ? retry : first
        }
        // 3. richer beats not-rich.
        let firstRich = isRich(first)
        let retryRich = isRich(retry)
        if firstRich != retryRich {
            return firstRich ? first : retry
        }
        // 4. decodable (decoded != nil) beats nil-decoded. A nil-decoded candidate
        // would throw `.permanent` at the shared decode and fail the meeting, so a
        // decodable candidate ALWAYS wins over a nil one — even if the nil one has
        // more output tokens (so this MUST precede rung 5).
        let firstDecodable = first.decoded != nil
        let retryDecodable = retry.decoded != nil
        if firstDecodable != retryDecodable {
            return firstDecodable ? first : retry
        }
        // 5. higher outputTokens.
        if first.response.usage.outputTokens != retry.response.usage.outputTokens {
            return first.response.usage.outputTokens >= retry.response.usage.outputTokens
                ? first : retry
        }
        // 6. deterministic tie → first.
        return first
    }

    /// F4 always-log the structured stub-retry outcome: both stop_reasons, both
    /// outputTokens, the first attempt's C/A/B′ bits, the chosen attempt, and a
    /// double-stub-same-shape flag (a recurring DETERMINISTIC failure — not the
    /// one-off variance the guard is meant for — so it is detectable, never
    /// silently shipped).
    nonisolated static func logStubRetry(
        logger: Logger, first: StubCandidate, retry: StubCandidate,
        chosenIsFirst: Bool, firstBits: (c: Bool, a: Bool, b: Bool)
    ) {
        let doubleStubSameShape =
            first.isStub && retry.isStub
            && first.response.stopReason == retry.response.stopReason
            && first.response.usage.outputTokens == retry.response.usage.outputTokens
        logger.warning(
            """
            notes completeness: stub retry fired \
            (first_stop=\(first.response.stopReason ?? "nil", privacy: .public) \
            first_out=\(first.response.usage.outputTokens, privacy: .public) \
            retry_stop=\(retry.response.stopReason ?? "nil", privacy: .public) \
            retry_out=\(retry.response.usage.outputTokens, privacy: .public) \
            C=\(firstBits.c, privacy: .public) A=\(firstBits.a, privacy: .public) \
            B=\(firstBits.b, privacy: .public) \
            retry_is_stub=\(retry.isStub, privacy: .public) \
            chose=\(chosenIsFirst ? "first" : "retry", privacy: .public) \
            double_stub_same_shape=\(doubleStubSameShape, privacy: .public))
            """)
    }

    // MARK: - Digest generation (G14 — second synthesis call)

    /// Backoff before the ONE bounded transient re-issue of the digest call
    /// (H1). Short and bounded — the digest-pending self-heal is the real
    /// safety net; this only shortens the window before it engages.
    static let digestRetryBackoff: Duration = .milliseconds(750)

    public func generateDigest(_ request: DigestRequest, purpose: CloudSpendPurpose) async throws -> DigestResult {
        try await chain.run { try await self.generateDigestBody(request, purpose: purpose) }
    }

    private func generateDigestBody(_ request: DigestRequest, purpose: CloudSpendPurpose) async throws -> DigestResult {
        let version = DigestPromptBuilder.shippedVersion
        let system = DigestPromptBuilder.systemPrompt(for: version)
        let user = DigestPromptBuilder.userMessage(for: request)
        // #102 (F4 scope): synthesis ALWAYS runs Sonnet — the Haiku toggle only
        // applies to the combined-audit. Pass `Self.model` explicitly because the
        // deep `runDigestCall` requires a non-defaulted `model`.
        return try await runDigestCall(
            system: system, user: user, request: request, purpose: purpose, version: version,
            model: Self.model)
    }

    /// OPTIONAL second pass — the env-gated (`BLAISE_DIGEST_VERIFY=1`) Sonnet
    /// auditor/repairer. Runs the SAME cloud path as `generateDigestBody` (same
    /// `runDigestCall` → same request build, decode/parse/ledger, one-shot bounded
    /// retry, maxTokens/timeout), but with the verify system prompt and a user
    /// message that appends the just-synthesized DRAFT digest for repair. Bills
    /// under the caller's `purpose`. Wrapped in `chain.run` like
    /// `generateDigest`/`generateNotes` so it serializes with the engine's other
    /// in-flight cloud calls; the pipeline's fallback-on-throw to the draft is
    /// preserved (any throw — including a verify that produced no parseable digest
    /// — falls back to the good draft).
    /// #102: `model` defaults to `Self.model` (Sonnet) — the md-v5 verify pass is
    /// OUT OF SCOPE for the Haiku audit (D1/F4) and always runs Sonnet under the
    /// default. The param exists only so the deep `runDigestCall` can require a
    /// non-defaulted `model` (an omission anywhere = compile error, never a
    /// silent Sonnet).
    public func verifyDigest(
        _ request: DigestRequest, draftDigest: String, purpose: CloudSpendPurpose,
        model: String = ClaudeSummarizationEngine.model
    ) async throws -> DigestResult {
        try await chain.run {
            try await self.verifyDigestBody(
                request, draftDigest: draftDigest, purpose: purpose, model: model)
        }
    }

    private func verifyDigestBody(
        _ request: DigestRequest, draftDigest: String, purpose: CloudSpendPurpose,
        model: String
    ) async throws -> DigestResult {
        let version = DigestPromptBuilder.shippedVersion
        let system = DigestPromptBuilder.systemDigestVerifyPrompt
        let user = DigestPromptBuilder.verifyUserMessage(for: request, draftDigest: draftDigest)
        let result = try await runDigestCall(
            system: system, user: user, request: request, purpose: purpose, version: version,
            model: model)
        // Harden the verify output: the Sonnet auditor sometimes narrates its
        // reasoning before emitting `## HEADER`. Drop any such chain-of-thought
        // preamble so the persisted digest starts at the first LINE-START
        // `## HEADER`. If no parseable digest is present, `stripPreamble` THROWS —
        // the pipeline's do/catch then falls back to the good draft, never
        // persisting malformed verify output.
        return DigestResult(
            digest: try Self.stripPreamble(result.digest),
            usage: result.usage,
            promptVersion: result.promptVersion)
    }

    /// md-v5 THIRD pass — the notes-anchored recall reconciler. Same cloud path
    /// as `verifyDigest`/`generateDigest` (same `runDigestCall` + one-shot bounded
    /// retry + ledger), with the reconcile system prompt and a user message that
    /// appends the human-notes recall checklist + the just-verified digest. Runs
    /// AFTER the transcript-only verify; ADDS only notes items the transcript body
    /// grounds. Bills under the caller's `purpose`. Any throw (incl. no parseable
    /// digest) falls back to the pre-reconcile digest in the pipeline — recall
    /// reconciliation never costs the good digest.
    /// #102: `model` defaults to `Self.model` (Sonnet) — the md-v5 reconcile pass
    /// is OUT OF SCOPE for the Haiku audit (D1/F4) and always runs Sonnet under
    /// the default; the param exists only to satisfy the non-defaulted deep
    /// `runDigestCall` requirement (F2).
    public func reconcileDigest(
        _ request: DigestRequest, draftDigest: String, purpose: CloudSpendPurpose,
        model: String = ClaudeSummarizationEngine.model
    ) async throws -> DigestResult {
        try await chain.run {
            try await self.reconcileDigestBody(
                request, draftDigest: draftDigest, purpose: purpose, model: model)
        }
    }

    private func reconcileDigestBody(
        _ request: DigestRequest, draftDigest: String, purpose: CloudSpendPurpose,
        model: String
    ) async throws -> DigestResult {
        let version = DigestPromptBuilder.shippedVersion
        let system = DigestPromptBuilder.systemDigestReconcilePrompt
        let user = DigestPromptBuilder.reconcileUserMessage(for: request, digest: draftDigest)
        let result = try await runDigestCall(
            system: system, user: user, request: request, purpose: purpose, version: version,
            model: model)
        // Same preamble hardening as the verify pass (the reconciler narrates its
        // add/reject audit before `## HEADER`).
        return DigestResult(
            digest: try Self.stripPreamble(result.digest),
            usage: result.usage,
            promptVersion: result.promptVersion)
    }

    /// md-v6 COMBINED AUDIT — the single pass that REPLACES the md-v5
    /// verify-then-reconcile pair. Same cloud path as `verifyDigest`/
    /// `reconcileDigest`/`generateDigest` (same `runDigestCall` + one-shot bounded
    /// retry + ledger), with the combined-audit system prompt and a user message
    /// that appends BOTH the human-notes recall checklist (for STEP 2) AND the
    /// just-synthesized DRAFT digest (to verify in STEP 1, reconcile in STEP 2).
    /// The transcript + draft ride ONE call rather than two. Runs AFTER synthesis;
    /// STEP 1 repairs grounding errors against the transcript, STEP 2 ADDS only
    /// notes items the transcript body grounds. Bills under the caller's
    /// `purpose`. Any throw (incl. no parseable digest) falls back to the
    /// synthesis draft in the pipeline — the audit never costs the good digest.
    /// #102: `model` defaults to `Self.model` (Sonnet) — omitting it at the call
    /// site is byte-identical to today. The pipeline passes
    /// `ClaudeSummarizationEngine.haikuModel` ONLY when the Haiku-audit toggle is
    /// ON; that one resolved string flows to the wire body, the receipt `model:`,
    /// AND `cost(of:model:)` (consistency invariant). This is the ONLY call that
    /// may run on Haiku.
    public func combinedAuditDigest(
        _ request: DigestRequest, draftDigest: String, purpose: CloudSpendPurpose,
        model: String = ClaudeSummarizationEngine.model
    ) async throws -> DigestResult {
        try await chain.run {
            try await self.combinedAuditDigestBody(
                request, draftDigest: draftDigest, purpose: purpose, model: model)
        }
    }

    private func combinedAuditDigestBody(
        _ request: DigestRequest, draftDigest: String, purpose: CloudSpendPurpose,
        model: String
    ) async throws -> DigestResult {
        let version = DigestPromptBuilder.shippedVersion
        let system = DigestPromptBuilder.systemDigestCombinedAuditPrompt
        let user = DigestPromptBuilder.combinedAuditUserMessage(for: request, draftDigest: draftDigest)
        let result = try await runDigestCall(
            system: system, user: user, request: request, purpose: purpose, version: version,
            model: model)
        // Same preamble hardening as the verify/reconcile passes: the combined
        // auditor narrates its STEP-1 fixes + STEP-2 additions before `## HEADER`.
        // If no parseable digest is present, `stripPreamble` THROWS and the
        // pipeline falls back to the good synthesis draft.
        return DigestResult(
            digest: try Self.stripPreamble(result.digest),
            usage: result.usage,
            promptVersion: result.promptVersion)
    }

    /// Extract the corrected digest from the verify pass's output, dropping any
    /// chain-of-thought preamble the auditor narrates before it. The digest is
    /// the substring from the FIRST LINE-START `## HEADER` (column 0, multiline)
    /// to the end, trimmed. A `## HEADER` that appears only mid-line (e.g. inside
    /// backticked reasoning) does NOT qualify. THROWS `.transient` when no
    /// line-start `## HEADER` is present OR the extracted text is empty/whitespace
    /// — the caller's fallback then keeps the good draft rather than persisting
    /// malformed output.
    static func stripPreamble(_ s: String) throws -> String {
        let ns = s as NSString
        // `^## HEADER` anchored at a line start (multiline), so a `## HEADER`
        // buried mid-line / inside backticks does not satisfy the contract.
        guard
            let regex = try? NSRegularExpression(
                pattern: "^## HEADER", options: [.anchorsMatchLines]),
            let match = regex.firstMatch(
                in: s, options: [], range: NSRange(location: 0, length: ns.length))
        else {
            throw EngineError.transient("verify produced no parseable digest")
        }
        let extracted = ns
            .substring(from: match.range.location)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !extracted.isEmpty else {
            throw EngineError.transient("verify produced no parseable digest")
        }
        return extracted
    }

    /// The shared digest cloud path: API-key/ceiling preflight, input-size guard,
    /// the H1 one-shot bounded transient retry, refusal/empty-text handling, and
    /// the `DigestResult` assembly. Called by the synthesis pass
    /// (`generateDigestBody`), the md-v5 verify/reconcile passes, and the md-v6
    /// combined audit; only the `system`/`user` strings differ. maxTokens/timeout
    /// are identical for all (the `performDigestAttempt` request build).
    ///
    /// #102 (F2): `model` is NON-DEFAULTED — every caller must pass it explicitly
    /// so an omission is a COMPILE error, never a silent Sonnet. It feeds BOTH
    /// `performDigestAttempt` calls (initial + retry — same model, F3) AND the
    /// returned `DigestResult.estimatedCostUSD` (F1 sink d): the input-size guard
    /// below is the combined-audit's OWN `maxInputTokens=150_000` (system+user)/3
    /// pre-screen (the audit bytes differ from synthesis — it drops the synthesis
    /// system prompt and adds the checklist + draft). That own-guard binds before
    /// any send, and 150K < Haiku's 200K window (~52K margin), so a meeting that
    /// reaches the audit always fits Haiku — no Haiku-specific cap is needed. (If
    /// `maxInputTokens` is ever raised above 200K, add a Haiku cap here.)
    private func runDigestCall(
        system: String, user: String, request: DigestRequest,
        purpose: CloudSpendPurpose, version: DigestPromptVersion, model: String
    ) async throws -> DigestResult {
        // Honor both task cancellation AND an inter-attempt CancellationToken
        // cancel (parity with `generateNotesBody`): the pipeline binds the token,
        // not necessarily structured-task cancellation.
        if Task.isCancelled || CancellationToken.current?.isCancelled == true {
            throw EngineError.cancelled
        }

        let apiKey: String?
        do {
            apiKey = try await configuration.value(for: Self.apiKeyConfigKey)
        } catch {
            throw EngineError.transient("cannot read engine configuration: \(error)")
        }
        guard let apiKey, !apiKey.isEmpty else {
            throw EngineError.configurationMissing(key: Self.apiKeyConfigKey)
        }
        if try await ledger.ceilingReached() {
            throw EngineError.notAvailable(reason: EngineFallbackReason.monthlyCeiling)
        }

        let estimatedTokens = (system.utf8.count + user.utf8.count) / 3
        if estimatedTokens > Self.maxInputTokens {
            throw EngineError.permanent(EngineFallbackReason.inputTooLong)
        }

        // H1 bounded transient-retry — NET-NEW, modelled on the max_tokens
        // re-issue structure (one bounded retry, then give up): a 429/529/5xx
        // (mapped to `.transient`) is re-issued ONCE after a short bounded
        // backoff before the error is allowed to escape to the digest-pending
        // path. A non-transient error escapes immediately (retrying a refusal /
        // bad request cannot help).
        let response: APIResponse
        do {
            response = try await performDigestAttempt(
                apiKey: apiKey, system: system, user: user, request: request,
                purpose: purpose, model: model)
        } catch let error as EngineError where Self.isDigestRetryable(error) {
            if Task.isCancelled || CancellationToken.current?.isCancelled == true {
                throw EngineError.cancelled
            }
            try? await Task.sleep(for: Self.digestRetryBackoff)
            if Task.isCancelled || CancellationToken.current?.isCancelled == true {
                throw EngineError.cancelled
            }
            // #102 (F3): the bounded retry carries the SAME `model` as the initial
            // attempt — a Haiku audit that retries re-issues a Haiku body.
            response = try await performDigestAttempt(
                apiKey: apiKey, system: system, user: user, request: request,
                purpose: purpose, model: model)
        }

        if response.stopReason == "refusal" {
            throw EngineError.permanent("model refused the digest request")
        }
        guard let text = response.content.first(where: { $0.type == "text" })?.text else {
            throw EngineError.permanent(
                "digest response carried no text content block (stop_reason: \(response.stopReason ?? "nil"))")
        }
        return DigestResult(
            digest: text,
            usage: EngineUsage(
                inputUnits: response.usage.inputTokens,
                outputUnits: response.usage.outputTokens,
                // #102 (F1 sink d): the returned `estimatedCostUSD` is model-aware
                // and MUST agree with the ledgered cost + receipt model for this
                // call. Display-only (the ledger bump happens inside
                // `performDigestAttempt`'s shield), but it is the same divergence
                // class as the prior `BLAISE_DIGEST_MODEL` HIGH, so it threads the
                // SAME `model`.
                estimatedCostUSD: Self.cost(of: response.usage, model: model)),
            promptVersion: version.rawValue)
    }

    /// True for the errors the digest's one-shot bounded retry re-issues: a
    /// rate-limit (429) / overload (529) / 5xx, all of which `mapHTTPError`
    /// classifies as `.transient`, plus a `.transient` network blip.
    static func isDigestRetryable(_ error: EngineError) -> Bool {
        if case .transient = error { return true }
        return false
    }

    /// One digest Messages attempt — a free-text (no json_schema) call. ANY
    /// 200 carrying `usage` ledgers + receipts under `purpose` inside the
    /// cancellation shield (same discipline as the notes attempt).
    ///
    /// #102 (F1/F2): `model` is NON-DEFAULTED and feeds THREE of the four
    /// consistency sinks for this call — (a) the wire body `model`
    /// (`buildDigestURLRequest`), (b) the ledger/accumulator cost
    /// (`cost(of:model:)`), and (c) the receipt `model:` field — all from the
    /// SAME string. (The fourth, `DigestResult.estimatedCostUSD`, is set in
    /// `runDigestCall`.) The atomic bump+receipt shield (`Task.detached` →
    /// `ledger.add`) is UNCHANGED; `model` is a `String` (value type) captured BY
    /// VALUE into the detached shield, so the shield's honesty is preserved.
    private func performDigestAttempt(
        apiKey: String, system: String, user: String,
        request: DigestRequest, purpose: CloudSpendPurpose, model: String
    ) async throws -> APIResponse {
        let urlRequest = try Self.buildDigestURLRequest(
            apiKey: apiKey, system: system, user: user,
            maxTokens: Self.maxTokensRetryAttempt, timeout: Self.retryAttemptTimeout,
            model: model)

        let data: Data
        let http: HTTPURLResponse
        do {
            let transport = self.transport
            let ledger = self.ledger
            let id = self.id
            // #102: capture the resolved `model` BY VALUE into the detached shield
            // so the bump cost + receipt model can never diverge from the wire
            // body — the same string that built `urlRequest` above.
            let auditModel = model
            (data, http) = try await Task.detached {
                let (data, http) = try await transport(urlRequest)
                if http.statusCode == 200, let usage = Self.decodeUsage(from: data) {
                    try await ledger.add(
                        Self.cost(of: usage, model: auditModel),
                        receipt: CloudSpendLedger.ReceiptDraft(
                            engineID: id,
                            model: auditModel,
                            purpose: purpose,
                            meetingID: request.meeting.id,
                            inputTokens: usage.inputTokens,
                            outputTokens: usage.outputTokens))
                }
                return (data, http)
            }.value
        } catch let error as EngineError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw EngineError.transient("digest request timed out after \(Int(Self.retryAttemptTimeout)) s")
        } catch {
            throw EngineError.transient("network failure: \(error)")
        }

        if http.statusCode == 200 {
            do {
                return try JSONDecoder().decode(APIResponse.self, from: data)
            } catch {
                throw EngineError.transient("unparseable API response: \(error)")
            }
        }
        let apiError = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data)
        let message = apiError?.error.message ?? String(decoding: data.prefix(600), as: UTF8.self)
        let errorType = apiError?.error.type ?? ""
        throw Self.mapHTTPError(statusCode: http.statusCode, type: errorType, message: message)
    }

    /// The digest Messages request: free-text (NO `output_config` json_schema —
    /// the digest is Markdown, not a schema-shaped document), temperature only.
    ///
    /// #102 (F2/F7): `model` is NON-DEFAULTED — the wire body carries whatever the
    /// caller resolved (Sonnet for synthesis/verify/reconcile; optionally Haiku
    /// for the combined audit). Both Sonnet 4.6 and Haiku 4.5 accept `temperature`
    /// (we pin digest decode to 0), so it is included unconditionally for either
    /// model. The wire model here is the SAME string the caller feeds to the
    /// receipt `model:` and `cost(of:model:)` (the consistency invariant — the
    /// prior `BLAISE_DIGEST_MODEL` HIGH was a wire/cost/receipt divergence).
    static func buildDigestURLRequest(
        apiKey: String, system: String, user: String, maxTokens: Int, timeout: TimeInterval,
        model: String
    ) throws -> URLRequest {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "temperature": NotesDecodingParameters.digestTemperature,
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]
        let serialized = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = serialized
        return request
    }

    /// One Messages API attempt. ANY response carrying `usage` updates the
    /// ledger — billed failures count. G7: that same accounting write also
    /// leaves a receipt (one transaction; receipt-failure isolation lives in
    /// the ledger).
    private func performAttempt(
        apiKey: String, system: String, user: String, maxTokens: Int, timeout: TimeInterval,
        request: NotesRequest, purpose: CloudSpendPurpose
    ) async throws -> APIResponse {
        let urlRequest = try Self.buildURLRequest(
            apiKey: apiKey, system: system, user: user, maxTokens: maxTokens, timeout: timeout)

        let data: Data
        let http: HTTPURLResponse
        do {
            // G10 §1 (H-3): SHIELD the in-flight send AND the ledger write that
            // records its spend from task cancellation. The transport
            // (URLSession) is cancellation-aware and GRDB's `pool.write` is too;
            // a `task.cancel()` mid-attempt would otherwise abandon the call OR
            // — the subtler hole — let the 200 return but then drop the
            // `ledger.add` on the cancelled caller task, leaving the
            // already-incurred Anthropic-side spend invisible (defeating the
            // shield's entire purpose and Hard Floor 3's cost ceiling). The
            // shield therefore spans transport + the conditional ledger write in
            // ONE detached task; a detached task does not inherit the parent's
            // cancellation, so both run to completion. The cancel still takes
            // effect at the NEXT attempt boundary (the token check above), and
            // the bounded timeout caps cancel latency.
            let transport = self.transport
            let ledger = self.ledger
            let id = self.id
            (data, http) = try await Task.detached {
                let (data, http) = try await transport(urlRequest)
                // Ledger inside the shield, BEFORE returning, ONLY on a billed
                // 200 (a crash can at worst under-count one call; accepted).
                // G7: the same write leaves a receipt.
                if http.statusCode == 200, let usage = Self.decodeUsage(from: data) {
                    try await ledger.add(
                        Self.cost(of: usage),
                        receipt: CloudSpendLedger.ReceiptDraft(
                            engineID: id,
                            model: Self.model,
                            purpose: purpose,
                            meetingID: request.meeting.id,
                            inputTokens: usage.inputTokens,
                            outputTokens: usage.outputTokens))
                }
                return (data, http)
            }.value
        } catch let error as EngineError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw EngineError.transient("request timed out after \(Int(timeout)) s")
        } catch {
            throw EngineError.transient("network failure: \(error)")
        }

        if http.statusCode == 200 {
            let response: APIResponse
            do {
                response = try JSONDecoder().decode(APIResponse.self, from: data)
            } catch {
                throw EngineError.transient("unparseable API response: \(error)")
            }
            // The spend for this 200 was ALREADY ledgered inside the shield.
            return response
        }

        let apiError = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data)
        let message = apiError?.error.message ?? String(decoding: data.prefix(600), as: UTF8.self)
        let errorType = apiError?.error.type ?? ""
        throw Self.mapHTTPError(statusCode: http.statusCode, type: errorType, message: message)
    }

    static func mapHTTPError(statusCode: Int, type: String, message: String) -> EngineError {
        switch statusCode {
        case 401, 403:
            return .configurationMissing(key: apiKeyConfigKey)
        case 429, 529:
            return .transient("API \(statusCode) \(type): \(message)")
        case 400:
            // An over-long prompt the pre-screen under-estimated maps to the
            // same fallback reason as the local refusal.
            if message.lowercased().contains("too long") || message.lowercased().contains("too many tokens") {
                return .permanent(EngineFallbackReason.inputTooLong)
            }
            return .permanent("API 400 \(type): \(message)")
        case 500...:
            return .transient("API \(statusCode) \(type): \(message)")
        default:
            return .permanent("API \(statusCode) \(type): \(message)")
        }
    }

    /// #102: the per-MTok price pair for `model`. Haiku is matched by EXACT
    /// string equality (never substring/prefix) → a future haiku-shaped id won't
    /// silently inherit the (1,5) pricing. EVERY other string — including the
    /// Sonnet `model`, an unknown, or a haiku-shaped-but-not-exact id — falls
    /// through to the (3,15) Sonnet pair, the CONSERVATIVE default (F6).
    static func pricePerMTok(for model: String) -> (input: Double, output: Double) {
        if model == haikuModel {
            return (haikuInputUSDPerMTok, haikuOutputUSDPerMTok)
        }
        return (inputUSDPerMTok, outputUSDPerMTok)
    }

    /// #102: model-aware cost. Defaults to `Self.model` (Sonnet) so every
    /// non-audit caller (notes, synthesis, md-v5 verify/reconcile) bills Sonnet
    /// unchanged; the combined-audit threads its resolved `auditModel`. The model
    /// string passed here MUST be identical to the one on the wire body and in
    /// the receipt `model:` field for any single call (the consistency invariant
    /// — the prior `BLAISE_DIGEST_MODEL` HIGH was exactly this divergence).
    static func cost(of usage: APIUsage, model: String = ClaudeSummarizationEngine.model) -> Double {
        let price = pricePerMTok(for: model)
        return Double(usage.inputTokens) / 1_000_000 * price.input
            + Double(usage.outputTokens) / 1_000_000 * price.output
    }

    /// The billed `usage` from a 200 body, or nil if the body is not
    /// schema-shaped. Used inside the cancellation shield to ledger the spend
    /// of an in-flight attempt BEFORE returning; an unparseable 200 ledgers
    /// nothing (the caller then maps it to `.transient`, unchanged).
    static func decodeUsage(from data: Data) -> APIUsage? {
        (try? JSONDecoder().decode(APIResponse.self, from: data))?.usage
    }

    /// Request construction (unit-tested: URL, headers minus the real key,
    /// the json_schema block, decoding pins — temperature ONLY, no top_p:
    /// the API rejects both together on Claude 4+ models).
    static func buildURLRequest(
        apiKey: String, system: String, user: String, maxTokens: Int, timeout: TimeInterval
    ) throws -> URLRequest {
        // The schema is spliced in as its RAW authored JSON, not via
        // JSONSerialization: dictionary round-trips destroy property order
        // (.sortedKeys puts "action_items" first), and structured-output
        // generation follows schema property order — alphabetical order
        // makes the model emit the item arrays before any summary exists,
        // which empirically collapses the whole document to an empty
        // skeleton (C6 bake-off finding, 2026-06-10: 3/3 empty at 48
        // output tokens vs rich notes with authored order).
        let placeholder = "BLAISE-NOTES-SCHEMA-SPLICE-7F2A"
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "temperature": NotesDecodingParameters.temperature,
            "system": system,
            "messages": [["role": "user", "content": user]],
            "output_config": [
                "format": [
                    "type": "json_schema",
                    "schema": placeholder,
                ]
            ],
        ]
        let serialized = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        guard let template = String(data: serialized, encoding: .utf8),
            template.contains("\"\(placeholder)\"")
        else {
            throw EngineError.permanent("request body serialization failed")
        }
        let spliced = template.replacingOccurrences(
            of: "\"\(placeholder)\"", with: NotesResponseSchema.json)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = Data(spliced.utf8)
        return request
    }

    // MARK: - Wire types

    struct APIResponse: Decodable {
        struct ContentBlock: Decodable {
            var type: String
            var text: String?
        }

        var content: [ContentBlock]
        var stopReason: String?
        var usage: APIUsage

        enum CodingKeys: String, CodingKey {
            case content, usage
            case stopReason = "stop_reason"
        }
    }

    struct APIUsage: Decodable {
        var inputTokens: Int
        var outputTokens: Int

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }

    struct APIErrorEnvelope: Decodable {
        struct Detail: Decodable {
            var type: String
            var message: String
        }

        var error: Detail
    }
}
