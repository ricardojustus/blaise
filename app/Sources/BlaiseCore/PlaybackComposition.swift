import Foundation

// Player composition planning (field bug 2026-06-12: the in-app player played
// ONLY audio.m4a — the system track — so the user's own voice, captured to
// audio_mic.m4a, was inaudible on playback even though it is plainly present
// in the transcript and notes). The fix mixes BOTH retained tracks into one
// AVMutableComposition, time-aligned with the SAME per-part offsets the
// transcode-stage stitcher uses, so the player timeline matches the transcript
// timeline exactly (a transcript segment's start_seconds lands on the same
// audio in the player).
//
// This file is the PURE, unit-tested half: it turns the enumerated parts
// (CaptureStitcher.PlannedPart, the DB-rows ∪ disk-residue truth) into a flat
// list of track placements (which file, which track, at what timeline offset).
// The AVMutableComposition wiring that consumes a plan lives in the executable
// target (AudioPlayerController) and is verified by build + measured playback.

extension CaptureStitcher {
    /// Linear gain applied to every SYSTEM (other-side) track in the playback
    /// mix so the user's own mic is not buried (mix-balance fix, 2026-06-12).
    ///
    /// Field measurement on the real meeting (offline RMS, see
    /// audits/playback/r1_fix_neuter_checks.md): active-segment loudness was
    /// mic (the user) median ≈ −34 dBFS vs system (the others) median ≈ −21
    /// dBFS — a ~12.6 dB gap (the auditor measured 12.9 dB on solo segments,
    /// 17.0 dB overall). The mic CANNOT be boosted — AVAudioMix volume is 0…1
    /// and the mic already plays at unity — so the gap is closed by lowering
    /// the system track. 0.35 ≈ −9.1 dB drops the residual active-segment gap
    /// to ≈ 4.0 dB (within the ≤6 dB target) while keeping the other side
    /// comfortably audible (system median ≈ −30 dBFS post-gain). The mic is
    /// never touched, so the user's own voice is preserved bit-for-bit.
    public static let systemTrackPlaybackGain: Float = 0.35

    /// Trusted range for a track's `wallSpan / fileDuration` time-scale (L-4).
    /// Genuine clock drift is the capture converter ratio class — 48000/44100 ≈
    /// 1.088 and its inverse ≈ 0.919 — so a scale well outside this band is a
    /// pathological part row (a derived-close span far from the file's true
    /// length), not drift; such a row is distrusted (unity + `scaleKnown` false),
    /// dropping a multi-track meeting to single-track playback rather than
    /// stretching audio to an absurd duration. The band has comfortable margin
    /// around the ±8.8% real drift.
    public static let timeScaleSanityBand: ClosedRange<Double> = 0.85...1.18

    /// One file placed on the playback timeline: a retained part m4a, the track
    /// it belongs to, the absolute REAL-TIME start offset (seconds) it begins
    /// at, and `timeScale` — the factor each file SECOND is stretched by so the
    /// file's frame clock maps onto real (wall-clock) time.
    ///
    /// Alignment ground truth (field-corrected 2026-06-12; the earlier
    /// "both tracks share t=0 and play at their own length" assumption was
    /// FALSIFIED — the mic and system m4as of a single part drift apart by a
    /// ~1.088 factor, so playing each at its own duration left the user's
    /// voice progressively out of sync with the others, up to ~110 s by the
    /// end of a 26-minute meeting):
    /// - The two tracks share one REAL-TIME axis, not one frame axis. Capture's
    ///   aggregate device runs the mic sub-device and the system tap on
    ///   independent clocks; their per-track converters resample by nominal
    ///   ratios, so each retained file accumulates frames at a rate that drifts
    ///   from wall-clock (measured: one track ≈ wall-clock, the other ≈ 1.088×,
    ///   and WHICH track drifts is per-recording). The part's recorded
    ///   wall-clock span (`wallSpanMs = endedAtMs − startedAtMs`) is the shared
    ///   truth; each track is stretched by `wallSpan / fileDuration` so its file
    ///   plays in real time. With a track at ≈1.0 and its sibling at ≈1.088,
    ///   this is the per-track anchor that re-aligns them (verified offline on
    ///   real meetings: mean cross-track error drops from +55 s to ≈0 s).
    /// - ACROSS parts (C14), part n begins at the real-time offset
    ///   `startedAtMs − anchorMs`. Row-less residue (offsetMs nil) appends after
    ///   the END of the prior audio on its track (the real-time frontier) with
    ///   no inserted gap.
    ///
    /// When a part has no closed row (`wallSpanMs == nil`) or a file's duration
    /// is unknown, the cross-track scale cannot be trusted; the caller drops to
    /// single-track playback (the user's rule: out-of-sync is worse than one track),
    /// gated by `playbackScalingTrustworthy`.
    public struct PlaybackPlacement: Sendable, Equatable {
        public let track: CaptureTrack
        public let url: URL
        public let startSeconds: Double
        /// Real seconds per file second (`wallSpan / fileDuration`). 1.0 when
        /// the file already runs at wall-clock or no span/duration is known.
        public let timeScale: Double
        /// True iff `timeScale` was derived from a real wall-clock span (not
        /// the unity fallback). The trust gate keys on THIS, not the scale
        /// value — a track genuinely at wall-clock has scale ≈ 1.0 yet is still
        /// span-grounded and safe to mix.
        public let scaleKnown: Bool

