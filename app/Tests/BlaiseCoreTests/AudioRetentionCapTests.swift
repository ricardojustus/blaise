import Foundation
import GRDB
import Testing
@testable import BlaiseCore

// G16 §4 (specs/g16_audio_retention.md): the size cap. The pure plan
// (unlimited plans nothing; oldest-first; never the most recent meeting; stops
// with `remainingOverCap` when only ineligible audio remains), the setting
// (default Unlimited, round-trips), and `AudioRetentionSweeper` end to end
// plus its coalescing (one in flight, one re-run).

private func entry(
    _ id: MeetingID,
    startedAt seconds: Double,
    bytes: Int64,
    capEligible: Bool = true
) -> AudioUsage.Entry {
    AudioUsage.Entry(
        meetingID: id, title: id, startedAt: msDate(seconds), bytes: bytes,
        audioDeletedAt: nil, manualEligible: true, capEligible: capEligible)
}

private func plantAudio(_ database: BlaiseDatabase, _ id: MeetingID, bytes: Int) throws {
    try Data(repeating: 0xA5, count: bytes).write(to: database.paths.audioURL(id))
}

@discardableResult
private func insertMeeting(
    _ database: BlaiseDatabase,
    status: MeetingStatus = .ready,
    startedAt: Date
) async throws -> MeetingID {
    let meeting = makeMeeting(startedAt: startedAt, status: status)
    try database.paths.createMeetingDirectory(meeting.id)
    try await MeetingRepository(database: database).create(meeting)
    return meeting.id
}

private func mark(_ database: BlaiseDatabase, _ id: MeetingID) async throws -> String? {
    try await database.pool.read { db in
        try String.fetchOne(db, sql: "SELECT audio_deleted_reason FROM meeting WHERE id = ?", arguments: [id])
    }
}

