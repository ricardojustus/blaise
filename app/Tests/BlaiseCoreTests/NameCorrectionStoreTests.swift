import Foundation
import GRDB
import Testing
@testable import BlaiseCore

// G2 §2 write-rule pins (AC5's "separate unit pins each §2 refusal incl. (d)
// both directions"). The everyday flag is computed via a real lexicon test.

private func everydayTest() throws -> @Sendable (String) -> Bool {
    let lex = try PipelineVocabulary.sharedLexicons()
    return { PipelineVocabulary.isEveryday($0, lexicons: lex) }
}

private func write(
    _ db: Database, _ key: String, _ replacement: String, _ isEveryday: @Sendable (String) -> Bool
) throws -> NameCorrectionStore.WriteResult {
    try NameCorrectionStore.upsert(
        db, mishearedSurface: key, replacement: replacement, sourceMeetingID: nil,
        now: msDate(), isEveryday: isEveryday)
}

@Suite struct NameCorrectionStoreTests {
    @Test func everydayFlagComputedAtWrite() async throws {
        let db = try makeDatabase()
        let everyday = try everydayTest()
        try await db.pool.write { conn in
            _ = try write(conn, "riso", "Marco Vidal", everyday)
            _ = try write(conn, "Vexatron", "Vextron Labs", everyday) // not everyday
            let rows = try NameCorrectionStore.all(conn)
            let riso = try #require(rows.first { $0.mishearedFolded == "riso" })
            #expect(riso.everyday == true)
            let vex = try #require(rows.first { $0.mishearedFolded == "vexatron" })
            #expect(vex.everyday == false)
        }
    }

    @Test func chainRowsCollapse_forwardOrder() async throws {
        let db = try makeDatabase()
        let everyday = try everydayTest()
        try await db.pool.write { conn in
            _ = try write(conn, "riso", "Vidal", everyday)
            let r = try write(conn, "Vidal", "Marco Vidal", everyday)
            #expect(r == .written(replacement: "Marco Vidal"))
            let rows = try NameCorrectionStore.all(conn)
            // (b) retargeted riso → "Marco Vidal"; both rows same target.
            let riso = try #require(rows.first { $0.mishearedFolded == "riso" })
            #expect(riso.replacement == "Marco Vidal")
            let Vidal = try #require(rows.first { $0.mishearedFolded == "vidal" })
            #expect(Vidal.replacement == "Marco Vidal")
        }
    }

    @Test func chainRowsCollapse_reverseOrder() async throws {
        let db = try makeDatabase()
        let everyday = try everydayTest()
        try await db.pool.write { conn in
            _ = try write(conn, "Vidal", "Marco Vidal", everyday)
            // (a) resolves "Vidal" → existing key Vidal → "Marco Vidal".
            let r = try write(conn, "riso", "Vidal", everyday)
            #expect(r == .written(replacement: "Marco Vidal"))
            let rows = try NameCorrectionStore.all(conn)
            let riso = try #require(rows.first { $0.mishearedFolded == "riso" })
            #expect(riso.replacement == "Marco Vidal")
        }
    }

    @Test func cycleRefused_selfResolvingNoOp() async throws {
        let db = try makeDatabase()
        let everyday = try everydayTest()
        try await db.pool.write { conn in
            // key folds equal to its own replacement → refused.
            let r = try write(conn, "Vidal", "Vidal", everyday)
            #expect(r == .refusedNoOp)
            #expect(try NameCorrectionStore.all(conn).isEmpty)
        }
    }

    @Test func wordConflictRefused_differentTargets_bothDirections() async throws {
        let db = try makeDatabase()
        let everyday = try everydayTest()
        // Direction 1: existing Vidal→Marco Vidal; insert hizo→Halden Vidal
        // (new replacement contains word "Vidal" fold-equal to existing key;
        // targets differ) → REFUSED.
        try await db.pool.write { conn in
            _ = try write(conn, "Vidal", "Marco Vidal", everyday)
            let r = try write(conn, "hizo", "Halden Vidal", everyday)
            if case .refusedConflict(let key, _) = r {
                #expect(key == "vidal")
            } else {
                Issue.record("expected refusedConflict, got \(r)")
            }
        }
        // Direction 2 (other clause): existing Marsh→Sammy Marsh; insert
        // sammy→Sammy Lee (new key fold-equals a replacement word; targets
        // differ) → REFUSED.
        let db2 = try makeDatabase()
        try await db2.pool.write { conn in
            _ = try write(conn, "Marsh", "Sammy Marsh", everyday)
            let r = try write(conn, "sammy", "Sammy Lee", everyday)
            if case .refusedConflict = r {} else {
                Issue.record("expected refusedConflict, got \(r)")
            }
        }
    }

