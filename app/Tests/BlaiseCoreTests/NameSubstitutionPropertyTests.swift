import Foundation
import GRDB
import Testing
@testable import BlaiseCore

// G2 AC5 (the SPECIFIED test, H-7): a property test over GENERATED cases that
// builds the store THROUGH THE §2 WRITE PATH (not hand-rolled rows), then
// asserts apply∘apply == apply on adversarial notes — including the C-1
// (decorated replacement word) and C-2 (apostrophe) inputs the round-1 audit
// used to break idempotence on a write-path-accepted store. Because the store
// is built only via NameCorrectionStore.upsert, every store the property sees
// is one §2(a–d) would actually ACCEPT to ship.

@Suite(.serialized) struct NameSubstitutionPropertyTests {
    private func everydayClosure() throws -> @Sendable (String) -> Bool {
        let lex = try PipelineVocabulary.sharedLexicons()
        return { PipelineVocabulary.isEveryday($0, lexicons: lex) }
    }

    /// A small deterministic PRNG so the generated cases are reproducible
    /// (failures replay identically — no seeded-hash flake).
    private struct LCG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    /// The adversarial corpus the writes are drawn from — keys and replacements
    /// that include the round-1 corruptions: decorated replacement words
    /// ("(Sammy)", "**Sammy**"), apostrophe replacements ("O'Neil"), and chains
    /// the (a)/(b) normalization collapses.
    private let keys = ["xq", "sammy", "hizo", "Vidal", "riso", "Marsh", "semi", "caco"]
    private let replacements = [
        "Bob", "(Sammy)", "**Sammy**", "Sammy Lee", "Sammy Marsh", "O'Neil",
        "Marco Vidal", "Halden Vidal", "Vidal", "Kobi",
    ]

    /// Build a store by attempting `n` random writes through the §2 path; return
    /// the resulting StoreRows for the engine.
    private func buildStore(
        seed: UInt64, writes: Int, _ everyday: @Sendable (String) -> Bool
    ) async throws -> [NameSubstitution.StoreRow] {
        var rng = LCG(state: seed)
        // Draw the write sequence up-front (the PRNG can't cross the write
        // closure's Sendable boundary).
        let pairs: [(String, String)] = (0 ..< writes).map { _ in
            (keys.randomElement(using: &rng)!, replacements.randomElement(using: &rng)!)
        }
        let db = try makeDatabase()
        try await db.pool.write { conn in
            for (k, r) in pairs {
                // The write path itself enforces (a–d); refusals are simply not
                // applied — exactly what production does.
                _ = try? NameCorrectionStore.upsert(
                    conn, mishearedSurface: k, replacement: r, sourceMeetingID: nil,
                    now: msDate(), isEveryday: everyday)
            }
        }
        return try await db.pool.read { conn in
            try NameCorrectionStore.all(conn).map {
                NameSubstitution.StoreRow(
                    mishearedFolded: $0.mishearedFolded, replacement: $0.replacement,
                    everyday: $0.everyday)
            }
        }
    }

    /// The adversarial note fields the property applies the store over,
    /// including the C-2 possessive + quoted-span inputs, the C-3 co-surname
    /// bearer ("Halden Vidal" alongside a `Vidal → …` row), and owner fields
    /// that the rule-2 owner fuzzy fix can fire on ("Vidau", "Samy", "Halde").
    private func noteCases() -> [NotesStructured] {
        let texts = [
            "xq said 'hizo stays' today",
            "Sam's plan: 'keep hizo as is' for now",
            "Cale's plan: 'keep hizo as is' for now",
            "Vidal e SEMI falaram com Mateo",
            "Marco Vidal aprovou; Vidal confirmou",
            "Halden Vidal e Vidal no mesmo texto",
            "\"Vidal\" entre aspas e Vidal solto",
            "O'Neil's note about sammy and xq",
        ]
        // Owners that exercise rule 2 (field-level fuzzy fix) — including
        // near-misses of the candidate full names below.
        let owners = ["xq", "sammy", "Vidau", "Samy", "Halden Vidal", "Marco Vidal"]
        return texts.flatMap { t in
            owners.map { owner in
                NotesStructured(
                    title: nil, summary: t, detailedNotes: t, decisions: [t],
                    actionItems: [ActionItem(owner: owner, text: t)],
                    userActionItems: [ActionItem(owner: "sammy", text: t)])
            }
        }
    }

