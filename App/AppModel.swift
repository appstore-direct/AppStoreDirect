import AppStoreDirectKit
import Observation
import SwiftUI

/// Sections in the sidebar. Named `SidebarSection` so it does not shadow
/// SwiftUI's `Section` inside this module.
enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case apps = "Apps"
    case installed = "Installed"
    case devices = "Devices"
    case settings = "Settings"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .apps:      return "magnifyingglass"
        case .installed: return "square.grid.2x2"
        case .devices:   return "iphone.gen3"
        case .settings:  return "gearshape"
        }
    }
}

/// Session, catalogue search, and the wiring between the device store and the
/// install centre.
///
/// Device state lives in `DeviceStore` and install state in `InstallCenter`; this
/// type owns neither. It exists to hold the Apple Account session and the search
/// results, and to hand the signed-in store to the install centre.
@MainActor
@Observable
final class AppModel {
    let devices = DeviceStore()
    let installs = InstallCenter()
    let ownership = OwnershipStore()

    // Session
    var account: StoreAccount?
    var isSigningIn = false
    var signInError: String?
    /// Set when Apple asks for a verification code; drives the 2FA sheet.
    var needsTwoFactorCode = false
    /// Set when the user opens sign-in themselves, rather than being prompted.
    var isPresentingSignIn = false
    var isRestoringSession = true

    // Catalogue
    var searchTerm = ""
    var results: [StoreApp] = []
    var isSearching = false
    var searchError: String?

    private let catalog = ITunesCatalog()
    private let keychain = KeychainStore()
    private var store: BridgeAppStoreService?
    private var searchTask: Task<Void, Never>?

    var isSignedIn: Bool { account != nil }

    /// Country used for catalogue search. Falls back to the Mac's region before
    /// sign-in, then to the storefront Apple returns for the account.
    var countryCode: String {
        account?.countryCode ?? Locale.current.region?.identifier ?? "US"
    }

    /// Whether Install can do anything right now.
    var canInstall: Bool { isSignedIn && devices.hasSelection }

    // MARK: - Lifecycle

    func start() async {
        // Device discovery and session restore are independent, and must not be
        // sequenced. Restoring the session can block indefinitely on a Keychain
        // authorisation prompt; gating discovery behind it would leave a plugged-in
        // iPhone showing as disconnected until the user answered that dialog.
        async let session: Void = restoreSession()
        async let discovery: Void = devices.start()
        _ = await (session, discovery)

        await devices.refreshInstalledAppsForSelection()
    }

    /// Signs back in from the Keychain so the user is not asked for a password
    /// on every launch.
    private func restoreSession() async {
        defer { isRestoringSession = false }
        guard let stored = try? await keychain.load() else { return }

        do {
            let service = try BridgeAppStoreService.locate(cookies: stored.cookies)
            store = service
            // Trust the stored session optimistically. Apple offers no cheap
            // token-validity check, so an expired token surfaces on first install
            // and the user is prompted then. The background call below is a
            // protocol preflight, not a credential check.
            account = stored.account
            installs.configure(store: service)
            ownership.configure(service: service, account: stored.account)

            Task.detached { [weak self] in
                guard let self else { return }
                if let refreshed = try? await service.resume(account: stored.account) {
                    await self.applyRefreshedAccount(refreshed, cookies: stored.cookies)
                }
            }
        } catch {
            signInError = error.localizedDescription
        }
    }

    private func applyRefreshedAccount(_ refreshed: StoreAccount, cookies: String) async {
        account = refreshed
        if let store { ownership.configure(service: store, account: refreshed) }
        try? await keychain.save(StoredSession(account: refreshed, cookies: cookies))
    }

    // MARK: - Search

    func search() {
        searchTask?.cancel()
        let term = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            results = []
            searchError = nil
            return
        }

        searchTask = Task { [catalog, countryCode] in
            // Debounce so a fast typist does not fire a request per keystroke.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }

            await MainActor.run { self.isSearching = true; self.searchError = nil }
            do {
                let found = try await catalog.search(term: term, countryCode: countryCode, limit: 30)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.results = found
                    self.isSearching = false
                    // Only the paid results cost a request; free ones resolve locally.
                    self.ownership.checkAll(found)
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.searchError = error.localizedDescription
                    self.isSearching = false
                }
            }
        }
    }

    // MARK: - Authentication

    func signIn(email: String, password: String, code: String?) async {
        isSigningIn = true
        signInError = nil
        defer { isSigningIn = false }

        do {
            let service = try store ?? BridgeAppStoreService.locate()
            store = service

            switch try await service.signIn(email: email, password: password, twoFactorCode: code) {
            case .needsTwoFactorCode:
                needsTwoFactorCode = true
            case .authenticated(let signedIn):
                account = signedIn
                needsTwoFactorCode = false
                isPresentingSignIn = false
                installs.configure(store: service)
                ownership.configure(service: service, account: signedIn)
                let cookies = await service.sessionCookies
                try await keychain.save(StoredSession(account: signedIn, cookies: cookies))
            }
        } catch {
            signInError = error.localizedDescription
        }
    }

    func signOut() async {
        ownership.reset()
        await installs.teardown()
        await store?.signOut()
        store = nil
        account = nil
        needsTwoFactorCode = false
        try? await keychain.clear()
    }

    // MARK: - Install

    /// Installs onto every selected device. Devices that cannot run the app are
    /// still passed through, so the coordinator can mark them unsupported rather
    /// than the user wondering why a ticked phone was skipped.
    func install(_ app: StoreApp) {
        guard let account else {
            isPresentingSignIn = true
            return
        }
        // A paid app the account does not own must never reach the download path.
        guard ownership.isInstallable(app) else { return }

        let targets = devices.selectedDevices
        guard !targets.isEmpty else { return }
        installs.install(app: app, devices: targets, account: account)
    }

    func install(_ app: StoreApp, on device: ConnectedDevice) {
        guard let account else {
            isPresentingSignIn = true
            return
        }
        installs.install(app: app, devices: [device], account: account)
    }

    func retry(_ app: StoreApp, on device: ConnectedDevice) {
        guard let account else { return }
        installs.retry(app: app, device: device, account: account)
    }

    func retryAllFailed() {
        guard let account else { return }
        installs.retryFailed(account: account, devices: devices.devices)
    }

    /// Refreshes the installed list for devices that just finished an install.
    func refreshAfterInstall(_ app: StoreApp) async {
        for job in installs.jobs(for: app) where job.state == .installed {
            await devices.refreshInstalledApps(for: job.key.udid)
        }
    }
}
