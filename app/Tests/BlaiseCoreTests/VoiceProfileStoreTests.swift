import Foundation
import Testing
@testable import BlaiseCore

private enum ProfileFixture {
    static let withinOwnerDistance = 0.187
    static let strangerDistance = 0.662
    static let sameModeDot = 1 - withinOwnerDistance
    static let baseCrossDot = (1 - strangerDistance) / sameModeDot

    static let ownerBase: [Float] = unit([1, 0, 0])
    static let colleagueBase: [Float] = unit([
        baseCrossDot, sqrt(1 - baseCrossDot * baseCrossDot), 0,
    ])
    static let secondColleagueBase: [Float] = {
        let c = baseCrossDot
        let s = sqrt(1 - c * c)
        let y = (c - c * c) / s
        return unit([c, y, sqrt(1 - c * c - y * y)])
    }()

    static func unit(_ prefix: [Double], count: Int = 32) -> [Float] {
        var values = prefix + Array(repeating: 0, count: max(0, count - prefix.count))
        let norm = sqrt(values.reduce(0) { $0 + $1 * $1 })
        values = values.map { $0 / norm }
        return values.map(Float.init)
    }

    static func sample(base: [Float], noiseIndex: Int) -> [Float] {
        var values = base.map { Double($0) * sqrt(sameModeDot) }
        values[noiseIndex] = sqrt(withinOwnerDistance)
        return values.map(Float.init)
    }

    static func blend(_ lhs: [Float], _ rhs: [Float]) -> [Float] {
        unit(zip(lhs, rhs).map { Double($0) + Double($1) })
    }

    static func candidate(
        id: String, base: [Float], noiseIndex: Int, speech: Double,
        language: String = "en"
    ) -> VoiceProfileCandidate {
        VoiceProfileCandidate(
            meetingID: id,
            meetingDate: Date(timeIntervalSince1970: Double(noiseIndex)),
            modelID: "vexatron-voice-v1",
            embedding: sample(base: base, noiseIndex: noiseIndex),
            speechSeconds: speech,
            language: language)
    }

    static func pool(
        owners: Int, colleagues: Int, blends: Int = 0
    ) -> [VoiceProfileCandidate] {
        var result: [VoiceProfileCandidate] = []
        for index in 0..<owners {
            result.append(candidate(
                id: "owner-\(index)", base: ownerBase, noiseIndex: 3 + index,
                speech: 200 - Double(index)))
        }
        for index in 0..<colleagues {
            result.append(candidate(
                id: "colleague-\(index)", base: colleagueBase,
                noiseIndex: 12 + index, speech: 150 - Double(index)))
        }
        let blendEmbedding = blend(ownerBase, colleagueBase)
        for index in 0..<blends {
            result.append(VoiceProfileCandidate(
                meetingID: "blend-\(index)",
                meetingDate: Date(timeIntervalSince1970: Double(30 + index)),
                modelID: "vexatron-voice-v1",
                embedding: blendEmbedding,
                speechSeconds: 100 - Double(index),
                language: "en"))
        }
        return result
    }
}

private func permutations<T>(_ values: [T]) -> [[T]] {
    guard values.count > 1 else { return [values] }
    return values.indices.flatMap { index -> [[T]] in
        var remainder = values
        let head = remainder.remove(at: index)
        return permutations(remainder).map { [head] + $0 }
    }
}

@Suite("Voice profile acceptance pools")
struct VoiceProfileAcceptanceTests {
    private func accepts(_ candidates: [VoiceProfileCandidate]) -> Bool {
        VoiceProfileAcceptance.evaluate(
            candidates, createdAt: Date(timeIntervalSince1970: 500)) != nil
    }

