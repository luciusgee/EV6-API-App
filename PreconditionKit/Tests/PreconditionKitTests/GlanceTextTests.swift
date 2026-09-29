import Foundation
import XCTest
@testable import PreconditionKit

final class GlanceTextTests: XCTestCase {
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/London")!
        return c
    }()

    /// Tuesday 29 September 2026.
    func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    func snap(plugged: Bool, charging: Bool = false, minutesToFull: Int? = nil) -> VehicleSnapshot {
        VehicleSnapshot(socPercent: 45, pluggedIn: plugged, minutesToFullyCharged: minutesToFull,
                        chargingState: charging ? .charging : (plugged ? .pluggedIn : .unplugged), fetchedAt: Date(),
                        details: VehicleDetails(chargeLimitAC: 80, offPeak: OffPeakWindow(start: ClockTime(hour: 23), end: ClockTime(hour: 6))))
    }

    func testTheChargePlanLine() {
        let now = at(29, 19)
        XCTAssertEqual(GlanceText.chargePlan(snap(plugged: false), smart: nil, now: now, calendar: cal), "Not plugged in")
        XCTAssertEqual(GlanceText.chargePlan(snap(plugged: true), smart: nil, now: now, calendar: cal), "Charges 23:00–06:00 to 80%")
        XCTAssertEqual(GlanceText.chargePlan(snap(plugged: true, charging: true, minutesToFull: 190), smart: nil, now: now, calendar: cal),
                       "Charging · 80% by 22:10")
        let smart = SmartChargePlan(start: at(30, 1, 30), end: at(30, 5), targetPercent: 90, kWh: 30, averagePence: 7, costPence: 210, nowCostPence: 700)
        XCTAssertEqual(GlanceText.chargePlan(snap(plugged: true), smart: smart, now: now, calendar: cal), "Smart charge 01:30–05:00 to 90%")
    }

    func testWhenReadsNaturally() {
        let now = at(29, 19)
        XCTAssertEqual(GlanceText.when(at(29, 21), now: now, calendar: cal), "today 21:00")
        XCTAssertEqual(GlanceText.when(at(30, 7, 30), now: now, calendar: cal), "tomorrow 07:30")
        XCTAssertEqual(GlanceText.when(at(1, 7, 30).addingTimeInterval(30 * 86400), now: now, calendar: cal), "Thu 07:30")
    }

    func testTheNextRule() {
        let lc = LocalClock(timeZone: cal.timeZone)
        let warm = Rule(id: "a", name: "Weekday warm-up", trigger: .schedule(days: [.monday, .tuesday, .wednesday, .thursday, .friday], time: TimeOfDay(7, 30)),
                        conditions: [], action: .startClimate(targetC: 21))
        var off = warm
        off.id = "b"
        off.name = "Disabled"
        off.enabled = false
        XCTAssertEqual(GlanceText.nextRule([warm, off], now: at(29, 19), clock: lc, calendar: cal), "Weekday warm-up · tomorrow 07:30")
        XCTAssertNil(GlanceText.nextRule([off], now: at(29, 19), clock: lc, calendar: cal))
    }
}
