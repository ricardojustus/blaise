import BlaiseCore
import Foundation
import Observation
import SwiftUI

// G2 §5 — the correct-name flow UI + the §3 substitution-report popover.

extension String {
    /// nil when this string equals `other` (after the substitution engine's
    /// fold-aware comparison falls back to surface equality); else self.
    fileprivate func nilIfEqual(to other: String) -> String? {
        self == other ? nil : self
    }
}

/// G2 §4: the speaker-rename popover (click a speaker label → rename).
struct SpeakerRenamePopover: View {
    let meeting: Meeting
    let speakerLabel: String
    let currentName: String?
    /// L-6: when no diarization artifact exists the rename cannot derive an
    /// anchor and parks `stale` — applied only after the next regenerate. The
    /// copy below tells that truth instead of promising immediate effect.
    var hasDiarizationArtifact = true
    let pipeline: ProcessingPipeline
    @Binding var isPresented: Bool

    @State private var name: String = ""
    @State private var working = false

    /// NH-E: the reserved `unattributed` label is renameable and its rename
    /// applies IMMEDIATELY to every unattributed segment (no cluster to
    /// mis-anchor, survives regeneration verbatim), so its copy states the true
    /// scope and drops the no-diarization regenerate-deferral.
    private var scopeCopy: String {
        if SpeakerRename.isAnchorless(speakerLabel) {
            return "Names every unattributed segment in this meeting and re-mints the record — no re-processing."
        }
        return hasDiarizationArtifact
            ? "Renames the speaker everywhere in this meeting and re-mints the record — no re-processing."
            : "This meeting has no saved diarization yet, so the rename is recorded but takes effect after the next Regenerate."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rename speaker")
                .font(.system(size: 14, weight: .semibold))
            Text("Label \(speakerLabel)\(currentName.map { " · currently “\($0)”" } ?? "")")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
            Text(scopeCopy)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Rename") {
                    working = true
                    Task {
                        _ = try? await pipeline.renameSpeaker(
                            meetingID: meeting.id, speakerLabel: speakerLabel, to: name)
                        working = false
                        isPresented = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || working)
            }
        }
        .padding(16)
        .onAppear { name = currentName ?? "" }
    }
}

/// The §3 substitution report, shown in the notes info popover.
struct SubstitutionReportView: View {
    let entries: [NameSubstitution.ReportEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Name corrections applied")
                .font(.system(size: 13, weight: .semibold))
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .leading, spacing: 1) {
                    Text("“\(entry.original)” → “\(entry.replacement)”")
                        .font(.system(size: 12))
                    Text("\(entry.field) · \(ruleName(entry.rule))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func ruleName(_ rule: Int) -> String {
        switch rule {
        case 1: return "saved correction"
        case 2: return "matched a known name"
        case 3: return "canonical spelling"
        default: return "rule \(rule)"
        }
    }
}

/// Backs the correct-name popover: everyday-aware defaults, occurrence count,
/// the glossary-link admission pre-check, and the pipeline writes.
@MainActor @Observable
final class CorrectNameModel {
    private let database: BlaiseDatabase
    private let pipeline: ProcessingPipeline
    let meeting: Meeting
    let notes: MeetingNotes?
    /// L-5: resolved speaker names from the transcript — a rule-2 pre-fill
    /// candidate alongside attendees and action-item owners.
    let resolvedSpeakers: [String]

    /// The misheard surface the user is correcting (pre-fillable from selection).
    var original: String = ""
    /// The replacement (pre-filled with the unique rule-2 candidate when one exists).
    var replacement: String = ""
    /// Apply to all identical occurrences (default ON for non-everyday, OFF for everyday).
    var applyToAll: Bool = true
    /// Remember this correction (default ON).
    var remember: Bool = true
    /// NH-C position scoping: which occurrence (zero-based, reading order) the
    /// position-scoped confirm fixes when the toggle is OFF — the token the user
    /// pointed at. Defaults to 0 (the first occurrence) when the popover was not
    /// opened from a specific selection.
    var selectedOccurrence: Int = 0
    /// M-4: true when the popover was opened FROM a specific token (the caller
    /// passed its occurrence index), so `selectedOccurrence` is the token the
    /// user pointed at — not a defaulted first occurrence. The provenance-line
    /// entry point passes no token, so this stays false there and the picker
    /// shows the reading-order gap note.
    let openedFromToken: Bool

    var statusMessage: String?

