import Foundation
import Testing
@testable import BlaiseCore

// C6: B-2 ceiling machinery. Crash semantics are by design: the ledger is
// written BEFORE the engine returns its result, so a crash between the API
// response and the ledger write can at worst UNDER-count one call —
// accepted and documented in the C6 spec.

private final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) { self.date = date }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    func set(_ date: Date) {
        lock.lock()
        self.date = date
        lock.unlock()
    }
}

@Suite struct CloudSpendLedgerTests {
    @Test func monthKeyRespectsTimeZone() {
        // A fixed UTC-3 zone (no locality): 2026-01-01T01:00:00Z is still
        // 31/12/2025 22:00 there, so the billing month is December.
        let utcMinus3 = TimeZone(secondsFromGMT: -3 * 3600)!
        let utcNewYear = Date(timeIntervalSince1970: 1_767_229_200)
        #expect(CloudSpendLedger.monthKey(for: utcNewYear, timeZone: utcMinus3) == "2025-12")
        // +11h is 09:00 the next day in UTC-3 → January.
        #expect(
            CloudSpendLedger.monthKey(
                for: utcNewYear.addingTimeInterval(11 * 3600), timeZone: utcMinus3) == "2026-01")
    }

    @Test func accumulatesAcrossCalls() async throws {
        let ledger = CloudSpendLedger(database: try makeDatabase())
        try await ledger.add(0.05)
        try await ledger.add(0.07)
        try await ledger.add(0.08)
        let total = try await ledger.accumulatedThisMonth()
        #expect(abs(total - 0.20) < 1e-9)
    }

    @Test func concurrentAddsNeverLoseAnIncrement() async throws {
        // `add` does its read-modify-write inside ONE pool.write transaction.
        let ledger = CloudSpendLedger(database: try makeDatabase())
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<40 {
                group.addTask { try await ledger.add(0.01) }
            }
            try await group.waitForAll()
        }
        let total = try await ledger.accumulatedThisMonth()
        #expect(abs(total - 0.40) < 1e-9)
    }

    @Test func thresholdsAgainstDefaultCeiling() async throws {
        let ledger = CloudSpendLedger(database: try makeDatabase())
        try await ledger.add(15.99)  // < 80 % of 20
        #expect(try await !ledger.warningReached())
        #expect(try await !ledger.ceilingReached())
        try await ledger.add(0.02)  // ≥ 16.00 = 80 %
        #expect(try await ledger.warningReached())
        #expect(try await !ledger.ceilingReached())
        try await ledger.add(4.00)  // ≥ 20.00 = 100 %
        #expect(try await ledger.ceilingReached())
    }

    @Test func ceilingIsSettingsVisible() async throws {
        let database = try makeDatabase()
        let ledger = CloudSpendLedger(database: database)
        #expect(await ledger.ceilingUSD() == 20.0)
        try await SettingsStore(database: database).set(CloudSpendLedger.ceilingSettingsKey, to: 5.0)
        #expect(await ledger.ceilingUSD() == 5.0)
        try await ledger.add(5.0)
        #expect(try await ledger.ceilingReached())
    }

    @Test func monthRolloverResets() async throws {
        let clock = ClockBox(Date(timeIntervalSince1970: 1_767_240_000))  // Jan 2026 (SP)
        let ledger = CloudSpendLedger(database: try makeDatabase(), now: clock.now)
        try await ledger.add(19.99)
        #expect(try await ledger.warningReached())

        clock.set(Date(timeIntervalSince1970: 1_767_240_000 + 31 * 86_400))  // Feb 2026
        let fresh = try await ledger.accumulatedThisMonth()
        #expect(fresh == 0)
        #expect(try await !ledger.ceilingReached())
        try await ledger.add(0.10)
        let february = try await ledger.accumulatedThisMonth()
        #expect(abs(february - 0.10) < 1e-9)
    }
}

// G7: receipts ride the accumulator bump in one transaction; the Settings
// month view reads them back with per-purpose subtotals and a reconciliation
// against the authoritative accumulator.
@Suite struct CloudSpendReceiptTests {
    @Test func addWritesReceiptAlongsideAccumulator() async throws {
        let ledger = CloudSpendLedger(database: try makeDatabase())
        try await ledger.add(
            0.05,
            receipt: CloudSpendLedger.ReceiptDraft(
                engineID: "claude-sonnet", model: "claude-sonnet-4-6",
                purpose: .generation, meetingID: nil,
                inputTokens: 10_000, outputTokens: 1_000))
        let month = try await ledger.monthReceipts()
        #expect(month.receipts.count == 1)
        let r = try #require(month.receipts.first)
        // The ledger fills monthKey + cost authoritatively.
        #expect(r.monthKey == month.monthKey)
        #expect(abs(r.costUSD - 0.05) < 1e-9)
        #expect(r.purpose == .generation)
        #expect(month.reconciles)
    }

