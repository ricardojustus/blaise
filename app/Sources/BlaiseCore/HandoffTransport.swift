import Foundation
import Network
import Synchronization

// MARK: - Command construction (normative; probed working form)

/// Builds the exact ssh invocation pinned in the C8 spec. The remote command
/// is ONE argv element: ssh space-joins remote-command arguments and the
/// remote LOGIN SHELL re-parses the joined string (the multi-element form is
/// a probed parse error). Every interpolated value is validated upstream
/// (`HandoffSettings.validate()`, hash/ULID checks) — that validation is the
/// entire injection defense.
public enum HandoffCommand {
    /// The verify-before-rename remote command (probed): stale-temp hygiene
    /// prepended via `find` (the `;` isolates its exit code from the `&&`
    /// chain), payload `cat`-ed from stdin to a dot-prefixed temp, hashed
    /// server-side, and renamed into visibility ONLY on hash match. Exit 65
    /// is reserved for transfer corruption (temp self-cleaned). The temp
    /// name carries a per-attempt `nonce` (impl-audit M-3) so an orphaned
    /// post-crash ssh and a relaunch redelivery never write the same temp
    /// file; the `.tmp-*` cleanup glob still matches.
    public static func remoteCommand(remoteDir: String, hash: String, nonce: String) -> String {
        let temp = "\(remoteDir)/.tmp-\(hash)-\(nonce)"
        return "find '\(remoteDir)' -name '.tmp-*' -mtime +1 -delete 2>/dev/null; "
            + "mkdir -p '\(remoteDir)' && cat > '\(temp)' && "
            + "A=$(/usr/bin/shasum -a 256 '\(temp)' | cut -d' ' -f1) && "
            + "if [ \"$A\" = '\(hash)' ]; then mv -f '\(temp)' '\(remoteDir)/\(hash).json'; "
            + "else rm -f '\(temp)'; exit 65; fi"
    }

    /// The Markdown-sidecar upload remote command (G6): a single argv element
    /// re-parsed by the remote LOGIN SHELL, exactly like `remoteCommand`. Both
    /// interpolated values are single-quoted AND validated upstream:
    /// `remoteDir` = `remoteRoot` (`HandoffSettings.isValidRemoteRoot`: no `'`,
    /// no `..`, no `//`) + `/` + `meetingID` (a validated ULID); `slug` is
    /// `[a-z0-9-]` by `MarkdownSidecar.slug`'s construction (the caller asserts
    /// it and skips on any non-match) — neither can break out of its quotes, so
    /// the single-quote model is the entire injection defense, unchanged from
    /// `remoteCommand`. `rm -f '<dir>'/*.md` supersedes a prior-slug sidecar;
    /// the dir is per-meeting so only THIS meeting's `.md` live there and the
    /// immutable `<hash>.json` history is untouched. The `2>/dev/null;`
    /// isolates the `rm`'s exit code (an empty dir is not a failure) from the
    /// `mkdir && cat` chain.
    public static func sidecarRemoteCommand(remoteDir: String, slug: String) -> String {
        "mkdir -p '\(remoteDir)' && rm -f '\(remoteDir)'/*.md 2>/dev/null; "
            + "cat > '\(remoteDir)/\(slug).md'"
    }

    /// Full ssh argv for the sidecar upload — identical option set + identity
    /// handling to `argv`, differing only in the trailing remote command. The
    /// rendered `.md` bytes stream on stdin (the transport's `payload`), exactly
    /// like the JSON payload.
    public static func sidecarArgv(
        user: String, host: String, identityFile: String, remoteDir: String, slug: String
    ) -> [String] {
        [
            "/usr/bin/ssh",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=2",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "IdentitiesOnly=yes",
            "-i", (identityFile as NSString).expandingTildeInPath,
            "\(user)@\(host)",
            sidecarRemoteCommand(remoteDir: remoteDir, slug: slug),
        ]
    }

    /// 16 lowercase hex characters — inside the single-quote-safe charset
    /// every other interpolated value is validated against.
    public static func makeNonce() -> String {
        (0..<8).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    }

    /// Full argv, element 0 = the executable. `identityFile` is
    /// tilde-expanded here; it travels as the `-i` option argument (never
    /// shell-parsed, no injection surface).
    public static func argv(
        user: String, host: String, identityFile: String, remoteDir: String, hash: String,
        nonce: String
    ) -> [String] {
        [
            "/usr/bin/ssh",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=2",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "IdentitiesOnly=yes",
            "-i", (identityFile as NSString).expandingTildeInPath,
            "\(user)@\(host)",
            remoteCommand(remoteDir: remoteDir, hash: hash, nonce: nonce),
        ]
    }

    /// Per-delivery watchdog (audit H-4): 120 s + 1 s per 100 KB of payload;
    /// expiry → SIGTERM/SIGKILL → transient failure. The ServerAlive
    /// keepalives kill dead-TCP hangs earlier in the common case.
    public static func watchdogTimeout(payloadByteCount: Int) -> TimeInterval {
        120 + Double(payloadByteCount) / 100_000
    }
}

