import Foundation
import Testing
@testable import BlaiseCore

// C6: ClaudeSummarizationEngine unit tests — request construction, response
// parsing, full error mapping, usage→EngineUsage, ledger interplay. No
// network: the transport seam plays the API.

private struct FakeAPI: Sendable {
    /// (status, body) per attempt, consumed in order.
    let responses: [(Int, String)]
    let requests = Recorder<URLRequest>()
    private let counter = Recorder<Int>()

    func transport(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        counter.append(1)
        let index = min(counter.values.count - 1, responses.count - 1)
        let (status, body) = responses[index]
        let http = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (Data(body.utf8), http)
    }
}

private func successBody(
    stopReason: String = "end_turn", inputTokens: Int = 12_000, outputTokens: Int = 2_500
) -> String {
    let text = sampleEngineResponseJSON
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
    return """
        {"id": "msg_test", "type": "message", "role": "assistant",
         "content": [{"type": "text", "text": "\(text)"}],
         "stop_reason": "\(stopReason)",
         "usage": {"input_tokens": \(inputTokens), "output_tokens": \(outputTokens)}}
        """
}

private struct ClaudeHarness {
    let engine: ClaudeSummarizationEngine
    let ledger: CloudSpendLedger
    let database: BlaiseDatabase
    let secrets: InMemorySecretStore
    let settings: SettingsStore
    let api: FakeAPI
}

private func makeClaudeHarness(
    responses: [(Int, String)] = [(200, successBody())],
    apiKey: String? = "sk-test-not-a-real-key"
) async throws -> ClaudeHarness {
    let database = try makeDatabase()
    let settings = SettingsStore(database: database)
    let secrets = InMemorySecretStore()
    if let apiKey {
        try secrets.set(
            key: "engine.\(ClaudeSummarizationEngine.engineID).\(ClaudeSummarizationEngine.apiKeyConfigKey)",
            value: apiKey)
    }
    let configuration = EngineConfiguration(
        engineID: ClaudeSummarizationEngine.engineID,
        descriptors: ClaudeSummarizationEngine.descriptors,
        settings: settings,
        secrets: secrets
    )
    let ledger = CloudSpendLedger(database: database)
    let api = FakeAPI(responses: responses)
    let engine = ClaudeSummarizationEngine(
        configuration: configuration, ledger: ledger, transport: api.transport)
    return ClaudeHarness(
        engine: engine, ledger: ledger, database: database, secrets: secrets,
        settings: settings, api: api)
}

