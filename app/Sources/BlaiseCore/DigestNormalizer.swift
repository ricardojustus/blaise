import Foundation

/// md-v5 deterministic post-step — a PURE, last-mile normalizer over the produced
/// memory-digest string, mirroring the `DigestDateNormalizer` pattern (pure
/// function, runs after the LLM passes, never re-enters a model). It owns the few
/// PRECISION/canonicalization decisions the LLM does unreliably and that are
/// KNOWN/computable in code — here: removing configured non-project terms (the
/// meeting-capture / memory tooling, which the synthesis prompt asks the model to
/// exclude but the model leaks intermittently) from the HEADER `projects:` line.
///
/// SAFETY (per the council's boundary): this NEVER edits body prose — it touches
/// ONLY the single `projects:` envelope line, so a tooling name that legitimately
/// anchors a `## DECISIONS`/`## FACTS` body line (e.g. a meeting ABOUT the memory
/// system) is spared. Matching is token-boundary + case/diacritic-folded against
/// an EXACT term list (never a substring/frequency cut), so it cannot fire on a
/// real project whose name merely contains a tool word. The exclusion list is
/// USER DATA (settings), default empty — there are no real names in this source,
/// and an empty list is an exact no-op.
public enum DigestNormalizer {
    /// Remove every comma-separated entry of the HEADER `projects:` line that
    /// matches (token-boundary, folded) a term in `excludeProjects`, then dedup
    /// the surviving entries (folded) preserving first-occurrence order. Every
    /// other line — and the body — is byte-identical. An empty `excludeProjects`
    /// AND a no-duplicate projects line make this a pure no-op.
    public static func normalize(_ digest: String, excludeProjects: [String]) -> String {
        let exclude = Set(excludeProjects.map(fold).filter { !$0.isEmpty })
        // Split preserving line structure; operate ONLY on the HEADER `projects:`
        // envelope field — bounded to the HEADER block so a grounded BODY line that
        // happens to begin with "projects:" is never rewritten (md-v5 gauntlet M).
        var lines = digest.components(separatedBy: "\n")
        guard let idx = headerProjectsLineIndex(lines) else { return digest }
        let line = lines[idx]
        guard let colon = line.firstIndex(of: ":") else { return digest }
        let prefix = String(line[line.startIndex ... colon]) // up to and incl. the colon
        let valuePart = String(line[line.index(after: colon)...])
        let leadingWS = valuePart.prefix { $0 == " " || $0 == "\t" }

        var kept: [String] = []
        var seen: Set<String> = []
        for raw in valuePart.split(separator: ",", omittingEmptySubsequences: false) {
            let entry = raw.trimmingCharacters(in: .whitespaces)
            if entry.isEmpty { continue }
            let key = fold(entry)
            if key.isEmpty { continue }
            if exclude.contains(key) { continue }            // tooling / non-project → drop
            if !seen.insert(key).inserted { continue }        // dedup (folded)
            kept.append(entry)
        }
        // If nothing survives, drop the projects: line entirely (an empty
        // `projects:` is contract-invalid — the synthesis prompt omits the line
        // when no project is named).
        if kept.isEmpty {
            lines.remove(at: idx)
        } else {
            lines[idx] = prefix + String(leadingWS) + kept.joined(separator: ", ")
        }
        return lines.joined(separator: "\n")
    }

    /// A line is the HEADER projects line when its trimmed form begins with
    /// `projects:` (case-insensitive). The synthesis contract emits exactly one.
    private static func isProjectsLine(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces).lowercased()
        return t.hasPrefix("projects:")
    }

    /// The index of the HEADER `projects:` envelope line, or nil. Scanning is
    /// BOUNDED to the HEADER block: it stops at the first BODY section heading (a
    /// `## …` line other than `## HEADER`), so a body line that merely begins with
    /// "projects:" (e.g. an unbulleted `## FACTS` sentence, emitted when HEADER has
    /// no projects field) is NEVER matched. The normalizer must touch only the
    /// envelope field, never grounded body prose (the council's PURITY boundary).
    private static func headerProjectsLineIndex(_ lines: [String]) -> Int? {
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") {
                let heading = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
                if heading != "header" { return nil } // reached the body — no HEADER projects line
            }
            if isProjectsLine(line) { return i }
        }
        return nil
    }

    /// Case/diacritic-folded comparison key (lowercased, diacritics stripped,
    /// surrounding whitespace already trimmed). Token-boundary is implicit: each
    /// `projects:` entry is a whole comma-separated term, so we compare whole
    /// terms — never a substring of a larger name.
    private static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
    }
}
