import Foundation

// PDF-export settings. Keys live in the existing `app_setting` KV table — no
// schema change.

/// The look of the exported PDF.
public enum PDFStyle: String, Codable, Sendable, CaseIterable {
    case atlas
    case ledger
    case clean

    public var displayName: String {
        switch self {
        case .atlas: return "Atlas"
        case .ledger: return "Ledger"
        case .clean: return "Clean"
        }
    }

    public var explanation: String {
        switch self {
        case .atlas: return "Editorial serif, quiet labels, your notes set beneath their passage."
        case .ledger: return "Modern sans with coloured section tabs and checkbox rows."
        case .clean: return "Plain black on white, closest to the markdown itself."
        }
    }
}

/// The paper the PDF is laid out on.
public enum PDFPaper: String, Codable, Sendable, CaseIterable {
    case a4
    case letter

    public var displayName: String {
        switch self {
        case .a4: return "A4"
        case .letter: return "Letter"
        }
    }

    public var explanation: String {
        switch self {
        case .a4: return "210 × 297 mm."
        case .letter: return "8.5 × 11 in."
        }
    }
}

/// The PDF-export KV keys and their loaders. Absent ⇒ the shipped default.
public enum PDFExportSettings {
    public enum Key {
        /// `pdf.defaultStyle` — `PDFStyle`; absent ⇒ `atlas`.
        public static let defaultStyle = "pdf.defaultStyle"
        /// `pdf.paper` — `PDFPaper`; absent ⇒ `a4`.
        public static let paper = "pdf.paper"
        /// `pdf.colophon` — Bool; absent ⇒ true.
        public static let colophon = "pdf.colophon"
        /// `pdf.lastSaveDirectory` — a file URL; absent ⇒ nil ⇒ Downloads.
        public static let lastSaveDirectory = "pdf.lastSaveDirectory"
    }

    public static let defaultStyle = PDFStyle.atlas
    public static let defaultPaper = PDFPaper.a4
    public static let defaultColophon = true

    public static func style(from store: SettingsStore) async -> PDFStyle {
        (try? await store.get(Key.defaultStyle, as: PDFStyle.self)) ?? nil ?? defaultStyle
    }

    public static func setStyle(_ value: PDFStyle, in store: SettingsStore) async throws {
        try await store.set(Key.defaultStyle, to: value)
    }

    public static func paper(from store: SettingsStore) async -> PDFPaper {
        (try? await store.get(Key.paper, as: PDFPaper.self)) ?? nil ?? defaultPaper
    }

    public static func setPaper(_ value: PDFPaper, in store: SettingsStore) async throws {
        try await store.set(Key.paper, to: value)
    }

    public static func colophon(from store: SettingsStore) async -> Bool {
        (try? await store.get(Key.colophon, as: Bool.self)) ?? nil ?? defaultColophon
    }

    public static func setColophon(_ value: Bool, in store: SettingsStore) async throws {
        try await store.set(Key.colophon, to: value)
    }

    public static func lastSaveDirectory(from store: SettingsStore) async -> URL? {
        (try? await store.get(Key.lastSaveDirectory, as: URL.self)) ?? nil
    }

    public static func setLastSaveDirectory(_ value: URL, in store: SettingsStore) async throws {
        try await store.set(Key.lastSaveDirectory, to: value)
    }
}
