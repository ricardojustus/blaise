import Foundation

/// G14 (H1): reserved `meeting.last_processing_error` prefix registry for the
/// memory-digest sub-state (D17 same no-string-scattering rule as
/// `NotesPendingClass`/`HandoffErrorClass`).
///
/// `digest-pending:` marks the one deliberate non-failure use of
/// `lastProcessingError` for the digest: the run finished EVERYTHING the
/// meeting needs — transcript persisted, notes minted, handoff enqueued, the
/// meeting is `ready` and fully usable (Floor 8: a digest-call failure never
/// blocks or loses a meeting) — EXCEPT the memory digest, whose call failed
/// past its bounded retry. The marker makes that failure DISTINGUISHABLE from
/// toggle-off / legacy (which have a null `memory_digest` BY INTENT): a
/// `digest-pending:` meeting WANTED a digest and didn't get one this pass.
///
/// The state self-heals: every self-heal trigger that drives the notes-pending
/// resume (app launch, API-key save, network-path restoration, an explicit
/// regenerate) ALSO drives a SEPARATE digest-resume dispatch keyed on this
/// prefix, which re-fires `generateDigest` over the stored transcript + stored
/// notes WITHOUT re-running `generateNotes` (the `ready` meeting's notes are
/// final). So a digest-pending meeting is NOT a permanent silent null — until
/// a digest lands, the payload simply omits `memory_digest` (absent ⇒ skip).
///
/// Distinct prefix from `notes-pending:` so the two dispatches never cross:
/// the notes-pending dispatch matches `notes-pending:%` and re-runs notes; the
/// digest dispatch matches `digest-pending:%` and re-runs only the digest.
public enum DigestPendingClass {
    public static let prefix = "digest-pending:"

    /// `last_processing_error` value for a digest-pending meeting.
    public static func marker(_ reason: String) -> String {
        prefix + " " + reason
    }

    public static func isPending(_ lastProcessingError: String?) -> Bool {
        lastProcessingError?.hasPrefix(prefix) ?? false
    }
}
