import Foundation

/// An error the fake car answers with, for exercising failure paths from the Developer screen.
public enum FakeScenario: String, CaseIterable, Codable, Sendable {
    case none
    /// The token endpoint rejects the refresh token (`invalid_grant`).
    case refreshTokenRejected
    /// Every API call answers 401 "Token is expired", so even a fresh login fails.
    case accessTokenRejected
    /// `5091`: the daily limit is used up.
    case rateLimited
    /// `5031`: remote control temporarily unavailable.
    case vehicleBusy
    /// `4005` on climate commands.
    case notSupported
    /// HTTP 503.
    case serverError
    /// No position anywhere: `location/park` answers `5921` and the status has no location.
    case partial
}

public struct FakeCarState: Codable, Equatable, Sendable {
    public var socPercent: Int
    public var pluggedIn: Bool
    /// Only meaningful when plugged in.
    public var charging: Bool
    public var climateOn: Bool
    public var targetTempC: Double
    public var latitude: Double
    public var longitude: Double
    public var scenario: FakeScenario
    /// Requests per day before the fake answers `5091`.
    public var dailyLimit: Int
    public var locked: Bool
    public var chargeLimitAC: Int
    public var chargeLimitDC: Int
    public var odometerKm: Double
    /// Like the real car: starting climate while plugged in also wakes the charger.
    public var climateStartsCharging: Bool
    public var lowTyre: Bool
    /// Charging was stopped by command: the session has ended, so climate no longer wakes the charger.
    public var chargerHeld: Bool = false
    /// How the car answers commands in Kia's notification records.
    public var commandOutcome: FakeCommandOutcome = .success
    /// Seconds before the car reports back (0 in tests; a few seconds feels real in the app).
    public var confirmAfter: TimeInterval = 0
    /// The off-peak window; nil is the Kia app's usual 23:00–06:00.
    public var offPeak: OffPeakWindow?

    public init(
        socPercent: Int = 62,
        pluggedIn: Bool = false,
        charging: Bool = false,
        climateOn: Bool = false,
        targetTempC: Double = 21.0,
        latitude: Double = 50.4113,
        longitude: Double = 14.9053,
        scenario: FakeScenario = .none,
        dailyLimit: Int = 200,
        locked: Bool = true,
        chargeLimitAC: Int = 80,
        chargeLimitDC: Int = 80,
        odometerKm: Double = 18234.5,
        climateStartsCharging: Bool = true,
        lowTyre: Bool = false
    ) {
        self.socPercent = socPercent
        self.pluggedIn = pluggedIn
        self.charging = charging
        self.climateOn = climateOn
        self.targetTempC = targetTempC
        self.latitude = latitude
        self.longitude = longitude
        self.scenario = scenario
        self.dailyLimit = dailyLimit
        self.locked = locked
        self.chargeLimitAC = chargeLimitAC
        self.chargeLimitDC = chargeLimitDC
        self.odometerKm = odometerKm
        self.climateStartsCharging = climateStartsCharging
        self.lowTyre = lowTyre
    }
}

public enum FakeCommandOutcome: String, CaseIterable, Codable, Sendable {
    case success, fail, noResponse
}

/// A stand-in for Kia Connect: login, device registration, vehicle list (one older-protocol EV6), cached
/// status, parked position, climate, charging, locks, charge limits and driving history, all driven by `state`. Install it behind a
/// `RoutingTransport` for fake-car mode, or use it directly in tests and SwiftUI previews, so the real
/// client, budget and error mapping run unchanged.
public final class FakeKia: HTTPTransport, @unchecked Sendable {
    public static let vehicleId = "00000000-fake-4000-8000-000000000ev6"
    public static let vin = "KNAFAKE0000000001"

    private struct Counter {
        var windowStart: Date
        var used = 0
    }

    private let time: TimeSource
    private let idpHost: String?
    private let car: Locked<FakeCarState>
    private let counter: Locked<Counter>
    /// Commands sent, by message id, with when.
    private let issued = Locked<[(String, Date)]>([])

