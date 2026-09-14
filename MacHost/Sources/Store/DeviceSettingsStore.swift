import Foundation
import TandemProtocol

/// What the user chose for one device. Defaults are what most people want:
/// best quality the link allows, 60 fps, HiDPI on, extended (not mirrored).
struct DeviceSettings: Codable, Equatable, Sendable {
    var quality: QualityPreset = .high
    var fps: Int = 60
    var hiDPI: Bool = true
    var mode: DisplayMode = .extend
    var autoConnect: Bool = false
    /// Last name we saw, so paired devices can be listed while offline.
    var lastKnownName: String?

    static let `default` = DeviceSettings()

    /// Frame rates offered in the UI.
    static let supportedFPS = [30, 60]

    var normalizedFPS: Int {
        Self.supportedFPS.contains(fps) ? fps : 60
    }
}

/// Per-device settings, keyed by the endpoint id, in user defaults.
final class DeviceSettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let keyPrefix = "device.settings."
    private let lock = NSLock()
    private var cache: [String: DeviceSettings] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func settings(for deviceKey: String) -> DeviceSettings {
        lock.lock()
        if let cached = cache[deviceKey] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        var value = DeviceSettings.default
        if let data = defaults.data(forKey: keyPrefix + deviceKey),
           let decoded = try? JSONDecoder().decode(DeviceSettings.self, from: data) {
            value = decoded
        }
        lock.lock()
        cache[deviceKey] = value
        lock.unlock()
        return value
    }

    func update(_ deviceKey: String, _ transform: (inout DeviceSettings) -> Void) {
        var value = settings(for: deviceKey)
        transform(&value)
        save(value, for: deviceKey)
    }

    func save(_ settings: DeviceSettings, for deviceKey: String) {
        lock.lock()
        cache[deviceKey] = settings
        lock.unlock()
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: keyPrefix + deviceKey)
    }

    func forget(_ deviceKey: String) {
        lock.lock()
        cache.removeValue(forKey: deviceKey)
        lock.unlock()
        defaults.removeObject(forKey: keyPrefix + deviceKey)
    }
}

/// Application-wide preferences.
enum AppSettings {
    private static let showStatsKey = "app.showStats"
    private static let completedOnboardingKey = "app.completedOnboarding"

    static var showStats: Bool {
        get { UserDefaults.standard.bool(forKey: showStatsKey) }
        set { UserDefaults.standard.set(newValue, forKey: showStatsKey) }
    }

    static var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: completedOnboardingKey) }
        set { UserDefaults.standard.set(newValue, forKey: completedOnboardingKey) }
    }
}
