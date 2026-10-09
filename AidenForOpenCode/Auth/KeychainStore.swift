import Foundation
import KeychainAccess

protocol KeychainStoring {
    func save(_ value: String, forKey key: KeychainStore.Key) throws
    func load(_ key: KeychainStore.Key) throws -> String?
    func delete(_ key: KeychainStore.Key) throws

    // A server password is scoped to the installation id it belongs to.
    // Switching or removing one paired server must never read or clear
    // another installation's credential.
    func save(_ value: String, forKey key: KeychainStore.Key, scope: String) throws
    func load(_ key: KeychainStore.Key, scope: String) throws -> String?
    func delete(_ key: KeychainStore.Key, scope: String) throws
}

struct KeychainStore: KeychainStoring {
    enum Key: String {
        // Installation metadata and the active installation live in one
        // Keychain snapshot under the OpenCode V2 namespace. Passwords are
        // stored as separately scoped entries keyed by installation id, so
        // switching or removing one installation cannot expose or delete
        // another installation's credential. Retired Aiden-remote-v1 data
        // lives under different keys and is intentionally not migrated.
        case installations = "opencode_installations_v1"
        case credential = "opencode_credential_v1"
    }

    private let keychain: Keychain

    init(service: String? = nil) {
        let service = service
            ?? Bundle.main.object(forInfoDictionaryKey: "AidenKeychainService") as? String
            ?? Bundle.main.bundleIdentifier
            ?? "sbtbiswas.AidenForOpenCode.pairing"
        self.keychain = Keychain(service: service)
            .accessibility(.afterFirstUnlockThisDeviceOnly)
    }

    func save(_ value: String, forKey key: Key) throws {
        try keychain.set(value, key: key.rawValue)
    }

    func load(_ key: Key) throws -> String? {
        try keychain.get(key.rawValue)
    }

    func delete(_ key: Key) throws {
        try keychain.remove(key.rawValue)
    }

    func save(_ value: String, forKey key: Key, scope: String) throws {
        try keychain.set(value, key: Self.scopedKey(key, scope: scope))
    }

    func load(_ key: Key, scope: String) throws -> String? {
        try keychain.get(Self.scopedKey(key, scope: scope))
    }

    func delete(_ key: Key, scope: String) throws {
        try keychain.remove(Self.scopedKey(key, scope: scope))
    }

    /// Namespaces a logical key by an installation scope. `::` cannot appear in
    /// the fixed lowercase key names, so the representation is unambiguous.
    static func scopedKey(_ key: Key, scope: String) -> String {
        "\(key.rawValue)::\(scope)"
    }
}
