import AVFoundation
import Foundation
import GRDB
import Testing

@testable import BlaiseCore

// G11: calendar-aware end detection — the pure classifier (AC1), the anchor
// columns + suggestion pass-through (AC2), the durable-grace recovery columns
// (AC4), calendar reliability + binding window + the diagnostic/log-privacy
// formatter (AC5), and the §4b Upcoming-list model (AC8). The tracker WIRING
// (AC3/AC4 exits) is pinned in RecordingAutomationTests' G11 suites; the
// quit-during-grace replacements in CapturePartsTests. All fixtures fictional.

private let epoch = Date(timeIntervalSince1970: 1_781_136_000)
private func at(_ offsetSeconds: TimeInterval) -> Date { epoch.addingTimeInterval(offsetSeconds) }
private func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

// MARK: - AC1: the pure classifier

@Suite("G11 AC1: EndDetection classifier (band edges)")
struct EndDetectionClassifierTests {
    @Test("at exactly −10:00 before the scheduled end → endAndProcess")
    func bandOpenEdgeProcesses() {
        let scheduledEnd = at(3600)
        let signal = scheduledEnd.addingTimeInterval(-600)  // exactly 10 min before
        #expect(
            EndDetectionClassifier.classify(endSignalAt: signal, scheduledEndMs: ms(scheduledEnd))
                == .endAndProcess)
    }

    @Test("at −10:01 (just before the band opens) → graceThenProcess")
    func justBeforeBandGraces() {
        let scheduledEnd = at(3600)
        let signal = scheduledEnd.addingTimeInterval(-601)  // 10 min 1 s before
        #expect(
            EndDetectionClassifier.classify(endSignalAt: signal, scheduledEndMs: ms(scheduledEnd))
                == .graceThenProcess)
    }

    @Test("after the scheduled end → endAndProcess")
    func postEndProcesses() {
        let scheduledEnd = at(3600)
        let signal = scheduledEnd.addingTimeInterval(120)
        #expect(
            EndDetectionClassifier.classify(endSignalAt: signal, scheduledEndMs: ms(scheduledEnd))
                == .endAndProcess)
    }

    @Test("nil anchor (ad-hoc meeting) → graceThenProcess regardless of time")
    func nilAnchorGraces() {
        #expect(
            EndDetectionClassifier.classify(endSignalAt: at(99_999), scheduledEndMs: nil)
                == .graceThenProcess)
    }

    @Test("well before the band (early signal on an anchored meeting) → graceThenProcess")
    func earlySignalGraces() {
        let scheduledEnd = at(3600)
        let signal = scheduledEnd.addingTimeInterval(-3000)  // 50 min before
        #expect(
            EndDetectionClassifier.classify(endSignalAt: signal, scheduledEndMs: ms(scheduledEnd))
                == .graceThenProcess)
    }
}

// MARK: - AC2: the anchor columns + suggestion pass-through

@Suite("G11 AC2: anchor persistence")
struct AnchorPersistenceTests {
    @Test("a matched suggestion carries end + eventIdentifier; CalendarAnchor derives from it")
    func suggestionCarriesAnchor() {
        let event = CalendarEventSnapshot(
            eventIdentifier: "evt-fiction-1", title: "Sprint review", start: at(0), end: at(1800),
            location: "meet.google.com/qrs-tuvw-xyz",
            attendees: [.init(name: "Alex Doe", email: "alex@example.test")])
        let suggestions = CalendarSuggestionBuilder.suggestions(
            from: [event], now: at(0), userEmail: "me@example.test")
        let suggestion = try! #require(suggestions.first)
        #expect(suggestion.end == at(1800))
        #expect(suggestion.eventIdentifier == "evt-fiction-1")
        let anchor = try! #require(CalendarAnchor(suggestion: suggestion))
        #expect(anchor.scheduledEndMs == ms(at(1800)))
        #expect(anchor.eventIdentifier == "evt-fiction-1")
    }

    @Test("a manual suggestion with no end yields no anchor")
    func manualSuggestionNoAnchor() {
        let suggestion = MeetingSuggestion(
            title: "Ad-hoc", start: at(0), source: .inPerson, meetingCode: nil, attendees: [])
        #expect(CalendarAnchor(suggestion: suggestion) == nil)
    }

