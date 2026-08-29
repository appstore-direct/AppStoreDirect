import DeviceKit
import Foundation
import StoreBridge

/// What the Install button shows, moment to moment.
public enum InstallState: Sendable, Equatable {
    case idle
    case preparing
    case authorizing
    case downloading(fraction: Double, detail: String)
    case packaging
    case transferring(fraction: Double)
    case installing(fraction: Double)
    case installed
    case failed(message: String)

    /// Text shown under the app name, matching the flow in the product spec.
    public var label: String {
        switch self {
        case .idle:                     return ""
        case .preparing:                return "Preparing…"
        case .authorizing:              return "Authorizing with App Store…"
        case .downloading(let f, let d):
            return d.isEmpty
                ? "Downloading from Apple… \(Int(f * 100))%"
                : "Downloading from Apple… \(Int(f * 100))%  (\(d))"
        case .packaging:                return "Preparing package…"
        case .transferring(let f):      return "Copying to iPhone… \(Int(f * 100))%"
        case .installing(let f):        return "Installing to iPhone… \(Int(f * 100))%"
        case .installed:                return "Installed ✓"
        case .failed(let message):      return message
        }
    }

    public var isActive: Bool {
        switch self {
        case .idle, .installed, .failed: return false
        default: return true
        }
    }

    /// Single 0–1 value for a determinate progress bar. Download is weighted at
    /// 70% of the whole because it dominates wall-clock time on a real install.
    public var fraction: Double? {
        switch self {
        case .preparing, .authorizing:  return 0
        case .downloading(let f, _):    return f * 0.7
        case .packaging:                return 0.72
        case .transferring(let f):      return 0.75 + f * 0.15
        case .installing(let f):        return 0.90 + f * 0.10
        case .installed:                return 1
        case .idle, .failed:            return nil
        }
    }
}

/// Runs one Install press end to end: licence, download, transfer, install, cleanup.
///
/// Deliberately the only place the store half and the device half meet. Neither
/// `AppStoreService` nor `AppInstaller` knows the other exists.
public actor InstallCoordinator {
    private let store: any AppStoreService
    private let installer: AppInstaller
    private let cacheDirectory: URL

    public init(store: any AppStoreService, installer: AppInstaller = AppInstaller(), cacheDirectory: URL? = nil) {
        self.store = store
        self.installer = installer
        self.cacheDirectory = cacheDirectory ?? Self.defaultCacheDirectory()
    }

    /// Packages live in the app's own cache container, never anywhere the user is
    /// expected to find or manage them.
    public static func defaultCacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("com.appstoredirect.mac", isDirectory: true)
            .appendingPathComponent("Packages", isDirectory: true)
    }

    /// Installs `app` onto `device`.
    ///
    /// - Parameter onState: called with every state change, on an arbitrary thread.
    public func install(
        app: StoreApp,
        account: StoreAccount,
        device: ConnectedDevice,
        externalVersionID: String? = nil,
        onState: @escaping @Sendable (InstallState) -> Void
    ) async throws {
        // Refuse early rather than downloading hundreds of megabytes that the
        // device will reject at the last step.
        if externalVersionID == nil, !app.minimumOSVersion.isEmpty,
           !device.canRun(minimumOSVersion: app.minimumOSVersion) {
            throw StoreError.incompatible(
                app: app.name,
                requires: app.minimumOSVersion,
                deviceHas: device.iosVersion
            )
        }

        onState(.preparing)
        try FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        var package: AcquiredPackage?
        defer {
            // Requirement 9: the package is a private implementation detail. It is
            // removed as soon as the install succeeds or fails for good.
            if let package { try? FileManager.default.removeItem(at: package.url) }
        }

        let acquired = try await store.acquire(
            app: app,
            account: account,
            externalVersionID: externalVersionID,
            into: cacheDirectory
        ) { phase in
            switch phase {
            case .preparing:   onState(.preparing)
            case .authorizing: onState(.authorizing)
            case .downloading(let fraction, let received, let expected):
                onState(.downloading(
                    fraction: fraction,
                    detail: Self.byteDetail(received: received, expected: expected)
                ))
            case .packaging:   onState(.packaging)
            default:           break
            }
        }
        package = acquired

        try Task.checkCancellation()

        try await installer.install(
            packageURL: acquired.url,
            bundleID: acquired.bundleID,
            sinf: acquired.sinf,
            iTunesMetadata: acquired.iTunesMetadata,
            udid: device.udid
        ) { phase in
            switch phase {
            case .copying(let fraction):      onState(.transferring(fraction: fraction))
            case .installing(let fraction, _): onState(.installing(fraction: fraction))
            case .finished:                    onState(.installed)
            }
        }

        // The staged copy on the phone is dead weight once the install completes.
        try? await installer.clearStaging(bundleID: acquired.bundleID, udid: device.udid)
        onState(.installed)
    }

    /// Removes packages left behind by a crash or a failed install. Called at
    /// launch, before any session exists, so it is a plain static utility rather
    /// than something that needs a coordinator or a signed-in account.
    public static func sweepCache(directory: URL? = nil) {
        let target = directory ?? defaultCacheDirectory()
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: target,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        // Anything older than a day cannot be part of a live install.
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, modified > cutoff { continue }
            try? manager.removeItem(at: entry)
        }
    }

    private static func byteDetail(received: Int64, expected: Int64) -> String {
        guard expected > 0 else { return "" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: received)) of \(formatter.string(fromByteCount: expected))"
    }
}
