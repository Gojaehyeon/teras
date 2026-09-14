import SwiftUI
import UIKit
import TerasProtocol

/// Hosts the existing `VideoRendererView` / `InputBridge` instances owned by
/// `AppModel` so the decoder survives SwiftUI view updates.
private struct HostedView<V: UIView>: UIViewRepresentable {
    let view: V
    func makeUIView(context: Context) -> V { view }
    func updateUIView(_ uiView: V, context: Context) {}
}

struct StreamingView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            HostedView(view: model.renderer)
                .ignoresSafeArea()

            HostedView(view: model.inputBridge)
                .ignoresSafeArea()

            if model.isShowingStatsOverlay {
                StatsOverlay(stats: model.stats,
                             transport: model.transport,
                             hostName: model.hostName)
                    .padding(.top, 12)
                    .padding(.trailing, 12)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: model.isShowingStatsOverlay)
        .onAppear { model.inputBridge.becomeFirstResponder() }
        .onDisappear { model.inputBridge.resignFirstResponder() }
    }
}
