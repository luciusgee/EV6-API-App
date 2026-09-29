import Foundation

/// One value the car reports over OBD: where to ask for it and how to read the answer.
public struct Sensor: Identifiable, Hashable, Sendable {
    public enum Group: String, CaseIterable, Sendable {
        case drive = "Driving"
        case battery = "Battery"
        case cells = "Cells"
        case climate = "Climate"
        case body = "Body"
        case tyres = "Tyres"
        case standard = "Standard OBD-II"
    }

    public var id: String
    public var name: String
    public var group: Group
    public var unit: String
    public var request: OBDRequest
    /// Typical range, for gauges and chart scales.
    public var range: ClosedRange<Double>
    /// Decimal places to show.
    public var decimals: Int
    let decode: @Sendable ([UInt8]) -> Double?

    public init(
        _ id: String, _ name: String, _ group: Group, unit: String, request: OBDRequest,
        range: ClosedRange<Double>, decimals: Int = 0, decode: @escaping @Sendable ([UInt8]) -> Double?
    ) {
        self.id = id
        self.name = name
        self.group = group
        self.unit = unit
        self.request = request
        self.range = range
        self.decimals = decimals
        self.decode = decode
    }

    public func value(from data: [UInt8]) -> Double? { decode(data) }

    public func format(_ v: Double) -> String {
        let number = String(format: "%.\(decimals)f", v)
        return unit.isEmpty ? number : "\(number) \(unit)"
    }

    public static func == (a: Sensor, b: Sensor) -> Bool { a.id == b.id }
    public func hash(into h: inout Hasher) { h.combine(id) }
}

/// Byte readers; offsets count from the first byte after the echoed identifier.
enum Bytes {
    static func u8(_ d: [UInt8], _ i: Int) -> Double? { d.indices.contains(i) ? Double(d[i]) : nil }
    static func s8(_ d: [UInt8], _ i: Int) -> Double? { d.indices.contains(i) ? Double(Int8(bitPattern: d[i])) : nil }
    static func u16(_ d: [UInt8], _ i: Int) -> Double? { i + 1 < d.count ? Double(Int(d[i]) << 8 | Int(d[i + 1])) : nil }
    static func s16(_ d: [UInt8], _ i: Int) -> Double? { u16(d, i).map { Double(Int16(truncatingIfNeeded: Int($0))) } }
    static func u24(_ d: [UInt8], _ i: Int) -> Double? {
        i + 2 < d.count ? Double(Int(d[i]) << 16 | Int(d[i + 1]) << 8 | Int(d[i + 2])) : nil
    }
    static func u32(_ d: [UInt8], _ i: Int) -> Double? {
        i + 3 < d.count ? Double(Int(d[i]) << 24 | Int(d[i + 1]) << 16 | Int(d[i + 2]) << 8 | Int(d[i + 3])) : nil
    }
    static func bit(_ d: [UInt8], _ i: Int, _ b: Int) -> Double? { d.indices.contains(i) ? Double((d[i] >> b) & 1) : nil }
}

/// Everything the EV6 (and the other E-GMP cars) is known to report, from OVMS's Ioniq 5 decoder and
/// the standard OBD-II set.
public enum EV6Sensors {
    /// Climate control module: speed and temperatures.
    public static let hvac: UInt16 = 0x7B3
    /// Vehicle control unit: gear and accelerator.
    public static let vcu: UInt16 = 0x7E2
    /// Instrument cluster: odometer.
    public static let cluster: UInt16 = 0x7C6
    /// Integrated gateway and power module: ignition, doors, seat belts.
    public static let igpm: UInt16 = 0x770

    static let bms0101 = EGMP.bmsMain
    static let bms0105 = EGMP.bmsHealth
    static let hvac0100 = OBDRequest(header: hvac, did: 0x0100)
    static let vcuE004 = OBDRequest(header: vcu, did: 0xE004)
    static let clusterB002 = OBDRequest(header: cluster, did: 0xB002)
    static let igpmBC03 = OBDRequest(header: igpm, did: 0xBC03)
    static let igpmBC04 = OBDRequest(header: igpm, did: 0xBC04)
    static let tpms = EGMP.tyres

    static func pid(_ p: UInt8) -> OBDRequest { OBDRequest(header: OBDRequest.broadcast, service: 0x01, parameter: [p]) }

