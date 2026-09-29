import Foundation

/// Times a run between two speeds from OBD speed readings: 0–60 mph, 0–100 km/h, 50–70 mph, or a
/// quarter mile. Crossings are interpolated between readings, so the time is better than the poll rate.
public struct AccelerationTimer: Sendable {
    public enum Kind: Hashable, Sendable {
        /// Between two speeds, in km/h.
        case speed(from: Double, to: Double)
        /// A standing start over a distance in metres.
        case distance(metres: Double)

        public static let zeroTo60mph = Kind.speed(from: 0, to: 96.56)
        public static let zeroTo100 = Kind.speed(from: 0, to: 100)
        public static let fiftyTo70mph = Kind.speed(from: 80.47, to: 112.65)
        public static let quarterMile = Kind.distance(metres: 402.336)

        var standingStart: Bool {
            switch self {
            case .speed(let from, _): return from < 1
            case .distance: return true
            }
        }
    }

    public enum State: Equatable, Sendable {
        /// Slow down (or stop) first.
        case waiting
        /// Ready: the timer starts as soon as the car moves (or passes the start speed).
        case armed
        case running(since: Date)
        case finished(Result)
    }

    public struct Result: Equatable, Sendable, Codable {
        public var seconds: Double
        public var distanceMetres: Double
        /// Speed at the end, km/h.
        public var endSpeedKmh: Double
        public var peakPowerKW: Double?
    }

    public let kind: Kind
    public private(set) var state: State = .waiting
    private var last: (at: Date, kmh: Double)?
    private var start: Date?
    private var distance = 0.0
    private var peakPower: Double?
    /// Below this the car counts as stopped, km/h.
    static let stopped = 0.5

    public init(kind: Kind) {
        self.kind = kind
    }

    public mutating func reset() {
        self = AccelerationTimer(kind: kind)
    }

    /// Feeds one reading; returns the state after it.
    @discardableResult
    public mutating func add(at: Date, kmh: Double, powerKW: Double? = nil) -> State {
        defer { last = (at, kmh) }
        switch state {
        case .finished:
            return state
        case .waiting:
            let ready: Bool
            switch kind {
            case .speed(let from, _) where from >= 1: ready = kmh < from - 5
            default: ready = kmh < Self.stopped
            }
            if ready { state = .armed }
            return state
        case .armed:
            let threshold: Double
            if case .speed(let from, _) = kind, from >= 1 { threshold = from } else { threshold = Self.stopped }
            guard kmh >= threshold, let last else { return state }
            // When the car started moving (or passed the start speed), between the two readings.
            let t0 = Self.crossing(threshold, last, (at, kmh))
            start = t0
            distance = Self.metres(from: last, to: (at, kmh), after: t0)
            peakPower = powerKW
            state = .running(since: t0)
            return finishIfDone(previous: (t0, threshold), current: (at, kmh))
        case .running:
            guard let last else { return state }
            if kmh < Self.stopped && kind.standingStart {
                // Stopped again before the end: start over.
                state = .armed
                return state
            }
            if let p = powerKW { peakPower = max(peakPower ?? p, p) }
            return finishIfDone(previous: last, current: (at, kmh))
        }
    }

    private mutating func finishIfDone(previous: (at: Date, kmh: Double), current: (at: Date, kmh: Double)) -> State {
        guard let start else { return state }
        let stepMetres = Self.metres(from: previous, to: current, after: previous.at)
        switch kind {
        case .speed(_, let to):
            if current.kmh >= to {
                let t = Self.crossing(to, previous, current)
                let part = Self.metres(from: previous, to: current, after: previous.at, until: t)
                state = .finished(Result(seconds: t.timeIntervalSince(start), distanceMetres: distance + part, endSpeedKmh: to, peakPowerKW: peakPower))
            } else {
                distance += stepMetres
            }
        case .distance(let metres):
            if distance + stepMetres >= metres, stepMetres > 0 {
                let fraction = (metres - distance) / stepMetres
                let dt = current.at.timeIntervalSince(previous.at)
                let t = previous.at.addingTimeInterval(dt * fraction)
                let v = previous.kmh + (current.kmh - previous.kmh) * fraction
                state = .finished(Result(seconds: t.timeIntervalSince(start), distanceMetres: metres, endSpeedKmh: v, peakPowerKW: peakPower))
            } else {
                distance += stepMetres
            }
        }
        return state
    }

