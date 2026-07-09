import Foundation
import Testing

@testable import BlaiseCore

// Account engine (`claude -p`) unit tests: the clean `-p` argv, the explicit
// minimal child env (OAuth token in, ANTHROPIC_API_KEY out), the user message on
// stdin, success → DigestResult/NotesResult, transient 529 retry, auth failure →
// .configurationMissing, and the digest synth→audit two-call fail-soft contract.
// No subprocess: the injected `CommandRunner` fake plays the CLI. All fixtures
// FICTIONAL (Vexatron / Sam / Dana — no real identity).

// MARK: - Recorded invocation

private struct CPInvocation: Sendable {
    let executable: URL
    let args: [String]
    let env: [String: String]
    let stdin: Data?
}

private typealias CPResponse = ClaudeCodeSummarizationEngine.SubprocessOutcomeLike

/// A success envelope: `claude -p --output-format json` wraps the model answer in
/// `result`. exit 0.
private func cpSuccess(result: String) -> CPResponse {
    let escaped = result
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
    let body = """
        {"type":"result","subtype":"success","is_error":false,"result":"\(escaped)"}
        """
    return CPResponse(stdout: Data(body.utf8), exitStatus: 0)
}

/// A transient overload envelope (`is_error` + api_error_status 529).
private func cpOverloaded() -> CPResponse {
    let body = """
        {"type":"result","subtype":"error","is_error":true,"api_error_status":529,"result":"overloaded"}
        """
    return CPResponse(stdout: Data(body.utf8), exitStatus: 1)
}

/// A schema-constrained success envelope: a `--json-schema` call delivers the
/// SCHEMA-VALIDATED object in `structured_output` (a JSON OBJECT), while `result`
/// holds the model's prose — which may be garbage. The engine must read
/// `structured_output`, NOT `result`. `structuredOutputJSON` is the raw JSON for
/// the object; `result` defaults to prose to prove `result` is ignored.
private func cpStructuredSuccess(
    structuredOutputJSON: String, result: String = "Here are the notes for the meeting."
) -> CPResponse {
    let escapedResult = result
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
    let body = """
        {"type":"result","subtype":"success","is_error":false,"result":"\(escapedResult)","structured_output":\(structuredOutputJSON)}
        """
    return CPResponse(stdout: Data(body.utf8), exitStatus: 0)
}

/// An auth-failure envelope ("not logged in").
private func cpAuthFailure() -> CPResponse {
    let body = """
        {"type":"result","subtype":"error","is_error":true,"result":"Not logged in. Please run /login."}
        """
    return CPResponse(stdout: Data(body.utf8), exitStatus: 1)
}

private let cpDigestText =
    "## HEADER\nmeeting: Vexatron Labs roadmap review\n\n## DECISIONS\nDana Marsh decidiu enviar o cronograma.\n"

private let cpNotesJSON = """
    {"title":"Roadmap","summary":"Resumo do roadmap.","meeting_type":"project_review",
     "detailed_notes":"Discussão.","decisions":["Enviar cronograma"],
     "action_items":[{"owner":"Dana Marsh","text":"enviar cronograma"}],
     "user_action_items":[{"owner":"Sam","text":"revisar"}],
     "speaker_name_mapping":[{"label":"S0","name":"Dana Marsh","confidence":"high","evidence":"Vamos enviar"}]}
    """

// MARK: - Fixtures (FICTIONAL only)

