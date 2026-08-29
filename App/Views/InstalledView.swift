import AppStoreDirectKit
import SwiftUI

/// Apps already on the devices, one section per selected device.
struct InstalledView: View {
    @Environment(AppModel.self) private var model

    private var devices: DeviceStore { model.devices }
    private var shown: [ConnectedDevice] {
        devices.hasSelection ? devices.selectedDevices : devices.devices
    }

    var body: some View {
        Group {
            if devices.devices.isEmpty {
                ContentUnavailableView(
                    "No iPhone connected",
                    systemImage: "cable.connector.slash",
                    description: Text("Connect an iPhone by USB to see the apps on it.")
                )
            } else {
                List {
                    ForEach(shown) { device in
                        Section {
                            let apps = devices.installedApps(for: device.udid)
                            if devices.isLoadingInstalled(for: device.udid) && apps.isEmpty {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("Reading…").font(.caption).foregroundStyle(.secondary)
                                }
                            } else if apps.isEmpty {
                                Text("No user apps installed.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(apps) { app in
                                    HStack(spacing: 12) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(app.name).font(.callout.weight(.medium))
                                            Text(app.bundleIdentifier)
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                        }
                                        Spacer()
                                        Text(app.shortVersion)
                                            .font(.caption)
                                            .monospacedDigit()
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        } header: {
                            HStack {
                                Text("\(device.name) · iOS \(device.iosVersion)")
                                Spacer()
                                Text("\(devices.installedApps(for: device.udid).count)")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Installed")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        for device in shown {
                            await devices.refreshInstalledApps(for: device.udid)
                        }
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(devices.devices.isEmpty)
            }
        }
        .task {
            for device in shown {
                await devices.refreshInstalledApps(for: device.udid)
            }
        }
    }
}
