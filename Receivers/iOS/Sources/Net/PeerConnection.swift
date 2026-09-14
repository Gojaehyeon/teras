import Foundation
import Network
import QuartzCore
import TandemProtocol

protocol PeerConnectionDelegate: AnyObject {
    /// The TCP connection is up; the host will send HELLO next.
    func peerConnectionDidConnect(_ connection: PeerConnection)
    /// A decrypted, decoded frame. Liveness frames are handled internally.
    func peerConnection(_ connection: PeerConnection, didReceive frame: Frame)
    /// Terminal. The connection is already cancelled.
    func peerConnection(_ connection: PeerConnection, didCloseWith reason: String)
}

/// One host session: frame reader/writer, optional per-direction encryption,
/// PING/PONG liveness and RTT/clock-offset tracking.
///
/// Everything runs on a private serial queue. Public methods are safe to call
/// from any thread.
final class PeerConnection {

    let linkTransport: Transport
    weak var delegate: PeerConnectionDelegate?

    private let connection: NWConnection
    private let queue: DispatchQueue
    private var parser = FrameParser()

    private var sendCipher: SessionCipher?
    private var receiveCipher: SessionCipher?

    private var pingTimer: DispatchSourceTimer?
    private var lastPingSentUs: UInt64 = 0
    private var lastPongAt: TimeInterval = 0
    private var awaitingPong = false

    private var smoothedRttMs: Double = 0
    private var offsetUs: Int64?
    private let metricsLock = NSLock()

