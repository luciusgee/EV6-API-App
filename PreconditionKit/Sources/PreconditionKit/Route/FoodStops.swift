import Foundation

/// A chain with something vegan on the menu.
public struct FoodChain: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var name: String
    /// What to get there, e.g. "Plant-based Whopper".
    public var vegan: String
    /// Other ways it's written ("McDonalds", "McDonald's Drive Thru").
    public var aliases: [String]
    public var id: String { name }

    public init(name: String, vegan: String = "", aliases: [String] = []) {
        self.name = name
        self.vegan = vegan
        self.aliases = aliases
    }

    /// The UK chains you'll find at services and retail parks, with their vegan staples.
    public static let ukVegan: [FoodChain] = [
        FoodChain(name: "Burger King", vegan: "Plant-based Whopper, vegan nuggets"),
        FoodChain(name: "LEON", vegan: "Lots marked vegan"),
        FoodChain(name: "McDonald's", vegan: "McPlant, veggie dippers", aliases: ["mcdonalds", "maccies"]),
        FoodChain(name: "Subway", vegan: "Plant patty or veggie sub"),
        FoodChain(name: "Greggs", vegan: "Vegan sausage roll"),
        FoodChain(name: "Pret A Manger", vegan: "Veggie Pret range", aliases: ["pret"]),
        FoodChain(name: "KFC", vegan: "Vegan burger"),
        FoodChain(name: "Wagamama", vegan: "Vegan menu", aliases: ["wagamamas"]),
        FoodChain(name: "Taco Bell", vegan: "Swap to beans"),
        FoodChain(name: "Nando's", vegan: "Plant-based options", aliases: ["nandos"]),
        FoodChain(name: "Pizza Hut", vegan: "Vegan cheese pizzas"),
        FoodChain(name: "Starbucks", vegan: "Plant milks, some food"),
        FoodChain(name: "Costa", vegan: "Plant milks, vegan wraps", aliases: ["costa coffee"]),
        FoodChain(name: "Itsu", vegan: "Vegan bowls and gyoza"),
        FoodChain(name: "M&S Food", vegan: "Plant Kitchen range", aliases: ["m&s simply food", "marks & spencer", "marks and spencer"]),
        FoodChain(name: "Waitrose", vegan: "Vegan meal deals"),
        FoodChain(name: "Tesco", vegan: "Plant Chef, meal deals", aliases: ["tesco express", "tesco extra"]),
        FoodChain(name: "Sainsbury's", vegan: "Plant Pioneers", aliases: ["sainsburys", "sainsbury's local"]),
        FoodChain(name: "Co-op", vegan: "GRO range", aliases: ["coop", "co-operative"]),
    ]

    /// Lowercased, with apostrophes, dots and spacing taken out, so "McDonald’s" matches "mcdonalds".
    static func normalise(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "&" }
    }

    /// Whether a place called `placeName` is this chain.
    public func matches(_ placeName: String) -> Bool {
        let place = Self.normalise(placeName)
        guard !place.isEmpty else { return false }
        return ([name] + aliases).map(Self.normalise).contains { !$0.isEmpty && place.contains($0) }
    }
}

public enum FoodMatch {
    /// The chains among the places, in the order of `chains` (your favourites first).
    public static func chains(at placeNames: [String], from chains: [FoodChain]) -> [FoodChain] {
        chains.filter { chain in placeNames.contains(where: chain.matches) }
    }
}

/// A charger you could stop at for one leg of the trip.
public struct StopOption: Equatable, Identifiable, Sendable {
    public var charger: RouteCharger
    public var arrivePercent: Double
    /// Minutes from setting off to arriving there (driving, and any earlier stops).
    public var minutesIn: Double
    public var id: String { charger.id }
}

public extension RoutePlanner {
    /// Every fast charger you could use instead of stop `index`: reachable from where the previous
    /// stop leaves you, with at least the minimum arrival charge, and before the next leg needs it.
    static func stopOptions(
        for index: Int,
        in plan: TripPlan,
        distanceKm: Double,
        driveMinutes: Double,
        chargers: [RouteCharger],
        trip: TripSettings,
        model: ConsumptionModel
    ) -> [StopOption] {
        guard index < plan.stops.count else { return [] }
        let per = { (km: Double) in percent(for: km, model: model, usableKWh: trip.usableKWh) }
        let minutesPerKm = distanceKm > 0 ? driveMinutes / distanceKm : 1
        var at = 0.0
        var soc = trip.startPercent
        var earlier = 0.0
        if index > 0 {
            let prev = plan.stops[index - 1]
            at = prev.charger.alongKm
            soc = prev.departPercent - per(prev.charger.detourKm / 2)
            earlier = plan.stops[..<index].map { $0.chargeMinutes + 5 }.reduce(0, +)
        }
        return chargers
            .filter { $0.alongKm > at + 0.5 && $0.alongKm < distanceKm - 1 && $0.powerKW >= 40 }
            .compactMap { c -> StopOption? in
                let arrive = soc - per(c.alongKm - at + c.detourKm / 2)
                guard arrive >= trip.minArrivalPercent else { return nil }
                return StopOption(charger: c, arrivePercent: arrive, minutesIn: c.alongKm * minutesPerKm + earlier)
            }
            .sorted { $0.charger.alongKm < $1.charger.alongKm }
    }
}

/// A planned trip kept for later: where to, where to stop, and what's there to eat.
public struct SavedTrip: Codable, Equatable, Identifiable, Sendable {
    public struct Stop: Codable, Equatable, Sendable {
        public var name: String
        public var position: LatLon
        public var kW: Double?
        public var chargeMinutes: Double?
        public var food: [String]

        public init(name: String, position: LatLon, kW: Double? = nil, chargeMinutes: Double? = nil, food: [String] = []) {
            self.name = name
            self.position = position
            self.kW = kW
            self.chargeMinutes = chargeMinutes
            self.food = food
        }
    }

    public var id: UUID
    public var name: String
    public var destination: NavPoint
    public var stops: [Stop]
    public var leaving: Date?
    public var savedAt: Date

    public init(id: UUID = UUID(), name: String, destination: NavPoint, stops: [Stop], leaving: Date? = nil, savedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.destination = destination
        self.stops = stops
        self.leaving = leaving
        self.savedAt = savedAt
    }

    /// For the car's nav: the charging stops, then the destination.
    public var navPoints: [NavPoint] {
        stops.map { NavPoint(name: $0.name, position: $0.position) } + [destination]
    }
}
