import Foundation
import GRDB
import Testing
@testable import BlaiseCore

// V1.1 P1 batch — model-layer tests: action-item done state (migration v7 +
// regenerate keying), attendee display names, transcript copy assembly, and
// the title-rename re-mint + supersession semantics.

// MARK: - Action-item done state (migration v7)

@Suite struct ActionItemKeyTests {
    @Test func keyIsStableAcrossCaseDiacriticsAndWhitespace() {
        let base = ActionItemKey.key(for: "Enviar proposta até sexta")
        #expect(ActionItemKey.key(for: "enviar PROPOSTA ate  sexta") == base)
        #expect(ActionItemKey.key(for: "  Enviar\tproposta até\nsexta  ") == base)
    }

    @Test func changedTextProducesDifferentKey() {
        // The documented regeneration behavior: a rewritten item is a NEW
        // item and loses its done mark — never fuzzy-matched.
        #expect(
            ActionItemKey.key(for: "Enviar proposta")
                != ActionItemKey.key(for: "Enviar proposta revisada"))
    }

    @Test func keyIsSHA256HexOfNormalizedText() {
        let key = ActionItemKey.key(for: "X")
        #expect(key.count == 64)
        #expect(key == EvidencePayloadBuilder.sha256Hex(Data("x".utf8)))
    }
}

@Suite struct ActionItemStateTests {
    @Test func markClearAndDoneKeysRoundTrip() async throws {
        let database = try makeDatabase()
        let meeting = makeMeeting()
        try await MeetingRepository(database: database).create(meeting)
        let repo = ActionItemStateRepository(database: database)

        try await repo.markDone(meetingID: meeting.id, itemText: "Enviar proposta")
        try await repo.markDone(meetingID: meeting.id, itemText: "Revisar contrato")
        var keys = try await repo.doneKeys(meetingID: meeting.id)
        #expect(keys == [
            ActionItemKey.key(for: "Enviar proposta"),
            ActionItemKey.key(for: "Revisar contrato"),
        ])

        try await repo.clearDone(meetingID: meeting.id, itemText: "Enviar proposta")
        keys = try await repo.doneKeys(meetingID: meeting.id)
        #expect(keys == [ActionItemKey.key(for: "Revisar contrato")])
    }

    @Test func markDoneIsIdempotentAndKeepsFirstTimestamp() async throws {
        let database = try makeDatabase()
        let meeting = makeMeeting()
        try await MeetingRepository(database: database).create(meeting)
        let repo = ActionItemStateRepository(database: database)

        try await repo.markDone(meetingID: meeting.id, itemText: "Enviar proposta")
        let first = try await database.pool.read { db in
            try Date.fetchOne(db, sql: "SELECT done_at FROM action_item_state")
        }
        try await repo.markDone(meetingID: meeting.id, itemText: "enviar PROPOSTA")  // same key
        let count = try database.count("action_item_state")
        #expect(count == 1)
        let second = try await database.pool.read { db in
            try Date.fetchOne(db, sql: "SELECT done_at FROM action_item_state")
        }
        #expect(first == second)
    }

    @Test func regenerationKeying_unchangedTextKeepsDoneChangedTextLosesIt() async throws {
        let database = try makeDatabase()
        let meeting = makeMeeting()
        try await MeetingRepository(database: database).create(meeting)
        let repo = ActionItemStateRepository(database: database)

        // Notes v1: two items, both marked done.
        try await repo.markDone(meetingID: meeting.id, itemText: "Enviar proposta")
        try await repo.markDone(meetingID: meeting.id, itemText: "Agendar reunião com a Vexatron")

        // Regeneration rewrites the second item's text; the first survives
        // verbatim. The done marks are resolved purely by key:
        let regenerated = ["Enviar proposta", "Agendar call com a Vexatron na quinta"]
        let done = try await repo.doneKeys(meetingID: meeting.id)
        let stillDone = regenerated.filter { done.contains(ActionItemKey.key(for: $0)) }
        #expect(stillDone == ["Enviar proposta"])
    }

    @Test func doneStateIsScopedPerMeeting() async throws {
        let database = try makeDatabase()
        let a = makeMeeting()
        let b = makeMeeting()
        try await MeetingRepository(database: database).create(a)
        try await MeetingRepository(database: database).create(b)
        let repo = ActionItemStateRepository(database: database)
        try await repo.markDone(meetingID: a.id, itemText: "Enviar proposta")
        #expect(try await repo.doneKeys(meetingID: b.id).isEmpty)
    }

    @Test func payloadBuilderIgnoresDoneState() async throws {
        // Done state is LOCAL ONLY: marking items done must not change what
        // the DURABLE re-materialization path produces — the same
        // rebuild-from-stored-state the delivery self-check performs (C8).
        // Both payloads are rebuilt from the DB, so this fails if markDone
        // ever gains a write to ANY builder input (meeting row, segments,
        // notes), not just if the builder grows a done-state argument.
        let harness = try await makePipelineHarness(now: { Date() })
        let meeting = try await harness.importTestMeeting()
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        let minted = try #require(
            try await HandoffRepository(database: harness.database).nextPending())

        func rebuildFromStoredState() async throws -> (bytes: Data, versionHash: String) {
            let stored = try #require(try await harness.meeting(meeting.id))
            let notes = try #require(
                try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id))
            let segments = try await harness.segments(meeting.id)
            let payload = EvidencePayloadBuilder.build(
                meeting: stored, segments: segments, notes: notes, user: .onboardedUser)
            return (payload.bytes, payload.versionHash)
        }

        let before = try await rebuildFromStoredState()
        #expect(before.versionHash == minted.versionHash, "rebuild matches the minted payload")

        // Mark items done through the REAL repository against the same DB
        // (one item that exists in the generated notes, one arbitrary).
        let repo = ActionItemStateRepository(database: harness.database)
        try await repo.markDone(meetingID: meeting.id, itemText: "mandar o contrato")
        try await repo.markDone(meetingID: meeting.id, itemText: "enviar proposta")

        let after = try await rebuildFromStoredState()
        #expect(after.bytes == before.bytes)
        #expect(after.versionHash == minted.versionHash)
        #expect(!String(decoding: after.bytes, as: UTF8.self).contains("done"))
    }

    @Test func sameFoldedTextItemsInOneMeetingShareDoneState() async throws {
        // Chosen behavior (documented in ActionItemKey): two DISTINCT items
        // in one meeting whose texts fold equal share one key, hence one
        // done state — marking either marks both, everywhere they render.
        let database = try makeDatabase()
        let meeting = makeMeeting()
        try await MeetingRepository(database: database).create(meeting)
        let repo = ActionItemStateRepository(database: database)
        try await repo.markDone(meetingID: meeting.id, itemText: "Enviar proposta")

        let items = ["ENVIAR  PROPOSTA", "Enviar proposta", "Enviar proposta revisada"]
        let done = try await repo.doneKeys(meetingID: meeting.id)
        let marked = items.filter { done.contains(ActionItemKey.key(for: $0)) }
        #expect(marked == ["ENVIAR  PROPOSTA", "Enviar proposta"])

        // ...and clearing through EITHER variant clears both.
        try await repo.clearDone(meetingID: meeting.id, itemText: "enviar proposta")
        #expect(try await repo.doneKeys(meetingID: meeting.id).isEmpty)
    }
}

