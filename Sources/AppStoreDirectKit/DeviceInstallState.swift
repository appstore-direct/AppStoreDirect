import DeviceKit
import Foundation
import StoreBridge

/// Identifies one unit of work: this app, onto this device.
public struct InstallJobKey: Hashable, Sendable {
    public let appStoreID: Int64
    public let udid: String

    public init(appStoreID: Int64, udid: String) {
        self.appStoreID = appStoreID
        self.udid = udid
    }
}

/// State of one app's installation on one device.
///
/// The first three cases describe work shared by every device in a batch — the
/// package is acquired from Apple once — so all queued devices report the same
/// download progress. From `transferring` onwards each device moves independently.
public enum DeviceInstallState: Sendable, Equatable {
    case idle
    case queued
    case preparing
    case authorizing
    case downloading(fraction: Double, detail: String)
    case transferring(fraction: Double)
    case installing(fraction: Double)
    case installed
    case failed(message: String)
    case cancelled
    /// Excluded before any work started, because this device cannot run the app.
    case incompatible(reason: String)

    public var label: String {
        switch self {
        case .idle:                     return ""
        case .queued:                   return "Queued"
        case .preparing:                return "Preparing…"
        case .authorizing:              return "Authorizing with App Store…"
        case .downloading(let f, let d):
            let percent = "Downloading from Apple… \(Int(f * 100))%"
            return d.isEmpty ? percent : "\(percent)  (\(d))"
        case .transferring(let f):      return "Copying to iPhone… \(Int(f * 100))%"
        case .installing(let f):        return "Installing… \(Int(f * 100))%"
        case .installed:                return "Installed ✓"
        case .failed(let message):      return message
        case .cancelled:                return "Cancelled"
        case .incompatible(let reason): return reason
        }
    }

    /// Short word for compact per-device rows and count summaries.
    public var shortLabel: String {
        switch self {
        case .idle:          return "Idle"
        case .queued:        return "Queued"
        case .preparing, .authorizing: return "Preparing"
        case .downloading:   return "Downloading"
        case .transferring:  return "Copying"
        case .installing:    return "Installing"
        case .installed:     return "Installed"
        case .failed:        return "Failed"
        case .cancelled:     return "Cancelled"
        case .incompatible:  return "Unsupported"
        }
    }

    /// True while the job still occupies a slot.
    public var isActive: Bool {
        switch self {
        case .queued, .preparing, .authorizing, .downloading, .transferring, .installing:
            return true
        case .idle, .installed, .failed, .cancelled, .incompatible:
            return false
        }
    }

    public var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    /// Whether a Retry button should be offered.
    public var isRetryable: Bool {
        switch self {
        case .failed, .cancelled: return true
        default: return false
        }
    }

    /// 0–1 for a determinate bar. Download is weighted at 70% of the whole because
    /// it dominates wall-clock time; the two device phases share the remainder.
    public var fraction: Double? {
        switch self {
        case .queued:                return 0
        case .preparing, .authorizing: return 0.02
        case .downloading(let f, _): return 0.02 + f * 0.68
        case .transferring(let f):   return 0.70 + f * 0.20
        case .installing(let f):     return 0.90 + f * 0.10
        case .installed:             return 1
        case .idle, .failed, .cancelled, .incompatible: return nil
        }
    }
}

/// One device's slice of a batch, as rendered in the UI.
public struct PerDeviceInstallJob: Identifiable, Sendable, Equatable {
    public var id: InstallJobKey { key }

    public let key: InstallJobKey
    public let deviceName: String
    public let deviceModel: String
    public let iosVersion: String
    public var state: DeviceInstallState

    public init(
        key: InstallJobKey,
        deviceName: String,
        deviceModel: String,
        iosVersion: String,
        state: DeviceInstallState
    ) {
        self.key = key
        self.deviceName = deviceName
        self.deviceModel = deviceModel
        self.iosVersion = iosVersion
        self.state = state
    }

    public init(app: StoreApp, device: ConnectedDevice, state: DeviceInstallState) {
        self.init(
            key: InstallJobKey(appStoreID: app.appStoreID, udid: device.udid),
            deviceName: device.name,
            deviceModel: device.marketingName,
            iosVersion: device.iosVersion,
            state: state
        )
    }
}

/// Counts across a set of jobs, for the bulk progress summary.
public struct InstallSummary: Sendable, Equatable {
    public var queued = 0
    public var working = 0
    public var installed = 0
    public var failed = 0
    public var cancelled = 0
    public var incompatible = 0

    public var total: Int { queued + working + installed + failed + cancelled + incompatible }
    public var hasActivity: Bool { queued + working > 0 }
    public var hasFailures: Bool { failed > 0 }

    public init() {}

    public init(_ states: some Sequence<DeviceInstallState>) {
        for state in states {
            switch state {
            case .queued:                       queued += 1
            case .preparing, .authorizing, .downloading, .transferring, .installing:
                                                working += 1
            case .installed:                    installed += 1
            case .failed:                       failed += 1
            case .cancelled:                    cancelled += 1
            case .incompatible:                 incompatible += 1
            case .idle:                         break
            }
        }
    }

    /// "12 queued · 5 installing · 2 failed · 1 installed", omitting empty parts.
    public var description: String {
        var parts: [String] = []
        if queued > 0       { parts.append("\(queued) queued") }
        if working > 0      { parts.append("\(working) installing") }
        if failed > 0       { parts.append("\(failed) failed") }
        if installed > 0    { parts.append("\(installed) installed") }
        if cancelled > 0    { parts.append("\(cancelled) cancelled") }
        if incompatible > 0 { parts.append("\(incompatible) unsupported") }
        return parts.joined(separator: " · ")
    }
}
