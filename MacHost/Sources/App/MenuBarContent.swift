import SwiftUI
import TandemProtocol

/// The menu that drops down from the menu-bar icon.
struct MenuBarContent: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            deviceSection(title: L("menu.usb"), rows: model.sessions.usbDevices)
            deviceSection(title: L("menu.wifi"), rows: model.sessions.lanDevices)

            if model.sessions.allDevices.isEmpty {
                Text(L("menu.noDevices"))
            }

            Divider()

            if !model.permissions.hasEverything {
                Button(L("menu.permissionsNeeded")) { model.showOnboarding() }
            }
            Button(L("menu.onboarding")) { model.showOnboarding() }
            SettingsLink { Text(L("menu.settings")) }
                .keyboardShortcut(",", modifiers: .command)

            Divider()
            Button(L("menu.quit")) { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
    }

    @ViewBuilder
    private func deviceSection(title: String, rows: [DeviceRow]) -> some View {
        if !rows.isEmpty {
            Section(title) {
                ForEach(rows) { row in
                    DeviceMenu(row: row)
                }
            }
        }
    }
}

/// One device and everything that can be done to it.
private struct DeviceMenu: View {
    @EnvironmentObject private var model: AppModel
    let row: DeviceRow

    var body: some View {
        Menu("\(row.name) — \(MenuBarContent.statusText(row))") {
            Button(row.isConnected ? L("menu.disconnect") : L("menu.connect")) {
                model.sessions.toggleConnection(row)
            }

            if let stats = row.stats {
                Divider()
                Text(L("stats.line", stats.fpsDecoded, row.rttMs))
                if !row.captureMethod.isEmpty {
                    Text(row.captureMethod)
                }
            }

            Divider()

            Menu(L("menu.quality")) {
                ForEach(QualityPreset.allCases, id: \.self) { preset in
                    Button(checkmark(settings.quality == preset) + preset.localizedName) {
                        model.sessions.setQuality(preset, for: row.id)
                    }
                }
            }

            Menu(L("menu.frameRate")) {
                ForEach(DeviceSettings.supportedFPS, id: \.self) { fps in
                    Button(checkmark(settings.normalizedFPS == fps) + L("fps.value", fps)) {
                        model.sessions.setFPS(fps, for: row.id)
                    }
                }
            }

            Button(checkmark(settings.hiDPI) + L("menu.hidpi")) {
                model.sessions.setHiDPI(!settings.hiDPI, for: row.id)
            }

            Button(checkmark(settings.mode == .mirror) + L("menu.mirror")) {
                model.sessions.setMode(settings.mode == .mirror ? .extend : .mirror, for: row.id)
            }
        }
    }

    private var settings: DeviceSettings {
        model.sessions.settings(for: row.id)
    }

    /// SwiftUI menu buttons do not carry a checked state, so the mark is part
    /// of the title.
    private func checkmark(_ on: Bool) -> String {
        on ? "✓ " : "   "
    }
}

extension MenuBarContent {
    static func statusText(_ row: DeviceRow) -> String {
        switch row.status {
        case .idle: return L("status.idle")
        case .connecting: return L("status.connecting")
        case .waitingForApp: return L("status.waitingForApp")
        case .unauthorized: return L("status.unauthorized")
        case .pairing(let attemptsLeft): return L("status.pairing", attemptsLeft)
        case .negotiating: return L("status.negotiating")
        case .streaming(let fps): return L("status.streaming", fps)
        case .failed(let reason): return L("status.failed", reason)
        }
    }
}
