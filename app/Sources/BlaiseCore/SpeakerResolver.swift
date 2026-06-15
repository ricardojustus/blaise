import Foundation
import os

// C4: mechanical cluster→name resolution from an active-speaker timeline
// (C12's output), plus the SINGLE validated application path for both
// mechanical and LLM (C6) name mappings. Pure, deterministic, re-runnable.

/// C12 contract, pinned here (Codable golden-tested). Times are WALL-CLOCK
/// epoch milliseconds — C12 cannot know recording start.
public struct ActiveSpeakerEvent: Codable, Sendable, Equatable {
    public let displayName: String
    /// Meet's stable participant id when scrape-able; nil tolerated.
    public let participantID: String?
    public let startEpochMillis: Int64
    public let endEpochMillis: Int64

    public init(displayName: String, participantID: String?, startEpochMillis: Int64, endEpochMillis: Int64) {
        self.displayName = displayName
        self.participantID = participantID
        self.startEpochMillis = startEpochMillis
        self.endEpochMillis = endEpochMillis
    }

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case participantID = "participant_id"
        case startEpochMillis = "start_epoch_millis"
        case endEpochMillis = "end_epoch_millis"
    }
}

public struct SpeakerHints: Sendable, Equatable {
    public let activeSpeakerEvents: [ActiveSpeakerEvent]?
    /// C7 supplies from `Meeting.startedAt`; events with this nil are
    /// ignored (logged).
    public let recordingStartEpochMillis: Int64?

    public init(activeSpeakerEvents: [ActiveSpeakerEvent]?, recordingStartEpochMillis: Int64?) {
        self.activeSpeakerEvents = activeSpeakerEvents
        self.recordingStartEpochMillis = recordingStartEpochMillis
    }
}

/// `unresolved` = clusters that had ≥ 1 vote but failed dominance, plus
/// clusters whose top name was ambiguous (ambiguous names still contribute
/// vote mass as runner-up — conservative).
public struct SpeakerResolution: Sendable, Equatable {
    public let assignments: [String: String]
    public let unresolved: [String]

    public init(assignments: [String: String], unresolved: [String]) {
        self.assignments = assignments
        self.unresolved = unresolved
    }
}

public enum SpeakerResolver {
    /// Drift sweep bounds/step (clock-skew absorption).
    static let driftSweepSeconds = 2.0
    static let driftStepSeconds = 0.25
    /// Dominance: top vote strictly > 2× runner-up AND ≥ 5 s total.
    static let dominanceFactor = 2.0
    static let dominanceFloorSeconds = 5.0

    private static let logger = Logger(subsystem: BlaiseBundle.identifier, category: "speaker.resolver")