    init(
        meeting: Meeting, notes: MeetingNotes?, database: BlaiseDatabase,
        pipeline: ProcessingPipeline, resolvedSpeakers: [String] = [],
        preselected: String? = nil, preselectedOccurrence: Int? = nil
    ) {
        self.meeting = meeting
        self.notes = notes
        self.database = database
        self.pipeline = pipeline
        self.resolvedSpeakers = resolvedSpeakers
        self.openedFromToken = preselectedOccurrence != nil
        // §5: pre-fill the misheard surface from a text selection when present.
        if let preselected {
            let trimmed = preselected.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                original = trimmed
                surfaceChanged()
            }
        }
        // §5/M-4: when the caller knows the exact occurrence the user invoked
        // from (the tap context), scope to it; default to a single-occurrence
        // fix so the pointed-at token is the one corrected.
        if let preselectedOccurrence {
            selectedOccurrence = preselectedOccurrence
            applyToAll = false
        }
    }

    /// §5: the unique rule-2 candidate for the current `original` among the
    /// meeting's resolved speakers ∪ attendees — used to PRE-FILL `replacement`.
    /// Returns nil when there is no unique candidate (zero or a tie → no pre-fill).
    var rule2Candidate: String? {
        let folded = VocabNormalization.canonicalMode(original)
        guard folded.count >= 4 else { return nil }
        var candidates = Set(meeting.attendees.map(\.name))
        // L-5: resolved speakers from the transcript are rule-2 candidates too.
        candidates.formUnion(resolvedSpeakers)
        if let segs = notes?.structured {
            // Owners already in the notes are also candidate full names.
            candidates.formUnion(segs.actionItems.map(\.owner))
            candidates.formUnion(segs.userActionItems.map(\.owner))
        }
        let context = NameSubstitution.Context(
            store: [], ownerCandidates: Array(candidates),
            commonNames: [], polishCanonicals: [])
        return NameSubstitution.applyToLabel(original, context: context).nilIfEqual(to: original)
    }

    // The everyday test, loaded once (no internal lexicon types leaked).
    private let everydayTest = PipelineVocabulary.everydayTest()

    /// Folded-key everyday membership (governs scope copy + toggle default).
    var isEverydaySurface: Bool {
        let folded = VocabNormalization.canonicalMode(original)
        guard !folded.isEmpty else { return false }
        return everydayTest(folded)
    }

    /// Count of identical occurrences in these notes (whole-word, folded).
    var occurrenceCount: Int {
        guard let structured = notes?.structured, !original.isEmpty else { return 0 }
        let (_, count) = NameSubstitution.applyNoteCorrection(
            notes: structured, original: original, replacement: "_", allOccurrences: true)
        return count
    }

    /// Recompute the everyday-aware toggle default when the surface changes,
    /// reset the position-scoped occurrence, and PRE-FILL the replacement with
    /// the unique rule-2 candidate when the replacement field is still empty.
    func surfaceChanged() {
        applyToAll = !isEverydaySurface
        selectedOccurrence = 0
        if replacement.trimmingCharacters(in: .whitespaces).isEmpty,
            let candidate = rule2Candidate
        {
            replacement = candidate
        }
    }

    /// The honest durability copy (§5 / R4-M3): for an EVERYDAY surface
    /// corrected in prose, remembering does NOT preserve the prose fix.
    var durabilityCopy: String {
        if remember {
            if isEverydaySurface {
                return "Remembered corrections for everyday words apply to owners and speaker labels; this prose fix is for these notes only."
            }
            return "Remembered — this correction will re-apply automatically on future regenerations."
        }
        return "Regenerating will lose this fix unless Remembered."
    }

    /// The scope-consequence copy shown before saving a remembered row (§2/§5).
    var rememberScopeCopy: String? {
        guard remember else { return nil }
        if isEverydaySurface {
            return "“\(VocabNormalization.canonicalMode(original))” is an everyday word — this will apply to owners and speaker labels, not prose."
        }
        return nil
    }

    /// M-5: the "also add to glossary" link shows ONLY when the surface would
    /// pass G1 admission (gates 0a/0b + AliasAdmission + distinctive-core).
    var glossaryLinkEligible: Bool {
        guard !original.isEmpty, !replacement.isEmpty else { return false }
        return PipelineVocabulary.wouldAdmitToGlossary(surface: original, canonical: replacement)
    }

    var canConfirm: Bool {
        !original.trimmingCharacters(in: .whitespaces).isEmpty
            && !replacement.trimmingCharacters(in: .whitespaces).isEmpty
            && occurrenceCount > 0
    }

