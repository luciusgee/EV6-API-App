import Foundation
import XCTest
@testable import PreconditionKit

final class OffPeakForecastTests: XCTestCase {
    var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    let window = OffPeakWindow(start: ClockTime(hour: 23), end: ClockTime(hour: 6))

    func car(soc: Int, charging: Bool, kW: Double? = nil, minutes: Int? = nil, at: String, limit: Int = 80) -> VehicleSnapshot {
        VehicleSnapshot(socPercent: soc, pluggedIn: true, chargePowerKw: kW, minutesToFullyCharged: minutes,
                        chargingState: charging ? .charging : .pluggedIn, carCapturedAt: date(at), fetchedAt: date(at),
                        details: VehicleDetails(chargeLimitAC: limit))
    }

    func testTheWindowYoureIn() {
        let night = OffPeakForecast.window(window, now: date("2026-10-03T00:38:00Z"), calendar: utc)
        XCTAssertEqual(night.end, date("2026-10-03T06:00:00Z"))
        let evening = OffPeakForecast.window(window, now: date("2026-10-02T19:00:00Z"), calendar: utc)
        XCTAssertEqual(evening.start, date("2026-10-02T23:00:00Z"))
        XCTAssertEqual(evening.end, date("2026-10-03T06:00:00Z"))
    }

    func testChargingUsesTheCarsOwnTimeToFull() {
        // 24% at 00:38, full (80%) in 6 h 10 min: 06:48, so not quite there by 06:00.
        let s = car(soc: 24, charging: true, kW: 7.4, minutes: 370, at: "2026-10-03T00:38:00Z")
        let e = OffPeakForecast.estimate(s, window: window, now: date("2026-10-03T00:40:00Z"), chargerKW: 7, usableKWh: 74, calendar: utc)
        // 322 of 370 minutes: 24 + 56 × 0.87 = 72.
        XCTAssertEqual(e?.percent, 72)
        XCTAssertEqual(e?.reachesLimit, false)
        let early = car(soc: 60, charging: true, kW: 7.4, minutes: 120, at: "2026-10-03T00:38:00Z")
        XCTAssertEqual(OffPeakForecast.estimate(early, window: window, now: date("2026-10-03T00:40:00Z"), chargerKW: 7, usableKWh: 74, calendar: utc)?.reachesLimit, true)
    }

    func testWaitingForTheWindowUsesTheChargerSpeed() {
        // Plugged in at 19:00 with 30%: 7 h at 7 kW × 0.9 is 44.1 kWh, 59% of 74 kWh: capped at 80%.
        let s = car(soc: 30, charging: false, at: "2026-10-02T19:00:00Z")
        let e = OffPeakForecast.estimate(s, window: window, now: date("2026-10-02T19:00:00Z"), chargerKW: 7, usableKWh: 74, calendar: utc)
        XCTAssertEqual(e?.percent, 80)
        XCTAssertEqual(e?.at, date("2026-10-03T06:00:00Z"))
        var unplugged = s
        unplugged.pluggedIn = false
        XCTAssertNil(OffPeakForecast.estimate(unplugged, window: window, now: date("2026-10-02T19:00:00Z"), chargerKW: 7, usableKWh: 74, calendar: utc))
    }
}
