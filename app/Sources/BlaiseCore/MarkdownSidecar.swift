import Foundation
import os

/// The human-facing Markdown sidecar written next to a local-folder JSON
/// delivery (G5 §1, default ON for local folders): an Obsidian-ready note with
/// YAML frontmatter plus the already-rendered notes markdown.
///
/// Contract:
/// - `<root>/<meeting-ulid>/<slug(title)>.md`, ONE current sidecar per meeting
///   (supersession OVERWRITES it; the JSONs remain the immutable history).
/// - Frontmatter: `title`, `started_at` (ISO 8601), `attendees` (names),
///   `source: blaise`, `native_id`, `version_hash`.
/// - Slug collisions across DISTINCT meetings sharing one folder get a
///   ULID-suffix so two meetings never overwrite each other's sidecar.
/// - Sidecar write failure is ISOLATED from the JSON delivery (the JSON is the
///   contract; the sidecar is convenience): the worker logs and retries the
///   sidecar on the meeting's next delivery, never failing the queue item.
///
/// The same machinery writes the OPT-IN transcript sidecar (`kind: .transcript`,
/// local destination only): `<slug>-transcript.md`, body rendered by
/// `TranscriptCopyText`, a `kind: transcript` frontmatter line and no
/// `version_hash` (its provenance is the transcript rows, not the payload). The
/// kinds are independent files and never delete each other.
public enum MarkdownSidecar {
    private static let logger = Logger(subsystem: BlaiseBundle.identifier, category: "handoff.sidecar")

    /// Which sidecar this is. `.notes` renders exactly as it always has (no
    /// `kind:` line) so existing sidecars stay byte-identical.
    public enum Kind: Sendable, Equatable {
        case notes
        case transcript

        /// File-name suffix before `.md`, so the two kinds are siblings.
        var nameSuffix: String { self == .transcript ? "-transcript" : "" }
    }

    public struct Fields: Sendable, Equatable {
        public var meetingID: String
        public var title: String
        public var startedAt: Date
        public var attendeeNames: [String]
        public var versionHash: String
        /// The rendered body: the notes markdown for `.notes`, the
        /// `TranscriptCopyText` render for `.transcript`.
        public var bodyMarkdown: String
        public var kind: Kind

        public init(
            meetingID: String, title: String, startedAt: Date, attendeeNames: [String],
            versionHash: String, bodyMarkdown: String, kind: Kind = .notes
        ) {
            self.meetingID = meetingID
            self.title = title
            self.startedAt = startedAt
            self.attendeeNames = attendeeNames
            self.versionHash = versionHash
            self.bodyMarkdown = bodyMarkdown
            self.kind = kind
        }
    }

