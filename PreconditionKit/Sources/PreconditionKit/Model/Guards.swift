import Foundation

public enum Tri: String, Sendable {
    case pass = "PASS"
    case fail = "FAIL"
    case unknown = "UNKNOWN"
}

/// One check in a decision, shown in the log as `"<name>: <detail>"`.
public struct Check: Equatable, Sendable, CustomStringConvertible {
    public var name: String
    public var result: Tri
    public var detail: String

    public init(_ name: String, _ result: Tri, _ detail: String) {
        self.name = name
        self.result = result
        self.detail = detail
    }

    public var description: String { "\(name): \(detail)" }
}

/// Safety guards shared by automated rules and manual commands. Unknown inputs always fail a guard.
/// The wording is the Android app's; users read it in the log.
public enum Guards {
    public static func soc(_ v: VehicleSnapshot, minPercent: Int) -> Check {
        if v.pluggedIn == true { return Check("SoC guard", .pass, "plugged in") }
        guard let soc = v.socPercent else { return Check("SoC guard", .fail, "state of charge unknown") }
        if soc < minPercent { return Check("SoC guard", .fail, "SoC \(soc)% below minimum \(minPercent)%") }
        return Check("SoC guard", .pass, "SoC \(soc)% ≥ \(minPercent)%")
    }

    public static func notRunning(_ v: VehicleSnapshot) -> Check {
        switch v.climate {
        case .off: return Check("not running", .pass, "climatisation off")
        case .running: return Check("not running", .fail, "already running (\(v.climateRawState ?? "on"))")
        case .unknown: return Check("not running", .fail, "climatisation state unknown")
        }
    }

    public static func running(_ v: VehicleSnapshot) -> Check {
        switch v.climate {
        case .running: return Check("running", .pass, "climatisation running")
        case .off: return Check("running", .fail, "climatisation already off")
        case .unknown: return Check("running", .fail, "climatisation state unknown")
        }
    }
}
