import AppleArchive
import CryptoKit
import Foundation
import GRDB
import OSLog
import Security
import Synchronization
import System
import Testing
@testable import BlaiseCore

// Backup engine (slice 1): fictional DemoSeeder library plus synthetic meeting-file bytes,
// throwaway data roots and destinations under the temporary directory.

private let testInstallID = "0123456789abcdef"
private let day: TimeInterval = 86_400
private let utc = TimeZone(identifier: "UTC")!

private func hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

final class Locked<T: Sendable>: Sendable {
    let m: Mutex<T>
    init(_ value: T) { m = Mutex(value) }
}

private func randomBytes(_ count: Int) -> Data {
    Data((0..<count).map { _ in UInt8.random(in: 0...255) })
}

/// A seeded library, a destination folder, and an engine with injected clock, recording flag
/// and file-operation hook.
final class BackupHarness: Sendable {
    let root: URL
    let dest: URL
    let database: BlaiseDatabase
    let secrets = InMemorySecretStore()
    let clock = Mutex(Date(timeIntervalSince1970: 1_772_000_000))  // 2026-02-25 06:13:20Z
    let zone = Mutex(TimeZone(identifier: "UTC")!)
    let recording = Mutex(false)
    let log = Mutex<[BackupFileOp]>([])
    let failer = Mutex<(@Sendable (BackupFileOp) throws -> Void)?>(nil)
    let recordingChecks = Mutex(0)
    let trigger = Mutex<(at: Int, action: @Sendable () async -> Void)?>(nil)
    let engine: BackupEngine

    init(meetings: Bool = true) async throws {
        root = try makeTempRoot()
        dest = try makeTempRoot()
        database = try BlaiseDatabase(rootURL: root)
        let box = Box()
        engine = BackupEngine(
            database: database, secrets: secrets,
            isRecording: { await box.harness!.checkRecording() },
            now: { box.harness!.clock.withLock { $0 } },
            timeZone: { box.harness?.zone.withLock { $0 } ?? utc }, installID: testInstallID,
            fileHook: { op in
                box.harness!.log.withLock { $0.append(op) }
                try box.harness!.failer.withLock { $0 }?(op)
            })
        box.harness = self
        if meetings { try await seedLibrary() }
    }

    private final class Box: @unchecked Sendable { weak var harness: BackupHarness? }

    func checkRecording() async -> Bool {
        let n = recordingChecks.withLock { $0 += 1; return $0 }
        if let t = trigger.withLock({ $0 }), t.at == n { await t.action() }
        return recording.withLock { $0 }
    }

    var install: URL { dest.appendingPathComponent("Blaise Backups/\(testInstallID)") }
    var snapshotsDir: URL { install.appendingPathComponent("snapshots") }
    var meetingsDir: URL { database.paths.meetingsDirectory }

    func advance(_ seconds: TimeInterval) { clock.withLock { $0 += seconds } }

    /// Every meeting of the database gets synthetic files; plus a row-less folder,
    /// a non-ULID folder and root-level items outside the allowlist.
    func seedLibrary() async throws {
        try await DemoSeeder.seed(database: database, now: clock.withLock { $0 })
        let ids = try await database.pool.read { try String.fetchAll($0, sql: "SELECT id FROM meeting ORDER BY id") }
        for (i, id) in ids.enumerated() {
            try writeMeetingFiles(id, variant: i)
        }
        try writeMeetingFiles(ULID.generate(), variant: 1)
        let stray = meetingsDir.appendingPathComponent("not-a-meeting")
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        try randomBytes(100).write(to: stray.appendingPathComponent("audio.m4a"))
        try Data("# Glossary\n- Vexatron Labs\n".utf8).write(to: database.paths.glossaryURL)
        try Data("quoll\n".utf8).write(to: database.paths.userStoplistURL)
        let voice = database.paths.voiceProfileDirectory
        try FileManager.default.createDirectory(at: voice, withIntermediateDirectories: true)
        try Data("{\"v\":1}".utf8).write(to: voice.appendingPathComponent("profile.json"))
        try Data("[]".utf8).write(to: voice.appendingPathComponent("candidates.json"))
        try Data("x".utf8).write(to: voice.appendingPathComponent("profile.json.corrupt"))
        for dir in ["models", "venv", "cache"] {
            let url = root.appendingPathComponent(dir)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try randomBytes(64).write(to: url.appendingPathComponent("blob.bin"))
        }
    }

    func writeMeetingFiles(_ id: String, variant: Int) throws {
        let dir = try database.paths.createMeetingDirectory(id)
        func put(_ name: String, _ size: Int = 2_000) throws {
            try randomBytes(size).write(to: dir.appendingPathComponent(name))
        }
        try put("audio.m4a", 20_000)
        try put("diarization.json")
        try put("capture_facts.json")
        try put("handoff/\(hex(Data(id.utf8))).json")
        try put("raw_asr.json")
        try put("transcript.json")
        try put("notes.md")
        try put(".audio.m4a.tmp-1")
        if variant % 2 == 0 { try put("audio_mic.m4a", 10_000); try put("room_treatment.json") }
        if variant % 3 == 0 { try put("audio_2.m4a", 5_000); try put("audio_mic_2.m4a", 5_000) }
        if variant == 1 { try put("capture_system.caf", 3_000); try put("import.wav", 3_000) }
    }

    /// Every allowlisted meeting file under valid-ULID folders, as `meeting/name`.
    func expectedFiles() throws -> Set<String> {
        var result = Set<String>()
        for m in try FileManager.default.contentsOfDirectory(atPath: meetingsDir.path) where ULID.isValid(m) {
            let dir = meetingsDir.appendingPathComponent(m)
            var names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            names += ((try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("handoff").path)) ?? [])
                .map { "handoff/" + $0 }
            for n in names where BackupAllowlist.isMeetingFileName(n) { result.insert(m + "/" + n) }
        }
        return result
    }

    func configure() async throws -> BackupEngine.RunOutcome {
        try await engine.chooseFolder(dest)
    }

    func completeSnapshots(_ dir: URL? = nil) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: (dir ?? snapshotsDir).path)) ?? [])
            .filter { BackupSnapshotName.date(of: $0) != nil }.sorted()
    }

    func manifest(_ name: String) throws -> BackupManifest {
        try BackupManifest.decode(Data(contentsOf: snapshotsDir.appendingPathComponent("\(name)/manifest.json")))
    }

    func latestManifest() throws -> BackupManifest { try manifest(completeSnapshots().last!) }

    /// A copy of the newest snapshot dated a minute before now: same day as the next run, so
    /// that run's retention drops it.
    func plantSameDaySnapshot() throws -> String {
        let name = BackupSnapshotName.make(clock.withLock { $0 } - 60)
        try FileManager.default.copyItem(
            at: snapshotsDir.appendingPathComponent(completeSnapshots().last!),
            to: snapshotsDir.appendingPathComponent(name))
        return name
    }

    /// Bytes written into the file stores by the logged operations.
    func storeBytesWritten(since index: Int = 0) -> Int {
        log.withLock { ops in
            ops[index...].reduce(0) { sum, op in
                if case .write(let path, let bytes) = op, path.contains("/\(testInstallID)/files") { return sum + bytes }
                return sum
            }
        }
    }

    func allFiles(under url: URL) -> [String] {
        let e = FileManager.default.enumerator(atPath: url.path)
        var out: [String] = []
        while let p = e?.nextObject() as? String {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.appendingPathComponent(p).path, isDirectory: &isDir)
            if !isDir.boolValue { out.append(p) }
        }
        return out
    }
}

private func run(_ tool: String, _ args: [String]) throws -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try p.run()
    let out = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: out, as: UTF8.self))
}

// MARK: - SC-001 / SC-003: the first snapshot

@Suite struct BackupRunTests {
    @Test func firstRunPublishesAllowlistOnly() async throws {
        let h = try await BackupHarness()
        #expect(try await h.configure() == .succeeded)
        let names = h.completeSnapshots()
        #expect(names.count == 1)
        let m = try h.latestManifest()
        #expect(m.format == 1 && !m.encrypted && m.keyID == nil)
        #expect(Set(m.files.map { $0.meeting + "/" + $0.name }) == (try h.expectedFiles()))
        let count = try await h.database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM meeting") }
        #expect(m.meetingCount == count)
        for f in m.files {
            let source = try Data(contentsOf: h.meetingsDir.appendingPathComponent("\(f.meeting)/\(f.name)"))
            let stored = try Data(contentsOf: h.install.appendingPathComponent(f.stored))
            #expect(stored == source && hex(source) == f.sha256 && f.stored.hasPrefix("files/\(f.meeting)/"))
        }
        let dataURL = h.snapshotsDir.appendingPathComponent("\(names[0])/data.aar")
        let data = try Data(contentsOf: dataURL)
        #expect(hex(data) == m.data.sha256 && Int64(data.count) == m.data.size && m.data.file == "data.aar")

        let (rc, listing) = try run("/usr/bin/aa", ["list", "-i", dataURL.path])
        #expect(rc == 0)
        let entries = Set(listing.split(separator: "\n").map(String.init))
        #expect(entries == ["blaise.sqlite", "Glossary.md", "stoplist_user.txt", "voice_profile",
                            "voice_profile/profile.json", "voice_profile/candidates.json"])

        // Nothing outside the allowlist anywhere at the destination.
        let everything = h.allFiles(under: h.dest)
        for bad in ["raw_asr", "transcript.json", "notes.md", ".tmp", "blob.bin", ".backup-state", ".backup-staging", "not-a-meeting", "corrupt"] {
            #expect(!everything.contains { $0.contains(bad) }, "found \(bad)")
        }
        #expect(!FileManager.default.fileExists(atPath: h.root.appendingPathComponent(".backup-staging").path))
        let state = await h.engine.state()
        #expect(state.lastSuccessAt == h.clock.withLock { $0 } && state.lastFailure == nil)
    }

    @Test func notConfiguredDoesNothing() async throws {
        let h = try await BackupHarness(meetings: false)
        #expect(await h.engine.tick() == .notConfigured)
        #expect(h.allFiles(under: h.dest).isEmpty)
    }

    @Test func absentMeetingsFolderMeansNoFiles() async throws {
        let h = try await BackupHarness(meetings: false)
        #expect(!FileManager.default.fileExists(atPath: h.meetingsDir.path))
        #expect(try await h.configure() == .succeeded)
        #expect(try h.latestManifest().files.isEmpty)
    }
}