private func cpDigestRequest() -> DigestRequest {
    let meeting = Meeting(
        id: "01CPDIGESTMEETING0000000000",
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

// MARK: - Harness

private struct CPHarness {
    let engine: ClaudeCodeSummarizationEngine
    let database: BlaiseDatabase
    let invocations: Recorder<CPInvocation>
    let binaryURL: URL
}

/// Builds the engine with a fake `CommandRunner` that records each invocation and
/// replays `responses` in order. A real, executable temp file stands in for the
/// `claude` binary so `availability()`/`resolveBinary()` succeed.
private func makeCPHarness(
    responses: [CPResponse],
    token: String? = "oauth-test-token-not-real",
    binaryInstalled: Bool = true
) async throws -> CPHarness {
    let database = try makeDatabase()
    let settings = SettingsStore(database: database)
    let secrets = InMemorySecretStore()
    if let token {
        try secrets.set(
            key:
                "engine.\(ClaudeCodeSummarizationEngine.engineID).\(ClaudeCodeSummarizationEngine.oauthTokenConfigKey)",
            value: token)
    }

    // A real executable file so isExecutableFile(atPath:) resolves it. The
    // binary-path `.path` descriptor routes to SettingsStore (live read-through).
    let binaryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("blaise-fake-claude-\(UUID().uuidString)")
    if binaryInstalled {
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binaryURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: binaryURL.path)
        try await settings.set(
            "engine.\(ClaudeCodeSummarizationEngine.engineID).\(ClaudeCodeSummarizationEngine.binaryPathConfigKey)",
            to: binaryURL.path)
    }

    let ledger = CloudSpendLedger(database: database)
    let invocations = Recorder<CPInvocation>()
    let counter = Recorder<Int>()
    let runner: ClaudeCodeSummarizationEngine.CommandRunner = { executable, args, env, stdin in
        invocations.append(CPInvocation(executable: executable, args: args, env: env, stdin: stdin))
        counter.append(1)
        let index = min(counter.values.count - 1, responses.count - 1)
        return responses[index]
    }
    let configuration = EngineConfiguration(
        engineID: ClaudeCodeSummarizationEngine.engineID,
        descriptors: ClaudeCodeSummarizationEngine.descriptors,
        settings: settings, secrets: secrets)
    let engine = ClaudeCodeSummarizationEngine(
        configuration: configuration, ledger: ledger,
        homeDirectory: URL(fileURLWithPath: "/Users/fictional-tester"),
        runner: runner)
    return CPHarness(
        engine: engine, database: database, invocations: invocations, binaryURL: binaryURL)
}

// MARK: - Tests

@Suite struct ClaudeCodeEngineArgvAndEnvTests {
    /// (a) The clean `-p` argv: `-p`, the model, the clean-config flags, and
    /// `--output-format json` all ride every call.
    @Test func argvCarriesCleanConfig() async throws {
        let harness = try await makeCPHarness(responses: [cpSuccess(result: cpDigestText)])
        // Digest does synth THEN audit; the first invocation is the synth call.
        _ = try await harness.engine.generateDigest(cpDigestRequest())
        let invocation = try #require(harness.invocations.values.first)
        let args = invocation.args
        #expect(args.contains("-p"))
        #expect(args.contains("--model"))
        #expect(args.contains("claude-sonnet-4-6"))
        #expect(args.contains("--effort") && args.contains("high"))
        #expect(args.contains("--max-turns") && args.contains("1"))
        #expect(args.contains("--system-prompt-file"))
        #expect(args.contains("--setting-sources") && args.contains("project"))
        #expect(args.contains("--exclude-dynamic-system-prompt-sections"))
        #expect(args.contains("--disallowedTools"))
        #expect(args.contains("Bash") && args.contains("WebFetch"))
        // The output-format flag + value appear adjacently.
        let outIdx = try #require(args.firstIndex(of: "--output-format"))
        #expect(args[args.index(after: outIdx)] == "json")
    }

    /// (b) The child env carries the OAuth token + thinking-off vars and does NOT
    /// carry ANTHROPIC_API_KEY (the env-hygiene boundary that makes the
    /// subscription auth work). Decision A: HOME is a FRESH throwaway temp dir
    /// (NOT the real injected home), so the CLI keeps no transcript cache.
    @Test func childEnvCarriesTokenAndOmitsAPIKey() async throws {
        let harness = try await makeCPHarness(responses: [cpSuccess(result: cpDigestText)])
        _ = try await harness.engine.generateDigest(cpDigestRequest())
        let env = try #require(harness.invocations.values.first?.env)
        #expect(env["CLAUDE_CODE_OAUTH_TOKEN"] == "oauth-test-token-not-real")
        #expect(env["MAX_THINKING_TOKENS"] == "0")
        #expect(env["CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING"] == "1")
        #expect(env["CLAUDE_CODE_MAX_OUTPUT_TOKENS"] == "16384")
        // Decision A: HOME is a throwaway temp dir — NOT the injected real home —
        // so `claude -p` writes its `~/.claude` session cache somewhere disposable.
        let home = try #require(env["HOME"])
        #expect(home.contains("blaise-cp-home"), "HOME is the per-call throwaway dir")
        #expect(home != "/Users/fictional-tester", "the real injected home is NOT used")
        // PATH leads with the resolved claude's own dir (so a launcher CLI can
        // re-exec itself) then the common install locations — still an explicit set.
        #expect(
            env["PATH"]?.hasPrefix(harness.binaryURL.deletingLastPathComponent().path) == true,
            "the resolved claude's own dir leads PATH")
        #expect(env["PATH"]?.contains("/opt/homebrew/bin") == true)
        #expect(env["PATH"]?.hasSuffix("/usr/bin:/bin") == true)
        #expect(env["ANTHROPIC_API_KEY"] == nil, "the GUI env is never inherited")
    }

    /// (b2) Decision A: the throwaway HOME dir is DELETED after the call returns —
    /// no `~/.claude` transcript cache survives. By the time the recorded
    /// invocation is observable here, `invoke`'s `defer` has already reaped the
    /// dir (best-effort assertion: the staged HOME path no longer exists on disk).
    @Test func throwawayHomeDoesNotSurviveTheCall() async throws {
        let harness = try await makeCPHarness(responses: [cpSuccess(result: cpDigestText)])
        _ = try await harness.engine.generateDigest(cpDigestRequest())
        let home = try #require(harness.invocations.values.first?.env["HOME"])
        #expect(home.contains("blaise-cp-home"))
        #expect(
            !FileManager.default.fileExists(atPath: home),
            "the per-call throwaway HOME is removed after the call (no transcript cache kept)")
    }

    /// (c) The user (synth) message is passed on stdin, not as an argv flag.
    @Test func userMessageRidesStdin() async throws {
        let harness = try await makeCPHarness(responses: [cpSuccess(result: cpDigestText)])
        let request = cpDigestRequest()
        _ = try await harness.engine.generateDigest(request)
        let stdin = try #require(harness.invocations.values.first?.stdin)
        let text = try #require(String(data: stdin, encoding: .utf8))
        let expectedUser = DigestPromptBuilder.userMessage(for: request)
        #expect(text == expectedUser)
        // And it is NOT smuggled into argv.
        let args = try #require(harness.invocations.values.first?.args)
        #expect(!args.contains(where: { $0.contains("Vexatron Labs") && $0.count > 200 }))
    }
}

