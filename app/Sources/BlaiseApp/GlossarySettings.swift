import AppKit
import BlaiseCore
import Foundation
import Observation
import SwiftUI

// G1 §6 — Settings → Glossary tab. Source of truth = the file's RAW ENTRIES;
// the table mirrors them in file order with inline annotations from the load.

@MainActor @Observable
final class GlossarySettingsModel {
    private let dataRoot: URL

    var rows: [GlossaryRow] = []
    /// Source lines of the parsed rows (R2-L-3 exact diagnostic attribution).
    private var rowSourceLines: [Int] = []
    /// Latest load diagnostics (nil until a load/Check-now has run).
    var diagnostics: GlossaryDiagnostics?
    var loadedAt: Date?
    var hasEntriesRegion = true
    var saveError: String?

    /// Per-canonical annotation derived from the latest load's line-level
    /// diagnostics, keyed by folded canonical (rejected aliases / limited
    /// correction surface inline in the table).
    private(set) var annotations: [String: String] = [:]

    var glossaryURL: URL { MeetingPaths(rootURL: dataRoot).glossaryURL }

    init(dataRoot: URL) {
        self.dataRoot = dataRoot
    }

    /// Reads the file into the editor table + refreshes diagnostics (read-only).
    func load() {
        let text = (try? String(contentsOf: glossaryURL, encoding: .utf8)) ?? ""
        let editor = GlossaryEditor(fileText: text)
        rows = editor.rows
        rowSourceLines = editor.rowSourceLines
        hasEntriesRegion = editor.hasEntriesRegion
        checkNow()
    }

    /// "Check now" (§5b): perform a load purely to refresh diagnostics.
    func checkNow() {
        let load = PipelineVocabulary.user(dataRoot: dataRoot)
        diagnostics = load.diagnostics
        loadedAt = load.loadedAt
        rebuildAnnotations(load.diagnostics)
    }

    private func rebuildAnnotations(_ diagnostics: GlossaryDiagnostics) {
        annotations = GlossaryEditor.annotations(
            from: diagnostics, rows: rows, rowSourceLines: rowSourceLines)
    }

    func annotation(for row: GlossaryRow) -> String? {
        annotations[VocabNormalization.canonicalMode(row.canonical)]
    }

    // MARK: - Mutations (apply on Save)

    func add() {
        rows.append(GlossaryRow(canonical: "", aliases: []))
    }

    func delete(_ id: UUID) {
        rows.removeAll { $0.id == id }
    }

    /// Save = regenerate the region (temp + atomic rename), then reload.
    func save() {
        saveError = nil
        // §6 inline validation blocks the save: a `|` or leading `#` in ANY field
        // (canonical or alias) would re-parse as different fields on reload (M-4).
        if let invalid = GlossaryEditor.firstInvalidField(in: rows) {
            saveError = invalid.isAlias
                ? "Mishearing “\(invalid.field)”: \(invalid.hint)"
                : "“\(invalid.field)”: \(invalid.hint)"
            return
        }
        let text = (try? String(contentsOf: glossaryURL, encoding: .utf8)) ?? ""
        var editor = GlossaryEditor(fileText: text)
        guard editor.hasEntriesRegion else {
            saveError = "No “## Entries” section — use Restore entries section first."
            return
        }
        // Reconcile the editor's rows with the table's edited rows (the table is
        // the user's intent; drop blank-canonical rows).
        let edited = rows
            .map { GlossaryRow(canonical: $0.canonical.trimmingCharacters(in: .whitespaces),
                               aliases: $0.aliases.map { $0.trimmingCharacters(in: .whitespaces) }
                                   .filter { !$0.isEmpty }) }
            .filter { !$0.canonical.isEmpty }
        editor.replaceRows(with: edited)
        guard let out = editor.serialize() else {
            saveError = "Could not regenerate the glossary file."
            return
        }
        do {
            try GlossaryEditor.writeAtomically(out, to: glossaryURL)
            load()
        } catch {
            saveError = "Save failed: \(error.localizedDescription)"
        }
    }