// MARK: - TP7 / SC-002: incremental store and encryption transitions

@Suite struct BackupIncrementalTests {
    @Test func unchangedRunCopiesNothingAndNewFilesExactly() async throws {
        let h = try await BackupHarness()
        #expect(try await h.configure() == .succeeded)
        #expect(await h.engine.tick() == .notDue)

        var mark = h.log.withLock { $0.count }
        #expect(await h.engine.backUpNow() == .succeeded)
        #expect(h.storeBytesWritten(since: mark) == 0)

        h.advance(day)
        let meeting = try FileManager.default.contentsOfDirectory(atPath: h.meetingsDir.path).first(where: ULID.isValid)!
        let added = randomBytes(12_345)
        try added.write(to: h.meetingsDir.appendingPathComponent("\(meeting)/audio_3.m4a"))
        mark = h.log.withLock { $0.count }
        #expect(await h.engine.tick() == .succeeded)
        #expect(h.storeBytesWritten(since: mark) == added.count)
        #expect(h.completeSnapshots().count == 2)  // one per day: the same-day earlier one aged out
    }

    @Test func changedFileGetsNewNameAndOldSnapshotStillVerifies() async throws {
        let h = try await BackupHarness()
        #expect(try await h.configure() == .succeeded)
        let first = try h.latestManifest()
        let old = first.files.first { $0.name == "diarization.json" }!
        try randomBytes(2_100).write(to: h.meetingsDir.appendingPathComponent("\(old.meeting)/diarization.json"))
        h.advance(day)
        #expect(await h.engine.tick() == .succeeded)
        let new = try h.latestManifest().files.first { $0.meeting == old.meeting && $0.name == old.name }!
        #expect(new.stored != old.stored)
        #expect(hex(try Data(contentsOf: h.install.appendingPathComponent(old.stored))) == old.sha256)
    }

    @Test func damagedStoredFileIsReplaced() async throws {
        let h = try await BackupHarness()
        #expect(try await h.configure() == .succeeded)
        let entry = try h.latestManifest().files.first { $0.name == "audio.m4a" }!
        let storedURL = h.install.appendingPathComponent(entry.stored)
        try Data(try Data(contentsOf: storedURL).prefix(100)).write(to: storedURL)
        h.advance(60)
        #expect(await h.engine.backUpNow() == .succeeded)
        let again = try h.latestManifest().files.first { $0.meeting == entry.meeting && $0.name == entry.name }!
        #expect(again.stored == entry.stored)
        #expect(hex(try Data(contentsOf: storedURL)) == entry.sha256)
    }

    @Test func encryptionTransitionsUseOneStorePerKey() async throws {
        let h = try await BackupHarness()
        #expect(try await h.configure() == .succeeded)
        let plainCount = try h.latestManifest().files.count

        try await h.engine.enableEncryption(password: try BackupEngine.generatePassword())
        let key1 = await h.engine.state().keyID!
        h.advance(60)
        #expect(await h.engine.backUpNow() == .succeeded)
        let enc1 = try h.latestManifest()
        #expect(enc1.encrypted && enc1.keyID == key1 && enc1.files.count == plainCount)
        #expect(enc1.files.allSatisfy { $0.stored.hasPrefix("files-\(key1)/") })

        try await h.engine.disableEncryption()
        h.advance(60)
        #expect(await h.engine.backUpNow() == .succeeded)
        #expect(try h.latestManifest().files.allSatisfy { $0.stored.hasPrefix("files/") })

        try await h.engine.enableEncryption(password: try BackupEngine.generatePassword())
        let key2 = await h.engine.state().keyID!
        #expect(key2 != key1)
        h.advance(60)
        #expect(await h.engine.backUpNow() == .succeeded)
        #expect(try h.latestManifest().files.allSatisfy { $0.stored.hasPrefix("files-\(key2)/") })
    }

    @Test func twelveMonthsOfEncryptedSnapshotsEmptyThePlaintextStore() async throws {
        let h = try await BackupHarness(meetings: false)
        let id = ULID.generate()
        try h.writeMeetingFiles(id, variant: 5)
        #expect(try await h.configure() == .succeeded)
        #expect(FileManager.default.fileExists(atPath: h.install.appendingPathComponent("files").path))
        try await h.engine.enableEncryption(password: try BackupEngine.generatePassword())
        for month in 1...12 {
            h.advance(31 * day)
            #expect(await h.engine.tick() == .succeeded, "month \(month)")
            if month < 12 {
                #expect(FileManager.default.fileExists(atPath: h.install.appendingPathComponent("files").path))
            }
        }
        #expect(!FileManager.default.fileExists(atPath: h.install.appendingPathComponent("files").path))
        #expect(try h.manifest(h.completeSnapshots().first!).encrypted)
    }
}

// MARK: - TP4 / SC-006: interrupted run and the durability order

@Suite struct BackupDurabilityTests {
    @Test func interruptedCopyLeavesNoSnapshotAndNextRunCleans() async throws {
        let h = try await BackupHarness()
        #expect(try await h.configure() == .succeeded)
        h.advance(day)
        let meeting = try FileManager.default.contentsOfDirectory(atPath: h.meetingsDir.path).first(where: ULID.isValid)!
        try randomBytes(3 * (1 << 20)).write(to: h.meetingsDir.appendingPathComponent("\(meeting)/audio_9.m4a"))
        let written = Locked(0)
        h.failer.withLock {
            $0 = { op in
                guard case .write(let path, let bytes) = op, path.contains("/.tmp-") else { return }
                let total = written.m.withLock { $0 += bytes; return $0 }
                if total > 1_500_000 { throw POSIXError(.EIO) }
            }
        }
        #expect(await h.engine.tick() == .failed(.notWritable))
        #expect(h.completeSnapshots().count == 1)
        let entries = try FileManager.default.contentsOfDirectory(atPath: h.snapshotsDir.path)
        #expect(entries.contains { $0.hasPrefix(".partial-") })
        #expect(h.allFiles(under: h.install).contains { $0.contains("/.tmp-") })

        h.failer.withLock { $0 = nil }
        #expect(await h.engine.tick() == .succeeded)
        #expect(h.completeSnapshots().count == 2)
        let after = h.allFiles(under: h.install)
        #expect(!after.contains { $0.contains(".partial-") || $0.contains(".tmp-") })
        #expect(await h.engine.state().lastFailure == nil)
    }

    /// Every commit step is preceded by the flushes of what it vouches for.
    @Test func commitStepsFollowTheirFlushes() async throws {
        let h = try await BackupHarness()
        #expect(try await h.configure() == .succeeded)
        h.advance(day)
        let pruned = try h.plantSameDaySnapshot()
        let meeting = try FileManager.default.contentsOfDirectory(atPath: h.meetingsDir.path).first(where: ULID.isValid)!
        try randomBytes(5_000).write(to: h.meetingsDir.appendingPathComponent("\(meeting)/audio_7.m4a"))
        h.log.withLock { $0.removeAll() }
        #expect(await h.engine.tick() == .succeeded)
        let ops = h.log.withLock { $0 }
        #expect(ops.contains { if case .rename(_, let to) = $0 { return to.hasSuffix("/snapshots/.partial-" + pruned) }; return false })
        #expect(!h.completeSnapshots().contains(pruned))
        checkDurabilityOrder(ops)
    }

