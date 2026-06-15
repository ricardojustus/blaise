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
public enum MarkdownSidecar {
    private static let logger = Logger(subsystem: BlaiseBundle.identifier, category: "handoff.sidecar")

    public struct Fields: Sendable, Equatable {
        public var meetingID: String
        public var title: String
        public var startedAt: Date
        public var attendeeNames: [String]
        public var versionHash: String
        public var notesMarkdown: String

        public init(
            meetingID: String, title: String, startedAt: Date, attendeeNames: [String],
            versionHash: String, notesMarkdown: String
        ) {
            self.meetingID = meetingID
            self.title = title
            self.startedAt = startedAt
            self.attendeeNames = attendeeNames
            self.versionHash = versionHash
            self.notesMarkdown = notesMarkdown
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
            // Remove any prior sidecar for THIS meeting (a re-slug on a renamed
            // title, or a prior delivery) so exactly one current sidecar
            // remains — supersession overwrites.
            removePriorSidecars(for: fields.meetingID, in: meetingDir, keeping: name)
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
        lines.append("version_hash: \(fields.versionHash)")
        lines.append("---")
        lines.append("")
        // The rendered notes markdown verbatim (single trailing newline).
        var body = fields.notesMarkdown
        if !body.hasSuffix("\n") { body += "\n" }
        return lines.joined(separator: "\n") + "\n" + body
    }

    /// Quote a YAML scalar only when needed (leading/trailing space, or a
    /// character that would otherwise change YAML meaning), escaping `"` and
    /// `\`. Plain titles stay unquoted and human-readable.
    static func yamlScalar(_ value: String) -> String {
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

    /// The sidecar file name. Base `<slug>.md`; on collision with ANOTHER
    /// meeting's sidecar already in the folder, suffix this meeting's ULID
    /// (`<slug>-<ulid>.md`) so the two never overwrite each other.
    static func fileName(for fields: Fields, in meetingDir: URL) -> String {
        let base = slug(fields.title)
        let baseName = "\(base).md"
        let fm = FileManager.default
        let existing = (try? fm.contentsOfDirectory(atPath: meetingDir.path)) ?? []
        // A collision is a base-name `.md` that belongs to a DIFFERENT meeting.
        // Our own prior sidecar (same slug) is an overwrite, not a collision.
        let collides = existing.contains(baseName)
            && !ours(baseName, meetingID: fields.meetingID, in: meetingDir)
        return collides ? "\(base)-\(fields.meetingID).md" : baseName
    }

    /// Whether a `.md` file in the folder is THIS meeting's sidecar (its
    /// frontmatter `native_id` matches). Used so a same-title re-delivery
    /// overwrites rather than mints a ULID-suffixed twin.
    private static func ours(_ name: String, meetingID: String, in dir: URL) -> Bool {
        guard let text = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
        else { return false }
        return text.contains("native_id: \(meetingID)\n")
    }

    private static func removePriorSidecars(for meetingID: String, in dir: URL, keeping: String) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        for name in entries where name.hasSuffix(".md") && name != keeping {
            if ours(name, meetingID: meetingID, in: dir) {
                try? fm.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }
}
