// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppStoreDirectKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AppStoreDirectKit", targets: ["AppStoreDirectKit"]),
        .executable(name: "asdctl", targets: ["asdctl"]),
    ],
    targets: [
        // Thin C shim over libimobiledevice / libplist. Everything Apple-device
        // related crosses this boundary and nowhere else.
        //
        // Resolved through pkg-config rather than hardcoded Homebrew paths, so the
        // same manifest works for an Intel Mac (/usr/local) and under Xcode, which
        // does not inherit the app project's header search paths.
        .systemLibrary(
            name: "CMobileDevice",
            path: "Sources/CMobileDevice",
            pkgConfig: "libimobiledevice-1.0",
            providers: [.brew(["libimobiledevice"])]
        ),

        .target(name: "DeviceKit", dependencies: ["CMobileDevice"]),

        // The replaceable Apple-protocol seam.
        .target(name: "StoreBridge"),

        .target(name: "AppStoreDirectKit", dependencies: ["DeviceKit", "StoreBridge"]),

        // Headless harness used to verify each layer against real hardware
        // and real Apple endpoints without launching the GUI.
        .executableTarget(name: "asdctl", dependencies: ["AppStoreDirectKit"]),
    ]
)
