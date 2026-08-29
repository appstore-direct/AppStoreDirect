package main

import (
	"archive/zip"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"github.com/majd/ipatool/v2/pkg/appstore"
	"github.com/majd/ipatool/v2/pkg/util/machine"
	"github.com/majd/ipatool/v2/pkg/util/operatingsystem"
	"github.com/schollz/progressbar/v3"
)

// newStore assembles ipatool's App Store client with our substituted dependencies.
// Every Apple-protocol call in this file goes through it.
func newStore(jar *sessionJar) (appstore.AppStore, *memoryKeychain) {
	os := operatingsystem.New()
	keychain := newMemoryKeychain()
	return appstore.NewAppStore(appstore.Args{
		Keychain:        keychain,
		CookieJar:       jar,
		OperatingSystem: os,
		Machine:         machine.New(machine.Args{OS: os}),
	}), keychain
}

// toAccount converts to the shape the Swift side persists, dropping the password.
func toAccount(source appstore.Account) account {
	return account{
		Email:               source.Email,
		Name:                strings.TrimSpace(source.Name),
		DirectoryServicesID: source.DirectoryServicesID,
		Storefront:          source.StoreFront,
		PasswordToken:       source.PasswordToken,
		Pod:                 source.Pod,
	}
}

func fromAccount(source account) appstore.Account {
	return appstore.Account{
		Email:               source.Email,
		Name:                source.Name,
		DirectoryServicesID: source.DirectoryServicesID,
		StoreFront:          source.Storefront,
		PasswordToken:       source.PasswordToken,
		Pod:                 source.Pod,
	}
}

// handleLogin authenticates against Apple. The SAP handshake happens inside
// ipatool's Login: it fetches the bag, downloads and caches Apple's signing assets
// on first use, completes the setup exchange, and signs the request.
func handleLogin(params loginParams) (*loginResult, *rpcError) {
	if params.Email == "" || params.Password == "" {
		return nil, &rpcError{Code: errCodeInvalidLogin, Message: "Enter your Apple Account email and password."}
	}

	jar, err := newSessionJar("")
	if err != nil {
		return nil, internalError(err)
	}
	defer jar.close()

	store, keychain := newStore(jar)
	defer keychain.zero()

	output, err := store.Login(appstore.LoginInput{
		Email:    params.Email,
		Password: params.Password,
		AuthCode: params.TwoFactorCode,
	})
	if err != nil {
		failure := mapAppleError(err)
		// Apple answers a wrong password and a missing 2FA code with the same
		// message, so "code required" is only truthful before we have sent one.
		// Reporting it again after a code was supplied would loop the UI.
		if params.TwoFactorCode != "" &&
			(failure.Code == errCodeTwoFactorRequired || failure.Code == errCodeInternal) {
			return nil, &rpcError{
				Code:    errCodeInvalidLogin,
				Message: "Sign-in failed. Check your password and verification code, then try again.",
			}
		}
		return nil, failure
	}

	cookies, err := jar.export()
	if err != nil {
		return nil, internalError(err)
	}

	return &loginResult{Account: toAccount(output.Account), Cookies: cookies}, nil
}

// handleResume performs a launch-time preflight on a stored session.
//
// It deliberately does NOT re-authenticate: Apple issues no cheap "is this token
// still valid" call, and ipatool's AccountInfo only reads local state. Token
// validity is therefore discovered on first use, where an expired token surfaces as
// session-expired and the app prompts for a fresh sign-in.
//
// What it does check is the thing that actually breaks silently: that Apple still
// serves this client a SAP-capable bag with the protocol version we implement. That
// catches "Apple changed the protocol" at launch instead of halfway through an
// install, which is the failure mode worth spending a round trip on.
func handleResume(params resumeParams) (*account, *rpcError) {
	if params.Account.PasswordToken == "" || params.Account.DirectoryServicesID == "" {
		return nil, &rpcError{
			Code:    errCodeSessionExpired,
			Message: "The stored session is incomplete. Sign in again.",
		}
	}

	jar, err := newSessionJar(params.Cookies)
	if err != nil {
		return nil, internalError(err)
	}
	defer jar.close()

	store, keychain := newStore(jar)
	defer keychain.zero()

	if _, err := store.Bag(appstore.BagInput{}); err != nil {
		return nil, &rpcError{
			Code:    errCodeAppleUnavailable,
			Message: "Could not reach the App Store. Check your connection and try again.",
		}
	}

	resumed := params.Account
	return &resumed, nil
}

