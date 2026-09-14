import SwiftUI
import TandemProtocol

struct StatsOverlay: View {
    let stats: VideoStatsSnapshot
    let transport: Transport?
    let hostName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row(L.s("stats.transport"), transportLabel)
            row(L.s("stats.codec"), stats.codec.uppercased())
            row(L.s("stats.resolution"), "\(stats.width)×\(stats.height)")
            row(L.s("stats.fps"), String(format: "%.0f", stats.fpsDecoded))
            row(L.s("stats.dropped"), String(format: "%.0f", stats.fpsDropped))
            row(L.s("stats.decode"), String(format: "%.1f ms", stats.decodeMsP50))
            if let e2e = stats.e2eMsP50 {
                row(L.s("stats.e2e"), String(format: "%.1f ms", e2e))
            }
            if !hostName.isEmpty {
                row("Mac", hostName)
            }
        }
        .font(.caption2.monospaced())
        .foregroundStyle(.white.opacity(0.9))
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.55))
        )
    }

    private var transportLabel: String {
        switch transport {
        case .usb: return L.s("badge.usb")
        case .lan: return L.s("badge.wifi")
        case nil: return "—"
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 10) {
            Text(verbatim: label)
                .foregroundStyle(.white.opacity(0.55))
            Spacer(minLength: 8)
            Text(verbatim: value)
        }
        .frame(minWidth: 170, alignment: .leading)
    }
}
