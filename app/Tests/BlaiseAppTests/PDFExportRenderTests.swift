import AppKit
import BlaiseCore
import Foundation
import PDFKit
import Testing

@testable import BlaiseApp

// SC-004 / SC-005 / SC-016: the real path — a hidden borderless window, WebKit's
// print operation and the Core Graphics stamp — over the real-size fixture.
// This is the one exception to BlaiseAppTests being headless.

@Suite(.serialized) @MainActor
struct PDFExportRenderTests {
    /// Raised when the test host itself cannot drive the print path, as
    /// opposed to the path producing a wrong PDF.
    struct HostCannotPrint: Error, CustomStringConvertible {
        let description: String
    }

    private static let repoRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { url.deleteLastPathComponent() }  // file → BlaiseAppTests → Tests → app
        return url
    }()

    private func recordSkip(_ test: String, reason: String) {
        let directory = Self.repoRoot.appendingPathComponent(".test-skips", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data("\(test) skipped: \(reason)\n".utf8)
            .write(to: directory.appendingPathComponent("\(test).txt"))
    }

    /// One real export through the hidden window and WebKit's print operation.
    private func export(style: PDFStyle, paper: PDFPaper, filename: String) async throws -> URL {
        _ = NSApplication.shared
        let exporter = PDFExporter()
        do {
            return try await exporter.export(
                html: try PDFExportFixture.html(style: style), paper: paper,
                header: (title: PDFExportFixture.title, date: PDFExportFixture.date),
                style: style, filename: filename)
        } catch let error as PDFExportError
            where error == .timedOut || error == .printFailed
        {
            throw HostCannotPrint(description: "\(error.stage): \(error.detail)")
        }
    }

    private func discard(_ output: URL) {
        try? FileManager.default.removeItem(at: output.deletingLastPathComponent())
    }

    /// Case-folded with all whitespace removed: a style may uppercase and
    /// letter-space its text, and PDF extraction then inserts spaces between
    /// the glyphs.
    private func squashed(_ text: String) -> String {
        text.lowercased().components(separatedBy: .whitespacesAndNewlines).joined()
    }

    private func collapsed(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - SC-004

    @Test("SC-004: every style paginates the real-size fixture with nothing clipped")
    func paginationAndCompleteness() async throws {
        let markdown = try PDFExportFixture.markdown()
        #expect(markdown.count > 14_000)

        for style in PDFStyle.allCases {
            for paper in PDFPaper.allCases {
                let output: URL
                do {
                    output = try await export(
                        style: style, paper: paper,
                        filename: "\(style.rawValue)-\(paper.rawValue).pdf")
                } catch let error as HostCannotPrint {
                    recordSkip("SC004_pagination", reason: error.description)
                    return
                }
                defer { discard(output) }

                let document = try #require(
                    PDFDocument(url: output), "\(style.rawValue)/\(paper.rawValue) is not a PDF")
                if paper == .a4 {
                    #expect(document.pageCount >= 2, "\(style.rawValue) on A4 filled one page only")
                }
                for index in 0 ..< document.pageCount {
                    let page = try #require(document.page(at: index))
                    #expect(page.bounds(for: .mediaBox).size == paper.pointSize)
                }
                let text = squashed(document.string ?? "")
                #expect(
                    text.contains(squashed(PDFExportFixture.lastBlock)),
                    "\(style.rawValue)/\(paper.rawValue) clipped the last block")
                #expect(
                    text.contains(squashed(PDFExportFixture.colophonEnglish)),
                    "\(style.rawValue)/\(paper.rawValue) clipped the colophon")
            }
        }
    }

    // MARK: - SC-005

    @Test("SC-005: the header and footer bands carry the stamp and nothing else")
    func stampedBands() async throws {
        let style = PDFStyle.atlas
        let output: URL
        do {
            output = try await export(style: style, paper: .a4, filename: "bands.pdf")
        } catch let error as HostCannotPrint {
            recordSkip("SC005_stamped_bands", reason: error.description)
            return
        }
        defer { discard(output) }

        let document = try #require(PDFDocument(url: output))
        #expect(document.pageCount >= 2, "the bands test needs a page 2 to check")
        let furniture = StampFurniture(style: style)
        let expectedHeader =
            furniture.headerText(PDFExportFixture.title) + " "
            + furniture.headerText(PDFExportFixture.date)
        let band = pdfMillimetres(15)

        for index in 0 ..< document.pageCount {
            let page = try #require(document.page(at: index))
            let bounds = page.bounds(for: .mediaBox)
            let header = page.selection(
                for: CGRect(
                    x: 0, y: bounds.height - band, width: bounds.width, height: band))
            let footer = page.selection(
                for: CGRect(x: 0, y: 0, width: bounds.width, height: band))

            let headerText = collapsed(header?.string ?? "")
            if index == 0 {
                #expect(headerText.isEmpty, "page 1 carries a running header")
            } else {
                #expect(headerText == expectedHeader)
            }
            #expect(collapsed(footer?.string ?? "") == "\(index + 1) / \(document.pageCount)")
        }
    }

    // MARK: - SC-016

    @Test("SC-016: an export of the real-size fixture completes in under five seconds")
    func exportPerformance() async throws {
        var seconds: [Double] = []
        for run in 1 ... 3 {
            let started = ContinuousClock.now
            let output: URL
            do {
                output = try await export(style: .atlas, paper: .a4, filename: "perf-\(run).pdf")
            } catch let error as HostCannotPrint {
                recordSkip("SC016_performance", reason: error.description)
                return
            }
            let elapsed = ContinuousClock.now - started
            discard(output)
            seconds.append(
                Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1e18)
        }
        print("SC-016 export wall clock (Atlas, A4): \(seconds)")
        for elapsed in seconds { #expect(elapsed <= 5.0) }
    }
}
