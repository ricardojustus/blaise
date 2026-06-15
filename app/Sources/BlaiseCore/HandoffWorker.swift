import Foundation
import Network
import os

// MARK: - Crash hooks (debug-only deterministic kill points, C8 kill tests)

/// `BLAISE_CRASH_AT` env hook — same technique as `PipelineCrashHooks`.
enum HandoffCrashPoint: String {
    /// Between the `delivering` transition and the ssh spawn.
    case postClaim = "handoff-post-claim"
    /// Armed just before the spawn; SIGKILLs the APP 0.3 s later, while the
    /// orphan-able ssh child is mid-transfer (the harness uses a payload
    /// large enough that the transfer outlives the fuse).
    case midTransfer = "handoff-mid-transfer"
}

enum HandoffCrashHooks {
    static func maybeKill(_ point: HandoffCrashPoint) {
        if ProcessInfo.processInfo.environment["BLAISE_CRASH_AT"] == point.rawValue {
            kill(getpid(), SIGKILL)
            // SIGKILL posting is asynchronous — never let the caller proceed.
            while true { usleep(1_000) }
        }
    }

    /// Arms the mid-transfer fuse (no-op unless the env names the point).
    static func maybeArmMidTransferKill() {
        guard ProcessInfo.processInfo.environment["BLAISE_CRASH_AT"]
            == HandoffCrashPoint.midTransfer.rawValue
        else { return }
        Task.detached {
            try? await Task.sleep(for: .milliseconds(300))
            kill(getpid(), SIGKILL)
        }
    }
}

// MARK: - Delivery record (evidence: "delivery LOG sequence")

public struct HandoffDeliveryRecord: Sendable, Codable, Equatable {
    public var itemID: HandoffID
    public var meetingID: MeetingID
    public var versionHash: String
    public var createdSeq: Int64
    public var host: String
    public var deliveredAt: Date
}

// MARK: - HandoffWorker

