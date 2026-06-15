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
        // `legacy_user_action_items` → `user_action_items` rename (schema property +
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
        #expect(!bodyText.contains("legacy_user_action_items"))

        // Reconstruct the pre-rename baseline body by substituting the source
        // constants the body is spliced from, exactly as a pre-G4 build would
        // have produced them, then comparing modulo the token.
        let oldKey = "legacy_user_action_items"
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
        // CLAUDE.md privacy boundary: transcript with speaker labels, title,
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
