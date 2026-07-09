import BlaiseCore
import SwiftUI

/// F1 Inc2 (Stage 2c): the "Reprocess All Meetings…" confirmation. Shows the
/// eligible count, the estimated cost, the month's spend vs. ceiling, and any
/// budget cap, then enqueues the capped set (origin `.reprocessAll`). The worker
/// drains them one at a time; the ledger's per-call gate is the true ceiling.
struct ReprocessAllSheet: View {
    @Environment(AppEnvironment.self) private var appEnv
    let onClose: () -> Void

    @State private var plan: ReprocessAllPlan?
    @State private var enqueuing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Reprocess All Meetings")
                .font(.title3.weight(.semibold))

            if let plan {
                if plan.eligibleCount == 0 {
                    Text("No completed meetings to reprocess.")
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        row("Meetings", "\(plan.cappedCount) of \(plan.eligibleCount)")
                        row("Estimated cost", String(format: "≈ US$ %.2f", plan.estimatedUSD))
                        row(
                            "This month (\(plan.monthKey))",
                            String(format: "US$ %.2f of US$ %.2f", plan.spentThisMonthUSD, plan.ceilingUSD))
                    }
                    if plan.wasCapped {
                        Label(
                            "Capped to your remaining monthly budget — "
                                + "\(plan.eligibleCount - plan.cappedCount) left out.",
                            systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    Text("Regenerates notes for each meeting from its retained audio, queued one at a time.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                ProgressView().controlSize(.small)
            }

            HStack {
                Spacer()
                Button("Cancel") { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("Reprocess") { Task { await enqueue() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan == nil || (plan?.cappedCount ?? 0) == 0 || enqueuing)
            }
        }
        .padding(20)
        .frame(width: 380)
        .task {
            plan = await ReprocessAllPlanner.plan(
                database: appEnv.database, ledger: appEnv.ledger,
                perMeetingUSD: ReprocessAllPlanner.defaultPerMeetingUSD)
        }
    }

    private func enqueue() async {
        guard let plan else { return }
        enqueuing = true
        for meetingID in plan.meetingsToEnqueue {
            await appEnv.processingQueue.enqueue(meetingID, origin: .reprocessAll)
        }
        onClose()
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
    }
}
