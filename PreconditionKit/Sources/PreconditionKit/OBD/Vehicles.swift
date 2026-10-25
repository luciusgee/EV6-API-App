import Foundation

/// How a car is read.
public enum Platform: String, Codable, Sendable {
    /// Hyundai Motor Group's 800 V Electric Global Modular Platform: deep battery, cell and body data.
    case egmp
    /// Standard OBD-II only: speed, engine and trouble codes on almost any car.
    case generic

    public var sensors: [Sensor] {
        switch self {
        case .egmp: return EGMPSensors.all
        case .generic: return GenericSensors.all
        }
    }

    public func sensor(_ id: String) -> Sensor? { sensors.first { $0.id == id } }

    /// Battery reports, cells and module scans need the car's own data.
    public var hasBatteryData: Bool { self == .egmp }
}

/// A battery pack a model was sold with.
public struct PackSpec: Codable, Hashable, Sendable, Identifiable {
    /// Gross capacity when new.
    public var kWh: Double
    /// Cells in series, as the BMS reports them.
    public var cells: Int
    public var id: Double { kWh }

    public init(_ kWh: Double, cells: Int) {
        self.kWh = kWh
        self.cells = cells
    }

    public var label: String {
        kWh == kWh.rounded() ? "\(Int(kWh)) kWh" : String(format: "%.1f kWh", kWh)
    }
}

public struct VehicleModel: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var make: String
    public var name: String
    public var platform: Platform
    /// Newest last.
    public var packs: [PackSpec]

    public var fullName: String { make.isEmpty ? name : "\(make) \(name)" }

    /// The pack with this many cells; with more than one, the newest unless the year says otherwise.
    public func pack(cells: Int, year: Int? = nil) -> PackSpec? {
        let matches = packs.filter { $0.cells == cells }
        guard matches.count > 1, let year else { return matches.last }
        // E-GMP cars moved from 77.4 to 84 kWh (and 58 to 63) with the 2024–25 updates.
        return year >= 2025 ? matches.last : matches.first
    }
}

/// The cars the app knows.
public enum Vehicles {
    static func egmp(_ id: String, _ make: String, _ name: String, _ packs: [PackSpec]) -> VehicleModel {
        VehicleModel(id: id, make: make, name: name, platform: .egmp, packs: packs)
    }

    public static let all: [VehicleModel] = [
        egmp("kia.ev6", "Kia", "EV6", [PackSpec(58, cells: 144), PackSpec(63, cells: 144), PackSpec(77.4, cells: 192), PackSpec(84, cells: 192)]),
        egmp("kia.ev6gt", "Kia", "EV6 GT", [PackSpec(77.4, cells: 192), PackSpec(84, cells: 192)]),
        egmp("kia.ev9", "Kia", "EV9", [PackSpec(76.1, cells: 160), PackSpec(99.8, cells: 192)]),
        egmp("hyundai.ioniq5", "Hyundai", "Ioniq 5", [PackSpec(58, cells: 144), PackSpec(63, cells: 144), PackSpec(72.6, cells: 180), PackSpec(77.4, cells: 192), PackSpec(84, cells: 192)]),
        egmp("hyundai.ioniq5n", "Hyundai", "Ioniq 5 N", [PackSpec(84, cells: 192)]),
        egmp("hyundai.ioniq6", "Hyundai", "Ioniq 6", [PackSpec(53, cells: 144), PackSpec(63, cells: 144), PackSpec(77.4, cells: 192), PackSpec(84, cells: 192)]),
        egmp("hyundai.ioniq9", "Hyundai", "Ioniq 9", [PackSpec(110.3, cells: 192)]),
        egmp("genesis.gv60", "Genesis", "GV60", [PackSpec(77.4, cells: 192), PackSpec(84, cells: 192)]),
        egmp("genesis.gv70e", "Genesis", "Electrified GV70", [PackSpec(77.4, cells: 192), PackSpec(84, cells: 192)]),
        generic,
    ]

    public static let generic = VehicleModel(id: "generic", make: "", name: "Any other car", platform: .generic, packs: [])

    public static func model(_ id: String) -> VehicleModel? { all.first { $0.id == id } }

    public static func models(make: String) -> [VehicleModel] { all.filter { $0.make == make } }

    /// The best guess from what the car said: its VIN, whether its battery answered like E-GMP, and how many
    /// cells it has.
    public static func guess(vin: VIN?, egmp: Bool, cells: Int?) -> VehicleModel {
        guard egmp else { return generic }
        let candidates = all.filter { $0.platform == .egmp && (vin?.make == nil || $0.make == vin?.make) }
        if let cells, let match = candidates.first(where: { m in m.packs.contains { $0.cells == cells } }) {
            return match
        }
        return candidates.first ?? all[0]
    }
}

/// What a vehicle identification number says without looking anything up: the maker and model year.
public struct VIN: Equatable, Sendable {
    public var text: String
    public var make: String?
    public var year: Int?

    /// World manufacturer identifiers (the first three characters).
    static let makers: [String: String] = [
        "KNA": "Kia", "KNC": "Kia", "KND": "Kia", "KNE": "Kia", "U5Y": "Kia", "U6Y": "Kia", "5XX": "Kia", "5XY": "Kia",
        "KMH": "Hyundai", "KM8": "Hyundai", "KMF": "Hyundai", "5NM": "Hyundai", "5NP": "Hyundai", "5NT": "Hyundai",
        "TMA": "Hyundai", "NLH": "Hyundai", "MAL": "Hyundai", "7YA": "Hyundai",
        "KMT": "Genesis", "KMU": "Genesis",
        "WVW": "Volkswagen", "WV1": "Volkswagen", "WV2": "Volkswagen", "WAU": "Audi", "WBA": "BMW", "WBY": "BMW",
        "WDD": "Mercedes-Benz", "W1K": "Mercedes-Benz", "W1N": "Mercedes-Benz", "TMB": "Škoda", "VSS": "SEAT",
        "SJN": "Nissan", "JN1": "Nissan", "VF1": "Renault", "VF3": "Peugeot", "VR3": "Peugeot", "W0L": "Vauxhall/Opel",
        "SAJ": "Jaguar", "SAL": "Land Rover", "YV1": "Volvo", "LRW": "Tesla", "5YJ": "Tesla", "7SA": "Tesla", "XP7": "Tesla",
        "JTD": "Toyota", "JTM": "Toyota", "SB1": "Toyota", "JHM": "Honda", "SHH": "Honda", "WF0": "Ford", "1FA": "Ford",
        "LSJ": "MG", "SDP": "MG", "LGX": "BYD", "LPS": "Polestar", "ZFA": "Fiat", "JMZ": "Mazda", "JS2": "Suzuki",
    ]

    public init?(_ raw: String) {
        let t = raw.uppercased().filter { $0.isLetter || $0.isNumber }
        guard t.count == 17, !t.contains("I"), !t.contains("O"), !t.contains("Q") else { return nil }
        text = t
        make = Self.makers[String(t.prefix(3))]
        year = Self.year(t[t.index(t.startIndex, offsetBy: 9)])
    }

    /// The 10th character, read for 2010–2039.
    static func year(_ c: Character) -> Int? {
        let letters = Array("ABCDEFGHJKLMNPRSTVWXY")
        if let i = letters.firstIndex(of: c) { return 2010 + i }
        if let d = c.wholeNumberValue, d > 0 { return 2030 + d }
        return nil
    }
}
