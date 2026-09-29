import Foundation

/// A temperature and where it came from ("Open-Meteo at usual spot at Office", "car sensor").
public struct TempReading: Equatable, Sendable {
    public var celsius: Double
    public var source: String
    public var at: Date

    public init(celsius: Double, source: String, at: Date) {
        self.celsius = celsius
        self.source = source
        self.at = at
    }
}

/// Everything the evaluator may need beyond the rule. Implementations fetch lazily and memoise within one
/// evaluation, so asking twice never costs two requests.
public protocol EvaluationInputs: Sendable {
    /// Vehicle state already in hand (fresh cache, or read earlier in this run). Never costs a request.
    func vehicleIfFree() async -> VehicleSnapshot?
    /// Vehicle state, reading Kia if the cache is stale. Nil if unavailable.
    func vehicle() async -> VehicleSnapshot?
    func weatherNow(at: LatLon) async -> TempReading?
    func forecast(at: LatLon, time: Date) async -> TempReading?
    func cabinTemp() async -> TempReading?
    /// The phone's location, or nil without permission or a fix. Costs no Kia request.
    func phoneLocation() async -> LatLon?
}

public struct CooldownState: Equatable, Sendable {
    public var lastAutomatedCommandAt: Date?
    public var lastFiredByRule: [String: Date]

    public init(lastAutomatedCommandAt: Date? = nil, lastFiredByRule: [String: Date] = [:]) {
        self.lastAutomatedCommandAt = lastAutomatedCommandAt
        self.lastFiredByRule = lastFiredByRule
    }
}

extension AutomationState {
    public var cooldowns: CooldownState {
        CooldownState(lastAutomatedCommandAt: lastAutomatedCommandAt, lastFiredByRule: lastFiredByRule)
    }
}

public struct RuleVerdict: Equatable, Sendable {
    public var ruleId: String
    public var ruleName: String
    public var fired: Bool
    /// Why it fired, or the first check that stopped it.
    public var reason: String
    public var checks: [Check]
    /// The last temperature a condition used, for notifications ("left Office, 3.0 °C").
    public var temperature: TempReading?
}

public struct Evaluation: Equatable, Sendable {
    public var event: TriggerEvent
    public var at: Date
    /// Set when nothing was evaluated at all (paused, holiday, no rules for this trigger).
    public var globalSkip: String?
    public var verdicts: [RuleVerdict]
    public var winner: Rule?

    public var winnerVerdict: RuleVerdict? {
        guard let winner else { return nil }
        return verdicts.first { $0.ruleId == winner.id }
    }
}

public struct EvaluationRequest: Sendable {
    public var event: TriggerEvent
    public var now: Date
    /// The time zone for time windows, days and holidays.
    public var clock: LocalClock
    public var rules: [Rule]
    public var places: [String: Place]
    public var guards: GuardSettings
    public var cooldowns: CooldownState
    /// How many Kia requests automation may still make.
    public var automationBudget: @Sendable () async -> Int
    public var inputs: EvaluationInputs
    /// False for "Test now" dry runs, which evaluate a rule whatever its trigger.
    public var requireTriggerMatch: Bool

    public init(
        event: TriggerEvent,
        now: Date,
        clock: LocalClock,
        rules: [Rule],
        places: [String: Place],
        guards: GuardSettings,
        cooldowns: CooldownState,
        automationBudget: @escaping @Sendable () async -> Int,
        inputs: EvaluationInputs,
        requireTriggerMatch: Bool = true
    ) {
        self.event = event
        self.now = now
        self.clock = clock
        self.rules = rules
        self.places = places
        self.guards = guards
        self.cooldowns = cooldowns
        self.automationBudget = automationBudget
        self.inputs = inputs
        self.requireTriggerMatch = requireTriggerMatch
    }
}