    /// "Restore entries section" (§6): append `## Entries` + examples at EOF.
    func restoreEntriesSection() {
        saveError = nil
        let text = (try? String(contentsOf: glossaryURL, encoding: .utf8)) ?? ""
        guard !GlossaryEditor(fileText: text).hasEntriesRegion else { return }
        do {
            try GlossaryEditor.writeAtomically(
                GlossaryEditor.restoredText(from: text), to: glossaryURL)
            load()
        } catch {
            saveError = "Restore failed: \(error.localizedDescription)"
        }
    }

    var agentPrompt: String {
        "Open the file \(glossaryURL.path) and follow the instructions inside it: "
            + "fill the ## Entries section with the people, companies, products, and projects "
            + "from my context, one per line in the \"Canonical Name | misheard1 | misheard2\" "
            + "format. Read the SAFETY note in the file before adding any mishearing. "
            + "Do not edit anything above the ## Entries heading."
    }

    func copyAgentPrompt() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(agentPrompt, forType: .string)
    }

    func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([glossaryURL])
    }
}

// MARK: - View

struct GlossaryTab: View {
    @Environment(AppEnvironment.self) private var appEnv
    @State private var model: GlossarySettingsModel?
    @State private var corrections: NameCorrectionsModel?

    var body: some View {
        Form {
            if let model {
                GlossaryTabBody(model: model)
            }
            if let corrections {
                NameCorrectionsSection(model: corrections)
            }
        }
        .formStyle(.grouped)
        .task {
            if model == nil {
                let m = GlossarySettingsModel(dataRoot: appEnv.database.rootURL)
                m.load()
                model = m
            }
            if corrections == nil {
                let c = NameCorrectionsModel(database: appEnv.database)
                await c.load()
                corrections = c
            }
        }
    }
}

// MARK: - Notes name corrections (G2 §2 / §7)

@MainActor @Observable
final class NameCorrectionsModel {
    private let database: BlaiseDatabase
    var rows: [NameCorrection] = []

    init(database: BlaiseDatabase) {
        self.database = database
    }

    func load() async {
        rows = (try? await database.pool.read { try NameCorrectionStore.all($0) }) ?? []
    }

    func delete(_ row: NameCorrection) async {
        try? await database.pool.write {
            try NameCorrectionStore.delete($0, mishearedFolded: row.mishearedFolded)
        }
        await load()
    }

    /// The scope-consequence copy shown under each row (§2).
    func scopeConsequence(_ row: NameCorrection) -> String {
        row.everyday
            ? "applies to owners and speaker labels only — “\(row.mishearedFolded)” is an everyday word"
            : "applies everywhere"
    }
}

private struct NameCorrectionsSection: View {
    @Bindable var model: NameCorrectionsModel

