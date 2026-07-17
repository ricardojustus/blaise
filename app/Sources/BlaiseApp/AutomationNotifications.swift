import BlaiseCore
import Foundation
import UserNotifications
import os

// C14: the UNUserNotificationCenter adapter behind BlaiseCore's
// `AutomationNotifying` seam (the tracker/scheduler never touch UN* —
// fully mockable in tests). Categories: `meetStart` (Record),
// `calendarUpcoming` (Launch & Record), `graceResume` (Resume — the
// watchdog-stop recovery; registered as its own category because action
// titles are fixed per category). Interruption level `.active` —
// `.timeSensitive` needs a provisioned entitlement the Apple Development
// signing flow does not carry (deliberate non-goal). Actionable alerts use
// the system sound so meeting transitions are not visually silent.

enum AutomationNotificationCategory {
    static let meetStart = "meetStart"
    static let calendarUpcoming = "calendarUpcoming"
    static let graceResume = "graceResume"
    static let handoffWarning = "handoffWarning"
    static let diagnostics = "diagnostics"
    static let participantConfirm = "participantConfirm"

    static let recordAction = "record"
    static let launchRecordAction = "launchRecord"
    static let resumeAction = "resume"
    static let openBlaiseAction = "openBlaise"
    static let confirmParticipantsAction = "confirmParticipants"
}

/// What macOS currently allows Blaise notifications to do. A successful
/// `UNUserNotificationCenter.add` only means macOS accepted the request; it
/// does not prove that a banner was visible (Focus and presentation settings
/// can still keep it quiet). The menu mirrors every action regardless.
enum AutomationNotificationHealth: Sendable, Equatable {
    case checking
    case available
    case alertsDisabled
    case denied
    case notDetermined
    case unavailable

    var needsAttention: Bool {
        switch self {
        case .alertsDisabled, .denied, .notDetermined, .unavailable: true
        case .checking, .available: false
        }
    }
}

struct AutomationNotificationReceipt: Sendable, Equatable {
    var title: String
    var submittedAt: Date
    var acceptedBySystem: Bool
}

/// Routed actions (default body-click and the single button behave the
/// same — benchmark: one click anywhere).
enum AutomationNotificationAction: Sendable, Equatable {
    case record(code: String)
    case launchRecord(eventKey: String, code: String, title: String, urlString: String)
    case resume(meetingID: MeetingID)
    /// Handoff-warning click (L-3): activate the app and open the main window
    /// (where the queue banner and the Settings → handoff panel live).
    case openMainWindow
    /// G15 participant-confirmation click: activate the app and select the
    /// meeting so its pending banner (which hosts the confirm sheet) is visible.
    case participantConfirm(meetingID: MeetingID)
}

/// Mirrors every posted/withdrawn notification to the menu-bar surfaces
/// (the load-bearing equivalents when notifications are denied).
@MainActor protocol AutomationNotificationMirroring: AnyObject {
    func calendarReminderPosted(eventKey: String, title: String, code: String, urlString: String)
    func calendarReminderWithdrawn(eventKey: String)
    func notificationRequestCompleted(title: String, submittedAt: Date, acceptedBySystem: Bool)
}

