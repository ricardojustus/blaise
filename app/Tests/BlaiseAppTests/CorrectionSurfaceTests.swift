import BlaiseCore
import Foundation
import Testing

@testable import BlaiseApp

// The two correction surfaces that are testable without rendering a SwiftUI
// scene: the entry gate around the CORRECTION path, and the top-menu command's
// action seam. The gate covers corrections only — a margin note is not an
// instruction and never touches synthesis, so it commits during a run
// (`NotesEditingEntryTests` and the core queue-behind-run pin cover that half).

@Suite struct CorrectionEntryGateTests {
    @Test("correction entry is offered only on a ready meeting with notes and nothing in flight")
    func entryGate() {
        #expect(correctionEntryEnabled(available: true, runActive: false, rewriteBusy: false))
    }

    @Test("a live run blocks new corrections — a row saved then would never reach that run's synthesis")
    func aLiveRunBlocksEntry() {
        #expect(!correctionEntryEnabled(available: true, runActive: true, rewriteBusy: false))
        #expect(!correctionEntryEnabled(available: true, runActive: false, rewriteBusy: true))
        #expect(!correctionEntryEnabled(available: true, runActive: true, rewriteBusy: true))
        // No notes / not ready: nothing to correct in the first place.
        #expect(!correctionEntryEnabled(available: false, runActive: false, rewriteBusy: false))
    }

    /// The window this gate exists to close: a composer opened BEFORE a run
    /// starts must not commit into a run that will ignore the row. The commit
    /// control consults the same predicate the affordance did, so the draft is
    /// kept and the commit closes for the run's duration.
    @Test("a composer opened before a run cannot commit while that run holds the meeting")
    func openBeforeRunCannotCommitDuringIt() {
        let atOpen = correctionEntryEnabled(available: true, runActive: false, rewriteBusy: false)
        #expect(atOpen, "the composer legitimately opened")
        let atCommit = correctionEntryEnabled(available: true, runActive: true, rewriteBusy: false)
        #expect(!atCommit)
        #expect(
            NotesEditingEntry.disabledReason(.correct, correctionEnabled: atCommit)?
                .contains("Updating notes") == true,
            "the reason for the closed commit control stays reachable")
        // The same run leaves the note path open.
        #expect(NotesEditingEntry.allowed(
            .note, correctionEnabled: atCommit, engineCanEditNotes: true))
    }
}

@MainActor
@Suite struct RewriteNotesCommandTests {
    /// The run record the pipeline would hand back. Its memberwise init is
    /// internal to BlaiseCore, so it is decoded from the wire shape here.
    private func record(notesPending: String? = nil) throws -> PipelineRunRecord {
        var fields: [String: Any] = [
            "meetingID": "01TESTMEETING0000000000000", "regeneration": true,
            "stageSeconds": [String: Double](), "asrSegmentCount": 0,
            "diarizationSegmentCount": 0, "speakerCount": 0, "mergeSplits": 0,
            "mergeDegenerateSegments": 0, "mergeGapAssignedWords": 0,
            "mergeHealedFragments": 0, "mergedSegmentCount": 0, "correctionCount": 0,
            "corrections": [Any](), "proposals": [Any](), "appliedNames": [String: String](),
            "namedSegmentCount": 0, "finalSegmentCount": 0, "groundedPersonHintCount": 0,
        ]
        if let notesPending { fields["notesPending"] = notesPending }
        let data = try JSONSerialization.data(withJSONObject: fields)
        return try JSONDecoder().decode(PipelineRunRecord.self, from: data)
    }

    @Test("the menu command routes the selected meeting to the pipeline rewrite")
    func routesToRewrite() async throws {
        let seen = SeenIDs()
        let message = await rewriteNotesCommandAction(
            selectedMeetingID: "01TESTMEETING0000000000000",
            rewrite: { id in
                seen.ids.append(id)
                return try record()
            })
        #expect(seen.ids == ["01TESTMEETING0000000000000"])
        #expect(message == nil, "a successful rewrite says nothing")
    }

    @Test("no selection is a no-op — the command never guesses a meeting")
    func noSelectionDoesNothing() async {
        let seen = SeenIDs()
        let message = await rewriteNotesCommandAction(
            selectedMeetingID: nil,
            rewrite: { id in
                seen.ids.append(id)
                return nil
            })
        #expect(seen.ids.isEmpty)
        #expect(message == nil)
    }

