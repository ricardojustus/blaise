import Foundation

public struct VoiceProfileCandidate: Codable, Sendable, Equatable {
    public var meetingID: MeetingID
    public var meetingDate: Date
    public var modelID: String
    public var embedding: [Float]
    public var speechSeconds: Double
    public var language: String

    public init(
        meetingID: MeetingID, meetingDate: Date, modelID: String,
        embedding: [Float], speechSeconds: Double, language: String
    ) {
        self.meetingID = meetingID
        self.meetingDate = meetingDate
        self.modelID = modelID
        self.embedding = embedding
        self.speechSeconds = speechSeconds
        self.language = language
    }
}

public struct VoiceProfileAcceptanceEvidence: Codable, Sendable, Equatable {
    public var winningModeCenterMeetingID: MeetingID
    public var cliqueMembers: [MeetingID]
    public var exclusions: [MeetingID]
    public var winningDistinctMeetingsBeforeExclusion: Int
    public var winningDistinctMeetingsAfterExclusion: Int
    public var runnerUpDistinctMeetings: Int
    public var competingModes: [[MeetingID]]

    public init(
        winningModeCenterMeetingID: MeetingID,
        cliqueMembers: [MeetingID],
        exclusions: [MeetingID],
        winningDistinctMeetingsBeforeExclusion: Int,
        winningDistinctMeetingsAfterExclusion: Int,
        runnerUpDistinctMeetings: Int,
        competingModes: [[MeetingID]]
    ) {
        self.winningModeCenterMeetingID = winningModeCenterMeetingID
        self.cliqueMembers = cliqueMembers
        self.exclusions = exclusions
        self.winningDistinctMeetingsBeforeExclusion =
            winningDistinctMeetingsBeforeExclusion
        self.winningDistinctMeetingsAfterExclusion =
            winningDistinctMeetingsAfterExclusion
        self.runnerUpDistinctMeetings = runnerUpDistinctMeetings
        self.competingModes = competingModes
    }
}

public struct VoiceProfile: Codable, Sendable, Equatable {
    public var version: Int
    public var modelID: String
    public var createdAt: Date
    public var references: [VoiceProfileReference]
    public var acceptance: VoiceProfileAcceptanceEvidence

    public init(
        version: Int, modelID: String, createdAt: Date,
        references: [VoiceProfileReference],
        acceptance: VoiceProfileAcceptanceEvidence
    ) {
        self.version = version
        self.modelID = modelID
        self.createdAt = createdAt
        self.references = references
        self.acceptance = acceptance
    }

    public var snapshot: VoiceProfileSnapshot {
        VoiceProfileSnapshot(version: version, modelID: modelID, references: references)
    }
}

public enum VoiceProfileStatus: Sendable, Equatable {
    case collecting(Int)
    case identified
}

public enum VoiceProfileAppendResult: Sendable, Equatable {
    case invalidated
    case collecting(Int)
    case accepted
    case frozen
}

public struct VoiceProfilePendingAppend: Sendable, Equatable {
    fileprivate var generation: Int
}

/// The Settings → Identity & Handoff "Voice identification" toggle, persisted
/// in `app_setting`, default ON. OFF deletes the profile store, invalidates any
/// pending post-run harvest append, and leaves the run snapshot empty so the
/// treatment ladder sees the profile as absent.
public enum VoiceIdentificationSettings {
    public static let enabledKey = "voiceProfile.identification.enabled"
    /// Default ON: an unset toggle (no row yet) means collection runs.
    public static let defaultEnabled = true

    public static func isEnabled(in store: SettingsStore) async -> Bool {
        ((try? await store.get(enabledKey, as: Bool.self)) ?? nil) ?? defaultEnabled
    }

    /// Brings the app's SHARED profile store in line with the toggle — at
    /// launch (the store's in-memory `enabled` starts true regardless of the
    /// persisted value) and at every flip. `enabled` and the append-generation
    /// token are per-actor state, so this must reach the same instance the
    /// pipeline holds. Deletion is idempotent.
    public static func apply(
        enabled: Bool, to profileStore: VoiceProfileStore
    ) async throws {
        if enabled {
            try await profileStore.enableCollection()
        } else {
            try await profileStore.deleteAndInvalidatePendingAppends()
        }
    }

