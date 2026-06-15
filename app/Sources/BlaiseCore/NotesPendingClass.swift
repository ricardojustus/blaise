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

    /// `last_processing_error` value for a notes-pending meeting.
    public static func marker(_ reason: String) -> String {
        prefix + " " + reason
    }

    public static func isPending(_ lastProcessingError: String?) -> Bool {
        lastProcessingError?.hasPrefix(prefix) ?? false
    }
}