/// A one-shot gate: `wait()` suspends until `open()`; `entered` counts waits.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var entered = 0

    func wait() async {
        entered += 1
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

@Suite struct AudioRetentionCapTests {

    // MARK: - capPlan (pure)

    @Test("unlimited plans nothing, even far over any cap")
    func unlimitedIsEmpty() {
        let usage = AudioUsage(entries: [
            entry("a", startedAt: 1, bytes: 80_000_000_000),
            entry("b", startedAt: 2, bytes: 1),
        ])
        #expect(AudioRetention.capPlan(usage: usage, cap: .unlimited) == .empty)
    }

    @Test("under the cap plans nothing")
    func underCapIsEmpty() {
        let usage = AudioUsage(entries: [
            entry("a", startedAt: 1, bytes: 400_000_000),
            entry("b", startedAt: 2, bytes: 400_000_000),
        ])
        #expect(AudioRetention.capPlan(usage: usage, cap: .gb1) == .empty)
    }

    @Test("deletes cap-eligible meetings oldest-first by startedAt until usage ≤ cap")
    func oldestFirst() {
        // Entries deliberately out of order; ineligible old ones are skipped.
        let usage = AudioUsage(entries: [
            entry("c", startedAt: 30, bytes: 600_000_000),
            entry("a", startedAt: 10, bytes: 600_000_000),
            entry("x", startedAt: 5, bytes: 100_000_000, capEligible: false),
            entry("b", startedAt: 20, bytes: 600_000_000),
            entry("d", startedAt: 40, bytes: 600_000_000, capEligible: false),
        ])
        // Total 2.5 GB, cap 1 GB → drop a (1.9), b (1.3), c (0.7).
        let plan = AudioRetention.capPlan(usage: usage, cap: .gb1)
        #expect(plan.meetingIDs == ["a", "b", "c"])
        #expect(plan.bytesFreed == 1_800_000_000)
        #expect(plan.remainingOverCap == 0)

        // A 2 GB cap stops after the first deletion.
        let smaller = AudioRetention.capPlan(usage: usage, cap: .gb2)
        #expect(smaller.meetingIDs == ["a"])
        #expect(smaller.remainingOverCap == 0)
    }

    @Test("stops with remainingOverCap when only ineligible audio remains; never forces")
    func stopsWhenOnlyIneligibleRemains() {
        let usage = AudioUsage(entries: [
            entry("old", startedAt: 1, bytes: 500_000_000),
            entry("failed", startedAt: 2, bytes: 1_500_000_000, capEligible: false),
            entry("latest", startedAt: 3, bytes: 700_000_000, capEligible: false),
        ])
        let plan = AudioRetention.capPlan(usage: usage, cap: .gb1)
        #expect(plan.meetingIDs == ["old"])
        #expect(plan.bytesFreed == 500_000_000)
        #expect(plan.remainingOverCap == 1_200_000_000)
    }

    @Test("usage marks the most recent meeting and non-ready meetings cap-ineligible; the plan never picks them")
    func neverTheMostRecent() async throws {
        let database = try makeDatabase()
        let oldest = try await insertMeeting(database, startedAt: msDate(1_000))
        let failed = try await insertMeeting(database, status: .failed, startedAt: msDate(2_000))
        let latest = try await insertMeeting(database, startedAt: msDate(3_000))
        for id in [oldest, failed, latest] { try plantAudio(database, id, bytes: 64 * 1024) }

        let usage = try await AudioRetention.usage(database: database)
        let byID = Dictionary(uniqueKeysWithValues: usage.entries.map { ($0.meetingID, $0) })
        #expect(byID[oldest]?.capEligible == true)
        #expect(byID[failed]?.capEligible == false)
        #expect(byID[latest]?.capEligible == false)
        #expect(byID[latest]?.manualEligible == true)

        // A zero-byte cap: everything is over; only the oldest ready one goes.
        let plan = AudioRetention.capPlan(usage: usage, capBytes: 0)
        #expect(plan.meetingIDs == [oldest])
        #expect(plan.remainingOverCap == usage.totalBytes - (byID[oldest]?.bytes ?? 0))
        #expect(plan.remainingOverCap > 0)
    }

    // MARK: - Settings

    @Test("cap setting: default Unlimited, round-trips through SettingsStore, labels and decimal bytes")
    func settingsRoundTrip() async throws {
        let store = SettingsStore(database: try makeDatabase())
        #expect(AudioRetentionSettings.defaultCap == .unlimited)
        #expect(await AudioRetentionSettings.cap(from: store) == .unlimited)
        for cap in AudioRetentionCap.allCases {
            try await store.set(AudioRetentionSettings.capKey, to: cap)
            #expect(await AudioRetentionSettings.cap(from: store) == cap)
        }
        #expect(AudioRetentionCap.mb250.bytes == 250_000_000)
        #expect(AudioRetentionCap.mb500.bytes == 500_000_000)
        #expect(AudioRetentionCap.gb1.bytes == 1_000_000_000)
        #expect(AudioRetentionCap.gb50.bytes == 50_000_000_000)
        #expect(AudioRetentionCap.unlimited.bytes == nil)
        #expect(AudioRetentionCap.mb250.label == "250 MB")
        #expect(AudioRetentionCap.gb5.label == "5 GB")
        #expect(AudioRetentionCap.unlimited.label == "Unlimited")
        // Garbage in the store falls back to the default (never deletes).
        try await store.set(AudioRetentionSettings.capKey, to: "gb3")
        #expect(await AudioRetentionSettings.cap(from: store) == .unlimited)
    }

    // MARK: - Sweeper

    @Test("sweeper deletes the oldest ready meetings' audio until under the cap, keeps the rest")
    func sweeperEndToEnd() async throws {
        let harness = try await makePipelineHarness()
        let database = harness.database
        var ids: [MeetingID] = []
        for n in 1...4 {
            let id = try await insertMeeting(database, startedAt: msDate(Double(n) * 1_000))
            try plantAudio(database, id, bytes: 64 * 1024)
            ids.append(id)
        }
        let usage = try await AudioRetention.usage(database: database)
        let per = try #require(usage.entries.first?.bytes)
        #expect(usage.entries.allSatisfy { $0.bytes == per })
        // Room for 2.5 meetings → the two oldest must go.
        let cap = usage.totalBytes - per - per / 2
        let sweeper = AudioRetentionSweeper(
            database: database, pipeline: harness.pipeline, beforePass: nil, capBytesOverride: cap)

        let plan = await sweeper.sweepNow()
        #expect(plan.meetingIDs == [ids[0], ids[1]])
        #expect(plan.remainingOverCap == 0)
        for id in ids.prefix(2) {
            #expect(try await mark(database, id) == "cap")
            #expect(AudioRetention.audioFileURLs(paths: database.paths, meetingID: id).isEmpty)
            #expect(try await harness.meeting(id)?.status == .ready, "row kept")
        }
        for id in ids.suffix(2) {
            #expect(try await mark(database, id) == nil)
            #expect(!AudioRetention.audioFileURLs(paths: database.paths, meetingID: id).isEmpty)
        }
        #expect(try await AudioRetention.usage(database: database).totalBytes <= cap)

        // A second sweep is a no-op (already under the cap).
        #expect(await sweeper.sweepNow() == .empty)
    }

    @Test("sweeper with the real setting: Unlimited (default) deletes nothing")
    func sweeperUnlimitedDeletesNothing() async throws {
        let harness = try await makePipelineHarness()
        let database = harness.database
        let old = try await insertMeeting(database, startedAt: msDate(1_000))
        _ = try await insertMeeting(database, startedAt: msDate(2_000))
        try plantAudio(database, old, bytes: 64 * 1024)
        let sweeper = AudioRetentionSweeper(database: database, pipeline: harness.pipeline)
        #expect(await sweeper.sweepNow() == .empty)
        #expect(try await mark(database, old) == nil)
        #expect(!AudioRetention.audioFileURLs(paths: database.paths, meetingID: old).isEmpty)
    }

    @Test("coalescing: two requests during a sweep → exactly one re-run")
    func coalescing() async throws {
        let harness = try await makePipelineHarness()
        let gate = Gate()
        let sweeper = AudioRetentionSweeper(
            database: harness.database, pipeline: harness.pipeline,
            beforePass: { await gate.wait() }, capBytesOverride: nil)

        let first = Task { await sweeper.sweepNow() }
        // Wait until the first pass is parked on the gate.
        while await gate.entered == 0 { await Task.yield() }
        await sweeper.requestSweep()
        await sweeper.requestSweep()
        #expect(await sweeper.passCount == 0)
        await gate.open()
        _ = await first.value
        #expect(await sweeper.passCount == 2, "the running pass plus ONE coalesced re-run")
        #expect(await gate.entered == 2)

        // Idle again: a new request starts a fresh sweep.
        await sweeper.sweepNow()
        #expect(await sweeper.passCount == 3)
    }
}
