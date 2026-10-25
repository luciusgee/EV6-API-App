import Foundation

/// One moment of a charge.
public struct ChargePoint: Codable, Equatable, Sendable {
    /// From the start of the session.
    public var seconds: Double
    public var socPercent: Double?
    /// Power going into the battery, kW.
    public var kW: Double
    public var batteryMaxC: Double?
    public var batteryMinC: Double?
}

/// A charge recorded from live readings: the power curve against charge, energy added and the
/// battery's temperature on the way.
public struct ChargeSession: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var started: Date
    public private(set) var updated: Date
    public private(set) var points: [ChargePoint] = []
    /// Energy into the battery, kWh.
    public private(set) var energyKWh: Double = 0
    public private(set) var peakKW: Double = 0
    private var last: Last?

    private struct Last: Codable, Equatable, Sendable {
        var at: Date
        var kW: Double
    }

    /// Keep a point at most this often, unless the charge moves on.
    public static let pointEvery: Double = 5

    public init(started: Date) {
        self.started = started
        updated = started
    }

    /// Charging: power flowing into the battery and the car standing still.
    public static func isCharging(packKW: Double?, kmh: Double?) -> Bool {
        guard let packKW else { return false }
        return packKW < -0.8 && (kmh ?? 0) < 1
    }

    /// `packKW` is the battery's own sign: negative while charging.
    public mutating func add(at: Date, packKW: Double, socPercent: Double?, batteryMaxC: Double? = nil, batteryMinC: Double? = nil) {
        let kW = max(0, -packKW)
        if let last {
            let dt = at.timeIntervalSince(last.at)
            // A gap (the phone slept) adds nothing rather than guessing.
            if dt > 0 && dt < 60 { energyKWh += (last.kW + kW) / 2 * dt / 3600 }
        }
        last = Last(at: at, kW: kW)
        updated = at
        peakKW = max(peakKW, kW)
        let seconds = at.timeIntervalSince(started)
        let socMoved = socPercent.map { s in points.last?.socPercent.map { abs($0 - s) >= 0.5 } ?? true } ?? false
        if points.isEmpty || socMoved || seconds - (points.last?.seconds ?? 0) >= Self.pointEvery {
            points.append(ChargePoint(seconds: seconds, socPercent: socPercent, kW: kW, batteryMaxC: batteryMaxC, batteryMinC: batteryMinC))
        }
    }

    public var duration: Double { updated.timeIntervalSince(started) }
    public var startSoc: Double? { points.lazy.compactMap(\.socPercent).first }
    public var endSoc: Double? { points.reversed().lazy.compactMap(\.socPercent).first }

    public var averageKW: Double? {
        duration > 60 ? energyKWh / (duration / 3600) : nil
    }

    /// Rapid charging: more than any home or AC charger gives.
    public var isRapid: Bool { peakKW > 23 }

    /// The highest power seen at each whole percent: the shape of the charge curve.
    public var curve: [(soc: Int, kW: Double)] {
        var best: [Int: Double] = [:]
        for p in points {
            guard let soc = p.socPercent else { continue }
            let k = Int(soc)
            best[k] = max(best[k] ?? 0, p.kW)
        }
        return best.keys.sorted().map { ($0, best[$0]!) }
    }

    /// Minutes from one charge to another, from this session's own points.
    public func minutes(from a: Double, to b: Double) -> Double? {
        guard let start = points.first(where: { ($0.socPercent ?? -1) >= a }),
              let end = points.first(where: { ($0.socPercent ?? -1) >= b }), end.seconds > start.seconds else { return nil }
        return (end.seconds - start.seconds) / 60
    }
}
