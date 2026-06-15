import Foundation
import Testing

@testable import BlaiseCore

// C11 AC1: processCaptured stage wiring with mock engines — mic-label path
// (`user` + UserIdentity name at creation), system-diarize path, interleave,
// payload speaker.source, the regenerate/dispatch track-inventory rule, the
// capture-recovery note lifecycle, and rule-0 immunity end to end.

extension PipelineHarness {
    /// Plants a captured meeting: row + directory + retained track m4as
    /// (encoded from generated WAVs through the real encoder).
    func plantCapturedMeeting(
        tracks: [CaptureTrack],
        status: MeetingStatus = .failed,
        attendees: [Attendee] = [Attendee(name: "Sam", email: "sam.rivera@vexatron.test", source: .manual)],
        processingNote: String? = nil,
        captured: Bool = false
    ) async throws -> Meeting {
        let meeting = Meeting(
            id: ULID.generate(),
            title: "Reunião capturada",
            startedAt: msDate(),
            endedAt: msDate(1_770_000_120),
            source: .meet,
            status: status,
            attendees: attendees,
            processingNote: processingNote,
            captured: captured,
            createdAt: msDate(),
            updatedAt: msDate())
        try database.paths.createMeetingDirectory(meeting.id)
        try await MeetingRepository(database: database).create(meeting)
        for track in tracks {
            let wav = dataRoot.appendingPathComponent("track-\(UUID().uuidString).wav")
            try writeTestWAV(to: wav)
            try AudioTranscoder.encodeToM4A(
                wav: wav, destination: track.retainedURL(database.paths, meetingID: meeting.id))
            try FileManager.default.removeItem(at: wav)
        }
        return meeting
    }

