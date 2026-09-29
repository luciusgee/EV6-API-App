import Foundation

/// Login state kept between requests. Holds tokens, so the app stores it in the Keychain
/// (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so background wakes can read it). Never log or export it.
public struct KiaSession: Codable, Equatable, Sendable {
    /// SHA-256 of the refresh token the user entered; entering a different one starts over.
    public var enteredTokenHash: String
    /// The current refresh token. Kia may rotate it, so this can differ from the one entered.
    public var refreshToken: String
    /// `"Bearer …"`, ready for the `Authorization` header.
    public var accessToken: String?
    public var accessExpiresAt: Date
    public var deviceId: String?
    public var vehicleId: String?
    public var vehicleVin: String?
    /// The VIN setting the car was picked for (`""` = first EV on the account).
    public var selectedFor: String?
    /// `ccuCCS2ProtocolSupport` from the vehicle list: 0 for older cars, non-zero for the CCS2 protocol.
    public var ccs2: Int
    /// CCS2 only: `"Bearer …"`, obtained with the PIN.
    public var controlToken: String?
    public var controlExpiresAt: Date
    /// Set when signed in with email and password: the newer Kia app's token set, which refreshes the
    /// access token (`refreshToken` then holds the CCI refresh token).
    public var cci: CCITokens?

    public init(
        enteredTokenHash: String,
        refreshToken: String,
        accessToken: String? = nil,
        accessExpiresAt: Date = .distantPast,
        deviceId: String? = nil,
        vehicleId: String? = nil,
        vehicleVin: String? = nil,
        selectedFor: String? = nil,
        ccs2: Int = 0,
        controlToken: String? = nil,
        controlExpiresAt: Date = .distantPast,
        cci: CCITokens? = nil
    ) {
        self.enteredTokenHash = enteredTokenHash
        self.refreshToken = refreshToken
        self.accessToken = accessToken
        self.accessExpiresAt = accessExpiresAt
        self.deviceId = deviceId
        self.vehicleId = vehicleId
        self.vehicleVin = vehicleVin
        self.selectedFor = selectedFor
        self.ccs2 = ccs2
        self.controlToken = controlToken
        self.controlExpiresAt = controlExpiresAt
        self.cci = cci
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enteredTokenHash = try c.decode(String.self, forKey: .enteredTokenHash)
        refreshToken = try c.decode(String.self, forKey: .refreshToken)
        accessToken = try c.decodeIfPresent(String.self, forKey: .accessToken)
        accessExpiresAt = try c.decodeIfPresent(Date.self, forKey: .accessExpiresAt) ?? .distantPast
        deviceId = try c.decodeIfPresent(String.self, forKey: .deviceId)
        vehicleId = try c.decodeIfPresent(String.self, forKey: .vehicleId)
        vehicleVin = try c.decodeIfPresent(String.self, forKey: .vehicleVin)
        selectedFor = try c.decodeIfPresent(String.self, forKey: .selectedFor)
        ccs2 = try c.decodeIfPresent(Int.self, forKey: .ccs2) ?? 0
        controlToken = try c.decodeIfPresent(String.self, forKey: .controlToken)
        controlExpiresAt = try c.decodeIfPresent(Date.self, forKey: .controlExpiresAt) ?? .distantPast
        cci = try c.decodeIfPresent(CCITokens.self, forKey: .cci)
    }

    public static func fingerprint(_ token: String) -> String {
        Digest.sha256Hex(token)
    }
}

/// The token set from the Kia app's current sign-in (the "OneApp"/CCI service).
public struct CCITokens: Codable, Equatable, Sendable {
    public var accessToken: String
    public var exchangeableToken: String
    public var exchangeableRefreshToken: String
    public var nonCcsToken: String
    public var nonCcsRefreshToken: String
    public var idToken: String

    public init(accessToken: String, exchangeableToken: String, exchangeableRefreshToken: String, nonCcsToken: String, nonCcsRefreshToken: String, idToken: String) {
        self.accessToken = accessToken
        self.exchangeableToken = exchangeableToken
        self.exchangeableRefreshToken = exchangeableRefreshToken
        self.nonCcsToken = nonCcsToken
        self.nonCcsRefreshToken = nonCcsRefreshToken
        self.idToken = idToken
    }
}

/// The app implements this over the Keychain. Keep a separate slot for fake-car mode, so the simulator can
/// never overwrite a real (possibly rotated) refresh token.
public protocol KiaSessionStore: Sendable {
    func load() async -> KiaSession?
    func save(_ session: KiaSession?) async
}

public actor InMemoryKiaSessionStore: KiaSessionStore {
    public private(set) var session: KiaSession?

    public init(_ session: KiaSession? = nil) { self.session = session }

    public func load() -> KiaSession? { session }
    public func save(_ session: KiaSession?) { self.session = session }
}
