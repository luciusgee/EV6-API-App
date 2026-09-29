import Foundation

// MARK: - Local time

/// Local-time arithmetic in one time zone: what day and time it is, and when a time of day next occurs.
public struct LocalClock: Sendable {
    public let timeZone: TimeZone

    public init(timeZone: TimeZone = .current) {
        self.timeZone = timeZone
    }

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }

    public func weekday(_ date: Date) -> Weekday {
        Weekday(calendarWeekday: calendar.component(.weekday, from: date))
    }

    public func timeOfDay(_ date: Date) -> TimeOfDay {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return TimeOfDay(c.hour ?? 0, c.minute ?? 0)
    }

    public func day(_ date: Date) -> CalendarDay {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return CalendarDay(c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }

    /// `time` on the same local day as `date`, `daysLater` days on. A time inside a spring-forward gap
    /// moves forward by the gap (02:30 → 03:30), which is what an alarm should do.
    public func date(_ time: TimeOfDay, sameDayAs date: Date, daysLater: Int = 0) -> Date {
        let cal = calendar
        let startOfDay = cal.startOfDay(for: date)
        let day = cal.date(byAdding: .day, value: daysLater, to: startOfDay) ?? startOfDay
        var c = cal.dateComponents([.year, .month, .day], from: day)
        c.hour = time.hour
        c.minute = time.minute
        guard let candidate = cal.date(from: c) else { return day }
        // Foundation resolves gap times differently across platforms. If it moved the time backwards,
        // read the wall time with the offset in force before the gap instead: that lands the same
        // distance past the gap (02:30 with a one-hour gap → 03:30).
        if timeOfDay(candidate) < time {
            return day.addingTimeInterval(TimeInterval(time.minutesSinceMidnight * 60))
        }
        return candidate
    }
}

// MARK: - Schedules

public struct ScheduledCheck: Equatable, Sendable {
    public var at: Date
    public var time: TimeOfDay
}

/// When schedule rules next run (HANDOVER.md §5: on iOS a Shortcuts automation runs them; this drives
/// the dashboard's "Next scheduled check").
public enum ScheduleCalculator {
    /// The next time strictly after `after` that falls on one of the days at the time.
    public static func next(days: Set<Weekday>, time: TimeOfDay, after: Date, clock: LocalClock) -> Date? {
        guard !days.isEmpty else { return nil }
        for offset in 0...7 {
            let candidate = clock.date(time, sameDayAs: after, daysLater: offset)
            guard days.contains(clock.weekday(candidate)) else { continue }
            if candidate > after { return candidate }
        }
        return nil
    }

    /// The soonest check across enabled schedule rules.
    public static func nextCheck(_ rules: [Rule], after: Date, clock: LocalClock) -> ScheduledCheck? {
        rules.compactMap { rule -> ScheduledCheck? in
            guard rule.enabled, case .schedule(let days, let time) = rule.trigger,
                  let at = next(days: days, time: time, after: after, clock: clock) else { return nil }
            return ScheduledCheck(at: at, time: time)
        }
        .min { $0.at < $1.at }
    }
}

// MARK: - Geofences

public struct GeofenceSpec: Equatable, Sendable {
    public var id: String
    public var centre: LatLon
    public var radiusM: Double
    public var enter: Bool
    public var exit: Bool
}

public enum Transition: Sendable {
    case enter, exit
}

/// Which regions the enabled rules need, and how a crossed region maps back to a `TriggerEvent`.
/// On iOS use `CLCircularRegion(identifier:)` with the same ids, and watch the 20-region limit.
public enum Geofences {
    private static let placePrefix = "place:"
    private static let approachPrefix = "approach:"
    private static let carPrefix = "car:"

    /// iOS monitors at most 20 regions per app.
    public static let iosRegionLimit = 20

