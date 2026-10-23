import Foundation

// Timed performance runs from live speed readings: standing starts, distances, in-gear pulls and
// braking. Every crossing is interpolated between readings, so the result is finer than the rate
// the car answers at.

public enum RunType: String, Codable, CaseIterable, Identifiable, Sendable {
    case zeroTo60mph, zeroTo100kmh, zeroTo100mph, zeroTo200kmh
    case eighthMile, quarterMile, halfMile, standingKm, standingMile
    case thirtyTo70mph, fiftyTo70mph, eightyTo120kmh, hundredTo200kmh
    case brake60mph, brake100kmh

    public var id: String { rawValue }

    public enum Category: String, CaseIterable, Sendable {
        case launch, distance, rolling, braking

        public var title: String {
            switch self {
            case .launch: return "Launch"
            case .distance: return "Drag strip"
            case .rolling: return "In-gear"
            case .braking: return "Braking"
            }
        }
    }

    public enum Spec: Equatable, Sendable {
        /// From one speed to a higher one, km/h. A start of 0 is a standing start.
        case accelerate(from: Double, to: Double)
        /// A standing start over a distance, metres.
        case distance(Double)
        /// From a speed down to a stop, km/h.
        case brake(from: Double)
    }

    public static let mph = 1.609344

    public var spec: Spec {
        switch self {
        case .zeroTo60mph: return .accelerate(from: 0, to: 60 * Self.mph)
        case .zeroTo100kmh: return .accelerate(from: 0, to: 100)
        case .zeroTo100mph: return .accelerate(from: 0, to: 100 * Self.mph)
        case .zeroTo200kmh: return .accelerate(from: 0, to: 200)
        case .eighthMile: return .distance(201.168)
        case .quarterMile: return .distance(402.336)
        case .halfMile: return .distance(804.672)
        case .standingKm: return .distance(1000)
        case .standingMile: return .distance(1609.344)
        case .thirtyTo70mph: return .accelerate(from: 30 * Self.mph, to: 70 * Self.mph)
        case .fiftyTo70mph: return .accelerate(from: 50 * Self.mph, to: 70 * Self.mph)
        case .eightyTo120kmh: return .accelerate(from: 80, to: 120)
        case .hundredTo200kmh: return .accelerate(from: 100, to: 200)
        case .brake60mph: return .brake(from: 60 * Self.mph)
        case .brake100kmh: return .brake(from: 100)
        }
    }

    public var category: Category {
        switch spec {
        case .accelerate(let from, _): return from < 1 ? .launch : .rolling
        case .distance: return .distance
        case .brake: return .braking
        }
    }

    public var title: String {
        switch self {
        case .zeroTo60mph: return "0–60 mph"
        case .zeroTo100kmh: return "0–100 km/h"
        case .zeroTo100mph: return "0–100 mph"
        case .zeroTo200kmh: return "0–200 km/h"
        case .eighthMile: return "⅛ mile"
        case .quarterMile: return "¼ mile"
        case .halfMile: return "½ mile"
        case .standingKm: return "Standing km"
        case .standingMile: return "Standing mile"
        case .thirtyTo70mph: return "30–70 mph"
        case .fiftyTo70mph: return "50–70 mph"
        case .eightyTo120kmh: return "80–120 km/h"
        case .hundredTo200kmh: return "100–200 km/h"
        case .brake60mph: return "60–0 mph"
        case .brake100kmh: return "100–0 km/h"
        }
    }

    /// What to do to start, shown while waiting.
    public var instructions: String {
        if standingStart { return "Come to a stop. Timing starts the moment the car moves." }
        switch spec {
        case .accelerate(let from, _):
            return "Drive steadily below \(Self.speedWords(from)), then accelerate hard through it."
        case .brake(let from):
            return "Get above \(Self.speedWords(from)), then brake hard to a stop."
        case .distance:
            return ""
        }
    }

    static func speedWords(_ kmh: Double) -> String {
        let mph = kmh / Self.mph
        return abs(mph - mph.rounded()) < 0.05 ? "\(Int(mph.rounded())) mph" : "\(Int(kmh.rounded())) km/h"
    }

    public var standingStart: Bool {
        switch spec {
        case .accelerate(let from, _): return from < 1
        case .distance: return true
        case .brake: return false
        }
    }
}

/// One reading during a run, from the start.
public struct TracePoint: Codable, Equatable, Sendable {
    public var seconds: Double
    public var kmh: Double
    public var metres: Double
    public var powerKW: Double?

    public init(seconds: Double, kmh: Double, metres: Double, powerKW: Double? = nil) {
        self.seconds = seconds
        self.kmh = kmh
        self.metres = metres
        self.powerKW = powerKW
    }
}

