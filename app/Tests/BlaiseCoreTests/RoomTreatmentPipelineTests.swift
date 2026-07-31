import Foundation
import Testing
@testable import BlaiseCore

@Suite("Room treatment captured pipeline", .serialized)
struct RoomTreatmentPipelineTests {
    private let explicitRoomFacts = CaptureFacts(
        sourceProvenance: .explicit, linkClass: .none)
    private let gateFacts = CaptureFacts(
        sourceProvenance: .classified, linkClass: .recognized)

    private func artifact(
        _ harness: PipelineHarness, _ meetingID: MeetingID
    ) throws -> RoomTreatmentArtifact {
        let data = try Data(
            contentsOf: harness.database.paths.roomTreatmentURL(meetingID))
        return try JSONDecoder().decode(RoomTreatmentArtifact.self, from: data)
    }

    /// AC2's named instrument: a FROZEN baseline, minted from the pre-wiring
    /// tree (`fixtures/room_treatment/captured_solo_segments.json`), not a
    /// same-run mirror of the functions under test. Full `PinnedSegment` shape,
    /// `ord` included; storage ids are erased by `PinnedSegment` because each
    /// run mints fresh ULIDs.
    @Test("AC2 solo verdict preserves the full pre-wiring captured output")
    func soloOutputIdentity() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.plantCapturedMeeting(
            tracks: [.system, .mic], captureFacts: gateFacts, encodeTracks: false)

