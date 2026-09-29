import ActivityKit
import Foundation
import PreconditionKit

/// Starts, updates and ends the climate and charging Live Activities from what the app knows.
@MainActor
enum LiveActivities {
    /// Kia runs remote climate for this long (the app asks for 15, like Kia's own app).
    static let climateMinutes: Double = 15

    static func update(_ car: CarModel) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        sync(.climate, climateState(car))
        sync(.charging, chargingState(car))
    }

    private static func climateState(_ car: CarModel) -> CarActivityAttributes.ContentState? {
        let now = Date()
        let snapshot = car.snapshot
        // Started from the app, a widget, the Watch or a rule, and not refused by the car.
        if let last = car.automation.lastCommand, last.description.hasPrefix("climatise"),
           now.timeIntervalSince(last.at) < climateMinutes * 60,
           last.status != .failed, last.status != .noResponse {
            let ends = last.at.addingTimeInterval(climateMinutes * 60)
            let target = last.description.replacingOccurrences(of: "climatise to ", with: "")
            return .init(
                socPercent: snapshot?.socPercent,
                rangeText: range(car),
                title: "Climate to \(target)",
                detail: last.status == .success ? "Confirmed by the car" : "Waiting for the car to confirm",
                startedAt: last.at,
                endsAt: ends
            )
        }
        return nil
    }

    private static func chargingState(_ car: CarModel) -> CarActivityAttributes.ContentState? {
        guard let s = car.snapshot, s.chargingState == .charging,
              Date().timeIntervalSince(s.fetchedAt) < 6 * 3600 else { return nil }
        let reported = s.carCapturedAt ?? s.fetchedAt
        let limit = s.details?.chargeLimitAC
        return .init(
            socPercent: s.socPercent,
            rangeText: range(car),
            title: limit.map { "Charging to \($0)%" } ?? "Charging",
            // When the car said so: this updates when the app next reads the car.
            detail: [s.chargePowerKw.map { String(format: "%.1f kW", $0) }, reported.formatted(date: .omitted, time: .shortened)]
                .compactMap { $0 }.joined(separator: " · "),
            startedAt: reported,
            endsAt: s.minutesToFullyCharged.map { reported.addingTimeInterval(Double($0) * 60) }
        )
    }

    private static func range(_ car: CarModel) -> String? {
        car.snapshot?.rangeKm.map { DisplayText.distance(km: Double($0), miles: car.settings.useMiles) }
    }

    private static func sync(_ kind: CarActivityAttributes.Kind, _ state: CarActivityAttributes.ContentState?) {
        let running = Activity<CarActivityAttributes>.activities.filter { $0.attributes.kind == kind }
        guard let state else {
            for activity in running {
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
            }
            return
        }
        let stale = state.endsAt.map { max($0, Date().addingTimeInterval(60)) }
        let content = ActivityContent(state: state, staleDate: stale)
        if let activity = running.first {
            if activity.content.state != state {
                Task { await activity.update(content) }
            }
            for extra in running.dropFirst() {
                Task { await extra.end(nil, dismissalPolicy: .immediate) }
            }
        } else {
            _ = try? Activity.request(attributes: CarActivityAttributes(kind: kind), content: content, pushType: nil)
        }
    }
}
