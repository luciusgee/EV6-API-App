import Foundation

/// What the battery management system and tyre sensors of an E-GMP car (EV6, Ioniq 5/6) report over
/// the OBD port. Byte positions follow OVMS's `vehicle_hyundai_ioniq5` decoder and count from the first
/// byte after `62 DID DID`. Every field is optional: a missing or short answer leaves it nil.
public struct BatteryReport: Codable, Equatable, Sendable {
    public var takenAt: Date
    /// State of health, %, as the BMS works it out (0x0105).
    public var sohPercent: Double?
    /// The BMS's real state of charge (0x0101), and the one the dashboard shows (0x0105).
    public var socBMSPercent: Double?
    public var socDisplayPercent: Double?
    public var packVolts: Double?
    /// Positive while discharging, negative while charging.
    public var packAmps: Double?
    public var availableChargePowerKW: Double?
    public var batteryMaxC: Double?
    public var batteryMinC: Double?
    public var moduleTempsC: [Double]
    public var inletC: Double?
    public var cellMaxVolts: Double?
    public var cellMaxNumber: Int?
    public var cellMinVolts: Double?
    public var cellMinNumber: Int?
    /// Every cell, in order (0x0102–0x010C), when read.
    public var cellVolts: [Double]
    public var cumulativeChargedAh: Double?
    public var cumulativeDischargedAh: Double?
    public var cumulativeChargedKWh: Double?
    public var cumulativeDischargedKWh: Double?
    public var operatingHours: Double?
    /// Front left, front right, rear left, rear right.
    public var tyrePressuresPsi: [Double?]
    public var tyreTempsC: [Double?]

    public init(takenAt: Date) {
        self.takenAt = takenAt
        moduleTempsC = []
        cellVolts = []
        tyrePressuresPsi = []
        tyreTempsC = []
    }

    /// Power in kW, positive while discharging.
    public var powerKW: Double? {
        guard let v = packVolts, let a = packAmps else { return nil }
        return v * a / 1000
    }

    /// Largest gap between cells, in millivolts: a healthy pack stays within a few tens of mV.
    public var cellSpreadMillivolts: Double? {
        if cellVolts.count > 1, let hi = cellVolts.max(), let lo = cellVolts.min() { return (hi - lo) * 1000 }
        if let hi = cellMaxVolts, let lo = cellMinVolts { return (hi - lo) * 1000 }
        return nil
    }

    /// 192 cells: the 77.4 kWh pack; 144: 58 kWh.
    public var packDescription: String? {
        switch cellVolts.count {
        case 192: return "77.4 kWh · 192 cells"
        case 180: return "84 kWh · 180 cells"
        case 144: return "58 kWh · 144 cells"
        case 0: return nil
        default: return "\(cellVolts.count) cells"
        }
    }

    /// Plain-English verdicts for the health screen.
    public var findings: [String] {
        var out: [String] = []
        if let soh = sohPercent {
            if soh >= 95 { out.append(String(format: "Battery health %.1f%%: excellent.", soh)) }
            else if soh >= 85 { out.append(String(format: "Battery health %.1f%%: normal ageing.", soh)) }
            else { out.append(String(format: "Battery health %.1f%%: below Kia's usual range; worth a dealer check (warranty covers 70%% for 8 years).", soh)) }
        }
        if let spread = cellSpreadMillivolts {
            if spread <= 40 { out.append(String(format: "Cells balanced within %.0f mV.", spread)) }
            else if spread <= 100 { out.append(String(format: "Cells %.0f mV apart: charge to 100%% now and then to let them balance.", spread)) }
            else { out.append(String(format: "Cells %.0f mV apart: unusually wide; keep an eye on it.", spread)) }
        }
        if let hi = batteryMaxC, let lo = batteryMinC, hi - lo > 8 {
            out.append(String(format: "Battery temperatures differ by %.0f °C.", hi - lo))
        }
        return out
    }
}

public enum EGMP {
    /// Battery management system.
    public static let bms: UInt16 = 0x7E4
    /// Body control module (tyre pressure sensors).
    public static let bcm: UInt16 = 0x7A0

    public static let bmsMain = OBDRequest(header: bms, did: 0x0101)
    public static let bmsHealth = OBDRequest(header: bms, did: 0x0105)
    /// 32 cells each.
    public static let cellBlocks: [(OBDRequest, Int)] = [
        (OBDRequest(header: bms, did: 0x0102), 0),
        (OBDRequest(header: bms, did: 0x0103), 32),
        (OBDRequest(header: bms, did: 0x0104), 64),
        (OBDRequest(header: bms, did: 0x010A), 96),
        (OBDRequest(header: bms, did: 0x010B), 128),
        (OBDRequest(header: bms, did: 0x010C), 160),
    ]
    public static let tyres = OBDRequest(header: bcm, did: 0xC00B)

    private static func u8(_ d: [UInt8], _ i: Int) -> Int? { d.indices.contains(i) ? Int(d[i]) : nil }
    private static func s8(_ d: [UInt8], _ i: Int) -> Int? { d.indices.contains(i) ? Int(Int8(bitPattern: d[i])) : nil }
    private static func u16(_ d: [UInt8], _ i: Int) -> Int? { i + 1 < d.count ? Int(d[i]) << 8 | Int(d[i + 1]) : nil }
    private static func s16(_ d: [UInt8], _ i: Int) -> Int? { u16(d, i).map { Int(Int16(truncatingIfNeeded: $0)) } }
    private static func u32(_ d: [UInt8], _ i: Int) -> Int? {
        i + 3 < d.count ? Int(d[i]) << 24 | Int(d[i + 1]) << 16 | Int(d[i + 2]) << 8 | Int(d[i + 3]) : nil
    }

