import Foundation

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