// handleOwnership determines whether the signed-in account may download an app.
//
// Apple exposes no separate "do I own this" call. The licence check and the download
// authorization are the same request: a POST to volumeStoreDownloadProduct, which
// answers with failureType 9610 when the account holds no licence and with the
// download details when it does. ipatool's ListVersions issues exactly that request
// and reads the version list from the reply, so it works as an ownership probe that
// transfers no package bytes.
//
// Nothing here can start a purchase. Acquiring a licence is a separate call that this
// function never makes.
func handleOwnership(params ownershipParams) (*ownershipResult, *rpcError) {
	jar, err := newSessionJar(params.Cookies)
	if err != nil {
		return nil, internalError(err)
	}
	defer jar.close()

	store, keychain := newStore(jar)
	defer keychain.zero()
	if err := seedAccount(keychain, params.Account); err != nil {
		return nil, internalError(err)
	}

	listed, err := store.ListVersions(appstore.ListVersionsInput{
		Account: fromAccount(params.Account),
		App:     appstore.App{ID: params.AppStoreID, BundleID: params.BundleID},
	})

	if err == nil {
		state := ownershipPurchased
		if params.Price == 0 {
			// A free app the account has already acquired. The UI shows these as
			// installable without dwelling on licence history.
			state = ownershipFree
		}
		return &ownershipResult{
			State:              state,
			DownloadAuthorized: true,
			AvailableVersions:  len(listed.ExternalVersionIdentifiers),
		}, nil
	}

	if errors.Is(err, appstore.ErrLicenseRequired) {
		// No licence. For a free app that is routine and recoverable at install
		// time; for a paid app it means the account has not bought it, and this
		// application will not offer to.
		state := ownershipNotPurchased
		if params.Price == 0 {
			state = ownershipFree
		}
		return &ownershipResult{State: state, DownloadAuthorized: false}, nil
	}

	if errors.Is(err, appstore.ErrPasswordTokenExpired) {
		return nil, &rpcError{
			Code:    errCodeSessionExpired,
			Message: "Your App Store session expired. Sign in again.",
		}
	}

	// Anything else — Apple unavailable, network, an unexpected failureType — is
	// reported as unknown rather than guessed at as "not owned", so the UI never
	// tells the user they do not own something they paid for.
	return &ownershipResult{
		State:  ownershipUnknown,
		Detail: redact(err.Error()),
	}, nil
}

// handlePurchase obtains a licence for a free app, without downloading it.
//
// Hard-limited to apps Apple prices at zero. The install path acquires licences
// inline as part of its retry loop; this exists so a licence can also be obtained on
// its own, and so the price guard lives in one auditable place on each side.
func handlePurchase(params purchaseParams) (*struct{}, *rpcError) {
	if params.Price > 0 {
		return nil, &rpcError{
			Code:    errCodePaidApp,
			Message: "This application does not purchase paid apps.",
		}
	}

	jar, err := newSessionJar(params.Cookies)
	if err != nil {
		return nil, internalError(err)
	}
	defer jar.close()

	store, keychain := newStore(jar)
	defer keychain.zero()
	if err := seedAccount(keychain, params.Account); err != nil {
		return nil, internalError(err)
	}

	err = store.Purchase(appstore.PurchaseInput{
		Account: fromAccount(params.Account),
		App:     appstore.App{ID: params.AppStoreID, BundleID: params.BundleID, Name: params.Name},
	})
	if err != nil && !errors.Is(err, appstore.ErrLicenseAlreadyExists) {
		return nil, mapAppleError(err)
	}
	return &struct{}{}, nil
}

