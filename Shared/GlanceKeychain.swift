import Foundation
import Security

/// Hands the `CarGlance` from the app to its widgets through a Keychain access group both are signed
/// for (no App Group needed). Readable after the first unlock, so Lock Screen widgets can show it.
enum GlanceKeychain {
    private static let service = "EV6Precondition.glance"
    private static let account = "glance"

    /// "<team id>.com.luciusgee.ev6precondition.shared", from the Info.plist; nil in unsigned builds.
    private static var accessGroup: String? {
        guard let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String,
              !prefix.isEmpty, !prefix.hasPrefix("$(") else { return nil }
        return prefix + "com.luciusgee.ev6precondition.shared"
    }

    private static var identity: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    static func load() -> CarGlance? {
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(CarGlance.self, from: data)
    }

    static func save(_ glance: CarGlance?) {
        guard let glance, let data = try? JSONEncoder().encode(glance) else {
            SecItemDelete(identity as CFDictionary)
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if SecItemUpdate(identity as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            SecItemAdd(identity.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
    }
}
