import AVFoundation
import BlaiseCore
import Pow
import SwiftUI
import os

// Meeting detail: notes rendered NATIVELY from NotesStructured (sections as
// SwiftUI views — markdown bodies through the block-level view, pinned),
// the load-bearing user-action box in the one accent, a transcript tab, regenerate,
// quiet banners, and the live processing overlay.

struct MeetingDetailView: View {
    enum Tab: String, CaseIterable {
        case notes = "Notes"
        case transcript = "Transcript"
    }

    let meetingID: MeetingID

    @Environment(AppEnvironment.self) private var appEnv
    @Environment(AppUIState.self) private var uiState
    @Environment(PipelineActivityHolder.self) private var activity
    @State private var model: MeetingDetailModel?
    @State private var tab: Tab = .notes
    @State private var scrollTarget: Int64?
    @State private var searchTerms: [String] = []
    @State private var notesSearchRequest = 0
    @State private var userActionBoxRequest = 0
    @State private var showInspector = false
    @State private var regenerating = false
    /// G10: the two-step delete confirmation (the user directive).
    @State private var showDeleteConfirm = false
    /// G16: the Delete Audio confirmation — its facts (size, warnings) are
    /// read when the menu item is chosen, before the dialog opens.
    @State private var audioDeletePrompt: AudioDeletePrompt?
    @State private var showAudioDeleteConfirm = false
    /// The export sheet's snapshot, read once when the sheet opens.
    @State private var pdfExportInput: PDFExportInput?
    /// A capture is in flight: a second press must not open a second sheet.
    @State private var pdfExportOpening = false
    /// Fluido: the header's one-shot settle entrance — armed per selection
    /// (this view is recreated via `.id(id)`), disarmed after the first
    /// landing so tab flips never replay it.
    @State private var heroArmed = true

    var body: some View {
        Group {
            if let model {
                DetailContent(
                    model: model, tab: $tab, scrollTarget: $scrollTarget,
                    searchTerms: $searchTerms, notesSearchRequest: notesSearchRequest,
                    userActionBoxRequest: userActionBoxRequest,
                    activeStage: activity.activeRuns[meetingID]?.stage,
                    heroArmed: $heroArmed)
            } else {
                // Pre-model frames render clear over the backdrop below —
                // a spinner here blinked on every meeting swap (local DB
                // loads land within a frame or two).
                Color.clear
            }
        }
        // The direction's reading field lives HERE, not inside the loaded
        // content: this view is recreated per selection (`.id(id)`), and the
        // model loads in a task — a backdrop applied only after loading let
        // the bare window background flash gray for a frame on every swap.
        // The aquarela per-meeting tint still pops in with the meeting (its
        // graphite base is what shows for the loading frame).
        .background {
            Design.paneBackdrop(
                tint: (model?.meeting).map { Design.meetingHue($0.title) }
            )
            .ignoresSafeArea()
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .accessibilityLabel("Detail view mode")
            }
            // G10 §1: Cancel while a run is in flight for THIS meeting.
            if activity.activeRuns[meetingID] != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .cancel) {
                        cancelProcessing()
                    } label: {
                        Label("Cancel", systemImage: "stop.circle")
                    }
                    .help("Stop processing this meeting (finishing the current step)")
                }
            }
            // G10 §1: a cancelled meeting offers Process — the sanctioned exit
            // re-runs the full pipeline (no artifact resume).
            if model?.meeting?.status == .cancelled, activity.activeRuns[meetingID] == nil {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        regenerate()  // dispatchProcessing flips cancelled → process class
                    } label: {
                        Label("Process", systemImage: "play.circle")
                    }
                    .disabled(regenerating || audioDeleted)
                    .help(
                        audioDeleted
                            ? Self.audioDeletedReprocessHelp
                            : "Re-run transcription and notes from the retained audio")
                }
            }
            // Export is a primary user action, so it stands on its own rather
            // than joining the maintenance menu below.
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    openPDFExport()
                } label: {
                    Label("Export PDF", systemImage: "arrow.down.doc")
                }
                .disabled(model?.notes == nil)
                .help("Export these notes as a PDF")
            }
            // Keep the toolbar's hierarchy calm: the current view and any
            // active Cancel/Process action stay direct; maintenance, info, and
            // destructive actions live together here instead of competing as
            // three equally prominent icon buttons.
            ToolbarItem(placement: .secondaryAction) {
                Menu {
                    Button {
                        regenerate()
                    } label: {
                        Label("Regenerate", systemImage: "arrow.clockwise")
                    }
                    .disabled(
                        regenerating || activity.activeRuns[meetingID] != nil || audioDeleted)
                    .help(audioDeleted ? Self.audioDeletedReprocessHelp : "")

                    Button {
                        showInspector.toggle()
                    } label: {
                        Label("Meeting Info", systemImage: "info.circle")
                    }

                    // G10 §2: Delete (with the two-step confirm). Refused only
                    // for a recording meeting; an in-flight run resolves via
                    // Cancel & Delete in the dialog.
                    if model?.meeting?.status != .recording {
                        Divider()
                        // G16: Delete Audio keeps the transcript and notes.
                        // Offered only once capture is over and while the
                        // audio is still retained.
                        if let meeting = model?.meeting, meeting.status != .paused,
                            meeting.audioDeletedAt == nil
                        {
                            Button(role: .destructive) {
                                requestAudioDelete()
                            } label: {
                                Label("Delete Audio…", systemImage: "waveform.slash")
                            }
                        }
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label("Delete Meeting…", systemImage: "trash")
                        }
                    }
                } label: {
                    Label("Meeting Actions", systemImage: "ellipsis.circle")
                }
                .help("Regenerate, view meeting info, delete audio, or delete")
            }
        }
        .confirmationDialog(
            deleteDialogTitle,
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            // Cancel & Delete when a run is in flight; plain Delete otherwise.
            if activity.activeRuns[meetingID] != nil {
                Button("Cancel & Delete", role: .destructive) { cancelAndDelete() }
            } else {
                Button("Delete", role: .destructive) { deleteMeeting() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This permanently deletes the recording, transcript, and notes from this Mac. Copies already delivered to your Evidence Store are not affected."
            )
        }
        .confirmationDialog(
            audioDeleteDialogTitle,
            isPresented: $showAudioDeleteConfirm,
            titleVisibility: .visible,
            presenting: audioDeletePrompt
        ) { _ in
            Button("Delete Audio", role: .destructive) { deleteAudio() }
            Button("Cancel", role: .cancel) {}
        } message: { prompt in
            Text(prompt.message)
        }
        .popover(isPresented: $showInspector) {
            if let model {
                MeetingInspector(model: model)
                    .padding(16)
                    .frame(width: 300)
            }
        }
        .task(id: meetingID) {
            let detail = MeetingDetailModel(database: appEnv.database, meetingID: meetingID)
            detail.start()
            model = detail
            // N4: this meeting now has a live reading session, so its settle
            // waits out the idle window instead of firing at once.
            await appEnv.pipeline.settleViewAttached(meetingID)
        }
        .onDisappear {
            model?.stop()
            // The session is over: the settle chain runs now (unless the app is
            // terminating, which the pipeline's own flag decides).
            let pipeline = appEnv.pipeline
            let id = meetingID
            Task { await pipeline.settleViewDetached(id) }
        }
        .sheet(item: $pdfExportInput) { input in
            PDFExportSheet(
                input: input, exporter: appEnv.pdfExporter, settings: appEnv.settings)
        }
        .onChange(of: uiState.pdfExportRequest) {
            guard
                consumePDFExportRequest(
                    uiState: uiState, meetingID: meetingID, hasNotes: model?.notes != nil,
                    sheetPresented: pdfExportInput != nil || pdfExportOpening)
            else { return }
            openPDFExport()
        }
        .onChange(of: uiState.detailRequest) {
            applyDetailRequest()
        }
        .onAppear { applyDetailRequest() }
    }

    /// The export works from ONE read of the stores, taken here.
    private func openPDFExport() {
        guard pdfExportInput == nil, !pdfExportOpening else { return }
        pdfExportOpening = true
        let database = appEnv.database
        let id = meetingID
        Task {
            pdfExportInput = try? await PDFExportInput.capture(database: database, meetingID: id)
            pdfExportOpening = false
        }
    }

    private func applyDetailRequest() {
        guard let request = uiState.detailRequest, request.meetingID == meetingID else { return }
        searchTerms = request.searchTerms
        switch request.target {
        case .notes:
            tab = .notes
            notesSearchRequest += 1
        case .userActions:
            tab = .notes
            userActionBoxRequest += 1  // scroll to the user-action box
        case .transcript(let segmentID):
            tab = .transcript
            scrollTarget = segmentID
        }
        uiState.detailRequest = nil
    }

    private func regenerate() {
        regenerating = true
        let queue = appEnv.processingQueue
        let id = meetingID
        Task {
            // F1 Inc2: the user's Process / Regenerate ENQUEUES (origin .user →
            // refuseCancelled=false, so a cancelled meeting's Process re-runs it).
            // The worker drives the unchanged dispatchProcessing on the chain.
            await queue.enqueue(id, origin: .user)
            regenerating = false
        }
    }

    // G10 §2: the two-step confirm dialog title — meeting name + date (the
    // the user directive: name what is being deleted).
    private var deleteDialogTitle: String {
        guard let meeting = model?.meeting else { return "Delete this meeting?" }
        let date = meeting.startedAt.formatted(date: .abbreviated, time: .omitted)
        return "Delete “\(meeting.title)” (\(date))?"
    }

    /// The meeting's audio is gone: nothing can be re-transcribed.
    private var audioDeleted: Bool { model?.meeting?.audioDeletedAt != nil }

    static let audioDeletedReprocessHelp =
        "The audio was deleted, so this meeting can't be re-transcribed. Re-write the notes still works."

    // G16: the Delete Audio dialog title names the meeting exactly as the
    // Delete Meeting dialog does.
    private var audioDeleteDialogTitle: String {
        guard let meeting = model?.meeting else { return "Delete the audio for this meeting?" }
        let date = meeting.startedAt.formatted(date: .abbreviated, time: .omitted)
        return "Delete audio for “\(meeting.title)” (\(date))?"
    }

    /// Reads the §2 verdict and this meeting's audio size, then opens the
    /// confirmation. A refusal skips the dialog: `deleteAudio` re-checks and
    /// reports it through the usual action-error banner.
    private func requestAudioDelete() {
        let env = appEnv
        let id = meetingID
        Task {
            async let eligibilityResult = env.audioEligibility(meetingID: id)
            async let usageResult = env.audioUsage()
            let (eligibility, usage) = await (eligibilityResult, usageResult)
            switch eligibility {
            case .eligible(let warnings):
                let bytes = usage?.entries.first { $0.meetingID == id }?.bytes ?? 0
                audioDeletePrompt = AudioDeletePrompt(bytes: bytes, warnings: warnings)
                showAudioDeleteConfirm = true
            case .refused, nil:
                await env.deleteAudio(meetingID: id)
            }
        }
    }

    /// The meeting row's mark flips via the pipeline's targeted UPDATE; the
    /// model's ValueObservation re-delivers the meeting, so the header,
    /// menu, and inspector refresh without an explicit reload.
    private func deleteAudio() {
        let env = appEnv
        let id = meetingID
        Task { await env.deleteAudio(meetingID: id) }
    }

    private func cancelProcessing() {
        let env = appEnv
        let id = meetingID
        Task { await env.cancelProcessing(meetingID: id) }
    }

    private func deleteMeeting() {
        let env = appEnv
        let id = meetingID
        Task { await env.deleteMeeting(meetingID: id) }
    }

    private func cancelAndDelete() {
        let env = appEnv
        let id = meetingID
        Task { await env.cancelAndDelete(meetingID: id) }
    }
}

/// The facts the Delete Audio confirmation states.
private struct AudioDeletePrompt {
    let bytes: Int64
    let warnings: [AudioDeletionWarning]

    var message: String {
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        var text =
            "This frees \(size) on this Mac. The transcript and notes are kept, but the meeting can no longer be regenerated or played back. Copies already delivered to your Evidence Store are not affected."
        if warnings.contains(.cannotRetry) { text += " It can no longer be retried." }
        if warnings.contains(.pendingAudioDelivery) {
            text += " Its pending delivery will be sent without audio."
        }
        return text
    }
}

/// G16: the "audio deleted" caption shared by the header and the inspector.
func audioDeletedDescription(_ meeting: Meeting) -> String? {
    guard let deletedAt = meeting.audioDeletedAt else { return nil }
    let date = deletedAt.formatted(date: .abbreviated, time: .omitted)
    if meeting.audioDeletedReason == .cap {
        return "Audio deleted automatically on \(date) to stay under the storage limit — transcript and notes kept"
    }
    return "Audio deleted on \(date) — transcript and notes kept"
}

// MARK: - Content

private struct DetailContent: View {
    @Bindable var model: MeetingDetailModel
    @Binding var tab: MeetingDetailView.Tab
    @Binding var scrollTarget: Int64?
    @Binding var searchTerms: [String]
    var notesSearchRequest = 0
    var userActionBoxRequest = 0
    let activeStage: PipelineStage?
    @Binding var heroArmed: Bool

    var body: some View {
        ZStack {
            if let meeting = model.meeting {
                switch tab {
                case .notes:
                    NotesPane(
                        meeting: meeting, notes: model.notes,
                        resolvedSpeakers: model.resolvedSpeakerNames,
                        doneActionKeys: model.doneActionKeys,
                        searchTerms: searchTerms, searchRequest: notesSearchRequest,
                        userActionBoxRequest: userActionBoxRequest,
                        heroArmed: $heroArmed)
                case .transcript:
                    TranscriptPane(
                        meeting: meeting,
                        segments: model.segments, renames: model.speakerRenames,
                        artifactPresence: model.diarizationArtifactPresence,
                        scrollTarget: $scrollTarget, searchTerms: searchTerms,
                        portuguese: (meeting.dominantLanguage ?? "").lowercased().hasPrefix("pt"))
                }
            } else if !model.loaded {
                // First observation delivery still in flight: stay clear
                // over the backdrop (no placeholder flash on meeting swap).
                Color.clear
            } else {
                // After a load reported no meeting (or the observation
                // failed — `loaded` flips true there too, so this pane never
                // stays blank forever). Styled like the no-selection state.
                DirectionUnavailableView(title: "Meeting Not Found", systemImage: "questionmark")
            }
        }
        // (The direction's backdrop is applied by MeetingDetailView, above
        // this content, so the loading placeholder shares it — no gray
        // flash between meetings.)
        .overlay(alignment: .bottom) {
            if let stage = activeStage {
                ProcessingOverlay(stage: stage)
                    .padding(.bottom, 18)
            }
        }
    }
}

// MARK: - Notes pane (native structured rendering)

/// The app-menu full-rewrite banner: nil on success; explicit copy when the
/// rewrite was parked (notes-pending, e.g. no engine configured) or refused.
func rewriteFeedback(_ record: PipelineRunRecord?) -> String? {
    guard let record else {
        return "The notes could not be re-written because the meeting is not ready."
    }
    if record.notesPending != nil {
        // The pipeline's reason is an engineering token (a missing settings
        // key, by name) and never reaches the reader.
        return "The re-write is waiting on the notes engine and will run automatically when it becomes available."
    }
    return nil
}

