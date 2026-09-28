import Foundation

public enum ClimateState: String, Codable, Sendable {
    case off = "OFF"
    case running = "RUNNING"
    case unknown = "UNKNOWN"
}

public enum ChargingState: String, Codable, Sendable {
    case charging = "CHARGING"
    case pluggedIn = "PLUGGED_IN"
    case unplugged = "UNPLUGGED"
}

/// The car's state as the rules and the dashboard see it. Every field is optional: nil means Kia didn't
/// report it, which rules treat as unknown, never as a failure. Cached to disk, so it's `Codable`.
public struct VehicleSnapshot: Codable, Equatable, Sendable {
    public var socPercent: Int?
    public var rangeKm: Int?
    public var pluggedIn: Bool?
    /// Only while charging.
    public var chargePowerKw: Double?
    /// Only while charging.
    public var minutesToFullyCharged: Int?
    public var climate: ClimateState
    /// Raw climate state for display and logs ("ON"/"OFF").
    public var climateRawState: String?
    public var targetTempC: Double?
    public var chargingState: ChargingState?
    /// Only CCS2 cars report it.
    public var outsideTempC: Double?
    public var parkingPosition: LatLon?
    /// True when the car is parked, false when it's ready to drive, nil when not reported.
    public var parked: Bool?
    /// When the car last reported this state (it can be hours or days old: we never wake the car).
    public var carCapturedAt: Date?
    /// When we fetched it from Kia.
    public var fetchedAt: Date

    public init(
        socPercent: Int? = nil,
        rangeKm: Int? = nil,
        pluggedIn: Bool? = nil,
        chargePowerKw: Double? = nil,
        minutesToFullyCharged: Int? = nil,
        climate: ClimateState = .unknown,
        climateRawState: String? = nil,
        targetTempC: Double? = nil,
        chargingState: ChargingState? = nil,
        outsideTempC: Double? = nil,
        parkingPosition: LatLon? = nil,
        parked: Bool? = nil,
        carCapturedAt: Date? = nil,
        fetchedAt: Date
    ) {
        self.socPercent = socPercent
        self.rangeKm = rangeKm
        self.pluggedIn = pluggedIn
        self.chargePowerKw = chargePowerKw
        self.minutesToFullyCharged = minutesToFullyCharged
        self.climate = climate
        self.climateRawState = climateRawState
        self.targetTempC = targetTempC
        self.chargingState = chargingState
        self.outsideTempC = outsideTempC
        self.parkingPosition = parkingPosition
        self.parked = parked
        self.carCapturedAt = carCapturedAt
        self.fetchedAt = fetchedAt
    }
}
