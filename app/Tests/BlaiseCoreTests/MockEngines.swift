import Foundation
import Synchronization
@testable import BlaiseCore

// Mock engines (test support only — never registered by the app's
// composition root). They exercise the protocol contracts: request
// recording (hints contract), `EngineError.cancelled` at the natural
// boundary, and `.configurationMissing` via live config read-through.

final class MockASREngine: ASREngine {
    let id: String
    let displayName = "Mock ASR"
    let kind: EngineKind = .local
    let costDescriptor: EngineCostDescriptor? = nil
    let configDescriptors: [EngineConfigDescriptor]
    private let configuration: EngineConfiguration?
    private let recorded = Mutex<[ASRRequest]>([])

    var recordedRequests: [ASRRequest] {
        recorded.withLock { $0 }
    }

    init(
        id: String = "mock-asr",
        configDescriptors: [EngineConfigDescriptor] = [],
        configuration: EngineConfiguration? = nil
    ) {
        self.id = id
        self.configDescriptors = configDescriptors
        self.configuration = configuration
    }

    func availability() async -> EngineAvailability {
        if let key = await firstMissingRequiredKey() {
            return .unavailable(reason: "missing required configuration: \(key)")
        }
        return .available
    }

    func transcribe(_ request: ASRRequest) async throws -> ASRResult {
        if Task.isCancelled { throw EngineError.cancelled }
        if let key = await firstMissingRequiredKey() {
            throw EngineError.configurationMissing(key: key)
        }
        recorded.withLock { $0.append(request) }
        return ASRResult(
            segments: [ASRSegment(startSeconds: 0, endSeconds: 1.5, text: "olá, vamos começar")],
            detectedLanguage: "pt-BR",
            rawPayload: Data(#"{"mock":true}"#.utf8),
            usage: nil,
            provenance: ASRProvenance(
                engine: id,
                model: "mock-model",
                runtime: "mock-runtime",
                engineVersion: "1",
                transcribedAt: msDate(),
                vocabularyHintsApplied: !request.vocabularyHints.isEmpty,
                languageHint: request.languageHint
            )
        )
    }

    private func firstMissingRequiredKey() async -> String? {
        for descriptor in configDescriptors where descriptor.required {
            let value = try? await configuration?.value(for: descriptor.key)
            if (value ?? nil) == nil { return descriptor.key }
        }
        return nil
    }
}

final class MockSummarizationEngine: SummarizationEngine {
    /// G14: how the seam-injected engine should answer a `generateDigest` call.
    /// Scriptable so AC tests can exercise the wiring deterministically without
    /// a real model (the honest caveat: this tests the seam/contract path, not
    /// the real model's adherence).
    enum DigestBehavior: Sendable {
        /// Return a fixed digest string verbatim.
        case fixed(String)
        /// Build the digest from the request (e.g. honor the drop rule by
        /// omitting a third-party claim the input carries).
        case build(@Sendable (DigestRequest) -> String)
        /// Throw this error every time (AC5c persistent-failure path).
        case failPermanently(EngineError)
        /// Throw a transient error the first N times, then return the string
        /// (AC: the bounded retry / transient-then-success path).
        case transientThen(failCount: Int, then: String)
    }

    let id: String
    let displayName = "Mock Summarizer"
    let kind: EngineKind
    let loadProfile: EngineLoadProfile
    let costDescriptor: EngineCostDescriptor?
    let configDescriptors: [EngineConfigDescriptor]
    private let configuration: EngineConfiguration?
    private let recorded = Mutex<[NotesRequest]>([])
    private let recordedDigests = Mutex<[DigestRequest]>([])
    private let digestBehavior: DigestBehavior
    private let transientAttempts = Mutex<Int>(0)

    var recordedRequests: [NotesRequest] {
        recorded.withLock { $0 }
    }

    /// G14: the digest requests this engine saw (count + content for the AC
    /// tests' notes-vs-digest call assertions).
    var recordedDigestRequests: [DigestRequest] {
        recordedDigests.withLock { $0 }
    }

    var notesCallCount: Int { recorded.withLock { $0.count } }
    var digestCallCount: Int { recordedDigests.withLock { $0.count } }

    init(
        id: String = "mock-summarizer",
        kind: EngineKind = .local,
        loadProfile: EngineLoadProfile = .lightweight,
        costDescriptor: EngineCostDescriptor? = nil,
        configDescriptors: [EngineConfigDescriptor] = [],
        configuration: EngineConfiguration? = nil,
        digestBehavior: DigestBehavior = .fixed("## HEADER\nmeeting: mock\n")
    ) {
        self.id = id
        self.kind = kind
        self.loadProfile = loadProfile
        self.costDescriptor = costDescriptor
        self.configDescriptors = configDescriptors
        self.configuration = configuration
        self.digestBehavior = digestBehavior
    }

    func availability() async -> EngineAvailability {
        if let key = await firstMissingRequiredKey() {
            return .unavailable(reason: "missing required configuration: \(key)")
        }
        return .available
    }

    func generateNotes(_ request: NotesRequest, purpose: CloudSpendPurpose) async throws -> NotesResult {
        if Task.isCancelled { throw EngineError.cancelled }
        if let key = await firstMissingRequiredKey() {
            throw EngineError.configurationMissing(key: key)
        }
        recorded.withLock { $0.append(request) }
        return NotesResult(
            structured: makeStructuredNotes(),
            usage: EngineUsage(inputUnits: 100, outputUnits: 50, estimatedCostUSD: nil),
            provenance: NotesProvenance(
                engine: id,
                model: "mock-model",
                pipelineVersion: "0.1",
                runtime: "mock-runtime",
                rendererVersion: NotesRenderer.version
            )
        )
    }

    func generateDigest(_ request: DigestRequest, purpose: CloudSpendPurpose) async throws -> DigestResult {
        if Task.isCancelled { throw EngineError.cancelled }
        if let key = await firstMissingRequiredKey() {
            throw EngineError.configurationMissing(key: key)
        }
        // Record EVERY attempt the pipeline made (so the AC tests can assert the
        // digest engine fired without the notes engine re-firing).
        recordedDigests.withLock { $0.append(request) }
        let digest: String
        switch digestBehavior {
        case .fixed(let value):
            digest = value
        case .build(let make):
            digest = make(request)
        case .failPermanently(let error):
            throw error
        case .transientThen(let failCount, let value):
            let attempt = transientAttempts.withLock { count -> Int in
                count += 1
                return count
            }
            if attempt <= failCount {
                throw EngineError.transient("mock transient digest failure attempt \(attempt)")
            }
            digest = value
        }
        return DigestResult(
            digest: digest,
            usage: EngineUsage(inputUnits: 80, outputUnits: 40, estimatedCostUSD: nil),
            promptVersion: DigestPromptBuilder.shippedVersion.rawValue)
    }

    private func firstMissingRequiredKey() async -> String? {
        for descriptor in configDescriptors where descriptor.required {
            let value = try? await configuration?.value(for: descriptor.key)
            if (value ?? nil) == nil { return descriptor.key }
        }
        return nil
    }
}
