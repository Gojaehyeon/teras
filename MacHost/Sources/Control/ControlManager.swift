import Combine
import CoreGraphics
import Foundation

/// What the UI shows for Teras Control on one device.
enum ControlStatus: Equatable, Sendable {
    case off
    case starting
    case ready(width: Int, height: Int)
    case captured
    case failed(String)

    var isRunning: Bool {
        switch self {
        case .ready, .captured: return true
        default: return false
        }
    }
}

/// One Android device's control session: the server link plus the edge watcher.
private final class ControlSession {
    let serial: String
    let launcher: ControlServerLauncher
    var edgeController: EdgeController?

    init(serial: String, launcher: ControlServerLauncher) {
        self.serial = serial
        self.launcher = launcher
    }

    func tearDown() {
        edgeController?.stop()
        edgeController = nil
        launcher.stop()
    }
}

/// Owns Teras Control for every attached Android device (CONTROL.md §7).
///
/// The feature is per device and off by default. The choice is remembered, so
/// a phone that had it on gets it back automatically the next time it is
/// plugged in.
@MainActor
final class ControlManager: ObservableObject {
    /// serial → status, for the menu and the Settings tab.
    @Published private(set) var statuses: [String: ControlStatus] = [:]
    /// Serials adb currently reports as authorized Android devices.
    @Published private(set) var availableSerials: [String] = []
    /// Human-readable names, for the Settings list.
    @Published private(set) var names: [String: String] = [:]

    private let adb: AdbBridge
    private let settingsStore: DeviceSettingsStore
    private var sessions: [String: ControlSession] = [:]
    private var starting: Set<String> = []

    /// Settings are filed under the same key the display session uses.
    static func deviceKey(serial: String) -> String { "usb-android:\(serial)" }

    init(adb: AdbBridge, settingsStore: DeviceSettingsStore) {
        self.adb = adb
        self.settingsStore = settingsStore
    }

    /// Whether this build can offer the feature at all.
    var isSupported: Bool { ControlServerLauncher.isAvailable }

    // MARK: - Device tracking

    /// Called with every adb snapshot. Only authorized USB devices can be
    /// controlled, so anything else is dropped and its session torn down.
    func updateDevices(_ devices: [AdbDevice]) {
        let usable = devices.filter { $0.state == .device }
        availableSerials = usable.map(\.serial).sorted()
        for device in usable {
            names[device.serial] = device.displayName
        }

        let present = Set(usable.map(\.serial))
        for serial in Array(sessions.keys) where !present.contains(serial) {
            Log.info(.control, "\(serial) went away; stopping control")
            teardown(serial: serial, status: .off)
        }
        for serial in Array(names.keys) where !present.contains(serial) {
            if statuses[serial] != nil, sessions[serial] == nil { statuses[serial] = nil }
        }

        // Re-enable anything the user had turned on.
        for device in usable where settings(for: device.serial).controlEnabled {
            guard sessions[device.serial] == nil, !starting.contains(device.serial) else { continue }
            enable(serial: device.serial)
        }
    }

    /// Stop everything, e.g. when the app quits.
    func shutdown() {
        for serial in Array(sessions.keys) { teardown(serial: serial, status: .off) }
    }

    // MARK: - Enable / disable

    func isEnabled(serial: String) -> Bool {
        settings(for: serial).controlEnabled
    }

    func status(serial: String) -> ControlStatus {
        statuses[serial] ?? .off
    }

    func setEnabled(_ enabled: Bool, serial: String) {
        settingsStore.update(Self.deviceKey(serial: serial)) { $0.controlEnabled = enabled }
        if enabled {
            enable(serial: serial)
        } else {
            teardown(serial: serial, status: .off)
        }
        objectWillChange.send()
    }

    func toggle(serial: String) {
        setEnabled(!isEnabled(serial: serial), serial: serial)
    }

    func setEdge(_ edge: ControlEdge, serial: String) {
        settingsStore.update(Self.deviceKey(serial: serial)) { $0.controlEdge = edge }
        sessions[serial]?.edgeController?.update(edge: edge)
        objectWillChange.send()
    }