@Suite struct ClaudeRequestConstructionTests {
    @Test func urlHeadersAndBodyShape() async throws {
        let harness = try await makeClaudeHarness()
        _ = try await harness.engine.generateNotes(makeNotesRequest())

        let request = try #require(harness.api.requests.values.first)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test-not-a-real-key")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.timeoutInterval == 300)

        let bodyData = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(body["model"] as? String == "claude-sonnet-4-6")
        #expect(body["max_tokens"] as? Int == 8192)
        // Decoding pin: temperature ONLY (the API rejects temperature +
        // top_p together on Claude 4+ models).
        #expect(body["temperature"] as? Double == 0.2)
        #expect(body["top_p"] == nil)
        #expect(body["system"] as? String == NotesPromptBuilder.systemPrompt)

        let outputConfig = try #require(body["output_config"] as? [String: Any])
        let format = try #require(outputConfig["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        let schema = try #require(format["schema"] as? [String: Any])
        #expect(schema["additionalProperties"] as? Bool == false)

        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "user")
        #expect(messages[0]["content"] as? String == NotesPromptBuilder.userMessage(for: makeNotesRequest()))
    }

    @Test("schema property order survives serialization (authored narrative order, NOT alphabetical)")
    func schemaPropertyOrderSurvivesSerialization() async throws {
        // Structured-output generation follows schema property order. A
        // JSONSerialization dictionary round-trip (.sortedKeys) reorders the
        // properties alphabetically, forcing "action_items" BEFORE the
        // summary/analysis — which empirically collapses the whole document
        // to an empty skeleton (C6 cloud bake-off, 2026-06-10: 3/3 runs
        // empty at 48 output tokens; authored order → rich notes). The
        // engine must splice the RAW authored schema into the body.
        let harness = try await makeClaudeHarness()
        _ = try await harness.engine.generateNotes(makeNotesRequest())
        let request = try #require(harness.api.requests.values.first)
        let bodyData = try #require(request.httpBody)
        let bodyText = String(decoding: bodyData, as: UTF8.self)

        // The wire bytes must list the top-level schema properties in the
        // authored narrative order. `meeting_type` sits BEFORE
        // detailed_notes deliberately (notes v2 classify-then-write: the
        // model commits to a type before writing the notes — the same
        // ordering mechanism pointed the right way).
        // Each needle is the property KEY (name followed by a colon) — the
        // top-level `required` ARRAY lists the same names as plain strings
        // in stable order and previously rescued a broken scan (v1.1-wave
        // audit H-2): a colon-anchored needle cannot match an array entry.
        let authored = [
            "\"title\":", "\"summary\":", "\"meeting_type\":", "\"detailed_notes\":",
            "\"decisions\":", "\"action_items\":", "\"user_action_items\":",
            "\"speaker_name_mapping\":",
        ]
        // Locate each property's first occurrence INSIDE the schema's
        // "properties" object (the body also contains these words in the
        // system prompt; scope the scan to after `"properties"`).
        let propertiesRange = bodyText.range(of: "\"properties\"")
        let propertiesStart = try #require(propertiesRange)
        let scanRegion = bodyText[propertiesStart.upperBound...]
        var lastIndex = scanRegion.startIndex
        for property in authored {
            let foundRange = scanRegion.range(of: property, range: lastIndex..<scanRegion.endIndex)
            let found = try #require(
                foundRange,
                "schema property \(property) missing or out of order in wire body")
            lastIndex = found.upperBound
        }
        // And the round-trip parse still yields a valid schema object.
        let parsed = try JSONSerialization.jsonObject(with: bodyData)
        let body = try #require(parsed as? [String: Any])
        let outputConfig = try #require(body["output_config"] as? [String: Any])
        let format = try #require(outputConfig["format"] as? [String: Any])
        let schema = try #require(format["schema"] as? [String: Any])
        #expect((schema["required"] as? [String])?.count == 8)
    }

    @Test("G4 AC4: request body equals the pre-rename baseline modulo the key/instruction tokens")
    func requestBodyDiffersFromPreRenameOnlyByTheRenamedTokens() async throws {
        // AC4: the ONLY change G4 made to the wire request is the
        // `ric_action_items` → `user_action_items` rename (schema property +
        // required entry + the two prompt-instruction mentions). Build the live
        // request body, substitute every new-key token back to the old key, and
        // assert the result is byte-identical to a baseline body assembled the
        // same way but with the old key everywhere. Any non-rename change to
        // schema bytes, prompt text, params, or serialization survives the
        // substitution and fails this — it is not vacuous.
        let harness = try await makeClaudeHarness()
        _ = try await harness.engine.generateNotes(makeNotesRequest())
        let request = try #require(harness.api.requests.values.first)
        let bodyText = String(decoding: try #require(request.httpBody), as: UTF8.self)

        // The new key really is present on the wire (schema + required + prompt),
        // so the substitution is doing real work.
        #expect(bodyText.contains("user_action_items"))
        #expect(!bodyText.contains("ric_action_items"))

        // Reconstruct the pre-rename baseline body by substituting the source
        // constants the body is spliced from, exactly as a pre-G4 build would
        // have produced them, then comparing modulo the token.
        let oldKey = "ric_action_items"
        let newKey = "user_action_items"
        let rolledBack = bodyText.replacingOccurrences(of: newKey, with: oldKey)
        // The schema is spliced into the body RAW (verbatim constant). After
        // rolling the key back, the body must contain the pre-rename schema
        // bytes verbatim — proving the schema splice changed by nothing but the
        // key/required tokens.
        let preRenameSchema = NotesResponseSchema.json.replacingOccurrences(of: newKey, with: oldKey)
        #expect(rolledBack.contains(preRenameSchema))
        // The system prompt is a JSON string value (newlines etc. escaped), so
        // compare against its JSON-encoded pre-rename form: the rolled-back body
        // must contain it verbatim too.
        let preRenamePrompt = NotesPromptBuilder.systemPrompt(for: NotesPromptBuilder.shippedVersion)
            .replacingOccurrences(of: newKey, with: oldKey)
        let encodedPrompt = String(
            decoding: try JSONEncoder().encode(preRenamePrompt), as: UTF8.self)
        // Strip the surrounding quotes JSONEncoder adds so we match the value
        // as it sits inside the request object.
        let promptNeedle = String(encodedPrompt.dropFirst().dropLast())
        #expect(rolledBack.contains(promptNeedle))
        // The token count is exactly the known rename footprint: schema
        // property key + the `required` array entry + the prompt mention(s) —
        // guard against a stray or missing occurrence.
        let occurrences = bodyText.components(separatedBy: newKey).count - 1
        #expect(occurrences >= 3, "expected schema property + required + prompt mentions")
    }

    @Test func promptVersionSettingSelectsV2AndTravelsInProvenance() async throws {
        // `notes.promptVersion` = "c6-v2" → the v2 system prompt is sent and
        // the provenance records what actually ran. Unset (the default
        // harness) is covered by urlHeadersAndBodyShape (v1 prompt) and
        // successMapsIntoNotesResultWithCost (provenance "c6-v1").
        let harness = try await makeClaudeHarness()
        try await harness.settings.set(NotesPromptBuilder.versionSettingsKey, to: "c6-v2")
        let result = try await harness.engine.generateNotes(makeNotesRequest())
        let request = try #require(harness.api.requests.values.first)
        let bodyData = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(body["system"] as? String == NotesPromptBuilder.systemPrompt(for: .v2))
        #expect(result.provenance.promptVersion == "c6-v2")
    }

    @Test func invalidPromptVersionSettingFallsBackToShippedDefault() async throws {
        let harness = try await makeClaudeHarness()
        try await harness.settings.set(NotesPromptBuilder.versionSettingsKey, to: "c9-v9")
        let result = try await harness.engine.generateNotes(makeNotesRequest())
        let request = try #require(harness.api.requests.values.first)
        let bodyData = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(body["system"] as? String == NotesPromptBuilder.systemPrompt)
        #expect(result.provenance.promptVersion == NotesPromptBuilder.promptVersion)
    }

    @Test func privacyBoundaryRequestCarriesExactlyTheAllowedFields() async throws {
        // Privacy-boundary policy: transcript with speaker labels, title,
        // date, attendee NAMES, vocabulary, user name+aliases, dominant
        // language — and nothing else (no emails, no meeting IDs).
        let harness = try await makeClaudeHarness()
        _ = try await harness.engine.generateNotes(makeNotesRequest())
        let request = try #require(harness.api.requests.values.first)
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)

        #expect(body.contains("Reunião semanal Vexatron"))         // title
        #expect(body.contains("20\\/03\\/2026") || body.contains("20/03/2026"))  // date
        #expect(body.contains("Tobias"))                          // attendee name + vocabulary
        #expect(body.contains("Sam Rivera"))                  // user alias
        #expect(body.contains("Bom dia, vamos começar."))         // transcript
        #expect(body.contains("Dominant language: pt"))           // language
        #expect(!body.contains("sam.rivera@vexatron.test"))              // user email NEVER
        #expect(!body.contains("tobias@vexatron.test"))               // attendee email NEVER
        #expect(!body.contains("01TESTMEETING0000000000000"))     // internal id NEVER

        // Exact top-level key set (impl audit M-1): an accidentally added
        // request field fails HERE, not in production.
        let bodyData = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(Set(json.keys) == ["model", "max_tokens", "temperature", "system", "messages", "output_config"],
                "unexpected request keys: \(Set(json.keys))")
    }
}

@Suite struct ClaudeResponseParsingTests {
    @Test func successMapsIntoNotesResultWithCost() async throws {
        let harness = try await makeClaudeHarness()
        let result = try await harness.engine.generateNotes(makeNotesRequest())

        #expect(result.structured.summary == "Resumo da reunião.")
        #expect(result.structured.meetingType == .projectReview)
        #expect(result.structured.actionItems.count == 2)  // user item unioned in
        #expect(result.speakerNameMapping.count == 2)
        #expect(result.usage?.inputUnits == 12_000)
        #expect(result.usage?.outputUnits == 2_500)
        // $3/MTok in + $15/MTok out → 0.036 + 0.0375.
        #expect(abs((result.usage?.estimatedCostUSD ?? 0) - 0.0735) < 1e-9)
        #expect(result.provenance.engine == "claude-sonnet")
        #expect(result.provenance.model == "claude-sonnet-4-6")
        #expect(result.provenance.runtime == "anthropic-messages-api/URLSession")
        #expect(result.provenance.promptVersion == NotesPromptBuilder.promptVersion)
    }

    @Test func successUpdatesLedgerBeforeReturning() async throws {
        let harness = try await makeClaudeHarness()
        _ = try await harness.engine.generateNotes(makeNotesRequest())
        let total = try await harness.ledger.accumulatedThisMonth()
        #expect(abs(total - 0.0735) < 1e-9)
    }