    public init(state: FakeCarState = FakeCarState(), time: TimeSource = SystemTime(), config: KiaConfig = KiaConfig()) {
        self.time = time
        self.idpHost = URL(string: config.idpBase)?.host
        self.car = Locked(state)
        self.counter = Locked(Counter(windowStart: time.now()))
    }

    public var state: FakeCarState {
        get { car.current }
        set { car.withLock { $0 = newValue } }
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let path = request.url.path
        let s = state

        if request.url.host == idpHost {
            if s.scenario == .refreshTokenRejected {
                return HTTPResponse(status: 400, text: #"{"error":"invalid_grant","error_description":"Invalid refresh token"}"#)
            }
            return HTTPResponse(
                status: 200,
                text: #"{"token_type":"Bearer","access_token":"fake-access","refresh_token":"FAKEREFRESH","expires_in":86400}"#
            )
        }

        let now = time.now()
        let over = counter.withLock { c -> Bool in
            if now.timeIntervalSince(c.windowStart) >= 24 * 3600 {
                c.windowStart = now
                c.used = 0
            }
            if c.used >= s.dailyLimit { return true }
            c.used += 1
            return false
        }
        if over { return fail(400, "5091", "Exceeds number of requests") }

        switch s.scenario {
        case .accessTokenRejected where !path.hasSuffix("/notifications/register"):
            return HTTPResponse(status: 401, text: #"{"error":"Key not authorized: Token is expired"}"#)
        case .rateLimited:
            return fail(400, "5091", "Exceeds number of requests")
        case .vehicleBusy:
            return fail(400, "5031", "Unavailable remote control - Service Temporary Unavailable")
        case .notSupported where path.contains("/control/"):
            return fail(400, "4005", "Unsupported control")
        case .serverError:
            return HTTPResponse(status: 503, text: #"{"error":"service unavailable"}"#)
        default:
            break
        }

        if path.hasSuffix("/notifications/register") {
            return ok(["deviceId": "fake-device"])
        }
        if path.hasSuffix("/spa/vehicles") {
            let vehicle: JSONValue = [
                "vehicleId": .string(Self.vehicleId),
                "nickname": "EV6 (fake)",
                "vehicleName": "EV6",
                "vin": .string(Self.vin),
                "type": "EV",
                "regDate": "2022-03-01 00:00:00.000",
                "ccuCCS2ProtocolSupport": 0,
            ]
            return ok(["vehicles": [vehicle]])
        }
        if path.hasSuffix("/status/latest") {
            return ok(status(s, now: now))
        }
        if path.hasSuffix("/location/park") {
            if s.scenario == .partial { return fail(400, "5921", "No Data Found v2") }
            let coord: JSONValue = ["lat": .number(s.latitude), "lon": .number(s.longitude), "type": 0]
            return ok(["coord": coord, "time": .string(Self.berlinTime(now.addingTimeInterval(-600)))])
        }
        if path.hasSuffix("/control/temperature") {
            let body = request.body.flatMap(JSONValue.parse)
            car.withLock { car in
                if body?["action"]?.str == "stop" {
                    car.climateOn = false
                } else {
                    car.climateOn = true
                    car.targetTempC = KiaMapper.legacyTemp(body?["tempCode"]?.str, unit: 0) ?? car.targetTempC
                    if car.climateStartsCharging, car.pluggedIn, !car.chargerHeld, car.socPercent < car.chargeLimitAC { car.charging = true }
                }
            }
            return ok([:], msgId: msgId(now))
        }
        if path.hasSuffix("/control/charge") {
            let body = request.body.flatMap(JSONValue.parse)
            guard s.pluggedIn else { return fail(400, "4004", "Charging cable not connected") }
            car.withLock { car in
                car.charging = body?["action"]?.str == "start"
                car.chargerHeld = !car.charging
            }
            return ok([:], msgId: msgId(now))
        }
        if path.hasSuffix("/control/door") {
            let body = request.body.flatMap(JSONValue.parse)
            car.withLock { $0.locked = body?["action"]?.str == "close" }
            return ok([:], msgId: msgId(now))
        }
        if path.hasSuffix("/charge/target") {
            let body = request.body.flatMap(JSONValue.parse)
            car.withLock { car in
                for entry in body?["targetSOClist"]?.array ?? [] {
                    guard let level = entry["targetSOClevel"]?.int else { continue }
                    if entry["plugType"]?.int == 1 { car.chargeLimitAC = level } else { car.chargeLimitDC = level }
                }
            }
            return ok([:], msgId: msgId(now))
        }
        if path.hasSuffix("/pin") {
            return HTTPResponse(status: 200, text: #"{"controlToken":"fake-control","expiresTime":600}"#)
        }
        if path.hasSuffix("/reservation/chargehvac") {
            let body = request.body.flatMap(JSONValue.parse)
            let info = body?["offPeakPowerInfo"]
            if let start = OffPeakWindow.clockTime(info?.path("offPeakPowerTime1.starttime")),
               let end = OffPeakWindow.clockTime(info?.path("offPeakPowerTime1.endtime")) {
                car.withLock { $0.offPeak = OffPeakWindow(start: start, end: end, onlyOffPeak: info?["offPeakPowerFlag"]?.int == 2) }
            }
            return ok([:], msgId: msgId(now))
        }
        if path.hasSuffix("/records") {
            let records: [JSONValue] = issued.current.suffix(20).reversed().map { id, at in
                let done = now.timeIntervalSince(at) >= s.confirmAfter
                let result: JSONValue
                switch s.commandOutcome {
                case _ where !done: result = .null
                case .success: result = "success"
                case .fail: result = "fail"
                case .noResponse: result = "non-response"
                }
                return ["recordId": .string(id), "result": result]
            }
            return ok(.array(records))
        }
        if path.hasSuffix("/drvhistory") {
            let body = request.body.flatMap(JSONValue.parse)
            return ok(Self.drivingHistory(allTime: body?["periodTarget"]?.int == 1, now: now))
        }
        return fail(404, "4040", "not found")
    }

    private func status(_ s: FakeCarState, now: Date) -> JSONValue {
        let charging = s.pluggedIn && s.charging
        let offPeak = s.offPeak ?? OffPeakWindow(start: ClockTime(hour: 23), end: ClockTime(hour: 6))
        let range: JSONValue = ["value": .number(Double(s.socPercent * 5)), "unit": 1]
        let evStatus: JSONValue = [
            "batteryStatus": .number(Double(s.socPercent)),
            "batteryCharge": .bool(charging),
            "batteryPlugin": .number(s.pluggedIn ? 2 : 0),
            "batteryPower": ["batteryStndChrgPower": .number(charging ? 10.9 : 0), "batteryFstChrgPower": 0],
            "remainTime2": ["atc": ["value": .number(charging ? Double((100 - s.socPercent) * 5) : 0), "unit": 1]],
            "drvDistance": [["rangeByFuel": ["evModeRange": range]]],
            "chargePortDoorOpenStatus": .number(s.pluggedIn ? 1 : 2),
            "batterySoh": 97.5,
            "reservChargeInfos": [
                "targetSOClist": [
                    ["plugType": 0, "targetSOClevel": .number(Double(s.chargeLimitDC))],
                    ["plugType": 1, "targetSOClevel": .number(Double(s.chargeLimitAC))],
                ],
                "reservFlag": 0,
                "offpeakPowerInfo": [
                    "offPeakPowerTime1": ["starttime": OffPeakWindow.kiaTime(offPeak.start), "endtime": OffPeakWindow.kiaTime(offPeak.end)],
                    "offPeakPowerFlag": .number(offPeak.onlyOffPeak ? 2 : 1),
                ],
            ],
        ]
        let vehicleStatus: JSONValue = [
            "time": .string(Self.berlinTime(now.addingTimeInterval(-120))),
            "airCtrlOn": .bool(s.climateOn),
            "engine": false,
            "airTemp": ["value": .string(KiaMapper.legacyTempCode(s.targetTempC)), "unit": 0],
            "evStatus": evStatus,
            "doorLock": .bool(s.locked),
            "doorOpen": ["frontLeft": 0, "frontRight": 0, "backLeft": 0, "backRight": 0],
            "windowOpen": ["frontLeft": 0, "frontRight": 0, "backLeft": 0, "backRight": 0],
            "trunkOpen": false,
            "hoodOpen": false,
            "defrost": false,
            "steerWheelHeat": 0,
            "battery": ["batSoc": 88],
            "tirePressureLamp": [
                "tirePressureLampAll": .number(s.lowTyre ? 1 : 0),
                "tirePressureLampFL": 0, "tirePressureLampFR": 0,
                "tirePressureLampRL": .number(s.lowTyre ? 1 : 0), "tirePressureLampRR": 0,
            ],
        ]
        var info: [String: JSONValue] = [
            "vehicleStatus": vehicleStatus,
            "odometer": ["value": .number(s.odometerKm), "unit": 1],
        ]
        if s.scenario != .partial {
            info["vehicleLocation"] = [
                "coord": ["lat": .number(s.latitude), "lon": .number(s.longitude)],
                "time": .string(Self.berlinTime(now.addingTimeInterval(-3600))),
            ]
        }
        return ["vehicleStatusInfo": .object(info)]
    }

    /// A believable month of driving: a commute on weekdays, longer trips at weekends, more heating in the cold.
    private static func drivingHistory(allTime: Bool, now: Date) -> JSONValue {
        if allTime {
            return ["drivingInfo": [["drivingPeriod": 1, "totalPwrCsp": 3_120_000, "regenPwr": 610_000, "calculativeOdo": 18234]]]
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .current
        var days: [JSONValue] = []
        var total = 0.0, odo = 0.0
        for back in 1...30 {
            guard let date = cal.date(byAdding: .day, value: -back, to: now) else { continue }
            let weekday = cal.component(.weekday, from: date)
            let weekend = weekday == 1 || weekday == 7
            let km = weekend ? Double(20 + (back * 37) % 90) : Double(34 + (back * 13) % 12)
            let motor = km * 152, climate = km * (weekend ? 18 : 31), electronics = km * 9, care = 120.0
            let regen = motor * 0.19
            let sum = motor + climate + electronics + care
            total += sum
            odo += km
            let c = cal.dateComponents([.year, .month, .day], from: date)
            days.append([
                "drivingDate": .string(String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)),
                "totalPwrCsp": .number(sum.rounded()), "motorPwrCsp": .number(motor.rounded()),
                "climatePwrCsp": .number(climate.rounded()), "eDPwrCsp": .number(electronics.rounded()),
                "batteryMgPwrCsp": .number(care), "regenPwr": .number(regen.rounded()),
                "calculativeOdo": .number(km),
            ])
        }
        let summary: JSONValue = ["drivingPeriod": 0, "totalPwrCsp": .number(total.rounded()), "calculativeOdo": .number(odo)]
        return ["drivingInfo": [summary], "drivingInfoDetail": .array(days)]
    }

    private func msgId(_ now: Date) -> String {
        let id = "fake-\(Int64(now.timeIntervalSince1970 * 1000))-\(issued.current.count)"
        issued.withLock { $0.append((id, now)) }
        return id
    }

    private func ok(_ resMsg: JSONValue, msgId: String? = nil) -> HTTPResponse {
        var body: [String: JSONValue] = ["retCode": "S", "resCode": "0000", "resMsg": resMsg]
        if let msgId { body["msgId"] = .string(msgId) }
        return HTTPResponse(status: 200, body: JSONValue.object(body).data)
    }

    private func fail(_ status: Int, _ resCode: String, _ message: String) -> HTTPResponse {
        let body: JSONValue = ["retCode": "F", "resCode": .string(resCode), "resMsg": .string(message)]
        return HTTPResponse(status: status, body: body.data)
    }

    private static func berlinTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Europe/Berlin")
        f.dateFormat = "yyyyMMddHHmmss"
        return f.string(from: date)
    }
}

public extension RoutingTransport {
    /// Kia traffic goes to `fake` while `fakeMode` is on.
    static func kia(live: HTTPTransport, fake: FakeKia, config: KiaConfig = KiaConfig()) -> RoutingTransport {
        var fakes: [String: HTTPTransport] = [:]
        for base in [config.apiBase, config.idpBase] {
            if let host = URL(string: base)?.host { fakes[host] = fake }
        }
        return RoutingTransport(live: live, fakes: fakes)
    }
}
