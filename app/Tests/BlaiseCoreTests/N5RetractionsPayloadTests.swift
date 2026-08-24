import CryptoKit
import Foundation
import GRDB
import Synchronization
import Testing

@testable import BlaiseCore

// N5 — the retractions payload segment: one record per claim the user's
// corrections erased from the notes, derived at every mint from the shipped
// withdrawn-claim predicate. Every fixture is FICTIONAL (Vexatron Labs / Quoll
// Harbor).
//
// SC-12 (the derivation adds no log surface — the payload is the observable) is
// an audit review assertion over the diff by design, and has no test here.

// MARK: - Fixtures

/// Claims absent from every notes fixture below, so a row quoting one is
/// withdrawn. No proper nouns in the first, so no name pass can move its bytes.
private let pilotClaim = "the pilot slipped to September"
private let budgetClaim = "the field kit budget doubled"

private let baseTime = msDate(1_770_000_000)
private func laterTime(_ offset: Double) -> Date { msDate(1_770_000_000 + offset) }

/// Fixed ids so the builder's id-sort is assertable. Crockford base32.
private enum RowID {
    static let present = "01ARZ3NDEKTSV4RRFFQ69G5FA1"
    static let erasedApplied = "01ARZ3NDEKTSV4RRFFQ69G5FA2"
    static let erasedPending = "01ARZ3NDEKTSV4RRFFQ69G5FA3"
    static let annotation = "01ARZ3NDEKTSV4RRFFQ69G5FA4"
    static let erasedThird = "01ARZ3NDEKTSV4RRFFQ69G5FA6"
}

private let fixtureMeetingID: MeetingID = "01ARZ3NDEKTSV4RRFFQ69G5FAV"

private func retractionStructured(
    title: String? = "Pilot sync",
    summary: String = "The Vexatron Labs pilot is on schedule.",
    detailedNotes: String = "The team reviewed the plan.\n\nThe budget is unchanged.",
    decisions: [String] = ["Keep the August date"],
    actionItems: [ActionItem] = [ActionItem(owner: "Dana Marsh", text: "confirm the ship date")],
    userActionItems: [ActionItem] = []
) -> NotesStructured {
    NotesStructured(
        title: title, summary: summary, detailedNotes: detailedNotes,
        decisions: decisions, actionItems: actionItems, userActionItems: userActionItems)
}

private func retractionMeeting(id: MeetingID = fixtureMeetingID) -> Meeting {
    makeMeeting(id: id, title: "Vexatron Labs pilot sync", status: .ready)
}

private func retractionNotes(
    meetingID: MeetingID = fixtureMeetingID,
    structured: NotesStructured = retractionStructured(),
    digest: String? = nil
) -> MeetingNotes {
    MeetingNotes(
        meetingID: meetingID, markdown: "# Pilot sync\n", structured: structured,
        language: "en", generatedAt: baseTime,
        provenance: NotesProvenance(
            engine: "fixture", model: "fixture", pipelineVersion: "fixture",
            runtime: "fixture", rendererVersion: NotesRenderer.version),
        memoryDigest: digest)
}

private func correctionRow(
    _ id: String, _ quote: String,
    kind: MeetingCorrection.Kind = .understanding,
    status: MeetingCorrection.Status = .applied,
    createdAt: Date = baseTime,
    meetingID: MeetingID = fixtureMeetingID
) -> MeetingCorrection {
    MeetingCorrection(
        id: id, meetingID: meetingID, kind: kind, section: .summary,
        quotedText: quote, userText: "That was never said.", status: status,
        createdAt: createdAt)
}

/// Writes a row straight to the store: a payload-CONTENT test wants the row
/// present without the editor scheduling an activation around it.
@discardableResult
private func plantCorrection(
    _ database: BlaiseDatabase, meetingID: MeetingID, id: String = ULID.generate(),
    quote: String, kind: MeetingCorrection.Kind = .understanding,
    status: MeetingCorrection.Status = .applied, createdAt: Date = baseTime
) async throws -> MeetingCorrection {
    let row = MeetingCorrection(
        id: id, meetingID: meetingID, kind: kind, section: .summary,
        quotedText: quote, userText: "That was never said.", status: status,
        createdAt: createdAt)
    try await database.pool.write { db in try MeetingCorrectionStore.insert(db, row) }
    return row
}

private func decoded(_ payload: EvidencePayloadBuilder.Payload) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: payload.bytes) as? [String: Any])
}

private func records(in object: [String: Any]) throws -> [[String: Any]] {
    try #require(object["retractions"] as? [[String: Any]])
}

private func recordIDs(_ object: [String: Any]) throws -> [String] {
    try records(in: object).compactMap { $0["id"] as? String }
}

/// The whole source of a file under `app/`, for the structural assertions.
private func appSource(_ relativePath: String) throws -> String {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0 ..< 4 { url.deleteLastPathComponent() }  // file → BlaiseCoreTests → Tests → app → repo
    url.appendPathComponent("app/" + relativePath)
    return try String(contentsOf: url, encoding: .utf8)
}

// MARK: - SC-1, SC-3, SC-8, SC-17 — the derivation, at the builder

@Suite struct N5RetractionDerivationTests {

