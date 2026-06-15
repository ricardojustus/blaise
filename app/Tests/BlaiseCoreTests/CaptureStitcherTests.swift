import AVFoundation
import Foundation
import Testing

@testable import BlaiseCore

// C14 AC1: the WAV-level stitcher over synthetic WAVs — re-anchored
// wall-clock offsets exact at every part boundary, per-part duration error
// non-accumulating, single-part byte-identity with today's decode path
// (NULL-endedAt repair the sole divergence), missing-track silence +
// recovery note, row-less part files appended gap-free with a note, NULL
// endedAt repair incl. the no-rows pre-v8 derivation, and the gap-segment
// hallucination filter.

// MARK: - Synthetic WAV helpers

private func writeWAV(at url: URL, seconds: Double, amplitude: Int16) throws {
    let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ]
    let outFile = try AVAudioFile(
        forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
    var remaining = Int(seconds * 16_000)
    while remaining > 0 {
        let chunk = min(remaining, 16_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk))!
        buffer.frameLength = AVAudioFrameCount(chunk)
        let pointer = buffer.int16ChannelData![0]
        for index in 0 ..< chunk { pointer[index] = amplitude }
        try outFile.write(from: buffer)
        remaining -= chunk
    }
    outFile.close()
}

private func samples(at url: URL) throws -> [Int16] {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
    var result: [Int16] = []
    result.reserveCapacity(Int(file.length))
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65_536)!
    // read(into:) may return fewer frames than capacity per call — loop.
    while file.framePosition < file.length {
        try file.read(into: buffer)
        if buffer.frameLength == 0 { break }
        let pointer = buffer.int16ChannelData![0]
        result.append(contentsOf: UnsafeBufferPointer(start: pointer, count: Int(buffer.frameLength)))
    }
    return result
}

private func tempWAVURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("stitch-\(UUID().uuidString).wav")
}

@Suite("C14 stitcher: re-anchored WAV stitching")
struct StitchTrackTests {
    @Test("two parts: exact wall-clock offset, gap silence between, samples preserved")
    func twoPartsExactOffsets() throws {
        let part1 = tempWAVURL()
        let part2 = tempWAVURL()
        let out = tempWAVURL()
        defer { [part1, part2, out].forEach { try? FileManager.default.removeItem(at: $0) } }
        try writeWAV(at: part1, seconds: 10, amplitude: 100)
        try writeWAV(at: part2, seconds: 5, amplitude: 200)

        let result = try CaptureStitcher.stitchTrack(
            sources: [(offsetMs: 0, wav: part1), (offsetMs: 20_000, wav: part2)],
            destination: out)
        #expect(result.frames == Int64(25 * 16_000))
        #expect(result.gapRanges == [10.0 ... 20.0])

        let data = try samples(at: out)
        #expect(data.count == 25 * 16_000)
        #expect(data[0] == 100)
        #expect(data[10 * 16_000 - 1] == 100)
        #expect(data[10 * 16_000] == 0, "gap is structural silence")
        #expect(data[20 * 16_000 - 1] == 0)
        #expect(data[20 * 16_000] == 200, "part 2 lands at its EXACT time-since-meeting-start")
        #expect(data[25 * 16_000 - 1] == 200)
    }

    @Test("per-part decoded-duration error never accumulates (absolute re-anchoring)")
    func reAnchoringDoesNotAccumulate() throws {
        // Each part decodes 0.4 s SHORT of its nominal 10 s span (the
        // encode-verification tolerance allows 0.5 s per part). Summing
        // gaps would drift part 3 by 0.8 s; absolute re-anchoring may not.
        let parts = try (0 ..< 3).map { index -> URL in
            let url = tempWAVURL()
            try writeWAV(at: url, seconds: 9.6, amplitude: Int16(100 * (index + 1)))
            return url
        }
        let out = tempWAVURL()
        defer { (parts + [out]).forEach { try? FileManager.default.removeItem(at: $0) } }

        let result = try CaptureStitcher.stitchTrack(
            sources: [
                (offsetMs: 0, wav: parts[0]),
                (offsetMs: 20_000, wav: parts[1]),
                (offsetMs: 40_000, wav: parts[2]),
            ],
            destination: out)
        let data = try samples(at: out)
        #expect(data[20 * 16_000] == 200, "part 2 boundary exact despite part 1 running short")
        #expect(data[40 * 16_000] == 300, "part 3 boundary exact despite cumulative shortfall")
        #expect(result.gapRanges == [9.6 ... 20.0, 29.6 ... 40.0])
    }

