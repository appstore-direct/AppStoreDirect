import Foundation

/// How the device is reachable. USB is the only mode we act on today, but the
/// lookup flags already distinguish them so network devices can be surfaced later.
public enum ConnectionKind: String, Sendable, Hashable {
    case usb
    case network
}

/// Everything the Device page shows. Built entirely from lockdownd values.
public struct ConnectedDevice: Identifiable, Sendable, Hashable {
    public var id: String { udid }

    public let udid: String
    public let name: String
    /// Raw hardware identifier, e.g. `iPhone8,2`.
    public let productType: String
    /// Human name resolved from `productType`, e.g. `iPhone 6s Plus`.
    public let marketingName: String
    public let iosVersion: String
    public let buildVersion: String
    public let cpuArchitecture: String?
    public let connection: ConnectionKind
    public let batteryPercent: Int?

    public init(
        udid: String,
        name: String,
        productType: String,
        iosVersion: String,
        buildVersion: String,
        cpuArchitecture: String?,
        connection: ConnectionKind,
        batteryPercent: Int?
    ) {
        self.udid = udid
        self.name = name
        self.productType = productType
        self.marketingName = DeviceModelNames.name(for: productType)
        self.iosVersion = iosVersion
        self.buildVersion = buildVersion
        self.cpuArchitecture = cpuArchitecture
        self.connection = connection
        self.batteryPercent = batteryPercent
    }

    /// Parsed `ProductVersion`, used to filter search results the device cannot run.
    public var iosVersionComponents: [Int] {
        iosVersion.split(separator: ".").compactMap { Int($0) }
    }

    /// True when this device satisfies an App Store listing's minimum OS requirement.
    public func canRun(minimumOSVersion: String) -> Bool {
        let required = minimumOSVersion.split(separator: ".").compactMap { Int($0) }
        guard !required.isEmpty else { return true }
        let have = iosVersionComponents
        for index in 0..<max(have.count, required.count) {
            let lhs = index < have.count ? have[index] : 0
            let rhs = index < required.count ? required[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return true
    }
}

/// An app already present on the device, from `instproxy_browse`.
public struct InstalledApp: Identifiable, Sendable, Hashable {
    public var id: String { bundleIdentifier }
    public let bundleIdentifier: String
    public let name: String
    public let version: String
    public let shortVersion: String

    public init(bundleIdentifier: String, name: String, version: String, shortVersion: String) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.version = version
        self.shortVersion = shortVersion
    }
}
