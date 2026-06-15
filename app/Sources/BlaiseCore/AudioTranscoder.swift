// @preconcurrency: AVAudioConverter's input block is typed @Sendable but is
// invoked synchronously inside convert(to:error:) on the calling thread; the
// buffer captures are safe (see ConversionState).
@preconcurrency import AVFoundation
import Foundation

/// C7-owned audio transcoding (research/c7_pipeline.md §1, probed):
/// - encode: import WAV → retained `audio.m4a` (D7: AAC-LC mono 32 kbps),
///   written via temp file + atomic rename;
/// - decode: retained `audio.m4a` → temp 16 kHz mono Int16 WAV for the
///   engines (`outFile.close()` finalizes the header — probed gotcha);
/// - duration: for the ingest verification decode.
public enum AudioTranscoderError: Error {
    case cannotOpen(String)
    case conversionFailed(String)
    case destinationExists(String)
}

public enum AudioTranscoder {
    // MARK: - Encode (WAV → AAC-LC 32k mono .m4a)

    /// Encodes `wavURL` to AAC-LC mono 32 kbps at `destination`, via a temp
    /// file in the same directory + atomic rename. Throws if the destination
    /// already exists (the retained audio is never overwritten — hard floor 2;
    /// the if-absent guard is the caller's, this is defense in depth).
    public static func encodeToM4A(wav wavURL: URL, destination: URL) throws {
        try encodeToM4A(wav: wavURL, destination: destination, midEncodeHook: nil)
    }

    /// `midEncodeHook` receives the fully-written TEMP file before the
    /// atomic rename — the ingest verification decode runs here, and an
    /// injected failure (or SIGKILL at the crash hook) must leave no
    /// `audio.m4a` at the final path.
    static func encodeToM4A(
        wav wavURL: URL, destination: URL, midEncodeHook: ((URL) throws -> Void)?
    ) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else {
            throw AudioTranscoderError.destinationExists(destination.path)
        }
        let inFile: AVAudioFile
        do {
            inFile = try AVAudioFile(forReading: wavURL)
        } catch {
            throw AudioTranscoderError.cannotOpen("cannot read \(wavURL.lastPathComponent): \(error)")
        }
        let sourceFormat = inFile.processingFormat

        let directory = destination.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let tempURL = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).tmp-\(UUID().uuidString).m4a")
        defer { try? fm.removeItem(at: tempURL) }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVEncoderBitRateKey: AudioConstants.retainedFormat.bitRate,
            AVNumberOfChannelsKey: AudioConstants.retainedFormat.channelCount,
            AVSampleRateKey: sourceFormat.sampleRate,
        ]
        do {
            let outFile = try AVAudioFile(forWriting: tempURL, settings: settings)
            // AVAudioFile.write requires buffers in EXACTLY the file's PCM
            // processing format; route through AVAudioConverter always (it
            // also mono-izes multichannel sources).
            guard let converter = AVAudioConverter(from: sourceFormat, to: outFile.processingFormat)
            else {
                throw AudioTranscoderError.conversionFailed("cannot build encode converter")
            }
            try convert(
                converter: converter, from: inFile, to: outFile.processingFormat,
                write: { try outFile.write(from: $0) })
            outFile.close()
        } catch let error as AudioTranscoderError {
            throw error
        } catch {
            throw AudioTranscoderError.conversionFailed("AAC encode failed: \(error)")
        }

        try midEncodeHook?(tempURL)
        PipelineCrashHooks.maybeKill(.ingestEncode)

        // Atomic claim of the final path; EEXIST means another writer beat us
        // (cannot happen single-process; defense in depth, never overwrite).
        if renamex_np(tempURL.path, destination.path, UInt32(RENAME_EXCL)) != 0 {
            throw AudioTranscoderError.conversionFailed(
                "atomic rename failed for \(destination.lastPathComponent): errno \(errno)")
        }
    }

    // MARK: - Decode (.m4a → 16 kHz mono Int16 WAV)

    /// Decodes the retained audio to the 16 kHz mono Int16 WAV the engines
    /// consume. Pull-style AVAudioConverter loop (probed); `close()` is what
    /// finalizes the WAV header.
    public static func decodeTo16kWAV(m4a m4aURL: URL, destination: URL) throws {
        let inFile: AVAudioFile
        do {
            inFile = try AVAudioFile(forReading: m4aURL)
        } catch {
            throw AudioTranscoderError.cannotOpen("cannot read \(m4aURL.lastPathComponent): \(error)")
        }
        guard
            let outFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
            let converter = AVAudioConverter(from: inFile.processingFormat, to: outFormat)
        else {
            throw AudioTranscoderError.conversionFailed("cannot build 16 kHz converter")
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            let outFile = try AVAudioFile(
                forWriting: destination, settings: settings,
                commonFormat: .pcmFormatInt16, interleaved: true)
            try convert(
                converter: converter, from: inFile, to: outFormat,
                write: { try outFile.write(from: $0) })
            outFile.close()
        } catch let error as AudioTranscoderError {
            throw error
        } catch {
            throw AudioTranscoderError.conversionFailed("WAV decode failed: \(error)")
        }
    }

    /// Duration in seconds via AVAudioFile (the ingest verification decode:
    /// the file must open and report a sane duration; AVAudioFile trims AAC
    /// encoder priming/padding exactly — probed).
    public static func duration(of url: URL) throws -> Double {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AudioTranscoderError.cannotOpen("cannot read \(url.lastPathComponent): \(error)")
        }
        let rate = file.processingFormat.sampleRate
        guard rate > 0 else { return 0 }
        return Double(file.length) / rate
    }

    // MARK: - Shared pull-style conversion loop

    /// The converter's input block is invoked synchronously inside
    /// `convert(to:error:)` on the calling thread; the box exists only to
    /// satisfy the @Sendable annotation on the block's type.
    private final class ConversionState: @unchecked Sendable {
        var reachedEnd = false
        var readError: Error?
    }

    private static func convert(
        converter: AVAudioConverter,
        from inFile: AVAudioFile,
        to outFormat: AVAudioFormat,
        write: (AVAudioPCMBuffer) throws -> Void
    ) throws {
        let inFormat = inFile.processingFormat
        let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: 65_536)!
        let state = ConversionState()

        while true {
            let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 65_536)!
            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError) { _, inputStatus in
                if state.reachedEnd {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                // EOF must be detected by position: read(into:) at EOF throws
                // a bare nilError on macOS 26 rather than returning 0 frames
                // (probed in-chunk).
                if inFile.framePosition >= inFile.length {
                    state.reachedEnd = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try inFile.read(into: inBuffer)
                } catch {
                    state.readError = error
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if inBuffer.frameLength == 0 {
                    state.reachedEnd = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inBuffer
            }
            if let readError = state.readError {
                throw AudioTranscoderError.conversionFailed("source read failed: \(readError)")
            }
            if let conversionError {
                throw AudioTranscoderError.conversionFailed("\(conversionError)")
            }
            if outBuffer.frameLength > 0 {
                try write(outBuffer)
            }
            if status == .endOfStream || (status == .haveData && outBuffer.frameLength == 0) {
                break
            }
            if status == .inputRanDry && state.reachedEnd && outBuffer.frameLength == 0 {
                break
            }
        }
    }
}
