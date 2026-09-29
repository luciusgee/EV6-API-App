import BackgroundTasks
import Foundation
import PreconditionKit

/// Acts on each new reading of the car: records charges, sends alerts, and carries out the smart-charging
/// plan. Also reads the car in the background now and then (within the automation budget) so alerts
/// and smart charging don't depend on the app being open.
@MainActor
final class ChargingCoordinator {
    static let shared = ChargingCoordinator()
    static let refreshTaskID = "com.luciusgee.ev6precondition.refresh"
    /// How soon to ask iOS for the next background check while charging. iOS decides when it
    /// really runs, often later.
    static let chargingCheckEvery: TimeInterval = 15 * 60

    private var lastProcessed: Date?
    private var lastAction: Date?

    /// Must run before the app finishes launching.
    func registerBackgroundRefresh() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskID, using: .main) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            let work = Task { @MainActor in
                await ChargingCoordinator.shared.runBackgroundRefresh()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    /// Asks iOS for the next background read: the owner's interval, or sooner for a smart-charge window.
    func scheduleBackgroundRefresh() {
        let charging = AppServices.shared.charging
        let alerts = charging.settings.alerts
        guard alerts.backgroundChecks || charging.settings.smart.enabled else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshTaskID)
            return
        }
        var earliest = Date().addingTimeInterval(Double(alerts.backgroundEveryHours) * 3600)
        if let start = charging.plan?.start, start > Date() {
            earliest = min(earliest, start.addingTimeInterval(60))
        }
        // While charging, check often so the Live Activity and widgets keep up.
        if alerts.backgroundChecks, AppServices.shared.car.snapshot?.chargingState == .charging {
            earliest = min(earliest, Date().addingTimeInterval(Self.chargingCheckEvery))
        }
        if alerts.backgroundChecks, let snapshot = AppServices.shared.car.snapshot, snapshot.pluggedIn == true,
           snapshot.chargingState != .charging, let window = snapshot.details?.offPeak {
            // Just after the off-peak window should have started, to catch a charger that never did.
            let startsAt = Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: window.start.hour, minute: window.start.minute),
                                                     matchingPolicy: .nextTime)
            if let startsAt { earliest = min(earliest, startsAt.addingTimeInterval(25 * 60)) }
        }
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        request.earliestBeginDate = earliest
        try? BGTaskScheduler.shared.submit(request)
    }

    private func runBackgroundRefresh() async {
        let services = AppServices.shared
        await services.prepare()
        scheduleBackgroundRefresh()
        if services.charging.pricesStale { await services.charging.refreshPrices() }
        // Fresh forecasts for the week's "ask first" questions.
        await AskCoordinator.shared.rebook()
        // Time at places by car: today's trips, one request at most.
        await services.presence.refreshCarTrips(days: 2, maxRequests: 1, kind: .automation)
        // An automation request: it leaves the reserve for the owner's own taps. While the car is
        // charging, ask the car itself: its main battery is feeding the 12 V, so waking it costs nothing,
        // and Kia's saved copy barely changes during a charge.
        let charging = services.car.snapshot?.chargingState == .charging
        _ = await services.container.vehicles.fetch(.automation, wake: charging)
        await services.car.load()
        if let snapshot = services.car.snapshot { await handle(snapshot) }
    }

    /// Called whenever the app has a new reading of the car.
    func handle(_ snapshot: VehicleSnapshot) async {
        guard snapshot.fetchedAt != lastProcessed else { return }
        lastProcessed = snapshot.fetchedAt
        let services = AppServices.shared
        await services.presence.sawCar(snapshot)
        let outcome = await services.charging.process(snapshot, home: home)
        for alert in outcome.alerts {
            await services.notifier.alert(alert)
        }
        await act(outcome.decision)
        await rebookPlugReminder()
        await remindAtWindowStart()
        scheduleBackgroundRefresh()
    }

    /// Home for costing charges: a place called Home, else the first place.
    var home: LatLon? {
        let places = AppServices.shared.rules.places
        return (places.first { $0.name.localizedCaseInsensitiveContains("home") } ?? places.first)?.centre
    }

    private func act(_ decision: SmartCharging.Decision) async {
        guard decision != .nothing else { return }
        // Never flip-flop: one smart-charging command per quarter hour at most.
        if let lastAction, Date().timeIntervalSince(lastAction) < 15 * 60 { return }
        lastAction = Date()
        let car = AppServices.shared.car
        switch decision {
        case .startCharging: await car.send(.startCharging)
        case .stopCharging: await car.send(.stopCharging)
        case .nothing: break
        }
    }

    /// iOS can't promise a background wake at an exact time, so the cheapest window also gets a
    /// notification with a Start Charging button that works from the Lock Screen.
    func remindAtWindowStart() async {
        let charging = AppServices.shared.charging
        guard charging.settings.smart.enabled, let plan = charging.plan else {
            await AppServices.shared.notifier.scheduleSmartReminder(at: nil, title: "", text: "")
            return
        }
        let cost = DisplayText.money(pence: plan.costPence)
        await AppServices.shared.notifier.scheduleSmartReminder(
            at: plan.start,
            title: "Cheapest charging starts now",
            text: String(format: "%.1f kWh to %d%% for about %@ (%.1fp/kWh). The app starts it if it can; tap Start Charging if it hasn't.",
                         plan.kWh, plan.targetPercent, cost, plan.averagePence)
        )
    }

    /// Books tonight's (or tomorrow's) "not plugged in yet" reminder from the latest reading.
    func rebookPlugReminder() async {
        let services = AppServices.shared
        let reminder = services.charging.settings.alerts.plugReminder
        let snapshot = services.car.snapshot
        let at = reminder.next(after: Date(), snapshot: snapshot)
        let words = PlugReminder.message(snapshot: snapshot, now: Date())
        await services.notifier.schedulePlugReminder(at: at, title: words.title, text: words.body)
    }

    /// From the reminder's button.
    func startChargingFromReminder() async {
        let services = AppServices.shared
        await services.prepare()
        lastAction = Date()
        await services.car.send(.startCharging)
    }
}