    public static let all: [Sensor] = {
        var s: [Sensor] = [
            // Driving
            Sensor("speed", "Speed", .drive, unit: "km/h", request: hvac0100, range: 0...200) { Bytes.u8($0, 29) },
            Sensor("power", "Battery power", .drive, unit: "kW", request: bms0101, range: -150...250, decimals: 1) { d in
                guard let a = Bytes.s16(d, 10), let v = Bytes.u16(d, 12) else { return nil }
                return a / 10 * v / 10 / 1000
            },
            Sensor("rpmFront", "Front motor", .drive, unit: "rpm", request: bms0101, range: -2000...15000) { Bytes.s16($0, 53) },
            Sensor("rpmRear", "Rear motor", .drive, unit: "rpm", request: bms0101, range: -2000...15000) { Bytes.s16($0, 55) },
            Sensor("accelerator", "Accelerator", .drive, unit: "%", request: vcuE004, range: 0...100) { Bytes.u8($0, 9).map { $0 / 2 } },
            Sensor("gear", "Gear", .drive, unit: "", request: vcuE004, range: 0...7) { d in Bytes.u8(d, 14).map { Double(Int($0) & 0x0F) } },
            Sensor("odometer", "Odometer", .drive, unit: "km", request: clusterB002, range: 0...500_000) { d in
                if let km = Bytes.u24(d, 6), km > 0 { return km }
                return Bytes.u24(d, 9).flatMap { $0 > 0 ? $0 * 1.609344 : nil }
            },

            // Battery
            Sensor("socBMS", "Charge (BMS)", .battery, unit: "%", request: bms0101, range: 0...100, decimals: 1) { Bytes.u8($0, 4).map { $0 / 2 } },
            Sensor("socDisplay", "Charge (dashboard)", .battery, unit: "%", request: bms0105, range: 0...100, decimals: 1) { Bytes.u8($0, 31).map { $0 / 2 } },
            Sensor("soh", "State of health", .battery, unit: "%", request: bms0105, range: 70...100, decimals: 1) { d in
                Bytes.u16(d, 25).flatMap { $0 > 0 && $0 <= 1100 ? $0 / 10 : nil }
            },
            Sensor("voltage", "Pack voltage", .battery, unit: "V", request: bms0101, range: 500...850, decimals: 1) { Bytes.u16($0, 12).map { $0 / 10 } },
            Sensor("current", "Pack current", .battery, unit: "A", request: bms0101, range: -300...500, decimals: 1) { Bytes.s16($0, 10).map { $0 / 10 } },
            Sensor("maxCharge", "Max charge power", .battery, unit: "kW", request: bms0101, range: 0...260) { Bytes.u16($0, 5).map { $0 / 100 } },
            Sensor("battMax", "Battery max temp", .battery, unit: "°C", request: bms0101, range: -20...60) { Bytes.s8($0, 14) },
            Sensor("battMin", "Battery min temp", .battery, unit: "°C", request: bms0101, range: -20...60) { Bytes.s8($0, 15) },
            Sensor("inlet", "Coolant inlet", .battery, unit: "°C", request: bms0101, range: -20...60) { Bytes.s8($0, 22) },
            Sensor("charged", "Charged since new", .battery, unit: "kWh", request: bms0101, range: 0...200_000) { Bytes.u32($0, 38).map { $0 / 10 } },
            Sensor("discharged", "Used since new", .battery, unit: "kWh", request: bms0101, range: 0...200_000) { Bytes.u32($0, 42).map { $0 / 10 } },
            Sensor("hours", "Operating time", .battery, unit: "h", request: bms0101, range: 0...100_000) { Bytes.u32($0, 46).map { $0 / 3600 } },

            // Cells
            Sensor("cellMax", "Highest cell", .cells, unit: "V", request: bms0101, range: 3.0...4.25, decimals: 2) { Bytes.u8($0, 23).map { $0 / 50 } },
            Sensor("cellMaxNo", "Highest cell no.", .cells, unit: "", request: bms0101, range: 1...192) { Bytes.u8($0, 24) },
            Sensor("cellMin", "Lowest cell", .cells, unit: "V", request: bms0101, range: 3.0...4.25, decimals: 2) { Bytes.u8($0, 25).map { $0 / 50 } },
            Sensor("cellMinNo", "Lowest cell no.", .cells, unit: "", request: bms0101, range: 1...192) { Bytes.u8($0, 26) },
            Sensor("cellSpread", "Cell spread", .cells, unit: "mV", request: bms0101, range: 0...200) { d in
                guard let hi = Bytes.u8(d, 23), let lo = Bytes.u8(d, 25) else { return nil }
                return (hi - lo) / 50 * 1000
            },

            // Climate
            Sensor("cabin", "Cabin", .climate, unit: "°C", request: hvac0100, range: -20...50, decimals: 1) { Bytes.u8($0, 5).map { $0 / 2 - 40 } },
            Sensor("outside", "Outside", .climate, unit: "°C", request: hvac0100, range: -20...50, decimals: 1) { Bytes.u8($0, 6).map { $0 / 2 - 40 } },

            // Body
            Sensor("ignition", "Ignition on", .body, unit: "", request: igpmBC03, range: 0...1) { d in Bytes.u8(d, 5).map { Int($0) & 0x60 != 0 ? 1 : 0 } },
            Sensor("bonnet", "Bonnet open", .body, unit: "", request: igpmBC03, range: 0...1) { Bytes.bit($0, 5, 0) },
            Sensor("boot", "Boot open", .body, unit: "", request: igpmBC03, range: 0...1) { Bytes.bit($0, 4, 7) },
            Sensor("driverDoor", "Driver's door open", .body, unit: "", request: igpmBC03, range: 0...1) { Bytes.bit($0, 4, 5) },
            Sensor("passengerDoor", "Passenger door open", .body, unit: "", request: igpmBC03, range: 0...1) { Bytes.bit($0, 4, 4) },
            Sensor("driverBelt", "Driver's belt", .body, unit: "", request: igpmBC03, range: 0...1) { Bytes.bit($0, 5, 1) },
            Sensor("driverLock", "Driver's door locked", .body, unit: "", request: igpmBC04, range: 0...1) { d in Bytes.bit(d, 4, 3).map { 1 - $0 } },
        ]
        let tyreNames = ["front left", "front right", "rear left", "rear right"]
        for (i, name) in tyreNames.enumerated() {
            let key = ["FL", "FR", "RL", "RR"][i]
            s.append(Sensor("psi\(key)", "Tyre \(name)", .tyres, unit: "psi", request: tpms, range: 20...50, decimals: 1) { d in
                Bytes.u8(d, 4 + i * 5).flatMap { $0 > 0 ? $0 / 5 : nil }
            })
            s.append(Sensor("tyreTemp\(key)", "Tyre temp \(name)", .tyres, unit: "°C", request: tpms, range: -20...80) { d in
                Bytes.u8(d, 5 + i * 5).flatMap { $0 > 0 ? $0 - 50 : nil }
            })
        }
        for m in 0..<5 {
            s.append(Sensor("module\(m + 1)", "Module \(m + 1) temp", .battery, unit: "°C", request: bms0101, range: -20...60) { Bytes.s8($0, 16 + m) })
        }
        s += standard
        return s
    }()