    public static func resolve(
        diarization: [DiarizedSegment], hints: SpeakerHints, audioDuration: Double
    ) -> SpeakerResolution {
        guard let events = hints.activeSpeakerEvents, !events.isEmpty else {
            return SpeakerResolution(assignments: [:], unresolved: [])
        }
        guard let recordingStart = hints.recordingStartEpochMillis else {
            logger.info("active-speaker events ignored: recordingStartEpochMillis is nil")
            return SpeakerResolution(assignments: [:], unresolved: [])
        }

        // Recording-relative seconds.
        let relative: [(name: String, participantID: String?, start: Double, end: Double)] =
            events.map {
                (
                    $0.displayName, $0.participantID,
                    Double($0.startEpochMillis - recordingStart) / 1000.0,
                    Double($0.endEpochMillis - recordingStart) / 1000.0
                )
            }

        // The `unattributed` sentinel never participates and is never named.
        let clusters = diarization.filter { $0.speakerLabel != TranscriptSegment.unattributed }

        let offset = chooseOffset(clusters: clusters, events: relative, audioDuration: audioDuration)

        // Ambiguity: two distinct non-nil participantIDs sharing one
        // displayName make that name ambiguous ONLY if their events overlap
        // in time (time-disjoint same-name ids are a rejoin — one person).
        // nil/non-nil mixtures of one displayName are one key. Offset-shifts
        // are common to all events, so overlap is checked unshifted.
        var ambiguousNames: Set<String> = []
        let byName = Dictionary(grouping: relative, by: { $0.name })
        for (name, group) in byName {
            let identified = group.filter { $0.participantID != nil }
            outer: for i in identified.indices {
                for j in identified.indices where j > i {
                    guard identified[i].participantID != identified[j].participantID else { continue }
                    if min(identified[i].end, identified[j].end)
                        > max(identified[i].start, identified[j].start)
                    {
                        ambiguousNames.insert(name)
                        break outer
                    }
                }
            }
        }

        // Voting: matrix over diarization segments × displayName (the
        // identity key). Overlapping simultaneous events each vote.
        var votes: [String: [String: Double]] = [:]
        for event in relative {
            let start = event.start + offset
            let end = event.end + offset
            if end <= 0 || start >= audioDuration { continue }  // entirely outside
            for cluster in clusters {
                let overlap = min(cluster.endSeconds, end) - max(cluster.startSeconds, start)
                if overlap > 0 {
                    votes[cluster.speakerLabel, default: [:]][event.name, default: 0] += overlap
                }
            }
        }

        var assignments: [String: String] = [:]
        var unresolved: [String] = []
        for (label, nameVotes) in votes.sorted(by: { $0.key < $1.key }) {
            // Deterministic order: vote mass descending, then name.
            let ranked = nameVotes.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            guard let top = ranked.first else { continue }
            let runnerUp = ranked.dropFirst().first?.value ?? 0
            if ambiguousNames.contains(top.key) {
                logger.info("cluster \(label): top name ambiguous (duplicate display name), unresolved")
                unresolved.append(label)
            } else if top.value > dominanceFactor * runnerUp, top.value >= dominanceFloorSeconds {
                assignments[label] = top.key
            } else {
                unresolved.append(label)
            }
        }
        return SpeakerResolution(assignments: assignments, unresolved: unresolved)
    }

    /// ±2 s drift sweep, step 0.25 s, offsets evaluated ascending. Per offset,
    /// events entirely outside [0, audioDuration] are excluded; objective =
    /// total cluster×event overlap; argmax ties → smallest |offset|, then the
    /// earlier offset. Deterministic. (Internal for direct tie-rule testing.)
    static func chooseOffset(
        clusters: [DiarizedSegment],
        events: [(name: String, participantID: String?, start: Double, end: Double)],
        audioDuration: Double
    ) -> Double {
        var bestOffset = 0.0
        var bestObjective = -Double.infinity
        var offset = -driftSweepSeconds
        while offset <= driftSweepSeconds + 1e-9 {
            var objective = 0.0
            for event in events {
                let start = event.start + offset
                let end = event.end + offset
                if end <= 0 || start >= audioDuration { continue }
                for cluster in clusters {
                    let overlap = min(cluster.endSeconds, end) - max(cluster.startSeconds, start)
                    if overlap > 0 { objective += overlap }
                }
            }
            let better =
                objective > bestObjective
                || (objective == bestObjective
                    && (abs(offset) < abs(bestOffset)
                        || (abs(offset) == abs(bestOffset) && offset < bestOffset)))
            if better {
                bestObjective = objective
                bestOffset = offset
            }
            offset += driftStepSeconds
        }
        // Normalize a float-noise offset like -2.0000000000000004 + 8*0.25.
        return (bestOffset * 4).rounded() / 4
    }
}

// MARK: - apply() — the single application path (mechanical + LLM mappings)

