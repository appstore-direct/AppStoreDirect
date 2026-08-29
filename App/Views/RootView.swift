import AppStoreDirectKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarSection = .apps

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(SidebarSection.allCases) { section in
                    Label(section.rawValue, systemImage: section.symbol)
                        .badge(badge(for: section))
                        .tag(section)
                }
            }
            // The sidebar list style is what gives the vibrant background and the
            // modern selection capsule; both come from the system rather than
            // being drawn by hand.
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 196, ideal: 214, max: 260)
            .safeAreaInset(edge: .bottom, spacing: 0) { DeviceSummaryBar() }
        } detail: {
            Group {
                switch selection {
                case .apps:      AppsView()
                case .installed: InstalledView()
                case .devices:   DevicesView()
                case .settings:  SettingsView()
                }
            }
            .navigationSplitViewColumnWidth(min: 560, ideal: 760)
        }
        .sheet(isPresented: signInBinding) { SignInView() }
    }

    /// Device count on Devices; work in flight on Apps.
    private func badge(for section: SidebarSection) -> Int {
        switch section {
        case .devices: return model.devices.devices.count
        case .apps:    return model.installs.overallSummary.working
        default:       return 0
        }
    }

    private var signInBinding: Binding<Bool> {
        @Bindable var model = model
        return Binding(
            get: { model.needsTwoFactorCode || model.isPresentingSignIn },
            set: { newValue in
                if !newValue {
                    model.needsTwoFactorCode = false
                    model.isPresentingSignIn = false
                }
            }
        )
    }
}

/// Persistent footer summarising the fleet. The app does nothing useful without a
/// device, so this stays visible on every page rather than living only on Devices.
struct DeviceSummaryBar: View {
    @Environment(AppModel.self) private var model
    private var devices: DeviceStore { model.devices }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 9) {
                Image(systemName: devices.devices.isEmpty ? "cable.connector.slash" : "iphone.gen3")
                    .font(.callout)
                    .foregroundStyle(devices.devices.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.green))
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text(headline)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    if !devices.devices.isEmpty {
                        Text("\(devices.selectedUDIDs.count) selected")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                }

                Spacer(minLength: 0)

                if !devices.devices.isEmpty {
                    Button(devices.isAllSelected ? "None" : "All") {
                        withAnimation(.snappy(duration: 0.2)) { devices.toggleSelectAll() }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .background(.bar)
    }

    private var headline: String {
        let count = devices.devices.count
        if count == 0 { return "No iPhone connected" }
        if count == 1, let only = devices.devices.first {
            return "\(only.name) · iOS \(only.iosVersion)"
        }
        return "\(count) iPhones connected"
    }
}
