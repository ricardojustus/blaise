import BlaiseCore
import Foundation
import PDFKit
import Testing

@testable import BlaiseApp

// SC-013 / SC-015: the exporter's failure paths, gate rule and single flight,
// driven through substituted render and stamp stages so every branch of R-5's
// gate rule can be produced on demand.

@Suite(.serialized) @MainActor
struct PDFExporterTests {
    // MARK: - Harness

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func waitUntil(
        _ description: String, timeout: Duration = .seconds(5), _ condition: () -> Bool
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            if ContinuousClock.now > deadline {
                Issue.record("timed out waiting for \(description)")
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func expectFailure(
        _ expected: PDFExportError, from work: () async throws -> URL
    ) async {
        do {
            let url = try await work()
            Issue.record("expected \(expected) but the export produced \(url.path)")
        } catch let error as PDFExportError {
            #expect(error == expected)
        } catch {
            Issue.record("expected \(expected) but got \(error)")
        }
    }

    private func export(
        _ exporter: PDFExporter, paper: PDFPaper = .a4, style: PDFStyle = .clean,
        filename: String = "notes.pdf", html: String = "<html><body>x</body></html>"
    ) async throws -> URL {
        try await exporter.export(
            html: html, paper: paper, header: (title: "Kickoff Quoll Harbor", date: "21/08/2026"),
            style: style, filename: filename)
    }

    /// A render stage that produces a real, stampable PDF.
    private func stubRender(pages: Int = 2) -> PDFExporter.RenderStage {
        { request in try writeStubPDF(at: request.output, paper: request.paper, pages: pages) }
    }

    @MainActor final class Recorder {
        var html: String?
        var renderOutput: URL?
        var cancelled = false
        var depth = 0
        var maxDepth = 0
        /// The attempt directory each stage invocation was handed — the exact
        /// directory whose removal the cleanup rules are about.
        var directories: [URL] = []

        func note(_ request: PDFExporter.RenderRequest) {
            // The render lands one level below the attempt directory.
            directories.append(
                request.output.deletingLastPathComponent().deletingLastPathComponent())
        }

        func enter() {
            depth += 1
            maxDepth = max(maxDepth, depth)
        }
        func leave() { depth -= 1 }
    }

    /// A latch the test opens, so a fake stage can be held mid-attempt.
    @MainActor final class Latch {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var open = false

        func wait() async {
            if open { return }
            await withCheckedContinuation { waiting.append($0) }
        }

        func openNow() {
            open = true
            for continuation in waiting { continuation.resume() }
            waiting = []
        }
    }

    // MARK: - SC-013 failure paths

    @Test("SC-013: a render failure reports once, logs once and removes the attempt directory")
    func renderFailure() async {
        let recorder = Recorder()
        let exporter = PDFExporter(
            render: { request in
                recorder.note(request)
                throw PDFExportError.renderFailed("the page never loaded")
            },
            stamp: { _ in Issue.record("the stamp stage must not run after a render failure") })

        await expectFailure(.renderFailed("the page never loaded")) {
            try await export(exporter)
        }

        #expect(exporter.reportedOutcomes == [.failed(.renderFailed("the page never loaded"))])
        #expect(exporter.loggedFailures == 1)
        #expect(recorder.directories.count == 1)
        #expect(recorder.directories.allSatisfy { !exists($0) })
    }

    @Test("SC-013: a print timeout with no print operation is terminal at once")
    func printTimeoutBeforeAnyPrintOperation() async {
        let recorder = Recorder()
        let exporter = PDFExporter(
            render: { request in
                recorder.note(request)
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    recorder.cancelled = true
                    throw error
                }
            },
            stamp: { _ in Issue.record("the stamp stage must not run after a timeout") },
            timeout: .milliseconds(50))

        await expectFailure(.timedOut) { try await export(exporter) }

        #expect(exporter.reportedOutcomes == [.failed(.timedOut)])
        #expect(exporter.loggedFailures == 1)
        #expect(recorder.directories.count == 1)
        #expect(recorder.directories.allSatisfy { !exists($0) })
        await waitUntil("the render stage to observe cancellation") { recorder.cancelled }
        #expect(recorder.cancelled)
    }

    @Test("SC-013: an unreadable rendered PDF fails the stamp and removes the directory")
    func stampReadFailureThroughTheExporter() async {
        let recorder = Recorder()
        let exporter = PDFExporter(
            render: { request in
                recorder.note(request)
                try Data("not a PDF".utf8).write(to: request.output)
            })

        await expectFailure(.unreadableRender) { try await export(exporter) }

        #expect(exporter.reportedOutcomes == [.failed(.unreadableRender)])
        #expect(exporter.loggedFailures == 1)
        #expect(recorder.directories.count == 1)
        #expect(recorder.directories.allSatisfy { !exists($0) })
    }

    @Test("SC-013: the stamp step rejects an unreadable source PDF")
    func stampRejectsUnreadableSource() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-stamp-source-\(UUID().uuidString).pdf")
        try Data("not a PDF".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        do {
            try PDFExporter.pdfKitStamp(
                PDFExporter.StampRequest(
                    source: source, destination: source.deletingLastPathComponent()
                        .appendingPathComponent("out.pdf"), paper: .a4,
                    title: "Kickoff Quoll Harbor", date: "21/08/2026", style: .clean))
            Issue.record("expected an unreadable-render failure")
        } catch let error as PDFExportError {
            #expect(error == .unreadableRender)
        }
    }

    @Test("SC-013: the stamp step rejects an unwritable destination")
    func stampRejectsUnwritableDestination() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-stamp-source-\(UUID().uuidString).pdf")
        try writeStubPDF(at: source, paper: .a4, pages: 1)
        defer { try? FileManager.default.removeItem(at: source) }
        let destination = URL(fileURLWithPath: "/pdf-export-no-such-dir-\(UUID().uuidString)/x.pdf")

        do {
            try PDFExporter.pdfKitStamp(
                PDFExporter.StampRequest(
                    source: source, destination: destination, paper: .a4,
                    title: "Kickoff Quoll Harbor", date: "21/08/2026", style: .clean))
            Issue.record("expected an unwritable-output failure")
        } catch let error as PDFExportError {
            #expect(error == .unwritableOutput)
        }
    }

