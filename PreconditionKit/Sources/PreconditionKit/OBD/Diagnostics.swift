import Foundation

/// A control module on the car's diagnostic bus.
public struct ECU: Identifiable, Hashable, Sendable {
    public var header: UInt16
    public var name: String
    public var id: UInt16 { header }

    public init(_ header: UInt16, _ name: String) {
        self.header = header
        self.name = name
    }

    public var address: String { String(format: "0x%03X", header) }

    /// Modules found on E-GMP cars (EV6, Ioniq 5/6) by the OVMS and Car Scanner communities. Which ones
    /// answer depends on the car's equipment and model year: `Diagnostics.scan` finds out.
    public static let egmp: [ECU] = [
        ECU(0x7E4, "Battery management (BMS)"),
        ECU(0x7E2, "Vehicle control unit (VCU)"),
        ECU(0x7E3, "Motor control (MCU)"),
        ECU(0x7E5, "On-board charger (OBC)"),
        ECU(0x7E6, "Charging control"),
        ECU(0x7E0, "Powertrain"),
        ECU(0x7E1, "Front motor control"),
        ECU(0x7A0, "Body control (BCM)"),
        ECU(0x770, "Gateway and power (IGPM)"),
        ECU(0x7B3, "Climate control (FATC)"),
        ECU(0x7C6, "Instrument cluster"),
        ECU(0x7D1, "Brakes and stability (IEB/ESC)"),
        ECU(0x7D2, "Airbags (SRS)"),
        ECU(0x7D4, "Power steering (MDPS)"),
        ECU(0x7D0, "Smart cruise radar (SCC)"),
        ECU(0x7C4, "Front camera"),
        ECU(0x7B1, "Blind-spot radar"),
        ECU(0x7B7, "Smart key"),
        ECU(0x7A5, "Power tailgate"),
        ECU(0x780, "Infotainment (AVN)"),
        ECU(0x7C7, "Head-up display"),
        ECU(0x7A3, "Driver's seat"),
    ]

    public static func named(_ header: UInt16) -> ECU {
        egmp.first { $0.header == header } ?? ECU(header, String(format: "Module 0x%03X", header))
    }
}

/// A diagnostic trouble code.
public struct TroubleCode: Identifiable, Hashable, Codable, Sendable {
    /// "P0AA6", "C1611", "U0100".
    public var code: String
    /// UDS failure type byte (the "-1C" after the code), 0 when none.
    public var failureType: UInt8
    /// UDS status byte.
    public var status: UInt8
    public var ecuHeader: UInt16
    public var raw: [UInt8]

    public var id: String { "\(ecuHeader)-\(code)-\(failureType)" }

    public init(code: String, failureType: UInt8 = 0, status: UInt8 = 0x08, ecuHeader: UInt16, raw: [UInt8] = []) {
        self.code = code
        self.failureType = failureType
        self.status = status
        self.ecuHeader = ecuHeader
        self.raw = raw
    }

    public var displayCode: String { failureType == 0 ? code : String(format: "%@-%02X", code, failureType) }

    public var isActive: Bool { status & 0x01 != 0 }
    public var isPending: Bool { status & 0x04 != 0 }
    public var isConfirmed: Bool { status & 0x08 != 0 }
    public var turnsOnWarningLight: Bool { status & 0x80 != 0 }

    public var stateText: String {
        var parts: [String] = []
        if isActive { parts.append("active now") }
        if isConfirmed { parts.append("stored") }
        if isPending { parts.append("pending") }
        if turnsOnWarningLight { parts.append("warning light") }
        return parts.isEmpty ? "history" : parts.joined(separator: ", ")
    }

    /// The system the letter stands for.
    public var system: String {
        switch code.first {
        case "P": return "Powertrain"
        case "C": return "Chassis"
        case "B": return "Body"
        case "U": return "Network"
        default: return "Unknown"
        }
    }

    /// Two bytes → "P0AA6" (SAE J2012).
    public static func sae(_ hi: UInt8, _ lo: UInt8) -> String {
        let letter = ["P", "C", "B", "U"][Int(hi >> 6)]
        return letter + String(format: "%01X%01X%02X", (hi >> 4) & 0x3, hi & 0x0F, lo)
    }

    /// What the code means, when it's a common one.
    public var meaning: String? { TroubleCode.known[code] }

