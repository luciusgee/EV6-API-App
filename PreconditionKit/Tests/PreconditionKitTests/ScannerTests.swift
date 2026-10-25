import Foundation
import XCTest
@testable import PreconditionKit

final class ScannerTests: XCTestCase {
    let clock = MutableTime()
    lazy var adapter = FakeOBDAdapter(now: { [clock] in clock.now() })
    lazy var elm = ELM327(transport: adapter)

    // MARK: Protocol

    func testBroadcastTakesTheFirstECUAndSkipsResponsePending() throws {
        let reply = "7EA 03 41 0D 20 AA AA AA AA\r7E8 03 41 0D 30 AA AA AA AA\r>"
        XCTAssertEqual(try ISOTP.message(from: reply, responseHeader: nil), [0x41, 0x0D, 0x20])
        let pending = "7EC 03 7F 14 78 AA AA AA AA\r7EC 01 54 AA AA AA AA AA AA\r>"
        XCTAssertEqual(try ISOTP.message(from: pending, responseHeader: 0x7EC), [0x54])
    }

    func testRequestsFromManyTasksNeverInterleave() async throws {
        try await elm.initialise()
        async let a = elm.read(EGMPSensors.hvac0100)
        async let b = elm.read(EGMP.bmsMain)
        async let c = elm.read(EGMPSensors.hvac0100)
        let (x, y, z) = try await (a, b, c)
        XCTAssertEqual(x.count, 32)
        XCTAssertEqual(y.count, 59)
        XCTAssertEqual(z.count, 32)
        // Every data request is preceded by the right header.
        var header = ""
        for command in adapter.commands where !command.hasPrefix("AT") || command.hasPrefix("ATSH") {
            if command.hasPrefix("ATSH") { header = command } else if command == "220100" {
                XCTAssertEqual(header, "ATSH7B3")
            } else if command == "220101" {
                XCTAssertEqual(header, "ATSH7E4")
            }
        }
    }

    // MARK: Sensors

    func testEverySensorDecodesFromTheSimulatedCar() async throws {
        try await elm.initialise()
        var values: [String: Double] = [:]
        for request in LivePoller.requests(for: EGMPSensors.all) {
            if let data = try? await elm.read(request) {
                values.merge(Sensor.decode(EGMPSensors.all, request: request, data: data)) { $1 }
            }
        }
        let missing = EGMPSensors.all.map(\.id).filter { values[$0] == nil }
        XCTAssertEqual(Set(missing), ["obdLoad", "obdPedal"], "only PIDs the car doesn't support may be missing")
        XCTAssertEqual(values["socBMS"], 72)
        XCTAssertEqual(values["soh"], 98.7)
        XCTAssertEqual(values["speed"], 0)
        XCTAssertEqual(values["cabin"], 19.5)
        XCTAssertEqual(values["outside"], 8)
        XCTAssertEqual(values["odometer"], 18_234)
        XCTAssertEqual(values["gear"].map(EGMPSensors.gearName), "P")
        XCTAssertEqual(values["obdVoltage"], 14.5)
        XCTAssertEqual(values["psiFL"], 36.4)
        // Max and min come in 20 mV steps.
        XCTAssertEqual(values["cellSpread"] ?? 0, 20, accuracy: 0.1)
    }

    func testPollerGroupsRequestsAndBacksOffSilentModules() async throws {
        var car = FakeOBDAdapter.Car()
        car.modules.remove(EGMPSensors.hvac)
        let adapter = FakeOBDAdapter(car: car)
        let sensors = ["socBMS", "power", "speed", "cabin"].compactMap(EGMPSensors.sensor)
        XCTAssertEqual(LivePoller.requests(for: sensors).count, 2)
        let poller = LivePoller(elm: ELM327(transport: adapter), sensors: sensors)
        for _ in 0..<8 { _ = try await poller.poll() }
        let hvacAsks = adapter.commands.filter { $0 == "220100" }.count
        let bmsAsks = adapter.commands.filter { $0 == "220101" }.count
        XCTAssertEqual(bmsAsks, 8)
        XCTAssertLessThan(hvacAsks, 5)
        let latest = await poller.latest
        XCTAssertEqual(latest["socBMS"], 72)
        XCTAssertNil(latest["speed"])
    }

    func testRecordingCSV() {
        var r = DataRecording(started: t0, sensorIds: ["speed", "power"])
        r.add(LiveSample(at: t0.addingTimeInterval(0.5), values: ["speed": 12, "power": 30.25]))
        r.add(LiveSample(at: t0.addingTimeInterval(1), values: ["speed": 14]))
        XCTAssertEqual(r.csv(sensors: EGMPSensors.all), "time_s,\"Speed (km/h)\",\"Battery power (kW)\"\n0.50,12.0,30.2\n1.00,14.0,\n")
        XCTAssertEqual(r.duration, 1)
    }

    // MARK: Diagnostics