    @Test("fixture geometry pins measured within-owner and stranger distances")
    func measuredGeometry() throws {
        let ownerA = ProfileFixture.candidate(
            id: "owner-a", base: ProfileFixture.ownerBase, noiseIndex: 3, speech: 90)
        let ownerB = ProfileFixture.candidate(
            id: "owner-b", base: ProfileFixture.ownerBase, noiseIndex: 4, speech: 89)
        let stranger = ProfileFixture.candidate(
            id: "colleague-a", base: ProfileFixture.colleagueBase,
            noiseIndex: 12, speech: 88)
        let within = try #require(
            RoomTreatment.cosineDistance(ownerA.embedding, ownerB.embedding))
        let cross = try #require(
            RoomTreatment.cosineDistance(ownerA.embedding, stranger.embedding))
        #expect(abs(within - 0.187) < 0.001)
        #expect(abs(cross - 0.662) < 0.001)
    }

    @Test("AC5 pool verdict table")
    func poolVerdicts() {
        #expect(accepts(ProfileFixture.pool(owners: 2, colleagues: 0)))
        #expect(accepts(ProfileFixture.pool(owners: 2, colleagues: 1)))
        #expect(!accepts(ProfileFixture.pool(owners: 2, colleagues: 2)))
        #expect(!accepts(ProfileFixture.pool(owners: 3, colleagues: 2)))
        #expect(accepts(ProfileFixture.pool(owners: 4, colleagues: 2)))
        #expect(!accepts(ProfileFixture.pool(owners: 2, colleagues: 2, blends: 1)))
        #expect(!accepts(ProfileFixture.pool(owners: 3, colleagues: 2, blends: 1)))
        #expect(!accepts(ProfileFixture.pool(owners: 2, colleagues: 2, blends: 2)))
        #expect(accepts(ProfileFixture.pool(owners: 2, colleagues: 0, blends: 1)))
    }

    @Test("all competing modes participate in ambiguous-evidence exclusion")
    func twoColleaguePoolRefuses() {
        var pool = ProfileFixture.pool(owners: 5, colleagues: 3)
        for index in 0..<2 {
            pool.append(ProfileFixture.candidate(
                id: "second-colleague-\(index)",
                base: ProfileFixture.secondColleagueBase,
                noiseIndex: 20 + index, speech: 125 - Double(index)))
        }
        pool.append(VoiceProfileCandidate(
            meetingID: "second-colleague-blend",
            meetingDate: Date(timeIntervalSince1970: 40),
            modelID: "vexatron-voice-v1",
            embedding: ProfileFixture.blend(
                ProfileFixture.ownerBase, ProfileFixture.secondColleagueBase),
            speechSeconds: 100,
            language: "en"))
        #expect(!accepts(pool))
    }

    @Test("every arrival order leaves the pinned pool verdicts invariant")
    func arrivalPermutationInvariance() {
        for configuration in [(2, 0), (2, 1), (2, 2), (3, 2), (4, 2)] {
            let pool = ProfileFixture.pool(
                owners: configuration.0, colleagues: configuration.1)
            let expected = accepts(pool)
            for permutation in permutations(pool) {
                #expect(accepts(permutation) == expected)
            }
        }
    }

    @Test("a duplicate append pool matches its deduplicated form")
    func duplicateAppendMatchesDeduplicatedPool() throws {
        let pool = ProfileFixture.pool(owners: 4, colleagues: 2)
        let duplicate = VoiceProfileCandidate(
            meetingID: pool[0].meetingID,
            meetingDate: pool[0].meetingDate,
            modelID: pool[0].modelID,
            embedding: pool[0].embedding,
            speechSeconds: pool[0].speechSeconds,
            language: pool[0].language)
        let createdAt = Date(timeIntervalSince1970: 600)
        let forward = try #require(
            VoiceProfileAcceptance.evaluate(pool, createdAt: createdAt))
        let reverse = try #require(
            VoiceProfileAcceptance.evaluate(
                Array((pool + [duplicate]).reversed()), createdAt: createdAt))
        #expect(forward == reverse)
    }

    @Test("references alternate the two most frequent languages deterministically")
    func deterministicLanguageAlternation() throws {
        var pool = ProfileFixture.pool(owners: 6, colleagues: 0)
        pool[4].language = "pt"
        pool[5].language = "pt"
        let profile = try #require(
            VoiceProfileAcceptance.evaluate(pool, createdAt: Date()))
        #expect(profile.references.map(\.language).prefix(4) == ["en", "pt", "en", "pt"])
        #expect(profile.references.map(\.meetingID) == [
            "owner-0", "owner-4", "owner-1", "owner-5", "owner-2", "owner-3",
        ])
    }
}

