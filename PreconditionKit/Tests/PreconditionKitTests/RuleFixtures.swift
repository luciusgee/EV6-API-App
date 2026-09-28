import Foundation
@testable import PreconditionKit

// Shared rule fixtures, as in the Android `TestFixtures.kt`.

let prague = TimeZone(identifier: "Europe/Prague")!
let pragueClock = LocalClock(timeZone: prague)

/// Wednesday 23 Sep 2026 at the given Prague time.
func wednesdayAt(_ hour: Int, _ minute: Int = 0) -> Date {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = prague
    return c.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: hour, minute: minute))!
}

func days(_ n: Int, after date: Date) -> Date {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = prague
    return c.date(byAdding: .day, value: n, to: date)!
}

let office = Place(id: "office", name: "Office", centre: LatLon(lat: 50.0870, lon: 14.4210), radiusM: 200, usualParkingSpot: LatLon(lat: 50.0875, lon: 14.4215))
let home = Place(id: "home", name: "Home", centre: LatLon(lat: 50.0500, lon: 14.3000), radiusM: 150)
let places = ["office": office, "home": home]

func placeName(_ id: String) -> String { places[id]?.name ?? id }

func rule(
    _ id: String = "r1",
    name: String? = nil,
    trigger: Trigger = .geofenceExit(placeId: "office"),
    conditions: [Condition] = [],
    action: RuleAction = .startClimate(targetC: 21),
    priority: Int = 0,
    enabled: Bool = true,
    cooldownMinutes: Int = 60,
    proceedIfUnknown: Bool = false
) -> Rule {
    Rule(
        id: id, name: name ?? id, enabled: enabled, priority: priority, trigger: trigger, conditions: conditions,
        action: action, cooldownMinutes: cooldownMinutes, proceedIfUnknown: proceedIfUnknown
    )
}
