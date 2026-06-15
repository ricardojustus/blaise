import Foundation
@testable import BlaiseCore

/// Shared, lazily-loaded C5 fixtures (real repo files — the tests assert against
/// the actual derivation outputs, not synthetic copies).
enum VocabFixtures {
    static let repoRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { url.deleteLastPathComponent() } // file → BlaiseCoreTests → Tests → app → repo
        return url
    }()

    static var fixturesDir: URL { repoRoot.appendingPathComponent("fixtures") }

    static func fixture(_ name: String) -> URL {
        fixturesDir.appendingPathComponent(name)
    }

    static let dictionary: VocabularyDictionary = {
        try! VocabularyDictionary.parse(contentsOf: fixture("synthetic_vocab.txt"))
    }()

    static let ptList: FrequencyList = {
        try! FrequencyList(contentsOf: fixture("stoplist_pt.txt"))
    }()

    static let enList: FrequencyList = {
        try! FrequencyList(contentsOf: fixture("stoplist_en.txt"))
    }()

    static let projectStops: Set<String> = {
        try! VocabWordList.parse(contentsOf: fixture("stoplist_project.txt"))
    }()

    static let exclusions: Set<String> = {
        try! VocabWordList.parse(contentsOf: fixture("stoplist_exclusions.txt"))
    }()

    static let brCommonNames: Set<String> = {
        try! VocabWordList.parse(contentsOf: fixture("br_common_names.txt"))
    }()

    static let suppression: Set<String> = {
        SuppressionSet.effective(pt: ptList, en: enList, project: projectStops, exclusions: exclusions)
    }()

    static let corrector: VocabularyCorrector = {
        try! VocabularyCorrector(dictionary: dictionary, suppression: suppression)
    }()

    /// The pinned pipeline vocabulary stack (G1 `fixture()` path): raw parse of
    /// the repo `fixtures/synthetic_vocab.txt`, suppression from the bundled
    /// stoplists PLUS the pinned project terms — byte-preserving every
    /// regression pin (AC7). After the G6 stoplist split the bundled
    /// `stoplist_user.txt` ships empty, so the harness re-supplies the project
    /// stops (the values that move to the data-root `stoplist_user.txt` on the
    /// deployed machine) to reproduce the pinned suppression set exactly.
    static func pipelineVocabulary() throws -> PipelineVocabulary {
        try PipelineVocabulary.fixture(
            vocabURL: fixture("synthetic_vocab.txt"), additionalSuppression: projectStops)
    }

    static let manifest: VocabManifest = {
        try! JSONDecoder().decode(VocabManifest.self, from: Data(contentsOf: fixture("synthetic_vocab.manifest.json")))
    }()

    /// Folded surface → canonical map over the live dictionary (admission-rule input).
    static let surfaces: [String: String] = {
        var map: [String: String] = [:]
        for entry in dictionary.entries {
            map[VocabNormalization.canonicalMode(entry.canonical)] = entry.canonical
            for alias in entry.aliases {
                map[VocabNormalization.canonicalMode(alias)] = entry.canonical
            }
        }
        return map
    }()

    /// Golden clauses: (source, input, expected).
    static let goldenClauses: [(source: String, input: String, expected: String)] = {
        let text = try! String(contentsOf: fixture("c5_golden_clauses.tsv"), encoding: .utf8)
        return text.split(separator: "\n").compactMap { line in
            if line.hasPrefix("#") { return nil }
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            precondition(parts.count == 3, "malformed golden row: \(line)")
            return (parts[0], parts[1], parts[2])
        }
    }()
}

/// Minimal decodable view of synthetic_vocab.manifest.json (the fields the ACs assert).
struct VocabManifest: Decodable, Sendable {
    struct LevelARecord: Decodable, Sendable {
        let surface: String
        let canonical: String
        let ptRank: Int?
        let enRank: Int?
        let disposition: String
        let justification: String
    }

    struct LevelBRecord: Decodable, Sendable {
        let canonical: String
        let cores: [String]
        let nonStopCores: [String]
        let classification: String
    }

    struct ProjectWord: Decodable, Sendable {
        let word: String
        let source: String
        let justification: String
    }

    struct AdmissionRecord: Decodable, Sendable {
        let alias: String
        let canonical: String
        let verdict: String
        let residualRisk: String
    }

    struct CompoundAliasRecord: Decodable, Sendable {
        let alias: String
        let canonical: String
        let cores: [String]
        let lexiconCommonCores: [String]
        let verdict: String
        let detail: String
    }

    let entryCount: Int
    let aliasCount: Int
    let multiTokenEntryCount: Int
    let levelA: [LevelARecord]
    let levelB: [LevelBRecord]
    let stoplistProject: [ProjectWord]
    let aliasAdmissions: [AdmissionRecord]
    let compoundAliasScan: [CompoundAliasRecord]
    let assertions: [String: Bool]
}