@Suite struct ClaudeCodeEngineSchemaTests {
    /// The NOTES call rides server-side schema enforcement: its argv carries
    /// `--json-schema <schema>` (the SHARED NotesResponseSchema) and `--max-turns 3`
    /// (the constrained object needs an extra tool-use turn). The schema value is
    /// the exact shared schema, placed adjacent to the `--json-schema` flag.
    @Test func notesArgvCarriesJSONSchemaAndMaxTurns3() async throws {
        let harness = try await makeCPHarness(responses: [
            cpStructuredSuccess(structuredOutputJSON: cpNotesJSON),
        ])
        _ = try await harness.engine.generateNotes(makeNotesRequest())
        let args = try #require(harness.invocations.values.first?.args)
        let schemaIdx = try #require(args.firstIndex(of: "--json-schema"))
        #expect(args[args.index(after: schemaIdx)] == NotesResponseSchema.json,
            "the shared NotesResponseSchema rides --json-schema")
        // --max-turns is 3 (NOT 1) for a schema-constrained call.
        let turnsIdx = try #require(args.firstIndex(of: "--max-turns"))
        #expect(args[args.index(after: turnsIdx)] == "3")
        // Output-format json is still present.
        #expect(args.contains("--output-format") && args.contains("json"))
    }

    /// The DIGEST call does NOT use schema enforcement: its argv carries NO
    /// `--json-schema` and keeps `--max-turns 1` (unchanged from before).
    @Test func digestArgvHasNoJSONSchemaAndKeepsMaxTurns1() async throws {
        let harness = try await makeCPHarness(responses: [cpSuccess(result: cpDigestText)])
        _ = try await harness.engine.generateDigest(cpDigestRequest())
        let args = try #require(harness.invocations.values.first?.args)
        #expect(!args.contains("--json-schema"), "the digest path is schema-free")
        let turnsIdx = try #require(args.firstIndex(of: "--max-turns"))
        #expect(args[args.index(after: turnsIdx)] == "1", "the digest keeps --max-turns 1")
    }

    /// The schema-validated `structured_output` object is read (mapped to a
    /// NotesResult) EVEN WHEN `result` is prose/garbage — proving the engine reads
    /// `structured_output`, not `result`, on the notes path.
    @Test func structuredOutputIsReadEvenWhenResultIsGarbage() async throws {
        let harness = try await makeCPHarness(responses: [
            cpStructuredSuccess(
                structuredOutputJSON: cpNotesJSON,
                result: "I'm sorry, I can't produce JSON here is some prose instead {{{ broken"),
        ])
        let result = try await harness.engine.generateNotes(makeNotesRequest())
        #expect(result.structured.summary == "Resumo do roadmap.")
        #expect(result.structured.meetingType == .projectReview)
        #expect(result.structured.decisions == ["Enviar cronograma"])
        #expect(result.structured.actionItems.contains(
            ActionItem(owner: "Dana Marsh", text: "enviar cronograma")))
        #expect(result.provenance.runtime == "claude-cli/-p/subprocess")
        #expect(result.usage?.estimatedCostUSD == 0.0)
    }
}

