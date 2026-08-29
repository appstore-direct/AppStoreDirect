import AppStoreDirectKit
import SwiftUI

/// Every connected iPhone, as selectable cards.
struct DevicesView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("devicesCompactDensity") private var isCompact = false

    private var devices: DeviceStore { model.devices }

    var body: some View {
        Group {
            if devices.devices.isEmpty && devices.unreachable.isEmpty {
                EmptyStateView(
                    symbol: "cable.connector.slash",
                    title: "No iPhones Connected",
                    message: devices.errorMessage
                        ?? "Connect one or more iPhones by USB. Unlock each one and tap Trust This Computer if prompted."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: isCompact ? 4 : 6) {
                        ForEach(devices.devices) { device in
                            DeviceCardView(device: device, density: isCompact ? .compact : .comfortable)
                        }

                        if !devices.unreachable.isEmpty {
                            SectionHeader(title: "Not Responding", count: devices.unreachable.count)
                                .padding(.top, 10)
                            ForEach(devices.unreachable) { entry in
                                UnreachableDeviceRow(entry: entry)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .animation(.smooth(duration: 0.25), value: devices.devices)
                }
                .scrollContentBackground(.hidden)
                .safeAreaInset(edge: .top, spacing: 0) { selectionBar }
            }
        }
        .navigationTitle("Devices")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("Density", selection: $isCompact) {
                    Image(systemName: "list.bullet").tag(true)
                    Image(systemName: "square.grid.2x2").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Switch between compact and comfortable layout")
            }
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
            // Every device, not only the selected ones: the tracked-app badges are
            // a fleet view and must be right for phones that are not ticked.
            await model.icons.load(countryCode: model.countryCode)
            await devices.refreshInstalledAppsForAll()
        }
    }

    private var selectionBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(devices.isAllSelected ? "Deselect All" : "Select All") {
                    withAnimation(.snappy(duration: 0.2)) { devices.toggleSelectAll() }
                }
                .buttonStyle(.link)
                .disabled(devices.devices.isEmpty)

                if devices.isRefreshing {
                    ProgressView().controlSize(.small)
                }

                Spacer()

                Text("\(devices.selectedUDIDs.count) of \(devices.devices.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider()
        }
        .background(.bar)
    }
}

/// A quiet section heading for lists that are not `Form`s.
struct SectionHeader: View {
    let title: String
    var count: Int?

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .kerning(0.6)
            if let count {
                Text("\(count)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            Spacer()
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 2)
    }
}
