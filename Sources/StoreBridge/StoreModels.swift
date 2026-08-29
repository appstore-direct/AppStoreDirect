import Foundation

/// One App Store listing, as shown in search results.
public struct StoreApp: Identifiable, Sendable, Hashable, Codable {
    public var id: Int64 { appStoreID }

    /// Apple's "adam ID" / trackId — the identifier every private endpoint uses.
    public let appStoreID: Int64
    public let bundleID: String
    public let name: String
    public let developer: String
    public let version: String
    public let minimumOSVersion: String
    public let iconURL: URL?
    public let price: Double
    public let currency: String
    public let fileSizeBytes: Int64?
    public let averageRating: Double?
    public let ratingCount: Int?

    public var isFree: Bool { price == 0 }

    public init(
        appStoreID: Int64,
        bundleID: String,
        name: String,
        developer: String,
        version: String,
        minimumOSVersion: String,
        iconURL: URL?,
        price: Double,
        currency: String,
        fileSizeBytes: Int64?,
        averageRating: Double?,
        ratingCount: Int?
    ) {
        self.appStoreID = appStoreID
        self.bundleID = bundleID
        self.name = name
        self.developer = developer
        self.version = version
        self.minimumOSVersion = minimumOSVersion
        self.iconURL = iconURL
        self.price = price
        self.currency = currency
        self.fileSizeBytes = fileSizeBytes
        self.averageRating = averageRating
        self.ratingCount = ratingCount
    }
}

/// The persisted half of a signed-in session. Deliberately excludes the password:
/// after login, Apple's `passwordToken` is what authorises purchase and download.
public struct StoreAccount: Sendable, Hashable, Codable {
    public let email: String
    public let name: String
    /// Apple's `dsPersonId`.
    public let directoryServicesID: String
    /// Apple's `X-Set-Apple-Store-Front`, e.g. `143441-1,29`.
    public let storefront: String
    public let passwordToken: String
    /// Optional `pod` header; selects the `p<N>-buy.itunes.apple.com` shard.
    public let pod: String

    public init(
        email: String,
        name: String,
        directoryServicesID: String,
        storefront: String,
        passwordToken: String,
        pod: String
    ) {
        self.email = email
        self.name = name
        self.directoryServicesID = directoryServicesID
        self.storefront = storefront
        self.passwordToken = passwordToken
        self.pod = pod
    }

    /// ISO country code implied by the storefront, used to scope catalogue search.
    public var countryCode: String? {
        guard let front = storefront.split(separator: "-").first,
              let identifier = Int(front) else { return nil }
        return StorefrontTable.countryCode(for: identifier)
    }
}

/// Outcome of an authentication attempt. Two-factor is a normal branch, not a failure.
public enum LoginOutcome: Sendable {
    case authenticated(StoreAccount)
    case needsTwoFactorCode
}

/// Progress of a single Install button press, mirroring the states the UI shows.
public enum InstallPhase: Sendable, Hashable {
    case preparing
    case authorizing
    case downloading(fraction: Double, bytesReceived: Int64, bytesExpected: Int64)
    case packaging
    case transferring(fraction: Double)
    case installing(fraction: Double)
    case installed
}

public enum StoreError: Error, LocalizedError, Sendable {
    case notSignedIn
    case sessionExpired
    case twoFactorRequired
    case paidAppsUnsupported(name: String)
    /// A paid app this Apple Account has not bought. Recoverable only by buying it
    /// in the App Store — never by this application.
    case notPurchased(name: String)
    case licenceUnavailable(reason: String)
    case incompatible(app: String, requires: String, deviceHas: String)
    case bridgeUnavailable(String)
    case bridgeFailure(code: String, message: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in with your Apple Account first."
        case .sessionExpired:
            return "Your App Store session expired. Sign in again."
        case .twoFactorRequired:
            return "A two-factor authentication code is required."
        case .paidAppsUnsupported(let name):
            return "\(name) is a paid app. Only apps that are free, or already in your purchase history, can be installed."
        case .notPurchased(let name):
            return "\(name) is not in this Apple Account's purchase history. Buy it in the App Store first, then install it here."
        case .licenceUnavailable(let reason):
            return "Your Apple Account could not obtain this app: \(reason)"
        case .incompatible(let app, let requires, let deviceHas):
            return "\(app) needs iOS \(requires); this device runs iOS \(deviceHas)."
        case .bridgeUnavailable(let detail):
            return "The App Store service is unavailable: \(detail)"
        case .bridgeFailure(_, let message):
            return message
        case .cancelled:
            return "Cancelled."
        }
    }
}
