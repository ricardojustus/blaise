import Foundation
import Testing

@testable import BlaiseCore

// SC-007: the PDF-export KV settings — shipped defaults when absent, and values
// that survive a fresh read of the same store.

@Suite struct PDFExportSettingsTests {
    @Test("style, paper and colophon default to the shipped values and round-trip")
    func stylePaperColophonRoundTrip() async throws {
        let database = try makeDatabase()
        let settings = SettingsStore(database: database)

        #expect(await PDFExportSettings.style(from: settings) == .atlas)
        #expect(await PDFExportSettings.paper(from: settings) == .a4)
        #expect(await PDFExportSettings.colophon(from: settings) == true)

        try await PDFExportSettings.setStyle(.ledger, in: settings)
        try await PDFExportSettings.setPaper(.letter, in: settings)
        try await PDFExportSettings.setColophon(false, in: settings)

        // A second store over the same database reads the flips — the values are
        // durable, not process state.
        let reread = SettingsStore(database: database)
        #expect(await PDFExportSettings.style(from: reread) == .ledger)
        #expect(await PDFExportSettings.paper(from: reread) == .letter)
        #expect(await PDFExportSettings.colophon(from: reread) == false)

        try await PDFExportSettings.setStyle(.clean, in: settings)
        #expect(await PDFExportSettings.style(from: settings) == .clean)
    }

    @Test("the last save directory is absent until a save records one")
    func lastSaveDirectoryRoundTrip() async throws {
        let database = try makeDatabase()
        let settings = SettingsStore(database: database)

        #expect(await PDFExportSettings.lastSaveDirectory(from: settings) == nil)

        let folder = try makeTempRoot()
        try await PDFExportSettings.setLastSaveDirectory(folder, in: settings)
        #expect(
            await PDFExportSettings.lastSaveDirectory(from: SettingsStore(database: database))
                == folder)
    }

    @Test("every style and paper carries a name and an explanation for the picker")
    func casesCarryPickerText() {
        for style in PDFStyle.allCases {
            #expect(!style.displayName.isEmpty)
            #expect(!style.explanation.isEmpty)
        }
        for paper in PDFPaper.allCases {
            #expect(!paper.displayName.isEmpty)
            #expect(!paper.explanation.isEmpty)
        }
    }
}
