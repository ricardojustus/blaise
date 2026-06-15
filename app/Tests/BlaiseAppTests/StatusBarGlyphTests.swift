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
}
