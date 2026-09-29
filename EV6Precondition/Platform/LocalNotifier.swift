import Foundation
import PreconditionKit
import UserNotifications

/// Local notifications: "Preconditioning to 21.0 °C" with a Stop button, and problems such as a rejected login.
final class LocalNotifier: NSObject, Notifier, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let commandCategory = "COMMAND"
    static let stopAction = "STOP_CLIMATE"
    static let smartCategory = "SMART_CHARGE"
    static let startChargingAction = "START_CHARGING"
    static let smartReminderID = "smart-charge-start"

    /// Set once at launch; runs when the user taps Stop on a notification.
    var onStop: (@MainActor () async -> Void)?
    /// Runs when the user taps Start Charging on the cheapest-window reminder.
    var onStartCharging: (@MainActor () async -> Void)?

    func register() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let stop = UNNotificationAction(identifier: Self.stopAction, title: "Stop", options: [])
        let category = UNNotificationCategory(identifier: Self.commandCategory, actions: [stop], intentIdentifiers: [], options: [])
        // Runs in the background: no need to open the app.
        let start = UNNotificationAction(identifier: Self.startChargingAction, title: "Start Charging", options: [])
        let smart = UNNotificationCategory(identifier: Self.smartCategory, actions: [start], intentIdentifiers: [], options: [])
        center.setNotificationCategories([category, smart])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func commandSent(title: String, text: String, canStop: Bool) async {
        await post(title: title, text: text, category: canStop ? Self.commandCategory : nil)
    }

    func problem(title: String, text: String, openSettings: Bool) async {
        await post(title: title, text: text, category: nil)
    }

    func alert(_ alert: CarAlert) async {
        await post(title: alert.title, text: alert.body, category: nil)
    }

    /// The reminder at the start of the cheapest charging window; replaces any earlier one.
    func scheduleSmartReminder(at date: Date?, title: String, text: String) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.smartReminderID])
        guard let date, date > Date() else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = text
        content.categoryIdentifier = Self.smartCategory
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let request = UNNotificationRequest(
            identifier: Self.smartReminderID, content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        )
        try? await center.add(request)
    }

    private func post(title: String, text: String, category: String?) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = text
        if let category { content.categoryIdentifier = category }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == Self.startChargingAction, let onStartCharging {
            Task { @MainActor in
                await onStartCharging()
                completionHandler()
            }
            return
        }
        guard response.actionIdentifier == Self.stopAction, let onStop else {
            completionHandler()
            return
        }
        Task { @MainActor in
            await onStop()
            completionHandler()
        }
    }
}
