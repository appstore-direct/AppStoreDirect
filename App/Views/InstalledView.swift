import AppStoreDirectKit
import SwiftUI

/// Apps already on the devices, grouped by phone.
struct InstalledView: View {
    @Environment(AppModel.self) private var model

    private var devices: DeviceStore { model.devices }
    private var shown: [ConnectedDevice] {
        devices.hasSelection ? devices.selectedDevices : devices.devices
    }

    var body: some View {
        Group {
            if devices.devices.isEmpty {
                EmptyStateView(
                    symbol: "cable.connector.slash",
                    title: "No iPhones Connected",
                    message: "Connect an iPhone by USB to see the apps on it."
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(shown) { device in
                            deviceSection(device)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                .scrollContentBackground(.hidden)
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

    @ViewBuilder
    private func deviceSection(_ device: ConnectedDevice) -> some View {
        let apps = devices.installedApps(for: device.udid)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "iphone.gen3").foregroundStyle(.secondary)
                Text(device.name).font(.headline)
                Text("iOS \(device.iosVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(apps.count)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            VStack(spacing: 0) {
                if devices.isLoadingInstalled(for: device.udid) && apps.isEmpty {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("Reading apps…").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(Metric.cardPadding)
                } else if apps.isEmpty {
                    HStack {
                        Text("No user apps installed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(Metric.cardPadding)
                } else {
                    ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(app.name).font(.callout.weight(.medium))
                                Text(app.bundleIdentifier)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 8)
                            Text(app.shortVersion)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .padding(.horizontal, Metric.cardPadding)
                        .padding(.vertical, 7)

                        if index < apps.count - 1 {
                            Divider().padding(.leading, Metric.cardPadding)
                        }
                    }
                }
            }
            .cardSurface()
        }
    }
}
