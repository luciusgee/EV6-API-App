import Foundation

/// Which budget pool a request draws from. Manual requests have a reserve automation can't touch.
public enum RequestKind: String, Codable, Sendable {
    case automation
    case manual
}

/// What the user entered in Settings. Stored in the Keychain; never logged or exported.
public struct Credentials: Codable, Equatable, Sendable, CustomStringConvertible {
    /// A Kia Connect refresh token (48 characters, `[A-Z0-9]`), for those who have one. Empty when signing
    /// in with email and password.
    public var refreshToken: String
    /// Optional: picks the car when the account has several. Empty = first EV.
    public var vin: String
    /// Kia Connect PIN. Needed for charging-schedule changes, and for climate commands on CCS2 cars.
    public var pin: String?
    /// The Kia account email and password (the Kia app's own sign-in).
    public var email: String?
    public var password: String?

    public init(refreshToken: String = "", vin: String = "", pin: String? = nil, email: String? = nil, password: String? = nil) {
        self.refreshToken = refreshToken
        self.vin = vin
        self.pin = pin
        self.email = email
        self.password = password
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        refreshToken = try c.decodeIfPresent(String.self, forKey: .refreshToken) ?? ""
        vin = try c.decodeIfPresent(String.self, forKey: .vin) ?? ""
        pin = try c.decodeIfPresent(String.self, forKey: .pin)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        password = try c.decodeIfPresent(String.self, forKey: .password)
    }

    /// Email and password, when both are set; they win over a refresh token.
    public var account: (email: String, password: String)? {
        guard let e = email?.trimmingCharacters(in: .whitespaces), !e.isEmpty, let p = password, !p.isEmpty else { return nil }
        return (e, p)
    }

    public var isConfigured: Bool { account != nil || !refreshToken.isEmpty }

    /// Identifies the login, so a different account or token starts a new session.
    public var loginFingerprint: String {
        if let account { return KiaSession.fingerprint("account:" + account.email.lowercased()) }
        return KiaSession.fingerprint(refreshToken)
    }

    /// Never prints the token, password or PIN, so credentials can't leak into a log by accident.
    public var description: String {
        let login = account != nil ? "account: \(maskEmail(email ?? ""))" : "refreshToken: \(refreshToken.isEmpty ? "none" : "set")"
        return "Credentials(\(login), vin: \(vin.isEmpty ? "none" : maskVin(vin)), pin: \(pin == nil ? "none" : "set"))"
    }
}

/// "l***@aol.com".
public func maskEmail(_ email: String) -> String {
    guard let at = email.firstIndex(of: "@"), at > email.startIndex else { return "***" }
    return String(email[email.startIndex]) + "***" + String(email[at...])
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
    /// When the car charges at home. Needs the Kia Connect PIN.
    case setOffPeak(OffPeakWindow)
    /// Sends a destination, with any waypoints before it, to the car's nav. Needs the Kia Connect PIN.
    case sendToCar([NavPoint])

    public var description: String {
        switch self {
        case .startCharging: return "start charging"
        case .stopCharging: return "stop charging"
        case .lock: return "lock the car"
        case .unlock: return "unlock the car"
        case .setChargeLimits(let ac, let dc): return "set charge limits to \(ac)% AC, \(dc)% DC"
        case .sendToCar(let points): return "send \(points.last?.name ?? "a destination") to the car's nav"
        case .setOffPeak(let w): return "set off-peak charging to \(w.text)\(w.onlyOffPeak ? " only" : "")"
        }
    }
}

public extension CarCommand {
    /// Whether the car itself carries it out and reports back in Kia's command history. Charge limits,
    /// the off-peak window and places sent to the nav are settings Kia stores: never listed there.
    var confirmedByCar: Bool {
        switch self {
        case .startCharging, .stopCharging, .lock, .unlock: return true
        case .setChargeLimits, .setOffPeak, .sendToCar: return false
        }
    }
}

/// What Kia hands back for an accepted command: its id, to ask later whether the car carried it out.
public struct CommandReceipt: Equatable, Sendable {
    public var messageId: String?

    public init(messageId: String? = nil) {
        self.messageId = messageId
    }
}

/// What the car made of a command, from Kia's notification records.
public enum CommandStatus: String, Codable, Equatable, Sendable {
    /// Not reported yet.
    case pending
    case success
    /// The car refused it (e.g. a door open, or not plugged in).
    case failed
    /// The car didn't answer: asleep, or out of mobile signal.
    case noResponse
    /// Kia doesn't list the command.
    case unknown

    public var isFinal: Bool { self == .success || self == .failed || self == .noResponse }
}

/// The car as the engine sees it. Every call goes through the rate budget and reports an `ApiResult`.
public protocol VehicleAPI: Sendable {
    /// Reads the car's cached state. Never wakes the car.
    func getVehicle(_ kind: RequestKind) async -> ApiResult<VehicleFetch>
    /// Asks the car itself to report, then reads it. Wakes the car's modem, so it costs a little 12 V charge.
    func wakeAndGetVehicle(_ kind: RequestKind) async -> ApiResult<VehicleFetch>
    func startClimate(targetC: Double, kind: RequestKind, options: ClimateOptions) async -> ApiResult<CommandReceipt>
    func stopClimate(_ kind: RequestKind) async -> ApiResult<CommandReceipt>
    func send(_ command: CarCommand, kind: RequestKind) async -> ApiResult<CommandReceipt>
    /// Whether the car has carried out the command Kia gave `messageId` for.
    func commandStatus(_ messageId: String, kind: RequestKind) async -> ApiResult<CommandStatus>
    /// Energy use: lifetime totals and the last 30 days, day by day.
    func drivingHistory(_ kind: RequestKind) async -> ApiResult<DrivingHistory>
    /// The car's drives on one day: start time, minutes and distance (no route).
    func trips(on day: CalendarDay, kind: RequestKind) async -> ApiResult<[CarTrip]>
}

extension VehicleAPI {
    public func wakeAndGetVehicle(_ kind: RequestKind) async -> ApiResult<VehicleFetch> {
        await getVehicle(kind)
    }

    public func startClimate(targetC: Double, kind: RequestKind) async -> ApiResult<CommandReceipt> {
        await startClimate(targetC: targetC, kind: kind, options: ClimateOptions())
    }
}
