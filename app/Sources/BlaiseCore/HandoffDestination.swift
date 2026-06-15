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
