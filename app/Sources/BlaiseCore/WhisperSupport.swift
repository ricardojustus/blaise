import CryptoKit
import Foundation
import os

// Support types for MLXWhisperEngine: driver-JSON decoding, model-cache
// integrity + suspect/repair state, venv layout + sentinel predicates,
// cross-process file lock, orphan sweep, disk-space probe.

// MARK: - Driver output

/// The single JSON document `whisper_driver.py` writes to stdout.
/// `no_speech_prob`/`avg_logprob` ride along for `rawPayload` consumers
/// (gating is BACKLOG); only start/end/text/words become `ASRSegment`s.
struct WhisperDriverOutput: Decodable {
    struct Segment: Decodable {
        // start/end are optional because the driver nulls NON-FINITE values
        // (NaN/Inf from mlx-whisper) rather than emit invalid JSON; a segment
        // or word without finite timing is garbage and is dropped below.
        var start: Double?
        var end: Double?
        var text: String
        var noSpeechProb: Double?
        var avgLogprob: Double?
        var words: [Word]?

        enum CodingKeys: String, CodingKey {
            case start, end, text, words
            case noSpeechProb = "no_speech_prob"
            case avgLogprob = "avg_logprob"
        }
    }

    struct Word: Decodable {
        var word: String
        var start: Double?
        var end: Double?
    }

    var text: String
    var language: String?
    var segments: [Segment]

    var asrSegments: [ASRSegment] {
        segments.compactMap { segment in
            guard let start = segment.start, let end = segment.end else { return nil }
            // Words do NOT necessarily tile the segment text: null-timed words
            // are dropped here. An emptied list normalizes to nil so consumers
            // see exactly two states — usable words or none (impl audit M2;
            // C4 treats nil as its per-segment degenerate path).
            let words = segment.words.map { list in
                list.compactMap { word -> ASRWord? in
                    guard let ws = word.start, let we = word.end else { return nil }
                    return ASRWord(word: word.word, startSeconds: ws, endSeconds: we)
                }
            }
            return ASRSegment(
                startSeconds: start,
                endSeconds: end,
                text: segment.text,
                words: (words?.isEmpty == true) ? nil : words
            )
        }
    }
}

// MARK: - Model cache (integrity + suspect/repair state)

/// Hugging Face cache for the pinned whisper repo under `hfHome`.
///
/// Integrity ⇔ the repo's snapshot dir exists, is non-empty, and no
/// `*.incomplete` blobs exist anywhere under the repo cache dir.
///
/// Suspect flow (C3 spec): exit-3 from the driver marks the cache SUSPECT
/// (marker file `<hfHome>/.blaise-suspect` with a persisted attempt counter —
/// survives relaunch). Repair runs in `prepareBody()`'s model step:
/// integrity-FALSE → resume fetch; integrity-TRUE while suspect (in-place
/// corruption resume cannot fix) → wipe the pinned repo's cache dir + full
/// re-fetch. "Two consecutive" exit-3s — with a completed wipe-repair and no
/// successful transcribe between them — escalate to `.permanent`.
struct WhisperModelCache: Sendable {
    let hfHome: URL
    let repo: String
    /// Suspect-marker file name — per-ENGINE, so two engines sharing one
    /// `hfHome` (whisper + the C6 notes model) never cross-suspect.
    let markerName: String

    init(
        hfHome: URL, repo: String = MLXWhisperEngine.modelRepo,
        markerName: String = ".blaise-suspect"
    ) {
        self.hfHome = hfHome
        self.repo = repo
        self.markerName = markerName
    }

    var repoCacheDir: URL {
        let folder = "models--" + repo.replacingOccurrences(of: "/", with: "--")
        return hfHome.appendingPathComponent("hub", isDirectory: true)
            .appendingPathComponent(folder, isDirectory: true)
    }

    var suspectMarkerURL: URL {
        hfHome.appendingPathComponent(markerName)
    }

