import SwiftUI
import TandemCore

/// Entry point. Everything else lives in the TandemCore framework so the same
/// code can be exercised by the unit tests without launching the app.
@main
struct TandemApp: App {
    @NSApplicationDelegateAdaptor(TandemAppDelegate.self) private var appDelegate

    var body: some Scene {
        TandemRootScene()
    }
}
