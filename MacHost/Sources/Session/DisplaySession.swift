import CoreGraphics
import Foundation
import TerasProtocol

/// Where input events go. A protocol so sessions can be driven in tests with
/// no Accessibility permission and no synthetic events.
@MainActor
protocol InputSink: AnyObject {
    func handle(_ touch: TouchEvent)
    func handle(_ scroll: ScrollEvent)
    func handle(_ key: KeyEvent)
    func handle(_ pointer: PointerEvent)
}

extension InputInjector: InputSink {}

/// Everything a session needs from the rest of the app.
@MainActor
struct SessionDependencies {
    var hostId: String
    var hostName: String
    var appInfo: AppInfo
    var pairingStore: SecretStore
    var settingsStore: DeviceSettingsStore
    var makeDisplay: (String) -> VirtualDisplayHosting
    var makePipeline: () -> VideoPipeline
    var makeInput: (@escaping () -> CGRect?) -> InputSink?
    /// Encrypt the stream once authenticated. Off for USB, where the cable is
    /// already the boundary and the CPU is better spent on pixels.
    var encryptOnLAN: Bool = true

    static func live(pairingStore: SecretStore, settingsStore: DeviceSettingsStore) -> SessionDependencies {
        SessionDependencies(
            hostId: HostIdentity.hostId,
            hostName: HostIdentity.hostName,
            appInfo: HostIdentity.appInfo,
            pairingStore: pairingStore,
            settingsStore: settingsStore,
            makeDisplay: { deviceId in VirtualDisplay(deviceId: deviceId) },
            makePipeline: { CaptureEncodePipeline() },
            makeInput: { bounds in InputInjector(displayBounds: bounds) }
        )
    }
}

enum SessionState: Equatable, Sendable {
    case handshaking
    case awaitingPIN(attemptsLeft: Int)
    case pairing
    case authenticating
    case configuring
    case streaming
    case failed(String)
    case closed(String)

    var isActive: Bool {
        switch self {
        case .failed, .closed: return false
        default: return true
        }
    }

    var isStreaming: Bool { self == .streaming }
}

enum SessionError: LocalizedError {
    case protocolViolation(String)
    case unsupportedVersion(Int)
    case noSharedCodec
    case pairingRefused(String)
    case authenticationFailed(String)
    case missingSecret

    var errorDescription: String? {
        switch self {
        case .protocolViolation(let detail): return "Unexpected message from the device: \(detail)."
        case .unsupportedVersion(let version): return "The device speaks protocol version \(version), which this Mac does not."
        case .noSharedCodec: return "The device offers no video codec this Mac can produce."
        case .pairingRefused(let detail): return detail
        case .authenticationFailed(let detail): return detail
        case .missingSecret:
            return "The device thinks it is already paired but this Mac has no key for it. "
                 + "Forget this Mac on the device, then pair again."
        }
    }
}

/// One receiver, one virtual display, one encode session.
///
/// Implements the host side of PROTOCOL §8 end to end: handshake, optional
/// pairing and authentication, stream configuration, video out and input in.
@MainActor
final class DisplaySession {
    let endpoint: TerasEndpoint

    private let channel: PeerChannel
    private let dependencies: SessionDependencies
    private let transport: Transport

    private var display: VirtualDisplayHosting?
    private var pipeline: VideoPipeline?
    private var input: InputSink?
    private var videoSender: VideoSender?

    private let hostNonce: Data
    private var helloAck: HelloAck?
    private var pinKey: Data?
    private var secret: Data?
    private var currentSpec: VirtualDisplaySpec?
    private var currentCodec: Codec = .hevc
    private var restartPipelineWhenReady = false

    private(set) var state: SessionState = .handshaking {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }
    private(set) var stats: Stats?

    var onStateChange: ((SessionState) -> Void)?
    var onStatsChange: ((Stats) -> Void)?
    /// Fired once when the session is finished, whatever the reason.
    var onFinished: ((SessionState) -> Void)?

    var rttMs: Double { channel.rttMs }
    var captureMethod: String { pipeline?.captureMethod ?? "" }
    var deviceId: String? { helloAck?.deviceId }
    var spec: VirtualDisplaySpec? { currentSpec }

    private var settingsKey: String { endpoint.id }
    private var finished = false

    init(endpoint: TerasEndpoint,
         channel: PeerChannel,
         transport: Transport,
         dependencies: SessionDependencies,
         hostNonce: Data = TerasCrypto.randomBytes(16)) {
        self.endpoint = endpoint
        self.channel = channel
        self.transport = transport
        self.dependencies = dependencies
        self.hostNonce = hostNonce
    }

