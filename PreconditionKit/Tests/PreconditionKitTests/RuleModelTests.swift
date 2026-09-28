import Foundation
import XCTest
@testable import PreconditionKit

/// Ports of the Android `RuleJsonTest`, `RuleValidatorTest`, `ScheduleCalculatorTest`, `DescribeTest`,
/// and the geofence parts of `NearCarTest` and `GeofencesTest`.
final class RuleJSONTests: XCTestCase {
    let rules = [
        Templates.leavingWork(officeId: "office", id: "a"),
        Templates.morningCommute(homeId: "home", id: "b"),
        Templates.hotDay(officeId: "office", id: "c"),
        rule("d", trigger: .approaching(placeId: "home", km: 3.5), conditions: [
            .pluggedIn(expected: false),
            .socAtLeast(percent: 30),
            .tempAbove(celsius: 10, source: .cabinBle),
            .tempBelow(celsius: 0, source: .carOutside),
            .tempOutside(low: 16, high: 21, source: .weatherAtCar),
        ], action: .stopClimate),
        rule("e", trigger: .geofenceEnter(placeId: "home"), priority: 3, proceedIfUnknown: true),
        rule("f", trigger: .nearCar(meters: 400)),
    ]

    func testExportAndImportRoundTrip() {
        let text = RuleJSON.export(places: [office, home], rules: rules)
        let result = RuleJSON.import(text)
        XCTAssertTrue(result.ok, "\(result.issues)")
        XCTAssertEqual(result.rules, rules)
        XCTAssertEqual(result.places, [office, home])
    }

    func testExportUsesReadableTimesAndDays() {
        let text = RuleJSON.export(places: [], rules: [Templates.morningCommute(homeId: "home", id: "b")])
        XCTAssertTrue(text.contains("\"07:20\""))
        XCTAssertTrue(text.contains("\"MON\""))
        XCTAssertTrue(text.contains("\"forecastAt\""))
        XCTAssertTrue(text.contains("\"version\" : 1"))
        XCTAssertFalse(text.lowercased().contains("token"))
        XCTAssertFalse(text.lowercased().contains("vin"))
    }

    func testTheAndroidBackupFixtureImports() throws {
        let text = String(decoding: try Data(contentsOf: Fixtures.directory.appendingPathComponent("rules-backup.json")), as: UTF8.self)
        let result = RuleJSON.import(text)
        XCTAssertTrue(result.ok, "\(result.issues)")
        XCTAssertFalse(result.rules.isEmpty)
        XCTAssertFalse(result.places.isEmpty)
        // And survives a round trip through this app's export.
        let again = RuleJSON.import(RuleJSON.export(places: result.places, rules: result.rules))
        XCTAssertEqual(again.rules, result.rules)
        XCTAssertEqual(again.places, result.places)
    }

    func testHandWrittenRulesAcceptFullDayNamesAndDefaults() {
        let text = """
        {"rules": [{"id": "x", "name": "Sunday", "trigger": {"type": "schedule", "days": ["sunday"], "time": "9:05"},
          "action": {"type": "stopClimate"}, "someFutureKey": 1}]}
        """
        let result = RuleJSON.import(text)
        XCTAssertTrue(result.ok, "\(result.issues)")
        let r = result.rules[0]
        XCTAssertEqual(r.trigger, .schedule(days: [.sunday], time: TimeOfDay(9, 5)))
        XCTAssertEqual(r.cooldownMinutes, Rule.defaultCooldownMinutes)
        XCTAssertTrue(r.enabled)
        XCTAssertEqual(r.priority, 0)
        XCTAssertFalse(r.proceedIfUnknown)
        XCTAssertEqual(r.conditions, [])
    }

