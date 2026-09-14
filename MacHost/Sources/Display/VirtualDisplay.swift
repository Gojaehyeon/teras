import AppKit
import CoreGraphics
import Foundation
import TerasProtocol
import CGVirtualDisplayBridge

//
//  Parts of this file (the descriptor/settings setup and the "physical display
//  stays main" safety net) are adapted from SideScreen (MIT licence) —
//  MacHost/Sources/VirtualDisplayManager.swift.
//  Copyright (c) SideScreen contributors. See THIRD_PARTY_NOTICES.md.
//

enum VirtualDisplayError: LocalizedError {
    case creationFailed
    case settingsRejected
    case notCreated
    case configuration(String)

    var errorDescription: String? {
        switch self {
        case .creationFailed:
            return "macOS refused to create the virtual display. "
                 + "This can happen after a system update; restarting the Mac usually clears it."
        case .settingsRejected: return "macOS rejected the virtual display mode."
        case .notCreated: return "No virtual display has been created yet."
        case .configuration(let detail): return "Display configuration failed: \(detail)"
        }
    }
}

/// What `DisplaySession` needs from a virtual display. A protocol so the
/// handshake can be tested without touching WindowServer.
@MainActor
protocol VirtualDisplayHosting: AnyObject {
    var displayID: CGDirectDisplayID? { get }
    var bounds: CGRect? { get }
    func create(spec: VirtualDisplaySpec, name: String, mode: DisplayMode) throws
    func setMode(_ mode: DisplayMode) throws
    func destroy()
}

/// One `CGVirtualDisplay`, owned by one session.
///
/// Identity is derived from the receiver: the serial number is a hash of its
/// device id, so macOS files the arrangement (position, rotation, mirroring)
/// under that device and restores it the next time the same phone connects.
@MainActor
final class VirtualDisplay: VirtualDisplayHosting {
    /// "TErAS" — our vendor id in the EDID macOS synthesises.
    static let vendorID: UInt32 = 0x7E5A

    private let deviceId: String
    private var display: CGVirtualDisplay?
    private var descriptor: CGVirtualDisplayDescriptor?
    private var settings: CGVirtualDisplaySettings?
    private var screenParamsObserver: NSObjectProtocol?
    private var currentMode: DisplayMode = .extend

    /// Called when WindowServer tears the display down under us.
    var onTerminated: (() -> Void)?

    init(deviceId: String) {
        self.deviceId = deviceId
    }

    deinit {
        if let token = screenParamsObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    var displayID: CGDirectDisplayID? { display?.displayID }

    var bounds: CGRect? {
        guard let id = displayID else { return nil }
        return CGDisplayBounds(id)
    }

    var isActive: Bool { display != nil }

    // MARK: - Lifecycle

    func create(spec: VirtualDisplaySpec, name: String, mode: DisplayMode) throws {
        destroy()

        let physW = spec.encodedWidth
        let physH = spec.encodedHeight

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.name = name
        descriptor.maxPixelsWide = UInt32(physW)
        descriptor.maxPixelsHigh = UInt32(physH)
        descriptor.vendorID = Self.vendorID
        descriptor.productID = Self.productID(width: physW, height: physH)
        descriptor.serialNum = Self.serialNumber(forDeviceId: deviceId)
        // macOS only offers HiDPI modes on a panel dense enough to deserve
        // them, and it works that out from the physical size we declare here.
        let ppi: Double = spec.hiDPI ? 220 : 110
        descriptor.sizeInMillimeters = CGSize(width: Double(physW) * 25.4 / ppi,
                                              height: Double(physH) * 25.4 / ppi)
        descriptor.queue = DispatchQueue.main
        descriptor.terminationHandler = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                Log.error(.display, "WindowServer terminated the virtual display for \(self.deviceId)")
                self.display = nil
                self.onTerminated?()
            }
        }
        self.descriptor = descriptor

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = spec.hiDPI ? 1 : 0
        var modes: [CGVirtualDisplayMode] = []
        if spec.hiDPI {
            // The physical-resolution mode is the anchor that tells macOS the
            // panel is high density; the logical mode is the one it selects.
            modes.append(CGVirtualDisplayMode(width: UInt32(physW),
                                              height: UInt32(physH),
                                              refreshRate: Double(spec.refreshHz)))
        }
        modes.append(CGVirtualDisplayMode(width: UInt32(spec.logicalWidth),
                                          height: UInt32(spec.logicalHeight),
                                          refreshRate: Double(spec.refreshHz)))
        settings.modes = modes
        self.settings = settings

        guard let created = CGVirtualDisplay(descriptor: descriptor) else {
            self.descriptor = nil
            self.settings = nil
            throw VirtualDisplayError.creationFailed
        }
        guard created.apply(settings) else {
            self.display = created
            destroy()
            throw VirtualDisplayError.settingsRejected
        }
        display = created

        Log.info(.display, "Created virtual display \(created.displayID) for \(deviceId): "
                 + "\(spec.logicalWidth)x\(spec.logicalHeight)"
                 + (spec.hiDPI ? " HiDPI (\(physW)x\(physH))" : "")
                 + " @ \(spec.refreshHz)Hz")

