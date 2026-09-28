import Foundation
import XCTest
@testable import PreconditionKit

final class DisplayTextTests: XCTestCase {
    let utc = TimeZone(identifier: "UTC")!

    func testBudgetLine() {
        var b = RateBudget.compute(RateBudgetState(), .kia, t0)
        XCTAssertEqual(DisplayText.budget(b, timeZone: utc), "80 left of 80 · 72 for automation · 8 kept for you")
        b = RateBudget.compute(RateBudgetState(sent: [SentRequest(id: 1, at: t0.addingTimeInterval(-600), kind: .manual)]), .kia, t0)
        XCTAssertEqual(DisplayText.budget(b, timeZone: utc), "79 left of 80 · 71 for automation · 8 kept for you · resets 14:50")
        b = RateBudget.compute(RateBudgetState(exhaustedUntil: t0.addingTimeInterval(3600)), .kia, t0)
        XCTAssertEqual(DisplayText.budget(b, timeZone: utc), "Kia's request limit reached · try again at 16:00")
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
}
