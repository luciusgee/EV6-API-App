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

    static let askCategory = "ASK_RULE"
    static let askStart = "ASK_START"
    static let askLater = "ASK_LATER"
    static let askSkip = "ASK_SKIP"
    static let askPrefix = "ask-"

    enum AskAnswer { case start, later, skip, opened }
    /// Runs when an "ask first" question is answered, or tapped to open the app.
    var onAsk: (@MainActor (_ ruleId: String, _ answer: AskAnswer) async -> Void)?

    func register() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let stop = UNNotificationAction(identifier: Self.stopAction, title: "Stop", options: [])
        let category = UNNotificationCategory(identifier: Self.commandCategory, actions: [stop], intentIdentifiers: [], options: [])
        // Runs in the background: no need to open the app.
        let start = UNNotificationAction(identifier: Self.startChargingAction, title: "Start Charging", options: [])
        let smart = UNNotificationCategory(identifier: Self.smartCategory, actions: [start], intentIdentifiers: [], options: [])
        // Start runs in the background; the others just reschedule or dismiss.
        let ask = UNNotificationCategory(identifier: Self.askCategory, actions: [
            UNNotificationAction(identifier: Self.askStart, title: "Start climate", options: []),
            UNNotificationAction(identifier: Self.askLater, title: "In 15 min", options: []),
            UNNotificationAction(identifier: Self.askSkip, title: "Not today", options: [.destructive]),
        ], intentIdentifiers: [], options: [])
        center.setNotificationCategories([category, smart, ask])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func commandSent(title: String, text: String, canStop: Bool) async {
        await post(title: title, text: text, category: canStop ? Self.commandCategory : nil)
    }

    func problem(title: String, text: String, openSettings: Bool) async {
        await post(title: title, text: text, category: nil)
    }

    /// A plain notice, e.g. the commute check's result.
    func note(title: String, text: String) async {
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

    /// An "ask first" rule is due now.
    func ask(ruleId: String, title: String, text: String) async {
        await book(id: "\(Self.askPrefix)\(ruleId)-now", ruleId: ruleId, title: title, text: text, at: nil)
    }

    /// Books (or, with `at` nil, sends) one ask. The same id replaces an earlier one.
    func book(id: String, ruleId: String, title: String, text: String, at date: Date?) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = text
        content.categoryIdentifier = Self.askCategory
        content.userInfo = ["ruleId": ruleId]
        var trigger: UNNotificationTrigger?
        if let date {
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        }
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    /// Replaces every booked (future) ask with `asks`.
    func rebook(_ asks: [(id: String, ruleId: String, title: String, text: String, at: Date)]) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let keep = Set(asks.map(\.id))
        let stale = pending.map(\.identifier).filter { $0.hasPrefix(Self.askPrefix) && !$0.hasSuffix("-later") && !keep.contains($0) }
        center.removePendingNotificationRequests(withIdentifiers: stale)
        for a in asks {
            await book(id: a.id, ruleId: a.ruleId, title: a.title, text: a.text, at: a.at)
        }
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
        if response.notification.request.content.categoryIdentifier == Self.askCategory,
           let ruleId = response.notification.request.content.userInfo["ruleId"] as? String, let onAsk {
            let answer: AskAnswer
            switch response.actionIdentifier {
            case Self.askStart: answer = .start
            case Self.askLater: answer = .later
            case Self.askSkip: answer = .skip
            case UNNotificationDismissActionIdentifier: answer = .skip
            default: answer = .opened
            }
            Task { @MainActor in
                await onAsk(ruleId, answer)
                completionHandler()
            }
            return
        }
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