/// The core decision (HANDOVER.md §4.3). Pure apart from `EvaluationInputs` and the budget.
///
/// Per rule, cheapest first so Kia is only read when everything else already passed: cooldowns → free
/// conditions (time, day) → rate budget → weather and cabin conditions → vehicle conditions → vehicle
/// guards (SoC, already running). The first rule to pass wins.
public enum RuleEvaluator {
    public static func evaluate(_ req: EvaluationRequest) async -> Evaluation {
        func skip(_ reason: String) -> Evaluation {
            Evaluation(event: req.event, at: req.now, globalSkip: reason, verdicts: [], winner: nil)
        }
        let today = req.clock.day(req.now)
        if req.guards.automationPaused { return skip("automation paused") }
        if req.guards.holidays.contains(today) { return skip("holiday \(today)") }

        let weekday = req.clock.weekday(req.now)
        let candidates = req.rules
            .filter { $0.enabled && (!req.requireTriggerMatch || $0.trigger.matches(req.event, today: weekday)) }
            .sorted { a, b in
                if a.priority != b.priority { return a.priority > b.priority }
                if a.name != b.name { return a.name < b.name }
                return a.id < b.id
            }
        if candidates.isEmpty { return skip("no enabled rules for this trigger") }

        var verdicts: [RuleVerdict] = []
        for rule in candidates {
            let verdict = await RuleRun(rule: rule, req: req).run()
            verdicts.append(verdict)
            if verdict.fired {
                return Evaluation(event: req.event, at: req.now, globalSkip: nil, verdicts: verdicts, winner: rule)
            }
        }
        return Evaluation(event: req.event, at: req.now, globalSkip: nil, verdicts: verdicts, winner: nil)
    }

    static let conditionPrefix = "condition "
}

private enum Tier {
    case free, network, vehicle
}

private final class RuleRun {
    let rule: Rule
    let req: EvaluationRequest
    private var checks: [Check] = []
    private var usedTemp: TempReading?

    init(rule: Rule, req: EvaluationRequest) {
        self.rule = rule
        self.req = req
    }

    private var inputs: EvaluationInputs { req.inputs }
    private var now: Date { req.now }

    func run() async -> RuleVerdict {
        if !record(ruleCooldown()) { return stopped() }
        if !record(globalCooldown()) { return stopped() }

        // Tiers are worked out up front, from what's free right now, as the Android app does.
        var byTier: [Tier: [Condition]] = [:]
        for c in rule.conditions { byTier[await tier(of: c), default: []].append(c) }

        for c in byTier[.free] ?? [] {
            if !record(await evaluate(c)) { return stopped() }
        }
        if !record(await budgetCheck()) { return stopped() }
        for tier in [Tier.network, .vehicle] {
            for c in byTier[tier] ?? [] {
                if !record(await evaluate(c)) { return stopped() }
            }
        }
        for g in await vehicleGuards() {
            if !record(g) { return stopped() }
        }

        let summary = checks.filter { $0.name.hasPrefix(RuleEvaluator.conditionPrefix) }.map(\.detail).joined(separator: "; ")
        let reason = summary.isEmpty ? "no conditions; guards passed" : summary
        return RuleVerdict(ruleId: rule.id, ruleName: rule.name, fired: true, reason: reason, checks: checks, temperature: usedTemp)
    }

    private func stopped() -> RuleVerdict {
        RuleVerdict(ruleId: rule.id, ruleName: rule.name, fired: false, reason: checks.last?.description ?? "", checks: checks, temperature: usedTemp)
    }

    /// Records a check; returns whether evaluation may continue.
    private func record(_ check: Check) -> Bool {
        checks.append(check)
        return check.result == .pass
    }

    // MARK: Guards

    private func ruleCooldown() -> Check {
        if let last = req.cooldowns.lastFiredByRule[rule.id] {
            let until = last.addingTimeInterval(TimeInterval(rule.cooldownMinutes * 60))
            if now < until { return Check("rule cooldown", .fail, "active until \(Describe.time(req.clock.timeOfDay(until)))") }
        }
        return Check("rule cooldown", .pass, "not active")
    }

    private func globalCooldown() -> Check {
        if let last = req.cooldowns.lastAutomatedCommandAt {
            let until = last.addingTimeInterval(req.guards.globalCooldown)
            if now < until { return Check("global cooldown", .fail, "active until \(Describe.time(req.clock.timeOfDay(until)))") }
        }
        return Check("global cooldown", .pass, "not active")
    }

    private func budgetCheck() async -> Check {
        let needed = await inputs.vehicleIfFree() != nil ? 1 : 2
        let available = await req.automationBudget()
        return available >= needed
            ? Check("rate budget", .pass, "\(available) available, needs \(needed)")
            : Check("rate budget", .fail, "only \(available) automation requests left, needs \(needed)")
    }

