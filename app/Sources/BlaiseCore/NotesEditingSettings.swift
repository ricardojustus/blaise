import Foundation

// Presentation settings for the notes editing surface. Keys live in the
// existing `app_setting` KV table (the `HandoffDestination.Key` pattern) — no
// schema change.

/// Where a margin note appears in a meeting's notes.
///
/// `inline` — an always-visible card under the noted text, pushing content
/// down. Safe at any window width, so it is the default.
/// `margin` — quiet typography in a right-hand rail beside the text, with the
/// narrow-window chip as its only fallback.
public enum MarginNotesPlacement: String, Codable, Sendable, CaseIterable {
    case inline
    case margin

    public var displayName: String {
        switch self {
        case .inline: return "In line"
        case .margin: return "In the margin"
        }
    }

    public var explanation: String {
        switch self {
        case .inline: return "Under the noted text, pushing content down."
        case .margin: return "Beside the text, when the window is wide enough."
        }
    }
}

/// The notes-surface KV keys and their loaders. Absent ⇒ the shipped default.
public enum NotesEditingSettings {
    public enum Key {
        /// `notes.marginNotesPlacement` — `MarginNotesPlacement`; absent ⇒ `inline`.
        public static let marginNotesPlacement = "notes.marginNotesPlacement"
        /// `notes.editingCalloutSeen` — Bool; absent ⇒ false ⇒ the one-time
        /// teaching callout is still owed.
        public static let editingCalloutSeen = "notes.editingCalloutSeen"
    }

    /// A card under the block it belongs to. The rail is the better shape where
    /// the pane can hold one, and it is one Setting away — but below the width a
    /// rail needs, the margin placement falls back to a chip, and a chip that
    /// does not expand leaves a saved note visible and unreadable. The default
    /// is the placement whose note can always be read.
    public static let defaultPlacement = MarginNotesPlacement.inline

    public static func marginNotesPlacement(from store: SettingsStore) async -> MarginNotesPlacement {
        (try? await store.get(Key.marginNotesPlacement, as: MarginNotesPlacement.self))
            ?? nil ?? defaultPlacement
    }

    public static func setMarginNotesPlacement(
        _ value: MarginNotesPlacement, in store: SettingsStore
    ) async throws {
        try await store.set(Key.marginNotesPlacement, to: value)
    }

    public static func editingCalloutSeen(from store: SettingsStore) async -> Bool {
        (try? await store.get(Key.editingCalloutSeen, as: Bool.self)) ?? nil ?? false
    }

    public static func markEditingCalloutSeen(in store: SettingsStore) async throws {
        try await store.set(Key.editingCalloutSeen, to: true)
    }

    /// The callout shows exactly while it has never been dismissed and the
    /// surface has notes to teach on. Any correction/note action dismisses it,
    /// which the caller records by flipping `seen`.
    public static func showEditingCallout(seen: Bool, hasNotes: Bool) -> Bool {
        !seen && hasNotes
    }
}