// MARK: - Attendee display names

@Suite struct AttendeeDisplayTests {
    @Test func plainNamePassesThrough() {
        let attendee = Attendee(name: "Silas Yarrow", email: "s@vexatron.test", source: .calendar)
        #expect(AttendeeDisplay.displayName(attendee) == "Silas Yarrow")
    }

    @Test func emailAsNamePrettifiesLocalPart() {
        let attendee = Attendee(name: "silas.Yarrow@vexatron.test", source: .calendar)
        #expect(AttendeeDisplay.displayName(attendee) == "Silas Yarrow")
    }

    @Test func hyphenAndUnderscoreSeparatorsSplit() {
        #expect(AttendeeDisplay.prettifyLocalPart("anna-reyes_calder@x.io") == "Anna Reyes Calder")
    }

    @Test func numericOnlyPartsDrop() {
        #expect(AttendeeDisplay.prettifyLocalPart("sam.Rivera.1984@x.io") == "Sam Rivera")
        // ...but digits attached to a name part stay.
        #expect(AttendeeDisplay.prettifyLocalPart("cale.sandoval2@x.io") == "Cale Sandoval2")
    }

    @Test func emptyNameFallsBackToEmail() {
        let attendee = Attendee(name: "  ", email: "Kobi@vexatron.test", source: .calendar)
        #expect(AttendeeDisplay.displayName(attendee) == "Kobi")
    }

    @Test func allDomainNameFallsBackToRawString() {
        // Degenerate calendar input: no local part — never render the
        // domain as a person's name.
        #expect(AttendeeDisplay.prettifyLocalPart("@vexatron.test") == "@vexatron.test")
        let attendee = Attendee(name: "@vexatron.test", source: .calendar)
        #expect(AttendeeDisplay.displayName(attendee) == "@vexatron.test")
    }

