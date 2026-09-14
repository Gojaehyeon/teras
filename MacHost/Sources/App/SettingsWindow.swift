import SwiftUI
import TerasProtocol

/// The Settings window: general preferences, paired devices, permissions and
/// a live log.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label(L("settings.general"), systemImage: "gearshape") }
            DevicesSettingsTab()
                .tabItem { Label(L("settings.devices"), systemImage: "iphone") }
            PermissionsSettingsTab()
                .tabItem { Label(L("settings.permissions"), systemImage: "lock.shield") }
            DiagnosticsTab()
                .tabItem { Label(L("settings.diagnostics"), systemImage: "doc.text.magnifyingglass") }
        }
        .environmentObject(model)
        .frame(width: 560, height: 420)
    }
}

private struct GeneralSettingsTab: View {
    @EnvironmentObject private var model: AppModel
    @State private var launchAtLogin = false
    @State private var showStats = AppSettings.showStats

    var body: some View {
        Form {
            Toggle(L("settings.launchAtLogin"), isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    model.permissions.setLaunchesAtLogin(newValue)
                }
            Toggle(L("settings.showStats"), isOn: $showStats)
                .onChange(of: showStats) { _, newValue in
                    AppSettings.showStats = newValue
                }

            Section {
                LabeledContent(L("settings.hostName"), value: HostIdentity.hostName)
                LabeledContent(L("settings.hostId"), value: HostIdentity.hostId)
                LabeledContent(L("settings.version"),
                               value: "\(HostIdentity.appInfo.version) (\(HostIdentity.appInfo.build))")
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = model.permissions.launchesAtLogin }
    }
}

private struct DevicesSettingsTab: View {
    @EnvironmentObject private var model: AppModel
    @State private var paired: [(deviceId: String, name: String)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("settings.pairedDevices")).font(.headline)
            Text(L("settings.pairedDevicesHelp")).font(.callout).foregroundStyle(.secondary)

            if paired.isEmpty {
                Spacer()
                Text(L("settings.noPairedDevices"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                List(paired, id: \.deviceId) { device in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(device.name)
                            Text(device.deviceId).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle(L("settings.autoConnect"), isOn: autoConnectBinding(for: device.deviceId))
                            .toggleStyle(.switch)
                            .labelsHidden()
                        Button(L("settings.forget")) {
                            model.sessions.forgetPairing(deviceId: device.deviceId)
                            reload()
                        }
                    }
                }
            }
        }
        .padding()
        .onAppear(perform: reload)
    }

    private func reload() {
        paired = model.sessions.pairedDevices()
    }

    private func autoConnectBinding(for deviceId: String) -> Binding<Bool> {
        let key = "lan:\(deviceId)"
        return Binding(
            get: { model.sessions.settings(for: key).autoConnect },
            set: { newValue in
                model.sessions.settingsStore.update(key) { $0.autoConnect = newValue }
            }
        )
    }
}

private struct PermissionsSettingsTab: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PermissionRow(title: L("permission.screenRecording"),
                              detail: L("permission.screenRecordingHelp"),
                              granted: model.permissions.hasScreenRecording,
                              actionTitle: L("permission.grant"),
                              action: { model.permissions.requestScreenRecording() },
                              secondaryTitle: L("permission.openSettings"),
                              secondaryAction: { model.permissions.openScreenRecordingSettings() })

                PermissionRow(title: L("permission.accessibility"),
                              detail: L("permission.accessibilityHelp"),
                              granted: model.permissions.hasAccessibility,
                              actionTitle: L("permission.grant"),
                              action: { model.permissions.requestAccessibility() },
                              secondaryTitle: L("permission.openSettings"),
                              secondaryAction: { model.permissions.openAccessibilitySettings() })

                PermissionRow(title: L("permission.localNetwork"),
                              detail: L("permission.localNetworkHelp"),
                              granted: model.sessions.isBrowsingLAN,
                              actionTitle: L("permission.openSettings"),
                              action: { model.permissions.openLocalNetworkSettings() })

                PermissionRow(title: L("permission.android"),
                              detail: model.permissions.adbPath.map { L("permission.adbFound", $0) }
                                  ?? L("permission.adbMissing"),
                              granted: model.permissions.adbPath != nil,
                              actionTitle: L("permission.refresh"),
                              action: { model.permissions.refresh() })

                Text(L("permission.androidSteps"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let actionTitle: String
    let action: () -> Void
    var secondaryTitle: String?
    var secondaryAction: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? Color.green : Color.orange)
                .font(.title2)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                if !granted {
                    Button(actionTitle, action: action)
                }
                if let secondaryTitle, let secondaryAction {
                    Button(secondaryTitle, action: secondaryAction).buttonStyle(.link)
                }
            }
        }
    }
}

private struct DiagnosticsTab: View {
    @State private var entries: [LogEntry] = []
    @State private var generation: UInt64 = 0
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("settings.diagnosticsHelp")).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(L("settings.copyLog")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(LogRing.shared.plainText(), forType: .string)
                }
                Button(L("settings.clearLog")) {
                    LogRing.shared.clear()
                    reload()
                }
            }

            ScrollViewReader { proxy in
                List(entries) { entry in
                    Text(entry.line)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(entry.level == .error ? Color.red : Color.primary)
                        .id(entry.id)
                }
                .onChange(of: entries.count) { _, _ in
                    if let last = entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .padding()
        .onAppear(perform: reload)
        .onReceive(refresh) { _ in reload() }
    }

    private func reload() {
        let current = LogRing.shared.currentGeneration()
        guard current != generation else { return }
        generation = current
        entries = LogRing.shared.snapshot().suffix(500)
    }
}
