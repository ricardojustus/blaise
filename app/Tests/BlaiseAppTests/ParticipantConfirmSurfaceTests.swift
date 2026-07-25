import BlaiseCore
import Foundation
import Testing

@testable import BlaiseApp

// G15 §2a/§3 — the app-layer half of the participant confirmation: WHICH surface
// an ask may use, and what the sheet does with an answer the pipeline refused.
// Both are pure decisions, pinned headlessly here (no scene, no window).

@MainActor
struct ParticipantConfirmSurfaceTests {

    private func meeting(_ id: MeetingID, _ title: String) -> Meeting {
        let now = Date(timeIntervalSince1970: 1_000_000)
        return Meeting(
            id: id, title: title, startedAt: now, source: .meet, status: .processing,
            createdAt: now, updatedAt: now)
    }

    /// R3-F4: two run-entry asks race. Meeting A's sheet is on screen; B's ask
    /// arrives while it stands. The sheet captured A at init, so writing B into
    /// `participantConfirmMeeting` would leave the standing sheet answering A
    /// and lose B's question entirely — the pipeline latch already counts B as
    /// asked, so its park posts nothing either. B therefore takes the
    /// NOTIFICATION path, the designed surface for "the sheet cannot be shown
    /// now". The first two cases are the control: with no sheet standing, a
    /// frontmost Blaise still gets the sheet.
    @Test func aSecondAskTakesTheNotificationPathWhileTheFirstSheetStands() {
        let a = meeting("01AAA", "First meeting")
        let uiState = AppUIState()

        #expect(
            AppEnvironment.participantAskSurface(
                appIsActive: true, sheetPresenting: uiState.participantConfirmMeeting?.id)
                == .sheet,
            "nothing is presented: A gets the sheet")
        uiState.participantConfirmMeeting = a

        #expect(
            AppEnvironment.participantAskSurface(
                appIsActive: true, sheetPresenting: uiState.participantConfirmMeeting?.id)
                == .notification,
            "B must not overwrite the sheet A is being answered in")
        #expect(
            uiState.participantConfirmMeeting?.id == a.id,
            "A is still the meeting the standing sheet answers")
        #expect(
            AppEnvironment.participantAskSurface(appIsActive: false, sheetPresenting: nil)
                == .notification,
            "not frontmost is the other notification case (unchanged)")
    }

    /// R3-F3: after the opt-in auto-skip minted the notes, both sheet buttons
    /// are refused by the pipeline (G15 §3 refuses a post-notes confirmation).
    /// That refusal is not retryable, so the sheet states the real reason and
    /// closes instead of showing a "Try again." the user can never satisfy.
    /// Every other refusal keeps the retry message and the sheet open.
    @Test func aRefusalAgainstAlreadyWrittenNotesDismissesWithTheHonestReason() {
        let retry = "Couldn't skip right now. Try again."

        #expect(
            ParticipantConfirmModel.outcome(
                succeeded: true, notesAlreadyWritten: false, retry: retry)
                == .init(dismiss: true, message: nil))
        #expect(
            ParticipantConfirmModel.outcome(
                succeeded: false, notesAlreadyWritten: true, retry: retry)
                == .init(dismiss: true, message: "Notes were generated without attendees."))
        #expect(
            ParticipantConfirmModel.outcome(
                succeeded: false, notesAlreadyWritten: false, retry: retry)
                == .init(dismiss: false, message: retry),
            "a refusal that IS retryable keeps the sheet open, and Cancel is the exit")
    }

    /// R3-F3: the sheet has the dismissal control every other sheet in the app
    /// has. It was the only modal in Blaise without one, which is what turned a
    /// pair of refused buttons into a stuck sheet. Grepped, because a headless
    /// test cannot press an Escape key.
    @Test func theConfirmSheetHasADismissalControl() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // BlaiseAppTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // app
            .appendingPathComponent("Sources/BlaiseApp/ParticipantConfirmFlow.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        #expect(text.contains("Button(\"Cancel\")"))
        #expect(text.contains(".keyboardShortcut(.cancelAction)"))
    }
}
