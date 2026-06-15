import Foundation

/// The single producer of `dominantLanguage` (C6 spec §single-language-
/// authority, C7 stage 7): a deterministic function-word classifier over the
/// transcript. Tokenize; count hits against two fixed committed word sets;
/// majority wins; tie or both-zero → "pt" (the user's meetings default PT).
/// Recomputable at regeneration; never fabricated; the LLM outputs no
/// language field.
public enum DominantLanguage {
    /// Portuguese function words (committed set). Forms ambiguous with
    /// common English words ("a", "as", "no", "do") are deliberately
    /// excluded from BOTH sets.
    public static let portugueseWords: Set<String> = [
        "que", "não", "uma", "para", "com", "mas", "isso", "está", "esse",
        "essa", "então", "também", "já", "muito", "bem", "aqui", "vamos",
        "fazer", "ser", "ter", "foi", "são", "tem", "como", "por", "se",
        "da", "dos", "das", "na", "em", "um", "é", "ele", "ela", "você",
        "gente", "pra", "né", "ou",
    ]

    /// English function words (committed set).
    public static let englishWords: Set<String> = [
        "the", "and", "that", "with", "this", "have", "what", "you", "for",
        "but", "not", "are", "was", "they", "there", "here", "will", "would",
        "can", "could", "should", "about", "just", "like", "know", "think",
        "going", "want", "need", "right", "okay", "yes", "well", "of", "to",
        "it", "is", "be", "we", "from",
    ]

    /// "pt" or "en" (bare BCP-47 primary subtags).
    public static func classify(segments: [TranscriptSegment]) -> String {
        classify(text: segments.map(\.text).joined(separator: " "))
    }

    public static func classify(text: String) -> String {
        var ptHits = 0
        var enHits = 0
        for token in tokenize(text) {
            if portugueseWords.contains(token) { ptHits += 1 }
            if englishWords.contains(token) { enHits += 1 }
        }
        return enHits > ptHits ? "en" : "pt"
    }

    static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
