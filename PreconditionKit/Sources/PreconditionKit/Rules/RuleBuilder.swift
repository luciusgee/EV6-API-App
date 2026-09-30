import Foundation

/// The choices in the step-by-step rule builder: when, what, only if. Turns them into a `Rule` and
/// into a sentence, so what's saved is exactly what was read back.
public struct RuleBuilder: Equatable, Sendable {
    public enum When: String, CaseIterable, Sendable {
        case time, leave, arrive, approach, nearCar
    }

    public enum Doing: String, CaseIterable, Sendable {
        case warm, cool, stop
    }

    public var when: When = .time
    public var days: Set<Weekday> = Weekday.weekdays
    public var time = TimeOfDay(7, 30)
    public var placeId: String?
    public var approachKm: Double = 5

    public var doing: Doing = .warm
    public var warmC: Double = 22
    public var coolC: Double = 19
    /// Heated steering wheel, rear window and mirrors (warm only).
    public var heatedExtras = false
    /// Windscreen defrost (warm only).
    public var defrost = false

    /// Warm: only when colder than `coldBelowC`. Cool: only when warmer than `hotAboveC`.
    public var onlyInWeather = true
    public var coldBelowC: Double = 8
    public var hotAboveC: Double = 22
    public var onlyIfPluggedIn = false
    public var minBattery: Int?

    public var askFirst = false

    public init() {}

    public var needsPlace: Bool { [.leave, .arrive, .approach].contains(when) }

    public var targetC: Double { doing == .cool ? coolC : warmC }

    /// Where the temperature is read: the forecast for a set time, else the best reading at the car.
    public var tempSource: TempSource { when == .time ? .forecastAt(time) : .bestAvailable }

    public var trigger: Trigger {
        switch when {
        case .time: return .schedule(days: days, time: time)
        case .leave: return .geofenceExit(placeId: placeId ?? "")
        case .arrive: return .geofenceEnter(placeId: placeId ?? "")
        case .approach: return .approaching(placeId: placeId ?? "", km: approachKm)
        case .nearCar: return .nearCar(meters: 150)
        }
    }

    public var conditions: [Condition] {
        var out: [Condition] = []
        if onlyInWeather {
            switch doing {
            case .warm: out.append(.tempBelow(celsius: coldBelowC, source: tempSource))
            case .cool: out.append(.tempAbove(celsius: hotAboveC, source: tempSource))
            case .stop: break
            }
        }
        if onlyIfPluggedIn { out.append(.pluggedIn(expected: true)) }
        if let minBattery { out.append(.socAtLeast(percent: minBattery)) }
        return out
    }

    public var action: RuleAction { doing == .stop ? .stopClimate : .startClimate(targetC: targetC) }

    public var climateOptions: ClimateOptions? {
        guard doing == .warm, heatedExtras || defrost else { return nil }
        return ClimateOptions(defrost: defrost, heatedExtras: heatedExtras)
    }

    public func build(id: String = Templates.newId(), name: String? = nil, placeName: (String) -> String = { $0 }) -> Rule {
        Rule(
            id: id,
            name: (name?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? shortName(placeName: placeName),
            trigger: trigger,
            conditions: conditions,
            action: action,
            askFirst: askFirst,
            climateOptions: climateOptions
        )
    }

    // MARK: Words

    public static func days(_ days: Set<Weekday>) -> String {
        if days == Weekday.everyDay { return "Every day" }
        if days == Weekday.weekdays { return "Weekdays" }
        if days == Weekday.weekend { return "Weekends" }
        if days.isEmpty { return "No days" }
        return days.sorted().map(\.shortName).joined(separator: ", ")
    }

    private static func temp(_ c: Double) -> String {
        c == c.rounded() ? "\(Int(c)) °C" : String(format: "%.1f °C", c)
    }

    public func whenText(placeName: (String) -> String) -> String {
        let place = placeId.map(placeName) ?? "a place"
        switch when {
        case .time: return "\(Self.days(days)) at \(time)"
        case .leave: return "When I leave \(place)"
        case .arrive: return "When I get to \(place)"
        case .approach: return "When I'm \(Int(approachKm)) km from \(place)"
        case .nearCar: return "When I walk up to the car"
        }
    }

    public var doText: String {
        switch doing {
        case .warm:
            var extras: [String] = []
            if heatedExtras { extras.append("heated wheel and mirrors") }
            if defrost { extras.append("defrost") }
            return "warm the car to \(Self.temp(warmC))" + (extras.isEmpty ? "" : " with the " + extras.joined(separator: " and "))
        case .cool: return "cool the car to \(Self.temp(coolC))"
        case .stop: return "turn the climate off"
        }
    }

    public var onlyIfText: [String] {
        var out: [String] = []
        if onlyInWeather {
            switch doing {
            case .warm: out.append("it's colder than \(Self.temp(coldBelowC))" + (when == .time ? " (forecast)" : ""))
            case .cool: out.append("it's warmer than \(Self.temp(hotAboveC))" + (when == .time ? " (forecast)" : ""))
            case .stop: break
            }
        }
        if onlyIfPluggedIn { out.append("it's plugged in") }
        if let minBattery { out.append("the battery's at least \(minBattery)%") }
        return out
    }

    /// "Weekdays at 07:30, if it's colder than 8 °C (forecast), warm the car to 22 °C. Asks first."
    public func sentence(placeName: (String) -> String) -> String {
        var s = whenText(placeName: placeName)
        let conditions = onlyIfText
        if !conditions.isEmpty { s += ", if " + Self.join(conditions) }
        s += ", " + doText + "."
        if askFirst { s += " Asks you first." }
        return s
    }

    /// A name for the list: "Weekday mornings: warm", "Leaving Work: warm".
    public func shortName(placeName: (String) -> String) -> String {
        let what = doing == .warm ? "warm up" : doing == .cool ? "cool down" : "climate off"
        switch when {
        case .time:
            let part = time.hour < 12 ? "mornings" : time.hour < 17 ? "afternoons" : "evenings"
            let d = Self.days(days)
            let label = d == "Weekdays" ? "Weekday \(part)" : d == "Weekends" ? "Weekend \(part)" : d == "Every day" ? "Every day at \(time)" : "\(d) at \(time)"
            return "\(label): \(what)"
        case .leave: return "Leaving \(placeId.map(placeName) ?? "a place"): \(what)"
        case .arrive: return "Arriving at \(placeId.map(placeName) ?? "a place"): \(what)"
        case .approach: return "Nearly at \(placeId.map(placeName) ?? "a place"): \(what)"
        case .nearCar: return "At the car: \(what)"
        }
    }

    private static func join(_ parts: [String]) -> String {
        guard parts.count > 1 else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + " and " + parts.last!
    }
}
