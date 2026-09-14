import Foundation
import Network
import TandemProtocol

/// Owns the TCP listener, the Bonjour advertisement and the single live
/// session. Host connections replace each other: the newest one wins
/// (PROTOCOL §1).
final class ReceiverServer {

    enum Advertisement: Equatable {
        case stopped
        case starting
        case advertising(name: String)
        case failed(String)
    }

    enum Event {
        case advertisement(Advertisement)
        case connected(transport: Transport, peer: String)
        case sessionState(ReceiverSession.State, hostName: String, transport: Transport)
        case streamConfigured(StreamConfig)
        case pairingFailed(attemptsLeft: Int)
        case ended(reason: String)
    }

    /// Delivered on the main queue.
    var onEvent: ((Event) -> Void)?

    private let queue = DispatchQueue(label: "app.tandem.receiver.net", qos: .userInitiated)
    private let descriptorBox: DeviceDescriptorBox
    private let pairingStore: PairingStoring
    private weak var videoSink: VideoSink?

    private var listener: NWListener?
    private var connection: PeerConnection?
    private var session: ReceiverSession?
    private var statsTimer: DispatchSourceTimer?
    private var retryWorkItem: DispatchWorkItem?
    private var retryDelay: TimeInterval = 0.5
    private var deviceConfigGeneration = 0
    private var isRunning = false

    init(descriptorBox: DeviceDescriptorBox, pairingStore: PairingStoring, videoSink: VideoSink?) {
        self.descriptorBox = descriptorBox
        self.pairingStore = pairingStore
        self.videoSink = videoSink
    }

    // MARK: - Lifecycle

    func start() {
        queue.async { [weak self] in
            guard let self, !self.isRunning else { return }
            self.isRunning = true
            self.retryDelay = 0.5
            self.startListener()
        }
    }