    /// A failed retention flush ends the run: nothing retired is deleted and GC does not run.
    @Test func failedRetentionFlushDeletesNothing() async throws {
        let h = try await BackupHarness()
        #expect(try await h.configure() == .succeeded)
        let id = try FileManager.default.contentsOfDirectory(atPath: h.meetingsDir.path).first(where: ULID.isValid)!
        let orphan = h.install.appendingPathComponent("files/\(id)/ffffffffffffffff-audio.m4a")
        try Data("orphan".utf8).write(to: orphan)
        h.advance(day)
        let planted = try h.plantSameDaySnapshot()
        let retired = Locked(false)
        h.failer.withLock {
            $0 = { op in
                if case .rename(_, let to) = op, to.hasSuffix("/snapshots/.partial-" + planted) { retired.m.withLock { $0 = true } }
                if case .flush(let p) = op, p.hasSuffix("/snapshots"), retired.m.withLock({ $0 }) { throw POSIXError(.EIO) }
            }
        }
        h.log.withLock { $0.removeAll() }
        #expect(await h.engine.tick() == .succeeded)
        #expect(retired.m.withLock { $0 })
        let ops = h.log.withLock { $0 }
        #expect(!ops.contains { if case .delete(let p) = $0 { return p.hasSuffix("/.partial-" + planted) }; return false })
        #expect(FileManager.default.fileExists(atPath: h.snapshotsDir.appendingPathComponent(".partial-" + planted).path))
        #expect(FileManager.default.fileExists(atPath: orphan.path))
        #expect(await h.engine.state().lastFailure == nil)
    }

    /// Snapshots a failed retention left retired are deleted by the next run only after a
    /// `snapshots/` flush; a failure of that flush fails the run and deletes nothing.
    @Test func inheritedRetiredSnapshotsAreFlushedBeforeDeletion() async throws {
        @Sendable func isFlushOfSnapshots(_ op: BackupFileOp) -> Bool {
            if case .flush(let p) = op { return p.hasSuffix("/snapshots") }
            return false
        }
        func isDelete(_ op: BackupFileOp, of names: [String]) -> Bool {
            if case .delete(let p) = op { return names.contains { p.hasSuffix("/.partial-" + $0) } }
            return false
        }
        // 0: retention's flush fails; 1: the second retirement rename fails;
        // 2: as 0, and the next run's cleanup flush fails too.
        for c in 0..<3 {
            let h = try await BackupHarness(meetings: false)
            try h.writeMeetingFiles(ULID.generate(), variant: 0)
            #expect(try await h.configure() == .succeeded)
            h.advance(day)
            let planted = [try h.plantSameDaySnapshot(), try h.plantSameDaySnapshot()]
            let renames = Locked(0)
            h.failer.withLock {
                $0 = { op in
                    if case .rename(_, let to) = op, to.contains("/snapshots/.partial-") {
                        let n = renames.m.withLock { $0 += 1; return $0 }
                        if c == 1 && n == 2 { throw POSIXError(.EIO) }
                    }
                    if c != 1, isFlushOfSnapshots(op), renames.m.withLock({ $0 }) == 2 { throw POSIXError(.EIO) }
                }
            }
            #expect(await h.engine.tick() == .succeeded, "case \(c)")
            func partials() throws -> Int {
                try FileManager.default.contentsOfDirectory(atPath: h.snapshotsDir.path)
                    .filter { $0.hasPrefix(".partial-") }.count
            }
            #expect(try partials() == (c == 1 ? 1 : 2), "case \(c)")

            h.log.withLock { $0.removeAll() }
            h.failer.withLock { $0 = nil }
            if c == 2 {
                h.failer.withLock { $0 = { op in if isFlushOfSnapshots(op) { throw POSIXError(.EIO) } } }
            }
            let rerun = await h.engine.backUpNow()
            let ops = h.log.withLock { $0 }
            let firstDelete = ops.firstIndex { isDelete($0, of: planted) }
            if c == 2 {
                #expect(rerun == .failed(.notWritable))
                #expect(firstDelete == nil)
                #expect(try partials() == 2)
            } else {
                #expect(rerun == .succeeded, "case \(c)")
                let firstFlush = ops.firstIndex(where: isFlushOfSnapshots)
                #expect(firstDelete != nil && firstFlush != nil && firstFlush! < firstDelete!, "case \(c)")
                #expect(!planted.contains { h.completeSnapshots().contains($0) }, "case \(c)")
                #expect(try partials() == 0, "case \(c)")
            }
        }
    }

    @Test func orderingCheckRejectsAMissingDirectoryFlush() {
        let ops: [BackupFileOp] = [
            .write("/d/s/.partial-x/manifest.json", bytes: 0), .flush("/d/s/.partial-x/manifest.json"),
            .rename(from: "/d/f/m/.tmp-1", to: "/d/f/m/abc-audio.m4a"),
            .flush("/d/s/.partial-x"), .rename(from: "/d/s/.partial-x", to: "/d/s/x"),
        ]
        #expect(!durabilityViolations(ops).isEmpty)
    }

    @Test func orderingCheckRejectsUnflushedOrInPlaceRetention() {
        let base: [BackupFileOp] = [
            .write("/d/snapshots/.partial-x/manifest.json", bytes: 0), .flush("/d/snapshots/.partial-x/manifest.json"),
            .flush("/d/snapshots/.partial-x"), .rename(from: "/d/snapshots/.partial-x", to: "/d/snapshots/x"),
            .flush("/d/snapshots"), .rename(from: "/r/.tmp-1", to: "/r/.backup-state.json"),
        ]
        let old = "/d/snapshots/2026-01-01T00-00-00Z-0000abcd"
        let retire: BackupFileOp = .rename(from: old, to: "/d/snapshots/.partial-2026-01-01T00-00-00Z-0000abcd")
        let remove: BackupFileOp = .delete("/d/snapshots/.partial-2026-01-01T00-00-00Z-0000abcd")
        #expect(durabilityViolations(base + [retire, .flush("/d/snapshots"), remove]).isEmpty)
        #expect(!durabilityViolations(base + [retire, remove]).isEmpty)
        #expect(!durabilityViolations(base + [.delete(old)]).isEmpty)
    }
}

/// Order violations in a logged run: a file renamed before its flush, a published folder whose
/// contents or new directories were not flushed first, success recorded before `snapshots/` was
/// flushed, a retention rename before the success record, a complete snapshot deleted without
/// its rename to `.partial-`, or a retired snapshot deleted before `snapshots/` was flushed.
func durabilityViolations(_ ops: [BackupFileOp]) -> [String] {
    var problems: [String] = []
    func parent(_ p: String) -> String { (p as NSString).deletingLastPathComponent }
    var lastWrite: [String: Int] = [:]
    var lastFlush: [String: Int] = [:]
    var pendingDirs: [String: Int] = [:]  // directory → index of an unflushed entry change
    var published: Int?
    var stateRecorded: Int?
    var retired: [String: Int] = [:]  // retention's `.partial-<name>` → index of its rename
    for (i, op) in ops.enumerated() {
        switch op {
        case .write(let p, _):
            lastWrite[p] = i
            pendingDirs[parent(p)] = pendingDirs[parent(p)] ?? i
        case .makeDirectory(let p):
            pendingDirs[parent(p)] = pendingDirs[parent(p)] ?? i
        case .flush(let p):
            lastFlush[p] = i
            pendingDirs[p] = nil
        case .rename(let from, let to):
            if let w = lastWrite[from], (lastFlush[from] ?? -1) < w { problems.append("rename before flush: \(from)") }
            if from.contains("/snapshots/.partial-") && !to.contains("/.partial-") {
                let unflushed = pendingDirs.filter { !$0.key.hasSuffix("/snapshots") }
                if !unflushed.isEmpty { problems.append("publish with unflushed dirs: \(unflushed.keys.sorted())") }
                for (p, w) in lastWrite where p.hasPrefix(from + "/") && (lastFlush[p] ?? -1) < w {
                    problems.append("publish before file flush: \(p)")
                }
                published = i
            } else if to.hasSuffix("/.backup-state.json"), let pub = published {
                let flushedSnapshots = lastFlush.contains { $0.key.hasSuffix("/snapshots") && $0.value > pub }
                if !flushedSnapshots { problems.append("success recorded before snapshots/ flush") }
                stateRecorded = i
            } else if to.contains("/snapshots/.partial-") {
                if stateRecorded == nil { problems.append("retention before success record") }
                retired[to] = i
            }
            pendingDirs[parent(to)] = pendingDirs[parent(to)] ?? i
            pendingDirs[parent(from)] = pendingDirs[parent(from)] ?? i
        case .delete(let p):
            if p.contains("/files") && stateRecorded == nil && published != nil { problems.append("GC before success record: \(p)") }
            if parent(p).hasSuffix("/snapshots") && BackupSnapshotName.date(of: (p as NSString).lastPathComponent) != nil {
                problems.append("complete snapshot deleted in place: \(p)")
            }
            if let r = retired[p], (lastFlush[parent(p)] ?? -1) < r { problems.append("retired snapshot deleted before its rename was flushed: \(p)") }
        case .stage:
            break
        }
    }
    if published == nil { problems.append("no publish") }
    return problems
}

func checkDurabilityOrder(_ ops: [BackupFileOp]) {
    let problems = durabilityViolations(ops)
    #expect(problems.isEmpty, "\(problems)")
}

// MARK: - TP6 / SC-004: retention and GC