    @Test func sameTargetWordOverlapAccepted() async throws {
        // The exemption: riso→Marco Vidal + Vidal→Marco Vidal coexist.
        let db = try makeDatabase()
        let everyday = try everydayTest()
        try await db.pool.write { conn in
            _ = try write(conn, "riso", "Marco Vidal", everyday)
            let r = try write(conn, "Vidal", "Marco Vidal", everyday)
            #expect(r == .written(replacement: "Marco Vidal"))
            #expect(try NameCorrectionStore.all(conn).count == 2)
        }
    }

    @Test func checkBeforeMutate_refusedInsertLeavesStoreUnmutated() async throws {
        // A refused (d) insert must NOT have applied any (b) retarget.
        let db = try makeDatabase()
        let everyday = try everydayTest()
        try await db.pool.write { conn in
            _ = try write(conn, "Vidal", "Marco Vidal", everyday)
            _ = try write(conn, "hizo", "Halden Vidal", everyday) // refused
            let Vidal = try #require(
                NameCorrectionStore.all(conn).first { $0.mishearedFolded == "vidal" })
            #expect(Vidal.replacement == "Marco Vidal") // untouched
            #expect(try NameCorrectionStore.all(conn).count == 1)
        }
    }

    // C-1: the write gate and the engine MUST agree on what a "word" is. A
    // decorated replacement word — "(Sammy)" — folds (via the engine's shared
    // .byWords segmentation) to "sammy", so inserting `sammy → Bob` against an
    // existing `xq → (Sammy)` is a different-target WORD conflict and MUST be
    // refused. Pre-fix the gate folded "(sammy)" (whitespace-split) ≠ "sammy",
    // missed the hit, and wrote the row — which composed in the engine.
    @Test func wordConflictRefused_decoratedReplacementWord_C1() async throws {
        let db = try makeDatabase()
        let everyday = try everydayTest()
        try await db.pool.write { conn in
            _ = try write(conn, "xq", "(Sammy)", everyday)
            let r = try write(conn, "sammy", "Bob", everyday)
            if case .refusedConflict(let key, _) = r {
                #expect(key == "xq")
            } else {
                Issue.record("expected refusedConflict on the decorated word, got \(r)")
            }
            // The store stayed word-compose-free: xq still resolves to (Sammy),
            // and there is no sammy→Bob row to make apply∘apply ≠ apply.
            let rows = try NameCorrectionStore.all(conn)
            #expect(rows.count == 1)
            #expect(rows.first?.mishearedFolded == "xq")
        }
    }

    // C-1, the other direction / markdown form: a `**Sammy**` replacement word
    // must be seen by the gate exactly as the engine sees it.
    @Test func wordConflictRefused_markdownReplacementWord_C1() async throws {
        let db = try makeDatabase()
        let everyday = try everydayTest()
        try await db.pool.write { conn in
            _ = try write(conn, "xq", "**Sammy**", everyday)
            let r = try write(conn, "sammy", "Bob", everyday)
            if case .refusedConflict = r {} else {
                Issue.record("expected refusedConflict on the markdown word, got \(r)")
            }
        }
    }

    @Test func reteachExistingKeyUpdates() async throws {
        let db = try makeDatabase()
        let everyday = try everydayTest()
        try await db.pool.write { conn in
            _ = try write(conn, "semi", "Sammy", everyday)
            _ = try write(conn, "semi", "Sammy Marsh", everyday)
            let rows = try NameCorrectionStore.all(conn)
            #expect(rows.count == 1)
            #expect(rows[0].replacement == "Sammy Marsh")
        }
    }
}