    @Test("SC-1: exactly the erased understanding rows derive records, carrying the row's own fields")
    func derivationCorrectness() throws {
        let meeting = retractionMeeting()
        let notes = retractionNotes()
        let present = correctionRow(RowID.present, "The Vexatron Labs pilot is on schedule.")
        let erasedApplied = correctionRow(
            RowID.erasedApplied, pilotClaim, createdAt: laterTime(100))
        // The N2 §7 state: pending, but an earlier pass already erased the quote.
        let erasedPending = correctionRow(
            RowID.erasedPending, budgetClaim, status: .pending, createdAt: laterTime(200))
        // An annotation quoting absent text derives nothing: annotations never withdraw.
        let annotation = correctionRow(
            RowID.annotation, "a margin note's own absent quote", kind: .annotation)

        let payload = EvidencePayloadBuilder.build(
            meeting: meeting, segments: [], notes: notes, user: .shippedDefault,
            corrections: [present, erasedApplied, erasedPending, annotation])
        let set = try records(in: try decoded(payload))

        #expect(set.count == 2)
        #expect(set.map { $0["id"] as? String } == [erasedApplied.id, erasedPending.id])
        #expect(set.allSatisfy { $0["kind"] as? String == "removal" })
        #expect(set[0]["claim_text"] as? String == pilotClaim)
        #expect(set[1]["claim_text"] as? String == budgetClaim)
        #expect(
            set[0]["retracted_at_ms"] as? Int64
                == EvidencePayloadBuilder.milliseconds(date: erasedApplied.createdAt))
        #expect(
            set[1]["retracted_at_ms"] as? Int64
                == EvidencePayloadBuilder.milliseconds(date: erasedPending.createdAt))
        // No record emits a replacement: removals-only in this version.
        #expect(set.allSatisfy { $0["replacement_text"] == nil })
    }

    @Test("SC-3: the key rides an EMPTY set too, and only the recovery axis can omit it")
    func alwaysEmitted() throws {
        let meeting = retractionMeeting()
        let notes = retractionNotes()

        // No rows at all.
        let noRows = try decoded(
            EvidencePayloadBuilder.build(
                meeting: meeting, segments: [], notes: notes, user: .shippedDefault,
                corrections: []))
        #expect(try records(in: noRows).isEmpty)
        #expect(noRows["retractions"] != nil, "the key is PRESENT, not omitted")

        // Rows that are all still present in the notes.
        let allPresent = try decoded(
            EvidencePayloadBuilder.build(
                meeting: meeting, segments: [], notes: notes, user: .shippedDefault,
                corrections: [
                    correctionRow(RowID.present, "The Vexatron Labs pilot is on schedule."),
                    correctionRow(RowID.erasedApplied, "Keep the August date"),
                ]))
        #expect(try records(in: allPresent).isEmpty)
        #expect(allPresent["retractions"] != nil)

        // The pre-N5 encoding is the ONLY path to the old shape.
        let preN5 = EvidencePayloadBuilder.build(
            meeting: meeting, segments: [], notes: notes, user: .shippedDefault,
            corrections: [correctionRow(RowID.erasedApplied, pilotClaim)],
            retractionsKey: .preN5Absent)
        #expect(try decoded(preN5)["retractions"] == nil)
        #expect(!String(decoding: preN5.bytes, as: UTF8.self).contains("retractions"))
    }

    /// SHA-256 of the payload the last PRE-retractions revision (`cb9ff18`)
    /// built from `goldenNotes()` + `retractionMeeting()` + no segments +
    /// `.shippedDefault`. A literal on purpose: deriving the pre-N5
    /// expectation from the current builder would only prove the builder
    /// agrees with itself. Re-mint by building that same fixture at that
    /// revision.
    private static let preN5GoldenHash =
        "12f3733f90756098c1143d423785a434d9e39e84e56edb6b0da310c056ecc35a"

    /// The golden fixture's notes. Every input is a LITERAL — the renderer
    /// version included — so the same payload is constructible at any
    /// revision and the oracle measures the wire encoding alone.
    private func goldenNotes() -> MeetingNotes {
        MeetingNotes(
            meetingID: fixtureMeetingID, markdown: "# Pilot sync\n",
            structured: retractionStructured(), language: "en", generatedAt: baseTime,
            provenance: NotesProvenance(
                engine: "fixture", model: "fixture", pipelineVersion: "fixture",
                runtime: "fixture", rendererVersion: "2"),
            memoryDigest: nil)
    }

    @Test("SC-3: the pre-N5 encoding reproduces the pre-retractions revision's exact bytes")
    func preN5EncodingMatchesTheBaseGolden() throws {
        let rows = [
            correctionRow(RowID.erasedApplied, pilotClaim, createdAt: laterTime(100)),
            correctionRow(
                RowID.erasedPending, budgetClaim, status: .pending, createdAt: laterTime(200)),
        ]
        let preN5 = EvidencePayloadBuilder.build(
            meeting: retractionMeeting(), segments: [], notes: goldenNotes(),
            user: .shippedDefault, corrections: rows, retractionsKey: .preN5Absent)
        #expect(preN5.versionHash == Self.preN5GoldenHash)

        // The oracle discriminates: withdrawn rows are present, so the CURRENT
        // encoding of the same durable state cannot reproduce those bytes.
        let current = EvidencePayloadBuilder.build(
            meeting: retractionMeeting(), segments: [], notes: goldenNotes(),
            user: .shippedDefault, corrections: rows)
        #expect(current.versionHash != Self.preN5GoldenHash)
    }

    @Test("SC-8: the key sorts canonically and identical state gives identical bytes, row order aside")
    func canonicalStabilityUnderPermutation() throws {
        let meeting = retractionMeeting()
        let notes = retractionNotes()
        let rows = [
            correctionRow(RowID.erasedPending, budgetClaim, createdAt: laterTime(200)),
            correctionRow(RowID.erasedApplied, pilotClaim, createdAt: laterTime(100)),
            correctionRow(RowID.erasedThird, "another erased claim entirely"),
        ]

        let forward = EvidencePayloadBuilder.build(
            meeting: meeting, segments: [], notes: notes, user: .shippedDefault,
            corrections: rows)
        let reversed = EvidencePayloadBuilder.build(
            meeting: meeting, segments: [], notes: notes, user: .shippedDefault,
            corrections: rows.reversed())

        #expect(forward.bytes == reversed.bytes, "the builder's id-sort absorbs the permutation")
        #expect(forward.versionHash == reversed.versionHash)
        #expect(try recordIDs(try decoded(forward)) == [RowID.erasedApplied, RowID.erasedPending, RowID.erasedThird].sorted())

        // Canonical placement: `retractions` sits between `provenance` and `source`.
        let text = String(decoding: forward.bytes, as: UTF8.self)
        let provenance = try #require(text.range(of: "\"provenance\":"))
        let retractions = try #require(text.range(of: "\"retractions\":"))
        let source = try #require(text.range(of: "\"source\":"))
        #expect(provenance.lowerBound < retractions.lowerBound)
        #expect(retractions.lowerBound < source.lowerBound)
    }

    @Test("SC-17: the predicate's three N5-direction blind spots, each chosen and pinned")
    func disclosedBlindSpots() throws {
        let meeting = retractionMeeting()
        let row = correctionRow(RowID.erasedApplied, pilotClaim)

        // (a) A PARAPHRASE restoration does NOT retire the record: "restored"
        // is the folding predicate's own meaning, and a reworded assertion is
        // fold-inequivalent. The user's recourse is deleting the correction.
        let paraphrased = retractionNotes(
            structured: retractionStructured(
                summary: "September is now the pilot's start month."))
        #expect(
            try recordIDs(
                try decoded(
                    EvidencePayloadBuilder.build(
                        meeting: meeting, segments: [], notes: paraphrased,
                        user: .shippedDefault, corrections: [row]))) == [row.id])
        // The recourse, asserted: with the correction gone, so is the record.
        #expect(
            try records(
                in: try decoded(
                    EvidencePayloadBuilder.build(
                        meeting: meeting, segments: [], notes: paraphrased,
                        user: .shippedDefault, corrections: []))).isEmpty)

        // (b) Contained-but-DENIED phrasing counts the quote PRESENT, so no
        // record is derived for a claim the notes go on to deny.
        let denied = retractionNotes(
            structured: retractionStructured(
                summary: "The earlier draft said \(pilotClaim), but that was wrong."))
        #expect(
            try records(
                in: try decoded(
                    EvidencePayloadBuilder.build(
                        meeting: meeting, segments: [], notes: denied,
                        user: .shippedDefault, corrections: [row]))).isEmpty)

        // (c) A claim whose words survive only ACROSS a haystack block boundary
        // counts ABSENT — a PHANTOM record for text still effectively present.
        // The cost is visible and accepted: the alternative is a second predicate.
        let split = retractionNotes(
            structured: retractionStructured(
                summary: "the pilot slipped", detailedNotes: "to September"))
        #expect(
            try recordIDs(
                try decoded(
                    EvidencePayloadBuilder.build(
                        meeting: meeting, segments: [], notes: split,
                        user: .shippedDefault, corrections: [row]))) == [row.id])
    }
}

