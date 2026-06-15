import AVFoundation
import Foundation
import GRDB
import os

// C14: multi-part capture (resume grace window). Durable per-part metadata
// (`meeting_capture_part`, migration v8) + the WAV-level stitcher the
// transcode stage uses: each part stop-encodes immediately exactly like
// today (hard floor 2 per part, unchanged code path); processing stitches
// the decoded parts into the ONE temp WAV per track every downstream stage
// already expects, with per-part wall-clock re-anchoring so diarization
// sees one continuous track and the C12 epoch correlation holds unchanged.

// MARK: - Part rows (migration v8)

public struct CapturePartRecord: Sendable, Equatable {
    public var partIndex: Int
    public var startedAtMs: Int64
    public var endedAtMs: Int64?

    public init(partIndex: Int, startedAtMs: Int64, endedAtMs: Int64? = nil) {
        self.partIndex = partIndex
        self.startedAtMs = startedAtMs
        self.endedAtMs = endedAtMs
    }
}

/// G9 (H-1): a resume's guarded status flip found the meeting no longer
/// `paused` — a concurrent End-from-pause won the race and the meeting is
/// already heading to processing. The resume transaction rolls back and the
/// caller tears its engine down; the meeting's `processing` state is preserved.
public enum CapturePartsError: Error, Equatable {
    case resumeLostRace(meetingID: MeetingID)
}

public enum CaptureParts {
    private static let logger = Logger(subsystem: BlaiseBundle.identifier, category: "capture.parts")

    // MARK: Row operations (controller: insert at part start, close at stop)

