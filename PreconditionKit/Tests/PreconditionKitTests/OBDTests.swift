import Foundation
import XCTest
@testable import PreconditionKit

final class OBDTests: XCTestCase {
    // MARK: ISO-TP

    func testSingleFrameWithHeaders() throws {
        let bytes = try ISOTP.message(from: "7EC 06 62 C0 0B 01 02 03 AA\r\r>", responseHeader: 0x7EC)
        XCTAssertEqual(bytes, [0x62, 0xC0, 0x0B, 0x01, 0x02, 0x03])
    }

    func testMultiFrameWithHeadersIgnoresOtherECUs() throws {
        let reply = """
        SEARCHING...
        7EC 10 0B 62 01 01 11 22 33
        7ED 03 7F 22 11 AA AA AA AA
        7EC 21 44 55 66 77 88 AA AA
        >
        """
        let bytes = try ISOTP.message(from: reply, responseHeader: 0x7EC)
        XCTAssertEqual(bytes, [0x62, 0x01, 0x01, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88])
    }

    func testMultiFrameWithoutSpaces() throws {
        let bytes = try ISOTP.message(from: "7EC1009620101112233\r7EC21445566AAAAAAAA\r>", responseHeader: 0x7EC)
        XCTAssertEqual(bytes, [0x62, 0x01, 0x01, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66])
    }

    func testHeadersOffIndexedLines() throws {
        let reply = "009\r0: 62 01 01 11 22 33\r1: 44 55 66 AA AA AA AA\r\r>"
        let bytes = try ISOTP.message(from: reply, responseHeader: 0x7EC)
        XCTAssertEqual(bytes, [0x62, 0x01, 0x01, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66])
    }

    func testFramesRoundTrip() throws {
        let message = (0..<62).map { UInt8($0) }
        let text = ISOTP.frames(message, header: 0x7EC).joined(separator: "\r")
        XCTAssertEqual(try ISOTP.message(from: text, responseHeader: 0x7EC), message)
        XCTAssertEqual(ISOTP.frames([1, 2], header: 0x7EC), ["7EC 02 01 02 AA AA AA AA AA"])
    }

    func testAdapterErrors() {
        XCTAssertThrowsError(try ISOTP.message(from: "NO DATA\r\r>", responseHeader: 0x7EC)) { XCTAssertEqual($0 as? OBDError, .noData) }
        XCTAssertThrowsError(try ISOTP.message(from: "CAN ERROR\r>", responseHeader: 0x7EC)) {
            XCTAssertEqual($0 as? OBDError, .busError("CAN ERROR"))
        }
        XCTAssertThrowsError(try ISOTP.message(from: ">", responseHeader: 0x7EC)) { XCTAssertEqual($0 as? OBDError, .timeout) }
        XCTAssertThrowsError(try ISOTP.message(from: "7EC 10 20 62 01 01 00 00 00\r>", responseHeader: 0x7EC))
    }

    // MARK: Decoding

    func testDecodesTheMainBatteryBlock() {
        var d = [UInt8](repeating: 0, count: 50)
        d[4] = 145 // 72.5 %
        d[10] = 0xFF; d[11] = 0x38 // -20.0 A
        d[12] = 0x1B; d[13] = 0x58 // 700.0 V
        d[14] = 25; d[15] = 0xFE // 25 °C, -2 °C
        d[23] = 200; d[24] = 5 // 4.00 V, cell 5
        d[25] = 195; d[26] = 90 // 3.90 V, cell 90
        d[38] = 0; d[39] = 0; d[40] = 0x8E; d[41] = 0xA0 // 36 512 → 3651.2 kWh
        var r = BatteryReport(takenAt: t0)
        EGMP.applyMain(d, to: &r)
        XCTAssertEqual(r.socBMSPercent, 72.5)
        XCTAssertEqual(r.packAmps, -20)
        XCTAssertEqual(r.packVolts, 700)
        XCTAssertEqual(r.powerKW ?? 0, -14, accuracy: 0.001)
        XCTAssertEqual(r.batteryMaxC, 25)
        XCTAssertEqual(r.batteryMinC, -2)
        XCTAssertEqual(r.cellMaxVolts, 4.0)
        XCTAssertEqual(r.cellMaxNumber, 5)
        XCTAssertEqual(r.cellMinNumber, 90)
        XCTAssertEqual(r.cumulativeChargedKWh ?? 0, 3651.2, accuracy: 0.01)
        XCTAssertEqual(r.cellSpreadMillivolts ?? 0, 100, accuracy: 0.01)
    }