    // MARK: - Lifecycle

    func start() {
        channel.start(
            onFrame: { [weak self] frame in self?.receive(frame) },
            onFailure: { [weak self] error in self?.finish(.closed(error.localizedDescription)) }
        )

        let hello = Hello(hostId: dependencies.hostId,
                          hostName: dependencies.hostName,
                          transport: transport,
                          hostNonce: hostNonce,
                          encrypt: transport == .lan && dependencies.encryptOnLAN,
                          app: dependencies.appInfo)
        do {
            channel.send(try Frame.json(.hello, hello))
            state = .handshaking
        } catch {
            finish(.failed("Could not send HELLO: \(error.localizedDescription)"))
        }
    }

    /// Answer a `PAIR_REQUIRED` with the code shown on the device.
    func providePIN(_ pin: String) {
        guard case .awaitingPIN = state, let ack = helloAck else { return }
        let key = TerasCrypto.pinKey(pin: pin, deviceId: ack.deviceId, hostId: dependencies.hostId)
        pinKey = key
        let proof = TerasCrypto.pairProof(pinKey: key, hostNonce: hostNonce, deviceNonce: ack.deviceNonce)
        do {
            channel.send(try Frame.json(.pair, PairMessage(proof: proof)))
            state = .pairing
        } catch {
            finish(.failed("Could not send PAIR: \(error.localizedDescription)"))
        }
    }

    /// End the session and give the virtual display back to macOS.
    func stop(reason: String) {
        guard !finished else { return }
        if let frame = try? Frame.json(.bye, Bye(reason: reason)) {
            channel.send(frame)
        }
        finish(.closed(reason))
    }

    private func finish(_ finalState: SessionState) {
        guard !finished else { return }
        finished = true

        videoSender?.stop()
        videoSender = nil
        pipeline?.stop()
        pipeline = nil
        input = nil
        display?.destroy()
        display = nil
        channel.cancel()

        state = finalState
        onFinished?(finalState)
        switch finalState {
        case .failed(let detail), .closed(let detail):
            Log.info(.session, "Session with \(endpoint.displayName) ended: \(detail)")
        default:
            break
        }
    }

    // MARK: - Frame routing

    private func receive(_ frame: Frame) {
        guard !finished else { return }
        do {
            switch frame.type {
            case .helloAck: try handleHelloAck(frame)
            case .pairRequired: try handlePairRequired(frame)
            case .pairOK: try handlePairOK(frame)
            case .pairFail: try handlePairFail(frame)
            case .authOK: try handleAuthOK(frame)
            case .authFail: try handleAuthFail(frame)
            case .ready: handleReady()
            case .keyframeRequest: handleKeyframeRequest()
            case .deviceConfig: try handleDeviceConfig(frame)
            case .stats: try handleStats(frame)
            case .touch: input?.handle(try TouchEvent(parsing: frame.payload))
            case .scroll: input?.handle(try ScrollEvent(parsing: frame.payload))
            case .pointer: input?.handle(try PointerEvent(parsing: frame.payload))
            case .key: input?.handle(try frame.decode(KeyEvent.self))
            case .bye:
                let bye = try? frame.decode(Bye.self)
                finish(.closed(bye?.reason ?? "the device ended the session"))
            default:
                // Unknown or host-to-receiver types are ignored (PROTOCOL §9).
                Log.debug(.session, "Ignoring \(frame.type) from \(endpoint.displayName)")
            }
        } catch {
            finish(.failed(error.localizedDescription))
        }
    }

    // MARK: - Handshake

    private func handleHelloAck(_ frame: Frame) throws {
        let ack = try frame.decode(HelloAck.self)
        guard ack.pv >= 1 else { throw SessionError.unsupportedVersion(ack.pv) }
        helloAck = ack
        Log.info(.session, "\(ack.deviceName) (\(ack.platform.rawValue)) "
                 + "\(ack.screen.wPx)x\(ack.screen.hPx)@\(Int(ack.screen.refreshHz))Hz, "
                 + "codecs \(ack.codecs.map(\.rawValue).joined(separator: ","))")

        dependencies.settingsStore.update(settingsKey) { $0.lastKnownName = ack.deviceName }

        guard ack.authRequired else {
            try configureStream()
            return
        }

        if let stored = dependencies.pairingStore.secret(forDeviceId: ack.deviceId) {
            secret = stored
            try sendAuth()
        } else if ack.paired {
            // The receiver holds a secret for this host id but we lost ours.
            // There is no protocol path to recover, so say so plainly.
            throw SessionError.missingSecret
        } else {
            // Wait for PAIR_REQUIRED, which carries the attempt budget.
            state = .awaitingPIN(attemptsLeft: Teras.pairMaxAttempts)
        }
    }