    /// A short list of codes E-GMP owners actually meet, plus the generic ones every car shares.
    static let known: [String: String] = [
        "P0A7E": "Hybrid/EV battery pack over temperature",
        "P0A80": "Replace hybrid/EV battery pack",
        "P0AA6": "High-voltage isolation fault",
        "P0AFA": "Hybrid/EV battery system voltage low",
        "P0B3B": "Battery voltage sense circuit",
        "P1B77": "High-voltage battery cell deviation",
        "P0562": "12 V system voltage low",
        "P0563": "12 V system voltage high",
        "P0D27": "Battery charger input voltage",
        "P0D5B": "Charging port lock circuit",
        "P1A9A": "Charging port or cable fault",
        "P0C73": "Motor electronics coolant pump",
        "P0A3F": "Drive motor position sensor",
        "P0A1D": "Hybrid/EV powertrain control module",
        "P0A94": "DC/DC converter performance",
        "C1611": "Brake pedal stroke sensor",
        "C1702": "Variant coding not done",
        "C1260": "Steering angle sensor",
        "C2402": "Electric brake motor",
        "B1602": "Airbag sensor communication",
        "B2600": "Smart key authentication",
        "U0100": "Lost communication with the motor control unit",
        "U0101": "Lost communication with the transmission/reducer unit",
        "U0111": "Lost communication with the battery management system",
        "U0121": "Lost communication with the brake (ABS/ESC) module",
        "U0122": "Lost communication with the vehicle dynamics module",
        "U0131": "Lost communication with power steering",
        "U0140": "Lost communication with the body control module",
        "U0151": "Lost communication with the airbag module",
        "U0155": "Lost communication with the instrument cluster",
        "U0164": "Lost communication with climate control",
        "U0184": "Lost communication with the radio",
        "U0293": "Lost communication with the hybrid/EV powertrain module",
        "U1111": "Network message timeout",
        "U3003": "Battery voltage out of range (often a weak 12 V battery)",
    ]
}

/// Identity strings an ECU reports (UDS F1xx identifiers).
public struct ECUIdentity: Hashable, Sendable {
    public var ecu: ECU
    public var fields: [(String, String)]

    public static func == (a: ECUIdentity, b: ECUIdentity) -> Bool {
        a.ecu == b.ecu && a.fields.map(\.0) == b.fields.map(\.0) && a.fields.map(\.1) == b.fields.map(\.1)
    }

    public func hash(into h: inout Hasher) { h.combine(ecu) }
}

/// Finding modules, reading and clearing trouble codes, and reading identifiers.
public struct Diagnostics: Sendable {
    let elm: ELM327

    public init(elm: ELM327) {
        self.elm = elm
    }

    /// The modules that answer, from `candidates`.
    public func scan(_ candidates: [ECU] = ECU.egmp, progress: @Sendable (Int, Int) async -> Void = { _, _ in }) async throws -> [ECU] {
        try await elm.initialiseIfNeeded()
        var found: [ECU] = []
        for (i, ecu) in candidates.enumerated() {
            await progress(i + 1, candidates.count)
            if await elm.ping(ecu.header) { found.append(ecu) }
        }
        return found
    }

    /// UDS 19 02: codes with any status bit set.
    public func troubleCodes(_ ecu: ECU) async throws -> [TroubleCode] {
        let data = try await elm.read(OBDRequest(header: ecu.header, service: 0x19, parameter: [0x02, 0xFF], echo: 1))
        return Self.parseUDS(data, ecu: ecu.header)
    }

    /// Standard OBD-II: stored (mode 03) and pending (mode 07) emission codes from every ECU.
    public func emissionCodes() async throws -> [TroubleCode] {
        var out: [TroubleCode] = []
        for (service, status) in [(UInt8(0x03), UInt8(0x08)), (0x07, 0x04)] {
            if let data = try? await elm.read(OBDRequest(header: OBDRequest.broadcast, service: service)) {
                out += Self.parseOBD(data, status: status)
            }
        }
        return out
    }

    /// Clears one module's codes (UDS 14 FFFFFF).
    public func clear(_ ecu: ECU) async throws {
        _ = try await elm.read(OBDRequest(header: ecu.header, service: 0x14, parameter: [0xFF, 0xFF, 0xFF], echo: 0))
    }

    /// Clears emission codes on every module (OBD-II mode 04).
    public func clearEmissionCodes() async throws {
        _ = try await elm.read(OBDRequest(header: OBDRequest.broadcast, service: 0x04))
    }

