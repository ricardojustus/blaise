import Foundation

public struct RoomGateConstants: Sendable, Equatable {
    // Pinned by the §7 calibration over the operator-labelled archive; changing a
    // value re-opens that calibration.
    public var systemDistanceThreshold: Double = 0.50
    public var maskedSecondsFloor: Double = 60
    public var profileDistanceThreshold: Double = 0.45
    public var modeRadius: Double = 0.50
    public var dominanceRatio: Int = 2

    public init() {}
}

public struct SpeechInterval: Codable, Sendable, Equatable {
    public var startSeconds: Double
    public var endSeconds: Double

    public init(startSeconds: Double, endSeconds: Double) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }
}

public struct RoomSpeechCluster: Sendable, Equatable {
    public var label: String
    public var intervals: [SpeechInterval]
    public var centroid: [Float]?

    public init(label: String, intervals: [SpeechInterval], centroid: [Float]?) {
        self.label = label
        self.intervals = intervals
        self.centroid = centroid
    }
}

public struct VoiceProfileReference: Codable, Sendable, Equatable {
    public var meetingID: MeetingID
    public var embedding: [Float]
    public var speechSeconds: Double
    public var language: String

    public init(
        meetingID: MeetingID, embedding: [Float], speechSeconds: Double, language: String
    ) {
        self.meetingID = meetingID
        self.embedding = embedding
        self.speechSeconds = speechSeconds
        self.language = language
    }
}

public struct VoiceProfileSnapshot: Sendable, Equatable {
    public var version: Int
    public var modelID: String
    public var references: [VoiceProfileReference]

    public init(version: Int, modelID: String, references: [VoiceProfileReference]) {
        self.version = version
        self.modelID = modelID
        self.references = references
    }
}

public enum TreatmentLadderRow: String, Sendable, Equatable {
    case explicitInPersonRoom
    case profileAbsentSolo
    case profileRoom
    case audioGate
}

public enum RoomGateVerdict: String, Codable, Sendable, Equatable {
    case solo
    case room
}

public struct RoomGateEvidence: Codable, Sendable, Equatable {
    public var cluster: String
    public var maskedSeconds: Double
    public var sysDistance: Double?
    public var profileDistance: Double?

    public init(
        cluster: String, maskedSeconds: Double, sysDistance: Double?,
        profileDistance: Double?
    ) {
        self.cluster = cluster
        self.maskedSeconds = maskedSeconds
        self.sysDistance = sysDistance
        self.profileDistance = profileDistance
    }
}

public enum OwnerStampDecision: String, Codable, Sendable, Equatable {
    case anonymous
    case user
}

public struct OwnerStamp: Codable, Sendable, Equatable {
    public var decision: OwnerStampDecision
    public var suppressedByRename: Bool

    public init(decision: OwnerStampDecision, suppressedByRename: Bool = false) {
        self.decision = decision
        self.suppressedByRename = suppressedByRename
    }
}

public struct RoomClusterCentroids: Codable, Sendable, Equatable {
    public var mic: [String: [Float]]
    public var system: [String: [Float]]

    public init(mic: [String: [Float]], system: [String: [Float]]) {
        self.mic = mic
        self.system = system
    }
}

public struct RoomTreatmentArtifact: Codable, Sendable, Equatable {
    public var micDiarization: DiarizationOutput
    public var clusterCentroids: RoomClusterCentroids
    public var gateVerdict: RoomGateVerdict
    public var gateEvidence: [RoomGateEvidence]
    public var profileVersion: Int?
    public var ownerStamps: [String: OwnerStamp]

    public init(
        micDiarization: DiarizationOutput,
        clusterCentroids: RoomClusterCentroids,
        gateVerdict: RoomGateVerdict,
        gateEvidence: [RoomGateEvidence],
        profileVersion: Int?,
        ownerStamps: [String: OwnerStamp]
    ) {
        self.micDiarization = micDiarization
        self.clusterCentroids = clusterCentroids
        self.gateVerdict = gateVerdict
        self.gateEvidence = gateEvidence
        self.profileVersion = profileVersion
        self.ownerStamps = ownerStamps
    }
}

public struct GateCandidateSurvivalCounters: Codable, Sendable, Equatable {
    public var systemExclusion: Int = 0
    public var duration: Int = 0
    public var profileVeto: Int = 0

    public init() {}
}

public struct RoomTreatmentCounters: Codable, Sendable, Equatable {
    public var micDiarizeSeconds: Double = 0
    public var micClusterCount: Int = 0
    public var gateVerdict: RoomGateVerdict = .solo
    public var gateCandidatesSurvivingPerCondition = GateCandidateSurvivalCounters()
    public var ownerStampedClusters: Int = 0
    public var stampsSuppressedByRename: Int = 0
    public var stampsDisabledNoSystemCentroids: Int = 0
    public var micDiarizeFailed: Int = 0
    public var roomGateInertNoSystemCentroids: Int = 0
    public var captureFactsWriteFailed: Int = 0
    public var harvestAppended: Int = 0

