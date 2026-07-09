import AVFoundation
import CoreAudio
import Foundation
import Synchronization
import os

// C11: the real capture engine — Core Audio global process tap + default
// input device composed into ONE private aggregate device (drift
// compensation on both sub-entries), one IOProc delivering sample-aligned
// mic + system buffers (validated call sequence, extracted). Each track
// converts to 16 kHz mono Int16 and streams into a crash-safe LPCM CAF
// (`CaptureCAFWriter`).
//
// NOT exercised by unit tests (creating the tap/aggregate and starting IO
// is what fires the TCC prompts); the gated capture integration test
// (BLAISE_TEST_CAPTURE=1) exercises it at/after the Human Touchpoint.
// Runtime facts confirmed by a real granted run (10/06/2026, C11 audit fix
// round; tone-energy analysis in the gated test header):
// - the IOProc buffer order is as composed: streams [0..<micStreamCount]
//   are the input device's, the rest are the tap's;
// - the mono tap delivers real mono system audio (no stereo fallback
//   needed on that run; the converter would downmix a stereo tap anyway);
// - the tap's self-exclusion extends to DESCENDANT processes of the
//   excluded process (audio played by a child process never reaches the
//   tap — fine for Blaise, which must not capture its own sounds).

public enum CaptureSessionError: Error, CustomStringConvertible {
    case coreAudio(String, OSStatus)
    case noDefaultInputDevice
    case tapFormatUnavailable

    public var description: String {
        switch self {
        case .coreAudio(let step, let status): return "\(step) failed (OSStatus \(status))"
        case .noDefaultInputDevice: return "no default input device"
        case .tapFormatUnavailable: return "tap format query failed"
        }
    }
}

public final class CaptureSession: AudioCapturing, @unchecked Sendable {
    private let logger = Logger(subsystem: BlaiseBundle.identifier, category: "capture.session")
    /// IO callbacks land here (never blocked); conversion + file writes hop
    /// to `processingQueue` (validated pattern: the IO thread only copies out).
    private let ioQueue = DispatchQueue(label: BlaiseBundle.subsystem("capture.io"))
    private let processingQueue = DispatchQueue(label: BlaiseBundle.subsystem("capture.processing"))

    // All mutable state below is owned by processingQueue (start/stop hop
    // onto it synchronously).
    private var graph: Graph?
    private var writers: (system: CaptureCAFWriter, mic: CaptureCAFWriter)?
    private var onEvent: (@Sendable (CaptureEngineEvent) -> Void)?
    /// Buffers from a torn-down graph generation are discarded (route-change
    /// rebuild races).
    private var generation = 0
    private var silenceDetector = MicSilenceDetector()
    /// G12 §2: the last time a level-meter RMS pair was emitted (the ≤ 10 Hz
    /// source throttle — buffers arrive far faster). Owned by processingQueue.
    private var lastLevelEmit: Date?
    private var stopped = true
    /// Set after a write failure so subsequent buffers are dropped while the
    /// controller's stop runs.
    private var writeFailed = false
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    public init() {}

    // MARK: - AudioCapturing

    @discardableResult
    public func start(
        systemCAF: URL, micCAF: URL,
        onEvent: @escaping @Sendable (CaptureEngineEvent) -> Void
    ) async throws -> CaptureStartInfo {
        try processingQueue.sync {
            precondition(stopped, "capture session already started")
            let system = try CaptureCAFWriter(url: systemCAF)
            let mic = try CaptureCAFWriter(url: micCAF)
            self.writers = (system, mic)
            self.onEvent = onEvent
            self.silenceDetector = MicSilenceDetector()
            self.lastLevelEmit = nil
            self.stopped = false
            self.writeFailed = false
            do {
                try buildGraph()
            } catch {
                system.close()
                mic.close()
                self.writers = nil
                self.stopped = true
                throw error
            }
            installRouteListeners()
            return CaptureStartInfo(micStreams: graph?.micStreamCount ?? 0)
        }
    }