    @Test("row-less source (offset nil) appends gap-free in order")
    func rowlessAppendsGapFree() throws {
        let part1 = tempWAVURL()
        let residue = tempWAVURL()
        let out = tempWAVURL()
        defer { [part1, residue, out].forEach { try? FileManager.default.removeItem(at: $0) } }
        try writeWAV(at: part1, seconds: 2, amplitude: 100)
        try writeWAV(at: residue, seconds: 1, amplitude: 200)
        let result = try CaptureStitcher.stitchTrack(
            sources: [(offsetMs: 0, wav: part1), (offsetMs: nil, wav: residue)],
            destination: out)
        #expect(result.gapRanges.isEmpty, "honesty over an invented gap")
        let data = try samples(at: out)
        #expect(data.count == 3 * 16_000)
        #expect(data[2 * 16_000] == 200, "appended immediately after part 1")
    }

    @Test("missing source (nil wav) contributes nothing; the next anchored part covers the span")
    func missingSourceSkipped() throws {
        let part2 = tempWAVURL()
        let out = tempWAVURL()
        defer { [part2, out].forEach { try? FileManager.default.removeItem(at: $0) } }
        try writeWAV(at: part2, seconds: 1, amplitude: 200)
        let result = try CaptureStitcher.stitchTrack(
            sources: [(offsetMs: 0, wav: nil), (offsetMs: 5_000, wav: part2)],
            destination: out)
        let data = try samples(at: out)
        #expect(data.count == 6 * 16_000)
        #expect(data[0] == 0)
        #expect(data[5 * 16_000] == 200, "later parts unaffected — re-anchoring is absolute")
        #expect(result.gapRanges == [0.0 ... 5.0])
    }
}

@Suite("C14 stitcher: gap-segment hallucination filter")
struct GapFilterTests {
    private let gaps: [ClosedRange<Double>] = [10.0 ... 20.0]

    private func segment(_ start: Double, _ end: Double) -> ASRSegment {
        ASRSegment(startSeconds: start, endSeconds: end, text: "x")
    }

    @Test("drops segments ENTIRELY inside a gap shrunk by the 1 s margin")
    func dropsInsideGap() {
        let segments = [
            segment(2, 8),  // real speech before the gap: kept
            segment(12, 18),  // fully inside the shrunk gap: dropped
            segment(11.0, 12.0),  // inside shrunk gap [11, 19]: dropped
            segment(10.2, 11.5),  // starts before the shrunk edge: kept
            segment(18.5, 21),  // straddles the gap end: kept
            segment(22, 25),  // after: kept
        ]
        let result = CaptureStitcher.filterGapSegments(segments, gaps: gaps)
        #expect(result.droppedCount == 2)
        #expect(result.kept.map(\.startSeconds) == [2, 10.2, 18.5, 22])
    }

    @Test("no gaps → untouched; sub-2 s gaps shrink away entirely")
    func noGapsUntouched() {
        let segments = [segment(0, 5)]
        #expect(CaptureStitcher.filterGapSegments(segments, gaps: []).droppedCount == 0)
        let tiny = CaptureStitcher.filterGapSegments(
            [segment(1.1, 1.9)], gaps: [1.0 ... 2.5])
        #expect(tiny.droppedCount == 0, "a 1.5 s gap shrunk by 1 s per edge cannot drop anything")
    }
}

@Suite("C14 stitcher: prepareTracks over retained part m4as")
struct PrepareTracksTests {
    /// Plants a part: synthetic WAV → encoded m4a at the part's retained
    /// path (the verified-encode artifact the stitcher consumes).
    private func plantPart(
        _ database: BlaiseDatabase, meetingID: MeetingID, part: Int,
        seconds: Double, amplitude: Int16, tracks: [CaptureTrack] = CaptureTrack.allCases
    ) throws {
        for track in tracks {
            let wav = tempWAVURL()
            defer { try? FileManager.default.removeItem(at: wav) }
            try writeWAV(at: wav, seconds: seconds, amplitude: amplitude)
            try AudioTranscoder.encodeToM4A(
                wav: wav, destination: track.retainedURL(database.paths, meetingID: meetingID, part: part))
        }
    }

    private func makeCapturedMeeting(
        _ database: BlaiseDatabase, endedAt: Date? = nil
    ) async throws -> Meeting {
        var meeting = makeMeeting(startedAt: msDate(1_770_000_000), status: .recording)
        meeting.captured = true
        meeting.endedAt = endedAt
        try await MeetingRepository(database: database).create(meeting)
        try database.paths.createMeetingDirectory(meeting.id)
        return meeting
    }

