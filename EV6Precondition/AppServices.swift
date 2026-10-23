import Foundation
import PreconditionKit

/// The app's long-lived pieces.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let obd = OBDService()
    let prefs = Preferences.shared
    let battery = BatteryReportStore.shared
    let runs = RunStore.shared

    private init() {}

    func prepare() async {
        await battery.load()
        await runs.load()
    }
}
