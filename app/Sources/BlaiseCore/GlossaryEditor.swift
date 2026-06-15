import Foundation

// G1 §6 — the Settings Glossary editor's file-rewrite layer.
//
// Source of truth = the file's RAW ENTRIES. The editor mirrors parsed entries in
// FILE ORDER (including entries with rejected aliases / limited correction —
// those annotations are computed by the load, not stored here) and regenerates
// the `## Entries` region on save under four invariants:
//   (1) outside-region bytes identical;
//   (2) no entry lost or reordered;
//   (3) top-of-region `#` comments preserved;
//   (4) diagnostic-skipped lines (markdown artifacts etc.) preserved verbatim.
// DOCUMENTED LIMITATION (not an invariant): `#` comments interleaved BETWEEN
// entries may be repositioned or dropped by a save that edits adjacent rows.

/// One editable glossary row, as the table presents it.
public struct GlossaryRow: Sendable, Equatable, Identifiable {
    public let id = UUID()
    public var canonical: String
    public var aliases: [String]

    public init(canonical: String, aliases: [String] = []) {
        self.canonical = canonical
        self.aliases = aliases
    }

    /// Identity is per-row UI bookkeeping; value equality compares content.
    public static func == (lhs: GlossaryRow, rhs: GlossaryRow) -> Bool {
        lhs.canonical == rhs.canonical && lhs.aliases == rhs.aliases
    }

    /// The file line for this row (`canonical | a1 | a2`).
    public var lineText: String {
        ([canonical] + aliases).joined(separator: " | ")
    }
}

public struct GlossaryEditor: Sendable {
    /// The whole file, split on newlines (CRLF graphemes collapse to one line).
    private let originalLines: [String]
    /// Each physical line WITH its original trailing terminator (`\n`, `\r\n`,
    /// or "" for a final line without one). Index-aligned with `originalLines`.
    /// Used to splice the prefix/suffix verbatim so mixed line endings outside
    /// the region survive a save byte-for-byte (M-3 / invariant 1).
    private let originalLineTerminators: [String]
    /// Newline string for the REGENERATED region only (the file's dominant
    /// ending). Outside-region lines keep their own terminators verbatim.
    private let newline: String
    /// Index of the `## Entries` heading line, nil when absent.
    private let headingIndex: Int?
    /// Index (exclusive) where the region ends — the terminator line, or
    /// `originalLines.count` at EOF.
    private let regionEnd: Int
    /// Top-of-region `#`/blank lines preserved verbatim above the first entry.
    private let leadingTrivia: [String]
    /// Diagnostic-skipped lines (markdown artifacts) with their position among
    /// the entry sequence (index = how many entries precede them).
    private let preservedSkips: [(afterEntry: Int, text: String)]

    public private(set) var rows: [GlossaryRow]
    /// Absolute (1-based) source line of each parsed row, index-aligned with
    /// `rows`. Used to attribute load diagnostics (which carry their own absolute
    /// line) to the exact owning row even when several rows share an alias surface
    /// (R2-L-3). Mutated rows do not update this (the table's intent overrides on
    /// save); it reflects the file as parsed.
    public private(set) var rowSourceLines: [Int] = []

    /// True when the file has a `## Entries` heading (the editor can save).
    public var hasEntriesRegion: Bool { headingIndex != nil }