    func setSpeed(_ speed: Double, serial: String) {
        settingsStore.update(Self.deviceKey(serial: serial)) { $0.controlSpeed = speed }
        sessions[serial]?.edgeController?.update(speed: CGFloat(speed))
        objectWillChange.send()
    }

    func settings(for serial: String) -> DeviceSettings {
        settingsStore.settings(for: Self.deviceKey(serial: serial))
    }

    // MARK: - Session lifecycle

    private func enable(serial: String) {
        guard sessions[serial] == nil, !starting.contains(serial) else { return }
        guard ControlServerLauncher.isAvailable else {
            // A build without the jar cannot do anything useful; say so once
            // rather than failing halfway through a push.
            Log.error(.control, "teras-control.jar is not in this build; Teras Control is unavailable")
            statuses[serial] = .failed(L("control.error.notBundled"))
            return
        }
        guard InputInjector.isTrusted() else {
            Log.error(.control, "Accessibility permission is missing; Teras Control cannot watch the cursor")
            statuses[serial] = .failed(L("control.error.accessibility"))
            return
        }

        starting.insert(serial)
        statuses[serial] = .starting
        let launcher = ControlServerLauncher(serial: serial, adb: adb)

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.starting.remove(serial) }
            do {
                let info = try await launcher.start()
                guard self.settings(for: serial).controlEnabled else {
                    // Turned off while we were starting.
                    launcher.stop()
                    return
                }
                self.attach(launcher: launcher, info: info, serial: serial)
            } catch {
                launcher.stop()
                Log.error(.control, "Teras Control could not start on \(serial): \(error.localizedDescription)")
                self.statuses[serial] = .failed(error.localizedDescription)
            }
        }
    }

    private func attach(launcher: ControlServerLauncher, info: ControlDisplayInfo, serial: String) {
        let session = ControlSession(serial: serial, launcher: launcher)
        let deviceSettings = settings(for: serial)

        let controller = EdgeController(serial: serial,
                                        phoneSize: info.size,
                                        edge: deviceSettings.controlEdge,
                                        speed: CGFloat(deviceSettings.normalizedControlSpeed)) { [weak launcher] frames in
            launcher?.send(frames)
        }
        controller.onCaptureChanged = { [weak self] captured in
            Task { @MainActor in
                guard let self, self.sessions[serial] != nil else { return }
                if captured {
                    self.statuses[serial] = .captured
                } else if let size = self.sessions[serial]?.launcher.displayInfo {
                    self.statuses[serial] = .ready(width: size.width, height: size.height)
                }
            }
        }
        controller.onTapFailure = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.statuses[serial] = .failed(L("control.error.accessibility"))
                self.teardown(serial: serial, status: .failed(L("control.error.accessibility")))
            }
        }

        launcher.onDisplayInfo = { [weak self] newInfo in
            Task { @MainActor in
                guard let self, let session = self.sessions[serial] else { return }
                session.edgeController?.update(phoneSize: newInfo.size)
                if self.statuses[serial] != .captured {
                    self.statuses[serial] = .ready(width: newInfo.width, height: newInfo.height)
                }
            }
        }
        launcher.onClosed = { [weak self] reason in
            Task { @MainActor in
                guard let self else { return }
                guard self.sessions[serial] != nil else { return }
                self.teardown(serial: serial, status: .failed(reason))
            }
        }
        launcher.onServerError = { message in
            Log.error(.control, "[\(serial)] \(message)")
        }

        session.edgeController = controller
        sessions[serial] = session

        // The link can drop between `start()` returning and the callbacks being
        // wired above; in that case nothing would ever report it.
        guard launcher.isLive else {
            teardown(serial: serial, status: .failed(L("control.status.linkLost")))
            return
        }

        controller.start()
        statuses[serial] = .ready(width: info.width, height: info.height)
        Log.info(.control, "Teras Control is on for \(serial) (\(info.width)×\(info.height))")
    }

    private func teardown(serial: String, status: ControlStatus) {
        if let session = sessions.removeValue(forKey: serial) {
            session.launcher.onClosed = nil
            session.launcher.onDisplayInfo = nil
            session.tearDown()
        }
        statuses[serial] = status
    }
}