@Suite("Voice profile store lifecycle")
struct VoiceProfileStoreTests {
    @Test("harvest requires a gate row and exactly one 60-second mic cluster")
    func harvestEligibility() {
        let facts = CaptureFacts(sourceProvenance: .classified, linkClass: .generic)
        let eligible = VoiceProfileHarvest.candidate(
            meetingID: "quoll-eligible",
            meetingDate: Date(),
            source: .meet,
            captureFacts: facts,
            micClusters: [
                RoomSpeechCluster(
                    label: "M0",
                    intervals: [
                        SpeechInterval(startSeconds: 0, endSeconds: 40),
                        SpeechInterval(startSeconds: 35, endSeconds: 65),
                    ],
                    centroid: [1, 0])
            ],
            modelID: "vexatron-voice-v1",
            language: "en")
        #expect(eligible?.speechSeconds == 65)

        let inPerson = VoiceProfileHarvest.candidate(
            meetingID: "quoll-room",
            meetingDate: Date(),
            source: .inPerson,
            captureFacts: facts,
            micClusters: [
                RoomSpeechCluster(
                    label: "M0", intervals: [SpeechInterval(startSeconds: 0, endSeconds: 70)],
                    centroid: [1, 0])
            ],
            modelID: "vexatron-voice-v1",
            language: "en")
        #expect(inPerson == nil)

        let tooShort = VoiceProfileHarvest.candidate(
            meetingID: "quoll-short",
            meetingDate: Date(),
            source: .meet,
            captureFacts: facts,
            micClusters: [
                RoomSpeechCluster(
                    label: "M0", intervals: [SpeechInterval(startSeconds: 0, endSeconds: 59)],
                    centroid: [1, 0])
            ],
            modelID: "vexatron-voice-v1",
            language: "en")
        #expect(tooShort == nil)

        let twoClusters = VoiceProfileHarvest.candidate(
            meetingID: "quoll-two-clusters",
            meetingDate: Date(),
            source: .meet,
            captureFacts: facts,
            micClusters: [
                RoomSpeechCluster(
                    label: "M0", intervals: [SpeechInterval(startSeconds: 0, endSeconds: 70)],
                    centroid: [1, 0]),
                RoomSpeechCluster(
                    label: "M1", intervals: [SpeechInterval(startSeconds: 70, endSeconds: 140)],
                    centroid: [0, 1]),
            ],
            modelID: "vexatron-voice-v1",
            language: "en")
        #expect(twoClusters == nil)
    }

