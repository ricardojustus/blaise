/// Pinned model choices: the selected model stays fixed across a meeting's
/// requests, provenance and spend receipts. Credentials are shared per runtime.
public enum ClaudeNotesModel: String, Sendable, CaseIterable {
    case sonnet46 = "claude-sonnet-4-6"
    case sonnet55 = "claude-sonnet-5-5"
    case opus55 = "claude-opus-5-5"
    case haiku45 = "claude-haiku-4-5"

    public var displayName: String {
        switch self {
        case .sonnet46: "Claude Sonnet 4.6"
        case .sonnet55: "Claude Sonnet 5.5"
        case .opus55: "Claude Opus 5.5"
        case .haiku45: "Claude Haiku 4.5"
        }
    }

    // Preserve the previously persisted selections.
    public var apiEngineID: String { self == .sonnet46 ? "claude-sonnet" : rawValue }
    public var cliEngineID: String { self == .sonnet55 ? "claude-cli" : rawValue + "-cli" }

    public static let apiModels: [Self] = [.sonnet46, .sonnet55, .opus55, .haiku45]
    public static let cliModels: [Self] = [.sonnet55, .opus55]

    /// Standard Messages API rates, verified 2026-10-07 against Anthropic's
    /// model pages. Subscription calls always record zero metered spend.
    /// https://platform.claude.com/docs/en/models/overview
    public var inputUSDPerMTok: Double {
        switch self {
        case .sonnet46: 3
        case .sonnet55: 2
        case .opus55: 4
        case .haiku45: 1
        }
    }

    public var outputUSDPerMTok: Double { inputUSDPerMTok * 5 }

    /// Display-only reprocessing estimate scaled from the existing Sonnet rate.
    public var estimatedPerMeetingUSD: Double { 0.074 * inputUSDPerMTok / 3 }
}
