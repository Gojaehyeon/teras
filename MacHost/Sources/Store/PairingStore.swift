import Foundation
import Security

/// Where pairing secrets live. A protocol so sessions can be tested without
/// touching the login keychain.
protocol SecretStore: AnyObject {
    func secret(forDeviceId deviceId: String) -> Data?
    @discardableResult func save(secret: Data, forDeviceId deviceId: String) -> Bool
    @discardableResult func forget(deviceId: String) -> Bool
}

/// Pairing secrets, one per receiver, in the login keychain.
///
/// A secret is 32 bytes agreed during PAIR and is what proves this Mac to the
/// device on every later connection, so it never goes in user defaults.
final class PairingStore: SecretStore, @unchecked Sendable {
    static let service = "app.tandem.pairing"

    private let service: String

    init(service: String = PairingStore.service) {
        self.service = service
    }

    func secret(forDeviceId deviceId: String) -> Data? {
        var query = baseQuery(deviceId: deviceId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                Log.error(.store, "Keychain read failed for \(deviceId) (status \(status))")
            }
            return nil
        }
        return item as? Data
    }

    @discardableResult
    func save(secret: Data, forDeviceId deviceId: String) -> Bool {
        let query = baseQuery(deviceId: deviceId)
        let attributes: [String: Any] = [kSecValueData as String: secret]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else {
            Log.error(.store, "Keychain update failed for \(deviceId) (status \(updateStatus))")
            return false
        }

        var insert = query
        insert[kSecValueData as String] = secret
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            Log.error(.store, "Keychain insert failed for \(deviceId) (status \(addStatus))")
            return false
        }
        return true
    }

    @discardableResult
    func forget(deviceId: String) -> Bool {
        let status = SecItemDelete(baseQuery(deviceId: deviceId) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Device ids we hold a secret for.
    func pairedDeviceIds() -> [String] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        query[kSecReturnData as String] = false

        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        guard status == errSecSuccess, let entries = items as? [[String: Any]] else { return [] }
        return entries.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    private func baseQuery(deviceId: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceId,
        ]
    }
}


/// In-memory secret store, used by tests and as a fallback if the keychain is
/// unavailable.
final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: Data] = [:]

    init(secrets: [String: Data] = [:]) {
        self.secrets = secrets
    }

    func secret(forDeviceId deviceId: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return secrets[deviceId]
    }

    @discardableResult
    func save(secret: Data, forDeviceId deviceId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        secrets[deviceId] = secret
        return true
    }

    @discardableResult
    func forget(deviceId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        secrets.removeValue(forKey: deviceId)
        return true
    }

    var storedDeviceIds: [String] {
        lock.lock(); defer { lock.unlock() }
        return secrets.keys.sorted()
    }
}