    func payloadJSON(_ record: PipelineRunRecord) throws -> [String: Any] {
        let url = dataRoot.appendingPathComponent(try #require(record.payloadPath))
        let data = try Data(contentsOf: url)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

@Suite("C11 processCaptured", .serialized)
struct ProcessCapturedTests {
    @Test("two tracks: mic labeled user+named at creation, system diarized, interleaved, ready")
    func twoTrackRun() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.plantCapturedMeeting(tracks: [.system, .mic])

        let record = try await harness.pipeline.processCaptured(meetingID: meeting.id)
        #expect(record.capturedTracks == ["system", "mic"])
        // Default mock data: mic text ≠ system text → no echo drops.
        #expect(record.echoDroppedSegments == nil)

        // Two ASR passes, same engine: system temp WAV + mic temp WAV.
        let requests = harness.asr.state.withLock { $0.requests }
        #expect(requests.count == 2)
        #expect(requests.filter { $0.audioURL.lastPathComponent.contains("-mic-") }.count == 1)

        let segments = try await harness.segments(meeting.id)
        let userSegments = segments.filter { $0.speakerLabel == TranscriptSegment.userLabel }
        #expect(!userSegments.isEmpty)
        #expect(userSegments.allSatisfy { $0.speakerName == "Sam" })
        let systemLabels = Set(segments.map(\.speakerLabel)).subtracting(["user"])
        #expect(systemLabels.contains("S0") || systemLabels.contains("S1"))
        // ord re-sequenced globally, 0..n-1.
        #expect(segments.map(\.ord) == Array(0 ..< segments.count))

        // Both raw envelopes exist (additive artifact for the mic pass).
        #expect(FileManager.default.fileExists(atPath: harness.database.paths.rawASRURL(meeting.id).path))
        #expect(FileManager.default.fileExists(atPath: harness.database.paths.rawASRMicURL(meeting.id).path))

        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.status == .ready)
        #expect(try await harness.queueRows(meeting.id) == 1)

        // Payload speaker.source: user-labeled segments are "microphone"
        // by the DURABLE label predicate (C8 v4.2).
        let payload = try harness.payloadJSON(record)
        let transcript = try #require(payload["transcript"] as? [[String: Any]])
        let speakers = transcript.compactMap { $0["speaker"] as? [String: Any] }
        let microphoneRows = speakers.filter { $0["source"] as? String == "microphone" }
        #expect(!microphoneRows.isEmpty)
        #expect(microphoneRows.allSatisfy { $0["diarization_label"] as? String == "user" })
        let speakerRows = speakers.filter { ($0["diarization_label"] as? String)?.hasPrefix("S") == true }
        #expect(speakerRows.allSatisfy { $0["source"] as? String == "speaker" })
    }

    @Test("G3-H1: empty (pre-onboarding) identity → mic turns are nameless (nil), payload carries null not \"\"")
    func twoTrackRunWithEmptyIdentity() async throws {
        let harness = try await makePipelineHarness()
        // Pre-onboarding: overwrite the harness's seeded "Sam" with the neutral
        // empty identity. The live mic-naming path must then leave mic segments
        // NAMELESS (speakerName == nil) so the "You" UI fallback and the payload
        // null both fire — not persist an empty speaker name.
        try await SettingsStore(database: harness.database).set(
            UserIdentity.settingsKey, to: UserIdentity.shippedDefault)
        let meeting = try await harness.plantCapturedMeeting(
            tracks: [.system, .mic], attendees: [])

        let record = try await harness.pipeline.processCaptured(meetingID: meeting.id)

        let segments = try await harness.segments(meeting.id)
        let userSegments = segments.filter { $0.speakerLabel == TranscriptSegment.userLabel }
        #expect(!userSegments.isEmpty)
        // Nameless, NOT empty string — keys the "You" fallback (== nil).
        #expect(userSegments.allSatisfy { $0.speakerName == nil })

        // Payload: mic rows carry name null (not "") and still tag "microphone"
        // by the DURABLE `user` label predicate (identity-independent).
        let payload = try harness.payloadJSON(record)
        let transcript = try #require(payload["transcript"] as? [[String: Any]])
        let micSpeakers = transcript.compactMap { $0["speaker"] as? [String: Any] }
            .filter { $0["diarization_label"] as? String == "user" }
        #expect(!micSpeakers.isEmpty)
        #expect(micSpeakers.allSatisfy { $0["source"] as? String == "microphone" })
        // name is JSON null, present as NSNull — never the empty string.
        #expect(micSpeakers.allSatisfy { $0["name"] is NSNull })
        #expect(micSpeakers.allSatisfy { ($0["name"] as? String) != "" })
        // Owner honestly empty too (no fabricated default).
        let owner = try #require(payload["owner"] as? [String: Any])
        #expect(owner["name"] as? String == "")
    }

    @Test("cross-track echo: near-duplicate raw mic segment dropped pre-merge, genuine mic speech kept (C7 v3.8)")
    func echoSuppressionEndToEnd() async throws {
        let harness = try await makePipelineHarness()
        harness.asr.state.withLock {
            $0.segments = [
                ASRSegment(
                    startSeconds: 0.0, endSeconds: 4.0,
                    text: "Vamos revisar o contrato da empresa amanhã de manhã.")
            ]
            $0.micSegments = [
                // Acoustic bleed: the system sentence under the user's label
                // (validation gap 5's worst case).
                ASRSegment(
                    startSeconds: 0.3, endSeconds: 4.2,
                    text: "vamos revisar o contrato da empresa amanhã de manhã"),
                // Genuine reply; > 2 s gap so merge consolidation keeps it
                // separate from the bleed segment.
                ASRSegment(
                    startSeconds: 6.5, endSeconds: 7.5,
                    text: "Perfeito, eu reviso tudo ainda hoje à tarde."),
            ]
        }
        harness.diarizer.state.withLock {
            $0.output = DiarizationOutput(
                segments: [DiarizedSegment(speakerLabel: "S0", startSeconds: 0.0, endSeconds: 4.5)],
                speakerCount: 1)
        }
        let meeting = try await harness.plantCapturedMeeting(tracks: [.system, .mic])

        let record = try await harness.pipeline.processCaptured(meetingID: meeting.id)
        #expect(record.echoDroppedSegments == 1)

        let segments = try await harness.segments(meeting.id)
        let userSegments = segments.filter { $0.speakerLabel == TranscriptSegment.userLabel }
        #expect(userSegments.count == 1)
        #expect(userSegments.allSatisfy { $0.text.contains("Perfeito") })
        // The system copy survives under its diarization-grounded label.
        #expect(segments.contains { $0.speakerLabel == "S0" && $0.text.contains("contrato") })
        #expect(segments.map(\.ord) == Array(0 ..< segments.count))
    }

    @Test("rule 0 end to end: an LLM proposal renaming `user` is dropped")
    func rule0Immunity() async throws {
        let harness = try await makePipelineHarness()
        harness.notesPrimary.state.withLock {
            $0.mapping = [
                SpeakerNameProposal(
                    label: "user", name: "Fábio", confidence: .high, evidence: "wrong"),
            ]
        }
        let meeting = try await harness.plantCapturedMeeting(tracks: [.system, .mic])
        _ = try await harness.pipeline.processCaptured(meetingID: meeting.id)

        let segments = try await harness.segments(meeting.id)
        let userSegments = segments.filter { $0.speakerLabel == TranscriptSegment.userLabel }
        #expect(!userSegments.isEmpty)
        #expect(userSegments.allSatisfy { $0.speakerName == "Sam" })
    }

    @Test("regenerate dispatches by track inventory: a captured meeting reruns two-track")
    func regenerateDispatch() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.plantCapturedMeeting(tracks: [.system, .mic])
        _ = try await harness.pipeline.processCaptured(meetingID: meeting.id)

        let record = try await harness.pipeline.regenerate(meetingID: meeting.id)
        #expect(record.capturedTracks == ["system", "mic"])
        #expect(harness.asr.state.withLock { $0.requests.count } == 4)  // 2 runs × 2 tracks
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.status == .ready)
    }

    @Test("dispatchProcessing, non-ready captured meeting → the two-track variant")
    func dispatchNonReady() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.plantCapturedMeeting(tracks: [.system, .mic], status: .failed)
        let record = try await harness.pipeline.dispatchProcessing(meetingID: meeting.id)
        #expect(record.capturedTracks == ["system", "mic"])
    }

    @Test("mic-track lost: the durable captured flag still dispatches the two-track variant")
    func capturedFlagSurvivesMicLoss() async throws {
        let harness = try await makePipelineHarness()
        // System track only on disk — but the row carries captured = true
        // (set at capture start), as after a damaged-mic partial recovery.
        let meeting = try await harness.plantCapturedMeeting(
            tracks: [.system], status: .failed, captured: true)

        let record = try await harness.pipeline.dispatchProcessing(meetingID: meeting.id)
        // capturedTracks is only recorded by the captured variant — the
        // file-first path would have left it nil and let isSelf events vote.
        #expect(record.capturedTracks == ["system"])
        let requests = harness.asr.state.withLock { $0.requests }
        #expect(requests.count == 1)
        #expect(requests.allSatisfy { !$0.audioURL.lastPathComponent.contains("-mic-") })
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.status == .ready)

        // Regenerate keeps dispatching captured, still without a mic file.
        let again = try await harness.pipeline.regenerate(meetingID: meeting.id)
        #expect(again.capturedTracks == ["system"])
    }

    @Test("mic-only survivor: transcript proceeds from the mic track; no diarization")
    func micOnlySurvivor() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.plantCapturedMeeting(tracks: [.mic])

        let record = try await harness.pipeline.processCaptured(meetingID: meeting.id)
        #expect(record.capturedTracks == ["mic"])
        #expect(harness.diarizer.state.withLock { $0.attendeeCounts }.isEmpty)

        let segments = try await harness.segments(meeting.id)
        #expect(!segments.isEmpty)
        #expect(segments.allSatisfy { $0.speakerLabel == TranscriptSegment.userLabel })
        #expect(segments.allSatisfy { $0.speakerName == "Sam" })
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.status == .ready)
    }

    @Test("capture-recovery note: preserved by entry, cleared only by a both-tracks success")
    func noteLifecycle() async throws {
        let harness = try await makePipelineHarness()
        let note = "\(CaptureRecovery.notePrefix) mic track audio damaged — transcript proceeds from the system track"

        // Mic-only run with the note: PRESERVED (not a both-tracks run).
        let partial = try await harness.plantCapturedMeeting(tracks: [.mic], processingNote: note)
        _ = try await harness.pipeline.processCaptured(meetingID: partial.id)
        let afterPartial = try #require(try await harness.meeting(partial.id))
        #expect(afterPartial.processingNote == note)

        // Both-tracks run with the note: CLEARED at the terminal write.
        let healed = try await harness.plantCapturedMeeting(
            tracks: [.system, .mic], processingNote: note)
        _ = try await harness.pipeline.processCaptured(meetingID: healed.id)
        let afterHealed = try #require(try await harness.meeting(healed.id))
        #expect(afterHealed.processingNote == nil)
    }

    @Test("capture-recovery note survives a FAILED run too")
    func noteSurvivesFailure() async throws {
        let harness = try await makePipelineHarness()
        let note = "\(CaptureRecovery.notePrefix) mic track audio damaged"
        let meeting = try await harness.plantCapturedMeeting(
            tracks: [.system, .mic], processingNote: note)
        harness.asr.state.withLock { $0.transcribeError = .permanent("asr exploded") }

        await #expect(throws: PipelineError.self) {
            try await harness.pipeline.processCaptured(meetingID: meeting.id)
        }
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.status == .failed)
        #expect(stored.processingNote == note)
        #expect(stored.lastProcessingError?.contains("asr exploded") == true)
    }

    @Test("fallback note never overwrites a surviving capture-recovery note")
    func fallbackDoesNotOverwriteRecovery() async throws {
        let harness = try await makePipelineHarness()
        let note = "\(CaptureRecovery.notePrefix) mic track audio damaged"
        let meeting = try await harness.plantCapturedMeeting(tracks: [.system], processingNote: note)
        harness.notesPrimary.state.withLock {
            $0.error = .permanent(EngineFallbackReason.inputTooLong)
        }

        let record = try await harness.pipeline.processCaptured(meetingID: meeting.id)
        #expect(record.fallback != nil)
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(stored.processingNote == note)  // the recovery fact wins
    }

    @Test("stored isSelf events are excluded from system-track hints (C4 v5.3)")
    func excludingSelfQuery() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.plantCapturedMeeting(tracks: [.system, .mic])
        try await harness.database.pool.write { db in
            for (index, isSelf) in [false, true, false].enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO meeting_speaker_event
                        (meeting_id, dedupe_id, display_name, participant_id, is_self,
                         start_epoch_ms, end_epoch_ms)
                        VALUES (?, ?, ?, NULL, ?, ?, ?)
                        """,
                    arguments: [
                        meeting.id, "evt-\(index)", isSelf ? "Sam" : "Fábio Souza", isSelf,
                        1_770_000_000_000 + index * 1000, 1_770_000_000_500 + index * 1000,
                    ])
            }
        }
        let repository = MeetEventsRepository(database: harness.database)
        let all = try await repository.activeSpeakerEvents(meetingID: meeting.id)
        #expect(all.count == 3)
        let voting = try await repository.activeSpeakerEvents(
            meetingID: meeting.id, excludingSelf: true)
        #expect(voting.count == 2)
        #expect(voting.allSatisfy { $0.displayName == "Fábio Souza" })
    }

    /// Field 2026-06-11 (internal): pre-0.2.0 extensions stored markup/sentence
    /// junk in `meeting_speaker_event.display_name`; one was voted onto a
    /// diarized cluster (the transcript's "As pessoas ainda podem ver seu
    /// vídeo completo." speaker). The vote-input read re-sanitizes, so junk
    /// events never reach the resolver — while clean names are unaffected and
    /// the raw rows are untouched.
    @Test("durable junk speaker events are filtered out of the vote inputs")
    func junkSpeakerEventsAreFilteredOnRead() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.plantCapturedMeeting(tracks: [.system, .mic])
        let cssBlock = ".ink-canvas-parent {\n  height: 100%;\n}"
        let rows: [(String, String)] = [
            ("evt-clean", "Anna Reyes"),
            ("evt-sentence", "As pessoas ainda podem ver seu vídeo completo."),
            ("evt-css", cssBlock),
        ]
        try await harness.database.pool.write { db in
            for (index, (dedupe, name)) in rows.enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO meeting_speaker_event
                        (meeting_id, dedupe_id, display_name, participant_id, is_self,
                         start_epoch_ms, end_epoch_ms)
                        VALUES (?, ?, ?, NULL, 0, ?, ?)
                        """,
                    arguments: [
                        meeting.id, dedupe, name,
                        1_770_000_000_000 + index * 1000, 1_770_000_000_500 + index * 1000,
                    ])
            }
        }
        let events = try await MeetEventsRepository(database: harness.database)
            .activeSpeakerEvents(meetingID: meeting.id)
        #expect(events.map(\.displayName) == ["Anna Reyes"])  // junk dropped, raw rows still 3
        #expect(try await harness.database.count("meeting_speaker_event") == 3)
    }

    @Test("file-first process() is untouched: no capturedTracks, single ASR pass")
    func fileFirstUntouched() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.importTestMeeting()
        let record = try await harness.pipeline.process(meetingID: meeting.id)
        #expect(record.capturedTracks == nil)
        #expect(harness.asr.state.withLock { $0.requests.count } == 1)
        #expect(
            !FileManager.default.fileExists(
                atPath: harness.database.paths.rawASRMicURL(meeting.id).path))
    }
}