    func testScanReadAndClearTroubleCodes() async throws {
        let diag = Diagnostics(elm: elm)
        let found = try await diag.scan()
        XCTAssertEqual(Set(found.map(\.header)), adapter.car.modules)
        XCTAssertEqual(found.first?.name, "Battery management (BMS)")

        let gateway = ECU.named(0x770)
        let codes = try await diag.troubleCodes(gateway)
        XCTAssertEqual(codes.map(\.displayCode), ["U3003-16"])
        XCTAssertEqual(codes.first?.meaning, "Battery voltage out of range (often a weak 12 V battery)")
        XCTAssertEqual(codes.first?.stateText, "stored")
        XCTAssertEqual(codes.first?.system, "Network")
        let brakes = try await diag.troubleCodes(ECU.named(0x7D1))
        XCTAssertEqual(brakes.first?.stateText, "active now, stored")

        let snapshot = try await diag.snapshot(codes[0])
        XCTAssertFalse(snapshot.isEmpty)

        try await diag.clear(gateway)
        let after = try await diag.troubleCodes(gateway)
        XCTAssertTrue(after.isEmpty)
        let emission = try await diag.emissionCodes()
        XCTAssertTrue(emission.isEmpty)
    }

    func testDTCParsing() {
        XCTAssertEqual(TroubleCode.sae(0x0A, 0xA6), "P0AA6")
        XCTAssertEqual(TroubleCode.sae(0x56, 0x11), "C1611")
        XCTAssertEqual(TroubleCode.sae(0xC1, 0x00), "U0100")
        XCTAssertEqual(TroubleCode.sae(0x96, 0x00), "B1600")
        XCTAssertEqual(Diagnostics.parseOBD([0x02, 0x0A, 0xA6, 0x05, 0x62], status: 0x08).map(\.code), ["P0AA6", "P0562"])
        XCTAssertEqual(Diagnostics.parseUDS([0xFF, 0x0A, 0xA6, 0x00, 0x2F, 0, 0, 0, 0], ecu: 0x7E4).map(\.code), ["P0AA6"])
    }

    func testIdentifiersVinAndSupportedPIDs() async throws {
        let diag = Diagnostics(elm: elm)
        try await elm.initialise()
        let identity = await diag.identity(ECU.named(0x7E4))
        XCTAssertEqual(identity.fields.first?.0, "VIN")
        XCTAssertEqual(identity.fields.first?.1, "KNAC381AFN5012345")
        XCTAssertTrue(identity.fields.contains { $0.0 == "Software version" })
        let vin = await diag.vin()
        XCTAssertEqual(vin, "KNAC381AFN5012345")
        let supported = await diag.supportedPIDs()
        XCTAssertEqual(supported.subtracting([0x20, 0x40]), [0x0D, 0x1F, 0x21, 0x31, 0x42, 0x46, 0x5B])
    }

    // MARK: Performance

    func testQuarterMileFromTheSimulatedLaunch() async throws {
        var car = FakeOBDAdapter.Car()
        car.drive = .launch(since: t0.addingTimeInterval(1))
        adapter.car = car
        var timer = RunTimer(type: .quarterMile)
        var sixty = RunTimer(type: .zeroTo60mph)
        try await elm.initialise()
        for step in 0..<400 {
            clock.set(t0.addingTimeInterval(Double(step) * 0.1))
            let data = try await elm.read(EGMPSensors.hvac0100)
            let kmh = EGMPSensors.sensor("speed")!.value(from: data)!
            let m = adapter.motion()
            timer.add(at: clock.now(), kmh: kmh, powerKW: m.kW)
            sixty.add(at: clock.now(), kmh: kmh)
            if case .finished = timer.state { break }
        }
        guard case .finished(let q) = timer.state, case .finished(let s) = sixty.state else { return XCTFail("\(timer.state) \(sixty.state)") }
        XCTAssertEqual(s.seconds, 5.0, accuracy: 0.3)
        XCTAssertEqual(q.seconds, 14, accuracy: 1.5)
        XCTAssertEqual(q.peakPowerKW ?? 0, 239, accuracy: 0.5)
    }

    func testTripComputer() {
        var trip = TripComputer(started: t0)
        // 36 km/h for 100 s using 10 kW, then 50 s regenerating 20 kW.
        for i in 0...100 { trip.add(at: t0.addingTimeInterval(Double(i)), kmh: 36, powerKW: 10) }
        for i in 101...150 { trip.add(at: t0.addingTimeInterval(Double(i)), kmh: 36, powerKW: -20) }
        XCTAssertEqual(trip.distanceKm, 1.5, accuracy: 0.001)
        let used: Double = 1000.0 / 3600
        let regen: Double = 1000.0 / 3600
        XCTAssertEqual(trip.usedKWh, used, accuracy: 0.005)
        XCTAssertEqual(trip.regenKWh, regen, accuracy: 0.01)
        XCTAssertEqual(trip.maxRegenKW, 20)
        XCTAssertEqual(trip.averageSpeedKmh ?? 0, 36, accuracy: 0.01)
        XCTAssertNotNil(trip.kWhPer100km)
        // A long gap isn't counted.
        trip.add(at: t0.addingTimeInterval(1000), kmh: 36, powerKW: 10)
        XCTAssertEqual(trip.seconds, 150)
    }
}