    @Test("controller.start persists the anchor columns; ad-hoc leaves them NULL")
    func startPersistsAnchorColumns() async throws {
        let database = try makeDatabase()
        let controller = RecordingController(
            database: database, engine: AnchorMockEngine(), processKicker: { _ in })
        let anchor = CalendarAnchor(eventIdentifier: "evt-fiction-2", scheduledEnd: at(2400))
        let anchored = try await controller.start(
            source: .meet, title: "Bound", meetingCode: "abc-defg-hij", attendees: [],
            anchor: anchor)
        let storedAnchored = try #require(try await MeetingRepository(database: database).fetch(anchored.id))
        #expect(storedAnchored.calendarEventID == "evt-fiction-2")
        #expect(storedAnchored.scheduledEndMs == ms(at(2400)))
        _ = try await controller.stop()

        let adHoc = try await controller.start(
            source: .meet, title: "Ad-hoc", meetingCode: nil, attendees: [], anchor: nil)
        let storedAdHoc = try #require(try await MeetingRepository(database: database).fetch(adHoc.id))
        #expect(storedAdHoc.calendarEventID == nil)
        #expect(storedAdHoc.scheduledEndMs == nil)
    }

    @Test("the anchor round-trips through the Meeting Codable (no migration needed for old rows)")
    func anchorCodableRoundTrip() throws {
        var meeting = makeMeeting()
        meeting.calendarEventID = "evt-fiction-3"
        meeting.scheduledEndMs = 12_345
        meeting.graceUntilMs = 67_890
        let data = try JSONEncoder().encode(meeting)
        let decoded = try JSONDecoder().decode(Meeting.self, from: data)
        #expect(decoded.calendarEventID == "evt-fiction-3")
        #expect(decoded.scheduledEndMs == 12_345)
        #expect(decoded.graceUntilMs == 67_890)
    }
}

private final class AnchorMockEngine: AudioCapturing, @unchecked Sendable {
    @discardableResult
    func start(
        systemCAF: URL, micCAF: URL,
        onEvent: @escaping @Sendable (CaptureEngineEvent) -> Void
    ) async throws -> CaptureStartInfo {
        // Plant a 1 s real CAF pair so the stop has recoverable audio.
        for url in [systemCAF, micCAF] {
            let writer = try CaptureCAFWriter(url: url)
            let buffer = AVAudioPCMBuffer(pcmFormat: CaptureCAFWriter.format, frameCapacity: 16_000)!
            buffer.frameLength = 16_000
            try writer.write(buffer)
            writer.close()
        }
        return CaptureStartInfo(micStreams: 1)
    }
    func stop() async {}
}

// MARK: - AC4: the durable-grace column writer + interrupted-flip exemption

@Suite("G11 AC4: durable grace column + flip exemption")
struct DurableGraceColumnTests {
    @Test("persistGraceDeadline writes then clears the column")
    func persistAndClear() async throws {
        let database = try makeDatabase()
        let controller = RecordingController(
            database: database, engine: AnchorMockEngine(), processKicker: { _ in })
        let meeting = try await controller.start(
            source: .meet, meetingCode: "abc-defg-hij", anchor: nil)
        await controller.persistGraceDeadline(meetingID: meeting.id, until: 999)
        #expect(try await MeetingRepository(database: database).fetch(meeting.id)?.graceUntilMs == 999)
        await controller.persistGraceDeadline(meetingID: meeting.id, until: nil)
        #expect(try await MeetingRepository(database: database).fetch(meeting.id)?.graceUntilMs == nil)
    }

    @Test("interrupted-flip EXEMPTS a recording row with a non-nil grace column")
    func flipExemptsGraceRow() async throws {
        let database = try makeDatabase()
        let meeting = makeMeeting(status: .recording)
        try await MeetingRepository(database: database).create(meeting)
        // A second recording row WITHOUT a grace column: must be flipped.
        let plain = makeMeeting(status: .recording)
        try await MeetingRepository(database: database).create(plain)
        // Set the grace column on the first only.
        try await database.pool.write { db in
            try db.execute(
                sql: "UPDATE meeting SET grace_until_ms = 123 WHERE id = ?", arguments: [meeting.id])
        }
        // Reopen → runStartupSweeps runs the interrupted flip.
        let reopened = try BlaiseDatabase(rootURL: database.rootURL)
        let exempted = try #require(try await MeetingRepository(database: reopened).fetch(meeting.id))
        #expect(exempted.status == .recording, "non-nil grace column → exempted from the flip")
        let flipped = try #require(try await MeetingRepository(database: reopened).fetch(plain.id))
        #expect(flipped.status == .failed)
        #expect(flipped.lastProcessingError == "interrupted")
    }

