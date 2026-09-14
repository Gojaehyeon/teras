import AppKit
import SwiftUI

/// Application delegate for the menu-bar app. Owns start-up and shutdown so
/// discovery runs whether or not the user has opened the menu.
@MainActor
public final class TerasAppDelegate: NSObject, NSApplicationDelegate {
    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.start()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
    }

    public func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

/// The whole user interface: a menu-bar item and a Settings window.
public struct TerasRootScene: Scene {
    @ObservedObject private var model = AppModel.shared

    public init() {}

    public var body: some Scene {
        MenuBarExtra {
            MenuBarContent().environmentObject(model)
        } label: {
            Image(systemName: model.menuBarSymbol)
                .accessibilityLabel(Text(L("app.name")))
        }

        Settings {
            SettingsView().environmentObject(model)
        }
    }
}
