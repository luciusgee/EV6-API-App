import Foundation

/// Human-readable wording for logs, notifications and the rules list, as in the Android `Describe.kt`.
/// Users read these to understand why a rule did or didn't fire, so keep them stable.
extension Describe {
    public static func time(_ t: TimeOfDay) -> String { t.description }

    public static func days(_ days: Set<Weekday>) -> String {
        if days.count == 7 { return "every day" }
        if days == Weekday.weekdays { return "Mon–Fri" }
        if days == Weekday.weekend { return "Sat–Sun" }
        return days.sorted().map(\.shortName).joined(separator: ",")
    }

    public static func trigger(_ t: Trigger, placeName: (String) -> String) -> String {
        switch t {
        case .geofenceExit(let id): return "leave \(placeName(id))"
        case .geofenceEnter(let id): return "arrive at \(placeName(id))"
        case .approaching(let id, let km): return "within \(trimNumber(km)) km of \(placeName(id))"
        case .schedule(let days, let time): return "\(Self.days(days)) at \(Self.time(time))"
        case .nearCar(let m): return "within \(m) m of the car"
        }
    }

    public static func event(_ e: TriggerEvent, placeName: (String) -> String) -> String {
        switch e {
        case .geofenceExited(let id): return "left \(placeName(id))"
        case .geofenceEntered(let id): return "arrived at \(placeName(id))"
        case .approached(let id, let km): return "approaching \(placeName(id)) (\(trimNumber(km)) km)"
        case .scheduleFired(let time): return "schedule \(Self.time(time))"
        case .approachedCar(let m): return "approaching the car (\(m) m)"
        }
    }

    public static func source(_ s: TempSource) -> String {
        switch s {
        case .carOutside: return "car outside temp"
        case .weatherAtCar: return "weather at car"
        case .forecastAt(let t): return "forecast at \(time(t))"
        case .cabinBle: return "cabin sensor"
        case .bestAvailable: return "temp at car"
        }
    }

    public static func condition(_ c: Condition, placeName: (String) -> String) -> String {
        switch c {
        case .timeWindow(let start, let end): return "\(time(start))–\(time(end))"
        case .daysOfWeek(let d): return days(d)
        case .tempBelow(let t, let s): return "\(source(s)) below \(temp(t))"
        case .tempAbove(let t, let s): return "\(source(s)) above \(temp(t))"
        case .tempOutside(let low, let high, let s): return "\(source(s)) below \(temp(low)) or above \(temp(high))"
        case .socAtLeast(let p): return "SoC ≥ \(p)%"
        case .pluggedIn(let e): return e ? "plugged in" : "not plugged in"
        case .carAtPlace(let id): return "car at \(placeName(id))"
        case .phoneNearCar(let m): return "phone within \(distance(m)) of the car"
        }
    }

    /// `"500 m"`, `"1.5 km"`, `"2 km"`.
    public static func distance(_ meters: Int) -> String {
        meters >= 1000 ? "\(trimNumber(Double(meters) / 1000)) km" : "\(meters) m"
    }

    /// One line for the rules list: "leave Office · Mon–Fri, 16:00–19:00 · climatise to 21.0 °C".
    public static func rule(_ r: Rule, placeName: (String) -> String) -> String {
        var parts = [trigger(r.trigger, placeName: placeName)]
        if !r.conditions.isEmpty { parts.append(r.conditions.map { condition($0, placeName: placeName) }.joined(separator: ", ")) }
        parts.append(action(r.action))
        return parts.joined(separator: " · ")
    }

    /// `3.0` → `"3"`, `2.5` → `"2.5"`.
    static func trimNumber(_ d: Double) -> String {
        d.rounded(.down) == d && abs(d) < 1e15 ? String(Int64(d)) : String(format: "%.1f", d)
    }
}
