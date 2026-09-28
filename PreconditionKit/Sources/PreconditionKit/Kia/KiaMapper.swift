import Foundation

/// Turns Kia's cached-status responses (both protocols) into a `VehicleSnapshot` (HANDOVER.md §3.7).
public enum KiaMapper {
    /// - Parameters:
    ///   - status: body of `status/latest` (older cars) or `ccs2/carstatus/latest`.
    ///   - park: body of `location/park`, if it was read. Its position wins over the one in `status`.
    public static func toSnapshot(status: JSONValue, park: JSONValue?, ccs2: Bool, fetchedAt: Date) -> VehicleSnapshot {
        var snapshot = ccs2
            ? fromCcs2(status.path("resMsg.state.Vehicle"))
            : fromLegacy(status.path("resMsg.vehicleStatusInfo"))
        if let resMsg = park?.path("resMsg"), let parked = position(resMsg.path("coord.lat"), resMsg.path("coord.lon")) {
            snapshot.parkingPosition = parked
        }
        snapshot.fetchedAt = fetchedAt
        return snapshot
    }

    /// Cars without CCS2 (most EV6s built before the 2024 facelift).
    private static func fromLegacy(_ info: JSONValue?) -> VehicleSnapshot {
        let vs = info?.path("vehicleStatus")
        let ev = vs?.path("evStatus")
        let charging = ev?.path("batteryCharge")?.bool
        let plug = ev?.path("batteryPlugin")?.int
        let range = ev?.path("drvDistance.0.rangeByFuel.evModeRange") ?? ev?.path("drvDistance.0.rangeByFuel.totalAvailableRange")
        let power = [
            ev?.path("batteryPower.batteryStndChrgPower")?.num,
            ev?.path("batteryPower.batteryFstChrgPower")?.num,
        ].compactMap { $0 }.filter { $0 > 0 }.max()
        let airOn = vs?.path("airCtrlOn")?.bool
        let engine = vs?.path("engine")?.bool
        let plugged = plug.map { $0 != 0 }

        return VehicleSnapshot(
            socPercent: ev?.path("batteryStatus")?.int,
            rangeKm: km(range?.path("value")?.num, unit: range?.path("unit")?.int),
            pluggedIn: plugged,
            chargePowerKw: charging == true ? power : nil,
            minutesToFullyCharged: ev?.path("remainTime2.atc.value")?.int.flatMap { charging == true && $0 > 0 ? $0 : nil },
            climate: airOn.map { $0 ? .running : .off } ?? .unknown,
            climateRawState: airOn.map { $0 ? "ON" : "OFF" },
            targetTempC: legacyTemp(vs?.path("airTemp.value")?.str, unit: vs?.path("airTemp.unit")?.int),
            chargingState: chargingState(plugged: plugged, charging: charging),
            parkingPosition: position(info?.path("vehicleLocation.coord.lat"), info?.path("vehicleLocation.coord.lon")),
            parked: engine.map { !$0 },
            carCapturedAt: time(vs?.path("time")?.str, zone: berlin),
            fetchedAt: Date(timeIntervalSince1970: 0),
            details: legacyDetails(info)
        )
    }

    private static let positions = ["frontLeft": "front left", "frontRight": "front right", "backLeft": "rear left", "backRight": "rear right"]

    private static func legacyDetails(_ info: JSONValue?) -> VehicleDetails? {
        guard let info else { return nil }
        let vs = info.path("vehicleStatus")
        let ev = vs?.path("evStatus")
        func open(_ group: String) -> [String] {
            ["frontLeft", "frontRight", "backLeft", "backRight"].filter { vs?.path("\(group).\($0)")?.bool == true }.map { positions[$0]! }
        }
        let tyres = ["FL": "front left", "FR": "front right", "RL": "rear left", "RR": "rear right"]
        let lowTyres = ["FL", "FR", "RL", "RR"].filter { vs?.path("tirePressureLamp.tirePressureLamp\($0)")?.bool == true }.map { tyres[$0]! }
        // The car sometimes repeats a plug type; the last entry is the one it uses.
        let limits = ev?.path("reservChargeInfos.targetSOClist")?.array ?? []
        func limit(_ plug: Int) -> Int? { limits.last { $0["plugType"]?.int == plug }?["targetSOClevel"]?.int }
        let port = ev?.path("chargePortDoorOpenStatus")?.int
        let wheel = vs?.path("steerWheelHeat")?.int
        let odometer = info.path("odometer.value")?.num
        let odoUnit = info.path("odometer.unit")?.int
        return VehicleDetails(
            odometerKm: odometer.map { odoUnit == 2 || odoUnit == 3 ? $0 * 1.609344 : $0 },
            locked: vs?.path("doorLock")?.bool,
            auxBatteryPercent: vs?.path("battery.batSoc")?.int,
            openDoors: open("doorOpen"),
            openWindows: open("windowOpen"),
            trunkOpen: vs?.path("trunkOpen")?.bool,
            hoodOpen: vs?.path("hoodOpen")?.bool,
            chargePortOpen: port == 1 ? true : (port == 2 ? false : nil),
            tyreWarning: vs?.path("tirePressureLamp.tirePressureLampAll")?.bool,
            tyreWarnings: lowTyres,
            chargeLimitAC: limit(1),
            chargeLimitDC: limit(0),
            batteryHealthPercent: ev?.path("batterySoh")?.num.flatMap { $0 > 0 ? $0 : nil },
            defrostOn: vs?.path("defrost")?.bool,
            steeringWheelHeatOn: wheel.map { $0 == 1 }
        )
    }

