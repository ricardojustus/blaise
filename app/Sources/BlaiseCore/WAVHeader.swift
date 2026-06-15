import Foundation

/// Minimal RIFF/WAVE header reader: `audioDuration` for the normalizer and
/// the subprocess timeout formula. Blaise produces its own 16 kHz mono PCM
/// WAVs (C7 owns transcoding), so plain PCM `fmt `/`data` chunks suffice;
/// anything unparseable is a bad-input boundary error.
public enum WAVHeader {
    public struct Info: Sendable, Equatable {
        public let sampleRate: Int
        public let channels: Int
        public let bitsPerSample: Int
        public let dataByteCount: Int

        public var duration: Double {
            let bytesPerFrame = channels * bitsPerSample / 8
            guard bytesPerFrame > 0, sampleRate > 0 else { return 0 }
            return Double(dataByteCount / bytesPerFrame) / Double(sampleRate)
        }
    }

    public enum ReadError: Error, Equatable {
        case notAWAVFile(String)
    }

    public static func read(at url: URL) throws -> Info {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 12), header.count == 12,
            header[0 ..< 4] == Data("RIFF".utf8), header[8 ..< 12] == Data("WAVE".utf8)
        else {
            throw ReadError.notAWAVFile("missing RIFF/WAVE header: \(url.lastPathComponent)")
        }

        var sampleRate = 0
        var channels = 0
        var bitsPerSample = 0
        var dataByteCount: Int?
        var sawFmt = false

        while true {
            guard let chunkHeader = try handle.read(upToCount: 8), chunkHeader.count == 8 else { break }
            let id = chunkHeader[chunkHeader.startIndex ..< chunkHeader.startIndex + 4]
            let size = Int(littleEndianUInt32(chunkHeader, offset: 4))
            if id == Data("fmt ".utf8) {
                guard let fmt = try handle.read(upToCount: size), fmt.count >= 16 else {
                    throw ReadError.notAWAVFile("truncated fmt chunk")
                }
                channels = Int(littleEndianUInt16(fmt, offset: 2))
                sampleRate = Int(littleEndianUInt32(fmt, offset: 4))
                bitsPerSample = Int(littleEndianUInt16(fmt, offset: 14))
                sawFmt = true
            } else if id == Data("data".utf8) {
                dataByteCount = size
                break  // PCM data is what we came for; no need to scan past it.
            } else {
                try handle.seek(toOffset: handle.offsetInFile + UInt64(size + size % 2))
            }
            if size % 2 == 1, id == Data("fmt ".utf8) {
                try handle.seek(toOffset: handle.offsetInFile + 1)
            }
        }

        guard sawFmt, let dataByteCount, sampleRate > 0, channels > 0, bitsPerSample > 0 else {
            throw ReadError.notAWAVFile("missing fmt/data chunk: \(url.lastPathComponent)")
        }
        return Info(
            sampleRate: sampleRate, channels: channels,
            bitsPerSample: bitsPerSample, dataByteCount: dataByteCount)
    }

    private static func littleEndianUInt32(_ data: Data, offset: Int) -> UInt32 {
        let i = data.startIndex + offset
        return UInt32(data[i]) | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2]) << 16 | UInt32(data[i + 3]) << 24
    }

    private static func littleEndianUInt16(_ data: Data, offset: Int) -> UInt16 {
        let i = data.startIndex + offset
        return UInt16(data[i]) | UInt16(data[i + 1]) << 8
    }
}
