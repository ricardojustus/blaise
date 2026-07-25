import BlaiseCore
import Foundation
import Observation
import SwiftUI

// G15 §3 — the participant-confirmation sheet: an editable name list pre-filled
// from calendar suggestions / grounded person hints, with the diarization
// cluster count as an advisory caption, and Confirm / Skip / "Don't ask again".

@MainActor @Observable
final class ParticipantConfirmModel {
    struct Row: Identifiable, Equatable {
        let id = UUID()
        var name: String
    }

    let meeting: Meeting
    private let env: AppEnvironment

    var rows: [Row] = [Row(name: "")]
    /// Advisory caption only — "Blaise heard N distinct voices" (§3); never a
    /// required row count.
    var voiceCount = 0
    var loading = true
    var working = false
    /// Set when Confirm/Skip did not take effect: the sheet stays open with this
    /// message instead of dismissing as if it had worked.
    var errorMessage: String?
    /// R4-F4: the answer can never succeed (the notes were already written), so
    /// the sheet stays open showing WHY, with a single Close — nothing left to
    /// retry, nothing left to answer.
    var terminal = false

    init(meeting: Meeting, env: AppEnvironment) {
        self.meeting = meeting
        self.env = env
    }

    /// Pre-fill from the best available hints (§3): calendar suggestions for the
    /// meeting's time window, then grounded person hints, otherwise one empty row.
    func load() async {
        async let names = env.participantPrefillNames(for: meeting)
        async let voices = env.participantVoiceCount(for: meeting.id)
        let (prefill, count) = await (names, voices)
        rows = prefill.isEmpty ? [Row(name: "")] : prefill.map { Row(name: $0) }
        voiceCount = count
        loading = false
    }

    var enteredNames: [String] { rows.map(\.name) }

    var hasAnyName: Bool {
        rows.contains { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    func addRow() { rows.append(Row(name: "")) }

    func removeRow(_ id: UUID) {
        rows.removeAll { $0.id == id }
        if rows.isEmpty { rows = [Row(name: "")] }
    }

    func binding(for id: UUID) -> Binding<String> {
        Binding(
            get: { [weak self] in self?.rows.first { $0.id == id }?.name ?? "" },
            set: { [weak self] newValue in
                guard let self, let idx = self.rows.firstIndex(where: { $0.id == id }) else { return }
                self.rows[idx].name = newValue
            })
    }

    /// Returns whether the sheet may dismiss.
    func confirm() async -> Bool {
        working = true
        let ok = await env.confirmParticipants(meetingID: meeting.id, names: enteredNames)
        let outcome = await resolve(ok: ok, retry: "Couldn't save the participants. Try again.")
        errorMessage = outcome.message
        terminal = outcome.terminal
        working = false
        return outcome.dismiss
    }

    /// Returns whether the sheet may dismiss.
    func skip(dontAskAgain: Bool) async -> Bool {
        working = true
        let ok = await env.skipParticipantConfirmation(
            meetingID: meeting.id, dontAskAgain: dontAskAgain)
        let outcome = await resolve(ok: ok, retry: "Couldn't skip right now. Try again.")
        errorMessage = outcome.message
        terminal = outcome.terminal
        working = false
        return outcome.dismiss
    }

    private func resolve(ok: Bool, retry: String) async -> AnswerOutcome {
        Self.outcome(
            succeeded: ok,
            notesAlreadyWritten: ok ? false : await env.meetingHasNotes(meeting.id),
            retry: retry)
    }

    struct AnswerOutcome: Equatable {
        var dismiss: Bool
        var message: String?
        /// The answer can never succeed — the sheet stays open on its message
        /// with a single Close, and that Close is the dismissal (R4-F4).
        var terminal = false
    }

    /// R3-F3: what the sheet does with the pipeline's answer. A refusal against
    /// a meeting whose notes are ALREADY written is not a retryable failure —
    /// the opt-in auto-skip took the answer's place after the five-minute window
    /// (G15 §2c) and §3 refuses a post-notes confirmation — so the sheet states
    /// that plainly instead of telling the user to retry something that can
    /// never succeed.
    ///
    /// R4-F4: it states it WHERE IT IS READ. Dismissing in the same turn as the
    /// message was assigned removed the only view containing it before a render
    /// pass — a silent close. The sheet therefore stays open (`dismiss: false`)
    /// in the TERMINAL shape, whose only control is Close; the exit is still one
    /// click and still cannot be retried into a dead end. Every other refusal
    /// keeps the sheet open with its retry message; Cancel is the exit there.
    static func outcome(
        succeeded: Bool, notesAlreadyWritten: Bool, retry: String
    ) -> AnswerOutcome {
        if succeeded { return AnswerOutcome(dismiss: true, message: nil) }
        if notesAlreadyWritten {
            return AnswerOutcome(
                dismiss: false, message: "Notes were generated without attendees.",
                terminal: true)
        }
        return AnswerOutcome(dismiss: false, message: retry)
    }
}

struct ParticipantConfirmSheet: View {
    @State private var model: ParticipantConfirmModel
    @Binding var isPresented: Bool
    @State private var dontAskAgain = false

    init(meeting: Meeting, env: AppEnvironment, isPresented: Binding<Bool>) {
        _model = State(initialValue: ParticipantConfirmModel(meeting: meeting, env: env))
        _isPresented = isPresented
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Who was in this meeting?")
                .font(.system(size: 15, weight: .semibold))
            Text(
                "Blaise couldn't learn the participants from your calendar or the Meet roster. Confirm the names so speaker labels and action-item owners are attributed correctly — then the notes are written."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            if model.voiceCount > 0 {
                Label(
                    "Blaise heard \(model.voiceCount) distinct voice\(model.voiceCount == 1 ? "" : "s")",
                    systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.loading {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.rows) { row in
                        HStack(spacing: 6) {
                            TextField("Name", text: model.binding(for: row.id))
                                .textFieldStyle(.roundedBorder)
                            Button {
                                model.removeRow(row.id)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Remove name")
                        }
                    }
                    Button {
                        model.addRow()
                    } label: {
                        Label("Add name", systemImage: "plus")
                    }
                    .buttonStyle(.plain)
                    .font(.callout)
                }
            }

            Text(
                "These are participants' display names. To standardize a spelling everywhere, add it in Settings → Glossary."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider()

            HStack {
                if model.terminal {
                    // R4-F4: nothing here can be answered any more (the notes
                    // are written). The reason above stays on screen and Close
                    // is the whole control set — no Confirm/Skip to press into
                    // a refusal, no Cancel that reads like "keep the question".
                    Spacer()
                    Button("Close") { isPresented = false }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Toggle("Don't ask again", isOn: $dontAskAgain)
                        .toggleStyle(.checkbox)
                        .font(.callout)
                    Spacer()
                    // R3-F3: the dismissal control every other sheet in the app
                    // has. Closing answers nothing — the question stays on the
                    // meeting's row (and its notification) until it is answered
                    // or auto-skipped.
                    Button("Cancel") { isPresented = false }
                        .keyboardShortcut(.cancelAction)
                        .disabled(model.working)
                    Button("Skip") {
                        Task {
                            if await model.skip(dontAskAgain: dontAskAgain) { isPresented = false }
                        }
                    }
                    .disabled(model.working)
                    Button("Confirm") {
                        Task {
                            if await model.confirm() { isPresented = false }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.working || model.loading || !model.hasAnyName)
                }
            }
        }
        .padding(20)
        .frame(width: 430)
        .task { await model.load() }
    }
}
