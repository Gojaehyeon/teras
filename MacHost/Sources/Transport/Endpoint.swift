import Foundation
import Network
import TerasProtocol

/// Something the host can dial: a phone on a cable or a receiver on the network.
enum TerasEndpoint: Hashable, Identifiable, Sendable {
    case usbIOS(udid: String, deviceID: UInt32, name: String)
    case usbAndroid(serial: String, model: String)
    case lan(peer: LanPeer)

    /// Stable across replugs and reboots: it is what per-device settings,
    /// pairing secrets and display arrangement are filed under.
    var id: String {
        switch self {
        case .usbIOS(let udid, _, _): return "usb-ios:\(udid)"
        case .usbAndroid(let serial, _): return "usb-android:\(serial)"
        case .lan(let peer): return "lan:\(peer.deviceId)"
        }
    }

    var displayName: String {
        switch self {
        case .usbIOS(let udid, _, let name): return name.isEmpty ? udid : name
        case .usbAndroid(let serial, let model): return model.isEmpty ? serial : model
        case .lan(let peer): return peer.name
        }
    }

    var transport: Transport {
        switch self {
        case .usbIOS, .usbAndroid: return .usb
        case .lan: return .lan
        }
    }

    var platform: Platform {
        switch self {
        case .usbIOS: return .ios
        case .usbAndroid: return .android
        case .lan(let peer): return peer.platform
        }
    }

    var isUSB: Bool { transport == .usb }

    /// The adb serial, for the Android-only features (Teras Control).
    var androidSerial: String? {
        if case .usbAndroid(let serial, _) = self { return serial }
        return nil
    }
}

/// A live connection plus whatever has to be undone when it ends.
struct DialedConnection {
    let connection: NWConnection
    let transport: Transport
    private let teardown: (@Sendable () -> Void)?

    init(connection: NWConnection, transport: Transport, teardown: (@Sendable () -> Void)? = nil) {
        self.connection = connection
        self.transport = transport
        self.teardown = teardown
    }

    /// Cancel the connection and release transport resources (an adb forward,
    /// for instance). Safe to call more than once.
    func close() {
        connection.cancel()
        teardown?()
    }
}

enum DialerError: LocalizedError {
    case notReady(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .notReady(let detail): return "Could not open a connection: \(detail)."
        case .timedOut: return "The device did not accept a connection in time."
        }
    }
}

/// Turns an endpoint into a ready TCP-equivalent byte stream.
enum Dialer {
    static let connectTimeout: TimeInterval = 6

    static func dial(_ endpoint: TerasEndpoint, adb: AdbBridge) async throws -> DialedConnection {
        switch endpoint {
        case .usbIOS(_, let deviceID, _):
            // usbmuxd hands back a socket that is already a byte pipe to the
            // device's port; there is no Nagle to disable on it.
            let connection = try await UsbmuxClient.connect(deviceID: deviceID, port: Teras.port)
            return DialedConnection(connection: connection, transport: .usb)

        case .usbAndroid(let serial, _):
            let localPort = try adb.forward(serial: serial, remotePort: Teras.port)
            do {
                let connection = try await dialTCP(host: "127.0.0.1", port: UInt16(localPort), peerToPeer: false)
                return DialedConnection(connection: connection, transport: .usb, teardown: {
                    adb.removeForward(serial: serial, localPort: localPort)
                })
            } catch {
                adb.removeForward(serial: serial, localPort: localPort)
                throw error
            }

        case .lan(let peer):
            let connection = try await dialNetwork(peer.endpoint, peerToPeer: true)
            return DialedConnection(connection: connection, transport: .lan)
        }
    }

    private static func dialTCP(host: String, port: UInt16, peerToPeer: Bool) async throws -> NWConnection {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        return try await dialNetwork(endpoint, peerToPeer: peerToPeer)
    }

    private static func dialNetwork(_ endpoint: NWEndpoint, peerToPeer: Bool) async throws -> NWConnection {
        let options = NWProtocolTCP.Options()
        // Screen updates are latency critical and often smaller than the MSS,
        // so Nagle must be off (PROTOCOL §1).
        options.noDelay = true
        options.connectionTimeout = Int(connectTimeout)
        options.enableKeepalive = true
        options.keepaliveIdle = 10

        let parameters = NWParameters(tls: nil, tcp: options)
        parameters.includePeerToPeer = peerToPeer
        parameters.serviceClass = .responsiveData

        let connection = NWConnection(to: endpoint, using: parameters)
        try await waitUntilReady(connection)
        return connection
    }

    private static func waitUntilReady(_ connection: NWConnection) async throws {
        let queue = DispatchQueue(label: "app.teras.dialer")
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        let resumed = ResumeGuard()
                        connection.stateUpdateHandler = { state in
                            switch state {
                            case .ready:
                                if resumed.claim() { continuation.resume() }
                            case .failed(let error):
                                if resumed.claim() {
                                    continuation.resume(throwing: DialerError.notReady(error.localizedDescription))
                                }
                            case .cancelled:
                                if resumed.claim() { continuation.resume(throwing: DialerError.notReady("cancelled")) }
                            default:
                                break
                            }
                        }
                        connection.start(queue: queue)
                    }
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(connectTimeout * 1_000_000_000))
                    throw DialerError.timedOut
                }
                try await group.next()
                group.cancelAll()
            }
        } catch {
            connection.stateUpdateHandler = nil
            connection.cancel()
            throw error
        }
        connection.stateUpdateHandler = nil
    }
}
