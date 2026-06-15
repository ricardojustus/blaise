import Foundation

// G1 — user glossary parser + region extraction (spec §2, §5b).
//
// The user glossary (`<dataRoot>/Glossary.md`) is UNTRUSTED markdown. Only the
// region between the first `## Entries` line and the next `## ` line (or EOF)
// is parsed. In-region handling is a wrapper over the C5 grammar with deliberate
// amendments (bullet strip, markdown-artifact skip, field-wise empty-alias drop,
// size cap). The file is never modified by parsing — see `GlossaryEditor` (§6)
// for the only programmatic writer besides launch provisioning (§4).

/// One diagnostic item: an absolute (1-based) source line number, a ≤40-char
/// prefix of the offending line, and a typed reason. Line-level reasons carry
/// no line number duplication here — the number is the item's own field.
public struct GlossaryDiagnosticItem: Sendable, Equatable {
    public let line: Int
    public let prefix: String
    public let reason: GlossaryDiagnosticReason

    public init(line: Int, prefix: String, reason: GlossaryDiagnosticReason) {
        self.line = line
        self.prefix = GlossaryDiagnosticItem.clip(prefix)
        self.reason = reason
    }

    /// Prefix is clipped to ≤ 40 characters (spec §5b).
    static func clip(_ s: String) -> String {
        s.count <= 40 ? s : String(s.prefix(40))
    }
}

/// The closed diagnostic set (spec §5b). File-level reasons describe the load
/// as a whole (their line numbers are best-effort: 0 where no single line
/// applies); line-level reasons annotate one source line.
public enum GlossaryDiagnosticReason: Sendable, Equatable {
    // File-level.
    case noEntriesHeading
    case fileMissing
    case fileUnreadable
    case glossaryRejected(reason: String)
    case glossaryTruncated(count: Int)
    case regionEndedEarly(line: Int)
    // Line-level.
    case emptyCanonical
    case duplicateCanonical
    case aliasCollidesWithCanonical
    case aliasDuplicated
    case emptyAlias
    case aliasRejectedUnsafe(reason: String)
    case canonicalCorrectionLimited
    case entryRejected(reason: String)
    case markdownArtifact
}

/// Per-load diagnostics: rollup counts plus the item list (spec §5b).
public struct GlossaryDiagnostics: Sendable, Equatable {
    public var parsedEntries = 0
    public var effectiveEntries = 0
    public var aliasesAdmitted = 0
    public var canonicalsLimited = 0
    public var items: [GlossaryDiagnosticItem] = []

    public init() {}

    public mutating func add(_ item: GlossaryDiagnosticItem) { items.append(item) }

    public mutating func addFile(_ reason: GlossaryDiagnosticReason, line: Int = 0, prefix: String = "") {
        items.append(GlossaryDiagnosticItem(line: line, prefix: prefix, reason: reason))
    }
}

/// The `## Entries` region extracted from a glossary file, with the line
/// numbers needed to map parsed entries and diagnostics back to source.
public struct GlossaryRegion: Sendable, Equatable {
    /// In-region source lines, in order, paired with their absolute (1-based)
    /// line number in the whole file.
    public let lines: [(number: Int, text: String)]
    /// True when the file had a `## Entries` heading at all.
    public let hasHeading: Bool
    /// Set when a `## ` line terminated the region before EOF AND any non-blank,
    /// non-`#` line followed it (spec §2 `regionEndedEarly`). Carries the
    /// terminator line number.
    public let endedEarlyAt: Int?

    public static func == (lhs: GlossaryRegion, rhs: GlossaryRegion) -> Bool {
        lhs.hasHeading == rhs.hasHeading
            && lhs.endedEarlyAt == rhs.endedEarlyAt
            && lhs.lines.count == rhs.lines.count
            && zip(lhs.lines, rhs.lines).allSatisfy { $0.number == $1.number && $0.text == $1.text }
    }
}

public enum GlossaryParser {
    /// The `## Entries` heading, after trimming space/tab/`\r` (case-sensitive,
    /// single space — spec §2).
    static let entriesHeading = "## Entries"

    /// Trim trailing/leading space, tab, and `\r` from a raw line for heading
    /// comparison and `## ` detection (spec §2 "same trim").
    static func headingTrim(_ line: Substring) -> String {
        var s = String(line)
        let trimSet = CharacterSet(charactersIn: " \t\r")
        while let first = s.unicodeScalars.first, trimSet.contains(first) {
            s.removeFirst()
        }
        while let last = s.unicodeScalars.last, trimSet.contains(last) {
            s.removeLast()
        }
        return s
    }

