import Foundation
import Security

/// The install's anonymous id: made once, then kept in the Keychain, where it
/// stays on this device and is never synced. The server counts supporters by
/// it until a user signs in.
@MainActor
enum InstallID {
    private static let service = "com.distilar.sdk"
    private static let account = "install-id"
    /// Used only when the Keychain refuses, such as in an unsigned build.
    private static let fallbackKey = "com.distilar.install-id"

    static func current() -> String {
        if let id = read() {
            return id
        }
        let id = UUID().uuidString.lowercased()
        switch SecItemAdd(query(adding: id) as CFDictionary, nil) {
        case errSecSuccess:
            return id
        case errSecDuplicateItem:
            return read() ?? fallback()
        default:
            return fallback()
        }
    }

    private static func read() -> String? {
        var query = query()
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)?.nilIfEmpty
    }

    private static func query(adding id: String? = nil) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: false,
            kSecUseDataProtectionKeychain: true,
        ]
        if let id {
            query[kSecValueData] = Data(id.utf8)
            query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        return query
    }

    private static func fallback() -> String {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: fallbackKey) {
            return id
        }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: fallbackKey)
        return id
    }
}
