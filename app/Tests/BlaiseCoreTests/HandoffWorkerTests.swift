import CryptoKit
import Foundation
import SQLite3
import Synchronization
import Testing
@testable import BlaiseCore

// C8 — handoff worker, transport command construction, validation (the
// entire injection defense), retry/breaker math, quarantine + supersession.

// MARK: - Test doubles

/// Scriptable transport: pops outcomes in call order; records every call.
final class MockTransport: HandoffTransporting, @unchecked Sendable {
    struct Call { let argv: [String]; let payload: Data; let timeout: TimeInterval }

    private let lock = NSLock()
    private var script: [HandoffTransportOutcome]
    private let fallback: HandoffTransportOutcome
    private(set) var calls: [Call] = []

    static let success = HandoffTransportOutcome(exitStatus: 0, stderrTail: "", timedOut: false)

    init(script: [HandoffTransportOutcome] = [], fallback: HandoffTransportOutcome = MockTransport.success) {
        self.script = script
        self.fallback = fallback
    }

    func deliver(argv: [String], payload: Data, timeout: TimeInterval) async throws -> HandoffTransportOutcome {
        record(Call(argv: argv, payload: payload, timeout: timeout))
    }

    private func record(_ call: Call) -> HandoffTransportOutcome {
        lock.lock()
        defer { lock.unlock() }
        calls.append(call)
        return script.isEmpty ? fallback : script.removeFirst()
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls.count
    }
}

/// Probe result switchable mid-test.
final class MockProber: HandoffProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var reachable: Bool

    init(reachable: Bool = true) { self.reachable = reachable }

    func set(reachable: Bool) {
        lock.lock()
        self.reachable = reachable
        lock.unlock()
    }

    func probe(host: String, port: UInt16, timeout: TimeInterval) async -> Bool {
        isReachable()
    }

    private func isReachable() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return reachable
    }
}

/// Seeds a fully re-materializable deliverable item through the REAL
/// codepaths: meeting row + persisted transcript + notes + builder payload +
/// `finalizeMeetingProcessing` (ready ⇒ queued invariant).
@discardableResult
func seedDeliverable(
    _ database: BlaiseDatabase, title: String = "Reunião C8", segmentText: String = "Olá, çãé 🎙"
) async throws -> HandoffItem {
    // The compiled handoff default is now EMPTY (Settings-configured on first
    // run); seed a valid destination so the worker has somewhere to deliver.
    try await seedHandoffConfig(database)
    let meeting = makeMeeting(title: title, attendees: [
        Attendee(name: "Sam", email: "sam.rivera@vexatron.test", source: .manual)
    ])
    try await MeetingRepository(database: database).create(meeting)
    let provenance = ASRProvenance(
        engine: "stub", model: "stub", runtime: "stub", engineVersion: "1",
        transcribedAt: msDate())
    let segments = [
        TranscriptSegment(
            meetingID: meeting.id, ord: 0, startSeconds: 0, endSeconds: 1.5,
            speakerLabel: "S0", speakerName: "Sam", text: segmentText),
        TranscriptSegment(
            meetingID: meeting.id, ord: 1, startSeconds: 1.6, endSeconds: 3,
            speakerLabel: "S1", speakerName: nil, text: "segundo segmento"),
    ]
    let stored = try await database.persistTranscript(
        meetingID: meeting.id, segments: segments, asrProvenance: provenance,
        dominantLanguage: "pt", updatedAt: msDate())
    let notes = makeNotes(meetingID: meeting.id)
    guard let finalMeeting = try await MeetingRepository(database: database).fetch(meeting.id) else {
        throw TestFailure()
    }
    let payload = EvidencePayloadBuilder.build(
        meeting: finalMeeting, segments: stored, notes: notes, user: .shippedDefault)
    let relative = database.paths.relativeHandoffPayloadPath(
        meetingID: meeting.id, versionHash: payload.versionHash)
    try ImmutablePayloadWriter.write(payload.bytes, to: database.rootURL.appendingPathComponent(relative))
    return try await database.finalizeMeetingProcessing(
        meetingID: meeting.id, versionHash: payload.versionHash, payloadPath: relative, notes: notes)
}

/// Fixed per-attempt temp-name nonce for deterministic argv assertions.
let testNonce = "00112233aabbccdd"

/// A populated, valid example handoff endpoint — the shape a user enters in
/// Settings on first run. The compiled `HandoffSettings.shippedDefault` is now
/// EMPTY (the public app is Settings-configured on first run), so the worker
/// behavior tests seed this valid config into the store before kicking.
let handoffValidExample = HandoffSettings(
    user: "blaise",
    identityFile: "~/.ssh/id_ed25519",
    hosts: ["host.example", "192.0.2.10"],
    remoteRoot: "/srv/blaise/evidence-inbox/blaise")

/// Seed the valid example handoff config into a database's settings store, so a
/// worker built on it has a deliverable destination (replacing the old reliance
/// on a populated compiled default).
func seedHandoffConfig(
    _ database: BlaiseDatabase, _ settings: HandoffSettings = handoffValidExample,
    markdownSidecar: Bool = false
) async throws {
    let store = SettingsStore(database: database)
    try await store.set(HandoffSettings.Key.user, to: settings.user)
    try await store.set(HandoffSettings.Key.identityFile, to: settings.identityFile)
    try await store.set(HandoffSettings.Key.hosts, to: settings.hosts)
    try await store.set(HandoffSettings.Key.remoteRoot, to: settings.remoteRoot)
    // The destination-independent sidecar toggle defaults ON in production
    // (absent key ⇒ ON), but the SSH delivery-mechanics tests assert exact
    // transport call counts on the JSON path; default it OFF here so each
    // delivery is one call, and seed it ON explicitly in the sidecar tests.
    try await store.set(HandoffDestination.Key.localMarkdownSidecar, to: markdownSidecar)
    // Same rationale for the G5 v1.3 destination-independent toggles: seed them
    // to their no-extra-call state so each delivery stays one JSON call. Both
    // now MATCH the shipped defaults (removal OFF, audio OFF), so this seed no
    // longer hides a default from the rest of the suite — the previous version
    // set the OPPOSITE of the then-default, which left the riskiest behaviour
    // (delete-by-default) asserted nowhere. The dedicated tests flip them ON.
    try await store.set(HandoffDestination.Key.removeSupersededPayloads, to: false)
    try await store.set(HandoffDestination.Key.deliverAudio, to: false)
}

/// A coordinated virtual clock for the retry/backoff tests. `now()` reads a
/// stored instant; `sleep(_:)` is the worker's retry-timer seam — it PARKS
/// (suspends without burning real time) for the requested virtual duration and
/// resumes only when the clock is advanced past its deadline OR the timer task
/// is cancelled (which is exactly what an external `kick()` does). Because the
/// backoff/breaker tests proceed via an explicit `kick()` (the external-wake
/// contract that clears all floors and benches), the clock never needs manual
/// advancement: the parked sleep keeps the worker quiescent so `waitUntilSettled`
/// returns with the intermediate parked state intact, and the next `kick()`
/// cancels the timer. This collapses what were REAL-second backoff waits to
/// zero wall-clock without touching any production retry/backoff semantics.
///
/// `advance(by:)` is provided for tests that want the backoff timer itself to
/// fire (without an external wake); the current suite drives everything via
/// `kick()`, so it is unused but kept as part of the clock's contract.
final class VirtualClock: @unchecked Sendable {
    /// One parked sleeper. `CheckedContinuation<Void, Never>` is Sendable, so
    /// it (not an arbitrary closure) is what crosses the Mutex boundary.
    private struct Sleeper {
        var deadline: Date
        var continuation: CheckedContinuation<Void, Never>?
        var done = false  // resumed (advanced-past or cancelled) — resume once
    }
    private struct State {
        var instant: Date
        var sleepers: [Int: Sleeper] = [:]
        var nextID = 0
    }
    private let state: Mutex<State>

