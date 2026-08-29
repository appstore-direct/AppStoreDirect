# AppStoreDirect — Architecture

A macOS SwiftUI app that installs App Store apps onto a USB-connected iPhone.
The user searches, presses **Install**, and the app does acquisition, download and
device installation internally. `.ipa` never appears in the UI.

All findings below were verified live on 2026-08-29 against Apple's endpoints and
against a physically connected iPhone (iPhone8,2 / iOS 15.8.7), not recalled from
memory. Where something is still unverified it is called out explicitly in
`docs/OPEN-QUESTIONS.md`.

---

## 1. How the App Store flow actually works today

### 1.1 The bag (endpoint discovery)

Everything starts at the **bag**, Apple's runtime endpoint directory:

    GET https://init.itunes.apple.com/bag.xml?guid=<GUID>

`GUID` is the machine's primary MAC address, uppercase, colons stripped
(e.g. `6691144B6870`).

**Critical, verified detail:** the bag's contents depend on the `User-Agent`.
With a default agent, Apple returns a bag with *no* `urlBag` dictionary and no SAP
keys. With the Configurator agent:

    Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6

Apple returns a `urlBag` (36 entries) containing, as observed today:

| key | value |
|---|---|
| `authenticateAccount` | `https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate` |
| `sign-sap-setup` | `https://fpinit.itunes.apple.com/v1/signSapSetup/legacy` |
| `sign-sap-setup-cert` | `https://s.mzstatic.com/sap/setupCert.plist` |
| `sign-sap-version` | `200` |
| `buyProduct` | `https://buy.itunes.apple.com/WebObjects/MZBuy.woa/wa/buyProduct` |
| `volumeStoreDownloadProduct` | `https://downloaddispatch.itunes.apple.com/WebObjects/DownloadDispatch.woa/wa/ent/download` |

Endpoints are **read from the bag at runtime**, never hardcoded. This is the single
most important resilience property: when Apple moves an endpoint, the bag moves with it.

### 1.2 SAP — the part that makes this hard

The bag also returns `sign-sap-request`, a map of which WebObjects actions require a
signature. Verified today it contains:

    'MZFinance': ['authenticate']

So **authentication must carry an `X-Apple-ActionSignature` header**, produced by
Apple's *Secure Association Protocol* (SAP) version 200. Without a valid signature
the authenticate call fails. This is why old open-source App Store clients that just
POST a username and password no longer work.

SAP setup is a two-message handshake against Apple, but the messages themselves must
be produced by Apple's own FairPlay client code:

1. `GET  sign-sap-setup-cert`  → plist, key `sign-sap-setup-cert` → certificate bytes
2. Feed the certificate into the FairPlay client, which emits a setup request blob
3. `POST sign-sap-setup` with plist `{ "sign-sap-setup-buffer": <blob> }`
4. Feed Apple's reply back into the client → handshake completes
5. The initialised context can now `Sign(body)` → the `X-Apple-ActionSignature` value

Step 2/4/5 are the problem: they are implemented inside Apple's closed-source
`CoreFP.framework`. There is no public API and no documented algorithm.

**How this is solved in practice (verified in ipatool HEAD, commit `a53550f`, dated
today):** ipatool range-downloads a legitimate Apple software update package from
Apple's CDN —

    https://swcdn.apple.com/content/downloads/27/34/041-98128-A_SYPWICN3KH/.../OSXUpd10.9.pkg

— reads the XAR container over HTTP range requests, seeks to a known bzip2 offset in
`Payload`, walks the CPIO archive, and extracts four x86_64 Mach-O binaries, each
pinned by exact size and SHA-256:

| file | size | purpose |
|---|---|---|
| `CommerceKit` | 3,271,840 | SAP entry points |
| `CommerceCore` | 207,744 | supporting symbols |
| `CoreFP` | 29,014,912 | the FairPlay implementation |
| `CoreFP.icxs` | 5,288,352 | CoreFP data segment |

It then runs those binaries under a **Unicorn CPU emulator** with a hand-written
Mach-O loader and ~1,250 lines of libSystem/platform shims
(`internal/sap/machine/`), calling `Initialize`, `Exchange` and `Sign` on the
emulated code. Assets are cached on disk after first fetch.

