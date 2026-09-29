import Foundation
import PreconditionKit
import UserNotifications

/// Local notifications: "Starting climate · 21.0 °C" with a Stop climate button, alerts about the car, and
/// problems such as a rejected login.
final class LocalNotifier: NSObject, Notifier, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let commandCategory = "COMMAND"
    static let stopAction = "STOP_CLIMATE"
    static let smartCategory = "SMART_CHARGE"
    static let startChargingAction = "START_CHARGING"
    static let smartReminderID = "smart-charge-start"
    static let unlockedCategory = "LEFT_UNLOCKED"
    static let lockAction = "LOCK_CAR"
    /// Command notices share one id, so "confirmed" replaces "sent" rather than stacking.
    static let commandID = "command"
    /// userInfo key: "settings" when tapping should open Settings.
    static let openKey = "open"

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
    /// Runs when a problem that needs Settings (such as a rejected sign-in) is tapped.
    var onOpenSettings: (@MainActor () -> Void)?
    /// Set when such a problem was tapped before `onOpenSettings` was set (a cold launch); the app
    /// reads it once it's ready and clears it.
    @MainActor var openSettingsPending = false

    func register() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let stop = UNNotificationAction(identifier: Self.stopAction, title: "Stop climate", options: [])
        let category = UNNotificationCategory(identifier: Self.commandCategory, actions: [stop], intentIdentifiers: [], options: [])
        // Runs in the background: no need to open the app.
        let start = UNNotificationAction(identifier: Self.startChargingAction, title: "Start charging", options: [])
        let smart = UNNotificationCategory(identifier: Self.smartCategory, actions: [start], intentIdentifiers: [], options: [])
        // Start runs in the background; the others just reschedule or dismiss.
        let ask = UNNotificationCategory(identifier: Self.askCategory, actions: [
            UNNotificationAction(identifier: Self.askStart, title: "Start climate", options: []),
            UNNotificationAction(identifier: Self.askLater, title: "In 15 min", options: []),
            UNNotificationAction(identifier: Self.askSkip, title: "Not today", options: [.destructive]),
        ], intentIdentifiers: [], options: [])
        let lock = UNNotificationAction(identifier: Self.lockAction, title: "Lock", options: [])
        let unlocked = UNNotificationCategory(identifier: Self.unlockedCategory, actions: [lock], intentIdentifiers: [], options: [])
        center.setNotificationCategories([category, smart, ask, unlocked])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func commandSent(title: String, text: String, canStop: Bool) async {
        await post(title: title, text: text, category: canStop ? Self.commandCategory : nil, id: Self.commandID)
    }

    func problem(title: String, text: String, openSettings: Bool) async {
        await post(title: title, text: text, category: nil, userInfo: openSettings ? [Self.openKey: "settings"] : [:])
    }

    /// A plain notice, e.g. the commute check's result.
    func note(title: String, text: String) async {
        await post(title: title, text: text, category: nil)
    }

    func alert(_ alert: CarAlert) async {
        await post(title: alert.title, text: alert.body, category: alert.kind == .leftUnlocked ? Self.unlockedCategory : nil)
    }

    /// The evening "not plugged in yet" reminder; replaces any earlier one. Nil cancels it.
    func schedulePlugReminder(at date: Date?, title: String, text: String) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["plug-reminder"])
        guard let date, date > Date() else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = text
        content.sound = .default
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let request = UNNotificationRequest(identifier: "plug-reminder", content: content,
                                            trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
        try? await center.add(request)
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
        content.sound = .default
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
        content.sound = .default
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

    private func post(title: String, text: String, category: String?, id: String? = nil, userInfo: [String: String] = [:]) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = text
        content.sound = .default
        if let category { content.categoryIdentifier = category }
        if !userInfo.isEmpty { content.userInfo = userInfo as [AnyHashable: Any] }
        let request = UNNotificationRequest(identifier: id ?? UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Command notices echo what the owner just did in the app: keep them in the list, no banner.
        if notification.request.identifier == Self.commandID {
            completionHandler([.list])
        } else {
            completionHandler([.banner, .list, .sound])
        }
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
            default: answer = .opened
            }
            Task { @MainActor in
                await onAsk(ruleId, answer)
                completionHandler()
            }
            return
        }
        if response.actionIdentifier == Self.lockAction {
            Task { @MainActor in
                _ = await GlanceSync.shared.perform(.lock)
                completionHandler()
            }
            return
        }
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           response.notification.request.content.userInfo[Self.openKey] as? String == "settings" {
            let open = onOpenSettings
            Task { @MainActor in
                if let open { open() } else { self.openSettingsPending = true }
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