    /// - Parameter carPosition: where the car is parked, for near-car rules. Nil registers no car fences.
    /// - Parameter tracked: places whose time is logged: watched both ways, and first in line for iOS's 20.
    public static func required(_ rules: [Rule], places: [Place], carPosition: LatLon? = nil, tracked: Set<String> = []) -> [GeofenceSpec] {
        let triggers = rules.filter(\.enabled).map(\.trigger)
        let byId = Dictionary(places.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let ordered = places.filter { tracked.contains($0.id) } + places.filter { !tracked.contains($0.id) }
        let placeFences = ordered.compactMap { place -> GeofenceSpec? in
            let logged = tracked.contains(place.id)
            let enter = logged || triggers.contains { if case .geofenceEnter(place.id) = $0 { return true } else { return false } }
            let exit = logged || triggers.contains { if case .geofenceExit(place.id) = $0 { return true } else { return false } }
            guard enter || exit else { return nil }
            return GeofenceSpec(id: placePrefix + place.id, centre: place.centre, radiusM: Double(place.radiusM), enter: enter, exit: exit)
        }

        var seenApproach = Set<String>()
        let approachFences = triggers.compactMap { t -> GeofenceSpec? in
            guard case .approaching(let id, let km) = t, let place = byId[id] else { return nil }
            let fenceId = "\(approachPrefix)\(id):\(km)"
            guard seenApproach.insert(fenceId).inserted else { return nil }
            return GeofenceSpec(id: fenceId, centre: place.centre, radiusM: km * 1000, enter: true, exit: false)
        }

        var carFences: [GeofenceSpec] = []
        if let carPosition {
            var seen = Set<Int>()
            for case .nearCar(let m) in triggers where seen.insert(m).inserted {
                carFences.append(GeofenceSpec(id: "\(carPrefix)\(m)", centre: carPosition, radiusM: Double(m), enter: true, exit: false))
            }
        }
        return placeFences + approachFences + carFences
    }

    /// Whether any enabled rule needs the car's position kept fresh.
    public static func needsCarPosition(_ rules: [Rule]) -> Bool {
        rules.contains { rule in
            if rule.enabled, case .nearCar = rule.trigger { return true }
            return false
        }
    }

    /// The place a region watches, for place regions.
    public static func placeId(for regionId: String) -> String? {
        regionId.hasPrefix(placePrefix) ? String(regionId.dropFirst(placePrefix.count)) : nil
    }

    public static func event(for regionId: String, transition: Transition) -> TriggerEvent? {
        if regionId.hasPrefix(placePrefix) {
            let id = String(regionId.dropFirst(placePrefix.count))
            return transition == .enter ? .geofenceEntered(placeId: id) : .geofenceExited(placeId: id)
        }
        guard transition == .enter else { return nil }
        if regionId.hasPrefix(carPrefix) {
            return Int(regionId.dropFirst(carPrefix.count)).map { .approachedCar(meters: $0) }
        }
        if regionId.hasPrefix(approachPrefix) {
            // Place ids may contain ':', so split on the last one.
            let rest = regionId.dropFirst(approachPrefix.count)
            guard let sep = rest.lastIndex(of: ":"), sep > rest.startIndex, let km = Double(rest[rest.index(after: sep)...]) else { return nil }
            return .approached(placeId: String(rest[..<sep]), km: km)
        }
        return nil
    }
}

// MARK: - Templates

/// Example rules offered in the editor (HANDOVER.md §6.2).
public enum Templates {
    public struct Template: Sendable {
        public var title: String
        public var description: String
        public var placeHint: String
        public var build: @Sendable (_ placeId: String) -> Rule
    }

    public static let all: [Template] = [
        Template(
            title: "Leaving work",
            description: "Leave the office Mon–Fri 16:00–19:00 below 5 °C, phone near the car → heat to 21 °C",
            placeHint: "Office",
            build: { leavingWork(officeId: $0) }
        ),
        Template(
            title: "Morning commute",
            description: "Mon–Fri 07:20, car at Home and you with it, forecast at 07:40 below 3 °C → heat to 20 °C",
            placeHint: "Home",
            build: { morningCommute(homeId: $0) }
        ),
        Template(
            title: "Hot day",
            description: "Leave the office when it is above 24 °C at the car → cool to 20 °C",
            placeHint: "Office",
            build: { hotDay(officeId: $0) }
        ),
    ]

    public static func leavingWork(officeId: String, id: String = newId()) -> Rule {
        Rule(
            id: id,
            name: "Leaving work",
            trigger: .geofenceExit(placeId: officeId),
            conditions: [
                .daysOfWeek(Weekday.weekdays),
                .timeWindow(start: TimeOfDay(16, 0), end: TimeOfDay(19, 0)),
                .tempBelow(celsius: 5, source: .bestAvailable),
                // Only if you're actually with the car, not if it was left at work while you're elsewhere.
                .phoneNearCar(meters: 1500),
            ],
            action: .startClimate(targetC: 21)
        )
    }

    public static func morningCommute(homeId: String, id: String = newId()) -> Rule {
        Rule(
            id: id,
            name: "Morning commute",
            trigger: .schedule(days: Weekday.weekdays, time: TimeOfDay(7, 20)),
            conditions: [
                .carAtPlace(placeId: homeId),
                // Not when you're away (on holiday, say) and the car is at home.
                .phoneNearCar(meters: 500),
                .tempBelow(celsius: 3, source: .forecastAt(TimeOfDay(7, 40))),
            ],
            action: .startClimate(targetC: 20)
        )
    }

    public static func hotDay(officeId: String, id: String = newId()) -> Rule {
        Rule(
            id: id,
            name: "Hot day",
            trigger: .geofenceExit(placeId: officeId),
            conditions: [.tempAbove(celsius: 24, source: .weatherAtCar)],
            action: .startClimate(targetC: 20)
        )
    }

    public static func newId() -> String { UUID().uuidString.lowercased() }
}
