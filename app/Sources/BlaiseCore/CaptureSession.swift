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
    case converterUnavailable(String)

    public var description: String {
        switch self {
        case .coreAudio(let step, let status): return "\(step) failed (OSStatus \(status))"
        case .noDefaultInputDevice: return "no default input device"
        case .tapFormatUnavailable: return "tap format query failed"
        case .converterUnavailable(let track): return "\(track) converter could not be built"
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

    // B4 route-change resilience (all owned by processingQueue). One physical
    // route event (AirPods connect) fires the default-device listeners many
    // times over a few seconds — observed 6 rebuilds in 5 s with the rate
    // flapping 48k↔24k (2026-07-23 log) — and every destructive rebuild
    // drops the audio in its teardown→live window. So: triggers coalesce
    // into ONE debounced rebuild; a failed rebuild walks a retry ladder
    // before declaring the capture dead; and the audio lost while the graph
    // was down is back-filled as silence so the timeline stays wall-clock
    // true (the stitcher gap-fills PART boundaries only, never in-part gaps).
    /// The one pending debounced rebuild/retry (superseded by newer triggers,
    /// cancelled by stop).
    private var pendingRebuild: DispatchWorkItem?
    /// True when the pending rebuild MUST run (device identity changed).
    /// A rate-only pending is skipped if the aggregate's rate never moved.
    private var pendingForced = false
    /// Position on the retry ladder; reset by success, or by a fresh route
    /// change only while a graph is live (see `scheduleRebuild`).
    private var rebuildAttempt = 0
    /// Monotonic uptime of the FIRST trigger in the current debounce burst.
    /// Bounds the trailing debounce so a fast-flapping device cannot starve
    /// the rebuild forever. Cleared when the rebuild fires.
    private var debounceFirstTriggerUptime: TimeInterval?
    /// Rate-only rebuilds performed this session, against
    /// `maxRateTriggeredRebuilds`. Guards the self-triggering loop that an
    /// unsettled post-creation HAL rate reading would otherwise sustain.
    private var rateTriggeredRebuilds = 0
    /// One-shot latch for the ceiling log line.
    private var rateCeilingReported = false
    /// F-1: the down-clock + one-shot threshold alarm behind the visible
    /// capture-down warning (armed at teardown, cleared on successful rebuild
    /// / stop). It owns its own queue and state — R2-F2: a `buildGraph()`
    /// blocking `processingQueue` past the deadline must not starve the
    /// watchdog that watches it.
    private let captureDownAlarm = CaptureDownAlarm(
        threshold: CaptureSession.captureDownAlarmSeconds)
    /// Monotonic uptime when buffers were last accepted for writing — the
    /// gap-fill anchor. Uptime, never wall-clock: system sleep must not be
    /// back-filled as hours of silence (the silence watchdog pins the same
    /// clock choice for the same reason).
    private var lastBufferUptime: TimeInterval?

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
            self.pendingForced = false
            self.rebuildAttempt = 0
            self.lastBufferUptime = nil
            // F-3: the route-change bounds are PER RECORDING, and the engine
            // instance is app-lifetime — without these resets the rate ceiling
            // was per-app-launch, a stale down-clock could warn instantly (or
            // a stale latch could suppress the warning entirely), and a stale
            // debounce anchor defeated the next session's first debounce.
            self.rateTriggeredRebuilds = 0
            self.rateCeilingReported = false
            self.captureDownAlarm.reset(onEvent: onEvent)
            self.debounceFirstTriggerUptime = nil
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
            pendingRebuild?.cancel()
            pendingRebuild = nil
            pendingForced = false
            captureDownAlarm.reset(onEvent: nil)
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
        /// B4: the aggregate's nominal rate as READ at build time (raw, pre-
        /// validation). The rate listener compares against this observation,
        /// so a rebuild happens only when the reported rate actually MOVED —
        /// loop-proof: a fresh aggregate notifies for its own initial rate.
        var observedRateAtBuild: Double?
        /// B4: nominal-rate listener on this aggregate (removed at teardown).
        var rateListener: AudioObjectPropertyListenerBlock?
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
            // F-8 / B3 §3-observability: master UID + per-stream virtual
            // rates + converter input rate, so a field report ("silent /
            // pitched after AirPods") can be diagnosed from this one line —
            // on BOTH branches (the fallback is where drift is EXPECTED).
            let virtualRates = streamASBDs.map(\.mSampleRate)
            if let rate = deliveredRate {
                logger.notice(
                    "capture rate: aggregate Fs=\(rate, privacy: .public) master=\(inputUID, privacy: .private(mask: .hash)) streams=\(streams.count, privacy: .public) virtualRates=\(virtualRates, privacy: .public) converterInput=\(rate, privacy: .public) target=\(CaptureCAFWriter.sampleRate, privacy: .public)")
                streamFormats = try streamASBDs.map { asbd in
                    guard let format = Self.converterInputFormat(streamASBD: asbd, rate: rate)
                    else { throw CaptureSessionError.tapFormatUnavailable }
                    return format
                }
            } else {
                logger.error(
                    "aggregate nominal rate unavailable/implausible (got \(aggregateRate ?? -1, privacy: .public)); falling back to per-stream virtual format — master=\(inputUID, privacy: .private(mask: .hash)) streams=\(streams.count, privacy: .public) virtualRates=\(virtualRates, privacy: .public) converterInput=per-stream target=\(CaptureCAFWriter.sampleRate, privacy: .public)")
                streamFormats = try streamASBDs.map { try Self.fallbackInputFormat(streamASBD: $0) }
            }
            let target = CaptureCAFWriter.format
            let micConverter = streamFormats.indices.contains(0) && micStreamCount > 0
                ? AVAudioConverter(from: streamFormats[0], to: target) : nil
            let systemConverter = streamFormats.indices.contains(micStreamCount)
                ? AVAudioConverter(from: streamFormats[micStreamCount], to: target) : nil
            // A stream the layout SELECTED whose converter cannot be built is a
            // failed build, not a silent no-op: a nil converter here previously
            // left that track empty for the whole session with a green
            // indicator (audit F-5; floor 2 — un-captured audio cannot be
            // regenerated). Throwing routes through the existing ladder →
            // `.writeFailure` stop policy.
            if micStreamCount > 0, micConverter == nil {
                throw CaptureSessionError.converterUnavailable("mic")
            }
            if streamFormats.indices.contains(micStreamCount), systemConverter == nil {
                throw CaptureSessionError.converterUnavailable("system")
            }
            // R2-F4: the tap contributed NO stream to the aggregate, so there
            // is nothing to select for the system track and it stays empty for
            // the whole recording behind a green indicator. Loud, mirroring
            // the mic-side treatment above (log only: the guard above cannot
            // fire here — the converter was never built).
            if streams.count <= micStreamCount {
                logger.error(
                    "aggregate exposes no tap streams (\(streams.count) streams, \(micStreamCount) mic); system track will be EMPTY")
            }
            // F-6: additional mic streams beyond stream 0 are DROPPED, loudly —
            // concatenating simultaneous streams serializes them as consecutive
            // time (a 2-stream device doubled the mic track's duration).
            // Proper same-timestamp mixing is backlogged (AB entry).
            if micStreamCount > 1 {
                logger.error(
                    "input device exposes \(micStreamCount) streams; capturing stream 0 only — further streams are dropped, not serialized")
            }

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

            // B4: watch the aggregate's nominal rate. Only default-device
            // IDENTITY changes trigger the route listeners — a same-device
            // rate renegotiation (Bluetooth flapped 48k↔24k within seconds
            // on 2026-07-23) would otherwise leave the converters resampling
            // by the wrong ratio: pitch-shifted tracks and no error anywhere.
            let rateListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.processingQueue.async { self?.scheduleRebuild(forced: false) }
            }
            var rateAddress = Self.nominalRateAddress
            let rateStatus = AudioObjectAddPropertyListenerBlock(
                aggregateID, &rateAddress, processingQueue, rateListener)
            if rateStatus != noErr {
                logger.error(
                    "nominal-rate listener install failed (OSStatus \(rateStatus)) — same-device rate changes will not rebuild")
            }

            graph = Graph(
                tapID: tapID, aggregateID: aggregateID, aggregateUID: aggregateUID,
                procID: procID,
                micStreamCount: micStreamCount, streamFormats: streamFormats,
                micConverter: micConverter, systemConverter: systemConverter,
                observedRateAtBuild: aggregateRate,
                rateListener: rateStatus == noErr ? rateListener : nil)
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
        if let rateListener = graph.rateListener {
            var rateAddress = Self.nominalRateAddress
            _ = AudioObjectRemovePropertyListenerBlock(
                graph.aggregateID, &rateAddress, processingQueue, rateListener)
        }
        _ = AudioDeviceStop(graph.aggregateID, graph.procID)
        _ = AudioDeviceDestroyIOProcID(graph.aggregateID, graph.procID)
        _ = AudioHardwareDestroyAggregateDevice(graph.aggregateID)
        _ = AudioHardwareDestroyProcessTap(graph.tapID)
        Self.liveAggregateUIDs.withLock { _ = $0.remove(graph.aggregateUID) }
        self.graph = nil
    }

    // MARK: - Route changes (default output OR input): debounced full rebuild

    /// B4: the quiet window that collapses a notification storm (both
    /// default-device listeners fire, several times, per physical event)
    /// into one destructive rebuild. The old graph keeps running while the
    /// window is open, so a still-working route loses nothing to the wait.
    static let rebuildDebounceSeconds: TimeInterval = 0.5
    /// B4: backoff before a rebuild failure ends the recording. A route
    /// change mid-Bluetooth-negotiation fails transiently (no default input
    /// for a moment after an unplug; HAL errors while devices flap) — a
    /// transient error must not kill a recording (Floor 2: dead air for
    /// seconds is recoverable, a stopped capture is not).
    static let rebuildRetryDelays: [TimeInterval] = [0.5, 1, 2, 4, 8]
    /// B4 (audit): hard ceiling on the debounce. The window above is a
    /// TRAILING debounce — every new trigger restarts it — so a device
    /// flapping faster than 2 Hz would starve the rebuild indefinitely and
    /// keep capturing through a graph whose converters no longer match the
    /// hardware. The field log that motivated this fix recorded 6 rebuilds in
    /// 5 s (~0.83 s apart), only 1.7x from that threshold. Past this age the
    /// rebuild fires regardless of fresh triggers.
    static let rebuildMaxWaitSeconds: TimeInterval = 3
    /// B4 (audit): the graph must not stay DOWN silently. Retries are correct
    /// (a transient HAL error mid-negotiation should not kill a recording),
    /// but while the graph is nil ZERO bytes reach either track — and the
    /// menu-bar indicator would otherwise stay green with the timer running,
    /// so the user only discovers the loss post-meeting. Past this much
    /// continuous downtime the session raises a VISIBLE alarm and keeps
    /// retrying: honest degradation beats a silent green light.
    static let captureDownAlarmSeconds: TimeInterval = 8
    /// B4 (audit): ceiling on rate-only rebuilds per session. The nominal-rate
    /// listener compares against the rate observed at build time; if the HAL
    /// reports an unsettled rate immediately after aggregate creation (the
    /// project's own B3 spec names this timing as a known, unresolved risk),
    /// each rebuild re-arms the same comparison and the session shreds itself
    /// into fragments — every rebuild excising 0.1-2.2 s of real speech, then
    /// back-filled with silence so the file duration still looks correct.
    /// Whether the HAL actually does this is UNVERIFIED (it needs a live
    /// granted probe), so this bound makes the fix safe either way: genuine
    /// rate changes are rare, and a device that legitimately renegotiates
    /// more than this in one session has a bigger problem than pitch drift.
    static let maxRateTriggeredRebuilds = 3

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
                self?.processingQueue.async { self?.scheduleRebuild(forced: true) }
            }
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, processingQueue, block)
            if status == noErr {
                listeners.append((address, block))
            } else {
                // F-7: a dead route listener means that selector's device
                // changes never rebuild — capture degrades silently. Same
                // observability rule as the rate-listener install above.
                logger.error(
                    "route listener install failed (selector \(selector), OSStatus \(status)) — that selector's route changes will not rebuild")
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

    /// B4: every rebuild trigger lands here and coalesces into the single
    /// pending work item. `forced` (device identity changed) always
    /// rebuilds; a rate-only trigger may be skipped at fire time if the
    /// aggregate's reported rate never actually moved.
    private func scheduleRebuild(forced: Bool) {
        guard !stopped else { return }
        pendingForced = pendingForced || forced
        // A fresh route change means the device world CHANGED — whatever
        // failed before may work now, so the retry ladder gets ONE reset per
        // down-period. It is deliberately NOT reset on every forced trigger:
        // a flapping device produces them faster than the ladder can run out,
        // so the ladder would never exhaust, `.writeFailure` would never fire,
        // and the recording would stay green while capturing nothing.
        if forced, graph != nil { rebuildAttempt = 0 }
        // F-2: during a down-period the RETRY LADDER owns the schedule. A
        // fresh trigger while a retry backoff is pending must not collapse it
        // to the debounce window (that let a trigger storm exhaust the ladder
        // in ~3-5 s and stop the recording on a transient — floor 2). The
        // trigger's meaning is preserved: `pendingForced` is already latched
        // and honored when the pending rebuild fires.
        if graph == nil, pendingRebuild != nil { return }
        enqueueRebuild(after: Self.rebuildDebounceSeconds)
    }

    /// F-4: the debounce-ceiling arithmetic, pure (mirrors `silenceFillFrames`
    /// / `rateChangeRequiresRebuild`). First trigger of a burst stamps the
    /// anchor; once `maxWait` has elapsed since it, the effective delay is 0.
    static func effectiveDebounceDelay(
        requested: TimeInterval, firstTriggerUptime: TimeInterval, now: TimeInterval,
        maxWait: TimeInterval
    ) -> TimeInterval {
        min(requested, max(0, maxWait - (now - firstTriggerUptime)))
    }

    private func enqueueRebuild(after delay: TimeInterval) {
        // Trailing debounce with a hard ceiling: the first trigger of a burst
        // stamps the deadline, and once `rebuildMaxWaitSeconds` has elapsed the
        // rebuild fires no matter how fast triggers keep arriving. Without the
        // ceiling a device flapping faster than the window starves the rebuild
        // forever (see `rebuildMaxWaitSeconds`). RETRY BACKOFFS DO NOT PASS
        // THROUGH HERE (F-2): the ceiling clamped the ladder's 4 s/8 s rungs
        // to 3 s — see `scheduleRetry`.
        let now = ProcessInfo.processInfo.systemUptime
        let first = debounceFirstTriggerUptime ?? now
        debounceFirstTriggerUptime = first
        let effective = Self.effectiveDebounceDelay(
            requested: delay, firstTriggerUptime: first, now: now,
            maxWait: Self.rebuildMaxWaitSeconds)
        // The ceiling is applied HERE, before the hand-off: `scheduleRetry`
        // only owns the (re)scheduling, never the debounce bound (F-2).
        scheduleRetry(after: effective)
    }

    /// F-2: a retry backoff is scheduled DIRECTLY at the ladder's delay — never
    /// through `enqueueRebuild`, whose ceiling is a DEBOUNCE bound, not a
    /// backoff bound.
    private func scheduleRetry(after delay: TimeInterval) {
        pendingRebuild?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.performPendingRebuild() }
        pendingRebuild = item
        processingQueue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func performPendingRebuild() {
        guard !stopped else { return }
        pendingRebuild = nil
        debounceFirstTriggerUptime = nil
        let forced = pendingForced
        pendingForced = false
        // Rate-only trigger: skip when the aggregate's reported rate never
        // moved from the build-time observation (creating an aggregate
        // notifies for its own initial rate — an unconditional rebuild here
        // would loop forever).
        if !forced, let graph,
            !Self.rateChangeRequiresRebuild(
                current: Self.aggregateNominalSampleRate(graph.aggregateID),
                observedAtBuild: graph.observedRateAtBuild)
        { return }
        // Rate-only rebuilds are CEILINGED per session. Each one destroys the
        // graph and excises 0.1-2.2 s of real speech (back-filled with silence,
        // so the damage is invisible in the file's duration). If the HAL
        // reports an unsettled rate right after aggregate creation, the
        // build-time observation is re-armed identically every time and the
        // session would shred itself into fragments. Past the ceiling we keep
        // the current graph and accept possible pitch drift — recoverable by
        // resampling, unlike excised audio (the same trade the graph builder
        // already makes: "a drifted recording is recoverable, no recording is
        // not").
        if !forced {
            guard rateTriggeredRebuilds < Self.maxRateTriggeredRebuilds else {
                if !rateCeilingReported {
                    rateCeilingReported = true
                    logger.error(
                        "rate-triggered rebuild ceiling (\(Self.maxRateTriggeredRebuilds)) reached — keeping the current graph; further rate changes ignored for this session")
                }
                return
            }
            rateTriggeredRebuilds += 1
        }
        logger.notice("default device or delivered rate changed — rebuilding capture graph")
        teardownGraph()
        // F-1: the down-period clock starts AT teardown — not at the first
        // failure — and the visible-warning alarm is TIMER-armed, so it fires
        // at the 8 s threshold regardless of when (or whether) the next retry
        // failure lands. Event-driven raising alone was unreachable on the
        // fast-failure path: every failure event sat below the threshold and
        // the exhaustion branch never raised. Arming is once per down-period.
        captureDownAlarm.arm(now: ProcessInfo.processInfo.systemUptime)
        do {
            try buildGraph()
            rebuildAttempt = 0
            captureDownAlarm.clear()
            fillCaptureGap()
        } catch {
            guard rebuildAttempt < Self.rebuildRetryDelays.count else {
                // Ladder exhausted: capture cannot continue; route through
                // the write-failure stop policy (stop + encode what exists).
                logger.error(
                    "capture graph rebuild failed after \(Self.rebuildRetryDelays.count) retries: \(error)")
                onEvent?(.writeFailure("audio route change broke the capture (\(error))"))
                return
            }
            let delay = Self.rebuildRetryDelays[rebuildAttempt]
            rebuildAttempt += 1
            logger.error(
                "capture graph rebuild failed (attempt \(self.rebuildAttempt)): \(error) — retrying in \(delay)s")
            // The dead air accumulating during retries is back-filled by the
            // next successful rebuild's gap fill. (The 8 s warning is
            // timer-armed at teardown on the alarm's OWN queue — F-1/R2-F2 —
            // so it fires on schedule even while this path keeps retrying.)
            pendingForced = true
            scheduleRetry(after: delay)
        }
    }

    /// B4: rebuild only when the aggregate's reported nominal rate MOVED
    /// against the build-time observation. nil current (unreadable now) →
    /// no rebuild: zero information, and rebuilding while the rate stays
    /// unreadable would loop. nil observation with a readable current →
    /// rebuild once (the fallback-format graph upgrades to a validated-rate
    /// graph); the new graph then records the observation, so this cannot
    /// loop either.
    static func rateChangeRequiresRebuild(current: Double?, observedAtBuild: Double?) -> Bool {
        guard let current else { return false }
        guard let observedAtBuild else { return true }
        return abs(current - observedAtBuild) >= 1
    }

    // MARK: - B4 gap fill: excised rebuild windows become silence

    /// Below the minimum a fill is jitter noise, not a gap; the cap bounds
    /// the fill so a pathological anchor can never flood the tracks.
    static let gapFillMinimumSeconds = 0.05
    static let gapFillMaximumSeconds = 300.0

    /// Frames of silence for a measured capture gap (0 = no fill).
    static func silenceFillFrames(gapSeconds: Double, sampleRate: Double) -> Int {
        guard gapSeconds >= gapFillMinimumSeconds else { return 0 }
        return Int(min(gapSeconds, gapFillMaximumSeconds) * sampleRate)
    }

    /// A rebuild EXCISES the audio between teardown and the new graph going
    /// live (0.1–2.2 s per rebuild on 2026-07-23; more when retries run).
    /// The stitcher silence-fills PART boundaries only — an in-part gap
    /// silently compresses the timeline, shifting everything after a device
    /// change earlier and skewing diarization/calendar alignment. So write
    /// the measured gap into BOTH tracks as silence, in the writer format.
    /// Runs on processingQueue right after a successful rebuild — BEFORE any
    /// new-generation buffer can be processed (serial-queue order), so the
    /// fill lands exactly at the gap position.
    private func fillCaptureGap() {
        guard let lastBufferUptime, let writers else { return }
        let gap = ProcessInfo.processInfo.systemUptime - lastBufferUptime
        let frames = Self.silenceFillFrames(
            gapSeconds: gap, sampleRate: CaptureCAFWriter.sampleRate)
        guard frames > 0 else { return }
        logger.notice(
            "gap-filling \(frames) frames (\(gap, format: .fixed(precision: 2)) s) of silence after rebuild")
        do {
            try writeSilence(frames: frames, to: writers.system)
            try writeSilence(frames: frames, to: writers.mic)
            self.lastBufferUptime = ProcessInfo.processInfo.systemUptime
        } catch {
            writeFailed = true
            onEvent?(.writeFailure("\(error)"))
        }
    }

    /// ≤ 1 s chunks bound the allocation; the buffer is explicitly zeroed
    /// (AVAudioPCMBuffer does not document zero-initialized memory).
    private func writeSilence(frames: Int, to writer: CaptureCAFWriter) throws {
        let chunkFrames = Int(CaptureCAFWriter.sampleRate)
        var remaining = frames
        while remaining > 0 {
            let n = AVAudioFrameCount(min(remaining, chunkFrames))
            guard
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: CaptureCAFWriter.format, frameCapacity: n)
            else {
                // F-5: a failed silence allocation silently truncated the
                // gap fill — the timeline compression the fill exists to
                // prevent. Throw to the caller's `.writeFailure` handler.
                throw CaptureCAFWriterError.writeFailed(
                    "silence buffer allocation failed (\(n) frames)")
            }
            buffer.frameLength = n
            if let channel = buffer.int16ChannelData?[0] {
                channel.update(repeating: 0, count: Int(n))
            }
            try writer.write(buffer)
            remaining -= Int(n)
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
        // B4 gap-fill anchor: buffers are flowing for the live generation.
        lastBufferUptime = ProcessInfo.processInfo.systemUptime

        var micData = Data()
        var systemData = Data()
        for (index, copy) in copies.enumerated() {
            // F-6: the mic track takes STREAM 0 ONLY. Appending simultaneous
            // mic streams here interpreted them as consecutive frames in
            // stream 0's format — duration and alignment corruption on any
            // multi-stream input device. Streams 1..<micStreamCount are
            // dropped (logged once at build).
            if index == 0, graph.micStreamCount > 0 {
                micData = copy
            } else if index >= graph.micStreamCount {
                systemData.append(copy)
            }
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
        // F-5: broken formats and failed allocations THROW (→ `.writeFailure`
        // stop-and-salvage). A silent `return` here dropped live audio with a
        // green indicator. A zero-frame slice alone stays a benign no-op.
        let bytesPerFrame = Int(sourceFormat.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else {
            throw CaptureCAFWriterError.writeFailed("source format has 0 bytes per frame")
        }
        let frames = AVAudioFrameCount(data.count / bytesPerFrame)
        guard frames > 0 else { return }
        guard let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frames)
        else {
            throw CaptureCAFWriterError.writeFailed("input buffer allocation failed (\(frames) frames)")
        }
        input.frameLength = frames
        data.withUnsafeBytes { raw in
            let target = input.audioBufferList.pointee.mBuffers
            if let dest = target.mData {
                dest.copyMemory(
                    from: raw.baseAddress!, byteCount: min(Int(target.mDataByteSize), data.count))
            }
        }

        let capacity = try Self.resampleCapacity(
            frames: frames, sourceRate: sourceFormat.sampleRate)
        guard
            let output = AVAudioPCMBuffer(pcmFormat: CaptureCAFWriter.format, frameCapacity: capacity)
        else {
            throw CaptureCAFWriterError.writeFailed("output buffer allocation failed (\(capacity) frames)")
        }
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
        // F-5: `.error` without a populated NSError was previously a silent
        // drop of the whole slice.
        if status == .error {
            throw CaptureCAFWriterError.writeFailed("conversion returned .error with no error object")
        }
        if output.frameLength > 0 {
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

    /// The nominal-rate property address — shared by the build-time read and
    /// the B4 rate listener (install + removal must use the same address).
    static var nominalRateAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    /// The aggregate's currently-delivered (master) sample rate. With the mic
    /// pinned as master (B3), every stream is drift-compensated to this rate, so
    /// it is the correct converter INPUT rate. nil if unreadable or <= 0.
    static func aggregateNominalSampleRate(_ deviceID: AudioObjectID) -> Double? {
        var address = Self.nominalRateAddress
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

    /// The B3 FALLBACK converter input format: the stream's OWN virtual
    /// format, verbatim. That rate never passed `isPlausibleRate` (the
    /// aggregate read that did is exactly what is missing on this branch), so
    /// it is checked here: a 0 Hz virtual rate makes the resample ratio
    /// infinite and `AVAudioFrameCount(inf)` TRAPS — the process dies
    /// mid-recording, past the retry ladder, the capture-down warning and the
    /// `.writeFailure` salvage (floor 2). Throwing routes the bad build
    /// through the ladder instead. The HAL is already known to report a
    /// non-positive rate for the AGGREGATE in this same unsettled window —
    /// that reading is what selects this branch; the per-stream read has no
    /// equivalent guard.
    static func fallbackInputFormat(
        streamASBD: AudioStreamBasicDescription
    ) throws -> AVAudioFormat {
        var asbd = streamASBD
        guard asbd.mSampleRate > 0, asbd.mSampleRate.isFinite else {
            throw CaptureSessionError.converterUnavailable("stream rate \(asbd.mSampleRate)")
        }
        guard let format = AVAudioFormat(streamDescription: &asbd)
        else { throw CaptureSessionError.tapFormatUnavailable }
        return format
    }

    /// The resample output capacity, pure. The ratio divides by the SOURCE
    /// rate, so a degenerate rate (0, non-finite, or denormal-small) makes
    /// this `inf`/out-of-range and `AVAudioFrameCount(…)` TRAPS. A capacity
    /// that is not representable is a write failure (stop-and-salvage), never
    /// arithmetic — the belt behind `fallbackInputFormat`'s build-time check.
    static func resampleCapacity(
        frames: AVAudioFrameCount, sourceRate: Double
    ) throws -> AVAudioFrameCount {
        // 0 Hz (the reproduced crash input) makes the ratio +inf; NaN/negative
        // rates are equally unusable.
        guard sourceRate > 0, sourceRate.isFinite else {
            throw CaptureCAFWriterError.writeFailed("unusable source sample rate \(sourceRate)")
        }
        // A denormal-small rate stays finite but overflows the frame count.
        let capacity = (Double(frames) * (CaptureCAFWriter.sampleRate / sourceRate)).rounded(.up) + 64
        guard capacity <= Double(AVAudioFrameCount.max) else {
            throw CaptureCAFWriterError.writeFailed(
                "source sample rate \(sourceRate) yields an unrepresentable output capacity (\(capacity) frames)")
        }
        return AVAudioFrameCount(capacity)
    }
}

// MARK: - Capture-down alarm (its own queue, R2-F2)

/// The down-clock and one-shot threshold alarm behind the visible
/// capture-down warning. It runs on its OWN serial queue because
/// `processingQueue` cannot host it: a synchronous `buildGraph()` spanning
/// the deadline is precisely the case the warning exists for, and a watchdog
/// queued behind the work it watches never fires — the rebuild's success then
/// clears it unfired, so >8 s of dead air passes with a green indicator
/// (audit H-R2-1). Both queues touch the state, so it is `Mutex`-guarded.
///
/// Deadline blocks are never cancelled: an alarm whose deadline elapses after
/// its period ended (successful rebuild, stop, next recording) finds
/// `downSince` nil — or, if a NEW period has since armed, an elapsed time
/// necessarily below the threshold — and does nothing. The same zero stale
/// fires a cancel-based version would have, without a cross-queue cancel race.
///
/// `reset` is also a FENCE (R3-F1): EVERY event invocation runs on this queue
/// and re-reads the sink under the lock at emission time, and `reset` ends the
/// down-period and bumps the sink key under the lock and then drains the queue
/// synchronously. Once `reset` returns, an emission that was already queued or
/// already running has either finished (through the sink of its own recording,
/// before `reset` returned) or found the cleared period / bumped sink key and
/// emitted nothing — so no event can reach a dropped or replaced sink, and no
/// old-period event can stand a warning over the next recording.
final class CaptureDownAlarm: @unchecked Sendable {
    private struct State {
        /// Monotonic uptime when the graph went down, or nil while it is up.
        var downSince: TimeInterval?
        /// Whether the warning is currently raised (emitted and cleared
        /// exactly once per down-period).
        var reported = false
        /// Bumped ONLY by `reset`, so a queued emission can tell at emission
        /// time whether the sink it was queued for is still the installed one.
        /// The down-period state cannot answer that: a clear ENDS the period
        /// as it queues its emission, and a new period may arm WITHIN the same
        /// recording, while the clear queued before it must still clear the
        /// warning it raised there.
        var sinkEpoch = 0
        /// Read under the lock: the alarm queue emits through it while the
        /// processing queue may be replacing it in `start()`/`stop()`.
        var onEvent: (@Sendable (CaptureEngineEvent) -> Void)?
    }

    private let logger = Logger(subsystem: BlaiseBundle.identifier, category: "capture.session")
    private let queue = DispatchQueue(label: BlaiseBundle.subsystem("capture.alarm"))
    private let state = Mutex(State())
    /// Injectable so the wiring is testable without sleeping the real 8 s.
    let threshold: TimeInterval

    init(threshold: TimeInterval) { self.threshold = threshold }

    /// `start()` / `stop()`: install (or drop) the event sink and end any
    /// standing down-period, per-recording bounds included (F-3). Returning
    /// from this call FENCES the previous sink: nothing can emit through it
    /// afterwards (R3-F1).
    func reset(onEvent: (@Sendable (CaptureEngineEvent) -> Void)?) {
        state.withLock { state in
            state.sinkEpoch += 1
            state.downSince = nil
            state.reported = false
            state.onEvent = onEvent
        }
        // The state is updated FIRST, so an emission that has not yet re-read
        // it finds the cleared period / bumped sink key and drops; this
        // barrier then waits out the one case the state cannot cover — an
        // emission already past its read, mid-invocation of the old sink.
        // Called from `processingQueue` (`start`/`stop`): safe because the
        // alarm queue never syncs back onto that queue — its blocks take only
        // this lock and call the sink, which must not block (the production
        // sink hands off to a Task). Delayed `arm` blocks are NOT waited for
        // (not yet due); the nil `downSince` retires them.
        queue.sync {}
    }

    /// The graph went down at `now`: start the down-clock and schedule the
    /// threshold alarm. Once per down-period — a re-arm while one is standing
    /// is a no-op, so the clock keeps measuring CONTINUOUS downtime.
    func arm(now: TimeInterval) {
        let armed: Bool = state.withLock { state in
            guard state.downSince == nil else { return false }
            state.downSince = now
            return true
        }
        guard armed else { return }
        queue.asyncAfter(deadline: .now() + threshold) { [weak self] in
            self?.raiseIfOverdue(now: ProcessInfo.processInfo.systemUptime)
        }
    }

    /// Raise the VISIBLE warning if the graph has been down past the
    /// threshold, once per down-period. See
    /// `CaptureSession.captureDownAlarmSeconds` for why this must be visible;
    /// the recording is NOT stopped — the retry ladder is still working and a
    /// transient failure recovers.
    /// A block whose period already ended finds `downSince` nil; one that
    /// outlived its period into a NEWLY armed one finds an elapsed time below
    /// the threshold (the new clock started after this block was scheduled),
    /// so a fired alarm can only ever be the period that armed it.
    ///
    /// The check and the emission both run on the alarm queue (R3-F1): an
    /// event invoked on the caller's thread would be outside the fence. The
    /// deadline block re-enters here asynchronously, which a serial queue
    /// permits (never `sync`).
    func raiseIfOverdue(now: TimeInterval) {
        queue.async { [weak self] in
            guard let self else { return }
            let raised:
                (handler: (@Sendable (CaptureEngineEvent) -> Void)?, downSeconds: TimeInterval)? =
                state.withLock { state in
                    // At the threshold raises, below it does not; once per
                    // down-period (`reported`).
                    guard let since = state.downSince,
                        !state.reported, now - since >= threshold
                    else { return nil }
                    state.reported = true
                    return (state.onEvent, now - since)
                }
            guard let raised else { return }
            logger.error(
                "capture graph has been down for \(Int(raised.downSeconds))s while rebuilding — surfacing the indicator warning")
            raised.handler?(.captureDown(active: true))
        }
    }

    /// A successful rebuild: end the down-period, and clear the warning if it
    /// was actually raised (a normal sub-threshold rebuild produces no UI
    /// churn at all). The clearing event rides the SAME queue as the raise, so
    /// a rebuild landing exactly at the deadline can never emit its `false`
    /// ahead of the alarm's `true` and strand the warning on screen.
    func clear() {
        // The down-period ends HERE, synchronously: the next `arm` must find
        // no standing period and start a fresh clock. Only the emission is
        // deferred to the alarm queue.
        let cleared: (sinkEpoch: Int, wasReported: Bool) = state.withLock { state in
            let wasReported = state.reported
            state.downSince = nil
            state.reported = false
            return (state.sinkEpoch, wasReported)
        }
        guard cleared.wasReported else { return }
        queue.async { [weak self, logger] in
            guard let self else { return }
            // Emission-time re-validation (R3-F1): the CURRENT sink, read
            // under the lock here rather than captured when `clear` ran, and
            // only while it is still the sink this clear belongs to — a
            // `reset` in between (stop, or the next recording) makes this a
            // dead old-period event.
            let handler: (@Sendable (CaptureEngineEvent) -> Void)? = state.withLock { state in
                state.sinkEpoch == cleared.sinkEpoch ? state.onEvent : nil
            }
            guard let handler else { return }
            logger.notice("capture graph rebuilt — clearing the indicator warning")
            handler(.captureDown(active: false))
        }
    }
}