    /// C-3 blind-spot closure: the candidate sets the property runs the store
    /// over. The EMPTY set is the original property; the NON-EMPTY set wires in
    /// rule 2 (owner fuzzy fix) AND the known-entity full names, so the
    /// rule-2→rule-1 surname-expansion composition the round-2 audit found
    /// ("Vidau" → "Halden Vidal" → "Halden Marco Vidal") is inside the
    /// idempotence property.
    private func candidateSets() -> [[String]] {
        [
            [],
            ["Marco Vidal", "Halden Vidal", "Sammy Marsh", "Sammy Lee"],
        ]
    }

    @Test func applyApplyEqualsApply_overGeneratedWritePathStores() async throws {
        let everyday = try everydayClosure()
        let cases = noteCases()
        let candidateSets = candidateSets()
        // 120 generated contexts (varied seeds × write counts × candidate sets)
        // × the adversarial notes — each store is one the §2 write path produced
        // and would ship; each candidate set is empty (original) or the C-3
        // co-surname/rule-2 set that exercises the rule-2→rule-1 relay.
        for seed in UInt64(1) ... 20 {
            for writes in [2, 5, 9] {
                let rows = try await buildStore(seed: seed, writes: writes, everyday)
                for candidates in candidateSets {
                    let context = NameSubstitution.Context(
                        store: rows, ownerCandidates: candidates, commonNames: [],
                        polishCanonicals: [])
                    let label = "seed \(seed), writes \(writes), candidates \(candidates.count)"
                    for input in cases {
                        let once = NameSubstitution.apply(notes: input, context: context).notes
                        let twice = NameSubstitution.apply(notes: once, context: context)
                        #expect(once == twice.notes, "apply∘apply must equal apply (\(label))")
                        #expect(twice.report.isEmpty, "second pass must be a no-op (\(label))")
                    }
                }
            }
        }

        // C-3 GUARANTEE: the random write draw may or may not produce the exact
        // `Vidal → Marco Vidal` row that drives the rule-2→rule-1 relay, so
        // pin one deterministic store-built-through-the-write-path that DOES,
        // applied with the co-surname candidate set over the relay-prone owners.
        // This is the case that fails when the NC-2 known-entity skip is neutered.
        let relayDB = try makeDatabase()
        try await relayDB.pool.write { conn in
            _ = try? NameCorrectionStore.upsert(
                conn, mishearedSurface: "Vidal", replacement: "Marco Vidal",
                sourceMeetingID: nil, now: msDate(), isEveryday: everyday)
        }
        let relayRows = try await relayDB.pool.read { conn in
            try NameCorrectionStore.all(conn).map {
                NameSubstitution.StoreRow(
                    mishearedFolded: $0.mishearedFolded, replacement: $0.replacement,
                    everyday: $0.everyday)
            }
        }
        // Single candidate so rule 2 fires UNAMBIGUOUSLY on "Vidau" (two
        // Vidal-bearing candidates would tie → no-op and never start the relay).
        let relayContext = NameSubstitution.Context(
            store: relayRows, ownerCandidates: ["Halden Vidal"],
            commonNames: [], polishCanonicals: [])
        let relayNotes: [NotesStructured] = [
            // "Vidau" fuzzy-grounds to "Halden Vidal" (rule 2); the surname inside
            // must NOT then expand under the Vidal row on the next pass.
            NotesStructured(
                title: nil, summary: "Halden Vidal e Vidal", detailedNotes: "",
                decisions: [], actionItems: [ActionItem(owner: "Vidau", text: "x")],
                userActionItems: []),
            NotesStructured(
                title: nil, summary: "", detailedNotes: "",
                decisions: [], actionItems: [ActionItem(owner: "Halden Vidal", text: "x")],
                userActionItems: []),
        ]
        for input in relayNotes {
            let once = NameSubstitution.apply(notes: input, context: relayContext).notes
            let twice = NameSubstitution.apply(notes: once, context: relayContext)
            #expect(once == twice.notes, "C-3 relay: apply∘apply must equal apply")
            #expect(twice.report.isEmpty, "C-3 relay: second pass must be a no-op")
        }
    }
}
