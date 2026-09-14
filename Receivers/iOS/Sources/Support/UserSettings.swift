import Foundation
import Combine

/// User-visible preferences. Small enough to live in `UserDefaults`.
@MainActor
final class UserSettings: ObservableObject {
    private enum Keys {
        static let deviceNameOverride = "app.teras.receiver.deviceNameOverride"
        static let showStats = "app.teras.receiver.showStats"
    }

    private let defaults: UserDefaults

    @Published var deviceNameOverride: String {
        didSet {
            let trimmed = deviceNameOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                defaults.removeObject(forKey: Keys.deviceNameOverride)
            } else {
                defaults.set(trimmed, forKey: Keys.deviceNameOverride)
            }
        }
    }

    @Published var showStats: Bool {
        didSet { defaults.set(showStats, forKey: Keys.showStats) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.deviceNameOverride = defaults.string(forKey: Keys.deviceNameOverride) ?? ""
        self.showStats = defaults.bool(forKey: Keys.showStats)
    }

    /// The name advertised over Bonjour and reported in HELLO_ACK.
    var effectiveDeviceName: String {
        let trimmed = deviceNameOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? DeviceMetrics.systemDeviceName : trimmed
    }
}