This is emulation of Apple's *own signing client*, using code Apple publishes.
It is not a DRM bypass: FairPlay encryption on the app binary is untouched, and the
signature only proves "a genuine client made this request".

**Architectural consequence.** Reimplementing that in Swift means porting a CPU
emulator, a Mach-O loader and a libSystem shim layer. That is the wrong place to spend
effort and the wrong thing to own. `AppStoreDirect` therefore isolates the entire
Apple protocol into a **separate Go sidecar process** built from ipatool's MIT-licensed
packages. See §3.

### 1.3 Authentication

    POST <bag.authenticateAccount>
    User-Agent: Configurator/2.17 ...
    X-Apple-ActionSignature: base64(SAP signature over the body)
    Content-Type: application/x-www-form-urlencoded
    body: XML plist { appleId, password, attempt, guid, rmp:"0", why:"signIn" }

Behaviours that must be handled:

* **2FA.** The 6-digit code is *appended to the password string* — there is no separate
  field. If no code was supplied and Apple replies with `customerMessage` =
  `MZFinance.BadLogin.Configurator_message` and an empty `failureType`, that means
  "2FA code required" — prompt, then retry with `password + code`.
* **First attempt lies.** `failureType == "-5000"` on attempt 1 is expected; retry with
  `attempt=2`.
* **Pod redirect.** A `302` returns a `p<N>-buy.itunes.apple.com` location. Follow it,
  but reset `attempt` back to 1 — Apple expects the original body.
* Response yields `passwordToken`, `dsPersonId`, the `X-Set-Apple-Store-Front` header
  (storefront, e.g. `143441-1,29`) and an optional `pod` header. These four are the
  session. The password itself is *not* needed again.

### 1.4 Licence acquisition ("purchase")

    POST https://[p<pod>-]buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/buyProduct
    X-Dsid / iCloud-DSID: <dsPersonId>
    X-Token: <passwordToken>
    X-Apple-Store-Front: <storefront>
    body: plist { salableAdamId, pricingParameters: "STDQ", price:"0", productType:"C", ... }

Only free apps. `pricingParameters` is `STDQ` for normal apps, `GAME` for Apple Arcade
(retry with `GAME` if the first attempt returns `2059 temporarily unavailable`).
`failureType 5002` = licence already exists = success for our purposes.
**No SAP signature required here** — the bag's `sign-sap-request` does not list `MZBuy`.

### 1.5 Download

    POST https://[p<pod>-]buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct?guid=<GUID>
    body: plist { salableAdamId, guid, creditDisplay:"", serialNumber:"0", [externalVersionId] }

Returns `songList[0]` with:

* `URL` — a plain HTTPS URL to the encrypted `.ipa` on Apple's CDN
* `sinfs[]` — the per-account FairPlay licence blobs
* `metadata` — the dict that becomes `iTunesMetadata.plist`

`failureType 9610` = no licence → run §1.4 first. `2034`/`2042`/`1008` = session
expired → re-authenticate.

The downloaded archive is **not installable as-is**. Two things must be injected:

1. `iTunesMetadata.plist` at the archive root (`metadata` + `apple-id`/`userName`)
2. The sinf at `Payload/<App>.app/SC_Info/<executable>.sinf`
   (or, when `SC_Info/Manifest.plist` exists, at each path in its `SinfPaths` array)

`externalVersionId` is how older versions are requested — directly relevant here, since
the test device runs iOS 15.8.7 and current builds of most apps require iOS 16+.

### 1.6 Search

Search is the **public** iTunes Search API — no authentication, no SAP:

    GET https://itunes.apple.com/search?term=…&country=<cc>&entity=software&limit=…

The country code is derived from the signed-in storefront ID, so results match what
the account can actually install. This is implemented natively in Swift; it does not
need the sidecar.

---

## 2. Installing onto the device

Verified against `ideviceinstaller` 1.2.0 source and libimobiledevice 1.4.0 headers,
both installed locally.

1. `idevice_new_with_options(&dev, udid, IDEVICE_LOOKUP_USBMUX)`
2. `lockdownd_client_new_with_handshake` → pairs / validates trust
3. Read the sinf and `iTunesMetadata.plist` back out of the finished archive
4. `afc_client_start_service` → upload the archive to `PublicStaging/<bundleID>`
   in 1 MiB chunks (this is the "Installing… %" the user sees, first half)
