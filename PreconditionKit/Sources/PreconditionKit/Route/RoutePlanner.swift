import Foundation

/// A charger somewhere near the route, placed by how far along the route it is.
public struct RouteCharger: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var position: LatLon
    /// From the start, along the route, to the point where you'd leave it.
    public var alongKm: Double
    /// Extra driving to reach it and get back on the route.
    public var detourKm: Double
    /// Best guess at its top speed (Apple Maps doesn't say; see `ChargerPower`).
    public var powerKW: Double
    /// True when `powerKW` is a guess from the name rather than known.
    public var powerGuessed: Bool

    public init(id: String, name: String, position: LatLon, alongKm: Double, detourKm: Double, powerKW: Double, powerGuessed: Bool = true) {
        self.id = id
        self.name = name
        self.position = position
        self.alongKm = alongKm
        self.detourKm = detourKm
        self.powerKW = powerKW
        self.powerGuessed = powerGuessed
    }
}

public extension RouteCharger {
    /// A known site placed on the route: real speed, not a guess.
    init(site: ChargeSite, alongKm: Double, detourKm: Double) {
        let who = site.operatorName.map { $0 + " · " } ?? ""
        self.init(id: site.id, name: who + site.name, position: site.position, alongKm: alongKm, detourKm: detourKm,
                  powerKW: site.maxKW ?? 50, powerGuessed: site.maxKW == nil)
    }
}

/// Guesses a charger's speed from the operator in its name: UK rapid networks are 150 kW or more.
public enum ChargerPower {
    static let ultraRapid = ["ionity", "gridserve", "electric highway", "instavolt", "osprey", "fastned", "tesla", "supercharger",
                             "bp pulse", "shell recharge", "mfg ev power", "mfg", "be.ev", "evyve", "applegreen", "ez-charge",
                             "moto", "welcome break", "roadchef", "allego", "ubitricity hub", "believ rapid", "sainsbury", "tesco ev"]
    static let slow = ["hotel", "destination", "council", "car park", "retail park", "pod point", "source london", "char.gy",
                       "connected kerb", "ubitricity", "lamp", "village hall", "church", "school"]

    public static func guess(name: String) -> Double {
        let n = name.lowercased()
        if slow.contains(where: { n.contains($0) }) && !n.contains("rapid") { return 22 }
        if ultraRapid.contains(where: { n.contains($0) }) || n.contains("hub") || n.contains("ultra") { return 150 }
        if n.contains("rapid") { return 50 }
        return 50
    }
}

/// The EV6 77.4 kWh (800 V) fast-charging curve: kW it can take at each state of charge, from
/// published tests (about 18 minutes 10→80% on a 350 kW charger).
public enum EV6ChargeCurve {
    /// (SoC %, kW) points, straight lines between.
    static let points: [(Double, Double)] = [
        (0, 180), (10, 225), (30, 235), (50, 230), (60, 200), (70, 180), (75, 150), (80, 100), (85, 70), (90, 45), (95, 25), (100, 10),
    ]

    public static func kW(at soc: Double) -> Double {
        let s = min(max(soc, 0), 100)
        for i in 1..<points.count where s <= points[i].0 {
            let (s0, p0) = points[i - 1]
            let (s1, p1) = points[i]
            return p0 + (p1 - p0) * (s - s0) / (s1 - s0)
        }
        return points.last!.1
    }

    /// Minutes to go from `from`% to `to`% on a charger of `chargerKW`.
    public static func minutes(from: Double, to: Double, chargerKW: Double, usableKWh: Double) -> Double {
        guard to > from, chargerKW > 0 else { return 0 }
        var t = 0.0
        var s = from
        let step = 0.5
        while s < to - 0.0001 {
            let ds = min(step, to - s)
            // Real chargers deliver a little less than their rating.
            let kw = min(kW(at: s + ds / 2), chargerKW * 0.92)
            t += (ds / 100 * usableKWh) / kw * 60
            s += ds
        }
        return t
    }
}

/// How much energy the drive takes.
public struct ConsumptionModel: Codable, Equatable, Sendable {
    /// Your usual use, kWh per 100 km, e.g. from Kia's driving history.
    public var baseKWhPer100km: Double
    /// Average speed of the route, km/h (motorways use more).
    public var averageKmh: Double
    /// Outside temperature at departure (the cold uses more: heating, a cold battery).
    public var outsideC: Double?
    /// Extra margin for wind, hills, passengers, luggage.
    public var marginPercent: Double

    public init(baseKWhPer100km: Double = 18.5, averageKmh: Double = 80, outsideC: Double? = nil, marginPercent: Double = 5) {
        self.baseKWhPer100km = baseKWhPer100km
        self.averageKmh = averageKmh
        self.outsideC = outsideC
        self.marginPercent = marginPercent
    }

    /// Everyday driving is mixed; above about 70 km/h average, each extra 10 km/h costs about 6%.
    public var speedFactor: Double { 1 + max(0, averageKmh - 70) / 10 * 0.06 }

    public var temperatureFactor: Double {
        guard let t = outsideC else { return 1 }
        if t >= 15 { return 1 }
        if t >= 5 { return 1.08 }
        if t >= 0 { return 1.15 }
        return 1.25
    }

    public var kWhPer100km: Double { baseKWhPer100km * speedFactor * temperatureFactor * (1 + marginPercent / 100) }
}

