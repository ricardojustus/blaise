import Foundation
import Testing
@testable import BlaiseCore

// Regression pin (retargeted to the CC-BY ICSI Bmr001 5-minute excerpt):
// - Tier 1 (always-on, no models): committed inputs → normalizer → merge →
//   correct → languageStats in-process → BYTE-compare vs the intermediate pin.
//   Skips cleanly until the ICSI pins are minted (pinsExist() guard).
// - Tier 2 LIGHT (gated BLAISE_TEST_FULL_SAMPLE=1): an AUDIO SMOKE — import the
//   committed ICSI wav, run the full pipeline, assert structural transcript
//   invariants, PLUS the D17 notes-pending outcome (this machine is keyless:
//   the cloud primary trips configurationMissing, the only fallback is
//   heavyweight → pending, transcript persisted, no handoff).
// - Tier 2 NOTES arm (ADDITIONALLY gated BLAISE_TEST_FULL_SAMPLE_NOTES=1):
//   deliberately selects the local Gemma engine as PRIMARY (~18 GB peak —
//   quiet-machine window ONLY) and runs the notes structural comparison.
// - Regeneration ACs: transcript-side gated with Tier 2 light; the
//   summarization-switch AC (heavyweight load) gated with the NOTES arm.

@Suite struct Tier1RegressionTests {
    @Test func tier1ByteStableAgainstIntermediatePin() throws {
        guard RegressionPin.pinsExist() else {
            recordTestSkip(
                "tier1ByteStableAgainstIntermediatePin",
                reason: "ICSI regression pins not yet minted (fixtures/icsi_sample/*.json absent)")
            return
        }
        let manifest = try PinManifest.load()
        let envelope = try RawASREnvelope.load(from: RegressionPin.rawASRURL)
        let diarization = try JSONDecoder().decode(
            DiarizationOutput.self, from: Data(contentsOf: RegressionPin.diarizationURL))
        let vocabulary = try VocabFixtures.pipelineVocabulary()
        let pinnedBytes = try Data(contentsOf: RegressionPin.intermediateURL)

        // Run the chain TWICE: byte-stable across runs AND vs the pin.
        var previous: Data?
        for runIndex in 1 ... 2 {
            let (segments, dominantLanguage) = Tier1Chain.run(
                envelope: envelope,
                diarization: diarization,
                audioDuration: manifest.audio.duration,
                vocabulary: vocabulary)
            #expect(dominantLanguage == manifest.dominantLanguage)
            #expect(segments.count == manifest.intermediateSegmentCount)
            let bytes = try pinBytes(segments.map(PinnedSegment.init))
            #expect(bytes == pinnedBytes, "run \(runIndex): Tier-1 output diverged from the intermediate pin — a deterministic stage changed; fix it or bump PipelineVersion and re-mint deliberately")
            if let previous {
                #expect(bytes == previous, "Tier-1 chain not byte-stable across in-process runs")
            }
            previous = bytes
        }
    }

    @Test func pipelineVersionFormat() {
        // "<major>.<minor>" per the spec's versioning scheme.
        let parts = PipelineVersion.current.split(separator: ".")
        #expect(parts.count == 2, "PipelineVersion must be <major>.<minor>")
        #expect(parts.allSatisfy { Int($0) != nil })
    }

    /// Gated one-time mint (BLAISE_MINT_ICSI=1): provisions the Whisper venv,
    /// runs ASR + diarization ONCE over the committed ICSI excerpt, and writes
    /// the five committed regression pins so the always-on Tier-1 byte-pin test
    /// above stops skipping. HEAVY (full Whisper pass) — never runs in CI or a
    /// normal local run. BLAISE_MINT_ICSI_FORCE=1 bypasses the realStacksPresent
    /// pre-check, since the venv provisioning that satisfies it happens INSIDE
    /// mintICSIRegressionPins (the pre-check would otherwise refuse before the
    /// mint had a chance to provision).
    @Test func mintICSIPins() async throws {
        guard ProcessInfo.processInfo.environment["BLAISE_MINT_ICSI"] == "1" else { return }
        guard realStacksPresent()
            || ProcessInfo.processInfo.environment["BLAISE_MINT_ICSI_FORCE"] == "1"
        else {
            recordTestSkip("mintICSIPins", reason: "real stacks not present")
            return
        }
        try await mintICSIRegressionPins()
    }
}

// MARK: - Tier 2 (gated; audio smoke over the committed ICSI wav)

@Suite(.serialized) struct Tier2FullSampleTests {
    static var gated: Bool {
        ProcessInfo.processInfo.environment["BLAISE_TEST_FULL_SAMPLE"] == "1"
    }

    /// The committed audio's exact duration (16 kHz mono PCM, 300.0 s).
    static let audioDuration = 300.0

