import AppStoreDirectKit
import SwiftUI

struct AppsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            content
            if model.installs.overallSummary.total > 0 {
                BulkActionBar()
            }
        }
        .navigationTitle("Apps")
        .searchable(text: $model.searchTerm, placement: .toolbar, prompt: "Search the App Store")
        .onChange(of: model.searchTerm) { _, _ in model.search() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if !model.isSignedIn && !model.isRestoringSession {
                    Button("Sign In") { model.isPresentingSignIn = true }
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.searchError {
            ContentUnavailableView("Search failed", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if model.searchTerm.isEmpty {
            ContentUnavailableView(
                "Search the App Store",
                systemImage: "magnifyingglass",
                description: Text(emptyPrompt)
            )
        } else if model.isSearching && model.results.isEmpty {
            ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.results.isEmpty {
            ContentUnavailableView.search(text: model.searchTerm)
        } else {
            List(model.results) { app in
                AppRow(app: app)
                    .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
            }
            .listStyle(.inset)
        }
    }

    private var emptyPrompt: String {
        if !model.isSignedIn { return "Sign in with your Apple Account to install apps." }
        if model.devices.devices.isEmpty { return "Connect an iPhone by USB, then search for an app." }
        if !model.devices.hasSelection { return "Select one or more devices, then search for an app." }
        return "Find an app, then press Install to put it on your selected iPhones."
    }
}

/// One search result, with the per-device fan-out beneath it when a batch is running.
struct AppRow: View {
    let app: StoreApp
    @Environment(AppModel.self) private var model
    @State private var isExpanded = true

    private var jobs: [PerDeviceInstallJob] { model.installs.jobs(for: app) }
    private var summary: InstallSummary { model.installs.summary(for: app) }
    private var targets: [ConnectedDevice] { model.devices.selectedDevices }
    private var compatible: [ConnectedDevice] { model.devices.compatibleSelection(for: app) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if !jobs.isEmpty {
                batchSection
            }
        }
        .padding(.vertical, 2)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            AppIcon(url: app.iconURL)

            VStack(alignment: .leading, spacing: 3) {
                Text(app.name).font(.headline).lineLimit(1)
                HStack(spacing: 6) {
                    Text(app.developer)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    OwnershipBadge(app: app)
                }

                HStack(spacing: 6) {
                    Text(app.bundleID)
                    Text("·")
                    Text(verbatim: "\(app.appStoreID)")
                    if !app.minimumOSVersion.isEmpty {
                        Text("·")
                        Text("iOS \(app.minimumOSVersion)+")
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)

                if jobs.isEmpty, let note = compatibilityNote {
                    Label(note, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: 8)
            installButton
        }
    }

    // MARK: - Install control

    @ViewBuilder
    private var installButton: some View {
        VStack(alignment: .trailing, spacing: 4) {
            switch ownership {
            case .free, .purchased:
                Button(action: { model.install(app) }) { Text(buttonTitle) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!isInstallEnabled)
                    .help(disabledReason ?? "Install \(app.name) on \(compatible.count) device\(compatible.count == 1 ? "" : "s")")

            case .notPurchased:
                // Deliberately not a buy button. Acquiring a paid licence is a
                // financial transaction this application never initiates.
                VStack(alignment: .trailing, spacing: 2) {
                    Text(priceText).font(.callout.weight(.medium))
                    Text("Not Purchased")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                .help("Buy \(app.name) in the App Store on any device signed into this Apple Account, then install it here.")

            case .unknown:
                if model.ownership.isChecking(app) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Checking…").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(priceText).font(.callout.weight(.medium))
                        Button("Check") { model.ownership.check(app, force: true) }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                    .help(model.ownership.product(for: app)?.detail
                          ?? "Could not confirm whether this Apple Account owns this app.")
                }
            }

            if ownership.isInstallable, !targets.isEmpty {
                Text("\(compatible.count) of \(targets.count) selected")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
    }

    private var ownership: AppOwnershipState { model.ownership.ownership(for: app) }

    private var priceText: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = app.currency.isEmpty ? "USD" : app.currency
        return formatter.string(from: NSNumber(value: app.price)) ?? String(format: "%.2f", app.price)
    }

    /// Reads "Install", "Install on 5 Devices" — so the button always says exactly
    /// how many phones the click will touch.
    private var buttonTitle: String {
        let count = compatible.count
        return count > 1 ? "Install on \(count) Devices" : "Install"
    }

    private var isInstallEnabled: Bool {
        ownership.isInstallable && model.isSignedIn && !compatible.isEmpty
    }

    private var disabledReason: String? {
        if !model.isSignedIn { return "Sign in with your Apple Account first." }
        if model.devices.devices.isEmpty { return "Connect an iPhone by USB." }
        if targets.isEmpty { return "Select at least one device in Devices." }
        if compatible.isEmpty { return "No selected device can run this app." }
        return nil
    }

    /// Explains a partially or wholly incompatible selection before any click.
    private var compatibilityNote: String? {
        let blocked = model.devices.incompatibleSelection(for: app)
        guard !blocked.isEmpty, !app.minimumOSVersion.isEmpty else { return nil }
        if blocked.count == targets.count {
            return targets.count == 1
                ? "Needs iOS \(app.minimumOSVersion) — \(blocked[0].name) runs iOS \(blocked[0].iosVersion)"
                : "Needs iOS \(app.minimumOSVersion) — no selected device can run it"
        }
        return "\(blocked.count) selected device\(blocked.count == 1 ? "" : "s") cannot run this (needs iOS \(app.minimumOSVersion))"
    }

    // MARK: - Per-device progress

    private var batchSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Text(summary.description)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Spacer()

                if !summary.hasActivity {
                    Button("Dismiss") { model.installs.dismiss(app: app) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }

            if isExpanded {
                VStack(spacing: 4) {
                    ForEach(jobs) { job in
                        DeviceJobRow(app: app, job: job)
                    }
                }
            }
        }
        .padding(.leading, 68)
        .padding(.trailing, 4)
    }
}

/// One device's line inside a batch, with its own Cancel and Retry.
struct DeviceJobRow: View {
    let app: StoreApp
    let job: PerDeviceInstallJob
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            statusIcon
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(job.deviceName)
                        .font(.caption.weight(.medium))
                    Text("iOS \(job.iosVersion)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if let fraction = job.state.fraction, job.state.isActive {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 260)
                }

                Text(job.state.label)
                    .font(.caption2)
                    .foregroundStyle(labelColor)
                    .monospacedDigit()
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)
            action
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch job.state {
        case .installed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        case .incompatible:
            Image(systemName: "minus.circle.fill").foregroundStyle(.orange)
        case .cancelled:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        case .queued:
            Image(systemName: "clock").foregroundStyle(.secondary)
        default:
            ProgressView().controlSize(.small).scaleEffect(0.6)
        }
        }

    private var labelColor: Color {
        switch job.state {
        case .installed:    return .green
        case .failed:       return .red
        case .incompatible: return .orange
        default:            return .secondary
        }
    }

    @ViewBuilder
    private var action: some View {
        if job.state.isActive {
            Button("Cancel") { model.installs.cancel(app: app, udid: job.key.udid) }
                .buttonStyle(.bordered)
                .controlSize(.mini)
        } else if job.state.isRetryable, let device = model.devices.device(udid: job.key.udid) {
            Button("Retry") { model.retry(app, on: device) }
                .buttonStyle(.bordered)
                .controlSize(.mini)
        }
    }
}

/// Footer with the overall counts and the bulk controls.
struct BulkActionBar: View {
    @Environment(AppModel.self) private var model

    private var summary: InstallSummary { model.installs.overallSummary }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                if summary.hasActivity {
                    ProgressView().controlSize(.small)
                }
                Text(summary.description.isEmpty ? "No installs" : summary.description)
                    .font(.callout)
                    .monospacedDigit()

                Spacer()

                Button("Retry Failed") { model.retryAllFailed() }
                    .disabled(!summary.hasFailures)

                Button("Cancel All") { model.installs.cancelAll() }
                    .disabled(!summary.hasActivity)

                Button("Clear Finished") { model.installs.clearFinished() }
                    .disabled(summary.hasActivity && summary.total == summary.queued + summary.working)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
}

struct AppIcon: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFit()
            default:
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
    }
}


/// "Purchased ✓" / "Not Purchased" beside a paid app's developer name.
/// Free apps show nothing — a badge there would be noise on most rows.
struct OwnershipBadge: View {
    let app: StoreApp
    @Environment(AppModel.self) private var model

    var body: some View {
        let state = model.ownership.ownership(for: app)
        if let text = state.badge {
            HStack(spacing: 3) {
                if state == .purchased {
                    Image(systemName: "checkmark.seal.fill").font(.caption2)
                }
                Text(text).font(.caption2.weight(.medium))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(state == .purchased ? Color.green.opacity(0.16) : Color.orange.opacity(0.16))
            .foregroundStyle(state == .purchased ? Color.green : Color.orange)
            .clipShape(Capsule())
        }
    }
}
