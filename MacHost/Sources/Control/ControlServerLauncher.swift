import CryptoKit
import Foundation
import Network

enum ControlLaunchError: LocalizedError {
    case jarMissing
    case adbMissing
    case pushFailed(String)
    case processDied(String)
    case noForwardedPort(String)
    case handshakeTimedOut
    case injectionUnavailable
    case connectionFailed(String)
    case serverReported(String)

    var errorDescription: String? {
        switch self {
        case .jarMissing:
            return "The control server (teras-control.jar) is missing from this build of Teras."
        case .adbMissing:
            return "adb was not found. Install Android platform-tools to use Teras Control."
        case .pushFailed(let detail):
            return "Could not copy the control server to the device: \(detail)."
        case .processDied(let detail):
            return "The control server stopped on the device\(detail.isEmpty ? "" : ": \(detail)")."
        case .noForwardedPort(let output):
            return "adb did not report a forwarded port (output: \(output))."
        case .handshakeTimedOut:
            return "The control server did not answer in time."
        case .injectionUnavailable:
            return "This Android version does not let Teras inject input events."
        case .connectionFailed(let detail):
            return "Could not open the control connection: \(detail)."
        case .serverReported(let message):
            return message
        }
    }
}

/// Starts the Android-side control server for one device and keeps a live
/// socket to it (CONTROL.md §1–§2).
///
/// One instance owns exactly one device: the pushed jar, the `app_process`
/// child, the adb forward, the TCP connection and the 2 s heartbeat. Calling
/// `stop()` undoes all of it.
final class ControlServerLauncher: @unchecked Sendable {

    /// Where the jar lives on the device.
    static let remotePath = "/data/local/tmp/teras-control.jar"
    /// Entry point inside the jar.
    static let entryClass = "app.teras.control.Server"
    /// The server is started by the Mac, so a start that races the socket is
    /// normal; retry a few times before giving up.
    static let startAttempts = 3
    static let retryBackoff: TimeInterval = 1
    /// The server binds its socket a moment after the process starts, so the
    /// dial — not the whole launch — is what gets retried first.
    static let dialAttempts = 12
    static let dialBackoff: TimeInterval = 0.25
    static let handshakeTimeout: TimeInterval = 8
    static let pingInterval: TimeInterval = 2
    static let pingTimeout: TimeInterval = 6

    let serial: String

    private let adb: AdbBridge
    private let jarURL: URL?
    private let queue = DispatchQueue(label: "app.teras.control.link")

    private var process: Process?
    private var connection: NWConnection?
    private var forwardedPort: Int?
    private var parser = ControlFrameParser()
    private var heartbeat: DispatchSourceTimer?
    private var lastPongAt = Date()
    /// True once the transport has been torn down; reset between start attempts.
    private var stopped = false
    /// True once the owner asked for a stop. Never reset, so a retry in flight
    /// cannot bring the link back up.
    private var cancelled = false

    /// Called on `queue` whenever the phone reports its geometry.
    var onDisplayInfo: ((ControlDisplayInfo) -> Void)?
    /// Called on `queue` once, when the link goes away for any reason.
    var onClosed: ((String) -> Void)?
    /// Called on `queue` for a server-side ERROR that does not end the session.
    var onServerError: ((String) -> Void)?

    private(set) var displayInfo: ControlDisplayInfo?

    /// True while the socket is up and the heartbeat is running.
    var isLive: Bool { !stopped && connection != nil }

    init(serial: String, adb: AdbBridge, jarURL: URL? = ControlServerLauncher.bundledJarURL()) {
        self.serial = serial
        self.adb = adb
        self.jarURL = jarURL
    }

    /// The control server shipped inside the app bundle, if this build has one.
    static func bundledJarURL() -> URL? {
        Bundle.main.url(forResource: "teras-control", withExtension: "jar")
    }

    static var isAvailable: Bool { bundledJarURL() != nil }

    // MARK: - Start