@Suite struct ClaudeCodeEngineMappingTests {
    /// (d) A canned success envelope maps to a DigestResult (mdV6-cp version, $0).
    @Test func successMapsToDigestResult() async throws {
        let harness = try await makeCPHarness(responses: [cpSuccess(result: cpDigestText)])
        let result = try await harness.engine.generateDigest(cpDigestRequest())
        #expect(result.digest.hasPrefix("## HEADER"))
        #expect(result.digest.contains("enviar o cronograma"))
        #expect(result.promptVersion == "mdV6-cp")
        #expect(result.usage?.estimatedCostUSD == 0.0)
    }

    /// (d) A canned notes envelope maps to a NotesResult (parsed against the
    /// schema, $0, the CLI runtime in provenance).
    @Test func successMapsToNotesResult() async throws {
        let harness = try await makeCPHarness(responses: [cpSuccess(result: cpNotesJSON)])
        let result = try await harness.engine.generateNotes(makeNotesRequest())
        #expect(result.structured.summary == "Resumo do roadmap.")
        #expect(result.structured.decisions == ["Enviar cronograma"])
        #expect(result.structured.actionItems.contains(ActionItem(owner: "Dana Marsh", text: "enviar cronograma")))
        #expect(result.provenance.engine == ClaudeCodeSummarizationEngine.engineID)
        #expect(result.provenance.runtime == "claude-cli/-p/subprocess")
        #expect(result.usage?.estimatedCostUSD == 0.0)
    }

    /// Notes JSON wrapped in a ```json fence + prose is still parsed (the `-p`
    /// path has no server-side schema enforcement, so we extract the object).
    @Test func notesFenceWrappedJSONIsParsed() async throws {
        let wrapped = "Here are the notes:\n```json\n" + cpNotesJSON + "\n```\nDone."
        let harness = try await makeCPHarness(responses: [cpSuccess(result: wrapped)])
        let result = try await harness.engine.generateNotes(makeNotesRequest())
        #expect(result.structured.summary == "Resumo do roadmap.")
    }

    /// A success notes call leaves a $0 receipt under the caller's purpose.
    @Test func notesLeavesZeroDollarReceipt() async throws {
        let harness = try await makeCPHarness(responses: [cpSuccess(result: cpNotesJSON)])
        _ = try await harness.engine.generateNotes(makeNotesRequest(), purpose: .generation)
        let (purposes, costs, notes) = try await harness.database.pool.read { db in
            (
                try String.fetchAll(db, sql: "SELECT purpose FROM cloud_spend_receipt"),
                try Double.fetchAll(db, sql: "SELECT cost_usd FROM cloud_spend_receipt"),
                try String.fetchAll(db, sql: "SELECT note FROM cloud_spend_receipt")
            )
        }
        #expect(purposes == ["generation"])
        #expect(costs == [0.0])
        #expect(notes == ["claude -p subscription"])
    }
}

@Suite struct ClaudeCodeEngineRetryAndErrorTests {
    /// (e) A 529 envelope retries, then succeeds: the bounded transient retry
    /// re-issues once and the second envelope is the good one.
    @Test func overloaded529RetriesThenSucceeds() async throws {
        let harness = try await makeCPHarness(responses: [
            cpOverloaded(),
            cpSuccess(result: cpDigestText),
        ])
        let result = try await harness.engine.generateDigest(cpDigestRequest())
        #expect(result.digest.hasPrefix("## HEADER"))
        // Two invocations to produce the synth draft (529 then success), then a
        // third for the combined audit.
        #expect(harness.invocations.values.count >= 2, "the 529 was retried")
    }

