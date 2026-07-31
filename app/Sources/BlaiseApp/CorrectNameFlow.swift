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
    @State private var rejection: String?

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
            if let rejection {
                Text(rejection)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Rename") {
                    rejection = nil
                    working = true
                    Task {
                        do {
                            _ = try await pipeline.renameSpeaker(
                                meetingID: meeting.id, speakerLabel: speakerLabel, to: name)
                            isPresented = false
                        } catch {
                            rejection = error.localizedDescription
                        }
                        working = false
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

/// Backs the correct-name popover: everyday-aware defaults, the two §3.3
/// occurrence quantities/classification, the Remember gate, the glossary-link
/// admission pre-check, and the pipeline writes.
@MainActor @Observable
final class CorrectNameModel {
    private let database: BlaiseDatabase?
    private let pipeline: ProcessingPipeline?
    /// These seams keep the state/copy contract headless-testable without
    /// changing the production pipeline API. Production construction leaves
    /// them nil and uses `pipeline` below.
    private let correctionHandler: ((MeetingID, String, String, Bool, Int?) async -> Int)?
    private let rememberHandler:
        ((String, String, MeetingID?) async throws -> NameCorrectionStore.WriteResult)?
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
    /// True while confirm() is in flight — disables Confirm and the text
    /// fields so the awaited correction and the durable Remember write cannot
    /// race a concurrent edit of the fields (impl-audit I-C2).
    var isConfirming: Bool = false

    init(
        meeting: Meeting, notes: MeetingNotes?, database: BlaiseDatabase? = nil,
        pipeline: ProcessingPipeline? = nil, resolvedSpeakers: [String] = [],
        preselected: String? = nil, preselectedOccurrence: Int? = nil,
        correctionHandler: ((MeetingID, String, String, Bool, Int?) async -> Int)? = nil,
        rememberHandler:
            ((String, String, MeetingID?) async throws -> NameCorrectionStore.WriteResult)? = nil
    ) {
        self.meeting = meeting
        self.notes = notes
        self.database = database
        self.pipeline = pipeline
        self.correctionHandler = correctionHandler
        self.rememberHandler = rememberHandler
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

    /// Replacement-independent §3.1 occurrence identity across these notes.
    /// This is the index domain for the position picker.
    var selectableOccurrenceCount: Int {
        guard let structured = notes?.structured else { return 0 }
        return NameSubstitution.selectableOccurrenceCount(in: structured, original: original)
    }

    /// §3.2-guarded count of occurrences an all-occurrences confirm will
    /// actually replace. This is the quantity shown next to the toggle.
    var replaceableCount: Int {
        guard let structured = notes?.structured else { return 0 }
        return NameSubstitution.replaceableOccurrenceCount(
            in: structured, original: original, replacement: replacement)
    }

    /// Whether the durable G2 store can truthfully remember this correction.
    /// The store matcher remains single-run by contract, so multi-word keys are
    /// intentionally meeting-local.
    var supportsRemember: Bool {
        NameSubstitution.foldedWords(in: original).count == 1
    }

    /// The status reason for the selected identity occurrence. A stale index
    /// is `.absent`; a guard-covered occurrence is `.alreadyCorrect`.
    var selectedOccurrenceClassification: NameSubstitution.OccurrenceClassification {
        guard let structured = notes?.structured else { return .absent }
        return NameSubstitution.classifyNoteOccurrence(
            in: structured, original: original, replacement: replacement,
            occurrenceIndex: selectedOccurrence)
    }

    /// Recompute the everyday-aware toggle default when the surface changes,
    /// reset the position-scoped occurrence, and PRE-FILL the replacement with
    /// the unique rule-2 candidate when the replacement field is still empty.
    func surfaceChanged() {
        applyToAll = !isEverydaySurface
        selectedOccurrence = 0
        // A disabled Toggle preserves its binding. Force the state off at the
        // same transition that makes a multi-word original unsupported.
        if !supportsRemember { remember = false }
        if replacement.trimmingCharacters(in: .whitespaces).isEmpty,
            let candidate = rule2Candidate
        {
            replacement = candidate
        }
    }

    /// The honest durability copy (§5 / R4-M3): for an EVERYDAY surface
    /// corrected in prose, remembering does NOT preserve the prose fix.
    var durabilityCopy: String {
        if NameSubstitution.foldedWords(in: original).count > 1 {
            return "Durable corrections for multi-word names aren't supported yet — this fix applies to these notes only"
        }
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
        guard remember && supportsRemember else { return nil }
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
        guard !original.trimmingCharacters(in: .whitespaces).isEmpty,
            !replacement.trimmingCharacters(in: .whitespaces).isEmpty
        else { return false }
        return applyToAll ? replaceableCount > 0 : selectableOccurrenceCount > 0
    }

    /// Confirm: position/occurrence-scoped notes fix, then optionally remember
    /// (the store write may hit a §2(d) conflict — surfaced, local fix kept).
    ///
    /// Race hardening (impl-audit I-C1/I-C2): the whole request is captured
    /// into immutable locals at entry — the applied correction and the durable
    /// Remember write always describe the SAME edit even if the fields change
    /// mid-await — and the persisted notes are re-fetched and compared against
    /// this model's snapshot before applying, because the position index is
    /// only meaningful against the notes the picker enumerated. Residual: the
    /// check-to-apply gap is not transactional (a pipeline revision token would
    /// need a LOCKED-signature change) — backlogged with trigger.
    func confirm() async {
        guard !isConfirming else { return }
        isConfirming = true
        defer { isConfirming = false }
        let requestOriginal = original
        let requestReplacement = replacement
        let requestApplyToAll = applyToAll
        let requestIndex = applyToAll ? nil : Optional(selectedOccurrence)
        let requestRemember = remember && supportsRemember
        // The zero-count status must describe the REQUEST, not whatever the
        // picker points at when the await returns (impl-audit r2 High):
        // classified here, synchronously, from the same captured state.
        let requestClassification = selectedOccurrenceClassification

        // I-C1 drift guard: the position index (and the counts the user just
        // read) were computed against this model's notes snapshot. If the
        // persisted notes have changed underneath the open popover (a resume
        // or regeneration landing), the index maps to a DIFFERENT occurrence —
        // abort honestly instead of correcting the wrong one.
        if let database, let snapshot = notes?.structured {
            let fresh = try? await NotesRepository(database: database)
                .fetch(meetingID: meeting.id)
            if let fresh, fresh.structured != snapshot {
                statusMessage =
                    "These notes changed since this popover opened — close and reopen to correct."
                return
            }
        }

        let count: Int
        if let correctionHandler {
            count = await correctionHandler(
                meeting.id, requestOriginal, requestReplacement, requestApplyToAll,
                requestIndex)
        } else if let pipeline {
            count = (try? await pipeline.correctNameInNotes(
                meetingID: meeting.id, original: requestOriginal,
                replacement: requestReplacement,
                allOccurrences: requestApplyToAll,
                occurrenceIndex: requestIndex)) ?? 0
        } else {
            count = 0
        }
        if count == 0 {
            statusMessage = !requestApplyToAll
                && requestClassification == .alreadyCorrect
                ? "Already matches the correction."
                : "No matching name found in these notes."
            return
        }
        // Defense in depth: even if a caller mutates state without going
        // through `surfaceChanged`, unsupported multi-word corrections never
        // reach the durable store.
        if requestRemember {
            let result: NameCorrectionStore.WriteResult?
            if let rememberHandler {
                result = try? await rememberHandler(
                    requestOriginal, requestReplacement, meeting.id)
            } else if let pipeline {
                result = try? await pipeline.rememberCorrection(
                    mishearedSurface: requestOriginal, replacement: requestReplacement,
                    sourceMeetingID: meeting.id)
            } else {
                result = nil
            }
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
                    .disabled(model.isConfirming)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Correct name").font(.caption).foregroundStyle(.secondary)
                TextField("e.g. Sammy", text: $model.replacement)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.isConfirming)
            }

            if model.selectableOccurrenceCount > 0 {
                Toggle(isOn: $model.applyToAll) {
                    Text("Apply to all \(model.replaceableCount) identical occurrence\(model.replaceableCount == 1 ? "" : "s") in these notes")
                        .font(.system(size: 12))
                }
                .toggleStyle(.checkbox)
                .disabled(model.isConfirming)
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
                if !model.applyToAll && model.selectableOccurrenceCount > 1 {
                    Picker("Occurrence", selection: $model.selectedOccurrence) {
                        ForEach(0 ..< model.selectableOccurrenceCount, id: \.self) { i in
                            Text("Occurrence \(i + 1) of \(model.selectableOccurrenceCount)").tag(i)
                        }
                    }
                    .pickerStyle(.menu)
                    .font(.system(size: 12))
                    .disabled(model.isConfirming)
                    if !model.openedFromToken {
                        Text("Counted in reading order (title → summary → detailed notes → decisions → action items → your action items; each item counts owner, then text). Pick the one to fix.")
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
            .disabled(!model.supportsRemember || model.isConfirming)
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
                .disabled(!model.canConfirm || model.isConfirming)
            }
        }
        .padding(16)
    }
}