// MARK: - SC-13 — one containment core

@Suite struct N5PredicateUnityTests {

    @Test("SC-13: the rows and the claims variant share ONE private containment core")
    func predicateUnity() throws {
        let source = try appSource("Sources/BlaiseCore/MeetingCorrections.swift")
        // The core is private and named once; both public entry points reach it.
        #expect(source.contains("private static func isWithdrawn("))
        let rowsBody = try #require(functionBody("public static func withdrawnRows(", in: source))
        let claimsBody = try #require(
            functionBody("public static func withdrawnClaims(", in: source))
        #expect(rowsBody.contains("isWithdrawn("))
        #expect(claimsBody.contains("withdrawnRows("))
        // Neither entry point may re-implement the containment itself.
        #expect(!claimsBody.contains("currentHaystack.contains("))
        #expect(!rowsBody.contains("currentHaystack.contains("))

        // …and behaviourally, over a fixture mixing all four row classes:
        // withdrawn, still-present, annotation, and an empty-fold quote. Both
        // entry points are asserted against the SAME independently-stated
        // projection — mutual equality alone would only restate the
        // delegation.
        let haystack = CorrectionAnchoring.foldedHaystack(
            of: retractionStructured(), meetingTitle: "Vexatron Labs pilot sync")
        let rows = [
            correctionRow(RowID.present, "The Vexatron Labs pilot is on schedule."),
            correctionRow(RowID.erasedApplied, pilotClaim),
            correctionRow(RowID.erasedPending, budgetClaim, status: .pending),
            correctionRow(RowID.annotation, budgetClaim, kind: .annotation),
            correctionRow("01ARZ3NDEKTSV4RRFFQ69G5FA5", "   "),
        ]
        let withdrawnRows = CorrectionAnchoring.withdrawnRows(
            corrections: rows, currentHaystack: haystack)
        #expect(withdrawnRows.map(\.id) == [RowID.erasedApplied, RowID.erasedPending])
        #expect(withdrawnRows.map(\.quotedText) == [pilotClaim, budgetClaim])
        #expect(
            CorrectionAnchoring.withdrawnClaims(corrections: rows, currentHaystack: haystack)
                == [pilotClaim, budgetClaim])
    }

    private func functionBody(_ signature: String, in source: String) -> String? {
        guard let start = source.range(of: signature) else { return nil }
        let tail = source[start.lowerBound...]
        guard let end = tail.range(of: "\n    }\n") else { return nil }
        return String(tail[..<end.upperBound])
    }
}

// MARK: - SC-7 — the boundary invariant

@Suite struct N5MintSeamBoundaryTests {

    @Test("SC-7: the ONLY builders in the app are the six forward mints, recovery, and the harness")
    func buildCallersArePinned() throws {
        let expected = [
            "Sources/BlaiseCore/ProcessingPipeline.swift": 6,
            "Sources/BlaiseCore/HandoffWorker.swift": 1,
            "Sources/CrashRunner/main.swift": 1,
        ]
        var found: [String: Int] = [:]
        for (path, _) in expected {
            let source = try appSource(path)
            found[path] = source.components(separatedBy: "EvidencePayloadBuilder.build(").count - 1
        }
        #expect(found == expected, "a NEW mint seam must be a deliberate change, not a surprise")

        // And no OTHER source file builds a payload at all.
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { root.deleteLastPathComponent() }
        let sources = root.appendingPathComponent("app/Sources")
        var others: [String] = []
        let walker = try #require(
            FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in walker where url.pathExtension == "swift" {
            let relative = "Sources/" + url.path.components(separatedBy: "app/Sources/")[1]
            guard expected[relative] == nil else { continue }
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if text.contains("EvidencePayloadBuilder.build(") { others.append(relative) }
        }
        #expect(others.isEmpty, "unexpected build sites: \(others)")
    }

    @Test("SC-7: a transport retry re-sends the MINTED bytes — it never rebuilds")
    func transportRetryResendsMintedBytes() async throws {
        let database = try makeDatabase()
        let item = try await seedDeliverable(database)
        let minted = try Data(
            contentsOf: database.rootURL.appendingPathComponent(item.payloadPath))
        // The mint carried no correction rows, so the file's set is empty.
        // Planting a WITHDRAWN row makes durable state disagree with the file:
        // any rebuild would carry that record, which is what separates
        // "re-sent the stored bytes" from "rebuilt bytes that happen to match".
        let planted = try await plantCorrection(
            database, meetingID: item.meetingID, quote: pilotClaim)
        #expect(String(decoding: minted, as: UTF8.self).contains("\"retractions\":[]"))

        // Exit 65 = transfer trouble; the local bytes already self-checked good.
        let transport = MockTransport(script: [
            HandoffTransportOutcome(exitStatus: 65, stderrTail: "", timedOut: false)
        ])
        let worker = makeWorker(database, transport: transport, clock: VirtualClock())
        await worker.kick()
        await worker.waitUntilSettled()

        // The row MOVES between the failed attempt and the retry, the payload
        // file staying intact: a retry never rebuilds, so the second attempt
        // must carry the same bytes the first one did.
        try await database.pool.write { db in
            try MeetingCorrectionStore.update(
                db, id: planted.id, quotedText: budgetClaim, occurrence: 0,
                userText: "That was never said either.", status: .pending,
                createdAt: laterTime(500))
        }

        await worker.kick()
        await worker.waitUntilSettled()
        await worker.stop()

        #expect(transport.callCount == 2, "one failed attempt, one retry")
        #expect(transport.calls.allSatisfy { $0.payload == minted })
        #expect(
            transport.calls.allSatisfy {
                let text = String(decoding: $0.payload, as: UTF8.self)
                return !text.contains(pilotClaim) && !text.contains(budgetClaim)
            }, "neither the planted row nor its revision reached the wire")
        #expect(try await HandoffRepository(database: database).allItems().first?.state == .delivered)
    }
}