@Suite struct BackupRetentionTests {
    /// 18 months of dailies at 02:00 local time (UTC+9, so the UTC date differs); now = 30/06/2026 12:00 local.
    @Test func eighteenMonthsOfDailiesKeepTheRuleSet() {
        let tz = TimeZone(identifier: "Asia/Tokyo")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 2) -> Date {
            cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
        }
        var names: [String] = []
        var byDay: [String: String] = [:]
        var date = at(2025, 1, 1)
        while date <= at(2026, 6, 30) {
            let name = BackupSnapshotName.make(date)
            names.append(name)
            let c = cal.dateComponents([.year, .month, .day], from: date)
            byDay[String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)] = name
            date = cal.date(byAdding: .day, value: 1, to: date)!
        }
        let future = BackupSnapshotName.make(at(2026, 7, 5))
        names.append(future)
        let now = at(2026, 6, 30, 12)

        let expectedDays = [
            // 7 most recent days
            "2026-06-24", "2026-06-25", "2026-06-26", "2026-06-27", "2026-06-28", "2026-06-29", "2026-06-30",
            // newest of ISO weeks 23-26 (week 27's is 30/06, week 26's is 28/06)
            "2026-06-07", "2026-06-14", "2026-06-21",
            // newest of the 12 most recent months (June is 30/06)
            "2026-05-31", "2026-04-30", "2026-03-31", "2026-02-28", "2026-01-31",
            "2025-12-31", "2025-11-30", "2025-10-31", "2025-09-30", "2025-08-31", "2025-07-31",
        ]
        let kept = BackupRetention.kept(names, now: now, timeZone: tz)
        #expect(kept == Set(expectedDays.map { byDay[$0]! } + [future]))
        #expect(kept.count == 22)

        // A snapshot just published at `now` survives even with a future-dated one present.
        let justPublished = BackupSnapshotName.make(now)
        #expect(BackupRetention.kept(names + [justPublished], now: now, timeZone: tz).contains(justPublished))
        #expect(BackupRetention.kept(names, now: now, timeZone: tz).isSuperset(of: [future]))
    }

    @Test func nonSnapshotNamesAreIgnored() {
        let kept = BackupRetention.kept(["notes", ".partial-2026-01-01T00-00-00Z-aaaaaaaa", "2026-01-01T00-00-00Z-XYZ"], now: Date(), timeZone: utc)
        #expect(kept.isEmpty)
    }

    @Test func pruneAndGarbageCollection() async throws {
        let h = try await BackupHarness(meetings: false)
        let id = ULID.generate()
        try h.writeMeetingFiles(id, variant: 0)
        #expect(try await h.configure() == .succeeded)

        // Another install's snapshots and files are never touched.
        let other = h.dest.appendingPathComponent("Blaise Backups/fedcba9876543210")
        let otherSnap = other.appendingPathComponent("snapshots/2020-01-01T00-00-00Z-00000000")
        try FileManager.default.createDirectory(at: otherSnap, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: otherSnap.appendingPathComponent("manifest.json"))
        try FileManager.default.createDirectory(at: other.appendingPathComponent("files/\(id)"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: other.appendingPathComponent("files/\(id)/0000000000000000-audio.m4a"))

        // A planted symlink in the store pointing outside, and an unreferenced file.
        let outside = try makeTempRoot().appendingPathComponent("target.bin")
        try Data("keep me".utf8).write(to: outside)
        let storeDir = h.install.appendingPathComponent("files/\(id)")
        try FileManager.default.createSymbolicLink(at: storeDir.appendingPathComponent("link-audio.m4a"), withDestinationURL: outside)
        let orphan = storeDir.appendingPathComponent("ffffffffffffffff-audio.m4a")
        try Data("orphan".utf8).write(to: orphan)

        // A future-dated snapshot (clock ran ahead) is kept.
        let futureName = BackupSnapshotName.make(h.clock.withLock { $0 } + 400 * day)
        try FileManager.default.copyItem(
            at: h.snapshotsDir.appendingPathComponent(h.completeSnapshots()[0]),
            to: h.snapshotsDir.appendingPathComponent(futureName))

        // One unreadable manifest: GC deletes nothing.
        h.advance(day)
        let first = h.completeSnapshots().first { $0 != futureName }!
        let brokenCopy = BackupSnapshotName.make(h.clock.withLock { $0 } - 2 * day)
        try FileManager.default.createDirectory(at: h.snapshotsDir.appendingPathComponent(brokenCopy), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: h.snapshotsDir.appendingPathComponent("\(brokenCopy)/manifest.json"))
        #expect(await h.engine.tick() == .succeeded)
        #expect(FileManager.default.fileExists(atPath: orphan.path))

        // Readable again: the orphan goes, the link and its target stay, other install untouched.
        try FileManager.default.removeItem(at: h.snapshotsDir.appendingPathComponent(brokenCopy))
        h.advance(day)
        #expect(await h.engine.tick() == .succeeded)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: storeDir.appendingPathComponent("link-audio.m4a").path)) != nil)
        #expect(try Data(contentsOf: outside) == Data("keep me".utf8))
        #expect(FileManager.default.fileExists(atPath: otherSnap.appendingPathComponent("manifest.json").path))
        #expect(FileManager.default.fileExists(atPath: other.appendingPathComponent("files/\(id)/0000000000000000-audio.m4a").path))
        #expect(h.completeSnapshots().contains(futureName))
        #expect(h.completeSnapshots().contains(first))

        // Every file left in this install's store is referenced.
        var refs = Set<String>()
        for name in h.completeSnapshots() { refs.formUnion(try h.manifest(name).files.map(\.stored)) }
        for file in h.allFiles(under: h.install.appendingPathComponent("files")) where !file.hasSuffix("link-audio.m4a") {
            #expect(refs.contains("files/" + file), "unreferenced \(file)")
        }
    }

    /// A link planted at any namespace folder is never followed: the run fails `notWritable`
    /// and the folder it points at is left exactly as it was.
    @Test func plantedNamespaceLinksAreNeverFollowed() async throws {
        let ulid = ULID.generate()
        // (where the link sits under `Blaise Backups`, what the run would touch below it)
        let spots: [(link: String, sentinel: String)] = [
            ("", "\(testInstallID)/snapshots/.partial-2020-01-01T00-00-00Z-00000000/keep.txt"),
            (testInstallID, "snapshots/.partial-2020-01-01T00-00-00Z-00000000/keep.txt"),
            ("\(testInstallID)/snapshots", ".partial-2020-01-01T00-00-00Z-00000000/keep.txt"),
            ("\(testInstallID)/files", "\(ulid)/.tmp-keep"),
            ("\(testInstallID)/files/\(ulid)", ".tmp-keep"),
        ]
        for spot in spots {
            let h = try await BackupHarness(meetings: false)
            try h.writeMeetingFiles(ulid, variant: 0)
            let backups = h.dest.appendingPathComponent("Blaise Backups")
            let link = spot.link.isEmpty ? backups : backups.appendingPathComponent(spot.link)
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            let outside = try makeTempRoot()
            let sentinel = outside.appendingPathComponent(spot.sentinel)
            try FileManager.default.createDirectory(at: sentinel.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("Quoll Harbor".utf8).write(to: sentinel)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            let before = h.allFiles(under: outside)

            #expect(try await h.configure() == .failed(.notWritable), "link at \(spot.link)")
            #expect(h.allFiles(under: outside) == before, "link at \(spot.link)")
            #expect((try? Data(contentsOf: sentinel)) == Data("Quoll Harbor".utf8), "link at \(spot.link)")
            #expect(await h.engine.state().lastFailure?.reason == .notWritable)
        }
    }

    /// A store meeting folder that became a link after a successful run is not vouched for by
    /// reuse: the next run fails `notWritable`, publishes nothing and leaves the folder as it was.
    @Test func storeMeetingFolderLinkedAfterARunIsNotReused() async throws {
        let h = try await BackupHarness(meetings: false)
        let ulid = ULID.generate()
        try h.writeMeetingFiles(ulid, variant: 0)
        #expect(try await h.configure() == .succeeded)
        let folder = h.install.appendingPathComponent("files/\(ulid)")
        let outside = try makeTempRoot().appendingPathComponent(ulid)
        try FileManager.default.moveItem(at: folder, to: outside)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: outside)
        let before = h.allFiles(under: outside)
        h.advance(day)
        #expect(await h.engine.tick() == .failed(.notWritable))
        #expect(h.completeSnapshots().count == 1)
        #expect(h.allFiles(under: outside) == before)
    }

    /// A `snapshots` link that appears after the publish is not pruned through.
    @Test func linkPlantedBeforeRetentionIsNotFollowed() async throws {
        let h = try await BackupHarness(meetings: false)
        try h.writeMeetingFiles(ULID.generate(), variant: 0)
        #expect(try await h.configure() == .succeeded)
        h.advance(day)
        let outside = try makeTempRoot()
        // Two of the same day: retention through the link would drop the older one.
        let names = [120.0, 60.0].map { BackupSnapshotName.make(h.clock.withLock { $0 } - $0) }
        for name in names {
            try FileManager.default.createDirectory(at: outside.appendingPathComponent(name), withIntermediateDirectories: true)
            try Data("Quoll Harbor".utf8).write(to: outside.appendingPathComponent("\(name)/manifest.json"))
        }
        let aside = try makeTempRoot().appendingPathComponent("snapshots")
        let snapshots = h.snapshotsDir
        let swapped = Locked(false)
        h.failer.withLock {
            $0 = { op in
                guard case .rename(_, let to) = op, to.hasSuffix("/.backup-state.json"),
                    !swapped.m.withLock({ $0 }) else { return }
                swapped.m.withLock { $0 = true }
                try FileManager.default.moveItem(at: snapshots, to: aside)
                try FileManager.default.createSymbolicLink(at: snapshots, withDestinationURL: outside)
            }
        }
        #expect(await h.engine.tick() == .succeeded)
        #expect(swapped.m.withLock { $0 })
        #expect(Set(h.allFiles(under: outside)) == Set(names.map { "\($0)/manifest.json" }))
    }

    @Test func runsPruneOldSnapshots() async throws {
        let h = try await BackupHarness(meetings: false)
        try h.writeMeetingFiles(ULID.generate(), variant: 0)
        #expect(try await h.configure() == .succeeded)
        for _ in 0..<9 {
            h.advance(day)
            #expect(await h.engine.tick() == .succeeded)
        }
        let names = h.completeSnapshots()
        #expect(names.count == BackupRetention.kept(names, now: h.clock.withLock { $0 }, timeZone: utc).count)
        #expect(names.count < 10)
        let entries = try FileManager.default.contentsOfDirectory(atPath: h.snapshotsDir.path)
        #expect(!entries.contains { $0.hasPrefix(".partial-") })
    }
}