    /// (f) An auth-failure envelope maps to `.configurationMissing` (the OAuth
    /// token key) — NOT retried (retrying cannot fix a login problem).
    @Test func authFailureMapsToConfigurationMissing() async throws {
        let harness = try await makeCPHarness(responses: [cpAuthFailure(), cpAuthFailure()])
        await #expect(throws: EngineError.configurationMissing(
            key: ClaudeCodeSummarizationEngine.oauthTokenConfigKey))
        {
            _ = try await harness.engine.generateDigest(cpDigestRequest())
        }
        #expect(harness.invocations.values.count == 1, "an auth failure is not retried")
    }
}

@Suite struct ClaudeCodeEngineDigestPipelineTests {
    /// (g) The digest path does synth THEN audit (TWO invocations), and the audit
    /// invocation carries the combined-audit prompt + the synth draft.
    @Test func digestDoesSynthThenAudit() async throws {
        let auditedDigest =
            "## HEADER\nmeeting: Vexatron Labs roadmap review\n\n## DECISIONS\nDana Marsh decidiu enviar o cronograma.\n"
        let synthDraft = "## HEADER\nmeeting: Vexatron Labs roadmap review\n\n## DECISIONS\nDraft.\n"
        let harness = try await makeCPHarness(responses: [
            cpSuccess(result: synthDraft),    // synth
            cpSuccess(result: auditedDigest), // combined audit
        ])
        let result = try await harness.engine.generateDigest(cpDigestRequest())
        #expect(harness.invocations.values.count == 2, "synth then audit")
        // The second call's stdin carries the synth draft (verify/reconcile input).
        let auditStdin = try #require(
            harness.invocations.values.last?.stdin.flatMap { String(data: $0, encoding: .utf8) })
        #expect(auditStdin.contains("Draft."), "the audit call receives the synth draft")
        #expect(result.digest.contains("Dana Marsh decidiu"))
    }

    /// (g) FAIL-SOFT: if the AUDIT invocation errors (e.g. unparseable output that
    /// stripPreamble rejects, or a permanent CLI error), the synth draft is
    /// returned — the digest is NEVER lost.
    @Test func digestFailSoftWhenAuditErrors() async throws {
        let synthDraft = "## HEADER\nmeeting: Vexatron Labs roadmap review\n\n## DECISIONS\nKept draft line.\n"
        // The audit returns prose with NO line-start `## HEADER` → stripPreamble
        // throws → fail-soft to the synth draft.
        let badAudit = "I reviewed the draft; it looks fully grounded. No corrected digest emitted."
        let harness = try await makeCPHarness(responses: [
            cpSuccess(result: synthDraft),
            cpSuccess(result: badAudit),
        ])
        let result = try await harness.engine.generateDigest(cpDigestRequest())
        #expect(result.digest == synthDraft, "the audit misfire falls back to the synth draft")
        #expect(harness.invocations.values.count == 2, "both passes attempted; the draft survived")
    }

    /// The digest's SHAPED prompts ride the calls: the synth carries the
    /// completeness directive; the audit carries the STEP 1.5 coverage sweep.
    @Test func digestPromptsAreShaped() async throws {
        let harness = try await makeCPHarness(responses: [
            cpSuccess(result: cpDigestText),
            cpSuccess(result: cpDigestText),
        ])
        _ = try await harness.engine.generateDigest(cpDigestRequest())
        // The system prompt is written to a temp file named in argv; read it back
        // for the synth call BEFORE it is cleaned up is racy, so instead assert at
        // the shaping-function level (the engine applies these exact functions).
        let shapedSynth = ClaudeCodeSummarizationEngine.shapeSynth(
            DigestPromptBuilder.systemPrompt(for: .mdV6))
        #expect(shapedSynth.contains("COMPLETENESS IS A FIRST-CLASS GOAL"))
        #expect(shapedSynth.contains("Its discipline is the whole job."))
        let shapedAudit = ClaudeCodeSummarizationEngine.shapeAudit(
            DigestPromptBuilder.systemDigestCombinedAuditPrompt)
        #expect(shapedAudit.contains("STEP 1.5 — TRANSCRIPT COVERAGE SWEEP"))
        // The sweep is inserted BEFORE the STEP 2 banner.
        let sweepRange = try #require(shapedAudit.range(of: "STEP 1.5 — TRANSCRIPT COVERAGE SWEEP"))
        let step2Range = try #require(
            shapedAudit.range(of: "═══ STEP 2 — RECONCILE against the HUMAN NOTES"))
        #expect(sweepRange.lowerBound < step2Range.lowerBound)
    }
}

