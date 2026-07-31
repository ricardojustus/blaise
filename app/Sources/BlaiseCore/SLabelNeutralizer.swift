import Foundation

/// G13 — the deterministic floor that keeps a raw diarization label (`S0`,
/// `S1`, …) out of every notes-content surface. the user's ask, verbatim: notes
/// "CANT say S0 … If it CANT tell who said, just make a note on what was said,
/// not use S0 and S1 in notes (its fine in transcripts)."
///
/// `neutralize` is a PURE function (same inputs → same output, no I/O) run as
/// the LAST write to `notes.structured` at each forward mint seam, upstream of
/// the render that produces `summary_markdown`. Two layers:
///
///  1. Name substitution (`NameSubstitution.applyLabelSubstitution`): every
///     label that a resolved speaker mapping ∪ an active `speaker_rename` row
///     names becomes that name — exact, case-sensitive.
///  2. Residual neutralization (the hard floor): any label with no name is
///     mechanically neutralized — in PROSE to a content-free neutral descriptor
///     in the dominant language ("a participant", "another participant", "a
///     third participant" by label index, keeping distinct unknowns distinct);
///     in an action-item OWNER to empty (the honest-empty pattern; the item
///     keeps its text), with the residual surfaced in the report so meeting
///     info can note an unnamed speaker. The neutralizer NEVER invents a name,
///     role, employer, or affiliation — an unresolved speaker is only ever "a
///     participant".
///
/// Engine-agnostic: it strips literal labels regardless of which engine authored
/// the notes, so it holds on the cloud engine AND the local MLX fallback.
public enum SLabelNeutralizer {
    /// One residual surfaced by layer 2: an OWNER field whose label could not be
    /// resolved was emptied. `meeting info` surfaces this as "notes mention an
    /// unnamed speaker"; it carries no invented identity, only the field + the
    /// neutralized label.
    public struct Residual: Sendable, Equatable {
        public let field: String
        public let label: String

        public init(field: String, label: String) {
            self.field = field
            self.label = label
        }
    }