/// A time along the way: "0–30 mph 2.1 s", "60 ft 1.9 s at 21 mph".
public struct RunSplit: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case speedMph, speedKmh, distance }
    public var kind: Kind
    public var label: String
    public var seconds: Double
    public var kmh: Double
    public var metres: Double
    public var id: String { kind.rawValue + label }
}

public struct RunResult: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var type: RunType
    public var date: Date
    public var seconds: Double
    /// Distance covered during the run (the stopping distance for braking).
    public var metres: Double
    /// Speed at the end: the trap speed on the drag strip.
    public var endKmh: Double
    public var peakPowerKW: Double?
    public var peakKmh: Double
    public var splits: [RunSplit]
    public var trace: [TracePoint]
    /// Readings a second during the run: higher is more precise.
    public var readingsPerSecond: Double
    /// Timed from 1 ft of movement, as drag strips do.
    public var rollout: Bool
    public var socPercent: Double?
    public var batteryC: Double?
    public var car: String?
    /// The phone's motion sensor marked the launch.
    public var motionLaunch: Bool

    /// Peak deceleration for braking, in g.
    public var peakDecelG: Double? {
        guard type.category == .braking, trace.count > 2 else { return nil }
        var best = 0.0
        for (a, b) in zip(trace, trace.dropFirst()) where b.seconds > a.seconds {
            best = max(best, (a.kmh - b.kmh) / 3.6 / (b.seconds - a.seconds) / 9.80665)
        }
        return best
    }
}

public struct RunTimer: Sendable {
    public enum State: Equatable, Sendable {
        /// Not ready: why, in a few words.
        case waiting(String)
        case armed
        case running(since: Date)
        case finished(RunResult)
    }

    public let type: RunType
    public var rollout: Bool
    public private(set) var state: State
    /// Readings since the start, in seconds from it.
    public private(set) var trace: [TracePoint] = []
    private var last: (at: Date, kmh: Double, power: Double?)?
    private var start: Date?
    private var metres = 0.0
    private var readings = 0
    private var context: (soc: Double?, batteryC: Double?, car: String?) = (nil, nil, nil)
    private var motionUsed = false

    /// Below this the car counts as stopped, km/h.
    public static let stopped = 0.5
    /// One foot, the drag strip's rollout.
    public static let rolloutMetres = 0.3048
    /// A run that takes longer than this is abandoned.
    public static let maxSeconds: Double = 120

    public init(type: RunType, rollout: Bool = false) {
        self.type = type
        self.rollout = rollout
        state = .waiting(Self.waitingWords(type))
    }

    static func waitingWords(_ type: RunType) -> String {
        switch type.spec {
        case .accelerate(let from, _) where from >= 1: return "Get below \(RunType.speedWords(max(from - 8, 0)))"
        case .brake(let from): return "Get above \(RunType.speedWords(from + 5))"
        default: return "Come to a stop"
        }
    }

    public mutating func reset() {
        self = RunTimer(type: type, rollout: rollout)
    }

    /// The battery and car at the start, kept with the result.
    public mutating func note(soc: Double?, batteryC: Double?, car: String?) {
        context = (soc, batteryC, car)
    }

    /// Feeds one speed reading. `launchedAt` is when the phone's motion sensor felt the car pull away,
    /// if it did: a sharper start than the first reading over walking pace.
    @discardableResult
    public mutating func add(at: Date, kmh: Double, powerKW: Double? = nil, launchedAt: Date? = nil) -> State {
        defer { last = (at, kmh, powerKW) }
        switch state {
        case .finished:
            return state
        case .waiting:
            if ready(kmh) { state = .armed }
            return state
        case .armed:
            guard let last, let t0 = startCrossing(last, (at, kmh)) else {
                if !ready(kmh) && !starting(kmh) { state = .waiting(Self.waitingWords(type)) }
                return state
            }
            var begin = t0
            // The car was still at the last reading and moving at this one, so a launch the motion
            // sensor felt in between is the true start.
            if type.standingStart, let launchedAt, launchedAt >= last.at.addingTimeInterval(-0.3), launchedAt <= at {
                begin = launchedAt
                motionUsed = true
            }
            start = begin
            metres = 0
            readings = 0
            let startKmh: Double
            switch type.spec {
            case .accelerate(let from, _) where from >= 1: startKmh = from
            case .brake(let from): startKmh = from
            default: startKmh = 0
            }
            trace = [TracePoint(seconds: 0, kmh: startKmh, metres: 0, powerKW: last.power ?? powerKW)]
            state = .running(since: begin)
            // The rest of this reading's interval counts.
            append(at: at, kmh: kmh, powerKW: powerKW, from: (begin, startKmh))
            return finishIfDone()
        case .running(let since):
            if at.timeIntervalSince(since) > Self.maxSeconds {
                reset()
                return state
            }
            if aborted(kmh) {
                state = .armed
                trace = []
                return state
            }
            guard let last else { return state }
            append(at: at, kmh: kmh, powerKW: powerKW, from: (last.at, last.kmh))
            return finishIfDone()
        }
    }