/// The C8 queue worker: drains C1's `handoff_queue` into the Evidence Store
/// inbox on the remote host — silently, in order, with retry until success, surviving
/// crashes and offline periods, never losing or duplicating an item (hard
/// floor 8). The app remains fully functional with the remote host offline.
///
/// Drive model: wake on launch (`start()`), `kick()` (the pipeline's
/// `HandoffKicking` seam), `NWPathMonitor` change, retry timer. Every
/// EXTERNAL wake clears item backoff floors (including the auth cap) and all
/// host benches + strikes — a fixed key/setting delivers on the next kick,
/// not in an hour. One delivery in flight, FIFO by `created_seq`;
/// `damaged:`-quarantined rows are skipped (loud, never dropped); a floored
/// HEAD item is WAITED on, not bypassed — strict enqueue order for healthy
/// items.
public actor HandoffWorker: HandoffKicking {
    private let database: BlaiseDatabase
    private let settingsStore: SettingsStore
    private let repository: HandoffRepository
    private let transport: any HandoffTransporting
    private let prober: any HandoffProbing
    /// Builds the transport for a `.localFolder` destination from its resolved
    /// root URL (G5). Default constructs the real `LocalFolderTransport`;
    /// tests inject a corrupt-on-read-back seam or a recording double.
    private let localTransportFactory: @Sendable (URL) -> any HandoffTransporting
    private let holder: HandoffStatusHolder?
    private let now: @Sendable () -> Date
    /// Retry-timer sleep seam. Default = real `Task.sleep`, so production
    /// behavior is unchanged; tests inject a virtual clock whose `sleep` costs
    /// zero wall-clock, so the retry/backoff integration tests no longer wait
    /// real backoff seconds.
    private let sleep: @Sendable (Duration) async -> Void
    private let jitter: @Sendable (TimeInterval) -> TimeInterval
    /// Per-attempt remote temp-name nonce source (impl-audit M-3): an
    /// orphaned post-crash ssh and a relaunch redelivery must never share a
    /// temp file. Injectable for the command goldens.
    private let nonce: @Sendable () -> String
    private let logger = Logger(subsystem: BlaiseBundle.identifier, category: "handoff")

    private struct HostState {
        var strikes = 0
        var benchExponent = 0
        var benchedUntil: Date?
    }

    private var hostStates: [String: HostState] = [:]
    /// Item floors are in-memory ONLY: a relaunch (external wake) clears
    /// them by construction. Backoff exponent derives from the row's durable
    /// `attempts`.
    private var itemFloors: [HandoffID: Date] = [:]
    private var drainTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    /// Bumped by external wakes; a drain that decided to block re-loops if
    /// a wake landed while it was deciding.
    private var wakeGeneration = 0
    /// `ProcessInfo.beginActivity(.background)` token held while items are
    /// pending — App Nap cannot stall the retry timer indefinitely.
    private var activityToken: NSObjectProtocol?
    private var deliveryLog: [HandoffDeliveryRecord] = []
    private var lastSnapshot: HandoffSnapshot = .initial
    /// L-4 startup grace: the warning notification is suppressed until the
    /// first post-launch drain settles, so a stale queue that delivers right
    /// away never fires a notification that withdraws seconds later.
    private var firstSweepReported = false

    public init(
        database: BlaiseDatabase,
        holder: HandoffStatusHolder? = nil,
        transport: any HandoffTransporting = SSHHandoffTransport(),
        prober: any HandoffProbing = TCPPortProber(),
        localTransportFactory: @escaping @Sendable (URL) -> any HandoffTransporting = {
            LocalFolderTransport(root: $0)
        },
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        jitter: @escaping @Sendable (TimeInterval) -> TimeInterval = { TimeInterval.random(in: 0...$0) },
        nonce: @escaping @Sendable () -> String = { HandoffCommand.makeNonce() }
    ) {
        self.database = database
        self.settingsStore = SettingsStore(database: database)
        self.repository = HandoffRepository(database: database)
        self.transport = transport
        self.prober = prober
        self.localTransportFactory = localTransportFactory
        self.holder = holder
        self.now = now
        self.sleep = sleep
        self.jitter = jitter
        self.nonce = nonce
    }

    // MARK: - Wakes

    /// Launch wake: damaged rows get their once-per-launch re-check, the
    /// path monitor starts, and a drain kicks off. (The C1 startup sweep
    /// already reset stale `delivering` rows when the DB opened.)
    public func start() async {
        // D12 launch catch-up (impl-audit M-1): the sweep is transactional
        // with the `.delivered` transition since the same audit, but a DB
        // written by an older binary (or any historical crash window) may
        // still hold an open older row behind a delivered newer one — close
        // it here so the FIFO scan can never ship stale content.
        if let closed = try? await repository.sweepSupersededAtLaunch(), closed > 0 {
            logger.notice("launch supersession catch-up: closed \(closed) stale undelivered item(s)")
        }
        if let requeued = try? await repository.requeueDamaged(), requeued > 0 {
            logger.info("relaunch re-check: \(requeued) damaged item(s) requeued once")
        }
        if pathMonitor == nil {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                guard path.status == .satisfied else { return }
                Task { await self?.kick() }
            }
            monitor.start(queue: DispatchQueue(label: BlaiseBundle.subsystem("handoff.path")))
            pathMonitor = monitor
        }
        await kick()
    }

    /// External wake (pipeline kick / path change / launch): clears ALL item
    /// floors and host benches + strike counts (round-3 M-1), then drains.
    public func kick() async {
        wakeGeneration += 1
        itemFloors.removeAll()
        hostStates.removeAll()
        timerTask?.cancel()
        timerTask = nil
        ensureDraining()
    }

    /// Graceful quit: cancels the in-flight delivery (SubprocessRunner's
    /// SIGTERM→SIGKILL path kills the ssh child) and all timers.
    public func stop() {
        drainTask?.cancel()
        timerTask?.cancel()
        timerTask = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        endActivityIfHeld()
    }

    /// "Retry now" (warning banner + Settings queue panel): re-enters
    /// retriable `failed` rows as `pending` (incl. one `damaged:` re-check;
    /// `superseded:` never — the C1/C8 prefix contract), then external-wakes
    /// the worker so ALL item floors and host benches clear and the head item
    /// is attempted immediately. The fix for the relaunch-to-retry gap: a
    /// floored queue retries on a click, not in hours.
    public func retryNow() async {
        _ = try? await repository.retryAllFailed()
        await kick()
    }

    /// Internal wake from the retry timer — floors and benches stand.
    private func timerFired() {
        timerTask = nil
        ensureDraining()
    }

    private func ensureDraining() {
        guard drainTask == nil else { return }
        drainTask = Task { await self.drain() }
    }

    /// Test/evidence support: waits until no drain is running. (drain()'s
    /// defer clears `drainTask`; a non-nil value after the await is a NEW
    /// drain started by another wake — keep waiting.)
    public func waitUntilSettled() async {
        while let task = drainTask {
            await task.value
        }
    }

    public func deliveryHistory() -> [HandoffDeliveryRecord] { deliveryLog }
    public func currentSnapshot() -> HandoffSnapshot { lastSnapshot }

    // MARK: - Drain loop

    private func drain() async {
        defer {
            drainTask = nil
            // L-4: the first drain to settle lifts the notification grace —
            // a launch-stale warning still active after this fires now.
            if !firstSweepReported {
                firstSweepReported = true
                if let holder { Task { await MainActor.run { holder.markFirstSweepComplete() } } }
            }
        }
        while !Task.isCancelled {
            let generation = wakeGeneration

            // Resolve the ACTIVE destination (G5). `.ssh` validates its
            // injection-bearing settings; `.localFolder` resolves its
            // security-scoped bookmark to a live URL. Either resolution failure
            // is a CONFIG failure (≠ damage): the worker pauses loudly, items
            // stay pending, and a settings fix + kick resumes everything.
            let destination: HandoffDestination
            do {
                destination = try await HandoffDestination.load(from: settingsStore)
                if case .ssh(let settings, _) = destination { try settings.validate() }
            } catch HandoffDestination.ResolutionError.unresolvableBookmark(let detail) {
                // A PREVIOUSLY-CHOSEN folder whose bookmark no longer resolves
                // (deleted folder, unplugged external drive). This is NOT a
                // loud config error — it behaves like the remote host-offline: floor the
                // head item as a folder-transient so the queue retries silently
                // and the D21 staleness banner eventually surfaces the
                // folder-specific reason (Retry Now re-attempts once the folder
                // is back). A wake clears the floor by construction.
                logger.notice("local destination folder unavailable: \(detail, privacy: .public)")
                if let item = try? await repository.nextDeliverable() {
                    // Record a folder-shaped transient failure on the head item
                    // (reuses the standard backoff/floor + warning machinery):
                    // the warning's shortReason then reads "destination folder
                    // unavailable", and the stale-age rule arms the banner.
                    await recordFailure(
                        item: item, host: "local folder", class: .transient,
                        message: "transient: exit=local local folder error: \(detail)")
                    // recordFailure floors the item silently for a transient;
                    // publish so the (possibly stale) warning surfaces now.
                    await publish(state: .waitingRetry, current: item, detail: "local folder unavailable")
                    if wakeGeneration != generation { continue }
                    // M-2: arm the SAME retry cadence as the remote host-offline. An
                    // unplugged drive / deleted folder must keep retrying on a
                    // timer (the item's backoff floor `recordFailure` just set),
                    // not stall until an unrelated external wake or manual Retry
                    // Now — exactly the SSH-offline behavior. The stale-age wake
                    // is a separate, longer arm (banner re-evaluation); take the
                    // EARLIER of the two so the queue retries promptly AND the
                    // banner still trips on schedule once the folder stays gone.
                    let floor = itemFloors[item.id]
                    let staleBoundary = await staleReevaluationBoundary()
                    if let wakeAt = [floor, staleBoundary].compactMap({ $0 }).min() {
                        scheduleTimer(at: wakeAt)
                    }
                } else {
                    await publish(state: .idle)
                    if wakeGeneration != generation { continue }
                    await scheduleStaleReevaluationIfNeeded()
                }
                return
            } catch {
                // Missing bookmark (no folder ever chosen) or an SSH validation
                // failure: pause loudly — items stay pending, a settings fix +
                // kick resumes everything.
                logger.error("handoff paused: \(String(describing: error), privacy: .public)")
                endActivityIfHeld()
                await publish(state: .configurationInvalid, detail: "\(error)")
                // A wake may have landed during the awaits above (actor
                // reentrancy; impl-audit H-1) — re-loop, never swallow it.
                if wakeGeneration != generation { continue }
                return
            }

            guard let item = try? await repository.nextDeliverable() else {
                endActivityIfHeld()
                await publish(state: .idle)
                if wakeGeneration != generation { continue }
                // No deliverable row, but undelivered-yet-undeliverable rows
                // (damaged: quarantine) may still exist: with no item to
                // claim the loop would park with no timer, so the 1-hour
                // staleness arm would never be re-evaluated until an unrelated
                // wake (audit M-2). Arm a wake at the oldest undelivered row's
                // staleness boundary so the warning trips on its own.
                await scheduleStaleReevaluationIfNeeded()
                return
            }
            beginActivityIfNeeded()

            // Strict FIFO: a floored head item is waited on, not bypassed.
            if let floor = itemFloors[item.id], floor > now() {
                // Alert states (auth/host-key/disk) stay surfaced while the
                // floor runs (audit M-4) — never downgraded to waitingRetry.
                let blockedState: HandoffSnapshot.WorkerState
                switch lastSnapshot.state {
                case .authFailure, .hostKeyMismatch, .remoteDiskFull:
                    blockedState = lastSnapshot.state
                default:
                    blockedState = .waitingRetry
                }
                await publish(state: blockedState, current: item, detail: lastSnapshot.detail)
                // A wake may have landed during the publish await (actor
                // reentrancy) — re-loop instead of arming a stale timer.
                if wakeGeneration != generation { continue }
                scheduleTimer(at: floor)
                return
            }

            switch destination {
            case .ssh(let settings, let sidecar):
                guard let host = await pickHost(settings.hosts) else {
                    let wakeAt = earliestBenchExpiry() ?? now().addingTimeInterval(HandoffBackoff.hostBase)
                    await publish(state: .allEndpointsDown, current: item)
                    if wakeGeneration != generation { continue }
                    scheduleTimer(at: wakeAt)
                    return
                }
                // Pre-stream self-check (audit C-2); quarantines on double
                // mismatch and the loop proceeds to the next item.
                guard let payload = await selfCheck(item) else { continue }
                guard let claimed = try? await repository.transition(item.id, to: .delivering) else {
                    // Local DB write failure (e.g. this Mac disk full) is a
                    // LOCAL-transient: floor the item so the loop arms a retry
                    // timer instead of busy-spinning (impl-audit M-2).
                    floorLocalTransient(item)
                    continue
                }
                await publish(state: .delivering, current: claimed, endpoint: host)
                HandoffCrashHooks.maybeKill(.postClaim)

                let remoteDir = settings.remoteRoot + "/" + item.meetingID
                let argv = HandoffCommand.argv(
                    user: settings.user, host: host, identityFile: settings.identityFile,
                    remoteDir: remoteDir, hash: item.versionHash, nonce: nonce())
                HandoffCrashHooks.maybeArmMidTransferKill()
                let outcome: HandoffTransportOutcome
                do {
                    outcome = try await transport.deliver(
                        argv: argv, payload: payload,
                        timeout: HandoffCommand.watchdogTimeout(payloadByteCount: payload.count))
                } catch {
                    // Spawn failure (ssh binary missing — cannot happen on stock
                    // macOS): treat as transient, surface in lastError.
                    await recordFailure(
                        item: claimed, host: host, class: .transient,
                        message: "spawn failed: \(error)")
                    continue
                }
                if outcome.exitStatus == 0, sidecar {
                    // JSON delivered; upload the convenience Markdown sidecar
                    // (failure ISOLATED — never fails the queue item; retried on
                    // this meeting's next delivery), mirroring the local path.
                    await uploadSidecar(
                        item: claimed, settings: settings, host: host, remoteDir: remoteDir)
                }
                await recordOutcome(outcome, item: claimed, endpoint: host)

            case .localFolder(let url, let sidecar):
                // No host to pick — the folder IS the single endpoint. The
                // verify-before-rename happens in LocalFolderTransport; the
                // same self-check, supersession, retry, D21 warning machinery
                // applies. Folder errors map onto the existing failure classes.
                guard let payload = await selfCheck(item) else { continue }
                guard let claimed = try? await repository.transition(item.id, to: .delivering) else {
                    floorLocalTransient(item)
                    continue
                }
                let endpoint = url.path
                await publish(state: .delivering, current: claimed, endpoint: endpoint)
                HandoffCrashHooks.maybeKill(.postClaim)

                // Open the security scope for the resolved bookmark (no-op for a
                // plain /tmp URL in tests); always balance the close.
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }

                let argv = LocalFolderCommand.argv(
                    meetingID: item.meetingID, hash: item.versionHash, nonce: nonce())
                let outcome = (try? await localTransportFactory(url).deliver(
                    argv: argv, payload: payload, timeout: 0))
                    ?? HandoffTransportOutcome(
                        exitStatus: nil, stderrTail: "local transport error", timedOut: false)

                if outcome.exitStatus == 0 {
                    // JSON delivered; write the convenience sidecar (failure
                    // isolated — never fails the queue item; retried next
                    // delivery of this meeting).
                    if sidecar {
                        await writeSidecar(item: claimed, root: url)
                    }
                }
                await recordOutcome(outcome, item: claimed, endpoint: endpoint)
            }
        }
    }

    /// Shared success/failure recording for both destinations: exit 0 →
    /// delivered (+ supersession sweep); else classify and floor/strike per
    /// the existing taxonomy.
    private func recordOutcome(
        _ outcome: HandoffTransportOutcome, item: HandoffItem, endpoint: String
    ) async {
        if outcome.exitStatus == 0 {
            await recordDelivery(item: item, host: endpoint)
            return
        }
        let failureClass = outcome.failureClass
        let detail = outcome.stderrTail.suffix(300).trimmingCharacters(in: .whitespacesAndNewlines)
        let message = "\(failureClass.rawValue): exit=\(outcome.exitLabel) \(detail)"
        await recordFailure(item: item, host: endpoint, class: failureClass, message: message)
    }

    /// Writes the Markdown sidecar next to a delivered local JSON (G5). Pulls
    /// the meeting + notes from durable state; a missing notes row simply skips
    /// the sidecar (the JSON is already the contract).
    private func writeSidecar(item: HandoffItem, root: URL) async {
        guard
            let meeting = try? await MeetingRepository(database: database).fetch(item.meetingID),
            let notes = try? await NotesRepository(database: database).fetch(meetingID: item.meetingID)
        else { return }
        let fields = MarkdownSidecar.Fields(
            meetingID: meeting.id,
            title: meeting.title,
            startedAt: meeting.startedAt,
            attendeeNames: meeting.attendees.map(\.name),
            versionHash: item.versionHash,
            notesMarkdown: notes.markdown)
        let dir = root.appendingPathComponent(item.meetingID, isDirectory: true)
        MarkdownSidecar.write(fields, to: dir)
    }

    /// Uploads the Markdown sidecar to the remote meeting dir AFTER the JSON
    /// delivery succeeded (G6). Pulls the meeting + notes from durable state (a
    /// missing notes row simply skips — the JSON is already the contract),
    /// renders the `.md`, and streams its bytes over a second ssh invocation
    /// reusing the SAME argv structure (user/host/identityFile) + transport as
    /// the JSON. FAILURE-ISOLATED: any failure here is logged and swallowed — it
    /// NEVER fails or retries the JSON queue item (the JSON is the contract, the
    /// sidecar is convenience), and is retried on this meeting's next delivery.
    private func uploadSidecar(
        item: HandoffItem, settings: HandoffSettings, host: String, remoteDir: String
    ) async {
        guard
            let meeting = try? await MeetingRepository(database: database).fetch(item.meetingID),
            let notes = try? await NotesRepository(database: database).fetch(meetingID: item.meetingID)
        else { return }
        let fields = MarkdownSidecar.Fields(
            meetingID: meeting.id,
            title: meeting.title,
            startedAt: meeting.startedAt,
            attendeeNames: meeting.attendees.map(\.name),
            versionHash: item.versionHash,
            notesMarkdown: notes.markdown)
        let slug = MarkdownSidecar.slug(fields.title)
        // Injection-safety guard: the slug is `[a-z0-9-]` by construction, so it
        // can never break out of the single-quoted remote command. Assert that
        // invariant and SKIP rather than ever emit an unsafe command — the
        // sidecar is convenience, never worth a malformed remote shell string.
        guard slug.allSatisfy({ $0 == "-" || ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") })
        else {
            logger.error(
                "sidecar slug '\(slug, privacy: .public)' is not [a-z0-9-]; skipping upload (JSON already delivered)"
            )
            return
        }
        let document = Data(MarkdownSidecar.render(fields).utf8)
        let argv = HandoffCommand.sidecarArgv(
            user: settings.user, host: host, identityFile: settings.identityFile,
            remoteDir: remoteDir, slug: slug)
        do {
            let outcome = try await transport.deliver(
                argv: argv, payload: document,
                timeout: HandoffCommand.watchdogTimeout(payloadByteCount: document.count))
            if outcome.exitStatus != 0 {
                logger.warning(
                    "sidecar upload for \(item.meetingID, privacy: .public) failed (exit=\(outcome.exitLabel, privacy: .public)) — JSON already delivered; retried on next delivery"
                )
            }
        } catch {
            logger.warning(
                "sidecar upload for \(item.meetingID, privacy: .public) errored: \(String(describing: error), privacy: .public) — JSON already delivered; retried on next delivery"
            )
        }
    }

    // MARK: - Success path

    private func recordDelivery(item: HandoffItem, host: String) async {
        // The `.delivered` transition and the D12 supersession sweep (older
        // undelivered versions of this meeting terminally closed —
        // content-superseded, visible, never silent) run in ONE write
        // transaction: no crash window between them (impl-audit M-1).
        guard let (delivered, superseded) = try? await repository.markDelivered(item.id) else { return }
        itemFloors[item.id] = nil
        hostStates[host] = HostState()  // healthy again: strikes AND benchExponent reset
        let record = HandoffDeliveryRecord(
            itemID: item.id, meetingID: item.meetingID, versionHash: item.versionHash,
            createdSeq: item.createdSeq, host: host,
            deliveredAt: delivered.deliveredAt ?? now())
        deliveryLog.append(record)
        logger.info(
            "delivered seq=\(item.createdSeq) meeting=\(item.meetingID, privacy: .public) hash=\(item.versionHash, privacy: .public) via \(host, privacy: .public)"
        )
        if !superseded.isEmpty {
            for id in superseded { itemFloors[id] = nil }
            logger.notice(
                "superseded \(superseded.count) older item(s) for meeting \(item.meetingID, privacy: .public)")
        }
    }

    // MARK: - Failure path

    /// A failed LOCAL repository write (claim or quarantine transition —
    /// e.g. disk full) floors the item via the standard backoff machinery so
    /// the drain loop arms a timer instead of busy-spinning (impl-audit M-2).
    /// In-memory only: any external wake clears it, like every item floor.
    private func floorLocalTransient(_ item: HandoffItem) {
        let delay = HandoffBackoff.fullJitter(
            base: HandoffBackoff.itemBase, cap: HandoffBackoff.itemCap,
            exponent: max(item.attempts - 1, 0), random: jitter)
        itemFloors[item.id] = now().addingTimeInterval(delay)
        logger.warning(
            "local DB write failed for seq=\(item.createdSeq); retrying in \(Int(delay)) s")
    }

    private func recordFailure(
        item: HandoffItem, host: String, class failureClass: HandoffFailureClass, message: String
    ) async {
        _ = try? await repository.transition(item.id, to: .failed, error: message)
        logger.warning(
            "delivery failed (\(failureClass.rawValue, privacy: .public)) seq=\(item.createdSeq): \(message, privacy: .public)"
        )
        switch failureClass {
        case .auth:
            itemFloors[item.id] = now().addingTimeInterval(HandoffBackoff.authFloor)
            await publish(state: .authFailure, current: item, endpoint: host, detail: message)
        case .hostKeyMismatch:
            itemFloors[item.id] = now().addingTimeInterval(HandoffBackoff.hostKeyFloor)
            await publish(state: .hostKeyMismatch, current: item, endpoint: host, detail: message)
        case .remoteDisk:
            itemFloors[item.id] = now().addingTimeInterval(HandoffBackoff.remoteDiskFloor)
            await publish(state: .remoteDiskFull, current: item, endpoint: host, detail: message)
        case .hostTransient:
            // The link, not the item: strike the host (3 consecutive →
            // benched); no item floor, so the loop can fail over.
            strike(host)
        case .transferTransient, .transient:
            // attempts was just incremented by the delivering transition;
            // exponent = attempts - 1 keeps backoff growth durable across
            // restarts (first failure jitters within [0, 30 s]).
            let delay = HandoffBackoff.fullJitter(
                base: HandoffBackoff.itemBase, cap: HandoffBackoff.itemCap,
                exponent: max(item.attempts - 1, 0), random: jitter)
            itemFloors[item.id] = now().addingTimeInterval(delay)
        }
    }

    // MARK: - Host breaker

    private func pickHost(_ hosts: [String]) async -> String? {
        for host in hosts {
            if let bench = hostStates[host]?.benchedUntil, bench > now() { continue }
            if await prober.probe(host: host, port: 22, timeout: 2) {
                hostStates[host, default: HostState()].benchedUntil = nil
                return host
            }
            bench(host)  // TCP-probe failure benches immediately
        }
        return nil
    }

    private func strike(_ host: String) {
        var state = hostStates[host, default: HostState()]
        state.strikes += 1
        if state.strikes >= HandoffBackoff.benchStrikeLimit {
            state.strikes = 0
            hostStates[host] = state
            bench(host)
        } else {
            hostStates[host] = state
        }
    }

    private func bench(_ host: String) {
        var state = hostStates[host, default: HostState()]
        let delay = HandoffBackoff.fullJitter(
            base: HandoffBackoff.hostBase, cap: HandoffBackoff.hostCap,
            exponent: state.benchExponent, random: jitter)
        state.benchedUntil = now().addingTimeInterval(delay)
        state.benchExponent += 1
        hostStates[host] = state
        logger.info("host \(host, privacy: .public) benched for \(Int(delay)) s")
    }

    private func earliestBenchExpiry() -> Date? {
        hostStates.values.compactMap(\.benchedUntil).min()
    }

    // MARK: - Pre-stream self-check + re-materialization recovery

    /// Returns verified payload bytes, or nil after quarantining the item.
    /// Ordering pinned (round-4 M-2): re-materialize FIRST, compare the
    /// rebuilt hash to the stored `versionHash`, and ONLY on match replace
    /// the corrupt file (a missing file is treated exactly as a mismatch,
    /// round-4 M-3). No match → `damaged:` quarantine, file left in place.
    private func selfCheck(_ item: HandoffItem) async -> Data? {
        // PAYLOAD-side validation: an invalid stored hash or meeting id can
        // never reach command construction.
        guard MeetingPaths.isValidVersionHash(item.versionHash), ULID.isValid(item.meetingID) else {
            await quarantine(item, detail: "stored version_hash or meeting id fails validation")
            return nil
        }
        let url = database.rootURL.appendingPathComponent(item.payloadPath)
        let onDisk = try? Data(contentsOf: url)
        if let onDisk, EvidencePayloadBuilder.sha256Hex(onDisk) == item.versionHash {
            return onDisk
        }
        guard let rebuilt = await rematerialize(item), rebuilt.versionHash == item.versionHash else {
            await quarantine(
                item,
                detail: onDisk == nil
                    ? "payload file missing and re-materialized bytes do not match version_hash"
                    : "payload damaged and re-materialized bytes do not match version_hash; file left in place")
            return nil
        }
        do {
            if onDisk != nil { try FileManager.default.removeItem(at: url) }
            try ImmutablePayloadWriter.write(rebuilt.bytes, to: url)
        } catch {
            await quarantine(item, detail: "verified re-materialized bytes could not be written: \(error)")
            return nil
        }
        logger.notice(
            "payload for seq=\(item.createdSeq) re-materialized and verified (was \(onDisk == nil ? "missing" : "corrupt", privacy: .public))"
        )
        return rebuilt.bytes
    }

    /// Re-materializes from durable state. We don't persist which notes
    /// user-action-items key form a queued payload used (no migration), so we
    /// rebuild with the CURRENT key (`user_action_items`) and, only if that
    /// fails to reproduce the stored hash, fall back to the LEGACY key
    /// (`legacy_user_action_items`) for items minted before G4. The caller compares the
    /// returned hash to `item.versionHash`; this just makes the legacy form
    /// reachable so pre-G4 history can still recover instead of quarantining.
    private func rematerialize(_ item: HandoffItem) async -> EvidencePayloadBuilder.Payload? {
        guard
            let meeting = try? await MeetingRepository(database: database).fetch(item.meetingID),
            let notes = try? await NotesRepository(database: database).fetch(meetingID: item.meetingID),
            let segments = try? await TranscriptRepository(database: database).segments(meetingID: item.meetingID)
        else { return nil }
        let user = (try? await settingsStore.get(UserIdentity.settingsKey, as: UserIdentity.self))
            ?? nil ?? UserIdentity.shippedDefault
        let current = EvidencePayloadBuilder.build(
            meeting: meeting, segments: segments, notes: notes, user: user,
            userActionItemsKey: .current)
        if current.versionHash == item.versionHash { return current }
        let legacy = EvidencePayloadBuilder.build(
            meeting: meeting, segments: segments, notes: notes, user: user,
            userActionItemsKey: .legacy)
        return legacy.versionHash == item.versionHash ? legacy : current
    }

    private func quarantine(_ item: HandoffItem, detail: String) async {
        if (try? await repository.transition(
            item.id, to: .failed, error: HandoffErrorClass.damaged(detail))) == nil
        {
            // Quarantine write failed: the row stays deliverable, so floor
            // it — otherwise the loop re-picks it immediately (audit M-2).
            floorLocalTransient(item)
        }
        logger.error(
            "item seq=\(item.createdSeq) QUARANTINED (damaged): \(detail, privacy: .public) — skipped by the FIFO scan, re-checked on relaunch"
        )
        await publishCounts()
    }

    // MARK: - Timer / activity

    /// Damaged-only / undeliverable-only park (audit M-2): when nothing is
    /// deliverable but undelivered rows remain, arm a wake at the oldest row's
    /// 1-hour staleness boundary so the stale arm is re-evaluated without an
    /// unrelated wake. Already-stale rows trip immediately on the next loop;
    /// already-armed warnings are unaffected (they published above).
    private func scheduleStaleReevaluationIfNeeded() async {
        guard let boundary = await staleReevaluationBoundary() else { return }
        scheduleTimer(at: boundary)
    }

    /// The 1-hour staleness boundary of the oldest undelivered row, or nil when
    /// there is nothing undelivered or it is already stale (publish reflected
    /// it). Shared by the damaged/undeliverable park and the M-2 unresolvable-
    /// bookmark path, which wakes at the EARLIER of this and the item floor.
    private func staleReevaluationBoundary() async -> Date? {
        guard let undelivered = try? await repository.undeliveredItems(),
            let oldest = undelivered.min(by: { $0.createdSeq < $1.createdSeq })
        else { return nil }
        let boundary = oldest.createdAt.addingTimeInterval(HandoffWarningThreshold.staleAge)
        guard boundary > now() else { return nil }
        return boundary
    }

    private func scheduleTimer(at date: Date) {
        timerTask?.cancel()
        let delay = max(0, date.timeIntervalSince(now()))
        timerTask = Task { [weak self] in
            await self?.sleep(.seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.timerFired()
        }
    }

    private func beginActivityIfNeeded() {
        guard activityToken == nil else { return }
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: .background, reason: "Blaise handoff queue pending")
    }

    private func endActivityIfHeld() {
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
    }

    // MARK: - Snapshot publishing

    private func publish(
        state: HandoffSnapshot.WorkerState, current: HandoffItem? = nil,
        endpoint: String? = nil, detail: String? = nil
    ) async {
        let pending = (try? await repository.undeliveredCount()) ?? 0
        let damaged = (try? await repository.damagedItems()) ?? []
        // Persistent-failure warning (owner directive refining hard floor 8):
        // re-evaluated on every publish, so it arms as failures accrue and
        // clears silently on the first publish after delivery succeeds.
        let undelivered = (try? await repository.undeliveredItems()) ?? []
        // `previous` keeps an armed episode sticky across error-class
        // downgrades (a warning never clears without a delivery succeeding):
        // only published-after-launch sweeps revisit it, never a fresh start.
        let warning = HandoffWarningThreshold.evaluate(
            items: undelivered,
            configurationInvalid: state == .configurationInvalid,
            now: now(),
            previous: lastSnapshot.warning)
        let snapshot = HandoffSnapshot(
            state: state,
            activeEndpoint: endpoint,
            pendingCount: pending,
            currentItem: current.map {
                HandoffSnapshot.ItemStatus(id: $0.id, attempts: $0.attempts, lastError: $0.lastError)
            },
            damagedItems: damaged.map {
                HandoffSnapshot.ItemStatus(id: $0.id, attempts: $0.attempts, lastError: $0.lastError)
            },
            detail: detail,
            warning: warning)
        lastSnapshot = snapshot
        guard let holder else { return }
        await MainActor.run { holder.publish(snapshot) }
    }

    private func publishCounts() async {
        await publish(
            state: lastSnapshot.state, endpoint: lastSnapshot.activeEndpoint,
            detail: lastSnapshot.detail)
    }
}
