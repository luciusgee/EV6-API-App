import Foundation

/// A serial line to an ELM327-compatible OBD adapter (Bluetooth LE or Wi-Fi). Sends one command and
/// returns everything the adapter printed up to its `>` prompt.
public protocol OBDTransport: Sendable {
    func exchange(_ command: String) async throws -> String
}

public enum OBDError: Error, Equatable, Sendable, CustomStringConvertible {
    case notConnected
    case timeout
    /// "NO DATA": the module didn't answer (the car may be asleep: switch it on).
    case noData
    /// "CAN ERROR", "BUS INIT… ERROR", "UNABLE TO CONNECT".
    case busError(String)
    /// The module refused the request (UDS negative response code).
    case rejected(UInt8)
    case unexpected(String)

    public var description: String {
        switch self {
        case .notConnected: return "adapter not connected"
        case .timeout: return "the adapter didn't answer"
        case .noData: return "no answer from the car; switch it on (ready or accessory) and try again"
        case .busError(let text): return "can't talk to the car (\(text.lowercased())); is the adapter fully plugged in?"
        case .rejected(let code): return String(format: "the car refused the request (NRC 0x%02X)", code)
        case .unexpected(let text): return "unexpected answer: \(text)"
        }
    }
}

/// One diagnostic request to an ECU: UDS "read data by identifier" (0x22), an OBD-II mode (0x01, 0x03,
/// 0x09…), trouble codes (0x19, 0x14) or tester present (0x3E).
public struct OBDRequest: Hashable, Sendable {
    /// 11-bit request CAN id, e.g. 0x7E4 for the battery management system; 0x7DF asks every ECU.
    public var header: UInt16
    public var service: UInt8
    public var parameter: [UInt8]
    /// How many parameter bytes the ECU repeats after its positive-response byte.
    public var echo: Int

    public init(header: UInt16, service: UInt8, parameter: [UInt8] = [], echo: Int? = nil) {
        self.header = header
        self.service = service
        self.parameter = parameter
        self.echo = echo ?? parameter.count
    }

    /// UDS read data by identifier.
    public init(header: UInt16, did: UInt16) {
        self.init(header: header, service: 0x22, parameter: [UInt8(did >> 8), UInt8(did & 0xFF)])
    }

    public static let broadcast: UInt16 = 0x7DF

    /// The data identifier of a 0x22 request.
    public var did: UInt16 { parameter.count == 2 ? UInt16(parameter[0]) << 8 | UInt16(parameter[1]) : 0 }

    /// The ECU answers on the request id + 8; nil for a broadcast (the first ECU to answer wins).
    public var responseHeader: UInt16? { header == Self.broadcast ? nil : header + 8 }
    public var command: String { ([service] + parameter).map { String(format: "%02X", $0) }.joined() }
}