    /// Push, launch, forward, dial and handshake. Returns once the server has
    /// answered READY and reported its display, or throws.
    func start() async throws -> ControlDisplayInfo {
        guard let jarURL else { throw ControlLaunchError.jarMissing }
        guard adb.isInstalled else { throw ControlLaunchError.adbMissing }

        try pushIfNeeded(jarURL)

        var lastError: Error = ControlLaunchError.handshakeTimedOut
        for attempt in 1...Self.startAttempts {
            do {
                return try await attemptStart()
            } catch {
                lastError = error
                Log.error(.control, "Control start attempt \(attempt)/\(Self.startAttempts) for \(serial) failed: \(error.localizedDescription)")
                tearDownTransport()
                guard attempt < Self.startAttempts, !cancelled else { break }
                try? await Task.sleep(nanoseconds: UInt64(Self.retryBackoff * 1_000_000_000))
            }
        }
        throw lastError
    }

    private func attemptStart() async throws -> ControlDisplayInfo {
        guard !cancelled else { throw ControlLaunchError.processDied("") }
        // A previous attempt may have marked the link closed; start clean.
        stopped = false
        sawReady = false
        displayInfo = nil
        parser = ControlFrameParser()

        let token = Self.makeToken()
        let socketName = "teras_control_\(token)"

        try launchServer(token: token)
        let port = try await forwardWithRetry(socketName: socketName)
        forwardedPort = port

        // `adb forward` succeeds as soon as the local listener exists, whether
        // or not the phone is listening on the abstract socket yet — and the
        // JVM needs a moment to get there. Until it does, adb accepts the TCP
        // connection and closes it again straight away, so the dial is retried
        // against the same server rather than launching a new one.
        var lastError: Error = ControlLaunchError.handshakeTimedOut
        for attempt in 1...Self.dialAttempts {
            guard !cancelled else { throw ControlLaunchError.processDied("") }
            if let process, !process.isRunning {
                throw ControlLaunchError.processDied("exit status \(process.terminationStatus)")
            }
            do {
                let info = try await connectAndHandshake(port: port)
                startHeartbeat()
                Log.info(.control, "Control ready on \(serial): \(info.width)×\(info.height) rot \(info.rotation)")
                return info
            } catch {
                lastError = error
                tearDownConnection()
                guard attempt < Self.dialAttempts else { break }
                Log.debug(.control, "Dial \(attempt)/\(Self.dialAttempts) to \(serial) failed: \(error.localizedDescription)")
                try? await Task.sleep(nanoseconds: UInt64(Self.dialBackoff * 1_000_000_000))
            }
        }
        throw lastError
    }

    // MARK: - Pushing the jar

    /// Copy the jar unless the device already has the identical file. Re-pushing
    /// a few hundred kilobytes on every enable is wasteful and slow over a poor
    /// cable, and md5 is only being used as a change detector here.
    private func pushIfNeeded(_ jarURL: URL) throws {
        let localData: Data
        do {
            localData = try Data(contentsOf: jarURL)
        } catch {
            throw ControlLaunchError.jarMissing
        }
        let localDigest = Insecure.MD5.hash(data: localData).map { String(format: "%02x", $0) }.joined()

        if let remote = remoteDigest(), remote == localDigest {
            Log.debug(.control, "\(serial) already has the current control server")
            return
        }

        do {
            _ = try adb.execute(["-s", serial, "push", jarURL.path, Self.remotePath], timeout: 60)
            Log.info(.control, "Pushed the control server to \(serial)")
        } catch {
            throw ControlLaunchError.pushFailed(error.localizedDescription)
        }
    }

    /// `md5sum` of the jar already on the device, or nil if it is absent or the
    /// device has no md5sum (very old builds), in which case we just re-push.
    private func remoteDigest() -> String? {
        guard let output = try? adb.execute(["-s", serial, "shell", "md5sum", Self.remotePath], timeout: 15) else {
            return nil
        }
        let first = output
            .split(whereSeparator: \.isNewline)
            .first?
            .split(separator: " ")
            .first
            .map(String.init)
        guard let digest = first, digest.count == 32, digest.allSatisfy({ $0.isHexDigit }) else { return nil }
        return digest.lowercased()
    }

    // MARK: - Launching

