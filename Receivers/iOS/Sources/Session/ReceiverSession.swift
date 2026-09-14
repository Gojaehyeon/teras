import Foundation
import TandemProtocol

protocol ReceiverSessionDelegate: AnyObject {
    func session(_ session: ReceiverSession, didChangeState state: ReceiverSession.State)
    func session(_ session: ReceiverSession, didConfigureStream config: StreamConfig)
    func session(_ session: ReceiverSession, pairingFailedWithAttemptsLeft attemptsLeft: Int)
    func sessionDidEnd(_ session: ReceiverSession, reason: String)
}

/// Receiver half of the session state machine (PROTOCOL §8).
///
/// Threading: every method must be called on the owning connection's serial
/// queue. Tests drive it directly with a fake channel.
final class ReceiverSession {

    enum State: Equatable {
        case waitingForHello
        case pairing(pin: String, attemptsLeft: Int)
        case authenticating
        case configuring
        case streaming
        case closed(String)
    }

    struct Configuration {
        var descriptorProvider: () -> DeviceDescriptor
        var pairingStore: PairingStoring
        var pinGenerator: () -> String = { TandemCrypto.generatePIN() }
        var secretGenerator: () -> Data = { TandemCrypto.randomBytes(32) }
        var nonceGenerator: () -> Data = { TandemCrypto.randomBytes(16) }
    }

    private(set) var state: State = .waitingForHello {
        didSet {
            guard state != oldValue else { return }
            delegate?.session(self, didChangeState: state)
        }
    }

    private(set) var hello: Hello?
    private(set) var streamConfig: StreamConfig?
    private(set) var effectiveTransport: Transport = .lan
    private(set) var deviceNonce = Data()
    private(set) var secret: Data?

    weak var delegate: ReceiverSessionDelegate?
    weak var videoSink: VideoSink?

    private let configuration: Configuration
    private let channel: FrameChannel
    private var pin: String?
    private var attemptsLeft = Tandem.pairMaxAttempts
    private var lastDeviceConfigSent: DeviceConfig?

    var hostName: String { hello?.hostName ?? "" }
    var hostId: String { hello?.hostId ?? "" }

    private var sink: VideoSink? { videoSink }

    init(channel: FrameChannel, configuration: Configuration) {
        self.channel = channel
        self.configuration = configuration
    }

    // MARK: - Inbound

    func handle(_ frame: Frame) {
        guard !isClosed else { return }
        switch frame.type {
        case .hello: handleHello(frame)
        case .pair: handlePair(frame)
        case .auth: handleAuth(frame)
        case .streamConfig: handleStreamConfig(frame)
        case .video: handleVideo(frame)
        case .bye:
            let reason = (try? frame.decode(Bye.self).reason) ?? "bye"
            finish(reason: reason, sendBye: false)
        default:
            // R→H types and anything unknown for this direction are ignored
            // (PROTOCOL §9: additive evolution).
            break
        }
    }

    func connectionClosed(reason: String) {
        guard !isClosed else { return }
        state = .closed(reason)
        sink?.reset()
        delegate?.sessionDidEnd(self, reason: reason)
    }

    // MARK: - HELLO