@MainActor
func saveUnderstandingCorrectionAction(
    save: () async throws -> Void
) async -> String? {
    do {
        try await save()
        return nil
    } catch {
        return "Could not save the correction: \(error.localizedDescription)"
    }
}

@MainActor
func sendToNotesEditorAction(
    meetingID: MeetingID,
    send: (MeetingID) async throws -> Void
) async -> String? {
    do {
        try await send(meetingID)
        return nil
    } catch {
        return "Could not send changes to Notes Editor: \(error.localizedDescription)"
    }
}

/// The honest banner for a saved margin note. nil when the note is already in
/// notes.md and the minted payload. A note written during a run is durable at
/// once, but its re-mint queues behind that run — so the copy says so instead
/// of implying the notes already carry it.
func noteFeedback(remintRefused: Bool, runActive: Bool) -> String? {
    if remintRefused {
        return "Note saved — it will appear in the delivered notes when processing completes."
    }
    if runActive {
        return "Note saved — it appears in the notes when the current run finishes."
    }
    return nil
}

/// What to report when the delete path threw. The row is deleted before the
/// re-mint that publishes the change can throw, so a surviving row is a real
/// failure while a row that is gone was deleted — only its publication lags.
/// `nil` is the third case: the store could not be read, so the outcome is
/// unknown and must be reported as unknown rather than as a delete.
func deleteFeedback(rowSurvived: Bool?, error: any Error) -> String {
    switch rowSurvived {
    case true:
        return "Could not delete: \(error.localizedDescription)"
    case false:
        return "Deleted — the notes could not be re-written just now; they catch up on the next run."
    case nil:
        return "Could not confirm the delete (\(error.localizedDescription)) — reopen the meeting to see whether it is still listed."
    }
}

/// Whether NEW correction/note entry is offered. A row saved while a run holds
/// the meeting is never seen by that run's synthesis (it built its request
/// before the save) — a silent no-op — so the block affordances close for the
/// duration. Management (delete = undo) uses the base availability instead.
func correctionEntryEnabled(available: Bool, runActive: Bool, rewriteBusy: Bool) -> Bool {
    available && !runActive && !rewriteBusy
}

/// The anchor id of one of the reader's OWN action items. Its own prefix, so it
/// can never collide with the meeting-wide action list's.
enum UserActionAnchor {
    static func id(_ index: Int) -> String { "notes-user-action-\(index)" }
}

/// Groups rows by the RENDERED block they belong beside: the one whose text
/// carries the row's quote. `uiTexts` is the pane's own markdown-block list,
/// which is finer than the fold-split anchor space — a bullet list is one anchor
/// block and many rendered blocks — so the quote is re-resolved against what the
/// reader actually sees. A row whose quote matches no rendered block falls to
/// the section's last block, where it still reads correctly because it names its
/// quote.
func rowsByRenderedBlock(
    _ rows: [MeetingCorrection], uiTexts: CorrectionAnchoring.FoldedBlocks
) -> [Int: [MeetingCorrection]] {
    guard !uiTexts.blocks.isEmpty else { return [:] }
    let fallback = uiTexts.blocks.count - 1
    var grouped: [Int: [MeetingCorrection]] = [:]
    for row in rows {
        let index =
            CorrectionAnchoring.resolve(
                quote: row.quotedText, occurrence: row.occurrence, in: uiTexts)?.blockIndex
            ?? fallback
        grouped[index, default: []].append(row)
    }
    return grouped
}

/// The rows of one kind that stand beside each block of a rendered list,
/// grouped by block index. The reading column's own filters decide which rows
/// are on the page at all — an annotation leaves it when it is resolved, a
/// correction when it is applied or resolved — and each survivor is placed on
/// the block its anchor resolves to. A row that resolves to nothing is omitted
/// from the grouping entirely: an unanchored ANNOTATION is surfaced by the
/// "Your notes" tail, which carries annotations only.
func rowsByAnchoredBlock(
    _ rows: [MeetingCorrection], kind: MeetingCorrection.Kind,
    section: MeetingCorrection.Section, blocks: CorrectionAnchoring.FoldedBlocks
) -> [Int: [MeetingCorrection]] {
    var grouped: [Int: [MeetingCorrection]] = [:]
    for row in rows where row.kind == kind && row.section == section {
        switch kind {
        case .annotation:
            guard row.status != .resolved else { continue }
        case .understanding:
            guard row.status != .applied, row.status != .resolved else { continue }
        }
        guard
            let resolved = CorrectionAnchoring.resolve(
                quote: row.quotedText, occurrence: row.occurrence, in: blocks)
        else { continue }
        grouped[resolved.blockIndex, default: []].append(row)
    }
    return grouped
}

private struct NotesPane: View {
    @Environment(AppEnvironment.self) private var appEnv
    @Environment(AppUIState.self) private var uiState
    @Environment(LibraryModel.self) private var library
    // The live pipeline activity — a correction save that races an in-flight
    // run would never be seen by that run's synthesis.
    @Environment(PipelineActivityHolder.self) private var activity
    /// The live margin-note placement + callout state, so a Settings change
    /// re-renders the open notes without a relaunch.
    @Environment(NotesPresentationHolder.self) private var notesPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let meeting: Meeting
    let notes: MeetingNotes?
    /// G2 §5 (L-5): resolved speaker names from the transcript, a rule-2 pre-fill
    /// candidate alongside attendees.
    var resolvedSpeakers: [String] = []
    /// `ActionItemKey`s marked done (live from the detail observation).
    var doneActionKeys: Set<String> = []
    /// Stored FTS spellings to highlight. Display-only; never mutates notes.
    var searchTerms: [String] = []
    /// Monotonic request token so repeated clicks on the same result re-scroll.
    var searchRequest = 0
    var userActionBoxRequest = 0
    /// Fluido: the header's one-shot settle entrance (armed per selection).
    @Binding var heroArmed: Bool
    /// Fluido: one shine sweep when the notes have JUST materialized
    /// (generation finished while watching, or opening a just-ready
    /// meeting) — the CleanShot "result card" moment, rare by construction.
    @State private var shineTick = 0
    /// G2 §3: the substitution report popover.
    @State private var showSubstitutionReport = false
    /// G2 §5: the correct-name popover.
    @State private var showCorrectName = false
    /// G15: the participant-confirmation sheet (opened from the pending banner).
    @State private var showParticipantConfirm = false

    // Correction/note flow state. `correctionRows` mirrors the durable table
    // (loaded on appear, refreshed after every mutation); `correctionBusy` is
    // the in-flight rewrite indicator.
    @State private var editingTarget: EditingTarget?
    /// The composer's typed draft, held here rather than in the composer: the
    /// re-synthesis that reopens the correction gate can take the composing
    /// block out of the notes, and the draft has to outlive its block.
    @State private var composerDraft = ""
    /// The settle-activity debounce clock (N4: at most one signal a second).
    @State private var lastSettleActivitySignal = Date.distantPast
    @State private var correctionRows: [MeetingCorrection] = []
    /// Bumped by every corrections load, so a slower earlier read cannot
    /// overwrite the rows a later one already assigned.
    @State private var correctionLoadGeneration = 0
    @State private var showChangesPanel = false
    @State private var correctionBusy = false
    /// The block the overview last sent the reader to, and the request that
    /// carries them there. The anchor doubles as the arrival mark, cleared once
    /// the reader has had time to see where they landed.
    @State private var navigationAnchor: String?
    @State private var navigationRequest = 0
    /// The words selected in the notes, if any (one block, or a passage
    /// across blocks).
    @State private var selection: BlockSelection?
    /// The block a click picked, and the whole-block target built from it.
    @State private var pickedBlock: BlockSelection?
    /// Block anchor ids whose narrow-mode note chip is expanded.
    @State private var expandedChips: Set<String> = []
    /// The pane's own width: it decides whether the margin rail fits.
    @State private var paneWidth: CGFloat = NotesEditingLayout.railMinimumWidth
    /// The one-text-view document, built only when its text inputs change,
    /// and the scroll requests handed to it.
    @State private var docCache = NotesDocCache()
    @State private var docScroll: NotesDocScrollRequest?
    @State private var docScrollToken = 0
    /// The user-action box's "Completed (n)" disclosure; closed on open.
    @State private var completedExpanded = false

    /// One block an entry path can aim at, carrying the block's own anchor so
    /// every path builds the identical target from it. `span` is the selection
    /// inside the block; empty text means the whole block, which is what a
    /// selection-less invocation anchors to.
    struct BlockSelection: Equatable {
        var blockID: String
        var section: MeetingCorrection.Section
        var blockText: String
        var occurrence: Int
        var span: SelectedSpan
        /// The text the block's host renders, which is the space `span`'s
        /// occurrence was counted in — the same space the wash paints in.
        var hostText: String
        /// A selection across paragraphs: its pieces. The block is then the
        /// anchor block (the last piece's).
        var passage: PassageCapture? = nil
    }

    /// Anchor id for the user-action box ("My Action Items" opens the detail here).
    static let userActionBoxAnchor = "user-action-box"

