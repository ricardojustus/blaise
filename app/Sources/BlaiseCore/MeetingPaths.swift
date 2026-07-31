import Foundation

/// Owns the per-meeting file layout under the Blaise data root:
///
///     <root>/meetings/<ulid>/
///       audio.m4a                    retained recording (never deleted/overwritten by BlaiseCore)
///       audio_mic.m4a                retained mic track (captured meetings, C11; same contract)
///       capture_system.caf           crash-safe LPCM capture track (during/just after recording)
///       capture_mic.caf              crash-safe LPCM capture track (during/just after recording)
///       raw_asr.json                 immutable raw engine output (raw_asr_mic.json for the mic pass)
///       transcript.json              DB export artifact (regenerated, never read back)
///       notes.md                     human artifact export
///       handoff/<version_hash>.json  immutable content-addressed payload snapshots
///
/// Retention guarantee: `MeetingPaths` provides no removal helper, and no
/// BlaiseCore API deletes or overwrites `audio*.m4a`. During capture the
/// `capture_*.caf` files are retention-class artifacts: their deletion
/// happens ONLY through the single audited verified-encode function
/// (`CaptureRecovery.encodeVerifiedAndRelease`) after the encoded m4a passes
/// its verification decode (C1 v6.5 amendment).
/// The two capture tracks of a recorded meeting (C11).
public enum CaptureTrack: String, Sendable, CaseIterable, Codable {
    /// The process-tap (system audio) track → `audio.m4a` (the C1 primary).
    case system
    /// The microphone track → `audio_mic.m4a`.
    case mic

    /// The retained destination this track encodes into at stop/recovery.
    public func retainedURL(_ paths: MeetingPaths, meetingID: MeetingID) -> URL {
        switch self {
        case .system: return paths.audioURL(meetingID)
        case .mic: return paths.audioMicURL(meetingID)
        }
    }

    /// Part-suffixed retained destination (C14 multi-part capture): part 1
    /// keeps today's unsuffixed names; part n ≥ 2 → `audio_n.m4a` /
    /// `audio_mic_n.m4a` (still `audio*.m4a` — the retention contract covers
    /// every part by construction).
    public func retainedURL(_ paths: MeetingPaths, meetingID: MeetingID, part: Int) -> URL {
        switch self {
        case .system: return paths.audioURL(meetingID, part: part)
        case .mic: return paths.audioMicURL(meetingID, part: part)
        }
    }
}

public struct MeetingPaths: Sendable {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    public var meetingsDirectory: URL {
        rootURL.appendingPathComponent("meetings", isDirectory: true)
    }

    /// The user glossary file (G1 §2): `<dataRoot>/Glossary.md`. Provisioned on
    /// first launch (§4) and edited by the Settings Glossary tab (§6).
    public var glossaryURL: URL {
        rootURL.appendingPathComponent("Glossary.md")
    }

    /// The optional per-install C5 suppression supplement:
    /// `<dataRoot>/stoplist_user.txt`. A plain word-per-line file (the deploy
    /// step may write project terms here); absent on a fresh install, where the
    /// bundled empty `stoplist_user.txt` and the per-glossary suppression
    /// augmentation are the whole suppression input.
    public var userStoplistURL: URL {
        rootURL.appendingPathComponent("stoplist_user.txt")
    }

    public func meetingDirectory(_ meetingID: MeetingID) -> URL {
        // Defense against path traversal: meeting ids are always ULIDs we
        // generated; anything else (e.g. containing "/" or "..") is a
        // programmer error, not an input to sanitize (impl audit F5).
        precondition(ULID.isValid(meetingID), "meeting id is not a ULID: \(meetingID)")
        return meetingsDirectory.appendingPathComponent(meetingID, isDirectory: true)
    }

    /// Primary system/mixed retained track. C11 may add a second synced
    /// track (e.g. `audio_mic.m4a`); adding a file here is additive — the
    /// retention contract covers every `audio*.m4a`.
    public func audioURL(_ meetingID: MeetingID) -> URL {
        meetingDirectory(meetingID).appendingPathComponent("audio.m4a")
    }

    /// Lossless import copy (file-first ingest, C7): owned the moment a WAV
    /// is imported; deleted ONLY after the encoded `audio.m4a` passes the
    /// verification decode (hard floor 2).
    public func importCopyURL(_ meetingID: MeetingID) -> URL {
        meetingDirectory(meetingID).appendingPathComponent("import.wav")
    }

    /// Retained mic track of a captured meeting (C11) — additive; the
    /// retention contract covers every `audio*.m4a`. Its presence is the
    /// two-track dispatch key (C7 v3.2: regenerate/process of a captured
    /// meeting must never be halved by the single-track path).
    public func audioMicURL(_ meetingID: MeetingID) -> URL {
        meetingDirectory(meetingID).appendingPathComponent("audio_mic.m4a")
    }

    /// Crash-safe in-flight capture track (LPCM Int16 16 kHz mono CAF —
    /// the ONLY probed format that survives kill -9). Deleted exclusively by
    /// the audited verified-encode function.
    public func captureCAFURL(_ meetingID: MeetingID, track: CaptureTrack) -> URL {
        meetingDirectory(meetingID).appendingPathComponent("capture_\(track.rawValue).caf")
    }

    // MARK: - Part-suffixed variants (C14 resume grace / multi-part capture)

