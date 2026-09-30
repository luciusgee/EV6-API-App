import Foundation

/// One charge, worked out from the car's reported charge before and after.
public struct ChargeSession: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var start: Date
    public var end: Date
    public var startPercent: Int
    public var endPercent: Int
    /// Into the battery.
    public var batteryKWh: Double
    /// Paid for: from the wall at home (with losses), or at the charger when away.
    public var paidKWh: Double
    public var costPence: Double
    public var atHome: Bool
    /// Entered by hand (a public charge, say) rather than seen.
    public var manual: Bool
    public var note: String?

    public init(id: String = UUID().uuidString, start: Date, end: Date, startPercent: Int, endPercent: Int,
                batteryKWh: Double, paidKWh: Double, costPence: Double, atHome: Bool, manual: Bool = false, note: String? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.startPercent = startPercent
        self.endPercent = endPercent
        self.batteryKWh = batteryKWh
        self.paidKWh = paidKWh
        self.costPence = costPence
        self.atHome = atHome
        self.manual = manual
        self.note = note
    }

    public var addedPercent: Int { endPercent - startPercent }
    public var pencePerKWh: Double { paidKWh > 0 ? costPence / paidKWh : 0 }
}

/// What the ledger remembers between readings.
public struct ChargingData: Codable, Equatable, Sendable {
    public struct Reading: Codable, Equatable, Sendable {
        public var at: Date
        public var soc: Int
        public var pluggedIn: Bool
        public var charging: Bool
        public var powerKW: Double?
        public var position: LatLon?
    }

    public var sessions: [ChargeSession] = []
    /// The last reading of the car's charge.
    public var last: Reading?
    /// A charge in progress: where it started.
    public var open: Reading?
    /// The first odometer reading seen, for cost per mile.
    public var firstOdometerKm: Double?
    public var latestOdometerKm: Double?
    /// How home charges were costed: 2 puts them in the cheapest hours between readings.
    public var costing: Int = ChargingData.currentCosting
    public static let currentCosting = 2

    public init() {}

    enum CodingKeys: String, CodingKey { case sessions, last, open, firstOdometerKm, latestOdometerKm, costing }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try c.decodeIfPresent([ChargeSession].self, forKey: .sessions) ?? []
        last = try c.decodeIfPresent(Reading.self, forKey: .last)
        open = try c.decodeIfPresent(Reading.self, forKey: .open)
        firstOdometerKm = try c.decodeIfPresent(Double.self, forKey: .firstOdometerKm)
        latestOdometerKm = try c.decodeIfPresent(Double.self, forKey: .latestOdometerKm)
        // Saved before costing was recorded: the old, time-averaged way.
        costing = try c.decodeIfPresent(Int.self, forKey: .costing) ?? 1
    }
}

public struct ChargingSettings: Codable, Equatable, Sendable {
    public var tariff: Tariff
    public var postcode: String?
    /// What public charging usually costs you.
    public var publicPencePerKWh: Double
    /// Wall energy per battery energy on a home AC charger.
    public var homeLossFactor: Double
    public var usableKWh: Double
    /// For the "vs petrol" comparison.
    public var petrolMPG: Double
    public var petrolPencePerLitre: Double
    public var smart: SmartChargeSettings
    public var alerts: AlertSettings

