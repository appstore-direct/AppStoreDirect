import CMobileDevice
import Foundation

/// Enumeration and description of connected devices.
///
/// An actor because every call opens a lockdown session, and doing several of those
/// concurrently against the same phone reliably produces handshake errors.
public actor DeviceService {
    public init() {}

    /// UDIDs currently visible to usbmuxd, with how each is reachable.
    public func attachedDevices() throws -> [(udid: String, connection: ConnectionKind)] {
        var list: UnsafeMutablePointer<idevice_info_t?>?
        var count: Int32 = 0

        let result = idevice_get_device_list_extended(&list, &count)
        guard result == IDEVICE_E_SUCCESS, let list else {
            // An empty bus is not an error worth throwing for.
            if result == IDEVICE_E_NO_DEVICE { return [] }
            throw DeviceError.deviceUnavailable(udid: "*", code: result.rawValue)
        }
        defer { idevice_device_list_extended_free(list) }

        // A device on Wi-Fi sync appears twice: once per transport. Collapse to one
        // entry per UDID and keep USB, which is the transport this app acts on.
        var byUDID: [String: ConnectionKind] = [:]
        var order: [String] = []
        for index in 0..<Int(count) {
            guard let info = list[index], let rawUDID = info.pointee.udid else { continue }
            let udid = String(cString: rawUDID)
            let connection: ConnectionKind =
                info.pointee.conn_type == CONNECTION_NETWORK ? .network : .usb
            if byUDID[udid] == nil { order.append(udid) }
            if byUDID[udid] != .usb { byUDID[udid] = connection }
        }
        return order.compactMap { udid in
            byUDID[udid].map { (udid: udid, connection: $0) }
        }
    }

    /// Full description of one device. Requires the phone to be unlocked and trusted.
    public func describe(udid: String, connection: ConnectionKind = .usb) throws -> ConnectedDevice {
        let session = try DeviceSession(
            udid: udid,
            options: connection == .network ? IDEVICE_LOOKUP_NETWORK : IDEVICE_LOOKUP_USBMUX
        )
        return try session.snapshot(connection: connection)
    }

    /// Describes every attached device, skipping any that cannot be reached right
    /// now (locked, mid-reboot, untrusted) rather than failing the whole refresh.
    public func describeAll() throws -> [ConnectedDevice] {
        try attachedDevices().compactMap { entry in
            try? describe(udid: entry.udid, connection: entry.connection)
        }
    }

    /// The USB device we act on. USB is preferred over network per the product spec.
    public func primaryDevice() throws -> ConnectedDevice? {
        let attached = try attachedDevices()
        for entry in attached.sorted(by: { $0.connection == .usb && $1.connection != .usb }) {
            if let device = try? describe(udid: entry.udid, connection: entry.connection) {
                return device
            }
        }
        return nil
    }
}