    init(start: Date = Date(timeIntervalSince1970: 1_000_000)) {
        state = Mutex(State(instant: start))
    }

    /// The `now` seam: reads the current virtual instant. Captures `self` (the
    /// `Mutex` value cannot be copied out of the class).
    var now: @Sendable () -> Date {
        { [self] in state.withLock { $0.instant } }
    }

    /// The `sleep` seam: suspends for `duration` of VIRTUAL time. Resumes when
    /// the clock is advanced past the deadline OR the timer task is cancelled
    /// (the timer's `Task.isCancelled` guard then short-circuits `timerFired`),
    /// so an external `kick()` — which cancels the timer — unblocks instantly
    /// with no real wait.
    var sleep: @Sendable (Duration) async -> Void {
        { [weak self] duration in
            guard let self else { return }
            let id = self.allocate(duration: duration)
            await withTaskCancellationHandler {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    self.park(id: id, cont: cont)
                }
            } onCancel: {
                self.wake(id: id)
            }
        }
    }

    /// Advances virtual time, resuming every sleeper whose deadline has passed.
    func advance(by duration: Duration) {
        let seconds = duration.seconds
        let due: [Int] = state.withLock { s in
            s.instant = s.instant.addingTimeInterval(seconds)
            return s.sleepers.filter { !$0.value.done && $0.value.deadline <= s.instant }
                .map(\.key)
        }
        for id in due { wake(id: id) }
    }

    // MARK: - Internals

    private func allocate(duration: Duration) -> Int {
        state.withLock { s in
            let id = s.nextID
            s.nextID += 1
            s.sleepers[id] = Sleeper(deadline: s.instant.addingTimeInterval(duration.seconds))
            return id
        }
    }

    /// Parks the continuation, or resumes it immediately if the sleeper was
    /// already woken (cancelled before the continuation attached).
    private func park(id: Int, cont: CheckedContinuation<Void, Never>) {
        let resumeNow: Bool = state.withLock { s in
            guard var sleeper = s.sleepers[id] else { return true }
            if sleeper.done { return true }
            sleeper.continuation = cont
            s.sleepers[id] = sleeper
            return false
        }
        if resumeNow { cont.resume() }
    }

    /// Resumes (once) and retires the sleeper.
    private func wake(id: Int) {
        let cont: CheckedContinuation<Void, Never>? = state.withLock { s in
            guard var sleeper = s.sleepers[id], !sleeper.done else { return nil }
            sleeper.done = true
            let c = sleeper.continuation
            sleeper.continuation = nil
            s.sleepers[id] = sleeper
            return c
        }
        cont?.resume()
    }
}

private extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

func makeWorker(
    _ database: BlaiseDatabase,
    transport: MockTransport = MockTransport(),
    prober: MockProber = MockProber(),
    holder: HandoffStatusHolder? = nil,
    now: @escaping @Sendable () -> Date = { Date() },
    clock: VirtualClock? = nil
) -> HandoffWorker {
    // When a virtual clock is supplied, BOTH `now` and the retry-timer `sleep`
    // wire to it (so backoff waits cost zero wall-clock); the explicit `now`
    // param is ignored in that case. Otherwise: real `now` + the production
    // default real sleep.
    if let clock {
        return HandoffWorker(
            database: database, holder: holder, transport: transport, prober: prober,
            now: clock.now,
            sleep: clock.sleep,
            jitter: { $0 },  // deterministic: full window, no randomness in tests
            nonce: { testNonce })
    }
    return HandoffWorker(
        database: database, holder: holder, transport: transport, prober: prober,
        now: now,
        jitter: { $0 },  // deterministic: full window, no randomness in tests
        nonce: { testNonce })
}

// MARK: - HandoffErrorClass (the reserved-prefix registry)

@Suite struct HandoffErrorClassTests {
    @Test func reservedPrefixesArePinned() {
        #expect(HandoffErrorClass.damagedPrefix == "damaged:")
        #expect(HandoffErrorClass.supersededPrefix == "superseded:")
        #expect(HandoffErrorClass.superseded(byNewerHash: "abc") == "superseded:abc")
        #expect(HandoffErrorClass.damaged("x y").hasPrefix("damaged:"))
    }

    @Test func reservedDetection() {
        #expect(HandoffErrorClass.isReserved("damaged: payload mismatch"))
        #expect(HandoffErrorClass.isReserved("superseded:deadbeef"))
        #expect(!HandoffErrorClass.isReserved("auth: exit=255 Permission denied"))
        #expect(!HandoffErrorClass.isReserved(nil))
        #expect(HandoffErrorClass.isDamaged("damaged: x") && !HandoffErrorClass.isSuperseded("damaged: x"))
    }
}

// MARK: - Settings validation (the ENTIRE injection defense)

@Suite struct HandoffSettingsValidationTests {
    @Test func shippedDefaultIsEmptyAndPausesUntilConfigured() throws {
        // The public app ships an EMPTY handoff default (Settings-configured on
        // first run): empty user/hosts/remoteRoot → validate() throws, so the
        // worker pauses `configurationInvalid` rather than delivering nowhere.
        #expect(HandoffSettings.shippedDefault.user.isEmpty)
        #expect(HandoffSettings.shippedDefault.hosts.isEmpty)
        #expect(HandoffSettings.shippedDefault.remoteRoot.isEmpty)
        #expect(throws: HandoffSettings.ValidationError.self) {
            try HandoffSettings.shippedDefault.validate()
        }
        // A populated config validates cleanly.
        try handoffValidExample.validate()
    }

    @Test func userRule() {
        #expect(HandoffSettings.isValidUser("host"))
        #expect(HandoffSettings.isValidUser("_svc-bot_2"))
        for bad in ["", "Robot9", "bot;rm -rf /", "bot$(reboot)", "bot`x`", "bot bot", "-bot", "böt", "2bot"] {
            #expect(!HandoffSettings.isValidUser(bad), "accepted: \(bad)")
        }
    }

    @Test func hostRule() {
        #expect(HandoffSettings.isValidHost("198.51.100.10"))
        #expect(HandoffSettings.isValidHost("remotehost.example-host.local"))
        // Leading dash in the user@host argv slot is OpenSSH option
        // injection (-oProxyCommand= runs local code).
        for bad in ["-oProxyCommand=evil", "-100.1.1.1", "host name", "h'ost", "$(reboot)", "`x`", "host;ls", "", "host/path"] {
            #expect(!HandoffSettings.isValidHost(bad), "accepted: \(bad)")
        }
    }

    @Test func remoteRootRule() {
        #expect(HandoffSettings.isValidRemoteRoot("/Users/host/Store/evidence-inbox/blaise"))
        #expect(HandoffSettings.isValidRemoteRoot("/Users/host/Store/evidence-inbox/blaise/_test/01ABC"))
        for bad in [
            "relative/path", "/a/../b", "/../etc", "/a//b", "/a'b", "/a b",
            "/a$(x)", "/a`x`", "/-flag", "/", "", "/a;b", "/ã",
        ] {
            #expect(!HandoffSettings.isValidRemoteRoot(bad), "accepted: \(bad)")
        }
    }

    @Test func trailingSlashRemoteRootIsNormalized() {
        // Impl-audit L-3: the validator's charset admits a trailing `/`,
        // which would put `//` in remoteDir — init strips it.
        var settings = handoffValidExample
        settings.remoteRoot = HandoffSettings.normalizedRemoteRoot("/a/b///")
        #expect(settings.remoteRoot == "/a/b")
        let constructed = HandoffSettings(
            user: "host", identityFile: "~/.ssh/id_ed25519", hosts: ["h"],
            remoteRoot: "/Users/host/inbox/")
        #expect(constructed.remoteRoot == "/Users/host/inbox")
        #expect(HandoffSettings.normalizedRemoteRoot("/") == "/")  // still invalid downstream
    }

    @Test func validateThrowsTypedErrors() {
        var settings = handoffValidExample
        settings.user = "BAD USER"
        #expect(throws: HandoffSettings.ValidationError.invalidUser("BAD USER")) { try settings.validate() }
        settings = handoffValidExample
        settings.hosts = []
        #expect(throws: HandoffSettings.ValidationError.noHosts) { try settings.validate() }
        settings.hosts = ["-oProxyCommand=evil"]
        #expect(throws: HandoffSettings.ValidationError.invalidHost("-oProxyCommand=evil")) {
            try settings.validate()
        }
        settings = handoffValidExample
        settings.remoteRoot = "/a/../b"
        #expect(throws: HandoffSettings.ValidationError.invalidRemoteRoot("/a/../b")) {
            try settings.validate()
        }
    }

    @Test func payloadSideValidators() {
        // version hash: exactly 64 lowercase hex.
        #expect(MeetingPaths.isValidVersionHash(String(repeating: "a0", count: 32)))
        #expect(!MeetingPaths.isValidVersionHash(String(repeating: "A0", count: 32)))
        #expect(!MeetingPaths.isValidVersionHash(String(repeating: "a", count: 63)))
        #expect(!MeetingPaths.isValidVersionHash("'; rm -rf /; '" + String(repeating: "a", count: 50)))
        // native id: ULID.
        #expect(ULID.isValid("01ARZ3NDEKTSV4RRFFQ69G5FAV"))
        #expect(!ULID.isValid("../../../../etc/passwd"))
        #expect(!ULID.isValid("01ARZ3NDEKTSV4RRFFQ69G5FA'"))
    }
}

