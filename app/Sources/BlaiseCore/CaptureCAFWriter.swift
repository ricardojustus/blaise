import AVFoundation
import Foundation

// C11: crash-safe in-flight track writer. PROBED FACT (research/c11_capture.md
// §3, real kill -9 matrix): LPCM Int16 CAF is the ONLY format that survives a
// kill -9 without finalize — CAF's data-chunk size is -1 ("rest of file")
// until close and LPCM needs no packet table. AAC-m4a and AAC-CAF are dead
// after a crash (no moov / no pakt). Each capture track records through this
// writer; the m4a encode happens at stop/recovery (verified-encode gating).

public enum CaptureCAFWriterError: Error, CustomStringConvertible {
    case cannotCreate(String)
    case writeFailed(String)

    public var description: String {
        switch self {
        case .cannotCreate(let detail): return "cannot create capture CAF: \(detail)"
        case .writeFailed(let detail): return "capture CAF write failed: \(detail)"
        }
    }
}

public final class CaptureCAFWriter {
    /// 16 kHz mono Int16 — the pipeline's engine format, written directly so
    /// the stop-time encode is a single verified pass (~115 MB/h per track).
    public static let sampleRate = 16_000.0
    public static let channels: AVAudioChannelCount = 1

    public static var format: AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: channels,
            interleaved: true)!
    }

    public let url: URL
    private let file: AVAudioFile
    public private(set) var framesWritten: Int64 = 0

    /// Opens the CAF for writing. The settings force the CAF container with
    /// LPCM Int16 — the probed crash-safe combination, followed exactly.
    public init(url: URL) throws {
        self.url = url
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: Int(Self.channels),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        do {
            self.file = try AVAudioFile(
                forWriting: url, settings: settings, commonFormat: .pcmFormatInt16,
                interleaved: true)
        } catch {
            throw CaptureCAFWriterError.cannotCreate("\(url.lastPathComponent): \(error)")
        }
    }

    /// Appends a buffer (must already be in `Self.format`; the session's
    /// converters guarantee it). A throw here is the write-failure stop
    /// trigger (disk full, I/O error) — the session stops the recording
    /// immediately rather than losing more.
    public func write(_ buffer: AVAudioPCMBuffer) throws {
        do {
            try file.write(from: buffer)
            framesWritten += Int64(buffer.frameLength)
        } catch {
            throw CaptureCAFWriterError.writeFailed("\(url.lastPathComponent): \(error)")
        }
    }

    /// Finalizes the header. NOT load-bearing for crash safety (that is the
    /// point of the format choice) — just good hygiene on the clean path.
    public func close() {
        file.close()
    }
}