// handleAcquire obtains a licence if needed, downloads the package, injects the
// metadata and sinf, and reports progress as it goes.
//
// Ordering follows ipatool's own download command: attempt the download first, and
// only obtain a licence when Apple says one is missing. That avoids sending a
// purchase request for apps already in the account's history.
func handleAcquire(id string, params acquireParams, emit func(string, interface{})) (*acquireResult, *rpcError) {
	jar, err := newSessionJar(params.Cookies)
	if err != nil {
		return nil, internalError(err)
	}
	defer jar.close()

	store, keychain := newStore(jar)
	defer keychain.zero()
	if err := seedAccount(keychain, params.Account); err != nil {
		return nil, internalError(err)
	}

	if err := os.MkdirAll(params.Destination, 0o700); err != nil {
		return nil, internalError(err)
	}

	acc := fromAccount(params.Account)
	app := appstore.App{ID: params.AppStoreID, BundleID: params.BundleID, Name: params.Name}

	// A paid app that reaches here is already owned: the download request below
	// carries the account's existing entitlement and no purchase occurs.
	emit("progress", progressEvent{Phase: "preparing"})

	bar, stop := newProgressReporter(id, emit)
	defer stop()

	var output appstore.DownloadOutput
	acquired := false

	// Two attempts: the second only happens after obtaining a licence.
	for attempt := 0; attempt < 2; attempt++ {
		output, err = store.Download(appstore.DownloadInput{
			Account:           acc,
			App:               app,
			OutputPath:        params.Destination,
			Progress:          bar,
			ExternalVersionID: params.ExternalVersionID,
			Platform:          appstore.PlatformIPhone,
		})
		if err == nil {
			break
		}

		if errors.Is(err, appstore.ErrLicenseRequired) && attempt == 0 {
			// A paid app with no licence means the account has not purchased it.
			// Obtaining one would be a financial transaction, which this
			// application never initiates. Report it and stop.
			if params.Price > 0 {
				return nil, &rpcError{
					Code: errCodeNotPurchased,
					Message: fmt.Sprintf(
						"%s is not in this Apple Account's purchase history. Buy it in the App Store first, then install it here.",
						params.Name,
					),
				}
			}

			// Free app: acquiring the licence costs nothing and is the normal path.
			emit("progress", progressEvent{Phase: "authorizing"})
			purchaseErr := store.Purchase(appstore.PurchaseInput{Account: acc, App: app})
			if purchaseErr != nil && !errors.Is(purchaseErr, appstore.ErrLicenseAlreadyExists) {
				return nil, mapAppleError(purchaseErr)
			}
			acquired = true
			continue
		}
		return nil, mapAppleError(err)
	}
	if err != nil {
		return nil, mapAppleError(err)
	}

	stop()
	emit("progress", progressEvent{Phase: "packaging"})

	// Without the sinf at the path the device expects, installation_proxy rejects
	// the package. This is the step that makes the download installable.
	if err := store.ReplicateSinf(appstore.ReplicateSinfInput{
		Sinfs:       output.Sinfs,
		PackagePath: output.DestinationPath,
	}); err != nil {
		_ = os.Remove(output.DestinationPath)
		return nil, internalError(err)
	}

	metadata, bundleID, version, err := readPackageFacts(output.DestinationPath)
	if err != nil {
		_ = os.Remove(output.DestinationPath)
		return nil, &rpcError{Code: errCodeInternal, Message: err.Error()}
	}
	if bundleID == "" {
		bundleID = params.BundleID
	}

	if len(output.Sinfs) == 0 {
		_ = os.Remove(output.DestinationPath)
		return nil, &rpcError{
			Code:    errCodeLicenceRequired,
			Message: "Apple did not return a licence for this app on this account.",
		}
	}

	info, err := os.Stat(output.DestinationPath)
	if err != nil {
		return nil, internalError(err)
	}
	if err := os.Chmod(output.DestinationPath, 0o600); err != nil {
		return nil, internalError(err)
	}

	return &acquireResult{
		Path:      output.DestinationPath,
		BundleID:  bundleID,
		Version:   version,
		ByteCount: info.Size(),
		Sinf:      base64.StdEncoding.EncodeToString(output.Sinfs[0].Data),
		Metadata:  base64.StdEncoding.EncodeToString(metadata),
		Acquired:  acquired,
	}, nil
}

