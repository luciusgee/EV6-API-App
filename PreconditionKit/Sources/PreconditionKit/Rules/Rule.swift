import Foundation

// The rule model (HANDOVER.md §4.1). The JSON must stay compatible with the Android app's backups, so
// every type encodes with a "type" discriminator and the Android field names.

/// A time of day, written `"HH:mm"`. Accepts `"H:mm"` on input for hand-edited files.
public struct TimeOfDay: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let hour: Int
    public let minute: Int

    public init(_ hour: Int, _ minute: Int) {
        precondition((0...23).contains(hour) && (0...59).contains(minute), "invalid time \(hour):\(minute)")
        self.hour = hour
        self.minute = minute
    }

    /// `"7:05"` or `"07:05"`; nil for anything else.
    public init?(parsing text: String) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, (1...2).contains(parts[0].count), parts[1].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let h = Int(parts[0]), let m = Int(parts[1]), (0...23).contains(h), (0...59).contains(m)
        else { return nil }
        self.init(h, m)
    }

    public static let midnight = TimeOfDay(0, 0)
    public static let noon = TimeOfDay(12, 0)

    public var minutesSinceMidnight: Int { hour * 60 + minute }

    public static func < (a: TimeOfDay, b: TimeOfDay) -> Bool { a.minutesSinceMidnight < b.minutesSinceMidnight }

    /// `"07:05"`.
    public var description: String { String(format: "%02d:%02d", hour, minute) }
}

extension TimeOfDay: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let text = try c.decode(String.self)
        guard let t = TimeOfDay(parsing: text) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid time '\(text)', expected HH:mm")
        }
        self = t
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

/// Days are written `MON`…`SUN`; full English names are accepted on input, in any case.
public enum Weekday: String, CaseIterable, Comparable, Sendable {
    case monday = "MON", tuesday = "TUE", wednesday = "WED", thursday = "THU", friday = "FRI", saturday = "SAT", sunday = "SUN"

    public static let weekdays: Set<Weekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]
    public static let weekend: Set<Weekday> = [.saturday, .sunday]
    public static let everyDay = Set(Weekday.allCases)

    private var order: Int { Weekday.allCases.firstIndex(of: self)! }
    public static func < (a: Weekday, b: Weekday) -> Bool { a.order < b.order }

    /// Foundation's `Calendar` numbers Sunday as 1. This is the one place that mapping lives.
    public init(calendarWeekday: Int) {
        self = [.sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday][(calendarWeekday - 1 + 7) % 7]
    }

    public var calendarWeekday: Int { order == 6 ? 1 : order + 2 }

    /// "Mon".
    public var shortName: String { rawValue.prefix(1) + rawValue.dropFirst().lowercased() }

    private static let fullNames = ["MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY", "SUNDAY"]

    public init?(parsing text: String) {
        let upper = text.trimmingCharacters(in: .whitespaces).uppercased()
        if let d = Weekday(rawValue: upper) {
            self = d
        } else if let i = Self.fullNames.firstIndex(of: upper) {
            self = Weekday.allCases[i]
        } else {
            return nil
        }
    }
}

extension Weekday: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let text = try c.decode(String.self)
        guard let d = Weekday(parsing: text) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid day '\(text)', expected MON..SUN")
        }
        self = d
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// A calendar date without a time, written `"yyyy-MM-dd"`. Used for holidays.
public struct CalendarDay: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(_ year: Int, _ month: Int, _ day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init?(parsing text: String) {
        let p = text.split(separator: "-").map { Int($0) }
        guard p.count == 3, let y = p[0], let m = p[1], let d = p[2], (1...12).contains(m), (1...31).contains(d) else { return nil }
        self.init(y, m, d)
    }

    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }

    public static func < (a: CalendarDay, b: CalendarDay) -> Bool { (a.year, a.month, a.day) < (b.year, b.month, b.day) }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let text = try c.decode(String.self)
        guard let d = CalendarDay(parsing: text) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid date '\(text)', expected yyyy-MM-dd")
        }
        self = d
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

// MARK: - Trigger

