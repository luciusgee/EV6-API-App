import Foundation

/// A battery report worked through: capacity, how evenly the cells sit, the modules, temperatures
/// and lifetime use, with a verdict on each. Everything here is derived from the battery's own OBD
/// data, not a manufacturer's capacity test.
public struct BatteryAnalysis: Equatable, Sendable {
    public enum Status: String, Sendable, Comparable {
        case good, fair, attention, unknown

        private var rank: Int {
            switch self {
            case .good: return 0
            case .unknown: return 1
            case .fair: return 2
            case .attention: return 3
            }
        }

        public static func < (a: Status, b: Status) -> Bool { a.rank < b.rank }
    }

    public struct Check: Equatable, Sendable, Identifiable {
        public var title: String
        public var status: Status
        public var value: String
        public var detail: String
        public var id: String { title }
    }

    public struct Cell: Equatable, Sendable {
        public var number: Int
        public var volts: Double
        /// From the pack's average, millivolts.
        public var deviationMV: Double
    }

    public struct Module: Equatable, Sendable, Identifiable {
        public var number: Int
        public var cells: ClosedRange<Int>
        public var meanVolts: Double
        public var spreadMV: Double
        public var temperatureC: Double?
        public var id: Int { number }
    }

    public let report: BatteryReport

    // Pack
    public let cellCount: Int
    /// The pack's gross capacity when new, from its cell count.
    public let nominalKWh: Double?
    /// Nominal × state of health: an estimate of what the pack holds now.
    public let estimatedKWh: Double?

    // Cells
    public let meanVolts: Double?
    public let medianVolts: Double?
    public let standardDeviationMV: Double?
    public let spreadMV: Double?
    /// Lowest first.
    public let weakest: [Cell]
    /// Highest first.
    public let strongest: [Cell]
    /// Cells well below the rest: more than 3 standard deviations, and more than two reading steps.
    public let outliers: [Cell]
    /// Empty when the cell count isn't a whole number of modules, rather than inventing boundaries.
    public let modules: [Module]

    // Use
    public let equivalentCycles: Double?
    /// Energy out over energy in since new: below 1 because of charging and cell losses.
    public let throughputRatio: Double?
    public let temperatureSpreadC: Double?

    public let checks: [Check]
    /// A to D: set by state of health; the other checks can lower it by one step at most.
    public let grade: String

    /// E-GMP modules hold six cells in series.
    public static let cellsPerModule = 6
    /// The BMS reports cell voltages in 20 mV steps, so smaller differences can't be seen.
    public static let cellResolutionMV = 20.0
    /// Below this current, either way, the pack counts as at rest.
    static let restAmps = 5.0

    /// A guess when the car's model isn't known.
    public static func nominalKWh(cells: Int) -> Double? {
        switch cells {
        case 192: return 77.4
        case 180: return 72.6
        case 160: return 76.1
        case 144: return 58.0
        default: return nil
        }
    }

