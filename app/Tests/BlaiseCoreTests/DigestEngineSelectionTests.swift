import Foundation
import GRDB
import Testing

@testable import BlaiseCore

// The Memory digest engine slot: every digest call resolves the digest
// selection; unset follows notes. Mock engines only; fictional data only.

private let digestUser = UserIdentity(
    name: "Dana Marsh", aliases: ["Dana"], email: "dana@vexatronlabs.example")
private let digestAttendees = [
    Attendee(name: "Dana Marsh", email: "dana@vexatronlabs.example", source: .manual),
    Attendee(name: "Pax Okoro", email: "pax@quollharbor.example", source: .manual),
]

private func makeHarness(digestEngineID: String? = nil) async throws -> PipelineHarness {
    let harness = try await makePipelineHarness()
    let settings = SettingsStore(database: harness.database)
    try await settings.set(UserIdentity.settingsKey, to: digestUser)
    if let digestEngineID {
        try await settings.set(EngineResolver.digestSettingsKey, to: digestEngineID)
    }
    return harness
}

private func payload(_ harness: PipelineHarness, _ path: String?) throws -> [String: Any] {
    let url = harness.database.rootURL.appendingPathComponent(try #require(path))
    return try #require(
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
}

private func digestProvenance(_ payload: [String: Any]) throws -> [String: Any] {
    let provenance = try #require(payload["provenance"] as? [String: Any])
    return try #require(provenance["memory_digest"] as? [String: Any])
}

private func notesProvenance(_ payload: [String: Any]) throws -> [String: Any] {
    let provenance = try #require(payload["provenance"] as? [String: Any])
    return try #require(provenance["notes"] as? [String: Any])
}

@Suite struct DigestEngineSelectionPipelineTests {
    @Test func noSelectionRunsTheDigestOnTheNotesEngine() async throws {
        let harness = try await makeHarness()
        let meeting = try await harness.importTestMeeting(attendees: digestAttendees)
        let record = try await harness.pipeline.process(meetingID: meeting.id)

        #expect(harness.notesPrimary.state.withLock { $0.digestRequests.count } == 1)
        #expect(harness.notesFallback.state.withLock { $0.digestRequests.count } == 0)
        let notes = try #require(
            try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id))
        #expect(notes.provenance.digestEngine == harness.notesPrimary.id)
        #expect(notes.provenance.digestModel == "mock-model")
        let digest = try digestProvenance(try payload(harness, record.payloadPath))
        #expect(digest["engine"] as? String == harness.notesPrimary.id)
        #expect(digest["model"] as? String == "mock-model")
    }

    /// Notes on the second-registered engine, so an empty id that slipped into
    /// substitution would land on the first one instead.
    @Test func emptySelectionIsSameAsNotes() async throws {
        let harness = try await makeHarness(digestEngineID: "")
        try await SettingsStore(database: harness.database).set(
            EngineResolver.summarizationSettingsKey, to: harness.notesFallback.id)
        let meeting = try await harness.importTestMeeting(attendees: digestAttendees)
        _ = try await harness.pipeline.process(meetingID: meeting.id)

        #expect(harness.notesFallback.state.withLock { $0.digestRequests.count } == 1)
        #expect(harness.notesPrimary.state.withLock { $0.digestRequests.count } == 0)
    }

    /// A row minted before the digest provenance fields existed re-mints the
    /// same bytes: the payload falls back to the notes engine and model.
    @Test func legacyProvenanceRematerializesByteIdentically() async throws {
        let harness = try await makeHarness()
        let meeting = try await harness.importTestMeeting(attendees: digestAttendees)
        let record = try await harness.pipeline.process(meetingID: meeting.id)

        try await harness.database.pool.write { db in
            try db.execute(
                sql: """
                    UPDATE meeting_notes
                    SET provenance = json_remove(provenance, '$.digest_engine', '$.digest_model')
                    WHERE meeting_id = ?
                    """,
                arguments: [meeting.id])
        }
        let legacy = try #require(
            try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id))
        #expect(legacy.provenance.digestEngine == "")
        #expect(legacy.provenance.digestModel == "")
        let finalMeeting = try #require(try await harness.meeting(meeting.id))
        let rebuilt = EvidencePayloadBuilder.build(
            meeting: finalMeeting, segments: try await harness.segments(meeting.id),
            notes: legacy, user: digestUser, corrections: [])
        #expect(rebuilt.versionHash == record.versionHash)
    }

    @Test func aSelectedEngineServesTheDigestAndNotesStayPut() async throws {
        let harness = try await makeHarness(digestEngineID: "pipeline-mock-notes-fallback")
        harness.notesFallback.state.withLock {
            $0.digestString = "## HEADER\nmeeting: Quoll Harbor sync\nspeaker: (none resolved)\n"
            $0.digestModel = "mock-digest-model"
        }
        let meeting = try await harness.importTestMeeting(attendees: digestAttendees)
        let record = try await harness.pipeline.process(meetingID: meeting.id)

        #expect(harness.notesPrimary.state.withLock { $0.requests.count } == 1)
        #expect(harness.notesPrimary.state.withLock { $0.digestRequests.count } == 0)
        #expect(harness.notesFallback.state.withLock { $0.requests.count } == 0)
        #expect(harness.notesFallback.state.withLock { $0.digestRequests.count } == 1)

        let notes = try #require(
            try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id))
        #expect(notes.memoryDigest?.contains("Quoll Harbor sync") == true)
        #expect(notes.provenance.engine == harness.notesPrimary.id)
        #expect(notes.provenance.digestEngine == harness.notesFallback.id)
        #expect(notes.provenance.digestModel == "mock-digest-model")
        #expect(notes.provenance.model == "mock-model")
        let body = try payload(harness, record.payloadPath)
        #expect(try digestProvenance(body)["engine"] as? String == harness.notesFallback.id)
        #expect(try digestProvenance(body)["model"] as? String == "mock-digest-model")
        #expect(try notesProvenance(body)["engine"] as? String == harness.notesPrimary.id)
    }

    @Test func theDigestResumeRunsOnTheSelectedEngine() async throws {
        let harness = try await makeHarness(digestEngineID: "pipeline-mock-notes-fallback")
        harness.notesFallback.state.withLock { $0.digestError = .permanent("forced digest failure") }
        let meeting = try await harness.importTestMeeting(attendees: digestAttendees)
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        let pending = try #require(try await harness.meeting(meeting.id))
        #expect(DigestPendingClass.isPending(pending.lastProcessingError))

        harness.notesFallback.state.withLock {
            $0.digestError = nil
            $0.digestModel = "mock-digest-model"
        }
        let fallbackBefore = harness.notesFallback.state.withLock { $0.digestRequests.count }
        await harness.pipeline.resumePendingDigests()

        #expect(harness.notesFallback.state.withLock { $0.digestRequests.count } == fallbackBefore + 1)
        #expect(harness.notesPrimary.state.withLock { $0.digestRequests.count } == 0)
        #expect(harness.notesPrimary.state.withLock { $0.requests.count } == 1, "notes not re-run")
        let healed = try #require(try await harness.meeting(meeting.id))
        #expect(healed.lastProcessingError == nil)
        let notes = try #require(
            try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id))
        #expect(notes.provenance.digestEngine == harness.notesFallback.id)
        #expect(notes.provenance.digestModel == "mock-digest-model")
        #expect(notes.provenance.engine == harness.notesPrimary.id)
    }

    @Test func anUnavailableDigestEngineParksTheDigestWithItsReason() async throws {
        let harness = try await makeHarness(digestEngineID: "pipeline-mock-notes-fallback")
        harness.notesFallback.state.withLock {
            $0.prepareError = .notAvailable(reason: "Vexatron Labs key is missing")
        }
        let meeting = try await harness.importTestMeeting(attendees: digestAttendees)
        let record = try await harness.pipeline.process(meetingID: meeting.id)

        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.status == .ready)
        #expect(DigestPendingClass.isPending(stored.lastProcessingError))
        #expect(stored.lastProcessingError?.contains("Vexatron Labs key is missing") == true)
        let notes = try #require(
            try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id))
        #expect(notes.memoryDigest == nil)
        #expect(notes.provenance.engine == harness.notesPrimary.id, "notes unaffected")
        #expect(harness.notesPrimary.state.withLock { $0.requests.count } == 1)
        #expect(harness.notesPrimary.state.withLock { $0.digestRequests.count } == 0)
        #expect(harness.notesFallback.state.withLock { $0.digestRequests.count } == 0)
        #expect(try payload(harness, record.payloadPath)["memory_digest"] == nil)
    }
}

