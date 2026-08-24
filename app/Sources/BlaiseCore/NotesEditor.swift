import Foundation

public enum NotesEditField: String, Sendable, Equatable, Codable {
    case title, summary
    case detailedNotes = "detailed_notes"
    case decisions
    case actionItems = "action_items"
    case userActionItems = "user_action_items"

    /// The family split §6's compatibility table is keyed on.
    public var isProse: Bool { self == .title || self == .summary || self == .detailedNotes }
}

/// Both members optional: the schema requires neither, and §6 merges only what is supplied.
public struct NotesItemPatch: Sendable, Equatable, Decodable {
    public var owner: String?
    public var text: String?
}

public struct NotesEditorInstruction: Sendable, Equatable {
    public var rowID: String          // host-only; never sent as authority
    public var section: MeetingCorrection.Section
    public var quotedText: String
    public var userText: String
}

public struct NotesEditorRequest: Sendable, Equatable {
    public var meetingID: MeetingID
    public var currentNotes: NotesStructured
    public var instructions: [NotesEditorInstruction]
}

public struct NotesEditorResult: Sendable, Equatable {
    public var operations: [NotesEditOperation]
    public var usage: EngineUsage?
}

public protocol NotesEditingEngine: Sendable {
    func editNotes(
        _ request: NotesEditorRequest,
        purpose: CloudSpendPurpose
    ) async throws -> NotesEditorResult
}

// MARK: - N4 digest editor seam

/// The digest-editor call's input: the STORED digest string plus the meeting's
/// complete active instruction set (every understanding row, any status,
/// chronological — the digest may still assert a claim corrected long before
/// the oldest pending row, so the reconcile needs the full set).
public struct DigestEditorRequest: Sendable, Equatable {
    public var meetingID: MeetingID
    public var currentDigest: String
    /// N2's instruction struct, reused unchanged — the digest prompt simply
    /// does not render the section clause (the digest has its own structure).
    public var instructions: [NotesEditorInstruction]

    public init(
        meetingID: MeetingID, currentDigest: String,
        instructions: [NotesEditorInstruction]
    ) {
        self.meetingID = meetingID
        self.currentDigest = currentDigest
        self.instructions = instructions
    }
}

/// One digest edit. ONE op kind suffices: the digest is a single markdown
/// string with no list fields and no index identity, and `replace: ""` erases.
public struct DigestEditOperation: Sendable, Equatable, Decodable {
    public var find: String
    public var replace: String
    public var instruction: Int

    public init(find: String, replace: String, instruction: Int) {
        self.find = find
        self.replace = replace
        self.instruction = instruction
    }
}

public struct DigestEditorResult: Sendable, Equatable {
    public var operations: [DigestEditOperation]
    public var usage: EngineUsage?

    public init(operations: [DigestEditOperation], usage: EngineUsage? = nil) {
        self.operations = operations
        self.usage = usage
    }
}

/// A SEPARATE protocol, not a `SummarizationEngine` requirement: the two cloud
/// engines adopt it and the local engine does not, which is what makes the
/// exclusion representable — the settle chain's availability check is a
/// conditional cast, and every existing path still runs locally.
public protocol DigestEditingEngine: Sendable {
    func editDigest(
        _ request: DigestEditorRequest,
        purpose: CloudSpendPurpose
    ) async throws -> DigestEditorResult
}

public enum NotesEditOperation: Sendable, Equatable, Decodable {
    case replace(field: NotesEditField, find: String, replace: String, instruction: Int)
    case set(field: NotesEditField, index: Int, patch: NotesItemPatch, instruction: Int)
    case remove(field: NotesEditField, index: Int, instruction: Int)
    case insert(field: NotesEditField, index: Int?, patch: NotesItemPatch, instruction: Int)
}

// MARK: - N4 digest-editor wire contract

