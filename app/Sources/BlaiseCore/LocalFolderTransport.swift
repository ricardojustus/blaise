import CryptoKit
import Foundation
import os

// MARK: - Local crash hook (kill between local tmp-write and rename, AC2)

/// `BLAISE_CRASH_AT=handoff-local-mid-write`: SIGKILLs the app between the
/// local `.tmp-*` write and the atomic rename. The exactly-once contract is
/// the same as the SSH mid-transfer kill — only a `.tmp-*` is ever visible,
/// never a partial `<hash>.json`; relaunch redelivers.
enum LocalFolderCrashHooks {
    static func maybeKillBeforeRename() {
        guard ProcessInfo.processInfo.environment["BLAISE_CRASH_AT"] == "handoff-local-mid-write"
        else { return }
        kill(getpid(), SIGKILL)
        while true { usleep(1_000) }
    }
}

// MARK: - LocalFolderTransport

/// Delivers a payload to a LOCAL directory with the SAME verify-before-rename
/// contract and inbox layout as the SSH transport — no host, no SSH. The
/// worker drives it through `HandoffTransporting`, so the queue states,
/// retries, supersession, D21 warning episodes and Retry Now are reused
/// unchanged; folder errors are mapped onto the existing `HandoffFailureClass`
/// taxonomy.
///
/// Layout (identical to docs/handoff.md, local variant):
///
///     <root>/<meeting-ulid>/.tmp-<hash>-<nonce>   transient (dot-prefixed)
///     <root>/<meeting-ulid>/<hash>.json           visible only after verify
///
/// Steps: (1) write the payload to `.tmp-<hash>-<nonce>`; (2) re-READ the temp
/// and SHA-256 it — a write that did not land byte-identically (the read-back
/// seam) yields exit 65 (transfer corruption, retriable); (3) atomic-rename to
/// `<hash>.json` ONLY on match. A `<hash>.json` is never partial or corrupt.
public struct LocalFolderTransport: HandoffTransporting {
    /// The resolved destination root (a security-scoped URL the worker has
    /// already `startAccessingSecurityScopedResource()`-opened, or a plain
    /// /tmp URL in tests).
    let root: URL
    /// The verify-before-rename read SOURCE (M-4). In production this is nil and
    /// the verify re-OPENS the just-written temp FROM DISK (`Data(contentsOf:)`)
    /// — the local analogue of the remote `shasum`, which proves the bytes
    /// actually landed. Tests inject this `(URL) -> Data` seam to model a write
    /// that did not land byte-identically (corrupt-on-write). Because the seam
    /// takes the temp URL and is the ONLY read source, a refactor that verified
    /// the IN-MEMORY `payload` instead of re-opening the file would change this
    /// signature and fail the disk-source pin — the in-memory tautology the
    /// auditor flagged can no longer pass silently.
    let readBackHook: (@Sendable (URL) throws -> Data)?
    /// Test-only filesystem fault injector (M-4 mutant check). Runs AFTER the
    /// temp is written and BEFORE the verify read, with the temp URL — a test
    /// uses it to corrupt the bytes ON DISK. An honest disk read-back catches
    /// the corruption (exit 65, no visible file); an in-memory verify would
    /// NOT, so this is the mutant that kills `readBack = payload`. nil in
    /// production.
    let afterWriteHook: (@Sendable (URL) -> Void)?
    /// Test-only fault injector for the M-1 atomicity pin. Runs AFTER the verify
    /// passes and BEFORE the rename into visibility, with the temp URL. A test
    /// deletes the temp here so the rename FAILS: under an atomic `rename(2)` the
    /// existing `<hash>.json` is untouched (never absent); under the old
    /// remove-then-move shape `removeItem(final)` has already deleted the visible
    /// file and the failed move leaves NONE — which the pin catches. nil in
    /// production.
    let beforeRenameHook: (@Sendable (URL) -> Void)?

    public init(
        root: URL,
        readBackHook: (@Sendable (URL) throws -> Data)? = nil,
        afterWriteHook: (@Sendable (URL) -> Void)? = nil,
        beforeRenameHook: (@Sendable (URL) -> Void)? = nil
    ) {
        self.root = root
        self.readBackHook = readBackHook
        self.afterWriteHook = afterWriteHook
        self.beforeRenameHook = beforeRenameHook
    }

    private static let logger = Logger(subsystem: BlaiseBundle.identifier, category: "handoff.local")

    /// `argv` carries [meetingID, hash, nonce] (the worker builds it through
    /// `LocalFolderCommand` — no shell, no injection surface; the values are
    /// already validated by `selfCheck`). `payload` is the verified bytes.
    public func deliver(argv: [String], payload: Data, timeout: TimeInterval) async throws
        -> HandoffTransportOutcome
    {
        let meetingID = argv[0]
        let hash = argv[1]
        let nonce = argv[2]
        let dir = root.appendingPathComponent(meetingID, isDirectory: true)
        let temp = dir.appendingPathComponent(".tmp-\(hash)-\(nonce)")
        let final = dir.appendingPathComponent("\(hash).json")
        let fm = FileManager.default

        // The destination ROOT must already exist: if the chosen folder was
        // deleted or its volume unplugged, fail (silent retry → 1-hour
        // staleness banner) rather than silently recreating it somewhere new.
        // The per-meeting subdir IS ours to create under a live root.
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return HandoffTransportOutcome(
                exitStatus: nil,
                stderrTail: "local destination folder is missing or unavailable",
                timedOut: false, localFolder: true)
        }

