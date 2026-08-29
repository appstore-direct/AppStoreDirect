import AppStoreDirectKit
import SwiftUI

/// One App Store search result.
///
/// Layout is deliberately flat rather than nested cards: at thirty results, a card
/// per row reads as clutter. Separation comes from generous spacing and a hairline,
/// with the card surface reserved for hover.
struct AppRowView: View {
    let app: StoreApp
    @Environment(AppModel.self) private var model
    @State private var isHovering = false

    private var ownership: AppOwnershipState { model.ownership.ownership(for: app) }
    private var targets: [ConnectedDevice] { model.devices.selectedDevices }
    private var compatible: [ConnectedDevice] { model.devices.compatibleSelection(for: app) }
    private var jobs: [PerDeviceInstallJob] { model.installs.jobs(for: app) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: Metric.rowSpacing) {
                AppArtwork(url: app.iconURL, side: Metric.appIcon)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(app.name)
                            .font(.headline)
                            .lineLimit(1)
                        if let badge = StatusBadge(ownership: ownership) {
                            badge
                        }
                    }

                    Text(app.developer)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    metadata

                    if jobs.isEmpty, let note = compatibilityNote {
                        Label(note, systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(.top, 1)
                    }
                }

                Spacer(minLength: 8)
                InstallControl(app: app)
            }

            if !jobs.isEmpty {
                InstallBatchView(app: app)
                    .padding(.leading, Metric.appIcon + Metric.rowSpacing)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .cardSurface(isHighlighted: isHovering)
        .onHover { isHovering = $0 }
        .animation(.smooth(duration: 0.25), value: jobs.count)
    }

    /// Bundle ID, App Store ID and minimum iOS — the identifying facts, kept on one
    /// quiet line so they are available without competing with the app name.
    private var metadata: some View {
        HStack(spacing: 5) {
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
        .truncationMode(.middle)
    }

    /// Explains a partly or wholly incompatible selection before anything is clicked.
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
}

/// The right-hand control: Install, a price with "Not Purchased", or a check.
private struct InstallControl: View {
    let app: StoreApp
    @Environment(AppModel.self) private var model

    private var ownership: AppOwnershipState { model.ownership.ownership(for: app) }
    private var targets: [ConnectedDevice] { model.devices.selectedDevices }
    private var compatible: [ConnectedDevice] { model.devices.compatibleSelection(for: app) }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            switch ownership {
            case .free, .purchased:
                Button(action: { model.install(app) }) {
                    Text(title).frame(minWidth: 58)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(!isEnabled)
                .help(disabledReason ?? "Install \(app.name) on \(compatible.count) device\(compatible.count == 1 ? "" : "s")")

            case .notPurchased:
                // Not a buy button. Acquiring a paid licence is a financial
                // transaction this application never initiates.
                VStack(alignment: .trailing, spacing: 1) {
                    Text(priceText).font(.callout.weight(.medium))
                    Text("Not Purchased")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                .help("Buy \(app.name) in the App Store on any device signed into this Apple Account, then install it here.")

            case .unknown:
                if model.ownership.isChecking(app) {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small)
                        Text("Checking…").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    VStack(alignment: .trailing, spacing: 1) {
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
                    .contentTransition(.numericText())
            }
        }
        .animation(.smooth(duration: 0.2), value: ownership)
    }

    /// Always states how many phones the click will touch.
    private var title: String {
        compatible.count > 1 ? "Install on \(compatible.count)" : "Install"
    }

    private var isEnabled: Bool {
        ownership.isInstallable && model.isSignedIn && !compatible.isEmpty
    }

    private var disabledReason: String? {
        if !model.isSignedIn { return "Sign in with your Apple Account first." }
        if model.devices.devices.isEmpty { return "Connect an iPhone by USB." }
        if targets.isEmpty { return "Select at least one device in Devices." }
        if compatible.isEmpty { return "No selected device can run this app." }
        return nil
    }

    private var priceText: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = app.currency.isEmpty ? "USD" : app.currency
        return formatter.string(from: NSNumber(value: app.price)) ?? String(format: "%.2f", app.price)
    }
}

/// App Store artwork with a placeholder that holds its shape while loading.
struct AppArtwork: View {
    let url: URL?
    var side: CGFloat = Metric.appIcon

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFit().transition(.opacity)
            default:
                RoundedRectangle(cornerRadius: Metric.iconRadius, style: .continuous)
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "app.dashed")
                            .font(.system(size: side * 0.32, weight: .light))
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: Metric.iconRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Metric.iconRadius, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
    }
}
