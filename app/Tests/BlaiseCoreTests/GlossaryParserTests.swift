import Foundation
import Testing
@testable import BlaiseCore

/// G1 AC1 — region extraction + in-region line handling + diagnostics (spec §2, §5b).
@Suite struct GlossaryParserTests {
    // MARK: Helpers

    private func parse(_ text: String) -> (entries: [VocabularyEntry], diagnostics: GlossaryDiagnostics) {
        let r = GlossaryParser.parseRegion(GlossaryParser.extractRegion(text))
        return (r.entries, r.diagnostics)
    }

    private func reasons(_ d: GlossaryDiagnostics) -> [GlossaryDiagnosticReason] {
        d.items.map(\.reason)
    }

    // MARK: Region extraction

    @Test func missingHeadingYieldsEmptyGlossaryAndDiagnostic() {
        let (entries, diag) = parse("# Blaise Glossary\n\nNo entries heading here\n")
        #expect(entries.isEmpty)
        #expect(reasons(diag) == [.noEntriesHeading])
    }

    @Test func regionRunsToEOFWhenNoTerminator() {
        let (entries, _) = parse("## Entries\nAlpha\nBravo\n")
        #expect(entries.map(\.canonical) == ["Alpha", "Bravo"])
    }

    @Test func regionTerminatesAtNextHeading() {
        let (entries, _) = parse("## Entries\nAlpha\n## People\nBravo\n")
        #expect(entries.map(\.canonical) == ["Alpha"])
    }

    @Test func doubleSpaceHeadingDoesNotMatch() {
        // `##  Entries` (two spaces) is not the entries heading.
        let (entries, diag) = parse("##  Entries\nAlpha\n")
        #expect(entries.isEmpty)
        #expect(reasons(diag) == [.noEntriesHeading])
    }

    @Test func lowercaseHeadingDoesNotMatch() {
        let (entries, diag) = parse("## entries\nAlpha\n")
        #expect(entries.isEmpty)
        #expect(reasons(diag) == [.noEntriesHeading])
    }

    @Test func firstEntriesHeadingWins() {
        let text = "## Entries\nAlpha\n## Other\nstray\n## Entries\nBravo\n"
        let (entries, _) = parse(text)
        // Region is between the FIRST `## Entries` and the next `## ` line.
        #expect(entries.map(\.canonical) == ["Alpha"])
    }

    @Test func peopleHeadingTerminatesAndEmitsRegionEndedEarlyWhenEntriesFollow() {
        let text = "## Entries\nAlpha\n## People\nStranded Entry\n"
        let (entries, diag) = parse(text)
        #expect(entries.map(\.canonical) == ["Alpha"])
        // Terminator at line 3; a non-blank, non-# line follows → regionEndedEarly(3).
        #expect(reasons(diag).contains(.regionEndedEarly(line: 3)))
    }

    @Test func trailingHeadingWithOnlyCommentsDoesNotEmitRegionEndedEarly() {
        let text = "## Entries\nAlpha\n## Notes\n# just a comment\n\n"
        let (_, diag) = parse(text)
        #expect(!reasons(diag).contains { if case .regionEndedEarly = $0 { return true }; return false })
    }

    @Test func crlfIdenticalIncludingFieldTrims() {
        let lf = parse("## Entries\nToban | Tobes\nNira\n")
        let crlf = parse("## Entries\r\nToban | Tobes\r\nNira\r\n")
        #expect(lf.entries == crlf.entries)
        #expect(crlf.entries == [
            VocabularyEntry(canonical: "Toban", aliases: ["Tobes"]),
            VocabularyEntry(canonical: "Nira", aliases: []),
        ])
    }

    // MARK: In-region line handling

    @Test func bulletMarkersStripped() {
        let (entries, _) = parse("## Entries\n- Alpha | a1\n* Bravo\n")
        #expect(entries == [
            VocabularyEntry(canonical: "Alpha", aliases: ["a1"]),
            VocabularyEntry(canonical: "Bravo", aliases: []),
        ])
    }

    @Test func commentsAndBlanksIgnored() {
        let (entries, diag) = parse("## Entries\n# a comment\n\nAlpha\n")
        #expect(entries.map(\.canonical) == ["Alpha"])
        #expect(diag.items.isEmpty)
    }

    @Test func markdownArtifactsSkippedWithDiagnostic() {
        let (entries, diag) = parse("## Entries\n```\ncode\n```\n> quote\nAlpha\n")
        #expect(entries.map(\.canonical) == ["code", "Alpha"])
        // Two fence lines + one blockquote = 3 markdownArtifact diagnostics.
        let artifacts = reasons(diag).filter { $0 == .markdownArtifact }
        #expect(artifacts.count == 3)
    }

    @Test func emptyAliasFieldSurvivesEntry() {
        let (entries, diag) = parse("## Entries\nAlpha||a2\n")
        #expect(entries == [VocabularyEntry(canonical: "Alpha", aliases: ["a2"])])
        #expect(reasons(diag).contains(.emptyAlias))
    }

    @Test func emptyCanonicalDiagnostic() {
        let (entries, diag) = parse("## Entries\n|orphan\nAlpha\n")
        #expect(entries.map(\.canonical) == ["Alpha"])
        #expect(reasons(diag).contains(.emptyCanonical))
    }

    @Test func aliasCollidesWithCanonicalSkipsLine() {
        // An alias folding to its own canonical → line skipped.
        let (entries, diag) = parse("## Entries\nAlpha | alpha\nBravo\n")
        #expect(entries.map(\.canonical) == ["Bravo"])
        #expect(reasons(diag).contains(.aliasCollidesWithCanonical))
    }

    @Test func aliasDuplicatedSkipsLine() {
        let (entries, diag) = parse("## Entries\nAlpha | x | X\nBravo\n")
        #expect(entries.map(\.canonical) == ["Bravo"])
        #expect(reasons(diag).contains(.aliasDuplicated))
    }

    @Test func duplicateCanonicalFoldDupFirstWins() {
        let (entries, diag) = parse("## Entries\nZandí\nzandi | z\n")
        // Diacritic + case fold collide; first wins, second dropped.
        #expect(entries.map(\.canonical) == ["Zandí"])
        #expect(reasons(diag).contains(.duplicateCanonical))
    }

    @Test func truncationBoundaryAtTwoThousand() {
        var lines = ["## Entries"]
        for i in 0 ..< (GlossaryParser.entryCap + 5) { lines.append("Entry\(i)") }
        let (entries, diag) = parse(lines.joined(separator: "\n") + "\n")
        #expect(entries.count == GlossaryParser.entryCap)
        guard case .glossaryTruncated(let count)? = reasons(diag).first(where: {
            if case .glossaryTruncated = $0 { return true }; return false
        }) else {
            Issue.record("expected glossaryTruncated")
            return
        }
        #expect(count == 5)
    }

    @Test func prefixClippedToFortyChars() {
        let longCanonical = String(repeating: "x", count: 80)
        let (_, diag) = parse("## Entries\n\(longCanonical) | \(longCanonical)\n")
        // alias collides? no — canonical is x*80, alias x*80 → collides, skipped.
        #expect(diag.items.allSatisfy { $0.prefix.count <= 40 })
    }

    @Test func templateYieldsZeroEffectiveEntries() throws {
        let text = GlossaryTemplate.text
        let (entries, diag) = parse(text)
        #expect(entries.isEmpty)
        // The template's examples are commented out; the region exists.
        #expect(!reasons(diag).contains(.noEntriesHeading))
    }
}