    /// Stops advertising and closes the live session with BYE.
    /// `completion` runs on the main queue once the socket is really gone.
    func stop(reason: String = "receiver stopped", completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else {
                completion.map { done in DispatchQueue.main.async(execute: done) }
                return
            }
            self.isRunning = false
            self.retryWorkItem?.cancel()
            self.retryWorkItem = nil
            self.tearDownSession(reason: reason) {
                completion.map { done in DispatchQueue.main.async(execute: done) }
            }
            self.listener?.stateUpdateHandler = nil
            self.listener?.newConnectionHandler = nil
            self.listener?.cancel()
            self.listener = nil
            self.emit(.advertisement(.stopped))
        }
    }

    /// Re-advertise under a new display name.
    func updateAdvertisedName(_ name: String) {
        queue.async { [weak self] in
            guard let self, let listener = self.listener else { return }
            listener.service = self.makeService(name: name)
        }
    }

    /// Orientation or safe-area change. Debounced, then sent as DEVICE_CONFIG.
    func geometryDidChange(orientation: Orientation, screen: ScreenInfo) {
        queue.async { [weak self] in
            guard let self else { return }
            self.deviceConfigGeneration += 1
            let generation = self.deviceConfigGeneration
            self.queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, generation == self.deviceConfigGeneration else { return }
                self.session?.sendDeviceConfig(orientation: orientation, screen: screen)
            }
        }
    }

    /// Input events from the UI thread.
    func sendInput(_ frame: Frame) {
        queue.async { [weak self] in
            self?.session?.sendInput(frame)
        }
    }

    func requestKeyframe() {
        queue.async { [weak self] in
            self?.session?.requestKeyframe()
        }
    }

    // MARK: - Listener

    private func startListener() {
        let parameters = makeParameters()
        let listener: NWListener
        do {
            guard let port = NWEndpoint.Port(rawValue: Tandem.port) else {
                emit(.advertisement(.failed("invalid port")))
                return
            }
            listener = try NWListener(using: parameters, on: port)
        } catch {
            emit(.advertisement(.failed(error.localizedDescription)))
            scheduleRetry()
            return
        }

        listener.service = makeService(name: descriptorBox.current.deviceName)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.retryDelay = 0.5
                self.emit(.advertisement(.advertising(name: self.descriptorBox.current.deviceName)))
            case .failed(let error):
                self.emit(.advertisement(.failed(error.localizedDescription)))
                self.listener?.cancel()
                self.listener = nil
                self.scheduleRetry()
            case .cancelled:
                if self.isRunning { self.scheduleRetry() }
            case .waiting(let error):
                self.emit(.advertisement(.failed(error.localizedDescription)))
            default:
                break
            }
        }
        listener.serviceRegistrationUpdateHandler = { [weak self] change in
            guard let self else { return }
            if case .add(let endpoint) = change, case .service(let name, _, _, _) = endpoint {
                self.emit(.advertisement(.advertising(name: name)))
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        self.listener = listener
        emit(.advertisement(.starting))
        listener.start(queue: queue)
    }

    private func makeParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = true      // AWDL for Mac hosts on the same Wi-Fi
        parameters.allowLocalEndpointReuse = true
        return parameters
    }

    private func makeService(name: String) -> NWListener.Service {
        let descriptor = descriptorBox.current
        var txt = NWTXTRecord()
        txt["pv"] = String(Tandem.protocolVersion)
        txt["id"] = descriptor.deviceId
        txt["plat"] = "ios"
        txt["name"] = name
        return NWListener.Service(name: name, type: Tandem.bonjourServiceType, domain: nil, txtRecord: txt)
    }

    private func scheduleRetry() {
        guard isRunning else { return }
        retryWorkItem?.cancel()
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 15)
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning, self.listener == nil else { return }
            self.startListener()
        }
        retryWorkItem = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    // MARK: - Sessions

    private func accept(_ nwConnection: NWConnection) {
        // One host at a time: the newest connection replaces the previous one.
        tearDownSession(reason: "replaced by a new connection")

        let peer = PeerConnection(connection: nwConnection, queue: queue)
        let configuration = ReceiverSession.Configuration(
            descriptorProvider: { [descriptorBox] in descriptorBox.current },
            pairingStore: pairingStore)
        let session = ReceiverSession(channel: peer, configuration: configuration)
        session.delegate = self
        session.videoSink = videoSink
        peer.delegate = self

        connection = peer
        self.session = session
        videoSink?.reset()
        peer.start()
    }

    private func tearDownSession(reason: String, completion: (() -> Void)? = nil) {
        statsTimer?.cancel()
        statsTimer = nil
        session?.delegate = nil
        connection?.delegate = nil
        if let connection {
            connection.close(reason: reason, completion: completion)
        } else {
            completion?()
        }
        session = nil
        self.connection = nil
        videoSink?.reset()
    }

    private func startStatsTimer() {
        statsTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Tandem.statsInterval, repeating: Tandem.statsInterval)
        timer.setEventHandler { [weak self] in self?.session?.sendStats() }
        statsTimer = timer
        timer.resume()
    }

    private func emit(_ event: Event) {
        guard let onEvent else { return }
        DispatchQueue.main.async { onEvent(event) }
    }
}

// MARK: - PeerConnectionDelegate

extension ReceiverServer: PeerConnectionDelegate {
    func peerConnectionDidConnect(_ peer: PeerConnection) {
        guard peer === connection else { return }
        emit(.connected(transport: peer.linkTransport, peer: peer.endpointDescription))
    }

    func peerConnection(_ peer: PeerConnection, didReceive frame: Frame) {
        guard peer === connection else { return }
        session?.handle(frame)
    }

    func peerConnection(_ peer: PeerConnection, didCloseWith reason: String) {
        guard peer === connection else { return }
        statsTimer?.cancel()
        statsTimer = nil
        session?.connectionClosed(reason: reason)
        session = nil
        connection = nil
        videoSink?.reset()
    }
}

// MARK: - ReceiverSessionDelegate

extension ReceiverServer: ReceiverSessionDelegate {
    func session(_ session: ReceiverSession, didChangeState state: ReceiverSession.State) {
        guard session === self.session else { return }
        emit(.sessionState(state, hostName: session.hostName, transport: session.effectiveTransport))
    }

    func session(_ session: ReceiverSession, didConfigureStream config: StreamConfig) {
        guard session === self.session else { return }
        startStatsTimer()
        emit(.streamConfigured(config))
    }

    func session(_ session: ReceiverSession, pairingFailedWithAttemptsLeft attemptsLeft: Int) {
        guard session === self.session else { return }
        emit(.pairingFailed(attemptsLeft: attemptsLeft))
    }

    func sessionDidEnd(_ session: ReceiverSession, reason: String) {
        guard session === self.session else { return }
        statsTimer?.cancel()
        statsTimer = nil
        emit(.ended(reason: reason))
    }
}
