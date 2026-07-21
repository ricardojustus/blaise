import BlaiseCore
import FluidAudio
import Foundation

// C4 diarization eval harness. Re-runs the FluidAudio offline diarizer over
// retained meeting audio (system track) or fixture WAVs with a sweep of
// config variants, and scores each variant's cluster count against known
// ground truth. The strongest free ground truth: a captured 1:1's system
// track holds EXACTLY one remote speaker, so any 1:1 yielding > 1 cluster is
// a measured over-clustering error. Multi-party fixtures (ICSI) serve as the
// under-clustering canary in the same sweep.
//
// Usage:
//   DiarLab <dataRoot> --case <meetingID|wavPath>[:<expected>[:<attendees>]] ...
//           [--thresholds 0.6,0.7,0.8] [--repeat 1] [--json <out.json>]
//
//   <expected>  = ground-truth speaker count for THIS track ("?" = unknown)
//   <attendees> = calendar attendee count, to reproduce the production
//                 withSpeakers(min: 1, max: attendees + 1) hint variant
//
// The data root is read READ-ONLY (audio decoded to a temp dir); models load
// from the app's existing cache <dataRoot>/models/fluidaudio-diar.

struct EvalCase {
    let name: String
    let audioURL: URL
    let isM4A: Bool
    let expected: Int?
    let attendeeCount: Int?
}

struct RunResult: Codable {
    let caseName: String
    let variant: String
    let clusters: Int
    let transitions: Int
    let clusterSeconds: [String: Double]
    let expected: Int?
    let verdict: String
    let wallSeconds: Double
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("DiarLab: " + message + "\n").utf8))
    exit(1)
}

// MARK: - Argument parsing

var arguments = Array(CommandLine.arguments.dropFirst())
guard !arguments.isEmpty else {
    fail("usage: DiarLab <dataRoot> --case <id|wav>[:<expected>[:<attendees>]] [--thresholds 0.6,0.7] [--repeat 1] [--json out.json]")
}
let dataRoot = URL(fileURLWithPath: (arguments.removeFirst() as NSString).expandingTildeInPath, isDirectory: true)

var caseSpecs: [String] = []
var thresholds: [Double] = [0.6, 0.7, 0.8]
var repeatCount = 1
var jsonOutPath: String?
var index = 0
while index < arguments.count {
    switch arguments[index] {
    case "--case":
        index += 1
        guard index < arguments.count else { fail("--case needs a value") }
        caseSpecs.append(arguments[index])
    case "--thresholds":
        index += 1
        guard index < arguments.count else { fail("--thresholds needs a value") }
        thresholds = arguments[index].split(separator: ",").compactMap { Double($0) }
        guard !thresholds.isEmpty else { fail("--thresholds: no parseable values") }
    case "--repeat":
        index += 1
        guard index < arguments.count, let n = Int(arguments[index]), n >= 1 else { fail("--repeat needs a positive integer") }
        repeatCount = n
    case "--json":
        index += 1
        guard index < arguments.count else { fail("--json needs a path") }
        jsonOutPath = arguments[index]
    default:
        fail("unknown argument: \(arguments[index])")
    }
    index += 1
}
guard !caseSpecs.isEmpty else { fail("at least one --case required") }

let evalCases: [EvalCase] = caseSpecs.map { spec in
    let parts = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    let target = parts[0]
    let expected = parts.count > 1 ? Int(parts[1]) : nil
    let attendees = parts.count > 2 ? Int(parts[2]) : nil
    if target.hasSuffix(".wav") {
        let url = URL(fileURLWithPath: (target as NSString).expandingTildeInPath)
        return EvalCase(name: url.deletingPathExtension().lastPathComponent, audioURL: url, isM4A: false, expected: expected, attendeeCount: attendees)
    }
    // Meeting ID → the retained SYSTEM track (mic track is the user by
    // definition and is never diarized).
    let url = dataRoot.appendingPathComponent("meetings/\(target)/audio.m4a")
    return EvalCase(name: target, audioURL: url, isM4A: true, expected: expected, attendeeCount: attendees)
}
for evalCase in evalCases where !FileManager.default.fileExists(atPath: evalCase.audioURL.path) {
    fail("audio not found: \(evalCase.audioURL.path)")
}

// MARK: - Model load (once) + scratch