// MARK: - Command construction golden (probed single-element remote command)

@Suite struct HandoffCommandTests {
    let hash = String(repeating: "ab", count: 32)
    let dir = "/Users/host/Store/evidence-inbox/blaise/01ARZ3NDEKTSV4RRFFQ69G5FAV"
    let nonce = testNonce

    @Test func remoteCommandGolden() {
        // Spec v4.3: per-attempt temp-name nonce (.tmp-<hash>-<nonce>); the
        // stale-cleanup glob `.tmp-*` still matches.
        let temp = "\(dir)/.tmp-\(hash)-\(nonce)"
        let expected =
            "find '\(dir)' -name '.tmp-*' -mtime +1 -delete 2>/dev/null; "
            + "mkdir -p '\(dir)' && cat > '\(temp)' && "
            + "A=$(/usr/bin/shasum -a 256 '\(temp)' | cut -d' ' -f1) && "
            + "if [ \"$A\" = '\(hash)' ]; then mv -f '\(temp)' '\(dir)/\(hash).json'; "
            + "else rm -f '\(temp)'; exit 65; fi"
        #expect(HandoffCommand.remoteCommand(remoteDir: dir, hash: hash, nonce: nonce) == expected)
    }

    @Test func argvGolden() {
        let argv = HandoffCommand.argv(
            user: "host", host: "198.51.100.10", identityFile: "~/.ssh/id_ed25519",
            remoteDir: dir, hash: hash, nonce: nonce)
        #expect(argv == [
            "/usr/bin/ssh",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=2",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "IdentitiesOnly=yes",
            "-i", NSHomeDirectory() + "/.ssh/id_ed25519",
            "host@198.51.100.10",
            HandoffCommand.remoteCommand(remoteDir: dir, hash: hash, nonce: nonce),
        ])
        // The remote command travels as ONE argv element (ssh space-joins
        // multi-element remote commands and the login shell re-parses —
        // probed parse error): 1 exe + 12 option tokens + 2 identity + 1
        // user@host + 1 remote command.
        #expect(argv.count == 17)
        #expect(argv.last == HandoffCommand.remoteCommand(remoteDir: dir, hash: hash, nonce: nonce))
    }

    // MARK: - G6 sidecar remote command (destination-independent Markdown upload)

    @Test func sidecarRemoteCommandGolden() {
        // The slug is [a-z0-9-] by MarkdownSidecar.slug's construction; every
        // interpolated value is single-quoted (the same model as remoteCommand).
        let slug = "q2-budget-review"
        let expected =
            "mkdir -p '\(dir)' && rm -f '\(dir)'/*.md 2>/dev/null; "
            + "cat > '\(dir)/\(slug).md'"
        #expect(HandoffCommand.sidecarRemoteCommand(remoteDir: dir, slug: slug) == expected)
    }

    @Test func sidecarArgvGolden() {
        let slug = "weekly-sync"
        let argv = HandoffCommand.sidecarArgv(
            user: "host", host: "198.51.100.10", identityFile: "~/.ssh/id_ed25519",
            remoteDir: dir, slug: slug)
        #expect(argv == [
            "/usr/bin/ssh",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=2",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "IdentitiesOnly=yes",
            "-i", NSHomeDirectory() + "/.ssh/id_ed25519",
            "host@198.51.100.10",
            HandoffCommand.sidecarRemoteCommand(remoteDir: dir, slug: slug),
        ])
        // ONE remote-command argv element, same structure as the JSON argv.
        #expect(argv.count == 17)
        #expect(argv.last == HandoffCommand.sidecarRemoteCommand(remoteDir: dir, slug: slug))
    }

    /// Injection-safety: a meeting title FULL of shell metacharacters still
    /// produces a [a-z0-9-] slug (the only new interpolated value), which sits
    /// safely inside the single quotes — the command cannot break out. remoteDir
    /// is `remoteRoot` (validated: no `'`, no `..`, no `//`) + `/` + a ULID.
    @Test func sidecarSlugFromHostileTitleStaysSafe() {
        let hostile = "'; rm -rf / # $(curl evil) `whoami` && cat /etc/passwd"
        let slug = MarkdownSidecar.slug(hostile)
        // The slug carries NO shell metacharacter — only [a-z0-9-].
        #expect(slug.allSatisfy { $0 == "-" || ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") })
        #expect(!slug.contains("'"))
        let command = HandoffCommand.sidecarRemoteCommand(remoteDir: dir, slug: slug)
        // No single quote ever appears INSIDE the quoted path (it would be the
        // only way to break out); the only quotes are the delimiters we placed.
        #expect(command == "mkdir -p '\(dir)' && rm -f '\(dir)'/*.md 2>/dev/null; cat > '\(dir)/\(slug).md'")
        // Sanity: a fully-metacharacter title still slugs to the safe fallback
        // rather than an empty (and thus `/.md`) name.
        #expect(MarkdownSidecar.slug("';#`$&|") == "meeting")
    }

    @Test func makeNonceIsQuoteSafeHexAndPerAttempt() {
        for _ in 0..<20 {
            let nonce = HandoffCommand.makeNonce()
            // 16 lowercase hex chars — inside the validated charsets, so it
            // cannot widen the injection surface.
            #expect(nonce.wholeMatch(of: /[0-9a-f]{16}/) != nil, "bad nonce: \(nonce)")
        }
        #expect(HandoffCommand.makeNonce() != HandoffCommand.makeNonce())
    }

    @Test func watchdogFormula() {
        #expect(HandoffCommand.watchdogTimeout(payloadByteCount: 0) == 120)
        #expect(HandoffCommand.watchdogTimeout(payloadByteCount: 100_000) == 121)
        #expect(HandoffCommand.watchdogTimeout(payloadByteCount: 1_000_000) == 130)
    }
}