    public static func applyMain(_ d: [UInt8], to r: inout BatteryReport) {
        r.socBMSPercent = u8(d, 4).map { Double($0) / 2 }
        r.availableChargePowerKW = u16(d, 5).map { Double($0) / 100 }
        r.packAmps = s16(d, 10).map { Double($0) / 10 }
        r.packVolts = u16(d, 12).map { Double($0) / 10 }
        r.batteryMaxC = s8(d, 14).map(Double.init)
        r.batteryMinC = s8(d, 15).map(Double.init)
        r.moduleTempsC = (16..<21).compactMap { s8(d, $0).map(Double.init) }
        r.inletC = s8(d, 22).map(Double.init)
        r.cellMaxVolts = u8(d, 23).map { Double($0) / 50 }
        r.cellMaxNumber = u8(d, 24)
        r.cellMinVolts = u8(d, 25).map { Double($0) / 50 }
        r.cellMinNumber = u8(d, 26)
        r.cumulativeChargedAh = u32(d, 30).map { Double($0) / 10 }
        r.cumulativeDischargedAh = u32(d, 34).map { Double($0) / 10 }
        r.cumulativeChargedKWh = u32(d, 38).map { Double($0) / 10 }
        r.cumulativeDischargedKWh = u32(d, 42).map { Double($0) / 10 }
        r.operatingHours = u32(d, 46).map { Double($0) / 3600 }
    }

    public static func applyHealth(_ d: [UInt8], to r: inout BatteryReport) {
        if let soh = u16(d, 25), soh > 0, soh <= 1100 { r.sohPercent = Double(soh) / 10 }
        r.socDisplayPercent = u8(d, 31).map { Double($0) / 2 }
    }

    /// One block of 32 cells: a presence bitmap, then one byte per cell in 20 mV steps.
    public static func cells(_ d: [UInt8]) -> [Double] {
        guard let present = u32(d, 0) else { return [] }
        var out: [Double] = []
        for i in 0..<32 where present & (0x8000_0000 >> i) != 0 {
            guard let raw = u8(d, 4 + i) else { break }
            out.append(Double(raw) * 0.02)
        }
        return out
    }

    public static func applyTyres(_ d: [UInt8], to r: inout BatteryReport) {
        let positions = [4, 9, 14, 19]
        r.tyrePressuresPsi = positions.map { i in u8(d, i).flatMap { $0 > 0 ? Double($0) / 5 : nil } }
        r.tyreTempsC = positions.map { i in u8(d, i + 1).flatMap { $0 > 0 ? Double($0) - 50 : nil } }
    }
}

/// Runs a full battery and tyre read. Each request stands alone: one that fails is reported and skipped.
public struct BatteryScanner: Sendable {
    public struct Progress: Sendable {
        public var step: Int
        public var of: Int
        public var label: String

        public init(step: Int, of: Int, label: String) {
            self.step = step
            self.of = of
            self.label = label
        }
    }

    let elm: ELM327
    let now: @Sendable () -> Date

    public init(elm: ELM327, now: @escaping @Sendable () -> Date = { Date() }) {
        self.elm = elm
        self.now = now
    }

    /// Throws only when nothing at all could be read.
    public func scan(includeCells: Bool = true, progress: @Sendable (Progress) async -> Void = { _ in }) async throws -> (BatteryReport, [String]) {
        var report = BatteryReport(takenAt: now())
        var problems: [String] = []
        var anySuccess = false
        let total = 3 + (includeCells ? EGMP.cellBlocks.count : 0) + 1
        var step = 0

        func next(_ label: String) async {
            step += 1
            await progress(Progress(step: step, of: total, label: label))
        }

        await next("Connecting to the adapter")
        try await elm.initialise()

        await next("Reading the battery")
        do {
            EGMP.applyMain(try await elm.read(EGMP.bmsMain), to: &report)
            anySuccess = true
        } catch {
            problems.append("battery: \(error)")
            // Nothing answers when the car is off: stop here rather than time out on every request.
            if error as? OBDError == .noData { throw error }
        }

        await next("Reading battery health")
        do {
            EGMP.applyHealth(try await elm.read(EGMP.bmsHealth), to: &report)
            anySuccess = true
        } catch { problems.append("health: \(error)") }

        if includeCells {
            var cells: [Double] = []
            for (request, first) in EGMP.cellBlocks {
                await next("Reading cells \(first + 1)–\(first + 32)")
                do {
                    cells += EGMP.cells(try await elm.read(request))
                    anySuccess = true
                } catch {
                    // The 58 kWh pack has fewer cells; later blocks may be absent.
                    if first < 96 { problems.append("cells \(first + 1)–\(first + 32): \(error)") }
                }
            }
            report.cellVolts = cells
        }

        await next("Reading tyre sensors")
        do {
            EGMP.applyTyres(try await elm.read(EGMP.tyres), to: &report)
            anySuccess = true
        } catch { problems.append("tyres: \(error)") }

        if !anySuccess { throw OBDError.noData }
        return (report, problems)
    }
}