    public init(fileText: String) {
        self.newline = fileText.contains("\r\n") ? "\r\n" : "\n"
        let split = GlossaryEditor.splitPreservingTerminators(fileText)
        let lines = split.map(\.body)
        self.originalLines = lines
        self.originalLineTerminators = split.map(\.terminator)

        var headingIdx: Int?
        for (i, line) in lines.enumerated()
        where GlossaryParser.headingTrim(Substring(line)) == GlossaryParser.entriesHeading {
            headingIdx = i
            break
        }
        self.headingIndex = headingIdx

        guard let start = headingIdx else {
            self.regionEnd = lines.count
            self.leadingTrivia = []
            self.preservedSkips = []
            self.rows = []
            return
        }

        // Region body: from start+1 to the next `## ` line (or EOF).
        var end = lines.count
        var i = start + 1
        while i < lines.count {
            let trimmed = GlossaryParser.headingTrim(Substring(lines[i]))
            if trimmed.hasPrefix("## ") || trimmed == "##" { end = i; break }
            i += 1
        }
        self.regionEnd = end

        // Walk the region: collect leading trivia (before the first entry),
        // parsed rows, and preserved skip lines keyed to entry position.
        var leading: [String] = []
        var parsedRows: [GlossaryRow] = []
        var parsedRowLines: [Int] = []
        var skips: [(afterEntry: Int, text: String)] = []
        var sawFirstEntry = false

        for j in (start + 1) ..< end {
            let raw = lines[j]
            var line = raw
            if line.hasSuffix("\r") { line.removeLast() }
            let leadStripped = line.drop { $0 == " " || $0 == "\t" }
            var body = String(leadStripped)
            if body.hasPrefix("- ") || body.hasPrefix("* ") { body = String(body.dropFirst(2)) }
            let trimmed = body.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                if !sawFirstEntry {
                    leading.append(raw)  // top-of-region trivia preserved verbatim
                }
                // Mid-region comments after the first entry are the documented
                // limitation: they are not preserved between rows.
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix(">") {
                skips.append((afterEntry: parsedRows.count, text: raw))
                sawFirstEntry = true
                continue
            }
            let fields = trimmed.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard let canonical = fields.first, !canonical.isEmpty else {
                // An empty-canonical line is malformed; preserve verbatim so a
                // save never silently drops it.
                skips.append((afterEntry: parsedRows.count, text: raw))
                sawFirstEntry = true
                continue
            }
            let aliases = Array(fields.dropFirst()).filter { !$0.isEmpty }
            parsedRows.append(GlossaryRow(canonical: canonical, aliases: aliases))
            parsedRowLines.append(j + 1) // absolute 1-based line
            sawFirstEntry = true
        }

        self.leadingTrivia = leading
        self.preservedSkips = skips
        self.rows = parsedRows
        self.rowSourceLines = parsedRowLines
    }

