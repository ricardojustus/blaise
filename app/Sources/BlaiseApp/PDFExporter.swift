import AppKit
import BlaiseCore
import CoreText
import Foundation
import PDFKit
import Synchronization
import WebKit
import os

// The render half of PDF export: an off-screen WebKit print pass turns the
// self-contained HTML into paginated PDF pages, then a Core Graphics pass
// stamps the running header and page numbers over them. One instance per app
// (AppEnvironment) — `NSPrintOperation.current` is a per-thread singleton, so
// attempts from any window queue behind the same gate.

/// What went wrong in an export attempt. One case per failable step of the
/// path; `errorDescription` is what the sheet shows the user.
enum PDFExportError: Error, LocalizedError, Equatable {
    case attemptDirectory(String)
    case renderFailed(String)
    case printFailed
    case timedOut
    case unreadableRender
    case unwritableOutput
    case pageCountMismatch(expected: Int, produced: Int)

    var errorDescription: String? {
        switch self {
        case .attemptDirectory(let reason):
            return "Blaise couldn't create a temporary folder for the export. (\(reason))"
        case .renderFailed(let reason):
            return "The notes couldn't be laid out for printing. (\(reason))"
        case .printFailed:
            return "The print step didn't produce a PDF."
        case .timedOut:
            return "The export took too long and was stopped."
        case .unreadableRender:
            return "The rendered PDF couldn't be read back."
        case .unwritableOutput:
            return "The PDF couldn't be written."
        case .pageCountMismatch(let expected, let produced):
            return "The finished PDF has \(produced) pages instead of \(expected)."
        }
    }

    /// The failing step, safe to log in the clear (it names no content).
    var stage: String {
        switch self {
        case .attemptDirectory: return "attempt-directory"
        case .renderFailed: return "render"
        case .printFailed: return "print"
        case .timedOut: return "timeout"
        case .unreadableRender: return "stamp"
        case .unwritableOutput: return "write"
        case .pageCountMismatch: return "page-count"
        }
    }

    /// The underlying text. Logged at the default (private) privacy level: it
    /// can carry a filename, and a filename carries the meeting title.
    var detail: String { errorDescription ?? stage }
}

@MainActor
final class PDFExporter {
    /// One attempt's render step. The stage writes a paginated PDF to
    /// `output`; it is substitutable so the gate, timeout and cleanup rules
    /// can be driven without WebKit.
    struct RenderRequest {
        let html: String
        let paper: PDFPaper
        let output: URL
        /// Called by the stage the moment a print operation exists. From then
        /// on the attempt's terminal event is that operation's completion —
        /// there is no cancel API — so the gate and the attempt directory
        /// outlive a timeout.
        let printOperationStarted: @MainActor () -> Void
    }

    /// One attempt's stamp step: `source` (WebKit's pages) plus the furniture,
    /// written to `destination`.
    struct StampRequest {
        let source: URL
        let destination: URL
        let paper: PDFPaper
        let title: String
        let date: String
        let style: PDFStyle
    }

    typealias RenderStage = @MainActor (RenderRequest) async throws -> Void
    typealias StampStage = @MainActor (StampRequest) throws -> Void

    enum AttemptOutcome: Equatable {
        case succeeded(URL)
        case failed(PDFExportError)
    }

    /// One entry per attempt that reported, in report order. The sheet reads
    /// the value `export` returns or throws; this is the record that proves an
    /// attempt reports exactly once whatever order its signals arrive in.
    private(set) var reportedOutcomes: [AttemptOutcome] = []
    /// Log lines emitted for failed attempts — one per failed attempt.
    private(set) var loggedFailures = 0

    private let render: RenderStage
    private let stamp: StampStage
    private let timeout: Duration
    private let logger = Logger(subsystem: BlaiseBundle.identifier, category: "pdf.export")

    private var gateHeld = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(
        render: @escaping RenderStage = PDFExporter.webKitRender,
        stamp: @escaping StampStage = PDFExporter.pdfKitStamp,
        timeout: Duration = .seconds(15)
    ) {
        self.render = render
        self.stamp = stamp
        self.timeout = timeout
    }