// MARK: - TP8 (write side) / SC-007: encryption

private func unpaddedAEASize(_ data: Data, password: String) throws -> Int64 {
    let url = try makeTempRoot().appendingPathComponent("x.aea")
    let out = ArchiveByteStream.fileStream(
        path: FilePath(url.path), mode: .writeOnly, options: [.create, .truncate], permissions: [.ownerReadWrite])!
    let context = ArchiveEncryptionContext(profile: .hkdf_sha256_aesctr_hmac__scrypt__none, compressionAlgorithm: .none)
    context.paddingSize = 0
    try context.setPassword(password)
    let enc = ArchiveByteStream.encryptionStream(writingTo: out, encryptionContext: context)!
    _ = try data.withUnsafeBytes { try enc.write(from: $0) }
    try enc.close()
    try out.close()
    return (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber).int64Value
}

@Suite struct BackupEncryptionTests {
    @Test func generatedPasswordShape() throws {
        let pw = try BackupEngine.generatePassword()
        let groups = pw.split(separator: "-")
        #expect(pw.count == 35 && groups.count == 6)
        #expect(groups.allSatisfy { $0.count == 5 && $0.allSatisfy(\.isNumber) })
    }

    @Test func encryptedRunWritesOnlyAEAAndRoundTrips() async throws {
        let h = try await BackupHarness()
        let pw = try BackupEngine.generatePassword()
        try await h.engine.enableEncryption(password: pw)
        #expect(try await h.configure() == .succeeded)
        let keyID = await h.engine.state().keyID!
        let m = try h.latestManifest()
        #expect(m.encrypted && m.keyID == keyID && m.data.file == "data.aea")
        #expect(m.files.allSatisfy { $0.stored.hasPrefix("files-\(keyID)/") && $0.stored.hasSuffix(".aea") })
        // Stored size equals an unpadded AEA of the same plaintext (the default pads).
        for f in m.files.prefix(5) {
            let source = try Data(contentsOf: h.meetingsDir.appendingPathComponent("\(f.meeting)/\(f.name)"))
            #expect(f.storedSize == (try unpaddedAEASize(source, password: pw)), "\(f.name)")
        }

        for file in h.allFiles(under: h.dest) {
            let url = h.dest.appendingPathComponent(file)
            if url.lastPathComponent == "manifest.json" { continue }
            #expect(url.pathExtension == "aea", "\(file)")
            #expect(try Data(contentsOf: url).prefix(4) == Data("AEA1".utf8), "\(file)")
        }

        let scratch = try makeTempRoot()
        let entry = m.files.first { $0.name == "audio.m4a" }!
        let out = scratch.appendingPathComponent("audio.m4a")
        let (rc, msg) = try run("/usr/bin/aea", ["decrypt", "-password-value", pw,
                                                 "-i", h.install.appendingPathComponent(entry.stored).path, "-o", out.path])
        #expect(rc == 0, "\(msg)")
        #expect(try Data(contentsOf: out) == Data(contentsOf: h.meetingsDir.appendingPathComponent("\(entry.meeting)/audio.m4a")))

        let dataURL = h.snapshotsDir.appendingPathComponent("\(h.completeSnapshots()[0])/data.aea")
        #expect(hex(try Data(contentsOf: dataURL)) == m.data.sha256)
        let aar = scratch.appendingPathComponent("data.aar")
        #expect(try run("/usr/bin/aea", ["decrypt", "-password-value", pw, "-i", dataURL.path, "-o", aar.path]).0 == 0)
        let extracted = scratch.appendingPathComponent("x")
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        #expect(try run("/usr/bin/aa", ["extract", "-i", aar.path, "-d", extracted.path]).0 == 0)
        #expect(try Data(contentsOf: extracted.appendingPathComponent("Glossary.md")) == Data(contentsOf: h.database.paths.glossaryURL))
        let queue = try DatabaseQueue(path: extracted.appendingPathComponent("blaise.sqlite").path)
        #expect(try await queue.read { try String.fetchAll($0, sql: "PRAGMA quick_check") } == ["ok"])
        let live = try await h.database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM meeting") }
        let archived = try await queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM meeting") }
        #expect(archived == live && archived == m.meetingCount && (live ?? 0) > 0)

        // A wrong password does not open it.
        #expect(try run("/usr/bin/aea", ["decrypt", "-password-value", String(repeating: "7", count: 35),
                                         "-i", dataURL.path, "-o", scratch.appendingPathComponent("bad").path]).0 != 0)
    }

    /// A failed state write while turning encryption on again keeps the old password with the
    /// old key, so the next snapshot opens with one password.
    @Test func failedStateWriteKeepsThePasswordWithItsKey() async throws {
        let h = try await BackupHarness()
        let pw1 = try BackupEngine.generatePassword()
        try await h.engine.enableEncryption(password: pw1)
        #expect(try await h.configure() == .succeeded)
        let key1 = await h.engine.state().keyID!

        h.failer.withLock {
            $0 = { if case .rename(_, let to) = $0, to.hasSuffix("/.backup-state.json") { throw POSIXError(.ENOSPC) } }
        }
        await #expect(throws: (any Error).self) { try await h.engine.enableEncryption(password: try BackupEngine.generatePassword()) }
        h.failer.withLock { $0 = nil }
        #expect(try h.secrets.get(key: BackupEngine.passwordKey) == pw1)
        #expect(await h.engine.state().keyID == key1)

        h.advance(day)
        #expect(await h.engine.tick() == .succeeded)
        let m = try h.latestManifest()
        #expect(m.keyID == key1)
        let scratch = try makeTempRoot()
        let dataURL = h.snapshotsDir.appendingPathComponent("\(h.completeSnapshots().last!)/data.aea")
        #expect(try run("/usr/bin/aea", ["decrypt", "-password-value", pw1, "-i", dataURL.path,
                                         "-o", scratch.appendingPathComponent("d").path]).0 == 0)
        let stored = h.install.appendingPathComponent(m.files.first { $0.name == "audio.m4a" }!.stored)
        #expect(try run("/usr/bin/aea", ["decrypt", "-password-value", pw1, "-i", stored.path,
                                         "-o", scratch.appendingPathComponent("f").path]).0 == 0)

        // With no earlier password, a failed write leaves none.
        let fresh = try await BackupHarness(meetings: false)
        fresh.failer.withLock {
            $0 = { if case .rename(_, let to) = $0, to.hasSuffix("/.backup-state.json") { throw POSIXError(.ENOSPC) } }
        }
        await #expect(throws: (any Error).self) { try await fresh.engine.enableEncryption(password: pw1) }
        #expect(try fresh.secrets.get(key: BackupEngine.passwordKey) == nil)
    }

    /// A flush that fails after the state file was replaced leaves the new key and the new
    /// password together, with and without an earlier password, and also when the state file
    /// cannot be read back during the recovery.
    @Test func failedFlushAfterTheStateReplaceKeepsTheNewPassword() async throws {
        for (hadPassword, unreadable) in [(true, false), (false, false), (true, true), (false, true)] {
            let h = try await BackupHarness()
            if hadPassword {
                try await h.engine.enableEncryption(password: try BackupEngine.generatePassword())
                #expect(try await h.configure() == .succeeded)
            }
            let before = await h.engine.state().keyID
            let replaced = Locked<String?>(nil)
            h.failer.withLock {
                $0 = { op in
                    if case .rename(_, let to) = op, to.hasSuffix("/.backup-state.json") { replaced.m.withLock { $0 = to } }
                    if case .flush = op, let state = replaced.m.withLock({ $0 }) {
                        if unreadable { chmod(state, 0) }
                        throw POSIXError(.EIO)
                    }
                }
            }
            let pw2 = try BackupEngine.generatePassword()
            try await h.engine.enableEncryption(password: pw2)
            h.failer.withLock { $0 = nil }
            if let state = replaced.m.withLock({ $0 }) { chmod(state, 0o644) }
            let label = "had password: \(hadPassword), unreadable: \(unreadable)"
            let key2 = await h.engine.state().keyID
            #expect(key2 != nil && key2 != before, "\(label)")
            #expect(try h.secrets.get(key: BackupEngine.passwordKey) == pw2, "\(label)")

            if hadPassword {
                h.advance(day)
                #expect(await h.engine.tick() == .succeeded)
            } else {
                #expect(try await h.configure() == .succeeded)
            }
            let latest = try #require(h.completeSnapshots().last)
            #expect(try h.manifest(latest).keyID == key2)
            let scratch = try makeTempRoot()
            let dataURL = h.snapshotsDir.appendingPathComponent("\(latest)/data.aea")
            #expect(try run("/usr/bin/aea", ["decrypt", "-password-value", pw2, "-i", dataURL.path,
                                             "-o", scratch.appendingPathComponent("d").path]).0 == 0)
        }
    }

    /// Fails the first state write: at its rename (before the replace) or at the flush after it.
    private func failFirstStateWrite(_ h: BackupHarness, afterReplace: Bool) {
        let replaced = Locked(false), done = Locked(false)
        h.failer.withLock {
            $0 = { op in
                guard !done.m.withLock({ $0 }) else { return }
                if case .rename(_, let to) = op, to.hasSuffix("/.backup-state.json") {
                    if !afterReplace { done.m.withLock { $0 = true }; throw POSIXError(.ENOSPC) }
                    replaced.m.withLock { $0 = true }
                }
                if case .flush = op, replaced.m.withLock({ $0 }) {
                    done.m.withLock { $0 = true }
                    throw POSIXError(.EIO)
                }
            }
        }
    }

    /// Turning encryption off: a failed flush after the state replace is not a failure (the
    /// change is in force); a failure before the replace throws and changes nothing.
    @Test func disableEncryptionFlushFailureAfterTheReplaceIsDone() async throws {
        let h = try await BackupHarness()
        try await h.engine.enableEncryption(password: try BackupEngine.generatePassword())
        #expect(try await h.configure() == .succeeded)

        failFirstStateWrite(h, afterReplace: false)
        await #expect(throws: (any Error).self) { try await h.engine.disableEncryption() }
        #expect(await h.engine.state().isEncrypted)

        failFirstStateWrite(h, afterReplace: true)
        try await h.engine.disableEncryption()
        h.failer.withLock { $0 = nil }
        #expect(await !h.engine.state().isEncrypted)
    }

    /// Choosing a folder: a failed flush after the state replace is not a failure (the folder is
    /// stored and the run starts); a failure before the replace throws and changes nothing.
    @Test func chooseFolderFlushFailureAfterTheReplaceIsDone() async throws {
        let h = try await BackupHarness()
        #expect(try await h.configure() == .succeeded)
        let before = await h.engine.state().destinationBookmark
        let other = try makeTempRoot()

        failFirstStateWrite(h, afterReplace: false)
        await #expect(throws: (any Error).self) { try await h.engine.chooseFolder(other) }
        #expect(await h.engine.state().destinationBookmark == before)

        failFirstStateWrite(h, afterReplace: true)
        h.advance(day)
        #expect(try await h.engine.chooseFolder(other) == .succeeded)
        h.failer.withLock { $0 = nil }
        let after = await h.engine.state().destinationBookmark
        #expect(after != nil && after != before)
        #expect(FileManager.default.fileExists(atPath: other.appendingPathComponent("Blaise Backups").path))
    }

    /// An interrupted encrypted run leaves temp files with no plaintext in them.
    @Test func interruptedEncryptedTempHoldsNoPlaintext() async throws {
        let h = try await BackupHarness(meetings: false)
        let id = ULID.generate()
        try h.writeMeetingFiles(id, variant: 0)
        let plain = randomBytes(3 * (1 << 20))
        try plain.write(to: h.meetingsDir.appendingPathComponent("\(id)/audio_5.m4a"))
        try await h.engine.enableEncryption(password: try BackupEngine.generatePassword())
        let written = Locked(0)
        h.failer.withLock {
            $0 = { op in
                guard case .write(let path, let bytes) = op, path.contains("/.tmp-") else { return }
                if written.m.withLock({ $0 += bytes; return $0 }) > 1_500_000 { throw POSIXError(.EIO) }
            }
        }
        #expect(try await h.configure() == .failed(.notWritable))
        let temps = h.allFiles(under: h.install).filter { $0.contains(".tmp-") }
        #expect(!temps.isEmpty)
        let probe = plain.subdata(in: 1_000_000..<1_000_064)
        for t in temps {
            let bytes = try Data(contentsOf: h.install.appendingPathComponent(t))
            #expect(bytes.range(of: probe) == nil)
            #expect(bytes.prefix(4) == Data("AEA1".utf8) || bytes.prefix(4) == Data(count: 4))
        }
        for file in h.allFiles(under: h.dest) where !file.contains(".tmp-") && !file.hasSuffix("manifest.json") {
            #expect(try Data(contentsOf: h.dest.appendingPathComponent(file)).prefix(4) == Data("AEA1".utf8), "\(file)")
        }
    }
}

