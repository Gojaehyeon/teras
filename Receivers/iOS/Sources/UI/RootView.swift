import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()
                if model.isStreaming {
                    StreamingView()
                        .transition(.opacity)
                } else {
                    IdleView()
                        .transition(.opacity)
                }
                if case .pairing(let pin, let attemptsLeft) = model.phase {
                    PairingView(pin: pin, attemptsLeft: attemptsLeft)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: model.phase)
            .onChange(of: proxy.size) { _ in
                model.geometryDidChange()
            }
        }
        .ignoresSafeArea()
        .statusBarHidden(model.isStreaming)
        .persistentSystemOverlays(model.isStreaming ? .hidden : .automatic)
        .sheet(isPresented: $model.isShowingSettings) {
            SettingsView()
                .environmentObject(model)
                .environmentObject(model.settings)
        }
        .onAppear { model.start() }
    }
}
