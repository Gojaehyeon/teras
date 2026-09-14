import Foundation

/// Stable, per-install receiver identity (PROTOCOL §3.2 `deviceId`).
///
/// Stored in the keychain so it survives app updates; mirrored into
/// `UserDefaults` so a keychain failure (locked device, simulator quirks)
/// still yields a stable id for the lifetime of the install.
enum DeviceIdentity {
    private static let account = "deviceId"
    private static let defaultsKey = "app.teras.receiver.deviceId"
    private static let lock = NSLock()
    private static var cached: String?

    static var deviceId: String {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }

        if let data = Keychain.read(account: account),
           let text = String(data: data, encoding: .utf8),
           UUID(uuidString: text) != nil {
            cached = text
            UserDefaults.standard.set(text, forKey: defaultsKey)
            return text
        }
        if let text = UserDefaults.standard.string(forKey: defaultsKey), UUID(uuidString: text) != nil {
            cached = text
            Keychain.write(Data(text.utf8), account: account)
            return text
        }
        let fresh = UUID().uuidString
        cached = fresh
        Keychain.write(Data(fresh.utf8), account: account)
        UserDefaults.standard.set(fresh, forKey: defaultsKey)
        return fresh
    }
}