    public func stop() async {
        processingQueue.sync {
            guard !stopped else { return }
            stopped = true
            removeRouteListeners()
            teardownGraph()
            writers?.system.close()
            writers?.mic.close()
            writers = nil
            onEvent = nil
        }
    }

    // MARK: - Graph (tap + aggregate + IOProc), built/rebuilt on processingQueue

    private struct Graph {
        var tapID: AudioObjectID
        var aggregateID: AudioObjectID
        var aggregateUID: String
        var procID: AudioDeviceIOProcID
        /// Streams [0..<micStreamCount] are the input sub-device's; the rest
        /// are the tap's (sub-devices listed before taps in the composition;
        /// confirmed by the gated integration test's tone-energy
        /// discrimination on a real granted run, 10/06/2026).
        var micStreamCount: Int
        var streamFormats: [AVAudioFormat]
        var micConverter: AVAudioConverter?
        var systemConverter: AVAudioConverter?
    }

    private func buildGraph() throws {
        // 1. Resolve OUR HAL process object: CATapDescription takes
        // AudioObjectIDs, NOT raw PIDs (research §1 warning).
        let selfObject = try Self.translatePIDToProcessObject(pid: getpid())

        // 2. The tap: mono global mix excluding ourselves.
        let description = CaptureDescriptors.tapDescription(excludingSelf: selfObject)
        var tapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else {
            throw CaptureSessionError.coreAudio("AudioHardwareCreateProcessTap", status)
        }

        // 3. The aggregate: default input sub-device + sub-tap, drift
        // compensation on both. Error paths unwind in reverse order.
        guard let inputDevice = Self.defaultDevice(selector: kAudioHardwarePropertyDefaultInputDevice),
            let inputUID = Self.deviceUID(inputDevice)
        else {
            _ = AudioHardwareDestroyProcessTap(tapID)
            throw CaptureSessionError.noDefaultInputDevice
        }
        let aggregateUID = CaptureDescriptors.makeAggregateUID()
        let composition = CaptureDescriptors.aggregateComposition(
            tapUID: description.uuid.uuidString,
            inputDeviceUID: inputUID,
            aggregateUID: aggregateUID)
        // Live-session guard: the launch-time stale-aggregate cleanup must
        // never destroy the device an active capture is using. The UID is
        // minted client-side, so register BEFORE creation — no window in
        // which the device exists unguarded.
        Self.liveAggregateUIDs.withLock { _ = $0.insert(aggregateUID) }
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregateID)
        guard status == noErr else {
            Self.liveAggregateUIDs.withLock { _ = $0.remove(aggregateUID) }
            _ = AudioHardwareDestroyProcessTap(tapID)
            throw CaptureSessionError.coreAudio("AudioHardwareCreateAggregateDevice", status)
        }

