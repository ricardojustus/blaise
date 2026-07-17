import Foundation
import os

// MARK: - Pipeline version

public enum PipelineVersion {
    /// Format "<major>.<minor>"; bumped on ANY change that alters pipeline
    /// output — the Tier-1 byte-pin enforces honesty (an unbumped
    /// output-changing edit fails the pin). Travels in
    /// `NotesProvenance.pipelineVersion` (C7-owned constant).
    public static let current = "1.0"
}

// MARK: - Crash hooks (debug-only deterministic kill points)

/// `BLAISE_CRASH_AT` env hook (C7 crash harness; the C8 kill tests use the
/// same technique). No-op unless the env var names the point.
enum PipelineCrashPoint: String {
    /// Mid-ingest-encode: temp file fully written, before the atomic rename.
    case ingestEncode = "ingest-encode"
    /// Inside the stage-11 transaction (WAL atomicity evidence).
    case persistTranscript = "persist-transcript"
    /// Between the immutable payload write and `finalizeMeetingProcessing`.
    case preFinalize = "pre-finalize"
}

enum PipelineCrashHooks {
    static func maybeKill(_ point: PipelineCrashPoint) {
        if ProcessInfo.processInfo.environment["BLAISE_CRASH_AT"] == point.rawValue {
            kill(getpid(), SIGKILL)
            // SIGKILL delivery is asynchronous: kill() returns after POSTING
            // the signal, and the calling thread can execute a few more
            // instructions before the kernel stops it — observed slipping the
            // post-hook renamex_np through, which silently voids the
            // crash-point's guarantee. Never let the caller proceed.
            while true { usleep(1_000) }
        }
    }
}

// MARK: - Stages, events, errors

/// Stage order is normative (C7 spec v3.1): persistence happens ONCE, after
/// ALL naming (stage 11) — the round-1 audit Critical was LLM names applied
/// after the only persistence point and lost from every durable artifact.
public enum PipelineStage: String, Codable, Sendable, CaseIterable {
    case ingest, transcode, asr, diarize, merge, correct, languageStats,
        resolveSpeakers, notes, applyLLMNames, persistTranscript, persistNotes,
        finalize

    /// 1-based spec ordinal.
    var ordinal: Int { Self.allCases.firstIndex(of: self)! + 1 }
}

public enum PipelineEvent: Sendable, Equatable {
    case runStarted(MeetingID, regeneration: Bool)
    case stageBegan(MeetingID, PipelineStage)
    case stageFinished(MeetingID, PipelineStage)
    case runCompleted(MeetingID)
    case runFailed(MeetingID, stage: PipelineStage, message: String)
    /// G1 §5b: the user-glossary load that THIS run used, with its diagnostics
    /// and timestamp, ridden on the pipeline-activity observable (and
    /// unified-logged). Lets Settings show what a run actually loaded, not just
    /// its own on-demand "Check now".
    case glossaryLoaded(MeetingID, GlossaryDiagnostics, loadedAt: Date)
    /// G15: the participant-confirmation gate parked this meeting for the FIRST
    /// time (a fresh park — NOT a self-heal re-park). The app posts the
    /// "Confirm participants — <title>" notification once off this event, so the
    /// notification fires once per park, never per resume re-park.
    case participantConfirmationNeeded(MeetingID, title: String)
}

public struct PipelineError: Error, Sendable, CustomStringConvertible {
    public let stage: PipelineStage
    public let message: String

    public var description: String { "\(stage.rawValue): \(message)" }
}

/// G9: every programmatic dispatch funnels through `dispatchProcessing`,
/// whose refusal set now includes `paused` (defense in depth behind the
/// orphan-sweep kick gate) — no path may process a meeting held in `paused`
/// until End flips it to `processing`.
public enum PipelineDispatchError: Error, CustomStringConvertible {
    case meetingPaused(MeetingID)
    /// G10 §1: an AUTO-kick refused a user-cancelled meeting. The user's own
    /// Process / Regenerate are exempt (they pass `refuseCancelled: false`).
    case meetingCancelled(MeetingID)

    public var description: String {
        switch self {
        case .meetingPaused(let id):
            return "meeting \(id) is paused — End & process it first (no path may process a paused meeting)"
        case .meetingCancelled(let id):
            return "meeting \(id) was cancelled — only the user's Process re-runs it (no auto-kick)"
        }
    }
}

/// G10 §2: delete refusals. Delete joins the single-flight chain (serializing
/// against in-flight runs), so the only state it must refuse outright is
/// `recording` (the live writer holds the dir).
public enum PipelineDeleteError: Error, CustomStringConvertible {
    case meetingRecording(MeetingID)

    public var description: String {
        switch self {
        case .meetingRecording(let id):
            return "meeting \(id) is recording — stop it before deleting"
        }
    }
}

/// Named ingest error (spec stage 1): after a mid-ingest crash with the
/// import copy gone and no verified m4a, process() needs the source again.
public enum PipelineIngestError: Error, CustomStringConvertible {
    case sourceAudioRequired(MeetingID)
    case encodeVerificationFailed(String)

    public var description: String {
        switch self {
        case .sourceAudioRequired(let id):
            return "source audio required: meeting \(id) has no retained audio.m4a and no import copy — re-import the source WAV"
        case .encodeVerificationFailed(let detail):
            return "encoded audio failed the verification decode (\(detail)); lossless import copy retained"
        }
    }
}

// MARK: - Run record (evidence + Tier-2 assertions)

public struct AppliedCorrection: Codable, Sendable, Equatable {
    public let original: String
    public let canonical: String
    public let stage: String
}

public struct NotesFallbackRecord: Codable, Sendable, Equatable {
    public let primaryEngineID: String
    public let reason: String
    public let fallbackEngineID: String
}

/// Stage-9 resolution (D17): notes were produced, or the run resolved to
/// notes-pending (fallback-trigger failure with only a heavyweight fallback
/// registered — never auto-loaded; the meeting self-heals later).
enum NotesStageOutcome {
    case produced(NotesResult)
    case pending(reason: String)
}

/// What a run did — returned by `process`/`regenerate`, dumped by the mint
/// harness as evidence, consumed by Tier-2 assertions.
public struct PipelineRunRecord: Codable, Sendable {
    public var meetingID: MeetingID
    public var regeneration: Bool
    public var stageSeconds: [String: Double] = [:]
    public var asrSegmentCount = 0
    public var detectedLanguage: String?
    public var asrProvenance: ASRProvenance?
    public var diarizationSegmentCount = 0
    public var speakerCount = 0
    /// Full diarization output — the regression-pin mint commits it as a
    /// Tier-1 input (it is not persisted anywhere else).
    public var diarization: DiarizationOutput?
    public var mergeSplits = 0
    public var mergeDegenerateSegments = 0
    public var mergeGapAssignedWords = 0
    public var mergeHealedFragments = 0
    public var mergedSegmentCount = 0
    public var correctionCount = 0
    public var corrections: [AppliedCorrection] = []
    public var dominantLanguage: String?
    public var proposals: [SpeakerNameProposal] = []
    public var appliedNames: [String: String] = [:]
    public var namedSegmentCount = 0
    public var finalSegmentCount = 0
    public var notesEngineID: String?
    public var notesUsage: EngineUsage?
    public var fallback: NotesFallbackRecord?
    /// Set when the run resolved to notes-pending (D17): the primary's
    /// fallback-trigger reason. nil when notes were produced.
    public var notesPending: String?
    public var versionHash: String?
    public var payloadPath: String?
    /// Two-track capture runs (C11): which retained tracks fed this run.
    /// nil for file-first runs.
    public var capturedTracks: [String]?
    /// C14 multi-part runs: how many parts the transcode stitched (nil =
    /// file-first or single-part).
    public var stitchedParts: Int?
    /// C14 silence-hallucination guard: ASR segments dropped for lying
    /// entirely inside a structural stitched-gap range.
    public var gapDroppedSegments: Int?
    /// C7 v3.8 cross-track echo dedup: RAW mic-track ASR segments dropped
    /// pre-merge as acoustic echo of overlapping system audio (near-duplicate
    /// text under the user's label). Counts raw ASR segments, NOT merged
    /// turns. nil when none dropped or not a two-track run.
    public var echoDroppedSegments: Int?
    /// #101 (D10): how many grounded person-mention hints the digest run carried
    /// (presence-gated; 0 means no hint block was rendered). Provenance only —
    /// the hint text lives in the LLM USER MESSAGE, never in the artifact.
    public var groundedPersonHintCount = 0

    init(meetingID: MeetingID, regeneration: Bool) {
        self.meetingID = meetingID
        self.regeneration = regeneration
    }
}

// MARK: - Handoff kick seam

/// C8 wires the real `HandoffWorker` here; until it lands, the pipeline's
/// stage 13 kicks a no-op (the queue row is durable either way — the worker
/// drains it on its own wakes once it exists).
public protocol HandoffKicking: Sendable {
    func kick() async
}

public struct NoopHandoffKicker: HandoffKicking {
    public init() {}
    public func kick() async {}
}

// MARK: - ProcessingPipeline

