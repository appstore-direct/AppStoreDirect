import AppStoreDirectKit
import SwiftUI

/// One device's line inside an install batch: status badge, device name, a
/// determinate bar while work is happening, and its own Cancel / Retry.
struct InstallProgressView: View {
    let app: StoreApp
    let job: PerDeviceInstallJob
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            StatusBadge(state: job.state)
                .frame(width: 92, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(job.deviceName)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Text("iOS \(job.iosVersion)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if let fraction = job.state.fraction, job.state.isActive {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(job.state.tint)
                        .frame(maxWidth: 240)
                        .transition(.opacity)
                }

                // The full sentence — "Downloading from Apple… 45% (12 MB of 34 MB)"
                // or an error straight from the device.
                Text(job.state.label)
                    .font(.caption2)
                    .foregroundStyle(job.state == .installed ? Color.green : .secondary)
                    .monospacedDigit()
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)
            action
        }
        .padding(.vertical, 3)
        .animation(.smooth(duration: 0.25), value: job.state)
    }

    @ViewBuilder
    private var action: some View {
        if job.state.isActive {
            Button("Cancel") { model.installs.cancel(app: app, udid: job.key.udid) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        } else if job.state.isRetryable, let device = model.devices.device(udid: job.key.udid) {
            Button("Retry") { model.retry(app, on: device) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}

/// The collapsible batch panel under a search result: a one-line summary plus the
/// per-device rows.
struct InstallBatchView: View {
    let app: StoreApp
    @Environment(AppModel.self) private var model
    @State private var isExpanded = true

    private var jobs: [PerDeviceInstallJob] { model.installs.jobs(for: app) }
    private var summary: InstallSummary { model.installs.summary(for: app) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .buttonStyle(.plain)

                Text(summary.description)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())

                Spacer()

                if !summary.hasActivity {
                    Button("Dismiss") { model.installs.dismiss(app: app) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }

            if isExpanded {
                VStack(spacing: 2) {
                    ForEach(jobs) { job in
                        InstallProgressView(app: app, job: job)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        }
        .animation(.smooth(duration: 0.25), value: summary)
    }
}
