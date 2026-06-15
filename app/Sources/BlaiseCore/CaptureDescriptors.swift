import CoreAudio
import Foundation

// C11: tap + aggregate construction recipes (research/c11_capture.md §1,
// swiftc-verified against the MacOSX26.5 SDK; validated call sequence). These
// are PURE descriptor builders — no HAL device is created here, so unit
// tests can snapshot the exact parameter forms without touching audio
// hardware or firing TCC prompts. `CaptureSession` feeds the results to
// `AudioHardwareCreateProcessTap` / `AudioHardwareCreateAggregateDevice`.

public enum CaptureDescriptors {
    /// Aggregate-device UID prefix — the stale-aggregate cleanup at launch
    /// destroys any leftover device whose UID carries it (a crashed
    /// session's aggregate lingers; the stale-device cleanup pattern).
    public static let aggregateUIDPrefix = BlaiseBundle.identifier + "."

    public static let tapName = "Blaise capture tap"
    public static let aggregateName = "Blaise Capture"

    /// The global process tap: mono mixdown of everything EXCEPT ourselves
    /// (`selfAudioObjectID` = the HAL AudioObjectID resolved from our PID —
    /// the API takes AudioObjectIDs, NOT raw PIDs; research §1). The mono
    /// initializer COMPILES against the SDK but its runtime behavior is
    /// unprobed: the capture path converts whatever `kAudioTapPropertyFormat`
    /// reports to 16 kHz mono, so a tap that turns out stereo downmixes
    /// through the same converter (the probed fallback, built in).
    public static func tapDescription(excludingSelf selfAudioObjectID: AudioObjectID) -> CATapDescription {
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: [selfAudioObjectID])
        description.name = tapName
        description.isPrivate = true
        description.muteBehavior = CATapMuteBehavior.unmuted
        return description
    }

    /// The aggregate composition (the research recipe): default input device
    /// as a sub-device AND the tap as a sub-tap in the SAME aggregate, drift
    /// compensation on BOTH entries against the aggregate clock → one IOProc
    /// delivers mic and system buffers sample-aligned by construction.
    /// `tapUID` is the tap's UUID STRING (passing CATapDescription objects
    /// crashes CoreAudio — capture note).
    public static func aggregateComposition(
        tapUID: String, inputDeviceUID: String, aggregateUID: String
    ) -> [String: Any] {
        [
            kAudioAggregateDeviceNameKey as String: aggregateName,
            kAudioAggregateDeviceUIDKey as String: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [
                    kAudioSubDeviceUIDKey as String: inputDeviceUID,
                    kAudioSubDeviceDriftCompensationKey as String: true,
                ]
            ],
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: tapUID,
                    kAudioSubTapDriftCompensationKey as String: true,
                ]
            ],
            // FALSE, deliberately (root-caused 10/06/2026): with tap
            // auto-start, the WHOLE aggregate's IO — mic sub-device
            // included — waits for "the first tap that receives audio"
            // (SDK doc; coreaudiod logs "waiting for writers"). On a
            // machine where no process is playing audio, NOTHING is
            // captured on either track (an in-person meeting on a quiet
            // system would record no mic audio at all). IO must start
            // immediately; the tap delivers silence until something plays.
            kAudioAggregateDeviceTapAutoStartKey as String: false,
        ]
    }

    /// Fresh aggregate UID for one capture session.
    public static func makeAggregateUID() -> String {
        aggregateUIDPrefix + UUID().uuidString
    }
}
