import Foundation
import GRDB
import os

/// B-2 cloud-spend accounting (C6 owns enforcement; C10 displays).
///
/// Persists per-month accumulated USD in the `cloud_spend` table (migration
/// v3): `{month_key "YYYY-MM" in the system time zone, accumulated_usd}`.
/// Month rollover "resets" by construction — a new month is a new row.
///
/// `add(_:)` performs the read-modify-write inside ONE `pool.write`
/// transaction, so concurrent calls can never lose an increment. Ledger
/// updates are written BEFORE the engine returns its result; a crash can at
/// worst under-count one call (accepted, documented in the C6 spec).
public actor CloudSpendLedger {
    public static let ceilingSettingsKey = "cloud.ceilingUSD"
    public static let defaultCeilingUSD = 20.0
    public static let warningFraction = 0.8

    private let database: BlaiseDatabase
    private let settings: SettingsStore
    private let logger = Logger(subsystem: BlaiseBundle.identifier, category: "cloud.spend")
    /// Test seam: the "now" used to derive the month key.
    private let now: @Sendable () -> Date
    /// Test seam (M-2): fired INSIDE the receipt write transaction, between the
    /// accumulator bump and the receipt INSERT. A throwing hook proves the two
    /// are one transaction: the bump rolls back with the failed insert, so the
    /// isolation replay bumps EXACTLY ONCE. A non-atomic split (bump committed
    /// in its own transaction first) would already have the bump persisted
    /// when the hook throws, and the replay would double it — which the
    /// atomicity test below asserts against.
    var midReceiptTransactionHook: (@Sendable () throws -> Void)?

    public init(database: BlaiseDatabase) {
        self.init(database: database, now: { Date() })
    }

    init(database: BlaiseDatabase, now: @escaping @Sendable () -> Date) {
        self.database = database
        self.settings = SettingsStore(database: database)
        self.now = now
    }

    /// Test-only (M-2): installs the mid-receipt-transaction hook through the
    /// actor's isolation.
    func setMidReceiptTransactionHook(_ hook: @escaping @Sendable () throws -> Void) {
        midReceiptTransactionHook = hook
    }

    /// "YYYY-MM" in `timeZone` (default: the system time zone) — the billing
    /// month boundary.
    static func monthKey(for date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
    }

    public func currentMonthKey() -> String {
        Self.monthKey(for: now())
    }

    /// Adds `costUSD` to the current month atomically and returns the new
    /// accumulated total. Logs the 80 % warning when the addition crosses it.
    @discardableResult
    public func add(_ costUSD: Double) async throws -> Double {
        try await add(costUSD, receipt: nil)
    }

    /// G7: bumps the month accumulator AND, when supplied, persists the
    /// matching receipt in the SAME transaction (the accumulator and its
    /// line item are written together, so they reconcile). The accumulator is
    /// authoritative: a receipt-write failure must fail NEITHER the call nor
    /// the bump — it is logged loudly and the bump is replayed alone. The
    /// receipt's `costUSD`/`monthKey` are taken from the ledger here so they
    /// can never drift from what the accumulator actually recorded.
    @discardableResult
    public func add(_ costUSD: Double, receipt: ReceiptDraft?) async throws -> Double {
        let key = currentMonthKey()
        let total: Double
        if let receipt {
            do {
                let hook = midReceiptTransactionHook
                total = try await database.pool.write { db -> Double in
                    let bumped = try Self.bumpAccumulator(db, key: key, costUSD: costUSD)
                    try hook?()
                    // M-3: keep the money, salvage the line item even when the
                    // meeting row is absent. The receipt's meeting_id is under a
                    // FK; a draft naming a meeting that has no row (the spec's
                    // validation/smoke harness flows call the engine outside a
                    // pipeline run, where no meeting exists) would throw an FK
                    // violation and drop the WHOLE receipt. Detect the missing
                    // row and write the receipt with meeting_id NULL instead —
                    // attribution is lost (it shows as a purpose badge), the
                    // line item and its money are preserved.
                    var draft = receipt
                    if let id = draft.meetingID,
                        try Meeting.filter(key: id).fetchCount(db) == 0
                    {
                        self.logger.error(
                            "cloud-spend receipt names a meeting with no row (\(String(describing: id))); writing it with meeting_id NULL — money kept, attribution lost"
                        )
                        draft.meetingID = nil
                    }
                    try draft.materialize(monthKey: key, costUSD: costUSD, at: self.now())
                        .insert(db)
                    return bumped
                }
            } catch {
                // Receipt-write failure isolation (spec §1): the accumulator
                // is the ceiling-enforcement source of truth and must never be
                // lost to a bookkeeping fault. Replay the bump ALONE.
                // L-4: the combined transaction can fault on EITHER the receipt
                // insert OR the accumulator bump. The replay below discriminates
                // them: if the bump succeeds in isolation, the original fault was
                // the receipt write (bill correct, line item lost — the common
                // case). If the replay ALSO fails, the fault was the accumulator
                // bump itself (a real money-path error) and it propagates.
                do {
                    total = try await database.pool.write { db in
                        try Self.bumpAccumulator(db, key: key, costUSD: costUSD)
                    }
                    logger.error(
                        "cloud-spend RECEIPT write failed (accumulator bump replayed alone; bill remains correct, the line item is missing): \(String(describing: error))"
                    )
                } catch let bumpError {
                    logger.error(
                        "cloud-spend ACCUMULATOR bump failed (the money-path write itself errored, NOT a receipt fault; propagating): \(String(describing: bumpError))"
                    )
                    throw bumpError
                }
            }
        } else {
            total = try await database.pool.write { db in
                try Self.bumpAccumulator(db, key: key, costUSD: costUSD)
            }
        }
        let ceiling = await ceilingUSD()
        if total >= Self.warningFraction * ceiling {
            logger.warning(
                "cloud spend \(String(format: "%.2f", total)) USD of \(String(format: "%.2f", ceiling)) ceiling this month (\(key))"
            )
        }
        return total
    }

    /// Read-modify-write of the month accumulator inside the caller's
    /// transaction. Returns the new total.
    private static func bumpAccumulator(_ db: Database, key: String, costUSD: Double) throws -> Double {
        let existing =
            try Double.fetchOne(
                db, sql: "SELECT accumulated_usd FROM cloud_spend WHERE month_key = ?",
                arguments: [key]) ?? 0
        let updated = existing + costUSD
        try db.execute(
            sql: """
                INSERT INTO cloud_spend (month_key, accumulated_usd) VALUES (?, ?)
                ON CONFLICT(month_key) DO UPDATE SET accumulated_usd = excluded.accumulated_usd
                """,
            arguments: [key, updated]
        )
        return updated
    }

    /// What the engine knows at the accounting write point; the ledger fills
    /// the authoritative `monthKey`/`costUSD`/`timestamp` so a receipt can
    /// never disagree with the accumulator bump it rides with.
    public struct ReceiptDraft: Sendable, Equatable {
        public var engineID: String
        public var model: String
        public var purpose: CloudSpendPurpose
        public var meetingID: MeetingID?
        public var inputTokens: Int
        public var outputTokens: Int
        public var note: String?

        public init(
            engineID: String,
            model: String,
            purpose: CloudSpendPurpose,
            meetingID: MeetingID?,
            inputTokens: Int,
            outputTokens: Int,
            note: String? = nil
        ) {
            self.engineID = engineID
            self.model = model
            self.purpose = purpose
            self.meetingID = meetingID
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.note = note
        }

        func materialize(monthKey: String, costUSD: Double, at timestamp: Date) -> CloudSpendReceipt {
            CloudSpendReceipt(
                timestamp: timestamp,
                monthKey: monthKey,
                engineID: engineID,
                model: model,
                purpose: purpose,
                meetingID: meetingID,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                costUSD: costUSD,
                note: note)
        }
    }

    /// The Settings → Cloud Spend month view: receipts (newest first) +
    /// accumulator, for the current month. The accumulator is read alongside
    /// so the reconciliation line compares like for like.
    public func monthReceipts() async throws -> CloudSpendMonthReceipts {
        try await monthReceipts(forMonthKey: currentMonthKey())
    }

    public func monthReceipts(forMonthKey key: String) async throws -> CloudSpendMonthReceipts {
        try await database.pool.read { db in
            let receipts = try CloudSpendReceipt
                .filter(sql: "month_key = ?", arguments: [key])
                .order(sql: "timestamp DESC, id DESC")
                .fetchAll(db)
            let accumulator =
                try Double.fetchOne(
                    db, sql: "SELECT accumulated_usd FROM cloud_spend WHERE month_key = ?",
                    arguments: [key]) ?? 0
            // Display-only title resolution (a deleted meeting → purpose badge).
            var titles: [MeetingID: String] = [:]
            let ids = Set(receipts.compactMap(\.meetingID))
            for id in ids {
                if let title = try String.fetchOne(
                    db, sql: "SELECT title FROM meeting WHERE id = ?", arguments: [id])
                {
                    titles[id] = title
                }
            }
            return CloudSpendMonthReceipts(
                monthKey: key, receipts: receipts, accumulatorUSD: accumulator,
                titlesByMeetingID: titles)
        }
    }

    /// Accumulated spend for the current month (0 when no row exists).
    public func accumulatedThisMonth() async throws -> Double {
        let key = currentMonthKey()
        return try await database.pool.read { db in
            try Double.fetchOne(
                db, sql: "SELECT accumulated_usd FROM cloud_spend WHERE month_key = ?",
                arguments: [key]) ?? 0
        }
    }

    /// The user-configurable ceiling (`cloud.ceilingUSD`, default 20.0).
    public func ceilingUSD() async -> Double {
        (try? await settings.get(Self.ceilingSettingsKey, as: Double.self))
            ?? Self.defaultCeilingUSD
    }

    /// True iff this month's spend has reached 100 % of the ceiling.
    public func ceilingReached() async throws -> Bool {
        try await accumulatedThisMonth() >= ceilingUSD()
    }

    /// True iff this month's spend has reached the 80 % warning threshold.
    public func warningReached() async throws -> Bool {
        try await accumulatedThisMonth() >= Self.warningFraction * ceilingUSD()
    }
}