    var body: some View {
        scrollBody
            .onChange(of: userActionBoxRequest) {
                requestDocScroll(Self.userActionBoxAnchor, center: false)
            }
            .onChange(of: searchRequest) {
                scrollToFirstSearchMatch(animated: true)
            }
            .onChange(of: navigationRequest) {
                guard let anchor = navigationAnchor else { return }
                requestDocScroll(anchor)
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(1600))
                    guard navigationAnchor == anchor else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) {
                        navigationAnchor = nil
                    }
                }
            }
            .onChange(of: editingTarget?.anchorID) { _, anchor in
                if let anchor { scrollComposerIntoView(anchor: anchor) }
            }
            .onAppear {
                if !searchTerms.isEmpty {
                    scrollToFirstSearchMatch(animated: false)
                } else if userActionBoxRequest > 0 {
                    requestDocScroll(Self.userActionBoxAnchor, center: false, animated: false)
                }
            }
            .onChange(of: notes?.generatedAt) { previous, current in
                if Design.direction == .fluido, current != nil, previous != current {
                    shineTick += 1
                }
                if !searchTerms.isEmpty, current != nil {
                    scrollToFirstSearchMatch(animated: false)
                }
            }
            .onChange(of: library.recentlyReady.contains(meeting.id), initial: true) { _, isNew in
                if Design.direction == .fluido, isNew {
                    shineTick += 1
                }
            }
            // G15: the participant-confirmation sheet (opened from the
            // pending banner or the notification).
            .sheet(isPresented: $showParticipantConfirm) {
                ParticipantConfirmSheet(
                    meeting: meeting, env: appEnv, isPresented: $showParticipantConfirm)
            }
    }

    @ViewBuilder
    private var scrollBody: some View {
        if Design.direction == .fluido {
            // Fluido: content slides under the toolbar with a soft scroll
            // edge; extra bottom room clears the floating recording pill.
            scrollCore
                .softTopScrollEdge()
        } else {
            scrollCore
        }
    }

    private var scrollCore: some View {
        Group {
            if let notes {
                documentCore(notes)
            } else {
                noNotesScroll
            }
        }
        .onChange(of: selection) { _, _ in noteSettleActivity() }
        .onChange(of: composerDraft) { _, _ in noteSettleActivity() }
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { paneWidth = $0 }
        .onChange(of: uiState.notesEditingRequest) { _, request in
            applyEditingRequest(request)
        }
        .onChange(of: correctionsAvailable) { _, available in
            // Its host leaves the pane with the chip, so a request left
            // standing would spring the panel open again when the run ends.
            if !available { showChangesPanel = false }
        }
        .onChange(of: editingContext, initial: true) { _, context in
            uiState.notesEditingContext = context
        }
        .onDisappear {
            if uiState.notesEditingContext.meetingID == meeting.id {
                uiState.notesEditingContext = AppUIState.NotesEditingContext()
            }
        }
    }

    /// The notes are one native text view that owns its own
    /// scrolling; the SwiftUI header is placed inside it, above the first
    /// section, so it scrolls with the notes as today.
    private func documentCore(_ notes: MeetingNotes) -> some View {
        // The scroll view runs under the toolbar and insets its content by the
        // toolbar's height: the header rests below the toolbar, and the text
        // scrolls beneath it.
        documentStack(notes)
            .ignoresSafeArea(.container, edges: .top)
    }

    private func documentStack(_ notes: MeetingNotes) -> some View {
        VStack(alignment: .leading, spacing: 0) {
                notesDocument(notes)
                    .task(id: meeting.id) { await loadCorrections() }
                    .onChange(of: notes.structured) { _, _ in
                        // The prose under the aim was just rewritten.
                        selection = nil
                        pickedBlock = nil
                        Task { await loadCorrections() }
                    }
                    .onChange(of: activity.activeRuns[meeting.id] != nil) { was, isNow in
                        if was, !isNow {
                            Task { await loadCorrections() }
                        }
                    }
        }
    }

    private func requestDocScroll(
        _ anchor: String, center: Bool = true, animated: Bool = true, reveal: Bool = false
    ) {
        docScrollToken += 1
        docScroll = NotesDocScrollRequest(
            anchorID: anchor, token: docScrollToken, center: center,
            animated: animated && !reduceMotion, reveal: reveal)
    }

    /// The notes as one text view. The string is rebuilt only when
    /// its text changes; the selection, the composer, the rows and the marks
    /// only move things placed around it.
    private func notesDocument(_ notes: MeetingNotes) -> some View {
        let structured = notes.structured
        let portuguese = (meeting.dominantLanguage ?? "").lowercased().hasPrefix("pt")
        let doc = docCache.document(
            for: NotesDocInput(
                structured: structured, doneKeys: doneActionKeys, searchTerms: searchTerms,
                portuguese: portuguese,
                userActionTitle: userActionSectionTitle(portuguese: portuguese),
                completedExpanded: completedExpanded, direction: Design.direction))
        let rows = docCache.rows(correctionRows, for: doc, structured: structured)
        let composingAnchor = editingTarget.flatMap { target in
            composerPresented(target, inBlockWith: target.anchorID, engineCanEditNotes: engineCanEditNotes)
                && doc.block(target.anchorID) != nil ? target.anchorID : nil
        }
        let aim = commandTarget.flatMap { target -> NotesDocAim? in
            composerPresented(editingTarget, inBlockWith: target.blockID, engineCanEditNotes: engineCanEditNotes)
                ? nil
                : NotesDocAim(
                    anchorID: target.blockID, isSpan: !target.span.text.isEmpty, isPassage: target.passage != nil)
        }
        let bar = commandTarget.map { target in
            NotesDocBarConfig(
                correctionEnabled: correctionsEnabled, engineCanEditNotes: engineCanEditNotes
            ) { kind in
                beginEditing(kind, on: target)
            }
        }
        return NotesDocumentView(
            document: doc, marks: docMarks(rows, pieces: docCache.pieces, composingAnchor: composingAnchor),
            attachments: docAttachments(doc, rows: rows, structured: structured, portuguese: portuguese),
            composingAnchor: composingAnchor,
            rail: layoutMode == .marginRail ? docRail(rows, portuguese: portuguese) : [:],
            railLane: layoutMode == .marginRail, completedExpanded: completedExpanded,
            aim: aim, bar: bar, scrollRequest: docScroll,
            callbacks: NotesDocCallbacks(
                onSelection: { block, span in
                    if let block, let span {
                        selection = BlockSelection(
                            blockID: block.anchorID, section: block.section, blockText: block.blockText,
                            occurrence: block.occurrence, span: span, hostText: block.hostText)
                    } else {
                        selection = nil
                    }
                },
                onPassage: { passage in
                    guard let anchor = passage.pieces.last.flatMap({ doc.block($0.anchorID) }) else { return }
                    selection = BlockSelection(
                        blockID: anchor.anchorID, section: anchor.section, blockText: anchor.blockText,
                        occurrence: 0, span: SelectedSpan(text: passage.quote), hostText: anchor.hostText,
                        passage: passage)
                },
                onPick: { pickDocBlock($0) },
                onClear: { clearAim() },
                onMenuAction: { kind, block, inSelection in
                    // A right-click inside a selection across paragraphs acts on
                    // the whole selection; anywhere else, on the block under it.
                    if inSelection, let passage = selection, passage.passage != nil {
                        guard NotesEditingEntry.allowed(
                            kind, correctionEnabled: correctionsEnabled, engineCanEditNotes: engineCanEditNotes)
                        else { return }
                        beginEditing(kind, on: passage)
                        return
                    }
                    contextMenuInvoke(
                        kind, section: block.section, blockText: block.blockText,
                        occurrence: block.occurrence, blockID: block.anchorID, hostText: Self.shownText(block))
                },
                menuOffers: {
                    (
                        NotesEditingEntry.offered(.correct, engineCanEditNotes: engineCanEditNotes),
                        NotesEditingEntry.allowed(
                            .correct, correctionEnabled: correctionsEnabled,
                            engineCanEditNotes: engineCanEditNotes)
                    )
                },
                onToggle: { item, done in setDone(item, done: done) },
                onToggleCompleted: { completedExpanded.toggle() },
                onScroll: { noteSettleActivity() }),
            shineTick: shineTick)
    }

    /// A click that selected no words picks the whole block.
    private func pickDocBlock(_ block: NotesDocBlock) {
        selection = nil
        pickedBlock = BlockSelection(
            blockID: block.anchorID, section: block.section, blockText: block.blockText,
            occurrence: block.occurrence, span: SelectedSpan(text: ""), hostText: Self.shownText(block))
    }

    /// What the composer quotes for a whole block: a table is not in the text,
    /// so its host text is empty; it quotes the table's own text, as today.
    private static func shownText(_ block: NotesDocBlock) -> String {
        block.table == nil ? block.hostText : block.blockText
    }

    /// The rail beside each block that carries notes (wide margin mode).
    private func docRail(_ rows: [String: NotesDocRows], portuguese: Bool) -> [String: AnyView] {
        var rail: [String: AnyView] = [:]
        for (anchor, blockRows) in rows where !blockRows.notes.isEmpty {
            let notes = NotesEditingPresentation.marginNotes(blockRows.notes)
            rail[anchor] = docHosted(
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(notes) { MarginRailNote(note: $0, portuguese: portuguese) }
                })
        }
        return rail
    }

    /// The marks behind the words, per block: today's `editableBlock` rules.
    private func docMarks(
        _ rows: [String: NotesDocRows], pieces: [String: [NotesDocPieceMark]], composingAnchor: String?
    ) -> [String: NotesDocMark] {
        var marks: [String: NotesDocMark] = [:]
        for (anchor, blockRows) in rows {
            // Pending rows first, then the first note; a passage that wins
            // marks its last piece.
            guard let first = blockRows.pending.first ?? blockRows.notes.first else { continue }
            if let piece = pieces[first.id]?.last(where: { $0.anchorID == anchor }) {
                marks[anchor] = NotesDocMark(range: piece.local)
            } else if !CorrectionAnchoring.isPassage(first.quotedText) {
                marks[anchor] = NotesDocMark(span: SelectedSpan(text: first.quotedText))
            }
        }
        // A passage's other pieces, only on blocks with no mark of their own,
        // in today's first-row order (pending rows, then notes).
        let passageRows = correctionRows.filter { pieces[$0.id] != nil }
        for row in passageRows.filter({ $0.kind == .understanding }) + passageRows.filter({ $0.kind == .annotation }) {
            for piece in pieces[row.id] ?? [] where marks[piece.anchorID] == nil {
                marks[piece.anchorID] = NotesDocMark(range: piece.local)
            }
        }
        if let composingAnchor, let target = editingTarget {
            if let passage = target.passage {
                for piece in passage.pieces { marks[piece.anchorID] = NotesDocMark(range: piece.local) }
            } else {
                marks[composingAnchor] = NotesDocMark(
                    span: target.isWholeBlock
                        ? nil : SelectedSpan(text: target.quotedText, occurrence: target.spanOccurrence))
            }
        }
        if let navigationAnchor { marks[navigationAnchor] = NotesDocMark(span: nil, emphasized: true) }
        return marks
    }

    /// What stands under each block: today's `editableBlock` stack minus the
    /// text itself — the composer, pending rows, note cards (and chip) — plus
    /// a table, which is not in the text flow, and the first-run callout.
    private func docAttachments(
        _ doc: NotesDocument, rows: [String: NotesDocRows], structured: NotesStructured, portuguese: Bool
    ) -> [String: AnyView] {
        var anchors = Set(rows.keys)
        for block in doc.blocks where block.table != nil { anchors.insert(block.anchorID) }
        if let target = editingTarget { anchors.insert(target.anchorID) }
        let summaryBlocks = MarkdownBlocks.parse(structured.summary)
        let callout = NotesEditingCallout.anchorIndex(
            seen: notesPresentation.editingCalloutSeen, summaryBlocks: summaryBlocks
        ).map { NotesBlockAnchor.summary(summaryBlocks[$0].id) }
        if let callout { anchors.insert(callout) }
        anchors.insert(NotesDocument.tailAnchor)

        var result: [String: AnyView] = [NotesDocument.headAnchor: docHosted(headerStack)]
        let mode = layoutMode
        for anchor in anchors {
            if anchor == NotesDocument.tailAnchor {
                if let tail = docTail(structured, portuguese: portuguese) { result[anchor] = tail }
                continue
            }
            guard let block = doc.block(anchor) else { continue }
            let blockRows = rows[anchor] ?? NotesDocRows()
            let composing = composerPresented(
                editingTarget, inBlockWith: anchor, engineCanEditNotes: engineCanEditNotes)
            let noteModels = NotesEditingPresentation.marginNotes(blockRows.notes)
            let chipExpanded = expandedChips.contains(anchor)
            let pending = blockRows.pending.compactMap { row in
                pendingRowStatus(kind: row.kind, status: row.status, runActive: runActive).map { (row, $0) }
            }
            let showCards = !noteModels.isEmpty && (mode == .inlineCards || (mode == .marginChip && chipExpanded))
            let chip = mode == .marginChip && !noteModels.isEmpty
            guard block.table != nil || composing || !pending.isEmpty || showCards || chip || anchor == callout
            else { continue }
            let stack = VStack(alignment: .leading, spacing: 6) {
                if let table = block.table {
                    MarkdownBlockView(block: table, searchTerms: searchTerms)
                }
                if chip {
                    MarginNoteChip(count: noteModels.count, expanded: chipExpanded, portuguese: portuguese) {
                        if chipExpanded {
                            expandedChips.remove(anchor)
                        } else {
                            expandedChips.insert(anchor)
                        }
                    }
                }
                if composing, let target = editingTarget {
                    InlineComposer(
                        target: target,
                        sectionName: target.passage.map { passage in
                            passage.sections.map { sectionName($0, portuguese: portuguese) }.joined(separator: " · ")
                        } ?? (block.alwaysQuote ? sectionName(block.section, portuguese: portuguese) : nil),
                        commitEnabled: correctionsEnabled, userText: $composerDraft,
                        onCancel: { closeComposer() },
                        onSubmit: { submitComposer(target, text: $0) })
                }
                ForEach(pending, id: \.0.id) { row, status in
                    Button {
                        showChangesPanel = true
                    } label: {
                        PendingInstructionRow(statement: row.userText, status: status)
                    }
                    .buttonStyle(.plain)
                    .disabled(!correctionsAvailable)
                    .help("Open Changes")
                }
                if showCards {
                    ForEach(noteModels) { note in
                        InlineNoteCard(note: note, portuguese: portuguese)
                    }
                }
                if anchor == callout { editingCallout }
            }
            result[anchor] = docHosted(stack)
        }
        return result
    }

    /// The orphaned composer and the "Your notes" tail, after the last section.
    private func docTail(_ structured: NotesStructured, portuguese: Bool) -> AnyView? {
        let orphan = editingTarget.flatMap { target in
            NotesEditingEntry.offered(target.kind, engineCanEditNotes: engineCanEditNotes)
                && docCache.document?.block(target.anchorID) == nil ? target : nil
        }
        let unanchored = docCache.unanchored
        guard orphan != nil || !unanchored.isEmpty else { return nil }
        return docHosted(
            VStack(alignment: .leading, spacing: 24) {
                if let target = orphan {
                    InlineComposer(
                        target: target, sectionName: sectionName(target.section, portuguese: portuguese),
                        commitEnabled: correctionsEnabled, orphaned: true, userText: $composerDraft,
                        onCancel: { closeComposer() },
                        onSubmit: { submitComposer(target, text: $0) })
                        .frame(maxWidth: readingWidth, alignment: .leading)
                }
                if !unanchored.isEmpty {
                    NoteSection(title: portuguese ? "Suas notas" : "Your notes", kind: .detailed) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(unanchored, id: \.id) { note in
                                let targets = pinTargets(for: note)
                                InlineNoteCard(
                                    note: NotesEditingPresentation.marginNotes([note])[0],
                                    portuguese: portuguese, pinBlocks: targets,
                                    pinDisabled: !correctionsEnabled,
                                    onPin: { pinNote(note, toBlockAt: $0, in: targets) })
                            }
                        }
                    }
                }
            }
            .padding(.top, 8))
    }

    /// A SwiftUI view hosted inside the text view does not inherit the pane's
    /// environment; the app's objects are handed to it here.
    private func docHosted<V: View>(_ view: V) -> AnyView {
        AnyView(
            view
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(appEnv)
                .environment(uiState)
                .environment(library)
                .environment(activity)
                .environment(notesPresentation))
    }

    /// The header and its banners.
    private var headerStack: some View {
                VStack(alignment: .leading, spacing: 24) {
                    header

                    if !searchTerms.isEmpty {
                        SearchDestinationBanner(terms: searchTerms, location: "notes")
                    }

                    if let note = meeting.processingNote, !note.isEmpty {
                        HStack(alignment: .top, spacing: 8) {
                            QuietBanner(
                                text: note,
                                systemImage: note.hasPrefix(CaptureRecovery.notePrefix) ? "exclamationmark.triangle" : "info.circle",
                                tint: note.hasPrefix(CaptureRecovery.notePrefix) ? .orange : .secondary,
                                accessibilityPrefix: "Processing note")
                            // C11: a capture-recovery note survives runs until a
                            // both-tracks run completes OR the user dismisses it;
                            // an unavailable call-audio interval survives until
                            // dismissed.
                            if note.hasPrefix(CaptureRecovery.notePrefix) {
                                Button {
                                    let database = appEnv.database
                                    let meetingID = meeting.id
                                    Task {
                                        await CaptureRecovery.dismissRecoveryNote(
                                            database: database, meetingID: meetingID)
                                    }
                                } label: {
                                    Image(systemName: "xmark.circle")
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Dismiss capture recovery note")
                                .help("Dismiss this note (recorded audio is not affected)")
                            }
                        }
                    }
                    if let error = meeting.lastProcessingError, !error.isEmpty {
                        if NotesPendingClass.isAwaitingParticipantConfirmation(error) {
                            // G15: the participant-confirmation gate — calm banner
                            // plus the action that opens the confirm sheet.
                            HStack(spacing: 10) {
                                QuietBanner(
                                    text: "Confirm the participants to finish the notes",
                                    systemImage: "person.2", tint: .secondary,
                                    accessibilityPrefix: "Confirm participants")
                                Button("Confirm Participants…") { showParticipantConfirm = true }
                                    .buttonStyle(.borderless)
                            }
                        } else if NotesPendingClass.isPending(error) {
                            // D17: calm, distinct from failed — keyed on the
                            // reserved prefix, never on free-form text.
                            QuietBanner(
                                text: "Notes pending — will complete automatically",
                                systemImage: "clock", tint: .secondary,
                                accessibilityPrefix: "Notes pending")
                        } else {
                            QuietBanner(
                                text: error, systemImage: "exclamationmark.triangle", tint: .orange,
                                accessibilityPrefix: "Last processing error")
                        }
                    }
                }
                .frame(maxWidth: readingWidth, alignment: .leading)
    }

    /// No notes yet (processing, awaiting participants, pending, never run):
    /// the header and where the notes stand.
    private var noNotesScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerStack
                if meeting.status == .processing || meeting.status == .recording {
                    Text("Notes will appear here when processing finishes.")
                        .foregroundStyle(.secondary)
                } else if NotesPendingClass.isAwaitingParticipantConfirmation(meeting.lastProcessingError) {
                    Text("The transcript is ready. Confirm the participants above and the notes are written automatically.")
                        .foregroundStyle(.secondary)
                } else if NotesPendingClass.isPending(meeting.lastProcessingError) {
                    Text("The transcript is ready. Notes will complete automatically when the notes engine becomes available.")
                        .foregroundStyle(.secondary)
                } else {
                    ContentUnavailableView(
                        "No Notes Yet", systemImage: "doc.text",
                        description: Text("Run processing to generate notes."))
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
            .frame(maxWidth: notesColumnWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// At most one activity signal a second reaches the pipeline: the three
    /// classes fire far faster than the ten-minute window they reset needs.
    private func noteSettleActivity() {
        let instant = Date()
        guard instant.timeIntervalSince(lastSettleActivitySignal) >= 1 else { return }
        lastSettleActivitySignal = instant
        let pipeline = appEnv.pipeline
        let id = meeting.id
        Task { await pipeline.noteMeetingActivity(id) }
    }

    /// The notes column's own inset from the pane, on both sides.
    private static let columnInset: CGFloat = 36

    /// The prose measure, widened for the annotation lane when the pane can
    /// hold one. Everything that belongs to the reading column keeps
    /// `readingWidth`.
    private var notesColumnWidth: CGFloat {
        NotesEditingLayout.proseMeasure
            + (laneWidth.map { NotesEditingLayout.railGutter + $0 } ?? 0)
    }

    /// The one measure the reading column is built on: the prose measure inside
    /// the column's own insets. A block's text, a note card, the user's action
    /// box and the header all end here, so the column has one right edge rather
    /// than four. Only the annotation lane lies outside it.
    private var readingWidth: CGFloat {
        NotesEditingLayout.proseMeasure - Self.columnInset * 2
    }

    /// The lane beside the reading column, and how wide it is. It carries the
    /// margin notes and nothing else — the transient control stands at the
    /// selection, so the lane exists only where the rail placement is live and
    /// there is exactly one width question to answer about it.
    private var laneWidth: CGFloat? {
        layoutMode.usesRail ? NotesEditingLayout.railWidth : nil
    }

    /// How margin notes present right now: the Setting, resolved against the
    /// width actually available for the notes column.
    private var layoutMode: NotesLayoutMode {
        // The pane's own width, undiminished: the column measure the resolver
        // compares it against already carries the column's insets.
        NotesEditingLayout.mode(notesPresentation.marginNotesPlacement, width: paneWidth)
    }

    /// A run (a full pipeline run or the interim rewrite, which announces
    /// itself the same way) holds this meeting.
    private var runActive: Bool {
        activity.activeRuns[meeting.id] != nil || correctionBusy
    }

    private var editingContext: AppUIState.NotesEditingContext {
        AppUIState.NotesEditingContext(
            meetingID: meeting.id, surfaceReady: correctionsAvailable && notes != nil,
            hasTarget: commandTarget != nil, correctionEnabled: correctionsEnabled,
            engineCanEditNotes: engineCanEditNotes)
    }

    /// What the surface aims at, in rank order: the live selection, then the
    /// block the keyboard is on, then the block a click picked. A blank `text`
    /// anchors the whole block, which is the same invocation right-click makes.
    /// Where the pointer is resting is not a rank — it aims nothing on this
    /// surface. The bar stands at this, so what the menu acts on and what the
    /// control acts on cannot drift apart.
    private var commandTarget: BlockSelection? {
        selection ?? pickedBlock
    }

    /// Gives the page back: nothing marked, nothing aimed at, nothing standing.
    private func clearAim() {
        selection = nil
        pickedBlock = nil
    }

    /// The menu-bar commands land here: the same entry the hover group uses,
    /// aimed at the selection or, without one, at the whole block.
    private func applyEditingRequest(_ request: AppUIState.NotesEditingRequest?) {
        guard let request, request.meetingID == meeting.id,
            NotesEditingEntry.allowed(
                request.kind, correctionEnabled: correctionsEnabled,
                engineCanEditNotes: engineCanEditNotes),
            let target = commandTarget
        else { return }
        uiState.notesEditingRequest = nil
        beginEditing(request.kind, on: target)
    }

    /// Opens the composer on what the surface aims at: a selection across
    /// paragraphs as its pieces (the passage walk runs once, here), anything
    /// else through today's entry seam.
    private func beginEditing(_ kind: EditingTarget.Kind, on target: BlockSelection) {
        guard let passage = target.passage else {
            beginEditing(
                kind, section: target.section, anchorID: target.blockID,
                blockText: target.blockText, occurrence: target.occurrence,
                selection: target.span, hostText: target.hostText)
            return
        }
        guard let doc = docCache.document,
            NotesEditingEntry.allowed(kind, correctionEnabled: correctionsEnabled, engineCanEditNotes: engineCanEditNotes)
        else { return }
        beginEditing(
            NotesEditingEntry.target(
                kind, passage: passage, anchorBlockText: target.blockText,
                occurrence: doc.occurrence(of: passage)))
    }

    /// Brings a freshly opened composer into view. The anchor id belongs to the
    /// whole editable block — prose, composer and pending row together — so
    /// centring it puts the input field and its buttons on screen wherever in
    /// the document the block sits.
    ///
    /// The wait is load-bearing: the composer expands over `NotesEditingMotion.
    /// expand`'s duration, and until that height is in the layout the scroll
    /// clamps to the shorter content and stops short of the commit buttons.
    private func scrollComposerIntoView(anchor: String) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 200 : 360))
            requestDocScroll(anchor, center: false, reveal: true)
        }
    }

    private func scrollToFirstSearchMatch(animated: Bool) {
        guard let anchor = firstSearchAnchor else { return }
        Task { @MainActor in
            // Let the tab switch land before the destination is resolved.
            await Task.yield()
            requestDocScroll(anchor, animated: animated)
        }
    }

    private var firstSearchAnchor: String? {
        guard let structured = notes?.structured, !searchTerms.isEmpty else { return nil }
        if let block = MarkdownBlocks.parse(structured.summary).first(where: {
            SearchTextMatcher.contains(String($0.text.characters), terms: searchTerms)
        }) {
            return "notes-summary-\(block.id)"
        }
        if structured.userActionItems.contains(where: {
            SearchTextMatcher.contains($0.text, terms: searchTerms)
        }) {
            return Self.userActionBoxAnchor
        }
        if let index = structured.decisions.firstIndex(where: {
            SearchTextMatcher.contains($0, terms: searchTerms)
        }) {
            return "notes-decision-\(index)"
        }
        let visibleActionItems = structured.actionItems.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let index = visibleActionItems.firstIndex(where: {
            SearchTextMatcher.contains("\($0.owner) \($0.text)", terms: searchTerms)
        }) {
            return "notes-action-\(index)"
        }
        if let block = MarkdownBlocks.parse(structured.detailedNotes).first(where: {
            SearchTextMatcher.contains(String($0.text.characters), terms: searchTerms)
        }) {
            return "notes-detailed-\(block.id)"
        }
        return nil
    }

    /// The meeting's hue (aquarela identity; the accent elsewhere).
    private var pageTint: Color {
        Design.direction == .aquarela ? Design.meetingHue(meeting.title) : Design.accent
    }

    /// Fluido renders the header as a floating material card — the same
    /// surface language as the list card you selected — settling quietly
    /// into place on selection. Other directions keep the bare header.
    @ViewBuilder
    private var header: some View {
        if Design.direction == .fluido {
            headerCore
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
                .modifier(FluidoHeaderSettle(armed: $heroArmed))
        } else {
            headerCore
        }
    }

    private var headerCore: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                EditableTitle(meeting: meeting)
                if runActive, notes != nil {
                    Text("Updating notes…")
                        .font(.system(size: 11))
                        .foregroundStyle(Design.accent)
                        .transition(.opacity)
                }
            }
            HStack(spacing: 14) {
                MetaItem(
                    icon: "calendar",
                    text: BlaiseDateFormat.dayMonthYear(meeting.startedAt),  // pinned DD/MM/YYYY (M-1)
                    tint: pageTint)
                MetaItem(icon: "clock", text: timeAndDuration, tint: pageTint)
                if let code = meeting.meetingCode {
                    MetaItem(icon: "video", text: code, tint: pageTint)
                }
            }
            let attendees = AttendeeDisplay.presentable(meeting.attendees)
            if !attendees.isEmpty {
                // Human NAMES (calendar may deliver emails as names); the
                // full addresses live in the tooltip. Extension-scraped junk
                // (markup blocks, UI sentences) is filtered by `presentable`.
                Text(attendees.map { AttendeeDisplay.displayName($0) }.joined(separator: ", "))
                    .font(Design.direction == .caderno ? .system(size: 12.5, design: .serif).italic() : .system(size: 12))
                    .foregroundStyle(.tertiary)
                    .help(AttendeeDisplay.tooltip(attendees))
            }
            provenanceLine
            if let deletedCaption = audioDeletedDescription(meeting) {
                Label(deletedCaption, systemImage: "waveform.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            } else {
                AudioPlayerView(
                    audioURL: appEnv.database.paths.audioURL(meeting.id),
                    database: appEnv.database, meetingID: meeting.id, tint: pageTint,
                    seed: meeting.id
                )
                .id(meeting.audioDeletedAt)
                .padding(.top, 6)
            }
        }
    }

    /// The engine identifiers. They name the machinery, never the meeting, and
    /// nobody acts on them — so they ride the stamp they belong to instead of
    /// taking a line of the reading surface.
    private var engineProvenance: String {
        [
            meeting.asrProvenance.map { "ASR: \($0.engine)" },
            notes.map { "Notes: \($0.provenance.engine)" },
        ].compactMap(\.self).joined(separator: " · ")
    }

    /// What stands above the prose: the row — when these notes were written,
    /// the G2 name-correction affordances, the overview's door, and Copy Notes
    /// — and, under it, the send action's own line.
    @ViewBuilder
    private var provenanceLine: some View {
        VStack(alignment: .leading, spacing: 6) {
            // One row where the measure carries it, the stamp over its controls
            // where it does not. Wrapping instead leaves a label broken across
            // three lines and the row's baselines ragged.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    provenanceStamp
                    provenanceControls
                }
                VStack(alignment: .leading, spacing: 6) {
                    provenanceStamp
                    HStack(spacing: 8) { provenanceControls }
                }
            }
            notesEditorSendLine
        }
        .transientScrollIndicators()
    }

    /// The pending batch's own control, on a line of its own under the row: an
    /// act, not another thing to manage, so it carries a border instead of
    /// standing in a stream of borderless labels. It comes and goes with the
    /// pending row and the notes below it shift; no space is held for it.
    @ViewBuilder
    private var notesEditorSendLine: some View {
        if correctionsAvailable,
            notesEditorSendOffered(rows: correctionRows, engineCanEditNotes: engineCanEditNotes)
        {
            Button {
                sendToNotesEditorNow()
            } label: {
                Label(
                    runActive ? NotesEditorPanelCopy.busyLabel : NotesEditorPanelCopy.actionLabel,
                    systemImage: "arrow.clockwise")
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            .buttonStyle(.bordered)
            .disabled(runActive)
            .help(NotesEditorPanelCopy.help)
        }
    }

    @ViewBuilder
    private var provenanceStamp: some View {
        // Non-breaking: a wrap that leaves the time on a line of its own reads
        // as a second fact rather than as the stamp's other half.
        if let notes {
            let stamp =
                "generated\u{00A0}"
                + BlaiseDateFormat.dayMonthYearTime(notes.generatedAt)
                    .replacingOccurrences(of: " ", with: "\u{00A0}")
            Text(stamp)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .help(engineProvenance)
                .accessibilityLabel(
                    engineProvenance.isEmpty ? stamp : "\(stamp). \(engineProvenance)")
        }
    }

    @ViewBuilder
    private var provenanceControls: some View {
        Group {
            // G2 §3: the substitution report — shown in an info popover.
            if let substitutions = notes?.provenance.nameSubstitutions, !substitutions.isEmpty {
                Button {
                    showSubstitutionReport.toggle()
                } label: {
                    Label("\(substitutions.count) name fix\(substitutions.count == 1 ? "" : "es")",
                          systemImage: "info.circle")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .popover(isPresented: $showSubstitutionReport) {
                    SubstitutionReportView(entries: substitutions)
                        .padding(14)
                        .frame(width: 320)
                }
            }
            // G2 §5: open the correct-name flow.
            if notes != nil, meeting.status == .ready {
                Button {
                    showCorrectName.toggle()
                } label: {
                    Label("Correct name…", systemImage: "character.cursor.ibeam")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .popover(isPresented: $showCorrectName) {
                    CorrectNamePopover(
                        meeting: meeting, notes: notes,
                        resolvedSpeakers: resolvedSpeakers,
                        database: appEnv.database, pipeline: appEnv.pipeline,
                        isPresented: $showCorrectName)
                        .frame(width: 360)
                }
            }
            // The Changes panel's entry point, and the pane's only standing sign
            // that its notes can be corrected and annotated at all. It shows
            // whenever the capability is live, empty list or not — a place to go
            // rather than an instruction on the page. Gated on the BASE
            // availability (not `correctionsEnabled`) so it stays open while a
            // rewrite runs.
            if correctionsAvailable {
                Button {
                    showChangesPanel.toggle()
                } label: {
                    Label(correctionChipTitle, systemImage: "list.bullet.rectangle")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .popover(isPresented: $showChangesPanel) {
                    ChangesPanel(
                        rows: correctionRows, runActive: runActive, busy: correctionBusy,
                        engineCanEditNotes: engineCanEditNotes,
                        resolvedIDs: resolvedRowIDs,
                        pinTargets: { pinTargets(for: $0) },
                        onNavigate: { navigate(to: $0) },
                        onResolve: { row, resolved in setResolved(row, resolved) },
                        onDelete: { deleteCorrectionRow($0) },
                        onEdit: { editCorrectionRow($0, text: $1) },
                        onPin: { row, index in
                            pinNote(row, toBlockAt: index, in: pinTargets(for: row))
                        },
                        onSend: { sendToNotesEditorNow() })
                }
            }
            // Copy is a utility of the meeting, not a third way to manage what
            // the notes say: the rule divides it from the two affordances that
            // are. It stands on the same gate as those two, so it never opens
            // a set that is not there.
            if correctionsAvailable {
                // The system rule renders at a contrast this ground swallows
                // entirely, so the seam is drawn explicitly, sized to the
                // labels it stands between rather than to the row.
                Rectangle()
                    .fill(.white.opacity(0.28))
                    .frame(width: 1, height: 13)
                    .accessibilityHidden(true)
            }
            // Copy All (V1.1): the rendered notes markdown — the human artifact,
            // verbatim. It sits with the meeting's other utilities rather than
            // on a row of its own between the reader and the first sentence.
            if let notes {
                let portuguese = (meeting.dominantLanguage ?? "").lowercased().hasPrefix("pt")
                CopyAllButton(
                    label: portuguese ? "Copiar Notas" : "Copy Notes",
                    copiedLabel: portuguese ? "Copiado" : "Copied",
                    accessibilityLabel: "Copy all notes as markdown", quiet: true
                ) { notes.markdown }
            }
        }
        .lineLimit(1)
    }

    private var correctionChipTitle: String {
        let corrections = correctionRows.filter { $0.kind == .understanding }.count
        let notesCount = correctionRows.count - corrections
        var parts: [String] = []
        if corrections > 0 { parts.append("\(corrections) correction\(corrections == 1 ? "" : "s")") }
        if notesCount > 0 { parts.append("\(notesCount) note\(notesCount == 1 ? "" : "s")") }
        return parts.isEmpty ? "Changes" : "Changes · \(parts.joined(separator: " · "))"
    }

    private var timeAndDuration: String {
        var line = meeting.startedAt.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened).locale(Locale(identifier: "en_GB")))
        if let ended = meeting.endedAt {
            line += " · \(max(1, Int(ended.timeIntervalSince(meeting.startedAt) / 60))) min"
        }
        return line
    }

    // MARK: - Correction/note actions

    /// The base gate: final notes on a ready meeting (the same gate as the
    /// correct-name flow). Correction/note ROWS may exist and be managed
    /// (viewed, deleted) whenever this holds — including while a rewrite is
    /// in flight, so the busy chip stays visible.
    private var correctionsAvailable: Bool {
        notes != nil && meeting.status == .ready
    }

    /// NEW corrections/notes may be INITIATED only when no pipeline run is in
    /// flight for this meeting and no rewrite is already running.
    private var correctionsEnabled: Bool {
        correctionEntryEnabled(
            available: correctionsAvailable,
            runActive: activity.activeRuns[meeting.id] != nil,
            rewriteBusy: correctionBusy)
    }

    /// Whether the notes surface offers the correction path at all: only an
    /// engine that can edit notes can serve one. Read from the live selection,
    /// so selecting another engine in Settings reaches this surface at once.
    private var engineCanEditNotes: Bool {
        notesEditingEngineCanEdit(
            selectedSummarizationID: appEnv.engineSettings.selectedSummarizationID,
            registry: appEnv.registry)
    }

    /// The occurrence to STORE for a submitted correction, resolved against
    /// the section's real anchor blocks — the popover lets the user trim the
    /// quote, which moves it into a different match space than the block it
    /// came from.
    private func storedOccurrence(for submission: CorrectionSubmission) -> Int {
        // A passage stores the occurrence its capture named (n7 §1).
        guard let structured = notes?.structured, !CorrectionAnchoring.isPassage(submission.quotedText)
        else { return submission.occurrence }
        return CorrectionAnchoring.occurrence(
            forQuote: submission.quotedText, takenFrom: submission.blockText,
            blockOccurrence: submission.occurrence,
            in: CorrectionAnchoring.blocks(of: structured, section: submission.section))
    }

    /// Rows the person has put away in the overview, read from the rows
    /// themselves: the status IS the answer, so it survives a relaunch and
    /// every synthesis run in between.
    private var resolvedRowIDs: Set<String> {
        Set(correctionRows.filter { $0.status == .resolved }.map(\.id))
    }

    /// Resolve / Reopen from the overview, written to the row. Reopening asks
    /// the notes where the row stands now — matched or stale for a note, and
    /// pending for a correction the rewrite has not consumed.
    private func setResolved(_ row: MeetingCorrection, _ resolved: Bool) {
        let pipeline = appEnv.pipeline
        let structuredNotes = notes?.structured
        Task {
            try? await pipeline.setCorrectionResolved(
                meetingID: meeting.id, id: row.id, resolved: resolved,
                structuredNotes: structuredNotes)
            await loadCorrections()
        }
    }

    /// Display load only — failure-soft (an empty list is a display state, not
    /// a synthesis input). The assignment carries the surface's motion, so the
    /// pending row's dissolve and a note card's appearance run their
    /// transitions instead of snapping.
    ///
    /// Returns what the store actually said, or nil when it could not be read.
    /// The display shows an empty list either way; a caller adjudicating a
    /// MUTATION must not read an unreadable store as an answer.
    @discardableResult
    private func loadCorrections() async -> [MeetingCorrection]? {
        let database = appEnv.database
        let meetingID = meeting.id
        correctionLoadGeneration += 1
        let generation = correctionLoadGeneration
        let rows: [MeetingCorrection]? = try? await database.pool.read { db in
            try MeetingCorrectionStore.all(db, meetingID: meetingID)
        }
        // Latest wins: two loads can complete out of order, and an earlier
        // snapshot (taken before a status flip) must not overwrite a later one.
        // The caller still gets what its own read said.
        guard generation == correctionLoadGeneration else { return rows }
        withAnimation(NotesEditingMotion.expand(reduceMotion: reduceMotion)) {
            correctionRows = rows ?? []
        }
        return rows
    }

    /// Opens the composer for one invocation, whatever path raised it. Every
    /// path consults the same gate first, and any editing action retires the
    /// teaching callout.
    private func beginEditing(
        _ kind: EditingTarget.Kind, section: MeetingCorrection.Section, anchorID: String,
        blockText: String, occurrence: Int, selection: SelectedSpan? = nil,
        hostText: String? = nil
    ) {
        guard NotesEditingEntry.allowed(
            kind, correctionEnabled: correctionsEnabled,
            engineCanEditNotes: engineCanEditNotes)
        else { return }
        beginEditing(
            NotesEditingEntry.target(
                kind, section: section, anchorID: anchorID, blockText: blockText,
                occurrence: occurrence, selection: selection, hostText: hostText))
    }

    /// Opens the composer on a target a seam has already built and gated.
    private func beginEditing(_ target: EditingTarget) {
        appEnv.notesPresentation.retireEditingCallout(in: appEnv.settings)
        composerDraft = ""
        withAnimation(NotesEditingMotion.expand(reduceMotion: reduceMotion)) {
            editingTarget = target
        }
    }

    private func closeComposer() {
        composerDraft = ""
        // The aim has been acted on, so the bar it summoned has nothing left to
        // offer; left standing it sits over the note just written.
        clearAim()
        withAnimation(NotesEditingMotion.expand(reduceMotion: reduceMotion)) {
            editingTarget = nil
        }
    }

    /// Submits whatever the composer holds, down the path its kind names. The
    /// gate is consulted before anything closes, so a refusal keeps the draft.
    private func submitComposer(_ target: EditingTarget, text: String) {
        notesEditingCommitAction(
            target, correctionEnabled: correctionsEnabled,
            engineCanEditNotes: engineCanEditNotes
        ) { target in
            closeComposer()
            switch target.kind {
            case .correct:
                submitCorrection(
                    CorrectionSubmission(
                        section: target.section, quotedText: target.quotedText, userText: text,
                        occurrence: target.occurrence, blockText: target.blockText))
            case .note:
                submitNote(target: target, text: text)
            }
        }
    }

    /// Understanding correction: save the durable row. The pipeline scheduler
    /// owns the editor activation; this UI path starts no synthesis itself.
    private func submitCorrection(_ submission: CorrectionSubmission) {
        guard !correctionBusy else { return }
        let pipeline = appEnv.pipeline
        let meetingID = meeting.id
        let uiState = uiState
        // Resolved against the CURRENT notes, on the main actor, before the
        // task detaches.
        let occurrence = storedOccurrence(for: submission)
        correctionBusy = true
        Task {
            defer { correctionBusy = false }
            uiState.lastActionError = await saveUnderstandingCorrectionAction {
                _ = try await pipeline.addCorrection(
                    meetingID: meetingID, kind: .understanding,
                    section: submission.section, quotedText: submission.quotedText,
                    occurrence: occurrence, userText: submission.userText)
            }
            await loadCorrections()
        }
    }

    /// Margin note: deterministic, instant, no engine call.
    private func submitNote(target: EditingTarget, text: String) {
        let pipeline = appEnv.pipeline
        let meetingID = meeting.id
        let uiState = uiState
        // Mid-run, the re-mint still runs — it queues behind the run on the
        // single-flight chain and weaves the note when the run drains, so the
        // note cannot be lost in the window after the run's own weave. But it
        // is NOT instant any more, and the copy says so.
        let runActive = activity.activeRuns[meeting.id] != nil
        // A selection anchors the note to the span, not the whole block, so the
        // occurrence is recomputed in the trimmed quote's match space.
        let occurrence = storedOccurrence(
            for: CorrectionSubmission(
                section: target.section, quotedText: target.quotedText, userText: text,
                occurrence: target.occurrence, blockText: target.blockText))
        Task {
            do {
                let result = try await pipeline.addCorrection(
                    meetingID: meetingID, kind: .annotation,
                    section: target.section, quotedText: target.quotedText,
                    occurrence: occurrence, userText: text)
                uiState.lastActionError = noteFeedback(
                    remintRefused: result.remintRefused, runActive: runActive)
            } catch {
                uiState.lastActionError = "Could not add the note: \(error.localizedDescription)"
            }
            await loadCorrections()
        }
    }

    /// Deleting cancels a correction that has not run, and stops a processed
    /// one affecting later runs. It never reverts written notes, so it is never
    /// presented as an undo.
    private func deleteCorrectionRow(_ row: MeetingCorrection) {
        let pipeline = appEnv.pipeline
        let meetingID = meeting.id
        let uiState = uiState
        Task {
            do {
                // An annotation delete that could not re-mint has NOT left the
                // delivered notes yet.
                let refused = try await pipeline.deleteCorrection(
                    meetingID: meetingID, id: row.id)
                uiState.lastActionError = refused
                    ? "Note deleted — it leaves the delivered notes when processing completes."
                    : nil
            } catch {
                // The row is deleted before the re-mint that publishes the
                // change can throw, so a throw here does not mean the delete
                // failed. The STORED outcome decides what the user is told —
                // and a store that cannot be read holds no outcome to report.
                let stored = await loadCorrections()
                uiState.lastActionError = deleteFeedback(
                    rowSurvived: stored.map { rows in rows.contains { $0.id == row.id } },
                    error: error)
            }
            await loadCorrections()
        }
    }

    /// Edit the row's TEXT, keeping its anchor. An annotation edit re-mints;
    /// an understanding edit returns the row to `pending` and re-arms the
    /// editor timer.
    private func editCorrectionRow(_ row: MeetingCorrection, text: String) {
        guard !text.isEmpty, text != row.userText, !correctionBusy else { return }
        let pipeline = appEnv.pipeline
        let meetingID = meeting.id
        let uiState = uiState
        Task {
            do {
                let refused = try await pipeline.updateCorrection(
                    meetingID: meetingID, id: row.id, quotedText: row.quotedText,
                    occurrence: row.occurrence, userText: text)
                uiState.lastActionError = editFeedback(row, refused: refused)
            } catch {
                uiState.lastActionError = "Could not edit: \(error.localizedDescription)"
            }
            await loadCorrections()
        }
    }

    private func editFeedback(_ row: MeetingCorrection, refused: Bool) -> String? {
        if row.kind == .understanding { return nil }
        return refused
            ? "Note updated — it reaches the delivered notes when processing completes."
            : nil
    }

    /// Take the reader to the passage a row is anchored to, and mark it when
    /// they arrive: a passage's first piece. A row whose quote no longer
    /// matches anything is left where it is: it is stale, it says so, and
    /// there is nowhere honest to go.
    private func navigate(to row: MeetingCorrection) {
        guard let structured = notes?.structured,
            let anchor = notesDocNavigationAnchor(
                row, space: docCache.document?.space ?? CorrectionAnchoring.RenderedSpace(structured))
        else { return }
        showChangesPanel = false
        // The first piece on a done item: "Completed" opens so its block is there to go to.
        if docCache.document?.hiddenInCompleted(anchor) == true { completedExpanded = true }
        navigationAnchor = anchor
        navigationRequest += 1
    }

    /// The blocks a stale row can be pinned back onto: its own section's,
    /// without the blanks. A blank block can never fold-match a non-empty
    /// quote, so it is unpinnable, AND its absence cannot shift the occurrence
    /// `CorrectionAnchoring.occurrence(ofBlockAt:in:)` computes when one is
    /// picked.
    private func pinTargets(for row: MeetingCorrection) -> [String] {
        guard let structured = notes?.structured else { return [] }
        return CorrectionAnchoring.blocks(of: structured, section: row.section)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// PIN PICKER: re-anchor a stale note onto the block the user picked. The
    /// block's CURRENT text becomes the quote (that is what the note is now
    /// about) with its fold-match occurrence, so a paragraph repeated verbatim
    /// still anchors distinctly. `updateCorrection` re-mints for annotations,
    /// so notes.md + the payload follow without a second call.
    private func pinNote(_ row: MeetingCorrection, toBlockAt index: Int, in blocks: [String]) {
        // The menu is disabled while a run/rewrite is in flight (the same gate
        // as the block affordances); a queued interaction could still land here.
        guard correctionsEnabled, let (quote, occurrence) = notesDocPin(blocks, at: index) else { return }
        let pipeline = appEnv.pipeline
        let meetingID = meeting.id
        let uiState = uiState
        Task {
            do {
                let refused = try await pipeline.updateCorrection(
                    meetingID: meetingID, id: row.id, quotedText: quote,
                    occurrence: occurrence, userText: row.userText)
                uiState.lastActionError = refused
                    ? "Note pinned — it moves in the delivered notes when processing completes."
                    : nil
            } catch {
                uiState.lastActionError = "Could not pin the note: \(error.localizedDescription)"
            }
            await loadCorrections()
        }
    }

    private func sendToNotesEditorNow() {
        // Never launch a second editor activation over an in-flight one.
        guard !correctionBusy else { return }
        let pipeline = appEnv.pipeline
        let meetingID = meeting.id
        let uiState = uiState
        correctionBusy = true
        Task {
            defer { correctionBusy = false }
            uiState.lastActionError = await sendToNotesEditorAction(meetingID: meetingID) { id in
                try await pipeline.sendPendingNotesToEditor(meetingID: id)
            }
            await loadCorrections()
        }
    }

    /// Marks/unmarks one user item done (`action_item_state`, local-only).
    /// A failure (DB-error-only in practice) surfaces in the window banner —
    /// the checkbox staying unchanged must never be unexplained.
    private func setDone(_ item: ActionItem, done: Bool) {
        let database = appEnv.database
        let meetingID = meeting.id
        let uiState = uiState
        Task {
            let repo = ActionItemStateRepository(database: database)
            do {
                if done {
                    try await repo.markDone(meetingID: meetingID, itemText: item.text)
                } else {
                    try await repo.clearDone(meetingID: meetingID, itemText: item.text)
                }
                uiState.lastActionError = nil
            } catch {
                uiState.lastActionError = "Could not update the action item: \(error.localizedDescription)"
            }
        }
    }

    /// G3 name-driven section title: `<name> — Action Items` / `<name> —
    /// Itens de Ação`; an empty (pre-onboarding) identity → neutral
    /// "My action items" / "Minhas ações".
    private func userActionSectionTitle(portuguese: Bool) -> String {
        let name = appEnv.userName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            return portuguese ? "Minhas ações" : "My action items"
        }
        return portuguese ? "\(name) — Itens de Ação" : "\(name) — Action Items"
    }

    /// The one first-run teaching line, standing under the summary paragraph it
    /// is about. Its ✕ retires it through the same path any correction or note
    /// action takes, so the surface has one way of putting it away.
    private var editingCallout: some View {
        HStack(alignment: .top, spacing: 8) {
            QuietBanner(
                text: NotesEditingCallout.text, systemImage: "text.cursor",
                tint: .secondary, accessibilityPrefix: "Tip")
            Button {
                appEnv.notesPresentation.retireEditingCallout(in: appEnv.settings)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss this tip")
            .help("Dismiss this tip")
        }
        .frame(maxWidth: readingWidth, alignment: .leading)
    }

    private func contextMenuInvoke(
        _ kind: EditingTarget.Kind, section: MeetingCorrection.Section, blockText: String,
        occurrence: Int, blockID: String, hostText: String
    ) {
        notesEditingContextMenuAction(
            kind, section: section, blockText: blockText, occurrence: occurrence,
            blockID: blockID, selection: selection.map { ($0.blockID, $0.span) },
            correctionEnabled: correctionsEnabled,
            engineCanEditNotes: engineCanEditNotes, hostText: hostText,
            begin: { beginEditing($0) })
    }

    private func sectionName(
        _ section: MeetingCorrection.Section, portuguese: Bool
    ) -> String {
        switch section {
        case .summary: return portuguese ? "Resumo" : "Summary"
        case .detailedNotes: return portuguese ? "Notas Detalhadas" : "Detailed Notes"
        case .decision: return portuguese ? "Decisões" : "Decisions"
        case .actionItem: return portuguese ? "Itens de Ação" : "Action Items"
        case .userActionItem: return portuguese ? "Suas ações" : "Your action items"
        }
    }
}

/// Section heading + chrome, per direction:
/// — Caderno: serif small-caps title with a fading hairline rule (a chapter
///   opening); content sits directly on the warm page.
/// — Estúdio: wide-tracked caps over a cyan→violet gradient tick.
/// — Aquarela: a tinted icon chip + title, content inside the section's
///   quiet semantic color field.
private struct NoteSection<Content: View>: View {
    let title: String
    var kind: Design.NoteSectionKind = .summary
    @ViewBuilder var content: Content

    var body: some View {
        switch Design.direction {
        case .caderno:
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text(title)
                        .font(.system(size: 13.5, weight: .semibold, design: .serif).smallCaps())
                        .kerning(0.5)
                        .foregroundStyle(Design.accent.opacity(0.92))
                        .accessibilityAddTraits(.isHeader)
                    LinearGradient(
                        colors: [Design.accent.opacity(0.35), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(height: 1)
                    .offset(y: 1)
                    .accessibilityHidden(true)
                }
                content
            }
        case .estudio:
            VStack(alignment: .leading, spacing: 10) {
                estudioHeading
                content
            }
        case .fluido:
            // Estúdio's heading over content floating on a material card —
            // the layer the living mesh shines through. The user-action box brings
            // its own chrome (UserActionBoxChrome), so no second card around it.
            VStack(alignment: .leading, spacing: 10) {
                estudioHeading
                if kind == .userActions {
                    content
                } else {
                    content
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
                }
            }
        case .aquarela:
            aquarelaSection
        }
    }

    /// Estúdio's section heading: wide-tracked caps over a gradient tick
    /// (shared by fluido).
    private var estudioHeading: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .kerning(1.6)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            LinearGradient(
                colors: [Design.accent, Design.support],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: 36, height: 2)
            .clipShape(Capsule())
            .accessibilityHidden(true)
        }
    }

    private var aquarelaSection: some View {
        let tint = Design.sectionTint(kind)
        return VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Image(systemName: Design.sectionIcon(kind))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .frame(width: 19, height: 19)
                        .background(tint.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tint)
                        .accessibilityAddTraits(.isHeader)
                }
                content
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        tint.opacity(kind == .userActions ? 0.11 : 0.055),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(tint.opacity(kind == .userActions ? 0.38 : 0.14), lineWidth: 1))
        }
    }
}

