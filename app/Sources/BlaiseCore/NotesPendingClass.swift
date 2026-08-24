import Foundation

/// Reserved `meeting.last_processing_error` prefix registry (D17; same
/// no-string-scattering rule as `HandoffErrorClass`).
///
/// `notes-pending:` marks the one deliberate non-failure use of
/// `lastProcessingError`: the run finished everything EXCEPT notes — the
/// transcript is persisted and visible, audio is retained, NO handoff was
/// enqueued (ready ⇒ queued holds: the meeting is not ready) — because the
/// notes stage hit a fallback-trigger condition and the only fallback engine
/// is heavyweight (never auto-loaded). The state self-heals: app launch, an
/// API key save in Settings, and network-path restoration each re-dispatch
/// pending meetings through the pipeline's notes-only resume.
///
/// `notesFilePromoteIncomplete` is the ONE reason that does not fit that
/// paragraph: it marks the deferred install's commit-to-promote window, where
/// the notes row DID commit and the payload IS enqueued and only `notes.md` is
/// behind. It shares the prefix because it wants exactly the same self-heal —
/// re-mint from the row — and the re-mint converges the file either way.
///
/// Every consumer (pipeline, UI pill/banner, the self-heal triggers) MUST
/// compile against these constants.
public enum NotesPendingClass {
    public static let prefix = "notes-pending:"

    /// G15: the ONE reserved notes-pending reason for the participant-
    /// confirmation gate. A meeting parked with `marker(awaitingParticipantConfirmation)`
    /// is holding the notes stage until the user confirms (or skips) the
    /// participant names — the same D17 semantics apply verbatim (transcript
    /// persisted and visible, audio retained, NO handoff, marker never bumps
    /// updatedAt). Distinct from every engine/ceiling pending reason so the
    /// self-heal, the UI banner, and the notification key off it precisely.
    public static let awaitingParticipantConfirmation = "awaiting participant confirmation"

    /// The reserved reason committed INSIDE the finalize transaction of a
    /// deferred run and cleared once `notes.md` carries the row that commit
    /// installed. A meeting found carrying it is `ready` with a new notes row
    /// whose file may still be the previous one (or absent) — the durable
    /// state process death in that window leaves behind — and the self-heal
    /// (launch / key save / network restore) re-mints it, which rewrites the
    /// file from the row.
    public static let notesFilePromoteIncomplete = "notes file promote incomplete"

    /// `last_processing_error` value for a notes-pending meeting.
    public static func marker(_ reason: String) -> String {
        prefix + " " + reason
    }

    public static func isPending(_ lastProcessingError: String?) -> Bool {
        lastProcessingError?.hasPrefix(prefix) ?? false
    }

    /// True iff the meeting is parked on the G15 participant-confirmation gate
    /// specifically (not an engine/ceiling pending reason). Keys the confirm
    /// banner/sheet, the "once per park" notification suppression, and the
    /// gate's own re-park-vs-fresh-park decision.
    public static func isAwaitingParticipantConfirmation(_ lastProcessingError: String?) -> Bool {
        lastProcessingError == marker(awaitingParticipantConfirmation)
    }
}
