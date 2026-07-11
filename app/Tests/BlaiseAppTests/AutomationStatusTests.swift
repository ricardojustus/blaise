import Foundation
import Testing
import UserNotifications

@testable import BlaiseApp

@MainActor
struct AutomationStatusTests {
    @Test("notification health distinguishes authorization from banner presentation")
    func notificationPresentationHealth() {
        #expect(
            AutomationNotificationAdapter.notificationHealth(
                authorizationStatus: .authorized,
                alertSetting: .enabled,
                notificationCenterSetting: .enabled) == .available)
        #expect(
            AutomationNotificationAdapter.notificationHealth(
                authorizationStatus: .authorized,
                alertSetting: .disabled,
                notificationCenterSetting: .enabled) == .alertsDisabled)
        #expect(
            AutomationNotificationAdapter.notificationHealth(
                authorizationStatus: .authorized,
                alertSetting: .enabled,
                notificationCenterSetting: .disabled) == .alertsDisabled)
        #expect(
            AutomationNotificationAdapter.notificationHealth(
                authorizationStatus: .denied,
                alertSetting: .enabled,
                notificationCenterSetting: .enabled) == .denied)
        #expect(
            AutomationNotificationAdapter.notificationHealth(
                authorizationStatus: .notDetermined,
                alertSetting: .enabled,
                notificationCenterSetting: .enabled) == .notDetermined)
    }

    @Test("listener health records requests and app acceptance separately")
    func listenerReceipts() {
        let holder = ListenerStatusHolder()
        let requestAt = Date(timeIntervalSince1970: 100)
        let responseAt = Date(timeIntervalSince1970: 101)

        holder.state = .listening
        holder.noteRequest(at: requestAt)
        holder.noteResponse(status: 200, at: responseAt)

        #expect(holder.state == .listening)
        #expect(holder.lastRequestAt == requestAt)
        #expect(holder.lastResponse == MeetListenerReceipt(status: 200, receivedAt: responseAt))
        #expect(holder.banner == nil)
    }

    @Test("listener failure retains the Settings explanation")
    func listenerFailureBanner() {
        let holder = ListenerStatusHolder()
        holder.state = .unavailable("Meet events are buffering")

        #expect(holder.isUnavailable)
        #expect(holder.banner == "Meet events are buffering")
    }

    @Test("capture holder retains the current notification presentation state")
    func captureNotificationHealth() {
        let holder = CaptureStatusHolder()
        holder.notificationHealth = .available
        #expect(holder.notificationHealth == .available)
        holder.notificationHealth = .denied
        #expect(holder.notificationHealth == .denied)
    }

    @Test("notification categories route visible actions to app commands")
    func notificationActionRouting() {
        #expect(
            AutomationNotificationAdapter.action(
                categoryIdentifier: AutomationNotificationCategory.meetStart,
                userInfo: ["meetingCode": "abc-defg-hij"])
                == .record(code: "abc-defg-hij"))
        #expect(
            AutomationNotificationAdapter.action(
                categoryIdentifier: AutomationNotificationCategory.graceResume,
                userInfo: ["meetingID": "meeting-1"])
                == .resume(meetingID: "meeting-1"))
        #expect(
            AutomationNotificationAdapter.action(
                categoryIdentifier: AutomationNotificationCategory.diagnostics,
                userInfo: [:]) == .openMainWindow)
        #expect(
            AutomationNotificationAdapter.action(
                categoryIdentifier: "unknown", userInfo: [:]) == nil)
    }
}