    @Test("single part = byte-for-byte today's decode path; NULL endedAt repaired (sole divergence)")
    func singlePartByteIdentity() async throws {
        let database = try makeDatabase()
        let meeting = try await makeCapturedMeeting(database)
        try await CaptureParts.insertPart(
            database, meetingID: meeting.id, partIndex: 1,
            startedAtMs: Int64(meeting.startedAt.timeIntervalSince1970 * 1000))
        try plantPart(database, meetingID: meeting.id, part: 1, seconds: 3, amplitude: 100)

        let stitchedSystem = tempWAVURL()
        let stitchedMic = tempWAVURL()
        let reference = tempWAVURL()
        defer {
            [stitchedSystem, stitchedMic, reference].forEach {
                try? FileManager.default.removeItem(at: $0)
            }
        }
        let outcome = try await CaptureStitcher.prepareTracks(
            database: database, meeting: meeting,
            tempSystemWAV: stitchedSystem, tempMicWAV: stitchedMic,
            tempDirectory: FileManager.default.temporaryDirectory)
        #expect(outcome.systemPresent && outcome.micPresent)
        #expect(outcome.partCount == 1)
        #expect(outcome.systemGaps.isEmpty && outcome.micGaps.isEmpty)
        #expect(outcome.complete)
        #expect(outcome.notes.isEmpty)

        // Byte identity with today's AUDIO path.
        try AudioTranscoder.decodeTo16kWAV(m4a: database.paths.audioURL(meeting.id), destination: reference)
        #expect(try Data(contentsOf: stitchedSystem) == Data(contentsOf: reference))

        // The sole deliberate divergence: the NULL endedAt was repaired
        // (started + decoded duration) and the open row closed.
        let repaired = try #require(try await MeetingRepository(database: database).fetch(meeting.id))
        let ended = try #require(repaired.endedAt)
        #expect(abs(ended.timeIntervalSince(meeting.startedAt) - 3.0) < 0.6)
        let rows = try await CaptureParts.parts(database, meetingID: meeting.id)
        #expect(rows.first?.endedAtMs != nil)
    }

    @Test("pre-v8 meeting (no rows at all): single-part derived; endedAt repaired from startedAt + duration")
    func preV8Derivation() async throws {
        let database = try makeDatabase()
        let meeting = try await makeCapturedMeeting(database)
        try plantPart(database, meetingID: meeting.id, part: 1, seconds: 2, amplitude: 100)
        let stitchedSystem = tempWAVURL()
        let stitchedMic = tempWAVURL()
        defer { [stitchedSystem, stitchedMic].forEach { try? FileManager.default.removeItem(at: $0) } }
        let outcome = try await CaptureStitcher.prepareTracks(
            database: database, meeting: meeting,
            tempSystemWAV: stitchedSystem, tempMicWAV: stitchedMic,
            tempDirectory: FileManager.default.temporaryDirectory)
        #expect(outcome.partCount == 1)
        #expect(outcome.complete, "pre-v8 single-part is derived, not row-less residue")
        #expect(outcome.notes.isEmpty)
        let repaired = try #require(try await MeetingRepository(database: database).fetch(meeting.id))
        let ended = try #require(repaired.endedAt)
        #expect(abs(ended.timeIntervalSince(meeting.startedAt) - 2.0) < 0.6)
    }

    @Test("an existing endedAt is never touched")
    func existingEndedAtUntouched() async throws {
        let database = try makeDatabase()
        let endedAt = msDate(1_770_000_500)
        let meeting = try await makeCapturedMeeting(database, endedAt: endedAt)
        try plantPart(database, meetingID: meeting.id, part: 1, seconds: 2, amplitude: 100)
        let stitchedSystem = tempWAVURL()
        let stitchedMic = tempWAVURL()
        defer { [stitchedSystem, stitchedMic].forEach { try? FileManager.default.removeItem(at: $0) } }
        _ = try await CaptureStitcher.prepareTracks(
            database: database, meeting: meeting,
            tempSystemWAV: stitchedSystem, tempMicWAV: stitchedMic,
            tempDirectory: FileManager.default.temporaryDirectory)
        let stored = try #require(try await MeetingRepository(database: database).fetch(meeting.id))
        #expect(stored.endedAt == endedAt)
    }