    private static func ccs2Details(_ v: JSONValue?) -> VehicleDetails? {
        guard let v else { return nil }
        let doors = [("Row1.Driver", "front left"), ("Row1.Passenger", "front right"), ("Row2.Left", "rear left"), ("Row2.Right", "rear right")]
        let openDoors = doors.filter { v.path("Cabin.Door.\($0.0).Open")?.bool == true }.map(\.1)
        let lockValues = doors.compactMap { v.path("Cabin.Door.\($0.0).Lock")?.bool }
        let windows = doors.filter { (v.path("Cabin.Window.\($0.0).Open")?.num ?? 0) > 0 }.map(\.1)
        let tyres = [("Row1.Left", "front left"), ("Row1.Right", "front right"), ("Row2.Left", "rear left"), ("Row2.Right", "rear right")]
        let low = tyres.filter { v.path("Chassis.Axle.\($0.0).Tire.PressureLow")?.bool == true }.map(\.1)
        let odoUnit = v.path("Drivetrain.Odometer.Unit")?.int
        let odometer = v.path("Drivetrain.Odometer")?.num ?? v.path("Drivetrain.Odometer.Value")?.num
        return VehicleDetails(
            odometerKm: odometer.map { odoUnit == 2 || odoUnit == 3 ? $0 * 1.609344 : $0 },
            // A truthy per-door "Lock" means unlocked (as the Python library reads it).
            locked: lockValues.isEmpty ? nil : !lockValues.contains(true),
            auxBatteryPercent: v.path("Electronics.Battery.Level")?.int,
            openDoors: openDoors,
            openWindows: windows,
            trunkOpen: v.path("Body.Trunk.Open")?.bool,
            hoodOpen: v.path("Body.Hood.Open")?.bool,
            chargePortOpen: v.path("Green.ChargingDoor.State")?.int.map { $0 == 1 },
            tyreWarning: v.path("Chassis.Axle.Tire.PressureLow")?.bool,
            tyreWarnings: low,
            chargeLimitAC: v.path("Green.ChargingInformation.TargetSoC.Standard")?.int,
            chargeLimitDC: v.path("Green.ChargingInformation.TargetSoC.Quick")?.int,
            batteryHealthPercent: v.path("Green.BatteryManagement.SoH.Ratio")?.num,
            defrostOn: v.path("Body.Windshield.Front.Defog.State")?.bool,
            steeringWheelHeatOn: v.path("Cabin.SteeringWheel.Heat.State")?.bool
        )
    }

