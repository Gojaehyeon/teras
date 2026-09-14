import Foundation
import Network
import TandemProtocol

/// The frame-level conversation with one receiver.
///
/// Callbacks are delivered on the main queue. `send` is safe to call from any
/// thread, which matters because encoded video arrives on the encoder's thread.
protocol PeerChannel: AnyObject {
    /// Begin reading. `onFrame` sees every decrypted, non-liveness frame.
    func start(onFrame: @escaping (Frame) -> Void, onFailure: @escaping (Error) -> Void)
    /// Send a control frame.
    func send(_ frame: Frame)
    /// Send a video frame; counts against `videoBacklog` until the socket takes it.
    func sendVideo(_ frame: Frame)
    /// Switch both directions to the encrypted envelope, starting with the next frame.
    func enableEncryption(h2r: Data, r2h: Data)
    /// Round-trip time from the most recent PING/PONG exchange.
    var rttMs: Double { get }
    /// Video frames handed to the socket but not yet written.
    var videoBacklog: Int { get }
    func cancel()
}

enum PeerConnectionError: LocalizedError {
    case framing(String)
    case transport(String)
    case pongTimeout
    case closedByPeer(String)

    var errorDescription: String? {
        switch self {
        case .framing(let detail): return "The device sent something we could not read: \(detail)."
        case .transport(let detail): return "The connection failed: \(detail)."
        case .pongTimeout: return "The device stopped answering (no PONG within \(Int(Tandem.pongTimeout))s)."
        case .closedByPeer(let reason): return reason.isEmpty ? "The device closed the session." : reason
        }
    }
}

/// `PeerChannel` over a Network.framework connection.
final class PeerConnection: PeerChannel, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "app.tandem.peer", qos: .userInitiated)
    private let sendQueue = DispatchQueue(label: "app.tandem.peer.send", qos: .userInteractive)

    private let stateLock = NSLock()
    private var parser = FrameParser()
    private var sendCipher: SessionCipher?
    private var receiveCipher: SessionCipher?
    private var backlog = 0
    private var lastRTT: Double = 0
    private var lastPongAt = Date()
    private var closed = false

    private var pingTimer: DispatchSourceTimer?
    private var onFrame: ((Frame) -> Void)?
    private var onFailure: ((Error) -> Void)?

    init(connection: NWConnection) {
        self.connection = connection
    }

    deinit {
        pingTimer?.cancel()
    }

    var rttMs: Double {
        stateLock.lock(); defer { stateLock.unlock() }
        return lastRTT
    }

    var videoBacklog: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return backlog
    }

    // MARK: - Lifecycle

    func start(onFrame: @escaping (Frame) -> Void, onFailure: @escaping (Error) -> Void) {
        stateLock.lock()
        self.onFrame = onFrame
        self.onFailure = onFailure
        lastPongAt = Date()
        stateLock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed(let error):
                self.fail(PeerConnectionError.transport(error.localizedDescription))
            case .cancelled:
                break
            case .waiting(let error):
                Log.debug(.session, "Connection waiting: \(error.localizedDescription)")
            default:
                break
            }
        }
        receiveLoop()
        startLivenessTimer()
    }

    func cancel() {
        stateLock.lock()
        guard !closed else { stateLock.unlock(); return }
        closed = true
        onFrame = nil
        onFailure = nil
        stateLock.unlock()

        pingTimer?.cancel()
        pingTimer = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    // MARK: - Sending

    func send(_ frame: Frame) {
        transmit(frame, isVideo: false)
    }

    func sendVideo(_ frame: Frame) {
        transmit(frame, isVideo: true)
    }

    private func transmit(_ frame: Frame, isVideo: Bool) {
        stateLock.lock()
        guard !closed else { stateLock.unlock(); return }
        // Sealing and enqueueing have to happen together: the envelope counter
        // must reach the peer in the order it was assigned.
        let data: Data
        if let cipher = sendCipher {
            do {
                data = try cipher.seal(frame).encoded()
            } catch {
                stateLock.unlock()
                fail(PeerConnectionError.framing("could not encrypt a \(frame.type) frame"))
                return
            }
        } else {
            data = frame.encoded()
        }
        if isVideo { backlog += 1 }
        stateLock.unlock()

        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if isVideo {
                self.stateLock.lock()
                self.backlog = max(0, self.backlog - 1)
                self.stateLock.unlock()
            }
            if let error {
                self.fail(PeerConnectionError.transport(error.localizedDescription))
            }
        })
    }

    func enableEncryption(h2r: Data, r2h: Data) {
        stateLock.lock()
        sendCipher = SessionCipher(key: h2r)
        receiveCipher = SessionCipher(key: r2h)
        stateLock.unlock()
        Log.info(.session, "Session encryption enabled")
    }

    // MARK: - Receiving

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.fail(PeerConnectionError.transport(error.localizedDescription))
                return
            }
            if let data, !data.isEmpty {
                self.ingest(data)
            }
            if isComplete {
                self.fail(PeerConnectionError.closedByPeer(""))
                return
            }
            self.stateLock.lock()
            let stillOpen = !self.closed
            self.stateLock.unlock()
            if stillOpen { self.receiveLoop() }
        }
    }

    private func ingest(_ data: Data) {
        var delivered: [Frame] = []
        stateLock.lock()
        parser.append(data)
        do {
            while let raw = try parser.next() {
                let frame: Frame
                if raw.type == .enc {
                    guard let cipher = receiveCipher else {
                        stateLock.unlock()
                        fail(PeerConnectionError.framing("encrypted frame before the session key was agreed"))
                        return
                    }
                    frame = try cipher.open(raw)
                } else {
                    frame = raw
                }
                delivered.append(frame)
            }
        } catch {
            stateLock.unlock()
            fail(PeerConnectionError.framing(String(describing: error)))
            return
        }
        stateLock.unlock()

        for frame in delivered {
            route(frame)
        }
    }

    /// Liveness is handled here rather than in the session so a busy main
    /// thread can never make a healthy device look dead.
    private func route(_ frame: Frame) {
        switch frame.type {
        case .ping:
            guard let ping = try? Ping(parsing: frame.payload) else { return }
            send(Pong(echoUs: ping.sentUs, receivedUs: monotonicMicros()).frame())
        case .pong:
            guard let pong = try? Pong(parsing: frame.payload) else { return }
            let now = monotonicMicros()
            let rtt = now >= pong.echoUs ? Double(now - pong.echoUs) / 1000 : 0
            stateLock.lock()
            lastRTT = rtt
            lastPongAt = Date()
            stateLock.unlock()
        default:
            stateLock.lock()
            let handler = onFrame
            stateLock.unlock()
            guard let handler else { return }
            DispatchQueue.main.async { handler(frame) }
        }
    }

    // MARK: - Liveness

    private func startLivenessTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Tandem.pingInterval, repeating: Tandem.pingInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let closed = self.closed
            let silentFor = Date().timeIntervalSince(self.lastPongAt)
            self.stateLock.unlock()
            guard !closed else { return }
            if silentFor > Tandem.pongTimeout {
                self.fail(PeerConnectionError.pongTimeout)
                return
            }
            self.send(Ping(sentUs: monotonicMicros()).frame())
        }
        timer.resume()
        pingTimer = timer
    }

    private func fail(_ error: Error) {
        stateLock.lock()
        guard !closed else { stateLock.unlock(); return }
        closed = true
        let handler = onFailure
        onFrame = nil
        onFailure = nil
        stateLock.unlock()

        pingTimer?.cancel()
        pingTimer = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        guard let handler else { return }
        DispatchQueue.main.async { handler(error) }
    }
}
