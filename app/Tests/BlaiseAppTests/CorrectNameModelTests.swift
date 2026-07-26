import Foundation
import Testing
@testable import BlaiseApp
import BlaiseCore

// Fix 0 §5 T9 UI-model pins. The model is driven with pure correction and
// Remember handlers so these tests can observe the UI contract without a
// database write or a SwiftUI scene.

@MainActor
private final class RememberCorrectionStoreSpy {
    private(set) var writeCount = 0

    func write(
        _: String, _: String, _: MeetingID?
    ) async throws -> NameCorrectionStore.WriteResult {
        writeCount += 1
        return .written(replacement: "Dana Quoll")
    }
}

@MainActor
private func makeCorrectNameModel(
    structured: NotesStructured,
    correctionHandler: ((MeetingID, String, String, Bool, Int?) async -> Int)? = nil,
    rememberHandler:
        ((String, String, MeetingID?) async throws -> NameCorrectionStore.WriteResult)? = nil
) -> CorrectNameModel {
    let meeting = Meeting(
        id: ULID.generate(), title: "Meeting", startedAt: Date(timeIntervalSince1970: 0),
        source: .meet, status: .ready, createdAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 0))
    let notes = MeetingNotes(
        meetingID: meeting.id, markdown: "", structured: structured, language: "en",
        generatedAt: Date(timeIntervalSince1970: 0),
        provenance: NotesProvenance(engine: "fixture", model: "fixture", pipelineVersion: "fixture"))
    return CorrectNameModel(
        meeting: meeting, notes: notes, database: nil, pipeline: nil,
        correctionHandler: correctionHandler, rememberHandler: rememberHandler)
}

@MainActor
struct CorrectNameModelTests {
    @Test func T9_uiCountsUseIdentityAndGuardedDomains() {
        let model = makeCorrectNameModel(structured: NotesStructured(
            summary: "Dana Quoll met Dana.", detailedNotes: "Dana",
            decisions: [], actionItems: [], userActionItems: []))
        model.original = "Dana"
        model.replacement = "Dana Quoll"
        model.surfaceChanged()

        #expect(model.selectableOccurrenceCount == 3)
        #expect(model.replaceableCount == 2)
        #expect(model.canConfirm)
        #expect(model.supportsRemember)

        model.applyToAll = false
        model.selectedOccurrence = 0
        #expect(model.canConfirm, "a guard-covered selection remains selectable")
        #expect(model.selectedOccurrenceClassification == .alreadyCorrect)
        model.selectedOccurrence = 1
        #expect(model.selectedOccurrenceClassification == .replaceable)
        model.selectedOccurrence = 99
        #expect(model.selectedOccurrenceClassification == .absent)
    }

    @Test func T9_guardCoveredAndAbsentStatusesRemainDistinct() async {
        let model = makeCorrectNameModel(
            structured: NotesStructured(
                summary: "Dana Quoll.", detailedNotes: "",
                decisions: [], actionItems: [], userActionItems: []),
            correctionHandler: { _, _, _, _, _ in 0 })
        model.original = "Dana"
        model.replacement = "Dana Quoll"
        model.surfaceChanged()
        model.applyToAll = false

        model.selectedOccurrence = 0
        await model.confirm()
        #expect(model.statusMessage == "Already matches the correction.")

        model.statusMessage = nil
        model.selectedOccurrence = 7
        await model.confirm()
        #expect(model.statusMessage == "No matching name found in these notes.")
    }

    @Test func T9_zeroCountStatusDescribesTheCapturedRequestNotLiveState() async {
        // Impl-audit r2 High: a picker change DURING the await must not change
        // which occurrence the zero-count status describes.
        let gate = AsyncStream<Void>.makeStream()
        let model = makeCorrectNameModel(
            structured: NotesStructured(
                summary: "Dana Quoll met Dana.", detailedNotes: "",
                decisions: [], actionItems: [], userActionItems: []),
            correctionHandler: { _, _, _, _, _ in
                var iterator = gate.stream.makeAsyncIterator()
                _ = await iterator.next()
                return 0
            })
        model.original = "Dana"
        model.replacement = "Dana Quoll"
        model.surfaceChanged()
        model.applyToAll = false
        model.selectedOccurrence = 0  // guard-covered → .alreadyCorrect

        let confirmTask = Task { await model.confirm() }
        await Task.yield()
        model.selectedOccurrence = 1  // .replaceable — mutated mid-await
        gate.continuation.yield()
        gate.continuation.finish()
        await confirmTask.value

        #expect(model.statusMessage == "Already matches the correction.",
            "the status describes the submitted request, not the post-await picker state")
    }

    @Test func T9_multiWordRememberIsOperationallyDisabledAndNeverWritten() async {
        let spy = RememberCorrectionStoreSpy()
        let model = makeCorrectNameModel(
            structured: NotesStructured(
                summary: "Dana Del Rosso reviewed the plan.", detailedNotes: "",
                decisions: [], actionItems: [], userActionItems: []),
            correctionHandler: { _, _, _, _, _ in 1 },
            rememberHandler: { original, replacement, meetingID in
                try await spy.write(original, replacement, meetingID)
            })
        model.original = "Dana Del Rosso"
        model.replacement = "Dana Quoll"
        model.surfaceChanged()

        #expect(!model.supportsRemember)
        #expect(!model.remember, "unsupported transition forces the binding false")
        #expect(model.durabilityCopy ==
            "Durable corrections for multi-word names aren't supported yet — this fix applies to these notes only")
        #expect(model.rememberScopeCopy == nil)

        await model.confirm()
        #expect(spy.writeCount == 0, "multi-word confirmation never writes the store")
        #expect(model.statusMessage == "Fixed 1 in these notes only.")
    }
}
