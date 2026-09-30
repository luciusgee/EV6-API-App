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
    let presence: PresenceModel
    let commute: CommuteModel
    let trips: TripsModel
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
        self.presence = PresenceModel(directory: support.appendingPathComponent("EV6Precondition", isDirectory: true))
        let commute = CommuteModel(directory: support.appendingPathComponent("EV6Precondition", isDirectory: true))
        // Google's traffic when there's a key (it follows your via points exactly), else Apple Maps.
        commute.timer = {
            if let key = ChargerKeys.google { return GoogleRoutesClient(transport: URLSessionTransport(), key: key) }
            return AppleDriveTimer()
        }
        self.commute = commute
        self.trips = TripsModel(directory: support.appendingPathComponent("EV6Precondition", isDirectory: true))
        self.charging = ChargingModel(directory: support.appendingPathComponent("EV6Precondition", isDirectory: true), transport: URLSessionTransport())
        notifier.onStop = {
            await car.stop()
        }
        notifier.onAsk = { ruleId, answer in
            await AskCoordinator.shared.answer(ruleId, answer)
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
        rules.onChange = { _, _ in
            AppServices.shared.syncGeofences()
            Task { await AskCoordinator.shared.rebook() }
        }
        commute.onChange = { list in
            AppServices.shared.syncGeofences()
            Task { await notifier.bookCommuteReminders(list) }
        }
        GeofenceMonitor.shared.onLeftCommuteStart = { id in
            await CommuteCoordinator.leftStart(id)
        }
        let presence = self.presence
        let engine2 = container.engine
        presence.fetchTrips = { day, kind in await engine2.trips(on: day, kind: kind) }
        let rulesModel = rules
        presence.places = { rulesModel.places }
        // Now, not later: the Watch can wake the app in the background with a command.
        GlanceSync.shared.start(car: car)
    }

    /// Watches the places the rules need and the starts of commutes that check on leaving.
    func syncGeofences() {
        GeofenceMonitor.shared.sync(rules: rules.rules, places: rules.places, carPosition: car.snapshot?.parkingPosition,
                                    extra: commute.commutes.compactMap(\.leaveRegion))
    }

    /// Loads settings and state once; safe to call from every entry point.
    func prepare() async {
        guard !prepared else { return }
        prepared = true
        notifier.register()
        await car.load()
        await charging.load()
        await presence.load()
        await commute.load()
        await trips.load()
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
        Task { await ChargingCoordinator.shared.rebookPlugReminder() }
        Task { await AskCoordinator.shared.rebook() }
        if charging.pricesStale {
            Task { await charging.refreshPrices() }
        }
    }
}