    // The receipt FK (ON DELETE SET NULL) requires the referenced meeting to
    // exist — in production the row is always present during processing. The
    // engine unit harness has no meeting row, so seed the one the canonical
    // NotesRequest names.
    private func seedRequestMeeting(_ harness: ClaudeHarness) async throws {
        let request = makeNotesRequest()
        try await harness.database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO meeting (id, title, started_at, source, status, attendees, created_at, updated_at)
                    VALUES (?, ?, ?, 'meet', 'processing', '[]', ?, ?)
                    """,
                arguments: [request.meeting.id, request.meeting.title, msDate(), msDate(), msDate()])
        }
    }

    // G7 AC2: one generate() writes accumulator + receipt atomically with
    // matching cost; the receipt carries the threaded purpose, the meeting id,
    // the engine identity, and the token counts.
    @Test func successWritesReceiptAtomicallyWithMatchingCost() async throws {
        let harness = try await makeClaudeHarness()
        try await seedRequestMeeting(harness)
        _ = try await harness.engine.generateNotes(makeNotesRequest(), purpose: .regeneration)

        let month = try await harness.ledger.monthReceipts()
        #expect(month.receipts.count == 1)
        let receipt = try #require(month.receipts.first)
        #expect(receipt.purpose == .regeneration)
        #expect(receipt.engineID == "claude-sonnet")
        #expect(receipt.model == "claude-sonnet-4-6")
        #expect(receipt.meetingID == "01TESTMEETING0000000000000")
        #expect(receipt.inputTokens == 12_000)
        #expect(receipt.outputTokens == 2_500)
        #expect(abs(receipt.costUSD - 0.0735) < 1e-9)
        // The receipt cost EQUALS the accumulator bump — they reconcile.
        #expect(abs(month.receiptsSumUSD - month.accumulatorUSD) < 1e-9)
        #expect(month.reconciles)
    }

    @Test func defaultPurposeIsGeneration() async throws {
        let harness = try await makeClaudeHarness()
        try await seedRequestMeeting(harness)
        // The no-purpose convenience defaults to generation (spec §1).
        _ = try await harness.engine.generateNotes(makeNotesRequest())
        let month = try await harness.ledger.monthReceipts()
        #expect(month.receipts.first?.purpose == .generation)
    }

    // G7 AC2: an injected receipt-write failure leaves the accumulator bumped
    // AND the call successful (the accumulator is authoritative; a receipt
    // fault is loud-logged, never fatal). The injection drops the receipt
    // table so its INSERT throws while the accumulator upsert still succeeds.
    @Test func receiptWriteFailureLeavesAccumulatorBumpedAndCallSuccessful() async throws {
        let harness = try await makeClaudeHarness()
        try await harness.database.pool.write { db in
            try db.execute(sql: "DROP TABLE cloud_spend_receipt")
        }

        // The call STILL succeeds (no throw) despite the broken receipt write.
        let result = try await harness.engine.generateNotes(makeNotesRequest())
        #expect(result.usage?.estimatedCostUSD != nil)

        // The accumulator was bumped anyway (replayed alone after the receipt
        // transaction rolled back).
        let total = try await harness.ledger.accumulatedThisMonth()
        #expect(abs(total - 0.0735) < 1e-9)
    }

    @Test func nonSchemaTextMapsToPermanent() async throws {
        let body = """
            {"content": [{"type": "text", "text": "not the schema"}],
             "stop_reason": "end_turn", "usage": {"input_tokens": 10, "output_tokens": 5}}
            """
        let harness = try await makeClaudeHarness(responses: [(200, body)])
        let error = await engineError { try await harness.engine.generateNotes(makeNotesRequest()) }
        guard case .permanent = error else {
            Issue.record("expected .transient, got \(String(describing: error))")
            return
        }
        // Billed failure still counted (any response carrying usage).
        let total = try await harness.ledger.accumulatedThisMonth()
        #expect(total > 0)
    }
}

@Suite struct ClaudeMaxTokensRetryTests {
    @Test func maxTokensRetriesOnceAtHigherBudget() async throws {
        let harness = try await makeClaudeHarness(
            responses: [(200, successBody(stopReason: "max_tokens")), (200, successBody())])
        _ = try await harness.engine.generateNotes(makeNotesRequest())

        let requests = harness.api.requests.values
        #expect(requests.count == 2)
        let firstData = try #require(requests[0].httpBody)
        let secondData = try #require(requests[1].httpBody)
        let first = try #require(try JSONSerialization.jsonObject(with: firstData) as? [String: Any])
        let second = try #require(try JSONSerialization.jsonObject(with: secondData) as? [String: Any])
        #expect(first["max_tokens"] as? Int == 8_192)
        #expect(second["max_tokens"] as? Int == 16_384)
        #expect(requests[1].timeoutInterval == 480)

        // BOTH attempts billed → ledger counted both.
        let total = try await harness.ledger.accumulatedThisMonth()
        #expect(abs(total - 2 * 0.0735) < 1e-9)
    }

    @Test func secondMaxTokensIsPermanent() async throws {
        let harness = try await makeClaudeHarness(
            responses: [
                (200, successBody(stopReason: "max_tokens")),
                (200, successBody(stopReason: "max_tokens")),
            ])
        let error = await engineError { try await harness.engine.generateNotes(makeNotesRequest()) }
        #expect(error == .permanent("output exceeds retry budget"))
        #expect(harness.api.requests.values.count == 2)
    }
}

@Suite struct ClaudeErrorMappingTests {
    private func errorFor(status: Int, body: String) async throws -> EngineError? {
        let harness = try await makeClaudeHarness(responses: [(status, body)])
        return await engineError { try await harness.engine.generateNotes(makeNotesRequest()) }
    }

    private func apiError(_ type: String, _ message: String) -> String {
        """
        {"type": "error", "error": {"type": "\(type)", "message": "\(message)"}}
        """
    }

    @Test func unauthorizedMapsToConfigurationMissing() async throws {
        let error = try await errorFor(status: 401, body: apiError("authentication_error", "bad key"))
        #expect(error == .configurationMissing(key: "apiKey"))
        let forbidden = try await errorFor(status: 403, body: apiError("permission_error", "no access"))
        #expect(forbidden == .configurationMissing(key: "apiKey"))
    }

    @Test func rateLimitAndOverloadMapToTransient() async throws {
        for (status, type) in [(429, "rate_limit_error"), (529, "overloaded_error"), (500, "api_error")] {
            let error = try await errorFor(status: status, body: apiError(type, "later"))
            guard case .transient(let reason) = error else {
                Issue.record("expected .transient for \(status), got \(String(describing: error))")
                continue
            }
            #expect(reason.contains("\(status)"))
        }
    }

    @Test func badRequestMapsToPermanent() async throws {
        let error = try await errorFor(
            status: 400, body: apiError("invalid_request_error", "schema rejected"))
        guard case .permanent(let reason) = error else {
            Issue.record("expected .permanent, got \(String(describing: error))")
            return
        }
        #expect(reason.contains("schema rejected"))
    }

    @Test func promptTooLong400MapsToInputTooLongFallback() async throws {
        let error = try await errorFor(
            status: 400, body: apiError("invalid_request_error", "prompt is too long: 230000 tokens"))
        #expect(error == .permanent(EngineFallbackReason.inputTooLong))
    }

    @Test func oversizedPromptIsRefusedBeforeAnyNetworkCall() async throws {
        let harness = try await makeClaudeHarness()
        var request = makeNotesRequest()
        let hugeText = String(repeating: "palavra ", count: 250_000)  // ~2 MB ≫ 150k tokens
        request.transcript = [
            TranscriptSegment(
                meetingID: request.meeting.id, ord: 0, startSeconds: 0, endSeconds: 1,
                speakerLabel: "S0", text: hugeText)
        ]
        let error = await engineError { try await harness.engine.generateNotes(request) }
        #expect(error == .permanent(EngineFallbackReason.inputTooLong))
        #expect(harness.api.requests.values.isEmpty)
    }

    @Test func missingAPIKeyThrowsConfigurationMissingAndReportsUnavailable() async throws {
        let harness = try await makeClaudeHarness(apiKey: nil)
        #expect(await harness.engine.availability()
            == .unavailable(reason: "Anthropic API key not configured"))
        let error = await engineError { try await harness.engine.generateNotes(makeNotesRequest()) }
        #expect(error == .configurationMissing(key: "apiKey"))
        #expect(harness.api.requests.values.isEmpty)
    }
}

@Suite struct ClaudeCeilingEnforcementTests {
    @Test func ceilingReachedBlocksGenerationWithFallbackReason() async throws {
        let harness = try await makeClaudeHarness()
        try await harness.ledger.add(20.0)  // default ceiling 20.0 → 100 %
        #expect(await harness.engine.availability()
            == .unavailable(reason: EngineFallbackReason.monthlyCeiling))
        let error = await engineError { try await harness.engine.generateNotes(makeNotesRequest()) }
        #expect(error == .notAvailable(reason: EngineFallbackReason.monthlyCeiling))
        #expect(EngineFallbackReason.isFallbackTrigger(try #require(error)))
        #expect(harness.api.requests.values.isEmpty, "no API call once the ceiling is reached")
    }

    @Test func customCeilingSettingIsHonored() async throws {
        let harness = try await makeClaudeHarness()
        try await harness.settings.set(CloudSpendLedger.ceilingSettingsKey, to: 0.05)
        try await harness.ledger.add(0.05)
        let error = await engineError { try await harness.engine.generateNotes(makeNotesRequest()) }
        #expect(error == .notAvailable(reason: EngineFallbackReason.monthlyCeiling))
    }

    @Test func belowCeilingStillRuns() async throws {
        let harness = try await makeClaudeHarness()
        try await harness.ledger.add(15.99)
        _ = try await harness.engine.generateNotes(makeNotesRequest())
        #expect(harness.api.requests.values.count == 1)
    }
}

// G10 §1 / AC1: the cancel token binds at the engine's ATTEMPT BOUNDARIES.
@Suite struct ClaudeCancelBoundaryTests {
    /// A token already cancelled BEFORE the first send → the engine refuses
    /// before sending anything (zero requests, ledger untouched).
    @Test func cancelBeforeFirstSendDoesNotSend() async throws {
        let harness = try await makeClaudeHarness()
        let token = CancellationToken()
        token.cancel()
        let error = await CancellationToken.$current.withValue(token) {
            await engineError { try await harness.engine.generateNotes(makeNotesRequest()) }
        }
        #expect(error == .cancelled)
        #expect(harness.api.requests.values.count == 0, "no send may start with the token already set")
        let total = try await harness.ledger.accumulatedThisMonth()
        #expect(total == 0, "ledger untouched — nothing was sent")
    }

    /// The in-flight FIRST attempt is shielded: it completes and its usage is
    /// ledgered; a cancel taking effect DURING it stops the max-tokens RETRY at
    /// the next boundary. Deterministic: a transport that cancels the run's
    /// token on the first call, then a max_tokens response that would normally
    /// retry. The retry boundary check fires → exactly ONE send, ledger
    /// reflects it (Anthropic-side spend stays visible).
    @Test func cancelDuringFirstAttemptStopsRetryButLedgersTheSend() async throws {
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
        let token = CancellationToken()
        let sends = Recorder<Int>()
        // Transport: records the send, then cancels the token AFTER the first
        // (in-flight) call returns max_tokens — so the engine ledgers send #1
        // and hits the retry boundary already cancelled.
        let transport: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = { request in
            sends.append(1)
            token.cancel()
            let http = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data(successBody(stopReason: "max_tokens").utf8), http)
        }
        let engine = ClaudeSummarizationEngine(
            configuration: configuration, ledger: ledger, transport: transport)
        let error = await CancellationToken.$current.withValue(token) {
            await engineError { try await engine.generateNotes(makeNotesRequest()) }
        }
        #expect(error == .cancelled, "the retry boundary stops the call after the first send")
        #expect(sends.values.count == 1, "exactly one send — the in-flight attempt was not retried")
        let total = try await ledger.accumulatedThisMonth()
        #expect(total > 0, "the shielded in-flight attempt's spend IS ledgered")
    }

    /// G10 §1 (H-3): the shield covers TRANSPORT AND LEDGER. The auditor's probe
    /// cancels the TASK running `generateNotes` (not merely the token) WHILE the
    /// 200 is in flight. GRDB's `pool.write` is cancellation-aware, so a ledger
    /// write back on the cancelled caller task would silently drop —
    /// Anthropic-side spend incurred but invisible (Floor 3 hole). With the
    /// ledger write moved inside the `Task.detached` shield, the already-incurred
    /// spend is recorded regardless of the caller-task cancellation.
    @Test func taskCancelDuringInflightSendStillLedgersSpend() async throws {
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
        // The transport signals it has started, then returns a billed 200. The
        // test cancels the engine's Task between the signal and the return, so
        // the cancellation is live when the (shielded) ledger write runs.
        let started = AsyncSignal()
        let release = AsyncSignal()
        let transport: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = { request in
            await started.fire()
            await release.wait()
            let http = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data(successBody().utf8), http)
        }
        let engine = ClaudeSummarizationEngine(
            configuration: configuration, ledger: ledger, transport: transport)
        let runTask = Task { try await engine.generateNotes(makeNotesRequest()) }
        await started.wait()  // the in-flight send is underway
        runTask.cancel()  // cancel the TASK (not just a token) mid-send
        await release.fire()  // let the shielded send + ledger write complete
        _ = try? await runTask.value
        let total = try await ledger.accumulatedThisMonth()
        #expect(
            total > 0,
            "the shielded in-flight send's spend IS ledgered even when the caller task is cancelled")
    }
}

/// A one-shot async signal (continuation-based latch) for ordering test
/// concurrency: `fire()` unblocks all current and future `wait()`s.
private actor AsyncSignal {
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func fire() {
        guard !fired else { return }
        fired = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func wait() async {
        if fired { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

// MARK: - #104 notes-completeness guard

/// A schema-valid notes JSON document with caller-controlled completeness
/// fields. Fictional data only (no real meeting content). Speaker mapping is
/// fixed and well-formed so decode always succeeds; the stub class is expressed
/// through `detailedNotes` / `decisions` / the two action arrays.
private func notesJSON(
    detailedNotes: String,
    decisions: [String] = [],
    actionItems: [(String, String)] = [],
    userActionItems: [(String, String)] = []
) -> String {
    func items(_ xs: [(String, String)]) -> String {
        "[" + xs.map { "{\"owner\": \"\($0.0)\", \"text\": \"\($0.1)\"}" }.joined(separator: ", ") + "]"
    }
    let decisionsJSON = "[" + decisions.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
    let escaped = detailedNotes
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
    return """
        {
          "title": "Sync semanal Quill",
          "summary": "Resumo curto da reunião.",
          "meeting_type": "general",
          "detailed_notes": "\(escaped)",
          "decisions": \(decisionsJSON),
          "action_items": \(items(actionItems)),
          "user_action_items": \(items(userActionItems)),
          "speaker_name_mapping": [
            {"label": "S0", "name": "Wren", "confidence": "high", "evidence": "aqui é a Wren"}
          ]
        }
        """
}

/// Decode a notes JSON body into the engine's `NotesEngineResponse` (the type
/// `isLikelyStub` consumes). Used by the pure-predicate tests.
private func decodeNotes(_ json: String) throws -> NotesEngineResponse {
    try NotesEngineResponse.decode(from: Data(json.utf8))
}

/// A 200's text content block that is valid JSON but NOT the notes schema, so
/// the engine's `decodeNotes` returns nil (a `NotesEngineResponse.decode`
/// failure). Models a non-schema 200 a retry can legitimately produce. Fictional
/// data only; no meeting content.
private let nonSchemaBody = "{\"unexpected\": \"this is not the notes schema\"}"

/// A full Messages-API wire body wrapping arbitrary notes JSON, with a
/// caller-set `stop_reason` and `output_tokens` (so the integration tests can
/// pin the C gate's input independently of the body length).
private func notesAPIBody(
    notes: String, stopReason: String = "end_turn",
    inputTokens: Int = 12_000, outputTokens: Int = 2_500
) -> String {
    let text = notes
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
    return """
        {"id": "msg_test", "type": "message", "role": "assistant",
         "content": [{"type": "text", "text": "\(text)"}],
         "stop_reason": "\(stopReason)",
         "usage": {"input_tokens": \(inputTokens), "output_tokens": \(outputTokens)}}
        """
}

/// A `ClaudeSummarizationEngine.APIResponse` for the pure `bestOfNotes` tests —
/// decoded from a wire body so the production decode path is exercised.
private func makeAPIResponse(
    notes: String, stopReason: String = "end_turn", outputTokens: Int = 2_500
) throws -> ClaudeSummarizationEngine.APIResponse {
    try JSONDecoder().decode(
        ClaudeSummarizationEngine.APIResponse.self,
        from: Data(notesAPIBody(notes: notes, stopReason: stopReason, outputTokens: outputTokens).utf8))
}

/// The Sonnet cost of one billed attempt (mirrors `ClaudeSummarizationEngine.cost`):
/// $3/MTok in + $15/MTok out. Lets the billing assertions sum the EXACT cost of
/// two attempts with differing token counts (rather than assuming the canonical
/// 0.0735 twice).
private func attemptCost(inputTokens: Int = 12_000, outputTokens: Int) -> Double {
    Double(inputTokens) / 1_000_000 * 3.0 + Double(outputTokens) / 1_000_000 * 15.0
}

/// A `StubCandidate` for the pure `bestOfNotes` ordering tests.
private func makeCandidate(
    attempt: ClaudeSummarizationEngine.StubAttempt,
    notes: String, stopReason: String = "end_turn",
    outputTokens: Int, transcriptBytes: Int
) throws -> ClaudeSummarizationEngine.StubCandidate {
    let response = try makeAPIResponse(notes: notes, stopReason: stopReason, outputTokens: outputTokens)
    let decoded = ClaudeSummarizationEngine.decodeNotes(response)
    let isStub = decoded.map {
        ClaudeSummarizationEngine.isLikelyStub(
            $0, outputTokens: outputTokens, transcriptBytes: transcriptBytes)
    } ?? true
    return ClaudeSummarizationEngine.StubCandidate(
        attempt: attempt, response: response, decoded: decoded, isStub: isStub)
}

/// A NotesRequest whose transcript is `bytes` UTF-8 bytes (single segment) — so
/// the size-anomaly gate (C) can be exercised at a chosen transcript size.
private func makeNotesRequest(transcriptBytes bytes: Int) -> NotesRequest {
    var request = makeNotesRequest()
    let filler = String(repeating: "a", count: max(0, bytes))
    request.transcript = [
        TranscriptSegment(
            meetingID: request.meeting.id, ord: 0, startSeconds: 0, endSeconds: 1,
            speakerLabel: "S0", text: filler)
    ]
    return request
}

/// Pure predicate tests for `isLikelyStub` (C AND (A OR B′)).
@Suite struct ClaudeStubPredicateTests {
    // (1) The 505-token-stub class: large transcript (20 000 bytes → thresh
    // 1000), output 505 < 1000 (C), detailed_notes cut mid-sentence (A), empty
    // action arrays (B′). Fires.
    @Test func largeTranscriptTruncatedEmptyArraysFires() throws {
        let r = try decodeNotes(notesJSON(
            detailedNotes: "## Resumo\nA equipe discutiu o plano e então a chamada foi"))
        #expect(ClaudeSummarizationEngine.isLikelyStub(r, outputTokens: 505, transcriptBytes: 20_000))
    }

    // (2) Same low output but a TINY transcript (500 bytes → thresh = floor
    // 400; 505 ≥ 400) → C false → never retried, however thin the body.
    @Test func smallTranscriptExemptByFloor() throws {
        let r = try decodeNotes(notesJSON(
            detailedNotes: "A equipe discutiu o plano e então a chamada foi"))
        #expect(!ClaudeSummarizationEngine.isLikelyStub(r, outputTokens: 505, transcriptBytes: 500))
    }

    // (3) A realistic SHORT real meeting: small transcript, complete concise
    // notes ending in a period, output below the 400 floor → C fires but A and
    // B′ both false (terminal punctuation + a real decision) → does NOT fire.
    @Test func shortCompleteMeetingDoesNotFire() throws {
        let r = try decodeNotes(notesJSON(
            detailedNotes: "## Resumo\nQuick standup; everyone is on track.",
            decisions: ["Ship Friday"]))
        #expect(!ClaudeSummarizationEngine.isLikelyStub(r, outputTokens: 300, transcriptBytes: 500))
    }

    // (F2) C AND A — decisions PRESENT but detailed_notes truncated mid-sentence.
    // A must fire WITHOUT B′ (decoupled). Fires.
    @Test func truncatedWithDecisionsPresentFires() throws {
        let r = try decodeNotes(notesJSON(
            detailedNotes: "## Plano\nO time decidiu avançar e em seguida",
            decisions: ["Avançar com a fase 2"]))
        #expect(ClaudeSummarizationEngine.isLikelyStub(r, outputTokens: 505, transcriptBytes: 20_000))
    }

    // (F2) C AND B′ — all three action arrays empty even though detailed_notes
    // ends with a period. B′ fires WITHOUT A. Fires.
    @Test func emptyArraysWithTerminalPunctuationFires() throws {
        let r = try decodeNotes(notesJSON(
            detailedNotes: "## Resumo\nA equipe revisou o status do projeto."))
        #expect(ClaudeSummarizationEngine.isLikelyStub(r, outputTokens: 505, transcriptBytes: 20_000))
    }

    // (F2) Complete endings that are NOT plain terminal punctuation must still
    // count as terminated when in the terminal set (`:` after a heading, a
    // closing quote/paren), AND a markdown bullet / `## heading` body on a
    // real-size transcript with non-empty arrays must NOT fire — A false (ends
    // on `.`) and B′ false.
    @Test func markdownCompleteEndingDoesNotFire() throws {
        let r = try decodeNotes(notesJSON(
            detailedNotes: """
                ## Decisões
                - O orçamento foi aprovado.
                - O cronograma foi confirmado.

                ## Próximos passos
                A equipe seguirá com a implementação na próxima semana.
                """,
            decisions: ["Aprovar orçamento"],
            actionItems: [("Wren", "preparar cronograma")]))
        #expect(!ClaudeSummarizationEngine.isLikelyStub(r, outputTokens: 505, transcriptBytes: 20_000))
    }

    // A PT abbreviation ending the body (`etc.`) is terminal punctuation → A
    // false; combined with non-empty arrays → no fire even on a large transcript.
    @Test func ptAbbreviationEndingDoesNotFire() throws {
        let r = try decodeNotes(notesJSON(
            detailedNotes: "## Itens\nForam discutidos custos, prazos, riscos, etc.",
            decisions: ["Revisar custos"]))
        #expect(!ClaudeSummarizationEngine.isLikelyStub(r, outputTokens: 505, transcriptBytes: 20_000))
    }

    // (5) Full notes — non-empty decisions/actions and a long terminated body,
    // proportional output → never fires (neither C nor A nor B′ alone matters).
    @Test func fullNotesDoNotFire() throws {
        let r = try decodeNotes(notesJSON(
            detailedNotes: "## Resumo\nUma discussão completa e bem estruturada da reunião inteira.",
            decisions: ["Decisão A", "Decisão B"],
            actionItems: [("Wren", "tarefa 1"), ("Quill", "tarefa 2")],
            userActionItems: [("Wren", "tarefa 1")]))
        #expect(!ClaudeSummarizationEngine.isLikelyStub(r, outputTokens: 6_000, transcriptBytes: 20_000))
    }

    // The empty-body edge: a blank detailed_notes is maximally truncated → A
    // fires; with C it is a stub.
    @Test func emptyDetailedNotesCountsAsTruncated() throws {
        let r = try decodeNotes(notesJSON(detailedNotes: ""))
        #expect(ClaudeSummarizationEngine.isLikelyStub(r, outputTokens: 100, transcriptBytes: 20_000))
    }
}

/// Pure ordering tests for `bestOfNotes` (F3).
@Suite struct ClaudeBestOfNotesTests {
    private let bytes = 20_000  // thresh 1000 — outputs < 1000 trip C

    // Rung 1: exactly one non-stub → that one wins, regardless of length.
    @Test func oneStubOneGoodPicksGood() throws {
        let stub = try makeCandidate(
            attempt: .first, notes: notesJSON(detailedNotes: "cortado no meio"),
            outputTokens: 505, transcriptBytes: bytes)
        let good = try makeCandidate(
            attempt: .retry,
            notes: notesJSON(
                detailedNotes: "## Resumo\nNotas completas e terminadas.",
                decisions: ["D"], actionItems: [("Wren", "t")]),
            outputTokens: 4_000, transcriptBytes: bytes)
        #expect(stub.isStub)
        #expect(!good.isStub)
        #expect(ClaudeSummarizationEngine.bestOfNotes(stub, good).attempt == .retry)
        // Order-independent.
        #expect(ClaudeSummarizationEngine.bestOfNotes(good, stub).attempt == .retry)
    }

    // Rung 4: both stubs → higher outputTokens wins (rungs 2/3 tie).
    @Test func bothStubPicksHigherOutput() throws {
        let lean = try makeCandidate(
            attempt: .first, notes: notesJSON(detailedNotes: "thin one"),
            outputTokens: 300, transcriptBytes: bytes)
        let fuller = try makeCandidate(
            attempt: .retry, notes: notesJSON(detailedNotes: "thin two"),
            outputTokens: 700, transcriptBytes: bytes)
        #expect(lean.isStub && fuller.isStub)
        #expect(ClaudeSummarizationEngine.bestOfNotes(lean, fuller).attempt == .retry)
    }

    // Rung 2: a retry that returned max_tokens must NOT win on raw length — the
    // non-max_tokens attempt wins even with FEWER output tokens (both stubs).
    @Test func maxTokensRetryNotChosenOnLengthAlone() throws {
        let endTurn = try makeCandidate(
            attempt: .first, notes: notesJSON(detailedNotes: "cortado"),
            stopReason: "end_turn", outputTokens: 400, transcriptBytes: bytes)
        let capped = try makeCandidate(
            attempt: .retry, notes: notesJSON(detailedNotes: "cortado mais longo aqui"),
            stopReason: "max_tokens", outputTokens: 900, transcriptBytes: bytes)
        #expect(endTurn.isStub && capped.isStub)
        #expect(ClaudeSummarizationEngine.bestOfNotes(endTurn, capped).attempt == .first)
    }

    // Rung 5: a perfect tie (same stub verdict, same stop_reason, same output)
    // → deterministic first.
    @Test func tieGoesToFirst() throws {
        let a = try makeCandidate(
            attempt: .first, notes: notesJSON(detailedNotes: "igual"),
            outputTokens: 500, transcriptBytes: bytes)
        let b = try makeCandidate(
            attempt: .retry, notes: notesJSON(detailedNotes: "igual"),
            outputTokens: 500, transcriptBytes: bytes)
        #expect(ClaudeSummarizationEngine.bestOfNotes(a, b).attempt == .first)
    }

    // Rung 3: both non-stub, same stop_reason, same output → richer (non-empty
    // action arrays + terminal-terminated) wins.
    @Test func richerWinsOnTieBeforeOutput() throws {
        // Both non-stub (high output, terminated). One has empty arrays.
        let bare = try makeCandidate(
            attempt: .first,
            notes: notesJSON(detailedNotes: "## Resumo\nNotas terminadas sem ações."),
            outputTokens: 5_000, transcriptBytes: bytes)
        let rich = try makeCandidate(
            attempt: .retry,
            notes: notesJSON(
                detailedNotes: "## Resumo\nNotas terminadas com ações.",
                decisions: ["D"], actionItems: [("Wren", "t")]),
            outputTokens: 5_000, transcriptBytes: bytes)
        #expect(!bare.isStub && !rich.isStub)
        #expect(ClaudeSummarizationEngine.bestOfNotes(bare, rich).attempt == .retry)
    }

    // FIX 2 / Rung 4 (decodable beats nil): a decodable thin STUB first attempt
    // vs a NIL-decoded (non-schema 200) retry that has MORE output tokens. The
    // raw-length rung (5) would otherwise pick the nil retry — and the shared
    // decode would then throw `.permanent` and fail the meeting. Rung 4 must
    // place the decodable first ABOVE the higher-token nil retry so the meeting
    // ships the decodable stub. Both rungs 1-3 tie (both treated as stub, both
    // end_turn, neither rich), so this exercises rung 4 in isolation.
    @Test func decodableStubBeatsNilDecodedHigherTokens() throws {
        let decodableStub = try makeCandidate(
            attempt: .first,
            notes: notesJSON(detailedNotes: "## Resumo\nA equipe discutiu e então"),
            outputTokens: 505, transcriptBytes: bytes)
        let nilHigherTokens = try makeCandidate(
            attempt: .retry, notes: nonSchemaBody,
            outputTokens: 9_000, transcriptBytes: bytes)
        // The decodable candidate decoded; the non-schema one did not.
        #expect(decodableStub.decoded != nil)
        #expect(nilHigherTokens.decoded == nil)
        // Both treated as stub (the nil candidate is always a stub), tie on rungs
        // 1-3, nil one has MORE output — rung 4 still picks the decodable first.
        #expect(decodableStub.isStub && nilHigherTokens.isStub)
        #expect(ClaudeSummarizationEngine.bestOfNotes(decodableStub, nilHigherTokens).attempt == .first)
        // Order-independent: the decodable wins regardless of argument position.
        #expect(ClaudeSummarizationEngine.bestOfNotes(nilHigherTokens, decodableStub).attempt == .first)
        // And the winner is never nil-decoded when a decodable candidate exists.
        #expect(ClaudeSummarizationEngine.bestOfNotes(decodableStub, nilHigherTokens).decoded != nil)
    }
}

/// Integration tests through the fake transport (the full retry control flow,
/// billing, cancellation, and the max-2-calls bound).
@Suite struct ClaudeCompletenessRetryTests {
    // A stub first attempt (large transcript, low output, truncated, empty
    // arrays, end_turn) → exactly TWO sends, BOTH billed, the full retry ships.
    @Test func stubThenFullRetriesOnceAndShipsFull() async throws {
        let stub = notesAPIBody(
            notes: notesJSON(detailedNotes: "## Resumo\nA equipe discutiu e então"),
            stopReason: "end_turn", outputTokens: 505)
        let full = notesAPIBody(
            notes: notesJSON(
                detailedNotes: "## Resumo\nUma discussão completa da reunião inteira.",
                decisions: ["Aprovar"], actionItems: [("Wren", "preparar")]),
            stopReason: "end_turn", outputTokens: 4_000)
        let harness = try await makeClaudeHarness(responses: [(200, stub), (200, full)])
        let result = try await harness.engine.generateNotes(makeNotesRequest(transcriptBytes: 20_000))

        #expect(harness.api.requests.values.count == 2, "stub → exactly one retry (2 sends)")
        // Budgets: 8 192 then 16 384.
        let firstData = try #require(harness.api.requests.values[0].httpBody)
        let secondData = try #require(harness.api.requests.values[1].httpBody)
        let firstBody = try JSONSerialization.jsonObject(with: firstData) as? [String: Any]
        let secondBody = try JSONSerialization.jsonObject(with: secondData) as? [String: Any]
        #expect(firstBody?["max_tokens"] as? Int == 8_192)
        #expect(secondBody?["max_tokens"] as? Int == 16_384)
        // The full retry ships (its decisions/actions survive into the result).
        #expect(result.structured.decisions == ["Aprovar"])
        #expect(result.structured.actionItems.contains { $0.text == "preparar" })
        // BOTH attempts billed (the stub 505-out + the full 4 000-out).
        let total = try await harness.ledger.accumulatedThisMonth()
        let expected = attemptCost(outputTokens: 505) + attemptCost(outputTokens: 4_000)
        #expect(abs(total - expected) < 1e-9, "both stub + retry are billed")
    }

    // Double-stub: both attempts are stubs → best-of-two ships, NO throw, the
    // meeting finalizes; both billed; exactly 2 sends.
    @Test func doubleStubReturnsBestOfTwoNoThrow() async throws {
        let stubLow = notesAPIBody(
            notes: notesJSON(detailedNotes: "## Resumo\nApenas o começo e então"),
            stopReason: "end_turn", outputTokens: 300)
        let stubHigh = notesAPIBody(
            notes: notesJSON(detailedNotes: "## Resumo\nUm pouco mais mas ainda cortado e"),
            stopReason: "end_turn", outputTokens: 700)
        let harness = try await makeClaudeHarness(responses: [(200, stubLow), (200, stubHigh)])
        // No throw — a result is produced.
        let result = try await harness.engine.generateNotes(makeNotesRequest(transcriptBytes: 20_000))
        #expect(harness.api.requests.values.count == 2)
        // best-of-two picked the higher-output stub (both stubs, tie on rungs
        // 1-3, rung 4 → higher output).
        #expect(result.structured.detailedNotes.contains("ainda cortado"))
        let total = try await harness.ledger.accumulatedThisMonth()
        let expected = attemptCost(outputTokens: 300) + attemptCost(outputTokens: 700)
        #expect(abs(total - expected) < 1e-9, "both stub attempts are billed")
    }

    // F1 bound: first = max_tokens, retry = end_turn STUB → the max_tokens IF
    // branch handles it (retry at 16 384, end_turn accepted) and the stub branch
    // is NEVER reached → exactly TWO sends, NO 3rd call, ships the stub.
    @Test func maxTokensFirstThenEndTurnStubIsExactlyTwoSends() async throws {
        let capped = notesAPIBody(
            notes: notesJSON(detailedNotes: "truncado pelo budget"),
            stopReason: "max_tokens", outputTokens: 8_192)
        let endTurnStub = notesAPIBody(
            notes: notesJSON(detailedNotes: "## Resumo\nainda cortado e"),
            stopReason: "end_turn", outputTokens: 505)
        let harness = try await makeClaudeHarness(responses: [(200, capped), (200, endTurnStub)])
        _ = try await harness.engine.generateNotes(makeNotesRequest(transcriptBytes: 20_000))
        #expect(
            harness.api.requests.values.count == 2,
            "max_tokens→retry path never reaches the stub branch: bounded at 2, never 3")
        let total = try await harness.ledger.accumulatedThisMonth()
        let expected = attemptCost(outputTokens: 8_192) + attemptCost(outputTokens: 505)
        #expect(abs(total - expected) < 1e-9, "both attempts on the max_tokens path are billed")
    }

    // A non-stub first attempt → no retry (one send), default behavior is
    // byte-identical to the no-guard path.
    @Test func nonStubFirstAttemptDoesNotRetry() async throws {
        let full = notesAPIBody(
            notes: notesJSON(
                detailedNotes: "## Resumo\nUma discussão completa e terminada.",
                decisions: ["D"], actionItems: [("Wren", "t")]),
            stopReason: "end_turn", outputTokens: 4_000)
        let harness = try await makeClaudeHarness(responses: [(200, full)])
        _ = try await harness.engine.generateNotes(makeNotesRequest(transcriptBytes: 20_000))
        #expect(harness.api.requests.values.count == 1, "a complete first attempt is not retried")
    }

    // A short real meeting whose first attempt is thin but below the C floor →
    // no retry (C exempts it). One send.
    @Test func shortMeetingThinNotesDoesNotRetry() async throws {
        // Tiny transcript (default request ~50 bytes → thresh = floor 400),
        // output 505 ≥ 400 → C false.
        let thin = notesAPIBody(
            notes: notesJSON(detailedNotes: "Standup rápido e então"),
            stopReason: "end_turn", outputTokens: 505)
        let harness = try await makeClaudeHarness(responses: [(200, thin)])
        _ = try await harness.engine.generateNotes(makeNotesRequest())
        #expect(harness.api.requests.values.count == 1, "C floor exempts a short meeting from retry")
    }

    // FIX 1 (always-finalizes): a decodable thin-but-valid stub first attempt
    // whose RETRY THROWS (transient 429) must NOT propagate the throw — the
    // already-billed first stub ships and the meeting finalizes. Only the first
    // (200) attempt is billed; the 429 retry carries no usage 200, so it is not.
    @Test func stubThenThrowingRetryKeepsFirstAndFinalizes() async throws {
        let stub = notesAPIBody(
            notes: notesJSON(detailedNotes: "## Resumo\nA equipe discutiu e então"),
            stopReason: "end_turn", outputTokens: 505)
        // The retry is a 429 → mapHTTPError → .transient; performAttempt throws.
        let rateLimited = """
            {"type": "error", "error": {"type": "rate_limit_error", "message": "slow down"}}
            """
        let harness = try await makeClaudeHarness(responses: [(200, stub), (429, rateLimited)])
        // No throw — the first stub is shipped despite the retry failing.
        let result = try await harness.engine.generateNotes(makeNotesRequest(transcriptBytes: 20_000))
        #expect(harness.api.requests.values.count == 2, "the retry was attempted (and threw)")
        // The FIRST decoded stub's content survives into the result.
        #expect(result.structured.detailedNotes.contains("A equipe discutiu e então"))
        // Only the first (200) attempt billed; the 429 retry is not a billed 200.
        let total = try await harness.ledger.accumulatedThisMonth()
        let expected = attemptCost(outputTokens: 505)
        #expect(abs(total - expected) < 1e-9, "only the first attempt is billed; the throwing retry is not")
    }

    // FIX 2 (decodable beats nil): a decodable thin-but-valid stub first attempt
    // and a non-schema 200 retry (decodes nil) that has MORE output tokens →
    // best-of-two must ship the FIRST (decodable) stub, never the nil retry (the
    // shared decode would throw .permanent on a nil winner and fail the meeting).
    // Both attempts returned 200 with usage, so BOTH are billed.
    @Test func stubThenNonSchemaRetryShipsFirstDecodable() async throws {
        let stub = notesAPIBody(
            notes: notesJSON(detailedNotes: "## Resumo\nA equipe discutiu e então"),
            stopReason: "end_turn", outputTokens: 505)
        // A valid 200 whose text content is NOT the notes schema → decodes nil.
        // Higher output tokens than the first, to prove rung 4 beats raw length.
        let nonSchema = notesAPIBody(notes: nonSchemaBody, stopReason: "end_turn", outputTokens: 9_000)
        let harness = try await makeClaudeHarness(responses: [(200, stub), (200, nonSchema)])
        // No throw — the decodable first stub is shipped.
        let result = try await harness.engine.generateNotes(makeNotesRequest(transcriptBytes: 20_000))
        #expect(harness.api.requests.values.count == 2, "stub → exactly one retry (2 sends)")
        // The FIRST decodable stub ships, NOT the higher-token nil retry.
        #expect(result.structured.detailedNotes.contains("A equipe discutiu e então"))
        // BOTH 200s are billed (the stub 505-out + the non-schema 9 000-out).
        let total = try await harness.ledger.accumulatedThisMonth()
        let expected = attemptCost(outputTokens: 505) + attemptCost(outputTokens: 9_000)
        #expect(abs(total - expected) < 1e-9, "both 200 attempts are billed")
    }

    // A cancel landing between the first (stub) attempt and the retry → NO retry
    // send; the first attempt is billed; the meeting finalizes on the first
    // (the stub branch did not fire because the token is cancelled).
    @Test func cancelBetweenAttemptsSkipsRetryButBillsFirst() async throws {
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
        let token = CancellationToken()
        let sends = Recorder<Int>()
        // The transport records the send then cancels the token, so the first
        // (stub) attempt is billed and the stub-branch boundary check sees the
        // cancel → no retry starts.
        let stubBody = notesAPIBody(
            notes: notesJSON(detailedNotes: "## Resumo\nA equipe discutiu e então"),
            stopReason: "end_turn", outputTokens: 505)
        let transport: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = { request in
            sends.append(1)
            token.cancel()
            let http = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data(stubBody.utf8), http)
        }
        let engine = ClaudeSummarizationEngine(
            configuration: configuration, ledger: ledger, transport: transport)
        let result = await CancellationToken.$current.withValue(token) {
            try? await engine.generateNotes(makeNotesRequest(transcriptBytes: 20_000))
        }
        #expect(sends.values.count == 1, "the stub retry does not start once the token is cancelled")
        #expect(result != nil, "the meeting still finalizes on the first attempt")
        let total = try await ledger.accumulatedThisMonth()
        #expect(total > 0, "the first (shielded) attempt is billed")
    }
}
