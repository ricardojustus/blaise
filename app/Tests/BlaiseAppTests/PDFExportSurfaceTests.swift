import BlaiseCore
import Foundation
import Testing

@testable import BlaiseApp

// The export surface where it is decidable without a rendered scene: the
// snapshot the sheet works from, the state its controls bind to, the folder a
// save remembers, and the request the File-menu command leaves behind.

/// Stands in for the real exporter: records what the sheet handed it, can be
/// held open while the controls are inspected, and can fail on demand.
@MainActor
private final class StubPDFExporter: PDFExporting {
    private(set) var html: String?
    private(set) var paper: PDFPaper?
    private(set) var header: (title: String, date: String)?
    private(set) var style: PDFStyle?
    private(set) var filename: String?
    private(set) var running = false
    /// The URL handed back, whose parent is the attempt's directory.
    private(set) var produced: URL?

    /// Thrown instead of producing a file.
    var failure: Error?
    /// The attempt waits until `release()` when true.
    var holds = false
    /// Returns the URL of a file that was never written, so delivery fails.
    var losesOutput = false

    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }

    func export(
        html: String, paper: PDFPaper, header: (title: String, date: String), style: PDFStyle,
        filename: String
    ) async throws -> URL {
        self.html = html
        self.paper = paper
        self.header = header
        self.style = style
        self.filename = filename
        running = true
        defer { running = false }
        if holds, !released {
            await withCheckedContinuation { continuation in
                if released {
                    continuation.resume()
                } else {
                    waiter = continuation
                }
            }
        }
        if let failure { throw failure }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(filename)
        produced = url
        if losesOutput { return url }
        try Data("%PDF-1.4\n".utf8).write(to: url)
        return url
    }
}

private struct StubFailure: LocalizedError {
    var errorDescription: String? { "the stylesheet is missing" }
}

@MainActor
struct PDFExportSurfaceTests {
    private static let meetingID: MeetingID = "01QUOLLHARBOR00000000000TIDE"
    private static let language = "en-GB"