    public init() {}
}

public struct RoomTreatmentEvaluation: Sendable, Equatable {
    public var ladderRow: TreatmentLadderRow
    public var artifact: RoomTreatmentArtifact
    public var counters: RoomTreatmentCounters

    public init(
        ladderRow: TreatmentLadderRow, artifact: RoomTreatmentArtifact,
        counters: RoomTreatmentCounters
    ) {
        self.ladderRow = ladderRow
        self.artifact = artifact
        self.counters = counters
    }
}

public enum RoomTreatment {
    public static func evaluate(
        source: MeetingSource,
        captureFacts: CaptureFacts,
        micClusters: [RoomSpeechCluster],
        systemCentroids: [String: [Float]],
        systemSpeechIntervals: [SpeechInterval],
        profile: VoiceProfileSnapshot?,
        persistedRenameClusters: Set<String>,
        constants: RoomGateConstants = RoomGateConstants()
    ) -> RoomTreatmentEvaluation {
        let profileUsable = profile?.references.isEmpty == false
        let ladderRow: TreatmentLadderRow
        if source == .inPerson && captureFacts.sourceProvenance == .explicit {
            ladderRow = .explicitInPersonRoom
        } else if !profileUsable {
            ladderRow = .profileAbsentSolo
        } else if source == .inPerson || captureFacts.linkClass == .none {
            ladderRow = .profileRoom
        } else {
            ladderRow = .audioGate
        }

        let systemSpeech = union(systemSpeechIntervals)
        let hasSystemSpeech = measure(systemSpeech) > 0
        let micCentroids = Dictionary(
            uniqueKeysWithValues: micClusters.compactMap { cluster in
                cluster.centroid.map { (cluster.label, $0) }
            })

        let evidence = micClusters.map { cluster in
            RoomGateEvidence(
                cluster: cluster.label,
                maskedSeconds: maskedSeconds(
                    candidate: cluster.intervals, system: systemSpeech),
                sysDistance: minimumDistance(
                    from: cluster.centroid, to: Array(systemCentroids.values)),
                profileDistance: minimumDistance(
                    from: cluster.centroid,
                    to: profile?.references.map(\.embedding) ?? []))
        }

        var counters = RoomTreatmentCounters()
        counters.micClusterCount = micClusters.count
        var verdict: RoomGateVerdict
        switch ladderRow {
        case .explicitInPersonRoom, .profileRoom:
            verdict = .room
        case .profileAbsentSolo:
            verdict = .solo
        case .audioGate:
            if hasSystemSpeech && systemCentroids.isEmpty {
                verdict = .solo
                counters.roomGateInertNoSystemCentroids = 1
            } else {
                let survivingSystem = evidence.filter {
                    hasSystemSpeech
                        ? (($0.sysDistance ?? -.infinity) > constants.systemDistanceThreshold)
                        : true
                }
                let survivingDuration = survivingSystem.filter {
                    $0.maskedSeconds >= constants.maskedSecondsFloor
                }
                let survivingProfile = survivingDuration.filter {
                    ($0.profileDistance ?? -.infinity) > constants.profileDistanceThreshold
                }
                counters.gateCandidatesSurvivingPerCondition.systemExclusion =
                    survivingSystem.count
                counters.gateCandidatesSurvivingPerCondition.duration =
                    survivingDuration.count
                counters.gateCandidatesSurvivingPerCondition.profileVeto =
                    survivingProfile.count
                verdict = survivingProfile.isEmpty ? .solo : .room
            }
        }

        var ownerStamps = Dictionary(
            uniqueKeysWithValues: micClusters.map {
                ($0.label, OwnerStamp(decision: .anonymous))
            })
        if verdict == .room, profileUsable, hasSystemSpeech && systemCentroids.isEmpty {
            counters.stampsDisabledNoSystemCentroids = 1
        } else if verdict == .room, profileUsable {
            ownerStamps = stampOwners(
                micClusters: micClusters, evidence: evidence,
                hasSystemSpeech: hasSystemSpeech,
                renamed: persistedRenameClusters, constants: constants,
                counters: &counters)
        }
        counters.gateVerdict = verdict

        let micSegments = micClusters.flatMap { cluster in
            cluster.intervals.map {
                DiarizedSegment(
                    speakerLabel: cluster.label,
                    startSeconds: $0.startSeconds,
                    endSeconds: $0.endSeconds)
            }
        }.sorted {
            ($0.startSeconds, $0.endSeconds, $0.speakerLabel)
                < ($1.startSeconds, $1.endSeconds, $1.speakerLabel)
        }
        let artifact = RoomTreatmentArtifact(
            micDiarization: DiarizationOutput(
                segments: micSegments, speakerCount: Set(micSegments.map(\.speakerLabel)).count),
            clusterCentroids: RoomClusterCentroids(
                mic: micCentroids, system: systemCentroids),
            gateVerdict: verdict,
            gateEvidence: evidence,
            profileVersion: profileUsable ? profile?.version : nil,
            ownerStamps: ownerStamps)
        return RoomTreatmentEvaluation(
            ladderRow: ladderRow, artifact: artifact, counters: counters)
    }