    /// Part n of a captured track: part 1 = today's unsuffixed names (zero
    /// churn for the single-part case); part n ≥ 2 = `capture_system_n.caf`.
    /// `capture_*_<n>.caf` files are retention-class identically to part 1
    /// (C1 amendment): deleted ONLY by the audited verified-encode function
    /// or the zero-frame-stub rule.
    public func captureCAFURL(_ meetingID: MeetingID, track: CaptureTrack, part: Int) -> URL {
        precondition(part >= 1, "part index is 1-based")
        guard part > 1 else { return captureCAFURL(meetingID, track: track) }
        return meetingDirectory(meetingID)
            .appendingPathComponent("capture_\(track.rawValue)_\(part).caf")
    }

    /// Retained system track of part n (`audio.m4a` / `audio_2.m4a`, …).
    public func audioURL(_ meetingID: MeetingID, part: Int) -> URL {
        precondition(part >= 1, "part index is 1-based")
        guard part > 1 else { return audioURL(meetingID) }
        return meetingDirectory(meetingID).appendingPathComponent("audio_\(part).m4a")
    }

    /// Retained mic track of part n (`audio_mic.m4a` / `audio_mic_2.m4a`, …).
    public func audioMicURL(_ meetingID: MeetingID, part: Int) -> URL {
        precondition(part >= 1, "part index is 1-based")
        guard part > 1 else { return audioMicURL(meetingID) }
        return meetingDirectory(meetingID).appendingPathComponent("audio_mic_\(part).m4a")
    }

    /// The retained audio set of a meeting (G5 v1.3 audio delivery = exactly the
    /// C1 retention set): every `audio*.m4a` in the meeting dir — the system
    /// track (`audio.m4a`), the mic track (`audio_mic.m4a`), and any
    /// part-suffixed files (`audio_2.m4a`, `audio_mic_2.m4a`, …). Sorted by name
    /// for a stable delivery order. Empty when the dir has none or is absent. The
    /// lossless `import.wav` is deliberately excluded (not an `*.m4a`).
    public func retainedAudioURLs(_ meetingID: MeetingID) -> [URL] {
        let dir = meetingDirectory(meetingID)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return [] }
        return names
            .filter { $0.hasPrefix("audio") && $0.hasSuffix(".m4a") }
            .sorted()
            .map { dir.appendingPathComponent($0) }
    }

    public func rawASRURL(_ meetingID: MeetingID) -> URL {
        meetingDirectory(meetingID).appendingPathComponent("raw_asr.json")
    }

    /// Raw engine output of the mic-track ASR pass (captured meetings).
    public func rawASRMicURL(_ meetingID: MeetingID) -> URL {
        meetingDirectory(meetingID).appendingPathComponent("raw_asr_mic.json")
    }

    /// The system-track diarization output of the FIRST processing run,
    /// persisted so `regenerate()` reuses it instead of re-running the
    /// nondeterministic diarizer (FluidAudio clustering shifts turn
    /// boundaries run-to-run, which moves speaker-name votes and can drop
    /// names that durable Meet events had attached — field exhibit,
    /// "Futuro do Vexatron"). Reuse makes speaker naming deterministic and
    /// idempotent across regenerations. Absent for meetings processed before
    /// this artifact existed → regenerate falls back to a fresh diarize.
    public func diarizationURL(_ meetingID: MeetingID) -> URL {
        meetingDirectory(meetingID).appendingPathComponent("diarization.json")
    }

    public func captureFactsURL(_ meetingID: MeetingID) -> URL {
        meetingDirectory(meetingID).appendingPathComponent("capture_facts.json")
    }

    public func roomTreatmentURL(_ meetingID: MeetingID) -> URL {
        meetingDirectory(meetingID).appendingPathComponent("room_treatment.json")
    }

    public var voiceProfileDirectory: URL {
        rootURL.appendingPathComponent("voice_profile", isDirectory: true)
    }

    public func transcriptURL(_ meetingID: MeetingID) -> URL {
        meetingDirectory(meetingID).appendingPathComponent("transcript.json")
    }

    public func notesURL(_ meetingID: MeetingID) -> URL {
        meetingDirectory(meetingID).appendingPathComponent("notes.md")
    }

    public func handoffDirectory(_ meetingID: MeetingID) -> URL {
        meetingDirectory(meetingID).appendingPathComponent("handoff", isDirectory: true)
    }

    public func handoffPayloadURL(meetingID: MeetingID, versionHash: String) -> URL {
        handoffDirectory(meetingID).appendingPathComponent("\(versionHash).json")
    }

    /// Path of a handoff payload relative to the data root — the form stored
    /// in `handoff_queue.payload_path`.
    public func relativeHandoffPayloadPath(meetingID: MeetingID, versionHash: String) -> String {
        precondition(ULID.isValid(meetingID), "meeting id is not a ULID: \(meetingID)")
        // Traversal guard only — strict hex validation is the producer's job
        // (C7 computes real SHA-256 digests; see isValidVersionHash).
        precondition(!versionHash.isEmpty && !versionHash.contains("/") && !versionHash.contains(".."),
                     "version hash must not contain path components")
        return "meetings/\(meetingID)/handoff/\(versionHash).json"
    }

    /// SHA-256 hex digest: exactly 64 lowercase hex characters. (Strict form
    /// for payload producers/deliverers — C7/C8.)
    public static func isValidVersionHash(_ hash: String) -> Bool {
        hash.count == 64 && hash.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// Creates the meeting directory (including the handoff subdirectory).
    @discardableResult
    public func createMeetingDirectory(_ meetingID: MeetingID) throws -> URL {
        let dir = meetingDirectory(meetingID)
        try FileManager.default.createDirectory(at: handoffDirectory(meetingID), withIntermediateDirectories: true)
        return dir
    }
}