    func testInvalidRulesAreReportedIndividuallyAndTheRestImported() {
        let text = """
        {"places": [{"id": "home", "name": "Home", "centre": {"lat": 50.0, "lon": 14.0}, "radiusM": 150}],
         "rules": [
          {"id": "ok", "name": "Fine", "trigger": {"type": "geofenceExit", "placeId": "home"}, "action": {"type": "startClimate", "targetC": 21}},
          {"id": "bad-time", "name": "Bad time", "trigger": {"type": "schedule", "days": ["MON"], "time": "25:00"}, "action": {"type": "stopClimate"}},
          {"id": "bad-place", "name": "Gym", "trigger": {"type": "geofenceExit", "placeId": "gym"}, "action": {"type": "startClimate", "targetC": 21}},
          {"id": "hot", "name": "Too hot", "trigger": {"type": "geofenceExit", "placeId": "home"}, "action": {"type": "startClimate", "targetC": 40}},
          {"id": "ok", "name": "Duplicate", "trigger": {"type": "geofenceExit", "placeId": "home"}, "action": {"type": "stopClimate"}},
          {"id": "weird", "name": "Unknown type", "trigger": {"type": "teleport"}, "action": {"type": "stopClimate"}},
          {"id": "noaction", "name": "No action", "trigger": {"type": "geofenceExit", "placeId": "home"}}
         ]}
        """
        let result = RuleJSON.import(text)
        XCTAssertEqual(result.rules.map(\.id), ["ok"])
        let byName = Dictionary(result.issues.map { ($0.name ?? "", $0) }, uniquingKeysWith: { a, _ in a })
        XCTAssertTrue(byName["Bad time"]!.message.contains("25:00"), byName["Bad time"]!.message)
        XCTAssertTrue(byName["Gym"]!.message.contains("unknown place 'gym'"))
        XCTAssertTrue(byName["Too hot"]!.message.contains("16–30"))
        XCTAssertTrue(byName["Duplicate"]!.message.contains("duplicate id"))
        XCTAssertTrue(byName["Unknown type"]!.message.contains("teleport"))
        XCTAssertTrue(byName["No action"]!.message.contains("action"))
        XCTAssertTrue(byName["Gym"]!.description.hasPrefix("rule #3 \"Gym\""))
    }

    func testRulesMayReferToPlacesAlreadyOnThePhone() {
        let text = RuleJSON.export(places: [], rules: [Templates.hotDay(officeId: "office", id: "c")])
        XCTAssertFalse(RuleJSON.import(text).ok)
        XCTAssertTrue(RuleJSON.import(text, existingPlaceIds: ["office"]).ok)
    }

