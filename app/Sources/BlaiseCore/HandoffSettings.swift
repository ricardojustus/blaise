import Foundation

/// Endpoint configuration for the SSH handoff to the Evidence Store
/// (Settings keys `handoff.*`; the destination is configured at runtime,
/// C8 spec).
///
/// **Injection safety is borne ENTIRELY by `validate()`** — the remote
/// command string interpolates these values inside single quotes and the
/// remote login shell re-parses it, so values failing validation must never
/// reach command construction. A validation failure pauses the WORKER
/// (`configurationInvalid`, items stay `pending`); it is never `damaged`.
public struct HandoffSettings: Sendable, Equatable {
    public enum Key {
        public static let user = "handoff.user"
        public static let identityFile = "handoff.identityFile"
        public static let hosts = "handoff.hosts"
        public static let remoteRoot = "handoff.remoteRoot"
    }

    public var user: String
    public var identityFile: String
    /// Ordered: each wake the TCP probe tries hosts in order and the first
    /// that answers port 22 within 2 s is used for the cycle. A two-host
    /// list (e.g. a Tailscale host first to avoid the macOS Local Network
    /// prompt, a LAN host second) is the typical configuration.
    public var hosts: [String]
    public var remoteRoot: String

    /// Empty by default: the SSH handoff is Settings-configured on first run
    /// (host(s), user, remote root, identity file), matching the empty
    /// user-identity and user-stoplist defaults. With no hosts the worker
    /// pauses `configurationInvalid` and items stay `pending` until the user
    /// configures a destination — the queue-and-retry seam is intact; only
    /// the compiled-in default is empty.
    public static let shippedDefault = HandoffSettings(
        user: "",
        identityFile: "~/.ssh/id_ed25519",
        hosts: [],
        remoteRoot: ""
    )

    public init(user: String, identityFile: String, hosts: [String], remoteRoot: String) {
        self.user = user
        self.identityFile = identityFile
        self.hosts = hosts
        self.remoteRoot = Self.normalizedRemoteRoot(remoteRoot)
    }

    /// A user-entered root may carry a trailing `/` (the validator's charset
    /// allows it); strip it here so `remoteRoot + "/" + meetingID` never
    /// contains `//`.
    static func normalizedRemoteRoot(_ value: String) -> String {
        var value = value
        while value.count > 1, value.hasSuffix("/") { value.removeLast() }
        return value
    }

    /// Per-key load with shipped defaults for absent keys.
    public static func load(from store: SettingsStore) async -> HandoffSettings {
        let defaults = HandoffSettings.shippedDefault
        return HandoffSettings(
            user: (try? await store.get(Key.user, as: String.self)) ?? nil ?? defaults.user,
            identityFile: (try? await store.get(Key.identityFile, as: String.self)) ?? nil
                ?? defaults.identityFile,
            hosts: (try? await store.get(Key.hosts, as: [String].self)) ?? nil ?? defaults.hosts,
            remoteRoot: (try? await store.get(Key.remoteRoot, as: String.self)) ?? nil
                ?? defaults.remoteRoot
        )
    }

    // MARK: - Validation (the ENTIRE injection defense — stated plainly)

    public enum ValidationError: Error, Equatable, CustomStringConvertible {
        case invalidUser(String)
        case invalidHost(String)
        case invalidRemoteRoot(String)
        case noHosts

        public var description: String {
            switch self {
            case .invalidUser(let value): return "handoff.user invalid: \(value)"
            case .invalidHost(let value): return "handoff.hosts entry invalid: \(value)"
            case .invalidRemoteRoot(let value): return "handoff.remoteRoot invalid: \(value)"
            case .noHosts: return "handoff.hosts is empty"
            }
        }
    }

    /// `^[a-z_][a-z0-9_-]*$`
    public static func isValidUser(_ value: String) -> Bool {
        value.wholeMatch(of: /[a-z_][a-z0-9_-]*/) != nil
    }

    /// `^[A-Za-z0-9.\-]+$` AND not starting with `-` — a leading-dash value
    /// in the `user@host` argv slot is OpenSSH option injection
    /// (`-oProxyCommand=` runs local code).
    public static func isValidHost(_ value: String) -> Bool {
        !value.hasPrefix("-") && value.wholeMatch(of: /[A-Za-z0-9.\-]+/) != nil
    }

    /// `^/[A-Za-z0-9_][A-Za-z0-9/_.\-]*$`, no `..` path segment, no `'`,
    /// no run of `//`.
    public static func isValidRemoteRoot(_ value: String) -> Bool {
        guard value.wholeMatch(of: #//[A-Za-z0-9_][A-Za-z0-9/_.\-]*/#) != nil else { return false }
        guard !value.contains("'"), !value.contains("//") else { return false }
        return !value.split(separator: "/").contains("..")
    }

    public func validate() throws(ValidationError) {
        guard Self.isValidUser(user) else { throw .invalidUser(user) }
        guard !hosts.isEmpty else { throw .noHosts }
        for host in hosts where !Self.isValidHost(host) {
            throw .invalidHost(host)
        }
        guard Self.isValidRemoteRoot(remoteRoot) else { throw .invalidRemoteRoot(remoteRoot) }
    }
}
