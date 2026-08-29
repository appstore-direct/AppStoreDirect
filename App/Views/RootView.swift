import AppStoreDirectKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarSection = .apps

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.symbol)
                    .badge(badge(for: section))
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom) { DeviceStatusBar() }
        } detail: {
            switch selection {
            case .apps:      AppsView()
            case .installed: InstalledView()
            case .devices:   DevicesView()
            case .settings:  SettingsView()
            }
        }
        .sheet(isPresented: signInBinding) { SignInView() }
    }

    /// Device count on the Devices row; active installs on Apps.
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

/// Persistent footer summarising what is plugged in and how much is selected.
/// The app is useless without a device, so this stays visible on every page.
struct DeviceStatusBar: View {
    @Environment(AppModel.self) private var model

    private var devices: DeviceStore { model.devices }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()

            if devices.devices.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "cable.connector.slash").foregroundStyle(.secondary)
                    Text("No iPhone connected")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "iphone.gen3").foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(deviceHeadline)
                            .font(.callout)
                            .lineLimit(1)
                        Text("\(devices.selectedUDIDs.count) selected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Spacer()
                    Button(devices.isAllSelected ? "None" : "All") {
                        devices.toggleSelectAll()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private var deviceHeadline: String {
        let count = devices.devices.count
        if count == 1, let only = devices.devices.first {
            return "\(only.name) · iOS \(only.iosVersion)"
        }
        return "\(count) iPhones connected"
    }
}