/// What starts an evaluation.
public enum Trigger: Hashable, Sendable {
    case geofenceExit(placeId: String)
    case geofenceEnter(placeId: String)
    /// The phone comes within `km` of the place: an outer geofence, not continuous tracking.
    case approaching(placeId: String, km: Double)
    case schedule(days: Set<Weekday>, time: TimeOfDay)
    /// The phone comes within `meters` of where the car is parked.
    case nearCar(meters: Int)

    /// The place the trigger refers to, if any.
    public var placeId: String? {
        switch self {
        case .geofenceExit(let id), .geofenceEnter(let id), .approaching(let id, _): return id
        case .schedule, .nearCar: return nil
        }
    }

    /// Does a rule with this trigger react to `event`? A schedule also needs today to be one of its days.
    public func matches(_ event: TriggerEvent, today: Weekday) -> Bool {
        switch (self, event) {
        case (.geofenceExit(let a), .geofenceExited(let b)), (.geofenceEnter(let a), .geofenceEntered(let b)): return a == b
        case (.approaching(let a, let km), .approached(let b, let km2)): return a == b && km == km2
        case (.schedule(let days, let time), .scheduleFired(let t)): return time == t && days.contains(today)
        case (.nearCar(let m), .approachedCar(let m2)): return m == m2
        default: return false
        }
    }

    /// The event this trigger would produce; used by "Test now".
    public var syntheticEvent: TriggerEvent {
        switch self {
        case .geofenceExit(let id): return .geofenceExited(placeId: id)
        case .geofenceEnter(let id): return .geofenceEntered(placeId: id)
        case .approaching(let id, let km): return .approached(placeId: id, km: km)
        case .schedule(_, let time): return .scheduleFired(time: time)
        case .nearCar(let m): return .approachedCar(meters: m)
        }
    }
}

extension Trigger: Codable {
    private enum CodingKeys: String, CodingKey { case type, placeId, km, days, time, meters }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "geofenceExit": self = .geofenceExit(placeId: try c.decode(String.self, forKey: .placeId))
        case "geofenceEnter": self = .geofenceEnter(placeId: try c.decode(String.self, forKey: .placeId))
        case "approaching": self = .approaching(placeId: try c.decode(String.self, forKey: .placeId), km: try c.decode(Double.self, forKey: .km))
        case "schedule": self = .schedule(days: Set(try c.decode([Weekday].self, forKey: .days)), time: try c.decode(TimeOfDay.self, forKey: .time))
        case "nearCar": self = .nearCar(meters: try c.decode(Int.self, forKey: .meters))
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown trigger type '\(type)'")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .geofenceExit(let id):
            try c.encode("geofenceExit", forKey: .type)
            try c.encode(id, forKey: .placeId)
        case .geofenceEnter(let id):
            try c.encode("geofenceEnter", forKey: .type)
            try c.encode(id, forKey: .placeId)
        case .approaching(let id, let km):
            try c.encode("approaching", forKey: .type)
            try c.encode(id, forKey: .placeId)
            try c.encode(km, forKey: .km)
        case .schedule(let days, let time):
            try c.encode("schedule", forKey: .type)
            try c.encode(days.sorted(), forKey: .days)
            try c.encode(time, forKey: .time)
        case .nearCar(let m):
            try c.encode("nearCar", forKey: .type)
            try c.encode(m, forKey: .meters)
        }
    }
}

// MARK: - Temperature sources and conditions

public enum TempSource: Hashable, Sendable {
    /// The outside temperature the car reports (CCS2 cars only).
    case carOutside
    /// Open-Meteo's current temperature at the car (or the place's usual parking spot).
    case weatherAtCar
    /// Open-Meteo's hourly forecast at the car for the next occurrence of `time`.
    case forecastAt(TimeOfDay)
    /// A BLE thermometer in the cabin; unknown unless the phone is in range.
    case cabinBle
    /// The car's sensor if it reports one, else weather at the car. Never the cabin.
    case bestAvailable
}

