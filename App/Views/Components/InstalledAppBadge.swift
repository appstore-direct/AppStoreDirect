import AppStoreDirectKit
import SwiftUI

/// A tracked app's App Store icon, shown on a device card when that app is
/// actually present on the phone.
///
/// Falls back to the app's initial when artwork has not loaded, so a present app is
/// never rendered as absent just because an image is missing.
struct InstalledAppBadge: View {
    let app: TrackedApp
    var side: CGFloat = Metric.badgeIcon

    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let image = model.icons.icon(for: app) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: side * 0.24, style: .continuous)
                        .fill(.quaternary)
                    Text(app.name.prefix(1))
                        .font(.system(size: side * 0.55, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: side * 0.24, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .help("\(app.name) is installed on this device")
        .accessibilityLabel("\(app.name) installed")
    }
}

/// The row of tracked-app badges for one device, with its own empty and loading
/// states so a device is never ambiguous about what it is reporting.
struct InstalledAppBadgeRow: View {
    let udid: String
    @Environment(AppModel.self) private var model

    private var installed: [TrackedApp] {
        model.devices.trackedAppsInstalled(on: udid)
    }

    var body: some View {
        if !model.devices.hasReadInstalledApps(for: udid) {
            HStack(spacing: 5) {
                ProgressView().controlSize(.small).scaleEffect(0.5)
                    .frame(width: 10, height: 10)
                Text("Reading apps…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(height: Metric.badgeIcon)
        } else if installed.isEmpty {
            Text("No tracked apps")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(height: Metric.badgeIcon)
        } else {
            HStack(spacing: 5) {
                ForEach(installed) { app in
                    InstalledAppBadge(app: app)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(height: Metric.badgeIcon)
            .animation(.snappy(duration: 0.25), value: installed)
        }
    }
}
