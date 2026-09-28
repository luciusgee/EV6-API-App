import Foundation
import XCTest
@testable import PreconditionKit

final class RuleComposerTests: XCTestCase {
    let home = Place(id: "home", name: "Home", centre: LatLon(lat: 51.5, lon: -0.1), radiusM: 150)
    let office = Place(id: "office", name: "Office", centre: LatLon(lat: 51.52, lon: -0.08), radiusM: 200)
    var places: [Place] { [home, office] }

    func compose(_ s: String) -> RuleComposer.Result { RuleComposer.compose(s, places: places) }

    func testWeekdayMorningBelowATemperature() throws {
        let r = compose("Weekdays at 7:30 heat to 22 degrees if it's below 5")
        let rule = try XCTUnwrap(r.rule)
        XCTAssertEqual(rule.trigger, .schedule(days: Weekday.weekdays, time: TimeOfDay(7, 30)))
        XCTAssertEqual(rule.action, .startClimate(targetC: 22))
        XCTAssertEqual(rule.conditions, [.tempBelow(celsius: 5, source: .forecastAt(TimeOfDay(7, 50)))])
        XCTAssertEqual(rule.name, "Weekday morning")
        XCTAssertEqual(r.problems, [])
        XCTAssertTrue(RuleValidator.validate(rule, placeIds: ["home", "office"]).isEmpty)
    }

    func testLeavingWorkAfterFiveWhenFreezing() throws {
        let r = compose("when I leave work after 5pm and it's freezing, warm the car")
        let rule = try XCTUnwrap(r.rule)
        XCTAssertEqual(rule.trigger, .geofenceExit(placeId: "office"))
        XCTAssertEqual(rule.action, .startClimate(targetC: 21))
        XCTAssertTrue(rule.conditions.contains(.timeWindow(start: TimeOfDay(17, 0), end: TimeOfDay(23, 59))))
        XCTAssertTrue(rule.conditions.contains(.tempBelow(celsius: 3, source: .bestAvailable)))
        XCTAssertEqual(rule.name, "Leaving Office")
    }

    func testCoolingWhenArrivingHome() throws {
        let rule = try XCTUnwrap(compose("Cool to 19°C when I get home if it's over 25").rule)
        XCTAssertEqual(rule.trigger, .geofenceEnter(placeId: "home"))
        XCTAssertEqual(rule.action, .startClimate(targetC: 19))
        XCTAssertEqual(rule.conditions, [.tempAbove(celsius: 25, source: .bestAvailable)])
    }

    func testTwelveHourTimesHalfPastAndDays() throws {
        XCTAssertEqual(try XCTUnwrap(compose("every day at 6:45pm heat to 21").rule).trigger, .schedule(days: Weekday.everyDay, time: TimeOfDay(18, 45)))
        XCTAssertEqual(try XCTUnwrap(compose("half seven on mondays and fridays").rule).trigger, .schedule(days: [.monday, .friday], time: TimeOfDay(7, 30)))
        XCTAssertEqual(try XCTUnwrap(compose("weekends at 9am").rule).trigger, .schedule(days: Weekday.weekend, time: TimeOfDay(9, 0)))
        XCTAssertEqual(try XCTUnwrap(compose("daily at 7:00 except sunday").rule).trigger, .schedule(days: Weekday.everyDay.subtracting([.sunday]), time: TimeOfDay(7, 0)))
    }

    func testPluggedInBatteryAndStop() throws {
        let rule = try XCTUnwrap(compose("weekdays at 07:15 if plugged in and battery above 40% heat to 21.5 degrees").rule)
        XCTAssertTrue(rule.conditions.contains(.pluggedIn(expected: true)))
        XCTAssertTrue(rule.conditions.contains(.socAtLeast(percent: 40)))
        XCTAssertEqual(rule.action, .startClimate(targetC: 21.5))
        XCTAssertEqual(try XCTUnwrap(compose("stop climate every day at 8:30").rule).action, .stopClimate)
    }