    private var isClosed = false
    private var isClosing = false
    private var closeCompletions: [() -> Void] = []

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
        self.linkTransport = PeerConnection.isLoopback(connection.endpoint) ? .usb : .lan
    }

    var endpointDescription: String { String(describing: connection.endpoint) }

    // MARK: - Lifecycle

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.lastPongAt = CACurrentMediaTime()
                self.startPingTimer()
                self.receiveLoop()
                self.delegate?.peerConnectionDidConnect(self)
            case .failed(let error):
                self.finish(reason: "connection failed: \(error.localizedDescription)")
            case .cancelled:
                self.finish(reason: "cancelled")
            case .waiting(let error):
                NSLog("[Tandem] connection waiting: \(error.localizedDescription)")
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// Graceful close. A non-nil `reason` sends BYE first; either way the
    /// write side is finished so queued frames reach the host before the
    /// socket goes away.
    func close(reason: String?) {
        close(reason: reason, completion: nil)
    }

    /// `completion` runs on the connection queue once the socket is really
    /// gone. Backgrounding uses it to hold a task assertion until BYE has been
    /// flushed, so the host learns immediately instead of waiting for its PONG
    /// timeout.
    func close(reason: String?, completion: (() -> Void)?) {
        // Strong captures on purpose: closing is terminal, and the owner
        // usually drops its reference in the same breath. Without them the
        // socket would outlive the object and stay open.
        queue.async {
            if let completion {
                if self.isClosed { completion(); return }
                self.closeCompletions.append(completion)
            }
            guard !self.isClosed, !self.isClosing else { return }
            self.isClosing = true
            self.pingTimer?.cancel()
            self.pingTimer = nil

            var content: Data?
            if let reason, let frame = try? Frame.json(.bye, Bye(reason: reason)) {
                content = self.sealIfNeeded(frame)?.encoded()
            }
            let finalReason = reason ?? "closed"
            self.connection.send(content: content, contentContext: .finalMessage, isComplete: true,
                                 completion: .contentProcessed { _ in
                self.finish(reason: finalReason)
            })
            // Never hang on a peer that stopped reading.
            self.queue.asyncAfter(deadline: .now() + 1.0) {
                self.finish(reason: finalReason)
            }
        }
    }

    deinit {
        // Last resort: an owner that simply dropped us must not leak a socket.
        pingTimer?.cancel()
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    /// Must be called on `queue`.
    private func sealIfNeeded(_ frame: Frame) -> Frame? {
        guard let cipher = sendCipher else { return frame }
        return try? cipher.seal(frame)
    }

    private func finish(reason: String) {
        guard !isClosed else { return }
        isClosed = true
        pingTimer?.cancel()
        pingTimer = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        delegate?.peerConnection(self, didCloseWith: reason)
        delegate = nil
        let completions = closeCompletions
        closeCompletions = []
        completions.forEach { $0() }
    }

    // MARK: - Reading

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.isClosed else { return }
            if let error {
                self.finish(reason: "receive failed: \(error.localizedDescription)")
                return
            }
            if let data, !data.isEmpty {
                self.parser.append(data)
                do {
                    while let frame = try self.parser.next() {
                        self.dispatch(frame)
                        if self.isClosed { return }
                    }
                } catch {
                    self.finish(reason: "protocol error: \(error)")
                    return
                }
            }
            if isComplete {
                self.finish(reason: "peer closed the connection")
                return
            }
            self.receiveLoop()
        }
    }

    private func dispatch(_ frame: Frame) {
        var incoming = frame
        if frame.type == .enc {
            guard let cipher = receiveCipher else {
                finish(reason: "encrypted frame before AUTH_OK")
                return
            }
            do {
                incoming = try cipher.open(frame)
            } catch {
                finish(reason: "decryption failed: \(error)")
                return
            }
        } else if receiveCipher != nil {
            // Once the envelope is active every frame must use it.
            finish(reason: "plaintext frame after AUTH_OK")
            return
        }

        switch incoming.type {
        case .ping:
            guard let ping = try? Ping(parsing: incoming.payload) else {
                finish(reason: "malformed PING")
                return
            }
            send(Pong(echoUs: ping.sentUs, receivedUs: monotonicMicros()).frame())
        case .pong:
            guard let pong = try? Pong(parsing: incoming.payload) else {
                finish(reason: "malformed PONG")
                return
            }
            handlePong(pong)
        default:
            delegate?.peerConnection(self, didReceive: incoming)
        }
    }

    // MARK: - Writing

    func send(_ frame: Frame) {
        queue.async { [weak self] in
            guard let self, !self.isClosed, !self.isClosing else { return }
            self.transmit(frame)
        }
    }

    /// Must be called on `queue`.
    private func transmit(_ frame: Frame) {
        guard let outgoing = sealIfNeeded(frame) else {
            finish(reason: "encryption failed")
            return
        }
        connection.send(content: outgoing.encoded(), completion: .contentProcessed { [weak self] error in
            guard let self, let error else { return }
            self.finish(reason: "send failed: \(error.localizedDescription)")
        })
    }

    func enableEncryption(hostToReceiver: Data, receiverToHost: Data) {
        queue.async { [weak self] in
            guard let self, !self.isClosed else { return }
            self.receiveCipher = SessionCipher(key: hostToReceiver)
            self.sendCipher = SessionCipher(key: receiverToHost)
        }
    }

    // MARK: - Liveness

    private func startPingTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Tandem.pingInterval, repeating: Tandem.pingInterval)
        timer.setEventHandler { [weak self] in self?.tick() }
        pingTimer = timer
        timer.resume()
    }

    private func tick() {
        guard !isClosed, !isClosing else { return }
        let now = CACurrentMediaTime()
        if awaitingPong, now - lastPongAt > Tandem.pongTimeout {
            finish(reason: "no PONG within \(Int(Tandem.pongTimeout)) s")
            return
        }
        lastPingSentUs = monotonicMicros()
        awaitingPong = true
        transmit(Ping(sentUs: lastPingSentUs).frame())
    }

    private func handlePong(_ pong: Pong) {
        lastPongAt = CACurrentMediaTime()
        awaitingPong = false
        let now = monotonicMicros()
        guard pong.echoUs <= now else { return }
        let rttUs = now - pong.echoUs
        let rttMs = Double(rttUs) / 1000.0
        let offset = Int64(bitPattern: pong.receivedUs) - Int64(bitPattern: pong.echoUs) - Int64(rttUs / 2)

        metricsLock.lock()
        smoothedRttMs = smoothedRttMs == 0 ? rttMs : (smoothedRttMs * 0.8 + rttMs * 0.2)
        offsetUs = offset
        metricsLock.unlock()
    }

    // MARK: - Endpoint classification

    static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            return address.isLoopback
        case .ipv6(let address):
            return address.isLoopback || address.asIPv4?.isLoopback == true
        case .name(let name, _):
            return name == "localhost" || name == "ip6-localhost"
        @unknown default:
            return false
        }
    }
}

extension PeerConnection: FrameChannel {
    var clockOffsetUs: Int64? {
        metricsLock.lock(); defer { metricsLock.unlock() }
        return offsetUs
    }
    var roundTripMs: Double {
        metricsLock.lock(); defer { metricsLock.unlock() }
        return smoothedRttMs
    }
}