    var body: some View {
        Section("Notes name corrections") {
            if model.rows.isEmpty {
                Text("No name corrections yet. Correct a misheard name in any meeting's notes and choose “Remember” to add one here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.rows, id: \.id) { row in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("\(row.mishearedFolded) → \(row.replacement)")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Button(role: .destructive) {
                            Task { await model.delete(row) }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Delete this correction")
                    }
                    Text(model.scopeConsequence(row))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
    }
}

private struct GlossaryTabBody: View {
    @Bindable var model: GlossarySettingsModel

    var body: some View {
        Section("Entries") {
            if model.rows.isEmpty {
                Text("No entries yet. Add names below, or let an AI agent fill the file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach($model.rows) { $row in
                GlossaryRowEditor(row: $row, annotation: model.annotation(for: row)) {
                    model.delete(row.id)
                }
            }
            HStack {
                Button {
                    model.add()
                } label: {
                    Label("Add entry", systemImage: "plus")
                }
                Spacer()
                Button("Save") { model.save() }
            }
            if let error = model.saveError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }

        Section("Diagnostics") {
            if !model.hasEntriesRegion {
                Label(
                    "This file has no “## Entries” section, so nothing is loaded.",
                    systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                Button("Restore entries section") { model.restoreEntriesSection() }
            }
            if let diagnostics = model.diagnostics {
                GlossaryDiagnosticsStrip(diagnostics: diagnostics, loadedAt: model.loadedAt)
            } else {
                Text("Not loaded yet — runs at the next meeting's processing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Check now") { model.checkNow() }
        }

        Section("Fill it with an agent") {
            Button {
                model.copyAgentPrompt()
            } label: {
                Label("Copy agent prompt", systemImage: "doc.on.clipboard")
            }
            Button {
                model.showInFinder()
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            Text(
                "Paste the prompt to an AI agent with access to your contacts and projects; it edits this file directly. Blaise screens every entry for safety on load."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct GlossaryRowEditor: View {
    @Binding var row: GlossaryRow
    let annotation: String?
    let onDelete: () -> Void

    @State private var aliasesText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("Canonical name", text: $row.canonical)
                    .textFieldStyle(.roundedBorder)
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Delete \(row.canonical)")
            }
            TextField("Mishearings (separate with commas)", text: $aliasesText)
                .textFieldStyle(.roundedBorder)
                .onChange(of: aliasesText) { _, newValue in
                    row.aliases = newValue.split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                }
            if let hint = GlossaryEditor.fieldRejectionHint(row.canonical) {
                Text(hint).font(.caption2).foregroundStyle(.orange)
            }
            // §6 inline validation also covers alias fields (M-4): a `|` or
            // leading `#` in a mishearing is flagged and blocks the save.
            if let badAlias = row.aliases.first(where: { GlossaryEditor.fieldRejectionHint($0) != nil }),
               let hint = GlossaryEditor.fieldRejectionHint(badAlias) {
                Text("Mishearing “\(badAlias)”: \(hint)").font(.caption2).foregroundStyle(.orange)
            }
            if let annotation {
                Text(annotation).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .onAppear { aliasesText = row.aliases.joined(separator: ", ") }
    }
}

private struct GlossaryDiagnosticsStrip: View {
    let diagnostics: GlossaryDiagnostics
    let loadedAt: Date?

    var body: some View {
        LabeledContent("Effective entries") {
            Text("\(diagnostics.effectiveEntries)").monospacedDigit()
        }
        LabeledContent("Aliases admitted") {
            Text("\(diagnostics.aliasesAdmitted)").monospacedDigit()
        }
        LabeledContent("Names limited") {
            Text("\(diagnostics.canonicalsLimited)").monospacedDigit()
        }
        if let loadedAt {
            LabeledContent("Last checked") {
                Text(loadedAt, style: .time).foregroundStyle(.secondary)
            }
        }
        ForEach(Array(diagnostics.items.enumerated()), id: \.offset) { _, item in
            if let text = GlossaryDiagnosticPresentation.line(item) {
                Text(text).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// Human-readable diagnostic lines for the Settings strip.
enum GlossaryDiagnosticPresentation {
    static func line(_ item: GlossaryDiagnosticItem) -> String? {
        let where_ = item.line > 0 ? "line \(item.line): " : ""
        switch item.reason {
        case .noEntriesHeading: return nil  // shown as its own warning + Restore
        case .fileMissing: return "Glossary file not found (it will be recreated)."
        case .fileUnreadable: return "Glossary file could not be read."
        case .glossaryRejected(let reason): return "Whole glossary skipped: \(reason)."
        case .glossaryTruncated(let count): return "\(count) entries past the 2,000 cap were dropped."
        case .regionEndedEarly(let line): return "A heading at line \(line) ended the entries section early — text below it is ignored."
        case .emptyCanonical: return "\(where_)empty name — skipped."
        case .duplicateCanonical: return "\(where_)duplicate name “\(item.prefix)” — first kept."
        case .aliasCollidesWithCanonical: return "\(where_)an alias repeats the name — line skipped."
        case .aliasDuplicated: return "\(where_)a duplicate alias — line skipped."
        case .emptyAlias: return "\(where_)empty mishearing field — dropped."
        case .aliasRejectedUnsafe(let reason): return "Alias “\(item.prefix)” not used (\(reason))."
        case .canonicalCorrectionLimited: return "“\(item.prefix)”: note spelling only — matches everyday words."
        case .entryRejected(let reason): return "“\(item.prefix)” dropped (\(reason))."
        case .markdownArtifact: return "\(where_)skipped a markdown line (“\(item.prefix)”)."
        }
    }
}