    /// Standard OBD-II mode 01, asked of every ECU. EVs support few of these; the car says which.
    public static let standard: [Sensor] = [
        Sensor("obdVoltage", "12 V (control module)", .standard, unit: "V", request: pid(0x42), range: 10...15.5, decimals: 2) { Bytes.u16($0, 0).map { $0 / 1000 } },
        Sensor("obdSpeed", "Speed (OBD-II)", .standard, unit: "km/h", request: pid(0x0D), range: 0...200) { Bytes.u8($0, 0) },
        Sensor("obdAmbient", "Ambient air (OBD-II)", .standard, unit: "°C", request: pid(0x46), range: -40...60) { Bytes.u8($0, 0).map { $0 - 40 } },
        Sensor("obdHybridSoc", "Battery remaining (OBD-II)", .standard, unit: "%", request: pid(0x5B), range: 0...100, decimals: 1) { Bytes.u8($0, 0).map { $0 * 100 / 255 } },
        Sensor("obdRunTime", "Time since start", .standard, unit: "s", request: pid(0x1F), range: 0...36_000) { Bytes.u16($0, 0) },
        Sensor("obdDistanceMIL", "Distance with warning light", .standard, unit: "km", request: pid(0x21), range: 0...65_535) { Bytes.u16($0, 0) },
        Sensor("obdDistanceCleared", "Distance since codes cleared", .standard, unit: "km", request: pid(0x31), range: 0...65_535) { Bytes.u16($0, 0) },
        Sensor("obdLoad", "Absolute load", .standard, unit: "%", request: pid(0x43), range: 0...100) { Bytes.u16($0, 0).map { $0 * 100 / 255 } },
        Sensor("obdPedal", "Accelerator (OBD-II)", .standard, unit: "%", request: pid(0x49), range: 0...100) { Bytes.u8($0, 0).map { $0 * 100 / 255 } },
    ]

    public static func sensor(_ id: String) -> Sensor? { all.first { $0.id == id } }

    /// Gear byte → letter.
    public static func gearName(_ v: Double) -> String {
        switch Int(v) {
        case 0: return "P"
        case 5: return "D"
        case 6: return "N"
        case 7: return "R"
        default: return "–"
        }
    }

    /// Reads every sensor in `sensors` that shares one of `requests`, one request each.
    public static func decode(_ sensors: [Sensor], request: OBDRequest, data: [UInt8]) -> [String: Double] {
        var out: [String: Double] = [:]
        for s in sensors where s.request == request {
            if let v = s.value(from: data) { out[s.id] = v }
        }
        return out
    }
}