    private func vehicleGuards() async -> [Check] {
        guard let v = await inputs.vehicle() else { return [Check("vehicle state", .fail, "unavailable")] }
        switch rule.action {
        case .startClimate: return [Guards.soc(v, minPercent: req.guards.minSocPercent), Guards.notRunning(v)]
        case .stopClimate: return [Guards.running(v)]
        }
    }

    // MARK: Tiers

    private func tier(of c: Condition) async -> Tier {
        switch c {
        case .timeWindow, .daysOfWeek: return .free
        case .socAtLeast, .pluggedIn, .carAtPlace, .phoneNearCar: return .vehicle
        case .tempBelow(_, let s), .tempAbove(_, let s), .tempOutside(_, _, let s): return await tier(of: s)
        }
    }

    private func tier(of s: TempSource) async -> Tier {
        switch s {
        case .cabinBle: return .network
        case .carOutside: return .vehicle
        case .weatherAtCar, .forecastAt: return await freeCarLocation() != nil ? .network : .vehicle
        case .bestAvailable:
            // A car already known not to report an outside temperature means weather is the answer.
            let cached = await inputs.vehicleIfFree()
            if let cached, cached.outsideTempC == nil, await freeCarLocation() != nil { return .network }
            return .vehicle
        }
    }

    // MARK: Conditions

    private func evaluate(_ c: Condition) async -> Check {
        let label = RuleEvaluator.conditionPrefix + Describe.condition(c) { self.placeName($0) }
        let (result, detail): (Tri, String)
        switch c {
        case .timeWindow(let start, let end):
            (result, detail) = timeWindow(start, end)
        case .daysOfWeek(let days):
            let today = req.clock.weekday(now)
            (result, detail) = (days.contains(today) ? .pass : .fail, "today is \(Describe.days([today]))")
        case .tempBelow(let t, let s):
            (result, detail) = await temperature(s, threshold: t, below: true)
        case .tempAbove(let t, let s):
            (result, detail) = await temperature(s, threshold: t, below: false)
        case .tempOutside(let low, let high, let s):
            (result, detail) = await temperatureOutside(low: low, high: high, source: s)
        case .socAtLeast(let p):
            if let soc = await inputs.vehicle()?.socPercent {
                (result, detail) = soc >= p ? (.pass, "charge \(soc)% ≥ \(p)%") : (.fail, "charge \(soc)% < \(p)%")
            } else {
                (result, detail) = (.unknown, "charge unknown")
            }
        case .pluggedIn(let expected):
            if let plugged = await inputs.vehicle()?.pluggedIn {
                (result, detail) = (plugged == expected ? .pass : .fail, plugged ? "plugged in" : "not plugged in")
            } else {
                (result, detail) = (.unknown, "plug state unknown")
            }
        case .carAtPlace(let id):
            (result, detail) = await carAtPlace(id)
        case .phoneNearCar(let m):
            (result, detail) = await phoneNearCar(m)
        }
        if result == .unknown && rule.proceedIfUnknown {
            return Check(label, .pass, "\(detail) (unknown, proceeding as the rule allows)")
        }
        return Check(label, result, detail)
    }

    private func timeWindow(_ start: TimeOfDay, _ end: TimeOfDay) -> (Tri, String) {
        let t = req.clock.timeOfDay(now)
        let inside: Bool
        if start == end {
            inside = true
        } else if start < end {
            inside = t >= start && t < end
        } else {
            inside = t >= start || t < end
        }
        return (inside ? .pass : .fail, "now \(Describe.time(t))")
    }

    private func temperature(_ source: TempSource, threshold: Double, below: Bool) async -> (Tri, String) {
        guard let reading = await readTemp(source) else { return (.unknown, "\(Describe.source(source)) unavailable") }
        usedTemp = reading
        let ok = below ? reading.celsius < threshold : reading.celsius > threshold
        let op = ok ? (below ? "<" : ">") : (below ? "≥" : "≤")
        return (ok ? .pass : .fail, "\(Describe.temp(reading.celsius)) (\(reading.source)) \(op) \(Describe.temp(threshold))")
    }

