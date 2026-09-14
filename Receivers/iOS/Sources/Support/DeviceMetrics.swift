import Foundation
import UIKit
import VideoToolbox
import CoreMedia
import TandemProtocol

/// Everything the receiver reports about itself in HELLO_ACK (PROTOCOL §3.2).
/// Built on the main actor, then handed to the connection queue as a value.
struct DeviceDescriptor: Equatable {
    var deviceId: String
    var deviceName: String
    var model: String
    var screen: ScreenInfo
    var orientation: Orientation
    var codecs: [Codec]
    var maxDecode: Size
    var features: [String]
}

/// A value snapshot shared across threads. The UI writes it on the main
/// actor; the connection queue reads it when building HELLO_ACK.
final class DeviceDescriptorBox: @unchecked Sendable {
    private var value: DeviceDescriptor
    private let lock = NSLock()

    init(_ value: DeviceDescriptor) { self.value = value }

    var current: DeviceDescriptor {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

enum DeviceMetrics {
    /// Hardware model identifier, e.g. `iPhone16,1`. On the simulator this is
    /// the host architecture, so fall back to the simulated model name.
    static let modelIdentifier: String = {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty {
            return simulated
        }
        var info = utsname()
        guard uname(&info) == 0 else { return "unknown" }
        let machine = info.machine
        let identifier = withUnsafeBytes(of: machine) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return identifier.isEmpty ? "unknown" : identifier
    }()

    @MainActor
    static var systemDeviceName: String {
        UIDevice.current.name
    }

    /// Codec preference order, hardware decode first.
    static let supportedCodecs: [Codec] = {
        var codecs: [Codec] = []
        if VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) { codecs.append(.hevc) }
        if VTIsHardwareDecodeSupported(kCMVideoCodecType_H264) { codecs.append(.h264) }
        if codecs.isEmpty {
            // Software decode still works through AVSampleBufferDisplayLayer.
            codecs = [.h264]
        }
        return codecs
    }()

    static let maxDecode = Size(w: 4096, h: 2304)

    @MainActor
    static func features(for scene: UIWindowScene?) -> [String] {
        var features = ["touch", "keyboard", "scroll"]
        if UIDevice.current.userInterfaceIdiom == .pad {
            features.append("pencil")
            // Indirect pointer (trackpad/mouse) hover is an iPadOS capability.
            features.append("hover")
        }
        return features
    }

    /// Orientation of the active scene, defaulting to portrait when unknown.
    @MainActor
    static func orientation(for scene: UIWindowScene?) -> Orientation {
        switch scene?.interfaceOrientation {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        // UIInterfaceOrientationLandscapeLeft means the home button is on the
        // left, i.e. the device is rotated right. We report the interface
        // orientation verbatim; the host only uses it for layout hints.
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        default: return .portrait
        }
    }

    /// Physical-pixel screen geometry in the *current* orientation.
    /// `UIScreen.nativeBounds` is always portrait-relative, so it is swapped
    /// when the interface is landscape.
    @MainActor
    static func screenInfo(for scene: UIWindowScene?, window: UIWindow?) -> ScreenInfo {
        let screen = scene?.screen ?? fallbackScreen()
        let scale = screen.nativeScale > 0 ? screen.nativeScale : max(screen.scale, 1)
        let native = screen.nativeBounds.size
        let orientation = orientation(for: scene)
        let wPx: Int
        let hPx: Int
        if orientation.isLandscape {
            wPx = Int(max(native.width, native.height).rounded())
            hPx = Int(min(native.width, native.height).rounded())
        } else {
            wPx = Int(min(native.width, native.height).rounded())
            hPx = Int(max(native.width, native.height).rounded())
        }

        let insets = window?.safeAreaInsets ?? .zero
        let safe = SafeInsets(top: Double((insets.top * scale).rounded()),
                              bottom: Double((insets.bottom * scale).rounded()),
                              left: Double((insets.left * scale).rounded()),
                              right: Double((insets.right * scale).rounded()))

        let refresh = Double(screen.maximumFramesPerSecond)
        return ScreenInfo(wPx: wPx, hPx: hPx, scale: Double(scale),
                          refreshHz: refresh > 0 ? refresh : 60, safeInsets: safe)
    }

    @MainActor
    private static func fallbackScreen() -> UIScreen {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let screen = scenes.first?.screen { return screen }
        return UIScreen.main
    }

    @MainActor
    static func descriptor(name: String, scene: UIWindowScene?, window: UIWindow?) -> DeviceDescriptor {
        DeviceDescriptor(deviceId: DeviceIdentity.deviceId,
                         deviceName: name,
                         model: modelIdentifier,
                         screen: screenInfo(for: scene, window: window),
                         orientation: orientation(for: scene),
                         codecs: supportedCodecs,
                         maxDecode: maxDecode,
                         features: features(for: scene))
    }
}