/// The probe-validated prompt and the one-op schema both cloud adapters send.
/// The prompt adapts the notes-editor rules to a flat markdown surface: ops
/// only, verbatim anchors, negated predicates never survive, subject scoping,
/// erase-without-trace, newest-correction-wins, and the `md-v1` structure rules
/// (never invent a section; an emptied section goes with its header; surviving
/// headers are never renamed or reordered).
enum DigestEditorWireContract {
    static let systemPrompt = #"""
You are the digest editor for a meeting-notes app. You receive a meeting's
machine-facing memory digest — one Markdown document with fixed English "## " section
headers — and a numbered list of user corrections. The corrections are authoritative —
they override anything the digest currently says.

You do NOT retype the digest. Return ONLY a raw JSON object of the form
{"ops": [ ... ]} (no prose, no fences). Each operation is:

  {"find": "<verbatim existing text>", "replace": "<new text>", "instruction": N}

Rules:
1. "find" must be copied EXACTLY from the current digest, character for character. An
   op whose "find" does not occur in the digest does nothing.
2. Operations apply in the order you give them, each replacing EVERY occurrence of its
   "find" text; a later "find" matches against the digest AFTER every preceding
   operation has been applied.
3. Emit an operation for every place the corrections genuinely change, including
   places they change indirectly: a correction fixes its target AND every other line
   stating or implying the old, wrong version. Emit nothing for anything the
   corrections do not genuinely affect — untouched text is never retyped.
4. A predicate the correction explicitly negates never survives anywhere in the
   corrected text: when a correction says something did not happen, was not done, or
   was not X, no operation may leave that predicate asserted — about the original
   subject or anyone else — unless the correction itself states it.
5. A correction applies only where the digest states or implies the SAME fact about
   the SAME subject or project. An identically-worded sentence about a different
   subject or project is NOT affected — leave it untouched, and never emit an
   operation whose replace equals its find. When the digest's other sections tell you
   which line the correction concerns, use them.
6. Never invent content beyond what a correction requires.
7. When a correction withdraws a claim, the digest reads as if the claim never
   existed: remove the sentence or line entirely (a "replace" of "" erases; include
   the line's trailing newline in "find" when erasing a whole line). Never add
   sentences noting that something did not happen, was retracted, or was previously
   misstated.
8. Every operation carries "instruction": the 1-based number of the numbered user
   correction it serves. An operation serving more than one correction cites the
   first.
9. The corrections are in the order the user stated them, oldest first. Where two
   corrections contradict each other about the same fact, the HIGHER-NUMBERED one is
   what the user believes now: satisfy it, and emit nothing that would satisfy the one
   it overrides.
10. Never invent a new "## " section. When your edits erase the last content line of a
    section, remove that section entirely, header included — the digest omits empty
    sections. Never rename or reorder the surviving section headers, and never edit
    the header lines at the top of the digest except the values a correction
    genuinely changes. Content stays in its section and keeps the digest's language.
11. If your "find" would match text you must not change as well as text you must,
    lengthen it using text that ALREADY EXISTS immediately before or after the
    target, copied character for character. NEVER add, duplicate, move or re-order
    text to make an anchor unique. If no unique anchor exists, emit nothing for that
    correction.

Example — digest containing "- Ada owns the rig retrofit." and "- The board noted Ada
missed the retrofit demo." with the correction "It wasn't Ada who missed the demo — Bo
ran the retrofit, and the demo was postponed, not missed.":
{"ops": [{"find": "Ada owns the rig retrofit.",
          "replace": "Bo owns the rig retrofit.", "instruction": 1},
         {"find": "The board noted Ada missed the retrofit demo.",
          "replace": "The board noted the retrofit demo was postponed.", "instruction": 1}]}

OUTPUT CONTRACT (STRICT): respond with a SINGLE JSON object and NOTHING ELSE — no
markdown fences, no prose before or after. The object carries exactly one key, "ops",
whose value is an array of operations, each exactly
{"find": <string>, "replace": <string>, "instruction": <int>}. An empty "ops" array is
valid when nothing genuinely changes.
"""#

    /// `json.dumps(DIGEST_OP_SCHEMA)` from the probe, byte for byte.
    static let schemaJSON = #"{"type": "object", "properties": {"ops": {"type": "array", "items": {"type": "object", "properties": {"find": {"type": "string"}, "replace": {"type": "string"}, "instruction": {"type": "integer"}}, "required": ["find", "replace", "instruction"], "additionalProperties": false}}}, "required": ["ops"], "additionalProperties": false}"#

    /// The digest is one markdown string, so an instruction line carries no
    /// section clause and no occurrence clause — only the hardened quote the
    /// user selected and the hardened correction text, numbered 1-based in
    /// chronological order.
    static func userMessage(for request: DigestEditorRequest) -> String {
        let lines = request.instructions.enumerated().map { index, instruction in
            "\(index + 1). The user corrected the meeting record. The notes said: \"\(CorrectionSanitize.promptField(instruction.quotedText))\". The user corrects: \(CorrectionSanitize.promptField(instruction.userText))"
        }
        return "CURRENT DIGEST:\n\(request.currentDigest)\nCORRECTIONS:\n"
            + lines.joined(separator: "\n")
    }

    /// A response that does not decode WHOLLY is a failed attempt: no partial
    /// ops array is ever applied.
    static func decodeOperations(from data: Data) throws -> [DigestEditOperation] {
        try JSONDecoder().decode(DigestEditorResponseEnvelope.self, from: data).operations
    }
}

// MARK: - Normative wire contract

/// The measured v9 prompt and v6 schema used by both cloud adapters.
enum NotesEditorWireContract {
    static let editorPrompt = #"""
You are the notes editor for a meeting-notes app. You receive the meeting's current
notes as JSON and a numbered list of user instructions. The user's instructions are
authoritative — they override anything the notes currently say.

You do NOT retype the notes. Return ONLY a raw JSON object of the form
{"ops": [ ... ]} (no prose, no fences). Each operation names one top-level field:

  {"field": "<prose field>", "find": "<verbatim existing text>", "replace": "<new text>"}
  {"field": "<list field>", "index": N, "set": {"owner": "...", "text": "..."}}
  {"field": "<list field>", "remove_index": N}
  {"field": "<list field>", "insert": {"owner": "...", "text": "..."}}

Rules:
1. "find" must be copied EXACTLY from the current notes, character for character.
   An op whose "find" does not occur in its field does nothing.
2. Use find/replace on the prose fields (title, summary, detailed_notes) and the
   index ops on the list fields (decisions, action_items, user_action_items).
   Indices are 0-based.
3. Operations apply in the order you give them; an index refers to the list AFTER
   every preceding operation has been applied.
4. In "set", give only the keys you are changing. decisions items are plain
   strings: change one with {"text": "..."}.
5. Emit an operation for every place the instructions genuinely change, including
   the places they change indirectly: a correction fixes its target AND every
   other spot stating or implying the old, wrong version (summary mentions,
   decision lines, action-item owners). Emit nothing for anything the instructions
   do not genuinely affect — untouched text is never retyped.
6. A replacement instruction gives exact new text: use it verbatim.
7. A removal instruction: the claim or item disappears; do not paraphrase it back.
8. Never invent content beyond what an instruction requires.
9. When an instruction retracts or corrects a story, the corrected notes read as if
   the wrong version never existed. State the corrected facts only. Never add
   sentences noting that something did not happen, was retracted, or was previously
   misstated.
10. Every operation carries "instruction": the 1-based number of the numbered user
    instruction it serves. An operation serving more than one instruction cites the
    first.
11. The instructions are in the order the user stated them, oldest first. Where two
    instructions contradict each other about the same fact, the HIGHER-NUMBERED one
    is what the user believes now: satisfy it, and emit nothing that would satisfy
    the instruction it overrides.
12. An instruction may say which occurrence of the quoted text the user selected.
    When that quoted text appears more than once in its field, your "find" must match
    ONLY the selected occurrence. Lengthen it using text that ALREADY EXISTS in the
    field immediately before or after that occurrence, copied character for
    character. NEVER add, duplicate, move or re-order text in order to make an anchor
    unique, and never emit an operation whose purpose is to set up another operation:
    the only thing "replace" may change is the selected occurrence itself, and every
    other byte of the "find" must appear unchanged in the "replace". If no unique
    anchor exists, emit nothing for that instruction.

Example — notes {"summary": "Ada owns the rig.", "decisions": ["Ship on Friday"]}
with the instruction "The rig owner is Bo, not Ada; drop the Friday decision":
{"ops": [{"field": "summary", "find": "Ada owns the rig.", "replace": "Bo owns the rig."},
         {"field": "decisions", "remove_index": 0}]}

Valid fields: title, summary, detailed_notes, decisions, action_items,
user_action_items.
"""#

    static let outputContract = #"""
OUTPUT CONTRACT (STRICT): respond with a SINGLE JSON object and NOTHING ELSE — no
markdown fences, no prose before or after. The object carries exactly one key,
"ops", whose value is an array of edit operations. Each operation is exactly one
of these four shapes:

  {"field": <field>, "find": <string>, "replace": <string>}
  {"field": <field>, "index": <int>, "set": {"owner": ..., "text": ...}}
  {"field": <field>, "remove_index": <int>}
  {"field": <field>, "insert": {"owner": ..., "text": ...}}

An empty "ops" array is valid when nothing genuinely changes. "field" MUST be one
of: title, summary, detailed_notes, decisions, action_items, user_action_items.
"""#

    static let systemPrompt = editorPrompt + "\n\n" + outputContract

    /// `json.dumps(OP_SCHEMA)` from `run_probe_v6.py`, byte for byte.
    static let schemaJSON = #"{"type": "object", "properties": {"ops": {"type": "array", "items": {"anyOf": [{"type": "object", "properties": {"field": {"type": "string", "enum": ["action_items", "decisions", "detailed_notes", "summary", "title", "user_action_items"]}, "find": {"type": "string"}, "replace": {"type": "string"}, "instruction": {"type": "integer"}}, "required": ["field", "find", "replace", "instruction"], "additionalProperties": false}, {"type": "object", "properties": {"field": {"type": "string", "enum": ["action_items", "decisions", "detailed_notes", "summary", "title", "user_action_items"]}, "index": {"type": "integer"}, "set": {"type": "object", "properties": {"owner": {"type": "string"}, "text": {"type": "string"}}, "additionalProperties": false}, "instruction": {"type": "integer"}}, "required": ["field", "index", "set", "instruction"], "additionalProperties": false}, {"type": "object", "properties": {"field": {"type": "string", "enum": ["action_items", "decisions", "detailed_notes", "summary", "title", "user_action_items"]}, "remove_index": {"type": "integer"}, "instruction": {"type": "integer"}}, "required": ["field", "remove_index", "instruction"], "additionalProperties": false}, {"type": "object", "properties": {"field": {"type": "string", "enum": ["action_items", "decisions", "detailed_notes", "summary", "title", "user_action_items"]}, "index": {"type": "integer"}, "insert": {"type": "object", "properties": {"owner": {"type": "string"}, "text": {"type": "string"}}, "additionalProperties": false}, "instruction": {"type": "integer"}}, "required": ["field", "insert", "instruction"], "additionalProperties": false}]}}}, "required": ["ops"], "additionalProperties": false}"#

    static func userMessage(for request: NotesEditorRequest) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let notesJSON = String(
            decoding: try encoder.encode(request.currentNotes), as: UTF8.self)
        let instructionLines = request.instructions.enumerated().map { index, instruction in
            "\(index + 1). In the \(sectionLabel(instruction.section)), the current notes say: \"\(CorrectionSanitize.promptField(instruction.quotedText))\". The user corrects: \(CorrectionSanitize.promptField(instruction.userText))"
        }
        return "CURRENT NOTES:\n\(notesJSON)\nINSTRUCTIONS:\n"
            + instructionLines.joined(separator: "\n")
    }

    static func decodeOperations(from data: Data) throws -> [NotesEditOperation] {
        try JSONDecoder().decode(NotesEditorResponseEnvelope.self, from: data).operations
    }

    private static func sectionLabel(_ section: MeetingCorrection.Section) -> String {
        switch section {
        case .summary: return "summary"
        case .detailedNotes: return "detailed notes"
        case .decision: return "decisions"
        case .actionItem: return "action items"
        case .userActionItem: return "your action items"
        }
    }
}

// MARK: - Strict response decoding

private struct NotesEditorCodingKey: CodingKey, Hashable {
    var stringValue: String
    var intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

private func notesEditorDataCorrupted(
    _ decoder: Decoder, _ description: String
) -> DecodingError {
    .dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: description))
}

extension NotesItemPatch {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: NotesEditorCodingKey.self)
        let keys = Set(container.allKeys.map(\.stringValue))
        guard keys.isSubset(of: ["owner", "text"]) else {
            throw notesEditorDataCorrupted(decoder, "item patch carried an unknown property")
        }
        let ownerKey = NotesEditorCodingKey("owner")
        let textKey = NotesEditorCodingKey("text")
        owner = container.contains(ownerKey) ? try container.decode(String.self, forKey: ownerKey) : nil
        text = container.contains(textKey) ? try container.decode(String.self, forKey: textKey) : nil
    }
}

extension NotesEditOperation {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: NotesEditorCodingKey.self)
        let keys = Set(container.allKeys.map(\.stringValue))
        let operationKeys = ["find", "set", "remove_index", "insert"].filter(keys.contains)
        guard operationKeys.count == 1 else {
            throw notesEditorDataCorrupted(
                decoder, "operation must carry exactly one operation discriminator")
        }

        let fieldKey = NotesEditorCodingKey("field")
        let instructionKey = NotesEditorCodingKey("instruction")
        let field = try container.decode(NotesEditField.self, forKey: fieldKey)
        let instruction = try container.decode(Int.self, forKey: instructionKey)

        switch operationKeys[0] {
        case "find":
            let allowed: Set<String> = ["field", "find", "replace", "instruction"]
            guard keys == allowed else {
                throw notesEditorDataCorrupted(decoder, "replace operation has the wrong properties")
            }
            self = .replace(
                field: field,
                find: try container.decode(String.self, forKey: NotesEditorCodingKey("find")),
                replace: try container.decode(String.self, forKey: NotesEditorCodingKey("replace")),
                instruction: instruction)
        case "set":
            let allowed: Set<String> = ["field", "index", "set", "instruction"]
            guard keys == allowed else {
                throw notesEditorDataCorrupted(decoder, "set operation has the wrong properties")
            }
            self = .set(
                field: field,
                index: try container.decode(Int.self, forKey: NotesEditorCodingKey("index")),
                patch: try container.decode(NotesItemPatch.self, forKey: NotesEditorCodingKey("set")),
                instruction: instruction)
        case "remove_index":
            let allowed: Set<String> = ["field", "remove_index", "instruction"]
            guard keys == allowed else {
                throw notesEditorDataCorrupted(decoder, "remove operation has the wrong properties")
            }
            self = .remove(
                field: field,
                index: try container.decode(Int.self, forKey: NotesEditorCodingKey("remove_index")),
                instruction: instruction)
        case "insert":
            let allowedWithoutIndex: Set<String> = ["field", "insert", "instruction"]
            let allowedWithIndex = allowedWithoutIndex.union(["index"])
            guard keys == allowedWithoutIndex || keys == allowedWithIndex else {
                throw notesEditorDataCorrupted(decoder, "insert operation has the wrong properties")
            }
            let indexKey = NotesEditorCodingKey("index")
            let index = container.contains(indexKey)
                ? try container.decode(Int.self, forKey: indexKey)
                : nil
            self = .insert(
                field: field,
                index: index,
                patch: try container.decode(
                    NotesItemPatch.self, forKey: NotesEditorCodingKey("insert")),
                instruction: instruction)
        default:
            throw notesEditorDataCorrupted(decoder, "unknown operation discriminator")
        }
    }
}

private struct NotesEditorResponseEnvelope: Decodable {
    var operations: [NotesEditOperation]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: NotesEditorCodingKey.self)
        let keys = Set(container.allKeys.map(\.stringValue))
        guard keys == ["ops"] else {
            throw notesEditorDataCorrupted(decoder, "editor response must carry exactly ops")
        }
        operations = try container.decode(
            [NotesEditOperation].self, forKey: NotesEditorCodingKey("ops"))
    }
}

// MARK: - Pure operation applier

enum NotesEditApplier {
    static func apply(
        _ operations: [NotesEditOperation], to currentNotes: NotesStructured
    ) -> (notes: NotesStructured, effectiveOperations: [Bool]) {
        var notes = currentNotes
        var effectiveOperations: [Bool] = []
        effectiveOperations.reserveCapacity(operations.count)

        for operation in operations {
            var effective = false
            switch operation {
            case .replace(let field, let find, let replace, _):
                switch field {
                case .title:
                    if let before = notes.title,
                        let after = replacedProse(before, find: find, replace: replace)
                    {
                        notes.title = after
                        effective = true
                    }
                case .summary:
                    if let after = replacedProse(notes.summary, find: find, replace: replace),
                        !after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    {
                        notes.summary = after
                        effective = true
                    }
                case .detailedNotes:
                    if let after = replacedProse(notes.detailedNotes, find: find, replace: replace) {
                        notes.detailedNotes = after
                        effective = true
                    }
                case .decisions, .actionItems, .userActionItems:
                    break
                }

            case .set(let field, let index, let patch, _):
                switch field {
                case .decisions:
                    guard notes.decisions.indices.contains(index), let text = patch.text else { break }
                    let before = notes.decisions[index]
                    guard bytes(before) != bytes(text) else { break }
                    notes.decisions[index] = text
                    effective = true
                case .actionItems:
                    effective = setItem(in: &notes.actionItems, at: index, patch: patch)
                case .userActionItems:
                    effective = setItem(in: &notes.userActionItems, at: index, patch: patch)
                case .title, .summary, .detailedNotes:
                    break
                }

            case .remove(let field, let index, _):
                switch field {
                case .decisions:
                    effective = removeItem(from: &notes.decisions, at: index)
                case .actionItems:
                    effective = removeItem(from: &notes.actionItems, at: index)
                case .userActionItems:
                    effective = removeItem(from: &notes.userActionItems, at: index)
                case .title, .summary, .detailedNotes:
                    break
                }

            case .insert(let field, let index, let patch, _):
                switch field {
                case .decisions:
                    guard let text = patch.text else { break }
                    effective = insertItem(text, into: &notes.decisions, at: index)
                case .actionItems:
                    guard let owner = patch.owner, let text = patch.text else { break }
                    effective = insertItem(
                        ActionItem(owner: owner, text: text), into: &notes.actionItems, at: index)
                case .userActionItems:
                    guard let owner = patch.owner, let text = patch.text else { break }
                    effective = insertItem(
                        ActionItem(owner: owner, text: text), into: &notes.userActionItems, at: index)
                case .title, .summary, .detailedNotes:
                    break
                }
            }
            effectiveOperations.append(effective)
        }

        return (notes, effectiveOperations)
    }

    private static func bytes(_ string: String) -> [UInt8] {
        Array(string.utf8)
    }

    private static func replacedProse(
        _ value: String, find: String, replace: String
    ) -> String? {
        guard !find.isEmpty, bytes(find) != bytes(replace) else { return nil }
        let result = value.replacingOccurrences(of: find, with: replace, options: .literal)
        return bytes(result) == bytes(value) ? nil : result
    }

    private static func setItem(
        in items: inout [ActionItem], at index: Int, patch: NotesItemPatch
    ) -> Bool {
        guard items.indices.contains(index) else { return false }
        let before = items[index]
        var after = before
        if let owner = patch.owner { after.owner = owner }
        if let text = patch.text { after.text = text }
        guard bytes(before.owner) != bytes(after.owner) || bytes(before.text) != bytes(after.text)
        else { return false }
        items[index] = after
        return true
    }

    private static func removeItem<Item>(from items: inout [Item], at index: Int) -> Bool {
        guard items.indices.contains(index) else { return false }
        items.remove(at: index)
        return true
    }

    private static func insertItem<Item>(
        _ item: Item, into items: inout [Item], at index: Int?
    ) -> Bool {
        if let index {
            guard index >= 0, index <= items.count else { return false }
            items.insert(item, at: index)
        } else {
            items.append(item)
        }
        return true
    }
}

// MARK: - Digest-editor strict decoding

extension DigestEditOperation {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: NotesEditorCodingKey.self)
        let keys = Set(container.allKeys.map(\.stringValue))
        guard keys == ["find", "replace", "instruction"] else {
            throw notesEditorDataCorrupted(
                decoder, "digest edit operation has the wrong properties")
        }
        find = try container.decode(String.self, forKey: NotesEditorCodingKey("find"))
        replace = try container.decode(String.self, forKey: NotesEditorCodingKey("replace"))
        instruction = try container.decode(Int.self, forKey: NotesEditorCodingKey("instruction"))
    }
}

private struct DigestEditorResponseEnvelope: Decodable {
    var operations: [DigestEditOperation]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: NotesEditorCodingKey.self)
        let keys = Set(container.allKeys.map(\.stringValue))
        guard keys == ["ops"] else {
            throw notesEditorDataCorrupted(
                decoder, "digest editor response must carry exactly ops")
        }
        operations = try container.decode(
            [DigestEditOperation].self, forKey: NotesEditorCodingKey("ops"))
    }
}

// MARK: - Pure digest applier + structural assertion

enum DigestEditApplier {
    /// The `md-v1` heading set. A heading outside it — model-smuggled or
    /// inherited from a corrupt input — never ships.
    static let allowedHeadings = [
        "HEADER", "DECISIONS", "COMMITMENTS", "FACTS", "STATUS", "VIEWS", "OPEN", "POLICIES",
    ]

    /// Applies the operations in array order, each replacing EVERY occurrence of
    /// its `find`. Matching is `.literal` — codepoint-exact — so an NFD-stored
    /// digest with an NFC `find` is deterministically a no-op rather than a
    /// locale-dependent surprise. An empty `find` is a no-op (the schema cannot
    /// forbid empty strings, so the applier does), and an unmatched `find` is a
    /// no-op by construction.
    ///
    /// Returns nil when the applied result fails the structural assertion: the
    /// whole ops array is discarded and the stored digest stays byte-unchanged.
    static func apply(_ operations: [DigestEditOperation], to digest: String) -> String? {
        var result = digest
        for operation in operations {
            guard !operation.find.isEmpty else { continue }
            result = result.replacingOccurrences(
                of: operation.find, with: operation.replace, options: .literal)
        }
        guard isStructurallySound(result, against: digest) else { return nil }
        return result
    }

    /// The `## ` heading names of a digest, in document order.
    static func headings(of digest: String) -> [String] {
        digest.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
            guard line.hasPrefix("## ") else { return nil }
            return String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        }
    }

    /// True where a line renders as an ATX heading of ANY level, CommonMark
    /// §4.2: up to three leading spaces, then one to six `#`, then heading
    /// whitespace or the end of the line (`###` alone is an empty heading).
    static func isHeadingLike(_ line: Substring) -> Bool {
        let indent = line.prefix(while: { $0 == " " })
        guard indent.count <= 3 else { return false }
        let opening = line.dropFirst(indent.count)
        let hashes = opening.prefix(while: { $0 == "#" })
        guard (1 ... 6).contains(hashes.count) else { return false }
        let rest = opening.dropFirst(hashes.count)
        return rest.isEmpty || rest.first == " " || rest.first == "\t"
    }

    /// One deterministic scan, no model: the result carries no heading-like line
    /// other than an exact allowed `## ` heading (a `### INVENTED` or a
    /// `#### FACTS` renders as a section the `md-v1` envelope does not have,
    /// whatever level it wears), the result's heading LIST must be an
    /// order-preserved SUBSEQUENCE of the input's (a multiset-and-order rule —
    /// it catches duplicated, renamed and reordered headings, which a set-subset
    /// test misses), every surviving heading must be an `md-v1` heading, and
    /// `## HEADER` must survive (the envelope is always derivable, so the one
    /// mandatory section is asserted by name).
    static func isStructurallySound(_ result: String, against input: String) -> Bool {
        for line in result.split(separator: "\n", omittingEmptySubsequences: false)
        where isHeadingLike(line) {
            guard line.hasPrefix("## "),
                allowedHeadings.contains(
                    String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces))
            else { return false }
        }
        let output = headings(of: result)
        guard output.contains("HEADER") else { return false }
        var remaining = headings(of: input)[...]
        for heading in output {
            guard let match = remaining.firstIndex(of: heading) else { return false }
            remaining = remaining[remaining.index(after: match)...]
        }
        return true
    }
}
