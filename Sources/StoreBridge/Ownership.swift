import Foundation

/// Whether the signed-in Apple Account may install a given app.
///
/// Ownership is a property of the *account*, not of any device: Apple's licence
/// check carries the account's directory-services ID and no device identifier at all.
public enum AppOwnershipState: Sendable, Hashable, Codable {
    /// Free app. Installable; a licence is acquired automatically at install time
    /// if the account does not already hold one.
    case free
    /// Paid app the account has already bought. Installable at no further cost.
    case purchased
    /// Paid app the account does not own. **Not** installable here — buying it is a
    /// financial transaction this application never initiates.
    case notPurchased
    /// Not yet checked, or the check failed. Never presented as "not owned":
    /// telling someone they do not own an app they paid for is the worse error.
    case unknown

    public var isInstallable: Bool {
        switch self {
        case .free, .purchased: return true
        case .notPurchased, .unknown: return false
        }
    }

    /// Badge text shown beside the app name. Free apps get no badge.
    public var badge: String? {
        switch self {
        case .free:         return nil
        case .purchased:    return "Purchased"
        case .notPurchased: return "Not Purchased"
        case .unknown:      return nil
        }
    }
}

/// A catalogue listing paired with what this account may do with it.
///
/// `StoreApp` describes the app as Apple's public catalogue reports it; the
/// ownership half comes from an authenticated licence check, so the two are kept
/// separate rather than merged into one type that is only half populated.
public struct StoreProduct: Identifiable, Sendable, Hashable {
    public var id: Int64 { app.appStoreID }

    public let app: StoreApp
    public var ownership: AppOwnershipState
    /// Apple returned a usable download authorization during the ownership check.
    public var downloadAuthorized: Bool
    /// How many builds Apple still serves, when known.
    public var availableVersions: Int
    /// Populated only when the check itself failed, for diagnostics.
    public var detail: String?

    public init(
        app: StoreApp,
        ownership: AppOwnershipState = .unknown,
        downloadAuthorized: Bool = false,
        availableVersions: Int = 0,
        detail: String? = nil
    ) {
        self.app = app
        self.ownership = ownership
        self.downloadAuthorized = downloadAuthorized
        self.availableVersions = availableVersions
        self.detail = detail
    }

    public var adamID: Int64 { app.appStoreID }
    public var bundleID: String { app.bundleID }
    public var name: String { app.name }
    public var price: Double { app.price }
    public var minimumOSVersion: String { app.minimumOSVersion }
    public var isPaid: Bool { app.price > 0 }
}

/// Ownership and download-authorization checks against the signed-in account.
///
/// Split out from `AppStoreService` because these are entitlement questions rather
/// than transfer operations, and because nothing here may ever spend money:
/// `acquireFreeLicence` is explicitly limited to apps with a price of zero.
public protocol PurchaseEntitlementService: Sendable {
    /// Asks Apple whether this account can download `app`, without transferring the
    /// package. Never initiates a purchase.
    func checkOwnership(of app: StoreApp, account: StoreAccount) async throws -> StoreProduct

    /// Obtains a licence for a **free** app. Throws `StoreError.paidAppsUnsupported`
    /// if called with a priced app, so a paid purchase cannot happen by accident.
    func acquireFreeLicence(for app: StoreApp, account: StoreAccount) async throws
}
