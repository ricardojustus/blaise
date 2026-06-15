import Foundation
import GRDB

/// G7: why a cloud call happened. CHECK-constrained at the table boundary
/// (migration v9) and threaded from the pipeline down to the engine's
/// post-hoc accounting write. `generation` is the default when a caller
/// supplies none (a bare engine test, a path the pipeline doesn't tag).
public enum CloudSpendPurpose: String, Codable, Sendable, CaseIterable, Equatable {
    /// First-time notes for a meeting (`process()` / `processCaptured()`).
    case generation
    /// Re-running notes for an already-noted meeting (`regenerate()`, and the
    /// D17 notes-pending self-heal retry of a meeting that already had notes).
    case regeneration
    /// Harness / acceptance cloud calls — the engine driven OUTSIDE a pipeline
    /// run (e.g. the real-key E2E `claudeEngineEndToEndWithRealKey`, which
    /// threads this purpose). Such calls have no meeting row, so their receipt
    /// is kept with `meeting_id` NULL (CloudSpendLedger M-3 FK salvage).
    case validation
    /// Reserved for the G3/G4 automated smoke gates: NOT YET written by any
    /// code path (those gates land later). The subtotal strip therefore shows
    /// "Smoke" only once a receipt with this purpose exists. Kept in the enum
    /// (and the table CHECK) so the gates can thread it without a migration.
    case smoke
    /// G14: the SECOND synthesis call that produces the `memory_digest`. Unlike
    /// `smoke`, this case was NOT pre-provisioned in the v9 CHECK, so a
    /// `digest`-purpose INSERT requires the v14 CHECK-rebuild migration (the
    /// frozen v9 column CHECK lists only generation/regeneration/validation/
    /// smoke). The cloud digest call (and its bounded-retry re-issue, and the
    /// digest-pending re-fire) bill under this purpose; the MLX digest spends
    /// nothing. A name-edit rewrite of the stored digest spends nothing (no LLM
    /// call), so it leaves no receipt.
    case digest

    /// The plural display noun for the per-purpose subtotal strip.
    public var displayPlural: String {
        switch self {
        case .generation: return "Meetings"
        case .regeneration: return "Regenerations"
        case .validation: return "Validation"
        case .smoke: return "Smoke"
        case .digest: return "Memory digests"
        }
    }
}

/// One persisted cloud-spend receipt: the line-by-line explanation of the
/// `cloud_spend` month accumulator. Receipts are local bookkeeping — never a
/// payload-builder input — and the ceiling gate never depends on a JOIN over
/// them (the accumulator is authoritative; receipts merely reconcile).
public struct CloudSpendReceipt: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "cloud_spend_receipt"

    public var id: String
    public var timestamp: Date
    public var monthKey: String
    public var engineID: String
    public var model: String
    public var purpose: CloudSpendPurpose
    public var meetingID: MeetingID?
    public var inputTokens: Int
    public var outputTokens: Int
    public var costUSD: Double
    public var note: String?

    public init(
        id: String = ULID.generate(),
        timestamp: Date,
        monthKey: String,
        engineID: String,
        model: String,
        purpose: CloudSpendPurpose,
        meetingID: MeetingID?,
        inputTokens: Int,
        outputTokens: Int,
        costUSD: Double,
        note: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.monthKey = monthKey
        self.engineID = engineID
        self.model = model
        self.purpose = purpose
        self.meetingID = meetingID
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.costUSD = costUSD
        self.note = note
    }

    enum CodingKeys: String, CodingKey {
        case id, timestamp, model, purpose, note
        case monthKey = "month_key"
        case engineID = "engine_id"
        case meetingID = "meeting_id"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case costUSD = "cost_usd"
    }
}

/// The Settings → Cloud Spend month view: the rows, the per-purpose
/// subtotals, and the reconciliation against the authoritative accumulator.
public struct CloudSpendMonthReceipts: Sendable, Equatable {
    public var monthKey: String
    /// Newest first.
    public var receipts: [CloudSpendReceipt]
    /// The authoritative `cloud_spend` accumulator for the month (the gate).
    public var accumulatorUSD: Double
    /// Display-only meeting titles for the receipts whose meeting still
    /// exists (LEFT JOIN; a deleted meeting's receipt falls back to the
    /// purpose badge). The ceiling gate never depends on this map.
    public var titlesByMeetingID: [MeetingID: String]

    public init(
        monthKey: String,
        receipts: [CloudSpendReceipt],
        accumulatorUSD: Double,
        titlesByMeetingID: [MeetingID: String] = [:]
    ) {
        self.monthKey = monthKey
        self.receipts = receipts
        self.accumulatorUSD = accumulatorUSD
        self.titlesByMeetingID = titlesByMeetingID
    }

    /// The row label per the spec: the meeting title when the meeting still
    /// exists, otherwise the receipt's purpose as a badge.
    public func label(for receipt: CloudSpendReceipt) -> String {
        if let id = receipt.meetingID, let title = titlesByMeetingID[id] {
            return title
        }
        return receipt.purpose.displayPlural
    }

    /// Sum of every receipt's cost this month.
    public var receiptsSumUSD: Double {
        receipts.reduce(0) { $0 + $1.costUSD }
    }

    /// Per-purpose subtotals in the canonical display order, ALWAYS including
    /// generation/regeneration/validation (the strip the spec names), and
    /// smoke only when present.
    public var subtotalsByPurpose: [(purpose: CloudSpendPurpose, totalUSD: Double)] {
        var order: [CloudSpendPurpose] = [.generation, .regeneration, .validation]
        if receipts.contains(where: { $0.purpose == .smoke }) { order.append(.smoke) }
        if receipts.contains(where: { $0.purpose == .digest }) { order.append(.digest) }
        return order.map { purpose in
            (purpose, receipts.filter { $0.purpose == purpose }.reduce(0) { $0 + $1.costUSD })
        }
    }

    /// accumulator − receipts sum. A POSITIVE delta is almost always the
    /// pre-receipts history (accumulator rows minted before G7 shipped have
    /// no receipts) — a permanent, honest initial offset.
    public var reconciliationDeltaUSD: Double {
        accumulatorUSD - receiptsSumUSD
    }

    /// True when the receipts sum and the accumulator agree to the cent.
    public var reconciles: Bool {
        abs(reconciliationDeltaUSD) < 0.005
    }
}