// handleVersions lists the builds Apple still serves for an app. Used to fall back
// to an older release when the current one needs a newer iOS than the device runs.
func handleVersions(params versionsParams) (*versionsResult, *rpcError) {
	jar, err := newSessionJar(params.Cookies)
	if err != nil {
		return nil, internalError(err)
	}
	defer jar.close()

	store, keychain := newStore(jar)
	defer keychain.zero()
	if err := seedAccount(keychain, params.Account); err != nil {
		return nil, internalError(err)
	}

	acc := fromAccount(params.Account)
	app := appstore.App{ID: params.AppStoreID, BundleID: params.BundleID}

	listed, err := store.ListVersions(appstore.ListVersionsInput{Account: acc, App: app})
	if err != nil {
		return nil, mapAppleError(err)
	}

	identifiers := listed.ExternalVersionIdentifiers
	// Newest first, and capped: Apple returns the full history, which for an old
	// app is hundreds of entries and not useful to show.
	// Each entry below costs one round-trip to Apple for its version string, so
	// this is capped at what a picker can usefully show rather than the full history.
	const maxVersions = 15
	start := 0
	if len(identifiers) > maxVersions {
		start = len(identifiers) - maxVersions
	}

	result := versionsResult{}
	for index := len(identifiers) - 1; index >= start; index-- {
		identifier := identifiers[index]
		entry := versionEntry{ExternalVersionID: identifier}

		metadata, err := store.GetVersionMetadata(appstore.GetVersionMetadataInput{
			Account:   acc,
			App:       app,
			VersionID: identifier,
		})
		if err == nil {
			entry.VersionString = metadata.DisplayVersion
			if !metadata.ReleaseDate.IsZero() {
				entry.ReleaseDate = metadata.ReleaseDate.Format("2006-01-02")
			}
		}
		result.Versions = append(result.Versions, entry)
	}
	return &result, nil
}

// seedAccount puts the caller's session where ipatool's client expects to find it.
func seedAccount(keychain *memoryKeychain, source account) error {
	encoded, err := marshalJSON(fromAccount(source))
	if err != nil {
		return err
	}
	return keychain.Set("account", encoded)
}

// readPackageFacts pulls the iTunesMetadata blob and identifying fields back out of
// the finished package, so the Swift side never needs a zip reader of its own.
func readPackageFacts(path string) (metadata []byte, bundleID string, version string, err error) {
	reader, err := zip.OpenReader(path)
	if err != nil {
		return nil, "", "", fmt.Errorf("the downloaded package could not be opened")
	}
	defer reader.Close()

	for _, file := range reader.File {
		if file.Name != "iTunesMetadata.plist" {
			continue
		}
		handle, err := file.Open()
		if err != nil {
			return nil, "", "", fmt.Errorf("the downloaded package is missing its store metadata")
		}
		metadata, err = io.ReadAll(handle)
		handle.Close()
		if err != nil {
			return nil, "", "", fmt.Errorf("the downloaded package is missing its store metadata")
		}
		break
	}
	if metadata == nil {
		return nil, "", "", fmt.Errorf("the downloaded package is missing its store metadata")
	}

	bundleID, version = readInfoPlistFacts(reader)
	return metadata, bundleID, version, nil
}