    @Test("a future-deadline grace with NO meeting code processes now (un-rejoinable)")
    func codelessFutureGraceProcesses() async throws {
        let database = try makeDatabase()
        var meeting = makeMeeting(status: .recording)
        meeting.meetingCode = nil
        try await MeetingRepository(database: database).create(meeting)
        let meetingID = meeting.id
        let futureMs = Int64(Date().addingTimeInterval(300).timeIntervalSince1970 * 1000)
        try await database.pool.write { db in
            try db.execute(
                sql: "UPDATE meeting SET grace_until_ms = ? WHERE id = ?",
                arguments: [futureMs, meetingID])
        }
        let kicked = Recorder<MeetingID>()
        let reentered = Recorder<MeetingID>()
        _ = await CaptureRecovery.recoverDurableGrace(
            database: database, kick: { kicked.append($0) },
            reenterGrace: { reentered.append($0.meetingID) })
        #expect(kicked.values == [meetingID], "code-less → processed, not re-entered")
        #expect(reentered.values.isEmpty)
        #expect(try await MeetingRepository(database: database).fetch(meetingID)?.graceUntilMs == nil)
    }

    @Test("a paused row with a stale grace column is never recovered (status-scoped)")
    func pausedRowNotRecovered() async throws {
        let database = try makeDatabase()
        let paused = makeMeeting(status: .paused)
        try await MeetingRepository(database: database).create(paused)
        try await database.pool.write { db in
            try db.execute(
                sql: "UPDATE meeting SET grace_until_ms = 1 WHERE id = ?", arguments: [paused.id])
        }
        let kicked = Recorder<MeetingID>()
        let reentered = Recorder<MeetingID>()
        let recovered = await CaptureRecovery.recoverDurableGrace(
            database: database, kick: { kicked.append($0) },
            reenterGrace: { reentered.append($0.meetingID) })
        #expect(recovered.isEmpty, "only `recording` rows are recovered")
        #expect(kicked.values.isEmpty)
        #expect(reentered.values.isEmpty)
    }
}

// MARK: - AC5: calendar reliability + binding window + diagnostics

@Suite("G11 AC5: binding window + diagnostics")
struct CalendarReliabilityTests {
    private func event(
        id: String, title: String, start: Date, end: Date,
        link: String? = nil, attendees: [CalendarEventSnapshot.AttendeeSnapshot] = []
    ) -> CalendarEventSnapshot {
        CalendarEventSnapshot(
            eventIdentifier: id, title: title, start: start, end: end,
            location: link, attendees: attendees)
    }

    @Test("the widened window binds a start joined mid-meeting (the Zoom miss)")
    func midMeetingBindsToSpan() {
        let zoom = event(
            id: "evt-zoom", title: "Standup", start: at(0), end: at(3600),
            link: "https://example.zoom.us/j/123")
        // A start 30 min into the meeting (well past the start vicinity) binds.
        let bound = CalendarSuggestionBuilder.bindingEvent(
            for: at(1800), code: nil, in: [zoom])
        #expect(bound?.eventIdentifier == "evt-zoom")
    }

    @Test("a NON-MEET event with no link still anchors (miss-class f fix)")
    func nonMeetEventAnchors() {
        let inPerson = event(
            id: "evt-room", title: "1:1", start: at(0), end: at(1800),
            attendees: [.init(name: "Sam Reyes")])
        let bound = CalendarSuggestionBuilder.bindingEvent(for: at(60), code: nil, in: [inPerson])
        #expect(bound?.eventIdentifier == "evt-room", "anchoring does not require a Meet link")
    }

    @Test("default-titled meetings bind — title is never a matching input (field exhibit)")
    func defaultTitledBinds() {
        // Two same-default-title meetings; the one whose span COVERS the start wins.
        let a = event(id: "evt-a", title: "Meeting", start: at(0), end: at(900))
        let b = event(id: "evt-b", title: "Meeting", start: at(1000), end: at(2000),
            attendees: [.init(name: "Jordan Vale")])
        let bound = CalendarSuggestionBuilder.bindingEvent(for: at(1500), code: nil, in: [a, b])
        #expect(bound?.eventIdentifier == "evt-b", "the covering span wins regardless of title")
    }

