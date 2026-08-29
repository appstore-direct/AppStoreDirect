import Foundation

/// `AppStoreService` implemented over the `appstore-bridge` sidecar.
///
/// This is the only type in the app that knows Apple's private protocol exists.
/// Replacing it — because Apple changed authentication, or because a native Swift
/// SAP implementation becomes practical — means writing one new conformer and
/// changing one line where the service is constructed.
public actor BridgeAppStoreService: AppStoreService {
    private let client: BridgeClient
    /// The cookie jar for the current session, opaque to us. Held here so the
    /// caller only ever persists it alongside the account.
    private var cookies: String

    public init(executableURL: URL, cookies: String = "") {
        self.client = BridgeClient(executableURL: executableURL)
        self.cookies = cookies
    }

    /// Fails fast with a clear message when the helper is missing from the bundle.
    public static func locate(cookies: String = "") throws -> BridgeAppStoreService {
        guard let url = BridgeClient.locateExecutable() else {
            throw StoreError.bridgeUnavailable("the App Store helper is missing from the app bundle")
        }
        return BridgeAppStoreService(executableURL: url, cookies: cookies)
    }

    /// The current session blob, for the caller to store in the Keychain.
    public var sessionCookies: String { cookies }

    public func signIn(email: String, password: String, twoFactorCode: String?) async throws -> LoginOutcome {
        do {
            let result: LoginPayload = try await client.call(
                method: "login",
                params: LoginRequest(email: email, password: password, twoFactorCode: twoFactorCode ?? "")
            )
            cookies = result.cookies
            return .authenticated(result.account.storeAccount)
        } catch StoreError.twoFactorRequired {
            return .needsTwoFactorCode
        }
    }

    public func resume(account: StoreAccount) async throws -> StoreAccount {
        let result: AccountPayload = try await client.call(
            method: "resume",
            params: ResumeRequest(account: .init(account), cookies: cookies)
        )
        return result.storeAccount
    }

    public func acquire(
        app: StoreApp,
        account: StoreAccount,
        externalVersionID: String?,
        into directory: URL,
        progress: @escaping @Sendable (InstallPhase) -> Void
    ) async throws -> AcquiredPackage {
        let request = AcquireRequest(
            account: .init(account),
            cookies: cookies,
            appStoreID: app.appStoreID,
            bundleID: app.bundleID,
            name: app.name,
            price: app.price,
            externalVersionID: externalVersionID ?? "",
            destination: directory.path
        )

        let decoder = JSONDecoder()
        let result: AcquirePayload = try await client.call(
            method: "acquire",
            params: request,
            onEvent: { name, data in
                guard name == "progress",
                      let update = try? decoder.decode(ProgressPayload.self, from: data)
                else { return }
                progress(update.phase)
            }
        )

        guard let sinf = Data(base64Encoded: result.sinf),
              let metadata = Data(base64Encoded: result.metadata)
        else {
            throw StoreError.bridgeUnavailable("the helper returned an unreadable package")
        }

        return AcquiredPackage(
            url: URL(fileURLWithPath: result.path),
            bundleID: result.bundleID,
            version: result.version,
            byteCount: result.byteCount,
            sinf: sinf,
            iTunesMetadata: metadata
        )
    }

    public func authorizeDownload(
        app: StoreApp,
        account: StoreAccount,
        externalVersionID: String?
    ) async throws -> DownloadAuthorization {
        let result: AuthorizePayload = try await client.call(
            method: "authorize",
            params: AuthorizeRequest(
                account: .init(account),
                cookies: cookies,
                appStoreID: app.appStoreID,
                bundleID: app.bundleID,
                externalVersionID: externalVersionID ?? ""
            )
        )
        guard let sinf = Data(base64Encoded: result.sinf),
              let metadata = Data(base64Encoded: result.metadata)
        else {
            throw StoreError.bridgeUnavailable("the helper returned unreadable licence material")
        }
        return DownloadAuthorization(
            sinf: sinf,
            iTunesMetadata: metadata,
            version: result.version,
            bundleID: result.bundleID.isEmpty ? app.bundleID : result.bundleID
        )
    }

    public func availableVersions(app: StoreApp, account: StoreAccount) async throws -> [StoreAppVersion] {
        let result: VersionsPayload = try await client.call(
            method: "versions",
            params: VersionsRequest(
                account: .init(account),
                cookies: cookies,
                appStoreID: app.appStoreID,
                bundleID: app.bundleID
            )
        )
        return result.versions.map {
            StoreAppVersion(
                externalVersionID: $0.externalVersionID,
                versionString: $0.versionString.isEmpty ? $0.externalVersionID : $0.versionString
            )
        }
    }

    public func signOut() async {
        cookies = ""
    }
}

// MARK: - Wire types
//
// Kept private and separate from the domain models so a protocol change on Apple's
// side cannot ripple into the UI's types.