@Suite struct DigestEngineSelectionEditTests {
    @Test func digestReconcileRunsOnTheSelectedEngine() async throws {
        let notesEngine = SettleScriptedEngine(id: "settle-notes-engine")
        let harness = try await makeSettleHarness(
            extraEngines: [notesEngine], selectedEngineID: notesEngine.id)
        try await SettingsStore(database: harness.database)
            .set(EngineResolver.digestSettingsKey, to: harness.engine.id)
        let meeting = try await seedSettleMeeting(harness)
        _ = try await seedSettleCorrection(
            harness, meetingID: meeting.id, createdAt: harness.clock.now())
        try await setDigestOwed(harness, meeting.id)
        harness.engine.scriptDigest([[]])

        _ = try await harness.pipeline.reconcileDigest(meetingID: meeting.id)

        #expect(harness.engine.digestCallCount == 1)
        #expect(notesEngine.digestCallCount == 0)
    }

    /// Owed digest debt is actionable when the DIGEST engine can edit digests,
    /// even though the notes engine cannot.
    @Test func owedDigestSettlesWhenOnlyTheDigestEngineCanEdit() async throws {
        let notesEngine = SettleNonEditingEngine()
        let harness = try await makeSettleHarness(
            extraEngines: [notesEngine], selectedEngineID: notesEngine.id)
        try await SettingsStore(database: harness.database)
            .set(EngineResolver.digestSettingsKey, to: harness.engine.id)
        let meeting = try await seedSettleMeeting(harness)
        _ = try await seedSettleCorrection(
            harness, meetingID: meeting.id, status: .applied,
            quotedText: "70% coverage", userText: "Coverage is 80%",
            createdAt: harness.clock.now())
        try await setDigestOwed(harness, meeting.id)
        harness.engine.scriptDigest([[
            DigestEditOperation(find: "70% coverage", replace: "80% coverage", instruction: 1)
        ]])

        await harness.pipeline.resumeOwedSettles()

        #expect(harness.engine.digestCallCount == 1)
        let notes = try await harness.notes(meeting.id)
        #expect(!notes.digestEditOwed)
        #expect(try #require(notes.memoryDigest).contains("80% coverage"))
    }
}

