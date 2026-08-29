import AppStoreDirectKit
import Observation
import SwiftUI

/// Observable front end for `MultiInstallCoordinator`.
///
/// Owns the per-device job table the UI renders and translates bulk actions
/// (Install on Selected, Cancel All, Retry Failed) into coordinator calls. It holds
/// no install logic of its own — scheduling, package reuse and cancellation all
/// live in the coordinator.
@MainActor
@Observable
final class InstallCenter {
    /// Every job, keyed by (app, device).
    private(set) var jobs: [InstallJobKey: PerDeviceInstallJob] = [:]
    /// Apps that currently have a batch, newest first, for rendering order.
    private(set) var activeAppIDs: [Int64] = []

    /// Max concurrent device installs. Persisted, and pushed to the scheduler.
    var concurrencyLimit: Int {
        didSet {
            guard concurrencyLimit != oldValue else { return }
            UserDefaults.standard.set(concurrencyLimit, forKey: Self.limitKey)
            Task { await scheduler.setLimit(concurrencyLimit) }
        }
    }

    private static let limitKey = "maxConcurrentInstalls"

    private let scheduler: InstallScheduler
    private var coordinator: MultiInstallCoordinator?
    /// Apps by ID, so Retry can rebuild a request without the view supplying it.
    private var knownApps: [Int64: StoreApp] = [:]

    init() {
        let stored = UserDefaults.standard.integer(forKey: Self.limitKey)
        let limit = InstallScheduler.allowedLimits.contains(stored) ? stored : InstallScheduler.defaultLimit
        self.concurrencyLimit = limit
        self.scheduler = InstallScheduler(limit: limit)
    }

    /// Rebuilt whenever the signed-in session changes.
    func configure(store: any AppStoreService) {
        coordinator = MultiInstallCoordinator(store: store, scheduler: scheduler)
    }

    func teardown() async {
        await coordinator?.releaseAll()
        coordinator = nil
        jobs.removeAll()
        activeAppIDs.removeAll()
    }

    // MARK: - Queries

    func job(app: StoreApp, udid: String) -> PerDeviceInstallJob? {
        jobs[InstallJobKey(appStoreID: app.appStoreID, udid: udid)]
    }

    func state(app: StoreApp, udid: String) -> DeviceInstallState {
        job(app: app, udid: udid)?.state ?? .idle
    }

    /// Jobs for one app, ordered by device name for a stable list.
    func jobs(for app: StoreApp) -> [PerDeviceInstallJob] {
        jobs.values
            .filter { $0.key.appStoreID == app.appStoreID }
            .sorted { $0.deviceName.localizedCaseInsensitiveCompare($1.deviceName) == .orderedAscending }
    }

    func summary(for app: StoreApp) -> InstallSummary {
        InstallSummary(jobs(for: app).map(\.state))
    }

    /// Counts across everything in flight — the bulk progress summary.
    var overallSummary: InstallSummary {
        InstallSummary(jobs.values.map(\.state))
    }

    /// The most advanced state for a device across all apps, for the device list.
    func currentState(udid: String) -> DeviceInstallState? {
        jobs.values
            .filter { $0.key.udid == udid && $0.state.isActive }
            .max { ($0.state.fraction ?? 0) < ($1.state.fraction ?? 0) }?
            .state
    }

    var hasActivity: Bool { overallSummary.hasActivity }
    var hasFailures: Bool { overallSummary.hasFailures }

    // MARK: - Actions

    /// Installs `app` onto every supplied device. Incompatible devices are reported
    /// as such by the coordinator rather than silently dropped.
    func install(app: StoreApp, devices: [ConnectedDevice], account: StoreAccount) {
        guard let coordinator, !devices.isEmpty else { return }
        knownApps[app.appStoreID] = app

        if !activeAppIDs.contains(app.appStoreID) {
            activeAppIDs.insert(app.appStoreID, at: 0)
        }
        // Seed rows immediately so the UI reacts on the same runloop turn as the
        // click, rather than after the coordinator's first callback.
        for device in devices {
            let key = InstallJobKey(appStoreID: app.appStoreID, udid: device.udid)
            if jobs[key]?.state.isActive == true { continue }
            jobs[key] = PerDeviceInstallJob(app: app, device: device, state: .queued)
        }

        let handler = makeHandler(app: app, devices: devices)
        Task { await coordinator.start(app: app, account: account, devices: devices, onUpdate: handler) }
    }

    func cancel(app: StoreApp, udid: String) {
        guard let coordinator else { return }
        Task { await coordinator.cancel(appStoreID: app.appStoreID, udid: udid) }
    }

    func cancelAll() {
        guard let coordinator else { return }
        Task { await coordinator.cancelAll() }
    }

    func retry(app: StoreApp, device: ConnectedDevice, account: StoreAccount) {
        guard let coordinator else { return }
        let handler = makeHandler(app: app, devices: [device])
        jobs[InstallJobKey(appStoreID: app.appStoreID, udid: device.udid)] =
            PerDeviceInstallJob(app: app, device: device, state: .queued)
        Task { await coordinator.retry(app: app, account: account, device: device, onUpdate: handler) }
    }

    /// Re-runs every failed or cancelled job, across all apps.
    func retryFailed(account: StoreAccount, devices: [ConnectedDevice]) {
        let byUDID = Dictionary(uniqueKeysWithValues: devices.map { ($0.udid, $0) })
        for job in jobs.values where job.state.isRetryable {
            guard let app = knownApps[job.key.appStoreID],
                  let device = byUDID[job.key.udid] else { continue }
            retry(app: app, device: device, account: account)
        }
    }

    /// Clears finished rows for one app and frees its cached package.
    func dismiss(app: StoreApp) {
        guard let coordinator else { return }
        jobs = jobs.filter { $0.key.appStoreID != app.appStoreID }
        activeAppIDs.removeAll { $0 == app.appStoreID }
        Task { await coordinator.release(appStoreID: app.appStoreID) }
    }

    func clearFinished() {
        for (key, job) in jobs where !job.state.isActive {
            jobs.removeValue(forKey: key)
        }
        let remaining = Set(jobs.keys.map(\.appStoreID))
        activeAppIDs.removeAll { !remaining.contains($0) }
    }

    // MARK: - Plumbing

    /// Bridges the coordinator's `@Sendable` UDID/state callback onto the main actor.
    private func makeHandler(app: StoreApp, devices: [ConnectedDevice]) -> MultiInstallCoordinator.StateHandler {
        let descriptors = Dictionary(
            uniqueKeysWithValues: devices.map {
                ($0.udid, (name: $0.name, model: $0.marketingName, ios: $0.iosVersion))
            }
        )
        let appStoreID = app.appStoreID

        return { [weak self] udid, state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let key = InstallJobKey(appStoreID: appStoreID, udid: udid)
                if var existing = self.jobs[key] {
                    existing.state = state
                    self.jobs[key] = existing
                } else if let descriptor = descriptors[udid] {
                    self.jobs[key] = PerDeviceInstallJob(
                        key: key,
                        deviceName: descriptor.name,
                        deviceModel: descriptor.model,
                        iosVersion: descriptor.ios,
                        state: state
                    )
                }
            }
        }
    }
}
