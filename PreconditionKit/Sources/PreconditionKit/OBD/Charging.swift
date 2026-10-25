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
    /// Energy into the battery from the power readings, kWh. Gaps (the phone asleep) add nothing.
    public private(set) var integratedKWh: Double = 0
    public private(set) var peakKW: Double = 0
    private var last: Last?
    /// The BMS's "charged since new" counter (kWh) at the first and latest readings, when read.
    public private(set) var counterStartKWh: Double?
    public private(set) var counterLatestKWh: Double?

    /// Energy into the battery, kWh: the BMS's own counter when it was read (it keeps counting through
    /// gaps in the readings), else the power readings added up.
    public var energyKWh: Double {
        guard let a = counterStartKWh, let b = counterLatestKWh, b >= a else { return integratedKWh }
        // The counter moves in 0.1 kWh steps: the readings are finer while nothing was missed.
        return max(integratedKWh, b - a)
    }

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

    enum CodingKeys: String, CodingKey {
        case id, started, updated, points, integratedKWh = "energyKWh", peakKW, last, counterStartKWh, counterLatestKWh
    }

    /// Lenient, so a session saved by an older or newer build still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        started = try c.decode(Date.self, forKey: .started)
        updated = try c.decodeIfPresent(Date.self, forKey: .updated) ?? started
        points = (try? c.decodeIfPresent(LossyArray<ChargePoint>.self, forKey: .points))??.elements ?? []
        integratedKWh = try c.decodeIfPresent(Double.self, forKey: .integratedKWh) ?? 0
        peakKW = try c.decodeIfPresent(Double.self, forKey: .peakKW) ?? 0
        last = try? c.decodeIfPresent(Last.self, forKey: .last)
        counterStartKWh = try c.decodeIfPresent(Double.self, forKey: .counterStartKWh)
        counterLatestKWh = try c.decodeIfPresent(Double.self, forKey: .counterLatestKWh)
    }

    /// Charging: power flowing into the battery and the car standing still.
    public static func isCharging(packKW: Double?, kmh: Double?) -> Bool {
        guard let packKW else { return false }
        return packKW < -0.8 && (kmh ?? 0) < 1
    }

    /// `packKW` is the battery's own sign: negative while charging. `chargedKWh` is the BMS's cumulative
    /// "charged since new" counter, when read.
    public mutating func add(
        at: Date, packKW: Double, socPercent: Double?, batteryMaxC: Double? = nil, batteryMinC: Double? = nil,
        chargedKWh: Double? = nil
    ) {
        let kW = max(0, -packKW)
        if let last {
            let dt = at.timeIntervalSince(last.at)
            // A gap (the phone slept) adds nothing rather than guessing.
            if dt > 0 && dt < 60 { integratedKWh += (last.kW + kW) / 2 * dt / 3600 }
        }
        if let chargedKWh, chargedKWh > 0 {
            // A counter that goes backwards is a misread or another module: start it again from here.
            if counterStartKWh == nil || chargedKWh < (counterLatestKWh ?? 0) {
                counterStartKWh = chargedKWh - integratedKWh
            }
            counterLatestKWh = chargedKWh
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

    /// Minutes from one charge to another, from this session's own points. Nil unless the
    /// session started at or below `a`, so a charge from 50% never passes for a 10–80% time.
    public func minutes(from a: Double, to b: Double) -> Double? {
        guard let s0 = startSoc, s0 <= a + 0.5,
              let start = points.first(where: { ($0.socPercent ?? -1) >= a }),
              let end = points.first(where: { ($0.socPercent ?? -1) >= b }), end.seconds > start.seconds else { return nil }
        return (end.seconds - start.seconds) / 60
    }
}
