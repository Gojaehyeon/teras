import SwiftUI
import TerasCore

/// Entry point. Everything else lives in the TerasCore framework so the same
/// code can be exercised by the unit tests without launching the app.
@main
struct TerasApp: App {
    @NSApplicationDelegateAdaptor(TerasAppDelegate.self) private var appDelegate

    var body: some Scene {
        TerasRootScene()
    }
}
