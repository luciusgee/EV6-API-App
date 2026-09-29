import Foundation
import Observation
import PreconditionKit
import WatchConnectivity
import WidgetKit

/// Keeps the widgets and the Watch showing what the app knows: whenever the car's state or the last
/// result changes, the new `CarGlance` goes to the shared Keychain slot (widgets) and to the Watch.
/// Also carries out commands the Watch sends.
@MainActor
final class GlanceSync: NSObject {
    static let shared = GlanceSync()

    private var car: CarModel?
    private var last: CarGlance?
    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }

    func start(car: CarModel) {
        guard self.car == nil else { return }
        self.car = car
        if let session {
            session.delegate = self
            session.activate()
        }
        observe()
    }

    private var lastSnapshotAt: Date?

    private func observe() {
        guard let car else { return }
        if let snapshot = car.snapshot, snapshot.fetchedAt != lastSnapshotAt {
            lastSnapshotAt = snapshot.fetchedAt
            Task { await ChargingCoordinator.shared.handle(snapshot) }
        }
        let glance = withObservationTracking {
            LiveActivities.update(car)
            return Self.glance(car)
        } onChange: {
            Task { @MainActor in GlanceSync.shared.observe() }
        }
        publish(glance)
    }

    private func publish(_ glance: CarGlance?) {
        guard glance != last else { return }
        let before = last
        last = glance
        GlanceKeychain.save(glance)
        // Widgets have a daily reload budget: only spend it when something they show has changed.
        if before?.withoutBusy != glance?.withoutBusy {
            WidgetCenter.shared.reloadAllTimelines()
        }
        sendToWatch(glance)
    }

    private func sendToWatch(_ glance: CarGlance?) {
        guard let session, session.activationState == .activated, session.isPaired, session.isWatchAppInstalled,
              let glance, let data = try? JSONEncoder().encode(glance) else { return }
        try? session.updateApplicationContext(["glance": data])
    }

    static func glance(_ car: CarModel) -> CarGlance? {
        guard let s = car.snapshot else { return nil }
        let miles = car.settings.useMiles
        return CarGlance(
            socPercent: s.socPercent,
            rangeText: s.rangeKm.map { DisplayText.distance(km: Double($0), miles: miles) },
            charging: s.chargingState == .charging,
            pluggedIn: s.pluggedIn == true,
            locked: s.details?.locked,
            climateOn: s.climate == .running,
            targetText: s.targetTempC.map { String(format: "%.1f °C", $0) },
            chargeLimit: s.details?.chargeLimitAC,
            minutesToFull: s.chargingState == .charging ? s.minutesToFullyCharged : nil,
            carReportedAt: s.carCapturedAt,
            fetchedAt: s.fetchedAt,
            status: car.confirming.map { "Waiting for the car: \($0)…" } ?? car.message,
            busy: car.busy != nil || car.confirming != nil,
            plan: GlanceText.chargePlan(s, smart: AppServices.shared.charging.plan, now: Date()),
            next: GlanceText.nextRule(AppServices.shared.rules.rules, now: Date(), clock: LocalClock())
        )
    }

    /// Runs a command from the Watch or a widget link, and says how it went.
    func perform(_ command: GlanceCommand) async -> String {
        let services = AppServices.shared
        await services.prepare()
        let car = services.car
        car.message = nil
        switch command {
        case .refresh: await car.refresh()
        case .climateStart: await car.start()
        case .climateStop: await car.stop()
        case .lock: await car.send(.lock)
        case .unlock: await car.send(.unlock)
        case .chargeStart: await car.send(.startCharging)
        case .chargeStop: await car.send(.stopCharging)
        }
        return car.message ?? (command == .refresh ? "Updated." : "Sent.")
    }
}

private extension CarGlance {
    var withoutBusy: CarGlance {
        var copy = self
        copy.busy = false
        return copy
    }
}

extension GlanceSync: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            let sync = GlanceSync.shared
            sync.sendToWatch(sync.last)
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            let sync = GlanceSync.shared
            sync.sendToWatch(sync.last)
        }
    }

    /// The Watch asks for a command; iOS wakes the app in the background to run it.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let raw = message["command"] as? String
        let reply = UncheckedReply(replyHandler)
        Task { @MainActor in
            guard let command = raw.flatMap(GlanceCommand.init(rawValue:)) else {
                reply.send(["message": "Unknown command."])
                return
            }
            let result = await GlanceSync.shared.perform(command)
            var answer: [String: Any] = ["message": result]
            if let glance = GlanceSync.shared.last, let data = try? JSONEncoder().encode(glance) {
                answer["glance"] = data
            }
            reply.send(answer)
        }
    }
}

/// WatchConnectivity's reply handler isn't marked Sendable; it's safe to call from any thread.
private struct UncheckedReply: @unchecked Sendable {
    let handler: ([String: Any]) -> Void
    init(_ handler: @escaping ([String: Any]) -> Void) { self.handler = handler }
    func send(_ reply: [String: Any]) { handler(reply) }
}