    @Test("UPSERT replaces a meeting candidate, acceptance freezes, and snapshot matches")
    func upsertFreezeAndSnapshot() async throws {
        let root = try makeTempRoot()
        let paths = MeetingPaths(rootURL: root)
        let store = VoiceProfileStore(paths: paths)
        let firstToken = try #require(await store.pendingAppend())
        var first = ProfileFixture.candidate(
            id: "quoll-a", base: ProfileFixture.ownerBase, noiseIndex: 3, speech: 80)
        #expect(try await store.append(first, pending: firstToken) == .collecting(1))
        #expect(await store.status() == .collecting(1))

        first.speechSeconds = 120
        let replacementToken = try #require(await store.pendingAppend())
        #expect(try await store.append(first, pending: replacementToken) == .collecting(1))

        let second = ProfileFixture.candidate(
            id: "quoll-b", base: ProfileFixture.ownerBase, noiseIndex: 4, speech: 90)
        let acceptToken = try #require(await store.pendingAppend())
        #expect(try await store.append(second, pending: acceptToken) == .accepted)
        let snapshot = try #require(await store.runSnapshot())
        #expect(snapshot.references.first { $0.meetingID == "quoll-a" }?.speechSeconds == 120)
        let distance = snapshot.references.compactMap {
            RoomTreatment.cosineDistance(first.embedding, $0.embedding)
        }.min()
        #expect(distance.map { $0 < 0.001 } == true)
        #expect(await store.status() == .identified)

        let third = ProfileFixture.candidate(
            id: "quoll-c", base: ProfileFixture.ownerBase, noiseIndex: 5, speech: 88)
        let frozenToken = try #require(await store.pendingAppend())
        #expect(try await store.append(third, pending: frozenToken) == .frozen)
    }

    @Test("corrupt profile fails closed, quarantines, and collection can continue")
    func corruptionQuarantine() async throws {
        let root = try makeTempRoot()
        let paths = MeetingPaths(rootURL: root)
        try FileManager.default.createDirectory(
            at: paths.voiceProfileDirectory, withIntermediateDirectories: true)
        let profileURL = paths.voiceProfileDirectory.appendingPathComponent("profile.json")
        try Data("{".utf8).write(to: profileURL)
        let store = VoiceProfileStore(paths: paths)

        #expect(await store.runSnapshot() == nil)
        #expect(FileManager.default.fileExists(
            atPath: paths.voiceProfileDirectory
                .appendingPathComponent("profile.json.corrupt").path))
        let token = try #require(await store.pendingAppend())
        let candidate = ProfileFixture.candidate(
            id: "quoll-after-corrupt", base: ProfileFixture.ownerBase,
            noiseIndex: 3, speech: 80)
        #expect(try await store.append(candidate, pending: token) == .collecting(1))
    }

    @Test("OFF deletes the store and invalidates an already-issued append")
    func deleteAndInvalidatePendingAppend() async throws {
        let root = try makeTempRoot()
        let paths = MeetingPaths(rootURL: root)
        let store = VoiceProfileStore(paths: paths)
        let token = try #require(await store.pendingAppend())
        let candidate = ProfileFixture.candidate(
            id: "quoll-pending", base: ProfileFixture.ownerBase,
            noiseIndex: 3, speech: 80)
        _ = try await store.append(candidate, pending: token)
        let staleToken = try #require(await store.pendingAppend())

        try await store.deleteAndInvalidatePendingAppends()

        #expect(!FileManager.default.fileExists(atPath: paths.voiceProfileDirectory.path))
        #expect(try await store.append(candidate, pending: staleToken) == .invalidated)
        #expect(await store.runSnapshot() == nil)
    }
}

@Suite("Voice identification setting")
struct VoiceIdentificationSettingsTests {
    @Test("a fresh settings row reads ON; a persisted OFF survives the read")
    func defaultAndPersistence() async throws {
        let database = try makeDatabase()
        let settings = SettingsStore(database: database)
        #expect(await VoiceIdentificationSettings.isEnabled(in: settings))

        try await settings.set(VoiceIdentificationSettings.enabledKey, to: false)
        #expect(await VoiceIdentificationSettings.isEnabled(in: settings) == false)
    }

    @Test("a persisted OFF disables the shared store before any run reads it")
    func launchWiringDisablesTheStore() async throws {
        let root = try makeTempRoot()
        let paths = MeetingPaths(rootURL: root)
        let store = VoiceProfileStore(paths: paths)

        try await VoiceIdentificationSettings.apply(enabled: false, to: store)
        #expect(await store.pendingAppend() == nil)
        #expect(await store.runSnapshot() == nil)

        // Back ON: collection restarts from an empty pool.
        try await VoiceIdentificationSettings.apply(enabled: true, to: store)
        #expect(await store.pendingAppend() != nil)
        #expect(await store.status() == .collecting(0))
    }