    @Test(.timeLimit(.minutes(45)))
    func fullSampleAgainstPin() async throws {
        guard Self.gated else { return }
        guard realStacksPresent() else {
            recordTestSkip("fullSampleAgainstPin", reason: "real engine stacks missing on this machine")
            return
        }
        let sample = VocabFixtures.fixture("icsi_sample/Bmr001_excerpt_5min.wav")
        let stack = try await makeRealPipelineStack()

        let meeting = try await stack.pipeline.importMeeting(
            sourceURL: sample,
            title: RegressionPin.sampleTitle,
            attendees: RegressionPin.fabricatedAttendees)
        let record = try await stack.pipeline.process(meetingID: meeting.id)
        let segments = try await TranscriptRepository(database: stack.database)
            .segments(meetingID: meeting.id)
        try FileManager.default.createDirectory(
            at: RegressionPin.auditsDir, withIntermediateDirectories: true)
        try pinBytes(record).write(
            to: RegressionPin.auditsDir.appendingPathComponent("tier2_last_run_record.json"))

        // --- Structural transcript invariants (no minted pin needed) ---
        let fullText = segments.map(\.text).joined(separator: " ")
        #expect(!fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "5 minutes of meeting speech must produce a non-empty transcript")
        // A 5-minute meeting: more than one turn, but not absurdly many.
        #expect(segments.count > 1, "expected more than one transcript segment, got \(segments.count)")
        #expect(segments.count < 2000, "implausibly many segments for 5 minutes: \(segments.count)")

        let epsilon = 0.5
        var previousEnd = -Double.infinity
        for (index, segment) in segments.enumerated() {
            #expect(!segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "segment \(index) has empty text")
            #expect(!segment.startSeconds.isNaN && !segment.endSeconds.isNaN,
                "segment \(index) has a NaN timestamp")
            #expect(segment.startSeconds >= 0, "segment \(index) has a negative start time")
            #expect(segment.endSeconds > segment.startSeconds,
                "segment \(index) end \(segment.endSeconds) not after start \(segment.startSeconds)")
            #expect(segment.endSeconds <= Self.audioDuration + epsilon,
                "segment \(index) end \(segment.endSeconds) exceeds audio duration \(Self.audioDuration)")
            #expect(segment.startSeconds >= previousEnd - epsilon,
                "segment \(index) start \(segment.startSeconds) is not monotonic (previous end \(previousEnd))")
            previousEnd = segment.endSeconds
        }

        // --- English-language detection + stable function-word presence ---
        let stored = try #require(
            try await MeetingRepository(database: stack.database).fetch(meeting.id))
        #expect(stored.dominantLanguage == "en",
            "the ICSI excerpt is English; detected \(stored.dominantLanguage ?? "nil")")
        let lowered = fullText.lowercased()
        let functionWords = [" the ", " and ", " to ", " of "]
        #expect(functionWords.contains { lowered.contains($0) },
            "no stable English function word found in the transcript")

        // --- D17 notes-pending outcome (the LIGHT run never loads Gemma) ---
        // The stack is keyless by construction (InMemorySecretStore): the
        // cloud primary throws configurationMissing, the only fallback is
        // heavyweight → pending. Transcript persisted (asserted above),
        // notes absent, NO handoff row (ready ⇒ queued: not ready). The
        // notes comparison lives in the BLAISE_TEST_FULL_SAMPLE_NOTES arm.
        #expect(record.notesPending != nil)
        #expect(NotesPendingClass.isPending(stored.lastProcessingError))
        #expect(stored.status == .failed)
        let notes = try await NotesRepository(database: stack.database)
            .fetch(meetingID: meeting.id)
        #expect(notes == nil)
        let queueRows = try await stack.database.pool.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM handoff_queue WHERE meeting_id = ?",
                arguments: [meeting.id]) ?? 0
        }
        #expect(queueRows == 0, "a notes-pending meeting must not enqueue a handoff")
        print("[tier2] audio smoke: \(segments.count) segments, lang=\(stored.dominantLanguage ?? "-"); notes pending (\(record.notesPending ?? "-")), no handoff row — Gemma arm gated behind BLAISE_TEST_FULL_SAMPLE_NOTES=1")
    }
}

// MARK: - Tier 2 notes arm (ADDITIONAL gate; heavyweight local engine)

/// Deliberately selects the local Gemma engine as PRIMARY — the D17 path
/// that still runs heavyweight weights. ~18 GB peak: run ONLY in a
/// quiet-machine window (no Chrome/Meet), never during the workday.
@Suite(.serialized) struct Tier2FullSampleNotesTests {
    static var gated: Bool {
        ProcessInfo.processInfo.environment["BLAISE_TEST_FULL_SAMPLE_NOTES"] == "1"
    }