    /// `pack` is the car's battery when known; otherwise it's guessed from the cell count.
    public init(_ report: BatteryReport, pack: PackSpec? = nil) {
        self.report = report
        let cells = report.cellVolts
        cellCount = cells.count
        nominalKWh = pack?.kWh ?? Self.nominalKWh(cells: cells.count)
        estimatedKWh = nominalKWh.flatMap { n in report.sohPercent.map { n * $0 / 100 } }

        if cells.count > 1 {
            let mean = cells.reduce(0, +) / Double(cells.count)
            let sorted = cells.sorted()
            let mid = sorted.count / 2
            meanVolts = mean
            medianVolts = sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
            let variance = cells.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(cells.count)
            let sd = variance.squareRoot() * 1000
            standardDeviationMV = sd
            spreadMV = (sorted.last! - sorted.first!) * 1000
            let all = cells.enumerated().map { Cell(number: $0.offset + 1, volts: $0.element, deviationMV: ($0.element - mean) * 1000) }
            let byVolts = all.sorted { $0.volts < $1.volts }
            weakest = Array(byVolts.prefix(5))
            strongest = Array(byVolts.suffix(5).reversed())
            // A single reading step is noise, not a weak cell: ask for more than two.
            outliers = byVolts.filter { $0.deviationMV < -max(3 * sd, 2 * Self.cellResolutionMV) }
            var modules: [Module] = []
            let temps = report.moduleTempsC
            // Only group whole modules: a pack that doesn't divide by six has a layout we don't know.
            let groups = cells.count % Self.cellsPerModule == 0 ? cells.count : 0
            for start in stride(from: 0, to: groups, by: Self.cellsPerModule) {
                let slice = cells[start..<min(start + Self.cellsPerModule, cells.count)]
                let n = start / Self.cellsPerModule
                // The BMS reports fewer temperature sensors than modules: share them out evenly.
                let temp = temps.isEmpty ? nil : temps[min(temps.count - 1, n * temps.count / max(1, (cells.count + Self.cellsPerModule - 1) / Self.cellsPerModule))]
                modules.append(Module(
                    number: n + 1, cells: (start + 1)...(start + slice.count),
                    meanVolts: slice.reduce(0, +) / Double(slice.count),
                    spreadMV: ((slice.max() ?? 0) - (slice.min() ?? 0)) * 1000,
                    temperatureC: temp
                ))
            }
            self.modules = modules
        } else {
            meanVolts = nil
            medianVolts = nil
            standardDeviationMV = nil
            spreadMV = report.cellSpreadMillivolts
            weakest = []
            strongest = []
            outliers = []
            modules = []
        }

        let nominal = nominalKWh ?? 77.4
        equivalentCycles = report.cumulativeChargedKWh.map { $0 / nominal }
        if let charged = report.cumulativeChargedKWh, let used = report.cumulativeDischargedKWh, charged > 0 {
            throughputRatio = used / charged
        } else {
            throughputRatio = nil
        }
        var temps = report.moduleTempsC
        if temps.isEmpty { temps = [report.batteryMinC, report.batteryMaxC].compactMap { $0 } }
        temperatureSpreadC = temps.count > 1 ? (temps.max()! - temps.min()!) : nil

        var checks: [Check] = []
        checks.append(Self.healthCheck(report.sohPercent))
        checks.append(Self.balanceCheck(spreadMV))
        if !weakest.isEmpty {
            let w = weakest[0]
            // Judged as the findings are: a cell that stands out needs attention. Otherwise in reading
            // steps, as the balance check is: two steps low (rounded) is still closely matched.
            let low = (-w.deviationMV).rounded()
            let status: Status = !outliers.isEmpty ? .attention : low <= 2 * Self.cellResolutionMV ? .good : .fair
            checks.append(Check(
                title: "Weakest cell", status: status,
                value: String(format: "Cell %d, %.0f mV below average", w.number, -w.deviationMV),
                detail: outliers.isEmpty
                    ? "No cell stands out from the rest."
                    : "\(outliers.count) cell\(outliers.count == 1 ? " sits" : "s sit") well below the rest. One reading isn't conclusive: read again after a full charge and compare."
                    + " Cells are read in 20 mV steps."
            ))
        }
        if let spread = temperatureSpreadC {
            // With current flowing the pack is charging or driving, and uneven heat is expected.
            let atRest = report.packAmps.map { abs($0) < Self.restAmps } ?? true
            let measured: Status = spread <= 5 ? .good : spread <= 10 ? .fair : .attention
            let status: Status = atRest || measured == .good ? measured : .unknown
            let detail: String
            switch status {
            case .good: detail = "The pack's temperature is even."
            case .unknown: detail = "Some of the pack is warmer than the rest, but current is flowing, so this isn't judged. Read again when the car has rested."
            default: detail = "Some of the pack is warmer than the rest. Normal straight after rapid charging or hard driving; worth a second look if it persists when the car has rested."
            }
            checks.append(Check(
                title: "Temperature spread", status: status, value: String(format: "%.0f °C", spread), detail: detail
            ))
        }
        if let cycles = equivalentCycles {
            let status: Status = cycles < 1000 ? .good : .fair
            checks.append(Check(
                title: "Use since new", status: status, value: String(format: "%.0f full cycles", cycles),
                detail: "Energy charged since new divided by the pack's size. E-GMP cells are designed for well over 1,000 cycles."
            ))
        }
        self.checks = checks

        if let soh = report.sohPercent {
            let grades = ["A", "B", "C", "D"]
            var step = soh >= 95 ? 0 : soh >= 90 ? 1 : soh >= 80 ? 2 : 3
            // The other checks can take off one step at most: any attention, or a fair one on an A.
            let worst = checks.dropFirst().map(\.status).filter { $0 != .unknown }.max() ?? .good
            if worst == .attention || (worst == .fair && step == 0) { step += 1 }
            grade = grades[min(step, grades.count - 1)]
        } else {
            grade = "–"
        }
    }

    static func healthCheck(_ soh: Double?) -> Check {
        guard let soh else {
            return Check(title: "State of health", status: .unknown, value: "Not reported", detail: "The battery didn't report its state of health.")
        }
        let status: Status = soh >= 90 ? .good : soh >= 80 ? .fair : .attention
        let detail: String
        switch status {
        case .good: detail = "Excellent. The battery reports little or no loss of capacity."
        case .fair: detail = "Normal ageing for a car with some years and miles behind it."
        default: detail = "Below the usual range. Battery warranties typically cover 70% for 8 years; a dealer can run the official test."
        }
        return Check(title: "State of health", status: status, value: String(format: "%.1f%%", soh), detail: detail)
    }

    static func balanceCheck(_ spread: Double?) -> Check {
        guard let spread else {
            return Check(title: "Cell balance", status: .unknown, value: "Not read", detail: "The cell voltages weren't read.")
        }
        // Readings come in 20 mV steps: two steps apart is still closely matched. Rounded first, as the
        // report's findings are, so a 40 mV spread that comes out as 40.00000000004 is still balanced.
        let s = spread.rounded()
        let status: Status = s <= 2 * cellResolutionMV ? .good : s <= 5 * cellResolutionMV ? .fair : .attention
        let detail: String
        switch status {
        case .good: detail = "Cells are closely matched (they're read in 20 mV steps)."
        case .fair: detail = "A little apart. Charging to 100% now and then gives the battery time to balance them."
        default: detail = "Wider than usual. Balance after a full charge and read again; if it stays wide, have it checked."
        }
        return Check(title: "Cell balance", status: status, value: String(format: "%.0f mV spread", spread), detail: detail)
    }
}