    func testWalkingToTheCar() throws {
        let rule = try XCTUnwrap(compose("when I walk to the car and it's cold").rule)
        XCTAssertEqual(rule.trigger, .nearCar(meters: 300))
        XCTAssertEqual(rule.conditions, [.tempBelow(celsius: 8, source: .bestAvailable)])
    }

    func testPlacesWithDaysGetADaysCondition() throws {
        let rule = try XCTUnwrap(compose("on weekdays when I leave the office heat to 20").rule)
        XCTAssertEqual(rule.conditions.first, .daysOfWeek(Weekday.weekdays))
    }

    func testUnknownPlaceAndNoTrigger() {
        let r = compose("when I leave the gym")
        XCTAssertNil(r.rule)
        XCTAssertEqual(r.unknownPlaces, ["gym"])
        XCTAssertTrue(r.problems.first?.contains("“gym”") == true)

        let vague = compose("make it warm please")
        XCTAssertNil(vague.rule)
        XCTAssertTrue(vague.problems.first?.hasPrefix("Say when") == true)
    }
}

final class InsightsTests: XCTestCase {
    let clock = LocalClock(timeZone: TimeZone(identifier: "UTC")!)
    let now = date("2026-09-28T20:00:00Z") // a Monday

    func start(_ iso: String, target: Double = 21) -> LogEntry {
        LogEntry(at: date(iso), kind: .manual, decision: "sent", reason: "climatise to \(String(format: "%.1f", target)) °C accepted")
    }

    func testRepeatedMorningStartsBecomeARule() throws {
        let log = [
            start("2026-09-21T07:22:00Z"), start("2026-09-22T07:31:00Z", target: 22), start("2026-09-23T07:25:00Z"),
            start("2026-09-24T07:28:00Z"), start("2026-09-24T07:29:00Z"), // same day twice counts once
            start("2026-09-25T18:00:00Z"), // not part of the habit
        ]
        let s = Insights.suggestions(log: log, rules: [], settings: AppSettings(), now: now, clock: clock)
        let habit = try XCTUnwrap(s.first { $0.id == "habit-weekdays" })
        XCTAssertEqual(habit.title, "You start climate around 07:28 on weekdays")
        guard case .addRule(let rule)? = habit.fix else { return XCTFail("expected a rule") }
        XCTAssertEqual(rule.trigger, .schedule(days: Weekday.weekdays, time: TimeOfDay(7, 10)))
        XCTAssertEqual(rule.action, .startClimate(targetC: 21))
        XCTAssertEqual(rule.conditions, [.tempBelow(celsius: 10, source: .forecastAt(TimeOfDay(7, 28)))])
        XCTAssertNil(s.first { $0.id == "habit-weekends" })
    }

    func testNoSuggestionWhenARuleAlreadyCoversIt() {
        let log = [start("2026-09-21T07:22:00Z"), start("2026-09-22T07:31:00Z"), start("2026-09-23T07:25:00Z")]
        let rule = Rule(id: "r", name: "Mornings", trigger: .schedule(days: Weekday.weekdays, time: TimeOfDay(7, 15)), action: .startClimate(targetC: 21))
        XCTAssertTrue(Insights.suggestions(log: log, rules: [rule], settings: AppSettings(), now: now, clock: clock).isEmpty)
    }

    func testTwoStartsOrOldOnesAreNotAHabit() {
        let log = [start("2026-09-21T07:22:00Z"), start("2026-09-22T07:31:00Z"), start("2026-08-01T07:25:00Z")]
        XCTAssertTrue(Insights.suggestions(log: log, rules: [], settings: AppSettings(), now: now, clock: clock).isEmpty)
    }

    func testSuggestsHoldingTheCharger() {
        let s = Insights.suggestions(
            log: [start("2026-09-21T07:22:00Z")], rules: [], settings: AppSettings(holdChargerOnClimate: false), now: now, clock: clock
        )
        XCTAssertEqual(s.map(\.id), ["hold-charger"])
        XCTAssertEqual(s.first?.fix, .holdCharger)
    }

    func testTargetParsing() {
        XCTAssertEqual(Insights.targetC(in: "climatise to 21.5 °C accepted (charger held)"), 21.5)
        XCTAssertNil(Insights.targetC(in: "stop climatisation accepted"))
    }
}
