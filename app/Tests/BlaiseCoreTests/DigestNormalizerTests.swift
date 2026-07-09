import Testing

@testable import BlaiseCore

/// md-v5 `DigestNormalizer` — the pure, last-mile projects-line cleanup. All
/// fixtures are FICTIONAL (no real project/tool names).
@Suite struct DigestNormalizerTests {
    private let digest = """
        ## HEADER
        meeting: Vexatron Labs sync
        date: 2026-01-05
        speaker: Dana Marsh
        projects: Aurora, MemCore, Borealis, aurora, Atlas Reborn
        type: general

        ## DECISIONS
        - Dana Marsh decided MemCore would index the Aurora rollout.
        """

    /// Strips an exact tooling term (case/diacritic-folded) from the projects
    /// line, dedups the rest, and leaves the BODY untouched.
    @Test func stripsToolingFromProjectsLineOnly() {
        let out = DigestNormalizer.normalize(digest, excludeProjects: ["MemCore"])
        let projects = out.split(separator: "\n").first { $0.hasPrefix("projects:") }!
        // MemCore removed; "aurora" deduped into "Aurora"; order preserved.
        #expect(projects == "projects: Aurora, Borealis, Atlas Reborn")
        // The DECISIONS body line that names MemCore is SPARED (body untouched).
        #expect(out.contains("- Dana Marsh decided MemCore would index the Aurora rollout."))
    }

    /// Token-boundary: an exclude term never strips a DISTINCT project whose name
    /// merely contains it as a substring/word.
    @Test func sparesProjectThatMerelyContainsAToolWord() {
        let out = DigestNormalizer.normalize(digest, excludeProjects: ["Atlas"])
        let projects = out.split(separator: "\n").first { $0.hasPrefix("projects:") }!
        // "Atlas Reborn" is a whole distinct entry — NOT stripped by excluding "Atlas".
        #expect(projects.contains("Atlas Reborn"))
    }

    /// Case- and diacritic-insensitive matching.
    @Test func matchingIsCaseAndDiacriticFolded() {
        let d = "## HEADER\nprojects: Memória, Cälü, Real Project\n"
        let out = DigestNormalizer.normalize(d, excludeProjects: ["memoria", "calu"])
        let projects = out.split(separator: "\n").first { $0.hasPrefix("projects:") }!
        #expect(projects == "projects: Real Project")
    }

    /// An empty exclusion list AND a no-duplicate line is an exact no-op.
    @Test func emptyExcludeIsExactNoOp() {
        let d = "## HEADER\nprojects: Aurora, Borealis\ntype: general\n"
        #expect(DigestNormalizer.normalize(d, excludeProjects: []) == d)
    }

    /// Dedup alone (no exclusions) collapses folded duplicates, first wins.
    @Test func dedupsFoldedDuplicates() {
        let d = "## HEADER\nprojects: Aurora, aurora, AURORA, Borealis\n"
        let out = DigestNormalizer.normalize(d, excludeProjects: [])
        let projects = out.split(separator: "\n").first { $0.hasPrefix("projects:") }!
        #expect(projects == "projects: Aurora, Borealis")
    }

    /// If EVERY project entry is excluded, the (now contract-invalid empty)
    /// projects line is dropped entirely rather than left blank.
    @Test func dropsLineWhenAllExcluded() {
        let d = "## HEADER\nmeeting: X\nprojects: MemCore, Quoll\ntype: general\n"
        let out = DigestNormalizer.normalize(d, excludeProjects: ["memcore", "quoll"])
        #expect(!out.contains("projects:"))
        #expect(out.contains("meeting: X"))
        #expect(out.contains("type: general"))
    }

    /// No projects line → unchanged (degenerate HEADER-only digest).
    @Test func noProjectsLineIsUnchanged() {
        let d = "## HEADER\nmeeting: X\ndate: 2026-01-01\n"
        #expect(DigestNormalizer.normalize(d, excludeProjects: ["MemCore"]) == d)
    }

    /// HEADER-bounded: when the HEADER has no `projects:` field, a BODY line that
    /// merely begins with "projects:" is NEVER rewritten — the normalizer touches
    /// only the HEADER envelope, never grounded body prose (md-v5 gauntlet M).
    @Test func bodyProjectsLineIsSpared() {
        let d = """
            ## HEADER
            meeting: X
            type: general

            ## FACTS
            projects: MemCore, Aurora shipped on 2026-01-05.
            """
        // Even with a matching exclude, the body sentence is byte-identical:
        // there is no HEADER projects line, so the normalizer no-ops.
        #expect(DigestNormalizer.normalize(d, excludeProjects: ["MemCore"]) == d)
    }
}