/// Talks ELM327: sets the adapter up for 500 kbit/s 11-bit CAN (the E-GMP diagnostic bus), then sends
/// requests one at a time, whichever screen asks.
public actor ELM327 {
    private let transport: OBDTransport
    private var currentHeader: UInt16?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public private(set) var adapterVersion: String?
    public private(set) var initialised = false

    public init(transport: OBDTransport) {
        self.transport = transport
    }

    public static let setup = ["ATZ", "ATE0", "ATL0", "ATS1", "ATH1", "ATSP6", "ATAT1", "ATCAF1"]

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    public func initialise() async throws {
        await acquire()
        defer { release() }
        currentHeader = nil
        initialised = false
        for command in Self.setup {
            let reply = try await transport.exchange(command)
            if command == "ATZ" {
                adapterVersion = Self.lines(reply).first { $0.uppercased().contains("ELM") || $0.uppercased().contains("V") }
            } else if Self.lines(reply).contains("?") {
                throw OBDError.unexpected("\(command) → ?")
            }
        }
        initialised = true
    }

    /// Sets the adapter up once; later calls do nothing.
    public func initialiseIfNeeded() async throws {
        if !initialised { try await initialise() }
    }

    /// The whole answer, starting with the response byte (0x62, 0x7F…).
    public func send(_ request: OBDRequest) async throws -> [UInt8] {
        await acquire()
        defer { release() }
        if currentHeader != request.header {
            let reply = try await transport.exchange(String(format: "ATSH%03X", request.header))
            guard Self.lines(reply).contains(where: { $0.uppercased() == "OK" }) else {
                throw OBDError.unexpected("ATSH → \(reply.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            currentHeader = request.header
        }
        let reply = try await transport.exchange(request.command)
        return try ISOTP.message(from: reply, responseHeader: request.responseHeader)
    }

    /// The data after the positive-response byte and the echoed parameter.
    public func read(_ request: OBDRequest) async throws -> [UInt8] {
        let message = try await send(request)
        guard let first = message.first else { throw OBDError.noData }
        if first == 0x7F {
            throw OBDError.rejected(message.count > 2 ? message[2] : 0)
        }
        guard first == request.service &+ 0x40, message.count >= 1 + request.echo,
              Array(message[1..<(1 + request.echo)]) == Array(request.parameter.prefix(request.echo))
        else { throw OBDError.unexpected(ISOTP.hex(Array(message.prefix(8)))) }
        return Array(message.dropFirst(1 + request.echo))
    }

    /// Whether an ECU answers at all (UDS tester present).
    public func ping(_ header: UInt16) async -> Bool {
        (try? await read(OBDRequest(header: header, service: 0x3E, parameter: [0x00]))) != nil
    }

    static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "\r" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " >")) }
            .filter { !$0.isEmpty }
    }
}

/// Reassembles an ISO 15765-2 (ISO-TP) message from what the ELM327 prints, with headers on
/// ("7EC 10 3E 62 01 01 …") or off ("03E" then "0: 62 01 01 …"), with or without spaces.
public enum ISOTP {
    public static func message(from reply: String, responseHeader: UInt16?) throws -> [UInt8] {
        let lines = ELM327.lines(reply).filter { !$0.uppercased().hasPrefix("SEARCHING") && !$0.uppercased().hasPrefix("BUS INIT") }
        guard !lines.isEmpty else { throw OBDError.timeout }
        for line in lines {
            let upper = line.uppercased()
            if upper.contains("NO DATA") { throw OBDError.noData }
            if upper.contains("ERROR") || upper.contains("UNABLE") || upper == "STOPPED" { throw OBDError.busError(line) }
            if upper == "?" { throw OBDError.unexpected("?") }
        }

        if lines.contains(where: { $0.contains(":") }) {
            return try indexed(lines)
        }
        return try framed(lines, responseHeader: responseHeader)
    }

    /// "Request received, response pending": the real answer follows.
    static func isPending(_ message: [UInt8]) -> Bool {
        message.count >= 3 && message[0] == 0x7F && message[2] == 0x78
    }

    /// Headers off: an optional length line, then "0: …", "1: …".
    private static func indexed(_ lines: [String]) throws -> [UInt8] {
        var length: Int?
        var parts: [(Int, [UInt8])] = []
        for line in lines {
            if let colon = line.firstIndex(of: ":") {
                guard let index = Int(line[..<colon].trimmingCharacters(in: .whitespaces), radix: 16) else { continue }
                parts.append((index, try bytes(String(line[line.index(after: colon)...]))))
            } else if length == nil, let n = Int(line.replacingOccurrences(of: " ", with: ""), radix: 16) {
                length = n
            }
        }
        let data = parts.sorted { $0.0 < $1.0 }.flatMap(\.1)
        guard let length else { return data }
        guard data.count >= length else { throw OBDError.unexpected("short message: \(data.count) of \(length) bytes") }
        return Array(data.prefix(length))
    }

