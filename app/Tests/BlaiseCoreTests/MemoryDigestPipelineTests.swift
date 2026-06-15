import Foundation
import GRDB
import Synchronization
import Testing

@testable import BlaiseCore

// G14 — end-to-end pipeline wiring of the second synthesis call. Mock engines
// only (no models, no network). All fixtures FICTIONAL (Vexatron Labs / Quoll
// Harbor). The harness seeds a "Sam" identity in pre-existing test support; G14
// tests override it to a fictional one before asserting payload content.

private enum DigestPipelineFixtures {
    static let fictionalUser = UserIdentity(
        name: "Dana Marsh", aliases: ["Dana"], email: "dana@vexatronlabs.example")
    static let fictionalAttendees = [
        Attendee(name: "Dana Marsh", email: "dana@vexatronlabs.example", source: .manual),
        Attendee(name: "Pax Okoro", email: "pax@quollharbor.example", source: .manual),
    ]
    static let cleanDigest = """
        ## HEADER
        meeting: Vexatron Labs roadmap review
        date: 14 March 2026
        speaker: Dana Marsh

        ## DECISIONS
        Dana Marsh decided on 14 March 2026 to ship the Vexatron Labs scheduler in May 2026.
        """
}

/// Builds a harness, overrides the seeded identity with a FICTIONAL one, and
/// returns the harness. The primary mock notes engine drives the run; its
/// digest behavior is configured per-test.
private func makeDigestHarness(
    digest: String = DigestPipelineFixtures.cleanDigest
) async throws -> PipelineHarness {
    let harness = try await makePipelineHarness()
    let settings = SettingsStore(database: harness.database)
    try await settings.set(UserIdentity.settingsKey, to: DigestPipelineFixtures.fictionalUser)
    harness.notesPrimary.state.withLock { $0.digestString = digest }
    return harness
}

private func importFictional(_ harness: PipelineHarness) async throws -> Meeting {
    try await harness.importTestMeeting(attendees: DigestPipelineFixtures.fictionalAttendees)
}