    /// Extracts the `## Entries` region (spec §2). The whole file is split on
    /// `\n` preserving empties so absolute line numbers are exact; CRLF is
    /// handled by the `\r`-aware trims downstream.
    public static func extractRegion(_ text: String) -> GlossaryRegion {
        // `\r\n` is a single Character in Swift; split on any newline grapheme so
        // CRLF files behave identically to LF (G1 §2).
        let rawLines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        // Find the first line equal to `## Entries` (heading-trimmed).
        var headingIndex: Int?
        for (i, raw) in rawLines.enumerated() where headingTrim(raw) == entriesHeading {
            headingIndex = i
            break
        }
        guard let start = headingIndex else {
            return GlossaryRegion(lines: [], hasHeading: false, endedEarlyAt: nil)
        }
        var lines: [(number: Int, text: String)] = []
        var terminator: Int?
        var i = start + 1
        while i < rawLines.count {
            let trimmed = headingTrim(rawLines[i])
            if trimmed.hasPrefix("## ") || trimmed == "##" {
                terminator = i + 1  // 1-based terminator line number
                break
            }
            lines.append((number: i + 1, text: String(rawLines[i])))
            i += 1
        }
        // `regionEndedEarly`: a terminator before EOF with any following
        // non-blank, non-`#` line (after bullet/heading trims it is content).
        var endedEarly: Int?
        if let terminator {
            for j in terminator ..< rawLines.count {
                let t = headingTrim(rawLines[j])
                if t.isEmpty || t.hasPrefix("#") { continue }
                endedEarly = terminator
                break
            }
        }
        return GlossaryRegion(lines: lines, hasHeading: true, endedEarlyAt: endedEarly)
    }

    /// Effective-entry size cap (spec §2): first 2,000 entries kept.
    public static let entryCap = 2_000

    /// Parses the extracted region into entries plus diagnostics (spec §2, §5b),
    /// applying the C5-grammar amendments. Admission (§5a) and the runtime
    /// dictionary are layered on top by `PipelineVocabulary.user`. `entryLines`
    /// is index-aligned with `entries`: each entry's absolute (1-based) source
    /// line number, so admission can attribute its own diagnostics (M-1, §5b).
    public static func parseRegion(_ region: GlossaryRegion) -> (entries: [VocabularyEntry], entryLines: [Int], diagnostics: GlossaryDiagnostics) {
        var diagnostics = GlossaryDiagnostics()
        if !region.hasHeading {
            diagnostics.addFile(.noEntriesHeading)
            return ([], [], diagnostics)
        }
        if let terminator = region.endedEarlyAt {
            diagnostics.addFile(.regionEndedEarly(line: terminator), line: terminator)
        }

        var entries: [VocabularyEntry] = []
        var entryLines: [Int] = []
        // Folded canonical → first-seen line (fold-dup, first wins).
        var seenCanonical: Set<String> = []
        var truncatedFrom: Int?

        for (number, rawText) in region.lines {
            // Strip `\r` for content handling (CRLF files), then trim space/tab.
            var line = rawText
            if line.hasSuffix("\r") { line.removeLast() }
            let trimmedLeading = line.drop { $0 == " " || $0 == "\t" }
            // Strip a single leading list marker (`- ` / `* `) before parsing.
            var body = String(trimmedLeading)
            if body.hasPrefix("- ") || body.hasPrefix("* ") {
                body = String(body.dropFirst(2))
            }
            let trimmed = body.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            // Markdown artifacts: fenced code / blockquote markers.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix(">") {
                diagnostics.add(GlossaryDiagnosticItem(
                    line: number, prefix: trimmed, reason: .markdownArtifact))
                continue
            }

            // Size cap: once `entryCap` effective entries are accepted, drop the
            // rest with one `glossaryTruncated`.
            if entries.count >= entryCap {
                truncatedFrom = (truncatedFrom ?? 0) + 1
                continue
            }

            // Parse fields, trimming each incl. `\r` (already stripped above).
            let fields = trimmed.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard let canonical = fields.first, !canonical.isEmpty else {
                diagnostics.add(GlossaryDiagnosticItem(
                    line: number, prefix: trimmed, reason: .emptyCanonical))
                continue
            }
            let folded = VocabNormalization.canonicalMode(canonical)
            if seenCanonical.contains(folded) {
                diagnostics.add(GlossaryDiagnosticItem(
                    line: number, prefix: trimmed, reason: .duplicateCanonical))
                continue
            }
            // Empty alias field → dropped FIELD-WISE (entry survives), diagnostic.
            let rawAliases = Array(fields.dropFirst())
            var aliases: [String] = []
            var emitEmptyAlias = false
            // An alias folding to the entry's own canonical, or a within-line
            // duplicate alias, makes the line malformed → SKIP the whole line.
            var aliasCollides = false
            var aliasDuplicated = false
            var seenAliasFolds: Set<String> = []
            for alias in rawAliases {
                if alias.isEmpty { emitEmptyAlias = true; continue }
                let aliasFold = VocabNormalization.canonicalMode(alias)
                if aliasFold == folded { aliasCollides = true; break }
                if seenAliasFolds.contains(aliasFold) { aliasDuplicated = true; break }
                seenAliasFolds.insert(aliasFold)
                aliases.append(alias)
            }
            if aliasCollides {
                diagnostics.add(GlossaryDiagnosticItem(
                    line: number, prefix: trimmed, reason: .aliasCollidesWithCanonical))
                continue
            }
            if aliasDuplicated {
                diagnostics.add(GlossaryDiagnosticItem(
                    line: number, prefix: trimmed, reason: .aliasDuplicated))
                continue
            }
            if emitEmptyAlias {
                diagnostics.add(GlossaryDiagnosticItem(
                    line: number, prefix: trimmed, reason: .emptyAlias))
            }
            seenCanonical.insert(folded)
            entries.append(VocabularyEntry(canonical: canonical, aliases: aliases))
            entryLines.append(number)
        }

        if let dropped = truncatedFrom {
            diagnostics.addFile(.glossaryTruncated(count: dropped))
        }
        diagnostics.parsedEntries = entries.count
        return (entries, entryLines, diagnostics)
    }
}
