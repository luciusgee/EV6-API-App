import Foundation
import XCTest
@testable import PreconditionKit

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