    /// Two owner meetings accept and freeze the profile (§4.3 bootstrap).
    private func seedFrozenProfile(in store: VoiceProfileStore) async throws {
        let first = ProfileFixture.candidate(
            id: "quoll-a", base: ProfileFixture.ownerBase, noiseIndex: 3, speech: 80)
        let second = ProfileFixture.candidate(
            id: "quoll-b", base: ProfileFixture.ownerBase, noiseIndex: 4, speech: 90)
        let firstToken = try #require(await store.pendingAppend())
        #expect(try await store.append(first, pending: firstToken) == .collecting(1))
        let acceptToken = try #require(await store.pendingAppend())
        #expect(try await store.append(second, pending: acceptToken) == .accepted)
    }

    @Test("residue from a failed OFF deletion reads as empty and cannot resurrect on ON")
    func residueCannotResurrect() async throws {
        let root = try makeTempRoot()
        let paths = MeetingPaths(rootURL: root)
        let directory = paths.voiceProfileDirectory
        let profileURL = directory.appendingPathComponent("profile.json")
        let candidatesURL = directory.appendingPathComponent("candidates.json")
        let store = VoiceProfileStore(paths: paths)
        try await seedFrozenProfile(in: store)
        #expect(await store.status() == .identified)
        let profileBytes = try Data(contentsOf: profileURL)
        let candidateBytes = try Data(contentsOf: candidatesURL)

        // An OFF whose deletion failed: the actor is disabled, the files survive.
        try await VoiceIdentificationSettings.apply(enabled: false, to: store)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try profileBytes.write(to: profileURL)
        try candidateBytes.write(to: candidatesURL)

        #expect(await store.runSnapshot() == nil)
        #expect(await store.pendingAppend() == nil)
        #expect(await store.status() == .collecting(0))

        try await VoiceIdentificationSettings.apply(enabled: true, to: store)
        #expect(!FileManager.default.fileExists(atPath: profileURL.path))
        #expect(!FileManager.default.fileExists(atPath: candidatesURL.path))
        #expect(await store.runSnapshot() == nil)
        #expect(await store.status() == .collecting(0))
        #expect(await store.pendingAppend() != nil)
    }

    @Test("a launch applying a persisted ON leaves a live profile intact")
    func launchApplyOfPersistedOnKeepsTheProfile() async throws {
        let root = try makeTempRoot()
        let paths = MeetingPaths(rootURL: root)
        let profileURL = paths.voiceProfileDirectory.appendingPathComponent("profile.json")
        try await seedFrozenProfile(in: VoiceProfileStore(paths: paths))

        // The launch shape: a FRESH instance over a data root that already
        // holds the profile, applying a persisted ON.
        let fresh = VoiceProfileStore(paths: paths)
        try await VoiceIdentificationSettings.apply(enabled: true, to: fresh)

        #expect(FileManager.default.fileExists(atPath: profileURL.path))
        #expect(await fresh.runSnapshot() != nil)
        #expect(await fresh.status() == .identified)
    }

