package main

// Wire protocol between the Swift app and this sidecar: newline-delimited JSON on
// stdin/stdout, one object per line. Requests carry an id; every response and event
// echoes it. The sidecar never writes anything else to stdout — diagnostics go to
// stderr, already redacted.

type request struct {
	ID     string  `json:"id"`
	Method string  `json:"method"`
	Params rawJSON `json:"params"`
}

type response struct {
	ID     string      `json:"id"`
	OK     bool        `json:"ok"`
	Result interface{} `json:"result,omitempty"`
	Error  *rpcError   `json:"error,omitempty"`
}

type event struct {
	ID    string      `json:"id"`
	Event string      `json:"event"`
	Data  interface{} `json:"data"`
}

// rpcError uses a stable machine-readable code so the Swift side can branch on the
// condition rather than on message text, which changes when Apple changes it.
type rpcError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

const (
	errCodeTwoFactorRequired = "two-factor-required"
	errCodeInvalidLogin      = "invalid-credentials"
	errCodeSessionExpired    = "session-expired"
	errCodeLicenceRequired   = "licence-required"
	errCodePaidApp           = "paid-app"
	// The account does not hold a licence for a paid app. Distinct from
	// licence-required, which for a free app is recoverable by acquiring one.
	errCodeNotPurchased     = "not-purchased"
	errCodeNotFound         = "not-found"
	errCodeAppleUnavailable = "apple-unavailable"
	errCodeInternal         = "internal"
)

// account is the session the Swift side persists in the Keychain. It intentionally
// has no password field: after login Apple's passwordToken is what authorises
// purchase and download, and the password must not be written to disk.
type account struct {
	Email               string `json:"email"`
	Name                string `json:"name"`
	DirectoryServicesID string `json:"directoryServicesID"`
	Storefront          string `json:"storefront"`
	PasswordToken       string `json:"passwordToken"`
	Pod                 string `json:"pod"`
}

type loginParams struct {
	Email         string `json:"email"`
	Password      string `json:"password"`
	TwoFactorCode string `json:"twoFactorCode"`
}

type loginResult struct {
	Account account `json:"account"`
	// Opaque, base64-encoded cookie jar. The Swift side stores it in the Keychain
	// alongside the account and hands it back on the next launch.
	Cookies string `json:"cookies"`
}

type resumeParams struct {
	Account account `json:"account"`
	Cookies string  `json:"cookies"`
}

// Ownership states, mirrored by AppOwnershipState on the Swift side.
const (
	ownershipFree         = "free"
	ownershipPurchased    = "purchased"
	ownershipNotPurchased = "notPurchased"
	ownershipUnknown      = "unknown"
)

type ownershipParams struct {
	Account    account `json:"account"`
	Cookies    string  `json:"cookies"`
	AppStoreID int64   `json:"appStoreID"`
	BundleID   string  `json:"bundleID"`
	Price      float64 `json:"price"`
}

type ownershipResult struct {
	State string `json:"state"`
	// True when Apple returned a usable download authorization for this account.
	DownloadAuthorized bool `json:"downloadAuthorized"`
	// Number of builds Apple still serves; 0 when unknown.
	AvailableVersions int `json:"availableVersions"`
	// Present only when the probe failed for a reason other than ownership.
	Detail string `json:"detail,omitempty"`
}

type purchaseParams struct {
	Account    account `json:"account"`
	Cookies    string  `json:"cookies"`
	AppStoreID int64   `json:"appStoreID"`
	BundleID   string  `json:"bundleID"`
	Name       string  `json:"name"`
	Price      float64 `json:"price"`
}

type acquireParams struct {
	Account           account `json:"account"`
	Cookies           string  `json:"cookies"`
	AppStoreID        int64   `json:"appStoreID"`
	BundleID          string  `json:"bundleID"`
	Name              string  `json:"name"`
	Price             float64 `json:"price"`
	ExternalVersionID string  `json:"externalVersionID"`
	Destination       string  `json:"destination"`
}

type acquireResult struct {
	Path      string `json:"path"`
	BundleID  string `json:"bundleID"`
	Version   string `json:"version"`
	ByteCount int64  `json:"byteCount"`
	// base64. Handed to installation_proxy as ApplicationSINF / iTunesMetadata.
	Sinf     string `json:"sinf"`
	Metadata string `json:"metadata"`
	// True when a licence had to be obtained as part of this call.
	Acquired bool `json:"acquired"`
}

type versionsParams struct {
	Account    account `json:"account"`
	Cookies    string  `json:"cookies"`
	AppStoreID int64   `json:"appStoreID"`
	BundleID   string  `json:"bundleID"`
}

type versionsResult struct {
	Versions []versionEntry `json:"versions"`
}

type versionEntry struct {
	ExternalVersionID string `json:"externalVersionID"`
	VersionString     string `json:"versionString"`
	ReleaseDate       string `json:"releaseDate"`
}

// progress events emitted during acquire.
type progressEvent struct {
	Phase         string  `json:"phase"`
	Fraction      float64 `json:"fraction"`
	BytesReceived int64   `json:"bytesReceived"`
	BytesExpected int64   `json:"bytesExpected"`
}