5. Build `instproxy_client_options_new()` with:
   * `CFBundleIdentifier` = the app's bundle ID
   * `ApplicationSINF` = sinf bytes (`plist_new_data`)
   * `iTunesMetadata` = metadata bytes (`plist_new_data`)
   * `PackageType` is **omitted** — it is only set for `Developer`/`CarrierBundle`
6. `instproxy_install(client, "PublicStaging/<bundleID>", opts, status_cb, ctx)`;
   `status_cb` reports `PercentComplete` and terminal `Status`/`Error`

This is the same mechanism Apple Configurator uses. The app binary stays FairPlay-
encrypted throughout; the device decrypts it using the sinf we hand it, which is why
the sinf must match the signed-in Apple Account.

Installed-app enumeration for the **Installed** page uses
`instproxy_browse` with `ApplicationType = User`.

Hotplug detection uses `idevice_events_subscribe(&ctx, cb, user_data)`, which fires
`IDEVICE_DEVICE_ADD` / `IDEVICE_DEVICE_REMOVE`.

---

## 3. Component architecture

```
┌──────────────────────────── AppStoreDirect.app ────────────────────────────┐
│                                                                            │
│  SwiftUI  ─ Apps · Installed · Device · Settings                           │
│     │                                                                      │
│  InstallCoordinator ── drives the state machine the user sees:             │
│     │   preparing → authorizing → downloading → installing → installed    │
│     │                                                                      │
│     ├── DeviceKit  (Swift ⟷ C)                                            │
│     │      DeviceMonitor · DeviceInfo · AppInstaller                       │
│     │      links libimobiledevice / libplist directly                      │
│     │                                                                      │
│     ├── KeychainStore  (Security.framework)                                │
│     │      session tokens + cookies, kSecAttrAccessibleWhenUnlocked        │
│     │                                                                      │
│     ├── ITunesCatalog  (URLSession)                                        │
│     │      public search API — no credentials                              │
│     │                                                                      │
│     └── AppStoreService  ◀── protocol boundary, the replaceable seam       │
│              │                                                             │
│              └── BridgeAppStoreService ──stdio NDJSON──┐                   │
└────────────────────────────────────────────────────────┼───────────────────┘
                                                         │
                    ┌────────────────────────────────────▼──────────────────┐
                    │  appstore-bridge  (Go, sidecar process)               │
                    │    bag · SAP handshake · authenticate · buyProduct    │
                    │    · volumeStoreDownloadProduct · sinf injection      │
                    │  built from ipatool pkg/appstore + internal/sap (MIT) │
                    └───────────────────────────────────────────────────────┘
```

### Why a sidecar and not a Swift port

* The SAP signer needs a CPU emulator running Apple's binaries. Porting it to Swift is
  weeks of work and a permanent maintenance burden for zero user-visible benefit.
* Apple changes these endpoints regularly. Tracking upstream ipatool is a `go get`.
* Crash isolation: the emulator does aggressive things with memory. If it faults, the
  sidecar dies and the SwiftUI app shows an error instead of crashing.
* The protocol boundary is one Swift file (`AppStoreService.swift`). Replacing the
  whole Apple implementation means writing one new conformer.

### Trust boundary

The sidecar is a **child process, not a service**: no network listener, no port, stdin
and stdout pipes only. It is spawned on demand, holds session state in memory for the
life of one operation, and is terminated when idle. It never writes credentials to
disk — persistence is the Swift side's job, in the Keychain.

---

## 4. Security design

| concern | decision |
|---|---|
| Apple password | held only in memory, only for the duration of one login call; never written to disk, never in a log, never sent to the sidecar's argv (passed over stdin) |
| session (`passwordToken`, `dsPersonId`, storefront, pod) | macOS Keychain, one generic-password item, `kSecAttrAccessibleWhenUnlocked` |
| cookies | returned by the sidecar as an opaque blob, stored in the same Keychain item, replayed on next launch — so the user is not asked to sign in every launch |
| 2FA | modelled as a first-class result (`.needsTwoFactorCode`), not an error string |
| logging | a redacting logger: `password`, `X-Token`, `X-Apple-ActionSignature`, `Cookie`, `Set-Cookie`, `passwordToken`, `dsPersonId` and sinf bytes are dropped before formatting, in both Swift and Go |
| temp packages | app cache dir, `0600`, deleted after successful install; retained only on failure for retry, and swept on next launch |
| DRM | untouched. No decryption, no re-signing, no patching. Only apps the signed-in account is entitled to. |

