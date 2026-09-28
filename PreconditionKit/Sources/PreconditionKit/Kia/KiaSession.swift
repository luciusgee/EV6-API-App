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
        controlExpiresAt: Date = .distantPast
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
    }

    public static func fingerprint(_ token: String) -> String {
        Digest.sha256Hex(token)
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
