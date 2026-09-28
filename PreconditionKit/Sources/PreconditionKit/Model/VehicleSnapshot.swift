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
    /// Everything else Kia reports: locks, doors, tyres, 12 V battery, charge limits, odometer.
    public var details: VehicleDetails?

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
        fetchedAt: Date,
        details: VehicleDetails? = nil
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
        self.details = details
    }
}

/// The rest of the car's cached state. Every field is optional: nil means Kia didn't report it.
public struct VehicleDetails: Codable, Equatable, Sendable {
    public var odometerKm: Double?
    public var locked: Bool?
    /// The 12 V battery, 0–100 %.
    public var auxBatteryPercent: Int?
    /// "front left", "rear right"… Empty when all are closed (or not reported).
    public var openDoors: [String]
    public var openWindows: [String]
    public var trunkOpen: Bool?
    public var hoodOpen: Bool?
    public var chargePortOpen: Bool?
    /// Any tyre-pressure warning lamp.
    public var tyreWarning: Bool?
    /// Positions with a low-pressure warning.
    public var tyreWarnings: [String]
    /// Charge limits the car will stop at, 50–100 %.
    public var chargeLimitAC: Int?
    public var chargeLimitDC: Int?
    /// Battery state of health, when the car reports it.
    public var batteryHealthPercent: Double?
    public var defrostOn: Bool?
    public var steeringWheelHeatOn: Bool?

    public init(
        odometerKm: Double? = nil,
        locked: Bool? = nil,
        auxBatteryPercent: Int? = nil,
        openDoors: [String] = [],
        openWindows: [String] = [],
        trunkOpen: Bool? = nil,
        hoodOpen: Bool? = nil,
        chargePortOpen: Bool? = nil,
        tyreWarning: Bool? = nil,
        tyreWarnings: [String] = [],
        chargeLimitAC: Int? = nil,
        chargeLimitDC: Int? = nil,
        batteryHealthPercent: Double? = nil,
        defrostOn: Bool? = nil,
        steeringWheelHeatOn: Bool? = nil
    ) {
        self.odometerKm = odometerKm
        self.locked = locked
        self.auxBatteryPercent = auxBatteryPercent
        self.openDoors = openDoors
        self.openWindows = openWindows
        self.trunkOpen = trunkOpen
        self.hoodOpen = hoodOpen
        self.chargePortOpen = chargePortOpen
        self.tyreWarning = tyreWarning
        self.tyreWarnings = tyreWarnings
        self.chargeLimitAC = chargeLimitAC
        self.chargeLimitDC = chargeLimitDC
        self.batteryHealthPercent = batteryHealthPercent
        self.defrostOn = defrostOn
        self.steeringWheelHeatOn = steeringWheelHeatOn
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        odometerKm = try c.decodeIfPresent(Double.self, forKey: .odometerKm)
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked)
        auxBatteryPercent = try c.decodeIfPresent(Int.self, forKey: .auxBatteryPercent)
        openDoors = try c.decodeIfPresent([String].self, forKey: .openDoors) ?? []
        openWindows = try c.decodeIfPresent([String].self, forKey: .openWindows) ?? []
        trunkOpen = try c.decodeIfPresent(Bool.self, forKey: .trunkOpen)
        hoodOpen = try c.decodeIfPresent(Bool.self, forKey: .hoodOpen)
        chargePortOpen = try c.decodeIfPresent(Bool.self, forKey: .chargePortOpen)
        tyreWarning = try c.decodeIfPresent(Bool.self, forKey: .tyreWarning)
        tyreWarnings = try c.decodeIfPresent([String].self, forKey: .tyreWarnings) ?? []
        chargeLimitAC = try c.decodeIfPresent(Int.self, forKey: .chargeLimitAC)
        chargeLimitDC = try c.decodeIfPresent(Int.self, forKey: .chargeLimitDC)
        batteryHealthPercent = try c.decodeIfPresent(Double.self, forKey: .batteryHealthPercent)
        defrostOn = try c.decodeIfPresent(Bool.self, forKey: .defrostOn)
        steeringWheelHeatOn = try c.decodeIfPresent(Bool.self, forKey: .steeringWheelHeatOn)
    }

    /// Anything that deserves attention: open doors, low tyres, a weak 12 V battery.
    public var alerts: [String] {
        var out: [String] = []
        if !openDoors.isEmpty { out.append("Door open: \(openDoors.joined(separator: ", "))") }
        if trunkOpen == true { out.append("Boot open") }
        if hoodOpen == true { out.append("Bonnet open") }
        if !openWindows.isEmpty { out.append("Window open: \(openWindows.joined(separator: ", "))") }
        if tyreWarning == true || !tyreWarnings.isEmpty {
            out.append(tyreWarnings.isEmpty ? "Tyre pressure warning" : "Low tyre pressure: \(tyreWarnings.joined(separator: ", "))")
        }
        if let aux = auxBatteryPercent, aux < 60 { out.append("12 V battery at \(aux)%") }
        return out
    }
}
