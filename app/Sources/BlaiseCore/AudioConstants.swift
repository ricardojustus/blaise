import Foundation

public enum AudioConstants {
    public struct RetainedFormat: Sendable, Equatable {
        public let codec: String
        public let bitRate: Int
        public let channelCount: Int
        public let fileExtension: String
    }

    /// Retained-audio codec per decision D7: AAC-LC mono 32 kbps `.m4a`.
    public static let retainedFormat = RetainedFormat(
        codec: "AAC-LC",
        bitRate: 32_000,
        channelCount: 1,
        fileExtension: "m4a"
    )
}
