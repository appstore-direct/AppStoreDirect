import CMobileDevice
import Foundation

/// Progress of the on-device half of an install.
public enum TransferPhase: Sendable {
    /// Copying the package to `PublicStaging` over AFC.
    case copying(fraction: Double)
    /// installation_proxy is unpacking and registering the app.
    case installing(fraction: Double, stage: String)
    case finished
}

/// Installs a package onto a connected device and enumerates what is already there.
///
/// This mirrors what Apple Configurator does: upload the archive over AFC, then hand
/// installation_proxy the account's FairPlay licence (`ApplicationSINF`) and the store
/// metadata. The app binary stays encrypted the whole time — the device decrypts it
/// with the sinf, which is why the sinf must belong to the signed-in Apple Account.
///
/// A `struct`, deliberately, not an actor. libimobiledevice calls are blocking C
/// calls against a per-device socket, and an actor would serialise every install
/// behind one executor — which would make installing to ten phones exactly as slow
/// as doing them one at a time. Holding no state, each call opens its own device
/// session, so concurrent calls against *different* devices are independent.
/// Serialising work against the *same* device is the scheduler's job, not this type's.
public struct AppInstaller: Sendable {
    public init() {}

    private static let stagingDirectory = "PublicStaging"
    private static let label = "AppStoreDirect"
    private static let chunkSize = 1 << 20  // 1 MiB, matching ideviceinstaller

    /// User-installed apps present on the device.
    public func installedApps(udid: String) async throws -> [InstalledApp] {
        try await DeviceIO.run { try installedAppsSync(udid: udid) }
    }

    public func isInstalled(bundleID: String, udid: String) async throws -> Bool {
        try await DeviceIO.run { try isInstalledSync(bundleID: bundleID, udid: udid) }
    }

    /// Removes a package left in `PublicStaging`, e.g. after a failed install.
    public func clearStaging(bundleID: String, udid: String) async throws {
        try await DeviceIO.run { try clearStagingSync(bundleID: bundleID, udid: udid) }
    }

    /// Uploads and installs a package. `progress` is invoked on the device I/O
    /// queue, not the caller's context.
    ///
    /// An existing installation is upgraded in place rather than failing.
    public func install(
        packageURL: URL,
        bundleID: String,
        sinf: Data,
        iTunesMetadata: Data,
        udid: String,
        progress: @escaping @Sendable (TransferPhase) -> Void
    ) async throws {
        try await DeviceIO.run {
            try installSync(
                packageURL: packageURL,
                bundleID: bundleID,
                sinf: sinf,
                iTunesMetadata: iTunesMetadata,
                udid: udid,
                progress: progress
            )
        }
    }

    // MARK: - Blocking implementations
    //
    // Synchronous and safe to call from any thread. Exposed so a caller that is
    // already off the cooperative pool can skip the extra hop.

    public func installedAppsSync(udid: String) throws -> [InstalledApp] {
        let session = try DeviceSession(udid: udid)
        guard let device = session.device else { throw DeviceError.noDeviceConnected }

        var client: instproxy_client_t?
        let start = instproxy_client_start_service(device, &client, Self.label)
        guard start == INSTPROXY_E_SUCCESS, let client else {
            throw DeviceError.serviceUnavailable(name: "installation_proxy", code: start.rawValue)
        }
        defer { instproxy_client_free(client) }

        let options = instproxy_client_options_new()
        defer { if let options { instproxy_client_options_free(options) } }
        // `instproxy_client_options_add` is C-variadic and therefore unavailable to
        // Swift; setting the dictionary entry directly is exactly what it does.
        plist_dict_set_item(options, "ApplicationType", plist_new_string("User"))

        var result: plist_t?
        let browse = instproxy_browse(client, options, &result)
        guard browse == INSTPROXY_E_SUCCESS, let result else {
            throw DeviceError.serviceUnavailable(name: "instproxy_browse", code: browse.rawValue)
        }
        defer { plist_free(result) }

        var apps: [InstalledApp] = []
        Plist.forEachArrayItem(result) { entry in
            var bundleID: String?
            var name: String?
            var version = ""
            var shortVersion = ""
            Plist.forEachDictEntry(entry) { key, value in
                switch key {
                case "CFBundleIdentifier":         bundleID = Plist.string(value)
                case "CFBundleDisplayName":        name = Plist.string(value) ?? name
                case "CFBundleName":               name = name ?? Plist.string(value)
                case "CFBundleVersion":            version = Plist.string(value) ?? ""
                case "CFBundleShortVersionString": shortVersion = Plist.string(value) ?? ""
                default: break
                }
            }
            guard let bundleID else { return }
            apps.append(
                InstalledApp(
                    bundleIdentifier: bundleID,
                    name: name ?? bundleID,
                    version: version,
                    shortVersion: shortVersion.isEmpty ? version : shortVersion
                )
            )
        }
        return apps
    }

    public func isInstalledSync(bundleID: String, udid: String) throws -> Bool {
        try installedAppsSync(udid: udid).contains { $0.bundleIdentifier == bundleID }
    }

