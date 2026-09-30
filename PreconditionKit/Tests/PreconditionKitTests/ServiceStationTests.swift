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