---

## 5. Frameworks and libraries

**Apple, first-party**

* SwiftUI, Observation, AppKit shims — UI
* Foundation / URLSession — public catalogue, artwork
* Security.framework — Keychain
* `Process`/`Pipe` — sidecar transport
* Swift/C interop via a `systemLibrary` module map

**Third-party, all MIT/LGPL and already installed via Homebrew**

* `libimobiledevice` 1.4.0 (LGPL-2.1) — lockdown, AFC, installation_proxy
* `libplist` 2.7.0 (LGPL-2.1) — plist encode/decode at the C boundary
* `libusbmuxd` 2.1.1, `libimobiledevice-glue` 1.3.2 — transport
* `ipatool` (MIT, Majd Alfhaily) — vendored into the Go sidecar

Note the LGPL: libimobiledevice must be **dynamically linked** (it is, via Homebrew
dylibs) and the app cannot be Mac App Store distributed. That is fine for this use case
but is recorded here because it constrains distribution.

---

## 6. What is reusable from ipatool

| ipatool | use here |
|---|---|
| `internal/sap/**` | **vendored wholesale.** Do not attempt to reimplement. |
| `pkg/appstore/appstore_bag.go` | vendored — bag parse + endpoint validation |
| `pkg/appstore/appstore_login.go` | vendored — retry/pod/2FA logic is subtle and hard-won |
| `pkg/appstore/appstore_purchase.go` | vendored — STDQ/GAME fallback |
| `pkg/appstore/appstore_download.go` | vendored — but our sidecar streams progress as NDJSON instead of a terminal progress bar |
| `pkg/appstore/appstore_replicate_sinf.go` | vendored — Manifest.plist vs Info.plist sinf placement |
| `pkg/appstore/appstore_search.go` | **not used** — reimplemented natively in Swift; it is just the public API |
| `pkg/keychain/**` | **not used** — replaced by a no-op in-memory shim; Swift owns the Keychain |
| `cmd/**` (cobra CLI) | **not used** — replaced by the NDJSON RPC loop |

`Keychain`, `Machine`, `OperatingSystem`, `CookieJar` and `ActionSignerFactory` are all
interfaces in `appstore.Args`, so the sidecar substitutes its own implementations
without forking ipatool.

---

## 6a. Multi-device installs

One app, many phones. The design turns on a single fact: **a licence and its sinf
belong to the Apple Account, not to a device.** One acquired package therefore
installs to every selected phone, so a batch downloads from Apple exactly once.

```
Install pressed
      │
      ├─ per device: compatibility check ──▶ .incompatible (never downloaded)
      │
      ▼
MultiInstallCoordinator
      │
      ├── acquire ONCE ─────────────▶ shared package in cache
      │     (all queued devices show the same download progress)
      │
      └── fan out, admitted by InstallScheduler
            ├─ device A ─ AFC copy ─ instproxy ─▶ .installed
            ├─ device B ─ AFC copy ─ instproxy ─▶ .failed  → Retry reuses the package
            └─ device C ─ …
                          package deleted once no device is still retryable
```

### Types

| type | role |
|---|---|
| `DeviceStore` | every connected device, plus the selection set (UDIDs, so a reconnect keeps its tick) |
| `InstallScheduler` | admission control: a global cap, and one job per device |
| `MultiInstallCoordinator` | owns the acquire task and one task per device; provides cancel/retry |
| `PerDeviceInstallJob` / `DeviceInstallState` | what the UI renders per (app, device) |
| `InstallCenter` | observable front end; bulk actions; concurrency setting |

### Concurrency

Two independent limits, both enforced by `InstallScheduler`:

1. **A global cap** (1/3/5/10, configurable in Settings, default 3). Each install
   holds a USB session, an AFC transfer and an installation_proxy session open for
   minutes; beyond a handful, usbmuxd is the bottleneck.