        do {
            // 4. Stream layout + formats (buffer[i] ↔ stream[i] in the IOProc).
            let micStreamCount = Self.inputStreamCount(of: inputDevice)
            if micStreamCount == 0 {
                // LOUD: the aggregate exposes no input-device streams — the
                // mic track will stay empty (the silence detector cannot
                // fire on no data). This event covers the ROUTE-CHANGE
                // rebuild; at initial start the controller emits the warning
                // deterministically after `.started`, from CaptureStartInfo
                // (an event here races the start reset).
                logger.error("input device exposes no streams; mic track will be EMPTY")
                onEvent?(.micSilence(active: true))
            } else {
                // A route-change rebuild that RESTORED a working input must
                // clear a standing zero-stream warning (nothing else ever
                // would — the silence detector restarts fresh and re-fires
                // in 60 s if the new device is genuinely silent). Harmless
                // at initial start: no warning is standing.
                onEvent?(.micSilence(active: false))
            }
            let streams = Self.inputStreams(of: aggregateID)
            // B3: the aggregate delivers ALL streams at the master (mic) rate via
            // drift compensation, but each stream's virtual format reports its OWN
            // nominal rate (mic 48k / tap 44.1k). Building converters from that
            // resamples by the wrong ratio — the 48000/44100 capture drift. Read
            // ONE delivered rate from the aggregate + validate it against the mic's
            // available rates; build BOTH converters from it, OR fall back
            // all-or-nothing to the per-stream format (never a mixed graph; a
            // drifted recording is recoverable, no recording is not — Floor 2).
            let aggregateRate = Self.aggregateNominalSampleRate(aggregateID)
            let plausibleRanges = Self.availableNominalSampleRates(inputDevice)
            let deliveredRate = Self.resolvedConverterRate(aggregateRate: aggregateRate) {
                Self.isPlausibleRate($0, within: plausibleRanges)
            }
            let streamASBDs: [AudioStreamBasicDescription] = try streams.map { stream in
                guard let asbd = Self.streamVirtualFormat(stream)
                else { throw CaptureSessionError.tapFormatUnavailable }
                return asbd
            }
            let streamFormats: [AVAudioFormat]
            if let rate = deliveredRate {
                logger.notice(
                    "capture rate: aggregate Fs=\(rate, privacy: .public) streams=\(streams.count, privacy: .public) target=\(CaptureCAFWriter.sampleRate, privacy: .public)")
                streamFormats = try streamASBDs.map { asbd in
                    guard let format = Self.converterInputFormat(streamASBD: asbd, rate: rate)
                    else { throw CaptureSessionError.tapFormatUnavailable }
                    return format
                }
            } else {
                logger.error(
                    "aggregate nominal rate unavailable/implausible (got \(aggregateRate ?? -1, privacy: .public)); falling back to per-stream virtual format")
                streamFormats = try streamASBDs.map { asbd in
                    var mutable = asbd
                    guard let format = AVAudioFormat(streamDescription: &mutable)
                    else { throw CaptureSessionError.tapFormatUnavailable }
                    return format
                }
            }
            let target = CaptureCAFWriter.format
            let micConverter = streamFormats.indices.contains(0) && micStreamCount > 0
                ? AVAudioConverter(from: streamFormats[0], to: target) : nil
            let systemConverter = streamFormats.indices.contains(micStreamCount)
                ? AVAudioConverter(from: streamFormats[micStreamCount], to: target) : nil

            // 5. IOProc on the dedicated serial queue; the block copies
            // buffers out and hops to processingQueue, never blocking IO.
            var procID: AudioDeviceIOProcID?
            let buildGeneration = generation
            status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) {
                [weak self] _, inInputData, _, _, _ in
                self?.captureBuffers(inInputData, generation: buildGeneration)
            }
            guard status == noErr, let procID else {
                throw CaptureSessionError.coreAudio("AudioDeviceCreateIOProcIDWithBlock", status)
            }
            status = AudioDeviceStart(aggregateID, procID)
            guard status == noErr else {
                _ = AudioDeviceDestroyIOProcID(aggregateID, procID)
                throw CaptureSessionError.coreAudio("AudioDeviceStart", status)
            }