// MARK: - SC-6 — re-materialization across both generations

@Suite struct N5RematerializeAxisTests {

    /// A queued meeting whose durable state is seeded by hand, so the mint's
    /// encoding is the test's choice rather than the pipeline's.
    private struct Seeded {
        let database: BlaiseDatabase
        let meeting: Meeting
        let notes: MeetingNotes
        let segments: [TranscriptSegment]
    }

    private func seed(digest: String? = nil) async throws -> Seeded {
        let database = try makeDatabase()
        try await seedHandoffConfig(database)
        let meeting = makeMeeting(
            id: ULID.generate(), title: "Vexatron Labs pilot sync", status: .ready,
            attendees: [Attendee(name: "Dana Marsh", email: "dana@vexatronlabs.example", source: .manual)])
        try await MeetingRepository(database: database).create(meeting)
        let segments = try await database.persistTranscript(
            meetingID: meeting.id,
            segments: [
                TranscriptSegment(
                    meetingID: meeting.id, ord: 0, startSeconds: 0, endSeconds: 1.5,
                    speakerLabel: "S0", speakerName: "Dana Marsh", text: "The pilot is on schedule.")
            ],
            asrProvenance: ASRProvenance(
                engine: "stub", model: "stub", runtime: "stub", engineVersion: "1",
                transcribedAt: msDate()),
            dominantLanguage: "en", updatedAt: msDate())
        let notes = retractionNotes(meetingID: meeting.id, digest: digest)
        let final = try #require(try await MeetingRepository(database: database).fetch(meeting.id))
        return Seeded(database: database, meeting: final, notes: notes, segments: segments)
    }

    /// Queues `payload` as the meeting's delivery, then destroys the file so the
    /// worker's pre-stream self-check must re-materialize.
    private func queueThenLoseFile(
        _ seeded: Seeded, _ payload: EvidencePayloadBuilder.Payload
    ) async throws -> HandoffItem {
        let relative = seeded.database.paths.relativeHandoffPayloadPath(
            meetingID: seeded.meeting.id, versionHash: payload.versionHash)
        try ImmutablePayloadWriter.write(
            payload.bytes, to: seeded.database.rootURL.appendingPathComponent(relative))
        let item = try await seeded.database.finalizeMeetingProcessing(
            meetingID: seeded.meeting.id, versionHash: payload.versionHash,
            payloadPath: relative, notes: seeded.notes)
        try FileManager.default.removeItem(
            at: seeded.database.rootURL.appendingPathComponent(item.payloadPath))
        return item
    }

    private func drain(_ seeded: Seeded) async -> MockTransport {
        let transport = MockTransport()
        let worker = makeWorker(seeded.database, transport: transport)
        await worker.kick()
        await worker.waitUntilSettled()
        return transport
    }

    private func state(_ seeded: Seeded) async throws -> HandoffState? {
        try await HandoffRepository(database: seeded.database).allItems().first?.state
    }

    @Test("SC-6(a): a PRE-N5 payload minted while withdrawn rows existed recovers via the axis")
    func preN5PayloadWithWithdrawnRowsRecovers() async throws {
        let seeded = try await seed()
        let row = try await plantCorrection(
            seeded.database, meetingID: seeded.meeting.id, quote: pilotClaim)
        let preN5 = EvidencePayloadBuilder.build(
            meeting: seeded.meeting, segments: seeded.segments, notes: seeded.notes,
            user: .shippedDefault, corrections: [row], retractionsKey: .preN5Absent)
        // Precondition: the CURRENT encoding cannot reproduce these bytes, so
        // only the axis can — the fixture genuinely exercises it.
        let current = EvidencePayloadBuilder.build(
            meeting: seeded.meeting, segments: seeded.segments, notes: seeded.notes,
            user: .shippedDefault, corrections: [row])
        #expect(current.versionHash != preN5.versionHash)

        let item = try await queueThenLoseFile(seeded, preN5)
        let transport = await drain(seeded)

        #expect(try await state(seeded) == .delivered)
        let restored = try Data(
            contentsOf: seeded.database.rootURL.appendingPathComponent(item.payloadPath))
        #expect(EvidencePayloadBuilder.sha256Hex(restored) == item.versionHash)
        #expect(!String(decoding: restored, as: UTF8.self).contains("retractions"))
        #expect(transport.calls.first?.payload == restored)
    }

    @Test("SC-6(b): a post-N5 payload with a non-empty set recovers from durable state alone")
    func postN5PayloadRecovers() async throws {
        let seeded = try await seed()
        let row = try await plantCorrection(
            seeded.database, meetingID: seeded.meeting.id, quote: pilotClaim)
        let payload = EvidencePayloadBuilder.build(
            meeting: seeded.meeting, segments: seeded.segments, notes: seeded.notes,
            user: .shippedDefault, corrections: [row])
        let item = try await queueThenLoseFile(seeded, payload)

        _ = await drain(seeded)

        #expect(try await state(seeded) == .delivered)
        let restored = try Data(
            contentsOf: seeded.database.rootURL.appendingPathComponent(item.payloadPath))
        #expect(EvidencePayloadBuilder.sha256Hex(restored) == item.versionHash)
        let object = try #require(JSONSerialization.jsonObject(with: restored) as? [String: Any])
        #expect(try recordIDs(object) == [row.id])
    }

    @Test("SC-6(c): a row deleted after the mint moves durable state, so recovery QUARANTINES")
    func postMintRowDeletionQuarantines() async throws {
        let seeded = try await seed()
        let row = try await plantCorrection(
            seeded.database, meetingID: seeded.meeting.id, quote: pilotClaim)
        let payload = EvidencePayloadBuilder.build(
            meeting: seeded.meeting, segments: seeded.segments, notes: seeded.notes,
            user: .shippedDefault, corrections: [row])
        _ = try await queueThenLoseFile(seeded, payload)
        try await seeded.database.pool.write { db in
            try MeetingCorrectionStore.delete(db, id: row.id)
        }

        let transport = await drain(seeded)

        #expect(try await state(seeded) == .failed, "the disclosed state-drift class")
        #expect(transport.callCount == 0, "nothing unverified is ever sent")
    }

