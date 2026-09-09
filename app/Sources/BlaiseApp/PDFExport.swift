import BlaiseCore
import Foundation
import os

// The export sheet's non-visual half: the snapshot it works from, the exporter
// seam it calls, and the attempt state its controls bind to.

/// The app-wide PDF exporter as the sheet uses it: one attempt, rendered and
/// stamped, landing as a file inside the attempt's own directory.
@MainActor
protocol PDFExporting {
    func export(
        html: String, paper: PDFPaper, header: (title: String, date: String), style: PDFStyle,
        filename: String
    ) async throws -> URL
}

/// Everything one export works from, read ONCE when the sheet opens and never
/// re-read: a re-synthesis landing mid-export must not change what is being
/// exported. Correction rows are deliberately absent — aside identity comes
/// from the stored markdown alone.
struct PDFExportInput: Identifiable, Sendable {
    let id = UUID()
    let meeting: Meeting
    let markdown: String
    let language: String
    let style: PDFStyle
    let paper: PDFPaper
    let colophon: Bool
    let lastSaveDirectory: URL?
    /// Computed from the snapshot markdown, so the margin-notes toggle can
    /// never disagree with what the export will actually remove.
    let hasMarginNotes: Bool

    init(
        meeting: Meeting, markdown: String, language: String, style: PDFStyle, paper: PDFPaper,
        colophon: Bool, lastSaveDirectory: URL?
    ) {
        self.meeting = meeting
        self.markdown = markdown
        self.language = language
        self.style = style
        self.paper = paper
        self.colophon = colophon
        self.lastSaveDirectory = lastSaveDirectory
        self.hasMarginNotes = NotesMarkdownSections.hasMarginNotes(markdown, language: language)
    }

    /// `yyyy-MM-dd – <title>.pdf`, with the two characters a file name cannot
    /// carry replaced.
    var defaultFilename: String {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        let title = PDFExportInput.filenameSafe(meeting.title)
        return "\(day.string(from: meeting.startedAt)) \u{2013} \(title).pdf"
    }

    /// The two characters a file name cannot carry, replaced. The default name
    /// is built with this rule and the typed name is held to it, so neither can
    /// name anything but a file directly inside the attempt's directory.
    static func filenameSafe(_ name: String) -> String {
        name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }

    /// nil when the meeting has no notes yet — the entry points are closed in
    /// that state, and a request that races one is ignored.
    static func capture(database: BlaiseDatabase, meetingID: MeetingID) async throws
        -> PDFExportInput?
    {
        guard let meeting = try await MeetingRepository(database: database).fetch(meetingID),
            let notes = try await NotesRepository(database: database).fetch(meetingID: meetingID)
        else { return nil }
        let settings = SettingsStore(database: database)
        return PDFExportInput(
            meeting: meeting, markdown: notes.markdown, language: notes.language,
            style: await PDFExportSettings.style(from: settings),
            paper: await PDFExportSettings.paper(from: settings),
            colophon: await PDFExportSettings.colophon(from: settings),
            lastSaveDirectory: await PDFExportSettings.lastSaveDirectory(from: settings))
    }
}

/// The sheet's state and its two exits. One attempt at a time: the controls
/// stay disabled until the running attempt reports.
@MainActor @Observable
final class PDFExportSheetModel {
    let input: PDFExportInput
    var style: PDFStyle
    var includeSelfActions = true
    var includeMarginNotes = true
    var filename: String
    /// The name both exits deliver: the typed name held to the file-name rule.
    /// The save panel's field is seeded with it too, so the field, the panel
    /// and the Share file cannot name three different things.
    var filenameSafe: String { PDFExportInput.filenameSafe(filename) }
    private(set) var running = false
    /// The last attempt's failure text; the sheet raises it as an alert on its
    /// own window and clears it.
    var failure: String?
    /// The sheet has done its job and closes.
    private(set) var finished = false

    /// Log lines emitted for failures outside the exporter — one per failure.
    private(set) var loggedFailures = 0

