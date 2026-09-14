import SwiftUI
import TerasProtocol

struct IdleView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(colors: [Color(white: 0.08), Color.black],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Spacer()

                Text(model.settings.effectiveDeviceName)
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .minimumScaleFactor(0.5)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)

                Text(statusTitle)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))

                Text(L.s("idle.usbHint"))
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 40)

                wifiStatus
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.horizontal, 40)

                Spacer()

                Text(L.f("idle.port", Int(Teras.port)))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.white.opacity(0.25))
                    .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity)

            Button {
                model.isShowingSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(14)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text(L.key("settings.title")))
            .padding(.top, 8)
            .padding(.trailing, 8)
        }
    }

    private var statusTitle: String {
        switch model.phase {
        case .idle: return L.s("idle.title.waiting")
        case .connected, .authenticating, .preparing: return L.s("idle.title.connecting")
        case .pairing: return L.s("idle.title.pairing")
        case .streaming: return L.s("idle.title.connected")
        }
    }

    @ViewBuilder
    private var wifiStatus: some View {
        switch model.advertisement {
        case .advertising(let name):
            Text(L.f("idle.wifiOn", name))
        case .starting, .stopped:
            Text(L.key("idle.wifiStarting"))
        case .failed:
            Text(L.key("idle.wifiFailed"))
        }
    }
}
