import Foundation
import GRDB
import Synchronization
import Testing
@testable import BlaiseCore

// C7 AC1: stage sequencing + failure tagging with mock engines; ingest
// guards; processingNote contract; regenerate semantics; classifier;
// transcode round-trip; import seam.

@Suite struct DominantLanguageTests {
    @Test func portugueseMajorityWins() {
        let text = "Então a gente vai fazer isso amanhã, não tem muito tempo mas está bem."
        #expect(DominantLanguage.classify(text: text) == "pt")
    }

    @Test func englishMajorityWins() {
        let text = "We should just think about what they want and ship the build this week."
        #expect(DominantLanguage.classify(text: text) == "en")
    }

    @Test func codeSwitchedMajorityDecides() {
        // PT frame with quoted EN terms — majority PT.
        let text = "Não, o que a gente quer é o creative trust, mas isso está no roadmap e já foi para o time."
        #expect(DominantLanguage.classify(text: text) == "pt")
    }

    @Test func tieAndEmptyDefaultToPT() {
        #expect(DominantLanguage.classify(text: "") == "pt")
        #expect(DominantLanguage.classify(text: "xyzzy plugh 1234") == "pt")
        // One hit each → tie → pt.
        #expect(DominantLanguage.classify(text: "que the") == "pt")
    }

    @Test func segmentsOverloadJoinsText() {
        let segments = [
            TranscriptSegment(meetingID: "m", ord: 0, startSeconds: 0, endSeconds: 1, text: "the and that with this"),
            TranscriptSegment(meetingID: "m", ord: 1, startSeconds: 1, endSeconds: 2, text: "have what you for but"),
        ]
        #expect(DominantLanguage.classify(segments: segments) == "en")
    }

    @Test func ambiguousFormsExcludedFromBothSets() {
        for word in ["a", "as", "no", "do"] {
            #expect(!DominantLanguage.portugueseWords.contains(word), "\(word) must not vote PT")
            #expect(!DominantLanguage.englishWords.contains(word), "\(word) must not vote EN")
        }
    }
}

@Suite struct AudioTranscoderTests {
    @Test func encodeDecodeRoundTrip() throws {
        let root = try makeTempRoot()
        let wav = root.appendingPathComponent("in.wav")
        try writeTestWAV(to: wav, seconds: 2.0)
        let m4a = root.appendingPathComponent("audio.m4a")
        try AudioTranscoder.encodeToM4A(wav: wav, destination: m4a)
        #expect(FileManager.default.fileExists(atPath: m4a.path))
        // Verification surface: opens, duration within 0.5 s.
        let duration = try AudioTranscoder.duration(of: m4a)
        #expect(abs(duration - 2.0) < 0.5)

        let outWAV = root.appendingPathComponent("decoded.wav")
        try AudioTranscoder.decodeTo16kWAV(m4a: m4a, destination: outWAV)
        let info = try WAVHeader.read(at: outWAV)
        #expect(info.sampleRate == 16_000)
        #expect(info.channels == 1)
        #expect(info.bitsPerSample == 16)
        #expect(abs(info.duration - 2.0) < 0.1)
    }

    @Test func encodeNeverOverwrites() throws {
        let root = try makeTempRoot()
        let wav = root.appendingPathComponent("in.wav")
        try writeTestWAV(to: wav, seconds: 1.0)
        let m4a = root.appendingPathComponent("audio.m4a")
        try AudioTranscoder.encodeToM4A(wav: wav, destination: m4a)
        #expect(throws: AudioTranscoderError.self) {
            try AudioTranscoder.encodeToM4A(wav: wav, destination: m4a)
        }
    }

    @Test func injectedMidEncodeFailureLeavesNoM4A() throws {
        let root = try makeTempRoot()
        let wav = root.appendingPathComponent("in.wav")
        try writeTestWAV(to: wav, seconds: 1.0)
        let m4a = root.appendingPathComponent("audio.m4a")
        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try AudioTranscoder.encodeToM4A(wav: wav, destination: m4a) { _ in throw Boom() }
        }
        #expect(!FileManager.default.fileExists(atPath: m4a.path), "atomicity violated: audio.m4a exists after injected mid-encode failure")
        // Temp file is cleaned on the failure path too.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.contains(".tmp-") }
        #expect(leftovers.isEmpty, "temp leftovers: \(leftovers)")
    }
}

@Suite struct PipelineImportTests {
    @Test func importCreatesRowDirAndLosslessCopy() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        #expect(meeting.source == .imported)
        #expect(meeting.status == .processing)
        #expect(meeting.attendees.count == 1)
        let ended = try #require(meeting.endedAt)
        #expect(abs(ended.timeIntervalSince(meeting.startedAt) - 2.0) < 0.01)
        let paths = harness.database.paths
        #expect(FileManager.default.fileExists(atPath: paths.importCopyURL(meeting.id).path))
        #expect(!FileManager.default.fileExists(atPath: paths.audioURL(meeting.id).path))
        let stored = try await harness.meeting(meeting.id)
        #expect(stored?.title == "Reunião de teste")
    }

    @Test func importRejectsNonWAV() async throws {
        let harness = try await makePipelineHarness()
        let bogus = harness.dataRoot.appendingPathComponent("bogus.wav")
        try Data("not a wav".utf8).write(to: bogus)
        await #expect(throws: WAVHeader.ReadError.self) {
            try await harness.pipeline.importMeeting(sourceURL: bogus, title: "x")
        }
    }
}

@Suite struct PipelineHappyPathTests {
    @Test func processRunsAllStagesInOrderAndFinalizes() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        let events = await harness.pipeline.events()

        let record = try await harness.pipeline.process(meetingID: meeting.id)

        // Stage order is load-bearing (persist-once-after-naming).
        var seen: [PipelineEvent] = []
        for await event in events {
            seen.append(event)
            if case .runCompleted = event { break }
        }
        let beganStages: [PipelineStage] = seen.compactMap {
            if case .stageBegan(_, let stage) = $0 { return stage }
            return nil
        }
        #expect(beganStages == PipelineStage.allCases)
        let finishedStages: [PipelineStage] = seen.compactMap {
            if case .stageFinished(_, let stage) = $0 { return stage }
            return nil
        }
        #expect(finishedStages == PipelineStage.allCases)