// readInfoPlistFacts reads the bundle identifier and short version straight from the
// payload's Info.plist, which is authoritative for what installation_proxy will see.
func readInfoPlistFacts(reader *zip.ReadCloser) (string, string) {
	for _, file := range reader.File {
		name := file.Name
		if !strings.HasPrefix(name, "Payload/") || !strings.HasSuffix(name, ".app/Info.plist") {
			continue
		}
		// Only the top-level app bundle, never a nested extension or framework.
		if strings.Count(strings.TrimPrefix(name, "Payload/"), "/") != 1 {
			continue
		}
		handle, err := file.Open()
		if err != nil {
			return "", ""
		}
		data, err := io.ReadAll(handle)
		handle.Close()
		if err != nil {
			return "", ""
		}
		return plistStrings(data, "CFBundleIdentifier", "CFBundleShortVersionString")
	}
	return "", ""
}

// newProgressReporter drives download progress out as NDJSON events.
//
// ipatool reports download progress by writing into a progressbar, so we hand it one
// backed by a discarding writer and sample its state on a timer. Sampling rather than
// hooking keeps us off ipatool's internals, which is the point of the vendoring
// boundary.
func newProgressReporter(id string, emit func(string, interface{})) (*progressbar.ProgressBar, func()) {
	bar := progressbar.NewOptions64(1,
		progressbar.OptionSetWriter(io.Discard),
		progressbar.OptionShowBytes(true),
		progressbar.OptionThrottle(0),
	)

	done := make(chan struct{})
	stopped := false
	ticker := time.NewTicker(120 * time.Millisecond)

	go func() {
		defer ticker.Stop()
		var lastSent int64 = -1
		for {
			select {
			case <-done:
				return
			case <-ticker.C:
				state := bar.State()
				received := int64(state.CurrentBytes)
				expected := state.Max
				// The bar is created with a placeholder maximum of 1 and only
				// learns the real content length once the response headers land.
				// Emitting before then renders as "Zero KB of 1 byte".
				if expected <= 1 {
					continue
				}
				if received == lastSent {
					continue
				}
				lastSent = received
				fraction := 0.0
				if expected > 0 {
					fraction = float64(received) / float64(expected)
				}
				emit("progress", progressEvent{
					Phase:         "downloading",
					Fraction:      fraction,
					BytesReceived: received,
					BytesExpected: expected,
				})
			}
		}
	}()

	return bar, func() {
		if stopped {
			return
		}
		stopped = true
		close(done)
	}
}

func internalError(err error) *rpcError {
	return &rpcError{Code: errCodeInternal, Message: redact(err.Error())}
}

// mapAppleError turns ipatool's errors into stable codes the UI can branch on.
func mapAppleError(err error) *rpcError {
	switch {
	case errors.Is(err, appstore.ErrAuthCodeRequired):
		return &rpcError{
			Code:    errCodeTwoFactorRequired,
			Message: "Enter the six-digit verification code from your trusted device.",
		}
	case errors.Is(err, appstore.ErrPasswordTokenExpired):
		return &rpcError{
			Code:    errCodeSessionExpired,
			Message: "Your App Store session expired. Sign in again.",
		}
	case errors.Is(err, appstore.ErrLicenseRequired):
		return &rpcError{
			Code:    errCodeLicenceRequired,
			Message: "This app is not in your Apple Account's purchase history.",
		}
	case errors.Is(err, appstore.ErrSubscriptionRequired):
		return &rpcError{
			Code:    errCodePaidApp,
			Message: "This app requires an active subscription, such as Apple Arcade.",
		}
	case errors.Is(err, appstore.ErrTemporarilyUnavailable):
		return &rpcError{
			Code:    errCodeAppleUnavailable,
			Message: "Apple reports this app is temporarily unavailable. Try again shortly.",
		}
	}

	message := redact(err.Error())
	lowered := strings.ToLower(message)
	switch {
	case strings.Contains(lowered, "incorrect") || strings.Contains(lowered, "bad login"):
		return &rpcError{Code: errCodeInvalidLogin, Message: "Incorrect Apple Account email or password."}
	case strings.Contains(lowered, "account is disabled"):
		return &rpcError{Code: errCodeInvalidLogin, Message: "This Apple Account is disabled."}
	}
	return &rpcError{Code: errCodeInternal, Message: message}
}
