import AppStoreDirectKit
import Foundation

// Headless harness. Exists so each layer can be exercised against a real device and
// real Apple endpoints without launching the GUI. Not shipped in the .app bundle.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func printUsage() {
    print("""
    asdctl — AppStoreDirect diagnostics

      devices              list attached devices with full details
      watch                stream USB attach/detach events
      search <term> [cc]   search the App Store catalogue (country default US)
      installed [udid]     list user apps on the device
      scheduler [limit] [n] exercise InstallScheduler (default limit 3, 4 devices)
      diagnose <appID>     report sign-in, ownership and download authorization
      authorize <appID>    request licence material twice and compare (no download)
      acquire <appID>      download from Apple, verify the package, then delete it
      install <appID>      full pipeline: acquire once, install to every device
    """)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { printUsage(); exit(0) }

switch command {
case "devices":
    let service = DeviceService()
    let attached = try await service.attachedDevices()
    if attached.isEmpty { print("No devices attached."); exit(0) }
    for entry in attached {
        do {
            let device = try await service.describe(udid: entry.udid, connection: entry.connection)
            print("""
            \(device.name)
              Model        \(device.marketingName)  [\(device.productType)]
              iOS          \(device.iosVersion) (\(device.buildVersion))
              UDID         \(device.udid)
              Architecture \(device.cpuArchitecture ?? "unknown")
              Connection   \(device.connection.rawValue)
              Battery      \(device.batteryPercent.map { "\($0)%" } ?? "unknown")
            """)
        } catch {
            print("\(entry.udid) [\(entry.connection.rawValue)] — \(error.localizedDescription)")
        }
    }

case "watch":
    try DeviceMonitor.shared.start()
    print("Watching for devices. Ctrl-C to stop.")
    for await event in DeviceMonitor.shared.events() {
        switch event {
        case .attached(let udid, let connection): print("+ attached  \(udid) (\(connection.rawValue))")
        case .detached(let udid):                 print("- detached  \(udid)")
        case .paired(let udid):                   print("~ paired    \(udid)")
        }
    }

case "search":
    guard arguments.count >= 2 else { fail("usage: asdctl search <term> [country]") }
    let term = arguments[1]
    let country = arguments.count >= 3 ? arguments[2] : "US"
    let results = try await ITunesCatalog().search(term: term, countryCode: country, limit: 10)
    if results.isEmpty { print("No results."); exit(0) }

    // Compare against the connected device so incompatibility is visible immediately.
    let device = try? await DeviceService().primaryDevice()
    for app in results {
        let compatibility: String
        if let device {
            compatibility = device.canRun(minimumOSVersion: app.minimumOSVersion)
                ? "compatible" : "needs newer iOS"
        } else {
            compatibility = "no device"
        }
        print("""
        \(app.name)  —  \(app.developer)
          bundle \(app.bundleID)   id \(app.appStoreID)
          version \(app.version)   min iOS \(app.minimumOSVersion)   \(compatibility)
          \(app.isFree ? "Free" : "\(app.price) \(app.currency)")
        """)
    }

case "installed":
    let service = DeviceService()
    guard let device = try await (arguments.count >= 2
        ? service.describe(udid: arguments[1])
        : service.primaryDevice())
    else { fail("no device attached") }
    let apps = try await AppInstaller().installedApps(udid: device.udid)
    print("\(apps.count) user apps on \(device.name):")
    for app in apps.sorted(by: { $0.name.lowercased() < $1.name.lowercased() }) {
        print("  \(app.name)  \(app.shortVersion)  [\(app.bundleIdentifier)]")
    }

case "diagnose":
    // Reports exactly what the App Store pipeline knows about one app, using the
    // real signed-in session. Prints no token, cookie, DSID or licence material.
    guard arguments.count >= 2, let appID = Int64(arguments[1]) else {
        fail("usage: asdctl diagnose <appStoreID>    (e.g. 932747118 for Shadowrocket)")
    }

    let keychain = KeychainStore()
    let stored = try? await keychain.load()

    func line(_ label: String, _ value: String) {
        print(label.padding(toLength: 24, withPad: " ", startingAt: 0) + value)
    }

    guard let stored else {
        line("Signed in:", "No")
        print("\nSign in through AppStoreDirect.app first; this reads the same saved session.")
        exit(1)
    }

    line("Signed in:", "Yes")
    line("Apple Account:", stored.account.email)
    line("Storefront:", stored.account.countryCode ?? stored.account.storefront)

    let country = stored.account.countryCode ?? "US"
    let listings = try await ITunesCatalog().lookup(appStoreIDs: [appID], countryCode: country)
    guard let app = listings.first else {
        fail("App Store ID \(appID) was not found in the \(country) storefront.")
    }

    line("App:", app.name)
    line("Developer:", app.developer)
    line("App Store ID:", String(app.appStoreID))
    line("Bundle ID:", app.bundleID)
    line("Type:", app.price > 0 ? "Paid" : "Free")
    line("Minimum iOS:", app.minimumOSVersion.isEmpty ? "unknown" : app.minimumOSVersion)

    let service = try BridgeAppStoreService.locate(cookies: stored.cookies)
    let product = try await service.checkOwnership(of: app, account: stored.account)

    let ownershipText: String
    switch product.ownership {
    case .free:         ownershipText = "Free (no purchase needed)"
    case .purchased:    ownershipText = "Purchased"
    case .notPurchased: ownershipText = "Not Purchased"
    case .unknown:      ownershipText = "Unknown" + (product.detail.map { " — \($0)" } ?? "")
    }
    line("Ownership:", ownershipText)
    line("Download authorization:", product.downloadAuthorized ? "Available" : "Failed")
    if product.availableVersions > 0 {
        line("Builds Apple serves:", String(product.availableVersions))
    }

    // Compatibility against whatever is plugged in right now.
    let attached = try await DeviceService().describeAll()
    if attached.isEmpty {
        line("Compatible with device:", "No device connected")
    } else {
        for device in attached {
            let ok = app.minimumOSVersion.isEmpty || device.canRun(minimumOSVersion: app.minimumOSVersion)
            line("\(device.name) (iOS \(device.iosVersion)):", ok ? "Compatible" : "Needs newer iOS")
        }
    }

    let installable = product.ownership.isInstallable
    let verdict = installable ? "READY" : "BLOCKED"
    let explanation = installable
        ? "this account may install \(app.name)."
        : "this account cannot install \(app.name)."
    print("\n\(verdict) — \(explanation)")

case "authorize":
    // Confirms the per-device authorization path: valid licence material, issued
    // fresh each time, without transferring the package.
    guard arguments.count >= 2, let appID = Int64(arguments[1]) else {
        fail("usage: asdctl authorize <appStoreID>")
    }
    guard let stored = try? await KeychainStore().load() else {
        fail("not signed in — sign in through AppStoreDirect.app first")
    }
    let country = stored.account.countryCode ?? "US"
    guard let app = try await ITunesCatalog().lookup(appStoreIDs: [appID], countryCode: country).first else {
        fail("App Store ID \(appID) not found in the \(country) storefront")
    }
    let service = try BridgeAppStoreService.locate(cookies: stored.cookies)

    var digests: [String] = []
    for attempt in 1...2 {
        let auth = try await service.authorizeDownload(
            app: app, account: stored.account, externalVersionID: nil
        )
        digests.append(shortDigest(auth.sinf))
        print("""
        authorization \(attempt)
          bundle ID   \(auth.bundleID)
          version     \(auth.version)
          sinf        \(auth.sinf.count) bytes   digest \(shortDigest(auth.sinf))
          metadata    \(auth.iTunesMetadata.count) bytes
        """)
    }

    let distinct = digests[0] != digests[1]
    print("""

    Apple issues \(distinct ? "fresh" : "identical") licence material per authorization.
    \(distinct
        ? "Each device therefore gets its own authorization; the package is downloaded once."
        : "One authorization would suffice for every device.")
    """)

case "acquire", "install":
    guard arguments.count >= 2, let appID = Int64(arguments[1]) else {
        fail("usage: asdctl \(command) <appStoreID>")
    }
    let installToDevices = (command == "install")

    let keychain = KeychainStore()
    guard let stored = try? await keychain.load() else {
        fail("not signed in — sign in through AppStoreDirect.app first")
    }
    let country = stored.account.countryCode ?? "US"
    guard let app = try await ITunesCatalog().lookup(appStoreIDs: [appID], countryCode: country).first else {
        fail("App Store ID \(appID) not found in the \(country) storefront")
    }

    let service = try BridgeAppStoreService.locate(cookies: stored.cookies)
    let product = try await service.checkOwnership(of: app, account: stored.account)
    print("\(app.name) — \(app.price > 0 ? "Paid" : "Free"), ownership: \(product.ownership)")
    guard product.ownership.isInstallable else {
        fail("this Apple Account cannot install \(app.name)")
    }

    let devices = try await DeviceService().describeAll()
    if installToDevices && devices.isEmpty {
        fail("no devices connected — use 'acquire' to test the download alone")
    }

    if installToDevices {
        print("installing to \(devices.count) device(s): \(devices.map(\.name).joined(separator: ", "))")
        let scheduler = InstallScheduler(limit: 3)
        let coordinator = MultiInstallCoordinator(store: service, scheduler: scheduler)
        let reporter = StateReporter()
        await coordinator.start(app: app, account: stored.account, devices: devices) { udid, state in
            Task { await reporter.record(udid: udid, state: state) }
        }
        // Poll until every device reaches a terminal state.
        while await !reporter.isFinished(expected: devices.count) {
            try? await Task.sleep(for: .milliseconds(400))
        }
        await reporter.printSummary(devices: devices)
    } else {
        // Acquisition only: proves the paid download path without touching a phone.
        let directory = InstallCoordinator.defaultCacheDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        print("downloading from Apple…")
        let package = try await service.acquire(
            app: app, account: stored.account, externalVersionID: nil, into: directory
        ) { phase in
            if case .downloading(let fraction, _, let expected) = phase, expected > 0 {
                let percent = Int(fraction * 100)
                if percent % 20 == 0 { print("  \(percent)%") }
            }
        }
        defer { try? FileManager.default.removeItem(at: package.url) }

        let formatter = ByteCountFormatter()
        print("""

        package      \(package.url.lastPathComponent)
        bundle ID    \(package.bundleID)
        version      \(package.version)
        size         \(formatter.string(fromByteCount: package.byteCount))
        sinf         \(package.sinf.count) bytes
        metadata     \(package.iTunesMetadata.count) bytes
        sinf digest  \(shortDigest(package.sinf))
        """)

        let valid = package.byteCount > 0 && !package.sinf.isEmpty
            && !package.iTunesMetadata.isEmpty && !package.bundleID.isEmpty
        print("\n\(valid ? "PASS" : "FAIL") — package \(valid ? "is installable" : "is incomplete")")
        if !valid { exit(1) }
    }

case "scheduler":
    // Verifies the two invariants that make multi-device installs safe:
    // the global cap is never exceeded, and one device never runs two jobs at once.
    let limit = arguments.count >= 2 ? (Int(arguments[1]) ?? 3) : 3
    let deviceCount = arguments.count >= 3 ? (Int(arguments[2]) ?? 4) : 4
    let scheduler = InstallScheduler(limit: limit)
    let tracker = ConcurrencyTracker()

    // Two jobs per device, so per-device exclusivity is actually exercised.
    var jobs: [(String, Int)] = []
    for index in 0..<deviceCount {
        let udid = String(format: "device-%02d", index + 1)
        jobs.append((udid, 120))
        jobs.append((udid, 60))
    }

    let started = Date()
    await withTaskGroup(of: Void.self) { group in
        for (udid, milliseconds) in jobs {
            group.addTask {
                await scheduler.withSlot(udid: udid) {
                    await tracker.enter(udid)
                    try? await Task.sleep(for: .milliseconds(milliseconds))
                    await tracker.leave(udid)
                }
            }
        }
    }
    let elapsed = Date().timeIntervalSince(started)

    let peak = await tracker.peakConcurrent
    let overlaps = await tracker.sameDeviceOverlaps
    let completed = await tracker.completed

    print("jobs completed      \(completed) / \(jobs.count)")
    print("configured limit    \(limit)")
    print("peak concurrent     \(peak)")
    print("same-device overlap \(overlaps)")
    print(String(format: "elapsed             %.2fs", elapsed))

    var failures: [String] = []
    if completed != jobs.count { failures.append("not all jobs ran (deadlock?)") }
    if peak > limit { failures.append("exceeded the concurrency cap") }
    if overlaps > 0 { failures.append("ran two jobs on one device at once") }
    if failures.isEmpty {
        print("\nPASS — cap respected, per-device exclusivity held, no deadlock")
    } else {
        for failure in failures { print("FAIL — \(failure)") }
        exit(1)
    }

default:
    printUsage()
}

