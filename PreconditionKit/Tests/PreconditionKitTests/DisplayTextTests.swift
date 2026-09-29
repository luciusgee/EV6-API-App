import Foundation
import XCTest
@testable import PreconditionKit

final class DisplayTextTests: XCTestCase {
    let utc = TimeZone(identifier: "UTC")!

    func testBudgetLine() {
        var b = RateBudget.compute(RateBudgetState(), .kia, t0)
        XCTAssertEqual(DisplayText.budget(b, timeZone: utc), "None used in the last 24 hours.")
        b = RateBudget.compute(RateBudgetState(sent: [SentRequest(id: 1, at: t0.addingTimeInterval(-600), kind: .manual)]), .kia, t0)
        XCTAssertEqual(DisplayText.budget(b, timeZone: utc), "Each one comes back 24 hours after it's used. Next at 14:50.")
        b = RateBudget.compute(RateBudgetState(exhaustedUntil: t0.addingTimeInterval(3600)), .kia, t0)
        XCTAssertEqual(DisplayText.budget(b, timeZone: utc), "Kia's daily limit is used up. Try again at 16:00.")
    }

    func testAge() {
        XCTAssertEqual(DisplayText.age(of: t0, now: t0.addingTimeInterval(20)), "just now")
        XCTAssertEqual(DisplayText.age(of: t0, now: t0.addingTimeInterval(5 * 60 + 30)), "5 min ago")
        XCTAssertEqual(DisplayText.age(of: t0, now: t0.addingTimeInterval(3 * 3600)), "3 h ago")
        XCTAssertEqual(DisplayText.age(of: t0, now: t0.addingTimeInterval(3 * 86400)), "3 days ago")
        XCTAssertEqual(DisplayText.age(of: t0.addingTimeInterval(60), now: t0), "just now")
    }

    func testCharging() {
        XCTAssertEqual(
            DisplayText.charging(VehicleSnapshot(chargePowerKw: 10.9, minutesToFullyCharged: 95, chargingState: .charging, fetchedAt: t0)),
            "Charging · 10.9 kW · full in 1 h 35 min"
        )
        XCTAssertEqual(DisplayText.charging(VehicleSnapshot(chargingState: .pluggedIn, fetchedAt: t0)), "Plugged in")
        XCTAssertNil(DisplayText.charging(VehicleSnapshot(fetchedAt: t0)))
        XCTAssertEqual(DisplayText.duration(minutes: 120), "2 h")
    }

    func testCredentialsNeverPrintSecrets() {
        let c = Credentials(refreshToken: KiaClientTests.refresh, vin: "KNAC381ABN5000001", pin: "1234")
        XCTAssertEqual(String(describing: c), "Credentials(refreshToken: set, vin: *************0001, pin: set)")
        XCTAssertFalse("\(c)".contains(KiaClientTests.refresh))
    }

    func testUnits() {
        XCTAssertEqual(DisplayText.distance(km: 315, miles: true), "196 mi")
        XCTAssertEqual(DisplayText.distance(km: 315, miles: false), "315 km")
        XCTAssertEqual(DisplayText.efficiency(kWhPer100km: 16, miles: false), "16.0 kWh/100 km")
        XCTAssertEqual(DisplayText.efficiency(kWhPer100km: 16, miles: true), "3.9 mi/kWh")
        XCTAssertNil(DisplayText.efficiency(kWhPer100km: nil, miles: true))
        XCTAssertEqual(DisplayText.energy(wh: 12_400), "12.4 kWh")
        XCTAssertEqual(DisplayText.energy(wh: 850), "850 Wh")
    }

    func testSpokenStatus() {
        let v = VehicleSnapshot(
            socPercent: 72, rangeKm: 315, pluggedIn: true, chargePowerKw: 7.4, minutesToFullyCharged: 65,
            climate: .running, targetTempC: 21, chargingState: .charging, fetchedAt: t0,
            details: VehicleDetails(locked: true)
        )
        XCTAssertEqual(
            DisplayText.spokenStatus(v, miles: true),
            "72%, 196 mi range. Charging at 7.4 kW, full in 1 h 5 min. Locked. Climate on at 21.0 °C."
        )
    }
}
