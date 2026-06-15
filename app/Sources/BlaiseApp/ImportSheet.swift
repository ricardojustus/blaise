import BlaiseCore
import SwiftUI
import UniformTypeIdentifiers

// File → Import Meeting Audio… (WAV/M4A): title + date + optional attendees
// + optional Meet code, then the widened import seam + a process() kick.
// Drag-drop onto the window lands on the same sheet.

struct ImportSheet: View {
    let sourceURL: URL
    let onDismiss: () -> Void

    @Environment(AppEnvironment.self) private var appEnv
    @Environment(AppUIState.self) private var uiState
    @State private var title = ""
    @State private var startedAt = Date()
    @State private var attendeesText = ""
    @State private var meetingCode = ""
    @State private var importError: String?
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import Meeting Audio")
                .font(.title3.weight(.semibold))
            LabeledContent("File") {
                Text(sourceURL.lastPathComponent)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
            DatePicker("Meeting date", selection: $startedAt)
            TextField("Attendees (comma-separated, optional)", text: $attendeesText)
                .textFieldStyle(.roundedBorder)
            TextField("Meet code (optional, abc-defg-hij)", text: $meetingCode)
                .textFieldStyle(.roundedBorder)
                .help("Matches speaker events captured by the Meet extension")
            if let importError {
                Label(importError, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onDismiss() }
                Button(importing ? "Importing…" : "Import") { runImport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(importing || title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 440)
        .onAppear {
            if title.isEmpty {
                title = sourceURL.deletingPathExtension().lastPathComponent
            }
        }
    }

    private func runImport() {
        importing = true
        importError = nil
        let attendees = attendeesText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { Attendee(name: $0, source: .manual) }
        let code = meetingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let environment = appEnv
        let uiState = uiState
        let source = sourceURL
        let meetingTitle = title.trimmingCharacters(in: .whitespaces)
        let started = startedAt
        Task {
            do {
                let accessing = source.startAccessingSecurityScopedResource()
                defer {
                    if accessing { source.stopAccessingSecurityScopedResource() }
                }
                let meeting = try await environment.pipeline.importMeeting(
                    sourceURL: source,
                    title: meetingTitle,
                    startedAt: started,
                    attendees: attendees,
                    meetingCode: code.isEmpty ? nil : code)
                // The new meeting appears immediately (observation) with
                // live stage progress; select it and kick processing
                // (status-dependent rule: fresh import is non-ready →
                // process()).
                uiState.selectedMeetingID = meeting.id
                onDismiss()
                _ = try? await environment.pipeline.dispatchProcessing(meetingID: meeting.id)
            } catch {
                importError = "\(error)"
                importing = false
            }
        }
    }
}

extension UTType {
    static let blaiseImportable: [UTType] = [.wav, .mpeg4Audio]
}