    // MARK: Start and stop

    private func ready(_ kmh: Double) -> Bool {
        switch type.spec {
        case .accelerate(let from, _) where from >= 1: return kmh < from - 3 && kmh > Self.stopped
        case .brake(let from): return kmh > from + 3
        default: return kmh < Self.stopped
        }
    }

    /// Still on the way to starting (e.g. creeping up to the start speed).
    private func starting(_ kmh: Double) -> Bool {
        switch type.spec {
        case .accelerate(let from, _) where from >= 1: return kmh < from && kmh > Self.stopped
        case .brake(let from): return kmh >= from
        default: return kmh < Self.stopped
        }
    }

    private func startCrossing(_ a: (at: Date, kmh: Double, power: Double?), _ b: (at: Date, kmh: Double)) -> Date? {
        switch type.spec {
        case .accelerate(let from, _) where from >= 1:
            return a.kmh < from && b.kmh >= from ? Self.crossing(from, (a.at, a.kmh), b) : nil
        case .brake(let from):
            return a.kmh > from && b.kmh <= from ? Self.crossing(from, (a.at, a.kmh), b) : nil
        default:
            return a.kmh < Self.stopped && b.kmh >= Self.stopped ? Self.crossing(Self.stopped, (a.at, a.kmh), b) : nil
        }
    }

    private func aborted(_ kmh: Double) -> Bool {
        switch type.spec {
        case .accelerate(let from, _) where from >= 1: return kmh < from - 8
        case .brake(let from): return kmh > from + 5
        default: return kmh < Self.stopped && metres > 2
        }
    }

    // MARK: Recording

    private mutating func append(at: Date, kmh: Double, powerKW: Double?, from: (at: Date, kmh: Double)) {
        guard let start else { return }
        let dt = at.timeIntervalSince(from.at)
        if dt > 0 { metres += (from.kmh + kmh) / 2 / 3.6 * dt }
        readings += 1
        trace.append(TracePoint(seconds: at.timeIntervalSince(start), kmh: kmh, metres: metres, powerKW: powerKW))
    }

    private mutating func finishIfDone() -> State {
        guard let end = Self.finish(type.spec, trace) else { return state }
        var points = trace
        // Cut the trace at the finish.
        points = points.filter { $0.seconds < end.seconds } + [end]
        var zero = 0.0
        if rollout && type.standingStart, let p = Self.point(atMetres: Self.rolloutMetres, points) {
            // The clock starts a foot in: the trace starts there too.
            zero = p.seconds
            points = [p] + points.filter { $0.seconds > zero }
        }
        let shifted = points.map { TracePoint(seconds: $0.seconds - zero, kmh: $0.kmh, metres: $0.metres, powerKW: $0.powerKW) }
        let seconds = end.seconds - zero
        let rate = seconds > 0 ? Double(readings) / end.seconds : 0
        let result = RunResult(
            id: UUID(), type: type, date: start ?? Date(), seconds: seconds, metres: end.metres, endKmh: end.kmh,
            peakPowerKW: shifted.compactMap(\.powerKW).max(), peakKmh: shifted.map(\.kmh).max() ?? end.kmh,
            splits: Self.splits(type, shifted), trace: shifted, readingsPerSecond: rate, rollout: rollout && type.standingStart,
            socPercent: context.soc, batteryC: context.batteryC, car: context.car, motionLaunch: motionUsed
        )
        state = .finished(result)
        return state
    }

    /// The interpolated finishing point, once the trace has passed it.
    static func finish(_ spec: RunType.Spec, _ trace: [TracePoint]) -> TracePoint? {
        guard trace.count >= 2 else { return nil }
        let a = trace[trace.count - 2], b = trace[trace.count - 1]
        switch spec {
        case .accelerate(_, let to):
            guard b.kmh >= to else { return nil }
            return interpolate(a, b, fraction: b.kmh > a.kmh ? (to - a.kmh) / (b.kmh - a.kmh) : 1)
        case .distance(let m):
            guard b.metres >= m else { return nil }
            return interpolate(a, b, fraction: b.metres > a.metres ? (m - a.metres) / (b.metres - a.metres) : 1)
        case .brake:
            guard b.kmh <= stopped else { return nil }
            // The car reports 0 once stopped, which hides when it stopped. Carry on at the rate it was
            // slowing before.
            if trace.count >= 3, b.kmh <= 0 {
                let p = trace[trace.count - 3]
                let rate = (p.kmh - a.kmh) / (a.seconds - p.seconds)
                if a.seconds > p.seconds, rate > 0 {
                    let t = (a.kmh - stopped) / rate
                    if t < b.seconds - a.seconds {
                        return interpolate(a, b, fraction: t / (b.seconds - a.seconds), kmh: stopped, metres: a.metres + (a.kmh + stopped) / 2 / 3.6 * t)
                    }
                }
            }
            return interpolate(a, b, fraction: a.kmh > b.kmh ? (a.kmh - stopped) / (a.kmh - b.kmh) : 1)
        }
    }

