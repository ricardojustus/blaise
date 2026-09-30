import Foundation

// G16 §4 (specs/g16_audio_retention.md): the owner-set audio size cap.

/// The `storage.audioCap` choices. MB/GB are decimal (10^6 / 10^9 bytes) so the cap
/// matches what `ByteCountFormatter` (`.file` style) shows on macOS.
public enum AudioRetentionCap: String, Codable, CaseIterable, Sendable {
    case mb250, mb500, gb1, gb2, gb5, gb10, gb20, gb50, unlimited

    private static let megabyte: Int64 = 1_000_000
    private static let gigabyte: Int64 = 1_000_000_000

    /// The cap in bytes; nil for `.unlimited`.
    public var bytes: Int64? {
        switch self {
        case .mb250: return 250 * Self.megabyte
        case .mb500: return 500 * Self.megabyte
        case .gb1: return 1 * Self.gigabyte
        case .gb2: return 2 * Self.gigabyte
        case .gb5: return 5 * Self.gigabyte
        case .gb10: return 10 * Self.gigabyte
        case .gb20: return 20 * Self.gigabyte
        case .gb50: return 50 * Self.gigabyte
        case .unlimited: return nil
        }
    }

    public var label: String {
        switch self {
        case .mb250: return "250 MB"
        case .mb500: return "500 MB"
        case .gb1: return "1 GB"
        case .gb2: return "2 GB"
        case .gb5: return "5 GB"
        case .gb10: return "10 GB"
        case .gb20: return "20 GB"
        case .gb50: return "50 GB"
        case .unlimited: return "Unlimited"
        }
    }
}

public enum AudioRetentionSettings {
    /// The size cap (`AudioRetentionCap` raw value). Absent ⇒ Unlimited.
    public static let capKey = "storage.audioCap"
    public static let defaultCap: AudioRetentionCap = .unlimited

    /// The configured cap; absent or unreadable ⇒ `defaultCap` (never deletes).
    public static func cap(from store: SettingsStore) async -> AudioRetentionCap {
        (try? await store.get(capKey, as: AudioRetentionCap.self)) ?? nil ?? defaultCap
    }
}