    @Test func receiptWriteFailureNeverLosesTheAccumulatorBump() async throws {
        let database = try makeDatabase()
        let ledger = CloudSpendLedger(database: database)
        // Break the receipt table so its INSERT throws; the accumulator
        // upsert must still land (the accumulator is authoritative).
        try await database.pool.write { db in
            try db.execute(sql: "DROP TABLE cloud_spend_receipt")
        }
        let total = try await ledger.add(
            0.07,
            receipt: CloudSpendLedger.ReceiptDraft(
                engineID: "claude-sonnet", model: "claude-sonnet-4-6",
                purpose: .generation, meetingID: nil,
                inputTokens: 1, outputTokens: 1))
        #expect(abs(total - 0.07) < 1e-9)
        #expect(abs((try await ledger.accumulatedThisMonth()) - 0.07) < 1e-9)
    }

    /// M-2 (AC2 "atomically"): the bump and the receipt INSERT ride ONE
    /// transaction. A fault injected BETWEEN them (the midReceiptTransactionHook
    /// seam) rolls the bump back with the failed insert; the isolation path then
    /// replays the bump ALONE, so the accumulator lands at the cost EXACTLY ONCE
    /// and no receipt persists. A non-atomic split (bump in its own committed
    /// transaction, receipt after) would leave the bump already persisted when
    /// the hook throws and the replay would DOUBLE it — this test fails (0.14 ≠
    /// 0.07) under that mutant.
    @Test func bumpAndReceiptAreOneTransaction() async throws {
        struct InjectedFault: Error {}
        let database = try makeDatabase()
        let ledger = CloudSpendLedger(database: database)
        await ledger.setMidReceiptTransactionHook { throw InjectedFault() }

        let total = try await ledger.add(
            0.07,
            receipt: CloudSpendLedger.ReceiptDraft(
                engineID: "claude-sonnet", model: "claude-sonnet-4-6",
                purpose: .generation, meetingID: nil,
                inputTokens: 1, outputTokens: 1))

        // Exactly one bump survived (rollback-then-replay), never two.
        #expect(abs(total - 0.07) < 1e-9, "atomic: the bump rolled back with the receipt, replayed once")
        #expect(abs((try await ledger.accumulatedThisMonth()) - 0.07) < 1e-9)
        // The receipt never persisted (it rolled back with the bump).
        let month = try await ledger.monthReceipts()
        #expect(month.receipts.isEmpty, "the receipt INSERT was rolled back, not committed")
    }

