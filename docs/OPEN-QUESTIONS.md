# Verified, unverified, and open

Written 2026-08-29. This file exists so nothing in this project is taken on trust.

## Verified live

| claim | how |
|---|---|
| Bag returns SAP config only for the Configurator User-Agent | fetched `init.itunes.apple.com/bag.xml` with both agents; default agent has no `urlBag` |
| `sign-sap-request` requires a signature on `MZFinance/authenticate` | read from the live bag |
| SAP v200 handshake completes against Apple | ran login; `fpinit.itunes.apple.com` and `s.mzstatic.com/sap/setupCert.plist` both answered, signature accepted, Apple returned a normal credential response in 8.5 s |
| Apple's SAP assets download and cache | 52 MB in `~/Library/Caches/ipatool` after first run: CommerceKit, CommerceCore, CoreFP, CoreFP.icxs, plus the Unicorn runtime |
| Device detection, model/iOS/UDID/battery | read from a connected iPhone 6s Plus, iOS 15.8.7, build 19H411 |
| USB and Wi-Fi transports both enumerate the same device | fixed by deduplicating, preferring USB |
| `instproxy_browse` lists user apps | returned 2 apps from the test device |
| Catalogue search and minimum-iOS filtering | Snapchat compatible (15.0), Instagram correctly flagged (needs 16.3 vs device 15.8.7) |
| The app builds, launches, and shows the live device | screenshotted |

## Now proven end to end

**The full pipeline works.** After the first build was tested with a real Apple
Account, the connected iPhone went from `Shadowrocket + Snapchat 14.17.1` to
`Shadowrocket + Snapchat 14.21.1 + Facebook 576.0.0` — versions matching exactly what
the catalogue search returned. That exercises sign-in with 2FA, SAP request signing,
licence acquisition, `volumeStoreDownloadProduct`, sinf and metadata injection, AFC
upload, and `instproxy_install`, including both a fresh install (Facebook) and an
upgrade in place (Snapchat). iOS 15.8.7 accepts packages acquired this way.

## Paid apps — verified against the real account

Run on 2026-08-29 with the signed-in Apple Account, App Store ID 932747118:

```
App:                    Shadowrocket
Developer:              Shadow Launch Technology Limited
Type:                   Paid          Minimum iOS: 13.0
Ownership:              Purchased
Download authorization: Available     Builds Apple serves: 87
```

* **Ownership detection works.** Apple reports a licence for this account.
* **Acquisition works.** `asdctl acquire 932747118` downloaded 33.9 MB from Apple and
  produced `com.liguangming.Shadowrocket_932747118_2.2.90.ipa` with a 1048-byte sinf
  and 2148-byte iTunesMetadata. No purchase call was made.
* **Per-device authorization works.** `asdctl authorize 932747118` obtained licence
  material twice without transferring the package.
* **Licence material is fresh per authorization** — digests differed across
  successive requests, which is why each device now gets its own.

* **The full pipeline is proven.** `asdctl install 932747118` ran against an
  iPhone 6s Plus on iOS 15.8.6 (UDID `c557e1a4…`): ownership `purchased` → download
  once → per-device authorization → AFC copy → `instproxy` → `Installed ✓`, and
  `asdctl installed` then reported `Shadowrocket 2.2.90
  [com.liguangming.Shadowrocket]` — the exact version acquired.
* **The UI shows the right state.** Searching "shadow" renders Shadowrocket with a
  green `Purchased` badge and an enabled `Install` button, while the free results
  beside it show a plain `Install`.

A cosmetic bug surfaced and was fixed during this run: the first progress sample was
taken before the download's content length was known, rendering as
"Zero KB of 1 byte". Progress is now suppressed until the real size arrives.

## Bugs found by testing, since fixed

* **Keychain I/O on the main actor deadlocked launch.** `KeychainStore.load()` ran
  synchronously during `AppModel.start()`. When the app's code signature changed,
  macOS tried to prompt for Keychain access — but the main thread was blocked inside
  `SecItemCopyMatching`, so the window never appeared and the prompt could never be
  answered. Keychain calls are now async and run off the main actor.
* **Ad-hoc signing re-prompted after every build.** A new signature each build
  invalidates the Keychain ACL. Signing identity is now configurable in
  `Signing.xcconfig`, defaulting to ad-hoc.
* **Device discovery was gated behind session restore.** A plugged-in iPhone showed
  as disconnected until the Keychain prompt was answered. The two now run concurrently.

## Still not executed

**Multi-device installs have only been tested with one phone attached**, because only
one was connected. The scheduler's concurrency rules are verified independently
(`asdctl scheduler`), but the following remain unobserved with real hardware: The code paths are built from
ipatool's current implementation and `ideviceinstaller`'s install sequence, both read
directly rather than recalled, but the following remain untested in this project:

1. **Two or more phones installing at once.** Whether usbmuxd stays healthy with
   several concurrent AFC transfers is the main unknown. Start at a concurrency of 3
   and raise it only if that proves stable.
2. **Package reuse across devices.** The shared-package path is only meaningfully
   exercised with more than one device in a batch.
3. **Per-device Cancel mid-transfer.** Cancellation is checked between phases and by
   `Task.checkCancellation()`; an AFC write already in flight finishes its chunk first.
4. **Hot-unplug during an install.** The job should fail with a device error and be
   retryable once the phone is reconnected — expected, but unobserved.

To test: attach two or more iPhones, Select All on the Devices page, and install one
small free app.

## Known limitations, by design

* **Free apps only.** `buyProduct` is sent with `price=0`. Paid apps already in the
  account's purchase history would work in principle, but the Install button is
  disabled for anything with a non-zero price rather than guessing.
* **The device must run an iOS the app supports.** Older builds can be requested via
  `externalVersionId` — `AppStoreService.availableVersions` is implemented and the
  bridge supports it — but no UI exposes a version picker yet. On this test device
  that matters: iOS 15.8.7 cannot run current builds of many popular apps.
* **App Sandbox is off.** Reaching usbmuxd at `/var/run/usbmuxd` and spawning the
  helper are both incompatible with the sandbox. This rules out Mac App Store
  distribution, as does libimobiledevice's LGPL licence.

## Things to watch

* **First login needs three third-party hosts**, beyond Apple's own:
  `swcdn.apple.com` (Apple's own CDN, for the signing assets) and
  `files.pythonhosted.org` (the Unicorn emulator, shipped as a Python wheel).
  Both are SHA-256 pinned by ipatool — Apple's four binaries by size and digest, the
  Unicorn library by archive and extracted-library digest — so a compromised mirror
  cannot substitute code. Still, an air-gapped or restricted network will fail at
  first sign-in. Consider pre-seeding the cache for offline use.
* **The SAP asset cache lives in `~/Library/Caches/ipatool`**, a path baked into the
  vendored code via `os.UserCacheDir()`. Under an app bundle with a container this
  lands inside the container, which is correct; run from the terminal it does not.
* **ipatool is pinned to a commit, not a tag**, because the SAP work postdates the
  last release. Treat every update as a protocol change and retest sign-in.
* **The declared deployment target is not real yet.** The project targets macOS 14,
  but Homebrew's `libimobiledevice`/`libplist` dylibs on this machine were built for
  macOS 26, and the linker warns about it. As built, the app only runs on the machine
  that built it. Shipping to other Macs means bundling the dylibs into
  `Contents/Frameworks` and rewriting their install names with `install_name_tool`,
  or dropping the deployment target to match. Not done — nothing in this project
  needs it yet, but it will bite the first time the .app is copied elsewhere.
