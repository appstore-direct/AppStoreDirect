import AppStoreDirectKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var isConfirmingSignOut = false

    var body: some View {
        Form {
            Section {
                if let account = model.account {
                    LabeledContent("Signed in as", value: account.email)
                    if !account.name.isEmpty {
                        LabeledContent("Name", value: account.name)
                    }
                    LabeledContent("Storefront", value: account.countryCode ?? account.storefront)
                    Button("Sign Out", role: .destructive) { isConfirmingSignOut = true }
                } else {
                    LabeledContent("Status", value: "Not signed in")
                    Button("Sign In…") { model.isPresentingSignIn = true }
                }
            } header: {
                Text("Apple Account")
            } footer: {
                Text("""
                Your password is never stored. Only the session Apple issues at sign-in is \
                kept, in the macOS Keychain, so you stay signed in between launches.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Picker("Maximum concurrent installs", selection: Binding(
                    get: { model.installs.concurrencyLimit },
                    set: { model.installs.concurrencyLimit = $0 }
                )) {
                    ForEach(InstallScheduler.allowedLimits, id: \.self) { limit in
                        Text(limit == 1 ? "1 (one at a time)" : "\(limit)").tag(limit)
                    }
                }
            } header: {
                Text("Installing")
            } footer: {
                Text("""
                How many devices are installed to at the same time. Each install holds a \
                USB session open, so a high number can make usbmuxd the bottleneck. \
                Work on any single device is always serialised, whatever this is set to.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("App packages", value: "Downloaded once per app, then installed to every selected device")
                Button("Clear Cached Packages") {
                    Task.detached { InstallCoordinator.sweepCache() }
                }
            } header: {
                Text("Storage")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .confirmationDialog(
            "Sign out of your Apple Account?",
            isPresented: $isConfirmingSignOut,
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) {
                Task { await model.signOut() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You will need to sign in again, including a verification code, to install apps.")
        }
    }
}
