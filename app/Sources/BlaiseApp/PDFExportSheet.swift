import AppKit
import BlaiseCore
import SwiftUI
import UniformTypeIdentifiers

// The export sheet: the choices, the two exits, and the AppKit surfaces both
// exits need. The save panel and the failure alert are presented on the
// SHEET's own window — a window that already shows a sheet queues the next
// one, so anything hung on the main window would wait for this sheet to close.

/// The sheet's own view in the AppKit tree: its window hosts the save panel
/// and the alert, and it is the rectangle the share picker points at.
@MainActor
final class PDFExportAnchor {
    weak var view: NSView?
    var window: NSWindow? { view?.window }
}

private struct PDFExportAnchorView: NSViewRepresentable {
    let anchor: PDFExportAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Retained for the life of the sheet: the picker holds its delegate weakly.
@MainActor
final class PDFSharePickerDelegate: NSObject, @MainActor NSSharingServicePickerDelegate {
    var reported: ((NSSharingService?) -> Void)?

    func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?
    ) {
        reported?(service)
    }
}

struct PDFExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: PDFExportSheetModel
    @State private var anchor = PDFExportAnchor()
    @State private var shareDelegate = PDFSharePickerDelegate()

    init(input: PDFExportInput, exporter: any PDFExporting, settings: SettingsStore) {
        _model = State(
            initialValue: PDFExportSheetModel(
                input: input, exporter: exporter, settings: settings))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export PDF")
                .font(.headline)

            Picker("Style", selection: $model.style) {
                ForEach(PDFStyle.allCases, id: \.self) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Toggle("Include my action items", isOn: $model.includeSelfActions)
            if model.input.hasMarginNotes {
                Toggle("Include margin notes", isOn: $model.includeMarginNotes)
            }

            TextField("File name", text: $model.filename)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 10) {
                if model.running {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Exporting")
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.running)
                Button("Share") { share() }
                    .disabled(model.running)
                    .background { PDFExportAnchorView(anchor: anchor) }
                Button("Save…") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.running)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onChange(of: model.finished) { _, finished in
            if finished { dismiss() }
        }
        .onChange(of: model.failure) { _, message in
            guard let message else { return }
            model.failure = nil
            presentFailure(message)
        }
    }

    private func save() {
        guard let window = anchor.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = model.filenameSafe
        panel.directoryURL =
            model.input.lastSaveDirectory
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.beginSheetModal(for: window) { response in
            // The completion can arrive while the panel is still on screen, and
            // the failure alert would then queue behind it.
            panel.orderOut(nil)
            guard response == .OK, let destination = panel.url else { return }
            Task { await model.save(to: destination) }
        }
    }

    private func share() {
        guard let view = anchor.view else { return }
        Task {
            guard let url = await model.share() else { return }
            shareDelegate.reported = { service in
                model.shareReported(chose: service != nil)
            }
            let picker = NSSharingServicePicker(items: [url])
            picker.delegate = shareDelegate
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }
    }

    private func presentFailure(_ message: String) {
        guard let window = anchor.window else { return }
        let alert = NSAlert()
        alert.messageText = "Couldn't export the PDF"
        alert.informativeText = message
        alert.beginSheetModal(for: window) { _ in }
    }
}
