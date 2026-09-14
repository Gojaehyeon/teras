import Foundation
import TerasProtocol

/// Quality presets offered in the menu bar. USB has bandwidth to spare, so the
/// presets are generous there; Wi-Fi is capped because anything above ~30 Mbps
/// on 5 GHz costs more in retransmits than it buys in picture quality.
enum QualityPreset: String, Codable, CaseIterable, Sendable {
    case low, medium, high, ultra

    static let `default` = QualityPreset.high

    /// Cap applied on any LAN transport, in megabits per second.
    static let lanCapMbps = 30

    var usbMbps: Int {
        switch self {
        case .low: return 8
        case .medium: return 20
        case .high: return 40
        case .ultra: return 60
        }
    }

    func megabitsPerSecond(transport: Transport) -> Int {
        switch transport {
        case .usb: return usbMbps
        case .lan: return min(usbMbps, Self.lanCapMbps)
        }
    }

    func bitsPerSecond(transport: Transport) -> Int {
        megabitsPerSecond(transport: transport) * 1_000_000
    }

    var localizedName: String {
        switch self {
        case .low: return L("quality.low")
        case .medium: return L("quality.medium")
        case .high: return L("quality.high")
        case .ultra: return L("quality.ultra")
        }
    }
}