    public static func insertPart(
        _ database: BlaiseDatabase, meetingID: MeetingID, partIndex: Int, startedAtMs: Int64
    ) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO meeting_capture_part
                        (meeting_id, part_index, started_at_ms, ended_at_ms)
                    VALUES (?, ?, ?, NULL)
                    """,
                arguments: [meetingID, partIndex, startedAtMs])
        }
    }

    public static func closePart(
        _ database: BlaiseDatabase, meetingID: MeetingID, partIndex: Int, endedAtMs: Int64
    ) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: "UPDATE meeting_capture_part SET ended_at_ms = ? WHERE meeting_id = ? AND part_index = ?",
                arguments: [endedAtMs, meetingID, partIndex])
        }
    }

    /// G9 pause: close the current capture part AND write `meeting.status`
    /// (+ `endedAt`, `updatedAt`) in ONE transaction (the C11 single-
    /// transaction flag discipline). A crash anywhere splits cleanly: the
    /// transaction either committed (the meeting is durably `paused` with the
    /// part closed) or it did not (the meeting stays `recording` — today's
    /// kill-mid-capture semantics). `midTransactionHook` is the AC3 crash-
    /// test seam (G7 pattern): a throw between the part close and the status
    /// write rolls BOTH back. The `endedAt`/`updatedAt` writes mirror the
    /// stop path (every part stop sets endedAt, latest wins).
    public static func closePartAndSetStatus(
        _ database: BlaiseDatabase,
        meetingID: MeetingID,
        partIndex: Int,
        endedAtMs: Int64,
        status: MeetingStatus,
        midTransactionHook: (@Sendable () throws -> Void)? = nil
    ) async throws {
        let endedAt = Date(timeIntervalSince1970: Double(endedAtMs) / 1000.0)
        try await database.pool.write { db in
            try db.execute(
                sql: "UPDATE meeting_capture_part SET ended_at_ms = ? WHERE meeting_id = ? AND part_index = ?",
                arguments: [endedAtMs, meetingID, partIndex])
            try midTransactionHook?()
            try db.execute(
                sql: "UPDATE meeting SET status = ?, ended_at = ?, updated_at = ? WHERE id = ?",
                arguments: [status.rawValue, endedAt, endedAt, meetingID])
        }
    }

    /// G9 resume: open the new capture part AND write `meeting.status`
    /// (+ clear `endedAt`, bump `updatedAt`) in ONE transaction — the same
    /// single-transaction discipline as pause, inverted: the engine and the
    /// part CAFs are created BEFORE this commit (round-2 M-7), so a crash at
    /// any point before it leaves the meeting durably `paused` (the §2 gate
    /// protects the orphaned new-part CAF). `midTransactionHook` is the
    /// crash-test seam.
    public static func openPartAndSetStatus(
        _ database: BlaiseDatabase,
        meetingID: MeetingID,
        partIndex: Int,
        startedAtMs: Int64,
        status: MeetingStatus,
        updatedAt: Date,
        midTransactionHook: (@Sendable () throws -> Void)? = nil
    ) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO meeting_capture_part
                        (meeting_id, part_index, started_at_ms, ended_at_ms)
                    VALUES (?, ?, ?, NULL)
                    """,
                arguments: [meetingID, partIndex, startedAtMs])
            try midTransactionHook?()
            // H-1: the status flip is GUARDED `WHERE status = 'paused'`. If a
            // concurrent End-from-pause already flipped the meeting to
            // `processing` inside this resume's engine-start window, this write
            // affects zero rows — the resume LOST the race and must NOT clobber
            // the End's `processing` with `recording` (that would re-open a
            // meeting already on its way to handoff). The whole transaction
            // (the new part row included) rolls back via the thrown error, and
            // the caller tears the engine down.
            try db.execute(
                sql: "UPDATE meeting SET status = ?, ended_at = NULL, updated_at = ? WHERE id = ? AND status = ?",
                arguments: [status.rawValue, updatedAt, meetingID, MeetingStatus.paused.rawValue])
            if db.changesCount == 0 {
                throw CapturePartsError.resumeLostRace(meetingID: meetingID)
            }
        }
    }

    /// G9 End-from-pause: flip `paused → processing` in its OWN transaction,
    /// BEFORE any dispatch (AC1) — so §2's refusal set never blocks a
    /// deliberate End. Idempotent guard: only a row currently `paused` is
    /// flipped (a racing kick that already moved it is a no-op). Returns
    /// whether the flip happened.
    @discardableResult
    public static func flipPausedToProcessing(
        _ database: BlaiseDatabase, meetingID: MeetingID
    ) async throws -> Bool {
        try await database.pool.write { db in
            try db.execute(
                sql: "UPDATE meeting SET status = ? WHERE id = ? AND status = ?",
                arguments: [
                    MeetingStatus.processing.rawValue, meetingID, MeetingStatus.paused.rawValue,
                ])
            return db.changesCount > 0
        }
    }

    /// Row-follows-files (the empty-part rule): the row is deleted ONLY when
    /// every file of the part is provably gone — zero-frame CAFs removed per
    /// the C1 zero-frame rule and no part m4a on disk. The caller
    /// (`deletePartRowIfFilesGone`) performs that proof; this is the raw op.
    public static func deletePart(
        _ database: BlaiseDatabase, meetingID: MeetingID, partIndex: Int
    ) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: "DELETE FROM meeting_capture_part WHERE meeting_id = ? AND part_index = ?",
                arguments: [meetingID, partIndex])
        }
    }

    /// Deletes the part row IFF no file of the part remains on disk (CAF or
    /// retained m4a, either track) — deletion can never strand a part file
    /// without a row. Returns whether the row was deleted.
    @discardableResult
    public static func deletePartRowIfFilesGone(
        _ database: BlaiseDatabase, meetingID: MeetingID, partIndex: Int
    ) async -> Bool {
        let fm = FileManager.default
        let paths = database.paths
        for track in CaptureTrack.allCases {
            if fm.fileExists(atPath: paths.captureCAFURL(meetingID, track: track, part: partIndex).path) {
                return false
            }
            if fm.fileExists(atPath: track.retainedURL(paths, meetingID: meetingID, part: partIndex).path) {
                return false
            }
        }
        try? await deletePart(database, meetingID: meetingID, partIndex: partIndex)
        return true
    }

    public static func parts(
        _ database: BlaiseDatabase, meetingID: MeetingID
    ) async throws -> [CapturePartRecord] {
        try await database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT part_index, started_at_ms, ended_at_ms
                    FROM meeting_capture_part WHERE meeting_id = ? ORDER BY part_index
                    """,
                arguments: [meetingID]
            ).map {
                CapturePartRecord(
                    partIndex: $0["part_index"], startedAtMs: $0["started_at_ms"],
                    endedAtMs: $0["ended_at_ms"])
            }
        }
    }

    /// G9: total recorded time = sum of every CLOSED part's wall-clock span
    /// (the indicator's accumulated "paused" timer; the open current part, if
    /// any, is excluded — its span is counted once it closes at the next
    /// pause/stop). A part with no `endedAtMs` contributes nothing.
    public static func accumulatedRecordedSeconds(
        _ database: BlaiseDatabase, meetingID: MeetingID
    ) async -> TimeInterval {
        let rows = (try? await parts(database, meetingID: meetingID)) ?? []
        let totalMs = rows.reduce(Int64(0)) { sum, row in
            guard let endedAtMs = row.endedAtMs, endedAtMs > row.startedAtMs else { return sum }
            return sum + (endedAtMs - row.startedAtMs)
        }
        return Double(totalMs) / 1000.0
    }

    // MARK: Disk scans (filenames are the residue-truth half of enumeration)

    /// Part indices that have a capture CAF on disk (either track) — the
    /// part-aware orphan-sweep key.
    public static func diskCAFPartIndices(paths: MeetingPaths, meetingID: MeetingID) -> Set<Int> {
        scanIndices(paths: paths, meetingID: meetingID) { name in
            for track in CaptureTrack.allCases {
                let base = "capture_\(track.rawValue)"
                if name == "\(base).caf" { return 1 }
                if name.hasPrefix("\(base)_"), name.hasSuffix(".caf"),
                    let index = Int(name.dropFirst(base.count + 1).dropLast(4)), index >= 2
                {
                    return index
                }
            }
            return nil
        }
    }

    /// Part indices with a retained m4a on disk for the given track.
    public static func diskRetainedPartIndices(
        paths: MeetingPaths, meetingID: MeetingID, track: CaptureTrack
    ) -> Set<Int> {
        scanIndices(paths: paths, meetingID: meetingID) { name in
            switch track {
            case .mic:
                if name == "audio_mic.m4a" { return 1 }
                if name.hasPrefix("audio_mic_"), name.hasSuffix(".m4a"),
                    let index = Int(name.dropFirst("audio_mic_".count).dropLast(4)), index >= 2
                {
                    return index
                }
            case .system:
                if name == "audio.m4a" { return 1 }
                if name.hasPrefix("audio_"), !name.hasPrefix("audio_mic"), name.hasSuffix(".m4a"),
                    let index = Int(name.dropFirst("audio_".count).dropLast(4)), index >= 2
                {
                    return index
                }
            }
            return nil
        }
    }

    /// Any retained part audio for this meeting (either track, any part) —
    /// the meeting-wide "no part has recoverable audio" check at part stop.
    public static func anyRetainedAudio(paths: MeetingPaths, meetingID: MeetingID) -> Bool {
        !diskRetainedPartIndices(paths: paths, meetingID: meetingID, track: .system).isEmpty
            || !diskRetainedPartIndices(paths: paths, meetingID: meetingID, track: .mic).isEmpty
    }

    /// Next part index for `resume`: one past everything known — DB rows AND
    /// file residue (a deleted empty-part row must not cause a reused index
    /// that would overwrite retained audio).
    public static func nextPartIndex(
        _ database: BlaiseDatabase, meetingID: MeetingID
    ) async -> Int {
        let rows = (try? await parts(database, meetingID: meetingID)) ?? []
        let paths = database.paths
        var maxIndex = rows.map(\.partIndex).max() ?? 1
        for set in [
            diskCAFPartIndices(paths: paths, meetingID: meetingID),
            diskRetainedPartIndices(paths: paths, meetingID: meetingID, track: .system),
            diskRetainedPartIndices(paths: paths, meetingID: meetingID, track: .mic),
        ] {
            maxIndex = max(maxIndex, set.max() ?? 1)
        }
        return maxIndex + 1
    }

    private static func scanIndices(
        paths: MeetingPaths, meetingID: MeetingID, parse: (String) -> Int?
    ) -> Set<Int> {
        let directory = paths.meetingDirectory(meetingID)
        guard
            let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return [] }
        return Set(names.compactMap(parse))
    }
}

// MARK: - Stitcher (transcode stage, captured meetings only)

public enum CaptureStitcher {
    private static let logger = Logger(subsystem: BlaiseBundle.identifier, category: "capture.stitch")
    static let sampleRate: Double = 16_000

    /// One enumerated part as the stitcher sees it (DB rows ∪ part files on
    /// disk). `offsetMs` nil = row-less residue: appended in suffix order
    /// with ZERO inserted silence and a capture-recovery note — honesty over
    /// an invented gap.
    ///
    /// `wallSpanMs` (playback only) is the part's TRUE recorded wall-clock
    /// duration (`endedAtMs − startedAtMs` from the part row) — the real-time
    /// reference both tracks share. The capture aggregate's mic sub-device and
    /// system tap drift relative to each other and to wall-clock (field: the
    /// two retained m4as of one part differ in duration by a ~1.088 factor —
    /// the classic 48 kHz↔44.1 kHz rate confusion — and which track runs long
    /// is per-recording, not fixed to a track), so a file's frame count is NOT
    /// a faithful clock. Stretching each track's file duration onto this span
    /// places both on one real-time axis (per-track playback anchor). `nil`
    /// when the part has no closed row (open/derived) — the player then cannot
    /// trust the cross-track alignment and falls back to single-track playback.
    public struct PlannedPart: Sendable, Equatable {
        public var index: Int
        public var offsetMs: Int64?
        public var wallSpanMs: Int64?
        public var systemM4A: URL?
        public var micM4A: URL?

        public init(
            index: Int, offsetMs: Int64?, wallSpanMs: Int64? = nil,
            systemM4A: URL?, micM4A: URL?
        ) {
            self.index = index
            self.offsetMs = offsetMs
            self.wallSpanMs = wallSpanMs
            self.systemM4A = systemM4A
            self.micM4A = micM4A
        }
    }

    public struct StitchOutcome: Sendable {
        public var systemPresent = false
        public var micPresent = false
        /// Structural-silence ranges (seconds in the stitched timeline) per
        /// track — the post-ASR hallucination filter's input.
        public var systemGaps: [ClosedRange<Double>] = []
        public var micGaps: [ClosedRange<Double>] = []
        /// Parts that contributed audio.
        public var partCount = 0
        /// Every contributing part carried BOTH tracks and no row-less
        /// residue was appended — gates the capture-recovery-note clear.
        public var complete = true
        /// Capture-recovery notes raised at stitch time (missing track span,
        /// row-less append).
        public var notes: [String] = []

        public init() {}
    }

    /// Enumerates the meeting's parts: DB rows (offset = wall-clock
    /// re-anchoring source) ∪ part files on disk. Parts with NO audio file
    /// on either track (e.g. an encode-failed part awaiting rescue, or a
    /// crash that left a row without files) are skipped — they contribute no
    /// span; re-anchoring is absolute, so later parts are unaffected.
    public static func plan(
        database: BlaiseDatabase, meetingID: MeetingID
    ) async -> [PlannedPart] {
        let paths = database.paths
        let fm = FileManager.default
        let rows = (try? await CaptureParts.parts(database, meetingID: meetingID)) ?? []
        let rowByIndex = Dictionary(uniqueKeysWithValues: rows.map { ($0.partIndex, $0) })
        var indices = Set(rows.map(\.partIndex))
        indices.formUnion(CaptureParts.diskRetainedPartIndices(paths: paths, meetingID: meetingID, track: .system))
        indices.formUnion(CaptureParts.diskRetainedPartIndices(paths: paths, meetingID: meetingID, track: .mic))
        // Anchor = the first part WITH a row (part 1 in every normal life).
        let anchorMs = rows.first?.startedAtMs

        var parts: [PlannedPart] = []
        for index in indices.sorted() {
            let system = paths.audioURL(meetingID, part: index)
            let mic = paths.audioMicURL(meetingID, part: index)
            let systemURL = fm.fileExists(atPath: system.path) ? system : nil
            let micURL = fm.fileExists(atPath: mic.path) ? mic : nil
            guard systemURL != nil || micURL != nil else { continue }  // no recovered audio: skipped
            let offsetMs: Int64?
            var wallSpanMs: Int64?
            if let row = rowByIndex[index], let anchorMs {
                offsetMs = row.startedAtMs - anchorMs
                // True recorded span of this part — the real-time axis both
                // tracks are scaled onto for playback. Only a CLOSED row
                // (endedAtMs present and after start) carries it; an open or
                // zero-length row leaves it nil (single-track fallback).
                if let endedAtMs = row.endedAtMs, endedAtMs > row.startedAtMs {
                    wallSpanMs = endedAtMs - row.startedAtMs
                }
            } else {
                offsetMs = nil  // row-less residue
            }
            parts.append(
                PlannedPart(
                    index: index, offsetMs: offsetMs, wallSpanMs: wallSpanMs,
                    systemM4A: systemURL, micM4A: micURL))
        }
        return parts
    }

    /// The transcode-stage entry: decodes every contributing part and emits
    /// ONE 16 kHz mono Int16 WAV per present track at `tempSystemWAV` /
    /// `tempMicWAV`. ONE enumerated part at offset 0 → exactly today's
    /// decode path (byte-for-byte identical output); the NULL-`endedAt`
    /// repair applies on every path, single-part included.
    public static func prepareTracks(
        database: BlaiseDatabase,
        meeting: Meeting,
        tempSystemWAV: URL,
        tempMicWAV: URL,
        tempDirectory: URL
    ) async throws -> StitchOutcome {
        let meetingID = meeting.id
        let parts = await plan(database: database, meetingID: meetingID)
        var outcome = StitchOutcome()
        guard !parts.isEmpty else {
            // No part audio at all; the caller raises today's no-tracks error.
            await repairEndedAt(database: database, meeting: meeting, lastPartDuration: nil)
            return outcome
        }
        outcome.partCount = parts.count
        outcome.systemPresent = parts.contains { $0.systemM4A != nil }
        outcome.micPresent = parts.contains { $0.micM4A != nil }

        var lastPartDuration: Double?
        if parts.count == 1, (parts[0].offsetMs ?? 0) == 0 {
            // Single part: today's AUDIO path, no intermediate rewrite.
            let part = parts[0]
            if let system = part.systemM4A {
                try AudioTranscoder.decodeTo16kWAV(m4a: system, destination: tempSystemWAV)
            }
            if let mic = part.micM4A {
                try AudioTranscoder.decodeTo16kWAV(m4a: mic, destination: tempMicWAV)
            }
            outcome.complete = part.systemM4A != nil && part.micM4A != nil && part.offsetMs != nil
            if part.offsetMs == nil {
                // Possible only pre-v8 (no rows): single-part derived; that
                // is NOT row-less residue — no note, complete when both
                // tracks exist.
                let preV8 = ((try? await CaptureParts.parts(database, meetingID: meetingID)) ?? []).isEmpty
                outcome.complete = part.systemM4A != nil && part.micM4A != nil && preV8
                if !preV8 {
                    outcome.notes.append(
                        "part \(part.index) file found without part metadata — appended without gap reconstruction")
                }
            }
            let reference = part.systemM4A != nil ? tempSystemWAV : tempMicWAV
            lastPartDuration = try WAVHeader.read(at: reference).duration
        } else {
            // Multi-part: decode each part m4a to a temp WAV, then stitch
            // per track with wall-clock re-anchoring.
            var decoded: [Int: (system: URL?, mic: URL?)] = [:]
            var partTemps: [URL] = []
            defer { partTemps.forEach { try? FileManager.default.removeItem(at: $0) } }
            for part in parts {
                var systemWAV: URL?
                var micWAV: URL?
                if let m4a = part.systemM4A {
                    let temp = tempDirectory.appendingPathComponent(
                        "blaise-part-\(meetingID)-\(part.index)-sys-\(UUID().uuidString).wav")
                    try AudioTranscoder.decodeTo16kWAV(m4a: m4a, destination: temp)
                    systemWAV = temp
                    partTemps.append(temp)
                }
                if let m4a = part.micM4A {
                    let temp = tempDirectory.appendingPathComponent(
                        "blaise-part-\(meetingID)-\(part.index)-mic-\(UUID().uuidString).wav")
                    try AudioTranscoder.decodeTo16kWAV(m4a: m4a, destination: temp)
                    micWAV = temp
                    partTemps.append(temp)
                }
                decoded[part.index] = (systemWAV, micWAV)
                if part.offsetMs == nil {
                    outcome.complete = false
                    outcome.notes.append(
                        "part \(part.index) file found without part metadata — appended without gap reconstruction")
                } else if systemWAV == nil || micWAV == nil {
                    outcome.complete = false
                    let missing = systemWAV == nil ? CaptureTrack.system : CaptureTrack.mic
                    outcome.notes.append(
                        "part \(part.index) \(missing.rawValue) track missing — silence spans that part on the \(missing.rawValue) track")
                }
            }
            if outcome.systemPresent {
                outcome.systemGaps = try stitchTrack(
                    sources: parts.map { (offsetMs: $0.offsetMs, wav: decoded[$0.index]?.system) },
                    destination: tempSystemWAV
                ).gapRanges
            }
            if outcome.micPresent {
                outcome.micGaps = try stitchTrack(
                    sources: parts.map { (offsetMs: $0.offsetMs, wav: decoded[$0.index]?.mic) },
                    destination: tempMicWAV
                ).gapRanges
            }
            if let last = parts.last,
                let wav = decoded[last.index]?.system ?? decoded[last.index]?.mic
            {
                lastPartDuration = try? WAVHeader.read(at: wav).duration
            }
        }
        await repairEndedAt(database: database, meeting: meeting, lastPartDuration: lastPartDuration)
        return outcome
    }

    // MARK: Per-track stitching (pure over WAV files; unit-tested)

    public struct TrackStitchResult: Sendable, Equatable {
        public var gapRanges: [ClosedRange<Double>]
        public var frames: Int64

        public var duration: Double { Double(frames) / CaptureStitcher.sampleRate }
    }

    /// Stitches ordered 16 kHz mono Int16 WAV sources into one WAV with
    /// per-part wall-clock re-anchoring: part n's target offset is absolute
    /// (`offsetMs` since part 1's start), and the silence inserted before it
    /// is `offset − samples already emitted`, clamped ≥ 0 — per-part decoded
    /// duration error never accumulates. `wav == nil` entries contribute
    /// nothing (the next anchored part's silence covers the span);
    /// `offsetMs == nil` entries append gap-free in order.
    public static func stitchTrack(
        sources: [(offsetMs: Int64?, wav: URL?)], destination: URL
    ) throws -> TrackStitchResult {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)
        else {
            throw AudioTranscoderError.conversionFailed("cannot build stitch format")
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let outFile = try AVAudioFile(
            forWriting: destination, settings: settings,
            commonFormat: .pcmFormatInt16, interleaved: true)
        var gaps: [ClosedRange<Double>] = []
        var emitted: Int64 = 0

        func writeSilence(frames: Int64) throws {
            var remaining = frames
            while remaining > 0 {
                let chunk = AVAudioFrameCount(min(remaining, 65_536))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
                    throw AudioTranscoderError.conversionFailed("cannot allocate silence buffer")
                }
                buffer.frameLength = chunk  // zero-initialized
                try outFile.write(from: buffer)
                remaining -= Int64(chunk)
            }
        }

        for source in sources {
            guard let wav = source.wav else { continue }
            if let offsetMs = source.offsetMs {
                let target = Int64((Double(offsetMs) / 1000.0 * sampleRate).rounded())
                let silence = max(0, target - emitted)
                if silence > 0 {
                    gaps.append(
                        (Double(emitted) / sampleRate)...(Double(target) / sampleRate))
                    try writeSilence(frames: silence)
                    emitted = target
                }
            }
            let inFile: AVAudioFile
            do {
                inFile = try AVAudioFile(
                    forReading: wav, commonFormat: .pcmFormatInt16, interleaved: true)
            } catch {
                throw AudioTranscoderError.cannotOpen("cannot read \(wav.lastPathComponent): \(error)")
            }
            guard
                inFile.processingFormat.sampleRate == sampleRate,
                inFile.processingFormat.channelCount == 1
            else {
                throw AudioTranscoderError.conversionFailed(
                    "stitch source is not 16 kHz mono: \(wav.lastPathComponent)")
            }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: inFile.processingFormat, frameCapacity: 65_536)
            else {
                throw AudioTranscoderError.conversionFailed("cannot allocate stitch buffer")
            }
            while inFile.framePosition < inFile.length {
                try inFile.read(into: buffer)
                if buffer.frameLength == 0 { break }
                try outFile.write(from: buffer)
                emitted += Int64(buffer.frameLength)
            }
        }
        outFile.close()
        return TrackStitchResult(gapRanges: gaps, frames: emitted)
    }

    // MARK: Silence-hallucination guard (hard floor 1)

    /// Drops ASR segments lying ENTIRELY inside a structural-silence gap
    /// (shrunk by `margin` on each edge) — Whisper-class models hallucinate
    /// on long silence, and a stitched gap is the one place silence is
    /// structural, known, and provably speech-free.
    public static func filterGapSegments(
        _ segments: [ASRSegment], gaps: [ClosedRange<Double>], margin: Double = 1.0
    ) -> (kept: [ASRSegment], droppedCount: Int) {
        guard !gaps.isEmpty else { return (segments, 0) }
        let shrunk = gaps.compactMap { gap -> ClosedRange<Double>? in
            let lower = gap.lowerBound + margin
            let upper = gap.upperBound - margin
            return lower < upper ? lower...upper : nil
        }
        guard !shrunk.isEmpty else { return (segments, 0) }
        let kept = segments.filter { segment in
            !shrunk.contains { gap in
                segment.startSeconds >= gap.lowerBound && segment.endSeconds <= gap.upperBound
            }
        }
        return (kept, segments.count - kept.count)
    }

    // MARK: endedAt repair (truthful library end time after crash recovery)

    /// Repairs a NULL `endedAt` at stitch time: derived close of the last
    /// open part row (`started + decoded part duration`); a meeting with no
    /// part rows at all (pre-v8) derives from `startedAt + decoded audio
    /// duration`. Open rows with decodable audio are also closed (honest
    /// durable state).
    static func repairEndedAt(
        database: BlaiseDatabase, meeting: Meeting, lastPartDuration: Double?
    ) async {
        let meetingID = meeting.id
        let rows = (try? await CaptureParts.parts(database, meetingID: meetingID)) ?? []
        // Close open rows whose part has decodable audio on disk.
        for row in rows where row.endedAtMs == nil {
            let m4a =
                FileManager.default.fileExists(
                    atPath: database.paths.audioURL(meetingID, part: row.partIndex).path)
                ? database.paths.audioURL(meetingID, part: row.partIndex)
                : database.paths.audioMicURL(meetingID, part: row.partIndex)
            guard FileManager.default.fileExists(atPath: m4a.path),
                let duration = try? AudioTranscoder.duration(of: m4a)
            else { continue }
            try? await CaptureParts.closePart(
                database, meetingID: meetingID, partIndex: row.partIndex,
                endedAtMs: row.startedAtMs + Int64(duration * 1000))
        }
        guard meeting.endedAt == nil else { return }
        let endedAt: Date
        if rows.isEmpty {
            // Pre-v8 (no rows at all): derived from the decoded duration.
            guard let duration = lastPartDuration else { return }
            endedAt = meeting.startedAt.addingTimeInterval(duration)
        } else {
            // Re-read: the close loop above repaired every open row that
            // has decodable audio. The honest meeting close is the LATEST
            // closed row — a trailing open row with NO recovered audio
            // (kill -9 between insertPart and CAF creation on a resume)
            // never recorded anything and must not borrow the previous
            // part's duration as its own span.
            let refreshed = (try? await CaptureParts.parts(database, meetingID: meetingID)) ?? rows
            guard let closeMs = refreshed.compactMap(\.endedAtMs).max() else { return }
            endedAt = Date(timeIntervalSince1970: Double(closeMs) / 1000.0)
        }
        try? await database.pool.write { db in
            try db.execute(
                sql: "UPDATE meeting SET ended_at = ? WHERE id = ? AND ended_at IS NULL",
                arguments: [endedAt, meetingID])
        }
        logger.notice("repaired NULL endedAt for \(meetingID) at stitch time")
    }
}