// MARK: - Block-level markdown view (pinned: .full keeps raw HTML literal)

/// Renders exact destination matches with three cues: stronger weight,
/// underline, and a quiet accent field. When no search is active the original
/// AttributedString is returned unchanged, preserving Markdown inline styles.
/// Non-selectable text (transcript rows, table cells, code).
private struct SearchHighlightedText: View {
    let source: AttributedString
    let terms: [String]

    var body: some View {
        NotesBlockText(source: source, terms: terms)
    }
}

/// Layers the match cues ON TOP of the source's own attributes: the markdown
/// parser's bold, italics and links must survive a search (rebuilding the
/// string from its characters discarded all of them).
enum SearchHighlight {
    @MainActor
    static func applied(to source: AttributedString, terms: [String]) -> AttributedString {
        guard !terms.isEmpty else { return source }
        var output = source
        var offset = 0
        for segment in SearchTextMatcher.segments(String(source.characters), matching: terms) {
            let length = segment.text.count
            defer { offset += length }
            guard segment.isMatch else { continue }
            // ANY mutation invalidates EVERY index of an AttributedString, so
            // the match's runs are recorded as CHARACTER OFFSETS (stable: the
            // characters never change here) and each index is reacquired
            // immediately before the mutation that uses it.
            let matchStart = output.index(output.startIndex, offsetByCharacters: offset)
            let matchEnd = output.index(matchStart, offsetByCharacters: length)
            let spans = output[matchStart..<matchEnd].runs.map { run in
                (
                    offset: output.characters.distance(
                        from: output.startIndex, to: run.range.lowerBound),
                    length: output.characters.distance(
                        from: run.range.lowerBound, to: run.range.upperBound),
                    intent: run.inlinePresentationIntent
                )
            }
            for span in spans {
                // Emphasis MERGES with whatever the run already carries (an
                // italic match stays italic); the run's whole cue set is applied
                // in ONE mutation, so no index outlives a write.
                var merged = span.intent ?? []
                merged.insert(.stronglyEmphasized)
                var cues = AttributeContainer()
                cues.inlinePresentationIntent = merged
                cues.foregroundColor = Design.accent
                cues.backgroundColor = Design.accent.opacity(0.2)
                cues.underlineStyle = .single
                let start = output.index(output.startIndex, offsetByCharacters: span.offset)
                let end = output.index(start, offsetByCharacters: span.length)
                output[start..<end].mergeAttributes(cues)
            }
        }
        return output
    }
}