        // Status + queue invariant.
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.status == .ready)
        #expect(stored.lastProcessingError == nil)
        #expect(stored.processingNote == nil)
        #expect(stored.dominantLanguage == "pt")
        #expect(stored.asrProvenance?.engine == "pipeline-mock-asr")
        #expect(try await harness.queueRows(meeting.id) == 1)

        // Segments persisted (split across the two diarized speakers).
        let segments = try await harness.segments(meeting.id)
        #expect(!segments.isEmpty)
        #expect(Set(segments.map(\.speakerLabel)).isSuperset(of: ["S0", "S1"]))

        // File artifacts.
        let paths = harness.database.paths
        for url in [
            paths.audioURL(meeting.id), paths.rawASRURL(meeting.id),
            paths.transcriptURL(meeting.id), paths.notesURL(meeting.id),
        ] {
            #expect(FileManager.default.fileExists(atPath: url.path), "missing \(url.lastPathComponent)")
        }
        // Import copy deleted only after the verified encode — by now, gone.
        #expect(!FileManager.default.fileExists(atPath: paths.importCopyURL(meeting.id).path))

        // raw_asr.json is the {provenance, payload} envelope with the
        // engine-native payload verbatim.
        let envelopeData = try Data(contentsOf: paths.rawASRURL(meeting.id))
        let envelope = try JSONSerialization.jsonObject(with: envelopeData) as? [String: Any]
        #expect(envelope?["provenance"] != nil)
        #expect((envelope?["payload"] as? [String: Any])?["mock"] as? Bool == true)

        // Payload on disk matches the recorded hash and embeds native_id.
        let payloadPath = try #require(record.versionHash)
        let payloadURL = harness.database.rootURL.appendingPathComponent(
            try #require(record.payloadPath))
        let payloadBytes = try Data(contentsOf: payloadURL)
        #expect(MeetingPaths.isValidVersionHash(payloadPath))
        let parsed = try JSONSerialization.jsonObject(with: payloadBytes) as? [String: Any]
        #expect(parsed?["native_id"] as? String == meeting.id)
        #expect(parsed?["source"] as? String == "blaise")

        // Temp WAV deleted on the success path.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: harness.tempDir.path)
        #expect(leftovers.isEmpty, "temp artifacts leaked: \(leftovers)")

        // Run record sanity.
        #expect(record.dominantLanguage == "pt")
        #expect(record.asrSegmentCount == 2)
        #expect(record.speakerCount == 2)
        #expect(record.fallback == nil)
    }

    @Test func processSetsProcessingStatusAtEntry() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        // Park the meeting in failed first, so the entry write is observable.
        try await harness.database.pool.write { db in
            try db.execute(
                sql: "UPDATE meeting SET status = 'failed', processing_note = 'stale note' WHERE id = ?",
                arguments: [meeting.id])
        }
        let database = harness.database
        let meetingID = meeting.id
        let observed = Mutex<(status: String?, note: String?)>((nil, "unset"))
        harness.asr.state.withLock { state in
            state.onTranscribe = {
                let snapshot: (String?, String?)? = try? await database.pool.read { db in
                    let row = try Row.fetchOne(
                        db, sql: "SELECT status, processing_note FROM meeting WHERE id = ?",
                        arguments: [meetingID])
                    return row.map { ($0["status"], $0["processing_note"]) }
                }
                observed.withLock { $0 = (snapshot?.0, snapshot?.1) }
            }
        }
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        let seen = observed.withLock { $0 }
        #expect(seen.status == "processing", "process() must set status=processing at entry")
        #expect(seen.note == nil, "processingNote must be cleared at every run entry")
    }

    @Test func secondRunNeverReencodesRetainedAudio() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        let audioURL = harness.database.paths.audioURL(meeting.id)
        let before = try FileIdentity(of: audioURL)
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        let after = try FileIdentity(of: audioURL)
        #expect(before == after, "audio.m4a was touched by a re-run (if-absent guard violated)")
    }

    @Test func llmNameProposalsApplyWithLowDropped() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        harness.notesPrimary.state.withLock { state in
            state.mapping = [
                // Transcript-verbatim name ("Fábio" occurs in segment text).
                SpeakerNameProposal(label: "S1", name: "Fábio", confidence: .high, evidence: "O Fábio vai mandar o contrato."),
                // low → dropped before apply().
                SpeakerNameProposal(label: "S0", name: "Fábio", confidence: .low, evidence: "guess"),
                // Not verbatim, not attendee → apply() must reject.
                SpeakerNameProposal(label: "S0", name: "Beltrano Qualquer", confidence: .high, evidence: "invented"),
            ]
        }
        let record = try await harness.pipeline.process(meetingID: meeting.id)
        let segments = try await harness.segments(meeting.id)
        let named = segments.filter { $0.speakerName != nil }
        #expect(named.allSatisfy { $0.speakerLabel == "S1" && $0.speakerName == "Fábio" })
        #expect(!named.isEmpty, "high-confidence verbatim proposal must persist")
        #expect(record.appliedNames == ["S1": "Fábio"])
        #expect(segments.filter { $0.speakerLabel == "S0" }.allSatisfy { $0.speakerName == nil })
    }

    @Test func attendeeListNameIsAllowed() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting(attendees: [
            Attendee(name: "Sam", email: "sam.rivera@vexatron.test", source: .manual),
            Attendee(name: "Mariana Costa", email: nil, source: .manual),
        ])
        harness.notesPrimary.state.withLock { state in
            state.mapping = [
                SpeakerNameProposal(label: "S0", name: "Mariana Costa", confidence: .medium, evidence: "attendee"),
            ]
        }
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        let segments = try await harness.segments(meeting.id)
        #expect(segments.contains { $0.speakerLabel == "S0" && $0.speakerName == "Mariana Costa" })
    }

    @Test func correctionsAreAppliedAndLogged() async throws {
        let harness = try await makePipelineHarness()
        harness.asr.state.withLock { state in
            state.segments = [
                ASRSegment(
                    startSeconds: 0, endSeconds: 1.5, text: "Eu concordo com o Tobes sobre a zandi.",
                    words: nil)
            ]
        }
        let meeting = try await harness.importTestMeeting()
        let record = try await harness.pipeline.process(meetingID: meeting.id)
        let segments = try await harness.segments(meeting.id)
        let text = segments.map(\.text).joined(separator: " ")
        #expect(text.contains("Toban"), "alias Tobes→Toban Vane must fire: \(text)")
        #expect(text.contains("Luca Zander"), "alias zandi→Luca Zander must fire: \(text)")
        #expect(record.correctionCount == 2)
    }

    // M-2 (round-1): the run's user-glossary load rides the pipeline-activity
    // observable (§5b) — Settings/logs can see what a RUN actually loaded, not
    // just the editor's on-demand "Check now".
    @Test func glossaryLoadRidesPipelineActivityObservable() async throws {
        var diagnostics = GlossaryDiagnostics()
        diagnostics.effectiveEntries = 3
        diagnostics.aliasesAdmitted = 1
        diagnostics.add(GlossaryDiagnosticItem(
            line: 5, prefix: "lance", reason: .aliasRejectedUnsafe(reason: "everyday word")))
        let fixedDate = msDate()
        let load = PipelineVocabulary.UserLoad(
            vocabulary: try VocabFixtures.pipelineVocabulary(),
            diagnostics: diagnostics, loadedAt: fixedDate)
        let harness = try await makePipelineHarness(vocabularyProvider: { load })
        let meeting = try await harness.importTestMeeting()
        let events = await harness.pipeline.events()

        _ = try await harness.pipeline.process(meetingID: meeting.id)

        var observed: GlossaryDiagnostics?
        var observedAt: Date?
        for await event in events {
            if case .glossaryLoaded(_, let d, let at) = event {
                observed = d
                observedAt = at
            }
            if case .runCompleted = event { break }
        }
        #expect(observed?.effectiveEntries == 3)
        #expect(observed?.aliasesAdmitted == 1)
        #expect(observed?.items.contains { if case .aliasRejectedUnsafe = $0.reason { return true }; return false } == true)
        #expect(observedAt == fixedDate)
    }
}