extension TempSource: Codable {
    private enum CodingKeys: String, CodingKey { case type, time }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "carOutside": self = .carOutside
        case "weatherAtCar": self = .weatherAtCar
        case "forecastAt": self = .forecastAt(try c.decode(TimeOfDay.self, forKey: .time))
        case "cabinBle": self = .cabinBle
        case "bestAvailable": self = .bestAvailable
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown temperature source '\(type)'")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .carOutside: try c.encode("carOutside", forKey: .type)
        case .weatherAtCar: try c.encode("weatherAtCar", forKey: .type)
        case .forecastAt(let t):
            try c.encode("forecastAt", forKey: .type)
            try c.encode(t, forKey: .time)
        case .cabinBle: try c.encode("cabinBle", forKey: .type)
        case .bestAvailable: try c.encode("bestAvailable", forKey: .type)
        }
    }
}

/// All of a rule's conditions must pass (AND).
public enum Condition: Hashable, Sendable {
    /// Inclusive start, exclusive end; wraps past midnight when start is after end.
    case timeWindow(start: TimeOfDay, end: TimeOfDay)
    case daysOfWeek(Set<Weekday>)
    case tempBelow(celsius: Double, source: TempSource)
    case tempAbove(celsius: Double, source: TempSource)
    /// Below `low` or above `high`: "heat when cold, cool when hot" in one rule.
    case tempOutside(low: Double, high: Double, source: TempSource)
    case socAtLeast(percent: Int)
    case pluggedIn(expected: Bool)
    case carAtPlace(placeId: String)
    /// The phone is within `meters` of the parked car, checked when the rule runs.
    case phoneNearCar(meters: Int)
}

extension Condition: Codable {
    private enum CodingKeys: String, CodingKey { case type, start, end, days, celsius, source, low, high, percent, expected, placeId, meters }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "timeWindow": self = .timeWindow(start: try c.decode(TimeOfDay.self, forKey: .start), end: try c.decode(TimeOfDay.self, forKey: .end))
        case "daysOfWeek": self = .daysOfWeek(Set(try c.decode([Weekday].self, forKey: .days)))
        case "tempBelow": self = .tempBelow(celsius: try c.decode(Double.self, forKey: .celsius), source: try c.decode(TempSource.self, forKey: .source))
        case "tempAbove": self = .tempAbove(celsius: try c.decode(Double.self, forKey: .celsius), source: try c.decode(TempSource.self, forKey: .source))
        case "tempOutside":
            self = .tempOutside(
                low: try c.decode(Double.self, forKey: .low),
                high: try c.decode(Double.self, forKey: .high),
                source: try c.decode(TempSource.self, forKey: .source)
            )
        case "socAtLeast": self = .socAtLeast(percent: try c.decode(Int.self, forKey: .percent))
        case "pluggedIn": self = .pluggedIn(expected: try c.decode(Bool.self, forKey: .expected))
        case "carAtPlace": self = .carAtPlace(placeId: try c.decode(String.self, forKey: .placeId))
        case "phoneNearCar": self = .phoneNearCar(meters: try c.decode(Int.self, forKey: .meters))
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown condition type '\(type)'")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .timeWindow(let start, let end):
            try c.encode("timeWindow", forKey: .type)
            try c.encode(start, forKey: .start)
            try c.encode(end, forKey: .end)
        case .daysOfWeek(let days):
            try c.encode("daysOfWeek", forKey: .type)
            try c.encode(days.sorted(), forKey: .days)
        case .tempBelow(let t, let s):
            try c.encode("tempBelow", forKey: .type)
            try c.encode(t, forKey: .celsius)
            try c.encode(s, forKey: .source)
        case .tempAbove(let t, let s):
            try c.encode("tempAbove", forKey: .type)
            try c.encode(t, forKey: .celsius)
            try c.encode(s, forKey: .source)
        case .tempOutside(let low, let high, let s):
            try c.encode("tempOutside", forKey: .type)
            try c.encode(low, forKey: .low)
            try c.encode(high, forKey: .high)
            try c.encode(s, forKey: .source)
        case .socAtLeast(let p):
            try c.encode("socAtLeast", forKey: .type)
            try c.encode(p, forKey: .percent)
        case .pluggedIn(let e):
            try c.encode("pluggedIn", forKey: .type)
            try c.encode(e, forKey: .expected)
        case .carAtPlace(let id):
            try c.encode("carAtPlace", forKey: .type)
            try c.encode(id, forKey: .placeId)
        case .phoneNearCar(let m):
            try c.encode("phoneNearCar", forKey: .type)
            try c.encode(m, forKey: .meters)
        }
    }
}