    /// AC4: the month view rendered from a fixture DB — newest-first ordering,
    /// per-purpose subtotals, meeting-title labels (with a purpose-badge
    /// fallback), and the pre-receipts reconciliation delta.
    @Test func monthViewSubtotalsTitlesAndReconciliation() async throws {
        let database = try makeDatabase()
        let ledger = CloudSpendLedger(database: database)
        let key = await ledger.currentMonthKey()

        // A meeting the receipts can name.
        let meetingID = ULID.generate()
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO meeting (id, title, started_at, source, status, attendees, created_at, updated_at)
                    VALUES (?, 'Weekly Vexatron sync', ?, 'meet', 'ready', '[]', ?, ?)
                    """,
                arguments: [meetingID, msDate(), msDate(), msDate()])
        }

        // Pre-receipts accumulator history: spend recorded before G7 shipped
        // has NO receipts → a permanent positive reconciliation delta.
        try await ledger.add(0.50)  // accumulator only

        // Then receipts (which also bump the accumulator).
        try await ledger.add(
            0.33,
            receipt: CloudSpendLedger.ReceiptDraft(
                engineID: "claude-sonnet", model: "claude-sonnet-4-6",
                purpose: .generation, meetingID: meetingID,
                inputTokens: 100_000, outputTokens: 5_000))
        try await ledger.add(
            0.25,
            receipt: CloudSpendLedger.ReceiptDraft(
                engineID: "claude-sonnet", model: "claude-sonnet-4-6",
                purpose: .regeneration, meetingID: nil,  // meeting deleted → badge
                inputTokens: 80_000, outputTokens: 4_000))

        let month = try await ledger.monthReceipts(forMonthKey: key)

        // Newest first.
        #expect(month.receipts.count == 2)
        #expect(month.receipts.first?.purpose == .regeneration)
        #expect(month.receipts.last?.purpose == .generation)

        // Per-purpose subtotals: generation/regeneration/validation always
        // present (validation = 0 here), smoke omitted (none).
        let subtotals = month.subtotalsByPurpose
        #expect(subtotals.map(\.purpose) == [.generation, .regeneration, .validation])
        #expect(abs(subtotals[0].totalUSD - 0.33) < 1e-9)
        #expect(abs(subtotals[1].totalUSD - 0.25) < 1e-9)
        #expect(subtotals[2].totalUSD == 0)

        // Label: title when the meeting exists, purpose badge otherwise.
        let withMeeting = try #require(month.receipts.first { $0.meetingID == meetingID })
        #expect(month.label(for: withMeeting) == "Weekly Vexatron sync")
        let orphan = try #require(month.receipts.first { $0.meetingID == nil })
        #expect(month.label(for: orphan) == "Regenerations")

        // Reconciliation: receipts sum 0.58, accumulator 1.08 → +0.50 delta
        // from the pre-receipts history (the panel labels this honestly).
        #expect(abs(month.receiptsSumUSD - 0.58) < 1e-9)
        #expect(abs(month.accumulatorUSD - 1.08) < 1e-9)
        #expect(abs(month.reconciliationDeltaUSD - 0.50) < 1e-9)
        #expect(!month.reconciles)
    }

    /// M-3 (the FK dropped-receipt class): a receipt whose `meetingID` has no
    /// meeting row must NOT be dropped on its FK violation. The ledger detects
    /// the missing row and writes the receipt with meeting_id NULL — the money
    /// AND the line item survive; only attribution is lost (a purpose badge).
    /// Before the fix this dropped the whole receipt silently (accumulator
    /// bumped, zero receipts) — the auditor's AuditFKProbe shape.
    @Test func receiptForAbsentMeetingIsKeptWithNullMeetingID() async throws {
        let database = try makeDatabase()
        let ledger = CloudSpendLedger(database: database)
        let ghostMeeting = ULID.generate()  // never inserted into `meeting`

        let total = try await ledger.add(
            0.10,
            receipt: CloudSpendLedger.ReceiptDraft(
                engineID: "claude-sonnet", model: "claude-sonnet-4-6",
                purpose: .validation, meetingID: ghostMeeting,
                inputTokens: 1, outputTokens: 1))

        #expect(abs(total - 0.10) < 1e-9)
        let month = try await ledger.monthReceipts()
        #expect(month.receipts.count == 1, "the line item is preserved, not dropped")
        let r = try #require(month.receipts.first)
        #expect(r.meetingID == nil, "attribution lost (no meeting row), money kept")
        #expect(r.purpose == .validation)
        #expect(abs(r.costUSD - 0.10) < 1e-9)
        #expect(month.reconciles, "the kept receipt reconciles with the bump")
    }

    /// ON DELETE SET NULL: a receipt outlives its meeting (the bill is real).
    @Test func deletingAMeetingNullsItsReceiptMeetingID() async throws {
        let database = try makeDatabase()
        let ledger = CloudSpendLedger(database: database)
        let meetingID = ULID.generate()
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO meeting (id, title, started_at, source, status, attendees, created_at, updated_at)
                    VALUES (?, 'Gone meeting', ?, 'meet', 'ready', '[]', ?, ?)
                    """,
                arguments: [meetingID, msDate(), msDate(), msDate()])
        }
        try await ledger.add(
            0.10,
            receipt: CloudSpendLedger.ReceiptDraft(
                engineID: "claude-sonnet", model: "claude-sonnet-4-6",
                purpose: .generation, meetingID: meetingID,
                inputTokens: 1, outputTokens: 1))
        try await database.pool.write { db in
            try db.execute(sql: "DELETE FROM meeting WHERE id = ?", arguments: [meetingID])
        }
        let month = try await ledger.monthReceipts()
        #expect(month.receipts.count == 1)
        #expect(month.receipts.first?.meetingID == nil, "ON DELETE SET NULL keeps the receipt")
        #expect(abs(month.accumulatorUSD - 0.10) < 1e-9, "the bill survives the meeting")
    }
}