@Suite struct PipelineFailurePathTests {
    private func expectFailure(
        _ harness: PipelineHarness, _ meetingID: MeetingID,
        stage: PipelineStage, messageContains: String? = nil,
        regeneration: Bool = false
    ) async throws -> PipelineError {
        let thrown: PipelineError
        do {
            if regeneration {
                _ = try await harness.pipeline.regenerate(meetingID: meetingID)
            } else {
                _ = try await harness.pipeline.process(meetingID: meetingID)
            }
            Issue.record("run unexpectedly succeeded")
            throw TestFailure()
        } catch let error as PipelineError {
            thrown = error
        }
        #expect(thrown.stage == stage, "failed at \(thrown.stage), expected \(stage): \(thrown.message)")
        if let messageContains {
            #expect(thrown.message.contains(messageContains), "\(thrown.message)")
        }
        let meeting = try #require(try await harness.meeting(meetingID))
        #expect(meeting.lastProcessingError == "\(thrown.stage.rawValue): \(thrown.message)")
        return thrown
    }

    @Test func ingestFailsNamedWhenSourceMissing() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        // Simulate the post-crash state: import copy gone, no verified m4a.
        try FileManager.default.removeItem(
            at: harness.database.paths.importCopyURL(meeting.id))
        _ = try await expectFailure(
            harness, meeting.id, stage: .ingest, messageContains: "source audio required")
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.status == .failed)
        #expect(stored.processingNote == nil)
    }

    @Test func ingestRecoversViaSourceWAVParameter() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        try FileManager.default.removeItem(
            at: harness.database.paths.importCopyURL(meeting.id))
        let replacement = harness.dataRoot.appendingPathComponent("replacement.wav")
        try writeTestWAV(to: replacement)
        let record = try await harness.pipeline.process(meetingID: meeting.id, sourceWAV: replacement)
        #expect(record.versionHash != nil)
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.status == .ready)
    }

    @Test func transcodeFailureIsStageTagged() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        // Plant a corrupt m4a (encode skipped by if-absent; transcode fails).
        // The import copy must be gone too, or ingest's verification decode
        // catches the corruption first (also correct, but not this test).
        try Data("garbage".utf8).write(
            to: harness.database.paths.audioURL(meeting.id))
        try FileManager.default.removeItem(
            at: harness.database.paths.importCopyURL(meeting.id))
        _ = try await expectFailure(harness, meeting.id, stage: .transcode)
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.status == .failed)
    }

    @Test func asrUnavailableFailsWithEngineReason() async throws {
        let harness = try await makePipelineHarness()
        harness.asr.state.withLock { $0.availability = .unavailable(reason: "not yet provisioned") }
        let meeting = try await harness.importTestMeeting()
        _ = try await expectFailure(
            harness, meeting.id, stage: .asr, messageContains: "not yet provisioned")
    }

    @Test func asrTranscribeFailureIsStageTagged() async throws {
        let harness = try await makePipelineHarness()
        harness.asr.state.withLock { $0.transcribeError = .transient("driver exit 4") }
        let meeting = try await harness.importTestMeeting()
        _ = try await expectFailure(
            harness, meeting.id, stage: .asr, messageContains: "driver exit 4")
        // No raw_asr.json written for a failed transcription.
        #expect(
            !FileManager.default.fileExists(
                atPath: harness.database.paths.rawASRURL(meeting.id).path))
    }

    @Test func diarizeFailureIsStageTagged() async throws {
        let harness = try await makePipelineHarness()
        harness.diarizer.state.withLock { $0.error = .transient("diarization failed") }
        let meeting = try await harness.importTestMeeting()
        _ = try await expectFailure(harness, meeting.id, stage: .diarize)
    }

    @Test func notesFallbackTriggerHopsOnceAndRecordsNote() async throws {
        let harness = try await makePipelineHarness()
        harness.notesPrimary.state.withLock {
            $0.error = .permanent(EngineFallbackReason.inputTooLong)
        }
        let meeting = try await harness.importTestMeeting()
        let record = try await harness.pipeline.process(meetingID: meeting.id)
        let fallback = try #require(record.fallback)
        #expect(fallback.primaryEngineID == "pipeline-mock-notes-primary")
        #expect(fallback.fallbackEngineID == "pipeline-mock-notes-fallback")
        // The fallback hop runs prepare() on the fallback engine FIRST.
        #expect(harness.notesFallback.state.withLock { $0.prepareCalls } == 1)
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.status == .ready)
        #expect(stored.processingNote == "fallback: \(EngineFallbackReason.inputTooLong)")
        // Provenance names the engine that actually ran.
        let notes = try #require(
            try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id))
        #expect(notes.provenance.engine == "pipeline-mock-notes-fallback")
    }

    @Test func configurationMissingIsTheFourthFallbackTrigger() async throws {
        // The exact no-key cloud-default path the full-sample run takes.
        let harness = try await makePipelineHarness()
        harness.notesPrimary.state.withLock {
            $0.error = .configurationMissing(key: "engine.claude-sonnet.apiKey")
        }
        let meeting = try await harness.importTestMeeting()
        let record = try await harness.pipeline.process(meetingID: meeting.id)
        #expect(record.fallback?.fallbackEngineID == "pipeline-mock-notes-fallback")
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.status == .ready)
        #expect(stored.processingNote?.starts(with: "fallback: configuration missing") == true)
    }

    @Test func monthlyCeilingAndOOMAreTriggers() async throws {
        for trigger in [
            EngineError.notAvailable(reason: EngineFallbackReason.monthlyCeiling),
            EngineError.permanent(EngineFallbackReason.outOfMemory),
        ] {
            let harness = try await makePipelineHarness()
            harness.notesPrimary.state.withLock { $0.error = trigger }
            let meeting = try await harness.importTestMeeting()
            let record = try await harness.pipeline.process(meetingID: meeting.id)
            #expect(record.fallback != nil, "expected fallback for \(trigger)")
        }
    }

    @Test func nonTriggerNotesErrorFailsWithoutFallback() async throws {
        let harness = try await makePipelineHarness()
        harness.notesPrimary.state.withLock { $0.error = .transient("api 529") }
        let meeting = try await harness.importTestMeeting()
        _ = try await expectFailure(
            harness, meeting.id, stage: .notes, messageContains: "api 529")
        #expect(harness.notesFallback.state.withLock { $0.requests.isEmpty })
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.status == .failed)
        #expect(stored.processingNote == nil)
    }

    @Test func bothEnginesFailingRecordsBothReasons() async throws {
        let harness = try await makePipelineHarness()
        harness.notesPrimary.state.withLock {
            $0.error = .permanent(EngineFallbackReason.inputTooLong)
        }
        harness.notesFallback.state.withLock { $0.error = .transient("load failure") }
        let meeting = try await harness.importTestMeeting()
        let error = try await expectFailure(harness, meeting.id, stage: .notes)
        #expect(error.message.contains(EngineFallbackReason.inputTooLong))
        #expect(error.message.contains("load failure"))
        #expect(error.message.contains("pipeline-mock-notes-primary"))
        #expect(error.message.contains("pipeline-mock-notes-fallback"))
    }

    @Test func triggerWithNoSecondEngineFailsHonestly() async throws {
        let harness = try await makePipelineHarness(registerFallbackEngine: false)
        harness.notesPrimary.state.withLock {
            $0.error = .permanent(EngineFallbackReason.inputTooLong)
        }
        let meeting = try await harness.importTestMeeting()
        let error = try await expectFailure(harness, meeting.id, stage: .notes)
        #expect(error.message.contains("no fallback engine"))
    }

    @Test func rendererRefusalFailsPersistNotes() async throws {
        let harness = try await makePipelineHarness()
        harness.notesPrimary.state.withLock { $0.summary = "   " }
        let meeting = try await harness.importTestMeeting()
        _ = try await expectFailure(
            harness, meeting.id, stage: .persistNotes, messageContains: "summary")
        // Hard-floor reading of `failed`: artifacts that DO exist stay valid —
        // the transcript was persisted at stage 11 before the failure.
        #expect(!(try await harness.segments(meeting.id)).isEmpty)
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.status == .failed)
        #expect(stored.processingNote == nil, "process() failure never writes a processingNote")
    }

    /// G10 §1 (spec-sanctioned UPDATE of the old `cancellationFailsWithCancelledTag`):
    /// a first-processing cancel via the explicit token commits `cancelled`
    /// FIRST, and the run's terminal write (recordFailure) PRESERVES it — no
    /// flip to `failed`. The earlier contract (cancel ⇒ failed) is replaced by
    /// the durable `cancelled` status.
    @Test func cancelCommitsCancelledAndTerminalWritePreservesIt() async throws {
        let harness = try await makePipelineHarness()
        // Block the run on a stage so the token lands mid-run, then the run's
        // catch path calls recordFailure — which must NOT overwrite cancelled.
        harness.asr.state.withLock { $0.transcribeDelaySeconds = 5 }
        let meeting = try await harness.importTestMeeting()
        let pipeline = harness.pipeline
        let task = Task { try await pipeline.process(meetingID: meeting.id) }
        // Wait until the run is in flight (a token is installed).
        #expect(await waitUntil { await pipeline.hasRunInFlight(meeting.id) })
        let signalled = await pipeline.cancel(meetingID: meeting.id)
        #expect(signalled, "cancel of an in-flight run must signal")
        // Status committed to `cancelled` synchronously at cancel time.
        let afterCancel = try #require(try await harness.meeting(meeting.id))
        #expect(afterCancel.status == .cancelled)
        do {
            _ = try await task.value
            Issue.record("cancelled run unexpectedly succeeded")
        } catch let error as PipelineError {
            #expect(error.message == "cancelled")
        } catch let error as EngineError {
            #expect(error == .cancelled)
        }
        // The terminal write (recordFailure) PRESERVED cancelled — no flip.
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.status == .cancelled, "recordFailure must never overwrite cancelled")
        // Temp WAV deleted on the cancellation exit path too.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: harness.tempDir.path)
        #expect(leftovers.isEmpty)
    }

    /// G10 §1: cancel with NO run in flight is a no-op (idleness-keyed on the
    /// token, not status). A `ready` meeting's cancel signals nothing and
    /// leaves it `ready`.
    @Test func cancelWithNoRunInFlightIsNoOp() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        let signalled = await harness.pipeline.cancel(meetingID: meeting.id)
        #expect(!signalled, "cancel of an idle meeting must be a no-op")
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.status == .ready)
    }

    /// G10 §1: after a process-class cancel, NO auto-kick caller re-runs the
    /// meeting (the refusal set). The listener seam, the launch sweep kick,
    /// and the meeting-code sweep all pass `refuseCancelled: true`.
    @Test func cancelledMeetingRefusesAutoDispatchButProcessReRuns() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        // Drive it to `cancelled` directly (the post-cancel durable state).
        try await harness.database.pool.write { db in
            try db.execute(
                sql: "UPDATE meeting SET status = 'cancelled' WHERE id = ?", arguments: [meeting.id])
        }
        // Auto-kick (listener seam / sweep): refused. (F1 Inc2 removed the
        // ProcessingDispatching conformance; the auto path is dispatchProcessing
        // with refuseCancelled=true, which the queue executor reproduces via origin.)
        _ = try? await harness.pipeline.dispatchProcessing(
            meetingID: meeting.id, refuseCancelled: true)
        let afterAuto = try #require(try await harness.meeting(meeting.id))
        #expect(afterAuto.status == .cancelled, "auto-kick must refuse a cancelled meeting")
        // Explicit refuse via the parameter throws the right error.
        await #expect(throws: PipelineDispatchError.self) {
            try await harness.pipeline.dispatchProcessing(
                meetingID: meeting.id, refuseCancelled: true)
        }
        // The user's Process (refuseCancelled false) re-runs the FULL pipeline.
        _ = try await harness.pipeline.dispatchProcessing(meetingID: meeting.id)
        let afterProcess = try #require(try await harness.meeting(meeting.id))
        #expect(afterProcess.status == .ready, "the user's Process re-runs and completes")
    }

    /// G10 §1 / AC1 (M-1): the token-before-status ORDER pin, made
    /// DISCRIMINATING. The mutant M7 (cancel() writes `cancelled` BEFORE setting
    /// the token) must FAIL this test. The run parks inside the primary engine's
    /// prepare(), just before the pipeline's cancel-token boundary check
    /// (`if cancelToken.isCancelled throw`). The test cancels; the cancel's
    /// status write — its own awaited step AFTER `token.cancel()` in the correct
    /// order — is the seam where we release the parked prepare (via the injected
    /// `now`). On release the run hits the boundary check:
    ///   • correct order: token ALREADY cancelled → boundary throws → the
    ///     primary engine is NEVER sent to (zero requests);
    ///   • M7 (status-before-token): the token is NOT yet cancelled when the
    ///     boundary runs → the send proceeds → a request is recorded → FAIL.
    /// So a cloud send cannot start after the click even if the status write is
    /// delayed — and the order is no longer vacuously unpinned.
    @Test func cancelTokenIsSetBeforeStatusWriteSoNoSendStartsAfterTheClick() async throws {
        let prepareParked = OneShotLatch()
        let prepareRelease = OneShotLatch()
        // The injected clock releases the parked prepare exactly when the
        // cancel's status write calls now() — and ONLY after prepare has parked
        // (now() is also called earlier in the run). It then yields so the run
        // advances through the boundary check before cancel() returns.
        let releaseDuringCancel = OneShotLatch()
        let now: @Sendable () -> Date = {
            if prepareParked.isSet && releaseDuringCancel.setOnce() {
                prepareRelease.set()
            }
            return msDate()
        }
        let harness = try await makePipelineHarness(now: now)
        harness.notesPrimary.state.withLock {
            $0.onPrepare = { [prepareParked, prepareRelease] in
                prepareParked.set()
                await prepareRelease.wait()
                // Let the boundary check run while the cancel is still in flight.
                for _ in 0..<5 { await Task.yield() }
            }
        }
        let meeting = try await harness.importTestMeeting()
        let pipeline = harness.pipeline
        let task = Task { try? await pipeline.process(meetingID: meeting.id) }
        // Wait until the run is parked in prepare (token already installed).
        #expect(await waitUntil { prepareParked.isSet })
        #expect(await pipeline.hasRunInFlight(meeting.id))
        // Cancel: token first, THEN the status write (which trips `now` → release).
        _ = await pipeline.cancel(meetingID: meeting.id)
        _ = await task.value
        // The discriminator: with the correct order the boundary saw a cancelled
        // token and the primary engine was never sent to.
        let requests = harness.notesPrimary.state.withLock { $0.requests.count }
        #expect(requests == 0, "no cloud send may start after the click — the token precedes the status write")
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.status == .cancelled)
    }

    /// G10 §1: a cancelled REGENERATION is status-silent — the meeting stays
    /// `ready` with its prior notes byte-identical (C1 no-regress). The
    /// terminal-write guard never fires because regen has no failure-status
    /// write.
    @Test func cancelledRegenerationLeavesReadyNotesByteIdentical() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        let notesBefore = try #require(
            try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id))
        // Block the regeneration mid-run, cancel it.
        harness.asr.state.withLock { $0.transcribeDelaySeconds = 5 }
        let pipeline = harness.pipeline
        let task = Task { try await pipeline.regenerate(meetingID: meeting.id) }
        #expect(await waitUntil { await pipeline.hasRunInFlight(meeting.id) })
        let signalled = await pipeline.cancel(meetingID: meeting.id)
        #expect(signalled)
        // Status-silent: the meeting is STILL ready right after cancel.
        let afterCancel = try #require(try await harness.meeting(meeting.id))
        #expect(afterCancel.status == .ready, "a regen cancel never writes cancelled")
        _ = try? await task.value
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.status == .ready, "a cancelled regen leaves the meeting ready")
        let notesAfter = try #require(
            try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id))
        #expect(notesAfter.markdown == notesBefore.markdown, "prior notes byte-identical")
    }

    /// G10 §1 / AC1: NO post-cancel attempt or fallback send. The primary
    /// notes engine fails with a fallback-trigger AND cancels the run's token
    /// from inside its own call (`onGenerate`); the fallback hop's
    /// attempt-boundary check then throws `cancelled` BEFORE the fallback ever
    /// sends — the fallback engine records zero requests.
    @Test func noFallbackSendAfterTokenSet() async throws {
        let harness = try await makePipelineHarness()  // primary + fallback registered
        let meeting = try await harness.importTestMeeting()
        let pipeline = harness.pipeline
        // The primary trips the fallback path (input-too-long is a fallback
        // trigger) and, on its way, cancels THIS run's token.
        harness.notesPrimary.state.withLock {
            $0.error = .permanent(EngineFallbackReason.inputTooLong)
            $0.onGenerate = { [pipeline] in
                _ = await pipeline.cancel(meetingID: meeting.id)
            }
        }
        _ = try? await pipeline.process(meetingID: meeting.id)
        // The fallback engine was NEVER sent to — the boundary check fired.
        let fallbackRequests = harness.notesFallback.state.withLock { $0.requests.count }
        #expect(fallbackRequests == 0, "no fallback send may start after the token is set")
        // The cancel committed `cancelled` (a process-class run) and the
        // terminal write preserved it.
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.status == .cancelled)
    }

    /// G10 §1 (H-2 / L-1): the LOSER RULE — cancel-vs-completion, the
    /// completion-wins order. A cancel landing AFTER `finalizeMeetingProcessing`
    /// committed `ready`, while the run's token is STILL installed (the window
    /// between finalize and the runBody exit-defer), must NO-OP: the finished
    /// meeting stays `ready` with its notes and queued handoff. The
    /// `handoffKicker` fires inside that window (post-finalize, pre-defer), so
    /// cancelling from the kicker reproduces the exact race deterministically.
    @Test func cancelAfterCompletionCommitLeavesMeetingReady() async throws {
        let kicker = CancelOnKick()
        let harness = try await makePipelineHarness(handoffKicker: kicker)
        kicker.bind(harness.pipeline)
        let meeting = try await harness.importTestMeeting()
        kicker.cancelOnNextKick(meeting.id)
        // The run completes finalize (status → ready, handoff enqueued), THEN
        // kicker.kick() cancels — landing in the post-finalize window with the
        // token still live.
        let record = try await harness.pipeline.process(meetingID: meeting.id)
        #expect(record.versionHash != nil, "the run finished and committed ready")
        #expect(kicker.didCancel, "the kicker fired the in-window cancel")
        // Loser rule: completion committed first → the cancel no-ops.
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.status == .ready, "a completed meeting stays ready — the cancel loses")
        let notes = try await NotesRepository(database: harness.database)
            .fetch(meetingID: meeting.id)
        #expect(notes != nil, "the finished notes survive")
        #expect(try await harness.queueRows(meeting.id) == 1, "the queued handoff survives")
    }

    /// G10 §1 (H-2 / L-1): the OTHER order — cancel-then-completion. A cancel
    /// that lands while the run is genuinely still `.processing` DOES commit
    /// `cancelled`, and the run winds down. This pins that the loser-rule
    /// predicate did not over-correct into refusing legitimate mid-run cancels.
    @Test func cancelBeforeCompletionCommitsCancelled() async throws {
        let harness = try await makePipelineHarness()
        harness.asr.state.withLock { $0.transcribeDelaySeconds = 5 }
        let meeting = try await harness.importTestMeeting()
        let pipeline = harness.pipeline
        let task = Task { try await pipeline.process(meetingID: meeting.id) }
        #expect(await waitUntil { await pipeline.hasRunInFlight(meeting.id) })
        // The meeting is genuinely `.processing` here (writeRunEntry set it,
        // finalize has not run): the loser-rule predicate admits the cancel.
        let beforeCancel = try #require(try await harness.meeting(meeting.id))
        #expect(beforeCancel.status == .processing)
        #expect(await pipeline.cancel(meetingID: meeting.id))
        let afterCancel = try #require(try await harness.meeting(meeting.id))
        #expect(afterCancel.status == .cancelled, "a mid-processing cancel commits cancelled")
        _ = try? await task.value
        #expect(
            try #require(try await harness.meeting(meeting.id)).status == .cancelled,
            "the terminal write preserves the committed cancelled")
    }
}

