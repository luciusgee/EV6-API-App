import Foundation

/// An ELM327 plugged into a 2022 EV6 77.4 kWh, for fake-car mode and tests. Answers the setup
/// commands and the battery and tyre identifiers with realistic, slightly varying values.
public final class FakeOBDAdapter: OBDTransport, @unchecked Sendable {
    public struct Car: Sendable {
        public var socPercent: Double = 72
        public var sohPercent: Double = 98.7
        public var packVolts: Double = 712.4
        public var packAmps: Double = -0.3
        public var cellCount = 192
        /// The weakest cell sits this far below the rest, in volts.
        public var weakCellDrop: Double = 0.02
        public var batteryTempC = 17
        public var tyrePsi: [Double] = [36.4, 36.2, 35.8, 36.0]
        /// "NO DATA" for everything: the car is off.
        public var asleep = false
        /// Answer with headers off ("0: …" lines) like some clones do.
        public var headersOff = false
        public var drive: Drive = .parked
        public var odometerKm = 18_234
        public var cabinC = 19.5
        public var outsideC = 8.0
        /// Stored trouble codes by module; cleared by UDS 0x14.
        public var codes: [UInt16: [TroubleCode]] = [
            0x770: [TroubleCode(code: "U3003", failureType: 0x16, status: 0x08, ecuHeader: 0x770, raw: [0xF0, 0x03, 0x16])],
            0x7D1: [TroubleCode(code: "C1611", failureType: 0x00, status: 0x09, ecuHeader: 0x7D1, raw: [0x56, 0x11, 0x00])],
        ]
        /// Modules that answer.
        public var modules: Set<UInt16> = [0x7E4, 0x7E2, 0x7E3, 0x7E5, 0x7A0, 0x770, 0x7B3, 0x7C6, 0x7D1, 0x7D2, 0x7D4, 0x7D0, 0x7C4, 0x780]

        public init() {}
    }

    public enum Drive: Sendable, Equatable {
        case parked
        /// Gentle town driving around 50 km/h.
        case cruising(since: Date)
        /// Flat out from a standstill: 0–60 mph in about 5 s, like a 325 bhp AWD EV6.
        case launch(since: Date)
    }

    private let state: Locked<(car: Car, header: UInt16, headers: Bool)>
    /// Every command received, for tests.
    public var commands: [String] { log.current }
    private let log = Locked<[String]>([])
    private let now: @Sendable () -> Date

    public init(car: Car = Car(), now: @escaping @Sendable () -> Date = { Date() }) {
        state = Locked((car, 0x7DF, true))
        self.now = now
    }

    /// Speed (km/h) and battery power (kW) for the drive simulation.
    public func motion() -> (kmh: Double, kW: Double, pedal: Double) {
        switch car.drive {
        case .parked:
            return (0, 0.4, 0)
        case .cruising(let since):
            let t = now().timeIntervalSince(since)
            let v = 48 + 10 * sin(t / 9)
            return (v, 9 + 12 * cos(t / 9), 22)
        case .launch(let since):
            let t = max(0, now().timeIntervalSince(since))
            let v = 230 * (1 - exp(-t / 9.2))
            return (v, t < 12 ? 239 * min(1, 0.4 + t) : 60, 100)
        }
    }

    public var car: Car {
        get { state.current.car }
        set { state.withLock { $0.car = newValue } }
    }

    public func exchange(_ command: String) async throws -> String {
        log.withLock { $0.append(command) }
        let cmd = command.uppercased().replacingOccurrences(of: " ", with: "")
        if cmd == "ATZ" { return "\r\rELM327 v1.5\r\r>" }
        if cmd == "ATH1" { state.withLock { $0.headers = true }; return "OK\r\r>" }
        if cmd == "ATH0" { state.withLock { $0.headers = false }; return "OK\r\r>" }
        if cmd.hasPrefix("ATSH"), let id = UInt16(cmd.dropFirst(4), radix: 16) {
            state.withLock { $0.header = id }
            return "OK\r\r>"
        }
        if cmd.hasPrefix("AT") { return "OK\r\r>" }

        let s = state.current
        if s.car.asleep { return "NO DATA\r\r>" }
        guard let bytes = try? ISOTP.bytes(cmd), let service = bytes.first else { return "?\r\r>" }
        let headersOn = s.headers && !s.car.headersOff
        if s.header == OBDRequest.broadcast {
            guard let answer = standard(bytes, car: s.car) else { return "NO DATA\r\r>" }
            return frames(answer, header: 0x7E8, headersOn: headersOn)
        }
        guard s.car.modules.contains(s.header) else { return "NO DATA\r\r>" }
        let reply = s.header + 8
        switch service {
        case 0x3E:
            return frames([0x7E, 0x00], header: reply, headersOn: headersOn)
        case 0x19:
            let codes = s.car.codes[s.header] ?? []
            if bytes.count >= 2, bytes[1] == 0x04 {
                return frames([0x59, 0x04] + Array(bytes.dropFirst(2).prefix(3)) + [0x08, 0x01, 0x03, 0x10, 0x02, 0x7A, 0x33, 0x44, 0x1C], header: reply, headersOn: headersOn)
            }
            return frames([0x59, 0x02, 0xFF] + codes.flatMap { $0.raw + [$0.status] }, header: reply, headersOn: headersOn)
        case 0x14:
            state.withLock { $0.car.codes[$0.header] = nil }
            // Clearing takes a moment: "response pending" first, like a real module.
            return (ISOTP.frames([0x7F, 0x14, 0x78], header: reply) + ISOTP.frames([0x54], header: reply)).joined(separator: "\r") + "\r\r>"
        case 0x22 where bytes.count == 3:
            let did = UInt16(bytes[1]) << 8 | UInt16(bytes[2])
            guard let payload = payload(header: s.header, did: did, car: s.car) else {
                return frames([0x7F, 0x22, 0x31], header: reply, headersOn: headersOn)
            }
            return frames([0x62, bytes[1], bytes[2]] + payload, header: reply, headersOn: headersOn)
        default:
            return frames([0x7F, service, 0x11], header: reply, headersOn: headersOn)
        }
    }