    static func interpolate(_ a: TracePoint, _ b: TracePoint, fraction f: Double, kmh: Double? = nil, metres: Double? = nil) -> TracePoint {
        let f = min(max(f, 0), 1)
        func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * f }
        let power: Double? = {
            switch (a.powerKW, b.powerKW) {
            case let (x?, y?): return mix(x, y)
            case let (x, y): return y ?? x
            }
        }()
        return TracePoint(seconds: mix(a.seconds, b.seconds), kmh: kmh ?? mix(a.kmh, b.kmh), metres: metres ?? mix(a.metres, b.metres), powerKW: power)
    }

    static func crossing(_ v: Double, _ a: (at: Date, kmh: Double), _ b: (at: Date, kmh: Double)) -> Date {
        let dv = b.kmh - a.kmh
        guard dv != 0 else { return b.at }
        let f = min(max((v - a.kmh) / dv, 0), 1)
        return a.at.addingTimeInterval(b.at.timeIntervalSince(a.at) * f)
    }

    // MARK: Splits

    static func time(atMetres m: Double, _ trace: [TracePoint]) -> Double? {
        for (a, b) in zip(trace, trace.dropFirst()) where a.metres <= m && b.metres >= m && b.metres > a.metres {
            return interpolate(a, b, fraction: (m - a.metres) / (b.metres - a.metres)).seconds
        }
        return nil
    }

    static func point(atKmh v: Double, _ trace: [TracePoint]) -> TracePoint? {
        for (a, b) in zip(trace, trace.dropFirst()) where a.kmh < v && b.kmh >= v {
            return interpolate(a, b, fraction: (v - a.kmh) / (b.kmh - a.kmh))
        }
        return nil
    }

    static func point(atMetres m: Double, _ trace: [TracePoint]) -> TracePoint? {
        for (a, b) in zip(trace, trace.dropFirst()) where a.metres <= m && b.metres >= m && b.metres > a.metres {
            return interpolate(a, b, fraction: (m - a.metres) / (b.metres - a.metres))
        }
        return nil
    }

    static let distanceMarks: [(String, Double)] = [
        ("60 ft", 18.288), ("330 ft", 100.584), ("⅛ mile", 201.168), ("1000 ft", 304.8),
        ("¼ mile", 402.336), ("½ mile", 804.672), ("1 km", 1000), ("1 mile", 1609.344),
    ]

    static func splits(_ type: RunType, _ trace: [TracePoint]) -> [RunSplit] {
        guard let first = trace.first, let last = trace.last else { return [] }
        var out: [RunSplit] = []
        switch type.spec {
        case .brake:
            return []
        case .distance(let total):
            for (label, m) in distanceMarks where m < total - 0.5 {
                if let p = point(atMetres: m, trace) {
                    out.append(RunSplit(kind: .distance, label: label, seconds: p.seconds, kmh: p.kmh, metres: m))
                }
            }
        case .accelerate:
            break
        }
        // Speed marks passed on the way, in both units.
        let lower = first.kmh
        let upper = last.kmh
        for mph in stride(from: 10.0, through: 200, by: 10) {
            let v = mph * RunType.mph
            guard v > lower + 0.5, v < upper - 0.5, let p = point(atKmh: v, trace) else { continue }
            let from = lower < 1 ? "0" : "\(Int((lower / RunType.mph).rounded()))"
            out.append(RunSplit(kind: .speedMph, label: "\(from)–\(Int(mph)) mph", seconds: p.seconds, kmh: v, metres: p.metres))
        }
        for kmh in stride(from: 20.0, through: 300, by: 20) {
            guard kmh > lower + 0.5, kmh < upper - 0.5, let p = point(atKmh: kmh, trace) else { continue }
            let from = lower < 1 ? "0" : "\(Int(lower.rounded()))"
            out.append(RunSplit(kind: .speedKmh, label: "\(from)–\(Int(kmh)) km/h", seconds: p.seconds, kmh: kmh, metres: p.metres))
        }
        return out
    }
}
