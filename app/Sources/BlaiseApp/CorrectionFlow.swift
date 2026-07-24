import BlaiseCore
import SwiftUI

// G17: the "Suggest a correction… / Add a note…" flow on a finished
// meeting's notes. Every block gets a hover-revealed affordance (visible
// control; right-click is the shortcut; keyboard-reachable — the UX-review
// discoverability decision), the correction popover leads solely with
// "What's actually true?" (re-transcription is a demoted escape hatch), and
// the provenance line counts corrections and notes separately with a
// management popover where deletion is the undo.

/// The block a popover is anchored to.
struct CorrectionTarget: Identifiable, Equatable {
    enum Action { case correct, note }
    let id = UUID()
    var action: Action
    var section: MeetingCorrection.Section
    var blockText: String
}

/// What the correction popover hands back on save.
struct CorrectionSubmission {
    var section: MeetingCorrection.Section
    var quotedText: String
    var userText: String
    /// The demoted escape hatch: re-transcribe from the kept audio.
    var fullReprocess: Bool
}

/// Hover-revealed correction affordance around one notes block. The menu
/// control participates in the layout permanently (keyboard-reachable, no
/// reflow) and fades in on hover; `.contextMenu` mirrors the same actions.
struct CorrectableBlock<Content: View>: View {
    var section: MeetingCorrection.Section
    var blockText: String
    var enabled: Bool
    var onAction: (CorrectionTarget) -> Void
    @ViewBuilder var content: () -> Content

    @State private var hovering = false

    var body: some View {
        if enabled {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                content()
                Spacer(minLength: 0)
                Menu {
                    menuItems
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .opacity(hovering ? 1 : 0.06)
                .accessibilityLabel("Correct or annotate this block")
                .help("Suggest a correction or add a note")
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .contextMenu { menuItems }
        } else {
            content()
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        Button {
            onAction(CorrectionTarget(action: .correct, section: section, blockText: blockText))
        } label: {
            Label("Suggest a correction…", systemImage: "pencil.line")
        }
        Button {
            onAction(CorrectionTarget(action: .note, section: section, blockText: blockText))
        } label: {
            Label("Add a note…", systemImage: "note.text.badge.plus")
        }
    }
}

/// "Suggest a correction": quoted span (trimmable), "What's actually true?",
/// and the demoted re-transcription disclosure. The save button's label
/// follows the effective scope (UX review #4).
struct CorrectionPopover: View {
    var target: CorrectionTarget
    var onCancel: () -> Void
    var onSave: (CorrectionSubmission) -> Void

    @State private var quote: String = ""
    @State private var userText: String = ""
    @State private var fullReprocess = false
    @State private var showAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Suggest a correction")
                .font(.system(size: 14, weight: .bold))

            fieldLabel("In the notes")
            TextField("Quoted span", text: $quote, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .lineLimit(2...4)
                .help("Trim this down to the exact phrase the correction is about")

            fieldLabel("What's actually true?")
            TextEditor(text: $userText)
                .font(.system(size: 13))
                .frame(minHeight: 64, maxHeight: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.quaternary, lineWidth: 1))

            DisclosureGroup(isExpanded: $showAdvanced) {
                Toggle(isOn: $fullReprocess) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Re-transcribe from audio (~4 min)")
                            .font(.system(size: 12))
                        Text("Use when a word itself was misheard — the transcript is re-created from the kept audio.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                .padding(.top, 4)
            } label: {
                Text("Advanced")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Saved corrections survive later re-runs.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(fullReprocess ? "Save & re-transcribe" : "Save & re-write") {
                    onSave(CorrectionSubmission(
                        section: target.section, quotedText: quote,
                        userText: userText, fullReprocess: fullReprocess))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 380)
        .onAppear { quote = target.blockText }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold))
            .kerning(0.6)
            .foregroundStyle(.secondary)
    }
}

/// "Add a note": free, instant, ships now.
struct AddNotePopover: View {
    var target: CorrectionTarget
    var onCancel: () -> Void
    var onSave: (_ text: String) -> Void

    @State private var userText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add a note")
                .font(.system(size: 14, weight: .bold))
            Text("On \u{201C}\(Self.shortQuote(target.blockText))\u{201D}")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            TextEditor(text: $userText)
                .font(.system(size: 13))
                .frame(minHeight: 56, maxHeight: 110)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.quaternary, lineWidth: 1))
            HStack {
                Text("Free — no model call. Ships now.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Add note") {
                    onSave(userText)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    static func shortQuote(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 90 ? flat.prefix(89) + "…" : flat
    }
}

/// The provenance-line management popover: every correction/note row with
/// its status, edit-free v1 management (delete = undo), and a re-write
/// trigger when pending understanding rows exist.
struct CorrectionsListView: View {
    var rows: [MeetingCorrection]
    var busy: Bool
    var onDelete: (MeetingCorrection) -> Void
    var onRewrite: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Corrections & notes")
                .font(.system(size: 13, weight: .bold))
            if rows.isEmpty {
                Text("Nothing yet. Hover any notes block to suggest a correction or add a note.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            ForEach(rows, id: \.id) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(row.kind == .understanding ? "Correction" : "Note")
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(
                                    row.kind == .understanding
                                        ? Color.accentColor.opacity(0.15)
                                        : Color.yellow.opacity(0.25),
                                    in: Capsule())
                            statusBadge(row.status)
                        }
                        Text(row.userText)
                            .font(.system(size: 12))
                            .lineLimit(3)
                        Text("on \u{201C}\(AddNotePopover.shortQuote(row.quotedText))\u{201D}")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button {
                        onDelete(row)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .disabled(busy)
                    .help(row.kind == .understanding
                        ? "Delete — the next re-write runs without it"
                        : "Delete — removes the note and re-delivers")
                }
                .padding(.vertical, 2)
                Divider()
            }
            if rows.contains(where: { $0.kind == .understanding && $0.status == .pending }) {
                Button {
                    onRewrite()
                } label: {
                    Label(busy ? "Re-writing…" : "Re-write notes now", systemImage: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .disabled(busy)
                .help("Re-writes the notes from the saved transcript with all pending corrections (~30 s)")
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    @ViewBuilder
    private func statusBadge(_ status: MeetingCorrection.Status) -> some View {
        switch status {
        case .pending:
            Text("pending").font(.system(size: 10)).foregroundStyle(.orange)
        case .applied:
            Text("applied").font(.system(size: 10)).foregroundStyle(.secondary)
        case .stale:
            Text("lost its paragraph").font(.system(size: 10)).foregroundStyle(.red)
        }
    }
}