/// The orchestrator (C7): retained audio → corrected, speaker-named
/// transcript + rendered notes + enqueued handoff. Single-flight FIFO
/// (one run in flight app-wide — the app constructs one pipeline);
/// cancellation kills the active stage's subprocess (engines' contract);
/// temp artifacts (decoded WAV) deleted on every exit path.
public actor ProcessingPipeline {
    private let database: BlaiseDatabase
    private let registry: EngineRegistry
    private let resolver: EngineResolver
    private let settings: SettingsStore
    private let diarizer: any Diarizing
    /// G1 §3: the vocabulary stack is rebuilt at EACH run start (the user
    /// glossary is hot-reloaded between runs). Tests/regression paths pass a
    /// constant provider over a `fixture()` stack. Returns the full `UserLoad`
    /// so its diagnostics ride the pipeline-activity observable (§5b, M-2).
    private let vocabularyProvider: @Sendable () -> PipelineVocabulary.UserLoad
    private let handoffKicker: any HandoffKicking
    private let meetEventsSweeper: any MeetEventsSweeping
    private let tempDirectory: URL
    private let now: @Sendable () -> Date
    private let chain = EngineTaskChain()
    private let logger = Logger(subsystem: BlaiseBundle.identifier, category: "pipeline")
    private var eventContinuations: [UUID: AsyncStream<PipelineEvent>.Continuation] = [:]

    /// G10 §1: per-meeting cancel tokens for in-flight runs. A run installs
    /// its token at entry (runBody) and removes it at exit; `cancel` sets the
    /// installed token (FIRST) so the run's stage checkpoints and the cloud
    /// engine's attempt-boundary checks both observe it. Absence of a token
    /// IS the idleness key the §1 no-op rule needs: a meeting with no run in
    /// flight has no token, so its cancel is a no-op.
    private var cancelTokens: [MeetingID: RunCancelHandle] = [:]

    /// The in-flight run's cancel token plus its CLASS (the status write is
    /// class-aware: process-class cancel writes `cancelled`; regeneration and
    /// notes-resume cancels are status-silent — the run aborts at its next
    /// checkpoint and the meeting stays at its prior status, C1 no-regress).
    private final class RunCancelHandle {
        let token: CancellationToken
        /// True for regeneration AND notes-resume runs (both are
        /// status-silent on cancel). False for first-processing (process /
        /// processCaptured / dispatchProcessing-of-a-non-ready meeting).
        let statusSilent: Bool
        /// Cancels the run's stage-work child task — this is what kills a
        /// running local subprocess (whisper SIGTERM→SIGKILL) and trips the
        /// diarizer's cooperative flag via Swift task cancellation. Set by the
        /// run after it spawns the child task; the cloud attempt is shielded
        /// from this cancellation (it binds the token at attempt boundaries).
        var cancelTask: (@Sendable () -> Void)?

        init(token: CancellationToken, statusSilent: Bool) {
            self.token = token
            self.statusSilent = statusSilent
        }
    }

    /// Per-run vocabulary provider (G1 §3): the app passes
    /// `{ PipelineVocabulary.user(dataRoot:).vocabulary }`; tests pass a
    /// constant `fixture()` stack via the convenience overload below.
    public init(
        database: BlaiseDatabase,
        registry: EngineRegistry,
        diarizer: any Diarizing,
        vocabularyProvider: @escaping @Sendable () -> PipelineVocabulary.UserLoad,
        handoffKicker: any HandoffKicking = NoopHandoffKicker(),
        meetEventsSweeper: any MeetEventsSweeping = NoopMeetEventsSweeper(),
        tempDirectory: URL = FileManager.default.temporaryDirectory,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.database = database
        self.registry = registry
        self.settings = SettingsStore(database: database)
        self.resolver = EngineResolver(registry: registry, settings: settings)
        self.diarizer = diarizer
        self.vocabularyProvider = vocabularyProvider
        self.handoffKicker = handoffKicker
        self.meetEventsSweeper = meetEventsSweeper
        self.tempDirectory = tempDirectory
        self.now = now
    }

    /// Convenience overload for a CONSTANT vocabulary stack (tests, regression
    /// pins, CrashRunner): the same `fixture()` stack is reused every run.
    public init(
        database: BlaiseDatabase,
        registry: EngineRegistry,
        diarizer: any Diarizing,
        vocabulary: PipelineVocabulary,
        handoffKicker: any HandoffKicking = NoopHandoffKicker(),
        meetEventsSweeper: any MeetEventsSweeping = NoopMeetEventsSweeper(),
        tempDirectory: URL = FileManager.default.temporaryDirectory,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            database: database, registry: registry, diarizer: diarizer,
            vocabularyProvider: {
                PipelineVocabulary.UserLoad(
                    vocabulary: vocabulary, diagnostics: GlossaryDiagnostics(), loadedAt: now())
            },
            handoffKicker: handoffKicker,
            meetEventsSweeper: meetEventsSweeper, tempDirectory: tempDirectory, now: now)
    }

    // MARK: - Progress

    /// Progress events for all runs (C10's indeterminate UI). Multiple
    /// subscribers supported; each gets its own stream.
    public func events() -> AsyncStream<PipelineEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            eventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        eventContinuations[id] = nil
    }

    private func emit(_ event: PipelineEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    /// G1 §5b (M-2): ride the run's user-glossary load on the pipeline-activity
    /// observable AND unified-log it, so Settings (and the logs) reflect what a
    /// run actually loaded, not just the editor's on-demand "Check now".
    private func reportGlossaryLoad(_ load: PipelineVocabulary.UserLoad, meetingID: MeetingID) {
        let d = load.diagnostics
        emit(.glossaryLoaded(meetingID, d, loadedAt: load.loadedAt))
        logger.info(
            "glossary load (run \(meetingID)): parsed=\(d.parsedEntries) effective=\(d.effectiveEntries) aliasesAdmitted=\(d.aliasesAdmitted) canonicalsLimited=\(d.canonicalsLimited) items=\(d.items.count)")
    }

    // MARK: - Import seam (AC5; widened per the C10 amendment)

    /// Creates the meeting row + directory and takes ownership of the source
    /// audio (hard floor 2). The seam is WIDENED from the original WAV-only
    /// form (C10 amendment, recorded in the C7 changelog): `sourceURL` may be
    /// WAV or M4A.
    ///
    /// - WAV → copied into the meeting dir as `import.wav`; stage 1 encodes.
    /// - M4A → it already IS the retained format: copied in as `audio.m4a`
    ///   and VERIFIED (decodable, with a duration) before the meeting row
    ///   exists; stage 1's encode is skipped by construction.
    ///
    /// `startedAt` and `meetingCode` persist on the row; `endedAt` = start +
    /// audio duration. Status starts `processing` (a crash before
    /// `process()` runs is swept to `failed` at next launch — honest,
    /// recoverable). A non-nil meeting code triggers a pending-events sweep.
    @discardableResult
    public func importMeeting(
        sourceURL: URL,
        title: String,
        startedAt: Date? = nil,
        attendees: [Attendee] = [],
        meetingCode: String? = nil
    ) async throws -> Meeting {
        let isM4A = sourceURL.pathExtension.lowercased() == "m4a"
        // Boundary validation up front: WAV header / M4A verification decode.
        let duration: Double
        if isM4A {
            duration = try AudioTranscoder.duration(of: sourceURL)
        } else {
            duration = try WAVHeader.read(at: sourceURL).duration
        }
        let id = ULID.generate()
        let started = startedAt ?? now()
        let meeting = Meeting(
            id: id,
            title: title,
            startedAt: started,
            endedAt: started.addingTimeInterval(duration),
            source: .imported,
            status: .processing,
            attendees: attendees,
            meetingCode: meetingCode,
            createdAt: now(),
            updatedAt: now()
        )
        try database.paths.createMeetingDirectory(id)
        let destination = isM4A ? database.paths.audioURL(id) : database.paths.importCopyURL(id)
        let temp = database.paths.meetingDirectory(id)
            .appendingPathComponent(".import.tmp-\(UUID().uuidString)")
        do {
            try FileManager.default.copyItem(at: sourceURL, to: temp)
            if isM4A {
                // Verify the COPY (not just the source) before the rename.
                let copiedDuration = try AudioTranscoder.duration(of: temp)
                guard abs(copiedDuration - duration) <= 0.5 else {
                    throw PipelineIngestError.encodeVerificationFailed(
                        "copied m4a duration \(copiedDuration) vs source \(duration)")
                }
            }
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        try await MeetingRepository(database: database).create(meeting)
        if meetingCode != nil {
            await meetEventsSweeper.sweep(meetingID: id)
        }
        return meeting
    }

    // MARK: - Entry points (single-flight FIFO chain)

    /// Full processing of an imported meeting. Sets `status = processing` at
    /// entry; failure → `failed` + stage-tagged `lastProcessingError`.
    /// `sourceWAV` is only consulted when both the retained audio and the
    /// import copy are missing (post-crash re-import path).
    @discardableResult
    public func process(meetingID: MeetingID, sourceWAV: URL? = nil) async throws -> PipelineRunRecord {
        try await chain.run {
            try await self.runBody(
                meetingID: meetingID, sourceWAV: sourceWAV, regeneration: false, captured: false)
        }
    }

    /// Captured-meeting variant (C11; C7 v3.2 body amendment): two retained
    /// tracks, ASR per track, mic track labeled `user`/named UserIdentity at
    /// creation, system track diarized+merged, interleave with the pinned
    /// tie-break, correction onward unchanged. process()-class semantics
    /// (status = processing at entry; failure → failed).
    @discardableResult
    public func processCaptured(meetingID: MeetingID) async throws -> PipelineRunRecord {
        try await chain.run {
            try await self.runBody(
                meetingID: meetingID, sourceWAV: nil, regeneration: false, captured: true)
        }
    }

    /// Regeneration from retained audio: NEVER runs ingest; status untouched
    /// (C1 no-regress — a failed regeneration keeps `ready`); `processingNote`
    /// cleared at entry (C6 lifecycle; capture-recovery notes survive — C7
    /// v3.3). Dispatches by the captured-meeting key (C7 v3.2 / C11 v4):
    /// the durable `meeting.captured` flag OR a present `audio_mic.m4a` →
    /// the two-track variant; a captured meeting can never be silently
    /// halved by the single-track path, even when its mic track was lost.
    @discardableResult
    public func regenerate(meetingID: MeetingID) async throws -> PipelineRunRecord {
        let meeting = try await MeetingRepository(database: database).fetch(meetingID)
        let captured = (meeting?.captured ?? false) || hasMicTrack(meetingID)
        return try await chain.run {
            try await self.runBody(
                meetingID: meetingID, sourceWAV: nil, regeneration: true, captured: captured)
        }
    }

    /// Status-dependent dispatch (C10 rule for EVERY programmatic kick):
    /// `ready` → regeneration class (never-regress), non-ready → process
    /// class — both captured-aware (C11). `ProcessingDispatching.dispatch`
    /// (the listener's post-ready re-mint trigger) funnels here too,
    /// swallowing failures — the run records them.
    ///
    /// The status fetch and the process-vs-regenerate decision happen INSIDE
    /// the chained body: the D17 notes-pending healer flips failed → ready
    /// as a background event, so a decision taken outside the chain could
    /// queue a stale process()-class run against a now-ready meeting and
    /// regress it to failed on any stage failure (C1 no-regress violated).
    /// Chained, a kick racing a resume sees the resume's terminal state.
    ///
    /// G9: `paused` is refused here (defense in depth behind §2's orphan-sweep
    /// kick gate). A meeting held in `paused` has its CAFs encoded by the
    /// sweep for retention but is never processed until End flips it to
    /// `processing`. The check is INSIDE the chain so a kick racing a
    /// pause/resume/End transaction sees the committed terminal status.
    ///
    /// G10 §1: `refuseCancelled` is the AUTO-KICK guard. Every automatic
    /// dispatch (the capture sweep kick, the launch re-dispatch, the listener
    /// post-ready re-mint seam, the meeting-code-edit sweep) passes `true`: a
    /// `cancelled` meeting is a sanctioned terminal state the user chose, and
    /// no auto path may flip it back to processing/failed. The user's own
    /// Process action and explicit Regenerate pass the default `false` — they
    /// ARE the sanctioned exits from `cancelled` (no deadlock). The check is
    /// INSIDE the chain so it sees the committed status.
    @discardableResult
    public func dispatchProcessing(
        meetingID: MeetingID, refuseCancelled: Bool = false
    ) async throws -> PipelineRunRecord {
        try await chain.run {
            guard
                let meeting = try await MeetingRepository(database: self.database).fetch(meetingID)
            else {
                throw BlaiseDatabaseError.meetingNotFound(meetingID)
            }
            guard meeting.status != .paused else {
                throw PipelineDispatchError.meetingPaused(meetingID)
            }
            if refuseCancelled, meeting.status == .cancelled {
                throw PipelineDispatchError.meetingCancelled(meetingID)
            }
            var captured = meeting.captured
            if !captured { captured = await self.hasMicTrack(meetingID) }
            return try await self.runBody(
                meetingID: meetingID, sourceWAV: nil,
                regeneration: meeting.status == .ready, captured: captured)
        }
    }

    /// The file-presence half of the captured-meeting dispatch key (C7
    /// v3.2): a retained mic track marks a captured meeting even on rows
    /// predating the durable `captured` flag. File-first imports never have
    /// one, so they are unaffected.
    private func hasMicTrack(_ meetingID: MeetingID) -> Bool {
        FileManager.default.fileExists(atPath: database.paths.audioMicURL(meetingID).path)
    }

    // MARK: - Cancel (G10 §1)

    /// Whether a run is in flight for this meeting (a token is installed). The
    /// §1 no-op is keyed on this, NOT on status — a regeneration runs against
    /// a `ready` meeting, so status cannot distinguish a running regen from an
    /// idle ready meeting. The detail-view click handler reads this to decide
    /// whether Cancel does anything.
    public func hasRunInFlight(_ meetingID: MeetingID) -> Bool {
        cancelTokens[meetingID] != nil
    }

    /// Cancel an in-flight run for `meetingID`. Commits FIRST (sets the token
    /// before the status write), so no cloud send can start after this returns
    /// even if the status transaction is momentarily delayed. The status write
    /// is CLASS-AWARE: a FIRST-processing run writes `cancelled` (its own
    /// transaction, synchronously); a REGENERATION or notes-resume run is
    /// status-silent (the meeting stays at its prior status — C1 no-regress;
    /// completed-stage artifact writes that already persisted remain,
    /// crash-resume-consistent, and surface on the next successful run). The
    /// terminal-write guards (`recordFailure`, `writeNotesPending`) preserve a
    /// committed `cancelled`. Cancel with NO run in flight is a no-op (no
    /// token). Returns true when a run was actually signalled.
    @discardableResult
    public func cancel(meetingID: MeetingID) async -> Bool {
        guard let handle = cancelTokens[meetingID] else { return false }
        // Token FIRST (the order pin): binds at the next stage checkpoint and
        // the next cloud attempt boundary.
        handle.token.cancel()
        // Then drive Swift task cancellation of the run's stage work — this is
        // what kills a running local subprocess (whisper SIGTERM→SIGKILL) and
        // trips the diarizer's cooperative flag mid-stage. The in-flight cloud
        // attempt is shielded from this (Task.detached) and binds the token at
        // its next attempt boundary instead.
        handle.cancelTask?()
        // Then the class-aware status write, in its own transaction. Only
        // first-processing writes `cancelled`; regen/notes-resume stay silent.
        if !handle.statusSilent {
            // The cancel's status write is the DURABLE cancel record; it must
            // always commit, so it is shielded from task cancellation (detached
            // — GRDB writes are cancellation-aware, and the caller may itself
            // be a task that is about to be cancelled). The terminal-write
            // guards then preserve this committed `cancelled`.
            //
            // G10 §1 (H-2 / L-1): the LOSER RULE. cancel-vs-completion =
            // whichever commits first wins; a completed meeting stays completed.
            // The token is removed only in `runBody`'s exit `defer`, which fires
            // AFTER `runStages` returns — and `runStages` runs the post-finalize
            // handoff kick / terminal-note / `.runCompleted` emit. So a token is
            // still installed for a window AFTER `finalizeMeetingProcessing`
            // committed `ready`. An unguarded write here would overwrite that
            // finished meeting `ready → cancelled` (notes intact, handoff
            // possibly already delivered) — contradicting the pinned AC and
            // mislabelling delivered work. The predicate `status == .processing`
            // (read-then-update in ONE write transaction) is the loser guard: a
            // FIRST-processing run is `.processing` (writeRunEntry sets it) until
            // its finalize commits `.ready`, so only a still-in-flight first run
            // flips to `cancelled`; a meeting that already terminally committed
            // (ready / failed) — or that an installed token names but which is
            // no longer processing — stays untouched.
            let database = self.database
            let timestamp = now()
            await Task.detached {
                try? await database.pool.write { db in
                    guard var meeting = try Meeting.fetchOne(db, key: meetingID) else { return }
                    guard meeting.status == .processing else { return }
                    meeting.status = .cancelled
                    meeting.updatedAt = timestamp
                    try meeting.update(db)
                }
            }.value
        }
        logger.notice(
            "cancel signalled for \(meetingID, privacy: .public) (statusSilent: \(handle.statusSilent, privacy: .public))")
        return true
    }

    // MARK: - Delete (G10 §2, tombstone-disciplined)

    /// Delete a meeting. JOINS THE SINGLE-FLIGHT CHAIN, so it serializes
    /// against every in-chain run for it (processing / regeneration /
    /// notes-resume) — the chain slot runs only after any in-flight run for
    /// the meeting has exited. Refuses a `recording` meeting (its live writer
    /// holds the dir). A `paused` meeting deletes DIRECTLY (it has no in-flight
    /// run — G9's sweep/dispatch refusal of `paused` is precisely why); the
    /// app-layer wrapper clears the paused teardown + holder mirror.
    ///
    /// "Cancel & Delete" is the caller setting the cancel token FIRST (via
    /// `cancel`, class-aware exactly as §1) and THEN enqueueing this — the
    /// in-flight run winds down at its next checkpoint and this slot runs after
    /// it exits.
    ///
    /// The erasure + tombstone + dir removal is `MeetingDeletion`. `midDeleteHook`
    /// is the AC3 crash-test seam (between the erase-commit and the dir
    /// removal).
    public func deleteMeeting(
        meetingID: MeetingID,
        midDeleteHook: (@Sendable () throws -> Void)? = nil
    ) async throws {
        try await chain.run {
            guard
                let meeting = try await MeetingRepository(database: self.database).fetch(meetingID)
            else {
                // Already gone (a double-delete, or the row never existed):
                // no-op. Any owed dir removal is the tombstone sweep's job.
                return
            }
            guard meeting.status != .recording else {
                throw PipelineDeleteError.meetingRecording(meetingID)
            }
            let tombstone = try await MeetingDeletion.eraseAndTombstone(
                database: self.database, meetingID: meetingID, now: self.now(),
                midTransactionHook: midDeleteHook)
            // Steps 2+3: remove the dir, clear the tombstone. A crash here
            // leaves the tombstone for the launch sweep (residue, never loss).
            await MeetingDeletion.removeDirAndClear(database: self.database, tombstone: tombstone)
        }
    }

    // MARK: - Rename (V1.1; C10 amendment)

    /// Title rename (inline edit in the detail view). The title is a
    /// payload-builder input AND the renderer's H1 fallback, so a rename is
    /// a CONTENT mutation (C1 v6.9: `updatedAt` bumps) — unlike the
    /// meetingCode metadata edit. On a `ready` meeting the rename therefore
    /// re-mints DETERMINISTICALLY (no engine calls — the structured notes
    /// are unchanged; only the rendered markdown's H1 fallback and the
    /// payload's title/updated_at/markdown fields move): re-render markdown
    /// → export notes.md → build payload → immutable write → notes upsert +
    /// enqueue of the new hash in one transaction → worker kick.
    /// The OLD queued payload is closed by the D12 supersession sweep when
    /// the new one delivers; its on-disk file stays hash-valid, so it
    /// remains deliverable (and visibly superseded) — never silently lost.
    /// A full `regenerate()` here would burn an LLM call and minutes of
    /// compute to change one string; rejected.
    ///
    /// Non-ready meetings just take the title + updatedAt write: no payload
    /// exists to invalidate, and the next content run mints with the new
    /// title. Runs on the single-flight chain — a rename can never interleave
    /// with a run's snapshot/mint window. By design that also means a rename
    /// submitted while a processing run is in flight QUEUES behind it and
    /// applies only when the run drains (the caller awaits silently; the UI
    /// shows the old title until then).
    ///
    /// Crash window (documented, same class as D17 L-2): a crash between
    /// the title write and the finalize leaves the rename local-only — the
    /// already-queued payload (old title) still delivers from its intact
    /// file; the renamed title reaches the evidence store on the next
    /// content run. Returns true when a re-mint happened.
    @discardableResult
    public func renameMeeting(meetingID: MeetingID, to newTitle: String) async throws -> Bool {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }
        return try await chain.run {
            let timestamp = self.now()
            let updated = try await self.database.pool.write { db -> Meeting? in
                guard let existing = try Meeting.fetchOne(db, key: meetingID) else {
                    throw BlaiseDatabaseError.meetingNotFound(meetingID)
                }
                // An identical title is a no-op (no content change → no
                // re-mint, no updatedAt bump). A genuine rename is the user's
                // authority and claims the USER tier.
                guard existing.title != title else { return nil }
                // G12 USER tier (top of the ladder): a surgical write of only
                // the columns the rename owns — `title`, `title_source`,
                // `updated_at` — never a full-row write that could clobber a
                // concurrently-changed column.
                try db.execute(
                    sql: "UPDATE meeting SET title = ?, title_source = ?, updated_at = ? WHERE id = ?",
                    arguments: [title, TitleSource.user.rawValue, timestamp, meetingID])
                // Stored-row discipline (the finalize/enqueue pattern): mint
                // from the row a later fetch would RETURN, not the in-memory
                // value — storage rounds dates to the millisecond.
                return try Meeting.fetchOne(db, key: meetingID)
            }
            // Notes-pending ready meetings (D17 regeneration-class) skip the
            // re-mint: the marker must survive (a finalize-shaped write would
            // cancel the self-heal), and the heal's own finalize mints with
            // the renamed title (its run re-fetches the meeting row).
            guard let meeting = updated, meeting.status == .ready,
                !NotesPendingClass.isPending(meeting.lastProcessingError),
                var notes = try await NotesRepository(database: self.database)
                    .fetch(meetingID: meetingID)
            else { return false }

            // Deterministic re-mint from the now-final DB state (the
            // stage-13 shape, minus the engine work). NOT
            // `finalizeMeetingProcessing`: the rename is not a processing
            // run, so run bookkeeping (`lastProcessingError`) stays
            // untouched; status is already `ready`. Notes upsert + enqueue
            // still commit in ONE transaction.
            let user = await self.userIdentity()
            let segments = try await TranscriptRepository(database: self.database)
                .segments(meetingID: meetingID)
            // G13: neutralize S-labels as the LAST write to notes.structured
            // before the render — render, build(), notes file, upsert all
            // derive from this one neutralized value.
            let labelMap = await self.slabelMap(meetingID: meetingID, segments: segments)
            notes.structured = SLabelNeutralizer.neutralize(
                notes: notes.structured, labelMap: labelMap, language: notes.language).notes
            notes.markdown = try NotesRenderer.render(
                notes.structured, language: notes.language, meetingTitle: title,
                userName: user.name)
            try Data(notes.markdown.utf8).write(
                to: self.database.paths.notesURL(meetingID), options: .atomic)
            let payload = EvidencePayloadBuilder.build(
                meeting: meeting, segments: segments, notes: notes,
                user: user)
            let relativePath = self.database.paths.relativeHandoffPayloadPath(
                meetingID: meetingID, versionHash: payload.versionHash)
            try ImmutablePayloadWriter.write(
                payload.bytes, to: self.database.rootURL.appendingPathComponent(relativePath))
            let rootURL = self.database.rootURL
            try await self.database.pool.write { [notes] db in
                try notes.upsert(db)
                _ = try HandoffRepository.enqueue(
                    db, rootURL: rootURL, meetingID: meetingID,
                    versionHash: payload.versionHash, payloadPath: relativePath)
            }
            await self.handoffKicker.kick()
            return true
        }
    }

    // MARK: - Speaker rename (G2 §4)

    /// Click a speaker label → rename. Upserts the `speaker_rename` row
    /// (anchor = midpoint of the cluster's longest segment in the persisted
    /// diarization), re-applies all rename rows to the transcript, re-persists
    /// it, and re-mints the payload DETERMINISTICALLY — NO engine call (the
    /// structured notes are unchanged; only speaker names + the re-rendered
    /// markdown/payload move). Runs on the single-flight chain.
    ///
    /// On a `ready` meeting this re-mints (notes upsert + enqueue in one
    /// transaction); on a non-ready meeting it only writes the rename row, and
    /// the next content run applies it. Store rule-1/3 normalization (one
    /// surface, no parentheticals) is applied to the rename input.
    @discardableResult
    public func renameSpeaker(
        meetingID: MeetingID, speakerLabel: String, to newName: String
    ) async throws -> Bool {
        // §4: store rule-1/3 normalization applies to rename input too — a user
        // renaming to the misheard surface they SEE ("marsa") durably stores the
        // corrected name ("Dana Marsh") when a store row / polish canonical
        // covers it, not the mishearing.
        let renameContext = await renameNormalizationContext()
        let name = NameSubstitution.normalizeRename(newName, context: renameContext)
        guard !name.isEmpty else { return false }
        return try await chain.run {
            let timestamp = self.now()
            let diarization = await self.loadPersistedDiarization(meetingID: meetingID)
                ?? DiarizationOutput(segments: [], speakerCount: 0)
            // M1: build the rename row ONCE and commit it ATOMICALLY with the
            // transcript it is applied to (a separate upfront upsert opened a
            // crash window: row committed but the transcript still old, which the
            // live rename-render in MeetingDetailView then showed while the notes
            // lagged). The row is applied to the segments in memory below and
            // saved inside `persistTranscript`'s transaction.
            let renameRow = SpeakerRenameStore.makeRow(
                meetingID: meetingID, speakerLabel: speakerLabel, name: name,
                diarization: diarization, now: timestamp)

            guard let meeting = try await MeetingRepository(database: self.database)
                .fetch(meetingID), meeting.status == .ready,
                !NotesPendingClass.isPending(meeting.lastProcessingError),
                var notes = try await NotesRepository(database: self.database)
                    .fetch(meetingID: meetingID)
            else {
                // Non-ready / pending: no transcript to re-mint — record the row
                // alone; the next content run applies it.
                try await self.database.pool.write { db in try renameRow.save(db) }
                return false
            }

            // Re-apply all rename rows over the persisted transcript and
            // re-persist (content mutation → updatedAt bumps before the mint).
            let existing = try await self.database.pool.read { db in
                try SpeakerRenameStore.all(db, meetingID: meetingID)
            }
            let segments = try await TranscriptRepository(database: self.database)
                .segments(meetingID: meetingID)
            // M3: capture the speaker's PRIOR resolved name (before the rename
            // is applied to the persisted transcript) so the stored digest's
            // mentions of the old name can be deterministically rewritten to the
            // new name below — no LLM call. An unresolved speaker (no prior
            // name, or a neutral descriptor in the digest) yields no match and
            // the digest reproduces unchanged.
            let priorSpeakerName = segments.first { $0.speakerLabel == speakerLabel }?.speakerName
            if let digest = notes.memoryDigest, let priorName = priorSpeakerName,
                !priorName.isEmpty, priorName != name
            {
                notes.memoryDigest = NameSubstitution.applyTextCorrection(
                    text: digest, original: priorName, replacement: name).text
            }
            // Effective rename set = existing rows (this label's prior row dropped)
            // plus the new row, matching what the store would hold post-upsert.
            let effective = existing.filter { $0.speakerLabel != speakerLabel } + [renameRow]
            let renamed = SpeakerRenameStore.applyRenames(effective, to: segments)
            if renamed != segments,
                let asrProvenance = meeting.asrProvenance,
                let dominantLanguage = meeting.dominantLanguage
            {
                _ = try await self.database.persistTranscript(
                    meetingID: meetingID, segments: renamed, asrProvenance: asrProvenance,
                    dominantLanguage: dominantLanguage, updatedAt: timestamp,
                    additionalWrites: { db in try renameRow.save(db) })
                try await self.exportTranscriptJSON(
                    meetingID: meetingID, segments: renamed,
                    provenance: asrProvenance, dominantLanguage: dominantLanguage)
            } else {
                // No transcript change (stale row / same name): record the row
                // alone — there is no transcript re-persist to fold it into.
                try await self.database.pool.write { db in try renameRow.save(db) }
            }

            // Deterministic re-mint (the renameMeeting pattern): re-render the
            // markdown (structured notes unchanged), re-build + write the
            // payload, notes upsert + enqueue in one transaction, kick.
            guard let finalMeeting = try await MeetingRepository(database: self.database)
                .fetch(meetingID)
            else { return false }
            let user = await self.userIdentity()
            let finalSegments = try await TranscriptRepository(database: self.database)
                .segments(meetingID: meetingID)
            // G13: this is where "I name S0 in a note and it populates" works —
            // the rename row now also substitutes into notes.structured (layer 1),
            // and any still-unresolved label is neutralized (layer 2).
            let labelMap = await self.slabelMap(meetingID: meetingID, segments: finalSegments)
            notes.structured = SLabelNeutralizer.neutralize(
                notes: notes.structured, labelMap: labelMap, language: notes.language).notes
            notes.markdown = try NotesRenderer.render(
                notes.structured, language: notes.language, meetingTitle: finalMeeting.title,
                userName: user.name)
            try Data(notes.markdown.utf8).write(
                to: self.database.paths.notesURL(meetingID), options: .atomic)
            let payload = EvidencePayloadBuilder.build(
                meeting: finalMeeting, segments: finalSegments, notes: notes,
                user: user)
            let relativePath = self.database.paths.relativeHandoffPayloadPath(
                meetingID: meetingID, versionHash: payload.versionHash)
            try ImmutablePayloadWriter.write(
                payload.bytes, to: self.database.rootURL.appendingPathComponent(relativePath))
            let rootURL = self.database.rootURL
            try await self.database.pool.write { [notes] db in
                try notes.upsert(db)
                _ = try HandoffRepository.enqueue(
                    db, rootURL: rootURL, meetingID: meetingID,
                    versionHash: payload.versionHash, payloadPath: relativePath)
            }
            await self.handoffKicker.kick()
            return true
        }
    }

    // MARK: - Correct-name flow (G2 §5)

    /// §2 store write for the "Remember this correction" checkbox: writes the
    /// row through the §2(a–d) normalization, computing the everyday flag from
    /// the run lexicon. Returns the write result so the UI can surface a (d)
    /// conflict. Does NOT touch any meeting (the store is cross-meeting).
    @discardableResult
    public func rememberCorrection(
        mishearedSurface: String, replacement: String, sourceMeetingID: MeetingID?
    ) async throws -> NameCorrectionStore.WriteResult {
        let now = self.now()
        let isEveryday = Self.everydayClosure()
        return try await database.pool.write { db in
            try NameCorrectionStore.upsert(
                db, mishearedSurface: mishearedSurface, replacement: replacement,
                sourceMeetingID: sourceMeetingID, now: now, isEveryday: isEveryday)
        }
    }

    /// §5 position-scoped notes correction: replaces the selected surface in
    /// the persisted notes (one occurrence by default, or all N identical when
    /// `allOccurrences`), then re-renders + re-mints the payload
    /// DETERMINISTICALLY — no engine call. An un-remembered correction fixes
    /// THESE notes only (regeneration recomputes from the store). Runs on the
    /// single-flight chain. Returns the number of occurrences replaced.
    @discardableResult
    public func correctNameInNotes(
        meetingID: MeetingID, original: String, replacement: String, allOccurrences: Bool,
        occurrenceIndex: Int? = nil
    ) async throws -> Int {
        // M-3: a NOTES replacement is used verbatim (only trimmed) — the
        // rename-input X-(Y) parenthetical heuristic does NOT belong here. It
        // would turn "Sammy (PM)" into "PM" in the notes while rememberCorrection
        // stores the RAW surface, diverging the visible fix from the saved row.
        let clean = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return 0 }
        return try await chain.run {
            let timestamp = self.now()
            guard let meeting = try await MeetingRepository(database: self.database)
                .fetch(meetingID), meeting.status == .ready,
                !NotesPendingClass.isPending(meeting.lastProcessingError),
                var notes = try await NotesRepository(database: self.database)
                    .fetch(meetingID: meetingID)
            else { return 0 }

            let (edited, count) = NameSubstitution.applyNoteCorrection(
                notes: notes.structured, original: original, replacement: clean,
                allOccurrences: allOccurrences, occurrenceIndex: occurrenceIndex)
            guard count > 0 else { return 0 }
            // M3: a name correction also rewrites the STORED digest string
            // deterministically (no LLM call) — every fold-equal mention of the
            // old name becomes the corrected name, so the digest's names stay in
            // lockstep with the notes. A non-name edit never reaches here.
            if let digest = notes.memoryDigest {
                notes.memoryDigest = NameSubstitution.applyTextCorrection(
                    text: digest, original: original, replacement: clean).text
            }
            let user = await self.userIdentity()
            var segments = try await TranscriptRepository(database: self.database)
                .segments(meetingID: meetingID)

            // G2 §5 speaker-layer unification (NH-D): when the ORIGINAL surface
            // fold-equals the CURRENT FULL display name of one or more resolved
            // speaker labels, the same confirmed correction ALSO corrects the
            // speaker layer — a §4 rename row per matching label (replacement
            // normalized through store rule-1/3, anchor per §4), re-applied to the
            // persisted transcript + the exported transcript JSON in THIS same
            // re-mint. Invariant: the re-minted payload's transcript speaker names
            // and its notes can never disagree about a person the user just
            // corrected. Fold-equality is against the FULL name (a bare-surname
            // prose correction never touches a "Dana Rosso" label); the notes
            // occurrence/apply-to-all scoping governs NOTES fields only — a label
            // is a single value and always updates wholly.
            let originalFold = VocabNormalization.canonicalMode(original)
            let matchingLabels = Set(segments.compactMap { segment -> String? in
                guard let name = segment.speakerName, !name.isEmpty,
                    VocabNormalization.canonicalMode(name) == originalFold
                else { return nil }
                return segment.speakerLabel
            })
            if !matchingLabels.isEmpty,
                let asrProvenance = meeting.asrProvenance,
                let dominantLanguage = meeting.dominantLanguage
            {
                let renameContext = await self.renameNormalizationContext()
                let renameName = NameSubstitution.normalizeRename(clean, context: renameContext)
                if !renameName.isEmpty {
                    let diarization = await self.loadPersistedDiarization(meetingID: meetingID)
                        ?? DiarizationOutput(segments: [], speakerCount: 0)
                    // M1: build the rename rows ONCE, apply them to segments in
                    // memory, and commit them ATOMICALLY with the transcript
                    // persist (no window where the rows exist but the transcript
                    // and notes still show the old name).
                    let existing = try await self.database.pool.read { db in
                        try SpeakerRenameStore.all(db, meetingID: meetingID)
                    }
                    let newRows = matchingLabels.sorted().map { label in
                        SpeakerRenameStore.makeRow(
                            meetingID: meetingID, speakerLabel: label, name: renameName,
                            diarization: diarization, now: timestamp)
                    }
                    let newLabels = Set(newRows.map(\.speakerLabel))
                    let effective = existing.filter { !newLabels.contains($0.speakerLabel) } + newRows
                    let renamed = SpeakerRenameStore.applyRenames(effective, to: segments)
                    if renamed != segments {
                        _ = try await self.database.persistTranscript(
                            meetingID: meetingID, segments: renamed, asrProvenance: asrProvenance,
                            dominantLanguage: dominantLanguage, updatedAt: timestamp,
                            additionalWrites: { db in for row in newRows { try row.save(db) } })
                        try await self.exportTranscriptJSON(
                            meetingID: meetingID, segments: renamed,
                            provenance: asrProvenance, dominantLanguage: dominantLanguage)
                        segments = renamed
                    } else {
                        // No transcript change (stale rows / already renamed):
                        // record the rows alone — nothing to fold into.
                        try await self.database.pool.write { db in
                            for row in newRows { try row.save(db) }
                        }
                    }
                }
            } else if !matchingLabels.isEmpty {
                // L3: persistTranscript is the SOLE writer of transcript_segment and
                // sets both provenance fields in the same transaction, so a
                // resolved-speaker meeting ALWAYS has them — a nil here is
                // unreachable. If it ever occurs, silently skipping the transcript
                // persist while still writing rename rows would reintroduce the
                // exact notes/transcript divergence NH-D exists to kill, so fail
                // loudly and skip the speaker layer ENTIRELY (no rename rows). The
                // notes correction below still applies.
                assertionFailure(
                    "NH-D: resolved speaker labels but nil asrProvenance/dominantLanguage — persistTranscript writes both atomically with the segments; unreachable")
                self.logger.error(
                    "NH-D skipped for \(meetingID, privacy: .public): matching labels but nil provenance; speaker layer left unchanged, no rename rows written"
                )
            }

            // G13: neutralize S-labels as the LAST write to notes.structured
            // before the render (the corrected value flows through it). The
            // label map reads the just-written rename rows, so a NH-D correction
            // renders the corrected speaker name into notes owners too.
            let labelMap = await self.slabelMap(meetingID: meetingID, segments: segments)
            notes.structured = SLabelNeutralizer.neutralize(
                notes: edited, labelMap: labelMap, language: notes.language).notes
            notes.markdown = try NotesRenderer.render(
                notes.structured, language: notes.language, meetingTitle: meeting.title,
                userName: user.name)
            try Data(notes.markdown.utf8).write(
                to: self.database.paths.notesURL(meetingID), options: .atomic)

            // Bump updatedAt (content mutation) before the mint, then re-mint.
            let finalMeeting = try await self.database.pool.write { db -> Meeting in
                guard var m = try Meeting.fetchOne(db, key: meetingID) else {
                    throw BlaiseDatabaseError.meetingNotFound(meetingID)
                }
                m.updatedAt = timestamp
                try m.update(db)
                return try Meeting.fetchOne(db, key: meetingID) ?? m
            }
            let payload = EvidencePayloadBuilder.build(
                meeting: finalMeeting, segments: segments, notes: notes,
                user: user)
            let relativePath = self.database.paths.relativeHandoffPayloadPath(
                meetingID: meetingID, versionHash: payload.versionHash)
            try ImmutablePayloadWriter.write(
                payload.bytes, to: self.database.rootURL.appendingPathComponent(relativePath))
            let rootURL = self.database.rootURL
            try await self.database.pool.write { [notes] db in
                try notes.upsert(db)
                _ = try HandoffRepository.enqueue(
                    db, rootURL: rootURL, meetingID: meetingID,
                    versionHash: payload.versionHash, payloadPath: relativePath)
            }
            await self.handoffKicker.kick()
            return count
        }
    }

    /// The everyday test as a Sendable closure over the cached lexicons (for
    /// the store write path). Falls back to "never everyday" if the bundled
    /// lexicons can't load (a build invariant — same degradation as elsewhere).
    static func everydayClosure() -> @Sendable (String) -> Bool {
        guard let lexicons = try? PipelineVocabulary.sharedLexicons() else { return { _ in false } }
        return { PipelineVocabulary.isEveryday($0, lexicons: lexicons) }
    }

    // MARK: - Run body

    /// Local per-run context (single actor method scope; never escapes).
    private final class RunContext {
        var currentStage: PipelineStage
        var record: PipelineRunRecord
        /// G7 (M-1): an explicit cloud-spend purpose for this run's notes call.
        /// nil = derive from the regeneration flag (process() = generation,
        /// regenerate() = regeneration). The notes-pending self-heal resume
        /// sets it explicitly: `.regeneration` only when the meeting already
        /// had persisted notes before this run, `.generation` for a meeting's
        /// first-ever notes produced via the pending path.
        var notesPurpose: CloudSpendPurpose?
        /// G14: an explicit cloud-spend purpose for this run's digest call.
        /// nil = `.digest` (the default for a first-time generation). The
        /// digest-only resume / regeneration sets `.regeneration`.
        var digestPurpose: CloudSpendPurpose?
        /// G10 §1: this run's cancel token. The stage checkpoint reads it
        /// (alongside `Task.isCancelled`); it is bound as the task-local
        /// `CancellationToken.current` around the cloud engine call so the
        /// engine binds the cancel at its attempt boundaries.
        var cancelToken: CancellationToken?
        /// T3.1 (md-v3) AC2: the scoped alias bindings RESOLVED by this run's
        /// digest call (`generateMemoryDigest` sets it). `persistNotesAndFinalize`
        /// writes them onto the `meeting_notes` row so the bare digest-resume
        /// path can replay them and scope identically. nil ⇒ no digest call ran
        /// (toggle off / failed before derivation); the persist step then keeps
        /// the empty default.
        var resolvedScopedAliasBindings: [AliasPair]?

        init(meetingID: MeetingID, regeneration: Bool) {
            self.currentStage = regeneration ? .transcode : .ingest
            self.record = PipelineRunRecord(meetingID: meetingID, regeneration: regeneration)
        }
    }

    // MARK: - Cancel-token registry (G10 §1)

    private func installCancelToken(meetingID: MeetingID, statusSilent: Bool) -> CancellationToken {
        let token = CancellationToken()
        cancelTokens[meetingID] = RunCancelHandle(token: token, statusSilent: statusSilent)
        return token
    }

    /// Remove the run's token ONLY if it is still the installed one — a
    /// re-dispatch that started a fresh run (its own token) must not have its
    /// handle clobbered by the prior run's exit defer.
    private func removeCancelToken(meetingID: MeetingID, token: CancellationToken) {
        if cancelTokens[meetingID]?.token === token {
            cancelTokens[meetingID] = nil
        }
    }

    private func runBody(
        meetingID: MeetingID, sourceWAV: URL?, regeneration: Bool, captured: Bool
    ) async throws -> PipelineRunRecord {
        // Processing start AND regenerate() are pending-events sweep
        // triggers (C10): matched batches must land in
        // `meeting_speaker_event` (and merged roster attendees on the
        // meeting row) BEFORE the run snapshot below is taken.
        await meetEventsSweeper.sweep(meetingID: meetingID)
        // Entry: clear processingNote (EVERY run — except the capture-
        // recovery class, which survives until a both-tracks run completes
        // or the user dismisses it; C7 v3.3); process() also flips status
        // to .processing. Throws (unrecorded) if the meeting is gone.
        let meeting = try await writeRunEntry(meetingID: meetingID, regeneration: regeneration)
        emit(.runStarted(meetingID, regeneration: regeneration))

        // G10 §1: install this run's cancel token. statusSilent mirrors the
        // status-write discipline — a regeneration never writes a `cancelled`
        // status (C1 no-regress), so its cancel is status-silent. Removed on
        // every exit path below.
        let cancelToken = installCancelToken(meetingID: meetingID, statusSilent: regeneration)
        defer { removeCancelToken(meetingID: meetingID, token: cancelToken) }

        let context = RunContext(meetingID: meetingID, regeneration: regeneration)
        context.cancelToken = cancelToken
        // Temp artifacts (decoded WAVs): deleted on every exit path.
        let tempWAV = tempDirectory
            .appendingPathComponent("blaise-pipeline-\(meetingID)-\(UUID().uuidString).wav")
        let tempMicWAV = tempDirectory
            .appendingPathComponent("blaise-pipeline-\(meetingID)-mic-\(UUID().uuidString).wav")
        defer {
            try? FileManager.default.removeItem(at: tempWAV)
            try? FileManager.default.removeItem(at: tempMicWAV)
        }

        // G1 §3: build the vocabulary stack for THIS run (hot-reloads the user
        // glossary; never fails — worst case an empty stack). §5b: the load
        // diagnostics ride the activity observable and are unified-logged.
        let userLoad = vocabularyProvider()
        reportGlossaryLoad(userLoad, meetingID: meetingID)
        let vocabulary = userLoad.vocabulary
        do {
            // Run the stages inside a child task so a `cancel` can drive Swift
            // task cancellation into them (the local-subprocess kill path)
            // WITHOUT cancelling the actor method itself. The handle's
            // `cancelTask` is wired to this child; the cloud attempt shields
            // itself from this cancellation and uses the token at its boundary.
            let stageTask = Task {
                try await self.runStages(
                    meeting: meeting, sourceWAV: sourceWAV, tempWAV: tempWAV, tempMicWAV: tempMicWAV,
                    captured: captured, context: context, vocabulary: vocabulary)
            }
            cancelTokens[meetingID]?.cancelTask = { stageTask.cancel() }
            let record = try await stageTask.value
            emit(.runCompleted(meetingID))
            return record
        } catch {
            let message = Self.describe(error)
            let stage = context.currentStage
            logger.error("run failed at \(stage.rawValue): \(message)")
            await recordFailure(
                meetingID: meetingID, regeneration: regeneration, stage: stage, message: message)
            emit(.runFailed(meetingID, stage: stage, message: message))
            // C1 (F1 Inc2): a CANCELLATION must surface as the TYPED
            // `EngineError.cancelled`, not be wrapped in a generic
            // `PipelineError` — the processing-queue worker classifies a job
            // `cancelled` (vs `failed`) on this type. Detect it via the cancel
            // token (set by `cancel`) or the thrown `EngineError.cancelled`. The
            // status/event behavior above is unchanged (the meeting-status write
            // stays owned by `cancel`); only the propagated error TYPE narrows.
            var wasCancelled = context.cancelToken?.isCancelled == true
            if case EngineError.cancelled = error { wasCancelled = true }
            if wasCancelled { throw EngineError.cancelled }
            throw PipelineError(stage: stage, message: message)
        }
    }

    /// What stages 1–5 produce, in either variant: the merged (and, for
    /// captured meetings, interleaved) segments plus what stage 8 needs.
    private struct FrontResult {
        var segments: [TranscriptSegment]
        var diarization: DiarizationOutput
        var provenance: ASRProvenance
        var detectedLanguage: String?
        var audioDuration: Double
        /// Both retained tracks fed a captured run (clears a surviving
        /// capture-recovery note at the terminal write).
        var capturedBothTracks = false
    }

    private func runStages(
        meeting: Meeting, sourceWAV: URL?, tempWAV: URL, tempMicWAV: URL, captured: Bool,
        context: RunContext, vocabulary: PipelineVocabulary
    ) async throws -> PipelineRunRecord {
        let meetingID = meeting.id
        let user = await userIdentity()

        let front: FrontResult
        if captured {
            front = try await runCapturedFront(
                meeting: meeting, tempSystemWAV: tempWAV, tempMicWAV: tempMicWAV,
                context: context, user: user)
        } else {
            front = try await runFileFirstFront(
                meeting: meeting, sourceWAV: sourceWAV, tempWAV: tempWAV, context: context)
        }
        let diarization = front.diarization
        let asrProvenance = front.provenance
        let audioDuration = front.audioDuration

        // 6. correct — C5 corrector (bundled fixtures); corrections logged.
        var segments = front.segments
        try await stage(.correct, context, meetingID) {
            for index in segments.indices {
                let result = vocabulary.corrector.correct(segments[index].text)
                segments[index].text = result.correctedText
                context.record.corrections += result.corrections.map {
                    AppliedCorrection(
                        original: $0.original, canonical: $0.canonical, stage: $0.stage.rawValue)
                }
            }
            context.record.correctionCount = context.record.corrections.count
            self.logger.info("vocabulary corrections applied: \(context.record.correctionCount)")
        }

        // 7. languageStats — held in memory, persisted at stage 11.
        let dominantLanguage = try await stage(.languageStats, context, meetingID) {
            DominantLanguage.classify(segments: segments)
        }
        context.record.dominantLanguage = dominantLanguage

        // 8. resolveSpeakers — mechanical pass. "Hints from stored events"
        // is now defined (C10): SpeakerHints.activeSpeakerEvents = this
        // meeting's `meeting_speaker_event` rows (the listener's consumer
        // table); imports without a matched Meet batch still see none.
        // Two-track capture (C4 v5.3): isSelf events are EXCLUDED from
        // system-track voting — the user is not on that track.
        let storedEvents = try await MeetEventsRepository(database: database)
            .activeSpeakerEvents(meetingID: meetingID, excludingSelf: captured)
        let eventNames = Set(storedEvents.map(\.displayName))
        try await stage(.resolveSpeakers, context, meetingID) {
            let hints = SpeakerHints(
                activeSpeakerEvents: storedEvents.isEmpty ? nil : storedEvents,
                recordingStartEpochMillis: Int64(meeting.startedAt.timeIntervalSince1970 * 1000))
            let resolution = SpeakerResolver.resolve(
                diarization: diarization.segments, hints: hints, audioDuration: audioDuration)
            segments = resolution.apply(
                to: segments,
                attendeeNames: Set(meeting.attendees.map(\.name)),
                eventNames: eventNames,
                userName: user.name,
                suppression: vocabulary.suppression,
                commonNames: vocabulary.commonNames)
            // C4 v6: per-segment refinement over the same timeline — corrects
            // cluster bleed (one acoustic cluster spanning two people) and names
            // multi-speaker blobs the cluster pass left unresolved. No-op without
            // events; never invents a name; clears a contradicted name rather
            // than keeping a wrong one (policy b).
            segments = SpeakerResolver.refineWithPerSegmentTimeline(
                segments: segments, diarization: diarization.segments, hints: hints,
                audioDuration: audioDuration, eventNames: eventNames)
        }

        // 9. notes — NO availability pre-gate (C2 amendment for this slot):
        // ceiling/budget/config conditions arrive as THROWN triggers so the
        // one-hop fallback can fire (lightweight engines only — D17; a
        // heavyweight-only fallback resolves to notes-pending instead).
        let notesRequest = NotesRequest(
            meeting: meeting,
            transcript: segments,
            dominantLanguage: dominantLanguage,
            vocabulary: vocabulary.canonicalTerms,
            user: user,
            // #101: grounded person-mention hints — derived IDENTICALLY here and
            // on the notes-only resume (same vocabulary, attendees, segments), so
            // the resume request stays byte-equal to this stage-9 request.
            groundedPersonHints: GroundedPersonHints.groundedPersonHints(
                vocabulary: vocabulary, attendees: meeting.attendees, segments: segments))
        // G15: the participant-confirmation gate is evaluated ONCE here, at
        // notes-stage entry (transcript + diarization already produced and about
        // to persist). When it fires, the run resolves to notes-pending with the
        // reserved reason WITHOUT calling the notes engine — transcript still
        // persists (stage 11 below), audio is retained, no handoff is enqueued —
        // and the app posts the confirm notification once off the emitted event.
        let hasNotesBeforeStage9 = await hasPersistedNotes(meetingID)
        let notesOutcome = try await stage(.notes, context, meetingID) {
            if await self.shouldGateForParticipants(
                meeting: meeting, hasExistingNotes: hasNotesBeforeStage9)
            {
                if !NotesPendingClass.isAwaitingParticipantConfirmation(meeting.lastProcessingError) {
                    self.emit(.participantConfirmationNeeded(meetingID, title: meeting.title))
                }
                return NotesStageOutcome.pending(
                    reason: NotesPendingClass.awaitingParticipantConfirmation)
            }
            return try await self.generateNotesWithFallback(notesRequest, context: context)
        }
        var producedNotes: NotesResult?
        if case .produced(let result) = notesOutcome {
            producedNotes = result
            context.record.notesEngineID = result.provenance.engine
            context.record.notesUsage = result.usage
            context.record.proposals = result.speakerNameMapping
        }

        // 10. applyLLMNames — drop `low`; mechanical names win by
        // no-overwrite. All naming now final, in memory. Skipped entirely on
        // a notes-pending resolution (no proposals exist; the notes-only
        // resume applies them when notes eventually arrive).
        if let notesResult = producedNotes {
            try await stage(.applyLLMNames, context, meetingID) {
                let before = segments
                segments = self.applyProposals(
                    notesResult.speakerNameMapping, to: segments, meeting: meeting,
                    eventNames: eventNames, user: user, vocabulary: vocabulary)
                for (old, new) in zip(before, segments)
                where old.speakerName == nil && new.speakerName != nil {
                    context.record.appliedNames[new.speakerLabel] = new.speakerName
                }
                context.record.namedSegmentCount = segments.filter { $0.speakerName != nil }.count
            }
        }

        // G2 §1/§3: apply the store (rule 1) + rule-3 polish to the speaker
        // NAMES BEFORE user renames — a misheard mechanical/LLM `speaker_name`
        // is outranked by a store row (the correction reaches the transcript
        // labels and the payload). User renames apply last and outrank this.
        let labelContext = await nameSubstitutionContext(
            meeting: meeting, segments: segments, vocabulary: vocabulary)
        segments = applyStoreToSpeakerLabels(segments, context: labelContext)

        // G2 §4: apply durable speaker-rename rows AFTER naming (a user rename
        // outranks mechanical/LLM names). Non-stale rows apply by speaker_label
        // (the artifact-present direct-apply path; the fallback already
        // re-keyed rows to the fresh labels above). Rename store rule-1/3
        // normalization already ran on the rename input at write time.
        let renames = (try? await database.pool.read { db in
            try SpeakerRenameStore.all(db, meetingID: meetingID)
        }) ?? []
        segments = SpeakerRenameStore.applyRenames(renames, to: segments)
        context.record.finalSegmentCount = segments.count

        // 11. persistTranscript — the single transcript persistence point,
        // AFTER all naming: replace-all + provenance + dominantLanguage in
        // the same write; export transcript.json. Nothing downstream
        // mutates segments.
        let inserted = try await stage(.persistTranscript, context, meetingID) {
            let stored = try await self.database.persistTranscript(
                meetingID: meetingID,
                segments: segments,
                asrProvenance: asrProvenance,
                dominantLanguage: dominantLanguage,
                updatedAt: self.now(),
                midTransactionHook: { PipelineCrashHooks.maybeKill(.persistTranscript) })
            try self.exportTranscriptJSON(
                meetingID: meetingID, segments: stored,
                provenance: asrProvenance, dominantLanguage: dominantLanguage)
            return stored
        }
        _ = inserted  // exported above; finalize re-reads the DB state

        // D17 notes-pending terminal: the run completed its non-notes work
        // (transcript persisted and visible above); NO notes, NO payload,
        // NO handoff row (ready ⇒ queued holds — the meeting is not ready).
        // The reserved marker keys the UI and the self-heal re-dispatch.
        guard let notesResult = producedNotes else {
            if case .pending(let reason) = notesOutcome {
                context.record.notesPending = reason
                await writeNotesPending(
                    meetingID: meetingID, regeneration: context.record.regeneration, reason: reason)
            }
            await writeTerminalNote(
                meetingID: meetingID, fallback: nil,
                clearCaptureRecovery: front.capturedBothTracks)
            return context.record
        }

        // G2 §3: deterministic name-substitution pass over the produced notes
        // (zero engine calls), before persist. Uses the now-final transcript
        // segments for rule-2 candidates.
        let substituted = await applyNameSubstitution(
            to: notesResult, meeting: meeting, segments: segments, vocabulary: vocabulary)

        // G14: the SECOND synthesis call — fired AFTER name-substitution, with
        // the name-substituted notes as the salience guide (toggle-gated;
        // non-fatal; bounded retry inside generateDigest). Its produced digest
        // is run through SLabelNeutralizer.neutralizeText before persist.
        let digestOutcome = await generateMemoryDigest(
            meetingID: meetingID, meeting: meeting, notes: substituted.structured,
            segments: segments, dominantLanguage: dominantLanguage,
            vocabulary: vocabulary, user: user, context: context,
            corrections: context.record.corrections)
        let digest = Self.digestStringOrNil(digestOutcome)

        // 12+13. persistNotes + finalize (shared with the notes-only resume).
        try await persistNotesAndFinalize(
            meetingID: meetingID, notesResult: substituted,
            dominantLanguage: dominantLanguage, meetingTitle: meeting.title,
            user: user, context: context, memoryDigest: digest)
        // H1: a digest call that failed past its bounded retry leaves a
        // distinguishable `digest-pending:` marker (the run is still ready;
        // the payload omits `memory_digest` until a self-heal re-fire lands).
        if case .failed(let reason) = digestOutcome {
            await writeDigestPending(meetingID: meetingID, reason: reason)
        }
        await handoffKicker.kick()

        // Terminal event (single writer): a successful run with a fallback
        // sets the fallback note; otherwise the entry-cleared nil stands.
        // Capture-recovery notes (the third writer class, C7 v3.3): cleared
        // here ONLY when this run processed both tracks; a surviving
        // capture-recovery note wins over a fallback note (the retention
        // fact must stay visible until both tracks process or the user
        // dismisses it — the two never combine).
        await writeTerminalNote(
            meetingID: meetingID,
            fallback: context.record.fallback,
            clearCaptureRecovery: front.capturedBothTracks)
        return context.record
    }

    // MARK: - Stages 1–5, file-first variant (process()/regenerate of imports)

    private func runFileFirstFront(
        meeting: Meeting, sourceWAV: URL?, tempWAV: URL, context: RunContext
    ) async throws -> FrontResult {
        let meetingID = meeting.id
        let audioURL = database.paths.audioURL(meetingID)

        // 1. ingest — process() of an import only; regenerate() NEVER runs it.
        if !context.record.regeneration {
            try await stage(.ingest, context, meetingID) {
                try self.ingest(meetingID: meetingID, sourceWAV: sourceWAV)
            }
        }

        // 2. transcode — retained audio.m4a → temp 16 kHz mono Int16 WAV.
        // First run ≡ regeneration by construction (D14).
        try await stage(.transcode, context, meetingID) {
            try AudioTranscoder.decodeTo16kWAV(m4a: audioURL, destination: tempWAV)
        }
        let audioDuration = try WAVHeader.read(at: tempWAV).duration

        // 3. asr — resolve → prepare → availability (gate stays: ASR has no
        // fallback contract) → transcribe. Provenance held IN MEMORY until
        // stage 11.
        let asrResult = try await stage(.asr, context, meetingID) {
            let engine = try await self.preparedASREngine()
            let result = try await engine.transcribe(
                ASRRequest(audioURL: tempWAV, vocabularyHints: [], languageHint: nil))
            try self.writeRawASREnvelope(
                meetingID: meetingID, result: result,
                destination: self.database.paths.rawASRURL(meetingID))
            return result
        }
        context.record.asrSegmentCount = asrResult.segments.count
        context.record.detectedLanguage = asrResult.detectedLanguage
        context.record.asrProvenance = asrResult.provenance

        // 4. diarize — same temp WAV. A regenerate reuses the first run's
        // persisted diarization (deterministic naming; see
        // diarizeReusingPersisted).
        let attendeeCount = meeting.attendees.isEmpty ? nil : meeting.attendees.count
        let diarization = try await stage(.diarize, context, meetingID) {
            try await self.diarizeReusingPersisted(
                meetingID: meetingID, audioURL: tempWAV, attendeeCount: attendeeCount,
                regeneration: context.record.regeneration)
        }
        context.record.diarizationSegmentCount = diarization.segments.count
        context.record.speakerCount = diarization.speakerCount
        context.record.diarization = diarization

        // 5. merge.
        let merged = try await stage(.merge, context, meetingID) {
            SpeakerMerger.merge(
                asr: asrResult.segments, diarization: diarization.segments, meetingID: meetingID)
        }
        context.record.mergeSplits = merged.report.splits
        context.record.mergeDegenerateSegments = merged.report.degenerateSegments
        context.record.mergeGapAssignedWords = merged.report.gapAssignedWords
        context.record.mergeHealedFragments = merged.report.healedFragments
        context.record.mergedSegmentCount = merged.segments.count

        return FrontResult(
            segments: merged.segments,
            diarization: diarization,
            provenance: asrResult.provenance,
            detectedLanguage: asrResult.detectedLanguage,
            audioDuration: audioDuration)
    }

    // MARK: - Stages 1–5, captured (two-track) variant — C7 v3.2 body amendment

    /// Two retained tracks: ASR per track (same engine, two passes); the MIC
    /// track's segments are created with `speakerLabel = "user"` AND
    /// `speakerName = UserIdentity.name`; the SYSTEM track runs
    /// diarization+merge as today; interleave by start time with the pinned
    /// tie-break (start, then track — mic first —, then original ord; ord
    /// re-sequenced globally; per-track invariants hold PER track,
    /// cross-track overlap legal). A partially-recovered capture (one
    /// verified track) processes the surviving track — honest partial,
    /// never a silent loss.
    private func runCapturedFront(
        meeting: Meeting, tempSystemWAV: URL, tempMicWAV: URL, context: RunContext,
        user: UserIdentity
    ) async throws -> FrontResult {
        let meetingID = meeting.id
        let paths = database.paths

        // 2. transcode — C14: part-aware. ONE part = exactly today's decode
        // path; multiple parts stitch into the ONE temp WAV per track every
        // downstream stage already expects, with per-part wall-clock
        // re-anchoring + gap silence. The NULL-`endedAt` repair applies on
        // every path (single-part included).
        let stitched = try await stage(.transcode, context, meetingID) {
            try await CaptureStitcher.prepareTracks(
                database: self.database, meeting: meeting,
                tempSystemWAV: tempSystemWAV, tempMicWAV: tempMicWAV,
                tempDirectory: self.tempDirectory)
        }
        let systemPresent = stitched.systemPresent
        let micPresent = stitched.micPresent
        guard systemPresent || micPresent else {
            throw PipelineError(
                stage: .transcode, message: "captured meeting has no retained audio tracks")
        }
        context.record.capturedTracks =
            (systemPresent ? [CaptureTrack.system.rawValue] : [])
            + (micPresent ? [CaptureTrack.mic.rawValue] : [])
        if stitched.partCount > 1 {
            context.record.stitchedParts = stitched.partCount
        }
        if !stitched.notes.isEmpty {
            // Stitch-time capture-recovery facts (row-less append, missing
            // track span) — third writer class; a graver stop-time damage
            // note already standing is never clobbered.
            await writeStitchRecoveryNote(meetingID: meetingID, notes: stitched.notes)
        }
        // Drift-sweep/duration reference: the system track carries the
        // diarization clusters the events vote over.
        let audioDuration = try WAVHeader.read(at: systemPresent ? tempSystemWAV : tempMicWAV)
            .duration

        // 3. asr — one engine, one pass per present track. raw_asr.json for
        // the system pass, raw_asr_mic.json for the mic pass (additive).
        var (systemASR, micASR) = try await stage(.asr, context, meetingID) {
            let engine = try await self.preparedASREngine()
            var system: ASRResult?
            var mic: ASRResult?
            if systemPresent {
                system = try await engine.transcribe(
                    ASRRequest(audioURL: tempSystemWAV, vocabularyHints: [], languageHint: nil))
                try self.writeRawASREnvelope(
                    meetingID: meetingID, result: system!,
                    destination: paths.rawASRURL(meetingID))
            }
            if micPresent {
                mic = try await engine.transcribe(
                    ASRRequest(audioURL: tempMicWAV, vocabularyHints: [], languageHint: nil))
                try self.writeRawASREnvelope(
                    meetingID: meetingID, result: mic!,
                    destination: paths.rawASRMicURL(meetingID))
            }
            return (system, mic)
        }

        // Silence-hallucination guard (hard floor 1, C14): segments lying
        // entirely inside a structural stitched-gap range (shrunk 1 s per
        // edge) drop per track BEFORE normalization; the count is logged in
        // the run record.
        var gapDropped = 0
        if let system = systemASR, !stitched.systemGaps.isEmpty {
            let filtered = CaptureStitcher.filterGapSegments(
                system.segments, gaps: stitched.systemGaps)
            systemASR?.segments = filtered.kept
            gapDropped += filtered.droppedCount
        }
        if let mic = micASR, !stitched.micGaps.isEmpty {
            let filtered = CaptureStitcher.filterGapSegments(mic.segments, gaps: stitched.micGaps)
            micASR?.segments = filtered.kept
            gapDropped += filtered.droppedCount
        }
        if gapDropped > 0 {
            context.record.gapDroppedSegments = gapDropped
            logger.notice("gap-segment filter dropped \(gapDropped) ASR segment(s) inside stitched silence")
        }
        let provenance = (systemASR ?? micASR)!.provenance
        context.record.asrSegmentCount =
            (systemASR?.segments.count ?? 0) + (micASR?.segments.count ?? 0)
        context.record.detectedLanguage = systemASR?.detectedLanguage ?? micASR?.detectedLanguage
        context.record.asrProvenance = provenance

        // 4. diarize — SYSTEM track only (the mic track is by definition the
        // user; never diarized). Skipped entirely when only the mic track
        // survived a partial recovery.
        var diarization = DiarizationOutput(segments: [], speakerCount: 0)
        if systemPresent {
            let attendeeCount = meeting.attendees.isEmpty ? nil : meeting.attendees.count
            diarization = try await stage(.diarize, context, meetingID) {
                try await self.diarizeReusingPersisted(
                    meetingID: meetingID, audioURL: tempSystemWAV, attendeeCount: attendeeCount,
                    regeneration: context.record.regeneration)
            }
        }
        context.record.diarizationSegmentCount = diarization.segments.count
        context.record.speakerCount = diarization.speakerCount
        context.record.diarization = diarization

        // 5. merge — cross-track echo suppression at RAW-ASR granularity
        // (C7 v3.8), then system merge as today; the mic SURVIVORS are
        // normalized through the same merger (empty diarization → per-track
        // invariants established), then labeled `user` + named at creation;
        // then interleave.
        let interleaved = try await stage(.merge, context, meetingID) {
            var systemSegments: [TranscriptSegment] = []
            if let systemASR {
                let merged = SpeakerMerger.merge(
                    asr: systemASR.segments, diarization: diarization.segments,
                    meetingID: meetingID)
                context.record.mergeSplits = merged.report.splits
                context.record.mergeDegenerateSegments = merged.report.degenerateSegments
                context.record.mergeGapAssignedWords = merged.report.gapAssignedWords
                context.record.mergeHealedFragments = merged.report.healedFragments
                systemSegments = merged.segments
            }
            var micSegments: [TranscriptSegment] = []
            if let micASR {
                // Cross-track echo dedup (C7 v3.8): without headphones the
                // system audio bleeds acoustically into the mic, growing
                // near-duplicate "user" segments of OTHER speakers' words.
                // The MIC copy is the artifact under the wrong label and is
                // dropped; the system copy's attribution is diarization-
                // grounded and is never touched. Runs on RAW ASR segments
                // BEFORE the mic merge: consolidation grows user turns up to
                // minutes, so a mixed turn (genuine speech + embedded echo)
                // never crosses the whole-segment similarity gate, while raw
                // whisper segments (~2 s) discriminate cleanly. The count is
                // raw mic ASR segments dropped. Routine, not a failure:
                // counted in the run record, no processingNote.
                var micRaw = micASR.segments
                if let systemASR, !micRaw.isEmpty, !systemASR.segments.isEmpty {
                    let suppressed = EchoSuppressor.suppress(
                        mic: micRaw, system: systemASR.segments)
                    if suppressed.droppedCount > 0 {
                        context.record.echoDroppedSegments = suppressed.droppedCount
                        self.logger.notice(
                            "echo suppression dropped \(suppressed.droppedCount) raw mic ASR segment(s) duplicating overlapping system audio"
                        )
                    }
                    micRaw = suppressed.kept
                }
                micSegments = SpeakerMerger.merge(
                    asr: micRaw, diarization: [], meetingID: meetingID
                ).segments.map { segment in
                    var named = segment
                    named.speakerLabel = TranscriptSegment.userLabel
                    // G3: a pre-onboarding (empty) identity contributes no
                    // self-name, so the mic turn stays nameless (speakerName ==
                    // nil) rather than persisting an empty speaker name. The
                    // "You" UI fallback (micAwareSpeakerLabel) and the
                    // payload-owner / prompt "the user" handling all key on nil.
                    named.speakerName = user.name.isEmpty ? nil : user.name
                    return named
                }
            }
            return TwoTrackInterleaver.interleave(mic: micSegments, system: systemSegments)
        }
        context.record.mergedSegmentCount = interleaved.count

        return FrontResult(
            segments: interleaved,
            diarization: diarization,
            provenance: provenance,
            detectedLanguage: context.record.detectedLanguage,
            audioDuration: audioDuration,
            // C14: a stitch with a missing-track part or row-less residue is
            // NOT a both-tracks run — its capture-recovery note must survive.
            capturedBothTracks: systemPresent && micPresent && stitched.complete)
    }

    /// Stitch-time capture-recovery note (C14): written only when no
    /// capture-recovery note is already standing — a stop-time damage note
    /// (CAF retained) is the graver fact and wins.
    private func writeStitchRecoveryNote(meetingID: MeetingID, notes: [String]) async {
        let current = try? await database.pool.read { db in
            try String.fetchOne(
                db, sql: "SELECT processing_note FROM meeting WHERE id = ?",
                arguments: [meetingID])
        }
        if let existing = current ?? nil, existing.hasPrefix(CaptureRecovery.notePrefix) {
            return
        }
        await CaptureRecovery.writeRecoveryNote(
            database: database, meetingID: meetingID,
            note: "\(CaptureRecovery.notePrefix) \(notes.joined(separator: "; "))")
    }

    /// Stage-3 shared engine resolution: resolve (C2) → prepare →
    /// availability (the gate stays: ASR has no fallback contract).
    private func preparedASREngine() async throws -> any ASREngine {
        let resolved = try await resolver.resolveASR()
        let engine = resolved.engine
        try await engine.prepare()
        if case .unavailable(let reason) = await engine.availability() {
            throw PipelineError(
                stage: .asr, message: "engine '\(engine.id)' unavailable: \(reason)")
        }
        return engine
    }

    // MARK: - Stage runner

    private func stage<T>(
        _ stage: PipelineStage, _ context: RunContext, _ meetingID: MeetingID,
        _ body: () async throws -> T
    ) async throws -> T {
        context.currentStage = stage
        // G10 §1: a checkpoint BEFORE each stage — Swift task cancellation
        // (the local heavy stages' kill path) OR the explicit cancel token
        // (set by `cancel`, which survives task-cancellation shielding).
        if Task.isCancelled || context.cancelToken?.isCancelled == true {
            throw EngineError.cancelled
        }
        emit(.stageBegan(meetingID, stage))
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await body()
        let elapsed = clock.now - start
        let seconds =
            Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        context.record.stageSeconds[stage.rawValue] = seconds
        logger.info("stage \(stage.rawValue) finished in \(String(format: "%.2f", seconds)) s")
        emit(.stageFinished(meetingID, stage))
        return result
    }

    // MARK: - Stage 1: ingest

    private func ingest(meetingID: MeetingID, sourceWAV: URL?) throws {
        let fm = FileManager.default
        let paths = database.paths
        let audioURL = paths.audioURL(meetingID)
        let importCopy = paths.importCopyURL(meetingID)

        if !fm.fileExists(atPath: audioURL.path) {
            // Encode from the in-dir copy if present, else the caller-supplied
            // source WAV; neither → named error (source required).
            let source: URL
            if fm.fileExists(atPath: importCopy.path) {
                source = importCopy
            } else if let sourceWAV, fm.fileExists(atPath: sourceWAV.path) {
                source = sourceWAV
            } else {
                throw PipelineIngestError.sourceAudioRequired(meetingID)
            }
            let sourceDuration = try WAVHeader.read(at: source).duration
            // The verification decode runs on the TEMP file, before the
            // atomic rename: a failed verification leaves no audio.m4a.
            try AudioTranscoder.encodeToM4A(wav: source, destination: audioURL) { tempURL in
                try Self.verifyEncodedAudio(at: tempURL, sourceDuration: sourceDuration)
            }
        }

        // The import copy is deleted ONLY after a verified encode exists
        // (hard floor 2: never discard the lossless copy on an unverified
        // encode). Covers the re-run-after-crash case too: audio.m4a is
        // complete by atomicity, but re-verify against the copy before
        // letting it go.
        if fm.fileExists(atPath: importCopy.path) {
            let sourceDuration = try WAVHeader.read(at: importCopy).duration
            try Self.verifyEncodedAudio(at: audioURL, sourceDuration: sourceDuration)
            try fm.removeItem(at: importCopy)
        }
    }

    /// Verification decode: opens, duration within 0.5 s of the source.
    private static func verifyEncodedAudio(at url: URL, sourceDuration: Double) throws {
        let encodedDuration = try AudioTranscoder.duration(of: url)
        guard abs(encodedDuration - sourceDuration) <= 0.5 else {
            throw PipelineIngestError.encodeVerificationFailed(
                "duration \(encodedDuration) vs source \(sourceDuration)")
        }
    }

    // MARK: - Stage 3 artifact: raw_asr.json envelope

    /// `{provenance: ASRProvenance, payload: <engine-native JSON>}` —
    /// payload bytes spliced VERBATIM (never re-serialized); replaced
    /// atomically on regeneration (C2 contract amendment to C1).
    private func writeRawASREnvelope(meetingID: MeetingID, result: ASRResult, destination: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var data = Data("{\"provenance\":".utf8)
        data.append(try encoder.encode(result.provenance))
        data.append(Data(",\"payload\":".utf8))
        data.append(result.rawPayload.isEmpty ? Data("null".utf8) : result.rawPayload)
        data.append(Data("}\n".utf8))

        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: temp)
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
    }

    // MARK: - Diarization persistence (deterministic regenerate)

    /// Stage-4 diarization: on a regeneration that can reuse the FIRST run's
    /// persisted output, reuse it — the FluidAudio clusterer is nondeterministic
    /// across runs (turn boundaries shift), so re-diarizing would re-vote the
    /// durable Meet speaker events onto different clusters and could drop names
    /// that previously attached (field exhibit, "Futuro do Vexatron": S0/S1
    /// reverted to unnamed on a regenerate). Reuse makes naming idempotent.
    /// The artifact is written on EVERY diarize so a regenerate that does fall
    /// back to a fresh diarize (missing artifact) persists its own for the next
    /// one. `process()` (first run) and meetings predating the artifact always
    /// diarize fresh.
    private func diarizeReusingPersisted(
        meetingID: MeetingID, audioURL: URL, attendeeCount: Int?, regeneration: Bool
    ) async throws -> DiarizationOutput {
        if regeneration, let reused = loadPersistedDiarization(meetingID: meetingID) {
            logger.info("regenerate: reusing persisted diarization (\(reused.segments.count) segments) — naming stays deterministic")
            return reused
        }
        let fresh = try await diarizer.diarize(audioURL: audioURL, attendeeCount: attendeeCount)
        // G2 §4 (R4-H1 ordering): on the MISSING-ARTIFACT fallback, re-map +
        // re-key the speaker-rename rows by anchor against this FRESH
        // clustering and COMMIT that BEFORE persisting the fresh artifact — a
        // crash between them degrades to one more safe fallback run, never a
        // direct-apply against stale label keys. On a first run there are no
        // rename rows, so this is a no-op.
        let now = self.now()
        // M-1: the re-key transaction MUST commit before the artifact is
        // persisted. If it throws, we do NOT persist the fresh artifact — the
        // next run falls back again (one more safe fallback, the spec's own
        // degradation argument) rather than persisting an artifact whose labels
        // the rename rows were never re-keyed to (a direct-apply against stale
        // keys, which the v5.1 ordering rule says can NEVER happen).
        try await database.pool.write { db in
            try SpeakerRenameStore.remapForFreshDiarization(
                db, meetingID: meetingID, fresh: fresh, now: now)
        }
        persistDiarization(fresh, meetingID: meetingID)
        return fresh
    }

    private func loadPersistedDiarization(meetingID: MeetingID) -> DiarizationOutput? {
        let url = database.paths.diarizationURL(meetingID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DiarizationOutput.self, from: data)
    }

    private func persistDiarization(_ output: DiarizationOutput, meetingID: MeetingID) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(output) else { return }
        try? data.write(to: database.paths.diarizationURL(meetingID), options: .atomic)
    }

    // MARK: - G15 participant-confirmation gate

    /// The G15 gate predicate, evaluated ONCE at notes-stage entry. Fires iff:
    /// the opt-in preference is ON; the meeting's attendees are empty (attendees
    /// from ANY source — calendar merge, import, Meet/Slack roster absorption —
    /// satisfy the gate, so a rostered/calendar-merged meeting never gates); the
    /// meeting has no persisted notes yet (regeneration of a noted meeting never
    /// gates — corrections and G2 renames are the tool there); AND the meeting is
    /// not already parked on a DIFFERENT notes-pending reason. That last clause
    /// is what makes a Skip durable with no new column (§3/AC5): a skipped
    /// meeting that then engine-parks carries the engine marker, so the next
    /// self-heal proceeds to the engine check instead of re-gating it — while a
    /// meeting parked on the participant marker itself DOES re-gate (AC5).
    private func shouldGateForParticipants(meeting: Meeting, hasExistingNotes: Bool) async -> Bool {
        guard !hasExistingNotes, meeting.attendees.isEmpty else { return false }
        let lpe = meeting.lastProcessingError
        guard !NotesPendingClass.isPending(lpe)
            || NotesPendingClass.isAwaitingParticipantConfirmation(lpe)
        else { return false }
        return await AutomationSettings.confirmParticipants(from: settings)
    }

    /// Whether the meeting already has a persisted notes row (the gate's
    /// regeneration-never-gates clause).
    private func hasPersistedNotes(_ meetingID: MeetingID) async -> Bool {
        (try? await database.pool.read { db in
            try MeetingNotes.filter(key: meetingID).fetchCount(db) > 0
        }) ?? false
    }

    /// The confirm sheet's attendee normalization (§3): trim, drop empties, and
    /// fold-dedup (C5 canonical) preserving first-seen display surface + order.
    /// No glossary/alias rows are created — these are attendee DISPLAY names.
    public static func foldedDedupedAttendees(_ names: [String]) -> [Attendee] {
        var seen = Set<String>()
        var out: [Attendee] = []
        for raw in names {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let key = VocabNormalization.canonicalMode(name)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            out.append(Attendee(name: name, source: .manual))
        }
        return out
    }

    /// G15 Confirm (§3): write the folded-deduped attendee names (a CONTENT
    /// mutation — attendees are a payload-builder input, so `updatedAt` bumps),
    /// then dispatch the notes-only resume that BYPASSES the gate. The pending
    /// marker is left in place so the resume runs (it requires it) and its
    /// finalize clears the marker — exactly like every other pending self-heal.
    /// Acts only on a meeting still parked on the participant marker (race-safe
    /// on the single-flight chain). Returns whether attendees were written.
    @discardableResult
    public func confirmParticipants(meetingID: MeetingID, names: [String]) async throws -> Bool {
        let attendees = Self.foldedDedupedAttendees(names)
        // L2: an all-empty/whitespace confirm writes nothing and dispatches
        // nothing (server-side guard — the sheet's Confirm button disable is only
        // the client-side half). A user with no names to give uses Skip.
        guard !attendees.isEmpty else { return false }
        let timestamp = now()
        let didWrite = try await chain.run { () -> Bool in
            try await self.database.pool.write { db in
                guard var meeting = try Meeting.fetchOne(db, key: meetingID),
                    NotesPendingClass.isAwaitingParticipantConfirmation(meeting.lastProcessingError)
                else { return false }
                meeting.attendees = attendees
                meeting.updatedAt = timestamp
                try meeting.update(db)
                return true
            }
        }
        guard didWrite else { return false }
        _ = try? await processNotesOnly(meetingID: meetingID, confirmingParticipants: true)
        return true
    }

    /// G15 Skip (§3): proceed WITHOUT attendees for this meeting — nothing is
    /// written; the gate-bypassing resume mints notes and its finalize clears the
    /// marker. A subsequent engine-park (no notes) carries the engine marker, so
    /// the skip is durable (a later self-heal does not re-gate). No-op when the
    /// meeting is no longer participant-pending.
    @discardableResult
    public func skipParticipantConfirmation(meetingID: MeetingID) async throws -> Bool {
        // L1: no-op unless the meeting is STILL parked on the participant marker
        // (mirrors confirmParticipants' guard). Without this, a Skip from a stale
        // sheet — the meeting has since moved to engine-pending or ready — would
        // dispatch a gate-bypassing resume and fire an out-of-cadence engine
        // retry / re-mint. `processNotesOnly` no-ops for a non-pending meeting,
        // but an engine-pending one would run; this guard stops that.
        guard let meeting = try await MeetingRepository(database: database).fetch(meetingID),
            NotesPendingClass.isAwaitingParticipantConfirmation(meeting.lastProcessingError)
        else { return false }
        let record = try await processNotesOnly(
            meetingID: meetingID, confirmingParticipants: true)
        return record != nil
    }

    /// Confirm-sheet pre-fill (§3): the grounded person-hint canonicals for a
    /// meeting — curated glossary person names whose everyday mis-transcription
    /// surfaces actually appear in this meeting's transcript. Read-only,
    /// best-effort (empty when there is no transcript or no grounded hint).
    public func groundedPersonNames(meetingID: MeetingID) async -> [String] {
        guard
            let meeting = try? await MeetingRepository(database: database).fetch(meetingID),
            let segments = try? await TranscriptRepository(database: database)
                .segments(meetingID: meetingID)
        else { return [] }
        let vocabulary = vocabularyProvider().vocabulary
        return GroundedPersonHints.groundedPersonHints(
            vocabulary: vocabulary, attendees: meeting.attendees, segments: segments
        ).map(\.canonical)
    }

    /// Confirm-sheet caption (§3): the diarization cluster count ("Blaise heard N
    /// distinct voices") from the persisted diarization artifact. 0 when absent.
    public func diarizationClusterCount(meetingID: MeetingID) async -> Int {
        loadPersistedDiarization(meetingID: meetingID)?.speakerCount ?? 0
    }

    // MARK: - Stage 9: notes with the ONE-hop runtime fallback (D17 policy)

    /// The one-hop runtime fallback, amended by D17: the hop only AUTO-fires
    /// to a `.lightweight` engine. When the only fallback is heavyweight
    /// (the shipped pair: cloud default, 18 GB-peak local second), a
    /// fallback-trigger failure resolves to `.pending` instead of loading
    /// it — the auto-fallback cold-loading Gemma locked up the 32 GB machine
    /// twice on 2026-06-10. A heavyweight engine still runs when it IS the
    /// user-selected primary (subject to its own memory gate).
    private func generateNotesWithFallback(
        _ request: NotesRequest, context: RunContext
    ) async throws -> NotesStageOutcome {
        // G7 purpose attribution: regenerate() on a ready meeting bills as
        // `.regeneration`; a first-time process()/processCaptured() run bills
        // as `.generation`. The notes-pending self-heal resume overrides this
        // explicitly (M-1): it is a `.regeneration` ONLY when the meeting
        // already had persisted notes before the run, and a `.generation` when
        // it is producing the meeting's first-ever notes (the common D17 case
        // where the ORIGINAL process() reached the ceiling / had no key and
        // never produced notes at all).
        let purpose: CloudSpendPurpose =
            context.notesPurpose ?? (context.record.regeneration ? .regeneration : .generation)
        // G10 §1: bind THIS run's cancel token as the task-local around the
        // notes call so the engine's attempt-boundary checks (the max-tokens
        // retry, a new send) observe it WITHOUT the token being threaded
        // through the engine-agnostic signature. The token is also checked
        // before the first send and before the fallback hop here — "no retry
        // attempt, fallback hop, or new call starts after the token is set".
        return try await CancellationToken.$current.withValue(context.cancelToken) {
            try await self.generateNotesWithFallbackBound(
                request, purpose: purpose, context: context)
        }
    }

    private func generateNotesWithFallbackBound(
        _ request: NotesRequest, purpose: CloudSpendPurpose, context: RunContext
    ) async throws -> NotesStageOutcome {
        let resolved = try await resolver.resolveSummarization()
        let primary = resolved.engine
        do {
            try await primary.prepare()
            if context.cancelToken?.isCancelled == true { throw EngineError.cancelled }
            return .produced(try await primary.generateNotes(request, purpose: purpose))
        } catch let primaryError as EngineError
        where EngineFallbackReason.isFallbackTrigger(primaryError) {
            let primaryReason = Self.describe(primaryError)
            // Decision B ("stay free, but not silent"): when the user SELECTED an
            // engine that suppresses auto-fallback (the subscription `claude -p`
            // Account engine), a fallback-trigger failure must NOT silently route
            // to the metered API (or any other) engine — leave the notes PENDING
            // with a user-visible warning so the user can retry on their chosen
            // free engine. This is checked BEFORE any fallback-engine lookup.
            if primary.suppressesAutoFallback {
                logger.warning(
                    "notes pending: selected engine \(primary.id) failed (\(primaryReason)); not auto-falling back — user-selected subscription engine stays free, retry on the same engine"
                )
                return .pending(reason: "\(primary.id) failed: \(primaryReason)")
            }
            guard
                let fallback = registry.summarizationEngines.first(where: { $0.id != primary.id })
            else {
                throw PipelineError(
                    stage: .notes,
                    message:
                        "notes failed (\(primary.id): \(primaryReason)) and no fallback engine is registered")
            }
            if case .heavyweight = fallback.loadProfile {
                logger.warning(
                    "notes pending: \(primary.id) failed (\(primaryReason)); fallback \(fallback.id) is heavyweight and is never auto-loaded (D17)"
                )
                return .pending(reason: primaryReason)
            }
            logger.warning(
                "notes fallback: \(primary.id) → \(fallback.id) (\(primaryReason))")
            // G10 §1: the fallback hop is an attempt boundary — no new send
            // starts after the token is set.
            if context.cancelToken?.isCancelled == true { throw EngineError.cancelled }
            do {
                // The fallback hop runs prepare() FIRST (idempotent,
                // cheap-when-satisfied; a cold lightweight fallback
                // provisions before generating).
                try await fallback.prepare()
                let result = try await fallback.generateNotes(request, purpose: purpose)
                context.record.fallback = NotesFallbackRecord(
                    primaryEngineID: primary.id, reason: primaryReason,
                    fallbackEngineID: fallback.id)
                return .produced(result)
            } catch {
                // Both-fail → stage failure, BOTH reasons recorded.
                throw PipelineError(
                    stage: .notes,
                    message:
                        "notes failed on both engines — \(primary.id): \(primaryReason); \(fallback.id): \(Self.describe(error))"
                )
            }
        }
    }

    /// Stage-10 LLM-name application, shared with the notes-only resume:
    /// drop `low`-confidence proposals, first-wins per label, then the
    /// validated `apply()` (mechanical names win by no-overwrite).
    private func applyProposals(
        _ proposals: [SpeakerNameProposal], to segments: [TranscriptSegment],
        meeting: Meeting, eventNames: Set<String>, user: UserIdentity,
        vocabulary: PipelineVocabulary
    ) -> [TranscriptSegment] {
        var assignments: [String: String] = [:]
        for confidence in [ProposalConfidence.high, .medium] {
            for proposal in proposals where proposal.confidence == confidence {
                if let name = proposal.name, assignments[proposal.label] == nil {
                    assignments[proposal.label] = name
                }
            }
        }
        guard !assignments.isEmpty else { return segments }
        return SpeakerResolution(assignments: assignments, unresolved: []).apply(
            to: segments,
            attendeeNames: Set(meeting.attendees.map(\.name)),
            eventNames: eventNames,
            userName: user.name,
            suppression: vocabulary.suppression,
            commonNames: vocabulary.commonNames)
    }

    // MARK: - G2 §3 name-substitution pass (generate / regenerate / pending-resume)

    /// Runs the deterministic name-substitution pass over the produced notes
    /// (§3), recording the report into notes provenance. Pure-function inputs
    /// are assembled from the durable correction store, the run's resolved
    /// speaker names + attendees (rule-2 candidates), and the run vocabulary
    /// (br_common_names for the NH-2 guard, glossary canonicals for rule-3
    /// polish). Zero engine calls. With an empty store this is the identity on
    /// the notes (AC6) and leaves the empty report off the payload.
    private func applyNameSubstitution(
        to notesResult: NotesResult, meeting: Meeting, segments: [TranscriptSegment],
        vocabulary: PipelineVocabulary
    ) async -> NotesResult {
        let context = await nameSubstitutionContext(
            meeting: meeting, segments: segments, vocabulary: vocabulary)
        let (substituted, report) = NameSubstitution.apply(
            notes: notesResult.structured, context: context)
        var result = notesResult
        result.structured = substituted
        result.provenance.nameSubstitutions = report
        return result
    }

    /// Builds the §3 substitution context (store rows, rule-2 candidates, the
    /// common-name set, and the rule-3 polish canonicals) once, shared by the
    /// notes pass and the speaker-label pass.
    private func nameSubstitutionContext(
        meeting: Meeting, segments: [TranscriptSegment], vocabulary: PipelineVocabulary
    ) async -> NameSubstitution.Context {
        let storeRows: [NameSubstitution.StoreRow] =
            (try? await database.pool.read { db in
                try NameCorrectionStore.all(db).map {
                    NameSubstitution.StoreRow(
                        mishearedFolded: $0.mishearedFolded, replacement: $0.replacement,
                        everyday: $0.everyday)
                }
            }) ?? []

        // Rule-2 candidates: resolved speaker names ∪ attendee names.
        var ownerCandidates = Set(segments.compactMap(\.speakerName))
        ownerCandidates.formUnion(meeting.attendees.map(\.name))

        return NameSubstitution.Context(
            store: storeRows,
            ownerCandidates: Array(ownerCandidates),
            commonNames: vocabulary.commonNames,
            polishCanonicals: Self.polishCanonicals(vocabulary))
    }

    /// The §4 rename-input normalization context: store rows + the rule-3 polish
    /// canonicals (no segment candidates — normalization is store/polish only).
    private func renameNormalizationContext() async -> NameSubstitution.Context {
        let storeRows: [NameSubstitution.StoreRow] =
            (try? await database.pool.read { db in
                try NameCorrectionStore.all(db).map {
                    NameSubstitution.StoreRow(
                        mishearedFolded: $0.mishearedFolded, replacement: $0.replacement,
                        everyday: $0.everyday)
                }
            }) ?? []
        let vocabulary = vocabularyProvider().vocabulary
        return NameSubstitution.Context(
            store: storeRows, ownerCandidates: [], commonNames: vocabulary.commonNames,
            polishCanonicals: Self.polishCanonicals(vocabulary))
    }

    /// G2 §1/§3: apply the store (rule 1) + rule-3 polish to the mechanical/LLM
    /// speaker NAMES on segments BEFORE user renames — a misheard `speaker_name`
    /// ("SEMI") is outranked by a `semi → Sammy` store row, so the correction
    /// reaches the transcript labels and the evidence payload, not just notes.
    /// Returns the segments with corrected names (only named segments change).
    private func applyStoreToSpeakerLabels(
        _ segments: [TranscriptSegment], context: NameSubstitution.Context
    ) -> [TranscriptSegment] {
        guard !context.store.isEmpty || !context.polishCanonicals.isEmpty else { return segments }
        // Resolve each distinct existing name once.
        var corrected: [String: String] = [:]
        for name in Set(segments.compactMap(\.speakerName)) {
            let fixed = NameSubstitution.applyToLabel(name, context: context)
            if fixed != name { corrected[name] = fixed }
        }
        guard !corrected.isEmpty else { return segments }
        return segments.map { segment in
            guard let name = segment.speakerName, let fixed = corrected[name] else { return segment }
            var copy = segment
            copy.speakerName = fixed
            return copy
        }
    }

    /// Rule-3 polish set (§3): glossary canonicals that are NON-correction-
    /// limited and NON-lexicon — i.e. distinctive single-token canonicals whose
    /// folded cores are not everyday words. The corrector already drops
    /// everyday-only canonicals from registration; here we re-derive the
    /// eligible set from the dictionary against the everyday test so the polish
    /// never fires on an ordinary word.
    static func polishCanonicals(_ vocabulary: PipelineVocabulary) -> [String] {
        guard let lexicons = try? PipelineVocabulary.sharedLexicons() else { return [] }
        return vocabulary.dictionary.entries.map(\.canonical).filter { canonical in
            let cores = AliasCoreScan.peeledCores(canonical)
            guard !cores.isEmpty else { return false }
            // Non-lexicon: no core is everyday; single distinctive token only
            // (multi-token canonicals are out of rule-3's surface-only scope).
            return cores.count == 1
                && !cores.contains { PipelineVocabulary.isEveryday($0, lexicons: lexicons) }
        }
    }

    // MARK: - G13 S-label neutralizer label map

    /// The G13 label→name map for a meeting: a resolved speaker mapping (the
    /// segments' `speakerLabel → speakerName`) ∪ active (non-stale)
    /// `speaker_rename` rows. Rename rows WIN — a user rename outranks
    /// mechanical/LLM naming (§1). `SLabelNeutralizer.neutralize` substitutes
    /// these into `notes.structured` (layer 1); any label with no entry here is
    /// neutralized to a neutral descriptor / honest-empty owner (layer 2).
    private func slabelMap(
        meetingID: MeetingID, segments: [TranscriptSegment]
    ) async -> [String: String] {
        var map: [String: String] = [:]
        // Resolved speaker mapping from the persisted transcript.
        for segment in segments {
            if let name = segment.speakerName, !name.isEmpty {
                map[segment.speakerLabel] = name
            }
        }
        // Active rename rows override (the user-rename-wins rule).
        let renames = (try? await database.pool.read { db in
            try SpeakerRenameStore.all(db, meetingID: meetingID)
        }) ?? []
        for row in renames where !row.stale && !row.name.isEmpty {
            map[row.speakerLabel] = row.name
        }
        return map
    }

    // MARK: - G14 memory-digest generation (the second synthesis call)

    /// The outcome of the digest attempt fired after the notes. `produced` is a
    /// clean (already-`neutralizeText`'d) digest string; `failed` means the call
    /// failed past its bounded retry (→ digest-pending marker, payload omits
    /// `memory_digest`); `disabled` means the toggle is OFF (no call, no field).
    private enum DigestOutcome {
        case produced(String)
        case failed(reason: String)
        case disabled
    }

    /// The digest string to persist (`produced` → the clean string; `failed` /
    /// `disabled` → nil, so the payload omits `memory_digest`).
    private static func digestStringOrNil(_ outcome: DigestOutcome) -> String? {
        if case .produced(let digest) = outcome { return digest }
        return nil
    }

    /// Fires the SECOND synthesis call (`generateDigest`) after the notes when
    /// the Settings → Handoff toggle is ON, neutralizes residual S-labels in the
    /// produced digest string (the same emphasis-aware G13 detector, via the
    /// new `SLabelNeutralizer.neutralizeText` flat-string entry point), and
    /// returns the clean digest. The digest rides the SAME engine the user
    /// selected for notes (the swappable seam). Bounded transient retry lives
    /// INSIDE `generateDigest`; a failure that survives it returns `.failed`
    /// (non-fatal — the caller writes the digest-pending marker and the run
    /// still completes). `notes` is the name-substituted `NotesStructured`
    /// salience guide; the digest re-derives facts from `segments`.
    ///
    /// T3.1 (md-v3): the digest request also carries the app-derived structured
    /// inputs — `scopedAliasBindings` (alias→canonical, admitted ONLY on actual
    /// alias evidence: a corrected-transcript alias surface OR an applied
    /// `.alias` correction; never on canonical-presence alone) and `hostBinding`
    /// (the `user`-track owner). `corrections` carries the applied corrections so
    /// the correction-limited path is reachable on the first run.
    ///
    /// T3.1 AC2 — RESUME PARITY: the first run's RESOLVED scoped set is persisted
    /// on the `meeting_notes` row; the bare digest-resume path (`digestOnlyBody`)
    /// reloads it and passes `scopedAliasBindingsOverride`, so a correction-
    /// limited alias (path (ii) — never reconstructable on resume because the
    /// `AppliedCorrection` records are gone) survives. The override, when
    /// present, REPLACES derivation entirely; the resolved set is stashed on the
    /// context so the persist step records it for the next resume.
    private func generateMemoryDigest(
        meetingID: MeetingID, meeting: Meeting, notes: NotesStructured,
        segments: [TranscriptSegment], dominantLanguage: String,
        vocabulary: PipelineVocabulary, user: UserIdentity, context: RunContext,
        corrections: [AppliedCorrection] = [],
        scopedAliasBindingsOverride: [AliasPair]? = nil
    ) async -> DigestOutcome {
        guard await MemoryDigestSettings.isEnabled(in: settings) else { return .disabled }

        // The override (digest-resume: the persisted first-run set) REPLACES
        // derivation — path (ii) is unreachable on resume (the records are gone),
        // so deriving here would silently drop a correction-limited alias.
        let scopedAliasBindings = scopedAliasBindingsOverride
            ?? DigestStructuredInputs.scopedAliasBindings(
                dictionary: vocabulary.dictionary,
                correctedSegments: segments,
                corrections: corrections)
        // Record the resolved set so the persist step writes it for the next
        // resume (a no-op when the resume itself just replayed a persisted set).
        context.resolvedScopedAliasBindings = scopedAliasBindings
        let hostBinding = DigestStructuredInputs.hostBinding(user: user)
        // #101: grounded person-mention hints — derived inside the shared digest
        // entry so ALL THREE digest call sites (full-run, notes-only resume,
        // digest-only resume) carry them identically. The everyday-rejected
        // aliases come from the per-run vocabulary load; attendees + the corrected
        // segments are the grounding inputs.
        let groundedPersonHints = GroundedPersonHints.groundedPersonHints(
            vocabulary: vocabulary, attendees: meeting.attendees, segments: segments)
        context.record.groundedPersonHintCount = groundedPersonHints.count

        // Optional knowledge glossary — load the user-configured file gracefully
        // (default-empty path → nil → no block, byte-identical to before). It
        // carries on the SINGLE `request` below, so ALL passes that share it
        // (synthesis + combined-audit + the md-v5 verify/reconcile) see it. Loaded
        // HERE, before the synthesis call, not at the post-call exclude-projects
        // read. Missing / empty / unreadable file → skipped, no block.
        let kgPath = await MemoryDigestSettings.knowledgeGlossaryPath(in: settings)
        var knowledgeGlossary: String? = nil
        if !kgPath.isEmpty {
            let expanded = (kgPath as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expanded),
                let s = try? String(contentsOfFile: expanded, encoding: .utf8), !s.isEmpty {
                knowledgeGlossary = s
            }
        }

        let request = DigestRequest(
            meeting: meeting,
            transcript: segments,
            notes: notes,
            dominantLanguage: dominantLanguage,
            vocabulary: vocabulary.canonicalTerms,
            user: user,
            scopedAliasBindings: scopedAliasBindings,
            hostBinding: hostBinding,
            groundedPersonHints: groundedPersonHints,
            knowledgeGlossary: knowledgeGlossary)

        // DEV-ONLY recall-gate capture (env-gated; OFF by default; NEVER alters
        // the digest, the payload, or any persisted state). When
        // BLAISE_DUMP_DIGEST_INPUT=1, write the byte-exact rendered user message
        // the model is about to receive — CANONICAL VOCABULARY + ALIAS
        // RESOLUTION + MEETING/HOST + TRANSCRIPT with provenance markers — to the
        // MEETING'S OWN directory at `<meetingDir>/.digest_input.txt`, so the
        // recall-gate judge sees EXACTLY what the model saw AND the dump (which
        // carries the same PII as the transcript) is REAPED with the meeting on
        // delete (it no longer survives in a sibling `_recall_gate` dir).
        // `userMessage(for:)` is a pure re-render of the SAME `request` the engine
        // renders, so the dump is byte-identical to the model input; this is a
        // read-only side effect captured before the call so it lands even if the
        // digest call later fails.
        if ProcessInfo.processInfo.environment["BLAISE_DUMP_DIGEST_INPUT"] == "1" {
            let dumpURL = database.paths.meetingDirectory(meetingID)
                .appendingPathComponent(".digest_input.txt")
            try? Data(DigestPromptBuilder.userMessage(for: request).utf8).write(
                to: dumpURL, options: .atomic)
            logger.notice("recall-gate: dumped digest input for \(meetingID, privacy: .public)")
        }
        // The digest call bills under `.digest` for first-time generation; a
        // resume/regeneration re-fire bills `.regeneration` (set on the context
        // by the resume path). The MLX path spends nothing.
        let purpose: CloudSpendPurpose = context.digestPurpose ?? .digest
        do {
            let resolved = try await resolver.resolveSummarization()
            let engine = resolved.engine
            try await engine.prepare()
            if context.cancelToken?.isCancelled == true { throw EngineError.cancelled }
            let result = try await CancellationToken.$current.withValue(context.cancelToken) {
                try await engine.generateDigest(request, purpose: purpose)
            }
            // G13-clean guarantee delivered HERE: neutralize every residual
            // S-label in the produced digest string (incl. a model-authored
            // `_S0_`/`**S0**`) to the unattributed prose descriptor. The label
            // map resolves known speakers to names; an unknown becomes a neutral
            // descriptor — never an invented identity.
            let labelMap = await slabelMap(meetingID: meetingID, segments: segments)
            let clean = SLabelNeutralizer.neutralizeText(
                result.digest, labelMap: labelMap, language: dominantLanguage)

            // Deterministic final-mile normalization (NOT env-gated; pure; runs as
            // the LAST step on WHATEVER digest is ultimately returned — after the
            // neutralizer and after every LLM pass): (1) date correction (a
            // conservative ±3-day ISO fix); (2) md-v5 `DigestNormalizer` — strip
            // the configured non-project/tooling terms from the HEADER `projects:`
            // line and dedup it. The exclusion list is user settings + the
            // recall-gate env override; EMPTY = exact no-op. Body prose untouched.
            let settingsExclude = await MemoryDigestSettings.excludeProjects(in: settings)
            let envExclude = (ProcessInfo.processInfo.environment["BLAISE_DIGEST_EXCLUDE_PROJECTS"] ?? "")
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let excludeProjects = settingsExclude + envExclude
            func dateCorrected(_ digest: String) -> String {
                DigestNormalizer.normalize(
                    DigestDateNormalizer.normalize(digest, meetingDate: meeting.startedAt),
                    excludeProjects: excludeProjects)
            }

            // md-v6 (combined audit — the 3-pass digest): ONE audit pass folds the
            // md-v5 transcript-only verify AND the notes reconcile into a single
            // call (verify STEP 1, then reconcile STEP 2). It runs AFTER synthesis
            // and ships the audited result; the separate verify+reconcile blocks
            // BELOW are the md-v5 rollback path (reached only if `shippedVersion`
            // is flipped back to `.mdV5`). Gated by EITHER the "Verify & repair" or
            // the "Reconcile against notes" toggle (both default ON) / the dev env
            // overrides — turning EITHER on runs the combined audit; both OFF ships
            // the bare single-call synthesis draft. Claude-only (the MLX path has
            // no audit call and ships `clean`). ROBUSTNESS: any throw (incl. cancel)
            // falls back to the synthesis draft `clean` — the digest is NEVER lost
            // because the audit failed.
            if DigestPromptBuilder.shippedVersion == .mdV6 {
                // Hoist both async toggle reads out of the `||` chain: the `||`
                // right-operand is an autoclosure that cannot `await`.
                let verifyOn = await MemoryDigestSettings.isVerifyEnabled(in: settings)
                let reconcileOn = await MemoryDigestSettings.isReconcileEnabled(in: settings)
                let auditRequested =
                    verifyOn
                    || reconcileOn
                    || ProcessInfo.processInfo.environment["BLAISE_DIGEST_VERIFY"] == "1"
                    || ProcessInfo.processInfo.environment["BLAISE_DIGEST_RECONCILE"] == "1"
                // #102: the cost toggle — does the COMBINED AUDIT run on Haiku?
                // Hoisted out of the `||` (the right operand is a non-awaiting
                // autoclosure). Settings OR the dev env override, default OFF →
                // Sonnet. This is the ONLY call site that may pick Haiku; notes,
                // synthesis, and the md-v5 verify/reconcile passes never read it.
                let haikuOn = await MemoryDigestSettings.isHaikuAuditEnabled(in: settings)
                    || ProcessInfo.processInfo.environment["BLAISE_HAIKU_AUDIT"] == "1"
                if auditRequested, let claudeEngine = engine as? ClaudeSummarizationEngine {
                    do {
                        if context.cancelToken?.isCancelled == true { throw EngineError.cancelled }
                        let audited = try await CancellationToken.$current.withValue(context.cancelToken) {
                            // #102 (F8): when ON pass the QUALIFIED const
                            // `ClaudeSummarizationEngine.haikuModel` (here `Self` is
                            // ProcessingPipeline — `Self.haikuModel` would not
                            // compile); when OFF omit the arg so the engine's
                            // `= Self.model` default keeps it byte-identical Sonnet.
                            if haikuOn {
                                return try await claudeEngine.combinedAuditDigest(
                                    request, draftDigest: clean, purpose: purpose,
                                    model: ClaudeSummarizationEngine.haikuModel)
                            }
                            return try await claudeEngine.combinedAuditDigest(
                                request, draftDigest: clean, purpose: purpose)
                        }
                        let auditedClean = SLabelNeutralizer.neutralizeText(
                            audited.digest, labelMap: labelMap, language: dominantLanguage)
                        return .produced(dateCorrected(auditedClean))
                    } catch {
                        logger.warning(
                            "digest combined-audit pass failed for \(meetingID, privacy: .public): \(Self.describe(error), privacy: .public) — falling back to the unaudited synthesis draft digest")
                        return .produced(dateCorrected(clean))
                    }
                }
                return .produced(dateCorrected(clean))
            }

            // OPTIONAL second verify/repair pass (TRANSCRIPT-only). Gated by the
            // Settings → Handoff "Verify & repair memory digest" toggle (default
            // ON) / dev env `BLAISE_DIGEST_VERIFY=1`. When ON and the engine is the
            // cloud Claude engine, run a focused auditor that repairs grounding
            // errors against the transcript and neutralize its output the SAME way.
            // The MLX path has no verify call. ROBUSTNESS: any throw (incl. cancel)
            // falls back to the synthesis draft `clean` — the digest is NEVER lost
            // because the audit failed.
            var transcriptDigest = clean
            let verifyRequested = await MemoryDigestSettings.isVerifyEnabled(in: settings)
                || ProcessInfo.processInfo.environment["BLAISE_DIGEST_VERIFY"] == "1"
            if verifyRequested,
                let claudeEngine = engine as? ClaudeSummarizationEngine {
                do {
                    if context.cancelToken?.isCancelled == true { throw EngineError.cancelled }
                    let verified = try await CancellationToken.$current.withValue(context.cancelToken) {
                        try await claudeEngine.verifyDigest(
                            request, draftDigest: clean, purpose: purpose)
                    }
                    transcriptDigest = SLabelNeutralizer.neutralizeText(
                        verified.digest, labelMap: labelMap, language: dominantLanguage)
                } catch {
                    logger.warning(
                        "digest verify pass failed for \(meetingID, privacy: .public): \(Self.describe(error), privacy: .public) — falling back to the unverified draft digest")
                }
            }

            // md-v5 THIRD pass — NOTES-ANCHORED RECALL RECONCILIATION. Runs AFTER
            // ALL transcript work (synthesis + verify). Gated by the "Reconcile
            // against notes" toggle (default ON) / dev env
            // `BLAISE_DIGEST_RECONCILE=1`. Claude-only (the MLX path has no
            // reconcile call and ships `transcriptDigest`). It ADDS a human-notes
            // item to the digest ONLY when the transcript body grounds it
            // (additive-only, transcript-gated, never edits the notes, never
            // launders an ungroundable note) — anchoring recall to the STABLE notes
            // so a grounded contributor/figure can't randomly drop run-to-run.
            // ROBUSTNESS: any throw (incl. cancel) falls back to `transcriptDigest`
            // — reconciliation never costs the good digest.
            let reconcileRequested = await MemoryDigestSettings.isReconcileEnabled(in: settings)
                || ProcessInfo.processInfo.environment["BLAISE_DIGEST_RECONCILE"] == "1"
            if reconcileRequested,
                let claudeEngine = engine as? ClaudeSummarizationEngine {
                do {
                    if context.cancelToken?.isCancelled == true { throw EngineError.cancelled }
                    let reconciled = try await CancellationToken.$current.withValue(context.cancelToken) {
                        try await claudeEngine.reconcileDigest(
                            request, draftDigest: transcriptDigest, purpose: purpose)
                    }
                    let reconciledClean = SLabelNeutralizer.neutralizeText(
                        reconciled.digest, labelMap: labelMap, language: dominantLanguage)
                    return .produced(dateCorrected(reconciledClean))
                } catch {
                    logger.warning(
                        "digest notes-reconcile pass failed for \(meetingID, privacy: .public): \(Self.describe(error), privacy: .public) — falling back to the pre-reconcile digest")
                    return .produced(dateCorrected(transcriptDigest))
                }
            }
            return .produced(dateCorrected(transcriptDigest))
        } catch {
            let reason = Self.describe(error)
            logger.warning(
                "memory digest failed for \(meetingID, privacy: .public): \(reason, privacy: .public) — meeting still ready; digest-pending, self-heals on launch/key-save/network/regenerate")
            return .failed(reason: reason)
        }
    }

    /// Writes the `digest-pending:` marker WITHOUT disturbing the meeting's
    /// `ready` status or its content `updatedAt` (the marker is bookkeeping,
    /// like the notes-pending refresh). A committed `cancelled` is never
    /// overwritten. Distinct from `writeNotesPending`: this never flips status
    /// to `failed` — a digest failure leaves a fully-usable `ready` meeting.
    private func writeDigestPending(meetingID: MeetingID, reason: String) async {
        try? await database.pool.write { db in
            guard var meeting = try Meeting.fetchOne(db, key: meetingID) else { return }
            guard meeting.status != .cancelled else { return }
            meeting.lastProcessingError = DigestPendingClass.marker(reason)
            // No status change, no updatedAt bump — the meeting stays ready and
            // its content is unchanged; only the digest is owed.
            try meeting.update(db)
        }
    }

    /// Clears a `digest-pending:` marker after a successful digest re-fire (only
    /// when the live marker is STILL digest-pending — never clobbers a marker a
    /// concurrent run wrote).
    private func clearDigestPending(meetingID: MeetingID) async {
        try? await database.pool.write { db in
            guard var meeting = try Meeting.fetchOne(db, key: meetingID) else { return }
            guard DigestPendingClass.isPending(meeting.lastProcessingError) else { return }
            meeting.lastProcessingError = nil
            try meeting.update(db)
        }
    }

    // MARK: - Stages 12+13 (shared by the full run and the notes-only resume)

    /// persistNotes (render in the persisted dominant language) + finalize
    /// (builder reads the now-final DB state → immutable payload write →
    /// `finalizeMeetingProcessing`: status=ready + notes upsert + enqueue in
    /// ONE transaction). The caller kicks the handoff worker.
    private func persistNotesAndFinalize(
        meetingID: MeetingID, notesResult: NotesResult, dominantLanguage: String,
        meetingTitle: String, user: UserIdentity, context: RunContext,
        memoryDigest: String?
    ) async throws {
        let paths = database.paths

        // G12 LLM tier — PROMOTE the notes engine's `NotesStructured.title` to
        // `meeting.title` BEFORE the stage-12 markdown render (so BOTH the
        // human-facing markdown and the stage-13 payload carry the promoted
        // title from one source). Gated to the `default`/`llm` tiers:
        //   - `default` (ad-hoc, no user/calendar title) → claim it as `llm`;
        //   - `llm` (a prior generation already promoted) → REFRESH from the
        //     newer generation, still `llm` (regeneration refreshes llm only);
        //   - `user`/`calendar` → untouched (higher tiers are authoritative).
        // No prompt change: this reuses a field the CURRENT notes prompt
        // already produces. A `var` so the stage-12 render below uses the
        // promoted title rather than the date-default captured at run start.
        var renderTitle = meetingTitle
        // The promoted (trimmed, ≤80-char) value the stage-12 markdown H1 must
        // carry so the human notes surface and the payload agree on one title.
        // `nil` when no promotion committed (the render keeps the raw structured
        // title and falls back to `renderTitle` only if that flattens to blank).
        var promotedStructuredTitle: String? = nil
        if let promoted = Self.promotedLLMTitle(from: notesResult.structured.title) {
            let timestamp = self.now()
            let committed = try await self.database.pool.write { db -> String? in
                guard let meeting = try Meeting.fetchOne(db, key: meetingID) else { return nil }
                // The non-null/non-empty gate already passed; here the tier
                // gate. A surgical two-column write — never a full-row write
                // that could clobber a concurrent rename.
                guard meeting.titleSource == .default || meeting.titleSource == .llm else {
                    return nil
                }
                try db.execute(
                    sql: "UPDATE meeting SET title = ?, title_source = ?, updated_at = ? WHERE id = ?",
                    arguments: [promoted, TitleSource.llm.rawValue, timestamp, meetingID])
                return promoted
            }
            if let committed {
                renderTitle = committed
                promotedStructuredTitle = committed
            }
        }

        // 12. persistNotes — render in the persisted dominant language.
        try await stage(.persistNotes, context, meetingID) {
            var provenance = notesResult.provenance
            provenance.pipelineVersion = PipelineVersion.current
            provenance.rendererVersion = NotesRenderer.version
            provenance.userName = user.name
            // G13: neutralize S-labels as the LAST write to notes.structured
            // before stage 12 persists it — stage 13 re-fetches THIS row and
            // build()s it, and a .preFinalize kill resumes on the clean row.
            let finalizeSegments = try await TranscriptRepository(database: self.database)
                .segments(meetingID: meetingID)
            let labelMap = await self.slabelMap(
                meetingID: meetingID, segments: finalizeSegments)
            let neutralized = SLabelNeutralizer.neutralize(
                notes: notesResult.structured, labelMap: labelMap,
                language: dominantLanguage).notes
            // The human markdown H1 must carry the promoted (trimmed, ≤80-char)
            // title — the SAME bytes as `meeting.title` and the payload — not the
            // raw, untruncated `NotesStructured.title`. The renderer derives the
            // H1 from `s.title` first, so render against a title-overridden COPY
            // when a promotion committed; without it a 200-char raw title would
            // leave a 200-char on-disk H1 while the payload/`meeting.title` are
            // truncated to 80 (a Floor-5 divergence between the human notes
            // surface and the payload). The PERSISTED structured notes keep the
            // raw `s.title` (the AI surface / verbatim model output is untouched).
            var renderStructured = neutralized
            if let promotedStructuredTitle {
                renderStructured.title = promotedStructuredTitle
            }
            let markdown = try NotesRenderer.render(
                renderStructured, language: dominantLanguage, meetingTitle: renderTitle,
                userName: user.name)
            // G14: the digest is persisted on the same notes row so stage 13's
            // build() picks it up (presence-gated). `memoryDigest` is the
            // ALREADY-neutralized clean digest string (or nil: toggle off, or a
            // digest-call failure that fell through to digest-pending — the
            // marker is written by the caller after finalize).
            // T3.1 AC2: persist this run's RESOLVED scoped alias bindings on the
            // SAME row (empty when no digest call ran), so the bare digest-resume
            // path replays them and scopes identically (a correction-limited
            // alias survives a digest-resume). NOT a payload input (versionHash
            // unaffected, AC7).
            let notes = MeetingNotes(
                meetingID: meetingID,
                markdown: markdown,
                structured: neutralized,
                language: dominantLanguage,
                generatedAt: self.now(),
                provenance: provenance,
                memoryDigest: memoryDigest,
                scopedAliasBindings: context.resolvedScopedAliasBindings ?? [])
            try await NotesRepository(database: self.database).upsert(notes)
            try Data(markdown.utf8).write(to: paths.notesURL(meetingID), options: .atomic)
        }

        // 13. finalize.
        try await stage(.finalize, context, meetingID) {
            guard
                let finalMeeting = try await MeetingRepository(database: self.database)
                    .fetch(meetingID),
                let finalNotes = try await NotesRepository(database: self.database)
                    .fetch(meetingID: meetingID)
            else {
                throw PipelineError(stage: .finalize, message: "meeting state vanished mid-run")
            }
            let finalSegments = try await TranscriptRepository(database: self.database)
                .segments(meetingID: meetingID)
            let payload = EvidencePayloadBuilder.build(
                meeting: finalMeeting, segments: finalSegments, notes: finalNotes, user: user)
            let relativePath = paths.relativeHandoffPayloadPath(
                meetingID: meetingID, versionHash: payload.versionHash)
            try ImmutablePayloadWriter.write(
                payload.bytes, to: self.database.rootURL.appendingPathComponent(relativePath))
            PipelineCrashHooks.maybeKill(.preFinalize)
            try await self.database.finalizeMeetingProcessing(
                meetingID: meetingID,
                versionHash: payload.versionHash,
                payloadPath: relativePath,
                notes: finalNotes)
            context.record.versionHash = payload.versionHash
            context.record.payloadPath = relativePath
        }
    }

    /// G12 LLM-title gate + normalization (pure, unit-testable): trims the
    /// notes engine's `NotesStructured.title`, rejects an empty/whitespace-only
    /// value (the non-null/non-empty gate → no promotion), and truncates to
    /// `maxTitleLength` characters with a trailing ellipsis. Returns nil when
    /// there is no promotable title. NO prompt change — this only normalizes an
    /// existing field the current prompt already produces.
    static let maxTitleLength = 80

    static func promotedLLMTitle(from rawTitle: String?) -> String? {
        guard let raw = rawTitle else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > maxTitleLength else { return trimmed }
        // Truncate to (max − 1) characters + ellipsis so the result is exactly
        // `maxTitleLength` characters (the ellipsis is one Character).
        let prefix = trimmed.prefix(maxTitleLength - 1)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix + "…"
    }

    // MARK: - Notes-only resume (D17 self-heal)

    /// Resumes a notes-pending meeting WITHOUT re-running ASR: rebuilds the
    /// NotesRequest from the persisted transcript + meeting row (the DB is
    /// the source of truth — segments, dominantLanguage, attendees and the
    /// bundled vocabulary are all durable), then notes → LLM-name
    /// application → finalize (a full reprocess costs 2–3 min and 3–5 GB
    /// per retry; this costs one engine call).
    ///
    /// Returns nil (no-op) when the meeting is no longer notes-pending —
    /// race-safe against a concurrent full reprocess by the pipeline's
    /// run-entry semantics: every entry point runs on the single-flight
    /// chain, so runs are serialized and whichever runs second sees the
    /// other's terminal state.
    ///
    /// Failure KEEPS the meeting pending (marker refreshed with the new
    /// reason): the durable state is still transcript-persisted/notes-absent
    /// and the next self-heal trigger retries.
    ///
    /// G15: `confirmingParticipants` is set ONLY when the user acted on the
    /// participant-confirmation sheet (Confirm or Skip) — that resume BYPASSES
    /// the participant gate. Every other trigger (launch/key-save self-heal)
    /// leaves it false so an unconfirmed gated meeting re-parks (§2/AC5).
    @discardableResult
    public func processNotesOnly(
        meetingID: MeetingID, confirmingParticipants: Bool = false
    ) async throws -> PipelineRunRecord? {
        try await chain.run {
            try await self.notesOnlyBody(
                meetingID: meetingID, confirmingParticipants: confirmingParticipants)
        }
    }

    /// Self-heal trigger entry (app launch / API-key save in Settings /
    /// network-path restoration): re-dispatches every notes-pending meeting
    /// through the notes-only resume, oldest first. Per-meeting failures are
    /// swallowed — each meeting's refreshed marker carries its reason.
    /// Month rollover needs no trigger of its own: the ceiling is
    /// re-evaluated on the next attempt, and launch/network cover it.
    public func resumePendingNotes() async {
        // G10 §1 (H-1): the self-heal is an AUTO-KICK path in the cancelled
        // refusal set. Exclude `cancelled` rows from the enumeration outright —
        // a meeting can carry a live `notes-pending:` marker while cancelled
        // (the user clicked Process on a pending meeting, then cancelled
        // mid-run; the cancel preserves the stale marker). `notesOnlyBody`
        // guards this too (defence in depth for a direct `processNotesOnly`).
        let pending: [MeetingID] =
            (try? await database.pool.read { db in
                try MeetingID.fetchAll(
                    db,
                    sql:
                        "SELECT id FROM meeting WHERE last_processing_error LIKE ? AND status != ? ORDER BY started_at, id",
                    arguments: [NotesPendingClass.prefix + "%", MeetingStatus.cancelled.rawValue])
            }) ?? []
        let queueRepo = ProcessingQueueRepository(database: database)
        for meetingID in pending {
            // C4 (F1 Inc2): skip a meeting that already has a live (pending/
            // running) queued full-run job — that run produces notes anyway; a
            // redundant notes-only cloud call here would waste budget and could
            // overwrite newer output. (Both serialize on the chain, so it's not
            // a correctness breach — this is the cost/freshness guard.)
            if ((try? await queueRepo.liveJob(meetingID: meetingID)) ?? nil) != nil { continue }
            _ = try? await processNotesOnly(meetingID: meetingID)
        }
    }

    private func notesOnlyBody(
        meetingID: MeetingID, confirmingParticipants: Bool = false
    ) async throws -> PipelineRunRecord? {
        // Absorb Meet roster rows queued while the meeting sat pending
        // (C10's absorption point is the full run's entry, which the resume
        // bypasses): the resume is a sanctioned content write followed by a
        // fresh mint, so late roster names reach the notes prompt, the
        // LLM-name validation set, and the minted payload instead of
        // stranding in `meet_roster_pending`. updatedAt bumps only when an
        // attendee was actually added (content-only rule, C1 v6.7). Late
        // speaker EVENTS need no equivalent: `notesOnlyStages` reads
        // `meeting_speaker_event` fresh.
        let timestamp = now()
        // G7 (M-1): does the meeting ALREADY have persisted notes coming into
        // this resume? If so, the resume re-runs notes for an already-noted
        // meeting → `.regeneration`. If not (the common D17 case: the original
        // process() hit the ceiling / had no key and never produced notes),
        // this resume mints the meeting's FIRST notes → `.generation`. Read in
        // the same transaction that absorbs the roster, before notes land.
        let hadNotesBefore = try await database.pool.read { db -> Bool in
            try MeetingNotes.filter(key: meetingID).fetchCount(db) > 0
        }
        let fetched = try await database.pool.write { db -> Meeting? in
            guard var meeting = try Meeting.fetchOne(db, key: meetingID) else { return nil }
            // G10 §1 (H-1): the self-heal is an AUTO-KICK path and MUST refuse a
            // user-cancelled meeting. A meeting can be `cancelled` while STILL
            // carrying a live `notes-pending:` marker: the first run hit
            // notes-pending (status `failed` + marker, D17); the user clicked
            // Process; the re-run's `writeRunEntry` clears only `processingNote`,
            // never `lastProcessingError`, so the stale marker persists; the
            // user cancelled mid-run, committing `cancelled`. Without this guard
            // the next self-heal trigger (launch / API-key save / network
            // restore) would resurrect the cancelled meeting to `ready` and
            // incur cloud spend on work the user explicitly cancelled. Returning
            // the meeting unmodified makes `notesOnlyBody` no-op below (the
            // post-fetch isPending re-check stays the live-vs-late guard; this
            // is the cancelled-refusal guard, distinct from it).
            guard meeting.status != .cancelled else { return meeting }
            guard NotesPendingClass.isPending(meeting.lastProcessingError) else { return meeting }
            let attendeesBefore = meeting.attendees
            try MeetEventsIngestor.absorbPendingRoster(db, meeting: &meeting)
            if meeting.attendees != attendeesBefore {
                meeting.updatedAt = timestamp
                try meeting.update(db)
            }
            return meeting
        }
        guard let meeting = fetched else {
            throw BlaiseDatabaseError.meetingNotFound(meetingID)
        }
        // G10 §1 (H-1): refuse the cancelled meeting here too — a no-op return,
        // never the meeting-not-found throw. The in-transaction guard above
        // already skipped the roster absorption; this stops the notes run, so a
        // cancelled meeting carrying a stale `notes-pending:` marker is NEVER
        // resurrected by any self-heal trigger.
        guard meeting.status != .cancelled else { return nil }
        guard NotesPendingClass.isPending(meeting.lastProcessingError) else { return nil }
        let segments = try await TranscriptRepository(database: database)
            .segments(meetingID: meetingID)
        guard !segments.isEmpty, let dominantLanguage = meeting.dominantLanguage,
            let asrProvenance = meeting.asrProvenance
        else {
            throw PipelineError(
                stage: .notes,
                message: "notes-pending meeting has no persisted transcript to resume from")
        }

        emit(.runStarted(meetingID, regeneration: true))
        let context = RunContext(meetingID: meetingID, regeneration: true)
        // G10 §1: notes-resume cancel is status-silent (the meeting keeps its
        // `failed` + pending marker; the pending state is incomplete by
        // definition, so it consciously auto-retries at the next self-heal
        // trigger — v5.1). Install the token so a cancel binds at the cloud
        // attempt boundary.
        let cancelToken = installCancelToken(meetingID: meetingID, statusSilent: true)
        defer { removeCancelToken(meetingID: meetingID, token: cancelToken) }
        context.cancelToken = cancelToken
        // M-1: bill the resume's notes call by whether the meeting was already
        // noted, NOT by the (always-true) regeneration flag this path carries.
        context.notesPurpose = hadNotesBefore ? .regeneration : .generation
        context.currentStage = .notes
        // G1 §3: the notes-pending resume path also rebuilds the vocabulary
        // at run start (every run that constructs a notes vocabulary). §5b: the
        // load diagnostics ride the activity observable and are unified-logged.
        let userLoad = vocabularyProvider()
        reportGlossaryLoad(userLoad, meetingID: meetingID)
        let vocabulary = userLoad.vocabulary
        return try await notesOnlyStages(
            meeting: meeting, segments: segments, dominantLanguage: dominantLanguage,
            asrProvenance: asrProvenance, context: context, vocabulary: vocabulary,
            confirmingParticipants: confirmingParticipants, hadNotesBefore: hadNotesBefore)
    }

    private func notesOnlyStages(
        meeting: Meeting, segments: [TranscriptSegment], dominantLanguage: String,
        asrProvenance: ASRProvenance, context: RunContext, vocabulary: PipelineVocabulary,
        confirmingParticipants: Bool = false, hadNotesBefore: Bool = false
    ) async throws -> PipelineRunRecord {
        let meetingID = meeting.id
        let user = await userIdentity()

        // G15: re-evaluate the participant-confirmation gate on a self-heal
        // resume. A resume the user triggered by Confirm/Skip BYPASSES it
        // (`confirmingParticipants`); any other trigger (launch/key-save)
        // re-parks an unconfirmed gated meeting rather than silently proceeding
        // (§2/AC5). Confirm writes attendees, so the emptiness condition alone
        // already lets it through; the bypass is what carries a Skip (attendees
        // stay empty) past the gate for this one resume.
        if !confirmingParticipants,
            await shouldGateForParticipants(meeting: meeting, hasExistingNotes: hadNotesBefore)
        {
            let reason = NotesPendingClass.awaitingParticipantConfirmation
            context.record.notesPending = reason
            if !NotesPendingClass.isAwaitingParticipantConfirmation(meeting.lastProcessingError) {
                emit(.participantConfirmationNeeded(meetingID, title: meeting.title))
            }
            await writeNotesPending(meetingID: meetingID, regeneration: true, reason: reason)
            emit(.runCompleted(meetingID))
            return context.record
        }
        // Same prompt inputs as the pending run's stage 9: the persisted
        // segments ARE that run's stage-9 transcript (a pending run applies
        // no LLM names — there were no proposals), and the prompt reads only
        // durable fields (title, startedAt, attendees, dominantLanguage,
        // vocabulary, user identity). Pinned by the resume request-equality
        // unit test.
        let request = NotesRequest(
            meeting: meeting,
            transcript: segments,
            dominantLanguage: dominantLanguage,
            vocabulary: vocabulary.canonicalTerms,
            user: user,
            // #101: SAME derivation as the full-run stage-9 build (same
            // vocabulary, attendees, persisted stage-9 segments) — pinned
            // byte-equal by `resumeRebuildsTheSamePromptInputsAsStageNine`.
            groundedPersonHints: GroundedPersonHints.groundedPersonHints(
                vocabulary: vocabulary, attendees: meeting.attendees, segments: segments))

        do {
            let outcome = try await stage(.notes, context, meetingID) {
                try await self.generateNotesWithFallback(request, context: context)
            }
            guard case .produced(let notesResult) = outcome else {
                if case .pending(let reason) = outcome {
                    context.record.notesPending = reason
                    await writeNotesPending(meetingID: meetingID, regeneration: true, reason: reason)
                }
                emit(.runCompleted(meetingID))
                return context.record
            }
            context.record.notesEngineID = notesResult.provenance.engine
            context.record.notesUsage = notesResult.usage
            context.record.proposals = notesResult.speakerNameMapping

            // applyLLMNames over the persisted transcript; re-persist only
            // when a proposal actually named someone (same validation set as
            // the full run's stage 10).
            let captured = meeting.captured || hasMicTrack(meetingID)
            let storedEvents = try await MeetEventsRepository(database: database)
                .activeSpeakerEvents(meetingID: meetingID, excludingSelf: captured)
            var finalSegments = segments
            try await stage(.applyLLMNames, context, meetingID) {
                finalSegments = self.applyProposals(
                    notesResult.speakerNameMapping, to: segments, meeting: meeting,
                    eventNames: Set(storedEvents.map(\.displayName)), user: user,
                    vocabulary: vocabulary)
                context.record.namedSegmentCount =
                    finalSegments.filter { $0.speakerName != nil }.count
            }
            // G2 §1/§3: apply the store + rule-3 polish to speaker NAMES before
            // user renames (a misheard label is outranked by a store row).
            let labelContext = await nameSubstitutionContext(
                meeting: meeting, segments: finalSegments, vocabulary: vocabulary)
            finalSegments = applyStoreToSpeakerLabels(finalSegments, context: labelContext)

            // G2 §4: apply durable speaker-rename rows (artifact-present direct
            // apply; the resume never re-diarizes, so labels are stable).
            let renames = (try? await database.pool.read { db in
                try SpeakerRenameStore.all(db, meetingID: meetingID)
            }) ?? []
            finalSegments = SpeakerRenameStore.applyRenames(renames, to: finalSegments)
            context.record.finalSegmentCount = finalSegments.count
            if finalSegments != segments {
                try await stage(.persistTranscript, context, meetingID) {
                    let stored = try await self.database.persistTranscript(
                        meetingID: meetingID,
                        segments: finalSegments,
                        asrProvenance: asrProvenance,
                        dominantLanguage: dominantLanguage,
                        updatedAt: self.now())
                    try self.exportTranscriptJSON(
                        meetingID: meetingID, segments: stored,
                        provenance: asrProvenance, dominantLanguage: dominantLanguage)
                }
            }

            // G2 §3: name-substitution pass (pending-resume path) over the
            // final segments — same pure pass, zero engine calls.
            let substituted = await applyNameSubstitution(
                to: notesResult, meeting: meeting, segments: finalSegments,
                vocabulary: vocabulary)

            // G14: the second synthesis call also fires on the notes-only resume
            // (toggle-gated, non-fatal). A resume that produced new notes also
            // produces a fresh digest from them.
            let digestOutcome = await generateMemoryDigest(
                meetingID: meetingID, meeting: meeting, notes: substituted.structured,
                segments: finalSegments, dominantLanguage: dominantLanguage,
                vocabulary: vocabulary, user: user, context: context)
            let digest = Self.digestStringOrNil(digestOutcome)

            try await persistNotesAndFinalize(
                meetingID: meetingID, notesResult: substituted,
                dominantLanguage: dominantLanguage, meetingTitle: meeting.title,
                user: user, context: context, memoryDigest: digest)
            if case .failed(let reason) = digestOutcome {
                await writeDigestPending(meetingID: meetingID, reason: reason)
            }
            await handoffKicker.kick()
            await writeTerminalNote(
                meetingID: meetingID, fallback: context.record.fallback,
                clearCaptureRecovery: false)
            emit(.runCompleted(meetingID))
            return context.record
        } catch {
            // STILL pending: the durable state is unchanged (transcript
            // persisted, notes absent) — refresh the marker so the next
            // trigger retries, and surface the failure honestly.
            let message = Self.describe(error)
            let stage = context.currentStage
            logger.error("notes-only resume failed at \(stage.rawValue): \(message)")
            await writeNotesPending(meetingID: meetingID, regeneration: true, reason: message)
            emit(.runFailed(meetingID, stage: stage, message: message))
            throw PipelineError(stage: stage, message: message)
        }
    }

    /// D17 terminal write for a notes-pending run. process()-class runs land
    /// `failed` (NOT ready — ready ⇒ queued must hold; the reserved marker
    /// distinguishes the calm pending state from a real failure);
    /// regeneration-class runs keep their status (C1 no-regress: an
    /// already-ready meeting keeps its previous notes, the marker surfacing
    /// the mixed transcript/notes generation until the resume heals it).
    private func writeNotesPending(meetingID: MeetingID, regeneration: Bool, reason: String) async {
        try? await database.pool.write { db in
            guard var meeting = try Meeting.fetchOne(db, key: meetingID) else { return }
            // G10 §1: a committed `cancelled` is NEVER overwritten — the user's
            // cancel commits the status first and the terminal write must
            // preserve it (read-check in the same write transaction). Only a
            // process-class run reaches this `failed` flip anyway; this guard
            // keeps it from flipping a meeting the user just cancelled.
            guard meeting.status != .cancelled else { return }
            meeting.lastProcessingError = NotesPendingClass.marker(reason)
            if !regeneration {
                meeting.status = .failed
            }
            // No updatedAt bump: the marker is bookkeeping, not content
            // (C1 v6.7 — updatedAt tracks content mutations only; every
            // failed resume retry refreshes this marker).
            try meeting.update(db)
        }
        logger.notice(
            "notes pending for \(meetingID, privacy: .public): \(reason, privacy: .public) — transcript persisted, no handoff; self-heals on launch/key-save/network"
        )
    }

    // MARK: - Digest-only resume (G14 H1 self-heal)

    /// Self-heal trigger entry for the digest (called from the SAME triggers as
    /// `resumePendingNotes`: app launch, API-key save, network-path
    /// restoration). Re-fires `generateDigest` for every `digest-pending:`
    /// meeting WITHOUT re-running notes — a `ready` meeting's notes are final.
    /// Per-meeting failures are swallowed (the marker refreshes with the new
    /// reason and the next trigger retries). Cancelled meetings are excluded.
    public func resumePendingDigests() async {
        let pending: [MeetingID] =
            (try? await database.pool.read { db in
                try MeetingID.fetchAll(
                    db,
                    sql:
                        "SELECT id FROM meeting WHERE last_processing_error LIKE ? AND status != ? ORDER BY started_at, id",
                    arguments: [DigestPendingClass.prefix + "%", MeetingStatus.cancelled.rawValue])
            }) ?? []
        let queueRepo = ProcessingQueueRepository(database: database)
        for meetingID in pending {
            // C4 (F1 Inc2): skip a meeting with a live queued full-run job (it
            // re-mints the digest anyway) — avoids a redundant cloud call.
            if ((try? await queueRepo.liveJob(meetingID: meetingID)) ?? nil) != nil { continue }
            _ = try? await processDigestOnly(meetingID: meetingID)
        }
    }

    /// Resumes a `digest-pending:` meeting by re-firing ONLY the digest call
    /// over the stored degarbled transcript + the stored (final) notes —
    /// identical inputs to the original attempt — then persisting the digest and
    /// re-minting the payload DETERMINISTICALLY (a payload re-build, NOT a
    /// `finalizeMeetingProcessing` re-run: notes are final, status is already
    /// `ready`). Does NOT call `generateNotes`. On success the digest lands,
    /// re-materializes, and the marker clears; on failure the marker refreshes
    /// (the next trigger retries). Returns true when a digest was minted.
    ///
    /// No-op (returns false) when the meeting is no longer digest-pending (a
    /// concurrent regenerate / name-edit already handled it) — race-safe via the
    /// single-flight chain.
    @discardableResult
    public func processDigestOnly(meetingID: MeetingID) async throws -> Bool {
        try await chain.run { try await self.digestOnlyBody(meetingID: meetingID) }
    }

    private func digestOnlyBody(meetingID: MeetingID) async throws -> Bool {
        guard let meeting = try await MeetingRepository(database: database).fetch(meetingID),
            meeting.status == .ready,
            DigestPendingClass.isPending(meeting.lastProcessingError),
            var notes = try await NotesRepository(database: database).fetch(meetingID: meetingID),
            let dominantLanguage = meeting.dominantLanguage
        else { return false }

        let segments = try await TranscriptRepository(database: database)
            .segments(meetingID: meetingID)
        guard !segments.isEmpty else { return false }
        let user = await userIdentity()
        let vocabulary = vocabularyProvider().vocabulary

        let context = RunContext(meetingID: meetingID, regeneration: true)
        // The re-fire is a regeneration-class spend, not a first generation.
        context.digestPurpose = .regeneration
        // Bind a status-silent cancel token so a cancel binds at the cloud
        // attempt boundary (the meeting keeps its ready status + marker).
        let cancelToken = installCancelToken(meetingID: meetingID, statusSilent: true)
        defer { removeCancelToken(meetingID: meetingID, token: cancelToken) }
        context.cancelToken = cancelToken

        // T3.1 AC2 — RESUME PARITY: replay the FIRST run's persisted scoped set
        // (path (ii) is unreachable here — the `AppliedCorrection` records are
        // gone — so a correction-limited alias would otherwise vanish). The
        // override REPLACES derivation, making the resume scope identically.
        //
        // DEV-ONLY recall-gate seam (env-gated; OFF by default; unset in prod =
        // exact resume-replay behavior, like the BLAISE_DUMP_DIGEST_INPUT seam):
        // when BLAISE_REGATE_FRESH_ALIASES=1, pass NO override so the scoped
        // alias set is DERIVED FRESH against the CURRENT glossary instead of the
        // persisted first-run set. This makes a digest-only regate reflect what a
        // full REPROCESS (which always re-derives) would produce after a glossary
        // edit — e.g. a newly-added codename→canonical alias merging two entries.
        // It NEVER changes a shipped resume (the env is unset there).
        let aliasOverride: [AliasPair]? =
            ProcessInfo.processInfo.environment["BLAISE_REGATE_FRESH_ALIASES"] == "1"
            ? nil : notes.scopedAliasBindings
        let outcome = await generateMemoryDigest(
            meetingID: meetingID, meeting: meeting, notes: notes.structured,
            segments: segments, dominantLanguage: dominantLanguage,
            vocabulary: vocabulary, user: user, context: context,
            scopedAliasBindingsOverride: aliasOverride)

        // Cancel honored AFTER the (shielded, billed) digest/verify cloud call: a
        // cancel that landed during the call must NOT persist + enqueue a digest on
        // this resume path. Unlike the full run, digest-only has no later stage()
        // checkpoint, so without this it would mint + hand off after a cancel. The
        // status-silent token leaves the meeting `ready` + digest-pending, so it
        // self-heals/retries later. (Covers a verify-cancel too: that returns
        // `.produced(draft)`, but the token is still cancelled here.)
        if cancelToken.isCancelled { return false }

        switch outcome {
        case .produced(let clean):
            // Deterministic re-mint with the digest stored on the EXISTING notes
            // (no notes change): re-render is unnecessary (markdown unchanged);
            // re-build the payload so `memory_digest` rides it, write it, upsert
            // + enqueue in one transaction, clear the marker, kick. The replayed
            // scoped set is already on `notes` (reloaded above), so the re-mint
            // preserves it.
            notes.memoryDigest = clean
            let payload = EvidencePayloadBuilder.build(
                meeting: meeting, segments: segments, notes: notes, user: user)
            let relativePath = database.paths.relativeHandoffPayloadPath(
                meetingID: meetingID, versionHash: payload.versionHash)
            try ImmutablePayloadWriter.write(
                payload.bytes, to: database.rootURL.appendingPathComponent(relativePath))
            let rootURL = database.rootURL
            try await database.pool.write { [notes] db in
                try notes.upsert(db)
                _ = try HandoffRepository.enqueue(
                    db, rootURL: rootURL, meetingID: meetingID,
                    versionHash: payload.versionHash, payloadPath: relativePath)
            }
            await clearDigestPending(meetingID: meetingID)
            await handoffKicker.kick()
            return true
        case .failed(let reason):
            await writeDigestPending(meetingID: meetingID, reason: reason)
            return false
        case .disabled:
            // The toggle was turned OFF after the meeting went digest-pending:
            // the meeting no longer wants a digest, so clear the marker (a
            // toggle-off meeting is a clean no-digest, never a pending one).
            await clearDigestPending(meetingID: meetingID)
            return false
        }
    }

    // MARK: - Exports

    private struct TranscriptExport: Codable {
        let meetingID: MeetingID
        let dominantLanguage: String
        let asrProvenance: ASRProvenance
        let pipelineVersion: String
        let segments: [TranscriptSegment]

        enum CodingKeys: String, CodingKey {
            case segments
            case meetingID = "meeting_id"
            case dominantLanguage = "dominant_language"
            case asrProvenance = "asr_provenance"
            case pipelineVersion = "pipeline_version"
        }
    }

    private func exportTranscriptJSON(
        meetingID: MeetingID, segments: [TranscriptSegment],
        provenance: ASRProvenance, dominantLanguage: String
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let export = TranscriptExport(
            meetingID: meetingID,
            dominantLanguage: dominantLanguage,
            asrProvenance: provenance,
            pipelineVersion: PipelineVersion.current,
            segments: segments)
        try (try encoder.encode(export))
            .write(to: database.paths.transcriptURL(meetingID), options: .atomic)
    }

    // MARK: - Run bookkeeping (entry / terminal writes)

    private func writeRunEntry(meetingID: MeetingID, regeneration: Bool) async throws -> Meeting {
        let timestamp = now()
        return try await database.pool.write { db in
            guard var meeting = try Meeting.fetchOne(db, key: meetingID) else {
                throw BlaiseDatabaseError.meetingNotFound(meetingID)
            }
            // Cleared at EVERY run entry — EXCEPT the capture-recovery class
            // (C7 v3.3 / C1 v6.6): that note survives until a run completes
            // with both tracks or the user dismisses it.
            if meeting.processingNote?.hasPrefix(CaptureRecovery.notePrefix) != true {
                meeting.processingNote = nil
            }
            if !regeneration {
                meeting.status = .processing
            }
            // C10: absorb queued Meet roster names into attendees HERE — the
            // run entry is the sanctioned content-mutation point (updatedAt
            // bumps below, the payload is re-minted by this run's finalize),
            // so ingestion itself never has to touch the meeting row.
            try MeetEventsIngestor.absorbPendingRoster(db, meeting: &meeting)
            meeting.updatedAt = timestamp
            try meeting.update(db)
            return meeting
        }
    }

    /// Failure semantics: process() → `failed` + stage-tagged error, no
    /// processingNote; regenerate() → status untouched, error recorded; a
    /// post-stage-11 regeneration failure sets the stage-accurate partial
    /// note (the failure-note class wins over any fallback note).
    private func recordFailure(
        meetingID: MeetingID, regeneration: Bool, stage: PipelineStage, message: String
    ) async {
        let timestamp = now()
        let database = self.database
        // Detached: GRDB's async writes are cancellation-aware, and a
        // CANCELLED run must still record its failure (status/lastError) —
        // probed by the cancellation unit test.
        await Task.detached {
            try? await Self.writeFailure(
                database: database, meetingID: meetingID, regeneration: regeneration,
                stage: stage, message: message, timestamp: timestamp)
        }.value
    }

    private static func writeFailure(
        database: BlaiseDatabase, meetingID: MeetingID, regeneration: Bool,
        stage: PipelineStage, message: String, timestamp: Date
    ) async throws {
        try await database.pool.write { db in
            guard var meeting = try Meeting.fetchOne(db, key: meetingID) else { return }
            // G10 §1: the cancel commits `cancelled` FIRST, in its own
            // transaction; this terminal write (recordFailure, the detached
            // cancellation-surviving task) must NEVER overwrite it. Read-check
            // in the same write transaction. The D17 self-heal gate keys on the
            // preserved status correctly as a result.
            guard meeting.status != .cancelled else { return }
            meeting.lastProcessingError = "\(stage.rawValue): \(message)"
            // A capture-recovery note survives failed runs too (C7 v3.3):
            // the graver retention fact outranks the partial-regen note.
            let preserved = meeting.processingNote.flatMap {
                $0.hasPrefix(CaptureRecovery.notePrefix) ? $0 : nil
            }
            if regeneration {
                meeting.processingNote =
                    preserved
                    ?? (stage.ordinal > PipelineStage.persistTranscript.ordinal
                        ? "partial regeneration: transcript updated; \(stage.rawValue) failed"
                        : nil)
            } else {
                meeting.status = .failed
                meeting.processingNote = preserved
            }
            meeting.updatedAt = timestamp
            try meeting.update(db)
        }
    }

    /// Terminal note write (single writer per run). Reads the surviving note
    /// (entry cleared everything except a capture-recovery note):
    /// - both tracks processed → the capture-recovery note clears;
    /// - a fallback note is set only when no capture-recovery note survives
    ///   (the two classes never combine; the recovery fact wins).
    private func writeTerminalNote(
        meetingID: MeetingID, fallback: NotesFallbackRecord?, clearCaptureRecovery: Bool
    ) async {
        try? await database.pool.write { db in
            let current = try String.fetchOne(
                db, sql: "SELECT processing_note FROM meeting WHERE id = ?",
                arguments: [meetingID])
            var note = current
            if clearCaptureRecovery, note?.hasPrefix(CaptureRecovery.notePrefix) == true {
                note = nil
            }
            if let fallback, note == nil {
                note = "fallback: \(fallback.reason)"
            }
            if note != current {
                try db.execute(
                    sql: "UPDATE meeting SET processing_note = ? WHERE id = ?",
                    arguments: [note, meetingID])
            }
        }
    }

    // MARK: - Helpers

    private func userIdentity() async -> UserIdentity {
        (try? await settings.get(UserIdentity.settingsKey, as: UserIdentity.self))
            ?? .shippedDefault
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case let error as PipelineError:
            return error.message
        case let error as EngineError:
            switch error {
            case .transient(let reason): return reason
            case .permanent(let reason): return reason
            case .cancelled: return "cancelled"
            case .configurationMissing(let key): return "configuration missing: \(key)"
            case .notAvailable(let reason): return reason
            case .duplicateEngineID(let id): return "duplicate engine id: \(id)"
            case .noEnginesRegistered(let slot): return "no engines registered for slot \(slot)"
            case .invalidStructuredNotes(let reason): return "invalid structured notes: \(reason)"
            }
        case is CancellationError:
            return "cancelled"
        default:
            return "\(error)"
        }
    }
}

// F1 Inc2 (C7): the `ProcessingDispatching` conformance was removed — the
// Meet-listener post-ready re-mint now routes through the durable queue
// (`QueueProcessingDispatcher`, set on the `dispatcherBox`), so the queue is the
// SINGLE admission path for full-pipeline work. `dispatchProcessing` has exactly
// one production caller: the worker's executor closure in AppEnvironment.