    private let exporter: any PDFExporting
    private let settings: SettingsStore
    private let logger = Logger(subsystem: BlaiseBundle.identifier, category: "pdf.export")

    init(input: PDFExportInput, exporter: any PDFExporting, settings: SettingsStore) {
        self.input = input
        self.style = input.style
        self.filename = input.defaultFilename
        self.exporter = exporter
        self.settings = settings
    }

    /// Save: the finished PDF takes the place the panel chose, and that folder
    /// is where the next save panel opens.
    func save(to destination: URL) async {
        // A destination that is itself a symlink cannot be replaced in place,
        // so the file behind it is what the save writes.
        let destination = destination.resolvingSymlinksInPath()
        await attempt { url in
            do {
                // A file already at the destination is replaced only once the
                // new one is in place, so a failed write leaves it standing.
                // The move can cross volumes and the replace cannot, so the
                // new file is staged beside the destination first.
                if FileManager.default.fileExists(atPath: destination.path) {
                    let staged = destination.deletingLastPathComponent()
                        .appendingPathComponent(".\(UUID().uuidString).pdf")
                    try FileManager.default.moveItem(at: url, to: staged)
                    do {
                        _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
                    } catch {
                        try? FileManager.default.removeItem(at: staged)
                        throw error
                    }
                } else {
                    try FileManager.default.moveItem(at: url, to: destination)
                }
                // The file is at the chosen path, so the export has happened;
                // a later failure must not send the user to export it twice.
                self.finished = true
                try await PDFExportSettings.setLastSaveDirectory(
                    destination.deletingLastPathComponent(), in: self.settings)
            } catch {
                // The save attempt has ended, so its directory goes with it.
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                throw error
            }
        }
    }

    /// Share: the file stays where it was rendered, for the picker. nil means
    /// the attempt failed and the alert carries the reason. A file that is
    /// ready leaves the attempt running — the picker, not the render, is its
    /// terminal event.
    func share() async -> URL? {
        var ready: URL?
        await attempt { ready = $0 }
        if ready != nil { running = true }
        return ready
    }

    /// The picker reported, which ends the attempt: a chosen service closes the
    /// sheet; a dismissed picker leaves it up with the file kept for another
    /// try.
    func shareReported(chose: Bool) {
        running = false
        if chose { finished = true }
    }

    private func attempt(_ deliver: (URL) async throws -> Void) async {
        guard !running else { return }
        running = true
        defer { running = false }
        do {
            let markdown = NotesMarkdownSections.apply(
                input.markdown, includeSelf: includeSelfActions,
                includeMarginNotes: includeMarginNotes, language: input.language)
            let front = FrontBlock(meeting: input.meeting, language: input.language)
            let html = try NotesPDFDocument.html(
                markdown: markdown, front: front, style: style, colophon: input.colophon,
                language: input.language)
            let url = try await exporter.export(
                html: html, paper: input.paper,
                header: (title: front.title, date: front.dateText), style: style,
                filename: filenameSafe)
            try await deliver(url)
        } catch {
            failure = error.localizedDescription
            // The exporter logs the failures it raises; this covers the steps
            // on either side of it, so a failure is logged exactly once.
            if !(error is PDFExportError) {
                logger.error("PDF export failed outside the exporter: \(error.localizedDescription)")
                loggedFailures += 1
            }
        }
    }
}

/// The File-menu request, consumed by the detail view that owns the meeting.
/// The request is cleared whether or not it opens anything, so a meeting
/// without notes — or a second ⇧⌘E while the sheet is up — cannot leave a
/// request pending that fires later.
@MainActor
func consumePDFExportRequest(
    uiState: AppUIState, meetingID: MeetingID, hasNotes: Bool, sheetPresented: Bool
) -> Bool {
    guard uiState.pdfExportRequest == meetingID else { return false }
    uiState.pdfExportRequest = nil
    return hasNotes && !sheetPresented
}

/// The app-wide exporter already has the seam's signature.
extension PDFExporter: PDFExporting {}
