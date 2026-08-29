import DeviceKit
import Foundation
import StoreBridge

/// Installs one app onto many devices.
///
/// Two facts from Apple's protocol shape this, both established by experiment rather
/// than assumption (see docs/OPEN-QUESTIONS.md):
///
/// 1. **The download authorization request carries no device identifier** — only the
///    Mac's guid and a literal `serialNumber` of `"0"`. The licence is therefore
///    scoped to the Apple Account, so one downloaded package legitimately serves
///    every device signed into that account. The package is downloaded **once**.
/// 2. **Apple issues fresh licence material on every authorization.** Requesting the
///    same app twice for the same account and version returns two different sinf
///    blobs. So rather than sharing one sinf, each device gets **its own
///    authorization** — a small POST, no package bytes — and that sinf is handed to
///    installation_proxy as `ApplicationSINF` alongside the shared package.
///
/// The result is one large download and N small authorizations, instead of either
/// N large downloads or one licence reused in a way Apple's protocol does not
/// obviously sanction.
///
/// Ownership of in-flight work lives here rather than in the UI: the coordinator
/// holds the acquire task and one task per device, which is what makes per-device
/// Cancel, Retry and Cancel All possible without the view layer juggling tasks.
public actor MultiInstallCoordinator {
    private let store: any AppStoreService
    private let installer: AppInstaller
    private let scheduler: InstallScheduler
    private let cacheDirectory: URL

    /// One app's fan-out across devices.
    private struct Batch {
        var app: StoreApp
        var account: StoreAccount
        var package: AcquiredPackage?
        var acquireTask: Task<AcquiredPackage, Error>?
        var deviceTasks: [String: Task<Void, Never>] = [:]
        /// Devices still eligible to run — used to decide when the package can go.
        var pending: Set<String> = []
        var retryable: Set<String> = []
    }

    private var batches: [Int64: Batch] = [:]

    public init(
        store: any AppStoreService,
        installer: AppInstaller = AppInstaller(),
        scheduler: InstallScheduler,
        cacheDirectory: URL? = nil
    ) {
        self.store = store
        self.installer = installer
        self.scheduler = scheduler
        self.cacheDirectory = cacheDirectory ?? InstallCoordinator.defaultCacheDirectory()
    }

    public typealias StateHandler = @Sendable (String, DeviceInstallState) -> Void

    // MARK: - Starting work

    /// Begins installing `app` onto `devices`. Returns as soon as the batch is
    /// scheduled; progress arrives through `onUpdate`, keyed by UDID.
    ///
    /// Devices already working on this app are left alone, so pressing Install
    /// twice does not double-schedule.
    public func start(
        app: StoreApp,
        account: StoreAccount,
        devices: [ConnectedDevice],
        onUpdate: @escaping StateHandler
    ) {
        // Reject incompatible devices before any bytes move. Downloading a package
        // the phone will refuse at the last step wastes the user's time and Apple's.
        var eligible: [ConnectedDevice] = []
        for device in devices {
            if !app.minimumOSVersion.isEmpty, !device.canRun(minimumOSVersion: app.minimumOSVersion) {
                onUpdate(device.udid, .incompatible(
                    reason: "Needs iOS \(app.minimumOSVersion) — this iPhone runs \(device.iosVersion)"
                ))
                continue
            }
            eligible.append(device)
        }

        guard !eligible.isEmpty else { return }

        var batch = batches[app.appStoreID] ?? Batch(app: app, account: account)
        batch.app = app
        batch.account = account

        let fresh = eligible.filter { batch.deviceTasks[$0.udid] == nil }
        guard !fresh.isEmpty else {
            batches[app.appStoreID] = batch
            return
        }

        for device in fresh {
            batch.pending.insert(device.udid)
            batch.retryable.remove(device.udid)
            onUpdate(device.udid, .queued)
        }
        batches[app.appStoreID] = batch

        for device in fresh {
            scheduleDevice(app: app, account: account, device: device, onUpdate: onUpdate)
        }
    }

    /// Re-runs one device that failed or was cancelled. Reuses the batch's package
    /// when it is still on disk, so a retry after a transient USB error does not
    /// re-download from Apple.
    public func retry(
        app: StoreApp,
        account: StoreAccount,
        device: ConnectedDevice,
        onUpdate: @escaping StateHandler
    ) {
        guard batches[app.appStoreID]?.deviceTasks[device.udid] == nil else { return }
        start(app: app, account: account, devices: [device], onUpdate: onUpdate)
    }

    // MARK: - Cancellation

    /// Cancels one device's job. The shared download continues if other devices in
    /// the batch still need it.
    public func cancel(appStoreID: Int64, udid: String) {
        guard var batch = batches[appStoreID] else { return }
        batch.deviceTasks[udid]?.cancel()
        batch.deviceTasks[udid] = nil
        batch.pending.remove(udid)
        batches[appStoreID] = batch
        finishIfDone(appStoreID: appStoreID)
    }

    public func cancelBatch(appStoreID: Int64) {
        guard let batch = batches[appStoreID] else { return }
        batch.acquireTask?.cancel()
        for task in batch.deviceTasks.values { task.cancel() }
        batches[appStoreID]?.deviceTasks.removeAll()
        batches[appStoreID]?.pending.removeAll()
        finishIfDone(appStoreID: appStoreID)
    }

    public func cancelAll() {
        for appStoreID in batches.keys { cancelBatch(appStoreID: appStoreID) }
    }

    /// Drops a finished batch and deletes its cached package. Called when the user
    /// dismisses a completed batch, and on sign-out.
    public func release(appStoreID: Int64) {
        guard let batch = batches.removeValue(forKey: appStoreID) else { return }
        batch.acquireTask?.cancel()
        for task in batch.deviceTasks.values { task.cancel() }
        if let package = batch.package {
            try? FileManager.default.removeItem(at: package.url)
        }
    }

    public func releaseAll() {
        for appStoreID in batches.keys { release(appStoreID: appStoreID) }
    }

    // MARK: - Internals

    private func scheduleDevice(
        app: StoreApp,
        account: StoreAccount,
        device: ConnectedDevice,
        onUpdate: @escaping StateHandler
    ) {
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runDevice(app: app, account: account, device: device, onUpdate: onUpdate)
        }
        batches[app.appStoreID]?.deviceTasks[device.udid] = task
    }

    private func runDevice(
        app: StoreApp,
        account: StoreAccount,
        device: ConnectedDevice,
        onUpdate: @escaping StateHandler
    ) async {
        let udid = device.udid
        do {
            let package = try await packageForBatch(app: app, account: account, onUpdate: onUpdate)
            try Task.checkCancellation()

            // This device's own licence. Cheap, and avoids assuming one sinf may be
            // replayed across devices when Apple plainly mints a new one each time.
            let authorization = try await store.authorizeDownload(
                app: app,
                account: account,
                externalVersionID: nil
            )
            try Task.checkCancellation()

            // The slot is taken only for the on-device phase. Holding it across the
            // shared download would serialise a step that is already shared.
            try await scheduler.withSlot(udid: udid) {
                try Task.checkCancellation()
                try await self.installer.install(
                    packageURL: package.url,
                    bundleID: package.bundleID,
                    sinf: authorization.sinf,
                    iTunesMetadata: authorization.iTunesMetadata,
                    udid: udid
                ) { phase in
                    switch phase {
                    case .copying(let fraction):
                        onUpdate(udid, .transferring(fraction: fraction))
                    case .installing(let fraction, _):
                        onUpdate(udid, .installing(fraction: fraction))
                    case .finished:
                        break
                    }
                }
            }

            try? await installer.clearStaging(bundleID: package.bundleID, udid: udid)
            onUpdate(udid, .installed)
            completeDevice(appStoreID: app.appStoreID, udid: udid, retryable: false)
        } catch is CancellationError {
            onUpdate(udid, .cancelled)
            completeDevice(appStoreID: app.appStoreID, udid: udid, retryable: true)
        } catch {
            onUpdate(udid, .failed(message: error.localizedDescription))
            completeDevice(appStoreID: app.appStoreID, udid: udid, retryable: true)
        }
    }

    /// Returns the batch's package, acquiring it once and sharing it with every
    /// device that asks concurrently.
    private func packageForBatch(
        app: StoreApp,
        account: StoreAccount,
        onUpdate: @escaping StateHandler
    ) async throws -> AcquiredPackage {
        if let existing = batches[app.appStoreID]?.package,
           FileManager.default.fileExists(atPath: existing.url.path) {
            return existing
        }

        if let inFlight = batches[app.appStoreID]?.acquireTask {
            return try await inFlight.value
        }

        let directory = cacheDirectory
        let store = self.store
        // Captured strongly and once: the progress closure runs on the bridge's
        // reader thread, and a nested weak capture inside it is not expressible.
        // The coordinator outlives every batch it owns, so there is no cycle to break.
        let coordinator = self
        let appStoreID = app.appStoreID

        let task = Task<AcquiredPackage, Error> {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            return try await store.acquire(
                app: app,
                account: account,
                externalVersionID: nil,
                into: directory
            ) { phase in
                // Shared work: report it against every device waiting on it, so the
                // user sees one download reflected across the whole batch.
                let state = Self.state(for: phase)
                Task {
                    let waiting = await coordinator.devicesAwaitingPackage(appStoreID: appStoreID)
                    for udid in waiting { onUpdate(udid, state) }
                }
            }
        }

        batches[app.appStoreID]?.acquireTask = task

        do {
            let package = try await task.value
            batches[app.appStoreID]?.package = package
            batches[app.appStoreID]?.acquireTask = nil
            return package
        } catch {
            batches[app.appStoreID]?.acquireTask = nil
            throw error
        }
    }

    private func devicesAwaitingPackage(appStoreID: Int64) -> [String] {
        Array(batches[appStoreID]?.pending ?? [])
    }

    private static func state(for phase: InstallPhase) -> DeviceInstallState {
        switch phase {
        case .preparing:   return .preparing
        case .authorizing: return .authorizing
        case .downloading(let fraction, let received, let expected):
            return .downloading(
                fraction: fraction,
                detail: byteDetail(received: received, expected: expected)
            )
        case .packaging:   return .preparing
        case .transferring(let fraction): return .transferring(fraction: fraction)
        case .installing(let fraction):   return .installing(fraction: fraction)
        case .installed:   return .installed
        }
    }

    private static func byteDetail(received: Int64, expected: Int64) -> String {
        guard expected > 0 else { return "" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: received)) of \(formatter.string(fromByteCount: expected))"
    }

    private func completeDevice(appStoreID: Int64, udid: String, retryable: Bool) {
        guard var batch = batches[appStoreID] else { return }
        batch.deviceTasks[udid] = nil
        batch.pending.remove(udid)
        if retryable { batch.retryable.insert(udid) } else { batch.retryable.remove(udid) }
        batches[appStoreID] = batch
        finishIfDone(appStoreID: appStoreID)
    }

    /// Deletes the shared package once nothing can still need it. It is kept while
    /// any device is retryable, so "Retry Failed" does not re-download from Apple.
    private func finishIfDone(appStoreID: Int64) {
        guard let batch = batches[appStoreID] else { return }
        guard batch.pending.isEmpty, batch.deviceTasks.isEmpty else { return }

        if batch.retryable.isEmpty {
            if let package = batch.package {
                try? FileManager.default.removeItem(at: package.url)
            }
            batches[appStoreID] = nil
        }
    }
}