    private func handleHello(_ frame: Frame) {
        guard state == .waitingForHello else {
            finish(reason: "unexpected HELLO", sendBye: true)
            return
        }
        guard let hello = try? frame.decode(Hello.self) else {
            finish(reason: "malformed HELLO", sendBye: true)
            return
        }
        guard hello.pv >= 1 else {
            finish(reason: "unsupported protocol version \(hello.pv)", sendBye: true)
            return
        }
        guard hello.hostNonce.count == 16 else {
            finish(reason: "bad hostNonce", sendBye: true)
            return
        }
        self.hello = hello

        // Only a loopback peer (usbmuxd) may claim the unauthenticated USB
        // path. Anything arriving over the network authenticates, whatever it
        // says about itself.
        effectiveTransport = channel.linkTransport == .usb ? hello.transport : .lan

        let descriptor = configuration.descriptorProvider()
        deviceNonce = configuration.nonceGenerator()
        let storedSecret = configuration.pairingStore.secret(forHost: hello.hostId)
        secret = storedSecret
        let authRequired = effectiveTransport == .lan

        let ack = HelloAck(deviceId: descriptor.deviceId,
                           deviceName: descriptor.deviceName,
                           platform: .ios,
                           model: descriptor.model,
                           deviceNonce: deviceNonce,
                           screen: descriptor.screen,
                           orientation: descriptor.orientation,
                           codecs: descriptor.codecs,
                           maxDecode: descriptor.maxDecode,
                           features: descriptor.features,
                           paired: storedSecret != nil,
                           authRequired: authRequired)
        guard let ackFrame = try? Frame.json(.helloAck, ack) else {
            finish(reason: "could not encode HELLO_ACK", sendBye: true)
            return
        }
        channel.send(ackFrame)

        guard authRequired else {
            state = .configuring
            return
        }
        if storedSecret != nil {
            state = .authenticating
            return
        }
        beginPairing()
    }

    private func beginPairing() {
        let code = configuration.pinGenerator()
        pin = code
        attemptsLeft = Tandem.pairMaxAttempts
        guard let frame = try? Frame.json(.pairRequired, PairRequired(attemptsLeft: attemptsLeft)) else {
            finish(reason: "could not encode PAIR_REQUIRED", sendBye: true)
            return
        }
        channel.send(frame)
        state = .pairing(pin: code, attemptsLeft: attemptsLeft)
    }

    // MARK: - PAIR

    private func handlePair(_ frame: Frame) {
        guard case .pairing = state, let pin, let hello else {
            finish(reason: "unexpected PAIR", sendBye: true)
            return
        }
        guard let message = try? frame.decode(PairMessage.self) else {
            finish(reason: "malformed PAIR", sendBye: true)
            return
        }
        let descriptor = configuration.descriptorProvider()
        let pinKey = TandemCrypto.pinKey(pin: pin, deviceId: descriptor.deviceId, hostId: hello.hostId)
        let expected = TandemCrypto.pairProof(pinKey: pinKey, hostNonce: hello.hostNonce, deviceNonce: deviceNonce)

        guard TandemCrypto.constantTimeEquals(expected, message.proof) else {
            attemptsLeft -= 1
            let locked = attemptsLeft <= 0
            if let failFrame = try? Frame.json(.pairFail, PairFail(attemptsLeft: max(attemptsLeft, 0), locked: locked)) {
                channel.send(failFrame)
            }
            delegate?.session(self, pairingFailedWithAttemptsLeft: max(attemptsLeft, 0))
            if locked {
                // Rotate the code so a new attempt cannot reuse what leaked.
                self.pin = configuration.pinGenerator()
                finish(reason: "too many pairing attempts", sendBye: true)
            } else {
                state = .pairing(pin: pin, attemptsLeft: attemptsLeft)
            }
            return
        }

        let fresh = configuration.secretGenerator()
        guard fresh.count == 32 else {
            finish(reason: "bad secret length", sendBye: true)
            return
        }
        guard let box = try? TandemCrypto.sealPairBox(secret: fresh, pinKey: pinKey,
                                                      hostNonce: hello.hostNonce, deviceNonce: deviceNonce),
              let okFrame = try? Frame.json(.pairOK, PairOK(box: box)) else {
            finish(reason: "could not seal the pairing box", sendBye: true)
            return
        }
        configuration.pairingStore.store(secret: fresh, hostId: hello.hostId, hostName: hello.hostName)
        secret = fresh
        self.pin = nil
        channel.send(okFrame)
        state = .authenticating
    }

    // MARK: - AUTH