    func integrity() -> Bool {
        let fileManager = FileManager.default
        let snapshots = repoCacheDir.appendingPathComponent("snapshots", isDirectory: true)
        guard
            let snapshotDirs = try? fileManager.contentsOfDirectory(
                at: snapshots, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]),
            snapshotDirs.contains(where: { dir in
                let contents = try? fileManager.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                return !(contents ?? []).isEmpty
            })
        else { return false }
        if let enumerator = fileManager.enumerator(at: repoCacheDir, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where url.lastPathComponent.hasSuffix(".incomplete") {
                return false
            }
        }
        return true
    }

    struct SuspectState: Codable, Equatable {
        var attempts: Int
        var repairedSinceLastFailure: Bool
        /// Set when the two-consecutive-failures verdict fires: the repair
        /// loop must STOP re-downloading 1.5 GB per attempt (impl audit M3).
        /// Cleared only by a successful transcribe (clearSuspect) or an
        /// explicit cache reset (delete the marker + repo dir; C10 settings
        /// action, BACKLOG until then).
        var permanentFailure: Bool

        enum CodingKeys: String, CodingKey {
            case attempts
            case repairedSinceLastFailure = "repaired_since_last_failure"
            case permanentFailure = "permanent_failure"
        }

        init(attempts: Int, repairedSinceLastFailure: Bool, permanentFailure: Bool = false) {
            self.attempts = attempts
            self.repairedSinceLastFailure = repairedSinceLastFailure
            self.permanentFailure = permanentFailure
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            attempts = try c.decode(Int.self, forKey: .attempts)
            repairedSinceLastFailure = try c.decode(Bool.self, forKey: .repairedSinceLastFailure)
            permanentFailure = try c.decodeIfPresent(Bool.self, forKey: .permanentFailure) ?? false
        }
    }

    /// nil ⇔ not suspect.
    func suspectState() -> SuspectState? {
        guard let data = try? Data(contentsOf: suspectMarkerURL) else { return nil }
        return try? JSONDecoder().decode(SuspectState.self, from: data)
    }

    /// Records an exit-3 (model load failure): increments the persisted
    /// attempt counter and clears the repaired flag.
    func recordLoadFailure() {
        let previous = suspectState()
        write(SuspectState(attempts: (previous?.attempts ?? 0) + 1, repairedSinceLastFailure: false))
    }

    /// Records that a wipe-repair COMPLETED (wipe + full re-fetch).
    func recordRepairCompleted() {
        guard let state = suspectState() else { return }
        write(SuspectState(attempts: state.attempts, repairedSinceLastFailure: true,
                           permanentFailure: state.permanentFailure))
    }

    /// Finalizes the two-consecutive-failures verdict: repair stops.
    func recordPermanentFailure() {
        let state = suspectState() ?? SuspectState(attempts: 0, repairedSinceLastFailure: true)
        write(SuspectState(attempts: state.attempts, repairedSinceLastFailure: state.repairedSinceLastFailure,
                           permanentFailure: true))
    }

    /// A successful transcribe clears suspicion entirely.
    func clearSuspect() {
        try? FileManager.default.removeItem(at: suspectMarkerURL)
    }

    private func write(_ state: SuspectState) {
        try? FileManager.default.createDirectory(at: hfHome, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: suspectMarkerURL, options: .atomic)
        }
    }
}

// MARK: - Venv layout + provisioning predicates

/// Default (app-managed) python layout under the data root. The uv-managed
/// CPython interpreter lives INSIDE the data root so nothing external can
/// break the venv invisibly.
struct VenvLayout: Sendable {
    let dataRoot: URL

    var pythonDir: URL { dataRoot.appendingPathComponent("python", isDirectory: true) }
    var venvDir: URL { pythonDir.appendingPathComponent("venv", isDirectory: true) }
    var lockFileURL: URL { pythonDir.appendingPathComponent(".lock") }
    var cpythonInstallDir: URL { pythonDir.appendingPathComponent("cpython", isDirectory: true) }
    var uvCacheDir: URL { pythonDir.appendingPathComponent("uv-cache", isDirectory: true) }

    /// Sentinel `.blaise-provisioned-<sha256(python_requirements.txt)>`:
    /// present in the venv dir ⇔ the venv satisfies exactly that pin set.
    /// Changing the requirements changes the hash → mismatch → rebuild
    /// (this is how the C6 rename + mlx-lm/outlines pin growth migrates
    /// existing installs automatically).
    static func sentinelName(requirementsData: Data) -> String {
        let digest = SHA256.hash(data: requirementsData)
        return ".blaise-provisioned-" + digest.map { String(format: "%02x", $0) }.joined()
    }

    static func sentinelURL(venvDir: URL, requirementsData: Data) -> URL {
        venvDir.appendingPathComponent(sentinelName(requirementsData: requirementsData))
    }

    static func isProvisioned(venvDir: URL, requirementsData: Data) -> Bool {
        FileManager.default.fileExists(
            atPath: sentinelURL(venvDir: venvDir, requirementsData: requirementsData).path)
    }
}

// MARK: - Orphan sweep

/// At engine init: kill stray driver processes whose parent died (launchd
/// reparenting → ppid 1 is exactly the observable signature). Best-effort.
enum OrphanSweeper {
    struct ProcessRecord: Equatable {
        var pid: Int32
        var ppid: Int32
        var command: String
    }

    /// Parses one line of `ps -axo pid=,ppid=,command=`.
    static func parsePSLine(_ line: String) -> ProcessRecord? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count == 3, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else { return nil }
        return ProcessRecord(pid: pid, ppid: ppid, command: String(parts[2]))
    }

    /// The matcher (unit-tested): driver path + `--blaise-engine` marker +
    /// ppid == 1. A live parent (ppid != 1) means the process is owned by a
    /// running Blaise instance — never touched.
    static func isOrphanedDriver(_ record: ProcessRecord, driverPath: String) -> Bool {
        record.ppid == 1
            && record.command.contains(driverPath)
            && record.command.contains("--blaise-engine")
    }

    static func sweep(driverPath: String, logger: Logger) async {
        do {
            let outcome = try await SubprocessRunner.run(
                executable: URL(fileURLWithPath: "/bin/ps"),
                arguments: ["-axo", "pid=,ppid=,command="],
                environment: ["PATH": "/usr/bin:/bin"],
                timeout: 30
            )
            guard outcome.exitStatus == 0 else { return }
            let lines = String(decoding: outcome.stdout, as: UTF8.self).split(separator: "\n")
            for line in lines {
                guard let record = parsePSLine(String(line)),
                    isOrphanedDriver(record, driverPath: driverPath)
                else { continue }
                logger.warning("orphan sweep: killing stray driver pid \(record.pid)")
                kill(record.pid, SIGKILL)
            }
        } catch {
            logger.warning("orphan sweep failed (best-effort): \(String(describing: error))")
        }
    }
}

// MARK: - Disk space

enum DiskSpace {
    /// Available bytes on the volume containing `url` (important-usage
    /// capacity, the purgeable-aware figure). nil if unreadable.
    static func availableBytes(at url: URL) -> Int64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" {
            probe = probe.deletingLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