// MARK: - Failure classification (probed taxonomy)

@Suite struct HandoffFailureClassTests {
    func classify(_ exit: Int32?, _ stderr: String, timedOut: Bool = false) -> HandoffFailureClass {
        HandoffFailureClass.classify(exitStatus: exit, stderrTail: stderr, timedOut: timedOut)
    }

    @Test func probedTable() {
        #expect(classify(255, "Sam@198.51.100.10: Permission denied (publickey,password,keyboard-interactive).") == .auth)
        #expect(classify(255, "@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@") == .hostKeyMismatch)
        #expect(classify(255, "Host key verification failed.") == .hostKeyMismatch)
        #expect(classify(255, "ssh: connect to host 198.51.100.10 port 22: Operation timed out") == .hostTransient)
        #expect(classify(255, "ssh: connect to host x port 22: Connection refused") == .hostTransient)
        #expect(classify(65, "") == .transferTransient)
        #expect(classify(1, "cat: stdout: No space left on device") == .remoteDisk)
        #expect(classify(nil, "", timedOut: true) == .transient)  // watchdog
        #expect(classify(1, "mkdir: permission denied") == .transient)
        #expect(classify(42, "") == .transient)
    }

    @Test func exitLabelDistinguishesCancellationFromTimeout() {
        // Impl-audit L-2: a graceful-quit cancellation must not masquerade
        // as a watchdog timeout in lastError bookkeeping.
        #expect(HandoffTransportOutcome(exitStatus: nil, stderrTail: "", timedOut: false, cancelled: true).exitLabel == "cancelled")
        #expect(HandoffTransportOutcome(exitStatus: nil, stderrTail: "", timedOut: true).exitLabel == "timeout")
        #expect(HandoffTransportOutcome(exitStatus: 65, stderrTail: "", timedOut: false).exitLabel == "65")
    }

    @Test func failureMessagesNeverCollideWithReservedPrefixes() {
        for cls in [HandoffFailureClass.auth, .hostKeyMismatch, .hostTransient, .transferTransient, .remoteDisk, .transient] {
            #expect(!HandoffErrorClass.isReserved("\(cls.rawValue): exit=255 detail"))
        }
    }
}

// MARK: - Backoff math

@Suite struct HandoffBackoffTests {
    @Test func parametersArePinned() {
        #expect(HandoffBackoff.itemBase == 30)
        #expect(HandoffBackoff.itemCap == 900)
        #expect(HandoffBackoff.hostBase == 10)
        #expect(HandoffBackoff.hostCap == 300)
        #expect(HandoffBackoff.authFloor == 3600)
        #expect(HandoffBackoff.hostKeyFloor == 900)
        #expect(HandoffBackoff.remoteDiskFloor == 900)
        #expect(HandoffBackoff.benchStrikeLimit == 3)
    }

    @Test func ceilingDoublesAndCaps() {
        #expect(HandoffBackoff.ceiling(base: 30, cap: 900, exponent: 0) == 30)
        #expect(HandoffBackoff.ceiling(base: 30, cap: 900, exponent: 3) == 240)
        #expect(HandoffBackoff.ceiling(base: 30, cap: 900, exponent: 5) == 900)  // capped
        #expect(HandoffBackoff.ceiling(base: 30, cap: 900, exponent: 500) == 900)  // clamp, no overflow
        #expect(HandoffBackoff.ceiling(base: 10, cap: 300, exponent: -1) == 10)
    }

    @Test func fullJitterSpansTheWindow() {
        // delay = random(0, min(cap, base·2^n)) — full jitter, AWS form.
        #expect(HandoffBackoff.fullJitter(base: 30, cap: 900, exponent: 2, random: { $0 }) == 120)
        #expect(HandoffBackoff.fullJitter(base: 30, cap: 900, exponent: 2, random: { _ in 0 }) == 0)
        for _ in 0..<50 {
            let delay = HandoffBackoff.fullJitter(base: 30, cap: 900, exponent: 4)
            #expect(delay >= 0 && delay <= 480)
        }
    }
}

// MARK: - Worker behavior (mock transport over a real DB)

@Suite(.serialized) struct HandoffWorkerBehaviorTests {
    @Test func drainsFIFOByCreatedSeq() async throws {
        let database = try makeDatabase()
        let first = try await seedDeliverable(database, title: "primeira")
        let second = try await seedDeliverable(database, title: "segunda")
        let third = try await seedDeliverable(database, title: "terceira")
        let transport = MockTransport()
        let worker = makeWorker(database, transport: transport)
        await worker.kick()
        await worker.waitUntilSettled()

        let history = await worker.deliveryHistory()
        #expect(history.map(\.itemID) == [first.id, second.id, third.id])
        #expect(history.map(\.createdSeq) == [1, 2, 3])
        let rows = try await HandoffRepository(database: database).allItems()
        #expect(rows.allSatisfy { $0.state == .delivered })
        #expect(transport.callCount == 3)
        await #expect(worker.currentSnapshot().state == .idle)
        await #expect(worker.currentSnapshot().pendingCount == 0)
    }