    @Test("code-matched events bind regardless of time vicinity")
    func codeMatchBindsOutOfWindow() {
        let meet = event(
            id: "evt-meet", title: "Sync", start: at(0), end: at(1800),
            link: "meet.google.com/qrs-tuvw-xyz")
        // A start far past the event end still binds by code.
        let bound = CalendarSuggestionBuilder.bindingEvent(
            for: at(99_999), code: "qrs-tuvw-xyz", in: [meet])
        #expect(bound?.eventIdentifier == "evt-meet")
    }

    @Test("no event covers the start → nil (ad-hoc)")
    func noCandidateAdHoc() {
        let far = event(id: "evt-far", title: "Later", start: at(7200), end: at(9000))
        #expect(CalendarSuggestionBuilder.bindingEvent(for: at(0), code: nil, in: [far]) == nil)
    }

    @Test("quickStartAnchor: a start INSIDE a covering event yields its end anchor")
    func quickStartAnchorCovers() {
        let zoom = event(
            id: "evt-zoom", title: "Standup", start: at(0), end: at(3600),
            link: "https://example.zoom.us/j/123")
        // A quick-start 30 min into the meeting (the late-join case) anchors.
        let anchor = try! #require(
            CalendarSuggestionBuilder.quickStartAnchor(for: at(1800), code: nil, in: [zoom]))
        #expect(anchor.eventIdentifier == "evt-zoom")
        #expect(anchor.scheduledEnd == at(3600))
    }

    @Test("quickStartAnchor: a PRE-START in the lead (event not yet begun) does NOT anchor")
    func quickStartAnchorPreStartAdHoc() {
        // Within the −15 min bind lead but before the event begins: bindingEvent
        // would surface it, but there is no trustworthy "currently scheduled to
        // end" yet, so quickStartAnchor stays ad-hoc.
        let soon = event(id: "evt-soon", title: "Soon", start: at(600), end: at(2400))
        #expect(CalendarSuggestionBuilder.quickStartAnchor(for: at(0), code: nil, in: [soon]) == nil)
    }

    @Test("quickStartAnchor: a code-match OUTSIDE the span does NOT fabricate an anchor")
    func quickStartAnchorCodeMatchOutsideSpanAdHoc() {
        // A pasted code can correlate (bindingEvent binds by code regardless of
        // time), but a start long after the event's end must not anchor to a
        // stale scheduled_end_ms — coverage is required.
        let meet = event(
            id: "evt-meet", title: "Sync", start: at(0), end: at(1800),
            link: "meet.google.com/qrs-tuvw-xyz")
        #expect(
            CalendarSuggestionBuilder.quickStartAnchor(
                for: at(99_999), code: "qrs-tuvw-xyz", in: [meet]) == nil)
    }

    @Test("END-TO-END: a quick-start covered by a calendar event lets the classifier Rule-1 it")
    func quickStartAnchorEndToEnd() async throws {
        // The headline §4 v3.2 case: a meeting JOINED MID-WAY (no surfaced
        // suggestion, because the event started > 15 min ago) must still get a
        // scheduled_end_ms so the §2 classifier can process in-band (Rule-1)
        // instead of always gracing. Synthetic EventKit-shaped snapshot; no real
        // calendar. now = 30 min into a 60 min meeting.
        let inProgress = event(
            id: "evt-midjoin", title: "All-hands", start: at(0), end: at(3600),
            link: "https://example.zoom.us/j/999")
        let joinAt = at(1800)
        // 1) The wiring derives the anchor a quick-start would carry.
        let anchor = try #require(
            CalendarSuggestionBuilder.quickStartAnchor(for: joinAt, code: nil, in: [inProgress]),
            "a covered quick-start must derive an anchor")

        // 2) The start persists the §1 anchor columns (the production path).
        let database = try makeDatabase()
        let controller = RecordingController(
            database: database, engine: AnchorMockEngine(), processKicker: { _ in })
        let meeting = try await controller.start(
            source: .zoom, title: "All-hands", meetingCode: nil, attendees: [], anchor: anchor)
        let stored = try #require(try await MeetingRepository(database: database).fetch(meeting.id))
        #expect(stored.scheduledEndMs == ms(at(3600)), "the covering event's end was persisted")
        #expect(stored.calendarEventID == "evt-midjoin")

        // 3) An end signal in-band (within 10 min of the scheduled end) now
        // classifies to processNow — Rule-1 fires, which it could NEVER do for
        // a mid-join before the v3.2 wiring (no anchor → always graceThenProcess).
        let endSignal = at(3600).addingTimeInterval(-300)  // 5 min before scheduled end
        #expect(
            EndDetectionClassifier.classify(
                endSignalAt: endSignal, scheduledEndMs: stored.scheduledEndMs)
                == .endAndProcess,
            "the persisted anchor lets the mid-join process in-band")
    }

    @Test("diagnostic: every §4 miss class is fixture-pinned (AC5)")
    func diagnoseClasses() {
        let now = at(0)
        // (success) a bindable Meet event reads bindable.
        let bindable = CalendarCandidateContext(
            snapshot: event(id: "evt-ok", title: "Open", start: at(-60), end: at(1800),
                link: "meet.google.com/abc-defg-hij"))
        // (a) excluded calendars: the event's calendar is not in the scan set.
        let excluded = CalendarCandidateContext(
            snapshot: event(id: "evt-x", title: "Hidden", start: at(0), end: at(1800)),
            calendarIncluded: false)
        // (b) pending invites: the user has not accepted.
        let pending = CalendarCandidateContext(
            snapshot: event(id: "evt-p", title: "Invited", start: at(0), end: at(1800)),
            accepted: false)
        // (c) recurring expansion: the series never expanded to a concrete instance.
        let recurring = CalendarCandidateContext(
            snapshot: event(id: "evt-r", title: "Weekly", start: at(-60), end: at(1800),
                link: "meet.google.com/abc-defg-hij"),
            expanded: false)
        // (d) refresh cadence / time window: now is outside [start − 15 min, end].
        // The event begins 30 min from now — past the 15 min bind lead — so it
        // was never fetched into the binding window.
        let outside = CalendarCandidateContext(
            snapshot: event(id: "evt-w", title: "Later", start: at(1800), end: at(3600),
                link: "meet.google.com/abc-defg-hij"))
        // (e) §4 v3.2: a meet.google.com text that does NOT parse to a valid
        // 3-4-3 code, but on an in-window, accepted, expanded event. The link
        // gates Launch & Record only — the event still ANCHORS, so it is
        // `.bindable`, never a miss. (Pins the regression: the former
        // "meetLinkUnparsed" miss class is superseded; a broken link must not
        // hide a real meeting from end detection.)
        let brokenLink = CalendarCandidateContext(
            snapshot: event(id: "evt-u", title: "Broken link", start: at(-60), end: at(1800),
                link: "meet.google.com/xy-bad"))
        let diagnostics = CalendarDiagnostics.diagnose(
            candidates: [bindable, excluded, pending, recurring, outside, brokenLink], now: now)
        let byID = Dictionary(uniqueKeysWithValues: diagnostics.map { ($0.eventIdentifier, $0.missClass) })
        #expect(byID["evt-ok"] == .bindable)
        #expect(byID["evt-x"] == .excludedCalendar)
        #expect(byID["evt-p"] == .pendingInvite)
        #expect(byID["evt-r"] == .recurringNotExpanded)
        #expect(byID["evt-w"] == .outsideWindow)
        #expect(byID["evt-u"] == .bindable, "a broken Meet link does not hide a calendar-anchored meeting")
    }

    @Test("AC5 formatter seam: the LOG variant carries NO event title; the UI variant does")
    func logVariantHasNoTitle() {
        let diagnostic = CalendarCandidateDiagnostic(
            eventIdentifier: "evt-secret", title: "Confidential 1:1", start: at(0), end: at(1800),
            meetingCode: "abc-defg-hij", missClass: .bindable)
        let line = CalendarDiagnostics.line(for: diagnostic)
        #expect(line.ui.contains("Confidential 1:1"), "the UI surface shows the title")
        #expect(!line.log.contains("Confidential 1:1"), "the log variant NEVER carries the title")
        #expect(line.log.contains("evt-secret"), "the log variant keys on the identifier")
    }
}