    private func handlePairRequired(_ frame: Frame) throws {
        let required = try frame.decode(PairRequired.self)
        state = .awaitingPIN(attemptsLeft: required.attemptsLeft)
        Log.info(.session, "\(endpoint.displayName) is asking for a pairing code")
    }

    private func handlePairOK(_ frame: Frame) throws {
        guard let ack = helloAck, let pinKey else {
            throw SessionError.protocolViolation("PAIR_OK before PAIR")
        }
        let payload = try frame.decode(PairOK.self)
        let recovered = try TerasCrypto.openPairBox(payload.box,
                                                     pinKey: pinKey,
                                                     hostNonce: hostNonce,
                                                     deviceNonce: ack.deviceNonce)
        secret = recovered
        dependencies.pairingStore.save(secret: recovered, forDeviceId: ack.deviceId)
        self.pinKey = nil
        Log.info(.session, "Paired with \(ack.deviceName)")
        try sendAuth()
    }

    private func handlePairFail(_ frame: Frame) throws {
        let failure = try frame.decode(PairFail.self)
        pinKey = nil
        if failure.locked {
            throw SessionError.pairingRefused(
                "Too many wrong codes. The device generated a new code; try pairing again.")
        }
        state = .awaitingPIN(attemptsLeft: failure.attemptsLeft)
    }

    private func sendAuth() throws {
        guard let ack = helloAck, let secret else { throw SessionError.missingSecret }
        let proof = TerasCrypto.authProof(secret: secret, hostNonce: hostNonce, deviceNonce: ack.deviceNonce)
        channel.send(try Frame.json(.auth, AuthMessage(proof: proof)))
        state = .authenticating
    }

    private func handleAuthOK(_ frame: Frame) throws {
        guard let ack = helloAck, let secret else {
            throw SessionError.protocolViolation("AUTH_OK before AUTH")
        }
        let payload = try frame.decode(AuthOK.self)
        let expected = TerasCrypto.authAckProof(secret: secret, hostNonce: hostNonce, deviceNonce: ack.deviceNonce)
        guard TerasCrypto.constantTimeEquals(payload.proof, expected) else {
            // The device could not prove it holds the same secret, so it is not
            // the device we paired with. Keep our secret and stop here.
            throw SessionError.authenticationFailed(
                "The device could not prove its identity. Pair again if this keeps happening.")
        }

        if transport == .lan, dependencies.encryptOnLAN {
            let keys = TerasCrypto.sessionKeys(secret: secret, hostNonce: hostNonce, deviceNonce: ack.deviceNonce)
            channel.enableEncryption(h2r: keys.h2r, r2h: keys.r2h)
        }
        try configureStream()
    }

    private func handleAuthFail(_ frame: Frame) throws {
        let failure = try frame.decode(AuthFail.self)
        if let deviceId = helloAck?.deviceId {
            // Our key is stale; drop it so the next attempt pairs cleanly.
            dependencies.pairingStore.forget(deviceId: deviceId)
        }
        throw SessionError.authenticationFailed(
            failure.reason.isEmpty ? "The device rejected this Mac. Pair again." : failure.reason)
    }

    // MARK: - Stream configuration

    private func configureStream() throws {
        guard let ack = helloAck else { throw SessionError.protocolViolation("no HELLO_ACK") }

        let settings = dependencies.settingsStore.settings(for: settingsKey)
        let codec = try chooseCodec(from: ack.codecs)
        currentCodec = codec

        let spec = DisplayGeometry.spec(screen: ack.screen,
                                        orientation: ack.orientation,
                                        codec: codec,
                                        maxDecode: ack.maxDecode,
                                        hiDPIRequested: settings.hiDPI,
                                        fpsCap: settings.normalizedFPS)
        currentSpec = spec

        let host = display ?? dependencies.makeDisplay(ack.deviceId)
        display = host
        try host.create(spec: spec, name: displayName(for: ack), mode: settings.mode)

        if input == nil {
            input = dependencies.makeInput { [weak host] in host?.bounds }
        }

        let config = StreamConfig(codec: codec,
                                  wPx: spec.encodedWidth,
                                  hPx: spec.encodedHeight,
                                  fps: spec.refreshHz,
                                  desktop: spec.desktop,
                                  orientation: ack.orientation,
                                  mode: settings.mode,
                                  cursorBaked: true)
        channel.send(try Frame.json(.streamConfig, config))
        restartPipelineWhenReady = true
        state = .configuring
        Log.info(.session, "Offered \(codec.rawValue) \(spec.encodedWidth)x\(spec.encodedHeight)@\(spec.refreshHz) "
                 + "(desktop \(spec.logicalWidth)x\(spec.logicalHeight)) to \(endpoint.displayName)")
    }