@Suite struct ClaudeCodeEngineFallbackPolicyTests {
    /// Decision B: the Account engine OVERRIDES the protocol default and reports
    /// `suppressesAutoFallback == true` — so a failure on the user-selected
    /// subscription engine goes notes-pending instead of silently switching to a
    /// metered engine ("stay free, but not silent").
    @Test func accountEngineSuppressesAutoFallback() async throws {
        let harness = try await makeCPHarness(responses: [cpSuccess(result: cpDigestText)])
        #expect(harness.engine.suppressesAutoFallback == true)
    }

    /// Decision B (the other side): the metered API engine keeps the protocol
    /// DEFAULT of `false` — it participates in auto-fallback as before. (The
    /// default `false` covers the local MLX engine too, which does not override
    /// it; a non-overriding mock engine is asserted as the MLX-class stand-in to
    /// avoid the heavy MLX driver/uv construction.)
    @Test func meteredAndLocalEnginesDoNotSuppressAutoFallback() async throws {
        // Metered cloud Claude engine (real type, no network touched — we only
        // read the property).
        let database = try makeDatabase()
        let settings = SettingsStore(database: database)
        let configuration = EngineConfiguration(
            engineID: ClaudeSummarizationEngine.engineID,
            descriptors: ClaudeSummarizationEngine.descriptors,
            settings: settings, secrets: InMemorySecretStore())
        let metered = ClaudeSummarizationEngine(
            configuration: configuration, ledger: CloudSpendLedger(database: database))
        #expect(metered.suppressesAutoFallback == false)

        // An engine that does NOT override (MLX-class / local stand-in) inherits
        // the protocol default of `false`.
        let nonOverriding = MockSummarizationEngine(id: "mlx-stand-in")
        #expect(nonOverriding.suppressesAutoFallback == false)
    }
}

@Suite struct ClaudeCodeEngineAvailabilityTests {
    /// Available iff the binary resolves AND the token is set.
    @Test func availableWithBinaryAndToken() async throws {
        let harness = try await makeCPHarness(responses: [cpSuccess(result: cpDigestText)])
        #expect(await harness.engine.availability() == .available)
    }

    @Test func unavailableWithoutToken() async throws {
        let harness = try await makeCPHarness(
            responses: [cpSuccess(result: cpDigestText)], token: nil)
        let availability = await harness.engine.availability()
        guard case .unavailable = availability else {
            Issue.record("expected unavailable without a token, got \(availability)")
            return
        }
    }

    @Test func unavailableWithoutBinary() async throws {
        let harness = try await makeCPHarness(
            responses: [cpSuccess(result: cpDigestText)], binaryInstalled: false)
        // The candidate paths (/opt/homebrew/bin/claude, etc.) are unlikely on a
        // CI box, but if a real `claude` IS installed this assertion would change;
        // we only assert the unavailable branch when no candidate resolves.
        let resolved = await harness.engine.resolveBinary()
        if resolved == nil {
            let availability = await harness.engine.availability()
            guard case .unavailable = availability else {
                Issue.record("expected unavailable without a binary, got \(availability)")
                return
            }
        }
    }
}

// MARK: - Double-escaped detailed_notes repair (rare model glitch)

@Suite struct ClaudeCodeDoubleEscapeRepairTests {
    private func notes(detailed: String) -> NotesStructured {
        NotesStructured(
            title: "Vexatron Labs roadmap review",
            summary: "Resumo do encontro.",
            detailedNotes: detailed,
            decisions: ["Lançar o beta em março"],
            actionItems: [ActionItem(owner: "Sam", text: "revisar cronograma")],
            userActionItems: [])
    }

