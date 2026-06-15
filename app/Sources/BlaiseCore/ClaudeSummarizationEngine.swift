import Foundation
import os

/// C6 engine 2: Anthropic Messages API via raw URLSession (no SDK
/// dependency exists for Swift; raw HTTPS is the supported path).
/// Structured output via `output_config.format` json_schema (the current
/// API mechanism; the top-level `output_format` is deprecated).
///
/// Privacy boundary (CLAUDE.md): the request carries EXACTLY these fields
/// and nothing else — transcript text with speaker labels, meeting title,
/// meeting date, attendee NAMES (no emails), the vocabulary list, the
/// user's name and aliases, the dominant language. All of it travels inside
/// the two prompt strings assembled by the shared `NotesPromptBuilder`;
/// asserted by a unit test over the assembled request.
public actor ClaudeSummarizationEngine: SummarizationEngine {
    public static let engineID = "claude-sonnet"
    /// Engine identity = model + runtime (D5).
    public static let model = "claude-sonnet-4-6"
    public static let apiKeyConfigKey = "apiKey"
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let apiVersion = "2023-06-01"
    /// Verified pricing (research/c6_summarization.md, live 2026-06-10).
    public static let inputUSDPerMTok = 3.0
    public static let outputUSDPerMTok = 15.0
    public static let maxInputTokens = 150_000
    public static let maxTokensFirstAttempt = 8_192
    public static let maxTokensRetryAttempt = 16_384
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
        let final: APIResponse
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
            final = first
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

    // MARK: - Digest generation (G14 — second synthesis call)

    /// Backoff before the ONE bounded transient re-issue of the digest call
    /// (H1). Short and bounded — the digest-pending self-heal is the real
    /// safety net; this only shortens the window before it engages.
    static let digestRetryBackoff: Duration = .milliseconds(750)

    public func generateDigest(_ request: DigestRequest, purpose: CloudSpendPurpose) async throws -> DigestResult {
        try await chain.run { try await self.generateDigestBody(request, purpose: purpose) }
    }

    private func generateDigestBody(_ request: DigestRequest, purpose: CloudSpendPurpose) async throws -> DigestResult {
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
        if try await ledger.ceilingReached() {
            throw EngineError.notAvailable(reason: EngineFallbackReason.monthlyCeiling)
        }

        let version = DigestPromptBuilder.shippedVersion
        let system = DigestPromptBuilder.systemPrompt(for: version)
        let user = DigestPromptBuilder.userMessage(for: request)

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
                apiKey: apiKey, system: system, user: user, request: request, purpose: purpose)
        } catch let error as EngineError where Self.isDigestRetryable(error) {
            if Task.isCancelled { throw EngineError.cancelled }
            try? await Task.sleep(for: Self.digestRetryBackoff)
            if Task.isCancelled { throw EngineError.cancelled }
            response = try await performDigestAttempt(
                apiKey: apiKey, system: system, user: user, request: request, purpose: purpose)
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
                estimatedCostUSD: Self.cost(of: response.usage)),
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
    private func performDigestAttempt(
        apiKey: String, system: String, user: String,
        request: DigestRequest, purpose: CloudSpendPurpose
    ) async throws -> APIResponse {
        let urlRequest = try Self.buildDigestURLRequest(
            apiKey: apiKey, system: system, user: user,
            maxTokens: Self.maxTokensRetryAttempt, timeout: Self.retryAttemptTimeout)

        let data: Data
        let http: HTTPURLResponse
        do {
            let transport = self.transport
            let ledger = self.ledger
            let id = self.id
            (data, http) = try await Task.detached {
                let (data, http) = try await transport(urlRequest)
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
    static func buildDigestURLRequest(
        apiKey: String, system: String, user: String, maxTokens: Int, timeout: TimeInterval
    ) throws -> URLRequest {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "temperature": NotesDecodingParameters.temperature,
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

    static func cost(of usage: APIUsage) -> Double {
        Double(usage.inputTokens) / 1_000_000 * inputUSDPerMTok
            + Double(usage.outputTokens) / 1_000_000 * outputUSDPerMTok
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
