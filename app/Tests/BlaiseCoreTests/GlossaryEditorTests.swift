import Foundation
import Testing
@testable import BlaiseCore

/// G1 AC5 — the Settings editor's file-rewrite layer: round-trip add/edit/delete
/// with the four invariants, plus inline `|`/`#` field rejection.
@Suite struct GlossaryEditorTests {
    /// A file with a header, top-of-region comment, a markdown-artifact line,
    /// and three entries — exercises every preserved class.
    private let sample = """
    # Blaise Glossary

    intro prose stays out of the region.

    ## Entries

    # top-of-region comment
    Alpha | a1
    > a stray blockquote (markdown artifact)
    Bravo
    Charlie | c1 | c2

    ## People
    Someone Below
    """

    private func outsideRegion(_ text: String) -> (prefix: String, suffix: String) {
        // Prefix = up to and incl. `## Entries`; suffix = from `## People`.
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        let head = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "## Entries" }!
        let term = lines.firstIndex { $0.hasPrefix("## People") }!
        return (lines[0 ... head].joined(separator: "\n"), lines[term...].joined(separator: "\n"))
    }

    @Test func parsesEntriesInFileOrder() {
        let editor = GlossaryEditor(fileText: sample)
        #expect(editor.rows.map(\.canonical) == ["Alpha", "Bravo", "Charlie"])
        #expect(editor.rows[2].aliases == ["c1", "c2"])
    }

    @Test func noOpSaveKeepsEntriesAndPreservedLines() {
        let editor = GlossaryEditor(fileText: sample)
        let out = editor.serialize()!
        let reparsed = GlossaryEditor(fileText: out)
        // Invariant (2): entries unchanged + ordered.
        #expect(reparsed.rows.map(\.canonical) == ["Alpha", "Bravo", "Charlie"])
        // Invariant (1): outside-region bytes identical.
        #expect(outsideRegion(out).prefix == outsideRegion(sample).prefix)
        #expect(outsideRegion(out).suffix == outsideRegion(sample).suffix)
        // Invariant (3): top-of-region comment preserved.
        #expect(out.contains("# top-of-region comment"))
        // Invariant (4): the markdown-artifact line preserved verbatim, in place.
        #expect(out.contains("> a stray blockquote (markdown artifact)"))
    }

    @Test func addAppendsAtRegionEnd() {
        var editor = GlossaryEditor(fileText: sample)
        editor.add(canonical: "Delta", aliases: ["d1"])
        let out = editor.serialize()!
        let reparsed = GlossaryEditor(fileText: out)
        #expect(reparsed.rows.map(\.canonical) == ["Alpha", "Bravo", "Charlie", "Delta"])
        // Still inside the region (above `## People`).
        #expect(out.range(of: "Delta")!.lowerBound < out.range(of: "## People")!.lowerBound)
        #expect(outsideRegion(out).suffix == outsideRegion(sample).suffix)
    }

    @Test func editInPlace() {
        var editor = GlossaryEditor(fileText: sample)
        let bravoID = editor.rows[1].id
        editor.update(id: bravoID, canonical: "Bravo Renamed", aliases: ["br"])
        let out = editor.serialize()!
        let reparsed = GlossaryEditor(fileText: out)
        #expect(reparsed.rows.map(\.canonical) == ["Alpha", "Bravo Renamed", "Charlie"])
        #expect(reparsed.rows[1].aliases == ["br"])
        // Preserved skip line survives the adjacent edit (invariant 4).
        #expect(out.contains("> a stray blockquote (markdown artifact)"))
    }

    @Test func deleteRemovesRow() {
        var editor = GlossaryEditor(fileText: sample)
        editor.delete(id: editor.rows[0].id)
        let out = editor.serialize()!
        let reparsed = GlossaryEditor(fileText: out)
        #expect(reparsed.rows.map(\.canonical) == ["Bravo", "Charlie"])
        #expect(outsideRegion(out).suffix == outsideRegion(sample).suffix)
    }

    @Test func rejectedAliasEntrySurvivesVerbatimThroughTheEditor() {
        // The editor mirrors RAW entries; an alias the LOAD would reject is still
        // a normal row here and round-trips unchanged.
        let text = "## Entries\nLighthouse | lance\n"
        var editor = GlossaryEditor(fileText: text)
        #expect(editor.rows == [GlossaryRow(canonical: "Lighthouse", aliases: ["lance"])])
        editor.add(canonical: "Other")
        let out = editor.serialize()!
        #expect(GlossaryEditor(fileText: out).rows.map(\.canonical) == ["Lighthouse", "Other"])
        #expect(out.contains("Lighthouse | lance"))
    }

    @Test func fieldRejectionHints() {
        #expect(GlossaryEditor.fieldRejectionHint("Normal Name") == nil)
        #expect(GlossaryEditor.fieldRejectionHint("Has | pipe") != nil)
        #expect(GlossaryEditor.fieldRejectionHint("#comment") != nil)
    }

    // M-4 (round-1): a save with a `|` or leading `#` in ANY field is blocked.
    @Test func firstInvalidFieldFlagsCanonicalAndAlias() {
        #expect(GlossaryEditor.firstInvalidField(in: [
            GlossaryRow(canonical: "Good", aliases: ["fine"]),
        ]) == nil)
        let badCanonical = GlossaryEditor.firstInvalidField(in: [
            GlossaryRow(canonical: "Bad | name", aliases: []),
        ])
        #expect(badCanonical?.field == "Bad | name")
        #expect(badCanonical?.isAlias == false)
        let badAlias = GlossaryEditor.firstInvalidField(in: [
            GlossaryRow(canonical: "Good", aliases: ["#hash"]),
        ])
        #expect(badAlias?.field == "#hash")
        #expect(badAlias?.isAlias == true)
    }

    // M-5 (round-1): a rejected-alias diagnostic is annotated against its OWNING
    // entry row (§5b wording), not silently dropped.
    @Test func rejectedAliasAnnotatedAgainstOwningEntry() {
        var diag = GlossaryDiagnostics()
        diag.add(GlossaryDiagnosticItem(
            line: 5, prefix: "lance", reason: .aliasRejectedUnsafe(reason: "everyday word")))
        diag.add(GlossaryDiagnosticItem(
            line: 6, prefix: "Caco", reason: .canonicalCorrectionLimited))
        let rows = [
            GlossaryRow(canonical: "Lighthouse", aliases: ["lance"]),
            GlossaryRow(canonical: "Caco", aliases: []),
        ]
        let ann = GlossaryEditor.annotations(from: diag, rows: rows)
        // The rejected alias is attributed to Lighthouse, its owner.
        #expect(ann[VocabNormalization.canonicalMode("Lighthouse")]?.contains("lance") == true)
        #expect(ann[VocabNormalization.canonicalMode("Lighthouse")]?.contains("not used") == true)
        // The limited canonical keeps its own note.
        #expect(ann[VocabNormalization.canonicalMode("Caco")]?.contains("note spelling") == true)
    }

    @Test func restoreAppendsEntriesSectionWithoutTouchingExistingText() {
        let headingless = "# Blaise Glossary\n\nNo entries heading here.\n"
        let restored = GlossaryEditor.restoredText(from: headingless)
        #expect(restored.hasPrefix(headingless))
        #expect(restored.contains("## Entries"))
        // The restored file now has a region with zero effective entries.
        let (entries, _, diag) = GlossaryParser.parseRegion(GlossaryParser.extractRegion(restored))
        #expect(entries.isEmpty)
        #expect(!diag.items.contains { $0.reason == .noEntriesHeading })
    }

    // M-3 (round-1): outside-region bytes — INCLUDING line endings — must be
    // identical on a no-op save, even when the file has mixed CRLF/LF endings.
    @Test func mixedLineEndingsPreservedOutsideRegionOnNoOpSave() {
        // CRLF prefix, LF region, CRLF suffix — a realistic agent-edited file.
        let mixed = "# Blaise Glossary\r\n\r\n## Entries\r\nAlpha | a1\nBravo\r\n## People\r\nSomeone Below\r\n"
        let editor = GlossaryEditor(fileText: mixed)
        let out = editor.serialize()!
        // The prefix (up to and including `## Entries\r\n`) is byte-identical.
        #expect(out.hasPrefix("# Blaise Glossary\r\n\r\n## Entries\r\n"))
        // The suffix (terminator line onward) keeps its CRLF endings verbatim.
        #expect(out.hasSuffix("## People\r\nSomeone Below\r\n"))
        // Entries survive and reparse.
        #expect(GlossaryEditor(fileText: out).rows.map(\.canonical) == ["Alpha", "Bravo"])
    }

    // A pure-LF no-op save stays byte-identical end to end (the common case).
    @Test func uniformLFNoOpSaveIsByteIdentical() {
        let text = "# H\n\n## Entries\nAlpha | a1\nBravo\n## People\nBelow\n"
        let out = GlossaryEditor(fileText: text).serialize()!
        #expect(out == text)
    }

    @Test func atomicWriteRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blaise-editor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Glossary.md")
        try GlossaryEditor.writeAtomically(sample, to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == sample)
        // Overwrite an existing file (replaceItemAt path).
        try GlossaryEditor.writeAtomically("## Entries\nNew\n", to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "## Entries\nNew\n")
    }
}