let modelsParent = dataRoot.appendingPathComponent("models/fluidaudio-diar", isDirectory: true)
let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("diarlab-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }

print("DiarLab: loading models from \(modelsParent.path) …")
let models = try await OfflineDiarizerModels.load(from: modelsParent)

// MARK: - Variants

struct Variant {
    let name: String
    let config: OfflineDiarizerConfig
}

@MainActor
func variants(for evalCase: EvalCase) -> [Variant] {
    var list: [Variant] = []
    for threshold in thresholds {
        var config = OfflineDiarizerConfig.default
        config.clustering.threshold = threshold
        list.append(Variant(name: String(format: "t=%.2f unconstrained", threshold), config: config))
        if let attendees = evalCase.attendeeCount {
            // Production behavior today: withSpeakers(min: 1, max: attendees + 1).
            list.append(Variant(
                name: String(format: "t=%.2f hint max=%d (prod)", threshold, attendees + 1),
                config: config.withSpeakers(min: 1, max: attendees + 1)))
            // Candidate fix for captured meetings: the system track excludes
            // the user, so the remote-speaker ceiling is attendees - 1 (+1
            // slack for an uninvited joiner) = attendees.
            list.append(Variant(
                name: String(format: "t=%.2f hint max=%d (sys-track)", threshold, attendees),
                config: config.withSpeakers(min: 1, max: attendees)))
            // Forced-count probe (shared-mic research): can an exact count
            // recover structure the unconstrained pass collapsed?
            list.append(Variant(
                name: String(format: "t=%.2f exactly %d", threshold, attendees),
                config: config.withSpeakers(exactly: attendees)))
        }
    }
    return list
}

// MARK: - Run

func summarize(_ segments: [TimedSpeakerSegment]) -> (clusters: Int, transitions: Int, seconds: [String: Double]) {
    let sorted = segments.sorted { ($0.startTimeSeconds, $0.endTimeSeconds) < ($1.startTimeSeconds, $1.endTimeSeconds) }
    var seconds: [String: Double] = [:]
    var transitions = 0
    var previousLabel: String?
    for segment in sorted {
        seconds[segment.speakerId, default: 0] += Double(segment.endTimeSeconds - segment.startTimeSeconds)
        if let previousLabel, previousLabel != segment.speakerId { transitions += 1 }
        previousLabel = segment.speakerId
    }
    return (seconds.count, transitions, seconds)
}

var results: [RunResult] = []
for evalCase in evalCases {
    let wavURL: URL
    if evalCase.isM4A {
        wavURL = scratch.appendingPathComponent("\(evalCase.name).wav")
        try AudioTranscoder.decodeTo16kWAV(m4a: evalCase.audioURL, destination: wavURL)
    } else {
        wavURL = evalCase.audioURL
    }
    let duration = try AudioTranscoder.duration(of: wavURL)
    print("\n=== \(evalCase.name)  (\(String(format: "%.0f", duration)) s, expected: \(evalCase.expected.map(String.init) ?? "?")) ===")

    for variant in variants(for: evalCase) {
        for attempt in 1 ... repeatCount {
            let started = Date()
            let manager = OfflineDiarizerManager(config: variant.config)
            manager.initialize(models: models)
            let clusters: Int
            let transitions: Int
            let seconds: [String: Double]
            do {
                let result = try await manager.process(wavURL)
                (clusters, transitions, seconds) = summarize(result.segments)
            } catch OfflineDiarizationError.noSpeechDetected {
                (clusters, transitions, seconds) = (0, 0, [:])
            }
            let wall = Date().timeIntervalSince(started)
            let verdict: String
            if let expected = evalCase.expected {
                verdict = clusters == expected ? "OK" : (clusters > expected ? "OVER by \(clusters - expected)" : "UNDER by \(expected - clusters)")
            } else {
                verdict = "-"
            }
            let secondsSummary = seconds.sorted { $0.value > $1.value }
                .map { "\($0.key)=\(String(format: "%.0f", $0.value))s" }
                .joined(separator: " ")
            let attemptSuffix = repeatCount > 1 ? " [run \(attempt)]" : ""
            print(String(
                format: "%-28@%@  clusters=%d transitions=%d  %@  %@  (%.1fs)",
                variant.name as NSString, attemptSuffix as NSString, clusters, transitions,
                verdict as NSString, secondsSummary as NSString, wall))
            results.append(RunResult(
                caseName: evalCase.name, variant: variant.name + attemptSuffix, clusters: clusters,
                transitions: transitions, clusterSeconds: seconds, expected: evalCase.expected,
                verdict: verdict, wallSeconds: wall))
        }
    }
}

if let jsonOutPath {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(results).write(to: URL(fileURLWithPath: (jsonOutPath as NSString).expandingTildeInPath))
    print("\nDiarLab: results written to \(jsonOutPath)")
}
