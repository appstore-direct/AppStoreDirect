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
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.25), value: model.installs.overallSummary.total)
        .navigationTitle("Apps")
        // The system search field: rounded, correctly sized, and placed in the
        // toolbar by the platform rather than positioned by hand.
        .searchable(text: $model.searchTerm, placement: .toolbar, prompt: "Search the App Store")
        .onChange(of: model.searchTerm) { _, _ in model.search() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if !model.isSignedIn && !model.isRestoringSession {
                    Button {
                        model.isPresentingSignIn = true
                    } label: {
                        Label("Sign In", systemImage: "person.crop.circle")
                    }
                    .help("Sign in with your Apple Account")
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.searchError {
            EmptyStateView(
                symbol: "exclamationmark.triangle",
                title: "Search Failed",
                message: error
            )
        } else if model.searchTerm.isEmpty {
            AppsLandingView()
        } else if model.isSearching && model.results.isEmpty {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.results.isEmpty {
            EmptyStateView(
                symbol: "magnifyingglass",
                title: "No Results",
                message: "Nothing in the App Store matched “\(model.searchTerm)”."
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(model.results) { app in
                        AppRowView(app: app)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .scrollContentBackground(.hidden)
        }
    }
}

/// The Apps page before a search: states what the page is for, how many phones are
/// ready, and offers the two apps this fleet installs most often.
struct AppsLandingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        EmptyStateView(
            symbol: "square.grid.2x2",
            title: "Search the App Store",
            message: "Find and install apps directly to your connected iPhones."
        ) {
            VStack(spacing: 18) {
                readiness

                if model.isSignedIn, !model.devices.devices.isEmpty {
                    VStack(spacing: 8) {
                        Text("QUICK PICKS")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .kerning(0.6)

                        HStack(spacing: 10) {
                            ForEach(TrackedApp.all) { app in
                                QuickPickTile(app: app)
                            }
                        }
                    }
                }
            }
        }
    }

    /// One line saying whether the app can actually do anything right now, and if
    /// not, which of the two prerequisites is missing.
    @ViewBuilder
    private var readiness: some View {
        let deviceCount = model.devices.devices.count

        HStack(spacing: 8) {
            if !model.isSignedIn {
                Label("Sign in with your Apple Account to install apps", systemImage: "person.crop.circle.badge.exclamationmark")
                    .foregroundStyle(.secondary)
            } else if deviceCount == 0 {
                Label("Connect an iPhone by USB to get started", systemImage: "cable.connector.slash")
                    .foregroundStyle(.secondary)
            } else {
                Label(
                    "\(deviceCount) device\(deviceCount == 1 ? "" : "s") connected · \(model.devices.selectedUDIDs.count) selected",
                    systemImage: "iphone.gen3"
                )
                .foregroundStyle(.green)
            }
        }
        .font(.callout)
        .monospacedDigit()
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background {
            Capsule().fill(Color.primary.opacity(0.05))
        }
    }
}

/// A one-click search for an app this fleet installs often.
struct QuickPickTile: View {
    let app: TrackedApp
    @Environment(AppModel.self) private var model
    @State private var isHovering = false

    var body: some View {
        Button {
            model.searchTerm = app.name
            model.search()
        } label: {
            VStack(spacing: 7) {
                InstalledAppBadge(app: app, side: 40)
                Text(app.name)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
            }
            .frame(width: 108)
            .padding(.vertical, 12)
            .cardSurface(isHighlighted: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Search for \(app.name)")
    }
}

/// Footer with the overall counts and the bulk controls.
struct BulkActionBar: View {
    @Environment(AppModel.self) private var model
    private var summary: InstallSummary { model.installs.overallSummary }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                if summary.hasActivity {
                    ProgressView().controlSize(.small)
                }
                Text(summary.description.isEmpty ? "No installs" : summary.description)
                    .font(.callout)
                    .monospacedDigit()
                    .contentTransition(.numericText())

                Spacer()

                Button("Retry Failed") { model.retryAllFailed() }
                    .disabled(!summary.hasFailures)
                Button("Cancel All") { model.installs.cancelAll() }
                    .disabled(!summary.hasActivity)
                Button("Clear Finished") { model.installs.clearFinished() }
                    .disabled(summary.hasActivity && summary.total == summary.queued + summary.working)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .background(.bar)
    }
}
