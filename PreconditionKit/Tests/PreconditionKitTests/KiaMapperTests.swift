import Foundation
import XCTest
@testable import PreconditionKit

final class KiaMapperTests: XCTestCase {
    func testLegacyFixtureMaps() throws {
        let v = KiaMapper.toSnapshot(
            status: try Fixtures.json("kia-status-legacy.json"),
            park: try Fixtures.json("kia-location-park.json"),
            ccs2: false,
            fetchedAt: t0
        )
        XCTAssertEqual(v.socPercent, 74)
        XCTAssertEqual(v.rangeKm, 312)
        XCTAssertEqual(v.pluggedIn, true)
        XCTAssertEqual(v.chargingState, .charging)
        XCTAssertEqual(v.chargePowerKw, 10.9)
        XCTAssertEqual(v.minutesToFullyCharged, 95)
        XCTAssertEqual(v.climate, .off)
        XCTAssertEqual(v.climateRawState, "OFF")
        XCTAssertEqual(v.targetTempC, 21.0)
        XCTAssertNil(v.outsideTempC)
        XCTAssertEqual(v.parked, true)
        XCTAssertEqual(v.parkingPosition, LatLon(lat: 50.1, lon: 14.4))
        XCTAssertEqual(v.carCapturedAt, date("2026-09-23T15:58:00Z"))
        XCTAssertEqual(v.fetchedAt, t0)
    }

    func testCcs2FixtureMaps() throws {
        let v = KiaMapper.toSnapshot(status: try Fixtures.json("kia-status-ccs2.json"), park: nil, ccs2: true, fetchedAt: t0)
        XCTAssertEqual(v.socPercent, 58)
        XCTAssertEqual(v.pluggedIn, false)
        XCTAssertEqual(v.chargingState, .unplugged)
        XCTAssertNil(v.chargePowerKw)
        XCTAssertNil(v.minutesToFullyCharged)
        XCTAssertEqual(v.climate, .running)
        XCTAssertEqual(v.targetTempC, 22.0)
        XCTAssertEqual(v.outsideTempC, 4.5)
        XCTAssertEqual(v.rangeKm, 402) // 250 miles
        XCTAssertEqual(v.parked, true)
        XCTAssertEqual(v.parkingPosition, LatLon(lat: 50.2, lon: 14.2))
        XCTAssertEqual(v.carCapturedAt, date("2026-09-23T14:30:05Z"))
    }

    func testTheVehicleListFixtureHasTheEV() throws {
        let vehicles = try XCTUnwrap(try Fixtures.json("kia-vehicles.json").path("resMsg.vehicles")?.array)
        XCTAssertEqual(vehicles.first { $0["type"] == "EV" }?["vehicleId"], "veh-ev")
    }

    func testLooseTypesAndFahrenheit() {
        let status: JSONValue = ["resMsg": ["state": ["Vehicle": [
            "DrivingReady": "1",
            "Green": [
                "BatteryManagement": ["BatteryRemain": ["Ratio": "80"]],
                "ChargingInformation": ["ConnectorFastening": ["State": 1], "Charging": ["RemainTime": 45]],
                "Electric": ["SmartGrid": ["RealTimePower": 7.4]],
            ],
            "Drivetrain": ["FuelSystem": ["DTE": ["Total": 300, "Unit": 1]]],
            "Cabin": ["HVAC": [
                "Row1": ["Driver": ["Temperature": ["Value": "OFF", "Unit": 0], "Blower": ["SpeedLevel": 0]]],
                "OutsideTemperature": ["Value": "41", "Unit": 1],
            ]],
            "Location": ["GeoCoord": ["Latitude": 0, "Longitude": 0]],
        ]]]]
        let v = KiaMapper.toSnapshot(status: status, park: nil, ccs2: true, fetchedAt: t0)
        XCTAssertEqual(v.socPercent, 80)
        XCTAssertEqual(v.chargingState, .charging)
        XCTAssertEqual(v.chargePowerKw, 7.4)
        XCTAssertEqual(v.minutesToFullyCharged, 45)
        XCTAssertEqual(v.climate, .off)
        XCTAssertNil(v.targetTempC) // "OFF"
        XCTAssertEqual(v.outsideTempC!, 5.0, accuracy: 0.001)
        XCTAssertEqual(v.rangeKm, 300)
        XCTAssertEqual(v.parked, false)
        XCTAssertNil(v.parkingPosition) // 0,0 means none
        XCTAssertNil(v.carCapturedAt)
    }

    func testAnEmptyStatusIsAllUnknown() {
        let v = KiaMapper.toSnapshot(status: ["resMsg": [:]], park: nil, ccs2: false, fetchedAt: t0)
        XCTAssertEqual(v, VehicleSnapshot(fetchedAt: t0))
    }

    func testTemperatureCodesRoundTrip() throws {
        XCTAssertEqual(KiaMapper.legacyTempCode(21.0), "0EH")
        XCTAssertEqual(KiaMapper.legacyTempCode(10.0), "00H")
        XCTAssertEqual(KiaMapper.legacyTempCode(35.0), "1FH")
        XCTAssertEqual(KiaMapper.legacyTemp("0EH", unit: 0), 21.0)
        XCTAssertEqual(KiaMapper.legacyTemp("1fH", unit: 0), 29.5)
        XCTAssertNil(KiaMapper.legacyTemp("20H", unit: 0))
        XCTAssertNil(KiaMapper.legacyTemp("0EH", unit: 1))
        XCTAssertNil(KiaMapper.legacyTemp("xx", unit: 0))

        guard case .object(let codes) = try Fixtures.json("kia-climate-payloads.json")["temp_codes"] else {
            return XCTFail("no temp_codes")
        }
        for (celsius, code) in codes {
            XCTAssertEqual(KiaMapper.legacyTempCode(Double(celsius)!), code.str, celsius)
            XCTAssertEqual(KiaMapper.legacyTemp(code.str, unit: 0), Double(celsius), celsius)
        }
    }

    func testCompactTimes() {
        let berlin = TimeZone(identifier: "Europe/Berlin")!
        let utc = TimeZone(identifier: "UTC")!
        // Winter: CET is UTC+1.
        XCTAssertEqual(KiaMapper.time("20260115080000", zone: berlin), date("2026-01-15T07:00:00Z"))
        XCTAssertEqual(KiaMapper.time("2026-09-23 14:30:05.123", zone: utc), date("2026-09-23T14:30:05Z"))
        XCTAssertNil(KiaMapper.time("20260931120000", zone: utc)) // 31 September
        XCTAssertNil(KiaMapper.time("2026", zone: utc))
        XCTAssertNil(KiaMapper.time(nil, zone: utc))
    }
}