public struct TripSettings: Codable, Equatable, Sendable {
    public var startPercent: Double
    /// Never plan to arrive anywhere below this.
    public var minArrivalPercent: Double
    /// Arrive at the destination with at least this.
    public var destinationPercent: Double
    /// Charge no higher than this at a stop (past 80% the EV6 slows right down).
    public var maxChargePercent: Double
    public var usableKWh: Double

    public init(startPercent: Double = 90, minArrivalPercent: Double = 10, destinationPercent: Double = 15, maxChargePercent: Double = 80, usableKWh: Double = 74) {
        self.startPercent = startPercent
        self.minArrivalPercent = minArrivalPercent
        self.destinationPercent = destinationPercent
        self.maxChargePercent = maxChargePercent
        self.usableKWh = usableKWh
    }
}

public struct TripStop: Equatable, Sendable, Identifiable {
    public var charger: RouteCharger
    public var arrivePercent: Double
    public var departPercent: Double
    public var chargeMinutes: Double
    public var id: String { charger.id }
}

public struct TripPlan: Equatable, Sendable {
    public var distanceKm: Double
    public var driveMinutes: Double
    public var stops: [TripStop]
    public var arrivePercent: Double
    public var kWhPer100km: Double
    /// True when the car can't make it with the chargers found.
    public var unreachable: Bool
    /// The charge to leave with to make it without stopping, when that's possible (≤ 100%).
    public var noStopStartPercent: Double?

    public var chargeMinutes: Double { stops.map(\.chargeMinutes).reduce(0, +) }
    /// Driving, charging, and 5 minutes to plug in and out at each stop.
    public var totalMinutes: Double { driveMinutes + chargeMinutes + Double(stops.count) * 5 }
}

public enum RoutePlanner {
    /// Percent of battery used driving `km`.
    static func percent(for km: Double, model: ConsumptionModel, usableKWh: Double) -> Double {
        km * model.kWhPer100km / 100 / usableKWh * 100
    }

    /// Plans charging stops: from each point, drive to the farthest reachable fast charger, charge only
    /// what's needed for the next leg (up to `maxChargePercent`), and repeat. Faster chargers win when
    /// they're nearly as far along.
    public static func plan(
        distanceKm: Double,
        driveMinutes: Double,
        chargers: [RouteCharger],
        trip: TripSettings,
        model: ConsumptionModel,
        prefer: Set<String> = []
    ) -> TripPlan {
        let per = { (km: Double) in percent(for: km, model: model, usableKWh: trip.usableKWh) }
        let candidates = chargers.filter { $0.alongKm > 1 && $0.alongKm < distanceKm - 1 && $0.powerKW >= 40 }
            .sorted { $0.alongKm < $1.alongKm }
        let neededAll = per(distanceKm) + trip.destinationPercent
        let noStop = neededAll <= 100 ? neededAll : nil

        var stops: [TripStop] = []
        var at = 0.0
        var soc = trip.startPercent
        var detourSoFar = 0.0
        var unreachable = false

        while true {
            // Can we finish from here?
            if soc - per(distanceKm - at) >= trip.destinationPercent - 0.01 { break }
            // Chargers ahead we can reach.
            let reachable = candidates.filter { c in
                c.alongKm > at + 0.5 && soc - per(c.alongKm - at + c.detourKm / 2) >= trip.minArrivalPercent
            }
            guard let farthest = reachable.map(\.alongKm).max() else {
                unreachable = true
                break
            }
            // A charger you chose, if one's in reach; else, among those within 25 km of the farthest,
            // the fastest, then the farthest.
            let chosen = reachable.filter { prefer.contains($0.id) }.max { $0.alongKm < $1.alongKm }
            let pick = chosen ?? reachable.filter { $0.alongKm >= farthest - 25 }
                .max { a, b in a.powerKW == b.powerKW ? a.alongKm < b.alongKm : a.powerKW < b.powerKW }!
            let arrive = soc - per(pick.alongKm - at + pick.detourKm / 2)
            // Enough to finish, else to reach the farthest charger further on, capped.
            // Half a percent spare so the finish check never misses by rounding.
            let toFinish = per(distanceKm - pick.alongKm + pick.detourKm / 2) + trip.destinationPercent + 0.5
            let depart = min(trip.maxChargePercent, max(arrive, toFinish))
            let target = depart <= arrive + 1 ? min(trip.maxChargePercent, arrive + 10) : depart
            let minutes = EV6ChargeCurve.minutes(from: arrive, to: target, chargerKW: pick.powerKW, usableKWh: trip.usableKWh)
            stops.append(TripStop(charger: pick, arrivePercent: arrive, departPercent: target, chargeMinutes: minutes))
            detourSoFar += pick.detourKm
            soc = target - per(pick.detourKm / 2)
            at = pick.alongKm
            if stops.count > 12 {
                unreachable = true
                break
            }
        }
        let finalArrive = soc - per(distanceKm - at)
        let detourMinutes = detourSoFar / max(model.averageKmh * 0.6, 20) * 60
        return TripPlan(
            distanceKm: distanceKm + detourSoFar,
            driveMinutes: driveMinutes + detourMinutes,
            stops: stops,
            arrivePercent: finalArrive,
            kWhPer100km: model.kWhPer100km,
            unreachable: unreachable,
            noStopStartPercent: noStop
        )
    }
}
