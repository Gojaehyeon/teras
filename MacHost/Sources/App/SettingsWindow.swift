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
            ControlSettingsTab()
                .tabItem { Label(L("settings.control"), systemImage: "cursorarrow.motionlines") }
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

/// Teras Control: which Android devices the cursor may cross onto, and how it
/// behaves once it is there (CONTROL.md §7).
private struct ControlSettingsTab: View {
    @EnvironmentObject private var model: AppModel

    private var control: ControlManager { model.sessions.control }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(L("control.title")).font(.headline)
                Text(L("control.help"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !control.isSupported {
                    Label(L("control.error.notBundled"), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }

                if !model.permissions.hasAccessibility {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("control.accessibilityNote"))
                                .fixedSize(horizontal: false, vertical: true)
                            Button(L("control.openAccessibility")) {
                                model.permissions.openAccessibilitySettings()
                            }
                            .buttonStyle(.link)
                        }
                    }
                }

                Divider()

                if control.availableSerials.isEmpty {
                    Text(L("control.noDevices"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 24)
                } else {
                    ForEach(control.availableSerials, id: \.self) { serial in
                        ControlDeviceRow(serial: serial)
                    }
                }
            }
            .padding()
        }
    }
}

private struct ControlDeviceRow: View {
    @EnvironmentObject private var model: AppModel
    let serial: String

    private var control: ControlManager { model.sessions.control }
    private var settings: DeviceSettings { control.settings(for: serial) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(control.names[serial] ?? serial, isOn: Binding(
                get: { control.isEnabled(serial: serial) },
                set: { control.setEnabled($0, serial: serial) }
            ))
            .font(.headline)
            .disabled(!control.isSupported)

            Text(MenuBarContent.controlStatusText(control.status(serial: serial), edge: settings.controlEdge))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker(L("control.edge"), selection: Binding(
                get: { settings.controlEdge },
                set: { control.setEdge($0, serial: serial) }
            )) {
                Text(L("control.edge.right")).tag(ControlEdge.right)
                Text(L("control.edge.left")).tag(ControlEdge.left)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)

            HStack(spacing: 12) {
                Text(L("control.speed"))
                Slider(value: Binding(
                    get: { settings.normalizedControlSpeed },
                    set: { control.setSpeed($0, serial: serial) }
                ), in: DeviceSettings.controlSpeedRange, step: 0.1)
                .frame(maxWidth: 220)
                Text(L("control.speedValue", settings.normalizedControlSpeed))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
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
