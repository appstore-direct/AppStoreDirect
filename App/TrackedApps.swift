import AppKit
import AppStoreDirectKit
import Observation
import SwiftUI

/// Apps whose presence is shown as a badge on each device in the Devices tab.
///
/// Deliberately a small fixed list rather than "every installed app": the badges are
/// a fleet-status glance, not an inventory. The Installed tab already lists
/// everything on a device.
struct TrackedApp: Identifiable, Hashable, Sendable {
    var id: Int64 { appStoreID }
    let appStoreID: Int64
    let bundleID: String
    let name: String

    static let snapchat = TrackedApp(
        appStoreID: 447188370,
        bundleID: "com.toyopagroup.picaboo",
        name: "Snapchat"
    )

    static let shadowrocket = TrackedApp(
        appStoreID: 932747118,
        bundleID: "com.liguangming.Shadowrocket",
        name: "Shadowrocket"
    )

    static let all: [TrackedApp] = [.snapchat, .shadowrocket]
}

/// Fetches and caches the official App Store artwork for the tracked apps.
///
/// Artwork URLs come from the same public catalogue lookup the search page uses, so
/// there is no second source of truth for app metadata. Images are cached in memory
/// for the session and on disk across launches, so the icons are fetched once rather
/// than on every Devices-tab refresh.
@MainActor
@Observable
final class TrackedAppIconStore {
    private(set) var icons: [Int64: NSImage] = [:]
    private var isLoading = false

    private let catalog = ITunesCatalog()

    private static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("com.appstoredirect.mac", isDirectory: true)
            .appendingPathComponent("Icons", isDirectory: true)
    }

    func icon(for app: TrackedApp) -> NSImage? {
        icons[app.appStoreID]
    }

    /// Loads every tracked icon, preferring the on-disk cache. Safe to call repeatedly.
    func load(countryCode: String) async {
        guard !isLoading else { return }
        guard icons.count < TrackedApp.all.count else { return }
        isLoading = true
        defer { isLoading = false }

        let directory = Self.cacheDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Disk cache first — this is the common path after the first launch.
        var missing: [TrackedApp] = []
        for app in TrackedApp.all where icons[app.appStoreID] == nil {
            let file = directory.appendingPathComponent("\(app.appStoreID).png")
            if let data = try? Data(contentsOf: file), let image = NSImage(data: data) {
                icons[app.appStoreID] = image
            } else {
                missing.append(app)
            }
        }
        guard !missing.isEmpty else { return }

        // One catalogue lookup covers every missing icon.
        guard let listings = try? await catalog.lookup(
            appStoreIDs: missing.map(\.appStoreID),
            countryCode: countryCode
        ) else { return }

        for listing in listings {
            guard let url = listing.iconURL else { continue }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = NSImage(data: data) else { continue }

            icons[listing.appStoreID] = image
            // Store the bytes Apple served rather than a re-encode, so the cached
            // file is exactly what was downloaded.
            try? data.write(
                to: directory.appendingPathComponent("\(listing.appStoreID).png"),
                options: .atomic
            )
        }
    }
}
