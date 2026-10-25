import Foundation
import XCTest
@testable import PreconditionKit

/// Answers each command from a script (AT commands default to OK) and logs what was sent.
final class ScriptedTransport: OBDTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [String: String]
    private(set) var sent: [String] = []

    init(_ script: [String: String]) { self.script = script }

    func set(_ command: String, _ reply: String) {
        lock.lock()
        script[command] = reply
        lock.unlock()
    }

    func exchange(_ command: String) async throws -> String {
        answer(command)
    }

    private func answer(_ command: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        sent.append(command)
        if let reply = script[command] { return reply + "\r\r>" }
        if command == "ATZ" { return "ELM327 v1.5\r\r>" }
        if command.hasPrefix("AT") { return "OK\r\r>" }
        return "NO DATA\r\r>"
    }
}

final class ProtocolTests: XCTestCase {
    func testMessagesByECUWithInterleavedMultiFrameReplies() throws {
        let reply = """
        7E8 10 14 49 02 01 4B 4E 44
        7EA 10 14 49 02 01 57 56 57
        7E8 21 43 33 44 4C 43 35 4E
        7EA 21 5A 5A 5A 31 4B 5A 38
        7E8 22 35 30 31 32 33 34 35
        7EA 22 57 30 30 30 30 30 31
        """
        let byECU = try ISOTP.messagesByECU(from: reply, responseHeader: nil)
        XCTAssertEqual(Set(byECU.keys), [0x7E0, 0x7E2])
        XCTAssertEqual(byECU[0x7E0].map { String(decoding: $0.dropFirst(3), as: UTF8.self) }, "KNDC3DLC5N5012345")
        XCTAssertEqual(byECU[0x7E2].map { String(decoding: $0.dropFirst(3), as: UTF8.self) }, "WVWZZZ1KZ8W000001")
    }

    func testOneECUPendingDoesntLoseTheOther() throws {
        let reply = """
        7E8 03 7F 03 78
        7EA 04 43 01 01 33
        """
        let byECU = try ISOTP.messagesByECU(from: reply, responseHeader: nil)
        XCTAssertEqual(Array(byECU.keys), [0x7E2])
        XCTAssertEqual(byECU[0x7E2], [0x43, 0x01, 0x01, 0x33])
    }

    func testTwentyNineBitIDs() throws {
        let byECU = try ISOTP.messagesByECU(from: "18DAF110 06 41 00 BE 3F A8 13", responseHeader: nil)
        XCTAssertEqual(byECU[0x7E0], [0x41, 0x00, 0xBE, 0x3F, 0xA8, 0x13])
        XCTAssertEqual(ISOTP.ecuHeader(address: 0x1A), 0x61A)
        XCTAssertEqual(ISOTP.address(ecuHeader: 0x7E3), 0x13)
    }

    func testSearchProtocolOnKLine() async throws {
        let transport = ScriptedTransport([
            "0100": "SEARCHING...\r48 6B 10 41 00 BE 3F A8 13 B9",
            "ATDPN": "A3",
        ])
        let elm = ELM327(transport: transport)
        try await elm.initialise()
        let number = try await elm.searchProtocol()
        XCTAssertEqual(number, "3")
        let isCAN = await elm.isCAN
        XCTAssertFalse(isCAN)
        XCTAssertTrue(transport.sent.contains("ATH0"))
        XCTAssertTrue(transport.sent.contains("ATSP0"))

        // Headers off on K-line: mode 09 answers one numbered line at a time, joined in order.
        transport.set("0902", "49 02 02 44 4C 43 35\r49 02 01 00 00 00 4B 4E 44 43 33\r49 02 03 4E 35 30 31")
        let vin = try await elm.read(OBDRequest(header: OBDRequest.broadcast, service: 0x09, parameter: [0x02]))
        XCTAssertEqual(vin, [0x01, 0, 0, 0, 0x4B, 0x4E, 0x44, 0x43, 0x33, 0x44, 0x4C, 0x43, 0x35, 0x4E, 0x35, 0x30, 0x31])
    }

    func testSearchFindsNothing() async throws {
        let elm = ELM327(transport: ScriptedTransport(["0100": "SEARCHING...\rUNABLE TO CONNECT"]))
        try await elm.initialise()
        do {
            _ = try await elm.searchProtocol()
            XCTFail("expected unsupportedProtocol")
        } catch let error as OBDError {
            XCTAssertEqual(error, .unsupportedProtocol)
            // A sleeping car lands here too (auto-detect searches when nothing answers): lead with switching it on.
            XCTAssertTrue(error.description.hasPrefix("no answer from the car; switch it on"))
        }
    }

