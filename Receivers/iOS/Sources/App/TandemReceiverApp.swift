import SwiftUI

@main
struct TandemReceiverApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.settings)
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { newPhase in
            model.scenePhaseChanged(newPhase)
        }
    }
}
