import Foundation
import Testing

@testable import BlaiseCore

// Design-wave logic pins (impl-audit M-3/H-1): the direction precedence
// chain, the meeting-list arrow-key advance, and the detail model's
// `loaded` placeholder gate — the wave's load-bearing logic, under test in
// core. (The render layer — live switch, mesh, Pow effects — is verified
// by eye/capture; it lives in the untestable executable target.)

@Suite struct DesignDirectionResolutionTests {
    @Test func envOverrideWinsOverSavedChoice() {
        #expect(DesignDirection.resolved(env: "caderno", saved: "fluido") == .caderno)
    }

    @Test func savedChoiceWinsWhenNoEnv() {
        #expect(DesignDirection.resolved(env: nil, saved: "aquarela") == .aquarela)
    }

    @Test func defaultIsEstudio() {
        #expect(DesignDirection.resolved(env: nil, saved: nil) == .estudio)
    }

    @Test func invalidEnvFallsThroughToSaved() {
        #expect(DesignDirection.resolved(env: "neon", saved: "fluido") == .fluido)
    }

    @Test func invalidSavedFallsThroughToDefault() {
        #expect(DesignDirection.resolved(env: nil, saved: "Estudio") == .estudio)
        #expect(DesignDirection.resolved(env: nil, saved: "") == .estudio)
    }

    @Test func bothInvalidFallsThroughToDefault() {
        #expect(DesignDirection.resolved(env: "", saved: "garbage") == .estudio)
    }

    @Test func everyCaseRoundTripsItsRawValue() {
        for direction in DesignDirection.allCases {
            #expect(DesignDirection.resolved(env: direction.rawValue, saved: nil) == direction)
        }
    }
}

@Suite struct ListKeySelectionTests {
    let order = ["a", "b", "c", "d"]

    @Test func downAdvancesToNextRow() {
        #expect(ListKeySelection.moved(from: "b", in: order, delta: 1) == "c")
    }

    @Test func upRetreatsToPreviousRow() {
        #expect(ListKeySelection.moved(from: "b", in: order, delta: -1) == "a")
    }

    @Test func clampsAtBothEnds() {
        #expect(ListKeySelection.moved(from: "d", in: order, delta: 1) == "d")
        #expect(ListKeySelection.moved(from: "a", in: order, delta: -1) == "a")
    }

    @Test func noSelectionDownSelectsFirst() {
        #expect(ListKeySelection.moved(from: nil, in: order, delta: 1) == "a")
    }

    @Test func noSelectionUpSelectsLast() {
        #expect(ListKeySelection.moved(from: nil, in: order, delta: -1) == "d")
    }

    @Test func selectionNoLongerVisibleBehavesLikeNoSelection() {
        // e.g. the selected meeting was filtered out by a smart-group switch.
        #expect(ListKeySelection.moved(from: "zz", in: order, delta: 1) == "a")
        #expect(ListKeySelection.moved(from: "zz", in: order, delta: -1) == "d")
    }

    @Test func emptyListLeavesSelectionUntouched() {
        #expect(ListKeySelection.moved(from: "a", in: [], delta: 1) == "a")
        #expect(ListKeySelection.moved(from: String?.none, in: [], delta: 1) == nil)
    }

    /// The wired flat order: day groups flatten in display order, so ↓ from
    /// a day's last row lands on the NEXT day's first row.
    @Test @MainActor func advanceCrossesDayGroupBoundaries() {
        let calendar = Calendar(identifier: .gregorian)
        let now = msDate()
        let today = makeMeeting(title: "Today sync", startedAt: now)
        let yesterdayA = makeMeeting(
            title: "Yesterday A", startedAt: now.addingTimeInterval(-24 * 3600))
        let yesterdayB = makeMeeting(
            title: "Yesterday B", startedAt: now.addingTimeInterval(-25 * 3600))
        let items = [today, yesterdayA, yesterdayB].map {
            MeetingListItem(meeting: $0, summary: nil, actionItemCount: 0, userActionItemCount: 0)
        }
        let groups = LibraryModel.dayGroups(items, calendar: calendar, now: now)
        let order = groups.flatMap { $0.items.map(\.id) }
        #expect(order == [today.id, yesterdayA.id, yesterdayB.id])
        #expect(ListKeySelection.moved(from: today.id, in: order, delta: 1) == yesterdayA.id)
        #expect(ListKeySelection.moved(from: yesterdayA.id, in: order, delta: -1) == today.id)
    }
}

@MainActor
@Suite struct MeetingDetailLoadedFlagTests {
    /// `loaded` flips only on the first observation delivery: before it the
    /// pane renders clear over the backdrop (no placeholder flash on
    /// meeting swap); after it, a nil meeting honestly means "not found".
    @Test func loadedFlipsOnFirstDeliveryEvenWhenMeetingAbsent() async throws {
        let database = try makeDatabase()
        let model = MeetingDetailModel(database: database, meetingID: ULID.generate())
        #expect(!model.loaded)

        model.start()
        defer { model.stop() }
        for _ in 0..<200 {
            if model.loaded { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.loaded)
        #expect(model.meeting == nil)  // "Meeting not found", post-load only
    }

    @Test func loadedFlipsWithMeetingPresent() async throws {
        let database = try makeDatabase()
        let meeting = makeMeeting(status: .ready)
        try await MeetingRepository(database: database).create(meeting)

        let model = MeetingDetailModel(database: database, meetingID: meeting.id)
        #expect(!model.loaded)
        model.start()
        defer { model.stop() }
        for _ in 0..<200 {
            if model.loaded { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.loaded)
        #expect(model.meeting?.id == meeting.id)
    }
}