// MARK: - TP9 / SC-005: failure reasons and the 7-day line

@Suite struct BackupFailureTests {
    @Test func reasonWording() {
        let expected: [BackupFailureReason: String] = [
            .notConnected: "drive not connected", .notWritable: "folder not writable",
            .full: "destination full", .localDiskFull: "this Mac's disk is full",
            .localError: "could not read the library on this Mac", .databaseCheck: "database check failed",
            .passwordUnavailable: "encryption password missing — turn Encrypt backups off and on again",
        ]
        #expect(Set(expected.keys) == Set(BackupFailureReason.allCases))
        for (reason, text) in expected { #expect(reason.statusText == text) }
    }

    @Test func staleLineAcrossTheBoundary() {
        let t0 = Date(timeIntervalSince1970: 1_772_000_000)
        var s = BackupState()
        s.destinationBookmark = Data([1])
        s.configuredAt = t0
        #expect(s.staleLine(now: t0 + 7 * day - 1) == nil)
        #expect(s.staleLine(now: t0 + 7 * day) == "No backup yet")
        s.lastFailure = .init(reason: .notConnected, at: t0)
        #expect(s.staleLine(now: t0 + 7 * day) == "No backup yet — drive not connected")
        s.lastSuccessAt = t0 + day
        #expect(s.staleLine(now: t0 + 8 * day - 1) == nil)
        #expect(s.staleLine(now: t0 + 10 * day) == "Last backup 9 days ago — drive not connected")
        s.lastFailure = nil
        #expect(s.staleLine(now: t0 + 10 * day) == "Last backup 9 days ago")
        #expect(s.staleLine(now: t0 - 8 * day) == "Last backup 9 days ago")  // absolute age
        #expect(BackupState().staleLine(now: t0 + 100 * day) == nil)
    }

    @Test func removedFolderIsNotConnectedAndWritesNothing() async throws {
        let h = try await BackupHarness()
        #expect(try await h.configure() == .succeeded)
        let success = await h.engine.state().lastSuccessAt
        try FileManager.default.removeItem(at: h.dest)
        h.advance(day)
        #expect(await h.engine.tick() == .failed(.notConnected))
        #expect(!FileManager.default.fileExists(atPath: h.dest.path))
        let state = await h.engine.state()
        #expect(state.lastSuccessAt == success && state.lastFailure?.reason == .notConnected)
        h.advance(6 * day)
        _ = await h.engine.tick()
        #expect(await h.engine.state().staleLine(now: h.clock.withLock { $0 }) == "Last backup 7 days ago — drive not connected")
    }

    @Test func missingPasswordFailsBeforeWriting() async throws {
        let h = try await BackupHarness()
        try await h.engine.enableEncryption(password: try BackupEngine.generatePassword())
        try h.secrets.delete(key: BackupEngine.passwordKey)
        #expect(try await h.configure() == .failed(.passwordUnavailable))
        #expect(h.allFiles(under: h.dest).isEmpty)
        #expect(await h.engine.state().lastFailure?.reason == .passwordUnavailable)
    }

    /// The run's password read never asks for UI; a read that would need it is `passwordUnavailable`.
    @Test func passwordReadNeverAsksForUI() async throws {
        final class NoUIStore: SecretStore, @unchecked Sendable {
            let inner = InMemorySecretStore()
            let interactiveReads = Mutex(0)
            func get(key: String) throws -> String? {
                interactiveReads.withLock { $0 += 1 }
                return try inner.get(key: key)
            }
            func getWithoutUI(key: String) throws -> String? {
                throw SecretStoreError(status: errSecInteractionNotAllowed, operation: "get")
            }
            func set(key: String, value: String) throws { try inner.set(key: key, value: value) }
            func delete(key: String) throws { try inner.delete(key: key) }
        }
        let h = try await BackupHarness()
        let store = NoUIStore()
        let engine = BackupEngine(
            database: h.database, secrets: store, isRecording: { false },
            now: { h.clock.withLock { $0 } }, timeZone: { utc }, installID: testInstallID)
        try await engine.enableEncryption(password: try BackupEngine.generatePassword())
        store.interactiveReads.withLock { $0 = 0 }
        #expect(try await engine.chooseFolder(h.dest) == .failed(.passwordUnavailable))
        #expect(store.interactiveReads.withLock { $0 } == 0)
        #expect(h.allFiles(under: h.dest).isEmpty)
    }

    @Test func injectedErrnosMapToReasons() async throws {
        let cases: [(BackupFailureReason, @Sendable (BackupFileOp) throws -> Void)] = [
            (.full, { if case .write(let p, _) = $0, p.contains("/files/") { throw POSIXError(.ENOSPC) } }),
            (.full, { if case .write(let p, _) = $0, p.hasSuffix("data.aar") { throw POSIXError(.EDQUOT) } }),
            (.notWritable, { if case .makeDirectory(let p) = $0, p.hasSuffix("Blaise Backups") { throw POSIXError(.EACCES) } }),
            (.localDiskFull, { if case .stage = $0 { throw POSIXError(.ENOSPC) } }),
            (.localError, { if case .stage(let p) = $0, p.hasSuffix("Glossary.md") { throw POSIXError(.EIO) } }),
        ]
        for (reason, failer) in cases {
            let h = try await BackupHarness()
            h.failer.withLock { $0 = failer }
            #expect(try await h.configure() == .failed(reason))
            #expect(h.completeSnapshots().isEmpty)
            #expect(await h.engine.state().lastFailure?.reason == reason)
        }
    }

    @Test func unreadableMeetingFolderIsLocalError() async throws {
        let h = try await BackupHarness()
        let meeting = try FileManager.default.contentsOfDirectory(atPath: h.meetingsDir.path).first(where: ULID.isValid)!
        let dir = h.meetingsDir.appendingPathComponent(meeting)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        #expect(try await h.configure() == .failed(.localError))
    }

    /// A meeting file listed but then unreadable (not gone) fails the run instead of being left out.
    @Test func unreadableListedFileFailsTheRun() async throws {
        let h = try await BackupHarness()
        let first = try FileManager.default.contentsOfDirectory(atPath: h.meetingsDir.path).filter(ULID.isValid).sorted()[0]
        let dir = h.meetingsDir.appendingPathComponent(first)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        // Check 2 is right before the first file's metadata read, after its folder was listed.
        h.trigger.withLock {
            $0 = (2, { try? FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: dir.path) })
        }
        #expect(try await h.configure() == .failed(.localError))
        #expect(h.completeSnapshots().isEmpty)
        let state = await h.engine.state()
        #expect(state.lastSuccessAt == nil && state.lastFailure?.reason == .localError)
    }