    /// Confirm: position/occurrence-scoped notes fix, then optionally remember
    /// (the store write may hit a §2(d) conflict — surfaced, local fix kept).
    func confirm() async {
        let count = (try? await pipeline.correctNameInNotes(
            meetingID: meeting.id, original: original, replacement: replacement,
            allOccurrences: applyToAll,
            occurrenceIndex: applyToAll ? nil : selectedOccurrence)) ?? 0
        if count == 0 {
            statusMessage = "No matching name found in these notes."
            return
        }
        if remember {
            let result = try? await pipeline.rememberCorrection(
                mishearedSurface: original, replacement: replacement, sourceMeetingID: meeting.id)
            switch result {
            case .written:
                statusMessage = "Fixed \(count) and remembered."
            case .refusedNoOp:
                statusMessage = "Fixed \(count). (The correction resolves to itself — nothing to remember.)"
            case .refusedConflict(let key, let repl):
                statusMessage = "Fixed \(count) here. Not remembered: conflicts with “\(key) → \(repl)”."
            case .none:
                statusMessage = "Fixed \(count). Could not save the correction."
            }
        } else {
            statusMessage = "Fixed \(count) in these notes only."
        }
    }
}

struct CorrectNamePopover: View {
    @State private var model: CorrectNameModel
    @Binding var isPresented: Bool

    init(
        meeting: Meeting, notes: MeetingNotes?, resolvedSpeakers: [String] = [],
        database: BlaiseDatabase, pipeline: ProcessingPipeline, isPresented: Binding<Bool>,
        preselected: String? = nil, preselectedOccurrence: Int? = nil
    ) {
        _model = State(initialValue: CorrectNameModel(
            meeting: meeting, notes: notes, database: database, pipeline: pipeline,
            resolvedSpeakers: resolvedSpeakers, preselected: preselected,
            preselectedOccurrence: preselectedOccurrence))
        _isPresented = isPresented
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Correct a name")
                .font(.system(size: 14, weight: .semibold))

            VStack(alignment: .leading, spacing: 4) {
                Text("Misheard name in these notes").font(.caption).foregroundStyle(.secondary)
                TextField("e.g. SEMI", text: $model.original)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: model.original) { model.surfaceChanged() }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Correct name").font(.caption).foregroundStyle(.secondary)
                TextField("e.g. Sammy", text: $model.replacement)
                    .textFieldStyle(.roundedBorder)
            }

            if model.occurrenceCount > 0 {
                Toggle(isOn: $model.applyToAll) {
                    Text("Apply to all \(model.occurrenceCount) identical occurrence\(model.occurrenceCount == 1 ? "" : "s") in these notes")
                        .font(.system(size: 12))
                }
                .toggleStyle(.checkbox)
                if model.applyToAll && model.isEverydaySurface {
                    Text("“\(model.original)” is an everyday word — replacing every occurrence may change ordinary prose.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                // NH-C position scoping: when fixing a single occurrence and
                // more than one exists, the user picks WHICH one. M-4 honesty:
                // when the popover is opened from a specific token (preselected),
                // the picker defaults to THAT occurrence; when it is opened from
                // the provenance-line button (no token context — SwiftUI's
                // `.textSelection` exposes no selected-token callback to scope
                // from), it defaults to the FIRST occurrence and the count is
                // shown so the user chooses deliberately.
                if !model.applyToAll && model.occurrenceCount > 1 {
                    Picker("Occurrence", selection: $model.selectedOccurrence) {
                        ForEach(0 ..< model.occurrenceCount, id: \.self) { i in
                            Text("Occurrence \(i + 1) of \(model.occurrenceCount)").tag(i)
                        }
                    }
                    .pickerStyle(.menu)
                    .font(.system(size: 12))
                    if !model.openedFromToken {
                        Text("Counted in reading order (summary → your items → decisions → action items). Pick the one to fix.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if !model.original.isEmpty {
                Text("This name does not appear in these notes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Toggle(isOn: $model.remember) {
                Text("Remember this correction").font(.system(size: 12, weight: .medium))
            }
            .toggleStyle(.checkbox)
            if let scope = model.rememberScopeCopy {
                Text(scope).font(.caption2).foregroundStyle(.secondary)
            }
            Text(model.durabilityCopy)
                .font(.caption2)
                .foregroundStyle(.secondary)

            if model.glossaryLinkEligible {
                Text("This name also qualifies for your glossary — add it from Settings → Glossary to standardize its spelling everywhere.")
                    .font(.caption2)
                    .foregroundStyle(.blue)
            }

            if let status = model.statusMessage {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                // M-2: do NOT close on Confirm — the status (including a §2(d)
                // conflict explanation "Not remembered: conflicts with …") is
                // set by confirm() and must stay visible. The user dismisses
                // with Done/Close once they've read it.
                Button(model.statusMessage == nil ? "Cancel" : "Close") { isPresented = false }
                Button("Confirm") {
                    Task { await model.confirm() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canConfirm)
            }
        }
        .padding(16)
    }
}