    @Test("SC-6(d1): pre-N5 × a non-shipped digest version × legacy key × digest pair PRESENT")
    func preN5InsideEveryOtherAxis() async throws {
        let seeded = try await seed(
            digest: "## HEADER\nmeeting: Vexatron Labs pilot sync\ndate: 2026-03-14\n")
        let row = try await plantCorrection(
            seeded.database, meetingID: seeded.meeting.id, quote: pilotClaim)
        let payload = EvidencePayloadBuilder.build(
            meeting: seeded.meeting, segments: seeded.segments, notes: seeded.notes,
            user: .shippedDefault, corrections: [row],
            userActionItemsKey: .legacy, digestPromptVersion: .mdV2,
            includeMemoryDigest: true, retractionsKey: .preN5Absent)
        #expect(DigestPromptBuilder.shippedVersion != .mdV2, "precondition: md-v2 is not shipped")
        let item = try await queueThenLoseFile(seeded, payload)

        _ = await drain(seeded)

        #expect(try await state(seeded) == .delivered)
        let restored = try Data(
            contentsOf: seeded.database.rootURL.appendingPathComponent(item.payloadPath))
        #expect(EvidencePayloadBuilder.sha256Hex(restored) == item.versionHash)
        let text = String(decoding: restored, as: UTF8.self)
        #expect(text.contains(EvidencePayloadBuilder.UserActionItemsKey.legacy.wireKey))
        #expect(text.contains("\"prompt_version\":\"md-v2\""))
        #expect(!text.contains("retractions"))
    }

    @Test("SC-6(d2): pre-N5 × legacy key × digest pair ABSENT (where the version axis is a no-op)")
    func preN5InsideTheDigestAbsentArm() async throws {
        let seeded = try await seed(
            digest: "## HEADER\nmeeting: Vexatron Labs pilot sync\ndate: 2026-03-14\n")
        let row = try await plantCorrection(
            seeded.database, meetingID: seeded.meeting.id, quote: pilotClaim)
        let payload = EvidencePayloadBuilder.build(
            meeting: seeded.meeting, segments: seeded.segments, notes: seeded.notes,
            user: .shippedDefault, corrections: [row],
            userActionItemsKey: .legacy, includeMemoryDigest: false,
            retractionsKey: .preN5Absent)
        let item = try await queueThenLoseFile(seeded, payload)

        _ = await drain(seeded)

        #expect(try await state(seeded) == .delivered)
        let restored = try Data(
            contentsOf: seeded.database.rootURL.appendingPathComponent(item.payloadPath))
        #expect(EvidencePayloadBuilder.sha256Hex(restored) == item.versionHash)
        let text = String(decoding: restored, as: UTF8.self)
        #expect(text.contains(EvidencePayloadBuilder.UserActionItemsKey.legacy.wireKey))
        #expect(!text.contains("memory_digest"))
        #expect(!text.contains("retractions"))
    }

    @Test("SC-6(e): an EMPTY post-N5 set recovers inside a non-first axis — [] never reads as omit")
    func emptySetRecoversUnderTheCurrentEncoding() async throws {
        let seeded = try await seed(
            digest: "## HEADER\nmeeting: Vexatron Labs pilot sync\ndate: 2026-03-14\n")
        let payload = EvidencePayloadBuilder.build(
            meeting: seeded.meeting, segments: seeded.segments, notes: seeded.notes,
            user: .shippedDefault, corrections: [],
            userActionItemsKey: .legacy, includeMemoryDigest: false)
        let item = try await queueThenLoseFile(seeded, payload)

        _ = await drain(seeded)

        #expect(try await state(seeded) == .delivered)
        let restored = try Data(
            contentsOf: seeded.database.rootURL.appendingPathComponent(item.payloadPath))
        #expect(EvidencePayloadBuilder.sha256Hex(restored) == item.versionHash)
        #expect(String(decoding: restored, as: UTF8.self).contains("\"retractions\":[]"))
    }

    @Test("SC-6(f): the retraction axis is the INNERMOST loop — the cross-product is structural")
    func retractionAxisIsInnermost() throws {
        let source = try appSource("Sources/BlaiseCore/HandoffWorker.swift")
        let start = try #require(source.range(of: "private func rematerialize("))
        let tail = source[start.lowerBound...]
        let end = try #require(tail.range(of: "\n    }\n"))
        let body = String(tail[..<end.upperBound])

        let axes = [
            "for digestVersion in", "for key in", "for includeDigest in", "for retractionsKey in",
        ]
        var cursor = body.startIndex
        for axis in axes {
            let hit = try #require(body.range(of: axis, range: cursor ..< body.endIndex))
            cursor = hit.upperBound
        }
        // The build call comes after the LAST axis, so every existing
        // combination is tried under both retraction encodings.
        #expect(body.range(of: "EvidencePayloadBuilder.build(", range: cursor ..< body.endIndex) != nil)
        #expect(
            body.range(of: "for ", range: cursor ..< body.endIndex) == nil,
            "no axis may sit inside the retraction loop")
    }
}

// MARK: - SC-2, SC-4, SC-5, SC-9, SC-10, SC-11, SC-14, SC-15, SC-16 — the mint sites

@Suite struct N5MintSiteTests {

    /// The seeded settle fixture plus one withdrawn understanding row.
    private func harnessWithWithdrawnRow(
        digestEnabled: Bool = true
    ) async throws -> (SettleHarness, Meeting, MeetingCorrection) {
        let harness = try await makeSettleHarness()
        if !digestEnabled {
            try await SettingsStore(database: harness.database)
                .set(MemoryDigestSettings.enabledKey, to: false)
        }
        let meeting = try await seedSettleMeeting(harness)
        let row = try await plantCorrection(
            harness.database, meetingID: meeting.id, quote: pilotClaim)
        return (harness, meeting, row)
    }

