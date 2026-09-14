import AppKit
import CoreGraphics
import Combine
import Foundation
import ServiceManagement

/// Live view of the system permissions Tandem depends on.
///
/// macOS gives no notification when the user flips one of these, so the model
/// re-checks on a timer and whenever the app becomes active.
@MainActor
final class PermissionsModel: ObservableObject {
    @Published private(set) var hasScreenRecording = false
    @Published private(set) var hasAccessibility = false
    @Published private(set) var adbPath: String?
    @Published private(set) var launchesAtLogin = false

    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?
    private let adb: AdbBridge

    init(adb: AdbBridge) {
        self.adb = adb
        refresh()
    }

    deinit {
        timer?.invalidate()
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    func startMonitoring() {
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 1
        self.timer = timer

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        hasScreenRecording = CGPreflightScreenCaptureAccess()
        hasAccessibility = InputInjector.isTrusted()
        adbPath = adb.adbPath
        launchesAtLogin = SMAppService.mainApp.status == .enabled
    }

    var hasEverything: Bool { hasScreenRecording && hasAccessibility }

    // MARK: - Requests

    /// Ask for Screen Recording. The first call shows the system prompt; after
    /// that macOS only opens Settings, so the UI offers that too.
    func requestScreenRecording() {
        if CGRequestScreenCaptureAccess() {
            refresh()
        } else {
            openScreenRecordingSettings()
        }
    }

    func requestAccessibility() {
        _ = InputInjector.isTrusted(promptIfNeeded: true)
        refresh()
    }

    func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    func openAccessibilitySettings() {
        InputInjector.openAccessibilitySettings()
    }

    func openLocalNetworkSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")
    }

    func setLaunchesAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.error(.app, "Could not change the login item: \(error.localizedDescription)")
        }
        refresh()
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
