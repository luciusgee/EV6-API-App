import Foundation
import XCTest
@testable import PreconditionKit

final class JSONValueTests: XCTestCase {
    func testParsesAndReadsLeniently() throws {
        let v = try XCTUnwrap(JSONValue.parse(#"{"a":{"b":[{"c":"12.5"}]},"t":true,"one":1,"zero":"0","s":"x","n":null}"#))
        XCTAssertEqual(v.path("a.b.0.c")?.num, 12.5)
        XCTAssertNil(v.path("a.b.1.c"))
        XCTAssertNil(v.path("a.x.y"))
        XCTAssertEqual(v["t"]?.bool, true)
        XCTAssertEqual(v["one"]?.bool, true)
        XCTAssertEqual(v["zero"]?.bool, false)
        XCTAssertNil(v["s"]?.bool)
        XCTAssertEqual(v["one"]?.str, "1")
        XCTAssertEqual(v["t"]?.str, "true")
        XCTAssertEqual(v["n"], .null)
        XCTAssertNil(v["n"]?.str)
        XCTAssertNil(JSONValue.parse("not json"))
    }

    func testPrintsStableCompactJSON() {
        let v: JSONValue = ["b": 1, "a": [true, nil, 10.9, "x/y"]]
        XCTAssertEqual(v.text, #"{"a":[true,null,10.9,"x/y"],"b":1}"#)
        XCTAssertEqual(JSONValue.parse(v.text), v)
    }
}

final class DigestTests: XCTestCase {
    func testPortableSHA256MatchesKnownVectors() {
        XCTAssertEqual(Digest.hex(PortableSHA256.hash([])), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(Digest.hex(PortableSHA256.hash(Array("abc".utf8))), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(
            Digest.hex(PortableSHA256.hash(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        )
        // Longer than one block.
        let million = [UInt8](repeating: UInt8(ascii: "a"), count: 1_000_000)
        XCTAssertEqual(Digest.hex(PortableSHA256.hash(million)), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    func testPlatformDigestAgreesWithThePortableOne() {
        let token = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ABCDEFGHIJKL"
        XCTAssertEqual(Digest.sha256Hex(token), Digest.hex(PortableSHA256.hash(Array(token.utf8))))
    }
}

final class VinTests: XCTestCase {
    func testMasksAllButTheLastFour() {
        XCTAssertEqual(maskVin("KNAC381ABN5000001"), "*************0001")
        XCTAssertEqual(maskVin("0001"), "0001")
    }

    func testRedactsTheKnownVinAndAnythingVinShaped() {
        let text = #"{"vin":"knac381abn5000001","other":"KNAC381ABN5000002","id":"veh-ev"}"#
        XCTAssertEqual(
            redactVin(text, vin: "KNAC381ABN5000001"),
            #"{"vin":"*************0001","other":"*************0002","id":"veh-ev"}"#
        )
        XCTAssertEqual(redactVin("no vin here", vin: nil), "no vin here")
    }
}

final class GuardTests: XCTestCase {
    func car(soc: Int? = 50, plugged: Bool? = false, climate: ClimateState = .off) -> VehicleSnapshot {
        VehicleSnapshot(socPercent: soc, pluggedIn: plugged, climate: climate, climateRawState: climate == .running ? "ON" : nil, fetchedAt: t0)
    }

    func testSocGuard() {
        XCTAssertEqual(Guards.soc(car(soc: 50), minPercent: 25), Check("SoC guard", .pass, "SoC 50% ≥ 25%"))
        XCTAssertEqual(Guards.soc(car(soc: 20), minPercent: 25), Check("SoC guard", .fail, "SoC 20% below minimum 25%"))
        XCTAssertEqual(Guards.soc(car(soc: nil), minPercent: 25).result, .fail)
        XCTAssertEqual(Guards.soc(car(soc: 5, plugged: true), minPercent: 25), Check("SoC guard", .pass, "plugged in"))
    }

    func testClimateGuards() {
        XCTAssertEqual(Guards.notRunning(car(climate: .off)).result, .pass)
        XCTAssertEqual(Guards.notRunning(car(climate: .running)).detail, "already running (ON)")
        XCTAssertEqual(Guards.notRunning(car(climate: .unknown)).result, .fail)
        XCTAssertEqual(Guards.running(car(climate: .running)).result, .pass)
        XCTAssertEqual(Guards.running(car(climate: .off)).result, .fail)
        XCTAssertEqual(Guards.running(car(climate: .unknown)).result, .fail)
        XCTAssertEqual(Guards.soc(car(soc: 20), minPercent: 25).description, "SoC guard: SoC 20% below minimum 25%")
    }
}

final class PlaceTests: XCTestCase {
    func testDistanceAndContainment() throws {
        let prague = LatLon(lat: 50.087, lon: 14.421)
        let brno = LatLon(lat: 49.195, lon: 16.607)
        XCTAssertEqual(prague.distance(to: brno), 185_000, accuracy: 2_000)
        XCTAssertEqual(prague.distance(to: prague), 0)
        let office = Place(id: "office", name: "Office", centre: prague, radiusM: 200)
        XCTAssertTrue(office.contains(LatLon(lat: 50.088, lon: 14.421))) // ~111 m
        XCTAssertFalse(office.contains(LatLon(lat: 50.090, lon: 14.421))) // ~333 m
        XCTAssertEqual(office.parkingSpotOrCentre, prague)
    }

    func testPlaceJSONMatchesTheAndroidBackup() throws {
        let backup = try Fixtures.json("rules-backup.json")
        let first = try XCTUnwrap(backup["places"]?.array?.first)
        let place = try JSONDecoder().decode(Place.self, from: first.data)
        let reencoded = try XCTUnwrap(JSONValue.parse(try JSONEncoder().encode(place)))
        XCTAssertEqual(reencoded, first)
    }
}