    private func handleAuth(_ frame: Frame) {
        guard state == .authenticating, let hello else {
            finish(reason: "unexpected AUTH", sendBye: true)
            return
        }
        guard let message = try? frame.decode(AuthMessage.self) else {
            finish(reason: "malformed AUTH", sendBye: true)
            return
        }
        guard let secret else {
            sendAuthFail("not paired")
            return
        }
        let expected = TandemCrypto.authProof(secret: secret, hostNonce: hello.hostNonce, deviceNonce: deviceNonce)
        guard TandemCrypto.constantTimeEquals(expected, message.proof) else {
            sendAuthFail("bad proof")
            return
        }
        let ack = TandemCrypto.authAckProof(secret: secret, hostNonce: hello.hostNonce, deviceNonce: deviceNonce)
        guard let okFrame = try? Frame.json(.authOK, AuthOK(proof: ack)) else {
            finish(reason: "could not encode AUTH_OK", sendBye: true)
            return
        }
        channel.send(okFrame)

        if hello.encrypt {
            let keys = TandemCrypto.sessionKeys(secret: secret, hostNonce: hello.hostNonce, deviceNonce: deviceNonce)
            channel.enableEncryption(hostToReceiver: keys.h2r, receiverToHost: keys.r2h)
        }
        configuration.pairingStore.touch(hostId: hello.hostId, hostName: hello.hostName)
        state = .configuring
    }

    private func sendAuthFail(_ reason: String) {
        if let frame = try? Frame.json(.authFail, AuthFail(reason: reason)) {
            channel.send(frame)
        }
        finish(reason: "authentication failed: \(reason)", sendBye: false)
    }

    // MARK: - Streaming

    private func handleStreamConfig(_ frame: Frame) {
        guard state == .configuring || state == .streaming else {
            finish(reason: "unexpected STREAM_CONFIG", sendBye: true)
            return
        }
        guard let config = try? frame.decode(StreamConfig.self), config.wPx > 0, config.hPx > 0 else {
            finish(reason: "malformed STREAM_CONFIG", sendBye: true)
            return
        }
        streamConfig = config
        sink?.configure(config)
        channel.send(Frame(type: .ready, payload: Data("{}".utf8)))
        state = .streaming
        delegate?.session(self, didConfigureStream: config)
    }

    private func handleVideo(_ frame: Frame) {
        guard state == .streaming else { return }
        guard let video = try? VideoFrame(parsing: frame.payload) else {
            requestKeyframe()
            return
        }
        sink?.enqueue(video, hostClockOffsetUs: channel.clockOffsetUs)
    }

    // MARK: - Outbound

    /// Input events. Dropped unless the stream is live.
    func sendInput(_ frame: Frame) {
        guard state == .streaming else { return }
        channel.send(frame)
    }

    func requestKeyframe() {
        guard state == .streaming else { return }
        channel.send(Frame(type: .keyframeRequest))
    }

    /// Orientation or usable-area change (PROTOCOL §5.2). Callers debounce.
    func sendDeviceConfig(orientation: Orientation, screen: ScreenInfo) {
        guard state == .configuring || state == .streaming else { return }
        let config = DeviceConfig(orientation: orientation, screen: screen)
        guard config != lastDeviceConfigSent else { return }
        guard let frame = try? Frame.json(.deviceConfig, config) else { return }
        lastDeviceConfigSent = config
        channel.send(frame)
    }

    func sendStats() {
        guard state == .streaming, let snapshot = sink?.snapshotStats() else { return }
        let stats = Stats(fpsDecoded: snapshot.fpsDecoded,
                          fpsDropped: snapshot.fpsDropped,
                          decodeMsP50: snapshot.decodeMsP50,
                          queued: snapshot.queued,
                          rttMs: channel.roundTripMs,
                          e2eMsP50: snapshot.e2eMsP50)
        guard let frame = try? Frame.json(.stats, stats) else { return }
        channel.send(frame)
    }

    // MARK: - Teardown

    private var isClosed: Bool {
        if case .closed = state { return true }
        return false
    }

    func close(reason: String) {
        finish(reason: reason, sendBye: true)
    }

    private func finish(reason: String, sendBye: Bool) {
        guard !isClosed else { return }
        state = .closed(reason)
        sink?.reset()
        channel.close(reason: sendBye ? reason : nil)
        delegate?.sessionDidEnd(self, reason: reason)
    }
}
