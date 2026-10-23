import Foundation
import Observation

/// The E-GMP cars the scanner knows. They share the battery system and its OBD data.
enum CarKind: String, CaseIterable, Identifiable {
    case ev6, ev6GT, ioniq5, ioniq5N, ioniq6, gv60

    var id: String { rawValue }

    var name: String {
        switch self {
        case .ev6: return "Kia EV6"
        case .ev6GT: return "Kia EV6 GT"
        case .ioniq5: return "Hyundai Ioniq 5"
        case .ioniq5N: return "Hyundai Ioniq 5 N"
        case .ioniq6: return "Hyundai Ioniq 6"
        case .gv60: return "Genesis GV60"
        }
    }

    /// Short, for headers.
    var shortName: String {
        switch self {
        case .ev6: return "EV6"
        case .ev6GT: return "EV6 GT"
        case .ioniq5: return "IONIQ 5"
        case .ioniq5N: return "IONIQ 5 N"
        case .ioniq6: return "IONIQ 6"
        case .gv60: return "GV60"
        }
    }
}

/// Settings kept on the phone.
@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    var useMiles: Bool { didSet { defaults.set(useMiles, forKey: "useMiles") } }
    var car: CarKind { didSet { defaults.set(car.rawValue, forKey: "carKind") } }
    var paint: CarPaint { didSet { defaults.set(paint.rawValue, forKey: CarPaint.storageKey) } }

    private init() {
        // Miles in the UK and US unless chosen otherwise.
        let region = Locale.current.region?.identifier ?? ""
        useMiles = defaults.object(forKey: "useMiles") as? Bool ?? ["GB", "US"].contains(region)
        car = defaults.string(forKey: "carKind").flatMap(CarKind.init) ?? .ev6
        paint = defaults.string(forKey: CarPaint.storageKey).flatMap(CarPaint.init) ?? .runwayRed
    }
}
