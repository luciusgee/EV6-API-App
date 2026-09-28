import Foundation

/// Rules and places, as the engine and the Rules screens see them.
public protocol RulesStore: Sendable {
    func rules() async -> [Rule]
    func places() async -> [Place]
    /// Called when Kia says the car can't do what the rule asks (4005).
    func disableRule(id: String, reason: String) async
}

/// Where the phone is, for "phone near the car". The app wraps `CLLocationManager.requestLocation()`.
public protocol PhoneLocator: Sendable {
    /// Nil without permission or a fix.
    func locate() async -> LatLon?
}

/// A BLE thermometer in the cabin. Not built yet, so the app passes `NoCabinSensor`.
public protocol CabinSensor: Sendable {
    func read() async -> TempReading?
}

public struct NoPhoneLocator: PhoneLocator {
    public init() {}
    public func locate() async -> LatLon? { nil }
}

public struct NoCabinSensor: CabinSensor {
    public init() {}
    public func read() async -> TempReading? { nil }
}

/// Weather that's never available, for tests and setups without it.
public struct NoWeather: WeatherSource {
    public init() {}
    public func current(at: LatLon) async -> TempReading? { nil }
    public func forecast(at: LatLon, time: Date) async -> TempReading? { nil }
}

public actor InMemoryRulesStore: RulesStore {
    public private(set) var ruleList: [Rule]
    public private(set) var placeList: [Place]
    public private(set) var disabled: [String: String] = [:]

    public init(rules: [Rule] = [], places: [Place] = []) {
        ruleList = rules
        placeList = places
    }

    public func rules() -> [Rule] { ruleList }
    public func places() -> [Place] { placeList }
    public func set(rules: [Rule]) { ruleList = rules }
    public func set(places: [Place]) { placeList = places }

    public func disableRule(id: String, reason: String) {
        disabled[id] = reason
        ruleList = ruleList.map { var r = $0; if r.id == id { r.enabled = false }; return r }
    }
}

/// Rules and places in one JSON file, in the same format as the backups.
public struct FileRulesStore: RulesStore {
    let file: JSONFileStore<RuleBundle>

    public init(url: URL) {
        file = JSONFileStore(url: url, default: RuleBundle())
    }

    public func rules() async -> [Rule] { await file.load().rules }
    public func places() async -> [Place] { await file.load().places }
    public func bundle() async -> RuleBundle { await file.load() }

    public func disableRule(id: String, reason: String) async {
        await file.update { b in
            if let i = b.rules.firstIndex(where: { $0.id == id }) { b.rules[i].enabled = false }
        }
    }

    /// Adds the rule, or replaces the one with the same id.
    public func save(_ rule: Rule) async {
        await file.update { b in
            if let i = b.rules.firstIndex(where: { $0.id == rule.id }) { b.rules[i] = rule } else { b.rules.append(rule) }
        }
    }

    public func deleteRule(id: String) async {
        await file.update { $0.rules.removeAll { $0.id == id } }
    }

    public func save(_ place: Place) async {
        await file.update { b in
            if let i = b.places.firstIndex(where: { $0.id == place.id }) { b.places[i] = place } else { b.places.append(place) }
        }
    }

    /// Refuses (returns the rule names) while rules still use the place.
    @discardableResult
    public func deletePlace(id: String) async -> [String] {
        let users = await file.load().rules.filter { r in
            r.trigger.placeId == id || r.conditions.contains { if case .carAtPlace(id) = $0 { return true } else { return false } }
        }.map(\.name)
        if users.isEmpty { await file.update { $0.places.removeAll { $0.id == id } } }
        return users
    }

    /// Merges an import: imported places and rules replace those with the same id; the rest stay.
    public func merge(_ result: ImportResult) async {
        await file.update { b in
            for p in result.places {
                if let i = b.places.firstIndex(where: { $0.id == p.id }) { b.places[i] = p } else { b.places.append(p) }
            }
            for r in result.rules {
                if let i = b.rules.firstIndex(where: { $0.id == r.id }) { b.rules[i] = r } else { b.rules.append(r) }
            }
        }
    }
}
