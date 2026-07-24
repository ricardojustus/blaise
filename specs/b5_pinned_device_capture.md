# B5 — Per-device sub-taps: capture pinned-device meeting audio at the right pitch

Status: briefing draft (written 2026-07-24, from the B4 route-change-resilience verification probes). Build on a feature branch, after B4 merges.

## Purpose

Meeting apps configured with a **manual output-device override** (the user's standing setup: Zoom/Meet pinned to the FiiO or Studio Display rather than "Same as System") play audio to a device that is not the system default. The C11 capture graph records system audio through ONE global process tap, and a probe (below) shows the OS mixes non-default-device audio into that tap **without sample-rate conversion**: the audio arrives pitch-shifted by exactly the rate ratio and attenuated. The corruption is premixed into the single tap stream — no downstream converter can repair it.

The failure story this produces: day-to-day the default output and the pinned meeting device coincide, so recordings are clean. Then something flips the default mid-meeting (AirPods connecting is the classic) while the app stays pinned — from that moment the system track is pitch-warped and quiet, ASR degrades to garbage, and it reads as "the device change broke the capture." B4 made the capture *graph* survive device changes; B5 makes the captured *content* survive them.

## Probed facts (2026-07-24, Darwin 25.4.0 / MacOSX26.5 SDK)

Probe: gated capture harness recording while a 440 Hz fixture played to the DEFAULT output (MacBook speakers, 48 kHz) and a second player rendered 1000 Hz **pinned** to the non-default Studio Display (`kAudioOutputUnitProperty_CurrentDevice` override, engine at 48 kHz). FFT of the system track:

- 440 Hz (default device): full digital strength.
- 1000 Hz: absent. Instead a peak at **918.75 Hz** — exactly 1000 × 44100/48000 — at ~6× lower power (~-8 dB).

Two further drifts from the 10/06/2026 research notes, same probe session:

- **Descendant exclusion is gone.** The global tap now captures audio played by child processes of the capturing process (afplay landed on the system track at digital strength from t=0). The gated test's mic/system tone-discrimination assertion relies on the old behavior and now false-fails — it needs a redesign (different mechanism, or assert on per-band timelines instead of a ratio).
- **`kTCCServiceAudioCapture` was not enforced** for the swiftpm-testing-helper: the tap captured system audio with no grant row in TCC.db. Convenient for headless gated runs today; do not design around it persisting.

These are OS-behavior observations, all dated: re-probe on OS updates before trusting any of them.

## Shape: N device-scoped sub-taps instead of one global tap

The aggregate composition already accepts a **list** of sub-taps (`kAudioAggregateDeviceTapListKey`). Replace the single global tap with one tap per output-capable device, each excluding our own process, each with drift compensation onto the mic clock (the B3 master arrangement, unchanged):

- Enumerate output-capable devices (output stream count > 0) at graph build; create a device-scoped tap per device (`CATapDescription` has device+stream-scoped initializers; probe which form delivers correctly-rated audio for a non-default device — that probe IS the acceptance gate for the whole approach).
- Sub-device list stays exactly as today: the default input device only. `micStreamCount` semantics (streams `[0..<micStreamCount]` are the mic's) are unchanged; everything after the mic streams is now N tap streams instead of one.
- The processing path currently converts ONE system stream (`streamFormats[micStreamCount]`). B5 must convert EACH tap stream through its own converter and **sum** the converted 16 kHz buffers into the single system track (saturating add — two devices playing at once must clip, not wrap).
- Rebuild triggers: B4's debounced rebuild machinery gains a third listener, `kAudioHardwarePropertyDevices` on the system object — device hot-plug/unplug must rebuild the tap list. Storms coalesce and failures retry exactly as B4 built; the gap-fill covers the swap windows.

## Risks / open questions (answer by probe before committing to the shape)

- Does a device-scoped tap deliver correctly-rated audio for a **non-default** device? (The entire premise. If it inherits the same unconverted-mix bug, B5's shape is wrong and the fallback is uglier: pin the tap's format per device and resample per stream ourselves.)
- Tap count ceiling and cost: this machine has 4 output devices; AirPlay/virtual devices may appear and vanish. Per-tap + per-converter cost at 5–6 devices should be measured, and devices with no plausible meeting audio (e.g. the aggregate's own UID prefix, other private aggregates) excluded.
- Self-exclusion per device-scoped tap: the descendant-exclusion drift above suggests exclusion semantics are in flux; verify at least the capturing process itself stays excluded per sub-tap, or Blaise's own alert sounds enter recordings.
- Buffer-order assumption: N taps means the stream order within the tap block must be probed (composition order vs HAL order), same discipline as the original C11 mic-first probe.

## Acceptance criteria

1. Two-tone probe passes: 440 Hz to the default output AND 1000 Hz pinned to a non-default device both land on the system track **at their own frequencies** (no 918.75 Hz image, both within 2 dB of each other after level normalization).
2. Mid-capture default flip (the B4 choreography) with the pinned player running: both tones stay pitch-correct across every rebuild.
3. Device hot-plug (connect/disconnect a device mid-capture) rebuilds the tap list without ending the recording; gap-fill covers the swap.
4. Composition snapshot tests pin the N-tap dictionary form (pure, no TCC), same style as `CaptureDescriptorTests.aggregateComposition`.
5. The gated test's discrimination assertion is redesigned to hold under current OS semantics (no reliance on descendant exclusion).
