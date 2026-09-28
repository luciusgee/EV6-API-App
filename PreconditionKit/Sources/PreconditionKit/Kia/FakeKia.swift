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

    public init(
        socPercent: Int = 62,
        pluggedIn: Bool = false,
        charging: Bool = false,
        climateOn: Bool = false,
        targetTempC: Double = 21.0,
        latitude: Double = 50.4113,
        longitude: Double = 14.9053,
        scenario: FakeScenario = .none,
        dailyLimit: Int = 200
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
    }
}

/// A stand-in for Kia Connect: login, device registration, vehicle list (one older-protocol EV6), cached
/// status, parked position and climate control, all driven by `state`. Install it behind a
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
                }
            }
            return ok([:], msgId: "fake-\(Int64(now.timeIntervalSince1970 * 1000))")
        }
        return fail(404, "4040", "not found")
    }

    private func status(_ s: FakeCarState, now: Date) -> JSONValue {
        let charging = s.pluggedIn && s.charging
        let range: JSONValue = ["value": .number(Double(s.socPercent * 5)), "unit": 1]
        let evStatus: JSONValue = [
            "batteryStatus": .number(Double(s.socPercent)),
            "batteryCharge": .bool(charging),
            "batteryPlugin": .number(s.pluggedIn ? 2 : 0),
            "batteryPower": ["batteryStndChrgPower": .number(charging ? 10.9 : 0), "batteryFstChrgPower": 0],
            "remainTime2": ["atc": ["value": .number(charging ? Double((100 - s.socPercent) * 5) : 0), "unit": 1]],
            "drvDistance": [["rangeByFuel": ["evModeRange": range]]],
        ]
        let vehicleStatus: JSONValue = [
            "time": .string(Self.berlinTime(now.addingTimeInterval(-120))),
            "airCtrlOn": .bool(s.climateOn),
            "engine": false,
            "airTemp": ["value": .string(KiaMapper.legacyTempCode(s.targetTempC)), "unit": 0],
            "evStatus": evStatus,
        ]
        var info: [String: JSONValue] = [
            "vehicleStatus": vehicleStatus,
            "odometer": ["value": 18234.5, "unit": 1],
        ]
        if s.scenario != .partial {
            info["vehicleLocation"] = [
                "coord": ["lat": .number(s.latitude), "lon": .number(s.longitude)],
                "time": .string(Self.berlinTime(now.addingTimeInterval(-3600))),
            ]
        }
        return ["vehicleStatusInfo": .object(info)]
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
