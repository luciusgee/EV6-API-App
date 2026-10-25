import Foundation
import Observation
import PreconditionKit

/// Settings kept on the phone.
@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    var useMiles: Bool { didSet { defaults.set(useMiles, forKey: "useMiles") } }
    /// The car, from `Vehicles.all`.
    var modelId: String { didSet { defaults.set(modelId, forKey: "vehicleModel") } }
    /// The battery's size, when chosen; otherwise worked out from the cell count.
    var packKWh: Double? { didSet { defaults.set(packKWh, forKey: "packKWh") } }
    /// Pick the car from what it reports when connecting.
    var autoDetect: Bool { didSet { defaults.set(autoDetect, forKey: "autoDetect") } }
    /// The last VIN the car reported.
    var vin: String? { didSet { defaults.set(vin, forKey: "vin") } }
    var onboarded: Bool { didSet { defaults.set(onboarded, forKey: "onboarded") } }
    /// Agreed to the performance timer's safety note.
    var acceptedTrackUse: Bool { didSet { defaults.set(acceptedTrackUse, forKey: "acceptedTrackUse") } }

    private init() {
        // Miles in the UK and US unless chosen otherwise.
        let region = Locale.current.region?.identifier ?? ""
        useMiles = defaults.object(forKey: "useMiles") as? Bool ?? ["GB", "US"].contains(region)
        modelId = defaults.string(forKey: "vehicleModel") ?? "kia.ev6"
        packKWh = defaults.object(forKey: "packKWh") as? Double
        autoDetect = defaults.object(forKey: "autoDetect") as? Bool ?? true
        vin = defaults.string(forKey: "vin")
        onboarded = defaults.bool(forKey: "onboarded")
        acceptedTrackUse = defaults.bool(forKey: "acceptedTrackUse")
    }

    var model: VehicleModel { Vehicles.model(modelId) ?? Vehicles.all[0] }
    var platform: Platform { model.platform }

    /// The pack: the one chosen, else the one matching the cells read and the VIN's year. With no year,
    /// the smaller (older, more common) pack, so the report doesn't claim capacity the car may not have.
    func pack(cells: Int?) -> PackSpec? {
        if let packKWh, let chosen = model.packs.first(where: { $0.kWh == packKWh }) { return chosen }
        guard let cells else { return nil }
        if let year = vin.flatMap(VIN.init)?.year { return model.pack(cells: cells, year: year) }
        return model.packs.first { $0.cells == cells }
    }
}