    /// 2024-on cars and newer software.
    private static func fromCcs2(_ v: JSONValue?) -> VehicleSnapshot {
        let green = v?.path("Green")
        let plugged = green?.path("ChargingInformation.ConnectorFastening.State")?.num.map { $0 > 0 }
        let remain = green?.path("ChargingInformation.Charging.RemainTime")?.int
        let charging: Bool? = plugged == false ? false : remain.map { $0 > 0 }
        let blower = v?.path("Cabin.HVAC.Row1.Driver.Blower.SpeedLevel")?.num
        let driver = v?.path("Cabin.HVAC.Row1.Driver.Temperature")
        let outside = v?.path("Cabin.HVAC.OutsideTemperature")
        let ready = v?.path("DrivingReady")?.bool

        return VehicleSnapshot(
            socPercent: green?.path("BatteryManagement.BatteryRemain.Ratio")?.int,
            rangeKm: km(v?.path("Drivetrain.FuelSystem.DTE.Total")?.num, unit: v?.path("Drivetrain.FuelSystem.DTE.Unit")?.int),
            pluggedIn: plugged,
            chargePowerKw: green?.path("Electric.SmartGrid.RealTimePower")?.num.flatMap { charging == true && $0 > 0 ? $0 : nil },
            minutesToFullyCharged: charging == true ? remain : nil,
            climate: blower.map { $0 > 0 ? .running : .off } ?? .unknown,
            climateRawState: blower.map { $0 > 0 ? "ON" : "OFF" },
            // "OFF" as the driver temperature parses to nil, i.e. unknown.
            targetTempC: celsius(driver?.path("Value")?.num, unit: driver?.path("Unit")?.int),
            chargingState: chargingState(plugged: plugged, charging: charging),
            outsideTempC: celsius(outside?.path("Value")?.num, unit: outside?.path("Unit")?.int),
            parkingPosition: position(v?.path("Location.GeoCoord.Latitude"), v?.path("Location.GeoCoord.Longitude")),
            parked: ready.map { !$0 },
            carCapturedAt: time(v?.path("Date")?.str, zone: utc),
            fetchedAt: Date(timeIntervalSince1970: 0),
            details: ccs2Details(v)
        )
    }

    private static func chargingState(plugged: Bool?, charging: Bool?) -> ChargingState? {
        if charging == true { return .charging }
        if plugged == true { return .pluggedIn }
        if plugged == false { return .unplugged }
        return nil
    }

    // MARK: - Temperatures

    /// Older cars report temperatures as a hex index into 14.0–29.5 °C in 0.5 °C steps: `"0EH"` = 21 °C.
    /// Out of range, or a unit other than °C (0), is unknown.
    public static func legacyTemp(_ hex: String?, unit: Int?) -> Double? {
        guard var code = hex?.uppercased() else { return nil }
        if let unit, unit != 0 { return nil }
        if code.hasSuffix("H") { code.removeLast() }
        guard let index = Int(code, radix: 16), index >= 0 else { return nil }
        let c = KiaConfig.minTempC + Double(index) * 0.5
        return c <= KiaConfig.maxTempC ? c : nil
    }

    /// The inverse of `legacyTemp`: 21.0 → `"0EH"`. Clamps to the range.
    public static func legacyTempCode(_ c: Double) -> String {
        let clamped = min(max(c, KiaConfig.minTempC), KiaConfig.maxTempC)
        let index = Int((clamped - KiaConfig.minTempC) * 2)
        let hex = String(index, radix: 16, uppercase: true)
        return (hex.count < 2 ? "0" + hex : hex) + "H"
    }

    // MARK: - Units, positions, times

    /// Unit 0 = °C, 1 = °F.
    private static func celsius(_ value: Double?, unit: Int?) -> Double? {
        guard let value else { return nil }
        return unit == 1 ? (value - 32) * 5 / 9 : value
    }

    /// Unit 1 = km, 2 or 3 = miles.
    private static func km(_ value: Double?, unit: Int?) -> Int? {
        guard let value, value.isFinite else { return nil }
        return Int(unit == 2 || unit == 3 ? value * 1.609344 : value)
    }

    /// `0,0` means none.
    private static func position(_ lat: JSONValue?, _ lon: JSONValue?) -> LatLon? {
        guard let la = lat?.num, let lo = lon?.num, !(la == 0 && lo == 0) else { return nil }
        return LatLon(lat: la, lon: lo)
    }

    /// Older cars report Central European local time; CCS2 `Date` is UTC.
    private static let berlin = TimeZone(identifier: "Europe/Berlin")!
    private static let utc = TimeZone(identifier: "UTC")!

    /// `"20240101120000"` or `"20240101120000.000"`; separators tolerated.
    static func time(_ raw: String?, zone: TimeZone) -> Date? {
        guard let digits = raw?.filter(\.isNumber), digits.count >= 14 else { return nil }
        let d = Array(digits.prefix(14))
        func field(_ from: Int, _ length: Int) -> Int? { Int(String(d[from..<(from + length)])) }
        guard let year = field(0, 4), let month = field(4, 2), let day = field(6, 2),
              let hour = field(8, 2), let minute = field(10, 2), let second = field(12, 2),
              (1...12).contains(month), (1...31).contains(day), (0...23).contains(hour),
              (0...59).contains(minute), (0...59).contains(second)
        else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let date = calendar.date(from: components),
              calendar.component(.day, from: date) == day // rejects 31 September and the like
        else { return nil }
        return date
    }
}