@MainActor
@Suite struct DigestEngineSettingsModelTests {
    private func makeModel() async throws -> (EngineSettingsModel, EngineRegistry, SettingsStore) {
        let database = try makeDatabase()
        let registry = try EngineRegistry(
            asr: [],
            summarization: [
                MockSummarizationEngine(id: "vexatron-notes"),
                MockSummarizationEngine(id: "quoll-digest"),
            ])
        let settings = SettingsStore(database: database)
        try await settings.set(EngineResolver.summarizationSettingsKey, to: "vexatron-notes")
        let model = EngineSettingsModel(registry: registry, settings: settings)
        await model.load()
        return (model, registry, settings)
    }

    @Test func defaultsToSameAsNotes() async throws {
        let (model, registry, settings) = try await makeModel()
        #expect(model.selectedID(.digest) == "")
        let resolved = try await EngineResolver(registry: registry, settings: settings).resolveDigest()
        #expect(resolved.engine.id == "vexatron-notes")
    }

    @Test func aSelectionPersistsAcrossReload() async throws {
        let (model, registry, settings) = try await makeModel()
        await model.select("quoll-digest", slot: .digest)
        #expect(model.selectedDigestID == "quoll-digest")
        #expect(model.digestPrepare == .idle)
        #expect(model.selectedSummarizationID == "vexatron-notes", "notes selection untouched")

        let reloaded = EngineSettingsModel(registry: registry, settings: settings)
        await reloaded.load()
        #expect(reloaded.selectedID(.digest) == "quoll-digest")
        let resolver = EngineResolver(registry: registry, settings: settings)
        #expect(try await resolver.resolveDigest().engine.id == "quoll-digest")
        #expect(try await resolver.resolveSummarization().engine.id == "vexatron-notes")
    }

    @Test func sameAsNotesClearsTheKey() async throws {
        let (model, registry, settings) = try await makeModel()
        await model.select("quoll-digest", slot: .digest)
        await model.select("", slot: .digest)
        #expect(model.selectedDigestID == "")
        #expect(model.digestPrepare == .idle)
        #expect(try await settings.get(EngineResolver.digestSettingsKey, as: String.self) == "")
        let resolved = try await EngineResolver(registry: registry, settings: settings).resolveDigest()
        #expect(resolved.engine.id == "vexatron-notes")
    }

    /// The digest picker offers the notes picker's rows; each one is a working
    /// digest choice.
    @Test func everyNotesRowIsADigestChoice() async throws {
        let (model, registry, settings) = try await makeModel()
        #expect(model.summarizationRows.map(\.id) == registry.summarizationEngines.map(\.id))
        let resolver = EngineResolver(registry: registry, settings: settings)
        for row in model.summarizationRows {
            await model.select(row.id, slot: .digest)
            let resolved = try await resolver.resolveDigest()
            #expect(resolved.engine.id == row.id)
            #expect(!resolved.usedFallback)
        }
    }
}