/// A handoff kicker that cancels the pipeline run exactly once, the first time
/// it is kicked. The kick fires AFTER `finalizeMeetingProcessing` commits
/// `ready` but BEFORE the run's exit-defer removes the cancel token — the H-2
/// loser-rule window. The pipeline + target meeting are bound after
/// construction (the kicker is an init dependency of the pipeline).
final class CancelOnKick: HandoffKicking, @unchecked Sendable {
    private let state = Mutex<(pipeline: ProcessingPipeline?, target: MeetingID?, fired: Bool)>(
        (nil, nil, false))

    func bind(_ pipeline: ProcessingPipeline) {
        state.withLock { $0.pipeline = pipeline }
    }

    func cancelOnNextKick(_ meetingID: MeetingID) {
        state.withLock { $0.target = meetingID }
    }

    var didCancel: Bool { state.withLock { $0.fired } }

    func kick() async {
        let resolved: (ProcessingPipeline, MeetingID)? = state.withLock { box in
            guard !box.fired, let pipeline = box.pipeline, let target = box.target else { return nil }
            box.fired = true
            return (pipeline, target)
        }
        if let (pipeline, target) = resolved { _ = await pipeline.cancel(meetingID: target) }
    }
}

/// A latch that can be set once and waited on by any number of awaiters.
/// `setOnce()` returns true exactly once (the order-discriminating trigger);
/// `isSet` is a non-blocking poll. Used to pin concurrency ordering in the M-1
/// token-before-status test without timing assumptions.
final class OneShotLatch: @unchecked Sendable {
    private let state = Mutex<(set: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    var isSet: Bool { state.withLock { $0.set } }

    func set() {
        let toResume: [CheckedContinuation<Void, Never>] = state.withLock { box in
            guard !box.set else { return [] }
            box.set = true
            defer { box.waiters.removeAll() }
            return box.waiters
        }
        for waiter in toResume { waiter.resume() }
    }

    /// Sets the latch and returns true ONLY the first time it transitions.
    func setOnce() -> Bool {
        let didTransition: Bool = state.withLock { box in
            guard !box.set else { return false }
            box.set = true
            return true
        }
        if didTransition {
            // No waiters expected on this trigger latch; nothing to resume.
        }
        return didTransition
    }

    func wait() async {
        let alreadySet: Bool = state.withLock { box in
            if box.set { return true }
            return false
        }
        if alreadySet { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow: Bool = state.withLock { box in
                if box.set { return true }
                box.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}

@Suite struct PipelineRegenerationTests {
    /// Processes once (ready), then reconfigures mocks for the regen test.
    private func readyHarness() async throws -> (PipelineHarness, Meeting) {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        return (harness, meeting)
    }

    @Test func regenerateSkipsIngestAndWorksFromRetainedAudio() async throws {
        let (harness, meeting) = try await readyHarness()
        // The import copy is gone; only audio.m4a remains — regeneration must
        // not need ingest at all.
        let events = await harness.pipeline.events()
        let record = try await harness.pipeline.regenerate(meetingID: meeting.id)
        var beganStages: [PipelineStage] = []
        for await event in events {
            if case .stageBegan(_, let stage) = event { beganStages.append(stage) }
            if case .runCompleted = event { break }
            if case .runFailed = event { break }
        }
        #expect(!beganStages.contains(.ingest), "regenerate() must NEVER run ingest")
        #expect(beganStages.first == .transcode)
        #expect(record.regeneration)
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.status == .ready)
    }

    @Test func regenerateAfterDeletingTranscriptAndNotesRestoresThem() async throws {
        let (harness, meeting) = try await readyHarness()
        try await TranscriptRepository(database: harness.database).deleteTranscript(meetingID: meeting.id)
        try await harness.database.pool.write { db in
            try db.execute(sql: "DELETE FROM meeting_notes WHERE meeting_id = ?", arguments: [meeting.id])
        }
        try FileManager.default.removeItem(at: harness.database.paths.transcriptURL(meeting.id))
        try FileManager.default.removeItem(at: harness.database.paths.notesURL(meeting.id))
        _ = try await harness.pipeline.regenerate(meetingID: meeting.id)
        #expect(!(try await harness.segments(meeting.id)).isEmpty)
        #expect(try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id) != nil)
        #expect(FileManager.default.fileExists(atPath: harness.database.paths.transcriptURL(meeting.id).path))
        #expect(FileManager.default.fileExists(atPath: harness.database.paths.notesURL(meeting.id).path))
    }

    @Test func earlyRegenerationFailureKeepsReadyAndSetsNoNote() async throws {
        let (harness, meeting) = try await readyHarness()
        harness.asr.state.withLock { $0.transcribeError = .transient("flaky") }
        let oldSegments = try await harness.segments(meeting.id)
        do {
            _ = try await harness.pipeline.regenerate(meetingID: meeting.id)
            Issue.record("expected failure")
        } catch let error as PipelineError {
            #expect(error.stage == .asr)
        }
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.status == .ready, "C1 no-regress: failed regeneration keeps ready")
        #expect(stored.lastProcessingError == "asr: flaky")
        #expect(stored.processingNote == nil, "pre-stage-11 regen failure sets NO note")
        // Old transcript untouched (provenance not re-labeled either).
        let after = try await harness.segments(meeting.id)
        #expect(after.map(\.text) == oldSegments.map(\.text))
        #expect(stored.asrProvenance?.engine == "pipeline-mock-asr")
    }

    @Test func lateRegenerationFailureSetsPartialNote() async throws {
        let (harness, meeting) = try await readyHarness()
        harness.notesPrimary.state.withLock { $0.summary = "" }  // renderer refusal at stage 12
        do {
            _ = try await harness.pipeline.regenerate(meetingID: meeting.id)
            Issue.record("expected failure")
        } catch let error as PipelineError {
            #expect(error.stage == .persistNotes)
        }
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.status == .ready)
        #expect(
            stored.processingNote
                == "partial regeneration: transcript updated; persistNotes failed")
        #expect(stored.lastProcessingError?.starts(with: "persistNotes:") == true)
        // The transcript WAS updated — exactly what the note surfaces.
        #expect(!(try await harness.segments(meeting.id)).isEmpty)
    }