            graph = Graph(
                tapID: tapID, aggregateID: aggregateID, aggregateUID: aggregateUID,
                procID: procID,
                micStreamCount: micStreamCount, streamFormats: streamFormats,
                micConverter: micConverter, systemConverter: systemConverter)
            logger.notice(
                "capture graph live: \(streams.count) streams (\(micStreamCount) mic), tap format \(streamFormats.last.map { "\($0.sampleRate) Hz \($0.channelCount) ch" } ?? "unknown")")
        } catch {
            Self.liveAggregateUIDs.withLock { _ = $0.remove(aggregateUID) }
            _ = AudioHardwareDestroyAggregateDevice(aggregateID)
            _ = AudioHardwareDestroyProcessTap(tapID)
            throw error
        }
    }

    /// Teardown order is always IOProc → aggregate → tap (validated order).
    private func teardownGraph() {
        guard let graph else { return }
        generation += 1
        _ = AudioDeviceStop(graph.aggregateID, graph.procID)
        _ = AudioDeviceDestroyIOProcID(graph.aggregateID, graph.procID)
        _ = AudioHardwareDestroyAggregateDevice(graph.aggregateID)
        _ = AudioHardwareDestroyProcessTap(graph.tapID)
        Self.liveAggregateUIDs.withLock { _ = $0.remove(graph.aggregateUID) }
        self.graph = nil
    }

    // MARK: - Route changes (default output OR input): full rebuild

    /// The tap follows the default output for audio by itself, but the
    /// negotiated format can change with the route (48 kHz speakers →
    /// Bluetooth handsfree rates) — keep the rebuild (research §1 note).
    /// The FILES stay open across the swap; the tracks just continue.
    private func installRouteListeners() {
        for selector in [
            kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultInputDevice,
        ] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.processingQueue.async { self?.rebuildAfterRouteChange() }
            }
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, processingQueue, block)
            if status == noErr {
                listeners.append((address, block))
            }
        }
    }

    private func removeRouteListeners() {
        for (address, block) in listeners {
            var address = address
            _ = AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, processingQueue, block)
        }
        listeners.removeAll()
    }

    private func rebuildAfterRouteChange() {
        guard !stopped else { return }
        logger.notice("default device changed — rebuilding capture graph")
        teardownGraph()
        do {
            try buildGraph()
        } catch {
            // Rebuild failure = capture cannot continue; route through the
            // write-failure stop policy (stop + encode what exists).
            logger.error("capture graph rebuild failed: \(error)")
            onEvent?(.writeFailure("audio route change broke the capture (\(error))"))
        }
    }

    // MARK: - IO path

    /// On ioQueue: copy out, then hop. Never blocks the IO thread.
    private func captureBuffers(_ list: UnsafePointer<AudioBufferList>, generation: Int) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        var copies: [Data] = []
        copies.reserveCapacity(buffers.count)
        for buffer in buffers {
            guard let data = buffer.mData, buffer.mDataByteSize > 0 else {
                copies.append(Data())
                continue
            }
            copies.append(Data(bytes: data, count: Int(buffer.mDataByteSize)))
        }
        processingQueue.async { [weak self] in
            self?.processCopiedBuffers(copies, generation: generation)
        }
    }

    private func processCopiedBuffers(_ copies: [Data], generation: Int) {
        guard generation == self.generation, !stopped, !writeFailed,
            let graph, let writers
        else { return }

        var micData = Data()
        var systemData = Data()
        for (index, copy) in copies.enumerated() {
            if index < graph.micStreamCount { micData.append(copy) } else { systemData.append(copy) }
        }

        // Health: all-zero mic while the system track carries signal.
        let micFormat = graph.streamFormats.first
        let windowSeconds: Double
        if let micFormat, micFormat.streamDescription.pointee.mBytesPerFrame > 0 {
            windowSeconds =
                Double(micData.count / Int(micFormat.streamDescription.pointee.mBytesPerFrame))
                / micFormat.sampleRate
        } else {
            windowSeconds = 0
        }
        if let change = silenceDetector.observe(
            micAllZero: !micData.isEmpty && micData.allSatisfy { $0 == 0 },
            systemActive: systemData.contains { $0 != 0 },
            windowSeconds: windowSeconds)
        {
            onEvent?(.micSilence(active: change))
        }

        // G12 §2: the live level meter rides this same off-IO processing queue
        // (zero extra audio taps). Throttle the emission to ≤ 10 Hz at the
        // source — buffers arrive far faster, and the meter never needs more.
        // The RMS is raw; the holder's `LevelMeter` model smooths and
        // silence-detects. A `bitsPerChannel` of 0 (unknown format) yields 0,
        // so the meter shows quiet rather than garbage.
        let now = Date()
        if now.timeIntervalSince(lastLevelEmit ?? .distantPast) >= LevelMeter.minPublishInterval {
            lastLevelEmit = now
            let micBytesPerSample = micFormat.map {
                Int($0.streamDescription.pointee.mBitsPerChannel) / 8
            } ?? 0
            let systemBytesPerSample = graph.streamFormats.indices.contains(graph.micStreamCount)
                ? Int(graph.streamFormats[graph.micStreamCount].streamDescription.pointee.mBitsPerChannel) / 8
                : 0
            onEvent?(.level(
                you: AudioRMS.rms(of: micData, bytesPerSample: micBytesPerSample),
                others: AudioRMS.rms(of: systemData, bytesPerSample: systemBytesPerSample)))
        }

        do {
            if !micData.isEmpty, let format = graph.streamFormats.first,
                let converter = graph.micConverter
            {
                try convertAndWrite(micData, sourceFormat: format, converter: converter, writer: writers.mic)
            }
            if !systemData.isEmpty, graph.streamFormats.indices.contains(graph.micStreamCount),
                let converter = graph.systemConverter
            {
                try convertAndWrite(
                    systemData, sourceFormat: graph.streamFormats[graph.micStreamCount],
                    converter: converter, writer: writers.system)
            }
        } catch {
            writeFailed = true
            onEvent?(.writeFailure("\(error)"))
        }
    }

    private func convertAndWrite(
        _ data: Data, sourceFormat: AVAudioFormat, converter: AVAudioConverter,
        writer: CaptureCAFWriter
    ) throws {
        let bytesPerFrame = Int(sourceFormat.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return }
        let frames = AVAudioFrameCount(data.count / bytesPerFrame)
        guard frames > 0,
            let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frames)
        else { return }
        input.frameLength = frames
        data.withUnsafeBytes { raw in
            let target = input.audioBufferList.pointee.mBuffers
            if let dest = target.mData {
                dest.copyMemory(
                    from: raw.baseAddress!, byteCount: min(Int(target.mDataByteSize), data.count))
            }
        }

        let ratio = CaptureCAFWriter.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(frames) * ratio).rounded(.up) + 64)
        guard
            let output = AVAudioPCMBuffer(pcmFormat: CaptureCAFWriter.format, frameCapacity: capacity)
        else { return }
        final class FeedOnce: @unchecked Sendable {
            var fed = false
        }
        let feed = FeedOnce()
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if feed.fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            feed.fed = true
            inputStatus.pointee = .haveData
            return input
        }
        if let conversionError {
            throw CaptureCAFWriterError.writeFailed("conversion: \(conversionError)")
        }
        if status != .error, output.frameLength > 0 {
            try writer.write(output)
        }
    }

    // MARK: - Stale-aggregate cleanup (launch hygiene)

    /// Aggregate UIDs of LIVE capture graphs (registered at build, removed
    /// at teardown): `cleanupStaleAggregates` must never destroy the device
    /// a running session is using — destroying it silently stops buffer
    /// delivery with no write error (the recording stays "green" while
    /// capturing nothing).
    static let liveAggregateUIDs = Mutex<Set<String>>([])

    /// A leftover Blaise aggregate is stale only if no live session owns it.
    static func isStaleAggregate(uid: String) -> Bool {
        uid.hasPrefix(CaptureDescriptors.aggregateUIDPrefix)
            && !liveAggregateUIDs.withLock { $0.contains(uid) }
    }

    /// A crashed session's aggregate device lingers in the HAL — destroy any
    /// leftover with our UID prefix at launch (stale-device cleanup),
    /// EXCEPT a live session's device (a recording started before this runs
    /// — MenuBarExtra/⌥⌘R work independently of launch ordering).
    /// Device enumeration does not fire TCC prompts.
    public static func cleanupStaleAggregates() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0
        else { return }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return }
        for id in ids {
            guard let uid = deviceUID(id), isStaleAggregate(uid: uid) else { continue }
            let status = AudioHardwareDestroyAggregateDevice(id)
            Logger(subsystem: BlaiseBundle.identifier, category: "capture.session")
                .notice("destroyed stale aggregate \(uid) (status \(status))")
        }
    }

    // MARK: - HAL helpers

    static func translatePIDToProcessObject(pid: pid_t) throws -> AudioObjectID {
        var pid = pid
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &pid) { pidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<pid_t>.size), pidPtr, &size, &objectID)
        }
        guard status == noErr, objectID != kAudioObjectUnknown else {
            throw CaptureSessionError.coreAudio("TranslatePIDToProcessObject", status)
        }
        return objectID
    }

    static func defaultDevice(selector: AudioObjectPropertySelector) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
            deviceID != kAudioObjectUnknown
        else { return nil }
        return deviceID
    }

    static func deviceUID(_ deviceID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        return uid as String?
    }

    static func inputStreamCount(of deviceID: AudioObjectID) -> Int {
        inputStreams(of: deviceID).count
    }

    static func inputStreams(of deviceID: AudioObjectID) -> [AudioStreamID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0
        else { return [] }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &streams) == noErr
        else { return [] }
        return streams
    }

    static func streamVirtualFormat(_ streamID: AudioStreamID) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyVirtualFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(streamID, &address, 0, nil, &size, &asbd) == noErr
        else { return nil }
        return asbd
    }

    // MARK: - B3: aggregate-delivered sample rate (drift root fix)

    /// The aggregate's currently-delivered (master) sample rate. With the mic
    /// pinned as master (B3), every stream is drift-compensated to this rate, so
    /// it is the correct converter INPUT rate. nil if unreadable or <= 0.
    static func aggregateNominalSampleRate(_ deviceID: AudioObjectID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate) == noErr,
            rate > 0
        else { return nil }
        return rate
    }

    /// The device's advertised nominal-rate ranges (e.g. 44100, 48000). Empty if
    /// unreadable — callers then fall back to a sane absolute bound.
    static func availableNominalSampleRates(_ deviceID: AudioObjectID) -> [AudioValueRange] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr
        else { return [] }
        let stride = MemoryLayout<AudioValueRange>.stride
        let count = Int(size) / stride
        guard count > 0 else { return [] }
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: count)
        // Read EXACTLY count elements — never the raw HAL byte size, which (if it
        // is not a whole multiple of the stride) would let CoreAudio write past
        // the buffer. count == 0 already returned the sane-bound fallback above.
        size = UInt32(count * stride)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &ranges) == noErr
        else { return [] }
        return ranges
    }

    /// A HAL-reported rate is plausible only inside the device's advertised
    /// ranges (or, when those are unreadable, a sane absolute bound). B3-M3: a
    /// garbage-but-nonzero rate fed to BOTH converters would mis-rate the pair
    /// UNIFORMLY, evading the relative-drift playback safety net — so this is a
    /// real Floor-1 boundary check, not gold-plating.
    static func isPlausibleRate(_ rate: Double, within ranges: [AudioValueRange]) -> Bool {
        guard rate >= 8000, rate <= 192_000 else { return false }
        guard !ranges.isEmpty else { return true }
        return ranges.contains { rate >= $0.mMinimum - 1 && rate <= $0.mMaximum + 1 }
    }

    /// The single all-or-nothing gate (B3-M1): the validated aggregate rate, or
    /// nil to signal that BOTH converters fall back to per-stream formats.
    static func resolvedConverterRate(
        aggregateRate: Double?, plausible: (Double) -> Bool
    ) -> Double? {
        guard let rate = aggregateRate, rate > 0, plausible(rate) else { return nil }
        return rate
    }

    /// A converter INPUT format: the stream's own channel count + PCM format,
    /// with the sample rate overridden to the aggregate's delivered rate.
    /// `mBytesPerFrame` is rate-independent for LPCM, so only `mSampleRate`
    /// changes — safe for the format and the `data.count / bytesPerFrame` math.
    static func converterInputFormat(
        streamASBD: AudioStreamBasicDescription, rate: Double
    ) -> AVAudioFormat? {
        var asbd = streamASBD
        asbd.mSampleRate = rate
        return AVAudioFormat(streamDescription: &asbd)
    }
}
