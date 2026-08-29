import AppStoreDirectKit
import SwiftUI

/// One connected iPhone.
///
/// Two densities, because twenty phones and one phone want different layouts:
/// `.comfortable` gives each device room, `.compact` fits the fleet on screen.
struct DeviceCardView: View {
    let device: ConnectedDevice
    var density: Density = .comfortable

    @Environment(AppModel.self) private var model
    @State private var isHovering = false

    enum Density { case comfortable, compact }

    private var isSelected: Bool { model.devices.isSelected(device) }
    private var activity: DeviceInstallState? { model.installs.currentState(udid: device.udid) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle(isOn: Binding(
                get: { isSelected },
                set: { _ in model.devices.toggle(device) }
            )) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: density == .compact ? 2 : 4) {
                header
                subtitle

                if density == .comfortable {
                    Text(device.udid)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if let activity {
                    HStack(spacing: 6) {
                        StatusBadge(state: activity)
                        if let fraction = activity.fraction, activity.isActive {
                            ProgressView(value: fraction)
                                .progressViewStyle(.linear)
                                .tint(activity.tint)
                                .frame(maxWidth: 130)
                        }
                    }
                    .padding(.top, 2)
                    .transition(.opacity)
                } else {
                    InstalledAppBadgeRow(udid: device.udid)
                        .padding(.top, density == .compact ? 1 : 3)
                }
            }

            Spacer(minLength: 6)
            trailing
        }
        .padding(density == .compact ? 9 : Metric.cardPadding)
        .cardSurface(isHighlighted: isHovering, isSelected: isSelected)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { model.devices.toggle(device) }
        .contextMenu {
            Button("Select Only This Device") { model.devices.selectOnly(device) }
            Button("Refresh Installed Apps") {
                Task { await model.devices.refreshInstalledApps(for: device.udid) }
            }
        }
        .animation(.smooth(duration: 0.25), value: activity)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(device.name)
                .font(density == .compact ? .subheadline.weight(.semibold) : .headline)
                .lineLimit(1)
            StatusBadge(
                text: device.connection == .usb ? "Connected" : "Wi-Fi",
                symbol: device.connection == .usb ? "cable.connector" : "wifi",
                tint: device.connection == .usb ? .green : .secondary,
                prominence: device.connection == .usb ? .tinted : .subtle
            )
        }
    }

    private var subtitle: some View {
        Text("\(device.marketingName) · iOS \(device.iosVersion)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private var trailing: some View {
        VStack(alignment: .trailing, spacing: 3) {
            if let battery = device.batteryPercent {
                Label {
                    Text("\(battery)%").monospacedDigit()
                } icon: {
                    Image(systemName: batterySymbol(battery))
                }
                .font(.caption)
                .foregroundStyle(battery < 20 ? .orange : .secondary)
            }
            Text("\(model.devices.installedApps(for: device.udid).count) apps")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
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

/// A device usbmuxd reports but that could not be described, with the real reason.
/// Shown rather than dropped, so a phone is never silently missing from the fleet.
struct UnreachableDeviceRow: View {
    let entry: DeviceStore.UnreachableDevice

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.udid)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(entry.reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Metric.cardPadding)
        .cardSurface()
    }
}
