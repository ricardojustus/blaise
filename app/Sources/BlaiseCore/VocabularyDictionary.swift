import Foundation

/// One vocabulary entry: a canonical spelling plus curated mishearing/compound aliases.
public struct VocabularyEntry: Sendable, Equatable {
    public let canonical: String
    public let aliases: [String]

    public init(canonical: String, aliases: [String] = []) {
        self.canonical = canonical
        self.aliases = aliases
    }
}

/// Parser for `fixtures/synthetic_vocab.txt`.
///
/// Grammar (C5 spec, normative): `# comment` and blank lines are ignored
/// (section headers are comments); `canonical` or `canonical|alias1|alias2|…`;
/// `,` has no syntactic meaning; fields are whitespace-trimmed including `\r`
/// (CRLF-safe); an empty canonical is a malformed line — skipped with a
/// surfaced warning; an empty alias field is dropped FIELD-WISE (the entry
/// survives on its remaining fields), also surfaced (G1 §2 amendment — the
/// shared grammar matches the user-glossary wrapper).
public struct VocabularyDictionary: Sendable {
    public let entries: [VocabularyEntry]
    public let warnings: [String]

    public init(entries: [VocabularyEntry], warnings: [String] = []) {
        self.entries = entries
        self.warnings = warnings
    }

    public static func parse(_ text: String) -> VocabularyDictionary {
        var entries: [VocabularyEntry] = []
        var warnings: [String] = []
        // Split on any newline grapheme — `\r\n` is a SINGLE Character in Swift,
        // so a plain `"\n"` separator would leave CRLF lines unsplit (G1 §2).
        let rawLines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for (number, rawLine) in rawLines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard let canonical = fields.first, !canonical.isEmpty else {
                warnings.append("line \(number + 1): empty canonical — skipped: \(line)")
                continue
            }
            // Empty alias fields drop field-wise; the entry survives on its
            // remaining fields (G1 §2). A surfaced warning records the drop.
            let rawAliases = Array(fields.dropFirst())
            let aliases = rawAliases.filter { !$0.isEmpty }
            if aliases.count != rawAliases.count {
                warnings.append("line \(number + 1): empty alias field — dropped: \(line)")
            }
            entries.append(VocabularyEntry(canonical: canonical, aliases: aliases))
        }
        return VocabularyDictionary(entries: entries, warnings: warnings)
    }

    public static func parse(contentsOf url: URL) throws -> VocabularyDictionary {
        parse(try String(contentsOf: url, encoding: .utf8))
    }
}