    func testInvalidPlacesAreReported() {
        let result = RuleJSON.import(#"{"places": [{"id": "p", "name": "Tiny", "centre": {"lat": 50.0, "lon": 14.0}, "radiusM": 20}]}"#)
        XCTAssertTrue(result.places.isEmpty)
        XCTAssertTrue(result.issues.first!.message.contains("radius"))
    }

    func testBrokenFilesAreReported() {
        XCTAssertEqual(RuleJSON.import("not json").issues.first?.section, "file")
        XCTAssertTrue(RuleJSON.import(#"{"version": 99}"#).issues.first!.message.contains("newer"))
        XCTAssertTrue(RuleJSON.import(#"{"rules": {}}"#).issues.first!.message.contains("not a list"))
    }

    func testTimeAndDayParsing() {
        XCTAssertEqual(TimeOfDay(parsing: "07:05"), TimeOfDay(7, 5))
        XCTAssertEqual(TimeOfDay(parsing: " 7:05 "), TimeOfDay(7, 5))
        XCTAssertNil(TimeOfDay(parsing: "7:5"))
        XCTAssertNil(TimeOfDay(parsing: "24:00"))
        XCTAssertNil(TimeOfDay(parsing: "12:60"))
        XCTAssertNil(TimeOfDay(parsing: "noon"))
        XCTAssertEqual(Weekday(parsing: "wednesday"), .wednesday)
        XCTAssertEqual(Weekday(parsing: "Fri"), .friday)
        XCTAssertNil(Weekday(parsing: "Funday"))
        XCTAssertEqual(Weekday(calendarWeekday: 1), .sunday)
        XCTAssertEqual(Weekday(calendarWeekday: 2), .monday)
        XCTAssertEqual(Weekday.sunday.calendarWeekday, 1)
        XCTAssertEqual(Weekday.monday.calendarWeekday, 2)
        XCTAssertEqual(CalendarDay(parsing: "2026-09-23"), CalendarDay(2026, 9, 23))
    }
}

final class RuleValidatorTests: XCTestCase {
    let ids: Set<String> = ["office", "home"]

    func testTemplatesAreValid() {
        for t in Templates.all {
            XCTAssertEqual(RuleValidator.validate(t.build("office"), placeIds: ids), [], t.title)
        }
    }

    func testCatchesEveryKindOfProblem() {
        let bad = Rule(
            id: "", name: " ",
            trigger: .approaching(placeId: "nowhere", km: 0),
            conditions: [
                .timeWindow(start: .noon, end: .noon),
                .daysOfWeek([]),
                .tempBelow(celsius: -60, source: .weatherAtCar),
                .tempAbove(celsius: 60, source: .weatherAtCar),
                .socAtLeast(percent: 120),
                .carAtPlace(placeId: "nowhere"),
            ],
            action: .startClimate(targetC: 10),
            cooldownMinutes: -1
        )
        let problems = RuleValidator.validate(bad, placeIds: ids)
        // 12 field problems, plus "below -60 and above 60" being impossible together.
        XCTAssertEqual(problems.count, 13, "\(problems)")
        XCTAssertTrue(RuleValidator.validate(rule(trigger: .schedule(days: [], time: .noon)), placeIds: ids).first!.contains("no days"))
        XCTAssertTrue(RuleValidator.validate(rule(trigger: .geofenceEnter(placeId: "x")), placeIds: ids).first!.contains("unknown place"))
    }

    func testDistances() {
        XCTAssertEqual(RuleValidator.validate(rule(trigger: .nearCar(meters: 300)), placeIds: []), [])
        XCTAssertTrue(RuleValidator.validate(rule(trigger: .nearCar(meters: 50)), placeIds: []).first!.contains("100–5000 m"))
        XCTAssertTrue(RuleValidator.validate(rule(conditions: [.phoneNearCar(meters: 10)]), placeIds: ids).first!.contains("50–20000 m"))
    }

    func testTemperatureRangesAndImpossibleCombinations() {
        let outside = rule(conditions: [.tempOutside(low: 16, high: 21, source: .weatherAtCar)])
        XCTAssertEqual(RuleValidator.validate(outside, placeIds: ids), [])
        let inverted = rule(conditions: [.tempOutside(low: 21, high: 16, source: .weatherAtCar)])
        XCTAssertTrue(RuleValidator.validate(inverted, placeIds: ids).first!.contains("lower limit"))

        let impossible = rule(conditions: [.tempBelow(celsius: 16, source: .bestAvailable), .tempAbove(celsius: 21, source: .bestAvailable)])
        let problem = RuleValidator.validate(impossible, placeIds: ids).first!
        XCTAssertTrue(problem.contains("can never both be true") && problem.contains("outside a range"), problem)
        // A real band ("between 5 and 16") is fine, as are different sources.
        let band = rule(conditions: [.tempBelow(celsius: 16, source: .bestAvailable), .tempAbove(celsius: 5, source: .bestAvailable)])
        XCTAssertEqual(RuleValidator.validate(band, placeIds: ids), [])
        let mixed = rule(conditions: [.tempBelow(celsius: 16, source: .cabinBle), .tempAbove(celsius: 21, source: .weatherAtCar)])
        XCTAssertEqual(RuleValidator.validate(mixed, placeIds: ids), [])
    }

    func testValidatesPlaces() {
        XCTAssertEqual(RuleValidator.validatePlace(office), [])
        XCTAssertEqual(RuleValidator.validatePlace(Place(id: "", name: "", centre: LatLon(lat: 95, lon: 0), radiusM: 5000)).count, 4)
    }
}

final class ScheduleCalculatorTests: XCTestCase {
    let weekdays0720: (Set<Weekday>, TimeOfDay) = (Weekday.weekdays, TimeOfDay(7, 20))

    func next(_ s: (Set<Weekday>, TimeOfDay), after: Date) -> Date? {
        ScheduleCalculator.next(days: s.0, time: s.1, after: after, clock: pragueClock)
    }

    func testNextOccurrenceLaterToday() {
        XCTAssertEqual(next(weekdays0720, after: wednesdayAt(6)), wednesdayAt(7, 20))
    }

    func testNextOccurrenceSkipsTheWeekend() {
        let friday = days(2, after: wednesdayAt(8))
        XCTAssertEqual(next(weekdays0720, after: friday), days(5, after: wednesdayAt(7, 20)))
    }

    func testExactlyAtTheTimeMeansTheNextOne() {
        XCTAssertEqual(next(weekdays0720, after: wednesdayAt(7, 20)), days(1, after: wednesdayAt(7, 20)))
    }

    func testOneDayAWeekWrapsToNextWeek() {
        XCTAssertEqual(next(([.wednesday], TimeOfDay(7, 20)), after: wednesdayAt(9)), days(7, after: wednesdayAt(7, 20)))
    }

    func testNoDaysNeverFires() {
        XCTAssertNil(next(([], .noon), after: wednesdayAt(9)))
    }

    func testSoonestCheckAcrossEnabledRules() {
        let rules = [
            rule("a", trigger: .schedule(days: Weekday.weekdays, time: TimeOfDay(7, 20))),
            rule("b", trigger: .schedule(days: Weekday.weekdays, time: TimeOfDay(6, 45))),
            rule("c", trigger: .schedule(days: Weekday.weekdays, time: TimeOfDay(6, 30)), enabled: false),
            rule("d"),
        ]
        let next = ScheduleCalculator.nextCheck(rules, after: wednesdayAt(6), clock: pragueClock)
        XCTAssertEqual(next, ScheduledCheck(at: wednesdayAt(6, 45), time: TimeOfDay(6, 45)))
        XCTAssertNil(ScheduleCalculator.nextCheck([rule("d")], after: wednesdayAt(6), clock: pragueClock))
    }

    func testATimeInTheSpringForwardGapMovesForward() {
        // Clocks go forward at 02:00 on Sunday 29 March 2026 in Prague.
        var c = Calendar(identifier: .gregorian)
        c.timeZone = prague
        let saturday = c.date(from: DateComponents(year: 2026, month: 3, day: 28, hour: 12))!
        let next = ScheduleCalculator.next(days: [.sunday], time: TimeOfDay(2, 30), after: saturday, clock: pragueClock)!
        XCTAssertEqual(pragueClock.timeOfDay(next), TimeOfDay(3, 30))
        XCTAssertEqual(pragueClock.day(next), CalendarDay(2026, 3, 29))
    }

    func testLocalClock() {
        XCTAssertEqual(pragueClock.weekday(wednesdayAt(17)), .wednesday)
        XCTAssertEqual(pragueClock.timeOfDay(wednesdayAt(17, 5)), TimeOfDay(17, 5))
        XCTAssertEqual(pragueClock.day(wednesdayAt(0)), CalendarDay(2026, 9, 23))
        XCTAssertEqual(pragueClock.date(TimeOfDay(7, 40), sameDayAs: wednesdayAt(9), daysLater: 1), days(1, after: wednesdayAt(7, 40)))
    }
}

final class DescribeTests: XCTestCase {
    func testDescribesTriggersEventsConditionsAndActions() {
        XCTAssertEqual(Describe.trigger(.geofenceExit(placeId: "office"), placeName: placeName), "leave Office")
        XCTAssertEqual(Describe.trigger(.geofenceEnter(placeId: "home"), placeName: placeName), "arrive at Home")
        XCTAssertEqual(Describe.trigger(.approaching(placeId: "home", km: 2.5), placeName: placeName), "within 2.5 km of Home")
        XCTAssertEqual(Describe.trigger(.approaching(placeId: "home", km: 3), placeName: placeName), "within 3 km of Home")
        XCTAssertEqual(Describe.trigger(.schedule(days: Weekday.weekdays, time: TimeOfDay(7, 20)), placeName: placeName), "Mon–Fri at 07:20")
        XCTAssertEqual(Describe.trigger(.nearCar(meters: 300), placeName: placeName), "within 300 m of the car")
        XCTAssertEqual(Describe.days(Weekday.everyDay), "every day")
        XCTAssertEqual(Describe.days(Weekday.weekend), "Sat–Sun")
        XCTAssertEqual(Describe.days([.wednesday, .monday]), "Mon,Wed")

        XCTAssertEqual(Describe.event(.geofenceExited(placeId: "office"), placeName: placeName), "left Office")
        XCTAssertEqual(Describe.event(.geofenceEntered(placeId: "home"), placeName: placeName), "arrived at Home")
        XCTAssertEqual(Describe.event(.approached(placeId: "home", km: 5), placeName: placeName), "approaching Home (5 km)")
        XCTAssertEqual(Describe.event(.scheduleFired(time: TimeOfDay(7, 20)), placeName: placeName), "schedule 07:20")
        XCTAssertEqual(Describe.event(.approachedCar(meters: 300), placeName: placeName), "approaching the car (300 m)")

        XCTAssertEqual(Describe.condition(.timeWindow(start: TimeOfDay(16, 0), end: TimeOfDay(19, 0)), placeName: placeName), "16:00–19:00")
        XCTAssertEqual(Describe.condition(.daysOfWeek(Weekday.weekdays), placeName: placeName), "Mon–Fri")
        XCTAssertEqual(Describe.condition(.tempBelow(celsius: 5, source: .bestAvailable), placeName: placeName), "temp at car below 5.0 °C")
        XCTAssertEqual(Describe.condition(.tempAbove(celsius: 24, source: .weatherAtCar), placeName: placeName), "weather at car above 24.0 °C")
        XCTAssertEqual(Describe.condition(.tempBelow(celsius: 3, source: .forecastAt(TimeOfDay(7, 40))), placeName: placeName), "forecast at 07:40 below 3.0 °C")
        XCTAssertEqual(Describe.condition(.tempAbove(celsius: 1, source: .cabinBle), placeName: placeName), "cabin sensor above 1.0 °C")
        XCTAssertEqual(Describe.condition(.tempAbove(celsius: 1, source: .carOutside), placeName: placeName), "car outside temp above 1.0 °C")
        XCTAssertEqual(Describe.condition(.tempOutside(low: 16, high: 21, source: .weatherAtCar), placeName: placeName), "weather at car below 16.0 °C or above 21.0 °C")
        XCTAssertEqual(Describe.condition(.socAtLeast(percent: 40), placeName: placeName), "SoC ≥ 40%")
        XCTAssertEqual(Describe.condition(.pluggedIn(expected: true), placeName: placeName), "plugged in")
        XCTAssertEqual(Describe.condition(.pluggedIn(expected: false), placeName: placeName), "not plugged in")
        XCTAssertEqual(Describe.condition(.carAtPlace(placeId: "home"), placeName: placeName), "car at Home")
        XCTAssertEqual(Describe.condition(.phoneNearCar(meters: 500), placeName: placeName), "phone within 500 m of the car")
        XCTAssertEqual(Describe.condition(.phoneNearCar(meters: 1500), placeName: placeName), "phone within 1.5 km of the car")
        XCTAssertEqual(Describe.distance(2000), "2 km")

        XCTAssertEqual(
            Describe.rule(Templates.hotDay(officeId: "office"), placeName: placeName),
            "leave Office · weather at car above 24.0 °C · climatise to 20.0 °C"
        )
    }

    func testTriggerHelpers() {
        XCTAssertEqual(Trigger.geofenceExit(placeId: "office").placeId, "office")
        XCTAssertEqual(Trigger.approaching(placeId: "home", km: 1).placeId, "home")
        XCTAssertNil(Trigger.schedule(days: Weekday.weekdays, time: .noon).placeId)
        XCTAssertNil(Trigger.nearCar(meters: 300).placeId)
        XCTAssertEqual(Trigger.approaching(placeId: "home", km: 1).syntheticEvent, .approached(placeId: "home", km: 1))
        XCTAssertEqual(Trigger.nearCar(meters: 300).syntheticEvent, .approachedCar(meters: 300))
        XCTAssertEqual(TriggerEvent.geofenceExited(placeId: "office").dedupKey, "exit:office")
        XCTAssertEqual(TriggerEvent.geofenceEntered(placeId: "home").dedupKey, "enter:home")
        XCTAssertEqual(TriggerEvent.approached(placeId: "home", km: 1).dedupKey, "approach:home:1.0")
        XCTAssertEqual(TriggerEvent.approachedCar(meters: 300).dedupKey, "car:300")
        XCTAssertNil(TriggerEvent.scheduleFired(time: .noon).dedupKey)

        XCTAssertTrue(Trigger.nearCar(meters: 300).matches(.approachedCar(meters: 300), today: .monday))
        XCTAssertFalse(Trigger.nearCar(meters: 500).matches(.approachedCar(meters: 300), today: .monday))
        XCTAssertTrue(Trigger.schedule(days: [.thursday], time: .noon).matches(.scheduleFired(time: .noon), today: .thursday))
        XCTAssertFalse(Trigger.schedule(days: [.thursday], time: .noon).matches(.scheduleFired(time: .noon), today: .wednesday))
        XCTAssertFalse(Trigger.approaching(placeId: "home", km: 5).matches(.approached(placeId: "home", km: 2), today: .monday))
    }
}

final class GeofenceTests: XCTestCase {
    let parked = LatLon(lat: 50.10, lon: 14.50)

    func testPlacesApproachAndCarFences() {
        let rules = [
            rule("exit", trigger: .geofenceExit(placeId: "office")),
            rule("enter", trigger: .geofenceEnter(placeId: "office")),
            rule("near", trigger: .approaching(placeId: "home", km: 5)),
            rule("near2", trigger: .approaching(placeId: "home", km: 5)),
            rule("off", trigger: .geofenceExit(placeId: "home"), enabled: false),
            rule("a", trigger: .nearCar(meters: 300)),
            rule("b", trigger: .nearCar(meters: 300)),
            rule("c", trigger: .nearCar(meters: 800)),
        ]
        XCTAssertEqual(Geofences.required(rules, places: [office, home], carPosition: parked), [
            GeofenceSpec(id: "place:office", centre: office.centre, radiusM: 200, enter: true, exit: true),
            GeofenceSpec(id: "approach:home:5.0", centre: home.centre, radiusM: 5000, enter: true, exit: false),
            GeofenceSpec(id: "car:300", centre: parked, radiusM: 300, enter: true, exit: false),
            GeofenceSpec(id: "car:800", centre: parked, radiusM: 800, enter: true, exit: false),
        ])
        XCTAssertEqual(Geofences.required(rules, places: [office, home], carPosition: nil).count, 2)
        XCTAssertTrue(Geofences.needsCarPosition(rules))
        XCTAssertFalse(Geofences.needsCarPosition([rule("x"), rule("y", trigger: .nearCar(meters: 300), enabled: false)]))
    }

    func testRegionEventsMapBackToTriggers() {
        XCTAssertEqual(Geofences.event(for: "place:office", transition: .exit), .geofenceExited(placeId: "office"))
        XCTAssertEqual(Geofences.event(for: "place:office", transition: .enter), .geofenceEntered(placeId: "office"))
        XCTAssertEqual(Geofences.event(for: "car:300", transition: .enter), .approachedCar(meters: 300))
        XCTAssertNil(Geofences.event(for: "car:300", transition: .exit))
        XCTAssertNil(Geofences.event(for: "car:far", transition: .enter))
        // Place ids may contain ':'.
        XCTAssertEqual(Geofences.event(for: "approach:my:place:2.5", transition: .enter), .approached(placeId: "my:place", km: 2.5))
        XCTAssertNil(Geofences.event(for: "approach::2.5", transition: .enter))
        XCTAssertNil(Geofences.event(for: "approach:home:far", transition: .enter))
        XCTAssertNil(Geofences.event(for: "something", transition: .enter))
    }
}
