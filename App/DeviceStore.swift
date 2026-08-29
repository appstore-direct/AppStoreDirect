import AppStoreDirectKit
import Observation
import SwiftUI

/// Every connected device, plus which ones the user has selected to act on.
///
/// Replaces the previous single `device` property. Selection is held as a set of
/// UDIDs rather than of `ConnectedDevice` values, so a device that reconnects — and
/// so arrives as a new value with a fresh battery reading — keeps its selection.
@MainActor
@Observable
final class DeviceStore {
    private(set) var devices: [ConnectedDevice] = []
    private(set) var isRefreshing = false
    var errorMessage: String?

    /// UDIDs the user has ticked.
    var selectedUDIDs: Set<String> = []

    /// Apps already on each device, keyed by UDID. Populated lazily per device so
    /// plugging in ten phones does not fire ten lockdown handshakes at once.
    private(set) var installedApps: [String: [InstalledApp]] = [:]
    private(set) var loadingInstalledFor: Set<String> = []

    private let service = DeviceService()
    private let installer = AppInstaller()
    private var monitorTask: Task<Void, Never>?
    /// Devices usbmuxd reports but that could not be described — locked, untrusted,
    /// still booting, or a usbmuxd failure under load. The reason is kept and shown
    /// rather than discarded, so a phone is never silently missing from the fleet.
    private(set) var unreachable: [UnreachableDevice] = []

    struct UnreachableDevice: Identifiable, Hashable {
        var id: String { udid }
        let udid: String
        let reason: String
    }

    var selectedDevices: [ConnectedDevice] {
        devices.filter { selectedUDIDs.contains($0.udid) }
    }

    var hasSelection: Bool { !selectedDevices.isEmpty }
    var isAllSelected: Bool { !devices.isEmpty && selectedUDIDs.count >= devices.count }

    func device(udid: String) -> ConnectedDevice? {
        devices.first { $0.udid == udid }
    }

    // MARK: - Selection

    func toggle(_ device: ConnectedDevice) {
        if selectedUDIDs.contains(device.udid) {
            selectedUDIDs.remove(device.udid)
        } else {
            selectedUDIDs.insert(device.udid)
        }
    }

    func isSelected(_ device: ConnectedDevice) -> Bool {
        selectedUDIDs.contains(device.udid)
    }

    func selectAll() {
        selectedUDIDs = Set(devices.map(\.udid))
    }

    func selectNone() {
        selectedUDIDs.removeAll()
    }

    func toggleSelectAll() {
        isAllSelected ? selectNone() : selectAll()
    }

    /// Selects only this device — the single-device workflow, preserved.
    func selectOnly(_ device: ConnectedDevice) {
        selectedUDIDs = [device.udid]
    }

    // MARK: - Discovery