    /// Fictional throughout (Vexatron Labs / Quoll Harbor), with the renderer's
    /// own heading and aside strings so the classifier sees what it would see
    /// in a real row.
    private static func markdown(withMarginNote: Bool) -> String {
        let heading = { (text: String) in "## \(text)" }
        var lines = [
            "# Quoll Harbor tide review",
            "",
            heading(NotesRenderer.summaryHeading(language: language)),
            "The buoy array survived the spring tide.",
            "",
            heading(NotesRenderer.actionItemsHeading(language: language)),
            "- **Wren Calloway:** re-anchor buoy four",
            "",
            "## My action items",
            "- send Vexatron Labs the revised chart",
        ]
        if withMarginNote {
            lines += [
                "",
                "> **\(NotesRenderer.yourNoteLabel(language: language)):** the datum is new.",
            ]
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func database() throws -> BlaiseDatabase {
        try BlaiseDatabase(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("blaise-pdf-export-tests-\(UUID().uuidString)"))
    }

    private static func seed(_ database: BlaiseDatabase, markdown: String) async throws {
        let moment = Date(timeIntervalSince1970: 1_770_000_000)
        let meeting = Meeting(
            id: meetingID, title: "Quoll Harbor tide review", startedAt: moment, source: .meet,
            status: .ready, createdAt: moment, updatedAt: moment)
        try await MeetingRepository(database: database).create(meeting)
        let structured = NotesStructured(
            summary: "The buoy array survived the spring tide.", detailedNotes: "",
            decisions: [], actionItems: [], userActionItems: [])
        try await NotesRepository(database: database).upsert(
            MeetingNotes(
                meetingID: meetingID, markdown: markdown, structured: structured,
                language: language, generatedAt: moment,
                provenance: NotesProvenance(
                    engine: "test", model: "test", pipelineVersion: "test", runtime: "test",
                    rendererVersion: NotesRenderer.version, promptVersion: "test")))
    }

    private static func destination() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("blaise-pdf-save-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("export.pdf")
    }

    // MARK: - SC-015(a): the snapshot is what exports

    @Test("SC-015(a): the export uses the sheet's snapshot, not the rows it was taken from")
    func exportUsesTheSnapshotAfterTheRowAndSettingsChange() async throws {
        let database = try Self.database()
        try await Self.seed(database, markdown: Self.markdown(withMarginNote: true))
        let settings = SettingsStore(database: database)
        try await PDFExportSettings.setStyle(.ledger, in: settings)
        try await PDFExportSettings.setColophon(true, in: settings)

        let input = try #require(
            await PDFExportInput.capture(database: database, meetingID: Self.meetingID))
        #expect(input.hasMarginNotes, "the snapshot markdown carries an aside")
        #expect(input.style == .ledger)

        // Everything the snapshot read now changes underneath it.
        try await NotesRepository(database: database).upsert(
            MeetingNotes(
                meetingID: Self.meetingID, markdown: "# Replaced\n\n## Summary\nNothing.\n",
                structured: NotesStructured(
                    summary: "Nothing.", detailedNotes: "", decisions: [], actionItems: [],
                    userActionItems: []),
                language: Self.language, generatedAt: Date(),
                provenance: NotesProvenance(
                    engine: "test", model: "test", pipelineVersion: "test", runtime: "test",
                    rendererVersion: NotesRenderer.version, promptVersion: "test")))
        try await PDFExportSettings.setStyle(.clean, in: settings)
        try await PDFExportSettings.setColophon(false, in: settings)
        try await PDFExportSettings.setPaper(.letter, in: settings)

        let exporter = StubPDFExporter()
        let model = PDFExportSheetModel(input: input, exporter: exporter, settings: settings)
        await model.save(to: Self.destination())

        let html = try #require(exporter.html)
        #expect(html.contains("re-anchor buoy four"), "the snapshot markdown was exported")
        #expect(!html.contains("Replaced"), "the row written after the snapshot was not read")
        #expect(html.contains("Made with"), "the colophon follows the snapshot, not the new value")
        #expect(exporter.style == .ledger)
        #expect(exporter.paper == .a4)
        #expect(exporter.header?.title == "Quoll Harbor tide review")
    }

    @Test("SC-015(a): the margin-notes toggle is offered from the snapshot markdown")
    func marginNotesToggleFollowsTheSnapshot() async throws {
        let database = try Self.database()
        try await Self.seed(database, markdown: Self.markdown(withMarginNote: false))
        let input = try #require(
            await PDFExportInput.capture(database: database, meetingID: Self.meetingID))
        #expect(!input.hasMarginNotes)
    }

    // MARK: - SC-008: the request the menu command leaves, and the controls

