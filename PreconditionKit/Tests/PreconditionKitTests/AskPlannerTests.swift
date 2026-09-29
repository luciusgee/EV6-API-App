import XCTest
@testable import PreconditionKit

final class AskPlannerTests: XCTestCase {
    func rule(ask: Bool = true, conditions: [Condition] = []) -> Rule {
        Rule(id: "home-time", name: "Leaving work", trigger: .schedule(days: [.monday, .tuesday, .wednesday, .thursday, .friday], time: TimeOfDay(17, 0)),
             conditions: conditions, action: .startClimate(targetC: 21), askFirst: ask)
    }

    func testBooksTheNextWeekdaysAtTheRuleTime() {
        // Wednesday 16:00 in Prague.
        let now = wednesdayAt(16, 0)
        let slots = AskPlanner.upcoming([rule(), rule(ask: false)], after: now, days: 7, clock: pragueClock)
        XCTAssertEqual(slots.count, 6, "Wed, Thu, Fri, Mon, Tue, Wed")
        XCTAssertEqual(slots.first?.at, wednesdayAt(17, 0))
        XCTAssertEqual(Set(slots.map(\.id)).count, slots.count)
        XCTAssertTrue(slots.allSatisfy { $0.id.hasPrefix("ask-home-time-") })
        // After today's time it starts tomorrow.
        XCTAssertEqual(AskPlanner.upcoming([rule()], after: wednesdayAt(17, 1), days: 1, clock: pragueClock).first?.at, wednesdayAt(17, 0).addingTimeInterval(86400))
    }

    func testTheForecastRulesOutOnlyWhenItFailsATemperatureCondition() {
        let cold = rule(conditions: [.tempBelow(celsius: 5, source: .weatherAtCar)])
        XCTAssertTrue(AskPlanner.forecastRulesOut(cold, forecastC: 12))
        XCTAssertFalse(AskPlanner.forecastRulesOut(cold, forecastC: 2))
        XCTAssertFalse(AskPlanner.forecastRulesOut(cold, forecastC: nil))
        let either = rule(conditions: [.tempOutside(low: 5, high: 24, source: .weatherAtCar)])
        XCTAssertTrue(AskPlanner.forecastRulesOut(either, forecastC: 15))
        XCTAssertFalse(AskPlanner.forecastRulesOut(either, forecastC: 27))
        XCTAssertFalse(AskPlanner.forecastRulesOut(rule(), forecastC: 15))
    }

    func testAskFirstIsSavedAndOldRulesDefaultToOff() throws {
        let data = try JSONEncoder().encode(rule())
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("askFirst"))
        XCTAssertTrue(try JSONDecoder().decode(Rule.self, from: data).askFirst)
        let old = try JSONDecoder().decode(Rule.self, from: JSONEncoder().encode(rule(ask: false)))
        XCTAssertFalse(old.askFirst)
    }
}
