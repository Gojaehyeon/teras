import Combine
import Foundation
import CoreGraphics
import Network
import TerasProtocol

/// What the UI shows next to a device.
enum DeviceStatus: Equatable, Sendable {
    case idle
    case connecting
    /// Reachable, but nothing is listening: the receiver app is not open yet.
    case waitingForApp
    /// Android device that has not accepted this Mac's USB debugging key.
    case unauthorized
    case pairing(attemptsLeft: Int)
    case negotiating
    case streaming(fps: Int)
    case failed(String)
}

/// One row in the menu.
struct DeviceRow: Identifiable, Equatable, Sendable {
    var id: String
    var endpoint: TerasEndpoint
    var status: DeviceStatus = .idle
    var stats: Stats?
    var rttMs: Double = 0
    var captureMethod: String = ""

    var name: String { endpoint.displayName }
    var isConnected: Bool { if case .streaming = status { return true } else { return false } }
}

/// A pairing code the user has to type in.
struct PINRequest: Identifiable, Equatable, Sendable {
    var id: String
    var deviceName: String
    var attemptsLeft: Int
}

/// Owns discovery and every live session.
///
/// USB devices connect by themselves as soon as they appear and keep retrying
/// while they are plugged in, because the receiver app is often not running
/// yet. Network devices connect when the user asks, or automatically when they
/// have been marked as trusted for that.
@MainActor
final class SessionManager: ObservableObject {
    @Published private(set) var usbDevices: [DeviceRow] = []
    @Published private(set) var lanDevices: [DeviceRow] = []
    @Published private(set) var isBrowsingLAN = false
    @Published var pinRequest: PINRequest?

    let adb = AdbBridge()
    let pairingStore = PairingStore()
    let settingsStore = DeviceSettingsStore()

    private let lanBrowser = LanBrowser()
    private var rows: [String: DeviceRow] = [:]
    private var sessions: [String: DisplaySession] = [:]
    private var connecting: Set<String> = []
    private var watchTasks: [Task<Void, Never>] = []
    private var retryTimer: Timer?
    private var started = false

    /// How often an attached-but-not-listening USB device is retried.
    private static let retryInterval: TimeInterval = 2
    /// Prompt for Screen Recording once per launch, not on every retry tick.
    private var screenRecordingRequested = false

    var activeSessionCount: Int {
        sessions.values.filter { $0.state.isStreaming }.count
    }

    var allDevices: [DeviceRow] { usbDevices + lanDevices }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        Log.info(.app, "Teras host \(HostIdentity.appInfo.version) starting as \(HostIdentity.hostId)")

        startUSBiOSWatch()
        startAndroidWatch()
        startLANBrowsing()

