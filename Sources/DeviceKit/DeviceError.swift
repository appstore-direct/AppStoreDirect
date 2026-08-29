import CMobileDevice
import Foundation

/// Errors crossing the libimobiledevice boundary, mapped to messages the UI can show.
public enum DeviceError: Error, LocalizedError, Sendable {
    case noDeviceConnected
    case deviceUnavailable(udid: String, code: Int32)
    /// The phone is locked, or "Trust This Computer" has not been accepted.
    case pairingRequired(udid: String)
    case lockdownFailed(code: Int32)
    case serviceUnavailable(name: String, code: Int32)
    case missingValue(key: String)
    case fileTransferFailed(path: String, code: Int32)
    case installationFailed(name: String, description: String, code: UInt64)
    case packageMalformed(reason: String)

    public var errorDescription: String? {
        switch self {
        case .noDeviceConnected:
            return "No iPhone is connected."
        case .deviceUnavailable(let udid, let code):
            return "Could not open device \(udid) (error \(code))."
        case .pairingRequired(let udid):
            return "Unlock \(udid) and tap Trust This Computer, then try again."
        case .lockdownFailed(let code):
            return "The device refused the lockdown handshake (error \(code))."
        case .serviceUnavailable(let name, let code):
            return "Could not start \(name) on the device (error \(code))."
        case .missingValue(let key):
            return "The device did not report \(key)."
        case .fileTransferFailed(let path, let code):
            return "Failed to copy the package to the device at \(path) (error \(code))."
        case .installationFailed(let name, let description, let code):
            return "\(name): \(description) (code \(code))"
        case .packageMalformed(let reason):
            return "The downloaded package is not installable: \(reason)"
        }
    }
}

// libimobiledevice's `lockdownd_client_new_with_handshake` returns these when the
// device is locked or the pairing record was rejected. They are the single most
// common failure users hit, so they get their own error case.
private let lockdownPasswordProtected: Int32 = -17
private let lockdownPairingDialogPending: Int32 = -20
private let lockdownInvalidHostID: Int32 = -21
private let lockdownUserDeniedPairing: Int32 = -19

func mapLockdownError(_ code: Int32, udid: String) -> DeviceError {
    switch code {
    case lockdownPasswordProtected, lockdownPairingDialogPending,
         lockdownInvalidHostID, lockdownUserDeniedPairing:
        return .pairingRequired(udid: udid)
    default:
        return .lockdownFailed(code: code)
    }
}