/// Records peak concurrency and any same-device overlap during the scheduler test.
actor ConcurrencyTracker {
    private var active: [String: Int] = [:]
    private var current = 0
    private(set) var peakConcurrent = 0
    private(set) var sameDeviceOverlaps = 0
    private(set) var completed = 0

    func enter(_ udid: String) {
        current += 1
        peakConcurrent = max(peakConcurrent, current)
        let count = (active[udid] ?? 0) + 1
        active[udid] = count
        if count > 1 { sameDeviceOverlaps += 1 }
    }

    func leave(_ udid: String) {
        current -= 1
        active[udid] = (active[udid] ?? 1) - 1
        completed += 1
    }
}


/// Short, non-reversible fingerprint of licence material, so two acquisitions can be
/// compared without ever printing the licence itself.
func shortDigest(_ data: Data) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in data {
        hash ^= UInt64(byte)
        hash = hash &* 0x100000001b3
    }
    return String(format: "%016llx", hash)
}

/// Collects per-device states during a headless install.
actor StateReporter {
    private var states: [String: DeviceInstallState] = [:]
    private var lastPrinted: [String: String] = [:]

    func record(udid: String, state: DeviceInstallState) {
        states[udid] = state
        let short = state.shortLabel
        if lastPrinted[udid] != short {
            lastPrinted[udid] = short
            print("  \(udid.prefix(8))…  \(state.label)")
        }
    }

    func isFinished(expected: Int) -> Bool {
        states.count >= expected && states.values.allSatisfy { !$0.isActive }
    }

    func printSummary(devices: [ConnectedDevice]) {
        print("")
        var failed = false
        for device in devices {
            let state = states[device.udid] ?? .idle
            print("  \(device.name): \(state.label)")
            if state.isFailure { failed = true }
        }
        print("\n\(failed ? "FAIL" : "PASS")")
    }
}
