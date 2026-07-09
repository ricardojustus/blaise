import Foundation
import Testing

@testable import BlaiseCore

// Regression: the `claude -p` (Account) notes path has NO server-side json_schema
// enforcement, so the model can emit a free-text phrase in the `meeting_type` ENUM
// field. The notes decode must tolerate that (unknown value -> nil) instead of
// failing the ENTIRE notes. Valid values still map to their case (no-op for the
// schema-enforced API/MLX engines). FICTIONAL data only.
@Suite struct NotesMeetingTypeLeniencyTests {
    private func notesJSON(meetingType: String) -> Data {
        Data(
            """
            {"title":"T","summary":"S","meeting_type":"\(meetingType)","detailed_notes":"N",
             "decisions":[],"action_items":[],"user_action_items":[],"speaker_name_mapping":[]}
            """.utf8)
    }

    @Test func invalidMeetingTypeDecodesToNilNotThrow() throws {
        // The exact value that broke the Account engine in the field.
        let resp = try NotesEngineResponse.decode(
            from: notesJSON(meetingType: "Revisão interna de pitch / apresentação de produto"))
        let (structured, _) = resp.toNotes()
        // Unrecognized free-text value -> `.general` (never throws / fails the notes).
        #expect(structured.meetingType == .general)
        #expect(structured.summary == "S")
    }

    @Test func validMeetingTypeStillMaps() throws {
        let resp = try NotesEngineResponse.decode(from: notesJSON(meetingType: "project_review"))
        let (structured, _) = resp.toNotes()
        #expect(structured.meetingType == .projectReview)
    }

    @Test func detailedNotesArrayIsCoercedToString() throws {
        // The model emitted detailed_notes as an ARRAY (the second prod failure).
        let json = """
            {"title":"T","summary":"S","meeting_type":"general",
             "detailed_notes":["line one","line two"],
             "decisions":[],"action_items":[],"user_action_items":[],"speaker_name_mapping":[]}
            """
        let resp = try NotesEngineResponse.decode(
            from: Data(ClaudeCodeSummarizationEngine.coerceNotesJSON(json).utf8))
        let (structured, _) = resp.toNotes()
        #expect(structured.detailedNotes.contains("line one"))
        #expect(structured.detailedNotes.contains("line two"))
    }

    @Test func looseActionItemAndBadConfidenceCoerced() throws {
        let json = """
            {"title":"T","summary":"S","meeting_type":"general","detailed_notes":"N",
             "decisions":["d"],"action_items":["just a string task"],"user_action_items":[],
             "speaker_name_mapping":[{"label":"S0","name":"Dana","confidence":"VERY HIGH","evidence":"x"}]}
            """
        let resp = try NotesEngineResponse.decode(
            from: Data(ClaudeCodeSummarizationEngine.coerceNotesJSON(json).utf8))
        let (structured, mapping) = resp.toNotes()
        #expect(structured.actionItems.first?.text == "just a string task")
        #expect(!mapping.isEmpty)  // invalid confidence coerced to low, didn't throw
    }
}