extension SpeakerResolution {
    /// Applies `assignments` to the transcript under validation that makes
    /// name invention impossible. ALL validation is callee-side; dependencies
    /// explicitly injected (`suppression` = C5's `SuppressionSet.effective`,
    /// `commonNames` = br_common_names.txt, both folded sets).
    ///
    /// 0. (C11 amendment, C4 v5.3) Segments labeled `user` (the reserved
    ///    mic-track class) are IMMUNE to any mapping: a mapping targeting
    ///    `user` is dropped, and a `user` segment is never modified — no LLM
    ///    proposal can rename the user's own voice.
    /// 1. A mapping may only target cluster labels that exist among the
    ///    segments, never `unattributed`. Violating entries dropped + logged.
    /// 2. A name is allowed iff it is in `attendeeNames ∪ eventNames ∪
    ///    {userName}` (case-insensitive, diacritic-folded), OR it passes the
    ///    transcript-verbatim rule: the FULL name (all tokens, contiguously,
    ///    at token boundaries, folded) occurs in a segment's text AND no
    ///    token is blocked AND the name is ≥ 2 characters. Blocked token =
    ///    (folded) member of the effective suppression set AND NOT a member
    ///    of `commonNames`.
    /// 3. No-overwrite precedence: a segment whose `speakerName` is already
    ///    set is never changed (mechanical wins over LLM; first application
    ///    wins).
    public func apply(
        to segments: [TranscriptSegment],
        attendeeNames: Set<String>,
        eventNames: Set<String>,
        userName: String,
        suppression: Set<String>,
        commonNames: Set<String>
    ) -> [TranscriptSegment] {
        let logger = Logger(subsystem: BlaiseBundle.identifier, category: "speaker.apply")
        let existingLabels = Set(segments.map(\.speakerLabel))
        let allowedFolded = Set(
            (attendeeNames.union(eventNames).union([userName]))
                .map { VocabNormalization.canonicalMode($0) })
        // Folded token streams per segment (token boundaries; a name does not
        // match across segment boundaries).
        let segmentTokens: [[String]] = segments.map { Self.foldedTokens($0.text) }

        var validated: [String: String] = [:]
        for (label, name) in assignments.sorted(by: { $0.key < $1.key }) {
            // Rule 0: the reserved `user` class is immune to any mapping.
            guard label != TranscriptSegment.userLabel else {
                logger.info("dropped mapping for reserved label 'user' (rule 0: mic track immune)")
                continue
            }
            // Rule 1: label must exist and never be the sentinel.
            guard label != TranscriptSegment.unattributed, existingLabels.contains(label) else {
                logger.info("dropped mapping \(label): label missing from transcript or sentinel")
                continue
            }
            // Rule 2: allowed-name.
            let folded = VocabNormalization.canonicalMode(name)
            if allowedFolded.contains(folded) {
                validated[label] = name
                continue
            }
            let nameTokens = Self.foldedTokens(name)
            let blocked = nameTokens.contains { suppression.contains($0) && !commonNames.contains($0) }
            let longEnough = name.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
            let verbatim =
                !nameTokens.isEmpty && !blocked && longEnough
                && segmentTokens.contains { Self.containsContiguous($0, nameTokens) }
            if verbatim {
                validated[label] = name
            } else {
                logger.info("dropped mapping \(label): name not allowed (not in sets, not transcript-verbatim)")
            }
        }
        guard !validated.isEmpty else { return segments }

        return segments.map { segment in
            // Rule 0 (belt-and-braces: `user` segments are named at creation,
            // so no-overwrite already protects them; the label check makes
            // the immunity unconditional).
            guard segment.speakerLabel != TranscriptSegment.userLabel else { return segment }
            // Rule 3: no-overwrite.
            guard segment.speakerName == nil, let name = validated[segment.speakerLabel] else {
                return segment
            }
            var named = segment
            named.speakerName = name
            return named
        }
    }

    /// Folded word tokens (C5 tokenizer: whitespace split, edge punctuation
    /// peeled, apostrophes kept in the core; canonical fold = lowercase +
    /// diacritic fold).
    private static func foldedTokens(_ text: String) -> [String] {
        VocabTokenizer.tokenize(text)
            .map { VocabNormalization.canonicalMode($0.core) }
            .filter { !$0.isEmpty }
    }

    private static func containsContiguous(_ haystack: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start ..< start + needle.count]) == needle { return true }
        }
        return false
    }
}
