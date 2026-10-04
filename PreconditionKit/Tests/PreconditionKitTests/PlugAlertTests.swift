import Foundation
import XCTest
@testable import PreconditionKit

final class PlugAlertTests: XCTestCase {
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/London")!
        return c
    }()

    func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    let window = OffPeakWindow(start: ClockTime(hour: 23), end: ClockTime(hour: 6))

    func snap(_ time: Date, soc: Int = 45, plugged: Bool, charging: Bool = false) -> VehicleSnapshot {
        VehicleSnapshot(socPercent: soc, pluggedIn: plugged, chargingState: charging ? .charging : (plugged ? .pluggedIn : .unplugged),
                        parked: true, carCapturedAt: time, fetchedAt: time,
                        details: VehicleDetails(chargeLimitAC: 80, offPeak: window))
    }

    func evaluate(_ previous: VehicleSnapshot?, _ current: VehicleSnapshot, _ state: inout AlertState, now: Date) -> [CarAlert] {
        AlertEngine.evaluate(previous: previous, current: current, state: &state, settings: AlertSettings(), now: now, calendar: cal)
    }

    func testPluggingInIsConfirmedWithWhatHappensNext() {
        var state = AlertState()
        // Plugged in at 19:00: the 20:00 evening note will say so, so nothing now.
        var early = AlertState()
        XCTAssertTrue(evaluate(snap(at(1, 18), plugged: false), snap(at(1, 19), plugged: true), &early, now: at(1, 19, 5))
            .filter { $0.kind == .pluggedIn }.isEmpty)
        // Plugged in after 20:00: said straight away.
        let alerts = evaluate(snap(at(1, 18), plugged: false), snap(at(1, 20, 30), plugged: true), &state, now: at(1, 20, 35))
        let plugged = alerts.first { $0.kind == .pluggedIn }
        XCTAssertEqual(plugged?.title, "EV6 plugged in at 45%")
        // 45% → 80% is 25.9 kWh in the battery, 28.8 from the wall: 3.9 h at 7.4 kW from 23:00.
        XCTAssertEqual(plugged?.body, "It'll charge in the off-peak window, 23:00–06:00, and should reach 80% (its limit) by about 02:55. All set for tomorrow.")
        // Nearly empty: 7 h at 7.4 kW won't get to 80%.
        let low = AlertEngine.pluggedInBody(snap(at(1, 19), soc: 10, plugged: true), now: at(1, 19), calendar: cal)
        XCTAssertEqual(low, "It'll charge in the off-peak window, 23:00–06:00, and should be at about 73% by 06:00, when off-peak ends (80% would take until about 06:45).")
        // Still plugged in: not said again.
        XCTAssertTrue(evaluate(snap(at(1, 20, 30), plugged: true), snap(at(1, 21), plugged: true), &state, now: at(1, 21)).isEmpty)
    }

    func testPluggedInButNotChargingLateInTheWindow() {
        var state = AlertState()
        // 23:10 is too soon to worry.
        XCTAssertFalse(AlertEngine.lateInWindow(window, now: at(1, 23, 10), calendar: cal))
        XCTAssertTrue(AlertEngine.lateInWindow(window, now: at(1, 23, 25), calendar: cal))
        XCTAssertTrue(AlertEngine.lateInWindow(window, now: at(2, 2), calendar: cal))
        XCTAssertFalse(AlertEngine.lateInWindow(window, now: at(2, 7), calendar: cal))
        XCTAssertFalse(AlertEngine.lateInWindow(window, now: at(1, 20), calendar: cal))

        let now = at(1, 23, 30)
        let alerts = evaluate(nil, snap(at(1, 23, 29), plugged: true), &state, now: now)
        XCTAssertEqual(alerts.first { $0.kind == .notCharging }?.body,
                       "It's past 23:00 and it hasn't started. If your charger needs confirming in its app, do that now.")
        // Charging starts: cleared, and no repeat.
        XCTAssertTrue(evaluate(nil, snap(at(1, 23, 40), plugged: true, charging: true), &state, now: at(1, 23, 45)).filter { $0.kind == .notCharging }.isEmpty)
    }

    func testTheEveningReminderSkipsWhenItsAlreadySorted() {
        let r = PlugReminder(enabled: true, at: ClockTime(hour: 21), skipAbovePercent: 90)
        // Unplugged at teatime: remind at 21:00 today.
        XCTAssertEqual(r.next(after: at(1, 18), snapshot: snap(at(1, 17), plugged: false), calendar: cal), at(1, 21))
        // Plugged in this evening: the note still comes, saying it's all set.
        XCTAssertEqual(r.next(after: at(1, 19), snapshot: snap(at(1, 18, 30), plugged: true), calendar: cal), at(1, 21))
        let allSet = PlugReminder.message(snapshot: snap(at(1, 18, 30), plugged: true), now: at(1, 19), timeZone: cal.timeZone)
        XCTAssertEqual(allSet.title, "EV6 is plugged in at 45%")
        XCTAssertTrue(allSet.body.hasSuffix("All set for tomorrow."), allSet.body)
        // Plugged in, but that reading is from yesterday: still remind.
        XCTAssertEqual(r.next(after: at(2, 8), snapshot: snap(at(1, 22), plugged: true), calendar: cal), at(2, 21))
        // Charged enough already.
        XCTAssertEqual(r.next(after: at(1, 18), snapshot: snap(at(1, 17), soc: 92, plugged: false), calendar: cal), at(2, 21))
        // After 21:00: tomorrow.
        XCTAssertEqual(r.next(after: at(1, 21, 30), snapshot: nil, calendar: cal), at(2, 21))
        XCTAssertNil(PlugReminder(enabled: false).next(after: at(1, 18), snapshot: nil, calendar: cal))
        XCTAssertEqual(PlugReminder.message(snapshot: snap(at(1, 17), plugged: false), now: at(1, 21), timeZone: cal.timeZone).body,
                       "At 17:00 it was unplugged at 45%. Plug in if it needs charging tonight. Already plugged in? Tap to check.")
    }

    func testOldAlertSettingsLoadWithTheNewAlertsOn() throws {
        // Saved before these alerts existed, with tyre alerts turned off.
        let old = #"{"enabled":["chargingStopped","chargeComplete","leftUnlocked","windowOpen","lowAuxBattery","lowCharge"],"lowChargePercent":25,"lowAuxPercent":70,"backgroundChecks":true,"backgroundEveryHours":3}"#
        let s = try JSONDecoder().decode(AlertSettings.self, from: Data(old.utf8))
        XCTAssertTrue(s.enabled.contains(.pluggedIn))
        XCTAssertTrue(s.enabled.contains(.notCharging))
        XCTAssertFalse(s.enabled.contains(.tyrePressure))
        XCTAssertEqual(s.lowChargePercent, 25)
        XCTAssertEqual(s.plugReminder, PlugReminder())
        // Once saved, turning one off sticks.
        var off = s
        off.enabled.remove(.pluggedIn)
        let again = try JSONDecoder().decode(AlertSettings.self, from: JSONEncoder().encode(off))
        XCTAssertFalse(again.enabled.contains(.pluggedIn))
        XCTAssertEqual(again, off)
    }
}

extension PlugAlertTests {
    func testAStaleReportStillWarnsOnceItsLate() {
        var state = AlertState()
        let evening = snap(at(1, 19), plugged: true)
        _ = evaluate(snap(at(1, 18), plugged: false), evening, &state, now: at(1, 19, 5))
        // The car hasn't reported since 19:00; by 23:30 that means it never started.
        let now = at(1, 23, 30)
        let late = evaluate(evening, evening, &state, now: now)
        XCTAssertEqual(late.map(\.kind), [.notCharging])
        // And only once.
        XCTAssertTrue(evaluate(evening, evening, &state, now: at(1, 23, 45)).isEmpty)
    }
}
