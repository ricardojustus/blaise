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
        #expect(result.promptVersion == "md-v1")
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
}
