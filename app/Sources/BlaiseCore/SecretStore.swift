import Foundation
import Security
import Synchronization

/// Storage for engine secrets (API keys). **No secret ever lands in SQLite
/// or on disk** — production uses the macOS Keychain; tests use the
/// in-memory store.
public protocol SecretStore: Sendable {
    func get(key: String) throws -> String?
    func set(key: String, value: String) throws
    func delete(key: String) throws
}

public struct SecretStoreError: Error, Equatable, Sendable {
    public let status: OSStatus
    public let operation: String
}

/// macOS Keychain generic password items, service `app.blaise.mac`,
/// account = `engine.<id>.<key>` (same scheme as SettingsStore keys — two
/// engines declaring `apiKey` can never collide).
///
/// Ad-hoc-signing caveat (accepted, documented in the C2 spec): per-build
/// ad-hoc identities may force re-granting Keychain access (or re-entering
/// the secret) after rebuilds on the dev machine.
public struct KeychainSecretStore: SecretStore {
    public static let defaultService = BlaiseBundle.identifier

    public let service: String

    public init(service: String = KeychainSecretStore.defaultService) {
        self.service = service
    }

    public func get(key: String) throws -> String? {
        var query = baseQuery(key: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw SecretStoreError(status: status, operation: "get: unexpected item type")
            }
            return String(decoding: data, as: UTF8.self)
        case errSecItemNotFound:
            return nil
        default:
            throw SecretStoreError(status: status, operation: "get")
        }
    }

    public func set(key: String, value: String) throws {
        let data = Data(value.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(baseQuery(key: key) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(key: key)
            add[kSecValueData as String] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw SecretStoreError(status: status, operation: "set")
        }
    }

    public func delete(key: String) throws {
        let status = SecItemDelete(baseQuery(key: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError(status: status, operation: "delete")
        }
    }

    private func baseQuery(key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}

/// Test double — secrets live only in process memory.
public final class InMemorySecretStore: SecretStore {
    private let storage = Mutex<[String: String]>([:])

    public init() {}

    public func get(key: String) throws -> String? {
        storage.withLock { $0[key] }
    }

    public func set(key: String, value: String) throws {
        storage.withLock { $0[key] = value }
    }

    public func delete(key: String) throws {
        storage.withLock { $0[key] = nil }
    }
}