    // MARK: - SC-015 snapshot, gate and single flight

    @Test("SC-015(a): the exporter renders only the HTML it was handed")
    func exporterUsesOnlyTheHandedInput() async throws {
        let recorder = Recorder()
        let exporter = PDFExporter(
            render: { request in
                recorder.html = request.html
                try writeStubPDF(at: request.output, paper: request.paper, pages: 1)
            })
        var handed = try PDFExportFixture.html(style: .clean)
        let snapshot = handed

        let output = try await export(exporter, html: snapshot)
        defer { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }
        handed = "a later edit the attempt must never see"

        #expect(recorder.html == snapshot)
        #expect(handed != snapshot)
    }

    @Test("SC-015(a): Letter rewrites the page rule and leaves the notes alone")
    func letterRewritesOnlyThePageSize() async throws {
        let recorder = Recorder()
        let exporter = PDFExporter(
            render: { request in
                recorder.html = request.html
                try writeStubPDF(at: request.output, paper: request.paper, pages: 1)
            })
        // A document that talks about paper on both sides of the stylesheet:
        // the title is emitted above it, the sentence below, and both must
        // survive verbatim.
        let title = "Status size:A4 checkpoint"
        let sentence = "The print run stays size:A4 until the trial closes."
        let front = FrontBlock(
            title: title, dateText: PDFExportFixture.date, timeText: "14:00\u{2013}15:10",
            attendeesText: "Marina Solano", kicker: "Meeting notes")
        let snapshot = try NotesPDFDocument.html(
            markdown: "## Summary\n\n\(sentence)\n", front: front,
            style: .atlas, colophon: true, language: "en")
        let before = snapshot.components(separatedBy: "size:A4").count - 1
        #expect(before >= 3, "the title, the rule and the sentence")
        #expect(snapshot.contains("@page{size:A4"))

        let output = try await export(exporter, paper: .letter, style: .atlas, html: snapshot)
        defer { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }

        let handed = try #require(recorder.html)
        #expect(handed.contains("@page{size:Letter"), "the page rule is the one that changed")
        // The title is emitted twice and the rewrite reaches the first
        // occurrence, so the <title> element is the copy that can be lost.
        #expect(
            handed.contains("<title>\(title)</title>"), "the meeting title is not rewritten")
        #expect(handed.contains(sentence), "the notes are not rewritten")
        #expect(
            handed.components(separatedBy: "size:A4").count - 1 == before - 1,
            "only the rule changed")
    }

    @Test("SC-013: an output named like the internal render file exports on its own path")
    func outputNamedLikeTheRenderFileExports() async throws {
        let recorder = Recorder()
        let exporter = PDFExporter(
            render: { request in
                recorder.renderOutput = request.output
                try writeStubPDF(at: request.output, paper: request.paper, pages: 2)
            })

        let output = try await export(exporter, filename: ".render.pdf")
        defer { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }

        #expect(output.lastPathComponent == ".render.pdf")
        #expect(
            recorder.renderOutput != output,
            "the render stage never writes the file the stamp will read into")
        #expect(exporter.reportedOutcomes == [.succeeded(output)])
        #expect(exporter.loggedFailures == 0)
        let stamped = try #require(PDFDocument(url: output))
        #expect(stamped.pageCount == 2)
    }

    @Test("SC-015(b): two concurrent attempts get two directories and both complete")
    func concurrentAttemptsGetDistinctDirectories() async throws {
        let exporter = PDFExporter(render: stubRender())

        async let first = export(exporter, filename: "first.pdf")
        async let second = export(exporter, filename: "second.pdf")
        let outputs = try await [first, second]
        defer {
            for output in outputs {
                try? FileManager.default.removeItem(at: output.deletingLastPathComponent())
            }
        }

        let directories = Set(outputs.map { $0.deletingLastPathComponent().lastPathComponent })
        #expect(directories.count == 2)
        for output in outputs {
            #expect(FileManager.default.fileExists(atPath: output.path))
        }
        #expect(exporter.reportedOutcomes.count == 2)
        #expect(exporter.loggedFailures == 0)
    }

    @Test("SC-015(c): the first signal of an attempt wins in either order")
    func attemptSignalsAreIdempotent() async {
        let completionFirst = AttemptRace()
        completionFirst.settle(.rendered)
        completionFirst.settle(.timedOut)
        #expect(await completionFirst.wait() == .rendered)

        let timeoutFirst = AttemptRace()
        timeoutFirst.settle(.timedOut)
        timeoutFirst.settle(.rendered)
        #expect(await timeoutFirst.wait() == .timedOut)
    }

    @Test("SC-015(c): completion before the timeout yields exactly one outcome")
    func completionThenTimeoutReportsOnce() async throws {
        let exporter = PDFExporter(render: stubRender(), timeout: .seconds(5))

        let output = try await export(exporter)
        defer { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }
        // Outlive the timeout that lost the race.
        try await Task.sleep(for: .milliseconds(200))

        #expect(exporter.reportedOutcomes == [.succeeded(output)])
        #expect(exporter.loggedFailures == 0)
    }

    @Test("SC-015(c): a timeout with a print operation pending holds the gate until it finishes")
    func timeoutWithPrintOperationPendingHoldsTheGate() async throws {
        let recorder = Recorder()
        let latch = Latch()
        let exporter = PDFExporter(
            render: { request in
                recorder.note(request)
                request.printOperationStarted()
                await latch.wait()
                try writeStubPDF(at: request.output, paper: request.paper, pages: 1)
            },
            timeout: .milliseconds(50))

        await expectFailure(.timedOut) { try await export(exporter, filename: "held.pdf") }
        #expect(exporter.reportedOutcomes == [.failed(.timedOut)])
        #expect(exporter.loggedFailures == 1)
        // The attempt directory survives its own timeout: the print operation
        // is still writing into it and AppKit cannot cancel it.
        let held = try #require(recorder.directories.first)
        #expect(exists(held))

        // A second attempt queues behind the gate the held attempt still owns.
        let queued = Task { @MainActor in try await export(exporter, filename: "queued.pdf") }
        try await Task.sleep(for: .milliseconds(100))
        #expect(exporter.reportedOutcomes.count == 1)
        #expect(recorder.directories.count == 1)

        latch.openNow()
        let output = try await queued.value
        defer { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }

        await waitUntil("the held attempt's directory to be removed") { !exists(held) }
        #expect(!exists(held))
        // Cleanup was scoped to the held attempt; the queued one kept its own.
        #expect(exists(output))
        #expect(exporter.reportedOutcomes == [.failed(.timedOut), .succeeded(output)])
        #expect(exporter.loggedFailures == 1)
    }

    @Test("SC-015(d): the exporter never runs two render stages at once")
    func renderStagesNeverOverlap() async throws {
        let recorder = Recorder()
        let exporter = PDFExporter(
            render: { request in
                recorder.enter()
                await Task.yield()
                try writeStubPDF(at: request.output, paper: request.paper, pages: 1)
                recorder.leave()
            })

        async let first = export(exporter, filename: "attempt-1.pdf")
        async let second = export(exporter, filename: "attempt-2.pdf")
        async let third = export(exporter, filename: "attempt-3.pdf")
        async let fourth = export(exporter, filename: "attempt-4.pdf")
        let outputs = try await [first, second, third, fourth]
        defer {
            for output in outputs {
                try? FileManager.default.removeItem(at: output.deletingLastPathComponent())
            }
        }

        #expect(recorder.maxDepth == 1)
        #expect(outputs.count == 4)
        #expect(Set(outputs.map { $0.deletingLastPathComponent() }).count == 4)
    }
}
