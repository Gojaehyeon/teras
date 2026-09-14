import Foundation
import Network

/// A framed conversation with usbmuxd over its unix socket.
///
/// After a successful `Connect` the same socket becomes a transparent byte pipe
/// to the port on the device, so the `NWConnection` is handed straight to the
/// session layer rather than being torn down.
final class UsbmuxSocket {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "app.teras.usbmux", qos: .userInitiated)
    private var buffer = Data()
    private var nextTag: UInt32 = 1
    private var opened = false

    init() {
        connection = NWConnection(to: .unix(path: UsbmuxProtocol.socketPath), using: .tcp)
    }

    func open(timeout: TimeInterval = 5) async throws {
        guard !opened else { return }
        try await withDeadline(timeout) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let resumed = ResumeGuard()
                self.connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if resumed.claim() { continuation.resume() }
                    case .failed(let error):
                        if resumed.claim() { continuation.resume(throwing: UsbmuxError.socket(error.localizedDescription)) }
                    case .cancelled:
                        if resumed.claim() { continuation.resume(throwing: UsbmuxError.socket("cancelled")) }
                    default:
                        break
                    }
                }
                self.connection.start(queue: self.queue)
            }
        }
        opened = true
    }

    /// Send a request and return the tag it was sent with.
    @discardableResult
    func send(_ plist: [String: Any]) async throws -> UInt32 {
        let tag = nextTag
        nextTag &+= 1
        let data = try UsbmuxProtocol.encode(plist, tag: tag)
        try await sendRaw(data)
        return tag
    }

    func sendRaw(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = ResumeGuard()
            connection.send(content: data, completion: .contentProcessed { error in
                guard resumed.claim() else { return }
                if let error {
                    continuation.resume(throwing: UsbmuxError.socket(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func nextMessage(timeout: TimeInterval = 5) async throws -> UsbmuxProtocol.Message {
        try await withDeadline(timeout) {
            while true {
                if let message = try UsbmuxProtocol.decode(from: &self.buffer) { return message }
                try await self.readMore()
            }
        }
    }

    func nextLockdownReply(timeout: TimeInterval = 5) async throws -> [String: Any] {
        try await withDeadline(timeout) {
            while true {
                if let plist = try UsbmuxProtocol.decodeLockdownReply(from: &self.buffer) { return plist }
                try await self.readMore()
            }
        }
    }

    /// Expect a `Result` message and require it to be `Number = 0`.
    func expectOK(timeout: TimeInterval = 5) async throws {
        let message = try await nextMessage(timeout: timeout)
        switch UsbmuxProtocol.event(from: message) {
        case .result(.ok):
            return
        case .result(let result):
            throw UsbmuxError.failed(result)
        default:
            throw UsbmuxError.unexpectedReply(message.messageType ?? "unknown")
        }
    }

    private func readMore() async throws {
        let chunk: Data = try await withCheckedThrowingContinuation { continuation in
            let resumed = ResumeGuard()
            connection.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) { data, _, isComplete, error in
                guard resumed.claim() else { return }
                if let error {
                    continuation.resume(throwing: UsbmuxError.socket(error.localizedDescription))
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: UsbmuxError.socket("usbmuxd closed the connection"))
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
        buffer.append(chunk)
    }

    /// Hand the socket over as a byte pipe. Only valid right after a successful
    /// `Connect`, and only when usbmuxd sent nothing beyond the reply.
    func detach() throws -> NWConnection {
        guard buffer.isEmpty else {
            throw UsbmuxError.unexpectedReply("\(buffer.count) unread bytes after Connect")
        }
        connection.stateUpdateHandler = nil
        opened = false
        return connection
    }

    func close() {
        connection.stateUpdateHandler = nil
        connection.cancel()
        opened = false
    }

    /// Longest deadline we will actually arm a timer for. Anything above this
    /// (the device-event read, for instance) simply waits.
    private static let maxDeadline: TimeInterval = 86_400

    private func withDeadline<T: Sendable>(_ seconds: TimeInterval,
                                           _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        guard seconds.isFinite, seconds > 0, seconds <= Self.maxDeadline else {
            return try await body()
        }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw UsbmuxError.timedOut
            }
            guard let result = try await group.next() else { throw UsbmuxError.timedOut }
            group.cancelAll()
            return result
        }
    }
}

/// Makes sure a Network.framework callback resumes its continuation once.
final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !used else { return false }
        used = true
        return true
    }
}

/// iOS-over-USB transport: device discovery and port connections through the
/// usbmuxd daemon that ships with macOS.
enum UsbmuxClient {
    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: UsbmuxProtocol.socketPath)
    }

    static func listDevices(timeout: TimeInterval = 5) async throws -> [UsbmuxDevice] {
        let socket = UsbmuxSocket()
        defer { socket.close() }
        try await socket.open(timeout: timeout)
        try await socket.send(UsbmuxProtocol.listDevicesRequest())
        let message = try await socket.nextMessage(timeout: timeout)
        guard message.messageType == nil || message.messageType == "Result" || message.plist["DeviceList"] != nil else {
            throw UsbmuxError.unexpectedReply(message.messageType ?? "unknown")
        }
        if case .result(let result)? = UsbmuxProtocol.event(from: message), result != .ok {
            throw UsbmuxError.failed(result)
        }
        return UsbmuxProtocol.devices(fromListReply: message.plist)
    }

    /// Open a byte pipe to `port` on the device. The returned connection is
    /// already started; the caller owns cancelling it.
    static func connect(deviceID: UInt32, port: UInt16, timeout: TimeInterval = 5) async throws -> NWConnection {
        let socket = UsbmuxSocket()
        var handedOff = false
        defer { if !handedOff { socket.close() } }

        try await socket.open(timeout: timeout)
        try await socket.send(UsbmuxProtocol.connectRequest(deviceID: deviceID, port: port))
        try await socket.expectOK(timeout: timeout)
        let connection = try socket.detach()
        handedOff = true
        return connection
    }

    /// The user-visible device name, read from lockdownd. `GetValue DeviceName`
    /// is readable without a pairing session, so no trust prompt is involved.
    static func deviceName(deviceID: UInt32, timeout: TimeInterval = 5) async throws -> String? {
        let socket = UsbmuxSocket()
        defer { socket.close() }
        try await socket.open(timeout: timeout)
        try await socket.send(UsbmuxProtocol.connectRequest(deviceID: deviceID, port: UsbmuxProtocol.lockdownPort))
        try await socket.expectOK(timeout: timeout)
        try await socket.sendRaw(try UsbmuxProtocol.deviceNameRequest())
        let reply = try await socket.nextLockdownReply(timeout: timeout)
        return UsbmuxProtocol.deviceName(fromLockdownReply: reply)
    }

    /// Attach and detach events for as long as the stream is consumed.
    /// usbmuxd replays the currently attached devices right after `Listen`, so
    /// a fresh subscriber sees everything that is already plugged in.
    static func watch() -> AsyncStream<UsbmuxEvent> {
        AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    let socket = UsbmuxSocket()
                    do {
                        try await socket.open()
                        try await socket.send(UsbmuxProtocol.listenRequest())
                        try await socket.expectOK()
                        Log.info(.transport, "Listening to usbmuxd for device attach and detach")
                        while !Task.isCancelled {
                            // No deadline: this read blocks until a device event
                            // arrives, which can be hours.
                            let message = try await socket.nextMessage(timeout: .greatestFiniteMagnitude)
                            if let event = UsbmuxProtocol.event(from: message) {
                                continuation.yield(event)
                            }
                        }
                    } catch {
                        if !Task.isCancelled {
                            Log.debug(.transport, "usbmuxd listen ended: \(error.localizedDescription)")
                        }
                    }
                    socket.close()
                    guard !Task.isCancelled else { break }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
