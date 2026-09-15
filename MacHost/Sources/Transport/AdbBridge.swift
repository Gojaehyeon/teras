import Foundation

enum AdbError: LocalizedError {
    case notInstalled
    case commandFailed(String, Int32, String)
    case noForwardedPort(String)
    case deviceNotUsable(AdbDeviceState)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "adb was not found. Install Android platform-tools to use Android devices over USB."
        case .commandFailed(let command, let status, let output):
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return "adb \(command) exited with status \(status)\(detail.isEmpty ? "" : ": \(detail)")."
        case .noForwardedPort(let output):
            return "adb did not report the port it forwarded (output: \(output))."
        case .deviceNotUsable(let state):
            switch state {
            case .unauthorized:
                return "The device has not accepted this Mac. Unlock it and tap Allow on the USB debugging prompt."
            default:
                return "The device is \(state.rawValue) and cannot accept a connection yet."
            }
        }
    }
}

/// Android-over-USB transport.
///
/// Teras runs its own adb server on a private port so it never fights Android
/// Studio's server for device ownership, and shuts that server down on quit.
final class AdbBridge: @unchecked Sendable {
    /// Private adb server port; Android Studio uses the default 5037.
    static let serverPort = 5037

    private let lock = NSLock()
    private var cachedPath: String?
    private var startedServer = false
    private var activeForwards: [String: Int] = [:]   // serial → local port

    init() {}

    // MARK: - Locating adb

    /// Where adb might live, in preference order. A copy bundled in the app
    /// wins so a user without Android tooling still gets a working setup.
    static func candidatePaths() -> [String] {
        var paths: [String] = []
        if let bundled = Bundle.main.url(forResource: "adb", withExtension: nil)?.path {
            paths.append(bundled)
        }
        paths.append(contentsOf: [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            NSString(string: "~/Library/Android/sdk/platform-tools/adb").expandingTildeInPath,
        ])
        return paths
    }

    var adbPath: String? {
        lock.lock()
        if let cachedPath {
            lock.unlock()
            return cachedPath
        }
        lock.unlock()

        var found: String?
        for path in Self.candidatePaths() where FileManager.default.isExecutableFile(atPath: path) {
            found = path
            break
        }
        if found == nil {
            found = Self.which("adb")
        }
        lock.lock()
        cachedPath = found
        lock.unlock()
        if let found {
            Log.info(.transport, "Using adb at \(found)")
        }
        return found
    }

    var isInstalled: Bool { adbPath != nil }

    private static func which(_ tool: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", tool]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    // MARK: - Server lifecycle

    /// True when something already accepts connections on the adb server port.
    static func isServerListening() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var tv = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(serverPort).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return result == 0
    }

    @discardableResult
    func startServer() -> Bool {
        guard adbPath != nil else { return false }
        do {
            // The port is shared with Android Studio and the user's own adb.
            // Only claim ownership (and therefore the right to kill-server on
            // quit) when nothing was listening before we started it.
            let alreadyRunning = Self.isServerListening()
            _ = try run(["start-server"], timeout: 20)
            lock.lock(); startedServer = !alreadyRunning; lock.unlock()
            Log.info(.transport, "adb server running on port \(Self.serverPort)"
                     + (alreadyRunning ? " (pre-existing, will be left running)" : " (started by Teras)"))
            return true
        } catch {
            Log.error(.transport, "Could not start the adb server: \(error.localizedDescription)")
            return false
        }
    }

    func killServer() {
        lock.lock()
        let shouldKill = startedServer
        startedServer = false
        let forwards = activeForwards
        activeForwards.removeAll()
        lock.unlock()

        for (serial, port) in forwards {
            _ = try? run(["-s", serial, "forward", "--remove", "tcp:\(port)"], timeout: 5)
        }
        guard shouldKill, adbPath != nil else { return }
        _ = try? run(["kill-server"], timeout: 10)
        Log.info(.transport, "adb server stopped")
    }

    // MARK: - Devices

    func devices() throws -> [AdbDevice] {
        let output = try run(["devices", "-l"], timeout: 10)
        return AdbParsing.parseDeviceList(output)
    }

    func model(serial: String) -> String? {
        guard let output = try? run(["-s", serial, "shell", "getprop", "ro.product.model"], timeout: 5) else {
            return nil
        }
        return AdbParsing.model(from: output)
    }

