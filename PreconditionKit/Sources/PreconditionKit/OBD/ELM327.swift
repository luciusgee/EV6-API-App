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
    /// The adapter searched every OBD-II protocol and nothing answered (`ELM327.searchProtocol`).
    case unsupportedProtocol
    /// The module refused the request (UDS negative response code).
    case rejected(UInt8)
    case unexpected(String)

    public var description: String {
        switch self {
        case .notConnected: return "adapter not connected"
        case .timeout: return "the adapter didn't answer"
        case .noData: return "no answer from the car; switch it on (ready or accessory) and try again"
        case .busError(let text): return "can't talk to the car (\(text.lowercased())); is the adapter fully plugged in and the car switched on?"
        case .unsupportedProtocol: return "no answer from the car; switch it on (ready or accessory) and try again. If it is already on, this adapter can't talk to this car's OBD protocol"
        case .rejected(let code): return String(format: "the car refused the request (NRC 0x%02X)", code)
        case .unexpected(let text): return "unexpected answer: \(text)"
        }
    }
}

/// One diagnostic request to an ECU: UDS "read data by identifier" (0x22), an OBD-II mode (0x01, 0x03,
/// 0x09…), trouble codes (0x19, 0x14) or tester present (0x3E).
public struct OBDRequest: Hashable, Sendable {
    /// 11-bit request CAN id, e.g. 0x7E4 for the battery management system; 0x7DF asks every ECU. On a
    /// 29-bit CAN car 0x7E0…0x7E7 stand for ECU addresses 0x10…0x17 (`ISOTP.address(ecuHeader:)`).
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
/// requests one at a time, whichever screen asks. `searchProtocol` moves a car on another bus to
/// whichever OBD-II protocol it answers on.
public actor ELM327 {
    private let transport: OBDTransport
    private var currentHeader: UInt16?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public private(set) var adapterVersion: String?
    public private(set) var initialised = false
    /// ELM327 protocol number (ATDPN): "6" is 11-bit 500k CAN, "7"/"9" 29-bit CAN, "8" 11-bit 250k
    /// CAN, "1"…"5" J1850, ISO 9141 and KWP2000.
    public private(set) var protocolNumber = "6"

    public var isCAN: Bool { !["1", "2", "3", "4", "5"].contains(protocolNumber) }
    /// 29-bit CAN ids: 18DB33F1 asks every ECU, ECUs answer on 18DAF1xx.
    public var uses29BitIDs: Bool { ["7", "9", "A"].contains(protocolNumber) }

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
        protocolNumber = "6"
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

    /// Lets the adapter search every OBD-II protocol (ATSP0) and returns the one the car answered on
    /// (ATDPN). For standard OBD-II when 0100 gets no answer on the default 11-bit 500k CAN setup; the
    /// search can take several seconds. Throws `.unsupportedProtocol` when nothing answers.
    public func searchProtocol() async throws -> String {
        await acquire()
        defer { release() }
        currentHeader = nil
        do {
            return try await runProtocolSearch()
        } catch {
            // The adapter is left on ATSP0 (or half set up): the next `initialiseIfNeeded` runs the
            // whole setup again, back on 11-bit 500k CAN, rather than every request searching.
            initialised = false
            protocolNumber = "6"
            currentHeader = nil
            throw error
        }
    }

    private func runProtocolSearch() async throws -> String {
        // Defaults first (ATD), so the search goes out on the standard OBD-II request headers.
        for command in ["ATD", "ATE0", "ATL0", "ATS1", "ATH1", "ATAT1", "ATCAF1", "ATSP0"] {
            let reply = try await transport.exchange(command)
            if command == "ATSP0", Self.lines(reply).contains("?") { throw OBDError.unexpected("ATSP0 → ?") }
        }
        do {
            _ = try ISOTP.checkedLines(try await transport.exchange("0100"))
        } catch let error as OBDError where error != .notConnected {
            throw OBDError.unsupportedProtocol
        }
        let reply = try await transport.exchange("ATDPN")
        if let line = Self.lines(reply).first(where: { $0.count <= 2 && $0.uppercased() != "OK" }) {
            let number = line.uppercased().hasPrefix("A") && line.count == 2 ? String(line.uppercased().dropFirst()) : line.uppercased()
            if "123456789ABC".contains(number), number.count == 1 { protocolNumber = number }
        }
        if !isCAN {
            // J1850 and K-line frames have no ISO-TP layer: read them as plain data lines.
            _ = try await transport.exchange("ATH0")
        } else if uses29BitIDs {
            _ = try await transport.exchange("ATCP18")
        }
        return protocolNumber
    }

    private func setHeader(_ header: UInt16) async throws {
        guard currentHeader != header else { return }
        let command: String
        if !isCAN {
            // J1850 and K-line only carry standard OBD-II here, on the adapter's default headers.
            guard header == OBDRequest.broadcast else { throw OBDError.noData }
            currentHeader = header
            return
        } else if uses29BitIDs {
            command = header == OBDRequest.broadcast
                ? "ATSHDB33F1" : String(format: "ATSHDA%02XF1", ISOTP.address(ecuHeader: header))
        } else {
            command = String(format: "ATSH%03X", header)
        }
        let reply = try await transport.exchange(command)
        guard Self.lines(reply).contains(where: { $0.uppercased() == "OK" }) else {
            throw OBDError.unexpected("ATSH → \(reply.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        currentHeader = header
    }

    /// The whole answer, starting with the response byte (0x62, 0x7F…).
    public func send(_ request: OBDRequest) async throws -> [UInt8] {
        await acquire()
        defer { release() }
        try await setHeader(request.header)
        let reply = try await transport.exchange(request.command)
        if !isCAN { return try ISOTP.plainMessage(from: reply) }
        return try ISOTP.message(from: reply, responseHeader: request.responseHeader)
    }

    /// Every ECU's whole answer, keyed by the ECU's request header (a reply on 0x7E8 → 0x7E0). For a
    /// broadcast, where several ECUs answer; with headers off (or on J1850/K-line) the ECUs can't be told
    /// apart and the answer comes under the request's header.
    public func sendAll(_ request: OBDRequest) async throws -> [UInt16: [UInt8]] {
        await acquire()
        defer { release() }
        try await setHeader(request.header)
        let reply = try await transport.exchange(request.command)
        if !isCAN { return [request.header: try ISOTP.plainMessage(from: reply)] }
        return try ISOTP.messagesByECU(from: reply, responseHeader: request.responseHeader)
    }

    /// The data after the positive-response byte and the echoed parameter.
    public func read(_ request: OBDRequest) async throws -> [UInt8] {
        try Self.payload(try await send(request), for: request)
    }

    /// `read` for every ECU that answers positively, keyed like `sendAll`. Throws only when none does.
    public func readAll(_ request: OBDRequest) async throws -> [UInt16: [UInt8]] {
        var out: [UInt16: [UInt8]] = [:]
        var firstError: Error?
        for (ecu, message) in try await sendAll(request) {
            do { out[ecu] = try Self.payload(message, for: request) } catch { firstError = firstError ?? error }
        }
        if out.isEmpty { throw firstError ?? OBDError.noData }
        return out
    }

    static func payload(_ message: [UInt8], for request: OBDRequest) throws -> [UInt8] {
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
/// ("7EC 10 3E 62 01 01 …", or "18DAF110 10 3E …" on 29-bit CAN) or off ("03E" then "0: 62 01 01 …"),
/// with or without spaces.
public enum ISOTP {
    public static func message(from reply: String, responseHeader: UInt16?) throws -> [UInt8] {
        let lines = try checkedLines(reply)
        if lines.contains(where: { $0.contains(":") }) {
            return try indexed(lines)
        }
        let frames = try parseFrames(lines)
        let sawHeaders = frames.contains { $0.ecu != nil }
        // Only the wanted ECU, or the first one to answer.
        guard let wanted = responseHeader.map({ $0 &- 8 }) ?? frames.lazy.compactMap(\.ecu).first else {
            return try assemble(frames.map(\.data), sawHeaders: sawHeaders)
        }
        return try assemble(frames.filter { $0.ecu == nil || $0.ecu == wanted }.map(\.data), sawHeaders: sawHeaders)
    }

    /// Every ECU's complete message, keyed by the ECU's request header (0x7E8 → 0x7E0). Without headers
    /// the whole reply is one message, keyed by the request header (`responseHeader` − 8, else 0x7DF).
    public static func messagesByECU(from reply: String, responseHeader: UInt16?) throws -> [UInt16: [UInt8]] {
        let lines = try checkedLines(reply)
        let fallback = responseHeader.map { $0 &- 8 } ?? OBDRequest.broadcast
        if lines.contains(where: { $0.contains(":") }) {
            return [fallback: try indexed(lines)]
        }
        let frames = try parseFrames(lines)
        let sawHeaders = frames.contains { $0.ecu != nil }
        var order: [UInt16] = []
        var byECU: [UInt16: [[UInt8]]] = [:]
        for frame in frames {
            let ecu = frame.ecu ?? fallback
            if responseHeader != nil, ecu != fallback { continue } // another ECU
            if byECU[ecu] == nil { order.append(ecu) }
            byECU[ecu, default: []].append(frame.data)
        }
        var out: [UInt16: [UInt8]] = [:]
        var firstError: Error?
        for ecu in order {
            // One ECU's garbled or pending answer doesn't lose the others'.
            do { out[ecu] = try assemble(byECU[ecu] ?? [], sawHeaders: sawHeaders) } catch { firstError = firstError ?? error }
        }
        if out.isEmpty { throw firstError ?? OBDError.noData }
        return out
    }

    /// J1850 and K-line with headers off: each line is one whole message (no ISO-TP layer). Mode 09
    /// answers come one numbered line at a time, and mode 03/07 with three codes a line: those are joined.
    static func plainMessage(from reply: String) throws -> [UInt8] {
        let messages = try checkedLines(reply).map { try bytes($0) }.filter { !$0.isEmpty && !isPending($0) }
        guard let first = messages.first else { throw OBDError.noData }
        let rest = messages.dropFirst()
        switch first[0] {
        case 0x49 where first.count >= 3:
            let parts = messages.filter { $0.count >= 3 && $0[0] == first[0] && $0[1] == first[1] }.sorted { $0[2] < $1[2] }
            return parts[0] + parts.dropFirst().flatMap { $0.dropFirst(3) }
        case 0x43, 0x47:
            return first + rest.filter { $0[0] == first[0] }.flatMap { $0.dropFirst() }
        default:
            return first
        }
    }

    /// The reply's lines without the adapter's progress messages; throws for its error messages.
    static func checkedLines(_ reply: String) throws -> [String] {
        let lines = ELM327.lines(reply).filter { !$0.uppercased().hasPrefix("SEARCHING") && !$0.uppercased().hasPrefix("BUS INIT") }
        guard !lines.isEmpty else { throw OBDError.timeout }
        for line in lines {
            let upper = line.uppercased()
            if upper.contains("NO DATA") { throw OBDError.noData }
            if upper.contains("ERROR") || upper.contains("UNABLE") || upper == "STOPPED" { throw OBDError.busError(line) }
            if upper == "?" { throw OBDError.unexpected("?") }
        }
        return lines
    }

    /// 29-bit CAN: ECU address 0x10…0x17 (answering on 18DAF110…) stands for 0x7E0…0x7E7, as on 11-bit
    /// CAN; any other address xx for 0x6xx.
    public static func ecuHeader(address: UInt8) -> UInt16 {
        (0x10...0x17).contains(address) ? 0x7E0 + UInt16(address - 0x10) : 0x600 | UInt16(address)
    }

    /// The 29-bit ECU address an 11-bit-style request header stands for (the inverse of `ecuHeader`).
    public static func address(ecuHeader header: UInt16) -> UInt8 {
        (0x7E0...0x7E7).contains(header) ? 0x10 + UInt8(header - 0x7E0) : UInt8(header & 0xFF)
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

    /// Headers on: each line is one CAN frame, "7EC" (or "18DAF1EC") then the PCI byte and data. The
    /// ECU is its request header (`ecuHeader`); nil for a line without an id.
    private static func parseFrames(_ lines: [String]) throws -> [(ecu: UInt16?, data: [UInt8])] {
        try lines.map { line in
            let compact = line.replacingOccurrences(of: " ", with: "").uppercased()
            if compact.count > 3, compact.count % 2 == 1, let id = UInt16(compact.prefix(3), radix: 16) {
                // An odd number of hex digits: an 11-bit id, then bytes.
                return (id &- 8, try bytes(String(compact.dropFirst(3))))
            }
            if compact.count > 8, compact.hasPrefix("18DAF1"), let address = UInt8(compact.dropFirst(6).prefix(2), radix: 16) {
                // A 29-bit id answering the tester (F1), then bytes.
                return (ecuHeader(address: address), try bytes(String(compact.dropFirst(8))))
            }
            return (nil, try bytes(compact))
        }
    }

    /// One ECU's CAN frames → its first complete message, skipping "response pending".
    private static func assemble(_ frames: [[UInt8]], sawHeaders: Bool) throws -> [UInt8] {
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