    func testShortAnswersLeaveFieldsEmpty() {
        var r = BatteryReport(takenAt: t0)
        EGMP.applyMain([0, 0, 0, 0, 100], to: &r)
        XCTAssertEqual(r.socBMSPercent, 50)
        XCTAssertNil(r.packVolts)
        XCTAssertTrue(r.moduleTempsC.isEmpty)
        EGMP.applyHealth([1, 2], to: &r)
        XCTAssertNil(r.sohPercent)
    }

    func testCellBlocksHonourThePresenceBits() {
        var d: [UInt8] = [0xC0, 0, 0, 0] // two cells present
        d += [180, 181] + [UInt8](repeating: 0, count: 30)
        XCTAssertEqual(EGMP.cells(d).map { ($0 * 100).rounded() / 100 }, [3.6, 3.62])
    }

    func testTyres() {
        var d = [UInt8](repeating: 0, count: 21)
        d[4] = 182; d[5] = 70 // 36.4 psi, 20 °C
        d[9] = 180
        var r = BatteryReport(takenAt: t0)
        EGMP.applyTyres(d, to: &r)
        XCTAssertEqual(r.tyrePressuresPsi[0] ?? 0, 36.4, accuracy: 0.001)
        XCTAssertEqual(r.tyreTempsC[0], 20)
        XCTAssertEqual(r.tyrePressuresPsi[1], 36)
        XCTAssertNil(r.tyrePressuresPsi[2])
    }

    // MARK: Against the simulated car

    func testAFullScanOfTheSimulatedEV6() async throws {
        let adapter = FakeOBDAdapter()
        let scanner = BatteryScanner(elm: ELM327(transport: adapter), now: { t0 })
        let steps = Locked<[String]>([])
        let (report, problems) = try await scanner.scan { p in steps.withLock { $0.append(p.label) } }
        XCTAssertEqual(problems, [])
        XCTAssertEqual(report.takenAt, t0)
        XCTAssertEqual(report.sohPercent, 98.7)
        XCTAssertEqual(report.socBMSPercent, 72)
        XCTAssertEqual(report.socDisplayPercent, 75)
        XCTAssertEqual(report.packVolts, 712.4)
        XCTAssertEqual(report.cellVolts.count, 192)
        XCTAssertEqual(report.packDescription, "77.4 kWh · 192 cells")
        XCTAssertEqual(report.tyrePressuresPsi.compactMap { $0 }.count, 4)
        XCTAssertEqual(report.moduleTempsC.count, 5)
        XCTAssertEqual(report.operatingHours ?? 0, 481.67, accuracy: 0.01)
        XCTAssertTrue(report.findings.first?.hasPrefix("Battery health 98.7%: excellent") == true, "\(report.findings)")
        XCTAssertEqual(steps.current.count, 10)
        XCTAssertEqual(Array(adapter.commands.prefix(8)), ELM327.setup)
        // The header is set once per module, not before every request.
        XCTAssertEqual(adapter.commands.filter { $0.hasPrefix("ATSH") }, ["ATSH7E4", "ATSH7A0"])
    }

    func testTheSmallerPackAndHeadersOff() async throws {
        var car = FakeOBDAdapter.Car()
        car.cellCount = 144
        car.headersOff = true
        let scanner = BatteryScanner(elm: ELM327(transport: FakeOBDAdapter(car: car)), now: { t0 })
        let (report, problems) = try await scanner.scan()
        XCTAssertEqual(report.cellVolts.count, 144)
        XCTAssertEqual(report.packDescription, "58 kWh · 144 cells")
        XCTAssertEqual(problems, [], "missing blocks past cell 96 are expected on the smaller pack")
    }

    func testASleepingCarStopsTheScanEarly() async {
        var car = FakeOBDAdapter.Car()
        car.asleep = true
        let adapter = FakeOBDAdapter(car: car)
        let scanner = BatteryScanner(elm: ELM327(transport: adapter), now: { t0 })
        do {
            _ = try await scanner.scan()
            XCTFail("expected no data")
        } catch {
            XCTAssertEqual(error as? OBDError, .noData)
        }
        XCTAssertEqual(adapter.commands.filter { $0.hasPrefix("22") }, ["220101"])
    }

    func testNegativeResponse() async throws {
        let elm = ELM327(transport: FakeOBDAdapter())
        try await elm.initialise()
        do {
            _ = try await elm.read(OBDRequest(header: 0x7E4, did: 0x0199))
            XCTFail("expected a rejection")
        } catch {
            XCTAssertEqual(error as? OBDError, .rejected(0x31))
        }
    }

    func testReportsRoundTripThroughJSON() throws {
        var r = BatteryReport(takenAt: t0)
        r.sohPercent = 97
        r.tyrePressuresPsi = [36, nil, 35, 36]
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try d.decode(BatteryReport.self, from: e.encode(r)), r)
    }
}