    @Test("two parts: stitched span, gap ranges, exact boundaries on both tracks")
    func twoPartsStitched() async throws {
        let database = try makeDatabase()
        let meeting = try await makeCapturedMeeting(database)
        let startMs = Int64(meeting.startedAt.timeIntervalSince1970 * 1000)
        try await CaptureParts.insertPart(database, meetingID: meeting.id, partIndex: 1, startedAtMs: startMs)
        try await CaptureParts.closePart(database, meetingID: meeting.id, partIndex: 1, endedAtMs: startMs + 3000)
        try await CaptureParts.insertPart(database, meetingID: meeting.id, partIndex: 2, startedAtMs: startMs + 10_000)
        try await CaptureParts.closePart(database, meetingID: meeting.id, partIndex: 2, endedAtMs: startMs + 12_000)
        try plantPart(database, meetingID: meeting.id, part: 1, seconds: 3, amplitude: 100)
        try plantPart(database, meetingID: meeting.id, part: 2, seconds: 2, amplitude: 200)

        let stitchedSystem = tempWAVURL()
        let stitchedMic = tempWAVURL()
        defer { [stitchedSystem, stitchedMic].forEach { try? FileManager.default.removeItem(at: $0) } }
        let outcome = try await CaptureStitcher.prepareTracks(
            database: database, meeting: meeting,
            tempSystemWAV: stitchedSystem, tempMicWAV: stitchedMic,
            tempDirectory: FileManager.default.temporaryDirectory)
        #expect(outcome.partCount == 2)
        #expect(outcome.complete)
        #expect(outcome.systemGaps.count == 1)
        let gap = try #require(outcome.systemGaps.first)
        #expect(abs(gap.upperBound - 10.0) < 0.001, "part 2 re-anchored at EXACTLY 10 s")
        #expect(gap.lowerBound > 2.4 && gap.lowerBound < 3.1)  // AAC duration ≈ 3 s

        // Stitched duration ≈ wall span (12 s), gap included.
        let info = try WAVHeader.read(at: stitchedSystem)
        #expect(abs(info.duration - 12.0) < 0.6)
        let data = try samples(at: stitchedSystem)
        #expect(abs(Int(data[10 * 16_000 + 100]) - 200) < 60,
            "part 2 samples (AAC-roundtripped) at the re-anchored offset")
    }

    @Test("part missing one track: silence spans it on that track + capture-recovery note; not complete")
    func missingTrackNote() async throws {
        let database = try makeDatabase()
        let meeting = try await makeCapturedMeeting(database)
        let startMs = Int64(meeting.startedAt.timeIntervalSince1970 * 1000)
        try await CaptureParts.insertPart(database, meetingID: meeting.id, partIndex: 1, startedAtMs: startMs)
        try await CaptureParts.insertPart(database, meetingID: meeting.id, partIndex: 2, startedAtMs: startMs + 5000)
        try plantPart(database, meetingID: meeting.id, part: 1, seconds: 2, amplitude: 100)
        try plantPart(database, meetingID: meeting.id, part: 2, seconds: 2, amplitude: 200, tracks: [.system])

        let stitchedSystem = tempWAVURL()
        let stitchedMic = tempWAVURL()
        defer { [stitchedSystem, stitchedMic].forEach { try? FileManager.default.removeItem(at: $0) } }
        let outcome = try await CaptureStitcher.prepareTracks(
            database: database, meeting: meeting,
            tempSystemWAV: stitchedSystem, tempMicWAV: stitchedMic,
            tempDirectory: FileManager.default.temporaryDirectory)
        #expect(!outcome.complete)
        #expect(outcome.notes.contains { $0.contains("part 2 mic track missing") })
        // Mic track simply ends after part 1; the span is silence by
        // construction (re-anchoring of nothing).
        let micInfo = try WAVHeader.read(at: stitchedMic)
        #expect(micInfo.duration < 2.5)
        let systemInfo = try WAVHeader.read(at: stitchedSystem)
        #expect(systemInfo.duration > 6.5)
    }

    @Test("row-less part FILE: appended in suffix order, zero silence, note recorded")
    func rowlessPartFile() async throws {
        let database = try makeDatabase()
        let meeting = try await makeCapturedMeeting(database)
        let startMs = Int64(meeting.startedAt.timeIntervalSince1970 * 1000)
        try await CaptureParts.insertPart(database, meetingID: meeting.id, partIndex: 1, startedAtMs: startMs)
        try plantPart(database, meetingID: meeting.id, part: 1, seconds: 2, amplitude: 100)
        // Residue: a part-2 m4a with NO meeting_capture_part row.
        try plantPart(database, meetingID: meeting.id, part: 2, seconds: 1, amplitude: 200)

        let stitchedSystem = tempWAVURL()
        let stitchedMic = tempWAVURL()
        defer { [stitchedSystem, stitchedMic].forEach { try? FileManager.default.removeItem(at: $0) } }
        let outcome = try await CaptureStitcher.prepareTracks(
            database: database, meeting: meeting,
            tempSystemWAV: stitchedSystem, tempMicWAV: stitchedMic,
            tempDirectory: FileManager.default.temporaryDirectory)
        #expect(!outcome.complete)
        #expect(outcome.notes.contains { $0.contains("part 2 file found without part metadata") })
        #expect(outcome.systemGaps.isEmpty, "no invented gap")
        let info = try WAVHeader.read(at: stitchedSystem)
        #expect(abs(info.duration - 3.0) < 0.6, "appended gap-free")
    }

    @Test("trailing open row with NO recovered audio: endedAt repairs to the LAST CLOSED row, never borrowing the previous part's duration")
    func trailingOpenRowNoAudioHonestEndedAt() async throws {
        // kill -9 between insertPart and CAF creation during a resume: the
        // trailing row never recorded anything. The honest meeting close is
        // part 1's close — not part-2-start + part-1-duration.
        let database = try makeDatabase()
        let meeting = try await makeCapturedMeeting(database)
        let startMs = Int64(meeting.startedAt.timeIntervalSince1970 * 1000)
        try await CaptureParts.insertPart(database, meetingID: meeting.id, partIndex: 1, startedAtMs: startMs)
        try await CaptureParts.closePart(database, meetingID: meeting.id, partIndex: 1, endedAtMs: startMs + 3000)
        try plantPart(database, meetingID: meeting.id, part: 1, seconds: 3, amplitude: 100)
        // Trailing open row, zero files for its part.
        try await CaptureParts.insertPart(database, meetingID: meeting.id, partIndex: 2, startedAtMs: startMs + 60_000)

        let stitchedSystem = tempWAVURL()
        let stitchedMic = tempWAVURL()
        defer { [stitchedSystem, stitchedMic].forEach { try? FileManager.default.removeItem(at: $0) } }
        _ = try await CaptureStitcher.prepareTracks(
            database: database, meeting: meeting,
            tempSystemWAV: stitchedSystem, tempMicWAV: stitchedMic,
            tempDirectory: FileManager.default.temporaryDirectory)
        let repaired = try #require(try await MeetingRepository(database: database).fetch(meeting.id))
        let ended = try #require(repaired.endedAt)
        #expect(
            abs(ended.timeIntervalSince(meeting.startedAt) - 3.0) < 0.001,
            "anchored at part 1's CLOSE, not at the never-recorded part 2's start + a borrowed duration")
    }

    @Test("an open row with NO recovered audio is skipped; later parts keep absolute offsets")
    func openRowNoAudioSkipped() async throws {
        let database = try makeDatabase()
        let meeting = try await makeCapturedMeeting(database)
        let startMs = Int64(meeting.startedAt.timeIntervalSince1970 * 1000)
        try await CaptureParts.insertPart(database, meetingID: meeting.id, partIndex: 1, startedAtMs: startMs)
        try plantPart(database, meetingID: meeting.id, part: 1, seconds: 2, amplitude: 100)
        // Part 2: row but no recovered audio (encode-failed, awaiting rescue).
        try await CaptureParts.insertPart(database, meetingID: meeting.id, partIndex: 2, startedAtMs: startMs + 4000)
        // Part 3: fine.
        try await CaptureParts.insertPart(database, meetingID: meeting.id, partIndex: 3, startedAtMs: startMs + 8000)
        try plantPart(database, meetingID: meeting.id, part: 3, seconds: 1, amplitude: 300)

        let stitchedSystem = tempWAVURL()
        let stitchedMic = tempWAVURL()
        defer { [stitchedSystem, stitchedMic].forEach { try? FileManager.default.removeItem(at: $0) } }
        let outcome = try await CaptureStitcher.prepareTracks(
            database: database, meeting: meeting,
            tempSystemWAV: stitchedSystem, tempMicWAV: stitchedMic,
            tempDirectory: FileManager.default.temporaryDirectory)
        #expect(outcome.partCount == 2, "the no-audio part contributes no span")
        let data = try samples(at: stitchedSystem)
        #expect(abs(Int(data[8 * 16_000 + 100]) - 300) < 60,
            "part 3 (AAC-roundtripped) lands at ITS absolute offset regardless")
    }
}
