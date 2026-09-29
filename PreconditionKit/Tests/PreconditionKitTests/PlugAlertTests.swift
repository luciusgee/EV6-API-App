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
        let alerts = evaluate(snap(at(1, 18), plugged: false), snap(at(1, 19), plugged: true), &state, now: at(1, 19, 5))
        let plugged = alerts.first { $0.kind == .pluggedIn }
        XCTAssertEqual(plugged?.title, "EV6 plugged in at 45%")
        XCTAssertEqual(plugged?.body, "It'll charge in the off-peak window, 23:00–06:00 to 80%. All set for tomorrow.")
        // Still plugged in: not said again.
        XCTAssertTrue(evaluate(snap(at(1, 19), plugged: true), snap(at(1, 20), plugged: true), &state, now: at(1, 20)).isEmpty)
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
        // Plugged in this evening: tomorrow instead.
        XCTAssertEqual(r.next(after: at(1, 19), snapshot: snap(at(1, 18, 30), plugged: true), calendar: cal), at(2, 21))
        // Plugged in, but that reading is from yesterday: still remind.
        XCTAssertEqual(r.next(after: at(2, 8), snapshot: snap(at(1, 22), plugged: true), calendar: cal), at(2, 21))
        // Charged enough already.
        XCTAssertEqual(r.next(after: at(1, 18), snapshot: snap(at(1, 17), soc: 92, plugged: false), calendar: cal), at(2, 21))
        // After 21:00: tomorrow.
        XCTAssertEqual(r.next(after: at(1, 21, 30), snapshot: nil, calendar: cal), at(2, 21))
        XCTAssertNil(PlugReminder(enabled: false).next(after: at(1, 18), snapshot: nil, calendar: cal))
        XCTAssertEqual(PlugReminder.message(snapshot: snap(at(1, 17), plugged: false), now: at(1, 21)).body,
                       "It's at 45%. Plug in if it needs charging tonight, and confirm the charger in its app if it asks.")
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
