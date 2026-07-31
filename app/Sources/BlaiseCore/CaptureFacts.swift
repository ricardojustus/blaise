import Foundation

public struct CaptureFacts: Codable, Sendable, Equatable {
    public enum SourceProvenance: String, Codable, Sendable {
        case explicit
        case classified
    }

    public enum LinkClass: String, Codable, Sendable {
        case none
        case recognized
        case generic
        case assumed
    }

    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var sourceProvenance: SourceProvenance
    public var linkClass: LinkClass

    public init(
        schemaVersion: Int = currentSchemaVersion,
        sourceProvenance: SourceProvenance,
        linkClass: LinkClass
    ) {
        self.schemaVersion = schemaVersion
        self.sourceProvenance = sourceProvenance
        self.linkClass = linkClass
    }

    public static func derive(
        source: MeetingSource,
        meetingCode: String?,
        sourceProvenance: SourceProvenance,
        joinedLinkText: String? = nil
    ) -> CaptureFacts {
        let linkText = joinedLinkText ?? ""
        let linkClass: LinkClass
        if meetingCode?.isEmpty == false || CaptureLinkClassifier.containsRecognizedLink(in: linkText) {
            linkClass = .recognized
        } else if CaptureLinkClassifier.containsGenericLink(in: linkText) {
            linkClass = .generic
        } else if source == .inPerson {
            linkClass = .none
        } else {
            linkClass = .assumed
        }
        return CaptureFacts(sourceProvenance: sourceProvenance, linkClass: linkClass)
    }

    /// Compatibility derivation is intentionally narrower than fresh capture:
    /// old rows did not retain the joined calendar-link fields.
    public static func legacy(source: MeetingSource, meetingCode: String?) -> CaptureFacts {
        let linkClass: LinkClass
        if meetingCode?.isEmpty == false || source == .zoom || source == .teams {
            linkClass = .recognized
        } else if source == .inPerson {
            linkClass = .none
        } else {
            linkClass = .assumed
        }
        return CaptureFacts(sourceProvenance: .classified, linkClass: linkClass)
    }

    public static func resolve(
        encoded: Data?, legacySource: MeetingSource, legacyMeetingCode: String?
    ) -> CaptureFactsReadResult {
        guard let encoded else {
            return CaptureFactsReadResult(
                facts: legacy(source: legacySource, meetingCode: legacyMeetingCode),
                disposition: .synthesizedAbsent)
        }
        guard let facts = try? JSONDecoder().decode(CaptureFacts.self, from: encoded) else {
            return CaptureFactsReadResult(
                facts: legacy(source: legacySource, meetingCode: legacyMeetingCode),
                disposition: .synthesizedCorrupt)
        }
        return CaptureFactsReadResult(facts: facts, disposition: .persisted)
    }

    public static func write(_ facts: CaptureFacts, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(facts).write(to: url, options: .atomic)
    }
}

public struct CaptureFactsReadResult: Sendable, Equatable {
    public enum Disposition: Sendable, Equatable {
        case persisted
        case synthesizedAbsent
        case synthesizedCorrupt
    }

    public var facts: CaptureFacts
    public var disposition: Disposition

    public init(facts: CaptureFacts, disposition: Disposition) {
        self.facts = facts
        self.disposition = disposition
    }
}

public enum CaptureLinkClassifier {
    private static let recognizedHosts = [
        "meet.google.com",
        "zoom.us",
        "teams.microsoft.com",
        "app.slack.com",
    ]

    public static func containsRecognizedLink(in text: String) -> Bool {
        let lowercased = text.lowercased()
        if recognizedHosts.contains(where: { lowercased.contains($0) }) {
            return true
        }
        return urls(in: text).contains { url in
            guard let host = url.host?.lowercased() else { return false }
            return recognizedHosts.contains { host == $0 || host.hasSuffix(".\($0)") }
        }
    }

    public static func containsGenericLink(in text: String) -> Bool {
        urls(in: text).contains { url in
            guard let host = url.host?.lowercased() else { return false }
            return !recognizedHosts.contains { host == $0 || host.hasSuffix(".\($0)") }
        }
    }

    private static func urls(in text: String) -> [URL] {
        let pattern = #"https?://[^\s<>"']+"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive])
        else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            return URL(string: String(text[matchRange]))
        }
    }
}
