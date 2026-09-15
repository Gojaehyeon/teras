import AppKit
import Combine
import Foundation
import SwiftUI

/// Top-level application state: discovery, sessions, permissions, and the
/// auxiliary windows a menu-bar app has to present for itself.
@MainActor
final class AppModel: ObservableObject {
    /// One model for the process. The app delegate starts it and the scene
    /// observes it, so both need the same instance.
    static let shared = AppModel()

    let sessions = SessionManager()
    let permissions: PermissionsModel

    @Published var activePINRequest: PINRequest?

    private var cancellables: Set<AnyCancellable> = []
    private var pairingWindow: NSWindow?
    private var onboardingWindow: NSWindow?

    init() {
        permissions = PermissionsModel(adb: sessions.adb)
    }

    func start() {
        permissions.startMonitoring()
        sessions.start()

        sessions.$pinRequest
            .receive(on: RunLoop.main)
            .sink { [weak self] request in
                self?.activePINRequest = request
                if request != nil {
                    self?.showPairingWindow()
                } else {
                    self?.closePairingWindow()
                }
            }
            .store(in: &cancellables)

        // Republish so menu content refreshes when device rows change.
        sessions.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        sessions.control.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        if !AppSettings.hasCompletedOnboarding || !permissions.hasEverything {
            showOnboarding()
        }
    }

    func shutdown() {
        permissions.stopMonitoring()
        sessions.shutdown()
    }

    var menuBarSymbol: String {
        "iphone.landscape"   // same glyph in every state so the menu bar never shifts
    }

    // MARK: - Windows
    //
    // A menu-bar app has no window of its own, and SwiftUI sheets cannot be
    // presented from a menu, so pairing and onboarding get real windows.

    func showPairingWindow() {
        guard activePINRequest != nil else { return }
        if let pairingWindow {
            NSApp.activate(ignoringOtherApps: true)
            pairingWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = Self.makeWindow(title: L("pairing.title"),
                                     size: NSSize(width: 380, height: 300),
                                     content: PairingView().environmentObject(self))
        window.isReleasedWhenClosed = false
        pairingWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.center()
    }

    func closePairingWindow() {
        pairingWindow?.orderOut(nil)
        pairingWindow = nil
    }

    func showOnboarding() {
        if let onboardingWindow {
            NSApp.activate(ignoringOtherApps: true)
            onboardingWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = Self.makeWindow(title: L("onboarding.title"),
                                     size: NSSize(width: 560, height: 520),
                                     content: OnboardingView().environmentObject(self))
        window.isReleasedWhenClosed = false
        onboardingWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.center()
    }

    func closeOnboarding() {
        AppSettings.hasCompletedOnboarding = true
        onboardingWindow?.orderOut(nil)
        onboardingWindow = nil
    }

    private static func makeWindow<Content: View>(title: String, size: NSSize, content: Content) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = title
        window.contentView = NSHostingView(rootView: content)
        window.setContentSize(size)
        window.level = .normal
        return window
    }
}