2. **One job per device.** Two apps installing to the same phone would both write to
   `PublicStaging` and race in installation_proxy.

Waiters are admitted FIFO, except that a waiter whose device is busy is skipped
rather than blocking the queue behind it — so one slow phone never stalls the others.
Verified with `asdctl scheduler`: 9 jobs over 4 devices at a cap of 3 gives peak
concurrency 3, zero same-device overlap, no deadlock.

`AppInstaller` was changed from an `actor` to a `Sendable` struct for this. As an
actor it would have serialised every install behind one executor, making ten phones
exactly as slow as one. It holds no state; each call opens its own device session,
and blocking libimobiledevice calls are dispatched off the cooperative pool by
`DeviceIO` so they cannot starve it.

### Preserved single-device behaviour

Plugging in exactly one phone auto-selects it, so the original flow is unchanged:
search, press Install, done. A single-device install is just a batch of one.

## 6b. Paid apps and ownership

An app the account already owns needs **no purchase call at all**. `buyProduct`
acquires a licence; downloading uses one that already exists. So the paid path is not
a special case bolted on — it is the normal download path with the purchase step
skipped.

### Ownership is the same call as authorization

Apple exposes no "do I own this" endpoint. The licence check and the download
authorization are literally the same request — `POST volumeStoreDownloadProduct` —
which answers either `failureType 9610` (no licence) or the download details. The
ownership probe therefore issues that request and reads only the verdict, moving no
package bytes.

| price | Apple's answer | state | UI |
|---|---|---|---|
| 0 | — (not probed) | `free` | `[ Install ]` |
| > 0 | licence returned | `purchased` | `Purchased ✓`  `[ Install ]` |
| > 0 | `9610` | `notPurchased` | `$2.99`  `Not Purchased` |
| any | error | `unknown` | `[ Check ]` — never rendered as "not owned" |

**Only paid apps are probed.** A free app is installable regardless of licence
history, so probing one would spend an authenticated request to learn nothing; a
30-result search costs at most a handful of calls instead of thirty.

`unknown` deliberately never degrades to `notPurchased`. Telling someone they do not
own an app they paid for is the worse of the two wrong answers.

### Payment is structurally impossible

The price guard sits in three independent places, not one:

* `OwnershipStore`/`AppModel` — Install is not offered unless ownership is
  `free` or `purchased`.
* `handleAcquire` (Go) — a licence-missing response for a priced app returns
  `not-purchased` and stops; `buyProduct` is never reached.
* `handlePurchase` (Go) — refuses any app with a non-zero price outright.

### Download reuse — measured, not assumed

Two experiments, both run against the real account:

1. **The authorization request contains no device identifier.** Its entire payload is
   `creditDisplay`, `guid` (the *Mac's* MAC address), `salableAdamId` and a literal
   `serialNumber` of `"0"`. Apple cannot be binding the result to an iPhone it was
   never told about, so the package is account-scoped and one download serves every
   selected device.
2. **Apple mints fresh licence material every time.** Two authorizations for
   Shadowrocket 2.2.90 on the same account returned sinf blobs with different
   digests (`c62f3161…` vs `e23b34a0…`), both 1048 bytes.

Finding (1) says the 34 MB package may be reused. Finding (2) says the licence is not
something to replay. So the design does both:

```
authorize + download package ONCE  (34 MB)
        │
        ├── device A ── authorize again (small POST) ─▶ sinf A ─▶ instproxy
        ├── device B ── authorize again              ─▶ sinf B ─▶ instproxy
        └── device C ── authorize again              ─▶ sinf C ─▶ instproxy
```

`installation_proxy` takes the licence as the `ApplicationSINF` *client option*,
separate from the uploaded archive, so per-device licence material costs one small
request per device and no extra disk.

There is no device-count limit anywhere in this application. If Apple declines a
particular authorization, that device's job reports Apple's own message and the rest
of the batch continues.

## 7. Build order

1. Device detection — `DeviceKit`, verified against the connected iPhone ✅
2. Catalogue search — `ITunesCatalog`, native Swift
3. Authentication — sidecar `login`, 2FA, Keychain persistence
4. Acquisition + download — sidecar `install` (purchase → download → patch)
5. Direct installation — `AppInstaller`, AFC + installation_proxy
6. SwiftUI shell wiring all of it
