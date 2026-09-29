import Foundation

public enum CarAlertKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case chargingStopped, chargeComplete, leftUnlocked, windowOpen, lowAuxBattery, tyrePressure, lowCharge

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .chargingStopped: return "Charging stopped early"
        case .chargeComplete: return "Charge complete"
        case .leftUnlocked: return "Left unlocked"
        case .windowOpen: return "Window open"
        case .lowAuxBattery: return "12 V battery low"
        case .tyrePressure: return "Tyre pressure"
        case .lowCharge: return "Low charge"
        }
    }
}

public struct CarAlert: Equatable, Sendable {
    public var kind: CarAlertKind
    public var title: String
    public var body: String
}

public struct AlertSettings: Codable, Equatable, Sendable {
    public var enabled: Set<CarAlertKind>
    public var lowChargePercent: Int
    public var lowAuxPercent: Int
    /// Read the car in the background every so often to catch these (uses Kia requests).
    public var backgroundChecks: Bool
    public var backgroundEveryHours: Int

    public init(
        enabled: Set<CarAlertKind> = Set(CarAlertKind.allCases),
        lowChargePercent: Int = 20,
        lowAuxPercent: Int = 70,
        backgroundChecks: Bool = true,
        backgroundEveryHours: Int = 2
    ) {
        self.enabled = enabled
        self.lowChargePercent = lowChargePercent
        self.lowAuxPercent = lowAuxPercent
        self.backgroundChecks = backgroundChecks
        self.backgroundEveryHours = backgroundEveryHours
    }
}

/// Which lasting conditions have already been announced, so each is said once until it clears.
public struct AlertState: Codable, Equatable, Sendable {
    public var raised: Set<CarAlertKind> = []
    public var lastSnapshotAt: Date?
    public init() {}
}

/// Turns a new reading of the car into notifications worth sending.
public enum AlertEngine {
    public static func evaluate(
        previous: VehicleSnapshot?,
        current s: VehicleSnapshot,
        state: inout AlertState,
        settings: AlertSettings,
        now: Date
    ) -> [CarAlert] {
        let reportedAt = s.carCapturedAt ?? s.fetchedAt
        // The same report again: nothing new to say.
        if let last = state.lastSnapshotAt, reportedAt <= last { return [] }
        state.lastSnapshotAt = reportedAt

        var out: [CarAlert] = []
        let soc = s.socPercent
        let parked = s.parked != false
        let details = s.details

        // Changes: only when the previous reading showed charging.
        if let previous, previous.chargingState == .charging, s.chargingState != .charging, let soc {
            let limit = details?.chargeLimitAC ?? 100
            if soc >= limit - 2 {
                out.append(CarAlert(kind: .chargeComplete, title: "EV6 charged to \(soc)%", body: "Charging has finished."))
            } else if s.pluggedIn == true {
                out.append(CarAlert(kind: .chargingStopped, title: "EV6 stopped charging at \(soc)%",
                                    body: "It's still plugged in but not charging, below its \(limit)% limit."))
            }
        }

        // Conditions: said once, then again only after they've cleared.
        func condition(_ kind: CarAlertKind, _ active: Bool, _ title: @autoclosure () -> String, _ body: @autoclosure () -> String) {
            if active {
                if !state.raised.contains(kind) {
                    state.raised.insert(kind)
                    out.append(CarAlert(kind: kind, title: title(), body: body()))
                }
            } else {
                state.raised.remove(kind)
            }
        }
        condition(.leftUnlocked, details?.locked == false && parked && now.timeIntervalSince(reportedAt) >= 10 * 60,
                  "EV6 is unlocked", "It has been unlocked since \(clock(reportedAt)). Lock it from the app.")
        let windows = details?.openWindows ?? []
        condition(.windowOpen, !windows.isEmpty && parked,
                  "EV6 window open", "\(windows.joined(separator: ", ")) \(windows.count == 1 ? "is" : "are") open.")
        if let aux = details?.auxBatteryPercent {
            condition(.lowAuxBattery, aux < settings.lowAuxPercent,
                      "EV6 12 V battery at \(aux)%", "It's normally 80–100%. If it keeps falling, have the ICCU checked.")
        }
        condition(.tyrePressure, details?.tyreWarning == true,
                  "EV6 tyre pressure warning", (details?.tyreWarnings ?? []).isEmpty ? "Check the tyres." : "Check: \((details?.tyreWarnings ?? []).joined(separator: ", ")).")
        if let soc {
            condition(.lowCharge, soc < settings.lowChargePercent && s.pluggedIn != true,
                      "EV6 at \(soc)%", "Charge is below \(settings.lowChargePercent)% and it isn't plugged in.")
        }
        return out.filter { settings.enabled.contains($0.kind) }
    }

    private static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}
