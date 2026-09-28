import Foundation

/// Kia Connect (UVO) Europe. Nothing here is a published API: these are the Kia app's own public
/// constants, as documented by the open-source hyundai_kia_connect_api project (v4.23), and Kia can
/// change them at any time (HANDOVER.md §3.1).
public struct KiaConfig: Equatable, Sendable {
    public static let apiHost = "prd.eu-ccapi.kia.com"
    public static let idpHost = "idpconnect-eu.kia.com"
    public static let userAgent = "okhttp/3.12.0"

    /// Target temperatures the EU cars accept. Older cars send them as an index into this range.
    public static let minTempC = 14.0
    public static let maxTempC = 29.5

    public var apiBase: String
    public var idpBase: String
    public var serviceId: String
    public var serviceSecret: String
    public var appId: String
    public var cfbBase64: String
    /// How long the car climatises for. Kia requires a duration.
    public var climateMinutes: Int

    public init(
        apiBase: String = "https://\(KiaConfig.apiHost):8080",
        idpBase: String = "https://\(KiaConfig.idpHost)",
        serviceId: String = "fdc85c00-0a2f-4c64-bcb4-2cfb1500730a",
        serviceSecret: String = "secret",
        appId: String = "a2b8469b-30a3-4361-8e13-6fceea8fbe74",
        cfbBase64: String = "wLTVxwidmH8CfJYBWSnHD6E0huk0ozdiuygB4hLkM5XCgzAL1Dk5sE36d/bx5PFMbZs=",
        climateMinutes: Int = 10
    ) {
        self.apiBase = apiBase
        self.idpBase = idpBase
        self.serviceId = serviceId
        self.serviceSecret = serviceSecret
        self.appId = appId
        self.cfbBase64 = cfbBase64
        self.climateMinutes = climateMinutes
    }

    var spa: String { "\(apiBase)/api/v1/spa" }
    var spaV2: String { "\(apiBase)/api/v2/spa" }
    var user: String { "\(apiBase)/api/v1/user" }

    /// The `Stamp` header: `"<appId>:<epochSeconds>"` XORed with a fixed key, base64 (§3.2).
    /// The XOR runs over the shorter of the two, which is the 47-byte plaintext.
    public func stamp(epochSeconds: Int64) -> String {
        let key = Array(Data(base64Encoded: cfbBase64) ?? Data())
        let raw = Array("\(appId):\(epochSeconds)".utf8)
        let out = zip(raw, key).map { $0 ^ $1 }
        return Data(out).base64EncodedString()
    }
}
