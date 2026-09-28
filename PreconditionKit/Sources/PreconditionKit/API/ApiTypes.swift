import Foundation

/// Which budget pool a request draws from. Manual requests have a reserve automation can't touch.
public enum RequestKind: String, Codable, Sendable {
    case automation
    case manual
}

/// What the user entered in Settings. Stored in the Keychain; never logged or exported.
public struct Credentials: Codable, Equatable, Sendable, CustomStringConvertible {
    /// The Kia Connect refresh token (48 characters, `[A-Z0-9]`).
    public var refreshToken: String
    /// Optional: picks the car when the account has several. Empty = first EV.
    public var vin: String
    /// Kia Connect PIN. Only CCS2 cars need it, for climate commands.
    public var pin: String?

    public init(refreshToken: String, vin: String = "", pin: String? = nil) {
        self.refreshToken = refreshToken
        self.vin = vin
        self.pin = pin
    }

    /// Never prints the token or PIN, so credentials can't leak into a log by accident.
    public var description: String {
        "Credentials(refreshToken: \(refreshToken.isEmpty ? "none" : "set"), vin: \(vin.isEmpty ? "none" : maskVin(vin)), pin: \(pin == nil ? "none" : "set"))"
    }
}

public protocol CredentialsProvider: Sendable {
    /// Nil when not configured (no token yet).
    func credentials() async -> Credentials?
}

/// What every finished call reports beyond its body.
public struct ResponseMeta: Equatable, Sendable {
    public var httpCode: Int
    public var receivedAt: Date
    public var retryAfter: TimeInterval?

    public init(httpCode: Int, receivedAt: Date, retryAfter: TimeInterval? = nil) {
        self.httpCode = httpCode
        self.receivedAt = receivedAt
        self.retryAfter = retryAfter
    }
}

/// Receives every response that arrived. The engine's `ApiMonitor` uses it to stop automation on an
/// auth failure and resume it after the next success.
public protocol ApiMetaSink: Sendable {
    func onResponse(_ meta: ResponseMeta, error: ApiError?) async
}

public struct NoopMetaSink: ApiMetaSink {
    public init() {}
    public func onResponse(_ meta: ResponseMeta, error: ApiError?) async {}
}

public enum ApiResult<Value> {
    case success(Value, ResponseMeta)
    /// `meta` is nil when no response arrived.
    case failure(ApiError, ResponseMeta?)

    public var value: Value? {
        if case .success(let v, _) = self { return v }
        return nil
    }

    public var error: ApiError? {
        if case .failure(let e, _) = self { return e }
        return nil
    }

    public var meta: ResponseMeta? {
        switch self {
        case .success(_, let m): return m
        case .failure(_, let m): return m
        }
    }
}

extension ApiResult: Sendable where Value: Sendable {}

public struct VehicleFetch: Equatable, Sendable {
    public var snapshot: VehicleSnapshot
    /// `{"status":…,"park":…}` as Kia sent it. Logged once, VIN masked, so the fields can be checked.
    public var rawJSON: String

    public init(snapshot: VehicleSnapshot, rawJSON: String) {
        self.snapshot = snapshot
        self.rawJSON = rawJSON
    }
}

/// Extras for a climate start.
public struct ClimateOptions: Codable, Equatable, Sendable {
    /// Front windscreen defrost.
    public var defrost: Bool
    /// Heated steering wheel, rear window and mirrors.
    public var heatedExtras: Bool

    public init(defrost: Bool = false, heatedExtras: Bool = false) {
        self.defrost = defrost
        self.heatedExtras = heatedExtras
    }
}

/// Commands beyond climate.
public enum CarCommand: Equatable, Sendable {
    case startCharging
    case stopCharging
    case lock
    case unlock
    /// Where charging stops, in % (50–100, steps of 10), for AC and DC charging.
    case setChargeLimits(ac: Int, dc: Int)

    public var description: String {
        switch self {
        case .startCharging: return "start charging"
        case .stopCharging: return "stop charging"
        case .lock: return "lock the car"
        case .unlock: return "unlock the car"
        case .setChargeLimits(let ac, let dc): return "set charge limits to \(ac)% AC, \(dc)% DC"
        }
    }
}

/// The car as the engine sees it. Every call goes through the rate budget and reports an `ApiResult`.
public protocol VehicleAPI: Sendable {
    /// Reads the car's cached state. Never wakes the car.
    func getVehicle(_ kind: RequestKind) async -> ApiResult<VehicleFetch>
    func startClimate(targetC: Double, kind: RequestKind, options: ClimateOptions) async -> ApiResult<Void>
    func stopClimate(_ kind: RequestKind) async -> ApiResult<Void>
    func send(_ command: CarCommand, kind: RequestKind) async -> ApiResult<Void>
    /// Energy use: lifetime totals and the last 30 days, day by day.
    func drivingHistory(_ kind: RequestKind) async -> ApiResult<DrivingHistory>
}

extension VehicleAPI {
    public func startClimate(targetC: Double, kind: RequestKind) async -> ApiResult<Void> {
        await startClimate(targetC: targetC, kind: kind, options: ClimateOptions())
    }
}