// MARK: - Rule

/// One trigger, AND-ed conditions, one action and a cooldown. Global guards (SoC, already running,
/// cooldowns, budget, pause) are applied on top by `RuleEvaluator`; they aren't part of the rule.
public struct Rule: Hashable, Identifiable, Sendable {
    public static let defaultCooldownMinutes = 60

    public var id: String
    public var name: String
    public var enabled: Bool
    /// Higher runs first. Ties go by name, then id, so ordering is deterministic.
    public var priority: Int
    public var trigger: Trigger
    public var conditions: [Condition]
    public var action: RuleAction
    public var cooldownMinutes: Int
    /// A condition whose input is unknown counts as passed instead of failed. Guards never do.
    public var proceedIfUnknown: Bool
    /// Ask with a notification (Start / In 15 min / Not today) instead of sending the command.
    public var askFirst: Bool

    public init(
        id: String,
        name: String,
        enabled: Bool = true,
        priority: Int = 0,
        trigger: Trigger,
        conditions: [Condition] = [],
        action: RuleAction,
        cooldownMinutes: Int = Rule.defaultCooldownMinutes,
        proceedIfUnknown: Bool = false,
        askFirst: Bool = false
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.priority = priority
        self.trigger = trigger
        self.conditions = conditions
        self.action = action
        self.cooldownMinutes = cooldownMinutes
        self.proceedIfUnknown = proceedIfUnknown
        self.askFirst = askFirst
    }
}

extension Rule: Codable {
    private enum CodingKeys: String, CodingKey { case id, name, enabled, priority, trigger, conditions, action, cooldownMinutes, proceedIfUnknown, askFirst }

    /// Missing keys take their defaults; unknown keys are ignored.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            name: try c.decode(String.self, forKey: .name),
            enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
            priority: try c.decodeIfPresent(Int.self, forKey: .priority) ?? 0,
            trigger: try c.decode(Trigger.self, forKey: .trigger),
            conditions: try c.decodeIfPresent([Condition].self, forKey: .conditions) ?? [],
            action: try c.decode(RuleAction.self, forKey: .action),
            cooldownMinutes: try c.decodeIfPresent(Int.self, forKey: .cooldownMinutes) ?? Rule.defaultCooldownMinutes,
            proceedIfUnknown: try c.decodeIfPresent(Bool.self, forKey: .proceedIfUnknown) ?? false,
            askFirst: try c.decodeIfPresent(Bool.self, forKey: .askFirst) ?? false
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(priority, forKey: .priority)
        try c.encode(trigger, forKey: .trigger)
        try c.encode(conditions, forKey: .conditions)
        try c.encode(action, forKey: .action)
        try c.encode(cooldownMinutes, forKey: .cooldownMinutes)
        try c.encode(proceedIfUnknown, forKey: .proceedIfUnknown)
        if askFirst { try c.encode(askFirst, forKey: .askFirst) }
    }
}

// MARK: - Trigger events

/// What actually happened on the phone. Rules are matched against it with `Trigger.matches`.
public enum TriggerEvent: Hashable, Codable, Sendable {
    case geofenceExited(placeId: String)
    case geofenceEntered(placeId: String)
    case approached(placeId: String, km: Double)
    case scheduleFired(time: TimeOfDay)
    case approachedCar(meters: Int)

    /// Used to ignore a repeated geofence event within the dedup window. Nil: never deduplicated.
    public var dedupKey: String? {
        switch self {
        case .geofenceExited(let id): return "exit:\(id)"
        case .geofenceEntered(let id): return "enter:\(id)"
        case .approached(let id, let km): return "approach:\(id):\(km)"
        case .approachedCar(let m): return "car:\(m)"
        case .scheduleFired: return nil
        }
    }
}