        registerScreenParamsObserver()
        restorePosition()
        try? setMode(mode)
        ensurePhysicalStaysMain()
    }

    func destroy() {
        guard display != nil else { return }
        savePosition()
        removeScreenParamsObserver()
        display = nil
        descriptor = nil
        settings = nil
        currentMode = .extend
        Log.info(.display, "Destroyed virtual display for \(deviceId)")
    }

    // MARK: - Identity

    /// Product id from the pixel size so portrait and landscape are distinct
    /// panels as far as macOS is concerned.
    nonisolated static func productID(width: Int, height: Int) -> UInt32 {
        UInt32(truncatingIfNeeded: width &* 10_000 &+ height)
    }

    /// Stable 32-bit serial for a receiver (FNV-1a over the device id), so the
    /// arrangement macOS remembers is per device rather than per session.
    nonisolated static func serialNumber(forDeviceId deviceId: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in deviceId.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        // 0 reads as "no serial" in some EDID parsers.
        return hash == 0 ? 1 : hash
    }

    // MARK: - Mirror / extend

    func setMode(_ mode: DisplayMode) throws {
        guard let display else { throw VirtualDisplayError.notCreated }
        let target: CGDirectDisplayID = mode == .mirror
            ? CGMainDisplayID()
            : CGDirectDisplayID(kCGNullDirectDisplay)
        if mode == .mirror, target == display.displayID {
            throw VirtualDisplayError.configuration("cannot mirror a display onto itself")
        }

        try withDisplayConfiguration { config in
            let result = CGConfigureDisplayMirrorOfDisplay(config, display.displayID, target)
            guard result == .success else {
                throw VirtualDisplayError.configuration("mirror: \(result.rawValue)")
            }
        }
        currentMode = mode
        Log.info(.display, "Virtual display \(display.displayID) set to \(mode.rawValue)")
    }

    // MARK: - Position persistence

    private var positionKey: String { "display.position.\(deviceId)" }

    func savePosition() {
        guard let bounds, currentMode == .extend else { return }
        // A display parked at the main slot is not a position worth restoring.
        guard bounds.origin != .zero else { return }
        UserDefaults.standard.set([Int(bounds.origin.x), Int(bounds.origin.y)], forKey: positionKey)
    }

    func restorePosition() {
        guard let display,
              let stored = UserDefaults.standard.array(forKey: positionKey) as? [Int],
              stored.count == 2 else { return }
        let (x, y) = (Int32(clamping: stored[0]), Int32(clamping: stored[1]))
        // (0,0) is the main slot. Re-taking it would move the menu bar onto a
        // screen the user may not be able to see.
        guard !(x == 0 && y == 0) else { return }
        do {
            try withDisplayConfiguration { config in
                let result = CGConfigureDisplayOrigin(config, display.displayID, x, y)
                guard result == .success else {
                    throw VirtualDisplayError.configuration("origin: \(result.rawValue)")
                }
            }
            Log.debug(.display, "Restored position (\(x), \(y)) for \(deviceId)")
        } catch {
            Log.error(.display, "Could not restore position for \(deviceId): \(error.localizedDescription)")
        }
    }

    // MARK: - Main-display safety net

    private func registerScreenParamsObserver() {
        guard screenParamsObserver == nil else { return }
        screenParamsObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.ensurePhysicalStaysMain()
            }
        }
    }

    private func removeScreenParamsObserver() {
        if let token = screenParamsObserver {
            NotificationCenter.default.removeObserver(token)
            screenParamsObserver = nil
        }
    }

    /// Whenever a physical display is online, the main slot must belong to it.
    /// If the virtual display takes the main slot, the menu bar, the Dock and
    /// keyboard focus all move onto a screen that may be in the user's pocket,
    /// which looks exactly like a hung Mac.
    func ensurePhysicalStaysMain() {
        guard let displayID else { return }
        guard CGMainDisplayID() == displayID,
              let physicalMain = onlinePhysicalDisplays().first else { return }

        let parkX = Int32(clamping: Int(CGDisplayBounds(physicalMain).width))
        do {
            try withDisplayConfiguration { config in
                var result = CGConfigureDisplayOrigin(config, physicalMain, 0, 0)
                if result == .success {
                    result = CGConfigureDisplayOrigin(config, displayID, parkX, 0)
                }
                guard result == .success else {
                    throw VirtualDisplayError.configuration("rearrange: \(result.rawValue)")
                }
            }
            Log.info(.display, "Physical display restored as main; virtual display parked beside it")
        } catch {
            Log.error(.display, "Could not restore the physical display as main: \(error.localizedDescription)")
        }
    }

    /// Online displays that are not ours. Filtered by vendor id so a stale
    /// Teras display from a previous run is never mistaken for a real screen.
    private func onlinePhysicalDisplays() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(32, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).filter { id in
            id != displayID && CGDisplayVendorNumber(id) != Self.vendorID
        }
    }

    // MARK: - Helpers

    /// Run a display reconfiguration as one transaction. Changes are session
    /// scoped on purpose: writing them into WindowServer's permanent preferences
    /// lets it re-adopt the virtual display as main on a later boot.
    private func withDisplayConfiguration(_ body: (CGDisplayConfigRef) throws -> Void) throws {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else {
            throw VirtualDisplayError.configuration("could not begin a display configuration")
        }
        do {
            try body(config)
        } catch {
            CGCancelDisplayConfiguration(config)
            throw error
        }
        let result = CGCompleteDisplayConfiguration(config, .forSession)
        guard result == .success else {
            throw VirtualDisplayError.configuration("could not complete: \(result.rawValue)")
        }
    }
}