    @Test("SC-008: a valid request opens the sheet exactly once and is consumed")
    func aValidRequestIsConsumedOnce() {
        let uiState = AppUIState()
        uiState.pdfExportRequest = Self.meetingID
        #expect(
            consumePDFExportRequest(
                uiState: uiState, meetingID: Self.meetingID, hasNotes: true, sheetPresented: false))
        #expect(uiState.pdfExportRequest == nil)
        #expect(
            !consumePDFExportRequest(
                uiState: uiState, meetingID: Self.meetingID, hasNotes: true, sheetPresented: false),
            "the consumed request cannot fire a second sheet")
    }

    @Test("SC-008: a request for a meeting without notes is consumed and ignored")
    func aRequestWithoutNotesIsIgnored() {
        let uiState = AppUIState()
        uiState.pdfExportRequest = Self.meetingID
        #expect(
            !consumePDFExportRequest(
                uiState: uiState, meetingID: Self.meetingID, hasNotes: false, sheetPresented: false))
        #expect(uiState.pdfExportRequest == nil, "it must not fire when notes later arrive")
    }

    @Test("SC-008: a request arriving while the sheet stands is consumed and ignored")
    func aRequestWhilePresentedIsIgnored() {
        let uiState = AppUIState()
        uiState.pdfExportRequest = Self.meetingID
        #expect(
            !consumePDFExportRequest(
                uiState: uiState, meetingID: Self.meetingID, hasNotes: true, sheetPresented: true))
        #expect(uiState.pdfExportRequest == nil)
    }

    @Test("SC-008: a request for another meeting is left for the view that owns it")
    func aRequestForAnotherMeetingIsLeftAlone() {
        let uiState = AppUIState()
        uiState.pdfExportRequest = "01OTHERMEETING000000000000"
        #expect(
            !consumePDFExportRequest(
                uiState: uiState, meetingID: Self.meetingID, hasNotes: true, sheetPresented: false))
        #expect(uiState.pdfExportRequest == "01OTHERMEETING000000000000")
    }

    @Test("SC-008: the controls are disabled while an attempt runs and enabled after it fails")
    func controlsFollowTheAttemptAndItsFailure() async throws {
        let database = try Self.database()
        try await Self.seed(database, markdown: Self.markdown(withMarginNote: true))
        let settings = SettingsStore(database: database)
        let input = try #require(
            await PDFExportInput.capture(database: database, meetingID: Self.meetingID))

        let exporter = StubPDFExporter()
        exporter.holds = true
        exporter.failure = StubFailure()
        let model = PDFExportSheetModel(input: input, exporter: exporter, settings: settings)
        #expect(!model.running)

        let attempt = Task { await model.save(to: Self.destination()) }
        while !exporter.running { await Task.yield() }
        #expect(model.running, "every control is disabled while the attempt is in flight")

        exporter.release()
        await attempt.value
        #expect(!model.running, "the controls come back when the attempt reports")
        #expect(model.failure == "the stylesheet is missing", "the alert carries the reason")
    }

    // MARK: - SC-009: the folder a save remembers

    @Test("SC-009: a successful save stores the chosen folder for the next panel")
    func aSuccessfulSaveRemembersTheFolder() async throws {
        let database = try Self.database()
        try await Self.seed(database, markdown: Self.markdown(withMarginNote: true))
        let settings = SettingsStore(database: database)
        let input = try #require(
            await PDFExportInput.capture(database: database, meetingID: Self.meetingID))
        #expect(input.lastSaveDirectory == nil)

        let destination = Self.destination()
        let model = PDFExportSheetModel(
            input: input, exporter: StubPDFExporter(), settings: settings)
        await model.save(to: destination)

        #expect(model.failure == nil)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(
            await PDFExportSettings.lastSaveDirectory(from: settings)?.standardizedFileURL
                == destination.deletingLastPathComponent().standardizedFileURL)
    }

    // MARK: - R-13: what a failed save may not destroy, and what is logged

    @Test("R-13: a failed save leaves the file already at the destination untouched")
    func aFailedSaveKeepsTheExistingFile() async throws {
        let database = try Self.database()
        try await Self.seed(database, markdown: Self.markdown(withMarginNote: false))
        let settings = SettingsStore(database: database)
        let input = try #require(
            await PDFExportInput.capture(database: database, meetingID: Self.meetingID))

        let destination = Self.destination()
        let sentinel = Data("the export from last week".utf8)
        try sentinel.write(to: destination)

        let exporter = StubPDFExporter()
        exporter.losesOutput = true
        let model = PDFExportSheetModel(input: input, exporter: exporter, settings: settings)
        await model.save(to: destination)

        #expect(model.failure != nil, "the alert carries the reason")
        #expect(!model.finished, "a failed save does not close the sheet")
        #expect(try Data(contentsOf: destination) == sentinel, "the earlier file is still there")
    }

    @Test("R-13: a replace that cannot complete leaves the existing file and nothing staged")
    func aFailedReplaceKeepsTheExistingFileAndStagesNothing() async throws {
        let database = try Self.database()
        try await Self.seed(database, markdown: Self.markdown(withMarginNote: false))
        let settings = SettingsStore(database: database)
        let input = try #require(
            await PDFExportInput.capture(database: database, meetingID: Self.meetingID))

        let destination = Self.destination()
        let sentinel = Data("the export from last week".utf8)
        try sentinel.write(to: destination)
        // An immutable destination fails the replace itself, with the new file
        // already staged in the same folder.
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: destination.path)
        defer {
            try? FileManager.default.setAttributes(
                [.immutable: false], ofItemAtPath: destination.path)
        }

        let model = PDFExportSheetModel(
            input: input, exporter: StubPDFExporter(), settings: settings)
        await model.save(to: destination)

        #expect(model.failure != nil, "the alert carries the reason")
        #expect(!model.finished)
        #expect(try Data(contentsOf: destination) == sentinel, "the earlier file is still there")
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: destination.deletingLastPathComponent().path)
                == [destination.lastPathComponent],
            "nothing was left staged beside it")
    }

    @Test("R-13: a successful save replaces the file already at the destination")
    func aSuccessfulSaveReplacesTheExistingFile() async throws {
        let database = try Self.database()
        try await Self.seed(database, markdown: Self.markdown(withMarginNote: false))
        let settings = SettingsStore(database: database)
        let input = try #require(
            await PDFExportInput.capture(database: database, meetingID: Self.meetingID))

        let destination = Self.destination()
        try Data("the export from last week".utf8).write(to: destination)

        let model = PDFExportSheetModel(
            input: input, exporter: StubPDFExporter(), settings: settings)
        await model.save(to: destination)

        #expect(model.failure == nil)
        #expect(model.finished)
        #expect(try Data(contentsOf: destination) == Data("%PDF-1.4\n".utf8))
    }

    @Test("R-13: a save to a symlinked destination writes the file the link points at")
    func aSaveFollowsASymlinkedDestination() async throws {
        let database = try Self.database()
        try await Self.seed(database, markdown: Self.markdown(withMarginNote: false))
        let settings = SettingsStore(database: database)
        let input = try #require(
            await PDFExportInput.capture(database: database, meetingID: Self.meetingID))

        let link = Self.destination()
        let real = link.deletingLastPathComponent().appendingPathComponent("real.pdf")
        try Data("the export from last week".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let model = PDFExportSheetModel(
            input: input, exporter: StubPDFExporter(), settings: settings)
        await model.save(to: link)

        #expect(model.failure == nil)
        #expect(model.finished)
        #expect(try Data(contentsOf: real) == Data("%PDF-1.4\n".utf8))
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == real.path)
    }

    @Test("SC-013: a failure before the exporter is reached is logged once")
    func aTemplateFailureIsLoggedOnce() async throws {
        let database = try Self.database()
        try await Self.seed(database, markdown: Self.markdown(withMarginNote: false))
        let settings = SettingsStore(database: database)
        let input = try #require(
            await PDFExportInput.capture(database: database, meetingID: Self.meetingID))

        let exporter = StubPDFExporter()
        exporter.failure = NotesPDFDocumentError.missingResource("pdf/template.html")
        let model = PDFExportSheetModel(input: input, exporter: exporter, settings: settings)
        await model.save(to: Self.destination())

        #expect(model.failure != nil, "the alert is raised")
        #expect(model.loggedFailures == 1, "exactly one log line")
    }

    @Test("SC-013: a failure writing to the chosen destination is logged once")
    func aWriteFailureIsLoggedOnce() async throws {
        let database = try Self.database()
        try await Self.seed(database, markdown: Self.markdown(withMarginNote: false))
        let settings = SettingsStore(database: database)
        let input = try #require(
            await PDFExportInput.capture(database: database, meetingID: Self.meetingID))

        let exporter = StubPDFExporter()
        let model = PDFExportSheetModel(input: input, exporter: exporter, settings: settings)
        await model.save(
            to: URL(fileURLWithPath: "/pdf-export-no-such-dir-\(UUID().uuidString)/notes.pdf"))

        #expect(model.failure != nil, "the alert is raised")
        #expect(model.loggedFailures == 1, "exactly one log line")
        #expect(!model.finished)
        let attemptDirectory = try #require(exporter.produced).deletingLastPathComponent()
        #expect(
            !FileManager.default.fileExists(atPath: attemptDirectory.path),
            "the failed attempt took its directory with it")
    }

    @Test("SC-013: a failure the exporter already logged is not logged a second time")
    func anExporterFailureIsNotLoggedTwice() async throws {
        let database = try Self.database()
        try await Self.seed(database, markdown: Self.markdown(withMarginNote: false))
        let settings = SettingsStore(database: database)
        let input = try #require(
            await PDFExportInput.capture(database: database, meetingID: Self.meetingID))

        let exporter = StubPDFExporter()
        exporter.failure = PDFExportError.timedOut
        let model = PDFExportSheetModel(input: input, exporter: exporter, settings: settings)
        await model.save(to: Self.destination())

        #expect(model.failure != nil)
        #expect(model.loggedFailures == 0, "the exporter logged that one")
    }

    // MARK: - SC-014: a share attempt ends at the picker

    @Test("SC-014: the controls stay disabled until the share picker reports")
    func shareStaysRunningUntilThePickerReports() async throws {
        let database = try Self.database()
        try await Self.seed(database, markdown: Self.markdown(withMarginNote: false))
        let settings = SettingsStore(database: database)
        let input = try #require(
            await PDFExportInput.capture(database: database, meetingID: Self.meetingID))

        let model = PDFExportSheetModel(
            input: input, exporter: StubPDFExporter(), settings: settings)
        let url = try #require(await model.share())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(model.running, "the picker has not reported yet")
        #expect(!model.finished)

        model.shareReported(chose: false)
        #expect(!model.running, "a dismissed picker ends the attempt")
        #expect(!model.finished, "and leaves the sheet up for another try")

        let second = try #require(await model.share())
        defer { try? FileManager.default.removeItem(at: second.deletingLastPathComponent()) }
        model.shareReported(chose: true)
        #expect(!model.running)
        #expect(model.finished, "a chosen service closes the sheet")
    }

    // MARK: - The filename the sheet starts from

    @Test("R-9: a typed file name naming a path is held to the default's rule")
    func aTypedFilenameCannotNameAPath() async throws {
        let database = try Self.database()
        try await Self.seed(database, markdown: Self.markdown(withMarginNote: false))
        let settings = SettingsStore(database: database)
        let input = try #require(
            await PDFExportInput.capture(database: database, meetingID: Self.meetingID))

        let exporter = StubPDFExporter()
        let model = PDFExportSheetModel(input: input, exporter: exporter, settings: settings)
        model.filename = "scratch/render.pdf"
        await model.save(to: Self.destination())

        #expect(exporter.filename == "scratch-render.pdf")
    }

    @Test("R-9: the name the panel is seeded with is the one both exits deliver")
    func theSanitisedNameIsTheOneThePanelIsSeededWith() async throws {
        let database = try Self.database()
        try await Self.seed(database, markdown: Self.markdown(withMarginNote: false))
        let settings = SettingsStore(database: database)
        let input = try #require(
            await PDFExportInput.capture(database: database, meetingID: Self.meetingID))

        let exporter = StubPDFExporter()
        let model = PDFExportSheetModel(input: input, exporter: exporter, settings: settings)
        model.filename = "scratch/render.pdf"

        #expect(model.filenameSafe == "scratch-render.pdf")
        await model.save(to: Self.destination())
        #expect(exporter.filename == model.filenameSafe)
    }

    @Test("the default file name carries the date and a title no folder could hold")
    func defaultFilenameReplacesPathAndTimeCharacters() {
        let moment = Date(timeIntervalSince1970: 1_770_000_000)
        let meeting = Meeting(
            id: Self.meetingID, title: "Quoll Harbor / Vexatron Labs: tide review",
            startedAt: moment, source: .meet, status: .ready, createdAt: moment, updatedAt: moment)
        let input = PDFExportInput(
            meeting: meeting, markdown: "", language: Self.language, style: .atlas, paper: .a4,
            colophon: true, lastSaveDirectory: nil)

        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        #expect(
            input.defaultFilename
                == "\(day.string(from: moment)) \u{2013} Quoll Harbor - Vexatron Labs- tide review.pdf")
    }
}