    /// A user flip of the Settings toggle, ordered asymmetrically so an ON never
    /// overwrites a durable OFF until the purge succeeds: a persisted ON written
    /// here implies an empty store, which is what makes the launch fast path
    /// (`enableCollection`'s transition guard) sound. OFF persists first: a
    /// durable OFF makes every later launch retry the deletion. A failed ON
    /// leaves the durable value OFF while the in-session toggle reads ON; the
    /// next tab load corrects the toggle, and the privacy-safe state is the
    /// durable one. Outside this guarantee: an OFF leg whose settings write ALSO
    /// fails leaves a prior or default ON durable over residue — the fail-open
    /// residual parked for the operator.
    public static func flip(
        enabled: Bool, in settings: SettingsStore, applyingTo profileStore: VoiceProfileStore
    ) async {
        if enabled {
            do {
                try await apply(enabled: true, to: profileStore)
            } catch {
                return
            }
            try? await settings.set(enabledKey, to: true)
        } else {
            try? await settings.set(enabledKey, to: false)
            try? await apply(enabled: false, to: profileStore)
        }
    }

    public static func statusText(_ status: VoiceProfileStatus) -> String {
        switch status {
        case .identified:
            return "Voice print: identified"
        case .collecting(let count):
            return "Voice print: still being collected (\(count) candidate meetings)"
        }
    }
}

public enum VoiceProfileHarvest {
    public static func candidate(
        meetingID: MeetingID,
        meetingDate: Date,
        source: MeetingSource,
        captureFacts: CaptureFacts,
        micClusters: [RoomSpeechCluster],
        modelID: String,
        language: String
    ) -> VoiceProfileCandidate? {
        guard source != .inPerson else { return nil }
        guard [.recognized, .generic, .assumed].contains(captureFacts.linkClass) else {
            return nil
        }
        guard micClusters.count == 1, let cluster = micClusters.first,
            let embedding = cluster.centroid
        else { return nil }
        let speechSeconds = RoomTreatment.maskedSeconds(
            candidate: cluster.intervals, system: [])
        guard speechSeconds >= 60 else { return nil }
        return VoiceProfileCandidate(
            meetingID: meetingID, meetingDate: meetingDate, modelID: modelID,
            embedding: embedding, speechSeconds: speechSeconds, language: language)
    }
}

public enum VoiceProfileAcceptance {
    private struct Mode {
        var center: VoiceProfileCandidate
        var members: [VoiceProfileCandidate]
        var totalSpeech: Double {
            members.reduce(0) { $0 + $1.speechSeconds }
        }
    }

    public static func evaluate(
        _ candidates: [VoiceProfileCandidate],
        createdAt: Date,
        constants: RoomGateConstants = RoomGateConstants()
    ) -> VoiceProfile? {
        let pool = totalOrder(deduplicating: candidates)
        guard let modelID = pool.first?.modelID,
            pool.allSatisfy({ $0.modelID == modelID })
        else { return nil }
        let modes = pool.map { center in
            Mode(
                center: center,
                members: clique(
                    center: center, pool: pool, radius: constants.modeRadius))
        }
        guard let winning = modes.sorted(by: modePrecedes).first else { return nil }
        let winningIDs = Set(winning.members.map(\.meetingID))

        var seenCompeting: Set<String> = []
        let competing: [[VoiceProfileCandidate]] = modes.compactMap { mode in
            let remainder = mode.members.filter { !winningIDs.contains($0.meetingID) }
            guard Set(remainder.map(\.meetingID)).count >= 2 else { return nil }
            let key = remainder.map(\.meetingID).sorted().joined(separator: "\u{1f}")
            guard seenCompeting.insert(key).inserted else { return nil }
            return remainder
        }
        let runnerUpCount =
            competing.map { Set($0.map(\.meetingID)).count }.max() ?? 0
        let competingMembers = competing.flatMap { $0 }
        let exclusions = winning.members.filter { winningMember in
            competingMembers.contains {
                distance(winningMember, $0).map { $0 <= constants.modeRadius } ?? false
            }
        }
        let exclusionIDs = Set(exclusions.map(\.meetingID))
        let postExclusion = winning.members.filter {
            !exclusionIDs.contains($0.meetingID)
        }
        let winningCount = Set(postExclusion.map(\.meetingID)).count
        guard winningCount >= 2,
            runnerUpCount == 0 || winningCount >= constants.dominanceRatio * runnerUpCount
        else { return nil }

        let orderedReferences = languageBalanced(
            totalOrder(deduplicating: postExclusion))
            .prefix(8)
            .map {
                VoiceProfileReference(
                    meetingID: $0.meetingID, embedding: $0.embedding,
                    speechSeconds: $0.speechSeconds, language: $0.language)
            }
        let evidence = VoiceProfileAcceptanceEvidence(
            winningModeCenterMeetingID: winning.center.meetingID,
            cliqueMembers: winning.members.map(\.meetingID),
            exclusions: exclusions.map(\.meetingID),
            winningDistinctMeetingsBeforeExclusion: winningIDs.count,
            winningDistinctMeetingsAfterExclusion: winningCount,
            runnerUpDistinctMeetings: runnerUpCount,
            competingModes: competing.map { $0.map(\.meetingID) })
        return VoiceProfile(
            version: 1, modelID: modelID, createdAt: createdAt,
            references: Array(orderedReferences), acceptance: evidence)
    }

