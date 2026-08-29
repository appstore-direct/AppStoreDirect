import AppStoreDirectKit
import Observation
import SwiftUI

/// Tracks, per app, whether the signed-in Apple Account may install it.
///
/// Only **paid** apps are ever checked. A free app is installable regardless of
/// licence history — one is acquired automatically at install time — so probing one
/// would spend an Apple request to learn nothing. That keeps a 30-result search to
/// at most a handful of authenticated calls instead of thirty.
@MainActor
@Observable
final class OwnershipStore {
    private(set) var products: [Int64: StoreProduct] = [:]
    private(set) var checking: Set<Int64> = []

    private var service: (any PurchaseEntitlementService)?
    private var account: StoreAccount?
    /// Ownership probes are real requests to Apple; a few at a time is plenty.
    private let gate = InstallScheduler(limit: 3)

    func configure(service: any PurchaseEntitlementService, account: StoreAccount) {
        self.service = service
        self.account = account
        // Ownership is a property of the account, so a different sign-in invalidates
        // everything cached here.
        products.removeAll()
    }

    func reset() {
        service = nil
        account = nil
        products.removeAll()
        checking.removeAll()
    }

    /// Current state. Free apps answer immediately without a network call.
    func ownership(for app: StoreApp) -> AppOwnershipState {
        if app.price == 0 { return .free }
        return products[app.appStoreID]?.ownership ?? .unknown
    }

    func product(for app: StoreApp) -> StoreProduct? {
        products[app.appStoreID]
    }

    func isChecking(_ app: StoreApp) -> Bool {
        checking.contains(app.appStoreID)
    }

    /// Whether Install should be offered for this app.
    func isInstallable(_ app: StoreApp) -> Bool {
        ownership(for: app).isInstallable
    }

    /// Checks one paid app, unless it is already known or in flight.
    func check(_ app: StoreApp, force: Bool = false) {
        guard app.price > 0, let service, let account else { return }
        if !force, products[app.appStoreID] != nil { return }
        guard !checking.contains(app.appStoreID) else { return }

        checking.insert(app.appStoreID)
        Task { [weak self] in
            defer { Task { @MainActor [weak self] in self?.checking.remove(app.appStoreID) } }
            let product: StoreProduct
            do {
                product = try await self?.gate.withSlot(udid: "ownership") {
                    try await service.checkOwnership(of: app, account: account)
                } ?? StoreProduct(app: app)
            } catch {
                // A failed check stays `unknown`. Reporting "Not Purchased" because
                // the network hiccuped would tell someone they do not own an app
                // they paid for, which is the worse of the two wrong answers.
                product = StoreProduct(app: app, ownership: .unknown, detail: error.localizedDescription)
            }
            await MainActor.run { [weak self] in
                self?.products[app.appStoreID] = product
            }
        }
    }

    /// Checks every paid app in a set of results.
    func checkAll(_ apps: [StoreApp]) {
        for app in apps where app.price > 0 { check(app) }
    }
}