    @Test func tooltipCarriesFullEmails() {
        let attendees = [
            Attendee(name: "Silas Yarrow", email: "silas@vexatron.test", source: .calendar),
            Attendee(name: "anna.calder@x.io", source: .calendar),
            Attendee(name: "Guest", source: .meetExtension),
        ]
        #expect(
            AttendeeDisplay.tooltip(attendees)
                == "Silas Yarrow <silas@vexatron.test>\nAnna Calder <anna.calder@x.io>\nGuest")
    }

    /// Field 2026-06-11: a pre-0.2.0 Meet extension scraped a CSS block and a
    /// UI sentence into the attendee name position; they rendered verbatim in
    /// the "Internal Weekly" detail header as "json artifacts".
    /// `presentable` drops extension-sourced junk at display; the durable row
    /// is untouched, and calendar/manual rows (incl. email-as-name) are kept.
    @Test func presentableDropsExtensionScrapedJunkButKeepsRealRows() {
        let cssBlock = """
            .ink-canvas-parent {
                      height: 100%;
                      position: relative;
                      width: 100%;
                    }
            """
        let attendees = [
            Attendee(name: "Marston@vexatron.test", email: "Marston@vexatron.test", source: .calendar),
            Attendee(name: "Eduardo Nolan", source: .meetExtension),
            Attendee(name: "As pessoas ainda podem ver seu vídeo completo.", source: .meetExtension),
            Attendee(name: "Sam Marston", source: .meetExtension),
            Attendee(name: cssBlock, source: .meetExtension),
        ]
        let kept = AttendeeDisplay.presentable(attendees).map(\.name)
        #expect(kept == ["Marston@vexatron.test", "Eduardo Nolan", "Sam Marston"])
        // The email-as-name calendar row still prettifies to a humane name.
        #expect(AttendeeDisplay.displayName(attendees[0]) == "Marston")
    }

    @Test func looksLikeSentenceOnlyFlagsManyWordTerminatedStrings() {
        #expect(AttendeeDisplay.looksLikeSentence("As pessoas ainda podem ver seu vídeo completo."))
        #expect(!AttendeeDisplay.looksLikeSentence("Maria Eduarda da Silva Santos Oliveira"))
        #expect(!AttendeeDisplay.looksLikeSentence("Sam Bopp Jr."))  // few tokens, kept
        #expect(!AttendeeDisplay.looksLikeSentence("Anna Reyes"))
    }
}

// MARK: - Copy All assembly

@Suite struct TranscriptCopyTextTests {
    @Test func assemblesSpeakerNamesAndTimestamps() {
        let segments = [
            TranscriptSegment(
                meetingID: "m", ord: 0, startSeconds: 0, endSeconds: 4,
                speakerLabel: "S0", speakerName: "Sam", text: " Vamos começar. "),
            TranscriptSegment(
                meetingID: "m", ord: 1, startSeconds: 65.4, endSeconds: 70,
                speakerLabel: "S1", speakerName: nil, text: "Ok."),
            TranscriptSegment(
                meetingID: "m", ord: 2, startSeconds: 3725, endSeconds: 3730,
                speakerLabel: "S0", speakerName: "Sam", text: "Fechado."),
        ]
        #expect(
            TranscriptCopyText.assemble(segments) == """
                [0:00:00] Sam: Vamos começar.
                [0:01:05] S1: Ok.
                [1:02:05] Sam: Fechado.
                """)
    }

    @Test func emptyTranscriptYieldsEmptyString() {
        #expect(TranscriptCopyText.assemble([]) == "")
    }
}

// MARK: - Title rename (re-mint + supersession)

@Suite struct RenameMeetingTests {
    @Test func renameNonReadyUpdatesTitleAndUpdatedAtWithoutMinting() async throws {
        let harness = try await makePipelineHarness(now: { Date() })
        let meeting = try await harness.importTestMeeting()  // status .processing
        let before = try #require(try await harness.meeting(meeting.id))

        let minted = try await harness.pipeline.renameMeeting(
            meetingID: meeting.id, to: "Kickoff Vexatron")

        #expect(!minted)
        let after = try #require(try await harness.meeting(meeting.id))
        #expect(after.title == "Kickoff Vexatron")
        #expect(after.updatedAt > before.updatedAt, "title edit is a CONTENT mutation")
        #expect(try await harness.queueRows(meeting.id) == 0)
    }