    public static func totalOrder(
        deduplicating candidates: [VoiceProfileCandidate]
    ) -> [VoiceProfileCandidate] {
        var byMeeting: [MeetingID: VoiceProfileCandidate] = [:]
        for candidate in candidates {
            byMeeting[candidate.meetingID] = candidate
        }
        return byMeeting.values.sorted {
            if $0.speechSeconds != $1.speechSeconds {
                return $0.speechSeconds > $1.speechSeconds
            }
            return $0.meetingID < $1.meetingID
        }
    }

    private static func clique(
        center: VoiceProfileCandidate,
        pool: [VoiceProfileCandidate],
        radius: Double
    ) -> [VoiceProfileCandidate] {
        var admitted = [center]
        for candidate in pool where candidate.meetingID != center.meetingID {
            let coherentWithCenter =
                distance(center, candidate).map { $0 <= radius } ?? false
            let coherentWithMembers = admitted.allSatisfy {
                distance($0, candidate).map { $0 <= radius } ?? false
            }
            if coherentWithCenter && coherentWithMembers {
                admitted.append(candidate)
            }
        }
        return admitted
    }

    private static func modePrecedes(_ lhs: Mode, _ rhs: Mode) -> Bool {
        let leftCount = Set(lhs.members.map(\.meetingID)).count
        let rightCount = Set(rhs.members.map(\.meetingID)).count
        if leftCount != rightCount { return leftCount > rightCount }
        if lhs.totalSpeech != rhs.totalSpeech { return lhs.totalSpeech > rhs.totalSpeech }
        if lhs.center.meetingDate != rhs.center.meetingDate {
            return lhs.center.meetingDate < rhs.center.meetingDate
        }
        return lhs.center.meetingID < rhs.center.meetingID
    }

    private static func languageBalanced(
        _ candidates: [VoiceProfileCandidate]
    ) -> [VoiceProfileCandidate] {
        var counts: [String: Int] = [:]
        var firstRank: [String: Int] = [:]
        for (index, candidate) in candidates.enumerated() {
            counts[candidate.language, default: 0] += 1
            firstRank[candidate.language, default: index] = min(
                firstRank[candidate.language] ?? index, index)
        }
        let primary = counts.keys.sorted {
            if counts[$0] != counts[$1] { return counts[$0]! > counts[$1]! }
            return firstRank[$0]! < firstRank[$1]!
        }.prefix(2)
        guard primary.count == 2 else { return candidates }
        let languages = Array(primary)
        var queues = languages.map { language in
            candidates.filter { $0.language == language }
        }
        var result: [VoiceProfileCandidate] = []
        var next = 0
        while !queues[0].isEmpty && !queues[1].isEmpty {
            result.append(queues[next].removeFirst())
            next = 1 - next
        }
        let selected = Set(result.map(\.meetingID))
        result.append(contentsOf: candidates.filter { !selected.contains($0.meetingID) })
        return result
    }

