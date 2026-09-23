import Foundation
import Security

/// Minimal generic-password Keychain wrapper (SPEC §39: session secrets live in the Keychain).
/// Items use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so background refresh can read them
/// and they never migrate to other devices / backups.
///
/// Item layout: `kSecClassGenericPassword`, `kSecAttrService` = `service`, `kSecAttrAccount` = key.
/// Values are never logged; errors carry only the `OSStatus`.
struct KeychainStore: Sendable {
    let service: String

    init(service: String = "ai.nemut.FANBOXClient.session") {
        self.service = service
    }

    /// Stores `data` under `key` (update-or-add).
    func set(_ data: Data, for key: String) throws {
        let query = baseQuery(for: key)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(attributes) { _, new in new }
            status = SecItemAdd(add as CFDictionary, nil)
            if status == errSecDuplicateItem {
                // Lost a race with another writer: fall back to update.
                status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            }
        }
        guard status == errSecSuccess else {
            AppLog.security.error("keychain set failed: status \(status, privacy: .public)")
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Returns the data stored under `key`, or nil when there is no such item.
    func data(for key: String) throws -> Data? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            AppLog.security.error("keychain read failed: status \(status, privacy: .public)")
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Deletes the item for `key`. Missing items are not an error.
    func remove(_ key: String) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            AppLog.security.error("keychain delete failed: status \(status, privacy: .public)")
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// All keys (`kSecAttrAccount`) stored under this service, sorted.
    func allKeys() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            let items = (result as? [[String: Any]]) ?? []
            return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
        case errSecItemNotFound:
            return []
        default:
            AppLog.security.error("keychain list failed: status \(status, privacy: .public)")
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Deletes every item of this service (account removal of all data / tests).
    func removeAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            AppLog.security.error("keychain delete-all failed: status \(status, privacy: .public)")
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: - Convenience

    func setString(_ value: String, for key: String) throws {
        try set(Data(value.utf8), for: key)
    }

    func string(for key: String) throws -> String? {
        try data(for: key).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}

enum KeychainError: Error, Sendable, Equatable {
    case unexpectedStatus(Int32)
}
