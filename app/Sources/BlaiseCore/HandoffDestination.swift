import Foundation

/// Where finished meetings are delivered (G5 / D19). ONE destination active at
/// a time (V1.2; multi-destination fan-out is BACKLOG). Both destinations reuse
/// the ENTIRE queue machinery — states, retries, supersession, the D21 warning
/// episodes, Retry Now — differing only in WHERE the (byte-identical) payload
/// lands:
///
/// - `.ssh` — the existing this Mac→the remote host OpenSSH path, unchanged semantics
///   incl. the per-host circuit breakers and verify-before-rename remote
///   command. This is the migration target for existing installs (§2).
/// - `.localFolder` — a local directory (Obsidian vault, any agentic
///   consumer) reached with no SSH, no host: the same inbox layout
///   (`<root>/<meeting-ulid>/<hash>.json`), the same verify-before-rename
///   contract, plus an optional human-facing Markdown sidecar.
public enum HandoffDestination: Sendable, Equatable {
    case ssh(HandoffSettings, markdownSidecar: Bool)
    case localFolder(url: URL, markdownSidecar: Bool)

    /// Discriminator persisted under `handoff.destination`; absent ⇒ `.ssh`
    /// (the migration default — existing installs keep delivering to the remote host
    /// with zero behavior change).
    public enum Kind: String, Codable, Sendable {
        case ssh
        case localFolder
    }

    public enum Key {
        /// `handoff.destination` — the active-destination discriminator.
        public static let kind = "handoff.destination"
        /// Base64 security-scoped bookmark data for the chosen folder. Survives
        /// folder moves (sandbox-correct even though the app is not sandboxed
        /// today) — the resolved URL, not a stored path string, is the source
        /// of truth for the local destination.
        public static let localBookmark = "handoff.localFolder.bookmark"
        /// Display-only folder path (the Settings label). Never used to deliver
        /// — the bookmark resolves the real URL.
        public static let localPath = "handoff.localFolder.path"
        /// Markdown sidecar toggle; absent ⇒ ON. Destination-independent (G6):
        /// both `.ssh` (uploads the `.md` alongside the JSON) and `.localFolder`
        /// (writes it next to the JSON) read this single key. The key name is
        /// kept (`…localFolder.markdownSidecar`) so existing installs migrate
        /// with no settings loss.
        public static let localMarkdownSidecar = "handoff.localFolder.markdownSidecar"
        /// Superseded-payload REMOVAL at the destination (G5 v1.3);
        /// destination-independent. Absent ⇒ OFF ⇒ delivered payloads
        /// ACCUMULATE, preserving the published "older versions are not
        /// deleted" contract. `true` opts IN: after a delivery + D12
        /// supersession this meeting's OTHER `<hash>.json` at the destination
        /// are removed, so the destination holds exactly ONE current payload
        /// per meeting.
        ///
        /// Default-OFF is deliberate and operator-ratified (24/07/2026). The
        /// asymmetry decides it: an accumulating destination is trivially
        /// tidied later, while deleted evidence cannot be recovered — and the
        /// primary consumer is an Evidence Store whose defining property is
        /// immutability, with downstream claims CITING the files by hash. A
        /// destructive default would also have changed behaviour silently for
        /// every existing install on upgrade, with nobody opting in.
        public static let removeSupersededPayloads = "handoff.removeSupersededPayloads"
        /// Audio delivery (G5 v1.3); destination-independent. Absent ⇒ OFF (the
        /// privacy default). `true` copies the meeting's retained `audio*.m4a`
        /// set into the destination meeting dir after the sidecar — a syncing
        /// destination (iCloud/network) then means audio leaves the machine. The
        /// payload bytes are unchanged (no audio field).
        public static let deliverAudio = "handoff.deliverAudio"
        /// G5 v1.6: the destination INSTANCE counter (absent ⇒ 0). Bumped on
        /// every destination change — kind switch, folder re-pick, SSH settings
        /// edit — and stamped into `delivered_endpoint` through
        /// `endpointIdentity(epoch:)`. Monotonic: it only ever counts up, so a
        /// row from a previous instance can never match the active one again.
        public static let destinationEpoch = "handoff.destinationEpoch"
    }

    /// The active destination epoch: `0` when the key is ABSENT (never bumped),
    /// `nil` when the settings read FAILED. The distinction is load-bearing
    /// (R4-F1): a failed read spelled `0` is the value that MAXIMALLY matches
    /// historical rows, so it re-arms deletion authority for the epoch-0
    /// instance. `nil` means "no authority is derivable this drain" — the
    /// worker skips cleanup, and `bumpEpoch` declines to count down over a
    /// value it could not read.
    public static func epoch(from store: SettingsStore) async -> Int? {
        do { return try await store.get(Key.destinationEpoch, as: Int.self) ?? 0 } catch {
            return nil
        }
    }

    /// Records that the destination changed: the next delivery stamps a new
    /// identity, and every row stamped before this call stops authorizing
    /// deletion. Called from the Settings model on a kind switch, a folder
    /// re-pick, or an SSH settings edit. An unreadable current value is left
    /// alone — writing `1` over an unread higher epoch would resurrect the
    /// authority this call exists to retire.
    public static func bumpEpoch(in store: SettingsStore) async {
        guard let current = await epoch(from: store) else { return }
        try? await store.set(Key.destinationEpoch, to: current + 1)
    }

