import Foundation
import Testing

/// F1 Inc2 — C7 / AC9. The durable processing queue is the SINGLE admission path
/// for full-pipeline work. This guard fails if any production code calls
/// `dispatchProcessing` outside the worker's executor closure (in
/// AppEnvironment), so the durability / queue-UI / cancellation / origin
/// guarantees cannot be silently bypassed by a future direct caller.
@Suite struct ProcessingQueueAdmissionGuardTests {
    @Test func dispatchProcessingHasOnlyTheBlessedProductionCaller() throws {
        // Locate app/Sources relative to this test file (compile-time #filePath).
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // BlaiseCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // app
            .appendingPathComponent("Sources")

        let fm = FileManager.default
        let walker = try #require(
            fm.enumerator(at: sources, includingPropertiesForKeys: nil),
            "could not enumerate \(sources.path)")

        var offenders: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard line.contains("dispatchProcessing(") else { continue }
                // Skip comments and the function definition itself.
                if line.hasPrefix("//") || line.hasPrefix("*") { continue }
                if line.contains("func dispatchProcessing") { continue }
                // The ONLY blessed production caller is the queue worker's
                // executor closure, which lives in AppEnvironment.swift.
                if url.lastPathComponent == "AppEnvironment.swift" { continue }
                offenders.append("\(url.lastPathComponent):\(index + 1)  \(line)")
            }
        }

        #expect(
            offenders.isEmpty,
            """
            dispatchProcessing must only be called by the processing-queue worker's \
            executor (AppEnvironment). Route any new producer through \
            processingQueue.enqueue(_, origin:). Unauthorized direct callers:
            \(offenders.joined(separator: "\n"))
            """)
    }
}
