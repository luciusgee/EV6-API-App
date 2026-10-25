import Foundation
import XCTest
@testable import PreconditionKit

final class ChargingTests: XCTestCase {
    func testRapidChargeCurve() {
        var s = ChargeSession(started: t0)
        // 20 minutes from 10%, the charge rising 0.06% a second: 200 kW to 60%, then 100 kW.
        for i in 0...1200 {
            let soc = 10 + Double(i) * 0.06
            s.add(at: t0.addingTimeInterval(Double(i)), packKW: soc < 60 ? -200 : -100, socPercent: soc, batteryMaxC: 30)
        }
        let fast: Double = 50 / 0.06
        let expected: Double = (200 * fast + 100 * (1200 - fast)) / 3600
        XCTAssertEqual(s.energyKWh, expected, accuracy: 0.2)
        XCTAssertEqual(s.peakKW, 200)
        XCTAssertTrue(s.isRapid)
        XCTAssertEqual(s.startSoc, 10)
        XCTAssertEqual(s.endSoc ?? 0, 82, accuracy: 0.01)
        XCTAssertEqual(s.curve.first?.soc, 10)
        XCTAssertEqual(s.curve.first { $0.soc == 70 }?.kW, 100)
        XCTAssertEqual(s.minutes(from: 10, to: 70) ?? 0, 60 / 0.06 / 60, accuracy: 0.2)
        XCTAssertEqual(s.averageKW ?? 0, s.energyKWh / (1200.0 / 3600), accuracy: 0.01)
    }

    func testGapsAddNothingAndPointsAreThinned() {
        var s = ChargeSession(started: t0)
        s.add(at: t0, packKW: -7, socPercent: 50)
        s.add(at: t0.addingTimeInterval(1), packKW: -7, socPercent: 50)
        s.add(at: t0.addingTimeInterval(600), packKW: -7, socPercent: 51)
        XCTAssertEqual(s.energyKWh, 7.0 / 3600, accuracy: 1e-6)
        XCTAssertEqual(s.points.count, 2)
        XCTAssertFalse(s.isRapid)
    }

    func testIsCharging() {
        XCTAssertTrue(ChargeSession.isCharging(packKW: -7, kmh: 0))
        XCTAssertFalse(ChargeSession.isCharging(packKW: -30, kmh: 40))
        XCTAssertFalse(ChargeSession.isCharging(packKW: 0.4, kmh: 0))
    }
}

final class VehicleTests: XCTestCase {
    func testVIN() {
        let v = VIN("KNDC3DLC5N5012345")
        XCTAssertEqual(v?.make, "Kia")
        XCTAssertEqual(v?.year, 2022)
        XCTAssertEqual(VIN("km8kn4ae1mu000001")?.make, "Hyundai")
        XCTAssertEqual(VIN("KMTKC4AB0RU000001")?.year, 2024)
        XCTAssertNil(VIN("TOO SHORT"))
        XCTAssertNil(VIN("KNDC3DLC5N50I2345"))
    }

    func testGuessAndPacks() {
        let kia = VIN("KNDC3DLC5N5012345")
        XCTAssertEqual(Vehicles.guess(vin: kia, egmp: true, cells: 192).id, "kia.ev6")
        XCTAssertEqual(Vehicles.guess(vin: kia, egmp: true, cells: 160).id, "kia.ev9")
        XCTAssertEqual(Vehicles.guess(vin: VIN("KM8KN4AE1MU000001"), egmp: true, cells: 180).id, "hyundai.ioniq5")
        XCTAssertEqual(Vehicles.guess(vin: nil, egmp: false, cells: nil).platform, .generic)
        let ev6 = Vehicles.model("kia.ev6")!
        XCTAssertEqual(ev6.pack(cells: 192, year: 2022)?.kWh, 77.4)
        XCTAssertEqual(ev6.pack(cells: 192, year: 2025)?.kWh, 84)
        XCTAssertEqual(ev6.pack(cells: 192)?.kWh, 84)
        XCTAssertEqual(PackSpec(77.4, cells: 192).label, "77.4 kWh")
        XCTAssertEqual(PackSpec(84, cells: 192).label, "84 kWh")
    }

    func testGenericSensorsDecode() {
        let rpm = GenericSensors.sensor("rpm")!
        XCTAssertEqual(rpm.value(from: [0x1A, 0xF8]), 1726)
        XCTAssertEqual(GenericSensors.sensor("coolant")!.value(from: [0x7B]), 83)
        XCTAssertEqual(Platform.generic.sensor("speed")?.request.command, "010D")
        XCTAssertEqual(Platform.egmp.sensor("speed")?.request.command, "220100")
    }
}
