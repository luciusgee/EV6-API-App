import Foundation
import PreconditionKit
import UserNotifications

/// Local notifications: "Preconditioning to 21.0 °C" with a Stop button, and problems such as a rejected login.
final class LocalNotifier: NSObject, Notifier, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let commandCategory = "COMMAND"
    static let stopAction = "STOP_CLIMATE"

    /// Set once at launch; runs when the user taps Stop on a notification.
    var onStop: (@MainActor () async -> Void)?

    func register() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let stop = UNNotificationAction(identifier: Self.stopAction, title: "Stop", options: [])
        let category = UNNotificationCategory(identifier: Self.commandCategory, actions: [stop], intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func commandSent(title: String, text: String, canStop: Bool) async {
        await post(title: title, text: text, category: canStop ? Self.commandCategory : nil)
    }

    func problem(title: String, text: String, openSettings: Bool) async {
        await post(title: title, text: text, category: nil)
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
