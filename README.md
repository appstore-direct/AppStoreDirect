# AppStoreDirect

A macOS app that installs App Store apps onto a USB-connected iPhone. Search, press
Install, done — no `.ipa` anywhere in the interface.

```
Connect iPhone → Sign in with Apple Account → Search → Install
                                                          │
        Preparing… → Authorizing… → Downloading 45% → Installing 72% → Installed ✓
```

## Requirements

```bash
brew install libimobiledevice ideviceinstaller pkg-config go xcodegen
```

macOS 14+, Xcode 26+. An iPhone connected by USB, unlocked and trusted.

## Build and run

```bash
./Scripts/build-bridge.sh          # build the Go sidecar
xcodegen generate                  # generate AppStoreDirect.xcodeproj
open AppStoreDirect.xcodeproj      # ⌘R
```

## Diagnostics without the GUI

```bash
swift build
./.build/debug/asdctl devices          # full details of attached devices
./.build/debug/asdctl watch            # live USB attach/detach
./.build/debug/asdctl search snapchat  # catalogue search + compatibility verdict
./.build/debug/asdctl installed        # user apps on the device
./.build/debug/asdctl scheduler        # verify install concurrency rules
./.build/debug/asdctl diagnose 932747118   # sign-in, ownership, download authorization
./.build/debug/asdctl authorize 932747118  # licence material, no package transfer
./.build/debug/asdctl acquire  932747118   # download + verify package, then delete
./.build/debug/asdctl install  932747118   # full pipeline to every connected device
```

## Layout

```
Sources/
  CMobileDevice/    C module map — the only place libimobiledevice is imported
  DeviceKit/        detection, lockdown values, AFC upload, installation_proxy
  StoreBridge/      AppStoreService protocol, catalogue search, Keychain, sidecar client
  AppStoreDirectKit/install pipeline: MultiInstallCoordinator, InstallScheduler,
                    per-device job state
  asdctl/           headless harness
App/                SwiftUI application
bridge/             Go sidecar: Apple's private App Store protocol, isolated
third_party/ipatool vendored at a pinned commit (MIT)
docs/               ARCHITECTURE.md, OPEN-QUESTIONS.md
```

## The one thing to understand

Authenticating with the App Store now requires an `X-Apple-ActionSignature` produced
by Apple's SAP v200 protocol, which is implemented inside Apple's closed-source
`CoreFP` framework. There is no public API. The working approach — and what
`ipatool` does — is to fetch Apple's own signing binaries from Apple's CDN and run
them under a CPU emulator.

That is why every line of Apple-protocol code lives in a **separate Go process**
behind `AppStoreService`, a Swift protocol with one method per operation. When Apple
changes the protocol, one conformer changes. No UI, no device code, no persistence.

Read `docs/ARCHITECTURE.md` §1 before touching anything in `bridge/`, and
`docs/OPEN-QUESTIONS.md` for what is proven versus what is merely built.

## Scope

Installs apps the signed-in Apple Account is entitled to: free apps, and paid apps
already in the account's purchase history. Paid apps that have **not** been bought
show "Not Purchased" and cannot be installed — this application never initiates a
financial transaction, and the price guard exists independently in the UI, in the
acquire path, and in the licence-acquisition call. FairPlay
encryption is never touched: the package downloads encrypted and the device decrypts
it with the account's own licence, exactly as Apple Configurator does. No
decryption, no re-signing, no third-party package sources.