    /// OBD-II modes 01, 03, 04, 07 and 09, answered by the VCU (7E8).
    private func standard(_ bytes: [UInt8], car: Car) -> [UInt8]? {
        let m = motion()
        switch (bytes[0], bytes.count > 1 ? bytes[1] : nil) {
        // Supported: 0x0D, 0x1F (next block 0x20), 0x21, 0x31 (next 0x40), 0x42, 0x46, 0x5B.
        case (0x01, 0x00?): return [0x41, 0x00, 0x00, 0x08, 0x00, 0x03]
        case (0x01, 0x20?): return [0x41, 0x20, 0x80, 0x00, 0x80, 0x01]
        case (0x01, 0x40?): return [0x41, 0x40, 0x44, 0x00, 0x00, 0x20]
        case (0x01, 0x0D?): return [0x41, 0x0D, UInt8(min(m.kmh, 255))]
        case (0x01, 0x1F?): return [0x41, 0x1F, 0x02, 0x58]
        case (0x01, 0x21?): return [0x41, 0x21, 0x00, 0x00]
        case (0x01, 0x31?): return [0x41, 0x31, 0x04, 0xD2]
        case (0x01, 0x42?): return [0x41, 0x42, 0x38, 0xA4] // 14.5 V
        case (0x01, 0x46?): return [0x41, 0x46, UInt8(car.outsideC + 40)]
        case (0x01, 0x5B?): return [0x41, 0x5B, UInt8(car.socPercent * 255 / 100)]
        case (0x03, _): return [0x43, 0x00]
        case (0x07, _): return [0x47, 0x00]
        case (0x04, _): return [0x44]
        case (0x09, 0x02?): return [0x49, 0x02, 0x01] + Array("KNAC381AFN5012345".utf8)
        default: return nil
        }
    }

    private func frames(_ message: [UInt8], header: UInt16, headersOn: Bool) -> String {
        if headersOn { return ISOTP.frames(message, header: header).joined(separator: "\r") + "\r\r>" }
        // Headers off: length, then indexed lines of 7 bytes (the first holds 6).
        var lines = [String(format: "%03X", message.count)]
        var rest = message
        var index = 0
        var firstChunk = true
        while !rest.isEmpty {
            let n = firstChunk ? 6 : 7
            lines.append("\(String(index, radix: 16).uppercased()): " + ISOTP.hex(Array(rest.prefix(n))))
            rest = Array(rest.dropFirst(n))
            index = (index + 1) & 0x0F
            firstChunk = false
        }
        return lines.joined(separator: "\r") + "\r\r>"
    }

    private func put16(_ d: inout [UInt8], _ i: Int, _ v: Int) {
        d[i] = UInt8((v >> 8) & 0xFF)
        d[i + 1] = UInt8(v & 0xFF)
    }

    private func put32(_ d: inout [UInt8], _ i: Int, _ v: Int) {
        for k in 0..<4 { d[i + k] = UInt8((v >> (24 - 8 * k)) & 0xFF) }
    }

    private func cellVolts(_ car: Car) -> [Double] {
        // Open-circuit voltage rises with charge: about 3.55 V empty-ish to 4.1 V full.
        let base = 3.55 + 0.55 * car.socPercent / 100
        return (0..<car.cellCount).map { i in
            let wobble = Double((i * 37) % 5) * 0.004
            return base + wobble - (i == 86 ? car.weakCellDrop : 0)
        }
    }

