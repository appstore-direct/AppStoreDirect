import CMobileDevice
import Foundation

/// A short-lived, non-Sendable handle to one connected device: an `idevice_t`
/// plus a completed lockdown handshake. Everything that talks to the phone opens
/// one of these, does its work, and lets `deinit` tear it down.
///
/// Deliberately scoped rather than long-lived: holding a lockdown client open
/// across a long download is a good way to get stale-handle failures when the
/// user unplugs the cable.
final class DeviceSession {
    let udid: String
    private(set) var device: idevice_t?
    private(set) var lockdown: lockdownd_client_t?

    /// Label reported to the device; shows up in its logs.
    private static let serviceLabel = "AppStoreDirect"

    init(udid: String, options: idevice_options = IDEVICE_LOOKUP_USBMUX) throws {
        self.udid = udid

        var handle: idevice_t?
        let openResult = idevice_new_with_options(&handle, udid, options)
        guard openResult == IDEVICE_E_SUCCESS, let handle else {
            throw DeviceError.deviceUnavailable(udid: udid, code: openResult.rawValue)
        }
        self.device = handle

        var client: lockdownd_client_t?
        let handshake = lockdownd_client_new_with_handshake(handle, &client, Self.serviceLabel)
        guard handshake == LOCKDOWN_E_SUCCESS, let client else {
            idevice_free(handle)
            self.device = nil
            throw mapLockdownError(handshake.rawValue, udid: udid)
        }
        self.lockdown = client
    }

    deinit {
        if let lockdown { lockdownd_client_free(lockdown) }
        if let device { idevice_free(device) }
    }

    /// Reads a single lockdown value. `domain` nil reads the root domain.
    func value(_ key: String, domain: String? = nil) -> plist_t? {
        guard let lockdown else { return nil }
        var node: plist_t?
        let result = lockdownd_get_value(lockdown, domain, key, &node)
        guard result == LOCKDOWN_E_SUCCESS else { return nil }
        return node
    }

    func stringValue(_ key: String, domain: String? = nil) -> String? {
        guard let node = value(key, domain: domain) else { return nil }
        defer { plist_free(node) }
        return Plist.string(node)
    }

    func intValue(_ key: String, domain: String? = nil) -> Int? {
        guard let node = value(key, domain: domain) else { return nil }
        defer { plist_free(node) }
        return Plist.integer(node)
    }

    func requiredString(_ key: String, domain: String? = nil) throws -> String {
        guard let value = stringValue(key, domain: domain) else {
            throw DeviceError.missingValue(key: key)
        }
        return value
    }

    /// Snapshots everything the Device page needs in one handshake.
    func snapshot(connection: ConnectionKind) throws -> ConnectedDevice {
        ConnectedDevice(
            udid: (try? requiredString("UniqueDeviceID")) ?? udid,
            name: try requiredString("DeviceName"),
            productType: try requiredString("ProductType"),
            iosVersion: try requiredString("ProductVersion"),
            buildVersion: stringValue("BuildVersion") ?? "",
            cpuArchitecture: stringValue("CPUArchitecture"),
            connection: connection,
            batteryPercent: intValue("BatteryCurrentCapacity", domain: "com.apple.mobile.battery")
        )
    }

    /// Starts a named lockdown service and hands back its descriptor.
    /// Only used for services without a `*_client_start_service` convenience wrapper.
    func startService(_ identifier: String) throws -> lockdownd_service_descriptor_t {
        guard let lockdown else { throw DeviceError.lockdownFailed(code: 0) }
        var descriptor: lockdownd_service_descriptor_t?
        let result = lockdownd_start_service(lockdown, identifier, &descriptor)
        guard result == LOCKDOWN_E_SUCCESS, let descriptor else {
            throw DeviceError.serviceUnavailable(name: identifier, code: result.rawValue)
        }
        return descriptor
    }
}
