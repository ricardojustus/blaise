import Foundation
import Testing
@testable import BlaiseCore

private func modelSelectionResponse(text: String, input: Int = 1_000, output: Int = 500) -> String {
    let escaped = text
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
    return """
        {"content":[{"type":"text","text":"\(escaped)"}],
         "stop_reason":"end_turn",
         "usage":{"input_tokens":\(input),"output_tokens":\(output)}}
        """
}

private func modelSelectionDigestRequest() -> DigestRequest {
    let notesRequest = makeNotesRequest()
    return DigestRequest(
        meeting: notesRequest.meeting,
        transcript: notesRequest.transcript,
        notes: NotesStructured(
            title: "Roadmap", summary: "Summary.", detailedNotes: "Details.",
            decisions: ["Ship"], actionItems: [], userActionItems: []),
        dominantLanguage: notesRequest.dominantLanguage,
        vocabulary: notesRequest.vocabulary,
        user: notesRequest.user)
}

private struct ModelSelectionHarness {
    let engine: ClaudeSummarizationEngine
    let ledger: CloudSpendLedger
    let requests: Recorder<URLRequest>
}

private func makeModelSelectionHarness(
    model: ClaudeNotesModel, responses: [String]
) async throws -> ModelSelectionHarness {
    let database = try makeDatabase()
    let settings = SettingsStore(database: database)
    let secrets = InMemorySecretStore()
    try secrets.set(
        key: "engine.\(ClaudeSummarizationEngine.engineID).\(ClaudeSummarizationEngine.apiKeyConfigKey)",
        value: "sk-test-not-a-real-key")
    let configuration = EngineConfiguration(
        engineID: ClaudeSummarizationEngine.engineID,
        descriptors: ClaudeSummarizationEngine.descriptors,
        settings: settings,
        secrets: secrets)
    let ledger = CloudSpendLedger(database: database)
    let requests = Recorder<URLRequest>()
    let counter = Recorder<Int>()
    let transport: ClaudeSummarizationEngine.Transport = { request in
        requests.append(request)
        counter.append(1)
        let body = responses[min(counter.values.count - 1, responses.count - 1)]
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (Data(body.utf8), response)
    }
    let engine = ClaudeSummarizationEngine(
        configuration: configuration, ledger: ledger, model: model, transport: transport)
    return ModelSelectionHarness(engine: engine, ledger: ledger, requests: requests)
}