    /// When the speed passed `v`, assuming it changed evenly between the readings.
    static func crossing(_ v: Double, _ a: (at: Date, kmh: Double), _ b: (at: Date, kmh: Double)) -> Date {
        let dv = b.kmh - a.kmh
        guard dv > 0 else { return b.at }
        let f = min(max((v - a.kmh) / dv, 0), 1)
        return a.at.addingTimeInterval(b.at.timeIntervalSince(a.at) * f)
    }

    /// Distance covered between readings from `after` (to `until`), with the speed changing evenly.
    static func metres(from a: (at: Date, kmh: Double), to b: (at: Date, kmh: Double), after: Date, until: Date? = nil) -> Double {
        let total = b.at.timeIntervalSince(a.at)
        guard total > 0 else { return 0 }
        func speed(_ t: Date) -> Double { a.kmh + (b.kmh - a.kmh) * t.timeIntervalSince(a.at) / total }
        let t1 = max(after, a.at)
        let t2 = min(until ?? b.at, b.at)
        guard t2 > t1 else { return 0 }
        return (speed(t1) + speed(t2)) / 2 / 3.6 * t2.timeIntervalSince(t1)
    }
}

/// Trip computer from live readings: distance from speed, energy from battery power.
public struct TripComputer: Sendable, Equatable, Codable {
    public var started: Date
    public private(set) var seconds: Double = 0
    public private(set) var distanceKm: Double = 0
    public private(set) var usedKWh: Double = 0
    public private(set) var regenKWh: Double = 0
    public private(set) var maxPowerKW: Double = 0
    public private(set) var maxRegenKW: Double = 0
    public private(set) var maxSpeedKmh: Double = 0
    private var last: Date?
    private var lastSpeed: Double?
    private var lastPower: Double?

    public init(started: Date) {
        self.started = started
    }

    /// Readings more than this far apart (the adapter dropped out) aren't joined up.
    static let maxGap: TimeInterval = 10

    public mutating func add(at: Date, kmh: Double?, powerKW: Double?) {
        defer {
            last = at
            if let kmh { lastSpeed = kmh }
            if let powerKW { lastPower = powerKW }
        }
        if let kmh { maxSpeedKmh = max(maxSpeedKmh, kmh) }
        if let p = powerKW {
            maxPowerKW = max(maxPowerKW, p)
            maxRegenKW = max(maxRegenKW, -p)
        }
        guard let last else { return }
        let dt = at.timeIntervalSince(last)
        guard dt > 0, dt <= Self.maxGap else { return }
        seconds += dt
        if let v1 = lastSpeed, let v2 = kmh ?? lastSpeed { distanceKm += (v1 + v2) / 2 * dt / 3600 }
        if let p1 = lastPower, let p2 = powerKW ?? lastPower {
            let kWh = (p1 + p2) / 2 * dt / 3600
            if kWh >= 0 { usedKWh += kWh } else { regenKWh -= kWh }
        }
    }

    public var netKWh: Double { usedKWh - regenKWh }
    public var averageSpeedKmh: Double? { seconds > 0 ? distanceKm / seconds * 3600 : nil }
    public var kWhPer100km: Double? { distanceKm > 0.2 ? netKWh / distanceKm * 100 : nil }
    /// Share of the energy used that regen gave back.
    public var regenShare: Double? { usedKWh > 0 ? regenKWh / usedKWh : nil }
}
