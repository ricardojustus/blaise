import Foundation
import GRDB
import Testing
@testable import BlaiseCore

// Settings Backup tab (slice 3): the view model over the real engine, on BackupHarness's fictional
// DemoSeeder library and throwaway destinations.

private let utc = TimeZone(identifier: "UTC")!
private var fm: FileManager { .default }

/// The bookmark reports `/private/var/…` for a `/var/…` temporary folder.
private func samePath(_ path: String?, _ url: URL) -> Bool {
    func plain(_ p: String) -> String { p.hasPrefix("/private/var/") ? String(p.dropFirst("/private".count)) : p }
    return path.map(plain) == plain(url.path)
}

@MainActor
private final class Confirmed {
    var restores: [StagedRestore] = []
}

@MainActor
private func makeModel(_ h: BackupHarness, confirmed: Confirmed = Confirmed(), password: String? = nil) -> BackupSettingsModel {
    BackupSettingsModel(
        engine: h.engine, database: h.database,
        now: { h.clock.withLock { $0 } }, timeZone: { utc },
        generatePassword: { try password ?? BackupEngine.generatePassword() },
        confirmRestore: { confirmed.restores.append($0) })
}

/// Holds the next run at its second recording check (the first meeting file) until released.
private final class RunHold: Sendable {
    let stream: AsyncStream<Void>
    let release: AsyncStream<Void>.Continuation

    init(_ h: BackupHarness) {
        (stream, release) = AsyncStream<Void>.makeStream()
        let at = h.recordingChecks.withLock { $0 } + 2
        let stream = stream
        h.trigger.withLock { $0 = (at: at, action: { for await _ in stream { break } }) }
    }

    func waitUntilHeld(_ h: BackupHarness, at: Int) async {
        while h.recordingChecks.withLock({ $0 }) < at { try? await Task.sleep(for: .milliseconds(5)) }
    }
}

/// Blocks the engine actor inside the first matching synchronous file operation until released:
/// the engine cannot answer any call meanwhile.
private final class SyncHold: Sendable {
    private let held = Locked(false)
    private let gate = DispatchSemaphore(value: 0)

    init(_ h: BackupHarness, when match: @escaping @Sendable (BackupFileOp) -> Bool) {
        let held = held, gate = gate
        let armed = Locked(true)
        h.failer.withLock {
            $0 = { op in
                guard match(op), armed.m.withLock({ let first = $0; $0 = false; return first }) else { return }
                held.m.withLock { $0 = true }
                _ = gate.wait(timeout: .now() + 30)
            }
        }
    }

    func waitUntilHeld() async {
        while !held.m.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func release() { gate.signal() }
}

/// Polls `condition` on the main actor for up to `seconds`. The bound only ends a failing wait; the
/// parallel suite can stall the main actor for over 2 s.
@MainActor
private func eventually(_ seconds: Double = 30, _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
    while !condition() {
        if ContinuousClock.now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

/// Serialized: several tests block a cooperative-pool thread inside the engine (`SyncHold`) or
/// spin the main actor until a run starts. Run side by side on a host with few cores, they take
/// every pool thread and wait on each other until the 30 s holds time out.
@MainActor
@Suite(.serialized)
struct BackupSettingsModelTests {

    // MARK: Status line

    private func state(last: Date?, configured: Date = Date(timeIntervalSince1970: 0), failure: BackupFailureReason? = nil) -> BackupState {
        var s = BackupState()
        s.destinationBookmark = Data([1])
        s.configuredAt = configured
        s.lastSuccessAt = last
        s.lastFailure = failure.map { .init(reason: $0, at: configured) }
        return s
    }

    @Test func statusLineTodayDaysAndNone() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)  // 2026-09-21 14:13:20Z
        let today = now - 45_600  // 01:33:20Z
        #expect(BackupSettingsModel.statusLine(state(last: today), now: now, timeZone: utc) == "Last backup: today, 01:33")
        #expect(BackupSettingsModel.statusLine(state(last: now - 86_400), now: now, timeZone: utc) == "Last backup: 1 day ago")
        #expect(BackupSettingsModel.statusLine(state(last: now - 3 * 86_400), now: now, timeZone: utc) == "Last backup: 3 days ago")
        #expect(BackupSettingsModel.statusLine(state(last: nil, configured: now), now: now, timeZone: utc) == "No backup yet")
        #expect(BackupSettingsModel.statusLine(BackupState(), now: now, timeZone: utc) == "No backup yet")
        // Before 7 days a failure shows nothing.
        #expect(BackupSettingsModel.statusLine(state(last: now - 6 * 86_400, failure: .notConnected), now: now, timeZone: utc)
            == "Last backup: 6 days ago")
    }