    @Test func failuresAfterThePublishRenameKeepTheSnapshot() async throws {
        let published = Locked(false)
        let failers: [@Sendable (BackupFileOp) throws -> Void] = [
            { op in
                if case .rename(let from, let to) = op, from.contains("/.partial-"), !to.contains("/.partial-") {
                    published.m.withLock { $0 = true }
                }
                if case .flush(let p) = op, p.hasSuffix("/snapshots"), published.m.withLock({ $0 }) { throw POSIXError(.EIO) }
            },
            { if case .rename(_, let to) = $0, to.hasSuffix("/.backup-state.json") { throw POSIXError(.EIO) } },
            { if case .delete(let p) = $0, p.contains("/files/") { throw POSIXError(.EIO) } },
        ]
        for (i, failer) in failers.enumerated() {
            let h = try await BackupHarness()
            #expect(try await h.configure() == .succeeded)
            let before = await h.engine.state()
            let id = try FileManager.default.contentsOfDirectory(atPath: h.meetingsDir.path).first(where: ULID.isValid)!
            let orphan = h.install.appendingPathComponent("files/\(id)/ffffffffffffffff-audio.m4a")
            try Data("orphan".utf8).write(to: orphan)
            h.advance(day)
            _ = try h.plantSameDaySnapshot()  // retention would drop it
            h.failer.withLock { $0 = failer }
            #expect(await h.engine.tick() == .succeeded, "case \(i)")
            // A failed flush or state write ends the run: no retention, no GC.
            #expect(h.completeSnapshots().count == (i == 2 ? 2 : 3), "case \(i)")
            #expect(FileManager.default.fileExists(atPath: orphan.path), "case \(i)")
            let after = await h.engine.state()
            #expect(after.lastFailure == nil, "case \(i)")
            if i == 1 { #expect(after.lastSuccessAt == before.lastSuccessAt) }
        }
    }

    /// Failures after the publish and failed state writes are logged with their reason and errno.
    @Test func laterFailuresAreLoggedWithTheirReason() async throws {
        let started = Date()
        let h = try await BackupHarness()
        #expect(try await h.configure() == .succeeded)
        h.advance(day)
        let published = Locked(false)
        h.failer.withLock {
            $0 = { op in
                if case .rename(let from, let to) = op, from.contains("/.partial-"), !to.contains("/.partial-") {
                    published.m.withLock { $0 = true }
                }
                if case .flush(let p) = op, p.hasSuffix("/snapshots"), published.m.withLock({ $0 }) { throw POSIXError(.EIO) }
            }
        }
        #expect(await h.engine.tick() == .succeeded)
        h.failer.withLock {
            $0 = { op in
                if case .makeDirectory(let p) = op, p.hasSuffix("Blaise Backups") { throw POSIXError(.EACCES) }
                if case .rename(_, let to) = op, to.hasSuffix("/.backup-state.json") { throw POSIXError(.EIO) }
            }
        }
        try FileManager.default.removeItem(at: h.dest.appendingPathComponent("Blaise Backups"))
        #expect(await h.engine.backUpNow() == .failed(.notWritable))

        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let messages = try store.getEntries(
            at: store.position(date: started),
            matching: NSPredicate(format: "subsystem == %@ AND category == %@", BlaiseBundle.identifier, "backup")
        ).compactMap { ($0 as? OSLogEntryLog)?.composedMessage }
        #expect(messages.contains { $0.contains("post-publish step failed: notWritable (flush errno 5)") }, "\(messages)")
        #expect(messages.contains { $0.contains("state write failed: localError (rename errno 5)") }, "\(messages)")
    }

    @Test func fileRemovedBeforeItsCopyIsSkipped() async throws {
        let h = try await BackupHarness()
        let first = try FileManager.default.contentsOfDirectory(atPath: h.meetingsDir.path).filter(ULID.isValid).sorted()[0]
        let dir = h.meetingsDir.appendingPathComponent(first)
        h.trigger.withLock {
            $0 = (2, {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent("audio.m4a"))
                try? FileManager.default.removeItem(at: dir.appendingPathComponent("capture_facts.json"))
            })
        }
        #expect(try await h.configure() == .succeeded)
        let names = try h.latestManifest().files.filter { $0.meeting == first }.map(\.name)
        #expect(!names.contains("audio.m4a") && !names.contains("capture_facts.json"))
        #expect(names.contains("diarization.json"))
    }
}

// MARK: - TP12: scheduling and exclusion

