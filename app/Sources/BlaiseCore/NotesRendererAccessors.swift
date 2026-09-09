import Foundation

// The renderer's name-free localized strings, exposed for consumers that must
// recognise its own output (the PDF export classifies sections and margin-note
// asides in stored markdown). Reading these instead of duplicating the literals
// keeps the markdown artifact the single source of those bytes.
extension NotesRenderer {
    private static func strings(_ language: String) -> LocalizedStrings {
        LocalizedStrings.match(language, userName: "")
    }

    public static func summaryHeading(language: String) -> String {
        strings(language).summary
    }

    public static func detailedNotesHeading(language: String) -> String {
        strings(language).detailedNotes
    }

    public static func decisionsHeading(language: String) -> String {
        strings(language).decisions
    }

    public static func actionItemsHeading(language: String) -> String {
        strings(language).actionItems
    }

    public static func yourNotesHeading(language: String) -> String {
        strings(language).yourNotes
    }

    /// The bold tag that opens a margin-note aside blockquote.
    public static func yourNoteLabel(language: String) -> String {
        strings(language).yourNote
    }

    /// Which language the renderer picked for this tag — asked of the matcher
    /// itself, so a consumer never re-implements the BCP-47 rule.
    public static func isPortuguese(language: String) -> Bool {
        strings(language).summary == LocalizedStrings.portuguese(userName: "").summary
    }
}