    private static func distance(
        _ lhs: VoiceProfileCandidate, _ rhs: VoiceProfileCandidate
    ) -> Double? {
        RoomTreatment.cosineDistance(lhs.embedding, rhs.embedding)
    }
}

public actor VoiceProfileStore {
    private struct CandidateFile: Codable {
        var version: Int
        var candidates: [VoiceProfileCandidate]
    }

    private let directory: URL
    private let candidatesURL: URL
    private let profileURL: URL
    private let corruptProfileURL: URL
    private var enabled = true
    private var generation = 0

    public init(paths: MeetingPaths) {
        directory = paths.voiceProfileDirectory
        candidatesURL = directory.appendingPathComponent("candidates.json")
        profileURL = directory.appendingPathComponent("profile.json")
        corruptProfileURL = directory.appendingPathComponent("profile.json.corrupt")
    }

    public func pendingAppend() -> VoiceProfilePendingAppend? {
        enabled ? VoiceProfilePendingAppend(generation: generation) : nil
    }

    public func append(
        _ candidate: VoiceProfileCandidate,
        pending: VoiceProfilePendingAppend,
        now: Date = Date()
    ) throws -> VoiceProfileAppendResult {
        guard enabled, pending.generation == generation else { return .invalidated }
        if readProfile(quarantiningCorruption: true) != nil { return .frozen }

        var candidates = readCandidates()
        if let index = candidates.firstIndex(where: { $0.meetingID == candidate.meetingID }) {
            candidates[index] = candidate
        } else {
            candidates.append(candidate)
        }
        candidates = VoiceProfileAcceptance.totalOrder(deduplicating: candidates)
        try write(
            CandidateFile(version: 1, candidates: candidates), to: candidatesURL)
        guard let profile = VoiceProfileAcceptance.evaluate(candidates, createdAt: now) else {
            return .collecting(candidates.count)
        }
        try write(profile, to: profileURL)
        return .accepted
    }

    public func runSnapshot() -> VoiceProfileSnapshot? {
        guard enabled else { return nil }
        return readProfile(quarantiningCorruption: true)?.snapshot
    }

    public func status() -> VoiceProfileStatus {
        // Disabled: whatever sits on disk is not collected evidence — residue
        // from a failed deletion must not render as "still being collected (n)".
        guard enabled else { return .collecting(0) }
        if runSnapshot() != nil { return .identified }
        return .collecting(readCandidates().count)
    }

    public func deleteAndInvalidatePendingAppends() throws {
        enabled = false
        generation += 1
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    /// Turning collection ON restarts it from empty: a disabled store may still
    /// hold residue from a deletion that failed, and that residue must never
    /// become a live profile again. A fresh instance starts enabled, so a
    /// launch that applies a persisted ON is not a transition and deletes
    /// nothing. A failed purge leaves the store DISABLED (the privacy-safe
    /// direction) and propagates.
    public func enableCollection() throws {
        guard !enabled else { return }
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        enabled = true
    }

    private func readCandidates() -> [VoiceProfileCandidate] {
        guard let data = try? Data(contentsOf: candidatesURL),
            let file = try? decoder().decode(CandidateFile.self, from: data)
        else { return [] }
        return VoiceProfileAcceptance.totalOrder(deduplicating: file.candidates)
    }

    private func readProfile(quarantiningCorruption: Bool) -> VoiceProfile? {
        guard FileManager.default.fileExists(atPath: profileURL.path) else { return nil }
        guard let data = try? Data(contentsOf: profileURL) else { return nil }
        do {
            return try decoder().decode(VoiceProfile.self, from: data)
        } catch {
            if quarantiningCorruption {
                if FileManager.default.fileExists(atPath: corruptProfileURL.path) {
                    try? FileManager.default.removeItem(at: corruptProfileURL)
                }
                try? FileManager.default.moveItem(at: profileURL, to: corruptProfileURL)
            }
            return nil
        }
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
