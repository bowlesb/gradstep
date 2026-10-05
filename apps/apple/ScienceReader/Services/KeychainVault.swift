import Foundation
import Security

enum VaultError: Error { case status(OSStatus) }

enum KeychainVault {
    static let service = "com.sciencereader.ios"

    static func read(_ name: String) throws -> Data? {
        var query = base(name)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw VaultError.status(status) }
        return result as? Data
    }

    static func write(_ data: Data, name: String) throws {
        let query = base(name)
        let changes: [CFString: Any] = [kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            for (key, value) in changes { insert[key] = value }
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw VaultError.status(status) }
    }

    static func delete(_ name: String) throws {
        let status = SecItemDelete(base(name) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultError.status(status) }
    }

    /// Deletes every item of this app whose name contains `fragment` (for
    /// example one account's keys after the account is deleted).
    static func deleteAll(namesContaining fragment: String) throws {
        guard !fragment.isEmpty else { return }
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrSynchronizable: false,
                                      kSecUseDataProtectionKeychain: true, kSecReturnAttributes: true, kSecMatchLimit: kSecMatchLimitAll]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess else { throw VaultError.status(status) }
        for item in result as? [[CFString: Any]] ?? [] {
            if let name = item[kSecAttrAccount] as? String, name.contains(fragment) { try delete(name) }
        }
    }

    private static func base(_ name: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: name,
         kSecAttrSynchronizable: false, kSecUseDataProtectionKeychain: true]
    }
}