    private func payload(header: UInt16, did: UInt16, car: Car) -> [UInt8]? {
        switch (header, did) {
        case (_, 0xF190):
            return Array("KNAC381AFN5012345".utf8)
        case (_, 0xF187):
            return Array(String(format: "%05X-CV%03d", header, header % 1000).utf8)
        case (_, 0xF189):
            return Array("CV1 EU 1.0\(header % 7)".utf8)
        case (_, 0xF18C):
            return Array(String(format: "S%08X", Int(header) * 7919).utf8)
        case (EGMP.bms, 0x0101):
            var d = [UInt8](repeating: 0, count: 59)
            d[4] = UInt8(min(max(car.socPercent * 2, 0), 200))
            put16(&d, 5, 25_000) // 250 kW available
            put16(&d, 10, Int((car.packAmps * 10).rounded()) & 0xFFFF)
            put16(&d, 12, Int((car.packVolts * 10).rounded()))
            d[14] = UInt8(bitPattern: Int8(car.batteryTempC + 1))
            d[15] = UInt8(bitPattern: Int8(car.batteryTempC - 1))
            for i in 0..<5 { d[16 + i] = UInt8(bitPattern: Int8(car.batteryTempC + (i % 3) - 1)) }
            d[22] = UInt8(bitPattern: Int8(car.batteryTempC))
            let cells = cellVolts(car)
            let maxIndex = cells.indices.max { cells[$0] < cells[$1] } ?? 0
            let minIndex = cells.indices.min { cells[$0] < cells[$1] } ?? 0
            d[23] = UInt8((cells[maxIndex] * 50).rounded())
            d[24] = UInt8(maxIndex + 1)
            d[25] = UInt8((cells[minIndex] * 50).rounded())
            d[26] = UInt8(minIndex + 1)
            put32(&d, 30, 52_340) // Ah × 10
            put32(&d, 34, 49_870)
            put32(&d, 38, 36_512) // kWh × 10
            put32(&d, 42, 33_208)
            put32(&d, 46, 1_734_000) // seconds
            let m = motion()
            if m.kW > 1 {
                let amps = m.kW * 1000 / car.packVolts
                put16(&d, 10, Int((amps * 10).rounded()) & 0xFFFF)
            }
            // 10.65:1 reduction, about 2.3 m per wheel turn.
            let rpm = Int(m.kmh * 77)
            put16(&d, 53, rpm & 0xFFFF)
            put16(&d, 55, rpm & 0xFFFF)
            return d
        case (EGMP.bms, 0x0105):
            var d = [UInt8](repeating: 0, count: 45)
            put16(&d, 25, Int((car.sohPercent * 10).rounded()))
            d[31] = UInt8(min(max((car.socPercent + 3) * 2, 0), 200))
            return d
        case (EGMP.bms, _):
            guard let block = EGMP.cellBlocks.first(where: { $0.0.did == did }) else { return nil }
            let cells = cellVolts(car)
            let slice = cells.dropFirst(block.1).prefix(32)
            if slice.isEmpty { return nil }
            var d = [UInt8](repeating: 0, count: 4 + 32)
            let present: UInt32 = slice.count == 32 ? 0xFFFF_FFFF : ~(0xFFFF_FFFF >> UInt32(slice.count))
            put32(&d, 0, Int(present))
            for (i, v) in slice.enumerated() { d[4 + i] = UInt8((v / 0.02).rounded()) }
            return d
        case (EV6Sensors.hvac, 0x0100):
            var d = [UInt8](repeating: 0, count: 32)
            d[5] = UInt8(((car.cabinC + 40) * 2).rounded())
            d[6] = UInt8(((car.outsideC + 40) * 2).rounded())
            d[29] = UInt8(min(motion().kmh, 255))
            return d
        case (EV6Sensors.vcu, 0xE004):
            var d = [UInt8](repeating: 0, count: 20)
            let m = motion()
            d[9] = UInt8(m.pedal * 2)
            d[14] = car.drive == .parked ? 0 : 5
            return d
        case (EV6Sensors.cluster, 0xB002):
            var d = [UInt8](repeating: 0, count: 14)
            d[6] = UInt8((car.odometerKm >> 16) & 0xFF)
            d[7] = UInt8((car.odometerKm >> 8) & 0xFF)
            d[8] = UInt8(car.odometerKm & 0xFF)
            return d
        case (EV6Sensors.igpm, 0xBC03):
            var d = [UInt8](repeating: 0, count: 8)
            d[5] = car.drive == .parked ? 0x02 : 0x62
            return d
        case (EV6Sensors.igpm, 0xBC04):
            return [UInt8](repeating: 0, count: 8)
        case (EGMP.bcm, 0xC00B):
            var d = [UInt8](repeating: 0, count: 24)
            for (i, psi) in car.tyrePsi.prefix(4).enumerated() {
                d[4 + i * 5] = UInt8((psi * 5).rounded())
                d[5 + i * 5] = UInt8(car.batteryTempC + 50 - 2)
            }
            return d
        default:
            return nil
        }
    }
}
