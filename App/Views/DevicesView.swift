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

                    if !devices.unreachable.isEmpty {
                        Section("Not Responding (\(devices.unreachable.count))") {
                            ForEach(devices.unreachable) { entry in
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.udid)
                                            .font(.system(.caption, design: .monospaced))
                                            .textSelection(.enabled)
                                        // The device's own failure, not a guess:
                                        // under load this is where usbmuxd errors show.
                                        Text(entry.reason)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                } icon: {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
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
                    Task {
                        await devices.refresh()
                        await devices.refreshInstalledAppsForAll()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(devices.isRefreshing)
            }
        }
        .task {
            // Every device, not just the selected ones: the tracked-app badges below
            // are a fleet view and must be accurate for phones that are not ticked.
            await model.icons.load(countryCode: model.countryCode)
            await devices.refreshInstalledAppsForAll()
        }
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

                TrackedAppBadges(udid: device.udid)
                    .padding(.top, 3)

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


/// Which tracked apps are present on one device, as small App Store icons.
///
/// The presence answer comes from that device's real `instproxy_browse` listing,
/// matched by bundle identifier — never from what this app believes it installed.
struct TrackedAppBadges: View {
    let udid: String
    @Environment(AppModel.self) private var model

    private var installed: [TrackedApp] {
        model.devices.trackedAppsInstalled(on: udid)
    }

    var body: some View {
        if !model.devices.hasReadInstalledApps(for: udid) {
            HStack(spacing: 5) {
                ProgressView().controlSize(.small).scaleEffect(0.55)
                Text("Reading apps…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        } else if installed.isEmpty {
            Text("No tracked apps installed")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        } else {
            HStack(spacing: 5) {
                ForEach(installed) { app in
                    TrackedAppIcon(app: app)
                }
            }
        }
    }
}

/// One badge. Falls back to the app's initial if the artwork has not loaded, so a
/// present app is never rendered as absent just because an icon is missing.
struct TrackedAppIcon: View {
    let app: TrackedApp
    @Environment(AppModel.self) private var model

    private let side: CGFloat = 20

    var body: some View {
        Group {
            if let image = model.icons.icon(for: app) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.quaternary)
                    Text(app.name.prefix(1))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
        .help("\(app.name) is installed on this device")
        .accessibilityLabel("\(app.name) installed")
    }
}
