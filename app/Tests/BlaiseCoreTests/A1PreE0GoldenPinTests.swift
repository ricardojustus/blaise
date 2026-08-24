import CryptoKit
import Foundation
import Testing

@testable import BlaiseCore

// A1's oracle: with zero correction rows the renderer output and the synthesis
// user message must be byte-identical to what they were BEFORE the corrections
// port. The expected hashes below were minted by running these exact fixtures
// against commit 5788181 (the port's base) in a throwaway worktree, so a drift
// in any pre-existing rendering or prompt byte fails here — a self-comparison
// of the current implementation cannot.
//
// A failure means one of two things: the E0 surface leaked into the zero-row
// path (a defect), or pre-E0 output was deliberately changed (re-mint the pin
// from the new base and say so in the commit).

private func sha256Hex(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// Prose + decisions + generated and user action items, EN.
private let richStructured = NotesStructured(
    title: "Quarterly planning",
    summary: "The team agreed to evaluate the new capture stack before committing.",
    detailedNotes: """
        The first paragraph covers the capture stack and its known limits.

        A second paragraph discusses the budget: US$ 12,000.00 for the pilot.
        """,
    decisions: ["Pilot runs for one quarter", "No vendor lock-in before the review"],
    actionItems: [
        ActionItem(owner: "Marco", text: "Benchmark the capture stack"),
        ActionItem(owner: "", text: "Circulate the pilot scope"),
    ],
    userActionItems: [ActionItem(owner: "Sam", text: "Approve the pilot budget")])

/// The same shapes in Portuguese.
private let richStructuredPT = NotesStructured(
    title: "Planejamento trimestral",
    summary: "A equipe decidiu avaliar a nova captura antes de fechar contrato.",
    detailedNotes: """
        O primeiro parágrafo trata da captura e dos seus limites.

        O segundo parágrafo trata do orçamento: R$ 60.000,00 para o piloto.
        """,
    decisions: ["O piloto dura um trimestre"],
    actionItems: [ActionItem(owner: "Anna", text: "Medir a captura")],
    userActionItems: [ActionItem(owner: "Sam", text: "Aprovar o orçamento")])

/// Every optional section empty (the empty-marker branches) and no title.
private let emptySectionsStructured = NotesStructured(
    summary: "A short call with nothing decided.",
    detailedNotes: "",
    decisions: [],
    actionItems: [],
    userActionItems: [])

/// A fenced block and a 4-space indented block inside the detailed notes.
private let fencedStructured = NotesStructured(
    title: "Debugging session",
    summary: "We traced the retry loop.",
    detailedNotes: """
        The failing call looks like this:

        ```swift
        let result = try await client.send(request)

        print(result)
        ```

        And the indented variant:

            let retries = 3
            perform(retries)

        Both reproduce the loop.
        """,
    decisions: ["Cap the retries at three"],
    actionItems: [ActionItem(owner: "Kobi", text: "Add the cap")],
    userActionItems: [])

private func makePinnedRequest(
    language: String, title: String, vocabulary: [String]
) -> NotesRequest {
    NotesRequest(
        meeting: Meeting(
            id: "01TESTMEETING0000000000000",
            title: title,
            // 2026-03-20 09:46 UTC — the fixed instant the pre-E0 prompt
            // goldens use, so the DD/MM/YYYY line is stable.
            startedAt: Date(timeIntervalSince1970: 1_774_000_000),
            source: .meet,
            status: .processing,
            attendees: [
                Attendee(name: "Sam", email: "sam.rivera@vexatron.test", source: .calendar),
                Attendee(name: "Tobias", email: "tobias@vexatron.test", source: .calendar),
            ],
            createdAt: Date(timeIntervalSince1970: 1_774_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_774_000_000)),
        transcript: [
            TranscriptSegment(
                meetingID: "01TESTMEETING0000000000000", ord: 0, startSeconds: 0, endSeconds: 5,
                speakerLabel: "S0", text: "Bom dia, vamos começar."),
            TranscriptSegment(
                meetingID: "01TESTMEETING0000000000000", ord: 1, startSeconds: 5, endSeconds: 9,
                speakerLabel: "S1", speakerName: "Tobias", text: "O orçamento é R$ 1.000,00."),
        ],
        dominantLanguage: language,
        vocabulary: vocabulary,
        user: UserIdentity(
            name: "Sam", aliases: ["Sam", "Sam Rivera"], email: "sam.rivera@vexatron.test"))
}

@Suite struct A1PreE0GoldenPinTests {
    @Test("zero-correction renderer output still hashes to the pre-E0 bytes")
    func rendererPins() throws {
        let cases: [(String, String, NotesStructured, String)] = [
            (
                "prose + decisions + both action-item lists (EN)", "en", richStructured,
                "3e8e121e9effa0fb389324eeea6a1d6401e5b9f730e31bd77f35328965ce1f9a"
            ),
            (
                "prose + decisions + both action-item lists (PT)", "pt", richStructuredPT,
                "d2596b8f8a630bc83a0e07a1bafd6aefd2ab44efe6c68771fe24863fb7ddb126"
            ),
            (
                "all optional sections empty", "en", emptySectionsStructured,
                "cf0bb6aa9fc25a2bf43e1956631c3163923e5ea8b10448097325143cb552a2e4"
            ),
            (
                "fenced and indented code blocks", "en", fencedStructured,
                "9fd17c36f2dca5bcb559021a53e823e05fe65faf5526f07c315c969237466101"
            ),
        ]
        for (label, language, structured, pin) in cases {
            let markdown = try NotesRenderer.render(
                structured, language: language, meetingTitle: "Sync", userName: "Sam")
            #expect(sha256Hex(markdown) == pin, "\(label): renderer bytes drifted from pre-E0")
        }
    }

    @Test("zero-correction synthesis user message still hashes to the pre-E0 bytes")
    func promptPins() {
        let pt = makePinnedRequest(
            language: "pt", title: "Reunião semanal Vexatron",
            vocabulary: ["Vexatron", "Tobias", "NVR 2"])
        #expect(
            sha256Hex(NotesPromptBuilder.userMessage(for: pt))
                == "e75a68cd6ba5fcb1fffba8835a1eaeb59b6e5ac3c4188cba3336c890bce32870",
            "PT prompt bytes drifted from pre-E0")
        let en = makePinnedRequest(language: "en", title: "Weekly sync", vocabulary: [])
        #expect(
            sha256Hex(NotesPromptBuilder.userMessage(for: en))
                == "3314bb18841b8f1ce7c035a16709df26423ca12bc825ac118b8cb5a92e30390a",
            "EN prompt bytes drifted from pre-E0")
    }
}