fileprivate struct AccountPayload: Codable, Sendable {
    let email: String
    let name: String
    let directoryServicesID: String
    let storefront: String
    let passwordToken: String
    let pod: String

    init(_ account: StoreAccount) {
        email = account.email
        name = account.name
        directoryServicesID = account.directoryServicesID
        storefront = account.storefront
        passwordToken = account.passwordToken
        pod = account.pod
    }

    var storeAccount: StoreAccount {
        StoreAccount(
            email: email,
            name: name,
            directoryServicesID: directoryServicesID,
            storefront: storefront,
            passwordToken: passwordToken,
            pod: pod
        )
    }
}

private struct LoginRequest: Encodable, Sendable {
    let email: String
    let password: String
    let twoFactorCode: String
}

private struct LoginPayload: Decodable, Sendable {
    let account: AccountPayload
    let cookies: String
}

private struct ResumeRequest: Encodable, Sendable {
    let account: AccountPayload
    let cookies: String
}

private struct AcquireRequest: Encodable, Sendable {
    let account: AccountPayload
    let cookies: String
    let appStoreID: Int64
    let bundleID: String
    let name: String
    let price: Double
    let externalVersionID: String
    let destination: String
}

private struct AcquirePayload: Decodable, Sendable {
    let path: String
    let bundleID: String
    let version: String
    let byteCount: Int64
    let sinf: String
    let metadata: String
    let acquired: Bool
}

private struct AuthorizeRequest: Encodable, Sendable {
    let account: AccountPayload
    let cookies: String
    let appStoreID: Int64
    let bundleID: String
    let externalVersionID: String
}

private struct AuthorizePayload: Decodable, Sendable {
    let sinf: String
    let metadata: String
    let version: String
    let bundleID: String
}

private struct VersionsRequest: Encodable, Sendable {
    let account: AccountPayload
    let cookies: String
    let appStoreID: Int64
    let bundleID: String
}

private struct VersionsPayload: Decodable, Sendable {
    struct Entry: Decodable, Sendable {
        let externalVersionID: String
        let versionString: String
        let releaseDate: String
    }
    let versions: [Entry]
}

private struct ProgressPayload: Decodable, Sendable {
    let phaseName: String
    let fraction: Double
    let bytesReceived: Int64
    let bytesExpected: Int64

    private enum CodingKeys: String, CodingKey {
        case phaseName = "phase"
        case fraction, bytesReceived, bytesExpected
    }

    /// Maps the sidecar's phase names onto the states the UI renders. An unknown
    /// name degrades to `.preparing` rather than failing the install.
    var phase: InstallPhase {
        switch phaseName {
        case "authorizing": return .authorizing
        case "packaging":   return .packaging
        case "downloading":
            return .downloading(
                fraction: min(max(fraction, 0), 1),
                bytesReceived: bytesReceived,
                bytesExpected: bytesExpected
            )
        default: return .preparing
        }
    }
}

// MARK: - Entitlements

extension BridgeAppStoreService: PurchaseEntitlementService {
    /// Asks Apple whether this account may download `app`.
    ///
    /// Apple has no dedicated ownership endpoint: the licence check and the download
    /// authorization are the same request. The bridge issues it and reads only the
    /// verdict, so no package bytes move and no purchase can occur.
    public func checkOwnership(of app: StoreApp, account: StoreAccount) async throws -> StoreProduct {
        let result: OwnershipPayload = try await client.call(
            method: "ownership",
            params: OwnershipRequest(
                account: .init(account),
                cookies: cookies,
                appStoreID: app.appStoreID,
                bundleID: app.bundleID,
                price: app.price
            )
        )

        return StoreProduct(
            app: app,
            ownership: result.ownership,
            downloadAuthorized: result.downloadAuthorized,
            availableVersions: result.availableVersions,
            detail: result.detail
        )
    }

    /// Obtains a licence for a free app. Refuses anything with a price before the
    /// request leaves this process; the bridge refuses again on its side.
    public func acquireFreeLicence(for app: StoreApp, account: StoreAccount) async throws {
        guard app.price == 0 else {
            throw StoreError.paidAppsUnsupported(name: app.name)
        }
        let _: EmptyPayload = try await client.call(
            method: "purchase",
            params: PurchaseRequest(
                account: .init(account),
                cookies: cookies,
                appStoreID: app.appStoreID,
                bundleID: app.bundleID,
                name: app.name,
                price: app.price
            )
        )
    }
}

private struct OwnershipRequest: Encodable, Sendable {
    let account: AccountPayload
    let cookies: String
    let appStoreID: Int64
    let bundleID: String
    let price: Double
}

private struct OwnershipPayload: Decodable, Sendable {
    let state: String
    let downloadAuthorized: Bool
    let availableVersions: Int
    let detail: String?

    var ownership: AppOwnershipState {
        switch state {
        case "free":         return .free
        case "purchased":    return .purchased
        case "notPurchased": return .notPurchased
        default:             return .unknown
        }
    }
}

private struct PurchaseRequest: Encodable, Sendable {
    let account: AccountPayload
    let cookies: String
    let appStoreID: Int64
    let bundleID: String
    let name: String
    let price: Double
}

private struct EmptyPayload: Decodable, Sendable {}