    func start() async {
        await refresh()
        guard monitorTask == nil else { return }

        do {
            try DeviceMonitor.shared.start()
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        monitorTask = Task { [weak self] in
            for await event in DeviceMonitor.shared.events() {
                guard let self else { return }
                switch event {
                case .attached, .paired:
                    // A phone needs a moment after enumerating before lockdown will
                    // complete a handshake.
                    try? await Task.sleep(for: .milliseconds(600))
                    await self.refresh()
                case .detached(let udid):
                    await self.handleDetach(udid: udid)
                }
            }
        }
    }

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let attached = try await service.attachedDevices()
            var described: [ConnectedDevice] = []
            var failures: [UnreachableDevice] = []

            // Describing one device at a time: each opens a lockdown session, and
            // hammering usbmuxd with parallel handshakes produces spurious failures.
            // With twenty phones this takes a moment, which is preferable to a
            // refresh that reports fewer devices than are actually plugged in.
            for entry in attached {
                do {
                    described.append(
                        try await service.describe(udid: entry.udid, connection: entry.connection)
                    )
                } catch {
                    failures.append(
                        UnreachableDevice(udid: entry.udid, reason: error.localizedDescription)
                    )
                }
            }

            devices = described.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            unreachable = failures
            errorMessage = nil

            // Drop selections for devices that are gone.
            let present = Set(devices.map(\.udid))
            selectedUDIDs.formIntersection(present)

            // First device to appear is selected, so the single-device flow needs
            // no ceremony: plug in one phone and Install is immediately usable.
            if selectedUDIDs.isEmpty, devices.count == 1 {
                selectedUDIDs = [devices[0].udid]
            }

            // Drop cached listings for devices that went away, then read the list for
            // any device we have not seen before — this is what makes the tracked-app
            // badges correct on connect and reconnect.
            installedApps = installedApps.filter { present.contains($0.key) }
            let unread = devices.filter { installedApps[$0.udid] == nil }.map(\.udid)
            if !unread.isEmpty {
                Task { [weak self] in
                    for udid in unread {
                        await self?.refreshInstalledApps(for: udid)
                    }
                }
            }
        } catch {
            devices = []
            unreachable = []
            errorMessage = error.localizedDescription
        }
    }

    /// Reads the installed-app list from every connected device.
    ///
    /// Serial on purpose: each device opens its own lockdown and installation_proxy
    /// session, and twenty simultaneous handshakes is exactly the load that makes
    /// usbmuxd start refusing connections.
    func refreshInstalledAppsForAll() async {
        for device in devices {
            await refreshInstalledApps(for: device.udid)
        }
    }

    private func handleDetach(udid: String) async {
        devices.removeAll { $0.udid == udid }
        selectedUDIDs.remove(udid)
        unreachable.removeAll { $0.udid == udid }
        installedApps.removeValue(forKey: udid)
    }

    // MARK: - Tracked apps

    /// Which tracked apps are actually present on a device.
    ///
    /// Answered from that device's real `instproxy_browse` listing, matched by bundle
    /// identifier. A device whose list has not been read yet reports nothing rather
    /// than guessing.
    func trackedAppsInstalled(on udid: String) -> [TrackedApp] {
        let present = Set(installedApps(for: udid).map(\.bundleIdentifier))
        return TrackedApp.all.filter { present.contains($0.bundleID) }
    }

    /// True once this device's installed list has been read at least once.
    func hasReadInstalledApps(for udid: String) -> Bool {
        installedApps[udid] != nil
    }

    // MARK: - Installed apps

    func installedApps(for udid: String) -> [InstalledApp] {
        installedApps[udid] ?? []
    }

    func isLoadingInstalled(for udid: String) -> Bool {
        loadingInstalledFor.contains(udid)
    }

    func refreshInstalledApps(for udid: String) async {
        guard !loadingInstalledFor.contains(udid) else { return }
        loadingInstalledFor.insert(udid)
        defer { loadingInstalledFor.remove(udid) }

        do {
            installedApps[udid] = try await installer.installedApps(udid: udid)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            // A phone that locked mid-refresh is not worth an alert; the list simply
            // stays as it was and the user can refresh again.
            errorMessage = error.localizedDescription
        }
    }

    /// Refreshes the selected devices one at a time.
    func refreshInstalledAppsForSelection() async {
        for device in selectedDevices {
            await refreshInstalledApps(for: device.udid)
        }
    }

    func isInstalled(_ app: StoreApp, on device: ConnectedDevice) -> Bool {
        installedApps(for: device.udid).contains { $0.bundleIdentifier == app.bundleID }
    }

    /// Compatibility verdict for one device, used to disable Install per row.
    func canRun(_ app: StoreApp, on device: ConnectedDevice) -> Bool {
        guard !app.minimumOSVersion.isEmpty else { return true }
        return device.canRun(minimumOSVersion: app.minimumOSVersion)
    }

    /// Selected devices that could actually run `app`.
    func compatibleSelection(for app: StoreApp) -> [ConnectedDevice] {
        selectedDevices.filter { canRun(app, on: $0) }
    }

    /// Selected devices that are incompatible, so the UI can say why rather than
    /// silently installing to fewer phones than the user ticked.
    func incompatibleSelection(for app: StoreApp) -> [ConnectedDevice] {
        selectedDevices.filter { !canRun(app, on: $0) }
    }
}
