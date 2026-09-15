import Foundation
import TerasProtocol

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

    // MARK: - Teras Control (Android only)

    /// Whether the cursor may cross onto this phone (CONTROL.md §7). Off by
    /// default; the user turns it on per device.
    var controlEnabled: Bool = false
    /// Which side of the desktop the phone is attached to.
    var controlEdge: ControlEdge = .right
    /// Phone pixels per Mac point while captured.
    var controlSpeed: Double = 1.5

    static let `default` = DeviceSettings()

    /// Frame rates offered in the UI.
    static let supportedFPS = [30, 60]

    /// The range the pointer speed slider offers.
    static let controlSpeedRange: ClosedRange<Double> = 0.5...3.0

    var normalizedFPS: Int {
        Self.supportedFPS.contains(fps) ? fps : 60
    }

    var normalizedControlSpeed: Double {
        min(max(controlSpeed, Self.controlSpeedRange.lowerBound), Self.controlSpeedRange.upperBound)
    }

    // Decoded field by field so settings saved by an older build — which had
    // no control keys — still load instead of falling back to the defaults.
    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        quality = try container.decodeIfPresent(QualityPreset.self, forKey: .quality) ?? .high
        fps = try container.decodeIfPresent(Int.self, forKey: .fps) ?? 60
        hiDPI = try container.decodeIfPresent(Bool.self, forKey: .hiDPI) ?? true
        mode = try container.decodeIfPresent(DisplayMode.self, forKey: .mode) ?? .extend
        autoConnect = try container.decodeIfPresent(Bool.self, forKey: .autoConnect) ?? false
        lastKnownName = try container.decodeIfPresent(String.self, forKey: .lastKnownName)
        controlEnabled = try container.decodeIfPresent(Bool.self, forKey: .controlEnabled) ?? false
        controlEdge = try container.decodeIfPresent(ControlEdge.self, forKey: .controlEdge) ?? .right
        controlSpeed = try container.decodeIfPresent(Double.self, forKey: .controlSpeed) ?? 1.5
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
