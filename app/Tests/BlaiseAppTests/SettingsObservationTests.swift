import BlaiseCore
import Foundation
import Observation
import Testing

@testable import BlaiseApp

// Field bug 12/06: while RECORDING, the Settings window degraded (tab icons
// disappeared, awkward loading). Confirmed cause: `captureStatus.state` — the
// recording-timer/indicator property that ticks during a capture — was read in
// `App.body` (the MenuBarExtra label argument and the ⌥⌘R command label). An
// @Observable read in the scene builder makes EVERY tick invalidate the whole
// `App.body`, which re-creates the sibling `Settings { }` scene's `TabView` and
// drops its SF Symbol tab icons (the FB15540812 macOS re-render class). The fix
// confines every `captureStatus.state` read to a leaf view (the menu-bar label
// and the command button), so a tick can only re-render that leaf.
//
// These tests pin the discriminating, headless-checkable invariant with
// Observation's `withObservationTracking`: a `state` tick must NOT invalidate a
// tracker that reads only what the SETTINGS surface depends on, while a tracker
// that reads `state` (the menu-bar label's dependency) MUST be invalidated by
// the same tick. The contrast makes the pin non-vacuous — it proves the tick is
// a real state change, not a no-op the assertion would pass on either way.
@MainActor
struct SettingsObservationTests {

    /// `withObservationTracking`'s `onChange` is `@Sendable`; a `@MainActor`
    /// reference counter lets the closure record an invalidation without
    /// capturing a mutable `var`. The change fires on the actor that performs
    /// the mutation — here the same @MainActor test — so the reads stay safe.
    @MainActor
    private final class InvalidationCounter {
        private(set) var count = 0
        func bump() { count += 1 }
    }

    /// Drive a representative recording-timer tick: the holder's `.tick` input
    /// re-resolves the indicator state the same way the long-session ticker and
    /// every capture lifecycle event do. Started → ticked into the >6h warning
    /// so `state` changes value (the @Observable registrar only fires on an
    /// actual change), making the discriminator meaningful.
    private func startThenLongSessionTick(_ holder: CaptureStatusHolder) {
        let start = Date(timeIntervalSince1970: 0)
        holder.apply(.captureStarted(at: start))
        // A tick past the 6h long-session boundary flips .recording → .warning,
        // a genuine value change to `state`.
        holder.apply(.tick(now: start.addingTimeInterval(6 * 3600 + 60)))
    }

    @Test("A recording-timer tick does NOT invalidate the Settings surface's capture dependency")
    func tickDoesNotInvalidateSettingsDependency() {
        let holder = CaptureStatusHolder()
        // Prime so the first tick produces an observable value change.
        holder.apply(.captureStarted(at: Date(timeIntervalSince1970: 0)))

        // The ONLY `captureStatus` property the Settings scene reads is
        // `notificationsDenied` (AutomationTab's denied banner). Track exactly
        // that — the Settings root and the scene body read no `state`-derived
        // property after the fix.
        let settings = InvalidationCounter()
        withObservationTracking {
            _ = holder.notificationsDenied
        } onChange: {
            MainActor.assumeIsolated { settings.bump() }
        }

        // A recording tick (and a few more, as the live ticker would emit).
        holder.apply(.tick(now: Date(timeIntervalSince1970: 60)))
        holder.apply(.tick(now: Date(timeIntervalSince1970: 6 * 3600 + 60)))
        holder.apply(.tick(now: Date(timeIntervalSince1970: 6 * 3600 + 120)))

        #expect(
            settings.count == 0,
            "A recording-timer tick must not invalidate the Settings scene's only capture dependency; it does only if a `state`-ticking read leaks into a Settings dependency.")
    }

    @Test("The same tick DOES invalidate a `state` reader — the menu-bar label's dependency (non-vacuity control)")
    func tickInvalidatesStateReader() {
        let holder = CaptureStatusHolder()
        holder.apply(.captureStarted(at: Date(timeIntervalSince1970: 0)))

        // The menu-bar label reads `captureStatus.state`. A tick that changes
        // `state` MUST invalidate this tracker — proving the tick is a real
        // state change and the negative test above is discriminating, not
        // vacuously green.
        let stateReads = InvalidationCounter()
        withObservationTracking {
            _ = holder.state
        } onChange: {
            MainActor.assumeIsolated { stateReads.bump() }
        }

        startThenLongSessionTick(holder)

        #expect(
            stateReads.count == 1,
            "A tick that changes the indicator state must invalidate a reader of `captureStatus.state` (the menu-bar label) — exactly once per tracking registration.")
    }

    @Test("`isRecording` reads register a dependency on `state` (why the command button had to move out of App.body)")
    func isRecordingTracksState() {
        let holder = CaptureStatusHolder()
        holder.apply(.captureStarted(at: Date(timeIntervalSince1970: 0)))

        // `isRecording` is `switch state` — reading it registers a dependency on
        // `state`, so the ⌥⌘R command's `isRecording` read (formerly in the
        // scene builder) DID tie `App.body` to the ticking state. This pins WHY
        // the command button had to be isolated into `RecordingMenuCommandButton`.
        let reads = InvalidationCounter()
        withObservationTracking {
            _ = holder.isRecording
        } onChange: {
            MainActor.assumeIsolated { reads.bump() }
        }

        // A tick that flips .recording → .warning keeps `isRecording == true`
        // (both are "recording") yet STILL invalidates: @Observable tracks the
        // accessed property (`state`), not the derived bool's value.
        startThenLongSessionTick(holder)

        #expect(
            reads.count == 1,
            "Reading `isRecording` tracks `state`, so any `state` tick invalidates the reader even when the bool value is unchanged — the reason the command label could not stay in App.body.")
    }
}
