import BlaiseCore
import SwiftUI

/// F1 Inc2 — a dedicated, openable window that shows the live processing queue
/// (every job + its state), so a user can SEE what's processing/queued/failed
/// and confirm a Reprocess-all. Opened from the menu (View ▸ Processing Queue,
/// ⇧⌘0). Live: refreshes whenever the worker publishes a new snapshot.
struct ProcessingQueueWindow: View {
    @Environment(AppEnvironment.self) private var appEnv
    @State private var model: ProcessingQueueModel?

    var body: some View {
        let snapshot = appEnv.processingStatus.snapshot
        VStack(spacing: 0) {
            HStack {
                Image(systemName: glyph(snapshot.state))
                    .foregroundStyle(snapshot.state == .waitingRetry ? .orange : .secondary)
                Text(stateLabel(snapshot))
                    .font(.headline)
                Spacer()
                if let model {
                    Toggle("Pause", isOn: Binding(
                        get: { model.paused },
                        set: { value in Task { await model.setPaused(value) } }))
                        .toggleStyle(.switch)
                        .help("Finish the in-flight meeting, then stop processing new ones.")
                }
            }
            .padding(12)
            Divider()

            if let model {
                if model.jobs.isEmpty {
                    ContentUnavailableView(
                        "Queue is empty", systemImage: "tray",
                        description: Text("Processing, Regenerate, and Reprocess-all jobs appear here."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(model.jobs, id: \.id) { job in
                        ProcessingJobRow(job: job, model: model)
                    }
                    .listStyle(.inset)
                }
                Divider()
                HStack {
                    Text(footerSummary(model))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh") { Task { await model.refresh() } }
                    Button("Retry All") { Task { await model.retryAllFailed() } }
                        .disabled(model.failedJobs.isEmpty)
                }
                .padding(10)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 440, minHeight: 320)
        .navigationTitle("Processing Queue")
        .task {
            guard model == nil else { return }
            let pipeline = appEnv.pipeline
            let made = ProcessingQueueModel(
                database: appEnv.database, worker: appEnv.processingQueue,
                settings: appEnv.settings,
                cancelRunning: { meetingID in _ = await pipeline.cancel(meetingID: meetingID) })
            await made.refresh()
            model = made
        }
        // Live: re-read the jobs whenever the worker publishes a state change.
        .onChange(of: appEnv.processingStatus.snapshot) {
            Task { await model?.refresh() }
        }
    }

    private func glyph(_ state: ProcessingSnapshot.State) -> String {
        switch state {
        case .idle: return "tray"
        case .processing: return "gearshape.2"
        case .pending: return "clock"
        case .waitingRetry: return "exclamationmark.triangle"
        case .paused: return "pause.circle"
        }
    }

    private func stateLabel(_ s: ProcessingSnapshot) -> String {
        switch s.state {
        case .idle: return "Idle"
        case .processing: return s.pendingCount > 0 ? "Processing · \(s.pendingCount) queued" : "Processing"
        case .pending: return "\(s.pendingCount) queued"
        case .waitingRetry: return "\(s.failedCount) failed"
        case .paused: return "Paused"
        }
    }

    private func footerSummary(_ model: ProcessingQueueModel) -> String {
        let live = model.liveJobs.count
        let failed = model.failedJobs.count
        let done = model.jobs.filter { $0.state == .done }.count
        return "\(live) active · \(failed) failed · \(done) done"
    }
}

/// One job row: meeting id, state (colored), attempts/error, and the contextual
/// action (Retry for failed, Cancel for live).
private struct ProcessingJobRow: View {
    let job: ProcessingJob
    @Bindable var model: ProcessingQueueModel

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle().fill(stateColor).frame(width: 7, height: 7)
                    Text(job.meetingID)
                        .font(.system(size: 11, design: .monospaced))
                    Text(job.state.rawValue)
                        .font(.caption2).foregroundStyle(.secondary)
                    if job.origin == .reprocessAll {
                        Text("reprocess-all").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                if let error = job.lastError, !error.isEmpty {
                    Text(error).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            if job.state == .failed {
                Button("Retry") { Task { await model.retry(job) } }
            } else if job.state == .pending || job.state == .running {
                Button("Cancel", role: .destructive) { Task { await model.cancel(job) } }
            }
        }
        .padding(.vertical, 2)
    }

    private var stateColor: Color {
        switch job.state {
        case .running: return .blue
        case .pending: return .secondary
        case .done: return .green
        case .failed: return .orange
        case .cancelled: return .gray
        }
    }
}
