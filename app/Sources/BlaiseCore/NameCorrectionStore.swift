import Foundation
import GRDB

/// G2 §2: the durable name-correction store. One folded misheard key → one
/// replacement, with the everyday flag computed at write time. The write path
/// (`upsert`) enforces §2(a–d): chain resolution, transitive-closure
/// maintenance, no-op refusal, and word-level conflict refusal — so the store
/// is always cycle-free, one-hop, and word-compose-free, and the substitution
/// pass (`NameSubstitution.apply`) can stay single-pass simple.
public struct NameCorrection: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "name_correction"

    public var id: String
    /// The folded misheard surface (the UNIQUE key); `VocabNormalization.canonicalMode`.
    public var mishearedFolded: String
    /// The replacement, stored in its user-facing surface form.
    public var replacement: String
    /// Computed at write time by the G1 everyday test over the folded key;
    /// governs WHERE this row applies (§3 rule 1).
    public var everyday: Bool
    public var sourceMeetingID: MeetingID?
    public var createdAt: Date

    public init(
        id: String = ULID.generate(),
        mishearedFolded: String,
        replacement: String,
        everyday: Bool,
        sourceMeetingID: MeetingID?,
        createdAt: Date
    ) {
        self.id = id
        self.mishearedFolded = mishearedFolded
        self.replacement = replacement
        self.everyday = everyday
        self.sourceMeetingID = sourceMeetingID
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, replacement, everyday
        case mishearedFolded = "misheard_folded"
        case sourceMeetingID = "source_meeting_id"
        case createdAt = "created_at"
    }
}

/// The §2 write path and its read snapshot. The `everyday` decision and the
/// folds are injected so the same logic serves the pipeline (folded membership
/// from `PipelineVocabulary`) and the UI (which reuses the run vocabulary).
public enum NameCorrectionStore {
    /// Result of an attempted write.
    public enum WriteResult: Equatable, Sendable {
        /// The row was written (possibly after resolving its replacement and
        /// retargeting earlier rows); the canonical replacement that landed.
        case written(replacement: String)
        /// (c): the key resolves to itself — a no-op row cannot exist.
        case refusedNoOp
        /// (d): word-level conflict with an existing row whose RESOLVED
        /// replacement differs. `conflictKey`/`conflictReplacement` name it for
        /// the explanatory copy ('conflicts with "<key> → <replacement>"').
        case refusedConflict(conflictKey: String, conflictReplacement: String)
    }

    /// All rows, ordered by creation (stable display order).
    public static func all(_ db: Database) throws -> [NameCorrection] {
        try NameCorrection
            .order(Column("created_at"), Column("id"))
            .fetchAll(db)
    }

    /// Deletes the row with the given folded key. No normalization runs on
    /// delete (deleting a row only ever shrinks the closure).
    public static func delete(_ db: Database, mishearedFolded: String) throws {
        _ = try NameCorrection
            .filter(Column("misheard_folded") == mishearedFolded)
            .deleteAll(db)
    }

    /// Folds a surface the way the store keys do (`canonicalMode`).
    public static func fold(_ s: String) -> String {
        VocabNormalization.canonicalMode(s)
    }

    /// The §2 write. `mishearedSurface` is the raw user surface (folded for the
    /// key); `replacement` is the user-facing replacement surface. `isEveryday`
    /// answers the G1 everyday test for a folded key. Idempotent re-teach of an
    /// existing key updates it (still through (a)–(d)).
    ///
    /// Order is strictly check-then-mutate (R4-L2): (a) resolves the incoming
    /// replacement once; (c) and (d) decide refusal BEFORE any (b) mutation;
    /// only on acceptance do (b)'s retargets and the row insert commit.
    @discardableResult
    public static func upsert(
        _ db: Database,
        mishearedSurface: String,
        replacement: String,
        sourceMeetingID: MeetingID?,
        now: Date,
        isEveryday: @Sendable (String) -> Bool
    ) throws -> WriteResult {
        let newKey = fold(mishearedSurface)
        guard !newKey.isEmpty else { return .refusedNoOp }

        var rows = try all(db)
        // A re-teach of an existing key must not let that same row act as the
        // resolution/conflict target for itself.
        rows.removeAll { $0.mishearedFolded == newKey }

        // (a) Resolve the new replacement through existing rows ONCE: if the
        // replacement's fold equals an existing key, store that row's
        // replacement instead (the chain collapses to one hop).
        let replacementFold = fold(replacement)
        var resolvedReplacement = replacement
        if let hit = rows.first(where: { $0.mishearedFolded == replacementFold }) {
            resolvedReplacement = hit.replacement
        }

        // (c) Refuse a key that fold-equals its own resolved replacement.
        if newKey == fold(resolvedReplacement) {
            return .refusedNoOp
        }

        // The new row's resolved target, in words (for the (d) word check) —
        // and the would-be (b) retarget that the conflict comparison must see
        // (the prospective post-insert store, per v5_verification §3).
        let newTargetFold = fold(resolvedReplacement)
        let newKeyFold = newKey

        // (d) WORD-LEVEL conflict refusal — but ONLY when the two rows'
        // RESOLVED replacements differ. Resolution is over the prospective
        // post-insert store: an existing row whose replacement fold-equals the
        // new key WILL be retargeted by (b) to `resolvedReplacement`, so its
        // effective target is `newTargetFold`.
        for row in rows {
            // Effective resolved target of the existing row AFTER the (b)
            // retarget the accepted insert would apply.
            let existingTargetFold =
                fold(row.replacement) == newKeyFold ? newTargetFold : fold(row.replacement)

            // First clause: the new key fold-equals any single WORD of an
            // existing row's replacement.
            let newKeyHitsExistingWord =
                NameSubstitution.foldedWords(in: row.replacement).contains(newKeyFold)
            // Second clause: the new replacement contains a WORD fold-equal to
            // an existing key.
            let newReplacementHitsExistingKey =
                NameSubstitution.foldedWords(in: resolvedReplacement).contains(row.mishearedFolded)

            guard newKeyHitsExistingWord || newReplacementHitsExistingKey else { continue }

            // Same-target chain refinements pass (R4-H3): the exemption is
            // exactly target-granular.
            if existingTargetFold == newTargetFold { continue }
            return .refusedConflict(
                conflictKey: row.mishearedFolded, conflictReplacement: row.replacement)
        }

        // Accepted. Apply (b): every existing row whose replacement
        // fold-equals the NEW key is retargeted to the resolved replacement
        // (transitive closure maintained flat).
        for row in rows where fold(row.replacement) == newKeyFold {
            try db.execute(
                sql: "UPDATE name_correction SET replacement = ? WHERE id = ?",
                arguments: [resolvedReplacement, row.id])
        }

        // Upsert the new row (UNIQUE key → REPLACE the prior row for this key).
        let correction = NameCorrection(
            mishearedFolded: newKey,
            replacement: resolvedReplacement,
            everyday: isEveryday(newKey),
            sourceMeetingID: sourceMeetingID,
            createdAt: now)
        try db.execute(
            sql: """
                INSERT INTO name_correction
                    (id, misheard_folded, replacement, everyday, source_meeting_id, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(misheard_folded) DO UPDATE SET
                    replacement = excluded.replacement,
                    everyday = excluded.everyday,
                    source_meeting_id = excluded.source_meeting_id,
                    created_at = excluded.created_at
                """,
            arguments: [
                correction.id, correction.mishearedFolded, correction.replacement,
                correction.everyday, correction.sourceMeetingID, correction.createdAt,
            ])
        return .written(replacement: resolvedReplacement)
    }
}
