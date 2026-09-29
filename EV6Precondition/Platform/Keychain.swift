import Foundation
import PreconditionKit
import Security

/// Generic-password items in the Keychain. Readable after the first unlock, so background wakes
/// (geofences, Shortcuts) can read them; never synced or backed up off the device (HANDOVER.md §5).
struct Keychain: Sendable {
    let service: String

    func data(for account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    /// `nil` deletes the item.
    func set(_ data: Data?, for account: String) {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        guard let data else {
            SecItemDelete(identity as CFDictionary)
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let item = identity.merging(attributes) { _, new in new }
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    func value<T: Decodable>(_ type: T.Type, for account: String) -> T? {
        data(for: account).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    func setValue<T: Encodable>(_ value: T?, for account: String) {
        set(value.flatMap { try? JSONEncoder().encode($0) }, for: account)
    }
}

/// The refresh token, PIN and VIN.
actor KeychainCredentialsStore: CredentialsStore {
    private let keychain = Keychain(service: "EV6Precondition.credentials")

    func credentials() -> Credentials? {
        keychain.value(Credentials.self, for: "kia")
    }

    func save(_ credentials: Credentials?) {
        keychain.setValue(credentials, for: "kia")
    }
}

/// The Kia login (access and control tokens, device id, chosen car).
actor KeychainSessionStore: KiaSessionStore {
    private let keychain = Keychain(service: "EV6Precondition.session")
    private let account: String

    init(account: String) {
        self.account = account
    }

    func load() -> KiaSession? {
        keychain.value(KiaSession.self, for: account)
    }

    func save(_ session: KiaSession?) {
        keychain.setValue(session, for: account)
    }
}

/// API keys the owner adds for charger data: Open Charge Map (free) and Google Places (optional).
enum ChargerKeys {
    private static let keychain = Keychain(service: "EV6Precondition.keys")

    static var openChargeMap: String? {
        get { keychain.data(for: "openchargemap").map { String(decoding: $0, as: UTF8.self) }.flatMap { $0.isEmpty ? nil : $0 } }
        set { keychain.set(newValue.flatMap { $0.isEmpty ? nil : Data($0.utf8) }, for: "openchargemap") }
    }

    static var google: String? {
        get { keychain.data(for: "google").map { String(decoding: $0, as: UTF8.self) }.flatMap { $0.isEmpty ? nil : $0 } }
        set { keychain.set(newValue.flatMap { $0.isEmpty ? nil : Data($0.utf8) }, for: "google") }
    }
}