// MARK: - apply() rule 0 unit coverage (C4 v5.3 amendment)

@Suite("C11 apply rule 0")
struct ApplyRuleZeroTests {
    private let suppression = VocabFixtures.suppression
    private let commonNames = VocabFixtures.brCommonNames

    private func segments() -> [TranscriptSegment] {
        [
            TranscriptSegment(
                meetingID: "01TESTMEETING0000000000000", ord: 0, startSeconds: 0, endSeconds: 5,
                speakerLabel: TranscriptSegment.userLabel, speakerName: "Sam", text: "Olá."),
            TranscriptSegment(
                meetingID: "01TESTMEETING0000000000000", ord: 1, startSeconds: 5, endSeconds: 9,
                speakerLabel: "S0", speakerName: nil, text: "Oi, tudo bem?"),
        ]
    }

    @Test("a mapping targeting `user` is dropped; user segments never modified")
    func userMappingDropped() {
        let result = SpeakerResolution(
            assignments: ["user": "Fábio Souza", "S0": "Fábio Souza"], unresolved: []
        ).apply(
            to: segments(),
            attendeeNames: ["Fábio Souza"],
            eventNames: [],
            userName: "Sam",
            suppression: suppression,
            commonNames: commonNames)
        #expect(result[0].speakerName == "Sam")  // immune
        #expect(result[1].speakerName == "Fábio Souza")  // normal path intact
    }
}