private struct SearchDestinationBanner: View {
    let terms: [String]
    let location: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Design.accent)
            Text("Showing \(location) match")
                .font(.system(size: 11, weight: .semibold))
            Text(terms.joined(separator: ", "))
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Design.accent)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Design.accent.opacity(0.09), in: Capsule())
        .overlay(Capsule().strokeBorder(Design.accent.opacity(0.24), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Showing \(location) search match: \(terms.joined(separator: ", "))")
    }
}

/// One parsed markdown block, rendered per its kind (the notes pane hosts it
/// for tables).
struct MarkdownBlockView: View {
    let block: MarkdownBlock
    var searchTerms: [String] = []

    var body: some View {
        blockView(block)
    }

    @ViewBuilder
    private func proseText(_ text: AttributedString) -> some View {
        NotesBlockText(source: text, terms: searchTerms)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block.kind {
        case .paragraph, .blockQuote:
            proseText(block.text)
                .font(Design.readingFont(14))
                .lineSpacing(Design.readingLineSpacing)
                .foregroundStyle(.primary.opacity(0.9))
                .textSelection(.enabled)
        case .header:
            // The selection-capable host, like every other anchorable block:
            // the block's right-click menu is carried by that host, and a
            // sub-heading is as correctable as the lines under it.
            proseText(block.text)
                .font(Design.readingFont(14, weight: .semibold))
                .padding(.top, 4)
                .textSelection(.enabled)
        case .listItem(let ordinal, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(ordinal.map { "\($0)." } ?? "•")
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(Design.direction == .caderno ? AnyShapeStyle(Design.accent.opacity(0.7)) : AnyShapeStyle(.tertiary))
                proseText(block.text)
                    .font(Design.readingFont(14))
                    .lineSpacing(Design.readingLineSpacing - 2)
                    .foregroundStyle(.primary.opacity(0.88))
                    .textSelection(.enabled)
            }
            .padding(.leading, CGFloat(max(0, depth - 1)) * 16)
        case .codeBlock:
            SearchHighlightedText(source: block.text, terms: searchTerms)
                .font(.system(size: 12.5, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                .textSelection(.enabled)
        case .thematicBreak:
            Divider()
        case .table(let header, let rows, let alignments):
            // The table lays out INSIDE the notes column: columns size to their
            // content and cell text wraps, growing the row (a horizontal scroll
            // pushed prose off the right edge).
            Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 6) {
                if !header.isEmpty {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { column, cell in
                            tableCell(cell, alignments: alignments, column: column, header: true)
                        }
                    }
                    Divider()
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                            tableCell(cell, alignments: alignments, column: column, header: false)
                        }
                    }
                    if index < rows.count - 1 {
                        Divider().opacity(0.4)
                    }
                }
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tableCell(
        _ cell: AttributedString,
        alignments: [PresentationIntent.TableColumn.Alignment],
        column: Int,
        header: Bool
    ) -> some View {
        SearchHighlightedText(source: cell, terms: searchTerms)
            .font(Design.readingFont(14, weight: header ? .semibold : .regular))
            .foregroundStyle(.primary.opacity(header ? 1 : 0.88))
            .multilineTextAlignment(textAlignment(alignments, column))
            .textSelection(.enabled)
            // Wrap instead of demanding the cell's natural single-line width,
            // and let the row grow vertically to fit what wrapped. The cell is
            // deliberately NOT stretched to maxWidth: .infinity — a flexible
            // cell makes Grid split the width EQUALLY between columns, which
            // gave a one-word label the same share as a prose column. Left
            // content-sized, a short label column stays narrow, the prose
            // column takes the remainder, and gridColumnAlignment positions the
            // cell inside its column again.
            .fixedSize(horizontal: false, vertical: true)
            .gridColumnAlignment(columnAlignment(alignments, column))
    }

    private func columnAlignment(
        _ alignments: [PresentationIntent.TableColumn.Alignment], _ column: Int
    ) -> HorizontalAlignment {
        switch alignments.indices.contains(column) ? alignments[column] : .left {
        case .center: .center
        case .right: .trailing
        default: .leading
        }
    }

    /// The same per-column alignment applied to the WRAPPED lines inside a cell.
    private func textAlignment(
        _ alignments: [PresentationIntent.TableColumn.Alignment], _ column: Int
    ) -> TextAlignment {
        switch alignments.indices.contains(column) ? alignments[column] : .left {
        case .center: .center
        case .right: .trailing
        default: .leading
        }
    }
}

// MARK: - Transcript pane

private struct TranscriptPane: View {
    let meeting: Meeting
    let segments: [TranscriptSegment]
    /// G2 §4: durable speaker renames by label (incl. stale rows).
    var renames: [String: SpeakerRename] = [:]
    /// G2 §4 (L-6): whether a persisted diarization artifact exists (governs the
    /// rename popover's honest "applies after regenerate" copy).
    var artifactPresence = DiarizationArtifactPresence(system: true, mic: true)
    @Binding var scrollTarget: Int64?
    var searchTerms: [String] = []
    /// Copy-button labels follow the meeting's dominant language, matching
    /// the notes pane's section titles.
    var portuguese = false
    @State private var filter = ""

