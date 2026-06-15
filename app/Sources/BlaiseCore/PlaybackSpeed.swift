import Foundation

// Playback-speed model for the meeting-detail audio player. The pure enum —
// its rate values, the 1× → 1.5× → 2× → 1× cycle, and the saved-value
// resolution — lives in CORE (not the BlaiseApp executable) so the speed
// math and persistence parsing are pure functions under unit test; the
// app's `PlaybackSpeedStore` (UserDefaults, the `DesignSelection` idiom) and
// the `AudioPlayerController` (AVPlayer rate + `.spectral` time-stretch)
// consume it.
//
// Speedup is pitch-PRESERVING: the player sets `audioTimePitchAlgorithm =
// .spectral`, so voices at 1.5×/2× stay naturally pitched rather than
// chipmunking (which `.varispeed` would do, and which is the failure this
// model is built to avoid).

public enum PlaybackSpeed: String, CaseIterable, Sendable {
    case x1
    case x1_5
    case x2

    /// The AVPlayer rate this speed maps to.
    public var rate: Float {
        switch self {
        case .x1: return 1.0
        case .x1_5: return 1.5
        case .x2: return 2.0
        }
    }

    /// Compact control label ("1×", "1.5×", "2×").
    public var label: String {
        switch self {
        case .x1: return "1×"
        case .x1_5: return "1.5×"
        case .x2: return "2×"
        }
    }

    /// Next speed in the tap-to-cycle order (wraps 2× → 1×).
    public var next: PlaybackSpeed {
        let all = PlaybackSpeed.allCases
        let i = all.firstIndex(of: self)!
        return all[(i + 1) % all.count]
    }

    /// The saved speed, or 1× when nothing valid is stored. An unrecognized
    /// value never crashes and never half-applies — it falls through to 1×.
    public static func resolved(saved: String?) -> PlaybackSpeed {
        saved.flatMap(PlaybackSpeed.init(rawValue:)) ?? .x1
    }
}