    /// The newest queued payload's own hash, for the freshness control below.
    private func latestVersionHash(
        _ harness: SettleHarness, _ id: MeetingID
    ) async throws -> String {
        try #require(
            try await harness.database.pool.read { db in
                try HandoffItem
                    .filter(Column("meeting_id") == id)
                    .order(Column("created_seq").desc)
                    .fetchOne(db)
            }).versionHash
    }

    @Test("SC-2/SC-11: the three instant name-fix mints and the settle delivery all carry the set")
    func everyInstantMintCarriesTheSet() async throws {
        let (harness, meeting, row) = try await harnessWithWithdrawnRow()
        let transcriptBefore = try await TranscriptRepository(database: harness.database)
            .segments(meetingID: meeting.id)

        // The expected record set is identical across all four ops, so the set
        // assertion ALONE passes on a predecessor's payload if a site stops
        // minting. Each op therefore also has to advance the queue and produce
        // a hash the previous op did not — each op changes title or speaker
        // content, so the bytes differ by construction.
        var previousRows = try await harness.queueRows(meeting.id)
        var previousHash: String? = nil
        func mintAdvanced(_ site: Comment, expecting expected: [String]) async throws {
            let rows = try await harness.queueRows(meeting.id)
            let hash = try await latestVersionHash(harness, meeting.id)
            #expect(rows > previousRows, site)
            #expect(hash != previousHash, site)
            #expect(
                try recordIDs(try await harness.latestPayload(meeting.id)).sorted()
                    == expected.sorted(), site)
            previousRows = rows
            previousHash = hash
        }

        _ = try await harness.pipeline.renameMeeting(
            meetingID: meeting.id, to: "Quoll Harbor field-kit review")
        try await mintAdvanced("renameMeeting", expecting: [row.id])

        _ = try await harness.pipeline.renameSpeaker(
            meetingID: meeting.id, speakerLabel: "S0", to: "Dana Quoll")
        try await mintAdvanced("renameSpeaker", expecting: [row.id])

        _ = try await harness.pipeline.correctNameInNotes(
            meetingID: meeting.id, original: "Dana Marsh", replacement: "Dana Quoll",
            allOccurrences: true)
        try await mintAdvanced("correctNameInNotes", expecting: [row.id])

        // The settle site delivers CURRENT content, so it enqueues only when
        // durable state moved. A second withdrawn row supplies that delta and
        // makes the site prove it derived the set fresh: a stale read of the
        // previous payload would carry one record, not two.
        let second = try await plantCorrection(
            harness.database, meetingID: meeting.id, quote: budgetClaim,
            createdAt: laterTime(50))
        try await setDeliveryOwed(harness, meeting.id)
        #expect(try await harness.pipeline.deliverSettled(meetingID: meeting.id) == .delivered)
        try await mintAdvanced("deliverSettled", expecting: [row.id, second.id])

        // SC-11: none of those mints touched a transcript row.
        let transcriptAfter = try await TranscriptRepository(database: harness.database)
            .segments(meetingID: meeting.id)
        #expect(transcriptAfter == transcriptBefore)
    }

    @Test("SC-5: with the digest toggle OFF the payload omits both digest keys and STILL retracts")
    func toggleDoesNotGateRetractions() async throws {
        let (harness, meeting, row) = try await harnessWithWithdrawnRow(digestEnabled: false)

        _ = try await harness.pipeline.renameMeeting(
            meetingID: meeting.id, to: "Quoll Harbor field-kit review")

        let payload = try await harness.latestPayload(meeting.id)
        #expect(payload["memory_digest"] == nil)
        let provenance = try #require(payload["provenance"] as? [String: Any])
        #expect(provenance["memory_digest"] == nil)
        #expect(try recordIDs(payload) == [row.id])
    }

    @Test("SC-9: the minted digest string is the STORED one, and no record text leaks into it")
    func digestCleanlinessOnMintedBytes() async throws {
        let (harness, meeting, row) = try await harnessWithWithdrawnRow()
        let stored = try #require(try await harness.notes(meeting.id).memoryDigest)
        // The fixture's stored digest does not itself state the retracted claim,
        // so an occurrence inside the digest would be the serialization layer
        // injecting it — which is what this screens for.
        #expect(!stored.contains(pilotClaim))

        _ = try await harness.pipeline.renameMeeting(
            meetingID: meeting.id, to: "Quoll Harbor field-kit review")
        let withRecord = try await harness.latestPayload(meeting.id)
        #expect(withRecord["memory_digest"] as? String == stored)
        #expect(try recordIDs(withRecord) == [row.id])
        // The claim text is carried by the RECORD, decoded and byte-verbatim —
        // the other half of "in the retractions field and nowhere else".
        let record = try #require(try records(in: withRecord).first)
        #expect(record["claim_text"] as? String == pilotClaim)
        #expect(!(try #require(withRecord["memory_digest"] as? String)).contains(pilotClaim))
        let withRecordProvenance = try #require(
            (withRecord["provenance"] as? [String: Any])?["memory_digest"] as? [String: Any])

        // The otherwise-identical EMPTY-set build: same digest string, same
        // digest provenance.
        try await harness.database.pool.write { db in
            try MeetingCorrectionStore.delete(db, id: row.id)
        }
        _ = try await harness.pipeline.renameMeeting(
            meetingID: meeting.id, to: "Quoll Harbor pilot review")
        let withoutRecord = try await harness.latestPayload(meeting.id)
        #expect(try records(in: withoutRecord).isEmpty)
        #expect(withoutRecord["memory_digest"] as? String == stored)
        let withoutRecordProvenance = try #require(
            (withoutRecord["provenance"] as? [String: Any])?["memory_digest"] as? [String: Any])
        #expect(
            withRecordProvenance["prompt_version"] as? String
                == withoutRecordProvenance["prompt_version"] as? String)
        #expect(
            withRecordProvenance["model"] as? String
                == withoutRecordProvenance["model"] as? String)
    }

    @Test("SC-4/SC-14/SC-16: restoration retires a record, deletion retires the last one, re-erasure brings it back")
    func retirementAndReappearance() async throws {
        let harness = try await makeSettleHarness()
        let meeting = try await seedSettleMeeting(harness)
        // Two withdrawn rows: one to retire, one that must survive the retirement.
        let restorable = try await plantCorrection(
            harness.database, meetingID: meeting.id, quote: pilotClaim)
        let surviving = try await plantCorrection(
            harness.database, meetingID: meeting.id, quote: budgetClaim,
            createdAt: laterTime(50))

        _ = try await harness.pipeline.renameMeeting(
            meetingID: meeting.id, to: "Quoll Harbor field-kit review")
        #expect(
            try recordIDs(try await harness.latestPayload(meeting.id)).sorted()
                == [restorable.id, surviving.id].sorted())

        // SC-4(a): the editor pass re-inserts the erased text — the one route
        // that can legitimately bring a claim back.
        harness.engine.scriptNotes([[
            .replace(
                field: .summary, find: "Ships in May.",
                replace: "Ships in May. Also, \(pilotClaim).", instruction: 1)
        ]])
        await harness.pipeline.settleViewAttached(meeting.id)
        _ = try await harness.pipeline.addCorrection(
            meetingID: meeting.id, kind: .understanding, section: .summary,
            quotedText: "Ships in May.", occurrence: 0,
            userText: "Add back that \(pilotClaim)")
        await harness.pipeline.settleViewDetached(meeting.id)

        let afterRestore = try await harness.latestPayload(meeting.id)
        #expect(!(try recordIDs(afterRestore).contains(restorable.id)), "the record retired")
        #expect(try recordIDs(afterRestore).contains(surviving.id), "the other record survives")

        // SC-16: a NEWER correction re-erases the same claim — the ORIGINAL
        // row's record returns, id and timestamp unchanged.
        harness.engine.scriptNotes([[
            .replace(
                field: .summary, find: "Ships in May. Also, \(pilotClaim).",
                replace: "Ships in May.", instruction: 1)
        ]])
        await harness.pipeline.settleViewAttached(meeting.id)
        _ = try await harness.pipeline.addCorrection(
            meetingID: meeting.id, kind: .understanding, section: .summary,
            quotedText: pilotClaim, occurrence: 0, userText: "That never happened")
        await harness.pipeline.settleViewDetached(meeting.id)

        let reErased = try await harness.latestPayload(meeting.id)
        let reborn = try #require(
            try records(in: reErased).first { $0["id"] as? String == restorable.id })
        #expect(reborn["claim_text"] as? String == pilotClaim)
        #expect(
            reborn["retracted_at_ms"] as? Int64
                == EvidencePayloadBuilder.milliseconds(date: restorable.createdAt))

        // SC-4(b) + SC-14: deleting every withdrawn row leaves the key PRESENT
        // and empty on the next mint.
        try await harness.database.pool.write { db in
            for row in try MeetingCorrectionStore.all(db, meetingID: meeting.id) {
                try MeetingCorrectionStore.delete(db, id: row.id)
            }
        }
        _ = try await harness.pipeline.renameMeeting(
            meetingID: meeting.id, to: "Quoll Harbor pilot review")
        let empty = try await harness.latestPayload(meeting.id)
        #expect(empty["retractions"] != nil)
        #expect(try records(in: empty).isEmpty)
    }

    @Test("SC-1/SC-15: a record across the full row lifecycle — applied, edited, reopened")
    func recordAcrossTheRowLifecycle() async throws {
        let harness = try await makeSettleHarness()
        let meeting = try await seedSettleMeeting(harness)
        // Whitespace, accented PT and JSON-escapable characters, all asserted
        // at the DECODED-string level: escaping on the wire is transport.
        let awkwardQuote = "  a “sessão” prévia\tfoi \\cancelada\" em setembro  "
        let row = try await plantCorrection(
            harness.database, meetingID: meeting.id, quote: awkwardQuote, status: .pending)

        _ = try await harness.pipeline.renameMeeting(
            meetingID: meeting.id, to: "Quoll Harbor field-kit review")
        let first = try #require(try records(in: try await harness.latestPayload(meeting.id)).first)
        #expect(first["id"] as? String == row.id)
        #expect(first["claim_text"] as? String == awkwardQuote, "byte-verbatim, untrimmed")
        #expect(
            first["retracted_at_ms"] as? Int64
                == EvidencePayloadBuilder.milliseconds(date: row.createdAt))

        // (i) pending→applied touches only bookkeeping: the record is unchanged.
        try await harness.database.pool.write { db in
            try MeetingCorrectionStore.markApplied(db, ids: [row.id], at: harness.clock.now())
        }
        _ = try await harness.pipeline.renameMeeting(
            meetingID: meeting.id, to: "Quoll Harbor pilot review")
        let afterApply = try #require(
            try records(in: try await harness.latestPayload(meeting.id)).first)
        #expect(NSDictionary(dictionary: afterApply) == NSDictionary(dictionary: first))

        // (ii) an understanding EDIT changes claim_text and restamps, same id.
        let newQuote = "uma alegação totalmente diferente"
        #expect(
            try await harness.pipeline.updateCorrection(
                meetingID: meeting.id, id: row.id, quotedText: newQuote, occurrence: 0,
                userText: "Nada disso foi dito") == false)
        _ = try await harness.pipeline.renameMeeting(
            meetingID: meeting.id, to: "Quoll Harbor pilot sync")
        let afterEdit = try #require(
            try records(in: try await harness.latestPayload(meeting.id)).first)
        #expect(afterEdit["id"] as? String == row.id, "the id is the one stable handle")
        #expect(afterEdit["claim_text"] as? String == newQuote)
        let editedStamp = try #require(afterEdit["retracted_at_ms"] as? Int64)
        #expect(editedStamp > (try #require(first["retracted_at_ms"] as? Int64)))

        // (iii) a resolved→pending REOPEN restamps under the same id and text.
        let structured = try await harness.notes(meeting.id).structured
        try await harness.pipeline.setCorrectionResolved(
            meetingID: meeting.id, id: row.id, resolved: true, structuredNotes: structured)
        try await harness.pipeline.setCorrectionResolved(
            meetingID: meeting.id, id: row.id, resolved: false, structuredNotes: structured)
        _ = try await harness.pipeline.renameMeeting(
            meetingID: meeting.id, to: "Quoll Harbor pilot standup")
        let afterReopen = try #require(
            try records(in: try await harness.latestPayload(meeting.id)).first)
        #expect(afterReopen["id"] as? String == row.id)
        #expect(afterReopen["claim_text"] as? String == newQuote)
        #expect((try #require(afterReopen["retracted_at_ms"] as? Int64)) > editedStamp)
    }

    @Test("SC-15: a restamp after the mint moves durable state, so a lost file QUARANTINES")
    func postMintRestampQuarantines() async throws {
        let harness = try await makeSettleHarness()
        try await seedHandoffConfig(harness.database)
        let meeting = try await seedSettleMeeting(harness)
        let row = try await plantCorrection(
            harness.database, meetingID: meeting.id, quote: pilotClaim)
        _ = try await harness.pipeline.renameMeeting(
            meetingID: meeting.id, to: "Quoll Harbor field-kit review")

        let item = try #require(
            try await HandoffRepository(database: harness.database).allItems().first)
        try FileManager.default.removeItem(
            at: harness.database.rootURL.appendingPathComponent(item.payloadPath))
        _ = try await harness.pipeline.updateCorrection(
            meetingID: meeting.id, id: row.id, quotedText: pilotClaim, occurrence: 0,
            userText: "A revised statement that restamps the row")

        let transport = MockTransport()
        let worker = makeWorker(harness.database, transport: transport)
        await worker.kick()
        await worker.waitUntilSettled()

        let rows = try await HandoffRepository(database: harness.database).allItems()
        #expect(rows.first?.state == .failed, "no candidate reproduces the pre-restamp hash")
        #expect(transport.callCount == 0)
    }

    @Test("SC-10: an edit session's delivered payload strictly advances updated_at_ms")
    func timestampStrictlyAdvances() async throws {
        let harness = try await makeSettleHarness()
        let meeting = try await seedSettleMeeting(harness)
        try await plantCorrection(harness.database, meetingID: meeting.id, quote: pilotClaim)
        _ = try await harness.pipeline.renameMeeting(
            meetingID: meeting.id, to: "Quoll Harbor field-kit review")
        let before = try #require(
            try await harness.latestPayload(meeting.id)["updated_at_ms"] as? Int64)

        harness.engine.scriptNotes([[
            .replace(field: .summary, find: "Ships in May.", replace: "Ships in June.",
                instruction: 1)
        ]])
        harness.engine.scriptDigest([[
            DigestEditOperation(find: "in May 2026", replace: "in June 2026", instruction: 1)
        ]])
        await harness.pipeline.settleViewAttached(meeting.id)
        _ = try await harness.pipeline.addCorrection(
            meetingID: meeting.id, kind: .understanding, section: .summary,
            quotedText: "Ships in May.", occurrence: 0, userText: "It ships in June")
        await harness.pipeline.settleViewDetached(meeting.id)

        let after = try await harness.latestPayload(meeting.id)
        #expect(try #require(after["updated_at_ms"] as? Int64) > before)
        #expect(!(try records(in: after).isEmpty), "and the set still rides it")
    }
}