        let timer = Timer.scheduledTimer(withTimeInterval: Self.retryInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.retryPass() }
        }
        timer.tolerance = 0.5
        retryTimer = timer
    }

    func shutdown() {
        retryTimer?.invalidate()
        retryTimer = nil
        watchTasks.forEach { $0.cancel() }
        watchTasks.removeAll()
        lanBrowser.stop()
        for session in sessions.values {
            session.stop(reason: "the Mac app is quitting")
        }
        sessions.removeAll()
        adb.killServer()
        started = false
    }

    // MARK: - Discovery: iOS over USB

    private func startUSBiOSWatch() {
        guard UsbmuxClient.isAvailable else {
            Log.error(.transport, "usbmuxd is not present; iPhone and iPad over USB is unavailable")
            return
        }
        let task = Task { [weak self] in
            for await event in UsbmuxClient.watch() {
                guard let self else { return }
                switch event {
                case .attached(let device) where device.isUSB:
                    await self.handleiOSAttached(device)
                case .detached(let deviceID):
                    await self.handleiOSDetached(deviceID)
                default:
                    break
                }
            }
        }
        watchTasks.append(task)
    }

    private func handleiOSAttached(_ device: UsbmuxDevice) async {
        let fallbackName = settingsStore.settings(for: "usb-ios:\(device.udid)").lastKnownName
            ?? String(device.udid.suffix(6))
        var endpoint = TerasEndpoint.usbIOS(udid: device.udid, deviceID: device.deviceID, name: fallbackName)
        upsert(endpoint, status: .connecting)
        connect(endpoint)

        // The real name needs a round trip to lockdownd, so fill it in after.
        if let name = try? await UsbmuxClient.deviceName(deviceID: device.deviceID), !name.isEmpty {
            endpoint = .usbIOS(udid: device.udid, deviceID: device.deviceID, name: name)
            settingsStore.update(endpoint.id) { $0.lastKnownName = name }
            if var row = rows[endpoint.id] {
                row.endpoint = endpoint
                rows[endpoint.id] = row
                publish()
            }
        }
    }

    private func handleiOSDetached(_ deviceID: UInt32) async {
        let matches = rows.values.filter {
            if case .usbIOS(_, let id, _) = $0.endpoint { return id == deviceID }
            return false
        }
        for row in matches {
            sessions[row.id]?.stop(reason: "the device was unplugged")
            sessions.removeValue(forKey: row.id)
            rows.removeValue(forKey: row.id)
            Log.info(.transport, "\(row.name) was unplugged")
        }
        publish()
    }

    // MARK: - Discovery: Android over USB

    private func startAndroidWatch() {
        guard adb.isInstalled else {
            Log.info(.transport, "adb was not found; Android over USB is unavailable until it is installed")
            return
        }
        adb.startServer()
        let stream = adb.watch()
        let task = Task { [weak self] in
            for await devices in stream {
                guard let self else { return }
                await MainActor.run { self.applyAndroidSnapshot(devices) }
            }
        }
        watchTasks.append(task)
    }

    private func applyAndroidSnapshot(_ devices: [AdbDevice]) {
        let seen = Set(devices.map { "usb-android:\($0.serial)" })

        // Drop devices that are gone.
        for (key, row) in rows where key.hasPrefix("usb-android:") && !seen.contains(key) {
            sessions[key]?.stop(reason: "the device was unplugged")
            sessions.removeValue(forKey: key)
            rows.removeValue(forKey: key)
            Log.info(.transport, "\(row.name) was unplugged")
        }

        for device in devices {
            let endpoint = TerasEndpoint.usbAndroid(serial: device.serial, model: device.model ?? device.serial)
            switch device.state {
            case .device:
                let existing = rows[endpoint.id]
                upsert(endpoint, status: existing?.status.isLive == true ? existing!.status : .connecting)
                connect(endpoint)
            case .unauthorized:
                upsert(endpoint, status: .unauthorized)
            default:
                upsert(endpoint, status: .failed(L("status.deviceState", device.state.rawValue)))
            }
        }
        publish()
    }

    // MARK: - Discovery: LAN

    private func startLANBrowsing() {
        lanBrowser.onPeersChanged = { [weak self] peers in
            Task { @MainActor in self?.applyLANPeers(peers) }
        }
        lanBrowser.onFailure = { [weak self] _ in
            Task { @MainActor in self?.isBrowsingLAN = false }
        }
        lanBrowser.start()
        isBrowsingLAN = true
    }

    private func applyLANPeers(_ peers: [LanPeer]) {
        let seen = Set(peers.map { "lan:\($0.deviceId)" })
        for (key, _) in rows where key.hasPrefix("lan:") && !seen.contains(key) {
            guard sessions[key] == nil else { continue }
            rows.removeValue(forKey: key)
        }
        for peer in peers {
            let endpoint = TerasEndpoint.lan(peer: peer)
            let existing = rows[endpoint.id]
            upsert(endpoint, status: existing?.status ?? .idle)
            if existing == nil || existing?.status == .idle,
               settingsStore.settings(for: endpoint.id).autoConnect {
                connect(endpoint)
            }
        }
        isBrowsingLAN = lanBrowser.isBrowsing
        publish()
    }

    // MARK: - Connecting

    func connect(_ endpoint: TerasEndpoint) {
        guard sessions[endpoint.id] == nil, !connecting.contains(endpoint.id) else { return }
        // Without Screen Recording every session would create a virtual display,
        // fail to capture it and tear it down again two seconds later — the
        // Mac's screens flicker on each reconfiguration. Hold the device in
        // `failed` until the permission exists; the retry timer re-checks.
        guard CGPreflightScreenCaptureAccess() else {
            if !screenRecordingRequested {
                screenRecordingRequested = true
                Log.error(.session, "Screen Recording permission missing; not dialing \(endpoint.id)")
                _ = CGRequestScreenCaptureAccess()
            }
            setStatus(.failed(L("status.needsScreenRecording")), for: endpoint.id)
            return
        }
        connecting.insert(endpoint.id)
        setStatus(.connecting, for: endpoint.id)

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.connecting.remove(endpoint.id) }
            do {
                let dialed = try await Dialer.dial(endpoint, adb: self.adb)
                guard self.rows[endpoint.id] != nil else {
                    // Unplugged while we were dialing.
                    dialed.close()
                    return
                }
                let channel = PeerConnection(connection: dialed.connection)
                let session = DisplaySession(endpoint: endpoint,
                                             channel: channel,
                                             transport: dialed.transport,
                                             dependencies: .live(pairingStore: self.pairingStore,
                                                                 settingsStore: self.settingsStore))
                self.wire(session, endpoint: endpoint, dialed: dialed)
                self.sessions[endpoint.id] = session
                session.start()
            } catch {
                self.handleDialFailure(error, endpoint: endpoint)
            }
        }
    }

    private func wire(_ session: DisplaySession, endpoint: TerasEndpoint, dialed: DialedConnection) {
        session.onStateChange = { [weak self] state in
            guard let self else { return }
            switch state {
            case .handshaking, .authenticating, .pairing, .configuring:
                self.setStatus(.negotiating, for: endpoint.id)
            case .awaitingPIN(let attemptsLeft):
                self.setStatus(.pairing(attemptsLeft: attemptsLeft), for: endpoint.id)
                self.pinRequest = PINRequest(id: endpoint.id,
                                             deviceName: endpoint.displayName,
                                             attemptsLeft: attemptsLeft)
            case .streaming:
                let fps = session.spec?.refreshHz ?? 60
                self.setStatus(.streaming(fps: fps), for: endpoint.id)
                if self.pinRequest?.id == endpoint.id { self.pinRequest = nil }
            case .failed(let reason):
                self.setStatus(.failed(reason), for: endpoint.id)
            case .closed:
                break
            }
        }
        session.onStatsChange = { [weak self] stats in
            guard let self, var row = self.rows[endpoint.id] else { return }
            row.stats = stats
            row.rttMs = session.rttMs
            row.captureMethod = session.captureMethod
            self.rows[endpoint.id] = row
            self.publish()
        }
        session.onFinished = { [weak self] finalState in
            guard let self else { return }
            dialed.close()
            self.sessions.removeValue(forKey: endpoint.id)
            if self.pinRequest?.id == endpoint.id { self.pinRequest = nil }
            guard self.rows[endpoint.id] != nil else { return }
            switch finalState {
            case .failed(let reason):
                self.setStatus(.failed(reason), for: endpoint.id)
            default:
                // Still plugged in: go back to waiting so the retry pass picks
                // it up when the receiver app comes back.
                self.setStatus(endpoint.isUSB ? .waitingForApp : .idle, for: endpoint.id)
            }
        }
    }

    private func handleDialFailure(_ error: Error, endpoint: TerasEndpoint) {
        guard rows[endpoint.id] != nil else { return }
        if Self.isConnectionRefused(error) {
            // Normal while the receiver app is not open. Stay quiet about it.
            setStatus(endpoint.isUSB ? .waitingForApp : .idle, for: endpoint.id)
            return
        }
        Log.error(.session, "Could not reach \(endpoint.displayName): \(error.localizedDescription)")
        setStatus(.failed(error.localizedDescription), for: endpoint.id)
    }

    /// Nothing listening on the far end. Distinguished from a real failure so
    /// the UI can say "waiting for the app" instead of showing an error.
    static func isConnectionRefused(_ error: Error) -> Bool {
        if let usbmux = error as? UsbmuxError, case .failed(.connectionRefused) = usbmux { return true }
        if let dialer = error as? DialerError, case .notReady(let detail) = dialer {
            let lowered = detail.lowercased()
            return lowered.contains("refused") || lowered.contains("econnrefused")
        }
        if let dialer = error as? DialerError, case .timedOut = dialer { return true }
        return false
    }

    /// Retry USB devices that are attached but have no session.
    private func retryPass() {
        for row in rows.values where row.endpoint.isUSB {
            guard sessions[row.id] == nil, !connecting.contains(row.id) else { continue }
            switch row.status {
            case .waitingForApp, .idle, .failed:
                connect(row.endpoint)
            default:
                break
            }
        }
    }

    // MARK: - User actions

    func disconnect(_ deviceKey: String) {
        sessions[deviceKey]?.stop(reason: "the user disconnected this device")
        sessions.removeValue(forKey: deviceKey)
        setStatus(.idle, for: deviceKey)
    }

    func toggleConnection(_ row: DeviceRow) {
        if sessions[row.id] != nil {
            disconnect(row.id)
        } else {
            connect(row.endpoint)
        }
    }

    func submitPIN(_ pin: String, for deviceKey: String) {
        sessions[deviceKey]?.providePIN(pin)
        pinRequest = nil
    }

    func cancelPIN(for deviceKey: String) {
        sessions[deviceKey]?.stop(reason: "pairing was cancelled")
        pinRequest = nil
    }

    func setQuality(_ quality: QualityPreset, for deviceKey: String) {
        settingsStore.update(deviceKey) { $0.quality = quality }
        sessions[deviceKey]?.applyQuality(quality)
    }

    func setFPS(_ fps: Int, for deviceKey: String) {
        settingsStore.update(deviceKey) { $0.fps = fps }
        sessions[deviceKey]?.reconfigure()
    }

    func setHiDPI(_ enabled: Bool, for deviceKey: String) {
        settingsStore.update(deviceKey) { $0.hiDPI = enabled }
        sessions[deviceKey]?.reconfigure()
    }

    func setMode(_ mode: DisplayMode, for deviceKey: String) {
        settingsStore.update(deviceKey) { $0.mode = mode }
        sessions[deviceKey]?.reconfigure()
    }

    func settings(for deviceKey: String) -> DeviceSettings {
        settingsStore.settings(for: deviceKey)
    }

    /// Devices we hold a pairing secret for, whether or not they are visible.
    func pairedDevices() -> [(deviceId: String, name: String)] {
        pairingStore.pairedDeviceIds().map { deviceId in
            let name = settingsStore.settings(for: "lan:\(deviceId)").lastKnownName ?? deviceId
            return (deviceId, name)
        }
    }

    func forgetPairing(deviceId: String) {
        pairingStore.forget(deviceId: deviceId)
        let key = "lan:\(deviceId)"
        settingsStore.update(key) { $0.autoConnect = false }
        if sessions[key] != nil { disconnect(key) }
        objectWillChange.send()
    }

    // MARK: - Row bookkeeping

    private func upsert(_ endpoint: TerasEndpoint, status: DeviceStatus) {
        if var existing = rows[endpoint.id] {
            existing.endpoint = endpoint
            existing.status = status
            rows[endpoint.id] = existing
        } else {
            rows[endpoint.id] = DeviceRow(id: endpoint.id, endpoint: endpoint, status: status)
            Log.info(.transport, "Found \(endpoint.displayName) over \(endpoint.transport.rawValue)")
        }
        publish()
    }

    private func setStatus(_ status: DeviceStatus, for deviceKey: String) {
        guard var row = rows[deviceKey] else { return }
        guard row.status != status else { return }
        row.status = status
        if case .streaming = status {} else { row.stats = nil }
        rows[deviceKey] = row
        publish()
    }

    private func publish() {
        let sorted = rows.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        usbDevices = sorted.filter { $0.endpoint.isUSB }
        lanDevices = sorted.filter { !$0.endpoint.isUSB }
    }
}

private extension DeviceStatus {
    /// True while a connection attempt or session is in progress.
    var isLive: Bool {
        switch self {
        case .connecting, .negotiating, .pairing, .streaming: return true
        default: return false
        }
    }
}