    public init(
        tariff: Tariff = .default, postcode: String? = nil, publicPencePerKWh: Double = 79, homeLossFactor: Double = 1.1,
        usableKWh: Double = 74, petrolMPG: Double = 45, petrolPencePerLitre: Double = 140,
        smart: SmartChargeSettings = SmartChargeSettings(), alerts: AlertSettings = AlertSettings()
    ) {
        self.tariff = tariff
        self.postcode = postcode
        self.publicPencePerKWh = publicPencePerKWh
        self.homeLossFactor = homeLossFactor
        self.usableKWh = usableKWh
        self.petrolMPG = petrolMPG
        self.petrolPencePerLitre = petrolPencePerLitre
        self.smart = smart
        self.alerts = alerts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ChargingSettings()
        tariff = try c.decodeIfPresent(Tariff.self, forKey: .tariff) ?? d.tariff
        postcode = try c.decodeIfPresent(String.self, forKey: .postcode)
        publicPencePerKWh = try c.decodeIfPresent(Double.self, forKey: .publicPencePerKWh) ?? d.publicPencePerKWh
        homeLossFactor = try c.decodeIfPresent(Double.self, forKey: .homeLossFactor) ?? d.homeLossFactor
        usableKWh = try c.decodeIfPresent(Double.self, forKey: .usableKWh) ?? d.usableKWh
        petrolMPG = try c.decodeIfPresent(Double.self, forKey: .petrolMPG) ?? d.petrolMPG
        petrolPencePerLitre = try c.decodeIfPresent(Double.self, forKey: .petrolPencePerLitre) ?? d.petrolPencePerLitre
        smart = try c.decodeIfPresent(SmartChargeSettings.self, forKey: .smart) ?? d.smart
        alerts = try c.decodeIfPresent(AlertSettings.self, forKey: .alerts) ?? d.alerts
    }

    /// Pence per mile in a petrol car at these prices.
    public var petrolPencePerMile: Double {
        guard petrolMPG > 0 else { return 0 }
        return petrolPencePerLitre / (petrolMPG / 4.54609)
    }
}

/// Spots charges from the car's reported state: the charge going up between readings. Kia only
/// reports when asked, so a charge is often seen as "was 40%, now 80%"; that's enough to cost it.
public enum ChargeLedger {
    /// Charges smaller than this are noise (rounding, a warm battery).
    static let minimumPercent = 2
    /// How close to home counts as home.
    static let homeRadiusM = 300.0

    /// Feeds one snapshot in; returns a charge that has just finished, if any.
    @discardableResult
    public static func ingest(
        _ data: inout ChargingData,
        snapshot s: VehicleSnapshot,
        settings: ChargingSettings,
        home: LatLon?,
        agileSlots: [PriceSlot] = [],
        calendar: Calendar = .current
    ) -> ChargeSession? {
        if let odo = s.details?.odometerKm, odo > 0 {
            if data.firstOdometerKm == nil { data.firstOdometerKm = odo }
            data.latestOdometerKm = odo
        }
        guard let soc = s.socPercent else { return nil }
        let reading = ChargingData.Reading(
            at: s.carCapturedAt ?? s.fetchedAt,
            soc: soc,
            pluggedIn: s.pluggedIn == true,
            charging: s.chargingState == .charging,
            powerKW: s.chargePowerKw,
            position: s.parkingPosition
        )
        guard let last = data.last else {
            data.last = reading
            if reading.charging { data.open = reading }
            return nil
        }
        // The car hasn't reported since last time.
        guard reading.at > last.at else { return nil }
        data.last = reading
        // A charge that has just been seen running started at the last reading if it was already
        // plugged in then and has gained since.
        defer {
            if data.open == nil && reading.charging {
                data.open = last.pluggedIn && last.soc < reading.soc ? last : reading
            }
        }

        if let open = data.open {
            // Still going.
            if reading.charging { return nil }
            data.open = nil
            return close(&data, from: open, to: reading, settings: settings, home: home, agileSlots: agileSlots, calendar: calendar)
        }
        // Charged while nobody was looking.
        if reading.soc - last.soc >= minimumPercent && !reading.charging {
            return close(&data, from: last, to: reading, settings: settings, home: home, agileSlots: agileSlots, calendar: calendar)
        }
        return nil
    }

    static func homeCost(paidKWh: Double, from: Date, to: Date, settings: ChargingSettings, agileSlots: [PriceSlot], calendar: Calendar) -> Double {
        // A "7 kW" wallbox is 32 A, which draws about 7.4 kW from the wall.
        let kW = settings.smart.chargerKW == 7 ? 7.4 : settings.smart.chargerKW
        return settings.tariff.chargeCost(kWh: paidKWh, powerKW: kW, from: from, to: to, agileSlots: agileSlots, calendar: calendar)
    }