// MARK: - SC-2 (continued) — the regeneration finalize and the digest heal

@Suite struct N5RunMintSiteTests {

    private func readyMeetingWithNotes(
        _ harness: PipelineHarness, digest: String? = nil
    ) async throws -> Meeting {
        let meeting = makeMeeting(
            id: ULID.generate(), title: "Vexatron Labs pilot sync", status: .ready)
        try await MeetingRepository(database: harness.database).create(meeting)
        try harness.database.paths.createMeetingDirectory(meeting.id)
        _ = try await harness.database.persistTranscript(
            meetingID: meeting.id,
            segments: [
                TranscriptSegment(
                    meetingID: meeting.id, ord: 0, startSeconds: 0, endSeconds: 1.5,
                    speakerLabel: "S0", speakerName: "Dana Marsh", text: "The pilot is on schedule.")
            ],
            asrProvenance: ASRProvenance(
                engine: "stub", model: "stub", runtime: "stub", engineVersion: "1",
                transcribedAt: msDate()),
            dominantLanguage: "en", updatedAt: msDate())
        try await NotesRepository(database: harness.database)
            .upsert(retractionNotes(meetingID: meeting.id, digest: digest))
        return meeting
    }

    private func latestPayload(
        _ harness: PipelineHarness, _ id: MeetingID
    ) async throws -> [String: Any] {
        let path = try #require(
            try await harness.database.pool.read { db in
                try String.fetchOne(
                    db,
                    sql: """
                        SELECT payload_path FROM handoff_queue
                        WHERE meeting_id = ? ORDER BY created_seq DESC LIMIT 1
                        """,
                    arguments: [id])
            })
        let data = try Data(contentsOf: harness.database.rootURL.appendingPathComponent(path))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("SC-2/SC-11: the regeneration finalize mint carries the set, from a POST-await read")
    func finalizeMintCarriesTheSet() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        let kept = try await plantCorrection(
            harness.database, meetingID: meeting.id, quote: pilotClaim)
        let transcriptBefore = try await TranscriptRepository(database: harness.database)
            .segments(meetingID: meeting.id)