    private func launchServer(token: String) throws {
        let stderrPipe = Pipe()
        let stdoutPipe = Pipe()
        let arguments = [
            "-s", serial, "shell",
            "CLASSPATH=\(Self.remotePath)",
            "app_process", "/", Self.entryClass, token,
        ]
        let process = try adb.spawn(arguments, standardOutput: stdoutPipe, standardError: stderrPipe)
        self.process = process

        let serial = self.serial
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
                let text = line.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                Log.error(.control, "[\(serial)] \(text)")
            }
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
                let text = line.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                Log.info(.control, "[\(serial)] \(text)")
            }
        }
        Log.info(.control, "Started the control server on \(serial)")
    }

    private func forwardWithRetry(socketName: String) async throws -> Int {
        var lastOutput = ""
        for attempt in 1...6 {
            if let process, !process.isRunning {
                throw ControlLaunchError.processDied("exit status \(process.terminationStatus)")
            }
            do {
                let output = try adb.execute(["-s", serial, "forward", "tcp:0", "localabstract:\(socketName)"],
                                             timeout: 10)
                lastOutput = output
                if let port = AdbParsing.forwardedPort(from: output) {
                    Log.debug(.control, "Forwarded 127.0.0.1:\(port) to \(socketName) on \(serial)")
                    return port
                }
            } catch {
                lastOutput = error.localizedDescription
            }
            guard attempt < 6 else { break }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        throw ControlLaunchError.noForwardedPort(lastOutput.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Socket

    private func connectAndHandshake(port: Int) async throws -> ControlDisplayInfo {
        let options = NWProtocolTCP.Options()
        // Every message is a few bytes of input; Nagle would batch them into
        // visible pointer lag.
        options.noDelay = true
        options.connectionTimeout = 4
        let parameters = NWParameters(tls: nil, tcp: options)

        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1",
                                           port: NWEndpoint.Port(rawValue: UInt16(port))!)
        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection

        let handshake = HandshakeBox()

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receiveLoop()
                self.sendRaw(ControlProtocol.hello())
            case .failed(let error):
                handshake.fail(ControlLaunchError.connectionFailed(error.localizedDescription))
                self.handleClosed(error.localizedDescription)
            case .cancelled:
                handshake.fail(ControlLaunchError.connectionFailed("cancelled"))
            default:
                break
            }
        }

        pendingHandshake = handshake

        // The timeout is armed on the same queue the callbacks run on, rather
        // than raced as a second task: a checked continuation is not
        // cancellable, so a losing task group child would never finish and the
        // group would wait for it for ever.
        handshake.arm(timeout: Self.handshakeTimeout, on: queue, error: ControlLaunchError.handshakeTimedOut)
        connection.start(queue: queue)
        return try await handshake.value()
    }

    /// Set while the handshake is in flight; cleared once the link is up.
    /// CONTROL.md §5 sends READY and DISPLAY_INFO as two messages in no
    /// guaranteed order, so the handshake completes only when both have landed.
    private var pendingHandshake: HandshakeBox?
    private var sawReady = false

    private func completeHandshakeIfReady() {
        guard let handshake = pendingHandshake, sawReady, let info = displayInfo else { return }
        pendingHandshake = nil
        handshake.succeed(info)
    }

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                for message in self.parser.append(data) { self.handle(message) }
            }
            if let error {
                self.handleClosed(error.localizedDescription)
                return
            }
            if isComplete {
                self.handleClosed("the control server closed the connection")
                return
            }
            self.receiveLoop()
        }
    }

    private func handle(_ message: ControlInbound) {
        switch message {
        case .displayInfo(let info):
            let changed = displayInfo != info
            displayInfo = info
            completeHandshakeIfReady()
            if changed { onDisplayInfo?(info) }
        case .ready(let apiLevel, let injectionWorks):
            Log.info(.control, "\(serial) control server ready (API \(apiLevel), injection \(injectionWorks ? "ok" : "unavailable"))")
            guard injectionWorks else {
                let handshake = pendingHandshake
                pendingHandshake = nil
                handshake?.fail(ControlLaunchError.injectionUnavailable)
                handleClosed("input injection is unavailable on this device")
                return
            }
            sawReady = true
            completeHandshakeIfReady()
            // The server answers HELLO with DISPLAY_INFO, but ask again if it
            // has not arrived yet so a dropped answer cannot stall the start.
            if displayInfo == nil { sendRaw(ControlProtocol.getDisplay()) }
        case .pong:
            lastPongAt = Date()
        case .error(let text):
            Log.error(.control, "[\(serial)] server error: \(text)")
            if let handshake = pendingHandshake {
                pendingHandshake = nil
                handshake.fail(ControlLaunchError.serverReported(text))
            } else {
                onServerError?(text)
            }
        case .unknown(let type, _):
            Log.debug(.control, "[\(serial)] ignoring unknown message type 0x\(String(type, radix: 16))")
        }
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        pendingHandshake = nil
        lastPongAt = Date()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.pingInterval, repeating: Self.pingInterval)
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            if Date().timeIntervalSince(self.lastPongAt) > Self.pingTimeout {
                self.handleClosed("the control server stopped answering")
                return
            }
            self.sendRaw(ControlProtocol.ping(UInt64(Date().timeIntervalSince1970 * 1000)))
        }
        timer.resume()
        heartbeat = timer
    }

    // MARK: - Sending

    /// Queue a frame. Safe to call from any thread; dropped once stopped.
    func send(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [weak self] in self?.sendRaw(data) }
    }

    func send(_ frames: [Data]) {
        guard !frames.isEmpty else { return }
        queue.async { [weak self] in
            for frame in frames { self?.sendRaw(frame) }
        }
    }

    private func sendRaw(_ data: Data) {
        guard !stopped, let connection else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error { self?.handleClosed(error.localizedDescription) }
        })
    }

    // MARK: - Stopping

    func stop(sendBye: Bool = true) {
        queue.async { [weak self] in
            guard let self else { return }
            self.cancelled = true
            guard !self.stopped else { return }
            self.stopped = true
            if sendBye, let connection = self.connection, connection.state == .ready {
                connection.send(content: ControlProtocol.bye(), completion: .idempotent)
            }
            self.tearDownTransport()
            Log.info(.control, "Control stopped for \(self.serial)")
        }
    }

    private func handleClosed(_ reason: String) {
        // A drop during the handshake is usually just the phone not listening
        // yet. Fail this dial, keep the server process and the forward, and let
        // the caller try again.
        if let handshake = pendingHandshake {
            pendingHandshake = nil
            Log.debug(.control, "Dial to \(serial) dropped: \(reason)")
            handshake.fail(ControlLaunchError.connectionFailed(reason))
            return
        }
        guard !stopped else { return }
        stopped = true
        tearDownTransport()
        Log.info(.control, "Control link for \(serial) ended: \(reason)")
        onClosed?(reason)
    }

    /// Undo just the socket, leaving the server process and the adb forward in
    /// place so the next dial can reuse them.
    private func tearDownConnection() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        parser = ControlFrameParser()
        pendingHandshake = nil
        sawReady = false
        displayInfo = nil
        stopped = false
    }

    /// Undo everything the transport owns. Idempotent.
    private func tearDownTransport() {
        heartbeat?.cancel()
        heartbeat = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        parser = ControlFrameParser()

        if let port = forwardedPort {
            forwardedPort = nil
            _ = try? adb.execute(["-s", serial, "forward", "--remove", "tcp:\(port)"], timeout: 5)
        }
        if let process {
            self.process = nil
            (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            if process.isRunning { process.terminate() }
        }
    }

    // MARK: - Token

    /// 16 random hex characters, so a server left over from a previous launch
    /// is never mistaken for this one (CONTROL.md §2).
    static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 8)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// One-shot bridge from the connection's callbacks to the awaiting `start()`.
private final class HandshakeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ControlDisplayInfo, Error>?
    private var result: Result<ControlDisplayInfo, Error>?

    func value() async throws -> ControlDisplayInfo {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func succeed(_ info: ControlDisplayInfo) { finish(.success(info)) }
    func fail(_ error: Error) { finish(.failure(error)) }

    /// Fail the handshake if nothing has resolved it by `timeout`.
    func arm(timeout: TimeInterval, on queue: DispatchQueue, error: Error) {
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.fail(error)
        }
    }

    private func finish(_ outcome: Result<ControlDisplayInfo, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = outcome
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: outcome)
    }
}