    @Test(.timeLimit(.minutes(45)))
    func fullSampleNotesWithLocalEnginePrimary() async throws {
        guard Self.gated else { return }
        guard realStacksPresent() else {
            recordTestSkip(
                "fullSampleNotesWithLocalEnginePrimary",
                reason: "real engine stacks missing on this machine")
            return
        }
        // The explicit "Sam Rivera" identity is written by makeRealPipelineStack
        // so the renderer emits the named user-action heading the structural
        // check expects.
        let identity = UserIdentity(name: "Sam Rivera", aliases: ["Sam"], email: "sam.rivera@vexatron.test")
        let stack = try await makeRealPipelineStack()
        // Deliberate primary selection — NOT a fallback hop (D17).
        try await stack.settings.set(
            EngineResolver.summarizationSettingsKey, to: MLXSummarizationEngine.engineID)
        let meeting = try await stack.pipeline.importMeeting(
            sourceURL: VocabFixtures.fixture("icsi_sample/Bmr001_excerpt_5min.wav"),
            title: RegressionPin.sampleTitle,
            attendees: RegressionPin.fabricatedAttendees)
        let record: PipelineRunRecord
        do {
            record = try await stack.pipeline.process(meetingID: meeting.id)
        } catch let error as PipelineError
        where error.message.contains(EngineFallbackReason.insufficientMemory) {
            // The engine's memory gate refused the 18 GB load (and the
            // lightweight hop is keyless here) — honest skip, not a failure.
            recordTestSkip(
                "fullSampleNotesWithLocalEnginePrimary",
                reason: "memory gate refused the 18 GB load — re-run in a quieter window")
            return
        }
        let segments = try await TranscriptRepository(database: stack.database)
            .segments(meetingID: meeting.id)
        let notes = try #require(
            try await NotesRepository(database: stack.database).fetch(meetingID: meeting.id))
        #expect(notes.provenance.engine == MLXSummarizationEngine.engineID)
        // Comparison keyed to the shipped prompt version: the local engine
        // shares NotesPromptBuilder, so a prompt bump changes what Gemma is
        // asked to write — the structural check itself is prompt-version-
        // agnostic (renderer headings, language, owner grounding), but a run
        // must say WHICH prompt produced what it checked.
        #expect(notes.provenance.promptVersion == NotesPromptBuilder.promptVersion)
        #expect(record.fallback == nil, "directly selected engine must not be labeled a fallback")
        let findings = NotesStructuralCheck.findings(
            notes: notes,
            dominantLanguage: try #require(record.dominantLanguage),
            attendees: meeting.attendees,
            segments: segments,
            user: identity)
        #expect(findings.isEmpty, "notes structural findings: \(findings)")
        let stored = try #require(
            try await MeetingRepository(database: stack.database).fetch(meeting.id))
        #expect(stored.status == .ready)
        let queueRows = try await stack.database.pool.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM handoff_queue WHERE meeting_id = ?",
                arguments: [meeting.id]) ?? 0
        }
        #expect(queueRows == 1)
    }
}

// MARK: - Regeneration ACs (real engines on the ICSI excerpt)

/// Transcript-side regeneration ACs run with Tier 2 LIGHT: the keyless
/// stack resolves the notes stage to PENDING (D17 — no Gemma load), so they
/// assert transcript restoration + the pending outcome. The notes-producing
/// regeneration AC (heavyweight load) lives in the NOTES-gated suite below.
@Suite(.serialized) struct RegenerationAcceptanceTests {
    static var gated: Bool {
        ProcessInfo.processInfo.environment["BLAISE_TEST_FULL_SAMPLE"] == "1"
    }

    private func processedSample() async throws -> (RealPipelineStack, Meeting)? {
        guard realStacksPresent() else {
            recordTestSkip("regenerationAcceptance", reason: "real engine stacks missing")
            return nil
        }
        let stack = try await makeRealPipelineStack()
        let meeting = try await stack.pipeline.importMeeting(
            sourceURL: VocabFixtures.fixture("icsi_sample/Bmr001_excerpt_5min.wav"),
            title: "Regeneration AC (ICSI excerpt)",
            attendees: RegressionPin.fabricatedAttendees)
        _ = try await stack.pipeline.process(meetingID: meeting.id)
        return (stack, meeting)
    }