    /// Layer 1 (`labelMap` substitution) then layer 2 (residual neutralization).
    /// Returns the ship-ready notes + the owner residuals (for the substitution
    /// report + meeting-info surfacing). `language` is BCP-47; a `pt*` prefix
    /// selects Portuguese descriptors, anything else English (matching the
    /// renderer's dominant-language rule).
    public static func neutralize(
        notes: NotesStructured, labelMap: [String: String], language: String = "en",
        groundedMLabels: Set<String> = []
    ) -> (notes: NotesStructured, residuals: [Residual]) {
        let groundedMLabels = Set(groundedMLabels.filter(DiarizationLabel.isMicCluster))
        let effectiveLabelMap = labelMap.filter {
            !DiarizationLabel.isMicCluster($0.key) || groundedMLabels.contains($0.key)
        }
        // Layer 1: resolved label → name.
        let substituted = NameSubstitution.applyLabelSubstitution(
            notes: notes, labelMap: effectiveLabelMap,
            groundedMLabels: groundedMLabels)

        // Layer 2: assign each DISTINCT residual label a stable descriptor by
        // label index (numeric order, then lexical), so two distinct unknown
        // speakers stay distinct in prose across every field.
        let descriptors = Descriptors.match(language)
        let order = residualLabelOrder(
            in: substituted, labelMap: effectiveLabelMap,
            groundedMLabels: groundedMLabels)
        var descriptorFor: [String: String] = [:]
        for (i, label) in order.enumerated() {
            descriptorFor[label] = descriptors.prose(index: i)
        }

        var out = substituted
        var residuals: [Residual] = []

        func neutralizeProse(_ value: String) -> String {
            replaceResiduals(
                in: value, labelMap: effectiveLabelMap,
                groundedMLabels: groundedMLabels
            ) { label in
                descriptorFor[label] ?? descriptors.prose(index: 0)
            }
        }
        func neutralizeOwner(_ value: String, _ field: String) -> String {
            var sawResidual: String?
            let cleaned = replaceResiduals(
                in: value, labelMap: effectiveLabelMap,
                groundedMLabels: groundedMLabels
            ) { label in
                sawResidual = label
                return ""  // honest-empty: the item keeps its text, the owner clears
            }
            if let label = sawResidual {
                residuals.append(Residual(field: field, label: label))
                // An owner that was ONLY a label collapses to empty; trim the
                // residue so "" renders as the honest-empty owner.
                return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return cleaned
        }

        if let title = out.title { out.title = neutralizeProse(title) }
        out.summary = neutralizeProse(out.summary)
        out.detailedNotes = neutralizeProse(out.detailedNotes)
        out.decisions = out.decisions.map(neutralizeProse)
        out.actionItems = out.actionItems.map {
            ActionItem(
                owner: neutralizeOwner($0.owner, "action_items.owner"),
                text: neutralizeProse($0.text))
        }
        out.userActionItems = out.userActionItems.map {
            ActionItem(
                owner: neutralizeOwner($0.owner, "user_action_items.owner"),
                text: neutralizeProse($0.text))
        }
        return (out, residuals)
    }

    // MARK: - Flat-string neutralization (G14 — the memory digest)

    /// G14: neutralize every residual diarization label in a FLAT Markdown
    /// string (the memory digest), reusing the same emphasis-aware detector
    /// (`labelRanges`/`labelRegex`) and the same localized `Descriptors` as the
    /// struct-shaped notes neutralizer. The digest has no action-item OWNER
    /// field and no cross-field struct order, so the honest-empty-owner and the
    /// struct-field descriptor-numbering semantics do NOT apply here: every
    /// residual gets the PROSE descriptor, and descriptors are assigned by
    /// first-seen residual order within the single string (so two distinct
    /// unknown speakers stay distinct in reading order). `language` selects the
    /// descriptor language (the digest's dominant language). A label that
    /// `labelMap` resolves is substituted to its name; an unresolved label
    /// becomes a content-free neutral descriptor — never an invented identity.
    public static func neutralizeText(
        _ text: String, labelMap: [String: String] = [:], language: String = "en",
        groundedMLabels: Set<String> = []
    ) -> String {
        let groundedMLabels = Set(groundedMLabels.filter(DiarizationLabel.isMicCluster))
        let effectiveLabelMap = labelMap.filter {
            !DiarizationLabel.isMicCluster($0.key) || groundedMLabels.contains($0.key)
        }
        let ranges = labelRanges(in: text, groundedMLabels: groundedMLabels)
        guard !ranges.isEmpty else { return text }
        let descriptors = Descriptors.match(language)

        // First-seen residual order within the single string → stable distinct
        // descriptors. A resolved label is NOT a residual (it substitutes to
        // its name and consumes no descriptor index).
        var descriptorFor: [String: String] = [:]
        var nextIndex = 0
        for range in ranges {
            let label = String(text[range])
            if effectiveLabelMap[label] != nil { continue }  // resolved → name, no descriptor
            if descriptorFor[label] == nil {
                descriptorFor[label] = descriptors.prose(index: nextIndex)
                nextIndex += 1
            }
        }

        var result = text
        // Replace right-to-left so earlier ranges stay valid.
        for range in ranges.reversed() {
            let label = String(text[range])
            let replacement =
                effectiveLabelMap[label] ?? descriptorFor[label] ?? descriptors.prose(index: 0)
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    // MARK: - Detector (emphasis-aware, case-sensitive)

    /// Every diarization-label occurrence in `text`, as source ranges, EXCLUDING
    /// any token that `labelMap` resolves (those are layer-1 names by the time
    /// layer 2 runs; this is the residual set). Emphasis-aware: markdown
    /// emphasis runs (`_`, `*`, `` ` ``) are token boundaries, so `_S0_` (the
    /// renderer never emits it, but a model authoring underscore italics can)
    /// is detected exactly like `**S0**`.
    static func residualRanges(
        in text: String, labelMap: [String: String], groundedMLabels: Set<String>
    ) -> [Range<String.Index>] {
        labelRanges(in: text, groundedMLabels: groundedMLabels)
            .filter { labelMap[String(text[$0])] == nil }
    }

    /// The label grammar `(?<![A-Za-z0-9])S\d+(?![A-Za-z0-9])`: a capital `S`
    /// then one or more ASCII digits (any count), bounded by non-alphanumeric
    /// characters. `_` is a `\w` char but NOT alphanumeric, so the boundaries
    /// match an underscore-italic `_S0_` while rejecting an identifier-embedded
    /// `S0Helper`/`AS0`/`S0x`; `S` is literal so a lowercase `s0` never matches
    /// (case-sensitive). Markdown emphasis runs (`_ * ` `` ` ``) are
    /// non-alphanumeric, so they act as token boundaries by construction.
    ///
    /// Swift's regex engine has no lookbehind, so the RIGHT boundary is a
    /// lookahead in the pattern and the LEFT boundary is checked against the
    /// preceding character below. The match body is the whole `S\d+` token.
    static var labelRegex: Regex<Substring> { /S[0-9]+(?![A-Za-z0-9])/ }
    static var micLabelRegex: Regex<Substring> { /M[0-9]+(?![A-Za-z0-9])/ }

    /// Every diarization-label occurrence in `text`, as source ranges, in
    /// reading order. Emphasis-aware, case-sensitive (see `labelRegex`).
    static func labelRanges(
        in text: String, groundedMLabels: Set<String> = []
    ) -> [Range<String.Index>] {
        func bounded(
            _ matches: [Regex<Substring>.Match]
        ) -> [Range<String.Index>] {
            matches.compactMap { match in
            let range = match.range
            // Left boundary: the char before the `S` must not be alphanumeric.
            if range.lowerBound > text.startIndex {
                let before = text[text.index(before: range.lowerBound)]
                if isAlphanumericASCII(before) { return nil }
            }
            return range
            }
        }
        let system = bounded(text.matches(of: labelRegex))
        let mic = bounded(text.matches(of: micLabelRegex)).filter {
            groundedMLabels.contains(String(text[$0]))
        }
        return (system + mic).sorted { $0.lowerBound < $1.lowerBound }
    }

    /// True when `text` carries at least one diarization label (any field, the
    /// invariant predicate). Emphasis-aware, case-sensitive.
    public static func containsLabel(
        _ text: String, groundedMLabels: Set<String> = []
    ) -> Bool {
        !labelRanges(in: text, groundedMLabels: groundedMLabels).isEmpty
    }

    private static func isAlphanumericASCII(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber)
    }

    // MARK: - Residual replacement

    /// Replaces every residual label range (right-to-left) using `replacement`.
    private static func replaceResiduals(
        in value: String, labelMap: [String: String], groundedMLabels: Set<String>,
        replacement: (String) -> String
    ) -> String {
        let ranges = residualRanges(
            in: value, labelMap: labelMap, groundedMLabels: groundedMLabels)
        guard !ranges.isEmpty else { return value }
        var result = value
        for range in ranges.reversed() {
            let label = String(value[range])
            result.replaceSubrange(range, with: replacement(label))
        }
        return result
    }

    /// The distinct residual labels across ALL notes fields, ordered by numeric
    /// label index then lexically, so the descriptor a label maps to is stable
    /// across fields ("S0" is always "a participant", "S1" always "another
    /// participant").
    private static func residualLabelOrder(
        in notes: NotesStructured, labelMap: [String: String],
        groundedMLabels: Set<String>
    ) -> [String] {
        var seen = Set<String>()
        var labels: [String] = []
        func scan(_ value: String) {
            for range in residualRanges(
                in: value, labelMap: labelMap, groundedMLabels: groundedMLabels
            ) {
                let label = String(value[range])
                if seen.insert(label).inserted { labels.append(label) }
            }
        }
        notes.title.map(scan)
        scan(notes.summary)
        scan(notes.detailedNotes)
        notes.decisions.forEach(scan)
        for item in notes.actionItems { scan(item.owner); scan(item.text) }
        for item in notes.userActionItems { scan(item.owner); scan(item.text) }
        return labels.sorted { a, b in
            let na = Int(a.dropFirst()) ?? Int.max
            let nb = Int(b.dropFirst()) ?? Int.max
            return na != nb ? na < nb : a < b
        }
    }

    // MARK: - Localized neutral descriptors (dominant language)

    /// Content-free neutral descriptors, by label index. English / Portuguese
    /// only (the renderer's `pt*` → Portuguese, else English rule).
    struct Descriptors {
        let participants: [String]
        let fallback: String

        func prose(index: Int) -> String {
            index < participants.count ? participants[index] : "\(fallback) \(index + 1)"
        }

        static func match(_ language: String) -> Descriptors {
            let primary = language.split(separator: "-").first.map(String.init) ?? language
            return primary.lowercased() == "pt" ? .portuguese : .english
        }

        static let english = Descriptors(
            participants: ["a participant", "another participant", "a third participant"],
            fallback: "participant")

        static let portuguese = Descriptors(
            participants: ["um participante", "outro participante", "um terceiro participante"],
            fallback: "participante")
    }
}