    /// Splits text into physical lines, each carrying its trailing terminator
    /// verbatim (`\n`, `\r\n`, or "" for a terminator-less final line). The
    /// `body` sequence and count match `split(whereSeparator: \.isNewline,
    /// omittingEmptySubsequences: false)` exactly, so all existing line indexing
    /// is preserved — this only ADDS the per-line terminator (M-3).
    static func splitPreservingTerminators(_ text: String) -> [(body: String, terminator: String)] {
        var result: [(body: String, terminator: String)] = []
        var body = ""
        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            if ch.isNewline {
                // `\r\n` is a single Character; any newline grapheme terminates.
                result.append((body, String(ch)))
                body = ""
            } else {
                body.append(ch)
            }
            index = text.index(after: index)
        }
        // Final segment (after the last terminator, or the whole text if none):
        // matches the trailing empty element of the non-omitting split.
        result.append((body, ""))
        return result
    }

    // MARK: - Mutations

    /// Append a new entry at the region end (spec §6).
    public mutating func add(canonical: String, aliases: [String] = []) {
        rows.append(GlossaryRow(canonical: canonical, aliases: aliases))
    }

    public mutating func update(id: UUID, canonical: String, aliases: [String]) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i] = GlossaryRow(canonical: canonical, aliases: aliases)
    }

    public mutating func delete(id: UUID) {
        rows.removeAll { $0.id == id }
    }

    /// Replaces the row set wholesale (the Settings table's edited intent).
    /// Preserved skip lines keyed past the new entry count collapse to the end.
    public mutating func replaceRows(with newRows: [GlossaryRow]) {
        rows = newRows
    }

    // MARK: - Validation (inline, §6)

    /// A field is invalid if it contains `|` or starts with `#` (hint shown).
    public static func fieldRejectionHint(_ field: String) -> String? {
        let trimmed = field.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("|") { return "Remove the “|” — it separates fields." }
        if trimmed.hasPrefix("#") { return "A name cannot start with “#” (that's a comment)." }
        return nil
    }

    /// The first invalid field (canonical or alias) across all rows, with its
    /// hint, or nil when every field is valid. §6: a save with an invalid field
    /// is BLOCKED — `|`/leading-`#` would re-parse as different fields on reload
    /// (M-4). Returns `(field, hint, isAlias)`.
    public static func firstInvalidField(in rows: [GlossaryRow]) -> (field: String, hint: String, isAlias: Bool)? {
        for row in rows {
            if let hint = fieldRejectionHint(row.canonical) {
                return (row.canonical, hint, false)
            }
            for alias in row.aliases where fieldRejectionHint(alias) != nil {
                return (alias, fieldRejectionHint(alias)!, true)
            }
        }
        return nil
    }

    /// Inline table annotations from a load's diagnostics, keyed by folded
    /// canonical (§6, §5b wording). Limited canonicals and rejected aliases are
    /// attributed to their owning entry row — a rejected-alias diagnostic is
    /// keyed only by the alias text, so `rows` supplies the alias→owner map
    /// (M-5). Multiple notes for one canonical join with newlines.
    public static func annotations(
        from diagnostics: GlossaryDiagnostics, rows: [GlossaryRow],
        rowSourceLines: [Int] = []
    ) -> [String: String] {
        // Line → owning canonical, when the caller supplies the parsed rows'
        // source lines. A rejected-alias diagnostic carries the alias's absolute
        // source line, so this attributes it to the EXACT owning row even when
        // several entries share an alias surface — exact and order-independent,
        // replacing the last-wins surface map that mis-attributed the n≥3 case
        // (R2-L-3).
        var ownerByLine: [Int: String] = [:]
        if rowSourceLines.count == rows.count {
            for (row, line) in zip(rows, rowSourceLines) { ownerByLine[line] = row.canonical }
        }
        // Fallback owner map (surface → last row listing it) for callers that do
        // not pass line info: the original two-entry behavior.
        var aliasOwnerBySurface: [String: String] = [:]
        for row in rows {
            for alias in row.aliases {
                aliasOwnerBySurface[VocabNormalization.canonicalMode(alias)] = row.canonical
            }
        }
        var map: [String: [String]] = [:]
        for item in diagnostics.items {
            switch item.reason {
            case .canonicalCorrectionLimited:
                map[VocabNormalization.canonicalMode(item.prefix), default: []].append(
                    "used for note spelling (and its mishearings still correct); automatic variant-correction is off for this name because it matches everyday words")
            case .aliasRejectedUnsafe(let reason):
                let owner = ownerByLine[item.line]
                    ?? aliasOwnerBySurface[VocabNormalization.canonicalMode(item.prefix)]
                    ?? item.prefix
                map[VocabNormalization.canonicalMode(owner), default: []].append(
                    "mishearing “\(item.prefix)” not used (\(reason))")
            default:
                break
            }
        }
        return map.mapValues { $0.joined(separator: "\n") }
    }

    // MARK: - Serialize (Save = regenerate the region)

    /// Rebuilds the whole file. The PREFIX (up to and including the
    /// `## Entries` heading) and the SUFFIX (from the terminator line onward)
    /// are spliced VERBATIM with their ORIGINAL per-line terminators, so
    /// mixed/odd line endings outside the region survive byte-for-byte — a no-op
    /// save is byte-identical (M-3 / invariant 1). Only the REGENERATED region
    /// (leading trivia + entries + preserved skips) is joined with the file's
    /// dominant newline. Returns nil when there is no region to write into.
    public func serialize() -> String? {
        guard let start = headingIndex else { return nil }

        // Prefix: lines 0…start, each with its original terminator. The heading
        // line's own terminator becomes the boundary into the region.
        var result = ""
        for i in 0 ... start {
            result += originalLines[i]
            result += originalLineTerminators[i]
        }

        // Region body, joined with the dominant newline. The region is always
        // terminated by `newline` so the suffix (or EOF) starts on its own line,
        // matching the original structure where the terminator line followed.
        var region: [String] = []
        region.append(contentsOf: leadingTrivia)
        func emitSkips(after entryCount: Int) {
            for skip in preservedSkips where skip.afterEntry == entryCount {
                region.append(skip.text)
            }
        }
        emitSkips(after: 0)
        for (index, row) in rows.enumerated() {
            region.append(row.lineText)
            emitSkips(after: index + 1)
        }
        // Any skip lines keyed past the (possibly shrunk) row set still emit at
        // the region end — invariant (4): never silently lost.
        for skip in preservedSkips where skip.afterEntry > rows.count {
            region.append(skip.text)
        }
        for line in region {
            result += line
            result += newline
        }

        // Suffix: the terminator line onward, each with its original terminator.
        if regionEnd < originalLines.count {
            for i in regionEnd ..< originalLines.count {
                result += originalLines[i]
                result += originalLineTerminators[i]
            }
        }
        return result
    }

    /// Appends `## Entries` + the template's commented examples at EOF (spec §6
    /// "Restore entries section"); only valid when the heading is absent.
    public static func restoredText(from fileText: String) -> String {
        fileText + GlossaryTemplate.restoreSuffix
    }

    /// Writes `text` to the glossary file via temp + atomic rename (spec §6 —
    /// torn-read-safe, the editor/restore are the only writers besides §4).
    public static func writeAtomically(_ text: String, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let temp = directory.appendingPathComponent(".Glossary.md.\(UUID().uuidString).tmp")
        try Data(text.utf8).write(to: temp, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: url)
        }
    }
}
