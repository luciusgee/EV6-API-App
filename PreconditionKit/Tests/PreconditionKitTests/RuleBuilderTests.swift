import Foundation
import XCTest
@testable import PreconditionKit

final class RuleBuilderTests: XCTestCase {
    func testAColdWeekdayMorningWithAllTheHeating() {
        // "Weekdays at 6:30, if it's 10 or less, warm to 22 with the steering wheel and mirrors on."
        var b = RuleBuilder()
        b.time = TimeOfDay(6, 30)
        b.coldBelowC = 11
        b.warmC = 22
        b.heatedExtras = true
        let rule = b.build(id: "r1")
        XCTAssertEqual(rule.trigger, .schedule(days: Weekday.weekdays, time: TimeOfDay(6, 30)))
        XCTAssertEqual(rule.conditions, [.tempBelow(celsius: 11, source: .forecastAt(TimeOfDay(6, 30)))])
        XCTAssertEqual(rule.action, .startClimate(targetC: 22))
        XCTAssertEqual(rule.climateOptions, ClimateOptions(defrost: false, heatedExtras: true))
        XCTAssertEqual(rule.name, "Weekday mornings: warm up")
        XCTAssertEqual(b.sentence { $0 }, "Weekdays at 06:30, if it's colder than 11 °C (forecast), warm the car to 22 °C with the heated wheel and mirrors.")
        XCTAssertTrue(RuleValidator.validate(rule, placeIds: []).isEmpty)
    }

    func testCoolingWhenArrivingIgnoresTheHeatingChoices() {
        var b = RuleBuilder()
        b.when = .arrive
        b.placeId = "home"
        b.doing = .cool
        b.heatedExtras = true
        b.onlyIfPluggedIn = true
        b.askFirst = true
        let rule = b.build(id: "r2", name: "  ") { $0 == "home" ? "Home" : $0 }
        XCTAssertEqual(rule.trigger, .geofenceEnter(placeId: "home"))
        XCTAssertEqual(rule.conditions, [.tempAbove(celsius: 22, source: .bestAvailable), .pluggedIn(expected: true)])
        XCTAssertEqual(rule.action, .startClimate(targetC: 19))
        XCTAssertNil(rule.climateOptions)
        XCTAssertTrue(rule.askFirst)
        XCTAssertEqual(rule.name, "Arriving at Home: cool down")
        XCTAssertEqual(b.sentence { $0 == "home" ? "Home" : $0 }, "When I get to Home, if it's warmer than 22 °C and it's plugged in, cool the car to 19 °C. Asks you first.")
    }

    func testRuleClimateOptionsSurviveASaveAndOldRulesHaveNone() throws {
        var b = RuleBuilder()
        b.defrost = true
        let rule = b.build(id: "r3")
        let back = try JSONDecoder().decode(Rule.self, from: JSONEncoder().encode(rule))
        XCTAssertEqual(back.climateOptions, ClimateOptions(defrost: true, heatedExtras: false))
        let old = #"{"id":"a","name":"Old","trigger":{"type":"nearCar","meters":100},"action":{"type":"stopClimate"}}"#
        XCTAssertNil(try JSONDecoder().decode(Rule.self, from: Data(old.utf8)).climateOptions)
    }
}
