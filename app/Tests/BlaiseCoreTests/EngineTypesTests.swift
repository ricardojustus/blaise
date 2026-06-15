import Foundation
import Testing
@testable import BlaiseCore

@Suite struct EngineTypesTests {
    @Test func userIdentityShippedDefaultIsNeutralAndEmpty() {
        // G3/D19: the app ships with NO personal data; the empty default means
        // "not yet onboarded".
        let identity = UserIdentity.shippedDefault
        #expect(identity.name == "")
        #expect(identity.aliases == [])
        #expect(identity.email == "")
        #expect(identity.isEmpty)
        #expect(UserIdentity.settingsKey == "user.identity")
    }

    @Test func userIdentityIsEmptyReflectsOnboardingState() {
        #expect(UserIdentity(name: "", aliases: [], email: "").isEmpty)
        #expect(UserIdentity(name: "  ", aliases: [], email: "").isEmpty)
        #expect(!UserIdentity(name: "Sam", aliases: [], email: "").isEmpty)
    }

    @Test func userIdentityRoundTripsThroughCodableAndSettingsStore() async throws {
        let decoded = try JSONDecoder().decode(
            UserIdentity.self,
            from: JSONEncoder().encode(UserIdentity.shippedDefault)
        )
        #expect(decoded == UserIdentity.shippedDefault)

        let store = SettingsStore(database: try makeDatabase())
        try await store.set(UserIdentity.settingsKey, to: UserIdentity.shippedDefault)
        #expect(try await store.get(UserIdentity.settingsKey) == UserIdentity.shippedDefault)
    }

    @Test func engineUsageAndCostDescriptorRoundTrip() throws {
        let usage = EngineUsage(inputUnits: 12_000, outputUnits: 800, estimatedCostUSD: 0.034)
        #expect(try JSONDecoder().decode(EngineUsage.self, from: JSONEncoder().encode(usage)) == usage)

        let localUsage = EngineUsage() // local engines: all nil
        #expect(try JSONDecoder().decode(EngineUsage.self, from: JSONEncoder().encode(localUsage)) == localUsage)

        let cost = EngineCostDescriptor(pricingSummary: "US$ 0.006/min audio", estimatedPerMeetingUSD: 0.27)
        #expect(try JSONDecoder().decode(EngineCostDescriptor.self, from: JSONEncoder().encode(cost)) == cost)
    }