    /// Prices home charges seen before costing used the cheapest hours again, with the tariff they
    /// were seen under being the current one (it's the only one known). Runs once.
    public static func recostOldHomeCharges(_ data: inout ChargingData, settings: ChargingSettings, agileSlots: [PriceSlot], calendar: Calendar = .current) {
        guard data.costing < ChargingData.currentCosting else { return }
        data.costing = ChargingData.currentCosting
        for i in data.sessions.indices where data.sessions[i].atHome && !data.sessions[i].manual {
            let s = data.sessions[i]
            data.sessions[i].costPence = homeCost(paidKWh: s.paidKWh, from: s.start, to: s.end, settings: settings,
                                                  agileSlots: agileSlots, calendar: calendar).rounded()
        }
    }

    private static func close(
        _ data: inout ChargingData, from: ChargingData.Reading, to: ChargingData.Reading,
        settings: ChargingSettings, home: LatLon?, agileSlots: [PriceSlot], calendar: Calendar
    ) -> ChargeSession? {
        guard to.soc - from.soc >= minimumPercent else { return nil }
        let position = to.position ?? from.position
        let atHome: Bool
        if let home, let position {
            atHome = position.distance(to: home) <= homeRadiusM
        } else {
            // No home set: a home wallbox is AC, 11 kW at most.
            atHome = (from.powerKW ?? to.powerKW ?? 7) <= 11.5
        }
        let battery = Double(to.soc - from.soc) / 100 * settings.usableKWh
        let paid = atHome ? battery * settings.homeLossFactor : battery
        let pence = atHome
            ? homeCost(paidKWh: paid, from: from.at, to: to.at, settings: settings, agileSlots: agileSlots, calendar: calendar)
            : paid * settings.publicPencePerKWh
        let session = ChargeSession(
            id: ISO8601DateFormatter().string(from: from.at),
            start: from.at, end: to.at, startPercent: from.soc, endPercent: to.soc,
            batteryKWh: battery, paidKWh: paid, costPence: pence.rounded(), atHome: atHome
        )
        data.sessions.append(session)
        data.sessions.sort { $0.start > $1.start }
        if data.sessions.count > 1000 { data.sessions.removeLast(data.sessions.count - 1000) }
        return session
    }
}

/// Totals for a period.
public struct ChargingTotals: Equatable, Sendable {
    public var sessions: Int
    public var batteryKWh: Double
    public var paidKWh: Double
    public var costPence: Double
    public var homeCostPence: Double
    public var publicCostPence: Double

    public static func of(_ sessions: [ChargeSession]) -> ChargingTotals {
        ChargingTotals(
            sessions: sessions.count,
            batteryKWh: sessions.map(\.batteryKWh).reduce(0, +),
            paidKWh: sessions.map(\.paidKWh).reduce(0, +),
            costPence: sessions.map(\.costPence).reduce(0, +),
            homeCostPence: sessions.filter(\.atHome).map(\.costPence).reduce(0, +),
            publicCostPence: sessions.filter { !$0.atHome }.map(\.costPence).reduce(0, +)
        )
    }

    /// Per calendar month, newest first.
    public static func byMonth(_ sessions: [ChargeSession], calendar: Calendar = .current) -> [(month: Date, totals: ChargingTotals)] {
        let grouped = Dictionary(grouping: sessions) { s -> Date in
            calendar.date(from: calendar.dateComponents([.year, .month], from: s.start)) ?? s.start
        }
        return grouped.keys.sorted(by: >).map { ($0, of(grouped[$0] ?? [])) }
    }

    /// Cost per mile over everything recorded, and the petrol equivalent.
    public static func perMile(_ data: ChargingData, settings: ChargingSettings) -> (electric: Double, petrol: Double)? {
        guard let first = data.firstOdometerKm, let latest = data.latestOdometerKm else { return nil }
        let miles = (latest - first) / 1.609344
        guard miles >= 20 else { return nil }
        let cost = data.sessions.map(\.costPence).reduce(0, +)
        return (cost / miles, settings.petrolPencePerMile)
    }
}
