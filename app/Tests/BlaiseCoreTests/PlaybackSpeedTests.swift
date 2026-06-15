import Foundation
import Testing

@testable import BlaiseCore

// Audio-player speed model pins (player playback-speed feature): the rate
// each speed maps to, the tap-to-cycle order, and the saved-value
// resolution (the UserDefaults persistence parsing). The pure model lives
// in core; the AVPlayer wiring (`.spectral` pitch-preserving time-stretch)
// and the SwiftUI pill live in the untestable executable target and are
// verified by build + measured playback.

@Suite struct PlaybackSpeedRateTests {
    @Test func ratesAreOneOneFiveTwo() {
        #expect(PlaybackSpeed.x1.rate == 1.0)
        #expect(PlaybackSpeed.x1_5.rate == 1.5)
        #expect(PlaybackSpeed.x2.rate == 2.0)
    }

    @Test func labelsAreCompactAndTimesGlyph() {
        #expect(PlaybackSpeed.x1.label == "1×")
        #expect(PlaybackSpeed.x1_5.label == "1.5×")
        #expect(PlaybackSpeed.x2.label == "2×")
    }

    @Test func allThreeSpeedsExist() {
        #expect(PlaybackSpeed.allCases.count == 3)
    }
}

@Suite struct PlaybackSpeedCycleTests {
    @Test func cycleAdvancesOneToOneFiveToTwo() {
        #expect(PlaybackSpeed.x1.next == .x1_5)
        #expect(PlaybackSpeed.x1_5.next == .x2)
    }

    @Test func cycleWrapsTwoBackToOne() {
        #expect(PlaybackSpeed.x2.next == .x1)
    }

    @Test func fullCycleVisitsEveryStateThenReturnsToStart() {
        // Non-vacuous (round-1 player L): assert the cycle VISITS every distinct
        // speed before returning to the start, so a fixed-point `next` (return
        // self) — which would also "return to start" — fails this test.
        var s = PlaybackSpeed.x1
        var visited: [PlaybackSpeed] = [s]
        for _ in 0..<PlaybackSpeed.allCases.count { s = s.next; visited.append(s) }
        // Distinct states visited before wrap-around = every case.
        #expect(Set(visited.dropLast()) == Set(PlaybackSpeed.allCases))
        #expect(visited.dropLast().count == PlaybackSpeed.allCases.count)
        #expect(s == .x1)
    }
}

@Suite struct PlaybackSpeedPersistenceTests {
    @Test func savedRawValueRoundTrips() {
        for speed in PlaybackSpeed.allCases {
            #expect(PlaybackSpeed.resolved(saved: speed.rawValue) == speed)
        }
    }

    @Test func nilSavedFallsBackToOneX() {
        #expect(PlaybackSpeed.resolved(saved: nil) == .x1)
    }

    @Test func unrecognizedSavedFallsBackToOneXNeverCrashes() {
        #expect(PlaybackSpeed.resolved(saved: "x3") == .x1)
        #expect(PlaybackSpeed.resolved(saved: "") == .x1)
        #expect(PlaybackSpeed.resolved(saved: "garbage") == .x1)
    }
}
