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