        do {
            // Stale-temp hygiene (the local mirror of the remote `find -delete`):
            // clear `.tmp-*` older than a day so an orphaned post-crash temp is
            // not kept forever. Best-effort; never fails the delivery.
            sweepStaleTemps(in: dir)

            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            // Write the temp (overwrite any same-nonce orphan — the nonce is
            // per-attempt, so this only collides with a re-run of THIS attempt).
            try payload.write(to: temp, options: .atomic)

            // M-4 fault-injection point: tests may corrupt the temp ON DISK here
            // to prove the verify re-reads the file rather than the in-memory
            // payload. No-op in production.
            afterWriteHook?(temp)

            // Verify-before-rename (M-4): re-OPEN the temp FROM DISK and hash
            // it — the local `shasum`. `readBackHook` (nil in production) is the
            // injected read source modeling a write that did not land
            // byte-identically; production always reads the URL.
            let readBack = try (readBackHook ?? { try Data(contentsOf: $0) })(temp)
            let actual = SHA256.hash(data: readBack).map { String(format: "%02x", $0) }.joined()
            guard actual == hash else {
                try? fm.removeItem(at: temp)
                return HandoffTransportOutcome(
                    exitStatus: 65,
                    stderrTail: "local verify mismatch: wrote \(payload.count) bytes, read-back hash \(actual)",
                    timedOut: false)
            }

            LocalFolderCrashHooks.maybeKillBeforeRename()

            // M-1 fault-injection point: tests delete the temp here to force the
            // rename to fail and prove the existing <hash>.json survives. No-op
            // in production.
            beforeRenameHook?(temp)

            // Atomic rename into visibility (M-1). `rename(2)` REPLACES an
            // existing `<hash>.json` in a single syscall, so an already-visible
            // delivery is never momentarily absent — the SSH path's `mv -f`
            // analogue, not a remove-then-move that opens an ENOENT window and
            // can leave only a `.tmp-*` if a crash lands inside it. Same volume
            // (temp and final share `dir`), so the rename is atomic on
            // APFS/HFS+ (see the local-volume caveat in the contract doc).
            try Self.atomicReplace(temp: temp, final: final)
            return HandoffTransportOutcome(exitStatus: 0, stderrTail: "", timedOut: false)
        } catch {
            try? fm.removeItem(at: temp)
            return HandoffTransportOutcome(
                exitStatus: nil,
                stderrTail: Self.classifyStderr(error),
                timedOut: false, localFolder: true)
        }
    }

    /// Maps a filesystem error to a stderr-shaped string the EXISTING
    /// `HandoffFailureClass.classify` taxonomy understands: `No space left`
    /// → `.remoteDisk` (15-min floor); everything else (folder missing,
    /// permission denied, volume unplugged) → `.transient` (silent retry,
    /// eventual 1-hour staleness banner — an unplugged external drive behaves
    /// exactly like the remote host-offline).
    ///
    /// Every string carries the `local ` marker (M-3): the warning's
    /// `shortReason` keys off it to name the LOCAL DESTINATION ("destination
    /// disk full" / "destination folder unavailable") rather than "the remote host",
    /// which would be wrong — a local-folder install may have no the remote host at all.
    static func classifyStderr(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain || ns.domain == NSPOSIXErrorDomain {
            if ns.code == ENOSPC || underlyingPOSIX(ns) == ENOSPC {
                return "local destination: No space left on device"
            }
        }
        return "local folder error: \(ns.domain)#\(ns.code) \(ns.localizedDescription)"
    }

    private static func underlyingPOSIX(_ ns: NSError) -> Int32? {
        guard let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
            underlying.domain == NSPOSIXErrorDomain
        else { return nil }
        return Int32(underlying.code)
    }

    /// Atomically move `temp` onto `final` (M-1). POSIX `rename(2)` on a single
    /// volume replaces an existing destination in one syscall — a reader doing
    /// readdir/open on `<hash>.json` either sees the old bytes or the new, never
    /// nothing. (The bytes are content-addressed by `final`'s name, so old and
    /// new are byte-identical on a redelivery anyway; what matters is that the
    /// visible file is NEVER absent and a crash can never leave only a `.tmp-*`
    /// where a JSON used to be.) Replaces the prior `removeItem`-then-`moveItem`
    /// shape, whose two-syscall window is exactly that hazard.
    static func atomicReplace(temp: URL, final: URL) throws {
        let rc = temp.withUnsafeFileSystemRepresentation { tempPath in
            final.withUnsafeFileSystemRepresentation { finalPath in
                rename(tempPath, finalPath)
            }
        }
        if rc != 0 {
            throw NSError(
                domain: NSPOSIXErrorDomain, code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
        }
    }

    private func sweepStaleTemps(in dir: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        for url in entries where url.lastPathComponent.hasPrefix(".tmp-") {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, modified < cutoff { try? fm.removeItem(at: url) }
        }
    }
}

// MARK: - Local command construction (no shell — argv is data, not a command)

/// Mirrors `HandoffCommand` so the worker's per-item code is symmetric, but
/// there is NO shell here: the "argv" is just [meetingID, hash, nonce] handed
/// to `LocalFolderTransport`, which uses FileManager. There is no injection
/// surface — values are validated by the worker's pre-stream self-check.
public enum LocalFolderCommand {
    public static func argv(meetingID: String, hash: String, nonce: String) -> [String] {
        [meetingID, hash, nonce]
    }
}