    /// Headers on: each line is one CAN frame, "7EC" then the PCI byte and data. Returns the first
    /// complete message from the wanted ECU (or the first ECU to answer), skipping "response pending".
    private static func framed(_ lines: [String], responseHeader: UInt16?) throws -> [UInt8] {
        var wanted = responseHeader.map { String(format: "%03X", $0) }
        var frames: [[UInt8]] = []
        var sawHeaders = false
        for line in lines {
            let compact = line.replacingOccurrences(of: " ", with: "").uppercased()
            if compact.count > 3, compact.count % 2 == 1 {
                // An odd number of hex digits: an 11-bit id, then bytes.
                sawHeaders = true
                let id = String(compact.prefix(3))
                if wanted == nil { wanted = id }
                guard id == wanted else { continue } // another ECU
                frames.append(try bytes(String(compact.dropFirst(3))))
            } else {
                frames.append(try bytes(compact))
            }
        }
        guard let first = frames.first, let pci = first.first else { throw OBDError.noData }
        if !sawHeaders && frames.count == 1 && pci >> 4 != 0 && pci >> 4 != 1 {
            // Plain response without PCI (CAF on, headers off, single frame).
            return first
        }

        var messages: [[UInt8]] = []
        var building: [UInt8]?
        var length = 0
        var expected: UInt8 = 1
        for frame in frames {
            guard let p = frame.first else { continue }
            switch p >> 4 {
            case 0:
                let n = Int(p & 0x0F)
                guard frame.count > n, n > 0 else { throw OBDError.unexpected("short single frame") }
                messages.append(Array(frame[1...n]))
            case 1:
                guard frame.count >= 2 else { throw OBDError.unexpected("short first frame") }
                length = Int(p & 0x0F) << 8 | Int(frame[1])
                building = Array(frame.dropFirst(2))
                expected = 1
            case 2:
                guard var data = building else { continue }
                if p & 0x0F != expected { throw OBDError.unexpected("frame \(p & 0x0F) out of order") }
                expected = (expected + 1) & 0x0F
                data += frame.dropFirst()
                if data.count >= length {
                    messages.append(Array(data.prefix(length)))
                    building = nil
                } else {
                    building = data
                }
            default:
                throw OBDError.unexpected(hex(Array(frame.prefix(8))))
            }
        }
        if let data = building {
            throw OBDError.unexpected("short message: \(data.count) of \(length) bytes")
        }
        guard let message = messages.first(where: { !isPending($0) }) else {
            throw messages.isEmpty ? OBDError.noData : OBDError.timeout
        }
        return message
    }

    static func bytes(_ text: String) throws -> [UInt8] {
        let hexDigits = text.replacingOccurrences(of: " ", with: "")
        guard hexDigits.count % 2 == 0 else { throw OBDError.unexpected(text) }
        var out: [UInt8] = []
        out.reserveCapacity(hexDigits.count / 2)
        var index = hexDigits.startIndex
        while index < hexDigits.endIndex {
            let next = hexDigits.index(index, offsetBy: 2)
            guard let byte = UInt8(hexDigits[index..<next], radix: 16) else { throw OBDError.unexpected(text) }
            out.append(byte)
            index = next
        }
        return out
    }

    public static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// The frames an ECU sends for `message`, as the ELM327 prints them with headers on.
    public static func frames(_ message: [UInt8], header: UInt16) -> [String] {
        let id = String(format: "%03X", header)
        func line(_ bytes: [UInt8]) -> String {
            var padded = bytes
            while padded.count < 8 { padded.append(0xAA) }
            return id + " " + hex(padded)
        }
        if message.count <= 7 {
            return [line([UInt8(message.count)] + message)]
        }
        var out = [line([0x10 | UInt8(message.count >> 8), UInt8(message.count & 0xFF)] + message.prefix(6))]
        var rest = Array(message.dropFirst(6))
        var sequence: UInt8 = 1
        while !rest.isEmpty {
            out.append(line([0x20 | sequence] + rest.prefix(7)))
            rest = Array(rest.dropFirst(7))
            sequence = (sequence + 1) & 0x0F
        }
        return out
    }
}