// MARK: - AC8: the §4b Upcoming-meetings list model

@Suite("G11 AC8: Upcoming-meetings list model")
struct UpcomingMeetingsTests {
    private let spCal = UpcomingMeetings.saoPauloCalendar
    /// A fixed reference noon in São Paulo so "today" scoping is deterministic.
    private var noonSP: Date {
        spCal.date(from: DateComponents(
            timeZone: TimeZone(identifier: "America/Sao_Paulo"),
            year: 2026, month: 6, day: 13, hour: 12))!
    }

    private func event(
        id: String, title: String, startHour: Int, endHour: Int,
        link: String? = nil, attendees: [CalendarEventSnapshot.AttendeeSnapshot] = []
    ) -> CalendarEventSnapshot {
        let start = spCal.date(from: DateComponents(
            timeZone: TimeZone(identifier: "America/Sao_Paulo"),
            year: 2026, month: 6, day: 13, hour: startHour))!
        let end = spCal.date(from: DateComponents(
            timeZone: TimeZone(identifier: "America/Sao_Paulo"),
            year: 2026, month: 6, day: 13, hour: endHour))!
        return CalendarEventSnapshot(
            eventIdentifier: id, title: title, start: start, end: end,
            location: link, attendees: attendees)
    }

    @Test("today's remaining meetings surface (Meet link or not); past-ended drop")
    func remainingTodaySurface() {
        let past = event(id: "evt-past", title: "This morning", startHour: 9, endHour: 10)
        let nowish = event(id: "evt-now", title: "Now", startHour: 11, endHour: 13,
            attendees: [.init(name: "Lee Park")])
        let later = event(id: "evt-later", title: "This afternoon", startHour: 15, endHour: 16,
            link: "meet.google.com/abc-defg-hij")
        let rows = UpcomingMeetings.rows(
            from: [past, nowish, later], now: noonSP, userEmail: "me@example.test")
        #expect(rows.map(\.eventIdentifier) == ["evt-now", "evt-later"], "the 09–10 meeting has ended")
        // A meeting with no Meet link still surfaces.
        #expect(rows.contains { $0.eventIdentifier == "evt-now" && $0.meetingCode == nil })
    }

