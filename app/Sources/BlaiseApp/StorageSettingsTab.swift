import AppKit
import BlaiseCore
import SwiftUI

// MARK: - Storage tab (G16)

/// Audio recordings on disk: how much space they use, the owner-set size cap
/// (oldest audio deleted automatically once over it), and a manual Delete All.
/// Transcripts and notes are never touched.
struct StorageSettingsTab: View {
    @Environment(AppEnvironment.self) private var appEnv
    @State private var cap = AudioRetentionSettings.defaultCap
    @State private var persistedCap = AudioRetentionSettings.defaultCap
    @State private var sliderIndex: Double = Double(Self.index(of: AudioRetentionSettings.defaultCap))
    @State private var usage: AudioUsage?
    @State private var loaded = false
    @State private var pendingPlan: AudioCapPlan?
    @State private var showCapConfirmation = false
    @State private var showDeleteAllConfirmation = false
    @State private var deleteAllResult: (deleted: Int, skipped: Int)?
    @State private var working = false

    private static let caps = AudioRetentionCap.allCases

    private static func index(of cap: AudioRetentionCap) -> Int {
        caps.firstIndex(of: cap) ?? (caps.count - 1)
    }

    private static func cap(at index: Double) -> AudioRetentionCap {
        let i = min(max(Int(index.rounded()), 0), caps.count - 1)
        return caps[i]
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func meetings(_ n: Int) -> String {
        n == 1 ? "1 meeting" : "\(n) meetings"
    }

    var body: some View {
        Form {
            Section("Audio recordings") {
                summary

                capSlider
                deleteControls
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            capConfirmationTitle,
            isPresented: $showCapConfirmation,
            titleVisibility: .visible,
            presenting: pendingPlan
        ) { _ in
            Button("Delete Audio", role: .destructive) {
                let newCap = cap
                pendingPlan = nil  // so the dismissal handler doesn't revert
                Task { await applyCap(newCap) }
            }
            Button("Cancel", role: .cancel) {
                revertSlider()
            }
        } message: { plan in
            Text("This frees \(Self.size(plan.bytesFreed)). Transcripts and notes are kept.")
        }
        .onChange(of: showCapConfirmation) { _, isShown in
            // Dismissed without choosing (Escape / click outside) ⇒ Cancel.
            if !isShown, pendingPlan != nil { revertSlider() }
        }
        .confirmationDialog(
            "Delete all audio recordings?",
            isPresented: $showDeleteAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Audio", role: .destructive) {
                Task { await deleteAll() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This deletes audio from \(Self.meetings(deletableCount)) and frees \(Self.size(usage?.manualEligibleBytes ?? 0)). Transcripts and notes are kept. Meetings that are recording or processing are skipped. Copies already delivered to your Evidence Store are not affected."
            )
        }
        .task {
            let stored = await AudioRetentionSettings.cap(from: appEnv.settings)
            cap = stored
            persistedCap = stored
            sliderIndex = Double(Self.index(of: stored))
            usage = await appEnv.audioUsage()
            loaded = true
        }
    }

    // MARK: Controls

    private var capConfirmationTitle: String {
        let n = pendingPlan?.meetingIDs.count ?? 0
        return "Delete audio from \(n) older \(n == 1 ? "meeting" : "meetings")?"
    }

    private var capSlider: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(cap == .unlimited ? "Keep all audio" : "Keep up to \(cap.label)")
            Slider(
                value: $sliderIndex,
                in: 0...Double(Self.caps.count - 1),
                step: 1,
                label: { Text("Keep up to") },
                onEditingChanged: { editing in
                    guard !editing, loaded else { return }
                    Task { await commitSlider() }
                }
            )
            .labelsHidden()
            .disabled(!loaded || working)
            .onChange(of: sliderIndex) { _, newValue in
                cap = Self.cap(at: newValue)
            }
            stepLabels
            Text(
                "Unlimited by default. When audio goes over this size, the oldest meetings' audio is deleted automatically. Transcripts and notes are always kept, and the most recent meeting is never touched."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// One label per slider step, centred under its tick. The ends are pinned
    /// to the slider's edges so "250 MB" and "Unlimited" never clip.
    private var stepLabels: some View {
        // The thumb's centre travels between these insets, not the full width.
        let knobInset: CGFloat = 10
        return GeometryReader { geo in
            let width = geo.size.width
            let track = max(width - 2 * knobInset, 0)
            let last = Self.caps.count - 1
            ZStack(alignment: .leading) {
            ForEach(Array(Self.caps.enumerated()), id: \.element) { i, step in
                let x = knobInset + track * CGFloat(i) / CGFloat(last)
                Text(step.label)
                    .font(.caption2)
                    .foregroundStyle(step == cap ? .primary : .secondary)
                    .fixedSize()
                    .alignmentGuide(.leading) { d in
                        switch i {
                        case 0: return 0
                        case last: return d.width - width
                        default: return d.width / 2 - x
                        }
                    }
                    .onTapGesture {
                        guard loaded, !working else { return }
                        sliderIndex = Double(i)
                        Task { await commitSlider() }
                    }
            }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 14)
        .accessibilityHidden(true)
    }

    private var deleteControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Delete All Audio Recordings…", role: .destructive) {
                    deleteAllResult = nil
                    showDeleteAllConfirmation = true
                }
                .disabled((usage?.manualEligibleBytes ?? 0) == 0 || working)
                Spacer()
                Button("Show in Finder") {
                    let dir = appEnv.database.paths.meetingsDirectory
                    NSWorkspace.shared.activateFileViewerSelecting([dir])
                }
            }
            if let result = deleteAllResult {
                Text(
                    "Deleted audio from \(Self.meetings(result.deleted)) (\(result.skipped) skipped)."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Summary

    @ViewBuilder
    private var summary: some View {
        if let usage, usage.meetingsWithAudio > 0 {
            VStack(alignment: .leading, spacing: 6) {
                Text(
                    "Audio is using \(Self.size(usage.totalBytes)) across \(Self.meetings(usage.meetingsWithAudio))."
                )
                if let capBytes = persistedCap.bytes {
                    ProgressView(
                        value: Double(min(usage.totalBytes, capBytes)),
                        total: Double(capBytes)
                    )
                    .tint(usage.totalBytes > capBytes ? .orange : .accentColor)
                    Text("\(Self.size(usage.totalBytes)) of \(persistedCap.label)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let oldest = oldestRecording(usage) {
                    Text("Oldest recording: \(oldest.formatted(date: .abbreviated, time: .omitted)).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                let protectedBytes = usage.totalBytes - usage.capEligibleBytes
                if persistedCap != .unlimited, protectedBytes > 0 {
                    Text(
                        "\(Self.size(protectedBytes)) can't be deleted automatically (the most recent meeting, or meetings that are recording, processing, failed, or waiting to deliver audio)."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        } else if loaded {
            Text("No audio recordings are stored.")
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private func oldestRecording(_ usage: AudioUsage) -> Date? {
        usage.entries.filter { $0.bytes > 0 }.map(\.startedAt).min()
    }

    private var deletableCount: Int {
        usage?.entries.filter { $0.manualEligible && $0.audioDeletedAt == nil && $0.bytes > 0 }.count ?? 0
    }

    // MARK: Actions

    private func commitSlider() async {
        let newCap = Self.cap(at: sliderIndex)
        cap = newCap
        guard newCap != persistedCap else { return }
        guard let plan = await appEnv.audioCapPreview(for: newCap) else {
            revertSlider()
            return
        }
        if plan.isEmpty {
            await applyCap(newCap)
        } else {
            pendingPlan = plan
            showCapConfirmation = true
        }
    }

    private func applyCap(_ newCap: AudioRetentionCap) async {
        pendingPlan = nil
        working = true
        await appEnv.setAudioCap(newCap)
        persistedCap = newCap
        usage = await appEnv.audioUsage()
        working = false
        // The sweep runs in the background (it queues behind any in-flight
        // processing run); re-poll briefly so the summary catches up.
        for _ in 0..<10 {
            try? await Task.sleep(for: .seconds(1))
            guard persistedCap == newCap else { return }
            let latest = await appEnv.audioUsage()
            usage = latest
            if let limit = newCap.bytes, let total = latest?.totalBytes, total <= limit { return }
        }
    }

    private func revertSlider() {
        pendingPlan = nil
        cap = persistedCap
        sliderIndex = Double(Self.index(of: persistedCap))
    }

    private func deleteAll() async {
        working = true
        let result = await appEnv.deleteAllAudio()
        deleteAllResult = (result.deleted, result.skipped)
        usage = await appEnv.audioUsage()
        working = false
    }
}
