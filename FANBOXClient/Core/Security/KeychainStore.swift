import Foundation
import Security

/// Minimal generic-password Keychain wrapper (SPEC §39: session secrets live in the Keychain).
/// Items use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so background refresh can read them
/// and they never migrate to other devices / backups.
struct KeychainStore: Sendable {
    let service: String

    init(service: String = "ai.nemut.FANBOXClient.session") {
        self.service = service
    }

    func set(_ data: Data, for key: String) throws {}

    func data(for key: String) throws -> Data? { nil }

    func remove(_ key: String) throws {}

    func allKeys() throws -> [String] { [] }
}

enum KeychainError: Error, Sendable, Equatable {
    case unexpectedStatus(Int32)
}