    @Test func deliveryStreamsExactPayloadBytesWithPinnedArgv() async throws {
        let database = try makeDatabase()
        let item = try await seedDeliverable(database)
        let transport = MockTransport()
        let worker = makeWorker(database, transport: transport)
        await worker.kick()
        await worker.waitUntilSettled()

        let call = try #require(transport.calls.first)
        let bytes = try Data(contentsOf: database.rootURL.appendingPathComponent(item.payloadPath))
        #expect(call.payload == bytes)
        #expect(call.timeout == HandoffCommand.watchdogTimeout(payloadByteCount: bytes.count))
        let settings = handoffValidExample
        #expect(call.argv == HandoffCommand.argv(
            user: settings.user, host: settings.hosts[0], identityFile: settings.identityFile,
            remoteDir: settings.remoteRoot + "/" + item.meetingID, hash: item.versionHash,
            nonce: testNonce))
    }

    @Test func corruptPayloadIsRematerializedVerifiedAndDelivered() async throws {
        let database = try makeDatabase()
        let item = try await seedDeliverable(database)
        let url = database.rootURL.appendingPathComponent(item.payloadPath)
        try Data("corrupted bytes".utf8).write(to: url)  // plant corruption
        let transport = MockTransport()
        let worker = makeWorker(database, transport: transport)
        await worker.kick()
        await worker.waitUntilSettled()

        let rows = try await HandoffRepository(database: database).allItems()
        #expect(rows.first?.state == .delivered)
        // Repaired on disk, byte-verified against the stored versionHash.
        let repaired = try Data(contentsOf: url)
        #expect(EvidencePayloadBuilder.sha256Hex(repaired) == item.versionHash)
        #expect(transport.calls.first?.payload == repaired)
    }

    @Test func missingPayloadFileIsTreatedExactlyAsMismatch() async throws {
        // Round-4 M-3: the C1-promised recovery path.
        let database = try makeDatabase()
        let item = try await seedDeliverable(database)
        let url = database.rootURL.appendingPathComponent(item.payloadPath)
        try FileManager.default.removeItem(at: url)
        let worker = makeWorker(database)
        await worker.kick()
        await worker.waitUntilSettled()

        let rows = try await HandoffRepository(database: database).allItems()
        #expect(rows.first?.state == .delivered)
        #expect(EvidencePayloadBuilder.sha256Hex(try Data(contentsOf: url)) == item.versionHash)
    }

    @Test func doubleMismatchQuarantinesDamagedAndQueueProceeds() async throws {
        let database = try makeDatabase()
        let damaged = try await seedDeliverable(database, title: "vai quebrar")
        let healthy = try await seedDeliverable(database, title: "segue o baile")
        // Corrupt the file AND drift the durable state (different notes) so
        // re-materialization cannot reproduce the stored hash.
        let url = database.rootURL.appendingPathComponent(damaged.payloadPath)
        let corruptBytes = Data("not the payload".utf8)
        try corruptBytes.write(to: url)
        try await NotesRepository(database: database)
            .upsert(makeNotes(meetingID: damaged.meetingID, markdown: "# conteúdo divergente"))
        let transport = MockTransport()
        let worker = makeWorker(database, transport: transport)
        await worker.kick()
        await worker.waitUntilSettled()

        let rows = try await HandoffRepository(database: database).allItems()
        let damagedRow = try #require(rows.first { $0.id == damaged.id })
        #expect(damagedRow.state == .failed)
        #expect(HandoffErrorClass.isDamaged(damagedRow.lastError))
        // The file is left in place for diagnosis (delete-then-write of
        // unverified bytes could manufacture a mismatched file).
        #expect(try Data(contentsOf: url) == corruptBytes)
        // The queue was NOT starved: the healthy item delivered.
        #expect(rows.first { $0.id == healthy.id }?.state == .delivered)
        #expect(transport.callCount == 1)
        // Loud in the snapshot.
        let snapshot = await worker.currentSnapshot()
        #expect(snapshot.damagedItems.map(\.id) == [damaged.id])
    }

    @Test func damagedItemRecheckedOnceAtRelaunch() async throws {
        let database = try makeDatabase()
        let item = try await seedDeliverable(database)
        _ = try await HandoffRepository(database: database)
            .transition(item.id, to: .failed, error: HandoffErrorClass.damaged("planted"))
        // Plain kick: damaged rows are wake-exempt — nothing delivers.
        let transport = MockTransport()
        let worker = makeWorker(database, transport: transport)
        await worker.kick()
        await worker.waitUntilSettled()
        #expect(transport.callCount == 0)

        // start() = the relaunch wake: re-checks once; the payload is fine
        // here, so it delivers.
        await worker.start()
        await worker.waitUntilSettled()
        await worker.stop()
        let rows = try await HandoffRepository(database: database).allItems()
        #expect(rows.first?.state == .delivered)
    }

    @Test func invalidStoredHashQuarantinesWithoutReachingCommandConstruction() async throws {
        let database = try makeDatabase()
        try await seedHandoffConfig(database)  // valid destination (empty default would pause the worker)
        let meeting = makeMeeting()
        try await MeetingRepository(database: database).create(meeting)
        let evilHash = "$(touch pwned)`reboot`'"  // shell-meta, path-safe
        let path = try plantPayload(database, meetingID: meeting.id, versionHash: evilHash)
        _ = try await HandoffRepository(database: database)
            .enqueue(meetingID: meeting.id, versionHash: evilHash, payloadPath: path)
        let transport = MockTransport()
        let worker = makeWorker(database, transport: transport)
        await worker.kick()
        await worker.waitUntilSettled()

        #expect(transport.callCount == 0)  // never reached the transport
        let row = try #require(try await HandoffRepository(database: database).allItems().first)
        #expect(row.state == .failed)
        #expect(HandoffErrorClass.isDamaged(row.lastError))
    }

    @Test func invalidRemoteRootPausesWorkerItemsStayPending() async throws {
        // Round-3 H-2: CONFIG failure ≠ damage.
        let database = try makeDatabase()
        _ = try await seedDeliverable(database)
        try await SettingsStore(database: database).set(HandoffSettings.Key.remoteRoot, to: "/evil/../path")
        let transport = MockTransport()
        let worker = makeWorker(database, transport: transport)
        await worker.kick()
        await worker.waitUntilSettled()

        #expect(transport.callCount == 0)
        let rows = try await HandoffRepository(database: database).allItems()
        #expect(rows.first?.state == .pending)  // untouched
        await #expect(worker.currentSnapshot().state == .configurationInvalid)

        // Settings fix + kick resumes everything immediately.
        try await SettingsStore(database: database)
            .set(HandoffSettings.Key.remoteRoot, to: handoffValidExample.remoteRoot)
        await worker.kick()
        await worker.waitUntilSettled()
        #expect(try await HandoffRepository(database: database).allItems().first?.state == .delivered)
    }

    @Test func authFailureFloorsItemAndWakeClearsIt() async throws {
        let database = try makeDatabase()
        _ = try await seedDeliverable(database)
        let transport = MockTransport(script: [
            HandoffTransportOutcome(
                exitStatus: 255, stderrTail: "Permission denied (publickey).", timedOut: false)
        ])
        let worker = makeWorker(database, transport: transport, clock: VirtualClock())
        await worker.kick()
        await worker.waitUntilSettled()

        var rows = try await HandoffRepository(database: database).allItems()
        #expect(rows.first?.state == .failed)
        #expect(rows.first?.lastError?.hasPrefix("auth:") == true)
        #expect(transport.callCount == 1)  // floored at 1 h — no burn
        await #expect(worker.currentSnapshot().state == .authFailure)

        // The fixed key delivers on the next kick, not in an hour.
        await worker.kick()
        await worker.waitUntilSettled()
        rows = try await HandoffRepository(database: database).allItems()
        #expect(rows.first?.state == .delivered)
        #expect(transport.callCount == 2)
    }

    @Test func hostKeyMismatchIsDistinctAlertWithoutRetryBurn() async throws {
        let database = try makeDatabase()
        _ = try await seedDeliverable(database)
        let transport = MockTransport(script: [
            HandoffTransportOutcome(
                exitStatus: 255,
                stderrTail: "@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@",
                timedOut: false)
        ])
        let worker = makeWorker(database, transport: transport)
        await worker.kick()
        await worker.waitUntilSettled()

        #expect(transport.callCount == 1)
        await #expect(worker.currentSnapshot().state == .hostKeyMismatch)
        let rows = try await HandoffRepository(database: database).allItems()
        #expect(rows.first?.lastError?.hasPrefix("hostKeyMismatch:") == true)
    }

    @Test func transferCorruptionExit65RetriesAfterBackoff() async throws {
        let database = try makeDatabase()
        _ = try await seedDeliverable(database)
        let transport = MockTransport(script: [
            HandoffTransportOutcome(exitStatus: 65, stderrTail: "", timedOut: false)
        ])
        let worker = makeWorker(database, transport: transport, clock: VirtualClock())
        await worker.kick()
        await worker.waitUntilSettled()

        // First attempt failed transfer; item floored (jitter = full window
        // = 30 s) → worker blocked in waitingRetry, NOT delivered yet.
        #expect(transport.callCount == 1)
        await #expect(worker.currentSnapshot().state == .waitingRetry)
        // Wake clears the floor; retry delivers (self-check already proved
        // local bytes good — 65 means transfer trouble, retry fixes).
        await worker.kick()
        await worker.waitUntilSettled()
        await worker.stop()
        #expect(try await HandoffRepository(database: database).allItems().first?.state == .delivered)
    }

    @Test func allHostsDownOpensBreakerNothingLostAndWakeClearsBenches() async throws {
        let database = try makeDatabase()
        _ = try await seedDeliverable(database)
        _ = try await seedDeliverable(database)
        let prober = MockProber(reachable: false)
        let transport = MockTransport()
        let worker = makeWorker(database, transport: transport, prober: prober, clock: VirtualClock())
        await worker.kick()
        await worker.waitUntilSettled()

        #expect(transport.callCount == 0)
        await #expect(worker.currentSnapshot().state == .allEndpointsDown)
        var rows = try await HandoffRepository(database: database).allItems()
        #expect(rows.allSatisfy { $0.state == .pending })  // nothing lost

        // Hosts restored + external wake (clears benches + strikes) → both
        // deliver, in order.
        prober.set(reachable: true)
        await worker.kick()
        await worker.waitUntilSettled()
        await worker.stop()
        rows = try await HandoffRepository(database: database).allItems()
        #expect(rows.allSatisfy { $0.state == .delivered })
        let history = await worker.deliveryHistory()
        #expect(history.map(\.createdSeq) == [1, 2])
    }

    @Test func reachableHostFailingSSHIsBenchedAfterThreeStrikes() async throws {
        let database = try makeDatabase()
        _ = try await seedDeliverable(database)
        let refused = HandoffTransportOutcome(
            exitStatus: 255, stderrTail: "ssh: connect to host x port 22: Connection refused",
            timedOut: false)
        // 3 strikes on host 1, then 3 on host 2 → both benched → breaker.
        let transport = MockTransport(script: Array(repeating: refused, count: 6))
        let worker = makeWorker(database, transport: transport, clock: VirtualClock())
        await worker.kick()
        await worker.waitUntilSettled()

        #expect(transport.callCount == 6)
        await #expect(worker.currentSnapshot().state == .allEndpointsDown)
        // Wake clears benches; the next attempt succeeds.
        await worker.kick()
        await worker.waitUntilSettled()
        #expect(try await HandoffRepository(database: database).allItems().first?.state == .delivered)
    }

    @Test func supersessionSweepClosesOlderUndeliveredOnNewerDelivery() async throws {
        // D12: damaged old version + delivered new version of the SAME
        // meeting → the wedge resolves as superseded:<newer hash>.
        let database = try makeDatabase()
        let item = try await seedDeliverable(database)
        // Newer version of the same meeting: drift content, rebuild, enqueue.
        let newNotes = makeNotes(meetingID: item.meetingID, markdown: "# v2")
        guard let meeting = try await MeetingRepository(database: database).fetch(item.meetingID) else {
            throw TestFailure()
        }
        let segments = try await TranscriptRepository(database: database).segments(meetingID: item.meetingID)
        let newPayload = EvidencePayloadBuilder.build(
            meeting: meeting, segments: segments, notes: newNotes, user: .shippedDefault)
        let newPath = database.paths.relativeHandoffPayloadPath(
            meetingID: item.meetingID, versionHash: newPayload.versionHash)
        try ImmutablePayloadWriter.write(
            newPayload.bytes, to: database.rootURL.appendingPathComponent(newPath))
        let newItem = try await database.finalizeMeetingProcessing(
            meetingID: item.meetingID, versionHash: newPayload.versionHash,
            payloadPath: newPath, notes: newNotes)
        // Old payload now unreproducible (notes drifted) AND corrupt on disk.
        try Data("rotten".utf8).write(to: database.rootURL.appendingPathComponent(item.payloadPath))

        let worker = makeWorker(database)
        await worker.kick()
        await worker.waitUntilSettled()
        await worker.stop()

        let rows = try await HandoffRepository(database: database).allItems()
        let old = try #require(rows.first { $0.id == item.id })
        let new = try #require(rows.first { $0.id == newItem.id })
        #expect(new.state == .delivered)
        #expect(old.state == .failed)
        #expect(old.lastError == HandoffErrorClass.superseded(byNewerHash: newPayload.versionHash))
    }

    @Test func startupSweepClosesCrashWindowSupersededRows() async throws {
        // Impl-audit M-1: plant the historical crash-window state (newer
        // version DELIVERED, older version still pending — possible only
        // under a pre-fix binary, where transition and sweep were separate
        // transactions) → relaunch → the start() catch-up sweep closes the
        // older row as superseded instead of delivering stale content.
        let database = try makeDatabase()
        let old = try await seedDeliverable(database)
        let newNotes = makeNotes(meetingID: old.meetingID, markdown: "# v2")
        guard let meeting = try await MeetingRepository(database: database).fetch(old.meetingID) else {
            throw TestFailure()
        }
        let segments = try await TranscriptRepository(database: database).segments(meetingID: old.meetingID)
        let newPayload = EvidencePayloadBuilder.build(
            meeting: meeting, segments: segments, notes: newNotes, user: .shippedDefault)
        let newPath = database.paths.relativeHandoffPayloadPath(
            meetingID: old.meetingID, versionHash: newPayload.versionHash)
        try ImmutablePayloadWriter.write(
            newPayload.bytes, to: database.rootURL.appendingPathComponent(newPath))
        let newItem = try await database.finalizeMeetingProcessing(
            meetingID: old.meetingID, versionHash: newPayload.versionHash,
            payloadPath: newPath, notes: newNotes)
        let repo = HandoffRepository(database: database)
        // Mark the newer row delivered WITHOUT any sweep — the crash window.
        _ = try await repo.transition(newItem.id, to: .delivering)
        _ = try await repo.transition(newItem.id, to: .delivered)

        let transport = MockTransport()
        let worker = makeWorker(database, transport: transport)
        await worker.start()  // the relaunch wake
        await worker.waitUntilSettled()
        await worker.stop()

        #expect(transport.callCount == 0)  // the stale older version never shipped
        let rows = try await repo.allItems()
        let oldRow = try #require(rows.first { $0.id == old.id })
        #expect(oldRow.state == .failed)
        #expect(oldRow.lastError == HandoffErrorClass.superseded(byNewerHash: newPayload.versionHash))
        #expect(rows.first { $0.id == newItem.id }?.state == .delivered)
    }

    @Test func failedDeliveringClaimFloorsItemInsteadOfBusySpinning() async throws {
        // Impl-audit M-2: a local DB write failure on the `delivering` claim
        // must arm the item-backoff timer, not spin the drain loop. A second
        // raw SQLite connection holds the write lock (BEGIN IMMEDIATE), so
        // every pool write fails while reads keep working (WAL).
        let database = try makeDatabase()
        let item = try await seedDeliverable(database)
        let transport = MockTransport()
        let worker = makeWorker(database, transport: transport)

        let dbPath = database.rootURL.appendingPathComponent(BlaiseDatabase.databaseFileName).path
        var blocker: OpaquePointer?
        #expect(sqlite3_open(dbPath, &blocker) == SQLITE_OK)
        defer { sqlite3_close(blocker) }
        #expect(sqlite3_exec(blocker, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)

        await worker.kick()
        await worker.waitUntilSettled()  // pre-fix: never settles (busy spin)

        #expect(transport.callCount == 0)
        await #expect(worker.currentSnapshot().state == .waitingRetry)
        #expect(try await HandoffRepository(database: database).allItems().first?.state == .pending)

        // Write lock released + external wake → delivers normally.
        #expect(sqlite3_exec(blocker, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
        await worker.kick()
        await worker.waitUntilSettled()
        await worker.stop()
        #expect(transport.callCount == 1)
        let row = try #require(try await HandoffRepository(database: database).allItems().first)
        #expect(row.id == item.id && row.state == .delivered)
    }

    @Test func deliveredIsNeverSuperseded() async throws {
        let database = try makeDatabase()
        let repo = HandoffRepository(database: database)
        let item = try await seedDeliverable(database)
        _ = try await repo.transition(item.id, to: .delivering)
        _ = try await repo.transition(item.id, to: .delivered)
        let closed = try await repo.supersedeOlder(
            meetingID: item.meetingID, newerSeq: item.createdSeq + 10, newerHash: "feed")
        #expect(closed.isEmpty)
        #expect(try await repo.allItems().first?.state == .delivered)
    }

    @Test func rematerializedBytesHashEqualStoredVersionHash() async throws {
        // The C-2 regression: rebuild from durable state alone must
        // reproduce the stored versionHash byte-for-byte (this is what makes
        // the damaged-file recovery path possible at all). Exercises the
        // full real path INCLUDING finalize (which must not mutate builder
        // inputs after the payload is minted).
        let database = try makeDatabase()
        let item = try await seedDeliverable(database, segmentText: "çãé emoji 🎙 \"quotes\" \\back")
        guard
            let meeting = try await MeetingRepository(database: database).fetch(item.meetingID),
            let notes = try await NotesRepository(database: database).fetch(meetingID: item.meetingID)
        else { throw TestFailure() }
        let segments = try await TranscriptRepository(database: database).segments(meetingID: item.meetingID)
        let rebuilt = EvidencePayloadBuilder.build(
            meeting: meeting, segments: segments, notes: notes, user: .shippedDefault)
        #expect(rebuilt.versionHash == item.versionHash)
        let stored = try Data(contentsOf: database.rootURL.appendingPathComponent(item.payloadPath))
        #expect(rebuilt.bytes == stored)
    }

    @Test func preG4LegacyKeyPayloadReMaterializesAndRecovers() async throws {
        // G4-M3 regression: an item minted BEFORE the legacy→user key rename stored a
        // payload (and version_hash) keyed `ric_action_items`. When its file is
        // damaged/missing, re-materialization must reproduce that LEGACY hash
        // and recover — not quarantine. With the builder emitting the new key
        // UNCONDITIONALLY, the rebuilt bytes carry `user_action_items`, the hash
        // never matches, and this item quarantines: this test fails. The
        // presence-gated legacy-key path makes it pass.
        let database = try makeDatabase()
        try await seedHandoffConfig(database)  // valid destination (empty default would pause the worker)
        let meeting = makeMeeting(title: "Pré-G4", attendees: [
            Attendee(name: "Sam", email: "sam.rivera@vexatron.test", source: .manual)
        ])
        try await MeetingRepository(database: database).create(meeting)
        let provenance = ASRProvenance(
            engine: "stub", model: "stub", runtime: "stub", engineVersion: "1", transcribedAt: msDate())
        let segments = [
            TranscriptSegment(
                meetingID: meeting.id, ord: 0, startSeconds: 0, endSeconds: 1.5,
                speakerLabel: "S0", speakerName: "Sam", text: "Olá"),
        ]
        let stored = try await database.persistTranscript(
            meetingID: meeting.id, segments: segments, asrProvenance: provenance,
            dominantLanguage: "pt", updatedAt: msDate())
        let notes = makeNotes(meetingID: meeting.id)
        guard let finalMeeting = try await MeetingRepository(database: database).fetch(meeting.id) else {
            throw TestFailure()
        }
        // Mint the payload the OLD way: legacy `ric_action_items` key form.
        let legacy = EvidencePayloadBuilder.build(
            meeting: finalMeeting, segments: stored, notes: notes, user: .shippedDefault,
            userActionItemsKey: .legacy)
        #expect(String(decoding: legacy.bytes, as: UTF8.self).contains("ric_action_items"))
        let relative = database.paths.relativeHandoffPayloadPath(
            meetingID: meeting.id, versionHash: legacy.versionHash)
        try ImmutablePayloadWriter.write(legacy.bytes, to: database.rootURL.appendingPathComponent(relative))
        let item = try await database.finalizeMeetingProcessing(
            meetingID: meeting.id, versionHash: legacy.versionHash, payloadPath: relative, notes: notes)

        // Damage the file so the pre-stream self-check must re-materialize.
        let url = database.rootURL.appendingPathComponent(item.payloadPath)
        try FileManager.default.removeItem(at: url)

        let transport = MockTransport()
        let worker = makeWorker(database, transport: transport)
        await worker.kick()
        await worker.waitUntilSettled()

        let rows = try await HandoffRepository(database: database).allItems()
        // Recovered, not quarantined: delivered, file restored to the LEGACY
        // bytes, hash intact.
        #expect(rows.first?.state == .delivered)
        let restored = try Data(contentsOf: url)
        #expect(EvidencePayloadBuilder.sha256Hex(restored) == item.versionHash)
        #expect(String(decoding: restored, as: UTF8.self).contains("ric_action_items"))
        #expect(transport.calls.first?.payload == restored)
        #expect(await worker.currentSnapshot().damagedItems.isEmpty)
    }

    @Test func queuedMdV2DigestPayloadReMaterializesAndRecoversAfterShippedBump() async throws {
        // T3.2 / AC6: a payload minted under a PRIOR digest contract (md-v2)
        // carries a memory_digest, so its version_hash bakes in `md-v2`. After
        // the shipped bump (now md-v6), that queued item's file is damaged/missing
        // and re-materialization must reproduce the md-v2 hash — the worker
        // rebuilds across the SHIPPED version then each prior one
        // (md-v1 … md-v5 via `DigestPromptVersion.allCases`), so the md-v2 build
        // matches and the item RECOVERS instead of quarantining. Every prior
        // contract is retained append-only, which is what makes this loop reach
        // the matching build.
        #expect(DigestPromptBuilder.shippedVersion == .mdV6, "precondition: md-v6 is shipped")
        let database = try makeDatabase()
        try await seedHandoffConfig(database)  // valid destination (empty default would pause the worker)
        let meeting = makeMeeting(title: "Quoll Harbor roadmap", attendees: [
            Attendee(name: "Dana Marsh", email: "dana@vexatronlabs.example", source: .manual)
        ])
        try await MeetingRepository(database: database).create(meeting)
        let provenance = ASRProvenance(
            engine: "stub", model: "stub", runtime: "stub", engineVersion: "1", transcribedAt: msDate())
        let segments = [
            TranscriptSegment(
                meetingID: meeting.id, ord: 0, startSeconds: 0, endSeconds: 1.5,
                speakerLabel: "S0", speakerName: "Dana Marsh", text: "Shipping in May."),
        ]
        let stored = try await database.persistTranscript(
            meetingID: meeting.id, segments: segments, asrProvenance: provenance,
            dominantLanguage: "en", updatedAt: msDate())
        // A notes row carrying a memory_digest, so the digest contract version is
        // load-bearing in the payload bytes (not a no-op digest axis).
        var notes = makeNotes(meetingID: meeting.id)
        notes.memoryDigest = "## HEADER\nmeeting: Quoll Harbor roadmap\ndate: 2026-03-14\nspeaker: Dana Marsh\n"
        guard let finalMeeting = try await MeetingRepository(database: database).fetch(meeting.id) else {
            throw TestFailure()
        }
        // Mint the payload under the PRIOR contract: md-v2 (no longer shipped).
        let priorContract = EvidencePayloadBuilder.build(
            meeting: finalMeeting, segments: stored, notes: notes, user: .shippedDefault,
            digestPromptVersion: .mdV2)
        #expect(String(decoding: priorContract.bytes, as: UTF8.self)
            .contains("\"prompt_version\":\"md-v2\""))
        // The SHIPPED build (md-v3) produces a DIFFERENT hash — so recovery cannot
        // come from the shipped combination; it must reach the md-v2 build.
        let shippedBuild = EvidencePayloadBuilder.build(
            meeting: finalMeeting, segments: stored, notes: notes, user: .shippedDefault)
        #expect(shippedBuild.versionHash != priorContract.versionHash)
        let relative = database.paths.relativeHandoffPayloadPath(
            meetingID: meeting.id, versionHash: priorContract.versionHash)
        try ImmutablePayloadWriter.write(
            priorContract.bytes, to: database.rootURL.appendingPathComponent(relative))
        let item = try await database.finalizeMeetingProcessing(
            meetingID: meeting.id, versionHash: priorContract.versionHash,
            payloadPath: relative, notes: notes)

        // Damage the file so the pre-stream self-check must re-materialize.
        let url = database.rootURL.appendingPathComponent(item.payloadPath)
        try FileManager.default.removeItem(at: url)

        let transport = MockTransport()
        let worker = makeWorker(database, transport: transport)
        await worker.kick()
        await worker.waitUntilSettled()

        let rows = try await HandoffRepository(database: database).allItems()
        // Recovered, not quarantined: delivered, file restored to the md-v2
        // bytes, hash intact.
        #expect(rows.first?.state == .delivered)
        let restored = try Data(contentsOf: url)
        #expect(EvidencePayloadBuilder.sha256Hex(restored) == item.versionHash)
        #expect(String(decoding: restored, as: UTF8.self).contains("\"prompt_version\":\"md-v2\""))
        #expect(transport.calls.first?.payload == restored)
        #expect(await worker.currentSnapshot().damagedItems.isEmpty)
    }

    @Test func realWorkerWiresIntoThePipelineKickSeam() async throws {
        // The C7 `HandoffKicking` seam, wired to the real worker: the
        // pipeline accepts it (compile-level), and a kick through the seam
        // type drains the queue.
        let database = try makeDatabase()
        let item = try await seedDeliverable(database)
        let worker = makeWorker(database)
        _ = ProcessingPipeline(
            database: database,
            registry: try EngineRegistry(asr: [], summarization: []),
            diarizer: PipelineMockDiarizer(),
            vocabulary: try VocabFixtures.pipelineVocabulary(),
            handoffKicker: worker)
        let kicker: any HandoffKicking = worker
        await kicker.kick()
        await worker.waitUntilSettled()
        #expect(try await HandoffRepository(database: database).allItems().first?.state == .delivered)
        #expect(await worker.deliveryHistory().first?.itemID == item.id)
    }

    @Test(.disabled("PRE-EXISTING in-process deadlock (confirmed on the unmodified baseline via git-stash, unrelated to the backoff virtual clock): the test blocks the main thread with DispatchSemaphore.wait() inside DispatchQueue.main.async and awaits across it, which deadlocks the swift-testing in-process runner in this toolchain — it was the sole cause of the `--filter Handoff` watchdog hang. Documented internally with a fix (re-express the main-actor occupation without blocking the main thread). Re-enable after that fix.")) func kickLandingDuringIdlePublishSuspensionIsNotLost() async throws {
        // Impl-audit H-1 regression: a kick that lands while drain() is
        // suspended inside publish(.idle)'s MainActor hop must re-loop, not
        // be swallowed (the item would otherwise sit `pending` until the
        // next unrelated wake).
        let database = try makeDatabase()
        let holder = await MainActor.run { HandoffStatusHolder() }
        let transport = MockTransport()
        let worker = makeWorker(database, transport: transport, holder: holder)

        // Make lastSnapshot distinguishable from .initial (.idle) so the
        // poll below deterministically detects the publish(.idle) call:
        // an invalid root parks the worker in configurationInvalid.
        try await SettingsStore(database: database)
            .set(HandoffSettings.Key.remoteRoot, to: "/evil/../path")
        await worker.kick()
        await worker.waitUntilSettled()
        await #expect(worker.currentSnapshot().state == .configurationInvalid)
        try await SettingsStore(database: database)
            .set(HandoffSettings.Key.remoteRoot, to: handoffValidExample.remoteRoot)

        // Occupy the main actor: a synchronous block on the main queue holds
        // the main thread, so the next publish suspends at MainActor.run.
        let occupied = Mutex(false)
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            occupied.withLock { $0 = true }
            // Bounded: the signal (line below, after the kick-during-suspension
            // setup) normally arrives in milliseconds, so this never fires on
            // the happy path. The timeout exists only so full-suite parallelism
            // — where cooperative-pool pressure can delay the test task reaching
            // release.signal() — can never turn this main-thread occupier into a
            // permanent, suite-killing deadlock.
            _ = release.wait(timeout: .now() + .seconds(30))
        }
        while !occupied.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(2))
        }

        // Queue still empty: drain heads for publish(.idle). lastSnapshot is
        // assigned BEFORE the MainActor hop, so once we observe .idle the
        // drain is parked inside publish(.idle) (main actor is blocked) and
        // cannot have returned yet.
        await worker.kick()
        while await worker.currentSnapshot().state != .idle {
            try await Task.sleep(for: .milliseconds(2))
        }

        // Enqueue + kick DURING the suspension (actor reentrancy lets kick()
        // run while drain() is suspended; ensureDraining no-ops, only
        // wakeGeneration records the wake).
        _ = try await seedDeliverable(database)
        await worker.kick()

        release.signal()
        await worker.waitUntilSettled()
        await worker.stop()
        #expect(transport.callCount == 1)
        let rows = try await HandoffRepository(database: database).allItems()
        #expect(rows.first?.state == .delivered)
    }

    @Test func snapshotPublishesToMainActorHolder() async throws {
        let database = try makeDatabase()
        _ = try await seedDeliverable(database)
        // Compile-level: HandoffStatusHolder is @MainActor — constructing
        // and reading it REQUIRE MainActor isolation.
        let holder = await MainActor.run { HandoffStatusHolder() }
        await MainActor.run { #expect(holder.snapshot == HandoffSnapshot.initial) }
        let worker = makeWorker(database, holder: holder)
        await worker.kick()
        await worker.waitUntilSettled()

        let snapshot = await MainActor.run { holder.snapshot }
        #expect(snapshot.state == .idle)
        #expect(snapshot.pendingCount == 0)
        #expect(snapshot.damagedItems.isEmpty)
        // The snapshot is a Sendable value (compile-level assertion).
        let _: any Sendable = snapshot
    }
}

// MARK: - Builder C11 amendment (spec v4.2)

@Suite struct SpeakerSourceC11AmendmentTests {
    @Test func userLabelYieldsMicrophoneRegardlessOfName() {
        // C11 live capture labels mic-track segments "user" — durable and
        // re-materialization-exact, independent of name resolution.
        let meeting = makeMeeting()
        for name in [nil, "Alguém Aleatório"] {
            let segment = TranscriptSegment(
                meetingID: meeting.id, ord: 0, startSeconds: 0, endSeconds: 1,
                speakerLabel: "user", speakerName: name, text: "x")
            #expect(
                EvidencePayloadBuilder.speakerSource(
                    of: segment, meeting: meeting, user: .shippedDefault) == "microphone")
        }
        // Non-"user" labels still depend on the name predicate.
        let other = TranscriptSegment(
            meetingID: meeting.id, ord: 0, startSeconds: 0, endSeconds: 1,
            speakerLabel: "S3", speakerName: "Alguém Aleatório", text: "x")
        #expect(
            EvidencePayloadBuilder.speakerSource(
                of: other, meeting: meeting, user: .shippedDefault) == "speaker")
    }
}