    @Test func regenerateClearsStaleProcessingNoteAtEntry() async throws {
        let (harness, meeting) = try await readyHarness()
        try await harness.database.pool.write { db in
            try db.execute(
                sql: "UPDATE meeting SET processing_note = 'fallback: stale' WHERE id = ?",
                arguments: [meeting.id])
        }
        _ = try await harness.pipeline.regenerate(meetingID: meeting.id)
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.processingNote == nil, "note must be cleared at entry and not re-set without a fallback")
    }

    @Test func failureNoteWinsOverFallbackNote() async throws {
        let (harness, meeting) = try await readyHarness()
        // Fallback fires (primary trigger), then stage 12 fails (fallback
        // returns an empty summary): the failure note must win, never combine.
        harness.notesPrimary.state.withLock {
            $0.error = .permanent(EngineFallbackReason.inputTooLong)
        }
        harness.notesFallback.state.withLock { $0.summary = " " }
        do {
            _ = try await harness.pipeline.regenerate(meetingID: meeting.id)
            Issue.record("expected failure")
        } catch let error as PipelineError {
            #expect(error.stage == .persistNotes)
        }
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(
            stored.processingNote
                == "partial regeneration: transcript updated; persistNotes failed")
    }

    /// Field 2026-06-11 ("Internal Project Review"): a regenerate re-ran the
    /// nondeterministic diarizer, the durable Meet speaker events re-voted
    /// onto shifted clusters, and two speakers (S0/S1) reverted to unnamed.
    /// The fix: process() persists `diarization.json`; regenerate() REUSES it
    /// instead of re-diarizing, so speaker labels — and the names voted onto
    /// them — are deterministic and idempotent across regenerations.
    @Test func regenerateReusesPersistedDiarizationAndNeverReDiarizes() async throws {
        let (harness, meeting) = try await readyHarness()
        // process() wrote the artifact and called the diarizer exactly once.
        let diarPath = harness.database.paths.diarizationURL(meeting.id).path
        #expect(FileManager.default.fileExists(atPath: diarPath), "process() must persist diarization.json")
        let callsAfterProcess = harness.diarizer.state.withLock { $0.expectedSpeakerCounts.count }
        #expect(callsAfterProcess == 1)
        let labelsAfterProcess = Set((try await harness.segments(meeting.id)).map(\.speakerLabel))

        // Reconfigure the diarizer to a DIFFERENT clustering (the
        // nondeterminism a real re-diarize would introduce). If regenerate
        // re-diarized, the transcript labels would change.
        harness.diarizer.state.withLock {
            $0.output = DiarizationOutput(
                segments: [DiarizedSegment(speakerLabel: "S0", startSeconds: 0.0, endSeconds: 1.9)],
                speakerCount: 1)
        }
        _ = try await harness.pipeline.regenerate(meetingID: meeting.id)

        // The diarizer was NOT called again; labels are unchanged.
        let callsAfterRegen = harness.diarizer.state.withLock { $0.expectedSpeakerCounts.count }
        #expect(callsAfterRegen == 1, "regenerate() must reuse persisted diarization, not re-diarize")
        let labelsAfterRegen = Set((try await harness.segments(meeting.id)).map(\.speakerLabel))
        #expect(labelsAfterRegen == labelsAfterProcess, "speaker labels must be stable across regeneration")
    }

    /// A meeting predating the persisted artifact (deleted here) still
    /// regenerates — it falls back to a fresh diarize and writes the artifact
    /// for the NEXT regeneration to reuse.
    @Test func regenerateFallsBackToFreshDiarizeWhenArtifactMissing() async throws {
        let (harness, meeting) = try await readyHarness()
        try FileManager.default.removeItem(at: harness.database.paths.diarizationURL(meeting.id))
        let callsBefore = harness.diarizer.state.withLock { $0.expectedSpeakerCounts.count }
        _ = try await harness.pipeline.regenerate(meetingID: meeting.id)
        let callsAfter = harness.diarizer.state.withLock { $0.expectedSpeakerCounts.count }
        #expect(callsAfter == callsBefore + 1, "missing artifact → one fresh diarize")
        #expect(
            FileManager.default.fileExists(
                atPath: harness.database.paths.diarizationURL(meeting.id).path),
            "the fallback diarize re-persists the artifact")
    }

    @Test func successfulReprocessingDedupsQueueOnIdenticalPayload() async throws {
        // Fixed clock + deterministic mocks → identical payload bytes →
        // immutable writer no-ops and enqueue dedups on (meeting, hash).
        let (harness, meeting) = try await readyHarness()
        _ = try await harness.pipeline.regenerate(meetingID: meeting.id)
        #expect(try await harness.queueRows(meeting.id) == 1)
        let payloads = try FileManager.default.contentsOfDirectory(
            atPath: harness.database.paths.handoffDirectory(meeting.id).path)
            .filter { $0.hasSuffix(".json") }
        #expect(payloads.count == 1, "expected one content-addressed payload, got \(payloads)")
    }
}