    @Test(.timeLimit(.minutes(30)))
    func deleteThenRegenerateRestoresArtifactsFromRetainedAudio() async throws {
        guard Self.gated else { return }
        guard let (stack, meeting) = try await processedSample() else { return }
        let transcripts = TranscriptRepository(database: stack.database)
        let paths = stack.database.paths

        try await transcripts.deleteTranscript(meetingID: meeting.id)
        try FileManager.default.removeItem(at: paths.transcriptURL(meeting.id))
        // Only the retained audio remains as the recoverable source.
        #expect(!FileManager.default.fileExists(atPath: paths.importCopyURL(meeting.id).path))

        let record = try await stack.pipeline.regenerate(meetingID: meeting.id)
        let segments = try await transcripts.segments(meetingID: meeting.id)
        // Substance, not turn count: merged-turn count is diarization-driven —
        // the AC is "valid artifacts from retained audio", so assert real content.
        #expect(!segments.isEmpty)
        let regeneratedWords = segments.map(\.text).joined(separator: " ")
            .split(separator: " ").count
        #expect(regeneratedWords >= 300, "5 minutes of meeting speech must regenerate substantial text, got \(regeneratedWords) words")
        #expect(FileManager.default.fileExists(atPath: paths.transcriptURL(meeting.id).path))
        let stored = try #require(
            try await MeetingRepository(database: stack.database).fetch(meeting.id))
        #expect(stored.asrProvenance?.engine == MLXWhisperEngine.engineID)
        // D17 keyless outcome: notes pending (regenerate keeps the pending
        // run's `failed` status), no notes, no handoff row.
        #expect(record.notesPending != nil)
        #expect(NotesPendingClass.isPending(stored.lastProcessingError))
        print("[regen-ac] from-retained-audio: \(segments.count) segments; notesPending=\(record.notesPending ?? "-")")
    }

    @Test(.timeLimit(.minutes(30)))
    func engineSwitchRegenerationReflectsASRProvenance() async throws {
        guard Self.gated else { return }
        guard let (stack, meeting) = try await processedSample() else { return }

        // ASR slot: switch to Parakeet, regenerate. (The summarization-slot
        // switch is the NOTES-gated AC — it loads the heavyweight engine.)
        try await stack.settings.set(
            EngineResolver.asrSettingsKey, to: FluidAudioParakeetEngine.engineID)
        _ = try await stack.pipeline.regenerate(meetingID: meeting.id)
        let afterASRSwitch = try #require(
            try await MeetingRepository(database: stack.database).fetch(meeting.id))
        #expect(afterASRSwitch.asrProvenance?.engine == FluidAudioParakeetEngine.engineID)
        #expect(afterASRSwitch.asrProvenance?.model == "parakeet-tdt-0.6b-v3")
        print("[regen-ac] engine-switch: asr=\(afterASRSwitch.asrProvenance?.engine ?? "-")")
    }
}

/// NOTES-gated regeneration AC (heavyweight load — quiet-machine window):
/// switching the summarization slot to the local engine regenerates with
/// engine-honest provenance and no fallback label.
@Suite(.serialized) struct RegenerationNotesAcceptanceTests {
    static var gated: Bool {
        ProcessInfo.processInfo.environment["BLAISE_TEST_FULL_SAMPLE_NOTES"] == "1"
    }

    @Test(.timeLimit(.minutes(30)))
    func engineSwitchRegenerationReflectsSummarizationProvenance() async throws {
        guard Self.gated else { return }
        guard realStacksPresent() else {
            recordTestSkip(
                "engineSwitchRegenerationReflectsSummarizationProvenance",
                reason: "real engine stacks missing")
            return
        }
        let stack = try await makeRealPipelineStack()
        let meeting = try await stack.pipeline.importMeeting(
            sourceURL: VocabFixtures.fixture("icsi_sample/Bmr001_excerpt_5min.wav"),
            title: "Regeneration AC (ICSI excerpt)",
            attendees: RegressionPin.fabricatedAttendees)
        _ = try await stack.pipeline.process(meetingID: meeting.id)

        // Summarization slot: the non-default engine. The shipped default is
        // cloud (claude-sonnet, keyless here); switching to the local Gemma
        // selects it DIRECTLY (no fallback note, engine-honest provenance).
        try await stack.settings.set(
            EngineResolver.summarizationSettingsKey, to: MLXSummarizationEngine.engineID)
        let record: PipelineRunRecord
        do {
            record = try await stack.pipeline.regenerate(meetingID: meeting.id)
        } catch let error as PipelineError
        where error.message.contains(EngineFallbackReason.insufficientMemory) {
            recordTestSkip(
                "engineSwitchRegenerationReflectsSummarizationProvenance",
                reason: "memory gate refused the 18 GB load — re-run in a quieter window")
            return
        }
        let notes = try #require(
            try await NotesRepository(database: stack.database).fetch(meetingID: meeting.id))
        #expect(notes.provenance.engine == MLXSummarizationEngine.engineID)
        #expect(record.fallback == nil, "directly selected engine must not be labeled a fallback")
        let stored = try #require(
            try await MeetingRepository(database: stack.database).fetch(meeting.id))
        #expect(stored.processingNote == nil)
        print("[regen-ac] engine-switch: notes=\(notes.provenance.engine)")
    }
}
