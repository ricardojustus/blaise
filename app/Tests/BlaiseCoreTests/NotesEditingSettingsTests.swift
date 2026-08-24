import Foundation
import Testing

@testable import BlaiseCore

// The notes-surface KV settings: shipped defaults, and a flip that survives a
// fresh read of the same store (no migration, no relaunch).

@Suite struct NotesEditingSettingsTests {
    @Test("margin-note placement defaults to the inline card and round-trips through the store")
    func placementRoundTrip() async throws {
        let database = try makeDatabase()
        let settings = SettingsStore(database: database)

        // The default is the placement whose note can always be read: below the
        // width a rail needs, the margin placement falls back to a chip.
        #expect(await NotesEditingSettings.marginNotesPlacement(from: settings) == .inline)

        try await NotesEditingSettings.setMarginNotesPlacement(.margin, in: settings)
        #expect(await NotesEditingSettings.marginNotesPlacement(from: settings) == .margin)
        // A second store over the same database reads the flip — the value is
        // durable, not process state.
        #expect(
            await NotesEditingSettings.marginNotesPlacement(
                from: SettingsStore(database: database)) == .margin)

        try await NotesEditingSettings.setMarginNotesPlacement(.inline, in: settings)
        #expect(await NotesEditingSettings.marginNotesPlacement(from: settings) == .inline)
    }

    @Test("the teaching callout flag starts unset and is one-way")
    func calloutFlagRoundTrip() async throws {
        let database = try makeDatabase()
        let settings = SettingsStore(database: database)

        #expect(await NotesEditingSettings.editingCalloutSeen(from: settings) == false)
        try await NotesEditingSettings.markEditingCalloutSeen(in: settings)
        #expect(await NotesEditingSettings.editingCalloutSeen(from: settings) == true)
    }
}
