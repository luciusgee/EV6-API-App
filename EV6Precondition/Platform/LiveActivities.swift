import ActivityKit
import Foundation
import PreconditionKit

/// Starts, updates and ends the climate and charging Live Activities from what the app knows.
@MainActor
enum LiveActivities {
    /// Kia runs remote climate for this long (the app asks for 15, like Kia's own app).
    static let climateMinutes: Double = 15
    /// Without a fresh reading for this long, an activity shows as out of date.
    static let staleAfter: TimeInterval = 45 * 60

    static func update(_ car: CarModel) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        sync(.climate, climateState(car))
        sync(.charging, chargingState(car))
    }

    private static func climateState(_ car: CarModel) -> CarActivityAttributes.ContentState? {
        let now = Date()
        let snapshot = car.snapshot
        // Started from the app, a widget, the Watch or a rule, and not refused by the car.
        guard let last = car.automation.lastCommand, last.description.hasPrefix("climatise"),
              now.timeIntervalSince(last.at) < climateMinutes * 60,
              last.status != .failed, last.status != .noResponse else { return nil }
        // The car has since said its climate is off (stopped from the car or Kia's app, or timed out).
        if let snapshot, snapshot.climate == .off,
           (snapshot.carCapturedAt ?? snapshot.fetchedAt) > last.at.addingTimeInterval(60) {
            return nil
        }
        let ends = last.at.addingTimeInterval(climateMinutes * 60)
        let target = last.description.replacingOccurrences(of: "climatise to ", with: "")
        let detail: String
        if last.status == .success {
            detail = "Confirmed by the car"
        } else if last.status == nil {
            detail = "Waiting for the car…"
        } else {
            // Confirmation gave up without an answer either way.
            detail = "Sent – not confirmed by the car"
        }
        return .init(
            socPercent: snapshot?.socPercent,
            rangeText: range(car),
            title: "Climate on · \(target)",
            detail: detail,
            startedAt: last.at,
            endsAt: ends
        )
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
            detail: s.chargePowerKw.map { String(format: "%.1f kW", $0) },
            startedAt: reported,
            endsAt: s.minutesToFullyCharged.map { reported.addingTimeInterval(Double($0) * 60) },
            // When the car said so: this updates when the app next reads the car.
            updatedAt: reported
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
        // Stale once it should have ended, or when the app hasn't read the car for a while, so the
        // activity says so rather than showing old numbers as current.
        let now = Date()
        let unread = (state.updatedAt ?? now).addingTimeInterval(staleAfter)
        let stale = max(min(state.endsAt ?? unread, unread), now.addingTimeInterval(60))
        let content = ActivityContent(state: state, staleDate: stale)
        if let activity = running.first {
            let oldStale = activity.content.staleDate ?? .distantPast
            if activity.content.state != state || abs(oldStale.timeIntervalSince(stale)) > 5 * 60 {
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