        let record = try await harness.pipeline.processCaptured(meetingID: meeting.id)
        let actual = try await harness.segments(meeting.id)
        #expect(record.roomTreatment?.gateVerdict == .solo)
        let baseline = try Data(contentsOf: Self.capturedSoloBaselineURL)
        #expect(
            try pinBytes(actual.map(PinnedSegment.init)) == baseline,
            "captured solo output diverged from the frozen pre-wiring baseline")
        #expect(
            try artifact(harness, meeting.id).micDiarization.segments.first?.speakerLabel
                == "M0")
    }

    static var capturedSoloBaselineURL: URL {
        RegressionPin.repoRoot
            .appendingPathComponent("fixtures/room_treatment", isDirectory: true)
            .appendingPathComponent("captured_solo_segments.json")
    }

    @Test("room merge keeps an independent M namespace and stamps before naming")
    func roomMergeAndStampOrdering() async throws {
        let harness = try await makePipelineHarness()
        try await harness.seedUsableVoiceProfile()
        harness.asr.state.withLock {
            $0.micSegments = [
                ASRSegment(startSeconds: 0, endSeconds: 0.9, text: "Owner update."),
                ASRSegment(startSeconds: 1, endSeconds: 1.9, text: "Colleague update."),
            ]
        }
        harness.diarizer.state.withLock {
            $0.micOutput = DiarizationOutput(
                segments: [
                    DiarizedSegment(speakerLabel: "M0", startSeconds: 0, endSeconds: 0.95),
                    DiarizedSegment(speakerLabel: "M1", startSeconds: 0.98, endSeconds: 2),
                ],
                speakerCount: 2)
            $0.micCentroids = ["M0": [1, 0], "M1": [0, 1]]
            $0.systemCentroids = ["S0": [0, 1], "S1": [0.2, 0.8]]
        }
        let meeting = try await harness.plantCapturedMeeting(
            tracks: [.system, .mic], source: .inPerson,
            captureFacts: explicitRoomFacts, encodeTracks: false)

        let record = try await harness.pipeline.processCaptured(meetingID: meeting.id)
        let stored = try await harness.segments(meeting.id)
        let room = try artifact(harness, meeting.id)
        #expect(room.gateVerdict == .room)
        #expect(Set(room.micDiarization.segments.map(\.speakerLabel)) == ["M0", "M1"])
        #expect(Set(room.micDiarization.segments.map(\.speakerLabel)).isDisjoint(
            with: Set(room.clusterCentroids.system.keys)))
        #expect(stored.contains {
            $0.speakerLabel == TranscriptSegment.userLabel && $0.speakerName == "Sam"
        })
        #expect(stored.contains {
            $0.speakerLabel == "M1" && $0.speakerName == nil
        })
        #expect(record.roomTreatment?.ownerStampedClusters == 1)

        _ = try await harness.pipeline.renameSpeaker(
            meetingID: meeting.id, speakerLabel: "M1", to: "Dana Okonkwo")
        let rename = try #require(
            try await harness.database.pool.read { db in
                try SpeakerRenameStore.all(db, meetingID: meeting.id)
                    .first { $0.speakerLabel == "M1" }
            })
        #expect(!rename.stale)
        _ = try await harness.pipeline.regenerate(meetingID: meeting.id)
        #expect(try await harness.segments(meeting.id).contains {
            $0.speakerLabel == "M1" && $0.speakerName == "Dana Okonkwo"
        })
        #expect(try await harness.database.pool.read { db in
            try SpeakerRenameStore.all(db, meetingID: meeting.id)
                .first { $0.speakerLabel == "M1" }?.stale
        } == false)
        await #expect(throws: SpeakerRenameError.self) {
            try await harness.pipeline.renameSpeaker(
                meetingID: meeting.id, speakerLabel: "M1", to: "Sam")
        }
    }

    @Test("regeneration reuses mic evidence and current profile then honors deletion semantics")
    func regenerationAndDeletion() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.plantCapturedMeeting(
            tracks: [.system, .mic], source: .inPerson,
            captureFacts: explicitRoomFacts, encodeTracks: false)
        _ = try await harness.pipeline.processCaptured(meetingID: meeting.id)
        #expect(try await harness.segments(meeting.id).contains {
            $0.speakerLabel == "M0"
        })
        let callsAfterFirst = harness.diarizer.state.withLock {
            $0.expectedSpeakerCounts.count
        }

        try await harness.seedUsableVoiceProfile(embedding: [0, 1])
        let stamped = try await harness.pipeline.regenerate(meetingID: meeting.id)
        #expect(stamped.roomTreatment?.ownerStampedClusters == 1)
        #expect(harness.diarizer.state.withLock {
            $0.expectedSpeakerCounts.count
        } == callsAfterFirst)
        #expect(try await harness.segments(meeting.id).contains {
            $0.speakerLabel == TranscriptSegment.userLabel
        })

        try FileManager.default.removeItem(
            at: harness.database.paths.roomTreatmentURL(meeting.id))
        let disabled = try await harness.pipeline.regenerate(meetingID: meeting.id)
        #expect(disabled.roomTreatment?.gateVerdict == .room)
        #expect(disabled.roomTreatment?.stampsDisabledNoSystemCentroids == 1)
        #expect(disabled.roomTreatment?.roomGateInertNoSystemCentroids == 0)
        #expect(FileManager.default.fileExists(
            atPath: harness.database.paths.captureFactsURL(meeting.id).path))

        try FileManager.default.removeItem(
            at: harness.database.paths.roomTreatmentURL(meeting.id))
        try FileManager.default.removeItem(
            at: harness.database.paths.diarizationURL(meeting.id))
        let recovered = try await harness.pipeline.regenerate(meetingID: meeting.id)
        #expect(recovered.roomTreatment?.ownerStampedClusters == 1)
        #expect(recovered.roomTreatment?.stampsDisabledNoSystemCentroids == 0)
        #expect(FileManager.default.fileExists(
            atPath: harness.database.paths.captureFactsURL(meeting.id).path))
    }

    @Test("missing room artifact makes a gate row inert")
    func gateRowDeletionIsInert() async throws {
        let harness = try await makePipelineHarness()
        try await harness.seedUsableVoiceProfile()
        let meeting = try await harness.plantCapturedMeeting(
            tracks: [.system, .mic], captureFacts: gateFacts, encodeTracks: false)
        _ = try await harness.pipeline.processCaptured(meetingID: meeting.id)
        try FileManager.default.removeItem(
            at: harness.database.paths.roomTreatmentURL(meeting.id))

        let record = try await harness.pipeline.regenerate(meetingID: meeting.id)
        #expect(record.roomTreatment?.gateVerdict == .solo)
        #expect(record.roomTreatment?.roomGateInertNoSystemCentroids == 1)
        #expect(record.roomTreatment?.stampsDisabledNoSystemCentroids == 0)
    }

    @Test("rename suppresses a recomputed owner stamp without double counting")
    func renameOutranksStamp() async throws {
        let harness = try await makePipelineHarness()
        try await harness.seedUsableVoiceProfile(embedding: [0, 1])
        let meeting = try await harness.plantCapturedMeeting(
            tracks: [.system, .mic], source: .inPerson,
            captureFacts: explicitRoomFacts, encodeTracks: false)
        _ = try await harness.pipeline.processCaptured(meetingID: meeting.id)
        let room = try artifact(harness, meeting.id)
        try await harness.database.pool.write { db in
            try SpeakerRenameStore.upsert(
                db, meetingID: meeting.id, speakerLabel: "M0",
                name: "Dana Okonkwo", diarization: room.micDiarization,
                now: msDate(), ownerIdentitySet: .empty)
        }

        let record = try await harness.pipeline.regenerate(meetingID: meeting.id)
        #expect(record.roomTreatment?.stampsSuppressedByRename == 1)
        #expect(record.roomTreatment?.ownerStampedClusters == 0)
        #expect(try await harness.segments(meeting.id).contains {
            $0.speakerLabel == "M0" && $0.speakerName == "Dana Okonkwo"
        })
    }

    @Test("mic diarization failure degrades to solo and composes the explicit-room note")
    func micFailureComposition() async throws {
        let harness = try await makePipelineHarness()
        harness.diarizer.state.withLock {
            $0.micError = .permanent("mic clustering unavailable")
        }
        harness.notesPrimary.state.withLock {
            $0.error = .permanent(EngineFallbackReason.inputTooLong)
        }
        let meeting = try await harness.plantCapturedMeeting(
            tracks: [.system, .mic], source: .inPerson,
            captureFacts: explicitRoomFacts, encodeTracks: false)

        let record = try await harness.pipeline.processCaptured(meetingID: meeting.id)
        let stored = try #require(try await harness.meeting(meeting.id))
        #expect(record.roomTreatment?.micDiarizeFailed == 1)
        #expect(record.roomTreatment?.gateVerdict == .solo)
        #expect(record.fallback != nil)
        #expect(
            stored.processingNote
                == "in-person treatment unavailable: speaker separation failed; fallback: \(EngineFallbackReason.inputTooLong)")
        #expect(!FileManager.default.fileExists(
            atPath: harness.database.paths.roomTreatmentURL(meeting.id).path))
    }

    @Test("capture-recovery note outranks explicit-room degradation")
    func captureRecoveryNotePrecedence() async throws {
        let harness = try await makePipelineHarness()
        harness.diarizer.state.withLock {
            $0.micError = .permanent("mic clustering unavailable")
        }
        let recovery =
            "\(CaptureRecovery.notePrefix) system track audio damaged — transcript proceeds from the mic track"
        let meeting = try await harness.plantCapturedMeeting(
            tracks: [.mic], processingNote: recovery, source: .inPerson,
            captureFacts: explicitRoomFacts, encodeTracks: false)

        let record = try await harness.pipeline.processCaptured(meetingID: meeting.id)
        #expect(record.roomTreatment?.micDiarizeFailed == 1)
        #expect(try await harness.meeting(meeting.id)?.processingNote == recovery)
    }

    @Test("eligible gate-row harvest appends and regeneration upserts")
    func harvestAppendAndRegeneration() async throws {
        let harness = try await makePipelineHarness()
        harness.diarizer.state.withLock {
            $0.micOutput = DiarizationOutput(
                segments: [
                    DiarizedSegment(speakerLabel: "M0", startSeconds: 0, endSeconds: 65)
                ],
                speakerCount: 1)
            $0.micCentroids = ["M0": [1, 0]]
        }
        let meeting = try await harness.plantCapturedMeeting(
            tracks: [.system, .mic], captureFacts: gateFacts, encodeTracks: false)
        let first = try await harness.pipeline.processCaptured(meetingID: meeting.id)
        #expect(first.roomTreatment?.harvestAppended == 1)
        #expect(await harness.voiceProfileStore.status() == .collecting(1))

        let second = try await harness.pipeline.regenerate(meetingID: meeting.id)
        #expect(second.roomTreatment?.harvestAppended == 1)
        #expect(await harness.voiceProfileStore.status() == .collecting(1))
    }

    @Test("switching voice identification off reaches the store the pipeline runs against")
    func toggleOffOnTheSharedStore() async throws {
        let harness = try await makePipelineHarness()
        try await harness.seedUsableVoiceProfile(embedding: [0, 1])
        let meeting = try await harness.plantCapturedMeeting(
            tracks: [.system, .mic], source: .inPerson,
            captureFacts: explicitRoomFacts, encodeTracks: false)
        let stamped = try await harness.pipeline.processCaptured(meetingID: meeting.id)
        #expect(stamped.roomTreatment?.ownerStampedClusters == 1)

        // A harvest token taken BEFORE the flip must not survive it.
        let pending = try #require(await harness.voiceProfileStore.pendingAppend())
        try await VoiceIdentificationSettings.apply(
            enabled: false, to: harness.voiceProfileStore)

        #expect(!FileManager.default.fileExists(
            atPath: harness.database.paths.voiceProfileDirectory.path))
        let candidate = VoiceProfileCandidate(
            meetingID: "01J00000000000000000000009",
            meetingDate: msDate(),
            modelID: FluidAudioDiarizer.diarizerID,
            embedding: [0, 1],
            speechSeconds: 90,
            language: "en")
        #expect(
            try await harness.voiceProfileStore.append(candidate, pending: pending)
                == .invalidated)

        let unstamped = try await harness.pipeline.regenerate(meetingID: meeting.id)
        #expect(unstamped.roomTreatment?.gateVerdict == .room)
        #expect(unstamped.roomTreatment?.ownerStampedClusters == 0)
        #expect(unstamped.roomTreatment?.harvestAppended == 0)
    }

    @Test("run record exposes counters without treatment evidence vectors")
    func runRecordPrivacy() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.plantCapturedMeeting(
            tracks: [.system, .mic], source: .inPerson,
            captureFacts: explicitRoomFacts, encodeTracks: false)
        let record = try await harness.pipeline.processCaptured(meetingID: meeting.id)
        let text = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        #expect(text.contains("\"roomTreatment\""))
        #expect(!text.contains("clusterCentroids"))
        #expect(!text.contains("gateEvidence"))
        #expect(!text.contains("embedding"))
    }

    @Test("capture-facts recovery is counted without exposing recovery evidence")
    func captureFactsRecoveryCounter() async throws {
        let harness = try await makePipelineHarness()
        let meeting = try await harness.plantCapturedMeeting(
            tracks: [.system, .mic], source: .inPerson, encodeTracks: false)
        try Data("{not-json".utf8).write(
            to: harness.database.paths.captureFactsURL(meeting.id), options: .atomic)

        let record = try await harness.pipeline.processCaptured(meetingID: meeting.id)
        #expect(record.roomTreatment?.captureFactsWriteFailed == 1)
        #expect(FileManager.default.fileExists(
            atPath: harness.database.paths.captureFactsURL(meeting.id).path))
    }

    @Test("rename re-mint grounds live M labels even without the room artifact")
    func renameRemintWithoutArtifact() async throws {
        let harness = try await makePipelineHarness()
        harness.asr.state.withLock {
            $0.micSegments = [
                ASRSegment(startSeconds: 0, endSeconds: 0.9, text: "First update."),
                ASRSegment(startSeconds: 1, endSeconds: 1.9, text: "Second update."),
            ]
        }
        harness.diarizer.state.withLock {
            $0.micOutput = DiarizationOutput(
                segments: [
                    DiarizedSegment(speakerLabel: "M0", startSeconds: 0, endSeconds: 0.95),
                    DiarizedSegment(speakerLabel: "M1", startSeconds: 0.98, endSeconds: 2),
                ],
                speakerCount: 2)
            $0.micCentroids = ["M0": [1, 0], "M1": [0, 1]]
        }
        let meeting = try await harness.plantCapturedMeeting(
            tracks: [.system, .mic], source: .inPerson,
            captureFacts: explicitRoomFacts, encodeTracks: false)
        _ = try await harness.pipeline.processCaptured(meetingID: meeting.id)

        var notes = try #require(
            try await NotesRepository(database: harness.database)
                .fetch(meetingID: meeting.id))
        notes.structured.summary = "M1 Max presented; M4 Max remained on the desk."
        notes.markdown = try NotesRenderer.render(
            notes.structured, language: notes.language, meetingTitle: meeting.title)
        try await NotesRepository(database: harness.database).upsert(notes)
        try FileManager.default.removeItem(
            at: harness.database.paths.roomTreatmentURL(meeting.id))

        _ = try await harness.pipeline.renameSpeaker(
            meetingID: meeting.id, speakerLabel: "M1", to: "Dana Okonkwo")
        let reminted = try #require(
            try await NotesRepository(database: harness.database)
                .fetch(meetingID: meeting.id))
        #expect(!reminted.structured.summary.contains("M1 Max"))
        #expect(reminted.structured.summary.contains("M4 Max"))
    }

    /// The artifact-PRESENT variant: the rename row stays non-stale, so the
    /// re-mint's label map RESOLVES M1 to a name. A resolved live M label must
    /// be substituted by layer 1 — layer 2 excludes it by construction, so a
    /// layer-1 miss ships the raw label to the reader.
    @Test("rename re-mint substitutes a resolved live M label with the artifact present")
    func renameRemintSubstitutesResolvedMicLabel() async throws {
        let harness = try await makePipelineHarness()
        harness.asr.state.withLock {
            $0.micSegments = [
                ASRSegment(startSeconds: 0, endSeconds: 0.9, text: "First update."),
                ASRSegment(startSeconds: 1, endSeconds: 1.9, text: "Second update."),
            ]
        }
        harness.diarizer.state.withLock {
            $0.micOutput = DiarizationOutput(
                segments: [
                    DiarizedSegment(speakerLabel: "M0", startSeconds: 0, endSeconds: 0.95),
                    DiarizedSegment(speakerLabel: "M1", startSeconds: 0.98, endSeconds: 2),
                ],
                speakerCount: 2)
            $0.micCentroids = ["M0": [1, 0], "M1": [0, 1]]
        }
        let meeting = try await harness.plantCapturedMeeting(
            tracks: [.system, .mic], source: .inPerson,
            captureFacts: explicitRoomFacts, encodeTracks: false)
        _ = try await harness.pipeline.processCaptured(meetingID: meeting.id)

        var notes = try #require(
            try await NotesRepository(database: harness.database)
                .fetch(meetingID: meeting.id))
        notes.structured.summary = "M1 presented; M4 Max remained on the desk."
        notes.structured.detailedNotes = "**M1** owns the Quoll Harbor rollout."
        notes.markdown = try NotesRenderer.render(
            notes.structured, language: notes.language, meetingTitle: meeting.title)
        try await NotesRepository(database: harness.database).upsert(notes)

        _ = try await harness.pipeline.renameSpeaker(
            meetingID: meeting.id, speakerLabel: "M1", to: "Dana Okonkwo")
        let rename = try #require(
            try await harness.database.pool.read { db in
                try SpeakerRenameStore.all(db, meetingID: meeting.id)
                    .first { $0.speakerLabel == "M1" }
            })
        #expect(!rename.stale, "the artifact is present, so the row must not be stale")

        let reminted = try #require(
            try await NotesRepository(database: harness.database)
                .fetch(meetingID: meeting.id))
        #expect(reminted.structured.summary.hasPrefix("Dana Okonkwo presented;"))
        #expect(reminted.structured.summary.contains("M4 Max"))
        #expect(reminted.structured.detailedNotes.contains("**Dana Okonkwo** owns"))
        #expect(
            !SLabelNeutralizer.containsLabel(
                reminted.structured.summary, groundedMLabels: ["M0", "M1"]))
        #expect(
            !SLabelNeutralizer.containsLabel(
                reminted.structured.detailedNotes, groundedMLabels: ["M0", "M1"]))
    }

    /// §4.1 row 1 in fact, not just in name: an attendee list that resolves to
    /// zero others must leave the mic clusterer unconstrained. A bound of 1
    /// collapses the whole room into one cluster and stamps it `user`.
    @Test("a ROOM row whose attendee list yields no others passes nil to the mic diarizer")
    func roomRowDegenerateAttendeeCountIsUnconstrained() async throws {
        let harness = try await makePipelineHarness()
        func counts() -> [Int?] { harness.diarizer.state.withLock { $0.expectedSpeakerCounts } }
        // A calendar list that carries only the user: the counting rule
        // subtracts him, leaving zero others.
        let userOnlyCalendar = [
            Attendee(name: "Sam Rivera", email: "sam.rivera@vexatron.test", source: .calendar)
        ]
        let degenerate = try await harness.plantCapturedMeeting(
            tracks: [.system, .mic], attendees: userOnlyCalendar,
            source: .inPerson, captureFacts: explicitRoomFacts, encodeTracks: false)
        _ = try await harness.pipeline.processCaptured(meetingID: degenerate.id)
        #expect(counts() == [nil, nil])

        // Control: a second calendar attendee makes the estimate real again.
        let twoUp = try await harness.plantCapturedMeeting(
            tracks: [.system, .mic],
            attendees: userOnlyCalendar
                + [Attendee(name: "Dana Okonkwo", email: nil, source: .calendar)],
            source: .inPerson, captureFacts: explicitRoomFacts, encodeTracks: false)
        _ = try await harness.pipeline.processCaptured(meetingID: twoUp.id)
        #expect(counts() == [nil, nil, 1, 2])
    }
}
