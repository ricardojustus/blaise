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

    /// R3-F3 + R4-F4: after the opt-in auto-skip minted the notes, both sheet
    /// buttons are refused by the pipeline (G15 §3 refuses a post-notes
    /// confirmation). That refusal is not retryable, so the sheet states the
    /// real reason instead of a "Try again." the user can never satisfy — and
    /// it states it WHERE IT IS READ. Dismissing in the same turn the message
    /// was assigned removed the only view containing it before any render pass,
    /// so the terminal shape keeps the sheet open (`dismiss: false`,
    /// `terminal: true`) and Close is its whole control set. Every other
    /// refusal keeps the retry message and the sheet open.
    @Test func aRefusalAgainstAlreadyWrittenNotesShowsTheHonestReasonAndOffersClose() {
        let retry = "Couldn't skip right now. Try again."

        #expect(
            ParticipantConfirmModel.outcome(
                succeeded: true, notesAlreadyWritten: false, retry: retry)
                == .init(dismiss: true, message: nil, terminal: false))
        #expect(
            ParticipantConfirmModel.outcome(
                succeeded: false, notesAlreadyWritten: true, retry: retry)
                == .init(
                    dismiss: false, message: "Notes were generated without attendees.",
                    terminal: true),
            "the reason must survive the turn it is written in — no dismissal here")
        #expect(
            ParticipantConfirmModel.outcome(
                succeeded: false, notesAlreadyWritten: false, retry: retry)
                == .init(dismiss: false, message: retry, terminal: false),
            "a refusal that IS retryable keeps the sheet open, and Cancel is the exit")
    }

    /// R4-F4, the rendering half: the terminal state has an exit, and it is the
    /// ONLY control there — no Confirm/Skip to press into a refusal that cannot
    /// succeed. Grepped, because a headless test cannot press a button.
    @Test func theTerminalStateRendersItsReasonWithASingleClose() throws {
        let text = try String(contentsOf: Self.flowSource, encoding: .utf8)
        #expect(text.contains("if model.terminal {"))
        #expect(text.contains("Button(\"Close\") { isPresented = false }"))
        let terminalBranch = try #require(text.range(of: "if model.terminal {"))
        let close = try #require(text.range(of: "Button(\"Close\")"))
        let elseBranch = try #require(text.range(of: "} else {", range: terminalBranch.upperBound ..< text.endIndex))
        #expect(
            close.lowerBound < elseBranch.lowerBound,
            "Close is the terminal branch's control; Confirm/Skip live in the other one")
    }

    /// R3-F3: the sheet has the dismissal control every other sheet in the app
    /// has. It was the only modal in Blaise without one, which is what turned a
    /// pair of refused buttons into a stuck sheet. Grepped, because a headless
    /// test cannot press an Escape key.
    @Test func theConfirmSheetHasADismissalControl() throws {
        let text = try String(contentsOf: Self.flowSource, encoding: .utf8)
        #expect(text.contains("Button(\"Cancel\")"))
        #expect(text.contains(".keyboardShortcut(.cancelAction)"))
    }

    private static let flowSource = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // BlaiseAppTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // app
        .appendingPathComponent("Sources/BlaiseApp/ParticipantConfirmFlow.swift")

    /// R4-F3: B's ask correctly took the notification path while A's sheet
    /// stood — and then the user CLICKS it. Installing B over the standing
    /// sheet is the same overwrite the ask rule exists to prevent (the
    /// presented sheet captured A at init, so the write retargets nothing the
    /// user can see, and answering A then clears B's state). The click
    /// therefore selects B, leaves A standing, and reports that B is owed its
    /// notification back — the surface the click consumed. Once A is dismissed,
    /// the same click presents B.
    @Test func clickingTheSecondAsksNotificationLeavesTheStandingSheetAlone() {
        let a = meeting("01AAA", "First meeting")
        let b = meeting("01BBB", "Second meeting")
        let uiState = AppUIState()
        uiState.participantConfirmMeeting = a

        #expect(
            AppEnvironment.routeParticipantConfirmClick(
                meetingID: b.id, meeting: b, uiState: uiState) == .deferredToStandingSheet,
            "B's click must not retarget the sheet A is being answered in")
        #expect(
            uiState.participantConfirmMeeting?.id == a.id,
            "A is still the meeting the standing sheet answers")
        #expect(uiState.selectedMeetingID == b.id, "B is selected: its row and banner are entries")

        // A is answered / dismissed; B's re-posted notification is clicked again.
        uiState.participantConfirmMeeting = nil
        #expect(
            AppEnvironment.routeParticipantConfirmClick(
                meetingID: b.id, meeting: b, uiState: uiState) == .presented)
        #expect(
            uiState.participantConfirmMeeting?.id == b.id,
            "with nothing standing, the click raises B's sheet — the question is not lost")
    }

    /// The control for the rule above: a click for the meeting whose sheet is
    /// ALREADY presented is not a deferral — it re-presents the same subject
    /// (the notification and the sheet name one question).
    @Test func clickingTheStandingSheetsOwnNotificationStillPresents() {
        let a = meeting("01AAA", "First meeting")
        let uiState = AppUIState()
        uiState.participantConfirmMeeting = a
        #expect(
            AppEnvironment.routeParticipantConfirmClick(
                meetingID: a.id, meeting: a, uiState: uiState) == .presented)
        #expect(uiState.participantConfirmMeeting?.id == a.id)
    }
}