    /// The observed corruption: a long markdown body whose newlines are the
    /// LITERAL two characters `\n` with ZERO real newlines → un-escaped in place.
    @Test func repairsTheDoubleEscapeSignature() {
        // Sections joined by the LITERAL "\n\n" (backslash-n), not real newlines.
        let corrupted = [
            "# Vexatron Labs roadmap review",
            "## Context and diagnosis",
            "- Dana Marsh outlined the Q2 plan and the team reviewed the timeline in detail.",
            "## Decisions",
            "- Ship the beta in March; Sam revisits the schedule by Friday afternoon.",
            "## Next steps",
            "- Circulate the updated deck and confirm the budget figures before the review.",
        ].joined(separator: "\\n\\n")
        #expect(!corrupted.contains("\n"))  // fixture sanity: zero real newlines
        #expect(corrupted.count > ClaudeCodeSummarizationEngine.doubleEscapeMinLength)

        let repaired = ClaudeCodeSummarizationEngine.repairDoubleEscapedDetailedNotes(
            notes(detailed: corrupted))
        #expect(repaired.detailedNotes.contains("\n"))  // now has real newlines
        #expect(!repaired.detailedNotes.contains("\\n"))  // no literal backslash-n left
        #expect(repaired.detailedNotes.hasPrefix("# Vexatron Labs roadmap review\n\n"))
        // Untouched siblings.
        #expect(repaired.summary == "Resumo do encontro.")
        #expect(repaired.decisions == ["Lançar o beta em março"])
    }

    /// A correctly generated multi-line body (REAL newlines) is never touched —
    /// the zero-real-newlines gate short-circuits.
    @Test func leavesCleanMultiLineBodyUntouched() {
        let clean = [
            "# Vexatron Labs roadmap review",
            "## Context",
            "- Dana Marsh outlined the Q2 plan and the team reviewed the timeline in detail.",
            "## Decisions",
            "- Ship the beta in March.",
        ].joined(separator: "\n\n")
        let result = ClaudeCodeSummarizationEngine.repairDoubleEscapedDetailedNotes(
            notes(detailed: clean))
        #expect(result.detailedNotes == clean)
    }

    /// A SHORT body that legitimately mentions the two-character sequence "\n"
    /// (below the length / run-count gate) is left exactly as written.
    @Test func leavesShortLiteralBackslashNMentionUntouched() {
        let literalMention = "Use \\n as the line separator in the export."
        #expect(!literalMention.contains("\n"))
        #expect(literalMention.contains("\\n"))
        let result = ClaudeCodeSummarizationEngine.repairDoubleEscapedDetailedNotes(
            notes(detailed: literalMention))
        #expect(result.detailedNotes == literalMention)  // below the length gate → untouched
    }

    /// A long single-line body with only ONE literal `\n` run (below the
    /// run-count floor) is left untouched — not the all-or-nothing signature.
    @Test func leavesLongBodyWithTooFewLiteralRunsUntouched() {
        let oneRun = String(repeating: "The roadmap review covered budget, timeline, and scope. ", count: 6)
            + "Use \\n once."
        #expect(!oneRun.contains("\n"))
        #expect(oneRun.count > ClaudeCodeSummarizationEngine.doubleEscapeMinLength)
        #expect(oneRun.components(separatedBy: "\\n").count - 1 < ClaudeCodeSummarizationEngine.doubleEscapeMinLiteralRuns)
        let result = ClaudeCodeSummarizationEngine.repairDoubleEscapedDetailedNotes(
            notes(detailed: oneRun))
        #expect(result.detailedNotes == oneRun)
    }

    /// A LONG single-paragraph body that legitimately discusses the two-character
    /// "\n" sequence several times — but with NO markdown-structural break — is
    /// left untouched (the prose false positive the audit flagged).
    @Test func leavesLongProseMentioningLiteralNewlineUntouched() {
        let prose = "The export pipeline uses \\n between records, and the parser must escape \\n carefully so the importer does not split on a stray \\n; we reviewed the delimiter handling at length and padded this fixture well beyond two hundred characters for the assertion."
        #expect(!prose.contains("\n"))  // zero real newlines
        #expect(prose.count > ClaudeCodeSummarizationEngine.doubleEscapeMinLength)
        #expect(prose.components(separatedBy: "\\n").count - 1 >= ClaudeCodeSummarizationEngine.doubleEscapeMinLiteralRuns)
        let result = ClaudeCodeSummarizationEngine.repairDoubleEscapedDetailedNotes(
            notes(detailed: prose))
        #expect(result.detailedNotes == prose)  // no markdown structure → untouched
    }

    /// A normal single-line body with NO backslash-n at all is untouched.
    @Test func leavesPlainSingleLineUntouched() {
        let plain = "A short one-line note with no structure."
        let result = ClaudeCodeSummarizationEngine.repairDoubleEscapedDetailedNotes(
            notes(detailed: plain))
        #expect(result.detailedNotes == plain)
    }
}