        public init(
            track: CaptureTrack, url: URL, startSeconds: Double,
            timeScale: Double = 1.0, scaleKnown: Bool = false
        ) {
            self.track = track
            self.url = url
            self.startSeconds = startSeconds
            self.timeScale = timeScale
            self.scaleKnown = scaleKnown
        }
    }

    /// Turns enumerated parts into timeline placements for the player. Pure over
    /// its input (the `plan(database:meetingID:)` output plus per-file
    /// durations), so it is unit-tested directly with synthetic parts.
    ///
    /// Row-less residue (offsetMs nil) appends after the running maximum END of
    /// the material already placed ON THAT TRACK, in part order, with no
    /// inserted gap — mirroring `stitchTrack` exactly: there, a `offsetMs == nil`
    /// source appends at the current `emitted` (the end of all audio written so
    /// far on that track), so a residue part lands AFTER the prior part's audio,
    /// not over it. The player needs each file's real duration to know that end,
    /// so `durations` maps placement URLs to seconds (the composition loader
    /// already reads `.duration` per file). A duration missing for a placed file
    /// is treated as 0 — the residue then stacks at the prior part's start,
    /// the old behaviour, rather than crashing; in practice every anchored part
    /// before a residue carries a readable file.
    ///
    /// Per-track asymmetry (worth noting, like the stitcher's): system and mic
    /// are stitched independently, so each track's residue frontier is that
    /// track's own running end. A residue mic part can therefore start at a
    /// different time than its sibling residue system part when the two tracks
    /// had different prior durations — matching the two separate `stitchTrack`
    /// calls the transcript timeline is built from.
    public static func playbackPlacements(
        parts: [PlannedPart], durations: [URL: Double] = [:]
    ) -> [PlaybackPlacement] {
        var placements: [PlaybackPlacement] = []
        // Per-track frontier: the END (start + REAL duration) of the latest
        // material already placed on that track. A row-less residue part appends
        // here. Real duration = the part's wall-clock span (a file's own length
        // is the drifted frame clock, not real time), falling back to the file
        // duration when no span is known.
        var frontier: [CaptureTrack: Double] = [:]
        for part in parts.sorted(by: { $0.index < $1.index }) {
            for (track, url) in [(CaptureTrack.system, part.systemM4A), (.mic, part.micM4A)] {
                guard let url else { continue }
                let fileDuration = durations[url] ?? 0
                // Stretch this track's file onto the part's real-time span so
                // both tracks share one wall-clock axis. Only with a known span
                // AND a readable, positive file duration; otherwise unity (the
                // single-track-fallback gate keeps a drifted pair from playing).
                let timeScale: Double
                let realDuration: Double
                let scaleKnown: Bool
                if let wallSpanMs = part.wallSpanMs, fileDuration > 0,
                    case let candidate = Double(wallSpanMs) / 1000.0 / fileDuration,
                    Self.timeScaleSanityBand.contains(candidate)
                {
                    // L-4 sanity band: the real per-track drift is the converter
                    // ratio class (48000/44100 ≈ 1.088 and its inverse ≈ 0.919).
                    // A scale OUTSIDE [0.85, 1.18] means a pathological closed row
                    // (e.g. a derived-close span far from the file's real length),
                    // not genuine clock drift — distrust it (unity + scaleKnown
                    // false) so the multi-track gate drops to single-track rather
                    // than stretching a track to an absurd duration.
                    timeScale = candidate
                    realDuration = Double(wallSpanMs) / 1000.0
                    scaleKnown = true
                } else {
                    timeScale = 1.0
                    realDuration = fileDuration
                    scaleKnown = false
                }
                let start: Double
                if let offsetMs = part.offsetMs {
                    start = Double(offsetMs) / 1000.0  // real-time anchor
                } else {
                    start = frontier[track] ?? 0  // residue: end of prior audio
                }
                placements.append(
                    .init(
                        track: track, url: url, startSeconds: start,
                        timeScale: timeScale, scaleKnown: scaleKnown))
                frontier[track] = max(frontier[track] ?? 0, start + realDuration)
            }
        }
        return placements
    }

    /// Whether the per-track real-time scaling can be trusted enough to mix
    /// BOTH tracks. Cross-track sync depends on every contributing part having
    /// a closed wall-clock span and every placed file a readable duration; if
    /// any is missing, the tracks' relative drift is unknown and mixing them
    /// risks the out-of-sync playback the user reported. In that case the caller
    /// plays a single track instead (the user's rule: out-of-sync is worse than a
    /// missing track). A single-track plan (one file, e.g. imported or a
    /// system-only capture) is always trustworthy — there is nothing to
    /// mis-align against.
    public static func playbackScalingTrustworthy(
        placements: [PlaybackPlacement]
    ) -> Bool {
        let tracks = Set(placements.map(\.track))
        guard tracks.count > 1 else { return true }
        // Every multi-track placement must carry a span-derived scale; a single
        // missing span (open/derived part, unreadable file) makes the tracks'
        // relative drift unknown and mixing them risks the out-of-sync playback.
        return placements.allSatisfy(\.scaleKnown)
    }
}