private func modelSelectionBody(_ request: URLRequest) throws -> [String: Any] {
    let data = try #require(request.httpBody)
    return try #require(
        try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Suite struct ClaudeModelSelectionTests {
    @Test func requestBuildersApplyEachModelsSupportedParameters() throws {
        for model in ClaudeNotesModel.allCases {
            let structuredRequest = try ClaudeSummarizationEngine.buildURLRequest(
                apiKey: "test", system: "system", user: "user", maxTokens: 100,
                timeout: 10, model: model.rawValue)
            let structuredBody = try modelSelectionBody(structuredRequest)
            Self.assertParameters(structuredBody, for: model, structured: true)

            let rawBody = try #require(
                structuredRequest.httpBody.flatMap { String(data: $0, encoding: .utf8) })
            let title = try #require(rawBody.range(of: #""title""#))
            let summary = try #require(rawBody.range(of: #""summary""#))
            #expect(title.lowerBound < summary.lowerBound, "schema author order must survive splicing")

            let digestRequest = try ClaudeSummarizationEngine.buildDigestURLRequest(
                apiKey: "test", system: "system", user: "user", maxTokens: 100,
                timeout: 10, model: model.rawValue)
            Self.assertParameters(
                try modelSelectionBody(digestRequest), for: model, structured: false)
        }
    }

    @Test(arguments: ClaudeNotesModel.allCases)
    func selectedModelFlowsAcrossEveryCallAndAuditOverride(
        model: ClaudeNotesModel
    ) async throws {
        let editor = #"{"ops":[{"field":"summary","find":"before","replace":"after","instruction":1}]}"#
        let digest = "## HEADER\nmeeting: Vexatron\n"
        let harness = try await makeModelSelectionHarness(model: model, responses: [
            modelSelectionResponse(text: sampleEngineResponseJSON),
            modelSelectionResponse(text: editor),
            modelSelectionResponse(text: digest),
            modelSelectionResponse(text: digest), // safely repeated by the transport
        ])

        let notes = try await harness.engine.generateNotes(makeNotesRequest(), purpose: .generation)
        let edit = try await harness.engine.editNotes(
            makeNotesEditorRequest(), purpose: .notesEditor)
        let request = modelSelectionDigestRequest()
        let digestResult = try await harness.engine.generateDigest(request, purpose: .digest)
        let verifyResult = try await harness.engine.verifyDigest(
            request, draftDigest: digest, purpose: .digest)
        let reconcileResult = try await harness.engine.reconcileDigest(
            request, draftDigest: digest, purpose: .digest)
        let defaultAuditResult = try await harness.engine.combinedAuditDigest(
            request, draftDigest: digest, purpose: .digest)
        let overrideAuditResult = try await harness.engine.combinedAuditDigest(
            request, draftDigest: digest, purpose: .digest,
            model: ClaudeNotesModel.haiku45.rawValue)

        let selectedCost: Double = switch model {
        case .sonnet46: 0.0105
        case .sonnet55: 0.007
        case .opus55: 0.014
        case .haiku45: 0.0035
        }
        let overrideCost = 0.0035
        #expect(harness.engine.selectedModel == model)
        #expect(harness.engine.id == model.apiEngineID)
        #expect(harness.engine.configurationID == ClaudeSummarizationEngine.engineID)
        #expect(notes.provenance.model == model.rawValue)
        #expect(abs((notes.usage?.estimatedCostUSD ?? -1) - selectedCost) < 1e-12)
        for result in [edit.usage, digestResult.usage, verifyResult.usage,
                       reconcileResult.usage, defaultAuditResult.usage] {
            #expect(abs((result?.estimatedCostUSD ?? -1) - selectedCost) < 1e-12)
        }
        #expect(
            abs((overrideAuditResult.usage?.estimatedCostUSD ?? -1) - overrideCost) < 1e-12)

        let wireModels = try harness.requests.values.map {
            try #require(try modelSelectionBody($0)["model"] as? String)
        }
        #expect(wireModels == Array(repeating: model.rawValue, count: 6)
            + [ClaudeNotesModel.haiku45.rawValue])

        let receipts = try await harness.ledger.monthReceipts().receipts
        #expect(receipts.count == 7)
        #expect(receipts.allSatisfy { $0.engineID == model.apiEngineID })
        #expect(receipts.map(\.model).sorted() == wireModels.sorted())
        #expect(abs(receipts.map(\.costUSD).reduce(0, +)
            - (selectedCost * 6 + overrideCost)) < 1e-12)
    }

    @Test func pricesCoverCatalogAndUnknownRemainsConservative() {
        let expected: [(ClaudeNotesModel, Double, Double)] = [
            (.sonnet46, 3, 15), (.sonnet55, 2, 10), (.opus55, 4, 20), (.haiku45, 1, 5),
        ]
        for (model, input, output) in expected {
            let price = ClaudeSummarizationEngine.pricePerMTok(for: model.rawValue)
            #expect(price.input == input)
            #expect(price.output == output)
        }
        let unknown = ClaudeSummarizationEngine.pricePerMTok(for: "claude-future-unknown")
        #expect(unknown.input == ClaudeSummarizationEngine.inputUSDPerMTok)
        #expect(unknown.output == ClaudeSummarizationEngine.outputUSDPerMTok)
    }

    private static func assertParameters(
        _ body: [String: Any], for model: ClaudeNotesModel, structured: Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(body["model"] as? String == model.rawValue, sourceLocation: sourceLocation)
        let thinking = body["thinking"] as? [String: Any]
        let outputConfig = body["output_config"] as? [String: Any]
        switch model {
        case .sonnet55:
            #expect(body["temperature"] == nil, sourceLocation: sourceLocation)
            #expect(thinking?["type"] as? String == "between_tools", sourceLocation: sourceLocation)
        case .opus55:
            #expect(body["temperature"] == nil, sourceLocation: sourceLocation)
            #expect(thinking?["type"] as? String == "adaptive", sourceLocation: sourceLocation)
            #expect(outputConfig?["effort"] as? String == "medium", sourceLocation: sourceLocation)
        case .sonnet46, .haiku45:
            #expect(body["temperature"] != nil, sourceLocation: sourceLocation)
            #expect(thinking == nil, sourceLocation: sourceLocation)
        }
        if structured {
            let format = outputConfig?["format"] as? [String: Any]
            #expect(format?["type"] as? String == "json_schema", sourceLocation: sourceLocation)
            #expect(format?["schema"] != nil, sourceLocation: sourceLocation)
        }
    }
}
