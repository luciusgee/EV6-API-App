import Foundation
import PreconditionKit

/// One set of services for the app and its App Intents (Shortcuts and Siri run in the app's process).
@MainActor
final class AppServices {
    static let shared = AppServices()

    let notifier: LocalNotifier
    let container: AppContainer
    let car: CarModel
    let rules: RulesModel
    let charging: ChargingModel
    let obd = OBDService()
    private var prepared = false

    private init() {
        let notifier = LocalNotifier()
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let container = AppContainer(
            directory: support.appendingPathComponent("EV6Precondition", isDirectory: true),
            credentials: KeychainCredentialsStore(),
            sessions: KeychainSessionStore(account: "kia-session"),
            // Fake-car mode gets its own slot so it never overwrites a real, possibly rotated, token.
            fakeSessions: KeychainSessionStore(account: "kia-session-fake"),
            notifier: notifier,
            phone: LocationPhoneLocator()
        )
        // The fake car takes a few seconds to confirm commands, like the real one.
        container.fakeCar.state.confirmAfter = 6
        let car = CarModel(container: container)
        self.notifier = notifier
        self.container = container
        self.car = car
        self.rules = RulesModel(container: container)
        self.charging = ChargingModel(directory: support.appendingPathComponent("EV6Precondition", isDirectory: true), transport: URLSessionTransport())
        notifier.onStop = {
            await car.stop()
        }
        notifier.onStartCharging = {
            await ChargingCoordinator.shared.startChargingFromReminder()
        }
        ChargingCoordinator.shared.registerBackgroundRefresh()
        let engine = container.engine
        // Created now, not later: iOS relaunches the app for a crossed boundary and delivers it at once.
        GeofenceMonitor.shared.onEvent = { event, at in
            await AppServices.shared.prepare()
            await BackgroundTrigger.run(event, at: at, engine: engine)
            await AppServices.shared.car.load()
        }
        rules.onChange = { rules, places in
            GeofenceMonitor.shared.sync(rules: rules, places: places, carPosition: car.snapshot?.parkingPosition)
        }
        // Now, not later: the Watch can wake the app in the background with a command.
        GlanceSync.shared.start(car: car)
    }

    /// Loads settings and state once; safe to call from every entry point.
    func prepare() async {
        guard !prepared else { return }
        prepared = true
        notifier.register()
        await car.load()
        await charging.load()
        // The fake car was a development aid; the app only talks to the real car now.
        if car.settings.fakeMode {
            await car.updateSettings { $0.fakeMode = false }
        }
        await rules.load()
        // Near-car rules need a recent parked position for their fence.
        if await container.engine.refreshCarPositionIfDue() {
            await car.load()
            await rules.load()
        }
        charging.replan(soc: car.snapshot?.socPercent)
        ChargingCoordinator.shared.scheduleBackgroundRefresh()
        if charging.pricesStale {
            Task { await charging.refreshPrices() }
        }
    }
}
