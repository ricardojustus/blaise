import Foundation
import os

/// The "Account engine" — a SECOND, user-selectable summarization engine that
/// generates the meeting NOTES and the memory DIGEST by shelling out to the
/// `claude -p` CLI (the user's Claude SUBSCRIPTION, ~$0) instead of the metered
/// Anthropic Messages API. It mirrors `ClaudeSummarizationEngine`'s shape (actor,
/// injectable seam, availability(), generateNotes/generateDigest, the combined
/// audit, the `$0` receipt under a cancellation shield), but the transport is a
/// subprocess (the ONLY allowed chokepoint, `SubprocessRunner.run`) and the cost
/// is zero (subscription, not metered tokens).
///
/// IT IS NEVER THE DEFAULT — it is registered alongside the API engine and only
/// runs when the user selects it AND it is available (the `claude` binary
/// resolves AND the OAuth token is set).
///
/// DIGEST shaping (validated): this engine applies the empirically-validated
/// *shaped* digest prompts — a COMPLETENESS directive on the synth system prompt
/// and a STEP 1.5 transcript COVERAGE SWEEP on the combined-audit system prompt
/// — which close the measured coverage gap without losing faithfulness. The
/// shaping is applied ONLY here; the shipped API prompts are untouched.
///
/// Privacy/env boundary (HARD): the child runs with an EXPLICIT minimal
/// environment — never the inherited GUI login env — so `ANTHROPIC_API_KEY` is
/// simply ABSENT from the child and the CLI authenticates with the OAuth token
/// alone. This is the same env-hygiene rule the MLX engine enforces.
public actor ClaudeCodeSummarizationEngine: SummarizationEngine {
    public static let engineID = "claude-cli"
    /// The wire model the CLI runs — kept identical to the API engine's model so
    /// the digest quality target (the validated shaping was tuned on Sonnet 4.6)
    /// holds and the receipt model field is meaningful.
    public static let model = "claude-sonnet-4-6"
    /// OAuth token for the user's Claude subscription (`CLAUDE_CODE_OAUTH_TOKEN`),
    /// stored as a `.secret`.
    public static let oauthTokenConfigKey = "oauthToken"
    /// Optional override for the `claude` binary path (a `.path`); empty/unset →
    /// the candidate search below.
    public static let binaryPathConfigKey = "binaryPath"

    /// Candidate `claude` install locations, in resolution order (a configured
    /// path always wins). Covers Homebrew (arm + intel), the per-user local
    /// install, and a manual `/usr/local/bin` drop.
    public static let candidateBinaryPaths: [String] = [
        "~/.local/bin/claude",  // the official native install (`claude install`)
        "/opt/homebrew/bin/claude",
        "~/.claude/local/claude",
        "/usr/local/bin/claude",
    ]

    public nonisolated let id: String = ClaudeCodeSummarizationEngine.engineID
    public nonisolated let displayName = "Claude account (subscription)"
    public nonisolated let kind: EngineKind = .cloud
    /// Lightweight (D17): a subprocess CLI call, no local weights. (It is a cloud
    /// call under the hood; nothing here loads model weights.)
    public nonisolated let loadProfile: EngineLoadProfile = .lightweight
    /// Decision B: when the user has SELECTED this subscription engine and it
    /// fails with a fallback-trigger error, the pipeline must NOT silently fall
    /// back to the metered API engine — it leaves the notes PENDING with a
    /// user-visible warning so the user can retry on their free engine. ("Stay
    /// free, but not silent.") This is the ONLY engine that overrides the
    /// protocol default of `false`.
    public nonisolated let suppressesAutoFallback: Bool = true
    /// ~$0 — the subscription, not metered tokens. The receipt is $0 so the
    /// cloud ceiling gate is left untouched (correct).
    public nonisolated let costDescriptor: EngineCostDescriptor? = EngineCostDescriptor(
        pricingSummary: "Included in your Claude subscription (≈ US$ 0 per meeting via the claude CLI)",
        estimatedPerMeetingUSD: 0.0)
    public static let descriptors: [EngineConfigDescriptor] = [
        EngineConfigDescriptor(
            key: ClaudeCodeSummarizationEngine.oauthTokenConfigKey,
            label: "Claude subscription OAuth token", kind: .secret, required: true),
        EngineConfigDescriptor(
            key: ClaudeCodeSummarizationEngine.binaryPathConfigKey,
            label: "claude CLI path (optional)", kind: .path, required: false),
    ]
    public nonisolated let configDescriptors: [EngineConfigDescriptor] =
        ClaudeCodeSummarizationEngine.descriptors

    // MARK: - Tunables

    /// Per-call subprocess timeout — a `-p` digest pass can be long (16k output
    /// tokens at realistic rates), matching the API engine's retry-attempt cap.
    static let callTimeout: TimeInterval = 480
    /// The bounded transient-retry ceiling (≤ 5) for an overloaded/5xx CLI
    /// envelope; backoff is `min(2^n, cap)` seconds.
    static let maxTransientRetries = 5
    static let transientBackoffCapSeconds: UInt64 = 16
    /// Notes JSON malformed → ONE re-issue (parity with the API notes path's
    /// single bounded retry contract).
    static let maxNotesParseRetries = 1

    // MARK: - Subprocess seam (injectable for tests)

    /// A minimal, Sendable mirror of `SubprocessRunner.Outcome` — the seam returns
    /// this so a test fake can produce a canned outcome without spawning a real
    /// process.
    public struct SubprocessOutcomeLike: Sendable {
        public var stdout: Data
        public var stderrTail: String
        /// nil when the runner killed the child (timeout/cancel).
        public var exitStatus: Int32?
        public var terminationReason: Process.TerminationReason
        public var timedOut: Bool
        public var cancelled: Bool

        public init(
            stdout: Data, stderrTail: String = "", exitStatus: Int32?,
            terminationReason: Process.TerminationReason = .exit,
            timedOut: Bool = false, cancelled: Bool = false
        ) {
            self.stdout = stdout
            self.stderrTail = stderrTail
            self.exitStatus = exitStatus
            self.terminationReason = terminationReason
            self.timedOut = timedOut
            self.cancelled = cancelled
        }
    }

    /// The subprocess chokepoint seam: real impl wraps `SubprocessRunner.run`; the
    /// test impl returns a canned `claude -p --output-format json` envelope.
    public typealias CommandRunner = @Sendable (
        _ executable: URL, _ args: [String], _ env: [String: String], _ stdin: Data?
    ) async throws -> SubprocessOutcomeLike

    private let configuration: EngineConfiguration
    private let ledger: CloudSpendLedger
    private let runner: CommandRunner
    private let homeDirectory: URL
    private let chain = EngineTaskChain()
    private let logger = Logger(subsystem: BlaiseBundle.identifier, category: "notes.claude-cli")

    /// Services are constructor-injected at the composition root (C2). The real
    /// runner wraps `SubprocessRunner.run` with `Self.callTimeout`.
    public init(configuration: EngineConfiguration, ledger: CloudSpendLedger) {
        self.init(
            configuration: configuration, ledger: ledger,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            runner: Self.realRunner)
    }

    init(
        configuration: EngineConfiguration,
        ledger: CloudSpendLedger,
        homeDirectory: URL,
        runner: @escaping CommandRunner
    ) {
        self.configuration = configuration
        self.ledger = ledger
        self.homeDirectory = homeDirectory
        self.runner = runner
    }

    /// A dedicated EMPTY working directory. `--setting-sources project` discovers
    /// project config (memory files, .claude, .mcp.json, hooks) by walking up from
    /// cwd, so running from a GUARANTEED-empty dir loads NOTHING — belt-and-suspenders
    /// over the already-disallowed tools, and independent of where the app launched.
    static let cleanWorkingDirectory: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blaise-cp-clean-cwd", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let realRunner: CommandRunner = { executable, args, env, stdin in
        let outcome = try await SubprocessRunner.run(
            executable: executable, arguments: args, environment: env,
            currentDirectory: ClaudeCodeSummarizationEngine.cleanWorkingDirectory,
            stdin: stdin, timeout: ClaudeCodeSummarizationEngine.callTimeout)
        return SubprocessOutcomeLike(
            stdout: outcome.stdout, stderrTail: outcome.stderrTail,
            exitStatus: outcome.exitStatus, terminationReason: outcome.terminationReason,
            timedOut: outcome.timedOut, cancelled: outcome.cancelled)
    }

    // MARK: - Binary / token resolution

    private nonisolated func expandTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    /// Resolves the `claude` binary: the configured path if it is set and
    /// executable, else the first executable candidate. nil → not installed.
    func resolveBinary() async -> URL? {
        let configured: String?
        do {
            configured = try await configuration.value(for: Self.binaryPathConfigKey)
        } catch {
            configured = nil
        }
        var candidates: [String] = []
        if let configured, !configured.isEmpty { candidates.append(configured) }
        candidates.append(contentsOf: Self.candidateBinaryPaths)
        for raw in candidates {
            let path = expandTilde(raw)
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    /// Reads the OAuth token secret, or nil if unreadable/unset.
    private func resolveToken() async -> String? {
        let token = try? await configuration.value(for: Self.oauthTokenConfigKey)
        guard let token, !token.isEmpty else { return nil }
        return token
    }

    // MARK: - Availability

    public func availability() async -> EngineAvailability {
        guard await resolveBinary() != nil else {
            return .unavailable(reason: "the `claude` CLI was not found (configure its path in Settings)")
        }
        guard await resolveToken() != nil else {
            return .unavailable(reason: "Claude subscription OAuth token not configured")
        }
        return .available
    }

    public func prepare() async throws {}

    // MARK: - The clean `-p` invocation

    /// The disallowed-tools list pinned onto every `-p` call: this is a pure
    /// text-in/text-out generation, so EVERY tool is denied (no Bash/file/web/task
    /// access). Kept as a constant so the test can assert the clean config.
    static let disallowedTools: [String] = [
        "Bash", "Read", "Write", "Edit", "Glob", "Grep", "Task", "WebFetch",
        "WebSearch", "TodoWrite", "NotebookEdit", "BashOutput", "KillShell",
    ]

    /// The `--max-turns` for a plain (no-schema) call: 1 turn, the model answers
    /// directly in `result`.
    static let defaultMaxTurns = 1
    /// The `--max-turns` for a `--json-schema`-constrained call: the schema-validated
    /// object is delivered as a tool-use that needs an EXTRA turn, so `--max-turns 1`
    /// fails with `error_max_turns`. 3 is the verified safe ceiling.
    static let schemaMaxTurns = 3

    /// The clean `-p` argv (minus the per-call system-prompt temp file path,
    /// which is appended by `invoke`). Tests assert these flags ride every call.
    ///
    /// When `jsonSchema != nil`, the call is CONSTRAINED to that JSON schema
    /// SERVER-SIDE (`--json-schema`, real enforcement like the Messages API
    /// structured output) and uses `schemaMaxTurns` (the constrained object rides
    /// an extra tool-use turn). When nil (the digest path), behaves exactly as
    /// before: `defaultMaxTurns`, no `--json-schema`, model answer in `result`.
    static func baseArguments(
        systemPromptFile: String, jsonSchema: String? = nil, maxTurns: Int = defaultMaxTurns
    ) -> [String] {
        var args: [String] = [
            "-p",
            "--model", model,
            "--effort", "high",
            "--max-turns", String(maxTurns),
            "--system-prompt-file", systemPromptFile,
            "--setting-sources", "project",
            "--exclude-dynamic-system-prompt-sections",
            "--disallowedTools",
        ] + disallowedTools
        if let jsonSchema {
            args += ["--json-schema", jsonSchema]
        }
        args += ["--output-format", "json"]
        return args
    }

    /// The EXPLICIT minimal child env — never the inherited GUI env, so
    /// `ANTHROPIC_API_KEY` is simply absent and the CLI authenticates with the
    /// OAuth token alone. Thinking is turned fully off (the digest/notes are
    /// extract-only, deterministic work).
    ///
    /// `home` is the THROWAWAY HOME the caller stages per invocation (deleted
    /// after the call) so the CLI keeps NO copy of the meeting transcript under a
    /// real `~/.claude`/`~/.claude.json`. `homeDirectory` remains only the
    /// fallback/default when a caller does not supply one.
    func childEnvironment(token: String, binary: URL, home: URL? = nil) -> [String: String] {
        // PATH includes the resolved `claude`'s OWN directory plus the common
        // install locations (Homebrew node, /usr/local) — a launcher/node-backed
        // CLI needs more than {/usr/bin:/bin} to re-exec itself. This is still an
        // EXPLICIT set: the inherited GUI env (and any ANTHROPIC_API_KEY in it) is
        // NEVER passed to the child, so the OAuth token authenticates alone.
        let binDir = binary.deletingLastPathComponent().path
        return [
            "PATH": "\(binDir):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            "HOME": (home ?? homeDirectory).path,
            "CLAUDE_CODE_OAUTH_TOKEN": token,
            "MAX_THINKING_TOKENS": "0",
            "CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING": "1",
            "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "16384",
        ]
    }

    /// The `claude -p --output-format json` result envelope (the fields we read).
    struct CLIEnvelope: Decodable {
        /// The model's text answer (our notes JSON or digest markdown).
        var result: String?
        var isError: Bool?
        var apiErrorStatus: Int?
        var subtype: String?
        /// The SCHEMA-VALIDATED, schema-conformant JSON object the CLI returns when
        /// the call rode `--json-schema` (server-side structured output, like the
        /// Messages API `output_config.format`). It is an arbitrary JSON object; we
        /// capture it as a `RawJSONValue` so it can be RE-SERIALIZED to a canonical
        /// JSON string to feed `NotesEngineResponse.decode`. Absent on the digest
        /// path (no schema) — then we read `result` exactly as before.
        var structuredOutput: RawJSONValue?

        enum CodingKeys: String, CodingKey {
            case result
            case isError = "is_error"
            case apiErrorStatus = "api_error_status"
            case subtype
            case structuredOutput = "structured_output"
        }
    }

    /// A minimal, Sendable, Decodable mirror of an arbitrary JSON value — enough to
    /// capture the CLI's `structured_output` object and RE-SERIALIZE it to a
    /// canonical JSON string (`JSONSerialization` cannot round-trip Swift `Any`
    /// across an `actor` boundary Sendable-clean, and `Codable` forbids a bare
    /// `Any`). Object key order is not preserved on re-serialization, which is fine:
    /// `NotesEngineResponse.decode` is key-driven, not order-driven.
    enum RawJSONValue: Decodable, Sendable {
        case object([String: RawJSONValue])
        case array([RawJSONValue])
        case string(String)
        case number(Double)
        case bool(Bool)
        case null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let b = try? container.decode(Bool.self) {
                self = .bool(b)
            } else if let n = try? container.decode(Double.self) {
                self = .number(n)
            } else if let s = try? container.decode(String.self) {
                self = .string(s)
            } else if let arr = try? container.decode([RawJSONValue].self) {
                self = .array(arr)
            } else if let obj = try? container.decode([String: RawJSONValue].self) {
                self = .object(obj)
            } else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "unrecognized JSON value in structured_output")
            }
        }

        /// The Foundation JSON object graph for this value (for `JSONSerialization`).
        var jsonObject: Any {
            switch self {
            case .object(let o): return o.mapValues { $0.jsonObject }
            case .array(let a): return a.map { $0.jsonObject }
            case .string(let s): return s
            case .number(let n): return n
            case .bool(let b): return b
            case .null: return NSNull()
            }
        }

        /// Re-serialize to a JSON string, or nil if the value cannot be encoded
        /// (a non-object/array top level is not valid `JSONSerialization` input).
        func serialized() -> String? {
            let object = jsonObject
            guard JSONSerialization.isValidJSONObject(object) else { return nil }
            return (try? JSONSerialization.data(withJSONObject: object))
                .flatMap { String(data: $0, encoding: .utf8) }
        }
    }

    /// Run ONE `claude -p` generation: writes `system` to a temp file, feeds
    /// `user` on stdin, parses the JSON envelope, and returns the `result` text.
    /// Maps transient overload/5xx → `.transient` (the caller's bounded retry
    /// re-issues), an auth/"not logged in" failure → `.configurationMissing`,
    /// everything else → `.permanent`. Records ONE `$0` receipt on success inside
    /// a cancellation shield.
    ///
    /// `jsonSchema` (the NOTES path passes the shared `NotesResponseSchema`): when
    /// non-nil the call is server-side CONSTRAINED to that schema and `runOnce`
    /// returns the re-serialized `structured_output` object (NOT `result`). When
    /// nil (the DIGEST path) the behavior is unchanged: `defaultMaxTurns`, no
    /// `--json-schema`, return `result`.
    private func invoke(
        system: String, user: String, purpose: CloudSpendPurpose, meetingID: MeetingID?,
        jsonSchema: String? = nil
    ) async throws -> String {
        if Task.isCancelled || CancellationToken.current?.isCancelled == true {
            throw EngineError.cancelled
        }
        guard let binary = await resolveBinary() else {
            throw EngineError.configurationMissing(key: Self.binaryPathConfigKey)
        }
        guard let token = await resolveToken() else {
            throw EngineError.configurationMissing(key: Self.oauthTokenConfigKey)
        }

        // The system prompt rides a temp file (--system-prompt-file); cleaned up
        // unconditionally. A random name avoids collisions across concurrent runs.
        let systemPromptFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("blaise-cp-sys-\(UUID().uuidString).txt")
        do {
            try Data(system.utf8).write(to: systemPromptFile, options: .atomic)
            // The system prompt is not secret, but keep the staged file owner-only.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: systemPromptFile.path)
        } catch {
            throw EngineError.transient("could not stage the system-prompt file: \(error)")
        }
        defer { try? FileManager.default.removeItem(at: systemPromptFile) }

        // THROWAWAY HOME (no transcript cache): `claude -p` writes its session
        // cache (a `.claude/` dir + `.claude.json`) under HOME, which would keep
        // the CLI's OWN copy of the meeting transcript. Run each invocation under
        // a FRESH temp HOME and DELETE it after the call returns — so no copy
        // survives. Auth is unaffected: the OAuth token rides the env
        // (`CLAUDE_CODE_OAUTH_TOKEN`), not `~/.claude`. (The injected
        // `homeDirectory` is now only a fallback/default — this per-call dir is
        // what the child actually uses.)
        let throwawayHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("blaise-cp-home-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: throwawayHome, withIntermediateDirectories: true)
        } catch {
            throw EngineError.transient("could not stage the throwaway HOME dir: \(error)")
        }
        // Deleted AFTER the call returns (success OR throw) so the CLI's cache —
        // the only on-disk copy of the transcript it would keep — is gone.
        defer { try? FileManager.default.removeItem(at: throwawayHome) }

        let maxTurns = jsonSchema == nil ? Self.defaultMaxTurns : Self.schemaMaxTurns
        let args = Self.baseArguments(
            systemPromptFile: systemPromptFile.path, jsonSchema: jsonSchema, maxTurns: maxTurns)
        let env = childEnvironment(token: token, binary: binary, home: throwawayHome)
        let stdin = Data(user.utf8)
        let expectStructuredOutput = jsonSchema != nil

        var attempt = 0
        while true {
            if Task.isCancelled || CancellationToken.current?.isCancelled == true {
                throw EngineError.cancelled
            }
            do {
                return try await runOnce(
                    binary: binary, args: args, env: env, stdin: stdin,
                    purpose: purpose, meetingID: meetingID,
                    expectStructuredOutput: expectStructuredOutput)
            } catch let error as EngineError where Self.isTransient(error) {
                attempt += 1
                if attempt > Self.maxTransientRetries { throw error }
                let backoff = min(
                    UInt64(1) << UInt64(attempt - 1), Self.transientBackoffCapSeconds)
                logger.warning(
                    "claude -p transient failure (attempt \(attempt)/\(Self.maxTransientRetries)); backing off \(backoff)s")
                if Task.isCancelled || CancellationToken.current?.isCancelled == true {
                    throw EngineError.cancelled
                }
                try? await Task.sleep(for: .seconds(backoff))
            }
        }
    }

    /// True for the CLI errors the bounded retry re-issues (overload/5xx). An
    /// auth failure (`.configurationMissing`) or a `.permanent` is NOT retried.
    static func isTransient(_ error: EngineError) -> Bool {
        if case .transient = error { return true }
        return false
    }

    /// A SINGLE `claude -p` subprocess attempt + envelope decode + `$0` receipt
    /// (inside a cancellation shield). Throws the mapped `EngineError`.
    ///
    /// When `expectStructuredOutput` is true (a `--json-schema`-constrained call)
    /// and the envelope carries a `structured_output` object, the RE-SERIALIZED
    /// schema-validated JSON string is returned (NOT `result`, which holds the
    /// model's prose). Otherwise (the digest path) `result` is returned, unchanged.
    private func runOnce(
        binary: URL, args: [String], env: [String: String], stdin: Data,
        purpose: CloudSpendPurpose, meetingID: MeetingID?,
        expectStructuredOutput: Bool = false
    ) async throws -> String {
        let outcome: SubprocessOutcomeLike
        do {
            outcome = try await runner(binary, args, env, stdin)
        } catch let error as EngineError {
            throw error
        } catch {
            // Spawn failure (binary vanished/not executable mid-run) — treat as a
            // missing-binary configuration problem (a fallback trigger).
            throw EngineError.configurationMissing(key: Self.binaryPathConfigKey)
        }

        if outcome.cancelled { throw EngineError.cancelled }
        if outcome.timedOut { throw EngineError.transient("claude -p timed out") }
        if outcome.terminationReason == .uncaughtSignal {
            throw EngineError.transient(
                "claude -p killed by signal: \(Self.stderrExcerpt(outcome.stderrTail))")
        }

        // Parse the JSON envelope. The CLI emits the result envelope on stdout
        // even on an `is_error`, so we decode FIRST and read `is_error`.
        let envelope = try? JSONDecoder().decode(CLIEnvelope.self, from: outcome.stdout)

        if let envelope, envelope.isError == true {
            throw Self.mapEnvelopeError(envelope, stderr: outcome.stderrTail)
        }

        // The payload to return: on a `--json-schema` call, the SCHEMA-VALIDATED
        // `structured_output` object re-serialized to a JSON string (NOT `result`,
        // which is prose); on the digest path, the `result` text exactly as before.
        let payload: String? = {
            if expectStructuredOutput, let structured = envelope?.structuredOutput,
                let serialized = structured.serialized()
            {
                return serialized
            }
            return envelope?.result
        }()

        // No parseable envelope OR a non-zero exit with no usable payload →
        // transient (a crashed/truncated CLI run; retrying may help). For a schema
        // call this also covers a missing/unserializable `structured_output`.
        guard let result = payload, !result.isEmpty else {
            if let status = outcome.exitStatus, status != 0 {
                if Self.stderrSignalsAuthFailure(outcome.stderrTail) {
                    throw EngineError.configurationMissing(key: Self.oauthTokenConfigKey)
                }
                throw EngineError.transient(
                    "claude -p exit \(status): \(Self.stderrExcerpt(outcome.stderrTail))")
            }
            throw EngineError.transient(
                "claude -p produced no parseable result: \(Self.stderrExcerpt(outcome.stderrTail))")
        }

        // Success → ONE $0 receipt under the caller's purpose, inside a
        // cancellation shield (mirrors the API engine: the spend record must land
        // even if the caller task is cancelled after the call returns). The cost
        // is $0 — the subscription, not metered tokens — so the ceiling gate is
        // untouched.
        let ledger = self.ledger
        let id = self.id
        await Task.detached {
            try? await ledger.add(
                0.0,
                receipt: CloudSpendLedger.ReceiptDraft(
                    engineID: id,
                    model: ClaudeCodeSummarizationEngine.model,
                    purpose: purpose,
                    meetingID: meetingID,
                    inputTokens: 0,
                    outputTokens: 0,
                    note: "claude -p subscription"))
        }.value

        return result
    }

    /// Map a CLI `is_error` envelope: an overloaded/5xx `api_error_status`
    /// (529/503/500/429) → `.transient`; an auth/"not logged in" failure →
    /// `.configurationMissing`; everything else → `.permanent`.
    static func mapEnvelopeError(_ envelope: CLIEnvelope, stderr: String) -> EngineError {
        if let status = envelope.apiErrorStatus, [529, 503, 500, 429].contains(status) {
            return .transient("claude -p API \(status)")
        }
        let haystack = ((envelope.result ?? "") + " " + (envelope.subtype ?? "") + " " + stderr)
        if stderrSignalsAuthFailure(haystack) {
            return .configurationMissing(key: oauthTokenConfigKey)
        }
        // An overload/5xx can surface WITHOUT api_error_status (text only) — retry
        // those too rather than dropping to the pending path on the first wobble.
        if textSignalsTransient(haystack) {
            return .transient("claude -p transient: \(stderrExcerpt(haystack))")
        }
        return .permanent("claude -p error: \(stderrExcerpt(envelope.result ?? envelope.subtype ?? stderr))")
    }

    /// Overload/rate-limit/5xx signatures that warrant a retry even when the CLI
    /// envelope omits `api_error_status`.
    static func textSignalsTransient(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let signatures = [
            "overloaded", "rate limit", "ratelimit", "temporarily", "try again",
            "service unavailable", "529", "503", "timeout", "timed out",
        ]
        return signatures.contains { lowered.contains($0) }
    }

    /// "Not logged in" / auth-failure signatures from the CLI envelope or stderr.
    static func stderrSignalsAuthFailure(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let signatures = [
            "not logged in", "please run /login", "unauthorized", "authentication",
            "invalid api key", "oauth", "401", "403", "no auth",
        ]
        return signatures.contains { lowered.contains($0) }
    }

    static func stderrExcerpt(_ s: String) -> String {
        String(s.suffix(600))
    }

    // MARK: - Notes generation

    public func generateNotes(_ request: NotesRequest, purpose: CloudSpendPurpose) async throws -> NotesResult {
        try await chain.run { try await self.generateNotesBody(request, purpose: purpose) }
    }

    private func generateNotesBody(_ request: NotesRequest, purpose: CloudSpendPurpose) async throws -> NotesResult {
        if Task.isCancelled { throw EngineError.cancelled }

        // Same prompt authority as both shipped engines (live read-through of the
        // global notes.promptVersion). The notes prompts are NOT shaped — only
        // the digest path carries the validated shaping.
        let promptVersion = NotesPromptBuilder.resolve(
            try? await configuration.globalValue(key: NotesPromptBuilder.versionSettingsKey))
        let system = NotesPromptBuilder.systemPrompt(for: promptVersion)
        // The notes prompt rides `--json-schema` (server-side schema enforcement)
        // below; we ALSO append an explicit output-contract reminder as
        // belt-and-suspenders for the rare result-fallback path. coerceNotesJSON +
        // the Swift decode validate/retry regardless.
        let systemWithContract = system + "\n\n" + Self.notesJSONOutputContract
        let user = NotesPromptBuilder.userMessage(for: request)

        // SERVER-SIDE schema enforcement: pass the SHARED `NotesResponseSchema`
        // (the same schema the API + MLX engines enforce) to `--json-schema`, so the
        // CLI returns a schema-VALIDATED object in `structured_output`. `invoke`
        // re-serializes that object; `coerceNotesJSON` + the decode below stay as
        // belt-and-suspenders (the structured output should already be valid).
        let notesSchema = NotesResponseSchema.json

        var parseAttempt = 0
        while true {
            let raw = try await invoke(
                system: systemWithContract, user: user, purpose: purpose,
                meetingID: request.meeting.id, jsonSchema: notesSchema)
            let json = Self.coerceNotesJSON(Self.extractJSONObject(raw))
            do {
                let response = try NotesEngineResponse.decode(from: Data(json.utf8))
                let (structured, mapping) = response.toNotes()
                return NotesResult(
                    structured: Self.repairDoubleEscapedDetailedNotes(structured),
                    usage: EngineUsage(inputUnits: nil, outputUnits: nil, estimatedCostUSD: 0.0),
                    provenance: NotesProvenance(
                        engine: id,
                        model: Self.model,
                        pipelineVersion: "",
                        runtime: "claude-cli/-p/subprocess",
                        promptVersion: promptVersion.rawValue),
                    speakerNameMapping: mapping)
            } catch {
                parseAttempt += 1
                if parseAttempt > Self.maxNotesParseRetries {
                    throw EngineError.permanent(
                        "claude -p notes output was not schema-shaped JSON after retry: \(error)")
                }
                logger.warning("claude -p notes JSON malformed; retrying once")
            }
        }
    }

    /// Gates for the double-escape repair: the body must be long enough to be real
    /// multi-line markdown, carry several literal `\n` runs, AND place those runs in
    /// markdown-structural positions before we treat zero-real-newlines as
    /// corruption — so a prose paragraph that merely mentions the two-character
    /// sequence "\n" (a logging / CSV / regex meeting topic) is never repaired.
    static let doubleEscapeMinLength = 200
    static let doubleEscapeMinLiteralRuns = 3
    /// A corrupted body has its markdown block breaks escaped, so a literal `\n`
    /// sits before a paragraph break or a block marker; prose mentioning "\n" does
    /// not. (Bullet/quote markers require the trailing space, so "…word\n- ok" in a
    /// prose sentence without a real list does not count.)
    static let doubleEscapeMarkdownMarkers = ["\\n\\n", "\\n#", "\\n- ", "\\n* ", "\\n> "]

    /// Defensive repair for a rare, transient `claude -p` generation glitch
    /// (observed once, during a Claude elevated-error window): the model writes
    /// its markdown newlines as the LITERAL two characters `\n` inside the JSON
    /// string it returns, so `detailed_notes` arrives as one unbroken wall of
    /// text. The signature is a long markdown body that contains literal `\n` runs
    /// in markdown-structural positions yet ZERO real newlines — impossible for a
    /// correctly rendered multi-line markdown document. When it matches, un-escape
    /// the literal newlines so a garbled blob never ships downstream. A correctly
    /// generated multi-line body always carries real newlines (so it never
    /// matches), and the markdown-structure gate excludes a prose paragraph that
    /// merely mentions the literal sequence "\n"; only `detailed_notes` is guarded
    /// (the sole multi-line field — `summary`/`decisions`/action items are
    /// single-line and cannot exhibit the signature). NOT a root-cause fix: the
    /// cause is a model-side escaping blip we could not reliably reproduce.
    static func repairDoubleEscapedDetailedNotes(_ structured: NotesStructured) -> NotesStructured {
        let dn = structured.detailedNotes
        guard !dn.contains("\n"),  // zero REAL newlines …
            dn.range(of: "\\n") != nil,  // … yet a literal backslash-n is present …
            dn.count > doubleEscapeMinLength,  // … in a body long enough to be markdown …
            dn.components(separatedBy: "\\n").count - 1 >= doubleEscapeMinLiteralRuns,  // … with several runs …
            doubleEscapeMarkdownMarkers.contains(where: dn.contains)  // … in markdown-structural spots.
        else { return structured }
        var repaired = structured
        repaired.detailedNotes = dn.replacingOccurrences(of: "\\n", with: "\n")
        return repaired
    }

    /// Appended to the notes system prompt as a belt-and-suspenders output-contract
    /// reminder ALONGSIDE the server-side `--json-schema` enforcement (it still
    /// hardens the rare result-fallback path): demand the bare schema-shaped JSON
    /// object only.
    static let notesJSONOutputContract = """
        OUTPUT CONTRACT (STRICT): respond with a SINGLE JSON object and NOTHING ELSE \
        — no markdown fences, no prose before or after. The object MUST carry exactly \
        these keys: title, summary, meeting_type, detailed_notes, decisions, \
        action_items, user_action_items, speaker_name_mapping. Each action item is \
        {"owner": ..., "text": ...}. Each speaker mapping is \
        {"label": ..., "name": ..., "confidence": ..., "evidence": ...}. \
        "meeting_type" MUST be EXACTLY ONE of these literal values, never a free-text \
        phrase: one_on_one, budget_finance, project_review, decision_meeting, \
        brainstorm_workshop, external_call, interview, general — use "general" if \
        unsure. "confidence" MUST be exactly one of: high, medium, low. \
        TYPES (critical): "title", "summary", and "detailed_notes" are each a SINGLE \
        STRING ("detailed_notes" is markdown), NEVER an array or object. "decisions" is \
        an array of STRINGS. "action_items" and "user_action_items" are arrays of \
        {"owner": string, "text": string}. Do not nest or restructure these fields.
        """

    /// Coerce a `-p` notes JSON object to the schema's expected field TYPES before
    /// decoding. The CLI has NO server-side json_schema enforcement, so the model can
    /// emit a String field as an array (observed: `detailed_notes`), a scalar where an
    /// array is expected, loose action-item shapes, or an out-of-range enum. Rather
    /// than fail the entire notes on a type mismatch, normalize each known field.
    /// No-op when the JSON is already schema-shaped (the API/MLX path never hits this).
    static func coerceNotesJSON(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
            var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return json }

        func asString(_ v: Any?) -> String {
            guard let v, !(v is NSNull) else { return "" }
            if let s = v as? String { return s }
            if let arr = v as? [Any] { return arr.map(asString).joined(separator: "\n") }
            if let d = v as? [String: Any] {
                return (try? JSONSerialization.data(withJSONObject: d))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            }
            return String(describing: v)
        }
        // STRING fields: collapse an array/object/scalar into one string.
        for key in ["title", "summary", "detailed_notes"] where obj[key] != nil {
            if !(obj[key] is String) { obj[key] = asString(obj[key]) }
        }
        // decisions: [String]
        if let arr = obj["decisions"] as? [Any] {
            obj["decisions"] = arr.map(asString)
        } else if obj["decisions"] != nil, !(obj["decisions"] is NSNull) {
            obj["decisions"] = [asString(obj["decisions"])]
        }
        // action_items / user_action_items: [{owner, text}]
        func items(_ v: Any?) -> [[String: String]] {
            (v as? [Any])?.compactMap { el in
                if let d = el as? [String: Any] {
                    return ["owner": asString(d["owner"]), "text": asString(d["text"])]
                }
                if el is NSNull { return nil }
                return ["owner": "", "text": asString(el)]
            } ?? []
        }
        obj["action_items"] = items(obj["action_items"])
        obj["user_action_items"] = items(obj["user_action_items"])
        // speaker_name_mapping: [{label, name?, confidence in {high,medium,low}, evidence?}]
        if let arr = obj["speaker_name_mapping"] as? [Any] {
            obj["speaker_name_mapping"] = arr.compactMap { el -> [String: Any]? in
                guard let d = el as? [String: Any] else { return nil }
                var m: [String: Any] = ["label": asString(d["label"])]
                if let n = d["name"], !(n is NSNull) { m["name"] = asString(n) } else { m["name"] = NSNull() }
                let conf = asString(d["confidence"]).lowercased()
                m["confidence"] = ["high", "medium", "low"].contains(conf) ? conf : "low"
                if let e = d["evidence"], !(e is NSNull) { m["evidence"] = asString(e) }
                return m
            }
        }
        return (try? JSONSerialization.data(withJSONObject: obj))
            .flatMap { String(data: $0, encoding: .utf8) } ?? json
    }

    /// Pull the outermost JSON object from a `-p` answer (the CLI sometimes wraps
    /// the JSON in a ```json fence or narrates around it). Returns the substring
    /// from the first `{` to the last `}`; falls back to the raw string.
    static func extractJSONObject(_ s: String) -> String {
        // Prefer a fenced ```json … ``` block (the most common wrapper a -p answer
        // adds); fall back to the first-`{`/last-`}` slice; else the raw string.
        if let fenced = Self.fencedJSON(s) { return fenced }
        guard let open = s.firstIndex(of: "{"), let close = s.lastIndex(of: "}"),
            open < close
        else { return s }
        return String(s[open...close])
    }

    /// Extract the body of the first ```json … ``` (or bare ``` … ```) fence that
    /// contains a JSON object, if present.
    static func fencedJSON(_ s: String) -> String? {
        guard let fenceStart = s.range(of: "```") else { return nil }
        var rest = s[fenceStart.upperBound...]
        if rest.lowercased().hasPrefix("json") { rest = rest.dropFirst(4) }
        if let nl = rest.firstIndex(of: "\n") { rest = rest[rest.index(after: nl)...] }
        guard let fenceEnd = rest.range(of: "```") else { return nil }
        let body = rest[..<fenceEnd.lowerBound]
        guard body.contains("{"), body.contains("}") else { return nil }
        return String(body)
    }

    // MARK: - Digest generation (synth → combined audit, both `-p`, both SHAPED)

    public func generateDigest(_ request: DigestRequest, purpose: CloudSpendPurpose) async throws -> DigestResult {
        try await chain.run { try await self.generateDigestBody(request, purpose: purpose) }
    }

    private func generateDigestBody(_ request: DigestRequest, purpose: CloudSpendPurpose) async throws -> DigestResult {
        let version = DigestPromptBuilder.shippedVersion

        // 1) SHAPED SYNTH `-p` → draft.
        let synthSystem = Self.shapeSynth(DigestPromptBuilder.systemPrompt(for: version))
        let synthUser = DigestPromptBuilder.userMessage(for: request)
        let draft = try await invoke(
            system: synthSystem, user: synthUser, purpose: purpose,
            meetingID: request.meeting.id)

        // 2) SHAPED COMBINED-AUDIT `-p` → final, run through stripPreamble.
        //    FAIL-SOFT: any throw here returns the synth draft (never lose the
        //    digest), mirroring the pipeline's audit fallback for the API engine.
        let final: String
        do {
            let auditSystem = Self.shapeAudit(DigestPromptBuilder.systemDigestCombinedAuditPrompt)
            let auditUser = DigestPromptBuilder.combinedAuditUserMessage(
                for: request, draftDigest: draft)
            let audited = try await invoke(
                system: auditSystem, user: auditUser, purpose: purpose,
                meetingID: request.meeting.id)
            final = try ClaudeSummarizationEngine.stripPreamble(audited)
        } catch {
            logger.warning("claude -p combined audit failed; keeping the synthesis draft: \(String(describing: error))")
            final = draft
        }

        return DigestResult(
            digest: final,
            usage: EngineUsage(inputUnits: nil, outputUnits: nil, estimatedCostUSD: 0.0),
            promptVersion: "mdV6-cp")
    }

    // MARK: - Digest prompt shaping (ported from shaped_prompts.py)

    /// The completeness directive, inserted right AFTER the synth opening
    /// paragraph (the same INSERTION `shape_synth` does — base wording preserved
    /// verbatim, a targeted COMPLETENESS block appended at the most-attended
    /// position). Ported byte-for-byte from `COMPLETENESS_BLOCK`.
    static let completenessBlock = """


        COMPLETENESS IS A FIRST-CLASS GOAL — equal in weight to precision (read this and apply it throughout STEP 1): this digest is the ONLY downstream record, so every substantive item you omit is permanently lost. Before you finalize, walk the transcript IN ORDER, segment by segment, and ensure that — wherever the transcript states it — the digest carries a line for EACH of: every decision; every commitment or action item with its owner; every concrete figure, amount, price, count, percentage, date, or deadline; every named project, product, partner, company, or person credited with a contribution; every distinct framework, model, process, rule, principle, or named example described; every named risk, blocker, or concern; every unresolved or open question; and every substantive position or view a speaker took. On LONG meetings especially: do NOT compress several distinct points into one generic line, and do NOT skip a stretch of conversation because it felt like a tangent — a tangent that names a figure, a decision, a framework, or a credited person still yields durable facts of record. Brevity is NOT a goal; faithful completeness is. This NEVER licenses fabrication: include ONLY what the transcript actually states, attributed per the evidence rules below.
        """

    /// The STEP 1.5 transcript coverage sweep, inserted BEFORE the STEP 2
    /// notes-reconcile anchor (the same INSERTION `shape_audit` does). Ported
    /// byte-for-byte from `COVERAGE_SWEEP` (incl. the trailing blank line).
    static let coverageSweep = """
        ═══ STEP 1.5 — TRANSCRIPT COVERAGE SWEEP (recall; do this AFTER STEP 1 and BEFORE STEP 2) ═══
        Re-read the TRANSCRIPT in order and verify the STEP-1 digest is COMPLETE against it. For every substantive item the transcript body states — a decision; a commitment or action item with its owner; a concrete figure, amount, price, count, percentage, date, or deadline; a named project, product, partner, or credited contribution; a distinct framework, model, process, rule, principle, or named example; a named risk, blocker, or concern; an unresolved/open question; or a substantive position/view — confirm it is represented in the digest. For each transcript-GROUNDED substantive item that is MISSING, ADD a single self-contained line to the correct `## ` section, using canonical names, the body-grounded owner, the meeting's language, and the one-assertion-per-line discipline. This step is ADDITIVE and TRANSCRIPT-GATED: add ONLY what the transcript body actually states; never invent, never launder, and do not add pleasantries or trivia — add items of record. On long meetings especially, recover every distinct decision, figure, and framework STEP 1 compressed away. (Apply the same RECALL GUARD and anti-fabrication discipline as STEP 1.)


        """

    /// The synth anchor: the directive is inserted right after this sentence
    /// (the last sentence of the opening paragraph). Matches `_SYNTH_ANCHOR`.
    static let synthAnchor = "Its discipline is the whole job."
    /// The audit anchor: the coverage sweep is inserted right before this STEP-2
    /// banner. Matches `_AUDIT_ANCHOR` (a prefix of the Swift banner line, so a
    /// substring replace lands at the STEP-2 boundary).
    static let auditAnchor = "═══ STEP 2 — RECONCILE against the HUMAN NOTES"

    /// Insert the completeness directive right after the opening paragraph
    /// (`shape_synth`). Fallback: prepend (mirrors the Python fallback).
    static func shapeSynth(_ base: String) -> String {
        guard base.contains(synthAnchor) else {
            return completenessBlock.trimmingCharacters(in: .whitespacesAndNewlines)
                + "\n\n" + base
        }
        return base.replacingFirstOccurrence(of: synthAnchor, with: synthAnchor + completenessBlock)
    }

    /// Insert the transcript coverage sweep just before STEP 2 (`shape_audit`).
    /// Fallback: append (mirrors the Python fallback).
    static func shapeAudit(_ base: String) -> String {
        guard base.contains(auditAnchor) else {
            return base + "\n\n" + coverageSweep
        }
        return base.replacingFirstOccurrence(of: auditAnchor, with: coverageSweep + auditAnchor)
    }
}

extension String {
    /// Replace ONLY the first occurrence of `target` (parity with Python's
    /// `str.replace(a, b, 1)`, which `shape_synth`/`shape_audit` use).
    fileprivate func replacingFirstOccurrence(of target: String, with replacement: String) -> String {
        guard let range = self.range(of: target) else { return self }
        return self.replacingCharacters(in: range, with: replacement)
    }
}
