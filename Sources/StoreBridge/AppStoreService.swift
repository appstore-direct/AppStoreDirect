import Foundation

/// A package acquired from Apple and made installable: metadata and sinf already
/// injected, sitting in the app's cache directory.
public struct AcquiredPackage: Sendable {
    /// The finished package in the app's cache directory. `iTunesMetadata.plist` and
    /// the sinf are already written into it.
    public let url: URL
    public let bundleID: String
    public let version: String
    public let byteCount: Int64

    /// The account's FairPlay licence for this app, passed to installation_proxy as
    /// `ApplicationSINF`. Returned separately so the Swift side never needs a zip
    /// reader, and so it can be zeroed after the install without rewriting the file.
    public let sinf: Data
    /// The `iTunesMetadata` client option, as a binary plist.
    public let iTunesMetadata: Data

    public init(
        url: URL,
        bundleID: String,
        version: String,
        byteCount: Int64,
        sinf: Data,
        iTunesMetadata: Data
    ) {
        self.url = url
        self.bundleID = bundleID
        self.version = version
        self.byteCount = byteCount
        self.sinf = sinf
        self.iTunesMetadata = iTunesMetadata
    }
}

/// One historical build of an app, identified by Apple's `externalVersionId`.
/// Needed because a current release often requires a newer iOS than the device runs.
public struct StoreAppVersion: Sendable, Hashable, Codable, Identifiable {
    public var id: String { externalVersionID }
    public let externalVersionID: String
    public let versionString: String

    public init(externalVersionID: String, versionString: String) {
        self.externalVersionID = externalVersionID
        self.versionString = versionString
    }
}

/// A fresh download authorization: the licence material Apple issues for one
/// install, without the package bytes.
///
/// Apple returns different licence material on every authorization, so this is
/// obtained per device rather than shared, while the package itself is downloaded
/// once. See `MultiInstallCoordinator`.
public struct DownloadAuthorization: Sendable {
    public let sinf: Data
    public let iTunesMetadata: Data
    public let version: String
    public let bundleID: String

    public init(sinf: Data, iTunesMetadata: Data, version: String, bundleID: String) {
        self.sinf = sinf
        self.iTunesMetadata = iTunesMetadata
        self.version = version
        self.bundleID = bundleID
    }
}

/// **The replaceable seam.**
///
/// Everything that speaks Apple's private App Store protocol lives behind this
/// protocol. When Apple changes authentication, request signing, endpoints or the
/// package format, only a conformer changes — no UI, no device code, no persistence.
///
/// Implementations must never log or return credentials, tokens, cookies or sinf
/// bytes, and must not write them anywhere except by handing them back to the caller.
public protocol AppStoreService: Sendable {
    /// Authenticates. Returns `.needsTwoFactorCode` when Apple wants a 2FA code;
    /// the caller then calls again with the same credentials plus `twoFactorCode`.
    func signIn(email: String, password: String, twoFactorCode: String?) async throws -> LoginOutcome

    /// Re-establishes an existing session without a password, so the user is not
    /// asked to sign in on every launch. Throws `.sessionExpired` when Apple
    /// has invalidated the token.
    func resume(account: StoreAccount) async throws -> StoreAccount

    /// Obtains a licence if the account does not already hold one, downloads the
    /// package, and injects `iTunesMetadata.plist` and the sinf so it is installable.
    ///
    /// `progress` is called on an arbitrary thread; callers hop to the main actor.
    func acquire(
        app: StoreApp,
        account: StoreAccount,
        externalVersionID: String?,
        into directory: URL,
        progress: @escaping @Sendable (InstallPhase) -> Void
    ) async throws -> AcquiredPackage

    /// Builds available for the app, newest first. Used to fall back to an older
    /// release when the current one requires a newer iOS than the device runs.
    func availableVersions(app: StoreApp, account: StoreAccount) async throws -> [StoreAppVersion]

    /// Requests licence material for one install without transferring the package.
    /// Used to give each device in a multi-device batch its own authorization.
    func authorizeDownload(
        app: StoreApp,
        account: StoreAccount,
        externalVersionID: String?
    ) async throws -> DownloadAuthorization

    /// Drops any process-level state. Called on sign-out.
    func signOut() async
}