    @Test func renameReadyRemintsRerendersAndEnqueuesNewHash() async throws {
        let harness = try await makePipelineHarness(now: { Date() })
        let meeting = try await harness.importTestMeeting()
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        let readyBefore = try #require(try await harness.meeting(meeting.id))
        #expect(readyBefore.status == .ready)
        let firstItem = try #require(try await HandoffRepository(database: harness.database).nextPending())

        // Make the renderer's H1 fallback observable: a nil structured
        // title renders the MEETING title as H1.
        var notes = try #require(
            try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id))
        notes.structured.title = nil
        try await NotesRepository(database: harness.database).upsert(notes)

        let minted = try await harness.pipeline.renameMeeting(
            meetingID: meeting.id, to: "Pauta nova")
        #expect(minted)

        let after = try #require(try await harness.meeting(meeting.id))
        #expect(after.title == "Pauta nova")
        #expect(after.status == .ready, "rename never regresses status")
        #expect(after.updatedAt > readyBefore.updatedAt)

        // Markdown re-rendered with the new title (deterministic re-mint —
        // structured content untouched, no engine call).
        let renamedNotes = try #require(
            try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id))
        #expect(renamedNotes.markdown.hasPrefix("# Pauta nova"))
        #expect(renamedNotes.structured == notes.structured)

        // A SECOND queue row with a new hash; the payload file exists,
        // carries the new title, and re-materializes hash-equal from
        // durable state alone (the C8 recovery invariant).
        let items = try await HandoffRepository(database: harness.database).allItems()
        #expect(items.count == 2)
        let newItem = try #require(items.last)
        #expect(newItem.versionHash != firstItem.versionHash)
        let payloadURL = harness.database.rootURL.appendingPathComponent(newItem.payloadPath)
        let bytes = try Data(contentsOf: payloadURL)
        #expect(EvidencePayloadBuilder.sha256Hex(bytes) == newItem.versionHash)
        #expect(String(decoding: bytes, as: UTF8.self).contains("Pauta nova"))
        let segments = try await harness.segments(meeting.id)
        let rebuilt = EvidencePayloadBuilder.build(
            meeting: after, segments: segments, notes: renamedNotes, user: .onboardedUser)
        #expect(rebuilt.versionHash == newItem.versionHash)

        // D12: delivery of the new payload terminally supersedes the old row.
        let (_, superseded) = try await HandoffRepository(database: harness.database)
            .markDelivered(newItem.id, endpoint: testDestinationIdentity)
        #expect(superseded == [firstItem.id])
        let oldRow = try #require(try await harness.database.pool.read { db in
            try HandoffItem.fetchOne(db, key: firstItem.id)
        })
        #expect(oldRow.state == .failed)
        #expect(oldRow.lastError?.hasPrefix(HandoffErrorClass.supersededPrefix) == true)
    }

    @Test func renameToSameOrEmptyTitleIsNoOp() async throws {
        let harness = try await makePipelineHarness(now: { Date() })
        let meeting = try await harness.importTestMeeting()
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        let before = try #require(try await harness.meeting(meeting.id))

        #expect(try await harness.pipeline.renameMeeting(meetingID: meeting.id, to: before.title) == false)
        #expect(try await harness.pipeline.renameMeeting(meetingID: meeting.id, to: "   ") == false)

        let after = try #require(try await harness.meeting(meeting.id))
        #expect(after.updatedAt == before.updatedAt, "no content change, no updatedAt bump")
        #expect(try await harness.queueRows(meeting.id) == 1, "no second mint")
    }

    @Test func renameNotesPendingReadySkipsMintAndKeepsMarker() async throws {
        let harness = try await makePipelineHarness(now: { Date() })
        let meeting = try await harness.importTestMeeting()
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        // Simulate the D17 regeneration-class pending state: ready + marker.
        try await harness.database.pool.write { db in
            try db.execute(
                sql: "UPDATE meeting SET last_processing_error = ? WHERE id = ?",
                arguments: [NotesPendingClass.marker("engine offline"), meeting.id])
        }

        let minted = try await harness.pipeline.renameMeeting(
            meetingID: meeting.id, to: "Renomeada pendente")

        #expect(!minted, "pending meetings defer the mint to the self-heal's finalize")
        let after = try #require(try await harness.meeting(meeting.id))
        #expect(after.title == "Renomeada pendente")
        #expect(NotesPendingClass.isPending(after.lastProcessingError), "marker must survive")
        #expect(try await harness.queueRows(meeting.id) == 1)
    }

    @Test func renameMissingMeetingThrows() async throws {
        let harness = try await makePipelineHarness()
        await #expect(throws: BlaiseDatabaseError.self) {
            try await harness.pipeline.renameMeeting(meetingID: ULID.generate(), to: "X")
        }
    }
}
