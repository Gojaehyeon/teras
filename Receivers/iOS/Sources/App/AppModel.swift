import Foundation
import Combine
import UIKit
import SwiftUI
import TandemProtocol

/// Glue between the networking stack (private serial queues) and SwiftUI
/// (main actor). Owns the renderer and the input overlay so both survive view
/// updates.
@MainActor
final class AppModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case connected              // TCP up, HELLO not seen yet
        case pairing(pin: String, attemptsLeft: Int)
        case authenticating
        case preparing              // authenticated, waiting for STREAM_CONFIG
        case streaming
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var advertisement: ReceiverServer.Advertisement = .stopped
    @Published private(set) var transport: Transport?
    @Published private(set) var hostName: String = ""
    @Published private(set) var streamConfig: StreamConfig?
    @Published private(set) var stats = VideoStatsSnapshot()
    @Published private(set) var lastEndReason: String?
    @Published private(set) var pairingAttemptsLeft: Int = Tandem.pairMaxAttempts
    @Published var isShowingSettings = false
    @Published var isShowingStatsOverlay = false

    let settings: UserSettings
    let renderer: VideoRendererView
    let inputBridge: InputBridge
    let pairingStore: PairingStoring

    private let descriptorBox: DeviceDescriptorBox
    private let server: ReceiverServer
    private var statsTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    var isStreaming: Bool { phase == .streaming }

    var deviceId: String { DeviceIdentity.deviceId }

    var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    init(settings: UserSettings? = nil, pairingStore: PairingStoring? = nil) {
        let settings = settings ?? UserSettings()
        let pairingStore = pairingStore ?? KeychainPairingStore()
        self.settings = settings
        self.pairingStore = pairingStore
        let renderer = VideoRendererView(frame: .zero)
        self.renderer = renderer
        self.inputBridge = InputBridge(frame: .zero)

        let descriptor = DeviceMetrics.descriptor(name: settings.effectiveDeviceName, scene: nil, window: nil)
        self.descriptorBox = DeviceDescriptorBox(descriptor)
        self.server = ReceiverServer(descriptorBox: descriptorBox, pairingStore: pairingStore, videoSink: renderer)

        self.isShowingStatsOverlay = settings.showStats

        configureWiring()
    }

    private func configureWiring() {
        server.onEvent = { [weak self] event in
            // `ReceiverServer` already hops to the main queue; the Task keeps
            // the call main-actor isolated without requiring iOS 17.
            Task { @MainActor [weak self] in self?.handle(event) }
        }
        renderer.onKeyframeNeeded = { [weak self] in
            Task { @MainActor [weak self] in self?.server.requestKeyframe() }
        }
        inputBridge.videoRectProvider = { [weak renderer] in
            renderer?.renderedVideoRect ?? .zero
        }
        inputBridge.onFrame = { [weak self] frame in
            self?.server.sendInput(frame)
        }
        inputBridge.onTripleTap = { [weak self] in
            self?.isShowingStatsOverlay.toggle()
        }

        settings.$deviceNameOverride
            .removeDuplicates()
            .dropFirst()
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.deviceNameDidChange() }
            .store(in: &cancellables)

        settings.$showStats
            .removeDuplicates()
            .sink { [weak self] value in self?.isShowingStatsOverlay = value }
            .store(in: &cancellables)
    }

    // MARK: - Lifecycle

    func start() {
        refreshDescriptor()
        server.start()
    }

    func stop(reason: String = "receiver stopped") {
        // Hold a task assertion so the BYE actually reaches the wire before
        // iOS suspends us. Without it the host would only notice this device
        // went away when its PONG timeout expires.
        let application = UIApplication.shared
        var assertion = UIBackgroundTaskIdentifier.invalid
        assertion = application.beginBackgroundTask(withName: "app.tandem.receiver.bye") {
            guard assertion != .invalid else { return }
            application.endBackgroundTask(assertion)
            assertion = .invalid
        }
        server.stop(reason: reason) {
            guard assertion != .invalid else { return }
            application.endBackgroundTask(assertion)
            assertion = .invalid
        }
        phase = .idle
        transport = nil
        streamConfig = nil
        stopStatsTimer()
        application.isIdleTimerDisabled = false
    }

    func scenePhaseChanged(_ newPhase: ScenePhase) {
        switch newPhase {
        case .active:
            start()
        case .background:
            stop(reason: "receiver moved to the background")
        default:
            break
        }
    }

    // MARK: - Geometry

    /// Called when the interface size, orientation or safe area changes.
    func geometryDidChange() {
        refreshDescriptor()
        let descriptor = descriptorBox.current
        server.geometryDidChange(orientation: descriptor.orientation, screen: descriptor.screen)
    }

    private func refreshDescriptor() {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ??
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        descriptorBox.current = DeviceMetrics.descriptor(name: settings.effectiveDeviceName,
                                                         scene: scene, window: window)
    }

    private func deviceNameDidChange() {
        refreshDescriptor()
        server.updateAdvertisedName(descriptorBox.current.deviceName)
    }

    var advertisedName: String {
        if case .advertising(let name) = advertisement { return name }
        return settings.effectiveDeviceName
    }

    // MARK: - Paired hosts

    func forgetHost(_ host: PairedHost) {
        pairingStore.forget(hostId: host.id)
        objectWillChange.send()
    }

    // MARK: - Server events

    private func handle(_ event: ReceiverServer.Event) {
        switch event {
        case .advertisement(let advertisement):
            self.advertisement = advertisement
        case .connected(let transport, _):
            self.transport = transport
            self.lastEndReason = nil
            if phase == .idle { phase = .connected }
        case .sessionState(let state, let hostName, let transport):
            self.hostName = hostName
            self.transport = transport
            apply(state)
        case .streamConfigured(let config):
            self.streamConfig = config
        case .pairingFailed(let attemptsLeft):
            self.pairingAttemptsLeft = attemptsLeft
        case .ended(let reason):
            self.lastEndReason = reason
            self.phase = .idle
            self.transport = nil
            self.streamConfig = nil
            self.stats = VideoStatsSnapshot()
            stopStatsTimer()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private func apply(_ state: ReceiverSession.State) {
        switch state {
        case .waitingForHello:
            phase = .connected
        case .pairing(let pin, let attemptsLeft):
            pairingAttemptsLeft = attemptsLeft
            phase = .pairing(pin: pin, attemptsLeft: attemptsLeft)
        case .authenticating:
            phase = .authenticating
        case .configuring:
            phase = .preparing
        case .streaming:
            phase = .streaming
            UIApplication.shared.isIdleTimerDisabled = true
            startStatsTimer()
        case .closed:
            phase = .idle
            UIApplication.shared.isIdleTimerDisabled = false
            stopStatsTimer()
        }
    }

    // MARK: - Stats

    private func startStatsTimer() {
        guard statsTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.stats = self.renderer.snapshotStats()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        statsTimer = timer
    }

    private func stopStatsTimer() {
        statsTimer?.invalidate()
        statsTimer = nil
    }
}
