import Foundation
import Testing

@testable import BlaiseCore

// GATED real `claude -p` smoke — SKIPPED unless BLAISE_CP_SMOKE=1 (never runs in CI).
// Drives the engine's REAL subprocess path (public init → SubprocessRunner → claude -p)
// end-to-end with FICTIONAL fixtures + the developer's OAuth token, to prove the
// Swift→CLI plumbing (clean argv, explicit minimal env, OAuth auth, JSON-envelope
// parse, synth→audit) works against a real `claude`. FICTIONAL data only
// (Vexatron Labs / Dana Marsh / Sam) — no real identity.

@Suite struct ClaudeCodeRealSmokeTests {
    @Test func realClaudePDigestSmoke() async throws {
        guard ProcessInfo.processInfo.environment["BLAISE_CP_SMOKE"] == "1" else {
            return  // skipped in normal/CI runs
        }
        let tokenPath = (NSHomeDirectory() as NSString).appendingPathComponent(".claude-oauth-token")
        let token = try String(contentsOfFile: tokenPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try #require(!token.isEmpty)

        let database = try makeDatabase()
        let settings = SettingsStore(database: database)
        let secrets = InMemorySecretStore()
        try secrets.set(
            key:
                "engine.\(ClaudeCodeSummarizationEngine.engineID).\(ClaudeCodeSummarizationEngine.oauthTokenConfigKey)",
            value: token)
        if let bin = ProcessInfo.processInfo.environment["BLAISE_CP_CLAUDE"], !bin.isEmpty {
            try await settings.set(
                "engine.\(ClaudeCodeSummarizationEngine.engineID).\(ClaudeCodeSummarizationEngine.binaryPathConfigKey)",
                to: bin)
        }
        let configuration = EngineConfiguration(
            engineID: ClaudeCodeSummarizationEngine.engineID,
            descriptors: ClaudeCodeSummarizationEngine.descriptors,
            settings: settings, secrets: secrets)
        let ledger = CloudSpendLedger(database: database)
        // PUBLIC init → the REAL SubprocessRunner-backed CommandRunner.
        let engine = ClaudeCodeSummarizationEngine(configuration: configuration, ledger: ledger)

        let availability = await engine.availability()
        print("SMOKE availability: \(availability)")

        let meeting = Meeting(
            id: "01CPSMOKEMEETING00000000000",
            title: "Vexatron Labs roadmap review",
            startedAt: Date(timeIntervalSince1970: 1_774_000_000),
            source: .meet, status: .processing,
            attendees: [Attendee(name: "Dana Marsh", email: "dana@vexatronlabs.example", source: .manual)],
            createdAt: msDate(), updatedAt: msDate())
        let request = DigestRequest(
            meeting: meeting,
            transcript: [
                TranscriptSegment(
                    meetingID: meeting.id, ord: 0, startSeconds: 0, endSeconds: 6,
                    speakerLabel: "S0", speakerName: "Dana Marsh",
                    text: "Decidimos lançar a Vexatron Labs em 12 de março e o orçamento é de US$ 50.000."),
                TranscriptSegment(
                    meetingID: meeting.id, ord: 1, startSeconds: 6, endSeconds: 12,
                    speakerLabel: "S1", speakerName: "Sam",
                    text: "Sam vai revisar o cronograma até sexta-feira."),
            ],
            notes: NotesStructured(
                title: "Roadmap", summary: "Resumo.", detailedNotes: "Discussão.",
                decisions: ["Lançar em 12 de março"],
                actionItems: [ActionItem(owner: "Sam", text: "revisar cronograma")],
                userActionItems: []),
            dominantLanguage: "pt",
            vocabulary: ["Vexatron Labs"],
            user: UserIdentity(name: "Dana Marsh", aliases: ["Dana"], email: "dana@vexatronlabs.example"))

        let result = try await engine.generateDigest(request, purpose: .digest)
        print("SMOKE DIGEST (\(result.digest.count) chars):\n\(result.digest)")
        #expect(result.digest.contains("## HEADER"))
        #expect(result.digest.count > 40)
    }

    /// GATED real NOTES smoke: drives the `--json-schema`-constrained notes path
    /// against a real `claude`, proving the server-side schema enforcement returns
    /// a schema-VALID object in `structured_output` that maps to a NotesResult.
    /// FICTIONAL data only. Skipped unless BLAISE_CP_SMOKE=1.
    @Test func realClaudePNotesSchemaSmoke() async throws {
        guard ProcessInfo.processInfo.environment["BLAISE_CP_SMOKE"] == "1" else {
            return  // skipped in normal/CI runs
        }
        let tokenPath = (NSHomeDirectory() as NSString).appendingPathComponent(".claude-oauth-token")
        let token = try String(contentsOfFile: tokenPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try #require(!token.isEmpty)

        let database = try makeDatabase()
        let settings = SettingsStore(database: database)
        let secrets = InMemorySecretStore()
        try secrets.set(
            key:
                "engine.\(ClaudeCodeSummarizationEngine.engineID).\(ClaudeCodeSummarizationEngine.oauthTokenConfigKey)",
            value: token)
        if let bin = ProcessInfo.processInfo.environment["BLAISE_CP_CLAUDE"], !bin.isEmpty {
            try await settings.set(
                "engine.\(ClaudeCodeSummarizationEngine.engineID).\(ClaudeCodeSummarizationEngine.binaryPathConfigKey)",
                to: bin)
        }
        let configuration = EngineConfiguration(
            engineID: ClaudeCodeSummarizationEngine.engineID,
            descriptors: ClaudeCodeSummarizationEngine.descriptors,
            settings: settings, secrets: secrets)
        let ledger = CloudSpendLedger(database: database)
        let engine = ClaudeCodeSummarizationEngine(configuration: configuration, ledger: ledger)

        let meeting = Meeting(
            id: "01CPSMOKENOTES000000000000",
            title: "Vexatron Labs roadmap review",
            startedAt: Date(timeIntervalSince1970: 1_774_000_000),
            source: .meet, status: .processing,
            attendees: [Attendee(name: "Dana Marsh", email: "dana@vexatronlabs.example", source: .manual)],
            createdAt: msDate(), updatedAt: msDate())
        let request = NotesRequest(
            meeting: meeting,
            transcript: [
                TranscriptSegment(
                    meetingID: meeting.id, ord: 0, startSeconds: 0, endSeconds: 6,
                    speakerLabel: "S0", speakerName: "Dana Marsh",
                    text: "Decidimos lançar a Vexatron Labs em 12 de março e o orçamento é de US$ 50.000."),
                TranscriptSegment(
                    meetingID: meeting.id, ord: 1, startSeconds: 6, endSeconds: 12,
                    speakerLabel: "S1", speakerName: "Sam",
                    text: "Sam vai revisar o cronograma até sexta-feira."),
            ],
            dominantLanguage: "pt",
            vocabulary: ["Vexatron Labs"],
            user: UserIdentity(name: "Dana Marsh", aliases: ["Dana"], email: "dana@vexatronlabs.example"))

        let result = try await engine.generateNotes(request, purpose: .generation)
        let meetingType = try #require(result.structured.meetingType)
        print("SMOKE NOTES summary: \(result.structured.summary)")
        print("SMOKE NOTES type: \(meetingType.rawValue)")
        print("SMOKE NOTES decisions: \(result.structured.decisions)")
        print("SMOKE NOTES actions: \(result.structured.actionItems)")
        // The schema-constrained type MUST be a valid taxonomy enum (never free text).
        #expect(MeetingType.allCases.contains(meetingType))
        #expect(!result.structured.summary.isEmpty)
        #expect(result.usage?.estimatedCostUSD == 0.0)
    }
}
