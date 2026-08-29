import AppStoreDirectKit
import SwiftUI

/// Every connected iPhone, with selection controls and live per-device status.
struct DevicesView: View {
    @Environment(AppModel.self) private var model

    private var devices: DeviceStore { model.devices }

    var body: some View {
        Group {
            if devices.devices.isEmpty {
                ContentUnavailableView {
                    Label("No iPhones connected", systemImage: "cable.connector.slash")
                } description: {
                    Text(devices.errorMessage
                         ?? "Connect one or more iPhones by USB. Unlock each one and tap Trust This Computer if prompted.")
                }
            } else {
                List {
                    Section {
                        ForEach(devices.devices) { device in
                            DeviceRow(device: device)
                        }
                    } header: {
                        selectionHeader
                    }

                    if !devices.unreachableUDIDs.isEmpty {
                        Section("Not Responding") {
                            ForEach(devices.unreachableUDIDs, id: \.self) { udid in
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(udid)
                                            .font(.system(.caption, design: .monospaced))
                                        Text("Unlock the device and tap Trust This Computer.")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: "lock.iphone").foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Devices")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await devices.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(devices.isRefreshing)
            }
        }
        .task { await devices.refreshInstalledAppsForSelection() }
    }

    private var selectionHeader: some View {
        HStack {
            Button(devices.isAllSelected ? "Deselect All" : "Select All") {
                devices.toggleSelectAll()
            }
            .buttonStyle(.link)
            .disabled(devices.devices.isEmpty)

            Spacer()

            Text("\(devices.selectedUDIDs.count) of \(devices.devices.count) selected")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.bottom, 2)
    }
}

/// One device: selection, identity, and whatever it is currently doing.
struct DeviceRow: View {
    let device: ConnectedDevice
    @Environment(AppModel.self) private var model

    private var isSelected: Bool { model.devices.isSelected(device) }
    private var activity: DeviceInstallState? { model.installs.currentState(udid: device.udid) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle(isOn: Binding(
                get: { isSelected },
                set: { _ in model.devices.toggle(device) }
            )) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(device.name).font(.headline)
                    Text(device.connection == .usb ? "USB" : "Wi-Fi")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(device.connection == .usb ? Color.green.opacity(0.18) : Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                        .foregroundStyle(device.connection == .usb ? .green : .secondary)
                }

                Text("\(device.marketingName) · iOS \(device.iosVersion)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(device.udid)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let activity {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(activity.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .padding(.top, 2)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                if let battery = device.batteryPercent {
                    Label("\(battery)%", systemImage: batterySymbol(battery))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(battery < 20 ? .orange : .secondary)
                        .labelStyle(.titleAndIcon)
                }
                Text("\(model.devices.installedApps(for: device.udid).count) apps")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { model.devices.toggle(device) }
        .contextMenu {
            Button("Select Only This Device") { model.devices.selectOnly(device) }
            Button("Refresh Installed Apps") {
                Task { await model.devices.refreshInstalledApps(for: device.udid) }
            }
        }
    }

    private func batterySymbol(_ percent: Int) -> String {
        switch percent {
        case ..<20:  return "battery.25"
        case ..<60:  return "battery.50"
        default:     return "battery.100"
        }
    }
}