final class AutomationNotificationAdapter: NSObject, AutomationNotifying,
    UNUserNotificationCenterDelegate, @unchecked Sendable
{
    private let logger = Logger(subsystem: BlaiseBundle.identifier, category: "automation.notify")
    /// Set by the composition root; actions route here.
    var onAction: (@Sendable (AutomationNotificationAction) async -> Void)?
    weak var mirror: (any AutomationNotificationMirroring)?
    /// Test/headless seam: the real center requires a bundle identity.
    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    func activate() {
        center.delegate = self
        let record = UNNotificationAction(
            identifier: AutomationNotificationCategory.recordAction, title: "Record",
            options: [.foreground])
        let launch = UNNotificationAction(
            identifier: AutomationNotificationCategory.launchRecordAction, title: "Launch & Record",
            options: [.foreground])
        let resume = UNNotificationAction(
            identifier: AutomationNotificationCategory.resumeAction, title: "Resume",
            options: [])
        let openBlaise = UNNotificationAction(
            identifier: AutomationNotificationCategory.openBlaiseAction, title: "Open Blaise",
            options: [.foreground])
        let confirmParticipants = UNNotificationAction(
            identifier: AutomationNotificationCategory.confirmParticipantsAction,
            title: "Confirm participants", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: AutomationNotificationCategory.meetStart, actions: [record],
                intentIdentifiers: []),
            UNNotificationCategory(
                identifier: AutomationNotificationCategory.calendarUpcoming, actions: [launch],
                intentIdentifiers: []),
            UNNotificationCategory(
                identifier: AutomationNotificationCategory.graceResume, actions: [resume],
                intentIdentifiers: []),
            // No button — a body click activates Blaise and opens the queue.
            UNNotificationCategory(
                identifier: AutomationNotificationCategory.handoffWarning, actions: [],
                intentIdentifiers: []),
            UNNotificationCategory(
                identifier: AutomationNotificationCategory.diagnostics, actions: [openBlaise],
                intentIdentifiers: []),
            UNNotificationCategory(
                identifier: AutomationNotificationCategory.participantConfirm,
                actions: [confirmParticipants], intentIdentifiers: []),
        ])
    }

    /// Human Touchpoint: fired at the first launch with automation enabled
    /// (docs/touchpoint_capture.md, Notifications section).
    func requestAuthorization() async {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            logger.notice("notification authorization: \(granted ? "granted" : "denied")")
        } catch {
            logger.error("notification authorization request failed: \(error)")
        }
    }

    func notificationHealth() async -> AutomationNotificationHealth {
        let settings = await center.notificationSettings()
        return Self.notificationHealth(
            authorizationStatus: settings.authorizationStatus,
            alertSetting: settings.alertSetting,
            notificationCenterSetting: settings.notificationCenterSetting)
    }

    static func notificationHealth(
        authorizationStatus: UNAuthorizationStatus,
        alertSetting: UNNotificationSetting,
        notificationCenterSetting: UNNotificationSetting
    ) -> AutomationNotificationHealth {
        switch authorizationStatus {
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        case .authorized, .provisional, .ephemeral:
            if alertSetting == .disabled || notificationCenterSetting == .disabled {
                return .alertsDisabled
            }
            return .available
        @unknown default:
            return .unavailable
        }
    }

    // MARK: - AutomationNotifying

    func postMeetStart(code: String, title: String?) async {
        let content = UNMutableNotificationContent()
        content.title = "Meeting in progress"
        content.body = title.map { "\(code) — \($0)" } ?? code
        content.categoryIdentifier = AutomationNotificationCategory.meetStart
        content.interruptionLevel = .active
        content.sound = .default
        content.userInfo = ["meetingCode": code]
        await post(id: meetStartID(code), content: content)
    }

    func withdrawMeetStart(code: String) async {
        withdraw(ids: [meetStartID(code)])
    }

    func postWatchdogStop(meetingID: MeetingID, title: String, canResume: Bool) async {
        let content = UNMutableNotificationContent()
        if canResume {
            content.title = "Recording stopped — meeting appears to have ended"
            content.body = "\(title) — click to resume if the meeting is still going."
            content.categoryIdentifier = AutomationNotificationCategory.graceResume
        } else {
            // Off means Off: no grace exists, a dead Resume button would be
            // worse than honesty.
            content.title = "Recording ended — uncertain signal"
            content.body = title
        }
        content.interruptionLevel = .active
        content.sound = .default
        content.userInfo = ["meetingID": meetingID]
        await post(id: "blaise.watchdog.\(meetingID)", content: content)
    }

    func withdrawWatchdogStop(meetingID: MeetingID) async {
        // Grace ended (resume / expiry / Finalize now / manual stop): a
        // stale "click to resume" hours later would be a dead surface.
        withdraw(ids: ["blaise.watchdog.\(meetingID)"])
    }

    /// Silence auto-pause: the `SilenceWatchdog` paused the recording after a
    /// sustained dual-track silence, so the user is never left with a silently
    /// missed capture. Informational (no action button): the meeting is held
    /// open and Resume lives in the menu / main window — a notification button
    /// would route through the grace path, which is the wrong resume here.
    func postSilenceAutoPause(meetingID: MeetingID, title: String, minutes: Int) async {
        let content = UNMutableNotificationContent()
        content.title = "Recording auto-paused — \(minutes) min of silence"
        content.body =
            "\(title) — both audio tracks were silent. Resume from the Blaise menu if the meeting is still going."
        content.interruptionLevel = .active
        content.sound = .default
        content.userInfo = ["meetingID": meetingID]
        await post(id: "blaise.silenceautopause.\(meetingID)", content: content)
    }

    func postNudge(meetingID: MeetingID, title: String) async {
        let content = UNMutableNotificationContent()
        content.title = "Recording running — no Meet signals yet"
        content.body = "\(title) — check that the meeting was joined in Chrome with the extension."
        content.interruptionLevel = .active
        content.sound = .default
        content.userInfo = ["meetingID": meetingID]
        await post(id: "blaise.nudge.\(meetingID)", content: content)
    }

    func postCalendarUpcoming(
        eventKey: String, title: String, start: Date, code: String, urlString: String?
    ) async {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = "Starts at \(formatter.string(from: start)) — opens in Google Chrome"
        content.categoryIdentifier = AutomationNotificationCategory.calendarUpcoming
        content.interruptionLevel = .active
        content.sound = .default
        let url = urlString ?? "https://meet.google.com/\(code)"
        content.userInfo = [
            "eventKey": eventKey, "meetingCode": code, "title": title, "url": url,
        ]
        await post(id: calendarID(eventKey), content: content)
        let mirror = self.mirror
        await MainActor.run {
            mirror?.calendarReminderPosted(eventKey: eventKey, title: title, code: code, urlString: url)
        }
    }

    func withdrawCalendarUpcoming(eventKey: String) async {
        withdraw(ids: [calendarID(eventKey)])
        let mirror = self.mirror
        await MainActor.run { mirror?.calendarReminderWithdrawn(eventKey: eventKey) }
    }

    /// Handoff persistent-failure warning: ONE notification per failure
    /// episode (the HandoffStatusHolder dedupes on episode key — never one
    /// per attempt). A fixed identifier keeps at most one in Notification
    /// Center (a newer episode replaces the older). Denied permission falls
    /// through `post`'s quiet failure — the banner and menu badge carry the
    /// load, same as every C14 surface.
    func postHandoffWarning(_ warning: HandoffWarning) async {
        let content = UNMutableNotificationContent()
        content.title = "Evidence Store unreachable"
        let plural = warning.meetingsWaiting == 1 ? "meeting" : "meetings"
        content.body = "\(warning.meetingsWaiting) \(plural) waiting since "
            + "\(warning.sinceLabel()). Last error: \(warning.shortReason)"
        content.categoryIdentifier = AutomationNotificationCategory.handoffWarning
        content.interruptionLevel = .active
        content.sound = .default
        await post(id: Self.handoffWarningID, content: content)
    }

    /// Delivery succeeded: the standing warning would be a stale dead
    /// surface — withdraw it silently (no success notification).
    func withdrawHandoffWarning() {
        withdraw(ids: [Self.handoffWarningID])
    }

    private static let handoffWarningID = "blaise.handoffwarning"

    /// G15: the participant-confirmation gate parked a meeting (posted once per
    /// park off the pipeline event, never per resume re-park). A body click / the
    /// "Confirm participants" action opens Blaise and selects the meeting, whose
    /// pending banner hosts the confirm sheet. A per-meeting id keeps at most one
    /// in Notification Center; the confirm/skip flow withdraws it.
    func postParticipantConfirmation(meetingID: MeetingID, title: String) async {
        let content = UNMutableNotificationContent()
        content.title = "Confirm participants"
        content.body = title.isEmpty
            ? "Confirm who was in this meeting so its notes can be written."
            : "\(title) — confirm who was there so notes can be written."
        content.categoryIdentifier = AutomationNotificationCategory.participantConfirm
        content.interruptionLevel = .active
        content.sound = .default
        content.userInfo = ["meetingID": meetingID]
        await post(id: participantConfirmID(meetingID), content: content)
    }

    /// Withdrawn when the meeting leaves the gate (Confirm / Skip): a stale
    /// "confirm participants" surface would be dead.
    func withdrawParticipantConfirmation(meetingID: MeetingID) {
        withdraw(ids: [participantConfirmID(meetingID)])
    }

    private func participantConfirmID(_ meetingID: MeetingID) -> String {
        "blaise.participantconfirm.\(meetingID)"
    }

    /// Chrome missing / launch failure: no recording start (recording an
    /// unjoined meeting is empty audio, worse than nothing).
    func postChromeLaunchFailure(title: String) async {
        let content = UNMutableNotificationContent()
        content.title = "Couldn't open Google Chrome"
        content.body = "\(title) — open the Meet link in Chrome manually, then click Record."
        content.interruptionLevel = .active
        content.sound = .default
        await post(id: "blaise.chromefail.\(UUID().uuidString)", content: content)
    }

    /// User-invoked smoke only: no tracker signal, meeting, recording,
    /// evidence, or handoff is created. This proves banners and their action
    /// category for the exact app identity currently running.
    func postDiagnosticsTest() async {
        let content = UNMutableNotificationContent()
        content.title = "Blaise notification test"
        content.body = "Banners and notification actions are working."
        content.categoryIdentifier = AutomationNotificationCategory.diagnostics
        content.interruptionLevel = .active
        content.sound = .default
        await post(id: "blaise.diagnostics.\(UUID().uuidString)", content: content)
    }

    private func meetStartID(_ code: String) -> String { "blaise.meetstart.\(code)" }
    private func calendarID(_ key: String) -> String { "blaise.calendar.\(key)" }

    private func post(id: String, content: UNNotificationContent) async {
        let acceptedBySystem: Bool
        do {
            try await center.add(
                UNNotificationRequest(identifier: id, content: content, trigger: nil))
            acceptedBySystem = true
            logger.info("notification request submitted to macOS (\(id, privacy: .public))")
        } catch {
            // Denied / restricted: the menu-bar surfaces carry the load.
            acceptedBySystem = false
            logger.notice("notification post failed (\(id, privacy: .public)): \(error)")
        }
        let mirror = self.mirror
        let title = content.title
        let submittedAt = Date()
        await MainActor.run {
            mirror?.notificationRequestCompleted(
                title: title, submittedAt: submittedAt, acceptedBySystem: acceptedBySystem)
        }
    }

    private func withdraw(ids: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Banners show while the menu-bar agent is frontmost too.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let content = response.notification.request.content
        let info = content.userInfo
        let actionID = response.actionIdentifier
        // Default (body click) and the single button behave the same;
        // dismiss = decline (the suppression record stands).
        guard actionID != UNNotificationDismissActionIdentifier else { return }
        let action = Self.action(
            categoryIdentifier: content.categoryIdentifier, userInfo: info)
        if let action, let onAction {
            await onAction(action)
        }
    }

    static func action(
        categoryIdentifier: String, userInfo info: [AnyHashable: Any]
    ) -> AutomationNotificationAction? {
        switch categoryIdentifier {
        case AutomationNotificationCategory.meetStart:
            return (info["meetingCode"] as? String).map { .record(code: $0) }
        case AutomationNotificationCategory.calendarUpcoming:
            if let key = info["eventKey"] as? String, let code = info["meetingCode"] as? String,
                let title = info["title"] as? String, let url = info["url"] as? String
            {
                return .launchRecord(eventKey: key, code: code, title: title, urlString: url)
            }
            return nil
        case AutomationNotificationCategory.graceResume:
            return (info["meetingID"] as? String).map { .resume(meetingID: $0) }
        case AutomationNotificationCategory.handoffWarning,
             AutomationNotificationCategory.diagnostics:
            return .openMainWindow
        case AutomationNotificationCategory.participantConfirm:
            return (info["meetingID"] as? String).map { .participantConfirm(meetingID: $0) }
        default:
            return nil
        }
    }
}
