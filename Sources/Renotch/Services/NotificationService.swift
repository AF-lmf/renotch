import AppKit
import Foundation
import UserNotifications

final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()
    static let updateNotificationID = "virtual-notch-update"

    private var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    private override init() {
        super.init()
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    func requestAuthorization() {
        center?.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // Deliver banners and sound even when app is frontmost or accessory
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge, .list])
    }

    // Clicking an update notification opens its release page.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let request = response.notification.request
        if request.identifier == Self.updateNotificationID,
           response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           let page = (request.content.userInfo["releasePage"] as? String).flatMap(URL.init(string:)) {
            DispatchQueue.main.async { NSWorkspace.shared.open(page) }
        }
        completionHandler()
    }

    /// Posts a silent "update available" notification, replacing any earlier
    /// one. Returns `false` without posting when there is no bundle identifier
    /// or notifications are not allowed, so the caller only records versions
    /// the user could have seen.
    func postUpdateAvailable(version: String, installed: String, releasePage: URL) async -> Bool {
        guard let center else { return false }
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return false }

        let content = UNMutableNotificationContent()
        content.title = "Update Available"
        content.body = "Re:notch \(version) is available (you have \(installed)). Click to open the download page."
        content.userInfo = ["releasePage": releasePage.absoluteString]

        let request = UNNotificationRequest(identifier: Self.updateNotificationID, content: content, trigger: nil)
        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }

    func playTimerSound() {
        if let sound = NSSound(named: "Glass") ?? NSSound(named: "Ping") {
            sound.play()
        } else {
            NSSound.beep()
        }
    }

    /// Schedule an OS-level notification so it fires even if the app quits or
    /// the Mac sleeps. Returns the request identifier (needed to cancel).
    @discardableResult
    func scheduleTimerFinished(
        after interval: TimeInterval,
        mode: PomodoroMode = .focus,
        breakMinutes: Int = 5,
        autoAdvance: Bool = true
    ) -> String {
        let id = "virtual-notch-timer-\(UUID().uuidString)"
        guard let center else { return id }

        let content = UNMutableNotificationContent()
        switch mode {
        case .focus:
            content.title = "Focus Session Finished"
            content.body = autoAdvance
                ? "Great work! Starting \(breakMinutes)-minute break now."
                : "Great work! Time to take a break."
        case .breakTime:
            content.title = "Break Finished"
            content.body = "Ready to start your next focus session?"
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: id,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(0.5, interval), repeats: false)
        )
        center.add(request)
        return id
    }

    func cancelScheduled(_ id: String) {
        guard !id.isEmpty else { return }
        center?.removePendingNotificationRequests(withIdentifiers: [id])
    }

    func timerFinished(mode: PomodoroMode = .focus, breakMinutes: Int = 5, autoAdvance: Bool = true) {
        playTimerSound()

        guard let center else { return }
        let content = UNMutableNotificationContent()
        switch mode {
        case .focus:
            content.title = "Focus Session Finished"
            content.body = autoAdvance
                ? "Great work! Starting \(breakMinutes)-minute break now."
                : "Great work! Time to take a break."
        case .breakTime:
            content.title = "Break Finished"
            content.body = "Ready to start your next focus session?"
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "virtual-notch-timer-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        center.add(request)
    }
}