    private func temperatureOutside(low: Double, high: Double, source: TempSource) async -> (Tri, String) {
        guard let reading = await readTemp(source) else { return (.unknown, "\(Describe.source(source)) unavailable") }
        usedTemp = reading
        let t = reading.celsius
        let where_ = "\(Describe.temp(t)) (\(reading.source))"
        if t < low { return (.pass, "\(where_) < \(Describe.temp(low))") }
        if t > high { return (.pass, "\(where_) > \(Describe.temp(high))") }
        return (.fail, "\(where_) is within \(Describe.temp(low))–\(Describe.temp(high))")
    }

    private func readTemp(_ source: TempSource) async -> TempReading? {
        switch source {
        case .carOutside:
            guard let v = await inputs.vehicle(), let t = v.outsideTempC else { return nil }
            return TempReading(celsius: t, source: "car sensor", at: v.fetchedAt)
        case .weatherAtCar:
            guard let (loc, where_) = await carLocation(), var r = await inputs.weatherNow(at: loc) else { return nil }
            r.source = "\(r.source) at \(where_)"
            return r
        case .forecastAt(let time):
            guard let (loc, where_) = await carLocation(), var r = await inputs.forecast(at: loc, time: forecastInstant(time)) else { return nil }
            r.source = "\(r.source) at \(where_)"
            return r
        case .cabinBle:
            return await inputs.cabinTemp()
        case .bestAvailable:
            let cached = await inputs.vehicleIfFree()
            let knownWithoutSensor = cached != nil && cached?.outsideTempC == nil
            if !knownWithoutSensor, let fromCar = await readTemp(.carOutside) { return fromCar }
            return await readTemp(.weatherAtCar)
        }
    }

    /// The next occurrence of the forecast time; a time up to an hour ago still means today.
    private func forecastInstant(_ time: TimeOfDay) -> Date {
        let today = req.clock.date(time, sameDayAs: now)
        return today < now.addingTimeInterval(-3600) ? req.clock.date(time, sameDayAs: now, daysLater: 1) : today
    }

    private func carAtPlace(_ id: String) async -> (Tri, String) {
        guard let place = req.places[id] else { return (.fail, "place \(id) no longer exists") }
        guard let pos = await inputs.vehicle()?.parkingPosition else { return (.unknown, "parking position unavailable") }
        let distance = Int(place.centre.distance(to: pos))
        return place.contains(pos)
            ? (.pass, "car \(distance) m from \(place.name)")
            : (.fail, "car \(distance) m from \(place.name) (radius \(place.radiusM) m)")
    }

    /// The phone first: it's free, and without it there's no point reading the car.
    private func phoneNearCar(_ meters: Int) async -> (Tri, String) {
        guard let phone = await inputs.phoneLocation() else { return (.unknown, "phone location unavailable") }
        guard let car = await inputs.vehicle()?.parkingPosition else { return (.unknown, "car position unavailable") }
        let d = Int(phone.distance(to: car))
        return (d <= meters ? .pass : .fail, "phone \(Describe.distance(d)) from the car")
    }

    // MARK: Car location

    /// The car's location without spending a Kia request: cached position, else the place fallback.
    private func freeCarLocation() async -> (LatLon, String)? {
        if let pos = await inputs.vehicleIfFree()?.parkingPosition { return (pos, "car position") }
        return placeFallback()
    }

    private func carLocation() async -> (LatLon, String)? {
        if let free = await freeCarLocation() { return free }
        return await inputs.vehicle()?.parkingPosition.map { ($0, "car position") }
    }

    /// Where the car most likely is: a car-at-place condition's place, else the trigger's place.
    private func placeFallback() -> (LatLon, String)? {
        var ids: [String] = rule.conditions.compactMap { if case .carAtPlace(let id) = $0 { return id } else { return nil } }
        if let id = rule.trigger.placeId { ids.append(id) }
        guard let place = ids.lazy.compactMap({ self.req.places[$0] }).first else { return nil }
        return (place.parkingSpotOrCentre, place.usualParkingSpot != nil ? "usual spot at \(place.name)" : place.name)
    }

    private func placeName(_ id: String) -> String { req.places[id]?.name ?? id }
}