    @Test("a recorded code disappears from the list")
    func recordedDisappears() {
        let later = event(id: "evt-later", title: "Afternoon", startHour: 15, endHour: 16,
            link: "meet.google.com/abc-defg-hij")
        let rows = UpcomingMeetings.rows(
            from: [later], now: noonSP, recordedCodes: ["abc-defg-hij"],
            userEmail: "me@example.test")
        #expect(rows.isEmpty, "an already-recorded code's row disappears")
    }

    @Test("a row's Record action binds the §1 anchor (end + identifier)")
    func rowCarriesAnchor() {
        let later = event(id: "evt-later", title: "Afternoon", startHour: 15, endHour: 16,
            link: "meet.google.com/abc-defg-hij")
        let row = try! #require(
            UpcomingMeetings.rows(from: [later], now: noonSP, userEmail: "me@example.test").first)
        #expect(row.anchor.eventIdentifier == "evt-later")
        #expect(row.anchor.scheduledEnd == later.end)
        #expect(row.offersLaunchAndRecord, "a Meet-linked row also offers Launch & Record")
        #expect(row.source == .meet)
    }

    @Test("the user is self-excluded from the prefilled attendees")
    func selfExcluded() {
        let m = event(id: "evt-m", title: "Team", startHour: 15, endHour: 16,
            attendees: [.init(name: "Me", email: "me@example.test"),
                .init(name: "Robin Cole", email: "robin@example.test")])
        let row = try! #require(
            UpcomingMeetings.rows(from: [m], now: noonSP, userEmail: "me@example.test").first)
        #expect(row.attendeeCount == 1)
        #expect(row.attendees.map(\.name) == ["Robin Cole"])
    }

    @Test("day-rollover trigger fires across a calendar-day boundary")
    func dayRollover() {
        let yesterdayNoon = spCal.date(byAdding: .day, value: -1, to: noonSP)!
        #expect(UpcomingMeetings.dayChanged(from: yesterdayNoon, to: noonSP))
        #expect(!UpcomingMeetings.dayChanged(from: noonSP, to: noonSP.addingTimeInterval(3600)))
    }

    @Test("empty input → empty list (the section collapses, no chrome)")
    func emptyCollapses() {
        #expect(UpcomingMeetings.rows(from: [], now: noonSP, userEmail: "me@example.test").isEmpty)
    }
}