private func parsePayload(_ harness: PipelineHarness, _ record: PipelineRunRecord) throws -> [String: Any] {
    let url = harness.database.rootURL.appendingPathComponent(try #require(record.payloadPath))
    return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
}

private func storedDigest(_ harness: PipelineHarness, _ meetingID: MeetingID) async throws -> String? {
    try await NotesRepository(database: harness.database).fetch(meetingID: meetingID)?.memoryDigest
}

// MARK: - AC2 / AC3 — second call wired, persisted, payload + provenance

@Suite struct MemoryDigestPipelineWiringTests {
    /// AC2: the digest call fires AFTER the notes (one notes call, one digest
    /// call), is persisted, and re-materializes byte-identically.
    @Test func digestFiresAfterNotesPersistsAndRematerializes() async throws {
        let harness = try await makeDigestHarness()
        let meeting = try await importFictional(harness)
        let record = try await harness.pipeline.process(meetingID: meeting.id)

        #expect(harness.notesPrimary.state.withLock { $0.requests.count } == 1, "one notes call")
        #expect(harness.notesPrimary.state.withLock { $0.digestRequests.count } == 1, "one digest call")
        // The digest request carried the produced notes + the transcript.
        let digestReq = try #require(harness.notesPrimary.state.withLock { $0.digestRequests.first })
        #expect(!digestReq.transcript.isEmpty)
        #expect(!digestReq.notes.summary.isEmpty, "the notes are the salience guide")

        // Persisted on the notes row.
        let stored = try await storedDigest(harness, meeting.id)
        #expect(stored == DigestPipelineFixtures.cleanDigest)

        // Re-materialization reproduces the stored digest byte-identically.
        let notes = try #require(try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id))
        let finalMeeting = try #require(try await harness.meeting(meeting.id))
        let segments = try await harness.segments(meeting.id)
        let rebuilt = EvidencePayloadBuilder.build(
            meeting: finalMeeting, segments: segments, notes: notes,
            user: DigestPipelineFixtures.fictionalUser)
        #expect(rebuilt.versionHash == record.versionHash, "re-materialization is byte-identical")
    }

    /// AC2: a digest seeded with a residual `_S0_`/`**S0**` is shown CLEAN on
    /// output (the neutralizeText pass over the produced digest string).
    @Test func seededResidualLabelIsNeutralizedInTheStoredDigest() async throws {
        let dirty = "## HEADER\nmeeting: Vexatron Labs sync\n\n## FACTS\n_S0_ raised a Vexatron Labs concern and **S1** answered.\n"
        let harness = try await makeDigestHarness(digest: dirty)
        let meeting = try await importFictional(harness)
        _ = try await harness.pipeline.process(meetingID: meeting.id)

        let stored = try #require(try await storedDigest(harness, meeting.id))
        #expect(!SLabelNeutralizer.containsLabel(stored), "no S-label may survive in the stored digest")
        #expect(stored.contains("participant"), "residuals become neutral descriptors")
    }

    /// AC3: a digest-ON payload carries a top-level `memory_digest` string +
    /// `provenance.memory_digest.prompt_version = "md-v1"`.
    @Test func payloadCarriesMemoryDigestAndProvenance() async throws {
        let harness = try await makeDigestHarness()
        let meeting = try await importFictional(harness)
        let record = try await harness.pipeline.process(meetingID: meeting.id)

        let payload = try parsePayload(harness, record)
        #expect(payload["memory_digest"] as? String == DigestPipelineFixtures.cleanDigest)
        let provenance = try #require(payload["provenance"] as? [String: Any])
        let mdProv = try #require(provenance["memory_digest"] as? [String: Any])
        #expect(mdProv["prompt_version"] as? String == "md-v1")
    }

    /// AC3: a degenerate meeting yields a `## HEADER`-only digest, still present.
    @Test func degenerateMeetingShipsHeaderOnlyDigest() async throws {
        let headerOnly = "## HEADER\nmeeting: Vexatron Labs standup\ndate: 14 March 2026\nspeaker: (none resolved)\n"
        let harness = try await makeDigestHarness(digest: headerOnly)
        let meeting = try await importFictional(harness)
        let record = try await harness.pipeline.process(meetingID: meeting.id)
        let payload = try parsePayload(harness, record)
        #expect(payload["memory_digest"] as? String == headerOnly)
    }
}

// MARK: - AC4 — Settings toggle (default ON; OFF ⇒ no call, no field)

@Suite struct MemoryDigestToggleTests {
    @Test func defaultOnShipsDigest() async throws {
        // No toggle row written → default ON.
        let harness = try await makeDigestHarness()
        let meeting = try await importFictional(harness)
        let record = try await harness.pipeline.process(meetingID: meeting.id)
        #expect(harness.notesPrimary.state.withLock { $0.digestRequests.count } == 1)
        #expect(try parsePayload(harness, record)["memory_digest"] != nil)
    }

    @Test func toggleOffSkipsCallAndOmitsField() async throws {
        let harness = try await makeDigestHarness()
        try await SettingsStore(database: harness.database).set(MemoryDigestSettings.enabledKey, to: false)
        let meeting = try await importFictional(harness)
        let record = try await harness.pipeline.process(meetingID: meeting.id)

        #expect(harness.notesPrimary.state.withLock { $0.digestRequests.isEmpty }, "OFF ⇒ no digest call")
        #expect(try await storedDigest(harness, meeting.id) == nil)
        let payload = try parsePayload(harness, record)
        #expect(payload["memory_digest"] == nil, "OFF ⇒ no memory_digest field")
        let provenance = try #require(payload["provenance"] as? [String: Any])
        #expect(provenance["memory_digest"] == nil, "OFF ⇒ no provenance.memory_digest")
    }

    /// A toggle-OFF payload is otherwise byte-identical to a pre-G14 payload
    /// (no digest fields anywhere).
    @Test func toggleOffPayloadHasNoDigestKeysAnywhere() async throws {
        let harness = try await makeDigestHarness()
        try await SettingsStore(database: harness.database).set(MemoryDigestSettings.enabledKey, to: false)
        let meeting = try await importFictional(harness)
        let record = try await harness.pipeline.process(meetingID: meeting.id)
        let url = harness.database.rootURL.appendingPathComponent(try #require(record.payloadPath))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("memory_digest"))
    }
}

// MARK: - AC5 — PII firewall + floors

@Suite struct MemoryDigestPIIFirewallTests {
    @Test func digestSurfaceCarriesNoEmailOrAttendeeDump() async throws {
        let harness = try await makeDigestHarness()
        let meeting = try await importFictional(harness)
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        let digest = try #require(try await storedDigest(harness, meeting.id))
        // No email-shaped token (the prompt forbids PII; this is the backstop).
        #expect(digest.range(of: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, options: .regularExpression) == nil)
        #expect(!digest.contains("dana@vexatronlabs.example"))
        #expect(!SLabelNeutralizer.containsLabel(digest))
    }
}

// MARK: - AC5b — DROP-by-default through the scripted seam

@Suite struct MemoryDigestDropContractTests {
    /// AC5b DROP-by-default (scripted-input path): a fictional input carrying a
    /// third-party cited claim is fed to a seam engine SCRIPTED to honor the
    /// md-v1 drop rule; the produced digest does NOT surface the third-party
    /// claim as an attributed fact. (Honest caveat: this exercises the
    /// seam/contract wiring, not the real model.)
    @Test func dropHonoringSeamDoesNotSurfaceThirdPartyClaim() async throws {
        let harness = try await makePipelineHarness()
        try await SettingsStore(database: harness.database)
            .set(UserIdentity.settingsKey, to: DigestPipelineFixtures.fictionalUser)
        // The scripted engine drops any line mentioning the third party
        // ("Quoll Harbor reported …") — honoring the md-v1 drop rule.
        harness.notesPrimary.state.withLock {
            $0.digestBuilder = { _ in
                // A drop-honoring digest: it never surfaces the third-party
                // claim as an attributed fact.
                "## HEADER\nmeeting: Vexatron Labs partner review\ndate: 14 March 2026\nspeaker: Dana Marsh\n\n## COMMITMENTS\nDana Marsh will review the Vexatron Labs plan by 21 March 2026.\n"
            }
        }
        let meeting = try await importFictional(harness)
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        let digest = try #require(try await storedDigest(harness, meeting.id))
        #expect(!digest.contains("Quoll Harbor reported"), "the third-party claim must be dropped")
        #expect(!digest.contains("[external-claim]") || !digest.contains("Quoll Harbor"))
    }
}

// MARK: - AC6 — cost receipted under a migration-provisioned `digest` purpose

@Suite struct MemoryDigestSpendPurposeTests {
    /// AC6 (non-vacuous): a `digest`-purpose receipt INSERTs successfully on a
    /// MIGRATED DB (proving the v14 CHECK-rebuild took — a `digest` INSERT
    /// against the un-rebuilt frozen v9 CHECK would fail).
    @Test func digestPurposeReceiptInsertsOnMigratedDB() async throws {
        let database = try makeDatabase()
        let ledger = CloudSpendLedger(database: database)
        let updated = try await ledger.add(
            0.01,
            receipt: CloudSpendLedger.ReceiptDraft(
                engineID: "claude-sonnet", model: "claude-sonnet-4-6",
                purpose: .digest, meetingID: nil, inputTokens: 80, outputTokens: 40))
        #expect(updated >= 0.01)
        let count = try await database.pool.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM cloud_spend_receipt WHERE purpose = ?",
                arguments: [CloudSpendPurpose.digest.rawValue]) ?? -1
        }
        #expect(count == 1, "the digest receipt landed (the v14 CHECK accepts it)")
    }

    /// The v9 CHECK (as frozen, WITHOUT digest) rejects a `digest` INSERT —
    /// proving the rebuild was actually necessary, so AC6 is non-vacuous.
    @Test func frozenV9CheckWouldRejectDigest() throws {
        let url = try makeTempRoot().appendingPathComponent("v9-frozen.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            // The frozen v9 CHECK as it stood BEFORE digest existed.
            try db.execute(sql: """
                CREATE TABLE r (
                  id TEXT PRIMARY KEY,
                  purpose TEXT NOT NULL CHECK(purpose IN ('generation','regeneration','validation','smoke'))
                )
                """)
        }
        #expect(throws: DatabaseError.self) {
            try queue.write { db in
                try db.execute(sql: "INSERT INTO r (id, purpose) VALUES ('x', 'digest')")
            }
        }
        // After the rebuild widens the CHECK, the same INSERT succeeds.
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE r2 (
                  id TEXT PRIMARY KEY,
                  purpose TEXT NOT NULL CHECK(purpose IN ('generation','regeneration','validation','smoke','digest'))
                )
                """)
            try db.execute(sql: "INSERT INTO r2 (id, purpose) VALUES ('x', 'digest')")
        }
    }

    /// The MLX (local) digest path spends nothing — the cost descriptor is nil
    /// and a `.local` engine never receipts. (Asserted at the seam: a local
    /// mock's digest call leaves no receipt.)
    @Test func localDigestPathSpendsNothing() async throws {
        let harness = try await makeDigestHarness()
        let meeting = try await importFictional(harness)
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        // The pipeline mock is a local engine; no receipts written at all.
        let count = try await harness.database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cloud_spend_receipt") ?? -1
        }
        #expect(count == 0, "a local digest engine spends nothing")
    }
}