    /// Writes (overwriting) the meeting's current sidecar in `meetingDir`.
    /// `existingSidecars` lists the `.md` file names already present in the
    /// SAME folder belonging to OTHER meetings — used only for collision
    /// detection. Returns the file name written, or nil on failure (logged;
    /// never throws — delivery is never failed by the sidecar).
    @discardableResult
    public static func write(_ fields: Fields, to meetingDir: URL) -> String? {
        let document = render(fields)
        let name = fileName(for: fields, in: meetingDir)
        let url = meetingDir.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(
                at: meetingDir, withIntermediateDirectories: true)
            // Remove any prior sidecar of THIS KIND for THIS meeting (a re-slug
            // on a renamed title, or a prior delivery) so exactly one current
            // sidecar per kind remains — supersession overwrites. Kind-aware, so
            // the notes and transcript sidecars never delete each other.
            removePriorSidecars(
                for: fields.meetingID, kind: fields.kind, in: meetingDir, keeping: name)
            try Data(document.utf8).write(to: url, options: .atomic)
            return name
        } catch {
            logger.warning(
                "sidecar write failed for \(fields.meetingID, privacy: .public): \(String(describing: error), privacy: .public) — JSON already delivered; retried on next delivery"
            )
            return nil
        }
    }

    // MARK: - Rendering

    static func render(_ fields: Fields) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var lines = ["---"]
        lines.append("title: \(yamlScalar(fields.title))")
        lines.append("started_at: \(iso.string(from: fields.startedAt))")
        if fields.attendeeNames.isEmpty {
            lines.append("attendees: []")
        } else {
            lines.append("attendees:")
            for name in fields.attendeeNames { lines.append("  - \(yamlScalar(name))") }
        }
        lines.append("source: blaise")
        lines.append("native_id: \(fields.meetingID)")
        // The transcript's provenance is the persisted transcript rows, not the
        // payload — stamping the payload hash would claim a version the rows may
        // postdate (a regeneration that failed to re-mint). Notes: unchanged.
        if fields.kind == .transcript {
            lines.append("kind: transcript")
        } else {
            lines.append("version_hash: \(fields.versionHash)")
        }
        lines.append("---")
        lines.append("")
        // The rendered body verbatim (single trailing newline).
        var body = fields.bodyMarkdown
        if !body.hasSuffix("\n") { body += "\n" }
        return lines.joined(separator: "\n") + "\n" + body
    }

    /// Quote a YAML scalar only when needed (leading/trailing space, or a
    /// character that would otherwise change YAML meaning), escaping `"` and
    /// `\`. Plain titles stay unquoted and human-readable.
    static func yamlScalar(_ value: String) -> String {
        // Flatten newlines FIRST: a title or attendee name carrying one would
        // otherwise inject arbitrary frontmatter lines (including `kind:`).
        let value = value.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let needsQuote =
            value.isEmpty
            || value.first == " " || value.last == " "
            || value.contains(where: { ":#[]{}&*!|>'\"%@`".contains($0) })
            || value.first == "-"
        guard needsQuote else { return value }
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    // MARK: - Slug + collisions

    /// Crockford-ish slug: lowercase, ASCII-fold, non-alphanumerics → `-`,
    /// collapsed, trimmed. Empty (e.g. an all-emoji title) falls back to
    /// `meeting`.
    static func slug(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive], locale: nil)
        var out = ""
        var lastDash = false
        for scalar in folded.lowercased().unicodeScalars {
            if (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57) {
                out.unicodeScalars.append(scalar)
                lastDash = false
            } else if !lastDash {
                out.append("-")
                lastDash = true
            }
        }
        while out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "meeting" : out
    }

    /// The sidecar file name. Base `<slug>.md` (`<slug>-transcript.md` for the
    /// transcript kind); on collision with ANOTHER meeting's sidecar already in
    /// the folder, suffix this meeting's ULID (`<slug>-<ulid>.md`) so the two
    /// never overwrite each other.
    static func fileName(for fields: Fields, in meetingDir: URL) -> String {
        let base = slug(fields.title) + fields.kind.nameSuffix
        let baseName = "\(base).md"
        let fm = FileManager.default
        let existing = (try? fm.contentsOfDirectory(atPath: meetingDir.path)) ?? []
        // A collision is a base-name `.md` that belongs to a DIFFERENT meeting.
        // Our own prior sidecar (same slug) is an overwrite, not a collision.
        let collides = existing.contains(baseName)
            && !ours(baseName, meetingID: fields.meetingID, kind: fields.kind, in: meetingDir)
        return collides ? "\(base)-\(fields.meetingID).md" : baseName
    }

    /// Whether a `.md` file in the folder is THIS meeting's sidecar OF THIS KIND
    /// (its frontmatter `native_id` matches and its `kind:` line agrees). Used so
    /// a same-title re-delivery overwrites rather than mints a ULID-suffixed
    /// twin — and so neither kind ever claims the other's file.
    private static func ours(_ name: String, meetingID: String, kind: Kind, in dir: URL) -> Bool {
        guard let text = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
        else { return false }
        // Classify from the FRONTMATTER ONLY (everything before the closing
        // `---`): a BODY line reading `kind: transcript` — a note quoting this
        // very format — must never flip a file's kind or its ownership. No
        // closing delimiter ⇒ no frontmatter ⇒ not ours. Nor does a file that
        // never OPENS with `---`: its leading body is not a header.
        let parts = text.components(separatedBy: "\n---\n")
        guard text.hasPrefix("---\n"), parts.count > 1 else { return false }
        let header = parts[0] + "\n"
        let isTranscript = header.contains("\nkind: transcript\n")
        return header.contains("\nnative_id: \(meetingID)\n") && isTranscript == (kind == .transcript)
    }

    private static func removePriorSidecars(
        for meetingID: String, kind: Kind, in dir: URL, keeping: String
    ) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        for name in entries where name.hasSuffix(".md") && name != keeping {
            if ours(name, meetingID: meetingID, kind: kind, in: dir) {
                try? fm.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }
}