    @Test func statusLineNeverSaysSevenDaysBeforeTheStaleLine() {
        let last = Date(timeIntervalSince1970: 1_789_945_200)  // 2026-09-20 23:00Z
        for age: TimeInterval in [522_000, 7 * 86_400 - 1] {  // 6 d 1 h, and 1 s short of 7 d: 7 calendar days
            #expect(BackupSettingsModel.statusLine(state(last: last, failure: .notConnected), now: last + age, timeZone: utc)
                == "Last backup: 6 days ago")
        }
        #expect(BackupSettingsModel.statusLine(state(last: last, failure: .notConnected), now: last + 7 * 86_400, timeZone: utc)
            == "Last backup 7 days ago — drive not connected")
    }

    @Test func statusLineSevenDayWordingForEachReason() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let old = now - 9 * 86_400
        let expected: [BackupFailureReason: String] = [
            .notConnected: "drive not connected",
            .notWritable: "folder not writable",
            .full: "destination full",
            .localDiskFull: "this Mac's disk is full",
            .localError: "could not read the library on this Mac",
            .databaseCheck: "database check failed",
            .passwordUnavailable: "encryption password missing — turn Encrypt backups off and on again",
        ]
        #expect(expected.count == BackupFailureReason.allCases.count)
        for (reason, text) in expected {
            #expect(BackupSettingsModel.statusLine(state(last: old, failure: reason), now: now, timeZone: utc)
                == "Last backup 9 days ago — \(text)")
        }
        #expect(BackupSettingsModel.statusLine(state(last: old), now: now, timeZone: utc) == "Last backup 9 days ago")
        #expect(BackupSettingsModel.statusLine(state(last: nil, configured: old, failure: .notConnected), now: now, timeZone: utc)
            == "No backup yet — drive not connected")
        // The boundary: 7 days exactly is stale.
        #expect(BackupSettingsModel.statusLine(state(last: now - 7 * 86_400), now: now, timeZone: utc) == "Last backup 7 days ago")
    }

    // MARK: Folder, same disk, Back Up Now

    @Test func sameDiskLineOnAndOff() async throws {
        let h = try await BackupHarness()
        #expect(BackupSettingsModel.isOnSameDisk(h.dest, as: h.root))
        #expect(!BackupSettingsModel.isOnSameDisk(URL(fileURLWithPath: "/dev"), as: h.root))
        #expect(!BackupSettingsModel.isOnSameDisk(h.dest.appendingPathComponent("gone"), as: h.root))

        let model = makeModel(h)
        await model.refresh(checkDisk: true)
        #expect(model.folderPath == nil)
        #expect(!model.onSameDisk)

        await model.chooseFolder(h.dest)
        #expect(samePath(model.folderPath, h.dest))
        #expect(model.onSameDisk)
        #expect(model.statusLine.hasPrefix("Last backup: today"))

        let reopened = makeModel(h)
        await reopened.refresh(checkDisk: true)
        #expect(reopened.onSameDisk)
        #expect(reopened.folderPath == model.folderPath)
    }

    @Test func aRejectedFolderLeavesTheSameDiskLineOfTheStoredOne() async throws {
        let h = try await BackupHarness(meetings: false)
        let model = makeModel(h)
        await model.chooseFolder(h.dest)
        #expect(model.onSameDisk)

        await model.chooseFolder(URL(fileURLWithPath: "/dev/no-such-folder"))
        #expect(model.folderError != nil)
        #expect(samePath(model.folderPath, h.dest))
        #expect(model.onSameDisk)
    }

    @Test func folderPathShowsWhileTheFolderIsGone() async throws {
        let h = try await BackupHarness()
        let model = makeModel(h)
        await model.chooseFolder(h.dest)
        try fm.removeItem(at: h.dest)
        await model.refresh(checkDisk: true)
        #expect(samePath(model.folderPath, h.dest))
        #expect(!model.onSameDisk)
    }

    @Test func backUpNowDisabledWhileARunIsInFlight() async throws {
        let h = try await BackupHarness()
        let model = makeModel(h)
        #expect(!model.canBackUpNow)  // no folder yet
        await model.chooseFolder(h.dest)
        #expect(model.canBackUpNow)
        #expect(!model.isBackingUp)

        let hold = RunHold(h)
        let at = h.recordingChecks.withLock { $0 } + 2
        let run = Task { await model.backUpNow() }
        await hold.waitUntilHeld(h, at: at)
        #expect(model.isBackingUp)
        #expect(!model.canBackUpNow)
        #expect(model.restoreUnavailableReason(isRecording: false) == BackupSettingsModel.backingUpRefusal)

        // A tab opened meanwhile sees the engine's run too (the hourly tick's case).
        let other = makeModel(h)
        await other.refresh()
        #expect(other.isBackingUp)
        #expect(!other.canBackUpNow)

        hold.release.yield()
        await run.value
        #expect(!model.isBackingUp)
        #expect(model.canBackUpNow)
        await other.refresh()
        #expect(!other.isBackingUp)
    }

    @Test func aTickRunShowsWhileTheEngineIsInASynchronousStep() async throws {
        let h = try await BackupHarness()
        let model = makeModel(h)
        await model.chooseFolder(h.dest)
        h.advance(86_400)
        await model.refresh()
        #expect(!model.isBackingUp)

        let hold = SyncHold(h) { if case .stage = $0 { true } else { false } }
        let run = Task { await h.engine.tick() }
        await hold.waitUntilHeld()
        let poll = Task { await model.refresh() }
        #expect(await eventually { model.isBackingUp })
        #expect(!model.canBackUpNow)
        #expect(model.restoreUnavailableReason(isRecording: false) == BackupSettingsModel.backingUpRefusal)

        hold.release()
        await poll.value
        #expect(await run.value == .succeeded)
        await model.refresh()
        #expect(!model.isBackingUp)
    }

    @Test func pollStopsWhenTheTabCloses() async throws {
        let h = try await BackupHarness(meetings: false)
        _ = try await h.configure()

        let polling = makeModel(h)
        let running = Task { await polling.poll(every: .milliseconds(20)) }
        #expect(await eventually { polling.state.isConfigured })
        running.cancel()
        await running.value

        // An interval no suite load can outrun: what is under test is the cancelled wait.
        let closed = makeModel(h)
        let poll = Task { await closed.poll(every: .seconds(3600)) }
        try await Task.sleep(for: .milliseconds(100))
        poll.cancel()
        await poll.value
        #expect(!closed.state.isConfigured)  // no refresh after the cancelled wait
    }

    @Test func backUpNowWhileRecordingSaysSo() async throws {
        let h = try await BackupHarness()
        let model = makeModel(h)
        await model.chooseFolder(h.dest)
        h.recording.withLock { $0 = true }
        await model.backUpNow()
        #expect(model.backUpNotice == BackupSettingsModel.recordingRefusal)
        h.recording.withLock { $0 = false }
        await model.backUpNow()
        #expect(model.backUpNotice == nil)
    }

    @Test func theRecordingRefusalClearsWhenTheRecordingEnds() async throws {
        let h = try await BackupHarness(meetings: false)
        let model = makeModel(h)
        await model.chooseFolder(h.dest)
        h.recording.withLock { $0 = true }
        await model.backUpNow()
        #expect(model.backUpNotice == BackupSettingsModel.recordingRefusal)
        await model.refresh()
        #expect(model.backUpNotice == BackupSettingsModel.recordingRefusal)  // still recording

        h.recording.withLock { $0 = false }
        model.recordingEnded()
        #expect(model.backUpNotice == nil)
        #expect(model.canBackUpNow)
    }

    @Test func restoreUnavailableWhileRecording() async throws {
        let h = try await BackupHarness()
        let model = makeModel(h)
        #expect(model.restoreUnavailableReason(isRecording: true) == BackupSettingsModel.recordingRefusal)
        #expect(model.restoreUnavailableReason(isRecording: false) == nil)  // no destination needed
    }

    // MARK: Encryption sheet

    @Test func encryptStoresTheGeneratedPassword() async throws {
        let h = try await BackupHarness()
        let model = makeModel(h)
        await model.chooseFolder(h.dest)
        await model.beginEnableEncryption()
        let password = try #require(model.pendingPassword)
        #expect(password.count == 35)
        #expect(try h.secrets.get(key: BackupEngine.passwordKey) == nil)
        #expect(!(await h.engine.state().isEncrypted))

        await model.confirmEncryption()
        #expect(model.pendingPassword == nil)
        #expect(try h.secrets.get(key: BackupEngine.passwordKey) == password)
        let s = await h.engine.state()
        #expect(s.isEncrypted)
        #expect(s.keyID != nil)
        #expect(model.state.isEncrypted)
    }

    /// Only the flush after the state file was replaced failed: encryption is on with this
    /// password, so the sheet closes with no error.
    @Test func aFailedFlushAfterTheStateReplaceShowsEncryptionOn() async throws {
        let h = try await BackupHarness()
        let model = makeModel(h)
        await model.chooseFolder(h.dest)
        await model.beginEnableEncryption()
        let password = try #require(model.pendingPassword)

        let replaced = Locked(false)
        h.failer.withLock {
            $0 = { op in
                if case .rename(_, let to) = op, to.hasSuffix("/.backup-state.json") { replaced.m.withLock { $0 = true } }
                if case .flush = op, replaced.m.withLock({ $0 }) { throw POSIXError(.EIO) }
            }
        }
        await model.confirmEncryption()
        h.failer.withLock { $0 = nil }
        #expect(replaced.m.withLock { $0 })
        #expect(model.encryptionError == nil)
        #expect(model.pendingPassword == nil)
        #expect(model.state.isEncrypted)
        #expect(try h.secrets.get(key: BackupEngine.passwordKey) == password)
    }

    @Test func cancelStoresNothing() async throws {
        let h = try await BackupHarness()
        let model = makeModel(h)
        await model.chooseFolder(h.dest)
        let before = await h.engine.state()
        await model.beginEnableEncryption()
        #expect(model.pendingPassword != nil)
        model.cancelEncryption()
        #expect(model.pendingPassword == nil)
        #expect(try h.secrets.get(key: BackupEngine.passwordKey) == nil)
        #expect(await h.engine.state() == before)
    }

    /// Holds the engine actor in a state-file write, with no run in flight.
    private func holdStateWrite(_ h: BackupHarness) async -> (SyncHold, Task<Void, Never>) {
        let hold = SyncHold(h) {
            if case .write(let path, _) = $0 { path.contains(".backup-state.json.tmp-") } else { false }
        }
        let blocker = Task { _ = try? await h.engine.disableEncryption() }
        await hold.waitUntilHeld()
        return (hold, blocker)
    }

    @Test func cancelWhileEncryptIsSavingStoresNothingElse() async throws {
        let h = try await BackupHarness()
        let model = makeModel(h)
        await model.chooseFolder(h.dest)
        await model.beginEnableEncryption()
        let password = try #require(model.pendingPassword)

        let (hold, blocker) = await holdStateWrite(h)
        let confirm = Task { await model.confirmEncryption() }
        #expect(await eventually { model.isSavingEncryption })
        #expect(!model.canConfirmEncryption)
        // A repeat press returns at once instead of queueing a second save behind the engine.
        let repeatReturned = Locked(false)
        let again = Task { await model.confirmEncryption(); repeatReturned.m.withLock { $0 = true } }
        #expect(await eventually { repeatReturned.m.withLock { $0 } })
        model.cancelEncryption()
        #expect(model.pendingPassword == password)  // the sheet stays up; Cancel did nothing

        hold.release()
        await blocker.value
        await confirm.value
        await again.value
        #expect(!model.isSavingEncryption)
        #expect(model.pendingPassword == nil)
        #expect(try h.secrets.get(key: BackupEngine.passwordKey) == password)
        #expect(model.state.isEncrypted)
    }

    /// A print that waits (on the print gate, or with its panel open) until released.
    @MainActor private final class PrintHold {
        let stream: AsyncStream<Void>
        let release: AsyncStream<Void>.Continuation
        var printed: [String] = []
        init() { (stream, release) = AsyncStream<Void>.makeStream() }
        func body(_ password: String) async {
            printed.append(password)
            for await _ in stream { break }
        }
    }

    @Test func cancelAndDismissAreRefusedWhileAPrintWaits() async throws {
        let h = try await BackupHarness()
        let model = makeModel(h)
        await model.chooseFolder(h.dest)
        await model.beginEnableEncryption()
        let password = try #require(model.pendingPassword)

        let print = PrintHold()
        model.printPassword(print.body)
        #expect(model.isPrinting)  // set on the press, before the print's task runs
        #expect(!model.canPrint)
        // A second Print… while the first waits never starts its print.
        let second = PrintHold()
        model.printPassword(second.body)
        #expect(await eventually { print.printed == [password] })
        // Cancel, Escape and the sheet's dismissal all route through cancelEncryption().
        model.cancelEncryption()
        #expect(model.pendingPassword == password)

        print.release.yield()
        #expect(await eventually { !model.isPrinting })
        #expect(second.printed.isEmpty)
        second.release.finish()
        model.cancelEncryption()
        #expect(model.pendingPassword == nil)
        #expect(try h.secrets.get(key: BackupEngine.passwordKey) == nil)
    }

    @Test func encryptIsRefusedWhileAPrintWaits() async throws {
        let h = try await BackupHarness()
        let model = makeModel(h)
        await model.chooseFolder(h.dest)
        await model.beginEnableEncryption()
        let password = try #require(model.pendingPassword)
        #expect(model.canConfirmEncryption)

        let print = PrintHold()
        model.printPassword(print.body)
        #expect(!model.canConfirmEncryption)  // Encrypt Backups and Return
        await model.confirmEncryption()
        #expect(model.pendingPassword == password)
        #expect(!model.isSavingEncryption)
        #expect(try h.secrets.get(key: BackupEngine.passwordKey) == nil)
        #expect(!(await h.engine.state().isEncrypted))

        print.release.yield()
        #expect(await eventually { !model.isPrinting })
        #expect(model.canConfirmEncryption)
        await model.confirmEncryption()
        #expect(model.pendingPassword == nil)
        #expect(try h.secrets.get(key: BackupEngine.passwordKey) == password)
    }

    @Test func printIsRefusedWhileEncryptIsSaving() async throws {
        let h = try await BackupHarness()
        let model = makeModel(h)
        await model.chooseFolder(h.dest)
        await model.beginEnableEncryption()
        let password = try #require(model.pendingPassword)

        let (hold, blocker) = await holdStateWrite(h)
        let confirm = Task { await model.confirmEncryption() }
        #expect(await eventually(10) { model.isSavingEncryption })
        #expect(!model.canPrint)
        let print = PrintHold()
        model.printPassword(print.body)
        #expect(!model.isPrinting)

        hold.release()
        await blocker.value
        await confirm.value
        #expect(print.printed.isEmpty)
        #expect(!model.isPrinting)
        #expect(model.pendingPassword == nil)
        #expect(try h.secrets.get(key: BackupEngine.passwordKey) == password)
    }

    @Test func encryptWaitsUntilTheEarlierBackupsLineIsKnown() async throws {
        let h = try await BackupHarness()
        let model = makeModel(h)
        await model.chooseFolder(h.dest)  // a plaintext snapshot in this namespace

        let (hold, blocker) = await holdStateWrite(h)
        let begin = Task { await model.beginEnableEncryption() }
        #expect(await eventually { model.pendingPassword != nil })
        #expect(!model.showsUnencryptedNotice)
        #expect(!model.canConfirmEncryption)

        hold.release()
        await blocker.value
        await begin.value
        #expect(model.showsUnencryptedNotice)
        #expect(model.canConfirmEncryption)

        // A check that returns after its sheet was cancelled changes nothing.
        model.cancelEncryption()
        let (again, blocked) = await holdStateWrite(h)
        let reopened = Task { await model.beginEnableEncryption() }
        #expect(await eventually { model.pendingPassword != nil })
        #expect(!model.showsUnencryptedNotice)
        model.cancelEncryption()
        again.release()
        await blocked.value
        await reopened.value
        #expect(!model.showsUnencryptedNotice)
    }

    @Test func aRunStartedDuringTheCheckShowsTheLine() async throws {
        let h = try await BackupHarness()
        let model = makeModel(h)
        await model.chooseFolder(h.dest)
        try? fm.removeItem(at: h.snapshotsDir)  // no plaintext snapshot: only the run applies

        let (hold, blocker) = await holdStateWrite(h)
        let begin = Task { await model.beginEnableEncryption() }
        #expect(await eventually { model.pendingPassword != nil })
        #expect(!model.canConfirmEncryption)

        let runHold = RunHold(h)
        let run = Task.detached { await h.engine.backUpNow() }
        hold.release()
        // Hold the main actor until the run is in flight, so the check's answer lands after it.
        let deadline = ContinuousClock.now + .seconds(30)
        while !h.engine.isBusyNow && ContinuousClock.now < deadline {}
        await begin.value
        #expect(model.showsUnencryptedNotice)
        #expect(model.canConfirmEncryption)

        runHold.release.yield()
        _ = await run.value
        await blocker.value
    }

    @Test func aRunInASynchronousStepShowsTheLineWhenTheSheetOpens() async throws {
        let h = try await BackupHarness(meetings: false)
        let model = makeModel(h)
        await model.chooseFolder(h.dest)
        try? fm.removeItem(at: h.snapshotsDir)  // no plaintext snapshot: only the run applies
        h.advance(86_400)
        await model.refresh()

        let hold = SyncHold(h) { if case .stage = $0 { true } else { false } }
        let run = Task { await h.engine.tick() }
        await hold.waitUntilHeld()
        let begin = Task { await model.beginEnableEncryption() }
        #expect(await eventually { model.pendingPassword != nil })
        #expect(model.showsUnencryptedNotice)
        #expect(model.canConfirmEncryption)

        hold.release()
        await begin.value
        _ = await run.value
    }

    @Test func unencryptedNoticeOnlyWhenItApplies() async throws {
        // No destination, no snapshots: no line.
        let fresh = try await BackupHarness()
        let none = makeModel(fresh)
        await none.beginEnableEncryption()
        #expect(!none.showsUnencryptedNotice)

        // A plaintext snapshot in this install's namespace: the line.
        let h = try await BackupHarness()
        let model = makeModel(h)
        await model.chooseFolder(h.dest)
        await model.beginEnableEncryption()
        #expect(model.showsUnencryptedNotice)

        // Only encrypted snapshots here, and plaintext ones in another namespace: no line.
        let e = try await BackupHarness()
        try await e.engine.enableEncryption(password: BackupEngine.generatePassword())
        let encrypted = makeModel(e)
        await encrypted.chooseFolder(e.dest)
        try fm.copyItem(at: h.install, to: e.dest.appendingPathComponent("Blaise Backups/ffffffffffffffff"))
        await encrypted.beginEnableEncryption()
        #expect(!encrypted.showsUnencryptedNotice)

        // A run in flight: the line.
        let hold = RunHold(e)
        let at = e.recordingChecks.withLock { $0 } + 2
        let run = Task { await e.engine.backUpNow() }
        await hold.waitUntilHeld(e, at: at)
        await encrypted.beginEnableEncryption()
        #expect(encrypted.showsUnencryptedNotice)
        hold.release.yield()
        _ = await run.value
    }

    // MARK: Restore sheets

    private func backedUp() async throws -> (BackupHarness, BackupSettingsModel, Confirmed) {
        let h = try await BackupHarness()
        let confirmed = Confirmed()
        let model = makeModel(h, confirmed: confirmed)
        await model.chooseFolder(h.dest)
        return (h, model, confirmed)
    }

    private var stagingName: String { ".restore-staging" }

    @Test func stagedMapsToConfirmAndCancelDiscardsStaging() async throws {
        let (h, model, confirmed) = try await backedUp()
        await model.beginRestore()
        #expect(model.restoreStep == .pick)
        let snapshot = try #require(model.snapshots.first)
        #expect(model.snapshots.count == 1)
        model.verify(snapshot)
        #expect(model.restoreStep == .verifying)
        await model.waitForVerify()
        guard case .confirm = model.restoreStep else {
            Issue.record("expected confirm, got \(String(describing: model.restoreStep))"); return
        }
        #expect(fm.fileExists(atPath: h.root.appendingPathComponent(stagingName).path))

        await model.cancelRestore()
        #expect(model.restoreStep == nil)
        #expect(!fm.fileExists(atPath: h.root.appendingPathComponent(stagingName).path))
        #expect(confirmed.restores.isEmpty)
    }

    @Test func confirmUnavailableWhileRecordingOrPaused() async throws {
        #expect(BackupSettingsModel.canQuitAndRestore(isRecording: false, isPaused: false))
        #expect(!BackupSettingsModel.canQuitAndRestore(isRecording: true, isPaused: false))
        #expect(!BackupSettingsModel.canQuitAndRestore(isRecording: false, isPaused: true))

        let (h, model, confirmed) = try await backedUp()
        await model.beginRestore()
        model.verify(try #require(model.snapshots.first))
        await model.waitForVerify()
        guard case .confirm(let staged, _) = model.restoreStep else { Issue.record("not staged"); return }
        model.quitAndRestore(isRecording: true, isPaused: false)
        model.quitAndRestore(isRecording: false, isPaused: true)
        #expect(confirmed.restores.isEmpty)
        model.quitAndRestore(isRecording: false, isPaused: false)
        #expect(confirmed.restores == [staged])
        try BackupRestore.discardStaging(dataRoot: h.root)
    }

    /// Confirming closes the sheet first (AppKit ignores a quit while a sheet is attached); the
    /// dismissal that follows, which calls `cancelRestore()`, keeps the confirmed staging.
    @Test func confirmClosesTheSheetAndKeepsStaging() async throws {
        let (h, model, confirmed) = try await backedUp()
        await model.beginRestore()
        model.verify(try #require(model.snapshots.first))
        await model.waitForVerify()
        guard case .confirm(let staged, _) = model.restoreStep else { Issue.record("not staged"); return }
        model.quitAndRestore(isRecording: false, isPaused: false)
        #expect(model.restoreStep == nil)
        #expect(confirmed.restores == [staged])
        await model.cancelRestore()
        #expect(fm.fileExists(atPath: h.root.appendingPathComponent(stagingName).path))
        try BackupRestore.discardStaging(dataRoot: h.root)
    }

    @Test func meetingsRecordedAfterLineApplies() async throws {
        let h = try await BackupHarness()
        let snapshotTime = h.clock.withLock { $0 }
        func setCreated(_ date: Date, onlyFirst: Bool) async throws {
            try await h.database.pool.write { db in
                try db.execute(
                    sql: onlyFirst
                        ? "UPDATE meeting SET created_at = ? WHERE id = (SELECT id FROM meeting ORDER BY id LIMIT 1)"
                        : "UPDATE meeting SET created_at = ?",
                    arguments: [date])
            }
        }
        try await setCreated(snapshotTime - 86_400, onlyFirst: false)
        let model = makeModel(h)
        await model.chooseFolder(h.dest)
        await model.beginRestore()
        let snapshot = try #require(model.snapshots.first)

        model.verify(snapshot)
        await model.waitForVerify()
        #expect(model.restoreStep.map { if case .confirm(_, false) = $0 { true } else { false } } == true)
        await model.cancelRestore()

        try await setCreated(snapshotTime + 3_600, onlyFirst: true)
        model.verify(snapshot)
        await model.waitForVerify()
        guard case .confirm(let staged, let after) = model.restoreStep else { Issue.record("not staged"); return }
        #expect(after)
        let lines = model.confirmLines(staged, meetingsAfter: after)
        #expect(lines.last == "Meetings recorded after 25 February 2026 will not appear in the library; their recordings stay on disk.")
        await model.cancelRestore()
    }

    @Test func confirmText() {
        let staged = StagedRestore(
            snapshot: "2026-02-25T06-13-20Z-0123abcd", sourceName: "Quoll Harbor iMac",
            createdAt: Date(timeIntervalSince1970: 1_772_000_000), appVersion: "1.10.0",
            items: ["blaise.sqlite"], damagedCount: 0)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let base = "Blaise will quit and restore the backup from 25 February 2026, 06:13 when it opens again. Your current library will be moved to \"Set Aside Before Restore 2026-09-21\" in the Blaise data folder. Nothing is deleted. Meeting files already on this Mac are kept as they are."
        #expect(BackupSettingsModel.confirmLines(staged, meetingsAfter: false, now: now, timeZone: utc) == [base])
        let damaged = StagedRestore(
            snapshot: staged.snapshot, sourceName: staged.sourceName, createdAt: staged.createdAt,
            appVersion: staged.appVersion, items: staged.items, damagedCount: 3)
        #expect(BackupSettingsModel.confirmLines(damaged, meetingsAfter: true, now: now, timeZone: utc) == [
            base,
            "3 files in this backup are damaged and will be skipped.",
            "Meetings recorded after 25 February 2026 will not appear in the library; their recordings stay on disk.",
        ])
    }

    @Test func encryptedSnapshotAsksForThePassword() async throws {
        let h = try await BackupHarness()
        let model = makeModel(h)
        await model.chooseFolder(h.dest)
        await model.beginEnableEncryption()
        let password = try #require(model.pendingPassword)
        await model.confirmEncryption()
        h.advance(86_400)
        await model.backUpNow()
        try h.secrets.delete(key: BackupEngine.passwordKey)

        await model.beginRestore()
        let snapshot = try #require(model.snapshots.first { $0.manifest?.encrypted == true })
        model.verify(snapshot)
        await model.waitForVerify()
        #expect(model.restoreStep == .password(incorrect: false))
        #expect(model.pickedSnapshot == snapshot)

        model.verify(snapshot, password: "00000-00000-00000-00000-00000-00000")
        await model.waitForVerify()
        #expect(model.restoreStep == .password(incorrect: true))
        #expect(!fm.fileExists(atPath: h.root.appendingPathComponent(stagingName).path))

        model.verify(snapshot, password: password)
        await model.waitForVerify()
        guard case .confirm = model.restoreStep else { Issue.record("not staged"); return }
        await model.cancelRestore()
        #expect(!fm.fileExists(atPath: h.root.appendingPathComponent(stagingName).path))
    }

    @Test func refusedRecordingBusyAndCancelledMapToTheirText() async throws {
        let (h, model, _) = try await backedUp()
        await model.beginRestore()
        let snapshot = try #require(model.snapshots.first)

        // Damaged archive: refused with the damaged message.
        let archive = snapshot.folder.appendingPathComponent("data.aar")
        let original = try Data(contentsOf: archive)
        try (original + Data([0])).write(to: archive)
        model.verify(snapshot)
        await model.waitForVerify()
        #expect(model.restoreStep == .message(BackupRestore.damagedMessage))
        try original.write(to: archive)

        // A recording: the spec's stop line.
        h.recording.withLock { $0 = true }
        model.verify(snapshot)
        await model.waitForVerify()
        #expect(model.restoreStep == .message(BackupRestore.recordingStartedMessage))
        h.recording.withLock { $0 = false }

        // A run in flight: busy.
        let hold = RunHold(h)
        let at = h.recordingChecks.withLock { $0 } + 2
        let run = Task { await h.engine.backUpNow() }
        await hold.waitUntilHeld(h, at: at)
        model.verify(snapshot)
        await model.waitForVerify()
        #expect(model.restoreStep == .message(BackupSettingsModel.stagingBusyMessage))
        hold.release.yield()
        _ = await run.value

        // Cancel while verifying: the sheet closes and nothing is left staged. (That run's
        // retention pruned the earlier same-day snapshot, so list again.)
        await model.beginRestore()
        model.verify(try #require(model.snapshots.first))
        model.cancelVerify()
        await model.waitForVerify()
        #expect(model.restoreStep == nil)
        #expect(!fm.fileExists(atPath: h.root.appendingPathComponent(stagingName).path))
    }

    @Test func damagedRowsCannotBePicked() async throws {
        let (h, model, _) = try await backedUp()
        await model.beginRestore()
        let snapshot = try #require(model.snapshots.first)
        try Data("{".utf8).write(to: snapshot.folder.appendingPathComponent("manifest.json"))
        await model.listSnapshots(in: h.dest)
        let row = try #require(model.snapshots.first)
        #expect(row.manifest == nil)
        #expect(model.rowText(row).hasSuffix("— damaged"))
        model.verify(row)
        #expect(model.restoreStep == .pick)
    }
}