    @Test func asrTypesRoundTrip() throws {
        let result = ASRResult(
            segments: [ASRSegment(startSeconds: 0, endSeconds: 2.5, text: "olá, hello")],
            detectedLanguage: "pt-BR",
            rawPayload: Data(#"{"words":[]}"#.utf8),
            usage: EngineUsage(inputUnits: 2700),
            provenance: ASRProvenance(
                engine: "mock", model: "m", runtime: "r", engineVersion: "1",
                transcribedAt: msDate(), vocabularyHintsApplied: true, languageHint: "pt-BR"
            )
        )
        #expect(try JSONDecoder().decode(ASRResult.self, from: JSONEncoder().encode(result)) == result)

        let request = ASRRequest(
            audioURL: URL(fileURLWithPath: "/tmp/a.wav"),
            vocabularyHints: ["Vexatron", "Lattice"],
            languageHint: nil
        )
        #expect(try JSONDecoder().decode(ASRRequest.self, from: JSONEncoder().encode(request)) == request)
    }

    @Test func notesTypesRoundTrip() throws {
        let result = NotesResult(
            structured: makeStructuredNotes(),
            usage: EngineUsage(inputUnits: 9_000, outputUnits: 1_200, estimatedCostUSD: 0.05),
            provenance: NotesProvenance(
                engine: "mock", model: "m", pipelineVersion: "0.1",
                runtime: "r", rendererVersion: NotesRenderer.version
            )
        )
        #expect(try JSONDecoder().decode(NotesResult.self, from: JSONEncoder().encode(result)) == result)

        let request = NotesRequest(
            meeting: makeMeeting(),
            transcript: [TranscriptSegment(meetingID: "m", ord: 0, startSeconds: 0, endSeconds: 1, text: "oi")],
            dominantLanguage: "pt-BR",
            vocabulary: ["Vexatron"],
            user: UserIdentity.shippedDefault
        )
        #expect(try JSONDecoder().decode(NotesRequest.self, from: JSONEncoder().encode(request)) == request)
    }

    @Test func meetingNotesRoundTripsWithStructured() async throws {
        let database = try makeDatabase()
        let meeting = makeMeeting()
        try await MeetingRepository(database: database).create(meeting)
        let repo = NotesRepository(database: database)
        let notes = makeNotes(meetingID: meeting.id)

        try await repo.upsert(notes)
        let fetched = try #require(try await repo.fetch(meetingID: meeting.id))
        #expect(fetched == notes)
        #expect(fetched.structured == makeStructuredNotes())
        #expect(fetched.provenance.runtime == "test-runtime")
        #expect(fetched.provenance.rendererVersion == NotesRenderer.version)
    }

    /// Decode defaults: JSON persisted before C2 (no new fields) must still
    /// decode — additive change, no migration.
    @Test func provenanceDecodeDefaultsCoverPreC2JSON() throws {
        let legacyASR = Data("""
        {"engine":"e","model":"m","runtime":"r","engine_version":"v","transcribed_at":700000000}
        """.utf8)
        let asr = try JSONDecoder().decode(ASRProvenance.self, from: legacyASR)
        #expect(asr.vocabularyHintsApplied == false)
        #expect(asr.languageHint == nil)

        let legacyNotes = Data("""
        {"engine":"e","model":"m","pipeline_version":"0.1"}
        """.utf8)
        let notes = try JSONDecoder().decode(NotesProvenance.self, from: legacyNotes)
        #expect(notes.runtime == "")
        #expect(notes.rendererVersion == "")
        // G3: userName decode-defaults to "" for any pre-G3 persisted JSON.
        #expect(notes.userName == "")
    }

    @Test("G3-M2: renderer version is \"2\" (name-driven title changed bytes) and userName travels in provenance")
    func rendererVersionBumpAndUserNameProvenance() async throws {
        // The user action-items title is name-driven (G3), so the SAME
        // structured/language/title renders different bytes than pre-G3 — the
        // version MUST have moved off "1", and the identity name the bytes
        // depend on rides in provenance.
        #expect(NotesRenderer.version == "2")

        let provenance = NotesProvenance(
            engine: "e", model: "m", pipelineVersion: "p",
            rendererVersion: NotesRenderer.version, userName: "Sam")
        let decoded = try JSONDecoder().decode(
            NotesProvenance.self, from: JSONEncoder().encode(provenance))
        #expect(decoded.userName == "Sam")
        #expect(decoded == provenance)
        // The provenance JSON uses the snake_case wire key.
        let json = String(decoding: try JSONEncoder().encode(provenance), as: UTF8.self)
        #expect(json.contains("\"user_name\":\"Sam\""))
    }
}

// C6 impl-audit H-1 regression: configurationMissing is the fourth fallback
// trigger (no-key cloud default must fall back to local, not fail).
@Suite struct FallbackTriggerTests {
    @Test func configurationMissingTriggersFallback() {
        #expect(EngineFallbackReason.isFallbackTrigger(.configurationMissing(key: "apiKey")))
        #expect(EngineFallbackReason.isFallbackTrigger(.permanent(EngineFallbackReason.inputTooLong)))
        #expect(EngineFallbackReason.isFallbackTrigger(.permanent(EngineFallbackReason.outOfMemory)))
        #expect(EngineFallbackReason.isFallbackTrigger(.notAvailable(reason: EngineFallbackReason.monthlyCeiling)))
        #expect(!EngineFallbackReason.isFallbackTrigger(.transient("x")))
        #expect(!EngineFallbackReason.isFallbackTrigger(.permanent("other")))
    }
}
