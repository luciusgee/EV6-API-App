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

        public init() {}
    }

    private let state: Locked<(car: Car, header: UInt16, headers: Bool)>
    /// Every command received, for tests.
    public var commands: [String] { log.current }
    private let log = Locked<[String]>([])

    public init(car: Car = Car()) {
        state = Locked((car, 0x7DF, true))
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
        guard cmd.hasPrefix("22"), let did = UInt16(cmd.dropFirst(2), radix: 16) else { return "?\r\r>" }
        guard let payload = payload(header: s.header, did: did, car: s.car) else {
            return frames([0x7F, 0x22, 0x31], header: s.header + 8, headersOn: s.headers && !s.car.headersOff)
        }
        let message = [0x62, UInt8(did >> 8), UInt8(did & 0xFF)] + payload
        return frames(message, header: s.header + 8, headersOn: s.headers && !s.car.headersOff)
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