    public static func cosineDistance(_ lhs: [Float], _ rhs: [Float]) -> Double? {
        guard !lhs.isEmpty, lhs.count == rhs.count else { return nil }
        var dot = 0.0
        var leftNorm = 0.0
        var rightNorm = 0.0
        for index in lhs.indices {
            let left = Double(lhs[index])
            let right = Double(rhs[index])
            dot += left * right
            leftNorm += left * left
            rightNorm += right * right
        }
        guard leftNorm > 0, rightNorm > 0 else { return nil }
        return 1 - dot / (leftNorm.squareRoot() * rightNorm.squareRoot())
    }

    public static func maskedSeconds(
        candidate: [SpeechInterval], system: [SpeechInterval]
    ) -> Double {
        let candidateUnion = union(candidate)
        let systemUnion = union(system)
        var overlap = 0.0
        for candidate in candidateUnion {
            for remote in systemUnion {
                overlap += max(
                    0,
                    min(candidate.endSeconds, remote.endSeconds)
                        - max(candidate.startSeconds, remote.startSeconds))
            }
        }
        return max(0, measure(candidateUnion) - overlap)
    }

    private static func stampOwners(
        micClusters: [RoomSpeechCluster],
        evidence: [RoomGateEvidence],
        hasSystemSpeech: Bool,
        renamed: Set<String>,
        constants: RoomGateConstants,
        counters: inout RoomTreatmentCounters
    ) -> [String: OwnerStamp] {
        let evidenceByCluster = Dictionary(
            uniqueKeysWithValues: evidence.map { ($0.cluster, $0) })
        let systemMatched = Set(evidence.compactMap {
            hasSystemSpeech && ($0.sysDistance ?? .infinity) <= constants.systemDistanceThreshold
                ? $0.cluster : nil
        })
        // Matches count PRE-suppression: a match the bleed veto or a rename keeps
        // from being stamped still suppresses the default-you of rule 3, which
        // exists for the profile-silent case only.
        let profileMatched = Set(evidence.compactMap {
            ($0.profileDistance ?? .infinity) <= constants.profileDistanceThreshold
                ? $0.cluster : nil
        })
        let dominant = profileMatched.isEmpty
            ? micClusters.enumerated().filter { $0.element.centroid != nil }.max {
                let left = evidenceByCluster[$0.element.label]?.maskedSeconds ?? 0
                let right = evidenceByCluster[$1.element.label]?.maskedSeconds ?? 0
                return left == right ? $0.offset > $1.offset : left < right
            }?.element.label
            : nil

        return Dictionary(uniqueKeysWithValues: micClusters.map { cluster in
            let wantsUser =
                !systemMatched.contains(cluster.label)
                && (profileMatched.contains(cluster.label) || dominant == cluster.label)
            guard wantsUser else {
                return (cluster.label, OwnerStamp(decision: .anonymous))
            }
            if renamed.contains(cluster.label) {
                counters.stampsSuppressedByRename += 1
                return (
                    cluster.label,
                    OwnerStamp(decision: .anonymous, suppressedByRename: true)
                )
            }
            counters.ownerStampedClusters += 1
            return (cluster.label, OwnerStamp(decision: .user))
        })
    }

    private static func minimumDistance(
        from candidate: [Float]?, to references: [[Float]]
    ) -> Double? {
        guard let candidate else { return nil }
        return references.compactMap { cosineDistance(candidate, $0) }.min()
    }

    private static func union(_ intervals: [SpeechInterval]) -> [SpeechInterval] {
        let sorted = intervals
            .filter { $0.endSeconds > $0.startSeconds }
            .sorted {
                ($0.startSeconds, $0.endSeconds) < ($1.startSeconds, $1.endSeconds)
            }
        var result: [SpeechInterval] = []
        for interval in sorted {
            guard var last = result.popLast() else {
                result.append(interval)
                continue
            }
            if interval.startSeconds <= last.endSeconds {
                last.endSeconds = max(last.endSeconds, interval.endSeconds)
                result.append(last)
            } else {
                result.append(last)
                result.append(interval)
            }
        }
        return result
    }

    private static func measure(_ intervals: [SpeechInterval]) -> Double {
        intervals.reduce(0) { $0 + max(0, $1.endSeconds - $1.startSeconds) }
    }
}
