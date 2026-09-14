import Foundation

struct PairedHost: Codable, Equatable, Identifiable {
    var id: String          // hostId (UUID string)
    var name: String
    var lastSeen: Date
}

/// Persistence for LAN pairing secrets. The 32-byte secret lives in the
/// keychain; only display metadata goes to `UserDefaults`.
protocol PairingStoring: AnyObject {
    func secret(forHost hostId: String) -> Data?
    func store(secret: Data, hostId: String, hostName: String)
    func touch(hostId: String, hostName: String)
    func forget(hostId: String)
    var pairedHosts: [PairedHost] { get }
}

final class KeychainPairingStore: PairingStoring {
    private let defaultsKey = "app.tandem.receiver.pairedHosts"
    private let lock = NSLock()

    init() {}

    private func account(for hostId: String) -> String { "secret." + hostId }

    func secret(forHost hostId: String) -> Data? {
        guard UUID(uuidString: hostId) != nil || !hostId.isEmpty else { return nil }
        guard let data = Keychain.read(account: account(for: hostId)), data.count == 32 else { return nil }
        return data
    }

    func store(secret: Data, hostId: String, hostName: String) {
        guard secret.count == 32, !hostId.isEmpty else { return }
        Keychain.write(secret, account: account(for: hostId))
        upsertMetadata(hostId: hostId, hostName: hostName)
    }

    func touch(hostId: String, hostName: String) {
        guard !hostId.isEmpty else { return }
        guard secret(forHost: hostId) != nil else { return }
        upsertMetadata(hostId: hostId, hostName: hostName)
    }

    func forget(hostId: String) {
        Keychain.delete(account: account(for: hostId))
        lock.lock()
        var hosts = loadMetadata()
        hosts.removeAll { $0.id == hostId }
        saveMetadata(hosts)
        lock.unlock()
    }

    var pairedHosts: [PairedHost] {
        lock.lock()
        defer { lock.unlock() }
        return loadMetadata().sorted { $0.lastSeen > $1.lastSeen }
    }

    private func upsertMetadata(hostId: String, hostName: String) {
        lock.lock()
        var hosts = loadMetadata()
        hosts.removeAll { $0.id == hostId }
        hosts.append(PairedHost(id: hostId, name: hostName, lastSeen: Date()))
        saveMetadata(hosts)
        lock.unlock()
    }

    private func loadMetadata() -> [PairedHost] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([PairedHost].self, from: data)) ?? []
    }

    private func saveMetadata(_ hosts: [PairedHost]) {
        guard let data = try? JSONEncoder().encode(hosts) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

/// In-memory store used by tests and previews.
final class MemoryPairingStore: PairingStoring {
    private var secrets: [String: Data] = [:]
    private var hosts: [String: PairedHost] = [:]
    private let lock = NSLock()

    init(secrets: [String: Data] = [:]) { self.secrets = secrets }

    func secret(forHost hostId: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return secrets[hostId]
    }
    func store(secret: Data, hostId: String, hostName: String) {
        lock.lock(); defer { lock.unlock() }
        secrets[hostId] = secret
        hosts[hostId] = PairedHost(id: hostId, name: hostName, lastSeen: Date())
    }
    func touch(hostId: String, hostName: String) {
        lock.lock(); defer { lock.unlock() }
        guard secrets[hostId] != nil else { return }
        hosts[hostId] = PairedHost(id: hostId, name: hostName, lastSeen: Date())
    }
    func forget(hostId: String) {
        lock.lock(); defer { lock.unlock() }
        secrets[hostId] = nil
        hosts[hostId] = nil
    }
    var pairedHosts: [PairedHost] {
        lock.lock(); defer { lock.unlock() }
        return hosts.values.sorted { $0.lastSeen > $1.lastSeen }
    }
}
