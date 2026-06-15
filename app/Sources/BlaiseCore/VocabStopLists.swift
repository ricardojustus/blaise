import Foundation

/// A vendored word-frequency list (`{word} {count}` per line, frequency-descending,
/// `#` header/comment lines ignored). Words are stored canonical-mode folded
/// (lowercase + diacritic fold); membership lookups fold both sides.
public struct FrequencyList: Sendable {
    /// Folded words in frequency order (first occurrence wins on folded duplicates).
    public let orderedWords: [String]
    /// Folded word → 1-based rank of its first occurrence.
    public let rank: [String: Int]

    public init(text: String) {
        var ordered: [String] = []
        var ranks: [String: Int] = [:]
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let word = line.split(separator: " ", maxSplits: 1)[0]
            let folded = VocabNormalization.canonicalMode(String(word))
            if ranks[folded] == nil {
                ordered.append(folded)
                ranks[folded] = ordered.count
            }
        }
        self.orderedWords = ordered
        self.rank = ranks
    }

    public init(contentsOf url: URL) throws {
        self.init(text: try String(contentsOf: url, encoding: .utf8))
    }

    /// Folded set of the `n` most frequent words.
    public func top(_ n: Int) -> Set<String> {
        Set(orderedWords.prefix(n))
    }

    /// Full folded lexicon (~50k).
    public var lexicon: Set<String> { Set(orderedWords) }

    /// 1-based rank of a surface form (folded on lookup), or nil if absent.
    public func rank(of surface: String) -> Int? {
        rank[VocabNormalization.canonicalMode(surface)]
    }
}

/// A simple word-per-line list (`#` comments ignored), folded for membership.
public enum VocabWordList {
    public static func parse(_ text: String) -> Set<String> {
        var words: Set<String> = []
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            words.insert(VocabNormalization.canonicalMode(line))
        }
        return words
    }

    public static func parse(contentsOf url: URL) throws -> Set<String> {
        parse(try String(contentsOf: url, encoding: .utf8))
    }
}

/// Effective suppression set per the C5 spec:
/// top-3000(pt) ∪ top-3000(en) ∪ stoplist_project − stoplist_exclusions, all folded.
public enum SuppressionSet {
    public static let frequencyCut = 3000

    public static func effective(
        pt: FrequencyList,
        en: FrequencyList,
        project: Set<String>,
        exclusions: Set<String>
    ) -> Set<String> {
        pt.top(frequencyCut)
            .union(en.top(frequencyCut))
            .union(project)
            .subtracting(exclusions)
    }
}