    private var visible: [TranscriptSegment] {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return segments }
        return segments.filter {
            $0.text.localizedCaseInsensitiveContains(needle)
                || ($0.speakerName?.localizedCaseInsensitiveContains(needle) ?? false)
        }
    }

    private var destinationMatchIDs: [Int64] {
        segments.compactMap { segment in
            guard let id = segment.id,
                SearchTextMatcher.contains(segment.text, terms: searchTerms)
            else { return nil }
            return id
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.tertiary)
                    TextField("Find in transcript", text: $filter)
                        .textFieldStyle(.plain)
                        .accessibilityLabel("Find in transcript")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 7))
                // Copy All (V1.1): the FULL transcript (filter ignored) as
                // readable text — speaker names + timestamps.
                CopyAllButton(
                    label: portuguese ? "Copiar Transcrição" : "Copy Transcript",
                    copiedLabel: portuguese ? "Copiado" : "Copied",
                    accessibilityLabel: "Copy the full transcript with speakers and timestamps"
                ) { TranscriptCopyText.assemble(segments) }
                    .disabled(segments.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            if !searchTerms.isEmpty {
                HStack(spacing: 10) {
                    SearchDestinationBanner(terms: searchTerms, location: "transcript")
                    Spacer()
                    Text("\(destinationMatchIDs.count) match\(destinationMatchIDs.count == 1 ? "" : "es")")
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Button {
                        moveSearchMatch(by: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.borderless)
                    .disabled(destinationMatchIDs.isEmpty)
                    .help("Previous search match")
                    .accessibilityLabel("Previous search match")
                    Button {
                        moveSearchMatch(by: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .disabled(destinationMatchIDs.isEmpty)
                    .help("Next search match")
                    .accessibilityLabel("Next search match")
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(visible, id: \.ord) { segment in
                            TranscriptRow(
                                meeting: meeting, segment: segment,
                                rename: renames[segment.speakerLabel],
                                artifactPresence: artifactPresence,
                                searchTerms: searchTerms,
                                highlighted: segment.id == scrollTarget)
                                .id(segment.id ?? -1)  // non-optional: must match scrollTo(Int64)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .transientScrollIndicators()
                .onChange(of: scrollTarget) {
                    if let target = scrollTarget {
                        withAnimation { proxy.scrollTo(target, anchor: .center) }
                    }
                }
                .onAppear {
                    if let target = scrollTarget {
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
            }
        }
        .overlay {
            if segments.isEmpty {
                ContentUnavailableView("No Transcript", systemImage: "text.quote")
            }
        }
    }

    private func moveSearchMatch(by delta: Int) {
        let ids = destinationMatchIDs
        guard !ids.isEmpty else { return }
        let current = scrollTarget.flatMap { ids.firstIndex(of: $0) }
        let origin = current ?? (delta > 0 ? -1 : 0)
        let next = (origin + delta + ids.count) % ids.count
        scrollTarget = ids[next]
    }
}

private struct TranscriptRow: View {
    @Environment(AppEnvironment.self) private var appEnv
    let meeting: Meeting
    let segment: TranscriptSegment
    /// G2 §4: the durable rename for this label, if any (stale rows render the
    /// label unnamed + a re-confirmation prompt).
    var rename: SpeakerRename?
    /// G2 §4 (L-6): whether a persisted diarization artifact exists.
    var artifactPresence = DiarizationArtifactPresence(system: true, mic: true)
    var searchTerms: [String] = []
    let highlighted: Bool

    @State private var showRename = false

    /// The user-reserved mic-track label is never user-renameable (it is the
    /// recording user).
    private var renameable: Bool { segment.speakerLabel != TranscriptSegment.userLabel }

    /// G3: an unnamed mic track (pre-onboarding identity → `speakerName` nil)
    /// reads "You" rather than the raw "user" reservation label. A named mic
    /// track shows the resolved name; non-mic speakers are unchanged.
    private var micAwareSpeakerLabel: String {
        if let name = segment.speakerName { return name }
        if segment.speakerLabel == TranscriptSegment.userLabel { return "You" }
        return segment.speakerLabel
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(timestamp)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 52, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                speakerLabelView
                SearchHighlightedText(
                    source: AttributedString(
                        segment.text.trimmingCharacters(in: .whitespaces)),
                    terms: searchTerms)
                    .font(.system(size: 13, design: .rounded))
                    .lineSpacing(3)
                    .foregroundStyle(.primary.opacity(0.88))
                    .textSelection(.enabled)
            }
        }
        .padding(8)
        .background(
            highlighted ? Theme.accent.opacity(0.12) : .clear,
            in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var speakerLabelView: some View {
        // NH-E: an `unattributed` rename is label-literal and always applied, so
        // it NEVER renders the re-confirmation badge — even a legacy stale row.
        let isStale = (rename?.stale ?? false)
            && !SpeakerRename.isAnchorless(segment.speakerLabel)
        HStack(spacing: 5) {
            Button {
                if renameable { showRename = true }
            } label: {
                Text(micAwareSpeakerLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(segment.speakerName == nil ? .secondary : .primary)
            }
            .buttonStyle(.plain)
            .disabled(!renameable)
            .help(renameable ? "Rename this speaker" : "")
            if isStale {
                Text("rename needs re-confirmation")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .popover(isPresented: $showRename) {
            SpeakerRenamePopover(
                meeting: meeting, speakerLabel: segment.speakerLabel,
                currentName: segment.speakerName,
                hasDiarizationArtifact: artifactPresence.containsArtifact(
                    for: segment.speakerLabel),
                pipeline: appEnv.pipeline, isPresented: $showRename)
                .frame(width: 300)
        }
    }

    private var timestamp: String {
        let total = Int(segment.startSeconds)
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

// MARK: - Overlay + banners + inspector

private struct ProcessingOverlay: View {
    let stage: PipelineStage

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Processing — \(stageLabel)")
                .font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .modifier(GlassCapsule())
        .accessibilityLabel("Processing, current stage \(stageLabel)")
    }

    private var stageLabel: String {
        switch stage {
        case .ingest, .transcode: "preparing audio"
        case .asr: "transcribing"
        case .diarize, .merge: "separating speakers"
        case .correct, .languageStats: "correcting vocabulary"
        case .resolveSpeakers, .applyLLMNames: "naming speakers"
        case .notes: "writing notes"
        case .persistTranscript, .persistNotes, .finalize: "finishing up"
        }
    }
}

struct QuietBanner: View {
    let text: String
    let systemImage: String
    let tint: Color
    let accessibilityPrefix: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("\(accessibilityPrefix): \(text)")
    }
}

// MARK: - Editable title (V1.1 inline rename)

/// Click-to-edit meeting title: Enter/focus-loss commits, Escape cancels.
/// The commit goes through `ProcessingPipeline.renameMeeting` — a content
/// mutation that re-mints the evidence payload on a `ready` meeting (the
/// old queued payload is superseded per D12 when the new one delivers).
/// Calendar-sourced titles are just as renameable; the rename wins.
private struct EditableTitle: View {
    let meeting: Meeting
    @Environment(AppEnvironment.self) private var appEnv
    @Environment(AppUIState.self) private var uiState
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        if editing {
            TextField("Meeting title", text: $draft)
                .textFieldStyle(.plain)
                .font(Design.displayFont(26))
                .focused($focused)
                .onSubmit { commit() }
                .onExitCommand { editing = false }  // Escape cancels
                .onChange(of: focused) {
                    if !focused, editing { commit() }  // focus loss commits
                }
                .accessibilityLabel("Meeting title, editing")
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Text(meeting.title)
                    .font(Design.displayFont(26))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        draft = meeting.title
                        editing = true
                        focused = true
                    }
                    .help("Click to rename")
                    .accessibilityLabel("Meeting title: \(meeting.title)")
                    .accessibilityHint("Click to rename")
                // G12 §3: a subtle provenance caption — "from calendar" /
                // "suggested by notes" for the non-user, non-default tiers;
                // nothing for a user rename or the bare date default.
                if let caption = Self.sourceCaption(meeting.titleSource) {
                    Text(caption)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The provenance caption for the title's tier. `user`/`default` show
    /// nothing (an explicit name and the bare date need no annotation).
    static func sourceCaption(_ source: TitleSource) -> String? {
        switch source {
        case .calendar: return "from calendar"
        case .llm: return "suggested by notes"
        case .user, .default: return nil
        }
    }

    private func commit() {
        editing = false
        let newTitle = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newTitle.isEmpty, newTitle != meeting.title else { return }
        let pipeline = appEnv.pipeline
        let uiState = uiState
        let id = meeting.id
        Task {
            // Re-mint + supersession semantics live in the pipeline; the
            // detail observation refreshes the shown title. Single-flight by
            // design: a rename submitted while a processing run is in flight
            // queues BEHIND it — this await drains silently and the title
            // visibly updates only when the run finishes (spec-pinned).
            do {
                _ = try await pipeline.renameMeeting(meetingID: id, to: newTitle)
                uiState.lastActionError = nil
            } catch {
                uiState.lastActionError = "Could not rename the meeting: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Audio player (V1.1)

/// Standard transport (play/pause + scrubber + elapsed/total) over the
/// retained meeting audio. Captured meetings write TWO tracks —
/// `audio.m4a` (system/other side) and `audio_mic.m4a` (the user's own mic) —
/// and the player MIXES BOTH so the user hears their own voice on playback
/// (field bug 2026-06-12: only `audio.m4a` was played, so the user's voice was
/// missing entirely even though it is plainly in the transcript). The mix is
/// an AVMutableComposition with the two files as parallel audio tracks,
/// time-aligned with the SAME per-part offsets the transcode stitcher uses, so
/// the player timeline matches the transcript timeline. Imported (single-track)
/// meetings just play `audio.m4a`. Hidden when no audio exists yet.
// `internal` (not `private`) so the cross-track alignment + pitch pins in
// BlaiseAppTests call the REAL `composition(for:)` builder rather than a
// replicated copy (sync-fix audit L-2). The view is still module-private in
// practice — nothing outside this file constructs it.
struct AudioPlayerView: View {
    /// The system track — half of the fileExists() gate.
    let audioURL: URL
    /// Source for the two-track composition plan (part offsets + mic/system
    /// files). The view resolves placements off `database` asynchronously.
    let database: BlaiseDatabase
    /// The mic track (part 1) — the other half of the gate (L-3: a mic-only
    /// meeting whose system track was lost still has playable audio).
    private var micURL: URL { database.paths.audioMicURL(meetingID) }
    let meetingID: MeetingID
    /// Transport tint: the direction accent, or the meeting's own hue
    /// (aquarela's adaptive tinting). No `Design`-derived default: `Design`
    /// is MainActor (runtime-switchable), and stored-property defaults are
    /// nonisolated — callers pass it.
    let tint: Color
    /// Stable per-meeting seed for the decorative waveform (estúdio).
    var seed: String = ""
    @State private var controller = AudioPlayerController()
    /// Sticky speed shared across meetings (UserDefaults-backed). The shared
    /// store is observable; a computed accessor keeps it out of the
    /// memberwise initializer (call sites pass only audioURL/tint/seed).
    private var speedStore: PlaybackSpeedStore { PlaybackSpeedStore.shared }
    /// Pre-play duration (the controller loads lazily on first play; the
    /// total time should read correctly before that).
    @State private var fileDuration: Double = 0
    /// The mixed-playback asset (system + mic as parallel tracks, per-part
    /// offsets), built off the database in `.task`. nil until resolved.
    @State private var mixedAsset: AVAsset?
    /// Resolution of the two-track plan. The transport stays disabled until the
    /// composition resolves (M-1: a tap during resolution must NOT load the
    /// system-only fallback, which would drop the user's mic for the view's
    /// whole lifetime — `load(asset:)` only ever attaches the first asset). On
    /// `.unreadable` (every retained file unreadable) the transport stays
    /// disabled and shows the honest read-error message (M-3).
    @State private var resolution: PlaybackResolution = .resolving
    /// System-track attenuation mix (M-2), built with the composition. Applied
    /// to the player item so the user's mic is not buried under the other side.
    @State private var mixedAudioMix: AVAudioMix?

    enum PlaybackResolution { case resolving, ready, unreadable }

    static let logger = Logger(subsystem: BlaiseBundle.identifier, category: "playback")

    var body: some View {
        // Gate on EITHER retained track existing (L-3): a captured meeting that
        // lost its system track but kept its mic m4a still has playable audio —
        // the planner gives it valid mic-only placements. Gating on the system
        // file alone hid the transport from exactly those mic-only meetings.
        if FileManager.default.fileExists(atPath: audioURL.path)
            || FileManager.default.fileExists(atPath: micURL.path)
        {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Button {
                        // M-1: never load the system-only fallback. Until the
                        // composition resolves the button is disabled (below),
                        // so a tap can only land on the resolved mixed asset —
                        // the mic-less single-file path can no longer leak in.
                        guard let mixedAsset else { return }
                        controller.toggle(asset: mixedAsset, audioMix: mixedAudioMix)
                    } label: {
                        ZStack {
                            Circle()
                                .fill(tint.opacity(0.18))
                            Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(tint)
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(controller.isPlaying ? "Pause recording" : "Play recording")
                    Text(Self.clock(controller.current))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if Design.direction == .estudio || Design.direction == .fluido {
                        // Studio transport: a waveform scrubber — played bars
                        // burn cyan→violet, the rest wait in the dark.
                        WaveformScrubber(
                            duration: controller.duration, current: controller.current,
                            seed: seed
                        ) { seconds, finished in
                            controller.scrubEditing(true)
                            controller.setScrubTarget(seconds)
                            if finished { controller.scrubEditing(false) }
                        }
                        .accessibilityLabel("Playback position")
                    } else {
                        Slider(
                            value: Binding(
                                get: { controller.current },
                                set: { controller.setScrubTarget($0) }),
                            in: 0...max(controller.duration, 0.01),
                            onEditingChanged: { controller.scrubEditing($0) }
                        )
                        .controlSize(.small)
                        .tint(tint)
                        .accessibilityLabel("Playback position")
                    }
                    Text(Self.clock(max(controller.duration, fileDuration)))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    SpeedControl(tint: tint, speed: speedStore.speed) {
                        speedStore.speed = speedStore.speed.next
                    }
                }
                .task(id: audioURL) {
                    // A re-run (audioURL changed) must re-gate: drop back to
                    // resolving so a stale `.ready` cannot enable the transport
                    // over the previous meeting's asset.
                    resolution = .resolving
                    // Seed the controller with the sticky speed so the very
                    // first play already honors it.
                    controller.speed = speedStore.speed
                    // Resolve the two-track composition plan (part offsets +
                    // mic/system files). A captured meeting yields system+mic
                    // placements; an imported meeting yields one system file.
                    let parts = await CaptureStitcher.plan(database: database, meetingID: meetingID)
                    // Load each part file's real duration up front: row-less
                    // residue must append at the END of the prior part's audio
                    // (the stitcher's `emitted` anchor), which needs durations.
                    // Reused below so the composition loader does not re-read.
                    let durations = await Self.durations(
                        for: parts.flatMap { [$0.systemM4A, $0.micM4A].compactMap { $0 } })
                    let resolved = CaptureStitcher.playbackPlacements(
                        parts: parts, durations: durations)
                    // Cross-track sync depends on a trustworthy per-track
                    // real-time scale on every part. If it is missing anywhere
                    // (open/derived part, unreadable file) the two tracks would
                    // drift apart on playback — out-of-sync is worse than a
                    // missing track (the user, 2026-06-12). Fall back to the system
                    // track alone (the user's mic survives in the transcript and
                    // notes), at unity.
                    let trustworthy = CaptureStitcher.playbackScalingTrustworthy(
                        placements: resolved)
                    let placements: [CaptureStitcher.PlaybackPlacement]
                    if resolved.isEmpty {
                        placements = [CaptureStitcher.PlaybackPlacement(
                            track: .system, url: audioURL, startSeconds: 0)]
                    } else if trustworthy {
                        placements = resolved
                    } else {
                        Self.logger.warning(
                            "playback scale untrusted for \(meetingID, privacy: .public); single-track fallback")
                        let system = resolved.filter { $0.track == .system }
                        placements = (system.isEmpty ? resolved : system).map {
                            // Unity scale: a track without a trustworthy span
                            // plays at its own length rather than a guessed one.
                            CaptureStitcher.PlaybackPlacement(
                                track: $0.track, url: $0.url, startSeconds: $0.startSeconds)
                        }
                    }
                    let (asset, audioMix, anyReadable) = await Self.composition(
                        for: placements, durations: durations)
                    mixedAsset = asset
                    mixedAudioMix = audioMix
                    // Honest failure (M-3): an empty composition (every file
                    // unreadable) never resolves to `.failed` on its own — an
                    // AVPlayerItem over an empty composition stays `.unknown`
                    // forever. Surface the read-error state from the resolved
                    // plan instead of waiting on item status.
                    resolution = anyReadable ? .ready : .unreadable
                    // Pre-play total = the longest track's end (mic may outrun
                    // system, field example mic 1717.7 s vs system 1578.1 s).
                    if let seconds = try? await asset.load(.duration).seconds, seconds.isFinite {
                        fileDuration = seconds
                    }
                }
                .onChange(of: speedStore.speed) { _, newValue in
                    controller.speed = newValue
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Design.direction == .aquarela ? AnyShapeStyle(tint.opacity(0.08)) : AnyShapeStyle(.quaternary.opacity(0.3)),
                    in: RoundedRectangle(cornerRadius: 10))
                // Honest transport: disabled while the plan is still resolving
                // (M-1: no fallback play before the mixed asset exists), when
                // the resolved plan has nothing readable (M-3), or if the player
                // item later fails (corrupt m4a — the atomic encode makes a
                // PARTIAL file unreachable). Never pretends to play.
                .disabled(resolution != .ready || controller.failed)
                if resolution == .unreadable || controller.failed {
                    Text("This recording could not be read for playback.")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Playback error: the audio file could not be read")
                }
            }
            .frame(maxWidth: 480)
            .onDisappear { controller.teardown() }
        }
    }

    static func clock(_ seconds: Double) -> String {
        let total = seconds.isFinite ? Int(seconds.rounded()) : 0
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Per-file durations (seconds) for the placement planner: row-less residue
    /// appends at the END of the prior part's audio, which needs real durations
    /// (H-1). Unreadable/zero-duration files are omitted (the planner then
    /// treats them as 0). Reused as the composition insert duration so each file
    /// is read once.
    static func durations(for urls: [URL]) async -> [URL: Double] {
        var result: [URL: Double] = [:]
        for url in urls {
            if let duration = try? await AVURLAsset(url: url).load(.duration),
                duration.isValid, duration.seconds > 0
            {
                result[url] = duration.seconds
            }
        }
        return result
    }

    /// Builds the mixed-playback asset: each placement's file becomes a
    /// parallel audio track inserted at its absolute REAL-TIME offset and
    /// stretched (`scaleTimeRange`) by `placement.timeScale` from its drifted
    /// file duration onto the part's wall-clock span, so the system (other
    /// side) and mic (the user's own voice) play together on one real-time
    /// axis — the 2026-06-12 sync fix. A single placement (imported meeting, or
    /// the untrusted-scale single-track fallback) yields a one-track
    /// composition at unity. Once both tracks are scaled to wall-clock their
    /// real durations match the recorded span; the composition's duration is
    /// the latest end, so playback reaches the user's trailing speech.
    ///
    /// System tracks are attenuated by `CaptureStitcher.systemTrackPlaybackGain`
    /// through an AVAudioMix so the user's mic sits within ~6 dB of the other
    /// side (mix-balance fix). The mix is
    /// returned alongside the composition (AVComposition carries no mix itself);
    /// the controller applies it to the player item.
    ///
    /// An unreadable file is skipped. `anyReadable` is false when EVERY file was
    /// skipped (empty composition): an AVPlayerItem over an empty composition
    /// never resolves to `.failed` (it stays `.unknown` forever), so the caller
    /// keys the honest read-error state on this flag, not on item status (M-3).
    ///
    /// Pitch correction (2026-06-12): a `scaleTimeRange`-drifted track is
    /// rendered with PER-TRACK `audioTimePitchAlgorithm = .varispeed` (set on
    /// its `AVMutableAudioMixInputParameters`), so the stretch onto wall-clock
    /// is rate-COUPLED and the baked-in ~1.088× pitch error (the "squeak") is
    /// corrected at the same time as the timing — verified to ≤1% of true on
    /// real meetings (sync-fix H-1). Every NON-drifted track keeps
    /// `.spectral` (pitch-preserving), so the 1×/1.5×/2× speed control stays
    /// pitch-preserved on those tracks. A varispeed track DOES pitch-shift under
    /// `player.rate` at 1.5×/2× — the accepted single-track tradeoff for getting
    /// the default 1× pitch perfect.
    static func composition(
        for placements: [CaptureStitcher.PlaybackPlacement], durations: [URL: Double]
    ) async -> (asset: AVAsset, audioMix: AVAudioMix?, anyReadable: Bool) {
        let composition = AVMutableComposition()
        // Per-track render parameters: which tracks are system (attenuated) and
        // which were drift-scaled (varispeed pitch correction).
        var systemTracks: [AVMutableCompositionTrack] = []
        var driftCorrectedTracks: [AVMutableCompositionTrack] = []
        for placement in placements {
            let asset = AVURLAsset(url: placement.url)
            guard
                let source = try? await asset.loadTracks(withMediaType: .audio).first,
                let duration = try? await asset.load(.duration),
                duration.isValid, duration.seconds > 0,
                let compTrack = composition.addMutableTrack(
                    withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            // L-2: a backward wall-clock step (NTP) could make a part's offset
            // negative; insert at a negative time throws and silently drops the
            // part. Clamp to 0 (the stitcher clamps too) and log, so the part
            // stays audible rather than vanishing.
            let startSeconds = placement.startSeconds
            if startSeconds < 0 {
                Self.logger.warning(
                    "playback placement start \(startSeconds, format: .fixed(precision: 3)) s < 0 (backward wall-clock step); clamping to 0")
            }
            let at = CMTime(seconds: max(0, startSeconds), preferredTimescale: 600)
            do {
                try compTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: duration), of: source, at: at)
            } catch {
                composition.removeTrack(compTrack)
                continue
            }
            // Sync fix (2026-06-12): the capture aggregate's mic and system
            // clocks drift, so a file's own duration is NOT real time. Stretch
            // the inserted segment from its file duration onto the part's
            // wall-clock span (`timeScale`), putting both tracks on one
            // real-time axis. scaleKnown==false keeps unity (single-track
            // fallback path), so this is a no-op there. A scaled track is
            // rendered with `.varispeed` (below) so the stretch also corrects
            // the baked-in pitch drift.
            if placement.scaleKnown, placement.timeScale > 0,
                abs(placement.timeScale - 1.0) > 0.0005
            {
                let target = CMTime(
                    seconds: duration.seconds * placement.timeScale, preferredTimescale: 600)
                let inserted = CMTimeRange(start: at, duration: duration)
                compTrack.scaleTimeRange(inserted, toDuration: target)
                driftCorrectedTracks.append(compTrack)
            }
            if placement.track == .system { systemTracks.append(compTrack) }
        }
        let anyReadable = !composition.tracks.isEmpty
        // Build per-track mix parameters. A track needs an entry if it is
        // drift-scaled (pitch-correcting varispeed) and/or a system track (mix
        // attenuation). Tracks that need neither are left to the item default
        // (`.spectral`, pitch-preserving). M-2: attenuate the system tracks
        // only when a mic track is actually present — a one-track imported or
        // system-only meeting plays at unity, nothing to balance against.
        let hasMic = placements.contains { $0.track == .mic } && anyReadable
        let attenuateSystem = hasMic && !systemTracks.isEmpty
        let parameterized = Set(driftCorrectedTracks).union(
            attenuateSystem ? Set(systemTracks) : [])
        guard !parameterized.isEmpty else { return (composition, nil, anyReadable) }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameterized.map { track in
            let params = AVMutableAudioMixInputParameters(track: track)
            if driftCorrectedTracks.contains(track) {
                // Rate-coupled stretch: corrects timing AND pitch together.
                params.audioTimePitchAlgorithm = .varispeed
            }
            if attenuateSystem, systemTracks.contains(track) {
                params.setVolume(CaptureStitcher.systemTrackPlaybackGain, at: .zero)
            }
            return params
        }
        return (composition, mix, anyReadable)
    }
}

/// Compact pitch-preserving speed control: a single pill that cycles
/// 1× → 1.5× → 2× → 1× on tap. Restrained and direction-consistent — it
/// reads the `tint` the transport already uses, fills faintly when sped up
/// (1×), and shows the rate in the same monospaced 11pt as the timecodes,
/// so it looks right in all four directions without per-direction chrome.
private struct SpeedControl: View {
    let tint: Color
    let speed: PlaybackSpeed
    let onTap: () -> Void

    var body: some View {
        let active = speed != .x1
        Button(action: onTap) {
            Text(speed.label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(active ? tint : Color.secondary)
                .frame(minWidth: 34)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(tint.opacity(active ? 0.18 : 0.0))
                )
                .overlay(
                    Capsule().strokeBorder(
                        active ? tint.opacity(0.35) : Color.secondary.opacity(0.25),
                        lineWidth: 1)
                )
                .contentTransition(.numericText())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Playback speed")
        .accessibilityValue(speed.label)
        .accessibilityHint("Cycles playback speed between 1×, 1.5×, and 2×")
        .help("Playback speed (pitch preserved)")
    }
}

/// Estúdio's decorative waveform transport: deterministic bars from the
/// meeting's id (no audio analysis — this is a scrubber with personality,
/// not a measurement). Drag or click to seek.
private struct WaveformScrubber: View {
    let duration: Double
    let current: Double
    let seed: String
    /// (targetSeconds, finished) — finished commits the seek.
    let onScrub: (Double, Bool) -> Void

    private var seedValue: Double {
        var hash: UInt64 = 5381
        for byte in seed.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return Double(hash % 977)
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let x = Double(index) * 0.83 + seedValue
        let value = abs(sin(x) * 0.62 + sin(x * 2.31) * 0.38)
        return CGFloat(0.18 + 0.82 * value)
    }

    var body: some View {
        GeometryReader { geo in
            let barCount = max(24, Int(geo.size.width / 5))
            let progress = duration > 0 ? min(max(current / duration, 0), 1) : 0
            HStack(spacing: 2) {
                ForEach(0..<barCount, id: \.self) { index in
                    let played = Double(index) / Double(max(1, barCount - 1)) <= progress
                    Capsule()
                        .fill(
                            played
                                ? AnyShapeStyle(
                                    LinearGradient(
                                        colors: [Design.accent, Design.support],
                                        startPoint: .top, endPoint: .bottom))
                                : AnyShapeStyle(Color.white.opacity(0.13))
                        )
                        .frame(width: 3, height: max(3, barHeight(index) * geo.size.height))
                        .frame(maxHeight: .infinity)
                }
            }
            .animation(.linear(duration: 0.2), value: progress)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onScrub(fraction(value.location.x, geo.size.width) * duration, false)
                    }
                    .onEnded { value in
                        onScrub(fraction(value.location.x, geo.size.width) * duration, true)
                    }
            )
        }
        .frame(height: 24)
    }

    private func fraction(_ x: CGFloat, _ width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return min(max(Double(x / width), 0), 1)
    }
}

/// Sticky playback speed, shared across meetings and persisted in
/// UserDefaults — the `DesignSelection` idiom (a user who listens at 1.5×
/// wants it to stay 1.5× on the next meeting). The pure `PlaybackSpeed`
/// enum and its saved-value resolution live in BlaiseCore (unit-tested);
/// this is just the observable store the player binds to.
@MainActor @Observable
final class PlaybackSpeedStore {
    static let shared = PlaybackSpeedStore()
    private static let defaultsKey = "BlaisePlaybackSpeed"

    var speed: PlaybackSpeed {
        didSet {
            UserDefaults.standard.set(speed.rawValue, forKey: Self.defaultsKey)
        }
    }

    private init() {
        speed = PlaybackSpeed.resolved(
            saved: UserDefaults.standard.string(forKey: Self.defaultsKey))
    }
}

/// AVPlayer wrapper: lazy load on first play, periodic time observer for
/// the scrubber, seek on scrub end, auto-reset at end of audio. Observes
/// the item's status: a `.failed` item flips `failed` (and clears
/// `isPlaying`) so the view never shows a playing transport over a dead
/// item.
///
/// Pitch-correct on any output device: a 16 kHz mono file plays at natural
/// pitch because AVPlayer resamples to the device rate (it never feeds the
/// 16 kHz buffers raw into a 44.1/48 kHz connection — that would chipmunk).
/// Speed control (1×/1.5×/2×) is pitch-PRESERVING on every track that plays at
/// its native rate: the item's default `audioTimePitchAlgorithm` is `.spectral`.
/// A clock-drift-corrected track is the exception — `composition(for:)` renders
/// it with per-track `.varispeed` so the wall-clock stretch corrects its pitch
/// at 1×; that one track therefore pitch-shifts at 1.5×/2× (accepted tradeoff).
/// Playback uses `player.rate` (not `play()`, which would reset
/// the rate to 1×).
@MainActor @Observable
private final class AudioPlayerController {
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var scrubbing = false
    private(set) var isPlaying = false
    /// The AVPlayerItem failed (unreadable/corrupt audio): transport disabled.
    private(set) var failed = false
    var current: Double = 0
    private(set) var duration: Double = 0
    /// The active playback speed; applied live to a playing player.
    var speed: PlaybackSpeed = .x1 {
        didSet {
            // Re-rate only while playing — setting `rate` on a paused player
            // would start it. At end-of-file, leave it paused.
            if isPlaying { player?.rate = speed.rate }
        }
    }

    func toggle(asset: AVAsset, audioMix: AVAudioMix? = nil) {
        load(asset: asset, audioMix: audioMix)
        guard let player, !failed else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if duration > 0, current >= duration - 0.1 {
                player.seek(to: .zero)
                current = 0
            }
            // `rate = speed.rate` plays at the chosen pitch-preserving speed
            // (`play()` would force 1×).
            player.rate = speed.rate
            isPlaying = true
        }
    }

    func scrubEditing(_ editing: Bool) {
        scrubbing = editing
        if !editing {
            player?.seek(
                to: CMTime(seconds: current, preferredTimescale: 600),
                toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    func setScrubTarget(_ seconds: Double) {
        current = seconds
    }

    private func load(asset: AVAsset, audioMix: AVAudioMix? = nil) {
        guard player == nil else { return }
        let item = AVPlayerItem(asset: asset)
        // M-2: the system-track attenuation mix (the user's mic is otherwise
        // buried under the other side). nil for one-track meetings (unity).
        item.audioMix = audioMix
        // Default per-track time-pitch algorithm: `.spectral` (pitch-preserving,
        // Apple's highest-quality voice-friendly algorithm), so the 1×/1.5×/2×
        // speed control sounds natural instead of chipmunked. This is the
        // ITEM-level default; the audioMix overrides it PER-TRACK for any
        // clock-drift-scaled track (`.varispeed`, so the wall-clock stretch also
        // corrects that track's baked-in pitch — see `composition(for:)`). A
        // non-drifted track (imported, single-track, or undrifted meeting) keeps
        // `.spectral` and stays pitch-preserved at every speed.
        item.audioTimePitchAlgorithm = .spectral
        let player = AVPlayer(playerItem: item)
        self.player = player
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.scrubbing else { return }
                self.current = time.seconds
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isPlaying = false
            }
        }
        // Item-status honesty: the status resolves asynchronously after the
        // item attaches; on `.failed`, stop claiming playback and disable
        // the transport. (KVO may fire off-main — hop.)
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.failed = true
                self.isPlaying = false
                self.player?.pause()
            }
        }
        Task { [weak self] in
            if let seconds = try? await item.asset.load(.duration).seconds, seconds.isFinite {
                self?.duration = seconds
            }
        }
    }

    func teardown() {
        player?.pause()
        isPlaying = false
        failed = false  // a reappear retries with a fresh item
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
        player = nil
    }
}

// MARK: - Copy All (V1.1)

/// Visible clipboard button (NSPasteboard) with a transient "Copied" state.
/// Labels are caller-localized (the meeting's dominant language, like the
/// surrounding section titles).
struct CopyAllButton: View {
    let label: String
    var copiedLabel = "Copied"
    let accessibilityLabel: String
    /// A permanent utility must not outrank the contextual actions beside it:
    /// on the notes header it wears the same borderless type as its neighbours.
    var quiet = false
    let text: () -> String
    @State private var copied = false

    @ViewBuilder
    var body: some View {
        if quiet {
            button.buttonStyle(.borderless)
        } else {
            button
        }
    }

    private var button: some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text(), forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Label(copied ? copiedLabel : label, systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: quiet ? 11 : 12))
        }
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Meeting info inspector: the editable Meet code (edits sweep pending
/// events; a resulting dispatch is status-dependent).
private struct MeetingInspector: View {
    @Bindable var model: MeetingDetailModel
    @Environment(AppEnvironment.self) private var appEnv
    @State private var code = ""
    @State private var loaded = false
    /// G16: this meeting's retained audio bytes (nil until read).
    @State private var audioBytes: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Meeting Info")
                .font(.headline)
            LabeledContent("Source") {
                Text(model.meeting?.source.rawValue ?? "—")
            }
            LabeledContent("Audio") {
                Text(audioSummary)
            }
            TextField("Meet code (abc-defg-hij)", text: $code)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Google Meet meeting code")
            Text("Used to match speaker events from the Meet extension.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear {
            if !loaded {
                code = model.meeting?.meetingCode ?? ""
                loaded = true
            }
        }
        .task(id: model.meeting?.audioDeletedAt) {
            guard let id = model.meeting?.id, model.meeting?.audioDeletedAt == nil else { return }
            audioBytes = await appEnv.audioUsage()?.entries.first { $0.meetingID == id }?.bytes
        }
    }

    private var audioSummary: String {
        guard let meeting = model.meeting else { return "—" }
        if let deletedAt = meeting.audioDeletedAt {
            let date = deletedAt.formatted(date: .abbreviated, time: .omitted)
            return meeting.audioDeletedReason == .cap
                ? "Deleted automatically \(date)" : "Deleted \(date)"
        }
        guard let audioBytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: audioBytes, countStyle: .file)
    }

    private func save() {
        guard let meeting = model.meeting else { return }
        let environment = appEnv
        let newCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            try? await MeetingRepository(database: environment.database)
                .setMeetingCode(meeting.id, to: newCode.isEmpty ? nil : newCode)
            guard !newCode.isEmpty else { return }
            // The edit triggers a pending-events sweep; dispatch processing
            // (status-dependent rule) for the meetings that actually RECEIVED
            // ingested data — under a recurring code that may not be the
            // edited meeting, and the edited meeting is dispatched only if it
            // received something itself.
            for meetingID in await environment.ingestor.sweep(meetingCode: newCode) {
                // F1 Inc2: the code-edit sweep is an auto path → enqueue
                // (origin .auto → refuseCancelled, never resurrects a cancelled meeting).
                await environment.processingQueue.enqueue(meetingID, origin: .auto)
            }
        }
    }
}
