import BlaiseCore
import Foundation
import Testing

@testable import BlaiseApp

/// Pins the menu-bar glyph mapping in `StatusBarController.symbolName`, including
/// the audit-H-1 regression: a handoff-warning badge must never mask the
/// load-bearing recording / warning / alarm glyphs.
@MainActor
struct StatusBarGlyphTests {
    private let t = Date(timeIntervalSinceReferenceDate: 0)

    @Test("a handoff warning never masks the recording/warning/alarm glyph (H-1)")
    func handoffBadgeNeverMasksLoudStates() {
        // The regression guard: an `.alarm` is a post-stop capture failure
        // ("recording may be lost") — the handoff badge must NOT replace it.
        #expect(
            StatusBarController.symbolName(for: .alarm(message: "x"), handoffWarning: true)
                == "exclamationmark.triangle.fill")
        #expect(
            StatusBarController.symbolName(for: .recording(startedAt: t), handoffWarning: true)
                == "record.circle")
        #expect(
            StatusBarController.symbolName(for: .warning(startedAt: t, message: "x"), handoffWarning: true)
                == "exclamationmark.circle")
    }

    @Test("a handoff warning badges the genuinely-quiet states")
    func handoffBadgeShowsInQuietStates() {
        #expect(StatusBarController.symbolName(for: .idle, handoffWarning: true) == "exclamationmark.triangle")
        #expect(StatusBarController.symbolName(for: .processing, handoffWarning: true) == "exclamationmark.triangle")
        #expect(
            StatusBarController.symbolName(for: .grace(meetingTitle: "m", until: t), handoffWarning: true)
                == "exclamationmark.triangle")
        #expect(
            StatusBarController.symbolName(for: .paused(meetingTitle: "m", accumulatedSeconds: 0), handoffWarning: true)
                == "exclamationmark.triangle")
    }

    @Test("base glyph per state with no handoff warning")
    func baseGlyphs() {
        #expect(StatusBarController.symbolName(for: .idle, handoffWarning: false) == "waveform.circle")
        #expect(StatusBarController.symbolName(for: .recording(startedAt: t), handoffWarning: false) == "record.circle")
        #expect(StatusBarController.symbolName(for: .warning(startedAt: t, message: "x"), handoffWarning: false) == "exclamationmark.circle")
        #expect(StatusBarController.symbolName(for: .alarm(message: "x"), handoffWarning: false) == "exclamationmark.triangle.fill")
        #expect(StatusBarController.symbolName(for: .processing, handoffWarning: false) == "arrow.triangle.2.circlepath.circle")
        #expect(StatusBarController.symbolName(for: .grace(meetingTitle: "m", until: t), handoffWarning: false) == "pause.circle")
        #expect(StatusBarController.symbolName(for: .paused(meetingTitle: "m", accumulatedSeconds: 0), handoffWarning: false) == "pause.circle.fill")
    }

    @Test("a detected meeting is visible in actionable quiet states")
    func detectedMeetingGlyph() {
        #expect(
            StatusBarController.symbolName(
                for: .idle, handoffWarning: false, meetingDetected: true)
                == "video.circle.fill")
        #expect(
            StatusBarController.symbolName(
                for: .processing, handoffWarning: true, meetingDetected: true)
                == "video.circle.fill")
        // Never mask the load-bearing live-recording state.
        #expect(
            StatusBarController.symbolName(
                for: .recording(startedAt: t), handoffWarning: false,
                meetingDetected: true) == "record.circle")
        // A paused meeting must be resolved before another recording starts.
        #expect(
            StatusBarController.symbolName(
                for: .paused(meetingTitle: "m", accumulatedSeconds: 1),
                handoffWarning: false, meetingDetected: true) == "pause.circle.fill")
    }

    @Test("idle status item title shows the next upcoming meeting compactly")
    func upcomingTitle() {
        let start = Date(timeIntervalSince1970: 1_781_150_400)
        let row = UpcomingMeetingRow(
            eventIdentifier: "evt-next",
            title: "Very Long Calendar Meeting Title",
            start: start,
            end: start.addingTimeInterval(1800),
            attendeeCount: 2,
            source: .meet,
            meetingCode: "abc-defg-hij",
            attendees: [],
            urlString: "https://meet.google.com/abc-defg-hij")

        let title = StatusBarController.upcomingTitle(
            [row], now: start.addingTimeInterval(-60))

        #expect(title?.contains("Very Long Calenda") == true)
        #expect((title?.count ?? 0) <= 24)
        #expect(
            StatusBarController.upcomingTitle([row], now: row.end.addingTimeInterval(1)) == nil)
    }

    @Test("the custom Blaise mark keeps one identity while state treatments change")
    func coherentVisualStates() {
        #expect(
            BlaiseStatusIcon.visualState(
                for: .idle, handoffWarning: false, meetingDetected: false) == .idle)
        #expect(
            BlaiseStatusIcon.visualState(
                for: .idle, handoffWarning: false, meetingDetected: true) == .meetingDetected)
        #expect(
            BlaiseStatusIcon.visualState(
                for: .recording(startedAt: t), handoffWarning: true,
                meetingDetected: true) == .recording)
        #expect(
            BlaiseStatusIcon.visualState(
                for: .paused(meetingTitle: "m", accumulatedSeconds: 1),
                handoffWarning: false, meetingDetected: false) == .paused)
        #expect(
            BlaiseStatusIcon.visualState(
                for: .processing, handoffWarning: true,
                meetingDetected: false) == .handoffWarning)
    }

}
