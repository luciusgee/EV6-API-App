import Foundation

/// Checks a rule or place before it's saved or imported (HANDOVER.md §4.2). An empty list means valid.
public enum RuleValidator {
    /// The EV6's climate control goes from 17 to 27 °C; outside that the car keeps its last setting.
    public static let minTargetC = 17.0
    public static let maxTargetC = 27.0
    public static let minCarRadiusM = 100
    public static let maxCarRadiusM = 5000
    public static let minPhoneDistanceM = 50
    public static let maxPhoneDistanceM = 20_000

    public static func validate(_ rule: Rule, placeIds: Set<String>) -> [String] {
        var problems: [String] = []
        func add(_ s: String) { problems.append(s) }
        func checkPlace(_ id: String, _ what: String) {
            if !placeIds.contains(id) { add("\(what) refers to unknown place '\(id)'") }
        }
        func checkTemp(_ c: Double) {
            if !(-40...50).contains(c) { add("temperature threshold must be between -40 and 50 °C") }
        }

        if rule.id.trimmingCharacters(in: .whitespaces).isEmpty { add("id is empty") }
        if rule.name.trimmingCharacters(in: .whitespaces).isEmpty { add("name is empty") }
        if rule.cooldownMinutes < 0 { add("cooldownMinutes must not be negative") }

        switch rule.trigger {
        case .geofenceExit(let id), .geofenceEnter(let id):
            checkPlace(id, "trigger")
        case .approaching(let id, let km):
            checkPlace(id, "trigger")
            if km <= 0 || km > 100 { add("approaching distance must be between 0 and 100 km") }
        case .schedule(let days, _):
            if days.isEmpty { add("schedule has no days") }
        case .nearCar(let m):
            if !(minCarRadiusM...maxCarRadiusM).contains(m) { add("distance to the car must be \(minCarRadiusM)–\(maxCarRadiusM) m") }
        }

        for c in rule.conditions {
            switch c {
            case .timeWindow(let start, let end):
                if start == end { add("time window start and end are equal") }
            case .daysOfWeek(let days):
                if days.isEmpty { add("days condition has no days") }
            case .tempBelow(let t, _), .tempAbove(let t, _):
                checkTemp(t)
            case .tempOutside(let low, let high, _):
                checkTemp(low)
                checkTemp(high)
                if low >= high { add("temperature range: the lower limit must be below the upper limit") }
            case .socAtLeast(let p):
                if !(0...100).contains(p) { add("SoC must be 0–100%") }
            case .pluggedIn:
                break
            case .carAtPlace(let id):
                checkPlace(id, "car-at-place condition")
            case .phoneNearCar(let m):
                if !(minPhoneDistanceM...maxPhoneDistanceM).contains(m) {
                    add("phone-near-car distance must be \(minPhoneDistanceM)–\(maxPhoneDistanceM) m")
                }
            }
        }

        // Conditions are all required. "Below X" with "above Y ≥ X" on the same source can never pass.
        for case let .tempBelow(b, bs) in rule.conditions {
            for case let .tempAbove(a, source) in rule.conditions where source == bs && a >= b {
                add("“below \(Describe.temp(b))” and “above \(Describe.temp(a))” can never both be true — all conditions must pass. Use “temperature outside a range” instead.")
            }
        }

        if case .startClimate(let target) = rule.action, !(minTargetC...maxTargetC).contains(target) {
            add("target temperature must be \(Int(minTargetC))–\(Int(maxTargetC)) °C")
        }
        return problems
    }

    public static func validatePlace(_ place: Place) -> [String] {
        var problems: [String] = []
        if place.id.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("id is empty") }
        if place.name.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("name is empty") }
        if !(Place.minRadiusM...Place.maxRadiusM).contains(place.radiusM) {
            problems.append("radius must be \(Place.minRadiusM)–\(Place.maxRadiusM) m")
        }
        if !(-90...90).contains(place.centre.lat) || !(-180...180).contains(place.centre.lon) {
            problems.append("centre is not a valid coordinate")
        }
        return problems
    }
}
