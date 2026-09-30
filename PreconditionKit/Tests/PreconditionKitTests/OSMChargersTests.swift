import Foundation
import XCTest
@testable import PreconditionKit

final class OSMChargersTests: XCTestCase {
    let reply = #"""
    {"elements":[
      {"type":"node","id":1,"lat":52.3601,"lon":-1.2201,"tags":{"amenity":"charging_station","operator":"Ionity","capacity":"6","socket:type2_combo":"6","socket:type2_combo:output":"350 kW"}},
      {"type":"way","id":2,"center":{"lat":52.3610,"lon":-1.2190},"tags":{"amenity":"charging_station","operator":"InstaVolt","socket:type2_combo":"4","socket:chademo":"2","socket:type2_combo:output":"160kW","socket:type2":"8","socket:type2:output":"22 kW"}},
      {"type":"node","id":3,"lat":52.5,"lon":-1.5,"tags":{"amenity":"charging_station","maxpower":"7000 W"}}
    ]}
    """#

    func testReadsCountsAndPowerAndMatchesTheNearestSite() throws {
        let sites = try OSMChargersClient.parse(Data(reply.utf8))
        XCTAssertEqual(sites.count, 3)
        let found = OSMChargersClient.match([
            (id: "ionity", position: LatLon(lat: 52.36012, lon: -1.22012)),
            (id: "instavolt", position: LatLon(lat: 52.3611, lon: -1.2191)),
            (id: "nothing", position: LatLon(lat: 51.0, lon: 0.0)),
        ], sites: sites, radiusM: 150)
        XCTAssertEqual(found["ionity"], ChargerDetails(count: 6, rapidCount: 6, maxKW: 350, operatorName: "Ionity"))
        XCTAssertEqual(found["ionity"]?.summary, "6 chargers · 350 kW")
        // No capacity: the largest socket count; the CCS speed, not the faster-sounding total.
        XCTAssertEqual(found["instavolt"], ChargerDetails(count: 8, rapidCount: 4, maxKW: 160, operatorName: "InstaVolt"))
        XCTAssertEqual(found["instavolt"]?.summary, "4 rapid of 8 · 160 kW")
        XCTAssertNil(found["nothing"])
        XCTAssertEqual(OSMChargersClient.kW("7000 W"), 7)
        XCTAssertEqual(OSMChargersClient.kW("350 kW;150 kW"), 350)
    }

    func testOneQueryForEveryCharger() {
        let q = OSMChargersClient.query([LatLon(lat: 52.1, lon: -1.2), LatLon(lat: 52.2, lon: -1.3)], radiusM: 150)
        XCTAssertTrue(q.hasPrefix("[out:json]"))
        XCTAssertEqual(q.components(separatedBy: "around:150,").count, 3)
        XCTAssertTrue(q.hasSuffix("out center tags;"))
    }
}