    /// Renders and stamps one PDF, returning it at `<attempt dir>/<filename>`.
    /// Attempts are serialised app-wide; a failure throws `PDFExportError`.
    func export(
        html: String, paper: PDFPaper, header: (title: String, date: String), style: PDFStyle,
        filename: String
    ) async throws -> URL {
        await acquireGate()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-export-\(UUID().uuidString)", isDirectory: true)
        // The render lands one level down: the output filename is the user's to
        // edit, and it must not be able to name the file being rendered.
        let scratch = directory.appendingPathComponent("scratch", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: scratch, withIntermediateDirectories: true)
        } catch {
            throw fail(.attemptDirectory(error.localizedDescription), removing: directory)
        }
        let rendered = scratch.appendingPathComponent("render.pdf")
        let stamped = directory.appendingPathComponent(filename)
        // The stylesheets ship `@page{size:A4}` inside `<style>`; Letter is
        // that one substitution and no other, so the document's own text — the
        // title above the stylesheet, the notes below it — is never rewritten.
        var sized = html
        if paper == .letter, let styleStart = sized.range(of: "<style>"),
            let styleEnd = sized.range(
                of: "</style>", range: styleStart.upperBound..<sized.endIndex),
            let pageRule = sized.range(
                of: "size:A4", range: styleStart.upperBound..<styleEnd.lowerBound)
        {
            sized.replaceSubrange(pageRule, with: "size:Letter")
        }

        let printing = Flag()
        let race = AttemptRace()
        let renderTask = Task { @MainActor in
            do {
                try await self.render(
                    RenderRequest(
                        html: sized, paper: paper, output: rendered,
                        printOperationStarted: { printing.value = true }))
                race.settle(.rendered)
            } catch let error as PDFExportError {
                race.settle(.failed(error))
            } catch is CancellationError {
                race.settle(.failed(.timedOut))
            } catch {
                race.settle(.failed(.renderFailed(error.localizedDescription)))
            }
        }
        let timeoutTask = Task { @MainActor in
            try? await Task.sleep(for: self.timeout)
            guard !Task.isCancelled else { return }
            race.settle(.timedOut)
        }
        let outcome = await race.wait()
        timeoutTask.cancel()

        switch outcome {
        case .timedOut where printing.value:
            // A print operation is in flight and AppKit offers no way to stop
            // it: report the failure now, but hold the gate and the directory
            // until it completes, so nothing is pulled out from under it.
            Task { @MainActor in
                _ = await renderTask.result
                try? FileManager.default.removeItem(at: directory)
                self.releaseGate()
            }
            throw fail(.timedOut, removing: nil, releasingGate: false)
        case .timedOut:
            // No print operation yet: the web view is torn down by the render
            // task's cancellation, so a late load can never reach `runModal`.
            renderTask.cancel()
            throw fail(.timedOut, removing: directory)
        case .failed(let error):
            throw fail(error, removing: directory)
        case .rendered:
            break
        }

        do {
            try stamp(
                StampRequest(
                    source: rendered, destination: stamped, paper: paper, title: header.title,
                    date: header.date, style: style))
        } catch let error as PDFExportError {
            throw fail(error, removing: directory)
        } catch {
            throw fail(.unwritableOutput, removing: directory)
        }