    @Test("a refused or parked rewrite is reported, never silently swallowed")
    func refusalAndParkAreReported() async throws {
        let refused = await rewriteNotesCommandAction(
            selectedMeetingID: "01TESTMEETING0000000000000", rewrite: { _ in nil })
        #expect(refused == "The notes could not be re-written because the meeting is not ready.")
        #expect(refused?.contains("Correction saved") == false)
        #expect(refused?.contains("Regenerate") == false)

        let parked = await rewriteNotesCommandAction(
            selectedMeetingID: "01TESTMEETING0000000000000",
            rewrite: { _ in try record(notesPending: "notes-pending: no engine") })
        #expect(parked?.contains("waiting on the notes engine") == true)
        #expect(parked?.contains("Rewrite notes now") == false)
        #expect(parked?.contains("Send to Notes Editor") == false)
        #expect(parked?.contains("Correction saved") == false)
        #expect(parked?.contains("Regenerate") == false)

        let failed = await rewriteNotesCommandAction(
            selectedMeetingID: "01TESTMEETING0000000000000",
            rewrite: { _ in throw TestRewriteFailure() })
        #expect(failed?.contains("Could not re-write the notes") == true)
    }
}

@MainActor
@Suite struct NotesEditorCorrectionActionTests {
    @Test("AC-12: correction submission saves once and starts no synthesis action")
    func submissionOnlySaves() async {
        var saves = 0
        let message = await saveUnderstandingCorrectionAction {
            saves += 1
        }
        #expect(saves == 1)
        #expect(message == nil)

        let failure = await saveUnderstandingCorrectionAction {
            throw TestRewriteFailure()
        }
        #expect(failure?.contains("Could not save the correction") == true)
        #expect(failure?.localizedCaseInsensitiveContains("apply") == false)
    }

    @Test("AC-12: the Changes-panel action routes to the notes-editor entry")
    func sendRoutesToEditor() async {
        let seen = SeenIDs()
        let message = await sendToNotesEditorAction(
            meetingID: "01TESTMEETING0000000000000",
            send: { seen.ids.append($0) })
        #expect(seen.ids == ["01TESTMEETING0000000000000"])
        #expect(message == nil)
    }

    @Test("AC-12: retired synthesis copy and trigger do not survive in app sources")
    func sourceTripwires() throws {
        let thisFile = URL(fileURLWithPath: #filePath)
        let appRoot = thisFile.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let sources = appRoot.appendingPathComponent("Sources", isDirectory: true)
        let enumerator = try #require(FileManager.default.enumerator(
            at: sources, includingPropertiesForKeys: nil))
        var allSource = ""
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            allSource += try String(contentsOf: file, encoding: .utf8)
        }
        #expect(!allSource.contains("Rewrite notes now"))
        #expect(!allSource.contains("Rewriting"))

        let detail = try String(
            contentsOf: sources.appendingPathComponent("BlaiseApp/MeetingDetailView.swift"),
            encoding: .utf8)
        let submitStart = try #require(detail.range(of: "private func submitCorrection"))
        let submitTail = detail[submitStart.lowerBound...]
        let submitEnd = try #require(submitTail.range(of: "/// Margin note"))
        let submitBody = submitTail[..<submitEnd.lowerBound]
        #expect(submitBody.contains("pipeline.addCorrection"))
        #expect(!submitBody.contains("pipeline.rewriteNotes"))
        #expect(!submitBody.contains("generateNotes"))
        #expect(!submitBody.contains("generateDigest"))

        let sendStart = try #require(detail.range(of: "private func sendToNotesEditorNow"))
        let sendTail = detail[sendStart.lowerBound...]
        let sendEnd = try #require(sendTail.range(of: "/// Marks/unmarks"))
        let sendBody = sendTail[..<sendEnd.lowerBound]
        #expect(sendBody.contains("pipeline.sendPendingNotesToEditor"))
        #expect(!sendBody.contains("pipeline.rewriteNotes"))
    }
}

private struct TestRewriteFailure: Error {}

/// Records the meeting ids the seam handed to the rewrite closure.
@MainActor
private final class SeenIDs {
    var ids: [MeetingID] = []
}
