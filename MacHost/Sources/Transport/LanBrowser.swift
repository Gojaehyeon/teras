import Foundation
import Network
import TerasProtocol

/// A receiver advertising itself on the local network.
struct LanPeer: Hashable, Identifiable, Sendable {
    var endpoint: NWEndpoint
    var deviceId: String
    var name: String
    var platform: Platform
    var protocolVersion: Int

    var id: String { deviceId }
}

/// Browses for `_teras._tcp`, including peer-to-peer interfaces so Apple
/// receivers are found over AWDL when there is no shared Wi-Fi network.
final class LanBrowser: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.teras.lanbrowser")
    private var browser: NWBrowser?
    private let lock = NSLock()
    private var latest: [LanPeer] = []
    private var browsing = false

    /// Called on an internal queue whenever the set of visible peers changes.
    var onPeersChanged: (([LanPeer]) -> Void)?
    /// Called when browsing cannot start, typically because the user denied
    /// Local Network access.
    var onFailure: ((Error) -> Void)?

    /// Read from the main thread while the browser updates it from its own
    /// queue, so it lives behind the same lock as the peer list.
    var isBrowsing: Bool {
        lock.lock(); defer { lock.unlock() }
        return browsing
    }

    private func setBrowsing(_ value: Bool) {
        lock.lock()
        browsing = value
        lock.unlock()
    }

    func start() {
        guard browser == nil else { return }

        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: Teras.bonjourServiceType, domain: nil)
        let browser = NWBrowser(for: descriptor, using: parameters)

        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.setBrowsing(true)
                Log.info(.transport, "Browsing for \(Teras.bonjourServiceType)")
            case .failed(let error):
                self.setBrowsing(false)
                Log.error(.transport, "Bonjour browsing failed: \(error.localizedDescription)")
                self.onFailure?(error)
            case .cancelled:
                self.setBrowsing(false)
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            let peers = results.compactMap(Self.peer(from:))
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            self.lock.lock()
            let changed = peers != self.latest
            self.latest = peers
            self.lock.unlock()
            if changed { self.onPeersChanged?(peers) }
        }

        self.browser = browser
        browser.start(queue: queue)
    }

    func stop() {
        browser?.stateUpdateHandler = nil
        browser?.browseResultsChangedHandler = nil
        browser?.cancel()
        browser = nil
        lock.lock()
        browsing = false
        latest = []
        lock.unlock()
    }

    var peers: [LanPeer] {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    /// Read one browse result, requiring the TXT record the protocol defines.
    /// A service without a usable `id` cannot be addressed, so it is dropped
    /// rather than shown as an unidentifiable row.
    static func peer(from result: NWBrowser.Result) -> LanPeer? {
        guard case .bonjour(let txt) = result.metadata else { return nil }
        let serviceName = Self.serviceName(of: result.endpoint)
        guard let deviceId = txt["id"], !deviceId.isEmpty else { return nil }
        let version = txt["pv"].flatMap(Int.init) ?? Teras.protocolVersion
        let platform = txt["plat"].flatMap(Platform.init(rawValue:)) ?? .ios
        let name = txt["name"].flatMap { $0.isEmpty ? nil : $0 } ?? serviceName ?? deviceId
        return LanPeer(endpoint: result.endpoint,
                       deviceId: deviceId,
                       name: name,
                       platform: platform,
                       protocolVersion: version)
    }

    static func serviceName(of endpoint: NWEndpoint) -> String? {
        if case .service(let name, _, _, _) = endpoint { return name }
        return nil
    }
}