    private func chooseCodec(from offered: [Codec]) throws -> Codec {
        // The receiver lists codecs in its own preference order, but HEVC is
        // worth roughly half the bitrate for the same picture, so take it
        // whenever it is on the list.
        if offered.contains(.hevc) { return .hevc }
        if offered.contains(.h264) { return .h264 }
        throw SessionError.noSharedCodec
    }

    private func displayName(for ack: HelloAck) -> String {
        ack.deviceName.isEmpty ? "Teras Display" : ack.deviceName
    }

    private func handleReady() {
        guard restartPipelineWhenReady else { return }
        restartPipelineWhenReady = false
        startPipeline()
    }

    private func startPipeline() {
        guard let spec = currentSpec, let displayID = display?.displayID else {
            finish(.failed("The virtual display disappeared before streaming started."))
            return
        }

        let settings = dependencies.settingsStore.settings(for: settingsKey)
        let bitrate = settings.quality.bitsPerSecond(transport: transport)

        let sender = VideoSender(channel: channel)
        sender.onKeyframeNeeded = { [weak self] in
            // Runs on the encoder's thread.
            DispatchQueue.main.async { self?.pipeline?.requestKeyframe() }
        }
        videoSender = sender

        let pipeline = self.pipeline ?? dependencies.makePipeline()
        self.pipeline = pipeline

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await pipeline.start(displayID: displayID,
                                         spec: spec,
                                         codec: self.currentCodec,
                                         bitrateBps: bitrate) { [weak sender] encoded in
                    sender?.submit(encoded)
                }
                guard !self.finished else {
                    pipeline.stop()
                    return
                }
                self.state = .streaming
                Log.info(.session, "Streaming to \(self.endpoint.displayName) at \(bitrate / 1_000_000) Mbps")
            } catch {
                self.finish(.failed(error.localizedDescription))
            }
        }
    }

    // MARK: - Running session

    private func handleKeyframeRequest() {
        pipeline?.requestKeyframe()
        // On a static desktop no new frame is captured, so nudge the last one
        // through the encoder as the IDR the receiver asked for.
        pipeline?.replayLastFrame()
    }

    private func handleDeviceConfig(_ frame: Frame) throws {
        let config = try frame.decode(DeviceConfig.self)
        guard var ack = helloAck else { throw SessionError.protocolViolation("DEVICE_CONFIG before HELLO_ACK") }
        guard ack.orientation != config.orientation || ack.screen != config.screen else { return }

        Log.info(.session, "\(endpoint.displayName) rotated to \(config.orientation.rawValue) "
                 + "(\(config.screen.wPx)x\(config.screen.hPx))")
        ack.orientation = config.orientation
        ack.screen = config.screen
        helloAck = ack

        // Rebuild from scratch: the display is a different panel now, and the
        // receiver resets its decoder when the geometry changes.
        videoSender?.stop()
        videoSender = nil
        pipeline?.stop()
        state = .configuring
        try configureStream()
    }

    private func handleStats(_ frame: Frame) throws {
        let stats = try frame.decode(Stats.self)
        self.stats = stats
        onStatsChange?(stats)
    }

    // MARK: - Settings changes

    /// Apply a quality change without renegotiating geometry.
    func applyQuality(_ quality: QualityPreset) {
        dependencies.settingsStore.update(settingsKey) { $0.quality = quality }
        pipeline?.setBitrate(quality.bitsPerSecond(transport: transport))
        pipeline?.requestKeyframe()
    }

    /// Re-negotiate the stream after a change that alters geometry (frame rate,
    /// HiDPI, mirror or extend).
    func reconfigure() {
        guard state.isActive, helloAck != nil else { return }
        videoSender?.stop()
        videoSender = nil
        pipeline?.stop()
        do {
            try configureStream()
        } catch {
            finish(.failed(error.localizedDescription))
        }
    }
}