    /// Long-running `track-devices`, restarted if it dies. Each element is the
    /// full device list as adb currently sees it.
    func watch() -> AsyncStream<[AdbDevice]> {
        AsyncStream { continuation in
            let task = Task.detached { [weak self] in
                while !Task.isCancelled {
                    guard let self, let path = self.adbPath else {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        continue
                    }
                    // Seed with a snapshot so the UI is populated even if
                    // nothing changes for a long time.
                    if let initial = try? self.devices() {
                        continuation.yield(initial.map { self.withModel($0) })
                    }

                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: path)
                    process.arguments = ["-P", "\(Self.serverPort)", "track-devices"]
                    let pipe = Pipe()
                    process.standardOutput = pipe
                    process.standardError = Pipe()

                    do {
                        try process.run()
                    } catch {
                        Log.error(.transport, "adb track-devices could not start: \(error.localizedDescription)")
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        continue
                    }
                    Log.debug(.transport, "adb track-devices started")

                    let handle = pipe.fileHandleForReading
                    var buffer = ""
                    while !Task.isCancelled {
                        let chunk = handle.availableData
                        if chunk.isEmpty { break }
                        buffer += String(decoding: chunk, as: UTF8.self)
                        for snapshot in AdbParsing.takeSnapshots(from: &buffer) {
                            continuation.yield(snapshot.map { self.withModel($0) })
                        }
                        // A snapshot with no trailing blank line still tells us
                        // something; emit it once the stream goes quiet.
                        if !buffer.isEmpty, buffer.hasSuffix("\n") {
                            let pending = AdbParsing.parseDeviceList(buffer)
                            if !pending.isEmpty {
                                continuation.yield(pending.map { self.withModel($0) })
                                buffer = ""
                            }
                        }
                    }

                    process.terminate()
                    process.waitUntilExit()
                    guard !Task.isCancelled else { break }
                    Log.debug(.transport, "adb track-devices ended; retrying")
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func withModel(_ device: AdbDevice) -> AdbDevice {
        guard device.model == nil, device.state.isUsable else { return device }
        var copy = device
        copy.model = model(serial: device.serial)
        return copy
    }

    // MARK: - Port forwarding

    /// Forward a free local port to `remotePort` on the device and return the
    /// local port adb chose.
    @discardableResult
    func forward(serial: String, remotePort: UInt16) throws -> Int {
        let output = try run(["-s", serial, "forward", "tcp:0", "tcp:\(remotePort)"], timeout: 10)
        guard let port = AdbParsing.forwardedPort(from: output) else {
            throw AdbError.noForwardedPort(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        lock.lock(); activeForwards[serial] = port; lock.unlock()
        Log.info(.transport, "Forwarded 127.0.0.1:\(port) to \(serial):\(remotePort)")
        return port
    }

    func removeForward(serial: String, localPort: Int) {
        lock.lock()
        if activeForwards[serial] == localPort { activeForwards.removeValue(forKey: serial) }
        lock.unlock()
        _ = try? run(["-s", serial, "forward", "--remove", "tcp:\(localPort)"], timeout: 5)
        Log.debug(.transport, "Removed forward tcp:\(localPort) for \(serial)")
    }

    // MARK: - Arbitrary commands

    /// Run an adb command and return its standard output.
    ///
    /// Exposed so features outside the display session — Teras Control pushes
    /// a jar and starts a process — reuse the same adb binary, private server
    /// port and timeout handling instead of shelling out on their own.
    @discardableResult
    func execute(_ arguments: [String], timeout: TimeInterval = 20) throws -> String {
        try run(arguments, timeout: timeout)
    }

    /// Start a long-running adb command the caller owns. The returned process
    /// is already running; the caller must terminate it.
    func spawn(_ arguments: [String], standardOutput: Pipe?, standardError: Pipe?) throws -> Process {
        guard let path = adbPath else { throw AdbError.notInstalled }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-P", "\(Self.serverPort)"] + arguments
        process.standardOutput = standardOutput ?? Pipe()
        process.standardError = standardError ?? Pipe()
        do {
            try process.run()
        } catch {
            throw AdbError.commandFailed(arguments.joined(separator: " "), -1, error.localizedDescription)
        }
        return process
    }

    // MARK: - Process plumbing

    @discardableResult
    private func run(_ arguments: [String], timeout: TimeInterval) throws -> String {
        guard let path = adbPath else { throw AdbError.notInstalled }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-P", "\(Self.serverPort)"] + arguments
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw AdbError.commandFailed(arguments.joined(separator: " "), -1, error.localizedDescription)
        }

        // Read both pipes on background queues so a chatty command cannot fill
        // a pipe buffer and deadlock against waitUntilExit.
        let collector = OutputCollector()
        let readQueue = DispatchQueue(label: "app.teras.adb.read", attributes: .concurrent)
        readQueue.async { collector.appendOutput(outputPipe.fileHandleForReading.readDataToEndOfFile()) }
        readQueue.async { collector.appendError(errorPipe.fileHandleForReading.readDataToEndOfFile()) }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            throw AdbError.commandFailed(arguments.joined(separator: " "), -1, "timed out after \(Int(timeout))s")
        }
        process.waitUntilExit()

        // Give the readers a moment to drain now that the process is gone.
        readQueue.sync(flags: .barrier) {}

        let standardOutput = collector.output()
        guard process.terminationStatus == 0 else {
            throw AdbError.commandFailed(arguments.joined(separator: " "),
                                         process.terminationStatus,
                                         collector.error() + standardOutput)
        }
        return standardOutput
    }
}

/// Thread-safe accumulator for the two pipes of a subprocess.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var outputData = Data()
    private var errorData = Data()

    func appendOutput(_ data: Data) { lock.lock(); outputData.append(data); lock.unlock() }
    func appendError(_ data: Data) { lock.lock(); errorData.append(data); lock.unlock() }

    func output() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: outputData, as: UTF8.self)
    }

    func error() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: errorData, as: UTF8.self)
    }
}