        _ = try await harness.pipeline.regenerate(meetingID: meeting.id)

        #expect(try recordIDs(try await latestPayload(harness, meeting.id)) == [kept.id])
        // SC-11: a regeneration re-persists the transcript by design (stage 11
        // re-runs ASR, so the row ids move), but its CONTENT is untouched — the
        // derivation reads the transcript and never writes it.
        let transcriptAfter = try await TranscriptRepository(database: harness.database)
            .segments(meetingID: meeting.id)
        #expect(
            transcriptAfter.map { [$0.text, $0.speakerLabel, $0.speakerName ?? ""] }
                == transcriptBefore.map { [$0.text, $0.speakerLabel, $0.speakerName ?? ""] })
        #expect(
            transcriptAfter.map { [$0.ord, Int($0.startSeconds * 1000), Int($0.endSeconds * 1000)] }
                == transcriptBefore.map { [$0.ord, Int($0.startSeconds * 1000), Int($0.endSeconds * 1000)] })
    }

    @Test("SC-2: a row deleted during the regeneration's model await is NOT in the finalize mint")
    func finalizeMintUsesTheMintScopeSlice() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        let doomed = try await plantCorrection(
            harness.database, meetingID: meeting.id, quote: pilotClaim)
        let kept = try await plantCorrection(
            harness.database, meetingID: meeting.id, quote: budgetClaim,
            createdAt: laterTime(50))

        // Understanding-row deletion is not run-gated, so it can land mid-run.
        let database = harness.database
        let fired = Mutex(false)
        harness.notesPrimary.state.withLock {
            $0.onGenerate = {
                guard fired.withLock({ was in defer { was = true }; return !was }) else { return }
                try? await database.pool.write { db in
                    try MeetingCorrectionStore.delete(db, id: doomed.id)
                }
            }
        }

        _ = try await harness.pipeline.regenerate(meetingID: meeting.id)

        #expect(try recordIDs(try await latestPayload(harness, meeting.id)) == [kept.id])
    }

    @Test("SC-2: the digest heal mint carries the set, read AFTER the billed digest call")
    func digestHealMintCarriesTheSet() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await readyMeetingWithNotes(harness)
        try await markDigestPending(harness, meeting.id)
        let kept = try await plantCorrection(
            harness.database, meetingID: meeting.id, quote: pilotClaim)

        #expect(try await harness.pipeline.processDigestOnly(meetingID: meeting.id))

        #expect(try recordIDs(try await latestPayload(harness, meeting.id)) == [kept.id])
    }

    @Test("SC-2: a row deleted during the digest heal's billed await is NOT in the heal mint")
    func digestHealUsesThePostCallRead() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await readyMeetingWithNotes(harness)
        try await markDigestPending(harness, meeting.id)
        let doomed = try await plantCorrection(
            harness.database, meetingID: meeting.id, quote: pilotClaim)
        let kept = try await plantCorrection(
            harness.database, meetingID: meeting.id, quote: budgetClaim,
            createdAt: laterTime(50))

        let database = harness.database
        harness.notesPrimary.state.withLock {
            $0.onGenerate = {
                try? await database.pool.write { db in
                    try MeetingCorrectionStore.delete(db, id: doomed.id)
                }
            }
        }

        #expect(try await harness.pipeline.processDigestOnly(meetingID: meeting.id))

        #expect(try recordIDs(try await latestPayload(harness, meeting.id)) == [kept.id])
    }

    private func markDigestPending(_ harness: PipelineHarness, _ id: MeetingID) async throws {
        try await harness.database.pool.write { db in
            try db.execute(
                sql: "UPDATE meeting SET last_processing_error = ? WHERE id = ?",
                arguments: [DigestPendingClass.prefix + "engine unavailable", id])
        }
    }
}
