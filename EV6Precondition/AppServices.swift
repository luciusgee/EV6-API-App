import BackgroundTasks
import CoreLocation
import Foundation
import PreconditionKit
import Security
import UserNotifications

/// The app's long-lived pieces.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let obd = OBDService()
    let prefs = Preferences.shared
    let battery = BatteryReportStore.shared
    let runs = RunStore.shared
    let charges = ChargeStore.shared
    let store = Store.shared

    private init() {}

    func prepare() async {
        LegacyCleanup.run()
        await battery.load()
        await runs.load()
        await charges.load()
        // A charge left unfinished last time: saved to the history now if it's over 3 h old
        // (OBDService.chargeGap), else kept waiting and carried on once the car answers.
        obd.recoverCharge(resume: false)
        await store.start()
    }
}

/// Clears what the Kia Connect builds (same bundle ID, TestFlight only) left behind: the Kia
/// sign-in in the Keychain, repeating commute reminders, geofences, background tasks and their
/// files. Once per install; fresh installs have nothing to clear, so it's a no-op for them.
@MainActor
enum LegacyCleanup {
    private static let doneKey = "legacyCleaned_v1"

    private static let keychainServices = ["EV6Precondition.credentials", "EV6Precondition.session", "EV6Precondition.keys"]

    /// In Application Support/EV6Precondition. Runs, laps, charges and battery-*.json are still in use.
    private static let files = [
        "rules.json", "presence.json", "car-movements.json", "commutes.json", "trips.json", "food-chains.json",
        "vehicle.json", "log.json", "settings.json", "budget.json", "automation.json", "energy.json",
        "charging-settings.json", "charging.json", "agile-prices.json", "alerts.json", "alerts-previous.json",
    ]

    /// `liveSensors` and `liveWindow` are still used by the live data screen.
    private static let defaultsKeys = ["carKind", "carPaint", "guideSeenRelease", "dismissedSuggestions", "lastNavDestination", "performanceRuns"]

    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }

        for service in keychainServices {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
            SecItemDelete(query as CFDictionary)
        }

        // The app books no notifications, background tasks or regions of its own any more.
        let notifications = UNUserNotificationCenter.current()
        notifications.removeAllPendingNotificationRequests()
        notifications.removeAllDeliveredNotifications()
        BGTaskScheduler.shared.cancelAllTaskRequests()
        let location = CLLocationManager()
        for region in location.monitoredRegions {
            location.stopMonitoring(for: region)
        }

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EV6Precondition", isDirectory: true)
        for name in files {
            try? FileManager.default.removeItem(at: support.appendingPathComponent(name))
        }

        for key in defaultsKeys {
            defaults.removeObject(forKey: key)
        }
        defaults.set(true, forKey: doneKey)
    }
}
