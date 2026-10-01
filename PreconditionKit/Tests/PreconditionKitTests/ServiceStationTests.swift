import XCTest
@testable import PreconditionKit

final class ServiceStationTests: XCTestCase {
    func testMotorwayServicesButNotBusinessesCalledServices() {
        for yes in ["Rugby Services", "Moto Rugby", "Watford Gap Services (M1)", "Welcome Break Newport Pagnell",
                    "Leicester Forest East Services", "Cherwell Valley Services", "Roadchef Northampton"] {
            XCTAssertTrue(ServiceStations.isMotorwayServices(yes), yes)
        }
        for no in ["Grahams Locksmith Services", "Banbury Cleaning Services", "Services", "Customer Services Desk",
                   "Oxfordshire County Council Social Services", "Forum Flavours"] {
            XCTAssertFalse(ServiceStations.isMotorwayServices(no), no)
        }
    }
}

final class ClimateDirectionTests: XCTestCase {
    func testLowSettingsAndWarmDaysCool() {
        // 17 °C on a 17 °C day: cooling, not warming.
        XCTAssertTrue(DisplayText.isCooling(targetC: 17, outsideC: 17))
        XCTAssertTrue(DisplayText.isCooling(targetC: 18, outsideC: nil))
        XCTAssertTrue(DisplayText.isCooling(targetC: 21, outsideC: 20))
        XCTAssertFalse(DisplayText.isCooling(targetC: 21, outsideC: 8))
        XCTAssertFalse(DisplayText.isCooling(targetC: 22, outsideC: nil))
    }

    func testAFreshReadingTellsWhetherACommandHappened() {
        var s = VehicleSnapshot(fetchedAt: Date())
        s.climate = .running
        XCTAssertEqual(CarModel.carShows("climatise to 17.0 °C", s), true)
        XCTAssertEqual(CarModel.carShows("stop climatisation", s), false)
        s.climate = .unknown
        XCTAssertNil(CarModel.carShows("climatise to 17.0 °C", s))
        XCTAssertNil(CarModel.carShows("set charge limits to 80% AC, 80% DC", s))
    }
}
