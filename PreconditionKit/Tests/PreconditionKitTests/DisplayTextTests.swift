import Foundation
import XCTest
@testable import PreconditionKit

final class DisplayTextTests: XCTestCase {
    func testAge() {
        XCTAssertEqual(DisplayText.age(of: t0, now: t0.addingTimeInterval(30)), "just now")
        XCTAssertEqual(DisplayText.age(of: t0, now: t0.addingTimeInterval(600)), "10 min ago")
        XCTAssertEqual(DisplayText.age(of: t0, now: t0.addingTimeInterval(7200)), "2 h ago")
    }

    func testUnits() {
        XCTAssertEqual(DisplayText.distance(km: 100, miles: true), "62 mi")
        XCTAssertEqual(DisplayText.distance(km: 100, miles: false), "100 km")
        XCTAssertEqual(DisplayText.kW(132.4), "132 kW")
        XCTAssertEqual(DisplayText.kW(7.2), "7.2 kW")
        XCTAssertEqual(DisplayText.energy(wh: 12_400), "12.4 kWh")
    }
}