    public func installSync(
        packageURL: URL,
        bundleID: String,
        sinf: Data,
        iTunesMetadata: Data,
        udid: String,
        progress: @escaping @Sendable (TransferPhase) -> Void
    ) throws {
        let session = try DeviceSession(udid: udid)
        guard let device = session.device else { throw DeviceError.noDeviceConnected }

        let remotePath = "\(Self.stagingDirectory)/\(bundleID)"
        try uploadPackage(packageURL, to: remotePath, device: device, progress: progress)

        var client: instproxy_client_t?
        let start = instproxy_client_start_service(device, &client, Self.label)
        guard start == INSTPROXY_E_SUCCESS, let client else {
            throw DeviceError.serviceUnavailable(name: "installation_proxy", code: start.rawValue)
        }
        defer { instproxy_client_free(client) }

        let options = instproxy_client_options_new()
        defer { if let options { instproxy_client_options_free(options) } }

        plist_dict_set_item(options, "CFBundleIdentifier", plist_new_string(bundleID))
        // `PackageType` is deliberately not set: it is only meaningful for Developer
        // and CarrierBundle packages. A store package must be left unlabelled.
        if let sinfNode = Plist.data(sinf) {
            plist_dict_set_item(options, "ApplicationSINF", sinfNode)
        }
        if let metadataNode = Plist.data(iTunesMetadata) {
            plist_dict_set_item(options, "iTunesMetadata", metadataNode)
        }

        let alreadyPresent = (try? isInstalledSync(bundleID: bundleID, udid: udid)) ?? false

        let observer = InstallObserver(progress: progress)
        let context = Unmanaged.passRetained(observer).toOpaque()
        defer { Unmanaged<InstallObserver>.fromOpaque(context).release() }

        let result = alreadyPresent
            ? instproxy_upgrade(client, remotePath, options, installStatusCallback, context)
            : instproxy_install(client, remotePath, options, installStatusCallback, context)

        guard result == INSTPROXY_E_SUCCESS else {
            throw DeviceError.serviceUnavailable(name: "instproxy_install", code: result.rawValue)
        }

        // instproxy_install is asynchronous: it returns as soon as the command is
        // accepted, and the callback runs until a terminal status arrives.
        try observer.waitForCompletion()
        progress(.finished)
    }

    /// Streams the package to the device over AFC in 1 MiB chunks.
    private func uploadPackage(
        _ url: URL,
        to remotePath: String,
        device: idevice_t,
        progress: @escaping @Sendable (TransferPhase) -> Void
    ) throws {
        var afc: afc_client_t?
        let start = afc_client_start_service(device, &afc, Self.label)
        guard start == AFC_E_SUCCESS, let afc else {
            throw DeviceError.serviceUnavailable(name: "afc", code: start.rawValue)
        }
        defer { afc_client_free(afc) }

        // Present on stock iOS, but a fresh restore can be missing it.
        afc_make_directory(afc, Self.stagingDirectory)

        let totalBytes = (try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var remoteHandle: UInt64 = 0
        let open = afc_file_open(afc, remotePath, AFC_FOPEN_WRONLY, &remoteHandle)
        guard open == AFC_E_SUCCESS, remoteHandle != 0 else {
            throw DeviceError.fileTransferFailed(path: remotePath, code: open.rawValue)
        }
        var closed = false
        defer { if !closed { afc_file_close(afc, remoteHandle) } }

        var sent: Int64 = 0
        while true {
            guard let chunk = try handle.read(upToCount: Self.chunkSize), !chunk.isEmpty else { break }

            // AFC can accept a short write; loop until the whole chunk is gone.
            var offset = 0
            while offset < chunk.count {
                let written: UInt32 = try chunk.withUnsafeBytes { buffer -> UInt32 in
                    let base = buffer.baseAddress!.advanced(by: offset)
                        .assumingMemoryBound(to: CChar.self)
                    var count: UInt32 = 0
                    let result = afc_file_write(
                        afc, remoteHandle, base, UInt32(chunk.count - offset), &count
                    )
                    guard result == AFC_E_SUCCESS else {
                        throw DeviceError.fileTransferFailed(path: remotePath, code: result.rawValue)
                    }
                    return count
                }
                guard written > 0 else {
                    throw DeviceError.fileTransferFailed(path: remotePath, code: 0)
                }
                offset += Int(written)
            }

            sent += Int64(chunk.count)
            let fraction = totalBytes > 0 ? Double(sent) / Double(totalBytes) : 0
            progress(.copying(fraction: min(fraction, 1)))
        }

        afc_file_close(afc, remoteHandle)
        closed = true
    }

    public func clearStagingSync(bundleID: String, udid: String) throws {
        let session = try DeviceSession(udid: udid)
        guard let device = session.device else { return }
        var afc: afc_client_t?
        guard afc_client_start_service(device, &afc, Self.label) == AFC_E_SUCCESS, let afc else { return }
        defer { afc_client_free(afc) }
        afc_remove_path(afc, "\(Self.stagingDirectory)/\(bundleID)")
    }
}