        // A successful attempt leaves its directory to the OS: the returned
        // URL lives inside it, and Share and Save both consume that file after
        // `export` returns. Only a failed attempt removes its directory.
        reportedOutcomes.append(.succeeded(stamped))
        releaseGate()
        return stamped
    }

    // MARK: - Gate

    private func acquireGate() async {
        guard gateHeld else {
            gateHeld = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func releaseGate() {
        if waiting.isEmpty {
            gateHeld = false
        } else {
            waiting.removeFirst().resume()
        }
    }

    private func fail(
        _ error: PDFExportError, removing directory: URL?, releasingGate: Bool = true
    ) -> PDFExportError {
        logger.error("PDF export failed at \(error.stage, privacy: .public): \(error.detail)")
        loggedFailures += 1
        reportedOutcomes.append(.failed(error))
        if let directory { try? FileManager.default.removeItem(at: directory) }
        if releasingGate { releaseGate() }
        return error
    }

    // MARK: - Render (WebKit)

    /// The real render stage: an off-screen web view in a hidden borderless
    /// window, printed to `output` through AppKit's save disposition.
    static func webKitRender(_ request: RenderRequest) async throws {
        let paperRect = CGRect(origin: .zero, size: request.paper.pointSize)
        let window = NSWindow(
            contentRect: paperRect, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let webView = WKWebView(frame: paperRect)
        window.contentView = webView
        let waiter = LoadWaiter()
        webView.navigationDelegate = waiter
        defer {
            webView.stopLoading()
            webView.navigationDelegate = nil
            window.contentView = nil
            window.close()
        }

        try await withTaskCancellationHandler {
            try await waiter.wait { webView.loadHTMLString(request.html, baseURL: nil) }
        } onCancel: {
            Task { @MainActor in
                webView.stopLoading()
                webView.navigationDelegate = nil
                waiter.fail(CancellationError())
            }
        }
        try Task.checkCancellation()

        let info = NSPrintInfo()
        info.paperSize = NSSize(width: paperRect.width, height: paperRect.height)
        info.orientation = .portrait
        // CSS `@page` owns the margins; the print path must not add its own.
        info.topMargin = 0
        info.bottomMargin = 0
        info.leftMargin = 0
        info.rightMargin = 0
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = request.output

        let operation = webView.printOperation(with: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        // macOS 26 initialises the print view lazily and crashes on an unsized
        // one; frame it before the run.
        operation.view?.frame = paperRect

        let run = PrintRunWaiter()
        request.printOperationStarted()
        // A plain `run()` yields a blank PDF for a WKWebView.
        let succeeded = await run.wait {
            operation.runModal(
                for: window, delegate: run,
                didRun: #selector(PrintRunWaiter.printOperationDidRun(_:success:contextInfo:)),
                contextInfo: nil)
        }
        guard succeeded, FileManager.default.fileExists(atPath: request.output.path) else {
            throw PDFExportError.printFailed
        }
    }

    // MARK: - Stamp (PDFKit + Core Graphics)

    /// The real stamp stage: every rendered page redrawn into one output
    /// context with the page number, and the running header from page 2.
    static func pdfKitStamp(_ request: StampRequest) throws {
        guard let document = PDFDocument(url: request.source) else {
            throw PDFExportError.unreadableRender
        }
        let pageCount = document.pageCount
        var mediaBox = CGRect(origin: .zero, size: request.paper.pointSize)
        guard let consumer = CGDataConsumer(url: request.destination as CFURL),
            let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { throw PDFExportError.unwritableOutput }

        let furniture = StampFurniture(style: request.style)
        for index in 0 ..< pageCount {
            guard let page = document.page(at: index) else {
                throw PDFExportError.unreadableRender
            }
            context.beginPDFPage(nil)
            context.saveGState()
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()
            // The text matrix is not part of the graphics state.
            context.textMatrix = .identity
            furniture.drawFooter("\(index + 1) / \(pageCount)", in: context, page: mediaBox)
            if index > 0 {
                furniture.drawHeader(
                    title: request.title, date: request.date, in: context, page: mediaBox)
            }
            context.endPDFPage()
        }
        context.closePDF()

        guard let output = PDFDocument(url: request.destination) else {
            throw PDFExportError.unreadableRender
        }
        guard output.pageCount == pageCount else {
            throw PDFExportError.pageCountMismatch(
                expected: pageCount, produced: output.pageCount)
        }
    }
}

extension PDFPaper {
    /// The paper in points — the media box every rendered and stamped page shares.
    var pointSize: CGSize {
        switch self {
        case .a4: return CGSize(width: 595, height: 842)
        case .letter: return CGSize(width: 612, height: 792)
        }
    }
}

/// Millimetres in PDF points.
func pdfMillimetres(_ value: CGFloat) -> CGFloat { value * 72 / 25.4 }

/// The header and footer typography of one style, and how to draw them.
struct StampFurniture {
    private let footerFont: NSFont
    private let headerFont: NSFont
    private let colour: CGColor
    private let inset: CGFloat
    private let uppercaseHeader: Bool
    private let headerTracking: CGFloat

    init(style: PDFStyle) {
        switch style {
        case .atlas:
            footerFont = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
            headerFont = .systemFont(ofSize: 7.5, weight: .regular)
            colour = CGColor(srgbRed: 0x8A / 255, green: 0x84 / 255, blue: 0x77 / 255, alpha: 1)
            inset = pdfMillimetres(18)
            uppercaseHeader = true
            headerTracking = 7.5 * 0.06
        case .ledger:
            footerFont = .monospacedDigitSystemFont(ofSize: 8.5, weight: .regular)
            headerFont = .systemFont(ofSize: 8.5, weight: .medium)
            colour = CGColor(srgbRed: 0x5B / 255, green: 0x60 / 255, blue: 0x68 / 255, alpha: 1)
            inset = pdfMillimetres(16)
            uppercaseHeader = false
            headerTracking = 0
        case .clean:
            footerFont = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
            headerFont = .systemFont(ofSize: 8.5, weight: .regular)
            colour = CGColor(srgbRed: 0x44 / 255, green: 0x44 / 255, blue: 0x44 / 255, alpha: 1)
            inset = pdfMillimetres(22)
            uppercaseHeader = false
            headerTracking = 0
        }
    }

    /// The stamped form of a running-header string, for the tests to expect.
    func headerText(_ text: String) -> String { uppercaseHeader ? text.uppercased() : text }

    func drawFooter(_ text: String, in context: CGContext, page: CGRect) {
        let line = self.line(text, font: footerFont, tracking: 0)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        context.textPosition = CGPoint(
            x: (page.width - width) / 2, y: pdfMillimetres(12))
        CTLineDraw(line, context)
    }

    func drawHeader(title: String, date: String, in context: CGContext, page: CGRect) {
        let baseline = page.height - pdfMillimetres(10)
        let dateLine = self.line(headerText(date), font: headerFont, tracking: headerTracking)
        let dateWidth = CGFloat(CTLineGetTypographicBounds(dateLine, nil, nil, nil))
        // 70 % of the CONTENT width, so a long title can never collide with
        // the right-aligned date.
        let titleLine = truncated(headerText(title), to: (page.width - 2 * inset) * 0.7)

        context.textPosition = CGPoint(x: inset, y: baseline)
        CTLineDraw(titleLine, context)
        context.textPosition = CGPoint(x: page.width - inset - dateWidth, y: baseline)
        CTLineDraw(dateLine, context)
    }

    private func truncated(_ text: String, to width: CGFloat) -> CTLine {
        let line = self.line(text, font: headerFont, tracking: headerTracking)
        guard CTLineGetTypographicBounds(line, nil, nil, nil) > Double(width) else { return line }
        let token = self.line("…", font: headerFont, tracking: headerTracking)
        return CTLineCreateTruncatedLine(line, Double(width), .end, token) ?? line
    }

    private func line(_ text: String, font: NSFont, tracking: CGFloat) -> CTLine {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): colour,
        ]
        if tracking != 0 { attributes[.kern] = tracking }
        let string = NSAttributedString(string: text, attributes: attributes)
        return CTLineCreateWithAttributedString(string as CFAttributedString)
    }
}

// MARK: - Attempt plumbing

/// A one-shot signal: the first of render completion, render failure and
/// timeout wins; every later one is ignored.
@MainActor
final class AttemptRace {
    enum Result: Equatable {
        case rendered
        case failed(PDFExportError)
        case timedOut
    }

    private var continuation: CheckedContinuation<Result, Never>?
    private var settled: Result?

    func wait() async -> Result {
        if let settled { return settled }
        return await withCheckedContinuation { continuation = $0 }
    }

    func settle(_ result: Result) {
        guard settled == nil else { return }
        settled = result
        continuation?.resume(returning: result)
        continuation = nil
    }
}

/// A main-actor box, so a render stage can report that its print operation now
/// exists without the request being mutable.
@MainActor
final class Flag {
    var value = false
}

@MainActor
private final class LoadWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var settled: Swift.Result<Void, Error>?

    func wait(_ start: () -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            if let settled {
                continuation.resume(with: settled)
                return
            }
            self.continuation = continuation
            start()
        }
    }

    func fail(_ error: Error) { finish(.failure(error)) }

    private func finish(_ result: Swift.Result<Void, Error>) {
        guard settled == nil else { return }
        settled = result
        continuation?.resume(with: result)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(.success(()))
    }

    func webView(
        _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
    ) {
        finish(.failure(PDFExportError.renderFailed(error.localizedDescription)))
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(.failure(PDFExportError.renderFailed(error.localizedDescription)))
    }
}

/// AppKit finishes a modal print operation on a secondary thread and calls the
/// didRun selector there, so this waiter is lock-guarded rather than
/// main-actor isolated.
@MainActor
private final class PrintRunWaiter: NSObject {
    private struct State {
        var continuation: CheckedContinuation<Bool, Never>?
        var settled: Bool?
    }

    private let state = Mutex(State())

    func wait(_ start: () -> Void) async -> Bool {
        await withCheckedContinuation { continuation in
            let alreadySettled = state.withLock { state -> Bool? in
                if let settled = state.settled { return settled }
                state.continuation = continuation
                return nil
            }
            if let alreadySettled {
                continuation.resume(returning: alreadySettled)
                return
            }
            start()
        }
    }

    @objc nonisolated func printOperationDidRun(
        _ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?
    ) {
        let continuation = state.withLock { state -> CheckedContinuation<Bool, Never>? in
            guard state.settled == nil else { return nil }
            state.settled = success
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(returning: success)
    }
}