// MARK: - G7 purpose threading (AC3)

/// The pipeline threads the cloud-spend purpose down to the summarization
/// engine: process()/processCaptured() = generation; regenerate() and the
/// notes-pending self-heal resume = regeneration. The recording mock engine
/// captures the purpose it was handed.
@Suite struct CloudSpendPurposeThreadingTests {
    @Test func processThreadsGeneration() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        let purposes = harness.notesPrimary.state.withLock { $0.purposes }
        #expect(purposes == [.generation])
    }

    @Test func regenerateThreadsRegeneration() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        // Clear the generation call so we inspect only the regeneration purpose.
        harness.notesPrimary.state.withLock { $0.purposes.removeAll() }
        _ = try await harness.pipeline.regenerate(meetingID: meeting.id)
        let purposes = harness.notesPrimary.state.withLock { $0.purposes }
        #expect(purposes == [.regeneration])
    }

    /// M-1: the common D17 case — the original process() reached the ceiling /
    /// had no key and the meeting NEVER produced notes. The self-heal resume
    /// mints the meeting's FIRST notes, so it bills as `.generation`, NOT
    /// `.regeneration` (the user never regenerated this meeting).
    @Test func notesPendingResumeOfNeverNotedMeetingThreadsGeneration() async throws {
        // Drive to notes-pending (heavyweight-only fallback never auto-loads),
        // then heal the primary and resume via the notes-only self-heal.
        let harness = try await makePipelineHarness(
            fallbackLoadProfile: .heavyweight(estimatedPeakBytes: 18 * 1_073_741_824))
        let meeting = try await harness.importTestMeeting()
        harness.notesPrimary.state.withLock {
            $0.error = .configurationMissing(key: "apiKey")
        }
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        // The process() attempt threaded generation before failing pending.
        #expect(harness.notesPrimary.state.withLock { $0.purposes } == [.generation])
        // No notes were ever persisted by the failed first run.
        #expect(try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id) == nil)

        harness.notesPrimary.state.withLock {
            $0.error = nil
            $0.purposes.removeAll()
        }
        _ = try await harness.pipeline.processNotesOnly(meetingID: meeting.id)
        // The resume produces the meeting's first-ever notes → generation.
        #expect(harness.notesPrimary.state.withLock { $0.purposes } == [.generation])
    }

    /// M-1: a meeting that ALREADY had persisted notes (a successful first run)
    /// is later driven notes-pending and resumed. THIS resume re-runs notes for
    /// an already-noted meeting, so it correctly bills as `.regeneration`.
    @Test func notesPendingResumeOfAlreadyNotedMeetingThreadsRegeneration() async throws {
        let harness = try await makePipelineHarness(
            fallbackLoadProfile: .heavyweight(estimatedPeakBytes: 18 * 1_073_741_824))
        let meeting = try await harness.importTestMeeting()
        // First run succeeds and persists notes (generation).
        _ = try await harness.pipeline.process(meetingID: meeting.id)
        #expect(try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id) != nil)

        // A regenerate() now resolves to notes-pending (heavyweight-only
        // fallback never auto-loads): the existing ready notes survive
        // (C1 no-regress) and a pending marker is written.
        harness.notesPrimary.state.withLock {
            $0.error = .configurationMissing(key: "apiKey")
            $0.purposes.removeAll()
        }
        _ = try await harness.pipeline.regenerate(meetingID: meeting.id)
        #expect(try await NotesRepository(database: harness.database).fetch(meetingID: meeting.id) != nil)

        harness.notesPrimary.state.withLock {
            $0.error = nil
            $0.purposes.removeAll()
        }
        _ = try await harness.pipeline.processNotesOnly(meetingID: meeting.id)
        // Resume of an already-noted meeting bills as a regeneration.
        #expect(harness.notesPrimary.state.withLock { $0.purposes } == [.regeneration])
    }
}