@Suite struct BackupSchedulingTests {
    @Test func dueRule() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        let t = Date(timeIntervalSince1970: 1_772_000_000)
        var s = BackupState()
        #expect(!s.isDue(now: t, calendar: cal))
        s.destinationBookmark = Data([1])
        #expect(s.isDue(now: t, calendar: cal))
        s.lastSuccessAt = t
        #expect(!s.isDue(now: t + 3600, calendar: cal))
        #expect(s.isDue(now: t + day, calendar: cal))
        #expect(s.isDue(now: t - day, calendar: cal))
    }

    /// A time-zone change while the app runs moves the local date for the due rule and retention.
    @Test func dueRuleAndRetentionFollowTheCurrentZone() async throws {
        let phoenix = TimeZone(identifier: "America/Phoenix")!  // UTC-7: 06:13Z is 23:13 the day before
        let h = try await BackupHarness(meetings: false)
        try h.writeMeetingFiles(ULID.generate(), variant: 0)
        #expect(try await h.configure() == .succeeded)
        h.advance(3600)
        #expect(await h.engine.tick() == .notDue)
        h.zone.withLock { $0 = phoenix }
        #expect(await h.engine.tick() == .succeeded)
        #expect(h.completeSnapshots().count == 2)  // two local days now: both kept

        let r = try await BackupHarness(meetings: false)
        try r.writeMeetingFiles(ULID.generate(), variant: 0)
        #expect(try await r.configure() == .succeeded)
        r.advance(3600)
        r.zone.withLock { $0 = phoenix }
        #expect(await r.engine.backUpNow() == .succeeded)
        #expect(r.completeSnapshots().count == 2)
    }

    @Test func noRunWhileRecording() async throws {
        let h = try await BackupHarness()
        h.recording.withLock { $0 = true }
        #expect(try await h.configure() == .recording)
        #expect(await h.engine.backUpNow() == .recording)
        #expect(h.completeSnapshots().isEmpty)
    }

    @Test func recordingMidRunStopsBeforeNextFileAsNonFailure() async throws {
        let h = try await BackupHarness()
        h.trigger.withLock { $0 = (3, { h.recording.withLock { $0 = true } }) }
        #expect(try await h.configure() == .interrupted)
        #expect(h.completeSnapshots().isEmpty)
        let state = await h.engine.state()
        #expect(state.lastFailure == nil && state.lastSuccessAt == nil)
        // Check 1 is at entry, check 2 before the first file; check 3 flips, so only one file was stored.
        let stored = h.allFiles(under: h.install.appendingPathComponent("files")).filter { !$0.contains(".tmp-") }
        #expect(stored.count == 1)
        #expect(h.recordingChecks.withLock { $0 } == 3)

        h.recording.withLock { $0 = false }
        #expect(await h.engine.tick() == .succeeded)
    }

    @Test func secondCallWhileBusyReturnsAtOnce() async throws {
        let h = try await BackupHarness()
        let inner = Locked<BackupEngine.RunOutcome?>(nil)
        h.trigger.withLock { $0 = (2, { let r = await h.engine.backUpNow(); inner.m.withLock { $0 = r } }) }
        #expect(try await h.configure() == .succeeded)
        #expect(inner.m.withLock { $0 } == .busy)
        #expect(await h.engine.isBusy == false)
    }

    @Test func encryptionTurnedOnMidRunAppliesToTheNextRun() async throws {
        let h = try await BackupHarness()
        h.trigger.withLock { $0 = (2, { try? await h.engine.enableEncryption(password: "11111-22222-33333-44444-55555-66666") }) }
        #expect(try await h.configure() == .succeeded)
        let m = try h.latestManifest()
        #expect(!m.encrypted && m.files.allSatisfy { $0.stored.hasPrefix("files/") })
        let state = await h.engine.state()
        #expect(state.isEncrypted && state.lastSuccessAt == nil)
    }

    /// Encryption turned on and off again during a plaintext run: the key changed, so the run
    /// records no outcome.
    @Test func keyChangedMidRunGetsNoSuccessFromThatRun() async throws {
        let h = try await BackupHarness()
        h.trigger.withLock {
            $0 = (2, {
                try? await h.engine.enableEncryption(password: "11111-22222-33333-44444-55555-66666")
                try? await h.engine.disableEncryption()
            })
        }
        #expect(try await h.configure() == .succeeded)
        let state = await h.engine.state()
        #expect(!state.isEncrypted && state.keyID != nil)
        #expect(state.lastSuccessAt == nil)
    }

    @Test func folderChosenMidRunGetsNoSuccessFromThatRun() async throws {
        let h = try await BackupHarness()
        let second = try makeTempRoot()
        let kicked = Locked<BackupEngine.RunOutcome?>(nil)
        h.trigger.withLock { $0 = (2, { let r = try? await h.engine.chooseFolder(second); kicked.m.withLock { $0 = r } }) }
        #expect(try await h.configure() == .succeeded)
        #expect(kicked.m.withLock { $0 } == .busy)
        let state = await h.engine.state()
        #expect(state.lastSuccessAt == nil)
        #expect(await h.engine.tick() == .succeeded)
        #expect(FileManager.default.fileExists(atPath: second.appendingPathComponent("Blaise Backups/\(testInstallID)/snapshots").path))
    }

    /// A state file that cannot be read when the run records its outcome is left as it is: the
    /// run's write never replaces it with an empty state.
    @Test func unreadableStateAtTheOutcomeWriteKeepsTheConfiguration() async throws {
        let h = try await BackupHarness()
        try await h.engine.enableEncryption(password: try BackupEngine.generatePassword())
        #expect(try await h.configure() == .succeeded)
        let before = await h.engine.state()
        let stateFile = h.root.appendingPathComponent(".backup-state.json").path
        h.advance(day)
        h.failer.withLock {
            $0 = { if case .rename(let from, _) = $0, from.contains("/.partial-") { chmod(stateFile, 0) } }
        }
        #expect(await h.engine.tick() == .succeeded)
        h.failer.withLock { $0 = nil }
        chmod(stateFile, 0o644)
        let after = await h.engine.state()
        #expect(after.destinationBookmark == before.destinationBookmark)
        #expect(after.isEncrypted && after.keyID == before.keyID)
        #expect(after.lastSuccessAt == before.lastSuccessAt)
        #expect(await h.engine.tick() == .succeeded)
    }

    /// The same for a failing run: recording its failure never replaces an unreadable state.
    @Test func unreadableStateAtTheFailureWriteKeepsTheConfiguration() async throws {
        let h = try await BackupHarness()
        try await h.engine.enableEncryption(password: try BackupEngine.generatePassword())
        #expect(try await h.configure() == .succeeded)
        let before = await h.engine.state()
        let stateFile = h.root.appendingPathComponent(".backup-state.json").path
        h.advance(day)
        h.failer.withLock {
            $0 = { op in
                if case .makeDirectory(let p) = op, p.contains("/.partial-") {
                    chmod(stateFile, 0)
                    throw POSIXError(.ENOSPC)
                }
            }
        }
        #expect(await h.engine.tick() == .failed(.full))
        h.failer.withLock { $0 = nil }
        chmod(stateFile, 0o644)
        let after = await h.engine.state()
        #expect(after.destinationBookmark == before.destinationBookmark)
        #expect(after.isEncrypted && after.keyID == before.keyID)
    }
}

// MARK: - TP10: performance gauge

/// The longest interval between consecutive heartbeats.
func maxHeartbeatGap(_ beats: [Date]) -> TimeInterval {
    zip(beats, beats.dropFirst()).map { $1.timeIntervalSince($0) }.max() ?? 0
}

/// Runs `work` under a main-queue heartbeat every 16 ms, started before `work` begins; returns
/// its result, the heartbeat count and the longest gap. The timer is strict with no leeway: under
/// a background process policy an ordinary sleep's wakeups coalesce past 100 ms on an idle main
/// actor, which would read as a stall.
@MainActor
func withMainActorHeartbeat<T>(_ work: @MainActor () async throws -> T) async rethrows
    -> (result: T, beats: Int, maxGap: TimeInterval)
{
    // The first heartbeat is on record before the work starts, so a stall at its start is a gap.
    let beats = Locked<[Date]>([Date()])
    let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
    timer.schedule(deadline: .now() + .milliseconds(16), repeating: .milliseconds(16), leeway: .nanoseconds(0))
    timer.setEventHandler { beats.m.withLock { $0.append(Date()) } }
    timer.resume()
    defer { timer.cancel() }
    let result = try await work()
    // The last heartbeat follows the work, so a stall at its end is a gap too.
    beats.m.withLock { $0.append(Date()) }
    let all = beats.m.withLock { $0 }
    return (result, all.count, maxHeartbeatGap(all))
}

@Suite(.serialized) struct BackupPerformanceTests {
    @Test func heartbeatGapIsTheWholeInterval() {
        let t = Date(timeIntervalSince1970: 0)
        #expect(maxHeartbeatGap([t, t + 0.016, t + 0.126]) > 0.100)
    }

    /// A main actor held from the first moment of the measured work still shows as a gap.
    @MainActor @Test func stallAtTheStartOfTheWorkIsMeasured() async {
        let gauge = await withMainActorHeartbeat { usleep(150_000) }
        #expect(gauge.maxGap > 0.100)
    }

    @Test func fullFirstBackupDoesNotStallMainOrWriters() async throws {
        let h = try await BackupHarness(meetings: false)
        for _ in 0..<9 { try await DemoSeeder.seed(database: h.database, now: h.clock.withLock { $0 }) }
        let ids = try await h.database.pool.read { try String.fetchAll($0, sql: "SELECT id FROM meeting") }
        #expect(ids.count >= 100)
        var recordings = 0
        for id in ids {
            let dir = try h.database.paths.createMeetingDirectory(id)
            for name in ["audio.m4a", "audio_mic.m4a"] {
                try randomBytes(256 * 1024).write(to: dir.appendingPathComponent(name))
                recordings += 1
            }
            try randomBytes(4_000).write(to: dir.appendingPathComponent("diarization.json"))
        }
        #expect(recordings >= 200)

        let stop = Locked(false)
        let maxCommit = Locked(0.0)
        let commits = Locked(0)
        let settings = SettingsStore(database: h.database)
        let writer = Task.detached {
            var i = 0
            while !stop.m.withLock({ $0 }) {
                let t = Date()
                try? await settings.set("backup.gauge.counter", to: i)
                maxCommit.m.withLock { $0 = max($0, Date().timeIntervalSince(t)) }
                commits.m.withLock { $0 += 1 }
                i += 1
            }
        }
        let started = Date()
        let gauge = try await withMainActorHeartbeat {
            try await Task(priority: .utility) { try await h.configure() }.value
        }
        let elapsed = Date().timeIntervalSince(started)
        stop.m.withLock { $0 = true }
        await writer.value
        #expect(gauge.result == .succeeded)
        #expect(gauge.beats > 2 && commits.m.withLock { $0 } > 0)
        let gapMs = gauge.maxGap * 1000
        let commitMs = maxCommit.m.withLock { $0 } * 1000
        print(String(format: "BACKUP-GAUGE| meetings=%d recordings=%d run=%.2fs maxHeartbeatGap=%.1fms maxCommit=%.1fms",
                     ids.count, recordings, elapsed, gapMs, commitMs))
        #expect(gapMs <= 100)
        #expect(commitMs <= 100)
    }
}