    /// Snapshot ("freeze frame") data stored with a code, as raw bytes: its layout is manufacturer-specific.
    public func snapshot(_ code: TroubleCode) async throws -> [UInt8] {
        guard code.raw.count >= 3 else { return [] }
        return try await elm.read(OBDRequest(header: code.ecuHeader, service: 0x19, parameter: [0x04] + code.raw.prefix(3) + [0xFF], echo: 1))
    }

    public static let identifiers: [(UInt16, String)] = [
        (0xF190, "VIN"),
        (0xF187, "Part number"),
        (0xF189, "Software version"),
        (0xF191, "Hardware number"),
        (0xF18C, "Serial number"),
        (0xF18B, "Manufactured"),
        (0xF100, "ECU information"),
    ]

    /// Whatever identifiers the module reports; missing ones are skipped.
    public func identity(_ ecu: ECU) async -> ECUIdentity {
        var fields: [(String, String)] = []
        for (did, name) in Self.identifiers {
            guard let data = try? await elm.read(OBDRequest(header: ecu.header, did: did)) else { continue }
            let text = Self.text(data)
            if !text.isEmpty { fields.append((name, text)) }
        }
        return ECUIdentity(ecu: ecu, fields: fields)
    }

    /// OBD-II mode 09 PID 02.
    public func vin() async -> String? {
        guard let data = try? await elm.read(OBDRequest(header: OBDRequest.broadcast, service: 0x09, parameter: [0x02])) else { return nil }
        let text = Self.text(data)
        return text.count >= 17 ? String(text.suffix(17)) : (text.isEmpty ? nil : text)
    }

    /// Mode 01 PIDs the car supports (from the 0x00, 0x20, 0x40… bitmaps).
    public func supportedPIDs() async -> Set<UInt8> {
        var out = Set<UInt8>()
        var base: UInt8 = 0
        while true {
            guard let data = try? await elm.read(OBDRequest(header: OBDRequest.broadcast, service: 0x01, parameter: [base])), data.count >= 4 else { break }
            let bits = UInt32(data[0]) << 24 | UInt32(data[1]) << 16 | UInt32(data[2]) << 8 | UInt32(data[3])
            for i in 0..<32 where bits & (0x8000_0000 >> UInt32(i)) != 0 { out.insert(base &+ UInt8(i + 1)) }
            // The last bit says whether the next block exists.
            guard bits & 1 != 0, base < 0xC0 else { break }
            base &+= 0x20
        }
        return out
    }

    // MARK: Parsing

    /// After `59 02`: the availability mask, then 4 bytes per code (3 code bytes, status).
    public static func parseUDS(_ data: [UInt8], ecu: UInt16) -> [TroubleCode] {
        guard !data.isEmpty else { return [] }
        let records = data.dropFirst()
        var out: [TroubleCode] = []
        var i = records.startIndex
        while i + 3 < records.endIndex {
            let b = Array(records[i..<(i + 4)])
            i += 4
            if b[0] == 0 && b[1] == 0 && b[2] == 0 { continue }
            out.append(TroubleCode(code: TroubleCode.sae(b[0], b[1]), failureType: b[2], status: b[3], ecuHeader: ecu, raw: Array(b.prefix(3))))
        }
        return out
    }

    /// After `43`/`47`: optionally a count byte, then 2 bytes per code.
    public static func parseOBD(_ data: [UInt8], status: UInt8, ecu: UInt16 = OBDRequest.broadcast) -> [TroubleCode] {
        var bytes = data
        // CAN adds a count byte, so the length is odd.
        if bytes.count % 2 == 1 { bytes.removeFirst() }
        var out: [TroubleCode] = []
        var i = 0
        while i + 1 < bytes.count {
            if bytes[i] != 0 || bytes[i + 1] != 0 {
                out.append(TroubleCode(code: TroubleCode.sae(bytes[i], bytes[i + 1]), status: status, ecuHeader: ecu))
            }
            i += 2
        }
        return out
    }

    /// Printable ASCII, trimmed; binary identifiers come back as hex.
    static func text(_ data: [UInt8]) -> String {
        let trimmed = data.drop { $0 == 0 || $0 == 0x01 }
        let printable = trimmed.filter { $0 >= 0x20 && $0 < 0x7F }
        if !trimmed.isEmpty && printable.count * 10 >= trimmed.count * 8 {
            return String(decoding: printable, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        }
        return ISOTP.hex(Array(data))
    }
}