// MARK: - Failure classification (probed taxonomy)

public enum HandoffFailureClass: String, Sendable, Equatable {
    /// Exit 255 + "Permission denied (publickey…" — will not self-heal;
    /// item floor 1 h, cleared by wakes.
    case auth
    /// Exit 255 + host-key strings — distinct alert state, 15 min floor,
    /// no retry burn (possible machine reinstall; needs the user).
    case hostKeyMismatch
    /// Exit 255 otherwise — the link, not the item: feeds the per-host
    /// breaker, no item floor.
    case hostTransient
    /// Exit 65 — transfer corruption; local bytes already proved good by the
    /// pre-stream self-check, so retry fixes it.
    case transferTransient
    /// "No space left" from the remote — 15 min floor.
    case remoteDisk
    /// Watchdog expiry and everything else.
    case transient

    public static func classify(exitStatus: Int32?, stderrTail: String, timedOut: Bool) -> HandoffFailureClass {
        if timedOut { return .transient }
        if exitStatus == 255 {
            if stderrTail.contains("Permission denied (publickey") { return .auth }
            if stderrTail.contains("REMOTE HOST IDENTIFICATION HAS CHANGED")
                || stderrTail.contains("Host key verification failed")
            {
                return .hostKeyMismatch
            }
            return .hostTransient
        }
        if exitStatus == 65 { return .transferTransient }
        if stderrTail.contains("No space left") { return .remoteDisk }
        return .transient
    }
}

// MARK: - Transport seam

/// Distilled subprocess outcome — what classification and the worker need.
public struct HandoffTransportOutcome: Sendable {
    public var exitStatus: Int32?
    public var stderrTail: String
    public var timedOut: Bool
    /// The runner killed the child because the TASK was cancelled (graceful
    /// quit), not because the watchdog expired — kept distinct so
    /// `lastError` does not mislabel a cancellation as a timeout.
    public var cancelled: Bool
    /// A LOCAL-folder failure (no subprocess, no watchdog) — kept distinct so
    /// `exitLabel` reads "local" rather than "timeout" (L-6): a missing folder
    /// or permission error is not a timeout.
    public var localFolder: Bool

    public init(
        exitStatus: Int32?, stderrTail: String, timedOut: Bool, cancelled: Bool = false,
        localFolder: Bool = false
    ) {
        self.exitStatus = exitStatus
        self.stderrTail = stderrTail
        self.timedOut = timedOut
        self.cancelled = cancelled
        self.localFolder = localFolder
    }

    public var failureClass: HandoffFailureClass {
        HandoffFailureClass.classify(exitStatus: exitStatus, stderrTail: stderrTail, timedOut: timedOut)
    }

    /// `exit=` label for `lastError` bookkeeping.
    public var exitLabel: String {
        if let exitStatus { return String(exitStatus) }
        if cancelled { return "cancelled" }
        if localFolder { return "local" }
        return "timeout"
    }
}

public protocol HandoffTransporting: Sendable {
    /// Runs `argv` with `payload` as the child's stdin. Throws only on spawn
    /// failure (ssh binary missing — cannot happen on stock macOS).
    func deliver(argv: [String], payload: Data, timeout: TimeInterval) async throws -> HandoffTransportOutcome
}

/// The real transport: subprocess OpenSSH via the C3 `SubprocessRunner`
/// (stdin = payload bytes, written from a detached task, fd closed at EOF).
public struct SSHHandoffTransport: HandoffTransporting {
    public init() {}

    public func deliver(argv: [String], payload: Data, timeout: TimeInterval) async throws -> HandoffTransportOutcome {
        let outcome = try await SubprocessRunner.run(
            executable: URL(fileURLWithPath: argv[0]),
            arguments: Array(argv.dropFirst()),
            // Explicit minimal env (C3 hygiene). HOME for ssh's known_hosts /
            // config resolution.
            environment: ["HOME": NSHomeDirectory()],
            stdin: payload,
            timeout: timeout
        )
        return HandoffTransportOutcome(
            exitStatus: outcome.exitStatus,
            stderrTail: outcome.stderrTail,
            timedOut: outcome.timedOut,
            cancelled: outcome.cancelled
        )
    }
}

// MARK: - Reachability probe (TCP port 22; ICMP is firewalled on the remote host)

public protocol HandoffProbing: Sendable {
    func probe(host: String, port: UInt16, timeout: TimeInterval) async -> Bool
}

/// `NWConnection` to the port with a deadline — no subprocess, no ICMP.
public struct TCPPortProber: HandoffProbing {
    public init() {}

    public func probe(host: String, port: UInt16, timeout: TimeInterval) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let resumed = Mutex(false)
        return await withCheckedContinuation { continuation in
            @Sendable func finish(_ reachable: Bool) {
                let first = resumed.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                guard first else { return }
                connection.cancel()
                continuation.resume(returning: reachable)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed: finish(false)
                default: break
                }
            }
            connection.start(queue: DispatchQueue.global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                finish(false)
            }
        }
    }
}