    func testAFailedSearchSetsTheAdapterUpAgain() async throws {
        let transport = ScriptedTransport(["0100": "SEARCHING...\rUNABLE TO CONNECT"])
        let elm = ELM327(transport: transport)
        try await elm.initialise()
        _ = try? await elm.searchProtocol()
        let initialised = await elm.initialised
        XCTAssertFalse(initialised)
        let number = await elm.protocolNumber
        XCTAssertEqual(number, "6")

        let before = transport.sent.count
        try await elm.initialiseIfNeeded()
        let again = Array(transport.sent[before...])
        XCTAssertTrue(again.contains("ATZ"))
        XCTAssertTrue(again.contains("ATSP6"))
        let back = await elm.initialised
        XCTAssertTrue(back)
    }

    func testReadAllKeepsEveryECU() async throws {
        let transport = ScriptedTransport([
            "0100": "7E8 06 41 00 BE 3F A8 12\r7E9 06 41 00 80 00 00 01",
            "0120": "7E9 06 41 20 00 00 00 01",
            "0140": "7E9 06 41 40 40 00 00 00",
        ])
        let elm = ELM327(transport: transport)
        try await elm.initialise()
        let all = try await elm.readAll(OBDRequest(header: OBDRequest.broadcast, service: 0x01, parameter: [0x00]))
        XCTAssertEqual(all[0x7E0], [0xBE, 0x3F, 0xA8, 0x12])
        XCTAssertEqual(all[0x7E1], [0x80, 0x00, 0x00, 0x01])

        // 7E0 stops after the first block (its bit 0x20 is clear); 7E1 goes on to 0x40.
        let pids = await Diagnostics(elm: elm).supportedPIDs()
        XCTAssertTrue(pids.contains(0x0D))
        XCTAssertTrue(pids.contains(0x01))
        XCTAssertTrue(pids.contains(0x42))
        XCTAssertTrue(pids.contains(0x40))
        XCTAssertFalse(pids.contains(0x21))
    }

    func testEmissionCodesFromEveryECU() async throws {
        let transport = ScriptedTransport([
            "03": "7E8 04 43 01 01 33\r7EA 06 43 02 01 71 41 23",
            "07": "7E8 04 43 01 01 33".replacingOccurrences(of: "43", with: "47"),
        ])
        let elm = ELM327(transport: transport)
        try await elm.initialise()
        let codes = try await Diagnostics(elm: elm).emissionCodes()
        XCTAssertEqual(codes.map(\.code), ["P0133", "P0171", "C0123"])
        XCTAssertEqual(codes.map(\.ecuHeader), [0x7E0, 0x7E2, 0x7E2])
        // Stored and pending from the same ECU: one code with both bits.
        XCTAssertEqual(codes[0].status, 0x08 | 0x04)
    }

    func testNoDataMeansNoCodesButSilenceThrows() async throws {
        let quiet = ELM327(transport: ScriptedTransport([:]))
        try await quiet.initialise()
        let none = try await Diagnostics(elm: quiet).emissionCodes()
        XCTAssertTrue(none.isEmpty)

        let broken = ELM327(transport: ScriptedTransport(["03": "CAN ERROR", "07": "CAN ERROR"]))
        try await broken.initialise()
        do {
            _ = try await Diagnostics(elm: broken).emissionCodes()
            XCTFail("expected an error")
        } catch let error as OBDError {
            XCTAssertEqual(error, .busError("CAN ERROR"))
        }
    }

    func testPollerTimesEachReply() async throws {
        let clock = MutableTime()
        let transport = ScriptedTransport(["010D": "7E8 03 41 0D 32", "010C": "7E8 04 41 0C 1A F8"])
        let elm = ELM327(transport: transport)
        try await elm.initialise()
        let sensors = ["rpm", "speed"].compactMap { GenericSensors.sensor($0) }
        let poller = LivePoller(elm: elm, sensors: sensors) {
            clock.advance(0.1)
            return clock.now()
        }
        let sample = try await poller.poll()
        XCTAssertEqual(sample.values["speed"], 50)
        XCTAssertLessThan(sample.time(of: "rpm"), sample.time(of: "speed"))
        XCTAssertLessThan(sample.time(of: "speed"), sample.at)
    }
}