    /// `voice_profile/` at 0o500 keeps its children unlinkable, so every
    /// deletion of the directory throws — the persistent write condition the
    /// residue cases rest on. Callers restore 0o700 so the temp root can be
    /// cleaned.
    private func setVoiceProfileDirectoryWritable(_ url: URL, _ writable: Bool) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: writable ? 0o700 : 0o500], ofItemAtPath: url.path)
    }

    /// A seeded, frozen profile whose OFF flip failed to delete it: the store is
    /// disabled, the value is durably OFF, the files survive on disk.
    private func failedOff(
        paths: MeetingPaths, settings: SettingsStore
    ) async throws -> VoiceProfileStore {
        let store = VoiceProfileStore(paths: paths)
        try await seedFrozenProfile(in: store)
        try setVoiceProfileDirectoryWritable(paths.voiceProfileDirectory, false)
        await VoiceIdentificationSettings.flip(
            enabled: false, in: settings, applyingTo: store)
        return store
    }

    @Test("an ON flip whose purge throws leaves the persisted value OFF")
    func failedOnFlipLeavesThePersistedValueOff() async throws {
        let paths = MeetingPaths(rootURL: try makeTempRoot())
        let directory = paths.voiceProfileDirectory
        let profileURL = directory.appendingPathComponent("profile.json")
        let settings = SettingsStore(database: try makeDatabase())
        let store = try await failedOff(paths: paths, settings: settings)
        defer { try? setVoiceProfileDirectoryWritable(directory, true) }

        #expect(await VoiceIdentificationSettings.isEnabled(in: settings) == false)
        #expect(FileManager.default.fileExists(atPath: profileURL.path))

        await VoiceIdentificationSettings.flip(
            enabled: true, in: settings, applyingTo: store)

        #expect(await VoiceIdentificationSettings.isEnabled(in: settings) == false)
        #expect(await store.runSnapshot() == nil)
        #expect(await store.status() == .collecting(0))
        #expect(await store.pendingAppend() == nil)
    }

    @Test("failed-OFF residue plus a failed ON flip does not resurrect at the next launch")
    func residueDoesNotResurrectAcrossLaunch() async throws {
        let paths = MeetingPaths(rootURL: try makeTempRoot())
        let directory = paths.voiceProfileDirectory
        let settings = SettingsStore(database: try makeDatabase())
        let store = try await failedOff(paths: paths, settings: settings)
        defer { try? setVoiceProfileDirectoryWritable(directory, true) }
        await VoiceIdentificationSettings.flip(
            enabled: true, in: settings, applyingTo: store)

        // Launch, write condition unchanged: a FRESH store applies the
        // persisted value, which the failed ON left OFF.
        let relaunched = VoiceProfileStore(paths: paths)
        try? await VoiceIdentificationSettings.apply(
            enabled: await VoiceIdentificationSettings.isEnabled(in: settings),
            to: relaunched)
        #expect(await relaunched.runSnapshot() == nil)
        #expect(await relaunched.status() == .collecting(0))

        // Once the write condition clears, the persisted OFF's retry deletes it.
        try setVoiceProfileDirectoryWritable(directory, true)
        let healed = VoiceProfileStore(paths: paths)
        try await VoiceIdentificationSettings.apply(
            enabled: await VoiceIdentificationSettings.isEnabled(in: settings),
            to: healed)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(await healed.runSnapshot() == nil)
    }

    @Test("a successful ON flip persists ON and restarts collection from empty")
    func successfulOnFlipPersistsOn() async throws {
        let paths = MeetingPaths(rootURL: try makeTempRoot())
        let settings = SettingsStore(database: try makeDatabase())
        let store = VoiceProfileStore(paths: paths)
        try await seedFrozenProfile(in: store)

        await VoiceIdentificationSettings.flip(
            enabled: false, in: settings, applyingTo: store)
        #expect(await VoiceIdentificationSettings.isEnabled(in: settings) == false)

        await VoiceIdentificationSettings.flip(
            enabled: true, in: settings, applyingTo: store)

        #expect(await VoiceIdentificationSettings.isEnabled(in: settings))
        #expect(await store.runSnapshot() == nil)
        #expect(await store.status() == .collecting(0))
        #expect(await store.pendingAppend() != nil)
    }

    @Test("the status line reads verbatim in both states")
    func statusStrings() {
        #expect(
            VoiceIdentificationSettings.statusText(.collecting(3))
                == "Voice print: still being collected (3 candidate meetings)")
        #expect(
            VoiceIdentificationSettings.statusText(.identified) == "Voice print: identified")
    }
}
