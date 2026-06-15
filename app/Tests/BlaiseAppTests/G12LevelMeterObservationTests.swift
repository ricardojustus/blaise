import BlaiseCore
import Foundation
import Observation
import Testing

@testable import BlaiseApp

// G12 §2 AC4 — leaf-observation isolation for the level meter, the audio analog
// of the recording-tick fix (SettingsObservationTests). A ≤ 10 Hz level publish
// into `LevelMeterHolder.levels` must invalidate ONLY a reader of `levels` (the
// meter view), never a tracker reading something else (the proxy for the scene
// root / Settings surface, which must NOT re-render on every level frame). The
// positive control proves the publish is a real change, so the negative test is
// non-vacuous.
@MainActor
struct G12LevelMeterObservationTests {

    @MainActor
    private final class InvalidationCounter {
        private(set) var count = 0
        func bump() { count += 1 }
    }

    @Test("a level publish invalidates a `levels` reader (the meter view's dependency)")
    func publishInvalidatesLevelsReader() {
        let holder = LevelMeterHolder()
        let reads = InvalidationCounter()
        withObservationTracking {
            _ = holder.levels
        } onChange: {
            MainActor.assumeIsolated { reads.bump() }
        }
        // A genuine value change (a non-silent "you" channel).
        holder.levels = MeterLevels(you: ChannelLevel(level: 0.7, silent: false))
        #expect(
            reads.count == 1,
            "a level publish must invalidate the meter view's `levels` dependency exactly once per registration")
    }

    @Test("a level publish does NOT invalidate a tracker that reads an unrelated holder (scene-root isolation)")
    func publishDoesNotInvalidateUnrelatedObservation() {
        let meter = LevelMeterHolder()
        // The scene root / Settings surface depends on OTHER holders, never on
        // `meter.levels`. Track a different @Observable's property and prove a
        // level publish leaves it untouched — the FB15540812 re-render the
        // recording timer once triggered must not return through the meter.
        let capture = CaptureStatusHolder()
        let sceneRoot = InvalidationCounter()
        withObservationTracking {
            _ = capture.notificationsDenied
        } onChange: {
            MainActor.assumeIsolated { sceneRoot.bump() }
        }

        // Several level publishes (as the live meter would emit at ≤ 10 Hz).
        meter.levels = MeterLevels(you: ChannelLevel(level: 0.2, silent: false))
        meter.levels = MeterLevels(you: ChannelLevel(level: 0.5, silent: false))
        meter.levels = MeterLevels(others: ChannelLevel(level: 0.0, silent: true))

        #expect(
            sceneRoot.count == 0,
            "a level publish must not invalidate any observation that does not read `meter.levels`")
    }

    @Test("reset publishes a fresh silent pair — observable by the meter view")
    func resetPublishesFreshPair() {
        let holder = LevelMeterHolder()
        holder.levels = MeterLevels(you: ChannelLevel(level: 0.9, silent: false))
        let reads = InvalidationCounter()
        withObservationTracking {
            _ = holder.levels
        } onChange: {
            MainActor.assumeIsolated { reads.bump() }
        }
        holder.reset()
        #expect(reads.count == 1)
        #expect(holder.levels == MeterLevels())
    }
}
