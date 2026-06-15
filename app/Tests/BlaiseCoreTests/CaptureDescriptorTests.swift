import AVFoundation
import CoreAudio
import Foundation
import Testing

@testable import BlaiseCore

// C11 AC1: tap/aggregate descriptor construction — parameter SNAPSHOT tests
// against the research-verified forms (research/c11_capture.md §1). These
// construct description objects and dictionaries only; no HAL device is
// created, no IO starts, no TCC prompt can fire.

@Suite("C11 capture descriptors")
struct CaptureDescriptorTests {
    @Test("tap description: mono global tap excluding self, private, unmuted")
    func tapDescription() {
        let selfID = AudioObjectID(4242)
        let description = CaptureDescriptors.tapDescription(excludingSelf: selfID)
        #expect(description.isMono)
        #expect(description.isPrivate)
        #expect(description.muteBehavior == .unmuted)
        #expect(description.name == "Blaise capture tap")
        // Global-mix-minus-processes form: mixdown of everything EXCEPT the
        // excluded list (us). The UUID is the aggregate's sub-tap key.
        #expect(description.isMixdown)
        #expect(description.isExclusive)
        #expect(description.processes == [selfID])
        #expect(!description.uuid.uuidString.isEmpty)
    }

    @Test("aggregate composition: sub-device list + tap list + drift on BOTH + autostart OFF + private")
    func aggregateComposition() throws {
        let dict = CaptureDescriptors.aggregateComposition(
            tapUID: "TAP-UUID-STRING", inputDeviceUID: "BuiltInMicrophoneDevice",
            aggregateUID: "app.blaise.mac.test")

        // Key strings pinned to the SDK constants (the research-verified
        // forms; a constant drifting would break the recipe silently).
        #expect(kAudioAggregateDeviceSubDeviceListKey == "subdevices")
        #expect(kAudioAggregateDeviceTapListKey == "taps")
        #expect(kAudioSubDeviceUIDKey == "uid")
        #expect(kAudioSubTapUIDKey == "uid")
        #expect(kAudioSubDeviceDriftCompensationKey == "drift")
        #expect(kAudioSubTapDriftCompensationKey == "drift")
        #expect(kAudioAggregateDeviceTapAutoStartKey == "tapautostart")
        #expect(kAudioAggregateDeviceIsPrivateKey == "private")

        #expect(dict[kAudioAggregateDeviceUIDKey as String] as? String == "app.blaise.mac.test")
        #expect(dict[kAudioAggregateDeviceNameKey as String] as? String == "Blaise Capture")
        #expect(dict[kAudioAggregateDeviceIsPrivateKey as String] as? Bool == true)
        // Pinned FALSE: tap auto-start gates the whole aggregate's IO (mic
        // included) on another process playing audio — on a quiet system
        // nothing is captured at all (root-caused 10/06/2026, killMidCapture).
        #expect(dict[kAudioAggregateDeviceTapAutoStartKey as String] as? Bool == false)

        let subDevices = try #require(
            dict[kAudioAggregateDeviceSubDeviceListKey as String] as? [[String: Any]])
        #expect(subDevices.count == 1)
        #expect(subDevices[0][kAudioSubDeviceUIDKey as String] as? String == "BuiltInMicrophoneDevice")
        #expect(subDevices[0][kAudioSubDeviceDriftCompensationKey as String] as? Bool == true)

        let taps = try #require(
            dict[kAudioAggregateDeviceTapListKey as String] as? [[String: Any]])
        #expect(taps.count == 1)
        // The tap UID is the UUID STRING (CATapDescription objects crash
        // CoreAudio — capture note, pinned).
        #expect(taps[0][kAudioSubTapUIDKey as String] as? String == "TAP-UUID-STRING")
        #expect(taps[0][kAudioSubTapDriftCompensationKey as String] as? Bool == true)
    }

    @Test("aggregate UID carries the cleanup prefix")
    func aggregateUIDPrefix() {
        let uid = CaptureDescriptors.makeAggregateUID()
        #expect(uid.hasPrefix("app.blaise.mac."))
        #expect(uid.count > "app.blaise.mac.".count)
    }
}

// MARK: - CAF writer format assertions (AC1)

@Suite("C11 capture CAF writer")
struct CaptureCAFWriterTests {
    @Test("writes LPCM Int16 16 kHz mono CAF (the probed crash-safe format)")
    func formatAssertions() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-writer-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try CaptureCAFWriter(url: url)
        let format = CaptureCAFWriter.format
        #expect(format.sampleRate == 16_000)
        #expect(format.channelCount == 1)
        #expect(format.commonFormat == .pcmFormatInt16)

        let frames: AVAudioFrameCount = 16_000  // 1 s
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.int16ChannelData![0]
        for n in 0 ..< Int(frames) {
            samples[n] = Int16(6000 * sin(2 * .pi * 440 * Double(n) / 16_000))
        }
        try writer.write(buffer)
        #expect(writer.framesWritten == Int64(frames))
        writer.close()

        let readBack = try AVAudioFile(forReading: url)
        #expect(readBack.fileFormat.sampleRate == 16_000)
        #expect(readBack.fileFormat.channelCount == 1)
        #expect(readBack.length == Int64(frames))
        // CAF container, not WAV/m4a: first bytes are the 'caff' magic.
        let head = try Data(contentsOf: url, options: .mappedIfSafe).prefix(4)
        #expect(head == Data("caff".utf8))
    }

    @Test("a never-closed CAF is fully decodable (crash-safety by construction)")
    func decodableWithoutClose() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-writer-noclose-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try CaptureCAFWriter(url: url)
        let format = CaptureCAFWriter.format
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000)!
        buffer.frameLength = 8000
        try writer.write(buffer)
        // NO close: open a second reader against the live file — the LPCM
        // CAF data chunk is sized -1 ("rest of file") until close, so every
        // written frame is already readable (the probed kill -9 property).
        let readBack = try AVAudioFile(forReading: url)
        #expect(readBack.length == 8000)
        writer.close()
    }
}
