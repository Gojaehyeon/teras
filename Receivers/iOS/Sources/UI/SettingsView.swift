import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: UserSettings
    @Environment(\.dismiss) private var dismiss
    @State private var pairedHosts: [PairedHost] = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L.s("settings.deviceName"),
                              text: $settings.deviceNameOverride,
                              prompt: Text(verbatim: DeviceMetrics.systemDeviceName))
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                } header: {
                    Text(L.key("settings.section.device"))
                } footer: {
                    Text(L.key("settings.deviceName.footer"))
                }

                Section {
                    Toggle(L.s("settings.showStats"), isOn: $settings.showStats)
                } header: {
                    Text(L.key("settings.section.display"))
                } footer: {
                    Text(L.key("settings.showStats.footer"))
                }

                Section {
                    if pairedHosts.isEmpty {
                        Text(L.key("settings.noPairedHosts"))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(pairedHosts) { host in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: host.name.isEmpty ? host.id : host.name)
                                    Text(host.lastSeen, style: .date)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(L.s("settings.forget"), role: .destructive) {
                                    model.forgetHost(host)
                                    reload()
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                } header: {
                    Text(L.key("settings.section.pairedHosts"))
                }

                Section {
                    LabeledContent(L.s("settings.version")) {
                        Text(verbatim: model.appVersion)
                    }
                    LabeledContent(L.s("settings.deviceId")) {
                        Text(verbatim: String(model.deviceId.prefix(8)))
                            .monospaced()
                    }
                } header: {
                    Text(L.key("settings.section.about"))
                }
            }
            .navigationTitle(Text(L.key("settings.title")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L.s("settings.done")) { dismiss() }
                }
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        pairedHosts = model.pairingStore.pairedHosts
    }
}