    /// The destination-INSTANCE identity stamped on every delivered row and
    /// required to match before a payload here may be deleted (G5 v1.6). Two
    /// components, both load-bearing:
    ///
    /// - the destination EPOCH: what makes a REPLACED destination a different
    ///   instance even when its configuration is spelled identically — the
    ///   volume swapped at the same mount point, the re-provisioned host at the
    ///   same address. Rows stamped under a previous epoch never match again.
    /// - the destination CONFIGURATION, deliberately NOT the host that answered
    ///   (`handoff.hosts` is an ordered list of routes to ONE machine — C8 — so
    ///   a Tailscale→LAN failover must not read as a destination switch). For a
    ///   local folder it is the resolved RESOURCE identity (volume UUID + file
    ///   id), not the path: the security-scoped bookmark exists so a folder MOVE
    ///   keeps delivering, and the resource id follows the same folder, while a
    ///   different volume mounted at the same path reads as what it is —
    ///   somebody else's store. Unresolvable ⇒ empty, and the epoch alone
    ///   carries the instance distinction.
    ///
    /// Every mismatch fails toward UNDER-deletion: a row whose identity is not
    /// exactly this string is left alone.
    public func endpointIdentity(epoch: Int) -> String {
        switch self {
        case .ssh(let settings, _):
            return "e\(epoch):ssh:\(settings.user)@\(settings.hosts.joined(separator: ","))"
                + ":\(settings.remoteRoot)"
        case .localFolder(let url, _):
            return "e\(epoch):local:\(Self.localResourceIdentity(of: url))"
        }
    }

    /// Volume UUID + file id of the chosen folder — the pair that survives a
    /// move and distinguishes a replacement resource at the same path. Empty
    /// when the file system does not answer (an unplugged volume, a file system
    /// with no persistent UUID); the epoch then carries the distinction alone.
    static func localResourceIdentity(of url: URL) -> String {
        // Same security-scope discipline the worker uses around every other
        // access to this URL; balanced immediately.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let values = try? url.resourceValues(
            forKeys: [.volumeUUIDStringKey, .fileIdentifierKey]),
            let volume = values.volumeUUIDString, let fileID = values.fileIdentifier
        else { return "" }
        return "\(volume)/\(fileID)"
    }

    /// Destination-independent (G5 v1.3): whether to REMOVE superseded payloads
    /// at the destination. Absent ⇒ false ⇒ payloads accumulate (the default;
    /// removal is the opt-in).
    public static func removeSupersededPayloads(from store: SettingsStore) async -> Bool {
        (try? await store.get(Key.removeSupersededPayloads, as: Bool.self)) ?? nil ?? false
    }

    /// Destination-independent (G5 v1.3): whether to deliver retained audio.
    /// Absent ⇒ false ⇒ OFF (the privacy default).
    public static func deliverAudio(from store: SettingsStore) async -> Bool {
        (try? await store.get(Key.deliverAudio, as: Bool.self)) ?? nil ?? false
    }

    public var kind: Kind {
        switch self {
        case .ssh: return .ssh
        case .localFolder: return .localFolder
        }
    }

    // MARK: - Resolution from settings

    /// Resolution failure for the local destination (the SSH path has no
    /// resolution step — its keys load with shipped defaults). The two cases
    /// are handled DIFFERENTLY by the worker, matching spec §1:
    ///
    /// - `missingBookmark` (no folder ever chosen) pauses delivery LOUDLY as
    ///   `configurationInvalid` — the user must pick a folder; nothing is lost,
    ///   items stay pending.
    /// - `unresolvableBookmark` (a previously-chosen folder that is deleted or
    ///   on an unplugged drive) behaves like the remote host-offline: a folder-shaped
    ///   TRANSIENT failure with silent retry and an eventual staleness banner,
    ///   NOT a loud config pause.
    public enum ResolutionError: Error, Equatable, CustomStringConvertible {
        case missingBookmark
        case unresolvableBookmark(String)

        public var description: String {
            switch self {
            case .missingBookmark:
                return "local folder destination has no saved folder — choose one in Settings"
            case .unresolvableBookmark(let detail):
                return "local folder bookmark could not be resolved: \(detail)"
            }
        }
    }

    /// Resolves the active destination from the settings store. `.ssh` is the
    /// default (absent discriminator) AND the fallback shape every SSH key
    /// loads with shipped defaults. `.localFolder` resolves its security-scoped
    /// bookmark to a live URL; a missing/unresolvable bookmark throws
    /// `ResolutionError`, which the worker surfaces as `configurationInvalid`.
    public static func load(from store: SettingsStore) async throws -> HandoffDestination {
        let kind = (try? await store.get(Key.kind, as: Kind.self)) ?? nil ?? .ssh
        // Destination-independent (G6): both destinations read the single
        // sidecar toggle; absent ⇒ ON.
        let sidecar = (try? await store.get(Key.localMarkdownSidecar, as: Bool.self)) ?? nil ?? true
        switch kind {
        case .ssh:
            return .ssh(await HandoffSettings.load(from: store), markdownSidecar: sidecar)
        case .localFolder:
            guard let base64 = (try? await store.get(Key.localBookmark, as: String.self)) ?? nil,
                let data = Data(base64Encoded: base64)
            else { throw ResolutionError.missingBookmark }
            do {
                var stale = false
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale)
                return .localFolder(url: url, markdownSidecar: sidecar)
            } catch {
                throw ResolutionError.unresolvableBookmark(String(describing: error))
            }
        }
    }
}
